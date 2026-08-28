//! Who is still holding a window parked on the virtual display, and when it may go home.
//!
//! Remoting a window MOVES it. The host shrinks the user's real window onto a `HiDPI` virtual
//! display so it renders at a true 2× backing — [`crate::window_placement`] is that arithmetic —
//! and for as long as it sits there nobody at the machine can see it. Every park therefore owes a
//! restore, and an owed restore that never arrives is not a tidy-up: it is the user's window left
//! shrunk on a display no screen shows, after every session.
//!
//! Owing it once is easy. Owing it EXACTLY once is not, because a lane and a window are not the
//! same thing. Two panes may name the same window, so it is moved once and must be put back once —
//! when the last of them lets go, not the first. And the lane that asks is a UDP endpoint, so the
//! same lane asks twice for reasons that have nothing to do with what the user did. Counting is the
//! whole of this module, and it is a module rather than three lines inside the accessibility code
//! because every bug this feature has ever had was a counting bug. Over-count and the window never
//! comes back; under-count and it is yanked out from under a pane still streaming it.
//!
//! Nothing here touches a window, and that is the point: the counting is decidable at a desk, while
//! the moving needs a granted accessibility client and a live window server.
//! [`ParkingLedger::park`] says whether the caller must move the window or may just capture the one
//! already there, and [`ParkingLedger::record_move`] commits a move that LANDED. The commit is a
//! second call rather than `park`'s return value for one reason: an app is free to refuse the
//! resize, and a refused move must leave no record behind promising a restore of a window that
//! never went anywhere.
//!
//! ## A lane that changes its mind
//!
//! A lane can park onto a DIFFERENT window without unparking the first — picking another window
//! from the rail does exactly that. Its old hold has to be released FIRST, down the same path an
//! unpark takes, or the old window's count never reaches zero and it stays parked until the whole
//! session tears down. That release can itself fall due, and `park`'s answer has nowhere to carry a
//! second obligation, so it is left one step to the side in
//! [`ParkingLedger::take_pending_retarget_restore`] for the caller to pick up immediately after
//! every park. It holds one value and clears on read, because a caller that forgets to look is back
//! to the stranded window and a caller that looks twice must not restore twice.

use std::collections::{BTreeMap, BTreeSet};

use crate::geometry::{VideoRect, VideoSize};

/// A window parked on the virtual display: where it came from, what it became, and who wants it
/// there.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Parked {
    /// The process that owns the window. Carried rather than looked up, because a restore can fall
    /// due long after the session that knew the owner has gone.
    pub pid: i32,
    /// The frame the window held before it was moved, and the one it is put back to.
    pub original: VideoRect,
    /// The size the window ACHIEVED on the virtual display, which is what a second lane captures
    /// at — not the size that was asked for, since an app may clamp or ignore a resize.
    pub achieved: VideoSize,
    /// How many lanes hold this window right now, never zero: the record is dropped when the last
    /// holder lets go rather than kept at nought.
    pub holders: u32,
}

/// A window that must be moved back, named the way the effect side needs it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RestoreTarget {
    /// The window to move.
    pub window_id: u32,
    /// The process that owns it.
    pub pid: i32,
    /// The frame to put it back to.
    pub original: VideoRect,
}

/// What a park request resolves to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ParkDecision {
    /// The window is on the display already — another lane put it there, or this lane is asking
    /// again — so capture at this achieved size and move nothing. The ledger has already done
    /// whatever counting the request called for.
    Reuse(VideoSize),
    /// Nobody holds this window yet. Move it, and commit with
    /// [`ParkingLedger::record_move`] only if the move lands.
    NeedsMove,
}

/// The refcounted ledger of parked windows and the lanes holding them.
///
/// One per host. It answers park and unpark requests and nothing else; the accessibility move and
/// the restore that its answers call for belong to the caller.
#[derive(Debug, Default, Clone)]
pub struct ParkingLedger {
    parked: BTreeMap<u32, Parked>,
    channel_window: BTreeMap<u32, u32>,
    pending_retarget_restore: Option<RestoreTarget>,
}

impl ParkingLedger {
    /// An empty ledger: nothing parked, nobody holding.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            parked: BTreeMap::new(),
            channel_window: BTreeMap::new(),
            pending_retarget_restore: None,
        }
    }

    /// Decides a park request, doing the counting the answer implies.
    ///
    /// A lane already bound to a DIFFERENT window is retargeting, and its old hold is released
    /// before anything else happens — see the module header for what an unreleased one costs. Any
    /// restore that release fell due for waits in [`Self::take_pending_retarget_restore`], which
    /// the caller must drain right after this call.
    ///
    /// The same lane asking again for the same window is a hello retransmit, not a second pane, and
    /// it does NOT count: the client resends its hello until the mint is acknowledged, so a bump
    /// here would leave a hold nothing will ever release. A DIFFERENT lane asking for a window that
    /// is already parked is a second pane, and it does count — one move, one restore, when the last
    /// of them goes.
    ///
    /// [`ParkDecision::NeedsMove`] binds nothing, because the move may still fail and a binding to
    /// a window that never moved would promise a restore that would move it for the first time.
    pub fn park(&mut self, channel_id: u32, window_id: u32) -> ParkDecision {
        if let Some(&existing) = self.channel_window.get(&channel_id)
            && existing != window_id
        {
            self.pending_retarget_restore = self.release_hold(channel_id, existing);
        }
        // Read AFTER the retarget release, which clears the binding: a retargeting lane is a new
        // holder of the new window, never a repeat of it.
        let asking_again = self.channel_window.get(&channel_id) == Some(&window_id);
        let Some(entry) = self.parked.get_mut(&window_id) else {
            return ParkDecision::NeedsMove;
        };
        if !asking_again {
            entry.holders = entry.holders.saturating_add(1);
        }
        let achieved = entry.achieved;
        self.channel_window.insert(channel_id, window_id);
        ParkDecision::Reuse(achieved)
    }

    /// Takes the restore the most recent [`Self::park`] fell due for by retargeting, if it did.
    ///
    /// `None` on every ordinary park, and on a retarget away from a window another lane still
    /// holds. One value is enough because park requests are decided one at a time; it clears on
    /// read so that a caller polling defensively cannot restore the same window twice.
    pub const fn take_pending_retarget_restore(&mut self) -> Option<RestoreTarget> {
        self.pending_retarget_restore.take()
    }

    /// Commits a move that landed, after [`Self::park`] answered [`ParkDecision::NeedsMove`].
    ///
    /// This OVERWRITES any record of `window_id` and sets its holder count to one; it does not add
    /// to what was there. A window reaching this call is one nobody was holding a moment ago — the
    /// only path here is through `NeedsMove`, which is only answered for a window absent from the
    /// ledger — so accumulating would be counting a state that cannot exist.
    pub fn record_move(
        &mut self,
        channel_id: u32,
        window_id: u32,
        pid: i32,
        original: VideoRect,
        achieved: VideoSize,
    ) {
        self.parked.insert(window_id, Parked {
            pid,
            original,
            achieved,
            holders: 1,
        });
        self.channel_window.insert(channel_id, window_id);
    }

    /// Releases whatever `channel_id` holds, and names the window to restore if that was the last
    /// hold on it.
    ///
    /// Idempotent, and deliberately so: a pane closing, a lane being reaped and a session shutting
    /// down all call this for the same channel, and none of them knows about the others. A channel
    /// that never parked and a channel whose window has already gone both answer `None`.
    pub fn unpark(&mut self, channel_id: u32) -> Option<RestoreTarget> {
        let window_id = *self.channel_window.get(&channel_id)?;
        self.release_hold(channel_id, window_id)
    }

    /// Every parked window, each exactly once, and the ledger left empty. The shutdown drain.
    ///
    /// Called when the daemon exits and when the window server tears the virtual display down, in
    /// both cases as a backstop behind the per-channel unparks — so a second drain is empty rather
    /// than a second restore. Holder counts do not survive it: a drain restores each window once no
    /// matter how many panes were on it. An undrained retarget restore is NOT swallowed here, since
    /// its window already left the ledger and is still owed a move home.
    pub fn drain_all(&mut self) -> Vec<RestoreTarget> {
        self.channel_window.clear();
        std::mem::take(&mut self.parked)
            .into_iter()
            .map(|(window_id, entry)| {
                RestoreTarget {
                    window_id,
                    pid: entry.pid,
                    original: entry.original,
                }
            })
            .collect()
    }

    /// The lanes currently holding a parked window.
    ///
    /// What the virtual-display termination policy asks when the display dies under a live session:
    /// these are the lanes whose window is now on nothing, and the ones that have to be told.
    #[must_use]
    pub fn parked_channel_ids(&self) -> BTreeSet<u32> {
        self.channel_window.keys().copied().collect()
    }

    /// Every parked window as `(window_id, Parked)`, for the crash-journal snapshot. Read-only.
    ///
    /// A clean exit drains; a `SIGKILL` does not, so the journal on disk is the only thing that can
    /// tell the next launch which windows were left stranded ([`crate::window_restore`] decides
    /// which of them may actually be moved). One entry per DISTINCT window, in window order,
    /// because that file is compared byte for byte across runs and a holder count means nothing to
    /// a process that is already dead.
    ///
    /// The caller rewrites the journal exactly when this set CHANGES, which is after a
    /// [`Self::record_move`], after an [`Self::unpark`] or a
    /// [`Self::take_pending_retarget_restore`] that answered `Some`, and after a non-empty
    /// [`Self::drain_all`] — never after a [`ParkDecision::Reuse`], which by construction
    /// changes nothing here.
    #[must_use]
    pub fn entries(&self) -> Vec<(u32, Parked)> {
        self.parked
            .iter()
            .map(|(&window_id, &entry)| (window_id, entry))
            .collect()
    }

    /// Drops `channel_id`'s hold on `window_id`, the one path both an unpark and a retarget take.
    ///
    /// The binding goes UNCONDITIONALLY and FIRST, before the parked record is even consulted, so
    /// that a repeated release cannot find anything to release a second time — that ordering is the
    /// whole of the idempotence [`Self::unpark`] promises.
    fn release_hold(&mut self, channel_id: u32, window_id: u32) -> Option<RestoreTarget> {
        self.channel_window.remove(&channel_id);
        let entry = self.parked.get_mut(&window_id)?;
        entry.holders = entry.holders.saturating_sub(1);
        if entry.holders > 0 {
            return None;
        }
        let released = *entry;
        self.parked.remove(&window_id);
        Some(RestoreTarget {
            window_id,
            pid: released.pid,
            original: released.original,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::{ParkDecision, Parked, ParkingLedger, RestoreTarget};
    use crate::geometry::{VideoRect, VideoSize};

    const FRAME_A: VideoRect = VideoRect::xywh(100.0, 200.0, 1600.0, 1000.0);
    const SIZE_A: VideoSize = VideoSize::new(1600.0, 1000.0);
    const FRAME_B: VideoRect = VideoRect::xywh(0.0, 0.0, 800.0, 600.0);
    const SIZE_B: VideoSize = VideoSize::new(800.0, 600.0);

    /// Parks window 42 for `channel_id` the way a caller whose move landed would.
    fn park_and_land(ledger: &mut ParkingLedger, channel_id: u32, window_id: u32, pid: i32) {
        assert_eq!(ledger.park(channel_id, window_id), ParkDecision::NeedsMove);
        ledger.record_move(channel_id, window_id, pid, FRAME_A, SIZE_A);
    }

    fn window_ids(ledger: &ParkingLedger) -> Vec<u32> {
        ledger.entries().into_iter().map(|(id, _)| id).collect()
    }

    #[test]
    fn a_first_park_asks_for_a_move_and_records_nothing_until_it_lands() {
        let mut ledger = ParkingLedger::new();
        assert_eq!(ledger.park(1, 42), ParkDecision::NeedsMove);
        assert!(
            ledger.entries().is_empty(),
            "the move may still fail, so nothing is recorded on the strength of the decision"
        );
        assert_eq!(
            ledger.parked_channel_ids(),
            BTreeSet::new(),
            "and the lane is not bound either"
        );
        ledger.record_move(1, 42, 7, FRAME_A, SIZE_A);
        assert_eq!(window_ids(&ledger), vec![42]);
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::from([1]));
    }

    #[test]
    fn a_move_that_never_landed_leaves_nothing_to_restore() {
        let mut ledger = ParkingLedger::new();
        let _ = ledger.park(1, 42);
        assert!(ledger.entries().is_empty());
        assert_eq!(
            ledger.unpark(1),
            None,
            "restoring a window that was never moved would move it for the first time"
        );
    }

    #[test]
    fn a_hello_retransmit_from_the_same_lane_is_not_a_second_holder() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);
        assert_eq!(ledger.park(1, 42), ParkDecision::Reuse(SIZE_A));
        assert_eq!(ledger.park(1, 42), ParkDecision::Reuse(SIZE_A));
        assert_eq!(
            ledger.unpark(1),
            Some(RestoreTarget {
                window_id: 42,
                pid: 7,
                original: FRAME_A
            }),
            "one lane, one hold, however many times the hello arrived"
        );
        assert!(ledger.entries().is_empty());
    }

    #[test]
    fn two_lanes_naming_one_window_move_it_once_and_restore_it_once() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);
        assert_eq!(
            ledger.park(2, 42),
            ParkDecision::Reuse(SIZE_A),
            "the window is already there — the second pane captures it, it does not move it"
        );
        assert_eq!(window_ids(&ledger), vec![42]);
        assert_eq!(
            ledger.unpark(1),
            None,
            "pane two is still streaming it; restoring now would yank it away"
        );
        assert_eq!(window_ids(&ledger), vec![42]);
        assert_eq!(ledger.unpark(2).map(|t| t.window_id), Some(42));
        assert!(ledger.entries().is_empty());
    }

    #[test]
    fn unparking_the_same_channel_twice_restores_it_once() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);
        assert!(ledger.unpark(1).is_some());
        assert_eq!(
            ledger.unpark(1),
            None,
            "the pane close, the lane reap and the shutdown all call this for the same channel"
        );
        assert!(ledger.entries().is_empty());
    }

    #[test]
    fn unparking_a_channel_that_never_parked_is_a_no_op() {
        let mut ledger = ParkingLedger::new();
        assert_eq!(ledger.unpark(99), None);
    }

    #[test]
    fn a_retarget_releases_the_old_window_before_it_counts_the_new_one() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);

        assert_eq!(
            ledger.park(1, 43),
            ParkDecision::NeedsMove,
            "a different window for the same lane is a fresh park"
        );
        assert_eq!(
            ledger.take_pending_retarget_restore(),
            Some(RestoreTarget {
                window_id: 42,
                pid: 7,
                original: FRAME_A
            }),
            "the old window's last hold went with the retarget, so it is owed a move home"
        );
        assert_eq!(
            ledger.take_pending_retarget_restore(),
            None,
            "and reading it clears it"
        );
        assert!(ledger.entries().is_empty(), "42 released, 43 not yet moved");
        assert_eq!(
            ledger.unpark(1),
            None,
            "a stale unpark must not restore 42 a second time"
        );

        ledger.record_move(1, 43, 8, FRAME_B, SIZE_B);
        assert_eq!(window_ids(&ledger), vec![43], "43 counted exactly once");
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::from([1]));
        assert_eq!(ledger.unpark(1).map(|t| t.window_id), Some(43));
    }

    #[test]
    fn a_retarget_away_from_a_shared_window_leaves_it_parked() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);
        assert_eq!(ledger.park(2, 42), ParkDecision::Reuse(SIZE_A));

        assert_eq!(ledger.park(1, 99), ParkDecision::NeedsMove);
        assert_eq!(
            ledger.take_pending_retarget_restore(),
            None,
            "lane two still holds 42 — nothing is owed yet"
        );
        assert_eq!(window_ids(&ledger), vec![42]);
        assert_eq!(ledger.unpark(2).map(|t| t.window_id), Some(42));
    }

    #[test]
    fn record_move_resets_the_holder_count_rather_than_accumulating() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);
        assert_eq!(ledger.park(2, 42), ParkDecision::Reuse(SIZE_A));
        assert_eq!(ledger.entries(), vec![(42, Parked {
            pid: 7,
            original: FRAME_A,
            achieved: SIZE_A,
            holders: 2
        })]);

        ledger.record_move(3, 42, 9, FRAME_B, SIZE_B);
        assert_eq!(
            ledger.entries(),
            vec![(42, Parked {
                pid: 9,
                original: FRAME_B,
                achieved: SIZE_B,
                holders: 1
            })],
            "a commit overwrites the record; it does not add to the count it found"
        );
        assert_eq!(ledger.unpark(3).map(|t| t.original), Some(FRAME_B));
    }

    #[test]
    fn draining_yields_every_parked_window_once_and_empties_the_ledger() {
        let mut ledger = ParkingLedger::new();
        park_and_land(&mut ledger, 1, 42, 7);
        assert_eq!(ledger.park(2, 42), ParkDecision::Reuse(SIZE_A));
        assert_eq!(ledger.park(3, 43), ParkDecision::NeedsMove);
        ledger.record_move(3, 43, 8, FRAME_B, SIZE_B);

        let drained = ledger.drain_all();
        assert_eq!(
            drained,
            vec![
                RestoreTarget {
                    window_id: 42,
                    pid: 7,
                    original: FRAME_A
                },
                RestoreTarget {
                    window_id: 43,
                    pid: 8,
                    original: FRAME_B
                },
            ],
            "42 was held twice and comes back once"
        );
        assert!(ledger.drain_all().is_empty(), "a second drain is a no-op");
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::new());
        assert_eq!(ledger.unpark(1), None, "the drain took the bindings with it");
    }

    #[test]
    fn the_channel_ids_track_every_park_share_release_and_drain() {
        let mut ledger = ParkingLedger::new();
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::new());
        park_and_land(&mut ledger, 1, 42, 7);
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::from([1]));
        let _ = ledger.park(2, 42);
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::from([1, 2]));
        let _ = ledger.unpark(1);
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::from([2]));
        assert!(!ledger.drain_all().is_empty());
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::new());
    }

    #[test]
    fn the_snapshot_holds_one_entry_per_window_in_window_order() {
        let mut ledger = ParkingLedger::new();
        assert!(ledger.entries().is_empty());
        assert_eq!(ledger.park(1, 43), ParkDecision::NeedsMove);
        ledger.record_move(1, 43, 8, FRAME_B, SIZE_B);
        park_and_land(&mut ledger, 2, 42, 7);
        let _ = ledger.park(3, 42);

        assert_eq!(
            window_ids(&ledger),
            vec![42, 43],
            "window order, and the shared window once — the file is compared byte for byte"
        );
        let _ = ledger.unpark(1);
        assert_eq!(
            window_ids(&ledger),
            vec![42],
            "a last-lane release drops the entry"
        );
    }

    #[test]
    fn a_default_ledger_is_an_empty_one() {
        let ledger = ParkingLedger::default();
        assert!(ledger.entries().is_empty());
        assert_eq!(ledger.parked_channel_ids(), BTreeSet::new());
    }
}
