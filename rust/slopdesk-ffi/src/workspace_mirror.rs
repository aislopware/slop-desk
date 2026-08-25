//! One client's REPLICA of the workspace document — host truth, the control-push overlay and the
//! optimistic patches, as one handle.
//!
//! `slopdesk_wire::document::mirror` owns the state machine. This is the door.
//!
//! ## Why this handle is exclusive
//! The replica has two writers — the workspace channel folds host frames, the store's per-pane
//! control sinks write the overlay — and they must write the SAME one, because the erasure rule
//! (host truth deletes the overlay entry for any key it supplies) is what keeps the two layers
//! disjoint. Both live on the near side's main actor, so like [`crate::channel_run`] this handle is
//! reached from exactly one thread and hands out `&mut`: the actor IS the lock.
//!
//! ## What did NOT cross
//! The presence ROSTER, which is not a layer of the replica — it is never diffed, never versioned,
//! and its lifetime is the connection rather than the document. The near side decodes it and holds
//! it beside the handle, and asks its joins through `slopdesk_ws_mirror_viewers`/`_holders`. The
//! two frame kinds that carry it and an intent's verdict are likewise routed on the near side; a
//! kind this door does not know answers DROPPED, which is the forward-tolerance rule stated once.
//!
//! ## The byte answers
//! Every door that hands back bytes follows `docs/55` §4: write nothing when the answer does not
//! fit, report what was needed, and let the caller retry at that size. [`ABSENT`] is the one
//! addition, and it is load-bearing — a cell holding a ZERO-LENGTH value is RETIRED, which this
//! wire gives a meaning distinct from missing all the way to the UI, so "0 bytes" cannot also mean
//! "no such cell".

use core::ffi::c_uchar;

use slopdesk_wire::document::mirror::{ApplyOutcome, PENDING_TIMEOUT, WorkspaceMirror};
use slopdesk_wire::document::state::WorkspaceKey;

use crate::{borrow, deliver};

/// One client's replica, as an opaque handle.
///
/// `Copy` deliberately absent: the handle OWNS a boxed replica, and a type that copied would give
/// the channel and the control sinks one layer each — which is the disagreement the document exists
/// to end.
#[derive(Debug)]
pub struct SlopDeskWorkspaceMirror {
    /// The state the main actor serializes.
    inner: WorkspaceMirror,
}

/// Host truth moved; the state to ACK rides in the out-parameter.
pub const APPLY_APPLIED: u8 = 0;

/// A frame already superseded. Not an error — duplicates and reorders are no-ops by construction.
pub const APPLY_IGNORED: u8 = 1;

/// Wrong epoch, or a base this replica is not at. The client re-sends `subscribe`.
pub const APPLY_NEEDS_RESUBSCRIBE: u8 = 2;

/// Undecodable, or a kind this door does not fold. Never fatal to the channel.
pub const APPLY_DROPPED: u8 = 3;

/// The host declared a new document. Host truth is empty and a snapshot follows.
pub const APPLY_RESET: u8 = 4;

/// What a byte door answers for a cell that is not there at all, told apart from the `0` a RETIRED
/// cell answers.
pub const ABSENT: usize = usize::MAX;

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_ws_mirror_new`] that has not been freed,
/// and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskWorkspaceMirror) -> Option<&'a mut SlopDeskWorkspaceMirror> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// A key from the caller's eighteen bytes: `[kind][16B objectID][field]`.
///
/// A short buffer reads as the all-zero ROOT key rather than trapping. It cannot name a real cell,
/// so every read answers absent and every write lands somewhere nothing looks — which is the right
/// shape for arithmetic that arrived from another process.
fn key_of(bytes: &[c_uchar]) -> WorkspaceKey {
    let Some((kind, rest)) = bytes.split_first() else {
        return WorkspaceKey::new(0, [0; 16], 0);
    };
    let Some((object, field)) = rest
        .split_first_chunk::<16>()
        .and_then(|(object, tail)| tail.first().map(|field| (*object, *field)))
    else {
        return WorkspaceKey::new(0, [0; 16], 0);
    };
    WorkspaceKey::new(*kind, object, field)
}

/// Sixteen bytes as an identity, short-reading as the all-zero id.
fn uuid_of(bytes: &[c_uchar]) -> [u8; 16] {
    bytes.first_chunk::<16>().copied().unwrap_or([0; 16])
}

/// A replica that has never been spoken to.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_mirror_new() -> *mut SlopDeskWorkspaceMirror {
    Box::into_raw(Box::new(SlopDeskWorkspaceMirror {
        inner: WorkspaceMirror::new(),
    }))
}

/// Frees a replica. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_ws_mirror_new`], freed exactly once, with no
/// other reference to it live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "reclaiming a boxed replica the caller has been holding IS the obligation here"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_free(handle: *mut SlopDeskWorkspaceMirror) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a once-only free of a `new` allocation.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one type-37 document frame in, answering what it DID.
///
/// `state_num` receives the state to ACK on [`APPLY_APPLIED`] and `0` on every other verdict, which
/// is the "I know nothing" sentinel and therefore never a state anything acks. A dead handle
/// answers [`APPLY_DROPPED`] — the same reading as a frame this build cannot interpret.
///
/// # Safety
/// `epoch` must be null or point to sixteen live bytes; `payload` null or to `payload_len` live
/// bytes; `state_num` null or writable for one `int64_t`. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_apply(
    handle: *mut SlopDeskWorkspaceMirror,
    kind: c_uchar,
    epoch: *const c_uchar,
    base_state_num: i64,
    new_state_num: i64,
    payload: *const c_uchar,
    payload_len: usize,
    state_num: *mut i64,
) -> u8 {
    // SAFETY: the caller's obligations, restated above.
    let (identity, bytes) = unsafe { (borrow(epoch, 16), borrow(payload, payload_len)) };
    // SAFETY: the caller's obligation on the handle, restated above.
    let outcome = unsafe { held(handle) }.map_or(ApplyOutcome::Dropped, |mirror| {
        mirror
            .inner
            .apply(kind, uuid_of(identity), base_state_num, new_state_num, bytes)
    });
    if !state_num.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `int64_t`.
        unsafe { *state_num = outcome.state_num() };
    }
    outcome.tag()
}

/// Forgets everything, host truth included — what the workspace channel does when it stops.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_forget(handle: *mut SlopDeskWorkspaceMirror) {
    // SAFETY: the caller's obligation, restated above.
    if let Some(mirror) = unsafe { held(handle) } {
        mirror.inner.forget();
    }
}

/// Records a value pushed on a pane's own control channel, answering whether the overlay MOVED.
///
/// `has_value` false retires the entry — a push that gives a fact up, which stays distinct from a
/// push of zero bytes. A dead handle answers `false`: nothing moved, so nothing repaints.
///
/// # Safety
/// `key` must be null or point to eighteen live bytes; `value` null or to `value_len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_write_fast_path(
    handle: *mut SlopDeskWorkspaceMirror,
    key: *const c_uchar,
    value: *const c_uchar,
    value_len: usize,
    has_value: bool,
) -> bool {
    // SAFETY: the caller's obligations, restated above.
    let (cell, bytes) = unsafe { (borrow(key, WorkspaceKey::ENCODED_SIZE), borrow(value, value_len)) };
    // SAFETY: the caller's obligation on the handle, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| {
        mirror
            .inner
            .write_fast_path(key_of(cell), has_value.then_some(bytes))
    })
}

/// Whether the OVERLAY holds one cell — not the full chain.
///
/// # Safety
/// `key` must be null or point to eighteen live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_fast_path_holds(
    handle: *mut SlopDeskWorkspaceMirror,
    key: *const c_uchar,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let cell = unsafe { borrow(key, WorkspaceKey::ENCODED_SIZE) };
    // SAFETY: the caller's obligation on the handle, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| mirror.inner.fast_path_holds(key_of(cell)))
}

/// Drops every overlay entry for one pane — what a client does when that pane's channel closes.
///
/// # Safety
/// `pane` must be null or point to sixteen live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_clear_fast_path(
    handle: *mut SlopDeskWorkspaceMirror,
    pane: *const c_uchar,
) {
    // SAFETY: the caller's obligation, restated above.
    let id = unsafe { borrow(pane, 16) };
    // SAFETY: the caller's obligation on the handle, restated above.
    if let Some(mirror) = unsafe { held(handle) } {
        mirror.inner.clear_fast_path(uuid_of(id));
    }
}

/// Stages one intent's optimistic effect, answering whether anything was staged.
///
/// `false` means the caller does NOT send it: this client can already see the host will refuse — a
/// round trip and a rollback for nothing. An intent that changes no cell still stages, and still
/// goes out; see [`slopdesk_wire::document::mirror::WorkspaceMirror::stage_intent`]. `minted` is
/// the identity pool the ops that create objects draw from; a client PROPOSES object ids, so they
/// are the near side's and arrive with the request.
///
/// # Safety
/// `intent_id` must be null or point to sixteen live bytes; `args` null or to `args_len` live
/// bytes; `minted` null or to `minted_count * 16` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_stage_intent(
    handle: *mut SlopDeskWorkspaceMirror,
    intent_id: *const c_uchar,
    op: c_uchar,
    args: *const c_uchar,
    args_len: usize,
    minted: *const c_uchar,
    minted_count: usize,
    issued_at: f64,
) -> bool {
    // SAFETY: the caller's obligations, restated above.
    let (id, payload, pool) = unsafe {
        (
            borrow(intent_id, 16),
            borrow(args, args_len),
            borrow(minted, minted_count.saturating_mul(16)),
        )
    };
    let ids: Vec<[u8; 16]> = pool.as_chunks::<16>().0.to_vec();
    // SAFETY: the caller's obligation on the handle, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| {
        mirror
            .inner
            .stage_intent(uuid_of(id), op, payload, &ids, issued_at)
    })
}

/// Folds the host's verdict on one intent, answering whether a patch was found and moved.
///
/// `applied` false snaps the layout back immediately; true only ARMS the patch, which retires at
/// the next document frame.
///
/// # Safety
/// `intent_id` must be null or point to sixteen live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_note_intent_result(
    handle: *mut SlopDeskWorkspaceMirror,
    intent_id: *const c_uchar,
    applied: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let id = unsafe { borrow(intent_id, 16) };
    // SAFETY: the caller's obligation on the handle, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| mirror.inner.note_intent_result(uuid_of(id), applied))
}

/// Drops patches the host never answered, answering whether anything went. The caller owns the
/// clock.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_expire_pending(
    handle: *mut SlopDeskWorkspaceMirror,
    now: f64,
    timeout: f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| mirror.inner.expire_pending(now, timeout))
}

/// How long an unanswered patch may stand, in seconds. Exported so the near side never spells it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_mirror_pending_timeout() -> f64 {
    PENDING_TIMEOUT
}

/// Drops one staged patch outright, answering whether it was there.
///
/// # Safety
/// `intent_id` must be null or point to sixteen live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_drop_pending(
    handle: *mut SlopDeskWorkspaceMirror,
    intent_id: *const c_uchar,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let id = unsafe { borrow(intent_id, 16) };
    // SAFETY: the caller's obligation on the handle, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| mirror.inner.drop_pending(uuid_of(id)))
}

/// How many optimistic patches are standing. A dead handle holds none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_pending_count(handle: *mut SlopDeskWorkspaceMirror) -> usize {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |mirror| mirror.inner.pending_count())
}

/// Whether one intent's patch is still standing.
///
/// # Safety
/// `intent_id` must be null or point to sixteen live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_is_pending(
    handle: *mut SlopDeskWorkspaceMirror,
    intent_id: *const c_uchar,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let id = unsafe { borrow(intent_id, 16) };
    // SAFETY: the caller's obligation on the handle, restated above.
    unsafe { held(handle) }.is_some_and(|mirror| mirror.inner.is_pending(uuid_of(id)))
}

/// One cell's bytes, read through the full precedence chain `pending` → host truth → overlay.
///
/// Answers [`ABSENT`] for a cell no layer holds, `0` for one holding a RETIRED (zero-length) value,
/// and otherwise the byte count under §4's retry convention.
///
/// # Safety
/// `key` must be null or point to eighteen live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_value(
    handle: *mut SlopDeskWorkspaceMirror,
    key: *const c_uchar,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let cell = unsafe { borrow(key, WorkspaceKey::ENCODED_SIZE) };
    // SAFETY: the caller's obligation on the handle, restated above.
    let Some(mirror) = (unsafe { held(handle) }) else {
        return ABSENT;
    };
    let Some(value) = mirror.inner.value(key_of(cell)) else {
        return ABSENT;
    };
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(value, out, cap) }
}

/// The whole replica as an encoded SNAPSHOT — host truth with the overlay and this client's
/// unanswered intents already on it.
///
/// The document crosses in the wire's own shape rather than as a marshalled cell array, because
/// that encoding already exists, is golden-pinned, and the near side already holds its decoder.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_resolved(
    handle: *mut SlopDeskWorkspaceMirror,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the handle, restated above.
    let Some(mirror) = (unsafe { held(handle) }) else {
        return 0;
    };
    let answer = slopdesk_wire::document::codec::encode_snapshot(&mirror.inner.resolved());
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(&answer, out, cap) }
}

/// HOST TRUTH alone, as an encoded snapshot — the overlay and the pending patches left out.
///
/// The one caller is the in-process document, which ADOPTS what a store seeded and must not adopt
/// the client's own overlay along with it: the fast path is a lane a real host's document never
/// holds, and a loopback that took it would publish this client's guesses back as truth.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_host_truth(
    handle: *mut SlopDeskWorkspaceMirror,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the handle, restated above.
    let Some(mirror) = (unsafe { held(handle) }) else {
        return 0;
    };
    let answer = slopdesk_wire::document::codec::encode_snapshot(mirror.inner.entries());
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(&answer, out, cap) }
}

/// The version of host truth as HELD, whatever the epoch says.
///
/// Distinct from [`slopdesk_ws_mirror_known_state_num`], which answers what `subscribe` should
/// declare and reads `0` for a replica holding no document at all.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_state_num(handle: *mut SlopDeskWorkspaceMirror) -> i64 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |mirror| mirror.inner.state_num())
}

/// Every pane the DOCUMENT knows about, sixteen bytes each, in canonical order.
///
/// Membership is the liveness field: a pane with only overlay values is not a document pane.
///
/// # Safety
/// `out` must be null or writable for `cap * 16` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_pane_ids(
    handle: *mut SlopDeskWorkspaceMirror,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the handle, restated above.
    let ids = unsafe { held(handle) }
        .map(|mirror| mirror.inner.pane_ids())
        .unwrap_or_default();
    // SAFETY: null or, by the caller's obligation, writable for `cap * 16` bytes.
    unsafe { deliver_ids(&ids, out, cap) }
}

/// Every pane with an OVERLAY entry. Distinct from [`slopdesk_ws_mirror_pane_ids`], which
/// enumerates the document.
///
/// # Safety
/// `out` must be null or writable for `cap * 16` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_fast_path_pane_ids(
    handle: *mut SlopDeskWorkspaceMirror,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the handle, restated above.
    let ids = unsafe { held(handle) }
        .map(|mirror| mirror.inner.fast_path_pane_ids())
        .unwrap_or_default();
    // SAFETY: null or, by the caller's obligation, writable for `cap * 16` bytes.
    unsafe { deliver_ids(&ids, out, cap) }
}

/// Writes an identity list under §4's retry convention.
///
/// # Safety
/// `out` must be null or writable for `cap` sixteen-byte identities, live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing a caller's identity array through a raw pointer"
)]
unsafe fn deliver_ids(ids: &[[u8; 16]], out: *mut c_uchar, cap: usize) -> usize {
    if ids.len() > cap || out.is_null() {
        return ids.len();
    }
    for (slot, id) in ids.iter().enumerate() {
        // SAFETY: `slot < ids.len() <= cap`, so `slot * 16 + 16 <= cap * 16`, which the caller
        // promised is writable.
        unsafe { std::ptr::copy_nonoverlapping(id.as_ptr(), out.add(slot.saturating_mul(16)), 16) };
    }
    ids.len()
}

/// The document identity actually held, `false` when none is.
///
/// Distinct from what `subscribe` declares: this answers absence, which the subscribe pair cannot —
/// it reports a fresh identity for "snapshot me".
///
/// # Safety
/// `out` must be null or writable for sixteen bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_epoch(
    handle: *mut SlopDeskWorkspaceMirror,
    out: *mut c_uchar,
) -> bool {
    // SAFETY: the caller's obligation on the handle, restated above.
    let Some(epoch) = (unsafe { held(handle) }).and_then(|mirror| mirror.inner.epoch()) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for sixteen bytes.
        unsafe { std::ptr::copy_nonoverlapping(epoch.as_ptr(), out, 16) };
    }
    true
}

/// What `subscribe` should declare — the held state, or `0` when no document is held.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_known_state_num(handle: *mut SlopDeskWorkspaceMirror) -> i64 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |mirror| mirror.inner.known_state_num())
}

/// How many document frames have been folded. Back to zero after a forget, so a caller can tell a
/// fold from every other reason its observers fire.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mirror_frames_applied(handle: *mut SlopDeskWorkspaceMirror) -> u64 {
    // SAFETY: the caller's obligation, restated above.
    unsafe { held(handle) }.map_or(0, |mirror| mirror.inner.frames_applied())
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_wire::document::codec;
    use slopdesk_wire::document::fields::pane as pane_field;
    use slopdesk_wire::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};

    use super::{
        ABSENT, APPLY_APPLIED, APPLY_DROPPED, SlopDeskWorkspaceMirror, slopdesk_ws_mirror_apply,
        slopdesk_ws_mirror_clear_fast_path, slopdesk_ws_mirror_epoch, slopdesk_ws_mirror_fast_path_pane_ids,
        slopdesk_ws_mirror_forget, slopdesk_ws_mirror_frames_applied, slopdesk_ws_mirror_free,
        slopdesk_ws_mirror_known_state_num, slopdesk_ws_mirror_new, slopdesk_ws_mirror_pane_ids,
        slopdesk_ws_mirror_pending_count, slopdesk_ws_mirror_value, slopdesk_ws_mirror_write_fast_path,
    };

    const EPOCH: [u8; 16] = [0xA1; 16];

    fn key_bytes(pane: u8, field: u8) -> [u8; 18] {
        let mut out = [0_u8; 18];
        out[0] = WorkspaceObjectKind::Pane.as_byte();
        out[1..17].copy_from_slice(&[pane; 16]);
        out[17] = field;
        out
    }

    fn one_pane_snapshot(pane: u8) -> Vec<u8> {
        let mut state = HostWorkspaceState::new();
        state.set(
            WorkspaceKey::of(WorkspaceObjectKind::Pane, [pane; 16], pane_field::LIVENESS),
            vec![1],
        );
        codec::encode_snapshot(&state)
    }

    fn opened() -> *mut SlopDeskWorkspaceMirror {
        slopdesk_ws_mirror_new()
    }

    #[test]
    fn a_snapshot_crosses_and_names_the_state_to_ack() {
        let handle = opened();
        let payload = one_pane_snapshot(1);
        let mut state = 0_i64;
        let verdict = unsafe {
            slopdesk_ws_mirror_apply(
                handle,
                0,
                EPOCH.as_ptr(),
                0,
                7,
                payload.as_ptr(),
                payload.len(),
                &raw mut state,
            )
        };
        assert_eq!(verdict, APPLY_APPLIED);
        assert_eq!(state, 7);
        assert_eq!(unsafe { slopdesk_ws_mirror_known_state_num(handle) }, 7);
        assert_eq!(unsafe { slopdesk_ws_mirror_frames_applied(handle) }, 1);

        let mut epoch = [0_u8; 16];
        assert!(unsafe { slopdesk_ws_mirror_epoch(handle, epoch.as_mut_ptr()) });
        assert_eq!(epoch, EPOCH);
        unsafe { slopdesk_ws_mirror_free(handle) };
    }

    #[test]
    fn an_absent_cell_and_a_retired_one_answer_differently() {
        let handle = opened();
        let key = key_bytes(1, pane_field::LIVE_TITLE);
        assert_eq!(
            unsafe { slopdesk_ws_mirror_value(handle, key.as_ptr(), std::ptr::null_mut(), 0) },
            ABSENT,
            "no layer holds it"
        );
        assert!(unsafe {
            slopdesk_ws_mirror_write_fast_path(handle, key.as_ptr(), std::ptr::null(), 0, true)
        });
        assert_eq!(
            unsafe { slopdesk_ws_mirror_value(handle, key.as_ptr(), std::ptr::null_mut(), 0) },
            0,
            "a RETIRED cell is zero bytes, which is not the same as no cell"
        );
        unsafe { slopdesk_ws_mirror_free(handle) };
    }

    #[test]
    fn a_value_answers_what_was_needed_and_writes_nothing_when_it_does_not_fit() {
        let handle = opened();
        let key = key_bytes(1, pane_field::LIVE_TITLE);
        unsafe { slopdesk_ws_mirror_write_fast_path(handle, key.as_ptr(), b"nvim".as_ptr(), 4, true) };
        let mut small = [0_u8; 2];
        assert_eq!(
            unsafe { slopdesk_ws_mirror_value(handle, key.as_ptr(), small.as_mut_ptr(), small.len()) },
            4
        );
        assert_eq!(
            small,
            [0, 0],
            "nothing was written at a cap that could not hold it"
        );
        let mut big = [0_u8; 8];
        assert_eq!(
            unsafe { slopdesk_ws_mirror_value(handle, key.as_ptr(), big.as_mut_ptr(), big.len()) },
            4
        );
        assert_eq!(&big[..4], b"nvim");
        unsafe { slopdesk_ws_mirror_free(handle) };
    }

    #[test]
    fn the_two_pane_enumerations_answer_different_questions() {
        let handle = opened();
        let payload = one_pane_snapshot(1);
        unsafe {
            slopdesk_ws_mirror_apply(
                handle,
                0,
                EPOCH.as_ptr(),
                0,
                1,
                payload.as_ptr(),
                payload.len(),
                std::ptr::null_mut(),
            )
        };
        let overlay = key_bytes(2, pane_field::LIVE_TITLE);
        unsafe { slopdesk_ws_mirror_write_fast_path(handle, overlay.as_ptr(), b"ghost".as_ptr(), 5, true) };

        let mut ids = [0_u8; 64];
        assert_eq!(
            unsafe { slopdesk_ws_mirror_pane_ids(handle, ids.as_mut_ptr(), 4) },
            1
        );
        assert_eq!(ids.first_chunk::<16>(), Some(&[1_u8; 16]), "the DOCUMENT's panes");
        assert_eq!(
            unsafe { slopdesk_ws_mirror_fast_path_pane_ids(handle, ids.as_mut_ptr(), 4) },
            1
        );
        assert_eq!(ids.first_chunk::<16>(), Some(&[2_u8; 16]), "the OVERLAY's");

        unsafe { slopdesk_ws_mirror_clear_fast_path(handle, [2_u8; 16].as_ptr()) };
        assert_eq!(
            unsafe { slopdesk_ws_mirror_fast_path_pane_ids(handle, ids.as_mut_ptr(), 4) },
            0
        );
        unsafe { slopdesk_ws_mirror_free(handle) };
    }

    #[test]
    fn forgetting_takes_host_truth_and_the_overlay_with_it() {
        let handle = opened();
        let payload = one_pane_snapshot(1);
        unsafe {
            slopdesk_ws_mirror_apply(
                handle,
                0,
                EPOCH.as_ptr(),
                0,
                1,
                payload.as_ptr(),
                payload.len(),
                std::ptr::null_mut(),
            )
        };
        unsafe { slopdesk_ws_mirror_forget(handle) };
        assert_eq!(unsafe { slopdesk_ws_mirror_known_state_num(handle) }, 0);
        assert!(!unsafe { slopdesk_ws_mirror_epoch(handle, std::ptr::null_mut()) });
        unsafe { slopdesk_ws_mirror_free(handle) };
    }

    #[test]
    fn a_dead_handle_answers_the_reading_that_touches_nothing() {
        let dead = std::ptr::null_mut();
        let mut state = 9_i64;
        assert_eq!(
            unsafe {
                slopdesk_ws_mirror_apply(dead, 0, EPOCH.as_ptr(), 0, 1, std::ptr::null(), 0, &raw mut state)
            },
            APPLY_DROPPED
        );
        assert_eq!(state, 0);
        assert_eq!(unsafe { slopdesk_ws_mirror_known_state_num(dead) }, 0);
        assert_eq!(unsafe { slopdesk_ws_mirror_pending_count(dead) }, 0);
        assert!(!unsafe { slopdesk_ws_mirror_epoch(dead, std::ptr::null_mut()) });
        assert_eq!(
            unsafe { slopdesk_ws_mirror_value(dead, key_bytes(1, 1).as_ptr(), std::ptr::null_mut(), 0) },
            ABSENT
        );
        // Freeing null is the documented no-op.
        unsafe { slopdesk_ws_mirror_free(dead) };
    }
}
