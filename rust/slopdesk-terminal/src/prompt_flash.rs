//! WHERE the prompt-jump "landed" flash paints, as a walk over the viewport's text rows.
//!
//! A ⌘PageUp/⌘PageDown (or navigator) prompt jump replaces the whole viewport in one frame — the
//! eye has no scroll motion to follow, so the user lands with zero orientation. The overlay paints
//! ONE accent fade over the landed prompt row the instant the jump settles.
//!
//! Everything here is the ANSWER's geometry in CELLS. Turning a cell span into a rectangle needs
//! the surface's own metrics and belongs to whichever half is drawing; so does the alt-screen gate,
//! which is a decision about the pane's MODE rather than about the grid (an alt-screen TUI has no
//! prompt block to anchor to, so the honest answer is no flash at all — absent, never wrong).
//!
//! ## The two field reports this encodes
//!
//! The jump-to-prompt scroll (already Rust, not the engine's decision — `docs/68` §10) pins the
//! landed prompt at row 0, but the OSC-133 `A` mark is emitted at the PRE-PROMPT cursor position.
//! With a spacer-printing prompt — starship's default `add_newline` — the pinned row is that blank
//! spacer and the visible prompt text sits on row 1 or 2. A `row 0 is non-empty` guard therefore
//! made the flash never paint on a starship host at all.
//!
//! And a row whose text fills the whole grid width soft-wrapped, so the row below CONTINUES the
//! same logical line. The first fix flashed only the anchor row, which read as a truncated cue.

use unicode_segmentation::UnicodeSegmentation;

/// How far down the viewport the anchor search looks.
///
/// Three because that is the deepest a prompt block puts its first TEXT row: a spacer, then at most
/// a two-line prompt. Text beyond it is unrelated output further down the screen, and flashing that
/// would highlight a line the jump never landed on.
pub const SEARCH_DEPTH: usize = 3;

/// How many rows one flash may cover.
///
/// A pathological grid-filling line must not flash half the screen. Four is a wrapped prompt's
/// realistic ceiling and a cap rather than a measurement.
pub const MAX_ROWS: usize = 4;

/// One anchored row: which viewport row, and how many cells of it carry text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Anchor {
    /// The viewport row, counted from the top of the visible grid.
    pub row: usize,
    /// The row's GRAPHEME count.
    ///
    /// Under-measures a wide (2-cell) glyph's span, which is the acceptable direction: the flash
    /// covers the text from column 0 and just stops a few cells early on a CJK-heavy prompt. The
    /// wrap detection below errs the same safe way — a wide-glyph row reads as non-full, ending the
    /// walk early rather than over-flashing.
    pub cell_count: usize,
}

/// The viewport rows the flash anchors to: the first row with visible TEXT within [`SEARCH_DEPTH`],
/// plus that line's soft-wrap continuations.
///
/// A whitespace-only row never anchors — a space-flash reads as a rendering artifact — and an
/// all-blank landing answers empty. The walk stops at the first NON-FULL row (the logical line's
/// true end), at a blank row, or at [`MAX_ROWS`]. An exactly-grid-width line over-includes at most
/// one following row, which is benign next to under-flashing every wrapped prompt.
#[must_use]
pub fn anchor_rows(rows: &[&str], cols: usize) -> Vec<Anchor> {
    let Some(start) = rows.iter().take(SEARCH_DEPTH).position(|text| !is_blank(text)) else {
        return Vec::new();
    };

    let mut anchors = Vec::new();
    let mut row = start;
    while row < rows.len() && anchors.len() < MAX_ROWS {
        let cell_count = rows.get(row).map_or(0, |text| text.graphemes(true).count());
        if cell_count == 0 {
            break;
        }
        anchors.push(Anchor { row, cell_count });
        // A row short of the grid width is the logical line's end. `cols == 0` is a surface with no
        // usable width, and ends the walk rather than treating every row as a continuation.
        if cols == 0 || cell_count < cols {
            break;
        }
        row += 1;
    }
    anchors
}

/// Whether a row carries no visible text.
///
/// The Swift this replaces trimmed `CharacterSet.whitespaces`, which is the space separators plus
/// tab and NOT the line breaks; this asks `char::is_whitespace`, which is those plus the breaks.
/// The difference is unreachable rather than tolerated: these are VIEWPORT rows, already cut at the
/// line boundary by whoever read the grid, so no row here contains one.
fn is_blank(text: &str) -> bool {
    text.chars().all(char::is_whitespace)
}

#[cfg(test)]
mod tests {
    use super::{Anchor, MAX_ROWS, anchor_rows};

    fn rows_of(rows: &[&str], cols: usize) -> Vec<(usize, usize)> {
        anchor_rows(rows, cols)
            .into_iter()
            .map(|Anchor { row, cell_count }| (row, cell_count))
            .collect()
    }

    /// A grid comfortably wider than every unwrapped fixture row, so only the wrap tests wrap.
    const WIDE: usize = 80;

    #[test]
    fn a_direct_prompt_on_row_zero_anchors_there() {
        assert_eq!(rows_of(&["user@host ~ %", "output"], WIDE), vec![(0, 13)]);
    }

    /// The exact shape that hid the flash in the field: OSC-133 A on the blank spacer, the two-line
    /// starship prompt below it.
    #[test]
    fn the_starship_spacer_row_is_skipped_to_the_visible_prompt() {
        let info = "slop-desk on main [!] via v6.3.2";
        assert_eq!(
            rows_of(&["", info, "❯ echo AAA"], WIDE),
            vec![(1, info.chars().count())],
            "the flash anchors to the block's first TEXT row, not the spacer",
        );
    }

    /// The second field report: a prompt line WIDER than the grid soft-wraps, so the flash must
    /// cover every continuation row.
    #[test]
    fn a_wrapped_prompt_line_flashes_every_continuation_row() {
        assert_eq!(
            rows_of(&["", "aaaaaaaaaa", "bbbbbbbbbb", "tail", "❯"], 10),
            vec![(1, 10), (2, 10), (3, 4)],
            "two full rows plus the line's short tail row",
        );
    }

    #[test]
    fn a_non_full_row_ends_the_line_before_the_input_row() {
        assert_eq!(
            rows_of(&["", "short info", "❯ next line"], WIDE),
            vec![(1, 10)],
            "a non-full row is the logical line's end",
        );
    }

    #[test]
    fn a_pathological_grid_filling_line_is_capped() {
        let rows = ["xxx"; 8];
        assert_eq!(
            anchor_rows(&rows, 3).len(),
            MAX_ROWS,
            "the cap is the whole point — never flash half the screen",
        );
    }

    #[test]
    fn a_whitespace_only_row_never_anchors() {
        assert_eq!(
            rows_of(&["   ", "❯"], WIDE),
            vec![(1, 1)],
            "a space-flash reads as a rendering artifact — skip it like a blank",
        );
    }

    #[test]
    fn an_all_blank_landing_is_absent_never_wrong() {
        assert!(
            anchor_rows(&["", "  ", ""], WIDE).is_empty(),
            "nothing to anchor to"
        );
        assert!(anchor_rows(&[], WIDE).is_empty(), "a torn-down surface is silent");
    }

    /// Text BEYOND the search depth must not anchor: flashing row 3 would highlight an unrelated
    /// output line far below the pinned prompt block.
    #[test]
    fn the_search_stays_within_the_prompt_block_window() {
        assert!(anchor_rows(&["", "", "", "way-below output"], WIDE).is_empty());
    }

    /// A grid with no usable width ends the walk rather than reading every row as a continuation.
    #[test]
    fn a_widthless_grid_anchors_one_row_and_stops() {
        assert_eq!(rows_of(&["prompt", "more"], 0), vec![(0, 6)]);
    }

    /// The count is GRAPHEMES, not scalars — a combining mark is one cell of text, not two.
    #[test]
    fn a_combining_mark_counts_as_the_one_cell_it_draws() {
        assert_eq!(rows_of(&["e\u{0301}cho"], WIDE), vec![(0, 4)]);
    }
}
