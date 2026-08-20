#if canImport(SwiftUI) && canImport(QuartzCore) && canImport(Metal) && canImport(VideoToolbox)
import CoreImage
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
    /// The remote window's APP display name ("Xcode"/"Google Chrome" — the picker's
    /// `appName`); empty for a desktop pane or a legacy binding. Only the smart-zoom ⌘0 gate
    /// consults it (``PinchZeroPolicy``).
    public let targetAppName: String
    /// `nil` ⇒ no live connection (the seam's placeholder path / preview). When set,
    /// the backing view brings up the full client pipeline.
    public let connection: VideoWindowConnection?

    /// Whether this pane is the active/focused pane on the canvas. Only the active pane forwards
    /// pointer hover/clicks/pinch to the remote window; SCROLL follows the pointer instead (any pane
    /// under the cursor forwards it, ⌥-scroll routes to ``onCanvasScroll``). Plain (non-isolated)
    /// closures + Bool so the `AppMain` factory can bridge them across the seam without importing
    /// `SlopDeskClientUI`.
    let isActive: Bool
    /// READ-ONLY INPUT GATE. `false` ⇒ this pane is read-only: forward NEITHER pointer/scroll
    /// NOR keycodes to the host. A click may still ACTIVATE the workspace pane (`onActivate`), but it is not
    /// relayed and the host window is not raised; the paste-as-keystrokes sink is also withheld. Gated with
    /// `isActive && inputEnabled` on every relay. Defaults `true` (a writable pane).
    let inputEnabled: Bool
    /// BACKGROUND POINTER (satellite windows): `true` ⇒ the surface keeps taking pointer input while
    /// its window is NOT key, and a click leaves the window un-activated (``BackgroundPointerPolicy``).
    /// Defaults `false` (canvas panes keep click-to-activate).
    let backgroundPointer: Bool
    /// Make this pane active (set workspace focus) — called on click. The host window is also raised
    /// (via the pane's own `focusWindow`).
    let onActivate: () -> Void
    /// Pan the canvas on ⌥-scroll (a plain scroll is forwarded to the remote window under the pointer,
    /// focused or not).
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
    /// depth, host-reported RTT/encode (ms) and client decode (ms) EWMAs (`0` = no reading yet) —
    /// for the pane's stats surface. Primitives only (the seam is headless). `nil` ⇒ none.
    let onNetworkStatsReady: ((
        _ fps: Double, _ fecPerSec: Double, _ unrecoveredPerSec: Double, _ holdMs: Int, _ pacerDepth: Int,
        _ rttMs: Double, _ encodeMs: Double, _ decodeMs: Double,
    ) -> Void)?
    /// STREAM SETTINGS (fps cap / bitrate ceiling): the live view publishes a settings-drive closure
    /// here once its session exists (and `nil` on teardown), so the pane can request a live encode
    /// fps cap / bitrate ceiling (`0` = auto). Host-affecting — the seam withholds it while
    /// read-only, like the resize sink. `nil` ⇒ no canvas.
    let onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)?
    /// HOST AUDIO: the live view publishes an audio enable/disable closure here once its session
    /// exists (and `nil` on teardown), so the pane's speaker toggle can start/stop the host's
    /// app-audio stream (absolute `enabled`; the session stores the wish and re-sends it after
    /// every re-hello). Host-affecting — the seam withholds it while read-only, like the
    /// stream-settings sink. `nil` ⇒ no canvas.
    let onAudioInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)?
    /// PRIVACY BLANK: the live view publishes a privacy enable/disable closure here once its display
    /// session exists (and `nil` on teardown), so the desktop pane's shield toggle can black the host
    /// display + swallow local input. Host-affecting — the seam withholds it while read-only, like
    /// the audio sink. `nil` ⇒ no canvas.
    let onPrivacyInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)?
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
        targetAppName = ""
        connection = nil
        isActive = true
        inputEnabled = true
        backgroundPointer = false
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
        onAudioInjectorReady = nil
        onPrivacyInjectorReady = nil
        onSystemKeyInjectorReady = nil
        onStreamStallChanged = nil
        onSessionRejected = nil
    }

    /// Live remote-window view: brings up the orchestrator against `connection`. `isActive` /
    /// `onActivate` / `onCanvasScroll` carry the canvas pane behaviour (active-only pointer + click-to-
    /// activate + ⌥-scroll-to-pan); they default to the standalone (always-active) values.
    public init(
        title: String,
        targetAppName: String = "",
        connection: VideoWindowConnection,
        isActive: Bool = true,
        inputEnabled: Bool = true,
        backgroundPointer: Bool = false,
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
            _ rttMs: Double, _ encodeMs: Double, _ decodeMs: Double,
        ) -> Void)? = nil,
        onStreamSettingsInjectorReady: ((((_ fpsCap: Int, _ bitrateCeilingBps: Int) -> Void)?) -> Void)? = nil,
        onAudioInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)? = nil,
        onPrivacyInjectorReady: ((((_ enabled: Bool) -> Void)?) -> Void)? = nil,
        onSystemKeyInjectorReady: ((((
            _ keyCode: UInt16, _ modifierFlags: UInt64, _ isDown: Bool,
        ) -> Void)?) -> Void)? = nil,
        onStreamStallChanged: ((_ stalled: Bool) -> Void)? = nil,
        onSessionRejected: (() -> Void)? = nil,
    ) {
        self.title = title
        self.targetAppName = targetAppName
        self.connection = connection
        self.isActive = isActive
        self.inputEnabled = inputEnabled
        self.backgroundPointer = backgroundPointer
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
        self.onAudioInjectorReady = onAudioInjectorReady
        self.onPrivacyInjectorReady = onPrivacyInjectorReady
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
            targetAppName: targetAppName,
            isActive: isActive,
            inputEnabled: inputEnabled,
            backgroundPointer: backgroundPointer,
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
            onAudioInjectorReady: onAudioInjectorReady,
            onPrivacyInjectorReady: onPrivacyInjectorReady,
            onSystemKeyInjectorReady: onSystemKeyInjectorReady,
            onStreamStallChanged: onStreamStallChanged,
            onSessionRejected: onSessionRejected,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { SwipePeelOverlay(controls: controls) }
        .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

/// SWIPE-PEEL feedback chip (doc 05 §8) — a SwiftUI overlay, NEVER an NSView subview of the Metal view
/// (the rule at ``VideoPaneControls``: subviews + gesture recognizers on the layer-backed Metal view
/// perturbed its geometry and swallowed the `mouseUp` of a trackpad three-finger-drag → a stuck remote
/// button). Flat fills only — no material/blur over the `CAMetalLayer`.
///
/// Its own view because the pane has TWO mounts now: ``VideoWindowView`` (SwiftUI, and iOS's only shape)
/// and ``VideoSurfaceHost`` (AppKit, over a hit-transparent hosting view). The chip's placement rule is
/// small enough to be tempting to re-type on the second mount, and re-typing it is how the two panes stop
/// agreeing about which EDGE a forward peel lives on.
struct SwipePeelOverlay: View {
    @ObservedObject var controls: VideoPaneControls

    var body: some View {
        // The edge alignment lives INSIDE the conditional content so the removal transition keeps the chip
        // on ITS edge — an outer `alignment:` recomputed from nil would yank a fading forward-chip across
        // to the leading edge.
        ZStack {
            if let peel = controls.swipePeel {
                SwipePeelChipView(state: peel)
                    .padding(.horizontal, 14)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: peel.direction == .forward ? .trailing : .leading,
                    )
                    .transition(.opacity)
                    // Feedback only — never eats pane input (the house convention for overlays
                    // atop the Metal surface, see `GuiStatsReadout`): a click at the pane edge
                    // during the ~520 ms confirm hold must reach the remote window.
                    .allowsHitTesting(false)
            }
        }
        .animation(.timingCurve(0, 0, 0.58, 1, duration: 0.15), value: controls.swipePeel)
    }
}

/// The swipe-peel progress chip: a chevron in a flat circle whose ring fills toward the commit
/// threshold and turns solid the instant a release would navigate — the ENTIRE visible
/// feedback: the streamed image itself never moves (v6 HW verdict — a remote pane is a window
/// onto a desktop, so translating it reads as dragging the pane, not peeling a page). To still
/// live with the finger, the chip EMERGES from its pane edge as progress grows: tucked ~12 pt
/// at the arm line, fully out at commit. White-on-any-video (the Chromium overscroll idiom
/// users already know), flat fills only (no material — never glass over the `CAMetalLayer`).
struct SwipePeelChipView: View {
    let state: SwipePeelChipState
    /// Reduce Motion: the chip renders IN PLACE (no tuck emergence, no scale pulse) and changes
    /// by fades only. The ring fill, the committed solid state and the haptic stay — they are
    /// information, not motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Emergence: progress is quantized to 1/32 by the planner, so the outer `.animation`
        // smooths this into a glide instead of re-laying-out per 120 Hz event.
        let tuck = reduceMotion ? 0 : (1 - state.progress) * 12
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
        .scaleEffect(reduceMotion ? 1.0 : (state.confirming ? 1.12 : (state.committed ? 1.06 : 1.0)))
        .shadow(color: Color.black.opacity(0.25), radius: 4, y: 1)
        .offset(x: state.direction == .back ? -tuck : tuck)
        // Confirm pulse → DIM HOLD: the scale-up plays inside the ambient 0.15 s curve, then the
        // chip HOLDS at low opacity until the ~520 ms clear task removes it (the removal
        // transition fades the rest) — the hold is what actually spans the 150–400 ms
        // inject→capture→stream beat, the only fire acknowledgement there is. Fading to 0 here
        // would end the visible pulse at ~150 ms and hold an invisible chip.
        .opacity(state.confirming ? 0.35 : 1)
    }
}

#if os(macOS)
/// Env-gated (`SLOPDESK_VIDEO_DEBUG`) stderr diagnostics for the remote-GUI VIEW layer (scroll routing +
/// isActive delivery) — the BUG-2 ground-truth probe: logging both distinguishes a stale/sticky
/// `isActive` value from a downstream scroll-routing problem.
func videoViewDbg(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("SlopDesk[video.client.view]: \(message())\n".utf8))
}

/// `NSViewRepresentable` host backing the `CAMetalLayer` + cursor overlay on macOS.
struct MetalVideoLayerView: NSViewRepresentable {
    let connection: VideoWindowConnection?
    var controls: VideoPaneControls?
    /// The bound remote app's display name (empty = desktop pane / unknown) — the smart-zoom
    /// ⌘0 gate's input (``PinchZeroPolicy``).
    var targetAppName: String = ""
    var isActive: Bool = true
    /// READ-ONLY INPUT GATE: `false` ⇒ the backing view forwards no pointer/scroll/keycode to the
    /// host (gated `isActive && inputEnabled`) and withholds the paste-as-keystrokes sink. Set on every render.
    var inputEnabled: Bool = true
    /// BACKGROUND POINTER (satellite windows): pointer interaction while the window is NOT key —
    /// see ``BackgroundPointerPolicy``. Set on every render.
    var backgroundPointer: Bool = false
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
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int, Double, Double, Double) -> Void)?
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    var onAudioInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onPrivacyInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    var onStreamStallChanged: ((Bool) -> Void)?
    var onSessionRejected: (() -> Void)?

    func makeNSView(context _: Context) -> MetalLayerBackedView { build() }

    func updateNSView(_ nsView: MetalLayerBackedView, context _: Context) { apply(to: nsView) }

    static func dismantleNSView(_ nsView: MetalLayerBackedView, coordinator _: ()) {
        nsView.deactivate()
    }

    /// The `makeNSView` body, callable WITHOUT a SwiftUI `Context` (neither this nor ``apply(to:)`` ever
    /// read one). ``VideoSurfaceHost`` mounts the same view into an AppKit canvas and drives it through
    /// these two methods, so the mount-time wiring and the per-render wiring are each written once — the
    /// alternative is an AppKit half that re-derives which sinks are published before `activate` and which
    /// after, and is right by luck until someone adds the next sink.
    func build() -> MetalLayerBackedView {
        let view = MetalLayerBackedView()
        view.controls = controls
        view.targetAppName = targetAppName
        view.isActive = isActive
        view.inputEnabled = inputEnabled
        view.backgroundPointer = backgroundPointer
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
        // HOST AUDIO: publish the enable/disable drive (the session stores the wish and re-sends it at
        // every handshake, so a pre-stream request is safe). Host-affecting, so the seam binds nil
        // while read-only, like the stream-settings sink.
        view.onAudioInjectorReady = onAudioInjectorReady
        view.publishAudioInjector()
        // PRIVACY BLANK: publish the enable/disable drive (stored + re-sent at handshake). Host-
        // affecting, so the seam binds nil while read-only, like the audio sink.
        view.onPrivacyInjectorReady = onPrivacyInjectorReady
        view.publishPrivacyInjector()
        // SYSTEM-KEY INJECTOR: publish the programmatic key drive (same wire path as local keyDown/keyUp;
        // `pipeline.key` no-ops until the session is up). Host input — seam binds nil while read-only.
        view.onSystemKeyInjectorReady = onSystemKeyInjectorReady
        view.publishSystemKeyInjector()
        // BUG-2 probe: a recreate (makeNSView) on focus change — vs an in-place updateNSView — would reset
        // isActive to its `true` default mid-stream; logging it distinguishes "stale Bool" from "recreate".
        videoViewDbg("makeNSView (CREATED) isActive=\(isActive)")
        return view
    }

    /// The `updateNSView` body, callable without a `Context` — see ``build()``.
    func apply(to nsView: MetalLayerBackedView) {
        nsView.controls = controls
        nsView.targetAppName = targetAppName
        if nsView.isActive != isActive { videoViewDbg("updateNSView isActive \(nsView.isActive)→\(isActive)") }
        nsView.isActive = isActive
        // READ-ONLY INPUT GATE: apply the current gate every render. On a FLIP, re-publish the
        // paste-as-keystrokes sink so the seam's `onKeyInjectorReady` (which binds a nil sink while read-only)
        // re-evaluates — locking a live pane withholds the sink, unlocking restores it, with no view rebuild.
        let inputGateFlipped = nsView.inputEnabled != inputEnabled
        nsView.inputEnabled = inputEnabled
        nsView.backgroundPointer = backgroundPointer
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
            // STREAM SETTINGS + AUDIO + SYSTEM KEYS: read-only-gated like the resize/key sinks — a flip
            // re-evaluates the seam's nil-binding (lock withholds, unlock restores).
            nsView.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
            nsView.publishStreamSettingsInjector()
            nsView.onAudioInjectorReady = onAudioInjectorReady
            nsView.publishAudioInjector()
            nsView.onPrivacyInjectorReady = onPrivacyInjectorReady
            nsView.publishPrivacyInjector()
            nsView.onSystemKeyInjectorReady = onSystemKeyInjectorReady
            nsView.publishSystemKeyInjector()
        }
    }
}

// MARK: - The native half of the video pixel seam (docs/56 stage F, risk 2)

/// The AppKit mount of one remote-GUI pane: the same `MetalLayerBackedView` ``VideoWindowView`` mounts,
/// added straight into an AppKit canvas instead of through an `NSHostingView` over an `AnyView`.
///
/// WHY the seam widened rather than the canvas thickening: `MetalLayerBackedView` is ALREADY an `NSView`,
/// and `VideoWindowFactory.shared` only returns an `AnyView` because neither UI target may NAME that type.
/// A hosting view between the canvas and a `CAMetalLayer` buys nothing and costs a full-bleed hit-test
/// claim over a surface that forwards pointer traffic to a remote desktop.
///
/// ONE hosting view survives, and deliberately: the swipe-peel chip. It is a ~120-line SwiftUI drawing
/// that no AppKit caller has any reason to own a second copy of, it is `allowsHitTesting(false)` on the
/// SwiftUI side already, and ``PeelOverlayHostingView`` returns `nil` from `hitTest` so it claims nothing
/// here either. That is the whole distinction risk 2 draws: a hosting view that takes input over the pixel
/// surface is the bug; one that is provably transparent to it is a renderer.
///
/// Conforms to `SlopDeskWorkspaceCore.RemoteSurfaceHosting` RETROACTIVELY, from the app target — this
/// module never imports `SlopDeskWorkspaceCore` (the seam exists for exactly that reason), so the three
/// members below are spelled to match that protocol and the conformance is declared where both are
/// visible, like `WindowFeedChannel: @retroactive HostWindowFeedLink`.
public final class VideoSurfaceHost: NSView {
    /// The Metal-backed pane view. Owned as a subview; it owns the decode pipeline for its lifetime.
    private let surface: MetalLayerBackedView
    /// The control bridge, owned here for this host's lifetime — the AppKit twin of `VideoWindowView`'s
    /// `@StateObject`. The Metal view publishes the swipe-peel state onto it; the chip overlay reads it.
    private let controls: VideoPaneControls
    /// The mount-time binding, kept so ``setPaneGates(isActive:inputEnabled:backgroundPointer:)`` can
    /// re-run the same `apply(to:)` the SwiftUI half re-runs on every render.
    private var binding: MetalVideoLayerView

    /// Builds the AppKit mount from the SAME value the SwiftUI mount is built from, so the app target's
    /// two registrations cannot drift: whatever it hands `VideoWindowFactory.shared` it also hands here.
    public init(_ pane: VideoWindowView) {
        // Locals through phase 1: `self` is off limits until `super.init`, so the binding is built from a
        // local `controls` and the surface from the local binding, then both are stored.
        let controls = VideoPaneControls()
        let binding = MetalVideoLayerView(
            connection: pane.connection,
            controls: controls,
            targetAppName: pane.targetAppName,
            isActive: pane.isActive,
            inputEnabled: pane.inputEnabled,
            backgroundPointer: pane.backgroundPointer,
            onActivate: pane.onActivate,
            onCanvasScroll: pane.onCanvasScroll,
            onStreamNativeSize: pane.onStreamNativeSize,
            onKeyInjectorReady: pane.onKeyInjectorReady,
            onResizeInjectorReady: pane.onResizeInjectorReady,
            onViewportInjectorReady: pane.onViewportInjectorReady,
            onInputReleaseReady: pane.onInputReleaseReady,
            onWindowGeometryReady: pane.onWindowGeometryReady,
            onStreamCadenceReady: pane.onStreamCadenceReady,
            onStreamBitrateReady: pane.onStreamBitrateReady,
            onNetworkStatsReady: pane.onNetworkStatsReady,
            onStreamSettingsInjectorReady: pane.onStreamSettingsInjectorReady,
            onAudioInjectorReady: pane.onAudioInjectorReady,
            onPrivacyInjectorReady: pane.onPrivacyInjectorReady,
            onSystemKeyInjectorReady: pane.onSystemKeyInjectorReady,
            onStreamStallChanged: pane.onStreamStallChanged,
            onSessionRejected: pane.onSessionRejected,
        )
        self.controls = controls
        self.binding = binding
        surface = binding.build()
        super.init(frame: .zero)
        surface.autoresizingMask = [.width, .height]
        surface.frame = bounds
        addSubview(surface)

        let chip = PeelOverlayHostingView(rootView: SwipePeelOverlay(controls: controls))
        chip.autoresizingMask = [.width, .height]
        chip.frame = bounds
        // The hosting view must not paint a background over the video: `NSHostingView` is otherwise
        // transparent, but an opaque backing would composite a grey plate over every decoded frame.
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(chip)
        // Accessibility rides the container, not the Metal view: the pixels have no structure to expose.
        setAccessibilityLabel("Remote GUI window: \(pane.title)")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// `RemoteSurfaceHosting`: the view the canvas adds. It is this container (the Metal view and the
    /// chip are its subviews and are never handed out separately).
    public var surfaceView: NSView { self }

    /// `RemoteSurfaceHosting`: the AppKit twin of `updateNSView`. SwiftUI re-runs the whole binding on
    /// every render; an AppKit canvas has no such pass, so the three gates that actually change at runtime
    /// are pushed explicitly and then run through the SAME `apply(to:)` — including its read-only-flip
    /// branch, which is the only thing that withdraws and restores the host-affecting injector sinks.
    public func setPaneGates(isActive: Bool, inputEnabled: Bool, backgroundPointer: Bool) {
        binding.isActive = isActive
        binding.inputEnabled = inputEnabled
        binding.backgroundPointer = backgroundPointer
        binding.apply(to: surface)
    }

    /// `RemoteSurfaceHosting`: the AppKit twin of `dismantleNSView`. Removing this view from its superview
    /// is NOT enough — the session owns two UDP sockets, a VideoToolbox decoder and a display link.
    public func detachSurface() { surface.deactivate() }
}

/// An `NSHostingView` that is transparent to the hit-test, so the swipe-peel chip floating over the video
/// surface cannot swallow a click the remote desktop is owed. `allowsHitTesting(false)` inside the SwiftUI
/// content is not enough on its own: the HOSTING view is an ordinary `NSView` in the AppKit responder
/// chain, and it is the one the canvas's `hitTest` walks.
final class PeelOverlayHostingView: NSHostingView<SwipePeelOverlay> {
    override func hitTest(_: NSPoint) -> NSView? { nil }
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

    /// BACKGROUND POINTER (satellite windows): `true` ⇒ this surface keeps taking pointer input while
    /// its window is NOT key — hover/scroll/click/drag forward to the host and a click leaves the
    /// window un-activated (typing stays wherever the user is working; see
    /// ``BackgroundPointerPolicy``). Threaded from the `RemotePaneContext` seam — the leaf grants it
    /// only to a DETACHED pane, so canvas panes keep the click-to-activate rule. A flip rebuilds the
    /// tracking area: its activation scope (`.activeAlways` vs `.activeInKeyWindow`) is baked in at
    /// install. Set by `MetalVideoLayerView` on every render.
    var backgroundPointer: Bool = false {
        didSet {
            guard backgroundPointer != oldValue else { return }
            updateTrackingAreas()
            // Flag flips OFF while the window is NOT key with the pointer parked inside: removing the
            // `.activeAlways` area synthesizes NO mouseExited, and the replacement `.activeInKeyWindow`
            // area is inert in a not-key window — so run mouseExited's cleanup here, or `pointerInside`
            // stays stale, an in-flight edge-pan keeps panning, and the host cursor shape stays frozen
            // over the pane. (The ON direction self-heals: adding an active area under the pointer
            // synthesizes mouseEntered.)
            if !backgroundPointer, window?.isKeyWindow != true, pointerInside {
                pointerInside = false
                stopEdgePan()
                NSCursor.arrow.set()
            }
        }
    }

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
    /// Pan the canvas by a (sign-adjusted) delta — called from `scrollWheel` on ⌥-scroll.
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
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int, Double, Double, Double) -> Void)?
    /// STREAM SETTINGS: the canvas publishes a settings-drive sink through this (and `nil` on teardown;
    /// the seam binds nil while read-only — host-affecting, like the resize sink). `(fpsCap,
    /// bitrateCeilingBps)`, 0 = auto. Set by the representable.
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    /// HOST AUDIO: the canvas publishes an audio enable/disable sink through this (and `nil` on
    /// teardown; the seam binds nil while read-only — host-affecting, like the stream-settings
    /// sink). Absolute `enabled`. Set by the representable.
    var onAudioInjectorReady: ((((Bool) -> Void)?) -> Void)?
    /// PRIVACY BLANK: the canvas publishes the host-display-blank enable sink through this (and `nil`
    /// on teardown; the seam binds nil while read-only). Absolute `enabled`. Set by the representable.
    var onPrivacyInjectorReady: ((((Bool) -> Void)?) -> Void)?
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
    /// ViewportCommand` (0 zoom-in / 1 zoom-out / 2 reset / 3 lock-on / 4 lock-off / 5 fit-to-pane).
    /// Set by the representable.
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

    /// Hands the canvas an audio enable/disable drive routed to THIS view's pipeline (the session
    /// stores the wish and re-sends it after every re-hello). `self` weak so a torn-down view
    /// drives nothing. Idempotent — safe to call on every render.
    func publishAudioInjector() {
        onAudioInjectorReady? { [weak self] enabled in
            self?.pipeline.setAudioEnabled(enabled)
        }
    }

    /// Hands the canvas a privacy enable/disable drive routed to THIS view's pipeline (the session
    /// stores the wish and re-sends it after every re-hello). `self` weak so a torn-down view drives
    /// nothing. Idempotent — safe to call on every render.
    func publishPrivacyInjector() {
        onPrivacyInjectorReady? { [weak self] enabled in
            self?.pipeline.setPrivacyEnabled(enabled)
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
    /// 0 zoom-in / 1 zoom-out / 2 reset / 3 lock-on / 4 lock-off / 5 fit-to-pane). The lock commands are
    /// ABSOLUTE (not a toggle): the model owns the lock state and RE-ASSERTS it on every sink publish (a
    /// detach/reattach re-binds the same model to a fresh, unlocked view), so a redundant re-assert must be
    /// idempotent here.
    private func handleViewportCommand(_ command: UInt8) {
        // PAN LOCK gates every pan-moving command HERE, not only at the footer buttons: zoom
        // re-anchors `panOffset` and reset/fit re-anchor top-left, so any of them would silently
        // defeat a held lock — and palette/chord-originated commands reach this handler directly.
        // While locked, they no-op entirely; only the lock commands themselves still apply.
        switch command {
        case 0 where !panLocked: applyZoom(1.25) // zoom in one step
        case 1 where !panLocked: applyZoom(1.0 / 1.25) // zoom out one step
        case 2 where !panLocked: applyResetZoom() // 1× + re-anchor top-left
        case 3: // "lock position" ON (freeze edge-pan)
            panLocked = true
            stopEdgePan()
        case 4: // "lock position" OFF (resume edge-pan on the next hover)
            panLocked = false
        case 5 where !panLocked: applyFitToPane() // zoom so the whole window fits inside the pane
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
    /// the pointer nudges the pane edges. A MIRROR of ``RemoteWindowModel/viewportLocked`` (the source of
    /// truth behind the footer lock control + the ⌥⌘L chord), driven by the absolute `lockOn`/`lockOff`
    /// viewport commands so the model can re-assert it into a fresh view; clears the pan timer on engage.
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
    //    the one piece of native swipe-back a key translation can't — something reacting WHILE
    //    the fingers are on the glass. The feedback is the edge chip + haptic ONLY: the streamed
    //    image never moves (v6 HW verdict — a remote pane is a window onto a whole desktop, so
    //    any translation of it reads as dragging the pane, not peeling a page). The host stays
    //    the sole authority on firing ⌘[/⌘].
    private var peelPlanner = SwipePeelPlanner()
    /// The host's swipe-nav operating point (cursor-socket type=3 push). `nil` until the first
    /// push — an old host never shows the overlay, so the affordance can't lie.
    private var peelStatus: SwipeNavStatusMessage?
    /// Rising-edge tracker for the commit haptic (tap once when "release now navigates" starts).
    private var peelChipCommitted = false
    /// Delayed clear of the confirm-pulse chip after a fire.
    private var peelConfirmClear: Task<Void, Never>?
    /// Per-gesture remote-vs-canvas routing pin (see ``ScrollRoutePinner``): an ⌥ press/release
    /// mid-gesture must not reroute the momentum tail.
    private var scrollRoutePinner = ScrollRoutePinner()

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
                snapshot.rttMillis,
                snapshot.encodeMillis,
                snapshot.decodeMillis,
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
        abandonSwipePeel() // never strand a mid-gesture chip across a teardown
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
        if BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
           pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor
        {
            cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Forward `winLoc` (window-space, as delivered by `NSEvent.locationInWindow`) to the host as a
    /// bare mouse-move so the host cursor WARPS to the client pointer — resyncing the remote cursor
    /// SHAPE without waiting for the next hover move. Gated exactly like `mouseMoved`.
    private func forwardPointer(atWindowLocation winLoc: NSPoint) {
        guard BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
              inputEnabled else { return }
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
    /// The bound remote app's DISPLAY NAME (`RemoteWindowDescriptor.appName` — picker style,
    /// "Xcode"/"Google Chrome"); empty for a desktop pane or a legacy binding. Only consulted
    /// by the smart-zoom ⌘0 gate (``PinchZeroPolicy``) — everything else is app-agnostic.
    var targetAppName = ""
    /// ANSI key POSITIONS (HIToolbox `kVK_ANSI_*`), interpreted by the host layout like any
    /// forwarded keystroke.
    private static let keyEqual: UInt16 = 0x18 // kVK_ANSI_Equal → ⌘= zoom in
    private static let keyMinus: UInt16 = 0x1B // kVK_ANSI_Minus → ⌘− zoom out
    private static let keyZero: UInt16 = 0x1D // kVK_ANSI_0 → ⌘0 actual size
    private static let keyCommandModifier: UInt16 = 0x37 // kVK_Command — the chord bracket
    private static let keyRightCommandModifier: UInt16 = 0x36 // kVK_RightCommand — same latch
    private var pinchPlanner = PinchZoomKeyPlanner()

    /// Two-finger pinch → ⌘= / ⌘− steps on the HOST. Unlike scroll (which follows the pointer), a
    /// pinch is a zoom COMMAND: only the ACTIVE, writable pane forwards; an unfocused or read-only
    /// pane swallows the pinch (it must not perturb local geometry either).
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
    /// natural pairing with the pinch's ⌘= / ⌘− ladder. Skipped where ⌘0 is NOT a zoom reset
    /// (``PinchZeroPolicy`` — Xcode toggles its Navigator with it); ⌘=/⌘− stay ungated, they
    /// are the correct zoom chords in editors too.
    override func smartMagnify(with _: NSEvent) {
        guard isActive, inputEnabled, Self.pinchKeysEnabled else { return }
        guard PinchZeroPolicy.allowsReset(appName: targetAppName) else { return }
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

    /// FIT TO PANE → set the client zoom so the WHOLE remote window is visible inside the pane (the
    /// smaller of the per-axis pane/window ratios, clamped to the same `[0.25, 4]` ladder as the zoom
    /// steps) and re-anchor top-left. At the fitted zoom there is no overflow (both displayed axes ≤ the
    /// pane), so edge-pan goes inert on its own — except when the 0.25 floor clips a >4×-oversized window,
    /// where the top-left anchor still shows the most content the ladder allows. A no-op until the host
    /// window's point size is known (`streamPoints`).
    private func applyFitToPane() {
        guard let win = streamPoints, win.width > 1, win.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let fit = Swift.min(bounds.width / CGFloat(win.width), bounds.height / CGFloat(win.height))
        clientZoom = Swift.min(Swift.max(fit, 0.25), 4.0)
        viewportTouched = false
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
        if BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
           inputEnabled
        {
            pipeline.mouseMove(VideoPoint(x: Double(lastPointerView.x), y: Double(bounds.height - lastPointerView.y)))
        }
        if xDone, yDone { stopEdgePan() }
    }

    // MARK: Input forwarding (view space → normalised → host)

    private func viewPoint(_ event: NSEvent) -> VideoPoint {
        // Convert to this view's coordinates, then flip Y so origin is TOP-left (the
        // orientation the host window space + InputEventEncoder normalisation expect).
        let p = convert(event.locationInWindow, from: nil)
        return VideoPoint(x: Double(p.x), y: Double(bounds.height - p.y))
    }

    private func mods(_ event: NSEvent) -> InputModifiers { Self.modifiers(event.modifierFlags) }

    /// Clamps `NSEvent.clickCount` (an unbounded `Int` — AppKit keeps incrementing it for consecutive
    /// in-place clicks within the double-click interval) into the wire `UInt8`. `UInt8(clamping:)`
    /// saturates at 255 instead of the trapping `UInt8(Int)` that would crash the client on a 256th rapid
    /// click; identical for every real 1/2/3-click, and the host only uses it as a click-state hint
    /// (`max(1, Int(clickCount))`), so saturating is harmless.
    nonisolated static func clampClickCount(_ n: Int) -> UInt8 { UInt8(clamping: n) }

    // Only the ACTIVE pane tracks hover (the "only the active pane swallows pointer" rule) — plus a
    // BACKGROUND-POINTER satellite, whose whole point is hover-following while another window holds
    // the keyboard. A non-active canvas pane still ignores hover so it never injects a stray remote
    // mouse-move; you must click it first.
    override func mouseMoved(with event: NSEvent) {
        guard BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer)
        else { return }
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
    // BACKGROUND-POINTER exception: on a NOT-key satellite the click is delivered to the host with the
    // LOCAL window left un-activated — `preventWindowOrdering` cancels the ordering that
    // `shouldDelayWindowOrdering` deferred (the drag-from-a-background-window mechanism), and
    // `onActivate` is skipped so local (workspace + key-window + first-responder) focus stays wherever
    // the user is typing. The HOST-side raise (`focusWindow`) still runs: it never touches local focus,
    // and a window-scoped satellite needs raise-then-click for the positional click to land right.
    override func mouseDown(with event: NSEvent) {
        // BUG-1 probe: clicking is the reported freeze trigger. Correlate this line with `cursorAPPLY`/
        // `RENDER` gaps (client main-actor block from focus()) and `mediaRX` gaps (host capture hitch on
        // window-raise) to see which path stalls on a click.
        let backgroundClick = BackgroundPointerPolicy.backgroundClick(
            backgroundPointer: backgroundPointer, windowIsKey: window?.isKeyWindow == true,
        )
        videoViewDbg("click → \(backgroundClick ? "background" : "activate") isActive=\(isActive)")
        if backgroundClick {
            NSApp.preventWindowOrdering()
        } else {
            onActivate()
        }
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
        // BACKGROUND-POINTER: a right-click never orders a window front on macOS, so only the local
        // activation is skipped — the context-click still reaches the host below.
        if !BackgroundPointerPolicy.backgroundClick(
            backgroundPointer: backgroundPointer, windowIsKey: window?.isKeyWindow == true,
        ) {
            onActivate()
        }
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
        // SCROLL ROUTING — scroll follows the POINTER, not focus (the terminal pane's rule too):
        //   • plain scroll → forward to the REMOTE window under the pointer, focused or NOT, so a
        //     background editor can be scrolled/compared while focus (and typing) stays in the working
        //     pane. Forwarding is a UDP send — no `@Observable` mutation, so it never blocks the stream.
        //   • ⌥ held       → PAN THE CANVAS — the one deliberate pan-over-a-pane route. Routed through
        //     the debounced `onCanvasScroll` accumulator (NOT a per-step commitCamera), so it never
        //     blocks the stream either.
        // The choice is PINNED per gesture (`ScrollRoutePinner`): decided at began/mayBegin and held
        // through the momentum tail, so pressing/releasing ⌥ mid-gesture can't reroute the inertia into
        // the other destination. Phase-less wheel ticks keep the live per-event decision.
        // Natural-scroll sign matches `CanvasView.PanView` so a pane-pan feels identical to the bg pan.
        // READ-ONLY: a locked pane does NOT swallow the scroll into the remote window —
        // `inputEnabled == false` falls through to the canvas-pan branch (view-only, no host relay).
        // Deliberately a LIVE gate, never pinned: locking mid-gesture must stop host relay at once.
        let scrollPhase = Self.cgScrollPhaseCode(event.phase)
        let momentumPhase = Self.cgMomentumPhaseCode(event.momentumPhase)
        let routeRemote = scrollRoutePinner.route(
            liveRemote: !event.modifierFlags.contains(.option),
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
        )
        if routeRemote, inputEnabled {
            videoViewDbg("scroll → remote")
            // Forward the trackpad gesture state so the host can replay a native continuous/inertial
            // scroll (Began→Changed→Ended, then momentum Begin→Continue→End) instead of a phase-less
            // wheel tick. `event.phase` (finger-on-glass) and `event.momentumPhase` (coast) are
            // distinct and mutually exclusive; map each to its CoreGraphics integer code.
            pipeline.scroll(
                dx: Double(event.scrollingDeltaX),
                dy: Double(event.scrollingDeltaY),
                viewPoint: viewPoint(event),
                scrollPhase: scrollPhase,
                momentumPhase: momentumPhase,
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
    /// immediately (the host would ignore the fire), and so does the shown chip's direction
    /// going history-DEAD (the ~250 ms change-poll can land mid-gesture) — EXCEPT a confirming
    /// chip: a fired back-nav flips canGoBack itself within one poll, and cutting the 520 ms
    /// confirm hold on that push would erase the acknowledgement of the very fire that caused
    /// it. A knob change rebuilds the (idle) mirror so a host-side
    /// `SLOPDESK_SWIPE_NAV_TRAVEL`/`_SLOW` retune never desynchronises the feedback.
    private func adoptSwipeNavStatus(_ status: SwipeNavStatusMessage) {
        let previous = peelStatus
        peelStatus = status
        if !status.eligible {
            abandonSwipePeel()
        } else if let chip = controls?.swipePeel, !chip.confirming, !status.allowsChip(chip.direction) {
            abandonSwipePeel()
        }
        if previous?.fireTravel != status.fireTravel || previous?.slowTier != status.slowTier {
            peelPlanner = SwipePeelPlanner(
                fireTravel: Double(status.fireTravel), slowSwipe: status.slowTier,
            )
        }
    }

    /// Mirrors one forwarded scroll event into the peel planner and applies its verdict. Gated
    /// on the host saying the target app is eligible AT ALL — no push yet (old host) ⇒ nothing
    /// — then per-direction on the pushed history state (``SwipePeelPlanner/historyGated``):
    /// the planner still tracks the gesture (its state must mirror the host recogniser's), but
    /// a dead-direction chip never surfaces.
    private func feedSwipePeel(_ event: NSEvent) {
        guard let status = peelStatus, status.eligible else { return }
        let verdict = peelPlanner.ingest(
            dx: Double(event.scrollingDeltaX),
            dy: Double(event.scrollingDeltaY),
            scrollPhase: Self.cgScrollPhaseCode(event.phase),
            momentumPhase: Self.cgMomentumPhaseCode(event.momentumPhase),
            continuous: event.hasPreciseScrollingDeltas,
            now: event.timestamp,
        )
        applySwipePeel(SwipePeelPlanner.historyGated(verdict, status: status))
    }

    private func applySwipePeel(_ verdict: SwipePeelPlanner.Verdict) {
        switch verdict {
        case .idle:
            return
        case let .show(chip):
            peelConfirmClear?.cancel()
            peelConfirmClear = nil
            if chip.committed, !peelChipCommitted {
                // The moment the chip turns solid: "release now navigates".
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            peelChipCommitted = chip.committed
            if controls?.swipePeel != chip { controls?.swipePeel = chip }
        case let .commit(direction):
            peelChipCommitted = false
            controls?.swipePeel = SwipePeelChipState(
                direction: direction, progress: 1, committed: true, confirming: true,
            )
            peelConfirmClear?.cancel()
            peelConfirmClear = Task { [weak self] in
                // The chip's confirm pulse + DIM HOLD (see `SwipePeelChipView`) span the beat
                // where the host's ⌘[/⌘] lands and the post-navigation page streams in — the
                // only fire acknowledgement there is; this clear then fades the held chip out.
                try? await Task.sleep(nanoseconds: 520_000_000)
                guard !Task.isCancelled else { return }
                self?.controls?.swipePeel = nil
            }
        case .retract:
            peelChipCommitted = false
            // Two guards, both for the history gate's relabelled verdicts (a dead-direction
            // gesture converts EVERY qualifying event to `.retract`): a nil-over-nil assign
            // would re-fire the @Published pane invalidation ~80×/gesture for zero visible
            // change, and a CONFIRMING chip must keep its 520 ms hold — the planner resets
            // `showing` at commit, so the only live publish a `.retract` can coexist with is
            // the PREVIOUS gesture's confirm hold (double-back at history end), which the
            // pending clear task ends. A genuine same-gesture retract always finds a
            // non-confirming chip and clears it exactly once.
            if let chip = controls?.swipePeel, !chip.confirming {
                controls?.swipePeel = nil
            }
        }
    }

    /// Abandons any in-flight peel candidate (scroll rerouted, eligibility off, teardown): the
    /// planner resets and, if the chip was showing, it fades out.
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
    // WORKSPACE CHORDS over the video pane.
    //
    // A LOCAL workspace chord (⌘D/⌘T/…) MUST NOT leak to the remote host. That interception is UPSTREAM:
    // the app-level `WorkspaceKeyDispatcher` installs ONE
    // `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` at launch, firing BEFORE the first responder —
    // so a resolved chord is consumed (handler returns `nil`) and this `keyDown` is NEVER reached for
    // those. A bare key returns unchanged and lands here as normal typing.
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

    /// BACKGROUND POINTER: the FIRST click on a not-key satellite must reach `mouseDown` — by default
    /// AppKit consumes it purely to activate the window, so the remote click would be lost.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { backgroundPointer }

    /// …and the window ordering that first click triggers is DELAYED (to mouseUp) so `mouseDown` can
    /// cancel it outright with `preventWindowOrdering` — the click then acts on the host with the
    /// local window left inactive, exactly like a drag lifted from a background Finder window.
    override func shouldDelayWindowOrdering(for _: NSEvent) -> Bool { backgroundPointer }

    /// AppKit only delivers `mouseMoved` when a tracking area requests it, and
    /// `acceptsFirstResponder` alone does NOT focus a bare layer-backed view inside a
    /// SwiftUI sheet — so without these two the cursor-follow + keyboard input paths are
    /// dead. Install/refresh a tracking area for the visible bounds, and grab first
    /// responder when the view enters a window.
    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        // BACKGROUND POINTER: a satellite surface keeps hover/cursor tracking alive while its window
        // is NOT key (`.activeAlways` — the window server still delivers tracking events to a
        // background window). Everywhere else `.activeInKeyWindow` stands: a background WORKSPACE
        // window must not start forwarding hover just because the pointer crosses it.
        let activation: NSTrackingArea.Options = backgroundPointer ? .activeAlways : .activeInKeyWindow
        let area = NSTrackingArea(
            // `.mouseEnteredAndExited` tracks whether the pointer is in the pane; `.cursorUpdate` makes
            // AppKit call `cursorUpdate(with:)` on each move so we re-assert the host's cursor shape.
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, activation, .inVisibleRect],
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
        if BackgroundPointerPolicy.forwardsPointer(isActive: isActive, backgroundPointer: backgroundPointer),
           pipeline.isServerCursorVisible, let cursor = pipeline.currentRemoteCursor
        {
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
    // Signature parity with the macOS representable (the shared `VideoWindowView.body` passes it).
    // The smart-zoom ⌘0 gate is a TRACKPAD `smartMagnify` translation; a phone has no two-finger
    // double-tap on a trackpad to gate, so this stays unread here.
    var targetAppName: String = ""
    /// Whether this is the workspace's focused pane. The phone forwards pointer input from ANY pane the
    /// finger lands on — exactly like the Mac's `mouseDown`, which is never `isActive`-gated (only HOVER
    /// is, and there is no hover here). What this drives is the KEYBOARD: the surface claims/releases
    /// first responder with the focus flip, so a hardware keyboard types into the focused pane.
    var isActive: Bool = true
    /// READ-ONLY INPUT GATE, and it is live now: `false` ⇒ this surface forwards NEITHER touch-derived
    /// pointer traffic NOR keycodes, and the seam withholds the host-affecting injector sinks. Set on
    /// every render, exactly like the macOS half.
    var inputEnabled: Bool = true
    // Signature parity with the macOS representable. Background-pointer interaction is "keep taking
    // pointer input while the window is NOT key", and iOS has no key-window state (nor a second window a
    // pane can be popped into) — the phone reads it as nothing, so it is accepted + ignored here.
    var backgroundPointer: Bool = false
    var onActivate: () -> Void = {}
    // Signature parity. ⌥-scroll-to-pan-the-canvas is a trackpad route; the phone's canvas is navigated
    // by its own gestures outside this surface, so the seam binds an empty closure and nothing calls it.
    var onCanvasScroll: (CGSize) -> Void = { _ in }
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    var onInputReleaseReady: (((() -> Void)?) -> Void)?
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    var onStreamCadenceReady: ((Int) -> Void)?
    var onStreamBitrateReady: ((Int) -> Void)?
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int, Double, Double, Double) -> Void)?
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    var onAudioInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onPrivacyInjectorReady: ((((Bool) -> Void)?) -> Void)?
    /// The ONE sink this half deliberately leaves unbound, and not for want of wiring: its argument is a
    /// raw `NSEvent.ModifierFlags` bit pattern and its only producer is `SystemKeyCaptureController`'s
    /// `CGEventTap` — neither of which exists in the iOS SDK. `PaneImmersiveCapture.isSupported` is
    /// already `false` here, so the footer draws no immersive chip; publishing a sink would light
    /// `RemoteWindowModel.canInjectSystemKeys` for a capture that can never run. See docs/56 increment 80.
    var onSystemKeyInjectorReady: ((((UInt16, UInt64, Bool) -> Void)?) -> Void)?
    var onStreamStallChanged: ((Bool) -> Void)?
    var onSessionRejected: (() -> Void)?

    func makeUIView(context _: Context) -> MetalLayerBackedView {
        let view = MetalLayerBackedView(frame: .zero)
        view.controls = controls
        view.isActive = isActive
        view.inputEnabled = inputEnabled
        view.onActivate = onActivate
        view.onStreamNativeSize = onStreamNativeSize // before activate — nil-ness picks snap vs host-follow
        // BEFORE activate, for the same reasons the macOS `build()` gives: the first decoded frame, the
        // first host cadence announcement, the first ~2 Hz stats aggregate, a stall detected on the very
        // first monitor tick and an immediate `helloAck(accepted: false)` must each find their sink set.
        view.onWindowGeometryReady = onWindowGeometryReady
        view.onStreamCadenceReady = onStreamCadenceReady
        view.onStreamBitrateReady = onStreamBitrateReady
        view.onNetworkStatsReady = onNetworkStatsReady
        view.onStreamStallReady = onStreamStallChanged
        view.onSessionRejectedReady = onSessionRejected
        view.activate(connection: connection)
        // AFTER activate — `pipeline.*` no-ops until the session is up, so publishing now is safe, and
        // the model's `didSet` re-asserts (audio / lock / stream overrides) need a live sink to push into.
        view.onKeyInjectorReady = onKeyInjectorReady
        view.publishKeyInjector()
        view.onResizeInjectorReady = onResizeInjectorReady
        view.publishResizeInjector()
        view.onViewportInjectorReady = onViewportInjectorReady
        view.publishViewportInjector()
        view.onInputReleaseReady = onInputReleaseReady
        view.publishInputReleaseInjector()
        view.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
        view.publishStreamSettingsInjector()
        view.onAudioInjectorReady = onAudioInjectorReady
        view.publishAudioInjector()
        view.onPrivacyInjectorReady = onPrivacyInjectorReady
        view.publishPrivacyInjector()
        return view
    }

    func updateUIView(_ uiView: MetalLayerBackedView, context _: Context) {
        uiView.controls = controls
        uiView.isActive = isActive
        // READ-ONLY INPUT GATE: on a FLIP, re-publish every sink the seam withholds while read-only, so
        // locking a live pane withdraws them and unlocking restores them with no view rebuild — the
        // macOS `apply(to:)` branch, transposed. The viewport sink is NOT in it (pure client compositor
        // ops), which is why the pane's fit/zoom/lock stay live on a locked phone pane.
        let inputGateFlipped = uiView.inputEnabled != inputEnabled
        uiView.inputEnabled = inputEnabled
        uiView.onActivate = onActivate
        uiView.onStreamNativeSize = onStreamNativeSize
        uiView.onViewportInjectorReady = onViewportInjectorReady
        uiView.onWindowGeometryReady = onWindowGeometryReady
        uiView.onStreamCadenceReady = onStreamCadenceReady
        uiView.onStreamBitrateReady = onStreamBitrateReady
        uiView.onNetworkStatsReady = onNetworkStatsReady
        uiView.onStreamStallReady = onStreamStallChanged
        uiView.onSessionRejectedReady = onSessionRejected
        uiView.activate(connection: connection)
        if inputGateFlipped {
            uiView.onKeyInjectorReady = onKeyInjectorReady
            uiView.publishKeyInjector()
            uiView.onResizeInjectorReady = onResizeInjectorReady
            uiView.publishResizeInjector()
            uiView.onInputReleaseReady = onInputReleaseReady
            uiView.publishInputReleaseInjector()
            uiView.onStreamSettingsInjectorReady = onStreamSettingsInjectorReady
            uiView.publishStreamSettingsInjector()
            uiView.onAudioInjectorReady = onAudioInjectorReady
            uiView.publishAudioInjector()
            uiView.onPrivacyInjectorReady = onPrivacyInjectorReady
            uiView.publishPrivacyInjector()
        }
    }

    static func dismantleUIView(_ uiView: MetalLayerBackedView, coordinator _: ()) {
        uiView.deactivate()
    }
}

/// A `UIView` whose `layerClass` is `CAMetalLayer`, owning the client pipeline — and the phone's whole
/// input half for a remote desktop.
///
/// TOUCH IS TRANSLATED HERE, NOT MIRRORED. `AndroidScreenUIView` and `SimulatorScreenUIView` both open by
/// saying a finger on the mirror IS the finger, and send the contact through unchanged. A remote
/// *desktop* has no touch to receive — only a pointer — so this is the one surface in the tree that must
/// SYNTHESIZE one, and the vocabulary it synthesizes is written down in ``TouchPointerPlan`` rather than
/// here, because this class (a `CAMetalLayer` over a VideoToolbox decoder) can never be built in a test.
/// What is taken from those two files verbatim is the lifecycle discipline they earned: the two-contact
/// LATCH (once a second finger lands the gesture stays a pair to its end — dropping back to one contact
/// because a finger lifted a frame early reads as a fling), the CLAMPED drag (a drag that leaves the
/// frame is still a drag), and cancelled touches LIFTED rather than forgotten.
///
/// Deliberately NO `UIGestureRecognizer`s, which is a change from the local-only zoom/pan this surface
/// used to have: recognizers arbitrate against each other and against the SwiftUI canvas above, and a
/// recognizer that "fails" 300 ms after the finger lands is 300 ms of a click the user already made.
/// Raw `touchesBegan`/`Moved`/`Ended`/`Cancelled`, exactly like the two sibling surfaces.
final class MetalLayerBackedView: UIView {
    override static var layerClass: AnyClass { CAMetalLayer.self }
    var videoLayer: CAMetalLayer {
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("layerClass is CAMetalLayer, so the backing layer is always a CAMetalLayer")
        }
        return metalLayer
    }

    private let pipeline = VideoWindowPipeline()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        isUserInteractionEnabled = true
        // The pair gestures are two REAL contacts (not a synthesized second finger the way the Mac's
        // magnify translation needs), so multi-touch has to be on for `event.touches(for:)` to ever
        // report more than one.
        isMultipleTouchEnabled = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    // ── VIEWPORT (client-side, never the host). The renderer crops UV for zoom + pan. Unlike the Mac's
    //    oversized-sublayer viewport there is no overflow to clip — the phone's pane IS the viewport and
    //    the stream `.fit`s into it — so `zoom`/`pan` go straight to `pipeline.setZoom`, which moves the
    //    renderer AND the session's input inverse together (a click while zoomed must land where it looks).
    private var zoom: CGFloat = 1
    private var pan: CGPoint = .zero
    /// "LOCK POSITION" (the footer lock, ⌥⌘L, the palette): freezes local viewport MOVEMENT. A MIRROR of
    /// ``RemoteWindowModel/viewportLocked`` driven by the ABSOLUTE `lockOn`/`lockOff` viewport commands,
    /// so the model can re-assert it into a freshly-mounted view and the re-assert is idempotent. Host
    /// scroll is untouched by it: the lock is about where the pane is LOOKING, not what reaches the desktop.
    private var panLocked = false

    /// Whether this pane is the workspace's focused one. Drives the KEYBOARD only — pointer traffic
    /// forwards from any pane the finger lands on, matching the Mac's never-`isActive`-gated `mouseDown`.
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                claimKeyboardFocus()
            } else {
                // The release `pressesEnded` for a modifier held across a focus move goes to the NEW
                // responder, so the host would keep it latched (and a later scroll would ride ⌘).
                releaseLatchedModifiers()
                if isFirstResponder { _ = resignFirstResponder() }
            }
        }
    }

    /// READ-ONLY INPUT GATE. `false` ⇒ every touch-derived pointer relay and every keycode is suppressed.
    /// A touch still ACTIVATES the pane (`onActivate`), exactly like a click on a locked Mac pane. Set by
    /// the representable on every render.
    var inputEnabled: Bool = true

    /// Make this pane the active pane — called on the first contact (the Mac's click-to-activate). The
    /// phone's `PaneContainer` also carries an `onTapGesture` for this, but a UIKit surface that claims
    /// the touch is exactly what stops that SwiftUI gesture from ever firing.
    var onActivate: () -> Void = {}

    /// Bridge to the SwiftUI control overlay (fit/fill toggle + zoom reset). Set by the
    /// representable before `activate`.
    weak var controls: VideoPaneControls?
    /// 1:1 PANE SNAP (see the macOS sibling): ask the canvas pane to resize its video content from
    /// `current` to `target` points. Set by the representable BEFORE ``activate(connection:)``.
    var onStreamNativeSize: ((CGSize, CGSize) -> Void)?

    // ── The seam's sinks. Same names, same contracts and the same before/after-`activate` split as the
    //    macOS sibling's; see `MetalVideoLayerView.makeUIView` for which side of `activate` each goes on.
    var onKeyInjectorReady: ((((UInt16, Bool, Bool) -> Void)?) -> Void)?
    var onResizeInjectorReady: ((((Double, Double) -> Void)?) -> Void)?
    var onViewportInjectorReady: ((((UInt8) -> Void)?) -> Void)?
    var onInputReleaseReady: (((() -> Void)?) -> Void)?
    var onStreamSettingsInjectorReady: ((((Int, Int) -> Void)?) -> Void)?
    var onAudioInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onPrivacyInjectorReady: ((((Bool) -> Void)?) -> Void)?
    var onWindowGeometryReady: ((Double, Double, Double, Double) -> Void)?
    var onStreamCadenceReady: ((Int) -> Void)?
    var onStreamBitrateReady: ((Int) -> Void)?
    var onNetworkStatsReady: ((Double, Double, Double, Int, Int, Double, Double, Double) -> Void)?
    var onStreamStallReady: ((Bool) -> Void)?
    var onSessionRejectedReady: (() -> Void)?

    /// The host window's current POINT size, and the host-reported MAX resizable size. `nil` until the
    /// first decoded frame / the host's `displayMax` lands — the geometry push then leaves the far side's
    /// field uncapped, exactly as on macOS.
    private var streamPoints: VideoSize?
    private var displayMaxPoints: VideoSize?

    /// MODIFIER LATCH: which modifier keyCodes this view forwarded as down and has not released. A focus
    /// move or an unmount that swallows the `pressesEnded` would otherwise leave the host's shared
    /// `hidSystemState` source latched (a plain scroll then rides ⌘ and the remote page zooms).
    private var modifierLatch = ModifierLatchTracker()

    func activate(connection: VideoWindowConnection?) {
        // 1:1 PANE SNAP — wire BEFORE pipeline.activate (nil-ness picks snap vs host-follow at
        // session construction; mirrors the macOS sibling).
        pipeline.onStreamNativePoints = onStreamNativeSize == nil ? nil : { [weak self] points in
            self?.adoptStreamNativePoints(points)
        }
        pipeline.activate(view: self, videoLayer: videoLayer, connection: connection)
        // HOST-WINDOW GEOMETRY: the current point size (first decoded frame + every host resize) and the
        // display max. The phone has no "Resize…" popover yet, but the model's `windowPointSize` is what
        // one would pre-fill from, and it is the same push the Mac makes — leaving it dark would be the
        // next increment re-deriving it.
        pipeline.onDecodedPointsChanged = { [weak self] points in
            guard let self else { return }
            streamPoints = points
            publishWindowGeometry()
        }
        pipeline.onDisplayMaxChanged = { [weak self] points in
            guard let self else { return }
            displayMaxPoints = points
            publishWindowGeometry()
        }
        // CONNECTION STATS + NETWORK-STATS MIRROR: the readings behind the footer's stats chip, which
        // until now opened onto five rows of "—" for a session's whole life.
        pipeline.onStreamCadenceChanged = { [weak self] fps in self?.onStreamCadenceReady?(fps) }
        pipeline.onStreamBitrateChanged = { [weak self] kbps in self?.onStreamBitrateReady?(kbps) }
        pipeline.onNetworkStatsChanged = { [weak self] snapshot in
            self?.onNetworkStatsReady?(
                snapshot.framesPerSecond,
                snapshot.fecRecoveredPerSecond,
                snapshot.unrecoveredPerSecond,
                snapshot.holdMillis,
                snapshot.pacerDepth,
                snapshot.rttMillis,
                snapshot.encodeMillis,
                snapshot.decodeMillis,
            )
        }
        // STALL: forward the flip so `StreamStallCaption` can finally appear. There is NO grayscale drain
        // twin here — the Mac desaturates the frozen frame through `CALayer.filters`, which UIKit does not
        // implement (the property exists and is ignored). The caption carries the whole signal on the phone.
        pipeline.onStreamStallChanged = { [weak self] stalled in self?.onStreamStallReady?(stalled) }
        // TERMINAL REFUSAL: the pipeline has already torn down with no auto-rebuild; forwarding is what
        // moves the pane off a dead black surface and onto the picker/error state.
        pipeline.onSessionRejected = { [weak self] in self?.onSessionRejectedReady?() }
        if connection != nil, let controls {
            controls.onToggleFill = { [weak self] in self?.applyToggleFill() }
            controls.onResetZoom = { [weak self] in self?.applyResetZoom() }
            controls.mode = pipeline.contentMode
        }
    }

    /// HOST-WINDOW GEOMETRY: push current + max POINT sizes to the seam. A zero max means "not yet
    /// known". No-op until the first decoded frame, or when no canvas wired the sink.
    private func publishWindowGeometry() {
        guard let cur = streamPoints else { return }
        onWindowGeometryReady?(cur.width, cur.height, displayMaxPoints?.width ?? 0, displayMaxPoints?.height ?? 0)
    }

    func deactivate() {
        // Never strand a contact or a modifier on the HOST: its event source is process-global there, so a
        // button left down or a ⌘ left latched outlives this pane. The sends are best-effort (the outbound
        // FIFO stops inside `pipeline.deactivate()`), which is exactly the Mac's bargain too.
        liftAllContacts()
        releaseLatchedModifiers()
        // Deliberately NO nil-publish of the injector sinks — see the macOS `deactivate()` for the
        // detach/reattach race that makes an unconditional clear here kill the REPLACEMENT view's input.
        pipeline.deactivate()
    }

    // MARK: Injector sinks (published to the seam → `RemoteWindowModel`)

    /// PASTE AS KEYSTROKES: the sink behind the footer's clipboard plate, whose every row was permanently
    /// `.disabled` while this was unpublished (`canPasteKeystrokes` false forever). Shift folds into the
    /// modifiers exactly as on macOS.
    func publishKeyInjector() {
        onKeyInjectorReady? { [weak self] keyCode, down, shift in
            self?.pipeline.key(keyCode: keyCode, down: down, modifiers: shift ? .shift : [])
        }
    }

    /// RESIZE: an ABSOLUTE host-window POINT size. No phone surface drives it yet; the sink is published
    /// because `canResizeWindow` is what a surface would gate on, and a live session is the only thing
    /// that makes it true.
    func publishResizeInjector() {
        onResizeInjectorReady? { [weak self] width, height in
            self?.pipeline.userResizeTo(width: width, height: height)
        }
    }

    /// STREAM SETTINGS (fps cap / bitrate ceiling): the footer's stream-quality popover.
    func publishStreamSettingsInjector() {
        onStreamSettingsInjectorReady? { [weak self] fpsCap, bitrateCeilingBps in
            self?.pipeline.updateStreamSettings(fpsCap: fpsCap, bitrateCeilingBps: bitrateCeilingBps)
        }
    }

    /// HOST AUDIO: the footer's speaker toggle. `AudioStreamDecoder` and its `AVAudioEngine` playback are
    /// already cross-platform — nothing but this publish was missing.
    func publishAudioInjector() {
        onAudioInjectorReady? { [weak self] enabled in self?.pipeline.setAudioEnabled(enabled) }
    }

    /// PRIVACY BLANK: the desktop pane's shield. Host-side verb end to end — the phone only asks.
    func publishPrivacyInjector() {
        onPrivacyInjectorReady? { [weak self] enabled in self?.pipeline.setPrivacyEnabled(enabled) }
    }

    /// VIEWPORT CONTROLS: fit / − / 1× / + / lock. Pure client compositor ops, so this sink is NOT
    /// read-only-gated and is never withdrawn on a lock flip.
    func publishViewportInjector() {
        onViewportInjectorReady? { [weak self] command in self?.handleViewportCommand(command) }
    }

    /// RELEASE STUCK INPUT: the palette's escape hatch. It has something to release NOW — before touch
    /// forwarding existed this pane could not leave a button or a modifier down on the host.
    func publishInputReleaseInjector() {
        onInputReleaseReady? { [weak self] in self?.releaseAllStuckInput() }
    }

    /// Synthesize a key-UP for every held-modifier keyCode plus a mouse-UP for every button, through the
    /// same send paths the automatic releases use. The host's `InputButtonBalance` suppresses whichever
    /// are no-ops there, so firing this on a healthy session is harmless.
    private func releaseAllStuckInput() {
        guard inputEnabled else { return }
        _ = modifierLatch.drainForRelease()
        for keyCode in InputModifierKeys.heldModifierKeyCodes.sorted() {
            pipeline.key(keyCode: keyCode, down: false, modifiers: [])
        }
        let centre = VideoPoint(x: Double(bounds.midX), y: Double(bounds.midY))
        for button in [MouseButton.left, .right, .other] {
            pipeline.mouseUp(button, centre, 1, [])
        }
    }

    // MARK: Viewport commands (the footer control bar)

    /// Apply one ``RemoteWindowModel/ViewportCommand`` byte. The lock commands are ABSOLUTE (the model
    /// owns the state and re-asserts it on every publish), so a redundant re-assert must be idempotent —
    /// and every pan-moving command is gated on the lock HERE, not only at the footer buttons, because
    /// zoom and reset both re-anchor the crop and would silently defeat a held lock.
    private func handleViewportCommand(_ command: UInt8) {
        switch command {
        case 0 where !panLocked: applyZoomStep(stepIn: true)
        case 1 where !panLocked: applyZoomStep(stepIn: false)
        case 2 where !panLocked: applyResetZoom()
        case 3: panLocked = true
        case 4: panLocked = false
        // FIT on the phone is `.fit` content mode at 1×: the pane IS the viewport and the stream already
        // letterboxes into it, so "the whole window visible" and "actual size" coincide — what fit adds
        // over reset is undoing a `.fill`.
        case 5 where !panLocked:
            pipeline.setContentMode(.fit)
            controls?.mode = .fit
            applyResetZoom()
        default: break
        }
    }

    /// One footer zoom step, re-anchored so the PANE CENTRE stays put (the Mac's rule). The crop is
    /// centre-based already, so holding the centre means holding `pan` and re-clamping it to the new
    /// zoom's tighter limit.
    private func applyZoomStep(stepIn: Bool) {
        let next = TouchPointerPlan.steppedZoom(Double(zoom), stepIn: stepIn)
        guard next != Double(zoom) else { return }
        zoom = CGFloat(next)
        pan.x = CGFloat(TouchPointerPlan.clampPan(Double(pan.x), zoom: next))
        pan.y = CGFloat(TouchPointerPlan.clampPan(Double(pan.y), zoom: next))
        commitViewport()
    }

    private func applyToggleFill() {
        let next: VideoContentMode = (pipeline.contentMode == .fit) ? .fill : .fit
        pipeline.setContentMode(next)
        controls?.mode = next
    }

    private func applyResetZoom() {
        zoom = 1
        pan = .zero
        commitViewport()
    }

    /// Push the viewport to the renderer AND the session in one call — they must move together or a
    /// click while zoomed lands at the un-zoomed source position — and mirror the "zoomed" light.
    private func commitViewport() {
        pipeline.setZoom(zoom, pan: pan)
        controls?.zoomed = Double(zoom) > TouchPointerPlan.minZoom
    }

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

    // MARK: Touch → pointer

    /// The ONE-CONTACT gesture in flight: where it landed (view points), where it is now, whether it
    /// has escaped the tap slop, whether a long press already spent it, and its `UITouch.tapCount`.
    private var pointerOrigin: CGPoint?
    private var pointerLatest: CGPoint = .zero
    private var pointerDragging = false
    private var pointerConsumed = false
    private var pointerTapCount = 1
    private var longPressTask: Task<Void, Never>?

    /// The TWO-CONTACT gesture in flight, LATCHED (the sibling surfaces' rule): set when a second
    /// contact lands and cleared only when the last contact leaves, so a pair that momentarily reports
    /// one touch cannot fall back into a drag halfway through a scroll.
    private var pairLatched = false
    private var pairRoute: TouchPairRoute?
    private var pairBaseSpan: Double = 0
    private var pairOrigin: CGPoint = .zero
    private var pairLatestCentroid: CGPoint = .zero
    private var pairBaseZoom: CGFloat = 1
    private var pairBasePan: CGPoint = .zero
    private var pairScrollStarted = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // ACTIVATE UNCONDITIONALLY: a read-only pane still takes workspace focus from a tap, exactly as
        // a click on a locked Mac pane does. It has to happen here — a UIKit surface that claims the
        // touch is what stops the container's SwiftUI tap gesture from ever firing.
        onActivate()
        if !isActive, inputEnabled { pipeline.focusWindow() }
        claimKeyboardFocus()
        let live = event?.touches(for: self) ?? touches
        if live.count >= 2 {
            guard !pairLatched else { return }
            // A second finger means the first one was never a click: abandon it WITHOUT the tap.
            cancelPointer()
            beginPair(live)
            return
        }
        guard !pairLatched, let touch = live.first else { return }
        beginPointer(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let live = event?.touches(for: self) ?? touches
        if pairLatched {
            movePair(live)
            return
        }
        guard let touch = live.first, let origin = pointerOrigin else { return }
        // Clamped rather than dropped — the sibling surfaces' rule: a drag that leaves the frame is
        // still a drag, and the host needs the intermediate points to read a selection rather than a jump.
        let point = clampedPoint(touch)
        pointerLatest = point
        let escaped = TouchPointerPlan.escapesTapSlop(
            dx: Double(point.x - origin.x), dy: Double(point.y - origin.y),
        )
        guard escaped else { return }
        if !pointerDragging {
            longPressTask?.cancel()
            longPressTask = nil
            // A long press that already fired its right click owns the contact: the finger sliding
            // afterwards must not start a left drag underneath the context menu.
            guard !pointerConsumed else { return }
            pointerDragging = true
            // The button goes down where the finger LANDED, not where it has reached — a drag whose
            // press lands 11 pt along has already missed the handle the user grabbed.
            pipeline.mouseDown(.left, hostPoint(origin), TouchPointerPlan.clickCount(pointerTapCount), mods(event))
        }
        guard pointerDragging else { return }
        pipeline.mouseDrag(.left, hostPoint(point), TouchPointerPlan.clickCount(pointerTapCount), mods(event))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches, event, cancelled: false)
    }

    /// A cancelled touch is LIFTED, not forgotten (the sibling surfaces' rule). The system takes touches
    /// away for its own gestures; leaving the button down would strand it on the host — where the event
    /// source is process-global — until the next press.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches, event, cancelled: true)
    }

    private func finishTouches(_ touches: Set<UITouch>, _ event: UIEvent?, cancelled: Bool) {
        let remaining = event?.touches(for: self)?.subtracting(touches) ?? []
        guard remaining.isEmpty else { return }
        if pairLatched {
            endPair()
            return
        }
        endPointer(cancelled: cancelled, event: event)
    }

    /// The view or the session is going away. Contacts are LIFTED rather than forgotten — the Android
    /// surface can forget its fingers because an `up` has nowhere to go once its socket is gone, but a
    /// desktop's event source is process-global: a button left down there outlives this pane entirely.
    private func liftAllContacts() {
        longPressTask?.cancel()
        longPressTask = nil
        if inputEnabled {
            if pointerDragging {
                pipeline.mouseUp(.left, hostPoint(pointerLatest), TouchPointerPlan.clickCount(pointerTapCount), [])
            }
            if pairRoute == .scroll, pairScrollStarted {
                pipeline.scroll(
                    dx: 0, dy: 0, viewPoint: hostPoint(pairLatestCentroid),
                    scrollPhase: TouchPointerPlan.scrollPhase(isFirst: false, isLast: true),
                    continuous: true,
                )
            }
        }
        pointerOrigin = nil
        pointerDragging = false
        pointerConsumed = false
        pairLatched = false
        pairRoute = nil
        pairScrollStarted = false
    }

    // MARK: One contact

    private func beginPointer(_ touch: UITouch) {
        let point = clampedPoint(touch)
        pointerOrigin = point
        pointerLatest = point
        pointerDragging = false
        pointerConsumed = false
        pointerTapCount = Swift.max(1, touch.tapCount)
        guard inputEnabled else { return }
        // Warp the host pointer under the finger the instant it lands. Hover-only UI (tooltips, menu
        // highlight, a hover-revealed close box) needs the move at all, and a click that arrives without
        // one lands wherever the pointer was left by the last gesture.
        pipeline.mouseMove(hostPoint(point))
        armLongPress()
    }

    /// End a one-contact gesture: lift a drag, or emit the click a tap earned. A CANCELLED tap emits
    /// nothing — the system took the touch for its own gesture, and the user did not click anything.
    private func endPointer(cancelled: Bool, event: UIEvent?) {
        longPressTask?.cancel()
        longPressTask = nil
        defer {
            pointerOrigin = nil
            pointerDragging = false
            pointerConsumed = false
        }
        guard inputEnabled, pointerOrigin != nil else { return }
        let clicks = TouchPointerPlan.clickCount(pointerTapCount)
        if pointerDragging {
            pipeline.mouseUp(.left, hostPoint(pointerLatest), clicks, mods(event))
            return
        }
        guard !cancelled, !pointerConsumed else { return }
        // Move-then-click, and the move goes to the LIFT point: a finger that rolled 3 pt inside the slop
        // still means the pixel it left, and the host's hover state has to agree with the click.
        let point = hostPoint(pointerLatest)
        pipeline.mouseMove(point)
        pipeline.mouseDown(.left, point, clicks, mods(event))
        pipeline.mouseUp(.left, point, clicks, mods(event))
    }

    /// Drop a one-contact gesture without clicking, because a second finger joined it.
    private func cancelPointer() {
        longPressTask?.cancel()
        longPressTask = nil
        if pointerDragging, inputEnabled {
            pipeline.mouseUp(.left, hostPoint(pointerLatest), TouchPointerPlan.clickCount(pointerTapCount), [])
        }
        pointerOrigin = nil
        pointerDragging = false
        pointerConsumed = false
    }

    /// Arm the RIGHT CLICK. A phone has no second button and no ⌃-click (there is no ⌃ to hold), so the
    /// long press is the only route to a context menu — which on a desktop is where half the verbs live.
    private func armLongPress() {
        longPressTask?.cancel()
        longPressTask = Task { [weak self] in
            let delay = UInt64(TouchPointerPlan.longPressDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.fireLongPress()
        }
    }

    private func fireLongPress() {
        guard inputEnabled, !pointerDragging, !pointerConsumed, pointerOrigin != nil else { return }
        pointerConsumed = true
        longPressTask = nil
        // The remote menu opens with no local animation to announce it, and the finger is covering the
        // spot it opens at — the tap of feedback is what tells the user the press took.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let point = hostPoint(pointerLatest)
        pipeline.mouseMove(point)
        pipeline.mouseDown(.right, point, 1, [])
        pipeline.mouseUp(.right, point, 1, [])
    }

    // MARK: Two contacts

    private func beginPair(_ touches: Set<UITouch>) {
        pairLatched = true
        pairRoute = nil
        pairScrollStarted = false
        pairBaseZoom = zoom
        pairBasePan = pan
        let contacts = pairContacts(touches)
        pairBaseSpan = Self.contactGap(contacts)
        pairOrigin = Self.centroid(contacts)
        pairLatestCentroid = pairOrigin
    }

    private func movePair(_ touches: Set<UITouch>) {
        let contacts = pairContacts(touches)
        guard contacts.count == 2 else { return } // a pair that dropped to one contact holds its state
        let centroid = Self.centroid(contacts)
        let gap = Self.contactGap(contacts)
        let travelX = Double(centroid.x - pairOrigin.x)
        let travelY = Double(centroid.y - pairOrigin.y)
        let horizontal = travelX * travelX
        let vertical = travelY * travelY
        let travel = (horizontal + vertical).squareRoot()
        let route = pairRoute ?? classifyPair(spanDelta: gap - pairBaseSpan, centroidTravel: travel)
        guard let route else { return } // still undecided: a two-finger REST must move nothing
        pairRoute = route
        switch route {
        case .zoom: applyPinch(contactGap: gap, centroid: centroid)
        case .pan: applyPairPan(centroid: centroid)
        case .scroll: applyPairScroll(centroid: centroid)
        }
        pairLatestCentroid = centroid
    }

    private func endPair() {
        if pairRoute == .scroll, pairScrollStarted, inputEnabled {
            // The finger's lift ENDS the host gesture. No momentum tail is invented: UIKit hands a raw
            // touch surface no coast events, so claiming one would be a fling the finger never threw.
            pipeline.scroll(
                dx: 0, dy: 0, viewPoint: hostPoint(pairLatestCentroid),
                scrollPhase: TouchPointerPlan.scrollPhase(isFirst: false, isLast: true),
                momentumPhase: 0, continuous: true,
            )
        }
        pairLatched = false
        pairRoute = nil
        pairScrollStarted = false
    }

    /// Classify a live pair, honouring the viewport LOCK: a locked viewport cannot move, so neither
    /// local branch exists and the pair can only mean the one thing left — a host scroll. Saying that as
    /// "classify it as if at 1×" reuses the pure rule instead of writing a second one.
    private func classifyPair(spanDelta: Double, centroidTravel: Double) -> TouchPairRoute? {
        guard !panLocked else {
            return TouchPointerPlan.classifyPair(
                spanDelta: 0, centroidTravel: centroidTravel, zoom: TouchPointerPlan.minZoom,
            )
        }
        return TouchPointerPlan.classifyPair(
            spanDelta: spanDelta, centroidTravel: centroidTravel, zoom: Double(zoom),
        )
    }

    /// LOCAL zoom from the live span ratio, with the centroid's travel riding along as pan — the map
    /// idiom, where one gesture both magnifies and repositions.
    private func applyPinch(contactGap: Double, centroid: CGPoint) {
        // A degenerate pair (both contacts on one pixel) would divide by zero; holding the base beats a
        // NaN reaching the renderer's UV crop.
        var ratio = 1.0
        if pairBaseSpan > 0 { ratio = contactGap / pairBaseSpan }
        let next = TouchPointerPlan.pinchedZoom(base: Double(pairBaseZoom), spanRatio: ratio)
        zoom = CGFloat(next)
        applyPan(from: centroid, zoom: next)
    }

    private func applyPairPan(centroid: CGPoint) {
        applyPan(from: centroid, zoom: Double(zoom))
    }

    /// Move the renderer's UV crop by the centroid's travel since the pair landed. The sign is the
    /// drag-the-paper one the old pan recognizer had: the crop moves OPPOSITE the finger, so the image
    /// follows it. Divided by the zoom because a crop point covers `1/zoom` of the pane at that scale.
    private func applyPan(from centroid: CGPoint, zoom next: Double) {
        let width = Swift.max(bounds.width, 1)
        let height = Swift.max(bounds.height, 1)
        let invZoom = 1.0 / CGFloat(Double.maximum(next, TouchPointerPlan.minZoom))
        let travelX = (centroid.x - pairOrigin.x) / width
        let travelY = (centroid.y - pairOrigin.y) / height
        let stepX = travelX * invZoom
        let stepY = travelY * invZoom
        pan.x = CGFloat(TouchPointerPlan.clampPan(Double(pairBasePan.x - stepX), zoom: next))
        pan.y = CGFloat(TouchPointerPlan.clampPan(Double(pairBasePan.y - stepY), zoom: next))
        commitViewport()
    }

    /// A HOST scroll at the centroid, phase-carrying and continuous, so the host replays a native
    /// trackpad gesture (Began→Changed→Ended) rather than a train of phase-less wheel ticks. The deltas
    /// are the centroid's per-event travel in view points — the same natural-scroll sign AppKit reports
    /// (finger right/down = positive), so the two clients feel identical against the same desktop.
    private func applyPairScroll(centroid: CGPoint) {
        guard inputEnabled else { return }
        let isFirst = !pairScrollStarted
        pairScrollStarted = true
        pipeline.scroll(
            dx: Double(centroid.x - pairLatestCentroid.x),
            dy: Double(centroid.y - pairLatestCentroid.y),
            viewPoint: hostPoint(centroid),
            scrollPhase: TouchPointerPlan.scrollPhase(isFirst: isFirst, isLast: false),
            momentumPhase: 0,
            continuous: true,
        )
    }

    /// The two contacts of a pair, clamped, and ordered by position so a jitter cannot swap which finger
    /// is which between two batches (the Android surface's ordering, for the same reason). A third finger
    /// is ignored rather than re-basing the gesture.
    private func pairContacts(_ touches: Set<UITouch>) -> [CGPoint] {
        let points = touches.map { clampedPoint($0) }
            .sorted { (lhs: CGPoint, rhs: CGPoint) in lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x }
        return Array(points.prefix(2))
    }

    private static func centroid(_ contacts: [CGPoint]) -> CGPoint {
        guard let first = contacts.first else { return .zero }
        guard contacts.count > 1 else { return first }
        return CGPoint(x: (first.x + contacts[1].x) / 2, y: (first.y + contacts[1].y) / 2)
    }

    /// The distance between the two contacts (view points). A lone contact reports 0, which reads as a
    /// degenerate pair everywhere it is used.
    private static func contactGap(_ contacts: [CGPoint]) -> Double {
        guard contacts.count > 1 else { return 0 }
        let dx = Double(contacts[1].x - contacts[0].x)
        let dy = Double(contacts[1].y - contacts[0].y)
        let horizontal = dx * dx
        let vertical = dy * dy
        return (horizontal + vertical).squareRoot()
    }

    // MARK: Geometry

    /// A view point as the encoder wants it: TOP-LEFT origin, unscaled, un-panned. `InputEventEncoder`
    /// already inverts zoom, pan and content mode on the way out, so the view must NOT pre-apply them —
    /// and UIKit's coordinate space is the top-left one it expects (the Mac's half flips because AppKit
    /// is bottom-left).
    private func hostPoint(_ point: CGPoint) -> VideoPoint {
        VideoPoint(x: Double(point.x), y: Double(point.y))
    }

    private func clampedPoint(_ touch: UITouch) -> CGPoint {
        let point = touch.location(in: self)
        return CGPoint(
            x: Swift.min(Swift.max(point.x, 0), Swift.max(bounds.width, 0)),
            y: Swift.min(Swift.max(point.y, 0), Swift.max(bounds.height, 0)),
        )
    }

    /// The modifiers a hardware keyboard is holding while a touch happens — ⇧-click and ⌘-click on an
    /// iPad with a keyboard, which is the pane's most likely home. `UIEvent` carries the live flags, so
    /// there is nothing to track; a bare finger reports `[]`.
    private func mods(_ event: UIEvent?) -> InputModifiers {
        guard let flags = event?.modifierFlags else { return [] }
        return Self.modifiers(flags)
    }

    // MARK: Keyboard

    /// A hardware keyboard on iPad types into the focused pane — the same rule the Mac's
    /// `acceptsFirstResponder` gives it, and the same one both sibling surfaces already follow.
    override var canBecomeFirstResponder: Bool { true }

    private func claimKeyboardFocus() {
        guard !isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        // Focus moved: the release `pressesEnded` for anything still held goes to the NEW responder, so
        // the host would keep it latched and the next scroll would ride ⌘ (the remote page zooms).
        releaseLatchedModifiers()
        return super.resignFirstResponder()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        liftAllContacts()
        releaseLatchedModifiers()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardKeys(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardKeys(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    /// A cancelled press is RELEASED, not forgotten — the same bargain as a cancelled touch.
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardKeys(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    /// Forward a `UIPress` batch to the host as POSITIONAL keycodes, and report whether anything was
    /// consumed (nothing consumed ⇒ the responder chain continues, which is what keeps a key with no
    /// macOS equivalent from vanishing into this pane).
    ///
    /// SCANCODE MODE, the rule the Mac's `keyDown` states: the layout-level keycode is what travels, so
    /// the HOST's layout and input method compose it — a pre-baked Unicode string is invisible to a
    /// keycode-driven IME, and Vietnamese Telex would never form. UIKit dispatches `UIKeyCommand` and
    /// SwiftUI `.keyboardShortcut` BEFORE `pressesBegan`, which reproduces the Mac's local-monitor
    /// precedence for free: the workspace's own chords are taken first and never reach the desktop.
    private func forwardKeys(_ presses: Set<UIPress>, down: Bool) -> Bool {
        guard inputEnabled else { return false }
        var consumed = false
        for press in presses {
            guard let key = press.key else { continue }
            let usage = UInt16(clamping: key.keyCode.rawValue)
            guard let keyCode = HIDVirtualKeyMap.virtualKey(hidUsage: usage) else { continue }
            if HIDVirtualKeyMap.isModifier(hidUsage: usage) { modifierLatch.note(keyCode: keyCode, down: down) }
            pipeline.key(keyCode: keyCode, down: down, modifiers: Self.modifiers(key.modifierFlags))
            consumed = true
        }
        return consumed
    }

    /// Synthesize the key-ups for every modifier this view forwarded as down and has not released.
    private func releaseLatchedModifiers() {
        let stuck = modifierLatch.drainForRelease()
        guard !stuck.isEmpty else { return }
        for keyCode in stuck {
            pipeline.key(keyCode: keyCode, down: false, modifiers: [])
        }
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> InputModifiers {
        var modifiers: InputModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        return modifiers
    }

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
