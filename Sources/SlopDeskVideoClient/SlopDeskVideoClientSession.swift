#if canImport(VideoToolbox) && canImport(Metal) && canImport(QuartzCore)
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import OSLog
import QuartzCore
import SlopDeskVideoProtocol

/// A ~2 Hz CLIENT-LOCAL aggregate of the ~50 ms network-telemetry windows — the pane's live
/// stats mirror. The 50 ms wire report to the host is untouched; this is a second, slower
/// consumer of the same counters (rates over the aggregated window) plus the latest host-stamp
/// hold and the pacer's live depth. Primitives only, so the seam can forward it headlessly.
public struct ClientNetworkStatsSnapshot: Sendable, Equatable {
    /// Complete frames received per second over the aggregation window.
    public let framesPerSecond: Double
    /// Frames completed via FEC recovery per second.
    public let fecRecoveredPerSecond: Double
    /// Frames declared unrecoverably lost per second.
    public let unrecoveredPerSecond: Double
    /// The latest `clientHoldMs` (ms since the newest observed host send stamp — the same
    /// client-local delta the wire report carries; 0 when telemetry is off / nothing observed).
    public let holdMillis: Int
    /// The pacer's live presentation depth (0 = no pacer attached).
    public let pacerDepth: Int

    public init(
        framesPerSecond: Double,
        fecRecoveredPerSecond: Double,
        unrecoveredPerSecond: Double,
        holdMillis: Int,
        pacerDepth: Int,
    ) {
        self.framesPerSecond = framesPerSecond
        self.fecRecoveredPerSecond = fecRecoveredPerSecond
        self.unrecoveredPerSecond = unrecoveredPerSecond
        self.holdMillis = holdMillis
        self.pacerDepth = pacerDepth
    }
}

/// The client-side session orchestrator for the GUI video path (PATH 2) — the exact mirror of
/// `SlopDeskVideoHost.SlopDeskVideoHostSession`.
///
/// The pipeline it wires:
///
/// ```
/// UDP media datagrams ─▶ ReceivedDatagramRouter
///   ├─ control  ─▶ VideoClientStateMachine (hello/helloAck/bye)
///   ├─ video    ─▶ FrameReassembler ─▶ FECScheme ─▶ VideoDecoder (VTDecompressionSession)
///   │                                            ─▶ FramePacer ─▶ MetalVideoRenderer
///   ├─ geometry ─▶ window move/resize/title (drives the host view layout)
///   └─ audio    ─▶ AudioStreamDecoder ─▶ AudioJitterBuffer ─▶ AudioPlaybackEngine (output AU)
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
public actor SlopDeskVideoClientSession {
    private let log = Logger(subsystem: "slopdesk.video.client", category: "SlopDeskVideoClientSession")

    /// Opt-in stderr diagnostics (`SLOPDESK_VIDEO_DEBUG=1`), client counterpart to the host's — so
    /// `scripts/check-video.sh` sees datagram arrival / reassembly / decode (OSLog `.info` isn't
    /// persisted; a white client window is otherwise opaque). No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil
    /// Redundancy for the critical RELEASE edge: a dropped `mouseUp` over plain UDP strands the target
    /// app mid-selection, so we send the up back-to-back. Idempotent on the host: button-balance posts
    /// the FIRST up (which releases the held button) and SUPPRESSES the duplicates — no spurious extra
    /// `*MouseUp`.
    private static let redundantUpCount = 3
    private var dbgMediaCount = 0
    private var dbgDecodeCount = 0
    private var dbgPointerCount = 0
    /// Monotonic time of the last cursor datagram RECEIVED on this (session) actor. The host/net
    /// side of the freeze probe — see ``dbgNoteCursorRx()``.
    private var dbgLastCursorRx: Double = 0
    /// Monotonic time of the last VIDEO datagram received — to detect a host capture stall (a gap in
    /// video arrival) distinct from a client main-actor block.
    private var dbgLastMediaRx: Double = 0
    private nonisolated func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("SlopDesk[video.client]: \(message())\n".utf8))
    }

    /// Diagnostics for the input-coordinate path (`SLOPDESK_VIDEO_DEBUG`): prints view point,
    /// on-screen layer size, aspect-fit NATIVE size, the displayed-video sub-rect, and the
    /// normalised 0..1 the host receives — so a report of wrong click coordinates or the video not
    /// filling the pane is root-caused from the log instead of guessed. Moves are sampled 1-in-30; every button-down / drag / up is
    /// logged.
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

    /// GUI hand-off seams (provided by `VideoWindowPipeline`). The renderer / cursor compositor /
    /// display link are `@MainActor`-isolated (they touch `CAMetalLayer` / `CALayer` / a display
    /// link), so the actor never holds them directly — it calls these `@Sendable` closures. The
    /// decoded NV12 frame goes to the pipeline-owned pacer (most-recent-wins), rendered at the display
    /// link's vsync. Keeps the orchestrator pure-actor + Sendable-clean, GUI objects main-confined.
    public struct GUIHooks: Sendable {
        /// Hand a freshly decoded NV12 buffer to the (pipeline-owned) frame pacer.
        public var submitDecodedFrame: @Sendable (CVImageBuffer) -> Void
        /// Place the cursor overlay through the aspect-fit + zoom/pan render transform
        /// (the same geometry the input encoder inverts) so the overlay tracks where a
        /// click actually lands.
        public var applyCursor: @Sendable (CursorUpdate, CursorPlacement) -> Void
        /// Register a cursor shape bitmap for its shapeID (shipped rarely, OOB).
        public var registerCursorShape: @Sendable (CGImage, VideoSize, UInt16) -> Void
        /// Set the renderer's YCbCr→RGB color range to the stream's negotiated luma range. Called once
        /// at pipeline bring-up, BEFORE the first frame renders (the `helloAck` carrying the range
        /// arrives before any media).
        public var setColorRange: @Sendable (ColorRange) -> Void
        /// 1:1 PANE SNAP (carries POINTS): fired when the decoded size CHANGES (first decoded frame, or
        /// first frame at a new capture size after an in-session resize), carrying the HOST WINDOW's
        /// POINT size (snap target = `decoded pixels / inferred host captureScale`, ``StreamSizeSnap``).
        /// The view snaps its canvas pane to those points. `nil` ⇒ no pane to snap (standalone window)
        /// → the session falls back to the connect-time host-follow negotiation (`startDecodePipeline`
        /// kicks the resize debounce).
        public var notifyStreamNativePoints: (@Sendable (VideoSize) -> Void)?
        /// FPS GOVERNOR: the host announced the stream's CONTENT cadence (fps) — at session start and on
        /// every governed step. The pipeline rebases the pacer's deadline-mode interval +
        /// adaptive-jitter seconds→frames conversion (`FramePacer.setContentFps`). `nil` ⇒ ignore (a
        /// view with no pacer to rebase). Idempotent — the host dup-sends ×2.
        public var applyStreamCadence: (@Sendable (Int) -> Void)?
        /// STREAM BITRATE (titlebar complication): the client-measured VIDEO-PAYLOAD bitrate
        /// (kilobits/sec), reported ~1 Hz from the reassembled-frame byte window. Payload-level (the
        /// decoder's diet — FEC parity/headers/dups excluded). `nil` ⇒ no view wants it.
        public var applyStreamBitrate: (@Sendable (Int) -> Void)?
        /// NETWORK-STATS MIRROR (~2 Hz): a client-local aggregate of the ~50 ms telemetry windows
        /// (``ClientNetworkStatsSnapshot``) for the pane's stats surface. A LOCAL GUI reading like
        /// ``applyStreamBitrate`` — never a wire report; the 50 ms host report cadence is
        /// untouched. `nil` ⇒ no view wants it.
        public var applyNetworkStats: (@Sendable (ClientNetworkStatsSnapshot) -> Void)?
        /// NON-DRAINING pacer-depth read for the stats mirror (`FramePacer.currentDepth`). The
        /// wire report's ``readPacerTelemetry`` DRAINS its counters exactly once per report, so
        /// the mirror must not share it — it reads this gauge instead. `nil` ⇒ no pacer (depth 0).
        public var readPacerDepth: (@Sendable () -> Int)?
        /// Adaptive pacer depth: SYNCHRONOUS, lock-guarded drain of the pipeline-owned FramePacer's
        /// presentation-health counters (`FramePacer.drainTelemetry`). Safe to call from the session
        /// actor with NO main hop — the pacer is `@unchecked Sendable` behind its own NSLock.
        /// `nil` ⇒ no pacer attached (depth 0 on the wire).
        public var readPacerTelemetry: (@Sendable () -> PacerTelemetrySnapshot)?
        /// One NETWORK-late event — a frame whose one-way delay spiked past the rolling baseline by more
        /// than the late threshold (`OwdLateDetector`). The pipeline folds it into the pacer's depth
        /// policy (`FramePacer.noteNetworkLate`); it is the PROMOTION source for the adaptive 1↔2 depth
        /// boost. A present-gap classifier is NOT usable here — natural sub-cadence content reads as
        /// permanently "late" under it, pinning depth at 2. Synchronous, lock-guarded, callable from the
        /// session actor like `readPacerTelemetry`.
        public var noteNetworkLate: (@Sendable () -> Void)?
        /// Adaptive playout: one live network-jitter sample (seconds, the session's RFC3550 EWMA), fed
        /// UNCONDITIONALLY per fragment regardless of pacer mode. The pipeline folds it into the
        /// deadline pacer's adaptive playout buffer (`FramePacer.notePlayoutJitter`) so the
        /// jitter-absorption delay auto-tunes to the link. Synchronous, lock-guarded.
        public var notePlayoutJitter: (@Sendable (Double) -> Void)?
        /// Scroll reprojection: a host-measured per-frame scroll offset (normalized ×10000, signed
        /// `dx`/`dy`) + the moving-content vertical band (`bandTop`/`bandBottom`, ten-thousandths of
        /// height). The pipeline converts the offset to a reprojector velocity and hands the band to the
        /// renderer so the last frame warps ONLY inside the editor body between codec frames
        /// (`VideoWindowPipeline.applyHostScrollOffset`). `nil` ⇒ no reprojector attached.
        public var applyScrollOffset: (@Sendable (Int16, Int16, UInt16, UInt16) -> Void)?
        /// Content-mask transparency: the opaque-content rects (capture PIXELS) the host sent after a
        /// DIALOG-EXPAND region change. The pipeline forwards them to the Metal renderer, which
        /// alpha-masks everything OUTSIDE the rects (a popup overhanging the window floats over the
        /// canvas instead of a black bar). An EMPTY list clears the mask. `nil` ⇒ no renderer.
        public var applyContentMask: (@Sendable ([MaskRect]) -> Void)?
        /// ACTUAL-SIZE VIEWPORT: fired UNCONDITIONALLY when the decoded size changes (first frame +
        /// every host-/grip-driven resize), carrying the HOST WINDOW's POINT size — same value as
        /// ``notifyStreamNativePoints`` but WITHOUT the 1:1-pane-snap (which resizes the pane). The
        /// macOS view auto-picks a zoom rendering the remote window at ACTUAL point size inside a FIXED
        /// pane viewport (edge-pan reaches the overflow), so a tiled GUI pane does not scale the whole
        /// window to fit. `nil` ⇒ no view wants it (iOS pinch; standalone has no canvas).
        public var notifyDecodedPoints: (@Sendable (VideoSize) -> Void)?
        /// HOST-WINDOW RESIZE: fired once when the host reports the captured window's MAXIMUM resizable
        /// POINT size (its display bounds). The macOS view forwards it to the model so the "Resize…"
        /// popover caps its width/height fields. `nil` ⇒ no view wants it (iOS / standalone).
        public var notifyDisplayMax: (@Sendable (VideoSize) -> Void)?
        /// The HOST ended this session (a received `bye` — daemon shutdown/restart, VD termination, or
        /// the restarted daemon answering an unbound lane). The pipeline rebuilds the WHOLE pipeline
        /// (fresh lane + hello + renderer/pacer/decoder) so a videohostd restart self-heals instead of
        /// freezing the pane with dead input. `nil` ⇒ no rebuild owner (standalone/preview) — the
        /// session just stays stopped.
        public var notifySessionEnded: (@Sendable () -> Void)?
        /// The host REFUSED this session (`helloAck(accepted: false)` — window gone / version
        /// mismatch). TERMINAL, non-retrying: unlike ``notifySessionEnded`` the pipeline must NOT
        /// rebuild + re-hello (that re-sends the same doomed request forever) — it tears down and
        /// surfaces the failure to the pane (picker/error). `nil` ⇒ no owner (standalone/preview).
        public var notifySessionRejected: (@Sendable () -> Void)?
        /// SWIPE-NAV STATUS (cursor socket type=3, ~2 Hz + on frontmost change): whether the host's
        /// ⌘[/⌘] swipe translation would currently accept a gesture, plus its recogniser knobs —
        /// the macOS view gates + configures its peel-feedback mirror from this (doc 05 §8). The
        /// client stays NOT-eligible until the first push arrives (old host ⇒ no overlay, never a
        /// lying affordance). `nil` ⇒ no view wants it (iOS / standalone).
        public var applySwipeNavStatus: (@Sendable (SwipeNavStatusMessage) -> Void)?
        @preconcurrency
        public init(
            submitDecodedFrame: @escaping @Sendable (CVImageBuffer) -> Void,
            applyCursor: @escaping @Sendable (CursorUpdate, CursorPlacement) -> Void,
            registerCursorShape: @escaping @Sendable (CGImage, VideoSize, UInt16) -> Void,
            setColorRange: @escaping @Sendable (ColorRange) -> Void,
            notifyStreamNativePoints: (@Sendable (VideoSize) -> Void)? = nil,
            applyStreamCadence: (@Sendable (Int) -> Void)? = nil,
            applyStreamBitrate: (@Sendable (Int) -> Void)? = nil,
            applyNetworkStats: (@Sendable (ClientNetworkStatsSnapshot) -> Void)? = nil,
            readPacerDepth: (@Sendable () -> Int)? = nil,
            readPacerTelemetry: (@Sendable () -> PacerTelemetrySnapshot)? = nil,
            noteNetworkLate: (@Sendable () -> Void)? = nil,
            notePlayoutJitter: (@Sendable (Double) -> Void)? = nil,
            applyScrollOffset: (@Sendable (Int16, Int16, UInt16, UInt16) -> Void)? = nil,
            applyContentMask: (@Sendable ([MaskRect]) -> Void)? = nil,
            notifyDecodedPoints: (@Sendable (VideoSize) -> Void)? = nil,
            notifyDisplayMax: (@Sendable (VideoSize) -> Void)? = nil,
            notifySessionEnded: (@Sendable () -> Void)? = nil,
            notifySessionRejected: (@Sendable () -> Void)? = nil,
            applySwipeNavStatus: (@Sendable (SwipeNavStatusMessage) -> Void)? = nil,
        ) {
            self.submitDecodedFrame = submitDecodedFrame
            self.applyCursor = applyCursor
            self.registerCursorShape = registerCursorShape
            self.setColorRange = setColorRange
            self.notifyStreamNativePoints = notifyStreamNativePoints
            self.applyStreamCadence = applyStreamCadence
            self.applyStreamBitrate = applyStreamBitrate
            self.applyNetworkStats = applyNetworkStats
            self.readPacerDepth = readPacerDepth
            self.readPacerTelemetry = readPacerTelemetry
            self.noteNetworkLate = noteNetworkLate
            self.notePlayoutJitter = notePlayoutJitter
            self.applyScrollOffset = applyScrollOffset
            self.applyContentMask = applyContentMask
            self.notifyDecodedPoints = notifyDecodedPoints
            self.notifyDisplayMax = notifyDisplayMax
            self.notifySessionEnded = notifySessionEnded
            self.notifySessionRejected = notifySessionRejected
            self.applySwipeNavStatus = applySwipeNavStatus
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

    /// DECODE-OFFQUEUE (DEFAULT ON, `SLOPDESK_DECODE_OFFQUEUE=0` forces inline). The synchronous VT
    /// decode (~8ms/frame, ``VideoDecoder/decode``) running ON this session actor blocks fragment
    /// ingest and contends with the 120 Hz cursor / FEC → HW-measured ~98ms ingest-gap jitter on a
    /// clean LAN (host send steady). When ON, decode runs on a dedicated SERIAL queue (submit order →
    /// the pacer still receives frames in order) and only the cheap, order-insensitive post-decode
    /// bookkeeping hops back to the actor; ingest/reassembly is never blocked by decode, so input sends
    /// + fragment ingest never queue behind decode during dense-frame scroll / fast typing.
    ///
    /// The inline path costs ~50–100µs LESS per ISOLATED frame (imperceptible; the actor-free win
    /// dominates once frames are dense). Only edge: during a recovery episode the drop-until-anchor
    /// gate reopens one decode-round-trip late (≤1 extra dropped frame + 1 redundant IDR,
    /// self-correcting) — negligible on a non-lossy link. Client analog of the host's encode-offqueue.
    private static let decodeOffQueue = ProcessInfo.processInfo.environment["SLOPDESK_DECODE_OFFQUEUE"] != "0"
    /// Serial queue owning the off-queue VT decode (incl. its keyframe reconfigure + `invalidateSession`),
    /// so the decoder stays single-threaded. `.userInteractive` to match the latency-critical path.
    private let decodeQueue = DispatchQueue(label: "slopdesk.client.decode", qos: .userInteractive)
    /// Carries a (single-owner, value-type) ``ReassembledFrame`` across the decode-queue hop Sendable-clean.
    private struct DecodeWork: @unchecked Sendable { let frame: ReassembledFrame }
    /// Bounds the compressed frames in flight on ``decodeQueue`` (each queued block retains its full
    /// AVCC `Data`): a wedged synchronous VT decode must not accumulate frames at wire rate. A frame
    /// past the budget is dropped BEFORE dispatch through the drop-until-anchor gate + IDR request —
    /// the same recovery a wire loss takes, so the stream re-syncs on the next admitted anchor.
    private var decodeBudget = DecodeAdmissionBudget()
    /// Debug counter for budget drops (mirrors ``dbgGateDrops``).
    private var dbgBudgetDrops: UInt64 = 0
    /// The decode result hopped back to the actor for bookkeeping. The error is carried as a string so the
    /// hop stays `Sendable`; `.failed` has already run `invalidateSession()` on the decode queue.
    private enum DecodeOutcome { case success, awaitingKeyframe, failed(String) }

    // MARK: App audio (channel 6)

    /// Serial queue owning ALL AudioToolbox work — the AAC-ELD `AudioConverter` decode and the
    /// output-AU lifecycle — the audio mirror of ``decodeQueue``: a converter call must never
    /// block fragment ingest / input sends on this actor. The engine's lock-free sample ring is
    /// the only state shared past this queue (the render callback consumes it wait-free).
    private let audioQueue = DispatchQueue(label: "slopdesk.client.audio", qos: .userInteractive)
    /// The audio config in force. The host re-sends it ~1 s apart (loss tolerance), so the
    /// decoder/engine rebuild below fires only when a received config actually DIFFERS.
    private var audioConfig: AudioStreamConfig?
    /// Decodes wire payloads → interleaved Float32 on ``audioQueue``. Rebuilt on config change;
    /// `nil` until the first config locks the stream parameters.
    private var audioDecoder: AudioStreamDecoder?
    /// Monotonic stamp for the OFF-ACTOR decoder build (`AudioConverterNew` runs on
    /// ``audioQueue``): bumped by every build dispatch and by pipeline teardown, and checked at
    /// install-back, so a stale build can never overwrite a newer config's decoder (or resurrect
    /// a torn-down pipeline).
    private var audioConfigGeneration = 0
    /// The config whose decoder build is in flight on ``audioQueue`` (`nil` when none) — the ~1 s
    /// config re-send must not queue a duplicate `AudioConverter` build while the first runs.
    private var audioPendingConfig: AudioStreamConfig?
    /// Output AU + jitter ring, one per locked `(sampleRate, channels)`. Started lazily on the
    /// first config while enabled; stopped on disable, invalidated with the pipeline.
    private var audioEngine: AudioPlaybackEngine?

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
    /// ACTUAL-SIZE VIEWPORT (per-axis 1:1 crop). When non-nil the macOS pane renders the remote window
    /// at its actual point size: the renderer maps this texture sub-rect (UV origin + size, per-axis)
    /// onto the WHOLE drawable, OVERRIDING the fit/zoom/pan path. Stored so the input encoder inverts the
    /// EXACT SAME per-axis crop (clicks land right). `nil` ⇒ the scalar fit/zoom/pan path. Kept in
    /// lock-step with `renderer.viewportCrop` via ``setViewportCrop(_:)`` (the pipeline calls both).
    private var viewportCrop: VideoRect?
    /// The most recent host cursor position, re-applied whenever the scale changes so
    /// a layout/resize re-places the overlay without waiting for the next cursor packet.
    private var lastCursorUpdate: CursorUpdate?
    /// Cursor-shape self-heal: decides when to re-request a shape bitmap the client is
    /// missing (its one-shot shipment was lost / over-MTU). A position update referencing an
    /// unknown shapeID triggers a `requestCursorShape` on the recovery channel; the decision is
    /// debounced per id so the ~120 Hz position stream cannot flood the channel. Pure type.
    private var shapeRequests = CursorShapeRequestTracker()

    /// The self-owned keepalive timer (NOT the 33 ms `motionPump` in `VideoWindowPipeline` —
    /// that is far too fast + main-actor-bound). A separate, slow (5 s,
    /// ``KeepaliveTiming/keepaliveInterval``) actor-owned `Task` that sends a zero-body
    /// `keepalive` on the control channel while streaming, so the host's idle-timeout reaper can
    /// tell a quiet-but-alive client from a crashed one (a crash never sends a `bye`).
    /// Cancelled in ``stop()``. ⚠️ Timer firing is [MS-confirm] (real-clock glue); the reap
    /// DECISION it feeds is covered by `IdleReapDeciderTests`.
    private var keepaliveTask: Task<Void, Never>?

    /// The hello-retry loop. Over plain UDP the one-shot hello or its ack can be lost, and after a
    /// pipeline rebuild the restarted host may not be listening yet — without a retry either case
    /// wedges the session in `.connecting` forever. This actor-owned Task re-sends the
    /// hello on the pure ``HelloRetryPolicy`` backoff while the FSM stays `.connecting`, and ends
    /// itself the first time ``VideoClientStateMachine/resendHello()`` returns no effects (the
    /// state resolved — streaming / rejected / stopped). Cancelled in ``stop()``. ⚠️ Timer firing
    /// is real-clock glue; the retry DECISION + cadence are covered by `VideoClientStateMachineTests`
    /// / `HelloRetryPolicyTests`.
    private var helloRetryTask: Task<Void, Never>?

    // MARK: Stall-scrim liveness stamps

    /// Uptime (``ProcessInfo/systemUptime`` seconds) of the last VIDEO fragment that arrived, and of
    /// the last successfully-decoded host CONTROL message (the host's 1 s heartbeat keepalive rides
    /// control, but ANY decodable control datagram proves the host is alive). The pipeline's stall
    /// monitor reads both via ``livenessSnapshot()`` and feeds ``StreamStallPolicy`` — no timer here;
    /// the stamps are just writes on paths the actor already runs per datagram.
    private var lastVideoSignalAt: TimeInterval?
    private var lastControlSignalAt: TimeInterval?

    /// Single batch-drain consumer of the inbound datagram queue (see ``start()``). Mirrors the
    /// host's `InboundQueue` pump. A per-datagram `Task { await receive… }` fan-out is NOT viable:
    /// ≈3000 Task spawns/sec at 60fps × ~50 fragments is pure scheduler overhead, the per-fragment
    /// actor hops add ~1.5ms of reassembly-completion latency + jitter per frame, and datagrams can
    /// race into the actor out of arrival order.
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
    /// 1:1 PANE SNAP target (`decoded / streamCaptureScale` = the host window's point size), which is
    /// what keeps a 1× no-VD capture on a 2× Retina client from HALVING the pane every resize cycle
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
    /// keyframe decodes. Polled by ``shouldEscalateToIDR()``. "FIRST request" (not "last
    /// request") is load-bearing: resetting the clock on EVERY dropped frame means 2·RTT
    /// never elapses under sustained loss, so the guaranteed-recovery forced IDR never fires
    /// (``LTREscalationTracker``).
    private var escalation = LTREscalationTracker()
    /// The loss-observing predicate gating the HALVED escalation clock. Fed by every unrecoverable
    /// loss AND every FEC-recovered completion (the early-warning channel), read by
    /// ``shouldEscalateToIDR()``.
    private var lossWindow = LossObservationWindow()
    /// `SLOPDESK_RECOVERY_REDUNDANCY` — total byte-identical copies per logical recovery request
    /// (default 3, clamped 1...5 by the init; 1 = a single send). Copies are spaced 3 ms apart to
    /// decorrelate burst loss; the host's `RecoveryRequestDeduper` collapses them to one action
    /// (spread ≤ half its 25 ms window at every legal copies count).
    private static let recoveryRedundancy: RecoveryRequestRedundancy = {
        let n = ProcessInfo.processInfo.environment["SLOPDESK_RECOVERY_REDUNDANCY"].flatMap(Int.init) ?? 3
        return RecoveryRequestRedundancy(copies: n)
    }()

    /// `SLOPDESK_FAST_ESCALATION` (default ON; "0" disables) — halve the IDR escalation clock to
    /// `max(1·RTT, 60 ms, 1.5·RTT)` while ``lossWindow`` is observing loss (floor tunable via
    /// `SLOPDESK_ESCALATION_FLOOR_MS`; the floor must not go as low as 30 ms — that escalates
    /// before an LTR refresh can physically land). Off ⇒ `observingLoss` is forced false and
    /// escalation runs the plain 2·RTT clock.
    private static let fastEscalationEnabled = ProcessInfo.processInfo.environment["SLOPDESK_FAST_ESCALATION"] != "0"
    /// The wrap-aware highest successfully-DECODED frameID. Carried (as ``DecodeFrontier/wireValue``)
    /// on every `requestIDR` / `requestLTRRefresh` so the host's delivery-keyed recovery-IDR cooldown
    /// can distinguish a delivered keyframe from a casualty.
    private var frontier = DecodeFrontier()
    /// Drop-until-anchor admission — the decode-fail cascade guard. Once the reference chain is
    /// known-broken (an unrecoverable loss), deltas stop reaching VT: only anchor candidates
    /// (keyframe / LTR refresh / pre-break delta) are submitted. Without it, losses amplify
    /// (measured: 9 losses → 23 decode-fails → 63 IDR requests) and each failure tears the VT
    /// session down, wiping the very LTR reference the recovery refresh needs.
    private var decodeGate = DecodeGate()
    /// In-order decode admission: frames release to the decoder strictly in frameID
    /// order — an out-of-order completion (small frame outrunning a big/FEC-recovering
    /// predecessor) is HELD until the gap completes or is declared lost, instead of hitting VT
    /// with a missing reference (the measured `frontier = N−2` -12909 class). Patience is derived
    /// from the NACK config (``makeSequencer(nackEnabled:nackGraceFrames:)``): with retransmit
    /// on, the sequencer must out-wait the reassembler's retransmit grace or its overflow valve
    /// re-creates the very -12909 class it exists to prevent.
    private var sequencer = SlopDeskVideoClientSession.makeSequencer(
        nackEnabled: SlopDeskVideoClientSession.nackEnabled,
        nackGraceFrames: SlopDeskVideoClientSession.nackGraceFrames,
    )

    /// Builds the decode sequencer with patience derived from the NACK config. WHY: when
    /// retransmit is enabled the reassembler HOLDS a FEC-unrecoverable frame N for
    /// ``nackGraceFrames`` frame-ids — during that window N is neither `.completed` nor
    /// `.dropped`, so the sequencer never hears about it while every NEWER completion piles into
    /// its held set. Both overflow valves must therefore out-wait the grace: `maxHeld` counts
    /// HELD FRAMES (up to `grace` newer frames can complete while the hole pends) and `maxGap`
    /// is a frameID SPAN (the same `grace` in frame-ids); `+2` is margin for the reassembler's
    /// own reorder grace on the frame after the hole. Leave the stock values in place under NACK
    /// (maxHeld 4 < grace 8) and the valve flushes at ~N+5 — BEFORE the retransmit lands —
    /// submitting frames over the missing reference with the gate still `.open`: -12909 →
    /// invalidateSession → forced-IDR churn, the exact class sequencer + gate exist to prevent.
    /// NACK OFF (the default) returns the stock ``DecodeSequencer`` values.
    static func makeSequencer(nackEnabled: Bool, nackGraceFrames: Int32) -> DecodeSequencer {
        guard nackEnabled else { return DecodeSequencer() }
        let floor = Int(nackGraceFrames) + 2
        return DecodeSequencer(
            maxHeld: max(DecodeSequencer.defaultMaxHeld, floor),
            maxGap: max(DecodeSequencer.defaultMaxGap, floor),
        )
    }

    /// Debug-only counter: frames the gate dropped this session (visible in the periodic dbg line).
    private var dbgGateDrops: UInt64 = 0
    /// Smoothed RTT estimate gating the 2·RTT IDR-escalation timeout. 50 ms default
    /// until ``updateRTTEstimate(_:)`` feeds a measurement.
    private var rttEstimate: TimeInterval = 0.05

    // MARK: Network-feedback telemetry (the network-feedback channel)

    /// DEFAULT ON; `SLOPDESK_NETSTATS=0` disables: the client sends no NetworkStats reports and the
    /// RTT loop runs open-loop. The 4-byte header field is still parsed either way (the host writes
    /// 0 when disabled).
    private static let telemetryEnabled = ProcessInfo.processInfo.environment["SLOPDESK_NETSTATS"] != "0"
    /// NACK / selective-ARQ retransmit. DEFAULT OFF (`SLOPDESK_NACK=1`; deploy host +
    /// client together — adds wire recovery type 6). When on, the reassembler HOLDS a FEC-unrecoverable
    /// frame for ``nackGraceFrames`` frame-ids and NACKs its missing fragments; the host re-sends them
    /// from its ring (cheaper than an IDR, and within the playout buffer → no stutter). The
    /// Dropped→LTR-refresh path is still the fallback once the grace expires.
    private static let nackEnabled = ProcessInfo.processInfo.environment["SLOPDESK_NACK"] == "1"
    /// Frame-ids past the loss frontier a FEC-unrecoverable frame is HELD for a NACK retransmit — must
    /// comfortably exceed the RTT in frame-units (~8 ≈ 130ms at 60fps ≫ a ~21ms WAN RTT, inside the
    /// ~80ms playout buffer).
    private static let nackGraceFrames: Int32 =
        ProcessInfo.processInfo.environment["SLOPDESK_NACK_GRACE"].flatMap { Int32($0) } ?? 8
    /// Only NACK a SMALL loss (≤ this many fragments) — a keystroke / tiny frame is cheap and
    /// stutter-free to re-send. A BIGGER loss (e.g. a scroll frame) skips to the Drop → LTR-refresh
    /// skip-to-current fallback instead, which is smoother + cheaper than re-sending a stale frame
    /// into a burst (HW-tuned: big retransmits add congestion exactly during a burst).
    private static let nackMaxFrags: Int =
        ProcessInfo.processInfo.environment["SLOPDESK_NACK_MAX_FRAGS"].flatMap(Int.init) ?? 8
    /// Delay-gradient detector: DEFAULT ON; `SLOPDESK_TREND=0` disables. The client computes a
    /// libwebrtc-style trendline over per-FRAME one-way-delay variation and ships the detector
    /// output in the NetworkStats report. PURE TELEMETRY: the host's gradient cut path is its own
    /// default-OFF gate (`SLOPDESK_ABR_GRAD`), so with this on the host merely logs trend fields.
    private static let trendEnabled = ProcessInfo.processInfo.environment["SLOPDESK_TREND"] != "0"
    /// WINDOW-FOLLOWS-PANE (host-follow resize), DEFAULT-OFF. On, a pane resize emits a
    /// `resizeRequest` so the host AX-resizes its real window to match — but with in-place (no-VD)
    /// capture the user wants the remote window to KEEP its own size; the pane just fits/letterboxes
    /// the fixed stream (and edge-pans when zoomed). Only `SLOPDESK_GUI_WINDOW_FOLLOWS_PANE=1` opts
    /// into the host-follow behaviour.
    private static let windowFollowsPane =
        ProcessInfo.processInfo.environment["SLOPDESK_GUI_WINDOW_FOLLOWS_PANE"] == "1"
    /// The newest `hostSendTsMillis` OBSERVED on a video fragment (0 = none / telemetry off). An
    /// OPAQUE token the client echoes back; never compared against the client clock.
    private var latestHostSendTs: UInt32 = 0
    /// Ingest-gap probe (`SLOPDESK_VIDEO_DEBUG`): last fragment-ingest time on this actor.
    private var dbgLastIngestAt: Double = 0
    /// Client-monotonic time (seconds) at which `latestHostSendTs` was observed, so the report's
    /// `clientHoldMs` is a client-LOCAL relative delta (now − observedAt) — never an absolute
    /// client timestamp (which would embed cross-machine skew).
    private var latestHostSendTsObservedAt: Double = 0
    /// Pure inter-arrival jitter estimator (client-clock-only 2nd differences).
    private var owdJitter = OWDJitterEstimator()
    /// Pure trendline detector over per-frame OWD variation (clock-skew-immune deltas, like
    /// `owdJitter`). Fed one sample per frame via `trendSampler`.
    private var owdTrend = TrendlineEstimator()
    /// Admits exactly ONE trend sample per frame — the FIRST fragment of each wrap-aware strictly-
    /// newer frameID (kfDup duplicates / reordered older frames / ts==0 are self-rejecting).
    /// Shared by the trendline AND the owd-late detector (both want the same per-frame sample).
    private var trendSampler = TrendSampler()
    /// Per-frame one-way-delay spike detector — owd more than `max(floor, fraction × frame interval)`
    /// past the rolling min-baseline = one network-late event, forwarded to the pacer's depth policy
    /// via ``GUIHooks/noteNetworkLate``.
    private var owdLateDetector = OwdLateDetector()
    /// The stream's content frame interval (ms) — seeds the owd-late threshold. Updated by the
    /// FPS governor's `streamCadence` message (`.applyStreamCadence`); 60 fps until announced.
    private var contentIntervalMs: Double = 1000.0 / 60.0
    /// Windowed counters reset after every report: frames completed / FEC-recovered / unrecovered.
    private var winFramesReceived: UInt32 = 0
    private var winFecRecovered: UInt32 = 0
    private var winUnrecovered: UInt32 = 0
    /// STREAM-BITRATE window (the ~1 Hz `gui.applyStreamBitrate` reading — independent of the 50 ms
    /// NetworkStats wire window): reassembled-frame payload bytes + the window's start timestamp.
    private var bitrateWindowBytes: UInt64 = 0
    private var bitrateWindowStartS: Double = 0
    /// NETWORK-STATS MIRROR window (the ~2 Hz `gui.applyNetworkStats` push): SEPARATE counters
    /// from the win* trio (the wire report resets those every ~50 ms, and it only runs when
    /// telemetry is on — the mirror must aggregate across those windows regardless). Incremented
    /// at the same three sites; reset by ``flushNetworkStatsMirrorIfDue()``.
    private var mirrorFrames: UInt32 = 0
    private var mirrorFecRecovered: UInt32 = 0
    private var mirrorUnrecovered: UInt32 = 0
    private var mirrorWindowStartS: Double = 0
    /// Minimum mirror-window span (seconds) — the ~2 Hz push cadence.
    private static let statsMirrorInterval: Double = 0.5
    /// USER STREAM SETTINGS: the last-requested fps cap / bitrate ceiling (`0` = auto), re-sent
    /// automatically after every accepted (re-)hello — the settings are per-session HOST state
    /// and die with a session re-mint, so the handshake must re-establish them. `nil` ⇒ never
    /// requested (nothing rides the handshake).
    private var lastStreamSettings: (fpsCap: Int, bitrateCeilingBps: Int)?
    /// APP AUDIO wish (wire type 26): the last-requested enable state, re-sent automatically
    /// after every accepted (re-)hello — the exact ``lastStreamSettings`` twin (per-session HOST
    /// state, reset to the default OFF by a session re-mint). `nil` ⇒ never requested (nothing
    /// rides the handshake).
    private var lastAudioEnabled: Bool?
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
    ///     `SLOPDESK_FEC_M >= 2` activates the fixed multi-loss `[k + m, k]` code. The reassembler
    ///     derives `m` from this scheme's `parityCount`, so host and client MUST read the same
    ///     `SLOPDESK_FEC_M` / `SLOPDESK_FEC_K` and deploy together (the per-group parity count
    ///     changes on the wire when `m > 1`).
    public init(
        requestedWindowID: UInt32,
        viewport: VideoSize,
        transport: any VideoClientTransport,
        gui: GUIHooks,
        fec: FECScheme? = AdaptiveFECPolicy.makeFECScheme(),
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy(),
    ) {
        self.init(
            target: .window(requestedWindowID), viewport: viewport, transport: transport,
            gui: gui, fec: fec, recoveryPolicy: recoveryPolicy,
        )
    }

    /// Target-general init: a `.window` target sends the classic `hello`; a `.display` target (the
    /// full-desktop pane) sends `helloDisplay` and never issues in-session resize requests (the
    /// display's size is fixed — the client letterboxes).
    public init(
        target: VideoStreamTarget,
        viewport: VideoSize,
        transport: any VideoClientTransport,
        gui: GUIHooks,
        fec: FECScheme? = AdaptiveFECPolicy.makeFECScheme(),
        recoveryPolicy: RecoveryPolicy = RecoveryPolicy(),
    ) {
        self.transport = transport
        self.gui = gui
        self.recoveryPolicy = recoveryPolicy
        stateMachine = VideoClientStateMachine(target: target, viewport: viewport)
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
        // actor in order (see ``inboundConsumer`` for why a per-datagram Task fan-out is not viable).
        let queue = ClientInboundQueue()
        let (wakeups, wakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        inboundWakeup = wakeup
        // .high: this pump sits between a received fragment and decode-submit; a bare Task's
        // inherited priority can queue it behind pool work (same rationale as the host pumps).
        inboundConsumer = Task(priority: .high) { [weak self] in
            var reportedDrops = 0
            for await _ in wakeups {
                guard let self else { break }
                let batch = queue.drainAll()
                // Overload-shed observability: report the drop-counter delta (bounded — one
                // report per drain that saw new drops, never per datagram).
                let drops = queue.droppedTotals()
                if drops.items > reportedDrops {
                    reportedDrops = drops.items
                    await noteInboundOverload(droppedItems: drops.items, droppedBytes: drops.bytes)
                }
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

    /// Logs the inbound queue's cumulative overload-shed totals (byte-budget tail-drops = wire
    /// loss, already absorbed by FEC / NACK / IDR recovery). Rate-bounded by the caller.
    private func noteInboundOverload(droppedItems: Int, droppedBytes: Int) {
        log
            .error(
                "inbound queue overload: shed \(droppedItems) datagram(s) / \(droppedBytes)B total (consumer starved)",
            )
        dbg("inbound queue overload: \(droppedItems) datagrams / \(droppedBytes)B shed so far")
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

    // MARK: Liveness keepalive (crash-without-bye)

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
        // DEAD-PATH GATE: while the media connection reports a non-viable path (`.waiting`),
        // Network.framework buffers every send in-process indefinitely — skip
        // the periodic fire (the FSM is untouched; the tick resumes the instant the path returns).
        guard stateMachine.mediaFlowing, transport.sendPathViable else { return }
        transport.send(VideoControlMessage.keepalive.encode(), on: .control)
        // Cursor-flow re-prime piggyback: the MEDIA flow re-stamps itself on every routed inbound
        // datagram, but the cursor socket has no ongoing client→host traffic — after a NAT rebind
        // (wifi flap) the host keeps sending cursor updates to the DEAD old mapping forever while
        // video and input recover, freezing the pointer shape on the default arrow. One extra
        // 5-byte datagram per keepalive tick keeps the host's cursor reply flow current (the host
        // stamp is an unconditional overwrite, so a duplicate prime is a no-op).
        transport.send(Self.cursorFlowPrime, on: .cursor)
    }

    /// The cursor side-channel prime payload — content is irrelevant to the host (it stamps the
    /// reply flow off the channelID framing alone); one stable byte keeps it identifiable in traces.
    private static let cursorFlowPrime = Data([0x00])

    // MARK: Stall-scrim liveness snapshot

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
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                await sendNetworkStatsIfStreaming()
                await flushStreamBitrateIfDue()
                await flushNetworkStatsMirrorIfDue()
            }
        }
    }

    /// Sends one NetworkStats report iff streaming and telemetry is enabled, then RESETS the windowed
    /// counters (the counts are per-report-window). `clientHoldMs` is a client-LOCAL delta (now −
    /// observedAt), never an absolute client timestamp, so the host can subtract it inside its own
    /// clock with zero cross-machine skew. The hold is clamped non-negative + saturating so a long
    /// pause cannot trap the `UInt32(Double)` initializer.
    private func sendNetworkStatsIfStreaming() {
        // DEAD-PATH GATE: same rationale as ``sendKeepaliveIfStreaming()`` — a skipped report just
        // widens the next report's window (the win* counters keep accumulating, saturating math).
        guard stateMachine.mediaFlowing, Self.telemetryEnabled, transport.sendPathViable else { return }
        let now = FramePacer.currentHostTimeSeconds()
        let holdMs: UInt32 = latestHostSendTs == 0 ? 0 : UInt32(min(
            Double(UInt32.max),
            max(0, (now - latestHostSendTsObservedAt) * 1000),
        ))
        // Drain the pacer's presentation-health window EXACTLY once per report (the drain IS the
        // window reset, mirroring the win* counter pattern below). No pacer ⇒ zeros with depth 0
        // (the wire's "no pacer attached" gauge value).
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
        winFramesReceived = 0
        winFecRecovered = 0
        winUnrecovered = 0
    }

    /// STREAM BITRATE (titlebar complication): flushes the ~1 s payload-byte window into
    /// `gui.applyStreamBitrate` (kilobits/sec). Rides the 50 ms stats timer but is NOT gated on the
    /// telemetry flag — it is a local GUI reading, never a wire report. While media is not flowing the
    /// window just re-arms (no 0-spam into a torn-down view); a flowing-but-idle window reports a real
    /// 0 (idle-skip means nothing arrives — the instrument shows the stream breathing).
    private func flushStreamBitrateIfDue() {
        guard let apply = gui.applyStreamBitrate else { return }
        let now = FramePacer.currentHostTimeSeconds()
        guard stateMachine.mediaFlowing else {
            bitrateWindowBytes = 0
            bitrateWindowStartS = now
            return
        }
        if bitrateWindowStartS == 0 {
            bitrateWindowStartS = now
            return
        }
        let elapsed = now - bitrateWindowStartS
        guard elapsed >= 1 else { return }
        let kbps = Int((Double(bitrateWindowBytes) * 8 / elapsed / 1000).rounded())
        bitrateWindowBytes = 0
        bitrateWindowStartS = now
        apply(kbps)
    }

    /// NETWORK-STATS MIRROR: flushes the ~0.5 s aggregate of the telemetry counters into
    /// `gui.applyNetworkStats` as per-second rates. Rides the 50 ms stats timer but — like the
    /// bitrate complication — is NOT gated on the telemetry flag (a local GUI reading, never a
    /// wire report; the 50 ms wire cadence is untouched). While media is not flowing the window
    /// re-arms silently (no 0-spam into a torn-down view); a flowing-but-idle window reports real
    /// zeros (idle-skip means nothing arrives). Monotonic clock throughout (the local idiom).
    private func flushNetworkStatsMirrorIfDue() {
        guard let apply = gui.applyNetworkStats else { return }
        let now = FramePacer.currentHostTimeSeconds()
        guard stateMachine.mediaFlowing else {
            mirrorFrames = 0
            mirrorFecRecovered = 0
            mirrorUnrecovered = 0
            mirrorWindowStartS = now
            return
        }
        if mirrorWindowStartS == 0 {
            mirrorWindowStartS = now
            return
        }
        let elapsed = now - mirrorWindowStartS
        guard elapsed >= Self.statsMirrorInterval else { return }
        // The latest clientHoldMs — the same clamped client-local delta the wire report carries
        // (0 = telemetry off / no host stamp observed yet).
        let holdMs: Int = latestHostSendTs == 0 ? 0 : Int(min(
            Double(UInt32.max),
            max(0, (now - latestHostSendTsObservedAt) * 1000),
        ))
        let snapshot = ClientNetworkStatsSnapshot(
            framesPerSecond: Double(mirrorFrames) / elapsed,
            fecRecoveredPerSecond: Double(mirrorFecRecovered) / elapsed,
            unrecoveredPerSecond: Double(mirrorUnrecovered) / elapsed,
            holdMillis: holdMs,
            pacerDepth: gui.readPacerDepth?() ?? 0,
        )
        mirrorFrames = 0
        mirrorFecRecovered = 0
        mirrorUnrecovered = 0
        mirrorWindowStartS = now
        apply(snapshot)
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
        // A DISPLAY target never resizes the host (the display's size is fixed; the client letterboxes).
        guard case .window = stateMachine.target else { return }
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
        // A DISPLAY target never follows the pane size (fixed display; the client aspect-fits).
        guard case .window = stateMachine.target else { return }
        // PANE-FOLLOWS-STREAM (1:1 snap): until the first snap rebases the debounce
        // (`noteLayerSizeAdopted`), suppress emission entirely. A layout pass racing the first
        // decoded frame must not echo the pane's STALE size to the host — that would AX-resize
        // the host window to the old pane size right before the pane adopts the stream's
        // natural size, defeating the snap. After the rebase, user drags request normally.
        if gui.notifyStreamNativePoints != nil, resizeDebounce.lastRequested == nil {
            dbg("resize: pane-follows-stream — holding resizeRequest until the 1:1 snap rebases the debounce")
            return
        }
        // Only a REAL change re-arms the settle clock — an identical layout pass must not, or a size
        // held steady across repeated passes never settles.
        if lastSeenSize != size {
            lastSeenSize = size
            lastSizeChangeTime = Date()
        }
        // Try to emit NOW; if not yet settled, arm the settle timer so the SETTLED size is still
        // requested even when the final drag frame re-armed the clock and no further layout callback
        // arrives to re-evaluate it (otherwise a clean drag-end emits no `resizeRequest` at all).
        // Each change cancels + reschedules → exactly one request per settled size.
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
        // A gap in VIDEO datagram arrival = a HOST-side capture stall (e.g. the SCStream hitching
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
        case let .audio(message):
            handleAudio(message)
        case let .drop(reason):
            log.error("dropping media datagram: \(reason)")
            dbg("media datagram DROPPED: \(reason)")
        case .ignore:
            break
        }
    }

    // MARK: Inbound app audio (channel 6)

    /// One decoded tag-6 datagram. Gated on the LOCAL wish, not just the host's send gate:
    /// datagrams still in flight when the user disabled audio must not re-fill the just-cleared
    /// ring (and a stale host that missed the OFF keeps sending until it applies it).
    private func handleAudio(_ message: AudioChannelMessage) {
        guard lastAudioEnabled == true else { return }
        switch message {
        case let .config(_, _, config):
            applyAudioConfig(config)
        case let .frame(seq, _, payload):
            // Frames before the first config are undecodable — drop; the ~1 s config re-send
            // locks the stream on promptly.
            guard let decoder = audioDecoder, let engine = audioEngine else { return }
            // OFF-QUEUE like video decode: the converter call runs on the serial audio queue so
            // it never blocks fragment ingest on this actor; the engine's jitter stage re-orders
            // by seq, so queue-serialised decode order is sufficient.
            audioQueue.async {
                let samples = decoder.decode(payload)
                guard !samples.isEmpty else { return } // corrupt frame — concealed like wire loss
                engine.enqueue(seq: seq, samples: samples)
            }
        }
    }

    /// (Re)locks the stream parameters from a received config. Idempotent for the ~1 s re-send:
    /// an UNCHANGED config only re-asserts playback (`start()` is idempotent — this is also how
    /// a re-enable's config restarts the stopped AU). A changed format/cookie rebuilds the
    /// decoder; changed `(sampleRate, channels)` also rebuilds the engine (its AU + ring are
    /// format-bound).
    private func applyAudioConfig(_ config: AudioStreamConfig) {
        if config == audioConfig, audioDecoder != nil, let engine = audioEngine {
            audioQueue.async { engine.start() }
            return
        }
        // A build for this exact config is already in flight — don't queue a duplicate.
        if config == audioPendingConfig { return }
        audioConfigGeneration += 1
        audioPendingConfig = config
        let generation = audioConfigGeneration
        // OFF-ACTOR like frame decode: `AudioConverterNew` is real AudioToolbox codec setup (a
        // framework warm-up on the first call in the process), so building here would stall
        // video-fragment ingest on this actor. Build on the audio queue and install back on the
        // actor; the generation stamp discards a build superseded by a newer config or teardown.
        // Frames arriving meanwhile keep flowing to the OLD decoder (or drop pre-first-config).
        audioQueue.async { [weak self] in
            let decoder = try? AudioStreamDecoder(config: config)
            guard let self else { return }
            Task { await self.installAudioDecoder(decoder, config: config, generation: generation) }
        }
    }

    /// Actor-side install of an off-queue decoder build. `decoder == nil` ⇒ the converter refused
    /// the config (validate-then-drop: keep whatever stream was in force; the host's ~1 s re-send
    /// retries).
    private func installAudioDecoder(
        _ decoder: AudioStreamDecoder?,
        config: AudioStreamConfig,
        generation: Int,
    ) {
        guard generation == audioConfigGeneration else { return } // superseded — a newer config/teardown won
        audioPendingConfig = nil
        guard let decoder else {
            log.error("audio config rejected (no decoder for it) — dropped")
            return
        }
        audioConfig = config
        audioDecoder = decoder
        dbg(
            "audio config: format=\(config.format) \(config.sampleRate)Hz ch=\(config.channels) cookie=\(config.cookie.count)B",
        )
        let rate = Double(config.sampleRate)
        let ch = Int(config.channels)
        if let engine = audioEngine, engine.sampleRate == rate, engine.channels == ch {
            audioQueue.async { engine.start() }
            return
        }
        let old = audioEngine
        let engine = AudioPlaybackEngine(sampleRate: rate, channels: ch)
        audioEngine = engine
        // Engine lifecycle stays on the audio queue (its single-owner discipline): retire the
        // old AU before starting the fresh one so two units never render at once.
        audioQueue.async {
            old?.invalidate()
            engine.start()
        }
    }

    /// Tears the audio path down with the pipeline (bye / local stop / rebuild): the AU must not
    /// keep running for a dead session, and the next session locks onto a fresh config anyway.
    /// The stored ``lastAudioEnabled`` wish survives — it re-rides the next handshake.
    private func stopAudioPipeline() {
        audioConfig = nil
        audioDecoder = nil
        // Invalidate any in-flight off-queue decoder build — it must not resurrect the pipeline.
        audioConfigGeneration += 1
        audioPendingConfig = nil
        guard let engine = audioEngine else { return }
        audioEngine = nil
        audioQueue.async { engine.invalidate() }
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
        // Stutter probe (`SLOPDESK_VIDEO_DEBUG`): a >28ms hole between fragment ingests ON THE ACTOR
        // while the socket stage is clean means the actor backlog ate the time. If the socket stage
        // gapped too, the stall is inherited, not actor-caused.
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
        // Delay-gradient: ONE sample per frame — the first fragment of each strictly-newer frameID
        // (all fragments of a frame share one packetize-time stamp, so per-fragment samples would
        // carry a built-in intra-frame slope; kfDup/reorder/ts==0 self-reject). The SAME admitted
        // sample also feeds the owd-late detector — one sampler, two consumers, so the per-frame
        // discipline can't drift between them.
        if trendSampler.shouldSample(frameID: fragment.header.frameID, sendTs: ts) {
            if Self.trendEnabled {
                owdTrend.note(arrivalMs: now * 1000, sendTs: ts)
            }
            // An owd spike past baseline + threshold = one network-late event for the pacer's
            // adaptive depth — the signal depth-2 actually absorbs. A present-gap classifier cannot
            // serve here: it self-sustains at depth 2 and reads sub-cadence content as late, so the
            // demote never happens on a clean path.
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
            mirrorFrames &+= 1
            bitrateWindowBytes &+= UInt64(frame.avcc.count)
            if frame.recoveredViaFEC {
                winFecRecovered &+= 1
                mirrorFecRecovered &+= 1
                // An FEC recovery is the EARLY-WARNING loss event — bursts produce several of these
                // before the first unrecoverable frame, so the burst's first frozen episode already
                // runs the halved escalation clock.
                lossWindow.noteEvent(now: FramePacer.currentHostTimeSeconds())
            }
            // In-order release: a frame ahead of a reassembly gap is held until the gap
            // resolves (complete or declared lost) — never submitted over a missing reference.
            for released in sequencer.noteCompleted(frame) {
                decode(released)
            }
        case let .dropped(lost):
            // When the INGESTED fragment's OWN frame becomes hopeless, `ingest()` returns
            // `.dropped(frameID:)` directly AND has already POPPED that id off its dropped queue — so
            // the drain loop below MISSES it. Ignoring this return therefore kills lost-frame recovery
            // (LTR refresh / IDR) for the reorder-then-loss interleaving (a newer frame's fragment
            // advances the frontier, then an older frame's last data fragment arrives and is hopeless):
            // the stream stalls on the last good frame until an unrelated re-anchor. Route it through
            // the same recovery decision as the drain.
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
    /// swallow a loss.
    private func signalRecovery(lostFrameID lost: UInt32) {
        dbg("frame #\(lost) declared LOST (unrecoverable)")
        // Network-feedback telemetry: count an unrecoverable loss (the loss-rate numerator).
        winUnrecovered &+= 1
        mirrorUnrecovered &+= 1
        // Feed the loss-observing window (gates the halved escalation clock).
        lossWindow.noteEvent(now: FramePacer.currentHostTimeSeconds())
        // SELF-HEAL: record the loss boundary so a SUCCESSFULLY-decoded frame newer than every loss
        // (the host's cadence/recovery LTR refresh — a P-frame, never a keyframe) can end the episode
        // instead of letting the 2·RTT escalation fire a spurious IDR after a healed stream.
        escalation.noteLoss(frameID: lost)
        // Arm the decode gate — post-loss deltas are dropped BEFORE VT until an anchor (keyframe /
        // acked-anchored refresh) decodes, instead of failing one by one.
        decodeGate.noteLoss(frameID: lost)
        // The declared loss closes any sequencer gap at this id: frames held behind it release
        // NOW (the armed gate above drops the non-anchors among them — its job, not VT's).
        for released in sequencer.noteLost(frameID: lost) {
            decode(released)
        }
        if shouldEscalateToIDR() {
            requestIDR()
            // Re-anchor the escalation clock so the NEXT dropped frame in this same loss episode does
            // not re-fire the escalation (and resend a redundant requestIDR) until another 2·RTT
            // elapses. Ordinary requestRecovery must still NOT move the first-request clock — only a
            // fired escalation re-arms it.
            escalation.noteEscalated(now: FramePacer.currentHostTimeSeconds())
        } else {
            requestRecovery(lostFrameID: lost)
        }
    }

    /// Whether a forced-IDR escalation is due: an LTR refresh is already outstanding
    /// (the recovery episode is armed, not yet cleared by a keyframe) and at least
    /// 2·RTT — or, while OBSERVING LOSS, `max(1·RTT, 30 ms)` — has elapsed
    /// since the FIRST request of the episode
    /// (``LTREscalationTracker/shouldEscalate(now:rtt:policy:observingLoss:)``).
    /// The env gate (`SLOPDESK_FAST_ESCALATION`) is applied HERE so the pure types stay env-free.
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
        // Drop-until-anchor. A delta that (transitively) references a lost frame cannot decode —
        // submitting it costs a VT failure, a session teardown, and a redundant IDR request PER
        // FRAME (measured: 9 losses → 23 decode-fails → 63 requests).
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
            // PENDING-DECODE BUDGET: a wedged synchronous VT decode (the iOS background-suspend hang
            // class) would otherwise let queued blocks — each retaining its full AVCC Data —
            // accumulate at wire rate. Past the budget, drop BEFORE dispatch and
            // take the awaiting-keyframe recovery path (gate arms → later deltas drop on the actor
            // at the escalation cadence; the IDR request guarantees an anchor comes even on a
            // static screen). Identical semantics to losing the frame on the wire.
            guard decodeBudget.admit(bytes: frame.avcc.count) else {
                dbgBudgetDrops &+= 1
                dbg(
                    "decode budget: frame #\(frame.frameID) dropped pre-dispatch (pending \(decodeBudget.pendingCount) frames / \(decodeBudget.pendingBytes)B, total \(dbgBudgetDrops)) — decode stage saturated",
                )
                decodeGate.noteAwaitingKeyframe()
                // Recovery rides the escalation cadence, NOT once per drop: a keyframe always
                // passes the gate, so during sustained saturation EVERY incoming keyframe (the
                // heartbeat IDR + each recovery IDR answering our own request) lands here — an
                // unconditional request would re-fire a redundant-copy IDR burst per keyframe,
                // exactly while the client is least able to cope. The FIRST drop of an episode
                // still requests immediately (arming the escalation clock); repeats wait out the
                // 2·RTT / floor window, mirroring the gate-drop branch above.
                if !escalation.hasOutstandingRequest || shouldEscalateToIDR() {
                    requestIDR()
                    escalation.noteEscalated(now: FramePacer.currentHostTimeSeconds())
                }
                return
            }
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
                    // Invalidate on the decode queue so the decoder stays single-owner; the next
                    // (even byte-identical) keyframe rebuilds a fresh VT session.
                    dec.invalidateSession()
                    outcome = .failed(String(describing: error))
                }
                guard let self else { return }
                Task { await self.finishOffQueueDecode(work.frame, outcome) }
            }
            return
        }
        // Inline synchronous decode on the actor (`SLOPDESK_DECODE_OFFQUEUE=0`).
        let outcome: DecodeOutcome
        do {
            try decoder.decode(frame)
            outcome = .success
        } catch VideoDecoderError.awaitingKeyframe {
            outcome = .awaitingKeyframe
        } catch {
            decoder.invalidateSession() // rebuild on the next (even byte-identical) keyframe
            outcome = .failed(String(describing: error))
        }
        finishDecode(frame, outcome)
    }

    /// Off-queue completion hop: releases the pending-decode budget FIRST (the block left the queue —
    /// success or failure alike, only admitted frames reach here), then the shared bookkeeping.
    private func finishOffQueueDecode(_ frame: ReassembledFrame, _ outcome: DecodeOutcome) {
        decodeBudget.complete(bytes: frame.avcc.count)
        finishDecode(frame, outcome)
    }

    /// Post-decode bookkeeping (decode-frontier / decode-gate reopen / LTR+keyframe ack / self-heal +
    /// escalation clock). Extracted so it runs either inline or hopped back from the decode queue
    /// (``decodeOffQueue``). Order-insensitive — the frontier takes the newest id, the ack is per-frame,
    /// the gate reopen + escalation checks are idempotent — so an out-of-order decode-queue hop is safe.
    /// `.failed` has already run `invalidateSession()` (decoder single-owner) before reaching here.
    private func finishDecode(_ frame: ReassembledFrame, _ outcome: DecodeOutcome) {
        switch outcome {
        case .success:
            // Advance the decode frontier — the context every recovery request carries.
            frontier.noteDecoded(frameID: frame.frameID)
            // A successful decode may re-open the gate (keyframe / newer-than-every-loss anchor).
            decodeGate.noteDecodeSucceeded(frameID: frame.frameID, keyframe: frame.keyframe)
            // ACK every decoded LTR-flagged frame AND every decoded keyframe on the dedicated
            // `.recovery` channel (ACKED-ONLY — we ack only frames we actually decoded) so the host may
            // ForceLTRRefresh against it / fold its recovery-IDR cooldown. Host fold is idempotent.
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
            // misses. A hard failure isn't surfaced by the reassembler (it reported `.completed`), so
            // re-anchor via IDR; the session was already invalidated, so the next byte-identical recovery
            // keyframe rebuilds a fresh one.
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

    /// Called from the decoder's frame handler with the ACTUAL decoded `CVPixelBuffer` dimensions
    /// (pixels). Frame-gated in-session-resize adoption: when a host resize has been acked
    /// (`pendingCaptureSize` set) and a decoded frame finally arrives AT that size, adopt it as the
    /// aspect-fit denominator (`decodedSize`) and re-place the cursor. Compares against the BUFFER dims
    /// (not the ack) so an in-flight OLD-size frame arriving after the ack does NOT trip adoption early
    /// (it would briefly mis-scale).
    ///
    /// `decodedSize` shares the aspect-fit unit family (ratios are scale-invariant), and the host
    /// clamps the achieved size to the ack's wire UInt16, so a per-axis rounding tolerance absorbs
    /// capture-scale rounding between acked points and decoded pixels. No-op when nothing is pending.
    private func noteDecoded(width: Double, height: Double) {
        // Track the magnitude baseline FIRST (every decoded frame) so the next
        // frame can tell a genuinely-new size from an in-flight old-size one.
        let decoded = VideoSize(width: width, height: height)
        let previous = lastDecodedPixelSize
        lastDecodedPixelSize = decoded
        // 1:1 PANE SNAP: surface the host window's POINT size whenever the decoded size changes (first
        // frame, or first frame at a new capture size). The host's captureScale isn't on the wire but
        // is CONSTANT and inferable from the first frame (`decoded pixels / negotiated window points`);
        // reused for every later resize. Snapping to `decoded / streamCaptureScale` (= host window
        // points) — NOT `decoded / CLIENT contentsScale` — keeps the resize loop gain at 1; against the
        // client scale, a 1× no-VD capture on a 2× Retina client HALVES the pane each cycle (panes keep
        // shrinking on every resize).
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
            // HOST-INITIATED RESIZE denominator refresh (else the cursor/clicks drift after a resize):
            // `decodedSize` (the pointer/cursor aspect-fit DENOMINATOR) is otherwise only adopted on a
            // CLIENT-initiated resize ack (`pendingCaptureSize`, below). A resize by ANY other means
            // (user dragging the window's corner, an app-driven resize) has no ack pending, so the
            // denominator would stay STALE while the renderer already draws the new frame, and
            // `InputEventEncoder.normalize` letterboxes against the wrong aspect → clicks land offset.
            // Adopt the live native point size whenever NO client resize is in flight, so input/cursor
            // mapping always matches the screen.
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
        // ⚠️ The video-native size (aspect-fit denominator shared by `normalize` and the renderer)
        // MUST equal the ACTUAL decoded frame size = the helloAck capture size, FIXED for the session:
        // the host configures the SCStream ONCE and does NOT reconfigure on window resize (the resized
        // window is scaled into the same buffer). The renderer aspect-fits via
        // `CVPixelBufferGetWidth/Height`, so re-deriving `decodedSize` from a window-resize geometry
        // message would letterbox INPUT against a different aspect than RENDER → drag/click land on the
        // wrong pixel (wrong coordinates, or the video not filling the pane). So geometry NEVER touches
        // `decodedSize`; it stays capture-pinned. (Move/resize still drives host-side cursor/input bounds in
        // `SlopDeskVideoHostSession.onGeometry`, so absolute injection tracks the live window.)
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
            // Self-heal: a position update referencing a shapeID we never cached means its one-shot
            // bitmap was lost (or never fit one datagram). Re-request it on the recovery channel
            // (debounced per id) so the overlay can recover instead of staying wrong/invisible for the
            // whole session. The applyCursor below keeps the prior bitmap until the re-ship arrives.
            maybeRequestCursorShape(update.shapeID)
            applyCursor(update)
        case let .shape(shape):
            registerCursorShape(shape)
        case let .swipeNavStatus(status):
            gui.applySwipeNavStatus?(status)
        }
    }

    /// Sends a `requestCursorShape(shapeID)` on the recovery channel iff the shape is missing and
    /// not recently requested (``CursorShapeRequestTracker``). No-op once the shape is cached.
    private func maybeRequestCursorShape(_ shapeID: UInt16) {
        guard shapeRequests.shouldRequest(shapeID: shapeID, now: FramePacer.currentHostTimeSeconds()) else { return }
        dbg("cursor shape \(shapeID) missing — requesting re-ship on recovery channel")
        transport.send(RecoveryMessage.requestCursorShape(shapeID: shapeID).encode(), on: .recovery)
    }

    /// Logs a SESSION-ACTOR cursor RX gap > 100 ms — the host/network side of the freeze. The host
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
            return // do NOT mark arrived — leave the id re-requestable so a decode failure self-heals.
        }
        // Mark arrived only AFTER a successful decode — the tracker then stops re-requesting.
        shapeRequests.noteShapeArrived(shape.shapeID)
        // Pass the LOGICAL point size so the overlay renders at the cursor's true size regardless of
        // the bitmap's pixel resolution (a Retina or MTU-downscaled bitmap is scaled to fit) — NOT the
        // raw bitmap pixel dimensions.
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
        // Build the up ONCE, send it `redundantUpCount` times (fire-and-forget UDP): the release edge
        // is the one event whose loss is catastrophic (a stuck selection). Same bytes/tag each time —
        // the host posts the FIRST and button-balance SUPPRESSES the rest (button already released), so
        // duplicates never become spurious extra `*MouseUp` events.
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
    /// inference), which is what makes drag-select survive the unreliable input channel.
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
        // Build ONCE, send `keySendCount` times: a MODIFIER key-up gets the same
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

    /// USER STREAM SETTINGS (wire type 25): request a live encode fps CAP and/or bitrate CEILING
    /// for this session — `0` on either axis means auto (clear that override). The values are
    /// stored and RE-SENT automatically after every accepted (re-)hello (per-session HOST state —
    /// it dies with a session re-mint); the HOST clamps on apply (fps 5…120, bitrate
    /// 500 kbps…200 Mbps). A later call replaces the earlier request wholesale.
    public func updateStreamSettings(fpsCap: Int, bitrateCeilingBps: Int) {
        lastStreamSettings = (fpsCap: max(0, fpsCap), bitrateCeilingBps: max(0, bitrateCeilingBps))
        sendStreamSettingsIfStreaming()
    }

    /// Sends the stored settings iff a session streams (the host SM ignores a pre-stream message,
    /// and the handshake completion re-sends — see ``updateStreamSettings(fpsCap:bitrateCeilingBps:)``).
    private func sendStreamSettingsIfStreaming() {
        guard let settings = lastStreamSettings, stateMachine.mediaFlowing else { return }
        dbg("→ streamSettings fpsCap=\(settings.fpsCap) ceiling=\(settings.bitrateCeilingBps)bps")
        transport.send(
            VideoControlMessage.streamSettings(
                fpsCap: UInt8(clamping: settings.fpsCap),
                bitrateCeilingBps: UInt32(clamping: settings.bitrateCeilingBps),
            ).encode(),
            on: .control,
        )
    }

    /// APP AUDIO (wire type 26): request host app-audio for this session on/off. The wish is
    /// stored and RE-SENT after every accepted (re-)hello — per-session HOST state that dies
    /// with a session re-mint (host default OFF), the exact
    /// ``updateStreamSettings(fpsCap:bitrateCeilingBps:)`` twin. Disable also acts LOCALLY —
    /// stop the output AU and drop everything buffered — so the pane falls silent NOW, not one
    /// control round-trip plus a ring-drain later.
    public func updateAudioEnabled(_ enabled: Bool) {
        lastAudioEnabled = enabled
        if !enabled, let engine = audioEngine {
            audioQueue.async {
                engine.stop()
                engine.flushBuffered()
            }
        }
        sendAudioControlIfStreaming()
    }

    /// Sends the stored audio wish iff a session streams (the host SM ignores a pre-stream
    /// message, and the handshake completion re-sends — see ``updateAudioEnabled(_:)``).
    private func sendAudioControlIfStreaming() {
        guard let enabled = lastAudioEnabled, stateMachine.mediaFlowing else { return }
        dbg("→ audioControl enabled=\(enabled)")
        transport.send(VideoControlMessage.audioControl(enabled: enabled).encode(), on: .control)
    }

    /// Tells the host to RAISE the captured window to frontmost because this pane was focused on the
    /// client (hover / first-responder). Sent fire-and-forget on the `.control` channel WHILE streaming.
    /// Proactive + idempotent: the host raises once (short-circuiting if already frontmost), so the
    /// user's first click lands instantly without the per-interaction activate-then-control raise stall.
    /// A no-raise background-injection path does not replace this — it preserves host focus but leaves
    /// the stall in place.
    public func sendFocusWindow() {
        guard stateMachine.mediaFlowing else { return }
        transport.send(VideoControlMessage.focusWindow.encode(), on: .control)
    }

    // MARK: Recovery (client → host)

    /// Sends one logical recovery request as `recoveryRedundancy.copies` BYTE-IDENTICAL
    /// datagrams — the first immediately (no added latency), the rest from a short-lived (≤12 ms) Task
    /// spaced `spacing` apart to decorrelate burst loss. The caller encodes the payload ONCE so every
    /// copy is byte-equal (the host `RecoveryRequestDeduper`'s contract). `transport.send` is sync
    /// fire-and-forget on a Sendable transport, so the Task captures ONLY the transport (never self — a
    /// send after stop() is a logged no-op, so it can't delay session teardown).
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
        // Arm the escalation clock on the FIRST request of the episode only; a request sent for each
        // subsequent dropped frame must NOT move it, or the 2·RTT window measured from the first
        // request never elapses.
        escalation.noteRequestSent(now: FramePacer.currentHostTimeSeconds())
    }

    private func requestIDR() {
        // Every IDR request carries the decode frontier so the host's delivery-keyed cooldown can
        // grant the casualty bypass (frontier older than a sent keyframe past grace).
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
        case .primeCursorFlow:
            // Cursor side-channel (re-)prime: a 1-byte datagram on the CURSOR socket (the transport
            // frames it with this lane's channelID) so the host (re-)stamps the lane's cursor reply
            // flow. Rides with every hello — the only self-heal the cursor channel has (no other
            // client→host traffic exists on that socket; see the Effect's doc).
            transport.send(Self.cursorFlowPrime, on: .cursor)
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
            // The owd-late threshold scales with the content interval.
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
            // The host ended this session (bye) — surface it so the pipeline rebuilds (fresh lane +
            // hello + presentation path), instead of wedging the pane. The FSM is already `.stopped`, so
            // the keepalive/stats timers self-quiesce on their mediaFlowing gates; the rebuild's
            // deactivate → stop() then cancels them and closes the lane.
            dbg("session ended by HOST (bye) → notifying pipeline for a full rebuild")
            gui.notifySessionEnded?()
        case .sessionRejectedByHost:
            // TERMINAL REFUSAL (helloAck accepted:false — window gone / version mismatch): surface
            // it so the pipeline tears down WITHOUT the rebuild the bye path runs (a rebuild would
            // re-hello the same doomed request forever). The FSM is `.rejected`, so the hello-retry
            // loop and the media gates have already quiesced.
            dbg("session REJECTED by host (helloAck accepted=false) → notifying pipeline, no rebuild")
            gui.notifySessionRejected?()
        }
    }

    private func startDecodePipeline(captureSize: VideoSize, fullRange: Bool) {
        decodedSize = captureSize
        dbg(
            "decode pipeline up — native(capture)=\(Int(captureSize.width))x\(Int(captureSize.height)) fullRange=\(fullRange); this is the FIXED aspect-fit denominator for the session",
        )
        // 1:1 PIXEL MATCH: the resize debounce is only driven from `setLayerSize` (layout passes), and at
        // connect those all land BEFORE mediaFlowing — so without a kick here the INITIAL pane size is
        // never negotiated and every frame pays a permanent non-integer fit-scale (measured: native
        // 2662x1658 → drawable 2485x1576 = 0.93× bilinear blur on all text). Kicking the debounce ONCE at
        // stream start has the host AX-resize the captured window to the pane's point size (capture@2× ==
        // drawable px ⇒ zero resample). Guarded so a pane already matching capture (within minDelta)
        // doesn't trigger a pointless capture restart.
        //
        // This host-follow negotiation runs ONLY for a standalone view (`notifyStreamNativePoints ==
        // nil`). A canvas pane registers the snap hook and the direction inverts — the PANE adopts the
        // stream's natural size (host window POINT size, fired from `noteDecoded` on the first frame), so
        // the host window is never disturbed at connect.
        //
        // KEEP-ORIGINAL-SIZE (no-VD in-place capture): host-follow AX-resizes the remote window to the
        // pane's size for a sharp 1:1 capture — but with in-place capture the user wants the remote
        // window to KEEP its own size (the pane `.fit`-letterboxes; pinch/edge-pan reach detail), and it
        // BOUNCES the window back after a manual corner-drag, fighting the user. Hence the
        // `windowFollowsPane` opt-in: default-off leaves the remote window untouched.
        if Self.windowFollowsPane, gui.notifyStreamNativePoints == nil,
           abs(layerSize.width - captureSize.width) >= 8 || abs(layerSize.height - captureSize.height) >= 8
        {
            dbg(
                "resize: initial pane \(Int(layerSize.width))x\(Int(layerSize.height)) ≠ capture \(Int(captureSize.width))x\(Int(captureSize.height)) → negotiating 1:1",
            )
            maybeRequestResize(for: layerSize)
        }
        // Set the renderer's color range to the stream's negotiated luma range BEFORE the first frame
        // renders (the helloAck carrying it arrived before any media). The decoder's output pixel-format
        // variant is set below from the SAME bool, so renderer + decoder agree — both derived from the
        // host's actual encoded range.
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
        // Request the NV12 output variant matching the stream's range (set before the decoder's lazy
        // first configure on the first keyframe). `false` ⇒ VideoRange.
        decoder.outputFullRange = fullRange
        self.decoder = decoder
        // LATE-JOIN ANCHOR: a freshly-built decoder holds NO reference frames — until an
        // IDR configures it, every delta is undecodable. A client joining a LIVE stream mid-GOP (host
        // already shipped its first-frame IDR) or a STATIC screen with no deltas would otherwise sit
        // dark until the host's periodic static re-anchor, wasting one VT `awaitingKeyframe` per
        // pre-anchor delta. Proactively (a) arm the drop-until-anchor gate so pre-anchor deltas drop
        // BEFORE VT, and (b) ask for an IDR now. The host's delivery-keyed `RecoveryIDRPolicy` absorbs
        // this as an in-flight duplicate when it JUST sent a first-frame IDR (grace window) — the common
        // fresh-session case, which therefore costs no extra IDR — and forces a real IDR only when this
        // client genuinely lacks an anchor. Anchoring latency ≈ one RTT regardless of motion.
        // `requestIDR()` arms the escalation
        // clock (no loss on record ⇒ only a keyframe clears the episode — the intended hard-anchor
        // semantics); the gate arming is idempotent with the reactive path below.
        decodeGate.noteAwaitingKeyframe()
        requestIDR()
        // USER STREAM SETTINGS are per-session HOST state — a (re-)accepted hello landed on a
        // freshly-minted session that knows nothing of the user's cap/ceiling, so re-establish
        // the last request now (no-op when none was ever made).
        sendStreamSettingsIfStreaming()
        // APP AUDIO is the same class of per-session host state (a re-mint resets it to the
        // default OFF) — re-assert the stored wish alongside the settings.
        sendAudioControlIfStreaming()
        reapplyCursor()
        log
            .info(
                "client decode pipeline up at capture \(captureSize.width, privacy: .public)x\(captureSize.height, privacy: .public)",
            )
    }

    private func stopDecodePipeline() {
        decoder = nil
        stopAudioPipeline()
    }

    // MARK: PNG decode (cross-platform, no window-server)

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Tracks the **first** outstanding LTR-refresh request so the 2·RTT IDR escalation can actually fire
/// under sustained loss (doc 17 §3.6). Pure value type — no transport / wall-clock (the actor passes
/// `now` in) — so escalation timing is unit-testable without a socket or `VTDecompressionSession`.
///
/// Loss is detected once per dropped frame, so a clock reset on EVERY detection (the tempting
/// `lastRecoveryRequestTime = now` in `requestRecovery`) never reaches 2·RTT under sustained loss: the
/// guaranteed-recovery forced IDR never fires and the stream can starve forever.
///
/// Hence: the clock is the time of the FIRST request in the current episode — armed only on entering
/// recovery (no request outstanding), NOT rearmed on each later loss, cleared only when a keyframe
/// decodes.
public struct LTREscalationTracker: Sendable, Equatable {
    /// Host time (seconds) of the first request in the current recovery episode, or
    /// `nil` when no recovery is outstanding. Cleared by ``keyframeDecoded()`` or by
    /// ``frameDecoded(frameID:)`` when a frame NEWER than every loss in the episode decodes.
    public private(set) var firstRequestTime: TimeInterval?

    /// The NEWEST (wrap-aware) frameID declared unrecoverably lost in the current episode, or `nil`
    /// when no loss was attributed (a `requestIDR` from a hard decode failure arms the episode with
    /// no frameID — then ONLY a keyframe can clear it). Recorded by ``noteLoss(frameID:)``; lets
    /// ``frameDecoded(frameID:)`` recognise a SELF-HEALED stream.
    ///
    /// WHY: clearing the episode ONLY on a decoded KEYFRAME cannot work — the LTR-refresh recovery
    /// frame, and every SELF-HEAL cadence refresh, is a plain P-frame (`kf=false` on the wire,
    /// HW-verified), so a recovery that SUCCEEDED via refresh would leave the episode armed and the
    /// 2·RTT escalation would fire a spurious IDR (LTR recovery saving no IDR at all). A delta
    /// referencing a LOST frame cannot decode (VT throws — measured 9/9), so any frame NEWER than every
    /// loss decoding SUCCESSFULLY proves the chain re-anchored, keyframe or not.
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
    /// already outstanding must NOT move the clock — resetting it per dropped frame means
    /// 2·RTT never elapses and the escalation never fires.
    public mutating func noteRequestSent(now: TimeInterval) {
        if firstRequestTime == nil { firstRequestTime = now }
    }

    /// Whether to escalate to a forced IDR right now: a request is outstanding and at
    /// least `2·RTT` (per `policy`) — or, while `observingLoss`, `max(1·RTT, floor)` —
    /// has elapsed since the FIRST request. Pure — does not mutate; the caller decides
    /// whether to act. `observingLoss` is defaulted so a caller with no loss signal gets
    /// the plain 2·RTT clock.
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

    /// Re-anchor the clock to `now` AFTER a forced-IDR escalation actually fired. Otherwise, once
    /// ``shouldEscalate(now:rtt:policy:)`` returns true, every SUBSEQUENT dropped frame in the episode
    /// keeps returning true (the first request is still ≥ 2·RTT old) and the drain loop resends a
    /// redundant `requestIDR` per frame. Re-anchoring gates the NEXT escalation to one-per-2·RTT.
    ///
    /// DISTINCT from ``noteRequestSent(now:)``: an ordinary recovery request must NOT move the
    /// first-request clock (that is what lets the 2·RTT window elapse at all). Only a fired escalation
    /// re-arms it. The episode is still cleared by ``keyframeDecoded()`` when recovery lands.
    public mutating func noteEscalated(now: TimeInterval) {
        firstRequestTime = now
    }
}

/// Lock-protected FIFO of inbound datagrams (media + cursor) feeding the client session's single
/// batch-drain consumer. Same discipline as the host's `InboundQueue` / `EncodedFrameQueue`: the
/// transport's serial receive queue appends synchronously (arrival order carried end-to-end), the
/// consumer drains the whole backlog per coalesced wakeup. `@unchecked Sendable` + NSLock.
///
/// BYTE-BUDGETED: the queue is fed at wire rate ahead of the session actor;
/// if the consumer is starved (whole-process pressure) the backlog must stop growing at the
/// budget. An append past it is TAIL-DROPPED (O(1), never a `removeFirst`) — refusing the newest
/// datagram is exactly a wire loss of that datagram, which the reassembler / FEC / NACK / decode
/// gate already handle; the next 120 Hz cursor update supersedes a shed one. Drops are counted
/// for the debug surface.
final class ClientInboundQueue: @unchecked Sendable {
    enum Item {
        case media(VideoChannel, Data)
        case cursor(Data)

        var byteCount: Int {
            switch self {
            case let .media(_, data): data.count
            case let .cursor(data): data.count
            }
        }
    }

    private let lock = NSLock()
    private var items: [Item] = []
    /// Payload bytes currently queued (each slice pins its ≤ MTU-sized parent datagram, so
    /// payload bytes track real retention within a small constant factor).
    private var queuedBytes = 0
    private var droppedItems = 0
    private var droppedBytes = 0
    /// Backlog byte budget. At streaming wire rate (~1–4 MB/s) the default 8 MiB is seconds of
    /// backlog — the healthy consumer drains in ms, so only genuine starvation ever hits it.
    private let byteBudget: Int

    init(byteBudget: Int = 8 << 20) {
        self.byteBudget = byteBudget
    }

    /// Append one datagram, tail-dropping past the byte budget (= wire loss, never corruption).
    /// Called on the transport's serial receive queue; O(1), never blocks.
    func append(_ item: Item) {
        let size = item.byteCount
        lock.lock()
        defer { lock.unlock() }
        guard queuedBytes + size <= byteBudget else {
            droppedItems += 1
            droppedBytes += size
            return
        }
        queuedBytes += size
        items.append(item)
    }

    /// Atomically take and clear the whole backlog (arrival order). An empty result means a
    /// coalesced wakeup whose datagrams an earlier drain already consumed.
    func drainAll() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items = []
        queuedBytes = 0
        return out
    }

    /// Cumulative overload-shed counters (monotonic; the consumer reports deltas).
    func droppedTotals() -> (items: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (droppedItems, droppedBytes)
    }
}
#endif
