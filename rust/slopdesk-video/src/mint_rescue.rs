//! Rescuing an OFF-SCREEN window pick at session-mint time.
//!
//! The host-windows rail offers minimized windows and windows on another desktop, but the mint path
//! resolves the hello's requested window against the ON-SCREEN enumeration, which can never contain
//! either — so picking one would bounce the pane straight back to the picker.
//!
//! The rescue is to find the target in the FULL enumeration, un-minimize it when that is what hides
//! it — the window server never paints a minimized window, so capturing one streams nothing — and
//! hand back a handle only once the restore has SETTLED.
//!
//! ## The settle gate is load-bearing
//!
//! Capture size is locked from the minted handle's frame, and the restore animation reports
//! INTERMEDIATE frames that already claim to be on screen — measured, a window grows through
//! several wrong sizes over about half a second. Minting a mid-animation handle crops the stream to
//! a top-left sliver of the real window, PERMANENTLY, because the geometry watcher installs only
//! after the mint and nothing re-targets afterwards.
//!
//! ## Why this asks instead of calls
//!
//! Every effect the rescue needs is asynchronous on the near side: two enumerations that suspend,
//! an accessibility call that hops to the main thread, and a sleep. A trait of those would have to
//! be called back ACROSS the boundary and suspend there, which no C ABI can do. So the decision
//! tree does not call — it ASKS. [`begin`] opens the rescue, [`next_step`] names the one effect the
//! caller must perform, and [`advance`] takes what came back and names the next. The caller holds
//! the window handles throughout; this side never sees one, and reaches its verdict from a frame it
//! compares for equality and nothing else.
//!
//! An observation that answers a question this machine did not ask is not an answer, and the rescue
//! REFUSES on it — the same terminal answer it gives a window it cannot restore, so a caller that
//! drives the protocol wrongly falls back to the picker rather than minting something arbitrary.

/// Whether, and how, the injected un-minimize changed the target window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeminiaturizeOutcome {
    /// The window was NOT minimized — it lives on another desktop, or a restore was ALREADY
    /// animating when this hello raced it, since the minimized flag flips false at animation START.
    NotMinimized,
    /// It WAS minimized and the un-minimize landed, so the restore is animating now.
    Restoring,
    /// The window could not be reached or flipped: no accessibility grant, a hung app, or a window
    /// that died under the call.
    Failed,
}

/// A window's frame, compared for equality and never interpreted.
///
/// Four numbers rather than an opaque token because the caller already has four and any narrowing
/// of them would be this side deciding what "the same frame" means — which is the caller's window
/// server's decision, not this machine's.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Frame {
    /// The frame's minimum x.
    pub x: f64,
    /// The frame's minimum y.
    pub y: f64,
    /// The frame's width.
    pub width: f64,
    /// The frame's height.
    pub height: f64,
}

/// The one effect the caller must perform before it may advance the rescue again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Enumerate EVERY window — minimized ones and those on another desktop included — and report
    /// whether the target was among them. The handle it came from is the one [`Step::MintTarget`]
    /// later names.
    FullList,
    /// Un-minimize the target and report what the attempt found.
    Deminiaturize,
    /// Wait one poll interval, enumerate EVERY window, and report the target's frame.
    PollFull,
    /// Wait one poll interval, enumerate the ON-SCREEN windows, and report the target's frame.
    PollOnScreen,
    /// Stop, minting nothing: the window is gone, or stays hidden and would stream black. The
    /// caller's terminal refusal stands and the client falls back to the picker.
    Refuse,
    /// Stop and mint from the handle the FIRST full enumeration produced — its frame is the
    /// pre-minimize one, which is exactly what the window restores to.
    MintTarget,
    /// Stop and mint from the handle the MOST RECENT sighting produced.
    MintSighted,
}

/// What the caller saw when it performed the step it was asked for.
///
/// A sighting carries four numbers and the other two answers carry almost none, which is the shape
/// the question has: an enumeration that found the window has a frame to report and one that did
/// not has nothing. Nothing here is boxed or moved in bulk — one of these is built, read once and
/// dropped per step — so the size spread costs nothing worth flattening the meaning for.
#[expect(
    variant_size_differences,
    reason = "a sighting IS a frame; the other two answers have nothing to carry"
)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Observation {
    /// The target was not in the enumeration — absent, or the enumeration itself failed. During the
    /// settle poll this is SKIPPED rather than counted as a sighting.
    Missed,
    /// The target was there, wearing this frame.
    Sighted(Frame),
    /// The un-minimize reported this.
    Deminiaturized(DeminiaturizeOutcome),
}

/// Where the rescue is.
///
/// Public because a caller across a C ABI holds this state between steps and must be able to write
/// it back down; [`next_step`] maps each stage to exactly one step and no two stages share one, so
/// the step a rescue is showing IS its stage, and nothing else has to cross.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    /// Waiting on the first full enumeration.
    Resolving,
    /// Waiting on the un-minimize.
    Deminiaturizing,
    /// Polling for a settled frame, against the on-screen list or the full one.
    Polling {
        /// Whether the poll reads the on-screen enumeration rather than the full one.
        on_screen: bool,
    },
    /// Finished, with the answer it finished on.
    Finished(Step),
}

/// A rescue in flight: a stage, the polls it may still spend, and the frame it last saw.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rescue {
    /// Where the rescue is.
    pub stage: Stage,
    /// The polls it may still spend.
    pub polls_left: u32,
    /// The previous sighting's frame — `Some` also means "a sighting exists to mint from".
    pub prior: Option<Frame>,
}

/// The stage a step came from — the inverse of [`next_step`], for a caller that stored the step.
#[must_use]
pub const fn stage_of(step: Step) -> Stage {
    match step {
        Step::FullList => Stage::Resolving,
        Step::Deminiaturize => Stage::Deminiaturizing,
        Step::PollOnScreen => Stage::Polling { on_screen: true },
        Step::PollFull => Stage::Polling { on_screen: false },
        finished => Stage::Finished(finished),
    }
}

/// Opens a rescue that may spend at most `poll_attempts` polls waiting for a frame to settle.
#[must_use]
pub const fn begin(poll_attempts: u32) -> Rescue {
    Rescue {
        stage: Stage::Resolving,
        polls_left: poll_attempts,
        prior: None,
    }
}

/// The step the caller owes right now. Idempotent — asking does not advance anything.
#[must_use]
pub const fn next_step(rescue: &Rescue) -> Step {
    match rescue.stage {
        Stage::Resolving => Step::FullList,
        Stage::Deminiaturizing => Step::Deminiaturize,
        Stage::Polling { on_screen: true } => Step::PollOnScreen,
        Stage::Polling { on_screen: false } => Step::PollFull,
        Stage::Finished(step) => step,
    }
}

/// Whether the rescue has reached its answer.
#[must_use]
pub const fn is_finished(rescue: &Rescue) -> bool {
    matches!(rescue.stage, Stage::Finished(_))
}

/// Feeds back what the caller observed and names the next step.
pub fn advance(rescue: &mut Rescue, observation: Observation) -> Step {
    match (rescue.stage, observation) {
        // In NEITHER enumeration ⇒ the window is closed, and so is the rescue.
        (Stage::Resolving, Observation::Sighted(_)) => rescue.stage = Stage::Deminiaturizing,
        (Stage::Deminiaturizing, Observation::Deminiaturized(outcome)) => {
            return open_poll(rescue, outcome);
        },
        // A sighting whose frame repeats the one before it is a frame that has stopped moving.
        (Stage::Polling { .. }, Observation::Sighted(frame)) => {
            if rescue.prior == Some(frame) {
                rescue.stage = Stage::Finished(Step::MintSighted);
            } else {
                rescue.prior = Some(frame);
                return issue_poll(rescue);
            }
        },
        // A failed or empty enumeration mid-poll is skipped, not counted as a sighting.
        (Stage::Polling { .. }, Observation::Missed) => return issue_poll(rescue),
        // Already answered: the answer does not change under a late observation.
        (Stage::Finished(step), _) => return step,
        // Anything else answers a question that was not asked.
        _ => rescue.stage = Stage::Finished(Step::Refuse),
    }
    next_step(rescue)
}

/// Enters the settle poll on the enumeration the outcome calls for, or refuses.
const fn open_poll(rescue: &mut Rescue, outcome: DeminiaturizeOutcome) -> Step {
    match outcome {
        // Still hidden and un-restorable: a mint would stream black.
        DeminiaturizeOutcome::Failed => {
            rescue.stage = Stage::Finished(Step::Refuse);
            Step::Refuse
        },
        // On another desktop, where the capture filter finds it wherever it lives — but the frame
        // may STILL be animating if a restore was in flight when this hello raced it, and an
        // other-desktop window never joins the on-screen list, so the settle gate runs on the FULL
        // enumeration.
        DeminiaturizeOutcome::NotMinimized => {
            rescue.stage = Stage::Polling { on_screen: false };
            issue_poll(rescue)
        },
        // Wait for the window to land on the ON-SCREEN list and for its frame to settle.
        DeminiaturizeOutcome::Restoring => {
            rescue.stage = Stage::Polling { on_screen: true };
            issue_poll(rescue)
        },
    }
}

/// Spends one poll from the budget, or finishes on the closest thing to a settled frame there is.
const fn issue_poll(rescue: &mut Rescue) -> Step {
    if rescue.polls_left == 0 {
        // A restore that never lands inside the budget mints the last sighting, which is the
        // closest to settled — or the pre-minimize handle when nothing was ever sighted.
        rescue.stage = Stage::Finished(if rescue.prior.is_some() {
            Step::MintSighted
        } else {
            Step::MintTarget
        });
    } else {
        rescue.polls_left -= 1;
    }
    next_step(rescue)
}

#[cfg(test)]
mod tests {
    use super::{
        DeminiaturizeOutcome, Frame, Observation, Rescue, Step, advance, begin, is_finished, next_step,
        stage_of,
    };

    /// A frame, named by its size the way the measured animation is.
    const fn frame(width: f64, height: f64) -> Frame {
        Frame {
            x: 0.0,
            y: 0.0,
            width,
            height,
        }
    }

    /// The caller's half of the protocol: performs each step against a script and returns where the
    /// rescue landed, plus the frame of the sighting it would mint from.
    ///
    /// `polls` is what the enumeration reports on each poll, repeating its last entry once
    /// exhausted, exactly as a window that has stopped moving would.
    fn drive(
        outcome: DeminiaturizeOutcome,
        target: Option<Frame>,
        polls: &[Option<Frame>],
        attempts: u32,
    ) -> (Step, Option<Frame>) {
        let mut rescue: Rescue = begin(attempts);
        let mut sighted: Option<Frame> = None;
        let mut poll = 0_usize;
        while !is_finished(&rescue) {
            let observation = match next_step(&rescue) {
                Step::FullList => target.map_or(Observation::Missed, Observation::Sighted),
                Step::Deminiaturize => Observation::Deminiaturized(outcome),
                Step::PollFull | Step::PollOnScreen => {
                    let seen = polls.get(poll).copied().or_else(|| polls.last().copied());
                    poll += 1;
                    seen.flatten().map_or(Observation::Missed, |frame| {
                        sighted = Some(frame);
                        Observation::Sighted(frame)
                    })
                },
                Step::Refuse | Step::MintTarget | Step::MintSighted => break,
            };
            advance(&mut rescue, observation);
        }
        let step = next_step(&rescue);
        let minted = match step {
            Step::MintTarget => target,
            Step::MintSighted => sighted,
            _ => None,
        };
        (step, minted)
    }

    #[test]
    fn a_window_in_neither_enumeration_is_closed_and_the_refusal_stands() {
        let (step, minted) = drive(DeminiaturizeOutcome::Restoring, None, &[], 16);
        assert_eq!(step, Step::Refuse);
        assert_eq!(minted, None);
    }

    #[test]
    fn a_window_that_cannot_be_restored_is_refused_rather_than_streamed_black() {
        let (step, _) = drive(DeminiaturizeOutcome::Failed, Some(frame(10.0, 10.0)), &[], 16);
        assert_eq!(step, Step::Refuse);
    }

    /// The permanent-crop failure the settle gate exists to prevent.
    #[test]
    fn a_mid_animation_frame_never_mints_the_capture_size() {
        let restore = [
            Some(frame(62.0, 136.0)),  // the Dock animation, mid-flight
            Some(frame(757.0, 423.0)), // still overshooting
            Some(frame(656.0, 422.0)), // the real size, once
            Some(frame(656.0, 422.0)), // and again — settled
        ];
        let (step, minted) = drive(
            DeminiaturizeOutcome::Restoring,
            Some(frame(656.0, 422.0)),
            &restore,
            16,
        );
        assert_eq!(step, Step::MintSighted);
        assert_eq!(minted, Some(frame(656.0, 422.0)));
    }

    /// A restore that never lands still has to mint something usable.
    #[test]
    fn a_budget_overrun_falls_back_to_the_last_sighting() {
        // Every sighting reports a different frame, so it never settles.
        let never_settles: Vec<Option<Frame>> = (1..=20_u32)
            .map(|step| Some(frame(f64::from(step), f64::from(step))))
            .collect();
        let (step, minted) = drive(
            DeminiaturizeOutcome::Restoring,
            Some(frame(656.0, 422.0)),
            &never_settles,
            16,
        );
        assert_eq!(step, Step::MintSighted);
        assert_eq!(
            minted,
            Some(frame(16.0, 16.0)),
            "the poll budget, and not one more"
        );
    }

    #[test]
    fn a_window_never_sighted_on_screen_falls_back_to_the_full_list_handle() {
        let (step, minted) = drive(
            DeminiaturizeOutcome::Restoring,
            Some(frame(656.0, 422.0)),
            &[None],
            16,
        );
        assert_eq!(step, Step::MintTarget);
        assert_eq!(
            minted,
            Some(frame(656.0, 422.0)),
            "the pre-minimize handle is what the window restores to"
        );
    }

    /// An other-desktop window never joins the on-screen list, so its gate must read the full one.
    #[test]
    fn an_other_desktop_window_settles_against_the_full_enumeration() {
        let mut rescue = begin(16);
        assert_eq!(next_step(&rescue), Step::FullList);
        assert_eq!(
            advance(&mut rescue, Observation::Sighted(frame(656.0, 422.0))),
            Step::Deminiaturize
        );
        assert_eq!(
            advance(
                &mut rescue,
                Observation::Deminiaturized(DeminiaturizeOutcome::NotMinimized)
            ),
            Step::PollFull,
            "the on-screen list would never see it at all"
        );
    }

    #[test]
    fn a_failed_enumeration_mid_poll_is_skipped_rather_than_counted_as_a_sighting() {
        let restore = [
            Some(frame(656.0, 422.0)),
            None, // the enumeration failed this poll
            Some(frame(656.0, 422.0)),
        ];
        let (step, minted) = drive(
            DeminiaturizeOutcome::Restoring,
            Some(frame(656.0, 422.0)),
            &restore,
            16,
        );
        assert_eq!(step, Step::MintSighted);
        assert_eq!(
            minted,
            Some(frame(656.0, 422.0)),
            "the two agreeing sightings straddle the failure"
        );
    }

    #[test]
    fn an_answer_to_a_question_that_was_not_asked_refuses_rather_than_minting() {
        let mut rescue = begin(16);
        assert_eq!(
            advance(
                &mut rescue,
                Observation::Deminiaturized(DeminiaturizeOutcome::Restoring)
            ),
            Step::Refuse,
            "the first step asked for an enumeration"
        );
        // And the answer does not change under a later, well-formed observation.
        assert_eq!(
            advance(&mut rescue, Observation::Sighted(frame(1.0, 1.0))),
            Step::Refuse
        );
        assert!(is_finished(&rescue));
    }

    #[test]
    fn a_rescue_with_no_poll_budget_mints_the_handle_it_already_has() {
        let (step, minted) = drive(
            DeminiaturizeOutcome::Restoring,
            Some(frame(656.0, 422.0)),
            &[Some(frame(62.0, 136.0))],
            0,
        );
        assert_eq!(step, Step::MintTarget);
        assert_eq!(minted, Some(frame(656.0, 422.0)));
    }

    #[test]
    fn a_step_names_the_stage_it_came_from_so_nothing_else_has_to_cross() {
        for step in [
            Step::FullList,
            Step::Deminiaturize,
            Step::PollFull,
            Step::PollOnScreen,
            Step::Refuse,
            Step::MintTarget,
            Step::MintSighted,
        ] {
            let rescue = Rescue {
                stage: stage_of(step),
                polls_left: 4,
                prior: None,
            };
            assert_eq!(next_step(&rescue), step, "{step:?}");
        }
    }
}
