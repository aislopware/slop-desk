//! Where the prompt-jump landed-flash paints, in C.
//!
//! The rules are `slopdesk_terminal::prompt_flash`; what is here is the marshalling.
//!
//! Only the CELL walk crosses. Turning an anchored `(row, cell_count)` into a rectangle needs the
//! surface's own metrics, and the alt-screen gate is a decision about the pane's MODE rather than
//! about the grid — both stay with whichever half is drawing, which is the same split every
//! decoration in this family keeps.

use core::ffi::c_uchar;

use slopdesk_terminal::prompt_flash::{self, Anchor};

use crate::workspace::{Span, borrow_array, text_of};
use crate::{borrow, deliver, saturating_u32};

/// The viewport rows the landed flash anchors to.
///
/// ```text
/// [u32 anchor_count]
/// anchor_count × [u32 row][u32 cell_count]
/// ```
///
/// `0` — nothing delivered — is an all-blank landing or a torn-down surface: absent, never wrong.
/// At most `SLOPDESK_PROMPT_FLASH_MAX_ROWS` anchors come back, so a caller may lend a fixed buffer
/// and never take the retry.
///
/// The rows are spans into ONE blob for the reason the rail's own list doors give: a `(ptr, len)`
/// per row would mean a borrow per row on a walk that is at most a handful of them and is asked
/// once per jump.
///
/// # Safety
/// `rows` must describe `row_count` live entries, `blob` must be readable for `blob_len` bytes, and
/// `(out, cap)` must be writable for `cap` bytes — all for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer here is the caller's"
)]
pub unsafe extern "C" fn slopdesk_prompt_flash_anchors(
    rows: *const Span,
    row_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    cols: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let bytes = unsafe { borrow(blob, blob_len) };
    // SAFETY: ditto.
    let spans = unsafe { borrow_array(rows, row_count) };
    // A span that cannot be read is a BLANK row rather than a missing one: the walk is positional,
    // and dropping a row would shift every anchor below it onto the wrong line.
    let texts: Vec<&str> = spans
        .iter()
        .map(|span| text_of(*span, bytes).unwrap_or_default())
        .collect();

    let anchors = prompt_flash::anchor_rows(&texts, cols);
    if anchors.is_empty() {
        return 0;
    }
    let mut answer = Vec::with_capacity(4 + anchors.len() * 8);
    answer.extend_from_slice(&saturating_u32(anchors.len()).to_be_bytes());
    for Anchor { row, cell_count } in anchors {
        answer.extend_from_slice(&saturating_u32(row).to_be_bytes());
        answer.extend_from_slice(&saturating_u32(cell_count).to_be_bytes());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::indexing_slicing,
        reason = "these blobs are the test's own, and a panic in a test is the failure report"
    )]

    use slopdesk_terminal::prompt_flash;

    use super::slopdesk_prompt_flash_anchors;
    use crate::testing::delivered;
    use crate::workspace::Span;

    /// The rows of one viewport, packed into one arena, walked across the door.
    fn anchors(rows: &[&str], cols: usize) -> Vec<(u32, u32)> {
        let mut arena = Vec::new();
        let spans: Vec<Span> = rows
            .iter()
            .map(|text| {
                let offset = arena.len();
                arena.extend_from_slice(text.as_bytes());
                Span {
                    offset,
                    len: arena.len() - offset,
                    present: true,
                }
            })
            .collect();
        let blob = delivered(|out, cap| {
            // SAFETY: `spans`, `arena` and `out` are live locals for the call.
            unsafe {
                slopdesk_prompt_flash_anchors(
                    spans.as_ptr(),
                    spans.len(),
                    arena.as_ptr(),
                    arena.len(),
                    cols,
                    out,
                    cap,
                )
            }
        });
        if blob.is_empty() {
            return Vec::new();
        }
        let word = |at: usize| u32::from_be_bytes([blob[at], blob[at + 1], blob[at + 2], blob[at + 3]]);
        (0..word(0) as usize)
            .map(|index| (word(4 + index * 8), word(8 + index * 8)))
            .collect()
    }

    #[test]
    fn the_walk_crosses_row_and_cell_count_in_viewport_order() {
        assert_eq!(anchors(&["", "aaaaaaaaaa", "bbbbbbbbbb", "tail", "❯"], 10), vec![
            (1, 10),
            (2, 10),
            (3, 4)
        ],);
    }

    #[test]
    fn an_all_blank_landing_crosses_as_nothing_delivered() {
        assert!(anchors(&["", "  ", ""], 80).is_empty());
        assert!(anchors(&[], 80).is_empty(), "a torn-down surface is silent");
    }

    /// The rule's cap bounds the longest possible walk, so `wsAnswerBytes`' first lend is always
    /// big enough and the retry never fires on this door.
    #[test]
    fn the_rules_cap_bounds_the_longest_possible_walk() {
        let rows = ["xxx"; 8];
        assert_eq!(anchors(&rows, 3).len(), prompt_flash::MAX_ROWS);
    }
}
