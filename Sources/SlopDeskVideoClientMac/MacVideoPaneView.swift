// MacVideoPaneView — the SwiftUI entry point of the Mac's remote-GUI pane, and the control bridge
// + swipe-peel chip that ride with it (docs/56 §3, the video carve).
//
// THIS FILE IS ONE HALF OF A DELIBERATE DUPLICATION. Its phone twin is
// `SlopDeskVideoClientPhone/VideoPaneView.swift`, and the two are not meant to converge: the
// user's standing directive is two separate implementations, and docs/56 §3 draws the line this
// obeys — LAYOUT diverges, CAPABILITY does not. What is duplicated here is arrangement (a closure
// list, an ObservableObject's fields, a chip's geometry). What is NOT duplicated, and must never be,
// is a RULE: `SwipePeelPlanner`, `ViewportZoom`, `ViewportPan`, `PinchZeroPolicy` and every other
// decision live once in `SlopDeskVideoClient`, most of them already in Rust behind the FFI.
//
// The seam contract — which sinks this half accepts — is ratcheted against the phone's in
// `rust/slopdesk-invariants`, so a sink wired here and forgotten there fails `make lint` rather
// than shipping as a feature that works on one platform.

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
public final class MacVideoPaneControls: ObservableObject {
    @Published public var mode: VideoContentMode = .fit
    @Published public var zoomed: Bool = false
    /// SWIPE-PEEL chip (doc 05 §8): the live swipe-nav feedback state the SwiftUI overlay
    /// renders (`nil` = hidden). Published by the macOS backing view's ``SwipePeelPlanner``
    /// mirror, already quantized so the 120 Hz gesture stream re-renders the chip at most a
    /// few dozen times per gesture. Never set on iOS (no trackpad scroll phases).
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
public struct MacVideoWindowView: View {
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
    @StateObject private var controls = MacVideoPaneControls()

    public var body: some View {
        // FILL THE PANE. Without this frame the bare representable claims no space → it shrinks to a small
        // island and clicks across the rest of the pane miss it. Mirrors the terminal seam. No control
        // overlay: the ACTUAL-SIZE viewport auto-anchors to the window top-left and edge-pan navigates.
        MacVideoLayerView(
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
        .overlay { MacSwipePeelOverlay(controls: controls) }
        .accessibilityLabel(Text("Remote GUI window: \(title)"))
    }
}

/// SWIPE-PEEL feedback chip (doc 05 §8) — a SwiftUI overlay, NEVER an NSView subview of the Metal view
/// (the rule at ``MacVideoPaneControls``: subviews + gesture recognizers on the layer-backed Metal view
/// perturbed its geometry and swallowed the `mouseUp` of a trackpad three-finger-drag → a stuck remote
/// button). Flat fills only — no material/blur over the `CAMetalLayer`.
///
/// Its own view because the pane has TWO mounts now: ``MacVideoWindowView`` (SwiftUI, and iOS's only shape)
/// and ``MacVideoSurfaceHost`` (AppKit, over a hit-transparent hosting view). The chip's placement rule is
/// small enough to be tempting to re-type on the second mount, and re-typing it is how the two panes stop
/// agreeing about which EDGE a forward peel lives on.
struct MacSwipePeelOverlay: View {
    @ObservedObject var controls: MacVideoPaneControls

    var body: some View {
        // The edge alignment lives INSIDE the conditional content so the removal transition keeps the chip
        // on ITS edge — an outer `alignment:` recomputed from nil would yank a fading forward-chip across
        // to the leading edge.
        ZStack {
            if let peel = controls.swipePeel {
                MacSwipePeelChipView(state: peel)
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
struct MacSwipePeelChipView: View {
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
