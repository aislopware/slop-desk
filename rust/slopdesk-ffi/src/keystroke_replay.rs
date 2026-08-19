//! A clipboard as the keys that type it, in C.
//!
//! The rules are [`slopdesk_workspace::keystroke_replay`]; what is here is the marshalling. One §4
//! door, because one PASS produces both halves of the answer: the strokes, and how much of the
//! clipboard never became one. Asking for them separately would encode the text twice and let a
//! caller pair a stroke list with a skip count from a different string.
//!
//! ## The two counts ride in the blob
//!
//! `[u32 skipped][u32 count]` leads it, and neither is derivable. `count` is not, because §4's
//! return of `0` means *no answer* and "everything in this clipboard was an emoji" is very much an
//! answer — one the caller turns into a banner rather than into silence. `skipped` is not, because
//! it is the whole point: a paste that quietly dropped four characters of a credential is worse
//! than one that refused, and the number in front of the person has to come from the same pass that
//! produced the keys.
//!
//! ## Why the strokes cross as records and not as text
//!
//! They are not text. A stroke is a virtual key code and a modifier bit — what the far side posts
//! into a `CGEventTap` — and the character it came from is deliberately gone by here. Nothing
//! downstream of this door may reconstruct it: the payload is usually a password, and the one
//! guarantee worth having is that it exists as bytes in exactly one place for exactly as long as
//! the caller holds it.

use core::ffi::c_uchar;

use slopdesk_workspace::keystroke_replay::{self, MAX_LENGTH};

use crate::{borrow, deliver, saturating_u32};

/// The largest clipboard, in grapheme CLUSTERS, that will be replayed as keystrokes.
///
/// Exported rather than transcribed because it is also the ceiling
/// [`crate::secrets`](crate)'s paste guard refuses past — one number, asked for at both sites.
pub const SLOPDESK_KEYSTROKE_MAX_LENGTH: usize = MAX_LENGTH;

/// `[u16 BE key_code][u8 shift]`.
const RECORD: usize = 3;

/// The two counts in front of the records.
const HEADER: usize = 8;

/// The strokes that type `text` on a US-QWERTY layout, and what could not be typed.
///
/// The answer is `[u32 BE skipped][u32 BE count]` followed by `count` records of
/// `[u16 BE key_code][u8 shift]`. It is never zero-length: an empty clipboard answers the eight
/// header bytes with both counts at zero, which is a state distinct from §4's refusal.
///
/// `skipped` counts a cluster with no US-QWERTY key AND every cluster past
/// [`SLOPDESK_KEYSTROKE_MAX_LENGTH`], because in both cases the field will not hold what the
/// clipboard did and the caller has one banner to say so with.
///
/// # Safety
/// `text` must be null or describe live memory for the whole call, and `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_keystroke_replay(
    text: *const c_uchar,
    text_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the pair is null or live for the call by the caller's obligation, discharged on the
    // Swift side by `withUnsafeBytes`, whose scope is exactly this call.
    let borrowed = unsafe { borrow(text, text_len) };
    // Lossy rather than a refusal: the bytes are a pasteboard's, so an invalid sequence is not
    // something this crate rejected — and a replacement character is unmappable, which is the
    // honest skip.
    let encoded = keystroke_replay::encode(&String::from_utf8_lossy(borrowed));

    let mut blob = Vec::with_capacity(HEADER.saturating_add(encoded.strokes.len().saturating_mul(RECORD)));
    blob.extend_from_slice(&saturating_u32(encoded.skipped).to_be_bytes());
    blob.extend_from_slice(&saturating_u32(encoded.strokes.len()).to_be_bytes());
    for press in &encoded.strokes {
        blob.extend_from_slice(&press.key_code.to_be_bytes());
        blob.push(u8::from(press.shift));
    }
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and `blob` is a
    // live local that cannot overlap it.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{HEADER, RECORD, SLOPDESK_KEYSTROKE_MAX_LENGTH, slopdesk_keystroke_replay};

    /// One encode through the door, decoded back to `(skipped, [(key_code, shift)])`.
    fn replay(text: &str) -> (u32, Vec<(u16, bool)>) {
        let call = |out: *mut u8, cap: usize| {
            // SAFETY: every pointer names a live local for the duration of the call.
            unsafe { slopdesk_keystroke_replay(text.as_ptr(), text.len(), out, cap) }
        };
        let needed = call(core::ptr::null_mut(), 0);
        let mut answer = vec![0_u8; needed];
        let written = call(answer.as_mut_ptr(), answer.len());
        assert_eq!(written, needed, "the sizing call and the filling call must agree");

        let word = |at: usize| {
            answer
                .get(at..at + 4)
                .and_then(|bytes| <[u8; 4]>::try_from(bytes).ok())
                .map_or(0, u32::from_be_bytes)
        };
        let skipped = word(0);
        let count = word(4) as usize;
        let strokes = (0..count)
            .map(|index| {
                let at = HEADER + index * RECORD;
                let key = answer
                    .get(at..at + 2)
                    .and_then(|bytes| <[u8; 2]>::try_from(bytes).ok())
                    .map_or(0, u16::from_be_bytes);
                (key, answer.get(at + 2).copied().unwrap_or(0) != 0)
            })
            .collect();
        (skipped, strokes)
    }

    /// The header spells this number too, as `#define SLOPDESK_KEYSTROKE_MAX_LENGTH`, because a
    /// define is what the near side can size a buffer from. Nothing in the build checks a define
    /// against a const, so it is written down here and CROSSED in `KeystrokeReplayTests` — a drift
    /// then fails a test rather than silently truncating a password.
    #[test]
    fn the_exported_cap_is_the_number_the_header_defines() {
        assert_eq!(SLOPDESK_KEYSTROKE_MAX_LENGTH, 4096);
    }

    #[test]
    fn a_password_crosses_as_the_presses_that_type_it() {
        let (skipped, strokes) = replay("Hi!");
        assert_eq!(skipped, 0);
        assert_eq!(strokes, vec![(4, true), (34, false), (18, true)]);
    }

    /// ⚠️ The grapheme rule, asserted THROUGH the door: a decomposed accent must arrive as a skip,
    /// never as the bare `e` a scalar walk would have typed into a password field.
    #[test]
    fn a_decomposed_accent_crosses_as_a_skip_and_not_as_its_base_letter() {
        assert_eq!(
            replay("caf\u{65}\u{301}"),
            (1, vec![(8, false), (0, false), (3, false)])
        );
    }

    /// An all-unmappable clipboard is the header with a real skip count — NOT §4's `0`, which the
    /// caller would read as "ask again" and show nothing.
    #[test]
    fn a_clipboard_that_types_nothing_still_answers() {
        let needed = {
            let text = "\u{1f600}\u{1f600}";
            // SAFETY: the pointer names a live local for the duration of the call.
            unsafe { slopdesk_keystroke_replay(text.as_ptr(), text.len(), core::ptr::null_mut(), 0) }
        };
        assert_eq!(needed, HEADER, "two counts and no records");
        assert_eq!(replay("\u{1f600}\u{1f600}"), (2, vec![]));
    }

    #[test]
    fn an_empty_clipboard_is_the_header_with_both_counts_at_zero() {
        // SAFETY: a null pair is exactly what the door is documented to accept.
        let needed = unsafe { slopdesk_keystroke_replay(core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(needed, HEADER);
        assert_eq!(replay(""), (0, vec![]));
    }

    /// A short buffer leaves it UNTOUCHED and reports the size — §4's retry, and the reason a
    /// caller can never post half a password.
    #[test]
    fn a_short_buffer_writes_nothing_at_all() {
        let text = "abc";
        let mut answer = [0xAA_u8; 4];
        // SAFETY: both pointers name live locals for the duration of the call.
        let needed = unsafe {
            slopdesk_keystroke_replay(text.as_ptr(), text.len(), answer.as_mut_ptr(), answer.len())
        };
        assert_eq!(needed, HEADER + 3 * RECORD);
        assert_eq!(answer, [0xAA; 4], "nothing was written");
    }

    #[test]
    fn the_cap_crosses_as_strokes_kept_and_overflow_skipped() {
        let big = "a".repeat(SLOPDESK_KEYSTROKE_MAX_LENGTH + 5);
        let (skipped, strokes) = replay(&big);
        assert_eq!(strokes.len(), SLOPDESK_KEYSTROKE_MAX_LENGTH);
        assert_eq!(skipped, 5);
    }
}
