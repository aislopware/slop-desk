//! The one-way-delay GRADIENT detector — congestion read from the queue's SLOPE, not its level.
//!
//! The bitrate controller's smoothed-RTT path needs a quarter of a second from congestion onset to
//! its first cut: an EWMA crossing, then a streak, then a not-improving guard. The slope is visible
//! far earlier than the level, so this regresses the per-FRAME delay variation against arrival time
//! — a 16.7 ms sample cadence at sixty frames, independent of the fifty-millisecond report cadence
//! — and flags OVERUSE the way GCC does, which authorises one early multiplicative cut.
//!
//! The shape is libwebrtc's trendline estimator and overuse detector, field-proven at exactly this
//! job: the per-sample delay variation accumulates, is exponentially smoothed, and a windowed
//! least-squares slope over the smoothed delay is scaled into a modified trend compared against an
//! ADAPTIVE threshold. The threshold rises on noisy paths by itself, which is the whole point —
//! this repo's history falsified two FIXED-threshold delay designs on rate-independent mobile
//! wobble. Overuse must additionally be SUSTAINED before it signals.
//!
//! The send stamps are host-clock deltas and the arrivals client-clock deltas, so the cross-machine
//! offset cancels in the differences, exactly as it does for the jitter estimator;
//! parts-per-million rate skew is nothing across a third of a second.
//!
//! The IDLE RESET is ours rather than libwebrtc's. WebRTC streams continuously; a content-adaptive
//! stream does not, and the frame-rate governor makes idle gaps MORE common. A long arrival gap
//! means the queue context is stale, and a regression straddling two activity clusters would read a
//! bogus slope, so the window is cleared and re-warmed instead of bridged.

use crate::reassembler::distance_wrapped;

/// The detector's verdict, carried in the low two bits of the wire flags field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TrendState {
    /// No gradient worth acting on — also the verdict before the window fills.
    #[default]
    Normal,
    /// The queue is growing: delay rises against arrival time.
    Overusing,
    /// The queue is draining.
    Underusing,
}

impl TrendState {
    /// The wire encoding, which is the libwebrtc ordering.
    #[must_use]
    pub const fn wire_value(self) -> u8 {
        match self {
            Self::Normal => 0,
            Self::Overusing => 1,
            Self::Underusing => 2,
        }
    }
}

/// The exponential smoothing applied to the accumulated delay.
pub const SMOOTHING_COEF: f64 = 0.9;
/// The adaptive threshold's starting value.
pub const INITIAL_THRESHOLD: f64 = 12.5;
/// The floor the adaptive threshold can never fall through.
pub const THRESHOLD_MIN: f64 = 6.0;
/// The ceiling the adaptive threshold can never rise through.
pub const THRESHOLD_MAX: f64 = 600.0;
/// The threshold's rise gain — slow, so one loud trend cannot desensitise the detector for long.
pub const K_UP: f64 = 0.0087;
/// The threshold's fall gain, deliberately several times the rise gain.
pub const K_DOWN: f64 = 0.039;
/// How far past the threshold a sample may sit and still adapt it. Beyond this the sample is a
/// gross outlier, which must not yank the threshold up to its own level.
pub const OUTLIER_SKIP_MARGIN: f64 = 15.0;
/// The clamp on the per-sample time step used in threshold adaptation, in milliseconds.
pub const MAX_ADAPT_DT_MS: f64 = 100.0;
/// How long the trend must stay over the threshold before overuse SIGNALS, in milliseconds.
pub const OVERUSING_TIME_MS: f64 = 10.0;
/// The arrival gap that resets the window: fifteen missed frame slots at sixty frames.
pub const RESET_GAP_MS: f64 = 250.0;
/// Where the sample count saturates inside the modified-trend scale factor.
pub const MAX_SCALED_DELTAS: usize = 60;
/// Where the total sample count saturates. It is a log field, not an input to the math.
pub const MAX_NUM_DELTAS: usize = 1000;
/// The largest regression window the estimator can be configured with.
///
/// It is also the ceiling of [`TrendlineConfig::window_size`]'s band, so a by-value crossing that
/// carries this many samples carries every window a legal config can ask for.
pub const WINDOW_CAPACITY: usize = 200;

/// The env-tunable half of the operating point, for hardware A/B.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrendlineConfig {
    /// The regression window in per-frame samples. Twenty is a third of a second at sixty frames.
    pub window_size: usize,
    /// The gain applied to the slope before the threshold comparison.
    pub threshold_gain: f64,
}

impl Default for TrendlineConfig {
    fn default() -> Self {
        Self {
            window_size: 20,
            threshold_gain: 4.0,
        }
    }
}

/// The regression window's environment name.
pub const TREND_WINDOW_KEY: &str = "SLOPDESK_TREND_WINDOW";
/// The slope gain's environment name.
pub const TREND_GAIN_KEY: &str = "SLOPDESK_TREND_GAIN";

impl TrendlineConfig {
    /// Parses the operating point from the raw environment values. An absent or unparseable value
    /// keeps the default, and so does an out-of-band one — a typo must not silently reshape the
    /// detector.
    #[must_use]
    pub fn from_env(window: Option<&str>, gain: Option<&str>) -> Self {
        let mut config = Self::default();
        for (key, value) in [(TREND_WINDOW_KEY, window), (TREND_GAIN_KEY, gain)] {
            if let Some(text) = value {
                config.apply_env_pair(key, text);
            }
        }
        config
    }

    /// Applies ONE environment pair, which is how a caller holding a whole environment map reaches
    /// the same bands without knowing which knob answers to which name.
    ///
    /// Out-of-band is REJECTED here rather than clamped — the two knobs reshape the detector's
    /// geometry rather than move an operating point along it, so a typo must keep the default.
    pub fn apply_env_pair(&mut self, key: &str, value: &str) {
        match key {
            TREND_WINDOW_KEY => {
                if let Some(parsed) = value
                    .parse::<usize>()
                    .ok()
                    .filter(|&parsed| (5..=WINDOW_CAPACITY).contains(&parsed))
                {
                    self.window_size = parsed;
                }
            },
            TREND_GAIN_KEY => {
                if let Some(parsed) = value
                    .parse::<f64>()
                    .ok()
                    .filter(|parsed| (0.1..=100.0).contains(parsed))
                {
                    self.threshold_gain = parsed;
                }
            },
            _ => {},
        }
    }
}

/// One regression point: arrival milliseconds since the window's first arrival, against the
/// smoothed delay at that arrival.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Sample {
    x: f64,
    y: f64,
}

/// The detector.
#[derive(Debug, Clone, PartialEq)]
pub struct TrendlineEstimator {
    config: TrendlineConfig,
    state: TrendState,
    modified_trend: f64,
    num_deltas: usize,
    threshold: f64,
    prev_arrival_ms: Option<f64>,
    prev_send_ts: Option<u32>,
    accumulated_delay_ms: f64,
    smoothed_delay_ms: f64,
    window: Vec<Sample>,
    first_arrival_ms: f64,
    /// The arrival of the FIRST over-threshold sample of the current excursion.
    overuse_start_ms: Option<f64>,
    prev_trend: f64,
}

impl Default for TrendlineEstimator {
    fn default() -> Self {
        Self::new(TrendlineConfig::default())
    }
}

impl TrendlineEstimator {
    /// A detector at the given operating point.
    #[must_use]
    pub const fn new(config: TrendlineConfig) -> Self {
        Self {
            config,
            state: TrendState::Normal,
            modified_trend: 0.0,
            num_deltas: 0,
            threshold: INITIAL_THRESHOLD,
            prev_arrival_ms: None,
            prev_send_ts: None,
            accumulated_delay_ms: 0.0,
            smoothed_delay_ms: 0.0,
            window: Vec::new(),
            first_arrival_ms: 0.0,
            overuse_start_ms: None,
            prev_trend: 0.0,
        }
    }

    /// The latest verdict. It stays normal until the window fills — the warm-up gate.
    #[must_use]
    pub const fn state(&self) -> TrendState {
        self.state
    }

    /// The value actually compared against the threshold: the saturated sample count times the
    /// slope times the gain. Shipped on the wire for host-side corroboration.
    #[must_use]
    pub const fn modified_trend(&self) -> f64 {
        self.modified_trend
    }

    /// How many samples have been folded, saturating.
    #[must_use]
    pub const fn num_deltas(&self) -> usize {
        self.num_deltas
    }

    /// The live adaptive threshold.
    #[must_use]
    pub const fn threshold(&self) -> f64 {
        self.threshold
    }

    /// Folds one per-FRAME sample: the client-monotonic arrival of the frame's first-seen fragment,
    /// plus that frame's host send stamp. The caller admits one sample per strictly-newer frame id
    /// through [`TrendSampler`].
    pub fn note(&mut self, arrival_ms: f64, send_ts: u32) {
        let (Some(prev_arrival), Some(prev_send)) = (self.prev_arrival_ms, self.prev_send_ts) else {
            self.seed(arrival_ms, send_ts);
            return;
        };
        if arrival_ms - prev_arrival > RESET_GAP_MS {
            self.reset_window();
            self.seed(arrival_ms, send_ts);
            return;
        }
        // A negative host-stamp delta is an older frame slipping through. The sampler already
        // rejects reordered frames; ignoring it here is the depth behind that.
        let d_send = f64::from(distance_wrapped(send_ts, prev_send));
        if d_send < 0.0 {
            return;
        }
        let d_arrival = arrival_ms - prev_arrival;
        self.prev_arrival_ms = Some(arrival_ms);
        self.prev_send_ts = Some(send_ts);

        // The delay variation. Positive means this frame spent longer in flight than the last one,
        // so the queue is growing; the cross-machine clock offset cancels between the two deltas.
        self.accumulated_delay_ms += d_arrival - d_send;
        // BIT-EXACT: the EWMA stays a separate multiply and add, never a fused one — fused rounding
        // diverges the low bits and breaks parity with the Swift original.
        self.smoothed_delay_ms =
            SMOOTHING_COEF * self.smoothed_delay_ms + (1.0 - SMOOTHING_COEF) * self.accumulated_delay_ms;
        self.num_deltas = (self.num_deltas + 1).min(MAX_NUM_DELTAS);

        self.window.push(Sample {
            x: arrival_ms - self.first_arrival_ms,
            y: self.smoothed_delay_ms,
        });
        if self.window.len() > self.config.window_size {
            let excess = self.window.len() - self.config.window_size;
            self.window.drain(..excess);
        }
        // The warm-up gate: no verdict until the window is full.
        if self.window.len() < self.config.window_size {
            return;
        }
        let trend = self.slope();
        // BIT-EXACT: the count, the slope and the gain multiply as a separate chain.
        #[expect(
            clippy::cast_precision_loss,
            reason = "the count saturates at sixty, which every f64 holds exactly"
        )]
        let scale = self.num_deltas.min(MAX_SCALED_DELTAS) as f64;
        self.modified_trend = scale * trend * self.config.threshold_gain;

        self.detect(arrival_ms, trend);
        self.adapt_threshold(d_arrival);
        self.prev_trend = trend;
    }

    /// Whether the latest verdict is STALE, meaning no accepted sample within the reset gap.
    ///
    /// The state only moves inside [`Self::note`], so across a content-idle gap a latched overuse
    /// would otherwise ride EVERY report until the next arrival performs the idle reset. The report
    /// path consults this and ships neutral fields instead, because the host must never act on
    /// queue context that no longer exists. No samples yet counts as stale, and the comparison
    /// mirrors the reset condition exactly.
    #[must_use]
    pub fn is_stale(&self, now_ms: f64) -> bool {
        self.prev_arrival_ms
            .is_none_or(|prev| now_ms - prev > RESET_GAP_MS)
    }

    const fn seed(&mut self, arrival_ms: f64, send_ts: u32) {
        self.prev_arrival_ms = Some(arrival_ms);
        self.prev_send_ts = Some(send_ts);
        self.first_arrival_ms = arrival_ms;
    }

    /// The least-squares slope over the window, in milliseconds of delay per millisecond of arrival
    /// time. A degenerate window — every sample at one arrival — holds the previous slope rather
    /// than inventing one.
    fn slope(&self) -> f64 {
        #[expect(
            clippy::cast_precision_loss,
            reason = "the window is at most two hundred samples"
        )]
        let n = self.window.len() as f64;
        let mut mean_x = 0.0;
        let mut mean_y = 0.0;
        for sample in &self.window {
            mean_x += sample.x;
            mean_y += sample.y;
        }
        mean_x /= n;
        mean_y /= n;
        // BIT-EXACT: the covariance and variance accumulators are a separate multiply and add per
        // term, never folded into a fused one.
        let mut numer = 0.0;
        let mut denom = 0.0;
        for sample in &self.window {
            numer += (sample.x - mean_x) * (sample.y - mean_y);
            denom += (sample.x - mean_x) * (sample.x - mean_x);
        }
        if denom > 0.0 {
            numer / denom
        } else {
            self.prev_trend
        }
    }

    /// Overuse must be SUSTAINED, anchored at the first over-threshold arrival and with a
    /// non-decreasing trend, before it signals. A sub-threshold sample resolves immediately and
    /// clears the clock.
    fn detect(&mut self, arrival_ms: f64, trend: f64) {
        if self.modified_trend > self.threshold {
            let start = *self.overuse_start_ms.get_or_insert(arrival_ms);
            if arrival_ms - start > OVERUSING_TIME_MS && trend >= self.prev_trend {
                self.state = TrendState::Overusing;
            }
        } else if self.modified_trend < -self.threshold {
            self.state = TrendState::Underusing;
            self.overuse_start_ms = None;
        } else {
            self.state = TrendState::Normal;
            self.overuse_start_ms = None;
        }
    }

    /// Moves the threshold toward the trend's magnitude, skipping gross outliers: noisy paths raise
    /// it, quiet ones let it fall back.
    fn adapt_threshold(&mut self, d_arrival: f64) {
        let magnitude = self.modified_trend.abs();
        if magnitude > self.threshold + OUTLIER_SKIP_MARGIN {
            return;
        }
        let k = if magnitude < self.threshold { K_DOWN } else { K_UP };
        // BIT-EXACT: the gain, the excess and the time step multiply separately from the outer add.
        self.threshold += k * (magnitude - self.threshold) * d_arrival.min(MAX_ADAPT_DT_MS);
        #[expect(
            clippy::manual_clamp,
            reason = "`clamp` returns NaN for a NaN input; the chained max-then-min drops a NaN to the \
                      floor, which is what the Swift original's ordered nesting does"
        )]
        {
            self.threshold = self.threshold.max(THRESHOLD_MIN).min(THRESHOLD_MAX);
        }
    }

    /// Every field the next fold reads, for a caller that carries the estimator BY VALUE across a
    /// boundary rather than holding it.
    ///
    /// The regression WINDOW travels as a pair of fixed-capacity arrays, because a least-squares
    /// slope is computed over the samples themselves: running sums that dropped the evicted point
    /// arithmetically would be a different sequence of rounding, and the wire's trend bits are
    /// pinned.
    #[must_use]
    pub fn snapshot(&self) -> TrendlineSnapshot {
        let mut window_x = [0.0; WINDOW_CAPACITY];
        let mut window_y = [0.0; WINDOW_CAPACITY];
        let mut window_len = 0;
        for ((slot_x, slot_y), sample) in window_x
            .iter_mut()
            .zip(window_y.iter_mut())
            .zip(self.window.iter())
        {
            *slot_x = sample.x;
            *slot_y = sample.y;
            window_len += 1;
        }
        TrendlineSnapshot {
            config: self.config,
            state: self.state,
            modified_trend: self.modified_trend,
            num_deltas: self.num_deltas,
            threshold: self.threshold,
            prev_arrival_ms: self.prev_arrival_ms,
            prev_send_ts: self.prev_send_ts,
            accumulated_delay_ms: self.accumulated_delay_ms,
            smoothed_delay_ms: self.smoothed_delay_ms,
            window_x,
            window_y,
            window_len,
            first_arrival_ms: self.first_arrival_ms,
            overuse_start_ms: self.overuse_start_ms,
            prev_trend: self.prev_trend,
        }
    }

    /// The estimator that snapshot describes. It is the inverse of [`Self::snapshot`], so a fold
    /// across the boundary is the fold this side would have run.
    #[must_use]
    pub fn restored(snapshot: TrendlineSnapshot) -> Self {
        let mut config = snapshot.config;
        // The band already stops here, so this is a guard rather than a truncation.
        config.window_size = config.window_size.min(WINDOW_CAPACITY);
        let window = snapshot
            .window_x
            .iter()
            .zip(snapshot.window_y.iter())
            .take(snapshot.window_len.min(WINDOW_CAPACITY))
            .map(|(&x, &y)| Sample { x, y })
            .collect();
        Self {
            config,
            state: snapshot.state,
            modified_trend: snapshot.modified_trend,
            num_deltas: snapshot.num_deltas,
            threshold: snapshot.threshold,
            prev_arrival_ms: snapshot.prev_arrival_ms,
            prev_send_ts: snapshot.prev_send_ts,
            accumulated_delay_ms: snapshot.accumulated_delay_ms,
            smoothed_delay_ms: snapshot.smoothed_delay_ms,
            window,
            first_arrival_ms: snapshot.first_arrival_ms,
            overuse_start_ms: snapshot.overuse_start_ms,
            prev_trend: snapshot.prev_trend,
        }
    }

    /// Clears the regression context but KEEPS the adapted threshold — knowledge about the path's
    /// noise survives an idle gap, knowledge about its queue does not.
    fn reset_window(&mut self) {
        self.window.clear();
        self.accumulated_delay_ms = 0.0;
        self.smoothed_delay_ms = 0.0;
        self.num_deltas = 0;
        self.overuse_start_ms = None;
        self.prev_trend = 0.0;
        self.modified_trend = 0.0;
        self.state = TrendState::Normal;
    }
}

/// The estimator's whole state, for a by-value crossing.
///
/// The window is a pair of parallel arrays rather than an array of points, because that is what
/// crosses a C boundary without a private type going with it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrendlineSnapshot {
    /// The env-tunable half of the operating point, which travels with the state.
    pub config: TrendlineConfig,
    /// The latest verdict.
    pub state: TrendState,
    /// The value compared against the threshold.
    pub modified_trend: f64,
    /// How many samples have folded, saturating.
    pub num_deltas: usize,
    /// The live adaptive threshold, which an idle reset deliberately KEEPS.
    pub threshold: f64,
    /// The previous arrival, which the next delay variation steps from.
    pub prev_arrival_ms: Option<f64>,
    /// The previous send stamp.
    pub prev_send_ts: Option<u32>,
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
    /// The first over-threshold arrival of the current excursion, which the sustain clock reads.
    pub overuse_start_ms: Option<f64>,
    /// The previous slope, which the sustain rule and a degenerate window both read.
    pub prev_trend: f64,
}

/// The trend times a thousand, rounded and clamped, as an unsigned bit pattern.
///
/// Free-standing rather than a method so the clamp is testable at magnitudes the detector cannot
/// reach organically.
#[must_use]
pub fn pack_trend_milli(modified_trend: f64) -> u32 {
    // BIT-EXACT: scale then round half away from zero.
    let milli = (modified_trend * 1000.0).round();
    #[expect(
        clippy::manual_clamp,
        reason = "`clamp` returns NaN for a NaN input; the chained max-then-min sends a NaN to the negative \
                  bound, which is what the Swift original's ordered nesting does"
    )]
    let clamped = milli.max(-1_000_000_000.0).min(1_000_000_000.0);
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the clamp already put the value inside the signed range"
    )]
    let value = clamped as i32;
    value.cast_unsigned()
}

/// The verdict in the low two bits and the sample count in bits eight to fifteen, the latter purely
/// for host log context.
#[must_use]
pub fn pack_trend_flags(state: TrendState, num_deltas: usize) -> u32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the count is clamped to a byte before it is cast"
    )]
    let deltas = num_deltas.min(255) as u32;
    u32::from(state.wire_value() & 0x3) | (deltas << 8)
}

/// The one-sample-per-frame admission gate.
///
/// Every fragment of one frame shares ONE packetize-time send stamp, so per-fragment samples would
/// carry a built-in positive slope inside every multi-fragment frame — later fragments arriving
/// later under the same stamp. Gating on the first fragment of a wrap-aware strictly-newer frame id
/// also makes keyframe duplicates and reordered older fragments self-rejecting, and a zero stamp,
/// which means telemetry is off, never samples at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TrendSampler {
    last_frame_id: Option<u32>,
}

impl TrendSampler {
    /// A sampler that has seen no frame.
    #[must_use]
    pub const fn new() -> Self {
        Self { last_frame_id: None }
    }

    /// The frame the gate last admitted, for a caller that carries the sampler BY VALUE.
    #[must_use]
    pub const fn last_frame_id(self) -> Option<u32> {
        self.last_frame_id
    }

    /// The sampler that last-admitted frame describes.
    #[must_use]
    pub const fn restored(last_frame_id: Option<u32>) -> Self {
        Self { last_frame_id }
    }

    /// True exactly once per strictly-newer frame id, and never for a zero stamp.
    pub const fn should_sample(&mut self, frame_id: u32, send_ts: u32) -> bool {
        if send_ts == 0 {
            return false;
        }
        match self.last_frame_id {
            Some(last) if distance_wrapped(frame_id, last) <= 0 => false,
            _ => {
                self.last_frame_id = Some(frame_id);
                true
            },
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the packed values and the seeded threshold are compared against their own pinned constants"
    )]

    use super::{
        INITIAL_THRESHOLD, RESET_GAP_MS, THRESHOLD_MIN, TrendSampler, TrendState, TrendlineConfig,
        TrendlineEstimator, pack_trend_flags, pack_trend_milli,
    };

    /// A stream whose arrivals track the send stamps exactly: no delay variation at all.
    fn steady(estimator: &mut TrendlineEstimator, samples: usize) {
        for step in 0..samples {
            #[expect(clippy::cast_precision_loss, reason = "a test's small step count")]
            let at = step as f64 * 16.0;
            #[expect(clippy::cast_possible_truncation, reason = "a test's small step count")]
            let stamp = (step as u32) * 16;
            estimator.note(at, stamp);
        }
    }

    #[test]
    fn a_clean_path_never_signals_and_never_fills_a_trend() {
        let mut estimator = TrendlineEstimator::default();
        steady(&mut estimator, 60);
        assert_eq!(estimator.state(), TrendState::Normal);
        assert!(estimator.modified_trend().abs() < 1e-9);
        assert_eq!(estimator.num_deltas(), 59);
    }

    #[test]
    fn a_growing_queue_signals_overuse_once_the_excursion_is_sustained() {
        let mut estimator = TrendlineEstimator::default();
        let mut at = 0.0;
        for step in 0..80_u32 {
            // Each frame lands four milliseconds later than the last relative to its stamp.
            at += 20.0;
            estimator.note(at, step * 16);
        }
        assert_eq!(estimator.state(), TrendState::Overusing);
        assert!(estimator.modified_trend() > estimator.threshold());
    }

    #[test]
    fn a_draining_queue_signals_underuse() {
        let mut estimator = TrendlineEstimator::default();
        let mut at = 0.0;
        for step in 0..80_u32 {
            at += 12.0;
            estimator.note(at, step * 16);
        }
        assert_eq!(estimator.state(), TrendState::Underusing);
    }

    #[test]
    fn the_verdict_waits_for_a_full_window() {
        let mut estimator = TrendlineEstimator::new(TrendlineConfig {
            window_size: 20,
            threshold_gain: 4.0,
        });
        let mut at = 0.0;
        for step in 0..10_u32 {
            at += 40.0;
            estimator.note(at, step * 16);
        }
        assert_eq!(estimator.state(), TrendState::Normal, "the window is half full");
        assert_eq!(estimator.modified_trend(), 0.0);
    }

    #[test]
    fn an_idle_gap_clears_the_queue_context_but_keeps_the_learned_threshold() {
        let mut estimator = TrendlineEstimator::default();
        let mut at = 0.0;
        for step in 0..80_u32 {
            at += 20.0;
            estimator.note(at, step * 16);
        }
        let learned = estimator.threshold();
        assert!(learned > INITIAL_THRESHOLD, "a loud path raises the threshold");
        estimator.note(at + RESET_GAP_MS + 1.0, 80 * 16);
        assert_eq!(estimator.state(), TrendState::Normal);
        assert_eq!(estimator.num_deltas(), 0);
        assert_eq!(estimator.threshold(), learned);
    }

    #[test]
    fn a_quiet_path_lets_the_threshold_fall_back_to_its_floor() {
        let mut estimator = TrendlineEstimator::default();
        steady(&mut estimator, 400);
        assert_eq!(estimator.threshold(), THRESHOLD_MIN);
    }

    #[test]
    fn staleness_mirrors_the_reset_gap_and_starts_true() {
        let estimator = TrendlineEstimator::default();
        assert!(estimator.is_stale(0.0), "no sample yet");
        let mut estimator = TrendlineEstimator::default();
        estimator.note(100.0, 1);
        assert!(!estimator.is_stale(100.0 + RESET_GAP_MS));
        assert!(estimator.is_stale(100.0 + RESET_GAP_MS + 0.001));
    }

    #[test]
    fn a_reordered_stamp_is_ignored_rather_than_folded_backwards() {
        let mut estimator = TrendlineEstimator::default();
        estimator.note(0.0, 1000);
        estimator.note(16.0, 900);
        assert_eq!(estimator.num_deltas(), 0, "the older stamp never folded");
        estimator.note(32.0, 1016);
        assert_eq!(
            estimator.num_deltas(),
            1,
            "and it never became the reference either"
        );
    }

    #[test]
    fn the_stamp_delta_survives_the_wrap() {
        let mut estimator = TrendlineEstimator::default();
        estimator.note(0.0, u32::MAX - 8);
        estimator.note(16.0, 7);
        assert_eq!(estimator.num_deltas(), 1, "sixteen milliseconds across the wrap");
    }

    #[test]
    fn the_packed_trend_rounds_scales_and_clamps() {
        assert_eq!(pack_trend_milli(2.5), 2500);
        assert_eq!(pack_trend_milli(0.0), 0);
        assert_eq!(pack_trend_milli(-2.5).cast_signed(), -2500);
        assert_eq!(pack_trend_milli(1e12).cast_signed(), 1_000_000_000);
        assert_eq!(pack_trend_milli(-1e12).cast_signed(), -1_000_000_000);
        assert_eq!(
            pack_trend_milli(f64::NAN).cast_signed(),
            -1_000_000_000,
            "a NaN drops to the negative bound rather than becoming a wild bit pattern",
        );
    }

    #[test]
    fn the_packed_flags_carry_the_verdict_under_the_count() {
        assert_eq!(pack_trend_flags(TrendState::Normal, 0), 0);
        assert_eq!(pack_trend_flags(TrendState::Overusing, 3), 1 | (3 << 8));
        assert_eq!(pack_trend_flags(TrendState::Underusing, 1000), 2 | (255 << 8));
    }

    #[test]
    fn the_sampler_admits_one_first_fragment_per_newer_frame() {
        let mut sampler = TrendSampler::new();
        assert!(sampler.should_sample(10, 500));
        assert!(
            !sampler.should_sample(10, 500),
            "the same frame's later fragments"
        );
        assert!(!sampler.should_sample(9, 500), "a reordered older frame");
        assert!(sampler.should_sample(11, 500));
        assert!(!sampler.should_sample(9, 0), "telemetry off never samples");
    }

    #[test]
    fn the_sampler_follows_the_frame_id_across_the_wrap() {
        let mut sampler = TrendSampler::new();
        assert!(sampler.should_sample(u32::MAX - 1, 500));
        assert!(sampler.should_sample(3, 500));
        assert!(!sampler.should_sample(u32::MAX - 1, 500));
    }

    #[test]
    fn the_environment_keeps_the_default_for_an_out_of_band_value() {
        let tuned = TrendlineConfig::from_env(Some("40"), Some("2.5"));
        assert_eq!(tuned.window_size, 40);
        assert_eq!(tuned.threshold_gain, 2.5);
        let default = TrendlineConfig::default();
        assert_eq!(TrendlineConfig::from_env(Some("1"), Some("nonsense")), default);
        assert_eq!(TrendlineConfig::from_env(Some("400"), Some("1000")), default);
    }
}
