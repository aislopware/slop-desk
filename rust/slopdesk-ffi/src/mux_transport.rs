//! PATH-1's client end, as two handles: a connection POOL and one CHANNEL on it.
//!
//! `docs/63` G.3. Behind it is [`slopdesk_clientnet`] — the dial, the pool, and
//! [`ChannelTransport`], which is the whole of what `MuxClientTransport.swift` decided. Nothing
//! here decides anything; this file is the calling convention and the lifetime rules, per the crate
//! header.
//!
//! ## Why the inbound record is a `SlopDeskWireMessage` and not a routing verdict
//!
//! The Swift transport handed its owner an `AsyncThrowingStream<WireMessage>` and the owner
//! decoded. With the socket in Rust the receive buffer is Rust's, so `blob_offset` has nothing left
//! to be an offset INTO — the datagram it used to index does not exist on the Swift side any more.
//! So the callback lends the run as its own `(ptr, len)` and sets `blob_offset = 0`, which is
//! exactly the convention [`crate::frame_decoder`] already uses for a parked run. Everything else
//! is [`crate::wire_message`]'s flattening, unchanged, so the Swift face that reads a
//! `SlopDeskWireMessage` today reads this one too and G.4 inherits it rather than replacing it.
//!
//! ## Three obligations, which are `docs/55` §4b's
//!
//! 1. `context` stays valid until [`slopdesk_mux_transport_free`] RETURNS — not until it is
//!    entered. `free` joins both forwarder threads, so a callback may still be running when it is
//!    called, and it is not once it answers.
//! 2. Both callbacks may run on ANY thread and never concurrently with each other. They are
//!    serialised by one lock inside [`ChannelTransport`], so a Swift closure that touches an
//!    unsynchronised field is safe without adding a queue.
//! 3. Neither callback may re-enter [`slopdesk_mux_transport_free`]. It joins the very thread the
//!    callback is running on. Sending IS allowed and is the common case — an `ack` written from
//!    inside `on_inbound` is what the ack gate does.
//!
//! ## What the ended callback is, and what it is not
//!
//! One `kind` and one raw close-reason byte. A `Peer` end carries the reason the host named, and
//! that reason decides opposite behaviours upstream — `Retired` means a re-open is a fresh spawn,
//! `SubscriberEvicted` means the pane is still there. `Decode` lends its diagnostic text; the
//! others lend nothing. There is no separate "why did it end" door, because the answer is delivered
//! exactly once and a caller that has to ASK is a caller that can ask too early.

use core::ffi::{c_uchar, c_void};
use std::sync::Arc;
use std::time::Duration;

use slopdesk_clientnet::dial::Endpoint;
use slopdesk_clientnet::registry::DiallingPool;
use slopdesk_clientnet::transport::{ChannelTransport, InboundSink, OpenError};
use slopdesk_muxnet::connection::OpenRequest;
use slopdesk_muxnet::subchannel::{ChannelEnd, SendError};
use slopdesk_wire::{SESSION_ID_BYTE_COUNT, WireMessage};

use crate::wire_message::{SlopDeskWireMessage, pack, unpack};
use crate::{borrow, lent};

/// This side closed the channel, or the pool did.
pub const SLOPDESK_MUX_END_LOCAL: u32 = 0;
/// The peer sent `channelClose`; `close_reason` is its raw byte.
pub const SLOPDESK_MUX_END_PEER: u32 = 1;
/// The link carrying the channel died. Says nothing about the channel itself, so a reattach is
/// the right reflex where a `Peer`/`Retired` end forbids one.
pub const SLOPDESK_MUX_END_LINK_DOWN: u32 = 2;
/// This channel's own inner framing faulted. `detail` lends the diagnostic.
pub const SLOPDESK_MUX_END_DECODE: u32 = 3;

/// The send went out.
pub const SLOPDESK_MUX_SEND_OK: i32 = 0;
/// The channel is finished — closed, reaped, or its link is gone. Not retryable.
pub const SLOPDESK_MUX_SEND_CLOSED: i32 = 1;
/// The write failed on the link, which is dying. Not retryable on this channel.
pub const SLOPDESK_MUX_SEND_LINK: i32 = 2;
/// The caller passed a handle or a record this door cannot use: a null transport, a
/// `message_type` no arm claims, or an `input` offered to the CONTROL door. Nothing was sent.
pub const SLOPDESK_MUX_SEND_REFUSED: i32 = 3;

/// One inbound message, lent for the duration of the call.
///
/// `arena` is [`crate::wire_message`]'s text arena and `blob` is the opaque run — separate pointers
/// because they are separate address spaces, exactly as the decode door documents. Both are borrows
/// that end when this function returns; a caller that keeps either must copy.
pub type SlopDeskMuxInboundFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        message: *const SlopDeskWireMessage,
        arena: *const c_uchar,
        arena_len: usize,
        blob: *const c_uchar,
        blob_len: usize,
    ),
>;

/// The channel is over. Called exactly once, and nothing follows it.
///
/// `detail` carries text only for [`SLOPDESK_MUX_END_DECODE`]; `detail_len` is 0 for every other
/// kind, and the pointer is then a dangling non-null Rust reads as an empty string. Check the
/// LENGTH, never the pointer.
pub type SlopDeskMuxEndedFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        kind: u32,
        close_reason: c_uchar,
        detail: *const c_uchar,
        detail_len: usize,
    ),
>;

/// The caller's opaque context pointer, carried to both callbacks.
///
/// A newtype for [`crate::decoder`]'s reason: a bare `*mut c_void` is neither `Send` nor `Sync`,
/// and the promise that makes it both is the CALLER's, stated at
/// [`slopdesk_mux_transport_open`]. Stronger here than for the decoder — these callbacks run on
/// forwarder threads this crate created, never on the caller's.
#[derive(Clone, Copy, Debug)]
struct CallerContext(*mut c_void);

// SAFETY: the caller of `slopdesk_mux_transport_open` promises this pointer is valid until
// `slopdesk_mux_transport_free` returns and usable from any thread. Both forwarders hand it back
// through the two function pointers below, and neither ever dereferences it here.
#[expect(
    unsafe_code,
    reason = "the context's thread-safety is the caller's stated obligation"
)]
unsafe impl Send for CallerContext {}
// SAFETY: as above.
#[expect(
    unsafe_code,
    reason = "the context's thread-safety is the caller's stated obligation"
)]
unsafe impl Sync for CallerContext {}

/// The two C function pointers, expressed as the sink [`ChannelTransport`] takes.
#[derive(Debug)]
struct CSink {
    context: CallerContext,
    inbound: SlopDeskMuxInboundFn,
    ended: SlopDeskMuxEndedFn,
}

impl InboundSink for CSink {
    /// # Safety
    /// Every pointer handed over names memory owned by this frame — the packed record, its arena
    /// and the message's own run — so all three are live for the whole call and dead after it,
    /// which is what the door's lend-for-the-call term says.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn message(&self, message: &WireMessage) {
        let Some(deliver) = self.inbound else {
            return;
        };
        let run = message.opaque_run();
        // `0..run.len()` rather than a slice into a datagram: there is no datagram here, the
        // message owns its bytes. `blob_offset` is therefore 0 and `blob_length` is the run's,
        // which is the same shape `frame_decoder` writes when it parks a run.
        let packed = pack(message, &(0..run.len()));
        // SAFETY: the context is live by the door's documented term, and the three spans below all
        // outlive the call — `packed` and `run` are locals of this frame.
        unsafe {
            deliver(
                self.context.0,
                &raw const packed.flat,
                packed.arena.as_ptr(),
                packed.arena.len(),
                run.as_ptr(),
                run.len(),
            );
        }
    }

    /// # Safety
    /// As above; `detail` borrows the end's own string, which lives until this function returns.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn ended(&self, end: &ChannelEnd) {
        let Some(deliver) = self.ended else {
            return;
        };
        let (kind, reason, detail) = match *end {
            ChannelEnd::Local => (SLOPDESK_MUX_END_LOCAL, 0, ""),
            ChannelEnd::Peer(reason) => (SLOPDESK_MUX_END_PEER, reason.as_byte(), ""),
            ChannelEnd::LinkDown => (SLOPDESK_MUX_END_LINK_DOWN, 0, ""),
            ChannelEnd::Decode(ref detail) => (SLOPDESK_MUX_END_DECODE, 0, detail.as_str()),
        };
        // SAFETY: the context is live by the door's documented term, and `detail` borrows a string
        // owned by the caller's `end`, which outlives this call.
        unsafe {
            deliver(self.context.0, kind, reason, detail.as_ptr(), detail.len());
        }
    }
}

/// The pooled connections to every host this client talks to, and the threads serving them.
///
/// One per app, not one per pane: every pane to one host rides ONE mux, which is the property
/// PATH-1 exists for.
///
/// It is one field, and the dial closure that used to sit here is gone: minting an id, calling
/// [`slopdesk_clientnet::dial::establish`], dropping the event receiver and stashing the join
/// handles is what EVERY shipping owner of a registry does, and there are two of them — this pool
/// and `slopdesk-client`. [`DiallingPool`] is that owner written once, so `free` is still a real
/// quiescence point (it closes then joins) without this file owning the list that makes it one.
#[derive(Debug)]
pub struct SlopDeskMuxPool {
    /// Reachable from [`crate::pane_driver`], which opens its channels on this same pool rather
    /// than minting a second one: every pane to one host and the workspace document ride ONE mux,
    /// and two registries would be two TCP pairs and two client identities at the host.
    pub(crate) pool: DiallingPool,
}

/// One channel, with the pooled connection under it.
#[derive(Debug)]
pub struct SlopDeskMuxTransport {
    transport: ChannelTransport,
}

/// Reconstitutes a pool handle for the duration of a call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_mux_pool_new`] that has not been freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn pool<'a>(handle: *const SlopDeskMuxPool) -> Option<&'a SlopDeskMuxPool> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and every field behind it is either
    // immutable or guarded, so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// Reconstitutes a transport handle for the duration of a call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_mux_transport_open`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskMuxTransport) -> Option<&'a SlopDeskMuxTransport> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: as `pool`'s.
    Some(unsafe { &*handle })
}

/// How a [`SendError`] reaches Swift.
const fn verdict(error: &SendError) -> i32 {
    match *error {
        SendError::Closed => SLOPDESK_MUX_SEND_CLOSED,
        SendError::Link(_) => SLOPDESK_MUX_SEND_LINK,
    }
}

/// Creates a connection pool. It dials nothing until the first channel asks it to.
///
/// `connect_timeout_ms` bounds each dial — both sockets and the whole address ladder behind a
/// hostname, not each attempt, so a mesh name that resolves to four dead addresses still answers
/// inside it.
///
/// # Safety
/// The answer must be passed to [`slopdesk_mux_pool_free`] exactly once, after every transport
/// opened on it has been freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_pool_new(connect_timeout_ms: u64) -> *mut SlopDeskMuxPool {
    let pool = DiallingPool::new(Duration::from_millis(connect_timeout_ms));
    Box::into_raw(Box::new(SlopDeskMuxPool { pool }))
}

/// Tears every pooled connection down and waits for its receive loops to return.
///
/// Closes before joining, and closes UNCONDITIONALLY: a connection the pool already retired is
/// idempotently closed a second time, and one still holding a channel is closed rather than waited
/// on, so this can never hang on a caller that leaked a transport. Every thread this module ever
/// started has returned by the time it answers.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_mux_pool_new`] that has not already been
/// freed, no call on it may be in flight, and every transport opened on it must already be freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_pool_free(handle: *mut SlopDeskMuxPool) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `new` with no call in
    // flight — so this reconstitutes the unique owner.
    let held = unsafe { Box::from_raw(handle) };
    held.pool.close();
    drop(held);
}

/// Whether a connection to `host:port` is pooled and alive.
///
/// # Safety
/// [`pool`]'s, plus `(host, host_len)` must be null-with-zero-length or live UTF-8 for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_pool_is_alive(
    handle: *const SlopDeskMuxPool,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
) -> bool {
    // SAFETY: the caller's obligations, above.
    let (Some(held), host) = (unsafe { (pool(handle), lent(host, host_len)) }) else {
        return false;
    };
    held.pool.registry().is_alive(&Endpoint::new(host, port))
}

/// Holds the connection to `host:port` open with no channel on it, dialling if there is none.
///
/// Answers whether the pin took. A pinned connection survives its last channel closing, which is
/// what a client that is about to re-open a pane wants and what the pool would otherwise reap.
///
/// # Safety
/// [`slopdesk_mux_pool_is_alive`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_pool_pin(
    handle: *const SlopDeskMuxPool,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
) -> bool {
    // SAFETY: the caller's obligations, above.
    let (Some(held), host) = (unsafe { (pool(handle), lent(host, host_len)) }) else {
        return false;
    };
    held.pool.registry().pin(&Endpoint::new(host, port)).is_ok()
}

/// Releases a pin, reaping the connection if nothing else holds it.
///
/// # Safety
/// [`slopdesk_mux_pool_is_alive`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_pool_unpin(
    handle: *const SlopDeskMuxPool,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
) {
    // SAFETY: the caller's obligations, above.
    let (Some(held), host) = (unsafe { (pool(handle), lent(host, host_len)) }) else {
        return;
    };
    held.pool.registry().unpin(&Endpoint::new(host, port));
}

/// How many channels ride the connection to `host:port`. Zero if there is none.
///
/// # Safety
/// [`slopdesk_mux_pool_is_alive`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_pool_channel_count(
    handle: *const SlopDeskMuxPool,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
) -> usize {
    // SAFETY: the caller's obligations, above.
    let (Some(held), host) = (unsafe { (pool(handle), lent(host, host_len)) }) else {
        return 0;
    };
    held.pool.registry().channel_count(&Endpoint::new(host, port))
}

/// How many connections the pool holds, across every endpoint.
///
/// # Safety
/// [`pool`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_pool_connection_count(handle: *const SlopDeskMuxPool) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(held) = (unsafe { pool(handle) }) else {
        return 0;
    };
    held.pool.registry().pooled_connection_count()
}

/// Opens one channel on the pooled connection to `host:port`, and starts delivering its inbound.
///
/// CLASS-GENERIC: `channel_class` is the raw `channelOpen` byte, so one door serves a pane and the
/// workspace document alike. The channel is usable the moment this returns — the responder opens on
/// the first `channelOpen` rather than on a handshake, so
/// [`slopdesk_mux_transport_await_open_ack`] collects a verdict about RESUME and is not permission
/// to write.
///
/// `session_id` reads 16 raw bytes; all-zero asks for a new session. `initial_cwd` is
/// null-with-zero-length for "wherever the host would start", and a non-empty span for a directory
/// — the two encode differently, so an empty string is NOT the same request as no string.
///
/// Answers null if the dial failed, the connection refused a channel, or a forwarder thread could
/// not start. On null, neither callback has run or ever will, and `context` may be freed at once.
///
/// # Safety
/// `context` must stay valid and usable from any thread until [`slopdesk_mux_transport_free`]
/// returns. Every `(ptr, len)` pair must be null-with-zero-length or live for the duration of THIS
/// call — nothing here is retained. `session_id` must be null or 16 readable bytes. The answer must
/// be passed to [`slopdesk_mux_transport_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_transport_open(
    handle: *const SlopDeskMuxPool,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
    channel_class: c_uchar,
    session_id: *const c_uchar,
    last_received_seq: i64,
    initial_cwd: *const c_uchar,
    initial_cwd_len: usize,
    context: *mut c_void,
    on_inbound: SlopDeskMuxInboundFn,
    on_ended: SlopDeskMuxEndedFn,
) -> *mut SlopDeskMuxTransport {
    // SAFETY: the caller's obligations, above — three borrows, none outliving the call.
    let (Some(held), host, cwd, raw) = (unsafe {
        (
            pool(handle),
            lent(host, host_len),
            lent(initial_cwd, initial_cwd_len),
            borrow(session_id, SESSION_ID_BYTE_COUNT),
        )
    }) else {
        return core::ptr::null_mut();
    };
    let mut session = [0_u8; SESSION_ID_BYTE_COUNT];
    if let Some(slot) = session.get_mut(..raw.len()) {
        slot.copy_from_slice(raw);
    }
    let request = OpenRequest {
        session_id: session,
        last_received_seq,
        channel_class,
        // Absent and empty are different requests on the wire, so the null pointer stays `None`
        // rather than collapsing into `Some("")`.
        initial_cwd: (!cwd.is_empty()).then(|| cwd.to_owned()),
    };
    let sink = Arc::new(CSink {
        context: CallerContext(context),
        inbound: on_inbound,
        ended: on_ended,
    });
    match ChannelTransport::open(
        Arc::clone(held.pool.registry()),
        &Endpoint::new(host, port),
        &request,
        sink,
    ) {
        Ok(transport) => Box::into_raw(Box::new(SlopDeskMuxTransport { transport })),
        // Both arms are the same answer on purpose: a caller does the same thing with each — report
        // and retry the dial — and `OpenError`'s own `Display` is the taxonomy for a log, not for a
        // branch. See `AcquireError`'s header for the same reasoning one layer down.
        Err(OpenError::Acquire(_) | OpenError::Forwarder(_)) => core::ptr::null_mut(),
    }
}

/// Closes the channel, joins both forwarders, and frees the handle.
///
/// Releases the pool entry, which sends `channelClose` and tears the connection down if this was
/// its last channel. Idempotent as to the close: a caller that saw the ended callback and a caller
/// that decided to leave are the same caller, and it does not know which of them ran first.
///
/// `context` may be freed as soon as this RETURNS, and not before: it joins the forwarders, so a
/// callback may still be running when it is entered.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_mux_transport_open`] that has not already
/// been freed, and no other call on it may be in flight. Never call it from inside either callback:
/// it joins the thread the callback is running on.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_transport_free(handle: *mut SlopDeskMuxTransport) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `open` with no call in
    // flight — so this reconstitutes the unique owner.
    let held = unsafe { Box::from_raw(handle) };
    held.transport.close();
    drop(held);
}

/// The channel id this end allocated. Stable for the channel's whole life; 0 for a null handle.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub const unsafe extern "C" fn slopdesk_mux_transport_channel_id(handle: *const SlopDeskMuxTransport) -> u32 {
    // SAFETY: the caller's obligation, above.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    held.transport.channel_id()
}

/// Waits for the responder's verdict on the open, answering whether it was ACCEPTED.
///
/// `resume_from_seq_out` receives the seq the host will resume from, which is the reason the
/// verdict is worth waiting for: this end's `last_received_seq` was a request, and that is the
/// answer.
///
/// A refusal covers every way there is no verdict — refused, the connection died, or nothing
/// arrived inside `timeout_ms` — because the caller does the same thing with each: a pane that
/// cannot be told where to resume from cannot resume. That collapse is
/// [`OpenAck::REFUSED`](slopdesk_muxnet::connection::OpenAck::REFUSED)'s, restated here so the door
/// is not read as having lost a distinction it never had.
///
/// # Safety
/// [`held`]'s, plus `resume_from_seq_out` must be null or writable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_transport_await_open_ack(
    handle: *const SlopDeskMuxTransport,
    timeout_ms: u64,
    resume_from_seq_out: *mut i64,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(held) = (unsafe { held(handle) }) else {
        return false;
    };
    let ack = held.transport.await_open_ack(Duration::from_millis(timeout_ms));
    if !resume_from_seq_out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable.
        unsafe { *resume_from_seq_out = ack.resume_from_seq };
    }
    ack.accepted
}

// NOTE: there is no `slopdesk_mux_transport_send_input`. A pane's keystrokes reach the DATA lane
// through `slopdesk_pane_driver_send_input` now (`docs/63` §G.5), which is the same
// `ChannelTransport::send_input` one layer further in — including the split at the flow cap that a
// paste larger than the window needs. What is left on this handle is the WORKSPACE channel, which
// is `channelClass 1` and speaks control alone, so a data-lane door here had no caller.

/// Sends one message on the CONTROL lane.
///
/// Verb-agnostic: `resize`, `ack`, `bye`, `ping`, `requestBlockOutput`, `metadataRequest` and
/// `workspaceRequest` differ only in their payload, and seven near-identical doors would be seven
/// places for a lane to be chosen wrongly. The record and its arena are
/// [`crate::wire_message`]'s, so the encode door's flattening is reused rather than mirrored.
///
/// REFUSES an `input`. CONTROL is unwindowed, so a paste routed here would bypass flow control
/// entirely and put a 16 MiB frame on the lane a `Ctrl-C` needs — the exact failure the two lanes
/// exist to prevent. It is refused rather than rerouted, because a caller that reached for the
/// wrong door has a bug that a silent correction would hide.
///
/// # Safety
/// [`held`]'s, plus `message` must point at one live struct and every `(ptr, len)` pair must be
/// null-with-zero-length or live for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_mux_transport_send(
    handle: *const SlopDeskMuxTransport,
    message: *const SlopDeskWireMessage,
    arena: *const c_uchar,
    arena_len: usize,
    blob: *const c_uchar,
    blob_len: usize,
) -> i32 {
    if message.is_null() {
        return SLOPDESK_MUX_SEND_REFUSED;
    }
    // SAFETY: the caller's obligations, above — one struct read and two borrows, none outliving
    // the call.
    let (Some(held), flat, arena, blob) = (unsafe {
        (
            held(handle),
            &*message,
            borrow(arena, arena_len),
            borrow(blob, blob_len),
        )
    }) else {
        return SLOPDESK_MUX_SEND_REFUSED;
    };
    let Some(message) = unpack(flat, arena, blob) else {
        return SLOPDESK_MUX_SEND_REFUSED;
    };
    if matches!(message, WireMessage::Input(_)) {
        return SLOPDESK_MUX_SEND_REFUSED;
    }
    held.transport
        .send_control(&message)
        .map_or_else(|failure| verdict(&failure), |()| SLOPDESK_MUX_SEND_OK)
}

// NOR a `slopdesk_mux_transport_note_consumed`. Consumption credit is issued inside
// `PaneDriver::take_output`, against the wire byte count the driver recorded when it inboxed the
// payload — so the near side no longer has to count what the wire spent, which is the one number a
// caller could get wrong and leak the window with.

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use core::ptr;

    use super::{
        SLOPDESK_MUX_SEND_REFUSED, SlopDeskMuxPool, SlopDeskMuxTransport, slopdesk_mux_pool_channel_count,
        slopdesk_mux_pool_connection_count, slopdesk_mux_pool_free, slopdesk_mux_pool_is_alive,
        slopdesk_mux_pool_new, slopdesk_mux_pool_pin, slopdesk_mux_pool_unpin,
        slopdesk_mux_transport_await_open_ack, slopdesk_mux_transport_channel_id,
        slopdesk_mux_transport_free, slopdesk_mux_transport_open, slopdesk_mux_transport_send,
    };

    /// Every door survives a null handle, which is the shape a Swift `deinit` racing a send would
    /// produce. None of them may dial to answer.
    #[test]
    fn every_door_answers_a_null_handle_without_dialling() {
        // SAFETY: null is the documented absent handle for every one of these.
        unsafe {
            assert!(!slopdesk_mux_pool_is_alive(ptr::null(), ptr::null(), 0, 0));
            assert!(!slopdesk_mux_pool_pin(ptr::null(), ptr::null(), 0, 0));
            slopdesk_mux_pool_unpin(ptr::null(), ptr::null(), 0, 0);
            assert_eq!(slopdesk_mux_pool_channel_count(ptr::null(), ptr::null(), 0, 0), 0);
            assert_eq!(slopdesk_mux_pool_connection_count(ptr::null()), 0);
            assert_eq!(slopdesk_mux_transport_channel_id(ptr::null()), 0);
            assert!(!slopdesk_mux_transport_await_open_ack(
                ptr::null(),
                0,
                ptr::null_mut()
            ));
            assert_eq!(
                slopdesk_mux_transport_send(ptr::null(), ptr::null(), ptr::null(), 0, ptr::null(), 0),
                SLOPDESK_MUX_SEND_REFUSED,
            );
            slopdesk_mux_transport_free(ptr::null_mut());
            slopdesk_mux_pool_free(ptr::null_mut());
        }
    }

    /// An open against a port nothing listens on answers null WITHOUT running either callback, and
    /// leaves the pool with no connection in it. This is the whole failure path a client walks
    /// when a host is down, and the property that matters is the second one: a caller that gets
    /// null may free its context immediately.
    #[test]
    fn a_refused_dial_answers_null_and_pools_nothing() {
        // SAFETY: the pool is freed exactly once at the end; every span is a live local.
        unsafe {
            let pool: *mut SlopDeskMuxPool = slopdesk_mux_pool_new(50);
            assert!(!pool.is_null());
            let host = b"127.0.0.1";
            // Port 1 on loopback: privileged, unbound, and refused rather than filtered, so this
            // returns on the connect's own error rather than on the timeout.
            let transport: *mut SlopDeskMuxTransport = slopdesk_mux_transport_open(
                pool,
                host.as_ptr(),
                host.len(),
                1,
                0,
                ptr::null(),
                -1,
                ptr::null(),
                0,
                ptr::null_mut(),
                None,
                None,
            );
            assert!(transport.is_null());
            assert_eq!(slopdesk_mux_pool_connection_count(pool), 0);
            assert!(!slopdesk_mux_pool_is_alive(pool, host.as_ptr(), host.len(), 1));
            slopdesk_mux_pool_free(pool);
        }
    }

    /// A thousand pool create/free round trips. The pool owns a registry, a closure and a stash, so
    /// what this pins is that `free` reconstitutes the `Box` rather than leaking it — the one thing
    /// a `Box::into_raw` door can get wrong silently.
    #[test]
    fn a_thousand_pools_are_created_and_freed_without_drift() {
        for _ in 0..1_000_u32 {
            // SAFETY: each handle is freed exactly once, and nothing was ever dialled on it.
            unsafe {
                let pool = slopdesk_mux_pool_new(1);
                assert!(!pool.is_null());
                assert_eq!(slopdesk_mux_pool_connection_count(pool), 0);
                slopdesk_mux_pool_free(pool);
            }
        }
    }
}
