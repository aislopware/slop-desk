//! One pane's subscriber set: the roster, each member's cursors, the retention floor, the producer
//! bound and the laggard rule — docs/45 §8.6, docs/59 step 3.
//!
//! `rust/slopdesk-muxsession`'s `fanout` owns the decisions. This is the door.
//!
//! ## Why this one is a HANDLE
//! The same test [`crate::mux_resize`] and [`crate::pane_outbox`] answer: this is state that lives
//! as long as the pane, is mutated from the read loop, the ack path, every member's sender task and
//! the exit task, and is serialized by exactly ONE `NSLock` — hostd's `subscribersLock`, the
//! innermost lock in that file. Nothing here takes a second lock, because everything here is
//! arithmetic over small integers.
//!
//! ## What did NOT cross
//! The members. A subscriber is a sub-channel PAIR plus four relay tasks, two outbound queues and
//! their `AsyncStream` continuations, and none of that has a shape a C ABI could carry. What
//! crosses is the `u64` the caller assigned it and the cursors that decide what the pane does next.
//! The `retired` latch stays over there for the same reason: it is about the OBJECT's tasks being
//! cancelled, and it outlives membership — a `shutdown()` cancels without retiring the set.
//!
//! ## The eviction ladder is two calls, deliberately
//! Pricing a cursor is an O(retained history) walk the REPLAY BUFFER owns, under a different lock.
//! A door that reached for it would alias state this handle's lock says nothing about, so the
//! decision splits: [`slopdesk_pane_fanout_lagging`] answers WHICH cursors are behind the frontier,
//! the caller prices each under `replayLock`, and [`slopdesk_pane_fanout_evict`] applies the
//! threshold and claims the latch. Both halves of the rule are here; only the query is over there.

use std::sync::OnceLock;

use slopdesk_muxsession::fanout::{Fanout, Priced};

/// One member's ack cursor, for the caller to price against its retained history.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskFanoutCursor {
    /// Which member.
    pub id: u64,
    /// The highest seq it has confirmed.
    pub acked: i64,
}

/// One member's un-acked backlog, as the caller's retained history prices it.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskFanoutPriced {
    /// Which member.
    pub id: u64,
    /// Bytes still retained above its ack cursor.
    pub retained_bytes: u64,
}

/// One pane's subscriber set, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskPaneFanout {
    /// The state the caller's `subscribersLock` guards.
    inner: Fanout,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_pane_fanout_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskPaneFanout) -> Option<&'a mut SlopDeskPaneFanout> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// How far behind the head one member may fall before it is EVICTED rather than buffered for.
///
/// Default 32 MiB (`SLOPDESK_SUB_LAG_BYTES`), deliberately BELOW the replay buffer's 64 MiB offline
/// gate: with N members, evicting the laggard replaces buffering for it, and the gate's
/// pause-the-PTY semantics stay reserved for the case where they still mean what they always meant
/// — nobody is listening. Without this, one sleeping iPhone freezes a build for two Macs. `0`
/// disables eviction. Read ONCE per process, matching the `static let` this replaced.
fn lag_bytes() -> u64 {
    static CACHED: OnceLock<u64> = OnceLock::new();
    *CACHED.get_or_init(|| {
        std::env::var("SLOPDESK_SUB_LAG_BYTES")
            .ok()
            .and_then(|raw| raw.parse::<u64>().ok())
            .unwrap_or(32 * 1024 * 1024)
    })
}

/// The laggard threshold in bytes, for a caller that has to NAME it — the eviction log line.
///
/// The rule itself never leaves this file; this door exists so the number is spelled once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_fanout_lag_bytes() -> u64 {
    lag_bytes()
}

/// An empty set for a fresh pane session.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_fanout_new() -> *mut SlopDeskPaneFanout {
    Box::into_raw(Box::new(SlopDeskPaneFanout { inner: Fanout::new() }))
}

/// Frees a set. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_pane_fanout_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_free(handle: *mut SlopDeskPaneFanout) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// RESERVES the id a pending join will enter under, before the member exists.
///
/// A dead handle answers `0`, which is the primary's id — the same fallback a channel key naming no
/// id already takes, and there is no set for the join to enter either.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_fanout_reserve_id(handle: *mut SlopDeskPaneFanout) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.reserve_id()
}

/// Enters a member under `id`, seeding its ack cursor at `acked`. Replaces any member already
/// there.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_join(handle: *mut SlopDeskPaneFanout, id: u64, acked: i64) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.join(id, acked);
    }
}

/// Drops a member and answers whether the set is now EMPTY. A dead handle answers `true`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_leave(handle: *mut SlopDeskPaneFanout, id: u64) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return true;
    };
    state.inner.leave(id)
}

/// How many members hold this pane right now.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_count(handle: *mut SlopDeskPaneFanout) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.len()
}

/// Writes every member id in ascending order — the deterministic broadcast order.
///
/// Answers the TOTAL count either way, so a caller that sees more than `capacity` retries with a
/// buffer that fits. Nothing is written unless the whole list fits.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable `u64`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_ids(
    handle: *mut SlopDeskPaneFanout,
    out: *mut u64,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let ids = state.inner.ids();
    let count = ids.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // elements by the caller's obligation, and the source is a fresh `Vec` that cannot overlap it.
    unsafe { std::ptr::copy_nonoverlapping(ids.as_ptr(), out, count) };
    count
}

/// Records `id`'s confirmation of `seq` and writes the retention floor over the members that
/// REMAIN.
///
/// Answers `false` for an empty set (nothing written) — the caller falls back to the acked seq
/// itself, which is the ack test seam on a session with no members.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or a writable `i64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_acknowledge(
    handle: *mut SlopDeskPaneFanout,
    id: u64,
    seq: i64,
    out: *mut i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: `out` is null or writable for one `i64` by the caller's obligation.
    unsafe { write_scalar(state.inner.acknowledge(id, seq), out) }
}

/// Writes the lowest ack cursor in the set — how far retention may be released. `false` when empty.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or a writable `i64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_retention_floor(
    handle: *mut SlopDeskPaneFanout,
    out: *mut i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: `out` is null or writable for one `i64` by the caller's obligation.
    unsafe { write_scalar(state.inner.retention_floor(), out) }
}

/// Marks `id` delivered from an OUTBOX, seeding its frontier at `head`, and answers whether THIS
/// call started it — so the caller builds the sender task exactly once.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_start_sender(
    handle: *mut SlopDeskPaneFanout,
    id: u64,
    head: i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.start_sender(id, head)
}

/// Drops `id` back off the producer bound, for a member whose sender has been cancelled.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_clear_sender(handle: *mut SlopDeskPaneFanout, id: u64) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.clear_sender(id);
    }
}

/// Records that `id`'s sender put `seq` on the wire (or died trying).
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_note_sent(handle: *mut SlopDeskPaneFanout, id: u64, seq: i64) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.note_sent(id, seq);
    }
}

/// Writes the delivery frontier — the highest seq the FASTEST outbox-delivered member has shipped.
/// `false` when nobody is delivered from an outbox, which is the whole inline path.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or a writable `i64`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_frontier(
    handle: *mut SlopDeskPaneFanout,
    out: *mut i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: `out` is null or writable for one `i64` by the caller's obligation.
    unsafe { write_scalar(state.inner.frontier(), out) }
}

/// Marks `id`'s `.exit` frame delivered.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_mark_exit_delivered(handle: *mut SlopDeskPaneFanout, id: u64) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.mark_exit_delivered(id);
    }
}

/// Whether `id` is still owed its `.exit`. A member that has LEFT is owed nothing, so a dead handle
/// answers `false` too: the exit task must never hold a teardown open for a set that is gone.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_exit_pending(handle: *mut SlopDeskPaneFanout, id: u64) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.exit_pending(id)
}

/// Writes every member BEHIND the healthiest ack cursor — the eviction ladder's first half.
///
/// Empty for a set of one and for a zero threshold, so a caller that gets `0` pays no replay query
/// at all. Answers the TOTAL count either way; nothing is written unless the whole list fits.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or point to `capacity`
/// writable [`SlopDeskFanoutCursor`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_lagging(
    handle: *mut SlopDeskPaneFanout,
    out: *mut SlopDeskFanoutCursor,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let cursors: Vec<SlopDeskFanoutCursor> = state
        .inner
        .lagging_cursors(lag_bytes())
        .into_iter()
        .map(|cursor| {
            SlopDeskFanoutCursor {
                id: cursor.id,
                acked: cursor.acked,
            }
        })
        .collect();
    let count = cursors.len();
    if count == 0 || count > capacity || out.is_null() {
        return count;
    }
    // SAFETY: `count <= capacity` was just checked, `out` is non-null and writable for `capacity`
    // elements by the caller's obligation, and the source is a fresh `Vec` that cannot overlap it.
    unsafe { std::ptr::copy_nonoverlapping(cursors.as_ptr(), out, count) };
    count
}

/// Applies the threshold to what the caller priced and CLAIMS the eviction latch, writing the ids
/// whose close this call must fire.
///
/// The claimed list can only be shorter than `priced`, so the caller sizes `out` to `count` and the
/// answer always fits — there is no retry, which matters because this call MUTATES.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `priced` must be null or point to `count` readable
/// [`SlopDeskFanoutPriced`]s; `out` must be null or point to `capacity` writable `u64`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_fanout_evict(
    handle: *mut SlopDeskPaneFanout,
    priced: *const SlopDeskFanoutPriced,
    count: usize,
    out: *mut u64,
    capacity: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    if priced.is_null() || count == 0 {
        return 0;
    }
    // SAFETY: `priced` is non-null and readable for `count` elements by the caller's obligation.
    let entries = unsafe { std::slice::from_raw_parts(priced, count) };
    let asked: Vec<Priced> = entries
        .iter()
        .map(|entry| {
            Priced {
                id: entry.id,
                retained_bytes: entry.retained_bytes,
            }
        })
        .collect();
    let claimed = state.inner.latch_evicting(&asked, lag_bytes());
    let claimed_count = claimed.len();
    if claimed_count == 0 || claimed_count > capacity || out.is_null() {
        return claimed_count;
    }
    // SAFETY: `claimed_count <= capacity` was just checked, `out` is non-null and writable for
    // `capacity` elements, and the source is a fresh `Vec` that cannot overlap it.
    unsafe { std::ptr::copy_nonoverlapping(claimed.as_ptr(), out, claimed_count) };
    claimed_count
}

/// Writes `value` through `out` when there is one, and answers whether there was.
///
/// # Safety
/// `out` must be null or point to one writable `i64`.
#[expect(
    unsafe_code,
    reason = "the out-parameter write is the shape every optional scalar here answers through"
)]
const unsafe fn write_scalar(value: Option<i64>, out: *mut i64) -> bool {
    let Some(value) = value else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: `out` was just checked non-null and is writable for one `i64` by the obligation.
        unsafe { out.write(value) };
    }
    true
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SlopDeskFanoutCursor, SlopDeskFanoutPriced, slopdesk_pane_fanout_acknowledge,
        slopdesk_pane_fanout_clear_sender, slopdesk_pane_fanout_count, slopdesk_pane_fanout_evict,
        slopdesk_pane_fanout_exit_pending, slopdesk_pane_fanout_free, slopdesk_pane_fanout_frontier,
        slopdesk_pane_fanout_ids, slopdesk_pane_fanout_join, slopdesk_pane_fanout_lag_bytes,
        slopdesk_pane_fanout_lagging, slopdesk_pane_fanout_leave, slopdesk_pane_fanout_mark_exit_delivered,
        slopdesk_pane_fanout_new, slopdesk_pane_fanout_note_sent, slopdesk_pane_fanout_reserve_id,
        slopdesk_pane_fanout_retention_floor, slopdesk_pane_fanout_start_sender,
    };

    #[test]
    fn the_roster_answers_in_ascending_id_order_and_reports_its_whole_length() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 4, 0);
            slopdesk_pane_fanout_join(handle, 0, 0);
            assert_eq!(slopdesk_pane_fanout_count(handle), 2);
            assert_eq!(slopdesk_pane_fanout_ids(handle, std::ptr::null_mut(), 0), 2);
            let mut ids = [0_u64; 2];
            assert_eq!(slopdesk_pane_fanout_ids(handle, ids.as_mut_ptr(), ids.len()), 2);
            assert_eq!(ids, [0, 4]);
            assert!(!slopdesk_pane_fanout_leave(handle, 4));
            assert!(slopdesk_pane_fanout_leave(handle, 0));
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn a_buffer_that_does_not_fit_is_left_untouched() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 0, 0);
            slopdesk_pane_fanout_join(handle, 1, 0);
            let mut ids = [99_u64; 1];
            assert_eq!(slopdesk_pane_fanout_ids(handle, ids.as_mut_ptr(), 1), 2);
            assert_eq!(
                ids,
                [99],
                "nothing is written into a buffer the list does not fit"
            );
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn the_retention_floor_is_the_slowest_member_and_an_empty_set_has_none() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 0, 0);
            slopdesk_pane_fanout_join(handle, 1, 0);
            let mut floor = -1_i64;
            assert!(slopdesk_pane_fanout_acknowledge(handle, 0, 900, &raw mut floor));
            assert_eq!(floor, 0, "member 1 has confirmed nothing");
            assert!(slopdesk_pane_fanout_acknowledge(handle, 1, 400, &raw mut floor));
            assert_eq!(floor, 400);
            assert!(slopdesk_pane_fanout_retention_floor(handle, &raw mut floor));
            assert_eq!(floor, 400);
            slopdesk_pane_fanout_leave(handle, 0);
            slopdesk_pane_fanout_leave(handle, 1);
            assert!(!slopdesk_pane_fanout_retention_floor(handle, &raw mut floor));
            assert_eq!(floor, 400, "a false answer writes nothing");
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn the_producer_bound_follows_the_fastest_sender_and_clears_with_it() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 0, 0);
            slopdesk_pane_fanout_join(handle, 1, 0);
            let mut frontier = -1_i64;
            assert!(
                !slopdesk_pane_fanout_frontier(handle, &raw mut frontier),
                "inline path"
            );
            assert!(slopdesk_pane_fanout_start_sender(handle, 0, 10));
            assert!(
                !slopdesk_pane_fanout_start_sender(handle, 0, 999),
                "already running"
            );
            assert!(slopdesk_pane_fanout_start_sender(handle, 1, 10));
            slopdesk_pane_fanout_note_sent(handle, 0, 5000);
            slopdesk_pane_fanout_note_sent(handle, 1, 11);
            assert!(slopdesk_pane_fanout_frontier(handle, &raw mut frontier));
            assert_eq!(frontier, 5000);
            slopdesk_pane_fanout_clear_sender(handle, 0);
            assert!(slopdesk_pane_fanout_frontier(handle, &raw mut frontier));
            assert_eq!(frontier, 11, "the cancelled sender stops pinning the producer");
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn an_exit_is_pending_until_delivered_and_a_departed_member_is_owed_nothing() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 0, 0);
            assert!(slopdesk_pane_fanout_exit_pending(handle, 0));
            slopdesk_pane_fanout_mark_exit_delivered(handle, 0);
            assert!(!slopdesk_pane_fanout_exit_pending(handle, 0));
            assert!(!slopdesk_pane_fanout_exit_pending(handle, 7), "never a member");
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn the_eviction_ladder_names_the_laggard_and_latches_it_once() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 0, 900);
            slopdesk_pane_fanout_join(handle, 1, 0);
            let mut cursors = [SlopDeskFanoutCursor::default(); 2];
            let count = slopdesk_pane_fanout_lagging(handle, cursors.as_mut_ptr(), cursors.len());
            assert_eq!(count, 1, "the healthiest member is never a candidate");
            assert_eq!(cursors[0].id, 1);
            assert_eq!(cursors[0].acked, 0);

            let over = slopdesk_pane_fanout_lag_bytes() + 1;
            let priced = [SlopDeskFanoutPriced {
                id: 1,
                retained_bytes: over,
            }];
            let mut doomed = [0_u64; 1];
            let claimed = slopdesk_pane_fanout_evict(
                handle,
                priced.as_ptr(),
                priced.len(),
                doomed.as_mut_ptr(),
                doomed.len(),
            );
            assert_eq!(claimed, 1);
            assert_eq!(doomed, [1]);
            let again = slopdesk_pane_fanout_evict(
                handle,
                priced.as_ptr(),
                priced.len(),
                doomed.as_mut_ptr(),
                doomed.len(),
            );
            assert_eq!(again, 0, "the latch is one-shot");
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn a_member_at_the_threshold_is_buffered_for_rather_than_dropped() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            slopdesk_pane_fanout_join(handle, 0, 900);
            slopdesk_pane_fanout_join(handle, 1, 0);
            let priced = [SlopDeskFanoutPriced {
                id: 1,
                retained_bytes: slopdesk_pane_fanout_lag_bytes(),
            }];
            let mut doomed = [0_u64; 1];
            let claimed = slopdesk_pane_fanout_evict(
                handle,
                priced.as_ptr(),
                priced.len(),
                doomed.as_mut_ptr(),
                doomed.len(),
            );
            assert_eq!(claimed, 0);
            slopdesk_pane_fanout_free(handle);
        }
    }

    #[test]
    fn a_null_handle_is_inert_rather_than_a_crash() {
        unsafe {
            let mut scalar = 7_i64;
            assert_eq!(slopdesk_pane_fanout_reserve_id(std::ptr::null_mut()), 0);
            slopdesk_pane_fanout_join(std::ptr::null_mut(), 1, 0);
            assert!(
                slopdesk_pane_fanout_leave(std::ptr::null_mut(), 1),
                "no set is an empty set"
            );
            assert_eq!(slopdesk_pane_fanout_count(std::ptr::null_mut()), 0);
            assert_eq!(
                slopdesk_pane_fanout_ids(std::ptr::null_mut(), std::ptr::null_mut(), 0),
                0
            );
            assert!(!slopdesk_pane_fanout_acknowledge(
                std::ptr::null_mut(),
                0,
                1,
                &raw mut scalar
            ));
            assert!(!slopdesk_pane_fanout_retention_floor(
                std::ptr::null_mut(),
                &raw mut scalar
            ));
            assert!(!slopdesk_pane_fanout_start_sender(std::ptr::null_mut(), 0, 1));
            slopdesk_pane_fanout_clear_sender(std::ptr::null_mut(), 0);
            slopdesk_pane_fanout_note_sent(std::ptr::null_mut(), 0, 1);
            assert!(!slopdesk_pane_fanout_frontier(
                std::ptr::null_mut(),
                &raw mut scalar
            ));
            slopdesk_pane_fanout_mark_exit_delivered(std::ptr::null_mut(), 0);
            assert!(!slopdesk_pane_fanout_exit_pending(std::ptr::null_mut(), 0));
            assert_eq!(
                slopdesk_pane_fanout_lagging(std::ptr::null_mut(), std::ptr::null_mut(), 0),
                0
            );
            assert_eq!(
                slopdesk_pane_fanout_evict(
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    0
                ),
                0,
            );
            slopdesk_pane_fanout_free(std::ptr::null_mut());
            assert_eq!(scalar, 7, "nothing wrote through the out-parameter");
        }
    }

    #[test]
    fn a_reservation_is_not_a_member_and_leaves_zero_to_the_primary() {
        let handle = slopdesk_pane_fanout_new();
        unsafe {
            assert_eq!(slopdesk_pane_fanout_reserve_id(handle), 1);
            assert_eq!(slopdesk_pane_fanout_reserve_id(handle), 2);
            assert_eq!(slopdesk_pane_fanout_count(handle), 0);
            slopdesk_pane_fanout_free(handle);
        }
    }
}
