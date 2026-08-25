//! What the detached-session store keeps, in C.
//!
//! The rules are `slopdesk_muxsession::detach_retention`; what is here is the marshalling.
//!
//! ## No identity crosses, so a store of live objects can be reasoned about by a pure crate
//!
//! A parked session is a `UUID` and a `final class` instance holding a PTY. Neither can cross, and
//! neither needs to: the near side answers the two questions only it can — *is this the same OBJECT
//! arriving twice* (`===`, which is not `==`) and *where in the list I am handing you does that id
//! already sit* — and every answer comes back as a POSITION into that same list. It is
//! [`crate::store_shape`]'s convention, one target over.
//!
//! ## The stamps cross as raw `f64`
//!
//! `detachedAt` is Foundation's `timeIntervalSinceReferenceDate`, unconverted. Nothing on the far
//! side does arithmetic on it — both rules only ORDER stamps, through `f64::total_cmp`, a total
//! order over every bit pattern including the ones `<` refuses to rank. Widening to integer
//! nanoseconds would be float arithmetic in a tree that pins float behaviour, to answer a question
//! that never needed the magnitude.

use slopdesk_muxsession::detach_retention::{self, Occupant};

use crate::{borrow, optional, optional_of, saturating_u32, spill};

/// What one insert does to the store.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskHostDetachInsert {
    /// The position of the entry to evict for room; read only when `has_victim`.
    pub victim: usize,
    /// Whether the cap bit at all. Unbounded stores — the default — never set it.
    pub has_victim: bool,
    /// The store already holds this very session: keep the ORIGINAL entry, with its `detachedAt`
    /// and its armed TTL, and do nothing else. Overwriting would leak the first entry's TTL task
    /// un-cancelled, and that stale timer would later kill whatever live entry holds the id.
    pub idempotent: bool,
    /// A DIFFERENT session holds this id: newest wins, and the displaced entry's TTL must be
    /// cancelled before it evicts the new one. Whether the displaced SESSION may then be reaped is
    /// the caller's — a session with subscribers is live, and killing it here would take down a
    /// client's running agent to make room for a store entry.
    pub displace: bool,
}

/// The insert rule, over the `detachedAt` stamps of every entry the store currently holds.
///
/// `has_occupant`/`occupant` name the entry already filed under the incoming session's id, and
/// `same_session` is the caller's `===`. `has_cap`/`cap` are the OPT-IN
/// `SLOPDESK_DETACH_MAX_SESSIONS` bound; absent is UNBOUNDED, which is the default and the
/// tmux/zellij semantics — never silently kill a live detached session.
///
/// # Safety
/// `(stamps, len)` must describe `len` live `double`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_detach_insert(
    stamps: *const f64,
    len: usize,
    has_occupant: bool,
    occupant: usize,
    same_session: bool,
    has_cap: bool,
    cap: usize,
) -> SlopDeskHostDetachInsert {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(stamps, len) };
    let held = optional_of(
        has_occupant,
        Occupant {
            position: occupant,
            same_session,
        },
    );
    let verdict = detach_retention::insert_verdict(lent, held, optional_of(has_cap, cap));
    let (has_victim, victim) = optional(verdict.victim, 0);
    SlopDeskHostDetachInsert {
        victim,
        has_victim,
        idempotent: verdict.idempotent,
        displace: verdict.displace,
    }
}

/// Every stored entry in `detachedAt` order, as positions into the stamps handed in.
///
/// Answers the count NEEDED, which is always `len` — so a caller that lends `len` slots never
/// travels the retry path, and the arithmetic bound is the guess `docs/55` §4 asks for rather than
/// a hunch. Ties keep the caller's own order, which is what makes the listing stable.
///
/// # Safety
/// `(stamps, len)` must describe `len` live `double`s, and `out` be null or writable for `cap`
/// positions, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_host_detach_order(
    stamps: *const f64,
    len: usize,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let lent = unsafe { borrow(stamps, len) };
    let order: Vec<u32> = detach_retention::detached_order(lent)
        .into_iter()
        .map(saturating_u32)
        .collect();
    // SAFETY: `out` is null or writable for `cap` positions, by the caller's obligation.
    unsafe { spill(&order, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{SlopDeskHostDetachInsert, slopdesk_host_detach_insert, slopdesk_host_detach_order};

    /// The insert door over a stamp list the caller still holds.
    fn insert(
        stamps: &[f64],
        occupant: Option<(usize, bool)>,
        cap: Option<usize>,
    ) -> SlopDeskHostDetachInsert {
        let (position, same) = occupant.unwrap_or((0, false));
        // SAFETY: `stamps` is a live Rust slice for the length of the call.
        unsafe {
            slopdesk_host_detach_insert(
                stamps.as_ptr(),
                stamps.len(),
                occupant.is_some(),
                position,
                same,
                cap.is_some(),
                cap.unwrap_or(0),
            )
        }
    }

    /// The order door, lent exactly the slots its answer needs.
    fn order(stamps: &[f64]) -> Vec<u32> {
        let mut room = vec![0_u32; stamps.len()];
        // SAFETY: both spans are live Rust slices for the length of the call.
        let count = unsafe {
            slopdesk_host_detach_order(
                stamps.as_ptr(),
                stamps.len(),
                room.as_mut_ptr(),
                room.len(),
            )
        };
        room.truncate(count.min(stamps.len()));
        room
    }

    #[test]
    fn an_unbounded_store_never_names_a_victim() {
        let verdict = insert(&[10.0, 20.0, 30.0], None, None);
        assert_eq!(verdict, SlopDeskHostDetachInsert::default());
    }

    #[test]
    fn the_same_session_twice_is_idempotent_however_full_the_store_is() {
        let verdict = insert(&[10.0, 20.0], Some((1, true)), Some(1));
        assert!(verdict.idempotent);
        assert!(!verdict.displace);
        assert!(!verdict.has_victim);
    }

    #[test]
    fn a_full_store_names_the_oldest() {
        let verdict = insert(&[30.0, 10.0, 20.0], None, Some(3));
        assert!(verdict.has_victim);
        assert_eq!(verdict.victim, 1);
    }

    #[test]
    fn the_displaced_entry_is_never_also_the_victim() {
        let verdict = insert(&[10.0, 20.0, 30.0], Some((0, false)), Some(2));
        assert!(verdict.displace);
        assert!(verdict.has_victim);
        assert_eq!(verdict.victim, 1);
    }

    #[test]
    fn a_null_stamp_list_is_an_empty_store() {
        // SAFETY: a null pointer with a zero length is exactly what `borrow` accepts as empty.
        let verdict = unsafe {
            slopdesk_host_detach_insert(core::ptr::null(), 0, false, 0, false, true, 0)
        };
        assert!(!verdict.has_victim, "there is nothing to take");
    }

    #[test]
    fn the_listing_is_oldest_first_and_ties_keep_their_order() {
        assert_eq!(order(&[30.0, 10.0, 20.0]), vec![1, 2, 0]);
        assert_eq!(order(&[5.0, 1.0, 5.0, 1.0]), vec![1, 3, 0, 2]);
        assert!(order(&[]).is_empty());
    }

    #[test]
    fn a_short_buffer_is_told_the_count_and_written_nothing() {
        let stamps = [30.0_f64, 10.0, 20.0];
        let mut room = [0_u32; 1];
        // SAFETY: both spans are live Rust slices for the length of the call.
        let needed = unsafe {
            slopdesk_host_detach_order(stamps.as_ptr(), stamps.len(), room.as_mut_ptr(), room.len())
        };
        assert_eq!(needed, 3);
        assert_eq!(room, [0]);
    }
}
