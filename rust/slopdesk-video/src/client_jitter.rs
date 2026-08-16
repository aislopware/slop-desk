//! How much slack the client holds before presenting, measured from arrivals it can trust.
//!
//! The estimator is the RFC3550 inter-arrival jitter, folded ENTIRELY in the client's own monotonic
//! clock from SECOND-ORDER differences of arrival intervals. Because only the client's relative
//! deltas enter, the constant clock offset cancels and even modest rate skew is negligible — the
//! measure is clock-skew-immune by construction. The host's send timestamp must NEVER be fed in
//! here: that would re-introduce exactly the cross-machine skew the second difference removes.
//!
//! The controller turns that number into a buffer depth, and is asymmetric on purpose. Growing is
//! the cheap mistake — a frame of latency — and shrinking is the expensive one, because shrinking
//! into a link that is about to wobble buys a visible stall. So it grows the instant the estimate
//! rises or a real underrun happens, and shrinks by at most one frame after a long run of quiet.

use std::cmp::Ordering;

/// The RFC3550 smoothing divisor: each sample moves the estimate a sixteenth of the way.
pub const JITTER_SMOOTHING_DIVISOR: f64 = 16.0;

/// The client-local one-way-delay jitter estimate.
///
/// The first sample only seeds the arrival, the second only seeds the first interval, and the
/// estimate starts moving from the third — so an opening burst can never emit a spurious spike.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct OwdJitterEstimator {
    last_arrival: Option<f64>,
    last_inter_arrival: Option<f64>,
    jitter_seconds: f64,
}

impl OwdJitterEstimator {
    /// An estimator with no samples.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_arrival: None,
            last_inter_arrival: None,
            jitter_seconds: 0.0,
        }
    }

    /// An estimator rebuilt from the three numbers it is, for a caller that carries them itself.
    ///
    /// The two stamps are optional for a reason the folds depend on: the first sample has no
    /// interval and the second has no second difference, so an initial burst never emits a spike.
    #[must_use]
    pub const fn restored(
        last_arrival: Option<f64>,
        last_inter_arrival: Option<f64>,
        jitter_seconds: f64,
    ) -> Self {
        Self {
            last_arrival,
            last_inter_arrival,
            jitter_seconds,
        }
    }

    /// When the previous frame arrived, or nothing before the first sample.
    #[must_use]
    pub const fn last_arrival(&self) -> Option<f64> {
        self.last_arrival
    }

    /// The previous inter-arrival interval, or nothing before the second sample.
    #[must_use]
    pub const fn last_inter_arrival(&self) -> Option<f64> {
        self.last_inter_arrival
    }

    /// The smoothed jitter, in seconds.
    #[must_use]
    pub const fn jitter_seconds(&self) -> f64 {
        self.jitter_seconds
    }

    /// Folds one frame arrival, in client-monotonic seconds.
    pub const fn note(&mut self, arrival: f64) {
        let Some(previous_arrival) = self.last_arrival else {
            self.last_arrival = Some(arrival);
            return;
        };
        let inter = arrival - previous_arrival;
        self.last_arrival = Some(arrival);
        let Some(previous_inter) = self.last_inter_arrival else {
            self.last_inter_arrival = Some(inter);
            return;
        };
        let d = (inter - previous_inter).abs();
        // keep the difference and the divide separate — this is the pinned RFC3550 fold
        self.jitter_seconds += (d - self.jitter_seconds) / JITTER_SMOOTHING_DIVISOR;
        self.last_inter_arrival = Some(inter);
    }

    /// The smoothed jitter as microseconds for the feedback wire field, saturating rather than
    /// wrapping: a negative floors to zero and an absurd value stops at the field's ceiling.
    #[must_use]
    pub fn jitter_micros(&self) -> u32 {
        let micros = self.jitter_seconds * 1_000_000.0;
        if micros.is_nan() {
            return 0;
        }
        let bounded = f64::from(u32::MAX).min(0.0_f64.max(micros));
        // the bound above is exactly the field's ceiling, so the cast is total
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "`bounded` is clamped into 0..=u32::MAX before the cast, so it is total"
        )]
        let micros = bounded as u32;
        micros
    }
}

/// The default buffer-sizing multiple: hold two and a half times the measured jitter, so ordinary
/// wobble on a marginal link does not underrun.
pub const DEFAULT_JITTER_SAFETY: f64 = 2.5;
/// The default number of consecutive low-jitter frames before a single one-step shrink — about
/// three seconds at sixty frames a second.
pub const DEFAULT_SHRINK_COOLDOWN_FRAMES: u32 = 180;

/// Recommends a presentation depth, in FRAMES, from the measured jitter.
///
/// On a perfectly steady link the estimate is zero and the recommendation is the floor, which is
/// the whole point: a clean LAN reclaims the fixed-depth buffer's added latency, while a real spike
/// still re-inflates the buffer immediately.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AdaptiveJitterController {
    min_depth: u32,
    max_depth: u32,
    fps: f64,
    jitter_safety: f64,
    shrink_cooldown_frames: u32,
    target_depth: u32,
    shrink_run: u32,
}

impl AdaptiveJitterController {
    /// A controller whose bounds are ordered and whose initial depth is placed inside them, so no
    /// caller's configuration can produce an empty range.
    #[must_use]
    pub const fn new(
        min_depth: u32,
        max_depth: u32,
        fps: f64,
        initial_depth: u32,
        jitter_safety: f64,
        shrink_cooldown_frames: u32,
    ) -> Self {
        let low = if min_depth > 1 { min_depth } else { 1 };
        let high = if max_depth > low { max_depth } else { low };
        let target = if initial_depth < low {
            low
        } else if initial_depth > high {
            high
        } else {
            initial_depth
        };
        Self {
            min_depth: low,
            max_depth: high,
            fps,
            jitter_safety,
            shrink_cooldown_frames: if shrink_cooldown_frames > 1 {
                shrink_cooldown_frames
            } else {
                1
            },
            target_depth: target,
            shrink_run: 0,
        }
    }

    /// A controller rebuilt from the seven numbers it is, for a caller that carries them itself.
    ///
    /// Deliberately NOT [`Self::new`]: that one orders the bounds and places the initial depth
    /// inside them, which is right for a fresh controller and wrong for one being handed back —
    /// re-clamping a live recommendation would quietly undo a grow.
    #[must_use]
    pub const fn restored(
        min_depth: u32,
        max_depth: u32,
        fps: f64,
        jitter_safety: f64,
        shrink_cooldown_frames: u32,
        target_depth: u32,
        shrink_run: u32,
    ) -> Self {
        Self {
            min_depth,
            max_depth,
            fps,
            jitter_safety,
            shrink_cooldown_frames,
            target_depth,
            shrink_run,
        }
    }

    /// The presentation cadence the jitter seconds are converted against.
    #[must_use]
    pub const fn fps(&self) -> f64 {
        self.fps
    }

    /// The buffer-sizing multiple.
    #[must_use]
    pub const fn jitter_safety(&self) -> f64 {
        self.jitter_safety
    }

    /// How many consecutive low-jitter frames a single one-step shrink costs.
    #[must_use]
    pub const fn shrink_cooldown_frames(&self) -> u32 {
        self.shrink_cooldown_frames
    }

    /// How many the run is at — the counter a grow or a steady step resets.
    #[must_use]
    pub const fn shrink_run(&self) -> u32 {
        self.shrink_run
    }

    /// The floor.
    #[must_use]
    pub const fn min_depth(&self) -> u32 {
        self.min_depth
    }

    /// The ceiling — the pacer's hard cap, which the recommendation never exceeds.
    #[must_use]
    pub const fn max_depth(&self) -> u32 {
        self.max_depth
    }

    /// The live recommendation, in frames.
    #[must_use]
    pub const fn target_depth(&self) -> u32 {
        self.target_depth
    }

    /// The depth that would absorb the given jitter: one frame plus the jitter's own span, rounded
    /// up and clamped, so small wobble does not flip the integer recommendation.
    #[must_use]
    pub fn depth_for_jitter(&self, jitter_seconds: f64) -> u32 {
        // keep the two multiplies separate — bit-exact with the Swift's `j * fps * safety`
        let scaled = jitter_seconds * self.fps;
        let raw = (scaled * self.jitter_safety).ceil();
        // Bound the float BEFORE the integer conversion: a non-finite or out-of-range product would
        // otherwise be a saturating cast whose result is not obviously the ceiling. Capping at the
        // ceiling is behaviour-preserving, since the result is bounded by it anyway.
        let extra = if raw.is_finite() {
            let capped = 0.0_f64.max(raw.min(f64::from(self.max_depth)));
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "`capped` is clamped into 0..=max_depth before the cast, so it is total"
            )]
            let extra = capped as u32;
            extra
        } else {
            0
        };
        self.max_depth.min(self.min_depth.max(extra.saturating_add(1)))
    }

    /// Folds one decoded frame's smoothed jitter and returns the recommendation.
    ///
    /// A rise applies in the SAME step; a fall steps down by at most one, and only after a full
    /// cooldown of consecutive low frames, so a freshly grown buffer sticks and a link sitting on
    /// the boundary cannot thrash.
    pub fn note_frame(&mut self, jitter_seconds: f64) -> u32 {
        let desired = self.depth_for_jitter(jitter_seconds);
        match desired.cmp(&self.target_depth) {
            Ordering::Greater => {
                self.target_depth = self.max_depth.min(desired);
                self.shrink_run = 0;
            },
            Ordering::Less => {
                self.shrink_run += 1;
                if self.shrink_run >= self.shrink_cooldown_frames {
                    self.target_depth = self.min_depth.max(self.target_depth.saturating_sub(1));
                    self.shrink_run = 0;
                }
            },
            Ordering::Equal => self.shrink_run = 0,
        }
        self.target_depth
    }

    /// A real starvation happened: grow one step at once, and restart the cooldown so the next
    /// low-jitter frame cannot undo the bump.
    pub const fn note_underrun(&mut self) -> u32 {
        let grown = self.target_depth.saturating_add(1);
        self.target_depth = if grown > self.max_depth {
            self.max_depth
        } else {
            grown
        };
        self.shrink_run = 0;
        self.target_depth
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures fold exact binary fractions, so the estimate is exact"
    )]

    use super::{
        AdaptiveJitterController, DEFAULT_JITTER_SAFETY, DEFAULT_SHRINK_COOLDOWN_FRAMES, OwdJitterEstimator,
    };

    fn controller() -> AdaptiveJitterController {
        AdaptiveJitterController::new(
            1,
            6,
            60.0,
            2,
            DEFAULT_JITTER_SAFETY,
            DEFAULT_SHRINK_COOLDOWN_FRAMES,
        )
    }

    #[test]
    fn an_opening_burst_never_emits_a_spike() {
        let mut estimator = OwdJitterEstimator::new();
        estimator.note(0.0);
        assert_eq!(estimator.jitter_seconds(), 0.0);
        estimator.note(1.0);
        assert_eq!(
            estimator.jitter_seconds(),
            0.0,
            "one interval is not yet a difference"
        );
    }

    #[test]
    fn a_perfectly_steady_arrival_cadence_reads_as_no_jitter() {
        let mut estimator = OwdJitterEstimator::new();
        for step in 0..50 {
            estimator.note(f64::from(step) * 0.015_625);
        }
        assert_eq!(estimator.jitter_seconds(), 0.0);
    }

    #[test]
    fn the_estimate_moves_a_sixteenth_of_the_way_per_sample() {
        let mut estimator = OwdJitterEstimator::new();
        estimator.note(0.0);
        estimator.note(0.5);
        estimator.note(1.5);
        // The second difference is 0.5, so the estimate lands a sixteenth of the way there.
        assert_eq!(estimator.jitter_seconds(), 0.031_25);
        estimator.note(2.0);
        // And again toward the next |D| = 0.5.
        assert_eq!(estimator.jitter_seconds(), 0.031_25 + (0.5 - 0.031_25) / 16.0);
    }

    #[test]
    fn the_sign_of_the_wobble_does_not_matter() {
        let mut early = OwdJitterEstimator::new();
        early.note(0.0);
        early.note(1.0);
        early.note(1.5);
        let mut late = OwdJitterEstimator::new();
        late.note(0.0);
        late.note(0.5);
        late.note(1.5);
        assert_eq!(early.jitter_seconds(), late.jitter_seconds(), "it is |D|, not D");
    }

    #[test]
    fn the_wire_field_saturates_instead_of_wrapping() {
        let mut estimator = OwdJitterEstimator::new();
        assert_eq!(estimator.jitter_micros(), 0);
        estimator.note(0.0);
        estimator.note(0.0);
        estimator.note(1_000_000.0);
        assert_eq!(
            estimator.jitter_micros(),
            u32::MAX,
            "an absurd gap stops at the field's ceiling rather than wrapping to a small number",
        );
    }

    #[test]
    fn a_steady_link_asks_for_the_latency_floor() {
        let controller = controller();
        assert_eq!(controller.depth_for_jitter(0.0), 1);
    }

    #[test]
    fn the_recommendation_covers_the_jitter_with_the_safety_headroom() {
        let controller = controller();
        // 10 ms of jitter at 60 fps with 2.5× safety is 1.5 frames, which rounds up to 2, plus the base.
        assert_eq!(controller.depth_for_jitter(0.010), 3);
        assert_eq!(
            controller.depth_for_jitter(1.0),
            6,
            "and it never exceeds the pacer's cap"
        );
    }

    #[test]
    fn a_nonsense_jitter_reading_falls_back_to_the_floor_rather_than_the_cap() {
        let controller = controller();
        assert_eq!(controller.depth_for_jitter(f64::NAN), 1);
        assert_eq!(controller.depth_for_jitter(f64::INFINITY), 1);
        assert_eq!(
            controller.depth_for_jitter(-1.0),
            1,
            "a negative can never underflow the floor"
        );
    }

    #[test]
    fn a_rise_applies_in_the_same_step() {
        let mut controller = controller();
        assert_eq!(controller.target_depth(), 2);
        assert_eq!(
            controller.note_frame(0.010),
            3,
            "the buffer re-inflates the instant jitter rises"
        );
    }

    #[test]
    fn a_fall_waits_out_the_whole_cooldown_and_then_steps_once() {
        let mut controller = controller();
        controller.note_frame(0.030);
        let grown = controller.target_depth();
        assert!(grown > 2);
        for _ in 0..(DEFAULT_SHRINK_COOLDOWN_FRAMES - 1) {
            assert_eq!(controller.note_frame(0.0), grown, "a freshly grown buffer sticks");
        }
        assert_eq!(
            controller.note_frame(0.0),
            grown - 1,
            "and then gives back exactly one frame"
        );
    }

    #[test]
    fn a_single_wobble_restarts_the_cooldown_so_a_boundary_link_cannot_thrash() {
        let mut controller = controller();
        controller.note_frame(0.030);
        let grown = controller.target_depth();
        for _ in 0..(DEFAULT_SHRINK_COOLDOWN_FRAMES - 1) {
            controller.note_frame(0.0);
        }
        controller.note_frame(0.030);
        assert_eq!(
            controller.target_depth(),
            grown,
            "steady at the recommendation, not shrinking"
        );
        for _ in 0..(DEFAULT_SHRINK_COOLDOWN_FRAMES - 1) {
            assert_eq!(controller.note_frame(0.0), grown, "the run started over");
        }
    }

    #[test]
    fn an_underrun_grows_at_once_and_is_not_undone_by_the_next_quiet_frame() {
        let mut controller = controller();
        for _ in 0..(DEFAULT_SHRINK_COOLDOWN_FRAMES - 1) {
            controller.note_frame(0.0);
        }
        assert_eq!(controller.note_underrun(), 3);
        assert_eq!(
            controller.note_frame(0.0),
            3,
            "the cooldown restarted with the bump"
        );
    }

    #[test]
    fn neither_edge_can_leave_the_configured_band() {
        let mut controller = AdaptiveJitterController::new(2, 4, 60.0, 2, DEFAULT_JITTER_SAFETY, 1);
        for _ in 0..20 {
            controller.note_underrun();
        }
        assert_eq!(controller.target_depth(), 4);
        for _ in 0..20 {
            controller.note_frame(0.0);
        }
        assert_eq!(controller.target_depth(), 2);
    }

    #[test]
    fn a_configuration_with_the_bounds_inverted_still_has_a_usable_range() {
        let controller = AdaptiveJitterController::new(5, 2, 60.0, 0, DEFAULT_JITTER_SAFETY, 0);
        assert_eq!(controller.min_depth(), 5);
        assert_eq!(
            controller.max_depth(),
            5,
            "the ceiling is lifted to the floor, never below it"
        );
        assert_eq!(
            controller.target_depth(),
            5,
            "and the initial depth lands inside the band"
        );
    }
}
