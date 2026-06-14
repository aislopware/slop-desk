#if os(macOS)
import AislopdeskVideoProtocol
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// The host-side session orchestrator for the GUI video path (PATH 2 / Phase 4).
///
/// This is the driver that wires the previously-disconnected islands into a working
/// pipeline:
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
public actor AislopdeskVideoHostSession {
    private let log = Logger(subsystem: "aislopdesk.video.host", category: "AislopdeskVideoHostSession")

    /// Opt-in stderr diagnostics (set `AISLOPDESK_VIDEO_DEBUG=1`). OSLog `.info`/`.debug` are not
    /// persisted, so a headless verify (`scripts/check-video.sh`) cannot read the capture/encode
    /// flow from `log show`. When enabled, the key lifecycle beats are mirrored to stderr so the
    /// gate can pinpoint where (if anywhere) the pipeline stalls. No-op in production.
    private static let debugStderr = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil
    /// Burst-resilient transmission interleaving (2026-06-08 flicker fix). DEFAULT ON; `AISLOPDESK_INTERLEAVE=0`
    /// reverts to the plain consecutive send order. The white/blank stream once seen on first enable was
    /// HW-investigated (2026-06-09) and is GONE on the current codebase — proven two ways: (1) the headless
    /// `aislopdesk-loopback-validate` harness runs synthetic→REAL HW HEVC encode→packetize→interleave→reassemble
    /// →REAL HW decode and reports 120/120 clean at no-loss AND full FEC recovery of a 2- and 3-adjacent
    /// datagram burst that the plain order drops entirely (0/120); (2) the live GUI loopback (capture→encode
    /// →UDP→decode→Metal) with `AISLOPDESK_INTERLEAVE=1` rendered the remote window crisply with zero decode
    /// failures. The original symptom was a live-only artifact since fixed incidentally by the header rewrite
    /// + reassembler dataCount-inversion. Reorder is a pure send-order permutation (header/`fragIndex`
    /// untouched, reassembler reorder-tolerant) → no wire change. The pure ``FragmentInterleaver`` (+ tests)
    /// and the harness interleave scenarios stand as regression proof.
    private static let interleaveTransmit = ProcessInfo.processInfo.environment["AISLOPDESK_INTERLEAVE"] != "0"
    /// SEND PACING (2026-06-08 flicker fix, the SAFE one — no reorder, no wire change). A large frame
    /// (a ~115 KB heartbeat IDR ≈ 97 datagrams, or a big scroll delta) sent as ONE instant burst
    /// overflows the client UDP receive buffer / WireGuard tunnel → consecutive packet loss → the
    /// single-loss XOR FEC cannot recover → a corrupt frame the next one only half-fixes → FLICKER.
    /// Pacing splits a large frame's datagrams into small chunks separated by a sub-ms gap so the
    /// receiver drains them as they arrive (no burst overflow); tiny frames (the static-window common
    /// case, ~1 datagram) still send instantly.
    ///
    /// DEFAULT **ON** since 2026-06-10 (`AISLOPDESK_PACE=0` disables). HISTORY: the 2026-06-09 latency
    /// workflow turned pacing OFF after measuring "pure latency harm on a non-lossy link" — but
    /// that verdict was for EXACT-rate pacing (k=1: a heavy frame serialized over 30-130ms,
    /// backlogging the consumer). 2026-06-10 HW (testufo stars-hdr, 40Mbps, Wi-Fi client): the
    /// un-paced path blasts a 133KB frame as ~110 back-to-back datagrams → measured 2-13% burst
    /// loss windows → FEC misses → recovery IDRs + ABR sawtooth 40→20→40Mbps = the periodic
    /// "khựng". The fix is pacing at a MULTIPLE of the live rate (``paceRateMultiplier``): bursts
    /// are capped at k× the link's sustained rate while the heaviest frame still drains in ~10ms
    /// (≲ a frame interval), so the consumer never falls behind. Frames ≤ ``paceChunkFragments``
    /// datagrams still send in one shot (input-feedback latency unaffected).
    private static let paceSend = ProcessInfo.processInfo.environment["AISLOPDESK_PACE"] != "0"
    /// Frames with at most this many datagrams send in one shot (no pacing) — covers static-window
    /// P-frames and small deltas. Above it, send in chunks of this size with ``paceGapNanos`` between.
    private static let paceChunkFragments = 8
    /// Gap between paced chunks. 0.5 ms × (97/8 ≈ 12 chunks) ≈ 6 ms to drain a heartbeat IDR — well
    /// under the 16 ms frame interval, so the consumer never falls behind. Override µs via `AISLOPDESK_PACE_US`.
    private static let paceGapNanos: UInt64 = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_PACE_US"], let v = UInt64(s), v >= 1,
           v <= 10000 { return v * 1000 }
        return 500_000
    }()

    /// RC-2 (2026-06-09 smoothness): RATE-PROPORTIONAL pacing. The fixed `paceGapNanos` (0.5ms) drains an
    /// 8-fragment (~9600-byte) chunk ~13× FASTER than a 12Mbps link can absorb → a big frame blasts
    /// ~146Mbps into the link → self-inflicted burst loss (measured 10–14% on a real scroll) → ABR
    /// collapse + FEC failure = the blur/khung/flicker chain. When ON (default; `AISLOPDESK_PACE_ADAPTIVE=0`
    /// reverts to the fixed gap), the inter-chunk gap is computed so a chunk drains at ≈ the LIVE ABR
    /// target (`lastActuatedBitrate`): gap = chunkBytes×8 / targetBps. This is aislopdesk's equivalent of
    /// Parsec's window-AIMD-paced send — it never puts more bytes/sec on the wire than the link drains.
    /// An explicit `AISLOPDESK_PACE_US` still pins a static gap (overrides adaptive, for A/B).
    private static let pacingAdaptive: Bool = {
        if ProcessInfo.processInfo.environment["AISLOPDESK_PACE_US"] != nil { return false } // explicit static pin wins
        return ProcessInfo.processInfo.environment["AISLOPDESK_PACE_ADAPTIVE"] != "0"
    }()

    /// Link-rate fallback when the ABR target is not yet known (ABR off / pre-warmup).
    private static let pacingFallbackBps = 12_000_000
    /// Pace at this MULTIPLE of the live ABR target (`AISLOPDESK_PACE_RATE_X`, default 2.5, clamp
    /// 1–10). k=1 (exact rate) serializes a max frame over ~27ms at 40Mbps — longer than the
    /// 16.7ms frame interval, the measured 06-09 "lag grows while you scroll" harm. k=2.5 keeps
    /// the instantaneous burst at 2.5× the sustained rate (gentle on Wi-Fi airtime/WireGuard
    /// queues) while a 133KB worst-case frame drains in ~10ms.
    private static let paceRateMultiplier: Double = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_PACE_RATE_X"], let v = Double(s), v.isFinite {
            return min(10, max(1, v))
        }
        return 2.5
    }()

    /// Clamp the adaptive gap: never faster than 0.2ms (a high ABR target would otherwise ≈0 it), never
    /// slower than 40ms/chunk (a collapsed-to-floor ABR must not serialize a frame into a multi-second stall).
    private static let pacingGapFloorNanos: UInt64 = 200_000
    private static let pacingGapCeilNanos: UInt64 = 40_000_000
    /// LOSS-TOLERANCE #1 (2026-06-10): route paced sends through the dedicated ``VideoSendLane``
    /// instead of awaiting the pacing INSIDE the encoder-output pump. Measured defect: inline pacing
    /// of frame N delayed frames N+1..k → send gaps 28–179ms on the real path (the visible khựng).
    /// DEFAULT ON; `AISLOPDESK_SEND_LANE=0` reverts to the inline `sendPaced` path.
    private static let sendLaneEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_SEND_LANE"] != "0"
    /// LOSS-TOLERANCE #1b: pace KEYFRAMES at no less than this rate. A recovery IDR paced at a
    /// post-backoff ABR rate (collapsed to the floor) serializes over 100s of ms — and IDR delivery
    /// time IS recovery time. Measured (2026-06-10 iperf3): the path carries 30Mbps with the same
    /// ~1% weather loss as 5Mbps, so draining an IDR at ≥12Mbps costs nothing in loss while cutting
    /// the freeze tail. `AISLOPDESK_KF_PACE_FLOOR_BPS` overrides (clamp 1–100 Mbps).
    private static let kfPaceFloorBps: Int = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_KF_PACE_FLOOR_BPS"], let v = Int(s) {
            return min(100_000_000, max(1_000_000, v))
        }
        return 12_000_000
    }()

    /// FPS GOVERNOR (2026-06-11) — regular-cadence content/congestion-adaptive fps, the successor
    /// of the retired `AdaptiveFPSController` (whose alternating skip delivered irregular
    /// 16.7/33.3 ms intervals = the PRIMARY cadence khựng; deleted with `AISLOPDESK_ADAPTIVE_FPS`).
    /// When ON, the host folds encoded-frame sizes into an ``FPSGovernor`` and ticks it on every
    /// NetworkStats report: when the offered load exceeds the actuated bitrate past the QP51
    /// coarsening floor AND there is positive congestion evidence, fps steps DOWN a clean-divisor
    /// ladder rung (60→30→20→15) — actuated by the capturer's schedule-anchored
    /// ``EncodeCadenceGate`` (metronome-regular), a live encoder `ExpectedFrameRate` hint, and a
    /// `streamCadence` control message so the client rebases its pacing. DEFAULT OFF: cadence is
    /// this project's highest-sensitivity axis ("user hand-feel is the only valid metric") — the
    /// established pattern is env-gated OFF → HW feel-test → flip default (ABR/LTR/kfDup all
    /// shipped this way). When OFF the host is byte-identical: no gate, no streamCadence message,
    /// no self-heal rebase. `AISLOPDESK_FPS_GOVERNOR=1` enables; tunables `AISLOPDESK_FPS_GOV_*`.
    private static let fpsGovernorEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_FPS_GOVERNOR"] == "1"

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

    /// KEYFRAME DUPLICATE-SEND (F3 flicker fix, 2026-06-08). Forward redundancy by REPETITION: re-send a
    /// keyframe's datagrams a second time (paced + time-separated) so a large IDR survives a time-correlated
    /// burst loss that the single-loss XOR FEC cannot repair. This is the only host-only, REORDER-FREE way
    /// to add real burst tolerance (the client reassembler dedups by frameID/fragIndex, so duplicates are
    /// harmless and the frame decodes exactly once → NO white-screen risk, unlike the gated-off interleave).
    /// Keyframes ONLY (never deltas). DEFAULT **ON** since 2026-06-10 (LOSS-TOLERANCE #3): the
    /// measured worst-case freeze is a LOST KEYFRAME inside the 500ms recovery-IDR cooldown — the
    /// client shows the last good frame for up to the full window. Duplicating keyframes makes that
    /// require BOTH copies of a fragment lost (weather loss ~1% ⇒ ~1e-4 per fragment), and the
    /// ``VideoSendLane`` means the duplicate no longer sleeps inside the encoder pump. Byte cost is
    /// keyframes only, throttled ≤1 dup per 250ms, on a path measured to carry 30Mbps at the same
    /// loss as 5Mbps. `AISLOPDESK_KF_DUP=0` disables.
    private static let kfDup = ProcessInfo.processInfo.environment["AISLOPDESK_KF_DUP"] != "0"
    /// Throttle so a recovery-IDR burst is not byte-amplified: duplicate at most one keyframe per interval.
    private static let kfDupMinInterval: TimeInterval = 0.25
    /// DELIVERY-KEYED RECOVERY-IDR COOLDOWN (component 2, 2026-06-11). DEFAULT **ON**;
    /// `AISLOPDESK_RECOVERY_IDR_V2=0` restores the legacy sent-keyed 500 ms capturer gate byte-for-byte
    /// (host-side only; the wire fields are unconditional and simply ignored in legacy mode). When ON,
    /// the two IDR-issuing recovery paths (`.forceKeyframe` + the `.refreshLTR`→`.idr` fallback) pass
    /// through ``RecoveryIDRPolicy`` — delivery-keyed cooldown + casualty bypass + token bucket — and
    /// the capturer's F1 `minRecoveryIDRInterval` gate goes inert (0). An LTR refresh is NEVER gated.
    /// Default-ON rationale: the suppression set is strictly narrower-or-provably-correct vs the F1
    /// gate except the grace window (40-250 ms ≪ 500 ms), the sustained IDR rate cap is byte-identical
    /// (2/s), and the wire change ships unconditionally anyway — one env flips back exactly.
    private static let recoveryIDRV2 = ProcessInfo.processInfo.environment["AISLOPDESK_RECOVERY_IDR_V2"] != "0"
    /// Tunables for the V2 policy: `AISLOPDESK_IDR_TOKENS` (bucket capacity, clamp 1...4),
    /// `AISLOPDESK_IDR_REFILL_MS` (ms per token, clamp 100...5000 — default 500 = the old F1 spacing),
    /// `AISLOPDESK_IDR_GRACE_MS` (pins floor=ceil for A/B, clamp 0...1000; unset = adaptive
    /// clamp(0.75×smoothedRTT, 40, 250) ms).
    private static let recoveryIDRConfig: RecoveryIDRPolicy.Config = {
        var config = RecoveryIDRPolicy.Config()
        let env = ProcessInfo.processInfo.environment
        if let s = env["AISLOPDESK_IDR_TOKENS"], let v = Double(s), v.isFinite {
            config.bucketCapacity = min(4, max(1, v))
        }
        if let s = env["AISLOPDESK_IDR_REFILL_MS"], let v = Double(s), v.isFinite {
            config.refillTokensPerSecond = 1000.0 / min(5000, max(100, v))
        }
        if let s = env["AISLOPDESK_IDR_GRACE_MS"], let v = Double(s), v.isFinite {
            let pinned = min(1000, max(0, v)) / 1000.0
            config.graceFloorSeconds = pinned
            config.graceCeilSeconds = pinned
        }
        return config
    }()

    /// NETWORK-FEEDBACK TELEMETRY (the network-feedback channel). DEFAULT ON; disable with
    /// `AISLOPDESK_NETSTATS=0`. When ON, every outgoing video fragment is stamped with the host-relative
    /// send time and the host folds the client's periodic NetworkStats reports into a NetworkEstimate
    /// (MAINTAIN+LOG only — nothing consumes it to change the stream yet). When "0", the host writes a
    /// 0 timestamp → the client observes 0 → reports `latestHostSendTs = 0` → the RTT fold is skipped
    /// (computeRTTMillis returns nil), fully reverting to today's open-loop path. The 4-byte wire field
    /// stays present either way (fixed header layout).
    private static let telemetryEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_NETSTATS"] != "0"
    /// WF-2 ADAPTIVE BITRATE. DEFAULT OFF; enable with `AISLOPDESK_ABR=1`. When ON the host folds each
    /// client NetworkStats report (already done for telemetry) into a ``LiveCongestionController`` and
    /// actuates the resulting target via ``VideoEncoder/setLiveBitrate(_:)``. When OFF the controller
    /// is never seeded/ticked, so `setLiveBitrate` is never called and the live rate stays pinned at
    /// the resolution-aware ceiling — byte-identical to today. Needs telemetry reports to ever tick
    /// (if the client sets `AISLOPDESK_NETSTATS=0` no reports arrive ⇒ the controller never fires ⇒ inert).
    /// DEFAULT **ON** since 2026-06-11 (defaults consolidation): with LOSS-TOLERANCE #4 the
    /// controller is weather-proof (holds the rate on uncorroborated loss, backs off only on
    /// queue evidence or sustained collapse), so the closed loop is pure upside — on a clean
    /// LAN/loopback it is inert at the ceiling. `AISLOPDESK_ABR=0` reverts to open-loop.
    private static let abrEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_ABR"] != "0"
    /// WF-4 ADAPTIVE FEC. DEFAULT OFF; enable with `AISLOPDESK_ADAPTIVE_FEC=1`. When ON the host picks a
    /// per-frame XOR-parity group size (``AdaptiveFECPolicy``) from the folded loss EWMA and signals it
    /// in each fragment's flags so the client splits data/parity identically. When OFF the host always
    /// sends tier 0 (the configured `fec.groupSize`, 5 in prod) → spare flag bits stay zero → the wire is
    /// byte-identical to the pre-WF-4 path. Needs telemetry reports to ever change tier (if the client
    /// sets `AISLOPDESK_NETSTATS=0` no reports arrive ⇒ the tier stays at the today-default tier 0, never OFF).
    /// DEFAULT ON since 2026-06-11 (self-heal era): on a clean path (loss EWMA <0.2%) the tier
    /// relaxes toward less parity — the standing 20% overhead is paid ONLY while loss exists. The
    /// ~1s one-step-per-report re-escalation window at loss onset is covered by AISLOPDESK_SELF_HEAL
    /// (any whole-frame loss self-heals ≤K frames with no round-trip) + client recovery + kfDup.
    /// FEC LADDER FLOOR (2026-06-11 telemetry round): relaxation now FLOORS at g10 (tier 2, ~10%
    /// overhead) — the measured 18 OFF-tier visits on the 0.1-0.6%-baseline path produced 102
    /// unrecovered losses / 65 decode-fails in 169s. `AISLOPDESK_FEC_ALLOW_OFF=1` restores the old
    /// walk to OFF; `AISLOPDESK_ADAPTIVE_FEC=0` restores the static always-g5 tier.
    private static let adaptiveFECEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_ADAPTIVE_FEC"] != "0"
    /// WF-6 (#8) FULL-RANGE COLOR. DEFAULT OFF; enable with `AISLOPDESK_FULL_RANGE=1`. ONE flag flips ALL
    /// FOUR atomic points together: (1) the capturer's NV12 pixel-format variant, (2) the encoder's
    /// explicit BT.709 VUI keys, (3) the `helloAck.fullRange` byte the host sends, and — because the
    /// client derives its decoder pixel-format + shader coefficients FROM that byte — (4) the client
    /// decoder + Metal shader. When OFF all four stay video-range, byte-identical to today. Read once
    /// (env static, like the flags above). NOTE: this is a HOST flag only — the client follows the
    /// stream, so there is NO matching client env to keep in sync (the desync footgun is unreachable).
    private static let fullRange = ProcessInfo.processInfo.environment["AISLOPDESK_FULL_RANGE"] == "1"
    /// WF-8 LONG-TERM-REFERENCE RECOVERY. DEFAULT OFF; enable with `AISLOPDESK_LTR=1` (WF-7's HW probe
    /// confirmed VERDICT=supported on this host). When ON: the encoder sets EnableLTR + reads the
    /// per-frame ack token, LTR frames carry the `isLTR` wire bit, the client acks decoded LTR frames,
    /// and a `requestLTRRefresh` recovers via a cheap `ForceLTRRefresh` P-frame against an ACKNOWLEDGED
    /// token (the ACKED-ONLY invariant) instead of a full IDR — falling back to a real IDR when no
    /// token is acked. When OFF: EnableLTR unset, no token read, no `isLTR` bit, `.refreshLTR` folds to
    /// `requestKeyframe()` (today's requestLTRRefresh→IDR), the client sees no LTR frame so sends no
    /// ack — byte-identical to today. Read once (env static, like the flags above).
    ///
    /// DEFAULT **ON** since 2026-06-10 (LOSS-TOLERANCE #3 — drop-frame-keep-cadence): on the real
    /// path, loss is weather (rate-independent ~1% + 3-9% bursts), so recovery happens many times a
    /// minute and its COST is what the user feels. With LTR off every recovery is a full IDR +
    /// client decoder rebuild; with LTR on it is a cheap ForceLTRRefresh P-frame against an acked
    /// token, no decoder flush — Parsec-class "frame kế chữa lành" recovery. HW-validated on this
    /// host (WF-7 probe VERDICT=supported; WF-8 headless harness). `AISLOPDESK_LTR=0` disables.
    private static let ltrEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_LTR"] != "0"
    /// Full per-event injection trace (`AISLOPDESK_INPUT_TRACE=1`): logs EVERY injected input event
    /// with a monotonic sequence number (NOT sampled), so a loopback run can read the exact
    /// injected ORDER — the ground truth for the reorder fix. No-op in production.
    private static let inputTrace = ProcessInfo.processInfo.environment["AISLOPDESK_INPUT_TRACE"] != nil
    private var encodedFrameCount = 0
    /// Uptime seconds of the last keyframe whose datagrams were duplicate-sent (F3 throttle).
    private var lastKeyframeDupTime: TimeInterval = 0
    /// Monotonic anchor for the per-fragment `hostSendTsMillis` stamp + the RTT fold (the network-
    /// feedback channel). Captured at init BEFORE any frame, so every stamp and `hostRelativeMillis()`
    /// share ONE epoch — RTT is `(hostNow − stamp) − clientHold`, all in this single clock domain
    /// (zero cross-machine skew). A reconnect that re-creates the actor resets the anchor; a stale
    /// stamp echoed from a prior session is rejected by `NetworkEstimate.computeRTTMillis` (elaps<0 / >60s).
    private let sessionStartUptime = ProcessInfo.processInfo.systemUptime
    /// Host-side network estimate folded from the client's periodic NetworkStats reports. A pure value
    /// type — no reference capture, so no retain-cycle risk.
    private var networkEstimate = NetworkEstimate()
    /// Component 2: delivery-keyed recovery-IDR admission (sent-keyframe ring + decode-acked id +
    /// casualty bypass + token bucket). Pure value type, consulted ONLY by ``gateRecoveryIDR(lastDecoded:)``
    /// when `AISLOPDESK_RECOVERY_IDR_V2` is on. Deliberately NOT reset on encoder rebuilds (see
    /// ``resetLTRForNewEncoder()``).
    private var recoveryIDRPolicy = RecoveryIDRPolicy(config: AislopdeskVideoHostSession.recoveryIDRConfig)
    /// Component 5 (recovery-redundancy): collapses the client's byte-identical redundant copies
    /// of one logical recovery request (3× spaced 3 ms) back to ONE host action. Gates ONLY the
    /// `.forceKeyframe` / `.refreshLTR` arms — `.ack`/`.networkStats`/`.reshipCursorShape`
    /// legitimately repeat. Also fixes the pre-existing frame-boundary-straddle double-
    /// `ForceLTRRefresh` (the LTR path has no cooldown of its own).
    private var recoveryDeduper = RecoveryRequestDeduper(windowSeconds: AislopdeskVideoHostSession.recoveryDedupWindow)
    /// `AISLOPDESK_RECOVERY_DEDUP_MS` (default 25, clamp 0...200; 0 disables — every datagram
    /// admitted). COUPLED to the client spacing: ≥ 2× the max copy spread ((copies−1)·spacing =
    /// 12 ms at copies=5, spacing 3 ms) + reorder skew — duplicates do NOT refresh the window
    /// timestamp, so the margin must absorb the whole spread — yet < every legitimate re-request
    /// spacing (lossy escalation floor — default 60 ms since fix 3; at the resolved defaults
    /// 25 ms < 60 ms with room to spare, pinned by the coupling test). Internal (not private) so
    /// the coupling test can assert against the RESOLVED constants.
    static let recoveryDedupWindow: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["AISLOPDESK_RECOVERY_DEDUP_MS"],
           let v = Double(s), v >= 0, v <= 200 { return v / 1000.0 }
        return 0.025
    }()

    /// WF-2 ADAPTIVE BITRATE controller (only seeded when `AISLOPDESK_ABR=1`). A pure value type re-seeded
    /// at every encoder build so a resize re-anchors it to the new resolution's ceiling. `nil` ⇒ ABR
    /// off or no encoder yet ⇒ no actuation.
    private var congestionController: LiveCongestionController?
    /// The last bitrate actually pushed to the encoder via `setLiveBitrate`, so the controller's small
    /// per-tick additive moves are throttled to MATERIAL changes (the controller's `current` advances
    /// every tick; actuation compares against THIS, not the prior tick). Re-anchored to the ceiling at
    /// each encoder build.
    private var lastActuatedBitrate = 0
    /// KHỰNG-ladder stage 2 (AISLOPDESK_VIDEO_DEBUG): last frame-send start, actor-owned. A >28ms gap
    /// between two frame sends during continuous motion = the hole formed at/before encode
    /// (capture stage-1 clean ⇒ encoder/actor pump); see WindowCapturer stage 1.
    private var dbgLastFrameSendAt: Double = 0
    /// WF-4 current adaptive-FEC tier + relax-dwell streak. Starts at tier 0 (= today's configured
    /// `fec.groupSize`, g5) so the stream is byte-identical to the static path until a real netstats
    /// report folds loss and (only when adaptive FEC is on) moves it. With no reports it never
    /// moves — inert at the safe default, never OFF. The dwell (`AdaptiveFECPolicy.relaxDwellReports`)
    /// makes relaxation require ~12s of consecutively clean reports — the 4G burst-flap fix.
    private var fecTierState = AdaptiveFECPolicy.TierState()
    /// WF-8 LTR recovery bookkeeping (pure value type — no reference capture, no retain-cycle risk).
    /// Records `frameID ↔ ack-token` for emitted LTR frames and the set of tokens the client has
    /// ACKNOWLEDGED, both bounded. Only mutated when `AISLOPDESK_LTR=1`; inert (never recorded/acked) when
    /// off, so a `.refreshLTR` decision always falls back to a real IDR.
    private var ltrController = LTRController()
    private nonisolated func dbg(_ message: @autoclosure () -> String) {
        guard Self.debugStderr else { return }
        FileHandle.standardError.write(Data("aislopdesk-videohostd[session]: \(message())\n".utf8))
    }

    private let transport: any VideoDatagramTransport
    private let window: SCWindow
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
    /// Capture + encoder frame-rate cap (fps). Default 60 for Parsec-class scroll/motion smoothness
    /// (30 was visibly steppier); threaded into every `WindowCapturer`/`VideoEncoder` this session builds.
    private let fps: Int
    private let scheduler = VideoSendScheduler()
    private let recoveryRouter = RecoveryDatagramRouter()

    private var stateMachine: VideoSessionStateMachine
    private var packetizer: VideoPacketizer
    /// FEC group size, mirrored from the packetizer's scheme, so ``onEncodedFrame`` can interleave a
    /// frame's fragments column-major across groups before transmit (burst-loss → flicker fix). 1 when
    /// there is no FEC (interleaving is then a no-op).
    private let fecGroupSize: Int

    // Live components, created on accept (never in a test).
    private var capturer: WindowCapturer?
    private var encoder: VideoEncoder?
    private var geometryWatcher: WindowGeometryWatcher?
    private var cursorSampler: CursorSampler?
    private var injector: InputInjector?
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
    /// Feature gate: default ON when display-anchored (VD-parked); `AISLOPDESK_DIALOG_EXPAND=0` disables.
    static let dialogExpandEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_DIALOG_EXPAND"] != "0"

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
    /// LOSS-TOLERANCE #1: dedicated paced-send lane (created in ``start()``, closed in ``stop()``,
    /// flushed on media teardown). `nil` before start / after stop / when `AISLOPDESK_SEND_LANE=0`.
    private var sendLane: VideoSendLane?
    private var encodedConsumer: Task<Void, Never>?
    /// FPS GOVERNOR (only seeded when `AISLOPDESK_FPS_GOVERNOR=1`). A pure value type, re-seeded at the
    /// INITIAL encoder build only (governor state deliberately persists across resize — path
    /// knowledge, like the congestion controller's knee would be if it survived; the capturer/
    /// encoder latches are re-applied at every install site instead). `nil` ⇒ governor off.
    private var fpsGovernor: FPSGovernor?
    /// The fps the governor currently has actuated (== `fps` until a step). Drives the capturer
    /// gate latch + encoder hint re-application at resize and the streamCadence dup-send.
    private var governedFps: Int

    /// - Parameters:
    ///   - window: the desktop-independent window to remote.
    ///   - transport: the UDP datagram transport (production: a ``VideoMuxChannelTransport`` lane on the shared ``NWVideoMuxDatagramTransport``).
    ///   - fec: optional FEC scheme for the video packetizer (default 20% XOR parity).
    public init(
        window: SCWindow,
        transport: any VideoDatagramTransport,
        fec: FECScheme? = XORParityFEC(),
        captureScale: Double = 2.0,
        captureSizeOverride: VideoSize? = nil,
        resizePointLimit: VideoSize? = nil,
        bitrate: Int = VideoEncoder.bitrateBitsPerSecond,
        fps: Int = 60,
    ) {
        self.window = window
        self.transport = transport
        self.captureScale = max(1.0, captureScale)
        self.captureSizeOverride = captureSizeOverride
        self.resizePointLimit = resizePointLimit
        self.bitrate = bitrate
        self.fps = max(1, fps)
        governedFps = max(1, fps)
        stateMachine = VideoSessionStateMachine(fullRange: Self.fullRange)
        // AISLOPDESK_FEC=0 (latency A/B, 2026-06-11): drop the 20% XOR parity entirely — Parsec ships
        // ZERO video FEC and relies on LTR/IDR recovery alone. Parity costs +20% datagrams per
        // frame (+1 pacing chunk ≈ +1.5ms lane serialization, sent AFTER the data) on EVERY frame
        // to save the occasional loss-recovery round-trip. The client reads the FEC tier per
        // fragment, so a parity-less stream is wire-compatible with an unchanged client.
        let fecDisabled = ProcessInfo.processInfo.environment["AISLOPDESK_FEC"] == "0"
        packetizer = VideoPacketizer(fec: fecDisabled ? nil : fec)
        fecGroupSize = fec?.groupSize ?? 1
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

        // Ordered encoder-OUTPUT pump (FIX C). Mirrors the inbound pump: a lock-protected FIFO the
        // VT serial callback appends to (preserving strict encode order) + a coalesced wakeup; a
        // single consumer drains and awaits `onEncodedFrame` IN ORDER so frameID/streamSeq are
        // assigned in encode order, not actor-processing order.
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

        // LOSS-TOLERANCE #1: the paced-send lane. `transport.send` is fire-and-forget UDP enqueue
        // (protocol contract: never blocks), safe to call from the lane's consumer task.
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
                do { try inputRun.append(InputEvent.decode(data)) } catch {
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
                handleRecovery(data)
            case .video,
                 .geometry,
                 .cursor:
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
            let raiseFirst = InputDatagramRouter.raiseFirst(for: event, needsRaise: inputNeedsRaise)
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
        // Proactive raise on client pane focus (the "raise the focused pane's window" model that
        // replaced background injection): bring the captured window frontmost ONCE now, so the user's
        // FIRST click lands instantly instead of paying the per-interaction activate-then-control raise
        // stall. Idempotent — `raiseTargetWindow()` short-circuits when already frontmost. Only
        // meaningful while streaming (the injector exists only then). The SM has no semantics for this
        // message, so action it here and return (no effects to apply).
        if case .focusWindow = message {
            // Bind a LOCAL non-optional injector (it is `@unchecked Sendable`) so the MainActor hop can
            // capture it — mirrors `inject(_:raiseFirst:)`'s `guard let injector` pattern.
            guard stateMachine.mediaFlowing, let injector else { return }
            if Self.inputTrace {
                FileHandle.standardError
                    .write(
                        Data(
                            "aislopdesk-videohostd[inject]: focusWindow → proactive raise (async, window=\(window.windowID))\n"
                                .utf8,
                        ),
                    )
            }
            // FIRE-AND-FORGET (the "click bị delay" fix): never AWAIT the AX raise. On an AX-slow target
            // it costs ≈1s, and the input path must not block on it. `raiseTargetWindow()` self-throttles
            // so this proactive raise + the imminent mouseDown raise coalesce to one bit of work.
            Task { @MainActor in injector.raiseTargetWindow() }
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
                guard requestedWindowID == UInt32(window.windowID) else { return nil }
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
                // UInt16 wire limit.
                guard requestedWindowID == UInt32(window.windowID) else { return nil }
                let maxSize = resizePointLimit ?? VideoSize(width: Double(UInt16.max), height: Double(UInt16.max))
                return SizeNegotiation.clamp(
                    desired: desired,
                    min: VideoSize(width: 1, height: 1),
                    max: maxSize,
                )
            },
        )
        for effect in effects { await apply(effect) }
        // CONCURRENCY-HOST-1: a clean `bye` re-arms the session to `.listening` and tears down
        // capture (above), but the pinned UDP flow slot stays pinned (UDP has no FIN) — so a
        // reconnecting client's fresh hello (a new source port ⇒ a new 4-tuple) was silently
        // refused at the listener until the daemon restarted. Free the flow now so the next
        // client can re-pin and reconnect WITHOUT a daemon restart. (A crash WITHOUT a bye still
        // relies on an idle-timeout reaper — documented follow-up in docs/25 §4.)
        if case .bye = message { transport.resetClientFlow() }
    }

    // R11 (dead-code removal): a `handleReap()` crash-without-bye hook lived here, documented as
    // "wired as `Task { await session.handleReap() }` from `transport.onReap`". That wiring never
    // existed — `transport` has no `onReap`, and the only reaper in the live (mux) path is
    // `NWVideoMuxDatagramTransport.runReaperTick` → `onReapLane` → `VideoMuxSessionRegistry.retireAndStop`
    // → `session.stop()`. `stop()` is a STRICT SUPERSET of what the dead hook did (it also drains the
    // inbound/encoded pumps and runs `teardownLiveComponents` unconditionally), so the reaped client is
    // already torn down correctly. The method was a single-pin-era leftover with zero call sites
    // (verified across Sources + Tests) and a misleading docstring, so it was removed rather than kept
    // as a confusing public no-op.

    private func inject(_ event: InputEvent, raiseFirst: Bool) {
        guard let injector else { return }
        // CLICK-LATENCY FIX (the "click bị delay" bug, proven on-device). The AX raise is ~6–10
        // SYNCHRONOUS cross-process IPC calls; against an AX-slow target app each hits the messaging
        // timeout → ≈1s per raise. The old code AWAITED that raise before posting EACH event, and a
        // single click fires several (mouseDown's `alwaysRaises` + every duplicate loss-resilience
        // mouseUp re-arming the latch + the first post-up move), so one click stalled multiple seconds.
        // On-device trace proved `frontmost` never equals the target (cross-app activation is throttled
        // on macOS 14+), so the short-circuit never fired and the raise was both slow AND futile — yet
        // clicks STILL landed, proving the posted CGEvent (not the raise) is the delivery mechanism.
        // So FIRE-AND-FORGET the raise (best-effort window-order/keyboard-focus nudge) and post the event
        // IMMEDIATELY. Bonus: removing the await deletes the suspension point, so the coalesced run now
        // injects in STRICT order (the down/up-inversion race the await introduced is gone); and
        // `raiseTargetWindow()` self-throttles so the several raises per click coalesce to one.
        if raiseFirst {
            inputNeedsRaise = false
            let injectorRef = injector
            if Self.inputTrace {
                FileHandle.standardError
                    .write(Data("aislopdesk-videohostd[inject]: raiseFirst dispatched async (event=\(event))\n".utf8))
            }
            Task { @MainActor in injectorRef.raiseTargetWindow() }
        }
        dbgInject(event)
        injector.inject(event)
        // A mouse-up ends the interaction → re-arm so the NEXT interaction raises+focuses.
        if InputDatagramRouter.rearmRaiseAfter(event) { inputNeedsRaise = true }
    }

    /// Opt-in (`AISLOPDESK_VIDEO_DEBUG=1`) trace of the injected input stream, so a hardware run
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
            FileHandle.standardError
                .write(Data("aislopdesk-videohostd[inject #\(injectTraceSeq)]: \(Self.inputName(event))\n".utf8))
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

    private func handleRecovery(_ data: Data) {
        switch recoveryRouter.route(datagram: data, mediaFlowing: stateMachine.mediaFlowing) {
        case let .forceKeyframe(lastDecoded):
            // Component 5: drop byte-identical redundant copies (client sends 3× per logical
            // request). A duplicate is dbg-logged and ignored — the first copy already acted.
            guard recoveryDeduper.admit(data, now: ProcessInfo.processInfo.systemUptime) else {
                dbg("recovery dup requestIDR suppressed")
                break
            }
            // Force an IDR on the next captured frame so a client that lost frames re-anchors
            // immediately instead of waiting for the ~1s heartbeat IDR — admission-gated by the
            // delivery-keyed RecoveryIDRPolicy (component 2; legacy capturer gate when V2 off).
            gateRecoveryIDR(lastDecoded: lastDecoded)
        case let .refreshLTR(lastDecoded):
            // Component 5: same dedup gate — REQUIRED here (no cooldown exists on the LTR path,
            // so copies straddling a capture-frame boundary would encode a second ForceLTRRefresh).
            guard recoveryDeduper.admit(data, now: ProcessInfo.processInfo.systemUptime) else {
                dbg("recovery dup requestLTRRefresh suppressed")
                break
            }
            // WF-8: the client asked for an LTR refresh. Decide LTR-refresh-vs-IDR from the runtime
            // acked-token state under the ACKED-ONLY invariant. `.ltrRefresh` issues a cheap
            // ForceLTRRefresh P-frame against a token the client DECODED+ACKED; `.idr` falls back to a
            // real keyframe (when AISLOPDESK_LTR is off OR no token is acked yet — today's behaviour exactly).
            // SELF-HEAL PREFERENCE KEPT: the `.ltrRefresh` arm is UNGATED — only the IDR fallback
            // passes through the recovery-IDR admission policy.
            switch ltrController.recoveryDecision(request: .ltrRefresh, hasEnableLTR: Self.ltrEnabled) {
            case .ltrRefresh:
                dbg("recovery refreshLTR → LTR refresh (acked tokens available)")
                capturer?.requestLTRRefresh()
            case .idr:
                gateRecoveryIDR(lastDecoded: lastDecoded)
            }
        case let .ack(streamSeq):
            // Component 2: a keyframe decode-ack (the client now acks EVERY decoded keyframe, not
            // just LTR-flagged frames) feeds the delivery-keyed cooldown. Unconditional — NOT gated
            // on `Self.ltrEnabled`: ring-matching inside the policy rejects non-keyframe ids, and
            // `ltrController.ackFrame` below already no-ops on unknown ids.
            recoveryIDRPolicy.noteKeyframeDelivered(frameID: streamSeq)
            // WF-8: the `streamSeq` wire field carries a FRAME ID (the dead ack path is repurposed —
            // see RecoveryMessage.ack). Fold it: map frameID→token, add the token to the bounded acked
            // set, and stage it onto the encoder as an AcknowledgedLTRTokens option so a later
            // ForceLTRRefresh may reference it (the ACKED-ONLY invariant). An unknown/duplicate/evicted
            // frameID is a safe no-op (ackFrame returns nil). Only acts under AISLOPDESK_LTR; off ⇒ the
            // client never sends acks anyway, and this stays diagnostics-only.
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
            // FIX B self-heal: the client lost this shape's one-shot bitmap (or it never fit
            // one datagram). Re-emit it through the SAME shape handler so it rides the cursor
            // socket again as a `CursorShapeMessage`; the client cache re-insert is idempotent.
            dbg("recovery requestCursorShape \(shapeID) — re-shipping cursor shape")
            cursorSampler?.reshipShape(shapeID)
        case let .networkStats(report):
            // Network-feedback telemetry: fold a clock-skew-free estimate (host-clock RTT + loss +
            // jitter trend) and LOG it. MAINTAIN+LOG only this phase — nothing consumes the estimate
            // to alter the stream yet. `AISLOPDESK_NETSTATS=0` ⇒ the client reports latestHostSendTs=0 ⇒
            // computeRTTMillis returns nil ⇒ the RTT term is skipped (loss/jitter still fold).
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
            // WF-4 ADAPTIVE FEC: pick the per-frame group-size tier from the freshly-folded loss EWMA.
            // Hysteretic + one-step-clamped (anti-flap) inside the pure policy. Updated ONLY here, inside
            // a real report → it can't move before there is loss data (inert when no reports arrive).
            // No-op unless `AISLOPDESK_ADAPTIVE_FEC=1` ⇒ the tier stays at the today-default tier 0.
            if Self.adaptiveFECEnabled {
                // FEC LADDER FLOOR + STICKY RELAX (2026-06-11): relaxation floors at g10 (tier 2,
                // `AISLOPDESK_FEC_ALLOW_OFF=1` restores the old OFF walk) and an unrecovered-loss
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
            // WF-2 ADAPTIVE BITRATE: tick the AIMD controller on the freshly-folded estimate and
            // actuate a MATERIAL target change onto the live encoder. No-op unless `AISLOPDESK_ABR=1` (the
            // controller is then never seeded ⇒ nil ⇒ this whole block is skipped and the live rate
            // stays pinned at the ceiling). The controller is a pure value type — copy out, tick,
            // write back; no reference capture, so no retain-cycle risk. `setLiveBitrate` is throttled
            // to material moves (≈5% of ceiling / 500 kbps) so it fires rarely, not every report.
            if Self.abrEnabled, var ctrl = congestionController {
                // Fix 4 (cut-reason attribution): `decide` is `onReport` + the WHY token, so the
                // actuate line below can attribute a cut to gradient/rttStreak/loss/… — printing
                // stays here at the debug site; the controller stays pure.
                let decision = ctrl.decide(networkEstimate)
                let target = decision.target
                congestionController = ctrl
                if LiveCongestionController.isMaterialChange(
                    previous: lastActuatedBitrate,
                    target: target,
                    ceiling: ctrl.ceiling,
                ) {
                    lastActuatedBitrate = target
                    encoder?.setLiveBitrate(target)
                    dbg(
                        "abr: actuate target=\(target) ceiling=\(ctrl.ceiling) floor=\(ctrl.floor) current=\(ctrl.current) ticks=\(ctrl.ticks) knee=\(ctrl.kneeBps.map(String.init) ?? "-") reason=\(decision.reason.rawValue)",
                    )
                }
            }
            // FPS GOVERNOR: tick on the same ~50 ms report clock, AFTER the ABR block so it reacts
            // to THIS tick's actuated rate. Congestion evidence reuses the ABR's own RTT constants
            // (the two controllers agree on "congested") + ABR-below-ceiling as a debounced proxy.
            // nil when `AISLOPDESK_FPS_GOVERNOR` is off ⇒ skipped entirely.
            if var gov = fpsGovernor {
                let congested = FPSGovernor.congestionEvidence(
                    lastLossSample: networkEstimate.lastLossSample,
                    smoothedRTTMillis: networkEstimate.smoothedRTTMillis,
                    minRTTMillis: networkEstimate.minRTTMillis,
                    abrCurrent: congestionController?.current, abrCeiling: congestionController?.ceiling,
                )
                let newFps = gov.onTick(targetBps: lastActuatedBitrate, congested: congested)
                let offeredBps = Int(gov.bytesPerFrameEWMA * 8 * Double(governedFps))
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
            // Component 3 (delay-gradient): the client trendline verdict, for the A/B logs.
            let trendStr = String(format: "%.2f", networkEstimate.owdTrendModified)
            let tstate = report.owdTrendStateRaw == 1 ? "o" : (report.owdTrendStateRaw == 2 ? "u" : "n")
            let tdeltas = report.owdTrendDeltas
            // Component 4 (adaptive pacer depth): the client's presentation-health telemetry rides
            // every report — late= (clean hitch signal), gaps= (superset incl. motion-stop
            // boundaries), depth= (live pacer depth gauge; 0 = no pacer). LOG-ONLY this phase
            // (component 3 owns the NetworkEstimate fold path), but it makes every feel-test a
            // measurement session: promotions must co-occur with loss/RTT events, never clean.
            log
                .info(
                    "netstats rx: rttSample=\(rttStr, privacy: .public)ms smoothedRTT=\(smoothedStr, privacy: .public)ms loss=\(lossStr, privacy: .public) rising=\(rising, privacy: .public) trend=\(trendStr, privacy: .public) tstate=\(tstate, privacy: .public) tdeltas=\(tdeltas, privacy: .public) late=\(report.pacerLateFrames, privacy: .public) gaps=\(report.pacerPresentGaps, privacy: .public) depth=\(report.pacerDepth, privacy: .public)",
                )
            dbg(
                "netstats rx: frames=\(report.framesReceived) fec=\(report.fecRecovered) lost=\(report.unrecovered) hostTs=\(report.latestHostSendTs) hold=\(report.clientHoldMs)ms jitter=\(report.owdJitterMicros)us → rtt=\(rttStr)ms smoothedRTT=\(smoothedStr)ms minRTT=\(minRTTStr)ms loss=\(lossStr) rising=\(rising) trend=\(trendStr) tstate=\(tstate) tdeltas=\(tdeltas) late=\(report.pacerLateFrames) gaps=\(report.pacerPresentGaps) depth=\(report.pacerDepth)",
            )
        case let .drop(reason):
            log.error("dropping recovery datagram: \(reason)")
        case .ignoreNotStreaming:
            break
        }
    }

    /// Component 2: admission gate for the two IDR-issuing recovery paths (`.forceKeyframe` and the
    /// `.refreshLTR`→`.idr` fallback). With V2 on, ``RecoveryIDRPolicy`` decides (delivery-keyed
    /// cooldown + casualty bypass + token bucket); only `.grant` latches the capturer keyframe.
    /// With V2 off, the latch is unconditional and the capturer's legacy F1 sent-keyed gate rules.
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
            capturer.requestKeyframe()
            return
        }
        let verdict = recoveryIDRPolicy.decide(
            now: ProcessInfo.processInfo.systemUptime,
            clientLastDecoded: lastDecoded,
            smoothedRTTSeconds: networkEstimate.smoothedRTTMillis / 1000.0,
        )
        if case .grant = verdict {
            capturer.requestKeyframe()
        } else {
            dbg("recovery IDR \(verdict) (lastDecoded=\(lastDecoded.map(String.init) ?? "none"))")
        }
    }

    /// (Re)seed the WF-2 congestion controller to a freshly-built encoder's resolution-aware ceiling
    /// (no-op unless `AISLOPDESK_ABR=1`). Called at EVERY encoder build (initial bring-up + both resize
    /// rebuild paths) so a resize re-anchors the controller — and `lastActuatedBitrate` — to the NEW
    /// ceiling; without re-seeding the controller would keep the OLD ceiling/current and either starve
    /// (old smaller ceiling) or over-shoot (old larger ceiling) the new resolution.
    private func seedCongestionController(ceiling: Int) {
        // LAT-3: seed `lastActuatedBitrate` to the REAL resolution-aware ceiling BEFORE the ABR guard, so
        // the adaptive send-pacing gap (the only reader) uses the true ~45Mbps ceiling — not the 12Mbps
        // fallback — even when ABR is off. Inert in the default config (pacing off), strictly-better when
        // `AISLOPDESK_PACE=1` is A/B'd with `AISLOPDESK_ABR=0` (otherwise heavy frames serialize at 4× the gap).
        lastActuatedBitrate = ceiling
        guard Self.abrEnabled else { return }
        congestionController = LiveCongestionController(ceiling: ceiling)
    }

    /// FPS GOVERNOR actuation: (1) latch the governed fps onto the capturer's cadence gate
    /// (thread-safe), (2) hint the live encoder's `ExpectedFrameRate` (best-effort
    /// VTSessionSetProperty — the gate enforces cadence regardless), (3) tell the client via
    /// `streamCadence` (dup-sent ×2 for loss tolerance — the exact `onCursorShape` pattern).
    private func actuateGovernedFps(_ newFps: Int) {
        capturer?.setGovernedFPS(newFps)
        encoder?.setExpectedFrameRate(newFps)
        sendStreamCadence(UInt16(clamping: newFps))
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

    /// WF-8 self-audit fix: invalidate the LTR acked-set + frame map whenever a FRESH encoder /
    /// `VTCompressionSession` is installed (initial bring-up + both resize rebuild paths — the
    /// WF-8 counterpart of ``seedCongestionController``, called at the SAME install sites so the
    /// two recovery controllers re-anchor to the new encoder in lockstep). A new VT session holds
    /// ZERO acknowledged long-term references and the new encoder's `pendingAckedTokens` starts
    /// empty, so without this the controller's `acknowledgedTokens` (acked against the now-destroyed
    /// session) would keep `hasAckedToken` true → a `.refreshLTR` request would return `.ltrRefresh`
    /// and issue a `ForceLTRRefresh` against an LTR the rebuilt session never had, bypassing the
    /// host-side half of the ACKED-ONLY invariant (only VT's own contract would then prevent
    /// corruption). Resetting re-arms the host gate (`.idr` fallback) until the client decodes+acks a
    /// NEW LTR frame on the rebuilt session. No-op when `AISLOPDESK_LTR` is off (the controller is never
    /// populated), but reset unconditionally so the invariant holds the instant LTR is enabled.
    private func resetLTRForNewEncoder() {
        ltrController.reset()
        // SELF-HEAL: a fresh VT session holds ZERO acknowledged LTRs — disarm the capturer's cadence
        // until the client decodes+acks a new LTR frame on the rebuilt session (else every K-th frame
        // would be VT's IDR fallback). Re-armed by the next `.ack` fold.
        capturer?.setSelfHealEligible(false)
        // Component 2: `recoveryIDRPolicy` is DELIBERATELY NOT reset here. The packetizer (and so
        // frameIDs) persists across encoder rebuilds, so the sent-keyframe ring and the delivered id
        // stay valid — and the token bucket MUST survive a rebuild (a resize storm during loss must
        // not refill the recovery-IDR budget). If HW testing ever shows resize-recovery starvation,
        // a one-line policy re-init here is the dial.
    }

    // MARK: Effects

    private func apply(_ effect: VideoSessionStateMachine.Effect) async {
        switch effect {
        case let .sendControl(message):
            dbg("→ sending control: \(String(describing: message))")
            transport.send(scheduler.scheduleControl(message).bytes, on: .control)
        case let .startCapture(_, width, height):
            dbg("effect startCapture \(width)x\(height) — bringing up live capture/encode")
            await startLiveComponents(width: Int(width), height: Int(height))
            // FPS GOVERNOR: announce the session's content cadence up front (+dup) so the
            // streamCadence message is the single cadence truth even before any governed step.
            // OFF ⇒ no message at all (byte-identical wire).
            if Self.fpsGovernorEnabled { sendStreamCadence(UInt16(clamping: governedFps)) }
        case .stopCapture:
            dbg("effect stopCapture")
            await teardownLiveComponents()
        case let .resizeCapture(width, height, epoch):
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
        // WF-2: the new resolution has a new ceiling — re-seed the controller to it once the new
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
        let newCapturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: captureSizeOverride != nil,
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh in
            do {
                if ltrRefresh {
                    try newEncoder.encodeLiveLTRRefresh(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if crisp {
                    try newEncoder.encodeLiveCrispKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if compact {
                    try newEncoder.encodeCompactKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else {
                    try newEncoder.encodeLive(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts,
                        forceKeyframe: forceKeyframe,
                    )
                }
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
              epoch >= stateMachine.lastResizeEpoch
        else {
            dbg(
                "resizeCapture epoch=\(epoch) — superseded/stale during oldCapturer.stop (lastEpoch=\(stateMachine.lastResizeEpoch)); aborting install",
            )
            return
        }

        // Install the new components, then bring the new SCStream up at the achieved pixel size.
        encoder = newEncoder
        seedCongestionController(ceiling: ceiling) // WF-2: re-anchor the controller to the new resolution's ceiling
        resetLTRForNewEncoder() // WF-8: the new VT session holds no acked LTRs — invalidate the acked-set
        capturer = newCapturer
        // FPS GOVERNOR: a fresh capturer/encoder start at the base fps — re-apply the live
        // governed state (governor state itself persists across resize: path knowledge). No
        // client message — the cadence is unchanged.
        if Self.fpsGovernorEnabled, governedFps != fps {
            newCapturer.setGovernedFPS(governedFps)
            newEncoder.setExpectedFrameRate(governedFps)
        }
        let captureWindow = window
        do {
            nonisolated(unsafe) let w = captureWindow
            try await newCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            dbg(
                "resize: new SCStream started (\(pixelWidth)x\(pixelHeight) px @\(captureScale)×, \(achievedWidth)x\(achievedHeight) pt) epoch=\(epoch)",
            )
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
    private func restartOldSizeCapture(
        points: VideoSize,
        epoch: UInt32,
        deadCapturer: WindowCapturer,
        deadEncoder: VideoEncoder,
    ) async {
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

        // WF-2: this recovery rebuild uses the OLD (pre-resize) pixel size — re-seed the controller to
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
            preferDisplayAnchored: captureSizeOverride != nil,
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh in
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
                    )
                }
            } catch {
                logCallback.error("live encode (post-resize recovery) failed: \(String(describing: error))")
            }
        }
        encoder = rebuiltEncoder
        seedCongestionController(ceiling: ceiling) // WF-2: re-anchor the controller to the rebuilt (old-size) ceiling
        resetLTRForNewEncoder() // WF-8: the rebuilt VT session holds no acked LTRs — invalidate the acked-set
        capturer = rebuiltCapturer
        // FPS GOVERNOR: re-apply the live governed state to the rebuilt components (see applyResize).
        if Self.fpsGovernorEnabled, governedFps != fps {
            rebuiltCapturer.setGovernedFPS(governedFps)
            rebuiltEncoder.setExpectedFrameRate(governedFps)
        }
        let captureWindow = window
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
        // WF-2: this resolution-aware result is BOTH the encoder bitrate AND the congestion controller's
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
        seedCongestionController(ceiling: ceiling) // WF-2: anchor the controller to this build's ceiling
        resetLTRForNewEncoder() // WF-8: anchor the LTR acked-set to this build (clears any prior-client acks on actor reuse)
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
        let capturer = WindowCapturer(
            fps: fps,
            captureScale: captureScale,
            fullRange: Self.fullRange,
            preferDisplayAnchored: captureSizeOverride != nil,
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh in
            do {
                if ltrRefresh {
                    try encoder.encodeLiveLTRRefresh(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if crisp {
                    try encoder.encodeLiveCrispKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else if compact {
                    try encoder.encodeCompactKeyframe(pixelBuffer: pixelBuffer, presentationTime: pts)
                } else {
                    try encoder.encodeLive(
                        pixelBuffer: pixelBuffer,
                        presentationTime: pts,
                        forceKeyframe: forceKeyframe,
                    )
                }
            } catch {
                logCallback.error("live encode failed: \(String(describing: error))")
            }
        }
        self.capturer = capturer

        // Geometry watcher → geometry datagrams + keep input/cursor bounds in sync.
        let geometryWatcher = WindowGeometryWatcher(
            windowID: window.windowID,
            pid: window.owningApplication?.processID ?? 0,
        ) { [weak self] message in
            guard let self else { return }
            Task { await self.onGeometry(message) }
        }
        self.geometryWatcher = geometryWatcher
        // DIALOG-EXPAND: arm the union poll only when the window is VD-parked (display-anchored
        // capture — the feature relies on includeChildWindows compositing the dialog) and the
        // feature env is on. The handler hops onto the actor; ``onAssociatedUnion`` decides whether
        // the union differs from the live region enough to rebuild.
        dialogExpandArmed = (captureSizeOverride != nil) && Self.dialogExpandEnabled
        captureRegionGlobal = nil // a fresh/reused session starts captured at the plain window frame
        if dialogExpandArmed {
            geometryWatcher.setAssociatedUnionHandler { [weak self] unionGlobal in
                guard let self else { return }
                Task { await self.onAssociatedUnion(unionGlobal) }
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

        // Input injector (created with the window pid + bounds).
        injector = InputInjector(
            pid: window.owningApplication?.processID ?? 0,
            windowID: window.windowID,
            windowBoundsCG: bounds,
        )
        inputNeedsRaise = true

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
        // Frames queued in the paced-send lane belong to the capture/encode generation being torn
        // down — drop them (a mid-pace job aborts at its next chunk boundary). The lane itself
        // survives for the next hello; `stop()` is what closes it.
        sendLane?.flush()
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
        encodedFrameCount += 1
        if encodedFrameCount == 1 || encodedFrameCount.isMultiple(of: 15) {
            dbg("encoded+sent frame #\(encodedFrameCount) (\(avcc.count)B, keyframe=\(keyframe), crisp=\(crisp))")
        }
        // Stamp the host-relative send time on every fragment of this frame (the network-feedback
        // channel). All fragments of one frame share one stamp; the ~≤6 ms pacing/kfDup bias is
        // sub-frame and acceptable (it makes the measured RTT a slight upper bound — the safe
        // direction). 0 when telemetry is disabled (AISLOPDESK_NETSTATS=0) → the client reports
        // latestHostSendTs=0 → the host's RTT fold is skipped.
        let sendTs: UInt32 = Self.telemetryEnabled ? hostRelativeMillis() : 0
        // WF-4: the per-frame FEC tier. Adaptive OFF ⇒ always tier 0 (= configured g5) ⇒ byte-identical.
        let tier = Self.adaptiveFECEnabled ? fecTierState.tier : AdaptiveFECPolicy.defaultTier
        // WF-8: if this is an LTR frame (AISLOPDESK_LTR on AND the encoder surfaced an ack token), record the
        // frameID↔token mapping (read the frameID the packetizer is ABOUT to assign, BEFORE packetize
        // increments it) so a later client ack(frameID) can fold the token, AND mark every fragment
        // with the isLTR wire bit so the client knows to ack on decode. Off ⇒ ltrToken nil ⇒ no record,
        // isLTR false ⇒ byte-identical wire. The packetizer persists across resize, so the frameID is
        // stable; record/peek/packetize all run here in encode order on the actor → race-free.
        // STALE-LTR FIX (2026-06-12): an IDR resets the DECODER's reference world — the DPB,
        // long-term references INCLUDED, is cleared by HEVC spec — so every token acked BEFORE
        // this keyframe now describes a reference the client no longer holds. Without this reset
        // a post-IDR ForceLTRRefresh could reference a pre-IDR acked token, which the client
        // cannot decode: -12909 → invalidateSession → forced IDR → another stale refresh — a
        // self-sustaining failure loop OBSERVED LIVE 2026-06-12 (ltr=true fec=false hard-fails
        // on a loss-free wire, ~1/6s under scroll). Mirror of ``resetLTRForNewEncoder`` fired per
        // ENCODED keyframe (any source: recovery grant, escalation, connect, crisp-IDR), BEFORE
        // the record below so the keyframe's OWN token (post-IDR, valid) still registers; the
        // client re-acks within ~one self-heal cadence and refreshes resume.
        if keyframe {
            ltrController.reset()
            capturer?.setSelfHealEligible(false)
            encoder?.clearStagedAckedTokens()
        }
        let isLTR = Self.ltrEnabled && ltrToken != nil
        if isLTR, let token = ltrToken {
            ltrController.recordLTRFrame(frameID: packetizer.peekNextFrameID, token: token)
        }
        // Component 2: record (keyframe frameID, sentAt) for the delivery-keyed recovery-IDR
        // cooldown — EVERY keyframe (recovery, first-frame, static-crisp, heartbeat), peeked BEFORE
        // packetize increments (the same race-free discipline as the LTR record above). kfDup's
        // second copy reuses the same frameID, so there is nothing extra to record for it.
        if keyframe {
            recoveryIDRPolicy.noteKeyframeSent(
                frameID: packetizer.peekNextFrameID,
                now: ProcessInfo.processInfo.systemUptime,
            )
        }
        let fragments = packetizer.packetize(
            frame: avcc,
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: sendTs,
            fecTier: tier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
        )
        // Interleave transmission column-major across FEC groups so an adjacent-loss BURST spreads to
        // distinct groups (each recoverable by single-loss XOR) instead of wiping one group. Header
        // `fragIndex`/grouping is unchanged, so the client (reassembles by index, reorder-tolerant) is
        // unaffected — host-only, no wire change. DEFAULT ON (AISLOPDESK_INTERLEAVE=0 disables): the once-seen
        // white-screen was HW-investigated 2026-06-09 (headless harness + live GUI loopback) and does NOT
        // reproduce on the current codebase. WF-4: interleave by the SAME per-frame group size the parity
        // used (OFF tier ⇒ g=1 ⇒ no-op; tier 0 ⇒ fecGroupSize ⇒ identical).
        let interleaveGroup = AdaptiveFECPolicy.groupSize(forTier: tier, default: fecGroupSize) ?? 1
        let ordered = Self.interleaveTransmit ? FragmentInterleaver
            .interleave(fragments, groupSize: interleaveGroup) : fragments
        let outgoings = scheduler.scheduleFrame(ordered)
        if Self.debugStderr {
            let now = ProcessInfo.processInfo.systemUptime
            if dbgLastFrameSendAt > 0, now - dbgLastFrameSendAt > 0.028 {
                dbg("send gap \(Int((now - dbgLastFrameSendAt) * 1000))ms") // khựng-ladder stage 2
            }
            dbgLastFrameSendAt = now
        }
        // LOSS-TOLERANCE #1: hand the frame to the paced-send lane and RETURN — the encoder-output
        // pump never sleeps on pacing again (inline pacing of frame N delayed frames N+1..k →
        // measured 28–179ms send gaps = the khựng). Wire order is preserved (one lane consumer).
        if let sendLane {
            // 1b: keyframes pace at ≥ kfPaceFloorBps — IDR delivery time IS recovery time, and the
            // measured path carries 30Mbps at the same weather-loss as 5Mbps (rate-independent).
            let paceTargetBps = keyframe ? max(lastActuatedBitrate, Self.kfPaceFloorBps) : lastActuatedBitrate
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
            sendLane.enqueue(VideoSendLane.Job(
                outgoings: outgoings,
                gapNanos: gapNanos,
                chunkFragments: Self.paceChunkFragments,
            ))
            // F3 keyframe DUPLICATE-SEND, lane edition: the second copy is just another in-order job
            // with a leading time-separation gap. Throttle state stays actor-owned.
            if Self.kfDup, keyframe {
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
            return
        }
        await sendPaced(outgoings)
        // F3: keyframe DUPLICATE-SEND. A heartbeat/recovery IDR is a large multi-datagram burst; even
        // paced, a time-correlated loss in one XOR group is unrecoverable → corrupt IDR → flicker.
        // Re-send the SAME ordered list a second time (paced + time-separated) so the IDR survives unless
        // BOTH copies of a fragment are lost. Reassembler dedups by frameID/fragIndex (overwrite-by-
        // identical-bytes; a copy after completion is .stale) → decoded exactly once. NOT a reorder → no
        // white-screen risk. Keyframes ONLY; throttled to ≤1 per kfDupMinInterval so a storm isn't
        // byte-amplified. AISLOPDESK_KF_DUP=1 to enable.
        if Self.kfDup, keyframe, stateMachine.mediaFlowing {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastKeyframeDupTime >= Self.kfDupMinInterval {
                lastKeyframeDupTime = now
                try? await Task.sleep(nanoseconds: Self.paceGapNanos) // time-separate the two copies
                if stateMachine.mediaFlowing { await sendPaced(outgoings) }
            }
        }
    }

    /// Sends one frame's datagrams, PACED (see `paceSend`) when large so a big IDR / scroll-delta does not
    /// blast as one instant burst → no receive-buffer overflow → no burst loss → no flicker. Small frames
    /// send in one shot. Reorder-free + wire-identical, so zero white-screen risk. Re-checks `mediaFlowing`
    /// after each gap so a bye/stop teardown racing the pacing aborts cleanly.
    private func sendPaced(_ outgoings: [VideoSendScheduler.Outgoing]) async {
        if Self.paceSend, outgoings.count > Self.paceChunkFragments {
            // RC-2: rate-proportional gap (drain a chunk at ≈ the live link rate) instead of the fixed
            // 0.5ms burst. Computed once per frame from the current ABR target.
            let gapNanos: UInt64 = Self.pacingAdaptive
                ? Self.adaptivePaceGapNanos(
                    targetBps: lastActuatedBitrate,
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
            if RustVideoHostFFI.captureReoriginOnGeometry(activeRegionGlobal: captureRegionGlobal) {
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
    private func onAssociatedUnion(_ unionGlobal: CGRect) async {
        guard dialogExpandArmed, stateMachine.mediaFlowing, !captureRegionRebuilding else { return }
        let windowFrame = currentWindowBoundsCG().cgRect
        // The "natural" region is the window frame; a union strictly larger than it (a dialog
        // overhangs) expands, otherwise we want the plain window frame back.
        let desired = unionGlobal.contains(windowFrame) && unionGlobal != windowFrame ? unionGlobal : windowFrame
        let current = captureRegionGlobal ?? windowFrame
        guard RustVideoHostFFI.captureShouldRetarget(current: current, desired: desired) else { return }
        // Contracting back to (approximately) the window frame ⇒ clear the override; else expand.
        let target: CGRect? = RustVideoHostFFI
            .captureShouldRetarget(current: desired, desired: windowFrame) ? desired : nil
        await applyCaptureRegion(target)
    }

    /// DIALOG-EXPAND rebuild: re-point the capture at `regionGlobal` (nil ⇒ the plain window frame)
    /// WITHOUT AX-resizing the window. Mirrors ``applyResize`` steps b–d (build new encoder, swap the
    /// capturer with a region override, ack) but skips the AX window resize (step a) — the window is
    /// untouched; only the captured RECT and the input/cursor mapping origin move. The client adopts
    /// the new size frame-gated and grows the pane for free (see the resize-path ack contract).
    private func applyCaptureRegion(_ regionGlobal: CGRect?) async {
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
            preferDisplayAnchored: captureSizeOverride != nil,
        ) { pixelBuffer, pts, forceKeyframe, crisp, compact, ltrRefresh in
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
                ) }
            } catch { logCallback.error("dialog-expand encode failed: \(String(describing: error))") }
        }
        await oldCapturer.stop()
        oldEncoder.completeFrames()
        // Supersede guard (mirrors applyResize FIX #1): a bye/stop/resize raced our suspension.
        guard stateMachine.mediaFlowing, capturer === oldCapturer, encoder === oldEncoder else {
            dbg("dialog-expand: superseded during oldCapturer.stop — aborting install")
            return
        }
        encoder = newEncoder
        seedCongestionController(ceiling: ceiling)
        resetLTRForNewEncoder()
        capturer = newCapturer
        if Self.fpsGovernorEnabled, governedFps != fps {
            newCapturer.setGovernedFPS(governedFps)
            newEncoder.setExpectedFrameRate(governedFps)
        }
        // Re-origin the input + cursor mapping to the captured region so a click in the dialog area
        // (which may sit left/above the window) maps to the correct GLOBAL point. Contracting back
        // to the window frame restores the window-origin mapping. (CursorSampler `visible` also keys
        // off this rect's size, so the cursor stays reported while over the dialog.)
        let mapRect = VideoRect(x: region.minX, y: region.minY, width: region.width, height: region.height)
        injector?.updateWindowBounds(mapRect)
        cursorSampler?.updateWindowBounds(mapRect)
        captureRegionGlobal = regionGlobal
        let captureWindow = window
        do {
            nonisolated(unsafe) let w = captureWindow
            try await newCapturer.start(window: w, pixelWidth: pixelWidth, pixelHeight: pixelHeight, region: override)
            dbg(
                "dialog-expand: capture region \(regionGlobal == nil ? "→ window frame" : "→ union") \(pointW)x\(pointH)pt (\(pixelWidth)x\(pixelHeight)px) epoch=\(epoch)",
            )
        } catch {
            log.error("dialog-expand capturer start failed: \(String(describing: error))")
            if capturer === newCapturer { capturer = nil
                encoder = nil
            }
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
    }

    private func onCursorUpdate(_ update: CursorUpdate) {
        guard stateMachine.mediaFlowing else { return }
        transport.send(scheduler.scheduleCursor(.update(update)).bytes, on: .cursor)
    }

    /// A new cursor SHAPE bitmap to ship out-of-band (once per shapeID; the sampler
    /// owns the dedup). Sent on the cursor socket as a ``CursorShapeMessage``.
    ///
    /// SHAPE-LAG FIX (2026-06-10): sent TWICE, ~25 ms apart. The shipment is one-shot per shapeID —
    /// if its single datagram is lost the client shows the wrong pointer until the re-request
    /// debounce fires, which reads exactly like "cursor shape changes slower than Parsec". A shape
    /// change often coincides with video motion (the lossiest moment), so cheap time-separated
    /// repetition (≤ ~1.2 KB, a few dozen per session) closes that window; the client's shape
    /// registration is idempotent per shapeID, so the duplicate is harmless.
    private func onCursorShape(_ shape: CursorShapeMessage) {
        guard stateMachine.mediaFlowing else { return }
        let bytes = scheduler.scheduleCursor(.shape(shape)).bytes
        transport.send(bytes, on: .cursor)
        Task { // inherits this actor's isolation; re-checks liveness after the gap so a
            // bye/stop teardown racing the delay aborts cleanly
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard stateMachine.mediaFlowing else { return }
            transport.send(bytes, on: .cursor)
        }
    }

    // MARK: Helpers

    private func currentWindowBoundsCG() -> VideoRect {
        // Live bounds via the watcher if present, else the window's creation frame.
        geometryWatcher?.currentBoundsCG() ?? VideoRect(window.frame)
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
/// actor can collapse pointer-motion runs (``InputMotionCoalescer``). Replaces the prior
/// unbounded `AsyncStream` of datagrams, whose strictly-serial per-event drain (three
/// WindowServer round-trips per motion event) let a motion flood accrue multi-second lag.
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

/// Lock-protected FIFO of ENCODED frames feeding the host's single ordered consumer (FIX C). The
/// encoder's VT output callback fires in STRICT encode order on a serial queue and APPENDS here
/// synchronously (no actor hop — so encode order is carried end-to-end); the single consumer task
/// drains the backlog IN ORDER and awaits `onEncodedFrame` one at a time, so the packetizer
/// assigns frameID/streamSeq in encode order. Replaces the prior `Task`-per-frame fan-out, which
/// gave no FIFO guarantee across separately-created Tasks targeting the actor (frame N+1 could be
/// processed before frame N → a delta packetized before its IDR).
final class EncodedFrameQueue: @unchecked Sendable {
    /// One encoded frame: the AVCC bytes + keyframe/crisp flags the packetizer needs, plus the WF-8
    /// LTR ack token (non-nil only when this is a Long-Term-Reference frame and AISLOPDESK_LTR is on).
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
#endif
