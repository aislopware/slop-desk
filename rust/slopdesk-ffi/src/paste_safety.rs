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

use crate::{borrow, deliver, push_text, saturating_u32};

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

/// How many bytes [`slopdesk_paste_confirmation`]'s answer opens with, before its runs: the number
/// of danger bullets, as a big-endian `u32`.
pub const CONFIRMATION_HEAD_BYTES: usize = 4;

/// How many runs follow the head before the bullets do: the heading, the affirmative, the reason,
/// the defused preview and the one-string body, in that order.
pub const CONFIRMATION_FIXED_RUNS: usize = 5;

/// The WHOLE confirmation for one ask, in one crossing.
///
/// It used to be six: a heading door, a button door, a reason door, a count, a bullet-at-index and
/// a preview — which is `5 + n` crossings to draw one dialog, and, more to the point, six chances
/// for a renderer to take the heading of one ask beside the bullets of another. The
/// bullets-or-reason branch is a rule and not a layout, so it is decided here too: a caller draws
/// exactly one of the two and never has to know which.
///
/// A payload that is not valid UTF-8 is read lossily rather than refused, for the same reason
/// [`slopdesk_paste_dangers`] does it: a clipboard is whatever the platform handed over.
///
/// `0` for an ask index no ask has — the answer is a whole dialog or nothing, never a dialog with a
/// blank heading.
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call; `(out, cap)` must be
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_paste_confirmation(
    ask: u8,
    mask: u32,
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(ask) = Ask::from_index(ask) else { return 0 };
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    let shown = slopdesk_terminal::paste::confirmation(ask, &String::from_utf8_lossy(bytes), mask);
    let mut answer = Vec::with_capacity(CONFIRMATION_HEAD_BYTES + shown.informative_text.len() * 2 + 256);
    answer.extend_from_slice(&saturating_u32(shown.dangers.len()).to_be_bytes());
    push_text(&mut answer, shown.title);
    push_text(&mut answer, shown.affirmative);
    push_text(&mut answer, shown.reason);
    push_text(&mut answer, &shown.preview);
    push_text(&mut answer, &shown.informative_text);
    for line in shown.dangers {
        push_text(&mut answer, line);
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_terminal::paste::{Ask, CONTROL_CHARS, MULTI_LINE, PREVIEW_CAPTION};

    use super::{
        CONFIRMATION_FIXED_RUNS, CONFIRMATION_HEAD_BYTES, slopdesk_paste_confirmation,
        slopdesk_paste_dangers, slopdesk_paste_should_warn,
    };
    use crate::testing::delivered;

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

    /// Cuts the confirmation delivery into its bullet count and its runs.
    fn confirmation(ask: u8, mask: u32, text: &str) -> (usize, Vec<String>) {
        // SAFETY: both pointers name live locals for the duration of the call.
        let blob = delivered(|out, cap| unsafe {
            slopdesk_paste_confirmation(ask, mask, text.as_ptr(), text.len(), out, cap)
        });
        let count = blob
            .get(..CONFIRMATION_HEAD_BYTES)
            .and_then(|four| <[u8; 4]>::try_from(four).ok())
            .map_or(0, u32::from_be_bytes) as usize;
        let mut runs = Vec::new();
        let mut cursor = CONFIRMATION_HEAD_BYTES;
        while let Some(four) = blob
            .get(cursor..cursor + 4)
            .and_then(|four| <[u8; 4]>::try_from(four).ok())
        {
            let length = u32::from_be_bytes(four) as usize;
            cursor += 4;
            let Some(run) = blob.get(cursor..cursor + length) else {
                break;
            };
            runs.push(String::from_utf8_lossy(run).into_owned());
            cursor += length;
        }
        (count, runs)
    }

    /// One crossing carries the whole dialog — its head, its button, its bullets and the body a
    /// single-string renderer sets — in the boundary's own order.
    #[test]
    fn the_whole_dialog_crosses_in_one_delivery() {
        let mask = MULTI_LINE | CONTROL_CHARS;
        let (count, runs) = confirmation(0, mask, "one\ntwo\u{1B}[31m");
        assert_eq!(count, 2);
        assert_eq!(runs.len(), CONFIRMATION_FIXED_RUNS + count);
        assert_eq!(runs.first().map(String::as_str), Some(Ask::UnsafePaste.title()));
        assert_eq!(runs.get(1).map(String::as_str), Some("Paste Anyway"));
        assert_eq!(
            runs.get(2).map(String::as_str),
            Some(""),
            "the bullets are the paste's reason"
        );
        assert_eq!(runs.get(3).map(String::as_str), Some("one\ntwo^[[31m"));
        assert!(runs.get(5).is_some_and(|line| line.starts_with("Multiple lines")));
        assert!(
            runs.get(6)
                .is_some_and(|line| line.starts_with("Contains control characters"))
        );
    }

    /// An OSC-52 ask arrives with an empty mask by construction, so the reason takes the bullets'
    /// place and the body carries no preview caption over an empty payload.
    #[test]
    fn an_osc52_ask_crosses_with_a_reason_and_no_bullets() {
        let (count, runs) = confirmation(1, 0, "");
        assert_eq!(count, 0);
        assert_eq!(runs.len(), CONFIRMATION_FIXED_RUNS);
        assert_eq!(runs.get(1).map(String::as_str), Some("Allow"));
        assert_eq!(runs.get(2).map(String::as_str), Some(Ask::ClipboardRead.reason()));
        assert_eq!(runs.get(4).map(String::as_str), Some(Ask::ClipboardRead.reason()));
        assert!(runs.iter().all(|run| !run.contains(PREVIEW_CAPTION)));
    }

    #[test]
    fn an_ask_index_no_ask_has_crosses_as_nothing_rather_than_as_a_blank_dialog() {
        let (count, runs) = confirmation(3, 0, "");
        assert_eq!(count, 0);
        assert!(runs.is_empty());
    }
}
