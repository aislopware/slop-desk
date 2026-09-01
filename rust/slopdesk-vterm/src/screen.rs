//! Addressing the grid by SCREEN row — the coordinate space the viewport scrolls through.
//!
//! Everything else in this crate speaks one of two spaces: pixels (the pointer doors) or viewport
//! cells (the frame). Neither can name a row that is not currently on screen, and three features
//! need to. Copy mode's cursor outlives the viewport it started in; the find bar's row-driven modes
//! match against rows nobody has scrolled to; block navigation counts prompts backwards through
//! output that scrolled off hours ago. This module is the third space: SCREEN coordinates, where
//! row 0 is the oldest row still retained and the newest row is `total_rows - 1`.
//!
//! ## Why the row readers format a selection instead of walking cells
//!
//! The engine's only per-cell text door is `GridRef::graphemes`, which answers ONE CELL and warns
//! in its own doc comment that it "isn't built to sustain the framerates needed for rendering". A
//! naive `screen_row_text` would be `cols` C calls; a naive scrollback mirror would be
//! `cols × total_rows` of them, which at a 10 000-row buffer is millions.
//!
//! The formatter is the bulk door: one call renders a whole span — unwrapping soft breaks and
//! trimming the blank padding a terminal pads short lines with. Crucially it takes the span as an
//! ARGUMENT (`FormatOptions::with_selection`), so nothing here installs a selection, nothing has to
//! restore one, and a read cannot be seen by the user or lost to an early return. A `Selection`
//! built from two grid refs is a snapshot, not terminal state.
//!
//! ## Why a row read can answer `None`
//!
//! A screen row index is a number the CALLER held across time — a copy-mode cursor, a find hit, a
//! block anchor — and the scrollback trims from the front. So the row it names may simply be gone
//! by the time it is read. That is an ordinary event, not an error: every door here answers
//! `Ok(None)` for a row past the end, and callers treat it as "that row scrolled away".

use libghostty_vt::screen::GridRef;
use libghostty_vt::selection::{Adjustment, FormatOptions, Selection};
use libghostty_vt::terminal::{Point, PointCoordinate};

use crate::frame::Frame;
use crate::search::{CellPos, LineScan, Matcher, SearchQuery, search_line};
use crate::session::{Result, VtError, VtSession};

/// One logical line of the buffer: its text, and the screen rows it occupies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogicalLineText {
    /// The first screen row of the line.
    pub first_row: u32,
    /// The last screen row of the line, inclusive. Equal to `first_row` for an unwrapped line.
    pub last_row: u32,
    /// The line's text, soft wraps joined and trailing padding trimmed.
    pub text: String,
}

/// One run of viewport cells sharing a single authored `OSC 8` URI.
///
/// The URI-bearing counterpart to [`Frame::hyperlink_spans`](crate::Frame::hyperlink_spans), and
/// the difference is the one that matters to anything that ACTUATES a link rather than drawing one:
/// two different links that abut with no character between them are one span there and two runs
/// here. An underline does not care; a hint label and a click do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HyperlinkRun {
    /// The viewport row the run sits on, counted from the top.
    pub row: u16,
    /// First linked column.
    pub start: u16,
    /// One past the last linked column.
    pub end: u16,
    /// The URI every cell of the run carries.
    pub uri: String,
}

/// One search hit, in SCREEN coordinates.
///
/// Both ends are inclusive, and they sit on different rows when the hit crosses a soft wrap — which
/// is what a highlight needs in order to draw two rectangles rather than one impossible one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScreenMatch {
    /// Column of the hit's first cell.
    pub start_col: u16,
    /// Screen row of the hit's first cell.
    pub start_row: u32,
    /// Column of the hit's last cell, inclusive.
    pub end_col: u16,
    /// Screen row of the hit's last cell, inclusive.
    pub end_row: u32,
}

/// Where the viewport sits in the screen coordinate space, and how much there is to sit in.
///
/// One struct rather than five getters because the five numbers are only ever meaningful together:
/// a caller that read `viewport_top_row` and `total_rows` in two calls could be answered from two
/// different grids if anything fed the terminal in between. Nothing can, on one thread — but a
/// shape that makes the question unanswerable is better than a comment saying it cannot be asked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ViewportInfo {
    /// Rows the screen coordinate space contains: retained scrollback plus the active grid. The
    /// last addressable row is `total_rows - 1`.
    pub total_rows: u32,
    /// The screen row currently at the TOP of the viewport. Add a viewport row index to this to get
    /// a screen row.
    pub viewport_top_row: u32,
    /// How many rows the viewport shows. Normally the grid height; smaller only when the whole
    /// buffer is shorter than the grid.
    pub viewport_rows: u32,
    /// Retained rows ABOVE the active grid.
    pub scrollback_rows: u32,
    /// The grid's width, so a caller sizing a row read does not need a second call.
    pub cols: u16,
}

impl ViewportInfo {
    /// Whether the viewport is showing the newest rows — the state output lands in.
    #[must_use]
    pub const fn is_at_bottom(self) -> bool {
        self.viewport_top_row.saturating_add(self.viewport_rows) >= self.total_rows
    }
}

/// Which way the selection's free end moves, and what it moves over.
///
/// A thin mirror of the engine's own `Adjustment` rather than a re-derivation, kept narrow to the
/// four directions the shift-arrow keybinds produce. The engine's `Home`/`End`/`PageUp`/`PageDown`
/// are deliberately absent: nothing in this app binds them, and a variant with no producer is a
/// door nobody checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectionAdjust {
    /// Up one row at the current column, or to the line's start if already at the top.
    Up,
    /// Down to the next non-blank row at the current column, or to the line's end if none exists.
    Down,
    /// Left to the previous non-empty cell, wrapping upward.
    Left,
    /// Right to the next non-empty cell, wrapping downward.
    Right,
}

impl From<SelectionAdjust> for Adjustment {
    fn from(value: SelectionAdjust) -> Self {
        match value {
            SelectionAdjust::Up => Self::Up,
            SelectionAdjust::Down => Self::Down,
            SelectionAdjust::Left => Self::Left,
            SelectionAdjust::Right => Self::Right,
        }
    }
}

/// Which of a row's two wrap flags [`VtSession::row_flag`] should read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RowFlag {
    /// The line continues on the row BELOW this one.
    Wrapped,
    /// This row continues the line on the row ABOVE it.
    WrapContinuation,
}

impl VtSession {
    /// Where the viewport is, in screen rows.
    ///
    /// # Errors
    /// The engine's own error if the terminal cannot report its scroll extent.
    pub fn viewport_info(&self) -> Result<ViewportInfo> {
        let scrollbar = self.terminal.scrollbar()?;
        // The engine counts in `u64` because its C struct does; the doors above take `u32` so a row
        // index costs four bytes at the FFI boundary rather than eight, and a grid that exceeded
        // `u32` rows would need four billion retained lines. Saturating rather than wrapping: an
        // impossible number must clamp to the largest addressable row, never wrap to row 0.
        Ok(ViewportInfo {
            total_rows: u32::try_from(scrollbar.total).unwrap_or(u32::MAX),
            viewport_top_row: u32::try_from(scrollbar.offset).unwrap_or(u32::MAX),
            viewport_rows: u32::try_from(scrollbar.len).unwrap_or(u32::MAX),
            scrollback_rows: u32::try_from(self.terminal.scrollback_rows()?).unwrap_or(u32::MAX),
            cols: self.cols,
        })
    }

    /// One screen row's text, with its trailing blank padding trimmed.
    ///
    /// Soft wraps are NOT unwrapped: this is one PHYSICAL row, because every caller that asks for a
    /// row by index got that index from something physical — a viewport offset, a match position, a
    /// cursor. [`Self::logical_line_text`] is the door for the other question.
    ///
    /// Answers `Ok(None)` for a row that is no longer retained; `Ok(Some(""))` for a blank one.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn screen_row_text(&self, row: u32) -> Result<Option<String>> {
        self.span_text(row, row, false)
    }

    /// The first and last screen row of the LOGICAL line `row` belongs to.
    ///
    /// A logical line is a run of physical rows joined by soft wraps: the run extends upwards while
    /// each row is a wrap continuation, and downwards while each row is itself wrapped. A row that
    /// is neither answers `(row, row)`.
    ///
    /// Answers `Ok(None)` for a row that is no longer retained.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn logical_line_range(&self, row: u32) -> Result<Option<(u32, u32)>> {
        let info = self.viewport_info()?;
        if row >= info.total_rows {
            return Ok(None);
        }
        let mut first = row;
        // Upwards while the row CONTINUES the one above it. The walk stops at row 0 whether or not
        // that row claims to continue something — there is nothing above it to continue, and a
        // buffer trimmed mid-line can leave exactly that claim behind.
        while first > 0 && self.row_flag(first, RowFlag::WrapContinuation)? {
            first -= 1;
        }
        let mut last = row;
        // Downwards while the row IS wrapped, i.e. the line continues below it.
        while last.saturating_add(1) < info.total_rows && self.row_flag(last, RowFlag::Wrapped)? {
            last += 1;
        }
        Ok(Some((first, last)))
    }

    /// A logical line's text, soft wraps joined, trailing padding trimmed.
    ///
    /// Answers `Ok(None)` for a row that is no longer retained.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn logical_line_text(&self, row: u32) -> Result<Option<String>> {
        let Some((first, last)) = self.logical_line_range(row)? else {
            return Ok(None);
        };
        self.span_text(first, last, true)
    }

    /// Every retained row, oldest first, as LOGICAL lines — soft wraps collapsed, so one entry is
    /// one line a user would call a line.
    ///
    /// Each entry carries the screen rows it occupies, and that is the whole reason this returns a
    /// struct rather than `Vec<String>`: every caller turns a line it matched back into somewhere
    /// to SCROLL, and a bare list of strings makes that mapping the caller's arithmetic to get
    /// wrong. A line's index is not its row — one wrapped line is several rows.
    ///
    /// ⚠️ This is a whole-buffer read and allocates the whole buffer's text. It exists for the two
    /// callers that genuinely need it — the find bar's row-driven modes and the block extractor —
    /// and both call it on a gesture, never per frame. It must never enter the render path.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn logical_lines(&self) -> Result<Vec<LogicalLineText>> {
        let info = self.viewport_info()?;
        let mut lines = Vec::new();
        let mut first = 0_u32;
        while first < info.total_rows {
            // Downwards only: the walk starts at row 0 and every line begins where the previous one
            // ended, so there is never anything above `first` to join it to. That halves the flag
            // reads a per-row `logical_line_range` would do over the same buffer.
            let mut last = first;
            while last.saturating_add(1) < info.total_rows && self.row_flag(last, RowFlag::Wrapped)? {
                last += 1;
            }
            lines.push(LogicalLineText {
                first_row: first,
                last_row: last,
                text: self.span_text(first, last, true)?.unwrap_or_default(),
            });
            first = last.saturating_add(1);
        }
        Ok(lines)
    }

    /// Every hit of `query` in the WHOLE retained buffer, in reading order.
    ///
    /// ## Two passes, because one would cost millions of C calls
    ///
    /// The exact matcher needs cells — a byte offset is not a column, and only a cell walk can say
    /// which column a hit starts at. But a cell walk over a 10 000-row buffer is `cols × rows`
    /// calls into the engine, which is not a keystroke's worth of work. So the bulk formatter
    /// narrows first: [`Self::logical_lines`] renders every line in one call each, a plain
    /// containment test picks the candidates, and only those are walked cell by cell. A buffer
    /// with three hits costs three walks.
    ///
    /// The prefilter is deliberately a SUPERSET of the real matcher — it ignores `whole_word` and
    /// folds case even where the exact pass will not — because a prefilter that is too permissive
    /// costs a wasted walk, and one that is too strict silently loses a hit.
    ///
    /// ⚠️ The one thing it can lose: the formatter TRIMS each line's trailing blank padding, so a
    /// needle that ends in a space cannot be found at the end of a line. That is the padding a
    /// terminal invents, not text anyone typed, and matching it would find hits on rows that look
    /// blank.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn search_screen(&self, query: &SearchQuery<'_>) -> Result<Vec<ScreenMatch>> {
        // Compiled once for the whole buffer — the needle's fold or the pattern's automaton is a
        // per-QUERY cost, and this loop runs per line. `None` is an empty needle or a pattern that
        // does not compile, both of which find nothing.
        let Some(matcher) = Matcher::new(query) else {
            return Ok(Vec::new());
        };
        let mut hits = Vec::new();
        let mut scan = LineScan::new();
        for line in self.logical_lines()? {
            if !matcher.might_match(&line.text) {
                continue;
            }
            self.scan_line(line.first_row, line.last_row, &mut scan)?;
            hits.extend(search_line(&mut scan, &matcher).into_iter().map(|hit| {
                ScreenMatch {
                    start_col: hit.start.col,
                    start_row: line.first_row.saturating_add(u32::from(hit.start.row)),
                    end_col: hit.end.col,
                    end_row: line.first_row.saturating_add(u32::from(hit.end.row)),
                }
            }));
        }
        Ok(hits)
    }

    /// Feeds one logical line's cells into `scan`, in reading order.
    ///
    /// Rows are pushed by their offset WITHIN the line rather than by screen row, because
    /// [`slopdesk_vterm::search::CellPos`](crate::search::CellPos) counts rows in `u16` and a
    /// screen row does not fit one. The caller adds `first` back on the way out.
    fn scan_line(&self, first: u32, last: u32, scan: &mut LineScan) -> Result<()> {
        use libghostty_vt::screen::CellWide;

        scan.clear();
        // Sixteen scalars covers every cluster a terminal prints in practice — a base plus its
        // combining marks — and the retry below covers the ones it does not.
        let mut scalars = vec!['\0'; 16];
        let mut text = String::new();
        for (offset, row) in (first..=last).enumerate() {
            let y = u16::try_from(offset).unwrap_or(u16::MAX);
            for col in 0..self.cols {
                let grid = self.terminal.grid_ref(screen_point(col, row))?;
                let cell = grid.cell()?;
                // A wide cell's spacers carry no text of their own; pushing one would put a phantom
                // blank inside a CJK word and break a search for it.
                if matches!(cell.wide()?, CellWide::SpacerTail | CellWide::SpacerHead) {
                    continue;
                }
                text.clear();
                if cell.has_text()? {
                    read_graphemes(&grid, &mut scalars, &mut text)?;
                }
                scan.push_cell(&text, CellPos { row: y, col });
            }
        }
        Ok(())
    }

    /// Install a selection between two SCREEN coordinates, replacing whatever was selected.
    ///
    /// This is the coordinate-driven primitive, entirely separate from [`crate::selection`]'s
    /// gesture machine: copy mode's visual selection is computed from a cursor this crate never
    /// sees a pointer for, so it cannot be expressed as a press and a drag. Both machines end at
    /// the same `set_selection`, so only one selection ever exists.
    ///
    /// Answers `Ok(false)` when either endpoint is no longer retained, leaving the previous
    /// selection alone.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn set_screen_selection(
        &mut self,
        anchor: (u16, u32),
        head: (u16, u32),
        rectangle: bool,
    ) -> Result<bool> {
        let info = self.viewport_info()?;
        if anchor.1 >= info.total_rows || head.1 >= info.total_rows {
            return Ok(false);
        }
        let start = self.terminal.grid_ref(screen_point(anchor.0, anchor.1))?;
        let end = self.terminal.grid_ref(screen_point(head.0, head.1))?;
        self.terminal
            .set_selection(Some(&Selection::new(start, end, rectangle)))?;
        Ok(true)
    }

    /// Move the installed selection's free end one step, leaving its anchor where it is.
    ///
    /// The engine moves the LOGICAL end — the endpoint the selection was extended to — rather than
    /// whichever end is visually lower, so shift-↑ after a downward drag shrinks the selection
    /// instead of growing it upwards from the top. That is the behaviour a text field has, and it
    /// is the engine's, not this crate's.
    ///
    /// Answers `Ok(false)` when nothing is selected: there is no free end to move, and inventing
    /// one from the cursor would make shift-arrow select in a pane the user never clicked.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn adjust_selection(&mut self, adjust: SelectionAdjust) -> Result<bool> {
        let Some(mut selection) = self.terminal.selection()? else {
            return Ok(false);
        };
        selection.adjust(&self.terminal, adjust.into())?;
        self.terminal.set_selection(Some(&selection))?;
        Ok(true)
    }

    /// The screen row of the `delta`-th prompt from the viewport's top row.
    ///
    /// ⚠️ **HAND-ROLLED, because the engine has no prompt-jump door.** `libghostty-vt` exposes the
    /// per-row OSC 133 flag (`RowSemanticPrompt`) and nothing that navigates by it — not in the
    /// bindings and not in the C ABI underneath them. So this walks rows and counts, at one C call
    /// per row stepped over. That is affordable because a hop is a keystroke and the walk stops at
    /// the first match; it is bounded because it stops at the ends of the buffer.
    ///
    /// A positive delta walks towards newer output, negative towards older. A delta that runs out
    /// of prompts answers the LAST one it found rather than `None` — the caller's gesture is "go
    /// back three prompts", and landing on the oldest is the honest answer to that when only two
    /// exist. `None` means there was no prompt at all in that direction, or the delta was zero.
    ///
    /// # Errors
    /// The engine's own error.
    pub fn prompt_row(&self, delta: i16) -> Result<Option<u32>> {
        let info = self.viewport_info()?;
        if delta == 0 || info.total_rows == 0 {
            return Ok(None);
        }
        let forward = delta > 0;
        let wanted = delta.unsigned_abs();
        let mut row = info.viewport_top_row.min(info.total_rows - 1);
        let mut found = None;
        let mut seen = 0_u16;
        loop {
            // The starting row is stepped over whichever way the walk goes: a hop from a prompt row
            // must move, or `[` on a prompt would be a no-op that reads as a lost keystroke.
            if forward {
                if row.saturating_add(1) >= info.total_rows {
                    break;
                }
                row += 1;
            } else {
                if row == 0 {
                    break;
                }
                row -= 1;
            }
            if self.row_is_prompt(row)? {
                found = Some(row);
                seen = seen.saturating_add(1);
                if seen >= wanted {
                    break;
                }
            }
        }
        Ok(found)
    }

    /// The OSC 8 hyperlink URI at one VIEWPORT cell, or `None` when that cell carries no link.
    ///
    /// Viewport rather than screen coordinates because the only caller is a pointer, and a pointer
    /// names the cell it is over. The URI is read here rather than carried in the frame for the
    /// reason [`CellFlags::HYPERLINK`](crate::CellFlags::HYPERLINK) states: one URI is shared by a
    /// whole run of cells, so putting it on every cell would allocate a URL per character.
    ///
    /// Two attempts at the buffer, never a loop, for [`Self::span_text`]'s reason: the engine
    /// answers `OutOfSpace { required }` with the exact size, and nothing can touch this terminal
    /// between the attempts.
    ///
    /// # Errors
    /// The engine's own error, other than the out-of-space it retries.
    pub fn hyperlink_at(&self, x: u16, y: u32) -> Result<Option<String>> {
        let grid = self
            .terminal
            .grid_ref(Point::Viewport(PointCoordinate { x, y }))?;
        let mut buffer = [0_u8; 256];
        let length = match grid.hyperlink_uri(&mut buffer) {
            Ok(length) => length,
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                let mut grown = vec![0_u8; required];
                let length = grid.hyperlink_uri(&mut grown)?;
                return Ok(Some(decode(grown.get(..length).unwrap_or_default())));
            },
            Err(other) => return Err(other.into()),
        };
        if length == 0 {
            return Ok(None);
        }
        Ok(Some(decode(buffer.get(..length).unwrap_or_default())))
    }

    /// Every authored `OSC 8` run in the viewport, split wherever the URI changes.
    ///
    /// `frame` supplies the flagged cells, which is what keeps this affordable: the engine is asked
    /// only about cells [`CellFlags::HYPERLINK`](crate::CellFlags::HYPERLINK) already says carry a
    /// link, so an ordinary screen of text costs one frame walk and ZERO engine calls. A screen
    /// full of links costs one call per linked cell, which is why this is an on-demand door — a
    /// click, a hint scan — and [`Frame::hyperlink_spans`](crate::Frame::hyperlink_spans) remains
    /// what the per-frame underline reads.
    ///
    /// A cell the engine cannot resolve CLOSES the run rather than being skipped: the alternative
    /// is joining two links across a cell whose URI is unknown, and a target that opens the wrong
    /// thing is worse than one that is a character short.
    #[must_use]
    pub fn hyperlink_runs(&self, frame: &Frame) -> Vec<HyperlinkRun> {
        let mut runs = Vec::new();
        for (row, span) in frame.hyperlink_spans() {
            let mut open: Option<(u16, String)> = None;
            for column in span.start..span.end {
                let found = self.hyperlink_at(column, u32::from(row)).ok().flatten();
                open = match (found, open.take()) {
                    (Some(uri), Some((start, held))) if held == uri => Some((start, held)),
                    (Some(uri), Some((start, held))) => {
                        runs.push(HyperlinkRun {
                            row,
                            start,
                            end: column,
                            uri: held,
                        });
                        Some((column, uri))
                    },
                    (Some(uri), None) => Some((column, uri)),
                    (None, Some((start, held))) => {
                        runs.push(HyperlinkRun {
                            row,
                            start,
                            end: column,
                            uri: held,
                        });
                        None
                    },
                    (None, None) => None,
                };
            }
            if let Some((start, held)) = open {
                runs.push(HyperlinkRun {
                    row,
                    start,
                    end: span.end,
                    uri: held,
                });
            }
        }
        runs
    }

    /// Whether a screen row starts a shell prompt.
    ///
    /// Continuation rows do NOT count: a two-line prompt is one place to jump to, and counting both
    /// halves would make `[` take two presses to leave it.
    fn row_is_prompt(&self, row: u32) -> Result<bool> {
        use libghostty_vt::screen::RowSemanticPrompt;

        let grid = self.terminal.grid_ref(screen_point(0, row))?;
        Ok(grid.row()?.semantic_prompt()? == RowSemanticPrompt::Prompt)
    }

    /// One row's wrap flag.
    fn row_flag(&self, row: u32, flag: RowFlag) -> Result<bool> {
        let grid = self.terminal.grid_ref(screen_point(0, row))?;
        let row = grid.row()?;
        Ok(match flag {
            RowFlag::Wrapped => row.is_wrapped()?,
            RowFlag::WrapContinuation => row.is_wrap_continuation()?,
        })
    }

    /// The text of screen rows `first..=last`, formatted as a snapshot span.
    ///
    /// Two attempts at the buffer, never a loop, for the reason
    /// [`VtSession::selection_text`](crate::VtSession::selection_text) gives: the engine answers
    /// `OutOfSpace { required }` with the exact size, and nothing else can touch this terminal
    /// between the attempts, so the second cannot be short.
    fn span_text(&self, first: u32, last: u32, unwrap: bool) -> Result<Option<String>> {
        let info = self.viewport_info()?;
        let Some(last_column) = info.cols.checked_sub(1) else {
            return Ok(None);
        };
        if first >= info.total_rows || last >= info.total_rows {
            return Ok(None);
        }
        let start = self.terminal.grid_ref(screen_point(0, first))?;
        let end = self.terminal.grid_ref(screen_point(last_column, last))?;
        let span = Selection::new(start, end, false);
        let options = || {
            FormatOptions::new()
                .with_selection(&span)
                .with_unwrap(unwrap)
                .with_trim(true)
        };
        let mut small = [0_u8; 1024];
        let required = match self.terminal.format_selection_buf(options(), &mut small) {
            // The span always exists — it was built from two live grid refs — so `None` here means
            // the rows formatted to nothing at all. That is a blank row, not a missing one.
            Ok(None) => return Ok(Some(String::new())),
            Ok(Some(written)) => {
                return Ok(Some(decode(small.get(..written).unwrap_or(&[]))));
            },
            Err(libghostty_vt::error::Error::OutOfSpace { required }) => required,
            Err(error) => return Err(VtError::from(error)),
        };
        let mut large = vec![0_u8; required];
        Ok(Some(
            self.terminal
                .format_selection_buf(options(), &mut large)?
                .map_or_else(String::new, |written| decode(large.get(..written).unwrap_or(&[]))),
        ))
    }
}

/// A screen-space point. A free function so the two-line construction is written once —
/// `Point::Screen` wraps a coordinate whose `y` is a `u32` precisely because screen rows exceed a
/// viewport's `u16`.
/// One cell's grapheme cluster, appended to `text`.
///
/// `scalars` is the caller's reusable buffer, grown on the engine's own `required` count. The retry
/// cannot loop: a `required` that did not exceed the buffer we just offered would mean the engine
/// asked for space it already had, and treating that as "nothing to read" ends the call rather than
/// spinning on a contradiction.
fn read_graphemes(grid: &GridRef<'_>, scalars: &mut Vec<char>, text: &mut String) -> Result<()> {
    loop {
        match grid.graphemes(scalars) {
            Ok(len) => {
                text.extend(scalars.iter().take(len));
                return Ok(());
            },
            Err(libghostty_vt::error::Error::OutOfSpace { required }) if required > scalars.len() => {
                scalars.resize(required, '\0');
            },
            Err(libghostty_vt::error::Error::OutOfSpace { .. }) => return Ok(()),
            Err(error) => return Err(VtError::from(error)),
        }
    }
}

const fn screen_point(x: u16, y: u32) -> Point {
    Point::Screen(PointCoordinate { x, y })
}

/// The formatter's bytes as a `String`, lossily — the far side of a PTY may print any byte, and a
/// replacement character is a better answer than a read that refuses.
fn decode(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::SelectionAdjust;
    use crate::search::SearchQuery;
    use crate::selection::CopyFormat;
    use crate::session::{Scroll, VtSession};

    const COLS: u16 = 8;
    const ROWS: u16 = 3;

    /// An 8×3 grid, so a fourth fed line is the first one in the scrollback and the arithmetic is
    /// checkable by eye.
    fn session() -> VtSession {
        VtSession::new(COLS, ROWS, 10, 20).unwrap()
    }

    #[test]
    fn an_untouched_grid_reports_no_scrollback_and_a_viewport_at_the_bottom() {
        let vt = session();
        let info = vt.viewport_info().unwrap();
        assert_eq!(info.cols, 8);
        assert_eq!(info.scrollback_rows, 0);
        assert_eq!(info.viewport_top_row, 0);
        assert!(info.is_at_bottom());
    }

    #[test]
    fn a_fed_line_reads_back_at_its_screen_row() {
        let mut vt = session();
        vt.feed(b"alpha\r\nbeta\r\n");
        let info = vt.viewport_info().unwrap();
        assert_eq!(
            vt.screen_row_text(info.viewport_top_row).unwrap().as_deref(),
            Some("alpha")
        );
        assert_eq!(
            vt.screen_row_text(info.viewport_top_row + 1).unwrap().as_deref(),
            Some("beta")
        );
    }

    #[test]
    fn a_row_past_the_end_is_gone_rather_than_an_error() {
        let mut vt = session();
        vt.feed(b"alpha\r\n");
        let info = vt.viewport_info().unwrap();
        assert_eq!(vt.screen_row_text(info.total_rows).unwrap(), None);
        assert_eq!(vt.logical_line_range(info.total_rows).unwrap(), None);
    }

    /// Scrolled-off rows stay addressable, which is the whole reason this space exists: the
    /// viewport can no longer name row 0, and a screen coordinate still can.
    #[test]
    fn a_row_that_scrolled_off_is_still_addressable() {
        let mut vt = session();
        vt.feed(b"one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
        let info = vt.viewport_info().unwrap();
        assert!(info.scrollback_rows > 0, "nothing scrolled off");
        assert!(info.viewport_top_row > 0);
        assert_eq!(vt.screen_row_text(0).unwrap().as_deref(), Some("one"));
    }

    /// A line longer than the grid wraps, and the logical-line doors join it back up while
    /// `screen_row_text` keeps the physical halves apart.
    #[test]
    fn a_soft_wrapped_line_is_one_logical_line_and_two_physical_rows() {
        let mut vt = session();
        vt.feed(b"abcdefghijkl");
        let info = vt.viewport_info().unwrap();
        let first = info.viewport_top_row;
        assert_eq!(vt.screen_row_text(first).unwrap().as_deref(), Some("abcdefgh"));
        assert_eq!(vt.screen_row_text(first + 1).unwrap().as_deref(), Some("ijkl"));
        assert_eq!(
            vt.logical_line_range(first + 1).unwrap(),
            Some((first, first + 1)),
            "the continuation row did not walk back to its head"
        );
        assert_eq!(
            vt.logical_line_text(first + 1).unwrap().as_deref(),
            Some("abcdefghijkl")
        );
    }

    #[test]
    fn an_unwrapped_row_is_its_own_logical_line() {
        let mut vt = session();
        vt.feed(b"abc\r\n");
        let info = vt.viewport_info().unwrap();
        let row = info.viewport_top_row;
        assert_eq!(vt.logical_line_range(row).unwrap(), Some((row, row)));
    }

    /// A read is a snapshot and installs nothing — the property that lets these doors be `&self`
    /// and lets a caller read a row in the middle of a drag.
    #[test]
    fn a_row_read_leaves_the_selection_alone() {
        let mut vt = session();
        vt.feed(b"alpha\r\nbeta\r\n");
        assert!(!vt.has_selection().unwrap());
        drop(vt.screen_row_text(0).unwrap());
        drop(vt.logical_lines().unwrap());
        assert!(
            !vt.has_selection().unwrap(),
            "a read installed a selection and left it there"
        );

        assert!(vt.select_all().unwrap());
        let before = vt.selection_text(CopyFormat::Plain).unwrap();
        drop(vt.screen_row_text(0).unwrap());
        assert_eq!(
            vt.selection_text(CopyFormat::Plain).unwrap(),
            before,
            "a read replaced the caller's selection"
        );
    }

    #[test]
    fn a_screen_selection_is_the_text_between_its_endpoints() {
        let mut vt = session();
        vt.feed(b"alpha\r\nbeta\r\n");
        let info = vt.viewport_info().unwrap();
        let row = info.viewport_top_row;
        assert!(vt.set_screen_selection((0, row), (4, row), false).unwrap());
        assert_eq!(
            vt.selection_text(CopyFormat::Plain).unwrap().as_deref(),
            Some("alpha")
        );
    }

    #[test]
    fn a_screen_selection_past_the_end_changes_nothing() {
        let mut vt = session();
        vt.feed(b"alpha\r\n");
        let info = vt.viewport_info().unwrap();
        assert!(
            !vt.set_screen_selection((0, 0), (0, info.total_rows), false)
                .unwrap()
        );
        assert!(!vt.has_selection().unwrap());
    }

    /// Nothing selected means no free end to move — the shift-arrow keys must not conjure a
    /// selection in a pane the user never clicked.
    #[test]
    fn adjusting_nothing_selects_nothing() {
        let mut vt = session();
        vt.feed(b"alpha\r\n");
        assert!(!vt.adjust_selection(SelectionAdjust::Right).unwrap());
        assert!(!vt.has_selection().unwrap());
    }

    #[test]
    fn adjusting_a_selection_moves_its_free_end() {
        let mut vt = session();
        vt.feed(b"alpha\r\n");
        let info = vt.viewport_info().unwrap();
        let row = info.viewport_top_row;
        assert!(vt.set_screen_selection((0, row), (0, row), false).unwrap());
        let before = vt.selection_text(CopyFormat::Plain).unwrap();
        assert!(vt.adjust_selection(SelectionAdjust::Right).unwrap());
        assert_ne!(
            vt.selection_text(CopyFormat::Plain).unwrap(),
            before,
            "the free end did not move"
        );
    }

    #[test]
    fn the_whole_buffer_reads_back_as_logical_lines() {
        let mut vt = session();
        vt.feed(b"one\r\ntwo\r\nthree\r\nfour\r\n");
        let lines = vt.logical_lines().unwrap();
        assert!(
            lines.iter().any(|line| line.text == "one"),
            "the scrolled-off row is missing: {lines:?}"
        );
        assert!(lines.iter().any(|line| line.text == "four"));
        // The row a line reports is the row a caller would scroll to, so it must read back as that
        // same line. An off-by-one here is a find bar that lands one line above every hit.
        for line in &lines {
            assert_eq!(
                vt.logical_line_range(line.first_row).unwrap(),
                Some((line.first_row, line.last_row)),
                "the line at {} does not agree with its own range",
                line.first_row
            );
        }
    }

    /// A wrapped line is ONE entry spanning two rows, and its rows still map back to it — the
    /// property the find bar's scroll-to-hit depends on.
    #[test]
    fn a_wrapped_line_is_one_entry_over_two_rows() {
        let mut vt = session();
        vt.feed(&vec![b'x'; usize::from(COLS) + 4]);
        let wrapped = vt
            .logical_lines()
            .unwrap()
            .into_iter()
            .find(|line| line.last_row > line.first_row)
            .expect("nothing wrapped");
        assert_eq!(wrapped.last_row - wrapped.first_row, 1);
        assert_eq!(wrapped.text.len(), usize::from(COLS) + 4);
    }

    #[test]
    fn a_search_finds_a_hit_that_scrolled_off_the_viewport() {
        let mut vt = session();
        vt.feed(b"needle here\r\n");
        for _ in 0..ROWS {
            vt.feed(b"filler\r\n");
        }
        let hits = vt.search_screen(&SearchQuery::new("needle")).unwrap();
        assert_eq!(hits.len(), 1, "the scrolled-off hit is missing");
        let hit = hits[0];
        assert_eq!(hit.start_col, 0);
        assert_eq!(hit.end_col, 5);
        assert_eq!(hit.start_row, hit.end_row);
        assert!(
            hit.start_row < vt.viewport_info().unwrap().viewport_top_row,
            "the hit was inside the viewport, so this proves nothing"
        );
    }

    #[test]
    fn a_search_finds_a_hit_across_the_wrap_seam() {
        let mut vt = session();
        let head = usize::from(COLS) - 2;
        let mut line = vec![b'.'; head];
        line.extend_from_slice(b"seam");
        vt.feed(&line);
        let hits = vt.search_screen(&SearchQuery::new("seam")).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].end_row, hits[0].start_row + 1, "not wrapped");
        assert_eq!(hits[0].start_col, u16::try_from(head).unwrap());
        assert_eq!(hits[0].end_col, 1);
    }

    #[test]
    fn a_search_is_case_insensitive_unless_it_is_told_otherwise() {
        let mut vt = session();
        vt.feed(b"Cargo Build\r\n");
        assert_eq!(vt.search_screen(&SearchQuery::new("cargo")).unwrap().len(), 1);
        assert!(
            vt.search_screen(&SearchQuery::new("cargo").case_sensitive(true))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn an_empty_needle_finds_nothing() {
        let mut vt = session();
        vt.feed(b"alpha\r\n");
        assert!(vt.search_screen(&SearchQuery::new("")).unwrap().is_empty());
    }

    /// No OSC 133 in the stream means no prompt anywhere, in either direction.
    #[test]
    fn a_buffer_without_prompt_marks_has_no_prompt_to_jump_to() {
        let mut vt = session();
        vt.feed(b"one\r\ntwo\r\nthree\r\n");
        assert_eq!(vt.prompt_row(-1).unwrap(), None);
        assert_eq!(vt.prompt_row(1).unwrap(), None);
    }

    #[test]
    fn a_zero_delta_is_not_a_hop() {
        let mut vt = session();
        vt.feed(b"\x1b]133;A\x07$ one\r\n");
        assert_eq!(vt.prompt_row(0).unwrap(), None);
    }

    /// Two marked prompts, and a backwards hop from the bottom lands on the nearer one. The second
    /// hop lands on the older one; a third, with only two to find, stays on the oldest rather than
    /// answering nothing — the "runs out of prompts" rule in `prompt_row`'s doc.
    #[test]
    fn a_backwards_hop_counts_prompts_and_saturates_at_the_oldest() {
        let mut vt = VtSession::new(8, 3, 10, 20).unwrap();
        // Enough output AFTER the second prompt that the viewport top sits below both of them —
        // the walk steps over its starting row, so a viewport parked on a prompt hides it.
        vt.feed(b"\x1b]133;A\x07$ one\r\nout\r\n\x1b]133;A\x07$ two\r\nout\r\nout\r\nout\r\n");
        vt.scroll(Scroll::Bottom);
        let nearest = vt.prompt_row(-1).unwrap().expect("no prompt found");
        let older = vt.prompt_row(-2).unwrap().expect("no second prompt found");
        assert!(older < nearest, "the second hop did not go further back");
        assert_eq!(
            vt.prompt_row(-9).unwrap(),
            Some(older),
            "an over-long hop did not saturate at the oldest prompt"
        );
    }

    /// `Scroll::Row` puts an absolute screen row at the viewport's top — the variant the engine
    /// always had and this crate did not expose.
    #[test]
    fn scrolling_to_a_row_puts_it_at_the_viewport_top() {
        let mut vt = session();
        vt.feed(b"one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
        vt.scroll(Scroll::Row(0));
        let info = vt.viewport_info().unwrap();
        assert_eq!(info.viewport_top_row, 0);
        assert_eq!(vt.screen_row_text(0).unwrap().as_deref(), Some("one"));
    }

    /// A grid wide enough for two links and a margin.
    fn wide_session() -> VtSession {
        VtSession::new(40, 3, 10, 20).unwrap()
    }

    /// The whole reason `hyperlink_runs` exists next to `Frame::hyperlink_spans`.
    #[test]
    fn two_abutting_links_are_two_runs_where_the_frame_sees_one_span() {
        let mut vt = wide_session();
        vt.feed(b"\x1b]8;;https://a.example\x1b\\ab\x1b]8;;https://b.example\x1b\\cd\x1b]8;;\x1b\\");
        vt.render().unwrap();
        let frame = vt.frame().clone();
        assert_eq!(
            frame.hyperlink_spans().len(),
            1,
            "the flag alone cannot tell the two apart"
        );
        let runs = vt.hyperlink_runs(&frame);
        assert_eq!(runs.len(), 2);
        assert_eq!((runs[0].start, runs[0].end), (0, 2));
        assert_eq!(runs[0].uri, "https://a.example");
        assert_eq!((runs[1].start, runs[1].end), (2, 4));
        assert_eq!(runs[1].uri, "https://b.example");
    }

    /// The columns are the ENGINE's cells, so a wide character before a run moves it by two — the
    /// number a hint badge and a link underline both have to agree on.
    #[test]
    fn a_wide_character_before_a_run_offsets_it_by_two_cells() {
        let mut vt = wide_session();
        vt.feed("漢\u{1b}]8;;https://x.example\u{1b}\\ok\u{1b}]8;;\u{1b}\\".as_bytes());
        vt.render().unwrap();
        let frame = vt.frame().clone();
        let runs = vt.hyperlink_runs(&frame);
        assert_eq!(runs.len(), 1);
        assert_eq!((runs[0].start, runs[0].end), (2, 4));
    }

    #[test]
    fn a_screen_with_no_link_asks_the_engine_nothing_and_answers_nothing() {
        let mut vt = wide_session();
        vt.feed(b"plain text");
        vt.render().unwrap();
        let frame = vt.frame().clone();
        assert!(vt.hyperlink_runs(&frame).is_empty());
    }
}
