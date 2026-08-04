// SimulatorScreenView — the device's live frame, and the surface that turns a click into a tap.
//
// The pixels land in an `AVSampleBufferDisplayLayer`: sample buffers go in, hardware decode and
// display come out, and there is no pixel-buffer lifetime, pacer or compositor to own. The desktop
// video path builds all of that on top of a `VTDecompressionSession` because it needs zoom, pan-lock,
// a cursor overlay and 1:1 snapping. This needs one rectangle at panel size, so the simpler API is
// not a shortcut — it is the whole feature.
//
// INPUT MODEL. A press-drag-release becomes `touch1-down`/`move`/`up`, which is what makes a swipe,
// a drag and a long-press all work without special cases. A click with no movement is still sent as
// that triple rather than as `tap`, so the timing is the user's own — a deliberate hold on a list row
// opens its context menu exactly as it would on a device, where a synthesized 50 ms `tap` never
// could. `tap` stays for programmatic use.
//
// Scroll becomes a swipe rather than a touch sequence: a wheel has no contact to track, and the
// discrete gesture is what the host interpolates smoothly.
//
// Hang-safety: this file builds a display layer, which spins up a decompression session on first
// enqueue. Nothing here may be constructed in a unit test — the geometry it depends on lives in
// ``SimulatorScreenLayout`` and the sample construction in ``SimulatorVideoFormat``, both pure.

#if os(macOS)
import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

/// The AppKit surface. A plain `NSView` hosting the display layer, plus the mouse/scroll handling —
/// SwiftUI gesture recognizers cannot express "report every intermediate point of a drag at the rate
/// they arrive", which is precisely what a touch sequence is.
final class SimulatorScreenNSView: NSView {
    /// Where a gesture goes. Set by the representable; nil until then, so an early click is dropped
    /// rather than queued against a device that may not be the one finally selected.
    var send: ((SimulatorInputEnvelope) -> Void)?

    /// Reports the framebuffer size upward the moment the decoder works it out. The header prints
    /// it, and this is the only place in the app that knows: the size is in the SPS, and the layer
    /// has already parsed it to build a format description. Reaching for it any other way means
    /// parsing that record a second time to learn something that is already sitting here.
    var onContentSize: ((CGSize) -> Void)?

    /// The stream's pixel size, learned from the format description. `.zero` until the first
    /// configuration message, which is what makes the fitted rect empty and every click a miss —
    /// correct, since there is nothing on screen to click yet.
    private(set) var contentSize: CGSize = .zero {
        didSet {
            guard contentSize != oldValue, contentSize != .zero else { return }
            onContentSize?(contentSize)
        }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    /// The JPEG seed, shown until the first access unit decodes. Its own layer rather than a draw
    /// into the view: it must sit UNDER the video layer and disappear the moment real frames start,
    /// and swapping a layer's contents is one assignment.
    private let seedLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(seedLayer)
        layer?.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        seedLayer.contentsGravity = .resizeAspect
        // No implicit animations: a frame arriving mid-animation would cross-fade with the previous
        // one, which on a 60 Hz mirror reads as motion blur.
        displayLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        seedLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Flipped so the view's y grows downward — the same direction as the device's own coordinates,
    /// which removes a per-event flip from the input path and the chance of forgetting it in one
    /// branch.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
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
        needsLayout = true
    }

    func enqueue(accessUnit: Data, isKeyframe: Bool) {
        guard let formatDescription else { return }
        // A failed decode leaves the renderer in `.failed` forever; flushing and waiting for the next
        // keyframe is the documented recovery, and the server sends one on request.
        if renderer.status == .failed { renderer.flush() }
        guard let sample = SimulatorVideoFormat.sampleBuffer(
            accessUnit: accessUnit, formatDescription: formatDescription, isKeyframe: isKeyframe,
        ) else { return }
        renderer.enqueue(sample)
        // The seed has done its job the moment real pixels exist. Kept until here rather than
        // dropped on connect so a stream that never produces a keyframe still shows something.
        if seedLayer.contents != nil { seedLayer.contents = nil }
    }

    func showSeed(_ jpeg: Data) {
        guard renderer.status != .rendering,
              let image = NSImage(data: jpeg), let cgImage = image.cgImage(
                  forProposedRect: nil, context: nil, hints: nil,
              ) else { return }
        // The seed arrives before any configuration, so it is also the first thing that tells the
        // view how big the device is — without it the fitted rect stays empty until the first IDR.
        if contentSize == .zero {
            contentSize = CGSize(width: cgImage.width, height: cgImage.height)
            needsLayout = true
        }
        seedLayer.contents = cgImage
    }

    /// Drop everything on the floor — a device switch, or a disconnect. Without the flush the next
    /// device's first frames decode against the previous device's parameter sets.
    func reset() {
        renderer.flush(removingDisplayedImage: true) {}
        seedLayer.contents = nil
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
        isTracking = true
        send?(.touch(.down, x: point.x, y: point.y, in: surface))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        // Clamped rather than dropped: a drag that leaves the frame is still a drag, and the device
        // needs the intermediate points to interpret it as a swipe rather than a jump.
        let point = clampedDevicePoint(for: event)
        send?(.touch(.move, x: point.x, y: point.y, in: surface))
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        let point = clampedDevicePoint(for: event)
        send?(.touch(.up, x: point.x, y: point.y, in: surface))
    }

    /// Scroll that has arrived but not yet been worth a swipe. Accumulating rather than dropping is
    /// what makes a wheel work at all: one notch is under iOS's pan slop, so sending it immediately
    /// would have the device ignore every tick, and dropping it would lose the travel instead of
    /// banking it. Measured 2026-08-04 — a per-tick swipe moved a Settings list not at all.
    private var scrollTravel: CGSize = .zero

    override func scrollWheel(with event: NSEvent) {
        guard let origin = devicePoint(for: event) else { return }
        let step = SimulatorScreenLayout.swipeVector(
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
        )
        scrollTravel = CGSize(
            width: scrollTravel.width + step.width, height: scrollTravel.height + step.height,
        )
        guard let end = SimulatorScreenLayout.swipeEnd(
            from: origin, delta: scrollTravel, fitted: fitted,
        ) else { return }
        scrollTravel = .zero
        // Short duration: a wheel tick is an impulse, and a 250 ms default would make the device lag
        // a scroll by a quarter second per tick.
        send?(.swipe(
            fromX: origin.x, fromY: origin.y, toX: end.x, toY: end.y, duration: 0.05, in: surface,
        ))
    }

    private var surface: SimulatorInputEnvelope.Surface {
        SimulatorScreenLayout.surface(fitted: fitted)
    }

    private func devicePoint(for event: NSEvent) -> CGPoint? {
        SimulatorScreenLayout.devicePoint(
            from: convert(event.locationInWindow, from: nil), fitted: fitted,
        )
    }

    private func clampedDevicePoint(for event: NSEvent) -> CGPoint {
        let fitted = fitted
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x - fitted.minX, 0), fitted.width),
            y: min(max(point.y - fitted.minY, 0), fitted.height),
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
        guard let code = SimulatorKeyMap.code(for: event.keyCode) else {
            // No mapping: fall back to the characters, which covers the whole printable range without
            // this file owning a layout table. Empty (a dead key, a modifier alone) is dropped.
            let text = event.charactersIgnoringModifiers ?? ""
            if !text.isEmpty, !event.modifierFlags.contains(.command) { send(.type(text)) }
            return
        }
        send(.key(code, modifiers: SimulatorKeyMap.modifiers(for: event.modifierFlags)))
    }
}

/// The device's frame as a SwiftUI view.
struct SimulatorScreenView: NSViewRepresentable {
    /// The stream's latest message. Driving the view from a value rather than reaching into it keeps
    /// the model the single owner of the connection.
    var frame: SimulatorScreenFrame
    var send: (SimulatorInputEnvelope) -> Void
    /// Optional so the bezel and the bare fallback can both mount this view while only the stage
    /// that owns the header cares what size the device turned out to be.
    var onContentSize: ((CGSize) -> Void)?

    func makeNSView(context _: Context) -> SimulatorScreenNSView {
        let view = SimulatorScreenNSView(frame: .zero)
        view.send = send
        view.onContentSize = onContentSize
        return view
    }

    func updateNSView(_ view: SimulatorScreenNSView, context _: Context) {
        view.send = send
        view.onContentSize = onContentSize
        switch frame.latest {
        case let .configuration(configuration): view.apply(configuration: configuration)
        case let .accessUnit(data, isKeyframe): view.enqueue(accessUnit: data, isKeyframe: isKeyframe)
        case let .seed(jpeg): view.showSeed(jpeg)
        case .none: view.reset()
        }
    }
}

/// The one-slot mailbox between the model and the view. A `struct` carrying the LATEST message plus a
/// monotonic sequence: SwiftUI coalesces updates, so a value that compares equal to the previous one
/// would be skipped — and two consecutive delta frames of identical bytes are entirely possible on a
/// static screen.
struct SimulatorScreenFrame: Equatable {
    enum Latest: Equatable {
        case none
        case configuration(SimulatorWireProtocol.AVCConfiguration)
        case accessUnit(Data, isKeyframe: Bool)
        case seed(Data)
    }

    var latest: Latest = .none
    var sequence: UInt64 = 0
}
#endif
