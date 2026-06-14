#if canImport(VideoToolbox) && canImport(Metal) && canImport(QuartzCore)
import AislopdeskVideoProtocol
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import OSLog
import QuartzCore

/// The client-side session orchestrator for the GUI video path (PATH 2 / Phase 4) —
/// the exact mirror of `AislopdeskVideoHost.AislopdeskVideoHostSession`.
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
public actor AislopdeskVideoClientSession {
    private let log = Logger(subsystem: "aislopdesk.video.client", category: "AislopdeskVideoClientSession")

    /// Opt-in stderr diagnostics (`AISLOPDESK_VIDEO_DEBUG=1`) — the client counterpart to the host's,
    /// so `scripts/check-video.sh` can see whether media datagrams arrive, frames reassemble, and
    /// decode succeeds (OSLog `.info` is not persisted; a white client window is otherwise opaque).
    /// No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil
    /// Redundancy for the critical RELEASE edge. Over plain UDP a dropped `mouseUp` strands the
    /// target app mid-selection; we send the up a few times back-to-back so a single loss can't.
    /// Genuinely idempotent on the host: button-balance posts the FIRST up (the one that releases
    /// the held button) and SUPPRESSES the duplicates, so the target app never sees a spurious
    /// extra `*MouseUp`.
    private static let redundantUpCount = 3
    private var dbgMediaCount = 0
    private var dbgDecodeCount = 0
    private var dbgPointerCount = 0
    /// BUG-1: monotonic time of the last cursor datagram RECEIVED on this (session) actor. The host/net
    /// side of the freeze probe — see ``dbgNoteCursorRx()``.
    private var dbgLastCursorRx: Double = 0
    /// BUG-1: monotonic time of the last VIDEO datagram received — to detect a host capture stall (a gap in
    /// video arrival) distinct from a client main-actor block.
    private var dbgLastMediaRx: Double = 0
    private nonisolated func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("Aislopdesk[video.client]: \(message())\n".utf8))
    }

    /// Diagnostics for the input-coordinate path (`AISLOPDESK_VIDEO_DEBUG`): prints the view
    /// point, the on-screen layer size, the aspect-fit NATIVE size, the resulting
    /// displayed-video sub-rect, and the normalised 0..1 the host receives — so a "toạ độ
    /// sai" / "không fill" report can be ROOT-CAUSED from the log instead of guessed
    /// (does the video fill the pane? is the native size capture-pinned or geometry-
    /// corrupted? does the click land where the user aimed?). Moves are sampled 1-in-30;
    /// every button-down / drag / up is logged.
    private func dbgPointer(_ kind: String, _ viewPoint: VideoPoint) {
        guard Self.debugStderr else { return }
        dbgPointerCount += 1
        if kind == "move", !dbgPointerCount.isMultiple(of: 30) { return }
        let r = AspectFit.displayedVideoRect(viewSize: layerSize, videoNativeSize: decodedSize, mode: contentMode)
        let n = InputEventEncoder.normalize(
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        )
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
        /// WF-6 (#8): set the renderer's YCbCr→RGB color range to the stream's negotiated luma range.
        /// Called once at pipeline bring-up, BEFORE the first frame renders (the `helloAck` carrying
        /// the range arrives before any media). `.video` ⇒ today's coefficients, byte-identical.
        public var setColorRange: @Sendable (ColorRange) -> Void
        /// 1:1 PANE SNAP (2026-06-11): fired when the decoded frames' PIXEL size CHANGES — the
        /// session's first decoded frame, or the first frame at a new capture size after an
        /// in-session resize. The view layer derives the 1:1 point size (`pixels /
        /// contentsScale`, ``StreamSizeSnap``) and snaps its canvas pane to it. `nil` ⇒ no pane
        /// to snap (a standalone window) → the session keeps the legacy connect-time
        /// host-follow negotiation (`startDecodePipeline` kicks the resize debounce) instead.
        public var notifyDecodedPixelSize: (@Sendable (VideoSize) -> Void)?
        /// FPS GOVERNOR (2026-06-11): the host announced the stream's CONTENT cadence (fps) — at
        /// session start and on every governed step. The pipeline rebases the pacer's deadline-mode
        /// interval + adaptive-jitter seconds→frames conversion (`FramePacer.setContentFps`).
        /// `nil` ⇒ ignore (a view with no pacer to rebase). Idempotent — the host dup-sends ×2.
        public var applyStreamCadence: (@Sendable (Int) -> Void)?
        /// Component 4 (adaptive pacer depth, 2026-06-11): SYNCHRONOUS, lock-guarded drain of the
        /// pipeline-owned FramePacer's presentation-health counters (`FramePacer.drainTelemetry`).
        /// Safe to call from the session actor with NO main hop — the pacer is `@unchecked
        /// Sendable` behind its own NSLock. `nil` ⇒ no pacer attached (depth 0 on the wire).
        public var readPacerTelemetry: (@Sendable () -> PacerTelemetrySnapshot)?
        /// Depth v3 (owd-late, 2026-06-12): one NETWORK-late event — a frame whose one-way delay
        /// spiked past the rolling baseline by more than the late threshold (`OwdLateDetector`).
        /// The pipeline folds it into the pacer's depth policy (`FramePacer.noteNetworkLate`) —
        /// the PROMOTION source for the adaptive 1↔2 depth boost (replacing the present-gap
        /// classifier, which natural sub-cadence content kept permanently "late"). Synchronous,
        /// lock-guarded, callable from the session actor like `readPacerTelemetry`.
        public var noteNetworkLate: (@Sendable () -> Void)?
        @preconcurrency
        public init(
            submitDecodedFrame: @escaping @Sendable (CVImageBuffer) -> Void,
            applyCursor: @escaping @Sendable (CursorUpdate, CursorPlacement) -> Void,
            registerCursorShape: @escaping @Sendable (CGImage, VideoSize, UInt16) -> Void,
            setColorRange: @escaping @Sendable (ColorRange) -> Void,
            notifyDecodedPixelSize: (@Sendable (VideoSize) -> Void)? = nil,
            applyStreamCadence: (@Sendable (Int) -> Void)? = nil,
            readPacerTelemetry: (@Sendable () -> PacerTelemetrySnapshot)? = nil,
            noteNetworkLate: (@Sendable () -> Void)? = nil,
        ) {
            self.submitDecodedFrame = submitDecodedFrame
            self.applyCursor = applyCursor
            self.registerCursorShape = registerCursorShape
            self.setColorRange = setColorRange
            self.notifyDecodedPixelSize = notifyDecodedPixelSize
            self.applyStreamCadence = applyStreamCadence
            self.readPacerTelemetry = readPacerTelemetry
            self.noteNetworkLate = noteNetworkLate
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
        public init(
            viewSize: VideoSize,
            videoNativeSize: VideoSize,
            zoom: Double,
            pan: VideoPoint,
            mode: VideoContentMode = .fit,
        ) {
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
    private var decodedSize: VideoSize = .init(width: 0, height: 0)
    private var layerSize: VideoSize = .init(width: 0, height: 0)
    /// The current VNC-style zoom (≥1) + normalized pan applied by the renderer (iOS
    /// pinch/pan; always (1, .zero) on macOS). Stored here so the input encoder inverts
    /// the EXACT SAME transform the renderer applies — otherwise a click while zoomed
    /// would land at the un-zoomed source position. Kept in lock-step with the renderer
    /// via ``setZoom(_:pan:)`` (the pipeline calls both on every gesture).
    private var zoom: Double = 1
    private var pan: VideoPoint = .init(x: 0, y: 0)
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

    /// Single batch-drain consumer of the inbound datagram queue (see ``start()``). Mirrors the
    /// host's `InboundQueue` pump; replaces the legacy per-datagram `Task { await receive… }`
    /// fan-out (≈3000 Task spawns/sec at 60fps × ~50 fragments — pure scheduler overhead, and the
    /// per-fragment actor hops added ~1.5ms of reassembly-completion latency + jitter per frame).
    private var inboundConsumer: Task<Void, Never>?
    private var inboundWakeup: AsyncStream<Void>.Continuation?
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
    /// Component 5 (recovery-redundancy): the loss-observing predicate gating the HALVED
    /// escalation clock. Fed by every unrecoverable loss AND every FEC-recovered completion
    /// (the early-warning channel), read by ``shouldEscalateToIDR()``.
    private var lossWindow = LossObservationWindow()
    /// Component 5: `AISLOPDESK_RECOVERY_REDUNDANCY` — total byte-identical copies per logical
    /// recovery request (default 3, clamped 1...5 by the init; 1 = today's single send). Copies
    /// are spaced 3 ms apart to decorrelate burst loss; the host's `RecoveryRequestDeduper`
    /// collapses them to one action (spread ≤ half its 25 ms window at every legal copies count).
    private static let recoveryRedundancy: RecoveryRequestRedundancy = {
        let n = ProcessInfo.processInfo.environment["AISLOPDESK_RECOVERY_REDUNDANCY"].flatMap(Int.init) ?? 3
        return RecoveryRequestRedundancy(copies: n)
    }()

    /// Component 5: `AISLOPDESK_FAST_ESCALATION` (default ON; "0" disables) — halve the IDR
    /// escalation clock to `max(1·RTT, 60 ms, 1.5·RTT)` while ``lossWindow`` is observing loss
    /// (the floor is `AISLOPDESK_ESCALATION_FLOOR_MS`-tunable — fix 3, 2026-06-11: the old 30 ms
    /// floor escalated before an LTR refresh could physically land). Off ⇒ `observingLoss` is
    /// forced false and escalation is byte-identical to today.
    private static let fastEscalationEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_FAST_ESCALATION"] != "0"
    /// Component 2: the wrap-aware highest successfully-DECODED frameID. Carried (as
    /// ``DecodeFrontier/wireValue``) on every `requestIDR` / `requestLTRRefresh` so the host's
    /// delivery-keyed recovery-IDR cooldown can distinguish a delivered keyframe from a casualty.
    private var frontier = DecodeFrontier()
    /// Decode-fail cascade fix (2026-06-12): drop-until-anchor admission. Once the reference
    /// chain is known-broken (an unrecoverable loss), deltas stop reaching VT — only anchor
    /// candidates (keyframe / LTR refresh / pre-break delta) are submitted. Kills the measured
    /// 9-losses→23-decode-fails→63-IDR-requests amplification (each old failure also tore the
    /// VT session down, wiping the very LTR reference the recovery refresh needed).
    private var decodeGate = DecodeGate()
    /// In-order decode admission (2026-06-12): frames release to the decoder strictly in frameID
    /// order — an out-of-order completion (small frame outrunning a big/FEC-recovering
    /// predecessor) is HELD until the gap completes or is declared lost, instead of hitting VT
    /// with a missing reference (the measured `frontier = N−2` -12909 class).
    private var sequencer = DecodeSequencer()
    /// Debug-only counter: frames the gate dropped this session (visible in the periodic dbg line).
    private var dbgGateDrops: UInt64 = 0
    /// Smoothed RTT estimate gating the 2·RTT IDR-escalation timeout. 50 ms default
    /// until ``updateRTTEstimate(_:)`` feeds a measurement.
    private var rttEstimate: TimeInterval = 0.05

    // MARK: Network-feedback telemetry (the network-feedback channel)

    /// DEFAULT ON; `AISLOPDESK_NETSTATS=0` disables: the client sends no NetworkStats reports and the
    /// RTT loop reverts to today's open-loop behaviour. The 4-byte header field is still parsed
    /// either way (the host writes 0 when disabled).
    private static let telemetryEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_NETSTATS"] != "0"
    /// Component 3 (delay-gradient): DEFAULT ON; `AISLOPDESK_TREND=0` disables. The client computes a
    /// libwebrtc-style trendline over per-FRAME one-way-delay variation and ships the detector
    /// output in the NetworkStats report. PURE TELEMETRY: the host's gradient cut path is its own
    /// default-OFF gate (`AISLOPDESK_ABR_GRAD`), so with this on the host merely logs trend fields.
    private static let trendEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_TREND"] != "0"
    /// The newest `hostSendTsMillis` OBSERVED on a video fragment (0 = none / telemetry off). An
    /// OPAQUE token the client echoes back; never compared against the client clock.
    private var latestHostSendTs: UInt32 = 0
    /// KHỰNG-ladder stage 4 (AISLOPDESK_VIDEO_DEBUG): last fragment-ingest time on this actor.
    private var dbgLastIngestAt: Double = 0
    /// Client-monotonic time (seconds) at which `latestHostSendTs` was observed, so the report's
    /// `clientHoldMs` is a client-LOCAL relative delta (now − observedAt) — never an absolute
    /// client timestamp (which would embed cross-machine skew).
    private var latestHostSendTsObservedAt: Double = 0
    /// Pure inter-arrival jitter estimator (client-clock-only 2nd differences).
    private var owdJitter = OWDJitterEstimator()
    /// Component 3 (delay-gradient): pure trendline detector over per-frame OWD variation
    /// (clock-skew-immune deltas, like `owdJitter`). Fed one sample per frame via `trendSampler`.
    private var owdTrend = TrendlineEstimator()
    /// Admits exactly ONE trend sample per frame — the FIRST fragment of each wrap-aware strictly-
    /// newer frameID (kfDup duplicates / reordered older frames / ts==0 are self-rejecting).
    /// Shared by the trendline AND the owd-late detector (both want the same per-frame sample).
    private var trendSampler = TrendSampler()
    /// Depth v3 (owd-late, 2026-06-12): per-frame one-way-delay spike detector — owd more than
    /// `max(floor, fraction × frame interval)` past the rolling min-baseline = one network-late
    /// event, forwarded to the pacer's depth policy via ``GUIHooks/noteNetworkLate``.
    private var owdLateDetector = OwdLateDetector()
    /// The stream's content frame interval (ms) — seeds the owd-late threshold. Updated by the
    /// FPS governor's `streamCadence` message (`.applyStreamCadence`); 60 fps until announced.
    private var contentIntervalMs: Double = 1000.0 / 60.0
    /// Windowed counters reset after every report: frames completed / FEC-recovered / unrecovered.
    private var winFramesReceived: UInt32 = 0
    private var winFecRecovered: UInt32 = 0
    private var winUnrecovered: UInt32 = 0
    /// The self-owned ~50 ms NetworkStats timer (mirrors ``keepaliveTask``'s safe weak pattern).
    /// Cancelled in ``stop()``.
    private var networkStatsTask: Task<Void, Never>?

    /// - Parameters:
    ///   - requestedWindowID: the host CGWindowID to remote.
    ///   - viewport: the client surface size sent in the hello.
    ///   - transport: the UDP transport (production: ``VideoMuxClientTransport``).
    ///   - gui: the main-actor GUI hand-off seams (submit-frame / cursor / shape).
    ///   - fec: FEC scheme matching the host (default 20% XOR parity).
    public init(
        requestedWindowID: UInt32,
        viewport: VideoSize,
        transport: any VideoClientTransport,
        gui: GUIHooks,
        fec: FECScheme? = XORParityFEC(),
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy(),
    ) {
        self.transport = transport
        self.gui = gui
        self.recoveryPolicy = recoveryPolicy
        stateMachine = VideoClientStateMachine(requestedWindowID: requestedWindowID, viewport: viewport)
        reassembler = FrameReassembler(fec: fec)
        layerSize = viewport
    }

    // MARK: Lifecycle

    /// Connects the UDP flows, sends the `hello`, and starts receiving. The decode
    /// pipeline (decoder + display link) starts once the host accepts.
    public func start() async throws {
        // ORDERED + BATCHED inbound path (mirrors the host's `InboundQueue` pump): the transport's
        // serial receive queue APPENDS synchronously (arrival order carried end-to-end) and yields
        // a coalesced wakeup; ONE .high consumer drains the whole backlog per wakeup and feeds the
        // actor in order. Replaces a per-datagram `Task { await receive… }` fan-out — ~3000 Task
        // spawns/sec under load, each its own actor hop, which both burned CPU and let datagrams
        // race into the actor out of arrival order.
        let queue = ClientInboundQueue()
        let (wakeups, wakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        inboundWakeup = wakeup
        // .high: this pump sits between a received fragment and decode-submit; a bare Task's
        // inherited priority can queue it behind pool work (same rationale as the host pumps).
        inboundConsumer = Task(priority: .high) { [weak self] in
            for await _ in wakeups {
                guard let self else { break }
                let batch = queue.drainAll()
                if batch.isEmpty { continue } // a coalesced wakeup an earlier drain already emptied
                await receiveBatch(batch)
            }
        }
        // Enqueue THEN signal on the transport's serial receive queue (no lost wakeup).
        try await transport.start { channel, data in
            queue.append(.media(channel, data))
            wakeup.yield()
        } onCursor: { data in
            queue.append(.cursor(data))
            wakeup.yield()
        }
        for effect in stateMachine.start() { await apply(effect) }
        startKeepalive()
        startNetworkStats()
        log.info("video client session started; hello sent")
    }

    /// Drains one inbound batch in arrival order on the actor.
    private func receiveBatch(_ batch: [ClientInboundQueue.Item]) async {
        for item in batch {
            switch item {
            case let .media(channel, data): await receiveMedia(channel: channel, data: data)
            case let .cursor(data): await receiveCursor(data)
            }
        }
    }

    /// Sends a best-effort `bye`, tears the pipeline + sockets down.
    public func stop() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        networkStatsTask?.cancel()
        networkStatsTask = nil
        resizeSettleTask?.cancel()
        resizeSettleTask = nil
        inboundWakeup?.finish()
        inboundWakeup = nil
        inboundConsumer?.cancel()
        inboundConsumer = nil
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
                await sendKeepaliveIfStreaming()
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

    // MARK: Network-feedback telemetry (the network-feedback channel)

    /// Starts the self-owned ~50 ms NetworkStats timer. COPIES ``startKeepalive()``'s safe weak
    /// pattern EXACTLY — a strong `self` capture in a long-lived timer Task would leak the whole
    /// session (decoder, sockets, Metal hooks). Cancelled in ``stop()``.
    private func startNetworkStats() {
        networkStatsTask?.cancel()
        networkStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                await sendNetworkStatsIfStreaming()
            }
        }
    }

    /// Sends one NetworkStats report iff streaming and telemetry is enabled, then RESETS the windowed
    /// counters (the counts are per-report-window). `clientHoldMs` is a client-LOCAL delta (now −
    /// observedAt), never an absolute client timestamp, so the host can subtract it inside its own
    /// clock with zero cross-machine skew. The hold is clamped non-negative + saturating so a long
    /// pause cannot trap the `UInt32(Double)` initializer.
    private func sendNetworkStatsIfStreaming() {
        guard stateMachine.mediaFlowing, Self.telemetryEnabled else { return }
        let now = FramePacer.currentHostTimeSeconds()
        let holdMs: UInt32 = latestHostSendTs == 0 ? 0 : UInt32(min(
            Double(UInt32.max),
            max(0, (now - latestHostSendTsObservedAt) * 1000),
        ))
        // Component 4: drain the pacer's presentation-health window EXACTLY once per report (the
        // drain IS the window reset, mirroring the win* counter pattern below). No pacer ⇒ zeros
        // with depth 0 (the wire's "no pacer attached" gauge value).
        let pacer = gui.readPacerTelemetry?() ?? PacerTelemetrySnapshot(lateFrames: 0, presentGaps: 0, depth: 0)
        // STALE-TREND GATE: the estimator only mutates in note(), so across a content-idle gap a
        // latched .overusing verdict would ride every 50 ms report until the NEXT arrival fires
        // the idle reset (≥ resetGapMs later). When the last sample is older than the estimator's
        // own reset gap, ship neutral/zero trend fields (state 0, trend 0) instead — the queue
        // context behind the verdict no longer exists. Same clock as the note() feed (`now`).
        let trendFresh = Self.trendEnabled && !owdTrend.isStale(nowMs: now * 1000)
        let report = NetworkStatsReport(
            framesReceived: winFramesReceived,
            fecRecovered: winFecRecovered,
            unrecovered: winUnrecovered,
            latestHostSendTs: latestHostSendTs,
            clientHoldMs: holdMs,
            owdJitterMicros: owdJitter.jitterMicros(),
            owdTrendMilli: trendFresh ? owdTrend.wireTrendMilli : 0,
            owdTrendFlags: trendFresh ? owdTrend.wireTrendFlags : 0,
            pacerLateFrames: pacer.lateFrames,
            pacerPresentGaps: pacer.presentGaps,
            pacerDepth: pacer.depth,
        )
        transport.send(RecoveryMessage.networkStats(report).encode(), on: .recovery)
        // Reset the window — counts are per-report.
        winFramesReceived = 0
        winFecRecovered = 0
        winUnrecovered = 0
    }

    // MARK: Layout (called by the host view each layout pass)

    /// Updates the on-screen layer size (points). Recomputes the cursor scale and
    /// re-applies the last cursor update so the overlay tracks the new layout.
    public func setLayerSize(_ size: VideoSize) {
        layerSize = size
        dbg(
            "setLayerSize → \(Int(size.width))x\(Int(size.height)) (native=\(Int(decodedSize.width))x\(Int(decodedSize.height)))",
        )
        reapplyCursor()
        maybeRequestResize(for: size)
    }

    /// 1:1 PANE SNAP: the view snapped its pane so the stream renders pixel-for-pixel (`size` =
    /// the resulting video-layer point size). Rebase the resize debounce on it WITHOUT emitting
    /// (no epoch mint — nothing was sent): the snap-induced layout pass then `.hold`s (zero delta
    /// vs the adopted baseline) instead of echoing a `resizeRequest` back to the host, so the
    /// snap stays client-side (no host-window AX-resize, no feedback loop). A LATER user drag
    /// still differs from this baseline by ≥ `minDelta` and requests normally (host-follow).
    public func noteLayerSizeAdopted(_ size: VideoSize) {
        resizeDebounce.noteAdopted(size)
        dbg("resize: pane snapped to 1:1 — debounce rebased on \(Int(size.width))x\(Int(size.height)) (no request)")
    }

    /// Drives the in-session resize debounce on a layer-size change (env-gated). A real size
    /// change re-arms the settle clock; once the size has been QUIET for the settle interval and
    /// differs enough from the last request, emit exactly one `resizeRequest(desired, epoch)` on
    /// the control channel (the existing `.sendControl` path). `noteRequested` is called ONLY
    /// after acting, per the ``ResizeDebounce`` query/mutator discipline. No-op when the session
    /// is not streaming.
    private func maybeRequestResize(for size: VideoSize) {
        guard stateMachine.mediaFlowing else { return }
        // PANE-FOLLOWS-STREAM (1:1 snap): until the first snap rebases the debounce
        // (`noteLayerSizeAdopted`), suppress emission entirely. A layout pass racing the first
        // decoded frame must not echo the pane's STALE size to the host — that would AX-resize
        // the host window to the old pane size right before the pane adopts the stream's
        // natural size, defeating the snap. After the rebase, user drags request normally.
        if gui.notifyDecodedPixelSize != nil, resizeDebounce.lastRequested == nil {
            dbg("resize: pane-follows-stream — holding resizeRequest until the 1:1 snap rebases the debounce")
            return
        }
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
        guard case let .request(settled) = resizeDebounce.decide(layerSize: size, elapsedSinceLastChange: elapsed)
        else {
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
        let delay = resizeDebounce.settleInterval + 0.02 // re-check just after the surface goes quiet
        resizeSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await resizeSettleFired()
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
        if dbgMediaCount == 1 || dbgMediaCount.isMultiple(of: 30) {
            dbg(
                "media datagram #\(dbgMediaCount) received (channel=\(channel), \(data.count)B, mediaFlowing=\(stateMachine.mediaFlowing))",
            )
        }
        // BUG-1: a gap in VIDEO datagram arrival = a HOST-side capture stall (e.g. the SCStream hitching
        // when the window is raised on a click). If a `mediaRX gap` lines up with a `click` line but there
        // is NO client `cursorAPPLY`/`RENDER` gap, the freeze is host capture, not client main-actor.
        if channel == .video, Self.debugStderr, stateMachine.mediaFlowing {
            let now = FramePacer.currentHostTimeSeconds()
            if dbgLastMediaRx > 0 {
                let gap = now - dbgLastMediaRx
                if gap > 0.1 { dbg("mediaRX gap \(Int(gap * 1000))ms (host capture/net)") }
            }
            dbgLastMediaRx = now
        }
        switch router.route(channel: channel, data: data, mediaFlowing: stateMachine.mediaFlowing) {
        case let .control(message):
            for effect in stateMachine.handleControl(message) { await apply(effect) }
        case let .videoFragment(fragment):
            ingestVideo(fragment)
        case let .geometry(message):
            applyGeometry(message)
        case let .drop(reason):
            log.error("dropping media datagram: \(reason)")
            dbg("media datagram DROPPED: \(reason)")
        case .ignore:
            break
        }
    }

    private func ingestVideo(_ fragment: FrameFragment) {
        // Network-feedback telemetry: every fragment arrival feeds the client-clock-only jitter
        // estimator, and the NEWEST host-send-ts (wrap-aware max) is tracked to echo back so the
        // host can derive RTT in its own clock. A late kfDup duplicate carries an OLDER stamp, so
        // the wrap-aware comparison rejects it (latestHostSendTs never regresses). 0 = telemetry off.
        // ONE hoisted clock read shared by jitter / hold-anchor / trendline below.
        let now = FramePacer.currentHostTimeSeconds()
        owdJitter.note(arrival: now)
        // KHỰNG-ladder stage 4 (AISLOPDESK_VIDEO_DEBUG): a >28ms hole between fragment ingests ON THE
        // ACTOR while stage 3 (socket) was clean = the per-datagram Task hop / actor backlog ate
        // the time. Stage 3 also gapped ⇒ inherited, not actor-caused.
        if Self.debugStderr {
            let now = ProcessInfo.processInfo.systemUptime
            if dbgLastIngestAt > 0, now - dbgLastIngestAt > 0.028 {
                dbg("ingest gap \(Int((now - dbgLastIngestAt) * 1000))ms")
            }
            dbgLastIngestAt = now
        }
        let ts = fragment.header.hostSendTsMillis
        if ts != 0, latestHostSendTs == 0 || ts.distanceWrapped(from: latestHostSendTs) > 0 {
            latestHostSendTs = ts
            latestHostSendTsObservedAt = now
        }
        // Component 3 (delay-gradient): ONE sample per frame — the first fragment of each strictly-
        // newer frameID (all fragments of a frame share one packetize-time stamp, so per-fragment
        // samples would carry a built-in intra-frame slope; kfDup/reorder/ts==0 self-reject).
        // The SAME admitted sample also feeds the owd-late detector (depth v3) — one sampler,
        // two consumers, so the per-frame discipline can't drift between them.
        if trendSampler.shouldSample(frameID: fragment.header.frameID, sendTs: ts) {
            if Self.trendEnabled {
                owdTrend.note(arrivalMs: now * 1000, sendTs: ts)
            }
            // Depth v3: an owd spike past baseline + threshold = one network-late event for the
            // pacer's adaptive depth (the signal depth-2 actually absorbs — unlike the old
            // present-gap classifier, this can't self-sustain at depth 2 or misread sub-cadence
            // content as late, so demote actually happens on a clean path).
            if let overMs = owdLateDetector.note(
                arrivalMs: now * 1000,
                sendTs: ts,
                intervalMs: contentIntervalMs,
            ) {
                gui.noteNetworkLate?()
                dbg("owd late: +\(Int(overMs))ms over baseline (frame #\(fragment.header.frameID))")
            }
        }
        let result = reassembler.ingest(fragment)
        switch result {
        case let .completed(frame):
            dbg(
                "frame reassembled #\(frame.frameID) (kf=\(frame.keyframe) ltr=\(frame.isLTR) fec=\(frame.recoveredViaFEC)) → decoding",
            )
            winFramesReceived &+= 1
            if frame.recoveredViaFEC {
                winFecRecovered &+= 1
                // Component 5: an FEC recovery is the EARLY-WARNING loss event — bursts produce
                // several of these before the first unrecoverable frame, so the burst's first
                // frozen episode already runs the halved escalation clock.
                lossWindow.noteEvent(now: FramePacer.currentHostTimeSeconds())
            }
            // In-order release: a frame ahead of a reassembly gap is held until the gap
            // resolves (complete or declared lost) — never submitted over a missing reference.
            for released in sequencer.noteCompleted(frame) {
                decode(released)
            }
        case let .dropped(lost):
            // R7 #3: when the INGESTED fragment's OWN frame becomes hopeless, `ingest()` returns
            // `.dropped(frameID:)` directly AND has already POPPED that id off its dropped queue — so the
            // drain loop below would MISS it. The prior code ignored this return entirely, so for the
            // reorder-then-loss interleaving (a newer frame's fragment advances the frontier, then an
            // older frame's last data fragment arrives and is hopeless) lost-frame recovery (LTR refresh /
            // IDR) NEVER fired — the stream stalled on the last good frame until an unrelated re-anchor.
            // Route it through the same recovery decision as the drain.
            signalRecovery(lostFrameID: lost)
        case .incomplete,
             .stale:
            break
        }
        // Drain any OTHER (older) frames the reassembler declared unrecoverably lost during this ingest.
        while let lost = reassembler.nextDroppedFrame() {
            signalRecovery(lostFrameID: lost)
        }
    }

    /// Signals recovery for one unrecoverably-lost frame. First loss → prefer an LTR refresh; if an LTR
    /// refresh is already in flight and no decodable frame has cleared it within 2·RTT, ESCALATE to a
    /// forced IDR (doc 17 §3.6). Driven off the loss-detection path — there is no separate timer. Shared
    /// by BOTH the `.dropped` return and the `nextDroppedFrame()` drain so neither path can silently
    /// swallow a loss (R7 #3).
    private func signalRecovery(lostFrameID lost: UInt32) {
        dbg("frame #\(lost) declared LOST (unrecoverable)")
        // Network-feedback telemetry: count an unrecoverable loss (the loss-rate numerator).
        winUnrecovered &+= 1
        // Component 5: feed the loss-observing window (gates the halved escalation clock).
        lossWindow.noteEvent(now: FramePacer.currentHostTimeSeconds())
        // SELF-HEAL: record the loss boundary so a SUCCESSFULLY-decoded frame newer than every loss
        // (the host's cadence/recovery LTR refresh — a P-frame, never a keyframe) can end the episode
        // instead of letting the 2·RTT escalation fire a spurious IDR after a healed stream.
        escalation.noteLoss(frameID: lost)
        // Cascade fix: arm the decode gate — post-loss deltas are dropped BEFORE VT until an
        // anchor (keyframe / acked-anchored refresh) decodes, instead of failing one by one.
        decodeGate.noteLoss(frameID: lost)
        // The declared loss closes any sequencer gap at this id: frames held behind it release
        // NOW (the armed gate above drops the non-anchors among them — its job, not VT's).
        for released in sequencer.noteLost(frameID: lost) {
            decode(released)
        }
        if shouldEscalateToIDR() {
            requestIDR()
            // Re-anchor the escalation clock so the NEXT dropped frame in this same loss episode does
            // not re-fire the escalation (and resend a redundant requestIDR) until another 2·RTT elapses
            // (F7). Ordinary requestRecovery still must NOT move the first-request clock (BUG-H) — only a
            // fired escalation re-arms it.
            escalation.noteEscalated(now: FramePacer.currentHostTimeSeconds())
        } else {
            requestRecovery(lostFrameID: lost)
        }
    }

    /// Whether a forced-IDR escalation is due: an LTR refresh is already outstanding
    /// (the recovery episode is armed, not yet cleared by a keyframe) and at least
    /// 2·RTT — or, while OBSERVING LOSS (component 5), `max(1·RTT, 30 ms)` — has elapsed
    /// since the FIRST request of the episode
    /// (``LTREscalationTracker/shouldEscalate(now:rtt:policy:observingLoss:)``).
    /// The env gate (`AISLOPDESK_FAST_ESCALATION`) is applied HERE so the pure types stay env-free.
    private func shouldEscalateToIDR() -> Bool {
        let now = FramePacer.currentHostTimeSeconds()
        return escalation.shouldEscalate(
            now: now,
            rtt: rttEstimate,
            policy: recoveryPolicy,
            observingLoss: Self.fastEscalationEnabled && lossWindow
                .isObservingLoss(now: now),
        )
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
        // Cascade fix (2026-06-12): drop-until-anchor. A delta that (transitively) references a
        // lost frame cannot decode — submitting it costs a VT failure, a session teardown, and a
        // redundant IDR request PER FRAME (measured: 9 losses → 23 decode-fails → 63 requests).
        // While the chain is broken, only anchor candidates reach VT. Liveness: the escalation
        // episode was armed by the loss path; every gated drop re-runs the escalation check, so a
        // lost recovery frame still escalates to a forced IDR at the 2·RTT / floor cadence.
        if case .drop = decodeGate.verdict(
            frameID: frame.frameID,
            keyframe: frame.keyframe,
            ackedAnchored: frame.ackedAnchored,
        ) {
            dbgGateDrops &+= 1
            dbg(
                "decode gate: frame #\(frame.frameID) dropped (\(decodeGate.mode), total \(dbgGateDrops)) — awaiting anchor",
            )
            if shouldEscalateToIDR() {
                requestIDR()
                escalation.noteEscalated(now: FramePacer.currentHostTimeSeconds())
            }
            return
        }
        do {
            // The decoded NV12 size becomes the cursor-scale denominator.
            updateDecodedSize(from: frame)
            try decoder.decode(frame)
            // Component 2: advance the decode frontier — the context every recovery request carries.
            frontier.noteDecoded(frameID: frame.frameID)
            // Cascade fix: a successful decode may re-open the gate (keyframe, or an anchor newer
            // than every recorded loss — the same proof `escalation.frameDecoded` uses).
            decodeGate.noteDecodeSucceeded(frameID: frame.frameID, keyframe: frame.keyframe)
            // WF-8: on a SUCCESSFUL decode of an LTR-flagged frame, ACK it so the host learns the
            // client now HOLDS this long-term reference and may ForceLTRRefresh against it (the
            // ACKED-ONLY invariant — we ack ONLY frames we actually decoded, never merely received
            // fragments of). The ack rides the dedicated `.recovery` channel; its `streamSeq` wire
            // field carries the FRAME ID for WF-8 (the dead ack path repurposed — see
            // RecoveryMessage.ack).
            // COMPONENT 2 EXTENSION: also ack every decoded KEYFRAME (one ~5-byte datagram per rare
            // keyframe) — the host's delivery-keyed recovery-IDR cooldown folds it via a ring-matched
            // `noteKeyframeDelivered` (an id that is not a sent keyframe is a no-op there, and
            // `ltrController.ackFrame` already no-ops on unknown ids), so this is safe with
            // AISLOPDESK_LTR off too. If VT happens to LTR-flag an IDR this is the same single ack as
            // before — the host fold is idempotent.
            if frame.isLTR || frame.keyframe {
                transport.send(RecoveryMessage.ack(streamSeq: frame.frameID).encode(), on: .recovery)
                dbg("acked #\(frame.frameID) (kf=\(frame.keyframe) ltr=\(frame.isLTR)) — decoder now holds it")
            }
            dbgDecodeCount += 1
            if dbgDecodeCount == 1 || dbgDecodeCount.isMultiple(of: 15) {
                dbg("DECODED frame #\(dbgDecodeCount) (keyframe=\(frame.keyframe)) → submitted to pacer/render")
            }
            // SELF-HEAL: a successful NON-keyframe decode that is newer than every loss in the
            // armed episode proves the chain re-anchored (a delta referencing a lost frame throws —
            // HW-measured), so end the episode without waiting for a keyframe. This is what lets
            // the host's cadence/recovery LTR refresh actually REPLACE the forced IDR.
            if !frame.keyframe, escalation.frameDecoded(frameID: frame.frameID) {
                dbg("recovery episode healed by frame #\(frame.frameID) (no IDR needed)")
            }
            // A successful keyframe ends the recovery episode and disarms the clock,
            // so the next loss starts a fresh 2·RTT escalation window.
            if frame.keyframe {
                // REVIVE updateRTTEstimate (previously had zero call sites): the recovery
                // round-trip the client already tracks IS a real measured RTT — request sent at
                // `firstRequestTime`, recovering keyframe decoded now. It is an UPPER BOUND (it
                // includes host encode latency), which makes the 2·RTT escalation timer slightly
                // more conservative — the safe direction. Clamp [5 ms, 2 s] so a pathological
                // sample can't disable escalation; the EWMA in updateRTTEstimate smooths it. This
                // replaces the static 0.05 s as the steady-state value (0.05 s stays only as the
                // pre-measurement bootstrap). No host→client echo exists this phase, so this
                // client-local measurement is the available RTT signal.
                if let first = escalation.firstRequestTime {
                    let rttSample = FramePacer.currentHostTimeSeconds() - first
                    updateRTTEstimate(min(2.0, max(0.005, rttSample)))
                }
                escalation.keyframeDecoded()
            }
        } catch VideoDecoderError.awaitingKeyframe {
            // A delta arrived before the first IDR — drop it and ask for a keyframe ONCE; the
            // gate (needKeyframe) absorbs the rest of the pre-IDR deltas, re-requesting at the
            // escalation cadence instead of once per frame.
            decodeGate.noteAwaitingKeyframe()
            dbg("decode: awaiting keyframe (delta dropped) → requesting IDR")
            requestIDR()
        } catch {
            log.error("decode failed: \(String(describing: error))")
            // FORENSICS (2026-06-12): -12909s now occur on a loss-free wire (~1/6s under active
            // scroll) — the next log session must be able to separate corrupt-complete frames
            // (FEC mis-recovery? truncation?) from reference-misses (stale-LTR refresh?). Print
            // the frame's full identity with the failure.
            dbg(
                "DECODE FAILED: \(String(describing: error)) frame=#\(frame.frameID) kf=\(frame.keyframe) ltr=\(frame.isLTR) fec=\(frame.recoveredViaFEC) crisp=\(frame.crisp) bytes=\(frame.avcc.count) gate=\(decodeGate.mode) frontier=\(frontier.wireValue)",
            )
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
            // Cascade fix: the session is gone — only a keyframe can re-anchor now. The gate
            // drops everything else (no more per-delta awaitingKeyframe → requestIDR spam).
            decodeGate.noteHardDecodeFailure()
            requestIDR()
        }
    }

    private func updateDecodedSize(from _: ReassembledFrame) {
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
        // 1:1 PANE SNAP: surface the GROUND-TRUTH pixel size whenever it changes (the first
        // frame of the session, or the first frame at a new capture size). The helloAck /
        // resizeAck carry POINT sizes and the host's captureScale is not on the wire, so the
        // decoded buffer is the only place the client learns the true pixel dimensions.
        if previous != decoded { gui.notifyDecodedPixelSize?(decoded) }
        guard let pending = pendingCaptureSize else { return }
        // Adopt only when the decoded buffer is the genuinely-NEW size (aspect match AND a real
        // pixel-size change vs the prior frame) — an in-flight OLD-size frame queued behind the
        // ack must not trip adoption early. Pure decision: ``ResizeAdoption/shouldAdopt``.
        guard ResizeAdoption.shouldAdopt(pending: pending, decoded: decoded, previousDecoded: previous) else {
            dbg(
                "resize: decoded \(Int(width))x\(Int(height)) not yet the new size — old-size frames still in flight (pending \(Int(pending.width))x\(Int(pending.height)))",
            )
            return
        }
        decodedSize = pending
        pendingCaptureSize = nil
        dbg(
            "resize: adopted decodedSize=\(Int(pending.width))x\(Int(pending.height)) (decoded buffer \(Int(width))x\(Int(height)) matched) → reapplying cursor",
        )
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
        // `AislopdeskVideoHostSession.onGeometry` — so absolute injection tracks the live window.)
        let kind =
            switch message {
            case .move: "move"
            case .resize: "resize"
            case .bounds: "bounds"
            case .title: "title"
            }
        dbg("geometry \(kind) — native size kept capture-pinned at "
            + "\(Int(decodedSize.width))x\(Int(decodedSize.height)) (NOT re-derived from window geometry)")
    }

    // MARK: Inbound cursor (dedicated socket)

    private func receiveCursor(_ data: Data) {
        guard stateMachine.mediaFlowing else { return }
        let message: CursorChannelMessage
        do { message = try CursorChannelMessage.decode(data) } catch {
            log.error("dropping malformed cursor datagram")
            return
        }
        switch message {
        case let .update(update):
            dbgNoteCursorRx()
            lastCursorUpdate = update
            // FIX B self-heal: a position update referencing a shapeID we never cached means its
            // one-shot bitmap was lost (or never fit one datagram). Re-request it on the recovery
            // channel (debounced per id) so the overlay can recover instead of staying wrong/
            // invisible for the whole session. The applyCursor below is unchanged — it simply
            // keeps the prior bitmap until the re-shipped one arrives.
            maybeRequestCursorShape(update.shapeID)
            applyCursor(update)
        case let .shape(shape):
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

    /// BUG-1: logs a SESSION-ACTOR cursor RX gap > 100 ms — the host/network side of the freeze. The host
    /// ``CursorSampler`` samples position OFF its main thread at 120 Hz unconditionally (built so a
    /// window-raise can't stall it), so a spike here would mean a genuine host/net stall. If this stays
    /// SMALL on click-back while the main-actor APPLY/RENDER gaps spike, the freeze is a CLIENT main-actor
    /// block (the focus re-render), not the host — which is the decisive split for the fix.
    private func dbgNoteCursorRx() {
        guard Self.debugStderr else { return }
        let now = FramePacer.currentHostTimeSeconds()
        if dbgLastCursorRx > 0 {
            let gap = now - dbgLastCursorRx
            if gap > 0.1 { dbg("cursorRX gap \(Int(gap * 1000))ms (host/net)") }
        }
        dbgLastCursorRx = now
    }

    private func applyCursor(_ update: CursorUpdate) {
        // Hand the overlay the full display geometry so it places itself through the same
        // aspect-fit + zoom/pan transform the input encoder inverts (hops to the main
        // actor inside the hook).
        let placement = CursorPlacement(
            viewSize: layerSize,
            videoNativeSize: decodedSize,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        )
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
            return // do NOT mark arrived — leave the id re-requestable so a decode failure self-heals (review).
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
        sendInput(inputEncoder.mouseMove(
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        ))
    }

    public func sendMouseDown(
        button: MouseButton,
        viewPoint: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
    ) {
        dbgPointer("down", viewPoint)
        sendInput(inputEncoder.mouseDown(
            button: button,
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            clickCount: clickCount,
            modifiers: modifiers,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        ))
    }

    public func sendMouseUp(button: MouseButton, viewPoint: VideoPoint, clickCount: UInt8, modifiers: InputModifiers) {
        dbgPointer("up", viewPoint)
        // Build the up ONCE, then send it `redundantUpCount` times (fire-and-forget UDP): the
        // release edge is the one event whose loss is catastrophic (a stuck selection), so it
        // gets redundancy a lost mid-drag sample never needs. Same bytes/tag each time — the
        // host posts the FIRST and button-balance SUPPRESSES the rest (the button is already
        // released), so duplicates never become spurious extra `*MouseUp` events.
        let up = inputEncoder.mouseUp(
            button: button,
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            clickCount: clickCount,
            modifiers: modifiers,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        )
        for _ in 0..<Self.redundantUpCount { sendInput(up) }
    }

    /// A drag move while a button is held (view `mouseDragged`/`rightMouseDragged`). Sent as an
    /// explicit `.mouseDrag` so the host posts a `*MouseDragged` statelessly (no held-button
    /// inference) — the fix for drag-select over the unreliable input channel.
    public func sendMouseDrag(
        button: MouseButton,
        viewPoint: VideoPoint,
        clickCount: UInt8,
        modifiers: InputModifiers,
    ) {
        dbgPointer("drag", viewPoint)
        sendInput(inputEncoder.mouseDrag(
            button: button,
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            clickCount: clickCount,
            modifiers: modifiers,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        ))
    }

    public func sendScroll(dx: Double, dy: Double, viewPoint: VideoPoint) {
        sendInput(inputEncoder.scroll(
            dx: dx,
            dy: dy,
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
        ))
    }

    public func sendKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers) {
        sendInput(inputEncoder.key(keyCode: keyCode, down: down, modifiers: modifiers))
    }

    public func sendText(_ string: String) {
        sendInput(inputEncoder.text(string))
    }

    /// Tells the host to RAISE the captured window to frontmost because this pane was focused on the
    /// client (hover / first-responder). Sent fire-and-forget on the `.control` channel WHILE streaming.
    /// Proactive + idempotent: the host raises once (short-circuiting if already frontmost), so the
    /// user's first click lands instantly without the per-interaction activate-then-control raise stall.
    /// (Replaces the abandoned no-raise background-injection approach.)
    public func sendFocusWindow() {
        guard stateMachine.mediaFlowing else { return }
        transport.send(VideoControlMessage.focusWindow.encode(), on: .control)
    }

    // MARK: Recovery (client → host)

    /// Component 5: sends one logical recovery request as `recoveryRedundancy.copies`
    /// BYTE-IDENTICAL datagrams — the first immediately (unchanged latency), the rest from a
    /// short-lived (≤12 ms) Task spaced `spacing` apart to decorrelate burst loss. The payload is
    /// encoded ONCE by the caller so every copy is byte-equal — the host
    /// `RecoveryRequestDeduper`'s contract (and future-proof for any body layout change).
    /// `transport.send` is sync fire-and-forget on a Sendable transport, so the Task captures
    /// ONLY the transport (never self — it cannot delay session teardown; a send after stop()
    /// is a logged no-op by the transport's fire-and-forget contract).
    private func sendRecoveryRequest(_ payload: Data) {
        transport.send(payload, on: .recovery)
        let extra = Self.recoveryRedundancy.copies - 1
        guard extra > 0 else { return }
        let spacingNs = UInt64(max(0, Self.recoveryRedundancy.spacing) * 1_000_000_000)
        Task { [transport] in
            for _ in 0..<extra {
                try? await Task.sleep(nanoseconds: spacingNs)
                transport.send(payload, on: .recovery)
            }
        }
    }

    private func requestRecovery(lostFrameID: UInt32) {
        // Prefer an LTR refresh over a forced IDR (doc 17 §3.6). Sent on the DEDICATED
        // `.recovery` channel — never `.input` — so the host does not mis-decode a
        // RecoveryMessage (type bytes 1/2/3) as a phantom InputEvent.
        let message = recoveryPolicy.initialRequest(
            lostFrom: lostFrameID,
            lostTo: lostFrameID,
            lastDecoded: frontier.wireValue,
        )
        sendRecoveryRequest(message.encode())
        // Arm the escalation clock on the FIRST request of the episode only; a request
        // sent for each subsequent dropped frame does NOT move it (BUG-H fix), so the
        // 2·RTT window measured from the first request can actually elapse.
        escalation.noteRequestSent(now: FramePacer.currentHostTimeSeconds())
    }

    private func requestIDR() {
        // Component 2: every IDR request carries the decode frontier so the host's delivery-keyed
        // cooldown can grant the casualty bypass (frontier older than a sent keyframe past grace).
        sendRecoveryRequest(RecoveryMessage.requestIDR(lastDecodedFrameID: frontier.wireValue).encode())
        // A forced IDR is still a recovery request: arm the clock if this is the first
        // request of the episode (e.g. an awaiting-keyframe delta drop), but keep the
        // original first-request time if recovery was already outstanding.
        escalation.noteRequestSent(now: FramePacer.currentHostTimeSeconds())
    }

    // MARK: Effects

    private func apply(_ effect: VideoClientStateMachine.Effect) {
        switch effect {
        case let .sendControl(message):
            transport.send(message.encode(), on: .control)
        case let .startDecodePipeline(captureSize, _, fullRange):
            startDecodePipeline(captureSize: captureSize, fullRange: fullRange)
        case .stopDecodePipeline:
            stopDecodePipeline()
        case let .updateCaptureSize(size):
            // The host acked an in-session resize. STAGE the new size; do NOT assign
            // `decodedSize` yet — adopt it only when a decoded CVPixelBuffer actually arrives at
            // it (frame-gated in `noteDecoded`), because in-flight old-size frames may still be
            // queued behind the ack. The decoder auto-reconfigures on the new IDR's parameter
            // sets; we only re-base the aspect-fit denominator once the new pixels land.
            pendingCaptureSize = size
            dbg(
                "resizeAck → pending capture size \(Int(size.width))x\(Int(size.height)) (adopt on matching decoded frame)",
            )
        case let .applyStreamCadence(fps):
            // FPS governor: forward the stream's content cadence to the GUI layer (the pipeline
            // rebases the pacer). Idempotent — the host dup-sends ×2 for loss tolerance.
            dbg("streamCadence → content fps \(fps)")
            // Depth v3: the owd-late threshold scales with the content interval.
            contentIntervalMs = 1000.0 / max(1.0, Double(fps))
            gui.applyStreamCadence?(Int(fps))
        }
    }

    private func startDecodePipeline(captureSize: VideoSize, fullRange: Bool) {
        decodedSize = captureSize
        dbg(
            "decode pipeline up — native(capture)=\(Int(captureSize.width))x\(Int(captureSize.height)) fullRange=\(fullRange); this is the FIXED aspect-fit denominator for the session",
        )
        // 1:1 PIXEL MATCH (2026-06-10 sharpness vs Parsec): the resize debounce only ran from
        // `setLayerSize` (layout passes), and at connect those all land BEFORE mediaFlowing —
        // so the INITIAL pane size was never negotiated and every frame paid a permanent
        // non-integer fit-scale (measured live: native 2662x1658 → drawable 2485x1576 = 0.93×
        // bilinear blur on all text — the "Parsec 1920x1200 nét căng mà mình thì không" gap).
        // Kick the debounce ONCE at stream start so the host AX-resizes the captured window to
        // the pane's point size (capture@2× == drawable px ⇒ zero resample). Guarded so a pane
        // already matching the capture (within the debounce's own minDelta) does not trigger a
        // pointless capture restart at connect.
        //
        // 1:1 PANE SNAP (2026-06-11): this legacy host-follow negotiation runs ONLY for a
        // standalone view (`notifyDecodedPixelSize == nil`). A canvas pane registers the snap
        // hook, and the direction inverts: the PANE adopts the stream's natural size (fired
        // from `noteDecoded` on the first frame's ground-truth pixel dims), so the host window
        // is never disturbed at connect — "pane resizes to match the virtual display", not the
        // other way around.
        if gui.notifyDecodedPixelSize == nil,
           abs(layerSize.width - captureSize.width) >= 8 || abs(layerSize.height - captureSize.height) >= 8
        {
            dbg(
                "resize: initial pane \(Int(layerSize.width))x\(Int(layerSize.height)) ≠ capture \(Int(captureSize.width))x\(Int(captureSize.height)) → negotiating 1:1",
            )
            maybeRequestResize(for: layerSize)
        }
        // WF-6 (#8): set the renderer's color range to the stream's negotiated luma range BEFORE the
        // first frame renders (the helloAck carrying it arrived before any media). The decoder's output
        // pixel-format variant is set below from the SAME bool, so renderer + decoder agree — both
        // derived from the host's actual encoded range. `.video` ⇒ today's coefficients.
        gui.setColorRange(ColorRange(fullRange: fullRange))
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
        // WF-6 (#8): request the NV12 output variant matching the stream's range (set before the
        // decoder's lazy first configure on the first keyframe). `false` ⇒ VideoRange (today).
        decoder.outputFullRange = fullRange
        self.decoder = decoder
        reapplyCursor()
        log
            .info(
                "client decode pipeline up at capture \(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public)",
            )
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
    /// `nil` when no recovery is outstanding. Cleared by ``keyframeDecoded()`` or by
    /// ``frameDecoded(frameID:)`` when a frame NEWER than every loss in the episode decodes.
    public private(set) var firstRequestTime: TimeInterval?

    /// The NEWEST (wrap-aware) frameID declared unrecoverably lost in the current episode, or `nil`
    /// when no loss was attributed (a `requestIDR` from a hard decode failure arms the episode with
    /// no frameID — then ONLY a keyframe can clear it, exactly the old behaviour). Recorded by
    /// ``noteLoss(frameID:)``; lets ``frameDecoded(frameID:)`` recognise a SELF-HEALED stream.
    ///
    /// WHY (2026-06-11 self-heal): the episode used to clear ONLY on a decoded KEYFRAME. But the
    /// WF-8 LTR-refresh recovery frame — and every SELF-HEAL cadence refresh — is a plain P-frame
    /// (`kf=false` on the wire, HW-proven in the ack-ref probe), so a recovery that SUCCEEDED via
    /// refresh left the episode armed and the 2·RTT escalation fired a spurious forced IDR anyway
    /// (a live bug: LTR recovery never actually saved the IDR). A delta that references a LOST
    /// frame cannot decode (VT throws — measured, 9/9 in the probe's baseline arm), so a frame
    /// NEWER than every loss of the episode decoding SUCCESSFULLY proves the chain re-anchored —
    /// keyframe or not.
    public private(set) var maxLostFrameID: UInt32?

    public init() {}

    /// Records one unrecoverably-lost frame of the current episode (wrap-aware keep-newest).
    /// Called by the loss-detection path BEFORE the recovery request is sent.
    public mutating func noteLoss(frameID: UInt32) {
        if let cur = maxLostFrameID, frameID.distanceWrapped(from: cur) <= 0 { return }
        maxLostFrameID = frameID
    }

    /// A NON-keyframe decoded successfully. Ends the episode IFF it is strictly newer than every
    /// recorded loss (it cannot have referenced a lost frame — those throw) AND a loss was actually
    /// attributed. Returns whether the episode was cleared (observability/tests).
    @discardableResult
    public mutating func frameDecoded(frameID: UInt32) -> Bool {
        guard firstRequestTime != nil, let lost = maxLostFrameID,
              frameID.distanceWrapped(from: lost) > 0 else { return false }
        firstRequestTime = nil
        maxLostFrameID = nil
        return true
    }

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
    /// least `2·RTT` (per `policy`) — or, while `observingLoss` (component 5),
    /// `max(1·RTT, floor)` — has elapsed since the FIRST request. Pure — does not
    /// mutate; the caller decides whether to act. `observingLoss` is defaulted so the
    /// historical 3-arg call shape stays byte-identical to today.
    public func shouldEscalate(
        now: TimeInterval,
        rtt: TimeInterval,
        policy: RecoveryPolicy,
        observingLoss: Bool = false,
    ) -> Bool {
        guard let firstRequestTime else { return false }
        return policy.shouldEscalateToIDR(
            elapsedSinceRequest: now - firstRequestTime,
            rtt: rtt,
            observingLoss: observingLoss,
        )
    }

    /// A keyframe decoded — the recovery episode is over unconditionally (a keyframe references
    /// nothing), so disarm the clock. The next loss starts a fresh episode and re-arms it.
    public mutating func keyframeDecoded() {
        firstRequestTime = nil
        maxLostFrameID = nil
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

/// Lock-protected FIFO of inbound datagrams (media + cursor) feeding the client session's single
/// batch-drain consumer. Same discipline as the host's `InboundQueue` / `EncodedFrameQueue`: the
/// transport's serial receive queue appends synchronously (arrival order carried end-to-end), the
/// consumer drains the whole backlog per coalesced wakeup. `@unchecked Sendable` + NSLock.
final class ClientInboundQueue: @unchecked Sendable {
    enum Item {
        case media(VideoChannel, Data)
        case cursor(Data)
    }

    private let lock = NSLock()
    private var items: [Item] = []

    /// Append one datagram. Called on the transport's serial receive queue; O(1), never blocks.
    func append(_ item: Item) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    /// Atomically take and clear the whole backlog (arrival order). An empty result means a
    /// coalesced wakeup whose datagrams an earlier drain already consumed.
    func drainAll() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}
#endif
