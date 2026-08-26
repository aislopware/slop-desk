//! One workspace subscriber's document-sync ladder — docs/59 step 10.
//!
//! `rust/slopdesk-workspace`'s `sync_ladder` owns the decisions. This is the door.
//!
//! ## Verdicts, never the document
//! The document is tens of kilobytes of tree and it never crosses. The ladder reads EPOCHS, STATE
//! NUMBERS and one bit of "snapshot or diff"; the bytes stay in hostd, filed under the SLOT this
//! door mints. A crossing that carried the state would pay a copy of the whole workspace per
//! subscriber per frame — and would put a network peer's payload through a boundary that has no
//! reason to see it.
//!
//! Every call that drops a retained state answers WHICH SLOTS stopped being reachable, into a
//! caller-lent array. The caller lends [`MAX_RELEASED`] of them, which is the widest any single
//! call can be — the four-deep window plus the base — so the write always fits and no door here
//! retries.
//!
//! ## Why this handle is exclusive
//! Like every other hostd handle in this crate except [`crate::pane_lifecycle`], it hands out
//! `&mut` and lets the caller's own `NSLock` serialize. `WorkspaceChannelSession.lock` is that
//! lock: the presence guard and the roster projection already lived under it, and the ladder half
//! was single-threaded by convention rather than by a lock, reachable only from the one send task.
//! Folding both under the lock they already shared costs nothing — it is a leaf, and no call here
//! can span an `await`, which is exactly why `plan` and `commit` are two calls.
//!
//! ## What did NOT cross
//! The `AsyncStream` and its continuation, the send `Task`, the depth-1 pending slot, the diff
//! itself and the channel write. The empty-diff suppression stays with the two states it compares:
//! it is simply not calling [`slopdesk_workspace_sync_commit`], which is what leaves the ladder
//! untouched.

use slopdesk_wire::workspace::WorkspaceSubscribe;
use slopdesk_workspace::sync_ladder::{
    MAX_RELEASED, NO_SLOT, Plan, Presence, RETAINED_SENT_STATES, SyncLadder,
};

use crate::workspace::Uuid;
use crate::workspace_channel::SlopDeskWorkspacePresence;

/// One subscriber's sync ladder, as an opaque handle.
///
/// `Copy` deliberately absent: the handle OWNS a boxed ladder, and a type that copied would let two
/// callers mint the same slot and retain two different states under it.
#[derive(Debug)]
#[expect(
    missing_copy_implementations,
    reason = "a copied ladder is two subscribers sharing one retention window"
)]
pub struct SlopDeskWorkspaceSyncLadder {
    /// The state the caller's `lock` serializes.
    inner: SyncLadder,
}

/// What [`slopdesk_workspace_sync_plan`] asks the caller to build.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWorkspaceSyncPlan {
    /// The `baseStateNum` a diff declares; `0` for a snapshot.
    pub base_state_num: i64,
    /// The slot holding the state a diff is computed FROM, or [`slopdesk_workspace_sync_constant`]
    /// index 2 when there is none.
    pub base_slot: u32,
    /// How many entries of the `released` array were written.
    pub released_count: u32,
    /// Whether to send anything at all. `false` is HOLD: a frame is in flight, nothing changed, and
    /// the offer must stay pending.
    pub send: bool,
    /// Send a `reset` (kind 4) before the frame — the epoch changed.
    pub reset_first: bool,
    /// Send a snapshot (kind 0) rather than a diff (kind 1).
    pub snapshot: bool,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_workspace_sync_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(
    handle: *mut SlopDeskWorkspaceSyncLadder,
) -> Option<&'a mut SlopDeskWorkspaceSyncLadder> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// Writes one record into the caller's slot, when there is one.
///
/// # Safety
/// `out` must be null, or writable for one `T`.
#[expect(
    unsafe_code,
    reason = "writing the caller's single out-record IS the boundary this module documents"
)]
unsafe fn place<T>(out: *mut T, record: T) {
    if out.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one `T` for this call.
    unsafe { out.write(record) };
}

/// Copies the released slots into the caller's array and answers how many there were.
///
/// A null array writes nothing and still answers the count — which strands the payloads it named,
/// so hostd always lends [`MAX_RELEASED`].
///
/// # Safety
/// `out` must be null, or writable for [`MAX_RELEASED`] `uint32_t` for the whole call.
#[expect(
    unsafe_code,
    reason = "writing the caller's slot array IS the boundary this module documents"
)]
unsafe fn place_released(slots: &[u32], out: *mut u32) -> u32 {
    if !out.is_null() {
        for (index, slot) in slots.iter().enumerate() {
            // SAFETY: `slots` is at most `MAX_RELEASED` long by the ladder's own invariant, and by
            // the caller's obligation `out` is writable for that many.
            unsafe { out.add(index).write(*slot) };
        }
    }
    u32::try_from(slots.len()).unwrap_or(0)
}

/// The subscribe flags, unpacked here so the ladder never respells `1 << 0` in a crate that cannot
/// see `slopdesk-wire`.
const fn contributes_size(flags: u8) -> bool {
    flags & WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE != 0
}

/// See [`contributes_size`].
const fn follows_focus(flags: u8) -> bool {
    flags & WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS != 0
}

/// The inverse, for the roster projection.
const fn packed(view: &Presence) -> u8 {
    let mut flags = 0_u8;
    if view.contributes_size {
        flags |= WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE;
    }
    if view.follows_focus {
        flags |= WorkspaceSubscribe::FLAG_FOLLOWS_FOCUS;
    }
    flags
}

/// The presence record as the ladder reads it.
const fn presence_of(record: &SlopDeskWorkspacePresence) -> Presence {
    Presence {
        presence_clock: record.presence_clock,
        viewing_tab_id: record.viewing_tab_id.bytes,
        viewing_pane_id: record.viewing_pane_id.bytes,
        cols: record.cols,
        rows: record.rows,
        contributes_size: contributes_size(record.flags),
        follows_focus: follows_focus(record.flags),
    }
}

/// A fresh ladder for a subscriber that has just sent its `subscribe`.
///
/// `flags` is the subscribe's own byte — the connection's standing claims.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_workspace_sync_new(flags: u8) -> *mut SlopDeskWorkspaceSyncLadder {
    Box::into_raw(Box::new(SlopDeskWorkspaceSyncLadder {
        inner: SyncLadder::new(contributes_size(flags), follows_focus(flags)),
    }))
}

/// Frees a ladder. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_workspace_sync_new`], freed exactly once,
/// with no other thread still calling into it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_free(handle: *mut SlopDeskWorkspaceSyncLadder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Records an ack. Highest wins — an out-of-order or duplicated ack can only move the base forward.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_workspace_sync_note_ack(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    state_num: i64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(ladder) = unsafe { held(handle) } {
        ladder.inner.note_ack(state_num);
    }
}

/// Applies the highest ack seen since the last call and answers which slots that freed.
///
/// An ack naming a state no longer retained latches a SNAPSHOT rather than guessing a base — a
/// diff against the wrong base applies cleanly and corrupts silently. A dead handle frees nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `released` must satisfy
/// [`place_released`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_apply_ack(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    released: *mut u32,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(ladder) = (unsafe { held(handle) }) else {
        return 0;
    };
    let freed = ladder.inner.apply_pending_ack();
    // SAFETY: the caller's obligation above is this function's, restated on `place_released`.
    unsafe { place_released(freed.slots(), released) }
}

/// A repeat `subscribe`, which IS the resync verb.
///
/// The client's claim is honoured only when the epoch matches and that exact state is still
/// retained; everything else re-snapshots. A dead handle frees nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `released` must satisfy
/// [`place_released`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_resubscribe(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    known_epoch: Uuid,
    known_state_num: i64,
    flags: u8,
    released: *mut u32,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(ladder) = (unsafe { held(handle) }) else {
        return 0;
    };
    let freed = ladder.inner.resubscribe(
        known_epoch.bytes,
        known_state_num,
        contributes_size(flags),
        follows_focus(flags),
    );
    // SAFETY: the caller's obligation above is this function's, restated on `place_released`.
    unsafe { place_released(freed.slots(), released) }
}

/// What to do with the freshest document offer, which the caller must NOT have consumed.
///
/// `send == false` is HOLD and changes nothing: the offer stays pending so it coalesces with
/// whatever arrives next. A dead handle holds, because a subscriber with no ladder must not ship a
/// frame nothing is tracking.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `out` must be null or writable for one
/// [`SlopDeskWorkspaceSyncPlan`], and `released` must satisfy [`place_released`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_plan(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    epoch: Uuid,
    out: *mut SlopDeskWorkspaceSyncPlan,
    released: *mut u32,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let plan = unsafe { held(handle) }.map_or(Plan::Hold, |ladder| ladder.inner.plan(epoch.bytes));
    let Plan::Send(frame) = plan else {
        // SAFETY: the caller's obligation above is this function's, restated on `place`.
        unsafe {
            place(out, SlopDeskWorkspaceSyncPlan {
                base_slot: NO_SLOT,
                ..SlopDeskWorkspaceSyncPlan::default()
            });
        }
        return;
    };
    // SAFETY: the caller's obligation above is this function's, restated on `place_released`.
    let released_count = unsafe { place_released(frame.released.slots(), released) };
    // SAFETY: the caller's obligation above is this function's, restated on `place`.
    unsafe {
        place(out, SlopDeskWorkspaceSyncPlan {
            base_state_num: frame.base_state_num,
            base_slot: frame.base_slot,
            released_count,
            send: true,
            reset_first: frame.reset_first,
            snapshot: frame.snapshot,
        });
    }
}

/// Records that the planned frame went out, and answers the SLOT its state is filed under.
///
/// Called only after a successful send: an empty diff and a dead link both end in no commit. A dead
/// handle answers the no-slot sentinel.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `released` must satisfy [`place_released`]'s, and
/// `released_count` must be null or writable for one `uint32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_commit(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    state_num: i64,
    released: *mut u32,
    released_count: *mut u32,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(ladder) = (unsafe { held(handle) }) else {
        // SAFETY: the caller's obligation above is this function's, restated on `place`.
        unsafe { place(released_count, 0) };
        return NO_SLOT;
    };
    let commit = ladder.inner.commit(state_num);
    // SAFETY: the caller's obligation above is this function's, restated on `place_released`.
    let count = unsafe { place_released(commit.released.slots(), released) };
    // SAFETY: the caller's obligation above is this function's, restated on `place`.
    unsafe { place(released_count, count) };
    commit.slot
}

/// The epoch to stamp on a frame that does not depend on one — presence and intent results.
///
/// All-zero before any document has shipped, and for a dead handle.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for one
/// `SlopDeskWsUuid`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_loose_epoch(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    out: *mut Uuid,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let bytes = unsafe { held(handle) }.map_or([0; 16], |ladder| ladder.inner.loose_epoch());
    // SAFETY: the caller's obligation above is this function's, restated on `place`.
    unsafe { place(out, Uuid { bytes }) };
}

/// Records the client's view.
///
/// `false` when the update is REFUSED because its clock is not strictly newer — newest wins with no
/// merge, so a client reconnecting with a stale clock must not resurrect a view it has since left.
/// A dead handle refuses, matching hostd's own closed guard.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `record` must be null or point at one live
/// [`SlopDeskWorkspacePresence`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_note_presence(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    record: *const SlopDeskWorkspacePresence,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(ladder) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: by the caller's obligation this is null or one live record for the call.
    let Some(update) = (unsafe { record.as_ref() }) else {
        return false;
    };
    ladder.inner.note_presence(presence_of(update))
}

/// This subscriber as the host describes it to everyone else: the view and viewport from its last
/// accepted presence update, and the folded flags.
///
/// A silent subscriber views nothing — every id all-zero, every count `0` — rather than views
/// something invented. A dead handle answers the same.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for one
/// [`SlopDeskWorkspacePresence`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_roster(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    out: *mut SlopDeskWorkspacePresence,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let view = unsafe { held(handle) }.map_or_else(Presence::default, |ladder| ladder.inner.roster_view());
    // SAFETY: the caller's obligation above is this function's, restated on `place`.
    unsafe {
        place(out, SlopDeskWorkspacePresence {
            presence_clock: view.presence_clock,
            viewing_tab_id: Uuid {
                bytes: view.viewing_tab_id,
            },
            viewing_pane_id: Uuid {
                bytes: view.viewing_pane_id,
            },
            cols: view.cols,
            rows: view.rows,
            flags: packed(&view),
        });
    }
}

/// The `stateNum` of the frame in flight. `false` when the client is caught up, or the handle is
/// dead.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for one
/// `int64_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_workspace_sync_outstanding(
    handle: *mut SlopDeskWorkspaceSyncLadder,
    out: *mut i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state_num) = (unsafe { held(handle) }).and_then(|ladder| ladder.inner.outstanding()) else {
        return false;
    };
    // SAFETY: the caller's obligation above is this function's, restated on `place`.
    unsafe { place(out, state_num) };
    true
}

/// The three numbers a caller would otherwise respell: `0` the retention window's depth, `1` how
/// many slots to lend a releasing call, `2` the slot that names no payload. `-1` for anything else.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[must_use]
pub extern "C" fn slopdesk_workspace_sync_constant(index: u32) -> i64 {
    let value = match index {
        0 => RETAINED_SENT_STATES,
        1 => MAX_RELEASED,
        2 => return i64::from(NO_SLOT),
        _ => return -1,
    };
    i64::try_from(value).unwrap_or(i64::MAX)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SlopDeskWorkspaceSyncPlan, slopdesk_workspace_sync_apply_ack, slopdesk_workspace_sync_commit,
        slopdesk_workspace_sync_constant, slopdesk_workspace_sync_free, slopdesk_workspace_sync_loose_epoch,
        slopdesk_workspace_sync_new, slopdesk_workspace_sync_note_ack, slopdesk_workspace_sync_note_presence,
        slopdesk_workspace_sync_outstanding, slopdesk_workspace_sync_plan,
        slopdesk_workspace_sync_resubscribe, slopdesk_workspace_sync_roster,
    };
    use crate::workspace::Uuid;
    use crate::workspace_channel::SlopDeskWorkspacePresence;

    const EPOCH_A: Uuid = Uuid { bytes: [1; 16] };
    const EPOCH_B: Uuid = Uuid { bytes: [2; 16] };
    const BOTH_FLAGS: u8 = 0b0000_0011;

    fn no_slot() -> u32 {
        u32::try_from(slopdesk_workspace_sync_constant(2)).unwrap_or(0)
    }

    fn max_released() -> usize {
        usize::try_from(slopdesk_workspace_sync_constant(1)).unwrap_or(0)
    }

    #[test]
    fn a_fresh_subscriber_snapshots_then_diffs_against_what_it_acked() {
        let handle = slopdesk_workspace_sync_new(BOTH_FLAGS);
        let mut released = vec![0_u32; max_released()];
        unsafe {
            let mut plan = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut plan, released.as_mut_ptr());
            assert!(plan.send);
            assert!(plan.snapshot);
            assert!(!plan.reset_first);
            assert_eq!(plan.base_slot, no_slot());
            assert_eq!(plan.released_count, 0);

            let mut count = 0_u32;
            let slot = slopdesk_workspace_sync_commit(handle, 1, released.as_mut_ptr(), &raw mut count);
            assert_ne!(slot, no_slot());
            assert_eq!(count, 0);

            let mut outstanding = 0_i64;
            assert!(slopdesk_workspace_sync_outstanding(handle, &raw mut outstanding));
            assert_eq!(outstanding, 1);

            // A second offer while that frame is in flight HOLDS, and changes nothing.
            let mut held = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut held, released.as_mut_ptr());
            assert!(!held.send);

            slopdesk_workspace_sync_note_ack(handle, 1);
            assert_eq!(
                slopdesk_workspace_sync_apply_ack(handle, released.as_mut_ptr()),
                0
            );
            assert!(!slopdesk_workspace_sync_outstanding(handle, &raw mut outstanding));

            let mut next = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut next, released.as_mut_ptr());
            assert!(next.send);
            assert!(!next.snapshot);
            assert_eq!(next.base_state_num, 1);
            assert_eq!(next.base_slot, slot);
            slopdesk_workspace_sync_free(handle);
        }
    }

    #[test]
    fn an_epoch_change_resets_and_hands_back_every_slot_it_stopped_needing() {
        let handle = slopdesk_workspace_sync_new(BOTH_FLAGS);
        let mut released = vec![0_u32; max_released()];
        unsafe {
            let mut plan = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut plan, released.as_mut_ptr());
            let mut count = 0_u32;
            let first = slopdesk_workspace_sync_commit(handle, 1, released.as_mut_ptr(), &raw mut count);
            slopdesk_workspace_sync_note_ack(handle, 1);
            slopdesk_workspace_sync_apply_ack(handle, released.as_mut_ptr());

            slopdesk_workspace_sync_plan(handle, EPOCH_B, &raw mut plan, released.as_mut_ptr());
            assert!(plan.reset_first);
            assert!(plan.snapshot);
            assert_eq!(plan.released_count, 1);
            assert_eq!(released.first().copied(), Some(first));
            slopdesk_workspace_sync_free(handle);
        }
    }

    #[test]
    fn a_resubscribe_naming_a_state_we_no_longer_hold_re_snapshots() {
        let handle = slopdesk_workspace_sync_new(BOTH_FLAGS);
        let mut released = vec![0_u32; max_released()];
        unsafe {
            let mut plan = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut plan, released.as_mut_ptr());
            let mut count = 0_u32;
            slopdesk_workspace_sync_commit(handle, 1, released.as_mut_ptr(), &raw mut count);
            let freed =
                slopdesk_workspace_sync_resubscribe(handle, EPOCH_A, 99, BOTH_FLAGS, released.as_mut_ptr());
            assert_eq!(freed, 1, "the state it never got is not a base");
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut plan, released.as_mut_ptr());
            assert!(plan.snapshot);
            slopdesk_workspace_sync_free(handle);
        }
    }

    #[test]
    fn the_loose_epoch_is_all_zero_until_a_document_ships() {
        let handle = slopdesk_workspace_sync_new(0);
        let mut released = vec![0_u32; max_released()];
        unsafe {
            let mut epoch = Uuid { bytes: [9; 16] };
            slopdesk_workspace_sync_loose_epoch(handle, &raw mut epoch);
            assert_eq!(epoch.bytes, [0; 16]);
            let mut plan = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(handle, EPOCH_A, &raw mut plan, released.as_mut_ptr());
            slopdesk_workspace_sync_loose_epoch(handle, &raw mut epoch);
            assert_eq!(epoch.bytes, EPOCH_A.bytes);
            slopdesk_workspace_sync_free(handle);
        }
    }

    #[test]
    fn presence_is_newest_wins_and_the_roster_folds_the_two_flag_sources() {
        let handle = slopdesk_workspace_sync_new(BOTH_FLAGS);
        unsafe {
            let mut roster = SlopDeskWorkspacePresence::default();
            slopdesk_workspace_sync_roster(handle, &raw mut roster);
            assert_eq!(
                roster.flags, BOTH_FLAGS,
                "a silent subscriber keeps its subscribe claims"
            );
            assert_eq!(roster.viewing_pane_id.bytes, [0; 16]);
            assert_eq!(roster.cols, 0);

            let update = SlopDeskWorkspacePresence {
                presence_clock: 4,
                viewing_tab_id: Uuid { bytes: [3; 16] },
                viewing_pane_id: Uuid { bytes: [4; 16] },
                cols: 120,
                rows: 30,
                // Neither flag: the window says it should not be counted in the size fold.
                flags: 0,
            };
            assert!(slopdesk_workspace_sync_note_presence(handle, &raw const update));
            assert!(
                !slopdesk_workspace_sync_note_presence(handle, &raw const update),
                "an equal clock is refused"
            );
            slopdesk_workspace_sync_roster(handle, &raw mut roster);
            assert_eq!(roster.presence_clock, 4);
            assert_eq!(roster.cols, 120);
            assert_eq!(
                roster.flags, 0b0000_0010,
                "the size claim is the window's; the focus claim is the connection's"
            );
            slopdesk_workspace_sync_free(handle);
        }
    }

    #[test]
    fn a_dead_handle_holds_every_offer_and_frees_nothing() {
        let dead: *mut super::SlopDeskWorkspaceSyncLadder = std::ptr::null_mut();
        let mut released = vec![0_u32; max_released()];
        unsafe {
            let mut plan = SlopDeskWorkspaceSyncPlan::default();
            slopdesk_workspace_sync_plan(dead, EPOCH_A, &raw mut plan, released.as_mut_ptr());
            assert!(!plan.send, "a subscriber with no ladder must ship nothing");
            slopdesk_workspace_sync_note_ack(dead, 4);
            assert_eq!(slopdesk_workspace_sync_apply_ack(dead, released.as_mut_ptr()), 0);
            assert_eq!(
                slopdesk_workspace_sync_resubscribe(dead, EPOCH_A, 1, 0, released.as_mut_ptr()),
                0
            );
            let mut count = 9_u32;
            assert_eq!(
                slopdesk_workspace_sync_commit(dead, 1, released.as_mut_ptr(), &raw mut count),
                no_slot()
            );
            assert_eq!(count, 0);
            let mut epoch = Uuid { bytes: [9; 16] };
            slopdesk_workspace_sync_loose_epoch(dead, &raw mut epoch);
            assert_eq!(epoch.bytes, [0; 16]);
            let update = SlopDeskWorkspacePresence::default();
            assert!(!slopdesk_workspace_sync_note_presence(dead, &raw const update));
            let mut roster = SlopDeskWorkspacePresence {
                cols: 9,
                ..Default::default()
            };
            slopdesk_workspace_sync_roster(dead, &raw mut roster);
            assert_eq!(roster.cols, 0);
            let mut outstanding = 7_i64;
            assert!(!slopdesk_workspace_sync_outstanding(dead, &raw mut outstanding));
            slopdesk_workspace_sync_free(dead);
        }
    }

    #[test]
    fn a_null_out_parameter_is_inert_everywhere() {
        let handle = slopdesk_workspace_sync_new(BOTH_FLAGS);
        unsafe {
            slopdesk_workspace_sync_plan(handle, EPOCH_A, std::ptr::null_mut(), std::ptr::null_mut());
            let slot = slopdesk_workspace_sync_commit(handle, 1, std::ptr::null_mut(), std::ptr::null_mut());
            assert_ne!(slot, no_slot());
            slopdesk_workspace_sync_note_ack(handle, 1);
            assert_eq!(slopdesk_workspace_sync_apply_ack(handle, std::ptr::null_mut()), 0);
            slopdesk_workspace_sync_loose_epoch(handle, std::ptr::null_mut());
            slopdesk_workspace_sync_roster(handle, std::ptr::null_mut());
            assert!(!slopdesk_workspace_sync_note_presence(handle, std::ptr::null()));
            slopdesk_workspace_sync_free(handle);
        }
    }

    #[test]
    fn the_constants_are_the_ones_the_caller_would_otherwise_respell() {
        assert_eq!(slopdesk_workspace_sync_constant(0), 4);
        assert_eq!(slopdesk_workspace_sync_constant(1), 5);
        assert_eq!(slopdesk_workspace_sync_constant(2), i64::from(u32::MAX));
        assert_eq!(slopdesk_workspace_sync_constant(99), -1);
    }
}
