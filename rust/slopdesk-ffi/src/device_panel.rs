//! The two device panels' shared decisions, in C.
//!
//! The rules are `slopdesk_devicepanel`'s; what is here is the marshalling. Only the host name
//! crosses through a buffer, and only inward: every answer is a KIND byte, because the panel
//! already holds the host string and the device row the answer is about.
//!
//! The endpoint crosses as the two scalars Swift already holds — the RAW state byte and the port —
//! rather than as a decoded state, so the forward-tolerant read of an unknown byte stays the wire's
//! one rule instead of becoming a second one on this side of the door.

use core::ffi::c_uchar;

use slopdesk_devicepanel::{Phase, phase, poll_backoff, stream_verdict, video_arrival_is_news};
use slopdesk_wire::metadata::ServiceEndpoint;

use crate::borrow;

/// The phase a device panel renders for one ensure round: `0` offline · `1` starting ·
/// `2` unavailable · `3` ready.
///
/// `has_endpoint` is false for a round that got no answer at all. `host`/`host_len` is the address
/// the panel would dial — null, or empty, is "none", which is why the emptiness test is in here
/// rather than at the call site: it is the same non-answer as a port of `0`.
///
/// # Safety
/// `host` must be null, or point to `host_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_device_panel_phase(
    has_endpoint: bool,
    state_byte: u8,
    port: u16,
    host: *const c_uchar,
    host_len: usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let host = unsafe { borrow(host, host_len) };
    let endpoint = has_endpoint.then_some(ServiceEndpoint { state_byte, port });
    phase(endpoint, !host.is_empty()).as_byte()
}

/// How many poll intervals `phase_byte` waits before the ensure verb is asked again — `0` stops the
/// loop. A byte no build wrote reads as the offline tier, which is the slowest and therefore the
/// safe one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_device_panel_poll_backoff(phase_byte: u8) -> u32 {
    poll_backoff(match Phase::from_byte(phase_byte) {
        Some(phase) => phase,
        None => Phase::Offline,
    })
}

/// What to do about a selection with no video yet: `0` connect · `1` wait · `2` gone · `3` stalled
/// · `4` never-ready.
///
/// `is_listed` is false for a device the latest list no longer carries, which is the one answer
/// that does not consult `is_running` or the clock.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_device_panel_stream_verdict(
    is_listed: bool,
    is_running: bool,
    within_grace: bool,
) -> u8 {
    stream_verdict(if is_listed { Some(is_running) } else { None }, within_grace).as_byte()
}

/// Whether an arriving frame has anything to tell the observable layer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_device_panel_video_is_news(
    has_video: bool,
    is_awaiting_stream: bool,
) -> bool {
    video_arrival_is_news(has_video, is_awaiting_stream)
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary the way Swift does IS what these tests are for"
)]
mod tests {
    use super::{
        slopdesk_device_panel_phase, slopdesk_device_panel_poll_backoff,
        slopdesk_device_panel_stream_verdict, slopdesk_device_panel_video_is_news,
    };

    fn phase_of(has_endpoint: bool, state_byte: u8, port: u16, host: &str) -> u8 {
        // SAFETY: the borrow lives for the call, which is the whole obligation.
        unsafe { slopdesk_device_panel_phase(has_endpoint, state_byte, port, host.as_ptr(), host.len()) }
    }

    #[test]
    fn the_door_carries_the_ready_answer_and_every_way_of_missing_it() {
        assert_eq!(phase_of(true, 1, 7421, "10.0.0.2"), 3);
        assert_eq!(phase_of(true, 1, 0, "10.0.0.2"), 0);
        assert_eq!(phase_of(true, 1, 7421, ""), 0);
        assert_eq!(phase_of(false, 1, 7421, "10.0.0.2"), 0);
        assert_eq!(phase_of(true, 0, 0, "h"), 1);
        assert_eq!(phase_of(true, 2, 0, "h"), 2);
    }

    #[test]
    fn a_null_host_reads_as_no_address_rather_than_a_trap() {
        // SAFETY: null is the documented "none", and `borrow` answers an empty slice for it.
        let answer = unsafe { slopdesk_device_panel_phase(true, 1, 7421, core::ptr::null(), 0) };
        assert_eq!(answer, 0);
    }

    #[test]
    fn the_backoff_crosses_per_phase_and_an_unknown_byte_takes_the_slow_tier() {
        assert_eq!(slopdesk_device_panel_poll_backoff(3), 0);
        assert_eq!(slopdesk_device_panel_poll_backoff(1), 1);
        assert_eq!(slopdesk_device_panel_poll_backoff(0), 4);
        assert_eq!(slopdesk_device_panel_poll_backoff(2), 4);
        assert_eq!(slopdesk_device_panel_poll_backoff(200), 4);
    }

    #[test]
    fn the_verdict_crosses_as_its_five_kinds() {
        assert_eq!(slopdesk_device_panel_stream_verdict(true, true, true), 0);
        assert_eq!(slopdesk_device_panel_stream_verdict(true, false, true), 1);
        assert_eq!(slopdesk_device_panel_stream_verdict(false, true, true), 2);
        assert_eq!(slopdesk_device_panel_stream_verdict(true, true, false), 3);
        assert_eq!(slopdesk_device_panel_stream_verdict(true, false, false), 4);
    }

    #[test]
    fn a_frame_is_news_once_per_wait() {
        assert!(slopdesk_device_panel_video_is_news(false, true));
        assert!(!slopdesk_device_panel_video_is_news(true, false));
        assert!(slopdesk_device_panel_video_is_news(true, true));
    }
}
