//! The swipe-nav recogniser: which two-finger gesture becomes a history navigation.
//!
//! Sixteen scalars and flags, so the state crosses BY VALUE — the host's injector and the client's
//! peel planner each hold one inside a Swift value they already own, and both sides must reach the
//! same verdict over the same event stream, which is exactly the argument for the law existing
//! once.
//!
//! The trace line is the one part that is not state. It is recorded at a DECISION and popped by the
//! caller straight after, so it crosses as an ANSWER — written into the caller's buffer by the same
//! ingest that produced it — rather than riding along in a record that would then need to own a
//! string. A restored recogniser has none pending, which is the same thing said from the other end.

use std::ffi::c_uchar;

use slopdesk_video::swipe_nav::SwipeDirection;
use slopdesk_video::swipe_peel::{
    PROGRESS_QUANTUM, PeelPlannerState, PeelVerdict, SHOW_TRAVEL_FRACTION, SwipePeelChipState,
    SwipePeelPlanner, history_gated,
};
use slopdesk_video::swipe_recognizer::{
    DEFAULT_FIRE_TRAVEL, DOMINANCE, FLICK_MAX_DURATION, LiveCandidate, REFRACTORY, RecognizerState,
    SLOW_DOMINANCE, SLOW_GRACE_MAX_DURATION, SLOW_RELAXED_DOMINANCE, SwipeNavRecognizer,
    slow_required_travel,
};

use crate::deliver;
use crate::metadata_wire::SlopDeskSwipeNavStatus;

/// Fingers moved right — history BACK.
pub const SLOPDESK_SWIPE_BACK: u32 = 0;
/// Fingers moved left — history FORWARD.
pub const SLOPDESK_SWIPE_FORWARD: u32 = 1;

/// The code for a direction.
const fn direction_code(direction: SwipeDirection) -> u32 {
    match direction {
        SwipeDirection::Back => SLOPDESK_SWIPE_BACK,
        SwipeDirection::Forward => SLOPDESK_SWIPE_FORWARD,
    }
}

/// The law's fixed thresholds, so neither language writes one down twice.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskSwipeConstants {
    /// The horizontal dominance a flick must show over its vertical travel.
    pub dominance: f64,
    /// The dominance the slow tier demands at the top of its ramp.
    pub slow_dominance: f64,
    /// The dominance floor under which no travel fires.
    pub slow_relaxed_dominance: f64,
    /// The longest a gesture may last and still be a flick, in seconds.
    pub flick_max_duration: f64,
    /// The longest a slow deliberate swipe may last, in seconds.
    pub slow_grace_max_duration: f64,
    /// The post-fire window in which nothing may fire again, in seconds.
    pub refractory: f64,
    /// The default on-glass travel that fires at lift, in points.
    pub default_fire_travel: f64,
}

/// The recogniser's whole state, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskSwipeRecognizer {
    /// The on-glass travel that fires at lift.
    pub fire_travel: f64,
    /// The on-glass travel that arms momentum confirmation.
    pub arm_travel: f64,
    /// The combined travel that fires an armed candidate.
    pub confirm_travel: f64,
    /// The travel that fires a slow deliberate swipe.
    pub slow_fire_travel: f64,
    /// The travel from which the slow tier's dominance relaxes to the floor.
    pub slow_relaxed_travel: f64,
    /// When the live candidate started, on the caller's arrival clock.
    pub started_at: f64,
    /// When the coast window closes.
    pub coast_deadline: f64,
    /// When a direction last fired — the refractory window's anchor.
    pub fired_at: f64,
    /// The accumulated horizontal travel.
    pub sum_x: f64,
    /// The accumulated vertical travel.
    pub sum_y: f64,
    /// The last momentum event's horizontal delta, for duplicate rejection.
    pub momentum_dx: f64,
    /// The last momentum event's vertical delta.
    pub momentum_dy: f64,
    /// The last momentum event's phase.
    pub momentum_phase: u8,
    /// Whether there was a last momentum event at all — presence, never a sentinel.
    pub has_momentum: bool,
    /// Whether the slow tier is on.
    pub slow_swipe: bool,
    /// Whether a per-gesture decision trace is recorded.
    pub trace: bool,
    /// Whether a candidate is live with the fingers on the glass.
    pub tracking: bool,
    /// Whether an armed candidate is coasting, awaiting momentum.
    pub coasting: bool,
    /// Whether the live candidate was synthesised from a `changed` whose `began` never arrived.
    pub synthesised: bool,
}

impl SlopDeskSwipeRecognizer {
    /// The wrapped recogniser this describes.
    fn inner(self) -> SwipeNavRecognizer {
        SwipeNavRecognizer::restored(RecognizerState {
            fire_travel: self.fire_travel,
            arm_travel: self.arm_travel,
            confirm_travel: self.confirm_travel,
            slow_fire_travel: self.slow_fire_travel,
            slow_relaxed_travel: self.slow_relaxed_travel,
            started_at: self.started_at,
            coast_deadline: self.coast_deadline,
            fired_at: self.fired_at,
            sum_x: self.sum_x,
            sum_y: self.sum_y,
            last_momentum: self.has_momentum.then_some((
                self.momentum_dx,
                self.momentum_dy,
                self.momentum_phase,
            )),
            slow_swipe: self.slow_swipe,
            trace: self.trace,
            tracking: self.tracking,
            coasting: self.coasting,
            synthesised: self.synthesised,
        })
    }

    /// The crossing form of a wrapped recogniser.
    const fn of(recognizer: &SwipeNavRecognizer) -> Self {
        let state = recognizer.state();
        // Presence and value, never a sentinel: a momentum event of exactly zero is a real one.
        let (seen, across, down, phase_code) = match state.last_momentum {
            Some((dx, dy, phase)) => (true, dx, dy, phase),
            None => (false, 0.0, 0.0, 0),
        };
        Self {
            fire_travel: state.fire_travel,
            arm_travel: state.arm_travel,
            confirm_travel: state.confirm_travel,
            slow_fire_travel: state.slow_fire_travel,
            slow_relaxed_travel: state.slow_relaxed_travel,
            started_at: state.started_at,
            coast_deadline: state.coast_deadline,
            fired_at: state.fired_at,
            sum_x: state.sum_x,
            sum_y: state.sum_y,
            momentum_dx: across,
            momentum_dy: down,
            momentum_phase: phase_code,
            has_momentum: seen,
            slow_swipe: state.slow_swipe,
            trace: state.trace,
            tracking: state.tracking,
            coasting: state.coasting,
            synthesised: state.synthesised,
        }
    }
}

/// One ingest: the state that results, the direction if one fired, and the trace line's length.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskSwipeIngest {
    /// The recogniser after the fold.
    pub recognizer: SlopDeskSwipeRecognizer,
    /// The direction, meaningful only when `fired`.
    pub direction: u32,
    /// Whether a gesture qualified — at lift, or at momentum confirmation of an armed lift.
    pub fired: bool,
    /// How many bytes of trace this decision produced. Zero unless tracing is on and a decision was
    /// reached; a length past the caller's capacity means nothing was written.
    pub trace_len: usize,
}

/// A live view of the in-flight candidate, for client-side gesture feedback.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskSwipeCandidate {
    /// The signed horizontal travel so far, momentum included while coasting.
    pub travel_x: f64,
    /// How far along the live tier's threshold the gesture is, in `0.0..=1.0`.
    pub progress: f64,
    /// The direction a fire would take.
    pub direction: u32,
    /// Whether a lift right now would fire. Always false while coasting.
    pub would_fire_at_lift: bool,
    /// Whether the candidate is armed and coasting.
    pub coasting: bool,
}

impl SlopDeskSwipeCandidate {
    /// The crossing form of one live candidate.
    const fn of(candidate: LiveCandidate) -> Self {
        Self {
            travel_x: candidate.travel_x,
            progress: candidate.progress,
            direction: direction_code(candidate.direction),
            would_fire_at_lift: candidate.would_fire_at_lift,
            coasting: candidate.coasting,
        }
    }
}

/// The law's fixed thresholds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_swipe_constants() -> SlopDeskSwipeConstants {
    SlopDeskSwipeConstants {
        dominance: DOMINANCE,
        slow_dominance: SLOW_DOMINANCE,
        slow_relaxed_dominance: SLOW_RELAXED_DOMINANCE,
        flick_max_duration: FLICK_MAX_DURATION,
        slow_grace_max_duration: SLOW_GRACE_MAX_DURATION,
        refractory: REFRACTORY,
        default_fire_travel: DEFAULT_FIRE_TRAVEL,
    }
}

/// A recogniser at rest, its whole threshold family scaled from `fire_travel`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_swipe_recognizer_new(
    fire_travel: f64,
    slow_swipe: bool,
    trace: bool,
) -> SlopDeskSwipeRecognizer {
    SlopDeskSwipeRecognizer::of(&SwipeNavRecognizer::new(fire_travel, slow_swipe, trace))
}

/// Feeds one forwarded scroll event, answering a direction exactly when a gesture qualifies.
///
/// `now` is the caller's arrival clock. Any trace line this decision produced is written into
/// `trace` — the answer's `trace_len` reports its length whether or not it fit.
///
/// # Safety
/// `trace` must either be null or point to `trace_cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_recognizer_ingest(
    recognizer: SlopDeskSwipeRecognizer,
    dx: f64,
    dy: f64,
    scroll_phase: u8,
    momentum_phase: u8,
    continuous: bool,
    now: f64,
    trace: *mut c_uchar,
    trace_cap: usize,
) -> SlopDeskSwipeIngest {
    let mut inner = recognizer.inner();
    let fired = inner.ingest(dx, dy, scroll_phase, momentum_phase, continuous, now);
    let line = inner.take_trace_line().unwrap_or_default();
    // SAFETY: the caller's obligation above, discharged at the call site by a scoped buffer access.
    let trace_len = unsafe { deliver(line.as_bytes(), trace, trace_cap) };
    SlopDeskSwipeIngest {
        recognizer: SlopDeskSwipeRecognizer::of(&inner),
        direction: fired.map_or(SLOPDESK_SWIPE_BACK, direction_code),
        fired: fired.is_some(),
        trace_len,
    }
}

/// The live candidate, for feedback. Answers false and leaves `out` untouched when none is live.
///
/// # Safety
/// `out` must point to one writable `SlopDeskSwipeCandidate` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_live_candidate(
    recognizer: SlopDeskSwipeRecognizer,
    now: f64,
    out: *mut SlopDeskSwipeCandidate,
) -> bool {
    let Some(candidate) = recognizer.inner().live_candidate(now) else {
        return false;
    };
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is non-null and writable for one record by the caller's obligation, and the
    // value written was built inside this call, so it cannot alias.
    unsafe { out.write(SlopDeskSwipeCandidate::of(candidate)) };
    true
}

/// The slow tier's required travel at this duration and dominance, or false when the dominance is
/// under the floor, where no travel fires.
///
/// # Safety
/// `out` must point to one writable `double` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_slow_required_travel(
    duration: f64,
    sum_x: f64,
    sum_y: f64,
    fire_travel: f64,
    slow_fire_travel: f64,
    slow_relaxed_travel: f64,
    out: *mut f64,
) -> bool {
    let Some(required) = slow_required_travel(
        duration,
        sum_x,
        sum_y,
        fire_travel,
        slow_fire_travel,
        slow_relaxed_travel,
    ) else {
        return false;
    };
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is non-null and writable by the caller's obligation; the value is a local.
    unsafe { out.write(required) };
    true
}

// The allowlist, its `SLOPDESK_SWIPE_NAV_APPS` extension and the travel knob have no door of their
// own: they are questions ABOUT an operating point, and `swipe_nav_config` is the one thing that
// holds one. Answering them a second time here is what let a fire path and a status push drift.

/// Nothing showing and nothing to change.
pub const SLOPDESK_PEEL_IDLE: u32 = 0;
/// A live decisively-horizontal candidate — publish the chip.
pub const SLOPDESK_PEEL_SHOW: u32 = 1;
/// The mirror fired: play the confirm pulse.
pub const SLOPDESK_PEEL_COMMIT: u32 = 2;
/// The candidate died without firing — hide the chip.
pub const SLOPDESK_PEEL_RETRACT: u32 = 3;

/// The peel planner's fixed numbers.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPeelConstants {
    /// The chip's fill quantum: progress rounds to this.
    pub progress_quantum: f64,
    /// How much of the fire threshold the travel must reach before the chip appears at all.
    pub show_travel_fraction: f64,
}

/// The planner's whole state: the mirrored recogniser, plus what the chip is doing.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPeelPlanner {
    /// The mirrored recogniser's own state.
    pub recognizer: SlopDeskSwipeRecognizer,
    /// How far the horizontal travel must reach before the chip appears at all.
    pub show_travel: f64,
    /// The fill floor across the tracking-to-coasting seam.
    pub glass_progress: f64,
    /// The edge the visible chip sits on; meaningful only when `has_shown_direction`.
    pub shown_direction: u32,
    /// Whether the chip is currently published.
    pub showing: bool,
    /// Presence for `shown_direction` — never a sentinel, because BACK is code zero.
    pub has_shown_direction: bool,
}

impl SlopDeskPeelPlanner {
    /// The wrapped planner this describes.
    fn inner(self) -> SwipePeelPlanner {
        SwipePeelPlanner::restored(PeelPlannerState {
            recognizer: self.recognizer.inner().state(),
            show_travel: self.show_travel,
            showing: self.showing,
            shown_direction: self
                .has_shown_direction
                .then(|| direction_of(self.shown_direction)),
            glass_progress: self.glass_progress,
        })
    }

    /// The crossing form of a wrapped planner.
    fn of(planner: &SwipePeelPlanner) -> Self {
        let state = planner.state();
        let (seen, edge) = state
            .shown_direction
            .map_or((false, SLOPDESK_SWIPE_BACK), |direction| {
                (true, direction_code(direction))
            });
        Self {
            recognizer: SlopDeskSwipeRecognizer::of(&SwipeNavRecognizer::restored(state.recognizer)),
            show_travel: state.show_travel,
            glass_progress: state.glass_progress,
            shown_direction: edge,
            showing: state.showing,
            has_shown_direction: seen,
        }
    }
}

/// One peel ingest: the state that results, and the verdict the view acts on.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPeelIngest {
    /// The planner after the fold.
    pub planner: SlopDeskPeelPlanner,
    /// The chip's fill, meaningful only for a `SHOW` verdict.
    pub progress: f64,
    /// One of the four `SLOPDESK_PEEL_*` verdicts.
    pub verdict: u32,
    /// The edge, meaningful for `SHOW` and `COMMIT`.
    pub direction: u32,
    /// Whether releasing now would navigate; `SHOW` only.
    pub committed: bool,
    /// Whether the gesture fired, so the chip plays its confirm pulse; `SHOW` only.
    pub confirming: bool,
}

/// The direction a code names. Anything unknown is back, which is the code-zero default.
const fn direction_of(code: u32) -> SwipeDirection {
    if code == SLOPDESK_SWIPE_FORWARD {
        SwipeDirection::Forward
    } else {
        SwipeDirection::Back
    }
}

/// One verdict, folded onto the planner state it came from.
fn answered(planner: &SwipePeelPlanner, verdict: PeelVerdict) -> SlopDeskPeelIngest {
    let (code, direction, progress, committed, confirming) = match verdict {
        PeelVerdict::Idle => (SLOPDESK_PEEL_IDLE, SLOPDESK_SWIPE_BACK, 0.0, false, false),
        PeelVerdict::Retract => (SLOPDESK_PEEL_RETRACT, SLOPDESK_SWIPE_BACK, 0.0, false, false),
        PeelVerdict::Commit(direction) => {
            (SLOPDESK_PEEL_COMMIT, direction_code(direction), 0.0, false, false)
        },
        PeelVerdict::Show(chip) => {
            (
                SLOPDESK_PEEL_SHOW,
                direction_code(chip.direction),
                chip.progress,
                chip.committed,
                chip.confirming,
            )
        },
    };
    SlopDeskPeelIngest {
        planner: SlopDeskPeelPlanner::of(planner),
        progress,
        verdict: code,
        direction,
        committed,
        confirming,
    }
}

/// The peel planner's fixed numbers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_peel_constants() -> SlopDeskPeelConstants {
    SlopDeskPeelConstants {
        progress_quantum: PROGRESS_QUANTUM,
        show_travel_fraction: SHOW_TRAVEL_FRACTION,
    }
}

/// A mirror configured from the host's pushed operating point.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_peel_new(fire_travel: f64, slow_swipe: bool) -> SlopDeskPeelPlanner {
    SlopDeskPeelPlanner::of(&SwipePeelPlanner::new(fire_travel, slow_swipe))
}

/// Feeds one forwarded scroll event — the same tuple the pipeline sends the host.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_peel_ingest(
    planner: SlopDeskPeelPlanner,
    dx: f64,
    dy: f64,
    scroll_phase: u8,
    momentum_phase: u8,
    continuous: bool,
    now: f64,
) -> SlopDeskPeelIngest {
    let mut inner = planner.inner();
    let verdict = inner.ingest(dx, dy, scroll_phase, momentum_phase, continuous, now);
    answered(&inner, verdict)
}

/// The view stopped feeding this gesture mid-flight — abandon the candidate and hide the chip.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_peel_cancel(planner: SlopDeskPeelPlanner) -> SlopDeskPeelIngest {
    let mut inner = planner.inner();
    let verdict = inner.cancel();
    answered(&inner, verdict)
}

/// The history gate over one verdict: a candidate toward a direction the host says cannot navigate
/// becomes a retract, so neither the chip nor the commit pulse promises a dead navigation.
///
/// `status` is the record the host pushed — the same one `slopdesk_swipe_nav_allows_chip` reads.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_peel_history_gated(
    verdict: u32,
    direction: u32,
    status: SlopDeskSwipeNavStatus,
) -> u32 {
    let status = status.message();
    let gated = match verdict {
        SLOPDESK_PEEL_SHOW => {
            history_gated(
                PeelVerdict::Show(SwipePeelChipState {
                    direction: direction_of(direction),
                    progress: 0.0,
                    committed: false,
                    confirming: false,
                }),
                &status,
            )
        },
        SLOPDESK_PEEL_COMMIT => history_gated(PeelVerdict::Commit(direction_of(direction)), &status),
        other => return other,
    };
    match gated {
        PeelVerdict::Retract => SLOPDESK_PEEL_RETRACT,
        _ => verdict,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::expect_used,
        clippy::indexing_slicing,
        unsafe_code,
        reason = "the fixtures are exact, the answered lengths bound their own buffers, and reaching a \
                  pointer entry from a test is what the entry is for"
    )]

    use std::ptr;

    use super::{
        SLOPDESK_SWIPE_BACK, SLOPDESK_SWIPE_FORWARD, SlopDeskSwipeCandidate, SlopDeskSwipeRecognizer,
        slopdesk_swipe_live_candidate, slopdesk_swipe_recognizer_ingest, slopdesk_swipe_recognizer_new,
        slopdesk_swipe_slow_required_travel,
    };

    /// One ingest with no interest in the trace.
    fn ingest(
        state: SlopDeskSwipeRecognizer,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        now: f64,
    ) -> super::SlopDeskSwipeIngest {
        unsafe {
            slopdesk_swipe_recognizer_ingest(
                state,
                dx,
                dy,
                scroll_phase,
                momentum_phase,
                true,
                now,
                ptr::null_mut(),
                0,
            )
        }
    }

    #[test]
    fn a_dominant_flick_fires_at_lift() {
        let state = slopdesk_swipe_recognizer_new(80.0, true, false);
        let began = ingest(state, 10.0, 0.0, 1, 0, 1.0);
        assert!(!began.fired);
        let moved = ingest(began.recognizer, 80.0, 2.0, 2, 0, 1.1);
        assert!(!moved.fired);
        let lifted = ingest(moved.recognizer, 0.0, 0.0, 4, 0, 1.2);
        assert!(lifted.fired);
        assert_eq!(lifted.direction, SLOPDESK_SWIPE_BACK, "rightward is history back");
        assert!(!lifted.recognizer.tracking);
        // The refractory window is the anchor a second gesture is measured against.
        let again = ingest(lifted.recognizer, 10.0, 0.0, 1, 0, 1.25);
        assert!(
            !again.recognizer.tracking,
            "the refractory window rejects the restart"
        );
    }

    #[test]
    fn an_armed_candidate_confirms_on_momentum_and_traces_it() {
        let state = slopdesk_swipe_recognizer_new(80.0, true, true);
        let began = ingest(state, 0.0, 0.0, 1, 0, 1.0);
        let moved = ingest(began.recognizer, -40.0, 1.0, 2, 0, 1.05);
        let lifted = ingest(moved.recognizer, 0.0, 0.0, 4, 0, 1.1);
        assert!(!lifted.fired, "under the fire bar, so it arms instead");
        assert!(lifted.recognizer.coasting);

        let mut trace = [0u8; 256];
        let confirmed = unsafe {
            slopdesk_swipe_recognizer_ingest(
                lifted.recognizer,
                -90.0,
                0.0,
                0,
                1,
                true,
                1.15,
                trace.as_mut_ptr(),
                trace.len(),
            )
        };
        assert!(confirmed.fired);
        assert_eq!(confirmed.direction, SLOPDESK_SWIPE_FORWARD);
        let line = core::str::from_utf8(&trace[..confirmed.trace_len]).expect("utf8");
        assert!(line.starts_with("momentum confirm"), "{line}");
        assert!(!confirmed.recognizer.coasting);
    }

    #[test]
    fn the_live_candidate_and_the_slow_bar_agree_with_the_lift() {
        let state = slopdesk_swipe_recognizer_new(80.0, true, false);
        let began = ingest(state, 0.0, 0.0, 1, 0, 1.0);
        let moved = ingest(began.recognizer, 60.0, 1.0, 2, 0, 1.05);
        let mut live = SlopDeskSwipeCandidate {
            travel_x: 0.0,
            progress: 0.0,
            direction: SLOPDESK_SWIPE_FORWARD,
            would_fire_at_lift: true,
            coasting: true,
        };
        assert!(unsafe { slopdesk_swipe_live_candidate(moved.recognizer, 1.05, &raw mut live) });
        assert_eq!(live.travel_x, 60.0);
        assert_eq!(live.progress, 0.75, "three quarters of the flick bar");
        assert!(!live.would_fire_at_lift, "and a lift here would not fire");
        assert_eq!(live.direction, SLOPDESK_SWIPE_BACK);

        let idle = slopdesk_swipe_recognizer_new(80.0, true, false);
        assert!(
            !unsafe { slopdesk_swipe_live_candidate(idle, 1.0, &raw mut live) },
            "an idle recogniser has nothing to show"
        );

        let mut required = 0.0;
        assert!(unsafe {
            slopdesk_swipe_slow_required_travel(0.45, 100.0, 1.0, 80.0, 160.0, 240.0, &raw mut required)
        });
        assert_eq!(required, 80.0, "at the seam the slow bar IS the flick bar");
        assert!(
            !unsafe {
                slopdesk_swipe_slow_required_travel(0.5, 10.0, 10.0, 80.0, 160.0, 240.0, &raw mut required)
            },
            "under the dominance floor no travel fires"
        );
    }
}
