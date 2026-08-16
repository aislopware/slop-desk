//! The host's four bounded accumulators: the LTR map, the dedup window, the idle reaper, the
//! retransmit ring.
//!
//! Every one of them is a HANDLE, and for the same reason: each holds something across many calls
//! that the near side almost never reads. §4b's test is whether the far side reads the part that is
//! big, and here it does not — the LTR map is sixty-four mappings and production reads only "has
//! anything been acked"; the dedup window is a ring of whole datagrams and the answer is one bool;
//! the reaper holds a record per flow and answers a short list of ids; the ring holds MEGABYTES of
//! sent datagrams and answers the handful a client actually lost.
//!
//! ## What that buys, concretely
//! The retransmit ring is the sharp case. Folding it by value would copy the entire send history on
//! every frame — the structure exists precisely because it is large. A handle records into it in
//! place, and a repair copies out only the fragments the negative acknowledgement named, in two
//! steps: the selection reports the shape, one take fills the caller's buffers.
//!
//! ## What is deliberately NOT here
//! The locks. The re-create gate stays Swift because its whole job is to serialise concurrent mint
//! lanes, and a lock is not a rule; the RULE it protects crosses in `host_policy`. Same for the
//! reaper's timer: this side decides which ids are dead, the actor tears them down.

use std::ffi::c_uchar;

use slopdesk_video::idle_reap::{FlowRecord, IdleReapDecider};
use slopdesk_video::ltr::{LtrController, RecoveryAction, RecoveryRequestKind};
use slopdesk_video::recovery_dedupe::RecoveryRequestDeduper;
use slopdesk_video::retransmit_ring::RetransmitRing;

use crate::{borrow, records_of};

/// A refresh request — eligible for the cheap path under the acked-only gate.
pub const SLOPDESK_LTR_REQUEST_REFRESH: u32 = 0;
/// An IDR request — the guaranteed escalation.
pub const SLOPDESK_LTR_REQUEST_IDR: u32 = 1;
/// Issue a forced long-term-reference refresh.
pub const SLOPDESK_LTR_ACTION_REFRESH: u32 = 0;
/// Force a full IDR keyframe.
pub const SLOPDESK_LTR_ACTION_IDR: u32 = 1;

/// The LTR controller's bounds, so neither language writes them down twice.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskLtrCaps {
    /// How many frame-to-token mappings are retained for ack look-up.
    pub frame_token_cap: usize,
    /// How many acknowledged tokens are retained, keeping the most recent.
    pub acknowledged_token_cap: usize,
}

/// One flow's liveness record, as the reaper holds it.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFlowRecord {
    /// Monotonic host time, in seconds, of the most recent inbound datagram of ANY kind.
    pub last_inbound: f64,
    /// Whether this flow has EVER delivered a keepalive. Sticky-true.
    pub saw_keepalive: bool,
}

/// The dedup window's defaults.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskRecoveryDedupeDefaults {
    /// Duplicates of an admitted payload are dropped for this long after the first sighting.
    pub window_seconds: f64,
    /// The most payloads remembered at once.
    pub capacity: usize,
}

/// One run of bytes inside the caller's arena.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskByteSpan {
    /// Where the run starts.
    pub offset: u32,
    /// How long it is.
    pub length: u32,
}

/// The shape of a selected repair, so the caller knows what to lend.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskRetransmitSelection {
    /// How many datagrams answer the request.
    pub datagram_count: usize,
    /// Their bytes, concatenated.
    pub total_len: usize,
}

/// The LTR controller.
#[derive(Debug)]
pub struct SlopDeskLtrController {
    /// The controller proper.
    inner: LtrController,
}

/// The dedup window over recently admitted recovery datagrams.
#[derive(Debug)]
pub struct SlopDeskRecoveryDeduper {
    /// The window proper.
    inner: RecoveryRequestDeduper,
}

/// The idle reaper, keyed on the channel id the mux lanes use.
#[derive(Debug)]
pub struct SlopDeskIdleReaper {
    /// The decider proper.
    inner: IdleReapDecider<u32>,
}

/// The retransmit ring, plus the repair its last selection picked out.
#[derive(Debug)]
pub struct SlopDeskRetransmitRing {
    /// The ring proper.
    inner: RetransmitRing,
    /// The datagrams a selection picked, awaiting their take. One at a time: a second selection
    /// replaces the first, which is the same rule as a caller that ignored its shape.
    selected: Option<Vec<Vec<u8>>>,
}

/// Turns a caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer from this module's matching `new` that has not been freed,
/// with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a, T>(handle: *mut T) -> Option<&'a mut T> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// The LTR controller's bounds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ltr_caps() -> SlopDeskLtrCaps {
    SlopDeskLtrCaps {
        frame_token_cap: LtrController::FRAME_TOKEN_CAP,
        acknowledged_token_cap: LtrController::ACKNOWLEDGED_TOKEN_CAP,
    }
}

/// A controller with nothing recorded and nothing acknowledged.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ltr_new() -> *mut SlopDeskLtrController {
    Box::into_raw(Box::new(SlopDeskLtrController {
        inner: LtrController::new(),
    }))
}

/// Frees a controller. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_ltr_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_free(handle: *mut SlopDeskLtrController) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Records that the encoder emitted a long-term-reference frame carrying `token`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_record(handle: *mut SlopDeskLtrController, frame_id: u32, token: i64) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.record_ltr_frame(frame_id, token);
    }
}

/// Folds a client acknowledgement of `frame_id`, writing the token to stage onto the encoder.
///
/// Answers false — and writes nothing — for an unknown or already-evicted id.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out_token` must be null or writable for one
/// `int64_t` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_ack(
    handle: *mut SlopDeskLtrController,
    frame_id: u32,
    out_token: *mut i64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(token) = state.inner.ack_frame(frame_id) else {
        return false;
    };
    if !out_token.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `i64` for this call.
        unsafe { out_token.write(token) };
    }
    true
}

/// Invalidates all acked-token and frame-map state.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_reset(handle: *mut SlopDeskLtrController) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.reset();
    }
}

/// THE recovery decision for one client request.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_decision(
    handle: *mut SlopDeskLtrController,
    request: u32,
    has_enable_ltr: bool,
) -> u32 {
    let kind = if request == SLOPDESK_LTR_REQUEST_REFRESH {
        RecoveryRequestKind::LtrRefresh
    } else {
        RecoveryRequestKind::Idr
    };
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SLOPDESK_LTR_ACTION_IDR;
    };
    match state.inner.recovery_decision(kind, has_enable_ltr) {
        RecoveryAction::LtrRefresh => SLOPDESK_LTR_ACTION_REFRESH,
        RecoveryAction::Idr => SLOPDESK_LTR_ACTION_IDR,
    }
}

/// The recorded frames, ids in insertion order with their tokens alongside, and the count either
/// way — so a caller that lent too little learns what to lend.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `ids` and `tokens` must each be null, or writable
/// for `cap` entries of their type for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_frames(
    handle: *mut SlopDeskLtrController,
    ids: *mut u32,
    tokens: *mut i64,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let order = state.inner.frame_order();
    let count = order.len();
    if count > cap || ids.is_null() || tokens.is_null() {
        return count;
    }
    for (index, frame_id) in order.iter().enumerate() {
        // SAFETY: `count <= cap` was just checked and both pointers are writable for `cap` entries
        // by the caller's obligation, so every index below `count` is in range.
        unsafe {
            ids.add(index).write(*frame_id);
            tokens
                .add(index)
                .write(state.inner.token_for(*frame_id).unwrap_or(0));
        }
    }
    count
}

/// The acknowledged tokens, oldest to newest, and the count either way.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `out` must be null, or writable for `cap` `int64_t`
/// for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ltr_acked_tokens(
    handle: *mut SlopDeskLtrController,
    out: *mut i64,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let tokens = state.inner.acknowledged_tokens();
    let count = tokens.len();
    if count > cap || out.is_null() {
        return count;
    }
    for (index, token) in tokens.iter().enumerate() {
        // SAFETY: `count <= cap` was just checked and `out` is writable for `cap` entries by the
        // caller's obligation.
        unsafe { out.add(index).write(*token) };
    }
    count
}

/// The dedup window's defaults.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_recovery_dedupe_defaults() -> SlopDeskRecoveryDedupeDefaults {
    SlopDeskRecoveryDedupeDefaults {
        window_seconds: RecoveryRequestDeduper::DEFAULT_WINDOW_SECONDS,
        capacity: RecoveryRequestDeduper::DEFAULT_CAPACITY,
    }
}

/// A dedup window with the given span and ring size.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_recovery_dedupe_new(
    window_seconds: f64,
    capacity: usize,
) -> *mut SlopDeskRecoveryDeduper {
    Box::into_raw(Box::new(SlopDeskRecoveryDeduper {
        inner: RecoveryRequestDeduper::new(window_seconds, capacity),
    }))
}

/// Frees a dedup window. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_recovery_dedupe_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_dedupe_free(handle: *mut SlopDeskRecoveryDeduper) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Whether the caller should PROCESS this datagram: true on a first sighting, false for a
/// duplicate.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `datagram` must be null or point to `len`
/// readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_recovery_dedupe_admit(
    handle: *mut SlopDeskRecoveryDeduper,
    datagram: *const c_uchar,
    len: usize,
    now: f64,
) -> bool {
    // SAFETY: the caller's obligations above are this function's, restated on `held` and `borrow`.
    unsafe {
        let Some(state) = held(handle) else {
            return true;
        };
        state.inner.admit(borrow(datagram, len), now)
    }
}

/// A reaper with no flows and the given idle threshold.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_idle_reaper_new(idle_timeout: f64) -> *mut SlopDeskIdleReaper {
    Box::into_raw(Box::new(SlopDeskIdleReaper {
        inner: IdleReapDecider::new(idle_timeout),
    }))
}

/// Frees a reaper. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_idle_reaper_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idle_reaper_free(handle: *mut SlopDeskIdleReaper) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Stamps an inbound datagram for `id`, latching the keepalive proof sticky.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idle_reaper_note_inbound(
    handle: *mut SlopDeskIdleReaper,
    id: u32,
    now: f64,
    is_keepalive: bool,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.note_inbound(id, now, is_keepalive);
    }
}

/// The ids to reap now, and the count either way.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `out` must be null, or writable for `cap`
/// `uint32_t` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idle_reaper_reap(
    handle: *mut SlopDeskIdleReaper,
    now: f64,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let doomed = state.inner.reap(now);
    let count = doomed.len();
    if count > cap || out.is_null() {
        return count;
    }
    for (index, id) in doomed.iter().enumerate() {
        // SAFETY: `count <= cap` was just checked and `out` is writable for `cap` entries by the
        // caller's obligation.
        unsafe { out.add(index).write(*id) };
    }
    count
}

/// Drops a flow's record, so it is neither re-reported nor leaked. Idempotent.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idle_reaper_forget(handle: *mut SlopDeskIdleReaper, id: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.forget(&id);
    }
}

/// The current record for `id`, if any. Answers false — and writes nothing — when there is none.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for one
/// `SlopDeskFlowRecord` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idle_reaper_record(
    handle: *mut SlopDeskIdleReaper,
    id: u32,
    out: *mut SlopDeskFlowRecord,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(FlowRecord {
        last_inbound,
        saw_keepalive,
    }) = state.inner.record(&id)
    else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one record for this call.
        unsafe {
            out.write(SlopDeskFlowRecord {
                last_inbound,
                saw_keepalive,
            });
        }
    }
    true
}

/// A retransmit ring with the given ceilings, each floored at one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_retransmit_ring_new(
    max_frames: usize,
    max_bytes: usize,
) -> *mut SlopDeskRetransmitRing {
    Box::into_raw(Box::new(SlopDeskRetransmitRing {
        inner: RetransmitRing::new(max_frames, max_bytes),
        selected: None,
    }))
}

/// Frees a ring. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_retransmit_ring_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_retransmit_ring_free(handle: *mut SlopDeskRetransmitRing) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Records a frame's datagrams, each named as a span of the caller's arena.
///
/// A repeat frame id keeps the first copy, because the two are byte-identical and keeping the first
/// avoids double-counting the bytes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `spans` must be null or describe `span_count` live
/// entries, and `arena` null or `arena_len` readable bytes, for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_retransmit_ring_record(
    handle: *mut SlopDeskRetransmitRing,
    frame_id: u32,
    spans: *const SlopDeskByteSpan,
    span_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) {
    // SAFETY: the caller's obligations above are this function's, restated on the helpers.
    unsafe {
        let Some(state) = held(handle) else {
            return;
        };
        let spans = records_of(spans, span_count);
        let pool = borrow(arena, arena_len);
        let datagrams = spans
            .iter()
            .filter_map(|span| run(pool, *span).map(<[u8]>::to_vec))
            .collect();
        state.inner.record(frame_id, datagrams);
    }
}

/// Selects the datagrams answering a negative acknowledgement, reporting their shape.
///
/// The bytes stay here until [`slopdesk_retransmit_ring_take`] copies them out — the ring is the
/// one structure in this module that is large on purpose, and a repair is a handful of it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `indices` must be null or describe
/// `index_count` live entries for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_retransmit_ring_select(
    handle: *mut SlopDeskRetransmitRing,
    frame_id: u32,
    indices: *const u16,
    index_count: usize,
) -> SlopDeskRetransmitSelection {
    // SAFETY: the caller's obligations above are this function's, restated on the helpers.
    unsafe {
        let Some(state) = held(handle) else {
            return SlopDeskRetransmitSelection::default();
        };
        let wanted = records_of(indices, index_count);
        let repair = state.inner.fragments(frame_id, wanted);
        let shape = SlopDeskRetransmitSelection {
            datagram_count: repair.len(),
            total_len: repair.iter().map(Vec::len).sum(),
        };
        state.selected = Some(repair);
        shape
    }
}

/// Copies the selected repair out: one span per datagram, their bytes concatenated in the arena.
///
/// Answers false — and leaves the selection in place — when either buffer is too small, so a caller
/// that lent the shape it was told retries rather than losing the repair.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `spans` must be null or writable for `span_cap`
/// entries, and `arena` null or writable for `arena_cap` bytes, for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_retransmit_ring_take(
    handle: *mut SlopDeskRetransmitRing,
    spans: *mut SlopDeskByteSpan,
    span_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(repair) = state.selected.as_ref() else {
        return false;
    };
    let total: usize = repair.iter().map(Vec::len).sum();
    if repair.len() > span_cap || total > arena_cap || spans.is_null() || arena.is_null() {
        return false;
    }
    let mut offset = 0_usize;
    for (index, datagram) in repair.iter().enumerate() {
        // SAFETY: the two capacities were just checked against the counts, and `offset + len` walks
        // `total` bytes exactly once, so every write below is inside the caller's buffers.
        unsafe {
            spans.add(index).write(SlopDeskByteSpan {
                offset: u32::try_from(offset).unwrap_or(u32::MAX),
                length: u32::try_from(datagram.len()).unwrap_or(u32::MAX),
            });
            std::ptr::copy_nonoverlapping(datagram.as_ptr(), arena.add(offset), datagram.len());
        }
        offset += datagram.len();
    }
    state.selected = None;
    true
}

/// The run a span names, or nothing when it falls outside the arena.
fn run(pool: &[u8], span: SlopDeskByteSpan) -> Option<&[u8]> {
    let start = usize::try_from(span.offset).ok()?;
    let end = start.checked_add(usize::try_from(span.length).ok()?)?;
    pool.get(start..end)
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{
        SLOPDESK_LTR_ACTION_IDR, SLOPDESK_LTR_ACTION_REFRESH, SLOPDESK_LTR_REQUEST_IDR,
        SLOPDESK_LTR_REQUEST_REFRESH, SlopDeskByteSpan, SlopDeskFlowRecord, slopdesk_idle_reaper_forget,
        slopdesk_idle_reaper_free, slopdesk_idle_reaper_new, slopdesk_idle_reaper_note_inbound,
        slopdesk_idle_reaper_reap, slopdesk_idle_reaper_record, slopdesk_ltr_ack, slopdesk_ltr_acked_tokens,
        slopdesk_ltr_caps, slopdesk_ltr_decision, slopdesk_ltr_frames, slopdesk_ltr_free, slopdesk_ltr_new,
        slopdesk_ltr_record, slopdesk_ltr_reset, slopdesk_recovery_dedupe_admit,
        slopdesk_recovery_dedupe_defaults, slopdesk_recovery_dedupe_free, slopdesk_recovery_dedupe_new,
        slopdesk_retransmit_ring_free, slopdesk_retransmit_ring_new, slopdesk_retransmit_ring_record,
        slopdesk_retransmit_ring_select, slopdesk_retransmit_ring_take,
    };

    #[test]
    fn the_gate_opens_only_once_a_token_is_acked_and_shuts_again_on_reset() {
        let handle = slopdesk_ltr_new();
        unsafe {
            assert_eq!(
                slopdesk_ltr_decision(handle, SLOPDESK_LTR_REQUEST_REFRESH, true),
                SLOPDESK_LTR_ACTION_IDR,
                "nothing acked yet"
            );
            slopdesk_ltr_record(handle, 10, 7777);
            let mut token = 0_i64;
            assert!(slopdesk_ltr_ack(handle, 10, &raw mut token));
            assert_eq!(token, 7777);
            assert_eq!(
                slopdesk_ltr_decision(handle, SLOPDESK_LTR_REQUEST_REFRESH, true),
                SLOPDESK_LTR_ACTION_REFRESH
            );
            assert_eq!(
                slopdesk_ltr_decision(handle, SLOPDESK_LTR_REQUEST_IDR, true),
                SLOPDESK_LTR_ACTION_IDR,
                "an IDR request never degrades"
            );
            assert!(
                !slopdesk_ltr_ack(handle, 999, &raw mut token),
                "an unknown id is a no-op"
            );
            slopdesk_ltr_reset(handle);
            assert_eq!(
                slopdesk_ltr_decision(handle, SLOPDESK_LTR_REQUEST_REFRESH, true),
                SLOPDESK_LTR_ACTION_IDR,
                "a rebuilt session re-arms the gate"
            );
            slopdesk_ltr_free(handle);
        }
    }

    #[test]
    fn the_frame_map_is_capped_and_reports_what_it_holds() {
        let caps = slopdesk_ltr_caps();
        let handle = slopdesk_ltr_new();
        unsafe {
            for frame_id in 0..u32::try_from(caps.frame_token_cap).unwrap_or(0) + 5 {
                slopdesk_ltr_record(handle, frame_id, i64::from(frame_id));
            }
            let held = slopdesk_ltr_frames(handle, std::ptr::null_mut(), std::ptr::null_mut(), 0);
            assert_eq!(held, caps.frame_token_cap, "the map is capped");
            let mut ids = vec![0_u32; held];
            let mut tokens = vec![0_i64; held];
            assert_eq!(
                slopdesk_ltr_frames(handle, ids.as_mut_ptr(), tokens.as_mut_ptr(), held),
                held
            );
            assert_eq!(ids.first().copied(), Some(5), "the oldest five were evicted");
            slopdesk_ltr_record(handle, 1000, 42);
            let mut token = 0_i64;
            assert!(slopdesk_ltr_ack(handle, 1000, &raw mut token));
            let mut acked = vec![0_i64; caps.acknowledged_token_cap];
            assert_eq!(
                slopdesk_ltr_acked_tokens(handle, acked.as_mut_ptr(), acked.len()),
                1
            );
            assert_eq!(acked.first().copied(), Some(42));
            slopdesk_ltr_free(handle);
        }
    }

    #[test]
    fn a_redundant_copy_is_admitted_once() {
        let defaults = slopdesk_recovery_dedupe_defaults();
        let handle = slopdesk_recovery_dedupe_new(defaults.window_seconds, defaults.capacity);
        let datagram = [0x11_u8, 0x22, 0x33];
        unsafe {
            assert!(slopdesk_recovery_dedupe_admit(
                handle,
                datagram.as_ptr(),
                datagram.len(),
                100.0
            ));
            assert!(
                !slopdesk_recovery_dedupe_admit(handle, datagram.as_ptr(), datagram.len(), 100.003),
                "the copy inside the window is a duplicate"
            );
            assert!(
                slopdesk_recovery_dedupe_admit(handle, datagram.as_ptr(), datagram.len(), 100.5),
                "a re-request after the window is a first sighting again"
            );
            slopdesk_recovery_dedupe_free(handle);
        }
    }

    #[test]
    fn only_a_flow_that_proved_keepalive_is_reaped() {
        let handle = slopdesk_idle_reaper_new(30.0);
        unsafe {
            slopdesk_idle_reaper_note_inbound(handle, 7, 10.0, false);
            let mut doomed = [0_u32; 4];
            assert_eq!(
                slopdesk_idle_reaper_reap(handle, 10_000.0, doomed.as_mut_ptr(), doomed.len()),
                0,
                "a legacy client degrades to no-reap"
            );
            let mut record = SlopDeskFlowRecord {
                last_inbound: 0.0,
                saw_keepalive: true,
            };
            assert!(slopdesk_idle_reaper_record(handle, 7, &raw mut record));
            assert!(!record.saw_keepalive);
            slopdesk_idle_reaper_note_inbound(handle, 7, 20.0, true);
            assert_eq!(
                slopdesk_idle_reaper_reap(handle, 50.0, doomed.as_mut_ptr(), doomed.len()),
                1
            );
            assert_eq!(doomed.first().copied(), Some(7));
            slopdesk_idle_reaper_forget(handle, 7);
            assert_eq!(
                slopdesk_idle_reaper_reap(handle, 50.0, doomed.as_mut_ptr(), doomed.len()),
                0,
                "a forgotten flow is not re-reported"
            );
            assert!(!slopdesk_idle_reaper_record(handle, 7, &raw mut record));
            slopdesk_idle_reaper_free(handle);
        }
    }

    #[test]
    fn a_repair_answers_in_two_steps_and_only_the_named_fragments() {
        let handle = slopdesk_retransmit_ring_new(8, 1 << 20);
        // Four datagrams whose wire headers name frame 10, fragments 0 through 3.
        let mut arena = Vec::new();
        let mut spans = Vec::new();
        for index in 0..4_u16 {
            let bytes = datagram(10, index, 4);
            spans.push(SlopDeskByteSpan {
                offset: u32::try_from(arena.len()).unwrap_or(0),
                length: u32::try_from(bytes.len()).unwrap_or(0),
            });
            arena.extend_from_slice(&bytes);
        }
        unsafe {
            slopdesk_retransmit_ring_record(
                handle,
                10,
                spans.as_ptr(),
                spans.len(),
                arena.as_ptr(),
                arena.len(),
            );
            let wanted = [1_u16, 3];
            let shape = slopdesk_retransmit_ring_select(handle, 10, wanted.as_ptr(), wanted.len());
            assert_eq!(shape.datagram_count, 2);
            let mut out_spans = vec![SlopDeskByteSpan::default(); shape.datagram_count];
            let mut out_arena = vec![0_u8; shape.total_len];
            assert!(!slopdesk_retransmit_ring_take(
                handle,
                out_spans.as_mut_ptr(),
                0,
                out_arena.as_mut_ptr(),
                out_arena.len()
            ));
            assert!(slopdesk_retransmit_ring_take(
                handle,
                out_spans.as_mut_ptr(),
                out_spans.len(),
                out_arena.as_mut_ptr(),
                out_arena.len()
            ));
            assert_eq!(out_spans.first().map(|span| span.offset), Some(0));
            let miss = slopdesk_retransmit_ring_select(handle, 99, wanted.as_ptr(), wanted.len());
            assert_eq!(
                miss.datagram_count, 0,
                "a frame that aged out answers with nothing"
            );
            slopdesk_retransmit_ring_free(handle);
        }
    }

    /// One datagram carrying the wire header a repair is selected by.
    fn datagram(frame_id: u32, frag_index: u16, frag_count: u16) -> Vec<u8> {
        use slopdesk_video::fragment::{Flags, FrameFragment, FrameFragmentHeader};
        let header = FrameFragmentHeader::new(
            u32::from(frag_index),
            frame_id,
            frag_index,
            frag_count,
            Flags::empty(),
            100,
            0,
        );
        FrameFragment::new(header, vec![0xAB; 100]).encode()
    }
}
