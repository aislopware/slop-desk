//! The client mux's pool and the two loop policies both ends of the wire were spelling twice.
//!
//! `rust/slopdesk-video`'s `mux_client_pool` and `mux_flow` own all of it. This is the door.
//!
//! ## Why the pool is a handle and the policies are calls
//! §4b's test is whether the far side reads the part that is big. The pool holds a lane set per
//! endpoint and an allocator, and the near side asks it one id at a time — never the whole map — so
//! it is a handle. The re-arm decision, the backoff and the send-path mapping are pure questions
//! about one integer, so they cross as calls with nothing to own.
//!
//! ## Why the loop policies live HERE and not once per side
//! The receive loop's re-arm rule was written out twice in Swift, once in the host module and once
//! in the client's, with a comment on each copy saying the other exists — a contract kept by
//! reading rather than by the compiler. There is one rule; a datagram loop is a datagram loop. Both
//! sides now call this, so the agreement is the artifact.
//!
//! ## The flow objects stay on the near side
//! A flow is an `NWConnection`, which this crate cannot hold and does not want to. The pool keys
//! endpoints by their three parts and answers whether the caller must BUILD a flow, join one, or
//! close one — the object that answer is about lives where objects live.

use slopdesk_video::mux_client_pool::{
    AcquireOutcome, FlowEndpoint, ReleaseOutcome, VideoFlowPool, request_send_offsets,
};
use slopdesk_video::mux_flow::{ConnectionStateKind, receive_backoff, should_rearm};

use crate::borrow;

/// No such endpoint, or no such lane on it: nothing to unregister and nothing to close.
pub const SLOPDESK_LANE_UNKNOWN: u32 = 0;
/// The lane's sinks come off and the shared flow stays up for its siblings.
pub const SLOPDESK_LANE_REMOVED: u32 = 1;
/// The last lane released: unregister it, then close the shared flow.
pub const SLOPDESK_LANE_FLOW_CLOSED: u32 = 2;

/// Created, not yet started.
pub const SLOPDESK_CONN_SETUP: u32 = 0;
/// Bringing the path up.
pub const SLOPDESK_CONN_PREPARING: u32 = 1;
/// Usable.
pub const SLOPDESK_CONN_READY: u32 = 2;
/// The path is down and the framework will queue rather than send.
pub const SLOPDESK_CONN_WAITING: u32 = 3;
/// The connection failed.
pub const SLOPDESK_CONN_FAILED: u32 = 4;
/// The connection was cancelled.
pub const SLOPDESK_CONN_CANCELLED: u32 = 5;

/// The refcounted pool of shared client flows, one per endpoint.
#[derive(Debug)]
pub struct SlopDeskVideoFlowPool {
    /// The pool proper.
    inner: VideoFlowPool,
}

/// Turns a caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer from [`slopdesk_video_pool_new`] that has not been freed,
/// with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskVideoFlowPool) -> Option<&'a mut SlopDeskVideoFlowPool> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// The endpoint a `(host bytes, ports)` triple names. Bytes that are not UTF-8 key by their lossy
/// reading rather than being refused: an endpoint is a map key here, not a name to be validated,
/// and the near side already holds the address it dialled.
///
/// # Safety
/// `host` must be null, or point to `host_len` initialised bytes live for the call.
#[expect(
    unsafe_code,
    reason = "the host address arrives as a pointer and length like every other string on this door"
)]
unsafe fn endpoint(host: *const u8, host_len: usize, media_port: u16, cursor_port: u16) -> FlowEndpoint {
    // SAFETY: the caller's obligation is discharged by Swift's `withUnsafeBufferPointer`.
    let bytes = unsafe { borrow(host, host_len) };
    FlowEndpoint::new(String::from_utf8_lossy(bytes), media_port, cursor_port)
}

/// The code a release outcome crosses as.
const fn release_code(outcome: ReleaseOutcome) -> u32 {
    match outcome {
        ReleaseOutcome::Unknown => SLOPDESK_LANE_UNKNOWN,
        ReleaseOutcome::LaneRemoved => SLOPDESK_LANE_REMOVED,
        ReleaseOutcome::FlowClosed => SLOPDESK_LANE_FLOW_CLOSED,
    }
}

/// The connection state a code names. An unknown code reads as `Setup`, the state that carries no
/// verdict — the safe reading of a code this side never emitted.
const fn state_of(code: u32) -> ConnectionStateKind {
    match code {
        SLOPDESK_CONN_PREPARING => ConnectionStateKind::Preparing,
        SLOPDESK_CONN_READY => ConnectionStateKind::Ready,
        SLOPDESK_CONN_WAITING => ConnectionStateKind::Waiting,
        SLOPDESK_CONN_FAILED => ConnectionStateKind::Failed,
        SLOPDESK_CONN_CANCELLED => ConnectionStateKind::Cancelled,
        _ => ConnectionStateKind::Setup,
    }
}

/// A pool whose lane allocator starts at `seed`, masked into the seed band and floored past zero.
///
/// The randomness is the caller's: this side stays deterministic, so the per-process base is
/// injected rather than drawn here.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_video_pool_new(seed: u32) -> *mut SlopDeskVideoFlowPool {
    Box::into_raw(Box::new(SlopDeskVideoFlowPool {
        inner: VideoFlowPool::new(seed),
    }))
}

/// Releases a pool. Null is a no-op; a handle must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_video_pool_new`] that has not been freed.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_video_pool_free(handle: *mut SlopDeskVideoFlowPool) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `new` and is unfreed.
    drop(unsafe { Box::from_raw(handle) });
}

/// How many distinct shared flows are pooled — one per active host, which is the whole point.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_video_pool_shared_flow_count(handle: *mut SlopDeskVideoFlowPool) -> usize {
    // SAFETY: the caller's obligation.
    unsafe { held(handle) }.map_or(0, |pool| pool.inner.shared_flow_count())
}

/// How many live lanes ride the shared flow for one endpoint.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `host` [`endpoint`]'s.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_video_pool_lane_count(
    handle: *mut SlopDeskVideoFlowPool,
    host: *const u8,
    host_len: usize,
    media_port: u16,
    cursor_port: u16,
) -> usize {
    // SAFETY: the caller's obligations.
    let Some(pool) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on the address bytes.
    let key = unsafe { endpoint(host, host_len, media_port, cursor_port) };
    pool.inner.lane_count(&key)
}

/// Acquires a lane, answering its id and writing through whether the caller must BUILD the shared
/// flow first — the first acquisition on an endpoint creates it, every later one joins.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `host` [`endpoint`]'s, and `out_created` must be
/// null or point to one writable `bool` for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_video_pool_acquire(
    handle: *mut SlopDeskVideoFlowPool,
    host: *const u8,
    host_len: usize,
    media_port: u16,
    cursor_port: u16,
    out_created: *mut bool,
) -> u32 {
    // SAFETY: the caller's obligations.
    let Some(pool) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on the address bytes.
    let key = unsafe { endpoint(host, host_len, media_port, cursor_port) };
    let outcome = pool.inner.acquire(key);
    if !out_created.is_null() {
        // SAFETY: the caller's obligation that this points at one writable bool.
        unsafe { *out_created = matches!(outcome, AcquireOutcome::FlowCreated { .. }) };
    }
    outcome.channel_id()
}

/// Releases a lane, answering what the caller owes the sockets: nothing, an unregister, or an
/// unregister and a close. The flow survives exactly as long as one pane still rides it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `host` [`endpoint`]'s.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_video_pool_release(
    handle: *mut SlopDeskVideoFlowPool,
    host: *const u8,
    host_len: usize,
    media_port: u16,
    cursor_port: u16,
    channel_id: u32,
) -> u32 {
    // SAFETY: the caller's obligations.
    let Some(pool) = (unsafe { held(handle) }) else {
        return SLOPDESK_LANE_UNKNOWN;
    };
    // SAFETY: the caller's obligation on the address bytes.
    let key = unsafe { endpoint(host, host_len, media_port, cursor_port) };
    release_code(pool.inner.release(&key, channel_id))
}

/// Whether to re-arm the receive loop: only while the flow is still alive.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_mux_should_rearm(connection_is_alive: bool) -> bool {
    should_rearm(connection_is_alive)
}

/// The delay, in seconds, before re-arming after an error-bearing completion. Zero consecutive
/// errors means re-arm immediately, so the hot path is never delayed.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_mux_receive_backoff(consecutive_errors: u32) -> f64 {
    receive_backoff(consecutive_errors)
}

/// The send-path viability after observing a connection state, or no verdict at all.
///
/// Answers whether the state carries a verdict; the verdict itself is written through
/// `out_viable`. The bring-up states carry none and leave the caller's previous reading alone —
/// spelled as an absence rather than as a third value, because "unchanged" is not a viability.
///
/// # Safety
/// `out_viable` must be null or point to one writable `bool` for the call.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_mux_send_path_viability(state: u32, out_viable: *mut bool) -> bool {
    let Some(viable) = slopdesk_video::mux_flow::send_path_viability(state_of(state)) else {
        return false;
    };
    if !out_viable.is_null() {
        // SAFETY: the caller's obligation that this points at one writable bool.
        unsafe { *out_viable = viable };
    }
    true
}

/// The offsets, in seconds from the start, at which a one-shot request should go out.
///
/// The video path is fire-and-forget UDP with no request-and-response machinery, so a discovery
/// builds its own: resend every interval until the reply lands or the deadline passes. Both the
/// request AND the reply can be lost, so one send is never enough — and an interval of zero or less
/// is not a schedule, it is a spin, which answers with no offsets at all.
///
/// Returns how many offsets there are. Nothing is written unless they all fit, so the caller may
/// ask with no buffer first.
///
/// # Safety
/// `out` must be null or writable for `cap` `double`s.
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_video_request_send_offsets(
    timeout_seconds: f64,
    retry_interval_seconds: f64,
    out: *mut f64,
    cap: usize,
) -> usize {
    let offsets = request_send_offsets(timeout_seconds, retry_interval_seconds);
    if out.is_null() || offsets.len() > cap {
        return offsets.len();
    }
    // SAFETY: `out` is non-null and the caller lent `cap` doubles, which the length was just shown
    // to fit inside; the source is a fresh Vec that cannot overlap it.
    unsafe { core::ptr::copy_nonoverlapping(offsets.as_ptr(), out, offsets.len()) };
    offsets.len()
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{
        SLOPDESK_CONN_CANCELLED, SLOPDESK_CONN_PREPARING, SLOPDESK_CONN_READY, SLOPDESK_CONN_SETUP,
        SLOPDESK_CONN_WAITING, SLOPDESK_LANE_FLOW_CLOSED, SLOPDESK_LANE_REMOVED, SLOPDESK_LANE_UNKNOWN,
        slopdesk_mux_receive_backoff, slopdesk_mux_send_path_viability, slopdesk_mux_should_rearm,
        slopdesk_video_pool_acquire, slopdesk_video_pool_free, slopdesk_video_pool_lane_count,
        slopdesk_video_pool_new, slopdesk_video_pool_release, slopdesk_video_pool_shared_flow_count,
    };

    const HOST: &[u8] = b"10.7.0.2";
    const OTHER: &[u8] = b"10.7.0.3";

    #[test]
    fn siblings_share_one_flow_and_the_last_one_out_closes_it() {
        let pool = slopdesk_video_pool_new(0);
        unsafe {
            let mut created = false;
            let first =
                slopdesk_video_pool_acquire(pool, HOST.as_ptr(), HOST.len(), 7000, 7001, &raw mut created);
            assert!(created, "the first lane on an endpoint builds the flow");
            let second =
                slopdesk_video_pool_acquire(pool, HOST.as_ptr(), HOST.len(), 7000, 7001, &raw mut created);
            assert!(!created, "a sibling joins the flow that is already up");
            assert_ne!(first, second);
            assert_eq!(slopdesk_video_pool_shared_flow_count(pool), 1);
            assert_eq!(
                slopdesk_video_pool_lane_count(pool, HOST.as_ptr(), HOST.len(), 7000, 7001),
                2
            );
            assert_eq!(
                slopdesk_video_pool_release(pool, HOST.as_ptr(), HOST.len(), 7000, 7001, first),
                SLOPDESK_LANE_REMOVED,
                "a sibling still rides it",
            );
            assert_eq!(
                slopdesk_video_pool_release(pool, HOST.as_ptr(), HOST.len(), 7000, 7001, second),
                SLOPDESK_LANE_FLOW_CLOSED,
            );
            assert_eq!(slopdesk_video_pool_shared_flow_count(pool), 0);
            assert_eq!(
                slopdesk_video_pool_release(pool, HOST.as_ptr(), HOST.len(), 7000, 7001, second),
                SLOPDESK_LANE_UNKNOWN,
                "releasing twice asks nothing of the sockets",
            );
            slopdesk_video_pool_free(pool);
        }
    }

    #[test]
    fn two_hosts_are_two_flows_and_a_null_pool_answers_empty() {
        let pool = slopdesk_video_pool_new(0);
        unsafe {
            slopdesk_video_pool_acquire(pool, HOST.as_ptr(), HOST.len(), 7000, 7001, std::ptr::null_mut());
            slopdesk_video_pool_acquire(
                pool,
                OTHER.as_ptr(),
                OTHER.len(),
                7000,
                7001,
                std::ptr::null_mut(),
            );
            slopdesk_video_pool_acquire(pool, HOST.as_ptr(), HOST.len(), 8000, 8001, std::ptr::null_mut());
            assert_eq!(
                slopdesk_video_pool_shared_flow_count(pool),
                3,
                "port pairs key too"
            );
            slopdesk_video_pool_free(pool);
            assert_eq!(slopdesk_video_pool_shared_flow_count(std::ptr::null_mut()), 0);
            assert_eq!(
                slopdesk_video_pool_lane_count(std::ptr::null_mut(), HOST.as_ptr(), HOST.len(), 7000, 7001),
                0,
            );
        }
    }

    #[test]
    fn the_seed_separates_two_clients_id_ranges() {
        let low = slopdesk_video_pool_new(0);
        let high = slopdesk_video_pool_new(0x0FFF_0000);
        unsafe {
            let a =
                slopdesk_video_pool_acquire(low, HOST.as_ptr(), HOST.len(), 7000, 7001, std::ptr::null_mut());
            let b = slopdesk_video_pool_acquire(
                high,
                HOST.as_ptr(),
                HOST.len(),
                7000,
                7001,
                std::ptr::null_mut(),
            );
            assert!(a >= 1, "zero stays an unset field on the wire");
            assert_ne!(a, b, "two processes cannot mint the same first lane");
            slopdesk_video_pool_free(low);
            slopdesk_video_pool_free(high);
        }
    }

    #[test]
    fn the_loop_re_arms_while_alive_and_backs_off_only_on_errors() {
        assert!(slopdesk_mux_should_rearm(true));
        assert!(!slopdesk_mux_should_rearm(false));
        assert!(
            slopdesk_mux_receive_backoff(0).abs() < 1e-12,
            "the hot path is never delayed"
        );
        assert!((slopdesk_mux_receive_backoff(1) - 0.005).abs() < 1e-12);
        assert!((slopdesk_mux_receive_backoff(5) - 0.080).abs() < 1e-12);
        assert!(
            (slopdesk_mux_receive_backoff(100) - 0.250).abs() < 1e-12,
            "capped, never overflowing"
        );
    }

    #[test]
    fn only_the_settled_states_carry_a_send_verdict() {
        let mut viable = false;
        unsafe {
            assert!(slopdesk_mux_send_path_viability(
                SLOPDESK_CONN_READY,
                &raw mut viable
            ));
            assert!(viable);
            assert!(slopdesk_mux_send_path_viability(
                SLOPDESK_CONN_WAITING,
                &raw mut viable
            ));
            assert!(!viable);
            assert!(slopdesk_mux_send_path_viability(
                SLOPDESK_CONN_CANCELLED,
                &raw mut viable
            ));
            assert!(!viable);
            assert!(
                !slopdesk_mux_send_path_viability(SLOPDESK_CONN_SETUP, &raw mut viable),
                "bring-up leaves the caller's reading alone",
            );
            assert!(!slopdesk_mux_send_path_viability(
                SLOPDESK_CONN_PREPARING,
                std::ptr::null_mut()
            ));
        }
    }
}
