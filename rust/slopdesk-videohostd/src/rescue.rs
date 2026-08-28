//! MINT-TIME RESCUE for an off-screen window pick: un-minimize the target, wait for the restore to
//! SETTLE, and hand back the handle to mint from.
//!
//! Replaces the Swift host's off-screen window mint rescue and the `rescueOffScreenWindow(_:)`
//! call site in the Swift daemon's `main`.
//!
//! ## The problem, in one paragraph
//! The host-windows rail (`docs/45`) offers MINIMIZED windows and windows on another Space, but the
//! mint path resolves a hello's `requestedWindowID` against `ScreenCaptureKit`'s ON-SCREEN
//! enumeration, which can never contain either. Picking one would bounce the pane straight back to
//! the picker. So: find the target in the FULL enumeration, un-minimize it through accessibility
//! when that is what hides it — `WindowServer` never paints a minimized window, so capturing one
//! streams nothing — and only then mint.
//!
//! ## Why the settle gate is load-bearing
//! Capture size is locked from the minted handle's frame, and the Dock restore reports intermediate
//! animation frames with `isOnScreen == true`. Hardware-measured on a 656×422 window: 62×136 →
//! 757×423 → 656×422 over about 550 ms. Minting a mid-animation handle crops the stream to a
//! top-left sliver of the real window PERMANENTLY, because the geometry watcher installs only after
//! the mint and nothing re-targets. The two-identical-frames gate is what stops that.
//!
//! ## What this module OWNS versus what it ASKS for
//! It owns EFFECTS and nothing else: two enumerations, an accessibility write, a sleep, and the two
//! window handles that could be minted. Every decision — whether to poll the on-screen list or the
//! full one, whether a frame has settled, how many polls are left, and whether to refuse — is
//! [`slopdesk_video::mint_rescue`]'s, which is `forbid(unsafe_code)` and fully tested there.
//!
//! ## Why it is a step protocol and not a set of callbacks
//! The decision tree names ONE step at a time and this loop performs it, rather than the tree
//! taking closures. The Swift needed that because every effect suspended and no C ABI can call back
//! into an `async` closure and wait. Rust has no such constraint, and the shape is kept anyway for
//! a better reason: the two mintable handles are `SCWindow`s and have no business crossing into a
//! rule crate that must stay window-server-free. The far side names WHICH handle, never which one.
//!
//! ## Threading
//! [`run`] is SYNCHRONOUS and BLOCKS — up to `poll_attempts` × [`POLL_INTERVAL`], so about two
//! seconds at the default budget, plus two `ScreenCaptureKit` enumerations per poll. ⚠️ It must run
//! on the mint's own worker thread, never on the thread that services the run loop and never on a
//! send lane: a pane that is already streaming must not stall while a sibling's window is being
//! rescued.
//!
//! ## What is untestable by design
//! [`ShareableWindows`] reaches `ScreenCaptureKit` and the accessibility tree, so it needs a window
//! server, a Screen-Recording grant AND an Accessibility grant. ⚠️ It cannot run under a test. The
//! DRIVER is what the `#[cfg(test)] mod tests` below covers, through a scripted fake — the loop's
//! handle bookkeeping, the sleep-before-every-poll ordering, and which of the two handles each
//! terminal step mints, which is the half that could be wrong.

use core::fmt;
use std::thread;
use std::time::Duration;

use slopdesk_apple_sck::ShareableContent;
use slopdesk_video::mint_rescue::{self, DeminiaturizeOutcome, Frame, Observation, Step};

use crate::windowplace::{AccessibilityTree, Deminiaturized};

/// How many polls a rescue may spend waiting for a restore's frame to stop moving.
///
/// Sixteen at [`POLL_INTERVAL`] is two seconds, against a measured restore of about 550 ms. The
/// margin is deliberate: the budget is not a deadline for the animation but for a window that will
/// NEVER settle — an app repainting on a timer — and running out mints the last sighting rather
/// than refusing, so a generous budget costs a slow mint and a tight one costs a cropped stream.
pub const POLL_ATTEMPTS: u32 = 16;

/// The wait before every poll.
///
/// One sleep per poll, taken BEFORE the enumeration rather than after: the accessibility write that
/// starts the restore needs time to paint, and an enumeration taken in the same instant it returned
/// reports the pre-restore frame, which would satisfy the two-identical-frames gate against a frame
/// the window is about to leave.
pub const POLL_INTERVAL: Duration = Duration::from_millis(125);

/// The four effects a rescue needs, and nothing else.
///
/// A trait rather than four closures so the concrete host implementation is one named type whose
/// `ScreenCaptureKit` and accessibility edges are visible in one place, and so a test can supply a
/// scripted one without a window server. The associated window type is the caller's: this module
/// never looks inside a handle, it only decides which one comes back.
pub trait Rescues: fmt::Debug {
    /// The handle a mint is built from. `SCWindow` in the live path.
    type Window;

    /// Enumerates EVERY window — minimized ones and those on another Space included — and answers
    /// the target's handle.
    ///
    /// A failed enumeration and one that simply lacks the window are the SAME answer, `None`:
    /// nothing was seen. Collapsing them here is what lets the decision tree treat a missed poll as
    /// a skip rather than as evidence the window is gone.
    fn full_list(&self, window_id: u32) -> Option<Self::Window>;

    /// Enumerates the ON-SCREEN windows and answers the target's handle, under the same rule.
    fn on_screen_list(&self, window_id: u32) -> Option<Self::Window>;

    /// The handle's frame, four numbers the decision tree compares for equality and never
    /// interprets.
    fn frame(&self, window: &Self::Window) -> Frame;

    /// Un-minimizes the handle and answers what the attempt found.
    fn deminiaturize(&self, window: &Self::Window) -> DeminiaturizeOutcome;

    /// Waits one poll interval.
    fn wait(&self);
}

/// Rescues `window_id` after the on-screen enumeration missed it, and answers the handle to mint
/// from.
///
/// `None` means the window is truly gone or stays hidden, and the caller's terminal refusal stands
/// — the client falls back to the picker rather than streaming black.
///
/// The loop holds TWO handles near-side. `target` is whatever the FIRST full enumeration produced;
/// its frame is the pre-minimize one, which is exactly what the window restores to, so it is the
/// right handle when nothing was ever sighted afterwards. `sighted` is the MOST RECENT poll's, and
/// it is the right handle once a frame has settled. The decision tree names which; it never sees
/// either.
///
/// ⚠️ BLOCKS. See the module's threading note.
#[must_use]
pub fn run<E: Rescues>(effects: &E, window_id: u32, poll_attempts: u32) -> Option<E::Window> {
    let mut rescue = mint_rescue::begin(poll_attempts);
    let mut target: Option<E::Window> = None;
    let mut sighted: Option<E::Window> = None;
    let mut step = mint_rescue::next_step(&rescue);

    loop {
        match step {
            Step::FullList => {
                let seen = effects.full_list(window_id);
                let observation = observe(effects, seen.as_ref());
                target = seen;
                step = mint_rescue::advance(&mut rescue, observation);
            },
            Step::Deminiaturize => {
                // The step is only ever named after a sighting, so there IS a target to flip. An
                // absent one is refused rather than assumed away — the same terminal answer, taken
                // where the reason for it is still legible.
                let found = target.as_ref()?;
                let outcome = effects.deminiaturize(found);
                step = mint_rescue::advance(&mut rescue, Observation::Deminiaturized(outcome));
            },
            Step::PollFull | Step::PollOnScreen => {
                effects.wait();
                let seen = if matches!(step, Step::PollOnScreen) {
                    effects.on_screen_list(window_id)
                } else {
                    effects.full_list(window_id)
                };
                let observation = observe(effects, seen.as_ref());
                // Only a sighting replaces the handle. A missed poll leaves the last good one in
                // place, because the rescue may still finish on it.
                if seen.is_some() {
                    sighted = seen;
                }
                step = mint_rescue::advance(&mut rescue, observation);
            },
            Step::MintTarget => return target,
            // Unreachable with `sighted` empty by construction — the step is only named after a
            // sighting, or after a poll budget that a sighting filled. `None` here would mean the
            // decision tree changed, and answering it is the caller's refusal, not a panic.
            Step::MintSighted => return sighted,
            Step::Refuse => return None,
        }
    }
}

/// Turns "what an enumeration showed" into the one observation the decision tree accepts.
fn observe<E: Rescues>(effects: &E, seen: Option<&E::Window>) -> Observation {
    seen.map_or(Observation::Missed, |window| {
        Observation::Sighted(effects.frame(window))
    })
}

/// The live effects: `ScreenCaptureKit` for both enumerations, the accessibility tree for the
/// un-minimize, and a real sleep.
///
/// ⚠️ Requires a window server, a Screen-Recording grant and an Accessibility grant. Every method
/// here fails SOFT — a refused enumeration is a missed poll, and a window with no owning process is
/// a failed un-minimize — so a missing grant costs the rescue, never the daemon.
#[derive(Clone, Copy, Debug, Default)]
pub struct ShareableWindows;

impl ShareableWindows {
    /// One enumeration, filtered to the target.
    ///
    /// `exclude_desktop_windows` is `false` on BOTH arms, matching the mint path's own query: the
    /// rescue must be able to see a window the picker offered, and the picker's list is the
    /// unfiltered one.
    fn lookup(window_id: u32, on_screen_only: bool) -> Option<slopdesk_apple_sck::Window> {
        ShareableContent::current(false, on_screen_only)?.window(window_id)
    }
}

impl Rescues for ShareableWindows {
    type Window = slopdesk_apple_sck::Window;

    fn full_list(&self, window_id: u32) -> Option<Self::Window> {
        Self::lookup(window_id, false)
    }

    fn on_screen_list(&self, window_id: u32) -> Option<Self::Window> {
        Self::lookup(window_id, true)
    }

    fn frame(&self, window: &Self::Window) -> Frame {
        let rect = window.frame();
        Frame {
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
        }
    }

    /// Resolves the window in the accessibility tree by its owning pid and flips `AXMinimized`.
    ///
    /// A window `ScreenCaptureKit` lists but that reports no owning process cannot be reached
    /// through accessibility at all, which is a failure and not a "not minimized" — reporting the
    /// latter would send the rescue into a settle poll for a window it can never restore.
    fn deminiaturize(&self, window: &Self::Window) -> DeminiaturizeOutcome {
        let Some(pid) = window.owner_pid() else {
            return DeminiaturizeOutcome::Failed;
        };
        match crate::windowplace::deminiaturize(&AccessibilityTree, window.id(), pid) {
            Deminiaturized::NotMinimized => DeminiaturizeOutcome::NotMinimized,
            Deminiaturized::Restoring => DeminiaturizeOutcome::Restoring,
            Deminiaturized::Failed => DeminiaturizeOutcome::Failed,
        }
    }

    fn wait(&self) {
        thread::sleep(POLL_INTERVAL);
    }
}

/// Rescues `window_id` through the live effects, at the default poll budget.
///
/// The one-line seam the mint path calls, so a call site does not have to name
/// [`ShareableWindows`] or [`POLL_ATTEMPTS`] to get the standard behaviour.
///
/// ⚠️ BLOCKS, and needs all three grants. See the module's threading note.
#[must_use]
pub fn rescue_off_screen_window(window_id: u32) -> Option<slopdesk_apple_sck::Window> {
    run(&ShareableWindows, window_id, POLL_ATTEMPTS)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a rescue that answers nothing is the failure this test reports, and a panic in a test is \
                  the failure report"
    )]

    use core::cell::RefCell;

    use slopdesk_video::mint_rescue::{DeminiaturizeOutcome, Frame};

    use super::{Rescues, run};

    /// One window handle, distinguishable so a test can tell WHICH of the two the driver minted.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct Handle(u32);

    /// A scripted set of effects: each enumeration answers the next frame in its queue, and every
    /// call is recorded so the ORDER — a wait before every poll, never before the first list — can
    /// be asserted rather than assumed.
    #[derive(Debug)]
    struct Script {
        full: RefCell<Vec<Option<Frame>>>,
        on_screen: RefCell<Vec<Option<Frame>>>,
        outcome: DeminiaturizeOutcome,
        log: RefCell<Vec<&'static str>>,
        next_handle: RefCell<u32>,
    }

    impl Script {
        fn new(
            full: Vec<Option<Frame>>,
            on_screen: Vec<Option<Frame>>,
            outcome: DeminiaturizeOutcome,
        ) -> Self {
            Self {
                full: RefCell::new(full),
                on_screen: RefCell::new(on_screen),
                outcome,
                log: RefCell::new(Vec::new()),
                next_handle: RefCell::new(0),
            }
        }

        /// Pops the next scripted answer, minting a fresh handle id for each sighting so the test
        /// can name the handle the driver kept.
        fn pop(&self, queue: &RefCell<Vec<Option<Frame>>>) -> Option<(Handle, Frame)> {
            let mut queue = queue.borrow_mut();
            let frame = if queue.is_empty() { None } else { queue.remove(0) };
            frame.map(|frame| {
                let mut next = self.next_handle.borrow_mut();
                *next += 1;
                (Handle(*next), frame)
            })
        }
    }

    impl Rescues for Script {
        type Window = (Handle, Frame);

        fn full_list(&self, _window_id: u32) -> Option<Self::Window> {
            self.log.borrow_mut().push("full");
            self.pop(&self.full)
        }

        fn on_screen_list(&self, _window_id: u32) -> Option<Self::Window> {
            self.log.borrow_mut().push("on_screen");
            self.pop(&self.on_screen)
        }

        fn frame(&self, window: &Self::Window) -> Frame {
            window.1
        }

        fn deminiaturize(&self, _window: &Self::Window) -> DeminiaturizeOutcome {
            self.log.borrow_mut().push("deminiaturize");
            self.outcome
        }

        fn wait(&self) {
            self.log.borrow_mut().push("wait");
        }
    }

    const fn frame(width: f64) -> Frame {
        Frame {
            x: 0.0,
            y: 0.0,
            width,
            height: 100.0,
        }
    }

    #[test]
    fn a_window_missing_from_the_full_list_is_refused_without_any_effect() {
        // Nothing to un-minimize and nothing to mint: the caller's refusal stands and the picker
        // is where the client goes.
        let script = Script::new(vec![None], Vec::new(), DeminiaturizeOutcome::Restoring);
        assert!(run(&script, 7, 16).is_none());
        assert_eq!(*script.log.borrow(), vec!["full"]);
    }

    #[test]
    fn a_window_that_cannot_be_restored_is_refused_rather_than_minted_black() {
        let script = Script::new(vec![Some(frame(600.0))], Vec::new(), DeminiaturizeOutcome::Failed);
        assert!(run(&script, 7, 16).is_none());
        assert_eq!(*script.log.borrow(), vec!["full", "deminiaturize"]);
    }

    #[test]
    fn a_restore_mints_the_sighting_only_once_two_polls_agree() {
        // The measured Dock animation: two moving frames, then the settled one twice. The mid-
        // animation sizes must NOT be minted — that is the permanent crop this gate exists for.
        let script = Script::new(
            vec![Some(frame(656.0))],
            vec![
                Some(frame(62.0)),
                Some(frame(757.0)),
                Some(frame(656.0)),
                Some(frame(656.0)),
            ],
            DeminiaturizeOutcome::Restoring,
        );
        let minted = run(&script, 7, 16).expect("a settled restore mints its sighting");
        assert_eq!(
            minted.1,
            frame(656.0),
            "the minted handle carries the SETTLED frame, not an animation step"
        );
        assert_eq!(
            *script.log.borrow(),
            vec![
                "full",
                "deminiaturize",
                "wait",
                "on_screen",
                "wait",
                "on_screen",
                "wait",
                "on_screen",
                "wait",
                "on_screen",
            ],
            "one wait before EVERY poll, and none before the first enumeration"
        );
    }

    #[test]
    fn a_window_on_another_space_settles_against_the_full_list() {
        // `NotMinimized` means another Space, where the window never joins the on-screen list — so
        // polling it would time out on every attempt.
        let script = Script::new(
            vec![Some(frame(400.0)), Some(frame(400.0)), Some(frame(400.0))],
            Vec::new(),
            DeminiaturizeOutcome::NotMinimized,
        );
        assert!(run(&script, 7, 16).is_some());
        assert_eq!(*script.log.borrow(), vec![
            "full",
            "deminiaturize",
            "wait",
            "full",
            "wait",
            "full"
        ]);
    }

    #[test]
    fn a_missed_poll_is_skipped_rather_than_counted_as_a_sighting() {
        // An enumeration that fails mid-restore must not reset the settle gate NOR end the rescue:
        // it spends a poll and the next one carries on from the last real sighting.
        let script = Script::new(
            vec![Some(frame(300.0))],
            vec![Some(frame(300.0)), None, Some(frame(300.0))],
            DeminiaturizeOutcome::Restoring,
        );
        let minted = run(&script, 7, 16).expect("the settle gate survives a missed poll");
        assert_eq!(minted.1, frame(300.0));
    }

    #[test]
    fn a_window_that_never_settles_mints_the_last_sighting_when_the_budget_runs_out() {
        // An app repainting on a timer never shows the same frame twice. Running out mints the
        // closest thing to settled there is rather than refusing a window that IS visible.
        let script = Script::new(
            vec![Some(frame(10.0))],
            vec![Some(frame(11.0)), Some(frame(12.0)), Some(frame(13.0))],
            DeminiaturizeOutcome::Restoring,
        );
        let minted = run(&script, 7, 2).expect("an unsettled restore still mints");
        assert_eq!(
            minted.1,
            frame(12.0),
            "the LAST sighting inside the budget, not the pre-minimize handle"
        );
    }

    #[test]
    fn a_restore_that_is_never_sighted_mints_the_pre_minimize_handle() {
        // Every poll missed, so there is no sighting to mint. The first full enumeration's handle
        // carries the PRE-minimize frame, which is exactly what the window restores to.
        let script = Script::new(
            vec![Some(frame(500.0))],
            vec![None, None, None],
            DeminiaturizeOutcome::Restoring,
        );
        let minted = run(&script, 7, 2).expect("the pre-minimize handle is the fallback");
        assert_eq!(minted.0, Handle(1), "the FIRST handle, not a later one");
        assert_eq!(minted.1, frame(500.0));
    }
}
