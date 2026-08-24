//! The hint overlay's badges and its words, in C.
//!
//! The rules are `slopdesk_workspace::hint_overlay`; what is here is the marshalling.
//!
//! What does NOT cross is the ASSIGNMENT — which label lands on which target, and which labels a
//! typed prefix keeps. That is `slopdesk_ws_hint_*` in [`crate::hint_scan`] already, and this
//! module is only what the badges then SAY and how they are drawn.

use core::ffi::c_uchar;

use slopdesk_workspace::hint_overlay::{self, Word};

use crate::workspace::{Span, text_of};
use crate::{borrow, deliver, push_text, records_of};

/// Every word the overlay says, in one delivery.
///
/// ```text
/// 3 × [u32 length][UTF-8 bytes]   // `Word::ALL`'s own order
/// ```
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_hint_overlay_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in Word::ALL {
        push_text(&mut blob, word.text());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Whether the overlay may draw at all: armed, and with a cell size to place badges against.
///
/// `0` for either metric is exactly what a caller holding no snapshot has, which is why they cross
/// as plain scalars rather than as an optional pair.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_hint_overlay_is_armed(armed: bool, cell_width: f64, cell_height: f64) -> bool {
    hint_overlay::is_armed(armed, cell_width, cell_height)
}

/// Whether the character at `offset` of a label draws faded — the typed prefix has reached it.
///
/// `typed` is counted in CHARACTERS by the rule, not in bytes.
///
/// # Safety
/// `(typed, typed_len)` must be null, or describe `typed_len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_hint_overlay_is_faded(
    offset: usize,
    typed: *const c_uchar,
    typed_len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let typed = String::from_utf8_lossy(unsafe { borrow(typed, typed_len) });
    hint_overlay::is_faded(offset, &typed)
}

/// Whether a badge is DIMMED — the typed prefix ruled its label out.
///
/// `matched` is the label set the assigner kept, as spans into `blob`; an ABSENT span names no
/// label and is skipped. Ruled-out badges are dimmed rather than removed, and the rule's own header
/// says why.
///
/// # Safety
/// `(label, label_len)` and `(blob, blob_len)` must be readable for the call, and `matched` must be
/// null or point to `matched_count` initialised [`Span`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_hint_overlay_dimmed(
    label: *const c_uchar,
    label_len: usize,
    matched: *const Span,
    matched_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; each borrow dies with this call.
    let (label, lent, spans) = unsafe {
        (
            String::from_utf8_lossy(borrow(label, label_len)),
            borrow(blob, blob_len),
            records_of(matched, matched_count),
        )
    };
    let kept: Vec<&str> = spans.iter().filter_map(|span| text_of(*span, lent)).collect();
    hint_overlay::dimmed(&label, &kept)
}

/// A badge's three readings, in one delivery: as drawn, as `VoiceOver` reads it, and the mode
/// badge's own accessibility label for `intent`.
///
/// ```text
/// 3 × [u32 length][UTF-8 bytes]
/// ```
///
/// All three derive from the same pair of inputs and are wanted together when a badge is built, so
/// they ride together rather than as three crossings per badge per keystroke.
///
/// # Safety
/// `(label, label_len)` and `(intent, intent_len)` must be readable for the call, and `(out, cap)`
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_hint_overlay_badge(
    label: *const c_uchar,
    label_len: usize,
    intent: *const c_uchar,
    intent_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; both borrows die with this call.
    let (label, intent) = unsafe {
        (
            String::from_utf8_lossy(borrow(label, label_len)),
            String::from_utf8_lossy(borrow(intent, intent_len)),
        )
    };
    let mut blob = Vec::new();
    push_text(&mut blob, &hint_overlay::display_label(&label));
    push_text(&mut blob, &hint_overlay::label_accessibility(&label));
    push_text(&mut blob, &hint_overlay::badge_accessibility_label(&intent));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::hint_overlay::{self, Word};

    use super::{
        slopdesk_ws_hint_overlay_badge, slopdesk_ws_hint_overlay_dimmed, slopdesk_ws_hint_overlay_is_armed,
        slopdesk_ws_hint_overlay_is_faded, slopdesk_ws_hint_overlay_words,
    };
    use crate::testing::{delivered, runs};
    use crate::workspace::Span;

    #[test]
    fn every_word_crosses_in_its_own_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_hint_overlay_words(out, cap) }
        });
        let words = runs(&blob, Word::ALL.len());
        for (index, word) in Word::ALL.into_iter().enumerate() {
            assert_eq!(
                words.get(index).map(String::as_str),
                Some(word.text()),
                "{word:?}"
            );
        }
    }

    #[test]
    fn a_caller_with_no_cell_size_never_arms_the_overlay() {
        assert!(slopdesk_ws_hint_overlay_is_armed(true, 7.0, 15.0));
        assert!(!slopdesk_ws_hint_overlay_is_armed(true, 0.0, 15.0));
        assert!(!slopdesk_ws_hint_overlay_is_armed(true, 7.0, 0.0));
        assert!(!slopdesk_ws_hint_overlay_is_armed(false, 7.0, 15.0));
    }

    #[test]
    fn the_typed_prefix_fades_exactly_the_characters_it_reached() {
        for (offset, typed) in [(0_usize, ""), (0, "a"), (1, "a"), (1, "ab")] {
            let bytes = typed.as_bytes().to_vec();
            // SAFETY: `bytes` is a live local for the call.
            let faded = unsafe { slopdesk_ws_hint_overlay_is_faded(offset, bytes.as_ptr(), bytes.len()) };
            assert_eq!(faded, hint_overlay::is_faded(offset, typed), "{offset} {typed:?}");
        }
    }

    /// Crosses one label against a kept set.
    fn dimmed(label: &str, matched: &[&str]) -> bool {
        let mut blob: Vec<u8> = Vec::new();
        let spans: Vec<Span> = matched
            .iter()
            .map(|text| {
                let offset = blob.len();
                blob.extend_from_slice(text.as_bytes());
                Span {
                    offset,
                    len: blob.len() - offset,
                    present: true,
                }
            })
            .collect();
        let label_bytes = label.as_bytes().to_vec();
        // SAFETY: every pointer is a live local for the call.
        unsafe {
            slopdesk_ws_hint_overlay_dimmed(
                label_bytes.as_ptr(),
                label_bytes.len(),
                spans.as_ptr(),
                spans.len(),
                blob.as_ptr(),
                blob.len(),
            )
        }
    }

    #[test]
    fn a_ruled_out_label_dims_and_a_kept_one_does_not() {
        assert!(!dimmed("as", &["as", "df"]));
        assert!(dimmed("gh", &["as", "df"]));
        assert!(dimmed("as", &[]), "an empty kept set rules everything out");
    }

    #[test]
    fn a_badges_three_readings_cross_together() {
        let (label, intent) = (b"as".to_vec(), b"Open".to_vec());
        let blob = delivered(|out, cap| {
            // SAFETY: every pointer is a live local for the call.
            unsafe {
                slopdesk_ws_hint_overlay_badge(
                    label.as_ptr(),
                    label.len(),
                    intent.as_ptr(),
                    intent.len(),
                    out,
                    cap,
                )
            }
        });
        let words = runs(&blob, 3);
        assert_eq!(words.first().map(String::as_str), Some("AS"));
        assert_eq!(
            words.get(1).cloned(),
            Some(hint_overlay::label_accessibility("as")),
        );
        assert_eq!(
            words.get(2).cloned(),
            Some(hint_overlay::badge_accessibility_label("Open")),
        );
    }
}
