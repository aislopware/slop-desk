//! One pane's whole client session, as a handle and three callbacks.
//!
//! `docs/63` G.5. Behind it is [`slopdesk_clientdriver`] — the supervisor thread, the dedup fold,
//! the ack and ping tickers, the resume verdict and the retry campaign — which is the whole of what
//! `SlopDeskClient.swift`, `ReconnectManager.swift` and `EventBroadcaster.swift` decided between
//! them. Nothing here decides anything; this file is the calling convention and the lifetime rules,
//! per the crate header.
//!
//! ## The pool is passed in, never minted here
//!
//! [`slopdesk_pane_driver_new`] takes a [`SlopDeskMuxPool`] rather than building a registry of its
//! own. That is the property PATH-1 exists for stated at the door: every pane to one host and the
//! workspace document ride ONE mux connection, so a driver with a private pool would be a second
//! TCP pair, a second client identity at the host, and a second set of windows for the host to
//! account for. The near side creates one pool per app and hands it to every driver.
//!
//! ## Why three callbacks and not one
//!
//! [`Observer`] has two methods and this door has three, because the trait's `event` carries two
//! unlike things. [`Event::Message`] is an inbound `WireMessage` and crosses as
//! [`crate::wire_message`]'s flat record plus its arena — the same marshalling
//! [`crate::mux_transport`] already does, so a Swift face that reads one reads the other.
//! Everything else is the SESSION's own lifecycle, which is not on the wire and has no record to
//! reuse, so it crosses as [`SlopDeskPaneEvent`]. Folding the two into one callback would mean a
//! caller discriminating on a `kind` before it could know which pointer to read.
//!
//! `output_ready` is the third, and it carries nothing on purpose: it says the inbox is non-empty,
//! and the bytes are collected by [`slopdesk_pane_driver_take_output`] when the near side's
//! renderer is ready for them. Handing the bytes to the wake would make the wake the delivery, and
//! credit-at-consumption would then credit bytes nothing had rendered.
//!
//! ## Four obligations
//!
//! 1. `context` stays valid until [`slopdesk_pane_driver_free`] RETURNS — not until it is entered.
//!    `free` stops the supervisor and joins every forwarder, so a callback may still be running
//!    when it is called, and none is once it answers.
//! 2. All three callbacks may run on ANY thread, and — unlike
//!    [`slopdesk_mux_transport_open`](crate::mux_transport::slopdesk_mux_transport_open)'s pair —
//!    they MAY OVERLAP. The session's lifecycle events come from the supervisor and the messages
//!    and wakes from a forwarder, two threads with no lock between them, which is deliberate: the
//!    lock that would serialise them would sit on the inbound byte path. A callback that touches
//!    shared state must synchronise it.
//! 3. No callback may re-enter [`slopdesk_pane_driver_free`]. It joins the thread the callback is
//!    running on. Everything ELSE is allowed and cannot deadlock, because the driver detects a call
//!    made from its own supervisor and answers rather than parking — a connect from inside a
//!    callback is [`SLOPDESK_PANE_CONNECT_REENTRANT`], and a pause or a close is queued and applied
//!    on the next turn of the loop. Sends, readouts and drains are ordinary calls from anywhere.
//! 4. Every pointer in every callback is LENT for that call. A caller that keeps a message, a text
//!    or an output chunk copies it.

use core::ffi::{c_uchar, c_void};
use std::sync::Arc;
use std::time::Duration;

use slopdesk_clientdriver::event::{Event, Observer};
use slopdesk_clientdriver::{ConnectError, DriverConfig, PaneDriver, ResumeSeed};
use slopdesk_clientsession::backoff::Backoff;
use slopdesk_wire::{SESSION_ID_BYTE_COUNT, WireMessage};

use crate::mux_transport::SlopDeskMuxPool;
use crate::wire_message::{SlopDeskWireMessage, pack, unpack};
use crate::{borrow, lent};

/// A fresh smoothed round-trip reading; `round_trip_ms` carries it.
pub const SLOPDESK_PANE_EVENT_ROUND_TRIP: u32 = 0;
/// The channel ended without being asked to; the lent text is one sentence about it.
pub const SLOPDESK_PANE_EVENT_DISCONNECTED: u32 = 1;
/// A handshake completed against an EXISTING session; `session_id` and `resume_from_seq` carry it.
pub const SLOPDESK_PANE_EVENT_RECONNECTED: u32 = 2;
/// A retry campaign made an attempt, or scheduled the next; `attempt` and `delay_ms` carry it.
pub const SLOPDESK_PANE_EVENT_RETRY: u32 = 3;
/// A campaign exhausted itself; `attempt` is how many attempts it made.
pub const SLOPDESK_PANE_EVENT_GAVE_UP: u32 = 4;
/// A diagnostic line, already worded by the driver. The lent text is it.
pub const SLOPDESK_PANE_EVENT_LOG: u32 = 5;

/// The connect landed and the session is live.
pub const SLOPDESK_PANE_CONNECT_OK: i32 = 0;
/// A terminal state refused it — closed, or the child exited. Permanent for this driver.
pub const SLOPDESK_PANE_CONNECT_REFUSED: i32 = 1;
/// A resume before anything was ever connected. There is no endpoint to resume to.
pub const SLOPDESK_PANE_CONNECT_NO_ENDPOINT: i32 = 2;
/// The channel could not be opened: the dial failed, or the pool refused. Retryable.
pub const SLOPDESK_PANE_CONNECT_OPEN: i32 = 3;
/// The host gave no verdict — refused, died, or said nothing inside the bound. Retryable.
pub const SLOPDESK_PANE_CONNECT_NO_VERDICT: i32 = 4;
/// A close or a pause landed while the dial was in flight. NOT a failure: stop, do not retry.
pub const SLOPDESK_PANE_CONNECT_SUPERSEDED: i32 = 5;
/// The driver is being freed, or the handle was null. Nothing was dialled.
pub const SLOPDESK_PANE_CONNECT_GONE: i32 = 6;
/// Called from inside a callback the supervisor is running. The CALLER's bug, named rather than
/// hung: see obligation 3.
pub const SLOPDESK_PANE_CONNECT_REENTRANT: i32 = 7;

/// The send went out.
pub const SLOPDESK_PANE_SEND_OK: i32 = 0;
/// Nothing is connected, or the session is finished. Not retryable on this transport.
pub const SLOPDESK_PANE_SEND_CLOSED: i32 = 1;
/// The write failed on the link, which is dying.
pub const SLOPDESK_PANE_SEND_LINK: i32 = 2;
/// A null handle, or a record this door cannot use. Nothing was sent.
pub const SLOPDESK_PANE_SEND_REFUSED: i32 = 3;

/// One inbound message, lent for the duration of the call.
///
/// Its own typedef rather than [`crate::mux_transport`]'s, though the shape is identical: the two
/// doors have separate lifetimes and one of them is a stage away from retiring, and a shared alias
/// would make the survivor's header depend on the other's existence.
///
/// `arena` is [`crate::wire_message`]'s text arena and `blob` is the opaque run — separate pointers
/// because they are separate address spaces. The record's own `blob_offset` is always 0 here; read
/// the run through `blob`.
pub type SlopDeskPaneMessageFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        message: *const SlopDeskWireMessage,
        arena: *const c_uchar,
        arena_len: usize,
        blob: *const c_uchar,
        blob_len: usize,
    ),
>;

/// One session-lifecycle event, lent for the duration of the call.
///
/// `text` carries a sentence for [`SLOPDESK_PANE_EVENT_DISCONNECTED`] and
/// [`SLOPDESK_PANE_EVENT_LOG`]; `text_len` is 0 for every other kind, and the pointer is then a
/// dangling non-null Rust reads as an empty string. Check the LENGTH, never the pointer.
pub type SlopDeskPaneEventFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        event: *const SlopDeskPaneEvent,
        text: *const c_uchar,
        text_len: usize,
    ),
>;

/// The output inbox has bytes waiting. Carries nothing; see the module header.
///
/// LEVEL-triggered, not edge: it fires once per ACCEPTED `output`, so a burst of ten produces ten
/// calls whether or not the near side drained between them. The coalescing belongs to the near side
/// — a one-slot wake whose pending value is replaced rather than queued — because only that side
/// can see whether a consumer is parked, and a driver that guessed would either drop the wake that
/// mattered or hold bytes nobody was coming for.
pub type SlopDeskPaneWakeFn = Option<unsafe extern "C" fn(context: *mut c_void)>;

/// One output payload, lent for the duration of the call.
pub type SlopDeskPaneChunkFn =
    Option<unsafe extern "C" fn(context: *mut c_void, bytes: *const c_uchar, len: usize)>;

/// One session-lifecycle event, flattened.
///
/// Every field but `kind` belongs to exactly one kind and is zero for the rest. `attempt` serves
/// both [`SLOPDESK_PANE_EVENT_RETRY`] and [`SLOPDESK_PANE_EVENT_GAVE_UP`] because it is the same
/// counter in both — the attempt a campaign is on, and the attempt it stopped at.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskPaneEvent {
    /// One of the `SLOPDESK_PANE_EVENT_*` constants.
    pub kind: u32,
    /// The 1-based attempt, for a retry or a give-up.
    pub attempt: u32,
    /// The wait before the next attempt, or 0 for "now".
    pub delay_ms: u64,
    /// The smoothed application-layer round trip.
    pub round_trip_ms: f64,
    /// The session the host acknowledged, for a reconnect.
    pub session_id: [c_uchar; SESSION_ID_BYTE_COUNT],
    /// The host-authoritative seq a reconnect resumes from. 0 is a fresh shell.
    pub resume_from_seq: i64,
}

/// How one driver is configured, fixed for its life.
///
/// The two OPTIONAL parts of [`DriverConfig`] each cross as a value plus its own absence flag
/// rather than as a sentinel, because both have a legal zero: a backoff of zero nanoseconds is a
/// legal schedule, and a resume seed of `last_seq == 0` is exactly what a cold launch presents.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskPaneConfig {
    /// The raw `channelOpen` class byte. Fixed for the driver's life.
    pub channel_class: c_uchar,
    /// Whether a retry campaign follows a drop at all. False is "announce it and stop".
    pub reconnects: bool,
    /// Whether `resume_session_id` and `resume_last_seq` name a pane to restore.
    pub has_resume_seed: bool,
    /// How often the coalesced ack ticker may flush.
    pub ack_interval_ms: u64,
    /// How often a round-trip probe goes out.
    pub ping_interval_ms: u64,
    /// The wait before the first retry, in nanoseconds.
    pub retry_initial_ns: u64,
    /// The ceiling on that wait, in nanoseconds.
    pub retry_maximum_ns: u64,
    /// What each retry step multiplies the wait by.
    pub retry_multiplier: f64,
    /// The session id a restored pane presents.
    pub resume_session_id: [c_uchar; SESSION_ID_BYTE_COUNT],
    /// The highest seq that pane had rendered. A cold launch presents 0 deliberately.
    pub resume_last_seq: i64,
}

/// The caller's opaque context pointer, carried to all three callbacks.
///
/// A newtype for [`crate::decoder`]'s reason: a bare `*mut c_void` is neither `Send` nor `Sync`,
/// and the promise that makes it both is the CALLER's, stated at [`slopdesk_pane_driver_new`].
#[derive(Clone, Copy, Debug)]
struct CallerContext(*mut c_void);

// SAFETY: the caller of `slopdesk_pane_driver_new` promises this pointer is valid until
// `slopdesk_pane_driver_free` returns and usable from any thread. The supervisor and both
// forwarders hand it back through the function pointers below, and none of them ever dereferences
// it here.
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

/// The three C function pointers, expressed as the observer the driver takes.
#[derive(Debug)]
struct CObserver {
    context: CallerContext,
    message: SlopDeskPaneMessageFn,
    event: SlopDeskPaneEventFn,
    wake: SlopDeskPaneWakeFn,
}

impl CObserver {
    /// Hands one flattened event over, with whatever text it lends.
    ///
    /// # Safety
    /// `flat` and `text` are locals of this frame and the caller's, so both outlive the call, which
    /// is the door's lend-for-the-call term.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn deliver(&self, flat: &SlopDeskPaneEvent, text: &str) {
        let Some(deliver) = self.event else {
            return;
        };
        // SAFETY: the context is live by the door's documented term, and both spans outlive the
        // call — `flat` is the caller's local and `text` borrows a string it owns.
        unsafe {
            deliver(
                self.context.0,
                core::ptr::from_ref(flat),
                text.as_ptr(),
                text.len(),
            );
        }
    }
}

impl Observer for CObserver {
    /// # Safety
    /// Every pointer handed over names memory owned by this frame or by the event being reported,
    /// so all of it is live for the whole call and dead after it.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn event(&self, event: &Event<'_>) {
        // The message arm is the OTHER callback: it carries a wire record and an arena, and folding
        // it into the flat lifecycle event would make the caller discriminate before it could know
        // which pointer to read. See the module header.
        if let Event::Message(message) = *event {
            let Some(deliver) = self.message else {
                return;
            };
            let run = message.opaque_run();
            // `0..run.len()`, because the message owns its bytes: there is no datagram left for
            // `blob_offset` to index. The same convention `mux_transport` and `frame_decoder` use.
            let packed = pack(message, &(0..run.len()));
            // SAFETY: the context is live by the door's documented term, and all three spans are
            // locals of this frame.
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
            return;
        }
        let mut flat = SlopDeskPaneEvent::default();
        let text = match *event {
            Event::RoundTrip(reading) => {
                flat.kind = SLOPDESK_PANE_EVENT_ROUND_TRIP;
                flat.round_trip_ms = reading;
                ""
            },
            Event::Disconnected { reason } => {
                flat.kind = SLOPDESK_PANE_EVENT_DISCONNECTED;
                reason
            },
            Event::Reconnected {
                session_id,
                resume_from_seq,
            } => {
                flat.kind = SLOPDESK_PANE_EVENT_RECONNECTED;
                flat.session_id = session_id;
                flat.resume_from_seq = resume_from_seq;
                ""
            },
            Event::Retry { attempt, delay_ms } => {
                flat.kind = SLOPDESK_PANE_EVENT_RETRY;
                flat.attempt = attempt;
                flat.delay_ms = delay_ms;
                ""
            },
            Event::GaveUp { attempts } => {
                flat.kind = SLOPDESK_PANE_EVENT_GAVE_UP;
                flat.attempt = attempts;
                ""
            },
            Event::Log(line) => {
                flat.kind = SLOPDESK_PANE_EVENT_LOG;
                line
            },
            // `Event` is `#[non_exhaustive]`, and a kind this build cannot name is dropped rather
            // than delivered as a zero: a caller that read it would act on a round trip of 0 ms.
            _ => return,
        };
        self.deliver(&flat, text);
    }

    /// # Safety
    /// Nothing crosses but the context, which is live by the door's documented term.
    #[expect(
        unsafe_code,
        reason = "calling the caller's function pointer IS this module's boundary"
    )]
    fn output_ready(&self) {
        let Some(wake) = self.wake else {
            return;
        };
        // SAFETY: the context is live by the door's documented term.
        unsafe {
            wake(self.context.0);
        }
    }
}

/// One pane's client session.
#[derive(Debug)]
pub struct SlopDeskPaneDriver {
    driver: PaneDriver,
}

/// Reconstitutes a driver handle for the duration of a call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_pane_driver_new`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskPaneDriver) -> Option<&'a SlopDeskPaneDriver> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and `PaneDriver` is `Sync`, so a
    // concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// How a [`ConnectError`] reaches the near side.
const fn verdict(error: &ConnectError) -> i32 {
    match *error {
        ConnectError::Refused(_) => SLOPDESK_PANE_CONNECT_REFUSED,
        ConnectError::NoEndpoint => SLOPDESK_PANE_CONNECT_NO_ENDPOINT,
        ConnectError::Open(_) => SLOPDESK_PANE_CONNECT_OPEN,
        ConnectError::NoVerdict => SLOPDESK_PANE_CONNECT_NO_VERDICT,
        ConnectError::Superseded => SLOPDESK_PANE_CONNECT_SUPERSEDED,
        ConnectError::Gone => SLOPDESK_PANE_CONNECT_GONE,
        ConnectError::Reentrant => SLOPDESK_PANE_CONNECT_REENTRANT,
    }
}

/// Writes what a [`ConnectError`] SAYS into the caller's buffer, and how much it wrote.
///
/// The code says which of seven things happened; this says which host refused, which dial failed
/// and why. Only [`ConnectError::Open`] and [`ConnectError::Refused`] carry a payload the code
/// cannot reconstruct, but every arm spills, because a near side that has to know which codes are
/// worth reading is a near side that will read the wrong one after the next arm is added.
///
/// TRUNCATED rather than retried when the buffer is short, unlike
/// `slopdesk_pane_session_refusal_reason`, and the difference is what the two answers are FOR: that
/// one is the sentence a refusal throws, this one is a diagnostic beside a code that already
/// carries the decision. A clipped sentence still names the host; a second call to learn a length
/// would be a round trip for the tail of a log line. The cut lands on a `char` boundary, so what
/// arrives is always UTF-8.
///
/// # Safety
/// `(reason, reason_cap)` must be null-with-zero-capacity or a live writable buffer, and
/// `reason_len` must be null or a live `usize`, both for the duration of the call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer IS the boundary this module documents"
)]
unsafe fn spill(error: &ConnectError, reason: *mut c_uchar, reason_cap: usize, reason_len: *mut usize) {
    let mut said = error.to_string();
    if said.len() > reason_cap {
        // `floor_char_boundary` is not stable, so walk back from the cap by hand.
        let mut cut = reason_cap;
        while cut > 0 && !said.is_char_boundary(cut) {
            cut -= 1;
        }
        said.truncate(cut);
    }
    if !reason.is_null() && !said.is_empty() {
        // SAFETY: `said.len() <= reason_cap` after the truncation above, and the caller's
        // obligation makes that many bytes writable. A `String`'s buffer cannot overlap the
        // caller's.
        unsafe { core::ptr::copy_nonoverlapping(said.as_ptr(), reason, said.len()) };
    }
    if !reason_len.is_null() {
        // SAFETY: non-null and, by the caller's obligation, a live `usize`.
        unsafe { reason_len.write(said.len()) };
    }
}

/// How a send failure reaches the near side.
const fn sent(error: &slopdesk_muxnet::subchannel::SendError) -> i32 {
    match *error {
        slopdesk_muxnet::subchannel::SendError::Closed => SLOPDESK_PANE_SEND_CLOSED,
        slopdesk_muxnet::subchannel::SendError::Link(_) => SLOPDESK_PANE_SEND_LINK,
    }
}

/// Starts a driver on `pool`. It dials nothing until [`slopdesk_pane_driver_connect`] asks it to.
///
/// The supervisor thread starts here, so the callbacks may begin the moment this returns — but not
/// before, and none of them can run for a session that has not connected. Answers null if the
/// thread could not be spawned or `pool` was null; on null, no callback has run or ever will, and
/// `context` may be freed at once.
///
/// # Safety
/// `pool` must be null or a live [`SlopDeskMuxPool`], which must outlive this driver. `context`
/// must stay valid and usable from any thread until [`slopdesk_pane_driver_free`] returns. `config`
/// must point at one live struct for the duration of THIS call; nothing in it is retained by
/// reference. The answer must be passed to [`slopdesk_pane_driver_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_new(
    pool: *const SlopDeskMuxPool,
    config: *const SlopDeskPaneConfig,
    context: *mut c_void,
    on_message: SlopDeskPaneMessageFn,
    on_event: SlopDeskPaneEventFn,
    on_wake: SlopDeskPaneWakeFn,
) -> *mut SlopDeskPaneDriver {
    if pool.is_null() || config.is_null() {
        return core::ptr::null_mut();
    }
    // SAFETY: both are non-null and, by the caller's obligations, live for this call.
    let (held, asked) = unsafe { (&*pool, &*config) };
    let settings = DriverConfig {
        channel_class: asked.channel_class,
        ack_interval: Duration::from_millis(asked.ack_interval_ms),
        ping_interval: Duration::from_millis(asked.ping_interval_ms),
        reconnect: asked.reconnects.then_some(Backoff {
            initial_ns: asked.retry_initial_ns,
            maximum_ns: asked.retry_maximum_ns,
            multiplier: asked.retry_multiplier,
        }),
        resume_seed: asked.has_resume_seed.then_some(ResumeSeed {
            session_id: asked.resume_session_id,
            last_seq: asked.resume_last_seq,
        }),
    };
    let observer = Arc::new(CObserver {
        context: CallerContext(context),
        message: on_message,
        event: on_event,
        wake: on_wake,
    });
    PaneDriver::new(Arc::clone(held.pool.registry()), observer, settings).map_or_else(
        |_unspawned| core::ptr::null_mut(),
        |driver| Box::into_raw(Box::new(SlopDeskPaneDriver { driver })),
    )
}

/// Retires the session, stops the supervisor, joins every forwarder, and frees the handle.
///
/// `context` may be freed as soon as this RETURNS, and not before: it joins the threads that run
/// the callbacks, so one may still be running when it is entered.
///
/// Does NOT close the session on the host — that is [`slopdesk_pane_driver_close`], and the
/// difference is the whole detach story: a freed driver leaves the host's shell and its replay
/// buffer standing, which is what a client that is going away and coming back needs.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_pane_driver_new`] that has not already been
/// freed, and no other call on it may be in flight. Never call it from inside a callback: it joins
/// the thread the callback is running on.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_driver_free(handle: *mut SlopDeskPaneDriver) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live pointer from `new` with no call in
    // flight — so this reconstitutes the unique owner. Dropping it is what stops and joins.
    drop(unsafe { Box::from_raw(handle) });
}

/// Provides the cwd a FRESH host shell should start in, for this and every later connection.
///
/// Null-with-zero-length clears it. A host-side reattach ignores it — the live shell's cwd is
/// preserved — so only a respawn reads it.
///
/// # Safety
/// [`held`]'s, plus `(cwd, cwd_len)` must be null-with-zero-length or live UTF-8 for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_driver_set_initial_cwd(
    handle: *const SlopDeskPaneDriver,
    cwd: *const c_uchar,
    cwd_len: usize,
) {
    // SAFETY: the caller's obligations, above.
    let (Some(driver), cwd) = (unsafe { (held(handle), lent(cwd, cwd_len)) }) else {
        return;
    };
    driver.driver.set_initial_cwd((!cwd.is_empty()).then_some(cwd));
}

/// Connects to `host:port`, or reconnects presenting the session this driver already holds.
///
/// BLOCKS until the dial and the handshake resolve, bounded by `handshake_timeout_ms`, and answers
/// one of the `SLOPDESK_PANE_CONNECT_*` constants. Each is a different thing for the caller to do —
/// a refusal is permanent, a supersede means stop, a reentrant is the caller's own bug, and the
/// rest are worth retrying. What went wrong in WORDS lands in `(reason, reason_cap)`; see
/// [`spill`].
///
/// # Safety
/// [`held`]'s, plus `(host, host_len)` must be null-with-zero-length or live UTF-8 for the call,
/// and [`spill`]'s for the three reason parameters.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_connect(
    handle: *const SlopDeskPaneDriver,
    host: *const c_uchar,
    host_len: usize,
    port: u16,
    handshake_timeout_ms: u64,
    reason: *mut c_uchar,
    reason_cap: usize,
    reason_len: *mut usize,
) -> i32 {
    // SAFETY: the caller's obligations, above.
    let (Some(driver), host) = (unsafe { (held(handle), lent(host, host_len)) }) else {
        return SLOPDESK_PANE_CONNECT_GONE;
    };
    match driver
        .driver
        .connect(host, port, Duration::from_millis(handshake_timeout_ms))
    {
        Ok(()) => SLOPDESK_PANE_CONNECT_OK,
        Err(failure) => {
            // SAFETY: the caller's obligation for the three reason parameters, above.
            unsafe { spill(&failure, reason, reason_cap, reason_len) };
            verdict(&failure)
        },
    }
}

/// Backgrounded: acks what is held, says a clean `bye` and tears the transport down.
///
/// The host keeps the shell and its replay buffer, so output produced while paused is retained.
/// Idempotent. Returns once the pause has landed, or once it is QUEUED when called from inside a
/// callback — see obligation 3.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_driver_pause(handle: *const SlopDeskPaneDriver) {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return;
    };
    driver.driver.pause();
}

/// Foregrounded: reconnects with the preserved session id and seq. A no-op unless paused.
///
/// As [`slopdesk_pane_driver_connect`], plus [`SLOPDESK_PANE_CONNECT_NO_ENDPOINT`] if nothing was
/// ever connected.
///
/// # Safety
/// [`held`]'s, plus [`spill`]'s for the three reason parameters.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_resume(
    handle: *const SlopDeskPaneDriver,
    handshake_timeout_ms: u64,
    reason: *mut c_uchar,
    reason_cap: usize,
    reason_len: *mut usize,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return SLOPDESK_PANE_CONNECT_GONE;
    };
    match driver.driver.resume(Duration::from_millis(handshake_timeout_ms)) {
        Ok(()) => SLOPDESK_PANE_CONNECT_OK,
        Err(failure) => {
            // SAFETY: the caller's obligation for the three reason parameters, above.
            unsafe { spill(&failure, reason, reason_cap, reason_len) };
            verdict(&failure)
        },
    }
}

/// Permanently retires the session: a final ack, a clean `bye`, and a teardown. Idempotent, and
/// queued rather than awaited when called from inside a callback, as
/// [`slopdesk_pane_driver_pause`] is.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_driver_close(handle: *const SlopDeskPaneDriver) {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return;
    };
    driver.driver.close();
}

/// Sends PTY input on the DATA lane, split across frames at the flow-control cap.
///
/// BLOCKS while the credit window is empty, which is the backpressure: a paste larger than the
/// window parks this thread until the host consumes, rather than buffering unboundedly on the
/// client. A caller feeding it from a keyboard never notices; one feeding it from a pipe wants
/// exactly this.
///
/// # Safety
/// [`held`]'s, plus `(bytes, len)` must be null-with-zero-length or live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_send_input(
    handle: *const SlopDeskPaneDriver,
    bytes: *const c_uchar,
    len: usize,
) -> i32 {
    // SAFETY: the caller's obligations, above.
    let (Some(driver), bytes) = (unsafe { (held(handle), borrow(bytes, len)) }) else {
        return SLOPDESK_PANE_SEND_REFUSED;
    };
    driver
        .driver
        .send_input(bytes)
        .map_or_else(|failure| sent(&failure), |()| SLOPDESK_PANE_SEND_OK)
}

/// Sends a resize, REMEMBERING it so every later connection re-asserts it.
///
/// The remembering happens even when the send fails, which is the point: a resize that could not go
/// out is exactly the one the next connection must assert.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_send_resize(
    handle: *const SlopDeskPaneDriver,
    cols: u16,
    rows: u16,
    px_width: u16,
    px_height: u16,
) -> i32 {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return SLOPDESK_PANE_SEND_REFUSED;
    };
    driver
        .driver
        .send_resize(cols, rows, px_width, px_height)
        .map_or_else(|failure| sent(&failure), |()| SLOPDESK_PANE_SEND_OK)
}

/// Sends one message on the CONTROL lane.
///
/// Verb-agnostic, for
/// [`slopdesk_mux_transport_send`](crate::mux_transport::slopdesk_mux_transport_send)'s
/// reason: `requestBlockOutput`, a metadata request and a workspace request differ only in the
/// value they carry. REFUSES an `input` — CONTROL is unwindowed, and a paste on it would put a 16
/// MiB frame on the lane a `Ctrl-C` needs. [`slopdesk_pane_driver_send_input`] is the door for
/// that.
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
pub unsafe extern "C" fn slopdesk_pane_driver_send_control(
    handle: *const SlopDeskPaneDriver,
    message: *const SlopDeskWireMessage,
    arena: *const c_uchar,
    arena_len: usize,
    blob: *const c_uchar,
    blob_len: usize,
) -> i32 {
    if message.is_null() {
        return SLOPDESK_PANE_SEND_REFUSED;
    }
    // SAFETY: the caller's obligations, above — one struct read and two borrows, none outliving the
    // call.
    let (Some(driver), flat, arena, blob) = (unsafe {
        (
            held(handle),
            &*message,
            borrow(arena, arena_len),
            borrow(blob, blob_len),
        )
    }) else {
        return SLOPDESK_PANE_SEND_REFUSED;
    };
    let Some(message) = unpack(flat, arena, blob) else {
        return SLOPDESK_PANE_SEND_REFUSED;
    };
    if matches!(message, WireMessage::Input(_)) {
        return SLOPDESK_PANE_SEND_REFUSED;
    }
    driver
        .driver
        .send_control(&message)
        .map_or_else(|failure| sent(&failure), |()| SLOPDESK_PANE_SEND_OK)
}

/// Flushes a pending ack NOW rather than at the next tick.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_driver_flush_ack(handle: *const SlopDeskPaneDriver) {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return;
    };
    driver.driver.flush_ack();
}

/// Takes the whole pending output backlog, in order, and credits its wire bytes back to the host.
///
/// `on_chunk` is called once per payload, with a borrow that ends when it returns. Answers how many
/// payloads were handed over; a null `on_chunk` still DRAINS and still credits, which is the door a
/// caller that is shutting down wants.
///
/// Credit is issued at CONSUMPTION — "taken" means the near side is about to render them — so the
/// un-rendered bytes a client holds stay bounded, and the host's PTY-pause backpressure engages
/// against a slow client rather than against a slow renderer.
///
/// # Safety
/// [`held`]'s, plus `on_chunk` must be a valid function pointer or null, and `context` is the
/// caller's, live for the duration of this call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_take_output(
    handle: *const SlopDeskPaneDriver,
    context: *mut c_void,
    on_chunk: SlopDeskPaneChunkFn,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return 0;
    };
    driver.driver.take_output(|chunk| {
        let Some(deliver) = on_chunk else {
            return;
        };
        // SAFETY: `chunk` is lent by the drain for the duration of this closure, and `context` is
        // live for the duration of the call this closure runs inside.
        unsafe {
            deliver(context, chunk.as_ptr(), chunk.len());
        }
    })
}

/// Writes the session id the host acknowledged into `out` — 16 bytes — and answers whether there
/// was one. Answers false before the first handshake, leaving `out` untouched.
///
/// # Safety
/// [`held`]'s, plus `out` must be null or 16 writable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_session_id(
    handle: *const SlopDeskPaneDriver,
    out: *mut c_uchar,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(session_id) = driver.driver.session_id() else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    // SAFETY: non-null and, by the caller's obligation, 16 writable bytes — which is exactly the
    // length of the source, and the two cannot overlap because the source is a local copy.
    unsafe {
        core::ptr::copy_nonoverlapping(session_id.as_ptr(), out, SESSION_ID_BYTE_COUNT);
    }
    true
}

/// The highest CONTIGUOUS output seq delivered — what is acked, and what the next open presents.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_highest_contiguous_seq(
    handle: *const SlopDeskPaneDriver,
) -> i64 {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return 0;
    };
    driver.driver.highest_contiguous_seq()
}

/// Whether the CURRENT connection reattached the same shell or got a fresh one, as
/// [`ResumeOutcome::code`](slopdesk_clientsession::seq::ResumeOutcome::code)'s byte.
///
/// It gates a surface WIPE, so the undetermined answer is the one a caller must not read as
/// "fresh": a pane whose stream has produced nothing yet has established nothing.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_resume_outcome(handle: *const SlopDeskPaneDriver) -> c_uchar {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return 0;
    };
    driver.driver.resume_outcome().code()
}

/// Writes the smoothed application-layer round trip in milliseconds into `out`, answering whether
/// there has been a reading. False before the first pong, leaving `out` untouched.
///
/// # Safety
/// [`held`]'s, plus `out` must be null or writable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_smoothed_rtt_ms(
    handle: *const SlopDeskPaneDriver,
    out: *mut f64,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(reading) = driver.driver.smoothed_rtt_ms() else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable.
        unsafe { *out = reading };
    }
    true
}

// NOTE: there is no `slopdesk_pane_driver_is_connected`. "Is a transport adopted" is not a question
// the near side can act on: it is true for an instant between a dial and the drop that follows it,
// and the two facts a caller actually branches on — paused and closed — are their own doors below.
// The face reports connectedness from the EVENTS instead, which is the only spelling that cannot be
// read after it stopped being true.

/// Backgrounded by [`slopdesk_pane_driver_pause`].
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_is_paused(handle: *const SlopDeskPaneDriver) -> bool {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle) }.is_some_and(|driver| driver.driver.is_paused())
}

/// Permanently retired by [`slopdesk_pane_driver_close`]. A null handle reads as CLOSED, which is
/// the safe reading: a caller holding nothing has nothing live.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_is_closed(handle: *const SlopDeskPaneDriver) -> bool {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle) }.is_none_or(|driver| driver.driver.is_closed())
}

/// The remote child exited. Terminal: a later connect is refused.
///
/// # Safety
/// [`held`]'s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_is_exited(handle: *const SlopDeskPaneDriver) -> bool {
    // SAFETY: the caller's obligation, above.
    unsafe { held(handle) }.is_some_and(|driver| driver.driver.is_exited())
}

/// Writes the raw reason the HOST closed this pane's channel into `out`, answering whether it did.
///
/// The gate above this driver asks only WHETHER, but the reason decides what the layer above may
/// build next: `Retired` says the pane is gone, `SubscriberEvicted` says only this attachment was.
///
/// # Safety
/// [`held`]'s, plus `out` must be null or writable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub unsafe extern "C" fn slopdesk_pane_driver_host_close_reason(
    handle: *const SlopDeskPaneDriver,
    out: *mut c_uchar,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(driver) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(reason) = driver.driver.host_close_reason() else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable.
        unsafe { *out = reason.as_byte() };
    }
    true
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use core::ptr;

    use super::{
        ConnectError, SLOPDESK_PANE_CONNECT_GONE, SLOPDESK_PANE_SEND_REFUSED, SlopDeskPaneConfig,
        slopdesk_pane_driver_close, slopdesk_pane_driver_connect, slopdesk_pane_driver_flush_ack,
        slopdesk_pane_driver_free, slopdesk_pane_driver_highest_contiguous_seq,
        slopdesk_pane_driver_host_close_reason, slopdesk_pane_driver_is_closed,
        slopdesk_pane_driver_is_exited, slopdesk_pane_driver_is_paused, slopdesk_pane_driver_new,
        slopdesk_pane_driver_pause, slopdesk_pane_driver_resume, slopdesk_pane_driver_resume_outcome,
        slopdesk_pane_driver_send_control, slopdesk_pane_driver_send_input, slopdesk_pane_driver_send_resize,
        slopdesk_pane_driver_session_id, slopdesk_pane_driver_set_initial_cwd,
        slopdesk_pane_driver_smoothed_rtt_ms, slopdesk_pane_driver_take_output, spill,
    };
    use crate::mux_transport::{slopdesk_mux_pool_free, slopdesk_mux_pool_new};

    /// Every door survives a null handle, which is the shape a Swift `deinit` racing a send
    /// produces. None of them may dial to answer it.
    ///
    /// `is_closed` is the one that answers TRUE, and deliberately: a caller holding nothing holds
    /// nothing live, and the reading that would let it send is the wrong one.
    #[test]
    fn every_door_answers_a_null_handle_without_dialling() {
        // SAFETY: null is the documented absent handle for every one of these.
        unsafe {
            assert!(
                slopdesk_pane_driver_new(ptr::null(), ptr::null(), ptr::null_mut(), None, None, None)
                    .is_null()
            );
            slopdesk_pane_driver_set_initial_cwd(ptr::null(), ptr::null(), 0);
            assert_eq!(
                slopdesk_pane_driver_connect(
                    ptr::null(),
                    ptr::null(),
                    0,
                    0,
                    0,
                    ptr::null_mut(),
                    0,
                    ptr::null_mut(),
                ),
                SLOPDESK_PANE_CONNECT_GONE,
            );
            assert_eq!(
                slopdesk_pane_driver_resume(ptr::null(), 0, ptr::null_mut(), 0, ptr::null_mut()),
                SLOPDESK_PANE_CONNECT_GONE
            );
            slopdesk_pane_driver_pause(ptr::null());
            slopdesk_pane_driver_close(ptr::null());
            assert_eq!(
                slopdesk_pane_driver_send_input(ptr::null(), ptr::null(), 0),
                SLOPDESK_PANE_SEND_REFUSED,
            );
            assert_eq!(
                slopdesk_pane_driver_send_resize(ptr::null(), 80, 24, 0, 0),
                SLOPDESK_PANE_SEND_REFUSED,
            );
            assert_eq!(
                slopdesk_pane_driver_send_control(ptr::null(), ptr::null(), ptr::null(), 0, ptr::null(), 0),
                SLOPDESK_PANE_SEND_REFUSED,
            );
            slopdesk_pane_driver_flush_ack(ptr::null());
            assert_eq!(
                slopdesk_pane_driver_take_output(ptr::null(), ptr::null_mut(), None),
                0
            );
            assert!(!slopdesk_pane_driver_session_id(ptr::null(), ptr::null_mut()));
            assert_eq!(slopdesk_pane_driver_highest_contiguous_seq(ptr::null()), 0);
            assert_eq!(slopdesk_pane_driver_resume_outcome(ptr::null()), 0);
            assert!(!slopdesk_pane_driver_smoothed_rtt_ms(
                ptr::null(),
                ptr::null_mut()
            ));
            assert!(!slopdesk_pane_driver_is_paused(ptr::null()));
            assert!(slopdesk_pane_driver_is_closed(ptr::null()));
            assert!(!slopdesk_pane_driver_is_exited(ptr::null()));
            assert!(!slopdesk_pane_driver_host_close_reason(
                ptr::null(),
                ptr::null_mut()
            ));
            slopdesk_pane_driver_free(ptr::null_mut());
        }
    }

    /// A thousand driver round trips on ONE pool, none of them dialling.
    ///
    /// Each `new` starts a supervisor thread and each `free` must stop and JOIN it. A door that
    /// merely abandoned the thread would pass every functional test above and then exhaust the
    /// process after a few hundred panes, which is a length of session a real client reaches.
    #[test]
    fn a_thousand_drivers_are_started_and_stopped_without_drift() {
        let config = SlopDeskPaneConfig {
            ack_interval_ms: 50,
            ping_interval_ms: 3_600_000,
            ..SlopDeskPaneConfig::default()
        };
        // SAFETY: the pool outlives every driver on it and is freed once at the end; each driver is
        // freed exactly once, and nothing was ever dialled.
        unsafe {
            let pool = slopdesk_mux_pool_new(50);
            assert!(!pool.is_null());
            for _ in 0..1_000_u32 {
                let driver =
                    slopdesk_pane_driver_new(pool, &raw const config, ptr::null_mut(), None, None, None);
                assert!(!driver.is_null());
                assert!(!slopdesk_pane_driver_is_closed(driver));
                slopdesk_pane_driver_free(driver);
            }
            slopdesk_mux_pool_free(pool);
        }
    }

    /// The reason a refusal spills, at every buffer size including the ones that cut it.
    ///
    /// The cut is the point: the near side decodes these bytes as UTF-8, and a cap that landed
    /// mid-scalar would hand it a replacement character or, in a stricter decoder, nothing at all —
    /// from a path that only runs when something has ALREADY gone wrong, which is the worst place
    /// to lose the sentence. Every arm's sentence is ASCII TODAY, so what this pins is the
    /// walk-back itself: [`ConnectError::Open`] wraps an OS error whose text is the platform's, and
    /// a host name or a path in it is where the first non-ASCII byte will arrive.
    #[test]
    fn a_reason_is_cut_on_a_boundary_or_not_at_all() {
        let failure = ConnectError::NoVerdict;
        let whole = failure.to_string();
        for cap in 0..=whole.len() + 8 {
            let mut buffer = vec![0_u8; whole.len() + 8];
            let mut written = usize::MAX;
            // SAFETY: the buffer outlives the call and is at least `cap` long for every `cap` here.
            unsafe { spill(&failure, buffer.as_mut_ptr(), cap, &raw mut written) };
            assert!(written <= cap, "spilled {written} into {cap}");
            let (filled, untouched) = buffer.split_at(written);
            // `unwrap_or_default` and then the LENGTH, rather than an unwrap: an invalid cut yields
            // the empty string, which the assertion names as the boundary failure it is.
            let said = core::str::from_utf8(filled).unwrap_or_default();
            assert_eq!(said.len(), written, "the cut at {cap} fell off a char boundary");
            assert!(whole.starts_with(said), "{said:?} is not a prefix of {whole:?}");
            // Nothing past what was written may have been touched.
            assert!(untouched.iter().all(|&byte| byte == 0));
        }
    }

    /// A null buffer is not an error, and it still answers the length it would have written.
    ///
    /// Zero, not the whole sentence's length: `reason_len` is what ARRIVED, so a caller that
    /// passed no buffer reads 0 and a caller that passed a short one reads the truncation. The
    /// alternative — the length it WOULD have taken — is the two-call convention this door
    /// deliberately does not use, and mixing the two is how a caller reads past its own buffer.
    #[test]
    fn a_null_reason_buffer_answers_nothing_rather_than_faulting() {
        let mut written = usize::MAX;
        // SAFETY: a null buffer with a zero capacity is the documented absent buffer.
        unsafe { spill(&ConnectError::Gone, ptr::null_mut(), 0, &raw mut written) };
        assert_eq!(written, 0);
        // SAFETY: a null `reason_len` is likewise documented, and must not be written.
        unsafe { spill(&ConnectError::Gone, ptr::null_mut(), 0, ptr::null_mut()) };
    }
}
