//! Adaptive pacer-depth policy (v3) — a port of Swift `PacerDepthPolicy`.
//!
//! Pays one frame of presentation slack (depth 1 → 2) only AFTER observed NETWORK-late events
//! (one-way-delay spikes from [`OwdLateDetector`](crate::owd_late_detector), fed via
//! [`note_network_late`](PacerDepthPolicy::note_network_late)), and refunds it after a clean dwell.
//! The present-gap machinery ([`note_present`](PacerDepthPolicy::note_present) /
//! [`note_reshow`](PacerDepthPolicy::note_reshow)) is KEPT as pure telemetry (the v2 present-gap
//! classifier conflated network lateness with content cadence and pinned the depth). Pure + headless
//! — all time is injected as client-monotonic seconds.
//!
//! Tunables: the Swift source resolves `AISLOPDESK_DEPTH_*` env vars at startup; the portable core
//! uses the compile-time defaults (identical when unset), and [`Config::from_environment`] applies
//! the same clamps to a caller-supplied map.

use std::collections::HashMap;

/// One windowed drain of the pacer's presentation-health counters (carried client→host).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacerTelemetrySnapshot {
    /// Windowed NETWORK-late events (owd spikes past baseline — the depth-promotion input).
    pub late_frames: u32,
    /// Windowed late-gap EPISODES opened (a superset of `late_frames`).
    pub present_gaps: u32,
    /// Gauge: the live presentation depth (0 = no pacer attached).
    pub depth: u32,
}

/// Tunables for [`PacerDepthPolicy`]. f64 fields, so [`PartialEq`] only.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Config {
    /// late iff gap > max(`absolute_late_floor_seconds`, `late_gap_factor` × expected interval).
    pub late_gap_factor: f64,
    /// The HW-validated KHỰNG threshold floor (seconds).
    pub absolute_late_floor_seconds: f64,
    /// A gap above this is IDLE (host idle-skip / motion stop), never late.
    pub idle_gap_seconds: f64,
    /// Late additionally requires gap ≥ this × the previous in-flow present gap.
    pub gap_gradient_factor: f64,
    /// Dense flow = ≥ this many arrivals within `dense_window_seconds` before the gap opened.
    pub dense_min_arrivals: usize,
    /// The dense-flow lookback window (seconds).
    pub dense_window_seconds: f64,
    /// Extra late-boundary margin, as a fraction of the expected interval.
    pub late_slack_fraction: f64,
    /// Promote on this many late events within `promote_window_seconds`.
    pub promote_late_count: usize,
    /// The promote pairing window (seconds).
    pub promote_window_seconds: f64,
    /// Demote after this long with at most `demote_tolerance_lates` late events in the window…
    pub demote_clean_seconds: f64,
    /// …but never sooner than this after a promotion (anti-flap).
    pub min_hold_seconds: f64,
    /// Demote tolerance: late events allowed inside the trailing dwell (0 = strict).
    pub demote_tolerance_lates: usize,
    /// Promote decisions are ignored for this long after the first arrival (cold-start guard).
    pub promote_warmup_seconds: f64,
    /// The boosted depth (1 ↔ 2 only).
    pub boost_depth: i64,
    /// Expected-interval = median of the last N in-flow inter-arrival gaps.
    pub interval_ring_size: usize,
    /// Minimum ring samples before the estimator is used.
    pub min_samples_for_estimate: usize,
    /// The expected interval before the estimator warms (seconds).
    pub default_interval_seconds: f64,
    /// Expected-interval floor (seconds).
    pub min_interval_seconds: f64,
    /// Expected-interval ceiling (seconds).
    pub max_interval_seconds: f64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            late_gap_factor: 1.6,
            absolute_late_floor_seconds: 0.028,
            idle_gap_seconds: 0.25,
            gap_gradient_factor: 1.45,
            dense_min_arrivals: 8,
            dense_window_seconds: 0.35,
            late_slack_fraction: 0.25,
            promote_late_count: 2,
            promote_window_seconds: 1.0,
            demote_clean_seconds: 2.5,
            min_hold_seconds: 1.0,
            demote_tolerance_lates: 1,
            promote_warmup_seconds: 2.0,
            boost_depth: 2,
            interval_ring_size: 15,
            min_samples_for_estimate: 5,
            default_interval_seconds: 1.0 / 60.0,
            min_interval_seconds: 1.0 / 240.0,
            max_interval_seconds: 1.0 / 10.0,
        }
    }
}

impl Config {
    /// Env-tunable construction, each value clamped to a sane band; absent / unparsable values keep
    /// the default. Pure: the caller supplies the `AISLOPDESK_DEPTH_*` map.
    ///
    /// Deviation (same as the other env helpers): Swift's `Double(String)` accepts hex-float; Rust's
    /// `parse::<f64>` rejects it → that knob keeps its default. Decimal values parse identically.
    #[must_use]
    pub fn from_environment(env: &HashMap<&str, &str>) -> Self {
        let mut c = Self::default();
        let int = |k: &str| env.get(k).and_then(|s| s.parse::<i64>().ok());
        let dbl = |k: &str| {
            env.get(k)
                .and_then(|s| s.parse::<f64>().ok())
                .filter(|v| v.is_finite())
        };
        if let Some(v) = int("AISLOPDESK_DEPTH_PROMOTE_LATES") {
            c.promote_late_count = v.clamp(1, 4) as usize;
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS") {
            c.promote_window_seconds = (v / 1000.0).clamp(0.1, 10.0);
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_DEMOTE_MS") {
            c.demote_clean_seconds = (v / 1000.0).clamp(0.5, 30.0);
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_MINHOLD_MS") {
            c.min_hold_seconds = (v / 1000.0).clamp(0.0, 10.0);
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_LATE_FACTOR") {
            c.late_gap_factor = v.clamp(1.1, 4.0);
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_IDLE_MS") {
            c.idle_gap_seconds = (v / 1000.0).clamp(0.1, 2.0);
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_LATE_SLACK_PCT") {
            c.late_slack_fraction = v.clamp(0.0, 100.0) / 100.0;
        }
        if let Some(v) = int("AISLOPDESK_DEPTH_DEMOTE_TOLERANCE") {
            c.demote_tolerance_lates = v.clamp(0, 3) as usize;
        }
        if let Some(v) = dbl("AISLOPDESK_DEPTH_WARMUP_MS") {
            c.promote_warmup_seconds = (v / 1000.0).clamp(0.0, 30.0);
        }
        c
    }
}

/// Classification of one content-present gap (telemetry / diagnostics).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GapClass {
    /// The first present (no predecessor gap).
    First,
    /// An ordinary in-flow gap.
    Normal,
    /// A gap past the late boundary, dense, with a sharp gradient step.
    Late,
    /// A gap past the idle cap (host idle-skip / motion stop).
    Idle,
}

/// Late/idle/dense gap classifier (telemetry) + promote/demote depth policy (driven by NETWORK-late
/// events). `PartialEq` (f64 / `Vec` fields).
#[derive(Debug, Clone, PartialEq)]
pub struct PacerDepthPolicy {
    depth: i64,
    config: Config,
    adapt_enabled: bool,
    last_arrival: Option<f64>,
    arrival_ring: Vec<f64>,
    interval_ring: Vec<f64>,
    interval_hint: Option<f64>,
    last_present_at: Option<f64>,
    prev_present_gap: Option<f64>,
    late_times: Vec<f64>,
    promoted_at: f64,
    stream_start_at: Option<f64>,
    gap_episode_open: bool,
    late_count: u32,
    gap_count: u32,
}

impl PacerDepthPolicy {
    /// Builds a policy. `adapt_enabled = false` runs the counters (telemetry) but never moves depth.
    #[must_use]
    pub const fn new(config: Config, adapt_enabled: bool) -> Self {
        Self {
            depth: 1,
            config,
            adapt_enabled,
            last_arrival: None,
            arrival_ring: Vec::new(),
            interval_ring: Vec::new(),
            interval_hint: None,
            last_present_at: None,
            prev_present_gap: None,
            late_times: Vec::new(),
            promoted_at: -1e30,
            stream_start_at: None,
            gap_episode_open: false,
            late_count: 0,
            gap_count: 0,
        }
    }

    /// The recommended presentation depth (1 or `boost_depth`).
    #[must_use]
    pub const fn depth(&self) -> i64 {
        self.depth
    }

    /// The active config.
    #[must_use]
    pub const fn config(&self) -> Config {
        self.config
    }

    /// The expected content interval: the hint (if set), else the median of the in-flow ring (once
    /// warmed), else the default — clamped to a sane band.
    #[must_use]
    pub fn expected_interval_seconds(&self) -> f64 {
        let raw = self.interval_hint.unwrap_or_else(|| {
            if self.interval_ring.len() >= self.config.min_samples_for_estimate {
                Self::median(&self.interval_ring)
            } else {
                self.config.default_interval_seconds
            }
        });
        raw.clamp(
            self.config.min_interval_seconds,
            self.config.max_interval_seconds,
        )
    }

    /// The late boundary: `max(abs_floor, factor × expected) + slack_fraction × expected`.
    #[must_use]
    pub fn late_threshold_seconds(&self) -> f64 {
        let expected = self.expected_interval_seconds();
        self.config
            .absolute_late_floor_seconds
            .max(self.config.late_gap_factor * expected)
            + self.config.late_slack_fraction * expected
    }

    /// Folds one decoded-frame SUBMIT. Also evaluates demote so a post-idle resume demotes before
    /// the pacer re-primes.
    pub fn note_arrival(&mut self, now: f64) {
        if self.stream_start_at.is_none() {
            self.stream_start_at = Some(now);
        }
        if let Some(last) = self.last_arrival {
            let gap = now - last;
            if gap > 0.0 && gap <= self.config.idle_gap_seconds {
                self.interval_ring.push(gap);
                if self.interval_ring.len() > self.config.interval_ring_size {
                    let excess = self.interval_ring.len() - self.config.interval_ring_size;
                    self.interval_ring.drain(0..excess);
                }
            }
        }
        self.arrival_ring.push(now);
        if self.arrival_ring.len() > 16 {
            let excess = self.arrival_ring.len() - 16;
            self.arrival_ring.drain(0..excess);
        }
        self.last_arrival = Some(now);
        self.evaluate_demote(now);
    }

    /// Folds one CONTENT present and classifies its gap. Late requires the gap past the boundary,
    /// dense flow when it opened, and a sharp step from the previous in-flow gap.
    pub fn note_present(&mut self, now: f64) -> GapClass {
        let Some(last) = self.last_present_at else {
            self.last_present_at = Some(now);
            return GapClass::First;
        };
        let gap = now - last;
        if gap > self.config.idle_gap_seconds {
            self.gap_episode_open = false;
            self.prev_present_gap = None;
            self.last_present_at = Some(now);
            self.evaluate_demote(now);
            return GapClass::Idle;
        }
        let gradient_ok = self
            .prev_present_gap
            .is_none_or(|p| gap >= self.config.gap_gradient_factor * p);
        // v3: classification only — a present-gap late no longer counts or promotes.
        let is_late = gap > self.late_threshold_seconds() && gradient_ok && self.was_dense(last);
        self.gap_episode_open = false; // any present closes an open re-show episode
        self.prev_present_gap = Some(gap);
        self.last_present_at = Some(now);
        self.evaluate_demote(now);
        if is_late {
            GapClass::Late
        } else {
            GapClass::Normal
        }
    }

    /// Folds one NETWORK-late event (an `OwdLateDetector` spike): THE promotion input and the demote
    /// dwell's content. Counted into the windowed `late_frames` telemetry too.
    pub fn note_network_late(&mut self, now: f64) {
        self.late_count = self.late_count.saturating_add(1);
        self.late_times.push(now);
        if self.late_times.len() > 4 {
            let excess = self.late_times.len() - 4;
            self.late_times.drain(0..excess);
        }
        self.evaluate_promote(now);
    }

    /// Folds one empty-queue re-show tick. Counts a late-gap EPISODE (once) when the open gap crosses
    /// the late boundary. Promotion never uses this counter.
    pub fn note_reshow(&mut self, now: f64) {
        let Some(last) = self.last_present_at else {
            return;
        };
        if self.gap_episode_open {
            return;
        }
        let open_gap = now - last;
        if open_gap > self.late_threshold_seconds()
            && open_gap <= self.config.idle_gap_seconds
            && self.was_dense(last)
        {
            self.gap_count = self.gap_count.saturating_add(1);
            self.gap_episode_open = true;
        }
    }

    /// Reads + resets the windowed counters (one drain per `NetworkStats` report).
    pub const fn drain_counters(&mut self) -> (u32, u32) {
        let out = (self.late_count, self.gap_count);
        self.late_count = 0;
        self.gap_count = 0;
        out
    }

    /// FPS-governor seam: pins the expected interval. `None` / non-finite / non-positive returns to
    /// the estimator.
    pub fn set_interval_hint(&mut self, seconds: Option<f64>) {
        self.interval_hint = match seconds {
            Some(s) if s.is_finite() && s > 0.0 => Some(s),
            _ => None,
        };
    }

    /// Dense-flow gate: ≥ `dense_min_arrivals` arrivals in the `dense_window_seconds` before `t`.
    fn was_dense(&self, t: f64) -> bool {
        let window_start = t - self.config.dense_window_seconds;
        let n = self
            .arrival_ring
            .iter()
            .filter(|&&a| a > window_start && a <= t)
            .count();
        n >= self.config.dense_min_arrivals
    }

    fn evaluate_promote(&mut self, now: f64) {
        if !self.adapt_enabled || self.depth != 1 {
            return;
        }
        let Some(start) = self.stream_start_at else {
            return;
        };
        if now - start < self.config.promote_warmup_seconds {
            return;
        }
        let window_start = now - self.config.promote_window_seconds;
        let recent = self
            .late_times
            .iter()
            .filter(|&&t| t >= window_start && t <= now)
            .count();
        if recent >= self.config.promote_late_count {
            self.depth = self.config.boost_depth.max(2);
            self.promoted_at = now;
        }
    }

    fn evaluate_demote(&mut self, now: f64) {
        if self.depth <= 1 {
            return;
        }
        if now - self.promoted_at < self.config.min_hold_seconds {
            return;
        }
        let window_start = now - self.config.demote_clean_seconds;
        let recent = self
            .late_times
            .iter()
            .filter(|&&t| t > window_start && t <= now)
            .count();
        if recent <= self.config.demote_tolerance_lates {
            self.depth = 1;
        }
    }

    /// Median of a small array (ring ≤ 15 entries).
    fn median(values: &[f64]) -> f64 {
        let mut sorted = values.to_vec();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        sorted[sorted.len() / 2]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drive_clean(
        dp: &mut PacerDepthPolicy,
        from: f64,
        frames: i32,
        fps: f64,
        reshows: bool,
    ) -> f64 {
        let mut t = from;
        let mut last_present = t;
        for _ in 0..frames {
            t += 1.0 / fps;
            if reshows {
                let mut tick = last_present + 1.0 / 120.0;
                while tick < t {
                    dp.note_reshow(tick);
                    tick += 1.0 / 120.0;
                }
            }
            dp.note_arrival(t);
            dp.note_present(t);
            last_present = t;
        }
        t
    }

    fn drive(dp: &mut PacerDepthPolicy, from: f64, frames: i32) -> f64 {
        drive_clean(dp, from, frames, 60.0, true)
    }

    fn skip_one_slot(dp: &mut PacerDepthPolicy, from: f64) -> (f64, GapClass) {
        let t2 = from + 2.0 / 60.0;
        dp.note_arrival(t2);
        (t2, dp.note_present(t2))
    }

    #[test]
    fn clean_steady_60fps_never_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let _ = drive(&mut dp, 0.0, 600);
        let win = dp.drain_counters();
        assert_eq!(win, (0, 0));
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn tick_quantization_alternation_never_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut arrival = 0.0;
        let mut present = 0.0;
        for i in 0..240 {
            arrival += 1.0 / 60.0;
            dp.note_arrival(arrival);
            present += if i % 2 == 0 { 1.0 / 120.0 } else { 0.025 };
            assert_ne!(dp.note_present(present), GapClass::Late);
        }
        assert_eq!(dp.drain_counters().0, 0);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn present_gap_late_classifies_but_never_counts_nor_promotes() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 130);
        for _ in 0..6 {
            let r = skip_one_slot(&mut dp, t);
            assert_eq!(r.1, GapClass::Late);
            t = drive(&mut dp, r.0, 20);
        }
        assert_eq!(dp.drain_counters().0, 0);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn sub_cadence_content_cannot_pin_depth() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 130);
        dp.note_network_late(t);
        dp.note_network_late(t + 0.2);
        assert_eq!(dp.depth(), 2);
        dp.set_interval_hint(Some(1.0 / 60.0));
        for _ in 0..250 {
            t += 0.040;
            dp.note_arrival(t);
            dp.note_present(t);
        }
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn single_network_late_never_promotes() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let t = drive(&mut dp, 0.0, 130);
        dp.note_network_late(t);
        assert_eq!(dp.depth(), 1);
        assert_eq!(dp.drain_counters().0, 1);
    }

    #[test]
    fn two_network_lates_within_window_promote() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let t = drive(&mut dp, 0.0, 130);
        dp.note_network_late(t);
        dp.note_network_late(t + 0.6);
        assert_eq!(dp.depth(), 2);
    }

    #[test]
    fn two_network_lates_outside_window_no_promote() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 130);
        dp.note_network_late(t);
        t = drive(&mut dp, t, 72);
        dp.note_network_late(t);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn burst_promotes_within_budget() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 180);
        let onset = t;
        let mut promoted_at: Option<f64> = None;
        for i in 0..600 {
            t += 1.0 / 60.0;
            dp.note_arrival(t);
            dp.note_present(t);
            if i % 20 == 0 {
                dp.note_network_late(t);
            }
            if dp.depth() == 2 && promoted_at.is_none() {
                promoted_at = Some(t);
            }
        }
        let promoted_at = promoted_at.expect("never promoted");
        assert!(promoted_at - onset <= 1.5);
    }

    #[test]
    fn burst_holds_depth_throughout() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 130);
        let mut promoted = false;
        let mut held = true;
        for k in 0..20 {
            t = drive(&mut dp, t, if k % 2 == 0 { 20 } else { 38 });
            dp.note_network_late(t);
            if dp.depth() == 2 {
                promoted = true;
            }
            if promoted && dp.depth() != 2 {
                held = false;
            }
        }
        assert!(promoted);
        assert!(held);
        assert_eq!(dp.depth(), 2);
    }

    #[test]
    fn demote_after_clean_dwell_respects_min_hold() {
        let strict = Config {
            demote_tolerance_lates: 0,
            ..Config::default()
        };
        let mut dp = PacerDepthPolicy::new(strict, true);
        let mut t = drive(&mut dp, 0.0, 130);
        dp.note_network_late(t);
        t = drive(&mut dp, t, 30);
        dp.note_network_late(t);
        assert_eq!(dp.depth(), 2);
        let last_late = t;
        let mut demoted_at: Option<f64> = None;
        for _ in 0..300 {
            t += 1.0 / 60.0;
            dp.note_arrival(t);
            dp.note_present(t);
            if dp.depth() == 1 && demoted_at.is_none() {
                demoted_at = Some(t);
            }
        }
        let demoted_at = demoted_at.expect("never demoted");
        assert!(demoted_at - last_late >= 2.5);
        assert!(demoted_at - last_late <= 2.5 + 2.0 / 60.0);

        let cfg = Config {
            demote_clean_seconds: 0.5,
            min_hold_seconds: 1.5,
            demote_tolerance_lates: 0,
            ..Config::default()
        };
        let mut dph = PacerDepthPolicy::new(cfg, true);
        let mut th = drive(&mut dph, 0.0, 130);
        dph.note_network_late(th);
        th = drive(&mut dph, th, 30);
        dph.note_network_late(th);
        assert_eq!(dph.depth(), 2);
        let promoted_at = th;
        let mut demoted_at_h: Option<f64> = None;
        for _ in 0..240 {
            th += 1.0 / 60.0;
            dph.note_arrival(th);
            dph.note_present(th);
            if dph.depth() == 1 && demoted_at_h.is_none() {
                demoted_at_h = Some(th);
            }
        }
        let demoted_at_h = demoted_at_h.expect("min-hold arm never demoted");
        assert!(demoted_at_h - promoted_at >= 1.5);
        assert!(demoted_at_h - promoted_at <= 1.5 + 2.0 / 60.0);
    }

    fn demote_time_with_one_mid_dwell_late(tolerance: usize) -> (Option<f64>, f64) {
        let cfg = Config {
            demote_tolerance_lates: tolerance,
            ..Config::default()
        };
        let mut dp = PacerDepthPolicy::new(cfg, true);
        let mut t = drive(&mut dp, 0.0, 150);
        dp.note_network_late(t);
        t = drive(&mut dp, t, 20);
        dp.note_network_late(t);
        assert_eq!(dp.depth(), 2);
        t = drive(&mut dp, t, 72);
        dp.note_network_late(t);
        let late_at = t;
        let mut demoted_at: Option<f64> = None;
        for _ in 0..360 {
            t += 1.0 / 60.0;
            dp.note_arrival(t);
            dp.note_present(t);
            if dp.depth() == 1 && demoted_at.is_none() {
                demoted_at = Some(t);
            }
        }
        (demoted_at, late_at)
    }

    #[test]
    fn demote_tolerates_one_late_in_window() {
        let (demoted, late_at) = demote_time_with_one_mid_dwell_late(1);
        let demoted = demoted.expect("tolerance 1 never demoted");
        assert!(demoted - late_at < 2.5);
        let (strict_demoted, strict_late) = demote_time_with_one_mid_dwell_late(0);
        let strict_demoted = strict_demoted.expect("tolerance 0 never demoted");
        assert!(strict_demoted - strict_late >= 2.5);
    }

    #[test]
    fn warmup_suppresses_early_promote() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 60);
        dp.note_network_late(t);
        dp.note_network_late(t + 0.3);
        assert_eq!(dp.depth(), 1);
        assert_eq!(dp.drain_counters().0, 2);
        t = drive(&mut dp, t, 90);
        dp.note_network_late(t);
        dp.note_network_late(t + 0.3);
        assert_eq!(dp.depth(), 2);
    }

    #[test]
    fn warmup_zero_promotes_immediately() {
        let cfg = Config {
            promote_warmup_seconds: 0.0,
            ..Config::default()
        };
        let mut dp = PacerDepthPolicy::new(cfg, true);
        let t = drive(&mut dp, 0.0, 60);
        dp.note_network_late(t);
        dp.note_network_late(t + 0.3);
        assert_eq!(dp.depth(), 2);
    }

    #[test]
    fn idle_gaps_classify_idle_not_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 60);
        for _ in 0..10 {
            t += 0.300;
            dp.note_arrival(t);
            assert_eq!(dp.note_present(t), GapClass::Idle);
        }
        assert_eq!(dp.drain_counters().0, 0);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn typing_sparse_never_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = 0.0;
        for i in 0..40 {
            t += 0.150 + f64::from(i % 8) * 0.010;
            dp.note_arrival(t);
            assert_ne!(dp.note_present(t), GapClass::Late);
        }
        assert_eq!(dp.drain_counters().0, 0);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn dense_flow_jitter_within_slack_never_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 150);
        for i in 0..600 {
            t += if i % 60 == 0 { 0.030 } else { 1.0 / 60.0 };
            dp.note_arrival(t);
            assert_ne!(dp.note_present(t), GapClass::Late);
        }
        assert_eq!(dp.drain_counters().0, 0);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn fps_downshift_no_false_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 120);
        let mut lates = 0;
        for _ in 0..150 {
            t += 1.0 / 30.0;
            dp.note_arrival(t);
            if dp.note_present(t) == GapClass::Late {
                lates += 1;
            }
            assert_eq!(dp.depth(), 1);
        }
        assert!(lates <= 1);
    }

    #[test]
    fn interval_hint_overrides_estimator() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let mut t = drive(&mut dp, 0.0, 120);
        assert!((dp.expected_interval_seconds() - 1.0 / 60.0).abs() < 0.002);
        dp.set_interval_hint(Some(1.0 / 30.0));
        assert!((dp.expected_interval_seconds() - 1.0 / 30.0).abs() < 1e-9);
        assert!((dp.late_threshold_seconds() - (1.6 + 0.25) / 30.0).abs() < 1e-9);
        for _ in 0..150 {
            t += 1.0 / 30.0;
            dp.note_arrival(t);
            assert_ne!(dp.note_present(t), GapClass::Late);
        }
        assert_eq!(dp.drain_counters().0, 0);
        dp.set_interval_hint(None);
        assert!((dp.expected_interval_seconds() - 1.0 / 30.0).abs() < 0.004);
    }

    #[test]
    fn reshow_episode_counts_once_and_resolves() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let t = drive(&mut dp, 0.0, 60);
        dp.note_reshow(t + 0.025);
        assert_eq!(dp.drain_counters().1, 0);
        dp.note_reshow(t + 0.033);
        dp.note_reshow(t + 0.042);
        dp.note_reshow(t + 0.050);
        dp.note_arrival(t + 0.058);
        assert_eq!(dp.note_present(t + 0.058), GapClass::Late);
        let win = dp.drain_counters();
        assert_eq!(win.1, 1);
        assert_eq!(win.0, 0);
        dp.note_reshow(t + 0.058 + 0.040);
        assert_eq!(dp.drain_counters().1, 1);
    }

    #[test]
    fn motion_stop_counts_gap_episode_but_no_late() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let t = drive(&mut dp, 0.0, 60);
        let mut tick = t + 1.0 / 120.0;
        while tick < t + 0.400 {
            dp.note_reshow(tick);
            tick += 1.0 / 120.0;
        }
        dp.note_arrival(t + 0.400);
        assert_eq!(dp.note_present(t + 0.400), GapClass::Idle);
        let win = dp.drain_counters();
        assert_eq!(win.1, 1);
        assert_eq!(win.0, 0);
        assert_eq!(dp.depth(), 1);
    }

    #[test]
    fn drain_counters_resets() {
        let mut dp = PacerDepthPolicy::new(Config::default(), true);
        let t = drive(&mut dp, 0.0, 60);
        dp.note_network_late(t);
        assert_eq!(dp.drain_counters().0, 1);
        let second = dp.drain_counters();
        assert_eq!(second, (0, 0));
    }

    #[test]
    fn adapt_disabled_counts_but_never_promotes() {
        let mut dp = PacerDepthPolicy::new(Config::default(), false);
        let t = drive(&mut dp, 0.0, 130);
        dp.note_network_late(t);
        dp.note_network_late(t + 0.3);
        assert_eq!(dp.depth(), 1);
        assert_eq!(dp.drain_counters().0, 2);
    }

    #[test]
    fn config_from_environment_clamps_and_defaults() {
        let defaults = Config::from_environment(&HashMap::new());
        assert_eq!(defaults, Config::default());

        let custom = Config::from_environment(&HashMap::from([
            ("AISLOPDESK_DEPTH_PROMOTE_LATES", "3"),
            ("AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS", "500"),
            ("AISLOPDESK_DEPTH_DEMOTE_MS", "4000"),
            ("AISLOPDESK_DEPTH_MINHOLD_MS", "2000"),
            ("AISLOPDESK_DEPTH_LATE_FACTOR", "2.0"),
            ("AISLOPDESK_DEPTH_IDLE_MS", "350"),
            ("AISLOPDESK_DEPTH_LATE_SLACK_PCT", "50"),
            ("AISLOPDESK_DEPTH_DEMOTE_TOLERANCE", "2"),
            ("AISLOPDESK_DEPTH_WARMUP_MS", "5000"),
        ]));
        assert_eq!(custom.promote_late_count, 3);
        assert!((custom.promote_window_seconds - 0.5).abs() < 1e-9);
        assert!((custom.demote_clean_seconds - 4.0).abs() < 1e-9);
        assert!((custom.min_hold_seconds - 2.0).abs() < 1e-9);
        assert!((custom.late_gap_factor - 2.0).abs() < 1e-9);
        assert!((custom.idle_gap_seconds - 0.35).abs() < 1e-9);
        assert!((custom.late_slack_fraction - 0.5).abs() < 1e-9);
        assert_eq!(custom.demote_tolerance_lates, 2);
        assert!((custom.promote_warmup_seconds - 5.0).abs() < 1e-9);

        let clamped = Config::from_environment(&HashMap::from([
            ("AISLOPDESK_DEPTH_PROMOTE_LATES", "99"),
            ("AISLOPDESK_DEPTH_PROMOTE_WINDOW_MS", "0"),
            ("AISLOPDESK_DEPTH_DEMOTE_MS", "999999"),
            ("AISLOPDESK_DEPTH_LATE_FACTOR", "0.1"),
            ("AISLOPDESK_DEPTH_IDLE_MS", "garbage"),
            ("AISLOPDESK_DEPTH_LATE_SLACK_PCT", "250"),
            ("AISLOPDESK_DEPTH_DEMOTE_TOLERANCE", "99"),
            ("AISLOPDESK_DEPTH_WARMUP_MS", "999999"),
        ]));
        assert_eq!(clamped.promote_late_count, 4);
        assert!((clamped.promote_window_seconds - 0.1).abs() < 1e-9);
        assert!((clamped.demote_clean_seconds - 30.0).abs() < 1e-9);
        assert!((clamped.late_gap_factor - 1.1).abs() < 1e-9);
        assert_eq!(clamped.idle_gap_seconds, Config::default().idle_gap_seconds);
        assert!((clamped.late_slack_fraction - 1.0).abs() < 1e-9);
        assert_eq!(clamped.demote_tolerance_lates, 3);
        assert!((clamped.promote_warmup_seconds - 30.0).abs() < 1e-9);

        let neg_slack =
            Config::from_environment(&HashMap::from([("AISLOPDESK_DEPTH_LATE_SLACK_PCT", "-10")]));
        assert!((neg_slack.late_slack_fraction - 0.0).abs() < 1e-9);
    }
}
