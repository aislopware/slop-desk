import CSlopDeskFFI
import SlopDeskVideoProtocol

/// PURE AIMD congestion controller for the live HEVC stream (adaptive bitrate).
///
/// Consumes the clock-skew-free ``NetworkEstimate`` (RTT / loss / OWD-gradient, folded by the host
/// from the client's periodic ``NetworkStatsReport``) and decides a new live target bitrate, which the
/// host actuates via ``VideoEncoder/setLiveBitrate(_:)`` (AverageBitRate + DataRateLimits together).
/// Clamped to the ``LiveBitratePolicy`` ceiling and a sane floor.
///
/// SHAPE: Additive-Increase / Multiplicative-Decrease (AIMD). On congestion (loss over threshold, or
/// RTT inflated above baseline WITH a rising OWD gradient) the target DROPS multiplicatively (fast
/// back-off); on a clean link past a hold-down window it CLIMBS additively (slow probe toward the
/// ceiling). Severe loss halves immediately.
///
/// PURE + DETERMINISTIC: no wall-clock, no I/O, no reference capture. "Time" is the count of folded
/// reports (`ticks`) — ~one report per 50ms, so `warmupTicks`/`holdTicks` are report-counts, not
/// seconds. Ceiling/floor are injected at construction (re-seeded per encoder build so a resize
/// re-anchors to the new resolution's ceiling). The policy is unit-testable in isolation; the HW-gated
/// ``VideoEncoder`` it drives is never instantiated in a test.
///
/// STABILITY MITIGATIONS (baked in so AIMD cannot thrash on a transient spike):
///  - Loss decisions key on the RAW per-report sample (``NetworkEstimate/lastLossSample``), NOT the
///    EWMA-damped ``NetworkEstimate/lossRate`` — a single transient spike costs exactly ONE decrease,
///    never a cascade on the EWMA's slowly-decaying tail (a clean report reads raw loss 0 ⇒ no
///    decrease). The EWMA `lossRate` is kept for logging/telemetry trend only.
///  - A controller-LOCAL warmup (`warmupTicks`, ~500ms) suppresses ALL action at cold start, so a
///    `loss == 0` open-loop start can never trigger a spurious drop.
///  - A `lossThreshold` gate (not "any loss") + a hold-down (`holdTicks`, ~1s), RE-ARMED only when a
///    decrease actually lowers the rate (a no-op decrease at the floor does not extend it), suppress
///    re-increase thrash without inflating dead time at the floor.
///  - Recovery is deliberately slow (additive `ceiling / increaseDivisor` per tick).
///  - The RTT path needs an ABSOLUTE slack (`rttSlackMillis`) on top of the multiplicative
///    `rttInflateFactor`: on a low-latency LAN (minRTT ≈ 5ms) the ×1.25 threshold is ~6ms — pure
///    scheduling noise (smoothedRTT wobbles 7–12ms) trips it permanently. Real queue build-up is tens
///    of ms of ABSOLUTE inflation; +15ms slack hides sub-slack wobble while a long-baseline WAN path
///    (minRTT 50ms+) is still governed by the multiplicative factor.
///  - The RTT signal must be SUSTAINED (`rttStreakTicks` consecutive inflated reports, ~150ms) before
///    it may decrease — a one-report blip never acts. The per-report `owdGradientRising` flag is
///    deliberately NOT consulted: it compares only two adjacent jitter samples, so on a steady link it
///    flaps ~50/50 (measured live) — a coin flip, not a signal.
///  - RTT-triggered decreases are PROPORTIONAL to the measured queue (DELAY-TARGETING):
///    `factor = (minRTT + slack) / smoothedRTT` clamped to `[rttDecreaseFloorFactor,
///    rttDecreaseCapFactor]` — a large standing queue cuts hard in one step, the post-congestion EWMA
///    decay tail trims at most −5%, so a "×0.85 every 50ms to the floor" cascade is structurally
///    impossible; the RTT path may re-decrease on the SHORT `cutHoldTicks` spacing (fresh streak each
///    time) instead of the full increase hold-down.
///  - ONE MULTIPLICATIVE CUT PER `cutHoldTicks` WINDOW — loss cuts included. A loss branch that fires
///    on EVERY report over the threshold cascades: measured inter-ISP weather bursts span 2-10
///    consecutive ~50ms reports, so one 130ms burst drops 29M→14M→floor in 2 ticks (31 such drops in a
///    4-minute session) while FEC recovers every lost frame (cutting buys nothing). Cut once per
///    WINDOW, not once per loss — the first cut of an episode is still immediate; a burst persisting
///    past ~400ms cuts again.
///  - NO "severe raw-sample" fast-halve: the ~50ms report window holds only ~3 frames, so ONE lost
///    frame reads as a 33% raw sample — quantization noise, not severity. The depth of a corroborated
///    cut comes from the MEASURED QUEUE (proportional RTT sizing) with the classic ×0.85 as the
///    loss-path step; a true collapse is the EWMA-keyed catastrophic halve, needing ~300ms of
///    sustained ≥50% loss to arm.
///  - A queue-corroborated decrease remembers the landed-on rate as the KNEE (ssthresh, `kneeBps`):
///    additive increase at/above it runs ÷`kneeCautionDivisor` so recovery hovers under the rate that
///    built the queue instead of re-bashing it every second (the felt 25↔40Mbps pumping). The knee
///    expires after `kneeTTLTicks` without re-confirmation — path conditions drift.
///  - DELAY-GRADIENT EARLY CUT (default OFF — `SLOPDESK_ABR_GRAD=1`): the client's libwebrtc-style
///    trendline (per-FRAME OWD slope, adaptive threshold, sustained overuse) ships its verdict in every
///    report; when it reads OVERUSING **and** the SAME report's RAW RTT sample clears the factor+slack
///    gates (fresh level evidence — no EWMA lag, no streak), ONE multiplicative
///    ×`gradientDecreaseFactor` cut is authorized after a single report (~100-170ms from onset vs
///    ~250-300ms for the smoothed path). It shares `cutHoldTicks` spacing with every other cut (the
///    cut-cascade invariant extends, never regresses), sets NO knee (an onset reflex is not capacity
///    knowledge — the proportional path sets it if the queue is real), and while overuse is detected
///    the additive probe is suppressed (never climb INTO a detected overuse during the cut hold).
///
/// SAFE WHEN TELEMETRY OFF: with `loss == 0` and no valid RTT (`minRTTMillis == .infinity`) the
/// congestion predicate is always false, so the controller can only additively increase — but it
/// starts AT the ceiling and is clamped there ⇒ a no-op. It NEVER decreases on absence-of-data, only
/// on positive evidence. Inert and byte-identical in every telemetry-off permutation.
///
/// THE LAW ITSELF LIVES BEHIND THE DOOR. Everything above describes what `slopdesk_abr_decide` does;
/// what stays here is the part that is genuinely the host's — resolving every `SLOPDESK_ABR_*` knob
/// through the overlay-aware ``EnvConfig`` (validate-then-default), naming the branches for the debug
/// log, and holding the state between reports. The state crosses BY VALUE, whole, on every call:
/// this is a `struct` its owner copies, and a handle would alias two values the type system says are
/// separate.
public struct LiveCongestionController: Sendable, Equatable {
    // MARK: Tunables (env-overridable SLOPDESK_ABR_*)

    /// The defaults, spelled ONCE — on the far side, next to the law that reads them. Every static
    /// below falls back to a field of this rather than to a literal, so a default can never be
    /// changed in one language and not the other.
    private static let defaults = slopdesk_abr_config_default()

    /// Reports to fold before ANY action — the cold-start guard (~10 × 50ms ≈ 500ms). `SLOPDESK_ABR_WARMUP`.
    public static let warmupTicks: Int = envInt(
        "SLOPDESK_ABR_WARMUP",
        Int(defaults.warmup_ticks),
        min: 0,
        max: 100_000,
    )
    /// RAW per-report loss sample above which the link is "congested" → multiplicative decrease
    /// (see the type doc on why the raw sample, not the EWMA). `SLOPDESK_ABR_LOSS`.
    public static let lossThreshold: Double = envDouble("SLOPDESK_ABR_LOSS", defaults.loss_threshold, min: 0, max: 1)
    /// Raw-sample gate the catastrophic halve ALSO requires: the halve needs a sustained EWMA collapse
    /// (``catastrophicLossThreshold``) AND a currently-hot report. `SLOPDESK_ABR_SEVERE`.
    public static let severeLossThreshold: Double = envDouble(
        "SLOPDESK_ABR_SEVERE",
        defaults.severe_loss_threshold,
        min: 0,
        max: 1,
    )
    /// LOSS TOLERANCE: loss below ``catastrophicLossThreshold`` decreases ONLY when CORROBORATED by RTT
    /// inflation (both gates of the RTT predicate on the same report). Measured on the real inter-ISP
    /// path (iperf3, 1200B datagrams): loss is ~0.6–1.1% at 5, 12 AND 30Mbps — rate-INDEPENDENT
    /// weather, with multi-second 3–9% burst episodes at FLAT RTT (jitter 0.3ms). Backing off cannot
    /// reduce that loss; it only degrades quality. Loss WITH RTT inflation = a building queue = real
    /// congestion → the classic AIMD response stays. `SLOPDESK_ABR_LOSS_NEEDS_RTT=0` disables.
    public static let lossNeedsRTTCorroboration = EnvConfig.boolDefaultOn("SLOPDESK_ABR_LOSS_NEEDS_RTT")
    /// EWMA loss-rate above THIS halves even at flat RTT: a queue-less policer / true link collapse
    /// drops without inflating RTT, and at a SUSTAINED ≥25% the stream is unusable regardless of
    /// cause. Keyed on the EWMA ``NetworkEstimate/lossRate`` (NOT the raw sample) deliberately: the
    /// ~50ms report window holds only ~3 frames, so ONE dropped frame reads as a 33% raw sample —
    /// weather, not collapse. The EWMA (alpha 0.125) needs ~6 consecutive ≥50%-loss reports (~300ms of
    /// true collapse) to cross 0.25, while a single spike moves it ≤12.5%. Gated on the hold-down so
    /// the decaying EWMA tail after collapse cannot cascade halvings to the floor.
    /// `SLOPDESK_ABR_CATASTROPHIC`.
    public static let catastrophicLossThreshold: Double = envDouble(
        "SLOPDESK_ABR_CATASTROPHIC",
        defaults.catastrophic_loss_threshold,
        min: 0,
        max: 1,
    )
    /// Multiplicative decrease factor on ordinary congestion (0.85 = drop to 85%). `SLOPDESK_ABR_DEC`.
    public static let decreaseFactor: Double = envDouble(
        "SLOPDESK_ABR_DEC",
        defaults.decrease_factor,
        min: 0.05,
        max: 0.999,
    )
    /// Multiplicative decrease factor on the catastrophic branch (0.5 = halve). `SLOPDESK_ABR_SEVERE_DEC`.
    public static let severeDecreaseFactor: Double = envDouble(
        "SLOPDESK_ABR_SEVERE_DEC",
        defaults.severe_decrease_factor,
        min: 0.05,
        max: 0.999,
    )
    /// Additive-increase step = `ceiling / increaseDivisor` per clean tick (32 ⇒ ~3% of ceiling). `SLOPDESK_ABR_INC_DIV`.
    public static let increaseDivisor: Int = envInt(
        "SLOPDESK_ABR_INC_DIV",
        Int(defaults.increase_divisor),
        min: 1,
        max: 100_000,
    )
    /// Minimum fraction of `current` the stream must actually be USING (offered encoded throughput)
    /// before the controller probes higher. Below it the stream is APPLICATION-limited (idle / near-
    /// static screen — "scroll-up-at-top, only the cursor blinks") so probing only inflates phantom
    /// headroom that a later burst overshoots into bufferbloat (RTT 90-110ms on a 5ms LAN) → the
    /// "scroll-down-hard → blur + lag" failure. Only consulted when the host supplies a utilization
    /// signal (`decide(_:offeredBps:)`); the no-signal path is unaffected. `SLOPDESK_ABR_RAMP_UTIL`.
    public static let rampUtilizationFraction: Double = envDouble(
        "SLOPDESK_ABR_RAMP_UTIL",
        defaults.ramp_utilization_fraction,
        min: 0,
        max: 1,
    )
    /// Fraction of `current` below which the stream is DEEPLY idle → the target DECAYS toward offered
    /// (stricter than ``rampUtilizationFraction`` so a brief flick-pause holds but a sustained static
    /// screen shrinks the target, preventing a post-idle burst forming a VBR monster frame).
    /// `SLOPDESK_ABR_DECAY_UTIL`.
    public static let decayUtilizationFraction: Double = envDouble(
        "SLOPDESK_ABR_DECAY_UTIL",
        defaults.decay_utilization_fraction,
        min: 0,
        max: 1,
    )
    /// While idle the target decays toward `offered × this` (headroom above the measured use).
    /// `SLOPDESK_ABR_DECAY_HEADROOM`.
    public static let decayHeadroom: Double = envDouble(
        "SLOPDESK_ABR_DECAY_HEADROOM",
        defaults.decay_headroom,
        min: 1,
        max: 100,
    )
    /// Geometric fraction of the gap to the decay target per idle tick. `SLOPDESK_ABR_DECAY_STEP`.
    public static let decayStepFraction: Double = envDouble(
        "SLOPDESK_ABR_DECAY_STEP",
        defaults.decay_step_fraction,
        min: 0,
        max: 1,
    )
    /// Reports to suppress any increase after a decrease — the anti-thrash hold-down (~20 × 50ms ≈ 1s). `SLOPDESK_ABR_HOLD`.
    public static let holdTicks: Int = envInt("SLOPDESK_ABR_HOLD", Int(defaults.hold_ticks), min: 0, max: 100_000)
    /// `smoothedRTT > minRTT × rttInflateFactor` (AND past the absolute slack) signals queue build-up. `SLOPDESK_ABR_RTT`.
    public static let rttInflateFactor: Double = envDouble(
        "SLOPDESK_ABR_RTT",
        defaults.rtt_inflate_factor,
        min: 1.0,
        max: 100,
    )
    /// ABSOLUTE smoothed-RTT inflation over the baseline (ms) ALSO required before the RTT path may
    /// signal congestion — keeps LAN scheduling wobble (a few ms on a ~5ms baseline) sub-threshold. `SLOPDESK_ABR_SLACK`.
    public static let rttSlackMillis: Double = envDouble(
        "SLOPDESK_ABR_SLACK",
        defaults.rtt_slack_millis,
        min: 0,
        max: 10000,
    )
    /// BASELINE-PROPORTIONAL slack (cellular wobble): effective slack is
    /// `max(rttSlackMillis, slackFraction × minRTT)`. The fixed 15ms suits ~5-10ms LAN baselines, but
    /// on the measured 4G path (minRTT ≈ 40-44ms) cellular scheduler wobble of ±50% is RATE-INDEPENDENT
    /// path texture (identical at 3M and 11.5M actuated), and 44→60ms trips a bare `min+15` constantly
    /// → perpetual −5% trims pin the average at ~3.5M on a path carrying 8M+ (soft image, zero latency
    /// gain). 0.75 reclassifies the sub-`1.75×min` band as weather while a REAL queue (smoothed ≥
    /// ~1.75× baseline) still cuts; LAN/WiFi baselines are unaffected (0.75×10ms < 15ms absolute
    /// floor). `SLOPDESK_ABR_SLACK_FRAC`.
    public static let rttSlackFraction: Double = envDouble(
        "SLOPDESK_ABR_SLACK_FRAC",
        defaults.rtt_slack_fraction,
        min: 0,
        max: 10,
    )

    /// The effective absolute-slack gate for a given path baseline (see ``rttSlackFraction``):
    /// `max(rttSlackMillis, rttSlackFraction × minRTT)`, or `rttSlackMillis` for a non-finite baseline.
    ///
    /// The frame-rate governor's congestion predicate consults the SAME rule, which is why it is a
    /// free-standing entry rather than a step inside `decide` — the two controllers cannot drift
    /// apart on what "inflated" means.
    public static func effectiveSlackMillis(minRTTMillis: Double) -> Double {
        slopdesk_abr_effective_slack(config, minRTTMillis)
    }

    /// CONSECUTIVE inflated reports required before the RTT path decreases (~N × 50ms). `SLOPDESK_ABR_RTT_N`.
    public static let rttStreakTicks: Int = envInt(
        "SLOPDESK_ABR_RTT_N",
        Int(defaults.rtt_streak_ticks),
        min: 1,
        max: 100_000,
    )
    /// Reports between ANY multiplicative decreases — RTT-path AND loss-path (~8 × 50ms ≈ 400ms).
    /// A full `holdTicks` (~1s) spacing would be the right anti-cascade guard for a FIXED ×0.85 step,
    /// but a REAL persistent queue (scroll demand > path capacity, measured live: RTT p90 80ms during
    /// scroll vs 11ms idle on the FPT↔Viettel path) then drains at one small step per second —
    /// multi-second 50–100ms latency episodes. The decrease is PROPORTIONAL to the measured queue (see
    /// ``onReport``), so the EWMA-tail cascade a long hold guards against is self-limiting anyway (a
    /// draining queue yields factors → ``rttDecreaseCapFactor``); the shorter spacing lets the
    /// controller chase a real queue. The streak also resets on every decrease, so each RTT
    /// re-decrease needs a FRESH `rttStreakTicks` run of inflated reports. The LOSS path shares this
    /// spacing — a multi-report weather burst costs ONE cut per window, not one per report (see type
    /// doc). `SLOPDESK_ABR_CUT_HOLD`.
    public static let cutHoldTicks: Int = envInt(
        "SLOPDESK_ABR_CUT_HOLD",
        Int(defaults.cut_hold_ticks),
        min: 0,
        max: 100_000,
    )
    /// Hardest single proportional RTT decrease (0.6 = at most −40% in one step). `SLOPDESK_ABR_RTT_DEC_MIN`.
    public static let rttDecreaseFloorFactor: Double = envDouble(
        "SLOPDESK_ABR_RTT_DEC_MIN",
        defaults.rtt_decrease_floor_factor,
        min: 0.05,
        max: 0.999,
    )
    /// Gentlest proportional RTT decrease — barely-over-threshold inflation still trims a little
    /// (0.95 = −5%), and the post-congestion EWMA decay tail can never re-cut deeply. `SLOPDESK_ABR_RTT_DEC_MAX`.
    public static let rttDecreaseCapFactor: Double = envDouble(
        "SLOPDESK_ABR_RTT_DEC_MAX",
        defaults.rtt_decrease_cap_factor,
        min: 0.05,
        max: 0.999,
    )
    /// Additive-increase divisor applied ON TOP of ``increaseDivisor`` at/above the remembered knee
    /// (ssthresh): climbing back INTO the rate that just built a queue should be slow (probe), while
    /// recovery below it stays fast. 8 ⇒ ~0.4% of ceiling per tick above the knee. `SLOPDESK_ABR_KNEE_DIV`.
    public static let kneeCautionDivisor: Int = envInt(
        "SLOPDESK_ABR_KNEE_DIV",
        Int(defaults.knee_caution_divisor),
        min: 1,
        max: 100_000,
    )
    /// Reports the knee memory survives without a fresh queue-corroborated decrease (~1200 × 50ms ≈
    /// 60s). Path conditions drift; a stale knee must not cap the climb forever. `SLOPDESK_ABR_KNEE_TTL`.
    public static let kneeTTLTicks: Int = envInt(
        "SLOPDESK_ABR_KNEE_TTL",
        Int(defaults.knee_ttl_ticks),
        min: 1,
        max: 1_000_000,
    )
    /// Floor as a fraction of the ceiling (also clamped to ``LiveBitratePolicy/minimumBitrate``). `SLOPDESK_ABR_MINFRAC`.
    public static let minFrac: Double = envDouble("SLOPDESK_ABR_MINFRAC", defaults.min_fraction, min: 0.01, max: 1.0)
    /// Open-loop START fraction of `ceiling` for ``current`` (`SLOPDESK_ABR_SEED_FRAC`, DEFAULT 1.0 =
    /// start AT the ceiling — today's behaviour, byte-identical). `< 1` seeds BELOW the ceiling so the
    /// first heavy burst can't self-induce bufferbloat before the loop's first report/streak reacts
    /// (Parsec slow-starts ~2.6 Mbps and its window — not its target — bounds in-flight). The cost is a
    /// brief additive-increase ramp (softer image) at connect/resize, so keep 1.0 on a clean fast link
    /// where the resolution-derived ceiling is already link-plausible; lower it for a lossy/bufferbloaty
    /// WAN. Clamped `[minFrac, 1]`.
    public static let seedFraction: Double = envDouble(
        "SLOPDESK_ABR_SEED_FRAC",
        defaults.seed_fraction,
        min: minFrac,
        max: 1.0,
    )
    /// Actuation churn gate (fraction of ceiling): the host skips a re-actuation smaller than this. `SLOPDESK_ABR_MATERIAL`.
    public static let materialFraction: Double = envDouble(
        "SLOPDESK_ABR_MATERIAL",
        defaults.material_fraction,
        min: 0.0,
        max: 1.0,
    )
    /// Actuation churn gate (absolute bps floor): the host skips a re-actuation smaller than this. `SLOPDESK_ABR_MATERIAL_FLOOR`.
    public static let materialFloorBps: Int = envInt(
        "SLOPDESK_ABR_MATERIAL_FLOOR",
        Int(defaults.material_floor_bps),
        min: 0,
        max: 1_000_000_000,
    )
    /// DELAY-GRADIENT EARLY CUT — DEFAULT OFF until the HW feel-test: delay-keyed designs are the ones
    /// live 4G wobble (rate-independent) falsifies, so this one must earn its arm. `SLOPDESK_ABR_GRAD=1`
    /// enables on the host; the client-side estimator + wire fields are pure telemetry and default ON.
    public static let gradientCutEnabledDefault = EnvConfig.boolDefaultOff("SLOPDESK_ABR_GRAD")
    /// Multiplicative factor for a gradient-authorized cut. 0.85 = GCC overuse beta (libwebrtc
    /// AimdRateControl), same depth as the loss path — one early conventional cut, then the
    /// proportional path sizes any standing queue. `SLOPDESK_ABR_GRAD_DEC`.
    public static let gradientDecreaseFactor: Double = envDouble(
        "SLOPDESK_ABR_GRAD_DEC",
        defaults.gradient_decrease_factor,
        min: 0.05,
        max: 0.999,
    )

    /// The resolved tunables, as the law reads them: the defaults with every knob the host was
    /// actually given a value for written over. Built once, because ``EnvConfig`` is resolved once.
    static let config: SlopDeskAbrConfig = {
        var c = defaults
        c.warmup_ticks = UInt32(warmupTicks)
        c.loss_threshold = lossThreshold
        c.severe_loss_threshold = severeLossThreshold
        c.loss_needs_rtt_corroboration = lossNeedsRTTCorroboration
        c.catastrophic_loss_threshold = catastrophicLossThreshold
        c.decrease_factor = decreaseFactor
        c.severe_decrease_factor = severeDecreaseFactor
        c.increase_divisor = Int64(increaseDivisor)
        c.ramp_utilization_fraction = rampUtilizationFraction
        c.decay_utilization_fraction = decayUtilizationFraction
        c.decay_headroom = decayHeadroom
        c.decay_step_fraction = decayStepFraction
        c.hold_ticks = UInt32(holdTicks)
        c.rtt_inflate_factor = rttInflateFactor
        c.rtt_slack_millis = rttSlackMillis
        c.rtt_slack_fraction = rttSlackFraction
        c.rtt_streak_ticks = UInt32(rttStreakTicks)
        c.cut_hold_ticks = UInt32(cutHoldTicks)
        c.rtt_decrease_floor_factor = rttDecreaseFloorFactor
        c.rtt_decrease_cap_factor = rttDecreaseCapFactor
        c.knee_caution_divisor = Int64(kneeCautionDivisor)
        c.knee_ttl_ticks = UInt32(kneeTTLTicks)
        c.min_fraction = minFrac
        c.seed_fraction = seedFraction
        c.material_fraction = materialFraction
        c.material_floor_bps = Int64(materialFloorBps)
        c.gradient_decrease_factor = gradientDecreaseFactor
        return c
    }()

    // MARK: State (one record, crossing whole)

    /// Every number the next fold reads. The two optionals inside it are a value plus a flag, never
    /// a sentinel — zero is a rate the floor forbids, but nothing stops a caller naming it.
    private var state: SlopDeskAbrController

    /// The ``LiveBitratePolicy/targetBitrate(pixelWidth:pixelHeight:fps:floor:)`` result for THIS
    /// encoder build — the hard upper bound the controller can never exceed.
    public var ceiling: Int { Int(state.ceiling) }
    /// The lowest the controller may drive the live rate. Always ≥ ``LiveBitratePolicy/minimumBitrate``
    /// (≥ 1 Mbps) ⇒ NEVER 0, and ≤ `ceiling`.
    public var floor: Int { Int(state.floor) }
    /// USER BITRATE CEILING (wire `streamSettings`): an optional client-requested ceiling layered
    /// UNDER the policy ceiling. `nil` = none (auto — the pure policy ceiling rules, byte-identical
    /// to the pre-override control law). Set/cleared at runtime via ``setUserCeilingBps(_:)``.
    public var userCeilingBps: Int? { state.has_user_ceiling ? Int(state.user_ceiling_bps) : nil }
    /// Whether the delay-gradient early-cut path is armed (see ``gradientCutEnabledDefault``).
    /// INSTANCE-level (injected at construction, env default in production) so the loopback harness
    /// and tests can A/B both arms in one process without env games.
    public var gradientCutEnabled: Bool { state.gradient_cut_enabled }
    /// Current target bitrate (bps). Seeded to `ceiling` — an open-loop start.
    public var current: Int { Int(state.current) }
    /// Folded-report count — the controller's "clock" (see type doc).
    public var ticks: Int { Int(state.ticks) }
    /// No increase is permitted until `ticks` reaches this (set on every decrease).
    public var holdUntilTick: Int { Int(state.hold_until_tick) }
    /// Consecutive reports whose smoothed RTT cleared BOTH inflation gates (factor + slack). The RTT
    /// path may decrease only once this reaches ``rttStreakTicks`` — one noisy report never acts.
    /// Reset on EVERY decrease, so each re-decrease needs a fresh sustained run.
    public var rttInflatedStreak: Int { Int(state.rtt_inflated_streak) }
    /// No multiplicative decrease (RTT-path OR loss-path) is permitted until `ticks` reaches this
    /// (set on every decrease) — the short re-decrease spacing (see ``cutHoldTicks``), distinct from
    /// the long increase hold-down. The catastrophic branch keeps its own stronger `holdUntilTick`.
    public var cutHoldUntilTick: Int { Int(state.cut_hold_until_tick) }
    /// The previous report's smoothed RTT — the one-report delay TREND. An RTT-path decrease
    /// additionally requires the smoothed RTT to be NOT IMPROVING (within 1ms) vs the last report: a
    /// queue already DRAINING (rate under capacity, the level is just the backlog flushing out) must
    /// not keep triggering cuts, or a ~900ms warmup backlog draining walks the rate down to the floor.
    /// A standing or growing queue reads flat/rising and keeps cutting. This is smoothed-EWMA vs
    /// smoothed-EWMA — NOT the per-report `owdGradientRising` jitter-sample coin-flip.
    public var prevSmoothedRTTMillis: Double { state.prev_smoothed_rtt_millis }
    /// The remembered "knee" (ssthresh): the rate the controller landed on after the most recent
    /// queue-corroborated decrease. Additive increase at/above this rate uses the cautious step
    /// (÷``kneeCautionDivisor``) — the controller hovers under the rate that built a queue instead of
    /// re-bashing the ceiling every recovery (the measured 25↔40Mbps pumping). `nil` = no knee known.
    public var kneeBps: Int? { state.has_knee ? Int(state.knee_bps) : nil }
    /// Tick at which the knee memory expires (refreshed by every queue-corroborated decrease).
    ///
    /// The caution divisor is CONSTANT on purpose. An "escalating caution" variant — doubling the
    /// above-knee divisor per knee re-confirmation (÷8→÷16→÷32→÷64) — is falsified by live 4G:
    /// cellular RTT wobble (p50 46 → p90 68ms) is largely rate-INDEPENDENT (identical profile at 3M and
    /// 11.5M), so each wobble trims −5% and resets the hold; any climb slower than the base ÷8
    /// (~0.94M/s at a 12M ceiling) cannot cross the material-actuation gap between wobble cuts and the
    /// rate PINS near the floor (3.45M for 91% of a session, soft image, zero latency benefit). The
    /// constant ÷8 caution rides through the wobble and breathes 3–11M — better quality at the same
    /// RTT. Keep the knee simple.
    public var kneeExpiresAtTick: Int { Int(state.knee_expires_at_tick) }

    // MARK: Init

    /// Primary initialiser. `floor` is clamped to `[minimumBitrate, ceiling]` so the controller can
    /// never drive the rate to 0 nor below a usable minimum. `current` starts AT `ceiling`.
    /// `gradientCutEnabled` defaults to the env gate — production passes nothing.
    public init(
        ceiling: Int,
        floor: Int,
        seedFraction: Double = 1.0,
        gradientCutEnabled: Bool = Self.gradientCutEnabledDefault,
    ) {
        // The seed is a per-construction choice, not a knob: the loopback harness builds controllers
        // that start below the ceiling without touching the process's env.
        var config = Self.config
        config.seed_fraction = seedFraction
        state = slopdesk_abr_new(Int64(ceiling), Int64(floor), config, gradientCutEnabled)
    }

    /// Convenience: derive the floor from `ceiling × minFrac` (the production wiring), keeping the
    /// floor-derivation policy in one place. Seeds `current` from the ``seedFraction`` env.
    public init(ceiling: Int, gradientCutEnabled: Bool = Self.gradientCutEnabledDefault) {
        state = slopdesk_abr_with_ceiling(Int64(ceiling), Self.config, gradientCutEnabled)
    }

    // MARK: User ceiling override (wire streamSettings)

    /// The ceiling every climb is clamped to: the policy ceiling bounded by the user override,
    /// itself floored at `floor` so a pathological low override can never starve the encoder below
    /// the usable minimum (the `[floor, ceiling]` invariant survives). With no override this is
    /// exactly `ceiling` — the control law is untouched.
    public var effectiveCeiling: Int { Int(slopdesk_abr_effective_ceiling(state)) }

    /// Sets (or with `nil`/≤0 clears) the user bitrate ceiling. A `current` above the new effective
    /// ceiling CLAMPS DOWN IMMEDIATELY — the override must bite on the very next actuation, not
    /// after an AIMD episode — and every later additive climb is capped at ``effectiveCeiling``.
    /// Clearing restores the pure policy ceiling; the reclaimed headroom is climbed back through the
    /// ordinary additive probe, never jumped.
    public mutating func setUserCeilingBps(_ userBps: Int?) {
        state = slopdesk_abr_set_user_ceiling(state, userBps != nil, Int64(userBps ?? 0))
    }

    // MARK: Control law

    /// CUT-REASON ATTRIBUTION (observability only, zero behaviour change): WHY the controller moved (or
    /// held) this tick, carried on the returned ``Decision`` so the host's `abr: actuate` debug line can
    /// attribute a cut to its trigger — without it the gradient path's (`SLOPDESK_ABR_GRAD`) efficacy is
    /// unmeasurable from logs.
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
        /// Multiplicative decay while DEEPLY application-limited (idle / static screen): the target
        /// drifts down toward the offered throughput so a post-idle burst stays bounded. Not congestion.
        case appLimited
        /// Proportional RTT (delay-targeting) cut — sustained smoothed-RTT inflation streak.
        case rttStreak
        /// Loss-corroborated cut — raw loss over the threshold WITH RTT-inflation evidence.
        case lossCorroborated
        /// Delay-gradient early cut — client trendline OVERUSING + raw-RTT corroboration.
        case gradient
        /// EWMA-keyed catastrophic halve (sustained ≥ catastrophic loss).
        case catastrophic

        /// The reason a `SLOPDESK_ABR_REASON_*` code names. An unknown code reads as ``hold``: a
        /// branch this side has never heard of moved nothing it can attribute, and inventing a cut
        /// in the debug log would be worse than admitting nothing happened.
        static func of(_ code: UInt32) -> Self {
            switch code {
            case UInt32(SLOPDESK_ABR_REASON_WARMUP): .warmup
            case UInt32(SLOPDESK_ABR_REASON_DRAIN): .drain
            case UInt32(SLOPDESK_ABR_REASON_PROBE): .probe
            case UInt32(SLOPDESK_ABR_REASON_KNEE): .knee
            case UInt32(SLOPDESK_ABR_REASON_APP_LIMITED): .appLimited
            case UInt32(SLOPDESK_ABR_REASON_RTT_STREAK): .rttStreak
            case UInt32(SLOPDESK_ABR_REASON_LOSS_CORROBORATED): .lossCorroborated
            case UInt32(SLOPDESK_ABR_REASON_GRADIENT): .gradient
            case UInt32(SLOPDESK_ABR_REASON_CATASTROPHIC): .catastrophic
            default: .hold
            }
        }
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
    /// Thin wrapper over ``decide(_:)`` for call sites that don't want the reason.
    @discardableResult
    public mutating func onReport(_ e: NetworkEstimate) -> Int {
        decide(e).target
    }

    /// Folds one network estimate and returns the new target bitrate PLUS the attributed reason.
    /// When several cut branches fire the reason names the branch that set the FINAL (lowest) target;
    /// on a tie the stronger evidence wins (rttStreak > lossCorroborated > gradient).
    ///
    /// Decision order: warmup → catastrophic halve → ordinary-congestion multiplicative decrease →
    /// (past hold-down) additive increase. The result is ALWAYS within `[floor, ceiling]`.
    ///
    /// `offeredBps` is the host's recent encoded throughput (bytes/frame × 8 × fps). When supplied and
    /// the stream is APPLICATION-limited (offered far below `current` — an idle / near-static screen),
    /// the additive increase is SUPPRESSED so an idle period can't inflate the target into phantom
    /// headroom a sudden burst then overshoots into bufferbloat. `nil` (the default) ⇒ no utilization
    /// gate ⇒ always probe.
    @discardableResult
    public mutating func decide(_ e: NetworkEstimate, offeredBps: Double? = nil) -> Decision {
        let decision = slopdesk_abr_decide(state, e.crossing, offeredBps != nil, offeredBps ?? 0)
        state = decision.controller
        return Decision(target: Int(decision.target), reason: CutReason.of(decision.reason))
    }

    // MARK: Actuation churn gate (pure — used by the host, unit-tested here)

    /// Whether a target change is large enough to be worth a VTSessionSetProperty round-trip. The host
    /// throttles actuation to MATERIAL moves (≥ `materialFraction` of the ceiling OR ≥ `materialFloorBps`)
    /// so a single ~3%-of-ceiling additive tick does not actuate every 50ms; consecutive additive ticks
    /// accumulate against the last ACTUATED rate and cross the gate after a couple of reports.
    public static func isMaterialChange(previous: Int, target: Int, ceiling: Int) -> Bool {
        slopdesk_abr_is_material_change(Int64(previous), Int64(target), Int64(ceiling), config)
    }

    /// Equality is over the whole record, as the synthesised one was. C structs synthesise nothing,
    /// so the comparison is spelled out; a field missing from it would let two controllers that
    /// disagree on the next report compare equal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.ceiling == rhs.state.ceiling
            && lhs.state.floor == rhs.state.floor
            && lhs.state.current == rhs.state.current
            && lhs.userCeilingBps == rhs.userCeilingBps
            && lhs.kneeBps == rhs.kneeBps
            && lhs.state.prev_smoothed_rtt_millis == rhs.state.prev_smoothed_rtt_millis
            && lhs.state.ticks == rhs.state.ticks
            && lhs.state.hold_until_tick == rhs.state.hold_until_tick
            && lhs.state.rtt_inflated_streak == rhs.state.rtt_inflated_streak
            && lhs.state.cut_hold_until_tick == rhs.state.cut_hold_until_tick
            && lhs.state.knee_expires_at_tick == rhs.state.knee_expires_at_tick
            && lhs.state.gradient_cut_enabled == rhs.state.gradient_cut_enabled
    }

    // MARK: Env parsing helpers

    // Resolve through `EnvConfig` (ProcessInfo env → overlay) so a GUI setting can override these
    // tunables. With an EMPTY overlay `EnvConfig.string(key)` is byte-identical to a raw
    // `ProcessInfo.processInfo.environment[key]` lookup, so the golden corpus pinning these defaults
    // holds. Validate-then-default: out-of-range or garbage falls back to `fallback`, never traps.
    private static func envInt(_ key: String, _ fallback: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = EnvConfig.string(key), let v = Int(s), v >= lo,
              v <= hi else { return fallback }
        return v
    }

    private static func envDouble(_ key: String, _ fallback: Double, min lo: Double, max hi: Double) -> Double {
        guard let s = EnvConfig.string(key), let v = Double(s), v >= lo,
              v <= hi else { return fallback }
        return v
    }
}
