#if canImport(VideoToolbox) && canImport(Metal) && canImport(QuartzCore)
import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import QuartzCore
import OSLog
import RworkVideoProtocol

/// The client-side session orchestrator for the GUI video path (PATH 2 / Phase 4) —
/// the exact mirror of `RworkVideoHost.RworkVideoHostSession`.
///
/// It wires the previously-disconnected client islands into a working pipeline:
///
/// ```
/// UDP media datagrams ─▶ ReceivedDatagramRouter
///   ├─ control  ─▶ VideoClientStateMachine (hello/helloAck/bye)
///   ├─ video    ─▶ FrameReassembler ─▶ FECScheme ─▶ VideoDecoder (VTDecompressionSession)
///   │                                            ─▶ FramePacer ─▶ MetalVideoRenderer
///   └─ geometry ─▶ window move/resize/title (drives the host view layout)
/// UDP cursor datagrams (own socket) ─▶ CursorChannelMessage ─▶ ClientCursorCompositor
/// view input (mouse/key/scroll/text) ─▶ InputEventEncoder ─▶ UDP input datagrams (→ host)
/// dropped frames ─▶ RecoveryPolicy ─▶ requestLTRRefresh / requestIDR (→ host)
/// ```
///
/// ⚠️ **HANG-SAFETY:** the live `start()` path brings up a `VTDecompressionSession`,
/// the Metal renderer, the `CVDisplayLink`/`CADisplayLink`, and UDP sockets — all of
/// which require a window-server / TCC session and HANG headlessly. This actor is
/// COMPILED + reviewed and only driven from a real GUI client app. Its PURE decision
/// logic (``VideoClientStateMachine`` / ``ReceivedDatagramRouter`` / ``VideoScaleMath``
/// / ``InputEventEncoder``) lives in `VideoClientSessionLogic.swift` and IS unit-tested.
public actor RworkVideoClientSession {
    private let log = Logger(subsystem: "rwork.video.client", category: "RworkVideoClientSession")

    /// Opt-in stderr diagnostics (`RWORK_VIDEO_DEBUG=1`) — the client counterpart to the host's,
    /// so `scripts/check-video.sh` can see whether media datagrams arrive, frames reassemble, and
    /// decode succeeds (OSLog `.info` is not persisted; a white client window is otherwise opaque).
    /// No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["RWORK_VIDEO_DEBUG"] != nil
    /// Redundancy for the critical RELEASE edge. Over plain UDP a dropped `mouseUp` strands the
    /// target app mid-selection; we send the up a few times back-to-back so a single loss can't.
    /// Genuinely idempotent on the host: button-balance posts the FIRST up (the one that releases
    /// the held button) and SUPPRESSES the duplicates, so the target app never sees a spurious
    /// extra `*MouseUp`.
    private static let redundantUpCount = 3
    private var dbgMediaCount = 0
    private var dbgDecodeCount = 0
    private var dbgPointerCount = 0
    nonisolated private func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("Rwork[video.client]: \(message())\n".utf8))
    }

    /// Diagnostics for the input-coordinate path (`RWORK_VIDEO_DEBUG`): prints the view
    /// point, the on-screen layer size, the aspect-fit NATIVE size, the resulting
    /// displayed-video sub-rect, and the normalised 0..1 the host receives — so a "toạ độ
    /// sai" / "không fill" report can be ROOT-CAUSED from the log instead of guessed
    /// (does the video fill the pane? is the native size capture-pinned or geometry-
    /// corrupted? does the click land where the user aimed?). Moves are sampled 1-in-30;
    /// every button-down / drag / up is logged.
    private func dbgPointer(_ kind: String, _ viewPoint: VideoPoint) {
        guard Self.debugStderr else { return }
        dbgPointerCount += 1
        if kind == "move", dbgPointerCount % 30 != 0 { return }
        let r = AspectFit.displayedVideoRect(viewSize: layerSize, videoNativeSize: decodedSize, mode: contentMode)
        let n = InputEventEncoder.normalize(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: decodedSize, zoom: zoom, pan: pan, mode: contentMode)
        dbg("\(kind) view=(\(Int(viewPoint.x)),\(Int(viewPoint.y))) "
            + "layer=\(Int(layerSize.width))x\(Int(layerSize.height)) "
            + "native=\(Int(decodedSize.width))x\(Int(decodedSize.height)) "
            + "mode=\(contentMode) zoom=\(String(format: "%.2f", zoom)) "
            + "fitRect=(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.size.width))x\(Int(r.size.height))) "
            + "→ norm=(\(String(format: "%.3f", n.x)),\(String(format: "%.3f", n.y)))")
    }

    /// GUI hand-off seams. The renderer / cursor compositor / display link are all
    /// `@MainActor`-isolated (they touch `CAMetalLayer` / `CALayer` / a view's
    /// display link), so the actor never holds them directly; it calls these
    /// `@Sendable` closures. The decoded NV12 frame is submitted to the pacer the
    /// `VideoWindowPipeline` owns (most-recent-wins), which renders it at the display
    /// link's vsync. This keeps the orchestrator pure-actor and Sendable-clean while
    /// the GUI objects stay main-thread-confined. `VideoWindowPipeline` provides them.
    public struct GUIHooks: Sendable {
        /// Hand a freshly decoded NV12 buffer to the (pipeline-owned) frame pacer.
        public var submitDecodedFrame: @Sendable (CVImageBuffer) -> Void
        /// Place the cursor overlay through the aspect-fit + zoom/pan render transform
        /// (the same geometry the input encoder inverts) so the overlay tracks where a
        /// click actually lands.
        public var applyCursor: @Sendable (CursorUpdate, CursorPlacement) -> Void
        /// Register a cursor shape bitmap for its shapeID (shipped rarely, OOB).
        public var registerCursorShape: @Sendable (CGImage, VideoSize, UInt16) -> Void
        public init(
            submitDecodedFrame: @escaping @Sendable (CVImageBuffer) -> Void,
            applyCursor: @escaping @Sendable (CursorUpdate, CursorPlacement) -> Void,
            registerCursorShape: @escaping @Sendable (CGImage, VideoSize, UInt16) -> Void
        ) {
            self.submitDecodedFrame = submitDecodedFrame
            self.applyCursor = applyCursor
            self.registerCursorShape = registerCursorShape
        }
    }

    /// The display geometry the cursor overlay needs to place itself through the same
    /// render transform the video uses (aspect-fit + zoom/pan). Passed across the
    /// main-actor hop so the compositor never reaches back into the actor for state.
    public struct CursorPlacement: Sendable {
        public var viewSize: VideoSize
        public var videoNativeSize: VideoSize
        public var zoom: Double
        public var pan: VideoPoint
        public var mode: VideoContentMode
        public init(viewSize: VideoSize, videoNativeSize: VideoSize, zoom: Double, pan: VideoPoint, mode: VideoContentMode = .fit) {
            self.viewSize = viewSize
            self.videoNativeSize = videoNativeSize
            self.zoom = zoom
            self.pan = pan
            self.mode = mode
        }
    }

    private let transport: any VideoClientTransport
    private let gui: GUIHooks
    private let router = ReceivedDatagramRouter()
    private let recoveryPolicy: RecoveryPolicy

    private var stateMachine: VideoClientStateMachine
    private var reassembler: FrameReassembler
    private var inputEncoder = InputEventEncoder()

    /// The decoder is created on an accepted helloAck (never in a test).
    private var decoder: VideoDecoder?

    /// Decoded-frame geometry, used for the cursor placement scale. The capture size
    /// is the host's window-point size; the layer size is the on-screen point size.
    private var decodedSize: VideoSize = VideoSize(width: 0, height: 0)
    private var layerSize: VideoSize = VideoSize(width: 0, height: 0)
    /// The current VNC-style zoom (≥1) + normalized pan applied by the renderer (iOS
    /// pinch/pan; always (1, .zero) on macOS). Stored here so the input encoder inverts
    /// the EXACT SAME transform the renderer applies — otherwise a click while zoomed
    /// would land at the un-zoomed source position. Kept in lock-step with the renderer
    /// via ``setZoom(_:pan:)`` (the pipeline calls both on every gesture).
    private var zoom: Double = 1
    private var pan: VideoPoint = VideoPoint(x: 0, y: 0)
    /// `.fit` (letterbox — whole window, bars) or `.fill` (cover — no bars, edges cropped).
    /// Both preserve aspect; the user toggles via the pane's fill button. Stored here so the
    /// input encoder + cursor overlay invert the SAME displayed rect the renderer draws into
    /// (kept in lock-step with the renderer via ``setContentMode(_:)`` — the pipeline calls
    /// both). Default `.fit`.
    private var contentMode: VideoContentMode = .fit
    /// The most recent host cursor position, re-applied whenever the scale changes so
    /// a layout/resize re-places the overlay without waiting for the next cursor packet.
    private var lastCursorUpdate: CursorUpdate?
    /// FIX B cursor-shape self-heal: decides when to re-request a shape bitmap the client is
    /// missing (its one-shot shipment was lost / over-MTU). A position update referencing an
    /// unknown shapeID triggers a `requestCursorShape` on the recovery channel; the decision is
    /// debounced per id so the ~120 Hz position stream cannot flood the channel. Pure type.
    private var shapeRequests = CursorShapeRequestTracker()

    /// The self-owned keepalive timer (NOT the 33 ms `motionPump` in `VideoWindowPipeline` —
    /// that is far too fast + main-actor-bound). A separate, slow (5 s,
    /// ``KeepaliveTiming/keepaliveInterval``) actor-owned `Task` that sends a zero-body
    /// `keepalive` on the control channel while streaming, so the host's idle-timeout reaper can
    /// tell a quiet-but-alive client from a crashed one (CONCURRENCY-HOST-1 crash-without-bye).
    /// Cancelled in ``stop()``. ⚠️ Timer firing is [MS-confirm] (real-clock glue); the reap
    /// DECISION it feeds is covered by `IdleReapDeciderTests`.
    private var keepaliveTask: Task<Void, Never>?
    /// Client-side debounce coalescing a burst of layout callbacks (one per drag frame) to the
    /// SETTLED surface size — one `resizeRequest` per settled size, monotonic epoch.
    private var resizeDebounce = ResizeDebounce()
    /// Wall-clock time the layer size last actually CHANGED (the debounce settle clock; the
    /// actor measures `elapsedSinceLastChange`, the ``ResizeDebounce`` discipline).
    private var lastSizeChangeTime = Date.distantPast
    /// The last layer size seen, so a no-op layout pass (same size) does not reset the settle
    /// clock (which would prevent the size from ever settling under repeated identical passes).
    private var lastSeenSize: VideoSize?
    /// The capture size the host acked for an in-session resize, staged until a decoded
    /// `CVPixelBuffer` actually arrives at it (frame-gated adoption). `nil` ⇒ none pending.
    private var pendingCaptureSize: VideoSize?
    /// The pixel dims of the most recently decoded frame — the MAGNITUDE baseline for
    /// frame-gated resize adoption (``ResizeAdoption/shouldAdopt(pending:decoded:previousDecoded:)``).
    /// A genuinely new-size frame is the first whose pixel dims differ from the steady prior size;
    /// an in-flight old-size frame matches the baseline and is rejected. Gated-path-only.
    private var lastDecodedPixelSize: VideoSize?
    /// One-shot settle timer for the resize debounce. ``maybeRequestResize(for:)`` is only ever
    /// driven by event-based layout callbacks, and the FINAL drag frame re-arms the settle clock
    /// with ~0 elapsed — so without this timer a settled size would NEVER be requested (no further
    /// layout pass arrives to re-evaluate it). Armed whenever a change has not yet settled;
    /// cancelled + rescheduled on each change (coalesce → one request per settled size); cancelled
    /// on ``stop()``. ⚠️ Timer firing is [MS-confirm] (real-clock glue; the pure debounce decision
    /// is covered by `ResizeDebounceTests`).
    private var resizeSettleTask: Task<Void, Never>?

    /// Recovery bookkeeping: tracks the time of the FIRST outstanding LTR-refresh
    /// request in the current recovery episode (host time seconds), cleared once a
    /// keyframe decodes. Polled by ``shouldEscalateToIDR()``. The "first request"
    /// (not "last request") semantics are the BUG-H fix: under sustained loss the old
    /// code reset this on EVERY dropped frame, so 2·RTT never elapsed and the
    /// guaranteed-recovery forced IDR never fired (``LTREscalationTracker``).
    private var escalation = LTREscalationTracker()
    /// Smoothed RTT estimate gating the 2·RTT IDR-escalation timeout. 50 ms default
    /// until ``updateRTTEstimate(_:)`` feeds a measurement.
    private var rttEstimate: TimeInterval = 0.05

    /// - Parameters:
    ///   - requestedWindowID: the host CGWindowID to remote.
    ///   - viewport: the client surface size sent in the hello.
    ///   - transport: the UDP transport (production: ``NWVideoClientTransport``).
    ///   - gui: the main-actor GUI hand-off seams (submit-frame / cursor / shape).
    ///   - fec: FEC scheme matching the host (default 20% XOR parity).
    public init(
        requestedWindowID: UInt32,
        viewport: VideoSize,
        transport: any VideoClientTransport,
        gui: GUIHooks,
        fec: FECScheme? = XORParityFEC(),
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy()
    ) {
        self.transport = transport
        self.gui = gui
        self.recoveryPolicy = recoveryPolicy
        self.stateMachine = VideoClientStateMachine(requestedWindowID: requestedWindowID, viewport: viewport)
        self.reassembler = FrameReassembler(fec: fec)
        self.layerSize = viewport
    }

    // MARK: Lifecycle

    /// Connects the UDP flows, sends the `hello`, and starts receiving. The decode
    /// pipeline (decoder + display link) starts once the host accepts.
    public func start() async throws {
        try await transport.start { [weak self] channel, data in
            guard let self else { return }
            Task { await self.receiveMedia(channel: channel, data: data) }
        } onCursor: { [weak self] data in
            guard let self else { return }
            Task { await self.receiveCursor(data) }
        }
        for effect in stateMachine.start() { await apply(effect) }
        startKeepalive()
        log.info("video client session started; hello sent")
    }

    /// Sends a best-effort `bye`, tears the pipeline + sockets down.
    public func stop() async {
        keepaliveTask?.cancel(); keepaliveTask = nil
        resizeSettleTask?.cancel(); resizeSettleTask = nil
        for effect in stateMachine.stop() { await apply(effect) }
        await transport.stop()
        log.info("video client session stopped")
    }

    // MARK: Liveness keepalive (CONCURRENCY-HOST-1 crash-without-bye)

    /// Starts the slow (``KeepaliveTiming/keepaliveInterval``, 5 s) actor-owned keepalive timer.
    /// Each tick sends a zero-body `keepalive` on the control channel WHILE STREAMING so the
    /// host's idle-timeout reaper can distinguish a quiet-but-alive client from a crashed one.
    /// Cancels any prior task (idempotent re-arm).
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(KeepaliveTiming.keepaliveInterval * 1_000_000_000))
                guard let self else { return }
                await self.sendKeepaliveIfStreaming()
            }
        }
    }

    /// Sends one `keepalive` iff the session is streaming (mirrors the resize-debounce gate). A
    /// pre-stream / torn-down session sends nothing — the heartbeat only matters while a flow is
    /// live. On mux the lane transport stamps the channelID automatically (no surface change).
    private func sendKeepaliveIfStreaming() {
        guard stateMachine.mediaFlowing else { return }
        transport.send(VideoControlMessage.keepalive.encode(), on: .control)
    }

    // MARK: Layout (called by the host view each layout pass)

    /// Updates the on-screen layer size (points). Recomputes the cursor scale and
    /// re-applies the last cursor update so the overlay tracks the new layout.
    public func setLayerSize(_ size: VideoSize) {
        layerSize = size
        dbg("setLayerSize → \(Int(size.width))x\(Int(size.height)) (native=\(Int(decodedSize.width))x\(Int(decodedSize.height)))")
        reapplyCursor()
        maybeRequestResize(for: size)
    }

    /// Drives the in-session resize debounce on a layer-size change (env-gated). A real size
    /// change re-arms the settle clock; once the size has been QUIET for the settle interval and
    /// differs enough from the last request, emit exactly one `resizeRequest(desired, epoch)` on
    /// the control channel (the existing `.sendControl` path). `noteRequested` is called ONLY
    /// after acting, per the ``ResizeDebounce`` query/mutator discipline. No-op when the session
    /// is not streaming.
    private func maybeRequestResize(for size: VideoSize) {
        guard stateMachine.mediaFlowing else { return }
        // A real change re-arms the settle clock; an identical pass does not (so a size that
        // stops changing can actually settle under repeated identical layout passes).
        if lastSeenSize != size {
            lastSeenSize = size
            lastSizeChangeTime = Date()
        }
        // Try to emit NOW; if not yet settled, arm the settle timer so the SETTLED size is still
        // requested even when the final drag frame re-armed the clock and no further layout
        // callback arrives to re-evaluate it (the "resizeRequest never fires on a clean drag-end"
        // fix). Each change cancels + reschedules → exactly one request per settled size.
        if !attemptResizeEmit(size) { scheduleResizeSettle() }
    }

    /// Evaluates the debounce for `size` and emits a `resizeRequest` iff it has settled and
    /// changed enough. Returns whether it emitted. `noteRequested` is called ONLY after deciding
    /// to act, per the ``ResizeDebounce`` query/mutator discipline.
    @discardableResult
    private func attemptResizeEmit(_ size: VideoSize) -> Bool {
        let elapsed = Date().timeIntervalSince(lastSizeChangeTime)
        guard case .request(let settled) = resizeDebounce.decide(layerSize: size, elapsedSinceLastChange: elapsed) else {
            return false
        }
        let epoch = resizeDebounce.noteRequested(settled)
        dbg("resize: surface settled → resizeRequest \(Int(settled.width))x\(Int(settled.height)) epoch=\(epoch)")
        transport.send(VideoControlMessage.resizeRequest(desired: settled, epoch: epoch).encode(), on: .control)
        return true
    }

    /// Arms the one-shot settle timer: re-check `lastSeenSize` just after the surface should have
    /// gone quiet. Cancels any prior pending timer (coalesce). See ``resizeSettleTask``.
    private func scheduleResizeSettle() {
        resizeSettleTask?.cancel()
        let delay = resizeDebounce.settleInterval + 0.02   // re-check just after the surface goes quiet
        resizeSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.resizeSettleFired()
        }
    }

    /// The settle timer fired: emit the settled size if it is now quiet enough. Reschedules ONLY
    /// while genuinely still mid-burst (a change raced in during the sleep — which itself would
    /// have already rescheduled, so this is defensive); a `.hold` from a sub-`minDelta` wobble
    /// does NOT reschedule (elapsed has passed the settle interval), so this can never busy-loop.
    private func resizeSettleFired() {
        resizeSettleTask = nil
        guard stateMachine.mediaFlowing, let size = lastSeenSize else { return }
        if !attemptResizeEmit(size), Date().timeIntervalSince(lastSizeChangeTime) < resizeDebounce.settleInterval {
            scheduleResizeSettle()
        }
    }

    /// Stores the current VNC-style zoom/pan (iOS pinch/pan gestures) so the input
    /// encoder inverts — and the cursor overlay re-applies — the EXACT SAME transform the
    /// renderer applies. The pipeline calls this in lock-step with `renderer.zoom/pan`.
    /// `zoom` is clamped ≥1; on macOS this stays (1, .zero).
    public func setZoom(_ zoom: Double, pan: VideoPoint) {
        self.zoom = max(1, zoom)
        self.pan = pan
        reapplyCursor()
    }

    /// Stores the fit/fill content mode so the input encoder + cursor overlay invert the
    /// EXACT SAME displayed rect the renderer draws into. The pipeline calls this in
    /// lock-step with `renderer.contentMode` (both must move together or a click in `.fill`
    /// would map against the `.fit` letterbox rect). Re-places the cursor for the new rect.
    public func setContentMode(_ mode: VideoContentMode) {
        contentMode = mode
        dbg("setContentMode → \(mode)")
        reapplyCursor()
    }

    /// The current videoScale = client-view-points per host-window-point. The host
    /// view feeds this to ``ClientCursorCompositor`` so the cursor lands correctly.
    public var videoScale: Double {
        VideoScaleMath.videoScale(layerSize: layerSize, decodedSize: decodedSize)
    }

    // MARK: Inbound media routing

    private func receiveMedia(channel: VideoChannel, data: Data) async {
        dbgMediaCount += 1
        if dbgMediaCount == 1 || dbgMediaCount % 30 == 0 {
            dbg("media datagram #\(dbgMediaCount) received (channel=\(channel), \(data.count)B, mediaFlowing=\(stateMachine.mediaFlowing))")
        }
        switch router.route(channel: channel, data: data, mediaFlowing: stateMachine.mediaFlowing) {
        case .control(let message):
            for effect in stateMachine.handleControl(message) { await apply(effect) }
        case .videoFragment(let fragment):
            ingestVideo(fragment)
        case .geometry(let message):
            applyGeometry(message)
        case .drop(let reason):
            log.error("dropping media datagram: \(reason)")
            dbg("media datagram DROPPED: \(reason)")
        case .ignore:
            break
        }
    }

    private func ingestVideo(_ fragment: FrameFragment) {
        let result = reassembler.ingest(fragment)
        if case .completed(let frame) = result {
            dbg("frame reassembled (keyframe=\(frame.keyframe)) → decoding")
            decode(frame)
        }
        // Drain any frames the reassembler declared unrecoverably lost and signal
        // recovery. First loss → prefer an LTR refresh; if an LTR refresh is already in
        // flight and no decodable frame has cleared it within 2·RTT, ESCALATE to a
        // forced IDR (doc 17 §3.6). The escalation is driven right here off the
        // loss-detection path — there is no separate timer.
        while let lost = reassembler.nextDroppedFrame() {
            if shouldEscalateToIDR() {
                requestIDR()
                // Re-anchor the escalation clock so the NEXT dropped frame in this same loss
                // episode does not re-fire the escalation (and resend a redundant requestIDR)
                // until another 2·RTT elapses (F7). Ordinary requestRecovery still must NOT
                // move the first-request clock (BUG-H) — only a fired escalation re-arms it.
                escalation.noteEscalated(now: FramePacer.currentHostTimeSeconds())
            } else {
                requestRecovery(lostFrameID: lost)
            }
        }
    }

    /// Whether a forced-IDR escalation is due: an LTR refresh is already outstanding
    /// (the recovery episode is armed, not yet cleared by a keyframe) and at least
    /// 2·RTT has elapsed since the FIRST request of the episode
    /// (``LTREscalationTracker/shouldEscalate(now:rtt:policy:)``).
    private func shouldEscalateToIDR() -> Bool {
        escalation.shouldEscalate(now: FramePacer.currentHostTimeSeconds(), rtt: rttEstimate, policy: recoveryPolicy)
    }

    /// Updates the smoothed RTT estimate that gates the IDR-escalation timeout. Fed by
    /// the transport / control round-trip when a measurement is available; until then
    /// the conservative 50 ms default holds. Exposed for the GUI layer to drive.
    public func updateRTTEstimate(_ rtt: TimeInterval) {
        guard rtt > 0 else { return }
        // Simple EWMA so a single spike does not whipsaw the escalation timeout.
        rttEstimate = rttEstimate * 0.75 + rtt * 0.25
    }

    private func decode(_ frame: ReassembledFrame) {
        guard let decoder else { return }
        do {
            // The decoded NV12 size becomes the cursor-scale denominator.
            updateDecodedSize(from: frame)
            try decoder.decode(frame)
            dbgDecodeCount += 1
            if dbgDecodeCount == 1 || dbgDecodeCount % 15 == 0 {
                dbg("DECODED frame #\(dbgDecodeCount) (keyframe=\(frame.keyframe)) → submitted to pacer/render")
            }
            // A successful keyframe ends the recovery episode and disarms the clock,
            // so the next loss starts a fresh 2·RTT escalation window.
            if frame.keyframe { escalation.keyframeDecoded() }
        } catch VideoDecoderError.awaitingKeyframe {
            // A delta arrived before the first IDR — drop it and ask for a keyframe.
            dbg("decode: awaiting keyframe (delta dropped) → requesting IDR")
            requestIDR()
        } catch {
            log.error("decode failed: \(String(describing: error))")
            dbg("DECODE FAILED: \(String(describing: error))")
            // VIDEO-CLIENT-1: a hard decode failure (corrupt-but-complete AVCC / decoder
            // malfunction — e.g. an FEC mis-recovery that passes the length check, or
            // VTDecompressionSession returning kVTVideoDecoderMalfunctionErr) is NOT surfaced by
            // the fragment-level reassembler — it reported the frame `.completed`, so the
            // loss-driven recovery never armed. Re-anchor the stream by requesting an IDR, exactly
            // like the `awaitingKeyframe` path above; otherwise the pacer re-presents the last good
            // frame indefinitely (especially once the host window goes static and stops producing
            // frames). Idempotent on the host — the escalation tracker dedups duplicate requests.
            //
            // FIX #3: a HARD failure can leave the VTDecompressionSession itself in a dead
            // state. On a fixed capture size the forced recovery IDR carries
            // BYTE-IDENTICAL VPS/SPS/PPS → needsReconfigure=false → the
            // SAME malfunctioning session would be reused forever (pane frozen permanently).
            // Force a session rebuild here so the next keyframe — even byte-identical — re-runs
            // configure() against a FRESH session. Done BEFORE requestIDR() so the rebuild is in
            // place by the time the recovery keyframe arrives. (The healthy heartbeat-IDR reuse
            // path / BUG-I is untouched: only a decode FAILURE clears the cached parameter sets.)
            decoder.invalidateSession()
            requestIDR()
        }
    }

    private func updateDecodedSize(from frame: ReassembledFrame) {
        // The capture size negotiated in the helloAck is the authoritative frame size
        // (host window points). Keep it; the decoded CVPixelBuffer matches it.
        if decodedSize.width == 0 {
            decodedSize = stateMachine.captureSize
            reapplyCursor()
        }
    }

    /// Called from the decoder's frame handler with the ACTUAL decoded `CVPixelBuffer`
    /// dimensions (pixels). Frame-gated in-session-resize adoption: when a host resize has been
    /// acked (`pendingCaptureSize` set) and a decoded frame finally arrives AT that size, adopt
    /// it as the aspect-fit denominator (`decodedSize`) and re-place the cursor for the new
    /// geometry. We compare against the BUFFER dims (not the ack) so an in-flight OLD-size frame
    /// that arrives after the ack does NOT trip the adoption early (it would briefly mis-scale).
    ///
    /// `decodedSize` is in the SAME unit family the aspect-fit math uses (ratios are
    /// scale-invariant), and the host clamps the achieved size to the wire UInt16 the ack
    /// carries, so a per-axis rounding tolerance absorbs any capture-scale rounding between the
    /// acked points and the decoded pixels. No-op when nothing is ever pending (no in-session
    /// resize in flight).
    private func noteDecoded(width: Double, height: Double) {
        // Track the magnitude baseline FIRST (every decoded frame) so the next
        // frame can tell a genuinely-new size from an in-flight old-size one.
        let decoded = VideoSize(width: width, height: height)
        let previous = lastDecodedPixelSize
        lastDecodedPixelSize = decoded
        guard let pending = pendingCaptureSize else { return }
        // Adopt only when the decoded buffer is the genuinely-NEW size (aspect match AND a real
        // pixel-size change vs the prior frame) — an in-flight OLD-size frame queued behind the
        // ack must not trip adoption early. Pure decision: ``ResizeAdoption/shouldAdopt``.
        guard ResizeAdoption.shouldAdopt(pending: pending, decoded: decoded, previousDecoded: previous) else {
            dbg("resize: decoded \(Int(width))x\(Int(height)) not yet the new size — old-size frames still in flight (pending \(Int(pending.width))x\(Int(pending.height)))")
            return
        }
        decodedSize = pending
        pendingCaptureSize = nil
        dbg("resize: adopted decodedSize=\(Int(pending.width))x\(Int(pending.height)) (decoded buffer \(Int(width))x\(Int(height)) matched) → reapplying cursor")
        reapplyCursor()
    }

    private func applyGeometry(_ message: WindowGeometryMessage) {
        // ⚠️ The video-native size (the aspect-fit denominator `normalize` and the renderer
        // share) MUST equal the ACTUAL decoded frame size. That size is the capture size
        // negotiated in the helloAck and is FIXED for the session: the host configures the
        // SCStream once and does NOT reconfigure it when its window resizes — the frame
        // keeps arriving at the same dimensions (the resized window is scaled into the same
        // buffer). The renderer aspect-fits using `CVPixelBufferGetWidth/Height` (the fixed
        // frame), so if we re-derive `decodedSize` from a window-resize geometry message the
        // INPUT path letterboxes against a different aspect than the RENDER path → drag/click
        // land on the wrong pixel and the video stops matching the pane ("toạ độ sai / không
        // fill"). So geometry NEVER touches `decodedSize`; it stays capture-pinned. (Window
        // move/resize still drives the host-side cursor/input bounds — handled host-side in
        // `RworkVideoHostSession.onGeometry` — so absolute injection tracks the live window.)
        let kind: String
        switch message {
        case .move: kind = "move"
        case .resize: kind = "resize"
        case .bounds: kind = "bounds"
        case .title: kind = "title"
        }
        dbg("geometry \(kind) — native size kept capture-pinned at "
            + "\(Int(decodedSize.width))x\(Int(decodedSize.height)) (NOT re-derived from window geometry)")
    }

    // MARK: Inbound cursor (dedicated socket)

    private func receiveCursor(_ data: Data) async {
        guard stateMachine.mediaFlowing else { return }
        let message: CursorChannelMessage
        do { message = try CursorChannelMessage.decode(data) } catch {
            log.error("dropping malformed cursor datagram")
            return
        }
        switch message {
        case .update(let update):
            lastCursorUpdate = update
            // FIX B self-heal: a position update referencing a shapeID we never cached means its
            // one-shot bitmap was lost (or never fit one datagram). Re-request it on the recovery
            // channel (debounced per id) so the overlay can recover instead of staying wrong/
            // invisible for the whole session. The applyCursor below is unchanged — it simply
            // keeps the prior bitmap until the re-shipped one arrives.
            maybeRequestCursorShape(update.shapeID)
            applyCursor(update)
        case .shape(let shape):
            registerCursorShape(shape)
        }
    }

    /// Sends a `requestCursorShape(shapeID)` on the recovery channel iff the shape is missing and
    /// not recently requested (``CursorShapeRequestTracker``). No-op once the shape is cached.
    private func maybeRequestCursorShape(_ shapeID: UInt16) {
        guard shapeRequests.shouldRequest(shapeID: shapeID, now: FramePacer.currentHostTimeSeconds()) else { return }
        dbg("cursor shape \(shapeID) missing — requesting re-ship on recovery channel")
        transport.send(RecoveryMessage.requestCursorShape(shapeID: shapeID).encode(), on: .recovery)
    }

    private func applyCursor(_ update: CursorUpdate) {
        // Hand the overlay the full display geometry so it places itself through the same
        // aspect-fit + zoom/pan transform the input encoder inverts (hops to the main
        // actor inside the hook).
        let placement = CursorPlacement(viewSize: layerSize, videoNativeSize: decodedSize, zoom: zoom, pan: pan, mode: contentMode)
        gui.applyCursor(update, placement)
    }

    private func reapplyCursor() {
        if let update = lastCursorUpdate { applyCursor(update) }
    }

    private func registerCursorShape(_ shape: CursorShapeMessage) {
        // Decode the PNG bitmap to a CGImage and register it for its shapeID. CGImage
        // decode is cheap + safe (no window-server); only the layer wiring is GUI.
        guard let image = Self.decodePNG(shape.bitmap) else {
            log.error("failed to decode cursor shape \(shape.shapeID) PNG")
            return   // do NOT mark arrived — leave the id re-requestable so a decode failure self-heals (review).
        }
        // Mark arrived only AFTER a successful decode — the tracker then stops re-requesting.
        shapeRequests.noteShapeArrived(shape.shapeID)
        // Pass the LOGICAL point size so the overlay renders at the cursor's true size regardless of
        // the bitmap's pixel resolution (a Retina or MTU-downscaled bitmap is scaled to fit), rather
        // than rendering at the raw bitmap pixel dimensions (FIX B review).
        gui.registerCursorShape(image, shape.size, shape.shapeID)
        // Re-apply the last position so the newly-registered shape shows immediately.
        reapplyCursor()
    }

    // MARK: Outbound input (view → host)

    /// Forwards an already-built ``InputEvent`` to the host on the input channel.
    /// The view layer builds events via ``InputEventEncoder`` (normalised coords) and
    /// hands them here; sent fire-and-forget (UDP).
    public func sendInput(_ event: InputEvent) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(event.encode(), on: .input)
    }

    /// Convenience: normalise + send a pointer move in the layer's view space. The
    /// normalisation inverts the renderer's aspect-fit + zoom/pan transform using the
    /// negotiated `decodedSize` (host-window points) and the live `zoom`/`pan`, so a click
    /// lands on the host pixel under the cursor on screen.
    public func sendMouseMove(viewPoint: VideoPoint) {
        dbgPointer("move", viewPoint)
        sendInput(inputEncoder.mouseMove(viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: decodedSize, zoom: zoom, pan: pan, mode: contentMode))
    }

    public func sendMouseDown(button: MouseButton, viewPoint: VideoPoint, clickCount: UInt8, modifiers: InputModifiers) {
        dbgPointer("down", viewPoint)
        sendInput(inputEncoder.mouseDown(button: button, viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: decodedSize, clickCount: clickCount, modifiers: modifiers, zoom: zoom, pan: pan, mode: contentMode))
    }

    public func sendMouseUp(button: MouseButton, viewPoint: VideoPoint, clickCount: UInt8, modifiers: InputModifiers) {
        dbgPointer("up", viewPoint)
        // Build the up ONCE, then send it `redundantUpCount` times (fire-and-forget UDP): the
        // release edge is the one event whose loss is catastrophic (a stuck selection), so it
        // gets redundancy a lost mid-drag sample never needs. Same bytes/tag each time — the
        // host posts the FIRST and button-balance SUPPRESSES the rest (the button is already
        // released), so duplicates never become spurious extra `*MouseUp` events.
        let up = inputEncoder.mouseUp(button: button, viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: decodedSize, clickCount: clickCount, modifiers: modifiers, zoom: zoom, pan: pan, mode: contentMode)
        for _ in 0..<Self.redundantUpCount { sendInput(up) }
    }

    /// A drag move while a button is held (view `mouseDragged`/`rightMouseDragged`). Sent as an
    /// explicit `.mouseDrag` so the host posts a `*MouseDragged` statelessly (no held-button
    /// inference) — the fix for drag-select over the unreliable input channel.
    public func sendMouseDrag(button: MouseButton, viewPoint: VideoPoint, clickCount: UInt8, modifiers: InputModifiers) {
        dbgPointer("drag", viewPoint)
        sendInput(inputEncoder.mouseDrag(button: button, viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: decodedSize, clickCount: clickCount, modifiers: modifiers, zoom: zoom, pan: pan, mode: contentMode))
    }

    public func sendScroll(dx: Double, dy: Double, viewPoint: VideoPoint) {
        sendInput(inputEncoder.scroll(dx: dx, dy: dy, viewPoint: viewPoint, layerSize: layerSize, videoNativeSize: decodedSize, zoom: zoom, pan: pan, mode: contentMode))
    }

    public func sendKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers) {
        sendInput(inputEncoder.key(keyCode: keyCode, down: down, modifiers: modifiers))
    }

    public func sendText(_ string: String) {
        sendInput(inputEncoder.text(string))
    }

    // MARK: Recovery (client → host)

    private func requestRecovery(lostFrameID: UInt32) {
        // Prefer an LTR refresh over a forced IDR (doc 17 §3.6). Sent on the DEDICATED
        // `.recovery` channel — never `.input` — so the host does not mis-decode a
        // RecoveryMessage (type bytes 1/2/3) as a phantom InputEvent.
        let message = recoveryPolicy.initialRequest(lostFrom: lostFrameID, lostTo: lostFrameID)
        transport.send(message.encode(), on: .recovery)
        // Arm the escalation clock on the FIRST request of the episode only; a request
        // sent for each subsequent dropped frame does NOT move it (BUG-H fix), so the
        // 2·RTT window measured from the first request can actually elapse.
        escalation.noteRequestSent(now: FramePacer.currentHostTimeSeconds())
    }

    private func requestIDR() {
        transport.send(RecoveryMessage.requestIDR.encode(), on: .recovery)
        // A forced IDR is still a recovery request: arm the clock if this is the first
        // request of the episode (e.g. an awaiting-keyframe delta drop), but keep the
        // original first-request time if recovery was already outstanding.
        escalation.noteRequestSent(now: FramePacer.currentHostTimeSeconds())
    }

    // MARK: Effects

    private func apply(_ effect: VideoClientStateMachine.Effect) async {
        switch effect {
        case .sendControl(let message):
            transport.send(message.encode(), on: .control)
        case .startDecodePipeline(let captureSize, _):
            startDecodePipeline(captureSize: captureSize)
        case .stopDecodePipeline:
            stopDecodePipeline()
        case .updateCaptureSize(let size):
            // The host acked an in-session resize. STAGE the new size; do NOT assign
            // `decodedSize` yet — adopt it only when a decoded CVPixelBuffer actually arrives at
            // it (frame-gated in `noteDecoded`), because in-flight old-size frames may still be
            // queued behind the ack. The decoder auto-reconfigures on the new IDR's parameter
            // sets; we only re-base the aspect-fit denominator once the new pixels land.
            pendingCaptureSize = size
            dbg("resizeAck → pending capture size \(Int(size.width))x\(Int(size.height)) (adopt on matching decoded frame)")
        }
    }

    private func startDecodePipeline(captureSize: VideoSize) {
        decodedSize = captureSize
        dbg("decode pipeline up — native(capture)=\(Int(captureSize.width))x\(Int(captureSize.height)); this is the FIXED aspect-fit denominator for the session")
        // The decoder hands each decoded NV12 buffer to the pipeline-owned pacer (via
        // the GUI hook, most-recent-wins); the pacer renders it at the display link's
        // vsync. GUI-only — the decode path is never reached in a test.
        let submit = gui.submitDecodedFrame
        // Read each decoded buffer's ACTUAL pixel dimensions and hop them back to the actor
        // (`noteDecoded`) so a frame-gated in-session-resize adoption fires when the first new-size
        // frame lands (the ack's size matters only once the pixels match it). Reading width/height
        // is a cheap, read-only CoreVideo query — no window-server.
        let decoder = VideoDecoder { [weak self] imageBuffer in
            submit(imageBuffer)
            guard let self else { return }
            let w = Double(CVPixelBufferGetWidth(imageBuffer))
            let h = Double(CVPixelBufferGetHeight(imageBuffer))
            Task { await self.noteDecoded(width: w, height: h) }
        }
        self.decoder = decoder
        reapplyCursor()
        log.info("client decode pipeline up at capture \(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public)")
    }

    private func stopDecodePipeline() {
        decoder = nil
    }

    // MARK: PNG decode (cross-platform, no window-server)

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Tracks the **first** outstanding LTR-refresh request so the 2·RTT IDR escalation
/// can actually fire under sustained loss (doc 17 §3.6). Pure value type — no
/// transport / wall-clock; the actor passes `now` in — so the escalation timing is
/// unit-testable without a socket or `VTDecompressionSession`.
///
/// The bug this fixes (BUG-H): the client detects loss once per dropped frame and, on
/// every detection, was resetting the "when did I last ask for recovery" clock
/// (`lastRecoveryRequestTime = now` in `requestRecovery`). Under sustained loss that
/// clock never reached 2·RTT, so the guaranteed-recovery forced IDR never fired and
/// the stream could starve forever on a degraded path.
///
/// The fix: the recovery clock is the time of the FIRST request in the current
/// recovery episode. It is armed only when entering recovery (no request outstanding),
/// NOT rearmed on each subsequent loss, and cleared only when a keyframe decodes and
/// ends the episode.
public struct LTREscalationTracker: Sendable, Equatable {
    /// Host time (seconds) of the first request in the current recovery episode, or
    /// `nil` when no recovery is outstanding. Cleared by ``keyframeDecoded()``.
    public private(set) var firstRequestTime: TimeInterval?

    public init() {}

    /// Whether a recovery episode is currently outstanding (a request was sent and no
    /// keyframe has cleared it yet).
    public var hasOutstandingRequest: Bool { firstRequestTime != nil }

    /// Records that a recovery request is being sent at host time `now`. Arms the clock
    /// ONLY when entering recovery (no request outstanding); a request sent while one is
    /// already outstanding does NOT move the clock — that is the BUG-H fix (the old code
    /// reset the clock on every dropped frame, so 2·RTT never elapsed).
    public mutating func noteRequestSent(now: TimeInterval) {
        if firstRequestTime == nil { firstRequestTime = now }
    }

    /// Whether to escalate to a forced IDR right now: a request is outstanding and at
    /// least `2·RTT` (per `policy`) has elapsed since the FIRST request. Pure — does not
    /// mutate; the caller decides whether to act.
    public func shouldEscalate(now: TimeInterval, rtt: TimeInterval, policy: RecoveryPolicy) -> Bool {
        guard let firstRequestTime else { return false }
        return policy.shouldEscalateToIDR(elapsedSinceRequest: now - firstRequestTime, rtt: rtt)
    }

    /// A keyframe (LTR refresh or forced IDR) decoded — the recovery episode is over,
    /// so disarm the clock. The next loss starts a fresh episode and re-arms it.
    public mutating func keyframeDecoded() {
        firstRequestTime = nil
    }

    /// Re-anchor the clock to `now` AFTER a forced-IDR escalation actually fired (F7).
    /// Once ``shouldEscalate(now:rtt:policy:)`` returns true, every SUBSEQUENT dropped
    /// frame in the same loss episode would otherwise keep returning true (the first
    /// request is still ≥ 2·RTT old) and the drain loop would resend a redundant
    /// `requestIDR` per dropped frame. Re-anchoring `firstRequestTime = now` gates the
    /// NEXT escalation to one-per-2·RTT — a single forced IDR per escalation window
    /// instead of a burst.
    ///
    /// This is DISTINCT from ``noteRequestSent(now:)``: an ordinary recovery request must
    /// NOT move the first-request clock (BUG-H — that is what let the 2·RTT window elapse
    /// in the first place). Only a fired escalation re-arms it. The episode is still
    /// cleared by ``keyframeDecoded()`` when recovery actually lands.
    public mutating func noteEscalated(now: TimeInterval) {
        firstRequestTime = now
    }
}
#endif
