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
    /// Full per-event injection trace (`RWORK_INPUT_TRACE=1`): logs EVERY injected input event
    /// with a monotonic sequence number (NOT sampled), so a loopback run can read the exact
    /// injected ORDER — the ground truth for the reorder fix. No-op in production.
    private static let inputTrace = ProcessInfo.processInfo.environment["RWORK_INPUT_TRACE"] != nil
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

    /// Ordered + COALESCING inbound pump — the input-reorder fix AND the input-latency fix.
    /// The transport delivers datagrams in strict arrival order on its serial receive queue; it
    /// APPENDS each to `inboundQueue` synchronously (no actor hop, so arrival order is carried
    /// end-to-end) and signals `inboundWakeup`. A SINGLE consumer task wakes, BATCH-DRAINS the
    /// whole backlog, and `receiveBatch` collapses consecutive pointer-motion runs to their
    /// latest (``InputMotionCoalescer``) before injecting. This both removes the inverted-down/up
    /// stuck-button race the old per-datagram `Task { await receive }` fan-out introduced AND
    /// stops a 150:1 motion-heavy flood from accruing multi-second lag by replaying every stale
    /// position: when the consumer keeps up the batches are size ~1 (coalescing is a no-op); only
    /// when it falls behind does a run collapse, bounding the lag to ~one injection. Control and
    /// recovery datagrams ride the same FIFO and are never dropped or reordered.
    private var inboundQueue: InboundQueue?
    private var inboundWakeup: AsyncStream<Void>.Continuation?
    private var inboundConsumer: Task<Void, Never>?

    /// Ordered encoder-OUTPUT pump (the encoder-reorder fix — the last instance of the recurring
    /// unstructured-`Task`-ordering class). `VideoEncoder` is RealTime + AllowFrameReordering=false,
    /// so its VT output callback fires in STRICT encode order on a serial queue. The prior shape —
    /// `Task { await self.onEncodedFrame(...) }` per frame — raced those frames onto the actor with
    /// NO FIFO guarantee across separately-created Tasks, so frame N+1 could be packetized (and get
    /// a LOWER frameID/streamSeq) before frame N → the client saw a delta before its IDR →
    /// awaitingKeyframe drop + a needless requestIDR. The VT callback now APPENDS to this
    /// lock-protected FIFO synchronously (carrying encode order end-to-end) and signals; a SINGLE
    /// consumer task drains it and `await`s ``onEncodedFrame(avcc:keyframe:crisp:)`` IN ORDER, so
    /// `packetizer.packetize` assigns frameID/streamSeq in encode order. ONE ordered hop, not one
    /// detached Task per frame. Shared across resize (the queue/consumer are the actor's, created
    /// once in ``start()``); every encoder-callback site feeds the SAME queue.
    private var encodedQueue: EncodedFrameQueue?
    private var encodedWakeup: AsyncStream<Void>.Continuation?
    private var encodedConsumer: Task<Void, Never>?

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
        // ORDERED + COALESCING inbound path. A lock-protected queue (appended on the transport's
        // serial receive queue, preserving arrival order) plus a coalesced wakeup signal; the
        // single consumer batch-drains the backlog and `receiveBatch` collapses pointer-motion
        // runs to their latest before injecting. (This replaced a legacy per-datagram
        // `Task { await receive }` fan-out that raced inbound datagrams into the actor OUT of
        // arrival order — a queued `mouseUp` could overtake its `mouseDown` through the
        // `await raiseTargetWindow()` suspension, inverting down/up and sticking a button down.)
        let queue = InboundQueue()
        let (wakeups, wakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        inboundQueue = queue
        inboundWakeup = wakeup
        inboundConsumer = Task { [weak self] in
            for await _ in wakeups {
                guard let self else { break }
                let batch = queue.drainAll()
                if batch.isEmpty { continue }   // a coalesced wakeup an earlier drain already emptied
                await self.receiveBatch(batch)
            }
        }
        // Enqueue THEN signal on the transport's serial receive queue, so the consumer always
        // runs a drain after the last append (no lost wakeup). Append is O(1) and never blocks.
        try await transport.start { channel, data in
            queue.append(channel, data)
            wakeup.yield()
        }

        // Ordered encoder-OUTPUT pump (FIX C). Mirrors the inbound pump: a lock-protected FIFO the
        // VT serial callback appends to (preserving strict encode order) + a coalesced wakeup; a
        // single consumer drains and awaits `onEncodedFrame` IN ORDER so frameID/streamSeq are
        // assigned in encode order, not actor-processing order.
        let eq = EncodedFrameQueue()
        let (eWakeups, eWakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        encodedQueue = eq
        encodedWakeup = eWakeup
        encodedConsumer = Task { [weak self] in
            for await _ in eWakeups {
                guard let self else { break }
                let batch = eq.drainAll()
                // Process IN ORDER (the FIFO carried encode order from the serial VT callback).
                for frame in batch {
                    await self.onEncodedFrame(avcc: frame.avcc, keyframe: frame.keyframe, crisp: frame.crisp)
                }
            }
        }

        log.info("video host session listening for client hello")
    }

    /// Tears down capture/encode/watchers/sockets.
    public func stop() async {
        // End the coalescing inbound pump first so no buffered datagram injects mid-teardown.
        inboundWakeup?.finish()
        inboundWakeup = nil
        inboundConsumer?.cancel()
        inboundConsumer = nil
        inboundQueue = nil
        // End the ordered encoder-output pump too (no buffered frame packetizes mid-teardown).
        encodedWakeup?.finish()
        encodedWakeup = nil
        encodedConsumer?.cancel()
        encodedConsumer = nil
        encodedQueue = nil
        for effect in stateMachine.stop() { await apply(effect) }
        await teardownLiveComponents()
        await transport.stop()
        log.info("video host session stopped")
    }

    // MARK: Inbound datagram routing

    /// Processes a batch of inbound datagrams drained from the coalescing queue. Consecutive
    /// `.input` datagrams are decoded into a run and collapsed via
    /// ``InputMotionCoalescer`` so only the LATEST of each motion run is injected; a control or
    /// recovery datagram is a flush BOUNDARY — the pending input run injects first (in arrival
    /// order), then the boundary is handled — so down/up/key ordering and ``InputButtonBalance``
    /// are never disturbed.
    private func receiveBatch(_ batch: [(VideoChannel, Data)]) async {
        var inputRun: [InputEvent] = []
        for (channel, data) in batch {
            switch channel {
            case .input:
                // Gate on streaming (matches `InputDatagramRouter.route`) and decode here so the
                // run can be coalesced. A malformed datagram is dropped, never crashes the receiver.
                guard stateMachine.mediaFlowing else { continue }
                do { inputRun.append(try InputEvent.decode(data)) }
                catch { log.error("dropping input datagram: undecodable") }
            case .control:
                let run = inputRun; inputRun = []
                await injectCoalesced(run)
                await handleControl(data)
            case .recovery:
                let run = inputRun; inputRun = []
                await injectCoalesced(run)
                handleRecovery(data)
            case .video, .geometry, .cursor:
                // Host does not receive these (host→client). Ignore defensively.
                break
            }
        }
        await injectCoalesced(inputRun)
    }

    /// Collapses an arrival-ordered run of input events to its coalesced form and injects each,
    /// reproducing the per-event raise latch the single-event path applied: a button-down raises
    /// + focuses first (`alwaysRaises`), a coalesced motion run never does, and `inputNeedsRaise`
    /// is advanced between events (mouse-up re-arms it). Motion is the only class collapsed, so
    /// the raise/button-balance semantics for every down/up are byte-identical to the un-batched path.
    private func injectCoalesced(_ run: [InputEvent]) async {
        guard !run.isEmpty else { return }
        for event in InputMotionCoalescer.coalesce(run) {
            let raiseFirst = inputNeedsRaise || InputDatagramRouter.alwaysRaises(event)
            await inject(event, raiseFirst: raiseFirst)
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
        let effects = stateMachine.handleControl(message, windowBoundsCG: bounds, resolveCaptureSize: { [window] requestedWindowID, viewport in
            // Accept only the window this session was created for; size the capture to
            // the real window backing store (clamp the requested viewport to it).
            guard requestedWindowID == UInt32(window.windowID) else { return nil }
            let w = UInt16(max(1, min(Double(UInt16.max), window.frame.width.rounded())))
            let h = UInt16(max(1, min(Double(UInt16.max), window.frame.height.rounded())))
            _ = viewport // viewport informs client-side scaling; host captures native window pixels.
            return (w, h)
        }, resolveResizeSize: { [window] requestedWindowID, desired in
            // Accept only the session's window; sanity-clamp the desired POINT size into a
            // valid, non-zero, UInt16-safe range. This is a POLICY pre-clamp only — the AX
            // read-back in `apply(.resizeCapture)` is the AUTHORITATIVE achieved size (the
            // window may further clamp to its own min/max). Min 1×1; max ceilinged at the
            // UInt16 wire limit (the clamp already enforces it).
            guard requestedWindowID == UInt32(window.windowID) else { return nil }
            return SizeNegotiation.clamp(desired: desired,
                                         min: VideoSize(width: 1, height: 1),
                                         max: VideoSize(width: Double(UInt16.max), height: Double(UInt16.max)))
        })
        for effect in effects { await apply(effect) }
        // CONCURRENCY-HOST-1: a clean `bye` re-arms the session to `.listening` and tears down
        // capture (above), but the pinned UDP flow slot stays pinned (UDP has no FIN) — so a
        // reconnecting client's fresh hello (a new source port ⇒ a new 4-tuple) was silently
        // refused at the listener until the daemon restarted. Free the flow now so the next
        // client can re-pin and reconnect WITHOUT a daemon restart. (A crash WITHOUT a bye still
        // relies on an idle-timeout reaper — documented follow-up in docs/25 §4.)
        if case .bye = message { transport.resetClientFlow() }
    }

    /// CONCURRENCY-HOST-1 crash-without-bye reaper hook. Handles a reaped
    /// (crashed / lost-bye) client EXACTLY like a clean `bye`: run the SM's bye effects (which
    /// include `.stopCapture` → the identity-guarded `teardownLiveComponents`), then free the pinned
    /// UDP flow LAST via `resetClientFlow()` — byte-for-byte the same order as `handleControl`'s bye
    /// branch (line ~268).
    ///
    /// Why this order, and why `runReaperTick` deliberately does NOT free the slot first: the slot
    /// MUST stay pinned for the whole teardown. If the transport freed it before this async teardown
    /// (the earlier design), a reconnecting client could be accepted DURING the `await capturer.stop()`
    /// suspension and then have its FRESH capture torn down — the streaming-but-dead F2 wedge the
    /// reviewer caught. Keeping the pin until the very end means a reconnect is refused at the
    /// listener until teardown finishes AND the SM is `.listening`, so handleReap can never demote
    /// or tear down a newer client: the race is eliminated by construction, identical to the proven
    /// clean-bye path. There is deliberately NO second unconditional `teardownLiveComponents` — the
    /// SM `.bye` effect already tore down (identity-guarded); a redundant call re-opened the race.
    /// Wired as `Task { await session.handleReap() }` from `transport.onReap` (the only new async
    /// work; inbound delivery stays inline).
    /// Reaper TIMING is [MS-confirm]; the STRUCTURE mirrors the unit-tested clean-bye semantics.
    public func handleReap() async {
        let bounds = currentWindowBoundsCG()
        for effect in stateMachine.handleControl(.bye, windowBoundsCG: bounds, resolveCaptureSize: { _, _ in nil }, resolveResizeSize: { _, _ in nil }) {
            await apply(effect)
        }
        transport.resetClientFlow()
    }

    private func inject(_ event: InputEvent, raiseFirst: Bool) async {
        guard let injector else { return }
        // Activate-THEN-control (doc 18 §A): the raise must COMPLETE before the event is
        // posted, else the first click of an interaction can land on the not-yet-frontmost
        // window. AWAIT the main-actor raise, then post — do not fire-and-forget the raise.
        if raiseFirst {
            // Clear the latch BEFORE the main-actor hop. That hop is a SUSPENSION POINT that
            // releases the actor, so the burst of `.mouseDrag`/`.mouseMove` datagrams behind a
            // mouseDown interleaves here. With the latch left armed, each of them would also
            // raise (thundering-herd of AX raises + app activations mid-drag, which can itself
            // disrupt a selection); clearing it now means only this first event raises and the
            // rest of the interaction injects straight through.
            inputNeedsRaise = false
            await MainActor.run { injector.raiseTargetWindow() }
            // The main-actor hop is a suspension point: a `stop()`/`bye` teardown can run here
            // and nil the injector (and close the sockets). Re-check on the actor before posting
            // so a buffered datagram cannot inject a stray, UNBALANCED event into the target app
            // after the session was torn down.
            guard self.injector != nil else { return }
        }
        dbgInject(event)
        injector.inject(event)
        // A mouse-up ends the interaction → re-arm so the NEXT interaction raises+focuses.
        if InputDatagramRouter.rearmRaiseAfter(event) { inputNeedsRaise = true }
    }

    /// Opt-in (`RWORK_VIDEO_DEBUG=1`) trace of the injected input stream, so a hardware run
    /// can confirm drags flow as `.mouseDrag` (not phantom `.mouseMoved`) and see the
    /// down/up framing. Pointer streams are high-rate, so moves/drags are SAMPLED (1-in-25)
    /// to avoid flooding stderr and perturbing injection timing; button/key/scroll log every
    /// event. No-op in production.
    private var dbgInputCount = 0
    private var injectTraceSeq = 0
    private func dbgInject(_ event: InputEvent) {
        if Self.inputTrace {
            // GROUND TRUTH for the reorder fix: every injected event in strict order, numbered.
            injectTraceSeq += 1
            FileHandle.standardError.write(Data("rwork-videohostd[inject #\(injectTraceSeq)]: \(Self.inputName(event))\n".utf8))
            return
        }
        guard Self.debugStderr else { return }
        switch event {
        case .mouseMove, .mouseDrag:
            dbgInputCount += 1
            if dbgInputCount % 25 == 1 { dbg("inject \(Self.inputName(event)) (pointer sample #\(dbgInputCount))") }
        default:
            dbg("inject \(Self.inputName(event))")
        }
    }
    private static func inputName(_ event: InputEvent) -> String {
        switch event {
        case .mouseMove: return "mouseMove"
        case .mouseDrag(let b, _, _, _, _): return "mouseDrag(\(b))"
        case .mouseDown(let b, _, let c, _, _): return "mouseDown(\(b),clicks=\(c))"
        case .mouseUp(let b, _, let c, _, _): return "mouseUp(\(b),clicks=\(c))"
        case .scroll: return "scroll"
        case .key(let kc, let down, _, _): return "key(\(kc),\(down ? "down" : "up"))"
        case .text: return "text"
        }
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
        case .reshipCursorShape(let shapeID):
            // FIX B self-heal: the client lost this shape's one-shot bitmap (or it never fit
            // one datagram). Re-emit it through the SAME shape handler so it rides the cursor
            // socket again as a `CursorShapeMessage`; the client cache re-insert is idempotent.
            dbg("recovery requestCursorShape \(shapeID) — re-shipping cursor shape")
            cursorSampler?.reshipShape(shapeID)
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
        case .resizeCapture(let width, let height, let epoch):
            await applyResize(width: width, height: height, epoch: epoch)
        }
    }

    // MARK: In-session resize (PATH A — AX window resize)

    /// Performs the live in-session resize for a `.resizeCapture` effect (the SM already
    /// clamped + epoch-gated the request). PATH A: resize the REAL host window via the
    /// Accessibility API, read back the ACHIEVED size, rebuild the encoder + capturer at the
    /// achieved PIXEL size, and only THEN send `resizeAck(achieved, epoch)`. Abort cleanly
    /// (keep the old encoder running, send NO ack) on any AX/encoder failure — never crash.
    ///
    /// Ordering (industry drain→recreate→forceIDR + the spec's option 4b):
    ///   a. AX-resize the window; read back the achieved POINT size (window may self-clamp).
    ///   b. Build the NEW encoder (createLive + createCrisp) FIRST; abort if it throws.
    ///   c. Drain the OLD encoder (`completeFrames`) so no in-flight output is dropped, then
    ///      stop the OLD capturer and start a NEW one at the achieved pixel size — the new
    ///      capturer forces an IDR on its first delivered frame (`hasEmittedFirstFrame`), so
    ///      the fresh VPS/SPS/PPS rides that IDR and the client decoder auto-reconfigures.
    ///   d. Send `resizeAck` LAST — after the new capturer/encoder is live. NOTE: `start()` only
    ///      kicks off the SCStream; it does NOT await the first delivered frame, so the ack MAY
    ///      reach the client just BEFORE the first new-size IDR. That is SAFE: the client
    ///      frame-GATES adoption (re-bases `decodedSize` only when a decoded buffer at the new
    ///      size actually arrives — `noteDecoded` / ``ResizeAdoption``), NOT on ack receipt.
    ///      Correctness rests on the client gate, not on send ordering.
    private func applyResize(width: UInt16, height: UInt16, epoch: UInt32) async {
        // Must still be streaming with a live capturer/encoder to resize (a bye/stop could have
        // raced in before this effect ran). If not, drop the resize (no ack).
        guard stateMachine.mediaFlowing, let oldCapturer = capturer, let oldEncoder = encoder else {
            dbg("resizeCapture \(width)x\(height) epoch=\(epoch) — not streaming / no live components; dropped")
            return
        }

        // a. AX-resize the REAL window to the requested POINT size; read back the ACHIEVED size.
        //    `geometryWatcher` owns the windowID/pid + the frame-matching AX lookup. If the
        //    window can't be resized (fixed-size/sheet → kAXErrorAttributeUnsupported, or a hung
        //    app → kAXErrorCannotComplete) we ABORT: keep the old encoder, send no ack.
        guard let watcher = geometryWatcher else {
            dbg("resizeCapture epoch=\(epoch) — no geometry watcher; dropped")
            return
        }
        // FIX #5: snapshot the ACHIEVED point size BEFORE the AX resize so any abort AFTER the
        // window has already moved can roll the window back to it (window/capture aspect must
        // agree again) and, for the dead-capturer case, rebuild an old-size capturer so frames
        // resume. `currentWindowBoundsCG()` reads the live window via the watcher and itself falls
        // back to the window's creation frame if the live read fails — never nil.
        let preResizePoints: VideoSize = currentWindowBoundsCG().size
        let requestedPoints = VideoSize(width: Double(width), height: Double(height))
        guard let achievedPoints = await MainActor.run(body: { watcher.resizeWindow(toPoints: requestedPoints) }) else {
            log.error("AX window resize unavailable/failed — keeping current capture size")
            dbg("resizeCapture epoch=\(epoch) — AX resize failed/unsupported; ABORTED (encoder unchanged)")
            return
        }
        // The main-actor hop above is a suspension point — re-check identity so a superseding
        // bye/stop teardown (which nils + tears down our refs) cannot make us resize a dead session.
        guard stateMachine.mediaFlowing, capturer === oldCapturer, encoder === oldEncoder else {
            dbg("resizeCapture epoch=\(epoch) — session superseded during AX resize; aborted")
            return
        }

        let achievedWidth = UInt16(max(1, min(Double(UInt16.max), achievedPoints.width.rounded())))
        let achievedHeight = UInt16(max(1, min(Double(UInt16.max), achievedPoints.height.rounded())))
        let pixelWidth = max(1, Int((Double(achievedWidth) * captureScale).rounded()))
        let pixelHeight = max(1, Int((Double(achievedHeight) * captureScale).rounded()))

        // b. Build the NEW encoder FIRST (off the live path). If creation throws, abort and keep
        //    the OLD encoder running — degrade to no-resize, never to a dead session.
        let newEncoder = VideoEncoder(width: pixelWidth, height: pixelHeight, bitrate: bitrate, outputHandler: makeEncoderOutputHandler())
        do {
            try newEncoder.createLiveSession()
            try newEncoder.createCrispSession()
        } catch {
            log.error("resize encoder create failed: \(String(describing: error)) — keeping old encoder")
            dbg("resizeCapture epoch=\(epoch) — new encoder create FAILED; ABORTED (old encoder kept)")
            // FIX #5: the AX window resize at (a) already happened, but the OLD capturer is still
            // running at the OLD pixel config — so the (now bigger/smaller) window content is scaled
            // into the old buffer → a distorted stream with no ack. Roll the AX window BACK to the
            // pre-resize point size so the running old capture matches the window aspect again. The
            // old encoder/capturer are untouched (still installed + live); only the window geometry
            // is restored. (See the SM re-ack-lies residual note at the function tail.)
            await rollBackWindow(toPoints: preResizePoints, watcher: watcher, epoch: epoch)
            return
        }

        // c. Build the NEW capturer bound to the new encoder (option 4b — stop the old capturer,
        //    start a fresh one at the achieved pixel size). A new capturer ⇒ hasEmittedFirstFrame
        //    false ⇒ forced IDR on its first frame for free, and avoids the per-frame
        //    encoder-ref swap race entirely.
        let logCallback = log
        let newCapturer = WindowCapturer { pixelBuffer, pts, forceKeyframe in
            do {
                try newEncoder.encodeLive(pixelBuffer: pixelBuffer, presentationTime: pts, forceKeyframe: forceKeyframe)
            } catch {
                logCallback.error("live encode (post-resize) failed: \(String(describing: error))")
            }
        }

        // Stop the OLD capturer first (no frames into the dead encoder), then drain the OLD
        // encoder so any already-encoded output is flushed before it is released.
        await oldCapturer.stop()
        oldEncoder.completeFrames()

        // FIX #1: `oldCapturer.stop()` is an UNGUARDED suspension point. A `bye`/`stop` teardown
        // (or a newer resize) can run while we are suspended. The only prior post-await guard runs
        // AFTER we install `self.capturer = newCapturer`, so it could never catch a teardown that
        // ran DURING this suspension (it would compare newCapturer to itself). Re-assert the
        // supersede guard HERE, before installing: if the session was torn down OR our refs were
        // swapped, simply return. `newCapturer` is NOT started yet (no SCStream to stop) and both
        // locals deinit on return (VideoEncoder.deinit invalidates its VTCompressionSessions), so
        // we install nothing and send no ack. Mirrors the pre-AX recheck + startLiveComponents'
        // post-await identity guard.
        //
        // FIX #8 (rapid-double-resize epoch race): a newer
        // resize request can commit a higher `lastResizeEpoch` in the SM while we are suspended.
        // Only the NEWEST epoch may install — abort a stale one (re-read the SM under actor
        // isolation: `epoch >= stateMachine.lastResizeEpoch`).
        guard stateMachine.mediaFlowing, capturer === oldCapturer, encoder === oldEncoder,
              epoch >= stateMachine.lastResizeEpoch else {
            dbg("resizeCapture epoch=\(epoch) — superseded/stale during oldCapturer.stop (lastEpoch=\(stateMachine.lastResizeEpoch)); aborting install")
            return
        }

        // Install the new components, then bring the new SCStream up at the achieved pixel size.
        self.encoder = newEncoder
        self.capturer = newCapturer
        let captureWindow = window
        do {
            nonisolated(unsafe) let w = captureWindow
            try await newCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg("resize: new SCStream started (\(pixelWidth)x\(pixelHeight) px @\(captureScale)×, \(achievedWidth)x\(achievedHeight) pt) epoch=\(epoch)")
        } catch {
            log.error("resize capturer start failed: \(String(describing: error))")
            dbg("resizeCapture epoch=\(epoch) — new capturer START FAILED")
            // FIX #5: the OLD capturer is already stopped and the NEW SCStream.start threw, so the
            // installed `self.capturer` is a DEAD stream (stream == nil) — no frames will EVER come
            // again. requestIDR / the heartbeat path is a no-op on a dead capturer (the prior claim
            // that "the heartbeat path can recover" is FALSE here). Recover explicitly:
            //   (a) roll the AX window BACK to the pre-resize point size so window/capture aspect
            //       agree again, then
            //   (b) REBUILD an old-size capturer + encoder (like startLiveComponents, at the OLD
            //       pixel size) and start it so frames resume.
            // If the rollback/restart itself fails, log + leave the (dead) refs cleared rather than
            // crash. Do NOT send an ack (no new-size stream came up).
            await rollBackWindow(toPoints: preResizePoints, watcher: watcher, epoch: epoch)
            await restartOldSizeCapture(points: preResizePoints, epoch: epoch,
                                        deadCapturer: newCapturer, deadEncoder: newEncoder)
            return
        }
        // Identity guard (symmetric to `startLiveComponents`): a superseding teardown/start during
        // `newCapturer.start` means our refs are no longer installed — tear down the orphan stream
        // and do NOT ack (a newer owner is live).
        guard self.capturer === newCapturer else {
            dbg("resize superseded during capturer.start — tearing down orphaned new stream")
            await newCapturer.stop()
            return
        }

        // d. Ack LAST — after the new stream is up. The ack may race slightly ahead of the first
        //    new-size IDR (start() does not await the first frame); this is SAFE because the
        //    client adopts the new size only when a matching decoded buffer arrives (frame-gated
        //    `noteDecoded` / `ResizeAdoption`), not on ack receipt.
        //
        // ⚠️ KNOWN RESIDUAL (re-ack-lies edge, FIX #5): the SM commits captureWidth/captureHeight/
        // lastResizeEpoch SYNCHRONOUSLY before this effect runs (VideoSessionLogic.swift ~L152). On
        // a failed-then-rolled-back resize above we restore the WINDOW + capture to the OLD size but
        // we do NOT correct the SM, so the SM still reports the REQUESTED size; a duplicate-hello
        // re-ack would then echo the requested (not actual) size in `helloAck`. We deliberately do
        // NOT touch the SM here — a blind SM rollback risks an epoch/size desync that is riskier
        // than this cosmetic re-ack edge (a real resize re-issues anyway). Left as a documented
        // residual to revisit with the Mac Studio in the loop (failure paths aren't headless-exercisable).
        await apply(.sendControl(.resizeAck(captureWidth: achievedWidth, captureHeight: achievedHeight, epoch: epoch)))
    }

    /// FIX #5 rollback: re-issue the AX window resize back to `points` so the (still-running OR
    /// about-to-be-rebuilt) old-size capture matches the window aspect again after a resize abort
    /// that happened AFTER the window was already moved. Best-effort: a failed roll-back is logged,
    /// never fatal (a beachballing/fixed-size app may refuse — the next successful resize corrects it).
    private func rollBackWindow(toPoints points: VideoSize, watcher: WindowGeometryWatcher, epoch: UInt32) async {
        let rolled = await MainActor.run { watcher.resizeWindow(toPoints: points) }
        if rolled == nil {
            log.error("resize rollback: AX window resize-back to \(points.width)x\(points.height)pt failed")
            dbg("resizeCapture epoch=\(epoch) — AX rollback FAILED (window left at requested size)")
        } else {
            dbg("resizeCapture epoch=\(epoch) — AX window rolled back to \(Int(points.width))x\(Int(points.height))pt")
        }
    }

    /// FIX #5 recovery: after a capturer-start abort left a DEAD capturer (old stopped, new failed
    /// to start), rebuild an OLD-size capturer + encoder (the same wiring as ``startLiveComponents``,
    /// at the pre-resize pixel size) and start it so frames RESUME — `requestIDR`/heartbeat cannot
    /// revive a stream whose `start()` threw. Reuses the EXISTING geometry/cursor/injector (those
    /// were never torn down by the resize). If the rebuild's own `start()` throws, clear the dead
    /// refs + log rather than leave a dead capturer installed (no crash). Symmetric to the
    /// startLiveComponents post-await identity guard: if a superseding owner installed its own
    /// capturer while we were suspended, tear down our orphan and leave theirs.
    private func restartOldSizeCapture(points: VideoSize, epoch: UInt32,
                                       deadCapturer: WindowCapturer, deadEncoder: VideoEncoder) async {
        // FIX #5 (review + confirm-dry audit): we reached here THROUGH `rollBackWindow`'s
        // `await MainActor.run` suspension, across which EITHER (a) a `bye`/reap/`stop()` teardown
        // ran on a separate Task (→ mediaFlowing false, refs nil'd) OR (b) a NEWER resize installed
        // its OWN live capturer/encoder (→ mediaFlowing STAYS true). A bare mediaFlowing check
        // catches (a) but NOT (b). So also require the dead refs we are recovering to STILL be the
        // installed ones AND this epoch to still be newest — mirroring the install-site FIX #1/#8
        // guard. If a newer owner is live, bail: clearing/rebuilding would orphan ITS SCStream (the
        // F2 streaming-but-dead leak). The failed dead refs are locals that deinit cleanly on return
        // (the failed capturer has no SCStream; deadEncoder.deinit invalidates its VTCompressionSessions).
        guard stateMachine.mediaFlowing,
              capturer === deadCapturer, encoder === deadEncoder,
              epoch >= stateMachine.lastResizeEpoch else {
            dbg("resizeCapture epoch=\(epoch) — superseded/torn-down during rollback; skip recovery restart")
            return
        }
        // Drop the dead refs the failed resize left installed before rebuilding.
        self.encoder = nil
        self.capturer = nil
        let pixelWidth = max(1, Int((points.width * captureScale).rounded()))
        let pixelHeight = max(1, Int((points.height * captureScale).rounded()))

        let rebuiltEncoder = VideoEncoder(width: pixelWidth, height: pixelHeight, bitrate: bitrate, outputHandler: makeEncoderOutputHandler())
        do {
            try rebuiltEncoder.createLiveSession()
            try rebuiltEncoder.createCrispSession()
        } catch {
            log.error("resize recovery: old-size encoder rebuild failed: \(String(describing: error)) — capture stays down")
            dbg("resizeCapture epoch=\(epoch) — old-size encoder rebuild FAILED; capture remains down")
            return
        }

        let logCallback = log
        let rebuiltCapturer = WindowCapturer { pixelBuffer, pts, forceKeyframe in
            do {
                try rebuiltEncoder.encodeLive(pixelBuffer: pixelBuffer, presentationTime: pts, forceKeyframe: forceKeyframe)
            } catch {
                logCallback.error("live encode (post-resize recovery) failed: \(String(describing: error))")
            }
        }
        self.encoder = rebuiltEncoder
        self.capturer = rebuiltCapturer
        let captureWindow = window
        do {
            nonisolated(unsafe) let w = captureWindow
            try await rebuiltCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg("resizeCapture epoch=\(epoch) — recovered: old-size capture restarted (\(pixelWidth)x\(pixelHeight) px)")
        } catch {
            log.error("resize recovery: old-size capturer start failed: \(String(describing: error)) — capture stays down")
            dbg("resizeCapture epoch=\(epoch) — old-size capturer restart FAILED; capture remains down")
            if capturer === rebuiltCapturer { capturer = nil }
            if encoder === rebuiltEncoder { encoder = nil }
            return
        }
        // Identity + liveness guard: a superseding teardown/start during the rebuilt `start` means
        // our refs are no longer installed OR the session was torn down — tear down the orphan stream
        // and clear if still ours. `mediaFlowing` is the authoritative "session still alive" signal
        // (a teardown sets the SM to .listening/.stopped before niling refs).
        guard capturer === rebuiltCapturer, stateMachine.mediaFlowing else {
            dbg("resizeCapture epoch=\(epoch) — recovery superseded/torn-down during start; tearing down orphan")
            await rebuiltCapturer.stop()
            if capturer === rebuiltCapturer { capturer = nil; encoder = nil }
            return
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
        let encoder = VideoEncoder(width: pixelWidth, height: pixelHeight, bitrate: bitrate, outputHandler: makeEncoderOutputHandler())
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
            // ⚠️ Suspension point (symmetric to F2's `teardownLiveComponents`). `capturer.start`
            // brings up the SCStream (`stream.startCapture()` + `addStreamOutput`/`delegate:self`),
            // and the SCStream framework then RETAINS `capturer` for as long as the stream runs.
            // A `bye`/`hello`/`bye` storm can run a teardown (and even a newer start) WHILE we are
            // suspended here: that teardown snapshots our fresh refs, stops them (no-op — the
            // stream/timers are not up yet), and nils them. If we then blindly resume and start
            // the SCStream/timers + leave our refs installed, we (a) clobber the actor's current
            // refs and (b) orphan THIS stream + its timers (frames are dropped by the mediaFlowing
            // gate, but the SCStream + VTCompressionSession + drag/cursor timers leak until process
            // exit). So guard the post-await start on identity: only proceed if `self.capturer` is
            // still the instance THIS invocation installed.
            try await capturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg("SCStream capture started (\(pixelWidth)x\(pixelHeight) px @\(captureScale)×, \(width)x\(height) pt) — awaiting frames")
        } catch {
            log.error("capturer start failed: \(String(describing: error))")
            dbg("SCStream capture START FAILED: \(String(describing: error))")
        }

        // Identity guard (symmetric to teardown's compare-and-clear). If a superseding
        // teardown/start ran while we were suspended in `capturer.start`, `self.capturer`
        // no longer points at the instance we installed. In that case DON'T start the
        // geometry/cursor timers and DON'T leave this now-live SCStream running: stop the
        // local instances we just created and return WITHOUT touching the actor's current
        // refs (the superseding teardown already nil'd ours; a newer start owns whatever is
        // installed now). All 5 component types are `final class`, so `===` is valid.
        guard self.capturer === capturer else {
            dbg("startLiveComponents superseded during capturer.start — tearing down orphaned instances")
            await capturer.stop()      // async: stops the SCStream we just brought up (stream = nil)
            cursorSampler.stop()
            geometryWatcher.stop()
            // `encoder`/`injector` are inert until the (now-skipped) capture/input path drives
            // them; releasing the locals lets them deinit (VideoEncoder.deinit invalidates its
            // VTCompressionSessions). Do not clear actor refs — a superseding start owns them.
            return
        }

        geometryWatcher.startDragPolling()
        cursorSampler.start()
        log.info("live capture/encode/geometry/cursor running")
    }

    private func teardownLiveComponents() async {
        // Compare-and-clear (race guard, F2). `#8` made `bye → .listening` re-armable, so a
        // bye's stopCapture (this teardown) can now overlap a reconnect hello's startCapture:
        // `await capturer?.stop()` (a slow SCStream stopCapture) is a suspension point across
        // which a newer `startLiveComponents` can install FRESH capturer/encoder/etc. Snapshot
        // the instances this teardown owns at entry, stop the slow source, then clear each ref
        // ONLY if it is still the one we snapshotted — a stale teardown that resumes after a
        // newer start must not nil the new components (which would wedge the actor
        // streaming-but-dead: mediaFlowing true per SM, but every live component nil → no
        // frames ever). The synchronous `stop()`s are safe to call on the snapshots; only the
        // ref-clearing is gated on identity.
        let staleCapturer = capturer
        let staleEncoder = encoder
        let staleCursorSampler = cursorSampler
        let staleGeometryWatcher = geometryWatcher
        let staleInjector = injector

        await staleCapturer?.stop()
        staleCursorSampler?.stop()
        staleGeometryWatcher?.stop()

        if capturer === staleCapturer { capturer = nil }
        if encoder === staleEncoder { encoder = nil }
        if cursorSampler === staleCursorSampler { cursorSampler = nil }
        if geometryWatcher === staleGeometryWatcher { geometryWatcher = nil }
        if injector === staleInjector { injector = nil }
    }

    // MARK: Component callbacks

    /// Builds the encoder's `@Sendable` output handler (FIX C). The VT serial callback APPENDS the
    /// encoded frame to the ordered FIFO and signals the single consumer — it does NOT spawn a
    /// per-frame `Task` (which would race onto the actor and scramble frameID/streamSeq). Snapshots
    /// the actor's queue + wakeup once at build time (both created in ``start()`` before any
    /// encoder, and stable across resize), so the hot callback never hops back to the actor just to
    /// enqueue. A frame that arrives after teardown (`encodedWakeup.finish()`) is dropped by the
    /// `.bufferingNewest(1)` stream being finished — symmetric to the old `mediaFlowing` drop.
    private func makeEncoderOutputHandler() -> VideoEncoder.OutputHandler {
        let queue = encodedQueue
        let wakeup = encodedWakeup
        return { avcc, keyframe, mode in
            // Enqueue THEN signal (no lost wakeup): the consumer always drains after the last append.
            queue?.append(EncodedFrameQueue.Frame(avcc: avcc, keyframe: keyframe, crisp: mode == .crisp))
            wakeup?.yield()
        }
    }

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

/// Lock-protected FIFO of inbound datagrams feeding the host's coalescing consumer. The
/// transport's serial receive queue APPENDS (synchronously, no actor hop — so arrival order is
/// carried end-to-end); the single consumer task DRAINS the whole backlog per wakeup so the
/// actor can collapse pointer-motion runs (``InputMotionCoalescer``). Replaces the prior
/// unbounded `AsyncStream` of datagrams, whose strictly-serial per-event drain (three
/// WindowServer round-trips per motion event) let a motion flood accrue multi-second lag.
private final class InboundQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(VideoChannel, Data)] = []

    /// Append one datagram. Called on the transport's serial receive queue; O(1), never blocks.
    func append(_ channel: VideoChannel, _ data: Data) {
        lock.lock(); items.append((channel, data)); lock.unlock()
    }

    /// Atomically take and clear the whole backlog (arrival order). An empty result means a
    /// coalesced wakeup whose datagrams an earlier drain already consumed.
    func drainAll() -> [(VideoChannel, Data)] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}

/// Lock-protected FIFO of ENCODED frames feeding the host's single ordered consumer (FIX C). The
/// encoder's VT output callback fires in STRICT encode order on a serial queue and APPENDS here
/// synchronously (no actor hop — so encode order is carried end-to-end); the single consumer task
/// drains the backlog IN ORDER and awaits `onEncodedFrame` one at a time, so the packetizer
/// assigns frameID/streamSeq in encode order. Replaces the prior `Task`-per-frame fan-out, which
/// gave no FIFO guarantee across separately-created Tasks targeting the actor (frame N+1 could be
/// processed before frame N → a delta packetized before its IDR).
final class EncodedFrameQueue: @unchecked Sendable {
    /// One encoded frame: the AVCC bytes + keyframe/crisp flags the packetizer needs.
    struct Frame: Sendable {
        let avcc: Data
        let keyframe: Bool
        let crisp: Bool
    }

    private let lock = NSLock()
    private var items: [Frame] = []

    init() {}

    /// Append one encoded frame. Called on the VT serial output queue; O(1), never blocks.
    func append(_ frame: Frame) {
        lock.lock(); items.append(frame); lock.unlock()
    }

    /// Atomically take and clear the whole backlog (encode order preserved). An empty result means
    /// a coalesced wakeup whose frames an earlier drain already consumed.
    func drainAll() -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}
#endif
