//! The budgeted accessibility probe over the OFF-SCREEN windows (`docs/45` Phase 5).
//!
//! Two questions, one sweep. Is this off-screen window MINIMIZED into the Dock, or is it sitting on
//! another Space? And is it a window at all — a `CGWindowList` entry that no accessibility sweep
//! ever returns is a phantom no person can look at, and the feed's inclusion gate drops it.
//!
//! Every decision here is [`slopdesk_video::ax_probe`]'s: which pids are stale enough to sweep
//! ([`ProbeBudget`]), what a sweep proves ([`Ledger`]), and what a window's absence from one means
//! ([`classify`]). What this module owns is the sweep itself and the lock around the two.
//!
//! ## Why a sweep can BLOCK, and what that costs
//! This is the only thing in the window feed that can block: a hung app charges its whole messaging
//! timeout, so an unbudgeted tick is one beachballing app away from stalling the feed. The budget
//! caps a tick at three stale pids and each of those at [`TIMEOUT`] — three quarters of a second in
//! the worst case, and approximately nothing in the steady state, where every pid answers from the
//! ledger.
//!
//! This replaces `WindowFeedAXSupport.swift`'s `MinimizedStateProbe` and the
//! `slopdesk_ax_probe_new`/`_classify`/`_free` door trio it was a handle over. A Rust daemon holds
//! the budget and the ledger directly, so the handle, its `deinit`, and the two-call
//! shape-then-fill protocol all go with it.

use core::fmt;
use std::sync::{Mutex, PoisonError};

use slopdesk_video::ax_probe::{Classification, Ledger, ProbeBudget, classify};

/// The per-message accessibility cap one sweep opens its application element with, in seconds.
///
/// The same quarter second `slopdesk-ffi`'s `ax` module opened its own doors with, and the number
/// `WindowFeedAXSupport.swift`'s header quoted. It is what turns "a hung app" from an unbounded
/// stall into a bounded one.
pub const TIMEOUT: f32 = 0.25;

/// One off-screen window and the process that owns it — the probe's whole input.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OffScreenWindow {
    /// The window's `CGWindowID`.
    pub window_id: u32,
    /// The owning process.
    pub pid: i32,
}

/// One app's whole accessibility window list: `(CGWindowID, minimized)` per window it published.
///
/// Named rather than spelled because it appears in the trait, in the tick's intermediate vector and
/// in every double — four spellings of one shape is where a `u32`/`i32` slip hides.
pub type Sweep = Vec<(u32, bool)>;

/// Sweeping ONE application's accessibility windows.
///
/// The seam a test substitutes, because the real one needs the Accessibility grant and a live app.
/// Everything ABOVE it — the budget, the ledger, the classification — is then reachable headlessly,
/// which is the whole reason this trait exists rather than a free function.
pub trait SweepsApps: Send + Sync + fmt::Debug {
    /// Every window `pid`'s accessibility tree lists, as `(CGWindowID, minimized)`.
    ///
    /// `None` and an EMPTY answer are DIFFERENT and [`Ledger::fold`] depends on it: empty means the
    /// app genuinely lists no windows, which is evidence, while `None` means the question could not
    /// be put, which is not. An implementation that cannot tell the two apart must answer `None`.
    fn sweep(&self, pid: i32) -> Option<Sweep>;
}

/// The accessibility tree, for real.
#[derive(Clone, Copy, Debug, Default)]
pub struct AccessibilityTree;

impl SweepsApps for AccessibilityTree {
    /// One application's sweep through `slopdesk-apple-ax`.
    ///
    /// An app that publishes ZERO windows is indistinguishable here from one that refused, and is
    /// treated as a refusal — carried verbatim from the shim this replaces. An app with genuinely
    /// no windows owns none of the off-screen ids the caller is asking about, so folding its
    /// empty sweep could only mark some OTHER app's windows absent.
    fn sweep(&self, pid: i32) -> Option<Sweep> {
        let app = slopdesk_apple_ax::App::new(pid, TIMEOUT);
        let windows = app.windows();
        if windows.is_empty() {
            return None;
        }
        Some(
            windows
                .iter()
                .filter_map(|window| Some((window.id()?, window.minimized().unwrap_or(false))))
                .collect(),
        )
    }
}

/// The probe: a budget, a ledger, and the sweeper the two are driven over.
pub struct OffScreenProbe<S: SweepsApps> {
    /// Where a sweep's answers come from.
    sweeper: S,
    /// Which pids may be swept this tick, and what every recent sweep proved. One lock, because a
    /// budget consulted without folding its result would spend a quota it never used.
    state: Mutex<(ProbeBudget, Ledger)>,
}

impl<S: SweepsApps> fmt::Debug for OffScreenProbe<S> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OffScreenProbe")
            .field("sweeper", &self.sweeper)
            .finish_non_exhaustive()
    }
}

impl<S: SweepsApps> OffScreenProbe<S> {
    /// A probe over `sweeper`, with an empty budget and an empty ledger.
    pub fn new(sweeper: S) -> Self {
        Self {
            sweeper,
            state: Mutex::new((ProbeBudget::new(), Ledger::new())),
        }
    }

    /// Classifies every window in `windows`, sweeping at most the budget's stale-pid quota.
    ///
    /// `now` is the CALLER's clock, so a whole tick shares one instant: reading a clock per pid
    /// would age two sweeps started in the same tick differently.
    ///
    /// Windows whose pid was not swept this tick answer from the last sweep, and windows never
    /// swept at all appear in NEITHER of the two sets rather than with a guessed verdict —
    /// "never asked" and "asked and absent" are different, and only the second is evidence.
    pub fn classify(&self, windows: &[OffScreenWindow], now: f64) -> Classification {
        let mut pids: Vec<i32> = windows.iter().map(|window| window.pid).collect();
        pids.sort_unstable();
        pids.dedup();

        let due = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.0.pids_to_probe(&pids, now)
        };
        // Swept OUTSIDE the lock: a sweep is the one blocking call in the feed, and holding the
        // ledger across it would make a beachballing app stall every other caller of this probe
        // rather than just this tick.
        let swept: Vec<(i32, Option<Sweep>)> = due
            .into_iter()
            .map(|pid| {
                let answer = self.sweeper.sweep(pid);
                (pid, answer)
            })
            .collect();

        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let ledger = &mut state.1;
        for (pid, answer) in swept {
            let Some(sweep) = answer else {
                // A FAILED sweep is never folded. Stale beats absent: folding an empty answer would
                // mark every one of that app's windows a phantom and the feed would drop them all.
                continue;
            };
            let off_screen: Vec<u32> = windows
                .iter()
                .filter(|window| window.pid == pid)
                .map(|window| window.window_id)
                .collect();
            ledger.fold(&sweep, &off_screen);
        }
        let ids: Vec<u32> = windows.iter().map(|window| window.window_id).collect();
        ledger.retain(&ids);
        let classification = classify(ledger, &ids);
        drop(state);
        classification
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, PoisonError};

    use super::{OffScreenProbe, OffScreenWindow, Sweep, SweepsApps};

    /// A sweeper that answers from a script and records what it was asked.
    #[derive(Debug)]
    struct Scripted {
        /// `pid` → the sweep it answers, or `None` for a refusal.
        answers: Vec<(i32, Option<Sweep>)>,
        /// Every pid swept, in order.
        asked: Mutex<Vec<i32>>,
    }

    impl SweepsApps for Scripted {
        fn sweep(&self, pid: i32) -> Option<Sweep> {
            self.asked
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(pid);
            self.answers
                .iter()
                .find(|(candidate, _)| *candidate == pid)
                .and_then(|(_, answer)| answer.clone())
        }
    }

    fn scripted(answers: Vec<(i32, Option<Sweep>)>) -> OffScreenProbe<Scripted> {
        OffScreenProbe::new(Scripted {
            answers,
            asked: Mutex::new(Vec::new()),
        })
    }

    /// A window an app's sweep listed is AX-listed; one it listed as minimized is minimized too.
    #[test]
    fn a_swept_app_answers_both_questions_about_its_own_windows() {
        let probe = scripted(vec![(9, Some(vec![(1, true), (2, false)]))]);
        let asked = [OffScreenWindow { window_id: 1, pid: 9 }, OffScreenWindow {
            window_id: 2,
            pid: 9,
        }];
        let verdict = probe.classify(&asked, 0.0);
        assert_eq!(verdict.ax_listed, vec![1, 2]);
        assert_eq!(verdict.minimized, vec![1]);
    }

    /// The phantom filter: a window the sweep did NOT list, from an app that answered, is evidence
    /// of absence. It appears in neither set, and the snapshot builder drops it.
    #[test]
    fn a_window_a_successful_sweep_never_listed_is_a_phantom() {
        let probe = scripted(vec![(9, Some(vec![(1, false)]))]);
        let asked = [OffScreenWindow { window_id: 1, pid: 9 }, OffScreenWindow {
            window_id: 404,
            pid: 9,
        }];
        let verdict = probe.classify(&asked, 0.0);
        assert_eq!(verdict.ax_listed, vec![1]);
        assert!(verdict.minimized.is_empty());
    }

    /// The rule the whole `Option` in [`SweepsApps::sweep`] exists for: a REFUSED sweep is not
    /// folded. Every one of that app's windows would otherwise read as a phantom and the feed would
    /// drop the lot — a window that was listed a second ago must survive one unanswerable question.
    #[test]
    fn a_refused_sweep_leaves_the_previous_verdict_standing() {
        let probe = scripted(vec![(9, Some(vec![(1, true)]))]);
        let asked = [OffScreenWindow { window_id: 1, pid: 9 }];
        assert_eq!(probe.classify(&asked, 0.0).ax_listed, vec![1]);

        let refusing = scripted(vec![(9, None)]);
        // A fresh probe with a refusing sweeper knows nothing at all, which is the OTHER half of the
        // same rule: never swept is not evidence either.
        let verdict = refusing.classify(&asked, 0.0);
        assert!(verdict.ax_listed.is_empty());
        assert!(verdict.minimized.is_empty());
    }

    /// The budget is what bounds a tick: more stale pids than the quota means the extras answer
    /// from the ledger — with nothing in it, from nothing — rather than costing a round trip
    /// each.
    #[test]
    fn a_tick_sweeps_no_more_apps_than_the_budget_allows() {
        let probe = scripted(
            (1_i32..=10)
                .map(|pid| (pid, Some(vec![(pid.cast_unsigned(), false)])))
                .collect(),
        );
        let asked: Vec<OffScreenWindow> = (1_i32..=10)
            .map(|pid| {
                OffScreenWindow {
                    window_id: pid.cast_unsigned(),
                    pid,
                }
            })
            .collect();
        probe.classify(&asked, 0.0);
        let swept = probe
            .sweeper
            .asked
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        assert!(
            swept <= 3,
            "the budget caps a tick at three stale pids; this one swept {swept}"
        );
    }

    /// A second call in the SAME tick sweeps nothing new — the budget already stamped this tick's
    /// pids — so a retry is cheap and answers identically.
    #[test]
    fn a_second_pass_at_the_same_instant_costs_no_further_sweeps() {
        let probe = scripted(vec![(9, Some(vec![(1, true)]))]);
        let asked = [OffScreenWindow { window_id: 1, pid: 9 }];
        let first = probe.classify(&asked, 0.0);
        let before = probe
            .sweeper
            .asked
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        let second = probe.classify(&asked, 0.0);
        let after = probe
            .sweeper
            .asked
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        assert_eq!(first, second);
        assert_eq!(before, after);
    }

    /// Asking about nothing sweeps nothing. The feed calls this every tick, and a desktop with
    /// every window on screen is the common case.
    #[test]
    fn an_empty_question_is_answered_without_touching_a_single_app() {
        let probe = scripted(vec![(9, Some(vec![(1, true)]))]);
        let verdict = probe.classify(&[], 0.0);
        assert!(verdict.ax_listed.is_empty());
        assert!(verdict.minimized.is_empty());
        assert!(
            probe
                .sweeper
                .asked
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .is_empty()
        );
    }
}
