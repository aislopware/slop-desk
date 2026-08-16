//! The live stream's rate law: what the client's periodic report folds into, and what the AIMD
//! controller does with it.
//!
//! Two types cross here and they cross together, because one is the other's only input. Both are
//! Swift `struct`s their owner copies out, folds into and writes back, so both cross BY VALUE —
//! `(state, report) -> state`, with the whole state travelling every time. There is no handle and
//! nothing is allocated, on either side, on any call.
//!
//! ## Why the whole state, every time
//!
//! Every field is load-bearing. `rtt_inflated_streak` is what makes one noisy report harmless;
//! `prev_smoothed_rtt_millis` is the entire drain gate, without which a backlog flushing out walks
//! the rate to the floor; `sample_count` is the two-fold warmup that stops the first jitter sample
//! reading as a rise. A crossing that carried "the interesting numbers" would be a different
//! control law that happened to agree on the easy cases.
//!
//! The tunables travel inside the controller rather than beside it, exactly as they sit inside
//! `LiveCongestionController` — the wrapped type is already `Copy`, so this is a mirror rather than
//! a re-arrangement. What the door does NOT do is read an environment: the host resolves every
//! `SLOPDESK_ABR_*` knob through its overlay-aware `EnvConfig`, validate-then-default, and hands
//! the numbers over.

use slopdesk_video::congestion::{
    CongestionConfig, CongestionSnapshot, CutReason, LiveCongestionController, effective_slack_millis,
    is_material_change,
};
use slopdesk_video::network_estimate::NetworkEstimate;

/// The cold-start guard: no action is possible.
pub const SLOPDESK_ABR_REASON_WARMUP: u32 = 0;
/// No branch fired — sub-threshold, or inside a hold-down.
pub const SLOPDESK_ABR_REASON_HOLD: u32 = 1;
/// The streak and the cut-hold were satisfied, but the round trip is IMPROVING — the queue is
/// already flushing, so the drain gate held the cut.
pub const SLOPDESK_ABR_REASON_DRAIN: u32 = 2;
/// Additive increase — the normal probe toward the ceiling.
pub const SLOPDESK_ABR_REASON_PROBE: u32 = 3;
/// Additive increase at or above the remembered knee — the cautious step.
pub const SLOPDESK_ABR_REASON_KNEE: u32 = 4;
/// Decay while DEEPLY application-limited. Not congestion.
pub const SLOPDESK_ABR_REASON_APP_LIMITED: u32 = 5;
/// The proportional delay-targeting cut, on a sustained inflation streak.
pub const SLOPDESK_ABR_REASON_RTT_STREAK: u32 = 6;
/// A loss-corroborated cut: raw loss over the threshold WITH inflation evidence.
pub const SLOPDESK_ABR_REASON_LOSS_CORROBORATED: u32 = 7;
/// The early cut: the client's trendline reads overusing and the raw round trip corroborates.
pub const SLOPDESK_ABR_REASON_GRADIENT: u32 = 8;
/// The catastrophic halve, on sustained heavy loss.
pub const SLOPDESK_ABR_REASON_CATASTROPHIC: u32 = 9;

// ---------------------------------------------------------------------------------------------
// The folded estimate
// ---------------------------------------------------------------------------------------------

/// The host's fold of the client's report, as it crosses.
///
/// Clock-skew-free by construction: the round trip is measured against the host's OWN stamp echoed
/// back, so the two machines never have to agree on a wall clock.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskNetEstimate {
    /// The smoothed round trip in milliseconds. Zero until the first valid sample folds.
    pub smoothed_rtt_millis: f64,
    /// The windowed minimum — the path's no-queue baseline. Infinite until the first sample.
    pub min_rtt_millis: f64,
    /// The smoothed loss rate, for logging and trend only.
    pub loss_rate: f64,
    /// The RAW per-report loss fraction from the most recent fold — what the controller keys on.
    pub last_loss_sample: f64,
    /// The detector's modified trend from the most recent report, for diagnostics only.
    pub owd_trend_modified: f64,
    /// The raw round trip of the most recent fold — read ONLY when `has_last_rtt_sample`.
    pub last_rtt_sample_millis: f64,
    /// Whether the most recent report's raw sample was accepted at all.
    pub has_last_rtt_sample: bool,
    /// Whether the most recent jitter sample rose against the previous one. A hint, not a signal.
    pub owd_gradient_rising: bool,
    /// The client's trendline read OVERUSING on the most recent report.
    pub owd_trend_overusing: bool,
    /// The last folded jitter sample, for the rising-trend comparison.
    pub last_owd_jitter_micros: u32,
    /// How many reports have folded — the gradient's two-fold warmup.
    pub sample_count: u32,
}

impl SlopDeskNetEstimate {
    /// The crate's estimate for this record.
    const fn inner(self) -> NetworkEstimate {
        NetworkEstimate {
            smoothed_rtt_millis: self.smoothed_rtt_millis,
            min_rtt_millis: self.min_rtt_millis,
            loss_rate: self.loss_rate,
            last_loss_sample: self.last_loss_sample,
            owd_gradient_rising: self.owd_gradient_rising,
            owd_trend_overusing: self.owd_trend_overusing,
            owd_trend_modified: self.owd_trend_modified,
            last_rtt_sample_millis: if self.has_last_rtt_sample {
                Some(self.last_rtt_sample_millis)
            } else {
                None
            },
            last_owd_jitter_micros: self.last_owd_jitter_micros,
            sample_count: self.sample_count,
        }
    }

    /// This record for the crate's estimate.
    const fn of(estimate: NetworkEstimate) -> Self {
        Self {
            smoothed_rtt_millis: estimate.smoothed_rtt_millis,
            min_rtt_millis: estimate.min_rtt_millis,
            loss_rate: estimate.loss_rate,
            last_loss_sample: estimate.last_loss_sample,
            owd_trend_modified: estimate.owd_trend_modified,
            // An absent sample crosses as a flag plus a value the flag makes meaningless — never a
            // sentinel, because every finite millisecond is a legal reading.
            last_rtt_sample_millis: match estimate.last_rtt_sample_millis {
                Some(sample) => sample,
                None => 0.0,
            },
            has_last_rtt_sample: estimate.last_rtt_sample_millis.is_some(),
            owd_gradient_rising: estimate.owd_gradient_rising,
            owd_trend_overusing: estimate.owd_trend_overusing,
            last_owd_jitter_micros: estimate.last_owd_jitter_micros,
            sample_count: estimate.sample_count,
        }
    }
}

/// A fresh estimate: nothing smoothed, no baseline.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_net_estimate_new() -> SlopDeskNetEstimate {
    SlopDeskNetEstimate::of(NetworkEstimate::new())
}

/// The wrap-safe host-clock round trip in milliseconds, or a rejection.
///
/// Total over every `u32` input — the subtraction is wrap-aware, so a counter that rolled between
/// the stamp and now still yields the right small positive elapsed. Rejects a sample when telemetry
/// is off, when the stamp is in the future, when the client's hold exceeds the elapsed, or when the
/// result is implausibly large. `false` means REJECT, and `out_millis` is left untouched.
///
/// # Safety
/// `out_millis` must be null, or writable for one `int64_t` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_net_estimate_rtt_millis(
    host_now_ms: u32,
    latest_host_send_ts: u32,
    client_hold_ms: u32,
    out_millis: *mut i64,
) -> bool {
    let Some(millis) = NetworkEstimate::compute_rtt_millis(host_now_ms, latest_host_send_ts, client_hold_ms)
    else {
        return false;
    };
    if !out_millis.is_null() {
        // SAFETY: non-null, and by the caller's obligation writable for one `i64` for this call.
        unsafe { out_millis.write(millis) };
    }
    true
}

/// Folds one report into the estimate and answers the estimate that results.
///
/// `has_rtt` false is a REJECTED round-trip sample, which skips the round-trip update but still
/// folds loss and jitter — turning the round-trip loop off must not blind the rest.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_net_estimate_fold(
    estimate: SlopDeskNetEstimate,
    has_rtt: bool,
    rtt_millis: i64,
    frames_received: u32,
    unrecovered: u32,
    owd_jitter_micros: u32,
    owd_trend_state: u8,
    owd_trend_modified_milli: i32,
) -> SlopDeskNetEstimate {
    let mut inner = estimate.inner();
    inner.fold(
        has_rtt.then_some(rtt_millis),
        frames_received,
        unrecovered,
        owd_jitter_micros,
        owd_trend_state,
        owd_trend_modified_milli,
    );
    SlopDeskNetEstimate::of(inner)
}

// ---------------------------------------------------------------------------------------------
// The rate law
// ---------------------------------------------------------------------------------------------

/// The tunables, as they cross. Every one is `SLOPDESK_ABR_*`-overridable on the host side.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskAbrConfig {
    /// RAW per-report loss above which the link is congested.
    pub loss_threshold: f64,
    /// The raw-sample gate the catastrophic halve ALSO requires.
    pub severe_loss_threshold: f64,
    /// EWMA loss above which the rate halves even at flat round trip.
    pub catastrophic_loss_threshold: f64,
    /// The multiplicative decrease on ordinary congestion.
    pub decrease_factor: f64,
    /// The multiplicative decrease on the catastrophic branch.
    pub severe_decrease_factor: f64,
    /// The share of the target the stream must be USING before the controller probes higher.
    pub ramp_utilization_fraction: f64,
    /// The share below which the stream is DEEPLY idle and the target decays.
    pub decay_utilization_fraction: f64,
    /// While idle the target decays toward the offered rate times this.
    pub decay_headroom: f64,
    /// The share of the gap to the decay target taken per idle report.
    pub decay_step_fraction: f64,
    /// Smoothed over baseline times this signals a queue.
    pub rtt_inflate_factor: f64,
    /// The ABSOLUTE inflation over baseline also required, in milliseconds.
    pub rtt_slack_millis: f64,
    /// The baseline-proportional slack, for paths whose own texture is wide.
    pub rtt_slack_fraction: f64,
    /// The hardest single proportional cut.
    pub rtt_decrease_floor_factor: f64,
    /// The gentlest proportional cut.
    pub rtt_decrease_cap_factor: f64,
    /// The floor as a share of the ceiling.
    pub min_fraction: f64,
    /// The open-loop START share of the ceiling.
    pub seed_fraction: f64,
    /// The actuation churn gate, as a share of the ceiling.
    pub material_fraction: f64,
    /// The multiplicative factor for a gradient-authorised cut.
    pub gradient_decrease_factor: f64,
    /// The additive step is the ceiling over this.
    pub increase_divisor: i64,
    /// The actuation churn gate, as an absolute rate.
    pub material_floor_bps: i64,
    /// Reports to fold before ANY action.
    pub warmup_ticks: u32,
    /// Reports suppressing any increase after a decrease.
    pub hold_ticks: u32,
    /// CONSECUTIVE inflated reports required before the round-trip path may cut.
    pub rtt_streak_ticks: u32,
    /// Reports between ANY multiplicative decreases.
    pub cut_hold_ticks: u32,
    /// The extra divisor applied to the additive step at or above the knee.
    pub knee_caution_divisor: i64,
    /// Reports the knee memory survives without re-confirmation.
    pub knee_ttl_ticks: u32,
    /// Whether ordinary loss must be corroborated by round-trip inflation to cut.
    pub loss_needs_rtt_corroboration: bool,
}

impl SlopDeskAbrConfig {
    /// The crate's config for these numbers.
    pub(crate) const fn inner(self) -> CongestionConfig {
        CongestionConfig {
            warmup_ticks: self.warmup_ticks,
            loss_threshold: self.loss_threshold,
            severe_loss_threshold: self.severe_loss_threshold,
            loss_needs_rtt_corroboration: self.loss_needs_rtt_corroboration,
            catastrophic_loss_threshold: self.catastrophic_loss_threshold,
            decrease_factor: self.decrease_factor,
            severe_decrease_factor: self.severe_decrease_factor,
            increase_divisor: self.increase_divisor,
            ramp_utilization_fraction: self.ramp_utilization_fraction,
            decay_utilization_fraction: self.decay_utilization_fraction,
            decay_headroom: self.decay_headroom,
            decay_step_fraction: self.decay_step_fraction,
            hold_ticks: self.hold_ticks,
            rtt_inflate_factor: self.rtt_inflate_factor,
            rtt_slack_millis: self.rtt_slack_millis,
            rtt_slack_fraction: self.rtt_slack_fraction,
            rtt_streak_ticks: self.rtt_streak_ticks,
            cut_hold_ticks: self.cut_hold_ticks,
            rtt_decrease_floor_factor: self.rtt_decrease_floor_factor,
            rtt_decrease_cap_factor: self.rtt_decrease_cap_factor,
            knee_caution_divisor: self.knee_caution_divisor,
            knee_ttl_ticks: self.knee_ttl_ticks,
            min_fraction: self.min_fraction,
            seed_fraction: self.seed_fraction,
            material_fraction: self.material_fraction,
            material_floor_bps: self.material_floor_bps,
            gradient_decrease_factor: self.gradient_decrease_factor,
        }
    }

    /// These numbers for the crate's config.
    const fn of(config: CongestionConfig) -> Self {
        Self {
            loss_threshold: config.loss_threshold,
            severe_loss_threshold: config.severe_loss_threshold,
            catastrophic_loss_threshold: config.catastrophic_loss_threshold,
            decrease_factor: config.decrease_factor,
            severe_decrease_factor: config.severe_decrease_factor,
            ramp_utilization_fraction: config.ramp_utilization_fraction,
            decay_utilization_fraction: config.decay_utilization_fraction,
            decay_headroom: config.decay_headroom,
            decay_step_fraction: config.decay_step_fraction,
            rtt_inflate_factor: config.rtt_inflate_factor,
            rtt_slack_millis: config.rtt_slack_millis,
            rtt_slack_fraction: config.rtt_slack_fraction,
            rtt_decrease_floor_factor: config.rtt_decrease_floor_factor,
            rtt_decrease_cap_factor: config.rtt_decrease_cap_factor,
            min_fraction: config.min_fraction,
            seed_fraction: config.seed_fraction,
            material_fraction: config.material_fraction,
            gradient_decrease_factor: config.gradient_decrease_factor,
            increase_divisor: config.increase_divisor,
            material_floor_bps: config.material_floor_bps,
            warmup_ticks: config.warmup_ticks,
            hold_ticks: config.hold_ticks,
            rtt_streak_ticks: config.rtt_streak_ticks,
            cut_hold_ticks: config.cut_hold_ticks,
            knee_caution_divisor: config.knee_caution_divisor,
            knee_ttl_ticks: config.knee_ttl_ticks,
            loss_needs_rtt_corroboration: config.loss_needs_rtt_corroboration,
        }
    }
}

/// The controller as it crosses: the tunables, the bounds and every number the next fold reads.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskAbrController {
    /// The tunables.
    pub config: SlopDeskAbrConfig,
    /// The policy ceiling for this encoder build.
    pub ceiling: i64,
    /// The lowest rate the controller may drive.
    pub floor: i64,
    /// The client-requested ceiling — read ONLY when `has_user_ceiling`.
    pub user_ceiling_bps: i64,
    /// The current target.
    pub current: i64,
    /// The remembered knee — read ONLY when `has_knee`.
    pub knee_bps: i64,
    /// The previous report's smoothed round trip — the drain gate's comparison.
    pub prev_smoothed_rtt_millis: f64,
    /// The folded-report count — the clock.
    pub ticks: u32,
    /// No increase until the clock reaches this.
    pub hold_until_tick: u32,
    /// Consecutive reports that cleared both inflation gates.
    pub rtt_inflated_streak: u32,
    /// No multiplicative decrease until the clock reaches this.
    pub cut_hold_until_tick: u32,
    /// The report at which the knee expires.
    pub knee_expires_at_tick: u32,
    /// Whether a client-requested ceiling is layered under the policy one.
    pub has_user_ceiling: bool,
    /// Whether a knee is remembered.
    pub has_knee: bool,
    /// Whether the delay-gradient early cut is armed.
    pub gradient_cut_enabled: bool,
}

impl SlopDeskAbrController {
    /// The crate's controller for this record, with `new`'s bounds re-established.
    fn inner(self) -> LiveCongestionController {
        LiveCongestionController::restored(CongestionSnapshot {
            config: self.config.inner(),
            ceiling: self.ceiling,
            floor: self.floor,
            user_ceiling_bps: self.has_user_ceiling.then_some(self.user_ceiling_bps),
            gradient_cut_enabled: self.gradient_cut_enabled,
            current: self.current,
            ticks: self.ticks,
            hold_until_tick: self.hold_until_tick,
            rtt_inflated_streak: self.rtt_inflated_streak,
            cut_hold_until_tick: self.cut_hold_until_tick,
            prev_smoothed_rtt_millis: self.prev_smoothed_rtt_millis,
            knee_bps: self.has_knee.then_some(self.knee_bps),
            knee_expires_at_tick: self.knee_expires_at_tick,
        })
    }

    /// This record for the crate's controller.
    ///
    /// By reference: the wrapped controller carries its tunables inside it, which puts it past the
    /// size a copy is free at. Nothing about it crosses here — this is one Rust frame to the next.
    const fn of(controller: &LiveCongestionController) -> Self {
        let snapshot = controller.snapshot();
        Self {
            config: SlopDeskAbrConfig::of(snapshot.config),
            ceiling: snapshot.ceiling,
            floor: snapshot.floor,
            // Both optionals cross as a value plus a flag. No bitrate could stand for "none": zero
            // is a rate the floor forbids but a hostile snapshot could still name.
            user_ceiling_bps: match snapshot.user_ceiling_bps {
                Some(bps) => bps,
                None => 0,
            },
            current: snapshot.current,
            knee_bps: match snapshot.knee_bps {
                Some(bps) => bps,
                None => 0,
            },
            prev_smoothed_rtt_millis: snapshot.prev_smoothed_rtt_millis,
            ticks: snapshot.ticks,
            hold_until_tick: snapshot.hold_until_tick,
            rtt_inflated_streak: snapshot.rtt_inflated_streak,
            cut_hold_until_tick: snapshot.cut_hold_until_tick,
            knee_expires_at_tick: snapshot.knee_expires_at_tick,
            has_user_ceiling: snapshot.user_ceiling_bps.is_some(),
            has_knee: snapshot.knee_bps.is_some(),
            gradient_cut_enabled: snapshot.gradient_cut_enabled,
        }
    }
}

/// One report's outcome: the controller that results, the new target, and the branch that set it.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskAbrDecision {
    /// The controller after the fold — what the caller writes back.
    pub controller: SlopDeskAbrController,
    /// The new live target in bits per second.
    pub target: i64,
    /// `SLOPDESK_ABR_REASON_*`.
    pub reason: u32,
}

/// The `SLOPDESK_ABR_REASON_*` value for a reason.
const fn reason_code(reason: CutReason) -> u32 {
    match reason {
        CutReason::Warmup => SLOPDESK_ABR_REASON_WARMUP,
        CutReason::Hold => SLOPDESK_ABR_REASON_HOLD,
        CutReason::Drain => SLOPDESK_ABR_REASON_DRAIN,
        CutReason::Probe => SLOPDESK_ABR_REASON_PROBE,
        CutReason::Knee => SLOPDESK_ABR_REASON_KNEE,
        CutReason::AppLimited => SLOPDESK_ABR_REASON_APP_LIMITED,
        CutReason::RttStreak => SLOPDESK_ABR_REASON_RTT_STREAK,
        CutReason::LossCorroborated => SLOPDESK_ABR_REASON_LOSS_CORROBORATED,
        CutReason::Gradient => SLOPDESK_ABR_REASON_GRADIENT,
        CutReason::Catastrophic => SLOPDESK_ABR_REASON_CATASTROPHIC,
    }
}

/// The production defaults, which are what every `SLOPDESK_ABR_*` knob falls back to.
///
/// The host resolves the environment itself and overwrites the fields it was given a value for, so
/// the defaults are spelled once — here — rather than a second time in Swift.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_config_default() -> SlopDeskAbrConfig {
    SlopDeskAbrConfig::of(CongestionConfig::default())
}

/// A controller with an explicit floor, seeded at the ceiling times the configured seed fraction.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_new(
    ceiling: i64,
    floor: i64,
    config: SlopDeskAbrConfig,
    gradient_cut_enabled: bool,
) -> SlopDeskAbrController {
    SlopDeskAbrController::of(&LiveCongestionController::new(
        ceiling,
        floor,
        config.inner(),
        gradient_cut_enabled,
    ))
}

/// A controller whose floor is derived from the ceiling — the production wiring, which keeps the
/// floor policy in one place.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_with_ceiling(
    ceiling: i64,
    config: SlopDeskAbrConfig,
    gradient_cut_enabled: bool,
) -> SlopDeskAbrController {
    SlopDeskAbrController::of(&LiveCongestionController::with_ceiling(
        ceiling,
        config.inner(),
        gradient_cut_enabled,
    ))
}

/// The ceiling every climb is clamped to: the policy ceiling bounded by the user override.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_effective_ceiling(controller: SlopDeskAbrController) -> i64 {
    controller.inner().effective_ceiling()
}

/// Sets, or with a non-positive value clears, the user ceiling, and answers the controller that
/// results — a target above the new effective ceiling has already clamped down.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_set_user_ceiling(
    controller: SlopDeskAbrController,
    has_user_ceiling: bool,
    user_bps: i64,
) -> SlopDeskAbrController {
    let mut inner = controller.inner();
    inner.set_user_ceiling_bps(has_user_ceiling.then_some(user_bps));
    SlopDeskAbrController::of(&inner)
}

/// Folds one estimate and answers the new controller, the new target and the branch that set it.
///
/// `has_offered` false means no utilization gate, so the controller always probes; supplied, it is
/// the host's recent encoded throughput, and a stream offering far below its target is
/// APPLICATION-limited rather than link-limited.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_decide(
    controller: SlopDeskAbrController,
    estimate: SlopDeskNetEstimate,
    has_offered: bool,
    offered_bps: f64,
) -> SlopDeskAbrDecision {
    let mut inner = controller.inner();
    let decision = inner.decide(&estimate.inner(), has_offered.then_some(offered_bps));
    SlopDeskAbrDecision {
        controller: SlopDeskAbrController::of(&inner),
        target: decision.target,
        reason: reason_code(decision.reason),
    }
}

/// The effective absolute-slack gate for a path baseline: the fixed slack, or the proportional one
/// when the baseline is long enough to make it bigger.
///
/// Free-standing because the frame-rate governor's congestion predicate consults the SAME rule, so
/// the two controllers cannot drift apart on what "inflated" means.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_effective_slack(config: SlopDeskAbrConfig, min_rtt_millis: f64) -> f64 {
    effective_slack_millis(&config.inner(), min_rtt_millis)
}

/// Whether a target change is large enough to be worth actuating on the encoder.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_abr_is_material_change(
    previous: i64,
    target: i64,
    ceiling: i64,
    config: SlopDeskAbrConfig,
) -> bool {
    is_material_change(previous, target, ceiling, config.inner())
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::integer_division,
    reason = "calling the door is the only way to test the door, and the literal bitrates here were chosen \
              to divide exactly"
)]
mod tests {
    use super::{
        SLOPDESK_ABR_REASON_CATASTROPHIC, SLOPDESK_ABR_REASON_HOLD, SLOPDESK_ABR_REASON_PROBE,
        SLOPDESK_ABR_REASON_RTT_STREAK, SLOPDESK_ABR_REASON_WARMUP, SlopDeskAbrController,
        SlopDeskNetEstimate, slopdesk_abr_config_default, slopdesk_abr_decide,
        slopdesk_abr_effective_ceiling, slopdesk_abr_effective_slack, slopdesk_abr_is_material_change,
        slopdesk_abr_new, slopdesk_abr_set_user_ceiling, slopdesk_abr_with_ceiling,
        slopdesk_net_estimate_fold, slopdesk_net_estimate_new, slopdesk_net_estimate_rtt_millis,
    };

    const CEILING: i64 = 32_000_000;

    /// A quiet report: a flat round trip at the baseline, no loss, no trend.
    fn quiet(estimate: SlopDeskNetEstimate) -> SlopDeskNetEstimate {
        slopdesk_net_estimate_fold(estimate, true, 10, 100, 0, 0, 0, 0)
    }

    /// Folds `count` quiet reports through the controller, returning the last decision's reason.
    fn settle(controller: &mut SlopDeskAbrController, estimate: &mut SlopDeskNetEstimate, count: u32) -> u32 {
        let mut reason = SLOPDESK_ABR_REASON_HOLD;
        for _ in 0..count {
            *estimate = quiet(*estimate);
            let decision = slopdesk_abr_decide(*controller, *estimate, false, 0.0);
            *controller = decision.controller;
            reason = decision.reason;
        }
        reason
    }

    #[test]
    fn a_rejected_sample_still_folds_loss_and_the_warmup_holds_the_gradient() {
        let mut estimate = slopdesk_net_estimate_new();
        assert!(
            estimate.min_rtt_millis.is_infinite(),
            "no baseline before the first sample"
        );
        assert!(!estimate.has_last_rtt_sample);

        // A rejected round trip must not blind the loss fold.
        estimate = slopdesk_net_estimate_fold(estimate, false, 0, 100, 10, 500, 0, 0);
        assert!(
            !estimate.has_last_rtt_sample,
            "a rejected sample stays absent, not zero"
        );
        assert!(
            estimate.min_rtt_millis.is_infinite(),
            "and leaves the baseline alone"
        );
        assert!(
            (estimate.last_loss_sample - 0.1).abs() < 1e-12,
            "while the loss still folded"
        );

        // The rising-trend hint needs two folds behind it before it can read anything.
        estimate = slopdesk_net_estimate_fold(estimate, true, 12, 100, 0, 900, 0, 0);
        assert!(
            !estimate.owd_gradient_rising,
            "the second fold is still inside the warmup"
        );
        estimate = slopdesk_net_estimate_fold(estimate, true, 12, 100, 0, 1500, 0, 0);
        assert!(
            estimate.owd_gradient_rising,
            "past the warmup a rising jitter sample reads as one"
        );
        assert_eq!(estimate.sample_count, 3, "the count is state, and it travels");
    }

    #[test]
    fn the_round_trip_is_wrap_safe_and_rejects_what_it_cannot_believe() {
        let mut millis = -1_i64;
        let ask = |now: u32, stamp: u32, hold: u32, out: &mut i64| unsafe {
            slopdesk_net_estimate_rtt_millis(now, stamp, hold, out)
        };
        assert!(
            ask(100, 40, 10, &mut millis) && millis == 50,
            "elapsed minus the client's hold"
        );
        // A counter that wrapped between the stamp and now still reads as a small positive elapsed.
        assert!(ask(10, u32::MAX - 9, 0, &mut millis) && millis == 20, "wrap-safe");
        millis = -1;
        assert!(!ask(100, 0, 0, &mut millis), "telemetry off is a rejection");
        assert!(
            !ask(40, 100, 0, &mut millis),
            "a stamp from the future is a rejection"
        );
        assert!(
            !ask(100, 40, 90, &mut millis),
            "a hold longer than the elapsed is a rejection"
        );
        assert_eq!(millis, -1, "and a rejection writes nothing");
    }

    #[test]
    fn the_warmup_holds_and_a_clean_link_probes_toward_the_ceiling() {
        let config = slopdesk_abr_config_default();
        let mut controller = slopdesk_abr_new(CEILING, CEILING / 4, config, false);
        assert_eq!(
            controller.current, CEILING,
            "an open-loop start sits at the ceiling"
        );
        let mut estimate = slopdesk_net_estimate_new();

        // The guard counts the reports it has folded, so the LAST warmup report is the one before
        // the count reaches the threshold.
        assert_eq!(
            settle(&mut controller, &mut estimate, config.warmup_ticks - 1),
            SLOPDESK_ABR_REASON_WARMUP,
            "no branch may fire inside the cold-start guard",
        );
        // At the ceiling the probe is a no-op in value but still names itself.
        assert_eq!(
            settle(&mut controller, &mut estimate, 1),
            SLOPDESK_ABR_REASON_PROBE
        );
        assert_eq!(controller.current, CEILING, "and cannot climb past the ceiling");

        // From below, the probe really climbs — exactly one step on the first report that acts.
        let mut low = slopdesk_abr_new(CEILING, CEILING / 4, config, false);
        low.current = CEILING / 2;
        let before = low.current;
        let mut fresh = estimate;
        assert_eq!(
            settle(&mut low, &mut fresh, config.warmup_ticks),
            SLOPDESK_ABR_REASON_PROBE,
            "a clean link past the warmup probes",
        );
        assert_eq!(
            low.current - before,
            CEILING / config.increase_divisor,
            "one step, not two"
        );
    }

    #[test]
    fn a_sustained_queue_cuts_proportionally_and_remembers_the_knee() {
        let config = slopdesk_abr_config_default();
        let mut controller = slopdesk_abr_with_ceiling(CEILING, config, false);
        let mut estimate = slopdesk_net_estimate_new();
        // A 10 ms baseline, established while the controller warms up.
        for _ in 0..config.warmup_ticks {
            estimate = slopdesk_net_estimate_fold(estimate, true, 10, 100, 0, 0, 0, 0);
            controller = slopdesk_abr_decide(controller, estimate, false, 0.0).controller;
        }
        assert!((estimate.min_rtt_millis - 10.0).abs() < 1e-9);

        // Then a standing queue: 90 ms, well past both the factor and the slack gates. The smoothed
        // round trip has to CLIMB into the gates before the streak can even start counting, which is
        // the point of smoothing — so this waits for the cut rather than asserting a report number.
        let mut reason = SLOPDESK_ABR_REASON_HOLD;
        for _ in 0..20 {
            estimate = slopdesk_net_estimate_fold(estimate, true, 90, 100, 0, 0, 0, 0);
            let decision = slopdesk_abr_decide(controller, estimate, false, 0.0);
            controller = decision.controller;
            if decision.reason == SLOPDESK_ABR_REASON_RTT_STREAK {
                reason = decision.reason;
                break;
            }
        }
        assert_eq!(reason, SLOPDESK_ABR_REASON_RTT_STREAK, "a sustained queue cuts");
        assert!(controller.current < CEILING, "and the cut lowers the target");
        assert!(controller.has_knee, "a queue-corroborated cut remembers the knee");
        assert_eq!(controller.knee_bps, controller.current);
        assert_eq!(controller.rtt_inflated_streak, 0, "and the streak restarts");
    }

    #[test]
    fn sustained_heavy_loss_halves_even_at_a_flat_round_trip() {
        let config = slopdesk_abr_config_default();
        let mut controller = slopdesk_abr_with_ceiling(CEILING, config, false);
        let mut estimate = slopdesk_net_estimate_new();
        for _ in 0..config.warmup_ticks {
            estimate = slopdesk_net_estimate_fold(estimate, true, 10, 100, 0, 0, 0, 0);
            controller = slopdesk_abr_decide(controller, estimate, false, 0.0).controller;
        }
        // ~300 ms of true collapse is what the EWMA needs to cross the catastrophic threshold.
        let mut reason = SLOPDESK_ABR_REASON_HOLD;
        for _ in 0..10 {
            estimate = slopdesk_net_estimate_fold(estimate, true, 10, 100, 60, 0, 0, 0);
            let decision = slopdesk_abr_decide(controller, estimate, false, 0.0);
            controller = decision.controller;
            if decision.reason == SLOPDESK_ABR_REASON_CATASTROPHIC {
                reason = decision.reason;
                break;
            }
        }
        assert_eq!(
            reason, SLOPDESK_ABR_REASON_CATASTROPHIC,
            "a flat-RTT collapse still halves"
        );
        assert!(controller.current <= CEILING / 2 + 1);
    }

    #[test]
    fn the_user_ceiling_bites_at_once_and_never_starves_the_encoder() {
        let config = slopdesk_abr_config_default();
        let controller = slopdesk_abr_with_ceiling(CEILING, config, false);
        assert_eq!(
            slopdesk_abr_effective_ceiling(controller),
            CEILING,
            "no override, no change"
        );

        let capped = slopdesk_abr_set_user_ceiling(controller, true, 8_000_000);
        assert_eq!(slopdesk_abr_effective_ceiling(capped), 8_000_000);
        assert_eq!(
            capped.current, 8_000_000,
            "the override bites on the very next actuation"
        );

        // A pathological override cannot drive the encoder under the usable minimum.
        let starved = slopdesk_abr_set_user_ceiling(controller, true, 1);
        assert_eq!(slopdesk_abr_effective_ceiling(starved), starved.floor);

        let cleared = slopdesk_abr_set_user_ceiling(capped, false, 0);
        assert_eq!(
            slopdesk_abr_effective_ceiling(cleared),
            CEILING,
            "clearing restores the policy"
        );
        assert_eq!(
            cleared.current, 8_000_000,
            "and the headroom is climbed back, never jumped"
        );
    }

    #[test]
    fn the_slack_gate_and_the_actuation_gate_answer_the_wrapped_rules() {
        let config = slopdesk_abr_config_default();
        assert!(
            (slopdesk_abr_effective_slack(config, 10.0) - config.rtt_slack_millis).abs() < 1e-12,
            "a short baseline is governed by the absolute slack",
        );
        assert!(
            (slopdesk_abr_effective_slack(config, 44.0) - 33.0).abs() < 1e-12,
            "a long one by the proportional slack",
        );
        assert!(
            (slopdesk_abr_effective_slack(config, f64::INFINITY) - config.rtt_slack_millis).abs() < 1e-12,
            "and a baseline that is not a number degrades to the absolute slack, never disables it",
        );

        // The churn gate: 5% of the ceiling here beats the absolute floor.
        assert!(!slopdesk_abr_is_material_change(
            CEILING,
            CEILING - 1_000_000,
            CEILING,
            config
        ));
        assert!(slopdesk_abr_is_material_change(
            CEILING,
            CEILING - 2_000_000,
            CEILING,
            config
        ));
    }

    #[test]
    fn a_state_that_crossed_a_boundary_is_clamped_like_any_other_input() {
        let config = slopdesk_abr_config_default();
        let mut hostile = slopdesk_abr_with_ceiling(CEILING, config, false);
        hostile.current = i64::MAX;
        hostile.ceiling = -5;
        let estimate = slopdesk_net_estimate_new();
        let landed = slopdesk_abr_decide(hostile, estimate, false, 0.0).controller;
        assert!(
            landed.ceiling >= 1,
            "a ceiling no encoder could honour is lifted to a legal one"
        );
        // What `new` guarantees, and therefore all a restore may: never below the floor, and never
        // above the effective ceiling unless the FLOOR is — the encoder minimum outranks a ceiling
        // this small, and answering the floor is what `new` does too.
        assert!(landed.current >= landed.floor, "never below the floor");
        assert!(
            landed.current <= landed.floor.max(slopdesk_abr_effective_ceiling(landed)),
            "a snapshot cannot smuggle a rate no `new` could have produced past the fold",
        );
    }
}
