//! The host's fold of the client's periodic network report into the few numbers the congestion
//! controller actually keys on.
//!
//! Everything here is clock-skew-free: the round trip is measured against the host's OWN stamp
//! echoed back by the client, so the two machines never have to agree on a wall clock.

/// The folded estimate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NetworkEstimate {
    /// The smoothed round trip in milliseconds. Zero until the first valid sample folds.
    pub smoothed_rtt_millis: f64,
    /// The windowed minimum round trip — the path's no-queue baseline. Infinite until the first
    /// sample.
    pub min_rtt_millis: f64,
    /// The smoothed loss rate, for logging and trend only. The controller does NOT key its decrease
    /// on this; see [`Self::last_loss_sample`].
    pub loss_rate: f64,
    /// The RAW per-report loss fraction from the most recent fold.
    ///
    /// Unlike the smoothed rate this is the INSTANTANEOUS sample, so a clean report reads zero even
    /// while the tail of a prior spike is still decaying above the threshold. The controller keys
    /// its multiplicative decrease on this, so one transient spike costs exactly ONE decrease
    /// rather than a cascade driven by a slowly-decaying average re-tripping on clean reports.
    pub last_loss_sample: f64,
    /// Whether the most recent one-way-delay jitter sample rose against the previous one.
    ///
    /// A congestion-onset HINT and nothing more: it compares two adjacent samples, so on a steady
    /// link it flaps about evenly. The controller deliberately does not consult it.
    pub owd_gradient_rising: bool,
    /// The client's trendline detector read OVERUSING on the most recent report — monotone delay
    /// growth over a full regression window, sustained past its adaptive threshold. THIS, not the
    /// two-sample hint, is the gradient signal the early-cut path consumes.
    pub owd_trend_overusing: bool,
    /// The detector's modified trend from the most recent report, for diagnostics only.
    pub owd_trend_modified: f64,
    /// The RAW round-trip sample of the most recent fold — the gradient cut's fresh LEVEL
    /// corroboration, with no smoothing lag and no streak. Explicitly `None` when that report's
    /// sample was rejected, because corroboration may only use THIS report's evidence.
    pub last_rtt_sample_millis: Option<f64>,
    /// The last folded jitter sample, for the rising-trend comparison.
    ///
    /// Public for the same reason the rest of this struct is: the estimate is a VALUE its owner
    /// copies, and an owner on the far side of a boundary carries every field or the next fold
    /// disagrees with the last one. Nothing reads this but [`Self::fold`].
    pub last_owd_jitter_micros: u32,
    /// How many reports have folded, so the gradient warms up rather than spiking on the first.
    ///
    /// Public for the reason above, and read by nothing but [`Self::fold`]. Two folds is the whole
    /// warmup: the first sample has no predecessor to rise against.
    pub sample_count: u32,
}

impl Default for NetworkEstimate {
    fn default() -> Self {
        Self::new()
    }
}

impl NetworkEstimate {
    /// The weight on a fresh round-trip sample — seven eighths history, in the classic style.
    pub const RTT_ALPHA: f64 = 0.125;
    /// The weight on a fresh loss sample.
    pub const LOSS_ALPHA: f64 = 0.125;
    /// The slow re-baseline factor for the minimum, so a transient low sample does not pin the
    /// baseline below the real path round trip forever.
    pub const MIN_RTT_DECAY: f64 = 0.01;
    /// Samples above this many milliseconds are implausible, and are dropped rather than allowed to
    /// poison the average.
    pub const MAX_PLAUSIBLE_RTT_MILLIS: i64 = 60_000;

    /// A fresh estimate: nothing smoothed, no baseline.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            smoothed_rtt_millis: 0.0,
            min_rtt_millis: f64::INFINITY,
            loss_rate: 0.0,
            last_loss_sample: 0.0,
            owd_gradient_rising: false,
            owd_trend_overusing: false,
            owd_trend_modified: 0.0,
            last_rtt_sample_millis: None,
            last_owd_jitter_micros: 0,
            sample_count: 0,
        }
    }

    /// The wrap-safe host-clock round trip in milliseconds, or `None` to REJECT the sample.
    ///
    /// Total over all inputs — the wrapping subtraction cannot trap. It rejects when telemetry is
    /// off, when the stamp is in the FUTURE (a stale stamp from a prior session after the actor was
    /// re-created), when the client's hold exceeds the elapsed time, and when the result is
    /// implausibly large.
    #[must_use]
    pub const fn compute_rtt_millis(
        host_now_ms: u32,
        latest_host_send_ts: u32,
        client_hold_ms: u32,
    ) -> Option<i64> {
        if latest_host_send_ts == 0 {
            return None;
        }
        // Wrap-aware, the same trick the reassembler's frame-id distance uses: a counter that
        // wrapped between the stamp and now still yields the correct small positive elapsed.
        let elapsed = host_now_ms.wrapping_sub(latest_host_send_ts).cast_signed() as i64;
        if elapsed < 0 {
            return None;
        }
        let rtt = elapsed - client_hold_ms as i64;
        if rtt < 0 || rtt > Self::MAX_PLAUSIBLE_RTT_MILLIS {
            return None;
        }
        Some(rtt)
    }

    /// Folds one report.
    ///
    /// A rejected round trip skips the round-trip and baseline update but still folds loss and
    /// jitter, so disabling the timing loop never blinds the rest of the estimate.
    pub fn fold(
        &mut self,
        rtt_millis: Option<i64>,
        frames_received: u32,
        unrecovered: u32,
        owd_jitter_micros: u32,
        owd_trend_state: u8,
        owd_trend_modified_milli: i32,
    ) {
        // The freshness contract the gradient cut relies on: this is per-fold, and None on reject.
        #[expect(
            clippy::cast_precision_loss,
            reason = "a round trip bounded by MAX_PLAUSIBLE_RTT_MILLIS is exact in f64"
        )]
        let sample = rtt_millis.map(|rtt| rtt as f64);
        self.last_rtt_sample_millis = sample;
        self.owd_trend_overusing = owd_trend_state == 1;
        self.owd_trend_modified = f64::from(owd_trend_modified_milli) / 1000.0;
        if let Some(sample) = sample {
            // Separate multiplies and one add, never fused.
            self.smoothed_rtt_millis = if self.smoothed_rtt_millis == 0.0 {
                sample
            } else {
                let history = self.smoothed_rtt_millis * (1.0 - Self::RTT_ALPHA);
                let fresh = sample * Self::RTT_ALPHA;
                history + fresh
            };
            if sample < self.min_rtt_millis {
                self.min_rtt_millis = sample;
            } else if self.min_rtt_millis.is_finite() {
                // Re-baseline slowly, so a one-off low cannot pin the baseline under the real path.
                let gap = (sample - self.min_rtt_millis) * Self::MIN_RTT_DECAY;
                self.min_rtt_millis += gap;
            }
        }
        // A report that received no frames contributes a zero sample rather than dividing by zero.
        let loss_sample = if frames_received > 0 {
            f64::from(unrecovered) / f64::from(frames_received)
        } else {
            0.0
        };
        self.last_loss_sample = loss_sample;
        let history = self.loss_rate * (1.0 - Self::LOSS_ALPHA);
        let fresh = loss_sample * Self::LOSS_ALPHA;
        self.loss_rate = history + fresh;
        // The gradient hint is only meaningful past a short warmup: the first sample has no
        // predecessor to rise against.
        if self.sample_count >= 2 {
            self.owd_gradient_rising = owd_jitter_micros > self.last_owd_jitter_micros;
        }
        self.last_owd_jitter_micros = owd_jitter_micros;
        self.sample_count = self.sample_count.saturating_add(1);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fold assertions are on values the law pins exactly — a first sample adopted verbatim, \
                  a zero-frame report's zero — which is the property under test"
    )]

    use super::NetworkEstimate;

    #[test]
    fn a_stamp_that_wrapped_still_measures_a_small_positive_round_trip() {
        // The host counter wrapped between the stamp and now.
        assert_eq!(NetworkEstimate::compute_rtt_millis(4, u32::MAX - 5, 0), Some(10));
    }

    #[test]
    fn an_implausible_or_impossible_sample_is_rejected_rather_than_folded() {
        assert_eq!(
            NetworkEstimate::compute_rtt_millis(100, 0, 0),
            None,
            "telemetry off"
        );
        assert_eq!(
            NetworkEstimate::compute_rtt_millis(100, 200, 0),
            None,
            "a stamp from the future is a stale prior session",
        );
        assert_eq!(
            NetworkEstimate::compute_rtt_millis(100, 50, 80),
            None,
            "the client held it longer than the whole elapsed time",
        );
        assert_eq!(
            NetworkEstimate::compute_rtt_millis(100_000, 1, 0),
            None,
            "implausible"
        );
        assert_eq!(NetworkEstimate::compute_rtt_millis(150, 50, 20), Some(80));
    }

    #[test]
    fn the_first_sample_is_adopted_rather_than_smoothed_against_zero() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(Some(40), 10, 0, 0, 0, 0);
        assert_eq!(estimate.smoothed_rtt_millis, 40.0);
        assert_eq!(estimate.min_rtt_millis, 40.0);
    }

    #[test]
    fn the_baseline_drops_at_once_but_re_baselines_slowly() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(Some(40), 10, 0, 0, 0, 0);
        estimate.fold(Some(10), 10, 0, 0, 0, 0);
        assert_eq!(
            estimate.min_rtt_millis, 10.0,
            "a lower sample IS the new baseline"
        );
        estimate.fold(Some(110), 10, 0, 0, 0, 0);
        assert!(
            (estimate.min_rtt_millis - 11.0).abs() < 1e-9,
            "one percent of the gap, not the sample: {}",
            estimate.min_rtt_millis,
        );
    }

    /// The distinction the controller's whole anti-cascade design rests on.
    #[test]
    fn the_raw_sample_reads_clean_while_the_smoothed_rate_is_still_decaying() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(Some(20), 3, 3, 0, 0, 0); // a total-loss report
        assert_eq!(estimate.last_loss_sample, 1.0);
        estimate.fold(Some(20), 3, 0, 0, 0, 0); // and a perfectly clean one
        assert_eq!(estimate.last_loss_sample, 0.0, "the raw sample forgets at once");
        assert!(estimate.loss_rate > 0.1, "while the average still remembers");
    }

    #[test]
    fn a_report_with_no_frames_contributes_a_zero_sample() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(None, 0, 0, 0, 0, 0);
        assert_eq!(estimate.last_loss_sample, 0.0);
        assert_eq!(estimate.loss_rate, 0.0);
    }

    #[test]
    fn a_rejected_round_trip_still_folds_loss() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(None, 10, 5, 0, 0, 0);
        assert_eq!(estimate.last_rtt_sample_millis, None);
        assert_eq!(estimate.smoothed_rtt_millis, 0.0);
        assert!(estimate.min_rtt_millis.is_infinite());
        assert_eq!(estimate.last_loss_sample, 0.5);
    }

    #[test]
    fn the_jitter_hint_warms_up_before_it_reads_anything() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(Some(20), 10, 0, 100, 0, 0);
        estimate.fold(Some(20), 10, 0, 900, 0, 0);
        assert!(!estimate.owd_gradient_rising, "the first pair has no history yet");
        estimate.fold(Some(20), 10, 0, 5_000, 0, 0);
        assert!(estimate.owd_gradient_rising);
        estimate.fold(Some(20), 10, 0, 10, 0, 0);
        assert!(!estimate.owd_gradient_rising);
    }

    #[test]
    fn the_trend_verdict_is_carried_per_report() {
        let mut estimate = NetworkEstimate::new();
        estimate.fold(Some(20), 10, 0, 0, 1, 2_500);
        assert!(estimate.owd_trend_overusing);
        assert!((estimate.owd_trend_modified - 2.5).abs() < 1e-9);
        estimate.fold(Some(20), 10, 0, 0, 0, 0);
        assert!(!estimate.owd_trend_overusing, "a stale verdict must not persist");
    }
}
