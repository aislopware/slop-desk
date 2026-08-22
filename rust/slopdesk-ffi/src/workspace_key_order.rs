//! The workspace document's canonical order — which cell is emitted first, and which is last.
//!
//! ## Why this is a door
//! `slopdesk_wire::document::state::HostWorkspaceState` is a `BTreeMap`, so the wire's emission
//! order is an invariant of the container and no sort exists there to keep in step with the
//! encoder. The Swift mirror is a `Dictionary`, which has no order at all, so it DERIVED the same
//! order — a hand-written `Comparable` over `(kind, objectID bytes, field)` — and the two were one
//! decision written twice. That pair is the shape `docs/55` §8 catalogues, and it is worse than
//! the usual one in a specific way: two orders never disagree loudly. They RE-EMIT. A snapshot's
//! bytes stop being deterministic, a diff churns on iteration order, and every frame of it looks
//! exactly like a real change to everything downstream.
//!
//! ## Why a PERMUTATION and not the sorted keys
//! The caller already holds the keys; it is asking where they GO. Answering with the keys
//! themselves would copy eighteen bytes per cell back across the boundary to say what four bits of
//! index already say, and a snapshot is hundreds of cells. So `out[i]` is the index, into the array
//! handed in, of the key that places `i`-th — the same shape `slopdesk_ws_rail_plan` answers in,
//! for the same reason.
//!
//! ## What it replaced
//! Not a crossing count. The Swift comparator materialised a fresh sixteen-byte `[UInt8]` for EACH
//! side of every comparison, so one `sortedEntries` on a 24-pane document ran ~8,600 heap
//! allocations. Measured with `swiftc -O` against the shipped staticlib, two runs agreeing inside
//! 4%, at 480 cells (24 panes): the sort alone **1,018 µs → 23 µs**, and the caller's
//! `sortedEntries` end to end **1,075 µs → 77 µs**. At 64 panes, 2,334 µs → 219 µs. The crossing
//! is one; what it deleted is the allocation — and the door is also the only reason the order
//! stopped being two rules.

use core::ffi::c_uchar;

use slopdesk_wire::document::state::{WorkspaceKey, canonical_order};

use crate::workspace::borrow_array;

/// One addressable cell's key, as the caller's flat record.
///
/// Field order is [`crate::workspace::CEntry`]'s minus the value span, so a caller that already
/// builds entries builds these the same way. Every member is byte-aligned, so the struct is
/// eighteen bytes with no padding for the hand-written header to transcribe.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CDocKey {
    /// The object kind's raw tag byte.
    pub kind: c_uchar,
    /// The field selector within the object.
    pub field: c_uchar,
    /// The object's identity, in its own byte order.
    pub object: [c_uchar; 16],
}

/// Where each key places in the document's canonical order.
///
/// Returns how many places there ARE, which is always `count`: every key handed in comes back
/// exactly once, so a caller rebuilds its own array from the answer without checking for a hole. A
/// `cap` short of that leaves `out` untouched and reports the same number, which is §4's retry at a
/// size the caller can always derive rather than guess.
///
/// # Safety
/// `keys` must be null or point to `count` live [`CDocKey`]s; `out` null or writable for `cap`
/// `uint32_t`s. Both live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_key_order(
    keys: *const CDocKey,
    count: usize,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow_array` states its own.
    let held: Vec<WorkspaceKey> = unsafe { borrow_array(keys, count) }
        .iter()
        .map(|key| WorkspaceKey::new(key.kind, key.object, key.field))
        .collect();
    let order = canonical_order(&held);
    if out.is_null() || cap < order.len() {
        return order.len();
    }
    for (index, place) in order.iter().enumerate() {
        // SAFETY: `index` is below `order.len()`, which is at most `cap`, and `out` is writable for
        // `cap` `u32`s by the caller's obligation.
        unsafe { out.add(index).write(*place) };
    }
    order.len()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{CDocKey, slopdesk_ws_key_order};

    fn key(kind: u8, object: u8, field: u8) -> CDocKey {
        CDocKey {
            kind,
            field,
            object: [object; 16],
        }
    }

    fn order(keys: &[CDocKey]) -> Vec<u32> {
        let mut out = vec![u32::MAX; keys.len()];
        // SAFETY: both arrays are live Rust allocations for the duration of the call.
        let written =
            unsafe { slopdesk_ws_key_order(keys.as_ptr(), keys.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(written, keys.len());
        out
    }

    #[test]
    fn the_order_is_kind_then_object_bytes_then_field() {
        let keys = [
            key(3, 0xA1, 8),
            key(3, 0xA1, 3),
            key(0, 0x00, 2),
            key(2, 0xB2, 0),
            key(3, 0xA0, 99),
        ];
        assert_eq!(order(&keys), vec![2, 3, 4, 1, 0]);
    }

    /// The caller can always derive the size, so the retry exists to be CORRECT rather than to be
    /// travelled — and the half that matters is that a short buffer is left alone. A partially
    /// permuted document would emit some cells twice and others never.
    #[test]
    fn a_short_buffer_is_untouched_and_still_reports_its_size() {
        let keys = [key(1, 0x11, 0), key(0, 0x00, 0)];
        let mut out = [7_u32; 2];
        // SAFETY: both arrays are live for the call; `cap` is deliberately one short.
        let needed = unsafe { slopdesk_ws_key_order(keys.as_ptr(), keys.len(), out.as_mut_ptr(), 1) };
        assert_eq!(needed, 2);
        assert_eq!(out, [7, 7], "nothing was written");
    }

    /// A null pair is inert at both ends: no keys is no order, and asking for the size is what a
    /// caller does before it allocates.
    #[test]
    fn a_null_or_empty_call_answers_nothing_rather_than_trapping() {
        // SAFETY: null is explicitly permitted at both ends of this entry point.
        let empty = unsafe { slopdesk_ws_key_order(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(empty, 0);
        let keys = [key(4, 0x0F, 1)];
        // SAFETY: `keys` is live; the output is the null-with-zero-cap sizing call.
        let sizing = unsafe { slopdesk_ws_key_order(keys.as_ptr(), keys.len(), core::ptr::null_mut(), 0) };
        assert_eq!(sizing, 1);
    }
}
