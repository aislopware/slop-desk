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
// NO SWIPE-PEEL CHIP HERE, AND THAT IS A KNOWN BUG, NOT A LAYOUT CHOICE — see the note in
// `MetalLayerBackedView.activate`. When it is fixed, the chip's DRAWING is duplicated from the
// Mac's `MacSwipePeelChipView` (it is layout) and the planner is NOT (it is a rule, and is already
// shared and Rust-backed).
#if os(iOS)
import CSlopDeskFFI
import QuartzCore
import SlopDeskVideoClient
import SlopDeskVideoProtocol
import SwiftUI

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
#endif
