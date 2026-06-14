//! Per-frame one-way-delay SPIKE detector — a port of Swift `OwdLateDetector` (depth v3).
//!
//! The signal the pacer's adaptive depth absorbs is NETWORK DELAY VARIATION: a frame whose one-way
//! delay spikes past the path's baseline would miss its present slot at depth 1; a standing slack
//! frame (depth 2) covers it. So "late" is measured on the wire stamp, not the present clock:
//!
//! ```text
//! owd_i  = arrival_i (client clock, ms) − send_i (host stamp, ms)   // offset-skewed, fine
//! late_i = owd_i − baseline > max(floor_ms, fraction × frame_interval)
//! ```
//!
//! The constant cross-machine clock offset cancels against the baseline. The baseline is a
//! two-bucket rolling MIN (~`2 × bucket_ms` of history): spikes can never raise it, while a genuine
//! path change re-bases within one bucket rotation. Content gaps don't matter to a min-baseline, so
//! FPS-governor / idle skips never produce false lates. Pure + deterministic — the caller injects
//! every sample.

use crate::seq::distance_wrapped;

/// Tunables for [`OwdLateDetector`]. f64 fields, so [`PartialEq`] only.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Config {
    /// Baseline bucket span (ms). Baseline = min(current bucket, previous bucket) ⇒ effective
    /// history 1–2 buckets.
    pub bucket_ms: f64,
    /// Absolute spike floor (ms) — above the self-inflicted packetize/pacing wobble band.
    pub threshold_floor_ms: f64,
    /// Interval-proportional spike component (× the content frame interval).
    pub threshold_interval_fraction: f64,
    /// Samples required before any late verdict (the baseline needs population first).
    pub warmup_samples: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bucket_ms: 2000.0,
            threshold_floor_ms: 25.0,
            threshold_interval_fraction: 1.25,
            warmup_samples: 20,
        }
    }
}

impl Config {
    /// Env-tunable construction (absent/unparsable ⇒ default), clamped to sane bands. Pure: the
    /// three raw values are passed explicitly (mirroring the [`crate::recovery_policy`] pattern).
    ///
    /// Deviation, identical to [`crate::recovery_policy::escalation_floor_seconds`]: Swift's
    /// `Double(String)` accepts hex-float notation that Rust's `parse::<f64>` rejects → the floor /
    /// fraction fall back to default for a hex-valued knob (no operator writes ms/percent in
    /// hex-float). The integer warmup parses identically in both languages.
    #[must_use]
    pub fn from_environment(
        floor_ms: Option<&str>,
        frac_pct: Option<&str>,
        warmup: Option<&str>,
    ) -> Self {
        let mut c = Self::default();
        if let Some(v) = floor_ms
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite())
        {
            c.threshold_floor_ms = v.clamp(1.0, 200.0);
        }
        if let Some(v) = frac_pct
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite())
        {
            c.threshold_interval_fraction = v.clamp(0.0, 400.0) / 100.0;
        }
        if let Some(v) = warmup.and_then(|s| s.parse::<i64>().ok()) {
            c.warmup_samples = v.clamp(1, 1000) as usize;
        }
        c
    }

    /// Resolves the config from the live process environment (`AISLOPDESK_OWD_LATE_*`).
    #[must_use]
    pub fn from_process_env() -> Self {
        Self::from_environment(
            std::env::var("AISLOPDESK_OWD_LATE_FLOOR_MS")
                .ok()
                .as_deref(),
            std::env::var("AISLOPDESK_OWD_LATE_FRAC_PCT")
                .ok()
                .as_deref(),
            std::env::var("AISLOPDESK_OWD_LATE_WARMUP").ok().as_deref(),
        )
    }
}

/// Two-bucket min-baseline one-way-delay spike detector.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OwdLateDetector {
    config: Config,
    unwrapped_send_ms: f64,
    prev_send_ts: Option<u32>,
    current_bucket_min: f64,
    previous_bucket_min: f64,
    bucket_start_arrival_ms: Option<f64>,
    samples: usize,
}

impl Default for OwdLateDetector {
    fn default() -> Self {
        Self::new(Config::default())
    }
}

impl OwdLateDetector {
    /// Builds a detector with the given config.
    #[must_use]
    pub const fn new(config: Config) -> Self {
        Self {
            config,
            unwrapped_send_ms: 0.0,
            prev_send_ts: None,
            current_bucket_min: f64::INFINITY,
            previous_bucket_min: f64::INFINITY,
            bucket_start_arrival_ms: None,
            samples: 0,
        }
    }

    /// The active config.
    #[must_use]
    pub const fn config(&self) -> Config {
        self.config
    }

    /// Folds one per-frame sample (one per strictly-newer frame id; the caller's `TrendSampler`
    /// guards reorder/kfDup/ts==0). Returns the deviation above threshold (ms) when the sample is a
    /// network-late spike, else `None`.
    pub fn note(&mut self, arrival_ms: f64, send_ts: u32, interval_ms: f64) -> Option<f64> {
        if let Some(prev) = self.prev_send_ts {
            // Wrap-aware monotone unwrap; a negative delta is tolerated as 0 forward progress.
            self.unwrapped_send_ms += f64::from(distance_wrapped(send_ts, prev).max(0));
        }
        self.prev_send_ts = Some(send_ts);
        let owd = arrival_ms - self.unwrapped_send_ms;

        // Bucket rotation on ARRIVAL time (content gaps just stretch a bucket — harmless to min).
        match self.bucket_start_arrival_ms {
            Some(start) => {
                if arrival_ms - start >= self.config.bucket_ms {
                    self.previous_bucket_min = self.current_bucket_min;
                    self.current_bucket_min = f64::INFINITY;
                    self.bucket_start_arrival_ms = Some(arrival_ms);
                }
            }
            None => self.bucket_start_arrival_ms = Some(arrival_ms),
        }

        let baseline = self
            .previous_bucket_min
            .min(self.current_bucket_min.min(owd));
        self.current_bucket_min = self.current_bucket_min.min(owd);
        self.samples += 1;
        if self.samples < self.config.warmup_samples || !baseline.is_finite() {
            return None;
        }

        let threshold = self
            .config
            .threshold_floor_ms
            .max(self.config.threshold_interval_fraction * interval_ms.max(0.0));
        let deviation = owd - baseline;
        if deviation > threshold {
            Some(deviation - threshold)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const INTERVAL: f64 = 1000.0 / 60.0;

    /// Feeds `n` clean steady samples at 60 fps, asserting none classify late. Returns the next
    /// (arrival, send) pair.
    fn warm(d: &mut OwdLateDetector, n: usize, arrival0: f64, send0: u32) -> (f64, u32) {
        let mut arrival = arrival0;
        let mut send = send0;
        for _ in 0..n {
            assert_eq!(d.note(arrival, send, INTERVAL), None);
            arrival += 16.7;
            send = send.wrapping_add(17);
        }
        (arrival, send)
    }

    fn warm_default(d: &mut OwdLateDetector) -> (f64, u32) {
        warm(d, 30, 5000.0, 91_000)
    }

    #[test]
    fn clean_steady_stream_never_late() {
        let mut d = OwdLateDetector::default();
        warm(&mut d, 200, 5000.0, 91_000);
    }

    #[test]
    fn warmup_suppresses_early_verdicts() {
        let mut d = OwdLateDetector::default();
        let mut arrival = 1000.0;
        let mut send: u32 = 50_000;
        for _ in 0..(Config::default().warmup_samples - 1) {
            assert_eq!(d.note(arrival + 500.0, send, INTERVAL), None);
            arrival += 16.7;
            send = send.wrapping_add(17);
        }
    }

    #[test]
    fn spike_past_threshold_is_late() {
        let mut d = OwdLateDetector::default();
        let (mut arrival, mut send) = warm_default(&mut d);
        arrival += 16.7 + 40.0;
        send = send.wrapping_add(17);
        let over = d.note(arrival, send, INTERVAL);
        assert!(over.is_some());
        assert!(over.unwrap() > 10.0);
    }

    #[test]
    fn pacing_wobble_band_never_late() {
        let mut d = OwdLateDetector::default();
        let (mut arrival, mut send) = warm_default(&mut d);
        for i in 0..50 {
            arrival += 16.7
                + if i % 3 == 0 {
                    18.0
                } else if i % 3 == 1 {
                    -18.0
                } else {
                    0.0
                };
            send = send.wrapping_add(17);
            assert_eq!(d.note(arrival, send, INTERVAL), None);
        }
    }

    #[test]
    fn spikes_do_not_raise_baseline() {
        let mut d = OwdLateDetector::default();
        let (mut arrival, mut send) = warm_default(&mut d);
        for _ in 0..5 {
            arrival += 16.7 + 30.0;
            send = send.wrapping_add(17);
            let _ = d.note(arrival, send, INTERVAL);
        }
        let mut verdict_at_baseline: Option<f64> = Some(f64::INFINITY);
        for _ in 0..12 {
            arrival += 1.0;
            send = send.wrapping_add(17);
            verdict_at_baseline = d.note(arrival, send, INTERVAL);
        }
        assert_eq!(verdict_at_baseline, None);
    }

    #[test]
    fn standing_queue_rebases_after_rotation() {
        let mut d = OwdLateDetector::default();
        let (mut arrival, mut send) = warm_default(&mut d);
        arrival += 16.7 + 50.0;
        send = send.wrapping_add(17);
        assert!(d.note(arrival, send, INTERVAL).is_some());
        for _ in 0..260 {
            arrival += 16.7;
            send = send.wrapping_add(17);
            let _ = d.note(arrival, send, INTERVAL);
        }
        arrival += 16.7;
        send = send.wrapping_add(17);
        assert_eq!(d.note(arrival, send, INTERVAL), None);
    }

    #[test]
    fn content_gaps_harmless() {
        let mut d = OwdLateDetector::default();
        let (mut arrival, mut send) = warm_default(&mut d);
        arrival += 2000.0;
        send = send.wrapping_add(2000);
        assert_eq!(d.note(arrival, send, INTERVAL), None);
        for _ in 0..10 {
            arrival += 16.7;
            send = send.wrapping_add(17);
            assert_eq!(d.note(arrival, send, INTERVAL), None);
        }
    }

    #[test]
    fn send_stamp_wrap_is_continuous() {
        let mut d = OwdLateDetector::default();
        let (mut arrival, mut send) = warm(&mut d, 30, 5000.0, u32::MAX - 200);
        for _ in 0..30 {
            arrival += 16.7;
            send = send.wrapping_add(17);
            assert_eq!(d.note(arrival, send, INTERVAL), None);
        }
    }

    #[test]
    fn threshold_scales_with_interval() {
        let mut d = OwdLateDetector::default();
        let mut arrival = 5000.0;
        let mut send: u32 = 91_000;
        let slow = 1000.0 / 15.0;
        for _ in 0..30 {
            assert_eq!(d.note(arrival, send, slow), None);
            arrival += 66.7;
            send = send.wrapping_add(67);
        }
        arrival += 66.7 + 30.0;
        send = send.wrapping_add(67);
        assert_eq!(d.note(arrival, send, slow), None);
    }

    #[test]
    fn env_config_clamps() {
        let c = Config::from_environment(Some("0.2"), Some("9999"), Some("0"));
        assert_eq!(c.threshold_floor_ms, 1.0);
        assert_eq!(c.threshold_interval_fraction, 4.0);
        assert_eq!(c.warmup_samples, 1);
        let d = Config::from_environment(None, None, None);
        assert_eq!(d, Config::default());
    }
}
