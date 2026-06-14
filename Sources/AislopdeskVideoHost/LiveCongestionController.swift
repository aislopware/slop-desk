import Foundation

/// PURE AIMD congestion controller for the live HEVC stream (WF-2 adaptive bitrate, 2026-06-09).
///
/// WHY: WF-1 landed the network-feedback channel — the host folds the client's periodic
/// ``NetworkStatsReport`` into a clock-skew-free ``NetworkEstimate`` (RTT / loss / OWD-gradient). That
/// estimate was MAINTAIN+LOG only. This controller is the consumer: given the latest estimate it
/// decides a new live target bitrate, which the host actuates via ``VideoEncoder/setLiveBitrate(_:)``
/// (AverageBitRate + DataRateLimits together). The encoder never exceeds the ``LiveBitratePolicy``
/// ceiling and never drops below a sane floor.
///
/// SHAPE: Additive-Increase / Multiplicative-Decrease (AIMD) — the standard anti-oscillation control
/// law. On congestion (loss over threshold, or RTT inflated above the path baseline WITH a rising OWD
/// gradient) the target DROPS multiplicatively (fast back-off); on a clean link past a hold-down
/// window it CLIMBS additively (slow probe toward the ceiling). Severe loss halves immediately.
///
/// PURE + DETERMINISTIC: no wall-clock, no I/O, no reference capture. "Time" is the count of folded
/// reports (`ticks`) — the client sends ~one report per 50ms, so `warmupTicks`/`holdTicks` are
/// report-counts, not seconds. The ceiling/floor are injected at construction (re-seeded per encoder
/// build so a resize re-anchors to the new resolution's ceiling). Mirrors ``LiveBitratePolicy`` /
/// ``NetworkEstimate`` / ``StaticIDRDecider``: the policy is unit-testable in isolation; the
/// HW-gated ``VideoEncoder`` it drives is never instantiated in a test.
///
/// STABILITY MITIGATIONS (baked in so AIMD cannot thrash on a transient spike):
///  - Loss decisions key on the RAW per-report sample (``NetworkEstimate/lastLossSample``), NOT the
///    EWMA-damped ``NetworkEstimate/lossRate`` — so a single transient spike costs exactly ONE
///    decrease, never a cascade of decreases on the EWMA's slowly-decaying tail (a clean report reads
///    raw loss 0 ⇒ no decrease). The EWMA `lossRate` is retained for logging/telemetry trend only.
///  - A controller-LOCAL warmup (`warmupTicks`, ~500ms) suppresses ALL action at cold start, so a
///    `loss == 0` open-loop start can never trigger a spurious drop.
///  - A `lossThreshold` gate (not "any loss") + a hold-down (`holdTicks`, ~1s) — RE-ARMED only when a
///    decrease actually lowers the rate (a no-op decrease at the floor does not extend it) — suppress
///    immediate re-increase thrash without inflating dead time at the floor.
///  - Recovery is deliberately slow (additive `ceiling / increaseDivisor` per tick).
///  - The RTT path needs an ABSOLUTE slack (`rttSlackMillis`) on top of the multiplicative
///    `rttInflateFactor`: on a low-latency LAN (minRTT ≈ 5ms) the ×1.25 threshold is ~6ms — pure
///    scheduling noise (smoothedRTT wobbles 7–12ms) trips it permanently. Real queue build-up shows
///    up as tens of ms of ABSOLUTE inflation; +15ms slack makes sub-slack wobble invisible while a
///    long-baseline WAN path (minRTT 50ms+) is still governed by the multiplicative factor.
///  - The RTT signal must be SUSTAINED (`rttStreakTicks` consecutive inflated reports, ~150ms)
///    before it may decrease — a one-report blip never acts. The per-report `owdGradientRising`
///    flag is deliberately NOT consulted: it compares only two adjacent jitter samples, so on a
///    steady link it flaps ~50/50 (measured live 2026-06-10) — a coin flip, not a signal.
///  - RTT-triggered decreases are PROPORTIONAL to the measured queue (DELAY-TARGETING, 2026-06-11):
///    `factor = (minRTT + slack) / smoothedRTT` clamped to `[rttDecreaseFloorFactor,
///    rttDecreaseCapFactor]` — a large standing queue cuts hard in one step, the post-congestion EWMA
///    decay tail trims at most −5%, so the 2026-06-09 "×0.85 every 50ms to the floor" cascade is
///    structurally impossible and the RTT path may re-decrease on the SHORT `cutHoldTicks` spacing
///    (with a fresh streak each time) instead of the full increase hold-down.
///  - ONE MULTIPLICATIVE CUT PER `cutHoldTicks` WINDOW — loss cuts included (CUT-CASCADE FIX,
///    2026-06-11 VD session): the loss branch used to fire on EVERY report over the threshold, but
///    the measured inter-ISP weather bursts span 2-10 consecutive ~50ms reports, so one 130ms burst
///    cascaded 29M→14M→floor in 2 ticks (31 such drops in a 4-minute session) while FEC recovered
///    every lost frame (cutting bought nothing). TCP halves once per WINDOW, not once per loss —
///    the first cut of an episode is still immediate; a burst that persists past ~400ms cuts again.
///  - NO "severe raw-sample" fast-halve (same fix): the ~50ms report window holds only ~3 frames,
///    so ONE lost frame reads as a 33% raw sample — quantization noise, not severity (the
///    catastrophic branch documents exactly this, yet the old severe branch keyed on it and halved).
///    The depth of a corroborated cut now comes from the MEASURED QUEUE (the proportional RTT
///    sizing) with the classic ×0.85 as the loss-path step; a true collapse is the EWMA-keyed
///    catastrophic halve, which needs ~300ms of sustained ≥50% loss to arm.
///  - A queue-corroborated decrease remembers the landed-on rate as the KNEE (ssthresh, `kneeBps`):
///    additive increase at/above it runs ÷`kneeCautionDivisor` so recovery hovers under the rate that
///    built the queue instead of re-bashing it every second (the felt 25↔40Mbps pumping). The knee
///    expires after `kneeTTLTicks` without re-confirmation — path conditions drift.
///  - DELAY-GRADIENT EARLY CUT (component 3, 2026-06-11, default OFF — `AISLOPDESK_ABR_GRAD=1`): the
///    client's libwebrtc-style trendline (per-FRAME OWD slope, adaptive threshold, sustained
///    overuse) ships its verdict in every report; when it reads OVERUSING **and** the SAME report's
///    RAW RTT sample clears the existing factor+slack gates (fresh level evidence — no EWMA lag, no
///    streak), ONE multiplicative ×`gradientDecreaseFactor` cut is authorized after a single report
///    (~100-170ms from onset vs ~250-300ms for the smoothed path). It shares `cutHoldTicks` spacing
///    with every other cut (the cut-cascade invariant extends, never regresses), sets NO knee (an
///    onset reflex is not capacity knowledge — the proportional path sets it if the queue is real),
///    and while overuse is detected the additive probe is suppressed (never climb INTO a detected
///    overuse during the cut hold).
///
/// SAFE WHEN TELEMETRY OFF: with `loss == 0` and no valid RTT (`minRTTMillis == .infinity`) the
/// congestion predicate is always false, so the controller can only additively increase — but it
/// starts AT the ceiling and is clamped there ⇒ a no-op. It NEVER decreases on absence-of-data; only
/// on positive evidence. Inert and byte-identical in every telemetry-off permutation.
///
/// All tunables are env-overridable (`AISLOPDESK_ABR_*`) for HW A/B without a rebuild.
public struct LiveCongestionController: Sendable, Equatable {
    // MARK: Tunables (env-overridable AISLOPDESK_ABR_*)

    /// Reports to fold before ANY action — the cold-start guard (~10 × 50ms ≈ 500ms). `AISLOPDESK_ABR_WARMUP`.
    public static let warmupTicks: Int = envInt("AISLOPDESK_ABR_WARMUP", 10, min: 0, max: 100_000)
    /// EWMA loss-rate above which the link is "congested" → multiplicative decrease. `AISLOPDESK_ABR_LOSS`.
    public static let lossThreshold: Double = envDouble("AISLOPDESK_ABR_LOSS", 0.02, min: 0, max: 1)
    /// EWMA loss-rate above which the link is "severely congested" → halve immediately. `AISLOPDESK_ABR_SEVERE`.
    public static let severeLossThreshold: Double = envDouble("AISLOPDESK_ABR_SEVERE", 0.10, min: 0, max: 1)
    /// LOSS-TOLERANCE #4 (2026-06-10): loss below ``catastrophicLossThreshold`` decreases ONLY when
    /// CORROBORATED by RTT inflation (both gates of the RTT predicate on the same report). Measured
    /// on the real inter-ISP path (iperf3, 1200B datagrams): loss is ~0.6–1.1% at 5, 12 AND 30Mbps —
    /// rate-INDEPENDENT weather, with multi-second 3–9% burst episodes at FLAT RTT (jitter 0.3ms).
    /// Backing the rate off cannot reduce that loss; it only degrades quality and (pre-#1) paced the
    /// recovery IDR at the collapsed rate. Loss WITH RTT inflation = a building queue = real
    /// congestion → the classic AIMD response stays. `AISLOPDESK_ABR_LOSS_NEEDS_RTT=0` reverts.
    public static let lossNeedsRTTCorroboration = ProcessInfo.processInfo
        .environment["AISLOPDESK_ABR_LOSS_NEEDS_RTT"] != "0"
    /// EWMA loss-rate above THIS halves even at flat RTT: a queue-less policer / true link collapse
    /// drops without inflating RTT, and at a SUSTAINED ≥25% the stream is unusable regardless of
    /// cause — backing off is the only safe move. Keyed on the EWMA ``NetworkEstimate/lossRate``
    /// (NOT the raw sample) deliberately: the ~50ms report window holds only ~3 frames, so ONE
    /// dropped frame reads as a 33% raw sample — weather, not collapse. The EWMA (alpha 0.125)
    /// needs ~6 consecutive ≥50%-loss reports (~300ms of true collapse) to cross 0.25, while a
    /// single spike moves it ≤12.5%. Gated on the hold-down so the decaying EWMA tail after the
    /// collapse ends cannot cascade halvings to the floor. `AISLOPDESK_ABR_CATASTROPHIC`.
    public static let catastrophicLossThreshold: Double = envDouble("AISLOPDESK_ABR_CATASTROPHIC", 0.25, min: 0, max: 1)
    /// Multiplicative decrease factor on ordinary congestion (0.85 = drop to 85%). `AISLOPDESK_ABR_DEC`.
    public static let decreaseFactor: Double = envDouble("AISLOPDESK_ABR_DEC", 0.85, min: 0.05, max: 0.999)
    /// Multiplicative decrease factor on SEVERE loss (0.5 = halve). `AISLOPDESK_ABR_SEVERE_DEC`.
    public static let severeDecreaseFactor: Double = envDouble("AISLOPDESK_ABR_SEVERE_DEC", 0.5, min: 0.05, max: 0.999)
    /// Additive-increase step = `ceiling / increaseDivisor` per clean tick (32 ⇒ ~3% of ceiling). `AISLOPDESK_ABR_INC_DIV`.
    public static let increaseDivisor: Int = envInt("AISLOPDESK_ABR_INC_DIV", 32, min: 1, max: 100_000)
    /// Reports to suppress any increase after a decrease — the anti-thrash hold-down (~20 × 50ms ≈ 1s). `AISLOPDESK_ABR_HOLD`.
    public static let holdTicks: Int = envInt("AISLOPDESK_ABR_HOLD", 20, min: 0, max: 100_000)
    /// `smoothedRTT > minRTT × rttInflateFactor` (AND past the absolute slack) signals queue build-up. `AISLOPDESK_ABR_RTT`.
    public static let rttInflateFactor: Double = envDouble("AISLOPDESK_ABR_RTT", 1.25, min: 1.0, max: 100)
    /// ABSOLUTE smoothed-RTT inflation over the baseline (ms) ALSO required before the RTT path may
    /// signal congestion — keeps LAN scheduling wobble (a few ms on a ~5ms baseline) sub-threshold. `AISLOPDESK_ABR_SLACK`.
    public static let rttSlackMillis: Double = envDouble("AISLOPDESK_ABR_SLACK", 15.0, min: 0, max: 10000)
    /// BASELINE-PROPORTIONAL slack (2026-06-11, cellular wobble fix): the effective slack is
    /// `max(rttSlackMillis, slackFraction × minRTT)`. The fixed 15ms was tuned for ~5-10ms LAN
    /// baselines; on the measured 4G path (minRTT ≈ 40-44ms) cellular scheduler wobble of ±50% is
    /// RATE-INDEPENDENT path texture (identical at 3M and 11.5M actuated), yet 44→60ms tripped
    /// `min+15` constantly → perpetual −5% trims pinned the average rate at ~3.5M on a path that
    /// carries 8M+ (soft image, zero latency gain). 0.75 reclassifies the sub-`1.75×min` band as
    /// weather while a REAL queue (smoothed ≥ ~1.75× baseline) still cuts; LAN/WiFi baselines are
    /// unaffected (0.75×10ms < 15ms absolute floor). `AISLOPDESK_ABR_SLACK_FRAC`.
    public static let rttSlackFraction: Double = envDouble("AISLOPDESK_ABR_SLACK_FRAC", 0.75, min: 0, max: 10)

    /// The effective absolute-slack gate for a given path baseline (see ``rttSlackFraction``).
    public static func effectiveSlackMillis(minRTTMillis: Double) -> Double {
        guard minRTTMillis.isFinite else { return rttSlackMillis }
        return max(rttSlackMillis, rttSlackFraction * minRTTMillis)
    }

    /// CONSECUTIVE inflated reports required before the RTT path decreases (~N × 50ms). `AISLOPDESK_ABR_RTT_N`.
    public static let rttStreakTicks: Int = envInt("AISLOPDESK_ABR_RTT_N", 3, min: 1, max: 100_000)
    /// Reports between ANY multiplicative decreases — RTT-path AND loss-path (~8 × 50ms ≈ 400ms).
    /// DELAY-TARGETING (2026-06-11): the full `holdTicks` (~1s) between RTT decreases was the right
    /// anti-cascade guard for a FIXED ×0.85 step, but it also meant a REAL persistent queue (scroll
    /// demand > path capacity, measured live: RTT p90 80ms during scroll vs 11ms idle on the
    /// FPT↔Viettel path) drained at one small step per second — multi-second 50–100ms latency
    /// episodes. The decrease is now PROPORTIONAL to the measured queue (see ``onReport``), so the
    /// EWMA-tail cascade this hold guarded against is self-limiting (a draining queue yields factors
    /// → ``rttDecreaseCapFactor``); a shorter re-decrease spacing lets the controller actually chase
    /// a real queue. The streak also resets on every decrease, so each RTT re-decrease needs a FRESH
    /// `rttStreakTicks` run of inflated reports.
    /// CUT-CASCADE FIX (2026-06-11, was `rttHoldTicks`): the LOSS path now shares this spacing — a
    /// multi-report weather burst costs ONE cut per window, not one per report (see type doc).
    /// `AISLOPDESK_ABR_CUT_HOLD`.
    public static let cutHoldTicks: Int = envInt("AISLOPDESK_ABR_CUT_HOLD", 8, min: 0, max: 100_000)
    /// Hardest single proportional RTT decrease (0.6 = at most −40% in one step). `AISLOPDESK_ABR_RTT_DEC_MIN`.
    public static let rttDecreaseFloorFactor: Double = envDouble(
        "AISLOPDESK_ABR_RTT_DEC_MIN",
        0.6,
        min: 0.05,
        max: 0.999,
    )
    /// Gentlest proportional RTT decrease — barely-over-threshold inflation still trims a little
    /// (0.95 = −5%), and the post-congestion EWMA decay tail can never re-cut deeply. `AISLOPDESK_ABR_RTT_DEC_MAX`.
    public static let rttDecreaseCapFactor: Double = envDouble(
        "AISLOPDESK_ABR_RTT_DEC_MAX",
        0.95,
        min: 0.05,
        max: 0.999,
    )
    /// Additive-increase divisor applied ON TOP of ``increaseDivisor`` at/above the remembered knee
    /// (ssthresh): climbing back INTO the rate that just built a queue should be slow (probe), while
    /// recovery below it stays fast. 8 ⇒ ~0.4% of ceiling per tick above the knee. `AISLOPDESK_ABR_KNEE_DIV`.
    public static let kneeCautionDivisor: Int = envInt("AISLOPDESK_ABR_KNEE_DIV", 8, min: 1, max: 100_000)
    /// Reports the knee memory survives without a fresh queue-corroborated decrease (~1200 × 50ms ≈
    /// 60s). Path conditions drift; a stale knee must not cap the climb forever. `AISLOPDESK_ABR_KNEE_TTL`.
    public static let kneeTTLTicks: Int = envInt("AISLOPDESK_ABR_KNEE_TTL", 1200, min: 1, max: 1_000_000)
    /// Floor as a fraction of the ceiling (also clamped to ``LiveBitratePolicy/minimumBitrate``). `AISLOPDESK_ABR_MINFRAC`.
    public static let minFrac: Double = envDouble("AISLOPDESK_ABR_MINFRAC", 0.25, min: 0.01, max: 1.0)
    /// Actuation churn gate (fraction of ceiling): the host skips a re-actuation smaller than this. `AISLOPDESK_ABR_MATERIAL`.
    public static let materialFraction: Double = envDouble("AISLOPDESK_ABR_MATERIAL", 0.05, min: 0.0, max: 1.0)
    /// Actuation churn gate (absolute bps floor): the host skips a re-actuation smaller than this. `AISLOPDESK_ABR_MATERIAL_FLOOR`.
    public static let materialFloorBps: Int = envInt(
        "AISLOPDESK_ABR_MATERIAL_FLOOR",
        500_000,
        min: 0,
        max: 1_000_000_000,
    )
    /// DELAY-GRADIENT EARLY CUT (component 3) — DEFAULT OFF until the HW feel-test (repo convention:
    /// two prior delay designs were falsified live by rate-independent 4G wobble). `AISLOPDESK_ABR_GRAD=1`
    /// enables on the host; the client-side estimator + wire fields are pure telemetry and default ON.
    public static let gradientCutEnabledDefault = ProcessInfo.processInfo.environment["AISLOPDESK_ABR_GRAD"] == "1"
    /// Multiplicative factor for a gradient-authorized cut. 0.85 = GCC overuse beta (libwebrtc
    /// AimdRateControl), same depth as the loss path — one early conventional cut, then the
    /// proportional path sizes any standing queue. `AISLOPDESK_ABR_GRAD_DEC`.
    public static let gradientDecreaseFactor: Double = envDouble("AISLOPDESK_ABR_GRAD_DEC", 0.85, min: 0.05, max: 0.999)

    // MARK: State (all value-type ⇒ auto Equatable / Sendable)

    /// The ``LiveBitratePolicy/targetBitrate(pixelWidth:pixelHeight:fps:floor:)`` result for THIS
    /// encoder build — the hard upper bound the controller can never exceed.
    public let ceiling: Int
    /// The lowest the controller may drive the live rate. Always ≥ ``LiveBitratePolicy/minimumBitrate``
    /// (≥ 1 Mbps) ⇒ NEVER 0, and ≤ `ceiling`.
    public let floor: Int
    /// Whether the delay-gradient early-cut path is armed (see ``gradientCutEnabledDefault``).
    /// INSTANCE-level (injected at construction, env default in production) so the loopback harness
    /// and tests can A/B both arms in one process without env games.
    public let gradientCutEnabled: Bool
    /// Current target bitrate (bps). Seeded to `ceiling` (open-loop start = today's behaviour).
    public private(set) var current: Int
    /// Folded-report count — the controller's "clock" (see type doc).
    public private(set) var ticks = 0
    /// No increase is permitted until `ticks` reaches this (set on every decrease).
    public private(set) var holdUntilTick = 0
    /// Consecutive reports whose smoothed RTT cleared BOTH inflation gates (factor + slack). The RTT
    /// path may decrease only once this reaches ``rttStreakTicks`` — one noisy report never acts.
    /// Reset on EVERY decrease, so each re-decrease needs a fresh sustained run.
    public private(set) var rttInflatedStreak = 0
    /// No multiplicative decrease (RTT-path OR loss-path) is permitted until `ticks` reaches this
    /// (set on every decrease) — the short re-decrease spacing (see ``cutHoldTicks``), distinct from
    /// the long increase hold-down. The catastrophic branch keeps its own stronger `holdUntilTick`.
    public private(set) var cutHoldUntilTick = 0
    /// The previous report's smoothed RTT — the one-report delay TREND. An RTT-path decrease
    /// additionally requires the smoothed RTT to be NOT IMPROVING (within 1ms) vs the last report:
    /// a queue that is already DRAINING (rate is under capacity, the level is just the backlog
    /// flushing out) must not keep triggering cuts — that was the measured undershoot-to-the-floor
    /// while a ~900ms warmup backlog drained. A standing or growing queue reads flat/rising and
    /// keeps cutting. (This is the sound version of the abandoned per-report `owdGradientRising`
    /// coin-flip: smoothed-EWMA vs smoothed-EWMA, not jitter-sample vs jitter-sample.)
    public private(set) var prevSmoothedRTTMillis = 0.0
    /// The remembered "knee" (ssthresh): the rate the controller landed on after the most recent
    /// queue-corroborated decrease. Additive increase at/above this rate uses the cautious step
    /// (÷``kneeCautionDivisor``) — the controller hovers under the rate that built a queue instead of
    /// re-bashing the ceiling every recovery (the measured 25↔40Mbps pumping). `nil` = no knee known.
    public private(set) var kneeBps: Int?
    /// Tick at which the knee memory expires (refreshed by every queue-corroborated decrease).
    ///
    /// NOTE (2026-06-11): an "escalating caution" variant — doubling the above-knee divisor per
    /// knee re-confirmation (÷8→÷16→÷32→÷64) — was built, deployed and REVERTED the same day.
    /// Two live 4G sessions falsified it: cellular RTT wobble (p50 46 → p90 68ms) is largely
    /// rate-INDEPENDENT (identical profile at 3M and 11.5M), so each wobble trims −5% and resets
    /// the hold; any climb slower than the base ÷8 (~0.94M/s at a 12M ceiling) cannot cross the
    /// material-actuation gap between wobble cuts and the rate PINS near the floor (3.45M for 91%
    /// of a session, soft image, zero latency benefit). The constant ÷8 caution rides through the
    /// wobble and breathes 3–11M — measurably better quality at the same RTT. Keep the knee simple.
    public private(set) var kneeExpiresAtTick = 0

    /// Additive-increase step in bps (≥ 1 so a tiny ceiling still makes progress).
    private var increaseStep: Int { max(1, ceiling / Self.increaseDivisor) }

    // MARK: Init

    /// Primary initialiser. `floor` is clamped to `[minimumBitrate, ceiling]` so the controller can
    /// never drive the rate to 0 nor below a usable minimum. `current` starts AT `ceiling`.
    /// `gradientCutEnabled` defaults to the env gate — production passes nothing.
    public init(ceiling: Int, floor: Int, gradientCutEnabled: Bool = Self.gradientCutEnabledDefault) {
        let c = max(1, ceiling)
        self.ceiling = c
        self.floor = max(LiveBitratePolicy.minimumBitrate, min(floor, c))
        current = c
        self.gradientCutEnabled = gradientCutEnabled
    }

    /// Convenience: derive the floor from `ceiling × minFrac` (the production wiring), keeping the
    /// floor-derivation policy in one place.
    public init(ceiling: Int, gradientCutEnabled: Bool = Self.gradientCutEnabledDefault) {
        self.init(
            ceiling: ceiling,
            floor: Int(Double(max(1, ceiling)) * Self.minFrac),
            gradientCutEnabled: gradientCutEnabled,
        )
    }

    // MARK: Control law

    /// CUT-REASON ATTRIBUTION (fix 4, 2026-06-11 telemetry round — observability only, zero
    /// behaviour change): WHY the controller moved (or held) this tick, carried on the returned
    /// ``Decision`` so the host's `abr: actuate` debug line can attribute a cut to its trigger —
    /// without it the gradient path's (`AISLOPDESK_ABR_GRAD`) efficacy is unmeasurable from logs.
    public enum CutReason: String, Sendable, Equatable {
        /// Cold-start guard — no action possible.
        case warmup
        /// No branch fired (sub-threshold / hold-down) — target unchanged.
        case hold
        /// RTT inflated with a satisfied streak + expired cut-hold, but the smoothed RTT is
        /// IMPROVING — the drain gate held the cut (the queue is already flushing).
        case drain
        /// Additive increase (the normal probe step toward the ceiling).
        case probe
        /// Additive increase at/above the remembered knee — the cautious (÷kneeCautionDivisor) step.
        case knee
        /// Proportional RTT (delay-targeting) cut — sustained smoothed-RTT inflation streak.
        case rttStreak
        /// Loss-corroborated cut — raw loss over the threshold WITH RTT-inflation evidence.
        case lossCorroborated
        /// Delay-gradient early cut — client trendline OVERUSING + raw-RTT corroboration.
        case gradient
        /// EWMA-keyed catastrophic halve (sustained ≥ catastrophic loss).
        case catastrophic
    }

    /// One control-law tick's outcome: the new target plus why. Pure data — printing happens at
    /// the host's existing debug-log site.
    public struct Decision: Sendable, Equatable {
        public let target: Int
        public let reason: CutReason
        public init(target: Int, reason: CutReason) {
            self.target = target
            self.reason = reason
        }
    }

    /// Folds one network estimate and returns the (possibly unchanged) new target bitrate.
    /// Compatibility wrapper over ``decide(_:)`` — every pre-fix-4 call site keeps its shape.
    @discardableResult
    public mutating func onReport(_ e: NetworkEstimate) -> Int {
        decide(e).target
    }

    /// Folds one network estimate and returns the new target bitrate PLUS the attributed reason
    /// (fix 4). When several cut branches fire on one report the reason names the branch that set
    /// the FINAL (lowest) target; on a tie the stronger evidence wins (rttStreak > lossCorroborated
    /// > gradient — the code order below).
    ///
    /// Decision order: warmup → severe-loss halve → ordinary-congestion multiplicative decrease →
    /// (past hold-down) additive increase. The result is ALWAYS within `[floor, ceiling]`.
    @discardableResult
    public mutating func decide(_ e: NetworkEstimate) -> Decision {
        ticks += 1
        // Capture the trend input for the NEXT report whatever branch runs (including warmup).
        defer { prevSmoothedRTTMillis = e.smoothedRTTMillis }
        // Cold-start guard: fold (advance `ticks`) but take no action, so an open-loop start with
        // `loss == 0` cannot trigger a spurious drop and the estimate's own gradient can warm up.
        guard ticks >= Self.warmupTicks else { return Decision(target: current, reason: .warmup) }

        // Positive-evidence congestion ONLY (never decrease on absence-of-data): loss over the gate,
        // OR a finite RTT baseline inflated past it WITH a rising OWD gradient (queue build-up).
        //
        // LOSS uses the RAW per-report sample (`lastLossSample`), NOT the EWMA-damped `lossRate`: the
        // EWMA's whole point is to lag, but here that lag is harmful — a single transient spike keeps
        // the damped value above the threshold for MANY subsequent reports, and since the decrease
        // branches fire on EVERY report over the threshold (the hold-down gates only the INCREASE),
        // one blip would cascade into a multi-step drop on otherwise perfectly-clean reports. Keying
        // on the raw sample means a clean report (raw loss 0) never decreases, so a spike costs exactly
        // ONE decrease + the hold-down — react-fast, recover-slow AIMD without the EWMA-tail cascade.
        // RTT path (see STABILITY MITIGATIONS): BOTH inflation gates (multiplicative factor AND
        // absolute slack), SUSTAINED for `rttStreakTicks` consecutive reports, AND past the
        // hold-down (the EWMA-decay anti-cascade cooldown — max one RTT decrease per `holdTicks`).
        // `owdGradientRising` is deliberately ignored: adjacent-sample jitter comparison is a coin
        // flip on a steady link, not congestion evidence.
        let slack = Self.effectiveSlackMillis(minRTTMillis: e.minRTTMillis)
        let rttInflated = e.minRTTMillis.isFinite
            && e.smoothedRTTMillis > e.minRTTMillis * Self.rttInflateFactor
            && e.smoothedRTTMillis > e.minRTTMillis + slack
        rttInflatedStreak = rttInflated ? rttInflatedStreak + 1 : 0
        let rttCongested = rttInflated
            && rttInflatedStreak >= Self.rttStreakTicks
            && ticks >= cutHoldUntilTick
            && e.smoothedRTTMillis + 1.0 >= prevSmoothedRTTMillis // not improving — see prevSmoothedRTTMillis

        // Knee TTL: a knee that hasn't been re-confirmed by a queue-corroborated decrease within
        // `kneeTTLTicks` is stale path knowledge — forget it so the climb is uncapped again.
        if kneeBps != nil, ticks >= kneeExpiresAtTick { kneeBps = nil }

        // LOSS-TOLERANCE #4: sub-catastrophic loss acts only when CORROBORATED by RTT inflation on
        // the same report (queue evidence). Weather loss — the measured rate-independent ~1%/3–9%
        // bursts at FLAT RTT — is handled by FEC/LTR/kfDup, not by giving up bitrate.
        let lossEvidence = !Self.lossNeedsRTTCorroboration || rttInflated
        // CUT-CASCADE FIX (2026-06-11): the loss path shares the `cutHoldTicks` spacing — the first
        // cut of an episode is immediate (the hold starts expired), but a weather burst spanning
        // several consecutive lossy reports costs ONE cut per window, never a per-report cascade.
        let lossCongested = e.lastLossSample > Self.lossThreshold && lossEvidence
            && ticks >= cutHoldUntilTick
        // DELAY-GRADIENT EARLY CUT (component 3): ONE report suffices. Trend evidence (the client
        // trendline reads OVERUSING — monotone delay growth over a full regression window, sustained
        // past its adaptive threshold) + fresh LEVEL evidence (THIS report's RAW RTT sample past the
        // same factor+slack gates the smoothed path uses — raw reflects the queue NOW, no EWMA lag,
        // no streak). Shares the `cutHoldTicks` spacing with every other cut: the FIRST cut of an
        // episode is immediate (the hold starts expired), and a persisting gradient re-cuts at most
        // once per window — the cut-cascade fix invariant extends, never regresses.
        let rawRTTInflated: Bool = {
            guard let raw = e.lastRTTSampleMillis, e.minRTTMillis.isFinite else { return false }
            return raw > e.minRTTMillis * Self.rttInflateFactor && raw > e.minRTTMillis + slack
        }()
        let gradientCongested = gradientCutEnabled && e.owdTrendOverusing && rawRTTInflated
            && ticks >= cutHoldUntilTick
        if e.lossRate > Self.catastrophicLossThreshold,
           e.lastLossSample > Self.severeLossThreshold,
           ticks >= holdUntilTick
        {
            // SUSTAINED catastrophic loss (EWMA over the gate AND the CURRENT raw sample still
            // severe — the collapse is happening now, not the decaying tail of one that ended):
            // halve regardless of RTT (queue-less policer / true collapse), at most once per
            // hold-down window.
            decrease(to: max(floor, Int(Double(current) * Self.severeDecreaseFactor)), queueCorroborated: rttInflated)
            return Decision(target: current, reason: .catastrophic)
        }
        if rttCongested || lossCongested || gradientCongested {
            // Ordinary congestion. DELAY-TARGETING (2026-06-11): the RTT path sizes the decrease to
            // the MEASURED queue instead of a fixed ×0.85 — `factor = (minRTT + slack) / smoothedRTT`,
            // clamped to [rttDecreaseFloorFactor, rttDecreaseCapFactor]. A 70ms standing queue over a
            // 10ms baseline cuts hard in ONE step (clamped −40%) instead of bleeding 50–100ms latency
            // through four ×0.85-per-second steps; barely-over-threshold inflation (and the EWMA
            // decay tail after the queue drains) trims at most −5% per step. The loss path keeps the
            // classic ×0.85. When both fire, take the stronger evidence (lower target).
            //
            // NOTE (CUT-CASCADE FIX): there is deliberately NO raw-sample "severe → halve" step here
            // any more — at ~3 frames per report one lost frame reads 33%, so raw severity is
            // quantization noise. Depth comes from the measured queue; collapse from the EWMA gate.
            var target = Int.max
            var reason = CutReason.hold // overwritten below — at least one branch fired to get here
            if rttCongested {
                // Drain target uses the SAME baseline-proportional slack as the gate, so the
                // proportional cut sizes against the path's own wobble floor, not the LAN constant.
                let drained = e.minRTTMillis + slack
                let factor = min(
                    Self.rttDecreaseCapFactor,
                    max(Self.rttDecreaseFloorFactor, drained / e.smoothedRTTMillis),
                )
                let cut = Int(Double(current) * factor)
                if cut < target { target = cut
                    reason = .rttStreak
                }
            }
            if lossCongested {
                let cut = Int(Double(current) * Self.decreaseFactor)
                if cut < target { target = cut
                    reason = .lossCorroborated
                }
            }
            if gradientCongested {
                // The early-onset reflex: one conventional ×0.85-deep cut. NOTE the unchanged
                // `queueCorroborated: rttInflated` below — a gradient-ONLY cut (smoothed not yet
                // inflated ⇒ `rttInflated` false) deliberately sets NO knee: an onset reflex is not
                // capacity knowledge, and knee-pinning from early cuts would cap the climb for
                // `kneeTTLTicks` on the measured rate-independent 4G/inter-ISP wobble (the
                // falsified-design history). The proportional path sets it if the queue is real.
                let cut = Int(Double(current) * Self.gradientDecreaseFactor)
                if cut < target { target = cut
                    reason = .gradient
                }
            }
            decrease(to: max(floor, target), queueCorroborated: rttInflated)
            return Decision(target: current, reason: reason)
        }
        if ticks >= holdUntilTick, !rttInflated, !(gradientCutEnabled && e.owdTrendOverusing) {
            // Clean link past the hold-down: probe up additively toward the ceiling. `!rttInflated`
            // keeps the probe from climbing INTO a building queue while the streak/hold-down is
            // still suppressing the decrease (minRTT re-baselines upward ~1%/fold, so a genuinely
            // shifted path baseline un-sticks this on its own). Component 3 adds the trend guard
            // (gated on the same flag for A/B purity): never probe up INTO a detected overuse while
            // `cutHoldUntilTick` is still blocking the gradient cut — the estimator un-latches
            // within one window when the slope flattens, so this can never pin the rate. At/above
            // the remembered knee the
            // step is divided by `kneeCautionDivisor`: the controller hovers under the rate that
            // built a queue instead of re-bashing it every recovery (25↔40Mbps pumping = the felt
            // sawtooth).
            let cautious = kneeBps.map { current >= $0 } ?? false
            let step = cautious ? max(1, increaseStep / Self.kneeCautionDivisor) : increaseStep
            current = min(ceiling, current + step)
            return Decision(target: current, reason: cautious ? .knee : .probe)
        }
        // No action this tick. Attribute the DRAIN gate when it is the only thing that held an
        // otherwise fully-armed RTT cut (inflated + streak + cut-hold expired, but improving).
        let drainGated = rttInflated
            && rttInflatedStreak >= Self.rttStreakTicks
            && ticks >= cutHoldUntilTick
            && e.smoothedRTTMillis + 1.0 < prevSmoothedRTTMillis
        return Decision(target: current, reason: drainGated ? .drain : .hold)
    }

    /// Applies a computed decrease target and arms the anti-thrash hold-downs — but ONLY re-arms them
    /// when the target actually LOWERS `current`. At the floor the decrease is a no-op
    /// (`next == current`), so without this guard a sustained congestion signal pinned at the floor
    /// would keep extending the hold-down every report, pushing the additive-recovery start far past
    /// the actual congestion and inflating dead time at the floor.
    ///
    /// `queueCorroborated` (the report showed RTT inflation) additionally records the landed-on rate
    /// as the knee (ssthresh) — see ``kneeBps``. A catastrophic halve at FLAT RTT is rate-independent
    /// weather/policer evidence, not path-capacity knowledge, so it deliberately sets no knee.
    private mutating func decrease(to next: Int, queueCorroborated: Bool) {
        if next < current {
            current = next
            holdUntilTick = ticks + Self.holdTicks
            cutHoldUntilTick = ticks + Self.cutHoldTicks
            rttInflatedStreak = 0
            if queueCorroborated {
                kneeBps = current
                kneeExpiresAtTick = ticks + Self.kneeTTLTicks
            }
        }
    }

    // MARK: Actuation churn gate (pure — used by the host, unit-tested here)

    /// Whether a target change is large enough to be worth a VTSessionSetProperty round-trip. The host
    /// throttles actuation to MATERIAL moves (≥ `materialFraction` of the ceiling OR ≥ `materialFloorBps`)
    /// so a single ~3%-of-ceiling additive tick does not actuate every 50ms; consecutive additive ticks
    /// accumulate against the last ACTUATED rate and cross the gate after a couple of reports.
    public static func isMaterialChange(previous: Int, target: Int, ceiling: Int) -> Bool {
        abs(target - previous) >= max(materialFloorBps, Int(Double(max(1, ceiling)) * materialFraction))
    }

    // MARK: Env parsing helpers

    private static func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Int(s), v >= lo,
              v <= hi else { return fallback }
        return v
    }

    private static func envDouble(_ key: String, _ fallback: Double, min lo: Double, max hi: Double) -> Double {
        guard let s = ProcessInfo.processInfo.environment[key], let v = Double(s), v >= lo,
              v <= hi else { return fallback }
        return v
    }
}
