// SimulatorScreenView — the device's live frame on the PHONE, and the surface that turns a touch into
// a touch.
//
// THE MAC'S HALF LEFT IN docs/56 INCREMENT 52a, and it left DOWNWARD rather than sideways. What stood
// here was a plain `NSView` with no SwiftUI in it at all beyond the four-line representable that
// mounted it — the "kind 2" debt the split names: not a view decision, just a file in the wrong target.
// It is `SlopDeskDevicePanels/Simulator/SimulatorScreenSurface.swift` now, mounted directly by
// `MacSimulatorBezelView`, which DELETED an import edge instead of adding one (the class already
// imported that target for its envelopes and its geometry).
//
// The UIKit half stays, and stays a `UIViewRepresentable`, because the phone's panel IS SwiftUI — there
// is no second renderer under it to mount the view directly. That asymmetry is the whole shape of stage
// D and is not a loose end.
//
// The pixels land in an `AVSampleBufferDisplayLayer`: sample buffers go in, hardware decode and
// display come out, and there is no pixel-buffer lifetime, pacer or compositor to own. The desktop
// video path builds all of that on top of a `VTDecompressionSession` because it needs zoom, pan-lock,
// a cursor overlay and 1:1 snapping. This needs one rectangle at panel size, so the simpler API is
// not a shortcut — it is the whole feature.
//
// FRAMES DO NOT ARRIVE AS STATE. The view registers itself with the model's ``SimulatorFrameSink`` on
// mount and is fed directly from the socket; SwiftUI is not in the path. See that file for the
// measurement that forced it — 69.5 frames a second, each one invalidating the entire stage.
//
// INPUT MODEL. A press-drag-release becomes `touch1-down`/`move`/`up`, which is what makes a swipe,
// a drag and a long-press all work without special cases. A click with no movement is still sent as
// that triple rather than as `tap`, so the timing is the user's own — a deliberate hold on a list row
// opens its context menu exactly as it would on a device, where a synthesized 50 ms `tap` never
// could. It is also 3000× cheaper: measured 2026-08-04, `tap` occupies the server for 73 ms and a
// `touch1-*` for 0.03 ms.
//
// NOTHING IS SYNTHESIZED HERE. A finger on the mirror IS the finger, so the three machines the Mac
// needs to manufacture one out of a pointer — ``SimulatorScrollGesture``, the wheel's idle timer, the
// magnify-to-two-contacts translation — have no counterpart on this half and never did.
// EDGES: a contact that starts in iOS's own edge bands carries the `edge` hint, which is what makes
// swipe-up-for-home and pull-down-for-the-shades work from a drag rather than only from a button.
//
// Hang-safety: this file builds a display layer, which spins up a decompression session on first
// enqueue. Nothing here may be constructed in a unit test — the geometry it depends on lives in
// ``SimulatorScreenLayout``, the gesture machine in ``SimulatorScrollGesture`` and the sample
// construction in ``SimulatorVideoFormat``, all pure.

#if os(iOS)
import AVFoundation
import CoreMedia
import SlopDeskDevicePanels
import SwiftUI
import UIKit

/// The UIKit surface. Same display layer, same envelopes, a much shorter input half — see the header
/// note on why: a finger on the mirror IS the finger, so there is no gesture to SYNTHESIZE and none
/// of the three machines the Mac needs to synthesize one (the scroll gesture, the wheel's idle timer,
/// the magnify-to-two-contacts translation) exists here.
final class SimulatorScreenUIView: UIView, SimulatorFrameRenderer {
    /// Where a gesture goes. Set by the representable; nil until then, so an early touch is dropped
    /// rather than queued against a device that may not be the one finally selected.
    var send: ((SimulatorInputEnvelope) -> Void)?

    /// Which way the device is being held — the EDGE BANDS need it. The Mac also needs it for the
    /// scroll delta; there is no scroll delta here.
    var orientation: SimulatorOrientation = .portrait

    /// Reports the framebuffer size upward the moment the decoder works it out — see the AppKit half
    /// for why this is the only place in the app that knows it.
    var onContentSize: ((CGSize) -> Void)?

    private(set) var contentSize: CGSize = .zero {
        didSet {
            guard contentSize != oldValue, contentSize != .zero else { return }
            onContentSize?(contentSize)
        }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    /// The JPEG seed, shown until the first access unit decodes. Under the video layer, dropped the
    /// moment real pixels exist.
    private let seedLayer = CALayer()

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        isMultipleTouchEnabled = true
        layer.addSublayer(seedLayer)
        layer.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        seedLayer.contentsGravity = .resizeAspect
        // No implicit animations: a frame arriving mid-animation would cross-fade with the previous
        // one, which on a 60 Hz mirror reads as motion blur.
        displayLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        seedLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitted = fitted
        displayLayer.frame = fitted
        seedLayer.frame = fitted
    }

    var fitted: CGRect {
        SimulatorScreenLayout.fittedRect(content: contentSize, in: bounds.size)
    }

    // MARK: Frames

    func apply(configuration: SimulatorWireProtocol.AVCConfiguration) {
        guard let description = SimulatorVideoFormat.formatDescription(for: configuration) else { return }
        formatDescription = description
        contentSize = SimulatorVideoFormat.dimensions(of: description)
        setNeedsLayout()
    }

    func enqueue(accessUnit: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }
        if renderer.status == .failed { renderer.flush() }
        guard let sample = SimulatorVideoFormat.sampleBuffer(
            accessUnit: accessUnit, formatDescription: formatDescription, isKeyframe: isKeyframe,
        ) else { return }
        renderer.enqueue(sample)
        if seedLayer.contents != nil { seedLayer.contents = nil }
    }

    func showSeed(_ jpeg: Data) {
        guard renderer.status != .rendering,
              let cgImage = UIImage(data: jpeg)?.cgImage else { return }
        if contentSize == .zero {
            contentSize = CGSize(width: cgImage.width, height: cgImage.height)
            setNeedsLayout()
        }
        seedLayer.contents = cgImage
    }

    func reset() {
        renderer.flush(removingDisplayedImage: true) {}
        seedLayer.contents = nil
        formatDescription = nil
        contentSize = .zero
        setNeedsLayout()
    }

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    private var formatDescription: CMVideoFormatDescription?

    // MARK: Touch

    /// The edge the ONE-finger gesture started in, carried on every event of that gesture — iOS
    /// decides whether a drag is a scroll or a system gesture from where the finger LANDED.
    private var trackingEdge: String?
    /// True while a two-finger contact is live. Once a second finger lands the gesture stays a
    /// `touch2` to its end: the device is mid-pinch, and dropping back to one contact because a
    /// finger lifted a frame early reads as a fling.
    private var isPinching = false
    private var pinchSentAt: TimeInterval = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Taking key focus on the press is what makes a hardware keyboard type into the device that
        // was last touched, rather than into whatever pane had focus before. NOT while the soft
        // keyboard is up: tapping a text field on the mirrored device is exactly when a phone user
        // needs the keyboard to stay, and stealing first responder here would drop it on the tap
        // that opened the field.
        if !softKeys.isFirstResponder, !isFirstResponder { becomeFirstResponder() }
        let live = live(event) ?? touches
        if live.count >= 2 {
            isPinching = true
            pinchSentAt = 0
            sendPinch(.down, live)
            return
        }
        guard !isPinching, let touch = live.first,
              let point = devicePoint(touch) else { return }
        trackingEdge = SimulatorScreenLayout.edge(
            at: point, fitted: fitted, orientation: orientation,
        )
        send?(.touch(.down, x: point.x, y: point.y, edge: trackingEdge, in: surface))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let live = live(event) ?? touches
        if isPinching {
            let now = ProcessInfo.processInfo.systemUptime
            // ⚠️ The floor is ONE measurement about the SERVER (`touch2-move` occupies it for 25 ms, a
            // thousand times what a `touch1-move` costs), so both screen surfaces read it from the same
            // place — the phone's real second finger and the Mac's synthesized one alike.
            guard now - pinchSentAt >= SimulatorPresentation.pinchInterval else { return }
            pinchSentAt = now
            sendPinch(.move, live)
            return
        }
        guard let touch = live.first else { return }
        // Clamped rather than dropped: a drag that leaves the frame is still a drag, and the device
        // needs the intermediate points to read it as a swipe rather than a jump.
        let point = clampedDevicePoint(touch)
        send?(.touch(.move, x: point.x, y: point.y, edge: trackingEdge, in: surface))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event)
    }

    /// A cancelled touch is lifted, not forgotten. The system takes touches away for its own gestures
    /// (a screen-edge swipe, a call arriving); leaving the contact down would strand a finger on the
    /// device until the next press.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event)
    }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let remaining = live(event)?.subtracting(touches) ?? []
        guard remaining.isEmpty else { return }
        if isPinching {
            sendPinch(.up, touches)
            isPinching = false
            return
        }
        guard let touch = touches.first else { return }
        let point = clampedDevicePoint(touch)
        send?(.touch(.up, x: point.x, y: point.y, edge: trackingEdge, in: surface))
        trackingEdge = nil
    }

    /// The touches this view currently owns, or nil when there is no event to ask (a synthesized call).
    private func live(_ event: UIEvent?) -> Set<UITouch>? {
        event?.touches(for: self)
    }

    /// The view is going away — a device switch, or the panel closing. The contacts are forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone.
    func abandonGestures() {
        isPinching = false
        trackingEdge = nil
    }

    /// Both contacts of a two-finger gesture, ordered so a jitter cannot swap which finger is which
    /// between two envelopes. A gesture that lost a finger reuses the one it has for both, which
    /// keeps the pair well-formed until the `up`.
    private func sendPinch(_ phase: SimulatorInputEnvelope.TouchPhase, _ touches: Set<UITouch>) {
        let points: [CGPoint] = touches.map { clampedDevicePoint($0) }
            .sorted { (lhs: CGPoint, rhs: CGPoint) in lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x }
        guard let first = points.first else { return }
        let second: CGPoint = points.count > 1 ? points[1] : first
        send?(.touch2(
            phase, x1: first.x, y1: first.y, x2: second.x, y2: second.y, in: surface,
        ))
    }

    // MARK: Geometry

    private var surface: SimulatorInputEnvelope.Surface {
        SimulatorScreenLayout.surface(fitted: fitted)
    }

    private func devicePoint(_ touch: UITouch) -> CGPoint? {
        SimulatorScreenLayout.devicePoint(from: touch.location(in: self), fitted: fitted)
    }

    private func clampedDevicePoint(_ touch: UITouch) -> CGPoint {
        SimulatorScreenLayout.clampedDevicePoint(from: touch.location(in: self), fitted: fitted)
    }

    // MARK: Keyboard

    /// A hardware keyboard on iPad types into the device. The mirror takes first responder on the
    /// first touch, so typing follows the last thing tapped — the same rule the Mac's
    /// `acceptsFirstResponder` gives it.
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let send, let resolved = presses.compactMap(\.key).first else {
            super.pressesBegan(presses, with: event)
            return
        }
        guard let code = SimulatorKeyMap.code(hidUsage: UInt16(resolved.keyCode.rawValue)) else {
            // No mapping: fall back to the characters, which covers the whole printable range without
            // this file owning a layout table. A dead key, a modifier alone, or a ⌘-chord (which the
            // mirror cannot forward — the device's layout is not knowable from here) is not this
            // view's, so it is FORWARDED rather than dropped: the mirror takes first responder on
            // touch, so a swallowed ⌘T meant every workspace chord died the moment anyone tapped the
            // picture. Up the chain it reaches ``PhoneRootKeyResponder``, which owns those chords.
            let text = resolved.charactersIgnoringModifiers
            guard !text.isEmpty, !resolved.modifierFlags.contains(.command) else {
                super.pressesBegan(presses, with: event)
                return
            }
            send(.type(text))
            return
        }
        send(.key(code, modifiers: SimulatorKeyMap.modifiers(for: resolved)))
    }

    // MARK: The soft keyboard

    /// The zero-sized child the on-screen keyboard belongs to — see ``DeviceSoftKeyboard``.
    private lazy var softKeys: DeviceSoftKeyInput = {
        let keys = DeviceSoftKeyInput(frame: .zero)
        keys.onText = { [weak self] text in self?.send?(.type(text)) }
        keys.onDeleteBackward = { [weak self] in
            // Spelled as the HID usage a real Backspace reports, resolved by the SAME door the
            // hardware path uses — this view names a KEY, never the server's code for one.
            guard let code = SimulatorKeyMap.code(hidUsage: DeviceSoftKeyboard.softDeleteUsage)
            else { return }
            self?.send?(.key(code, modifiers: []))
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

extension SimulatorScreenUIView: DeviceSoftKeyboardHost {}

/// The device's frame as a SwiftUI view. It carries no frame data: the view attaches itself to the
/// model's sink and is fed from the socket directly.
struct SimulatorScreenView: UIViewRepresentable {
    var frames: SimulatorFrameSink
    var orientation: SimulatorOrientation
    var send: (SimulatorInputEnvelope) -> Void
    /// Optional so the bezel and the bare fallback can both mount this view while only the stage
    /// that owns the header cares what size the device turned out to be.
    var onContentSize: ((CGSize) -> Void)?

    func makeUIView(context _: Context) -> SimulatorScreenUIView {
        let view = SimulatorScreenUIView(frame: .zero)
        view.send = send
        view.orientation = orientation
        view.onContentSize = onContentSize
        frames.attach(view)
        return view
    }

    func updateUIView(_ view: SimulatorScreenUIView, context _: Context) {
        view.send = send
        view.orientation = orientation
        view.onContentSize = onContentSize
    }

    static func dismantleUIView(_ view: SimulatorScreenUIView, coordinator _: ()) {
        view.abandonGestures()
        view.send = nil
        view.onContentSize = nil
    }
}
#endif
