//! Can the frontmost app go back and forward — the swipe-nav chip's one live read.
//!
//! `HostNavHistory.swift` was this, and the file carried a standing warning that no unit test could
//! reach it: every reading is blocking out-of-process accessibility IPC against a live browser,
//! which is the same hang-safety rule that keeps `SCStream` and `VideoToolbox` out of the suite.
//! What rode along under that warning was not the IPC. It was two element-matching rules, two walk
//! bounds, a per-window currency rule and a cache with three states — none of which needs a browser
//! to be true, and all of which are `slopdesk_video::nav_history` now, with thirteen tests.
//!
//! Three pieces meet here, so the join is in the shim rather than in any of them:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | `slopdesk-apple-ax` | the elements, their attributes, and the bounded walk over them |
//! | [`slopdesk_video::nav_history`] | which node counts, how far to look, when to trust a cached pair |
//! | this module | the handle Swift holds, and the order the two are asked in |
//!
//! ## Why a handle rather than a function
//! A full scan is 25–180 ms of blocking IPC on a cold browser and a cached re-read is about
//! 0.05 ms, so the pair has to survive between beats — and the poll runs at 4 Hz. A stateless door
//! would pay the scan every quarter second for every frontmost browser. The handle holds the pair,
//! and `slopdesk_video::nav_history::Cache` holds the rules about when it may still be believed.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use slopdesk_apple_ax::{App, Element, Step, Window, walk};
use slopdesk_video::nav_history::{
    Cache, Direction, Flags, MENU_MAX_DEPTH, MENU_NODE_BUDGET, MESSAGE_TIMEOUT, Plan, SCAN_DEADLINE,
    Strategy, TOOLBAR_MAX_DEPTH, TOOLBAR_NODE_BUDGET, fold, menu_visit, toolbar_visit,
};

/// Both directions, as a Rust caller sees them — what [`SlopDeskNavHistory::read`] answers.
///
/// Re-exported so a crate holding the reader natively need not also take an edge to
/// `slopdesk-video` just to name the return type.
pub use slopdesk_video::nav_history::Flags as NavFlags;

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
pub struct SlopDeskNavHistory {
    /// The pair and the rules about believing it.
    ///
    /// Behind a lock because the status push runs on a detached task and the beat that forces a
    /// rescan can arrive from another: two readings must serialise rather than interleave, or one
    /// would read the pair the other is replacing.
    state: Mutex<State>,
}

impl SlopDeskNavHistory {
    /// A reader with an empty cache.
    ///
    /// The Rust-native face beside [`slopdesk_nav_history_new`]: the same handle, without the raw
    /// pointer, so a `forbid(unsafe_code)` caller can hold one. `reader` rather than `new` because
    /// a `new` returning `Self` with no `Default` is the shape `clippy::new_without_default` names.
    #[must_use]
    pub fn reader() -> Self {
        Self {
            state: Mutex::new(State::default()),
        }
    }

    /// The current flags for `pid`, or `None` for unknown.
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

/// Both directions, as C sees them.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct SlopDeskNavFlags {
    /// Whether ⌘[ would navigate.
    pub can_go_back: bool,
    /// Whether ⌘] would navigate.
    pub can_go_forward: bool,
}

/// Builds a reader. Never null.
///
/// # Safety
/// The answer must be passed to [`slopdesk_nav_history_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_nav_history_new() -> *mut SlopDeskNavHistory {
    Box::into_raw(Box::new(SlopDeskNavHistory::reader()))
}

/// Releases a reader. Null is inert.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_nav_history_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_nav_history_free(handle: *mut SlopDeskNavHistory) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free.
    drop(unsafe { Box::from_raw(handle) });
}

/// Reads `pid`'s history availability into `out`; answers whether it is KNOWN.
///
/// `false` means unknown and leaves `out` untouched, which is the fail-open answer the whole gate
/// is built to give: the client falls back to its pre-gate behaviour rather than darking a chip it
/// cannot vouch for.
///
/// `rescan_unknown` is the slow heartbeat's permission to retry a pid whose last scan found no
/// pair. `verify_window` is the same beat's permission to spend one extra round trip confirming a
/// toolbar pair still belongs to the focused window.
///
/// Blocks on out-of-process IPC, bounded by the crate's own per-message cap and scan deadline —
/// call it off the main thread.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_nav_history_new`]; `out` must be null or
/// point at one writable [`SlopDeskNavFlags`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "the shim's whole job is turning a caller's pointers into references"
)]
pub unsafe extern "C" fn slopdesk_nav_history_read(
    handle: *const SlopDeskNavHistory,
    pid: i32,
    rescan_unknown: bool,
    verify_window: bool,
    out: *mut SlopDeskNavFlags,
) -> bool {
    if handle.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation, above — non-null and live for the call.
    let reader = unsafe { &*handle };
    let Some(flags) = reader.read(pid, rescan_unknown, verify_window) else {
        return false;
    };
    // SAFETY: the caller's obligation, above — non-null and one writable record.
    unsafe {
        *out = SlopDeskNavFlags {
            can_go_back: flags.can_go_back,
            can_go_forward: flags.can_go_forward,
        };
    }
    true
}

#[cfg(test)]
mod tests {
    use super::{slopdesk_nav_history_free, slopdesk_nav_history_new, slopdesk_nav_history_read};

    /// Every door refuses rather than faults. A null handle, a null out and a pid that names no
    /// process are the three ways a caller can be wrong, and all three are the caller's ordinary
    /// "unknown, fail open" answer rather than a crash in a daemon.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn every_door_refuses_rather_than_faults() {
        let mut flags = super::SlopDeskNavFlags::default();
        // SAFETY: a null handle and a null out are both the refusal arms under test.
        unsafe {
            assert!(!slopdesk_nav_history_read(
                std::ptr::null(),
                1,
                true,
                true,
                &raw mut flags
            ));
            slopdesk_nav_history_free(std::ptr::null_mut());
        }

        let reader = slopdesk_nav_history_new();
        // SAFETY: `reader` is the live box just built; the null `out` is the arm under test.
        unsafe {
            assert!(!slopdesk_nav_history_read(
                reader,
                i32::MAX,
                true,
                true,
                std::ptr::null_mut()
            ));
            assert!(!slopdesk_nav_history_read(
                reader,
                i32::MAX,
                true,
                true,
                &raw mut flags
            ));
            slopdesk_nav_history_free(reader);
        }
    }

    /// A pid that names no process answers unknown every time and never starts believing itself.
    /// The empty-scan memory is the mechanism that makes the later calls cheap, and the property it
    /// must not break is that a cheap call and an expensive one give the same answer.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn a_process_that_is_not_there_keeps_answering_unknown() {
        let reader = slopdesk_nav_history_new();
        let mut flags = super::SlopDeskNavFlags::default();
        // SAFETY: `reader` is live for every call below and `flags` is one writable record.
        unsafe {
            for beat in 0..32 {
                assert!(!slopdesk_nav_history_read(
                    reader,
                    i32::MAX,
                    beat % 8 == 0,
                    beat % 4 == 0,
                    &raw mut flags
                ));
            }
            slopdesk_nav_history_free(reader);
        }
    }

    /// A reader asked about this process reads a live accessibility tree rather than a missing one,
    /// and the answer — pair or no pair — is the SAME across a hundred beats. Whichever branch a
    /// machine takes, the property under test is that the cache does not drift: a held pair keeps
    /// reading, and an empty verdict keeps refusing.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn a_reading_of_a_live_process_is_stable_across_beats() {
        let reader = slopdesk_nav_history_new();
        let pid = std::process::id().cast_signed();
        let mut flags = super::SlopDeskNavFlags::default();
        // SAFETY: `reader` is live for every call below and `flags` is one writable record.
        unsafe {
            let first = slopdesk_nav_history_read(reader, pid, true, true, &raw mut flags);
            for beat in 0..100 {
                assert_eq!(
                    slopdesk_nav_history_read(reader, pid, beat % 8 == 0, beat % 4 == 0, &raw mut flags),
                    first
                );
            }
            slopdesk_nav_history_free(reader);
        }
    }
}
