// VideoPaneView — the SwiftUI entry point of the phone's remote-GUI pane, and its control
// bridge (docs/56 §3, the video carve).
//
// THIS FILE IS ONE HALF OF A DELIBERATE DUPLICATION. Its Mac twin is
// `SlopDeskVideoClientMac/MacVideoPaneView.swift`, and the two are not meant to converge — the
// user's standing directive is two separate implementations, and docs/56 §3 draws the line:
// LAYOUT diverges, CAPABILITY does not. Arrangement is duplicated; a RULE never is. Every decision
// (`TouchPointerPlan`, `ViewportZoom`, `ViewportPan`, `SwipePeelPlanner`) lives once in
// `SlopDeskVideoClient`, most of it already in Rust behind the FFI.
//
// THE SWIPE-PEEL CHIP IS HERE, and it is the split's rule working rather than an exception to it:
// the DRAWING is duplicated from the Mac's `MacSwipePeelChipView` because arrangement is layout,
// and neither the planner nor the chip's state machine is, because a decision is shared. The DRIVER
// used to be missing on this half, on a premise that was false: "a touch produces no scroll phases".
// A two-finger pair routed to `.scroll` produces exactly them — `MetalLayerBackedView` sends Began on
// the first move and Ended on the lift, because the host needs a native gesture rather than a train
// of wheel ticks — and the mirror now reads the same tuple. What a touch genuinely has none of is
// MOMENTUM, so the recogniser's coast arm is unreachable here and the lift is what fires.
#if os(iOS)
import CSlopDeskFFI
import QuartzCore
import SlopDeskVideoClient
import SlopDeskVideoProtocol
import SwiftUI

/// Bridges the SwiftUI overlay to the backing view's pipeline. Deliberately a SwiftUI overlay — NOT
/// AppKit/UIKit subviews of the Metal view: subviews + gesture recognizers on the layer-backed Metal
/// view perturbed its geometry and swallowed the `mouseUp` of a trackpad three-finger-drag (→ a stuck
/// remote button).
///
/// It used to advertise a "fit/fill toggle", and there was never anything on the other end: the
/// closure was declared on both halves, assigned on one, and INVOKED by nothing. Fit is reachable —
/// through the `ViewportCommand` byte, like every other footer verb — and fill is reachable from
/// neither platform. The dead closure is gone; adding fill for real means a new command case and an
/// arm in each `handleViewportCommand`, which is a feature rather than a repair.
@preconcurrency
@MainActor
public final class VideoPaneControls: ObservableObject {
    @Published public var mode: VideoContentMode = .fit
    @Published public var zoomed: Bool = false
    /// SWIPE-PEEL chip (doc 05 §8): the live swipe-nav feedback state ``SwipePeelOverlay`` renders
    /// (`nil` = hidden), already quantized by ``SwipePeelPlanner`` so a 120 Hz gesture stream
    /// re-renders the chip at most a few dozen times per gesture.
    ///
    /// Published by ``MetalLayerBackedView``'s peel driver off the same two-finger scroll it forwards
    /// to the host (see the file header).
    @Published public var swipePeel: SwipePeelChipState?
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
    // NO `onSystemKeyInjectorReady` HERE, AND THAT IS THE ONE DELIBERATE ASYMMETRY BETWEEN THE HALVES.
    // `MacVideoWindowView` takes it; this initializer does not, so the iOS shell cannot thread a sink
    // that would be swallowed. The reason is a platform floor, not an unfinished port: the sink's
    // middle argument is a raw `NSEvent.ModifierFlags` bit pattern and its only producer is
    // `SystemKeyCaptureController`'s `CGEventTap` — neither exists in the iOS SDK, which is why
    // `PaneImmersiveCapture.isSupported` is already `false` here
    // (`SlopDeskClientCore/Input/PaneImmersiveCapture.swift:58`) and the phone footer draws no
    // immersive chip. Accepting the parameter anyway would light `RemoteWindowModel.canInjectSystemKeys`
    // for a capture that can never run. The ratchet's Rule D names this as its one allowed exception and
    // carries the same reason; if iOS ever grows a system-wide key tap, delete the exception FIRST.
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
        self.onStreamStallChanged = onStreamStallChanged
        self.onSessionRejected = onSessionRejected
    }

    /// Owns the control bridge for this view's lifetime; the backing view wires its closures.
    @StateObject private var controls = VideoPaneControls()

    public var body: some View {
        // FILL THE PANE. Without this frame the bare representable claims no space → it shrinks to a small
        // island and clicks across the rest of the pane miss it. Mirrors the terminal seam. No control
        // overlay: the ACTUAL-SIZE viewport auto-anchors to the window top-left and edge-pan navigates.
        VideoLayerView(
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
            onStreamStallChanged: onStreamStallChanged,
            onSessionRejected: onSessionRejected,
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { SwipePeelOverlay(controls: controls) }
        .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

/// SWIPE-PEEL feedback chip (doc 05 §8) — a SwiftUI overlay, NEVER a `UIView` subview of the Metal
/// view (the rule at ``VideoPaneControls``: subviews + gesture recognizers on the layer-backed Metal
/// view perturb its geometry). Flat fills only — no material/blur over the `CAMetalLayer`.
///
/// Duplicated from the Mac's ``MacSwipePeelOverlay`` on purpose, and it is the ARRANGEMENT that is
/// duplicated: the placement rule is layout, so docs/56 §3 puts it on each half. The decision behind
/// it — when a peel starts, how far it has come, whether a release would commit — is
/// ``SwipePeelPlanner``, which is shared, Rust-backed, and exists exactly once.
struct SwipePeelOverlay: View {
    @ObservedObject var controls: VideoPaneControls

    var body: some View {
        // The edge alignment lives INSIDE the conditional content so the removal transition keeps the
        // chip on ITS edge — an outer `alignment:` recomputed from nil would yank a fading
        // forward-chip across to the leading edge.
        ZStack {
            if let peel = controls.swipePeel {
                SwipePeelChipView(state: peel)
                    .padding(.horizontal, 14)
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity,
                        alignment: peel.direction == .forward ? .trailing : .leading,
                    )
                    .transition(.opacity)
                    // Feedback only — never eats pane input: a touch at the pane edge during the
                    // ~520 ms confirm hold must reach the remote window.
                    .allowsHitTesting(false)
            }
        }
        .animation(.timingCurve(0, 0, 0.58, 1, duration: 0.15), value: controls.swipePeel)
    }
}

/// The swipe-peel progress chip: a chevron in a flat circle whose ring fills toward the commit
/// threshold and turns solid the instant a release would navigate — the ENTIRE visible feedback: the
/// streamed image itself never moves (v6 HW verdict — a remote pane is a window onto a desktop, so
/// translating it reads as dragging the pane, not peeling a page). To still live with the finger, the
/// chip EMERGES from its pane edge as progress grows: tucked ~12 pt at the arm line, fully out at
/// commit. White-on-any-video, flat fills only (no material — never glass over the `CAMetalLayer`).
struct SwipePeelChipView: View {
    let state: SwipePeelChipState
    /// Reduce Motion: the chip renders IN PLACE (no tuck emergence, no scale pulse) and changes by
    /// fades only. The ring fill, the committed solid state and the haptic stay — they are
    /// information, not motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Emergence: progress is quantized to 1/32 by the planner, so the outer `.animation` smooths
        // this into a glide instead of re-laying-out per gesture event.
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
        // Confirm pulse → DIM HOLD: the scale-up plays inside the ambient 0.15 s curve, then the chip
        // HOLDS at low opacity until the ~520 ms clear task removes it (the removal transition fades
        // the rest) — the hold is what actually spans the 150–400 ms inject→capture→stream beat, the
        // only fire acknowledgement there is. Fading to 0 here would end the visible pulse at ~150 ms
        // and hold an invisible chip.
        .opacity(state.confirming ? 0.35 : 1)
    }
}
#endif
