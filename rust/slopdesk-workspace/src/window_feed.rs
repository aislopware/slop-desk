//! The host-windows rail's fold: what keeps its place across a snapshot, and when a lane that
//! stopped answering is called stale.
//!
//! `docs/45` §1 names the UX this exists for in one word — STABILITY. The rail lists every window
//! on the host and the host re-sends that list twice a second, so the naive fold (take the
//! snapshot's order) reorders rows under the pointer on every focus flip, title change and refresh
//! tick. What is here instead FREEZES positions: a window that survives keeps the place it had, and
//! only a genuinely new one is appended.
//!
//! This was `HostWindowFeed.apply` and its three lifecycle guards, in Swift. The `@Observable`
//! writes stayed there — a diff-before-publish is what that macro is for — and the folds came here.
//!
//! ## THE FOLD ANSWERS POSITIONS, NEVER WINDOWS
//!
//! A window is a `CGWindowID` and a bundle id, which is IDENTITY, and identity does not cross the
//! boundary (`docs/55` §4b). The caller mints one dense TOKEN per distinct window across BOTH the
//! structure it holds and the snapshot that arrived — one table spanning the comparison, exactly as
//! [`crate::store_shape`]'s two flattenings do — and what comes back is [`FoldSlot`]s naming
//! positions in the two lists the caller still has. The bundle id and app name never travel at all:
//! a survivor keeps the record already in the caller's array, and a newcomer is built from the
//! snapshot row the answer points at.
//!
//! ## THE DOUBLE APPEND IS DELIBERATE
//!
//! [`structure_plan`] computes its "already known" set ONCE, before the append loop, and does not
//! grow it as it appends. So a snapshot that names the same window twice appends it twice. That is
//! what the Swift did, character for character, and it is reproduced rather than repaired: the host
//! does not emit duplicates today, no caller has ever seen the case, and quietly changing what a
//! malformed snapshot produces would be an unreported behaviour change hiding inside a port. If it
//! should be fixed, it should be fixed as a fix.
//!
//! ## THE CLOCK STAYS OUTSIDE
//!
//! [`goes_stale`] takes ELAPSED NANOSECONDS and not two instants, the same split
//! [`crate::gui_readout::stall_caption`] takes. The caller owns `ContinuousClock`; what is here is
//! a comparison against a grace period, and a rule that read the wall clock could not be asked
//! about a chosen moment.

use std::collections::HashSet;

/// Where one entry of the folded structure comes from.
///
/// Both arms carry a POSITION and neither carries a window: `Kept` names the caller's existing
/// structure array, `Added` names the snapshot that just arrived.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FoldSlot {
    /// Keep the identity the caller's structure already holds at this position.
    Kept(usize),
    /// Append a new identity, built from the snapshot row at this position.
    Added(usize),
}

/// The rail's display title: the window's own, or the app's name when the window has none.
///
/// A great many windows are untitled — a palette, a sheet, an app that never set one — and a blank
/// row is unclickable in practice. The app name is always there, so it is what the row falls back
/// to rather than a placeholder nobody can act on.
#[must_use]
pub const fn display_title<'a>(title: &'a str, app_name: &'a str) -> &'a str {
    if title.is_empty() { app_name } else { title }
}

/// The structure after one snapshot: survivors in the order they already had, then the newcomers in
/// the order the host sent them.
///
/// `structure` is the tokens of the identities the caller holds, in its own order; `snapshot` is
/// the tokens of the windows the host just reported, in the host's z-order. The first snapshot
/// therefore seeds in z-order — nothing has a place yet — and every one after it only appends.
///
/// A window that vanished simply does not appear in the answer. Nothing is reordered, ever: that is
/// the whole point, and the reason this is a plan rather than a sort.
#[must_use]
pub fn structure_plan(structure: &[u32], snapshot: &[u32]) -> Vec<FoldSlot> {
    let live: HashSet<u32> = snapshot.iter().copied().collect();
    let mut plan: Vec<FoldSlot> = Vec::with_capacity(structure.len().saturating_add(snapshot.len()));
    for (position, token) in structure.iter().enumerate() {
        if live.contains(token) {
            plan.push(FoldSlot::Kept(position));
        }
    }
    // Computed ONCE — the tokens the survivors above carry — and deliberately not grown by the
    // loop below, which is what makes a duplicated incoming window append twice. Module note.
    let known: HashSet<u32> = structure
        .iter()
        .copied()
        .filter(|token| live.contains(token))
        .collect();
    for (position, token) in snapshot.iter().enumerate() {
        if !known.contains(token) {
            plan.push(FoldSlot::Added(position));
        }
    }
    plan
}

/// The POSITION of the host's focused window in the snapshot, or `None` when none is focused.
///
/// At most one window per snapshot carries the flag, so the FIRST is the answer; a snapshot that
/// somehow carried two would name the earlier, which is what the Swift `first(where:)` did.
#[must_use]
pub fn frontmost(focused: &[bool]) -> Option<usize> {
    focused.iter().position(|is_focused| *is_focused)
}

/// Whether a "you are current" ack may mark the feed LIVE.
///
/// Only when it names the generation this client actually holds. A stale or duplicated datagram
/// acking some older generation is not confirmation of what we have — UDP delivers both — and
/// treating it as one would undim a rail whose contents nothing has confirmed.
#[must_use]
pub const fn ack_marks_live(is_live: bool, acked: u32, known: u32) -> bool {
    !is_live && acked == known
}

/// Whether the renewal interval that just elapsed makes the feed stale.
///
/// The grace is two full renewal gaps plus the first-answer gap: UDP weather loses single
/// datagrams, not multi-second stretches, so one missed reply must not dim a rail that is fine.
/// `elapsed` is `None` when no answer has ever landed, which is not staleness — it is the state
/// before any interval has been timed, and the two gates above it say so.
///
/// Both products saturate. A grace assembled from a corrupt duration would otherwise overflow, and
/// on this boundary an overflow is an aborted process rather than a wrong rail.
#[must_use]
pub const fn goes_stale(
    is_live: bool,
    answered_since_open: bool,
    elapsed_ns: Option<i64>,
    renewal_ns: i64,
    first_answer_ns: i64,
) -> bool {
    if !is_live || !answered_since_open {
        return false;
    }
    let grace = renewal_ns.saturating_mul(2).saturating_add(first_answer_ns);
    match elapsed_ns {
        Some(elapsed) => elapsed > grace,
        None => false,
    }
}

/// How long to wait before the next renewal: the fast retransmit gap until the FIRST answer lands
/// on a freshly opened lane, the ordinary gap after that.
///
/// A lane that just opened has nothing on screen, so it asks again quickly; one that is answering
/// costs the host a fixed low rate. A collapsed rail never reaches this at all — it releases the
/// lane and idles at 0 Hz.
#[must_use]
pub const fn renewal_wait_ns(answered_since_open: bool, renewal_ns: i64, first_answer_ns: i64) -> i64 {
    if answered_since_open {
        renewal_ns
    } else {
        first_answer_ns
    }
}

#[cfg(test)]
mod tests {
    use super::{
        FoldSlot, ack_marks_live, display_title, frontmost, goes_stale, renewal_wait_ns, structure_plan,
    };

    /// Resolves a plan back to the tokens it names, which is what the caller's array rebuild does.
    fn resolve(structure: &[u32], snapshot: &[u32]) -> Vec<u32> {
        structure_plan(structure, snapshot)
            .into_iter()
            .filter_map(|slot| {
                match slot {
                    FoldSlot::Kept(position) => structure.get(position).copied(),
                    FoldSlot::Added(position) => snapshot.get(position).copied(),
                }
            })
            .collect()
    }

    /// The first snapshot seeds in the host's own order — nothing has a place to keep yet.
    #[test]
    fn the_first_snapshot_seeds_in_the_hosts_order() {
        assert_eq!(resolve(&[], &[7, 3, 9]), vec![7, 3, 9]);
        assert_eq!(structure_plan(&[], &[7, 3, 9]), vec![
            FoldSlot::Added(0),
            FoldSlot::Added(1),
            FoldSlot::Added(2),
        ]);
    }

    /// A reordered snapshot moves NOTHING. This is the whole feature: the host re-sends its list in
    /// z-order twice a second, and a rail that followed it would shuffle under the pointer.
    #[test]
    fn a_reordered_snapshot_moves_nothing() {
        assert_eq!(resolve(&[7, 3, 9], &[9, 7, 3]), vec![7, 3, 9]);
        assert_eq!(resolve(&[7, 3, 9], &[3, 9, 7]), vec![7, 3, 9]);
        assert_eq!(structure_plan(&[7, 3, 9], &[9, 7, 3]), vec![
            FoldSlot::Kept(0),
            FoldSlot::Kept(1),
            FoldSlot::Kept(2),
        ]);
    }

    /// A window that closes drops out, the survivors close ranks in their old order, and a new one
    /// lands at the END rather than where the host happened to put it.
    #[test]
    fn a_removal_closes_ranks_and_a_newcomer_appends() {
        assert_eq!(resolve(&[7, 3, 9], &[9, 7]), vec![7, 9]);
        assert_eq!(resolve(&[7, 3, 9], &[4, 9, 7, 3]), vec![7, 3, 9, 4]);
        assert_eq!(resolve(&[7, 3], &[5, 4]), vec![5, 4]);
    }

    /// The whole set turning over at once, and the empty snapshot that clears the rail.
    #[test]
    fn a_full_turnover_and_an_empty_snapshot() {
        assert_eq!(resolve(&[7, 3, 9], &[]), Vec::<u32>::new());
        assert_eq!(structure_plan(&[7, 3, 9], &[]), Vec::new());
        assert_eq!(resolve(&[], &[]), Vec::<u32>::new());
    }

    /// The double append, pinned so it cannot be lost by accident and cannot be changed in silence.
    #[test]
    fn a_duplicated_window_in_one_snapshot_appends_twice() {
        assert_eq!(resolve(&[], &[7, 7]), vec![7, 7]);
        assert_eq!(structure_plan(&[], &[7, 7]), vec![
            FoldSlot::Added(0),
            FoldSlot::Added(1)
        ]);
        // Already known from the structure, so neither copy appends.
        assert_eq!(resolve(&[7], &[7, 7]), vec![7]);
    }

    /// A structure that already holds a window twice keeps both, because the plan names positions
    /// and two positions are two entries.
    #[test]
    fn a_duplicated_window_in_the_structure_keeps_both_places() {
        assert_eq!(structure_plan(&[7, 7], &[7]), vec![
            FoldSlot::Kept(0),
            FoldSlot::Kept(1)
        ]);
        assert_eq!(resolve(&[7, 7], &[7]), vec![7, 7]);
    }

    /// Every plan names only positions that exist, over a sweep of overlapping sets — the property
    /// the caller's array rebuild depends on and the one an off-by-one would break.
    #[test]
    fn every_slot_names_a_position_that_exists() {
        for held in 0_u32..6 {
            for arrived in 0_u32..6 {
                for offset in 0_u32..4 {
                    let structure: Vec<u32> = (0..held).collect();
                    let snapshot: Vec<u32> = (0..arrived).map(|index| index.saturating_add(offset)).collect();
                    for slot in structure_plan(&structure, &snapshot) {
                        match slot {
                            FoldSlot::Kept(position) => assert!(position < structure.len()),
                            FoldSlot::Added(position) => assert!(position < snapshot.len()),
                        }
                    }
                }
            }
        }
    }

    /// A repeated snapshot is a fixed point: fold it twice and the second fold changes nothing.
    #[test]
    fn folding_the_same_snapshot_twice_is_a_fixed_point() {
        let snapshot = vec![9, 7, 3, 4];
        let once = resolve(&[7, 3], &snapshot);
        let twice = resolve(&once, &snapshot);
        assert_eq!(once, twice);
        assert_eq!(once, vec![7, 3, 9, 4]);
    }

    /// The row's title precedence, in both arms and in the case where neither has anything.
    #[test]
    fn a_titleless_window_borrows_its_apps_name() {
        assert_eq!(display_title("", "Xcode"), "Xcode");
        assert_eq!(display_title("Untitled 2", "Xcode"), "Untitled 2");
        assert_eq!(display_title("", ""), "");
        assert_eq!(display_title(" ", "Xcode"), " ", "a blank is not empty");
    }

    /// The focused position, its absence, and the first-wins rule for a snapshot with two.
    #[test]
    fn the_frontmost_is_the_first_flag_and_absent_when_there_is_none() {
        assert_eq!(frontmost(&[false, true, false]), Some(1));
        assert_eq!(frontmost(&[true, true]), Some(0));
        assert_eq!(frontmost(&[false, false]), None);
        assert_eq!(frontmost(&[]), None);
        assert_eq!(frontmost(&[true]), Some(0));
    }

    /// The ack rule over its whole domain: only an ack naming OUR generation, and only when the
    /// feed is not already live.
    #[test]
    fn only_an_ack_that_names_our_generation_marks_the_feed_live() {
        assert!(ack_marks_live(false, 4, 4));
        assert!(!ack_marks_live(false, 3, 4), "a stale datagram confirms nothing");
        assert!(!ack_marks_live(false, 5, 4), "nor does one from the future");
        assert!(!ack_marks_live(true, 4, 4), "already live, nothing to say");
        assert!(
            ack_marks_live(false, 0, 0),
            "the generation nothing has been told yet"
        );
    }

    /// Both gates, then the grace. A feed that is not live, or that has never answered, cannot go
    /// stale — there is no interval to have missed.
    #[test]
    fn the_two_gates_come_before_the_grace() {
        let renewal = 2_000_000_000_i64;
        let first = 500_000_000_i64;
        let ancient = Some(i64::MAX);
        assert!(!goes_stale(false, true, ancient, renewal, first));
        assert!(!goes_stale(true, false, ancient, renewal, first));
        assert!(!goes_stale(true, true, None, renewal, first));
        assert!(goes_stale(true, true, ancient, renewal, first));
    }

    /// The grace is exactly two renewals plus the first-answer gap, and the boundary is STRICT —
    /// an elapsed equal to the grace is not yet stale.
    #[test]
    fn the_grace_is_two_renewals_plus_the_first_gap() {
        let renewal = 2_000_000_000_i64;
        let first = 500_000_000_i64;
        let grace = 4_500_000_000_i64;
        assert!(!goes_stale(true, true, Some(grace - 1), renewal, first));
        assert!(
            !goes_stale(true, true, Some(grace), renewal, first),
            "equal is not past"
        );
        assert!(goes_stale(true, true, Some(grace + 1), renewal, first));
        assert!(!goes_stale(true, true, Some(0), renewal, first));
    }

    /// A corrupt duration saturates rather than overflowing, because on this path an overflow is an
    /// aborted process.
    #[test]
    fn a_corrupt_grace_saturates() {
        assert!(!goes_stale(true, true, Some(i64::MAX), i64::MAX, i64::MAX));
        assert!(goes_stale(true, true, Some(1), i64::MIN, i64::MIN));
    }

    /// Which gap the loop sleeps for, on both sides of the first answer.
    #[test]
    fn the_first_answer_is_chased_faster_than_it_is_renewed() {
        assert_eq!(renewal_wait_ns(false, 2_000_000_000, 500_000_000), 500_000_000);
        assert_eq!(renewal_wait_ns(true, 2_000_000_000, 500_000_000), 2_000_000_000);
    }
}
