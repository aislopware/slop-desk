//! The host mux's three deciders: which lane a datagram belongs to, which flow it replies on, and
//! what a lane that has none is owed.
//!
//! `rust/slopdesk-video`'s `mux_routing` and `mux_flow` own all three. This is the door.
//!
//! ## Why the two tables are handles and the byes are not
//! §4b's test is whether the far side reads the part that is big. The router holds up to five
//! hundred retired ids and answers one verdict per datagram; the flow table holds a record per
//! accepted flow, per reply stamp and per never-admitted lane, and answers a short list of ids at
//! reap time. Neither is ever read whole, so both are handles. `warrants_bye` is a pure question
//! about one payload and crosses as a call.
//!
//! ## The flow id is the caller's, not ours
//! A flow on the near side is an `NWConnection` — a reference the crate cannot hold and does not
//! want to. It crosses as an opaque `uint64_t` the caller assigns, so every decision here is made
//! in terms of ids, exactly as the crate already states. Which object an id names stays on the near
//! side, where the object lives; WHICH id survives a reap is this side's answer.
//!
//! ## The reap asks its caller back
//! Rule one of the reap needs to know whether a lane got admitted inside its window, and that
//! answer lives in the router — which the transport holds separately, and which a test replaces
//! with a fake. So the predicate crosses as a C callback plus its context rather than as a
//! snapshot: a snapshot would have to be taken before the sweep it feeds, which is the one ordering
//! the rule forbids.

use std::ffi::c_void;

use slopdesk_video::mux_flow::{MuxFlowTable, UnboundByeRateLimiter, payload_is_keepalive, warrants_bye};
use slopdesk_video::mux_routing::{
    BootstrapAction, DispatchDecision, MuxDecision, VideoMuxRouter, bootstrap_action, dispatch_decision,
};
use slopdesk_video::recovery_routing::VideoChannel;

use crate::borrow;

/// Route the datagram to the session bound to this lane.
pub const SLOPDESK_MUX_ROUTE: u32 = 0;
/// The lane was never admitted — an unknown or stray id.
pub const SLOPDESK_MUX_REJECT_UNADMITTED: u32 = 1;
/// The lane was retired by a reconnect or teardown; these are a previous generation's bytes.
pub const SLOPDESK_MUX_DROP_RETIRED: u32 = 2;
/// The lane is mid-teardown, so every datagram drops until the drain ends.
pub const SLOPDESK_MUX_DROP_DRAINING: u32 = 3;
/// An empty datagram. Never fatal, just nothing to route.
pub const SLOPDESK_MUX_DROP_EMPTY: u32 = 4;

/// Remember the lane's reply flow and deliver the datagram, so the registry can mint or answer.
pub const SLOPDESK_MUX_BOOTSTRAP_DELIVER: u32 = 0;
/// Drop it without touching any flow bookkeeping.
pub const SLOPDESK_MUX_DROP_NO_STAMP: u32 = 1;

/// A live lane exists — deliver the datagram to its session sink.
pub const SLOPDESK_MUX_DISPATCH_DELIVER: u32 = 0;
/// A never-seen lane carrying a hello — mint a session for it, then deliver.
pub const SLOPDESK_MUX_DISPATCH_MINT: u32 = 1;
/// An unknown lane whose first datagram is not a hello. It cannot be bound, so it drops.
pub const SLOPDESK_MUX_DISPATCH_DROP_UNBOUND: u32 = 2;

/// The per-datagram lane router.
#[derive(Debug)]
pub struct SlopDeskMuxRouter {
    /// The router proper.
    inner: VideoMuxRouter,
}

/// The flow table: which flow each lane replies on, and which flows the reaper may close.
#[derive(Debug)]
pub struct SlopDeskMuxFlowTable {
    /// The table proper.
    inner: MuxFlowTable,
}

/// The unbound-lane bye rate limiter.
#[derive(Debug)]
pub struct SlopDeskUnboundByeLimiter {
    /// The limiter proper.
    inner: UnboundByeRateLimiter,
}

/// Whether a lane is currently admitted, asked of whatever holds that answer.
///
/// The context pointer is passed straight back, untouched.
pub type SlopDeskLaneAdmittedFn = Option<unsafe extern "C" fn(channel_id: u32, context: *mut c_void) -> bool>;

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

/// The decision code a verdict crosses as.
const fn decision_code(decision: MuxDecision) -> u32 {
    match decision {
        MuxDecision::Route { .. } => SLOPDESK_MUX_ROUTE,
        MuxDecision::RejectUnadmitted => SLOPDESK_MUX_REJECT_UNADMITTED,
        MuxDecision::DropRetired => SLOPDESK_MUX_DROP_RETIRED,
        MuxDecision::DropDraining => SLOPDESK_MUX_DROP_DRAINING,
        MuxDecision::DropEmpty => SLOPDESK_MUX_DROP_EMPTY,
    }
}

/// The verdict a decision code names. An unknown code reads as the empty-datagram drop, which
/// bootstraps nothing — the safe reading of a code this side never emitted.
const fn decision_of(code: u32, channel_id: u32) -> MuxDecision {
    match code {
        SLOPDESK_MUX_ROUTE => MuxDecision::Route { channel_id },
        SLOPDESK_MUX_REJECT_UNADMITTED => MuxDecision::RejectUnadmitted,
        SLOPDESK_MUX_DROP_RETIRED => MuxDecision::DropRetired,
        SLOPDESK_MUX_DROP_DRAINING => MuxDecision::DropDraining,
        _ => MuxDecision::DropEmpty,
    }
}

/// The channel a wire tag names. An unknown tag reads as `Audio`, which is host→client only and so
/// warrants nothing and bootstraps nothing.
const fn channel_of(raw: u8) -> VideoChannel {
    match VideoChannel::from_raw_value(raw) {
        Some(channel) => channel,
        None => VideoChannel::Audio,
    }
}

/// A router with no lanes at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_mux_router_new() -> *mut SlopDeskMuxRouter {
    Box::into_raw(Box::new(SlopDeskMuxRouter {
        inner: VideoMuxRouter::new(),
    }))
}

/// Frees a router. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_mux_router_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_free(handle: *mut SlopDeskMuxRouter) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Admits a lane, clearing any retired or draining mark.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_admit(handle: *mut SlopDeskMuxRouter, channel_id: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.admit(channel_id);
    }
}

/// Retires a lane, bounding the retired set by the wrap-aware high-water mark.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_retire(handle: *mut SlopDeskMuxRouter, channel_id: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.retire(channel_id);
    }
}

/// Begins a reaper teardown: the lane stops routing and is HELD.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_begin_drain(handle: *mut SlopDeskMuxRouter, channel_id: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.begin_drain(channel_id);
    }
}

/// Finishes a reaper teardown, moving the lane from draining to retired.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_end_drain(handle: *mut SlopDeskMuxRouter, channel_id: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.end_drain(channel_id);
    }
}

/// Whether the lane is currently routable.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_is_admitted(
    handle: *mut SlopDeskMuxRouter,
    channel_id: u32,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_admitted(channel_id))
}

/// Whether the lane is currently draining.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_is_draining(
    handle: *mut SlopDeskMuxRouter,
    channel_id: u32,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_draining(channel_id))
}

/// The verdict for one received datagram, as a decision code.
///
/// The lane it names is the one the caller passed, so only the code crosses back.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_router_route(
    handle: *mut SlopDeskMuxRouter,
    channel_id: u32,
    bytes_count: usize,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SLOPDESK_MUX_DROP_EMPTY;
    };
    decision_code(state.inner.route(channel_id, bytes_count))
}

/// What the bootstrap arm should do with a datagram whose lane is not admitted.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_mux_bootstrap_action(
    decision: u32,
    channel: u8,
    payload_is_hello: bool,
    payload_is_list_request: bool,
) -> u32 {
    match bootstrap_action(
        decision_of(decision, 0),
        channel_of(channel),
        payload_is_hello,
        payload_is_list_request,
    ) {
        BootstrapAction::BootstrapDeliver => SLOPDESK_MUX_BOOTSTRAP_DELIVER,
        BootstrapAction::DropNoStamp => SLOPDESK_MUX_DROP_NO_STAMP,
    }
}

/// What the daemon's session registry should do with one demultiplexed datagram, as a code.
///
/// The lane it concerns is the caller's own — it is pure echo on both sides, exactly as
/// [`slopdesk_mux_router_route`] documents — so no channel id crosses in either direction and the
/// answer is one scalar.
///
/// Whether a lane is live and whether its mint is already in flight are the CALLER's bookkeeping:
/// the sink table registers synchronously inside a session's start, and only the near side can see
/// that. They arrive as two booleans so this stays a decision over what was observed, the shape
/// [`slopdesk_mux_bootstrap_action`] already takes.
///
/// # Safety
/// `payload` must be null, or point to `payload_len` bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_dispatch_decision(
    channel: u8,
    payload: *const u8,
    payload_len: usize,
    lane_is_live: bool,
    mint_in_flight: bool,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    let payload = unsafe { borrow(payload, payload_len) };
    // The lane id is the caller's echo, so this side names it zero and never reads it back.
    match dispatch_decision(0, channel_of(channel), payload, lane_is_live, mint_in_flight) {
        DispatchDecision::Deliver { .. } => SLOPDESK_MUX_DISPATCH_DELIVER,
        DispatchDecision::Mint { .. } => SLOPDESK_MUX_DISPATCH_MINT,
        DispatchDecision::DropUnbound { .. } => SLOPDESK_MUX_DISPATCH_DROP_UNBOUND,
    }
}

/// A flow table that has accepted nothing, with the idle threshold a reap measures against.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_mux_flows_new(idle_timeout: f64) -> *mut SlopDeskMuxFlowTable {
    Box::into_raw(Box::new(SlopDeskMuxFlowTable {
        inner: MuxFlowTable::new(idle_timeout),
    }))
}

/// Frees a flow table. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_mux_flows_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_free(handle: *mut SlopDeskMuxFlowTable) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Tracks a listener-accepted flow, stamping `now` as its first inbound time.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_accept(
    handle: *mut SlopDeskMuxFlowTable,
    flow: u64,
    is_media: bool,
    now: f64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.accept(flow, is_media, now);
    }
}

/// Refreshes a tracked flow's last-inbound time. A no-op for a flow the table does not hold.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_note_inbound(
    handle: *mut SlopDeskMuxFlowTable,
    flow: u64,
    now: f64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.note_inbound(flow, now);
    }
}

/// Stamps the media reply flow for an ADMITTED lane.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_stamp_media_reply(
    handle: *mut SlopDeskMuxFlowTable,
    channel_id: u32,
    flow: u64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.stamp_media_reply(channel_id, flow);
    }
}

/// Stamps the media reply flow for a not-yet-admitted bootstrap, starting its expiry clock.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_stamp_media_bootstrap(
    handle: *mut SlopDeskMuxFlowTable,
    channel_id: u32,
    flow: u64,
    now: f64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.stamp_media_bootstrap(channel_id, flow, now);
    }
}

/// Stamps the cursor reply flow for a lane, tracking an unadmitted stamp's expiry clock.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_stamp_cursor_reply(
    handle: *mut SlopDeskMuxFlowTable,
    channel_id: u32,
    flow: u64,
    now: f64,
    is_admitted: bool,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.stamp_cursor_reply(channel_id, flow, now, is_admitted);
    }
}

/// Drops a lane's reply stamps. The flows themselves stay tracked — they may carry siblings.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_retire_lane(handle: *mut SlopDeskMuxFlowTable, channel_id: u32) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.retire_lane(channel_id);
    }
}

/// Forgets a flow that reached failed or cancelled, and every reply stamp pointing at it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_did_reset(
    handle: *mut SlopDeskMuxFlowTable,
    flow: u64,
    is_media: bool,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.flow_did_reset(flow, is_media);
    }
}

/// Whether this flow is still tracked on either side.
///
/// The caller holds the OBJECT an id names — this side holds only ids — so it asks after a reset
/// whether it may release it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_tracks(handle: *mut SlopDeskMuxFlowTable, flow: u64) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.tracks(flow))
}

/// One reaper tick: sweeps never-admitted stamps, then reaps idle unreferenced flows.
///
/// Writes the reaped flow ids into `out` when they fit and answers how many there were either way,
/// so a caller that lent too little retries with the size it was told.
///
/// `is_admitted` is asked, for each expired stamp, whether that lane got admitted inside the
/// window; a null predicate reads as "none did", which sweeps every expired stamp.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `out` must be null or writable for `cap` ids for
/// the call, and `is_admitted` must be null or safe to call with `context` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_reap(
    handle: *mut SlopDeskMuxFlowTable,
    now: f64,
    is_admitted: SlopDeskLaneAdmittedFn,
    context: *mut c_void,
    out: *mut u64,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let reaped = state.inner.reap(now, |channel_id| {
        is_admitted.is_some_and(|ask| {
            // SAFETY: by the caller's obligation the predicate is safe to call with this context
            // for the duration of the call, which is exactly the scope of this closure.
            unsafe { ask(channel_id, context) }
        })
    });
    // SAFETY: the caller's obligation on `out`/`cap` is restated on `spill`.
    unsafe { spill(&reaped, out, cap) }
}

/// Shutdown: drops everything and answers every tracked flow exactly once.
///
/// Same lend shape as the reap — the count comes back whether or not the ids fit.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for `cap` ids.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_remove_all(
    handle: *mut SlopDeskMuxFlowTable,
    out: *mut u64,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let flows = state.inner.remove_all();
    // SAFETY: the caller's obligation on `out`/`cap` is restated on `spill`.
    unsafe { spill(&flows, out, cap) }
}

/// The flow host→client media datagrams for a lane must ride, or false when none is known.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out_flow` must be null or writable for one
/// `uint64_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_media_reply(
    handle: *mut SlopDeskMuxFlowTable,
    channel_id: u32,
    out_flow: *mut u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let found = unsafe { held(handle) }.and_then(|state| state.inner.media_reply_flow(channel_id));
    // SAFETY: `out_flow` is null or writable for one id by the caller's obligation.
    unsafe { put(found, out_flow) }
}

/// The flow host→client cursor datagrams for a lane must ride, or false when none is known.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out_flow` must be null or writable for one
/// `uint64_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_cursor_reply(
    handle: *mut SlopDeskMuxFlowTable,
    channel_id: u32,
    out_flow: *mut u64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let found = unsafe { held(handle) }.and_then(|state| state.inner.cursor_reply_flow(channel_id));
    // SAFETY: `out_flow` is null or writable for one id by the caller's obligation.
    unsafe { put(found, out_flow) }
}

/// How many accepted flows are tracked, media and cursor together.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_flows_count(handle: *mut SlopDeskMuxFlowTable) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.flow_count())
}

/// Whether a dropped datagram proves its sender still believes a live session exists.
///
/// # Safety
/// `payload` must be null, or point to `payload_len` bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_warrants_bye(
    channel: u8,
    payload: *const u8,
    payload_len: usize,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    warrants_bye(channel_of(channel), unsafe { borrow(payload, payload_len) })
}

/// Whether a datagram is the control-channel keepalive the idle reaper takes as its sticky proof.
///
/// A door rather than a byte test on the near side: the type byte the peek compared against is not
/// the near side's to spell, and `6` is also [`VideoChannel::Audio`]'s raw value — one table over
/// from the channel test it sits beside. What it gates is reap eligibility outright, so the reading
/// belongs with the grammar that defines it.
///
/// # Safety
/// `payload` must be null, or point to `payload_len` bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_payload_is_keepalive(
    channel: u8,
    payload: *const u8,
    payload_len: usize,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    payload_is_keepalive(channel_of(channel), unsafe { borrow(payload, payload_len) })
}

/// A bye limiter that has sent nothing.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_mux_bye_limiter_new(
    min_interval: f64,
    capacity: usize,
) -> *mut SlopDeskUnboundByeLimiter {
    Box::into_raw(Box::new(SlopDeskUnboundByeLimiter {
        inner: UnboundByeRateLimiter::new(min_interval, capacity),
    }))
}

/// Frees a bye limiter. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_mux_bye_limiter_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_bye_limiter_free(handle: *mut SlopDeskUnboundByeLimiter) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Whether a bye may be sent for this lane now, recording the send when it says yes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_bye_limiter_admit(
    handle: *mut SlopDeskUnboundByeLimiter,
    channel_id: u32,
    now: f64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.admit(channel_id, now))
}

/// Copies flow ids into the caller's buffer if they fit, reporting the count either way.
///
/// # Safety
/// `out` must be null, or writable for `cap` `uint64_t` for the call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
const unsafe fn spill(ids: &[u64], out: *mut u64, cap: usize) -> usize {
    let needed = ids.len();
    if needed == 0 || needed > cap || out.is_null() {
        // Nothing written. A caller seeing `needed > cap` retries with a bigger buffer.
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` ids by the
    // caller's obligation, and `ids` is a live Rust slice allocated inside this call, so the two
    // cannot overlap.
    unsafe { std::ptr::copy_nonoverlapping(ids.as_ptr(), out, needed) };
    needed
}

/// Writes one optional flow id out, answering whether there was one.
///
/// # Safety
/// `out` must be null, or writable for one `uint64_t` for the call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
const unsafe fn put(found: Option<u64>, out: *mut u64) -> bool {
    let Some(flow) = found else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one id for this call.
        unsafe { out.write(flow) };
    }
    true
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use slopdesk_video::geometry::VideoSize;
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{
        SLOPDESK_MUX_BOOTSTRAP_DELIVER, SLOPDESK_MUX_DISPATCH_DELIVER, SLOPDESK_MUX_DISPATCH_DROP_UNBOUND,
        SLOPDESK_MUX_DISPATCH_MINT, SLOPDESK_MUX_DROP_EMPTY, SLOPDESK_MUX_DROP_NO_STAMP,
        SLOPDESK_MUX_DROP_RETIRED, SLOPDESK_MUX_REJECT_UNADMITTED, SLOPDESK_MUX_ROUTE,
        slopdesk_mux_bootstrap_action, slopdesk_mux_bye_limiter_admit, slopdesk_mux_bye_limiter_free,
        slopdesk_mux_bye_limiter_new, slopdesk_mux_dispatch_decision, slopdesk_mux_flows_accept,
        slopdesk_mux_flows_free, slopdesk_mux_flows_media_reply, slopdesk_mux_flows_new,
        slopdesk_mux_flows_reap, slopdesk_mux_flows_remove_all, slopdesk_mux_flows_stamp_media_reply,
        slopdesk_mux_payload_is_keepalive, slopdesk_mux_router_admit, slopdesk_mux_router_free,
        slopdesk_mux_router_new, slopdesk_mux_router_retire, slopdesk_mux_router_route,
        slopdesk_mux_warrants_bye,
    };

    /// The control channel's wire tag, as the near side hands it over.
    const CONTROL: u8 = 0;

    fn hello_bytes() -> Vec<u8> {
        VideoControlMessage::Hello {
            protocol_version: 1,
            requested_window_id: 42,
            viewport: VideoSize {
                width: 1280.0,
                height: 800.0,
            },
        }
        .encode()
    }

    #[test]
    fn a_lane_routes_while_admitted_and_drops_as_a_stale_generation_after() {
        let router = slopdesk_mux_router_new();
        unsafe {
            slopdesk_mux_router_admit(router, 7);
            assert_eq!(slopdesk_mux_router_route(router, 7, 12), SLOPDESK_MUX_ROUTE);
            assert_eq!(slopdesk_mux_router_route(router, 7, 0), SLOPDESK_MUX_DROP_EMPTY);
            slopdesk_mux_router_retire(router, 7);
            assert_eq!(
                slopdesk_mux_router_route(router, 7, 12),
                SLOPDESK_MUX_DROP_RETIRED
            );
            assert_eq!(
                slopdesk_mux_router_route(router, 9, 12),
                SLOPDESK_MUX_REJECT_UNADMITTED
            );
            slopdesk_mux_router_free(router);
        }
    }

    #[test]
    fn only_a_control_hello_or_list_bootstraps_an_unbound_lane() {
        assert_eq!(
            slopdesk_mux_bootstrap_action(SLOPDESK_MUX_REJECT_UNADMITTED, 0, true, false),
            SLOPDESK_MUX_BOOTSTRAP_DELIVER
        );
        assert_eq!(
            slopdesk_mux_bootstrap_action(SLOPDESK_MUX_DROP_RETIRED, 0, false, true),
            SLOPDESK_MUX_BOOTSTRAP_DELIVER
        );
        assert_eq!(
            slopdesk_mux_bootstrap_action(SLOPDESK_MUX_REJECT_UNADMITTED, 4, true, false),
            SLOPDESK_MUX_DROP_NO_STAMP
        );
        assert_eq!(
            slopdesk_mux_bootstrap_action(SLOPDESK_MUX_ROUTE, 0, true, false),
            SLOPDESK_MUX_DROP_NO_STAMP
        );
    }

    #[test]
    fn a_new_lane_mints_on_its_first_hello_and_a_live_one_only_ever_delivers() {
        let hello = hello_bytes();
        let keepalive = VideoControlMessage::Keepalive.encode();
        unsafe {
            assert_eq!(
                slopdesk_mux_dispatch_decision(CONTROL, hello.as_ptr(), hello.len(), false, false),
                SLOPDESK_MUX_DISPATCH_MINT
            );
            assert_eq!(
                slopdesk_mux_dispatch_decision(CONTROL, hello.as_ptr(), hello.len(), true, false),
                SLOPDESK_MUX_DISPATCH_DELIVER
            );
            assert_eq!(
                slopdesk_mux_dispatch_decision(CONTROL, hello.as_ptr(), hello.len(), false, true),
                SLOPDESK_MUX_DISPATCH_DELIVER,
                "a hello retransmit must not mint a second session"
            );
            assert_eq!(
                slopdesk_mux_dispatch_decision(CONTROL, keepalive.as_ptr(), keepalive.len(), false, false),
                SLOPDESK_MUX_DISPATCH_DROP_UNBOUND
            );
            assert_eq!(
                slopdesk_mux_dispatch_decision(4, hello.as_ptr(), hello.len(), false, false),
                SLOPDESK_MUX_DISPATCH_DROP_UNBOUND,
                "hello-shaped bytes on the input channel bind nothing"
            );
            assert_eq!(
                slopdesk_mux_dispatch_decision(CONTROL, std::ptr::null(), 0, false, false),
                SLOPDESK_MUX_DISPATCH_DROP_UNBOUND,
                "a null payload is the empty one, which names no message"
            );
        }
    }

    #[test]
    fn only_a_control_keepalive_crosses_as_the_reapers_liveness_proof() {
        let keepalive = VideoControlMessage::Keepalive.encode();
        let focus = VideoControlMessage::FocusWindow.encode();
        unsafe {
            assert!(slopdesk_mux_payload_is_keepalive(
                CONTROL,
                keepalive.as_ptr(),
                keepalive.len()
            ));
            assert!(
                !slopdesk_mux_payload_is_keepalive(6, keepalive.as_ptr(), keepalive.len()),
                "tag 6 is the AUDIO channel — the same bytes there are no liveness proof"
            );
            assert!(!slopdesk_mux_payload_is_keepalive(
                CONTROL,
                focus.as_ptr(),
                focus.len()
            ));
            assert!(!slopdesk_mux_payload_is_keepalive(CONTROL, std::ptr::null(), 0));
        }
    }

    /// A predicate that admits nothing, in the shape the reap asks for.
    unsafe extern "C" fn admits_nothing(_: u32, _: *mut std::ffi::c_void) -> bool {
        false
    }

    #[test]
    fn a_referenced_flow_survives_a_reap_and_an_unreferenced_one_does_not() {
        let flows = slopdesk_mux_flows_new(10.0);
        let mut out = [0_u64; 4];
        unsafe {
            slopdesk_mux_flows_accept(flows, 1, true, 0.0);
            slopdesk_mux_flows_accept(flows, 2, true, 0.0);
            slopdesk_mux_flows_stamp_media_reply(flows, 5, 1);
            let reaped = slopdesk_mux_flows_reap(
                flows,
                100.0,
                Some(admits_nothing),
                std::ptr::null_mut(),
                out.as_mut_ptr(),
                out.len(),
            );
            assert_eq!(reaped, 1);
            assert_eq!(out[0], 2);
            let mut flow = 0_u64;
            assert!(slopdesk_mux_flows_media_reply(flows, 5, &raw mut flow));
            assert_eq!(flow, 1);
            assert_eq!(
                slopdesk_mux_flows_remove_all(flows, out.as_mut_ptr(), out.len()),
                1
            );
            slopdesk_mux_flows_free(flows);
        }
    }

    #[test]
    fn a_short_buffer_is_told_the_size_it_should_have_lent() {
        let flows = slopdesk_mux_flows_new(10.0);
        unsafe {
            slopdesk_mux_flows_accept(flows, 1, true, 0.0);
            slopdesk_mux_flows_accept(flows, 2, false, 0.0);
            assert_eq!(slopdesk_mux_flows_remove_all(flows, std::ptr::null_mut(), 0), 2);
            slopdesk_mux_flows_free(flows);
        }
    }

    #[test]
    fn an_in_session_datagram_earns_a_bye_and_a_host_to_client_one_never_does() {
        let payload = [0x01_u8, 0xFF];
        unsafe {
            assert!(slopdesk_mux_warrants_bye(4, payload.as_ptr(), payload.len()));
            assert!(!slopdesk_mux_warrants_bye(1, payload.as_ptr(), payload.len()));
        }
    }

    #[test]
    fn a_wedged_lane_is_told_once_per_interval() {
        let limiter = slopdesk_mux_bye_limiter_new(1.0, 8);
        unsafe {
            assert!(slopdesk_mux_bye_limiter_admit(limiter, 3, 10.0));
            assert!(!slopdesk_mux_bye_limiter_admit(limiter, 3, 10.5));
            assert!(slopdesk_mux_bye_limiter_admit(limiter, 3, 11.0));
            slopdesk_mux_bye_limiter_free(limiter);
        }
    }
}
