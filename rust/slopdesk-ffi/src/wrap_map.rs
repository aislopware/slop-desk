//! The find bar's logical-line → physical-row mapping, in C —
//! `Sources/SlopDeskWorkspaceCore/Terminal/ScrollbackWrapMapper.swift`.
//!
//! The rule is [`slopdesk_terminal::wrap_map`]; what is here is the marshalling. One door, one
//! answer: the physical grid row a logical scrollback line starts on.
//!
//! ## Why the whole mirror crosses at once
//!
//! This is the port that exists for the CROSSING COUNT rather than for the arithmetic. The Swift
//! loop it replaces called [`crate::link_detect::slopdesk_link_text_cells`] once per scrollback
//! line — a door of its own, already — so mapping a match at logical line N cost N crossings, each
//! lending one string and answering one `usize`. The lines now go over as a single flat
//! `(blob, lengths)` pair and the loop runs on the far side, where a width is a call into
//! [`slopdesk_terminal::link`] and not a call into another language. N crossings became one.
//!
//! The list shape is the one [`crate::link_detect::slopdesk_link_scan`] and
//! [`crate::hint_scan::slopdesk_hint_scan`] already take, down to the argument order: a flat UTF-8
//! blob, a byte length per entry, and the count. Nothing here invents a second way to hand this
//! crate a list of rows — a caller that can build the link scan's arguments can build these, and
//! `link_detect::split` is the same reader on this side.
//!
//! ## Why the answer needs no `(out, cap)` and no refusal
//!
//! The answer is one row number, so it is `size_t` by value in the shape
//! [`crate::link_detect::slopdesk_link_text_cells`] already has, and §4's "`0` means no answer"
//! does not apply because there is no buffer to size. That matters more than it sounds: physical
//! row `0` is the single most common answer this door gives — it is where the top of the scrollback
//! is — and a convention that spent `0` on a refusal would have had nowhere to put it. There is no
//! refusal to spend it on. Every input has a row: an unknown grid width degrades to the identity, a
//! bogus index reads as zero, and an index past the mirror's end counts phantom rows. All three of
//! those are the wrapped crate's decisions, which is why this file has no branch in it.
//!
//! ## Why the two counts are `intptr_t`
//!
//! Both arrive from a Swift `Int` in which a negative value carries meaning — `columns <= 0` is
//! "the grid width is unknown", which the rule answers with the identity. Declaring them `size_t`
//! would turn `-1` into `SIZE_MAX` on the way in, and the rule would answer a question nobody
//! asked. The sign is part of the argument, so it travels; see `slopdesk_terminal::wrap_map` for
//! what each sign means.

use core::ffi::c_uchar;

use slopdesk_terminal::wrap_map;

use crate::link_detect::split;
use crate::{borrow, records_of};

/// The physical (wrapped) grid row that logical scrollback line `logical_line` starts on.
///
/// `lines` is the scrollback mirror as one flat UTF-8 blob with a BYTE length per line in
/// `line_lengths`, `line_count` entries long — the same shape the link and hint scans take their
/// rows in. `columns` is the live grid width in cells; `0` or negative means the caller could not
/// resolve it, and the answer degrades to the identity.
///
/// Answers a row for every input. There is no refusal, so `0` is a real row — the top of the
/// scrollback — rather than §4's "no answer".
///
/// # Safety
/// `(lines, lines_len)` and `(line_lengths, line_count)` must each be null or describe live,
/// unaliased memory for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both lists are the caller's memory"
)]
pub unsafe extern "C" fn slopdesk_scrollback_physical_row(
    lines: *const c_uchar,
    lines_len: usize,
    line_lengths: *const usize,
    line_count: usize,
    logical_line: isize,
    columns: isize,
) -> usize {
    // SAFETY: the caller's contract — both pairs are live for this call, or null, which borrows as
    // empty. Swift's array-to-pointer conversion scopes them to exactly this call.
    let text = split(unsafe { borrow(lines, lines_len) }, unsafe {
        records_of(line_lengths, line_count)
    });
    let rows: Vec<&str> = text.iter().map(String::as_str).collect();
    wrap_map::physical_row(logical_line, &rows, columns)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::slopdesk_scrollback_physical_row;

    /// Flattens a list of lines the way the Swift face does — one blob, one BYTE length per entry.
    fn flatten(lines: &[&str]) -> (Vec<u8>, Vec<usize>) {
        let mut blob = Vec::new();
        let mut lengths = Vec::with_capacity(lines.len());
        for line in lines {
            blob.extend_from_slice(line.as_bytes());
            lengths.push(line.len());
        }
        (blob, lengths)
    }

    fn row(logical_line: isize, lines: &[&str], columns: isize) -> usize {
        let (blob, lengths) = flatten(lines);
        // SAFETY: both pairs are live locals for the duration of the call.
        unsafe {
            slopdesk_scrollback_physical_row(
                blob.as_ptr(),
                blob.len(),
                lengths.as_ptr(),
                lengths.len(),
                logical_line,
                columns,
            )
        }
    }

    #[test]
    fn the_mirror_crosses_once_and_the_walk_lands_where_the_rule_says() {
        assert_eq!(row(2, &["abcdefgh", "ij", "klmnopqrstuv"], 4), 3);
        assert_eq!(row(1, &["abcd", "x"], 4), 1, "exactly `columns` wide is one row");
        assert_eq!(row(1, &["abcde", "x"], 4), 2, "one cell past the edge is two");
    }

    #[test]
    fn a_byte_length_is_not_a_character_count() {
        // The whole hazard of the flat-blob shape: `文` is one character and three bytes, so a
        // face that sent character counts would split the blob mid-glyph and measure garbage. Six
        // cells at a width of four is two rows, and the second line has to still be reachable.
        assert_eq!(row(1, &["文文文", "x"], 4), 2);
        assert_eq!(row(2, &["文文文", "x"], 4), 3);
    }

    #[test]
    fn an_empty_list_is_not_a_refusal() {
        // Null pairs borrow as empty rather than as an error, and an index into an empty mirror is
        // all phantom rows — which is a real answer, so `0` here means row zero.
        // SAFETY: null pairs are the documented "empty" spelling.
        let answer =
            unsafe { slopdesk_scrollback_physical_row(core::ptr::null(), 0, core::ptr::null(), 0, 4, 80) };
        assert_eq!(answer, 4);
        assert_eq!(
            row(0, &["abcdefgh"], 4),
            0,
            "row zero is an answer, not a refusal"
        );
    }

    #[test]
    fn a_negative_count_keeps_its_sign_across_the_boundary() {
        // `intptr_t` rather than `size_t` is the whole point: as `size_t` these would arrive as
        // `SIZE_MAX` and the rule would answer a question nobody asked.
        assert_eq!(row(5, &["a very long line that would wrap", "short"], -1), 5);
        assert_eq!(row(-3, &["abcdefgh", "ij"], 4), 0);
    }
}
