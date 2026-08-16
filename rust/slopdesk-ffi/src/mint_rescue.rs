//! The off-screen window rescue, as a machine the caller drives one step at a time.
//!
//! Every effect the rescue needs suspends on the near side — two window enumerations, an
//! accessibility call that hops to the main thread, and a sleep — and no C ABI can call back into
//! that and wait. So the decision tree does not take a trait of effects: it hands back the ONE step
//! it wants performed, and takes the observation.
//!
//! The state crosses BY VALUE, seven scalars of it, because the caller owns the loop and holds it
//! between suspensions. Its `step` field is both halves of the answer: what to do next, and where
//! the rescue is — the two are the same thing, since no two stages ask for the same step.
//!
//! No window handle ever crosses. The caller keeps the two it might mint from (the one the first
//! full enumeration produced and the one the last sighting did) and this side names which, so the
//! rescue can reason about a window without any way to touch one.

use slopdesk_video::mint_rescue::{
    DeminiaturizeOutcome, Frame, Observation, Rescue, Step, advance, begin, next_step, stage_of,
};

/// Enumerate every window and report whether the target is among them.
pub const SLOPDESK_MINT_STEP_FULL_LIST: u32 = 0;
/// Un-minimize the target and report the outcome.
pub const SLOPDESK_MINT_STEP_DEMINIATURIZE: u32 = 1;
/// Sleep one poll interval, enumerate every window, report the target's frame.
pub const SLOPDESK_MINT_STEP_POLL_FULL: u32 = 2;
/// Sleep one poll interval, enumerate the on-screen windows, report the target's frame.
pub const SLOPDESK_MINT_STEP_POLL_ON_SCREEN: u32 = 3;
/// Stop and mint nothing — the caller's terminal refusal stands.
pub const SLOPDESK_MINT_STEP_REFUSE: u32 = 4;
/// Stop and mint from the handle the first full enumeration produced.
pub const SLOPDESK_MINT_STEP_MINT_TARGET: u32 = 5;
/// Stop and mint from the handle the most recent sighting produced.
pub const SLOPDESK_MINT_STEP_MINT_SIGHTED: u32 = 6;

/// The enumeration missed the target, or failed outright.
pub const SLOPDESK_MINT_SAW_NOTHING: u32 = 0;
/// The enumeration found the target, wearing the frame that rides along.
pub const SLOPDESK_MINT_SAW_WINDOW: u32 = 1;
/// The un-minimize reported, with its outcome riding along.
pub const SLOPDESK_MINT_SAW_DEMINIATURIZE: u32 = 2;

/// The window was not minimized — another desktop, or a restore already in flight.
pub const SLOPDESK_MINT_NOT_MINIMIZED: u32 = 0;
/// It was minimized, the un-minimize landed, and the restore is animating.
pub const SLOPDESK_MINT_RESTORING: u32 = 1;
/// The window could not be reached or flipped.
pub const SLOPDESK_MINT_FAILED: u32 = 2;

/// A rescue in flight.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskMintRescue {
    /// The step the caller owes, one of the `SLOPDESK_MINT_STEP_*` codes. A code at or above
    /// `SLOPDESK_MINT_STEP_REFUSE` is an answer, and the rescue is over.
    pub step: u32,
    /// The polls still left in the settle budget.
    pub polls_left: u32,
    /// The previous sighting's frame, meaningful only when `has_prior`.
    pub prior_x: f64,
    /// The previous sighting's frame, meaningful only when `has_prior`.
    pub prior_y: f64,
    /// The previous sighting's frame, meaningful only when `has_prior`.
    pub prior_width: f64,
    /// The previous sighting's frame, meaningful only when `has_prior`.
    pub prior_height: f64,
    /// Whether a sighting has happened at all — an absent frame is not a frame of zeroes, and a
    /// window really can sit at the origin with no size while it animates.
    pub has_prior: bool,
}

/// Opens a rescue that may spend at most `poll_attempts` polls waiting for a frame to settle.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mint_rescue_begin(poll_attempts: u32) -> SlopDeskMintRescue {
    crossing(&begin(poll_attempts))
}

/// Feeds back what the caller observed and answers with the rescue's next state.
///
/// `saw` is one of the `SLOPDESK_MINT_SAW_*` codes; `outcome` carries the un-minimize's answer and
/// the four frame numbers carry a sighting's. A code this side does not know is not an answer, and
/// the rescue refuses on it rather than minting something arbitrary.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_mint_rescue_advance(
    state: SlopDeskMintRescue,
    saw: u32,
    outcome: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> SlopDeskMintRescue {
    let mut rescue = restored(&state);
    advance(&mut rescue, observation(saw, outcome, x, y, width, height));
    crossing(&rescue)
}

/// The observation a code and its payload spell.
const fn observation(saw: u32, outcome: u32, x: f64, y: f64, width: f64, height: f64) -> Observation {
    match saw {
        SLOPDESK_MINT_SAW_WINDOW => Observation::Sighted(Frame { x, y, width, height }),
        SLOPDESK_MINT_SAW_DEMINIATURIZE => {
            Observation::Deminiaturized(match outcome {
                SLOPDESK_MINT_NOT_MINIMIZED => DeminiaturizeOutcome::NotMinimized,
                SLOPDESK_MINT_RESTORING => DeminiaturizeOutcome::Restoring,
                // An outcome nobody named is one nobody can act on: refuse rather than guess.
                _ => DeminiaturizeOutcome::Failed,
            })
        },
        // Both "the enumeration missed it" and an unknown code answer with nothing, which during a
        // poll is skipped and anywhere else ends the rescue.
        _ => Observation::Missed,
    }
}

/// The crossing form of a rescue.
const fn crossing(rescue: &Rescue) -> SlopDeskMintRescue {
    let (has_prior, frame) = match rescue.prior {
        Some(frame) => (true, frame),
        None => {
            (false, Frame {
                x: 0.0,
                y: 0.0,
                width: 0.0,
                height: 0.0,
            })
        },
    };
    SlopDeskMintRescue {
        step: step_code(next_step(rescue)),
        polls_left: rescue.polls_left,
        prior_x: frame.x,
        prior_y: frame.y,
        prior_width: frame.width,
        prior_height: frame.height,
        has_prior,
    }
}

/// The rescue a crossing form describes.
const fn restored(state: &SlopDeskMintRescue) -> Rescue {
    Rescue {
        stage: stage_of(step_of(state.step)),
        polls_left: state.polls_left,
        prior: if state.has_prior {
            Some(Frame {
                x: state.prior_x,
                y: state.prior_y,
                width: state.prior_width,
                height: state.prior_height,
            })
        } else {
            None
        },
    }
}

/// The code one step carries.
const fn step_code(step: Step) -> u32 {
    match step {
        Step::FullList => SLOPDESK_MINT_STEP_FULL_LIST,
        Step::Deminiaturize => SLOPDESK_MINT_STEP_DEMINIATURIZE,
        Step::PollFull => SLOPDESK_MINT_STEP_POLL_FULL,
        Step::PollOnScreen => SLOPDESK_MINT_STEP_POLL_ON_SCREEN,
        Step::Refuse => SLOPDESK_MINT_STEP_REFUSE,
        Step::MintTarget => SLOPDESK_MINT_STEP_MINT_TARGET,
        Step::MintSighted => SLOPDESK_MINT_STEP_MINT_SIGHTED,
    }
}

/// The step one code names. An unknown code is a refusal, which is the terminal answer that mints
/// nothing.
const fn step_of(code: u32) -> Step {
    match code {
        SLOPDESK_MINT_STEP_FULL_LIST => Step::FullList,
        SLOPDESK_MINT_STEP_DEMINIATURIZE => Step::Deminiaturize,
        SLOPDESK_MINT_STEP_POLL_FULL => Step::PollFull,
        SLOPDESK_MINT_STEP_POLL_ON_SCREEN => Step::PollOnScreen,
        SLOPDESK_MINT_STEP_MINT_TARGET => Step::MintTarget,
        SLOPDESK_MINT_STEP_MINT_SIGHTED => Step::MintSighted,
        _ => Step::Refuse,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        SLOPDESK_MINT_FAILED, SLOPDESK_MINT_NOT_MINIMIZED, SLOPDESK_MINT_RESTORING,
        SLOPDESK_MINT_SAW_DEMINIATURIZE, SLOPDESK_MINT_SAW_NOTHING, SLOPDESK_MINT_SAW_WINDOW,
        SLOPDESK_MINT_STEP_DEMINIATURIZE, SLOPDESK_MINT_STEP_FULL_LIST, SLOPDESK_MINT_STEP_MINT_SIGHTED,
        SLOPDESK_MINT_STEP_MINT_TARGET, SLOPDESK_MINT_STEP_POLL_FULL, SLOPDESK_MINT_STEP_POLL_ON_SCREEN,
        SLOPDESK_MINT_STEP_REFUSE, SlopDeskMintRescue, slopdesk_mint_rescue_advance,
        slopdesk_mint_rescue_begin,
    };

    /// The caller's half: report a sighting of this size.
    fn saw(state: SlopDeskMintRescue, width: f64, height: f64) -> SlopDeskMintRescue {
        slopdesk_mint_rescue_advance(state, SLOPDESK_MINT_SAW_WINDOW, 0, 0.0, 0.0, width, height)
    }

    /// The caller's half: report what the un-minimize found.
    fn flipped(state: SlopDeskMintRescue, outcome: u32) -> SlopDeskMintRescue {
        slopdesk_mint_rescue_advance(
            state,
            SLOPDESK_MINT_SAW_DEMINIATURIZE,
            outcome,
            0.0,
            0.0,
            0.0,
            0.0,
        )
    }

    #[test]
    fn the_state_round_trips_through_the_crossing_form_at_every_step() {
        let opened = slopdesk_mint_rescue_begin(16);
        assert_eq!(opened.step, SLOPDESK_MINT_STEP_FULL_LIST);
        assert!(!opened.has_prior);

        let resolved = saw(opened, 656.0, 422.0);
        assert_eq!(resolved.step, SLOPDESK_MINT_STEP_DEMINIATURIZE);
        assert!(!resolved.has_prior, "the target's frame is not a sighting");

        let polling = flipped(resolved, SLOPDESK_MINT_RESTORING);
        assert_eq!(polling.step, SLOPDESK_MINT_STEP_POLL_ON_SCREEN);
        assert_eq!(polling.polls_left, 15, "the first poll is spent");

        // The Dock animation, then the real size twice.
        let mid = saw(polling, 62.0, 136.0);
        assert!(mid.has_prior);
        // The frame crosses unchanged, which is the whole of what the settle gate compares.
        #[expect(
            clippy::float_cmp,
            reason = "the frame is carried, never computed — an exact equality is the question asked"
        )]
        {
            assert_eq!(mid.prior_width, 62.0);
        }
        let once = saw(mid, 656.0, 422.0);
        assert_eq!(once.step, SLOPDESK_MINT_STEP_POLL_ON_SCREEN);
        let settled = saw(once, 656.0, 422.0);
        assert_eq!(settled.step, SLOPDESK_MINT_STEP_MINT_SIGHTED);
    }

    #[test]
    fn an_other_desktop_window_polls_the_full_enumeration() {
        let opened = saw(slopdesk_mint_rescue_begin(16), 656.0, 422.0);
        let polling = flipped(opened, SLOPDESK_MINT_NOT_MINIMIZED);
        assert_eq!(polling.step, SLOPDESK_MINT_STEP_POLL_FULL);
    }

    #[test]
    fn a_window_that_cannot_be_restored_refuses() {
        let opened = saw(slopdesk_mint_rescue_begin(16), 656.0, 422.0);
        assert_eq!(
            flipped(opened, SLOPDESK_MINT_FAILED).step,
            SLOPDESK_MINT_STEP_REFUSE
        );
        // An outcome code nobody named cannot be acted on either.
        assert_eq!(flipped(opened, 99).step, SLOPDESK_MINT_STEP_REFUSE);
    }

    #[test]
    fn a_window_in_neither_enumeration_refuses() {
        let opened = slopdesk_mint_rescue_begin(16);
        let missed = slopdesk_mint_rescue_advance(opened, SLOPDESK_MINT_SAW_NOTHING, 0, 0.0, 0.0, 0.0, 0.0);
        assert_eq!(missed.step, SLOPDESK_MINT_STEP_REFUSE);
    }

    #[test]
    fn a_budget_that_never_settles_ends_on_the_handle_it_has() {
        // No polls at all: nothing was ever sighted, so the pre-minimize handle is the answer.
        let opened = saw(slopdesk_mint_rescue_begin(0), 656.0, 422.0);
        assert_eq!(
            flipped(opened, SLOPDESK_MINT_RESTORING).step,
            SLOPDESK_MINT_STEP_MINT_TARGET
        );

        // One poll, one sighting, and then the budget is gone.
        let one = saw(slopdesk_mint_rescue_begin(1), 656.0, 422.0);
        let polling = flipped(one, SLOPDESK_MINT_RESTORING);
        assert_eq!(polling.polls_left, 0);
        assert_eq!(saw(polling, 62.0, 136.0).step, SLOPDESK_MINT_STEP_MINT_SIGHTED);
    }
}
