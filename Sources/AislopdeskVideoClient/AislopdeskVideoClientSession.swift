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
            viewportCrop: viewportCrop,
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
        /// 1:1 PANE SNAP (2026-06-11; carries POINTS as of 2026-06-16): fired when the decoded
        /// frames' size CHANGES — the session's first decoded frame, or the first frame at a new
        /// capture size after an in-session resize — carrying the HOST WINDOW's POINT size (the
        /// snap target the session derives as `decoded pixels / the inferred host captureScale`,
        /// ``StreamSizeSnap``). The view snaps its canvas pane straight to those points. `nil` ⇒
        /// no pane to snap (a standalone window) → the session keeps the legacy connect-time
        /// host-follow negotiation (`startDecodePipeline` kicks the resize debounce) instead.
        public var notifyStreamNativePoints: (@Sendable (VideoSize) -> Void)?
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
        /// Adaptive playout (2026-06-15): one live network-jitter sample (seconds, the session's
        /// RFC3550 EWMA), fed UNCONDITIONALLY per fragment regardless of pacer mode. The pipeline
        /// folds it into the deadline pacer's adaptive playout buffer (`FramePacer.notePlayoutJitter`)
        /// so the jitter-absorption delay auto-tunes to the link. Synchronous, lock-guarded.
        public var notePlayoutJitter: (@Sendable (Double) -> Void)?
        /// Scroll reprojection (2026-06-16): a host-measured per-frame scroll offset (normalized
        /// ×10000, signed `dx`/`dy`) + the moving-content vertical band (`bandTop`/`bandBottom`,
        /// ten-thousandths of height). The pipeline converts the offset to a reprojector velocity and
        /// hands the band to the renderer so the last frame warps ONLY inside the editor body between
        /// codec frames (`VideoWindowPipeline.applyHostScrollOffset`). `nil` ⇒ no reprojector attached.
        public var applyScrollOffset: (@Sendable (Int16, Int16, UInt16, UInt16) -> Void)?
        /// Content-mask transparency (2026-06-17): the opaque-content rects (capture PIXELS) the host
        /// sent after a DIALOG-EXPAND region change. The pipeline forwards them to the Metal renderer,
        /// which alpha-masks everything OUTSIDE the rects (a popup overhanging the window floats over
        /// the canvas instead of a black bar). An EMPTY list clears the mask. `nil` ⇒ no renderer.
        public var applyContentMask: (@Sendable ([MaskRect]) -> Void)?
        /// ACTUAL-SIZE VIEWPORT (2026-06-30, RealVNC-mobile): fired UNCONDITIONALLY whenever the decoded
        /// size changes (first frame + every host-/grip-driven resize) carrying the HOST WINDOW's POINT
        /// size — the SAME value ``notifyStreamNativePoints`` carries, but WITHOUT the 1:1-pane-snap
        /// semantics (which resizes the pane). The macOS view uses it to auto-pick a zoom that renders the
        /// remote window at its ACTUAL point size inside a FIXED pane viewport (edge-pan reaches the
        /// overflow), so a tiled GUI pane no longer scales the whole window to fit. `nil` ⇒ no view wants
        /// it (iOS uses manual pinch; standalone has no canvas) → byte-identical to before.
        public var notifyDecodedPoints: (@Sendable (VideoSize) -> Void)?
        /// HOST-WINDOW RESIZE (2026-06-30): fired once when the host reports the captured window's MAXIMUM
        /// resizable POINT size (its display bounds). The macOS view forwards it to the model so the
        /// "Resize…" popover caps its width/height fields. `nil` ⇒ no view wants it (iOS / standalone).
        public var notifyDisplayMax: (@Sendable (VideoSize) -> Void)?
        /// RECONNECT-WEDGE FIX (2026-07-03): the HOST ended this session (a received `bye` — daemon
        /// shutdown/restart, VD termination, or the restarted daemon answering an unbound lane). The
        /// pipeline rebuilds the WHOLE pipeline (fresh lane + hello + renderer/pacer/decoder) so a
        /// videohostd restart self-heals instead of freezing the pane with dead input. `nil` ⇒ no
        /// rebuild owner (standalone/preview) — the session just stays stopped.
        public var notifySessionEnded: (@Sendable () -> Void)?
        /// STATS HUD (design-craft pass, 2026-07-04): a ~1 Hz sample for the pane's opt-in diagnostics
        /// overlay — the video-transport smoothed RTT (ms) + the CUMULATIVE frames received /
        /// FEC-recovered / unrecovered since bring-up. Purely informational (drives no policy); `nil` ⇒
        /// no HUD wants it (standalone / preview).
        public var notifyVideoStats: (@Sendable (
            _ rttMS: Double, _ received: UInt64, _ recovered: UInt64, _ lost: UInt64,
        ) -> Void)?
        @preconcurrency
        public init(
            submitDecodedFrame: @escaping @Sendable (CVImageBuffer) -> Void,
            applyCursor: @escaping @Sendable (CursorUpdate, CursorPlacement) -> Void,
            registerCursorShape: @escaping @Sendable (CGImage, VideoSize, UInt16) -> Void,
            setColorRange: @escaping @Sendable (ColorRange) -> Void,
            notifyStreamNativePoints: (@Sendable (VideoSize) -> Void)? = nil,
            applyStreamCadence: (@Sendable (Int) -> Void)? = nil,
            readPacerTelemetry: (@Sendable () -> PacerTelemetrySnapshot)? = nil,
            noteNetworkLate: (@Sendable () -> Void)? = nil,
            notePlayoutJitter: (@Sendable (Double) -> Void)? = nil,
            applyScrollOffset: (@Sendable (Int16, Int16, UInt16, UInt16) -> Void)? = nil,
            applyContentMask: (@Sendable ([MaskRect]) -> Void)? = nil,
            notifyDecodedPoints: (@Sendable (VideoSize) -> Void)? = nil,
            notifyDisplayMax: (@Sendable (VideoSize) -> Void)? = nil,
            notifySessionEnded: (@Sendable () -> Void)? = nil,
            notifyVideoStats: (@Sendable (
                _ rttMS: Double, _ received: UInt64, _ recovered: UInt64, _ lost: UInt64,
            ) -> Void)? = nil,
        ) {
            self.submitDecodedFrame = submitDecodedFrame
            self.applyCursor = applyCursor
            self.registerCursorShape = registerCursorShape
            self.setColorRange = setColorRange
            self.notifyStreamNativePoints = notifyStreamNativePoints
            self.applyStreamCadence = applyStreamCadence
            self.readPacerTelemetry = readPacerTelemetry
            self.noteNetworkLate = noteNetworkLate
            self.notePlayoutJitter = notePlayoutJitter
            self.applyScrollOffset = applyScrollOffset
            self.applyContentMask = applyContentMask
            self.notifyDecodedPoints = notifyDecodedPoints
            self.notifyDisplayMax = notifyDisplayMax
            self.notifySessionEnded = notifySessionEnded
            self.notifyVideoStats = notifyVideoStats
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

    /// DECODE-OFFQUEUE. The synchronous VT decode (~8ms/frame, ``VideoDecoder/decode``) ran ON this
    /// session actor, blocking fragment ingest (+ contending with the 120 Hz cursor / FEC) → the
    /// HW-measured ~98ms ingest-gap jitter on a clean LAN (host send was steady) = the residual
    /// "occasional chậm". When ON, the decode runs on a dedicated SERIAL queue (in submit order → the
    /// pacer still receives frames in order) and only the cheap, order-insensitive post-decode bookkeeping
    /// hops back to the actor; the actor's ingest/reassembly is never blocked by decode.
    ///
    /// DEFAULT ON (2026-06-18 — flip, HW-confirmed smooth). It frees the session actor so input sends +
    /// fragment ingest never queue behind the decode during dense-frame scroll / fast typing. The inline
    /// path costs ~50–100µs LESS per single isolated frame, but that is imperceptible and the actor-free
    /// win dominates whenever frames are dense. The only edge is during a recovery episode (post-loss):
    /// the drop-until-anchor gate reopens one decode-round-trip late (≤1 extra dropped frame + 1
    /// redundant IDR request, self-correcting) — negligible on a non-lossy link. `AISLOPDESK_DECODE_OFFQUEUE=0`
    /// restores the inline-on-actor path. The client analog of the host's encode-offqueue.
    private static let decodeOffQueue = ProcessInfo.processInfo.environment["AISLOPDESK_DECODE_OFFQUEUE"] != "0"
    /// Serial queue owning the off-queue VT decode (incl. its keyframe reconfigure + `invalidateSession`),
    /// so the decoder stays single-threaded. `.userInteractive` to match the latency-critical path.
    private let decodeQueue = DispatchQueue(label: "aislopdesk.client.decode", qos: .userInteractive)
    /// Carries a (single-owner, value-type) ``ReassembledFrame`` across the decode-queue hop Sendable-clean.
    private struct DecodeWork: @unchecked Sendable { let frame: ReassembledFrame }
    /// The decode result hopped back to the actor for bookkeeping. The error is carried as a string so the
    /// hop stays `Sendable`; `.failed` has already run `invalidateSession()` on the decode queue.
    private enum DecodeOutcome { case success, awaitingKeyframe, failed(String) }

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
    /// ACTUAL-SIZE VIEWPORT (per-axis 1:1 crop, 2026-06-30). When non-nil the macOS pane renders the remote
    /// window at its actual point size: the renderer maps this texture sub-rect (UV origin + size, per-axis)
    /// onto the WHOLE drawable, OVERRIDING the fit/zoom/pan path. Stored so the input encoder inverts the
    /// EXACT SAME per-axis crop (clicks land right). `nil` ⇒ the scalar fit/zoom/pan path (unchanged). Kept
    /// in lock-step with `renderer.viewportCrop` via ``setViewportCrop(_:)`` (the pipeline calls both).
    private var viewportCrop: VideoRect?
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

    /// RECONNECT-WEDGE FIX: the hello-retry loop. Over plain UDP the one-shot hello or its ack can
    /// be lost, and after a pipeline rebuild the restarted host may not be listening yet — either
    /// way the session used to wedge in `.connecting` forever. This actor-owned Task re-sends the
    /// hello on the pure ``HelloRetryPolicy`` backoff while the FSM stays `.connecting`, and ends
    /// itself the first time ``VideoClientStateMachine/resendHello()`` returns no effects (the
    /// state resolved — streaming / rejected / stopped). Cancelled in ``stop()``. ⚠️ Timer firing
    /// is real-clock glue; the retry DECISION + cadence are covered by `VideoClientStateMachineTests`
    /// / `HelloRetryPolicyTests`.
    private var helloRetryTask: Task<Void, Never>?

    // MARK: Stall-scrim liveness stamps (2026-07-03, the reconnect-wedge residual)

    /// Uptime (``ProcessInfo/systemUptime`` seconds) of the last VIDEO fragment that arrived, and of
    /// the last successfully-decoded host CONTROL message (the host's 1 s heartbeat keepalive rides
    /// control, but ANY decodable control datagram proves the host is alive). The pipeline's stall
    /// monitor reads both via ``livenessSnapshot()`` and feeds ``StreamStallPolicy`` — no timer here;
    /// the stamps are just writes on paths the actor already runs per datagram.
    private var lastVideoSignalAt: TimeInterval?
    private var lastControlSignalAt: TimeInterval?

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
    /// Smallest remote-window point size the resize popover will request (so a typed value can't collapse
    /// the window to nothing); the host app's own min size still wins above this.
    private static let minResizePoints: Double = 160
    /// The capture size the host acked for an in-session resize, staged until a decoded
    /// `CVPixelBuffer` actually arrives at it (frame-gated adoption). `nil` ⇒ none pending.
    private var pendingCaptureSize: VideoSize?
    /// The pixel dims of the most recently decoded frame — the MAGNITUDE baseline for
    /// frame-gated resize adoption (``ResizeAdoption/shouldAdopt(pending:decoded:previousDecoded:)``).
    /// A genuinely new-size frame is the first whose pixel dims differ from the steady prior size;
    /// an in-flight old-size frame matches the baseline and is rejected. Gated-path-only.
    private var lastDecodedPixelSize: VideoSize?
    /// The HOST's capture scale (decoded PIXELS per window POINT), inferred ONCE from the first
    /// decoded frame (`decoded pixels / the negotiated window points`) and CONSTANT thereafter —
    /// the host captures at a fixed scale; only the window points change on resize. Drives the
    /// 1:1 PANE SNAP target (`decoded / streamCaptureScale` = the host window's point size), so a
    /// 1× no-VD capture on a 2× Retina client no longer halves the pane every resize cycle
    /// (`StreamSizeSnap`). `nil` until the first frame infers it.
    private var streamCaptureScale: Double?
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
    /// NACK / selective-ARQ retransmit (2026-06-18). DEFAULT OFF (`AISLOPDESK_NACK=1`; deploy host +
    /// client together — adds wire recovery type 6). When on, the reassembler HOLDS a FEC-unrecoverable
    /// frame for ``nackGraceFrames`` frame-ids and NACKs its missing fragments; the host re-sends them
    /// from its ring (cheaper than an IDR, and within the playout buffer → no stutter). The
    /// Dropped→LTR-refresh path is still the fallback once the grace expires.
    private static let nackEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_NACK"] == "1"
    /// Frame-ids past the loss frontier a FEC-unrecoverable frame is HELD for a NACK retransmit — must
    /// comfortably exceed the RTT in frame-units (~8 ≈ 130ms at 60fps ≫ a ~21ms WAN RTT, inside the
    /// ~80ms playout buffer).
    private static let nackGraceFrames: Int32 =
        ProcessInfo.processInfo.environment["AISLOPDESK_NACK_GRACE"].flatMap { Int32($0) } ?? 8
    /// Only NACK a SMALL loss (≤ this many fragments) — a keystroke / tiny frame is cheap and
    /// stutter-free to re-send. A BIGGER loss (e.g. a scroll frame) skips to the Drop → LTR-refresh
    /// skip-to-current fallback instead, which is smoother + cheaper than re-sending a stale frame
    /// into a burst (HW-tuned 2026-06-18 after big retransmits added congestion during bursts).
    private static let nackMaxFrags: Int =
        ProcessInfo.processInfo.environment["AISLOPDESK_NACK_MAX_FRAGS"].flatMap(Int.init) ?? 8
    /// Component 3 (delay-gradient): DEFAULT ON; `AISLOPDESK_TREND=0` disables. The client computes a
    /// libwebrtc-style trendline over per-FRAME one-way-delay variation and ships the detector
    /// output in the NetworkStats report. PURE TELEMETRY: the host's gradient cut path is its own
    /// default-OFF gate (`AISLOPDESK_ABR_GRAD`), so with this on the host merely logs trend fields.
    private static let trendEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_TREND"] != "0"
    /// WINDOW-FOLLOWS-PANE (host-follow resize), DEFAULT-OFF. When the pane is resized the client used
    /// to emit a `resizeRequest` so the host AX-resized its real window to match — but with in-place
    /// (no-VD) capture the user wants the remote window to KEEP its own size; the pane just fits/letter-
    /// boxes the fixed stream (and edge-pans when zoomed). Only `AISLOPDESK_GUI_WINDOW_FOLLOWS_PANE=1`
    /// re-enables the old host-follow behaviour.
    private static let windowFollowsPane =
        ProcessInfo.processInfo.environment["AISLOPDESK_GUI_WINDOW_FOLLOWS_PANE"] == "1"
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
    /// STATS HUD (design-craft pass, 2026-07-04): CUMULATIVE since bring-up (never reset per report,
    /// unlike the `win*` window below) — the pane's diagnostics HUD shows totals, not 50 ms windows.
    /// Wrapping adds by idiom (a u64 frame counter cannot realistically wrap; the guard costs nothing).
    private var cumFramesReceived: UInt64 = 0
    private var cumFecRecovered: UInt64 = 0
    private var cumUnrecovered: UInt64 = 0
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
    ///   - fec: FEC scheme matching the host. The DEFAULT is the process's env-gated scheme
    ///     (``AdaptiveFECPolicy/makeFECScheme()``) — the SAME factory the host uses — so the client
    ///     reassembler is built with the SAME `(k, m)`: production `m == 1` (XOR-equivalent) unless
    ///     `AISLOPDESK_FEC_M >= 2` activates the fixed multi-loss `[k + m, k]` code. The reassembler
    ///     derives `m` from this scheme's `parityCount`, so host and client MUST read the same
    ///     `AISLOPDESK_FEC_M` / `AISLOPDESK_FEC_K` and deploy together (the per-group parity count
    ///     changes on the wire when `m > 1`).
    public init(
        requestedWindowID: UInt32,
        viewport: VideoSize,
        transport: any VideoClientTransport,
        gui: GUIHooks,
        fec: FECScheme? = AdaptiveFECPolicy.makeFECScheme(),
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy(),
    ) {
        self.transport = transport
        self.gui = gui
        self.recoveryPolicy = recoveryPolicy
        stateMachine = VideoClientStateMachine(requestedWindowID: requestedWindowID, viewport: viewport)
        reassembler = FrameReassembler(fec: fec)
        // NACK / selective ARQ: hold a FEC-unrecoverable frame for the retransmit grace so a host
        // re-send can fill it (instead of dropping straight to an LTR refresh). Off by default.
        if Self.nackEnabled {
            reassembler.enableRetransmit(grace: Self.nackGraceFrames, maxFrags: Self.nackMaxFrags)
        }
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
        startHelloRetry()
        log.info("video client session started; hello sent")
    }

    /// Starts the hello-retry loop (see ``helloRetryTask``). Mirrors ``startKeepalive()``'s safe
    /// weak pattern; the loop ends itself once the FSM leaves `.connecting`.
    private func startHelloRetry() {
        helloRetryTask?.cancel()
        helloRetryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(HelloRetryPolicy.delay(attempt: attempt) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard await resendHelloIfStillConnecting(attempt: attempt) else { return }
                attempt += 1
            }
        }
    }

    /// One retry tick: re-sends the hello iff the FSM is still `.connecting`. Returns whether the
    /// loop should keep running (false once the state resolved).
    private func resendHelloIfStillConnecting(attempt: Int) async -> Bool {
        let effects = stateMachine.resendHello()
        guard !effects.isEmpty else { return false }
        dbg("hello retry #\(attempt + 1) — still connecting (no ack yet)")
        for effect in effects { await apply(effect) }
        return true
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
        helloRetryTask?.cancel()
        helloRetryTask = nil
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

    // MARK: Stall-scrim liveness snapshot (2026-07-03)

    /// One reading of the session's liveness signals for the pipeline's stall monitor: whether the
    /// FSM is `.streaming`, plus the uptime stamps of the last video fragment and the last decodable
    /// host control message (the host's 1 s heartbeat rides control). All stamps share the
    /// ``ProcessInfo/systemUptime`` clock the monitor evaluates ``StreamStallPolicy`` against.
    public struct LivenessSnapshot: Sendable, Equatable {
        public let streaming: Bool
        public let lastVideoSignalAt: TimeInterval?
        public let lastControlSignalAt: TimeInterval?
    }

    /// The current liveness reading (see ``LivenessSnapshot``).
    public func livenessSnapshot() -> LivenessSnapshot {
        LivenessSnapshot(
            streaming: stateMachine.mediaFlowing,
            lastVideoSignalAt: lastVideoSignalAt,
            lastControlSignalAt: lastControlSignalAt,
        )
    }

    // MARK: Network-feedback telemetry (the network-feedback channel)

    /// Starts the self-owned ~50 ms NetworkStats timer. COPIES ``startKeepalive()``'s safe weak
    /// pattern EXACTLY — a strong `self` capture in a long-lived timer Task would leak the whole
    /// session (decoder, sockets, Metal hooks). Cancelled in ``stop()``.
    private func startNetworkStats() {
        networkStatsTask?.cancel()
        networkStatsTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                await sendNetworkStatsIfStreaming()
                // STATS HUD: publish the cumulative sample every ~1 s (20 × 50 ms), independent of the
                // host-report `telemetryEnabled` gate — the local HUD must work with telemetry off.
                tick += 1
                if tick.isMultiple(of: 20) { await publishHUDStats() }
            }
        }
    }

    /// STATS HUD (design-craft pass, 2026-07-04): one ~1 Hz informational sample for the pane's opt-in
    /// diagnostics overlay — smoothed video-transport RTT (ms) + the cumulative frame counters. Drives
    /// no policy; skipped while media is not flowing (a stale sample would lie).
    private func publishHUDStats() {
        guard stateMachine.mediaFlowing else { return }
        gui.notifyVideoStats?(rttEstimate * 1000, cumFramesReceived, cumFecRecovered, cumUnrecovered)
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
        // Host-follow resize is OFF by default (the remote window keeps its own size; see
        // `windowFollowsPane`). The layer size above still updates the cursor scale + input mapping.
        if Self.windowFollowsPane { maybeRequestResize(for: size) }
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

    /// USER RESIZE (numeric popover) — request an ABSOLUTE host-window POINT size (the value typed in the
    /// "Resize…" popover, already capped at the host-reported display max client-side). Clamps each axis to
    /// a sane minimum and routes the target through the resize debounce's epoch mint so the host AX-resizes
    /// its real window to it (paired with the host's resize-to-display-origin so an up-to-display-max size
    /// actually takes). One request per call (no drag throttle); a no-op when the size is unchanged or the
    /// session is not streaming.
    public func userResizeTo(width: Double, height: Double) {
        guard stateMachine.mediaFlowing else { return }
        let target = VideoSize(
            width: Double.maximum(Self.minResizePoints, width),
            height: Double.maximum(Self.minResizePoints, height),
        )
        guard target != resizeDebounce.lastRequested else { return } // nothing changed → don't respam
        let epoch = resizeDebounce.noteRequested(target)
        dbg("resize-popover: → resizeRequest \(Int(target.width))x\(Int(target.height)) epoch=\(epoch)")
        transport.send(VideoControlMessage.resizeRequest(desired: target, epoch: epoch).encode(), on: .control)
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
        if gui.notifyStreamNativePoints != nil, resizeDebounce.lastRequested == nil {
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

    /// ACTUAL-SIZE VIEWPORT: store the per-axis 1:1 crop so the input encoder inverts the SAME transform
    /// the renderer applies. `nil` restores the scalar fit/zoom/pan mapping. The pipeline calls this in
    /// lock-step with `renderer.viewportCrop`. Re-places the cursor (no-op on macOS — local shape).
    public func setViewportCrop(_ crop: VideoRect?) {
        viewportCrop = crop
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
            // Stall-scrim liveness: any decodable host control message (the 1 s heartbeat keepalive,
            // acks, cadence, …) proves the host is alive — stamp BEFORE the FSM (which deliberately
            // no-ops a keepalive).
            lastControlSignalAt = ProcessInfo.processInfo.systemUptime
            for effect in stateMachine.handleControl(message) { await apply(effect) }
        case let .videoFragment(fragment):
            lastVideoSignalAt = ProcessInfo.processInfo.systemUptime
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
        // Feed the live jitter EWMA to the deadline pacer's adaptive playout buffer — unconditional per
        // fragment (the session estimator is fed regardless of pacer mode; the pacer throttles the
        // recompute to ~1s). No-op when adaptive playout is off / the hook is unbound.
        gui.notePlayoutJitter?(owdJitter.jitterSeconds)
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
            cumFramesReceived &+= 1
            if frame.recoveredViaFEC {
                winFecRecovered &+= 1
                cumFecRecovered &+= 1
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
        // NACK (selective ARQ): drain frames the reassembler is HOLDING for retransmit — FEC-
        // unrecoverable but still inside the retransmit grace — and request exactly the missing data
        // fragments. The host re-sends them from its ring; with the playout buffer ≫ RTT they fill the
        // hole before playout (no stutter). If they don't arrive before the grace expires the frame
        // Drops (above) and the LTR-refresh fallback fires. Inert unless retransmit is enabled.
        while let needed = reassembler.nextNeedsRetransmit() {
            sendNACK(frameID: needed.frameID, fragIndices: needed.frags)
        }
    }

    /// Sends a NACK (selective ARQ) requesting the missing DATA fragments of `frameID` on the
    /// recovery channel — with the same redundancy as a recovery request, so the NACK itself survives
    /// loss. The host answers by re-sending exactly those fragments from its send-history ring.
    private func sendNACK(frameID: UInt32, fragIndices: [UInt16]) {
        dbg("NACK frame #\(frameID): requesting \(fragIndices.count) missing fragment(s)")
        sendRecoveryRequest(
            RecoveryMessage.requestFragments(frameID: frameID, fragIndices: fragIndices).encode(),
        )
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
        cumUnrecovered &+= 1
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
        // The decoded NV12 size becomes the cursor-scale denominator. Cheap, actor-only.
        updateDecodedSize(from: frame)
        if Self.decodeOffQueue {
            // OFF-QUEUE: run the blocking VT decode on the serial decode queue so it never blocks
            // fragment ingest; hop only the (cheap, order-insensitive) bookkeeping back to the actor.
            // `submitDecodedFrame` fires INSIDE decode() in serial order → the pacer still receives
            // frames in order. `invalidateSession` (hard-fail) runs on the queue too, keeping the
            // decoder single-owner.
            let dec = decoder
            let work = DecodeWork(frame: frame)
            decodeQueue.async { [weak self] in
                let outcome: DecodeOutcome
                do {
                    try dec.decode(work.frame)
                    outcome = .success
                } catch VideoDecoderError.awaitingKeyframe {
                    outcome = .awaitingKeyframe
                } catch {
                    dec.invalidateSession() // FIX #3 — on the decode queue (decoder single-owner)
                    outcome = .failed(String(describing: error))
                }
                guard let self else { return }
                Task { await self.finishDecode(work.frame, outcome) }
            }
            return
        }
        // LEGACY (default, byte-identical): inline synchronous decode on the actor.
        let outcome: DecodeOutcome
        do {
            try decoder.decode(frame)
            outcome = .success
        } catch VideoDecoderError.awaitingKeyframe {
            outcome = .awaitingKeyframe
        } catch {
            decoder.invalidateSession() // FIX #3 — rebuild on the next (even byte-identical) keyframe
            outcome = .failed(String(describing: error))
        }
        finishDecode(frame, outcome)
    }

    /// Post-decode bookkeeping (decode-frontier / decode-gate reopen / WF-8 LTR+keyframe ack / self-heal +
    /// escalation clock). Extracted so it runs either inline (legacy) or hopped back from the decode queue
    /// (``decodeOffQueue``). Order-insensitive — the frontier takes the newest id, the ack is per-frame,
    /// the gate reopen + escalation checks are idempotent — so an out-of-order decode-queue hop is safe.
    /// `.failed` has already run `invalidateSession()` (decoder single-owner) before reaching here.
    private func finishDecode(_ frame: ReassembledFrame, _ outcome: DecodeOutcome) {
        switch outcome {
        case .success:
            // Component 2: advance the decode frontier — the context every recovery request carries.
            frontier.noteDecoded(frameID: frame.frameID)
            // Cascade fix: a successful decode may re-open the gate (keyframe / newer-than-every-loss anchor).
            decodeGate.noteDecodeSucceeded(frameID: frame.frameID, keyframe: frame.keyframe)
            // WF-8 + Component-2: ACK every decoded LTR-flagged frame AND every decoded keyframe on the
            // dedicated `.recovery` channel (ACKED-ONLY — we ack only frames we actually decoded) so the
            // host may ForceLTRRefresh against it / fold its recovery-IDR cooldown. Host fold is idempotent.
            if frame.isLTR || frame.keyframe {
                transport.send(RecoveryMessage.ack(streamSeq: frame.frameID).encode(), on: .recovery)
                dbg("acked #\(frame.frameID) (kf=\(frame.keyframe) ltr=\(frame.isLTR)) — decoder now holds it")
            }
            dbgDecodeCount += 1
            if dbgDecodeCount == 1 || dbgDecodeCount.isMultiple(of: 15) {
                dbg("DECODED frame #\(dbgDecodeCount) (keyframe=\(frame.keyframe)) → submitted to pacer/render")
            }
            // SELF-HEAL: a successful NON-keyframe decode newer than every loss in the armed episode proves
            // the chain re-anchored (a delta referencing a lost frame throws) → end the episode, no keyframe.
            if !frame.keyframe, escalation.frameDecoded(frameID: frame.frameID) {
                dbg("recovery episode healed by frame #\(frame.frameID) (no IDR needed)")
            }
            // A successful keyframe ends the recovery episode + measures a real RTT (request→recovering
            // keyframe, clamped [5ms,2s], EWMA-smoothed) and disarms the escalation clock for the next loss.
            if frame.keyframe {
                if let first = escalation.firstRequestTime {
                    let rttSample = FramePacer.currentHostTimeSeconds() - first
                    updateRTTEstimate(min(2.0, max(0.005, rttSample)))
                }
                escalation.keyframeDecoded()
            }
        case .awaitingKeyframe:
            // A delta arrived before the first IDR — drop it + request a keyframe ONCE; the gate absorbs
            // the rest of the pre-IDR deltas (re-requesting at the escalation cadence, not per frame).
            decodeGate.noteAwaitingKeyframe()
            dbg("decode: awaiting keyframe (delta dropped) → requesting IDR")
            requestIDR()
        case let .failed(desc):
            log.error("decode failed: \(desc)")
            // FORENSICS: separate corrupt-complete frames (FEC mis-recovery / truncation) from reference
            // misses. VIDEO-CLIENT-1: a hard failure isn't surfaced by the reassembler (it reported
            // `.completed`), so re-anchor via IDR; the session was already invalidated (FIX #3) so the next
            // byte-identical recovery keyframe rebuilds a fresh session.
            dbg(
                "DECODE FAILED: \(desc) frame=#\(frame.frameID) kf=\(frame.keyframe) ltr=\(frame.isLTR) fec=\(frame.recoveredViaFEC) crisp=\(frame.crisp) bytes=\(frame.avcc.count) gate=\(decodeGate.mode) frontier=\(frontier.wireValue)",
            )
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
        // 1:1 PANE SNAP: surface the host window's POINT size whenever the decoded size changes
        // (first frame of the session, or the first frame at a new capture size). The host's
        // captureScale is not on the wire, but it is CONSTANT and inferable from the first frame
        // (`decoded pixels / the negotiated window points`); reuse it for every later resize.
        // Snapping to `decoded / streamCaptureScale` (= the host window points) — NOT `decoded /
        // the CLIENT contentsScale` — keeps the resize loop gain at 1, so a 1× no-VD capture on a
        // 2× Retina client no longer halves the pane each cycle ("pane cứ bị co nhỏ").
        if previous != decoded {
            // The window points for THIS decoded size: the in-flight resize ack's `pending`
            // (a resize just landed), else the session's current `decodedSize` (first frame).
            let windowPoints = pendingCaptureSize ?? decodedSize
            if streamCaptureScale == nil {
                streamCaptureScale = StreamSizeSnap.inferredCaptureScale(
                    decodedPixels: decoded, windowPoints: windowPoints,
                )
            }
            let nativePoints = StreamSizeSnap.targetPoints(
                pixelSize: decoded, captureScale: streamCaptureScale ?? 1,
            )
            gui.notifyStreamNativePoints?(nativePoints)
            // ACTUAL-SIZE VIEWPORT: surface the host window's POINT size to the view UNCONDITIONALLY (no
            // snap coupling) so the macOS pane can auto-zoom the stream to 1:1 inside a fixed viewport.
            gui.notifyDecodedPoints?(nativePoints)
            // HOST-INITIATED RESIZE denominator refresh (the "cursor lệch khi resize" fix):
            // `decodedSize` is the aspect-fit DENOMINATOR the pointer/cursor mapping inverts, but it is
            // otherwise only adopted on a CLIENT-initiated resize ack (`pendingCaptureSize`, below). When
            // the remote window is resized by ANY other means — the user dragging the window's own corner,
            // an app-driven resize — no ack is pending, so the denominator would stay STALE at the old
            // size while the renderer already draws the new frame, and `InputEventEncoder.normalize`
            // letterboxes against the wrong aspect → clicks land offset (worse the more the aspect
            // changed). Adopt the live native point size as the denominator whenever NO client resize is
            // in flight, so input/cursor mapping always matches what is on screen.
            if pendingCaptureSize == nil, nativePoints.width > 0, nativePoints.height > 0 {
                decodedSize = nativePoints
                reapplyCursor()
            }
        }
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
            viewportCrop: viewportCrop,
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
            viewportCrop: viewportCrop,
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
            viewportCrop: viewportCrop,
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
            viewportCrop: viewportCrop,
        ))
    }

    public func sendScroll(
        dx: Double,
        dy: Double,
        viewPoint: VideoPoint,
        scrollPhase: UInt8 = 0,
        momentumPhase: UInt8 = 0,
        continuous: Bool = false,
    ) {
        sendInput(inputEncoder.scroll(
            dx: dx,
            dy: dy,
            viewPoint: viewPoint,
            layerSize: layerSize,
            videoNativeSize: decodedSize,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            continuous: continuous,
            zoom: zoom,
            pan: pan,
            mode: contentMode,
            viewportCrop: viewportCrop,
        ))
    }

    public func sendKey(keyCode: UInt16, down: Bool, modifiers: InputModifiers) {
        // Build ONCE, send `keySendCount` times (C5 BUG B): a MODIFIER key-up gets the same
        // loss-resilient redundancy as `sendMouseUp` — a lost modifier release permanently latches
        // the flag on the host's shared `hidSystemState` source (every later plain scroll becomes
        // ⌘-scroll) until the user happens to press+release that modifier again. Same bytes each
        // time: the host's `InputButtonBalance` posts the FIRST and suppresses the duplicates, so
        // the redundancy never becomes a spurious extra modifier edge. Everything else stays a
        // single datagram (an ordinary key-up loss is a visible, self-healing miss).
        let event = inputEncoder.key(keyCode: keyCode, down: down, modifiers: modifiers)
        for _ in 0..<Self.keySendCount(keyCode: keyCode, down: down) { sendInput(event) }
    }

    /// Pure send-count policy for one key event: `redundantUpCount` for a HELD-modifier key-UP
    /// (⌘/⇧/⌃/⌥/fn — see ``InputModifierKeys``), else 1. Caps Lock and ordinary keys are never
    /// duplicated (Caps is a toggle; a duplicated edge would flip it twice on a host that missed
    /// the dedup). Static + pure so the policy is pinned headlessly (`InputKeyRedundancyTests`).
    static func keySendCount(keyCode: UInt16, down: Bool) -> Int {
        (!down && InputModifierKeys.isHeldModifier(keyCode)) ? redundantUpCount : 1
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
        case let .applyScrollOffset(dx, dy, bandTop, bandBottom):
            // Scroll reprojection: forward the host-measured normalized offset + moving-content band to
            // the GUI layer (the pipeline converts the offset to a reprojector velocity and hands the
            // band to the renderer's chrome-region mask).
            gui.applyScrollOffset?(dx, dy, bandTop, bandBottom)
        case let .applyContentMask(rects):
            // Transparency mask after a DIALOG-EXPAND region change: forward the opaque-content rects
            // to the GUI layer (the renderer alpha-masks everything outside them). Empty ⇒ clear.
            dbg("contentMask → \(rects.count) opaque rect(s)")
            gui.applyContentMask?(rects)
        case let .applyDisplayMax(size):
            // HOST-WINDOW RESIZE: forward the captured window's display max (points) to the view → model
            // so the "Resize…" popover caps its width/height fields at a size the remote can adopt.
            dbg("displayMax → max resize \(Int(size.width))x\(Int(size.height))pt")
            gui.notifyDisplayMax?(size)
        case .sessionEndedByHost:
            // RECONNECT-WEDGE FIX: the host ended this session (bye) — surface it so the pipeline
            // rebuilds (fresh lane + hello + presentation path). The FSM is already `.stopped`, so
            // the keepalive/stats timers self-quiesce on their mediaFlowing gates; the rebuild's
            // deactivate → stop() then cancels them and closes the lane.
            dbg("session ended by HOST (bye) → notifying pipeline for a full rebuild")
            gui.notifySessionEnded?()
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
        // standalone view (`notifyStreamNativePoints == nil`). A canvas pane registers the snap
        // hook, and the direction inverts: the PANE adopts the stream's natural size (the host
        // window's POINT size, fired from `noteDecoded` on the first frame), so the host window
        // is never disturbed at connect — "pane resizes to match the virtual display", not the
        // other way around.
        // KEEP-ORIGINAL-SIZE (no-VD in-place capture, task #4): the connect-time host-follow negotiation
        // AX-resizes the remote window to the pane's size for a 1:1 sharp capture — but with in-place
        // capture the user wants the remote window to KEEP its own size (the pane just `.fit`-letterboxes
        // it and pinch-zoom/edge-pan reach detail). Left on, it also BOUNCED the window back to the pane
        // size right after a manual corner-drag resize, fighting the user. So it now runs ONLY when the
        // host-follow opt-in (`windowFollowsPane`) is set; default-off keeps the window untouched.
        if Self.windowFollowsPane, gui.notifyStreamNativePoints == nil,
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
