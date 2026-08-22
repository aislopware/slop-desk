// MetalLayerBackedView — the phone's whole input + viewport half for a remote desktop: a
// `UIView` whose `layerClass` IS `CAMetalLayer` (docs/56 §3, the video carve).
//
// THE VIEWPORT MODEL IS THE PHONE'S, NOT SHARED. Unlike the Mac's oversized-sublayer viewport there
// is no overflow to clip — the pane IS the viewport and the stream `.fit`s into it — so zoom/pan go
// straight to `pipeline.setZoom`, which moves the renderer AND the session's input inverse together.
// That is also why the zoom ladder floors at 1× here and at 0.25 on the Mac; `ViewportZoom`'s doc
// comment in `SlopDeskVideoClient` records the distinction so it is not "fixed" into one ladder.
//
// TOUCH IS TRANSLATED HERE, NOT MIRRORED. A remote desktop has no touch to receive, only a pointer,
// so this is the one surface in the tree that must SYNTHESIZE one — and the vocabulary it
// synthesizes is `TouchPointerPlan`'s (Rust, behind the FFI), not this file's.
//
// A POINTER IS NOT A FINGER, AND BOTH LAND HERE. `TARGETED_DEVICE_FAMILY` is "1,2", so an iPad with
// a trackpad or a mouse drives this same view — and everything the touch translation is FOR is wrong
// for it. A pointer has real buttons (so the press is diffed from `UIEvent.buttonMask`, never
// synthesized from a tap), it hovers with nothing held (so `UIHoverGestureRecognizer` forwards the
// move that hover-only remote UI needs), it scrolls without touching (so a `UIPanGestureRecognizer`
// with `allowedScrollTypesMask` carries the wheel), and it is PRECISE — so the tap slop and the
// long-press-to-right-click, both of which exist because a contact patch is tens of points across and
// a phone has no second button, are skipped for it. See `Indirect pointer` below; the pure half is
// `IndirectPointerPlan`.
//
// ── TWO THINGS THE NEXT PERSON WILL NEED, recorded here because this is where they land ─────────
//
// 1. CURSOR SHAPE ON iPad IS THE ONE PIECE STILL MISSING, and the reason is UIKit's, not this file's.
//    macOS runs the Parsec model — the host's shape drawn ON the local OS cursor at the instant
//    position, no overlay — because `NSCursor(image:hotSpot:)` takes an arbitrary bitmap.
//    `UIPointerStyle` does not: its shapes are a `UIBezierPath` or a system effect, and no host cursor
//    bitmap becomes either. So this half keeps the POSITION overlay the pipeline already composites
//    for a touch device (`VideoWindowPipeline`, the `#if !os(macOS)` sublayer add) and hides the local
//    pointer over it, which is `applyLocalCursor`'s decision inverted: pixel-exact shape, RTT-lagged
//    position, instead of instant position and no shape. The way back to BOTH is to place that same
//    overlay at the LOCAL hover point rather than the host-reported one — the compositor already has
//    the shape cached and the placement math is pure — and it wants a host-space conversion the input
//    encoder currently owns, which is why it is a separate increment and not a `TODO` here.
//
// 2. MODIFIER RESYNC ON REFOCUS IS CLOSED, and the note stays because the shape is worth keeping.
//    The Mac re-establishes a still-held modifier when a pane REGAINS focus; this half only released
//    on blur, so an iPad with a hardware keyboard refocusing a pane with ⇧ or ⌘ physically down left
//    the host unaware and the next chord started a key short. The blocker was believed to be that
//    UIKit has no `NSEvent.modifierFlags` global read. It is not: `GCKeyboard.coalesced` answers
//    without waiting for a keystroke, and it answers per KEY rather than per flag, which is why
//    `hardwareModifiers()` below reads eight codes and folds them into the four the wire carries.
//    What is NOT rewritten here is which keycodes a held mask implies — that is
//    `LocalInputPolicy.heldModifierKeyCodes`, shared, already unit-tested, and the reason both halves
//    are now identically imperfect (a physical RIGHT-⇧ resyncs as the left code) rather than
//    divergent. Caps Lock stays out of it on both halves: it is a toggle, and re-forwarding it on
//    every focus change would flip the remote's once per focus change.
#if os(iOS)
import CSlopDeskFFI
import GameController
import QuartzCore
import SlopDeskVideoClient
import SlopDeskVideoProtocol
import UIKit

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
/// Deliberately NO `UIGestureRecognizer`s FOR TOUCH, which is a change from the local-only zoom/pan
/// this surface used to have: recognizers arbitrate against each other and against the SwiftUI canvas
/// above, and a recognizer that "fails" 300 ms after the finger lands is 300 ms of a click the user
/// already made. Raw `touchesBegan`/`Moved`/`Ended`/`Cancelled`, exactly like the two sibling surfaces.
///
/// The two recognizers that ARE installed are the exception that proves it: hover and trackpad scroll
/// have no `UIView` callback at all — `UIHoverGestureRecognizer` and a pan with `allowedScrollTypesMask`
/// are the only way UIKit delivers either — and neither can steal a touch, because a hover has no
/// contact and the scroll pan is capped at zero of them.
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
        installPointerSupport()
    }

    /// HOVER + TRACKPAD SCROLL + the local pointer's own visibility. All three are pure iPad
    /// affordances that fall away to nothing on a touch-only device: a phone never hovers, its pan
    /// recogniser never sees a scroll event, and its pointer interaction is never asked for a style.
    private func installPointerSupport() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        hover.delegate = self
        addGestureRecognizer(hover)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        // SCROLL EVENTS ONLY. A `maximumNumberOfTouches` of zero is UIKit's own idiom for "recognise
        // the wheel, never a finger pan" — without it this recogniser would arbitrate against the raw
        // touch handling above and swallow the two-contact gestures the whole surface is built on.
        scroll.maximumNumberOfTouches = 0
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = self
        addGestureRecognizer(scroll)
        scrollRecognizer = scroll

        pointerInteraction = UIPointerInteraction(delegate: self)
        if let pointerInteraction { addInteraction(pointerInteraction) }
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
                resyncModifiersFromHardwareKeyboard()
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
    //    macOS sibling's; see `VideoLayerView.makeUIView` for which side of `activate` each goes on.
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

    // ── SWIPE-PEEL feedback (doc 05 §8). The chip renderer has been on this half since the video
    //    carve; what was missing was the DRIVER, and the reason it was missing was a stale one — the
    //    planner arms on scroll PHASES, and the note said a touch produces none. A two-finger pair
    //    routed to `.scroll` produces exactly them: `applyPairScroll` already sends Began on the
    //    first move and `endPair` the Ended on lift, because the host needs a native gesture rather
    //    than a train of wheel ticks. The mirror reads the SAME tuple.
    //
    //    ONE THING IS GENUINELY ABSENT AND IT IS NOT A GAP: momentum. UIKit hands a raw touch
    //    surface no coast events, and this half refuses to invent a fling the finger never threw
    //    (`endPair`'s own rule), so the recogniser's coast-expiry path is unreachable here — a
    //    gesture ends at the lift and the lift is what fires. The Mac's coasting arm is dead code on
    //    this half rather than a behaviour to reimplement.
    private var peelPlanner = SwipePeelPlanner()
    /// The host's swipe-nav operating point (cursor-socket type=3 push). `nil` until the first push
    /// — an old host never shows the chip, so the affordance cannot lie.
    private var peelStatus: SwipeNavStatusMessage?
    /// The verdict → chip state machine, shared with the Mac (``SwipePeelChipDriver``).
    private var peelDriver = SwipePeelChipDriver()
    /// Delayed clear of the confirm-pulse chip after a fire.
    private var peelConfirmClear: Task<Void, Never>?
    /// The "release now navigates" tick. Held rather than minted per tap so the generator is warm
    /// when the edge arrives — a cold `UIFeedbackGenerator` costs its first tap.
    private let peelHaptic = UISelectionFeedbackGenerator()

    // ── INDIRECT POINTER (iPad trackpad / mouse). Inert on a touch-only device: nothing below is
    //    reached without a `UITouch` of type `.indirectPointer`, a hover, or a scroll event.
    /// Held only because ``endScrollPan(cancelled:)`` has to ask whether a scroll is mid-flight — the
    /// hover recogniser needs no such question and is therefore not kept.
    private var scrollRecognizer: UIPanGestureRecognizer?
    private var pointerInteraction: UIPointerInteraction?
    /// Which host buttons this view has forwarded as DOWN and not released — the caller's half of
    /// ``IndirectPointerPlan/buttonTransitions(held:mask:)``, which keeps no state of its own. Left
    /// non-zero across a teardown is a button stranded on a process-global host event source, so
    /// every path that ends a gesture drains it.
    private var pointerButtonsHeld: UInt8 = 0
    /// The last point an indirect pointer was seen at, so a button press that arrives without a move
    /// (a click without a preceding hover, or a second button mid-drag) lands where the pointer is
    /// rather than where the last FINGER was.
    private var pointerHoverPoint: CGPoint?
    /// The scroll pan's translation at the previous event. UIKit accumulates translation over the
    /// gesture and the host wants per-event deltas, exactly as the touch centroid path does.
    private var scrollTranslation: CGPoint = .zero

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
        // SWIPE-PEEL: the host's operating point + history push. Without it the mirror never arms,
        // which is the correct behaviour against a host too old to send one.
        pipeline.onSwipeNavStatusChanged = { [weak self] status in self?.adoptSwipeNavStatus(status) }
        // HOST CURSOR VISIBILITY: the LOCAL pointer's decision, re-asked on every flip so the iPadOS
        // pointer reappears the instant the overlay stops being one (a `.fit` letterbox margin, or a
        // host that hid its own cursor) rather than waiting for the next hover.
        pipeline.onServerCursorVisibilityChanged = { [weak self] _ in self?.applyLocalPointerVisibility() }
        if connection != nil, let controls {
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
        abandonSwipePeel() // never strand a mid-gesture chip across a teardown
        peelStatus = nil
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
        for button in MouseButton.allCases {
            pipeline.mouseUp(button, centre, 1, [])
        }
        // The blanket release above already sent every up; forgetting the held set here is what stops
        // the NEXT press from being swallowed as "already down".
        pointerButtonsHeld = 0
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
        // A POINTER'S PRESS IS NOT A TAP. It arrives as a `UITouch` like a finger does, but its
        // buttons are on the EVENT, and everything the finger path does next — the tap slop, the
        // long-press-to-right-click, the two-contact latch — exists because a finger is imprecise and
        // has one button. A pointer has neither problem.
        if let pointer = live.first(where: { $0.type == .indirectPointer }) {
            updatePointerButtons(at: clampedPoint(pointer), event: event)
            return
        }
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
        if let pointer = live.first(where: { $0.type == .indirectPointer }) {
            // A pointer DRAG. The same call as the press: the mask carries any button pressed or
            // released mid-drag, and the diff swallows the ones that did not change.
            updatePointerButtons(at: clampedPoint(pointer), event: event)
            return
        }
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
        if let pointer = touches.first(where: { $0.type == .indirectPointer }) {
            // A CANCELLED pointer releases too, and does not care that it was cancelled: the finger
            // path swallows a cancelled tap because the user never clicked anything, but a pointer's
            // press was a real button that is now physically up. Leaving it down would strand it.
            let point = clampedPoint(pointer)
            if cancelled {
                releaseHeldPointerButtons(at: point, event: event)
            } else {
                updatePointerButtons(at: point, event: event)
            }
            return
        }
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
        // An indirect pointer's buttons are the same bargain as a finger's: released, never
        // forgotten, and at the last place the pointer was actually seen.
        releaseHeldPointerButtons(at: pointerHoverPoint ?? pointerLatest, event: nil)
        endScrollPan(cancelled: true)
        // A LIFT-ALL is a teardown, never a commit: the gesture is being taken away rather than
        // finished, so the mirror is cancelled instead of fed an ended phase.
        abandonSwipePeel()
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

    // MARK: Indirect pointer (an iPad trackpad or a mouse)

    /// Forward one indirect-pointer event: the move, then whichever buttons the mask says changed.
    ///
    /// ONE call site serves press, drag and release, which is the whole reason the diff is pure and
    /// stateless — UIKit reports the LEVEL on every event, so an edge has to be derived, and deriving
    /// it in three places is three chances to strand a button on a host whose event source is
    /// process-global.
    ///
    /// The move goes FIRST and unconditionally. A press that arrives without one lands wherever the
    /// host pointer was left by the last gesture, and hover-only remote UI (a tooltip, a menu
    /// highlight, a hover-revealed close box) needs the move at all.
    private func updatePointerButtons(at point: CGPoint, event: UIEvent?) {
        pointerHoverPoint = point
        guard inputEnabled else { return }
        let host = hostPoint(point)
        let change = IndirectPointerPlan.buttonTransitions(
            held: pointerButtonsHeld, mask: event?.buttonMask.rawValue ?? 0,
        )
        pointerButtonsHeld = change.held
        // A DRAG is a move with something held, and the pipeline has a distinct verb for it so the
        // host posts the matching `*MouseDragged` statelessly rather than guessing which button is
        // down. `mouseDrag` takes ONE button, so a two-button drag drags on the primary — which is
        // also what AppKit reports, since its drag callbacks are per-button and the Mac forwards the
        // one whose callback fired.
        if change.pressed == 0, change.released == 0,
           let dragging = IndirectPointerPlan.buttons(in: change.held).first
        {
            pipeline.mouseDrag(dragging, host, 1, mods(event))
            return
        }
        pipeline.mouseMove(host)
        // RELEASES BEFORE PRESSES. A swap in one event (the user rolled from one button to the other
        // between two reports) must not leave the old button down behind the new one's press.
        for button in IndirectPointerPlan.buttons(in: change.released) {
            pipeline.mouseUp(button, host, 1, mods(event))
        }
        for button in IndirectPointerPlan.buttons(in: change.pressed) {
            pipeline.mouseDown(button, host, 1, mods(event))
        }
    }

    /// Release every button this view still has down, without consulting a mask — the teardown path,
    /// where there is no event to read one from and the answer is "all of them" regardless.
    private func releaseHeldPointerButtons(at point: CGPoint, event: UIEvent?) {
        guard pointerButtonsHeld != 0 else { return }
        let held = pointerButtonsHeld
        pointerButtonsHeld = 0
        guard inputEnabled else { return }
        let host = hostPoint(point)
        for button in IndirectPointerPlan.buttons(in: held) {
            pipeline.mouseUp(button, host, 1, mods(event))
        }
    }

    /// HOVER: a pointer moving with nothing held. There is no `UIView` callback for it — a hover
    /// produces no `UITouch` at all — so the recogniser is the only route, and without it every piece
    /// of hover-only remote UI is unreachable from this half.
    @objc
    private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began,
             .changed:
            let point = clampedPoint(recognizer.location(in: self))
            pointerHoverPoint = point
            guard inputEnabled else { return }
            pipeline.mouseMove(hostPoint(point))
        case .ended,
             .cancelled,
             .failed:
            pointerHoverPoint = nil
        default:
            return
        }
    }

    /// TRACKPAD / WHEEL SCROLL. A pan recogniser capped at zero touches recognises scroll events and
    /// nothing else, so this cannot arbitrate against the two-contact touch gestures below.
    ///
    /// The deltas are the recogniser's per-event travel, the same shape the touch centroid path
    /// sends, and they feed the swipe-peel mirror for the same reason it does: on an iPad a
    /// two-finger trackpad swipe is exactly the gesture the host's own recogniser fires on, so a
    /// trackpad that navigated with no chip would be the bug this half just fixed, back on the other
    /// input modality.
    @objc
    private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        let state = IndirectPointerPlan.scrollPhase(gestureState: recognizer.state.rawValue)
        switch recognizer.state {
        case .began:
            scrollTranslation = .zero
        case .changed,
             .ended,
             .cancelled,
             .failed:
            break
        default:
            return
        }
        guard inputEnabled else {
            // The host's own recogniser stops seeing this gesture too, so a chip left up would
            // promise a fire that cannot happen.
            abandonSwipePeel()
            scrollTranslation = .zero
            return
        }
        let translation = recognizer.translation(in: self)
        let dx = Double(translation.x - scrollTranslation.x)
        let dy = Double(translation.y - scrollTranslation.y)
        scrollTranslation = translation
        let at = clampedPoint(pointerHoverPoint ?? recognizer.location(in: self))
        // NO MOMENTUM PHASE, for the touch half's reason with a different cause: iPadOS delivers a
        // trackpad's inertial tail as more `.changed` events inside the same gesture rather than as a
        // separately-phased coast, so there is no edge to report — and inventing one would tell the
        // host a fling ended that never started.
        pipeline.scroll(
            dx: dx, dy: dy, viewPoint: hostPoint(at),
            scrollPhase: state, momentumPhase: 0, continuous: true,
        )
        feedSwipePeel(dx: dx, dy: dy, scrollPhase: state)
        // Reset only where the gesture actually ENDED. Doing it on `.began` too would re-zero the
        // baseline the began delta just established, and the next `.changed` would count it twice.
        if recognizer.state != .began, recognizer.state != .changed { scrollTranslation = .zero }
    }

    /// Close an in-flight trackpad scroll on a teardown. The host is told the gesture ENDED rather
    /// than cancelled, because it has one replay for a finished gesture and none for an abandoned
    /// one — the same call ``IndirectPointerPlan/scrollPhase(gestureState:)`` makes.
    private func endScrollPan(cancelled: Bool) {
        guard let scrollRecognizer, scrollRecognizer.state == .began || scrollRecognizer.state == .changed
        else { return }
        if inputEnabled {
            pipeline.scroll(
                dx: 0, dy: 0, viewPoint: hostPoint(clampedPoint(pointerHoverPoint ?? .zero)),
                scrollPhase: IndirectPointerPlan.scrollPhase(gestureState: UIGestureRecognizer.State.ended.rawValue),
                momentumPhase: 0, continuous: true,
            )
        }
        scrollTranslation = .zero
        if cancelled { scrollRecognizer.isEnabled = false
            scrollRecognizer.isEnabled = true
        }
    }

    /// The LOCAL cursor decision, and the mirror image of the Mac's ``applyLocalCursor``.
    ///
    /// macOS hides the host's POSITION overlay and paints its SHAPE onto the local OS cursor;
    /// `UIPointerStyle` takes no bitmap, so this half does the opposite — it keeps the overlay the
    /// pipeline already composites and hides the LOCAL pointer over it, so the two never both show.
    /// The gate is the same one, `isServerCursorVisible`: in a `.fit` letterbox margin, or when the
    /// host has hidden its own cursor, there is no overlay to be the pointer and the iPadOS one must
    /// come back rather than leaving the user with nothing to aim.
    private func applyLocalPointerVisibility() {
        pointerInteraction?.invalidate()
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: Swift.min(Swift.max(point.x, 0), Swift.max(bounds.width, 0)),
            y: Swift.min(Swift.max(point.y, 0), Swift.max(bounds.height, 0)),
        )
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
        // Warm the peel tick now rather than at the commit edge: a cold generator costs its first tap,
        // and the one tap this surface makes is the one that has to land on the exact frame.
        peelHaptic.prepare()
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
            let scrollPhase = TouchPointerPlan.scrollPhase(isFirst: false, isLast: true)
            pipeline.scroll(
                dx: 0, dy: 0, viewPoint: hostPoint(pairLatestCentroid),
                scrollPhase: scrollPhase, momentumPhase: 0, continuous: true,
            )
            // THE LIFT IS WHAT FIRES. The mirror decides on the ended phase exactly as the host's own
            // recogniser does off the same event, so this feed is not bookkeeping — skip it and the
            // chip would fill to solid and then simply vanish, having promised a navigation it never
            // acknowledged.
            feedSwipePeel(dx: 0, dy: 0, scrollPhase: scrollPhase)
        } else {
            abandonSwipePeel()
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
        guard inputEnabled else {
            // A pair that can no longer reach the remote abandons any candidate — the host's own
            // recogniser stops seeing this gesture too, so a chip left up would promise a fire that
            // cannot happen.
            abandonSwipePeel()
            return
        }
        let isFirst = !pairScrollStarted
        pairScrollStarted = true
        let dx = Double(centroid.x - pairLatestCentroid.x)
        let dy = Double(centroid.y - pairLatestCentroid.y)
        let scrollPhase = TouchPointerPlan.scrollPhase(isFirst: isFirst, isLast: false)
        pipeline.scroll(
            dx: dx, dy: dy, viewPoint: hostPoint(centroid),
            scrollPhase: scrollPhase, momentumPhase: 0, continuous: true,
        )
        feedSwipePeel(dx: dx, dy: dy, scrollPhase: scrollPhase)
    }

    // MARK: Swipe-peel feedback (doc 05 §8)

    /// Adopts the host's swipe-nav status push, on the Mac's rules — eligibility flipping OFF
    /// mid-gesture retracts immediately, a shown chip's direction going history-DEAD retracts unless
    /// it is CONFIRMING (a fired back-nav flips `canGoBack` itself within one poll, and cutting the
    /// hold on that push would erase the acknowledgement of the fire that caused it), and a knob
    /// change rebuilds the idle mirror so a host-side retune never desynchronises the feedback.
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
            peelDriver = SwipePeelChipDriver()
        }
    }

    /// Mirrors one forwarded scroll event into the peel planner and applies its verdict. Gated on
    /// the host saying the target app is eligible AT ALL — no push yet (old host) ⇒ nothing — then
    /// per-direction on the pushed history state.
    ///
    /// `now` is `CACurrentMediaTime()` rather than the touch's own timestamp: the recogniser's clock
    /// only has to be MONOTONIC and shared across the events of one gesture, and this surface feeds
    /// it from `touchesMoved` batches that are already coalesced by UIKit — so the media clock at
    /// send time is the same instant the pipeline stamped, without threading a `UITouch` down here.
    private func feedSwipePeel(dx: Double, dy: Double, scrollPhase: UInt8) {
        guard let status = peelStatus, status.eligible else { return }
        let verdict = peelPlanner.ingest(
            dx: dx, dy: dy, scrollPhase: scrollPhase, momentumPhase: 0,
            continuous: true, now: CACurrentMediaTime(),
        )
        applySwipePeel(SwipePeelPlanner.historyGated(verdict, status: status))
    }

    /// Actuates one driver step. Every EDGE below it is ``SwipePeelChipDriver``'s and shared with
    /// the Mac; what is left here is UIKit's three verbs.
    private func applySwipePeel(_ verdict: SwipePeelPlanner.Verdict) {
        switch peelDriver.step(verdict, showing: controls?.swipePeel) {
        case .none:
            return
        case let .show(chip, haptic):
            peelConfirmClear?.cancel()
            peelConfirmClear = nil
            if haptic {
                // The moment the chip turns solid: "release now navigates". A SELECTION tick rather
                // than an impact — the Mac taps `.alignment`, whose whole character is "a thing
                // snapped into place", and an impact would read as the navigation itself landing.
                peelHaptic.selectionChanged()
            }
            controls?.swipePeel = chip
        case let .confirm(chip, hold):
            controls?.swipePeel = chip
            peelConfirmClear?.cancel()
            peelConfirmClear = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.controls?.swipePeel = nil
            }
        case .clear:
            controls?.swipePeel = nil
        }
    }

    /// Abandons any in-flight peel candidate (route change, eligibility off, teardown): the planner
    /// resets and, if the chip was showing, it fades out.
    private func abandonSwipePeel() {
        applySwipePeel(peelPlanner.cancel())
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
        clampedPoint(touch.location(in: self))
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

    /// The modifiers a hardware keyboard is PHYSICALLY holding right now, or `[]` when none is
    /// attached. UIKit has no `NSEvent.modifierFlags` — a `UIKeyModifierFlags` arrives only attached to
    /// a press event, and a refocus is not one — so the answer comes from GameController, which reports
    /// per KEY. Left and right fold into one flag because that is what the wire carries.
    ///
    /// Caps Lock is deliberately absent, matching ``LocalInputPolicy/heldModifierKeyCodes(_:)``: it is a
    /// toggle rather than a held modifier, and re-forwarding it would flip the remote's Caps once per
    /// focus change. `fn` likewise has no `GCKeyCode`, which costs nothing — ``modifiers(_:)`` cannot
    /// produce `.function` from `UIKeyModifierFlags` either.
    private static func hardwareModifiers() -> InputModifiers {
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return [] }
        func held(_ codes: GCKeyCode...) -> Bool {
            codes.contains { keys.button(forKeyCode: $0)?.isPressed == true }
        }
        var modifiers: InputModifiers = []
        if held(.leftShift, .rightShift) { modifiers.insert(.shift) }
        if held(.leftControl, .rightControl) { modifiers.insert(.control) }
        if held(.leftAlt, .rightAlt) { modifiers.insert(.option) }
        if held(.leftGUI, .rightGUI) { modifiers.insert(.command) }
        return modifiers
    }

    /// MODIFIER RESYNC — the Mac's ``MacMetalLayerBackedView`` rule, off a hardware-keyboard poll
    /// instead of a global flags read. On regaining focus, re-establish any modifier still physically
    /// held: its down `pressesBegan` went to the PREVIOUSLY focused responder, so without this the host
    /// does not know the modifier is down and the next chord starts a key short.
    ///
    /// The sends are idempotent end to end — the host suppresses a modifier-down for a code it already
    /// holds, naming this case in as many words — so a resync against a still-latched host flag costs a
    /// datagram and changes nothing. The local latch is checked anyway, because it is cheaper.
    private func resyncModifiersFromHardwareKeyboard() {
        guard isActive, inputEnabled else { return }
        let modifiers = Self.hardwareModifiers()
        for keyCode in LocalInputPolicy.heldModifierKeyCodes(modifiers) where !modifierLatch.isDown(keyCode) {
            modifierLatch.note(keyCode: keyCode, down: true)
            pipeline.key(keyCode: keyCode, down: true, modifiers: modifiers)
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

// MARK: - The two recognizers coexist with the raw touch handling

extension MetalLayerBackedView: UIGestureRecognizerDelegate {
    /// Both installed recognizers run ALONGSIDE everything else rather than arbitrating against it.
    ///
    /// Neither can take a contact away — a hover has none and the scroll pan is capped at zero of
    /// them — so the only thing exclusivity could achieve here is cancelling the SwiftUI gestures the
    /// canvas above puts on the pane, which is the failure this surface avoided by using raw touches
    /// in the first place.
    func gestureRecognizer(
        _: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool {
        true
    }
}

// MARK: - The local pointer, over a pane that is already drawing one

extension MetalLayerBackedView: UIPointerInteractionDelegate {
    /// HIDE THE LOCAL POINTER while the host's own is on screen, so the pane never shows two.
    ///
    /// This is ``applyLocalPointerVisibility``'s decision spelled in UIKit's vocabulary, and it is
    /// the Mac's `applyLocalCursor` with the halves swapped — there, the OS cursor takes the host's
    /// SHAPE and the position overlay is never added; here, `UIPointerStyle` takes no bitmap, so the
    /// overlay stays and the OS pointer goes. Same gate on both: a read-only or unfocused pane, a
    /// letterbox margin, or a host that hid its cursor all fall through to the system pointer,
    /// because in each of those there is nothing on screen for the user to aim with.
    func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
        guard inputEnabled, pipeline.isServerCursorVisible else { return nil }
        return .hidden()
    }
}
#endif
