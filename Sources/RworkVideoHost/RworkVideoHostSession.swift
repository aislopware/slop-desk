#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import OSLog
import RworkVideoProtocol

/// The host-side session orchestrator for the GUI video path (PATH 2 / Phase 4).
///
/// This is the driver that wires the previously-disconnected islands into a working
/// pipeline:
///
/// ```
/// WindowCapturer (NV12 frame) ─▶ VideoEncoder (2-session HEVC, doc 18 §E)
///        ─▶ VideoPacketizer (FramePacketizer) ─▶ UDP video datagrams
/// WindowGeometryWatcher ─▶ geometry datagrams
/// CursorSampler ─▶ cursor position + (OOB) shape bitmap datagrams (cursor socket)
/// client input datagrams ─▶ InputDatagramRouter ─▶ InputInjector (CGEvent)
/// client control datagrams ─▶ VideoSessionStateMachine (hello/helloAck/bye)
/// ```
///
/// ⚠️ **HANG-SAFETY:** the live `start()` path brings up `SCStream` +
/// `VTCompressionSession` + UDP sockets, all of which HANG / require TCC headlessly.
/// This actor is COMPILED + reviewed and only driven from a real GUI host app. Its
/// PURE decision logic (``VideoSessionStateMachine`` / ``InputDatagramRouter`` /
/// ``VideoSendScheduler``) lives in `VideoSessionLogic.swift` and IS unit-tested.
///
/// Session bring-up (the wire detail for the docs step): plain UDP, no TCP. The
/// client sends ``VideoControlMessage/hello`` on the control channel; the host
/// validates the protocol version + window, replies ``VideoControlMessage/helloAck``,
/// and starts capture. Media (video/geometry) + the dedicated cursor socket then
/// flow; client input arrives on the input channel. ``VideoControlMessage/bye`` (or
/// `stop()`) tears it down.
public actor RworkVideoHostSession {
    private let log = Logger(subsystem: "rwork.video.host", category: "RworkVideoHostSession")

    /// Opt-in stderr diagnostics (set `RWORK_VIDEO_DEBUG=1`). OSLog `.info`/`.debug` are not
    /// persisted, so a headless verify (`scripts/check-video.sh`) cannot read the capture/encode
    /// flow from `log show`. When enabled, the key lifecycle beats are mirrored to stderr so the
    /// gate can pinpoint where (if anywhere) the pipeline stalls. No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["RWORK_VIDEO_DEBUG"] != nil
    private var encodedFrameCount = 0
    nonisolated private func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("rwork-videohostd[session]: \(message())\n".utf8))
    }

    private let transport: any VideoDatagramTransport
    private let window: SCWindow
    /// Capture/encode at `window points × captureScale` PIXELS — 2 (Retina) gives sharp text;
    /// the helloAck/cursor mapping stays in POINTS so coordinates are unaffected.
    private let captureScale: Double
    /// Live-encoder target bitrate (bits/sec). Higher = crisper text (HEVC softens glyph edges
    /// at low bitrate); raise it over LAN/NetBird where bandwidth is ample.
    private let bitrate: Int
    private let scheduler = VideoSendScheduler()
    private let router = InputDatagramRouter()
    private let recoveryRouter = RecoveryDatagramRouter()

    private var stateMachine: VideoSessionStateMachine
    private var packetizer: VideoPacketizer

    // Live components, created on accept (never in a test).
    private var capturer: WindowCapturer?
    private var encoder: VideoEncoder?
    private var geometryWatcher: WindowGeometryWatcher?
    private var cursorSampler: CursorSampler?
    private var injector: InputInjector?
    /// Whether the next injected input event must raise+focus first.
    private var inputNeedsRaise = true

    /// - Parameters:
    ///   - window: the desktop-independent window to remote.
    ///   - transport: the UDP datagram transport (production: ``NWVideoDatagramTransport``).
    ///   - fec: optional FEC scheme for the video packetizer (default 20% XOR parity).
    public init(window: SCWindow, transport: any VideoDatagramTransport, fec: FECScheme? = XORParityFEC(), captureScale: Double = 2.0, bitrate: Int = VideoEncoder.bitrateBitsPerSecond) {
        self.window = window
        self.transport = transport
        self.captureScale = max(1.0, captureScale)
        self.bitrate = bitrate
        self.stateMachine = VideoSessionStateMachine()
        self.packetizer = VideoPacketizer(fec: fec)
    }

    // MARK: Lifecycle

    /// Binds the UDP sockets and waits for the client `hello`. Capture/encode start
    /// only once a valid hello is accepted (so we never capture into the void).
    public func start() async throws {
        _ = stateMachine.start()
        try await transport.start { [weak self] channel, data in
            guard let self else { return }
            Task { await self.receive(channel: channel, data: data) }
        }
        log.info("video host session listening for client hello")
    }

    /// Tears down capture/encode/watchers/sockets.
    public func stop() async {
        for effect in stateMachine.stop() { await apply(effect) }
        await teardownLiveComponents()
        await transport.stop()
        log.info("video host session stopped")
    }

    // MARK: Inbound datagram routing

    private func receive(channel: VideoChannel, data: Data) async {
        switch channel {
        case .control:
            await handleControl(data)
        case .input:
            await handleInput(data)
        case .recovery:
            handleRecovery(data)
        case .video, .geometry, .cursor:
            // Host does not receive these (they are host→client). Ignore defensively.
            break
        }
    }

    private func handleControl(_ data: Data) async {
        let message: VideoControlMessage
        do { message = try VideoControlMessage.decode(data) } catch {
            log.error("dropping malformed control datagram")
            dbg("control datagram malformed (\(data.count)B) — dropped")
            return
        }
        dbg("control received: \(String(describing: message)) (window=\(window.windowID))")
        let bounds = currentWindowBoundsCG()
        let effects = stateMachine.handleControl(message, windowBoundsCG: bounds) { [window] requestedWindowID, viewport in
            // Accept only the window this session was created for; size the capture to
            // the real window backing store (clamp the requested viewport to it).
            guard requestedWindowID == UInt32(window.windowID) else { return nil }
            let w = UInt16(max(1, min(Double(UInt16.max), window.frame.width.rounded())))
            let h = UInt16(max(1, min(Double(UInt16.max), window.frame.height.rounded())))
            _ = viewport // viewport informs client-side scaling; host captures native window pixels.
            return (w, h)
        }
        for effect in effects { await apply(effect) }
    }

    private func handleInput(_ data: Data) async {
        let decision = router.route(datagram: data, mediaFlowing: stateMachine.mediaFlowing, needsRaise: inputNeedsRaise)
        switch decision {
        case .inject(let event, let raiseFirst):
            await inject(event, raiseFirst: raiseFirst)
        case .drop(let reason):
            log.error("dropping input datagram: \(reason)")
        case .ignoreNotStreaming:
            break
        }
    }

    private func inject(_ event: InputEvent, raiseFirst: Bool) async {
        guard let injector else { return }
        // Activate-THEN-control (doc 18 §A): the raise must COMPLETE before the event is
        // posted, else the first click of an interaction can land on the not-yet-frontmost
        // window. AWAIT the main-actor raise, then post — do not fire-and-forget the raise.
        if raiseFirst {
            await MainActor.run { injector.raiseTargetWindow() }
        }
        injector.inject(event)
        // Latch policy: after the first injected event we no longer force a raise,
        // until a mouse-up ends the interaction and re-arms it.
        inputNeedsRaise = InputDatagramRouter.rearmRaiseAfter(event)
    }

    private func handleRecovery(_ data: Data) {
        switch recoveryRouter.route(datagram: data, mediaFlowing: stateMachine.mediaFlowing) {
        case .forceKeyframe:
            // Force an IDR on the next captured frame so a client that lost frames
            // re-anchors immediately instead of waiting for the ~1s heartbeat IDR.
            capturer?.requestKeyframe()
        case .ack(let streamSeq):
            // No retransmit/LTR-pin window to advance yet; record for diagnostics.
            log.debug("recovery ack streamSeq=\(streamSeq, privacy: .public)")
        case .drop(let reason):
            log.error("dropping recovery datagram: \(reason)")
        case .ignoreNotStreaming:
            break
        }
    }

    // MARK: Effects

    private func apply(_ effect: VideoSessionStateMachine.Effect) async {
        switch effect {
        case .sendControl(let message):
            dbg("→ sending control: \(String(describing: message))")
            transport.send(scheduler.scheduleControl(message).bytes, on: .control)
        case .startCapture(_, let width, let height):
            dbg("effect startCapture \(width)x\(height) — bringing up live capture/encode")
            await startLiveComponents(width: Int(width), height: Int(height))
        case .stopCapture:
            dbg("effect stopCapture")
            await teardownLiveComponents()
        }
    }

    // MARK: Live component bring-up (GUI only)

    private func startLiveComponents(width: Int, height: Int) async {
        let bounds = currentWindowBoundsCG()

        // Capture/encode at PIXEL resolution (window points × captureScale) for sharp text;
        // helloAck/cursor coordinates stay in points (this multiplier is display-only).
        let pixelWidth = max(1, Int((Double(width) * captureScale).rounded()))
        let pixelHeight = max(1, Int((Double(height) * captureScale).rounded()))

        // Encoder: the EXACT doc-18 2-session HEVC config (created inside VideoEncoder).
        let encoder = VideoEncoder(width: pixelWidth, height: pixelHeight, bitrate: bitrate) { [weak self] avcc, keyframe, mode in
            guard let self else { return }
            Task { await self.onEncodedFrame(avcc: avcc, keyframe: keyframe, crisp: mode == .crisp) }
        }
        do {
            try encoder.createLiveSession()
            try encoder.createCrispSession()
        } catch {
            log.error("encoder session create failed: \(String(describing: error)) — aborting session")
            dbg("ENCODER create FAILED: \(String(describing: error)) — aborting")
            return
        }
        self.encoder = encoder

        // Capturer: NV12 frames → encoder.encodeLive (zero-copy hand-off). The capture
        // closure captures the encoder DIRECTLY (not via the actor) so the hot per-frame
        // path encodes synchronously on the capture queue and returns within the
        // queue-depth deadline — no actor hop per frame. `VideoEncoder` is
        // `@unchecked Sendable` and thread-safe for `encodeLive`. The encoded OUTPUT is
        // what hops back to the actor (`onEncodedFrame`) to packetize + send.
        let logCallback = log
        let capturer = WindowCapturer { pixelBuffer, pts, forceKeyframe in
            do {
                try encoder.encodeLive(pixelBuffer: pixelBuffer, presentationTime: pts, forceKeyframe: forceKeyframe)
            } catch {
                logCallback.error("live encode failed: \(String(describing: error))")
            }
        }
        self.capturer = capturer

        // Geometry watcher → geometry datagrams + keep input/cursor bounds in sync.
        let geometryWatcher = WindowGeometryWatcher(windowID: window.windowID, pid: window.owningApplication?.processID ?? 0) { [weak self] message in
            guard let self else { return }
            Task { await self.onGeometry(message) }
        }
        self.geometryWatcher = geometryWatcher

        // Cursor sampler → hot position datagrams (+ OOB shape bitmaps, shipped once
        // per new shapeID by the sampler itself). Both go on the dedicated cursor
        // socket so video backpressure never delays the pointer (doc 17 §3.3).
        let cursorSampler = CursorSampler(windowBoundsCG: bounds) { [weak self] update in
            guard let self else { return }
            Task { await self.onCursorUpdate(update) }
        } shapeHandler: { [weak self] shape in
            guard let self else { return }
            Task { await self.onCursorShape(shape) }
        }
        self.cursorSampler = cursorSampler

        // Input injector (created with the window pid + bounds).
        self.injector = InputInjector(pid: window.owningApplication?.processID ?? 0, windowID: window.windowID, windowBoundsCG: bounds)
        self.inputNeedsRaise = true

        // Bring the live sources up. `window` is an AppKit/SCK type (not Sendable);
        // it is owned only by this actor and handed to the capturer here. The capture
        // path is GUI-only and single-owner, so this hand-off is safe.
        let captureWindow = window
        do {
            nonisolated(unsafe) let w = captureWindow
            try await capturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg("SCStream capture started (\(pixelWidth)x\(pixelHeight) px @\(captureScale)×, \(width)x\(height) pt) — awaiting frames")
        } catch {
            log.error("capturer start failed: \(String(describing: error))")
            dbg("SCStream capture START FAILED: \(String(describing: error))")
        }
        geometryWatcher.startDragPolling()
        cursorSampler.start()
        log.info("live capture/encode/geometry/cursor running")
    }

    private func teardownLiveComponents() async {
        await capturer?.stop()
        cursorSampler?.stop()
        geometryWatcher?.stop()
        capturer = nil
        encoder = nil
        cursorSampler = nil
        geometryWatcher = nil
        injector = nil
    }

    // MARK: Component callbacks

    private func onEncodedFrame(avcc: Data, keyframe: Bool, crisp: Bool) {
        guard stateMachine.mediaFlowing else {
            dbg("encoded frame DROPPED (mediaFlowing=false)")
            return
        }
        encodedFrameCount += 1
        if encodedFrameCount == 1 || encodedFrameCount % 15 == 0 {
            dbg("encoded+sent frame #\(encodedFrameCount) (\(avcc.count)B, keyframe=\(keyframe), crisp=\(crisp))")
        }
        let fragments = packetizer.packetize(frame: avcc, keyframe: keyframe, crisp: crisp)
        for outgoing in scheduler.scheduleFrame(fragments) {
            transport.send(outgoing.bytes, on: outgoing.channel)
        }
    }

    private func onGeometry(_ message: WindowGeometryMessage) {
        guard stateMachine.mediaFlowing else { return }
        // Keep the cursor + input mapping origin in sync as the window moves.
        if let bounds = boundsFromGeometry(message) {
            cursorSampler?.updateWindowBounds(bounds)
            injector?.updateWindowBounds(bounds)
        }
        transport.send(scheduler.scheduleGeometry(message).bytes, on: .geometry)
    }

    private func onCursorUpdate(_ update: CursorUpdate) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(scheduler.scheduleCursor(.update(update)).bytes, on: .cursor)
    }

    /// A new cursor SHAPE bitmap to ship out-of-band (once per shapeID; the sampler
    /// owns the dedup). Sent on the cursor socket as a ``CursorShapeMessage``.
    private func onCursorShape(_ shape: CursorShapeMessage) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(scheduler.scheduleCursor(.shape(shape)).bytes, on: .cursor)
    }

    // MARK: Helpers

    private func currentWindowBoundsCG() -> VideoRect {
        // Live bounds via the watcher if present, else the window's creation frame.
        geometryWatcher?.currentBoundsCG() ?? VideoRect(window.frame)
    }

    private func boundsFromGeometry(_ message: WindowGeometryMessage) -> VideoRect? {
        switch message {
        case .bounds(let r): return r
        case .move, .resize, .title: return geometryWatcher?.currentBoundsCG()
        }
    }
}
#endif
