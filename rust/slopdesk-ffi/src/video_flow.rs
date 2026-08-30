//! PATH 2's shared client UDP flow, as one handle and a per-lane sink.
//!
//! Behind it is [`slopdesk_videolink`] — two sockets, two readers, one lane table — which is the
//! whole of what `NWVideoMuxClientFlow.swift` did. Nothing here decides anything; this file is the
//! calling convention and the lifetime rules, per the crate header.
//!
//! ## No lane count here
//!
//! `slopdesk_video_pool_lane_count` next door already answers it, and it is the one the registry
//! asks because the REFCOUNT is what decides a teardown — this side's table is what that decision
//! is carried out on. `slopdesk_videolink`'s own `lane_count` stays for its suite.
//!
//! ## Two callbacks, not one
//!
//! Unlike [`crate::device_link`], whose every event is the same "a kind and a run of bytes", the
//! two things this flow delivers differ in their SHAPE: a media datagram carries a decoded channel
//! tag the near side switches on, a cursor datagram carries none. Folding them would mean a kind
//! byte the near side immediately re-splits, plus a tag argument that is meaningless on half the
//! calls.
//!
//! ## Four obligations
//!
//! 1. `context` stays valid until `on_release` is called for it. This side calls `on_release`
//!    EXACTLY once per successful [`slopdesk_video_flow_register_lane`], from whichever thread
//!    drops the sink's last reference — the caller's, inside
//!    [`slopdesk_video_flow_unregister_lane`], [`slopdesk_video_flow_close`] or
//!    [`slopdesk_video_flow_free`], or a reader's if it was mid-delivery. That is why a release
//!    callback exists at all: unregistering a lane cannot join the reader that serves the other
//!    lanes, so "no callback after unregister returns" is not a promise this door can keep, and
//!    `on_release` is the one that can.
//! 2. The callbacks run on the flow's OWN reader threads, never on the caller's. The media and the
//!    cursor callback for the SAME lane can run CONCURRENTLY, because they are two sockets read by
//!    two threads. A near side that touches shared state synchronises it.
//! 3. No callback may re-enter [`slopdesk_video_flow_close`] or [`slopdesk_video_flow_free`]. Both
//!    join the threads the callbacks run on.
//! 4. Every pointer in every callback is LENT for that call. A caller that keeps a payload copies
//!    it.

use core::ffi::{c_uchar, c_void};
use std::sync::Arc;

use slopdesk_video::recovery_routing::VideoChannel;
use slopdesk_videolink::flow::{Flow, LaneSink};

use crate::borrow;

/// One host's shared media + cursor flow. Opaque; freed by [`slopdesk_video_flow_free`].
#[derive(Debug)]
pub struct SlopDeskVideoFlow(Flow);

/// The near side's lane: a context pointer and the three functions that reach it.
///
/// A struct rather than a closure because a `@convention(c)` pointer captures nothing, so the
/// context has to travel beside it.
struct Lane {
    context: *mut c_void,
    on_media: unsafe extern "C" fn(*mut c_void, u8, *const c_uchar, usize),
    on_cursor: unsafe extern "C" fn(*mut c_void, *const c_uchar, usize),
    on_release: unsafe extern "C" fn(*mut c_void),
}

// SAFETY: `context` is the near side's, and obligation 1 above is what makes moving it to a reader
// thread sound — it stays valid until `on_release` is called, and this side calls that only after
// the last reference to this struct is gone. The pointer is never dereferenced here; it is handed
// back to the near side, which owns what it means.
#[expect(
    unsafe_code,
    reason = "the context is a raw pointer the caller keeps alive across a thread"
)]
unsafe impl Send for Lane {}
// SAFETY: as above, and the near side is told (obligation 2) that its two callbacks can run at
// once, so a shared reference to this struct is only ever read.
#[expect(
    unsafe_code,
    reason = "the context is a raw pointer the caller keeps alive across a thread"
)]
unsafe impl Sync for Lane {}

/// An empty run crosses as a null pointer and a zero length, which is the convention every other
/// door in this crate uses.
const fn lend(payload: &[u8]) -> (*const c_uchar, usize) {
    if payload.is_empty() {
        (core::ptr::null(), 0)
    } else {
        (payload.as_ptr(), payload.len())
    }
}

impl LaneSink for Lane {
    #[expect(
        unsafe_code,
        reason = "calling the caller's own function pointer is the whole point"
    )]
    fn media(&self, channel: VideoChannel, payload: &[u8]) {
        let (bytes, length) = lend(payload);
        // SAFETY: `on_media` is the pointer the caller passed to the register door and `context` is
        // its own; both are valid until `on_release` runs, which cannot happen while this does
        // because this call is holding the reference whose drop would trigger it.
        unsafe { (self.on_media)(self.context, channel.raw_value(), bytes, length) }
    }

    #[expect(
        unsafe_code,
        reason = "calling the caller's own function pointer is the whole point"
    )]
    fn cursor(&self, payload: &[u8]) {
        let (bytes, length) = lend(payload);
        // SAFETY: as above, for the cursor half.
        unsafe { (self.on_cursor)(self.context, bytes, length) }
    }
}

impl Drop for Lane {
    #[expect(
        unsafe_code,
        reason = "calling the caller's own function pointer is the whole point"
    )]
    fn drop(&mut self) {
        // SAFETY: this runs once, when the last reference to this lane is gone, so no callback is
        // in flight and none can start. That is exactly the moment obligation 1 names.
        unsafe { (self.on_release)(self.context) }
    }
}

/// Open the media and cursor sockets to `host` and start both readers.
///
/// Null when `host` is not UTF-8, when it does not resolve, or when either socket cannot be bound —
/// which is the point of doing this over a plain socket: a bring-up failure is answered HERE
/// instead of arriving later through a state handler. No callback has run in that case, and the
/// caller has registered no lane, so it has nothing to release.
///
/// # Safety
/// `host` is null or `host_len` readable bytes for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_open(
    host: *const c_uchar,
    host_len: usize,
    media_port: u16,
    cursor_port: u16,
) -> *mut SlopDeskVideoFlow {
    // SAFETY: the caller's obligation, restated at the door; the borrow dies with this call.
    let Ok(host) = core::str::from_utf8(unsafe { borrow(host, host_len) }) else {
        return core::ptr::null_mut();
    };
    let Ok(flow) = Flow::open(host, media_port, cursor_port) else {
        return core::ptr::null_mut();
    };
    Box::into_raw(Box::new(SlopDeskVideoFlow(flow)))
}

/// Register a lane's sinks under `channel_id` and prime its cursor flow.
///
/// The prime is the one datagram that has to be sent for the lane to receive cursor updates at all:
/// the host accepts a cursor flow only on an inbound datagram. Registering a `channel_id` that is
/// already registered REPLACES it — the old lane's `on_release` runs, and the new one is primed.
///
/// `false`, with no callback ever run and nothing to release, when `flow` is null.
///
/// # Safety
/// `flow` is null or a live handle from [`slopdesk_video_flow_open`], and `context` stays valid
/// until `on_release` is called with it — see obligation 1 in the module header.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_register_lane(
    flow: *mut SlopDeskVideoFlow,
    channel_id: u32,
    context: *mut c_void,
    on_media: unsafe extern "C" fn(*mut c_void, u8, *const c_uchar, usize),
    on_cursor: unsafe extern "C" fn(*mut c_void, *const c_uchar, usize),
    on_release: unsafe extern "C" fn(*mut c_void),
) -> bool {
    // SAFETY: the caller's obligation, restated at the door; the borrow dies with this call.
    unsafe { flow.as_ref() }.is_some_and(|flow| {
        flow.0.register_lane(
            channel_id,
            Arc::new(Lane {
                context,
                on_media,
                on_cursor,
                on_release,
            }),
        );
        true
    })
}

/// Drop a lane's sinks. Datagrams for it are dropped from the next one on.
///
/// Its `on_release` runs before this returns UNLESS a reader is mid-delivery, in which case that
/// reader runs it as it finishes. A `channel_id` that is not registered is a no-op.
///
/// # Safety
/// `flow` is null or a live handle from [`slopdesk_video_flow_open`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_unregister_lane(flow: *mut SlopDeskVideoFlow, channel_id: u32) {
    // SAFETY: the caller's obligation, restated at the door.
    if let Some(flow) = unsafe { flow.as_ref() } {
        flow.0.unregister_lane(channel_id);
    }
}

/// Send one media datagram for `channel_id`, tag-stamped. `false` when it did not leave.
///
/// # Safety
/// `flow` is null or a live handle from [`slopdesk_video_flow_open`], and `payload` is null or
/// `payload_len` readable bytes — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_send_media(
    flow: *mut SlopDeskVideoFlow,
    channel_id: u32,
    tag: u8,
    payload: *const c_uchar,
    payload_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated at the door; both borrows die with this call.
    unsafe { flow.as_ref() }.is_some_and(|flow| {
        // SAFETY: as above.
        flow.0
            .send_media(channel_id, tag, unsafe { borrow(payload, payload_len) })
    })
}

/// Send one cursor datagram for `channel_id` — the lane's re-prime. `false` when it did not leave.
///
/// # Safety
/// `flow` is null or a live handle from [`slopdesk_video_flow_open`], and `payload` is null or
/// `payload_len` readable bytes — both for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_send_cursor(
    flow: *mut SlopDeskVideoFlow,
    channel_id: u32,
    payload: *const c_uchar,
    payload_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated at the door; both borrows die with this call.
    unsafe { flow.as_ref() }.is_some_and(|flow| {
        // SAFETY: as above.
        flow.0
            .send_cursor(channel_id, unsafe { borrow(payload, payload_len) })
    })
}

/// Whether the LAST media send reached the path.
///
/// The session's PERIODIC producers — the 20 Hz stats reports, the 5 s keepalive — skip their fire
/// while this is false. Sparse best-effort sends are not gated. `true` for a null handle, which is
/// the same optimism a fresh flow starts with: this gate exists to suppress a flood, never to be a
/// state-machine input.
///
/// # Safety
/// `flow` is null or a live handle from [`slopdesk_video_flow_open`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_send_path_viable(flow: *const SlopDeskVideoFlow) -> bool {
    // SAFETY: the caller's obligation, restated at the door.
    unsafe { flow.as_ref() }.is_none_or(|flow| flow.0.is_send_path_viable())
}

/// Tear both sockets down, leaving the handle VALID.
///
/// JOINS both readers, so no callback is running when this returns and none ever will be again, and
/// runs every remaining lane's `on_release`. Every later call on the handle is a cheap refusal; a
/// null pointer, and a second close, are no-ops.
///
/// This is the door a caller ends a flow through, and [`slopdesk_video_flow_free`] is the one it
/// ends the HANDLE through. Splitting them is what lets the near side keep its pointer for its
/// whole object lifetime: a flow torn down while another thread is inside a send answers `false`,
/// where a flow FREED under that thread is a use-after-free the near side cannot lock its way out
/// of — unregistering cannot join, so no lock it could hold would span the call.
///
/// # Safety
/// `flow` is null or a live handle from [`slopdesk_video_flow_open`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_close(flow: *mut SlopDeskVideoFlow) {
    // SAFETY: the caller's obligation, restated at the door.
    if let Some(flow) = unsafe { flow.as_ref() } {
        flow.0.close();
    }
}

/// Release the handle, closing it first if it is not closed already.
///
/// A null pointer is a no-op. Carries every obligation [`slopdesk_video_flow_close`] does, plus
/// one: no thread may be inside ANY door on this handle when it is called.
///
/// # Safety
/// `flow` is null or a handle from [`slopdesk_video_flow_open`] that is freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_video_flow_free(flow: *mut SlopDeskVideoFlow) {
    if flow.is_null() {
        return;
    }
    // SAFETY: the caller's obligation — this pointer came from `slopdesk_video_flow_open` and is
    // freed exactly once. The drop tears down and joins.
    drop(unsafe { Box::from_raw(flow) });
}
