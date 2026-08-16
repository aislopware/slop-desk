//! vi word/column motions over ONE terminal row, in display CELL columns.
//!
//! The horizontal half of the copy-mode cursor engine. Every function takes a row's text and a
//! column and answers a landing COLUMN within that row, or nothing when the motion runs off the
//! row's end — the caller wraps to the neighbouring row, because only the caller knows there is
//! one.
//!
//! ## Why this lives beside the link scanner
//!
//! Columns here are display cells, and they come from [`crate::link::scalar_cells`] over the same
//! grapheme clusters [`crate::link::detect`] measures its spans in. That is the whole reason the
//! motion is in this module and not in the view: a cursor landed by `w` and a hint badge claimed by
//! the link overlay must name the SAME column on a CJK row, and they can only be guaranteed to when
//! one clustering answers both. Two clusterings over one row is how a cursor lands half a glyph
//! away from the badge that says it is there, on exactly the rows nobody tests by hand.
//!
//! ## The word classes are vim's, not Unicode's
//!
//! A WORD run is alphabetic/numeric/underscore, a PUNCT run is any other non-blank, and whitespace
//! separates runs and is never a landing cell. Class is read off the cluster's FIRST scalar, which
//! is also where its width comes from — `e` plus a combining acute is one letter one cell wide, and
//! asking the combining mark would answer neither.

use crate::link::{clusters, scalar_cells};

/// vim's three small-word character classes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Class {
    /// A separator. Never a landing cell, and never part of a run.
    Whitespace,
    /// Alphabetic, numeric, or `_` — vim's small word.
    Word,
    /// Any other non-blank.
    Punct,
}

/// One display cell: the column it starts at, and the first scalar of the cluster occupying it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Cell {
    /// The display column this cluster begins at.
    pub col: usize,
    /// The cluster's base scalar — what its width and its class are both read from.
    pub scalar: char,
}

/// The class of one scalar.
#[must_use]
pub fn class(scalar: char) -> Class {
    if scalar.is_whitespace() {
        Class::Whitespace
    } else if scalar.is_alphabetic() || scalar.is_numeric() || scalar == '_' {
        Class::Word
    } else {
        Class::Punct
    }
}

/// A row's display cells, one entry per non-zero-width cluster carrying the column it starts at.
///
/// Zero-width clusters are dropped rather than given a column: they attach to the preceding base
/// and can never carry a cursor, so a motion that landed on one would put the caret nowhere
/// visible.
#[must_use]
pub fn cells(line: &str) -> Vec<Cell> {
    let mut out = Vec::new();
    let mut col = 0_usize;
    for cluster in clusters(line) {
        let Some(scalar) = cluster.chars().next() else {
            continue;
        };
        let width = scalar_cells(scalar);
        if width == 0 {
            continue;
        }
        out.push(Cell { col, scalar });
        col = col.saturating_add(width);
    }
    out
}

/// The row's cursor-ADDRESSABLE cells: [`cells`] trimmed of TRAILING whitespace.
///
/// A terminal row right-pads to the grid width, so trailing blanks are padding rather than text.
/// The vi cursor lives on the text only, the way vim's and tmux's do — it follows the line, not the
/// grid.
#[must_use]
pub fn addressable_cells(line: &str) -> Vec<Cell> {
    let mut cells = cells(line);
    while cells
        .last()
        .is_some_and(|cell| class(cell.scalar) == Class::Whitespace)
    {
        cells.pop();
    }
    cells
}

/// `^` — the first non-blank cell's column, or `0` on a blank row.
#[must_use]
pub fn first_non_blank(line: &str) -> usize {
    cells(line)
        .iter()
        .find(|cell| class(cell.scalar) != Class::Whitespace)
        .map_or(0, |cell| cell.col)
}

/// `$` — the LAST non-blank cell's column, or nothing on a blank row (the caller keeps column 0).
#[must_use]
pub fn last_non_blank(line: &str) -> Option<usize> {
    cells(line)
        .iter()
        .rfind(|cell| class(cell.scalar) != Class::Whitespace)
        .map(|cell| cell.col)
}

/// `w` — the start of the NEXT word/punct run after `col`, or nothing when the motion runs off the
/// row.
///
/// Leaving the current run and changing class both count as a new run, which is what makes vim step
/// `foo(bar` as `f` → `(` → `b` rather than treating it as one word.
#[must_use]
pub fn next_word_start(line: &str, col: usize) -> Option<usize> {
    let cells = cells(line);
    let start = index_of(col, &cells)?;
    let start_class = class(cells.get(start)?.scalar);
    let mut i = start;
    // Skip the rest of the current run. Whitespace has no run to skip — fall straight through.
    if start_class != Class::Whitespace {
        while cells
            .get(i.saturating_add(1))
            .is_some_and(|cell| class(cell.scalar) == start_class)
        {
            i = i.saturating_add(1);
        }
    }
    // Step past the run, then past any whitespace, landing on the next run's first cell.
    i = i.saturating_add(1);
    while cells
        .get(i)
        .is_some_and(|cell| class(cell.scalar) == Class::Whitespace)
    {
        i = i.saturating_add(1);
    }
    cells.get(i).map(|cell| cell.col)
}

/// `b` — the start of the CURRENT run when the cursor sits inside one past its first cell, else the
/// start of the PREVIOUS run; nothing when the motion runs off the row's start.
#[must_use]
pub fn prev_word_start(line: &str, col: usize) -> Option<usize> {
    let cells = cells(line);
    let i = index_of(col, &cells)?;
    let start_class = class(cells.get(i)?.scalar);
    let run_start = run_start_index(&cells, i);
    if start_class != Class::Whitespace && cells.get(run_start).is_some_and(|cell| cell.col < col) {
        // Inside a run past its first cell → land on this run's start.
        return cells.get(run_start).map(|cell| cell.col);
    }
    // At a run's first cell (or on whitespace) → walk left past whitespace to the previous run.
    let mut j = run_start;
    loop {
        j = j.checked_sub(1)?;
        if class(cells.get(j)?.scalar) != Class::Whitespace {
            break;
        }
    }
    cells.get(run_start_index(&cells, j)).map(|cell| cell.col)
}

/// `e` — the END of the current run when the cursor is before it, else the end of the NEXT run;
/// nothing when the motion runs off the row.
#[must_use]
pub fn word_end(line: &str, col: usize) -> Option<usize> {
    let cells = cells(line);
    let mut i = index_of(col, &cells)?;
    if class(cells.get(i)?.scalar) != Class::Whitespace {
        let end = run_end_index(&cells, i);
        let end_col = cells.get(end)?.col;
        if end_col > col {
            return Some(end_col);
        }
        i = end;
    }
    // At the current run's end (or on whitespace) → step to the next run and land on ITS end.
    i = i.saturating_add(1);
    while cells
        .get(i)
        .is_some_and(|cell| class(cell.scalar) == Class::Whitespace)
    {
        i = i.saturating_add(1);
    }
    cells.get(i)?;
    cells.get(run_end_index(&cells, i)).map(|cell| cell.col)
}

/// The start of the row's final word/punct run, or nothing on a blank row — where a backward (`b`)
/// wrap lands on the previous row.
#[must_use]
pub fn last_word_start(line: &str) -> Option<usize> {
    let cells = cells(line);
    let mut i = cells.len().checked_sub(1)?;
    loop {
        if class(cells.get(i)?.scalar) != Class::Whitespace {
            break;
        }
        i = i.checked_sub(1)?;
    }
    cells.get(run_start_index(&cells, i)).map(|cell| cell.col)
}

/// `h`/`l` — the landing column `delta` GLYPHS from `col` over the addressable cells.
///
/// A wide glyph is ONE step, and the walk clamps at the row's first and last text cell: vim's `h`
/// and `l` never leave the row. A cursor sitting in the trailing padding steps back INTO the text,
/// and a blank row pins column 0.
#[must_use]
pub fn column_step(line: &str, col: usize, delta: isize) -> usize {
    let cells = addressable_cells(line);
    let Some(last) = cells.len().checked_sub(1) else {
        return 0;
    };
    let index = cells.iter().rposition(|cell| cell.col <= col).unwrap_or(0);
    let landed = if delta >= 0 {
        index.saturating_add(delta.unsigned_abs()).min(last)
    } else {
        index.saturating_sub(delta.unsigned_abs())
    };
    cells.get(landed).map_or(0, |cell| cell.col)
}

/// The column of the addressable cell CONTAINING `col` — the snap a vertical motion applies after
/// its curswant clamp, so a cursor never sits mid-glyph or out in the trailing padding.
///
/// Past the row's extent snaps to the last text cell; a blank row to column 0.
#[must_use]
pub fn snap_to_cell(line: &str, col: usize) -> usize {
    addressable_cells(line)
        .iter()
        .rfind(|cell| cell.col <= col)
        .map_or(0, |cell| cell.col)
}

/// The display width of the glyph AT `col`, which is the block cursor's drawn width — so a wide
/// glyph wears a full-width block instead of half a cell. Blank and out-of-range cells read as `1`.
#[must_use]
pub fn cell_width(line: &str, col: usize) -> usize {
    cells(line)
        .iter()
        .find(|cell| cell.col == col)
        .map_or(1, |cell| scalar_cells(cell.scalar).max(1))
}

/// The index of the cell CONTAINING `col` — a cursor mid-wide-glyph belongs to that glyph — or
/// nothing for an empty row.
///
/// Columns increase along the row, so the LAST cell starting at or before `col` is the one covering
/// it. A `col` past the final cell answers that final cell rather than nothing: the caller clamps
/// to the grid, not to the text, and a motion from the padding is a motion from the row's end.
fn index_of(col: usize, cells: &[Cell]) -> Option<usize> {
    cells.iter().rposition(|cell| cell.col <= col)
}

/// The index of the first cell of the same-class run containing `i` (whitespace is its own run).
fn run_start_index(cells: &[Cell], i: usize) -> usize {
    let Some(cls) = cells.get(i).map(|cell| class(cell.scalar)) else {
        return i;
    };
    let mut j = i;
    while let Some(previous) = j.checked_sub(1) {
        if cells.get(previous).is_some_and(|cell| class(cell.scalar) == cls) {
            j = previous;
        } else {
            break;
        }
    }
    j
}

/// The index of the last cell of the same-class run containing `i`.
fn run_end_index(cells: &[Cell], i: usize) -> usize {
    let Some(cls) = cells.get(i).map(|cell| class(cell.scalar)) else {
        return i;
    };
    let mut j = i;
    while cells
        .get(j.saturating_add(1))
        .is_some_and(|cell| class(cell.scalar) == cls)
    {
        j = j.saturating_add(1);
    }
    j
}

#[cfg(test)]
mod tests {
    use super::{
        Class, cell_width, cells, class, column_step, first_non_blank, last_non_blank, last_word_start,
        next_word_start, prev_word_start, snap_to_cell, word_end,
    };

    #[test]
    fn the_classes_are_vims_three_and_underscore_is_a_word() {
        assert_eq!(class(' '), Class::Whitespace);
        assert_eq!(class('\t'), Class::Whitespace);
        assert_eq!(class('a'), Class::Word);
        assert_eq!(class('7'), Class::Word);
        assert_eq!(class('_'), Class::Word);
        assert_eq!(class('('), Class::Punct);
        assert_eq!(class('-'), Class::Punct);
    }

    #[test]
    fn a_wide_glyph_advances_two_columns_and_a_combiner_none() {
        let cols: Vec<usize> = cells("a中b").iter().map(|cell| cell.col).collect();
        assert_eq!(cols, vec![0, 1, 3]);
        // `e` + U+0301 is ONE cell, and the mark never gets a column of its own.
        let cols: Vec<usize> = cells("e\u{301}x").iter().map(|cell| cell.col).collect();
        assert_eq!(cols, vec![0, 1]);
    }

    #[test]
    fn the_row_ends_are_the_text_not_the_padding() {
        assert_eq!(first_non_blank("    make check"), 4);
        assert_eq!(first_non_blank("    "), 0, "a blank row keeps column 0");
        assert_eq!(first_non_blank(""), 0);
        assert_eq!(last_non_blank("make check  "), Some(9));
        assert_eq!(last_non_blank("   "), None);
    }

    #[test]
    fn w_steps_on_a_class_change_as_well_as_a_gap() {
        let line = "foo(bar) baz";
        assert_eq!(next_word_start(line, 0), Some(3), "foo → (");
        assert_eq!(next_word_start(line, 3), Some(4), "( → bar");
        assert_eq!(next_word_start(line, 4), Some(7), "bar → )");
        assert_eq!(next_word_start(line, 7), Some(9), ") skips the space → baz");
        assert_eq!(next_word_start(line, 9), None, "off the last word wraps");
        assert_eq!(
            next_word_start("ab  cd", 2),
            Some(4),
            "from the gap → the next word"
        );
    }

    #[test]
    fn b_lands_on_the_current_runs_start_before_the_previous_ones() {
        let line = "foo(bar)";
        assert_eq!(prev_word_start("foo bar", 5), Some(4), "inside bar → its start");
        assert_eq!(prev_word_start(line, 4), Some(3), "at bar's start → (");
        assert_eq!(prev_word_start(line, 3), Some(0), "at ( → foo's start");
        assert_eq!(prev_word_start(line, 0), None, "at the row start wraps");
    }

    #[test]
    fn e_lands_on_a_run_end_and_the_columns_are_cells() {
        let line = "foo bar";
        assert_eq!(word_end(line, 0), Some(2), "inside foo → its end");
        assert_eq!(word_end(line, 2), Some(6), "AT foo's end → bar's end");
        assert_eq!(word_end(line, 6), None, "off the last word wraps");
        // A CJK word is two cells per glyph, so `w` off it lands at column 5, not 3.
        assert_eq!(next_word_start("中文 ab", 0), Some(5));
    }

    #[test]
    fn h_and_l_step_by_glyph_and_clamp_inside_the_row() {
        let line = "a 中 b";
        assert_eq!(
            column_step(line, 0, 1),
            1,
            "l steps onto the space, glyph by glyph"
        );
        assert_eq!(
            column_step(line, 0, 2),
            2,
            "two steps cross the space onto the wide glyph"
        );
        assert_eq!(column_step(line, 2, 1), 4, "a wide glyph is ONE step, not two");
        assert_eq!(column_step(line, 0, -1), 0, "h clamps at the row start");
        assert_eq!(column_step(line, 5, 3), 5, "l clamps at the last text cell");
        assert_eq!(column_step("", 7, 1), 0, "a blank row pins column 0");
    }

    #[test]
    fn a_cursor_snaps_onto_a_glyph_and_out_of_the_padding() {
        let line = "ab中  ";
        assert_eq!(
            snap_to_cell(line, 3),
            2,
            "mid-wide-glyph snaps to the glyph's start"
        );
        assert_eq!(
            snap_to_cell(line, 20),
            2,
            "past the extent snaps to the last text cell"
        );
        assert_eq!(snap_to_cell("", 9), 0);
    }

    #[test]
    fn the_block_cursor_wears_the_glyphs_own_width() {
        let line = "a中";
        assert_eq!(cell_width(line, 0), 1);
        assert_eq!(cell_width(line, 1), 2);
        assert_eq!(cell_width(line, 40), 1, "out-of-range reads as a plain cell");
    }

    #[test]
    fn the_backward_wrap_lands_on_the_previous_rows_last_run() {
        assert_eq!(last_word_start("foo bar  "), Some(4));
        assert_eq!(last_word_start("   "), None, "a blank row offers no run");
        assert_eq!(last_word_start(""), None);
    }
}
