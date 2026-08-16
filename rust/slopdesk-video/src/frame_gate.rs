//! The two pixel-hash gates that sit beside the capture path: whether a byte-identical frame may be
//! SKIPPED, and whether a settled picture may be re-anchored EARLY.
//!
//! Both own a boolean or counting rule and nothing else — no hashing, no pixel buffers, no clocks —
//! so both are exhaustively testable headlessly while the hardware-gated encoder they steer is
//! never instantiated in a test.

/// The forced-frame obligations that outrank a pixel-identical hash.
///
/// Each one is a contract the client is waiting on, so a frame carrying any of them must be
/// encoded whatever its pixels say. Grouped into one value rather than passed as seven booleans
/// because the rule is conjunctive over all of them: a future obligation is one more field that
/// defaults to "encode".
#[expect(
    clippy::struct_excessive_bools,
    reason = "this IS the list of obligations; collapsing it into a bitset or an enum would hide that they \
              are independent and that any one of them wins"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FrameObligations {
    /// The stream's first frame, which is always the keyframe the client needs to start.
    pub is_first_frame: bool,
    /// A client loss-recovery or heartbeat IDR latch is pending.
    pub forced_keyframe_pending: bool,
    /// An LTR-refresh recovery latch is pending.
    pub recovery_pending: bool,
    /// The periodic insurance IDR cadence is due.
    pub heartbeat_due: bool,
    /// A long-term-reference refresh is scheduled.
    pub ltr_refresh_due: bool,
    /// The self-heal cadence frame is due.
    pub self_heal_due: bool,
}

impl FrameObligations {
    /// Whether anything at all is outstanding.
    #[must_use]
    pub const fn any(&self) -> bool {
        self.is_first_frame
            || self.forced_keyframe_pending
            || self.recovery_pending
            || self.heartbeat_due
            || self.ltr_refresh_due
            || self.self_heal_due
    }
}

/// Whether a captured frame should be SUPPRESSED — skipped rather than handed to the encoder.
///
/// HEVC and the capture stack's own idle-skip already drop most static content; this catches the
/// residual case where a complete frame arrives whose pixels are identical to the previous one.
/// Suppression is allowed ONLY when the pixels are unchanged and NOTHING is outstanding: a
/// duplicate frame with nothing else to deliver.
#[must_use]
pub const fn should_suppress_static_frame(hash_equal_to_last: bool, obligations: FrameObligations) -> bool {
    hash_equal_to_last && !obligations.any()
}

/// The event-driven crisp re-anchor: firing as soon as the picture demonstrably settled, rather
/// than waiting out the quiet-window timer.
///
/// The timer re-sharpens roughly 300 ms after the last real frame. But when the capture stack
/// re-delivers the now-static frame a few times after motion stops, rest is detectable SOONER
/// straight from the frame hash — enough consecutive byte-identical frames means the picture has
/// settled. The timer remains the fallback for content that never goes byte-identical, like a
/// blinking cursor, or that is idle-skipped without ever being re-delivered.
///
/// It fires AT MOST once per rest period; a changed frame re-arms it, because motion resumed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StillnessCrispDecider {
    /// Consecutive byte-identical complete frames observed, reset to zero on any change.
    consecutive_equal: usize,
    /// Whether the crisp re-anchor already fired for the CURRENT rest period.
    fired_this_rest: bool,
}

impl StillnessCrispDecider {
    /// A decider armed and at zero.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            consecutive_equal: 0,
            fired_this_rest: false,
        }
    }

    /// A decider carrying the count and the fired latch it was last seen with.
    ///
    /// The counterpart of the two accessors below: a caller that has to hold this decider's state
    /// somewhere it cannot hold a Rust value — across a foreign-function boundary, say — hands the
    /// same two numbers back rather than keeping a second copy of the rule.
    #[must_use]
    pub const fn restored(consecutive_equal: usize, fired_this_rest: bool) -> Self {
        Self {
            consecutive_equal,
            fired_this_rest,
        }
    }

    /// The consecutive-identical count, for tests and introspection.
    #[must_use]
    pub const fn consecutive_equal(&self) -> usize {
        self.consecutive_equal
    }

    /// Whether the crisp re-anchor has already fired for this rest period.
    #[must_use]
    pub const fn fired_this_rest(&self) -> bool {
        self.fired_this_rest
    }

    /// Feeds one complete frame's hash-equality against the immediately previous frame. A changed
    /// frame re-arms the decider for the next rest period; an equal frame advances the count, which
    /// saturates so a long static stretch cannot wrap.
    pub const fn on_frame(&mut self, hash_equal_to_previous: bool) {
        if hash_equal_to_previous {
            self.consecutive_equal = self.consecutive_equal.saturating_add(1);
        } else {
            self.consecutive_equal = 0;
            self.fired_this_rest = false;
        }
    }

    /// Whether to fire the crisp re-anchor NOW: enough consecutive identical frames, and not
    /// already fired for this rest period. Pure.
    #[must_use]
    pub const fn should_fire_crisp(&self, rest_threshold: usize) -> bool {
        let threshold = if rest_threshold > 1 { rest_threshold } else { 1 };
        self.consecutive_equal >= threshold && !self.fired_this_rest
    }

    /// Records that the re-anchor fired, so it fires once until motion resumes.
    pub const fn note_crisp_fired(&mut self) {
        self.fired_this_rest = true;
    }
}

#[cfg(test)]
mod tests {
    use super::{FrameObligations, StillnessCrispDecider, should_suppress_static_frame};

    #[test]
    fn only_a_duplicate_frame_with_nothing_outstanding_is_suppressed() {
        let idle = FrameObligations::default();
        assert!(should_suppress_static_frame(true, idle));
        assert!(
            !should_suppress_static_frame(false, idle),
            "changed pixels are always encoded"
        );
    }

    /// The invariant: an obligation outranks the hash, one field at a time.
    #[test]
    fn every_forced_obligation_defeats_an_identical_hash() {
        let obligations: [fn(&mut FrameObligations); 6] = [
            |o| o.is_first_frame = true,
            |o| o.forced_keyframe_pending = true,
            |o| o.recovery_pending = true,
            |o| o.heartbeat_due = true,
            |o| o.ltr_refresh_due = true,
            |o| o.self_heal_due = true,
        ];
        for (index, set) in obligations.into_iter().enumerate() {
            let mut pending = FrameObligations::default();
            set(&mut pending);
            assert!(pending.any(), "obligation {index} must register");
            assert!(
                !should_suppress_static_frame(true, pending),
                "obligation {index} must force an encode",
            );
        }
    }

    #[test]
    fn the_crisp_anchor_fires_once_the_picture_has_settled() {
        let mut decider = StillnessCrispDecider::new();
        decider.on_frame(true);
        assert!(!decider.should_fire_crisp(3), "one identical frame is not rest");
        decider.on_frame(true);
        decider.on_frame(true);
        assert!(decider.should_fire_crisp(3));
    }

    #[test]
    fn it_fires_at_most_once_per_rest_period() {
        let mut decider = StillnessCrispDecider::new();
        for _ in 0..5 {
            decider.on_frame(true);
        }
        assert!(decider.should_fire_crisp(3));
        decider.note_crisp_fired();
        decider.on_frame(true);
        assert!(!decider.should_fire_crisp(3), "still the same rest period");
        // Motion resumes, and the next rest period may fire again.
        decider.on_frame(false);
        assert_eq!(decider.consecutive_equal(), 0);
        assert!(!decider.fired_this_rest());
        for _ in 0..3 {
            decider.on_frame(true);
        }
        assert!(decider.should_fire_crisp(3));
    }

    #[test]
    fn a_zero_threshold_still_needs_one_identical_frame() {
        let mut decider = StillnessCrispDecider::new();
        assert!(!decider.should_fire_crisp(0), "nothing observed is not rest");
        decider.on_frame(true);
        assert!(decider.should_fire_crisp(0));
    }

    #[test]
    fn a_long_static_stretch_saturates_rather_than_wrapping() {
        let mut decider = StillnessCrispDecider::new();
        for _ in 0..1_000 {
            decider.on_frame(true);
        }
        assert!(decider.should_fire_crisp(3));
        assert_eq!(decider.consecutive_equal(), 1_000);
    }
}
