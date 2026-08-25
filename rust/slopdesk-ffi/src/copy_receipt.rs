//! What just landed on the clipboard, in C.
//!
//! ONE door, because the receipt is one answer. The two chips that draw it hold the counts as their
//! identity and print the sentence beside them, so a door for the numbers and a door for the words
//! would be two crossings for one copy — and, worse, two chances for a chip to hold a count from
//! one grab beside a sentence from the next.
//!
//! The delivery leads with the numbers and follows with the runs, which is the shape `docs/55` §4
//! already uses where an answer is not all text: a count spelled as text would only have to be read
//! back, and a run holding a number could not say whether it was a length or a figure.

use core::ffi::c_uchar;

use slopdesk_terminal::copy_receipt;

use crate::{borrow, deliver, push_text, saturating_u32};

/// How many bytes [`slopdesk_copy_receipt`]'s answer opens with, before its two runs: the character
/// count and the line count, each a big-endian `u32`.
pub const RECEIPT_HEAD_BYTES: usize = 8;

/// The receipt for a copy of `text`: its two counts, then its two sentences.
///
/// A payload that is not valid UTF-8 is read lossily rather than refused — a clipboard is whatever
/// the platform handed over, and refusing to count it would report an empty copy.
///
/// The answer is never `0`: an empty copy still has a receipt (`0 characters`), because the chip is
/// shown BECAUSE a copy happened and a silent chip would read as a copy that failed.
///
/// # Safety
/// `(text, len)` must be null, or name `len` initialised bytes live for the call, and `(out, cap)`
/// must be writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_copy_receipt(
    text: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    let counts = copy_receipt::counts(&String::from_utf8_lossy(bytes));
    let mut answer = Vec::with_capacity(RECEIPT_HEAD_BYTES + 64);
    answer.extend_from_slice(&saturating_u32(counts.chars).to_be_bytes());
    answer.extend_from_slice(&saturating_u32(counts.lines).to_be_bytes());
    push_text(&mut answer, &copy_receipt::detail(counts));
    push_text(&mut answer, &copy_receipt::label(counts));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{RECEIPT_HEAD_BYTES, slopdesk_copy_receipt};
    use crate::testing::delivered;

    /// Cuts the delivery into its two counts and its two runs.
    fn receipt(text: &str) -> (u32, u32, Vec<String>) {
        // SAFETY: both pointers name live locals for the duration of the call.
        let blob =
            delivered(|out, cap| unsafe { slopdesk_copy_receipt(text.as_ptr(), text.len(), out, cap) });
        let head = blob.get(..RECEIPT_HEAD_BYTES).unwrap_or_default();
        let number = |at: usize| {
            head.get(at..at + 4)
                .and_then(|four| <[u8; 4]>::try_from(four).ok())
                .map_or(0, u32::from_be_bytes)
        };
        let mut runs = Vec::new();
        let mut cursor = RECEIPT_HEAD_BYTES;
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
        (number(0), number(4), runs)
    }

    #[test]
    fn the_counts_lead_the_answer_and_the_sentences_follow_it() {
        let (chars, lines, runs) = receipt("hello");
        assert_eq!((chars, lines), (5, 1));
        assert_eq!(runs, ["5 characters", "Copied · 5 characters"]);
    }

    #[test]
    fn a_multi_line_grab_crosses_speaking_lines() {
        let (chars, lines, runs) = receipt("a\nb\nc\n");
        assert_eq!((chars, lines), (6, 3));
        assert_eq!(runs.first().map(String::as_str), Some("3 lines"));
    }

    /// An empty copy still has a receipt: the chip is shown BECAUSE a copy happened, so a silent
    /// one would read as a copy that failed.
    #[test]
    fn an_empty_payload_still_crosses_with_a_sentence() {
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        let blob = delivered(|out, cap| unsafe { slopdesk_copy_receipt(std::ptr::null(), 0, out, cap) });
        assert!(!blob.is_empty());
        let (chars, lines, runs) = receipt("");
        assert_eq!((chars, lines), (0, 1));
        assert_eq!(runs.first().map(String::as_str), Some("0 characters"));
    }
}
