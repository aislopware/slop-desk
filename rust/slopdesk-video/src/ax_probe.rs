//! The decisions the accessibility probe makes, with no accessibility API in sight.
//!
//! `slopdesk-apple-ax` turns an `AXUIElement` into a window id, a frame and a minimized flag.
//! Everything the host does with those — which candidate element is the window it meant, which pids
//! are worth re-probing this tick, and what a window's absence from a sweep proves — is here, where
//! it is `forbid(unsafe_code)` and every arm has a test. None of it needed an accessibility grant
//! to be written and none of it needs one to be checked, which is what changed: the Swift these
//! came from carried "COMPILED + reviewed; not driven from unit tests" in its own header.

use std::collections::{HashMap, HashSet};

/// How far apart two frames may sit and still be considered the same window, in points.
///
/// AX reports a window's position and size through a different path than `CGWindowBounds` does, and
/// the two disagree by well under a point on a `HiDPI` display. Two points is generous enough to
/// absorb that and far tighter than any real window's distance from another.
pub const FRAME_TOLERANCE: f64 = 2.0;

/// One candidate window as the accessibility tree answers it: the id the private symbol gave, if
/// any, and the frame, if it was readable.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Candidate {
    /// The `CGWindowID` the private symbol resolved, or `None` when it could not.
    pub id: Option<u32>,
    /// The window's global frame in top-left points, or `None` when either half was unreadable.
    pub frame: Option<Frame>,
}

/// A global frame in top-left points — the same space `CGWindowBounds` reports.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Frame {
    /// The left edge.
    pub x: f64,
    /// The top edge.
    pub y: f64,
    /// The width.
    pub width: f64,
    /// The height.
    pub height: f64,
}

impl Frame {
    /// Whether `self` and `other` name the same window, within [`FRAME_TOLERANCE`] on all four
    /// numbers.
    #[must_use]
    pub fn matches(&self, other: &Self) -> bool {
        (self.x - other.x).abs() < FRAME_TOLERANCE
            && (self.y - other.y).abs() < FRAME_TOLERANCE
            && (self.width - other.width).abs() < FRAME_TOLERANCE
            && (self.height - other.height).abs() < FRAME_TOLERANCE
    }
}

/// Which of `candidates` is the window `wanted`, by index, or `None` when none is.
///
/// The id wins outright wherever it is available. The frame is consulted ONLY when the private
/// symbol resolved NOTHING for any candidate at all — which is what happens on a locked screen
/// (macOS 15+ answers success and writes zero; `AeroSpace` #445) — and never per element.
///
/// That distinction is the whole rule, and getting it wrong is a real bug rather than a lost
/// opportunity: a candidate whose id resolved and did NOT match is a genuine non-match, so falling
/// back to the frame for it binds two windows of the same app that share an origin. The host parks
/// every remoted window at its virtual display's top-left corner, so identical frames are not an
/// edge case here — they are the steady state.
#[must_use]
pub fn match_window(candidates: &[Candidate], wanted: u32, bounds: Frame) -> Option<usize> {
    let mut any_id_resolved = false;
    for (index, candidate) in candidates.iter().enumerate() {
        if let Some(id) = candidate.id {
            any_id_resolved = true;
            if id == wanted {
                return Some(index);
            }
        }
    }
    if any_id_resolved {
        return None;
    }
    candidates
        .iter()
        .position(|candidate| candidate.frame.is_some_and(|frame| frame.matches(&bounds)))
}

/// How many pids may be swept per tick, and how long a sweep's answer counts as fresh.
///
/// The probe is the only thing in the feed that can block: a hung app costs its whole messaging
/// timeout, so an unbounded tick is one beachballing app away from stalling the window feed. Three
/// pids at a quarter-second each is a worst case of about three quarters of a second, and the
/// steady state is zero because nothing is stale.
#[derive(Clone, Debug)]
pub struct ProbeBudget {
    /// When each pid was last swept, in the caller's own clock.
    stamps: HashMap<i32, f64>,
    /// How long a sweep stays fresh, in seconds.
    ttl: f64,
    /// The most pids one tick may sweep.
    max_per_tick: usize,
}

/// A sweep counts as fresh for three seconds — long enough that a steady feed sweeps nothing, short
/// enough that un-minimizing a window shows up within a few frames of the differ's own cadence.
pub const DEFAULT_TTL: f64 = 3.0;

/// Three pids per tick. See [`ProbeBudget`] for the arithmetic.
pub const DEFAULT_MAX_PER_TICK: usize = 3;

impl Default for ProbeBudget {
    fn default() -> Self {
        Self::new()
    }
}

impl ProbeBudget {
    /// A budget with the defaults above.
    #[must_use]
    pub fn new() -> Self {
        Self::with_limits(DEFAULT_TTL, DEFAULT_MAX_PER_TICK)
    }

    /// A budget with an explicit freshness window and per-tick cap.
    ///
    /// A cap of zero is honoured rather than corrected: a caller asking for no sweeps is asking for
    /// the ledger alone, which is a coherent thing to want while a machine has no grant.
    #[must_use]
    pub fn with_limits(ttl: f64, max_per_tick: usize) -> Self {
        Self {
            stamps: HashMap::new(),
            ttl,
            max_per_tick,
        }
    }

    /// How long a sweep stays fresh.
    #[must_use]
    pub const fn ttl(&self) -> f64 {
        self.ttl
    }

    /// The most pids one tick may sweep.
    #[must_use]
    pub const fn max_per_tick(&self) -> usize {
        self.max_per_tick
    }

    /// The pids to sweep this tick, stamped as swept.
    ///
    /// Sorted, so the pick is deterministic and a pid starved by a busy tick wins the next one
    /// rather than depending on hash order. Stamps for pids no longer among `candidates` are
    /// dropped in the same pass, which is what keeps the map from growing for the process's life
    /// across every app the person has ever opened.
    pub fn pids_to_probe(&mut self, candidates: &[i32], now: f64) -> Vec<i32> {
        let mut stale: Vec<i32> = candidates
            .iter()
            .copied()
            .filter(|pid| self.stamps.get(pid).is_none_or(|last| now - last >= self.ttl))
            .collect();
        stale.sort_unstable();
        stale.dedup();
        stale.truncate(self.max_per_tick);
        for pid in &stale {
            self.stamps.insert(*pid, now);
        }
        let live: HashSet<i32> = candidates.iter().copied().collect();
        self.stamps.retain(|pid, _| live.contains(pid));
        stale
    }
}

/// What one sweep proved about one window.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Verdict {
    /// Whether the window appeared in its app's accessibility window list at all.
    ///
    /// A window that does NOT is a phantom — a browser's tab cache, a panel service's scratch
    /// surface — which the window server lists and no person can ever look at. That is the feed's
    /// inclusion gate, and it is why a failed sweep must never be folded: absence of evidence would
    /// become evidence of absence and the feed would empty itself.
    pub ax_listed: bool,
    /// Whether the window is minimized into the Dock, as opposed to on another Space.
    pub minimized: bool,
}

/// Every window's last verdict, held between sweeps.
///
/// Reads must be free — the feed classifies every off-screen window on every tick — while sweeps
/// are budgeted to a few pids. So the answer between sweeps is the last one, and the ledger is
/// where it lives.
#[derive(Clone, Debug, Default)]
pub struct Ledger {
    /// Window id to its last verdict.
    verdicts: HashMap<u32, Verdict>,
}

impl Ledger {
    /// An empty ledger.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// How many windows have a verdict.
    #[must_use]
    pub fn len(&self) -> usize {
        self.verdicts.len()
    }

    /// Whether nothing has been folded yet.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.verdicts.is_empty()
    }

    /// Fold ONE app's SUCCESSFUL sweep.
    ///
    /// `sweep` is every window the accessibility tree listed for that app, with its minimized flag.
    /// `off_screen` is the pid's off-screen window ids this tick: any of them the sweep did not
    /// return is recorded as explicitly not-listed, rather than left alone. That explicitness is
    /// the point — window ids recycle, and a phantom inheriting a real window's stale verdict is
    /// the bug this closes.
    ///
    /// A FAILED sweep must not reach here. Stale beats absent: the caller skips the fold entirely
    /// and the next freshness window retries.
    pub fn fold(&mut self, sweep: &[(u32, bool)], off_screen: &[u32]) {
        for (id, minimized) in sweep {
            self.verdicts.insert(*id, Verdict {
                ax_listed: true,
                minimized: *minimized,
            });
        }
        for id in off_screen {
            if !sweep.iter().any(|(swept, _)| swept == id) {
                self.verdicts.insert(*id, Verdict::default());
            }
        }
    }

    /// One window's last verdict, or `None` when it has never been swept.
    #[must_use]
    pub fn verdict(&self, id: u32) -> Option<Verdict> {
        self.verdicts.get(&id).copied()
    }

    /// Drop every verdict for a window not in `live` — the windows that have closed.
    pub fn retain(&mut self, live: &[u32]) {
        let live: HashSet<u32> = live.iter().copied().collect();
        self.verdicts.retain(|id, _| live.contains(id));
    }
}

/// One classification pass: which off-screen windows are minimized, and which have any evidence of
/// being real windows at all.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Classification {
    /// The minimized ones, sorted.
    pub minimized: Vec<u32>,
    /// The ones the accessibility tree listed, sorted.
    pub ax_listed: Vec<u32>,
}

/// Read `ids` out of `ledger` into the two sorted sets the feed consumes.
///
/// A window with no verdict appears in neither: never swept is not the same as swept and absent,
/// and only the second is evidence.
#[must_use]
pub fn classify(ledger: &Ledger, ids: &[u32]) -> Classification {
    let mut out = Classification::default();
    for id in ids {
        let Some(verdict) = ledger.verdict(*id) else {
            continue;
        };
        if verdict.ax_listed {
            out.ax_listed.push(*id);
        }
        if verdict.minimized {
            out.minimized.push(*id);
        }
    }
    out.ax_listed.sort_unstable();
    out.ax_listed.dedup();
    out.minimized.sort_unstable();
    out.minimized.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::{Candidate, Classification, Frame, Ledger, ProbeBudget, Verdict, classify, match_window};

    /// A frame at the given place, for the tests below.
    fn frame(x: f64, y: f64, width: f64, height: f64) -> Frame {
        Frame { x, y, width, height }
    }

    /// The ordinary case: the private symbol answered for every candidate and one of them is the
    /// window asked for.
    #[test]
    fn the_id_decides_when_the_symbol_answered() {
        let candidates = [
            Candidate {
                id: Some(11),
                frame: Some(frame(0.0, 0.0, 100.0, 100.0)),
            },
            Candidate {
                id: Some(22),
                frame: Some(frame(0.0, 0.0, 100.0, 100.0)),
            },
        ];
        assert_eq!(
            match_window(&candidates, 22, frame(0.0, 0.0, 100.0, 100.0)),
            Some(1)
        );
    }

    /// THE bug this rule exists for. Two windows of one app parked at the same origin — which is
    /// what the host manufactures when it moves panes onto a shared virtual display — and the id
    /// resolved for both. The one that is not asked for must NOT be accepted on its frame.
    #[test]
    fn a_resolved_id_that_does_not_match_is_a_real_non_match() {
        let shared = Some(frame(0.0, 0.0, 1920.0, 1080.0));
        let candidates = [
            Candidate {
                id: Some(11),
                frame: shared,
            },
            Candidate {
                id: Some(22),
                frame: shared,
            },
        ];
        assert_eq!(
            match_window(&candidates, 33, frame(0.0, 0.0, 1920.0, 1080.0)),
            None
        );
    }

    /// The locked-screen arm: the symbol resolved for nobody, so the frame is all there is. Falling
    /// back here is what keeps a raise working while the screen is locked.
    #[test]
    fn the_frame_decides_only_when_the_symbol_answered_for_nobody() {
        let candidates = [
            Candidate {
                id: None,
                frame: Some(frame(0.0, 0.0, 100.0, 100.0)),
            },
            Candidate {
                id: None,
                frame: Some(frame(400.0, 300.0, 800.0, 600.0)),
            },
        ];
        assert_eq!(
            match_window(&candidates, 99, frame(400.0, 300.0, 800.0, 600.0)),
            Some(1)
        );
    }

    /// A single resolved id anywhere in the list disables the frame fallback for the WHOLE list —
    /// not just for that candidate. Otherwise one window whose id failed to resolve reopens the
    /// mis-binding for every other.
    #[test]
    fn one_resolved_id_anywhere_disables_the_frame_fallback_entirely() {
        let candidates = [
            Candidate {
                id: Some(11),
                frame: Some(frame(0.0, 0.0, 100.0, 100.0)),
            },
            Candidate {
                id: None,
                frame: Some(frame(400.0, 300.0, 800.0, 600.0)),
            },
        ];
        assert_eq!(
            match_window(&candidates, 99, frame(400.0, 300.0, 800.0, 600.0)),
            None
        );
    }

    /// Sub-point disagreement between the two APIs must not lose the match; a whole window away
    /// must not win one.
    #[test]
    fn the_frame_match_absorbs_rounding_and_nothing_more() {
        let candidates = [Candidate {
            id: None,
            frame: Some(frame(100.5, 200.5, 640.25, 480.75)),
        }];
        assert_eq!(
            match_window(&candidates, 7, frame(101.0, 201.0, 640.0, 481.0)),
            Some(0)
        );
        assert_eq!(
            match_window(&candidates, 7, frame(103.0, 201.0, 640.0, 481.0)),
            None
        );
    }

    /// Nothing to match against is nothing, not a panic.
    #[test]
    fn an_empty_candidate_list_matches_nothing() {
        assert_eq!(match_window(&[], 1, frame(0.0, 0.0, 1.0, 1.0)), None);
    }

    /// A candidate whose frame was unreadable cannot win the fallback — a `None` frame is not a
    /// frame that happens to be at the origin.
    #[test]
    fn an_unreadable_frame_never_wins_the_fallback() {
        let candidates = [Candidate {
            id: None,
            frame: None,
        }];
        assert_eq!(match_window(&candidates, 1, frame(0.0, 0.0, 0.0, 0.0)), None);
    }

    /// Everything is stale on the first tick, and the cap holds.
    #[test]
    fn the_first_tick_probes_up_to_the_cap_and_no_further() {
        let mut budget = ProbeBudget::new();
        assert_eq!(budget.pids_to_probe(&[5, 3, 1, 4, 2], 0.0), vec![1, 2, 3]);
    }

    /// The pids the cap left behind win the very next tick — the property that makes starvation
    /// impossible rather than merely unlikely.
    #[test]
    fn the_pids_the_cap_skipped_win_the_next_tick() {
        let mut budget = ProbeBudget::new();
        assert_eq!(budget.pids_to_probe(&[1, 2, 3, 4, 5], 0.0), vec![1, 2, 3]);
        assert_eq!(budget.pids_to_probe(&[1, 2, 3, 4, 5], 0.0), vec![4, 5]);
        assert_eq!(budget.pids_to_probe(&[1, 2, 3, 4, 5], 0.0), Vec::<i32>::new());
    }

    /// Past the freshness window everything is stale again, in the same order.
    #[test]
    fn a_stamp_expires_after_the_freshness_window() {
        let mut budget = ProbeBudget::new();
        assert_eq!(budget.pids_to_probe(&[1, 2], 0.0), vec![1, 2]);
        assert_eq!(budget.pids_to_probe(&[1, 2], 2.999), Vec::<i32>::new());
        assert_eq!(budget.pids_to_probe(&[1, 2], 3.0), vec![1, 2]);
    }

    /// A pid that quits takes its stamp with it, so the map cannot grow across the life of a
    /// long-running daemon.
    #[test]
    fn a_pid_that_leaves_takes_its_stamp_with_it() {
        let mut budget = ProbeBudget::new();
        assert_eq!(budget.pids_to_probe(&[1, 2], 0.0), vec![1, 2]);
        assert_eq!(budget.pids_to_probe(&[2], 0.1), Vec::<i32>::new());
        // Pid 1 came back with the same number; without the drop it would still look fresh.
        assert_eq!(budget.pids_to_probe(&[1, 2], 0.2), vec![1]);
    }

    /// A duplicate in the candidate list is one pid, not two slots of the cap.
    #[test]
    fn a_repeated_pid_costs_one_slot() {
        let mut budget = ProbeBudget::new();
        assert_eq!(budget.pids_to_probe(&[7, 7, 7, 8, 9, 10], 0.0), vec![7, 8, 9]);
    }

    /// A cap of zero probes nothing and stamps nothing, forever.
    #[test]
    fn a_cap_of_zero_probes_nothing() {
        let mut budget = ProbeBudget::with_limits(3.0, 0);
        assert_eq!(budget.pids_to_probe(&[1, 2, 3], 0.0), Vec::<i32>::new());
        assert_eq!(budget.pids_to_probe(&[1, 2, 3], 100.0), Vec::<i32>::new());
    }

    /// A swept window is listed, and its minimized flag is carried verbatim.
    #[test]
    fn a_swept_window_carries_its_own_flag() {
        let mut ledger = Ledger::new();
        assert!(ledger.is_empty());
        ledger.fold(&[(1, true), (2, false)], &[1, 2]);
        assert_eq!(
            ledger.verdict(1),
            Some(Verdict {
                ax_listed: true,
                minimized: true
            })
        );
        assert_eq!(
            ledger.verdict(2),
            Some(Verdict {
                ax_listed: true,
                minimized: false
            })
        );
        assert_eq!(ledger.len(), 2);
    }

    /// An off-screen window the sweep did NOT return is recorded as not-listed EXPLICITLY. This is
    /// the phantom filter, and the explicitness is what stops a recycled id from inheriting the
    /// verdict of the real window that used to hold it.
    #[test]
    fn a_window_the_sweep_omitted_is_recorded_as_absent_rather_than_left_alone() {
        let mut ledger = Ledger::new();
        ledger.fold(&[(1, true)], &[1, 2]);
        assert_eq!(ledger.verdict(2), Some(Verdict::default()));
        // The same id, now a real window in a later sweep, flips back.
        ledger.fold(&[(2, false)], &[2]);
        assert_eq!(
            ledger.verdict(2),
            Some(Verdict {
                ax_listed: true,
                minimized: false
            })
        );
    }

    /// A window nobody asked about is untouched by a fold — only the ids the caller named as
    /// off-screen this tick are candidates for the absent verdict.
    #[test]
    fn a_fold_touches_only_the_windows_it_was_given() {
        let mut ledger = Ledger::new();
        ledger.fold(&[(1, true)], &[1]);
        ledger.fold(&[(9, false)], &[9]);
        assert_eq!(
            ledger.verdict(1),
            Some(Verdict {
                ax_listed: true,
                minimized: true
            })
        );
    }

    /// Closed windows leave the ledger.
    #[test]
    fn retaining_the_live_ones_drops_the_rest() {
        let mut ledger = Ledger::new();
        ledger.fold(&[(1, true), (2, false), (3, true)], &[]);
        ledger.retain(&[2, 3]);
        assert_eq!(ledger.verdict(1), None);
        assert_eq!(ledger.len(), 2);
    }

    /// The classification reads the ledger and sorts, and a window with no verdict at all appears
    /// in neither set — never swept is not evidence of anything.
    #[test]
    fn a_window_never_swept_is_in_neither_set() {
        let mut ledger = Ledger::new();
        ledger.fold(&[(3, true), (1, false)], &[3, 1, 5]);
        assert_eq!(classify(&ledger, &[5, 3, 1, 404]), Classification {
            minimized: vec![3],
            ax_listed: vec![1, 3],
        });
    }
}
