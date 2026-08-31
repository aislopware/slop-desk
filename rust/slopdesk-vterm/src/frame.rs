//! The grid, flattened into plain data a renderer can draw without holding the engine.
//!
//! [`Frame`] is the whole contract between the engine and everything downstream. It exists rather
//! than handing the renderer a `&Terminal` for three reasons, and each one is load-bearing:
//!
//! * **The engine is `!Send` and `!Sync`.** Every libghostty-vt handle is confined to one thread. A
//!   frame is plain owned data, so the pipeline that consumes it — quad building, atlas residency,
//!   the Metal encode — is free of that confinement and free of the engine's lock.
//! * **The lock is held for the scan, not for the draw.** `begin_update` needs the terminal;
//!   everything after it does not. Filling a frame is the only phase that touches engine memory, so
//!   it is the only phase that has to be serialised against `vt_write`.
//! * **A frame is testable.** Quad geometry, block layout, cursor shape and selection spans are all
//!   decided from a frame, so `slopdesk-termrender` tests them by building one by hand — no engine,
//!   no font, no GPU.
//!
//! ## Why the text is per row rather than per cell
//!
//! A cell's text is a grapheme cluster: usually one scalar, sometimes a base plus combining marks,
//! occasionally an emoji sequence of five. Storing a `String` in every cell would allocate 10 000
//! times for a 200×50 viewport. Storing one arena for the whole frame would mean a single dirty row
//! shifts every span after it.
//!
//! So the arena is a row: [`FrameRow::text`] holds that row's clusters back to back and each
//! [`FrameCell`] carries a [`TextSpan`] into it. A dirty row clears and refills its own `String`
//! and `Vec`, both of which keep their capacity — so a steady-state repaint allocates nothing at
//! all, and a clean row is skipped without being touched.

use core::ops::Range;

use libghostty_vt::unicode::grapheme_width;

/// How many grid cells `text` would take if the engine placed it.
///
/// The engine's OWN segmenter and width table answer it, which is the whole reason this is here
/// rather than a `unicode-width` dependency: text an input method is still composing has to measure
/// the same as the text that replaces it when the composition commits, and two width tables would
/// disagree on exactly the sequences a preedit is made of — a base plus its combining tone mark.
///
/// Saturating rather than wrapping, because the caller is placing a caret: a preedit wider than
/// 65 535 cells is not a number anyone can act on, and a wrapped one would place it on the left.
#[must_use]
pub fn text_cells(text: &str) -> u16 {
    // Collected because `grapheme_width` reads a `char` slice — it walks a cluster and answers how
    // many scalars it consumed, which a `Chars` iterator cannot be rewound over. A preedit is at
    // most a phrase, so this is one small allocation per composition change, not per frame: the
    // measurement is taken where the input method reports, never on the paint path.
    let chars: Vec<char> = text.chars().collect();
    let mut cells = 0_u16;
    let mut at = 0_usize;
    while let Some(rest) = chars.get(at..).filter(|rest| !rest.is_empty()) {
        let (consumed, width) = grapheme_width(rest);
        cells = cells.saturating_add(u16::from(width));
        // A cluster that consumes nothing would spin here forever. One scalar is the honest floor:
        // every `char` is at least its own cluster.
        at = at.saturating_add(consumed.max(1));
    }
    cells
}

/// A 24-bit colour, already resolved.
///
/// Palette lookup, the bold-brightening rule and `inverse` are the engine's job — by the time a
/// colour reaches a frame it is the literal one to paint, so nothing downstream needs the palette
/// to draw a cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Rgb {
    /// Red, 0–255.
    pub r: u8,
    /// Green, 0–255.
    pub g: u8,
    /// Blue, 0–255.
    pub b: u8,
}

impl Rgb {
    /// Black.
    pub const BLACK: Self = Self { r: 0, g: 0, b: 0 };
    /// White.
    pub const WHITE: Self = Self {
        r: 0xFF,
        g: 0xFF,
        b: 0xFF,
    };

    /// A colour from its three components.
    #[must_use]
    pub const fn new(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b }
    }

    /// The colour packed little-endian into `0x00BBGGRR`, the layout a vertex buffer wants.
    #[must_use]
    pub const fn packed(self) -> u32 {
        (self.r as u32) | ((self.g as u32) << 8) | ((self.b as u32) << 16)
    }
}

impl From<libghostty_vt::style::RgbColor> for Rgb {
    fn from(value: libghostty_vt::style::RgbColor) -> Self {
        Self {
            r: value.r,
            g: value.g,
            b: value.b,
        }
    }
}

/// Where one cell's grapheme cluster lives inside its row's text arena.
///
/// A span rather than a `String`: see the module header. `len == 0` is an empty cell, which is the
/// common case for the right-hand end of most rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TextSpan {
    /// Byte offset into [`FrameRow::text`].
    pub offset: u32,
    /// Byte length. Zero for a blank cell.
    pub len: u32,
}

impl TextSpan {
    /// Whether the cell has no text at all.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.len == 0
    }

    /// The span as a byte range, for slicing the row's arena.
    #[must_use]
    pub const fn range(self) -> Range<usize> {
        (self.offset as usize)..(self.offset as usize + self.len as usize)
    }
}

/// The boolean cell attributes, packed.
///
/// A bitset rather than nine `bool` fields because a cell is copied per glyph per frame: at 200×50
/// and 120 Hz that is 1.2 M copies a second, and two bytes beats nine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct CellFlags(u16);

impl CellFlags {
    /// No attributes.
    pub const NONE: Self = Self(0);
    /// SGR 1 — draw with the bold face, or synthesise one.
    pub const BOLD: Self = Self(1 << 0);
    /// SGR 3 — draw with the italic face, or slant one.
    pub const ITALIC: Self = Self(1 << 1);
    /// SGR 2 — dim. Applied to the resolved foreground, not to the face.
    pub const FAINT: Self = Self(1 << 2);
    /// SGR 5 — the cell blinks. Whether it is currently on is the renderer's clock, not the grid's.
    pub const BLINK: Self = Self(1 << 3);
    /// SGR 9 — strike through the cell at the mid-line.
    pub const STRIKETHROUGH: Self = Self(1 << 4);
    /// SGR 53 — a line above the cell.
    pub const OVERLINE: Self = Self(1 << 5);
    /// The leading half of a double-width character.
    pub const WIDE: Self = Self(1 << 6);
    /// The trailing half of a double-width character. Never drawn — its glyph belongs to [`WIDE`].
    ///
    /// [`WIDE`]: Self::WIDE
    pub const WIDE_TAIL: Self = Self(1 << 7);
    /// The spacer libghostty leaves at the end of a soft-wrapped row before a wide character.
    pub const WIDE_HEAD: Self = Self(1 << 8);
    /// The cell falls inside the active selection.
    pub const SELECTED: Self = Self(1 << 9);
    /// The cell carries an OSC 8 hyperlink.
    ///
    /// The FLAG only — the URI is not in the frame, because it is one string shared by a whole run
    /// of cells and copying it per cell per frame would allocate a URL for every character of a
    /// link. `Session::hyperlink_at` reads it for the one cell somebody actually pointed at.
    pub const HYPERLINK: Self = Self(1 << 10);

    /// Whether every bit of `other` is set.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        (self.0 & other.0) == other.0
    }

    /// Both sets of bits.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// The set with `other`'s bits cleared.
    #[must_use]
    pub const fn without(self, other: Self) -> Self {
        Self(self.0 & !other.0)
    }

    /// The set with `other`'s bits set iff `on`.
    #[must_use]
    pub const fn set(self, other: Self, on: bool) -> Self {
        if on {
            self.union(other)
        } else {
            self.without(other)
        }
    }

    /// The raw bits, for a vertex attribute.
    #[must_use]
    pub const fn bits(self) -> u16 {
        self.0
    }

    /// Whether the cell contributes no glyph — blank, invisible, or the tail of a wide pair.
    ///
    /// Invisible (SGR 8) is folded in at fill time by blanking the span rather than kept as a flag:
    /// a renderer that forgot to check the flag would leak a password, and one that reads an empty
    /// span cannot.
    #[must_use]
    pub const fn hides_glyph(self) -> bool {
        self.contains(Self::WIDE_TAIL) || self.contains(Self::WIDE_HEAD)
    }
}

/// The underline an SGR 4 variant asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum UnderlineStyle {
    /// No underline.
    #[default]
    None,
    /// SGR 4 — one straight line.
    Single,
    /// SGR 21 — two straight lines.
    Double,
    /// SGR 4:3 — the squiggle diagnostics use.
    Curly,
    /// SGR 4:4 — a dotted line.
    Dotted,
    /// SGR 4:5 — a dashed line.
    Dashed,
}

impl From<libghostty_vt::style::Underline> for UnderlineStyle {
    fn from(value: libghostty_vt::style::Underline) -> Self {
        match value {
            libghostty_vt::style::Underline::Single => Self::Single,
            libghostty_vt::style::Underline::Double => Self::Double,
            libghostty_vt::style::Underline::Curly => Self::Curly,
            libghostty_vt::style::Underline::Dotted => Self::Dotted,
            libghostty_vt::style::Underline::Dashed => Self::Dashed,
            // `None`, and — because the enum is `#[non_exhaustive]` — anything a newer engine adds.
            // An unknown decoration draws none rather than failing the frame: a missing underline is
            // not worth losing a repaint over.
            _ => Self::None,
        }
    }
}

/// One drawable cell.
///
/// 20 bytes, `Copy`, and self-contained apart from its text — everything the quad builder needs for
/// a background rect, a glyph and a decoration, with no second lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FrameCell {
    /// The cell's grapheme cluster inside [`FrameRow::text`].
    pub text: TextSpan,
    /// The resolved foreground.
    pub fg: Rgb,
    /// The resolved background.
    pub bg: Rgb,
    /// The underline's own colour (SGR 58), or the foreground when unset.
    pub underline_color: Rgb,
    /// The boolean attributes.
    pub flags: CellFlags,
    /// Which underline to draw, if any.
    pub underline: UnderlineStyle,
}

/// A half-open span of columns, as the selection reports one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColumnSpan {
    /// First selected column.
    pub start: u16,
    /// One past the last selected column.
    pub end: u16,
}

impl ColumnSpan {
    /// Whether `x` falls inside the span.
    #[must_use]
    pub const fn contains(self, x: u16) -> bool {
        x >= self.start && x < self.end
    }

    /// How many columns the span covers.
    #[must_use]
    pub const fn width(self) -> u16 {
        self.end.saturating_sub(self.start)
    }
}

/// What OSC 133 said this row is.
///
/// This is the whole basis of blocks. A [`Prompt`] row is where one command block ends and the next
/// begins, which is why a row carries it rather than the block ring having to re-scan the grid.
///
/// [`Prompt`]: Self::Prompt
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum RowSemantic {
    /// Ordinary output — the shell said nothing about this row.
    #[default]
    Output,
    /// A primary prompt line: `OSC 133;A`.
    Prompt,
    /// A prompt that wrapped onto a second line: `OSC 133;A;k=c`.
    PromptContinuation,
}

impl From<libghostty_vt::screen::RowSemanticPrompt> for RowSemantic {
    fn from(value: libghostty_vt::screen::RowSemanticPrompt) -> Self {
        match value {
            libghostty_vt::screen::RowSemanticPrompt::None => Self::Output,
            libghostty_vt::screen::RowSemanticPrompt::Prompt => Self::Prompt,
            libghostty_vt::screen::RowSemanticPrompt::Continuation => Self::PromptContinuation,
        }
    }
}

/// One row of the viewport, with its own text arena.
#[derive(Debug, Clone, Default)]
pub struct FrameRow {
    /// Every cell's grapheme cluster, back to back. Sliced by each cell's [`TextSpan`].
    pub text: String,
    /// The row's cells, left to right, always `cols` of them.
    pub cells: Vec<FrameCell>,
    /// The selected column span, if the selection crosses this row.
    ///
    /// A row-local span is both cheaper and more correct than testing every cell: the selection
    /// covers a contiguous run, so one range draws one rect instead of `cols` of them.
    pub selection: Option<ColumnSpan>,
    /// What OSC 133 said this row is.
    pub semantic: RowSemantic,
    /// Whether the row soft-wrapped into the next one.
    ///
    /// Load-bearing twice over: an unwrapped copy has to rejoin the pieces, and block layout must
    /// not put a boundary in the middle of a logical line.
    pub wrapped: bool,
    /// Whether the row changed since the last frame the renderer drew.
    pub dirty: bool,
}

impl FrameRow {
    /// The text of one cell, or `""` for a blank one.
    #[must_use]
    pub fn cell_text(&self, cell: FrameCell) -> &str {
        self.text.get(cell.text.range()).unwrap_or("")
    }

    /// Clears the row for a refill, keeping both allocations.
    pub(crate) fn begin_fill(&mut self) {
        self.text.clear();
        self.cells.clear();
        self.selection = None;
    }

    /// Appends one cell, interning its text into the row arena.
    pub(crate) fn push_cell(&mut self, text: &str, mut cell: FrameCell) {
        // A `u32` offset caps a row's arena at 4 GiB, which no terminal row can reach: the column
        // count is a `u16` and a grapheme cluster is bounded by the engine's own cluster limit.
        cell.text = TextSpan {
            offset: u32::try_from(self.text.len()).unwrap_or(u32::MAX),
            len: u32::try_from(text.len()).unwrap_or(0),
        };
        self.text.push_str(text);
        self.cells.push(cell);
    }
}

/// Which cursor the terminal is asking for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum CursorShape {
    /// A filled block over the whole cell.
    #[default]
    Block,
    /// A vertical bar at the cell's leading edge.
    Bar,
    /// A line along the cell's baseline.
    Underline,
    /// A block outline, which is what an unfocused surface draws.
    Hollow,
}

impl From<libghostty_vt::render::CursorVisualStyle> for CursorShape {
    fn from(value: libghostty_vt::render::CursorVisualStyle) -> Self {
        match value {
            libghostty_vt::render::CursorVisualStyle::Bar => Self::Bar,
            libghostty_vt::render::CursorVisualStyle::Underline => Self::Underline,
            libghostty_vt::render::CursorVisualStyle::BlockHollow => Self::Hollow,
            // `Block`, and — because the enum is `#[non_exhaustive]` — anything a newer engine adds.
            // An unknown shape draws the block rather than no cursor: a terminal with no visible
            // cursor is unusable, one with the wrong shape is merely wrong.
            _ => Self::Block,
        }
    }
}

/// Where the cursor is and what it looks like.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameCursor {
    /// Column, in cells.
    pub x: u16,
    /// Row within the viewport, in cells.
    pub y: u16,
    /// The shape to draw.
    pub shape: CursorShape,
    /// The cursor's colour.
    pub color: Rgb,
    /// Whether the terminal asked the cursor to blink. The phase is the renderer's clock.
    pub blinking: bool,
    /// Whether the cursor sits on the trailing half of a wide character, where a bar belongs at the
    /// pair's leading edge rather than at this cell's.
    pub at_wide_tail: bool,
    /// Whether the cell under the cursor is a password field, which suppresses the blink so a
    /// shoulder-surfer cannot count keystrokes from it.
    pub password_input: bool,
}

/// The frame's default colours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameColors {
    /// The default background — what an unstyled cell and the padding are painted.
    pub background: Rgb,
    /// The default foreground.
    pub foreground: Rgb,
    /// The 256-entry palette, for anything that has to resolve an index itself.
    pub palette: [Rgb; 256],
}

impl Default for FrameColors {
    fn default() -> Self {
        Self {
            background: Rgb::BLACK,
            foreground: Rgb::WHITE,
            palette: [Rgb::BLACK; 256],
        }
    }
}

/// How much of the frame changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum FrameDirty {
    /// Nothing changed. The renderer re-presents the last drawable and does no work at all.
    #[default]
    Clean,
    /// Some rows changed; the ones with [`FrameRow::dirty`] set are the ones to rebuild.
    Partial,
    /// Global state changed — a resize, a palette swap, a screen flip. Rebuild everything.
    Full,
}

impl From<libghostty_vt::render::Dirty> for FrameDirty {
    fn from(value: libghostty_vt::render::Dirty) -> Self {
        match value {
            libghostty_vt::render::Dirty::Clean => Self::Clean,
            libghostty_vt::render::Dirty::Partial => Self::Partial,
            libghostty_vt::render::Dirty::Full => Self::Full,
        }
    }
}

/// One viewport, flattened.
///
/// Reused across renders: [`Frame::rows`] keeps its `Vec<FrameRow>` and each row keeps its two
/// allocations, so the steady state is memcpy over already-owned memory.
#[derive(Debug, Clone, Default)]
pub struct Frame {
    /// Viewport width in cells. Every row has exactly this many cells.
    pub cols: u16,
    /// The viewport's rows, top to bottom.
    pub rows: Vec<FrameRow>,
    /// The cursor, when it is visible and inside the viewport.
    pub cursor: Option<FrameCursor>,
    /// The default colours and palette.
    pub colors: FrameColors,
    /// How much changed.
    pub dirty: FrameDirty,
    /// Monotonic frame counter, bumped on every fill that was not [`FrameDirty::Clean`].
    ///
    /// The renderer compares it to decide whether a rebuild is needed at all, which is cheaper and
    /// more honest than comparing contents.
    pub revision: u64,
}

impl Frame {
    /// An empty frame.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether the selection stops exactly where the cursor stands.
    ///
    /// This is the question a CUT has to answer before it sends a single `DEL`. Cutting from a
    /// terminal is not an edit the terminal can perform — there is no buffer to splice, only a
    /// program on the far side reading keystrokes — so the delete half is BACKSPACES, and a
    /// backspace only removes the selected text when the cursor is sitting immediately past it.
    /// Anywhere else, those backspaces would eat somebody else's characters, which is why the
    /// count degrades to zero and the cut becomes a copy.
    ///
    /// Answered from the FRAME rather than the engine, and that is the point: the frame already
    /// carries both halves — each row's selected span and the cursor's cell — so the answer costs
    /// a walk of the rows and no engine call at all. The last row that carries a span holds the
    /// selection's end, because a selection is contiguous.
    #[must_use]
    pub fn selection_ends_at_cursor(&self) -> bool {
        let Some(cursor) = self.cursor else {
            return false;
        };
        let Some((row, span)) = self
            .rows
            .iter()
            .enumerate()
            .filter_map(|(row, line)| line.selection.map(|span| (row, span)))
            .next_back()
        else {
            return false;
        };
        // `end` is one past the last selected column, which is exactly where a cursor standing
        // after the selection sits — so the two compare directly, with no off-by-one to argue
        // about. `u16::try_from` cannot fail for a viewport, and a frame taller than 65 535 rows
        // is not one anybody is cutting from.
        u16::try_from(row).is_ok_and(|row| row == cursor.y) && span.end == cursor.x
    }

    /// Every run of cells the program marked as an `OSC 8` hyperlink, row by row.
    ///
    /// What the hover underline needs, and the reason it reads the FRAME rather than asking the
    /// engine cell by cell: [`CellFlags::HYPERLINK`] is already on every cell, so a whole viewport
    /// costs one walk and zero engine calls, where `hyperlink_at` per cell would be `rows × cols`
    /// C calls each allocating a URI nobody is going to read.
    ///
    /// Two DIFFERENT links that abut with no character between them merge into one run. That is
    /// deliberate rather than a limitation worth the flag byte it would cost to fix: the caller is
    /// drawing an underline, and one stroke across both is the same picture as two touching ones.
    /// A caller that needs the URI asks `hyperlink_at` for the one cell under the pointer.
    #[must_use]
    pub fn hyperlink_spans(&self) -> Vec<(u16, ColumnSpan)> {
        let mut spans = Vec::new();
        for (row, line) in self.rows.iter().enumerate() {
            let Ok(row) = u16::try_from(row) else {
                continue;
            };
            let mut open: Option<u16> = None;
            for (column, cell) in line.cells.iter().enumerate() {
                let Ok(column) = u16::try_from(column) else {
                    continue;
                };
                match (cell.flags.contains(CellFlags::HYPERLINK), open) {
                    (true, None) => open = Some(column),
                    (false, Some(start)) => {
                        spans.push((row, ColumnSpan { start, end: column }));
                        open = None;
                    },
                    _ => {},
                }
            }
            if let Some(start) = open {
                spans.push((row, ColumnSpan {
                    start,
                    end: self.cols,
                }));
            }
        }
        spans
    }

    /// Viewport height in cells.
    #[must_use]
    pub fn row_count(&self) -> u16 {
        u16::try_from(self.rows.len()).unwrap_or(u16::MAX)
    }

    /// One row, or `None` past the bottom.
    #[must_use]
    pub fn row(&self, y: u16) -> Option<&FrameRow> {
        self.rows.get(y as usize)
    }

    /// One cell, or `None` outside the viewport.
    #[must_use]
    pub fn cell(&self, x: u16, y: u16) -> Option<FrameCell> {
        self.rows.get(y as usize)?.cells.get(x as usize).copied()
    }

    /// The text of one row with its trailing blanks removed, which is what a copy wants.
    #[must_use]
    pub fn row_text(&self, y: u16) -> String {
        let Some(row) = self.row(y) else {
            return String::new();
        };
        let mut out = String::with_capacity(row.text.len());
        for cell in &row.cells {
            if cell.flags.hides_glyph() {
                continue;
            }
            let text = row.cell_text(*cell);
            out.push_str(if text.is_empty() { " " } else { text });
        }
        while out.ends_with(' ') {
            out.pop();
        }
        out
    }

    /// Grows or shrinks the frame to `cols` × `rows`, keeping every allocation it can.
    pub(crate) fn reshape(&mut self, cols: u16, rows: u16) {
        self.cols = cols;
        self.rows.resize_with(rows as usize, FrameRow::default);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        CellFlags, ColumnSpan, CursorShape, Frame, FrameCell, FrameCursor, FrameRow, Rgb, RowSemantic,
        TextSpan, UnderlineStyle, text_cells,
    };

    /// A frame of `rows` blank rows, `cols` wide, with no cursor and nothing selected.
    fn blank_frame(cols: u16, rows: u16) -> Frame {
        let mut frame = Frame::new();
        frame.cols = cols;
        frame.rows = (0..rows)
            .map(|_| {
                let mut row = FrameRow::default();
                row.begin_fill();
                for _ in 0..cols {
                    row.push_cell("", FrameCell::default());
                }
                row
            })
            .collect();
        frame
    }

    /// A cursor at `(x, y)`. Everything but the position is irrelevant to what these tests ask.
    fn cursor_at(x: u16, y: u16) -> FrameCursor {
        FrameCursor {
            x,
            y,
            shape: CursorShape::Block,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        }
    }

    #[test]
    fn a_cut_is_armed_only_when_the_cursor_sits_just_past_the_selection() {
        let mut frame = blank_frame(10, 3);
        frame.rows[1].selection = Some(ColumnSpan { start: 2, end: 5 });

        frame.cursor = Some(cursor_at(5, 1));
        assert!(
            frame.selection_ends_at_cursor(),
            "column 5 is one past the last selected cell, which is where a backspace bites"
        );

        frame.cursor = Some(cursor_at(4, 1));
        assert!(
            !frame.selection_ends_at_cursor(),
            "inside the selection is not past it"
        );
        frame.cursor = Some(cursor_at(5, 2));
        assert!(
            !frame.selection_ends_at_cursor(),
            "the right column on the wrong row"
        );
        frame.cursor = None;
        assert!(
            !frame.selection_ends_at_cursor(),
            "no cursor, nothing to delete from"
        );
    }

    #[test]
    fn a_multi_row_selection_is_measured_from_its_last_row() {
        let mut frame = blank_frame(10, 3);
        frame.rows[0].selection = Some(ColumnSpan { start: 7, end: 10 });
        frame.rows[1].selection = Some(ColumnSpan { start: 0, end: 4 });

        frame.cursor = Some(cursor_at(4, 1));
        assert!(frame.selection_ends_at_cursor());
        frame.cursor = Some(cursor_at(10, 0));
        assert!(
            !frame.selection_ends_at_cursor(),
            "the FIRST row's end is where the selection began, not where it stopped"
        );
    }

    #[test]
    fn hyperlink_spans_close_at_the_first_unlinked_cell() {
        let mut frame = blank_frame(8, 2);
        for column in [1_usize, 2, 3, 6] {
            frame.rows[0].cells[column].flags = CellFlags::HYPERLINK;
        }
        assert_eq!(
            frame.hyperlink_spans(),
            vec![
                (0, ColumnSpan { start: 1, end: 4 }),
                (0, ColumnSpan { start: 6, end: 7 })
            ],
            "two runs, because column 4 broke the first one"
        );
    }

    #[test]
    fn a_hyperlink_running_to_the_edge_closes_at_the_last_column() {
        let mut frame = blank_frame(4, 1);
        for cell in &mut frame.rows[0].cells {
            cell.flags = CellFlags::HYPERLINK;
        }
        assert_eq!(frame.hyperlink_spans(), vec![(0, ColumnSpan {
            start: 0,
            end: 4
        })]);
        assert!(
            blank_frame(4, 1).hyperlink_spans().is_empty(),
            "a viewport with no links reports none"
        );
    }

    #[test]
    fn a_packed_colour_is_little_endian_bgr() {
        assert_eq!(Rgb::new(0x12, 0x34, 0x56).packed(), 0x0056_3412);
        assert_eq!(Rgb::BLACK.packed(), 0);
        assert_eq!(Rgb::WHITE.packed(), 0x00FF_FFFF);
    }

    #[test]
    fn flags_set_and_clear_without_touching_their_neighbours() {
        let flags = CellFlags::NONE.union(CellFlags::BOLD).union(CellFlags::ITALIC);
        assert!(flags.contains(CellFlags::BOLD));
        assert!(flags.contains(CellFlags::ITALIC));
        assert!(!flags.contains(CellFlags::FAINT));

        let cleared = flags.without(CellFlags::BOLD);
        assert!(!cleared.contains(CellFlags::BOLD));
        assert!(cleared.contains(CellFlags::ITALIC), "the neighbour survives");

        assert!(
            CellFlags::NONE
                .set(CellFlags::BLINK, true)
                .contains(CellFlags::BLINK)
        );
        assert!(!flags.set(CellFlags::BOLD, false).contains(CellFlags::BOLD));
    }

    #[test]
    fn only_the_halves_of_a_wide_pair_hide_their_glyph() {
        assert!(CellFlags::WIDE_TAIL.hides_glyph());
        assert!(CellFlags::WIDE_HEAD.hides_glyph());
        assert!(
            !CellFlags::WIDE.hides_glyph(),
            "the leading half is where the glyph is drawn"
        );
        assert!(!CellFlags::NONE.hides_glyph());
    }

    #[test]
    fn a_refilled_row_reuses_its_allocations_and_reads_back_its_text() {
        let mut row = FrameRow::default();
        row.begin_fill();
        row.push_cell("a", FrameCell::default());
        row.push_cell("é", FrameCell::default());
        row.push_cell("", FrameCell::default());

        let capacity = row.text.capacity();
        assert_eq!(row.cells.len(), 3);
        assert_eq!(row.cell_text(row.cells[0]), "a");
        assert_eq!(row.cell_text(row.cells[1]), "é", "two bytes, one cluster");
        assert_eq!(row.cell_text(row.cells[2]), "", "a blank cell has no text");

        row.begin_fill();
        assert!(row.cells.is_empty());
        assert!(row.selection.is_none());
        assert_eq!(row.text.capacity(), capacity, "the arena is kept, not freed");
    }

    #[test]
    fn a_span_slices_the_arena_it_was_interned_into() {
        let span = TextSpan { offset: 1, len: 2 };
        assert_eq!(span.range(), 1..3);
        assert!(!span.is_empty());
        assert!(TextSpan::default().is_empty());
    }

    #[test]
    fn a_column_span_is_half_open() {
        let span = ColumnSpan { start: 2, end: 5 };
        assert!(!span.contains(1));
        assert!(span.contains(2));
        assert!(span.contains(4));
        assert!(!span.contains(5), "end is one past the last selected column");
        assert_eq!(span.width(), 3);
    }

    #[test]
    fn row_text_pads_blanks_and_trims_the_tail() {
        let mut frame = Frame::new();
        frame.reshape(4, 1);
        let row = &mut frame.rows[0];
        row.begin_fill();
        row.push_cell("h", FrameCell::default());
        row.push_cell("", FrameCell::default());
        row.push_cell("i", FrameCell::default());
        row.push_cell("", FrameCell::default());

        assert_eq!(frame.row_text(0), "h i", "inner blanks stay, the tail goes");
        assert_eq!(frame.row_text(9), "", "past the bottom is empty, not a panic");
    }

    #[test]
    fn row_text_skips_the_tail_of_a_wide_pair() {
        let mut frame = Frame::new();
        frame.reshape(2, 1);
        let row = &mut frame.rows[0];
        row.begin_fill();
        row.push_cell("漢", FrameCell {
            flags: CellFlags::WIDE,
            ..FrameCell::default()
        });
        row.push_cell("", FrameCell {
            flags: CellFlags::WIDE_TAIL,
            ..FrameCell::default()
        });
        assert_eq!(frame.row_text(0), "漢", "the tail contributes nothing");
    }

    #[test]
    fn reshaping_keeps_the_rows_it_can_and_adds_the_rest() {
        let mut frame = Frame::new();
        frame.reshape(80, 24);
        assert_eq!(frame.rows.len(), 24);
        assert_eq!(frame.row_count(), 24);
        frame.rows[0].push_cell("x", FrameCell::default());

        frame.reshape(80, 40);
        assert_eq!(frame.rows.len(), 40);
        assert_eq!(frame.rows[0].cells.len(), 1, "an existing row is untouched");

        frame.reshape(80, 2);
        assert_eq!(frame.rows.len(), 2);
    }

    #[test]
    fn the_defaults_line_up_with_an_unstyled_cell() {
        let cell = FrameCell::default();
        assert_eq!(cell.underline, UnderlineStyle::None);
        assert_eq!(cell.flags, CellFlags::NONE);
        assert!(cell.text.is_empty());
        assert_eq!(RowSemantic::default(), RowSemantic::Output);
    }

    #[test]
    fn ascii_measures_one_cell_a_character() {
        assert_eq!(text_cells("hello"), 5);
        assert_eq!(text_cells(""), 0);
    }

    #[test]
    fn an_east_asian_character_measures_two() {
        assert_eq!(text_cells("漢字"), 4);
        assert_eq!(text_cells("a漢"), 3);
    }

    #[test]
    fn a_base_and_its_combining_marks_measure_one_cell_together() {
        // The Telex case, and the reason this is the ENGINE's segmenter rather than a width table:
        // `e` + combining circumflex + combining acute is one cluster in one cell, and a per-scalar
        // count would place a composition's caret three cells too far right.
        assert_eq!(text_cells("e\u{0302}\u{0301}"), 1);
        assert_eq!(text_cells("ế"), 1, "the same syllable, precomposed");
    }
}
