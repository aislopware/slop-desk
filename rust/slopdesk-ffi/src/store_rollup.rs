//! What a whole list of panes says, and what a ring keeps, in C.
//!
//! The rules are `slopdesk_workspace::store_rollup`; what is here is the marshalling.
//!
//! ## The two rollups answer BY VALUE
//!
//! A rolled-up progress is a discriminant and a percent — two bytes — and a rolled-up completion is
//! one. Neither needs the `(out, cap) -> needed` protocol, because neither has a size the call
//! decides: they are §4's "entry whose answer is one small record", and the absence of a rollup is
//! a `kind` of `0` rather than a return code, so a caller reads one field instead of two.
//!
//! The progress `kind` is the WIRE's own `OSC 9;4` discriminant — `1` in progress, `2` error, `3`
//! indeterminate — the same byte `slopdesk_ws_dock_tile` already takes, so a rollup handed straight
//! from one door to the other never changes vocabulary on the way.
//!
//! ## No identity crosses, so one door serves four rings
//!
//! The ring push is the interesting one. Its four callers ring `SessionID`s, `PaneID`s, palette
//! catalogue ids and clipboard texts — nothing in common as data — so what crosses is one ROLE byte
//! per existing entry and what comes back is one SLOT per surviving entry, naming where it came
//! from. The comparison that assigns the roles stays on the near side, where the values are; the
//! policy that reads them is here, once, instead of four times in Swift.

use core::ffi::c_uchar;

use slopdesk_workspace::store_rollup::{self, Completion, Progress, Role, Slot};

use crate::borrow;

/// One leaf's `OSC 9;4` progress, and the rollup over a set of them.
///
/// `kind` is the wire's own discriminant: `1` determinate, `2` error, `3` indeterminate. `0` — and
/// anything this build cannot name — is the ABSENCE of an indicator, which is a real answer both on
/// the way in (a pane with no progress) and on the way out (no leaf had any).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsLeafProgress {
    /// `0` none · `1` determinate · `2` error · `3` indeterminate.
    pub kind: c_uchar,
    /// The percent the two value-carrying kinds hold; meaningless for the other two.
    pub percent: c_uchar,
}

/// Where one entry of a pushed ring came from.
///
/// `kind` is `0` keep the caller's entry at `index`, `1` the entry being pushed, `2` the outgoing
/// entry seeded behind it. `index` is meaningful only for `0` — the other two name entries that are
/// not in the caller's list at all, which is exactly why this is a flag beside a value rather than
/// a position with two reserved numbers in it.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskWsRingSlot {
    /// The position in the caller's existing ring; read it only when `kind` is `0`.
    pub index: u32,
    /// `0` keep `index` · `1` the incoming entry · `2` the seeded previous.
    pub kind: c_uchar,
}

/// The wire's `OSC 9;4` discriminant, as one leaf's progress. Anything unnamed is the absence.
const fn progress_of(kind: c_uchar, percent: c_uchar) -> Option<Progress> {
    match kind {
        1 => Some(Progress::Determinate(percent)),
        2 => Some(Progress::Error(percent)),
        3 => Some(Progress::Indeterminate),
        _ => None,
    }
}

/// `1` success · `2` failure. Anything else is the absence of a badge — the conservative reading,
/// because inventing a failure for a pane that reported nothing is the one answer that interrupts
/// somebody for no reason.
const fn completion_of(raw: c_uchar) -> Option<Completion> {
    match raw {
        1 => Some(Completion::Success),
        2 => Some(Completion::Failure),
        _ => None,
    }
}

/// `1` the entry being pushed · `2` the outgoing entry. Anything else is an ordinary entry, which
/// is the reading that cannot lose data: an unnamed byte keeps its place rather than being dropped.
const fn role_of(raw: c_uchar) -> Role {
    match raw {
        1 => Role::Selected,
        2 => Role::Previous,
        _ => Role::Plain,
    }
}

/// The ERROR-DOMINANT progress rollup over a set of leaves.
///
/// Any error wins, at the FIRST failing leaf's percent; else any determinate value, at the MAX
/// percent; else any spinner; else nothing, which crosses back as a `kind` of `0`.
///
/// # Safety
/// `(states, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_aggregate_progress(
    states: *const SlopDeskWsLeafProgress,
    len: usize,
) -> SlopDeskWsLeafProgress {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(states, len) };
    let leaves: Vec<Option<Progress>> = lent
        .iter()
        .map(|leaf| progress_of(leaf.kind, leaf.percent))
        .collect();
    match store_rollup::aggregate_progress(&leaves) {
        Some(Progress::Determinate(percent)) => SlopDeskWsLeafProgress { kind: 1, percent },
        Some(Progress::Error(percent)) => SlopDeskWsLeafProgress { kind: 2, percent },
        Some(Progress::Indeterminate) => SlopDeskWsLeafProgress { kind: 3, percent: 0 },
        None => SlopDeskWsLeafProgress::default(),
    }
}

/// The completion rollup over a set of leaves: `2` if any leaf failed, else `1` if any succeeded,
/// else `0`.
///
/// # Safety
/// `(badges, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_rollup_completion(badges: *const c_uchar, len: usize) -> c_uchar {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(badges, len) };
    let read: Vec<Option<Completion>> = lent.iter().map(|raw| completion_of(*raw)).collect();
    match store_rollup::rollup_completion(&read) {
        Some(Completion::Success) => 1,
        Some(Completion::Failure) => 2,
        None => 0,
    }
}

/// The dedupe-to-front-and-cap every ring in the store runs, as SLOTS into the caller's own ring.
///
/// `roles` carries one byte per existing entry, in the ring's order. `has_previous` says there is
/// an outgoing entry to retain behind the push; when no role names it, it is seeded as the answer's
/// second slot. A `previous` equal to the `selected` is not a previous — the near side resolves
/// that collision by passing `false`, because both spellings of it collapse to the plain push.
///
/// Returns the count NEEDED. A short or null `out` is written nothing and told the length, the same
/// contract every other counted door here keeps.
///
/// # Safety
/// `(roles, len)` must be readable for the call, and `out` writable for `capacity` slots.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_ring_push(
    roles: *const c_uchar,
    len: usize,
    has_previous: bool,
    cap: usize,
    out: *mut SlopDeskWsRingSlot,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(roles, len) };
    let read: Vec<Role> = lent.iter().map(|raw| role_of(*raw)).collect();
    let slots: Vec<SlopDeskWsRingSlot> = store_rollup::push(&read, has_previous, cap)
        .into_iter()
        .map(|slot| {
            match slot {
                Slot::Incoming => SlopDeskWsRingSlot { index: 0, kind: 1 },
                Slot::Retained => SlopDeskWsRingSlot { index: 0, kind: 2 },
                Slot::Kept(index) => SlopDeskWsRingSlot { index, kind: 0 },
            }
        })
        .collect();
    let count = slots.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // slots by the caller's obligation, and `slots` was allocated inside this call, so the two
    // cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(slots.as_ptr(), out, count) };
    count
}

/// The POSITION of the first ring entry that survives, or `-1` when none does.
///
/// `-1` is outside the answer's range by construction — a position into a list is never negative —
/// so no `size_t` sentinel is needed and `0`, which is the most common landing a visit ring has,
/// stays available as a real answer. `survives` carries one flag per entry, in the ring's order.
///
/// # Safety
/// `(survives, len)` must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_most_recent_survivor(survives: *const bool, len: usize) -> isize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(survives, len) };
    store_rollup::most_recent_survivor(lent).map_or(-1, |position| isize::try_from(position).unwrap_or(-1))
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::store_rollup::{self, Completion, Progress, Role};

    use super::{
        SlopDeskWsLeafProgress, SlopDeskWsRingSlot, slopdesk_ws_aggregate_progress,
        slopdesk_ws_most_recent_survivor, slopdesk_ws_ring_push, slopdesk_ws_rollup_completion,
    };

    /// The two bytes one leaf's progress crosses as.
    const fn leaf(state: Option<Progress>) -> SlopDeskWsLeafProgress {
        match state {
            Some(Progress::Determinate(percent)) => SlopDeskWsLeafProgress { kind: 1, percent },
            Some(Progress::Error(percent)) => SlopDeskWsLeafProgress { kind: 2, percent },
            Some(Progress::Indeterminate) => SlopDeskWsLeafProgress { kind: 3, percent: 0 },
            None => SlopDeskWsLeafProgress { kind: 0, percent: 0 },
        }
    }

    /// The byte one completion badge crosses as.
    const fn badge(state: Option<Completion>) -> u8 {
        match state {
            Some(Completion::Success) => 1,
            Some(Completion::Failure) => 2,
            None => 0,
        }
    }

    /// The byte one ring role crosses as.
    const fn role(role: Role) -> u8 {
        match role {
            Role::Plain => 0,
            Role::Selected => 1,
            Role::Previous => 2,
        }
    }

    /// Every leaf state, in every position of a three-leaf set, crosses to the verdict the rule
    /// gives directly — the differential the boundary exists to keep true.
    #[test]
    fn every_progress_rollup_crosses_verbatim() {
        let vocabulary = [
            None,
            Some(Progress::Indeterminate),
            Some(Progress::Determinate(0)),
            Some(Progress::Determinate(61)),
            Some(Progress::Error(0)),
            Some(Progress::Error(44)),
        ];
        for first in vocabulary {
            for second in vocabulary {
                for third in vocabulary {
                    let states = [leaf(first), leaf(second), leaf(third)];
                    // SAFETY: `states` is a live local for the call.
                    let crossed = unsafe { slopdesk_ws_aggregate_progress(states.as_ptr(), states.len()) };
                    let native = store_rollup::aggregate_progress(&[first, second, third]);
                    assert_eq!(crossed, leaf(native), "{first:?} {second:?} {third:?}");
                }
            }
        }
    }

    /// An empty set and a null pointer are the same answer, and it is the absence.
    #[test]
    fn no_leaves_roll_up_to_a_zero_kind() {
        // SAFETY: a null pointer with a zero length is the documented empty case.
        let empty = unsafe { slopdesk_ws_aggregate_progress(core::ptr::null(), 0) };
        assert_eq!(empty, SlopDeskWsLeafProgress::default());
        // SAFETY: `states` is a live local for the call.
        let none = unsafe {
            let states = [leaf(None), leaf(None)];
            slopdesk_ws_aggregate_progress(states.as_ptr(), states.len())
        };
        assert_eq!(none, SlopDeskWsLeafProgress::default());
    }

    /// A `kind` this build cannot name reads as the absence rather than as an arbitrary state.
    #[test]
    fn an_unnamed_progress_kind_reads_as_absence() {
        let states = [
            SlopDeskWsLeafProgress {
                kind: 200,
                percent: 99,
            },
            leaf(Some(Progress::Indeterminate)),
        ];
        // SAFETY: `states` is a live local for the call.
        let crossed = unsafe { slopdesk_ws_aggregate_progress(states.as_ptr(), states.len()) };
        assert_eq!(crossed, leaf(Some(Progress::Indeterminate)));
    }

    /// The percent rides back with the kind that carries it, and the spinner carries none.
    #[test]
    fn the_error_percent_survives_the_crossing() {
        let states = [
            leaf(Some(Progress::Determinate(100))),
            leaf(Some(Progress::Error(7))),
        ];
        // SAFETY: `states` is a live local for the call.
        let crossed = unsafe { slopdesk_ws_aggregate_progress(states.as_ptr(), states.len()) };
        assert_eq!(crossed, SlopDeskWsLeafProgress { kind: 2, percent: 7 });
    }

    /// Every badge set of three crosses to the verdict the rule gives directly.
    #[test]
    fn every_completion_rollup_crosses_verbatim() {
        let vocabulary = [None, Some(Completion::Success), Some(Completion::Failure)];
        for first in vocabulary {
            for second in vocabulary {
                for third in vocabulary {
                    let badges = [badge(first), badge(second), badge(third)];
                    // SAFETY: `badges` is a live local for the call.
                    let crossed = unsafe { slopdesk_ws_rollup_completion(badges.as_ptr(), badges.len()) };
                    let native = store_rollup::rollup_completion(&[first, second, third]);
                    assert_eq!(crossed, badge(native), "{first:?} {second:?} {third:?}");
                }
            }
        }
    }

    /// An unnamed badge byte reads as no badge — never as a failure nobody reported.
    #[test]
    fn an_unnamed_badge_byte_reads_as_absence() {
        let badges = [9_u8, 250, 0];
        // SAFETY: `badges` is a live local for the call.
        let crossed = unsafe { slopdesk_ws_rollup_completion(badges.as_ptr(), badges.len()) };
        assert_eq!(crossed, 0);
        // SAFETY: a null pointer with a zero length is the documented empty case.
        assert_eq!(unsafe { slopdesk_ws_rollup_completion(core::ptr::null(), 0) }, 0);
    }

    /// Reads the door's answer out of a buffer sized to the count it asked for.
    fn pushed(roles: &[u8], has_previous: bool, cap: usize) -> Vec<SlopDeskWsRingSlot> {
        // SAFETY: `roles` is the caller's live slice and `out` is null, the documented size call.
        let needed = unsafe {
            slopdesk_ws_ring_push(
                roles.as_ptr(),
                roles.len(),
                has_previous,
                cap,
                core::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![SlopDeskWsRingSlot::default(); needed];
        // SAFETY: `roles` and `out` are live for the call, and `out` holds exactly `needed` slots.
        let count = unsafe {
            slopdesk_ws_ring_push(
                roles.as_ptr(),
                roles.len(),
                has_previous,
                cap,
                out.as_mut_ptr(),
                needed,
            )
        };
        assert_eq!(count, needed, "the size call and the read call must agree");
        out
    }

    /// The three plain rings: a repeat moves to the front rather than duplicating, and the rest
    /// keep their order one rung back.
    #[test]
    fn a_plain_push_crosses_as_incoming_then_the_survivors() {
        let roles = [role(Role::Plain), role(Role::Selected), role(Role::Plain)];
        assert_eq!(pushed(&roles, false, 8), vec![
            SlopDeskWsRingSlot { index: 0, kind: 1 },
            SlopDeskWsRingSlot { index: 0, kind: 0 },
            SlopDeskWsRingSlot { index: 2, kind: 0 },
        ]);
    }

    /// The session-retention half: an absent previous is seeded as the second slot, and a present
    /// one keeps the place it already had.
    #[test]
    fn the_previous_crosses_as_its_own_kind() {
        assert_eq!(pushed(&[], true, 2), vec![
            SlopDeskWsRingSlot { index: 0, kind: 1 },
            SlopDeskWsRingSlot { index: 0, kind: 2 },
        ]);
        assert_eq!(
            pushed(&[role(Role::Previous), role(Role::Plain)], true, 2),
            vec![SlopDeskWsRingSlot { index: 0, kind: 1 }, SlopDeskWsRingSlot {
                index: 0,
                kind: 0
            },],
            "the previous is kept where it is, not promoted"
        );
    }

    /// An unnamed role byte keeps its place — the reading that cannot lose an entry.
    #[test]
    fn an_unnamed_role_byte_is_an_ordinary_entry() {
        assert_eq!(pushed(&[77, 200], false, 8), vec![
            SlopDeskWsRingSlot { index: 0, kind: 1 },
            SlopDeskWsRingSlot { index: 0, kind: 0 },
            SlopDeskWsRingSlot { index: 1, kind: 0 },
        ]);
    }

    /// A short buffer is told the length and written nothing, and a cap of zero answers zero.
    #[test]
    fn a_short_buffer_is_told_the_length_and_written_nothing() {
        let roles = [role(Role::Plain), role(Role::Plain)];
        let mut short = [SlopDeskWsRingSlot::default(); 1];
        // SAFETY: both arrays are live locals for the call.
        let needed =
            unsafe { slopdesk_ws_ring_push(roles.as_ptr(), roles.len(), false, 8, short.as_mut_ptr(), 1) };
        assert_eq!(needed, 3);
        assert_eq!(short, [SlopDeskWsRingSlot::default()], "and untouched");

        // SAFETY: `roles` is a live local and `out` is null, the documented size call.
        let capped =
            unsafe { slopdesk_ws_ring_push(roles.as_ptr(), roles.len(), false, 0, core::ptr::null_mut(), 0) };
        assert_eq!(capped, 0, "a ring that keeps nothing keeps nothing");
    }

    /// An empty ring is still a push, and a null `roles` is answered rather than dereferenced.
    #[test]
    fn an_empty_ring_still_answers_the_incoming_entry() {
        // SAFETY: a null pointer with a zero length is the documented empty case.
        let needed =
            unsafe { slopdesk_ws_ring_push(core::ptr::null(), 0, false, 4, core::ptr::null_mut(), 0) };
        assert_eq!(needed, 1);
        assert_eq!(pushed(&[], false, 4), vec![SlopDeskWsRingSlot {
            index: 0,
            kind: 1
        }]);
    }

    /// The survivor walk crosses as a position, and its refusal is `-1`.
    #[test]
    fn the_survivor_walk_crosses_as_a_position() {
        let survives = [false, false, true, true];
        // SAFETY: `survives` is a live local for the call.
        let crossed = unsafe { slopdesk_ws_most_recent_survivor(survives.as_ptr(), survives.len()) };
        assert_eq!(crossed, 2);

        let first = [true, false];
        // SAFETY: `first` is a live local for the call.
        assert_eq!(
            unsafe { slopdesk_ws_most_recent_survivor(first.as_ptr(), first.len()) },
            0,
            "position zero is a real answer, which is why the refusal is negative"
        );
    }

    #[test]
    fn a_ring_with_no_survivor_refuses() {
        let dead = [false, false];
        // SAFETY: `dead` is a live local for the call.
        assert_eq!(
            unsafe { slopdesk_ws_most_recent_survivor(dead.as_ptr(), dead.len()) },
            -1
        );
        // SAFETY: a null pointer with a zero length is the documented empty case.
        assert_eq!(
            unsafe { slopdesk_ws_most_recent_survivor(core::ptr::null(), 0) },
            -1
        );
    }
}
