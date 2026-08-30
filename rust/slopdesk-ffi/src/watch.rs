//! What the HOST and the CLIENT read back out of the bytes `slopdesk watch` prints.
//!
//! The wrapper itself is Rust now — `slopdesk-cli`'s `shell::watch` calls `slopdesk-wire::osc`
//! directly — so the writing half of this door is gone. What is left is the reading half, which is
//! Swift's because the sniffer and the notification router are: the `ConEmu` `9;4` progress parse
//! the host's byte reader runs, and the private sentinel that tells a watch-finish banner apart
//! from any other explicit `OSC 9`.
//!
//! Both stay wrapped from `slopdesk-wire::osc` rather than re-spelled here, which is the point: the
//! grammar the wrapper WRITES and the grammar the host READS are one crate, so a spinner cannot
//! survive the command that raised it because two modules disagreed about a digit.
//!
//! ## Everything crosses by value
//! A progress update is a function of one body; a marker check is a function of one title. So both
//! entry points are the pure convention: inputs as `(ptr, len)`, the answer written into a lent
//! buffer or a one-byte out-parameter.

use std::ffi::c_uchar;

use slopdesk_wire::osc::{WATCH_NOTIFICATION_MARKER, is_watch_notification, parse_progress};

use crate::{borrow, deliver};

/// Parses an OSC-9 body — the remainder AFTER the leading `9;` — as `4;<state>[;<percent>]`.
///
/// The host's byte reader has already split the `9;` off by the time it asks, so what crosses is
/// `4;1;40`, never `9;4;1;40`. Answers `false` for a body that is not a progress update, which is
/// the reader's cue to leave the bytes alone rather than to guess a state.
///
/// # Safety
/// The body pair must be live for the call; both output pointers must be null or writable for one
/// byte.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_osc_parse_progress(
    body: *const c_uchar,
    body_len: usize,
    state: *mut u8,
    percent: *mut u8,
) -> bool {
    // SAFETY: the caller's obligation on the input pair.
    let text = String::from_utf8_lossy(unsafe { borrow(body, body_len) });
    let Some(update) = parse_progress(text.as_ref()) else {
        return false;
    };
    if !state.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one byte.
        unsafe { std::ptr::write(state, update.state.to_wire()) };
    }
    if !percent.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one byte.
        unsafe { std::ptr::write(percent, update.percent) };
    }
    true
}

/// The private sentinel a watch-finish banner carries in its title field.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_watch_notification_marker(out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation on the output buffer.
    unsafe { deliver(WATCH_NOTIFICATION_MARKER.as_bytes(), out, cap) }
}

/// Whether a notification's TITLE is the watch sentinel — which routes the banner to the dedicated
/// "Notify on Watch Finish" toggle instead of the generic master switch.
///
/// The reading of the marker sits beside the constant that names it, so the client recognises
/// exactly what the wrapper emitted rather than a second spelling of it.
///
/// # Safety
/// `title` must be null, or point to `title_len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_watch_notification_is_marked(
    title: *const c_uchar,
    title_len: usize,
) -> bool {
    // SAFETY: the caller's obligation on the input pair.
    let text = unsafe { borrow(title, title_len) };
    core::str::from_utf8(text).is_ok_and(is_watch_notification)
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "a test of a C entry point has to make the call the C caller would"
    )]
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_wire::osc::{WATCH_NOTIFICATION_MARKER, watch_finish_notification_bytes};

    use super::{
        slopdesk_osc_parse_progress, slopdesk_watch_notification_is_marked,
        slopdesk_watch_notification_marker,
    };

    /// The parse the host's byte reader runs, and the refusal that leaves foreign bytes alone.
    #[test]
    fn a_progress_body_yields_its_state_and_anything_else_yields_nothing() {
        let mut state = 0_u8;
        let mut percent = 0_u8;
        // The remainder after `9;`, which is all the host's reader ever hands over.
        let body = b"4;1;40";
        // SAFETY: both pointers are live locals and the input pair is a live slice.
        let parsed = unsafe {
            slopdesk_osc_parse_progress(body.as_ptr(), body.len(), &raw mut state, &raw mut percent)
        };
        assert!(parsed);
        assert_eq!((state, percent), (1, 40));

        // An OSC 9 the host sees far more often: a plain notification, whose first field is a
        // title.
        let foreign = b"some title";
        // SAFETY: as above.
        let parsed = unsafe {
            slopdesk_osc_parse_progress(foreign.as_ptr(), foreign.len(), &raw mut state, &raw mut percent)
        };
        assert!(!parsed, "a notification body is not a progress update");
        assert_eq!((state, percent), (1, 40), "a refusal writes nothing");
    }

    /// The marker the CLI writes is the marker the client recognises — the whole reason both
    /// spellings come out of one crate.
    #[test]
    fn the_banner_the_wrapper_emits_is_recognised_by_its_title() {
        let needed = unsafe { slopdesk_watch_notification_marker(std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is writable for exactly the length the sizing call asked for.
        let written = unsafe { slopdesk_watch_notification_marker(out.as_mut_ptr(), out.len()) };
        assert_eq!(written, needed);
        assert_eq!(
            String::from_utf8(out).expect("the marker is UTF-8"),
            WATCH_NOTIFICATION_MARKER
        );

        // SAFETY: the input pair is a live slice.
        let marked = unsafe {
            slopdesk_watch_notification_is_marked(
                WATCH_NOTIFICATION_MARKER.as_ptr(),
                WATCH_NOTIFICATION_MARKER.len(),
            )
        };
        assert!(marked);
        // SAFETY: as above.
        assert!(!unsafe { slopdesk_watch_notification_is_marked(b"Build".as_ptr(), 5) });

        // And the bytes the wrapper actually prints carry it.
        let banner = String::from_utf8(watch_finish_notification_bytes("watch: true")).expect("UTF-8");
        assert!(banner.contains(WATCH_NOTIFICATION_MARKER), "{banner:?}");
    }
}
