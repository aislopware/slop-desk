//! Content/congestion-adaptive FPS governor — a port of Swift `FPSGovernor`, plus its actuator
//! `EncodeCadenceGate` and the time-equivalent `SelfHealCadence`.
//!
//! Under a bandwidth-starved link `VideoToolbox` can only coarsen QP so far; past the entropy floor a
//! dense stream's offered load exceeds the actuated rate. The governor drops the FRAME RATE (each
//! remaining frame gets a bigger byte budget AND the aggregate fits) by picking a target fps from a
//! clean-divisor LADDER of the base fps and actuating it through a schedule-anchored
//! [`EncodeCadenceGate`] — a metronome-regular every-k-th-delivery cadence, never an alternating
//! skip.
//!
//! Control law (one tick per folded `NetworkStats` report): a budget test (`bytes_ewma × 8 ×
//! current_fps` vs `target × headroom`) drives asymmetric hysteresis — step DOWN fast on sustained
//! over-budget AND congestion (one rung per hold window), step UP slow on a clean run with a strict
//! projected fit. Pure + deterministic; "time" is the count of folded reports.
//!
//! Tunables: the Swift source resolves these from `AISLOPDESK_FPS_GOV_*` env vars at startup; the
//! portable core uses the compile-time defaults below (identical when no override is set).

use crate::live_congestion_controller::{
    effective_slack_millis, LOSS_THRESHOLD, RTT_INFLATE_FACTOR,
};
use std::collections::BTreeSet;

/// Offered-load overage tolerated before "over budget" (1.2 = +20%).
pub const HEADROOM_FACTOR: f64 = 1.2;
/// Consecutive over-budget+congested ticks before a step-down.
pub const STEP_DOWN_TICKS: i64 = 3;
/// Ticks between step-downs — one rung per spacing window.
pub const STEP_DOWN_HOLD_TICKS: i64 = 8;
/// Clean ticks per step-up rung.
pub const STEP_UP_TICKS: i64 = 60;
/// Reports to fold before ANY action — the cold-start guard.
pub const WARMUP_TICKS: i64 = 10;
/// Ladder floor fps.
pub const MIN_FPS: i32 = 15;
/// EWMA weight for the per-frame bytes fold.
pub const BYTES_ALPHA: f64 = 0.125;

/// Content/congestion-adaptive FPS governor.
#[derive(Debug, Clone, PartialEq)]
pub struct FpsGovernor {
    base_fps: i32,
    ladder: Vec<i32>,
    current_fps: i32,
    ticks: i64,
    over_budget_run: i64,
    clean_run: i64,
    down_hold_until_tick: i64,
    bytes_per_frame_ewma: f64,
}

impl FpsGovernor {
    /// Builds a governor for the session's configured `base_fps` (clamped ≥ 1).
    #[must_use]
    pub fn new(base_fps: i32) -> Self {
        let base = base_fps.max(1);
        let ladder = Self::ladder(base);
        let current_fps = ladder[0];
        Self {
            base_fps: base,
            ladder,
            current_fps,
            ticks: 0,
            over_budget_run: 0,
            clean_run: 0,
            down_hold_until_tick: 0,
            bytes_per_frame_ewma: 0.0,
        }
    }

    /// Clean-divisor ladder: divisors {1,2,3,4} of `base_fps`, floored at [`MIN_FPS`], deduplicated,
    /// descending. Always contains `base_fps` itself, so it is never empty.
    #[must_use]
    pub fn ladder(base_fps: i32) -> Vec<i32> {
        let base = base_fps.max(1);
        let mut rungs: BTreeSet<i32> = BTreeSet::new();
        rungs.insert(base);
        for divisor in 2..=4 {
            let f = base / divisor;
            if f >= MIN_FPS {
                rungs.insert(f);
            }
        }
        rungs.iter().rev().copied().collect()
    }

    /// The session's configured top-rung fps.
    #[must_use]
    pub const fn base_fps(&self) -> i32 {
        self.base_fps
    }
    /// The currently selected fps.
    #[must_use]
    pub const fn current_fps(&self) -> i32 {
        self.current_fps
    }
    /// Folded-report count.
    #[must_use]
    pub const fn ticks(&self) -> i64 {
        self.ticks
    }
    /// Consecutive over-budget+congested ticks (the step-down streak).
    #[must_use]
    pub const fn over_budget_run(&self) -> i64 {
        self.over_budget_run
    }
    /// Consecutive clean ticks (the step-up run).
    #[must_use]
    pub const fn clean_run(&self) -> i64 {
        self.clean_run
    }
    /// EWMA of non-anchor encoded frame bytes (0 = unseeded).
    #[must_use]
    pub const fn bytes_per_frame_ewma(&self) -> f64 {
        self.bytes_per_frame_ewma
    }

    /// Folds one ENCODED frame's byte size. `is_anchor` (keyframe / crisp) frames are EXCLUDED
    /// (episodic outliers); a non-positive byte count is ignored.
    pub fn note_encoded_frame(&mut self, bytes: i64, is_anchor: bool) {
        if is_anchor || bytes <= 0 {
            return;
        }
        self.bytes_per_frame_ewma = if self.bytes_per_frame_ewma == 0.0 {
            bytes as f64
        } else {
            self.bytes_per_frame_ewma * (1.0 - BYTES_ALPHA) + bytes as f64 * BYTES_ALPHA
        };
    }

    /// One tick per folded `NetworkStats` report. `target_bps` is the host's last actuated bitrate;
    /// `congested` is positive congestion evidence for THIS tick (see [`Self::congestion_evidence`]).
    /// Returns the (possibly unchanged) selected fps.
    pub fn on_tick(&mut self, target_bps: i64, congested: bool) -> i32 {
        self.ticks += 1;
        if self.ticks < WARMUP_TICKS || self.bytes_per_frame_ewma <= 0.0 || target_bps <= 0 {
            return self.current_fps;
        }
        let offered_bps = self.bytes_per_frame_ewma * 8.0 * f64::from(self.current_fps);
        let over_budget = offered_bps > target_bps as f64 * HEADROOM_FACTOR;
        if over_budget && congested {
            self.clean_run = 0;
            self.over_budget_run += 1;
            if self.over_budget_run >= STEP_DOWN_TICKS && self.ticks >= self.down_hold_until_tick {
                if let Some(next) = self.ladder.iter().copied().find(|&x| x < self.current_fps) {
                    self.current_fps = next; // ONE rung down
                    self.over_budget_run = 0;
                    self.down_hold_until_tick = self.ticks + STEP_DOWN_HOLD_TICKS;
                }
            }
        } else if over_budget {
            // Content-heavy but the link is holding: never step down on content alone.
            self.over_budget_run = 0;
            self.clean_run = 0;
        } else {
            self.over_budget_run = 0;
            self.clean_run += 1;
            if self.current_fps < self.base_fps && self.clean_run >= STEP_UP_TICKS {
                if let Some(next) = self
                    .ladder
                    .iter()
                    .rev()
                    .copied()
                    .find(|&x| x > self.current_fps)
                {
                    if self.bytes_per_frame_ewma * 8.0 * f64::from(next) <= target_bps as f64 {
                        self.current_fps = next; // one rung UP, strict fit, NO headroom
                        self.clean_run = 0;
                    }
                }
            }
        }
        self.current_fps
    }

    /// Pure congestion-evidence predicate — the step-down gate's second AND-arm. Reuses the SAME
    /// RTT constants as the ABR ([`crate::live_congestion_controller`]) so the two controllers agree
    /// on what "congested" means.
    #[must_use]
    pub fn congestion_evidence(
        last_loss_sample: f64,
        smoothed_rtt_millis: f64,
        min_rtt_millis: f64,
        abr_current: Option<i64>,
        abr_ceiling: Option<i64>,
    ) -> bool {
        if let (Some(cur), Some(ceil)) = (abr_current, abr_ceiling) {
            if cur < ceil {
                return true;
            }
        }
        if last_loss_sample > LOSS_THRESHOLD {
            return true;
        }
        let slack = effective_slack_millis(min_rtt_millis);
        min_rtt_millis.is_finite()
            && smoothed_rtt_millis > min_rtt_millis * RTT_INFLATE_FACTOR
            && smoothed_rtt_millis > min_rtt_millis + slack
    }
}

/// Schedule-anchored encode-cadence gate — the governor's actuator at the capture→encode hand-off.
/// Admits deliveries on a drift-free schedule at the governed interval.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct EncodeCadenceGate {
    next_due_seconds: f64,
}

impl EncodeCadenceGate {
    /// A fresh, unanchored gate.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            next_due_seconds: 0.0,
        }
    }

    /// The anchored next-due boundary (0 = unanchored). A REJECTED admit exposes the slot boundary
    /// at which the rejected content becomes admissible; rejections never move it.
    #[must_use]
    pub const fn next_due(self) -> f64 {
        self.next_due_seconds
    }

    /// One delivered-frame admission decision. `target_interval_seconds ≤ 0` is inert (always
    /// admit). The first call admits and anchors the schedule; `forced` admits AND re-anchors.
    pub fn admit(
        &mut self,
        now: f64,
        target_interval_seconds: f64,
        tolerance_seconds: f64,
        forced: bool,
    ) -> bool {
        if target_interval_seconds <= 0.0 {
            return true;
        }
        if forced || self.next_due_seconds == 0.0 {
            self.next_due_seconds = now + target_interval_seconds;
            return true;
        }
        if now + tolerance_seconds < self.next_due_seconds {
            return false;
        }
        if now - self.next_due_seconds > target_interval_seconds {
            self.next_due_seconds = now + target_interval_seconds; // stall: re-anchor, no burst catch-up
        } else {
            self.next_due_seconds += target_interval_seconds; // drift-free schedule advance
        }
        true
    }
}

/// Time-equivalent self-heal cadence at a governed fps — keeps wall-clock heal latency ≈ constant.
pub struct SelfHealCadence;

impl SelfHealCadence {
    /// Scales the self-heal `base_every` (frames between refreshes at `base_fps`) to `governed_fps`,
    /// clamped ≥ 2. `base_every ≤ 0` is disabled (passthrough 0). `base_fps` is clamped ≥ 1.
    #[must_use]
    pub fn effective_every(base_every: i64, base_fps: i32, governed_fps: i32) -> i64 {
        if base_every <= 0 {
            return 0; // disabled, passthrough
        }
        let scaled = (base_every as f64 * f64::from(governed_fps) / f64::from(base_fps.max(1)))
            .round() as i64;
        scaled.max(2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // MARK: Ladder

    #[test]
    fn ladder_base_60() {
        assert_eq!(FpsGovernor::ladder(60), vec![60, 30, 20, 15]);
    }

    #[test]
    fn ladder_base_30_drops_sub_min_rungs() {
        assert_eq!(FpsGovernor::ladder(30), vec![30, 15]);
    }

    #[test]
    fn ladder_never_empty_always_contains_base() {
        assert_eq!(FpsGovernor::ladder(10), vec![10]);
        assert_eq!(FpsGovernor::new(10).current_fps(), 10);
    }

    // MARK: Warmup + unseeded guards

    #[test]
    fn no_step_during_warmup_even_over_budget_and_congested() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000_000, false);
        for _ in 0..(WARMUP_TICKS - 1) {
            assert_eq!(gov.on_tick(10_000_000, true), 60);
        }
        assert_eq!(gov.current_fps(), 60);
    }

    #[test]
    fn unseeded_ewma_never_steps() {
        let mut gov = FpsGovernor::new(60);
        for _ in 0..100 {
            assert_eq!(gov.on_tick(1, true), 60);
        }
    }

    // MARK: noteEncodedFrame (EWMA fold)

    #[test]
    fn anchor_frames_excluded_from_ewma() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(500_000, true);
        assert_eq!(gov.bytes_per_frame_ewma(), 0.0);
        gov.note_encoded_frame(10_000, false);
        assert_eq!(gov.bytes_per_frame_ewma(), 10_000.0);
        gov.note_encoded_frame(500_000, true);
        assert_eq!(gov.bytes_per_frame_ewma(), 10_000.0);
    }

    #[test]
    fn ewma_alpha_convergence() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(10_000, false);
        gov.note_encoded_frame(20_000, false);
        assert!((gov.bytes_per_frame_ewma() - 11_250.0).abs() < 1e-9);
        for _ in 0..60 {
            gov.note_encoded_frame(20_000, false);
        }
        assert!((gov.bytes_per_frame_ewma() - 20_000.0).abs() < 20.0);
        gov.note_encoded_frame(0, false);
        assert!((gov.bytes_per_frame_ewma() - 20_000.0).abs() < 20.0);
    }

    // MARK: Step-down requires BOTH arms

    #[test]
    fn over_budget_without_congestion_never_steps_down() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000_000, false);
        for _ in 0..100 {
            assert_eq!(gov.on_tick(10_000_000, false), 60);
        }
        assert_eq!(gov.clean_run(), 0);
    }

    #[test]
    fn congestion_without_over_budget_never_steps_down() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000, false);
        for _ in 0..100 {
            assert_eq!(gov.on_tick(10_000_000, true), 60);
        }
    }

    // MARK: Step-down speed + one-rung-per-window spacing

    #[test]
    fn step_down_after_streak_then_hold_window_spaces_rungs() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000_000, false);
        let ladder = FpsGovernor::ladder(60);
        let mut step_ticks: std::collections::HashMap<i32, i64> = std::collections::HashMap::new();
        let mut fps = 60;
        for _ in 0..40 {
            let next = gov.on_tick(10_000_000, true);
            if next != fps {
                let next_idx = ladder.iter().position(|&x| x == next).unwrap();
                let fps_idx = ladder.iter().position(|&x| x == fps).unwrap();
                assert_eq!(next_idx, fps_idx + 1);
                step_ticks.insert(next, gov.ticks());
                fps = next;
            }
        }
        assert_eq!(step_ticks[&30], WARMUP_TICKS + STEP_DOWN_TICKS - 1);
        assert_eq!(step_ticks[&20] - step_ticks[&30], STEP_DOWN_HOLD_TICKS);
        assert_eq!(step_ticks[&15] - step_ticks[&20], STEP_DOWN_HOLD_TICKS);
        assert_eq!(gov.current_fps(), 15);
        assert_eq!(gov.on_tick(10_000_000, true), 15);
    }

    #[test]
    fn over_budget_run_resets_on_clean_tick() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000_000, false);
        for _ in 0..WARMUP_TICKS {
            let _ = gov.on_tick(1_000_000_000, false);
        }
        let _ = gov.on_tick(10_000_000, true);
        let _ = gov.on_tick(10_000_000, true);
        assert_eq!(gov.over_budget_run(), 2);
        let _ = gov.on_tick(1_000_000_000, false);
        assert_eq!(gov.over_budget_run(), 0);
        assert_eq!(gov.current_fps(), 60);
    }

    // MARK: Step-up

    fn governor_at_20() -> FpsGovernor {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000_000, false);
        while gov.current_fps() != 20 {
            let _ = gov.on_tick(10_000_000, true);
        }
        for _ in 0..200 {
            gov.note_encoded_frame(1_000, false);
        }
        gov
    }

    #[test]
    fn step_up_requires_clean_run_and_projected_fit_one_rung_per_run() {
        let mut gov = governor_at_20();
        let mut fps_trail: Vec<i32> = Vec::new();
        let mut fps = gov.current_fps();
        for _ in 0..(STEP_UP_TICKS * 2 + 2) {
            let next = gov.on_tick(10_000_000, false);
            if next != fps {
                fps_trail.push(next);
                fps = next;
            }
        }
        assert_eq!(fps_trail, vec![30, 60]);
        assert_eq!(gov.current_fps(), 60);
        for _ in 0..=STEP_UP_TICKS {
            assert_eq!(gov.on_tick(10_000_000, false), 60);
        }
    }

    #[test]
    fn step_up_blocked_by_strict_projected_fit() {
        let mut gov = FpsGovernor::new(60);
        gov.note_encoded_frame(1_000_000, false);
        while gov.current_fps() != 30 {
            let _ = gov.on_tick(10_000_000, true);
        }
        for _ in 0..200 {
            gov.note_encoded_frame(10_000, false);
        }
        for _ in 0..(STEP_UP_TICKS * 3) {
            assert_eq!(gov.on_tick(3_000_000, false), 30);
        }
        assert!(gov.clean_run() >= STEP_UP_TICKS);
    }

    #[test]
    fn over_budget_without_congestion_freezes_clean_run() {
        let mut gov = governor_at_20();
        for _ in 0..30 {
            let _ = gov.on_tick(10_000_000, false);
        }
        assert_eq!(gov.clean_run(), 30);
        for _ in 0..200 {
            gov.note_encoded_frame(1_000_000, false);
        }
        let _ = gov.on_tick(10_000_000, false);
        assert_eq!(gov.clean_run(), 0);
        assert_eq!(gov.current_fps(), 20);
    }

    // MARK: congestionEvidence

    #[test]
    fn congestion_evidence_abr_below_ceiling() {
        assert!(FpsGovernor::congestion_evidence(
            0.0,
            10.0,
            10.0,
            Some(5_000_000),
            Some(10_000_000)
        ));
        assert!(!FpsGovernor::congestion_evidence(
            0.0,
            10.0,
            10.0,
            Some(10_000_000),
            Some(10_000_000)
        ));
    }

    #[test]
    fn congestion_evidence_raw_loss_over_threshold() {
        assert!(FpsGovernor::congestion_evidence(
            LOSS_THRESHOLD + 0.01,
            10.0,
            10.0,
            None,
            None
        ));
        assert!(!FpsGovernor::congestion_evidence(
            LOSS_THRESHOLD,
            10.0,
            10.0,
            None,
            None
        ));
    }

    #[test]
    fn congestion_evidence_rtt_inflation() {
        assert!(FpsGovernor::congestion_evidence(
            0.0, 30.0, 10.0, None, None
        ));
        assert!(!FpsGovernor::congestion_evidence(
            0.0, 20.0, 10.0, None, None
        ));
        assert!(!FpsGovernor::congestion_evidence(
            0.0, 11.0, 10.0, None, None
        ));
    }

    #[test]
    fn congestion_evidence_infinite_min_rtt_falls_back_to_other_arms() {
        assert!(!FpsGovernor::congestion_evidence(
            0.0,
            100.0,
            f64::INFINITY,
            None,
            None
        ));
        assert!(FpsGovernor::congestion_evidence(
            0.05,
            100.0,
            f64::INFINITY,
            None,
            None
        ));
    }

    // MARK: EncodeCadenceGate

    const SLOT: f64 = 1.0 / 60.0;
    const TOL: f64 = 0.5 / 120.0;

    #[test]
    fn inert_when_target_interval_non_positive() {
        let mut gate = EncodeCadenceGate::new();
        for i in 0..10 {
            assert!(gate.admit(f64::from(i) * SLOT, 0.0, TOL, false));
            assert!(gate.admit(f64::from(i) * SLOT, -1.0, TOL, false));
        }
    }

    #[test]
    fn first_call_admits_and_anchors() {
        let mut gate = EncodeCadenceGate::new();
        assert!(gate.admit(100.0, 1.0 / 30.0, TOL, false));
        assert!(!gate.admit(100.0 + SLOT, 1.0 / 30.0, TOL, false));
    }

    #[test]
    fn regular_cadence_at_every_ladder_rung() {
        for (fps, expect_stride) in [(30, 2), (20, 3), (15, 4)] {
            let mut gate = EncodeCadenceGate::new();
            let mut admitted_slots: Vec<i64> = Vec::new();
            for i in 0..48i64 {
                if gate.admit(i as f64 * SLOT, 1.0 / f64::from(fps), TOL, false) {
                    admitted_slots.push(i);
                }
            }
            assert!(admitted_slots.len() > 3);
            for pair in admitted_slots.windows(2) {
                assert_eq!(pair[1] - pair[0], expect_stride);
            }
        }
    }

    #[test]
    fn arrival_jitter_never_slips_a_slot_and_schedule_does_not_drift() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        let mut admitted: Vec<f64> = Vec::new();
        for i in 0..60 {
            let jitter = if i % 2 == 0 { -0.004 } else { 0.004 };
            let now = f64::from(i) * SLOT + if i == 0 { 0.0 } else { jitter };
            if gate.admit(now, interval, TOL, false) {
                admitted.push(f64::from(i) * SLOT);
            }
        }
        for pair in admitted.windows(2) {
            assert!((pair[1] - pair[0] - interval).abs() < 1e-9);
        }
    }

    #[test]
    fn forced_always_admits_and_reanchors() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        assert!(gate.admit(0.0, interval, TOL, false));
        assert!(gate.admit(SLOT, interval, TOL, true));
        assert!(!gate.admit(2.0 * SLOT, interval, TOL, false));
        assert!(gate.admit(3.0 * SLOT, interval, TOL, false));
    }

    #[test]
    fn content_stall_reanchors_without_burst_catch_up() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        assert!(gate.admit(0.0, interval, TOL, false));
        assert!(gate.admit(0.5, interval, TOL, false));
        assert!(!gate.admit(0.5 + SLOT, interval, TOL, false));
        assert!(gate.admit(0.5 + 2.0 * SLOT, interval, TOL, false));
    }

    #[test]
    fn rejection_exposes_stable_next_due_deadline() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        assert_eq!(gate.next_due(), 0.0);
        assert!(gate.admit(100.0, interval, TOL, false));
        assert!((gate.next_due() - (100.0 + interval)).abs() < 1e-9);
        assert!(!gate.admit(100.0 + SLOT, interval, TOL, false));
        assert!((gate.next_due() - (100.0 + interval)).abs() < 1e-9);
        assert!(!gate.admit(100.0 + 1.5 * SLOT, interval, TOL, false));
        assert!((gate.next_due() - (100.0 + interval)).abs() < 1e-9);
        let due = gate.next_due();
        assert!(gate.admit(due, interval, TOL, false));
        assert!((gate.next_due() - (100.0 + 2.0 * interval)).abs() < 1e-9);
        let mut inert = EncodeCadenceGate::new();
        assert!(inert.admit(5.0, 0.0, TOL, false));
        assert_eq!(inert.next_due(), 0.0);
    }

    // MARK: SelfHealCadence

    #[test]
    fn effective_every() {
        assert_eq!(SelfHealCadence::effective_every(6, 60, 60), 6);
        assert_eq!(SelfHealCadence::effective_every(6, 60, 30), 3);
        assert_eq!(SelfHealCadence::effective_every(6, 60, 20), 2);
        assert_eq!(SelfHealCadence::effective_every(6, 60, 15), 2);
    }

    #[test]
    fn disabled_passthrough_and_degenerate_base() {
        assert_eq!(SelfHealCadence::effective_every(0, 60, 30), 0);
        // degenerate base_fps clamps to 1: 6 × 30 / 1 = 180 (well above the ≥2 floor).
        assert_eq!(SelfHealCadence::effective_every(6, 0, 30), 180);
    }
}
