//! What a clipboard payload would DO at a shell prompt, in C.
//!
//! The two DECISION doors over [`slopdesk_terminal::paste`] do not take §4's `(out, cap)` shape:
//! one answers a BITMASK and the other a BOOLEAN, so there is nothing to size and nothing to
//! retry. A mask of `0` is a real answer here — "nothing about this payload is dangerous" — which
//! is exactly why the mask is not the crate's `usize` return: `0` there means the caller should
//! stop, and here it means the caller should paste.
//!
//! The WORDS doors do take it. They cross the confirmation's whole text — its heading, its button,
//! its bullets and the payload preview — because a sentence describing a danger is as much the
//! guard as the bit that trips it, and a renderer that spelled its own would be a second guard
//! saying something slightly different.
//!
//! ## What is NOT here
//! The rules, and the words. Which four things are dangerous, what counts as a `sudo` TOKEN rather
//! than a substring, the three states in which a paste provably cannot run, and every string the
//! sheet prints are `slopdesk-terminal`'s, in a crate that forbids `unsafe`.

use core::ffi::c_uchar;

use slopdesk_terminal::paste::Ask;

use crate::{borrow, deliver};

/// The four dangers `text` trips, as `slopdesk_terminal::paste`'s bit constants.
///
/// A payload that is not valid UTF-8 is read lossily rather than refused: a clipboard is whatever
/// the platform handed over, and refusing to classify it would silently mean "safe".
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_dangers(text: *const c_uchar, len: usize) -> u32 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    slopdesk_terminal::paste::dangers(&String::from_utf8_lossy(bytes))
}

/// Whether the paste-protection confirmation should be shown.
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_should_warn(
    text: *const c_uchar,
    len: usize,
    protection_on: bool,
    bracketed_safe: bool,
    program_advertised_bracketed: bool,
    is_alternate_screen: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    slopdesk_terminal::paste::should_warn(
        &String::from_utf8_lossy(bytes),
        protection_on,
        bracketed_safe,
        program_advertised_bracketed,
        is_alternate_screen,
    )
}

/// How many bullets a mask spells out. `0` is a real answer — an OSC-52 ask arrives with no
/// dangers at all and prints its reason instead.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_paste_danger_count(mask: u32) -> usize {
    slopdesk_terminal::paste::descriptions(mask).len()
}

/// One bullet of a mask, in bit order. `0` past the end.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_danger_description(
    mask: u32,
    index: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let lines = slopdesk_terminal::paste::descriptions(mask);
    let line = lines.get(index).copied().unwrap_or_default();
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(line.as_bytes(), out, cap) }
}

/// The confirmation's heading for one ask. `0` for an ask index no ask has.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_ask_title(ask: u8, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: as above.
    unsafe { ask_field(ask, out, cap, Ask::title) }
}

/// The affirmative button's title for one ask. `0` for an ask index no ask has.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_ask_affirmative(ask: u8, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: as above.
    unsafe { ask_field(ask, out, cap, Ask::affirmative) }
}

/// What the body says when the mask flagged nothing.
///
/// `0` for the unsafe paste, which never arrives without a danger to list, and for an ask index no
/// ask has — the two read identically because neither prints a line.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_ask_reason(ask: u8, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: as above.
    unsafe { ask_field(ask, out, cap, Ask::reason) }
}

/// The payload as the confirmation shows it — capped, with every control character made visible.
///
/// A payload that is not valid UTF-8 is read lossily rather than refused, for the same reason
/// [`slopdesk_paste_dangers`] does it: a clipboard is whatever the platform handed over.
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call; `(out, cap)` must be
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_preview(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` and `deliver` state their own.
    let bytes = unsafe { borrow(text, len) };
    let shown = slopdesk_terminal::paste::preview(&String::from_utf8_lossy(bytes));
    // SAFETY: as above.
    unsafe { deliver(shown.as_bytes(), out, cap) }
}

/// One ask's string, or nothing for an index no ask has.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "the shared body of the exported doors above, and it carries their obligation"
)]
unsafe fn ask_field(ask: u8, out: *mut c_uchar, cap: usize, field: fn(Ask) -> &'static str) -> usize {
    let answer = Ask::from_index(ask).map(field).unwrap_or_default();
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_terminal::paste::{CONTROL_CHARS, MULTI_LINE};

    use super::{
        slopdesk_paste_ask_affirmative, slopdesk_paste_ask_reason, slopdesk_paste_ask_title,
        slopdesk_paste_danger_count, slopdesk_paste_danger_description, slopdesk_paste_dangers,
        slopdesk_paste_preview, slopdesk_paste_should_warn,
    };

    fn dangers(text: &str) -> u32 {
        // SAFETY: the pointer names a live local for the duration of the call.
        unsafe { slopdesk_paste_dangers(text.as_ptr(), text.len()) }
    }

    #[test]
    fn the_mask_crosses_and_zero_means_safe_rather_than_no_answer() {
        assert_eq!(dangers("ls -la"), 0);
        assert_eq!(dangers("sudo id\n"), 0b0110, "sudo plus a trailing newline");
    }

    #[test]
    fn the_decision_crosses_with_its_four_states() {
        let risky = "sudo id\n";
        // SAFETY: the pointer names a live local for the duration of each call.
        let warn = |on, safe, advertised, alt| unsafe {
            slopdesk_paste_should_warn(risky.as_ptr(), risky.len(), on, safe, advertised, alt)
        };
        assert!(warn(true, false, false, false));
        assert!(!warn(false, false, false, false));
        assert!(!warn(true, false, false, true));
        assert!(!warn(true, true, true, false));
    }

    #[test]
    fn a_null_payload_is_the_empty_one() {
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        let mask = unsafe { slopdesk_paste_dangers(std::ptr::null(), 0) };
        assert_eq!(mask, 0);
    }

    /// Reads one `(out, cap)` door at a capacity generous enough that nothing here retries.
    fn read(door: impl Fn(*mut u8, usize) -> usize) -> String {
        let mut buffer = [0_u8; 256];
        let written = door(buffer.as_mut_ptr(), buffer.len());
        // A door that reported MORE than it wrote asked for a retry — nothing here is long enough
        // to need one, so an empty answer here is the failure rather than a truncated read.
        let answer = buffer.get(..written).unwrap_or_default();
        String::from_utf8_lossy(answer).into_owned()
    }

    #[test]
    fn the_bullets_cross_in_bit_order_and_stop_at_the_end() {
        let mask = MULTI_LINE | CONTROL_CHARS;
        assert_eq!(slopdesk_paste_danger_count(mask), 2);
        // SAFETY: the buffer is a live local for the duration of each call.
        let line =
            |index| read(|out, cap| unsafe { slopdesk_paste_danger_description(mask, index, out, cap) });
        assert!(line(0).starts_with("Multiple lines"));
        assert!(line(1).starts_with("Contains control characters"));
        assert!(line(2).is_empty(), "past the end is nothing, not a panic");
        assert_eq!(slopdesk_paste_danger_count(0), 0);
    }

    #[test]
    fn every_ask_crosses_with_a_heading_and_a_button_and_only_two_with_a_reason() {
        // SAFETY: the buffer is a live local for the duration of each call.
        let title = |ask| read(|out, cap| unsafe { slopdesk_paste_ask_title(ask, out, cap) });
        let button = |ask| read(|out, cap| unsafe { slopdesk_paste_ask_affirmative(ask, out, cap) });
        let reason = |ask| read(|out, cap| unsafe { slopdesk_paste_ask_reason(ask, out, cap) });
        for ask in 0..3 {
            assert!(!title(ask).is_empty(), "ask {ask} crossed headless");
            assert!(!button(ask).is_empty(), "ask {ask} crossed with no button");
        }
        assert_eq!(button(0), "Paste Anyway");
        assert!(reason(0).is_empty(), "the dangers are the unsafe paste's reason");
        assert!(!reason(1).is_empty() && !reason(2).is_empty());
        assert!(title(3).is_empty(), "past the end is nothing, not a panic");
    }

    #[test]
    fn the_preview_crosses_with_its_escapes_already_defused() {
        let text = "go \u{1B}[31m";
        // SAFETY: both pointers name live locals for the duration of the call.
        let shown = read(|out, cap| unsafe { slopdesk_paste_preview(text.as_ptr(), text.len(), out, cap) });
        assert_eq!(shown, "go ^[[31m");
        // SAFETY: a null payload with a zero length is what `borrow` documents.
        let empty = read(|out, cap| unsafe { slopdesk_paste_preview(std::ptr::null(), 0, out, cap) });
        assert!(empty.is_empty());
    }
}
