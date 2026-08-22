// AndroidScreenView — the device's live frame ON THE PHONE, and the surface that turns a finger into
// a touch.
//
// THE MAC'S HALF LEFT THIS FILE in docs/56 stage D increment 52b, and it did not become an AppKit
// rewrite: `AndroidScreenNSView` was already a plain `NSView`, so it MOVED, verbatim, down to
// `SlopDeskDevicePanels/Android/AndroidScreenNSView.swift` — the ledger's kind 2, a view-framework
// class sitting in a view TARGET because the thing above it happened to be a `View`. What went with it
// is the `NSViewRepresentable` that used to mount it: the Mac's panel is AppKit now and mounts the
// `NSView` directly, so the wrapper had nothing left to wrap.
//
// What is left here is the phone's, whole. The pixels land in an `AVSampleBufferDisplayLayer`: sample
// buffers go in, hardware decode and display come out, and there is no pixel-buffer lifetime, pacer or
// compositor to own. Same choice as the simulator panel and for the same reason — this needs one
// rectangle at panel size, so the simpler API is not a shortcut, it is the whole feature.
//
// FRAMES DO NOT ARRIVE AS STATE. The view registers itself with the model's ``AndroidFrameSink`` on
// mount and is fed from the socket directly; SwiftUI is not in the path.
//
// THE PHONE'S INPUT HALF IS SHORTER, not a port of the Mac's. A finger on the mirror IS the finger, so
// the three machines the Mac needs to SYNTHESIZE one — the scroll gesture, the classic wheel's idle
// timer, and the magnify-gesture-to-two-contacts translation — have nothing to do here and are absent
// rather than reimplemented. What survives is everything that is about the DEVICE rather than about
// the pointer: the clamped drag, the pinch's rate limit, and the pointer-index discipline.
//
// NO EDGE HINTS, and none are needed. `docs/47` records the simulator panel classifying a contact into
// iOS's home-indicator and shade bands and sending an `edge` hint, because `baguette` interprets
// gestures server-side. `scrcpy` injects a real `MotionEvent` into the input pipeline, so Android's own
// `SystemGestureExclusion` and `WindowInsets` logic classifies it exactly as it would a finger on the
// glass — the client neither can nor should pre-empt that.
//
// Hang-safety: this file builds a display layer, which spins up a decompression session on first
// enqueue. Nothing here may be constructed in a unit test — the geometry lives in
// ``AndroidScreenLayout``, the sample construction in ``AndroidVideoFormat`` and the byte layouts in
// ``AndroidControlMessage``, all pure.

#if os(iOS)
import AVFoundation
import CoreMedia
import SlopDeskDevicePanels
import SwiftUI
import UIKit

/// The UIKit surface. Same display layer and the same control messages as the Mac's `NSView`, with a
/// much shorter input half: a finger on the mirror IS the finger. The pinch is two real contacts,
/// which is also why it keeps the pointer-index discipline below rather than dropping it.
final class AndroidScreenUIView: UIView, AndroidFrameRenderer {
    /// Where a control message goes. Nil until the representable sets it, so an early touch is
    /// dropped rather than queued against a device that may not be the one finally selected.
    var send: ((Data) -> Void)?

    /// Drawing geometry, from the decoder's reading of the bitstream. See ``AndroidScreenNSView`` for
    /// why it is kept apart from ``videoSize``.
    private(set) var contentSize: CGSize = .zero

    /// The size the SERVER says it is encoding, and the only size a positional message may be paired
    /// with — the device drops any other.
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            setNeedsLayout()
        }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        isMultipleTouchEnabled = true
        layer.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        // No implicit animations: a frame arriving mid-animation would cross-fade with the previous
        // one, which on a 60 Hz mirror reads as motion blur.
        displayLayer.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = fitted
    }

    var fitted: CGRect {
        AndroidScreenLayout.fittedRect(content: contentSize, in: bounds.size)
    }

    private var surface: AndroidScreenLayout.Surface {
        AndroidScreenLayout.Surface(
            fitted: fitted, video: videoSize == .zero ? contentSize : videoSize,
        )
    }

    // MARK: Frames

    func apply(parameterSets: [Data], codec: AndroidVideoCodec) {
        guard let description = AndroidVideoFormat.formatDescription(
            parameterSets: parameterSets, codec: codec,
        ) else { return }
        formatDescription = description
        contentSize = AndroidVideoFormat.dimensions(of: description)
        // A rotation arrives as new parameter sets describing the swapped axes, and the frames encoded
        // against the OLD ones are still in the renderer's queue.
        renderer.flush()
        setNeedsLayout()
    }

    func enqueue(accessUnit: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }
        if renderer.status == .failed {
            renderer.flush()
            send?(AndroidControlMessage.simple(.resetVideo))
        }
        guard let sample = AndroidVideoFormat.sampleBuffer(
            accessUnit: accessUnit, formatDescription: formatDescription, isKeyframe: isKeyframe,
        ) else { return }
        renderer.enqueue(sample)
    }

    func reset() {
        renderer.flush(removingDisplayedImage: true) {}
        formatDescription = nil
        contentSize = .zero
        setNeedsLayout()
    }

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    private var formatDescription: CMVideoFormatDescription?

    // MARK: Touch

    /// True while a two-finger contact is live. Once a second finger lands the gesture stays a pinch
    /// to its end — dropping back to one contact because a finger lifted a frame early reads to
    /// `ScaleGestureDetector` as a fling.
    private var isPinching = false
    private var pinchSentAt: TimeInterval = 0
    /// One pair per frame. Not a server cost (measured 5 µs a message) — Android's own: a two-pointer
    /// batch arriving faster than the display refreshes gives `ScaleGestureDetector` sub-pixel spans
    /// to difference, and the zoom quantises.
    private static let pinchInterval: TimeInterval = 0.016

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Taking key focus on the press is what makes a hardware keyboard type into the device that
        // was last touched, rather than into whatever pane had focus before. NOT while the soft
        // keyboard is up: tapping a text field on the mirrored device is exactly when a phone user
        // needs the keyboard to stay, and stealing first responder here would drop it on the tap
        // that opened the field.
        if !softKeys.isFirstResponder, !isFirstResponder { becomeFirstResponder() }
        let live = event?.touches(for: self) ?? touches
        if live.count >= 2 {
            isPinching = true
            pinchSentAt = 0
            sendPinch(.down, live)
            return
        }
        guard !isPinching, let touch = live.first,
              let point = devicePoint(touch) else { return }
        sendTouch(.down, at: point, buttons: .primary)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let live = event?.touches(for: self) ?? touches
        if isPinching {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - pinchSentAt >= Self.pinchInterval else { return }
            pinchSentAt = now
            sendPinch(.move, live)
            return
        }
        guard let touch = live.first else { return }
        // Clamped rather than dropped: a drag that leaves the frame is still a drag, and the device
        // needs the intermediate points to read it as a swipe rather than a jump.
        sendTouch(.move, at: clampedDevicePoint(touch), buttons: .primary)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event)
    }

    /// A cancelled touch is lifted, not forgotten. The system takes touches away for its own gestures;
    /// leaving the contact down would strand a finger on the device until the next press.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event)
    }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let remaining = event?.touches(for: self)?.subtracting(touches) ?? []
        guard remaining.isEmpty else { return }
        if isPinching {
            sendPinch(.up, touches)
            isPinching = false
            return
        }
        guard let touch = touches.first else { return }
        sendTouch(.up, at: clampedDevicePoint(touch), buttons: [])
    }

    /// The view is going away — a device switch, or the panel closing. The contacts are forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone.
    func abandonGestures() {
        isPinching = false
    }

    private func sendTouch(
        _ action: AndroidMotionAction, at point: CGPoint, buttons: AndroidButtons,
    ) {
        let surface = surface
        guard surface.isUsable else { return }
        let pixel = surface.pixels(point)
        send?(AndroidControlMessage.touch(
            action: action,
            x: AndroidScreenLayout.clampToInt32(pixel.x),
            y: AndroidScreenLayout.clampToInt32(pixel.y),
            width: surface.width, height: surface.height,
            buttons: buttons,
        ))
    }

    /// Both contacts of a pinch, as the pointer-index actions Android expects — the SECOND pointer
    /// takes `POINTER_DOWN`/`POINTER_UP` while the first takes plain `DOWN`/`UP`, which is how
    /// `MotionEvent` says "another finger joined an existing gesture". Ordered so a jitter cannot swap
    /// which finger is which between two batches.
    private func sendPinch(_ action: AndroidMotionAction, _ touches: Set<UITouch>) {
        guard let send else { return }
        let surface = surface
        guard surface.isUsable else { return }
        let points: [CGPoint] = touches.map { clampedDevicePoint($0) }
            .sorted { (lhs: CGPoint, rhs: CGPoint) in lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x }
        guard let first = points.first else { return }
        let second: CGPoint = points.count > 1 ? points[1] : first
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
                secondAction, at: second, id: AndroidControlMessage.virtualFingerPointerID,
                surface: surface, buttons: buttons,
            ))
            send(pinchMessage(
                action, at: first, id: AndroidControlMessage.fingerPointerID,
                surface: surface, buttons: buttons,
            ))
        } else {
            send(pinchMessage(
                action, at: first, id: AndroidControlMessage.fingerPointerID,
                surface: surface, buttons: buttons,
            ))
            send(pinchMessage(
                secondAction, at: second, id: AndroidControlMessage.virtualFingerPointerID,
                surface: surface, buttons: buttons,
            ))
        }
    }

    private func pinchMessage(
        _ action: AndroidMotionAction, at point: CGPoint, id: UInt64,
        surface: AndroidScreenLayout.Surface, buttons: AndroidButtons,
    ) -> Data {
        let pixel = surface.pixels(point)
        return AndroidControlMessage.touch(
            action: action, pointerID: id,
            x: AndroidScreenLayout.clampToInt32(pixel.x),
            y: AndroidScreenLayout.clampToInt32(pixel.y),
            width: surface.width, height: surface.height, buttons: buttons,
        )
    }

    // MARK: Geometry

    private func devicePoint(_ touch: UITouch) -> CGPoint? {
        AndroidScreenLayout.devicePoint(from: touch.location(in: self), fitted: fitted)
    }

    private func clampedDevicePoint(_ touch: UITouch) -> CGPoint {
        AndroidScreenLayout.clampedDevicePoint(from: touch.location(in: self), fitted: fitted)
    }

    // MARK: Keyboard

    /// A hardware keyboard on iPad types into the device — the same rule the Mac's
    /// `acceptsFirstResponder` gives it.
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let send, let key = presses.compactMap(\.key).first else {
            super.pressesBegan(presses, with: event)
            return
        }
        switch AndroidKeyMap.resolve(key) {
        case let .text(string):
            if let message = AndroidControlMessage.text(string) { send(message) }
        case let .keycode(keycode, metaState):
            for message in AndroidControlMessage.keyPress(keycode, metaState: metaState) {
                send(message)
            }
        case .none:
            // `.none` means "a bare modifier, or a chord the client KEEPS FOR ITSELF" — and keeping
            // it meant dropping it. `resolve_android` returns it for every ⌘/⌃ chord (the panel
            // cannot know the device's layout, so an ambiguous chord is never forwarded), so with a
            // `break` here every workspace chord died the moment the mirror took key focus: a touch
            // on the picture makes this view first responder, and from then on ⌘T, ⌘⇧P and ⌘1–9 hit a
            // `break`. Forwarded instead, so the press walks the chain to the root rung that owns
            // those chords (``PhoneRootKeyResponder``) — which is what "the client keeps it" was
            // always supposed to mean.
            super.pressesBegan(presses, with: event)
        }
    }

    // MARK: The soft keyboard

    /// The zero-sized child the on-screen keyboard belongs to — see ``DeviceSoftKeyboard``.
    private lazy var softKeys: DeviceSoftKeyInput = {
        let keys = DeviceSoftKeyInput(frame: .zero)
        keys.onText = { [weak self] text in
            guard let message = AndroidControlMessage.text(text) else { return }
            self?.send?(message)
        }
        keys.onDeleteBackward = { [weak self] in
            // The HID usage a real Backspace reports, put through the SAME resolve door the hardware
            // path uses — this view names a KEY, never Android's keycode for one.
            guard case let .keycode(keycode, meta) = AndroidKeyMap.resolve(
                hidUsage: DeviceSoftKeyboard.softDeleteUsage,
                characters: nil, charactersIgnoringModifiers: nil, modifiers: [],
            ) else { return }
            for message in AndroidControlMessage.keyPress(keycode, metaState: meta) {
                self?.send?(message)
            }
        }
        keys.onResign = { DeviceSoftKeyboard.shared.report(isTyping: false) }
        addSubview(keys)
        return keys
    }()

    func setSoftKeyboard(_ armed: Bool) {
        if armed {
            softKeys.becomeFirstResponder()
        } else {
            _ = softKeys.resignFirstResponder()
            becomeFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            DeviceSoftKeyboard.shared.unregister(self)
        } else {
            DeviceSoftKeyboard.shared.register(self)
        }
    }
}

extension AndroidScreenUIView: DeviceSoftKeyboardHost {}

/// The device's frame as a SwiftUI view. It carries no frame data: the view attaches itself to the
/// model's sink and is fed from the socket directly.
struct AndroidScreenView: UIViewRepresentable {
    var frames: AndroidFrameSink
    var send: (Data) -> Void
    /// The session packet's size. `nil` before the stream has named one — every touch is then
    /// measured against the decoder's reading of the bitstream instead (``AndroidScreenUIView/surface``).
    var videoSize: CGSize?

    func makeUIView(context _: Context) -> AndroidScreenUIView {
        let view = AndroidScreenUIView(frame: .zero)
        view.send = send
        view.videoSize = videoSize ?? .zero
        frames.attach(view)
        return view
    }

    func updateUIView(_ view: AndroidScreenUIView, context _: Context) {
        view.send = send
        view.videoSize = videoSize ?? .zero
    }

    static func dismantleUIView(_ view: AndroidScreenUIView, coordinator _: ()) {
        view.abandonGestures()
        view.send = nil
    }
}
#endif
