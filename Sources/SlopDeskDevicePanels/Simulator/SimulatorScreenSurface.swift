// SimulatorScreenSurface — the device's live frame on macOS, and the surface that turns a click into
// a tap.
//
// KIND 2, not kind 1 (docs/56 stage D, increment 52a, and the ledger's own §"Kind 2 — not views at
// all"). This class was already a plain `NSView` sitting in `SlopDeskClientUI` with a four-line
// `NSViewRepresentable` on top of it, and it imported this target for everything it actually does —
// ``SimulatorScreenLayout``, ``SimulatorScrollGesture``, ``SimulatorVideoFormat``,
// ``SimulatorInputEnvelope``, ``SimulatorKeyMap``. So the move DELETES an import edge rather than
// adding one, and there is no rewrite in it at all: the body below is the body it had, plus the
// access levels its new callers need.
//
// The representable is gone with it. AppKit callers mount this view directly
// (``SlopDeskMacUI/MacSimulatorBezelView``), and the phone keeps its own `SimulatorScreenUIView` and
// the `UIViewRepresentable` over it, in `SlopDeskPhoneUI` where a SwiftUI wrapper belongs.
//
// The pixels land in an `AVSampleBufferDisplayLayer`: sample buffers go in, hardware decode and
// display come out, and there is no pixel-buffer lifetime, pacer or compositor to own. The desktop
// video path builds all of that on top of a `VTDecompressionSession` because it needs zoom, pan-lock,
// a cursor overlay and 1:1 snapping. This needs one rectangle at panel size, so the simpler API is
// not a shortcut — it is the whole feature.
//
// FRAMES DO NOT ARRIVE AS STATE. The view registers itself with the model's ``SimulatorFrameSink`` on
// mount and is fed directly from the socket; no view framework is in the path. See that file for the
// measurement that forced it — 69.5 frames a second, each one invalidating the entire stage.
//
// INPUT MODEL. A press-drag-release becomes `touch1-down`/`move`/`up`, which is what makes a swipe,
// a drag and a long-press all work without special cases. A click with no movement is still sent as
// that triple rather than as `tap`, so the timing is the user's own — a deliberate hold on a list row
// opens its context menu exactly as it would on a device, where a synthesized 50 ms `tap` never
// could. It is also 3000× cheaper: measured 2026-08-04, `tap` occupies the server for 73 ms and a
// `touch1-*` for 0.03 ms.
//
// SCROLL IS A FINGER, not a flick — see ``SimulatorScrollGesture`` for the 275 ms that bought.
// PINCH is the trackpad's own magnify gesture as a two-finger contact; it is rate-limited because
// `touch2-move` costs 25 ms a piece, twenty times what the single-finger path costs
// (``SimulatorPresentation/pinchInterval``, which the phone's real second finger reads too).
// EDGES: a contact that starts in iOS's own edge bands carries the `edge` hint, which is what makes
// swipe-up-for-home and pull-down-for-the-shades work from a drag rather than only from a button.
//
// ⚠️ Hang-safety: this file builds a display layer, which spins up a decompression session on first
// enqueue. Nothing here may be constructed in a unit test — the geometry it depends on lives in
// ``SimulatorScreenLayout``, the gesture machine in ``SimulatorScrollGesture`` and the sample
// construction in ``SimulatorVideoFormat``, all pure and all testable without it.

// ⚠️ THE GATE IS `canImport(AppKit)`, NEVER `os(macOS)`. This target is the phone's floor too, and
// `slopdesk-invariants` fails the build on an `os(macOS)` here for exactly that reason: the question
// this file asks is "is there an `NSView` to subclass", which is a framework question, not a
// product one.
#if canImport(AppKit)
import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// The AppKit surface. A plain `NSView` hosting the display layer, plus the mouse/scroll handling —
/// no gesture-recognizer API on either framework can express "report every intermediate point of a
/// drag at the rate they arrive", which is precisely what a touch sequence is.
package final class SimulatorScreenNSView: NSView, SimulatorFrameRenderer {
    /// Where a gesture goes. Set by the mounting view; nil until then, so an early click is dropped
    /// rather than queued against a device that may not be the one finally selected.
    package var send: ((SimulatorInputEnvelope) -> Void)?

    /// Which way the device is being held. Needed for the SCROLL DELTA and the edge bands, neither of
    /// which passes through the view's own geometry: a delta arrives in SCREEN space while the
    /// framebuffer never turns, so it is handed to `slopdesk_panel_scroll_accept` as an ANGLE and
    /// un-rotated there — see ``SimulatorScrollGesture/accept(delta:isPrecise:phase:pointer:fitted:orientation:)``.
    package var orientation: SimulatorOrientation = .portrait

    /// Reports the framebuffer size upward the moment the decoder works it out. The header prints
    /// it, and this is the only place in the app that knows: the size is in the SPS, and the layer
    /// has already parsed it to build a format description. Reaching for it any other way means
    /// parsing that record a second time to learn something that is already sitting here.
    package var onContentSize: ((CGSize) -> Void)?

    /// The stream's pixel size, learned from the format description. `.zero` until the first
    /// configuration message, which is what makes the fitted rect empty and every click a miss —
    /// correct, since there is nothing on screen to click yet.
    package private(set) var contentSize: CGSize = .zero {
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

    override package init(frame frameRect: NSRect) {
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
    override package var isFlipped: Bool { true }

    override package func layout() {
        super.layout()
        let fitted = fitted
        displayLayer.frame = fitted
        seedLayer.frame = fitted
    }

    package var fitted: CGRect {
        SimulatorScreenLayout.fittedRect(content: contentSize, in: bounds.size)
    }

    // MARK: Frames

    package func apply(configuration: SimulatorWireProtocol.AVCConfiguration) {
        guard let description = SimulatorVideoFormat.formatDescription(for: configuration) else { return }
        formatDescription = description
        contentSize = SimulatorVideoFormat.dimensions(of: description)
        needsLayout = true
    }

    package func enqueue(accessUnit: Data, isKeyframe: Bool) {
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

    package func showSeed(_ jpeg: Data) {
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
    package func reset() {
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

    /// Which system edge the press started in, carried on every event of that gesture. iOS decides
    /// whether a drag is a scroll or a system gesture from where the finger LANDED, so the hint has
    /// to ride the whole sequence rather than only its first envelope.
    private var trackingEdge: String?

    override package func mouseDown(with event: NSEvent) {
        guard let point = devicePoint(for: event) else { return }
        endScroll()
        isTracking = true
        trackingEdge = SimulatorScreenLayout.edge(
            at: point, fitted: fitted, orientation: orientation,
        )
        send?(.touch(.down, x: point.x, y: point.y, edge: trackingEdge, in: surface))
    }

    override package func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        // Clamped rather than dropped: a drag that leaves the frame is still a drag, and the device
        // needs the intermediate points to interpret it as a swipe rather than a jump.
        let point = clampedDevicePoint(for: event)
        send?(.touch(.move, x: point.x, y: point.y, edge: trackingEdge, in: surface))
    }

    override package func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        let point = clampedDevicePoint(for: event)
        send?(.touch(.up, x: point.x, y: point.y, edge: trackingEdge, in: surface))
        trackingEdge = nil
    }

    // MARK: Scroll

    private let scroll = SimulatorScrollGesture()
    /// Closes a CLASSIC WHEEL's gesture. A wheel has no phases, so nothing on the wire says the user
    /// stopped — the finger is lifted once the notches stop coming. A trackpad never uses this: its
    /// own `.ended` is exact, and waiting out an idle window after it would hold a contact down for a
    /// tenth of a second after the fingers left.
    private var wheelIdle: Timer?
    /// Matches `baguette`'s own web UI, which closes a synthesized wheel gesture on the same window.
    /// The Mac's alone, unlike ``SimulatorPresentation/pinchInterval``: there is no wheel on a phone,
    /// so there is no second half to keep it in step with.
    private static let wheelIdleInterval: TimeInterval = 0.12

    override package func scrollWheel(with event: NSEvent) {
        // MOMENTUM IS THE DEVICE'S JOB. macOS keeps delivering deltas after the fingers lift, and
        // replaying them as finger movement would scroll twice: once from our synthetic travel and
        // again from the deceleration iOS computes from the touch history at lift. Dropping them is
        // what makes the device's own inertia the only inertia.
        guard event.momentumPhase.isEmpty else { return }

        let phase: SimulatorScrollGesture.Phase
        switch event.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended,
             .cancelled: phase = .ended
        case []: phase = .wheel
        default: return // `.mayBegin` and anything later — not a delta worth acting on.
        }

        guard let origin = devicePoint(for: event) ?? scroll.finger else { return }
        let envelopes = scroll.accept(
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: phase, pointer: origin, fitted: fitted, orientation: orientation,
        )
        for envelope in envelopes { send?(envelope) }

        wheelIdle?.invalidate()
        wheelIdle = nil
        guard phase == .wheel else { return }
        wheelIdle = Timer.scheduledTimer(
            withTimeInterval: Self.wheelIdleInterval, repeats: false,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endScroll() }
        }
    }

    /// Lift whatever the scroll left down. Called by the wheel's idle timer, and by a mouse press —
    /// a click while a synthetic finger is still on the screen would be two contacts at once.
    private func endScroll() {
        wheelIdle?.invalidate()
        wheelIdle = nil
        for envelope in scroll.lift(in: fitted) { send?(envelope) }
    }

    /// The view is going away — a device switch, or the panel closing. The contact is forgotten
    /// rather than lifted: an `up` has nowhere to go once the socket for it is gone.
    package func abandonGestures() {
        wheelIdle?.invalidate()
        wheelIdle = nil
        scroll.abandon()
        pinchCentre = nil
        isTracking = false
    }

    // MARK: Pinch

    /// The trackpad's own magnify gesture, as the two contacts a device understands. `touch2-move`
    /// costs 25 ms of server time — a thousand times a `touch1-move` — so this is the one input path
    /// that is deliberately rate-limited rather than reported at the rate the events arrive.
    private var pinchCentre: CGPoint?
    private var pinchSpread: CGFloat = 0
    private var pinchSentAt: TimeInterval = 0
    /// The pair's starting separation, and the floor a full pinch closes to. Wide enough that a
    /// spread has somewhere to go, narrow enough to sit inside a phone's width. The Mac's alone: it
    /// describes a pair of fingers this side INVENTS, and the phone's two are real.
    private static let pinchSpread: CGFloat = 160

    override package func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            guard let centre = devicePoint(for: event) else { return }
            pinchCentre = centre
            pinchSpread = Self.pinchSpread
            pinchSentAt = 0
            sendPinch(phase: .down)
        case .changed:
            guard pinchCentre != nil else { return }
            // Multiplicative: magnification is a fractional delta, so a pinch and the spread that
            // undoes it have to be the same factor in each direction.
            pinchSpread = min(max(pinchSpread * (1 + event.magnification), 24), 2000)
            let now = event.timestamp
            guard now - pinchSentAt >= SimulatorPresentation.pinchInterval else { return }
            pinchSentAt = now
            sendPinch(phase: .move)
        case .ended,
             .cancelled:
            guard pinchCentre != nil else { return }
            sendPinch(phase: .up)
            pinchCentre = nil
        default:
            break
        }
    }

    private func sendPinch(phase: SimulatorInputEnvelope.TouchPhase) {
        guard let pinchCentre else { return }
        let (first, second) = SimulatorScreenLayout.pinchFingers(
            centre: pinchCentre, spread: pinchSpread, fitted: fitted,
        )
        send?(.touch2(
            phase, x1: first.x, y1: first.y, x2: second.x, y2: second.y, in: surface,
        ))
    }

    // MARK: Geometry

    private var surface: SimulatorInputEnvelope.Surface {
        SimulatorScreenLayout.surface(fitted: fitted)
    }

    private func devicePoint(for event: NSEvent) -> CGPoint? {
        SimulatorScreenLayout.devicePoint(
            from: convert(event.locationInWindow, from: nil), fitted: fitted,
        )
    }

    private func clampedDevicePoint(for event: NSEvent) -> CGPoint {
        SimulatorScreenLayout.clampedDevicePoint(
            from: convert(event.locationInWindow, from: nil), fitted: fitted,
        )
    }

    // MARK: Keyboard

    /// Clicking the frame takes key focus, so typing goes to the device rather than to whatever pane
    /// was focused before.
    override package var acceptsFirstResponder: Bool { true }

    override package func keyDown(with event: NSEvent) {
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
        send(.key(code, modifiers: SimulatorKeyMap.modifiers(for: event)))
    }
}
#endif
