//! The text, the caret and the selection — the part of an editor that has to be right about
//! Unicode before anything above it can be.
//!
//! ## Why byte offsets rather than an index of graphemes
//!
//! The obvious model is a `Vec<String>` of clusters, or a cursor counted in graphemes. Both make
//! every edit O(n): a keystroke at the start of a 10 MB paste re-indexes ten million entries, and
//! the paste is the case that has to stay cheap. So the text is one [`String`] and every offset is
//! a byte offset — but one carrying an INVARIANT the type enforces at every door: a cursor is
//! always on a grapheme-cluster boundary. [`snap`] is the only way in, so a caller cannot construct
//! a cursor that splits a family emoji.
//!
//! Boundary steps go through `unicode_segmentation`'s [`GraphemeCursor`], which walks LOCALLY: one
//! arrow key costs the length of one cluster, not the length of the document. A line of 100 000
//! combining marks is one cluster and one step — slow to step over once, not slow per keystroke.
//!
//! ## Word motion is UAX #29's, and that is a different question from `vimotion`'s
//!
//! [`crate::vimotion`] also answers "where is the next word", and is deliberately NOT reused here.
//! It classes characters vim's way (alphanumeric-or-underscore versus punctuation) over DISPLAY
//! CELLS of a rendered terminal row, because a copy-mode cursor has to land on the same cell the
//! hint overlay claims. This module answers over the EDIT BUFFER in UAX #29 word boundaries,
//! because ⌥→ in a text field is the platform's segmentation and not vim's. Two contracts, two
//! callers, neither one a port of the other.
//!
//! ## Word motion stops at the line edge, on purpose
//!
//! A word motion never crosses a newline in one press: at the edge of a line it steps across, and
//! the press after that moves by a word. That keeps every word motion bounded by ONE logical line —
//! which matters because a newline is a hard word boundary in UAX #29 anyway, so restricting the
//! segmentation window to the line is exact rather than approximate. Only a single line longer than
//! [`WORD_WINDOW`] is approximated, and there the motion lands on the window edge rather than
//! scanning a 10 MB line on every arrow key.

use core::ops::Range;

use unicode_segmentation::{GraphemeCursor, UnicodeSegmentation};

use crate::link::text_cells;
use crate::prompt::undo::Edit;

/// How much of a single logical line a word motion will segment, in bytes.
///
/// Real text puts a word boundary every few bytes, so this is never reached by anything a human
/// typed. It exists for the pathological line — a 10 MB base64 blob with no boundary in it — where
/// landing on the window edge is a defined answer and re-segmenting ten megabytes per arrow key is
/// not.
pub const WORD_WINDOW: usize = 4096;

/// How much context a word motion reads on the far side of the cursor.
///
/// UAX #29 needs a little of what precedes a boundary to judge it (`don't` is one word, `a.b` is
/// three), and a few dozen bytes covers every rule that is not regional-indicator pairing.
const WORD_CONTEXT: usize = 64;

/// Which way a motion goes. On [`Motion::Line`] these mean up and down.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Direction {
    /// Toward the start of the document.
    Backward,
    /// Toward the end.
    Forward,
}

/// A cursor movement, named by what it means rather than by the key that sends it.
///
/// The keys are the view's business — ⌥→ on macOS and ⌃→ elsewhere are the same [`Motion::Word`] —
/// and every one of them is also a DELETION granularity, which is why [`TextBuffer::delete`] takes
/// the same enum rather than a second one spelling the same five things.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Motion {
    /// One grapheme cluster.
    Grapheme(Direction),
    /// To the far edge of the next UAX #29 word.
    Word(Direction),
    /// To the start or end of the current logical line.
    LineEdge(Direction),
    /// One logical line up or down, keeping the goal column.
    Line(Direction),
    /// To the start or end of the whole document.
    DocEdge(Direction),
}

/// A caret position expressed the way a renderer needs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LineColumn {
    /// Zero-based logical line — the count of newlines before the offset.
    pub line: usize,
    /// Display CELLS from the line's start, not graphemes: a CJK cluster is two, a combining mark
    /// is nought. The same [`crate::link::text_cells`] every other overlay measures with, so a
    /// caret and a link badge on one row cannot disagree about a column.
    pub column: usize,
}

/// The document, the caret and the selection anchor.
///
/// The selection is anchor+head rather than a range because the two ends are not interchangeable:
/// extending a selection moves the head and leaves the anchor, and a range would have to be
/// re-derived — losing which end the next shift-arrow should move.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TextBuffer {
    text: String,
    cursor: usize,
    anchor: usize,
    /// The column a vertical run is aiming at, so ↓ through a short line and back up returns to
    /// where it started. Cleared by every non-vertical motion.
    goal: Option<usize>,
}

impl TextBuffer {
    /// An empty buffer with the caret at the start.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            text: String::new(),
            cursor: 0,
            anchor: 0,
            goal: None,
        }
    }

    /// A buffer holding `text`, caret at the end — the shape a history recall or a draft restore
    /// wants.
    #[must_use]
    pub fn seeded(text: &str) -> Self {
        let mut buffer = Self::new();
        buffer.set_text(text);
        buffer
    }

    /// Replaces the whole document and puts the caret at its end, discarding any selection.
    ///
    /// Not an [`Edit`]: the callers are history recall and draft restore, which are not undoable
    /// steps of their own — the caller decides whether to record one.
    pub fn set_text(&mut self, text: &str) {
        self.text.clear();
        self.text.push_str(text);
        self.cursor = self.text.len();
        self.anchor = self.cursor;
        self.goal = None;
    }

    /// The document.
    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The document's length in bytes.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.text.len()
    }

    /// Whether there is nothing in it.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    /// The caret's byte offset, always on a grapheme boundary.
    #[must_use]
    pub const fn cursor(&self) -> usize {
        self.cursor
    }

    /// The selection's fixed end, equal to the caret when nothing is selected.
    #[must_use]
    pub const fn anchor(&self) -> usize {
        self.anchor
    }

    /// The selected byte range, low end first, or `None` when the selection is empty.
    #[must_use]
    pub const fn selection(&self) -> Option<Range<usize>> {
        if self.anchor == self.cursor {
            None
        } else if self.anchor < self.cursor {
            Some(self.anchor..self.cursor)
        } else {
            Some(self.cursor..self.anchor)
        }
    }

    /// The selected text, or `""`.
    #[must_use]
    pub fn selected_text(&self) -> &str {
        self.selection()
            .and_then(|range| self.text.get(range))
            .unwrap_or("")
    }

    /// Puts the caret at `offset`, snapped to a grapheme boundary, and collapses the selection.
    pub fn set_cursor(&mut self, offset: usize) {
        self.cursor = snap(&self.text, offset);
        self.anchor = self.cursor;
        self.goal = None;
    }

    /// Selects `anchor..head`, both snapped. The caret ends at `head`, so a following extend moves
    /// the end the caller last moved.
    pub fn set_selection(&mut self, anchor: usize, head: usize) {
        self.anchor = snap(&self.text, anchor);
        self.cursor = snap(&self.text, head);
        self.goal = None;
    }

    /// Selects everything, caret at the end.
    pub const fn select_all(&mut self) {
        self.anchor = 0;
        self.cursor = self.text.len();
        self.goal = None;
    }

    /// Drops the selection, keeping the caret.
    pub const fn collapse(&mut self) {
        self.anchor = self.cursor;
    }

    /// Where `motion` would land the caret, without moving it.
    ///
    /// A pure query so the same arithmetic answers a movement, an extension and a deletion — three
    /// callers, one rule, and a word-deletion that cannot disagree with a word-motion.
    #[must_use]
    pub fn target(&self, motion: Motion) -> usize {
        match motion {
            Motion::Grapheme(Direction::Forward) => next_grapheme(&self.text, self.cursor),
            Motion::Grapheme(Direction::Backward) => prev_grapheme(&self.text, self.cursor),
            Motion::Word(direction) => word_target(&self.text, self.cursor, direction),
            Motion::LineEdge(Direction::Backward) => line_start(&self.text, self.cursor),
            Motion::LineEdge(Direction::Forward) => line_end(&self.text, self.cursor),
            Motion::DocEdge(Direction::Backward) => 0,
            Motion::DocEdge(Direction::Forward) => self.text.len(),
            Motion::Line(direction) => self.vertical(direction),
        }
    }

    /// Moves the caret and drops the selection.
    pub fn move_by(&mut self, motion: Motion) {
        // A selection collapses to the edge the motion points at, the way every text field does:
        // ← from a selection puts the caret at its start, not one character before its head.
        if let (Some(range), Motion::Grapheme(direction)) = (self.selection(), motion) {
            self.cursor = match direction {
                Direction::Backward => range.start,
                Direction::Forward => range.end,
            };
            self.anchor = self.cursor;
            self.goal = None;
            return;
        }
        self.remember_goal(motion);
        let landing = self.target(motion);
        self.cursor = landing;
        self.anchor = landing;
    }

    /// Moves the caret and keeps the anchor, extending the selection.
    pub fn extend_by(&mut self, motion: Motion) {
        self.remember_goal(motion);
        self.cursor = self.target(motion);
    }

    /// Replaces the selection (or inserts at the caret) with `text`, and answers the [`Edit`] that
    /// did it.
    pub fn insert(&mut self, text: &str) -> Edit {
        let range = self.selection().unwrap_or(self.cursor..self.cursor);
        self.replace_range(range, text)
    }

    /// Deletes the selection if there is one, otherwise the run between the caret and `motion`'s
    /// landing.
    ///
    /// `None` when there is nothing to delete — backspace at offset 0 — so a caller can tell a
    /// no-op from an empty deletion and not push an undo step for it.
    pub fn delete(&mut self, motion: Motion) -> Option<Edit> {
        let range = if let Some(range) = self.selection() {
            range
        } else {
            let landing = self.target(motion);
            if landing == self.cursor {
                return None;
            }
            if landing < self.cursor {
                landing..self.cursor
            } else {
                self.cursor..landing
            }
        };
        Some(self.replace_range(range, ""))
    }

    /// Replaces a byte range with `text`, snapping both ends to grapheme boundaries.
    ///
    /// The start rounds DOWN and the end rounds UP, so a range that clips a cluster grows to
    /// contain it rather than splitting it — replacing `2..3` of `a` + `e◌́` + `b` replaces the
    /// whole `e◌́`, which is the only outcome that cannot leave a stranded combining mark in the
    /// document.
    ///
    /// The [`Edit`] carries the removed text and the caret on both sides, which is everything undo
    /// needs — see [`crate::prompt::undo`] for why an op and not a snapshot.
    pub fn replace_range(&mut self, range: Range<usize>, text: &str) -> Edit {
        let start = snap(&self.text, range.start);
        let end = snap_up(&self.text, range.end.max(start));
        let removed = self.text.get(start..end).unwrap_or("").to_owned();
        let edit = Edit {
            at: start,
            removed,
            inserted: text.to_owned(),
            cursor_before: self.cursor,
            anchor_before: self.anchor,
            cursor_after: start.saturating_add(text.len()),
        };
        self.splice(start..end, text);
        self.cursor = edit.cursor_after;
        self.anchor = self.cursor;
        self.goal = None;
        edit
    }

    /// Splices without recording anything — the door undo and redo replay through.
    pub(crate) fn splice(&mut self, range: Range<usize>, text: &str) {
        let start = range.start.min(self.text.len());
        let end = range.end.clamp(start, self.text.len());
        if self.text.is_char_boundary(start) && self.text.is_char_boundary(end) {
            self.text.replace_range(start..end, text);
        }
        self.cursor = snap(&self.text, self.cursor);
        self.anchor = snap(&self.text, self.anchor);
        self.goal = None;
    }

    /// Places the caret and the anchor directly, for undo's restore. Both are snapped.
    pub(crate) fn place(&mut self, cursor: usize, anchor: usize) {
        self.cursor = snap(&self.text, cursor);
        self.anchor = snap(&self.text, anchor);
        self.goal = None;
    }

    /// The logical lines, in order. Always at least one, because an empty document is one empty
    /// line and a prompt with no lines has nowhere to put a caret.
    pub fn lines(&self) -> impl Iterator<Item = &str> {
        self.text.split('\n')
    }

    /// How many logical lines the document has.
    #[must_use]
    pub fn line_count(&self) -> usize {
        self.text.matches('\n').count().saturating_add(1)
    }

    /// Where `offset` is, in lines and display cells.
    #[must_use]
    pub fn line_column(&self, offset: usize) -> LineColumn {
        let offset = snap(&self.text, offset);
        let before = self.text.get(..offset).unwrap_or("");
        let start = before.rfind('\n').map_or(0, |at| at.saturating_add(1));
        LineColumn {
            line: before.matches('\n').count(),
            column: text_cells(before.get(start..).unwrap_or("")),
        }
    }

    /// The caret, in lines and display cells.
    #[must_use]
    pub fn caret(&self) -> LineColumn {
        self.line_column(self.cursor)
    }

    /// Arms the goal column on the first vertical step of a run and clears it on anything else,
    /// which is what makes ↓ through a short line and back ↑ end where it began.
    fn remember_goal(&mut self, motion: Motion) {
        if matches!(motion, Motion::Line(_)) {
            if self.goal.is_none() {
                self.goal = Some(self.line_column(self.cursor).column);
            }
        } else {
            self.goal = None;
        }
    }

    /// One logical line up or down, landing on the goal column or the line's end, whichever comes
    /// first.
    fn vertical(&self, direction: Direction) -> usize {
        let start = line_start(&self.text, self.cursor);
        let goal = self.goal.unwrap_or_else(|| self.line_column(self.cursor).column);
        match direction {
            Direction::Backward => {
                if start == 0 {
                    return 0;
                }
                let previous = line_start(&self.text, start.saturating_sub(1));
                offset_at_column(&self.text, previous, goal)
            },
            Direction::Forward => {
                let end = line_end(&self.text, self.cursor);
                if end >= self.text.len() {
                    return self.text.len();
                }
                offset_at_column(&self.text, end.saturating_add(1), goal)
            },
        }
    }
}

/// Clamps `offset` into the text and moves it back to the nearest grapheme boundary.
///
/// Backward rather than forward so a caret never jumps over text the caller was pointing at, and so
/// snapping is idempotent.
#[must_use]
pub fn snap(text: &str, offset: usize) -> usize {
    let mut at = offset.min(text.len());
    while at > 0 && !text.is_char_boundary(at) {
        at = at.saturating_sub(1);
    }
    let mut cursor = GraphemeCursor::new(at, text.len(), true);
    match cursor.is_boundary(text, 0) {
        Ok(true) | Err(_) => at,
        Ok(false) => prev_grapheme(text, at),
    }
}

/// [`snap`]'s mirror: forward to the nearest boundary rather than back.
///
/// Used only for the END of a replaced range, where rounding down would leave the tail of a cluster
/// behind.
#[must_use]
pub fn snap_up(text: &str, offset: usize) -> usize {
    let down = snap(text, offset);
    if down == offset.min(text.len()) {
        down
    } else {
        next_grapheme(text, down)
    }
}

/// The next grapheme boundary after `offset`, or `offset` at the end.
#[must_use]
pub fn next_grapheme(text: &str, offset: usize) -> usize {
    let at = offset.min(text.len());
    let mut cursor = GraphemeCursor::new(at, text.len(), true);
    cursor.next_boundary(text, 0).ok().flatten().unwrap_or(at)
}

/// The previous grapheme boundary before `offset`, or `offset` at the start.
#[must_use]
pub fn prev_grapheme(text: &str, offset: usize) -> usize {
    let at = offset.min(text.len());
    let mut cursor = GraphemeCursor::new(at, text.len(), true);
    cursor.prev_boundary(text, 0).ok().flatten().unwrap_or(at)
}

/// The byte offset of the start of the logical line holding `offset`.
fn line_start(text: &str, offset: usize) -> usize {
    text.get(..offset.min(text.len()))
        .and_then(|before| before.rfind('\n'))
        .map_or(0, |at| at.saturating_add(1))
}

/// The byte offset of the newline that ends the logical line holding `offset`, or the document's
/// end.
fn line_end(text: &str, offset: usize) -> usize {
    let at = offset.min(text.len());
    text.get(at..)
        .and_then(|after| after.find('\n'))
        .map_or(text.len(), |found| at.saturating_add(found))
}

/// The offset on the line starting at `start` that sits `column` display cells in, or the line's
/// end when it is shorter than that.
fn offset_at_column(text: &str, start: usize, column: usize) -> usize {
    let end = line_end(text, start);
    let line = text.get(start..end).unwrap_or("");
    let mut cells = 0_usize;
    for (offset, cluster) in line.grapheme_indices(true) {
        if cells >= column {
            return start.saturating_add(offset);
        }
        cells = cells.saturating_add(text_cells(cluster));
    }
    end
}

/// Whether a UAX #29 segment is one a word motion should stop at.
///
/// Alphanumeric content rather than "not whitespace": ⌥→ skips over `-->` in one press, the way a
/// text field does, and stopping on every punctuation run would make it a grapheme motion with
/// extra steps.
fn is_wordish(segment: &str) -> bool {
    segment.chars().any(char::is_alphanumeric)
}

/// The landing of a word motion. See the module header for why it is confined to one line.
fn word_target(text: &str, cursor: usize, direction: Direction) -> usize {
    let start = line_start(text, cursor);
    let end = line_end(text, cursor);
    match direction {
        Direction::Forward => {
            if cursor >= end {
                // Already at the line's edge: step over the newline into the next line.
                return next_grapheme(text, cursor);
            }
            let from = cursor.saturating_sub(WORD_CONTEXT).max(start);
            let from = snap(text, from);
            let to = cursor.saturating_add(WORD_WINDOW).min(end);
            let to = snap(text, to);
            let window = text.get(from..to).unwrap_or("");
            window
                .split_word_bound_indices()
                .map(|(offset, segment)| (from.saturating_add(offset), segment))
                .find(|(at, segment)| at.saturating_add(segment.len()) > cursor && is_wordish(segment))
                .map_or(to, |(at, segment)| at.saturating_add(segment.len()))
        },
        Direction::Backward => {
            if cursor <= start {
                return prev_grapheme(text, cursor);
            }
            let from = snap(text, cursor.saturating_sub(WORD_WINDOW).max(start));
            let to = snap(text, cursor.saturating_add(WORD_CONTEXT).min(end));
            let window = text.get(from..to).unwrap_or("");
            window
                .split_word_bound_indices()
                .map(|(offset, segment)| (from.saturating_add(offset), segment))
                .rev()
                .find(|(at, segment)| *at < cursor && is_wordish(segment))
                .map_or(from, |(at, _)| at)
        },
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::Direction::{Backward, Forward};
    use super::{LineColumn, Motion, TextBuffer, snap};

    fn seeded(text: &str, cursor: usize) -> TextBuffer {
        let mut buffer = TextBuffer::seeded(text);
        buffer.set_cursor(cursor);
        buffer
    }

    #[test]
    fn a_grapheme_step_crosses_a_whole_cluster_not_a_byte() {
        // "é" as e + combining acute, then a ZWJ family, then a flag.
        let text = "e\u{301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{1F1FB}\u{1F1F3}";
        let mut buffer = seeded(text, 0);
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), 3, "e + combining acute is one step");
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), 3 + 18, "the ZWJ family is one step");
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), text.len(), "the flag pair is one step");
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), text.len(), "and the end is a wall, not a panic");
    }

    #[test]
    fn a_hundred_thousand_combining_marks_are_one_cluster() {
        let text = "a".to_owned() + &"\u{301}".repeat(100_000);
        let mut buffer = seeded(&text, 0);
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), text.len());
        buffer.move_by(Motion::Grapheme(Backward));
        assert_eq!(buffer.cursor(), 0);
    }

    #[test]
    fn a_cursor_offset_inside_a_cluster_snaps_back_to_its_start() {
        let text = "e\u{301}x";
        assert_eq!(snap(text, 1), 0, "between the e and its mark");
        assert_eq!(snap(text, 2), 0, "inside the mark's bytes");
        assert_eq!(snap(text, 3), 3);
        assert_eq!(snap(text, 999), text.len());
    }

    #[test]
    fn word_motion_agrees_with_uax_29_rather_than_with_whitespace() {
        let mut buffer = seeded("git commit --amend", 0);
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 3, "the end of `git`");
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 10, "the end of `commit`, skipping the space");
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 18, "the end of `amend`, skipping the two dashes");
        buffer.move_by(Motion::Word(Backward));
        assert_eq!(buffer.cursor(), 13, "the start of `amend`");
    }

    #[test]
    fn a_contraction_and_a_number_are_each_one_word() {
        let mut buffer = seeded("don't 3.14 x", 0);
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 5, "`don't` is one UAX #29 word");
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 10, "and so is `3.14`");
    }

    #[test]
    fn word_motion_stops_at_the_line_edge_and_steps_across_on_the_next_press() {
        let mut buffer = seeded("ab\ncd", 2);
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 3, "over the newline");
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), 5, "then by a word");
        buffer.move_by(Motion::Word(Backward));
        assert_eq!(buffer.cursor(), 3);
        buffer.move_by(Motion::Word(Backward));
        assert_eq!(buffer.cursor(), 2, "back over the newline");
    }

    #[test]
    fn line_and_document_edges_are_logical_lines() {
        let mut buffer = seeded("one\ntwo\nthree", 5);
        buffer.move_by(Motion::LineEdge(Backward));
        assert_eq!(buffer.cursor(), 4);
        buffer.move_by(Motion::LineEdge(Forward));
        assert_eq!(buffer.cursor(), 7);
        buffer.move_by(Motion::DocEdge(Backward));
        assert_eq!(buffer.cursor(), 0);
        buffer.move_by(Motion::DocEdge(Forward));
        assert_eq!(buffer.cursor(), 13);
    }

    #[test]
    fn a_vertical_run_keeps_its_goal_column_through_a_short_line() {
        let mut buffer = seeded("longest line\nab\nanother long line", 10);
        assert_eq!(buffer.caret().column, 10);
        buffer.move_by(Motion::Line(Forward));
        assert_eq!(
            buffer.caret(),
            LineColumn { line: 1, column: 2 },
            "clipped to the short line"
        );
        buffer.move_by(Motion::Line(Forward));
        assert_eq!(
            buffer.caret(),
            LineColumn { line: 2, column: 10 },
            "goal recovered"
        );
        buffer.move_by(Motion::Line(Backward));
        buffer.move_by(Motion::Line(Backward));
        assert_eq!(buffer.caret(), LineColumn { line: 0, column: 10 });
    }

    #[test]
    fn a_column_is_display_cells_so_a_cjk_row_lines_up() {
        let buffer = TextBuffer::seeded("日本x");
        assert_eq!(buffer.line_column(6), LineColumn { line: 0, column: 4 });
        assert_eq!(buffer.caret(), LineColumn { line: 0, column: 5 });
    }

    #[test]
    fn a_selection_replaces_on_type_and_a_collapsed_one_inserts() {
        let mut buffer = TextBuffer::seeded("hello world");
        buffer.set_selection(6, 11);
        assert_eq!(buffer.selected_text(), "world");
        let edit = buffer.insert("there");
        assert_eq!(buffer.text(), "hello there");
        assert_eq!(edit.removed, "world");
        assert_eq!(buffer.selection(), None);
        assert_eq!(buffer.cursor(), 11);
    }

    #[test]
    fn extending_moves_the_head_and_leaves_the_anchor() {
        let mut buffer = seeded("alpha beta", 0);
        buffer.extend_by(Motion::Word(Forward));
        assert_eq!(buffer.selection(), Some(0..5));
        buffer.extend_by(Motion::Word(Forward));
        assert_eq!(buffer.selection(), Some(0..10));
        buffer.extend_by(Motion::DocEdge(Backward));
        assert_eq!(buffer.selection(), None, "the head passed the anchor and met it");
        assert_eq!(buffer.anchor(), 0);
    }

    #[test]
    fn an_arrow_out_of_a_selection_lands_on_its_edge() {
        let mut buffer = TextBuffer::seeded("abcdef");
        buffer.set_selection(2, 5);
        buffer.move_by(Motion::Grapheme(Backward));
        assert_eq!(buffer.cursor(), 2);
        buffer.set_selection(2, 5);
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), 5);
    }

    #[test]
    fn deleting_by_word_and_by_grapheme_use_the_same_landing() {
        let mut buffer = seeded("git commit --amend", 18);
        buffer.delete(Motion::Word(Backward)).unwrap();
        assert_eq!(buffer.text(), "git commit --");
        buffer.delete(Motion::Grapheme(Backward)).unwrap();
        assert_eq!(buffer.text(), "git commit -");
        buffer.set_cursor(0);
        buffer.delete(Motion::Word(Forward)).unwrap();
        assert_eq!(buffer.text(), " commit -");
    }

    #[test]
    fn a_deletion_with_nowhere_to_go_reports_nothing_rather_than_an_empty_edit() {
        let mut buffer = seeded("abc", 0);
        assert!(buffer.delete(Motion::Grapheme(Backward)).is_none());
        buffer.set_cursor(3);
        assert!(buffer.delete(Motion::Grapheme(Forward)).is_none());
    }

    #[test]
    fn a_selection_deletes_whole_whatever_motion_was_asked_for() {
        let mut buffer = TextBuffer::seeded("hello world");
        buffer.set_selection(0, 5);
        let edit = buffer.delete(Motion::Grapheme(Forward)).unwrap();
        assert_eq!(edit.removed, "hello");
        assert_eq!(buffer.text(), " world");
    }

    #[test]
    fn a_ten_megabyte_paste_is_one_splice_and_arrows_stay_local() {
        let paste = "x".repeat(10 * 1024 * 1024);
        let mut buffer = TextBuffer::new();
        buffer.insert(&paste);
        assert_eq!(buffer.len(), paste.len());
        buffer.set_cursor(0);
        buffer.move_by(Motion::Grapheme(Forward));
        assert_eq!(buffer.cursor(), 1);
        // A word motion over a line with no boundary lands on the window edge, not the far end.
        buffer.move_by(Motion::Word(Forward));
        assert_eq!(buffer.cursor(), super::WORD_WINDOW + 1);
    }

    #[test]
    fn replacing_a_range_snaps_both_of_its_ends() {
        let mut buffer = TextBuffer::seeded("ae\u{301}b");
        let edit = buffer.replace_range(2..3, "Z");
        assert_eq!(
            edit.at, 1,
            "the end of the cluster is not a boundary; both ends snapped back"
        );
        assert_eq!(buffer.text(), "aZb");
    }

    #[test]
    fn an_empty_document_is_still_one_line() {
        let buffer = TextBuffer::new();
        assert_eq!(buffer.line_count(), 1);
        assert_eq!(buffer.lines().count(), 1);
        assert!(buffer.is_empty());
        assert_eq!(buffer.caret(), LineColumn::default());
    }
}
