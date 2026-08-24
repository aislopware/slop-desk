//! The Command Navigator card's words and its two measurements, in C.
//!
//! The rules are `slopdesk_workspace::command_navigator`; what is here is the marshalling.
//!
//! The ranking, the list, the jump and the clamp are NOT here — each was already shared before the
//! rule module existed, and this only finishes the set with the card's own vocabulary.

use core::ffi::c_uchar;

use slopdesk_workspace::command_navigator::{self, Filter, Word};

use crate::global_search::CSearchPanelSize;
use crate::{deliver, push_text};

/// The card's fixed width and its results ceiling.
///
/// The same record the search overlay's frame crosses in, because it is the same two numbers about
/// the same kind of thing: a second struct spelling `{ width, height }` would be a shape the near
/// side reads twice.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_command_navigator_metrics() -> CSearchPanelSize {
    CSearchPanelSize {
        width: command_navigator::PANEL_WIDTH,
        height: command_navigator::RESULTS_MAX_HEIGHT,
    }
}

/// Every word the card says, in one delivery.
///
/// ```text
/// 11 × [u32 length][UTF-8 bytes]   // `Word::ALL`'s own order
/// ```
///
/// A hint's label and its cap ride as neighbouring runs rather than as one pre-joined string, so
/// neither renderer has to un-join a label to set the cap in its own type.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_command_navigator_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in Word::ALL {
        push_text(&mut blob, word.text());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The zero-state line for an empty list, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// `has_blocks` is the whole fork: a query that matched nothing blames the query, an empty segment
/// names the segment. An unrecognised `filter` reads as the widest one.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_command_navigator_empty_line(
    filter: u8,
    has_blocks: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut blob = Vec::new();
    push_text(
        &mut blob,
        command_navigator::empty_line(Filter::from_code(filter), has_blocks),
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::command_navigator::{self, Filter, Word};

    use super::{
        slopdesk_ws_command_navigator_empty_line, slopdesk_ws_command_navigator_metrics,
        slopdesk_ws_command_navigator_words,
    };
    use crate::testing::{delivered, runs};

    #[test]
    fn the_two_measurements_cross_unchanged() {
        let size = slopdesk_ws_command_navigator_metrics();
        assert!((size.width - command_navigator::PANEL_WIDTH).abs() < f64::EPSILON);
        assert!((size.height - command_navigator::RESULTS_MAX_HEIGHT).abs() < f64::EPSILON);
    }

    #[test]
    fn every_word_crosses_in_its_own_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_command_navigator_words(out, cap) }
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
    fn a_typed_query_and_an_empty_segment_cross_as_different_lines() {
        for filter in Filter::ALL {
            for has_blocks in [false, true] {
                let blob = delivered(|out, cap| {
                    // SAFETY: `out` is a live local for the call.
                    unsafe { slopdesk_ws_command_navigator_empty_line(filter.code(), has_blocks, out, cap) }
                });
                assert_eq!(
                    runs(&blob, 1).first().map(String::as_str),
                    Some(command_navigator::empty_line(filter, has_blocks)),
                    "{filter:?} {has_blocks}",
                );
            }
        }
    }

    #[test]
    fn an_unrecognised_segment_names_the_whole_pane() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_command_navigator_empty_line(200, false, out, cap) }
        });
        assert_eq!(
            runs(&blob, 1).first().map(String::as_str),
            Some(command_navigator::empty_line(Filter::All, false)),
        );
    }
}
