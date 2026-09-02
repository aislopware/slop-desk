// MacVideoPaneView — the AppKit spec bag for one remote-GUI pane, and the control bridge + swipe-peel
// chip that ride with it (docs/56 §3, the video carve).
//
// THIS FILE IS ONE HALF OF A DELIBERATE DUPLICATION. Its phone twin is
// `SlopDeskVideoClientPhone/VideoSurfaceHost.swift`, and the two are not meant to converge: the
// user's standing directive is two separate implementations, and docs/56 §3 draws the line this
// obeys — LAYOUT diverges, CAPABILITY does not. What is duplicated here is arrangement (a closure
// list, a controls object's fields, a chip's geometry). What is NOT duplicated, and must never be,
// is a RULE: `SwipePeelPlanner`, `ViewportZoom`, `ViewportPan`, `PinchZeroPolicy` and every other
// decision live once in `SlopDeskVideoClient`, most of them already in Rust behind the FFI.
//
// The seam contract — which sinks this half accepts — is ratcheted against the phone's in
// `rust/slopdesk-invariants`, so a sink wired here and forgotten there fails `just lint` rather
// than shipping as a feature that works on one platform.
//
// SwiftUI removal (this campaign): `MacVideoWindowView` — a SwiftUI `View` whose `body` built exactly
// one thing (``MacVideoLayerView`` filling the pane + the swipe-peel `.overlay`) — is gone.
// `MacVideoSurfaceHost.init` never read that `body`; it read `pane.connection`, `pane.title`,
// `pane.isActive` and the ~20 `on…Ready` callbacks off the value itself. ``MacVideoPaneSpec`` below is
// what is left once the `View` conformance is subtracted: the same stored properties, no `body`, no
// `@StateObject`. The swipe-peel chip (`MacSwipePeelOverlay`/`MacSwipePeelChipView`, SwiftUI `View`s
// hosted over the Metal surface through an `NSHostingView`) is gone too, replaced by the plain
// `NSView`s at the bottom of this file — their headers explain how the hit-test-transparency bugfix
// that used to live on the HOSTING view now lives on the content view instead, since there is only one
// view left to get it right on.

import AppKit
import QuartzCore
import SlopDeskVideoClient
import SlopDeskVideoProtocol

/// Bridges the AppKit chrome to the backing view's pipeline — the control bridge `MacVideoSurfaceHost`
/// owns for the pane's lifetime and the Metal view publishes into.
///
/// It used to be a SwiftUI `ObservableObject`. It is a plain class now because `ObservableObject` /
/// `@Published` exist to trigger a SwiftUI re-render, and this pane has had no SwiftUI observer to
/// trigger since the swipe-peel chip became an `NSView` (below) — `MacVideoSurfaceHost` is the only
/// mount left, and it is AppKit start to finish. `swipePeel` keeps a `didSet` push instead: the AppKit
/// spelling of the same "something downstream needs to react to this" fact, aimed at exactly the one
/// observer (``MacSwipePeelOverlayView``) that has one. `mode` and `zoomed` stay plain stored
/// properties — nothing outside this module ever read them even in the SwiftUI shape (grepped clean),
/// so there is no observer to wire a push to.
///
/// It used to advertise a "fit/fill toggle", and there was never anything on the other end: the
/// closure was declared on both halves, assigned on one, and INVOKED by nothing. Fit is reachable —
/// through the `ViewportCommand` byte, like every other footer verb — and fill is reachable from
/// neither platform. The dead closure is gone; adding fill for real means a new command case and an
/// arm in each `handleViewportCommand`, which is a feature rather than a repair.
@preconcurrency
@MainActor
public final class MacVideoPaneControls {
    public var mode: VideoContentMode = .fit
    public var zoomed: Bool = false
    /// SWIPE-PEEL chip (doc 05 §8): the live swipe-nav feedback state (`nil` = hidden). Set by the
    /// macOS backing view's ``SwipePeelPlanner`` mirror, already quantized so the 120 Hz gesture stream
    /// pushes at most a few dozen times per gesture. Never set on iOS (no trackpad scroll phases).
    public var swipePeel: SwipePeelChipState? {
        didSet {
            guard swipePeel != oldValue else { return }
            onSwipePeelChanged?(swipePeel)
        }
    }

    /// Fired on every ``swipePeel`` change — the AppKit twin of what a `@Published` property's
    /// projected publisher gave a SwiftUI `.overlay` for free. Wired by whichever view is currently
    /// showing the chip (``MacVideoSurfaceHost``, the only mount left); `nil` before that wiring runs
    /// and after teardown.
    public var onSwipePeelChanged: ((SwipePeelChipState?) -> Void)?
    var onResetZoom: () -> Void = {}
    public init() {}
}

/// A plain value describing one remote-GUI pane (doc 17 §3 PATH 2) — everything ``MacVideoSurfaceHost``
/// needs to build the `CAMetalLayer` + cursor overlay mount, and nothing else.
///
/// Each layout pass the mount computes `videoScale = layerSize / decodedFrameSize` and feeds
/// it to ``ClientCursorCompositor`` (via the session) so the composited cursor lands
/// on the right pixel.
///
/// ⚠️ **GUI-ONLY:** the properties below feed a live decode pipeline (Metal/VideoToolbox/sockets) once
/// handed to ``MacVideoSurfaceHost``. This type itself is inert data — building one commits to nothing
/// until it is passed to that initializer. `MacVideoSurfaceHost` is COMPILED + reviewed; not driven
/// from tests (instantiating the renderer / decoder / display link / sockets needs a real device +
/// screen + TCC). This is the wiring point `SlopDeskClientUI` injects via `VideoWindowFactory`.
public struct MacVideoPaneSpec {
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
    let onSessionRejected: ((VideoSessionRefusal) -> Void)?

    /// The existing seam signature (title-only): describes the Metal-backed view chrome
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

    /// Live remote-window spec: brings up the orchestrator against `connection`. `isActive` /
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
        onSessionRejected: ((VideoSessionRefusal) -> Void)? = nil,
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
}

/// SWIPE-PEEL feedback chip (doc 05 §8) — an `NSView`, NEVER a subview of the Metal view itself (the
/// rule at ``MacVideoPaneControls``: subviews + gesture recognizers on the layer-backed Metal view
/// perturbed its geometry and swallowed the `mouseUp` of a trackpad three-finger-drag → a stuck remote
/// button). Flat fills only — no material/blur over the `CAMetalLayer`.
///
/// It used to be `MacSwipePeelOverlay`, a SwiftUI `View` mounted through an `NSHostingView`
/// (`PeelOverlayHostingView`) — TWO objects, because SwiftUI content cannot itself answer AppKit's
/// `hitTest`, only its own `.allowsHitTesting`, which is invisible to the responder chain that actually
/// walks the hosting view. Now there is one object, and it answers `hitTest` itself: see below.
final class MacSwipePeelOverlayView: NSView {
    private let chip = MacSwipePeelChipView()
    /// Matches the SwiftUI chip's `.padding(.horizontal, 14)` from its aligned edge.
    private static let edgeInset: CGFloat = 14
    private static let chipSize: CGFloat = 36
    /// Matches the SwiftUI overlay's `.animation(.timingCurve(0, 0, 0.58, 1, duration: 0.15), value:)`
    /// — the one curve every property change (appear/disappear, scale, offset, opacity) rode.
    private static let transitionDuration: CFTimeInterval = 0.15
    private static let transitionCurve = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chip.alphaValue = 0
        addSubview(chip)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Feedback only — never eats pane input (the house convention for overlays atop the Metal
    /// surface): a click at the pane edge during the ~520 ms confirm hold must reach the remote
    /// window. Returning `nil` unconditionally — not delegating to `super`, which would test the chip
    /// subview and its bounds — is what makes that true regardless of where the chip currently sits.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// Applies a new swipe-peel state. `nil` hides the chip; a value shows/updates it. The chip's own
    /// fill/ring/glyph redraw immediately (cheap, and already rate-limited by the planner's 1/32
    /// progress quantization — see ``MacVideoPaneControls/swipePeel``); the SIZE/POSITION/OPACITY that
    /// used to ride SwiftUI's implicit `.animation` glide under one `NSAnimationContext` pass instead.
    func apply(_ state: SwipePeelChipState?) {
        // The edge alignment is resolved INSIDE this call, from the state's OWN direction, so a
        // fading-out chip keeps its last known edge — the SwiftUI overlay's comment on the same
        // problem: an outer alignment recomputed from `nil` would yank a fading forward-chip across to
        // the leading edge mid-transition.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        chip.state = state
        if let state, chip.alphaValue == 0 {
            // A chip about to fade IN is placed at its target frame with NO animation first, so the
            // first animated frame moves it FROM the right edge rather than gliding in from wherever
            // the previous gesture left it.
            chip.frame = frame(for: state, reduceMotion: reduceMotion)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.transitionDuration
            context.timingFunction = Self.transitionCurve
            chip.animator().alphaValue = alpha(for: state)
            if let state {
                chip.animator().frame = frame(for: state, reduceMotion: reduceMotion)
            }
        }
    }

    private func alpha(for state: SwipePeelChipState?) -> CGFloat {
        guard let state else { return 0 }
        // Confirm pulse → DIM HOLD: the scale-up plays inside the ambient curve above, then the chip
        // HOLDS at low opacity until the planner's ~520 ms clear task removes it — the hold is what
        // actually spans the 150–400 ms inject→capture→stream beat, the only fire acknowledgement
        // there is. Fading to 0 here would end the visible pulse early and hold an invisible chip.
        return state.confirming ? 0.35 : 1
    }

    private func frame(for state: SwipePeelChipState, reduceMotion: Bool) -> NSRect {
        let scale = reduceMotion ? 1 : (state.confirming ? 1.12 : (state.committed ? 1.06 : 1))
        let side = Self.chipSize * scale
        // Emergence: the chip TUCKS toward its pane edge as progress grows (tucked ~12 pt at the arm
        // line, flush at commit) — reduce-motion renders in place, no tuck.
        let tuck = reduceMotion ? 0 : (1 - state.progress) * 12
        let y = bounds.midY - side / 2
        let x: CGFloat =
            switch state.direction {
            case .back: Self.edgeInset - tuck
            case .forward: bounds.width - Self.edgeInset - side + tuck
            }
        return NSRect(x: x, y: y, width: side, height: side)
    }
}

/// The swipe-peel progress chip: a chevron in a flat circle whose ring fills toward the commit
/// threshold and turns solid the instant a release would navigate — the ENTIRE visible
/// feedback: the streamed image itself never moves (v6 HW verdict — a remote pane is a window
/// onto a desktop, so translating it reads as dragging the pane, not peeling a page). White-on-any-
/// video (the Chromium overscroll idiom users already know), flat fills only (no material — never
/// glass over the `CAMetalLayer`).
///
/// Drawn with Core Graphics rather than `CAShapeLayer` sublayers: a one-shot vector redraw per state
/// change is simpler to reason about than a `CAShapeLayer`'s animatable-property lifecycle, and
/// correctness here matters more than a glide between two of the planner's quantized progress steps —
/// the SAME quantization that already keeps a 120 Hz gesture stream from redrawing more than a few
/// dozen times per gesture (``MacVideoPaneControls/swipePeel``). The size/position/opacity animation
/// that SwiftUI's `.animation` used to give the whole chip for free is ``MacSwipePeelOverlayView``'s.
final class MacSwipePeelChipView: NSView {
    var state: SwipePeelChipState? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1) // AppKit shadow offset is bottom-up
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not supported") }

    /// Never eats input — belt-and-suspenders alongside ``MacSwipePeelOverlayView/hitTest(_:)``, which
    /// already returns `nil` unconditionally and so never reaches this view's own hit test at all. Kept
    /// so this view is provably transparent even if it is ever mounted somewhere else.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        guard let state else { return }

        // Background fill.
        NSColor.white.withAlphaComponent(state.committed ? 0.95 : 0.82).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        // Hairline border, inset by half its width so the 1 pt stroke lands fully inside the view.
        let border = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.black.withAlphaComponent(0.12).setStroke()
        border.stroke()

        // Progress ring, replaced by the solid fill above once committed.
        if !state.committed {
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = bounds.width / 2 - 1
            let ring = NSBezierPath()
            // Starts at 12 o'clock (90°) and sweeps clockwise on screen as progress grows — the
            // Core-Graphics spelling of the SwiftUI ring's `rotationEffect(-90°)` +
            // `trim(from: 0, to: progress)`, which fills clockwise from the top.
            ring.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - 360 * state.progress, clockwise: true,
            )
            ring.lineWidth = 2
            ring.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.75).setStroke()
            ring.stroke()
        }

        // Chevron glyph.
        let symbolName = state.direction == .back ? "chevron.left" : "chevron.right"
        let glyphAlpha = state.committed ? 0.9 : 0.45
        if let glyph = Self.tintedChevron(named: symbolName, alpha: glyphAlpha) {
            let origin = NSPoint(x: bounds.midX - glyph.size.width / 2, y: bounds.midY - glyph.size.height / 2)
            glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// Renders `named` at the chip's glyph weight/size, tinted to `alpha`-opacity black. `NSImage` has
    /// no direct "draw as this color" call for a template image the way SwiftUI's
    /// `.foregroundStyle(_:)` does; the standard AppKit recipe draws the glyph once and then fills the
    /// tint color with `.sourceAtop` so only the glyph's own alpha picks it up.
    private static func tintedChevron(named symbolName: String, alpha: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return nil }
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.black.withAlphaComponent(alpha).set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
