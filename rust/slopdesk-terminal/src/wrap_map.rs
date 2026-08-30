//! Logical (unwrapped) scrollback lines → the PHYSICAL grid row libghostty scrolls to.
//!
//! The ⌘F find bar and ⇧⌘F Global Search juggle two different row indexings and have to hand one to
//! the other. The scrollback text mirror (`ghostty_surface_read_text` with `unwrap = true`)
//! collapses a soft-wrapped line spanning N grid rows into ONE array entry, so a match's `line` is
//! a LOGICAL index. `scroll_to_row:` addresses `PageList` rows, where every wrap continuation
//! counts for itself. Feeding the first number into the second lands the viewport N rows too high,
//! N being the number of continuation rows ABOVE the target — a match highlighted off-screen, which
//! reads as the search simply not working. This is the sum that converts one into the other.
//!
//! ## Why it is in Rust rather than beside the find bar
//!
//! The Swift loop this replaced was already reaching across the FFI boundary once PER LINE:
//! `TerminalLinkDetector.displayCellWidth(of:)` is `slopdesk_link_text_cells`, so mapping a match
//! at logical line N cost N non-inlinable crossings, each one lending a string, walking its
//! grapheme clusters and answering a single `usize`. The clustering has to happen either way and it
//! happens here; what the port deletes is the N crossings. The lines now cross ONCE, as the flat
//! `(blob, lengths)` pair every list-of-strings door in this tree already takes, and the loop runs
//! on this side of the boundary where a line's width is a function call rather than a call into
//! another language. A ⇧⌘F hit near the bottom of a long scrollback is exactly the case where N is
//! large, and it is the only case anybody notices.
//!
//! The second thing it buys is that the WIDTH MEASURE cannot drift. The wrap arithmetic and the
//! cell table are now one file apart rather than one language apart: [`crate::link::text_cells`] is
//! called directly, with no crossing at all, so a change to the East-Asian-wide table moves the
//! find bar's scroll target in the same commit that moves the link overlay's columns.
//!
//! ## Why the two counts are SIGNED
//!
//! Both of this rule's numbers arrive from a Swift `Int` that is allowed to be negative, and in
//! both cases the negative value MEANS something. `columns <= 0` is the caller saying it could not
//! resolve the grid width at all — headless, or before the first layout — and the answer there is
//! the IDENTITY, so a caller that cannot measure the grid still scrolls exactly where the un-mapped
//! code did rather than somewhere invented. A negative logical index is a bogus one, and it reads
//! as row zero.
//!
//! Taking these as `usize` at the boundary would not have been a simplification, it would have been
//! a silent reinterpretation: `-1` arrives as `usize::MAX`, which for `columns` is a grid so wide
//! that every line fits on one row (identity by accident, and only for lines under `usize::MAX`
//! cells) and for `logical_line` is a walk over the whole mirror plus four billion phantom rows.
//! Both are wrong answers that no test would think to ask for, so the sign travels and the clamping
//! is stated here, once, where the reason for it can be read.
//!
//! ## The invariants, in one place
//!
//! - An empty or zero-width line still occupies exactly ONE physical row. A grid row is a row even
//!   when nothing was printed on it, and `ceil(0 / columns)` is `0`, which would slide every line
//!   below a blank one up by one.
//! - A line exactly `columns` wide is ONE row. Ghostty wraps PAST the edge, not at it.
//! - A logical index beyond the mirror's end contributes one physical row EACH. The mirror is a
//!   snapshot and the buffer it mirrors can shrink between the search and the scroll;
//!   under-counting there would silently scroll to the wrong place, and trapping would take the
//!   pane down for a stale index.
//! - There is no wrap indent. A continuation row starts at column zero, so the count is a plain
//!   `ceil(width / columns)` rather than a running fold.

use crate::link::text_cells;

/// The physical (wrapped) grid row that logical line `logical_line` STARTS on within `lines`, at a
/// grid `columns` cells wide.
///
/// Each logical line of display width `W` occupies `max(1, ceil(W / columns))` physical rows, and
/// the answer is the sum of those counts over every line ABOVE the target. Widths are display CELLS
/// from [`crate::link::text_cells`], so a fullwidth glyph is two and a combining mark is none — the
/// same measure the link overlay reports its columns in.
///
/// Degrades to the identity (`logical_line`, floored at zero) when `columns <= 0`, which is the
/// caller saying the grid width is unknown. A negative `logical_line` is row zero. Neither of those
/// can panic and neither reads a line.
#[must_use]
pub fn physical_row(logical_line: isize, lines: &[&str], columns: isize) -> usize {
    let logical_line = usize::try_from(logical_line).unwrap_or(0);
    let columns = usize::try_from(columns).unwrap_or(0);
    if columns == 0 || logical_line == 0 {
        return logical_line;
    }
    let mut row = 0_usize;
    for line in lines.iter().take(logical_line) {
        row = row.saturating_add(wrapped_row_count(line, columns));
    }
    // A logical index past the mirror's end — a stale snapshot of a buffer that has since shrunk —
    // contributes one physical row each. `saturating_sub` is the "only when it ran off the end"
    // test and the count in one expression.
    row.saturating_add(logical_line.saturating_sub(lines.len()))
}

/// The number of physical grid rows one logical line occupies at width `columns`: `1` for an empty
/// or zero-width line, else `ceil(display_width / columns)`.
///
/// `columns` is assumed non-zero — [`physical_row`] is the only caller and it has already answered
/// the unknown-width case without reaching here.
fn wrapped_row_count(line: &str, columns: usize) -> usize {
    let width = text_cells(line);
    if width == 0 {
        return 1;
    }
    width.div_ceil(columns)
}

#[cfg(test)]
mod tests {
    use super::physical_row;

    /// The Swift face's own argument order, so a case reads the way the door is called.
    fn row(line: isize, lines: &[&str], columns: isize) -> usize {
        physical_row(line, lines, columns)
    }

    #[test]
    fn an_unknown_grid_width_is_the_identity() {
        let lines = ["a very long line that would wrap", "short"];
        assert_eq!(row(1, &lines, 0), 1);
        assert_eq!(row(5, &lines, -1), 5, "a negative width is the same 'unknown'");
    }

    #[test]
    fn no_wrapping_leaves_the_physical_row_equal_to_the_logical_index() {
        let lines = ["abc", "de", "fghi"];
        assert_eq!(row(0, &lines, 4), 0);
        assert_eq!(row(1, &lines, 4), 1);
        assert_eq!(row(2, &lines, 4), 2);
    }

    #[test]
    fn a_wrapped_line_shifts_every_later_row_down() {
        let lines = ["abcdefgh", "ij", "klmnopqrstuv"];
        assert_eq!(
            row(0, &lines, 4),
            0,
            "the first line always starts at physical row 0"
        );
        assert_eq!(row(1, &lines, 4), 2, "after the two-row line 0");
        assert_eq!(row(2, &lines, 4), 3, "plus the one-row line 1");
    }

    #[test]
    fn the_grid_wraps_past_its_edge_and_not_at_it() {
        assert_eq!(row(1, &["abcd", "x"], 4), 1, "exactly `columns` wide is ONE row");
        assert_eq!(
            row(1, &["abcde", "x"], 4),
            2,
            "one cell past the edge takes a second"
        );
    }

    #[test]
    fn an_empty_line_still_occupies_one_physical_row() {
        assert_eq!(row(2, &["", "", "x"], 4), 2);
    }

    #[test]
    fn an_index_past_the_mirrors_end_counts_one_row_each_rather_than_trapping() {
        let lines = ["abcdefgh"];
        assert_eq!(row(1, &lines, 4), 2, "the one wrapped line");
        assert_eq!(row(3, &lines, 4), 4, "plus two phantom rows for indices 1 and 2");
        assert_eq!(
            row(9, &[], 4),
            9,
            "an empty mirror is phantom rows all the way down"
        );
    }

    #[test]
    fn east_asian_wide_glyphs_count_as_two_cells() {
        // Three fullwidth glyphs are 6 cells, which is two rows at a width of 4 — sooner than the
        // character count suggests, and the whole reason the width comes from the link table.
        assert_eq!(row(1, &["文文文", "x"], 4), 2);
    }

    #[test]
    fn a_negative_logical_index_reads_as_row_zero() {
        // The Swift guard this replaced was `max(0, logicalLine)`, and it applied whether or not
        // the grid width was known. Both arms are pinned so the clamp cannot quietly move
        // into one.
        assert_eq!(row(-1, &["abcdefgh", "ij"], 4), 0);
        assert_eq!(row(-7, &["abcdefgh", "ij"], 0), 0);
    }

    #[test]
    fn a_zero_width_line_is_not_a_zero_row_line() {
        // A line of nothing but combining marks measures zero cells and would otherwise vanish from
        // the sum, sliding every line under it up by one.
        assert_eq!(row(1, &["\u{0301}\u{0301}", "x"], 4), 1);
    }
}
