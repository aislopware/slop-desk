//! The client's mirror of the host's swipe recogniser, run purely for FEEDBACK.
//!
//! It is the piece of native swipe-back that key translation can never give: something reacting
//! WHILE the fingers are still on the glass. The host stays the sole authority on actually firing
//! the chord; this drives the edge chip and its haptic, from the SAME event stream the view
//! forwards. That stream is pre-coalescing, and coalescing sums same-phase deltas while keeping the
//! boundary markers, so both recognisers reach the same sums and the same verdicts.
//!
//! The streamed IMAGE never moves. A remote pane is a window onto a whole desktop, so translating
//! it reads as dragging the pane rather than peeling a page.
//!
//! The thresholds come from the host's own status push, so a host-side retune can never
//! desynchronise the feedback from what the host will do.

use crate::swipe_nav::{SwipeDirection, SwipeNavStatusMessage};
use crate::swipe_recognizer::{RecognizerState, SwipeNavRecognizer};

/// What the edge chip renders. Progress is QUANTIZED, so a 120 Hz event stream does not re-render
/// the overlay once per event.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SwipePeelChipState {
    /// Which edge the chip sits on.
    pub direction: SwipeDirection,
    /// The fill toward the live tier's commit threshold, in `0.0..=1.0`.
    pub progress: f64,
    /// Whether releasing now would navigate, so the chip renders solid and the view taps the haptic
    /// on the rising edge.
    pub committed: bool,
    /// Whether the gesture fired, so the chip plays its confirm pulse and fades.
    pub confirming: bool,
}

/// What the view should do after feeding one scroll event.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PeelVerdict {
    /// Nothing showing and nothing to change.
    Idle,
    /// A live decisively-horizontal candidate — publish the chip.
    Show(SwipePeelChipState),
    /// The mirror fired: play the confirm pulse. The host fires the actual chord from its own
    /// recogniser at the same moment.
    Commit(SwipeDirection),
    /// The candidate died without firing — a reject, a coast expiry, a cancel. Hide the chip.
    Retract,
}

/// The chip's fill quantum: progress rounds to this, so the published state changes about
/// thirty-two times across a full fill rather than once per event.
pub const PROGRESS_QUANTUM: f64 = 1.0 / 32.0;

/// How much of the fire threshold the horizontal travel must reach before the chip appears at all.
///
/// This is the recogniser's own arm line. Below it the horizontal component is jitter, and a
/// slightly diagonal ordinary scroll must not flash the chip for its first few points.
pub const SHOW_TRAVEL_FRACTION: f64 = 0.3;

/// How long a COMMITTED chip is held after the mirror fires, in seconds.
///
/// The pulse and the dim hold together span the beat where the host's own recogniser lands the
/// chord and the navigated-to page streams in — the only acknowledgement of the fire there is.
/// It is a number both clients need and neither may spell: a Mac holding it for one length and a
/// phone for another would be two answers to "how long does a fire stay acknowledged".
pub const CONFIRM_HOLD_SECONDS: f64 = 0.52;

/// The planner's whole state, carried by a caller that cannot hold a Rust value between calls.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PeelPlannerState {
    /// The mirrored recogniser's own state.
    pub recognizer: RecognizerState,
    /// How far the horizontal travel must reach before the chip appears at all.
    pub show_travel: f64,
    /// Whether the chip is currently published.
    pub showing: bool,
    /// The edge the visible chip sits on.
    pub shown_direction: Option<SwipeDirection>,
    /// The fill floor across the tracking-to-coasting seam.
    pub glass_progress: f64,
}

/// The mirror.
#[derive(Debug, Clone)]
pub struct SwipePeelPlanner {
    recognizer: SwipeNavRecognizer,
    show_travel: f64,
    showing: bool,
    /// The edge the visible chip sits on.
    ///
    /// A mid-gesture REVERSAL that clears the dead zone in one event would otherwise emit
    /// consecutive shows with flipped direction, and the chip would keep its identity in the view —
    /// animating a full-pane slide from one edge to the other instead of fading out and
    /// re-appearing. A flip therefore concludes the old chip first, and the next event re-shows on
    /// the new edge.
    shown_direction: Option<SwipeDirection>,
    /// The fill floor across the tracking-to-coasting seam.
    ///
    /// The denominator changes there, from the fire threshold to the confirm one, which would
    /// visibly DROP the fill mid-gesture even though nothing regressed. A coast frame displays at
    /// least what the on-glass segment reached — unless dominance collapses to zero, which stays an
    /// honest retract.
    glass_progress: f64,
}

impl SwipePeelPlanner {
    /// A mirror configured from the host's pushed operating point.
    #[must_use]
    pub fn new(fire_travel: f64, slow_swipe: bool) -> Self {
        Self {
            recognizer: SwipeNavRecognizer::new(fire_travel, slow_swipe, false),
            show_travel: fire_travel * SHOW_TRAVEL_FRACTION,
            showing: false,
            shown_direction: None,
            glass_progress: 0.0,
        }
    }

    /// Whether the chip is currently published.
    #[must_use]
    pub const fn showing(&self) -> bool {
        self.showing
    }

    /// The planner's whole state, for a caller that cannot hold a Rust value across its own calls.
    #[must_use]
    pub const fn state(&self) -> PeelPlannerState {
        PeelPlannerState {
            recognizer: self.recognizer.state(),
            show_travel: self.show_travel,
            showing: self.showing,
            shown_direction: self.shown_direction,
            glass_progress: self.glass_progress,
        }
    }

    /// A planner carrying the state it was last seen with — the counterpart of [`Self::state`].
    #[must_use]
    pub const fn restored(state: PeelPlannerState) -> Self {
        Self {
            recognizer: SwipeNavRecognizer::restored(state.recognizer),
            show_travel: state.show_travel,
            showing: state.showing,
            shown_direction: state.shown_direction,
            glass_progress: state.glass_progress,
        }
    }

    /// Feeds one forwarded scroll event — the same tuple the pipeline sends the host.
    pub fn ingest(
        &mut self,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
        now: f64,
    ) -> PeelVerdict {
        if let Some(fired) = self
            .recognizer
            .ingest(dx, dy, scroll_phase, momentum_phase, continuous, now)
        {
            self.showing = false;
            self.shown_direction = None;
            self.glass_progress = 0.0;
            return PeelVerdict::Commit(fired);
        }
        // No candidate, one that stopped being decisively horizontal as its dominance or tier
        // collapsed, or an incidental sub-arm travel: the overlay must promise neither a fire the
        // host would reject nor a chip on an ordinary scroll's first diagonal points.
        let Some(live) = self
            .recognizer
            .live_candidate(now)
            .filter(|live| live.progress > 0.0 && live.travel_x.abs() >= self.show_travel)
        else {
            return self.conclude_if_showing();
        };
        if self.showing && self.shown_direction.is_some_and(|shown| live.direction != shown) {
            return self.conclude_if_showing();
        }
        let progress = if live.coasting {
            self.glass_progress.max(live.progress)
        } else {
            self.glass_progress = live.progress;
            live.progress
        };
        self.showing = true;
        self.shown_direction = Some(live.direction);
        let quantized = (progress / PROGRESS_QUANTUM).floor() * PROGRESS_QUANTUM;
        #[expect(
            clippy::manual_clamp,
            reason = "`clamp` returns NaN for a NaN input; the chained max-then-min carries the Swift's \
                      IEEE-754 minimum/maximum semantics, where the non-NaN operand wins"
        )]
        PeelVerdict::Show(SwipePeelChipState {
            direction: live.direction,
            progress: quantized.max(PROGRESS_QUANTUM).min(1.0),
            committed: live.would_fire_at_lift,
            confirming: false,
        })
    }

    /// The view stopped feeding this gesture mid-flight — the scroll rerouted to a canvas pan, the
    /// pane lost focus, eligibility flipped off. Abandon the candidate and hide the chip.
    pub fn cancel(&mut self) -> PeelVerdict {
        self.recognizer.ingest(0.0, 0.0, 8, 0, true, 0.0);
        self.conclude_if_showing()
    }

    const fn conclude_if_showing(&mut self) -> PeelVerdict {
        self.glass_progress = 0.0;
        self.shown_direction = None;
        if self.showing {
            self.showing = false;
            PeelVerdict::Retract
        } else {
            PeelVerdict::Idle
        }
    }
}

/// The history gate over one verdict.
///
/// A candidate toward a direction the host says cannot navigate never surfaces, so neither the chip
/// nor the commit pulse promises a dead navigation. Idempotent when nothing is showing.
///
/// Applied by the VIEW between the ingest and the publish, rather than inside the mirror: the host
/// keeps firing the self-gating chord on these swipes, so the mirror's own state has to keep
/// tracking the gesture exactly as the host's does. An unknown history fails open.
#[must_use]
pub const fn history_gated(verdict: PeelVerdict, status: &SwipeNavStatusMessage) -> PeelVerdict {
    match verdict {
        PeelVerdict::Show(chip) if !status.allows_chip(chip.direction) => PeelVerdict::Retract,
        PeelVerdict::Commit(direction) if !status.allows_chip(direction) => PeelVerdict::Retract,
        other => other,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the fill is compared against the pinned quantum, and a panic in a test is the failure \
                  report rather than a runtime fault"
    )]

    use super::{PROGRESS_QUANTUM, PeelVerdict, SwipePeelChipState, SwipePeelPlanner, history_gated};
    use crate::swipe_nav::{SwipeDirection, SwipeNavStatusMessage};

    const FIRE_TRAVEL: f64 = 80.0;

    fn planner() -> SwipePeelPlanner {
        SwipePeelPlanner::new(FIRE_TRAVEL, true)
    }

    /// One on-glass event of a rightward swipe, which is a BACK navigation.
    fn glass(planner: &mut SwipePeelPlanner, dx: f64, phase: u8, now: f64) -> PeelVerdict {
        planner.ingest(dx, 0.0, phase, 0, true, now)
    }

    fn shown(verdict: PeelVerdict) -> SwipePeelChipState {
        match verdict {
            PeelVerdict::Show(chip) => chip,
            other => panic!("expected a published chip, got {other:?}"),
        }
    }

    /// An ordinary scroll's first diagonal points must not flash the chip.
    #[test]
    fn an_incidental_sub_arm_travel_shows_nothing() {
        let mut planner = planner();
        assert_eq!(glass(&mut planner, 5.0, 1, 0.0), PeelVerdict::Idle);
        assert!(!planner.showing());
    }

    #[test]
    fn a_decisively_horizontal_gesture_publishes_a_filling_chip() {
        let mut planner = planner();
        glass(&mut planner, 20.0, 1, 0.0);
        let early = shown(glass(&mut planner, 20.0, 2, 0.01));
        assert_eq!(early.direction, SwipeDirection::Back);
        assert!(!early.committed, "not at the threshold yet");
        let later = shown(glass(&mut planner, 30.0, 2, 0.02));
        assert!(later.progress > early.progress);
    }

    #[test]
    fn the_chip_reports_that_a_release_would_navigate() {
        let mut planner = planner();
        glass(&mut planner, 40.0, 1, 0.0);
        let chip = shown(glass(&mut planner, 60.0, 2, 0.02));
        assert!(chip.committed);
        assert_eq!(chip.progress, 1.0);
    }

    /// A 120 Hz stream must not re-render the overlay once per event.
    #[test]
    fn the_fill_is_quantized_rather_than_continuous() {
        let mut planner = planner();
        glass(&mut planner, 30.0, 1, 0.0);
        let chip = shown(glass(&mut planner, 1.0, 2, 0.01));
        let steps = chip.progress / PROGRESS_QUANTUM;
        assert!(
            (steps - steps.round()).abs() < 1e-9,
            "the fill lands on a quantum boundary: {}",
            chip.progress,
        );
        assert!(chip.progress >= PROGRESS_QUANTUM, "and never rounds to nothing");
    }

    /// A slide from one edge to the other is what keeping the chip's identity would animate.
    #[test]
    fn a_mid_gesture_reversal_concludes_the_old_chip_before_the_new_one() {
        let mut planner = planner();
        glass(&mut planner, 40.0, 1, 0.0);
        assert_eq!(
            shown(glass(&mut planner, 10.0, 2, 0.01)).direction,
            SwipeDirection::Back
        );
        let flipped = glass(&mut planner, -120.0, 2, 0.02);
        assert_eq!(flipped, PeelVerdict::Retract, "the old chip concludes first");
        assert!(!planner.showing());
    }

    #[test]
    fn a_cancelled_gesture_retracts_the_chip_and_then_stays_idle() {
        let mut planner = planner();
        glass(&mut planner, 40.0, 1, 0.0);
        glass(&mut planner, 10.0, 2, 0.01);
        assert_eq!(planner.cancel(), PeelVerdict::Retract);
        assert_eq!(planner.cancel(), PeelVerdict::Idle, "idempotent");
    }

    #[test]
    fn a_fire_commits_and_leaves_nothing_showing() {
        let mut planner = planner();
        glass(&mut planner, 50.0, 1, 0.0);
        glass(&mut planner, 50.0, 2, 0.01);
        assert_eq!(
            planner.ingest(0.0, 0.0, 4, 0, true, 0.02),
            PeelVerdict::Commit(SwipeDirection::Back),
        );
        assert!(!planner.showing());
    }

    /// Neither the chip nor the haptic may promise a navigation the target cannot make.
    #[test]
    fn the_history_gate_suppresses_a_dead_direction() {
        let no_back = SwipeNavStatusMessage::new(true, true, 80, false, true, true);
        let chip = SwipePeelChipState {
            direction: SwipeDirection::Back,
            progress: 0.5,
            committed: false,
            confirming: false,
        };
        assert_eq!(
            history_gated(PeelVerdict::Show(chip), &no_back),
            PeelVerdict::Retract,
        );
        assert_eq!(
            history_gated(PeelVerdict::Commit(SwipeDirection::Back), &no_back),
            PeelVerdict::Retract,
        );
        assert_eq!(
            history_gated(PeelVerdict::Commit(SwipeDirection::Forward), &no_back),
            PeelVerdict::Commit(SwipeDirection::Forward),
            "the live direction is untouched",
        );
    }

    #[test]
    fn an_unknown_history_leaves_the_feedback_alone() {
        let unknown = SwipeNavStatusMessage::new(true, true, 80, false, false, false);
        let verdict = PeelVerdict::Commit(SwipeDirection::Back);
        assert_eq!(history_gated(verdict, &unknown), verdict);
    }
}
