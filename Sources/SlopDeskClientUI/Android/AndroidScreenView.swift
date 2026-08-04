// AndroidScreenView — the device's live frame, and the surface that turns a click into a touch.
//
// The pixels land in an `AVSampleBufferDisplayLayer`: sample buffers go in, hardware decode and
// display come out, and there is no pixel-buffer lifetime, pacer or compositor to own. Same choice as
// the simulator panel and for the same reason — this needs one rectangle at panel size, so the
// simpler API is not a shortcut, it is the whole feature.
//
// FRAMES DO NOT ARRIVE AS STATE. The view registers itself with the model's ``AndroidFrameSink`` on
// mount and is fed from the socket directly; SwiftUI is not in the path.
//
// INPUT MODEL. A press-drag-release becomes down/move/up as a FINGER (`SC_POINTER_ID_GENERIC_FINGER`),
// not a mouse. Android's gesture recognisers, its scrollers and its fling physics are all built for
// touch, and a mouse pointer id makes a drag arrive as a hover in views that distinguish them. A
// click with no movement is still sent as that triple, so a deliberate hold on a list row opens its
// context menu with the user's own timing.
//
// NO EDGE HINTS, and none are needed. `docs/47` records the simulator panel classifying a contact
// into iOS's home-indicator and shade bands and sending an `edge` hint, because `baguette` interprets
// gestures server-side. `scrcpy` injects a real `MotionEvent` into the input pipeline, so Android's
// own `SystemGestureExclusion` and `WindowInsets` logic classifies it exactly as it would a finger on
// the glass — the client neither can nor should pre-empt that. What the panel does instead is keep
// its synthetic contacts out of those bands (``AndroidScrollGesture/edgeMargin``) so a scroll is never
// mistaken for a Back.
//
// Hang-safety: this file builds a display layer, which spins up a decompression session on first
// enqueue. Nothing here may be constructed in a unit test — the geometry lives in
// ``AndroidScreenLayout``, the gesture machine in ``AndroidScrollGesture``, the sample construction in
// ``AndroidVideoFormat`` and the byte layouts in ``AndroidControlMessage``, all pure.

#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

/// The AppKit surface. A plain `NSView` hosting the display layer, plus the mouse/scroll/key
/// handling — SwiftUI gesture recognizers cannot express "report every intermediate point of a drag
/// at the rate they arrive", which is precisely what a touch sequence is.
final class AndroidScreenNSView: NSView, AndroidFrameRenderer {
    /// Where a control message goes. Nil until the representable sets it, so an early click is
    /// dropped rather than queued against a device that may not be the one finally selected.
    var send: ((Data) -> Void)?

    /// Reports the framebuffer size upward the moment the decoder works it out. The header prints it,
    /// and this is the only place in the app that knows: the size is in the SPS, and the layer has
    /// already parsed it to build a format description.
    var onContentSize: ((CGSize) -> Void)?

    /// The stream's pixel size, learned from the format description. `.zero` until the first
    /// parameter sets arrive, which is what makes the fitted rect empty and every click a miss —
    /// correct, since there is nothing on screen to click yet.
    private(set) var contentSize: CGSize = .zero {
        didSet {
            guard contentSize != oldValue, contentSize != .zero else { return }
            onContentSize?(contentSize)
        }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        // No implicit animations: a frame arriving mid-animation would cross-fade with the previous
        // one, which on a 60 Hz mirror reads as motion blur.
        displayLayer.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Flipped so the view's y grows downward — the same direction as Android's own screen
    /// coordinates, which removes a per-event flip from the input path and the chance of forgetting
    /// it in one branch.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        displayLayer.frame = fitted
    }

    var fitted: CGRect {
        AndroidScreenLayout.fittedRect(content: contentSize, in: bounds.size)
    }

    // MARK: Frames

    func apply(parameterSets: [Data], codec: AndroidVideoCodec) {
        guard let description = AndroidVideoFormat.formatDescription(
            parameterSets: parameterSets, codec: codec,
        ) else { return }
        formatDescription = description
        contentSize = AndroidVideoFormat.dimensions(of: description)
        // A rotation arrives as new parameter sets describing the swapped axes, and the frames encoded
        // against the OLD ones are still in the renderer's queue. Flushing here is what keeps the
        // first moments after a turn from decoding a portrait frame into a landscape description.
        renderer.flush()
        needsLayout = true
    }

    func enqueue(accessUnit: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }
        // A failed decode leaves the renderer in `.failed` forever; flushing and waiting for the next
        // keyframe is the documented recovery, and `RESET_VIDEO` asks the device for one.
        if renderer.status == .failed {
            renderer.flush()
            send?(AndroidControlMessage.simple(AndroidControlMessage.resetVideo))
        }
        guard let sample = AndroidVideoFormat.sampleBuffer(
            accessUnit: accessUnit, formatDescription: formatDescription, isKeyframe: isKeyframe,
        ) else { return }
        renderer.enqueue(sample)
    }

    /// Drop everything on the floor — a device switch, or a disconnect. Without the flush the next
    /// device's first frames decode against the previous device's parameter sets.
    func reset() {
        renderer.flush(removingDisplayedImage: true) {}
        formatDescription = nil
        contentSize = .zero
        needsLayout = true
    }

    /// The layer's renderer — every enqueue, flush and status read goes through it. The identically
    /// named methods on `AVSampleBufferDisplayLayer` are the deprecated spelling of these, and mixing
    /// the two on one layer is the documented way to get an inconsistent status.
    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    private var formatDescription: CMVideoFormatDescription?

    // MARK: Pointer

    /// Set on mouse-down when the press landed on the frame, cleared on mouse-up. Its presence is
    /// what makes a drag that wanders off the frame keep reporting: releasing outside must still
    /// deliver an `up`, or the device is left with a finger permanently down.
    private var isTracking = false

    override func mouseDown(with event: NSEvent) {
        guard let point = devicePoint(for: event) else { return }
        endScroll()
        isTracking = true
        sendTouch(.down, at: point, buttons: .primary)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        // Clamped rather than dropped: a drag that leaves the frame is still a drag, and the device
        // needs the intermediate points to interpret it as a swipe rather than a jump.
        sendTouch(.move, at: clampedDevicePoint(for: event), buttons: .primary)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        sendTouch(.up, at: clampedDevicePoint(for: event), buttons: [])
    }

    /// A right-click is Back, which is what the button does everywhere else in this project's mental
    /// model of a device: it is the gesture the user reaches for to leave a screen. Sent as
    /// `BACK_OR_SCREEN_ON`, so on a sleeping device the same click wakes it instead.
    override func rightMouseDown(with event: NSEvent) {
        guard devicePoint(for: event) != nil, let send else { return }
        for message in AndroidControlMessage.pressBack() { send(message) }
    }

    private func sendTouch(
        _ action: AndroidMotionAction, at point: CGPoint, buttons: AndroidButtons,
    ) {
        let surface = AndroidScreenLayout.surface(fitted: fitted)
        guard surface.width > 0, surface.height > 0 else { return }
        send?(AndroidControlMessage.touch(
            action: action,
            x: AndroidScreenLayout.clampToInt32(point.x),
            y: AndroidScreenLayout.clampToInt32(point.y),
            width: surface.width, height: surface.height,
            buttons: buttons,
        ))
    }

    // MARK: Scroll

    private var scroll = AndroidScrollGesture()
    /// Closes a CLASSIC WHEEL's gesture. A wheel has no phases, so nothing on the wire says the user
    /// stopped — the finger is lifted once the notches stop coming. A trackpad never uses this: its
    /// own `.ended` is exact, and waiting out an idle window after it would hold a contact down for a
    /// tenth of a second after the fingers left.
    private var wheelIdle: Timer?
    private static let wheelIdleInterval: TimeInterval = 0.12

    override func scrollWheel(with event: NSEvent) {
        // MOMENTUM IS THE DEVICE'S JOB. macOS keeps delivering deltas after the fingers lift, and
        // replaying them as finger movement would scroll twice: once from our synthetic travel and
        // again from the fling Android computes from the touch history at lift. Dropping them is what
        // makes the device's own inertia the only inertia.
        guard event.momentumPhase.isEmpty else { return }

        let phase: AndroidScrollGesture.Phase
        switch event.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended,
             .cancelled: phase = .ended
        case []: phase = .wheel
        default: return // `.mayBegin` and anything later — not a delta worth acting on.
        }

        guard let origin = devicePoint(for: event) ?? scroll.finger else { return }
        for message in scroll.accept(
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: phase, pointer: origin, fitted: fitted,
        ) { send?(message) }

        wheelIdle?.invalidate()
        wheelIdle = nil
        guard phase == .wheel else { return }
        wheelIdle = Timer.scheduledTimer(
            withTimeInterval: Self.wheelIdleInterval, repeats: false,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endScroll() }
        }
    }

    /// Lift whatever the scroll left down. Called by the wheel's idle timer, and by a mouse press — a
    /// click while a synthetic finger is still on the screen would be two contacts at once.
    private func endScroll() {
        wheelIdle?.invalidate()
        wheelIdle = nil
        for message in scroll.lift(in: fitted) { send?(message) }
    }

    /// The view is going away — a device switch, or the panel closing. The contact is forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone.
    func abandonGestures() {
        wheelIdle?.invalidate()
        wheelIdle = nil
        scroll.abandon()
        pinchCentre = nil
        isTracking = false
    }

    // MARK: Pinch

    /// The trackpad's own magnify gesture, as the two contacts a device understands.
    ///
    /// Rate-limited, but for a different reason than the simulator's: there is no expensive server
    /// verb here (measured 5 µs a message), the limit is Android's own. A two-pointer `MotionEvent`
    /// batch arriving faster than the display refreshes gives `ScaleGestureDetector` sub-pixel spans
    /// to difference, and the zoom quantises. One pair per frame is what a real hand produces.
    private var pinchCentre: CGPoint?
    private var pinchSpread: CGFloat = 0
    private var pinchSentAt: TimeInterval = 0
    /// The pair's starting separation, and the floor a full pinch closes to. Wide enough that a
    /// spread has somewhere to go, narrow enough to sit inside a phone's width.
    private static let pinchSpread: CGFloat = 160
    private static let pinchInterval: TimeInterval = 0.016

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            guard let centre = devicePoint(for: event) else { return }
            pinchCentre = centre
            pinchSpread = Self.pinchSpread
            pinchSentAt = 0
            sendPinch(.down)
        case .changed:
            guard pinchCentre != nil else { return }
            // Multiplicative: magnification is a fractional delta, so a pinch and the spread that
            // undoes it have to be the same factor in each direction.
            pinchSpread = min(max(pinchSpread * (1 + event.magnification), 24), 2000)
            let now = event.timestamp
            guard now - pinchSentAt >= Self.pinchInterval else { return }
            pinchSentAt = now
            sendPinch(.move)
        case .ended,
             .cancelled:
            guard pinchCentre != nil else { return }
            sendPinch(.up)
            pinchCentre = nil
        default:
            break
        }
    }

    /// Both contacts of a pinch, as the pointer-index actions Android expects.
    ///
    /// The SECOND pointer takes `POINTER_DOWN`/`POINTER_UP` while the first takes plain `DOWN`/`UP` —
    /// that is how `MotionEvent` says "another finger joined an existing gesture" rather than "a new
    /// gesture started", and getting it the other way round gives `ScaleGestureDetector` two
    /// unrelated single-finger drags.
    private func sendPinch(_ action: AndroidMotionAction) {
        guard let pinchCentre, let send else { return }
        let surface = AndroidScreenLayout.surface(fitted: fitted)
        guard surface.width > 0, surface.height > 0 else { return }
        let (first, second) = AndroidScreenLayout.pinchFingers(
            centre: pinchCentre, spread: pinchSpread, fitted: fitted,
        )
        let secondAction: AndroidMotionAction =
            switch action {
            case .down: .pointerDown
            case .up: .pointerUp
            default: action
            }
        let buttons: AndroidButtons = action == .up ? [] : .primary
        // Order matters on the way down and on the way up: the second finger arrives after the first
        // and leaves before it, exactly as a hand does.
        if action == .up {
            send(pinchMessage(
                secondAction,
                at: second,
                id: AndroidControlMessage.virtualFingerPointerID,
                surface: surface,
                buttons: buttons,
            ))
            send(pinchMessage(
                action,
                at: first,
                id: AndroidControlMessage.fingerPointerID,
                surface: surface,
                buttons: buttons,
            ))
        } else {
            send(pinchMessage(
                action,
                at: first,
                id: AndroidControlMessage.fingerPointerID,
                surface: surface,
                buttons: buttons,
            ))
            send(pinchMessage(
                secondAction,
                at: second,
                id: AndroidControlMessage.virtualFingerPointerID,
                surface: surface,
                buttons: buttons,
            ))
        }
    }

    private func pinchMessage(
        _ action: AndroidMotionAction, at point: CGPoint, id: UInt64,
        surface: (width: UInt16, height: UInt16), buttons: AndroidButtons,
    ) -> Data {
        AndroidControlMessage.touch(
            action: action, pointerID: id,
            x: AndroidScreenLayout.clampToInt32(point.x),
            y: AndroidScreenLayout.clampToInt32(point.y),
            width: surface.width, height: surface.height, buttons: buttons,
        )
    }

    // MARK: Geometry

    private func devicePoint(for event: NSEvent) -> CGPoint? {
        AndroidScreenLayout.devicePoint(
            from: convert(event.locationInWindow, from: nil), fitted: fitted,
        )
    }

    private func clampedDevicePoint(for event: NSEvent) -> CGPoint {
        AndroidScreenLayout.clampedDevicePoint(
            from: convert(event.locationInWindow, from: nil), fitted: fitted,
        )
    }

    // MARK: Keyboard

    /// Clicking the frame takes key focus, so typing goes to the device rather than to whatever pane
    /// was focused before.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let send else {
            super.keyDown(with: event)
            return
        }
        switch AndroidKeyMap.resolve(event) {
        case let .text(string):
            if let message = AndroidControlMessage.text(string) { send(message) }
        case let .keycode(keycode, metaState):
            for message in AndroidControlMessage.keyPress(keycode, metaState: metaState) {
                send(message)
            }
        case .none:
            break
        }
    }
}

/// The device's frame as a SwiftUI view. It carries no frame data: the view attaches itself to the
/// model's sink and is fed from the socket directly.
struct AndroidScreenView: NSViewRepresentable {
    var frames: AndroidFrameSink
    var send: (Data) -> Void
    /// Optional so a bare fallback can mount this view while only the stage that owns the header
    /// cares what size the device turned out to be.
    var onContentSize: ((CGSize) -> Void)?

    func makeNSView(context _: Context) -> AndroidScreenNSView {
        let view = AndroidScreenNSView(frame: .zero)
        view.send = send
        view.onContentSize = onContentSize
        frames.attach(view)
        return view
    }

    func updateNSView(_ view: AndroidScreenNSView, context _: Context) {
        view.send = send
        view.onContentSize = onContentSize
    }

    static func dismantleNSView(_ view: AndroidScreenNSView, coordinator _: ()) {
        view.abandonGestures()
        view.send = nil
        view.onContentSize = nil
    }
}
#endif
