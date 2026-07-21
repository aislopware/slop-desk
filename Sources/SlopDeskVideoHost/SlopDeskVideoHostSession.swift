#if os(macOS)
import AppKit
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import SlopDeskVideoProtocol

/// The host-side session orchestrator for the GUI video path (PATH 2 / Phase 4).
///
/// Wires the components into a working pipeline:
///
/// ```
/// WindowCapturer (NV12 frame) ─▶ VideoEncoder (single-session HEVC + crisp refresh, doc 18 §E)
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
public actor SlopDeskVideoHostSession {
    private let log = Logger(subsystem: "slopdesk.video.host", category: "SlopDeskVideoHostSession")

    /// Opt-in stderr diagnostics (`SLOPDESK_VIDEO_DEBUG=1`). OSLog `.info`/`.debug` aren't persisted,
    /// so a headless verify (`scripts/check-video.sh`) can't read the capture/encode flow from
    /// `log show`; when enabled, lifecycle beats mirror to stderr to pinpoint pipeline stalls. No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil
    /// Burst-resilient transmission interleaving (anti-flicker). DEFAULT ON; `SLOPDESK_INTERLEAVE=0`
    /// reverts to plain consecutive send order. Interleaving is a pure send-order permutation (header /
    /// `fragIndex` untouched, reassembler reorder-tolerant) → NO wire change, so it cannot white-screen
    /// the stream: `slopdesk-loopback-validate` (synthetic→REAL HW HEVC→packetize→interleave→reassemble
    /// →REAL HW decode) reports 120/120 clean at no-loss AND full FEC recovery of the 2- and 3-adjacent
    /// datagram bursts that plain order drops entirely (0/120). The pure ``FragmentInterleaver`` (+ tests)
    /// and the harness scenarios are the regression proof.
    private static let interleaveTransmit = ProcessInfo.processInfo.environment["SLOPDESK_INTERLEAVE"] != "0"
    /// SEND PACING (anti-flicker; reorder-free, no wire change). A large frame (a ~115 KB heartbeat IDR
    /// ≈ 97 datagrams, or a big scroll delta) sent as ONE instant burst overflows the client UDP receive
    /// buffer / WireGuard tunnel → consecutive packet loss → the single-loss XOR FEC cannot recover → a
    /// corrupt frame the next one only half-fixes → FLICKER. Pacing splits a large frame's datagrams into
    /// small chunks separated by a sub-ms gap so the receiver drains them as they arrive; tiny frames
    /// (static-window common case, ~1 datagram) still send instantly.
    ///
    /// DEFAULT **ON** (`SLOPDESK_PACE=0` disables). Un-paced, HW (testufo stars-hdr, 40Mbps, Wi-Fi
    /// client) blasts a 133KB frame as ~110 back-to-back datagrams → 2-13% burst loss → FEC misses →
    /// recovery IDRs + ABR sawtooth 40→20→40Mbps = periodic stutter. Pacing at the EXACT link rate is
    /// the opposite trap — a pure latency harm on a non-lossy link (k=1 serializes a heavy frame over
    /// 30-130ms, backlogging the consumer) — so the gap is computed at a MULTIPLE of the live rate
    /// (``paceRateMultiplier``): bursts capped at k× the sustained rate while the heaviest frame still
    /// drains in ~10ms (≲ a frame interval). Frames ≤ ``paceChunkFragments`` datagrams still send in one
    /// shot (input latency unaffected).
    private static let paceSend = ProcessInfo.processInfo.environment["SLOPDESK_PACE"] != "0"
    /// Frames with at most this many datagrams send in one shot (no pacing) — covers static-window
    /// P-frames and small deltas. Above it, send in chunks of this size with ``paceGapNanos`` between.
    private static let paceChunkFragments = 8
    /// Gap between paced chunks. 0.5 ms × (97/8 ≈ 12 chunks) ≈ 6 ms to drain a heartbeat IDR — well
    /// under the 16 ms frame interval, so the consumer never falls behind. Override µs via `SLOPDESK_PACE_US`.
    private static let paceGapNanos: UInt64 = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_PACE_US"], let v = UInt64(s), v >= 1,
           v <= 10000 { return v * 1000 }
        return 500_000
    }()

    /// RATE-PROPORTIONAL pacing. The fixed `paceGapNanos` (0.5ms) drains an 8-fragment (~9600-byte) chunk
    /// ~13× FASTER than a 12Mbps link absorbs → a big frame blasts ~146Mbps → self-inflicted burst loss
    /// (measured 10–14% on a real scroll) → ABR collapse + FEC failure = the blur/stutter/flicker chain.
    /// When ON (default; `SLOPDESK_PACE_ADAPTIVE=0` reverts to the fixed gap), the inter-chunk gap is
    /// computed so a chunk drains at ≈ the LIVE ABR target (`lastActuatedBitrate`): gap = chunkBytes×8 /
    /// targetBps. slopdesk's equivalent of Parsec's window-AIMD-paced send — never puts more bytes/sec on
    /// the wire than the link drains. An explicit `SLOPDESK_PACE_US` pins a static gap (A/B).
    private static let pacingAdaptive: Bool = {
        if ProcessInfo.processInfo.environment["SLOPDESK_PACE_US"] != nil { return false } // explicit static pin wins
        return ProcessInfo.processInfo.environment["SLOPDESK_PACE_ADAPTIVE"] != "0"
    }()

    /// Link-rate fallback when the ABR target is not yet known (ABR off / pre-warmup).
    private static let pacingFallbackBps = 12_000_000
    /// Pace at this MULTIPLE of the live ABR target (`SLOPDESK_PACE_RATE_X`, default 2.5, clamp
    /// 1–10). k=1 (exact rate) serializes a max frame over ~27ms at 40Mbps — longer than the
    /// 16.7ms frame interval, i.e. the measured "lag grows while you scroll" harm. k=2.5 keeps
    /// the instantaneous burst at 2.5× the sustained rate (gentle on Wi-Fi airtime/WireGuard
    /// queues) while a 133KB worst-case frame drains in ~10ms.
    private static let paceRateMultiplier: Double = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_PACE_RATE_X"], let v = Double(s), v.isFinite {
            return min(10, max(1, v))
        }
        return 2.5
    }()

    /// Clamp the adaptive gap: never faster than 0.2ms (a high ABR target would otherwise ≈0 it), never
    /// slower than 40ms/chunk (a collapsed-to-floor ABR must not serialize a frame into a multi-second stall).
    private static let pacingGapFloorNanos: UInt64 = 200_000
    private static let pacingGapCeilNanos: UInt64 = 40_000_000
    /// Route paced sends through the dedicated ``VideoSendLane`` instead of awaiting the pacing INSIDE
    /// the encoder-output pump: pacing frame N inline delays frames N+1..k → measured send gaps
    /// 28–179ms on the real path (the visible stutter). DEFAULT ON; `SLOPDESK_SEND_LANE=0` selects the
    /// inline `sendPaced` path.
    private static let sendLaneEnabled = ProcessInfo.processInfo.environment["SLOPDESK_SEND_LANE"] != "0"
    /// Pace KEYFRAMES at no less than this rate. A recovery IDR paced at a post-backoff ABR rate
    /// (collapsed to the floor) serializes over 100s of ms — and IDR delivery time IS recovery time.
    /// Measured (iperf3): the path carries 30Mbps with the same ~1% weather loss as 5Mbps, so draining
    /// an IDR at ≥12Mbps costs nothing in loss while cutting the freeze tail.
    /// `SLOPDESK_KF_PACE_FLOOR_BPS` overrides (clamp 1–100 Mbps).
    private static let kfPaceFloorBps: Int = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_KF_PACE_FLOOR_BPS"], let v = Int(s) {
            return min(100_000_000, max(1_000_000, v))
        }
        return 12_000_000
    }()

    /// DELTA send-pace FLOOR. DEFAULT **12 Mbps** (`SLOPDESK_DELTA_PACE_FLOOR_BPS` overrides; an
    /// explicit `0`/negative disables ⇒ `max(ABR, 0) == ABR`, the raw-ABR pacing). A non-keyframe
    /// delta paces at the RAW live ABR; a scroll-onset delta landing on a stale-low static-window ABR
    /// (~4–8Mbps on the 1× 1080p dongle) then serializes over ~30–46ms of pure send-span, and the
    /// depth-1 present-on-arrival client converts that span 1:1 into present-cadence JITTER the loss-0
    /// link never demanded (Parsec blasts the same delta at link rate ≈ 2ms — it paces at a
    /// connection-AIMD window, not at the encoder's low steady-state bitrate). A low-ABR delta drains
    /// at ≥ floor·k instead: the 12Mbps floor ⇒ 30Mbps instantaneous (gap 7.68→2.56ms @4Mbps ABR),
    /// 5× below the ~146Mbps un-paced blast that caused the documented Wi-Fi 2–13% burst loss — so this
    /// FLOORS the pace rate, never UN-paces, and reintroduces no ABR sawtooth. Inert whenever ABR ≥ floor
    /// (an active scene already paces fast). The keyframe floor (same 12M, always-on on this exact path)
    /// is the existence proof the floor is burst-safe. Clamp 1–100 Mbps, mirroring ``kfPaceFloorBps``.
    private static let deltaPaceFloorBps: Int = {
        guard let s = ProcessInfo.processInfo.environment["SLOPDESK_DELTA_PACE_FLOOR_BPS"],
              let v = Int(s) else { return 12_000_000 } // unset ⇒ default floor (HW-validated 07-21)
        guard v > 0 else { return 0 } // explicit 0/negative ⇒ OFF: max(ABR, 0) == ABR ⇒ raw-ABR pacing
        return min(100_000_000, max(1_000_000, v))
    }()

    /// CONGESTION BACKPRESSURE. The paced ``VideoSendLane`` is an unbounded FIFO: under a sustained
    /// scroll burst the encoder outruns the drain, the queue grows without bound, and latency bloats to
    /// seconds (HW-measured RTT 1475ms / client hold 2547ms on a 10ms link — a slowness no env tuning can
    /// fix, since a deep-buffered path triggers no loss-based backoff until the buffer is already huge).
    /// The real-time discipline (Parsec's) is to DROP rather than queue: when ``VideoSendLane/depth``
    /// exceeds ``backpressureDepth``, SKIP feeding the encoder (drop the capture frame BEFORE encode →
    /// the P-frame reference chain stays intact, so the client never sees a decode break, unlike dropping
    /// already-queued frames). fps dips-and-recovers under bursts; latency stays bounded to ≈`depth` frame
    /// intervals. A frame with a forced obligation (keyframe / crisp / compact / LTR-refresh) ALWAYS
    /// passes — recovery/sharpness anchors, never droppable. DEFAULT ON; `SLOPDESK_BACKPRESSURE=0`
    /// disables. `SLOPDESK_BACKPRESSURE_DEPTH` overrides (clamp 1…30).
    private static let backpressureEnabled =
        ProcessInfo.processInfo.environment["SLOPDESK_BACKPRESSURE"] != "0"
    private static let backpressureDepth: Int = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_BACKPRESSURE_DEPTH"], let v = Int(s) {
            return min(30, max(1, v))
        }
        return 3
    }()

    /// SCROLL COALESCING. A fast trackpad scroll + its OS momentum coast is a ~200/s event flood.
    /// Injecting each delta as its own synchronous `CGEvent.post` (i.e. treating `.scroll` as a
    /// non-mergeable barrier, collapsing only mouse-move) saturates the WindowServer → SCStream capture
    /// STALLS (HW-measured 61ms capture-gap / 1210ms send-gap) → the scroll/reversal hitch + jerky
    /// host-side scroll. When ON, the drain SUMS consecutive same-phase scroll deltas → one smooth phased
    /// post per drain (≈ refresh rate, as Parsec/Sunshine and macOS do), preserving total travel.
    /// DEFAULT: **follows the injector's scroll resampler** — OFF while the resampler is active
    /// (it caps the post rate itself, and stacking this summing gate under it double-quantizes the
    /// stream into uneven chunks = scroll ripple + the 60-100ms capture-stall bucket going 25 → 212
    /// HW-measured), ON when the resampler is explicitly disabled (the gate then resumes its
    /// anti-flood job on the direct-post path). Explicit `SLOPDESK_SCROLL_COALESCE=1`/`0` overrides
    /// either way (A/B).
    private static let scrollCoalesceEnabled: Bool = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_SCROLL_COALESCE"] { return s != "0" }
        return !InputInjector.scrollResamplerActive
    }()

    /// Minimum wall-clock interval between injected (summed) scroll events when coalescing is on.
    /// The inbound datagrams are drained one-at-a-time (interleaved with recovery acks), so a pure
    /// per-batch collapse never engages — this TIME GATE holds a delta accumulator ACROSS drains
    /// and posts at most one summed scroll per interval, cutting the ~200/s `CGEvent.post` flood.
    ///
    /// DEFAULT 8ms (~120/s), NOT 1/refresh: the gate's post times are quantized by inbound-datagram
    /// arrival, so a 16.7ms gate makes the host content advance on an IRREGULAR ~60/s lattice that
    /// beats against the display's own 60Hz commit — HW-measured (2026-07-21, RTT 5-8ms link) as the
    /// dominant scroll-smoothness gap vs Parsec: 16.7ms ⇒ capture beat 190×28-40ms gaps/scroll,
    /// windowed fps 33-51; 8ms ⇒ 70 gaps, fps 55-59 ≈ Parsec's 58.8-60 on the same host. 120/s
    /// summed posts stay well under the ~200/s per-delta flood that stalls the WindowServer.
    /// `SLOPDESK_SCROLL_INJECT_MS` overrides (clamp 4…50).
    private static let scrollInjectInterval: Double = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_SCROLL_INJECT_MS"], let v = Double(s),
           v >= 4, v <= 50 { return v / 1000.0 }
        return 0.008
    }()

    // Which scroll phases accumulate lives in ``ScrollCoalescePlanner/isCoalescableScrollPhase`` — the
    // pure planner owns the whole scroll-accumulator fold.

    /// PURE (unit-tested): should this captured frame be SKIPPED for congestion backpressure? Skip iff
    /// backpressure is enabled, the lane is backed up beyond `depthThreshold`, AND the frame carries no
    /// forced obligation. A forced keyframe/crisp/compact/LTR-refresh is a recovery or sharpness anchor
    /// and must always reach the encoder — only ordinary live deltas are droppable.
    static func backpressureSkip(
        enabled: Bool,
        laneDepth: Int,
        depthThreshold: Int,
        forceKeyframe: Bool,
        crisp: Bool,
        compact: Bool,
        ltrRefresh: Bool,
    ) -> Bool {
        guard enabled else { return false }
        if forceKeyframe || crisp || compact || ltrRefresh { return false }
        return laneDepth > depthThreshold
    }

    /// FPS GOVERNOR — regular-cadence content/congestion-adaptive fps. When ON, the host folds
    /// encoded-frame sizes into an ``FPSGovernor`` and ticks it on every NetworkStats report: when
    /// offered load exceeds the actuated bitrate past the QP51 coarsening floor AND congestion evidence
    /// is positive, fps steps DOWN a CLEAN-DIVISOR ladder rung (60→30→20→15) — an alternating frame-skip
    /// instead would give irregular 16.7/33.3 ms intervals, itself the PRIMARY cadence stutter. Actuated
    /// by the capturer's schedule-anchored ``EncodeCadenceGate`` (metronome-regular), a live encoder
    /// `ExpectedFrameRate` hint, and a `streamCadence` message so the client rebases its pacing.
    /// DEFAULT OFF: cadence is this project's highest-sensitivity axis ("user hand-feel is the only valid
    /// metric"), and the established pattern (ABR/LTR/kfDup) is env-gated OFF → HW feel-test → flip the
    /// default. When OFF the host is byte-identical: no gate, no streamCadence message, no self-heal
    /// rebase. `SLOPDESK_FPS_GOVERNOR=1` enables; tunables `SLOPDESK_FPS_GOV_*`.
    private static let fpsGovernorEnabled = ProcessInfo.processInfo.environment["SLOPDESK_FPS_GOVERNOR"] == "1"
    /// In-place SCStream resize (default ON): reconfigure the live stream via `updateConfiguration` on
    /// a window resize instead of restarting it (~120ms SCK spin-up = the resize freeze). HW-validated:
    /// 6 back-to-back pane resizes ALL took the in-place path with NO SCStream restart (capture-gap
    /// stayed ~36ms, never the ~120ms spin-up), 0 errors, loss 0. Display-anchored modes only (the live
    /// default); union/`.window`/any failure fall back to the byte-identical restart path, so correctness
    /// never regresses. `SLOPDESK_INPLACE_RESIZE=0` forces the restart path.
    private static let inPlaceResizeEnabled = ProcessInfo.processInfo.environment["SLOPDESK_INPLACE_RESIZE"] != "0"

    /// PURE (unit-tested): inter-chunk pacing gap (ns) so `chunkFragments × datagramSize` bytes drain at
    /// `targetBps × rateMultiplier`, clamped to `[floorNanos, ceilNanos]`. `targetBps <= 0` ⇒ `fallbackBps`.
    /// `rateMultiplier` (≥1) is the burst-vs-serialization dial: 1 = exact link rate (max frame ~27ms at
    /// 40Mbps — backlogs the consumer), 2.5 (default) = max frame ~10ms while bursts stay 2.5× sustained.
    static func adaptivePaceGapNanos(
        targetBps: Int,
        fallbackBps: Int,
        chunkFragments: Int,
        datagramSize: Int,
        floorNanos: UInt64,
        ceilNanos: UInt64,
        rateMultiplier: Double = 1.0,
    ) -> UInt64 {
        let bps = targetBps > 0 ? targetBps : fallbackBps
        guard bps > 0 else { return ceilNanos }
        let effectiveBps = Double(bps) * max(1.0, rateMultiplier.isFinite ? rateMultiplier : 1.0)
        let chunkBits = Double(chunkFragments * datagramSize) * 8.0
        let gap = chunkBits / effectiveBps * 1_000_000_000.0
        guard gap.isFinite, gap >= 0 else { return ceilNanos }
        return max(floorNanos, min(UInt64(min(gap, Double(ceilNanos))), ceilNanos))
    }

    /// PURE (unit-tested): the pace-TARGET bitrate for a frame — the rate ``adaptivePaceGapNanos`` drains a
    /// chunk at. Keyframes floor at `kfFloorBps` (IDR delivery time IS recovery time); deltas floor at
    /// `deltaFloorBps`, which is 0 by default so `max(abr, 0) == abr` ⇒ delta pace timing is byte-identical
    /// to the pre-floor path. A non-zero delta floor lifts a stale-low scroll-onset delta off the raw ABR so
    /// it drains at ≥ floor·k rather than a 4Mbps crawl — flooring the pace RATE, never un-pacing (see
    /// ``deltaPaceFloorBps``). Inert whenever `abr >= deltaFloorBps` (an active scene).
    static func paceTargetBps(keyframe: Bool, abr: Int, kfFloorBps: Int, deltaFloorBps: Int) -> Int {
        keyframe ? max(abr, kfFloorBps) : max(abr, deltaFloorBps)
    }

    /// KEYFRAME DUPLICATE-SEND. Forward redundancy by REPETITION: re-send a keyframe's datagrams a second
    /// time (paced + time-separated) so a large IDR survives a time-correlated burst loss the single-loss
    /// XOR FEC cannot repair. The only host-only, REORDER-FREE way to add real burst tolerance (the client
    /// reassembler dedups by frameID/fragIndex, so duplicates are harmless and the frame decodes exactly
    /// once → NO white-screen risk). Keyframes ONLY (never deltas). DEFAULT **ON**: the measured worst-case
    /// freeze is a LOST KEYFRAME inside the 500ms recovery-IDR cooldown — the client shows the last good
    /// frame for up to the full window. Duplicating keyframes makes that require BOTH copies of a fragment
    /// lost (weather loss ~1% ⇒ ~1e-4 per fragment), and the ``VideoSendLane`` keeps the duplicate's
    /// time-separation out of the encoder pump. Byte cost is keyframes only, throttled ≤1 dup per 250ms,
    /// on a path measured to carry 30Mbps at the same loss as 5Mbps. `SLOPDESK_KF_DUP=0` disables.
    private static let kfDup = ProcessInfo.processInfo.environment["SLOPDESK_KF_DUP"] != "0"
    /// Throttle so a recovery-IDR burst is not byte-amplified: duplicate at most one keyframe per interval.
    private static let kfDupMinInterval: TimeInterval = 0.25
    /// kfDup engages only when the loss EWMA (`networkEstimate.lossRate`) is at/above this. On a clean
    /// link (LAN/mesh, loss ≈ 0) the keyframe double-send is pure overhead Parsec never pays (it dups
    /// nothing, ever); it re-arms the instant real loss appears — and recovery keyframes happen DURING
    /// loss, so they stay protected. 0.5% mirrors the adaptive-FEC ladder's lowest escalation boundary.
    /// A UNIVERSAL signal: works whether the adaptive-FEC/-m gates are on or off (the adaptive-m tier is
    /// default-OFF, so a tier-only gate would leave the default config always-dupping). `SLOPDESK_KF_DUP_LOSS`.
    private static let kfDupLossThreshold: Double = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_KF_DUP_LOSS"], let v = Double(s), v >= 0 {
            return v
        }
        return 0.005
    }()

    /// How long ``gateRecoveryIDR`` keeps kfDup armed after a recovery-keyframe request (fast-attack
    /// window, uptime seconds). Comfortably covers the recovery IDR's next-capture encode + paced send
    /// even while `lossRate` is still ~0; re-armed on each request through a sustained burst.
    private static let kfDupFastAttackWindow: TimeInterval = 0.5

    /// PURE kfDup decision (unit-tested): duplicate a keyframe iff loss is present (the smoothed EWMA is
    /// at/above threshold — steady loss) OR the fast-attack window is still open (a recovery IDR was just
    /// requested — closes the EWMA's leading-edge lag so the FIRST re-anchor IDR of a burst is protected
    /// even before the burst's `unrecovered` count folds into `lossRate`). On a clean link neither holds,
    /// so the heartbeat crisp IDR is NOT dupped — the bandwidth win Parsec has.
    static func shouldDupKeyframe(
        lossRate: Double,
        nowUptime: TimeInterval,
        fastAttackUntil: TimeInterval,
        threshold: Double,
    ) -> Bool {
        lossRate >= threshold || nowUptime < fastAttackUntil
    }

    /// SMALL-FRAME DUPLICATE-SEND. DEFAULT OFF (`SLOPDESK_SMALL_DUP=1`).
    ///
    /// A CHANGED small DELTA frame (a keystroke / caret — typically 1 fragment) can be wiped WHOLE
    /// by a loss burst (its data AND parity fragments lost together) — FEC recovers lost fragments
    /// *within* a frame, never a fully-lost frame. Duplicate-send it time-separated (like a keyframe)
    /// so it survives unless BOTH copies are lost → protects typing responsiveness on a lossy WAN.
    /// Gated on the link being CURRENTLY lossy (an elevated adaptive-`m` FEC tier, i.e. not the
    /// relaxed CLEAN level) so an idle/static stream — every frame a tiny byte-identical delta — is
    /// NOT doubled. Requires adaptive-m (the live WAN config); inert otherwise.
    private static let smallDup = ProcessInfo.processInfo.environment["SLOPDESK_SMALL_DUP"] == "1"
    /// A frame qualifies as "small" for ``smallDup`` when its encoded byte length is at most this
    /// (a keystroke delta is ~100–500 B / ~1 MTU; a scroll frame is KB–tens-of-KB and relies on FEC,
    /// not duplication). Default ~1 MTU-and-a-bit so only genuine 1-fragment deltas qualify.
    private static let smallDupMaxBytes: Int =
        ProcessInfo.processInfo.environment["SLOPDESK_SMALL_DUP_MAX_BYTES"].flatMap(Int.init) ?? 1400
    /// NACK / selective-ARQ retransmit. DEFAULT OFF (`SLOPDESK_NACK=1`; deploy host +
    /// client together). When on, the host keeps a bounded ring of recently-sent frame datagrams so a
    /// client NACK (``RecoveryDatagramRouter/Decision/retransmitFragments(frameID:fragIndices:)``) is
    /// answered by re-sending exactly the missing fragments — cheaper than a recovery-IDR, and with
    /// the client's playout buffer ≫ RTT it lands before playout (no stutter). The client mirrors the
    /// gate (its reassembler holds a FEC-unrecoverable frame for the retransmit grace + NACKs the
    /// missing fragments). A ring miss (frame aged out) is a no-op; the LTR-refresh path is the
    /// fallback.
    private static let nackEnabled = ProcessInfo.processInfo.environment["SLOPDESK_NACK"] == "1"
    /// Retransmit ring depth in FRAMES (~`/60`s at 60fps): the loss-detect + NACK + retransmit round
    /// trip is a few frames, so a generous history covers it. Bounded jointly by bytes below.
    private static let retransmitRingFrames =
        ProcessInfo.processInfo.environment["SLOPDESK_NACK_RING_FRAMES"].flatMap(Int.init) ?? 96
    /// Retransmit ring byte ceiling (an IDR is large; cap total history so the ring can't bloat).
    private static let retransmitRingMaxBytes =
        ProcessInfo.processInfo.environment["SLOPDESK_NACK_RING_BYTES"].flatMap(Int.init) ?? (8 << 20)

    /// The NACK retransmit ring (see ``RetransmitRing``) — `nil` (no memory) unless ``nackEnabled``.
    private var retransmitRing: RetransmitRing? = SlopDeskVideoHostSession.nackEnabled
        ? RetransmitRing(
            maxFrames: SlopDeskVideoHostSession.retransmitRingFrames,
            maxBytes: SlopDeskVideoHostSession.retransmitRingMaxBytes,
        )
        : nil
    /// DELIVERY-KEYED RECOVERY-IDR COOLDOWN. DEFAULT **ON**; `SLOPDESK_RECOVERY_IDR_V2=0` restores the
    /// sent-keyed 500 ms capturer gate byte-for-byte (host-side only; the wire fields are unconditional
    /// and simply ignored in that mode). When ON, the two IDR-issuing recovery paths (`.forceKeyframe` +
    /// the `.refreshLTR`→`.idr` fallback) pass through ``RecoveryIDRPolicy`` — delivery-keyed cooldown +
    /// casualty bypass + token bucket — and the capturer's `minRecoveryIDRInterval` gate goes inert (0).
    /// An LTR refresh is NEVER gated. Default-ON rationale: the suppression set is strictly
    /// narrower-or-provably-correct vs the sent-keyed gate except the grace window (40-250 ms ≪ 500 ms),
    /// the sustained IDR rate cap is identical (2/s), and the wire fields ship unconditionally anyway —
    /// one env flips back exactly.
    private static let recoveryIDRV2 = ProcessInfo.processInfo.environment["SLOPDESK_RECOVERY_IDR_V2"] != "0"
    /// Tunables for the V2 policy: `SLOPDESK_IDR_TOKENS` (bucket capacity, clamp 1...4),
    /// `SLOPDESK_IDR_REFILL_MS` (ms per token, clamp 100...5000 — default 500 = the sent-keyed spacing),
    /// `SLOPDESK_IDR_GRACE_MS` (pins floor=ceil for A/B, clamp 0...1000; unset = adaptive
    /// clamp(0.75×smoothedRTT, 40, 250) ms).
    private static let recoveryIDRConfig: RecoveryIDRPolicy.Config = {
        var config = RecoveryIDRPolicy.Config()
        let env = ProcessInfo.processInfo.environment
        if let s = env["SLOPDESK_IDR_TOKENS"], let v = Double(s), v.isFinite {
            config.bucketCapacity = min(4, max(1, v))
        }
        if let s = env["SLOPDESK_IDR_REFILL_MS"], let v = Double(s), v.isFinite {
            config.refillTokensPerSecond = 1000.0 / min(5000, max(100, v))
        }
        if let s = env["SLOPDESK_IDR_GRACE_MS"], let v = Double(s), v.isFinite {
            let pinned = min(1000, max(0, v)) / 1000.0
            config.graceFloorSeconds = pinned
            config.graceCeilSeconds = pinned
        }
        return config
    }()

    /// NETWORK-FEEDBACK TELEMETRY. DEFAULT ON; disable with `SLOPDESK_NETSTATS=0`. When ON, every
    /// outgoing video fragment is stamped with the host-relative send time and the host folds the
    /// client's periodic NetworkStats reports into a NetworkEstimate. When "0", the host writes a
    /// 0 timestamp → the client observes 0 → reports `latestHostSendTs = 0` → the RTT fold is skipped
    /// (computeRTTMillis returns nil) and the path stays open-loop. The 4-byte wire field is present
    /// either way (fixed header layout).
    private static let telemetryEnabled = ProcessInfo.processInfo.environment["SLOPDESK_NETSTATS"] != "0"
    /// ADAPTIVE BITRATE. DEFAULT **ON**; `SLOPDESK_ABR=0` reverts to open-loop. When ON the host
    /// folds each client NetworkStats report (already done for telemetry) into a
    /// ``LiveCongestionController`` and actuates the resulting target via ``VideoEncoder/setLiveBitrate(_:)``.
    /// When OFF the controller is never seeded/ticked, so `setLiveBitrate` is never called and the live
    /// rate stays pinned at the resolution-aware ceiling. Needs telemetry reports to ever tick (if the
    /// client sets `SLOPDESK_NETSTATS=0` no reports arrive ⇒ the controller never fires ⇒ inert).
    /// Default-ON rationale: the controller is weather-proof (it holds the rate on uncorroborated loss and
    /// backs off only on queue evidence or sustained collapse), so the closed loop is pure upside — on a
    /// clean LAN/loopback it sits inert at the ceiling.
    private static let abrEnabled = ProcessInfo.processInfo.environment["SLOPDESK_ABR"] != "0"
    /// ADAPTIVE FEC. DEFAULT **ON**; `SLOPDESK_ADAPTIVE_FEC=0` pins the static always-g5 tier. When
    /// ON the host picks a per-frame XOR-parity group size (``AdaptiveFECPolicy``) from the folded loss
    /// EWMA and signals it in each fragment's flags so the client splits data/parity identically. When OFF
    /// the host always sends tier 0 (the configured `fec.groupSize`, 5 in prod) → spare flag bits stay
    /// zero. Needs telemetry reports to ever change tier (if the client sets `SLOPDESK_NETSTATS=0` no
    /// reports arrive ⇒ the tier stays at tier 0, never OFF). Default-ON rationale: on a clean path (loss
    /// EWMA <0.2%) the tier relaxes toward less parity — the standing 20% overhead is paid ONLY while loss
    /// exists; the ~1s one-step-per-report re-escalation window at loss onset is covered by
    /// SLOPDESK_SELF_HEAL (any whole-frame loss self-heals ≤K frames with no round-trip) + client recovery
    /// + kfDup. FEC LADDER FLOOR: relaxation FLOORS at g10 (tier 2, ~10% overhead) — walking all the way
    /// to OFF is measurably harmful (18 OFF-tier visits on a 0.1-0.6%-baseline path produced 102
    /// unrecovered losses / 65 decode-fails in 169s). `SLOPDESK_FEC_ALLOW_OFF=1` re-allows the walk to OFF.
    private static let adaptiveFECEnabled = ProcessInfo.processInfo.environment["SLOPDESK_ADAPTIVE_FEC"] != "0"
    /// ADAPTIVE-`m` ladder gate (`SLOPDESK_ADAPTIVE_FEC_M=1`, default OFF; requires a multi-loss
    /// codec `SLOPDESK_FEC_M>=2`). When on, the host steps the per-frame parity multiplicity `m`
    /// by loss (tiers 5/6/7 → m 2/3/5) instead of the group-size tier — lower overhead on a clean
    /// link (smaller frames → less WAN airtime → fewer RTT spikes), heavier recovery on a burst.
    /// Resolved in ``AdaptiveFECPolicy`` (the SAME gate the `wireTier` passthrough reads). The
    /// client needs no flag (its reassembler honours the per-frame wire tier); deploy with matched
    /// `FEC_M`.
    private static let adaptiveMEnabled = AdaptiveFECPolicy.adaptiveMEnabled
    /// FULL-RANGE COLOR. DEFAULT OFF; enable with `SLOPDESK_FULL_RANGE=1`. ONE flag flips ALL
    /// FOUR atomic points together: (1) the capturer's NV12 pixel-format variant, (2) the encoder's
    /// explicit BT.709 VUI keys, (3) the `helloAck.fullRange` byte the host sends, and — because the
    /// client derives its decoder pixel-format + shader coefficients FROM that byte — (4) the client
    /// decoder + Metal shader. When OFF all four stay video-range. Read once (env static, like the flags
    /// above). NOTE: this is a HOST flag only — the client follows the stream, so there is NO matching
    /// client env to keep in sync (the desync footgun is unreachable).
    private static let fullRange = ProcessInfo.processInfo.environment["SLOPDESK_FULL_RANGE"] == "1"
    /// LONG-TERM-REFERENCE RECOVERY. DEFAULT **ON** (`SLOPDESK_LTR=0` disables); HW probe on this
    /// host reports VERDICT=supported. When ON: the encoder sets EnableLTR + reads the per-frame ack
    /// token, LTR frames carry the `isLTR` wire bit, the client acks decoded LTR frames, and a
    /// `requestLTRRefresh` recovers via a cheap `ForceLTRRefresh` P-frame against an ACKNOWLEDGED token
    /// (the ACKED-ONLY invariant) instead of a full IDR — falling back to a real IDR when no token is
    /// acked. When OFF: EnableLTR unset, no token read, no `isLTR` bit, `.refreshLTR` folds to
    /// `requestKeyframe()`, and the client sees no LTR frame so sends no ack. Read once (env static, like
    /// the flags above).
    ///
    /// Default-ON rationale: on the real path loss is weather (rate-independent ~1% + 3-9% bursts), so
    /// recovery happens many times a minute and its COST is what the user feels. With LTR off every
    /// recovery is a full IDR + client decoder rebuild; with LTR on it is a cheap ForceLTRRefresh P-frame
    /// against an acked token, no decoder flush — Parsec-class next-frame self-healing recovery.
    private static let ltrEnabled = ProcessInfo.processInfo.environment["SLOPDESK_LTR"] != "0"
    /// Full per-event injection trace (`SLOPDESK_INPUT_TRACE=1`): logs EVERY injected input event
    /// with a monotonic sequence number (NOT sampled), so a loopback run can read the exact
    /// injected ORDER — the ground truth for input-ordering bugs. No-op in production.
    private static let inputTrace = ProcessInfo.processInfo.environment["SLOPDESK_INPUT_TRACE"] != nil
    private var encodedFrameCount = 0
    /// Uptime seconds of the last keyframe whose datagrams were duplicate-sent (the kfDup throttle).
    private var lastKeyframeDupTime: TimeInterval = 0
    /// kfDup FAST-ATTACK deadline (uptime seconds; 0 = disarmed). The loss-EWMA gate lags — it only moves
    /// when a 50ms NetworkStats report folds, so at a clean→burst edge the client's recovery-IDR request
    /// can reach the send path BEFORE the burst's `unrecovered` count is folded, leaving that first
    /// re-anchor IDR un-dupped (the load-bearing case kfDup exists for). ``gateRecoveryIDR`` arms this the
    /// instant a recovery keyframe is requested — independent of report timing — so the recovery IDR is
    /// dupped even while `lossRate` is still ~0. Mirrors the FEC ladder's raw-`unrecovered` fast-attack.
    private var kfDupFastAttackUntil: TimeInterval = 0
    /// Monotonic anchor for the per-fragment `hostSendTsMillis` stamp + the RTT fold (the network-
    /// feedback channel). Captured at init BEFORE any frame, so every stamp and `hostRelativeMillis()`
    /// share ONE epoch — RTT is `(hostNow − stamp) − clientHold`, all in this single clock domain
    /// (zero cross-machine skew). A reconnect that re-creates the actor resets the anchor; a stale
    /// stamp echoed from a prior session is rejected by `NetworkEstimate.computeRTTMillis` (elaps<0 / >60s).
    private let sessionStartUptime = ProcessInfo.processInfo.systemUptime
    /// Monotonic time (systemUptime) of the most recent inbound client datagram of ANY kind — the
    /// CLIENT-SILENCE video-pause signal (see ``clientSilencePauseSeconds``). Seeded to session start
    /// (and re-seeded on each `startCapture`) so a fresh/reconnected stream is never instantly
    /// "silent". Actor-isolated (stamped in ``receiveBatch``, read on the 1 s heartbeat).
    private var lastClientInboundUptime = ProcessInfo.processInfo.systemUptime
    /// Sticky-true once the client has sent feedback (a `networkStats` report) — proves a modern
    /// feedback-speaking client, so the pause (like the idle-reaper's never-reap-without-keepalive
    /// rule) never fires on a legacy client that never reports. Reset per `startCapture`.
    private var sawClientFeedback = false
    /// The client-silence pause state currently pushed to the capturer — so the 1 s heartbeat only
    /// re-pushes on a TRANSITION, not every tick.
    private var videoPausedForSilence = false
    /// Host-side network estimate folded from the client's periodic NetworkStats reports. A pure value
    /// type — no reference capture, so no retain-cycle risk.
    private var networkEstimate = NetworkEstimate()
    /// Delivery-keyed recovery-IDR admission (sent-keyframe ring + decode-acked id + casualty bypass +
    /// token bucket). Pure value type, consulted ONLY by ``gateRecoveryIDR(lastDecoded:)`` when
    /// `SLOPDESK_RECOVERY_IDR_V2` is on. Deliberately NOT reset on encoder rebuilds (see
    /// ``resetLTRForNewEncoder()``).
    private var recoveryIDRPolicy = RecoveryIDRPolicy(config: SlopDeskVideoHostSession.recoveryIDRConfig)
    /// Collapses the client's byte-identical redundant copies of one logical recovery request (3×
    /// spaced 3 ms) back to ONE host action. Gates ONLY the `.forceKeyframe` / `.refreshLTR` arms —
    /// `.ack`/`.networkStats`/`.reshipCursorShape` legitimately repeat. Required on the LTR path in its
    /// own right: it has no cooldown, so copies straddling a capture-frame boundary would otherwise
    /// encode a second `ForceLTRRefresh`.
    private let recoveryDeduper = RecoveryRequestDeduper(windowSeconds: SlopDeskVideoHostSession.recoveryDedupWindow)
    /// `SLOPDESK_RECOVERY_DEDUP_MS` (default 25, clamp 0...200; 0 disables — every datagram
    /// admitted). COUPLED to the client spacing: ≥ 2× the max copy spread ((copies−1)·spacing =
    /// 12 ms at copies=5, spacing 3 ms) + reorder skew — duplicates do NOT refresh the window
    /// timestamp, so the margin must absorb the whole spread — yet < every legitimate re-request
    /// spacing (lossy escalation floor, 60 ms; at the resolved defaults 25 ms < 60 ms with room to
    /// spare, pinned by the coupling test). Internal (not private) so the coupling test can assert
    /// against the RESOLVED constants.
    static let recoveryDedupWindow: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_RECOVERY_DEDUP_MS"],
           let v = Double(s), v >= 0, v <= 200 { return v / 1000.0 }
        return 0.025
    }()

    /// ADAPTIVE BITRATE controller (only seeded when `SLOPDESK_ABR=1`). A pure value type re-seeded
    /// at every encoder build so a resize re-anchors it to the new resolution's ceiling. `nil` ⇒ ABR
    /// off or no encoder yet ⇒ no actuation.
    private var congestionController: LiveCongestionController?
    /// OWN RATE-CONTROL link-AIMD on QP: drives the encoder's CONSTANT QP from the ABR's per-report
    /// congestion verdict (a cut reason ⇒ congested → coarsen Q; clean → sharpen slowly), so the
    /// constant-quality stream adapts to the link without VT's VBR clawback. `nil` unless const-QP mode
    /// is on (`VideoEncoder.constQP != nil`). The ABR's congestion detection is reused rather than
    /// duplicated — under const-QP its verdict is exactly what drives Q.
    private var qpController: QPController?
    /// The last bitrate actually pushed to the encoder via `setLiveBitrate`, so the controller's small
    /// per-tick additive moves are throttled to MATERIAL changes (the controller's `current` advances
    /// every tick; actuation compares against THIS, not the prior tick). Re-anchored to the ceiling at
    /// each encoder build.
    private var lastActuatedBitrate = 0
    /// ABR utilization signal (the idle-ramp guard): an EWMA of the encoded DELTA-frame byte size
    /// (anchors excluded, same as the FPS governor), tracked INDEPENDENTLY of the FPS governor (which is
    /// usually off) so it is always available at the ABR tick. `offeredBps = ewma × 8 × governedFps`
    /// feeds `LiveCongestionController.decide(_:offeredBps:)`, which suppresses the additive probe while
    /// the stream is application-limited (idle / near-static screen) — so an idle period can't inflate
    /// the target into phantom headroom that a sudden scroll then overshoots into bufferbloat. `0` until
    /// the first delta frame (⇒ pass `nil` ⇒ no gate, the warmup default).
    private var offeredBytesPerFrameEWMA: Double = 0
    /// EWMA smoothing for ``offeredBytesPerFrameEWMA`` (matches the FPS governor's 0.125).
    private static let offeredEWMAAlpha = 0.125
    /// Send-gap probe (`SLOPDESK_VIDEO_DEBUG`): last frame-send start, actor-owned. A >28ms gap between
    /// two frame sends during continuous motion means the hole formed at/before encode (a clean capture
    /// gap ⇒ the encoder/actor pump is the culprit); pairs with the capturer's own capture-gap trace.
    private var dbgLastFrameSendAt: Double = 0
    /// Current adaptive-FEC tier + relax-dwell streak. Starts at tier 0 (the configured
    /// `fec.groupSize`, g5) so the stream matches the static path until a real netstats report folds loss
    /// and (only when adaptive FEC is on) moves it. With no reports it never moves — inert at the safe
    /// default, never OFF. The dwell (`AdaptiveFECPolicy.relaxDwellReports`) makes relaxation require
    /// ~12s of consecutively clean reports, so a 4G burst-flap cannot relax parity mid-storm.
    private var fecTierState = SlopDeskVideoHostSession.adaptiveMEnabled
        // Adaptive-m: seed at the NORMAL parity level (tier 6, m=3 = the fixed baseline) so
        // the very first frame already rides the m-ladder's tier set (5/6/7) and `wireTier` passes
        // it through cleanly — the ladder then relaxes toward CLEAN (m2) or escalates to BURST (m5).
        ? AdaptiveFECPolicy.TierState(tier: AdaptiveFECPolicy.parityTierNormal)
        : AdaptiveFECPolicy.TierState()
    /// LTR recovery bookkeeping (pure value type — no reference capture, no retain-cycle risk).
    /// Records `frameID ↔ ack-token` for emitted LTR frames and the set of tokens the client has
    /// ACKNOWLEDGED, both bounded. Only mutated when `SLOPDESK_LTR=1`; inert (never recorded/acked) when
    /// off, so a `.refreshLTR` decision always falls back to a real IDR.
    private var ltrController = LTRController()
    private nonisolated func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("slopdesk-videohostd[session]: \(message())\n".utf8))
    }

    private let transport: any VideoDatagramTransport
    /// The window target (the classic per-window session). Exactly one of `window`/`display` is set.
    private let window: SCWindow?
    /// The DISPLAY target (the full-desktop pane): capture the whole display, no parking, no
    /// geometry watcher, no AX raise. Exactly one of `window`/`display` is set.
    private let display: SCDisplay?
    /// The target's id for logging (windowID or displayID).
    private var targetID: UInt32 { window.map { UInt32($0.windowID) } ?? display?.displayID ?? 0 }
    /// Capture/encode at `window points × captureScale` PIXELS — 2 (Retina) gives sharp text;
    /// the helloAck/cursor mapping stays in POINTS so coordinates are unaffected.
    private let captureScale: Double
    /// Authoritative POINT capture size, set by the daemon when it AX-moves/resizes the window onto
    /// the HiDPI virtual display (feature #1): the achieved post-move size, NOT the stale `SCWindow.frame`
    /// snapshot. Drives both the `helloAck` captureWidth/Height (client input-mapping denominator) and
    /// the SCStream size, so a window resized DOWN to fit the VD is captured + acked at its real new
    /// size (no over-crop, no input desync). `nil` ⇒ no VD move happened ⇒ size from `window.frame`
    /// as before (default-path behaviour unchanged).
    private let captureSizeOverride: VideoSize?
    /// Upper bound (POINTS) for a client-driven in-session resize, set by the daemon to the VD's point
    /// size when the window is parked on the VD (feature #1). A resize larger than the VD framebuffer
    /// would push the capture crop past the display → over-crop / soft capture, so the resize target
    /// is clamped to this. `nil` ⇒ no VD parking ⇒ only the UInt16 wire limit applies (unchanged).
    private let resizePointLimit: VideoSize?
    /// Live-encoder target bitrate (bits/sec). Higher = crisper text (HEVC softens glyph edges
    /// at low bitrate); raise it over LAN/NetBird where bandwidth is ample.
    private let bitrate: Int
    /// Capture + encoder frame-rate cap (fps), set by the CALLER per pane kind — threaded into every
    /// `WindowCapturer`/`VideoEncoder` this session builds. Window/terminal (coding) panes run the
    /// `--fps` default (30, latency-first + WAN-frugal); the FULL-DESKTOP pane runs `resolveDisplayFps`
    /// (60 default) for Parsec-class scroll/motion smoothness (30 was visibly steppier on a whole
    /// desktop). `LiveBitratePolicy` provisions the bitrate ceiling from area × THIS fps, so 60 also
    /// lifts the ceiling ~2× — the two together are the felt smoothness delta vs Parsec.
    private let fps: Int
    private let scheduler = VideoSendScheduler()
    private let recoveryRouter = RecoveryDatagramRouter()

    private var stateMachine: VideoSessionStateMachine
    /// The send-path packetize lane (keystroke latency): OWNS the `VideoPacketizer` (MTU-split,
    /// per-frame FEC parity, header stamp, interleave — all native Swift) on its own serial executor, so
    /// that heavy per-frame work does not block this actor's input consumer. `onEncodedFrame` awaits it
    /// (a suspension point → keystrokes interleave) and records LTR / recovery-IDR / NACK-ring
    /// bookkeeping against the RETURNED frameID. The lane persists across encoder rebuilds/resizes, so
    /// frameIDs stay monotonic for the whole session.
    private let packetizeLane: PacketizeLane

    // Live components, created on accept (never in a test).
    private var capturer: WindowCapturer? {
        didSet {
            // SCROLL REPROJECTION: wire every freshly-installed capturer to forward its host-measured
            // per-frame scroll offset as a `ScrollOffset` control message. Set on EVERY (re)build —
            // initial start, resize, encoder rebuild — so reprojection survives them. The capturer only
            // measures + calls this when SLOPDESK_SCROLL_REPROJECT=1, so this is inert otherwise.
            capturer?.onScrollOffset = { [weak self] dx, dy, bandTop, bandBottom in
                Task { await self?.sendScrollOffset(dx: dx, dy: dy, bandTop: bandTop, bandBottom: bandBottom) }
            }
            // CAPTURE-DEATH: wire every freshly-installed capturer to
            // report its SCStream dying out from under us (window closed, display unplugged, TCC
            // revoked, WindowServer reset). Fires on the capturer's frameQueue AFTER the capturer
            // quiesced its own synthetic-frame machinery; hop onto the actor to decide. The closure
            // captures THIS instance (weakly) so a stale (superseded-by-resize) capturer's death is
            // distinguishable from the currently-installed one's — `onCaptureDied` ignores the former.
            if let installed = capturer {
                installed.onCaptureFailed = { [weak self, weak installed] in
                    guard let self, let installed else { return }
                    Task { await self.onCaptureDied(installed) }
                }
            }
            // APP-AUDIO: point every freshly-installed capturer's `.audio` tap at the SESSION-
            // lifetime lane (so the wire seq stays monotonic across resize/dialog-expand
            // rebuilds), and re-assert the cheap forwarding gate — a rebuilt capturer starts with
            // the gate down, and a mid-session resize must not silently kill enabled audio. The
            // sink runs on the capturer's audio queue; the lane is `@unchecked Sendable`. Inert
            // (nil sender) when `SLOPDESK_AUDIO=0` masters the feature off.
            if let installed = capturer, let sender = ensureAudioSender() {
                installed.onAudioSampleBuffer = { [sender] buffer in sender.handle(buffer) }
                installed.setAudioForwardingEnabled(sender.isEnabled)
            }
        }
    }

    private var encoder: VideoEncoder?
    private var geometryWatcher: WindowGeometryWatcher?
    private var cursorSampler: CursorSampler?
    private var injector: InputInjector?
    /// Held-button/modifier balance carried ACROSS injector rebuilds (the reconnect-stuck-drag
    /// fix). A transparent auto-reconnect (SCStream death / wifi flap → bye → fresh hello) rebuilds
    /// the `InputInjector` while the user may still be PHYSICALLY holding a drag or ⌘; a fresh
    /// empty ``InputButtonBalance`` would classify their eventual mouseUp/keyUp as an orphan →
    /// suppress → the terminating CGEvent is never posted → host OS wedged in drag/modifier state
    /// (AppKit mouse-tracking loops hang; a latched ⌘ corrupts all subsequent input). Teardown
    /// snapshots the stale injector's balance here; the next `startLiveComponents` seeds the new
    /// injector from it, so the post-reconnect up matches and posts normally. A deliberate session
    /// END (bye/stop with NO successor hello) never reads this — behaviour there is unchanged; and
    /// carrying into a much-later fresh hello is safe (a stale held entry either matches a genuinely
    /// still-stuck host button, releasing it, or is healed by the pre-release path on the next down).
    private var carriedInputBalance = InputButtonBalance()
    /// Whether the next injected input event must raise+focus first.
    private var inputNeedsRaise = true

    /// DIALOG-EXPAND state (host-only feature; armed only when the window is VD-parked AND the
    /// feature env is on). The current capture region in GLOBAL points: `nil` ⇒ the plain window
    /// frame; non-nil ⇒ a union (window ∪ an attached file-open/print dialog) so the dialog shows in
    /// full and is clickable. ``onAssociatedUnion`` drives transitions; the input/cursor mapping
    /// origin tracks this rect so clicks land in the dialog area (capture-region math in the Rust core).
    private var dialogExpandArmed = false
    private var captureRegionGlobal: CGRect?
    /// Monotonic epoch for host-initiated capture-region `resizeAck`s (distinct space from the
    /// client-driven resize epoch; the client does not re-validate ack epochs).
    private var captureRegionEpoch: UInt32 = 1 << 24
    /// Re-entrancy guard so overlapping union polls can't launch concurrent region rebuilds.
    private var captureRegionRebuilding = false
    /// Debounce timer for contracting the capture region back to the window frame (flicker cut — a
    /// quick menu open→close must not rebuild the encoder twice). Cancelled by a fresh expand.
    private var pendingContractTask: Task<Void, Never>?
    /// Feature gate: default ON when display-anchored (VD-parked); `SLOPDESK_DIALOG_EXPAND=0` disables.
    static let dialogExpandEnabled = ProcessInfo.processInfo.environment["SLOPDESK_DIALOG_EXPAND"] != "0"

    /// Ordered + COALESCING inbound pump — input ORDER and input LATENCY in one structure.
    /// The transport delivers datagrams in strict arrival order on its serial receive queue; it
    /// APPENDS each to `inboundQueue` synchronously (no actor hop, so arrival order is carried
    /// end-to-end) and signals `inboundWakeup`. A SINGLE consumer task wakes, BATCH-DRAINS the
    /// whole backlog, and `receiveBatch` collapses consecutive pointer-motion runs to their
    /// latest (``InputMotionCoalescer``) before injecting. A per-datagram `Task { await receive }`
    /// fan-out instead would give no FIFO guarantee across separately-created Tasks: a `mouseUp`
    /// could overtake its `mouseDown` and stick a button down. Coalescing also stops a 150:1
    /// motion-heavy flood from accruing multi-second lag by replaying every stale position: when the
    /// consumer keeps up the batches are size ~1 (coalescing is a no-op); only when it falls behind
    /// does a run collapse, bounding the lag to ~one injection. Control and recovery datagrams ride
    /// the same FIFO and are never dropped or reordered.
    private var inboundQueue: InboundQueue?
    private var inboundWakeup: AsyncStream<Void>.Continuation?
    private var inboundConsumer: Task<Void, Never>?

    /// Ordered encoder-OUTPUT pump. `VideoEncoder` is RealTime + AllowFrameReordering=false, so its VT
    /// output callback fires in STRICT encode order on a serial queue. It APPENDS to this lock-protected
    /// FIFO synchronously (carrying encode order end-to-end) and signals; a SINGLE consumer task drains
    /// it and `await`s ``onEncodedFrame(avcc:keyframe:crisp:)`` IN ORDER, so the packetize lane assigns
    /// frameID/streamSeq in encode order. A `Task { await self.onEncodedFrame(...) }` per frame instead
    /// would race frames onto the actor with NO FIFO guarantee across separately-created Tasks: frame N+1
    /// could be packetized (and get a LOWER frameID/streamSeq) before frame N → the client sees a delta
    /// before its IDR → awaitingKeyframe drop + a needless requestIDR. ONE ordered hop, not one detached
    /// Task per frame. Shared across resize (the queue/consumer are the actor's, created once in
    /// ``start()``); every encoder-callback site feeds the SAME queue.
    private var encodedQueue: EncodedFrameQueue?
    private var encodedWakeup: AsyncStream<Void>.Continuation?
    /// Dedicated paced-send lane (created in ``start()``, closed in ``stop()``, flushed on media
    /// teardown). `nil` before start / after stop / when `SLOPDESK_SEND_LANE=0`.
    private var sendLane: VideoSendLane?
    private var encodedConsumer: Task<Void, Never>?
    /// FPS GOVERNOR (only seeded when `SLOPDESK_FPS_GOVERNOR=1`). A pure value type, re-seeded at the
    /// INITIAL encoder build only (governor state deliberately persists across resize — path
    /// knowledge, like the congestion controller's knee would be if it survived; the capturer/
    /// encoder latches are re-applied at every install site instead). `nil` ⇒ governor off.
    private var fpsGovernor: FPSGovernor?
    /// The fps the governor currently has actuated (== `fps` until a step). Drives the capturer
    /// gate latch + encoder hint re-application at resize and the streamCadence dup-send.
    private var governedFps: Int
    /// USER STREAM SETTINGS (wire `streamSettings`, clamped by ``UserStreamSettingsPolicy``):
    /// the client's live fps cap and bitrate ceiling for THIS session. `nil` = auto. Reset at
    /// every `.startCapture` — the settings die with a session re-mint; the client re-sends its
    /// last-requested values after the fresh helloAck.
    private var userFPSCap: Int?
    private var userBitrateCeilingBps: Int?
    /// The resolution-aware policy ceiling of the CURRENT encoder build (re-stamped by
    /// ``seedCongestionController(ceiling:)``). The ABR-off actuation baseline for the user
    /// bitrate ceiling — with ABR on, the controller's own `effectiveCeiling` rules instead.
    private var policyCeilingBps = 0

    /// The encode cadence actually in force: the governor's output clamped by the user fps cap
    /// (`min`); with no cap this is exactly `governedFps`, so every pre-override path is untouched.
    private var effectiveStreamFps: Int {
        UserStreamSettingsPolicy.effectiveFps(governed: governedFps, userCap: userFPSCap)
    }

    /// HOST→CLIENT HEARTBEAT (stall-scrim liveness): a 1 s
    /// (``KeepaliveTiming/hostHeartbeatInterval``) actor-owned Task sending a zero-body `keepalive` on
    /// the control channel while streaming, so the client can tell a healthily-IDLE window (idle-skip
    /// suppresses frames by design) from a DEAD/unreachable host and overlay its "Reconnecting…"
    /// scrim. Wire type 6 is documented wire-safe in both directions — an old client's FSM drops it
    /// inertly — so this is behaviour-only, no wire change. Started on `.startCapture`, cancelled on
    /// `.stopCapture` + ``stop()`` (a bye → `.listening` session must go silent so the client's stall
    /// monitor sees the truth).
    private var heartbeatTask: Task<Void, Never>?

    /// APP-AUDIO lane: the SESSION-lifetime encode→send state for channel tag 6 (seq stays
    /// monotonic across capturer rebuilds — the packetize lane's frameID discipline). Built
    /// lazily at the first capturer install (``ensureAudioSender()``); stays nil for the whole
    /// session when `SLOPDESK_AUDIO=0` masters the feature off.
    private var audioSender: AudioStreamSender?
    /// The client's per-session `audioControl` wish. Default OFF, reset at every `.startCapture`
    /// so a re-minted session starts silent until the client re-sends its wish after the fresh
    /// helloAck — the exact `userFPSCap`/`userBitrateCeilingBps` discipline.
    private var audioEnabled = false

    /// Builds (once) the session's audio lane. nil ⇒ `SLOPDESK_AUDIO=0` — the capturer then has
    /// no audio tap either, so the whole feature is off end-to-end.
    private func ensureAudioSender() -> AudioStreamSender? {
        guard WindowCapturer.audioCaptureEnabled else { return nil }
        if let audioSender { return audioSender }
        let sender = AudioStreamSender(transport: transport, sessionStartUptime: sessionStartUptime)
        audioSender = sender
        return sender
    }

    /// - Parameters:
    ///   - window: the desktop-independent window to remote.
    ///   - transport: the UDP datagram transport (production: a ``VideoMuxChannelTransport`` lane on the shared ``NWVideoMuxDatagramTransport``).
    ///   - fec: optional FEC scheme for the video packetizer. The DEFAULT is the process's env-gated
    ///     scheme (``AdaptiveFECPolicy/makeFECScheme()``): the production `m == 1` XOR-equivalent
    ///     unless `SLOPDESK_FEC_M >= 2` activates a fixed multi-loss `[k + m, k]` Reed-Solomon code
    ///     (`k = SLOPDESK_FEC_K`). With `m > 1` the host forces tier 0 / group_size = k on every
    ///     frame (see ``AdaptiveFECPolicy/wireTier(adaptiveTier:)``); the CLIENT must read the SAME
    ///     env and be deployed together (the parity-fragment count per group changes on the wire).
    public init(
        window: SCWindow,
        transport: any VideoDatagramTransport,
        fec: FECScheme? = AdaptiveFECPolicy.makeFECScheme(),
        captureScale: Double = 2.0,
        captureSizeOverride: VideoSize? = nil,
        resizePointLimit: VideoSize? = nil,
        bitrate: Int = VideoEncoder.bitrateBitsPerSecond,
        fps: Int = 30,
    ) {
        self.window = window
        display = nil
        self.transport = transport
        self.captureScale = max(1.0, captureScale)
        self.captureSizeOverride = captureSizeOverride
        self.resizePointLimit = resizePointLimit
        self.bitrate = bitrate
        self.fps = max(1, fps)
        governedFps = max(1, fps)
        stateMachine = VideoSessionStateMachine(fullRange: Self.fullRange)
        // SLOPDESK_FEC=0 (latency A/B): drop the 20% XOR parity entirely — Parsec ships
        // ZERO video FEC and relies on LTR/IDR recovery alone. Parity costs +20% datagrams per
        // frame (+1 pacing chunk ≈ +1.5ms lane serialization, sent AFTER the data) on EVERY frame
        // to save the occasional loss-recovery round-trip. The client reads the FEC tier per
        // fragment, so a parity-less stream is wire-compatible with an unchanged client.
        let fecDisabled = ProcessInfo.processInfo.environment["SLOPDESK_FEC"] == "0"
        packetizeLane = PacketizeLane(fec: fecDisabled ? nil : fec)
    }

    /// FULL-DESKTOP session (the desktop pane, docs/DECISIONS.md 2026-07-14): streams a whole
    /// display. Same wire/encode/input machinery as the window session minus the window-only
    /// pieces — no VD parking / size override (the display IS the size), no geometry watcher (a
    /// display never moves), no AX raise (whole-desktop input goes to whatever is frontmost).
    /// `captureScale` should be the DISPLAY's backing scale (pixels ÷ points) so a Retina display
    /// captures at native resolution.
    public init(
        display: SCDisplay,
        transport: any VideoDatagramTransport,
        fec: FECScheme? = AdaptiveFECPolicy.makeFECScheme(),
        captureScale: Double = 1.0,
        bitrate: Int = VideoEncoder.bitrateBitsPerSecond,
        fps: Int = 30,
    ) {
        window = nil
        self.display = display
        self.transport = transport
        self.captureScale = max(1.0, captureScale)
        captureSizeOverride = nil
        resizePointLimit = nil
        self.bitrate = bitrate
        self.fps = max(1, fps)
        governedFps = max(1, fps)
        stateMachine = VideoSessionStateMachine(fullRange: Self.fullRange)
        // Same SLOPDESK_FEC=0 A/B gate as the window init (see the comment there).
        let fecDisabled = ProcessInfo.processInfo.environment["SLOPDESK_FEC"] == "0"
        packetizeLane = PacketizeLane(fec: fecDisabled ? nil : fec)
    }

    // MARK: Lifecycle

    /// Binds the UDP sockets and waits for the client `hello`. Capture/encode start
    /// only once a valid hello is accepted (so we never capture into the void).
    public func start() async throws {
        _ = stateMachine.start()
        // ORDERED + COALESCING inbound path. A lock-protected queue (appended on the transport's
        // serial receive queue, preserving arrival order) plus a coalesced wakeup signal; the
        // single consumer batch-drains the backlog and `receiveBatch` collapses pointer-motion
        // runs to their latest before injecting. The single consumer is what keeps arrival order:
        // a per-datagram `Task { await receive }` fan-out races datagrams into the actor, and a
        // queued `mouseUp` can overtake its `mouseDown` through a suspension, sticking a button down.
        let queue = InboundQueue()
        let (wakeups, wakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        inboundQueue = queue
        inboundWakeup = wakeup
        // .high: this pump sits between a received input datagram and CGEventPost — a bare
        // Task inherits ambient priority and can queue behind pool work (~0.5-1.5 ms).
        inboundConsumer = Task(priority: .high) { [weak self] in
            for await _ in wakeups {
                guard let self else { break }
                let batch = queue.drainAll()
                if batch.isEmpty { continue } // a coalesced wakeup an earlier drain already emptied
                await receiveBatch(batch)
            }
        }
        // Enqueue THEN signal on the transport's serial receive queue, so the consumer always
        // runs a drain after the last append (no lost wakeup). Append is O(1) and never blocks.
        try await transport.start { channel, data in
            queue.append(channel, data)
            wakeup.yield()
        }

        // Ordered encoder-OUTPUT pump. Mirrors the inbound pump: a lock-protected FIFO the VT serial
        // callback appends to (preserving strict encode order) + a coalesced wakeup; a single consumer
        // drains and awaits `onEncodedFrame` IN ORDER so frameID/streamSeq are assigned in encode order,
        // not actor-processing order.
        let eq = EncodedFrameQueue()
        let (eWakeups, eWakeup) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        encodedQueue = eq
        encodedWakeup = eWakeup
        // .high: every encoded frame crosses this pump on its way to the wire; a bare Task's
        // inherited priority lets the executor queue it behind lower-priority work.
        encodedConsumer = Task(priority: .high) { [weak self] in
            for await _ in eWakeups {
                guard let self else { break }
                let batch = eq.drainAll()
                // Process IN ORDER (the FIFO carried encode order from the serial VT callback).
                for frame in batch {
                    await onEncodedFrame(
                        avcc: frame.avcc,
                        keyframe: frame.keyframe,
                        crisp: frame.crisp,
                        ltrToken: frame.ltrToken,
                        ackedAnchored: frame.ackedAnchored,
                    )
                }
            }
        }

        // The paced-send lane. `transport.send` is fire-and-forget UDP enqueue (protocol contract:
        // never blocks), safe to call from the lane's consumer task.
        if Self.sendLaneEnabled {
            let transport = transport
            sendLane = VideoSendLane(send: { data, channel in transport.send(data, on: channel) })
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
        // End the paced-send lane (queued frames are for a session that no longer exists).
        sendLane?.close()
        sendLane = nil
        // End the stall-scrim heartbeat (a stopped session must go silent — the client's stall
        // monitor + the shutdown bye are the truth now).
        stopHeartbeat()
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
    /// Debug-only: host-relative ms of the latest key/button-DOWN inject, for the "i2h" (input→encoded)
    /// segment logged in ``onEncodedFrame``. Set ONLY under `debugStderr`; 0 ⇒ none pending, so the i2h
    /// log is naturally debug-gated. Actor-isolated (set here, read in onEncodedFrame).
    private var lastInputRxMs: UInt32 = 0

    private func receiveBatch(_ batch: [(VideoChannel, Data)]) async {
        // CLIENT-SILENCE PAUSE liveness: any inbound client datagram refreshes the silence stamp and,
        // if video was paused for silence, RESUMES it instantly (before decode — even an undecodable
        // datagram proves the peer is back). When the feature is off `videoPausedForSilence` is never
        // set, so this is a lone dead-store assignment (no capturer call, no observable effect).
        lastClientInboundUptime = ProcessInfo.processInfo.systemUptime
        if videoPausedForSilence {
            videoPausedForSilence = false
            capturer?.setClientSilencePaused(false)
            dbg("client-silence: video RESUMED (inbound datagram)")
        }
        var inputRun: [InputEvent] = []
        var sawKeyOrButtonDown = false
        for (channel, data) in batch {
            switch channel {
            case .input:
                // Gate on streaming (matches `InputDatagramRouter.route`) and decode here so the
                // run can be coalesced. A malformed datagram is dropped, never crashes the receiver.
                guard stateMachine.mediaFlowing else {
                    // TRACE the silent gate (`SLOPDESK_VIDEO_DEBUG`): a client that still believes
                    // its session is live sends input here and sees NOTHING happen — the drop must be
                    // observable or the remote window looks like it isn't receiving input, with no lead.
                    if Self.inputTrace {
                        FileHandle.standardError.write(Data(
                            "slopdesk-videohostd[inject]: input DROPPED (state=\(stateMachine.state), target=\(targetID))\n"
                                .utf8,
                        ))
                    }
                    continue
                }
                do {
                    let event = try InputEvent.decode(data)
                    // i2h: note a real key/mouse DOWN (NOT move/scroll/up) so the input→encoded segment is
                    // keyed off the input that changes the screen + scroll bursts can't overwrite it.
                    // Checked across the WHOLE batch (a down may inject mid-batch via the control/recovery arms).
                    switch event {
                    case .mouseDown,
                         .key(_, true, _, _): sawKeyOrButtonDown = true
                    default: break
                    }
                    inputRun.append(event)
                } catch {
                    log.error("dropping input datagram: undecodable")
                }
            case .control:
                let run = inputRun
                inputRun = []
                await injectCoalesced(run)
                await handleControl(data)
            case .recovery:
                let run = inputRun
                inputRun = []
                await injectCoalesced(run)
                await handleRecovery(data)
            case .video,
                 .geometry,
                 .cursor,
                 .audio:
                // Host does not receive these (host→client). Ignore defensively.
                break
            }
        }
        await injectCoalesced(inputRun)
        // i2h (debug-only): stamp the inject time of the latest key/button-down so `onEncodedFrame` logs the
        // inject→encoded segment of input-to-photon. Same `hostRelativeMillis` clock as sendTs/RTT.
        if Self.debugStderr, sawKeyOrButtonDown { lastInputRxMs = hostRelativeMillis() }
    }

    // SCROLL-COALESCE accumulator (time-gated, held ACROSS drains — see `scrollInjectInterval`).
    // The whole fold — sum continuous-phase deltas, ≤1 summed emit per interval, boundary +
    // trailing flushes — is the PURE ``ScrollCoalescePlanner`` (so the trailing-flush reachability
    // is unit-testable); this actor just injects what it returns.
    private var scrollPlanner = ScrollCoalescePlanner(
        injectInterval: SlopDeskVideoHostSession.scrollInjectInterval,
        coalesceScroll: SlopDeskVideoHostSession.scrollCoalesceEnabled,
    )
    /// One-shot idle flush for a HELD scroll residual (the lost-gesture-`ended` backstop). The
    /// reachable empty-run trailing flush already drains the residual on the next inbound batch
    /// (netstats arrive ~20/s), but if the wire goes fully quiet this timer flushes it after one
    /// `scrollInjectInterval` instead of stranding it until the next input. Re-arms itself while
    /// a residual is still gate-held; cancelled + cleared at media teardown.
    private var scrollIdleFlushTask: Task<Void, Never>?

    /// Collapses an arrival-ordered run of input events to its coalesced form and injects each,
    /// reproducing the per-event raise latch the single-event path applied: a button-down raises
    /// + focuses first (`alwaysRaises`), a coalesced motion run never does, and `inputNeedsRaise`
    /// is advanced between events (mouse-up re-arms it). Motion is the only class collapsed, so
    /// the raise/button-balance semantics for every down/up are byte-identical to the un-batched path.
    ///
    /// SCROLL COALESCING: continuous-phase scroll deltas are SUMMED into a time-gated accumulator
    /// (held across drains) and posted ≤ once per `scrollInjectInterval`, so the ~200/s `CGEvent`
    /// flood that saturates the WindowServer → SCStream capture stalls never forms. A gesture
    /// boundary (began/ended/wheel) or any non-scroll event flushes the accumulator FIRST, in
    /// order — and an EMPTY run reaches the trailing flush too, so a residual stranded by a lost
    /// gesture-`ended` drains on the next control/recovery-only batch instead of waiting for the
    /// next unrelated input.
    private func injectCoalesced(_ run: [InputEvent]) async {
        for event in scrollPlanner.plan(run: run, now: ProcessInfo.processInfo.systemUptime) {
            let raiseFirst = InputDatagramRouter.raiseFirst(for: event, needsRaise: inputNeedsRaise)
            await inject(event, raiseFirst: raiseFirst)
        }
        if scrollPlanner.hasPendingScroll { armScrollIdleFlush() }
    }

    /// Arms the one-shot idle flush (no-op while one is already armed — see `scrollIdleFlushTask`).
    private func armScrollIdleFlush() {
        guard scrollIdleFlushTask == nil else { return }
        scrollIdleFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.scrollInjectInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.scrollIdleFlushFired()
        }
    }

    /// Timer body: an empty-run plan is exactly the trailing-flush path — the gate decides, and
    /// `injectCoalesced` re-arms if the residual is still held (fired before the gate elapsed).
    private func scrollIdleFlushFired() async {
        scrollIdleFlushTask = nil
        await injectCoalesced([])
    }

    private func handleControl(_ data: Data) async {
        let message: VideoControlMessage
        do { message = try VideoControlMessage.decode(data) } catch {
            log.error("dropping malformed control datagram")
            dbg("control datagram malformed (\(data.count)B) — dropped")
            return
        }
        dbg("control received: \(String(describing: message)) (target=\(targetID))")
        // Proactive raise on client pane focus (the "raise the focused pane's window" model): bring the
        // captured window frontmost ONCE now, so the user's FIRST click lands instantly instead of
        // paying the per-interaction activate-then-control raise stall. Idempotent —
        // `raiseTargetWindow()` short-circuits when already frontmost. Only meaningful while streaming
        // (the injector exists only then). The SM has no semantics for this message, so action it here
        // and return (no effects to apply).
        if case .focusWindow = message {
            // Bind a LOCAL non-optional injector (it is `@unchecked Sendable`) so the MainActor hop can
            // capture it — mirrors `inject(_:raiseFirst:)`'s `guard let injector` pattern.
            guard stateMachine.mediaFlowing, let injector else { return }
            if Self.inputTrace {
                FileHandle.standardError
                    .write(
                        Data(
                            "slopdesk-videohostd[inject]: focusWindow → proactive raise (async, target=\(targetID))\n"
                                .utf8,
                        ),
                    )
            }
            // FIRE-AND-FORGET: never AWAIT the AX raise. On an AX-slow target it costs ≈1s, and the
            // input path must not block on it. `raiseTargetWindow()` hops the AX chain onto its own
            // background queue and self-throttles, so this proactive raise + the imminent mouseDown
            // raise coalesce to one bit of work.
            injector.raiseTargetWindow()
            // A following move/scroll/key need not re-raise.
            inputNeedsRaise = false
            return
        }
        let bounds = currentWindowBoundsCG()
        let effects = stateMachine.handleControl(
            message,
            windowBoundsCG: bounds,
            resolveCaptureSize: { [window, captureSizeOverride] requestedWindowID, viewport in
                // Accept only the window this session was created for; size the capture to
                // the real window backing store (clamp the requested viewport to it).
                guard let window, requestedWindowID == UInt32(window.windowID) else { return nil }
                // Prefer the daemon's achieved post-move size (feature #1 VD): a window resized DOWN to
                // fit the VD must be captured + acked at its NEW point size, not the stale `SCWindow.frame`
                // enumeration snapshot — else the SCStream over-crops and the client's input-mapping
                // denominator desyncs. `nil` (no VD move) ⇒ `window.frame` as before.
                let sourcePoints = captureSizeOverride ?? VideoSize(
                    width: window.frame.width,
                    height: window.frame.height,
                )
                let w = UInt16(max(1, min(Double(UInt16.max), sourcePoints.width.rounded())))
                let h = UInt16(max(1, min(Double(UInt16.max), sourcePoints.height.rounded())))
                _ = viewport // viewport informs client-side scaling; host captures native window pixels.
                return (w, h)
            },
            resolveResizeSize: { [window, resizePointLimit] requestedWindowID, desired in
                // Accept only the session's window; sanity-clamp the desired POINT size into a
                // valid, non-zero range. This is a POLICY pre-clamp only — the AX read-back in
                // `apply(.resizeCapture)` is the AUTHORITATIVE achieved size (the window may further
                // clamp to its own min/max). Min 1×1; max is the VD point bounds when the window is
                // parked on the VD (so a resize can't push the crop past the framebuffer), else the
                // UInt16 wire limit. A DISPLAY session never resizes (window == nil ⇒ nil).
                guard let window, requestedWindowID == UInt32(window.windowID) else { return nil }
                let maxSize = resizePointLimit ?? VideoSize(width: Double(UInt16.max), height: Double(UInt16.max))
                return SizeNegotiation.clamp(
                    desired: desired,
                    min: VideoSize(width: 1, height: 1),
                    max: maxSize,
                )
            },
            resolveDisplayCaptureSize: { [display] requestedDisplayID, viewport in
                // Accept only the display this session was created for (`0` = "the main display" —
                // the daemon already resolved the concrete target at mint, so any id that got this
                // session minted matches). Capture at the display's full point size; the client
                // aspect-fits (viewport informs nothing here, same as the window path).
                guard let display,
                      requestedDisplayID == display.displayID || requestedDisplayID == 0 else { return nil }
                let w = UInt16(max(1, min(Double(UInt16.max), display.frame.width.rounded())))
                let h = UInt16(max(1, min(Double(UInt16.max), display.frame.height.rounded())))
                _ = viewport
                return (w, h)
            },
        )
        for effect in effects { await apply(effect) }
        // A clean `bye` re-arms the session to `.listening` and tears down capture (above), but the
        // pinned UDP flow slot would stay pinned (UDP has no FIN) — and a reconnecting client's fresh
        // hello arrives on a NEW source port ⇒ a new 4-tuple ⇒ silently refused at the listener until
        // the daemon restarts. Free the flow so the next client can re-pin and reconnect WITHOUT a
        // daemon restart. (A crash WITHOUT a bye relies on the idle-timeout reaper — see docs/25 §4.)
        if case .bye = message { transport.resetClientFlow() }
    }

    // No crash-without-bye hook belongs here: the only reaper on the live (mux) path is
    // `NWVideoMuxDatagramTransport.runReaperTick` → `onReapLane` → `VideoMuxSessionRegistry.retireAndStop`
    // → `session.stop()`, and `stop()` already drains the inbound/encoded pumps and runs
    // `teardownLiveComponents` unconditionally — a strict superset of anything a session-local reap
    // callback could do.

    private func inject(_ event: InputEvent, raiseFirst: Bool) {
        guard let injector else { return }
        // CLICK LATENCY: the raise is FIRE-AND-FORGET (a best-effort window-order/keyboard-focus nudge)
        // and the event posts IMMEDIATELY. Awaiting the raise before each post is the delayed-click bug:
        // the AX raise is ~6–10 SYNCHRONOUS cross-process IPC calls, and against an AX-slow target app
        // each hits the messaging timeout → ≈1s per raise; a single click fires several (mouseDown's
        // `alwaysRaises` + every duplicate loss-resilience mouseUp re-arming the latch + the first
        // post-up move) → multi-second stalls. On-device, `frontmost` never equals the target (cross-app
        // activation is throttled on macOS 14+), so the short-circuit never fires and the raise is both
        // slow AND futile — yet clicks still land, proving the posted CGEvent (not the raise) is the
        // delivery mechanism. Not awaiting also removes a suspension point, so a coalesced run injects in
        // STRICT order (no down/up inversion); `raiseTargetWindow()` self-throttles so the several raises
        // per click coalesce to one.
        if raiseFirst {
            inputNeedsRaise = false
            let injectorRef = injector
            if Self.inputTrace {
                FileHandle.standardError
                    .write(Data("slopdesk-videohostd[inject]: raiseFirst dispatched async (event=\(event))\n".utf8))
            }
            Task { @MainActor in injectorRef.raiseTargetWindow() }
        }
        dbgInject(event)
        injector.inject(event)
        // A mouse-up ends the interaction → re-arm so the NEXT interaction raises+focuses.
        if InputDatagramRouter.rearmRaiseAfter(event) { inputNeedsRaise = true }
    }

    /// Opt-in (`SLOPDESK_VIDEO_DEBUG=1`) trace of the injected input stream, so a hardware run
    /// can confirm drags flow as `.mouseDrag` (not phantom `.mouseMoved`) and see the
    /// down/up framing. Pointer streams are high-rate, so moves/drags are SAMPLED (1-in-25)
    /// to avoid flooding stderr and perturbing injection timing; button/key/scroll log every
    /// event. No-op in production.
    private var dbgInputCount = 0
    private var injectTraceSeq = 0
    private func dbgInject(_ event: InputEvent) {
        if Self.inputTrace {
            // GROUND TRUTH for input ordering: every injected event in strict order, numbered.
            injectTraceSeq += 1
            FileHandle.standardError
                .write(Data("slopdesk-videohostd[inject #\(injectTraceSeq)]: \(Self.inputName(event))\n".utf8))
            return
        }
        guard Self.debugStderr else { return }
        switch event {
        case .mouseMove,
             .mouseDrag:
            dbgInputCount += 1
            if dbgInputCount % 25 == 1 { dbg("inject \(Self.inputName(event)) (pointer sample #\(dbgInputCount))") }
        default:
            dbg("inject \(Self.inputName(event))")
        }
    }

    private static func inputName(_ event: InputEvent) -> String {
        switch event {
        case .mouseMove: "mouseMove"
        case let .mouseDrag(b, _, _, _, _): "mouseDrag(\(b))"
        case let .mouseDown(b, _, c, _, _): "mouseDown(\(b),clicks=\(c))"
        case let .mouseUp(b, _, c, _, _): "mouseUp(\(b),clicks=\(c))"
        case .scroll: "scroll"
        case let .key(kc, down, _, _): "key(\(kc),\(down ? "down" : "up"))"
        case .text: "text"
        }
    }

    /// Host-monotonic milliseconds since `sessionStartUptime`, truncated into a `UInt32` (the wire
    /// width). `truncatingIfNeeded` makes the ~49.7-day wrap well-defined; the RTT fold's wrap-aware
    /// subtraction stays correct across it. Stamped on every video fragment and read again on a
    /// NetworkStats receipt, so both ends of the RTT live in this one clock domain.
    private func hostRelativeMillis() -> UInt32 {
        UInt32(truncatingIfNeeded: Int64((ProcessInfo.processInfo.systemUptime - sessionStartUptime) * 1000))
    }

    private func handleRecovery(_ data: Data) async {
        switch recoveryRouter.route(datagram: data, mediaFlowing: stateMachine.mediaFlowing) {
        case let .forceKeyframe(lastDecoded):
            // Drop byte-identical redundant copies (the client sends 3× per logical request). A
            // duplicate is dbg-logged and ignored — the first copy already acted.
            guard recoveryDeduper.admit(data, now: ProcessInfo.processInfo.systemUptime) else {
                dbg("recovery dup requestIDR suppressed")
                break
            }
            // Force an IDR on the next captured frame so a client that lost frames re-anchors
            // immediately instead of waiting for the ~1s heartbeat IDR — admission-gated by the
            // delivery-keyed RecoveryIDRPolicy (or the capturer's sent-keyed gate when V2 is off).
            gateRecoveryIDR(lastDecoded: lastDecoded)
        case let .refreshLTR(lastDecoded):
            // Same dedup gate — REQUIRED here (no cooldown exists on the LTR path, so copies
            // straddling a capture-frame boundary would encode a second ForceLTRRefresh).
            guard recoveryDeduper.admit(data, now: ProcessInfo.processInfo.systemUptime) else {
                dbg("recovery dup requestLTRRefresh suppressed")
                break
            }
            // The client asked for an LTR refresh. Decide LTR-refresh-vs-IDR from the runtime
            // acked-token state under the ACKED-ONLY invariant. `.ltrRefresh` issues a cheap
            // ForceLTRRefresh P-frame against a token the client DECODED+ACKED; `.idr` falls back to a
            // real keyframe (when SLOPDESK_LTR is off OR no token is acked yet). SELF-HEAL PREFERENCE:
            // the `.ltrRefresh` arm is UNGATED — only the IDR fallback passes through the recovery-IDR
            // admission policy.
            switch ltrController.recoveryDecision(request: .ltrRefresh, hasEnableLTR: Self.ltrEnabled) {
            case .ltrRefresh:
                dbg("recovery refreshLTR → LTR refresh (acked tokens available)")
                capturer?.requestLTRRefresh()
            case .idr:
                gateRecoveryIDR(lastDecoded: lastDecoded)
            }
        case let .ack(streamSeq):
            // A keyframe decode-ack (the client acks EVERY decoded keyframe, not just LTR-flagged
            // frames) feeds the delivery-keyed cooldown. Unconditional — NOT gated on
            // `Self.ltrEnabled`: ring-matching inside the policy rejects non-keyframe ids, and
            // `ltrController.ackFrame` below already no-ops on unknown ids.
            recoveryIDRPolicy.noteKeyframeDelivered(frameID: streamSeq)
            // The `streamSeq` wire field carries a FRAME ID (see RecoveryMessage.ack). Fold it:
            // map frameID→token, add the token to the bounded acked set, and stage it onto the encoder
            // as an AcknowledgedLTRTokens option so a later ForceLTRRefresh may reference it (the
            // ACKED-ONLY invariant). An unknown/duplicate/evicted frameID is a safe no-op (ackFrame
            // returns nil). Only acts under SLOPDESK_LTR; off ⇒ the client never sends acks anyway, and
            // this stays diagnostics-only.
            if Self.ltrEnabled, let token = ltrController.ackFrame(frameID: streamSeq) {
                encoder?.stageAcknowledgedToken(token)
                // SELF-HEAL: an ack just folded ⇒ VT holds an acknowledged LTR ⇒ the capturer's
                // cadence ForceLTRRefresh is a small loss-immune P-frame, not an IDR fallback.
                // Idempotent (lock-set of a Bool); disarmed at every encoder install
                // (``resetLTRForNewEncoder``).
                capturer?.setSelfHealEligible(true)
                dbg("recovery ack frameID=\(streamSeq) → staged LTR token \(token)")
            }
            log.debug("recovery ack streamSeq=\(streamSeq, privacy: .public)")
        case let .reshipCursorShape(shapeID):
            // Self-heal: the client lost this shape's one-shot bitmap (or it never fit one
            // datagram). Re-emit it through the SAME shape handler so it rides the cursor socket
            // again as a `CursorShapeMessage`; the client cache re-insert is idempotent.
            dbg("recovery requestCursorShape \(shapeID) — re-shipping cursor shape")
            cursorSampler?.reshipShape(shapeID)
        case let .networkStats(report):
            sawClientFeedback = true // proven modern feedback client ⇒ eligible for the silence pause
            // Network-feedback telemetry: fold a clock-skew-free estimate (host-clock RTT + loss +
            // jitter trend) — the ABR / FEC / fps controllers below all tick off it.
            // `SLOPDESK_NETSTATS=0` ⇒ the client reports latestHostSendTs=0 ⇒ computeRTTMillis returns
            // nil ⇒ the RTT term is skipped (loss/jitter still fold).
            let rtt = NetworkEstimate.computeRTTMillis(
                hostNowMs: hostRelativeMillis(),
                latestHostSendTs: report.latestHostSendTs,
                clientHoldMs: report.clientHoldMs,
            )
            networkEstimate.fold(
                rttMillis: rtt,
                framesReceived: report.framesReceived,
                unrecovered: report.unrecovered,
                owdJitterMicros: report.owdJitterMicros,
                owdTrendState: report.owdTrendStateRaw,
                owdTrendModifiedMilli: report.owdTrendModifiedMilliSigned,
            )
            // SELF-HEAL clean-link loss-gate: push the freshly-folded loss EWMA to the capturer so its
            // gate (SLOPDESK_SELF_HEAL_LOSS_GATE) can suppress the periodic refresh doublet on a loss-free
            // link and re-arm it the instant loss appears. Gated on the flag ⇒ zero work when off; the
            // snapshot is at most one report (~50ms) stale, well inside the K-frame heal cadence.
            if WindowCapturer.selfHealLossGate {
                capturer?.setSelfHealLossRate(networkEstimate.lossRate)
            }
            // ADAPTIVE FEC: pick the per-frame group-size tier from the freshly-folded loss EWMA.
            // Hysteretic + one-step-clamped (anti-flap) inside the pure policy. Updated ONLY here, inside
            // a real report → it can't move before there is loss data (inert when no reports arrive).
            // No-op unless `SLOPDESK_ADAPTIVE_FEC=1` ⇒ the tier stays at the today-default tier 0.
            if Self.adaptiveMEnabled {
                // ADAPTIVE-m ladder: step the per-frame parity multiplicity by the folded loss
                // (escalate immediately on a burst; relax only after the sticky-gated dwell). Same
                // unrecovered-loss evidence feeds the sticky window. Floors at CLEAN (m2), never OFF.
                let next = AdaptiveFECPolicy.nextParityTierState(
                    forLossRate: networkEstimate.lossRate,
                    state: fecTierState,
                    sawUnrecoveredLoss: report.unrecovered > 0,
                )
                if next.tier != fecTierState.tier {
                    dbg(
                        "adaptive-fec-m: tier \(fecTierState.tier) → \(next.tier) (lossEWMA=\(String(format: "%.4f", networkEstimate.lossRate)))",
                    )
                }
                fecTierState = next
            } else if Self.adaptiveFECEnabled {
                // FEC LADDER FLOOR + STICKY RELAX: relaxation floors at g10 (tier 2;
                // `SLOPDESK_FEC_ALLOW_OFF=1` re-allows the walk to OFF) and an unrecovered-loss
                // report doubles the relax dwell for the next sticky window — both inside the pure
                // policy; this site only feeds it the report's unrecovered evidence.
                let next = AdaptiveFECPolicy.nextTierState(
                    forLossRate: networkEstimate.lossRate,
                    state: fecTierState,
                    sawUnrecoveredLoss: report.unrecovered > 0,
                )
                if next.tier != fecTierState.tier {
                    dbg(
                        "adaptive-fec: tier \(fecTierState.tier) → \(next.tier) (lossEWMA=\(String(format: "%.4f", networkEstimate.lossRate)))",
                    )
                }
                fecTierState = next
            }
            // ADAPTIVE BITRATE: tick the AIMD controller on the freshly-folded estimate and
            // actuate a MATERIAL target change onto the live encoder. No-op unless `SLOPDESK_ABR=1` (the
            // controller is then never seeded ⇒ nil ⇒ this whole block is skipped and the live rate
            // stays pinned at the ceiling). The controller is a pure value type — copy out, tick,
            // write back; no reference capture, so no retain-cycle risk. `setLiveBitrate` is throttled
            // to material moves (≈5% of ceiling / 500 kbps) so it fires rarely, not every report.
            if Self.abrEnabled, var ctrl = congestionController {
                // `decide` is `onReport` + the WHY token, so the actuate line below can attribute a cut
                // to gradient/rttStreak/loss/… — printing stays here at the debug site; the controller
                // stays pure.
                // IDLE-RAMP GUARD: pass the recent offered throughput so the controller suppresses the
                // additive probe while application-limited (idle/static) — no phantom headroom for a
                // later burst to overshoot. `nil` until the first delta frame (no gate).
                // `effectiveStreamFps` (== governedFps with no user cap) — the utilization signal
                // must reflect the cadence frames actually encode at.
                let offeredBps = offeredBytesPerFrameEWMA > 0
                    ? offeredBytesPerFrameEWMA * 8.0 * Double(effectiveStreamFps)
                    : nil
                let decision = ctrl.decide(networkEstimate, offeredBps: offeredBps)
                let target = decision.target
                congestionController = ctrl
                // OWN RATE-CONTROL: feed the ABR's congestion verdict into the QP link-AIMD and drive the
                // encoder's CONSTANT QP. A cut reason (RTT/loss/gradient/catastrophic) = congested →
                // coarsen Q (smaller frames, fit the link); anything else = clean → sharpen slowly. This
                // adapts the constant-quality stream to the link with NO VT VBR clawback. Runs every
                // report (not gated on actuation).
                if var qp = qpController {
                    let congested =
                        switch decision.reason {
                        case .rttStreak,
                             .lossCorroborated,
                             .gradient,
                             .catastrophic: true
                        default: false
                        }
                    let q = qp.decide(congested: congested)
                    qpController = qp
                    if encoder?.setConstQP(q) == true {
                        dbg("qp-aimd: Q=\(q) (congested=\(congested) reason=\(decision.reason.rawValue))")
                    }
                    // LOSS-TIER-ADAPTIVE QP DECOUPLE: feed the same congestion verdict to the encoder so
                    // the sharp-sidebar `[floor,q]` band is used only on a clean link and collapses to
                    // Min==Max==q (small frames) when the link is stressed (burst-loss safety).
                    if encoder?.setLinkCongested(congested) == true {
                        dbg("qp-decouple: \(congested ? "PIN Min==Max (congested)" : "BAND (clean)")")
                    }
                }
                if LiveCongestionController.isMaterialChange(
                    previous: lastActuatedBitrate,
                    target: target,
                    ceiling: ctrl.ceiling,
                ) {
                    lastActuatedBitrate = target
                    // Under const-QP the QP-AIMD above is the SOLE rate control: keep AverageBitRate
                    // pinned at the create-time ceiling (a high drop-backstop) and do NOT actuate the
                    // ABR's bitrate cut — cutting AverageBitRate here would race the QP-AIMD (the cut
                    // lands a frame before the coarser Q) and could momentarily drop frames. The ABR
                    // still runs purely for its congestion VERDICT, which drives the QP-AIMD.
                    if qpController == nil { encoder?.setLiveBitrate(target) }
                    dbg(
                        "abr: actuate target=\(target) ceiling=\(ctrl.ceiling) floor=\(ctrl.floor) current=\(ctrl.current) ticks=\(ctrl.ticks) knee=\(ctrl.kneeBps.map(String.init) ?? "-") offered≈\(offeredBps.map { String(Int($0)) } ?? "-") reason=\(decision.reason.rawValue)",
                    )
                }
            }
            // FPS GOVERNOR: tick on the same ~50 ms report clock, AFTER the ABR block so it reacts
            // to THIS tick's actuated rate. Congestion evidence reuses the ABR's own RTT constants
            // (the two controllers agree on "congested") + ABR-below-ceiling as a debounced proxy.
            // nil when `SLOPDESK_FPS_GOVERNOR` is off ⇒ skipped entirely.
            if var gov = fpsGovernor {
                // `effectiveCeiling` (not the raw policy ceiling): the below-ceiling proxy means
                // "the ABR cut below what it is ALLOWED to run at". With a user bitrate ceiling the
                // rate legitimately saturates AT that override — comparing against the policy
                // ceiling would read a clean link as permanently congested and walk fps down.
                let congested = FPSGovernor.congestionEvidence(
                    lastLossSample: networkEstimate.lastLossSample,
                    smoothedRTTMillis: networkEstimate.smoothedRTTMillis,
                    minRTTMillis: networkEstimate.minRTTMillis,
                    abrCurrent: congestionController?.current,
                    abrCeiling: congestionController?.effectiveCeiling,
                )
                let newFps = gov.onTick(targetBps: lastActuatedBitrate, congested: congested)
                let offeredBps = Int(gov.bytesPerFrameEWMA * 8 * Double(effectiveStreamFps))
                fpsGovernor = gov
                if newFps != governedFps {
                    let old = governedFps
                    governedFps = newFps
                    actuateGovernedFps(newFps)
                    dbg(
                        "fps-governor: \(old) → \(newFps) (offered≈\(offeredBps)bps target=\(lastActuatedBitrate) congested=\(congested))",
                    )
                }
            }
            // Precompute display strings so the log interpolation captures only plain Strings.
            let rttStr = rtt.map { String($0) } ?? "nil"
            let smoothedStr = String(format: "%.1f", networkEstimate.smoothedRTTMillis)
            let lossStr = String(format: "%.3f", networkEstimate.lossRate)
            let minRTTStr = networkEstimate.minRTTMillis.isFinite ? String(
                format: "%.1f",
                networkEstimate.minRTTMillis,
            ) : "inf"
            let rising = networkEstimate.owdGradientRising
            // The client's delay-gradient trendline verdict, for the A/B logs.
            let trendStr = String(format: "%.2f", networkEstimate.owdTrendModified)
            let tstate = report.owdTrendStateRaw == 1 ? "o" : (report.owdTrendStateRaw == 2 ? "u" : "n")
            let tdeltas = report.owdTrendDeltas
            // The client's presentation-health telemetry rides every report — late= (clean hitch
            // signal), gaps= (superset incl. motion-stop boundaries), depth= (live pacer depth gauge;
            // 0 = no pacer). LOG-ONLY (the delay-gradient fold owns the NetworkEstimate path), but it
            // makes every feel-test a measurement session: promotions must co-occur with loss/RTT
            // events, never clean.
            log
                .info(
                    "netstats rx: rttSample=\(rttStr, privacy: .public)ms smoothedRTT=\(smoothedStr, privacy: .public)ms loss=\(lossStr, privacy: .public) rising=\(rising, privacy: .public) trend=\(trendStr, privacy: .public) tstate=\(tstate, privacy: .public) tdeltas=\(tdeltas, privacy: .public) late=\(report.pacerLateFrames, privacy: .public) gaps=\(report.pacerPresentGaps, privacy: .public) depth=\(report.pacerDepth, privacy: .public)",
                )
            dbg(
                "netstats rx: frames=\(report.framesReceived) fec=\(report.fecRecovered) lost=\(report.unrecovered) hostTs=\(report.latestHostSendTs) hold=\(report.clientHoldMs)ms jitter=\(report.owdJitterMicros)us → rtt=\(rttStr)ms smoothedRTT=\(smoothedStr)ms minRTT=\(minRTTStr)ms loss=\(lossStr) rising=\(rising) trend=\(trendStr) tstate=\(tstate) tdeltas=\(tdeltas) late=\(report.pacerLateFrames) gaps=\(report.pacerPresentGaps) depth=\(report.pacerDepth)",
            )
        case let .retransmitFragments(frameID, fragIndices):
            // NACK / selective ARQ: re-send exactly the missing fragments from the send-history ring
            // — no IDR. Dedup the client's 3× redundant NACK copies (same byte-keyed gate as the
            // other request paths). A ring miss (the frame aged out, or NACK is disabled host-side)
            // is a benign no-op: the client's retransmit grace then expires and its
            // Dropped→LTR-refresh fallback fires.
            guard recoveryDeduper.admit(data, now: ProcessInfo.processInfo.systemUptime) else {
                dbg("recovery dup NACK suppressed")
                break
            }
            let resend = retransmitRing?.fragments(frameID: frameID, fragIndices: fragIndices) ?? []
            if resend.isEmpty {
                dbg("NACK frame=\(frameID) want=\(fragIndices.count): ring miss — no retransmit")
            } else if let sendLane {
                dbg("NACK frame=\(frameID): retransmitting \(resend.count)/\(fragIndices.count) frags")
                sendLane.enqueue(VideoSendLane.Job(
                    outgoings: resend,
                    gapNanos: 0,
                    chunkFragments: Self.paceChunkFragments,
                ))
            } else {
                // SLOPDESK_SEND_LANE=0 (inline-pacing path): no lane to enqueue on — mirror the primary
                // frame-send path's own fallback (`sendPaced`) so a NACK hit is never silently dropped
                // just because the lane is disabled.
                dbg("NACK frame=\(frameID): retransmitting \(resend.count)/\(fragIndices.count) frags (inline)")
                await sendPaced(resend)
            }
        case let .drop(reason):
            log.error("dropping recovery datagram: \(reason)")
        case .ignoreNotStreaming:
            break
        }
    }

    /// Admission gate for the two IDR-issuing recovery paths (`.forceKeyframe` and the
    /// `.refreshLTR`→`.idr` fallback). With V2 on, ``RecoveryIDRPolicy`` decides (delivery-keyed
    /// cooldown + casualty bypass + token bucket); only `.grant` latches the capturer keyframe.
    /// With V2 off, the latch is unconditional and the capturer's sent-keyed gate rules.
    /// LTR refreshes never come through here (self-heal preference preserved).
    private func gateRecoveryIDR(lastDecoded: UInt32?) {
        // CAPTURE BRING-UP GUARD: with no capturer there is nothing to latch — consulting the
        // policy anyway would burn a token AND latch `grantedAt` with NO keyframe ever emitted
        // (a phantom grant whose pending-window then suppresses the client's real re-request
        // once capture is up). Bail BEFORE the policy; the client's 2·RTT escalation re-requests.
        guard let capturer else {
            dbg("recovery IDR ignored — capturer not up yet (lastDecoded=\(lastDecoded.map(String.init) ?? "none"))")
            return
        }
        guard Self.recoveryIDRV2 else {
            armKfDupFastAttack()
            capturer.requestKeyframe()
            return
        }
        let verdict = recoveryIDRPolicy.decide(
            now: ProcessInfo.processInfo.systemUptime,
            clientLastDecoded: lastDecoded,
            smoothedRTTSeconds: networkEstimate.smoothedRTTMillis / 1000.0,
        )
        if case .grant = verdict {
            armKfDupFastAttack()
            capturer.requestKeyframe()
        } else {
            dbg("recovery IDR \(verdict) (lastDecoded=\(lastDecoded.map(String.init) ?? "none"))")
        }
    }

    /// Arm the kfDup fast-attack window (see ``kfDupFastAttackUntil``) — called wherever a RECOVERY
    /// keyframe is actually requested, so the resulting re-anchor IDR is dupped regardless of when the
    /// loss EWMA folds. On a clean link no recovery is requested, so this never arms and the heartbeat
    /// crisp IDR stays un-dupped (the bandwidth win).
    private func armKfDupFastAttack() {
        kfDupFastAttackUntil = ProcessInfo.processInfo.systemUptime + Self.kfDupFastAttackWindow
    }

    /// (Re)seed the congestion controller to a freshly-built encoder's resolution-aware ceiling
    /// (no-op unless `SLOPDESK_ABR=1`). Called at EVERY encoder build (initial bring-up + both resize
    /// rebuild paths) so a resize re-anchors the controller — and `lastActuatedBitrate` — to the NEW
    /// ceiling; without re-seeding the controller would keep the OLD ceiling/current and either starve
    /// (old smaller ceiling) or over-shoot (old larger ceiling) the new resolution.
    private func seedCongestionController(ceiling: Int) {
        // Seed `lastActuatedBitrate` to the REAL resolution-aware ceiling BEFORE the ABR guard, so the
        // adaptive send-pacing gap (the only reader) uses the true ~45Mbps ceiling — not the 12Mbps
        // fallback — even when ABR is off. Otherwise `SLOPDESK_PACE=1` with `SLOPDESK_ABR=0` serializes
        // heavy frames at 4× the gap.
        lastActuatedBitrate = ceiling
        policyCeilingBps = ceiling // the ABR-off baseline the user bitrate ceiling clamps against
        // OWN RATE-CONTROL: when const-QP mode is on, seed the link-AIMD at the env QP. It rides the ABR
        // tick (uses the ABR's congestion verdict), so it needs the ABR controller below.
        if let seed = VideoEncoder.constQP { qpController = QPController(seedQ: seed) }
        if Self.abrEnabled {
            var controller = LiveCongestionController(ceiling: ceiling)
            // USER BITRATE CEILING survives an encoder rebuild (a mid-session resize must not silently
            // discard the client's request): re-layer the live override under the fresh policy ceiling.
            controller.setUserCeilingBps(userBitrateCeilingBps)
            congestionController = controller
        }
        // USER BITRATE CEILING re-actuation: a rebuilt encoder starts at the policy ceiling, and the
        // client only re-sends its settings after a re-hello — never on a resize — so a live override
        // must re-clamp the fresh encoder NOW. No-op with no override (effective == ceiling ==
        // lastActuatedBitrate); const-QP keeps AverageBitRate pinned (the QP-AIMD owns the rate).
        let effective = congestionController?.current
            ?? Swift.min(ceiling, userBitrateCeilingBps ?? ceiling)
        if effective != lastActuatedBitrate {
            lastActuatedBitrate = effective
            if qpController == nil { encoder?.setLiveBitrate(effective) }
        }
    }

    /// FPS GOVERNOR actuation: (1) latch the governed fps onto the capturer's cadence gate
    /// (thread-safe), (2) hint the live encoder's `ExpectedFrameRate` (best-effort
    /// VTSessionSetProperty — the gate enforces cadence regardless), (3) tell the client via
    /// `streamCadence` (dup-sent ×2 for loss tolerance — the exact `onCursorShape` pattern).
    /// The USER FPS CAP composes here (`min`) so a governed step can never actuate above the
    /// client's cap; with no cap the actuated value is exactly the governor's. SCStream slot
    /// config is never touched (slots stay at 2× base — the slot-beat trap).
    private func actuateGovernedFps(_ newFps: Int) {
        let fps = UserStreamSettingsPolicy.effectiveFps(governed: newFps, userCap: userFPSCap)
        capturer?.setGovernedFPS(fps)
        encoder?.setExpectedFrameRate(fps)
        sendStreamCadence(UInt16(clamping: fps))
    }

    /// USER STREAM SETTINGS (the `.applyStreamSettings` effect): clamp the wire values
    /// host-side (``UserStreamSettingsPolicy``; `0` = restore auto) and actuate both axes. A
    /// second message REPLACES the first wholesale — both overrides are re-assigned every time.
    private func applyUserStreamSettings(fpsCap: UInt8, bitrateCeilingBps: UInt32) {
        // FPS CAP: actuate through the SAME path a governed step takes (capture cadence gate +
        // VT ExpectedFrameRate hint + streamCadence announce, so the client FramePacer learns the
        // new cadence). The governor's own output keeps evolving underneath; the cap only clamps
        // actuation, so clearing it restores the governed/base cadence on the spot.
        userFPSCap = UserStreamSettingsPolicy.fpsCap(fromWire: fpsCap)
        actuateGovernedFps(governedFps)

        // BITRATE CEILING: layer the override under the policy ceiling. With ABR on the
        // controller clamps its current target down immediately and never climbs past the
        // effective ceiling; with ABR off the live rate is pinned at the policy ceiling, so the
        // override (or its clearing) actuates the encoder directly.
        userBitrateCeilingBps = UserStreamSettingsPolicy.bitrateCeiling(fromWire: bitrateCeilingBps)
        let target: Int
        if var ctrl = congestionController {
            ctrl.setUserCeilingBps(userBitrateCeilingBps)
            target = ctrl.current
            congestionController = ctrl
        } else {
            guard policyCeilingBps > 0 else { return } // no encoder seeded yet — nothing to actuate
            target = Swift.min(policyCeilingBps, userBitrateCeilingBps ?? policyCeilingBps)
        }
        // A user-driven ceiling change actuates immediately (no material-change gate — it is a
        // rare explicit request, not a 50 ms tick), except under const-QP where the QP-AIMD owns
        // the rate (same carve-out as the ABR actuation site).
        if target != lastActuatedBitrate {
            lastActuatedBitrate = target
            if qpController == nil { encoder?.setLiveBitrate(target) }
        }
        dbg(
            "streamSettings: fpsCap=\(userFPSCap.map(String.init) ?? "auto") → fps \(effectiveStreamFps), "
                + "ceiling=\(userBitrateCeilingBps.map(String.init) ?? "auto") → target \(target)bps",
        )
    }

    // MARK: Host→client heartbeat (stall-scrim liveness)

    /// Starts the 1 s heartbeat timer (idempotent re-arm). Mirrors the client keepalive's safe weak
    /// pattern — a strong `self` in a long-lived timer Task would leak the whole session. ⚠️ Timer
    /// firing is real-clock glue; the stall DECISION it feeds is covered by `StreamStallPolicyTests`
    /// + `StallScrimLatchTests` client-side.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(KeepaliveTiming.hostHeartbeatInterval * 1_000_000_000),
                )
                guard let self else { return }
                await sendHeartbeatIfStreaming()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Sends one host→client `keepalive` iff the session is streaming (a bye → `.listening` session
    /// must go silent). Fire-and-forget UDP; a lost heartbeat costs nothing — the client's stall
    /// threshold (3 s) tolerates two consecutive losses.
    private func sendHeartbeatIfStreaming() {
        guard stateMachine.mediaFlowing else { return }
        transport.send(scheduler.scheduleControl(.keepalive).bytes, on: .control)
        updateClientSilencePause()
    }

    /// CLIENT-SILENCE video-pause threshold (seconds). When the client's feedback (netstats /
    /// keepalive / input) has been silent this long, the host PAUSES video encode+send — it must not
    /// keep blasting ~ABR to a peer that is not listening (lid-closed / walk-away / dead uplink). This
    /// is DISTINCT from the 30 s idle-reaper (``KeepaliveTiming/idleTimeout``), which TEARS DOWN the
    /// session: the pause keeps the session `.streaming`, advances NO encoder reference, and resumes
    /// instantly on the next inbound — so detach-tolerance is unchanged and the reaper still reclaims a
    /// truly-gone client. `SLOPDESK_VIDEO_PAUSE_SILENT_SEC`; unset/≤0 ⇒ 0 ⇒ **DISABLED** (byte-
    /// identical — the capturer is never told to pause). When set it is clamped to
    /// `[keepaliveInterval, idleTimeout)` = [5, 30): shorter than one keepalive interval would trip on
    /// a normal keepalive-only gap; ≥ the reaper is pointless (it already tore the session down).
    static let clientSilencePauseSeconds: Double = {
        guard let s = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_PAUSE_SILENT_SEC"],
              let v = Double(s), v > 0 else { return 0 } // unset/≤0 ⇒ OFF
        return min(KeepaliveTiming.idleTimeout - 0.001, max(KeepaliveTiming.keepaliveInterval, v))
    }()

    /// PURE: whether video should PAUSE for client silence. Disabled (`thresholdSeconds <= 0`) or an
    /// unproven client (never sent feedback) ⇒ never pause — mirrors the idle-reaper's
    /// never-reap-without-keepalive safety. Otherwise pause once the last inbound is `thresholdSeconds`
    /// old. Monotonic-clock `now`/`lastInbound`.
    static func shouldPauseForClientSilence(
        now: Double, lastInbound: Double, sawFeedback: Bool, thresholdSeconds: Double,
    ) -> Bool {
        guard thresholdSeconds > 0, sawFeedback else { return false }
        return now - lastInbound >= thresholdSeconds
    }

    /// 1 s-heartbeat client-silence check: if the client has been silent past
    /// ``clientSilencePauseSeconds``, tell the capturer to pause video encode+send (logged on the
    /// transition). Resume is handled instantly in ``receiveBatch`` on the next inbound; this only
    /// ARMS the pause. No-op unless the feature is enabled (threshold 0 ⇒ `shouldPause` always false ⇒
    /// `videoPausedForSilence` never leaves `false`). Actor-isolated.
    private func updateClientSilencePause() {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPause = Self.shouldPauseForClientSilence(
            now: now, lastInbound: lastClientInboundUptime, sawFeedback: sawClientFeedback,
            thresholdSeconds: Self.clientSilencePauseSeconds,
        )
        guard shouldPause != videoPausedForSilence else { return }
        videoPausedForSilence = shouldPause
        capturer?.setClientSilencePaused(shouldPause)
        let silentFor = String(format: "%.1f", now - lastClientInboundUptime)
        dbg("client-silence: video \(shouldPause ? "PAUSED" : "RESUMED") (silent \(silentFor)s)")
    }

    /// Sends the `streamCadence(fps:)` control message, duplicated once ~25 ms later with a
    /// `mediaFlowing` re-check (cursor-shape dup-send pattern): a cadence change often coincides
    /// with congestion (the lossiest moment) and the client's application is idempotent.
    private func sendStreamCadence(_ fps: UInt16) {
        guard stateMachine.mediaFlowing else { return }
        let bytes = scheduler.scheduleControl(.streamCadence(fps: fps)).bytes
        dbg("→ sending streamCadence fps=\(fps) (+dup in 25ms)")
        transport.send(bytes, on: .control)
        Task { // inherits this actor's isolation; re-checks liveness after the gap
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard stateMachine.mediaFlowing else { return }
            transport.send(bytes, on: .control)
        }
    }

    /// SCROLL REPROJECTION: send the host-measured per-frame scroll offset (normalized ×10000, signed)
    /// plus the moving-content vertical band (`bandTop`/`bandBottom`, ten-thousandths of height; the
    /// client warps only that band so the chrome stays put) to the client as a `ScrollOffset` control
    /// message. Fire-and-forget UDP (a single send, not dup'd — it is a per-frame stream); a lost hint
    /// just costs one reproject frame (self-corrects on the next real frame). No-op once the media flow
    /// has stopped.
    func sendScrollOffset(dx: Int16, dy: Int16, bandTop: UInt16, bandBottom: UInt16) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(
            scheduler.scheduleControl(.scrollOffset(dx: dx, dy: dy, bandTop: bandTop, bandBottom: bandBottom)).bytes,
            on: .control,
        )
    }

    /// HOST-WINDOW RESIZE: report the captured window's MAXIMUM resizable POINT size so the client's
    /// "Resize…" popover can cap its width/height fields at a size the remote can actually adopt (paired
    /// with the AX resize-to-display-origin in ``WindowGeometryWatcher/resizeWindow(toPoints:)``). Sent
    /// once at capture start; a client that does not know the type drops it. No-op once the media flow
    /// has stopped, or on a degenerate (zero) size.
    private func sendDisplayMax() {
        guard stateMachine.mediaFlowing else { return }
        let maxPoints = resolveDisplayMaxPoints()
        let w = UInt16(clamping: Int(maxPoints.width.rounded()))
        let h = UInt16(clamping: Int(maxPoints.height.rounded()))
        guard w >= 1, h >= 1 else { return }
        dbg("→ sending displayMax \(w)x\(h)pt")
        transport.send(scheduler.scheduleControl(.displayMax(width: w, height: h)).bytes, on: .control)
    }

    /// The captured window's max resizable POINT size: the parked-VD point bounds when set (the existing
    /// resize ceiling), else the CG bounds of the display the window currently sits on, else the window's
    /// own current size (degenerate fallback — never reports 0). Pure pick math lives in
    /// ``WindowDisplayResolver``; only the live display enumeration is impure.
    private func resolveDisplayMaxPoints() -> VideoSize {
        if let limit = resizePointLimit { return limit }
        // A full-desktop session's "max" is simply the display's own point size (it never resizes).
        if let display {
            return VideoSize(width: display.frame.width, height: display.frame.height)
        }
        guard let frame = window?.frame else { return VideoSize(width: 0, height: 0) }
        if let display = WindowDisplayResolver.display(
            forWindowFrame: frame, displays: WindowDisplayResolver.activeDisplayBounds(),
        ) {
            return VideoSize(width: Double(display.width), height: Double(display.height))
        }
        return VideoSize(width: Double(frame.width), height: Double(frame.height))
    }

    /// Invalidate the LTR acked-set + frame map whenever a FRESH encoder /
    /// `VTCompressionSession` is installed (initial bring-up + both resize rebuild paths — the
    /// LTR counterpart of ``seedCongestionController``, called at the SAME install sites so the
    /// two recovery controllers re-anchor to the new encoder in lockstep). A new VT session holds
    /// ZERO acknowledged long-term references and the new encoder's `pendingAckedTokens` starts
    /// empty, so without this the controller's `acknowledgedTokens` (acked against the now-destroyed
    /// session) would keep `hasAckedToken` true → a `.refreshLTR` request would return `.ltrRefresh`
    /// and issue a `ForceLTRRefresh` against an LTR the rebuilt session never had, bypassing the
    /// host-side half of the ACKED-ONLY invariant (only VT's own contract would then prevent
    /// corruption). Resetting re-arms the host gate (`.idr` fallback) until the client decodes+acks a
    /// NEW LTR frame on the rebuilt session. No-op when `SLOPDESK_LTR` is off (the controller is never
    /// populated), but reset unconditionally so the invariant holds the instant LTR is enabled.
    private func resetLTRForNewEncoder() {
        ltrController.reset()
        // SELF-HEAL: a fresh VT session holds ZERO acknowledged LTRs — disarm the capturer's cadence
        // until the client decodes+acks a new LTR frame on the rebuilt session (else every K-th frame
        // would be VT's IDR fallback). Re-armed by the next `.ack` fold.
        capturer?.setSelfHealEligible(false)
        // `recoveryIDRPolicy` is DELIBERATELY NOT reset here. The packetize lane (and so frameIDs)
        // persists across encoder rebuilds, so the sent-keyframe ring and the delivered id stay valid —
        // and the token bucket MUST survive a rebuild (a resize storm during loss must not refill the
        // recovery-IDR budget). If HW testing ever shows resize-recovery starvation, a one-line policy
        // re-init here is the dial.
    }

    // MARK: Effects

    private func apply(_ effect: VideoSessionStateMachine.Effect) async {
        switch effect {
        case let .sendControl(message):
            dbg("→ sending control: \(String(describing: message))")
            transport.send(scheduler.scheduleControl(message).bytes, on: .control)
        case let .startCapture(_, width, height):
            dbg("effect startCapture \(width)x\(height) — bringing up live capture/encode")
            // USER STREAM SETTINGS die with the session re-mint: a fresh hello starts clean and
            // the client re-sends its last-requested values after the ack.
            userFPSCap = nil
            userBitrateCeilingBps = nil
            // APP-AUDIO dies with the re-mint too: default OFF until the client re-sends its wish
            // post-helloAck (the fresh capturer's forwarding gate also starts down).
            audioEnabled = false
            audioSender?.setEnabled(false)
            await startLiveComponents(width: Int(width), height: Int(height))
            // FPS GOVERNOR: announce the session's content cadence up front (+dup) so the
            // streamCadence message is the single cadence truth even before any governed step.
            // OFF ⇒ no message at all (byte-identical wire).
            if Self.fpsGovernorEnabled { sendStreamCadence(UInt16(clamping: governedFps)) }
            // HOST-WINDOW RESIZE: announce the window's display max so the client's resize popover caps
            // its fields. Additive (old clients drop the unknown type); sent once per capture bring-up.
            sendDisplayMax()
            // CLIENT-SILENCE PAUSE: re-seed the silence state for this stream so a reused/reconnected
            // session never inherits a stale "silent" stamp (which would wrongly pause the fresh
            // capturer before its first inbound). The new capturer starts un-paused by construction.
            lastClientInboundUptime = ProcessInfo.processInfo.systemUptime
            sawClientFeedback = false
            videoPausedForSilence = false
            // STALL-SCRIM HEARTBEAT: start the 1 s host→client liveness keepalive for this stream.
            startHeartbeat()
        case .stopCapture:
            dbg("effect stopCapture")
            stopHeartbeat()
            await teardownLiveComponents()
        case let .resizeCapture(width, height, epoch):
            await applyResize(width: width, height: height, epoch: epoch)
        case let .applyStreamSettings(fpsCap, bitrateCeilingBps):
            applyUserStreamSettings(fpsCap: fpsCap, bitrateCeilingBps: bitrateCeilingBps)
        case let .applyAudioControl(enabled):
            applyAudioControl(enabled: enabled)
        }
    }

    /// APP-AUDIO (the `.applyAudioControl` effect): latch the client's wish and open/close the
    /// capture→encode→send gate. NO SCStream reconfiguration — the audio tap always runs while
    /// the master env gate allows; OFF just drops `.audio` buffers at the capturer's delegate,
    /// so toggling is hitch-free. Re-ENABLE re-arms the lane's config resend
    /// (``AudioStreamSender/setEnabled(_:)``) so a fresh ``AudioStreamConfig`` datagram precedes
    /// the first frame — the client may have missed (or predate) every earlier copy. A second
    /// message replaces the first wholesale; the SM only emits this while `.streaming`.
    private func applyAudioControl(enabled: Bool) {
        audioEnabled = enabled
        guard let sender = ensureAudioSender() else {
            dbg("audioControl \(enabled ? "ON" : "OFF") ignored — SLOPDESK_AUDIO=0 masters audio off")
            return
        }
        sender.setEnabled(enabled)
        capturer?.setAudioForwardingEnabled(enabled)
        dbg("audioControl → \(enabled ? "ON" : "OFF")")
    }

    /// A swappable encoder + its configured pixel size behind a lock, so the capture queue's hot
    /// per-frame closure can be RE-POINTED at a new encoder WITHOUT rebuilding the `WindowCapturer`
    /// / restarting the SCStream (the ~120ms spin-up). The closure reads `(encoder, w, h)` ONCE per
    /// frame under the lock — identical cost to the existing `currentGovernedFPS()` read — and DROPS
    /// any buffer whose size != the configured size (the ≤1-frame transient while SCK applies a new
    /// `updateConfiguration`), so a mismatched buffer never reaches a resolution-fixed `VTCompressionSession`.
    final class SwappableEncoder: @unchecked Sendable {
        private let lock = NSLock()
        private var encoder: VideoEncoder
        private var pixelWidth: Int
        private var pixelHeight: Int
        init(encoder: VideoEncoder, pixelWidth: Int, pixelHeight: Int) {
            self.encoder = encoder
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }

        /// Atomically re-point the dispatch at `encoder` with its new configured size (in-place resize).
        func swap(encoder: VideoEncoder, pixelWidth: Int, pixelHeight: Int) {
            lock.lock()
            self.encoder = encoder
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            lock.unlock()
        }

        /// The hot per-frame hand-off (capture queue). Reads the live encoder + size once, drops a
        /// size-mismatched buffer, else runs the same dispatch the construction closure would.
        func encode(
            pixelBuffer: CVPixelBuffer,
            pts: CMTime,
            forceKeyframe: Bool,
            crisp: Bool,
            compact: Bool,
            ltrRefresh: Bool,
            perFrameMaxQP: Int?,
            log: Logger,
        ) {
            lock.lock()
            let enc = encoder
            let w = pixelWidth
            let h = pixelHeight
            lock.unlock()
            // Transient guard: a buffer at the OLD size may arrive after the encoder swap but before
            // SCK applies the new capture config. Drop it — the next matching new-size buffer is the IDR.
            guard CVPixelBufferGetWidth(pixelBuffer) == w, CVPixelBufferGetHeight(pixelBuffer) == h else { return }
            do {
                if ltrRefresh {
                    try enc.encodeLiveLTRRefresh(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if crisp {
                    try enc.encodeLiveCrispKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if compact {
                    try enc.encodeCompactKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else {
                    try enc.encodeLive(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts,
                        forceKeyframe: forceKeyframe,
                        perFrameMaxQP: perFrameMaxQP,
                    )
                }
            } catch {
                log.error("live encode failed: \(String(describing: error))")
            }
        }
    }

    /// The live capturer's swappable encoder box (the in-place-resize hand-off). Set alongside
    /// `encoder`/`capturer`; an in-place resize swaps it, the restart path rebuilds it.
    private var encoderBox: SwappableEncoder?

    // MARK: In-session resize (PATH A — AX window resize)

    /// Performs the live in-session resize for a `.resizeCapture` effect (the SM already
    /// clamped + epoch-gated the request). PATH A: resize the REAL host window via the
    /// Accessibility API, read back the ACHIEVED size, rebuild the encoder + capturer at the
    /// achieved PIXEL size, and only THEN send `resizeAck(achieved, epoch)`. Abort cleanly
    /// (keep the old encoder running, send NO ack) on any AX/encoder failure — never crash.
    ///
    /// Ordering (industry drain→recreate→forceIDR + the spec's option 4b):
    ///   a. AX-resize the window; read back the achieved POINT size (window may self-clamp).
    ///   b. Build the NEW encoder (createLiveSession) FIRST; abort if it throws.
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
        // Snapshot the ACHIEVED point size BEFORE the AX resize so any abort AFTER the window has
        // already moved can roll the window back to it (window/capture aspect must agree again) and,
        // for the dead-capturer case, rebuild an old-size capturer so frames resume.
        // `currentWindowBoundsCG()` reads the live window via the watcher and itself falls back to the
        // window's creation frame if the live read fails — never nil.
        let preResizePoints: VideoSize = currentWindowBoundsCG().size
        // Pre-resize PIXEL size, for restoring the encoder box on an in-place-resize fallback.
        let preResizePixelWidth = max(1, Int((preResizePoints.width * captureScale).rounded()))
        let preResizePixelHeight = max(1, Int((preResizePoints.height * captureScale).rounded()))
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
        // The new resolution has a new ceiling — re-seed the controller to it once the new
        //    encoder is actually installed (below), so the controller re-anchors after a resize.
        let ceiling = LiveBitratePolicy.targetBitrate(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fps: fps,
            floor: bitrate,
        )
        let newEncoder = VideoEncoder(
            width: pixelWidth,
            height: pixelHeight,
            bitrate: ceiling,
            fps: fps,
            fullRange: Self.fullRange,
            ltrEnabled: Self.ltrEnabled,
            outputHandler: makeEncoderOutputHandler(),
        )
        do {
            try newEncoder.createLiveSession()
        } catch {
            log.error("resize encoder create failed: \(String(describing: error)) — keeping old encoder")
            dbg("resizeCapture epoch=\(epoch) — new encoder create FAILED; ABORTED (old encoder kept)")
            // The AX window resize at (a) already happened, but the OLD capturer is still running at
            // the OLD pixel config — so the (now bigger/smaller) window content is scaled into the old
            // buffer → a distorted stream with no ack. Roll the AX window BACK to the pre-resize point
            // size so the running old capture matches the window aspect again. The old encoder/capturer
            // are untouched (still installed + live); only the window geometry is restored. (See the SM
            // re-ack residual note at the function tail.)
            await rollBackWindow(toPoints: preResizePoints, watcher: watcher, epoch: epoch)
            return
        }

        // c. Build the NEW capturer bound to the new encoder (option 4b — stop the old capturer,
        //    start a fresh one at the achieved pixel size). A new capturer ⇒ hasEmittedFirstFrame
        //    false ⇒ forced IDR on its first frame for free, and avoids the per-frame
        //    encoder-ref swap race entirely.
        let logCallback = log
        // IN-PLACE FAST PATH (SLOPDESK_INPLACE_RESIZE, per-mode gated): reconfigure the LIVE
        // SCStream to the new size via `updateConfiguration` + swap the encoder box, instead of
        // tearing the stream down and paying SCK's ~120ms `startCapture` spin-up (the resize freeze).
        // On ANY failure (updateConfiguration throws, unproven mode, union/DIALOG-EXPAND) it falls
        // through to the byte-identical restart path below — correctness never regresses.
        if Self.inPlaceResizeEnabled,
           let liveCapturer = capturer, liveCapturer === oldCapturer,
           let box = encoderBox,
           WindowCapturer.canResizeInPlace(
               flagEnabled: Self.inPlaceResizeEnabled,
               isDisplayAnchored: liveCapturer.isDisplayAnchored,
               isUnion: liveCapturer.isUnionAnchored,
           )
        {
            // Swap the encoder FIRST (new-size buffers must hit the new-size encoder) — the fresh VT
            // session's first frame is an IDR; requestKeyframe() belt-and-suspenders forces it too —
            // then reconfigure the live stream. updateSize throws on any failure → swap the box back +
            // fall through to the restart path with a STILL-LIVE old stream.
            box.swap(encoder: newEncoder, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            liveCapturer.requestKeyframe()
            do {
                try await liveCapturer.updateSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
                // Post-await recheck (the await is a suspension point) — only the newest epoch installs;
                // a superseding bye/stop nils `capturer`. Compare to oldCapturer (the object is unchanged).
                guard stateMachine.mediaFlowing, capturer === oldCapturer, encoder === oldEncoder,
                      epoch >= stateMachine.lastResizeEpoch
                else {
                    dbg("resize(in-place) epoch=\(epoch) — superseded during updateSize; leaving live stream, no ack")
                    return
                }
                encoder = newEncoder
                seedCongestionController(ceiling: ceiling) // re-anchor controller to new ceiling
                resetLTRForNewEncoder() // new VT session holds no acked LTRs
                oldEncoder.completeFrames() // drain the old encoder AFTER the swap (no frames route to it now)
                // Re-apply the live EFFECTIVE cadence (governed + user cap) to the swapped encoder;
                // the capturer (and its latch) is unchanged on this in-place path.
                if effectiveStreamFps != fps { newEncoder.setExpectedFrameRate(effectiveStreamFps) }
                dbg(
                    "resize(in-place) epoch=\(epoch) — updateConfiguration to \(pixelWidth)x\(pixelHeight) px, NO restart",
                )
                await apply(.sendControl(.resizeAck(
                    captureWidth: achievedWidth,
                    captureHeight: achievedHeight,
                    epoch: epoch,
                )))
                return
            } catch {
                // In-place failed: the OLD stream was NEVER stopped and updateSize restored the box to
                // the old encoder, so frames are still flowing at the OLD size — no dead stream. Fall
                // through to the restart path (which rebuilds a fresh capturer at the new size).
                box.swap(encoder: oldEncoder, pixelWidth: preResizePixelWidth, pixelHeight: preResizePixelHeight)
                log.error("in-place resize failed (\(String(describing: error))) — falling back to stream restart")
                dbg("resize(in-place) epoch=\(epoch) — updateSize threw; restart fallback")
            }
        }

        let newBox = SwappableEncoder(encoder: newEncoder, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let newCapturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: true, // low-latency default (see WindowCapturer.preferDisplayAnchored)
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP in
            newBox.encode(
                pixelBuffer: pixelBuffer,
                pts: pts,
                forceKeyframe: forceKeyframe,
                crisp: crisp,
                compact: compact,
                ltrRefresh: ltrRefresh,
                perFrameMaxQP: perFrameMaxQP,
                log: logCallback,
            )
        }

        // Stop the OLD capturer first (no frames into the dead encoder), then drain the OLD
        // encoder so any already-encoded output is flushed before it is released.
        await oldCapturer.stop()
        oldEncoder.completeFrames()

        // `oldCapturer.stop()` is a suspension point: a `bye`/`stop` teardown (or a newer resize) can
        // run while we are suspended. The supersede guard must be asserted HERE, BEFORE installing — a
        // guard placed after `self.capturer = newCapturer` can never catch a teardown that ran DURING
        // this suspension (it would compare newCapturer to itself). If the session was torn down OR our
        // refs were swapped, simply return: `newCapturer` is NOT started yet (no SCStream to stop) and
        // both locals deinit on return (VideoEncoder.deinit invalidates its VTCompressionSessions), so
        // we install nothing and send no ack. Mirrors the pre-AX recheck + startLiveComponents'
        // post-await identity guard.
        //
        // Rapid-double-resize epoch race: a newer resize request can commit a higher `lastResizeEpoch`
        // in the SM while we are suspended. Only the NEWEST epoch may install — abort a stale one
        // (re-read the SM under actor isolation: `epoch >= stateMachine.lastResizeEpoch`).
        guard stateMachine.mediaFlowing, capturer === oldCapturer, encoder === oldEncoder,
              epoch >= stateMachine.lastResizeEpoch
        else {
            dbg(
                "resizeCapture epoch=\(epoch) — superseded/stale during oldCapturer.stop (lastEpoch=\(stateMachine.lastResizeEpoch)); aborting install",
            )
            return
        }

        // Install the new components, then bring the new SCStream up at the achieved pixel size.
        encoder = newEncoder
        seedCongestionController(ceiling: ceiling) // re-anchor the controller to the new resolution's ceiling
        resetLTRForNewEncoder() // the new VT session holds no acked LTRs — invalidate the acked-set
        capturer = newCapturer
        encoderBox = newBox // the new capturer's hot-path hand-off
        // FPS GOVERNOR: a fresh capturer/encoder start at the base fps — re-apply the live
        // governed state clamped by the user fps cap (both persist across resize: path/user
        // knowledge). No client message — the cadence is unchanged.
        if effectiveStreamFps != fps {
            newCapturer.setGovernedFPS(effectiveStreamFps)
            newEncoder.setExpectedFrameRate(effectiveStreamFps)
        }
        // Resize is a WINDOW-session path (the SM rejects a display resize) — defensive unwrap.
        guard let captureWindow = window else { return }
        do {
            nonisolated(unsafe) let w = captureWindow
            try await newCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg(
                "resize: new SCStream started (\(pixelWidth)x\(pixelHeight) px @\(captureScale)×, \(achievedWidth)x\(achievedHeight) pt) epoch=\(epoch)",
            )
        } catch {
            log.error("resize capturer start failed: \(String(describing: error))")
            dbg("resizeCapture epoch=\(epoch) — new capturer START FAILED")
            // The OLD capturer is already stopped and the NEW SCStream.start threw, so the installed
            // `self.capturer` is a DEAD stream (stream == nil) — no frames will EVER come again, and
            // requestIDR / the heartbeat path is a no-op on a dead capturer (it CANNOT recover this).
            // Recover explicitly:
            //   (a) roll the AX window BACK to the pre-resize point size so window/capture aspect
            //       agree again, then
            //   (b) REBUILD an old-size capturer + encoder (like startLiveComponents, at the OLD
            //       pixel size) and start it so frames resume.
            // If the rollback/restart itself fails, log + leave the (dead) refs cleared rather than
            // crash. Do NOT send an ack (no new-size stream came up).
            await rollBackWindow(toPoints: preResizePoints, watcher: watcher, epoch: epoch)
            await restartOldSizeCapture(
                points: preResizePoints,
                epoch: epoch,
                deadCapturer: newCapturer,
                deadEncoder: newEncoder,
            )
            return
        }
        // Identity guard (symmetric to `startLiveComponents`): a superseding teardown/start during
        // `newCapturer.start` means our refs are no longer installed — tear down the orphan stream
        // and do NOT ack (a newer owner is live).
        guard capturer === newCapturer else {
            dbg("resize superseded during capturer.start — tearing down orphaned new stream")
            await newCapturer.stop()
            return
        }

        // d. Ack LAST — after the new stream is up. The ack may race slightly ahead of the first
        //    new-size IDR (start() does not await the first frame); this is SAFE because the
        //    client adopts the new size only when a matching decoded buffer arrives (frame-gated
        //    `noteDecoded` / `ResizeAdoption`), not on ack receipt.
        //
        // ⚠️ KNOWN RESIDUAL (re-ack edge): the SM commits captureWidth/captureHeight/lastResizeEpoch
        // SYNCHRONOUSLY before this effect runs (VideoSessionLogic.swift ~L152). On a
        // failed-then-rolled-back resize above we restore the WINDOW + capture to the OLD size but do
        // NOT correct the SM, so it still reports the REQUESTED size; a duplicate-hello re-ack would
        // then echo the requested (not actual) size in `helloAck`. The SM is deliberately left alone —
        // a blind SM rollback risks an epoch/size desync riskier than this cosmetic edge (a real resize
        // re-issues anyway). Revisit with the Mac Studio in the loop (failure paths aren't
        // headless-exercisable).
        await apply(.sendControl(.resizeAck(captureWidth: achievedWidth, captureHeight: achievedHeight, epoch: epoch)))
    }

    /// Rollback: re-issue the AX window resize back to `points` so the (still-running OR
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

    /// Recovery after a capturer-start abort left a DEAD capturer (old stopped, new failed to start):
    /// rebuild an OLD-size capturer + encoder (the same wiring as ``startLiveComponents``, at the
    /// pre-resize pixel size) and start it so frames RESUME — `requestIDR`/heartbeat cannot revive a
    /// stream whose `start()` threw. Reuses the EXISTING geometry/cursor/injector (those were never
    /// torn down by the resize). If the rebuild's own `start()` throws, clear the dead refs + log
    /// rather than leave a dead capturer installed (no crash). Symmetric to the startLiveComponents
    /// post-await identity guard: if a superseding owner installed its own capturer while we were
    /// suspended, tear down our orphan and leave theirs.
    private func restartOldSizeCapture(
        points: VideoSize,
        epoch: UInt32,
        deadCapturer: WindowCapturer,
        deadEncoder: VideoEncoder,
    ) async {
        // We reached here THROUGH `rollBackWindow`'s `await MainActor.run` suspension, across which
        // EITHER (a) a `bye`/reap/`stop()` teardown ran on a separate Task (→ mediaFlowing false, refs
        // nil'd) OR (b) a NEWER resize installed its OWN live capturer/encoder (→ mediaFlowing STAYS
        // true). A bare mediaFlowing check catches (a) but NOT (b). So also require the dead refs we
        // are recovering to STILL be the installed ones AND this epoch to still be newest — mirroring
        // the install-site guard. If a newer owner is live, bail: clearing/rebuilding would orphan ITS
        // SCStream (a streaming-but-dead leak). The failed dead refs are locals that deinit cleanly on
        // return (the failed capturer has no SCStream; deadEncoder.deinit invalidates its
        // VTCompressionSessions).
        guard stateMachine.mediaFlowing,
              capturer === deadCapturer, encoder === deadEncoder,
              epoch >= stateMachine.lastResizeEpoch
        else {
            dbg("resizeCapture epoch=\(epoch) — superseded/torn-down during rollback; skip recovery restart")
            return
        }
        // Drop the dead refs the failed resize left installed before rebuilding.
        encoder = nil
        capturer = nil
        let pixelWidth = max(1, Int((points.width * captureScale).rounded()))
        let pixelHeight = max(1, Int((points.height * captureScale).rounded()))

        // This recovery rebuild uses the OLD (pre-resize) pixel size — re-seed the controller to
        // its ceiling once installed so it re-anchors to the size actually being captured.
        let ceiling = LiveBitratePolicy.targetBitrate(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fps: fps,
            floor: bitrate,
        )
        let rebuiltEncoder = VideoEncoder(
            width: pixelWidth,
            height: pixelHeight,
            bitrate: ceiling,
            fps: fps,
            fullRange: Self.fullRange,
            ltrEnabled: Self.ltrEnabled,
            outputHandler: makeEncoderOutputHandler(),
        )
        do {
            try rebuiltEncoder.createLiveSession()
        } catch {
            log
                .error(
                    "resize recovery: old-size encoder rebuild failed: \(String(describing: error)) — capture stays down",
                )
            dbg("resizeCapture epoch=\(epoch) — old-size encoder rebuild FAILED; capture remains down")
            return
        }

        let logCallback = log
        let rebuiltCapturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: true, // low-latency default (see WindowCapturer.preferDisplayAnchored)
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP in
            do {
                if ltrRefresh {
                    try rebuiltEncoder.encodeLiveLTRRefresh(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if crisp {
                    try rebuiltEncoder.encodeLiveCrispKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if compact {
                    try rebuiltEncoder.encodeCompactKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else {
                    try rebuiltEncoder.encodeLive(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts,
                        forceKeyframe: forceKeyframe,
                        perFrameMaxQP: perFrameMaxQP,
                    )
                }
            } catch {
                logCallback.error("live encode (post-resize recovery) failed: \(String(describing: error))")
            }
        }
        encoder = rebuiltEncoder
        seedCongestionController(ceiling: ceiling) // re-anchor the controller to the rebuilt (old-size) ceiling
        resetLTRForNewEncoder() // the rebuilt VT session holds no acked LTRs — invalidate the acked-set
        capturer = rebuiltCapturer
        // FPS GOVERNOR + USER FPS CAP: re-apply the live effective cadence (see applyResize).
        if effectiveStreamFps != fps {
            rebuiltCapturer.setGovernedFPS(effectiveStreamFps)
            rebuiltEncoder.setExpectedFrameRate(effectiveStreamFps)
        }
        // Resize recovery is a WINDOW-session path (the SM rejects a display resize) — defensive unwrap.
        guard let captureWindow = window else { return }
        do {
            nonisolated(unsafe) let w = captureWindow
            try await rebuiltCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg(
                "resizeCapture epoch=\(epoch) — recovered: old-size capture restarted (\(pixelWidth)x\(pixelHeight) px)",
            )
        } catch {
            log
                .error(
                    "resize recovery: old-size capturer start failed: \(String(describing: error)) — capture stays down",
                )
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
            if capturer === rebuiltCapturer { capturer = nil
                encoder = nil
            }
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

        // Encoder: the EXACT doc-18 low-latency HEVC live session + crisp static refresh (created inside VideoEncoder).
        // Bitrate is resolution-aware (LiveBitratePolicy): a 2× HiDPI window has 4× the pixels and must
        // be provisioned proportionally or the rate cap starves scroll frames → stutter (`bitrate` is the floor).
        // This resolution-aware result is BOTH the encoder bitrate AND the congestion controller's
        // ceiling (the controller may never exceed it). Hoist it so we can seed the controller below.
        let ceiling = LiveBitratePolicy.targetBitrate(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fps: fps,
            floor: bitrate,
        )
        let encoder = VideoEncoder(
            width: pixelWidth,
            height: pixelHeight,
            bitrate: ceiling,
            fps: fps,
            fullRange: Self.fullRange,
            ltrEnabled: Self.ltrEnabled,
            outputHandler: makeEncoderOutputHandler(),
        )
        do {
            try encoder.createLiveSession()
        } catch {
            log.error("encoder session create failed: \(String(describing: error)) — aborting session")
            dbg("ENCODER create FAILED: \(String(describing: error)) — aborting")
            return
        }
        self.encoder = encoder
        let encoderBox = SwappableEncoder(encoder: encoder, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        self.encoderBox = encoderBox
        seedCongestionController(ceiling: ceiling) // anchor the controller to this build's ceiling
        resetLTRForNewEncoder() // anchor the LTR acked-set to this build (clears any prior-client acks on actor reuse)
        // FPS GOVERNOR: fresh session ⇒ fresh governor at the base fps (nil when the flag is off ⇒
        // no fold, no tick, no gate — byte-identical host).
        fpsGovernor = Self.fpsGovernorEnabled ? FPSGovernor(baseFps: fps) : nil
        governedFps = fps

        // Capturer: NV12 frames → encoder.encodeLive (zero-copy hand-off). The capture
        // closure captures the encoder DIRECTLY (not via the actor) so the hot per-frame
        // path encodes synchronously on the capture queue and returns within the
        // queue-depth deadline — no actor hop per frame. `VideoEncoder` is
        // `@unchecked Sendable` and thread-safe for `encodeLive`. The encoded OUTPUT is
        // what hops back to the actor (`onEncodedFrame`) to packetize + send.
        let logCallback = log
        // CONGESTION BACKPRESSURE: capture the (thread-safe `.depth`) send-lane reference so the
        // capture-queue closure can drop a delta BEFORE encode when the lane is backed up — bounding
        // end-to-end latency under scroll bursts (see `backpressureSkip`). nil ⇒ no lane ⇒ never skips.
        let backpressureLane = sendLane
        let capturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: true, // low-latency default (see WindowCapturer.preferDisplayAnchored)
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP in
            if let lane = backpressureLane, Self.backpressureSkip(
                enabled: Self.backpressureEnabled,
                laneDepth: lane.depth,
                depthThreshold: Self.backpressureDepth,
                forceKeyframe: forceKeyframe,
                crisp: crisp,
                compact: compact,
                ltrRefresh: ltrRefresh,
            ) {
                if Self
                    .debugStderr
                {
                    logCallback.notice("backpressure skip: lane depth \(lane.depth) > \(Self.backpressureDepth)")
                }
                return // drop this delta before encode — the P-chain stays intact, latency bounded
            }
            encoderBox.encode(
                pixelBuffer: pixelBuffer,
                pts: pts,
                forceKeyframe: forceKeyframe,
                crisp: crisp,
                compact: compact,
                ltrRefresh: ltrRefresh,
                perFrameMaxQP: perFrameMaxQP,
                log: logCallback,
            )
        }
        self.capturer = capturer

        // Geometry watcher → geometry datagrams + keep input/cursor bounds in sync. WINDOW
        // sessions only: a display's bounds never change, so a full-desktop session has no watcher
        // (and no geometry datagrams — the client's mapping origin stays the helloAck bounds).
        var geometryWatcher: WindowGeometryWatcher?
        if let window {
            geometryWatcher = WindowGeometryWatcher(
                windowID: window.windowID,
                pid: window.owningApplication?.processID ?? 0,
            ) { [weak self] message in
                guard let self else { return }
                Task { await self.onGeometry(message) }
            }
        }
        self.geometryWatcher = geometryWatcher
        // DIALOG-EXPAND: arm the union poll only when the window is VD-parked (display-anchored
        // capture — the feature relies on includeChildWindows compositing the dialog) and the
        // feature env is on. The handler hops onto the actor; ``onAssociatedUnion`` decides whether
        // the union differs from the live region enough to rebuild. (A display session has neither
        // a size override nor a watcher, so this stays off there.)
        dialogExpandArmed = (captureSizeOverride != nil) && Self.dialogExpandEnabled
        captureRegionGlobal = nil // a fresh/reused session starts captured at the plain window frame
        if dialogExpandArmed {
            geometryWatcher?.setAssociatedUnionHandler { [weak self] unionGlobal, contentRectsGlobal in
                guard let self else { return }
                Task { await self.onAssociatedUnion(unionGlobal, contentRectsGlobal: contentRectsGlobal) }
            }
        }

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

        // Input injector (created with the window pid + bounds). SEEDED with the carried
        // held-button/modifier balance so a transparent-reconnect rebuild (bye → fresh hello)
        // still matches — and posts — the up of a button/⌘ the user held across the reconnect
        // (see `carriedInputBalance`). If a live injector is being REPLACED without an
        // intervening teardown, its balance is the freshest truth — snapshot it first.
        if let injector { carriedInputBalance = injector.balanceSnapshot }
        if let window {
            injector = InputInjector(
                pid: window.owningApplication?.processID ?? 0,
                windowID: window.windowID,
                windowBoundsCG: bounds,
                balance: carriedInputBalance,
            )
        } else {
            // Full-desktop: display-scoped injector — same affine mapping over the display's CG
            // bounds, NO AX raise (there is no one target window; posted CGEvents already land
            // wherever a local user's would).
            injector = InputInjector(displayBoundsCG: bounds, balance: carriedInputBalance)
        }
        inputNeedsRaise = true

        // Bring the live sources up. `window`/`display` are AppKit/SCK types (not Sendable);
        // they are owned only by this actor and handed to the capturer here. The capture
        // path is GUI-only and single-owner, so this hand-off is safe.
        do {
            // ⚠️ Suspension point (symmetric to `teardownLiveComponents`). `capturer.start`
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
            if let window {
                nonisolated(unsafe) let w = window
                try await capturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            } else if let display {
                nonisolated(unsafe) let d = display
                try await capturer.start(display: d, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            }
            dbg(
                "SCStream capture started (\(pixelWidth)x\(pixelHeight) px @\(captureScale)×, \(width)x\(height) pt) — awaiting frames",
            )
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
            await capturer.stop() // async: stops the SCStream we just brought up (stream = nil)
            cursorSampler.stop()
            geometryWatcher?.stop()
            // `encoder`/`injector` are inert until the (now-skipped) capture/input path drives
            // them; releasing the locals lets them deinit (VideoEncoder.deinit invalidates its
            // VTCompressionSessions). Do not clear actor refs — a superseding start owns them.
            return
        }

        geometryWatcher?.startDragPolling()
        cursorSampler.start()
        log.info("live capture/encode/geometry/cursor running")
    }

    private func teardownLiveComponents() async {
        // Cancel the DIALOG-EXPAND contract debounce so a pending region contraction can't fire (rebuild)
        // after teardown. Inert anyway ([weak self] + mediaFlowing-guarded), but cancel for consistency.
        pendingContractTask?.cancel()
        pendingContractTask = nil
        // Drop any held scroll residual + its idle flush: a stale gesture tail from the session
        // being torn down must not be injected at the start of the next one.
        scrollIdleFlushTask?.cancel()
        scrollIdleFlushTask = nil
        scrollPlanner.clearPending()
        // Frames queued in the paced-send lane belong to the capture/encode generation being torn
        // down — drop them (a mid-pace job aborts at its next chunk boundary). The lane itself
        // survives for the next hello; `stop()` is what closes it.
        sendLane?.flush()
        // APP-AUDIO: close the send gate BEFORE stopping the stream — a buffer already queued on
        // the capturer's audio queue must not race a datagram onto the wire mid-teardown
        // ("streaming AND enabled" is the lane's send contract). The wish itself resets at the
        // next `.startCapture`; the lane (and its seq) survives for a possible re-hello.
        audioSender?.setEnabled(false)
        // Compare-and-clear race guard. `bye → .listening` is re-armable, so a bye's stopCapture
        // (this teardown) can overlap a reconnect hello's startCapture: `await capturer?.stop()`
        // (a slow SCStream stopCapture) is a suspension point across which a newer
        // `startLiveComponents` can install FRESH capturer/encoder/etc. Snapshot
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
        if injector === staleInjector {
            // Carry the held-button/modifier truth forward BEFORE dropping the injector, so the
            // next hello's rebuild seeds from it (else a reconnect strands a held drag/modifier).
            // Inside the same identity guard as the clear: a stale teardown resuming after a newer
            // start must not overwrite the carry with an older injector's state.
            if let staleInjector { carriedInputBalance = staleInjector.balanceSnapshot }
            injector = nil
        }
    }

    // MARK: Component callbacks

    /// Builds the encoder's `@Sendable` output handler. The VT serial callback APPENDS the encoded
    /// frame to the ordered FIFO and signals the single consumer — it does NOT spawn a per-frame
    /// `Task` (which would race onto the actor and scramble frameID/streamSeq). Snapshots the actor's
    /// queue + wakeup once at build time (both created in ``start()`` before any encoder, and stable
    /// across resize), so the hot callback never hops back to the actor just to enqueue. A frame that
    /// arrives after teardown (`encodedWakeup.finish()`) is dropped by the `.bufferingNewest(1)` stream
    /// being finished.
    private func makeEncoderOutputHandler() -> VideoEncoder.OutputHandler {
        let queue = encodedQueue
        let wakeup = encodedWakeup
        return { avcc, keyframe, mode, ltrToken, ackedAnchored in
            // Enqueue THEN signal (no lost wakeup): the consumer always drains after the last append.
            queue?.append(EncodedFrameQueue.Frame(
                avcc: avcc,
                keyframe: keyframe,
                crisp: mode == .crisp,
                ltrToken: ltrToken,
                ackedAnchored: ackedAnchored,
            ))
            wakeup?.yield()
        }
    }

    private func onEncodedFrame(avcc: Data, keyframe: Bool, crisp: Bool, ltrToken: Int64?, ackedAnchored: Bool) async {
        guard stateMachine.mediaFlowing else {
            dbg("encoded frame DROPPED (mediaFlowing=false)")
            return
        }
        // FPS GOVERNOR: fold this frame's encoded size into the offered-load EWMA. Anchors
        // (keyframe/crisp) are excluded — episodic 5-10× outliers would fake over-budget right
        // after every recovery IDR; LTR refreshes ARE folded (steady-state stream cost).
        if var gov = fpsGovernor {
            gov.noteEncodedFrame(bytes: avcc.count, isAnchor: keyframe || crisp)
            fpsGovernor = gov
        }
        // ABR utilization signal (always on, independent of the FPS governor): fold this DELTA frame's
        // size into the offered-load EWMA. Anchors (keyframe/crisp) excluded — episodic 5-10× IDR
        // outliers would fake high utilization right after every recovery. Separated mul/add (no FMA).
        if !(keyframe || crisp) {
            offeredBytesPerFrameEWMA = offeredBytesPerFrameEWMA * (1.0 - Self.offeredEWMAAlpha)
                + Double(avcc.count) * Self.offeredEWMAAlpha
        }
        encodedFrameCount += 1
        if encodedFrameCount == 1 || encodedFrameCount.isMultiple(of: 15) {
            dbg("encoded+sent frame #\(encodedFrameCount) (\(avcc.count)B, keyframe=\(keyframe), crisp=\(crisp))")
        }
        // i2h (debug-only): log the inject→encoded segment of input-to-photon. `lastInputRxMs`
        // was set in `receiveBatch` on a key/mouse-DOWN; this is the FIRST encoded frame after it, so the
        // delta ≈ host inject → app paints → SCK capture → encode. Combined with the client `pacer hold` +
        // RTT it yields end-to-end input-to-photon. Reset to 0 ⇒ measured once per input, not every frame.
        // Naturally debug-gated: lastInputRxMs is only ever set under `debugStderr`.
        if lastInputRxMs != 0 {
            let hostSegMs = Int(Int32(bitPattern: hostRelativeMillis() &- lastInputRxMs))
            lastInputRxMs = 0
            dbg("i2h ms=\(hostSegMs)")
        }
        // Stamp the host-relative send time on every fragment of this frame (the network-feedback
        // channel). All fragments of one frame share one stamp; the ~≤6 ms pacing/kfDup bias is
        // sub-frame and acceptable (it makes the measured RTT a slight upper bound — the safe
        // direction). 0 when telemetry is disabled (SLOPDESK_NETSTATS=0) → the client reports
        // latestHostSendTs=0 → the host's RTT fold is skipped.
        let sendTs: UInt32 = Self.telemetryEnabled ? hostRelativeMillis() : 0
        // FRAME-TYPE PROTECTION MODEL (latency-first). The frame that MUST survive a WAN loss burst is
        // the "sharp" one, and it is protected: every keyframe — including the crisp QP18 static
        // re-anchor, which encodes as an IDR ⇒ keyframe=true (VideoEncoder.keyframe = !notSync) — is
        // DUPLICATE-SENT by kfDup. In-motion DELTAS ride the cheap adaptive FEC ladder only (it relaxes
        // toward g10 on a clean link and re-tightens on detected loss): a lost delta blurs/glitches for
        // ≤1 self-heal cadence and then re-sharpens, which is cheaper than spending extra parity on
        // motion frames. Fully cutting delta FEC (SLOPDESK_FEC_ALLOW_OFF=1) stays OPT-IN: FEC/kfDup are
        // load-bearing on a real lossy WAN (a max-cut is a hard negative), so flipping it needs a WAN
        // A/B + loopback-validate.
        // The per-frame FEC tier. Adaptive OFF ⇒ always tier 0 (the configured g5).
        // MULTI-LOSS (SLOPDESK_FEC_M>=2): `wireTier` FORCES tier 0 for every frame so the per-frame
        // group size resolves to the codec's `k` (the Cauchy matrix has exactly k columns / clamps to
        // min(g,k), so m>1 REQUIRES group_size == k). The dynamic adaptive tiers (g2/g3/g10/OFF) are
        // NOT used when m>1. With m==1 the adaptive tier passes through unchanged.
        // Read the ladder tier when EITHER ladder is active (group-size OR adaptive-m); `wireTier`
        // then forces/passes it per the active mode (adaptive-m passes the m-tier 5/6/7 through).
        let adaptiveTier = (Self.adaptiveFECEnabled || Self.adaptiveMEnabled)
            ? fecTierState.tier
            : AdaptiveFECPolicy.defaultTier
        let tier = AdaptiveFECPolicy.wireTier(adaptiveTier: adaptiveTier)
        // If this is an LTR frame (SLOPDESK_LTR on AND the encoder surfaced an ack token), the
        // record below (post-packetize) maps the frameID the lane RETURNS to the token so a later
        // client ack(frameID) can fold it, AND every fragment carries the isLTR wire bit so the
        // client knows to ack on decode. Off ⇒ ltrToken nil ⇒ no record, isLTR false. The packetize
        // lane persists across resize, so the frameID is stable; frames flow through here one at a
        // time in encode order → the record stays race-free.
        // STALE-LTR GUARD: an IDR resets the DECODER's reference world — the DPB, long-term references
        // INCLUDED, is cleared by HEVC spec — so every token acked BEFORE this keyframe describes a
        // reference the client no longer holds. Without this reset a post-IDR ForceLTRRefresh can
        // reference a pre-IDR acked token the client cannot decode: -12909 → invalidateSession → forced
        // IDR → another stale refresh — a self-sustaining failure loop (observed live: ltr=true
        // fec=false hard-fails on a loss-free wire, ~1/6s under scroll). Mirror of
        // ``resetLTRForNewEncoder`` fired per ENCODED keyframe (any source: recovery grant, escalation,
        // connect, crisp-IDR), BEFORE the record below so the keyframe's OWN token (post-IDR, valid)
        // still registers; the client re-acks within ~one self-heal cadence and refreshes resume.
        if keyframe {
            ltrController.reset()
            capturer?.setSelfHealEligible(false)
            encoder?.clearStagedAckedTokens()
        }
        let isLTR = Self.ltrEnabled && ltrToken != nil
        // Packetize AND interleave OFF-ACTOR on the dedicated ``PacketizeLane``. The lane MTU-splits,
        // FEC-parities (no double-FEC), stamps the 19-byte header, and (when `interleave`) reorders
        // transmission column-major across FEC groups so an adjacent-loss BURST spreads to distinct
        // groups (each recoverable) instead of wiping one group. Header `fragIndex`/grouping is
        // unchanged, so the client (reassembles by index, reorder-tolerant) is unaffected — host-only,
        // no wire change. The lane keys the interleave by the SAME per-frame group size the parity used,
        // m-aware (OFF tier ⇒ no-op; tier 0 ⇒ the codec's group). RAW send path (perf): finished wire
        // datagrams directly, no FrameFragment parse/re-encode round-trip (byte-identical, unit-pinned
        // by PacketizeRawByteIdentityTests + PacketizeLaneTests).
        //
        // The `await` is the POINT: run this heavy per-frame work synchronously on THIS actor and a
        // keystroke arriving mid-packetize of a large IDR waits several ms for `CGEventPost`.
        // Suspending here frees the actor for the inbound input consumer; frame ORDER is untouched
        // because the single encoded-frame consumer awaits `onEncodedFrame` one frame at a time
        // end-to-end (this method has no other caller).
        let packetized = await packetizeLane.packetize(
            frame: avcc,
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: sendTs,
            fecTier: tier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
            interleave: Self.interleaveTransmit,
        )
        // A bye/stop teardown can interleave through the await above: its `sendLane.flush()` already
        // dropped the queued frames of this capture generation, so drop this one too instead of
        // enqueueing it after the flush — and skip the bookkeeping below (the frame is never sent, so
        // nothing may reference its frameID).
        guard stateMachine.mediaFlowing else {
            dbg("encoded frame DROPPED post-packetize (mediaFlowing=false)")
            return
        }
        // Record the frameID↔token mapping for the LTR frame JUST packetized (the lane
        // returns the frameID it assigned, so record and packetize cannot race) so a later
        // client ack(frameID) can fold the token. Off ⇒ ltrToken nil ⇒ no record.
        if isLTR, let token = ltrToken {
            ltrController.recordLTRFrame(frameID: packetized.frameID, token: token)
        }
        // Record (keyframe frameID, sentAt) for the delivery-keyed recovery-IDR cooldown — EVERY
        // keyframe (recovery, first-frame, static-crisp, heartbeat). kfDup's second copy reuses the
        // same frameID, so there is nothing extra to record for it.
        if keyframe {
            recoveryIDRPolicy.noteKeyframeSent(
                frameID: packetized.frameID,
                now: ProcessInfo.processInfo.systemUptime,
            )
        }
        let outgoings = packetized.outgoings
        // Record this frame's datagrams so a later client NACK can be answered by re-sending exactly
        // the lost fragments (nil ring unless SLOPDESK_NACK). Keyed by frameID; bounded ring. Still
        // BEFORE the send-lane feed, so a NACK can never observe a sent-but-unrecorded frame.
        retransmitRing?.record(frameID: packetized.frameID, outgoings: outgoings)
        if Self.debugStderr {
            let now = ProcessInfo.processInfo.systemUptime
            if dbgLastFrameSendAt > 0, now - dbgLastFrameSendAt > 0.028 {
                dbg("send gap \(Int((now - dbgLastFrameSendAt) * 1000))ms")
            }
            dbgLastFrameSendAt = now
        }
        // Hand the frame to the paced-send lane and RETURN — the encoder-output pump must never sleep
        // on pacing (pacing frame N inline delays frames N+1..k → measured 28–179ms send gaps = the
        // stutter). Wire order is preserved (one lane consumer).
        if let sendLane {
            // Keyframes pace at ≥ kfPaceFloorBps — IDR delivery time IS recovery time, and the measured
            // path carries 30Mbps at the same weather-loss as 5Mbps (rate-independent). Deltas floor at
            // deltaPaceFloorBps (0 = off ⇒ raw ABR, byte-identical) — lifts a stale-low scroll-onset delta
            // off a 4Mbps crawl so its send-span (⇒ depth-1 present jitter) shrinks, without un-pacing.
            let paceTargetBps = Self.paceTargetBps(
                keyframe: keyframe, abr: lastActuatedBitrate,
                kfFloorBps: Self.kfPaceFloorBps, deltaFloorBps: Self.deltaPaceFloorBps,
            )
            let gapNanos: UInt64 = !Self.paceSend ? 0 : (Self.pacingAdaptive
                ? Self.adaptivePaceGapNanos(
                    targetBps: paceTargetBps,
                    fallbackBps: Self.pacingFallbackBps,
                    chunkFragments: Self.paceChunkFragments,
                    datagramSize: VideoPacketizer.maxDatagramSize,
                    floorNanos: Self.pacingGapFloorNanos,
                    ceilNanos: Self.pacingGapCeilNanos,
                    rateMultiplier: Self.paceRateMultiplier,
                )
                : Self.paceGapNanos)
            // Inline fast path (input latency): a tiny single-shot DELTA that produces NO second (dup)
            // copy can skip the lane's Task-wakeup hop when the wire is idle — the typing-idle
            // keystroke case, where shaving ~0.1–1 ms off input→photon is felt.
            // `singleShot` mirrors the lane's own one-shot test, so an inlined frame goes out
            // byte-for-byte as the lane would have sent it. Keyframes (kfDup) and loss-gated small
            // deltas (smallDup) keep the lane: they enqueue a SECOND time-separated copy, so
            // primary+dup must stay ordered on the one consumer. `trySendInline` returns false (→
            // enqueue) whenever the lane is busy, so a keystroke can never overtake an earlier,
            // still-draining frame.
            let singleShot = gapNanos == 0 || outgoings.count <= Self.paceChunkFragments
            let willSmallDup = Self.smallDup && !keyframe && avcc.count <= Self.smallDupMaxBytes
                && Self.adaptiveMEnabled && fecTierState.tier != AdaptiveFECPolicy.parityTierClean
            let inlined = singleShot && !keyframe && !willSmallDup && sendLane.trySendInline(outgoings)
            if !inlined {
                sendLane.enqueue(VideoSendLane.Job(
                    outgoings: outgoings,
                    gapNanos: gapNanos,
                    chunkFragments: Self.paceChunkFragments,
                ))
            }
            // Keyframe DUPLICATE-SEND, lane edition: the second copy is just another in-order job
            // with a leading time-separation gap. Throttle state stays actor-owned.
            // LOSS-GATED on the loss EWMA (see `kfDupLossThreshold`): the dup guards a keyframe lost
            // inside the recovery-IDR cooldown, which only matters when the link is actually dropping
            // packets. On a clean link (loss ≈ 0 — the LAN/mesh case) the second copy is pure re-send
            // Parsec never pays, and it occupies the ordered lane delaying the next delta. So dup iff
            // loss is present; it re-engages the instant loss appears, so recovery keyframes — which
            // happen DURING loss — stay protected.
            if Self.kfDup, keyframe, Self.shouldDupKeyframe(
                lossRate: networkEstimate.lossRate,
                nowUptime: ProcessInfo.processInfo.systemUptime,
                fastAttackUntil: kfDupFastAttackUntil,
                threshold: Self.kfDupLossThreshold,
            ) {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastKeyframeDupTime >= Self.kfDupMinInterval {
                    lastKeyframeDupTime = now
                    sendLane.enqueue(VideoSendLane.Job(
                        outgoings: outgoings,
                        gapNanos: gapNanos,
                        chunkFragments: Self.paceChunkFragments,
                        leadingDelayNanos: Self.paceGapNanos,
                    ))
                }
            }
            // SMALL-FRAME DUP (see `smallDup`): a changed small DELTA during active loss — enqueue a
            // second time-separated copy so a burst can't wipe the whole tiny frame. Gated on the
            // elevated adaptive-m tier so an idle/clean static stream is never doubled; keyframes are
            // handled by kfDup above. Same dedup-by-(frameID,fragIndex) on the client → decoded once.
            if Self.smallDup, !keyframe, avcc.count <= Self.smallDupMaxBytes,
               Self.adaptiveMEnabled, fecTierState.tier != AdaptiveFECPolicy.parityTierClean
            {
                sendLane.enqueue(VideoSendLane.Job(
                    outgoings: outgoings,
                    gapNanos: gapNanos,
                    chunkFragments: Self.paceChunkFragments,
                    leadingDelayNanos: Self.paceGapNanos,
                ))
            }
            return
        }
        await sendPaced(outgoings)
        // Keyframe DUPLICATE-SEND (inline path). A heartbeat/recovery IDR is a large multi-datagram
        // burst; even paced, a time-correlated loss in one XOR group is unrecoverable → corrupt IDR →
        // flicker. Re-send the SAME ordered list a second time (paced + time-separated) so the IDR
        // survives unless BOTH copies of a fragment are lost. The reassembler dedups by
        // frameID/fragIndex (overwrite-by-identical-bytes; a copy after completion is .stale) → decoded
        // exactly once. NOT a reorder → no white-screen risk. Keyframes ONLY; throttled to ≤1 per
        // kfDupMinInterval so a storm isn't byte-amplified (`SLOPDESK_KF_DUP=0` disables).
        // LOSS-GATED on the loss EWMA (mirror of the lane-path gate above): dup only when loss is
        // present; on a clean link the double-send is pure overhead Parsec never pays.
        if Self.kfDup, keyframe, stateMachine.mediaFlowing, Self.shouldDupKeyframe(
            lossRate: networkEstimate.lossRate,
            nowUptime: ProcessInfo.processInfo.systemUptime,
            fastAttackUntil: kfDupFastAttackUntil,
            threshold: Self.kfDupLossThreshold,
        ) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastKeyframeDupTime >= Self.kfDupMinInterval {
                lastKeyframeDupTime = now
                try? await Task.sleep(nanoseconds: Self.paceGapNanos) // time-separate the two copies
                if stateMachine.mediaFlowing { await sendPaced(outgoings) }
            }
        }
        // SMALL-FRAME DUP (non-lane path): mirror of the lane-path gate above.
        if Self.smallDup, !keyframe, avcc.count <= Self.smallDupMaxBytes,
           Self.adaptiveMEnabled, fecTierState.tier != AdaptiveFECPolicy.parityTierClean,
           stateMachine.mediaFlowing
        {
            try? await Task.sleep(nanoseconds: Self.paceGapNanos)
            if stateMachine.mediaFlowing { await sendPaced(outgoings) }
        }
    }

    /// Sends one frame's datagrams, PACED (see `paceSend`) when large so a big IDR / scroll-delta does not
    /// blast as one instant burst → no receive-buffer overflow → no burst loss → no flicker. Small frames
    /// send in one shot. Reorder-free + wire-identical, so zero white-screen risk. Re-checks `mediaFlowing`
    /// after each gap so a bye/stop teardown racing the pacing aborts cleanly.
    private func sendPaced(_ outgoings: [VideoSendScheduler.Outgoing]) async {
        if Self.paceSend, outgoings.count > Self.paceChunkFragments {
            // Rate-proportional gap (drain a chunk at ≈ the live link rate) rather than the fixed 0.5ms
            // burst. Computed once per frame from the current ABR target.
            let gapNanos: UInt64 = Self.pacingAdaptive
                ? Self.adaptivePaceGapNanos(
                    // SLOPDESK_SEND_LANE=0 parity: floor the delta pace target the same as the lane path
                    // (0 = off ⇒ raw ABR, byte-identical). This path is not keyframe-aware, so the floor
                    // lifts both — strictly ≥ the raw-ABR gap, never slower.
                    targetBps: max(lastActuatedBitrate, Self.deltaPaceFloorBps),
                    fallbackBps: Self.pacingFallbackBps,
                    chunkFragments: Self.paceChunkFragments,
                    datagramSize: VideoPacketizer.maxDatagramSize,
                    floorNanos: Self.pacingGapFloorNanos,
                    ceilNanos: Self.pacingGapCeilNanos,
                    rateMultiplier: Self.paceRateMultiplier,
                )
                : Self.paceGapNanos
            // ABSOLUTE-DEADLINE schedule (same rationale as VideoSendLane.transmit): a relative
            // sub-ms Task.sleep oversleeps by Darwin's ~1ms quantum and the overshoot accumulates
            // per chunk; deadlines anchored at `start` self-correct and a behind-schedule chunk
            // sends immediately.
            let clock = ContinuousClock()
            let start = clock.now
            var chunk = 0
            var i = 0
            while i < outgoings.count {
                let end = min(i + Self.paceChunkFragments, outgoings.count)
                var j = i
                while j < end { transport.send(outgoings[j].bytes, on: outgoings[j].channel)
                    j += 1
                }
                i = end
                chunk += 1
                if i < outgoings.count {
                    let deadline = start + .nanoseconds(Int64(gapNanos) * Int64(chunk))
                    if deadline > clock.now {
                        try? await clock.sleep(until: deadline)
                    }
                    guard stateMachine.mediaFlowing else { return } // a bye/stop teardown raced the gap
                }
            }
        } else {
            for outgoing in outgoings { transport.send(outgoing.bytes, on: outgoing.channel) }
        }
    }

    private func onGeometry(_ message: WindowGeometryMessage) {
        guard stateMachine.mediaFlowing else { return }
        // Keep the cursor + input mapping origin in sync as the window moves — BUT only while the capture
        // is at the plain window frame. While DIALOG-EXPAND has the region expanded to window∪dialog
        // (captureRegionGlobal != nil), the mapping origin is owned by applyCaptureRegion (it maps against
        // the union); re-origining to the plain window frame here would desync input/cursor from the still-
        // union-sized stream (clicks/cursor in the dialog area map to the wrong absolute point). The union
        // poll (onAssociatedUnion → applyCaptureRegion) re-applies the correct mapping as things move.
        if let bounds = boundsFromGeometry(message) {
            if CaptureRegionMath.shouldReoriginToWindowOnGeometry(activeRegionGlobal: captureRegionGlobal) {
                cursorSampler?.updateWindowBounds(bounds)
                injector?.updateWindowBounds(bounds)
            }
            // Display-anchored capture crops at a fixed display-local rect — re-anchor it to the
            // moved window (no-op in `.window` mode). Unstructured on purpose: the SCStream config
            // update must not block the geometry fan-out; the capturer no-ops if torn down.
            if let capturer {
                let frameCG = CGRect(
                    x: bounds.origin.x,
                    y: bounds.origin.y,
                    width: bounds.size.width,
                    height: bounds.size.height,
                )
                Task { await capturer.updateDisplayAnchoredOrigin(windowFrameCG: frameCG) }
            }
        }
        transport.send(scheduler.scheduleGeometry(message).bytes, on: .geometry)
    }

    /// DIALOG-EXPAND: the geometry watcher detected the capture-region union (window ∪ attached
    /// dialog) change. Decide whether to retarget the capture region: expand when a dialog overhangs
    /// the window, contract back to the window frame when it closes. Each transition is an encoder
    /// rebuild + IDR, so it is hysteresis-gated (the watcher only fires past `shouldRetarget`, and we
    /// re-check vs the LIVE region here — the watcher's baseline can lag a rebuild).
    private func onAssociatedUnion(_ unionGlobal: CGRect, contentRectsGlobal: [CGRect]) async {
        guard dialogExpandArmed, stateMachine.mediaFlowing, !captureRegionRebuilding else { return }
        let windowFrame = currentWindowBoundsCG().cgRect
        // The "natural" region is the window frame; a union strictly larger than it (a dialog
        // overhangs) expands, otherwise we want the plain window frame back.
        let desired = unionGlobal.contains(windowFrame) && unionGlobal != windowFrame ? unionGlobal : windowFrame
        let current = captureRegionGlobal ?? windowFrame
        guard CaptureRegionMath.shouldRetarget(current: current, desired: desired) else { return }
        // Contracting back to (approximately) the window frame ⇒ clear the override; else expand.
        let target: CGRect? = CaptureRegionMath
            .shouldRetarget(current: desired, desired: windowFrame) ? desired : nil
        if let target {
            // EXPAND immediately, and cancel any pending contract (a popup re-opened inside the
            // debounce window — no need to shrink-then-grow).
            pendingContractTask?.cancel()
            pendingContractTask = nil
            await applyCaptureRegion(target, contentRectsGlobal: contentRectsGlobal)
        } else {
            // CONTRACT, debounced (~400 ms): a quick menu open→pick→close would otherwise rebuild
            // the encoder twice (expand + contract = double flicker). Holding the expanded region a
            // beat lets a re-open reuse it; a genuine close applies after the quiet window.
            scheduleContract()
        }
    }

    /// Debounced contract back to the plain window frame (see ``onAssociatedUnion``). The watcher
    /// keeps polling, so if the region is still contracted after the quiet window we apply it; a new
    /// expand cancels the pending task.
    private func scheduleContract() {
        pendingContractTask?.cancel()
        pendingContractTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            await applyCaptureRegion(nil, contentRectsGlobal: [])
        }
    }

    /// DIALOG-EXPAND rebuild: re-point the capture at `regionGlobal` (nil ⇒ the plain window frame)
    /// WITHOUT AX-resizing the window. Mirrors ``applyResize`` steps b–d (build new encoder, swap the
    /// capturer with a region override, ack) but skips the AX window resize (step a) — the window is
    /// untouched; only the captured RECT and the input/cursor mapping origin move. The client adopts
    /// the new size frame-gated and grows the pane for free (see the resize-path ack contract).
    private func applyCaptureRegion(_ regionGlobal: CGRect?, contentRectsGlobal: [CGRect]) async {
        guard stateMachine.mediaFlowing, let oldCapturer = capturer, let oldEncoder = encoder,
              !captureRegionRebuilding else { return }
        captureRegionRebuilding = true
        defer { captureRegionRebuilding = false }

        // Resolve the target region: explicit union, or the live window frame for a contract.
        let windowFrame = currentWindowBoundsCG().cgRect
        let region = regionGlobal ?? windowFrame
        // Display under the region centre (the VD); needed for the display-local sourceRect.
        var did = CGDirectDisplayID(0)
        var count: UInt32 = 0
        let center = CGPoint(x: region.midX, y: region.midY)
        guard CGGetDisplaysWithPoint(center, 1, &did, &count) == .success, count > 0 else {
            dbg("dialog-expand: no display under region centre — skipped")
            return
        }
        let db = CGDisplayBounds(did)
        let override: WindowCapturer.CaptureRegionOverride? = regionGlobal.map {
            WindowCapturer.CaptureRegionOverride(
                displayID: did,
                displayLocalRect: CGRect(
                    x: $0.minX - db.minX,
                    y: $0.minY - db.minY,
                    width: $0.width,
                    height: $0.height,
                ),
                globalRect: $0,
            )
        }
        let pointW = max(1, Int(region.width.rounded())), pointH = max(1, Int(region.height.rounded()))
        let pixelWidth = max(1, Int((Double(pointW) * captureScale).rounded()))
        let pixelHeight = max(1, Int((Double(pointH) * captureScale).rounded()))
        captureRegionEpoch &+= 1
        let epoch = captureRegionEpoch

        // b. New encoder at the region pixel size (abort cleanly on failure — keep the old one).
        let ceiling = LiveBitratePolicy.targetBitrate(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fps: fps,
            floor: bitrate,
        )
        let newEncoder = VideoEncoder(
            width: pixelWidth,
            height: pixelHeight,
            bitrate: ceiling,
            fps: fps,
            fullRange: Self.fullRange,
            ltrEnabled: Self.ltrEnabled,
            outputHandler: makeEncoderOutputHandler(),
        )
        do { try newEncoder.createLiveSession() } catch {
            log.error("dialog-expand encoder create failed: \(String(describing: error)) — keeping old")
            return
        }
        // c. New capturer bound to the new encoder, with the region override.
        let logCallback = log
        let newCapturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: true, // low-latency default (see WindowCapturer.preferDisplayAnchored)
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP in
            do {
                if ltrRefresh { try newEncoder.encodeLiveLTRRefresh(pixelBuffer: pixelBuffer, presentationTime: pts) }
                else if crisp { try newEncoder.encodeLiveCrispKeyframe(
                    pixelBuffer: pixelBuffer,
                    presentationTime: pts,
                )
                } else if compact { try newEncoder.encodeCompactKeyframe(
                    pixelBuffer: pixelBuffer,
                    presentationTime: pts,
                )
                } else { try newEncoder.encodeLive(
                    pixelBuffer: pixelBuffer,
                    presentationTime: pts,
                    forceKeyframe: forceKeyframe,
                    perFrameMaxQP: perFrameMaxQP,
                ) }
            } catch { logCallback.error("dialog-expand encode failed: \(String(describing: error))") }
        }
        await oldCapturer.stop()
        oldEncoder.completeFrames()
        // Supersede guard (mirrors applyResize's pre-install guard): a bye/stop/resize raced our suspension.
        guard stateMachine.mediaFlowing, capturer === oldCapturer, encoder === oldEncoder else {
            dbg("dialog-expand: superseded during oldCapturer.stop — aborting install")
            return
        }
        encoder = newEncoder
        seedCongestionController(ceiling: ceiling)
        resetLTRForNewEncoder()
        capturer = newCapturer
        if effectiveStreamFps != fps {
            newCapturer.setGovernedFPS(effectiveStreamFps)
            newEncoder.setExpectedFrameRate(effectiveStreamFps)
        }
        // Re-origin the input + cursor mapping to the captured region so a click in the dialog area
        // (which may sit left/above the window) maps to the correct GLOBAL point. Contracting back
        // to the window frame restores the window-origin mapping. (CursorSampler `visible` also keys
        // off this rect's size, so the cursor stays reported while over the dialog.)
        let mapRect = VideoRect(x: region.minX, y: region.minY, width: region.width, height: region.height)
        injector?.updateWindowBounds(mapRect)
        cursorSampler?.updateWindowBounds(mapRect)
        captureRegionGlobal = regionGlobal
        // Dialog-expand is a WINDOW-session path (armed only when VD-parked) — defensive unwrap.
        guard let captureWindow = window else { return }
        do {
            nonisolated(unsafe) let w = captureWindow
            try await newCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight, region: override)
            dbg(
                "dialog-expand: capture region \(regionGlobal == nil ? "→ window frame" : "→ union") \(pointW)x\(pointH)pt (\(pixelWidth)x\(pixelHeight)px) epoch=\(epoch)",
            )
        } catch {
            // The OLD capturer is already stopped and the union start threw. Simply nil'ing the refs
            // here would leave the session `.streaming` with NO capturer and NO recovery — a silent
            // forever-freeze (contrast applyResize's rollBackWindow + restartOldSizeCapture). Walk the
            // recovery ladder instead (pure: `CaptureRegionFailureRecovery`): rebuild the PLAIN
            // window-frame capturer so the stream degrades to the un-expanded window; if even that
            // fails, bye + stop (a visible disconnect beats a silent freeze).
            log
                .error(
                    "dialog-expand capturer start failed: \(String(describing: error)) — degrading to plain window capture",
                )
            await recoverPlainWindowCapture(deadCapturer: newCapturer, deadEncoder: newEncoder)
            return
        }
        guard capturer === newCapturer else {
            dbg("dialog-expand: superseded during start — tearing down orphan")
            await newCapturer.stop()
            return
        }
        await apply(.sendControl(.resizeAck(
            captureWidth: UInt16(min(Double(UInt16.max), Double(pointW))),
            captureHeight: UInt16(min(Double(UInt16.max), Double(pointH))),
            epoch: epoch,
        )))
        // TRANSPARENCY MASK: tell the client which capture-PIXEL rects are real content (window +
        // popups) so it masks the black flank beside a narrow popup. A contract (regionGlobal nil)
        // sends an EMPTY mask to clear it (the window-frame capture is fully opaque). Sent ×2 ~25 ms
        // apart for loss tolerance (UDP control; the client's application is idempotent — last wins).
        let maskRects = regionGlobal == nil
            ? []
            : Self.maskRects(
                contentRectsGlobal: contentRectsGlobal,
                region: region,
                captureScale: captureScale,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
            )
        await apply(.sendControl(.contentMask(maskRects)))
        let maskMessage = VideoControlMessage.contentMask(maskRects).encode()
        Task { // dup ~25 ms later (mirrors cursor-shape/cadence loss-tolerant resend)
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard stateMachine.mediaFlowing, captureRegionGlobal == regionGlobal else { return }
            transport.send(maskMessage, on: .control)
        }
    }

    /// Rung 2 of the `CaptureRegionFailureRecovery` ladder: the DIALOG-EXPAND rebuild stopped the old
    /// capturer and the union-region `start()` threw, leaving the installed `deadCapturer`/`deadEncoder`
    /// refs pointing at a stream that never came up. Rebuild a PLAIN window-frame capturer (the same
    /// wiring as ``applyCaptureRegion``'s contract path, no region override) so frames RESUME at the
    /// un-expanded window; on any further failure escalate to ``disconnectAfterCaptureRebuildFailure()``.
    /// Mirrors ``restartOldSizeCapture`` (the resize path's recovery), including its post-suspension
    /// supersede guards.
    private func recoverPlainWindowCapture(deadCapturer: WindowCapturer, deadEncoder: VideoEncoder) async {
        switch CaptureRegionFailureRecovery.action(
            mediaFlowing: stateMachine.mediaFlowing,
            superseded: !(capturer === deadCapturer && encoder === deadEncoder),
            isFallbackRebuild: false,
        ) {
        case .abandon:
            dbg("dialog-expand recovery: superseded/torn-down — skip (a newer owner or a teardown owns cleanup)")
            return
        case .disconnect: // not the first rung's outcome; defensive
            await disconnectAfterCaptureRebuildFailure()
            return
        case .rebuildPlainWindow:
            break
        }
        // Drop the dead refs the failed region rebuild left installed before rebuilding.
        capturer = nil
        encoder = nil
        let windowFrame = currentWindowBoundsCG().cgRect
        let pointW = max(1, Int(windowFrame.width.rounded())), pointH = max(1, Int(windowFrame.height.rounded()))
        let pixelWidth = max(1, Int((Double(pointW) * captureScale).rounded()))
        let pixelHeight = max(1, Int((Double(pointH) * captureScale).rounded()))
        captureRegionEpoch &+= 1
        let epoch = captureRegionEpoch
        let ceiling = LiveBitratePolicy.targetBitrate(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fps: fps,
            floor: bitrate,
        )
        let fallbackEncoder = VideoEncoder(
            width: pixelWidth,
            height: pixelHeight,
            bitrate: ceiling,
            fps: fps,
            fullRange: Self.fullRange,
            ltrEnabled: Self.ltrEnabled,
            outputHandler: makeEncoderOutputHandler(),
        )
        do { try fallbackEncoder.createLiveSession() } catch {
            log.error("dialog-expand recovery: encoder rebuild failed: \(String(describing: error))")
            await disconnectAfterCaptureRebuildFailure()
            return
        }
        let logCallback = log
        let fallbackCapturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: true, // low-latency default (see WindowCapturer.preferDisplayAnchored)
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh, perFrameMaxQP in
            do {
                if ltrRefresh {
                    try fallbackEncoder.encodeLiveLTRRefresh(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if crisp {
                    try fallbackEncoder.encodeLiveCrispKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if compact {
                    try fallbackEncoder.encodeCompactKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else {
                    try fallbackEncoder.encodeLive(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts,
                        forceKeyframe: forceKeyframe,
                        perFrameMaxQP: perFrameMaxQP,
                    )
                }
            } catch { logCallback.error("live encode (dialog-expand recovery) failed: \(String(describing: error))") }
        }
        encoder = fallbackEncoder
        seedCongestionController(ceiling: ceiling)
        resetLTRForNewEncoder()
        capturer = fallbackCapturer
        if effectiveStreamFps != fps {
            fallbackCapturer.setGovernedFPS(effectiveStreamFps)
            fallbackEncoder.setExpectedFrameRate(effectiveStreamFps)
        }
        // Back to the WINDOW-origin input/cursor mapping (the union region — and its off-window
        // origin — is gone with the failed capturer).
        let mapRect = VideoRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: windowFrame.height,
        )
        injector?.updateWindowBounds(mapRect)
        cursorSampler?.updateWindowBounds(mapRect)
        captureRegionGlobal = nil
        // Dialog-expand recovery is a WINDOW-session path (armed only when VD-parked) — defensive unwrap.
        guard let captureWindow = window else { return }
        do {
            nonisolated(unsafe) let w = captureWindow
            try await fallbackCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg("dialog-expand recovery: degraded to plain window capture \(pointW)x\(pointH)pt epoch=\(epoch)")
        } catch {
            log.error("dialog-expand recovery: plain window capturer start failed: \(String(describing: error))")
            let superseded = !(capturer === fallbackCapturer && encoder === fallbackEncoder)
            if !superseded {
                capturer = nil
                encoder = nil
            }
            // Last rung: even the plain-window fallback failed — disconnect (unless a newer owner /
            // teardown took over across the start suspension, which then owns the session's fate).
            if CaptureRegionFailureRecovery.action(
                mediaFlowing: stateMachine.mediaFlowing,
                superseded: superseded,
                isFallbackRebuild: true,
            ) == .disconnect {
                await disconnectAfterCaptureRebuildFailure()
            }
            return
        }
        // Identity guard (symmetric to applyCaptureRegion): a superseding teardown/start during
        // `start` means our refs are no longer installed — tear down the orphan stream, no ack.
        guard capturer === fallbackCapturer else {
            dbg("dialog-expand recovery: superseded during start — tearing down orphan")
            await fallbackCapturer.stop()
            return
        }
        // Ack the degraded (window-frame) size — the client adopts it frame-gated — and CLEAR any
        // transparency mask left over from a previously-applied union region.
        await apply(.sendControl(.resizeAck(
            captureWidth: UInt16(min(Double(UInt16.max), Double(pointW))),
            captureHeight: UInt16(min(Double(UInt16.max), Double(pointH))),
            epoch: epoch,
        )))
        await apply(.sendControl(.contentMask([])))
    }

    /// Last rung: no capturer can be brought up — a `.streaming` session with dead capture would freeze
    /// the client's pane forever with no signal. Send a host→client `.bye` (twice —
    /// it is a single unacked UDP datagram) so the client's existing disconnect/reconnect UI
    /// engages, then stop the session; `stop()`'s `transport.stop()` retires the lane, which also
    /// unparks/restores the window through the daemon's retire hook.
    private func disconnectAfterCaptureRebuildFailure() async {
        log
            .error(
                "capture rebuild unrecoverable — sending bye + stopping session (visible disconnect beats silent freeze)",
            )
        await apply(.sendControl(.bye))
        await apply(.sendControl(.bye))
        await stop()
    }

    /// CAPTURE-DEATH: the live capturer's SCStream died out from under the session
    /// (`didStopWithError` — window closed, display unplugged, TCC revoked, WindowServer/GPU reset).
    /// The capturer already quiesced its synthetic-frame machinery (IDR timer cancelled, cached frame
    /// dropped), but the session is still `.streaming`: the 1 s host heartbeat keeps the client's stall
    /// scrim disarmed, so without this teardown the pane freezes PERMANENTLY and silently on the last
    /// decoded frame (and every recovery request just re-encodes that stale frame). Reuse the last-rung
    /// teardown — `.bye` (twice, unacked UDP) + `stop()` — so the client's disconnect/reconnect UI
    /// engages. Once-only: the teardown flips `mediaFlowing` false, so a second callback (or a racing
    /// deliberate stop) is gated out by the pure decision below.
    private func onCaptureDied(_ failed: WindowCapturer) async {
        guard Self.shouldDisconnectOnCaptureFailure(
            mediaFlowing: stateMachine.mediaFlowing,
            failedIsCurrent: failed === capturer,
        ) else {
            dbg("capture death ignored (session already torn down, or a superseded capturer died)")
            return
        }
        log.error("SCStream capture died — sending bye + stopping session (visible disconnect beats silent freeze)")
        await disconnectAfterCaptureRebuildFailure()
    }

    /// PURE decision for ``onCaptureDied`` (headlessly unit-tested — the session actor itself
    /// needs a real `SCWindow`; the `CaptureRegionFailureRecovery` pattern): tear down ONLY when
    /// the session still believes media is flowing AND the dead capturer is the CURRENTLY
    /// installed one. `mediaFlowing == false` ⇒ a deliberate stop/bye teardown already ran
    /// (double-teardown guard); `failedIsCurrent == false` ⇒ a resize/region rebuild superseded
    /// the dead instance across a suspension point (a newer owner owns the session's fate).
    static func shouldDisconnectOnCaptureFailure(mediaFlowing: Bool, failedIsCurrent: Bool) -> Bool {
        mediaFlowing && failedIsCurrent
    }

    /// Converts the GLOBAL opaque content rects (window + popups) into capture-local PIXEL
    /// ``MaskRect``s for the client's transparency mask: subtract the captured region origin, scale
    /// by `captureScale`, clamp to the frame. A rect that clamps to empty (fully outside) is dropped.
    /// `internal` (not `private`) so the pure conversion is unit-tested without a live session.
    static func maskRects(
        contentRectsGlobal: [CGRect],
        region: CGRect,
        captureScale: Double,
        pixelWidth: Int,
        pixelHeight: Int,
    ) -> [MaskRect] {
        let maxW = Double(pixelWidth), maxH = Double(pixelHeight)
        var out: [MaskRect] = []
        for r in contentRectsGlobal {
            let x0 = ((r.minX - region.minX) * captureScale).rounded()
            let y0 = ((r.minY - region.minY) * captureScale).rounded()
            let x1 = ((r.maxX - region.minX) * captureScale).rounded()
            let y1 = ((r.maxY - region.minY) * captureScale).rounded()
            let cx0 = min(max(0, x0), maxW), cy0 = min(max(0, y0), maxH)
            let cx1 = min(max(0, x1), maxW), cy1 = min(max(0, y1), maxH)
            let w = cx1 - cx0, h = cy1 - cy0
            guard w > 0, h > 0 else { continue }
            out.append(MaskRect(
                x: UInt16(min(Double(UInt16.max), cx0)),
                y: UInt16(min(Double(UInt16.max), cy0)),
                width: UInt16(min(Double(UInt16.max), w)),
                height: UInt16(min(Double(UInt16.max), h)),
            ))
        }
        return out
    }

    private func onCursorUpdate(_ update: CursorUpdate) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(scheduler.scheduleCursor(.update(update)).bytes, on: .cursor)
    }

    /// A new cursor SHAPE bitmap to ship out-of-band (once per shapeID; the sampler
    /// owns the dedup). Sent on the cursor socket as a ``CursorShapeMessage``.
    ///
    /// SHAPE LAG: sent TWICE, ~25 ms apart. The shipment is one-shot per shapeID — if its single
    /// datagram is lost the client shows the wrong pointer until the re-request debounce fires, which
    /// reads exactly like "cursor shape changes slower than Parsec". A shape change often coincides
    /// with video motion (the lossiest moment), so cheap time-separated repetition (≤ ~1.2 KB, a few
    /// dozen per session) closes that window; the client's shape registration is idempotent per
    /// shapeID, so the duplicate is harmless.
    /// Daemon push (`SwipeNavStatusKicker`): ships the current swipe-nav status over the cursor
    /// socket so the client's peel-feedback mirror knows whether a swipe would translate and
    /// which thresholds the host operates on (doc 05 §8). A WINDOW session's eligibility is its
    /// own target app AND that app being frontmost (``SwipeNavHostConfig/eligibleWindowTarget``):
    /// the chord posts at the HID tap — it lands in the OS key-focus holder — so the fire path
    /// gates on live focus (``InputInjector/fireSwipeNav`` suppresses + raises on a mismatch),
    /// and the chip must mirror that gate or it promises fires the host swallows. A DISPLAY
    /// session follows the frontmost app, exactly mirroring the fire-time check. `history` is
    /// the kicker's AX Back/Forward read of the frontmost app (nil = unknown ⇒ client fails
    /// open) — it gates only the chip, never the fire (doc 20 §9.6). Fire-and-forget: the
    /// kicker re-pushes on every frontmost activation, on every history/eligibility CHANGE
    /// (~250 ms poll), plus a ~2 s heartbeat, so a lost datagram self-heals and the window-pane
    /// eligibility is at most one beat stale.
    public func pushSwipeNavStatus(frontmostBundleID: String?, history: NavHistoryFlags?) {
        guard stateMachine.mediaFlowing else { return }
        let status: SwipeNavStatusMessage =
            if let pid = window?.owningApplication?.processID, pid > 0 {
                SwipeNavHostConfig.windowStatus(
                    // Thread-safe AppKit read, same as InputInjector's off-main usage.
                    paneBundleID: NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier,
                    frontmostBundleID: frontmostBundleID,
                    history: history,
                )
            } else {
                SwipeNavHostConfig.status(bundleID: frontmostBundleID, history: history)
            }
        transport.send(scheduler.scheduleCursor(.swipeNavStatus(status)).bytes, on: .cursor)
    }

    private func onCursorShape(_ shape: CursorShapeMessage) {
        guard stateMachine.mediaFlowing else { return }
        let bytes = scheduler.scheduleCursor(.shape(shape)).bytes
        transport.send(bytes, on: .cursor)
        Task { // inherits this actor's isolation; re-checks liveness after each gap so a
            // bye/stop teardown racing the delay aborts cleanly. THREE time-separated copies (0/25/50ms)
            // so a burst loss during video motion (the lossiest moment, and exactly when the shape often
            // changes) is very unlikely to drop all of them — the client's shape registration is
            // idempotent per shapeID, so the duplicates are harmless.
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard stateMachine.mediaFlowing else { return }
                transport.send(bytes, on: .cursor)
            }
        }
    }

    // MARK: Helpers

    private func currentWindowBoundsCG() -> VideoRect {
        // Live bounds via the watcher if present, else the target's creation frame (a display's
        // CG bounds are fixed — no watcher exists for a full-desktop session).
        if let live = geometryWatcher?.currentBoundsCG() { return live }
        if let window { return VideoRect(window.frame) }
        if let display { return VideoRect(CGDisplayBounds(display.displayID)) }
        return VideoRect(x: 0, y: 0, width: 0, height: 0)
    }

    private func boundsFromGeometry(_ message: WindowGeometryMessage) -> VideoRect? {
        switch message {
        case let .bounds(r): r
        case .move,
             .resize,
             .title: geometryWatcher?.currentBoundsCG()
        }
    }
}

/// Lock-protected FIFO of inbound datagrams feeding the host's coalescing consumer. The
/// transport's serial receive queue APPENDS (synchronously, no actor hop — so arrival order is
/// carried end-to-end); the single consumer task DRAINS the whole backlog per wakeup so the
/// actor can collapse pointer-motion runs (``InputMotionCoalescer``). An `AsyncStream` of
/// datagrams instead forces a strictly-serial per-event drain (three WindowServer round-trips per
/// motion event), which lets a motion flood accrue multi-second lag.
private final class InboundQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(VideoChannel, Data)] = []

    /// Append one datagram. Called on the transport's serial receive queue; O(1), never blocks.
    func append(_ channel: VideoChannel, _ data: Data) {
        lock.lock()
        items.append((channel, data))
        lock.unlock()
    }

    /// Atomically take and clear the whole backlog (arrival order). An empty result means a
    /// coalesced wakeup whose datagrams an earlier drain already consumed.
    func drainAll() -> [(VideoChannel, Data)] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}

/// Lock-protected FIFO of ENCODED frames feeding the host's single ordered consumer. The encoder's
/// VT output callback fires in STRICT encode order on a serial queue and APPENDS here synchronously
/// (no actor hop — so encode order is carried end-to-end); the single consumer task drains the
/// backlog IN ORDER and awaits `onEncodedFrame` one at a time, so the packetize lane assigns
/// frameID/streamSeq in encode order. A `Task`-per-frame fan-out gives no FIFO guarantee across
/// separately-created Tasks targeting the actor (frame N+1 could be processed before frame N → a
/// delta packetized before its IDR).
final class EncodedFrameQueue: @unchecked Sendable {
    /// One encoded frame: the AVCC bytes + keyframe/crisp flags the packetizer needs, plus the
    /// LTR ack token (non-nil only when this is a Long-Term-Reference frame and SLOPDESK_LTR is on).
    struct Frame {
        let avcc: Data
        let keyframe: Bool
        let crisp: Bool
        let ltrToken: Int64?
        /// Bit-7 wire marker: this frame was a `ForceLTRRefresh` product (references only
        /// client-acked LTRs) — the decode gate's non-keyframe re-anchor admission.
        let ackedAnchored: Bool
    }

    private let lock = NSLock()
    private var items: [Frame] = []

    init() {}

    /// Append one encoded frame. Called on the VT serial output queue; O(1), never blocks.
    func append(_ frame: Frame) {
        lock.lock()
        items.append(frame)
        lock.unlock()
    }

    /// Atomically take and clear the whole backlog (encode order preserved). An empty result means
    /// a coalesced wakeup whose frames an earlier drain already consumed.
    func drainAll() -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        let out = items
        items = []
        return out
    }
}

/// APP-AUDIO encode→send lane (channel tag 6). ONE per session, shared by every capturer the
/// session installs, so the wire `seq` stays monotonic across resize/dialog-expand rebuilds (the
/// packetize lane's frameID discipline for audio).
///
/// Threading: ``handle(_:)`` runs on the capturer's dedicated audio sample-handler queue — the
/// session ACTOR never encodes (it only flips the gate, a Bool set). One lock guards the whole
/// pipeline: two capturers can briefly overlap around a rebuild, and encoder/seq/config-cadence
/// must stay consistent across that. The encode of one ~10 ms buffer holds the lock far under a
/// buffer interval; a disabled buffer releases it immediately (gate before any work).
///
/// Datagrams go out IMMEDIATE (`transport.send`, thread-safe fire-and-forget UDP) — NEVER through
/// `VideoSendLane`/`sendPaced`: audio must not queue behind a fat video frame, and at ≤ ~2 KB a
/// datagram needs no chunking (the cursor-channel discipline, sharing the media socket).
final class AudioStreamSender: @unchecked Sendable {
    /// Wire codec pick: `SLOPDESK_AUDIO_CODEC=pcm` selects raw s16le (the codec-free A/B arm);
    /// default AAC-ELD.
    static let wireFormat: AudioWireFormat =
        ProcessInfo.processInfo.environment["SLOPDESK_AUDIO_CODEC"] == "pcm" ? .pcmS16LE : .aacEld
    /// AAC-ELD target bitrate (`SLOPDESK_AUDIO_BITRATE`, clamp 32k…320k, default 128k). The PCM
    /// arm ignores it.
    static let bitrateBps: Int = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_AUDIO_BITRATE"], let v = Int(s) {
            return min(320_000, max(32000, v))
        }
        return 128_000
    }()

    /// Config re-send cadence (seconds): UDP may drop any single copy and a client may lock on
    /// late, so the config is re-asserted ~1 s apart — piggybacked on the encode path (a stamp
    /// compare per buffer), no dedicated timer. Client re-application is idempotent.
    private static let configResendInterval: TimeInterval = 1.0

    private let lock = NSLock()
    /// The send gate: true only while the session is STREAMING and the client's `audioControl`
    /// wish is ON (the actor maintains both transitions), so a buffer that races a teardown is
    /// dropped here — "streaming AND enabled" is the lane's send contract.
    private var enabled = false
    /// Built lazily at the FIRST enabled buffer, so a session whose client never turns audio on
    /// never constructs an AudioConverter.
    private var encoder: AudioStreamEncoder?
    /// ONE monotonic counter for ALL tag-6 datagrams of this session (config + frames share it —
    /// the client orders/late-drops on it). Wraps via `&+` like every wire counter.
    private var seq: UInt32 = 0
    /// Monotonic uptime of the last config send; −∞ ⇒ send one before the next frame (reset on
    /// every OFF→ON transition so a (re-)enable always leads with a fresh config).
    private var lastConfigSentUptime = -Double.infinity

    private let transport: any VideoDatagramTransport
    /// The session's monotonic epoch — `hostSendTsMillis` shares `FrameFragmentHeader`'s clock
    /// contract (host-relative ms, never cross-clock).
    private let sessionStartUptime: Double

    init(transport: any VideoDatagramTransport, sessionStartUptime: Double) {
        self.transport = transport
        self.sessionStartUptime = sessionStartUptime
    }

    var isEnabled: Bool { lock.withLock { enabled } }

    /// Actor-driven gate flip (`.applyAudioControl` / `.startCapture` reset / teardown). Cheap by
    /// contract: the actor must never wait on an encode — worst case it waits out one in-flight
    /// ~10 ms buffer's encode (well under a frame interval), and only on a rare user-driven toggle.
    func setEnabled(_ on: Bool) {
        lock.withLock {
            if on, !enabled {
                lastConfigSentUptime = -.infinity
                // The sub-frame remainder left by the last pre-disable buffer is stale by now —
                // starting clean keeps the first fresh frame free of an old-audio shard. The
                // converter's own internal codec state (bit reservoir / window history) is just as
                // stale after an arbitrarily long disable window — reset both together so the first
                // post-resume frame is a clean encoder start, not a continuation of audio from long
                // before the gap.
                encoder?.resetAccumulator()
                encoder?.resetConverterState()
            }
            enabled = on
        }
    }

    /// The capturer's `.audio` sink: extract→encode→packetize→send. Runs on the capturer's audio
    /// queue; everything but the actual `transport.send` happens under the lane lock.
    func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        if encoder == nil {
            encoder = AudioStreamEncoder(format: Self.wireFormat, bitrateBps: Self.bitrateBps)
        }
        guard let encoder else {
            lock.unlock()
            return
        }
        let payloads = encoder.encode(sampleBuffer: sampleBuffer)
        // `config` is non-nil once the encoder can produce (PCM: always; AAC: converter built) —
        // and payloads imply it. No completed frame ⇒ nothing to announce or send yet.
        guard !payloads.isEmpty, let config = encoder.config else {
            lock.unlock()
            return
        }
        var datagrams: [Data] = []
        let now = ProcessInfo.processInfo.systemUptime
        let ts = UInt32(truncatingIfNeeded: Int64((now - sessionStartUptime) * 1000))
        if now - lastConfigSentUptime >= Self.configResendInterval {
            lastConfigSentUptime = now
            datagrams.append(AudioChannelMessage.config(seq: seq, hostSendTsMillis: ts, config: config).encode())
            seq &+= 1
        }
        for payload in payloads {
            datagrams.append(AudioChannelMessage.frame(seq: seq, hostSendTsMillis: ts, payload: payload).encode())
            seq &+= 1
        }
        lock.unlock()
        // Send OUTSIDE the lock: fire-and-forget UDP enqueue, and a racing gate flip must never
        // wait behind socket work.
        for datagram in datagrams { transport.send(datagram, on: .audio) }
    }
}
#endif
