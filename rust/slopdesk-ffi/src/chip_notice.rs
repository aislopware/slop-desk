//! What a transient window-level cue SAYS, in C.
//!
//! ONE door for both answers, because the spoken form is built from the CUT detail and not from the
//! one that arrived: two doors would let a chip draw a clipped sentence while the screen reader
//! spoke the whole one, which is the same notice disagreeing with itself.
//!
//! The three strings arrive as `docs/55` §4b's arena and spans rather than as three `(ptr, len)`
//! pairs, which keeps the crossing to one lifetime and one scope — and lets the keycap be ABSENT
//! rather than empty, which is the difference between a notice that offers nothing and one that
//! offers a chord it forgot to name.

use core::ffi::c_uchar;

use slopdesk_workspace::chip_notice;

use crate::workspace::{Span, borrow_array, text_of};
use crate::{borrow, deliver, push_text};

/// How many spans [`slopdesk_ws_chip_notice`] reads, in its own order: the label, the keycap and
/// the detail.
pub const NOTICE_SPANS: usize = 3;

/// The detail as the chip may draw it, then the whole notice as one string for the reader that has
/// no keycap to press.
///
/// A span array of the wrong length answers NOTHING rather than reading a neighbour's slot: the
/// three are positional, and a layout disagreement must lose the notice rather than print the
/// keycap where the label goes.
///
/// # Safety
/// `(blob, blob_len)` must be null, or name `blob_len` initialised bytes live for the call;
/// `(spans, span_count)` likewise for `span_count` spans; `(out, cap)` must be writable for `cap`
/// bytes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_ws_chip_notice(
    blob: *const c_uchar,
    blob_len: usize,
    spans: *const Span,
    span_count: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(blob, blob_len) };
    // SAFETY: ditto.
    let spans = unsafe { borrow_array(spans, span_count) };
    if spans.len() != NOTICE_SPANS {
        return 0;
    }
    let at = |index: usize| spans.get(index).and_then(|span| text_of(*span, bytes));
    let label = at(0).unwrap_or_default();
    let detail = chip_notice::capped(at(2).unwrap_or_default());
    let mut answer = Vec::with_capacity(detail.len() * 2 + 32);
    push_text(&mut answer, &detail);
    push_text(
        &mut answer,
        &chip_notice::accessibility_text(label, at(1), &detail),
    );
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_workspace::chip_notice::DETAIL_CAP;

    use super::{NOTICE_SPANS, slopdesk_ws_chip_notice};
    use crate::testing::delivered;
    use crate::workspace::Span;

    /// Packs three optional strings into one arena and reads the door's two runs back.
    fn notice(label: &str, keycap: Option<&str>, detail: &str) -> Vec<String> {
        let mut blob = Vec::new();
        let mut spans = Vec::new();
        for text in [Some(label), keycap, Some(detail)] {
            let Some(text) = text else {
                spans.push(Span {
                    offset: 0,
                    len: 0,
                    present: false,
                });
                continue;
            };
            let offset = blob.len();
            blob.extend_from_slice(text.as_bytes());
            spans.push(Span {
                offset,
                len: text.len(),
                present: true,
            });
        }
        // SAFETY: every pointer names a live local for the duration of the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_chip_notice(blob.as_ptr(), blob.len(), spans.as_ptr(), spans.len(), out, cap)
        });
        let mut runs = Vec::new();
        let mut cursor = 0;
        while let Some(four) = answer
            .get(cursor..cursor + 4)
            .and_then(|four| <[u8; 4]>::try_from(four).ok())
        {
            let length = u32::from_be_bytes(four) as usize;
            cursor += 4;
            let Some(run) = answer.get(cursor..cursor + length) else {
                break;
            };
            runs.push(String::from_utf8_lossy(run).into_owned());
            cursor += length;
        }
        runs
    }

    #[test]
    fn both_halves_cross_together_and_the_chord_reads_where_it_is_drawn() {
        let runs = notice("Tab closed", Some("⇧⌘T"), "reopens");
        assert_eq!(runs, ["reopens", "Tab closed · ⇧⌘T reopens"]);
    }

    /// The keycap is ABSENT rather than empty for a notice that offers nothing — and the absence is
    /// what stops the separator being left hanging.
    #[test]
    fn an_absent_chord_is_not_an_empty_one() {
        assert_eq!(notice("Reply sent", None, "to slopdesk"), [
            "to slopdesk",
            "Reply sent · to slopdesk"
        ]);
        assert_eq!(notice("Reply sent", None, ""), ["", "Reply sent"]);
    }

    /// The spoken form is built from the CUT detail, so a chip and a screen reader can never
    /// disagree about how much of the notice there is.
    #[test]
    fn the_spoken_form_carries_the_same_cut_the_chip_draws() {
        let long = "z".repeat(DETAIL_CAP + 12);
        let runs = notice("Tab closed", None, &long);
        let cut = runs.first().cloned().unwrap_or_default();
        assert_eq!(cut.chars().count(), DETAIL_CAP);
        assert_eq!(
            runs.get(1).cloned().unwrap_or_default(),
            format!("Tab closed · {cut}")
        );
    }

    /// A layout disagreement must lose the notice whole — printing the keycap where the label goes
    /// would be a sentence nobody wrote.
    #[test]
    fn a_short_span_array_answers_nothing_rather_than_shifting_a_slot() {
        let spans = [Span {
            offset: 0,
            len: 0,
            present: false,
        }; NOTICE_SPANS - 1];
        // SAFETY: both pointers name live locals for the duration of the call.
        let answer = delivered(|out, cap| unsafe {
            slopdesk_ws_chip_notice(std::ptr::null(), 0, spans.as_ptr(), spans.len(), out, cap)
        });
        assert!(answer.is_empty());
    }
}
