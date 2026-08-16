//! The live stream's additive-increase, multiplicative-decrease bitrate controller.
//!
//! It consumes the clock-skew-free [`NetworkEstimate`] and decides a new live target, which the
//! host actuates on the encoder. On congestion the target DROPS multiplicatively — fast back-off —
//! and on a clean link past a hold-down it CLIMBS additively, a slow probe toward the ceiling.
//!
//! Pure and deterministic: no clock and no I/O. "Time" is the COUNT OF FOLDED REPORTS, so every
//! window below is a report count rather than a duration. The ceiling and floor are injected at
//! construction and re-seeded per encoder build, so a resize re-anchors to the new resolution.
//!
//! ## Every stability rule here was bought with a measurement
//!
//! * **Loss decisions key on the RAW sample, not the smoothed rate.** One transient spike costs
//!   exactly ONE decrease; a clean report reads raw loss zero, so the decaying tail of a past spike
//!   cannot re-trip the threshold report after report.
//! * **A warmup suppresses all action at cold start**, so an open-loop start with no data yet can
//!   never trigger a spurious drop.
//! * **The round-trip path needs ABSOLUTE slack on top of the multiplicative factor.** On a
//!   low-latency link a 1.25× threshold is a few milliseconds — pure scheduling noise, which trips
//!   it permanently. Real queue build-up is tens of milliseconds of absolute inflation.
//! * **And it must be SUSTAINED**: a consecutive streak of inflated reports before it may cut, so a
//!   one-report blip never acts. The two-sample jitter hint is deliberately NOT consulted — on a
//!   steady link it flaps about evenly, which is a coin flip rather than a signal.
//! * **Round-trip cuts are PROPORTIONAL to the measured queue.** A large standing queue cuts hard
//!   in one step, while the post-congestion decay tail trims a few percent at most, so a
//!   cut-cascade to the floor is structurally impossible.
//! * **ONE multiplicative cut per cut-hold window, loss included.** A loss branch that fires on
//!   every report over the threshold cascades: measured inter-provider weather bursts span several
//!   consecutive reports, so one short burst would walk the rate to the floor while forward error
//!   correction was already recovering every frame — cutting bought nothing. The first cut of an
//!   episode is still immediate; a burst that persists past the window cuts again.
//! * **No fast-halve on a raw sample.** A report window holds only a few frames, so ONE lost frame
//!   reads as a third of them — quantisation noise, not severity. A true collapse is keyed on the
//!   SMOOTHED rate and needs sustained heavy loss to arm.
//! * **A queue-corroborated cut remembers where it landed as the KNEE**, and additive increase at
//!   or above it runs at a fraction of the step, so recovery hovers under the rate that built the
//!   queue instead of re-bashing it every second. The knee expires without re-confirmation, because
//!   path conditions drift.
//!
//! ## Safe when telemetry is off
//!
//! With no loss and no valid baseline the congestion predicate is always false, so the controller
//! can only increase — and it starts AT the ceiling and is clamped there, which makes it a no-op.
//! It NEVER decreases on absence of data, only on positive evidence.

use crate::live_bitrate::MINIMUM_BITRATE;
use crate::network_estimate::NetworkEstimate;

/// The tunables. Every default is the production value.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CongestionConfig {
    /// Reports to fold before ANY action — the cold-start guard.
    pub warmup_ticks: u32,
    /// The raw per-report loss sample above which the link counts as congested.
    pub loss_threshold: f64,
    /// The raw-sample gate the catastrophic halve ALSO requires, on top of the smoothed collapse.
    pub severe_loss_threshold: f64,
    /// Whether loss below the catastrophic line decreases ONLY when corroborated by round-trip
    /// inflation.
    ///
    /// Measured on a real inter-provider path, loss is around one percent at every actuated rate —
    /// rate-INDEPENDENT weather, with multi-second burst episodes at FLAT round trip. Backing off
    /// cannot reduce that loss; it only degrades the picture. Loss WITH inflation is a building
    /// queue, which is real congestion, and there the classic response stays.
    pub loss_needs_rtt_corroboration: bool,
    /// The smoothed loss rate above which the target halves even at flat round trip: a queueless
    /// policer or a true link collapse drops without inflating anything, and at a sustained quarter
    /// of all frames the stream is unusable whatever the cause.
    pub catastrophic_loss_threshold: f64,
    /// The multiplicative factor on ordinary congestion.
    pub decrease_factor: f64,
    /// The multiplicative factor on the catastrophic branch.
    pub severe_decrease_factor: f64,
    /// The additive step is the ceiling over this, per clean report.
    pub increase_divisor: i64,
    /// The fraction of the target the stream must actually be USING before the controller probes
    /// higher.
    ///
    /// Below it the stream is APPLICATION-limited — an idle or near-static screen — so probing only
    /// inflates phantom headroom that a later burst overshoots into a queue.
    pub ramp_utilization_fraction: f64,
    /// The fraction below which the stream is DEEPLY idle and the target DECAYS toward what is
    /// offered. Stricter than the ramp gate, so a brief pause holds but a sustained static screen
    /// shrinks the target, and a post-idle burst cannot form a monster frame.
    pub decay_utilization_fraction: f64,
    /// While idle the target decays toward the offered throughput times this headroom.
    pub decay_headroom: f64,
    /// The fraction of the remaining gap closed per idle report.
    pub decay_step_fraction: f64,
    /// Reports to suppress any increase after a decrease — the anti-thrash hold-down.
    pub hold_ticks: u32,
    /// The multiplicative inflation over the baseline that signals queue build-up.
    pub rtt_inflate_factor: f64,
    /// The ABSOLUTE inflation over the baseline also required, which keeps scheduling wobble on a
    /// short-baseline link below the threshold.
    pub rtt_slack_millis: f64,
    /// The BASELINE-PROPORTIONAL slack, for paths whose own texture is proportional.
    ///
    /// A fixed slack suits a short baseline, but on a measured cellular path the scheduler's wobble
    /// is about half the baseline again and is rate-INDEPENDENT — identical at every actuated rate
    /// — so a bare fixed slack trips constantly and perpetual small trims pin the rate far
    /// below what the path was carrying. This reclassifies the sub-threshold band as weather
    /// while a real queue still cuts; a short baseline is unaffected, since the fixed floor
    /// dominates there.
    pub rtt_slack_fraction: f64,
    /// Consecutive inflated reports required before the round-trip path may decrease.
    pub rtt_streak_ticks: u32,
    /// Reports between ANY multiplicative decreases, both paths.
    ///
    /// A full increase hold-down would be right for a FIXED step, but a real persistent queue then
    /// drains at one small step per second — multi-second latency episodes. The decrease is
    /// proportional to the measured queue, so the cascade a long spacing guards against is
    /// self-limiting anyway, and the shorter spacing lets the controller chase a real queue.
    pub cut_hold_ticks: u32,
    /// The hardest single proportional cut.
    pub rtt_decrease_floor_factor: f64,
    /// The gentlest proportional cut, so barely-over-threshold inflation still trims a little and
    /// the decay tail can never re-cut deeply.
    pub rtt_decrease_cap_factor: f64,
    /// The extra divisor applied to the additive step at or above the remembered knee.
    ///
    /// Deliberately CONSTANT. An escalating variant — doubling the divisor per re-confirmation — is
    /// falsified by live cellular: the wobble is rate-independent, so each one trims and resets the
    /// hold, and any climb slower than this base cannot cross the actuation gap between wobbles, so
    /// the rate pins near the floor for most of a session with a soft picture and no latency
    /// benefit. The constant divisor rides through the wobble instead.
    pub knee_caution_divisor: i64,
    /// Reports the knee survives without a fresh queue-corroborated decrease.
    pub knee_ttl_ticks: u32,
    /// The floor as a fraction of the ceiling.
    pub min_fraction: f64,
    /// The open-loop START fraction of the ceiling.
    ///
    /// One means start AT the ceiling. Below one seeds under it, so the first heavy burst cannot
    /// self-induce a queue before the loop's first report reacts; the cost is a brief ramp — a
    /// softer picture — at connect and resize.
    pub seed_fraction: f64,
    /// The actuation churn gate as a fraction of the ceiling.
    pub material_fraction: f64,
    /// The actuation churn gate as an absolute floor.
    pub material_floor_bps: i64,
    /// The multiplicative factor for a gradient-authorised cut — the same depth as the loss path.
    pub gradient_decrease_factor: f64,
}

impl Default for CongestionConfig {
    fn default() -> Self {
        Self {
            warmup_ticks: 10,
            loss_threshold: 0.02,
            severe_loss_threshold: 0.10,
            loss_needs_rtt_corroboration: true,
            catastrophic_loss_threshold: 0.25,
            decrease_factor: 0.85,
            severe_decrease_factor: 0.5,
            increase_divisor: 32,
            ramp_utilization_fraction: 0.5,
            decay_utilization_fraction: 0.25,
            decay_headroom: 2.0,
            decay_step_fraction: 0.25,
            hold_ticks: 20,
            rtt_inflate_factor: 1.25,
            rtt_slack_millis: 15.0,
            rtt_slack_fraction: 0.75,
            rtt_streak_ticks: 3,
            cut_hold_ticks: 8,
            rtt_decrease_floor_factor: 0.6,
            rtt_decrease_cap_factor: 0.95,
            knee_caution_divisor: 8,
            knee_ttl_ticks: 1200,
            min_fraction: 0.25,
            seed_fraction: 1.0,
            material_fraction: 0.05,
            material_floor_bps: 500_000,
            gradient_decrease_factor: 0.85,
        }
    }
}

/// Why the controller moved, or held, this report.
///
/// Observability only, with zero behavioural weight — but without it the gradient path's efficacy
/// is unmeasurable from logs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CutReason {
    /// The cold-start guard: no action is possible.
    Warmup,
    /// No branch fired — sub-threshold, or inside a hold-down.
    Hold,
    /// Inflated with a satisfied streak and an expired cut-hold, but the round trip is IMPROVING,
    /// so the drain gate held the cut: the queue is already flushing.
    Drain,
    /// Additive increase — the normal probe toward the ceiling.
    Probe,
    /// Additive increase at or above the remembered knee — the cautious step.
    Knee,
    /// Decay while DEEPLY application-limited. Not congestion: the target drifts toward what the
    /// stream is actually offering, so a post-idle burst stays bounded.
    AppLimited,
    /// The proportional delay-targeting cut, on a sustained inflation streak.
    RttStreak,
    /// A loss-corroborated cut: raw loss over the threshold WITH inflation evidence.
    LossCorroborated,
    /// The early cut: the client's trendline reads overusing and the raw round trip corroborates.
    Gradient,
    /// The catastrophic halve, on sustained heavy loss.
    Catastrophic,
}

/// One report's outcome: the new target, and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CongestionDecision {
    /// The new live target in bits per second.
    pub target: i64,
    /// The branch that set it.
    pub reason: CutReason,
}

/// Every number a fold reads, as one flat value.
///
/// The controller is a VALUE to its owner — copied out, folded into, written back — and an owner on
/// the far side of a boundary has to carry all of it, not just the target. Nothing here is derived:
/// a snapshot missing `rtt_inflated_streak` would need a fresh streak after every crossing, and one
/// missing `prev_smoothed_rtt_millis` would lose the drain gate entirely.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CongestionSnapshot {
    /// The tunables.
    pub config: CongestionConfig,
    /// The policy ceiling for this encoder build.
    pub ceiling: i64,
    /// The lowest rate the controller may drive.
    pub floor: i64,
    /// The client-requested ceiling layered under the policy one, if any.
    pub user_ceiling_bps: Option<i64>,
    /// Whether the delay-gradient early cut is armed.
    pub gradient_cut_enabled: bool,
    /// The current target.
    pub current: i64,
    /// The folded-report count — the clock.
    pub ticks: u32,
    /// No increase until the clock reaches this.
    pub hold_until_tick: u32,
    /// Consecutive reports that cleared both inflation gates.
    pub rtt_inflated_streak: u32,
    /// No multiplicative decrease until the clock reaches this.
    pub cut_hold_until_tick: u32,
    /// The previous report's smoothed round trip — the drain gate's comparison.
    pub prev_smoothed_rtt_millis: f64,
    /// The remembered knee, if one is live.
    pub knee_bps: Option<i64>,
    /// The report at which the knee expires.
    pub knee_expires_at_tick: u32,
}

/// The controller.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiveCongestionController {
    /// The tunables.
    config: CongestionConfig,
    /// The policy ceiling for THIS encoder build — the hard bound the controller can never exceed.
    ceiling: i64,
    /// The lowest the controller may drive the rate. Never below the encoder minimum, so never
    /// zero.
    floor: i64,
    /// An optional client-requested ceiling layered UNDER the policy ceiling.
    user_ceiling_bps: Option<i64>,
    /// Whether the delay-gradient early cut is armed.
    gradient_cut_enabled: bool,
    /// The current target.
    current: i64,
    /// The folded-report count — the controller's clock.
    ticks: u32,
    /// No increase is permitted until the clock reaches this.
    hold_until_tick: u32,
    /// Consecutive reports that cleared BOTH inflation gates. Reset on EVERY decrease, so each
    /// re-decrease needs a fresh sustained run.
    rtt_inflated_streak: u32,
    /// No multiplicative decrease of any kind is permitted until the clock reaches this — the short
    /// re-decrease spacing, distinct from the long increase hold-down.
    cut_hold_until_tick: u32,
    /// The previous report's smoothed round trip — the one-report delay TREND.
    ///
    /// A cut additionally requires the smoothed round trip to be NOT IMPROVING against it: a queue
    /// already DRAINING must not keep triggering cuts, or a backlog flushing out walks the rate
    /// down to the floor. A standing or growing queue reads flat or rising and keeps cutting.
    /// This is smoothed against smoothed, not the two-sample jitter coin flip.
    prev_smoothed_rtt_millis: f64,
    /// The remembered knee: the rate the controller landed on after the most recent
    /// queue-corroborated decrease.
    knee_bps: Option<i64>,
    /// The report at which the knee expires, refreshed by every queue-corroborated decrease.
    knee_expires_at_tick: u32,
}

impl LiveCongestionController {
    /// A controller with an explicit floor.
    ///
    /// The floor is clamped into the encoder minimum and the ceiling, so the rate can never be
    /// driven to zero nor below a usable minimum. The target is seeded at the ceiling times the
    /// configured seed fraction, never below the floor; additive increase then probes back up.
    #[must_use]
    pub fn new(ceiling: i64, floor: i64, config: CongestionConfig, gradient_cut_enabled: bool) -> Self {
        let ceiling = ceiling.max(1);
        let floor = MINIMUM_BITRATE.max(floor.min(ceiling));
        let fraction = config.seed_fraction.clamp(0.0, 1.0);
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate in bits per second is far inside f64's exact integer range"
        )]
        let seeded = (ceiling as f64) * fraction;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the seeded rate is bounded above by the ceiling it scaled"
        )]
        let seeded = seeded.round() as i64;
        Self {
            config,
            ceiling,
            floor,
            user_ceiling_bps: None,
            gradient_cut_enabled,
            current: floor.max(seeded),
            ticks: 0,
            hold_until_tick: 0,
            rtt_inflated_streak: 0,
            cut_hold_until_tick: 0,
            prev_smoothed_rtt_millis: 0.0,
            knee_bps: None,
            knee_expires_at_tick: 0,
        }
    }

    /// A controller whose floor is derived from the ceiling by the configured fraction — the
    /// production wiring, which keeps the floor policy in one place.
    #[must_use]
    pub fn with_ceiling(ceiling: i64, config: CongestionConfig, gradient_cut_enabled: bool) -> Self {
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate in bits per second is far inside f64's exact integer range"
        )]
        let scaled = (ceiling.max(1) as f64) * config.min_fraction;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the derived floor is bounded above by the ceiling it scaled"
        )]
        let floor = scaled as i64;
        Self::new(ceiling, floor, config, gradient_cut_enabled)
    }

    /// Every number this controller holds, flat.
    #[must_use]
    pub const fn snapshot(&self) -> CongestionSnapshot {
        CongestionSnapshot {
            config: self.config,
            ceiling: self.ceiling,
            floor: self.floor,
            user_ceiling_bps: self.user_ceiling_bps,
            gradient_cut_enabled: self.gradient_cut_enabled,
            current: self.current,
            ticks: self.ticks,
            hold_until_tick: self.hold_until_tick,
            rtt_inflated_streak: self.rtt_inflated_streak,
            cut_hold_until_tick: self.cut_hold_until_tick,
            prev_smoothed_rtt_millis: self.prev_smoothed_rtt_millis,
            knee_bps: self.knee_bps,
            knee_expires_at_tick: self.knee_expires_at_tick,
        }
    }

    /// A controller rebuilt from a snapshot, with the bounds `new` establishes re-established.
    ///
    /// This is what an owner that keeps the controller BY VALUE needs, and a snapshot that crossed
    /// a boundary is untrusted like any other input: the ceiling is positive, the floor sits
    /// inside the encoder minimum and the ceiling, and the target sits inside the floor and the
    /// EFFECTIVE ceiling — so a hostile snapshot cannot make the next fold hand the encoder a
    /// rate no `new` could have produced. The clock and the streaks are carried verbatim,
    /// because they ARE the state and nothing about them can be checked.
    #[must_use]
    pub fn restored(snapshot: CongestionSnapshot) -> Self {
        let ceiling = snapshot.ceiling.max(1);
        let floor = MINIMUM_BITRATE.max(snapshot.floor.min(ceiling));
        let mut restored = Self {
            config: snapshot.config,
            ceiling,
            floor,
            user_ceiling_bps: match snapshot.user_ceiling_bps {
                Some(bps) if bps > 0 => Some(bps),
                _ => None,
            },
            gradient_cut_enabled: snapshot.gradient_cut_enabled,
            current: snapshot.current,
            ticks: snapshot.ticks,
            hold_until_tick: snapshot.hold_until_tick,
            rtt_inflated_streak: snapshot.rtt_inflated_streak,
            cut_hold_until_tick: snapshot.cut_hold_until_tick,
            prev_smoothed_rtt_millis: snapshot.prev_smoothed_rtt_millis,
            knee_bps: snapshot.knee_bps,
            knee_expires_at_tick: snapshot.knee_expires_at_tick,
        };
        // Floor-last, exactly as `new` seeds it (`floor.max(seeded)`) — NOT `clamp`, which asserts
        // its bounds are ordered. A ceiling under the encoder minimum leaves the floor ABOVE the
        // ceiling, which `new` already permits and answers by returning the floor; `clamp` would
        // panic there instead, and a panic crossing the C boundary aborts the process.
        restored.current = floor.max(restored.current.min(restored.effective_ceiling()));
        restored
    }

    /// The policy ceiling.
    #[must_use]
    pub const fn ceiling(&self) -> i64 {
        self.ceiling
    }

    /// The floor.
    #[must_use]
    pub const fn floor(&self) -> i64 {
        self.floor
    }

    /// The current target.
    #[must_use]
    pub const fn current(&self) -> i64 {
        self.current
    }

    /// The remembered knee, if one is live.
    #[must_use]
    pub const fn knee_bps(&self) -> Option<i64> {
        self.knee_bps
    }

    /// The ceiling every climb is clamped to: the policy ceiling bounded by the user override,
    /// itself floored, so a pathological low override can never starve the encoder below the usable
    /// minimum. With no override this is exactly the policy ceiling, and the control law is
    /// untouched.
    #[must_use]
    pub const fn effective_ceiling(&self) -> i64 {
        match self.user_ceiling_bps {
            Some(user) if user > 0 => {
                let raised = if user > self.floor { user } else { self.floor };
                if raised < self.ceiling {
                    raised
                } else {
                    self.ceiling
                }
            },
            _ => self.ceiling,
        }
    }

    /// Sets, or with a non-positive value clears, the user ceiling.
    ///
    /// A target above the new effective ceiling CLAMPS DOWN IMMEDIATELY — the override must bite on
    /// the very next actuation, not after a whole congestion episode — and every later climb is
    /// capped there. Clearing restores the policy ceiling, and the reclaimed headroom is climbed
    /// back through the ordinary probe rather than jumped.
    pub const fn set_user_ceiling_bps(&mut self, user_bps: Option<i64>) {
        self.user_ceiling_bps = match user_bps {
            Some(bps) if bps > 0 => Some(bps),
            _ => None,
        };
        let ceiling = self.effective_ceiling();
        if self.current > ceiling {
            self.current = ceiling;
        }
    }

    /// The effective absolute-slack gate for a path baseline: the fixed slack, or the proportional
    /// one when the baseline is long enough to make it bigger.
    ///
    /// IEEE-faithful: the maximum here returns the non-NaN operand rather than poisoning, so a
    /// nonsense baseline degrades to the fixed slack instead of disabling the gate.
    #[must_use]
    pub fn effective_slack_millis(&self, min_rtt_millis: f64) -> f64 {
        effective_slack_millis(&self.config, min_rtt_millis)
    }

    /// Folds one estimate and returns the new target, with the branch that set it.
    ///
    /// `offered_bps` is the host's recent encoded throughput. When supplied and the stream is
    /// APPLICATION-limited — offering far below the target, an idle or near-static screen — the
    /// increase is SUPPRESSED, so an idle stretch cannot inflate the target into phantom headroom a
    /// sudden burst then overshoots into a queue. `None` means no utilization gate, so it always
    /// probes.
    ///
    /// Decision order: warmup, then the catastrophic halve, then the ordinary multiplicative
    /// decrease, then — past the hold-down — the additive increase. The result is always within the
    /// floor and the ceiling.
    pub fn decide(&mut self, estimate: &NetworkEstimate, offered_bps: Option<f64>) -> CongestionDecision {
        self.ticks = self.ticks.saturating_add(1);
        let decision = self.decide_inner(estimate, offered_bps);
        // This report's smoothed round trip becomes the next report's comparison, whatever branch
        // ran — including warmup.
        self.prev_smoothed_rtt_millis = estimate.smoothed_rtt_millis;
        decision
    }

    /// The additive step, at least one so a tiny ceiling still makes progress.
    #[expect(
        clippy::integer_division,
        reason = "the step is a whole number of bits per second, and truncating it is the pinned rule"
    )]
    const fn increase_step(&self) -> i64 {
        let step = self.ceiling / self.config.increase_divisor;
        if step > 1 { step } else { 1 }
    }

    /// This report's additive step, and whether it is the CAUTIOUS one — a climb at or above the
    /// remembered knee runs at a fraction of the step, so recovery hovers under the rate that built
    /// the queue instead of re-bashing it.
    #[expect(
        clippy::integer_division,
        reason = "the step is a whole number of bits per second, and truncating it is the pinned rule"
    )]
    const fn ramp_step(&self) -> (i64, bool) {
        let full = self.increase_step();
        match self.knee_bps {
            Some(knee) if self.current >= knee => {
                let cautious = full / self.config.knee_caution_divisor;
                (if cautious > 1 { cautious } else { 1 }, true)
            },
            _ => (full, false),
        }
    }

    /// Whether the stream is using enough of its target to justify probing higher. No signal always
    /// permits.
    fn utilization_permits_ramp(&self, offered_bps: Option<f64>) -> bool {
        let Some(offered) = offered_bps.filter(|offered| offered.is_finite()) else {
            return true;
        };
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate in bits per second is far inside f64's exact integer range"
        )]
        let gate = (self.current as f64) * self.config.ramp_utilization_fraction;
        offered >= gate
    }

    /// The decayed target for a DEEPLY application-limited report, or `None` when no decay applies.
    fn app_limited_decay(&self, offered_bps: Option<f64>) -> Option<i64> {
        let offered = offered_bps.filter(|offered| offered.is_finite())?;
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate in bits per second is far inside f64's exact integer range"
        )]
        let idle_gate = (self.current as f64) * self.config.decay_utilization_fraction;
        if offered >= idle_gate {
            return None; // not deeply idle — hold rather than decay
        }
        let decay_target = offered * self.config.decay_headroom;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "truncation toward zero is the pinned rule, and the value is a bitrate"
        )]
        let target = self.floor.max(decay_target as i64);
        if target >= self.current {
            return None; // already at or below the idle target
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate in bits per second is far inside f64's exact integer range"
        )]
        let gap = ((self.current - target) as f64) * self.config.decay_step_fraction;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "truncation toward zero is the pinned rule, and the value is a bitrate"
        )]
        let step = gap as i64;
        Some((self.current - step.max(1)).max(target))
    }

    /// Applies a decrease and arms the hold-downs — ONLY when the target actually lowers the rate.
    /// A queue-corroborated decrease additionally records the knee.
    const fn apply_decrease(&mut self, next: i64, queue_corroborated: bool) {
        if next < self.current {
            self.current = next;
            self.hold_until_tick = self.ticks + self.config.hold_ticks;
            self.cut_hold_until_tick = self.ticks + self.config.cut_hold_ticks;
            self.rtt_inflated_streak = 0;
            if queue_corroborated {
                self.knee_bps = Some(self.current);
                self.knee_expires_at_tick = self.ticks + self.config.knee_ttl_ticks;
            }
        }
    }

    /// The DEEPEST cut any armed branch asks for, and which branch that was.
    ///
    /// At least one flag is set by construction, so the seeded reason is always overwritten.
    fn cut_target(
        &self,
        estimate: &NetworkEstimate,
        slack: f64,
        rtt_congested: bool,
        loss_congested: bool,
        gradient_congested: bool,
    ) -> (i64, CutReason) {
        let mut target = i64::MAX;
        let mut reason = CutReason::Hold;
        if rtt_congested {
            let drained = estimate.min_rtt_millis + slack;
            // IEEE-faithful clamp: the ratio of the drained round trip to the measured one, held
            // between the hardest and the gentlest single cut.
            let ratio = drained / estimate.smoothed_rtt_millis;
            let factor = self
                .config
                .rtt_decrease_cap_factor
                .min(self.config.rtt_decrease_floor_factor.max(ratio));
            let cut = self.scaled(factor);
            if cut < target {
                target = cut;
                reason = CutReason::RttStreak;
            }
        }
        if loss_congested {
            let cut = self.scaled(self.config.decrease_factor);
            if cut < target {
                target = cut;
                reason = CutReason::LossCorroborated;
            }
        }
        if gradient_congested {
            let cut = self.scaled(self.config.gradient_decrease_factor);
            if cut < target {
                target = cut;
                reason = CutReason::Gradient;
            }
        }
        (target, reason)
    }

    /// The move a CLEAN link past the hold-down makes: RAMP while using the allocation, DECAY while
    /// deeply idle, and `None` in the band between the two fractions, which holds.
    ///
    /// With no utilization signal at all this is always a ramp.
    fn clean_link_step(&mut self, offered_bps: Option<f64>) -> Option<CongestionDecision> {
        if self.utilization_permits_ramp(offered_bps) {
            let (step, cautious) = self.ramp_step();
            self.current = self.effective_ceiling().min(self.current + step);
            return Some(CongestionDecision {
                target: self.current,
                reason: if cautious {
                    CutReason::Knee
                } else {
                    CutReason::Probe
                },
            });
        }
        let decayed = self.app_limited_decay(offered_bps)?;
        self.current = decayed;
        Some(CongestionDecision {
            target: self.current,
            reason: CutReason::AppLimited,
        })
    }

    /// The control-law step over one folded estimate.
    fn decide_inner(&mut self, estimate: &NetworkEstimate, offered_bps: Option<f64>) -> CongestionDecision {
        if self.ticks < self.config.warmup_ticks {
            return CongestionDecision {
                target: self.current,
                reason: CutReason::Warmup,
            };
        }

        let slack = self.effective_slack_millis(estimate.min_rtt_millis);
        let inflate_threshold = estimate.min_rtt_millis * self.config.rtt_inflate_factor;
        let slack_threshold = estimate.min_rtt_millis + slack;
        let rtt_inflated = estimate.min_rtt_millis.is_finite()
            && estimate.smoothed_rtt_millis > inflate_threshold
            && estimate.smoothed_rtt_millis > slack_threshold;
        self.rtt_inflated_streak = if rtt_inflated {
            self.rtt_inflated_streak.saturating_add(1)
        } else {
            0
        };
        let rtt_congested = rtt_inflated
            && self.rtt_inflated_streak >= self.config.rtt_streak_ticks
            && self.ticks >= self.cut_hold_until_tick
            && estimate.smoothed_rtt_millis + 1.0 >= self.prev_smoothed_rtt_millis;

        // Forget a knee that has not been re-confirmed inside its lifetime.
        if self.knee_bps.is_some() && self.ticks >= self.knee_expires_at_tick {
            self.knee_bps = None;
        }

        let loss_evidence = !self.config.loss_needs_rtt_corroboration || rtt_inflated;
        let loss_congested = estimate.last_loss_sample > self.config.loss_threshold
            && loss_evidence
            && self.ticks >= self.cut_hold_until_tick;
        let raw_rtt_inflated = match estimate.last_rtt_sample_millis {
            Some(raw) if estimate.min_rtt_millis.is_finite() => {
                let raw_inflate = estimate.min_rtt_millis * self.config.rtt_inflate_factor;
                let raw_slack = estimate.min_rtt_millis + slack;
                raw > raw_inflate && raw > raw_slack
            },
            _ => false,
        };
        let gradient_congested = self.gradient_cut_enabled
            && estimate.owd_trend_overusing
            && raw_rtt_inflated
            && self.ticks >= self.cut_hold_until_tick;

        if estimate.loss_rate > self.config.catastrophic_loss_threshold
            && estimate.last_loss_sample > self.config.severe_loss_threshold
            && self.ticks >= self.hold_until_tick
        {
            let target = self.floor.max(self.scaled(self.config.severe_decrease_factor));
            self.apply_decrease(target, rtt_inflated);
            return CongestionDecision {
                target: self.current,
                reason: CutReason::Catastrophic,
            };
        }
        if rtt_congested || loss_congested || gradient_congested {
            let (target, reason) =
                self.cut_target(estimate, slack, rtt_congested, loss_congested, gradient_congested);
            self.apply_decrease(self.floor.max(target), rtt_inflated);
            return CongestionDecision {
                target: self.current,
                reason,
            };
        }
        if self.ticks >= self.hold_until_tick
            && !rtt_inflated
            && !(self.gradient_cut_enabled && estimate.owd_trend_overusing)
            && let Some(decision) = self.clean_link_step(offered_bps)
        {
            return decision;
        }
        let drain_gated = rtt_inflated
            && self.rtt_inflated_streak >= self.config.rtt_streak_ticks
            && self.ticks >= self.cut_hold_until_tick
            && estimate.smoothed_rtt_millis + 1.0 < self.prev_smoothed_rtt_millis;
        CongestionDecision {
            target: self.current,
            reason: if drain_gated {
                CutReason::Drain
            } else {
                CutReason::Hold
            },
        }
    }

    /// The current target scaled by a factor, truncated toward zero — the pinned rule for every
    /// multiplicative cut.
    fn scaled(&self, factor: f64) -> i64 {
        #[expect(
            clippy::cast_precision_loss,
            reason = "a bitrate in bits per second is far inside f64's exact integer range"
        )]
        let scaled = (self.current as f64) * factor;
        #[expect(
            clippy::cast_possible_truncation,
            reason = "truncation toward zero is the pinned rule, and the value is a bitrate"
        )]
        let truncated = scaled as i64;
        truncated
    }
}

/// The effective absolute-slack gate for a path baseline: the fixed slack, or the proportional one
/// when the baseline is long enough to make it bigger.
///
/// Free-standing because the frame-rate governor's congestion predicate consults the SAME rule, so
/// the two controllers cannot drift apart on what "inflated" means.
///
/// IEEE-faithful: the maximum here returns the non-NaN operand rather than poisoning, so a nonsense
/// baseline degrades to the fixed slack instead of disabling the gate.
#[must_use]
pub fn effective_slack_millis(config: &CongestionConfig, min_rtt_millis: f64) -> f64 {
    if min_rtt_millis.is_finite() {
        let scaled = config.rtt_slack_fraction * min_rtt_millis;
        config.rtt_slack_millis.max(scaled)
    } else {
        config.rtt_slack_millis
    }
}

/// Whether a target change is large enough to be worth actuating on the encoder.
///
/// The host throttles actuation to MATERIAL moves, so a single small additive step does not actuate
/// on every report; consecutive steps accumulate against the last ACTUATED rate and cross the gate
/// after a couple of reports.
#[must_use]
pub fn is_material_change(previous: i64, target: i64, ceiling: i64, config: CongestionConfig) -> bool {
    #[expect(
        clippy::cast_precision_loss,
        reason = "a bitrate in bits per second is far inside f64's exact integer range"
    )]
    let scaled = (ceiling.max(1) as f64) * config.material_fraction;
    #[expect(
        clippy::cast_possible_truncation,
        reason = "truncation toward zero is the pinned rule, and the value is a bitrate"
    )]
    let threshold = config.material_floor_bps.max(scaled as i64);
    (target - previous).abs() >= threshold
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::integer_division,
        clippy::cast_precision_loss,
        reason = "a panic in a test is the failure report, not a runtime fault, and the arithmetic here is \
                  on literal bitrates chosen to divide exactly"
    )]

    use super::{CongestionConfig, CutReason, LiveCongestionController, NetworkEstimate, is_material_change};

    const CEILING: i64 = 32_000_000;

    /// An estimate with a clean, short-baseline link.
    fn clean() -> NetworkEstimate {
        let mut estimate = NetworkEstimate::new();
        for _ in 0..4 {
            estimate.fold(Some(10), 100, 0, 0, 0, 0);
        }
        estimate
    }

    /// An estimate with a standing queue: the baseline is short, the smoothed round trip is not.
    ///
    /// Deliberately only twenty reports deep. The baseline RE-BASELINES at one percent of the gap
    /// per fold, so a queue held long enough eventually drags the baseline up with it and the path
    /// stops reading as inflated at all — which is the estimator's design, not a shortcut here.
    fn queued() -> NetworkEstimate {
        let mut estimate = clean();
        for _ in 0..20 {
            estimate.fold(Some(120), 100, 0, 0, 0, 0);
        }
        estimate
    }

    /// Folds `count` clean reports, discarding the decisions.
    fn warm(controller: &mut LiveCongestionController, count: u32) {
        let estimate = clean();
        for _ in 0..count {
            controller.decide(&estimate, None);
        }
    }

    #[test]
    fn nothing_happens_during_the_warmup() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        let estimate = queued();
        // The counter advances BEFORE the gate, so the nth report is the first one that may act.
        for _ in 1..CongestionConfig::default().warmup_ticks {
            let decision = controller.decide(&estimate, None);
            assert_eq!(decision.reason, CutReason::Warmup);
            assert_eq!(decision.target, CEILING);
        }
        assert_ne!(controller.decide(&estimate, None).reason, CutReason::Warmup);
    }

    /// With telemetry off the controller is inert: it starts at the ceiling and can only climb.
    #[test]
    fn absence_of_data_never_decreases_the_target() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        let blind = NetworkEstimate::new();
        for _ in 0..500 {
            let decision = controller.decide(&blind, None);
            assert_eq!(decision.target, CEILING, "clamped at the ceiling it started on");
        }
    }

    #[test]
    fn a_sustained_queue_cuts_proportionally_to_its_depth() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let queued = queued();
        // The streak has to build first: one inflated report never acts.
        assert_eq!(controller.decide(&queued, None).reason, CutReason::Hold);
        assert_eq!(controller.decide(&queued, None).reason, CutReason::Hold);
        let decision = controller.decide(&queued, None);
        assert_eq!(decision.reason, CutReason::RttStreak);
        assert!(decision.target < CEILING);
        // A deep queue cuts hard — down to the floor factor, not a timid few percent.
        assert!(
            decision.target <= CEILING * 3 / 5 + 1,
            "a deep queue cuts to the floor factor: {}",
            decision.target,
        );
        assert_eq!(
            controller.knee_bps(),
            Some(decision.target),
            "and remembers the knee"
        );
    }

    /// The measured failure the raw-sample rule exists to prevent.
    #[test]
    fn one_transient_loss_spike_costs_exactly_one_cut() {
        let config = CongestionConfig {
            loss_needs_rtt_corroboration: false,
            ..CongestionConfig::default()
        };
        let mut controller = LiveCongestionController::with_ceiling(CEILING, config, false);
        warm(&mut controller, 20);
        let mut estimate = clean();
        estimate.fold(Some(10), 100, 20, 0, 0, 0);
        let cut = controller.decide(&estimate, None);
        assert_eq!(cut.reason, CutReason::LossCorroborated);
        // Now perfectly clean reports, while the smoothed rate is still above the threshold.
        estimate.fold(Some(10), 100, 0, 0, 0, 0);
        assert!(
            estimate.loss_rate > config.loss_threshold,
            "the average still remembers"
        );
        let after = controller.decide(&estimate, None);
        assert_eq!(
            after.target, cut.target,
            "but the raw sample reads clean, so no cascade"
        );
    }

    /// Rate-independent weather must not walk the rate down.
    #[test]
    fn loss_at_a_flat_round_trip_is_weather_rather_than_congestion() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let before = controller.current();
        let mut estimate = clean();
        for _ in 0..20 {
            estimate.fold(Some(10), 100, 8, 0, 0, 0); // eight percent loss, flat round trip
            controller.decide(&estimate, None);
        }
        assert!(controller.current() >= before, "uncorroborated loss must not cut");
    }

    /// …but a true collapse still halves, corroboration or not.
    #[test]
    fn a_sustained_collapse_halves_even_at_a_flat_round_trip() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let mut estimate = clean();
        let mut halved = false;
        for _ in 0..20 {
            estimate.fold(Some(10), 100, 90, 0, 0, 0);
            if controller.decide(&estimate, None).reason == CutReason::Catastrophic {
                halved = true;
                break;
            }
        }
        assert!(halved, "sustained ninety percent loss is not weather");
        assert!(controller.current() < CEILING);
    }

    #[test]
    fn a_draining_queue_stops_triggering_cuts() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let mut estimate = queued();
        for _ in 0..3 {
            controller.decide(&estimate, None);
        }
        let after_cut = controller.current();
        // The backlog now flushes out: the smoothed round trip falls report over report.
        let mut saw_drain = false;
        for _ in 0..40 {
            estimate.fold(Some(11), 100, 0, 0, 0, 0);
            if controller.decide(&estimate, None).reason == CutReason::Drain {
                saw_drain = true;
            }
        }
        assert!(saw_drain, "the drain gate must be reachable");
        assert!(
            controller.current() >= after_cut,
            "a draining queue must not walk to the floor"
        );
    }

    #[test]
    fn recovery_is_slow_and_hovers_under_the_knee() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let queued = queued();
        for _ in 0..3 {
            controller.decide(&queued, None);
        }
        let knee = controller
            .knee_bps()
            .expect("a queue-corroborated cut sets the knee");
        let clean = clean();
        let mut saw_knee_step = false;
        for _ in 0..60 {
            if controller.decide(&clean, None).reason == CutReason::Knee {
                saw_knee_step = true;
            }
        }
        assert!(
            saw_knee_step,
            "climbing back through the knee uses the cautious step"
        );
        assert!(controller.current() >= knee);
        assert!(
            controller.current() < CEILING,
            "and does not re-bash the ceiling at once"
        );
    }

    #[test]
    fn an_idle_screen_neither_probes_nor_is_treated_as_congestion() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let clean = clean();
        let before = controller.current();
        // Offering a tenth of the target: deeply application-limited.
        let decision = controller.decide(&clean, Some(before as f64 * 0.1));
        assert_eq!(decision.reason, CutReason::AppLimited);
        assert!(decision.target < before);
        // Between the two fractions: neither probe nor decay.
        let held = controller.current();
        let decision = controller.decide(&clean, Some(held as f64 * 0.35));
        assert_eq!(decision.reason, CutReason::Hold);
        assert_eq!(decision.target, held);
        // And using the allocation probes again.
        let decision = controller.decide(&clean, Some(held as f64 * 0.9));
        assert_eq!(decision.reason, CutReason::Probe);
    }

    #[test]
    fn the_decay_never_goes_below_the_floor() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        let clean = clean();
        for _ in 0..500 {
            controller.decide(&clean, Some(1.0));
        }
        assert_eq!(controller.current(), controller.floor());
    }

    #[test]
    fn the_gradient_cut_only_fires_when_it_is_armed_and_corroborated() {
        let mut estimate = clean();
        estimate.fold(Some(10), 100, 0, 0, 1, 0); // overusing, but the raw sample is clean
        let mut disarmed =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut disarmed, 20);
        assert_ne!(disarmed.decide(&estimate, None).reason, CutReason::Gradient);

        let mut armed = LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), true);
        warm(&mut armed, 20);
        assert_ne!(
            armed.decide(&estimate, None).reason,
            CutReason::Gradient,
            "an uncorroborated trendline is not evidence",
        );
        // Now the same report's RAW round trip corroborates it.
        estimate.fold(Some(120), 100, 0, 0, 1, 0);
        assert_eq!(armed.decide(&estimate, None).reason, CutReason::Gradient);
    }

    #[test]
    fn a_user_ceiling_bites_immediately_and_caps_every_later_climb() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        warm(&mut controller, 20);
        controller.set_user_ceiling_bps(Some(8_000_000));
        assert_eq!(controller.current(), 8_000_000, "not after an episode — now");
        let clean = clean();
        for _ in 0..200 {
            controller.decide(&clean, None);
        }
        assert_eq!(controller.current(), 8_000_000, "and the climb is capped there");
        // Clearing restores the policy ceiling, climbed back through the ordinary probe.
        controller.set_user_ceiling_bps(None);
        assert_eq!(controller.current(), 8_000_000, "never jumped");
        controller.decide(&clean, None);
        assert!(controller.current() > 8_000_000);
    }

    #[test]
    fn a_pathological_user_ceiling_cannot_starve_the_encoder() {
        let mut controller =
            LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        controller.set_user_ceiling_bps(Some(1));
        assert_eq!(controller.current(), controller.floor());
        assert_eq!(controller.effective_ceiling(), controller.floor());
    }

    #[test]
    fn the_floor_is_never_below_the_usable_minimum() {
        let controller = LiveCongestionController::new(8_000_000, 1, CongestionConfig::default(), false);
        assert_eq!(controller.floor(), 1_000_000);
    }

    #[test]
    fn a_seed_below_the_ceiling_starts_the_stream_lower() {
        let config = CongestionConfig {
            seed_fraction: 0.5,
            ..CongestionConfig::default()
        };
        let controller = LiveCongestionController::with_ceiling(CEILING, config, false);
        assert_eq!(controller.current(), CEILING / 2);
    }

    #[test]
    fn the_slack_gate_takes_whichever_of_the_two_is_larger() {
        let controller = LiveCongestionController::with_ceiling(CEILING, CongestionConfig::default(), false);
        assert!(
            (controller.effective_slack_millis(10.0) - 15.0).abs() < 1e-9,
            "a short baseline is governed by the fixed floor",
        );
        assert!(
            (controller.effective_slack_millis(44.0) - 33.0).abs() < 1e-9,
            "a long baseline by the proportional one",
        );
        assert!(
            (controller.effective_slack_millis(f64::INFINITY) - 15.0).abs() < 1e-9,
            "no baseline degrades to the fixed slack",
        );
    }

    #[test]
    fn only_material_changes_are_worth_actuating() {
        let config = CongestionConfig::default();
        assert!(!is_material_change(20_000_000, 20_400_000, CEILING, config));
        assert!(is_material_change(20_000_000, 22_000_000, CEILING, config));
        // The absolute floor governs a small ceiling.
        assert!(!is_material_change(1_000_000, 1_300_000, 2_000_000, config));
        assert!(is_material_change(1_000_000, 1_600_000, 2_000_000, config));
    }
}
