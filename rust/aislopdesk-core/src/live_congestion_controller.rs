//! AIMD congestion controller for the live HEVC stream — a port of Swift
//! `LiveCongestionController` (WF-2 adaptive bitrate).
//!
//! Additive-Increase / Multiplicative-Decrease over the folded [`NetworkEstimate`]: on congestion
//! (raw loss over threshold WITH RTT corroboration, or sustained RTT inflation, or an enabled
//! delay-gradient onset) the target DROPS multiplicatively; on a clean link past the hold-down it
//! CLIMBS additively. Sustained catastrophic loss halves. Pure + deterministic — "time" is the
//! count of folded reports (`ticks`).
//!
//! Key stability properties (see the Swift source for the full rationale): loss keys on the RAW
//! per-report sample (no EWMA-tail cascade); RTT needs both a multiplicative factor AND an absolute
//! (baseline-proportional) slack, sustained for a streak, and a not-improving trend; ONE
//! multiplicative cut per `cut_hold_ticks` window (loss included); RTT cuts are PROPORTIONAL to the
//! measured queue; a queue-corroborated cut remembers the knee (ssthresh) and climbs cautiously
//! above it.
//!
//! Tunables: the Swift source resolves these from `AISLOPDESK_ABR_*` env vars once at startup. The
//! portable core uses the compile-time defaults below — byte-identical to the Swift values when no
//! env override is set (the configuration these tests and the golden vectors exercise).

use crate::live_bitrate_policy::MINIMUM_BITRATE;
use crate::network_estimate::NetworkEstimate;

/// Reports to fold before ANY action — the cold-start guard.
pub const WARMUP_TICKS: i64 = 10;
/// Raw per-report loss above which the link is "congested" → multiplicative decrease.
pub const LOSS_THRESHOLD: f64 = 0.02;
/// Raw per-report loss above which a catastrophic report's CURRENT sample still counts as severe.
pub const SEVERE_LOSS_THRESHOLD: f64 = 0.10;
/// Whether sub-catastrophic loss decreases only when RTT-corroborated (Swift default: true).
pub const LOSS_NEEDS_RTT_CORROBORATION: bool = true;
/// EWMA loss-rate above which the controller halves even at flat RTT (true collapse / policer).
pub const CATASTROPHIC_LOSS_THRESHOLD: f64 = 0.25;
/// Multiplicative decrease factor on ordinary congestion (0.85 = drop to 85%).
pub const DECREASE_FACTOR: f64 = 0.85;
/// Multiplicative decrease factor on catastrophic loss (0.5 = halve).
pub const SEVERE_DECREASE_FACTOR: f64 = 0.5;
/// Additive-increase step = `ceiling / increase_divisor` per clean tick.
pub const INCREASE_DIVISOR: i64 = 32;
/// Reports to suppress any increase after a decrease — the anti-thrash hold-down.
pub const HOLD_TICKS: i64 = 20;
/// `smoothed_rtt > min_rtt × rtt_inflate_factor` (AND past the slack) signals queue build-up.
pub const RTT_INFLATE_FACTOR: f64 = 1.25;
/// Absolute smoothed-RTT inflation over the baseline (ms) ALSO required before the RTT path acts.
pub const RTT_SLACK_MILLIS: f64 = 15.0;
/// Baseline-proportional slack: the effective slack is `max(rtt_slack_millis, fraction × min_rtt)`.
pub const RTT_SLACK_FRACTION: f64 = 0.75;
/// Consecutive inflated reports required before the RTT path decreases.
pub const RTT_STREAK_TICKS: i64 = 3;
/// Reports between ANY multiplicative decreases — RTT-path AND loss-path.
pub const CUT_HOLD_TICKS: i64 = 8;
/// Hardest single proportional RTT decrease (0.6 = at most −40% in one step).
pub const RTT_DECREASE_FLOOR_FACTOR: f64 = 0.6;
/// Gentlest proportional RTT decrease (0.95 = −5%).
pub const RTT_DECREASE_CAP_FACTOR: f64 = 0.95;
/// Additive divisor applied ON TOP of `increase_divisor` at/above the remembered knee.
pub const KNEE_CAUTION_DIVISOR: i64 = 8;
/// Reports the knee memory survives without a fresh queue-corroborated decrease.
pub const KNEE_TTL_TICKS: i64 = 1200;
/// Floor as a fraction of the ceiling (also clamped to [`MINIMUM_BITRATE`]).
pub const MIN_FRAC: f64 = 0.25;
/// Actuation churn gate (fraction of ceiling).
pub const MATERIAL_FRACTION: f64 = 0.05;
/// Actuation churn gate (absolute bps floor).
pub const MATERIAL_FLOOR_BPS: i64 = 500_000;
/// Whether the delay-gradient early-cut path is armed by default (Swift default: false).
pub const GRADIENT_CUT_ENABLED_DEFAULT: bool = false;
/// Multiplicative factor for a gradient-authorized cut.
pub const GRADIENT_DECREASE_FACTOR: f64 = 0.85;

/// The effective absolute-slack gate for a given path baseline.
#[must_use]
pub fn effective_slack_millis(min_rtt_millis: f64) -> f64 {
    if min_rtt_millis.is_finite() {
        RTT_SLACK_MILLIS.max(RTT_SLACK_FRACTION * min_rtt_millis)
    } else {
        RTT_SLACK_MILLIS
    }
}

/// Why the controller moved (or held) this tick — observability only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CutReason {
    /// Cold-start guard — no action possible.
    Warmup,
    /// No branch fired (sub-threshold / hold-down) — target unchanged.
    Hold,
    /// Fully-armed RTT cut held because the smoothed RTT is improving (the queue is draining).
    Drain,
    /// Additive increase (the normal probe step toward the ceiling).
    Probe,
    /// Additive increase at/above the remembered knee — the cautious step.
    Knee,
    /// Proportional RTT (delay-targeting) cut — sustained smoothed-RTT inflation streak.
    RttStreak,
    /// Loss-corroborated cut — raw loss over the threshold WITH RTT-inflation evidence.
    LossCorroborated,
    /// Delay-gradient early cut — client trendline OVERUSING + raw-RTT corroboration.
    Gradient,
    /// EWMA-keyed catastrophic halve (sustained ≥ catastrophic loss).
    Catastrophic,
}

/// One control-law tick's outcome: the new target plus why.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Decision {
    /// The new target bitrate (bps), within `[floor, ceiling]`.
    pub target: i64,
    /// The branch that set the final target.
    pub reason: CutReason,
}

/// Pure AIMD congestion controller. `Copy` value type; [`PartialEq`] (f64 fields).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiveCongestionController {
    ceiling: i64,
    floor: i64,
    gradient_cut_enabled: bool,
    current: i64,
    ticks: i64,
    hold_until_tick: i64,
    rtt_inflated_streak: i64,
    cut_hold_until_tick: i64,
    prev_smoothed_rtt_millis: f64,
    knee_bps: Option<i64>,
    knee_expires_at_tick: i64,
}

impl LiveCongestionController {
    /// Primary initialiser. `floor` is clamped to `[MINIMUM_BITRATE, ceiling]`; `current` starts at
    /// `ceiling`.
    #[must_use]
    pub fn with_floor(ceiling: i64, floor: i64, gradient_cut_enabled: bool) -> Self {
        let c = ceiling.max(1);
        Self {
            ceiling: c,
            floor: MINIMUM_BITRATE.max(floor.min(c)),
            gradient_cut_enabled,
            current: c,
            ticks: 0,
            hold_until_tick: 0,
            rtt_inflated_streak: 0,
            cut_hold_until_tick: 0,
            prev_smoothed_rtt_millis: 0.0,
            knee_bps: None,
            knee_expires_at_tick: 0,
        }
    }

    /// Derives the floor from `ceiling × MIN_FRAC` with the given gradient-cut flag.
    #[must_use]
    pub fn with_gradient_cut(ceiling: i64, gradient_cut_enabled: bool) -> Self {
        let floor = (ceiling.max(1) as f64 * MIN_FRAC) as i64;
        Self::with_floor(ceiling, floor, gradient_cut_enabled)
    }

    /// Production wiring: derives the floor from `ceiling × MIN_FRAC`, gradient cut off by default.
    #[must_use]
    pub fn new(ceiling: i64) -> Self {
        Self::with_gradient_cut(ceiling, GRADIENT_CUT_ENABLED_DEFAULT)
    }

    /// The hard upper bound the controller can never exceed.
    #[must_use]
    pub const fn ceiling(&self) -> i64 {
        self.ceiling
    }
    /// The lowest the controller may drive the live rate (≥ [`MINIMUM_BITRATE`], ≤ `ceiling`).
    #[must_use]
    pub const fn floor(&self) -> i64 {
        self.floor
    }
    /// Whether the delay-gradient early-cut path is armed.
    #[must_use]
    pub const fn gradient_cut_enabled(&self) -> bool {
        self.gradient_cut_enabled
    }
    /// Current target bitrate (bps).
    #[must_use]
    pub const fn current(&self) -> i64 {
        self.current
    }
    /// Folded-report count — the controller's clock.
    #[must_use]
    pub const fn ticks(&self) -> i64 {
        self.ticks
    }
    /// Tick until which no increase is permitted (set on every decrease).
    #[must_use]
    pub const fn hold_until_tick(&self) -> i64 {
        self.hold_until_tick
    }
    /// The remembered knee (ssthresh), if any.
    #[must_use]
    pub const fn knee_bps(&self) -> Option<i64> {
        self.knee_bps
    }

    /// Additive-increase step in bps (≥ 1 so a tiny ceiling still makes progress).
    fn increase_step(&self) -> i64 {
        (self.ceiling / INCREASE_DIVISOR).max(1)
    }

    /// Folds one network estimate and returns the (possibly unchanged) new target bitrate.
    pub fn on_report(&mut self, e: &NetworkEstimate) -> i64 {
        self.decide(e).target
    }

    /// Folds one network estimate and returns the new target bitrate PLUS the attributed reason.
    pub fn decide(&mut self, e: &NetworkEstimate) -> Decision {
        self.ticks += 1;
        let decision = self.decide_inner(e);
        // Mirrors the Swift `defer { prevSmoothedRTTMillis = e.smoothedRTTMillis }`: captured for
        // the NEXT report whatever branch ran (including warmup).
        self.prev_smoothed_rtt_millis = e.smoothed_rtt_millis();
        decision
    }

    #[allow(clippy::too_many_lines)] // one faithful translation of the Swift control law
    fn decide_inner(&mut self, e: &NetworkEstimate) -> Decision {
        if self.ticks < WARMUP_TICKS {
            return Decision {
                target: self.current,
                reason: CutReason::Warmup,
            };
        }

        let slack = effective_slack_millis(e.min_rtt_millis());
        let rtt_inflated = e.min_rtt_millis().is_finite()
            && e.smoothed_rtt_millis() > e.min_rtt_millis() * RTT_INFLATE_FACTOR
            && e.smoothed_rtt_millis() > e.min_rtt_millis() + slack;
        self.rtt_inflated_streak = if rtt_inflated {
            self.rtt_inflated_streak + 1
        } else {
            0
        };
        let rtt_congested = rtt_inflated
            && self.rtt_inflated_streak >= RTT_STREAK_TICKS
            && self.ticks >= self.cut_hold_until_tick
            && e.smoothed_rtt_millis() + 1.0 >= self.prev_smoothed_rtt_millis;

        // Knee TTL: forget a knee not re-confirmed within `KNEE_TTL_TICKS`.
        if self.knee_bps.is_some() && self.ticks >= self.knee_expires_at_tick {
            self.knee_bps = None;
        }

        let loss_evidence = !LOSS_NEEDS_RTT_CORROBORATION || rtt_inflated;
        let loss_congested = e.last_loss_sample() > LOSS_THRESHOLD
            && loss_evidence
            && self.ticks >= self.cut_hold_until_tick;
        let raw_rtt_inflated = match e.last_rtt_sample_millis() {
            Some(raw) if e.min_rtt_millis().is_finite() => {
                raw > e.min_rtt_millis() * RTT_INFLATE_FACTOR && raw > e.min_rtt_millis() + slack
            }
            _ => false,
        };
        let gradient_congested = self.gradient_cut_enabled
            && e.owd_trend_overusing()
            && raw_rtt_inflated
            && self.ticks >= self.cut_hold_until_tick;

        if e.loss_rate() > CATASTROPHIC_LOSS_THRESHOLD
            && e.last_loss_sample() > SEVERE_LOSS_THRESHOLD
            && self.ticks >= self.hold_until_tick
        {
            let target = self
                .floor
                .max((self.current as f64 * SEVERE_DECREASE_FACTOR) as i64);
            self.decrease(target, rtt_inflated);
            return Decision {
                target: self.current,
                reason: CutReason::Catastrophic,
            };
        } else if rtt_congested || loss_congested || gradient_congested {
            let mut target = i64::MAX;
            let mut reason = CutReason::Hold; // overwritten — at least one branch fired
            if rtt_congested {
                let drained = e.min_rtt_millis() + slack;
                let factor = RTT_DECREASE_CAP_FACTOR
                    .min(RTT_DECREASE_FLOOR_FACTOR.max(drained / e.smoothed_rtt_millis()));
                let cut = (self.current as f64 * factor) as i64;
                if cut < target {
                    target = cut;
                    reason = CutReason::RttStreak;
                }
            }
            if loss_congested {
                let cut = (self.current as f64 * DECREASE_FACTOR) as i64;
                if cut < target {
                    target = cut;
                    reason = CutReason::LossCorroborated;
                }
            }
            if gradient_congested {
                let cut = (self.current as f64 * GRADIENT_DECREASE_FACTOR) as i64;
                if cut < target {
                    target = cut;
                    reason = CutReason::Gradient;
                }
            }
            self.decrease(self.floor.max(target), rtt_inflated);
            return Decision {
                target: self.current,
                reason,
            };
        } else if self.ticks >= self.hold_until_tick
            && !rtt_inflated
            && !(self.gradient_cut_enabled && e.owd_trend_overusing())
        {
            let cautious = self.knee_bps.is_some_and(|knee| self.current >= knee);
            let step = if cautious {
                (self.increase_step() / KNEE_CAUTION_DIVISOR).max(1)
            } else {
                self.increase_step()
            };
            self.current = self.ceiling.min(self.current + step);
            return Decision {
                target: self.current,
                reason: if cautious {
                    CutReason::Knee
                } else {
                    CutReason::Probe
                },
            };
        }
        let drain_gated = rtt_inflated
            && self.rtt_inflated_streak >= RTT_STREAK_TICKS
            && self.ticks >= self.cut_hold_until_tick
            && e.smoothed_rtt_millis() + 1.0 < self.prev_smoothed_rtt_millis;
        Decision {
            target: self.current,
            reason: if drain_gated {
                CutReason::Drain
            } else {
                CutReason::Hold
            },
        }
    }

    /// Applies a decrease and arms the hold-downs — but ONLY when the target actually LOWERS
    /// `current` (a no-op at the floor must not keep extending the hold-down). A queue-corroborated
    /// decrease additionally records the landed-on rate as the knee.
    const fn decrease(&mut self, next: i64, queue_corroborated: bool) {
        if next < self.current {
            self.current = next;
            self.hold_until_tick = self.ticks + HOLD_TICKS;
            self.cut_hold_until_tick = self.ticks + CUT_HOLD_TICKS;
            self.rtt_inflated_streak = 0;
            if queue_corroborated {
                self.knee_bps = Some(self.current);
                self.knee_expires_at_tick = self.ticks + KNEE_TTL_TICKS;
            }
        }
    }

    /// Whether a target change is large enough to be worth a re-actuation (≥ `MATERIAL_FRACTION`
    /// of the ceiling OR ≥ `MATERIAL_FLOOR_BPS`).
    #[must_use]
    pub fn is_material_change(previous: i64, target: i64, ceiling: i64) -> bool {
        (target - previous).abs()
            >= MATERIAL_FLOOR_BPS.max((ceiling.max(1) as f64 * MATERIAL_FRACTION) as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CEILING: i64 = 45_000_000;

    fn estimate(loss_samples: f64, folds: i64, rtt_congested: bool) -> NetworkEstimate {
        let mut est = NetworkEstimate::new();
        let unrecovered = (loss_samples * 1000.0).round() as u32;
        for _ in 0..folds.max(1) {
            est.fold(Some(50), 1000, unrecovered, 100);
            if rtt_congested {
                est.fold(Some(50), 1000, unrecovered, 200);
                est.fold(Some(500), 1000, unrecovered, 9000);
            }
        }
        est
    }

    fn warmed_controller(
        ceiling: i64,
        floor: Option<i64>,
        gradient: bool,
    ) -> LiveCongestionController {
        let mut ctrl = floor.map_or_else(
            || LiveCongestionController::with_gradient_cut(ceiling, gradient),
            |f| LiveCongestionController::with_floor(ceiling, f, gradient),
        );
        let clean = estimate(0.0, 1, false);
        for _ in 0..WARMUP_TICKS {
            let _ = ctrl.on_report(&clean);
        }
        ctrl
    }

    fn gradient_estimate(
        raw_rtt: Option<i64>,
        overusing: bool,
        baseline_folds: i64,
    ) -> NetworkEstimate {
        let mut est = NetworkEstimate::new();
        for _ in 0..baseline_folds {
            est.fold(Some(50), 1000, 0, 100);
        }
        est.fold_with_trend(
            raw_rtt,
            1000,
            0,
            100,
            u8::from(overusing),
            if overusing { 80_000 } else { 0 },
        );
        est
    }

    fn stepped_clean(est: &mut NetworkEstimate, ctrl: &mut LiveCongestionController, count: i64) {
        for _ in 0..count {
            est.fold(Some(50), 1000, 0, 100);
            let _ = ctrl.on_report(est);
        }
    }

    #[test]
    fn starts_at_ceiling() {
        assert_eq!(LiveCongestionController::new(CEILING).current(), CEILING);
    }

    #[test]
    fn floor_derived_from_ceiling_and_never_below_minimum() {
        let big = LiveCongestionController::new(40_000_000);
        assert_eq!(big.floor(), (40_000_000.0 * MIN_FRAC) as i64);
        let tiny = LiveCongestionController::new(2_000_000);
        assert_eq!(tiny.floor(), MINIMUM_BITRATE);
        assert!(tiny.floor() > 0);
    }

    #[test]
    fn explicit_floor_clamped_into_range() {
        let over = LiveCongestionController::with_floor(10_000_000, 99_000_000, false);
        assert_eq!(over.floor(), 10_000_000);
        let under = LiveCongestionController::with_floor(10_000_000, 0, false);
        assert_eq!(under.floor(), MINIMUM_BITRATE);
    }

    #[test]
    fn warmup_is_a_no_op() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let lossy = estimate(0.5, 8, false);
        for _ in 0..(WARMUP_TICKS - 1) {
            assert_eq!(ctrl.on_report(&lossy), CEILING);
        }
        assert_eq!(ctrl.current(), CEILING);
        assert!(ctrl.on_report(&lossy) < CEILING);
    }

    #[test]
    fn decrease_on_loss_above_threshold() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let lossy = estimate(0.05, 8, true);
        let before = ctrl.current();
        let after = ctrl.on_report(&lossy);
        assert_eq!(
            after,
            ctrl.floor().max((before as f64 * DECREASE_FACTOR) as i64)
        );
        assert!(after < before);
    }

    #[test]
    fn severe_loss_halves() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let severe = estimate(0.5, 12, false);
        let before = ctrl.current();
        let after = ctrl.on_report(&severe);
        assert_eq!(
            after,
            ctrl.floor()
                .max((before as f64 * SEVERE_DECREASE_FACTOR) as i64)
        );
        let mut ordinary_ctrl = warmed_controller(CEILING, None, false);
        let ordinary = ordinary_ctrl.on_report(&estimate(0.05, 8, true));
        assert!(after < ordinary);
    }

    #[test]
    fn decrease_on_sustained_rtt_inflation() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let rtt = estimate(0.0, 4, true);
        assert!(rtt.smoothed_rtt_millis() > rtt.min_rtt_millis() * RTT_INFLATE_FACTOR);
        assert!(rtt.smoothed_rtt_millis() > rtt.min_rtt_millis() + RTT_SLACK_MILLIS);
        let before = ctrl.current();
        for _ in 0..(RTT_STREAK_TICKS - 1) {
            assert_eq!(ctrl.on_report(&rtt), before);
        }
        assert!(ctrl.on_report(&rtt) < before);
    }

    #[test]
    fn clean_lan_jitter_never_decreases() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        est.fold(Some(5), 1000, 0, 10_000);
        let rtts = [7, 12, 9, 15, 6, 11, 5, 16, 8, 13];
        let jitters: [u32; 6] = [9_000, 14_000, 11_000, 13_500, 10_000, 12_500];
        for i in 0..200usize {
            est.fold(
                Some(rtts[i % rtts.len()]),
                1000,
                0,
                jitters[i % jitters.len()],
            );
            assert_eq!(ctrl.on_report(&est), CEILING);
        }
    }

    #[test]
    fn sustained_rtt_inflation_backs_off_once_per_window_not_per_report() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        est.fold(Some(5), 1000, 0, 100);
        let mut decrease_ticks: Vec<i64> = Vec::new();
        for i in 0..(HOLD_TICKS + 10) {
            est.fold(Some(80), 1000, 0, 100);
            let before = ctrl.current();
            let raw = (est.min_rtt_millis() + RTT_SLACK_MILLIS) / est.smoothed_rtt_millis();
            let factor = RTT_DECREASE_CAP_FACTOR.min(RTT_DECREASE_FLOOR_FACTOR.max(raw));
            let after = ctrl.on_report(&est);
            if after < before {
                decrease_ticks.push(i);
                assert_eq!(after, ctrl.floor().max((before as f64 * factor) as i64));
            }
        }
        assert!(decrease_ticks.len() >= 2);
        for pair in decrease_ticks.windows(2) {
            assert!(pair[1] - pair[0] >= CUT_HOLD_TICKS);
        }
    }

    #[test]
    fn rtt_decrease_clamp_bounds() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        est.fold(Some(5), 1000, 0, 100);
        let mut first: Option<(i64, i64, f64)> = None;
        for _ in 0..10 {
            est.fold(Some(300), 1000, 0, 100);
            let before = ctrl.current();
            let raw = (est.min_rtt_millis() + RTT_SLACK_MILLIS) / est.smoothed_rtt_millis();
            let after = ctrl.on_report(&est);
            if after < before {
                first = Some((before, after, raw));
                break;
            }
        }
        let (before, after, factor) = first.expect("must decrease");
        assert!(factor < RTT_DECREASE_FLOOR_FACTOR);
        assert_eq!(after, (before as f64 * RTT_DECREASE_FLOOR_FACTOR) as i64);

        let mut gentle = warmed_controller(CEILING, None, false);
        let mut est2 = NetworkEstimate::new();
        est2.fold(Some(10), 1000, 0, 100);
        let mut saw = false;
        for _ in 0..40 {
            est2.fold(Some(31), 1000, 0, 100);
            let before = gentle.current();
            let raw = (est2.min_rtt_millis() + effective_slack_millis(est2.min_rtt_millis()))
                / est2.smoothed_rtt_millis();
            let after = gentle.on_report(&est2);
            if after < before {
                saw = true;
                assert!(raw > RTT_DECREASE_CAP_FACTOR);
                assert_eq!(after, (before as f64 * RTT_DECREASE_CAP_FACTOR) as i64);
                break;
            }
        }
        assert!(saw);
    }

    #[test]
    fn knee_cautious_climb_above_fast_below() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let _ = ctrl.on_report(&estimate(0.05, 8, true));
        let knee = ctrl.current();
        assert_eq!(ctrl.knee_bps(), Some(knee));

        let mut est = NetworkEstimate::new();
        est.fold(Some(50), 1000, 0, 100);
        for _ in 0..(HOLD_TICKS + 10) {
            est.fold(Some(50), 1000, 1000, 100);
            let _ = ctrl.on_report(&est);
        }
        assert!(ctrl.current() < knee);
        assert_eq!(ctrl.knee_bps(), Some(knee));

        let full_step = (CEILING / INCREASE_DIVISOR).max(1);
        let cautious_step = (full_step / KNEE_CAUTION_DIVISOR).max(1);
        let mut saw_full = false;
        let mut saw_cautious = false;
        for _ in 0..2_000 {
            est.fold(Some(50), 1000, 0, 100);
            let before = ctrl.current();
            let after = ctrl.on_report(&est);
            if after <= before {
                continue;
            }
            if before < knee {
                assert_eq!(after - before, full_step);
                saw_full = true;
            } else {
                assert_eq!(after - before, cautious_step);
                saw_cautious = true;
            }
            if saw_cautious && after >= knee + 2 * cautious_step {
                break;
            }
        }
        assert!(saw_full);
        assert!(saw_cautious);
    }

    #[test]
    fn draining_queue_never_re_cuts() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        est.fold(Some(5), 1000, 0, 100);
        let mut after_first_cut: Option<i64> = None;
        for _ in 0..10 {
            est.fold(Some(300), 1000, 0, 100);
            let before = ctrl.current();
            if ctrl.on_report(&est) < before {
                after_first_cut = Some(ctrl.current());
                break;
            }
        }
        let cut = after_first_cut.expect("a rising queue must cut");
        let mut rtt = 100;
        for _ in 0..40 {
            rtt = (rtt - 12).max(6);
            est.fold(Some(rtt), 1000, 0, 100);
            let _ = ctrl.on_report(&est);
            assert!(ctrl.current() >= cut);
        }
    }

    #[test]
    fn knee_expires_after_ttl() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let _ = ctrl.on_report(&estimate(0.05, 8, true));
        assert!(ctrl.knee_bps().is_some());
        let clean = estimate(0.0, 1, false);
        for _ in 0..=KNEE_TTL_TICKS {
            let _ = ctrl.on_report(&clean);
        }
        assert_eq!(ctrl.knee_bps(), None);
    }

    #[test]
    fn high_baseline_wobble_does_not_cut() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        est.fold(Some(40), 1000, 0, 100);
        for _ in 0..100 {
            est.fold(Some(60), 1000, 0, 100);
            let _ = ctrl.on_report(&est);
        }
        assert_eq!(ctrl.current(), CEILING);
    }

    #[test]
    fn high_baseline_real_queue_still_cuts() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        est.fold(Some(40), 1000, 0, 100);
        let mut cut = false;
        for _ in 0..20 {
            est.fold(Some(120), 1000, 0, 100);
            let before = ctrl.current();
            if ctrl.on_report(&est) < before {
                cut = true;
                break;
            }
        }
        assert!(cut);
    }

    #[test]
    fn effective_slack_unchanged_on_lan_baseline() {
        assert_eq!(effective_slack_millis(10.0), 15.0);
        assert_eq!(effective_slack_millis(5.0), 15.0);
        assert_eq!(effective_slack_millis(40.0), 30.0);
        assert_eq!(effective_slack_millis(f64::INFINITY), 15.0);
    }

    #[test]
    fn absolute_slack_guards_tiny_baseline() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        est.fold(Some(3), 1000, 0, 100);
        for _ in 0..200 {
            est.fold(Some(12), 1000, 0, 100);
            let _ = ctrl.on_report(&est);
        }
        assert_eq!(ctrl.current(), CEILING);
    }

    #[test]
    fn hold_down_suppresses_immediate_re_increase() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let dropped = ctrl.on_report(&estimate(0.05, 8, true));
        assert!(dropped < CEILING);
        let clean = estimate(0.0, 1, false);
        for _ in 0..(HOLD_TICKS - 1) {
            assert_eq!(ctrl.on_report(&clean), dropped);
        }
    }

    #[test]
    fn probe_increase_on_clean_link_past_hold_down() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let dropped = ctrl.on_report(&estimate(0.05, 8, true));
        let clean = estimate(0.0, 1, false);
        for _ in 0..HOLD_TICKS {
            let _ = ctrl.on_report(&clean);
        }
        let probed = ctrl.on_report(&clean);
        assert!(probed > dropped);
        let step = (CEILING / INCREASE_DIVISOR).max(1);
        assert!(probed - dropped <= step * (HOLD_TICKS + 1));
    }

    #[test]
    fn recovery_never_exceeds_ceiling() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let _ = ctrl.on_report(&estimate(0.5, 12, false));
        let clean = estimate(0.0, 1, false);
        for _ in 0..10_000 {
            let _ = ctrl.on_report(&clean);
        }
        assert_eq!(ctrl.current(), CEILING);
    }

    #[test]
    fn single_transient_spike_at_flat_rtt_never_decreases() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        stepped_clean(&mut est, &mut ctrl, WARMUP_TICKS);
        assert_eq!(ctrl.current(), CEILING);
        est.fold(Some(50), 1000, 1000, 100);
        assert_eq!(ctrl.on_report(&est), CEILING);
        assert!(est.loss_rate() > LOSS_THRESHOLD);
        for _ in 0..60 {
            est.fold(Some(50), 1000, 0, 100);
            assert_eq!(ctrl.on_report(&est), CEILING);
        }
    }

    #[test]
    fn sustained_collapse_halves_once_per_hold_down() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        stepped_clean(&mut est, &mut ctrl, WARMUP_TICKS);
        let mut first_halve: Option<i64> = None;
        for i in 0..HOLD_TICKS {
            est.fold(Some(50), 1000, 1000, 100);
            let _ = ctrl.on_report(&est);
            if first_halve.is_none() && ctrl.current() < CEILING {
                first_halve = Some(i);
            }
        }
        assert!(first_halve.is_some());
        assert_eq!(
            ctrl.current(),
            ctrl.floor()
                .max((CEILING as f64 * SEVERE_DECREASE_FACTOR) as i64)
        );
        stepped_clean(&mut est, &mut ctrl, 3);
        assert!(
            ctrl.current()
                >= ctrl
                    .floor()
                    .max((CEILING as f64 * SEVERE_DECREASE_FACTOR) as i64)
        );
    }

    #[test]
    fn no_op_decrease_at_floor_does_not_extend_hold_down() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        for _ in 0..200 {
            est.fold(Some(50), 1000, 1000, 100);
            let _ = ctrl.on_report(&est);
        }
        assert_eq!(ctrl.current(), ctrl.floor());
        assert!(ctrl.hold_until_tick() <= ctrl.ticks());
        for _ in 0..11 {
            est.fold(Some(50), 1000, 0, 100);
            let _ = ctrl.on_report(&est);
        }
        est.fold(Some(50), 1000, 0, 100);
        assert!(ctrl.on_report(&est) > ctrl.floor());
    }

    #[test]
    fn weather_loss_flat_rtt_never_decreases() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let mut est = NetworkEstimate::new();
        est.fold(Some(50), 1000, 0, 100);
        let loss_per_mille: [u32; 8] = [30, 90, 42, 60, 86, 33, 77, 51];
        for i in 0..200usize {
            est.fold(
                Some(50),
                1000,
                loss_per_mille[i % loss_per_mille.len()],
                300,
            );
            assert_eq!(ctrl.on_report(&est), CEILING);
        }
    }

    #[test]
    fn loss_with_rtt_inflation_decreases_immediately() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let congested = estimate(0.05, 4, true);
        let before = ctrl.current();
        assert!(ctrl.on_report(&congested) < before);
    }

    #[test]
    fn catastrophic_loss_halves_even_at_flat_rtt() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let catastrophic = estimate(0.30, 16, false);
        assert!(catastrophic.loss_rate() > CATASTROPHIC_LOSS_THRESHOLD);
        let after = ctrl.on_report(&catastrophic);
        assert_eq!(
            after,
            ctrl.floor()
                .max((CEILING as f64 * SEVERE_DECREASE_FACTOR) as i64)
        );
    }

    #[test]
    fn weather_burst_spanning_reports_cuts_once_per_window() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        for _ in 0..(WARMUP_TICKS + 5) {
            est.fold(Some(6), 3, 0, 100);
            let _ = ctrl.on_report(&est);
        }
        assert_eq!(ctrl.current(), CEILING);
        let before = ctrl.current();
        for i in 0..6u32 {
            est.fold(Some(80), 2 + i % 2, 1, 500);
            let _ = ctrl.on_report(&est);
        }
        let one_cut = ctrl.floor().max((before as f64 * DECREASE_FACTOR) as i64);
        assert_eq!(ctrl.current(), one_cut);
        assert!(ctrl.current() > ctrl.floor());
    }

    #[test]
    fn severe_raw_sample_no_longer_fast_halves() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        for _ in 0..(WARMUP_TICKS + 5) {
            est.fold(Some(6), 3, 0, 100);
            let _ = ctrl.on_report(&est);
        }
        for _ in 0..2 {
            est.fold(Some(80), 3, 0, 500);
            let _ = ctrl.on_report(&est);
        }
        assert_eq!(ctrl.current(), CEILING);
        est.fold(Some(80), 2, 1, 500);
        assert!(est.loss_rate() < CATASTROPHIC_LOSS_THRESHOLD);
        let after = ctrl.on_report(&est);
        assert_eq!(
            after,
            ctrl.floor().max((CEILING as f64 * DECREASE_FACTOR) as i64)
        );
    }

    #[test]
    fn persistent_corroborated_loss_cuts_spaced_by_window() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let mut est = NetworkEstimate::new();
        for _ in 0..(WARMUP_TICKS + 5) {
            est.fold(Some(6), 3, 0, 100);
            let _ = ctrl.on_report(&est);
        }
        let mut cut_ticks: Vec<i64> = Vec::new();
        for i in 0..40 {
            est.fold(Some(80), 20, 1, 500);
            let before = ctrl.current();
            let _ = ctrl.on_report(&est);
            if ctrl.current() < before {
                cut_ticks.push(i);
            }
        }
        assert!(cut_ticks.len() >= 2);
        for pair in cut_ticks.windows(2) {
            assert!(pair[1] - pair[0] >= CUT_HOLD_TICKS);
        }
    }

    #[test]
    fn decrease_never_below_floor() {
        let mut ctrl = warmed_controller(CEILING, None, false);
        let severe = estimate(0.5, 12, false);
        for _ in 0..10_000 {
            let _ = ctrl.on_report(&severe);
        }
        assert_eq!(ctrl.current(), ctrl.floor());
        assert!(ctrl.current() >= MINIMUM_BITRATE);
        assert!(ctrl.current() > 0);
    }

    #[test]
    fn inert_when_no_loss_and_no_rtt() {
        let mut ctrl = LiveCongestionController::new(CEILING);
        let blind = NetworkEstimate::new();
        for _ in 0..1_000 {
            let _ = ctrl.on_report(&blind);
        }
        assert_eq!(ctrl.current(), CEILING);
    }

    #[test]
    fn never_decreases_on_absence_of_data() {
        let mut est = NetworkEstimate::new();
        for _ in 0..20 {
            est.fold(None, 1000, 0, 100);
        }
        let mut ctrl = LiveCongestionController::new(CEILING);
        for _ in 0..1_000 {
            let _ = ctrl.on_report(&est);
        }
        assert_eq!(ctrl.current(), CEILING);
    }

    #[test]
    fn churn_gate_suppresses_tiny_changes() {
        assert!(!LiveCongestionController::is_material_change(
            45_000_000, 45_100_000, CEILING
        ));
        assert!(LiveCongestionController::is_material_change(
            45_000_000, 42_000_000, CEILING
        ));
    }

    #[test]
    fn churn_gate_absolute_floor_for_small_ceiling() {
        let small = 4_000_000;
        assert!(!LiveCongestionController::is_material_change(
            4_000_000, 3_700_000, small
        ));
        assert!(LiveCongestionController::is_material_change(
            4_000_000, 3_400_000, small
        ));
    }

    #[test]
    fn additive_ticks_accumulate_to_a_material_actuation() {
        let step = CEILING / INCREASE_DIVISOR;
        assert!(!LiveCongestionController::is_material_change(
            CEILING - step,
            CEILING,
            CEILING
        ));
        assert!(LiveCongestionController::is_material_change(
            CEILING - 2 * step,
            CEILING,
            CEILING
        ));
    }

    #[test]
    fn gradient_flag_defaults_off() {
        // Documents the shipped default (a guard against an accidental flip), hence the const assert.
        #[allow(clippy::assertions_on_constants)]
        {
            assert!(!GRADIENT_CUT_ENABLED_DEFAULT);
        }
        assert!(!LiveCongestionController::new(CEILING).gradient_cut_enabled());
        assert!(LiveCongestionController::with_gradient_cut(CEILING, true).gradient_cut_enabled());
    }

    #[test]
    fn gradient_overuse_cuts_after_one_report() {
        let mut ctrl = warmed_controller(CEILING, None, true);
        let est = gradient_estimate(Some(200), true, 8);
        let slack = effective_slack_millis(est.min_rtt_millis());
        assert!(est.smoothed_rtt_millis() <= est.min_rtt_millis() + slack);
        let before = ctrl.current();
        let after = ctrl.on_report(&est);
        assert_eq!(
            after,
            ctrl.floor()
                .max((before as f64 * GRADIENT_DECREASE_FACTOR) as i64)
        );
        assert!(after < before);
    }

    #[test]
    fn gradient_cut_requires_raw_rtt_corroboration() {
        let mut flat_raw = warmed_controller(CEILING, None, true);
        assert_eq!(
            flat_raw.on_report(&gradient_estimate(Some(50), true, 8)),
            CEILING
        );
        let mut rejected_raw = warmed_controller(CEILING, None, true);
        assert_eq!(
            rejected_raw.on_report(&gradient_estimate(None, true, 8)),
            CEILING
        );
    }

    #[test]
    fn gradient_cut_respects_cut_hold_spacing() {
        let mut ctrl = warmed_controller(CEILING, None, true);
        let mut est = NetworkEstimate::new();
        for _ in 0..8 {
            est.fold(Some(50), 1000, 0, 100);
        }
        est.fold_with_trend(Some(200), 1000, 0, 100, 1, 80_000);
        assert!(ctrl.on_report(&est) < CEILING);
        let mut cut_ticks: Vec<i64> = Vec::new();
        let mut last = ctrl.current();
        for i in 1..=(CUT_HOLD_TICKS * 2) {
            est.fold_with_trend(Some(200), 1000, 0, 100, 1, 80_000);
            let after = ctrl.on_report(&est);
            if after < last {
                cut_ticks.push(i);
            }
            last = after;
        }
        assert!(!cut_ticks.is_empty());
        assert!(cut_ticks[0] >= CUT_HOLD_TICKS);
        for pair in cut_ticks.windows(2) {
            assert!(pair[1] - pair[0] >= CUT_HOLD_TICKS);
        }
    }

    #[test]
    fn gradient_disabled_is_byte_identical_to_today() {
        let mut with_trend = LiveCongestionController::new(CEILING);
        let mut no_trend = LiveCongestionController::new(CEILING);
        let mut est_a = NetworkEstimate::new();
        let mut est_b = NetworkEstimate::new();
        for i in 0..60 {
            let rtt = if i % 5 == 0 { 200 } else { 50 };
            let lost: u32 = if i % 7 == 0 { 30 } else { 0 };
            est_a.fold_with_trend(Some(rtt), 1000, lost, 100, 1, 99_000);
            est_b.fold(Some(rtt), 1000, lost, 100);
            assert_eq!(with_trend.on_report(&est_a), no_trend.on_report(&est_b));
        }
        assert_eq!(with_trend, no_trend);
    }

    #[test]
    fn gradient_overuse_suppresses_additive_increase() {
        let mut ctrl = warmed_controller(CEILING, None, true);
        let cut = ctrl.on_report(&gradient_estimate(Some(200), true, 8));
        assert!(cut < CEILING);
        let mut est = NetworkEstimate::new();
        for _ in 0..8 {
            est.fold(Some(50), 1000, 0, 100);
        }
        for _ in 0..(HOLD_TICKS + 10) {
            est.fold_with_trend(Some(50), 1000, 0, 100, 1, 80_000);
            assert_eq!(ctrl.on_report(&est), cut);
        }
        est.fold(Some(50), 1000, 0, 100);
        assert!(ctrl.on_report(&est) > cut);
    }

    #[test]
    fn gradient_cut_sets_no_knee() {
        let mut ctrl = warmed_controller(CEILING, None, true);
        let _ = ctrl.on_report(&gradient_estimate(Some(200), true, 8));
        assert!(ctrl.current() < CEILING);
        assert_eq!(ctrl.knee_bps(), None);
    }

    #[test]
    fn gradient_then_sustained_queue_proportional_cut_next_window() {
        let mut ctrl = warmed_controller(CEILING, None, true);
        let mut est = NetworkEstimate::new();
        for _ in 0..8 {
            est.fold(Some(50), 1000, 0, 100);
        }
        est.fold_with_trend(Some(200), 1000, 0, 100, 1, 80_000);
        let after_gradient = ctrl.on_report(&est);
        assert_eq!(
            after_gradient,
            (CEILING as f64 * GRADIENT_DECREASE_FACTOR) as i64
        );
        assert_eq!(ctrl.knee_bps(), None);
        let mut cut_tick: Option<i64> = None;
        for i in 1..=(CUT_HOLD_TICKS + 2) {
            est.fold_with_trend(Some(250), 1000, 0, 100, 1, 80_000);
            let before = ctrl.current();
            if ctrl.on_report(&est) < before {
                cut_tick = Some(i);
                break;
            }
        }
        assert_eq!(cut_tick, Some(CUT_HOLD_TICKS));
        assert!(ctrl.knee_bps().is_some());
    }
}
