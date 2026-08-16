//! The one-way-delay GRADIENT detector: congestion read from the queue's slope rather than its
//! level, and the one-sample-per-frame gate in front of it.
//!
//! Both are Swift `struct`s their owner copies out, folds into and writes back, so both cross BY
//! VALUE — `(state, sample) -> state`, with the whole state travelling every time.
//!
//! ## Why the WINDOW travels
//!
//! The verdict is a least-squares slope over the window's samples. Running sums that dropped the
//! evicted point arithmetically would be a different sequence of roundings, and the trend's bits
//! are pinned on the wire and in the golden corpus — so the samples themselves cross, as a pair of
//! parallel fixed-capacity arrays. The capacity is two hundred, which is the CEILING of the window
//! knob's own band, so every window a legal config can ask for fits with nothing truncated.
//!
//! ## What does not cross
//!
//! The law's constants — the smoothing coefficient, the threshold's bounds and gains, the sustain
//! time, the idle-reset gap — are asked for once through `slopdesk_trendline_constants`, so the
//! near side spells none of them. They are not state: no fold changes one.

use core::ffi::c_uchar;

use slopdesk_video::trendline::{
    INITIAL_THRESHOLD, K_DOWN, K_UP, MAX_ADAPT_DT_MS, MAX_NUM_DELTAS, MAX_SCALED_DELTAS, OUTLIER_SKIP_MARGIN,
    OVERUSING_TIME_MS, RESET_GAP_MS, SMOOTHING_COEF, THRESHOLD_MAX, THRESHOLD_MIN, TrendSampler, TrendState,
    TrendlineConfig, TrendlineEstimator, TrendlineSnapshot, WINDOW_CAPACITY, pack_trend_flags,
    pack_trend_milli,
};

use crate::{borrow, optional, optional_of};

/// No gradient worth acting on, which is also the verdict before the window fills.
pub const SLOPDESK_TREND_STATE_NORMAL: u32 = 0;
/// The queue is growing: delay rises against arrival time.
pub const SLOPDESK_TREND_STATE_OVERUSING: u32 = 1;
/// The queue is draining.
pub const SLOPDESK_TREND_STATE_UNDERUSING: u32 = 2;

/// The verdict as a plain code, which is the wire encoding widened.
const fn state_code(state: TrendState) -> u32 {
    match state {
        TrendState::Normal => SLOPDESK_TREND_STATE_NORMAL,
        TrendState::Overusing => SLOPDESK_TREND_STATE_OVERUSING,
        TrendState::Underusing => SLOPDESK_TREND_STATE_UNDERUSING,
    }
}

/// The inverse of [`state_code`]. An unknown code cannot arise from this door and reads as the
/// benign verdict, which is also the one a fresh detector holds.
const fn state_of(code: u32) -> TrendState {
    match code {
        SLOPDESK_TREND_STATE_OVERUSING => TrendState::Overusing,
        SLOPDESK_TREND_STATE_UNDERUSING => TrendState::Underusing,
        _ => TrendState::Normal,
    }
}

/// The env-tunable half of the operating point, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskTrendlineConfig {
    /// The regression window in per-frame samples. Twenty is a third of a second at sixty frames.
    pub window_size: usize,
    /// The gain applied to the slope before the threshold comparison.
    pub threshold_gain: f64,
}

impl SlopDeskTrendlineConfig {
    /// The wrapped config this describes.
    const fn inner(self) -> TrendlineConfig {
        TrendlineConfig {
            // The band already stops here; this is the guard behind it.
            window_size: if self.window_size > WINDOW_CAPACITY {
                WINDOW_CAPACITY
            } else {
                self.window_size
            },
            threshold_gain: self.threshold_gain,
        }
    }

    /// The crossing form of a wrapped config.
    const fn of(config: TrendlineConfig) -> Self {
        Self {
            window_size: config.window_size,
            threshold_gain: config.threshold_gain,
        }
    }
}

/// The operating point the detector ships with.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_config_default() -> SlopDeskTrendlineConfig {
    SlopDeskTrendlineConfig::of(TrendlineConfig::default())
}

/// Applies ONE environment pair to a config and answers the config that results.
///
/// An unknown key, an unparseable value and an OUT-OF-BAND one all answer the config unchanged:
/// these two knobs reshape the detector's geometry rather than move it along an axis, so a typo
/// must keep the default rather than land on the nearest end of a band.
///
/// # Safety
/// `(key, key_len)` and `(value, value_len)` must each describe live memory for the whole call, or
/// be null.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_trendline_config_apply(
    config: SlopDeskTrendlineConfig,
    key: *const c_uchar,
    key_len: usize,
    value: *const c_uchar,
    value_len: usize,
) -> SlopDeskTrendlineConfig {
    // SAFETY: each pair is live for the call or null, which borrows as empty.
    let (key_bytes, value_bytes) = unsafe { (borrow(key, key_len), borrow(value, value_len)) };
    let mut inner = config.inner();
    inner.apply_env_pair(
        &String::from_utf8_lossy(key_bytes),
        &String::from_utf8_lossy(value_bytes),
    );
    SlopDeskTrendlineConfig::of(inner)
}

/// The law's fixed numbers, which no fold changes and no environment moves.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskTrendlineConstants {
    /// The exponential smoothing applied to the accumulated delay.
    pub smoothing_coef: f64,
    /// The adaptive threshold's starting value.
    pub initial_threshold: f64,
    /// The floor the threshold can never fall through.
    pub threshold_min: f64,
    /// The ceiling the threshold can never rise through.
    pub threshold_max: f64,
    /// The threshold's rise gain, deliberately slow.
    pub k_up: f64,
    /// Its fall gain, several times the rise.
    pub k_down: f64,
    /// How far past the threshold a sample may sit and still adapt it.
    pub outlier_skip_margin: f64,
    /// The clamp on the per-sample time step used in adaptation, in milliseconds.
    pub max_adapt_dt_ms: f64,
    /// How long the trend must stay over the threshold before overuse SIGNALS.
    pub overusing_time_ms: f64,
    /// The arrival gap that resets the window.
    pub reset_gap_ms: f64,
    /// Where the sample count saturates inside the scale factor.
    pub max_scaled_deltas: usize,
    /// Where the total sample count saturates. A log field, not an input to the math.
    pub max_num_deltas: usize,
    /// The largest window a config can ask for, which is what the crossing carries.
    pub window_capacity: usize,
}

/// The law's fixed numbers, so the near side spells none of them.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_trendline_constants() -> SlopDeskTrendlineConstants {
    SlopDeskTrendlineConstants {
        smoothing_coef: SMOOTHING_COEF,
        initial_threshold: INITIAL_THRESHOLD,
        threshold_min: THRESHOLD_MIN,
        threshold_max: THRESHOLD_MAX,
        k_up: K_UP,
        k_down: K_DOWN,
        outlier_skip_margin: OUTLIER_SKIP_MARGIN,
        max_adapt_dt_ms: MAX_ADAPT_DT_MS,
        overusing_time_ms: OVERUSING_TIME_MS,
        reset_gap_ms: RESET_GAP_MS,
        max_scaled_deltas: MAX_SCALED_DELTAS,
        max_num_deltas: MAX_NUM_DELTAS,
        window_capacity: WINDOW_CAPACITY,
    }
}

/// The detector's whole state, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskTrendline {
    /// The operating point, which travels with the state.
    pub config: SlopDeskTrendlineConfig,
    /// One of the `SLOPDESK_TREND_STATE_*` codes.
    pub state: u32,
    /// The value compared against the threshold.
    pub modified_trend: f64,
    /// How many samples have folded, saturating.
    pub num_deltas: usize,
    /// The live adaptive threshold, which an idle reset deliberately KEEPS.
    pub threshold: f64,
    /// Whether a previous arrival exists to step from.
    pub has_prev_arrival: bool,
    /// The previous arrival.
    pub prev_arrival_ms: f64,
    /// Whether a previous send stamp exists.
    pub has_prev_send_ts: bool,
    /// The previous send stamp.
    pub prev_send_ts: u32,
    /// The running sum of delay variations.
    pub accumulated_delay_ms: f64,
    /// Its exponential smoothing, which is what the regression fits.
    pub smoothed_delay_ms: f64,
    /// The window's arrival offsets, oldest first.
    pub window_x: [f64; WINDOW_CAPACITY],
    /// The window's smoothed delays, oldest first.
    pub window_y: [f64; WINDOW_CAPACITY],
    /// How many of the window's slots are live.
    pub window_len: usize,
    /// The arrival the window's offsets are measured from.
    pub first_arrival_ms: f64,
    /// Whether an over-threshold excursion is open.
    pub has_overuse_start: bool,
    /// The excursion's first arrival, which the sustain clock reads.
    pub overuse_start_ms: f64,
    /// The previous slope, which the sustain rule and a degenerate window both read.
    pub prev_trend: f64,
}

impl SlopDeskTrendline {
    /// The wrapped detector this describes.
    fn inner(&self) -> TrendlineEstimator {
        TrendlineEstimator::restored(TrendlineSnapshot {
            config: self.config.inner(),
            state: state_of(self.state),
            modified_trend: self.modified_trend,
            num_deltas: self.num_deltas,
            threshold: self.threshold,
            prev_arrival_ms: optional_of(self.has_prev_arrival, self.prev_arrival_ms),
            prev_send_ts: self.has_prev_send_ts.then_some(self.prev_send_ts),
            accumulated_delay_ms: self.accumulated_delay_ms,
            smoothed_delay_ms: self.smoothed_delay_ms,
            window_x: self.window_x,
            window_y: self.window_y,
            window_len: self.window_len,
            first_arrival_ms: self.first_arrival_ms,
            overuse_start_ms: optional_of(self.has_overuse_start, self.overuse_start_ms),
            prev_trend: self.prev_trend,
        })
    }

    /// The crossing form of a wrapped detector.
    fn of(estimator: &TrendlineEstimator) -> Self {
        let snapshot = estimator.snapshot();
        let (has_prev_arrival, prev_arrival_ms) = optional(snapshot.prev_arrival_ms, 0.0);
        let (has_overuse_start, overuse_start_ms) = optional(snapshot.overuse_start_ms, 0.0);
        Self {
            config: SlopDeskTrendlineConfig::of(snapshot.config),
            state: state_code(snapshot.state),
            modified_trend: snapshot.modified_trend,
            num_deltas: snapshot.num_deltas,
            threshold: snapshot.threshold,
            has_prev_arrival,
            prev_arrival_ms,
            has_prev_send_ts: snapshot.prev_send_ts.is_some(),
            prev_send_ts: snapshot.prev_send_ts.unwrap_or(0),
            accumulated_delay_ms: snapshot.accumulated_delay_ms,
            smoothed_delay_ms: snapshot.smoothed_delay_ms,
            window_x: snapshot.window_x,
            window_y: snapshot.window_y,
            window_len: snapshot.window_len,
            first_arrival_ms: snapshot.first_arrival_ms,
            has_overuse_start,
            overuse_start_ms,
            prev_trend: snapshot.prev_trend,
        }
    }
}

/// A detector at the given operating point, with an empty window and the initial threshold.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_new(config: SlopDeskTrendlineConfig) -> SlopDeskTrendline {
    SlopDeskTrendline::of(&TrendlineEstimator::new(config.inner()))
}

/// Folds one per-FRAME sample: the arrival of the frame's first-seen fragment, and its send stamp.
///
/// The caller admits one sample per strictly-newer frame id through the sampler below.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_note(
    estimator: SlopDeskTrendline,
    arrival_ms: f64,
    send_ts: u32,
) -> SlopDeskTrendline {
    let mut inner = estimator.inner();
    inner.note(arrival_ms, send_ts);
    SlopDeskTrendline::of(&inner)
}

/// Whether the latest verdict is STALE, meaning no accepted sample within the reset gap.
///
/// The state only moves inside a fold, so across a content-idle gap a latched overuse would ride
/// every report until the next arrival resets the window. No samples yet counts as stale.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_is_stale(estimator: SlopDeskTrendline, now_ms: f64) -> bool {
    estimator.inner().is_stale(now_ms)
}

/// The trend times a thousand, rounded and clamped, as the wire's bit pattern.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_pack_milli(modified_trend: f64) -> u32 {
    pack_trend_milli(modified_trend)
}

/// The verdict in the low two bits and the sample count in bits eight to fifteen.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_pack_flags(state: u32, num_deltas: usize) -> u32 {
    pack_trend_flags(state_of(state), num_deltas)
}

/// Whether two detectors are the same state.
///
/// The window makes this the one comparison the near side cannot spell for itself: a C array is a
/// tuple over there, and a tuple that long has no equality.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trendline_eq(left: &SlopDeskTrendline, right: &SlopDeskTrendline) -> bool {
    left == right
}

/// The one-sample-per-frame admission gate, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskTrendSampler {
    /// Whether any frame has been admitted.
    pub has_last_frame_id: bool,
    /// The frame the gate last admitted.
    pub last_frame_id: u32,
}

/// One gate decision: the sampler that results, and whether this frame is a sample.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskTrendSample {
    /// The sampler after the decision.
    pub sampler: SlopDeskTrendSampler,
    /// Whether the caller should fold this frame.
    pub sampled: bool,
}

/// A gate that has seen no frame.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_trend_sampler_new() -> SlopDeskTrendSampler {
    SlopDeskTrendSampler {
        has_last_frame_id: false,
        last_frame_id: 0,
    }
}

/// True exactly once per strictly-newer frame id, and never for a zero stamp.
///
/// Every fragment of one frame shares one packetize-time stamp, so per-fragment samples would carry
/// a built-in positive slope inside every multi-fragment frame.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_trend_sampler_should_sample(
    sampler: SlopDeskTrendSampler,
    frame_id: u32,
    send_ts: u32,
) -> SlopDeskTrendSample {
    let mut inner = TrendSampler::restored(sampler.has_last_frame_id.then_some(sampler.last_frame_id));
    let admitted = inner.should_sample(frame_id, send_ts);
    let last = inner.last_frame_id();
    SlopDeskTrendSample {
        sampler: SlopDeskTrendSampler {
            has_last_frame_id: last.is_some(),
            last_frame_id: last.unwrap_or(0),
        },
        sampled: admitted,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::float_cmp,
    reason = "calling the door is the only way to test the door, and a threshold is compared against the \
              constant the law seeds it with"
)]
mod tests {
    use super::{
        SLOPDESK_TREND_STATE_NORMAL, SLOPDESK_TREND_STATE_OVERUSING, SlopDeskTrendline,
        SlopDeskTrendlineConfig, slopdesk_trend_sampler_new, slopdesk_trend_sampler_should_sample,
        slopdesk_trendline_config_apply, slopdesk_trendline_config_default, slopdesk_trendline_constants,
        slopdesk_trendline_eq, slopdesk_trendline_is_stale, slopdesk_trendline_new, slopdesk_trendline_note,
        slopdesk_trendline_pack_flags, slopdesk_trendline_pack_milli,
    };

    /// Applies one environment pair through the door.
    fn apply(config: SlopDeskTrendlineConfig, key: &str, value: &str) -> SlopDeskTrendlineConfig {
        // SAFETY: both slices outlive the call.
        unsafe {
            slopdesk_trendline_config_apply(config, key.as_ptr(), key.len(), value.as_ptr(), value.len())
        }
    }

    /// Feeds a run of samples at a fixed arrival cadence and a fixed stamp step.
    fn feed(
        estimator: &mut SlopDeskTrendline,
        count: usize,
        arrival: &mut f64,
        stamp: &mut u32,
        arrival_step: f64,
        stamp_step: u32,
    ) {
        for _ in 0..count {
            *arrival += arrival_step;
            *stamp = stamp.wrapping_add(stamp_step);
            *estimator = slopdesk_trendline_note(*estimator, *arrival, *stamp);
        }
    }

    #[test]
    fn a_fresh_detector_is_stale_and_holds_the_seeded_threshold() {
        let estimator = slopdesk_trendline_new(slopdesk_trendline_config_default());
        assert!(slopdesk_trendline_is_stale(estimator, 0.0));
        assert_eq!(
            estimator.threshold,
            slopdesk_trendline_constants().initial_threshold
        );
        assert_eq!(estimator.state, SLOPDESK_TREND_STATE_NORMAL);
    }

    #[test]
    fn the_whole_window_crosses_so_the_slope_is_the_slope() {
        let config = slopdesk_trendline_config_default();
        let mut arrival = 1000.0;
        let mut stamp = 5000_u32;
        // A clean path: arrivals and stamps step together, so the delay variation is zero.
        let mut clean = slopdesk_trendline_new(config);
        feed(
            &mut clean,
            config.window_size + 5,
            &mut arrival,
            &mut stamp,
            16.0,
            16,
        );
        assert_eq!(clean.window_len, config.window_size, "the window filled");
        assert_eq!(clean.state, SLOPDESK_TREND_STATE_NORMAL);
        // A queue building: every arrival lags its stamp by a growing amount.
        let mut congested = clean;
        for _ in 0..40 {
            arrival += 24.0;
            stamp = stamp.wrapping_add(16);
            congested = slopdesk_trendline_note(congested, arrival, stamp);
        }
        assert_eq!(
            congested.state, SLOPDESK_TREND_STATE_OVERUSING,
            "a sustained rising delay is what overuse means",
        );
        assert!(congested.modified_trend > congested.threshold);
    }

    #[test]
    fn an_idle_gap_clears_the_queue_context_but_keeps_the_learned_threshold() {
        let config = slopdesk_trendline_config_default();
        let mut arrival = 1000.0;
        let mut stamp = 5000_u32;
        let mut warm = slopdesk_trendline_new(config);
        feed(
            &mut warm,
            config.window_size + 5,
            &mut arrival,
            &mut stamp,
            16.0,
            16,
        );
        let threshold = warm.threshold;
        let after = slopdesk_trendline_note(
            warm,
            arrival + slopdesk_trendline_constants().reset_gap_ms + 1.0,
            stamp.wrapping_add(16),
        );
        assert_eq!(after.window_len, 0, "the regression context is stale");
        assert_eq!(after.num_deltas, 0);
        assert_eq!(after.threshold, threshold, "path noise is not queue context");
    }

    #[test]
    fn the_state_compares_the_whole_window_and_not_just_its_verdict() {
        let config = slopdesk_trendline_config_default();
        let mut arrival = 1000.0;
        let mut stamp = 5000_u32;
        let mut warm = slopdesk_trendline_new(config);
        feed(
            &mut warm,
            config.window_size + 5,
            &mut arrival,
            &mut stamp,
            16.0,
            16,
        );
        assert!(slopdesk_trendline_eq(&warm, &warm));
        let moved = slopdesk_trendline_note(warm, arrival + 16.0, stamp.wrapping_add(16));
        assert!(!slopdesk_trendline_eq(&warm, &moved));
    }

    #[test]
    fn the_environment_reshapes_the_window_only_inside_its_band() {
        let base = slopdesk_trendline_config_default();
        assert_eq!(apply(base, "SLOPDESK_TREND_WINDOW", "50").window_size, 50);
        assert_eq!(
            apply(base, "SLOPDESK_TREND_WINDOW", "9999").window_size,
            base.window_size,
            "out of band keeps the default rather than clamping",
        );
        assert_eq!(apply(base, "SLOPDESK_TREND_GAIN", "8.5").threshold_gain, 8.5);
        assert_eq!(
            apply(base, "SLOPDESK_NOT_A_KNOB", "3"),
            base,
            "an unknown key is not this door's business",
        );
    }

    #[test]
    fn the_wire_packing_rounds_clamps_and_lays_the_fields_out() {
        assert_eq!(slopdesk_trendline_pack_milli(1.5), 1500);
        assert_eq!(
            slopdesk_trendline_pack_milli(f64::MAX).cast_signed(),
            1_000_000_000,
            "the clamp holds where the detector never reaches",
        );
        assert_eq!(
            slopdesk_trendline_pack_flags(SLOPDESK_TREND_STATE_OVERUSING, 300),
            1 | (255 << 8),
            "the count saturates at a byte",
        );
    }

    #[test]
    fn the_gate_admits_one_sample_per_strictly_newer_frame() {
        let first = slopdesk_trend_sampler_should_sample(slopdesk_trend_sampler_new(), 7, 100);
        assert!(first.sampled);
        assert!(!slopdesk_trend_sampler_should_sample(first.sampler, 7, 100).sampled);
        assert!(!slopdesk_trend_sampler_should_sample(first.sampler, 6, 100).sampled);
        assert!(slopdesk_trend_sampler_should_sample(first.sampler, 8, 100).sampled);
        assert!(
            !slopdesk_trend_sampler_should_sample(first.sampler, 8, 0).sampled,
            "a zero stamp means telemetry is off",
        );
    }
}
