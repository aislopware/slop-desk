#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import SlopDeskVideoProtocol
import SwiftUI

/// Connection parameters for a remote GUI window (PATH 2 / Phase 4, doc 17 §3): host
/// endpoint + the window to remote. Built by the GUI app and handed to ``VideoWindowView``.
public struct VideoWindowConnection: Sendable, Equatable {
    /// The host's NetBird-routable address (or hostname).
    public var host: String
    /// The host media UDP port (control/video/geometry/input).
    public var mediaPort: UInt16
    /// The host dedicated cursor UDP port.
    public var cursorPort: UInt16
    /// The host CGWindowID to remote (`0` for a display target).
    public var windowID: UInt32
    /// FULL-DESKTOP TARGET: non-nil ⇒ stream a whole host display (`0` = the main display) via
    /// the wire `helloDisplay` instead of a window `hello`. `nil` ⇒ window.
    public var displayID: UInt32?

    public init(host: String, mediaPort: UInt16, cursorPort: UInt16, windowID: UInt32, displayID: UInt32? = nil) {
        self.host = host
        self.mediaPort = mediaPort
        self.cursorPort = cursorPort
        self.windowID = windowID
        self.displayID = displayID
    }

    /// The stream target this connection names (display wins when set).
    public var streamTarget: VideoStreamTarget {
        displayID.map { .display($0) } ?? .window(windowID)
    }
}

/// Bridges the SwiftUI control overlay (fit/fill toggle + zoom reset) to the backing view's
/// pipeline: the view sets the `onToggle*` closures on `activate` and publishes `mode`/`zoomed`
/// for the overlay icons. Deliberately a SwiftUI overlay — NOT AppKit/UIKit subviews of the Metal
/// view: subviews + gesture recognizers on the layer-backed Metal view perturbed its geometry and
/// swallowed the `mouseUp` of a trackpad three-finger-drag (→ a stuck remote button).
@preconcurrency
@MainActor
public final class VideoPaneControls: ObservableObject {
    @Published public var mode: VideoContentMode = .fit
    @Published public var zoomed: Bool = false
    /// SWIPE-PEEL chip (doc 05 §8): the live swipe-nav feedback state the SwiftUI overlay
    /// renders (`nil` = hidden). Published by the macOS backing view's ``SwipePeelPlanner``
    /// mirror, already quantized so the 120 Hz gesture stream re-renders the chip at most a
    /// few dozen times per gesture. Never set on iOS (no trackpad scroll phases).
    @Published public var swipePeel: SwipePeelChipState?
    var onToggleFill: () -> Void = {}
    var onResetZoom: () -> Void = {}
    public init() {}
    func toggleFill() { onToggleFill() }
    func resetZoom() { onResetZoom() }
}

/// A SwiftUI view that hosts the `CAMetalLayer` + cursor overlay for one remote GUI
/// window (doc 17 §3 PATH 2). It owns the Metal layer/view, builds the
/// ``MetalVideoRenderer`` + ``ClientCursorCompositor`` + ``SlopDeskVideoClientSession``,
/// starts the orchestrator on appear and stops it on disappear, drives the decoded-
/// frame → renderer path through the ``FramePacer`` display link, and forwards input.
///
/// Each layout pass it computes `videoScale = layerSize / decodedFrameSize` and feeds
/// it to ``ClientCursorCompositor`` (via the session) so the composited cursor lands
/// on the right pixel.
///
/// ⚠️ **GUI-ONLY:** instantiating the renderer / decoder / display link / sockets
/// needs a real device + screen + TCC. COMPILED + reviewed; not driven from tests.
/// This is the wiring point `SlopDeskClientUI` injects via `VideoWindowFactory`.
public struct VideoWindowView: View {
    /// The remote window's title, shown for accessibility.
    public let title: String
    /// `nil` ⇒ no live connection (the seam's placeholder path / preview). When set,
    /// the backing view brings up the full client pipeline.
    public let connection: VideoWindowConnection?

    /// Whether this pane is the active/focused pane on the canvas. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes scroll to ``onCanvasScroll`` (the
    /// "only the active pane swallows pointer" rule). Plain (non-isolated) closures + Bool so the
    /// `AppMain` factory can bridge them across the seam without importing `SlopDeskClientUI`.
    let isActive: Bool
    /// READ-ONLY INPUT GATE. `false` ⇒ this pane is read-only: forward NEITHER pointer/scroll
    /// NOR keycodes to the host. A click may still ACTIVATE the workspace pane (`onActivate`), but it is not
    /// relayed and the host window is not raised; the paste-as-keystrokes sink is also withheld. Gated with
    /// `isActive && inputEnabled` on every relay. Defaults `true` (a writable pane).
    let inputEnabled: Bool
    /// Make this pane active (set workspace focus) — called on click. The host window is also raised
    /// (via the pane's own `focusWindow`).
    let onActivate: () -> Void
    /// Pan the canvas when a NON-active pane is scrolled (so scroll over a background pane navigates the
    /// canvas instead of being swallowed by the remote window).
    let onCanvasScroll: (CGSize) -> Void
    /// 1:1 PANE SNAP: ask the surrounding canvas pane to resize its VIDEO CONTENT from `current`
    /// to `target` points so the stream renders pixel-for-pixel (`target` = decoded pixels /
    /// contentsScale, fired on the first decoded frame and on host-side capture-size changes).
    /// `nil` ⇒ standalone window (no pane to snap) → the session keeps the legacy connect-time
    /// host-follow negotiation instead.
    let onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the backing view publishes a key-injection closure here once it exists
    /// (and `nil` on teardown), routed to `pipeline.key(...)` — the same secure-input-aware path the
    /// keyboard uses. `(keyCode, down, shift)`. `nil` ⇒ no canvas wants the sink (preview/standalone).
    let onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)?
    /// RESIZE (numeric popover): the live view publishes a resize-drive closure here once its session
    /// exists (and `nil` on teardown), so the pane's "Resize…" popover can request an ABSOLUTE
    /// host-window POINT size. The closure is `(width, height)` in host points. `nil` ⇒ no canvas.
    let onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)?
    /// VIEWPORT CONTROLS: the live view publishes a client-viewport command closure here once its session
    /// exists (and `nil` on teardown), so the pane's control bar can drive zoom / pan-lock. The closure
    /// carries a raw command byte (`RemoteWindowModel.ViewportCommand`). `nil` ⇒ no canvas / iOS.
    let onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)?
    /// RELEASE STUCK INPUT (C5): the live view publishes a zero-arg release closure here (and `nil` on
    /// teardown) that synthesizes a key-UP for every held modifier + a mouse-UP for every button — the
    /// palette's chord-less escape hatch for a host left holding input. `nil` ⇒ no canvas / iOS.
    let onInputReleaseReady: (((() -> Void)?) -> Void)?
    /// HOST-WINDOW RESIZE: the live view pushes the window's current + MAX resizable POINT sizes here
    /// whenever either changes (first decoded frame / host displayMax report), so the "Resize…" popover
    /// pre-fills its fields at the current size and caps them at the remote max. `(curW, curH, maxW,
    /// maxH)`; a zero max means "not yet known" (the popover then leaves the field uncapped). `nil` ⇒ none.
    let onWindowGeometryReady: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)?
    /// CONNECTION STATS: the live view pushes the host-announced stream CADENCE (frames/sec) here whenever
    /// the host's FPS governor announces a new value, so the sidebar's Connection section shows a per-pane
    /// "FPS" row. `nil` ⇒ no canvas wired it (preview / standalone / iOS).
    let onStreamCadenceReady: ((_ fps: Int) -> Void)?
    /// CONNECTION STATS: the live view pushes the client-measured video PAYLOAD bitrate (kilobits/sec,
    /// ~1 Hz) here — the titlebar cluster's stream-weight complication. `nil` ⇒ no canvas wired it.
    let onStreamBitrateReady: ((_ kbps: Int) -> Void)?
    /// NETWORK-STATS MIRROR: the live view pushes the ~2 Hz client-local telemetry aggregate here —
    /// received frames/sec, FEC recoveries/sec, unrecovered losses/sec, latest hold (ms), pacer
    /// depth — for the pane's stats surface. Primitives only (the seam is headless). `nil` ⇒ none.
    let onNetworkStatsReady: ((
        _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
    ) -> Void)?
    /// STREAM SETTINGS (fps cap / bitrate ceiling): the live view publishes a settings-drive closure
    /// here once its session exists (and `nil` on teardown), so the pane can request a live encode
    /// fps cap / bitrate ceiling (`0` = auto). Host-affecting — the seam withholds it while
    /// read-only, like the resize sink. `nil` ⇒ no canvas.
    let onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)?
    /// SYSTEM-KEY INJECTOR (immersive capture plumbing): the live view publishes a programmatic
    /// key-event closure here (and `nil` on teardown) driving the SAME wire path the Metal view's
    /// local keyDown/keyUp uses. `(keyCode, modifierFlags [raw NSEvent flags], isDown)`.
    /// Host input — the seam withholds it while read-only, like the paste-keystrokes sink. `nil` ⇒ none.
    let onSystemKeyInjectorReady: ((((
        _ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool,
    ) -> Void)?) -> Void)?
    /// STALL SCRIM: the live view pushes the stream's stall state here when it FLIPS — `true` ⇒ the host
    /// went silent past the stall threshold (show the pane's "Reconnecting…" scrim), `false` ⇒ traffic
    /// resumed (clear it). Sticky through the self-heal rebuild. `nil` ⇒ no canvas wired it.
    let onStreamStallChanged: ((_ stalled: Bool) -> Void)?
    /// TERMINAL REFUSAL: the live view fires this once after the host REJECTED the session
    /// (`helloAck(accepted: false)` — window gone / version mismatch, incl. the mux mint-failure
    /// refusal). The pipeline has already torn down WITHOUT the bye path's auto-rebuild; the pane
    /// model should leave its live surface and fall back to the picker/error state. `nil` ⇒ no
    /// canvas wired it (the pane just stays down).
    let onSessionRejected: (() -> Void)?

    /// The existing seam signature (title-only): renders the Metal-backed view chrome
    /// without a live connection. Kept so `VideoWindowFactory` callers compile.
    public init(title: String) {
        self.title = title
        connection = nil
        isActive = true
        inputEnabled = true
        onActivate = {}
        onCanvasScroll = { _ in }
        onStreamNativeSize = nil
        onKeyInjectorReady = nil
        onResizeInjectorReady = nil
        onViewportInjectorReady = nil
        onInputReleaseReady = nil
        onWindowGeometryReady = nil
        onStreamCadenceReady = nil
        onStreamBitrateReady = nil
        onNetworkStatsReady = nil
        onStreamSettingsInjectorReady = nil
        onSystemKeyInjectorReady = nil
        onStreamStallChanged = nil
        onSessionRejected = nil
    }

    /// Live remote-window view: brings up the orchestrator against `connection`. `isActive` /
    /// `onActivate` / `onCanvasScroll` carry the canvas pane behaviour (active-only pointer + click-to-
    /// activate + non-active scroll-to-pan); they default to the standalone (always-active) values.
    public init(
        title: String,
        connection: VideoWindowConnection,
        isActive: Bool = true,
        inputEnabled: Bool = true,
        onActivate: @escaping () -> Void = {},
        onCanvasScroll: @escaping (CGSize) -> Void = { _ in },
        onStreamNativeSize: ((_ target: CGSize, _ current: CGSize) -> Void)? = nil,
        onKeyInjectorReady: ((((_ keyCode: UInt16, _ down: Bool, _ shift: Bool) -> Void)?) -> Void)? = nil,
        onResizeInjectorReady: ((((_ width: Double, _ height: Double) -> Void)?) -> Void)? = nil,
        onViewportInjectorReady: ((((_ command: UInt8) -> Void)?) -> Void)? = nil,
        onInputReleaseReady: (((() -> Void)?) -> Void)? = nil,
        onWindowGeometryReady: ((_ curW: Double, _ curH: Double, _ maxW: Double, _ maxH: Double) -> Void)? = nil,
        onStreamCadenceReady: ((_ fps: Int) -> Void)? = nil,
        onStreamBitrateReady: ((_ kbps: Int) -> Void)? = nil,
        onNetworkStatsReady: ((
            _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
        ) -> Void)? = nil,
        onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)? = nil,
        onSystemKeyInjectorReady: ((((
            _ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool,
        ) -> Void)?) -> Void)? = nil,
        onStreamStallChanged: ((_ stalled: Bool) -> Void)? = nil,
        onSessionRejected: (() -> Void)? = nil,
    ) {
        self.title = title
        self.connection = connection
        self.isActive = isActive
        self.inputEnabled = inputEnabled
        self.onActivate = onActivate
        self.onCanvasScroll = onCanvasScroll
        self.onStreamNativeSize = onStreamNativeSize
        self.onKeyInjectorReady = onKeyInjectorReady
        self.onResizeInjectorReady = onResizeInjectorReady
        self.onViewportInjectorReady = onViewportInjectorReady
        self.onInputReleaseReady = onInputReleaseReady
        self.onWindowGeometryReady = onWindowGeometryReady
        self.onStreamCadenceReady = onStreamCadenceReady
        self.onStreamBitrateReady = onStreamBitrateReady
        self.onNetworkStatsReady = onNetworkStatsReady
        self.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        self.onSystemKeyInjectorReady = onSystemKeyInjectorReady
        self.onStreamStallChanged = onStreamStallChanged
        self.onSessionRejected = onSessionRejected
    }

    /// Owns the control bridge for this view's lifetime; the backing view wires its closures.
    @StateObject private var controls = VideoPaneControls()

    public var body: some View {
        // FILL THE PANE. Without this frame the bare representable claims no space → it shrinks to a small
        // island and clicks across the rest of the pane miss it. Mirrors the terminal seam. No control
        // overlay: the ACTUAL-SIZE viewport auto-anchors to the window top-left and edge-pan navigates.
        MetalVideoLayerView(
            connection: connection,
            controls: controls,
            isActive: isActive,
            inputEnabled: inputEnabled,
            onActivate: onActivate,
            onCanvasScroll: onCanvasScroll,
            onStreamNativeSize: onStreamNativeSize,
            onKeyInjectorReady: onKeyInjectorReady,
            onResizeInjectorReady: onResizeInjectorReady,
            onViewportInjectorReady: onViewportInjectorReady,
            onInputReleaseReady: onInputReleaseReady,
            onWindowGeometryReady: onWindowGeometryReady,
            onStreamCadenceReady: onStreamCadenceReady,
            onStreamBitrateReady: onStreamBitrateReady,
            onNetworkStatsReady: onNetworkStatsReady,
            onStreamSettingsInjectorReady: onStreamSettingsInjectorReady,
            onSystemKeyInjectorReady: onSystemKeyInjectorReady,
            onStreamStallChanged: onStreamStallChanged,
            onSessionRejected: onSessionRejected,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // SWIPE-PEEL feedback chip (doc 05 §8): a SwiftUI overlay, NEVER an NSView subview of
        // the Metal view (the rule at `VideoPaneControls` — subviews perturbed its geometry and
        // swallowed gesture mouseUps). Flat fills only — no material/blur over the CAMetalLayer.
        // The edge alignment lives INSIDE the conditional content so the removal transition keeps
        // the chip on ITS edge — an outer `alignment:` recomputed from nil would yank a fading
        // forward-chip across to the leading edge.
        .overlay {
            if let peel = controls.swipePeel {
                SwipePeelChipView(state: peel)
                    .padding(.horizontal, 14)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: peel.direction == .forward ? .trailing : .leading,
                    )
                    .transition(.opacity)
            }
        }
        .animation(.timingCurve(0, 0, 0.58, 1, duration: 0.15), value: controls.swipePeel)
        .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

/// The swipe-peel progress chip: a chevron in a flat circle whose ring fills toward the commit
/// threshold and turns solid the instant a release would navigate — the affordance native swipe
/// communicates by peeling the page. White-on-any-video (the Chromium overscroll idiom users
/// already know), flat fills only (no material — never glass over the `CAMetalLayer`).
struct SwipePeelChipView: View {
    let state: SwipePeelChipState

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(state.committed ? 0.95 : 0.82))
            Circle()
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
            Circle()
                .trim(from: 0, to: state.progress)
                .stroke(Color.black.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(state.committed ? 0 : 1) // the solid state replaces the progress ring
            Image(systemName: state.direction == .back ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.black.opacity(state.committed ? 0.9 : 0.45))
        }
        .frame(width: 36, height: 36)
        .scaleEffect(state.confirming ? 1.12 : (state.committed ? 1.06 : 1.0))
        .shadow(color: Color.black.opacity(0.25), radius: 4, y: 1)
        .opacity(state.confirming ? 0 : 1) // confirm pulse: scale up while fading out
    }
}

#if os(macOS)
/// Env-gated (`SLOPDESK_VIDEO_DEBUG`) stderr diagnostics for the remote-GUI VIEW layer (scroll routing +
/// isActive delivery) — the BUG-2 ground-truth probe. A non-active pane that logs `isActive=true` proves a
/// stale/sticky focus value; `isActive=false` with no pan proves a downstream scroll-routing problem.
func videoViewDbg(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("SlopDesk[video.client.view]: \(message())\n".utf8))
}

/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    var isActive: Bool = true
    /// READ-ONLY INPUT GATE: `false` ⇒ the backing view forwards no pointer/scroll/keycode to the
    /// host (gated `isActive && inputEnabled`) and withholds the paste-as-keystrokes sink. Set on every render.
    var inputEnabled: Bool = true
    var onActivate: () -> Void = {}
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    var onInputReleaseReady: (((() -> Void)?) -> Void)?
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    var onStreamCadenceReady: ((Int) -> Void)?
    var onStreamBitrateReady: ((Int) -> Void)?
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int) -> Void)?
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    var onStreamStallChanged: ((Bool) -> Void)?
    var onSessionRejected: (() -> Void)?

    func makeNSView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.isActive = isActive
        view.inputEnabled = inputEnabled
        view.onActivate = onActivate
        view.onCanvasScroll = onCanvasScroll
        view.onStreamNativeSize = onStreamNativeSize // before activate — its nil-ness picks snap vs host-follow
        // HOST-WINDOW RESIZE: before activate so the first decoded-points / displayMax callback can publish
        // the window geometry (current + max) straight to the model.
        view.onWindowGeometryReady = onWindowGeometryReady
        // CONNECTION STATS: before activate so the first host cadence announcement reaches the model's FPS row.
        view.onStreamCadenceReady = onStreamCadenceReady
        view.onStreamBitrateReady = onStreamBitrateReady
        // NETWORK-STATS MIRROR: before activate so the first ~2 Hz aggregate reaches the model.
        view.onNetworkStatsReady = onNetworkStatsReady
        // STALL SCRIM: before activate so a stall detected on the very first monitor tick reaches the model.
        view.onStreamStallReady = onStreamStallChanged
        // TERMINAL REFUSAL: before activate so a helloAck(accepted:false) landing immediately reaches the model.
        view.onSessionRejectedReady = onSessionRejected
        view.activate(connection: connection)
        // PASTE AS KEYSTROKES: publish a key-injection sink routed to THIS view's pipeline (`pipeline.key`
        // no-ops until the session is up, so publishing now is safe). Cleared on `deactivate`.
        view.onKeyInjectorReady = onKeyInjectorReady
        view.publishKeyInjector()
        // RESIZE GRIP: publish a resize-drive sink routed to THIS view's pipeline (the session's
        // resize guard no-ops until streaming, so publishing now is safe). Cleared on `deactivate`.
        view.onResizeInjectorReady = onResizeInjectorReady
        view.publishResizeInjector()
        // VIEWPORT CONTROLS: publish the client zoom / pan-lock command sink (pure compositor ops on THIS
        // view — no host round-trip). NOT read-only-gated, so it is never withdrawn on a lock flip. Cleared
        // on `deactivate`.
        view.onViewportInjectorReady = onViewportInjectorReady
        view.publishViewportInjector()
        // RELEASE STUCK INPUT (C5): publish the manual escape-hatch release sink (the seam binds nil while
        // read-only, like the key sink). Cleared on `deactivate`.
        view.onInputReleaseReady = onInputReleaseReady
        view.publishInputReleaseInjector()
        // STREAM SETTINGS: publish the fps-cap / bitrate-ceiling drive (the session's streaming guard
        // makes a pre-stream request safe — it is stored and sent at handshake). Host-affecting, so the
        // seam binds nil while read-only, like the resize sink. Cleared on `deactivate`.
        view.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        view.publishStreamSettingsInjector()
        // SYSTEM-KEY INJECTOR: publish the programmatic key drive (same wire path as local keyDown/keyUp;
        // `pipeline.key` no-ops until the session is up). Host input — seam binds nil while read-only.
        view.onSystemKeyInjectorReady = onSystemKeyInjectorReady
        view.publishSystemKeyInjector()
        // BUG-2 probe: a recreate (makeNSView) on focus change — vs an in-place updateNSView — would reset
        // isActive to its `true` default mid-stream; logging it distinguishes "stale Bool" from "recreate".
        videoViewDbg("makeNSView (CREATED) isActive=\(isActive)")
        return view
    }

    func updateNSView(_ nsView: MetalLayerBackedView, context _: Context) {
        nsView.controls = controls
        if nsView.isActive != isActive { videoViewDbg("updateNSView isActive \(nsView.isActive)→\(isActive)") }
        nsView.isActive = isActive
        // READ-ONLY INPUT GATE: apply the current gate every render. On a FLIP, re-publish the
        // paste-as-keystrokes sink so the seam's `onKeyInjectorReady` (which binds a nil sink while read-only)
        // re-evaluates — locking a live pane withholds the sink, unlocking restores it, with no view rebuild.
        let inputGateFlipped = nsView.inputEnabled != inputEnabled
        nsView.inputEnabled = inputEnabled
        nsView.onActivate = onActivate
        nsView.onCanvasScroll = onCanvasScroll
        nsView.onStreamNativeSize = onStreamNativeSize
        // VIEWPORT CONTROLS: keep the bind closure current (the model persists per pane, so the published
        // sink stays valid — no re-publish needed; it is not read-only-gated).
        nsView.onViewportInjectorReady = onViewportInjectorReady
        // HOST-WINDOW RESIZE: keep the geometry push current (model persists per pane).
        nsView.onWindowGeometryReady = onWindowGeometryReady
        // CONNECTION STATS: keep the cadence + bitrate pushes current (model persists per pane).
        nsView.onStreamCadenceReady = onStreamCadenceReady
        nsView.onStreamBitrateReady = onStreamBitrateReady
        // NETWORK-STATS MIRROR: keep the ~2 Hz aggregate push current (model persists per pane).
        nsView.onNetworkStatsReady = onNetworkStatsReady
        // STALL SCRIM: keep the stall push current (model persists per pane).
        nsView.onStreamStallReady = onStreamStallChanged
        // TERMINAL REFUSAL: keep the rejection push current (model persists per pane).
        nsView.onSessionRejectedReady = onSessionRejected
        nsView.activate(connection: connection)
        if inputGateFlipped {
            nsView.onKeyInjectorReady = onKeyInjectorReady
            nsView.publishKeyInjector()
            // RESIZE GRIP: the seam binds a nil resize sink while read-only (like the key sink), so a
            // read-only flip must re-publish to withdraw / restore the grip's drive.
            nsView.onResizeInjectorReady = onResizeInjectorReady
            nsView.publishResizeInjector()
            // RELEASE STUCK INPUT (C5): read-only-gated like the key sink — a flip re-evaluates the seam's
            // nil-binding so a locked pane withdraws the escape hatch and an unlock restores it.
            nsView.onInputReleaseReady = onInputReleaseReady
            nsView.publishInputReleaseInjector()
            // STREAM SETTINGS + SYSTEM KEYS: read-only-gated like the resize/key sinks — a flip
            // re-evaluates the seam's nil-binding (lock withholds, unlock restores).
            nsView.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
            nsView.publishStreamSettingsInjector()
            nsView.onSystemKeyInjectorReady = onSystemKeyInjectorReady
            nsView.publishSystemKeyInjector()
        }
    }

    static func dismantleNSView(_ nsView: MetalLayerBackedView, coordinator _: ()) {
        nsView.deactivate()
    }
}

/// A layer-backed `NSView` whose backing layer is a `CAMetalLayer`, with a cursor
/// overlay layer on top. It owns the client pipeline for its lifetime.
final class MetalLayerBackedView: NSView {
    let videoLayer = CAMetalLayer()
    private let pipeline = VideoWindowPipeline()

    /// Whether THIS pane is the canvas's active/focused pane. Only the active pane forwards
    /// pointer/scroll to the remote window; a non-active pane routes a scroll to ``onCanvasScroll`` (so
    /// scroll navigates the canvas) and ignores hover, matching the terminal pane's `isFocusedPane` rule.
    /// Set by `MetalVideoLayerView` on every render (reactive to focus changes). On change it re-applies
    /// the local cursor — a pane losing focus must drop the host shape back to the arrow even if the
    /// pointer never moved.
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { applyLocalCursor()
                return
            }
            applyLocalCursor()
            if isActive {
                // FOCUS CLAIM (BUG-1): this pane became the workspace-focused pane WITHOUT a click inside the
                // surface (a tab switch / pane-focus keybinding). Panes stay mounted under keep-all-mounted, so
                // the view is never remounted and `viewDidMoveToWindow`'s mount-time claim can't re-fire — claim
                // the keyboard here so typing reaches the remote window instead of the previously focused
                // (possibly hidden) terminal. Mirrors the terminal pane's `isFocusedPane` false→true path.
                claimKeyboardFocus()
                // MODIFIER RESYNC (BUG-2): a modifier genuinely still held at refocus must be re-established
                // (its down `flagsChanged` was delivered to the OLD responder), else a chord starts a key short.
                resyncModifiersFromCurrentFlags()
                // REFOCUS SHAPE RESYNC: when this pane REGAINS focus with the pointer already inside (e.g.
                // the user clicked away to a terminal pane then tabbed/clicked back), the host cursor is
                // frozen at its last-forwarded spot — hover moves aren't forwarded while inactive — so the
                // remote SHAPE is stale (an I-beam sitting over a resize edge) until the user jiggles the
                // mouse. Warp the host cursor to the LIVE pointer now so the correct shape ships next tick.
                resyncPointerToHost()
            } else {
                // MODIFIER UNLATCH (BUG-2): a modifier forwarded as down whose release we will no longer see
                // (focus moved to another pane) would stay latched in the host's shared hidSystemState event
                // source, so a later plain scroll rides ⌘ (the remote page zooms). Release them now.
                releaseLatchedModifiers()
            }
        }
    }

    /// READ-ONLY INPUT GATE. `false` ⇒ this pane is read-only: every pointer/scroll/keycode relay
    /// to the host is suppressed (gated `isActive && inputEnabled`; a drag/up forward checks `inputEnabled`
    /// alone since it only follows a `mouseDown` that already passed the gate). A click still ACTIVATES the
    /// workspace pane but is not relayed and the host window is not raised. The paste-as-keystrokes sink is
    /// withheld by the seam (a `nil` `keyInjector`). Set by `MetalVideoLayerView` on every render.
    var inputEnabled: Bool = true

    // ── CURSOR (Parsec model): the host streams its cursor SHAPE (cached bitmaps); the OS draws that
    //    shape on the LOCAL cursor at the INSTANT mouse position — zero added latency, and exactly ONE
    //    cursor because macOS does NOT composite the host's RTT-delayed POSITION overlay. While the
    //    pointer is inside an ACTIVE pane and the host cursor is visible we set the host's shape; in a
    //    `.fit` letterbox margin / host-hidden-cursor / a background pane we keep the plain arrow.
    //    `pointerInside` gates the work to when the pointer is actually over this view.
    private var pointerInside = false
    /// MODIFIER LATCH (BUG-2): which modifier keyCodes this view has forwarded to the host as "down" but not
    /// yet released. On focus loss (pane blur / FR resign / window-resign-key on ⌘-Tab away) we synthesize the
    /// missing key-ups so the host's shared hidSystemState source does not keep the modifier latched (which
    /// would make a later plain scroll a ⌘-scroll = zoom). Pure logic lives in ``ModifierLatchTracker``.
    private var modifierLatch = ModifierLatchTracker()
    /// Observer token for the current window's ``NSWindow/didResignKeyNotification`` — releases any latched
    /// modifiers when the window loses key (⌘-Tab away / clicking another app) while a modifier is held, since
    /// that path delivers NO release `flagsChanged` and does NOT call `resignFirstResponder` (the view stays
    /// first responder). Re-scoped to the live window on every `viewDidMoveToWindow` (mirrors the terminal pane).
    private var windowResignKeyObserver: NSObjectProtocol?
    /// Make this pane the active pane — called at the top of `mouseDown` (click-to-activate). Sets the
    /// *workspace* focus; the host window is raised separately via `pipeline.focusWindow()`.
    var onActivate: () -> Void = {}
    /// Pan the canvas by a (sign-adjusted) delta — called from `scrollWheel` when this pane is NOT active.
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    /// 1:1 PANE SNAP: ask the canvas pane to resize its video content from `current` to `target`
    /// points so the stream renders pixel-for-pixel. `nil` ⇒ standalone (no pane). Set by the
    /// representable BEFORE ``activate(connection:)`` — its nil-ness picks pane-follows-stream
    /// vs the legacy connect-time host-follow when the session's GUI hooks are built.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    /// PASTE AS KEYSTROKES: the canvas publishes a key-injection sink through this (and `nil` on
    /// teardown), so the pane's "Paste as Keystrokes" can drive `pipeline.key(...)` — the same
    /// secure-input-aware key path the keyboard uses. Set by the representable before `activate`.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    /// RESIZE (numeric popover): the canvas publishes a resize-drive sink through this (and `nil` on
    /// teardown), so the pane's "Resize…" popover can request an ABSOLUTE host-window POINT size.
    /// `(width, height)` in host points.
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    /// HOST-WINDOW RESIZE: the canvas publishes a geometry SINK through this — the view pushes the window's
    /// current + max resizable POINT sizes whenever either changes so the "Resize…" popover pre-fills +
    /// caps its fields. `(curW, curH, maxW, maxH)`; a zero max = "not yet known". Set by the representable.
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    /// CONNECTION STATS: the canvas publishes a cadence SINK through this — the view pushes the host-announced
    /// stream fps whenever the host's FPS governor announces a new value so the sidebar's Connection section
    /// shows a per-pane "FPS" row. Set by the representable.
    var onStreamCadenceReady: ((Int) -> Void)?
    /// CONNECTION STATS: the canvas publishes a bitrate SINK through this — the view pushes the ~1 Hz
    /// client-measured video PAYLOAD bitrate (kilobits/sec) for the titlebar's stream-weight complication.
    /// Set by the representable.
    var onStreamBitrateReady: ((Int) -> Void)?
    /// NETWORK-STATS MIRROR: the canvas publishes a stats SINK through this — the view pushes the ~2 Hz
    /// client-local aggregate `(fps, fecPerSec, unrecoveredPerSec, holdMs, pacerDepth)` for the pane's
    /// stats surface. Set by the representable.
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int) -> Void)?
    /// STREAM SETTINGS: the canvas publishes a settings-drive sink through this (and `nil` on teardown;
    /// the seam binds nil while read-only — host-affecting, like the resize sink). `(fpsCap,
    /// bitrateCeilingBps)`, 0 = auto. Set by the representable.
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    /// SYSTEM-KEY INJECTOR: the canvas publishes a programmatic key sink through this (and `nil` on
    /// teardown; the seam binds nil while read-only — host input, like the paste-keystrokes sink).
    /// `(keyCode, modifierFlags [raw NSEvent flags], isDown)`. Set by the representable.
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    /// STALL SCRIM: the canvas publishes a stall SINK through this — the view pushes the pipeline's stall
    /// flips (`true` ⇒ host silent past threshold, show "Reconnecting…"; `false` ⇒ traffic resumed) so the
    /// pane can overlay/clear its scrim. Set by the representable.
    var onStreamStallReady: ((Bool) -> Void)?
    /// TERMINAL REFUSAL: the canvas publishes a rejection SINK through this — the view fires it once
    /// after the host rejected the session (`helloAck(accepted: false)`), the pipeline having already
    /// torn down with NO auto-rebuild, so the pane model can fall back to the picker/error state.
    /// Set by the representable.
    var onSessionRejectedReady: (() -> Void)?
    /// VIEWPORT CONTROLS: the canvas publishes a client-viewport command sink through this (and `nil` on
    /// teardown), so the pane's bottom control bar drives zoom / pan-lock. The byte is `RemoteWindowModel.
    /// ViewportCommand` (0 zoom-in / 1 zoom-out / 2 reset / 3 toggle-lock). Set by the representable.
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    /// RELEASE STUCK INPUT (C5): the canvas publishes a zero-arg release sink through this (and `nil` on
    /// teardown; the seam binds nil while read-only) — the palette's chord-less escape hatch fires it to
    /// synthesize a key-UP for every held modifier + a mouse-UP for every button. Set by the representable.
    var onInputReleaseReady: (((() -> Void)?) -> Void)?

    /// Hands the canvas a key-injection closure routed to THIS view's pipeline (Shift folded into the
    /// modifiers; `pipeline.key` no-ops until the session is up). Idempotent — safe to call on every
    /// render; the sink captures `self` weakly so a torn-down view injects nothing.
    func publishKeyInjector() {
        onKeyInjectorReady? { [weak self] keyCode, down, shift in
            self?.pipeline.key(keyCode: keyCode, down: down, modifiers: shift ? .shift : [])
        }
    }

    /// Hands the canvas a resize-drive closure routed to THIS view's pipeline: an ABSOLUTE host-window
    /// POINT size the session debounce-requests. `self` weak so a torn-down view resizes nothing.
    func publishResizeInjector() {
        onResizeInjectorReady? { [weak self] width, height in
            self?.pipeline.userResizeTo(width: width, height: height)
        }
    }

    /// Hands the canvas a stream-settings drive routed to THIS view's pipeline (fps cap / bitrate
    /// ceiling, 0 = auto; the session stores + re-sends after every re-hello). `self` weak so a
    /// torn-down view requests nothing. Idempotent — safe to call on every render.
    func publishStreamSettingsInjector() {
        onStreamSettingsInjectorReady? { [weak self] fpsCap, bitrateCeilingBps in
            self?.pipeline.updateStreamSettings(fpsCap: fpsCap, bitrateCeilingBps: bitrateCeilingBps)
        }
    }

    /// Hands the canvas a programmatic key drive routed through the SAME `pipeline.key` path the
    /// local `keyDown`/`keyUp` overrides use, so an injected key is indistinguishable on the wire
    /// from a typed one. The raw flags are the caller's `NSEvent.ModifierFlags.rawValue` (UInt64 at
    /// the headless seam); the mapping to ``InputModifiers`` is the keyboard path's own
    /// ``modifiers(_:)``. `self` weak so a torn-down view injects nothing. Idempotent.
    func publishSystemKeyInjector() {
        onSystemKeyInjectorReady? { [weak self] keyCode, rawModifierFlags, isDown in
            let flags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: rawModifierFlags))
            self?.pipeline.key(keyCode: keyCode, down: isDown, modifiers: Self.modifiers(flags))
        }
    }

    /// Hands the canvas a client-viewport command closure routed to THIS view (zoom the compositor sublayer /
    /// freeze the edge-pan). `self` weak so a torn-down view does nothing. Idempotent.
    func publishViewportInjector() {
        onViewportInjectorReady? { [weak self] command in self?.handleViewportCommand(command) }
    }

    /// Hands the canvas the RELEASE STUCK INPUT closure (C5) routed to THIS view. `self` weak so a
    /// torn-down view releases nothing. Idempotent — safe to call on every render.
    func publishInputReleaseInjector() {
        onInputReleaseReady? { [weak self] in self?.releaseAllStuckInput() }
    }

    /// RELEASE STUCK INPUT (C5, the manual escape hatch): synthesize a key-UP for EVERY held-modifier
    /// keyCode (left/right ⌘⇧⌃⌥ + fn — not only the locally-latched ones; the point is a HOST stuck
    /// despite the automatic paths) plus a mouse-UP for every button, through the same send paths the
    /// automatic synthetic releases use. Each modifier key-up rides the loss-resilient redundant send
    /// (`keySendCount`) and each mouse-up the `redundantUpCount` burst; the host's `InputButtonBalance`
    /// suppresses whichever releases are no-ops there (an already-up modifier / button posts nothing),
    /// so firing this on a healthy session is harmless. The local latch is drained first so the
    /// client's own bookkeeping agrees that nothing is held. Read-only panes never reach here (the seam
    /// withholds the sink), but keep the `inputEnabled` gate as belt-and-braces.
    private func releaseAllStuckInput() {
        guard inputEnabled else { return }
        _ = modifierLatch.drainForRelease()
        for keyCode in InputModifierKeys.heldModifierKeyCodes.sorted() {
            pipeline.key(keyCode: keyCode, down: false, modifiers: [])
        }
        // The release position is immaterial to un-sticking (the target app just ends its tracking);
        // the pane centre keeps it inside the captured window.
        let centre = VideoPoint(x: Double(bounds.midX), y: Double(bounds.midY))
        for button in [MouseButton.left, .right, .other] {
            pipeline.mouseUp(button, centre, 1, [])
        }
    }

    /// Apply one viewport command from the footer control bar (the `RemoteWindowModel.ViewportCommand` byte:
    /// 0 zoom-in / 1 zoom-out / 2 reset / 3 toggle-lock).
    private func handleViewportCommand(_ command: UInt8) {
        switch command {
        case 0: applyZoom(1.25) // zoom in one step
        case 1: applyZoom(1.0 / 1.25) // zoom out one step
        case 2: applyResetZoom() // 1× + re-anchor top-left
        case 3: // toggle "lock position" (freeze edge-pan)
            panLocked.toggle()
            if panLocked { stopEdgePan() }
        default: break
        }
    }

    /// Multiply ``clientZoom`` by `factor` (clamped to `[0.25, 4]`, snapped to 1× near unity) and re-anchor so
    /// the PANE CENTRE stays fixed across the zoom — you zoom toward the middle of what you're looking at. A
    /// no-op until the host window's point size is known (`streamPoints`).
    private func applyZoom(_ factor: CGFloat) {
        guard let win = streamPoints, win.width > 1, win.height > 1 else { return }
        let oldZoom = clientZoom
        var newZoom = Swift.min(Swift.max(clientZoom * factor, 0.25), 4.0)
        if abs(newZoom - 1) < 0.06 { newZoom = 1.0 } // snap near 1× so repeated steps settle exactly to actual-size
        guard newZoom != oldZoom else { return }
        // The displayed window size is native × zoom; keep the pane-centre texture fraction constant.
        let oldDW = CGFloat(win.width) * oldZoom, oldDH = CGFloat(win.height) * oldZoom
        let centreFracX = (panOffset.x + bounds.width / 2) / Swift.max(oldDW, 1)
        let centreFracY = (panOffset.y + bounds.height / 2) / Swift.max(oldDH, 1)
        clientZoom = newZoom
        let newDW = CGFloat(win.width) * newZoom, newDH = CGFloat(win.height) * newZoom
        panOffset.x = centreFracX * newDW - bounds.width / 2
        panOffset.y = centreFracY * newDH - bounds.height / 2
        needsLayout = true
        layoutVideoLayer() // clamps panOffset to the new overflow + republishes the input viewport
    }

    /// Bridge to the SwiftUI control overlay; the SwiftUI view owns it. Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?

    // ── ACTUAL-SIZE VIEWPORT (RealVNC-mobile). The host sends + the client decodes the WHOLE
    //    window every frame; the renderer draws the whole window at its native resolution into `videoLayer`,
    //    which is sized to the window's POINT size and added as a SUBLAYER of this view's clipping backing
    //    layer. The pane is a fixed viewport: we PAN by translating `videoLayer` (a compositor move — smooth,
    //    no per-frame reshader) instead of cropping the texture. Edge-hover drives the translation. The
    //    visible sub-rect is reported to the session as a `viewportCrop` so a pane click maps to the right
    //    host pixel. Window point size arrives via `onDecodedPointsChanged`.
    /// The host window's current POINT size. `nil` until the first decoded frame (then the layer is sized).
    private var streamPoints: VideoSize?
    /// HOST-WINDOW RESIZE: the host-reported MAX resizable POINT size (its display bounds). `nil` until the
    /// host's `displayMax` lands; the "Resize…" popover leaves its fields uncapped until then.
    private var displayMaxPoints: VideoSize?
    /// The viewport's top-left offset INTO the window, in WINDOW POINTS (top-left origin, +y down). `(0,0)`
    /// = the window's top-left corner (default). Clamped to `[0, max(0, window − pane)]`; pan moves it.
    private var panOffset: CGPoint = .zero
    /// Whether the user has explicitly PANNED (edge-pan). Until then the offset stays at the window top-left
    /// (the default anchor, not centred); the 1× reset clears it.
    private var viewportTouched = false
    /// CLIENT ZOOM factor (1.0 = actual-size, >1 zoomed-in, <1 minified), driven by the footer zoom controls.
    /// Pure COMPOSITOR scale: the video sublayer FRAME is scaled by this while the drawable stays at the
    /// native window pixel size (CA scales the native-res texture — no reshader, no host round-trip). Clamped
    /// to `[0.25, 4]`; the 1× reset clears it. The decoded frame is native-res, so zoom-in magnifies
    /// (interpolated beyond native) and zoom-out minifies crisply.
    private var clientZoom: CGFloat = 1.0
    /// PAN LOCK ("lock position"): when true the edge-hover auto-pan is FROZEN — the viewport stays put even as
    /// the pointer nudges the pane edges. Toggled by the footer lock control; clears its timer on engage.
    private var panLocked = false

    // ── EDGE-PAN (RealVNC-mobile): nudging the pointer into a pane edge auto-translates the video layer
    //    toward that edge so you can reach off-screen window content without a scroll gesture. Driven by a
    //    `.common`-mode timer (a default-mode timer would freeze during event tracking). Inert when the
    //    window fits inside the pane.
    private var edgePanTimer: Timer?
    private var edgePanVelocity: CGPoint = .zero
    /// Last pointer position in this view's coordinates (AppKit, origin bottom-left) — re-forwarded each
    /// edge-pan tick so the host cursor follows into the newly revealed region while the content scrolls.
    private var lastPointerView: CGPoint = .zero
    /// Pane-edge band width (points) within which the pointer triggers an auto-pan.
    private static let edgePanThreshold: CGFloat = 44
    /// Full-penetration pan speed (WINDOW POINTS per second) at the pane border.
    private static let edgePanPointsPerSec: Double = 1600

    // ── SWIPE-PEEL feedback (doc 05 §8): a local mirror of the HOST's swipe-nav recogniser gives
    //    the one piece of native swipe-back a key translation can't — the page reacting WHILE the
    //    fingers are on the glass. The page FOLLOWS the fingers ~1:1 (`videoLayer.transform`, a
    //    channel `layoutVideoLayer`'s frame writes never touch) over a flat underlay, the chip
    //    publishes through `controls`, and a fired gesture plays the commit choreography: the
    //    outgoing page freezes into a snapshot and slides off while the post-navigation page
    //    streams in underneath — masking the inject→capture→stream round trip the way Safari's
    //    snapshot swap masks its own load. The host stays the sole authority on firing ⌘[/⌘].
    private var peelPlanner = SwipePeelPlanner()
    /// The host's swipe-nav operating point (cursor-socket type=3 push). `nil` until the first
    /// push — an old host never shows the overlay, so the affordance can't lie.
    private var peelStatus: SwipeNavStatusMessage?
    /// Rising-edge tracker for the commit haptic (tap once when "release now navigates" starts).
    private var peelChipCommitted = false
    /// Delayed clear of the confirm-pulse chip after a fire.
    private var peelConfirmClear: Task<Void, Never>?
    /// The flat backdrop revealed behind the page while it follows the fingers (below
    /// `videoLayer` in the clipping host layer; the chip floats over it as the affordance —
    /// MERIDIAN flat, no ornament). Built lazily on first show, hidden when the peel concludes.
    private var peelUnderlay: CALayer?
    /// A thin gradient hugging the sliding page's edge inside the revealed gap — the page
    /// "casts" onto the underlay, reading as depth without any blur/material over metal.
    private var peelUnderlayShade: CAGradientLayer?
    /// The commit choreography's frozen outgoing page (a plain layer over `videoLayer`).
    private var peelSnapshotLayer: CALayer?
    /// The hold-then-slide driver for ``peelSnapshotLayer``.
    private var peelSnapshotSlide: Task<Void, Never>?
    /// One-shot NV12→RGB conversion context for the commit snapshot (class-level: CIContext
    /// construction is expensive; first touched on the first commit, GUI-only — this class
    /// never runs headless, per the no-Metal-in-unit-tests law).
    private static let peelSnapshotContext = CIContext()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The video layer is an oversized SUBLAYER (sized to the whole remote window) of a CLIPPING backing
        // layer, so we can translate it for panning while the pane masks the overflow — making it the
        // backing layer directly would leave nothing to clip the overflow against.
        wantsLayer = true
        // MERIDIAN DRAIN: allow CI filters on the layer tree (the stall desaturation below). The flag alone
        // does not change the live compositing path — the expensive in-process render kicks in only while a
        // filter is actually ATTACHED, and we attach one only over a STALLED (frozen, no new presents) frame,
        // so the 60fps hot path never pays for it.
        layerUsesCoreImageFilters = true
        let host = CALayer()
        host.masksToBounds = true
        host.addSublayer(videoLayer)
        layer = host
    }

    /// MERIDIAN L1 — "colour is live data, grayscale is the past": while the stream is STALLED the frozen
    /// last frame drains to grayscale (slightly darkened), so the material itself says "this is the past"
    /// instead of a dim veil hiding it. Applied to `videoLayer` (the cursor overlay is its sublayer, so it
    /// drains with the surface — correct: the whole picture is stale). Removed the instant traffic resumes;
    /// sticky through the self-heal rebuild exactly like the stall latch that drives it.
    private func applyStallDrain(_ stalled: Bool) {
        if stalled {
            guard let drain = CIFilter(
                name: "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.0, kCIInputBrightnessKey: -0.06],
            ) else { return }
            drain.name = "stallDrain"
            videoLayer.filters = [drain]
        } else {
            videoLayer.filters = nil
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    func activate(connection: VideoWindowConnection?) {
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate: the session decides pane-follows-stream
        // (snap) vs the legacy connect-time host-follow by whether this hook exists when the GUI
        // hooks are built. The closure reads the live `onStreamNativeSize`, so updateNSView
        // refreshing the seam closure stays picked up without re-activation.
        pipeline.onStreamNativePoints = onStreamNativeSize == nil ? nil : { [weak self] points in
            self?.adoptStreamNativePoints(points)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        // Re-apply the local cursor when the host SWAPS shape, or when the host cursor enters/leaves the
        // captured window (visible flip) — so the pointer shape tracks the remote with no RTT lag.
        pipeline.onServerCursorVisibilityChanged = { [weak self] _ in self?.applyLocalCursor() }
        pipeline.onRemoteCursorChanged = { [weak self] in self?.applyLocalCursor() }
        // ACTUAL-SIZE VIEWPORT: learn the host window's point size, size the video layer to it, lay out.
        pipeline.onDecodedPointsChanged = { [weak self] points in
            guard let self else { return }
            streamPoints = points
            needsLayout = true
            layoutVideoLayer()
            publishWindowGeometry() // the popover's current-size pre-fill tracks the live window size
        }
        // HOST-WINDOW RESIZE: learn the captured window's display max so the "Resize…" popover caps its
        // fields at a size the remote can actually adopt.
        pipeline.onDisplayMaxChanged = { [weak self] points in
            guard let self else { return }
            displayMaxPoints = points
            publishWindowGeometry()
        }
        // SWIPE-PEEL: adopt the host's swipe-nav operating point (eligibility + recogniser knobs)
        // so the feedback mirror always predicts what the host will actually do.
        pipeline.onSwipeNavStatusChanged = { [weak self] status in self?.adoptSwipeNavStatus(status) }
        // CONNECTION STATS: forward the host-announced stream cadence to the model's FPS row (no-op if unbound).
        pipeline.onStreamCadenceChanged = { [weak self] fps in self?.onStreamCadenceReady?(fps) }
        pipeline.onStreamBitrateChanged = { [weak self] kbps in self?.onStreamBitrateReady?(kbps) }
        // NETWORK-STATS MIRROR: flatten the snapshot to primitives at the seam (the model side is
        // headless — it never imports this module's types). No-op if unbound.
        pipeline.onNetworkStatsChanged = { [weak self] snapshot in
            self?.onNetworkStatsReady?(
                snapshot.framesPerSecond,
                snapshot.fecRecoveredPerSecond,
                snapshot.unrecoveredPerSecond,
                snapshot.holdMillis,
                snapshot.pacerDepth,
            )
        }
        // STALL: drain THIS surface to grayscale (MERIDIAN L1 — the material says "stale", see
        // `applyStallDrain`) and forward the flip to the pane model (→ the corner age caption; no-op if
        // unbound). The closure reads the live `onStreamStallReady`, so updateNSView refreshing the seam
        // closure is picked up.
        pipeline.onStreamStallChanged = { [weak self] stalled in
            self?.applyStallDrain(stalled)
            self?.onStreamStallReady?(stalled)
        }
        // TERMINAL REFUSAL: forward the host's rejection to the pane model (→ picker/error state; no-op
        // if unbound). The pipeline already tore itself down with NO auto-rebuild before firing. The
        // closure reads the live `onSessionRejectedReady`, so updateNSView refreshing the seam closure
        // is picked up.
        pipeline.onSessionRejected = { [weak self] in self?.onSessionRejectedReady?() }
        // Wire the SwiftUI overlay's buttons to THIS view's pipeline (live connection only). No fit/fill
        // toggle: the ACTUAL-SIZE viewport auto-drives content mode, so only the 1× reset wires.
        if connection != nil, let controls {
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    /// HOST-WINDOW RESIZE: push the window's current + max resizable POINT sizes to the canvas (→ model)
    /// so the "Resize…" popover pre-fills its fields at the current size and caps them at the remote max.
    /// A zero max (display max not yet reported) tells the model to leave the field uncapped. No-op until
    /// the current size is known (first decoded frame) or when no canvas wired the sink.
    private func publishWindowGeometry() {
        guard let cur = streamPoints else { return }
        onWindowGeometryReady?(cur.width, cur.height, displayMaxPoints?.width ?? 0, displayMaxPoints?.height ?? 0)
    }

    func deactivate() {
        if pointerInside { NSCursor.arrow.set() } // restore the arrow before the pipeline tears down
        pointerInside = false
        abandonSwipePeel() // never strand a mid-gesture peel/chip across a teardown
        clearPeelSnapshot() // nor a mid-flight commit choreography
        // Forget the host's eligibility across a teardown: a remounted surface must stay dark
        // until the NEXT status push (≤2 s heartbeat) instead of trusting a stale operating
        // point from a possibly-restarted host (audit: stale-eligible window).
        peelStatus = nil
        // Deliberately NO nil-publish of the injector sinks here: `RemoteWindowModel.close()` clears its
        // own sinks (model lifecycle, always BEFORE a re-open in store order). During a pane
        // detach/reattach the SAME model is re-bound by a replacement view in ANOTHER hosting root, and
        // SwiftUI may dismantle THIS view AFTER that view already published fresh sinks — an
        // unconditional nil-publish here would silently kill the new surface's input.
        pipeline.deactivate()
    }

    /// 1:1 PANE SNAP: the stream's decoded size changed (first frame, or the host re-captured
    /// after a window resize). The session already converted it to the HOST WINDOW's POINT size
    /// (`points`, = decoded pixels / the inferred host captureScale — NOT the client contentsScale,
    /// which halved the pane on a 1× capture). Rebase the session's resize debounce on it FIRST
    /// (so the snap-induced layout pass holds instead of echoing a `resizeRequest` back to the
    /// host — the snap is client-side only), then ask the canvas pane to adopt it. Skips the pane
    /// mutation for a sub-half-point delta (already at the native size; the rebase alone suffices).
    private func adoptStreamNativePoints(_ points: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        pipeline.adoptLayerSize(points)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: points, current: current) else { return }
        videoViewDbg(
            "1:1 snap → video \(Int(current.width))x\(Int(current.height)) → \(Int(points.width))x\(Int(points.height))pt (host window points)",
        )
        handler(
            CGSize(width: points.width, height: points.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    // MARK: Local cursor (Parsec model — host shape on the instant local pointer)

    /// Sets the local OS cursor to the host's CURRENT shape while the pointer is inside an ACTIVE pane
    /// and the host cursor is visible there; otherwise the plain arrow. The OS draws it at the live mouse
    /// position so there's no RTT lag, and macOS composites no host-position overlay so there's no
    /// duplicate. No-op unless the pointer is over this view (so a shape swap elsewhere can't hijack the
    /// global cursor).
    private func applyLocalCursor() {
        guard pointerInside else { return }
        if isActive, pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor {
            cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Forward `winLoc` (window-space, as delivered by `NSEvent.locationInWindow`) to the host as a
    /// bare mouse-move so the host cursor WARPS to the client pointer — resyncing the remote cursor
    /// SHAPE without waiting for the next hover move. Gated exactly like `mouseMoved`.
    private func forwardPointer(atWindowLocation winLoc: NSPoint) {
        guard isActive, inputEnabled else { return }
        let p = convert(winLoc, from: nil)
        pipeline.mouseMove(VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y)))
    }

    /// Resync WITHOUT an event (a tab/keyboard refocus where the pointer is already inside and never
    /// moved): read the live pointer from the window and warp the host cursor to it, so a refocused
    /// pane doesn't sit on a stale host cursor shape until the user jiggles the mouse.
    private func resyncPointerToHost() {
        guard pointerInside, let window else { return }
        forwardPointer(atWindowLocation: window.mouseLocationOutsideOfEventStream)
    }

    /// FOCUS CLAIM (BUG-1): make this view first responder so the keyboard follows workspace focus. Deferred
    /// off the SwiftUI update/commit pass (a synchronous `makeFirstResponder` rebuilds the AppKit responder
    /// chain and stalls the main thread inside `updateNSView` on a tab/pane switch) and guarded so a pane that
    /// lost focus again before the hop, or is already first responder, is a no-op. Mirrors the terminal pane.
    private func claimKeyboardFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, isActive, let window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    /// MODIFIER UNLATCH (BUG-2): synthesize a host key-up for every modifier this view forwarded as down but
    /// whose release `flagsChanged` it will not see (focus moved away), clearing the host's latched flag so a
    /// subsequent scroll / mouse-move (which carry no explicit flags) is not treated as modifier-held. Idempotent
    /// — a no-op when nothing is latched. Uses an empty modifier mask so the emitted key-up itself clears cleanly.
    private func releaseLatchedModifiers() {
        for keyCode in modifierLatch.drainForRelease() {
            pipeline.key(keyCode: keyCode, down: false, modifiers: [])
        }
    }

    /// MODIFIER RESYNC (BUG-2): on regaining focus, re-establish any modifier that is STILL physically held —
    /// its down `flagsChanged` went to the previously focused responder, so without this the host would not
    /// know the modifier is down (a chord would start a key short). Reads the live global flags (there is no
    /// event on a keyboard/tab refocus). Gated exactly like the other relays (`isActive && inputEnabled`).
    private func resyncModifiersFromCurrentFlags() {
        guard isActive, inputEnabled else { return }
        let flags = NSEvent.modifierFlags
        for keyCode in Self.heldModifierKeyCodes(flags) where !modifierLatch.isDown(keyCode) {
            modifierLatch.note(keyCode: keyCode, down: true)
            pipeline.key(keyCode: keyCode, down: true, modifiers: Self.modifiers(flags))
        }
    }

    /// A representative modifier keyCode (left variant) for each modifier currently present in `flags` — used
    /// by ``resyncModifiersFromCurrentFlags`` to re-forward a still-held modifier on refocus. The left keyCode
    /// is arbitrary but consistent: the host only cares about the resulting latched flag, not left-vs-right.
    /// Caps Lock is deliberately ABSENT (C5 BUG A): `.capsLock` in `flags` is a TOGGLE STATE, not a
    /// held key — re-forwarding it as a key-down would make the host post virtualKey 57 and FLIP the
    /// remote Caps state on every refocus (and the matching latch release flipped it again on blur).
    static func heldModifierKeyCodes(_ flags: NSEvent.ModifierFlags) -> [UInt16] {
        var codes: [UInt16] = []
        if flags.contains(.command) { codes.append(55) }
        if flags.contains(.shift) { codes.append(56) }
        if flags.contains(.control) { codes.append(59) }
        if flags.contains(.option) { codes.append(58) }
        if flags.contains(.function) { codes.append(63) }
        return codes
    }

    override func layout() {
        super.layout()
        layer?.masksToBounds = true // clip the oversized video sublayer to the pane
        layoutVideoLayer()
        // session.layerSize = the PANE point size (the input/cursor denominator). The DRAWABLE pixel size is
        // owned by `layoutVideoLayer()` (window-sized); the pipeline does not touch it.
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }

    /// ACTUAL-SIZE VIEWPORT: size + position the oversized video sublayer. It is sized to the remote
    /// window's POINT size (so the renderer draws the WHOLE window at native res into a window-sized
    /// drawable), and positioned so the visible pane shows the region at `panOffset` (top-left anchored by
    /// default). Pure compositor geometry — panning later just moves this layer, no reshader. Falls back to
    /// filling the pane until the window size is known.
    private func layoutVideoLayer() {
        // layer-HOSTING views (we assign `layer`) are NOT auto-promoted to the window's backing scale, so set
        // contentsScale from `backingScaleFactor` (never hardcode 2 — 1× externals/Sidecar); fall back to the
        // last good value so a window==nil teardown layout never drops to 1×.
        let scale = window?.backingScaleFactor ?? videoLayer.contentsScale
        layer?.contentsScale = scale
        videoLayer.contentsScale = scale
        // No implicit position/size animation — panning sets these directly each tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let win = streamPoints, win.width > 1, win.height > 1, bounds.width > 1, bounds.height > 1 else {
            // No stream geometry yet → fill the pane (the renderer aspect-fits the first frames).
            videoLayer.frame = bounds
            videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            return
        }
        // The DISPLAYED window size is the native point size × the client zoom (a compositor scale of the
        // sublayer FRAME); the drawable stays at the NATIVE pixel size below, so CA scales the native-res
        // texture — no reshader. `dw`/`dh` drive the frame + the pan clamp; `win` drives the drawable.
        let dw = CGFloat(win.width) * clientZoom, dh = CGFloat(win.height) * clientZoom
        // Clamp the pan offset to the overflow on each axis (0 when the zoomed window fits → top-left anchored).
        let maxX = Swift.max(0, dw - bounds.width)
        let maxY = Swift.max(0, dh - bounds.height)
        if !viewportTouched, clientZoom == 1 { panOffset = .zero } // only auto-anchor at the untouched 1× default
        panOffset.x = Swift.min(Swift.max(panOffset.x, 0), maxX)
        panOffset.y = Swift.min(Swift.max(panOffset.y, 0), maxY)
        // Position (parent layer is bottom-left origin): origin.x = −panOffset.x; origin.y places the window
        // TOP at the pane top and reveals lower content as panOffset.y grows (derived for y-down panOffset).
        videoLayer.frame = CGRect(x: -panOffset.x, y: bounds.height - dh + panOffset.y, width: dw, height: dh)
        videoLayer.drawableSize = CGSize(width: CGFloat(win.width) * scale, height: CGFloat(win.height) * scale)
        publishInputViewport()
    }

    /// Report the currently-visible texture sub-rect (UV) to the session so a pane click maps to the right
    /// host pixel. `origin = panOffset / window`, `size = pane / window` (size may exceed 1 when the window
    /// is smaller than the pane — `normalize` then clamps a click outside the window, which is correct).
    private func publishInputViewport() {
        guard let win = streamPoints, win.width > 1, win.height > 1 else { pipeline.setInputViewport(nil)
            return
        }
        // The visible sub-rect is reported in TEXTURE (native-window) fractions. With zoom the displayed window
        // is native × zoom, so divide the display-space pan offset / pane size by the DISPLAYED size `dw`/`dh`
        // (= native × zoom) — equivalent to dividing the texture-space offset by the native size.
        let dw = win.width * Double(clientZoom), dh = win.height * Double(clientZoom)
        pipeline.setInputViewport(VideoRect(
            x: Double(panOffset.x) / dw,
            y: Double(panOffset.y) / dh,
            width: Double(bounds.width) / dw,
            height: Double(bounds.height) / dh,
        ))
        controls?.zoomed = viewportTouched || clientZoom != 1
    }

    /// Fires on window-attach and when the view moves between Retina/non-Retina displays.
    /// Re-syncs the hosted layer's scale and re-lays-out so the drawable is sized for the new
    /// backing scale (the initial scale is set in `layout()`; this keeps it correct across moves).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard window != nil else { return } // can fire with window==nil during teardown
        videoLayer.contentsScale = window?.backingScaleFactor ?? videoLayer.contentsScale
        needsLayout = true
    }

    // MARK: Local navigation (pan) — responder methods, never gesture recognizers

    // MARK: Pinch / smart-zoom → key translation (`SLOPDESK_PINCH_KEYS`, default ON; `=0` off)

    /// No public API can synthesise a real `magnify` gesture on the host, so the pinch is
    /// translated into the near-universal zoom key equivalents and rides the existing key path
    /// (no wire change; accumulation lives in the pure ``PinchZoomKeyPlanner``). The pane itself
    /// never zooms from a pinch — it is a fixed ACTUAL-SIZE viewport (footer zoom + edge-pan own
    /// local navigation), so the gesture's only meaning here is REMOTE zoom.
    private static let pinchKeysEnabled = EnvConfig.boolDefaultOn("SLOPDESK_PINCH_KEYS")
    /// ANSI key POSITIONS (HIToolbox `kVK_ANSI_*`), interpreted by the host layout like any
    /// forwarded keystroke.
    private static let keyEqual: UInt16 = 0x18 // kVK_ANSI_Equal → ⌘= zoom in
    private static let keyMinus: UInt16 = 0x1B // kVK_ANSI_Minus → ⌘− zoom out
    private static let keyZero: UInt16 = 0x1D // kVK_ANSI_0 → ⌘0 actual size
    private static let keyCommandModifier: UInt16 = 0x37 // kVK_Command — the chord bracket
    private static let keyRightCommandModifier: UInt16 = 0x36 // kVK_RightCommand — same latch
    private var pinchPlanner = PinchZoomKeyPlanner()

    /// Two-finger pinch → ⌘= / ⌘− steps on the HOST. Same routing rule as `scrollWheel`: only the
    /// ACTIVE, writable pane forwards; an unfocused or read-only pane swallows the pinch (it must
    /// not perturb local geometry either — the historical no-op behaviour).
    override func magnify(with event: NSEvent) {
        guard isActive, inputEnabled, Self.pinchKeysEnabled else { return }
        if event.phase.contains(.began) { pinchPlanner.begin() }
        let steps = pinchPlanner.ingest(magnification: Double(event.magnification))
        guard steps != 0 else { return }
        for _ in 0..<abs(steps) {
            sendHostChord(keyCode: steps > 0 ? Self.keyEqual : Self.keyMinus)
        }
    }

    /// Two-finger double-tap (smart zoom) → ⌘0 (actual size / reset zoom) on the HOST — the
    /// natural pairing with the pinch's ⌘= / ⌘− ladder.
    override func smartMagnify(with _: NSEvent) {
        guard isActive, inputEnabled, Self.pinchKeysEnabled else { return }
        sendHostChord(keyCode: Self.keyZero)
    }

    /// Emits one synthetic ⌘-chord as a BRACKETED sequence — real ⌘ key down, the letter pair
    /// flagged, the ⌘ release with EMPTY flags — never a bare flagged pair: the host posts
    /// forwarded keys onto the shared `.hidSystemState` source, where a flagged pair with no
    /// modifier release LATCHES ⌘ onto every later flag-less synthetic event (scrolls → browser
    /// zoom; probe-verified). Byte-shaped like a real user chord (`flagsChanged` forwards the
    /// modifier edges exactly this way).
    ///
    /// EXCEPT while the user PHYSICALLY holds ⌘ (either side — `modifierLatch` tracks the real
    /// edges): the host already has the real latch, and a synthetic ⌘-up would be consumed by the
    /// host's balance as the one legitimate release — the user's actual release later dedupes
    /// away, stranding the host un-⌘'d mid-hold. Ride the real modifier: letter pair only.
    private func sendHostChord(keyCode: UInt16) {
        let commandHeld = modifierLatch.isDown(Self.keyCommandModifier)
            || modifierLatch.isDown(Self.keyRightCommandModifier)
        if !commandHeld { pipeline.key(keyCode: Self.keyCommandModifier, down: true, modifiers: .command) }
        pipeline.key(keyCode: keyCode, down: true, modifiers: .command)
        pipeline.key(keyCode: keyCode, down: false, modifiers: .command)
        if !commandHeld { pipeline.key(keyCode: Self.keyCommandModifier, down: false, modifiers: []) }
    }

    /// 1× reset → restore actual-size zoom AND re-anchor the viewport to the window's TOP-LEFT.
    private func applyResetZoom() {
        viewportTouched = false
        clientZoom = 1
        panOffset = .zero
        stopEdgePan()
        needsLayout = true
        layoutVideoLayer()
    }

    /// Whether there is window content beyond the pane to pan to (the window is larger than the pane on at
    /// least one axis). Gates edge-pan.
    private var isNavigable: Bool {
        guard let win = streamPoints else { return false }
        // The DISPLAYED window is native × clientZoom (see `layoutVideoLayer`), so the navigability gate must
        // key off the zoomed size — otherwise footer zoom-in overflow of a smaller-than-pane window reads as
        // "fits" and edge-pan (the only in-pane pan path) never arms.
        return ViewportPan.isNavigable(
            window: win,
            pane: VideoSize(width: Double(bounds.width), height: Double(bounds.height)),
            zoom: Double(clientZoom),
        )
    }

    // MARK: Edge-pan (translate the oversized video layer when the pointer hugs a pane edge)

    /// Recompute the edge-pan velocity from the pointer's distance to each edge and (re)arm/stop the
    /// drive timer. `p` is in this view's coordinates (AppKit, origin bottom-left). Inert when the window
    /// fits the pane.
    private func updateEdgePan(at p: CGPoint) {
        lastPointerView = p
        // PAN LOCK ("lock position"): the footer lock control freezes the viewport — no edge-hover auto-pan.
        guard !panLocked else { stopEdgePan()
            return
        }
        edgePanVelocity = computeEdgePanVelocity(at: p)
        if edgePanVelocity == .zero {
            stopEdgePan()
        } else if edgePanTimer == nil {
            // `.common` mode so the timer keeps firing during mouse-tracking / gesture runloop modes.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.stepEdgePan() }
            }
            RunLoop.main.add(timer, forMode: .common)
            edgePanTimer = timer
        }
    }

    private func stopEdgePan() {
        edgePanVelocity = .zero
        edgePanTimer?.invalidate()
        edgePanTimer = nil
    }

    /// Signed pan velocity (WINDOW POINTS/sec) for a pointer at `p`. Each axis ramps linearly from 0 at the
    /// band's inner edge to ``edgePanPointsPerSec`` at the pane border. Sign is in the `panOffset` basis
    /// (top-left, y-down): right edge → +x (reveal right); the view's BOTTOM (small AppKit y) → +y (reveal
    /// the window's bottom).
    private func computeEdgePanVelocity(at p: CGPoint) -> CGPoint {
        guard isNavigable, bounds.width > 1, bounds.height > 1 else { return .zero }
        let t = Self.edgePanThreshold
        let maxV = Self.edgePanPointsPerSec
        func ramp(_ depth: CGFloat) -> Double { min(max(Double(depth) / Double(t), 0), 1) * maxV }
        var v = CGPoint.zero
        if p.x < t { v.x = -ramp(t - p.x) } else if p.x > bounds.width - t { v.x = ramp(p.x - (bounds.width - t)) }
        if p.y < t { v.y = ramp(t - p.y) } else if p.y > bounds.height - t { v.y = -ramp(p.y - (bounds.height - t)) }
        return v
    }

    /// One 60 Hz edge-pan step: advance ``panOffset`` (window points) by `velocity · dt`, clamp to the
    /// overflow `[0, window − pane]`, re-lay-out the video layer (a compositor translate), and re-forward
    /// the (edge-pinned) pointer so the host cursor walks into the revealed region.
    private func stepEdgePan() {
        guard isNavigable, edgePanVelocity != .zero, let win = streamPoints else { stopEdgePan()
            return
        }
        let dt = 1.0 / 60.0
        // Clamp to the DISPLAYED (zoomed) overflow, matching `layoutVideoLayer`'s frame clamp — clamping to
        // the un-zoomed `win − pane` stopped panning partway and stranded the far edge of zoomed content.
        let maxPan = ViewportPan.maxPanOffset(
            window: win,
            pane: VideoSize(width: Double(bounds.width), height: Double(bounds.height)),
            zoom: Double(clientZoom),
        )
        let maxX = maxPan.x
        let maxY = maxPan.y
        let nx = min(max(Double(panOffset.x) + Double(edgePanVelocity.x) * dt, 0), maxX)
        let ny = min(max(Double(panOffset.y) + Double(edgePanVelocity.y) * dt, 0), maxY)
        let xDone = edgePanVelocity
            .x == 0 || (edgePanVelocity.x < 0 && nx <= 0) || (edgePanVelocity.x > 0 && nx >= maxX)
        let yDone = edgePanVelocity
            .y == 0 || (edgePanVelocity.y < 0 && ny <= 0) || (edgePanVelocity.y > 0 && ny >= maxY)
        panOffset = CGPoint(x: nx, y: ny)
        viewportTouched = true // explicit edge-pan → stop re-anchoring to top-left
        layoutVideoLayer() // compositor translate (smooth) + republish input viewport
        if isActive, inputEnabled {
            pipeline.mouseMove(VideoPoint(x: Double(lastPointerView.x), y: Double(bounds.height - lastPointerView.y)))
        }
        if xDone, yDone { stopEdgePan() }
    }

    // MARK: Input forwarding (view space → normalised → host)

    private func viewPoint(_ event: NSEvent) -> VideoPoint {
        // Convert to this view's coordinates, then flip Y so origin is TOP-left (the
        // orientation the host window space + InputEventEncoder normalisation expect).
        let p = convert(event.locationInWindow, from: nil)
        // SWIPE-PEEL COMPENSATION: while the peel nudge translates `videoLayer`, the content the
        // user SEES at view-x sits at content-x − shift — the same render/input coupling the
        // zoom/pan inverse preserves (a click must land on the pixel under the pointer). Read the
        // PRESENTATION value so the 180 ms ease-home beat compensates with the live decayed
        // offset (the model is already identity there); zero whenever no peel is in flight.
        let peelShift = videoLayer.presentation()?.transform.m41 ?? videoLayer.transform.m41
        return VideoPoint(x: Double(p.x - peelShift), y: Double(bounds.height - p.y))
    }

    private func mods(_ event: NSEvent) -> InputModifiers { Self.modifiers(event.modifierFlags) }

    /// Clamps `NSEvent.clickCount` (an unbounded `Int` — AppKit keeps incrementing it for consecutive
    /// in-place clicks within the double-click interval) into the wire `UInt8`. `UInt8(clamping:)`
    /// saturates at 255 instead of the trapping `UInt8(Int)` that would crash the client on a 256th rapid
    /// click; identical for every real 1/2/3-click, and the host only uses it as a click-state hint
    /// (`max(1, Int(clickCount))`), so saturating is harmless.
    nonisolated static func clampClickCount(_ n: Int) -> UInt8 { UInt8(clamping: n) }

    // Only the ACTIVE pane tracks hover (the "only the active pane swallows pointer" rule). A non-active
    // pane ignores hover so it never injects a stray remote mouse-move; you must click it first.
    override func mouseMoved(with event: NSEvent) {
        guard isActive else { return }
        // Edge-pan is local view-nav (moves the zoomed crop) — runs even on a read-only pane; inert at 1×.
        updateEdgePan(at: convert(event.locationInWindow, from: nil))
        guard inputEnabled else { return } // read-only ⇒ no remote mouse-move
        pipeline.mouseMove(viewPoint(event))
    }

    // A drag (a button is HELD) is a DISTINCT NSView callback from a hover `mouseMoved`, so the
    // client KNOWS which button is down and forwards an explicit `.mouseDrag`; the host posts
    // the matching `*MouseDragged` STATELESSLY — no host-side held-button guess. NOT gated on
    // `isActive`: a drag only follows a `mouseDown` on THIS pane, which already activated it, so the
    // in-gesture frames must keep flowing even before SwiftUI re-renders `isActive` true.
    override func mouseDragged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote drag
        pipeline.mouseDrag(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote drag
        pipeline.mouseDrag(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    // CLICK = ACTIVATE: a mouseDown makes this the active pane (`onActivate` → workspace focus) AND raises
    // the host window (`focusWindow`), THEN lands as a remote click — raising on hover instead would steal
    // the host window the moment the pointer merely crosses an unfocused pane. The activating click is
    // always forwarded so clicking a control in a background window just works.
    override func mouseDown(with event: NSEvent) {
        // BUG-1 probe: clicking is the reported freeze trigger. Correlate this line with `cursorAPPLY`/
        // `RENDER` gaps (client main-actor block from focus()) and `mediaRX` gaps (host capture hitch on
        // window-raise) to see which path stalls on a click.
        videoViewDbg("click → activate isActive=\(isActive)")
        onActivate()
        // READ-ONLY: a locked pane still ACTIVATES (workspace focus, above), but the click is NOT
        // relayed to the host and the host window is NOT raised — the pane is view-only.
        guard inputEnabled else { return }
        // Send the host window-raise ONLY when (re)activating an UNfocused pane — not on every click of
        // an already-active pane. The host raise is best-effort + costly (AX IPC); re-raising on each
        // click of the focused pane is wasted work (the host throttles redundant raises as a backstop).
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote click
        pipeline.mouseUp(.left, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        onActivate()
        guard inputEnabled else { return } // read-only ⇒ activate only, no remote relay
        if !isActive { pipeline.focusWindow() }
        pipeline.mouseDown(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no remote click
        pipeline.mouseUp(.right, viewPoint(event), Self.clampClickCount(event.clickCount), mods(event))
    }

    /// Maps a finger-on-glass `NSEvent.phase` to its `CGScrollPhase` integer code so the host can set
    /// `kCGScrollWheelEventScrollPhase` verbatim (`0`=none, `1`=began, `2`=changed, `4`=ended,
    /// `8`=cancelled, `128`=mayBegin). `.stationary`/empty → `0`.
    static func cgScrollPhaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 8 }
        if phase.contains(.mayBegin) { return 128 }
        return 0
    }

    /// Maps an inertial-coast `NSEvent.momentumPhase` to its `CGMomentumScrollPhase` integer code
    /// (`0`=none, `1`=begin, `2`=continue, `3`=end) — a SEPARATE encoding from `cgScrollPhaseCode`.
    static func cgMomentumPhaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 3 }
        return 0
    }

    override func scrollWheel(with event: NSEvent) {
        // ACTUAL-SIZE viewport: a two-finger scroll FORWARDS to the remote (scrolls the editor) — it is NOT
        // hijacked to pan the viewport. Moving the viewport is the EDGE-PAN's job (hover-to-edge, RealVNC
        // model). So there is no local crop-pan branch here.
        //
        // SCROLL ROUTING — gated on EXPLICIT canvas focus (`isActive == store.isFocused(id)`),
        // the desktop model the user asked for — once a GUI pane is focused, it must swallow the scroll:
        //   • FOCUSED pane   → forward the scroll to the REMOTE window (you clicked in, you're scrolling
        //     its content). Forwarding is a UDP send — no `@Observable` mutation, so it never blocks the
        //     stream. Mirrors the terminal pane's focused-scrollback rule.
        //   • UNFOCUSED pane → PAN THE CANVAS, never swallow — so panning across a background pane keeps
        //     navigating instead of stopping at its edge. Routed through the debounced `onCanvasScroll`
        //     accumulator (NOT a per-step commitCamera), so it never blocks the stream either.
        //   • ⌥ held         → ALWAYS pan the canvas, even while focused (escape hatch to pan a focused
        //     pane without first unfocusing it).
        // Natural-scroll sign matches `CanvasView.PanView` so a pane-pan feels identical to the bg pan.
        // READ-ONLY: a locked focused pane does NOT swallow the scroll into the remote window —
        // `inputEnabled == false` falls through to the canvas-pan branch (view-only, no host relay).
        if isActive, inputEnabled, !event.modifierFlags.contains(.option) {
            videoViewDbg("scroll → remote (focused)")
            // Forward the trackpad gesture state so the host can replay a native continuous/inertial
            // scroll (Began→Changed→Ended, then momentum Begin→Continue→End) instead of a phase-less
            // wheel tick. `event.phase` (finger-on-glass) and `event.momentumPhase` (coast) are
            // distinct and mutually exclusive; map each to its CoreGraphics integer code.
            pipeline.scroll(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                viewPoint: viewPoint(event),
                scrollPhase: Self.cgScrollPhaseCode(event.phase),
                momentumPhase: Self.cgMomentumPhaseCode(event.momentumPhase),
                continuous: event.hasPreciseScrollingDeltas,
            )
            feedSwipePeel(event)
            return
        }
        // A scroll that no longer reaches the remote (focus flip / ⌥ pan / read-only) abandons
        // any mid-gesture peel — the host recogniser stops seeing this gesture too.
        abandonSwipePeel()
        let dx: CGFloat, dy: CGFloat
        if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else { dx = event.scrollingDeltaX * 10
            dy = event.scrollingDeltaY * 10
        }
        videoViewDbg("scroll → canvas pan d=(\(Int(-dx)),\(Int(-dy))) isActive=\(isActive)")
        onCanvasScroll(CGSize(width: -dx, height: -dy))
    }

    // MARK: Swipe-peel feedback (doc 05 §8)

    /// Adopts the host's swipe-nav status push. Eligibility flipping OFF mid-gesture retracts
    /// immediately (the host would ignore the fire); a knob change rebuilds the (idle) mirror so
    /// a host-side `SLOPDESK_SWIPE_NAV_TRAVEL`/`_SLOW` retune never desynchronises the feedback.
    private func adoptSwipeNavStatus(_ status: SwipeNavStatusMessage) {
        let previous = peelStatus
        peelStatus = status
        if !status.eligible { abandonSwipePeel() }
        if previous?.fireTravel != status.fireTravel || previous?.slowTier != status.slowTier {
            peelPlanner = SwipePeelPlanner(
                fireTravel: Double(status.fireTravel), slowSwipe: status.slowTier,
            )
        }
    }

    /// Mirrors one forwarded scroll event into the peel planner and applies its verdict. Gated
    /// on the host saying the target app is eligible AT ALL — no push yet (old host) ⇒ nothing.
    private func feedSwipePeel(_ event: NSEvent) {
        guard peelStatus?.eligible == true else { return }
        applySwipePeel(peelPlanner.ingest(
            dx: Double(event.scrollingDeltaX),
            dy: Double(event.scrollingDeltaY),
            scrollPhase: Self.cgScrollPhaseCode(event.phase),
            momentumPhase: Self.cgMomentumPhaseCode(event.momentumPhase),
            continuous: event.hasPreciseScrollingDeltas,
            now: event.timestamp,
        ))
    }

    /// The page-follow translation for a raw gesture travel: ~1:1 under the fingers with a
    /// soft tanh knee into a cap at just under half the pane (`d(offset)/d(travel) ≈ 1` at the
    /// origin because the scale equals the cap) — the page never slides past the point where
    /// the reveal would read as a detached card.
    private func peelOffset(forTravel travelX: Double) -> CGFloat {
        let cap = Double.maximum(Double.minimum(Double(bounds.width) * 0.45, 560), 120)
        return CGFloat(cap * tanh(travelX / cap))
    }

    private func applySwipePeel(_ verdict: SwipePeelPlanner.Verdict) {
        switch verdict {
        case .idle:
            return
        case let .show(overlay):
            peelConfirmClear?.cancel()
            peelConfirmClear = nil
            // A new gesture over a still-running commit choreography adopts the page where it
            // is: drop the old snapshot instantly (the live layer beneath is already home).
            clearPeelSnapshot()
            let offset = peelOffset(forTravel: overlay.travelX)
            // Track the finger — instant transform write, the same no-implicit-animation
            // convention as every other geometry mutation in this file. `.transform` is a pure
            // compositor channel `layoutVideoLayer`'s frame writes never touch. The underlay
            // updates in the SAME transaction so page and backdrop can never tear.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.transform = CATransform3DMakeTranslation(offset, 0, 0)
            updatePeelUnderlay(offset: offset)
            CATransaction.commit()
            if overlay.chip.committed, !peelChipCommitted {
                // The moment native communicates by page position: "release now navigates".
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            peelChipCommitted = overlay.chip.committed
            if controls?.swipePeel != overlay.chip { controls?.swipePeel = overlay.chip }
        case let .commit(direction):
            beginPeelCommitChoreography(direction)
            peelChipCommitted = false
            controls?.swipePeel = SwipePeelChipState(
                direction: direction, progress: 1, committed: true, confirming: true,
            )
            peelConfirmClear?.cancel()
            peelConfirmClear = Task { [weak self] in
                // The chip's confirm pulse spans the snapshot hold + slide (the host's ⌘[/⌘]
                // lands and the new page streams in underneath during this beat).
                try? await Task.sleep(nanoseconds: 520_000_000)
                guard !Task.isCancelled else { return }
                self?.controls?.swipePeel = nil
            }
        case .retract:
            easeSwipePeelHome()
            peelChipCommitted = false
            controls?.swipePeel = nil
        }
    }

    // MARK: Swipe-peel underlay + commit choreography

    /// Shows/positions the flat backdrop + edge shade for the current page offset; `0` hides.
    /// Caller wraps this in its disabled-actions transaction (tears otherwise).
    private func updatePeelUnderlay(offset: CGFloat) {
        guard offset != 0 else {
            peelUnderlay?.isHidden = true
            return
        }
        let underlay = ensurePeelUnderlay()
        underlay.isHidden = false
        underlay.frame = bounds
        guard let shade = peelUnderlayShade else { return }
        // The shade hugs the page's moving edge INSIDE the revealed gap: for a back-swipe the
        // gap is on the left and the page edge sits at x = offset (dark side rightmost); a
        // forward-swipe mirrors on the right edge.
        let shadeWidth: CGFloat = 18
        if offset > 0 {
            shade.frame = CGRect(x: offset - shadeWidth, y: 0, width: shadeWidth, height: bounds.height)
            shade.startPoint = CGPoint(x: 0, y: 0.5)
            shade.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            shade.frame = CGRect(x: bounds.width + offset, y: 0, width: shadeWidth, height: bounds.height)
            shade.startPoint = CGPoint(x: 1, y: 0.5)
            shade.endPoint = CGPoint(x: 0, y: 0.5)
        }
        // Read as the page casting onto the backdrop: strongest at the page edge, gone by ~18pt.
        shade.opacity = Float(Double.minimum(abs(Double(offset)) / 80, 1))
    }

    private func ensurePeelUnderlay() -> CALayer {
        if let peelUnderlay { return peelUnderlay }
        let underlay = CALayer()
        // MERIDIAN flat: a near-black matte, no ornament — the chip floating above the gap is
        // the affordance. Never a material/blur (repo law: nothing refractive over/under the
        // metal layer's compositing path).
        underlay.backgroundColor = CGColor(gray: 0.07, alpha: 1)
        let shade = CAGradientLayer()
        shade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.34)]
        underlay.addSublayer(shade)
        layer?.insertSublayer(underlay, below: videoLayer)
        peelUnderlay = underlay
        peelUnderlayShade = shade
        return underlay
    }

    /// The fired-gesture choreography: freeze the outgoing page into a plain snapshot layer at
    /// its current offset, return the live layer home INSTANTLY underneath (same pixels — an
    /// invisible seam), hold one beat for the post-navigation page to stream in, then slide the
    /// snapshot off in the swipe direction revealing the live layer. Masks the ~150–400 ms
    /// inject→browser-paint→capture→stream latency exactly the way Safari's own snapshot swap
    /// masks its load. No frame on glass yet (fresh session) ⇒ fall back to the plain ease-home.
    private func beginPeelCommitChoreography(_ direction: SwipeNavRecognizer.Direction) {
        clearPeelSnapshot()
        guard let cgImage = makePeelSnapshotImage() else {
            easeSwipePeelHome()
            return
        }
        let snapshot = CALayer()
        snapshot.contents = cgImage
        snapshot.contentsGravity = .resize
        snapshot.frame = videoLayer.frame
        snapshot.transform = videoLayer.presentation()?.transform ?? videoLayer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.addSublayer(snapshot)
        videoLayer.transform = CATransform3DIdentity
        peelUnderlay?.isHidden = true
        CATransaction.commit()
        peelSnapshotLayer = snapshot
        peelSnapshotSlide = Task { [weak self] in
            // One beat for ⌘[/⌘] to land remotely and the new page's frames to arrive — the
            // common case reveals the REAL destination page mid-slide; a slow navigation
            // degrades to revealing the old page again (yesterday's teleport, now with motion).
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self?.slidePeelSnapshotOff(direction)
        }
    }

    private func slidePeelSnapshotOff(_ direction: SwipeNavRecognizer.Direction) {
        guard let snapshot = peelSnapshotLayer else { return }
        let dx = direction == .back ? bounds.width + 40 : -(bounds.width + 40)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1))
        CATransaction.setCompletionBlock { [weak self] in
            // Only the still-current snapshot tears down here — a new gesture may have swapped
            // in a fresh one while this slide ran.
            if self?.peelSnapshotLayer === snapshot { self?.peelSnapshotLayer = nil }
            snapshot.removeFromSuperlayer()
        }
        snapshot.transform = CATransform3DMakeTranslation(dx, 0, 0)
        snapshot.opacity = 0.92
        CATransaction.commit()
    }

    /// Drops any commit-choreography snapshot instantly (new gesture / teardown).
    private func clearPeelSnapshot() {
        peelSnapshotSlide?.cancel()
        peelSnapshotSlide = nil
        guard let snapshot = peelSnapshotLayer else { return }
        peelSnapshotLayer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshot.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// The outgoing page, frozen: the frame on glass converted NV12→RGB once. ~10 ms for a
    /// desktop-sized frame — once per FIRED navigation, at gesture end, never on the 120 Hz
    /// tracking path.
    private func makePeelSnapshotImage() -> CGImage? {
        guard let buffer = pipeline.lastRenderedImageBuffer() else { return nil }
        let image = CIImage(cvImageBuffer: buffer)
        return Self.peelSnapshotContext.createCGImage(image, from: image.extent)
    }

    /// The retract ease-home: a transform-only compositor animation (never touches the
    /// drawable pool), non-spring per the design system — the reveal curve over 180 ms. The
    /// edge shade fades in the same transaction (its frame is pinned to the last offset, so it
    /// would otherwise dangle in the shrinking gap), and the underlay hides on completion. A
    /// new gesture's instant `.show` write (disabled actions) snaps over all of it, so
    /// finger-tracking always wins.
    private func easeSwipePeelHome() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1))
        CATransaction.setCompletionBlock { [weak self] in
            // Hidden only if no new gesture re-showed it mid-ease (its instant write already
            // un-hid + repositioned everything).
            guard let self, videoLayer.transform.m41 == 0 else { return }
            peelUnderlay?.isHidden = true
        }
        videoLayer.transform = CATransform3DIdentity
        peelUnderlayShade?.opacity = 0
        CATransaction.commit()
    }

    /// Abandons any in-flight peel (scroll rerouted, eligibility off, teardown): the planner
    /// resets and, if something was showing, everything eases home.
    private func abandonSwipePeel() {
        applySwipePeel(peelPlanner.cancel())
    }

    // ALL keys (printable + special) go through the layout-level keycode `.key` path so the HOST's
    // keyboard layout + input method (e.g. OpenKey/xkey Telex) interpret and COMPOSE them server-side —
    // like Parsec/VNC/Screen-Sharing "scancode mode". A `.text` path that posts a virtualKey-0 CGEvent +
    // keyboardSetUnicodeString would be invisible to a keycode-driven IME composer (OpenKey reads only the
    // virtual keycode + shift/caps flag, never the Unicode string): the pre-baked glyph would ride through
    // and Vietnamese would never compose (`tieesng` inserted literally instead of composing). The real
    // keycode + flags let the host IME compose normally.
    //
    // Send ONLY `.key` per keypress — sending `.key` + `.text` together for the same keypress double-injects
    // one character per path. The `.text` / pipeline.text(...) / host `postText` plumbing stays (unused by
    // live typing) for future layout-independent input like paste.
    // WORKSPACE PREFIX over the video pane.
    //
    // The tmux/zellij prefix (⌃B) MUST NOT leak to the remote host when arming a LOCAL workspace command.
    // That interception is UPSTREAM: the app-level `WorkspaceKeyDispatcher` installs ONE
    // `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` at launch, firing BEFORE the first responder —
    // so a prefix arm / resolved chord / send-prefix double-tap is consumed (handler returns `nil`) and
    // this `keyDown` is NEVER reached for those. A bare key returns unchanged and lands here as normal typing.
    //
    // No thin pre-check is mirrored here (unlike the libghostty surface's) ON PURPOSE: `TerminalKeyInterceptor`
    // lives in `SlopDeskWorkspaceCore`, and `SlopDeskVideoClient` depends ONLY on `SlopDeskVideoProtocol`
    // (Package.swift) — importing WorkspaceCore here would invert the module graph (the HARD RULE keeps these
    // layers separated). That belt-and-suspenders exists because the libghostty surface is hosted INSIDE the
    // WorkspaceCore-importing app target and can reach the engine; this gated video surface cannot and need
    // not — the monitor already covers it. (Gated module: never instantiated in tests; verified by REVIEW.)
    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no keycode forward
        pipeline.key(keyCode: event.keyCode, down: true, modifiers: mods(event))
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no keycode forward
        pipeline.key(keyCode: event.keyCode, down: false, modifiers: mods(event))
    }

    // Modifier press/release. Without this, ⌘/⇧/⌃/⌥ are NEVER sent as discrete key events — they only
    // ride as per-event flags on key/mouse events. On the host `postKey` posts a CGEvent whose flags come
    // from those per-event mods, but the shared `CGEventSource(stateID:.hidSystemState)` LATCHES modifier
    // state: a ⌘ flag injected on (say) Delete with no matching modifier KEY-UP stays latched and corrupts
    // every later `.text` insertion (⌘+Delete then a stuck ⌘ turns the next Return into newline-with-⌘).
    // Emitting the real modifier key-up here posts a CGEvent that clears the latched flag. (`pipeline.key`
    // already carries keyCode+down+modifiers — no protocol change.)
    override func flagsChanged(with event: NSEvent) {
        guard inputEnabled else { return } // read-only ⇒ no modifier key-event forward
        guard let down = Self.modifierDown(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
        // Track the edge (BUG-2) so a focus change that swallows the release can synthesize the key-up.
        modifierLatch.note(keyCode: event.keyCode, down: down)
        pipeline.key(keyCode: event.keyCode, down: down, modifiers: mods(event))
    }

    override var acceptsFirstResponder: Bool { true }

    /// AppKit only delivers `mouseMoved` when a tracking area requests it, and
    /// `acceptsFirstResponder` alone does NOT focus a bare layer-backed view inside a
    /// SwiftUI sheet — so without these two the cursor-follow + keyboard input paths are
    /// dead. Install/refresh a tracking area for the visible bounds, and grab first
    /// responder when the view enters a window.
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            // `.mouseEnteredAndExited` tracks whether the pointer is in the pane; `.cursorUpdate` makes
            // AppKit call `cursorUpdate(with:)` on each move so we re-assert the host's cursor shape.
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        applyLocalCursor()
        // Warp the host cursor to the entry point so its SHAPE resyncs immediately — a pointer that
        // enters an active pane and stops on a resize edge would otherwise hold the stale pre-focus
        // shape until the first hover move. Gated on active+writable inside `forwardPointer`.
        forwardPointer(atWindowLocation: event.locationInWindow)
    }

    override func mouseExited(with _: NSEvent) {
        pointerInside = false
        stopEdgePan() // pointer left the pane → stop auto-scrolling the crop
        NSCursor.arrow.set() // leaving the pane → restore the normal pointer
    }

    /// AppKit's per-move cursor callback while the pointer is in the pane: re-assert the host shape (or
    /// fall through to AppKit's default arrow) so a transient `.set()` from elsewhere can't win on a move.
    override func cursorUpdate(with event: NSEvent) {
        if isActive, pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor {
            cursor.set()
        } else {
            super.cursorUpdate(with: event) // AppKit already set the window's default (arrow) pre-callback
        }
    }

    /// FIRST-RESPONDER RESIGN (BUG-2): when a sibling pane grabs first responder (⌘T / any focus move that
    /// calls `makeFirstResponder`) while a modifier is physically held, its release `flagsChanged` is delivered
    /// to the NEW responder — never to us — so the host would keep the modifier latched (scroll → zoom). Release
    /// the latched modifiers here. (The other no-release path — the whole window resigning key on ⌘-Tab away,
    /// which does NOT call `resignFirstResponder` — is covered by the `didResignKeyNotification` observer below.)
    override func resignFirstResponder() -> Bool {
        releaseLatchedModifiers()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // BUG-2: re-scope the window-resign-key observer to the CURRENT window (removed first so a moved /
        // detached view never keeps a stale subscription). On ⌘-Tab away the window resigns key WITHOUT a
        // release `flagsChanged` or a `resignFirstResponder`, so this is the only signal to unlatch modifiers.
        if let token = windowResignKeyObserver {
            NotificationCenter.default.removeObserver(token)
            windowResignKeyObserver = nil
        }
        if let window {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main,
            ) { [weak self] _ in
                // Already on the main queue (`queue: .main`); bridge to this @MainActor view.
                MainActor.assumeIsolated { self?.releaseLatchedModifiers() }
            }
        }
        // FOCUS-STEALING FIX: only grab first responder when THIS pane is the ACTIVE one and we are not
        // already the responder. An unconditional makeFirstResponder on every NSView mount let the
        // LAST-mounted video pane steal the keyboard regardless of workspace focus (and thrash the
        // responder on tab switches). Mirrors the terminal pane's `isFocusedPane` guard.
        guard isActive, let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// Restore the arrow when the view leaves its window (drag-out / pane close): a teardown that skipped
    /// `mouseExited` must not leave a stale host-shape cursor set.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { if pointerInside { NSCursor.arrow.set() }
            pointerInside = false
            stopEdgePan() // teardown — never leave a timer firing on a detached view
            // BUG-2: release any latched modifier + drop the resign-key observer before the view detaches, so
            // a torn-down pane never leaves the host with a stuck modifier or a stale window subscription.
            releaseLatchedModifiers()
            if let token = windowResignKeyObserver {
                NotificationCenter.default.removeObserver(token)
                windowResignKeyObserver = nil
            }
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> InputModifiers {
        var m: InputModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }

    /// Pure: decide whether a `flagsChanged` keyCode is a modifier press (`down`) or a
    /// release. `flagsChanged` fires for BOTH edges with the same keyCode; the only way
    /// to tell them apart is to ask whether the corresponding modifier is still present
    /// in `flags` after the event. Returns `nil` for a keyCode that is not a known
    /// modifier (so the caller sends nothing). Factored out so the keyCode→modifier-mask
    /// mapping is unit-testable without an `NSEvent`.
    static func modifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        switch Int(keyCode) {
        case 55,
             54: flags.contains(.command) // ⌘ left / right
        case 56,
             60: flags.contains(.shift) // ⇧ left / right
        case 59,
             62: flags.contains(.control) // ⌃ left / right
        case 58,
             61: flags.contains(.option) // ⌥ left / right
        case 57: flags.contains(.capsLock) // ⇪
        case 63: flags.contains(.function) // fn
        default: nil
        }
    }
}

#elseif os(iOS)
import UIKit

/// `UIViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on iOS.
struct MetalVideoLayerView: UIViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    // Signature parity with the macOS representable (the shared `VideoWindowView.body` builds both). iOS
    // pane activation runs through the canvas's per-pane tap gesture + a background `DragGesture`, so unused here.
    var isActive: Bool = true
    // Read-only gate — signature parity only. The iOS video view forwards NO host pointer/key
    // input (its gestures are LOCAL zoom/pan), so there is nothing to suppress; accepted + ignored here.
    var inputEnabled: Bool = true
    var onActivate: () -> Void = {}
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    // Signature parity with the macOS representable (the shared `VideoWindowView.body` passes it).
    // iOS has no host-key-injection sink (paste-as-keystrokes is macOS-only), so this is unused here.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    // Signature parity with the macOS representable. iOS resizes the remote window via pinch (local zoom),
    // not a host-window resize, so the resize / viewport / geometry hooks are accepted + ignored here.
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    // Signature parity with the macOS representable. iOS forwards no host key/mouse input, so the
    // release-stuck-input escape hatch has nothing to release — accepted + ignored here.
    var onInputReleaseReady: (((() -> Void)?) -> Void)?
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    // Signature parity with the macOS representable. The iOS Connection section is not wired yet, so the
    // host-cadence + bitrate + stats pushes are accepted + ignored here.
    var onStreamCadenceReady: ((Int) -> Void)?
    var onStreamBitrateReady: ((Int) -> Void)?
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int) -> Void)?
    // Signature parity with the macOS representable. iOS has no stream-settings UI nor a
    // programmatic key drive (it forwards no host key input) — accepted + ignored here.
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    // Signature parity with the macOS representable. The iOS pane has no scrim overlay wired yet, so the
    // stall push is accepted + ignored here.
    var onStreamStallChanged: ((Bool) -> Void)?
    // Signature parity with the macOS representable. The iOS view layer has no picker fallback wired
    // yet, so the terminal-refusal push is accepted + ignored here.
    var onSessionRejected: (() -> Void)?

    func makeUIView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.onStreamNativeSize = onStreamNativeSize // before activate — nil-ness picks snap vs host-follow
        view.activate(connection: connection)
        return view
    }

    func updateUIView(_ uiView: MetalLayerBackedView, context _: Context) {
        uiView.controls = controls
        uiView.onStreamNativeSize = onStreamNativeSize
        uiView.activate(connection: connection)
    }

    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator _: ()) {
        uiView.deactivate()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the client pipeline. Adds VNC-style
/// pinch-to-zoom + one-finger pan (+ double-tap to reset) over the remote window.
final class MetalLayerBackedView: UIView, UIGestureRecognizerDelegate {
    override static var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer {
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("layerClass is CAMetalLayer, so the backing layer is always a CAMetalLayer")
        }
        return metalLayer
    }

    private let pipeline = VideoWindowPipeline()

    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    private var gestureBaseZoom: CGFloat = 1
    private var gestureBasePan: CGPoint = .zero
    private var gesturesInstalled = false
    /// Bridge to the SwiftUI control overlay (fit/fill toggle + zoom reset). Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?
    /// 1:1 PANE SNAP (see the macOS sibling): ask the canvas pane to resize its video content from
    /// `current` to `target` points. Set by the representable BEFORE ``activate(connection:)``.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?

    func activate(connection: VideoWindowConnection?) {
        installGesturesIfNeeded()
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate (nil-ness picks snap vs host-follow at
        // session construction; mirrors the macOS sibling).
        pipeline.onStreamNativePoints = onStreamNativeSize == nil ? nil : { [weak self] points in
            self?.adoptStreamNativePoints(points)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    func deactivate() { pipeline.deactivate() }

    /// 1:1 PANE SNAP: the session handed us the host window's POINT size (the snap target).
    /// Rebase the session's resize debounce (no host echo), then ask the pane to adopt it —
    /// mirrors the macOS sibling.
    private func adoptStreamNativePoints(_ points: VideoSize) {
        guard let handler = onStreamNativeSize else { return }
        pipeline.adoptLayerSize(points)
        let current = VideoSize(width: Double(bounds.width), height: Double(bounds.height))
        guard StreamSizeSnap.shouldSnap(target: points, current: current) else { return }
        handler(
            CGSize(width: points.width, height: points.height),
            CGSize(width: current.width, height: current.height),
        )
    }

    private func applyToggleFill() {
        let next: VideoContentMode = (pipeline.contentMode == .fit) ? .fill : .fit
        pipeline.setContentMode(next)
        controls?.mode = next
    }

    private func applyResetZoom() {
        zoom = 1
        pan = .zero
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = false
    }

    private func installGesturesIfNeeded() {
        guard !gesturesInstalled else { return }
        gesturesInstalled = true
        isUserInteractionEnabled = true
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        for g in [pinch, pan, doubleTap] as [UIGestureRecognizer] { g.delegate = self
            addGestureRecognizer(g)
        }
    }

    // Let pinch + pan run together (zoom while dragging).
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool { true }

    @objc
    private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { gestureBaseZoom = zoom }
        zoom = min(max(gestureBaseZoom * g.scale, 1), 8)
        if zoom <= 1.001 { pan = .zero }
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = zoom > 1.001
    }

    @objc
    private func onPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { gestureBasePan = pan }
        let t = g.translation(in: self)
        let invZoom = 1.0 / zoom
        pan.x = gestureBasePan.x - (t.x / max(bounds.width, 1)) * invZoom
        pan.y = gestureBasePan.y - (t.y / max(bounds.height, 1)) * invZoom
        pipeline.setZoom(zoom, pan: pan)
    }

    @objc
    private func onDoubleTap() { applyResetZoom() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Render at native Retina resolution: set the layer's contentsScale to the screen
        // scale so the pipeline's drawableSize (points × contentsScale) is the pixel size.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        videoLayer.contentsScale = scale
        // Own drawableSize in the view (always lays out), same as the macOS sibling — so the
        // pixel size is correct regardless of renderer-activation ordering.
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        pipeline.layoutChanged(layerSize: VideoSize(width: Double(bounds.width), height: Double(bounds.height)))
    }
}
#endif
#endif
