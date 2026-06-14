//! libwebrtc-trendline-style one-way-delay GRADIENT detector — a port of Swift
//! `TrendlineEstimator` (component 3), plus its `TrendSampler` admission gate and wire packing.
//!
//! The queue's *slope* is visible earlier than its *level*: this regresses per-FRAME delay
//! variation against arrival time and flags OVERUSE the way GCC/libwebrtc does, so the host can
//! authorize one early multiplicative cut per spacing window. Per-sample delay variation
//! `d = d_arrival − d_send` accumulates, is exponentially smoothed, and a windowed OLS slope over
//! `(arrival, smoothed_delay)` is scaled into a `modified_trend` compared against an ADAPTIVE
//! threshold (rises on noisy paths, falls on quiet ones). Overuse must be SUSTAINED before it
//! signals. The cross-machine clock offset cancels in the deltas. An idle-gap reset clears stale
//! queue context. Pure + deterministic + `PartialEq` — the caller injects every arrival.
//!
//! Tunables: the Swift source resolves `window_size` / `threshold_gain` from `AISLOPDESK_TREND_*`
//! env vars at startup; the portable core uses the compile-time defaults (identical when unset).

use crate::seq::distance_wrapped;

/// Regression window in per-frame samples (333 ms @60fps).
pub const WINDOW_SIZE: usize = 20;
/// Exponential smoothing on the accumulated delay.
pub const SMOOTHING_COEF: f64 = 0.9;
/// Gain applied to the slope before the threshold compare.
pub const THRESHOLD_GAIN: f64 = 4.0;
/// Adaptive-threshold start value.
pub const INITIAL_THRESHOLD: f64 = 12.5;
/// Adaptive-threshold floor.
pub const THRESHOLD_MIN: f64 = 6.0;
/// Adaptive-threshold ceiling.
pub const THRESHOLD_MAX: f64 = 600.0;
/// Adaptive-threshold rise gain toward a loud trend.
pub const K_UP: f64 = 0.0087;
/// Adaptive-threshold fall gain toward a quiet trend.
pub const K_DOWN: f64 = 0.039;
/// Skip threshold adaptation when |trend| overshoots it by more than this.
pub const OUTLIER_SKIP_MARGIN: f64 = 15.0;
/// Clamp on the per-sample dt used in threshold adaptation (ms).
pub const MAX_ADAPT_DT_MS: f64 = 100.0;
/// Time over threshold required before overuse SIGNALS (ms).
pub const OVERUSING_TIME_MS: f64 = 10.0;
/// An arrival gap larger than this resets the window (ms).
pub const RESET_GAP_MS: f64 = 250.0;
/// `num_deltas` saturation in the modified-trend scale factor.
const MAX_SCALED_DELTAS: i64 = 60;

/// Detector output, encoded into bits 0-1 of the wire flags field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// No significant delay trend.
    Normal = 0,
    /// Delay growing — a queue is building.
    Overusing = 1,
    /// Delay shrinking — a queue is draining.
    Underusing = 2,
}

/// One regression point: `x` = arrival ms since the window's first arrival, `y` = smoothed delay.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Sample {
    x: f64,
    y: f64,
}

/// Windowed OLS delay-gradient detector. `PartialEq` (f64 / `Vec` fields).
#[derive(Debug, Clone, PartialEq)]
pub struct TrendlineEstimator {
    state: State,
    modified_trend: f64,
    num_deltas: i64,
    threshold: f64,
    prev_arrival_ms: Option<f64>,
    prev_send_ts: Option<u32>,
    accumulated_delay_ms: f64,
    smoothed_delay_ms: f64,
    window: Vec<Sample>,
    first_arrival_ms: f64,
    overuse_start_ms: Option<f64>,
    prev_trend: f64,
}

impl Default for TrendlineEstimator {
    fn default() -> Self {
        Self::new()
    }
}

impl TrendlineEstimator {
    /// A fresh estimator (verdict `Normal`, threshold at [`INITIAL_THRESHOLD`]).
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: State::Normal,
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

    /// The latest detector verdict.
    #[must_use]
    pub const fn state(&self) -> State {
        self.state
    }
    /// `min(num_deltas, 60) × slope × threshold_gain` — the value compared against `threshold`.
    #[must_use]
    pub const fn modified_trend(&self) -> f64 {
        self.modified_trend
    }
    /// Total samples folded (saturates at 1000).
    #[must_use]
    pub const fn num_deltas(&self) -> i64 {
        self.num_deltas
    }
    /// The adaptive detection threshold.
    #[must_use]
    pub const fn threshold(&self) -> f64 {
        self.threshold
    }

    /// Folds one per-FRAME sample: the client-monotonic arrival ms plus the frame's
    /// `host_send_ts_millis` stamp. The caller gates to one sample per strictly-newer frame id via
    /// [`TrendSampler`].
    pub fn note(&mut self, arrival_ms: f64, send_ts: u32) {
        let (Some(prev_arrival), Some(prev_send)) = (self.prev_arrival_ms, self.prev_send_ts)
        else {
            // First sample: seed only.
            self.prev_arrival_ms = Some(arrival_ms);
            self.prev_send_ts = Some(send_ts);
            self.first_arrival_ms = arrival_ms;
            return;
        };
        if arrival_ms - prev_arrival > RESET_GAP_MS {
            // IDLE RESET: clear the regression context, re-seed, re-warm.
            self.reset_window();
            self.prev_arrival_ms = Some(arrival_ms);
            self.prev_send_ts = Some(send_ts);
            self.first_arrival_ms = arrival_ms;
            return;
        }
        // Wrap-aware host-stamp delta; a negative delta (a reordered older frame) is ignored.
        let d_send = f64::from(distance_wrapped(send_ts, prev_send));
        if d_send < 0.0 {
            return;
        }
        let d_arrival = arrival_ms - prev_arrival;
        self.prev_arrival_ms = Some(arrival_ms);
        self.prev_send_ts = Some(send_ts);

        // Delay variation: positive d ⇒ this frame spent longer in flight (queue growing).
        let d = d_arrival - d_send;
        self.accumulated_delay_ms += d;
        self.smoothed_delay_ms = SMOOTHING_COEF * self.smoothed_delay_ms
            + (1.0 - SMOOTHING_COEF) * self.accumulated_delay_ms;
        self.num_deltas = (self.num_deltas + 1).min(1000);

        self.window.push(Sample {
            x: arrival_ms - self.first_arrival_ms,
            y: self.smoothed_delay_ms,
        });
        if self.window.len() > WINDOW_SIZE {
            let excess = self.window.len() - WINDOW_SIZE;
            self.window.drain(0..excess);
        }
        // Warm-up gate: no verdict until the window is full.
        if self.window.len() < WINDOW_SIZE {
            return;
        }

        // OLS slope over the window (ms of delay per ms of arrival time).
        let n = self.window.len() as f64;
        let mut mean_x = 0.0;
        let mut mean_y = 0.0;
        for s in &self.window {
            mean_x += s.x;
            mean_y += s.y;
        }
        mean_x /= n;
        mean_y /= n;
        let mut numer = 0.0;
        let mut denom = 0.0;
        for s in &self.window {
            numer += (s.x - mean_x) * (s.y - mean_y);
            denom += (s.x - mean_x) * (s.x - mean_x);
        }
        let trend = if denom > 0.0 {
            numer / denom
        } else {
            self.prev_trend
        };
        self.modified_trend =
            (self.num_deltas.min(MAX_SCALED_DELTAS)) as f64 * trend * THRESHOLD_GAIN;

        // Detect: overuse must be SUSTAINED (> overusing_time_ms, non-decreasing trend) to signal.
        if self.modified_trend > self.threshold {
            if self.overuse_start_ms.is_none() {
                self.overuse_start_ms = Some(arrival_ms);
            }
            if let Some(start) = self.overuse_start_ms {
                if arrival_ms - start > OVERUSING_TIME_MS && trend >= self.prev_trend {
                    self.state = State::Overusing;
                }
            }
        } else if self.modified_trend < -self.threshold {
            self.state = State::Underusing;
            self.overuse_start_ms = None;
        } else {
            self.state = State::Normal;
            self.overuse_start_ms = None;
        }

        // Adapt the threshold toward |modified_trend| (skip gross outliers), clamped.
        if self.modified_trend.abs() <= self.threshold + OUTLIER_SKIP_MARGIN {
            let k = if self.modified_trend.abs() < self.threshold {
                K_DOWN
            } else {
                K_UP
            };
            self.threshold +=
                k * (self.modified_trend.abs() - self.threshold) * d_arrival.min(MAX_ADAPT_DT_MS);
            // `max().min()` mirrors Swift's `min(thresholdMax, max(thresholdMin, threshold))`
            // exactly (identical to `clamp` for the finite values reachable here; intentionally
            // NOT `clamp`, which would propagate NaN where Swift's min/max drop it).
            #[allow(clippy::manual_clamp)]
            {
                self.threshold = self.threshold.max(THRESHOLD_MIN).min(THRESHOLD_MAX);
            }
        }
        self.prev_trend = trend;
    }

    /// Whether the latest verdict is STALE at `now_ms`: no accepted sample within [`RESET_GAP_MS`].
    /// No samples yet ⇒ stale. The `>` mirrors [`note`](Self::note)'s reset condition exactly.
    #[must_use]
    pub fn is_stale(&self, now_ms: f64) -> bool {
        self.prev_arrival_ms
            .is_none_or(|prev| now_ms - prev > RESET_GAP_MS)
    }

    /// Clears the regression context but KEEPS the adapted threshold.
    fn reset_window(&mut self) {
        self.window.clear();
        self.accumulated_delay_ms = 0.0;
        self.smoothed_delay_ms = 0.0;
        self.num_deltas = 0;
        self.overuse_start_ms = None;
        self.prev_trend = 0.0;
        self.modified_trend = 0.0;
        self.state = State::Normal;
    }

    // Wire packing (NetworkStatsReport.owd_trend_milli / owd_trend_flags).

    /// `modified_trend × 1000` rounded, clamped to ±1e9, as an `i32` bit-pattern. Uses
    /// `max().min()` (not `f64::clamp`) to reproduce Swift's `min(1e9, max(-1e9, milli))` exactly,
    /// including its NaN-dropping (`clamp` would propagate NaN): identical for every finite input,
    /// and a NaN argument to this public fn yields the same `-1e9` byte as Swift.
    #[must_use]
    pub fn pack_trend_milli(modified_trend: f64) -> u32 {
        let milli = (modified_trend * 1000.0).round();
        #[allow(clippy::manual_clamp)]
        // intentional: NaN-dropping like Swift's min(max()), not clamp
        let clamped = milli.max(-1_000_000_000.0).min(1_000_000_000.0);
        (clamped as i32) as u32
    }

    /// Bits 0-1: detector state; bits 8-15: `min(num_deltas, 255)`.
    #[must_use]
    pub fn pack_trend_flags(state: State, num_deltas: i64) -> u32 {
        u32::from(state as u8 & 0x3) | ((num_deltas.clamp(0, 255) as u32) << 8)
    }

    /// The wire value for `NetworkStatsReport::owd_trend_milli`.
    #[must_use]
    pub fn wire_trend_milli(&self) -> u32 {
        Self::pack_trend_milli(self.modified_trend)
    }

    /// The wire value for `NetworkStatsReport::owd_trend_flags`.
    #[must_use]
    pub fn wire_trend_flags(&self) -> u32 {
        Self::pack_trend_flags(self.state, self.num_deltas)
    }
}

/// Admits exactly ONE trend sample per frame: the FIRST fragment of each wrap-aware strictly-NEWER
/// frame id (and never for `send_ts == 0`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TrendSampler {
    last_frame_id: Option<u32>,
}

impl TrendSampler {
    /// A fresh sampler.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_frame_id: None,
        }
    }

    /// `true` exactly once per strictly-newer frame id (and never for `send_ts == 0`).
    pub const fn should_sample(&mut self, frame_id: u32, send_ts: u32) -> bool {
        if send_ts == 0 {
            return false;
        }
        match self.last_frame_id {
            None => {
                self.last_frame_id = Some(frame_id);
                true
            }
            Some(last) if distance_wrapped(frame_id, last) > 0 => {
                self.last_frame_id = Some(frame_id);
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recovery::NetworkStatsReport;

    fn feed(
        est: &mut TrendlineEstimator,
        count: usize,
        arrival: &mut f64,
        ts: &mut u32,
        arrival_step_ms: f64,
        send_step_ms: u32,
    ) {
        for _ in 0..count {
            *arrival += arrival_step_ms;
            *ts = ts.wrapping_add(send_step_ms);
            est.note(*arrival, *ts);
        }
    }

    #[test]
    fn flat_delay_stays_normal() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        for _ in 0..200 {
            arrival += 16.0;
            ts = ts.wrapping_add(16);
            est.note(arrival, ts);
            assert_eq!(est.state(), State::Normal);
        }
        assert!(est.modified_trend().abs() < 0.0001);
    }

    #[test]
    fn linear_ramp_signals_overuse() {
        fn onset(ramp_ms_per_frame: f64) -> Option<i32> {
            let mut est = TrendlineEstimator::new();
            let mut arrival = 1000.0;
            let mut ts: u32 = 5000;
            est.note(arrival, ts);
            feed(&mut est, 60, &mut arrival, &mut ts, 16.0, 16);
            assert_eq!(est.state(), State::Normal);
            for i in 1..=40 {
                arrival += 16.0 + ramp_ms_per_frame;
                ts = ts.wrapping_add(16);
                est.note(arrival, ts);
                if est.state() == State::Overusing {
                    return Some(i);
                }
            }
            None
        }
        let steep = onset(25.0);
        assert!(steep.is_some());
        assert!(steep.unwrap() <= 6);
        let gentle = onset(1.5);
        assert!(gentle.is_some());
        assert!(gentle.unwrap() <= 16);
    }

    #[test]
    fn ramp_then_plateau_returns_to_normal() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        feed(&mut est, 60, &mut arrival, &mut ts, 16.0, 16);
        feed(&mut est, 15, &mut arrival, &mut ts, 17.5, 16);
        assert_eq!(est.state(), State::Overusing);
        feed(&mut est, WINDOW_SIZE + 5, &mut arrival, &mut ts, 16.0, 16);
        assert_eq!(est.state(), State::Normal);
    }

    #[test]
    fn drain_signals_underusing_never_overusing() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        feed(&mut est, 60, &mut arrival, &mut ts, 16.0, 16);
        let mut saw_underusing = false;
        for _ in 0..40 {
            arrival += 14.5;
            ts = ts.wrapping_add(16);
            est.note(arrival, ts);
            assert_ne!(est.state(), State::Overusing);
            if est.state() == State::Underusing {
                saw_underusing = true;
            }
        }
        assert!(saw_underusing);
    }

    #[test]
    fn alternating_jitter_never_overusing() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        for i in 0..500 {
            arrival += if i % 2 == 0 { 24.0 } else { 8.0 };
            ts = ts.wrapping_add(16);
            est.note(arrival, ts);
            assert_ne!(est.state(), State::Overusing);
        }
    }

    #[test]
    fn single_step_spike_does_not_latch_overuse() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        feed(&mut est, 60, &mut arrival, &mut ts, 16.0, 16);
        arrival += 46.0;
        ts = ts.wrapping_add(16);
        est.note(arrival, ts);
        feed(&mut est, WINDOW_SIZE + 5, &mut arrival, &mut ts, 16.0, 16);
        assert_eq!(est.state(), State::Normal);
        feed(&mut est, 10, &mut arrival, &mut ts, 16.0, 16);
        assert_eq!(est.state(), State::Normal);
    }

    #[test]
    fn send_ts_wrap_continuity() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = u32::MAX - 100;
        est.note(arrival, ts);
        for _ in 0..200 {
            arrival += 16.0;
            ts = ts.wrapping_add(16);
            est.note(arrival, ts);
            assert_eq!(est.state(), State::Normal);
            assert!(est.modified_trend().abs() < THRESHOLD_MIN);
        }
    }

    #[test]
    fn idle_gap_resets_window() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        feed(&mut est, 60, &mut arrival, &mut ts, 16.0, 16);
        assert!(est.num_deltas() > 0);
        arrival += 300.0;
        ts = ts.wrapping_add(300);
        est.note(arrival, ts);
        assert_eq!(est.num_deltas(), 0);
        assert_eq!(est.state(), State::Normal);
        for _ in 0..(WINDOW_SIZE - 1) {
            arrival += 21.0;
            ts = ts.wrapping_add(16);
            est.note(arrival, ts);
            assert_eq!(est.state(), State::Normal);
        }
        let mut fired = false;
        for _ in 0..25 {
            arrival += 21.0;
            ts = ts.wrapping_add(16);
            est.note(arrival, ts);
            if est.state() == State::Overusing {
                fired = true;
                break;
            }
        }
        assert!(fired);
    }

    #[test]
    fn verdict_goes_stale_across_idle_gap_without_new_arrival() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        feed(&mut est, 60, &mut arrival, &mut ts, 16.0, 16);
        feed(&mut est, 15, &mut arrival, &mut ts, 17.5, 16);
        assert_eq!(est.state(), State::Overusing);
        assert!(!est.is_stale(arrival));
        assert!(!est.is_stale(arrival + RESET_GAP_MS));
        assert!(est.is_stale(arrival + RESET_GAP_MS + 1.0));
        assert_eq!(est.state(), State::Overusing);
        assert_ne!(est.wire_trend_flags() & 0x3, 0);
        assert!(TrendlineEstimator::new().is_stale(0.0));
    }

    #[test]
    fn negative_send_delta_ignored() {
        let mut est = TrendlineEstimator::new();
        let mut arrival = 1000.0;
        let mut ts: u32 = 5000;
        est.note(arrival, ts);
        feed(&mut est, 30, &mut arrival, &mut ts, 16.0, 16);
        let before = est.clone();
        est.note(arrival + 16.0, ts.wrapping_sub(100));
        assert_eq!(est, before);
    }

    #[test]
    fn deterministic_replay_equatable() {
        fn drive(est: &mut TrendlineEstimator) {
            let mut arrival = 1000.0;
            let mut ts: u32 = 5000;
            est.note(arrival, ts);
            for i in 0..150 {
                arrival += if i % 3 == 0 { 18.5 } else { 15.0 };
                ts = ts.wrapping_add(16);
                est.note(arrival, ts);
            }
        }
        let mut a = TrendlineEstimator::new();
        let mut b = TrendlineEstimator::new();
        drive(&mut a);
        drive(&mut b);
        assert_eq!(a, b);
        assert_eq!(a.wire_trend_milli(), b.wire_trend_milli());
        assert_eq!(a.wire_trend_flags(), b.wire_trend_flags());
    }

    #[test]
    fn wire_field_clamping() {
        assert_eq!(
            TrendlineEstimator::pack_trend_milli(2_000_000.0),
            1_000_000_000_i32 as u32
        );
        assert_eq!(
            TrendlineEstimator::pack_trend_milli(-2_000_000.0),
            (-1_000_000_000_i32) as u32
        );
        assert_eq!(
            TrendlineEstimator::pack_trend_milli(12.5),
            12_500_i32 as u32
        );
        assert_eq!(
            TrendlineEstimator::pack_trend_milli(-0.5),
            (-500_i32) as u32
        );
        assert_eq!(TrendlineEstimator::pack_trend_milli(0.0), 0);
        // NaN parity with Swift's `min(1e9, max(-1e9, NaN))` = -1e9 (NaN-dropping), not clamp's
        // NaN-propagation. Unreachable through `note()`, but this is a public fn.
        assert_eq!(
            TrendlineEstimator::pack_trend_milli(f64::NAN),
            (-1_000_000_000_i32) as u32
        );
    }

    #[test]
    fn wire_flags_pack_and_report_accessors_round_trip() {
        let flags = TrendlineEstimator::pack_trend_flags(State::Overusing, 300);
        let report = NetworkStatsReport {
            owd_trend_milli: TrendlineEstimator::pack_trend_milli(-42.5),
            owd_trend_flags: flags,
            ..NetworkStatsReport::default()
        };
        assert_eq!(report.owd_trend_state_raw(), State::Overusing as u8);
        assert_eq!(report.owd_trend_deltas(), 255);
        assert_eq!(report.owd_trend_modified_milli_signed(), -42_500);
        let normal = TrendlineEstimator::pack_trend_flags(State::Underusing, 7);
        assert_eq!((normal as u8) & 0x3, State::Underusing as u8);
        assert_eq!((normal >> 8) & 0xFF, 7);
    }

    #[test]
    fn sampler_admits_first_fragment_of_each_new_frame_only() {
        let mut gate = TrendSampler::new();
        assert!(gate.should_sample(5, 100));
        assert!(!gate.should_sample(5, 100));
        assert!(!gate.should_sample(5, 100));
        assert!(gate.should_sample(6, 116));
    }

    #[test]
    fn sampler_rejects_reordered_older_frame() {
        let mut gate = TrendSampler::new();
        assert!(gate.should_sample(10, 100));
        assert!(!gate.should_sample(9, 84));
        assert!(!gate.should_sample(10, 100));
        assert!(gate.should_sample(11, 116));
    }

    #[test]
    fn sampler_never_samples_ts_zero() {
        let mut gate = TrendSampler::new();
        assert!(!gate.should_sample(1, 0));
        assert!(gate.should_sample(1, 50));
    }

    #[test]
    fn sampler_wrap_aware_frame_id_continuity() {
        let mut gate = TrendSampler::new();
        assert!(gate.should_sample(u32::MAX, 100));
        assert!(gate.should_sample(0, 116));
        assert!(!gate.should_sample(u32::MAX, 100));
    }
}
