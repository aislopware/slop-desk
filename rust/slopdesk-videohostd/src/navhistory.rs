//! Can the frontmost app go back and forward — the swipe-nav chip's one live read.
//!
//! ## What it replaces
//! `HostNavHistory.swift`, and `slopdesk-ffi`'s `nav_history` — the handle that joined the two
//! crates below for that Swift face. The Swift carried a standing warning that no unit test could
//! reach it: every reading is blocking out-of-process accessibility IPC against a live browser,
//! which is the same hang-safety rule that keeps `SCStream` and `VideoToolbox` out of the suite.
//! What rode along under that warning was not the IPC. It was two element-matching rules, two walk
//! bounds, a per-window currency rule and a cache with three states — none of which needs a browser
//! to be true, and all of which are [`slopdesk_video::nav_history`]'s, with thirteen tests.
//!
//! Two crates meet here, so the join is in the daemon rather than in either of them:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | `slopdesk-apple-ax` | the elements, their attributes, and the bounded walk over them |
//! | [`slopdesk_video::nav_history`] | which node counts, how far to look, when to trust a cached pair |
//! | this module | the order the two are asked in, and what is remembered between beats |
//!
//! ## Why a handle rather than a function
//! A full scan is 25–180 ms of blocking IPC on a cold browser and a cached re-read is about
//! 0.05 ms, so the pair has to survive between beats — and [`crate::navstatus`] polls at 4 Hz. A
//! stateless door would pay the scan every quarter second for every frontmost browser. The reader
//! holds the pair, and [`slopdesk_video::nav_history::Cache`] holds the rules about when it may
//! still be believed.
//!
//! ## Why it is its own module and not part of the kicker
//! Because it has a second caller. `rust/slopdesk-navprobe` drives this reader against a live
//! browser precisely because a suite cannot, and a probe that had to construct a kicker — a thread,
//! a registry, a fan-out — to reach one `read` would be proving the wiring rather than the reader.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use slopdesk_apple_ax::{App, Element, Step, Window, walk};
use slopdesk_video::nav_history::{
    Cache, Direction, Flags, MENU_MAX_DEPTH, MENU_NODE_BUDGET, MESSAGE_TIMEOUT, Plan, SCAN_DEADLINE,
    Strategy, TOOLBAR_MAX_DEPTH, TOOLBAR_NODE_BUDGET, fold, menu_visit, toolbar_visit,
};

/// The two controls a reading is taken from, and the window they belong to.
#[derive(Debug)]
struct Pair {
    /// The Back control.
    back: Element,
    /// The Forward control.
    forward: Element,
    /// The window a TOOLBAR pair was scanned from, `None` for a menu pair.
    ///
    /// This is what a currency check compares against, and it is the field the whole per-window
    /// rule exists for: a toolbar pair from window A keeps answering successfully after focus moves
    /// to window B of the same app — no error, just A's history served as B's.
    window: Option<Window>,
}

/// Everything one reader remembers between beats.
#[derive(Debug, Default)]
struct State {
    /// Which pid is held and how, and which one already scanned empty.
    cache: Cache,
    /// The elements themselves, when a pair is held.
    pair: Option<Pair>,
}

impl State {
    /// Re-read both controls. `None` when either read fails — see `nav_history::fold`.
    fn read_pair(&self) -> Option<Flags> {
        let pair = self.pair.as_ref()?;
        fold(pair.back.enabled(), pair.forward.enabled())
    }

    /// Whether a held toolbar pair still belongs to the window that would receive the chord.
    ///
    /// A failed focused-window read fails the check rather than passing it: the rescan that follows
    /// lands on whatever is true now, or collapses to unknown, and both are better than serving a
    /// window's history as another window's.
    fn pair_is_current(&self, pid: i32) -> bool {
        let Some(window) = self.pair.as_ref().and_then(|pair| pair.window.as_ref()) else {
            return true;
        };
        App::new(pid, MESSAGE_TIMEOUT)
            .focused_or_first_window()
            .is_some_and(|focused| focused == *window)
    }

    /// Walk for a pair and read it, recording what was learnt either way.
    fn scan(&mut self, pid: i32) -> Option<Flags> {
        let app = App::new(pid, MESSAGE_TIMEOUT);
        let deadline = Instant::now() + Duration::from_secs_f64(SCAN_DEADLINE);
        // Toolbar first, and the order is not a preference: a toolbar button is what the person
        // SEES grey out, while Safari's autoenabled menus validate lazily and keep serving a
        // background navigation's stale state — stale in the direction that hides a working chip.
        let found = toolbar_pair(&app, deadline)
            .map(|pair| (pair, Strategy::Toolbar))
            .or_else(|| menu_pair(&app, deadline).map(|pair| (pair, Strategy::Menu)));
        let Some((pair, strategy)) = found else {
            self.pair = None;
            self.cache.found_nothing(pid);
            return None;
        };
        self.pair = Some(pair);
        self.cache.hold(pid, strategy);
        self.read_pair()
    }
}

/// The toolbar pair of the window the chord would land in, or `None`.
fn toolbar_pair(app: &App, deadline: Instant) -> Option<Pair> {
    let window = app.focused_or_first_window()?;
    let mut back = None;
    let mut forward = None;
    walk(
        &window.as_element(MESSAGE_TIMEOUT),
        TOOLBAR_MAX_DEPTH,
        TOOLBAR_NODE_BUDGET,
        deadline,
        &mut |node, _| {
            let visit = toolbar_visit(node.role().as_deref(), || node.identifier());
            if visit.prune {
                return Step::Prune;
            }
            match visit.hit {
                Some(Direction::Back) if back.is_none() => back = Some(node.clone()),
                Some(Direction::Forward) if forward.is_none() => forward = Some(node.clone()),
                _ => {},
            }
            if back.is_some() && forward.is_some() {
                Step::Stop
            } else {
                Step::Descend
            }
        },
    );
    Some(Pair {
        back: back?,
        forward: forward?,
        window: Some(window),
    })
}

/// The ⌘[ / ⌘] menu pair, or `None`.
///
/// No window is recorded, because there is nothing to check it against: the items are app-global
/// and Chromium's `CommandUpdater` retargets them to whichever window is active.
fn menu_pair(app: &App, deadline: Instant) -> Option<Pair> {
    let bar = app.menu_bar()?;
    let mut back = None;
    let mut forward = None;
    walk(
        &bar,
        MENU_MAX_DEPTH,
        MENU_NODE_BUDGET,
        deadline,
        &mut |node, _| {
            match menu_visit(node.cmd_char().as_deref(), || node.cmd_modifiers()) {
                Some(Direction::Back) if back.is_none() => back = Some(node.clone()),
                Some(Direction::Forward) if forward.is_none() => forward = Some(node.clone()),
                _ => {},
            }
            if back.is_some() && forward.is_some() {
                Step::Stop
            } else {
                Step::Descend
            }
        },
    );
    Some(Pair {
        back: back?,
        forward: forward?,
        window: None,
    })
}

/// One process's history reader, with its cached pair.
#[derive(Debug)]
pub struct NavHistoryReader {
    /// The pair and the rules about believing it.
    ///
    /// Behind a lock because the status push runs on its own thread and the beat that forces a
    /// rescan can arrive from another: two readings must serialise rather than interleave, or one
    /// would read the pair the other is replacing.
    state: Mutex<State>,
}

impl Default for NavHistoryReader {
    fn default() -> Self {
        Self::new()
    }
}

impl NavHistoryReader {
    /// A reader with an empty cache.
    #[must_use]
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
        }
    }

    /// The current flags for `pid`, or `None` for unknown.
    ///
    /// `rescan_unknown` is the slow heartbeat's permission to retry a pid whose last scan found no
    /// pair. `verify_window` is the same beat's permission to spend one extra round trip confirming
    /// a toolbar pair still belongs to the focused window.
    ///
    /// Blocks on out-of-process IPC, bounded by `slopdesk-apple-ax`'s per-message cap and this
    /// crate's scan deadline — call it off the main thread.
    ///
    /// A poisoned lock answers unknown rather than propagating: the whole gate is fail-open, and
    /// the client's answer to unknown is its pre-gate behaviour.
    #[must_use]
    pub fn read(&self, pid: i32, rescan_unknown: bool, verify_window: bool) -> Option<Flags> {
        let Ok(mut state) = self.state.lock() else {
            return None;
        };
        match state.cache.plan(pid, rescan_unknown, verify_window) {
            Plan::Skip => None,
            Plan::Scan => state.scan(pid),
            Plan::Reuse { verify_currency } => {
                if (!verify_currency || state.pair_is_current(pid))
                    && let Some(flags) = state.read_pair()
                {
                    return Some(flags);
                }
                // Focus moved to a window the pair does not belong to, or an element went stale
                // because its window closed or the app rebuilt its UI. Release rather than record
                // empty — a failed pair says nothing about whether a fresh scan would find one.
                state.cache.release();
                state.pair = None;
                state.scan(pid)
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::NavHistoryReader;

    /// A pid that names no process answers unknown every time and never starts believing itself.
    /// The empty-scan memory is the mechanism that makes the later calls cheap, and the property it
    /// must not break is that a cheap call and an expensive one give the same answer.
    #[test]
    fn a_process_that_is_not_there_keeps_answering_unknown() {
        let reader = NavHistoryReader::new();
        for beat in 0..32_u32 {
            assert!(reader.read(i32::MAX, beat % 8 == 0, beat % 4 == 0).is_none());
        }
    }

    /// A reader asked about THIS process reads a live accessibility tree rather than a missing one,
    /// and the answer — pair or no pair — is the SAME across a hundred beats. Whichever branch a
    /// machine takes, the property under test is that the cache does not drift: a held pair keeps
    /// reading, and an empty verdict keeps refusing.
    #[test]
    fn a_reading_of_a_live_process_is_stable_across_beats() {
        let reader = NavHistoryReader::new();
        let pid = std::process::id().cast_signed();
        let first = reader.read(pid, true, true);
        for beat in 0..100_u32 {
            assert_eq!(reader.read(pid, beat % 8 == 0, beat % 4 == 0), first);
        }
    }
}
