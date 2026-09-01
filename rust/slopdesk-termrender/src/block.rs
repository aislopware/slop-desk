//! Blocks as layout, which is the whole reason the surface API had to go.
//!
//! ## What a block is here
//!
//! `rust/slopdesk-terminal/src/blocks.rs` already models a command block as *metadata* — index,
//! command text, exit code, duration — pushed from the host and drawn nowhere. This module supplies
//! the missing layer named in `docs/68` §5.3: where those blocks are on screen. It does not
//! duplicate the ring; it segments the *frame*, using the one thing the ring cannot see, which is
//! which viewport row a prompt landed on.
//!
//! The segmentation is [`RowSemantic`], which the engine fills from OSC 133. A
//! [`RowSemantic::Prompt`] row opens a block; the [`RowSemantic::PromptContinuation`] rows after it
//! are the rest of the same prompt; everything until the next prompt is that block's output. No
//! heuristics, no text matching — the shell already said where the boundaries are.
//!
//! ## The alt-screen escape hatch is a chrome value, not a branch
//!
//! vim and htop need the flat grid. The obvious shape for that is an `enum { Blocks, Grid }` and
//! two layout paths — and two paths is one too many, because the second would be the one nobody
//! tests. Instead, [`LayoutMode::Grid`] segments the whole viewport into ONE block and
//! [`Chrome::NONE`] gives it no header, no gutter and no gap. The alt screen falls out as the
//! degenerate case of the block layout rather than as an alternative to it, so a bug in row
//! placement fails in vim and in the block list at the same time, where it will be found.
//!
//! ## Virtualisation
//!
//! [`lay_out`] places every block — a scrollbar needs the total height, so the ones off screen
//! still have to be measured — but only resolves the visible ROWS of the blocks the viewport
//! touches. Measuring is arithmetic per block; resolving is work per row. A scrollback with ten
//! thousand blocks costs ten thousand additions and draws forty rows.

use slopdesk_terminal::geometry::Rect;
use slopdesk_vterm::{Frame, RowSemantic};

/// Whether the surface is drawing command blocks or a flat grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum LayoutMode {
    /// One block per OSC 133 prompt — the main screen.
    #[default]
    Blocks,
    /// One block covering the viewport — the alternate screen, where a full-screen program owns
    /// every cell and a header drawn across the middle of it would be vandalism.
    Grid,
}

impl LayoutMode {
    /// The mode for a screen, given whether the terminal is on the alternate one.
    #[must_use]
    pub const fn for_screen(alternate: bool) -> Self {
        if alternate { Self::Grid } else { Self::Blocks }
    }
}

/// A half-open run of viewport rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RowRange {
    /// First row.
    pub start: u16,
    /// One past the last row.
    pub end: u16,
}

impl RowRange {
    /// How many rows the range covers.
    #[must_use]
    pub const fn len(self) -> u16 {
        self.end.saturating_sub(self.start)
    }

    /// Whether the range covers no rows.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.end <= self.start
    }

    /// Whether `row` is inside.
    #[must_use]
    pub const fn contains(self, row: u16) -> bool {
        row >= self.start && row < self.end
    }
}

/// One command block's rows, before anything has been placed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BlockSpan {
    /// The block's rows in the viewport.
    pub rows: RowRange,
    /// How many of them, from the top, are the prompt line and its wraps.
    ///
    /// This is what a collapsed block keeps: the command stays readable, the output folds away.
    pub prompt_rows: u16,
}

impl BlockSpan {
    /// The output rows — everything after the prompt.
    #[must_use]
    pub const fn output_rows(self) -> u16 {
        self.rows.len().saturating_sub(self.prompt_rows)
    }

    /// Whether the block has no prompt of its own.
    ///
    /// True for the rows above the first prompt in the viewport: output whose command has scrolled
    /// off, or a session joined mid-stream. It is still a block — it has to be placed and drawn —
    /// but it gets no header, because there is no command to put in one.
    #[must_use]
    pub const fn is_orphan(self) -> bool {
        self.prompt_rows == 0
    }
}

/// The furniture drawn around a block.
///
/// Device pixels, like everything else in this crate. Zero fields are meaningful: `Chrome::NONE` is
/// what makes the alt screen the degenerate case rather than a second code path.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Chrome {
    /// Height of the header strip above a block — where the exit code, duration and controls go.
    pub header: f64,
    /// Vertical gap between one block and the next.
    pub gap: f64,
    /// Width of the gutter reserved at the leading edge, inside which the status mark is drawn.
    pub gutter: f64,
}

impl Chrome {
    /// No furniture at all — the alternate screen.
    pub const NONE: Self = Self {
        header: 0.0,
        gap: 0.0,
        gutter: 0.0,
    };
}

/// A block with a place in the CONTENT, which is not yet a place on screen.
///
/// Every rect here is measured from the top of the first block, at x zero — [`lay_out`] knows
/// neither the drawable's insets nor how far the view is scrolled. Whoever draws adds both back;
/// see [`PlacedBlock::translated`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlacedBlock {
    /// Which rows this block holds.
    pub span: BlockSpan,
    /// The block's whole box, header included.
    pub frame: Rect,
    /// The header strip, or `None` for an orphan block and for [`Chrome::NONE`].
    pub header: Option<Rect>,
    /// The rows' box, below the header and right of the gutter.
    pub body: Rect,
    /// Whether the output is folded away.
    pub collapsed: bool,
    /// The rows that intersect the viewport, or an empty range for a block that is off screen.
    ///
    /// Row indices are the FRAME's, not the block's, so a caller draws `frame.row(y)` directly and
    /// cannot introduce an off-by-one converting between the two.
    pub visible: RowRange,
}

impl PlacedBlock {
    /// Whether any of this block is on screen.
    #[must_use]
    pub const fn is_visible(&self) -> bool {
        !self.visible.is_empty()
    }

    /// The y of one of this block's rows, in the same space as [`PlacedBlock::frame`].
    ///
    /// `None` for a row this block does not hold, or one folded away by a collapse.
    #[must_use]
    pub fn row_y(&self, row: u16, cell_height: f64) -> Option<f64> {
        if !self.span.rows.contains(row) {
            return None;
        }
        let offset = row - self.span.rows.start;
        if self.collapsed && offset >= self.span.prompt_rows {
            return None;
        }
        Some(self.body.y + cell_height * f64::from(offset))
    }

    /// The height of this block's HEAD — its header band, plus the prompt rows under it.
    ///
    /// The unit [`crate::pin`] keeps on screen: everything that says WHICH command this is, and
    /// nothing that says what it printed. Zero for a block with no header, which is an orphan or
    /// the alternate screen — neither has a command of its own worth pinning.
    ///
    /// For a COLLAPSED block this is the whole frame, since a collapse is exactly the fold that
    /// leaves the head and nothing else.
    #[must_use]
    pub fn head_height(&self, cell_height: f64) -> f64 {
        self.header.map_or(0.0, |header| {
            header.height + cell_height * f64::from(self.span.prompt_rows)
        })
    }

    /// The same block with its rects moved into the drawable's space.
    ///
    /// The paint pass makes this move inline for every row it places — x by
    /// `CellMetrics::origin_x`, y by `PaintStyle::content_origin_y`, which carries the top inset
    /// and the scroll offset together. Anything else that draws on a block's rects has to make the
    /// IDENTICAL move, and this is the one copy of it: furniture placed a scroll offset away from
    /// the rows it decorates is what this exists to make impossible.
    ///
    /// [`PlacedBlock::span`] and [`PlacedBlock::visible`] are row indices, not lengths, so they
    /// come across untouched.
    #[must_use]
    pub fn translated(&self, dx: f64, dy: f64) -> Self {
        let shift = |rect: Rect| {
            Rect {
                x: rect.x + dx,
                y: rect.y + dy,
                ..rect
            }
        };
        Self {
            frame: shift(self.frame),
            header: self.header.map(shift),
            body: shift(self.body),
            ..*self
        }
    }
}

/// Every block, placed, plus the total height a scrollbar measures against.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct BlockLayout {
    /// The blocks, top to bottom.
    pub blocks: Vec<PlacedBlock>,
    /// The height of everything laid out, gaps included but not the trailing one.
    pub content_height: f64,
}

impl BlockLayout {
    /// The block holding `row`, if any.
    #[must_use]
    pub fn block_at_row(&self, row: u16) -> Option<&PlacedBlock> {
        self.blocks.iter().find(|block| block.span.rows.contains(row))
    }

    /// The blocks that intersect the viewport, in order.
    pub fn visible(&self) -> impl Iterator<Item = &PlacedBlock> {
        self.blocks.iter().filter(|block| block.is_visible())
    }

    /// The row top nearest `y`, which is where a scroll settles with smooth scrolling off.
    ///
    /// Rows are not at multiples of `cell_height` in a block layout — the chrome sits between them
    /// — so a snap has to ask the placement rather than round. Inside the content this walks
    /// the placed rows; OUTSIDE it, in the blank the overscroll policies open, it rounds to a
    /// whole cell from the nearest edge, because that blank IS made of rows and quantising it
    /// any other way would leave a partial one against the viewport edge.
    ///
    /// A layout with no rows at all answers `y` unchanged: there is no boundary to prefer, and
    /// moving the offset would be inventing one.
    #[must_use]
    pub fn nearest_row_top(&self, y: f64, cell_height: f64) -> f64 {
        if !cell_height.is_finite() || cell_height <= 0.0 || !y.is_finite() {
            return y;
        }
        let mut nearest: Option<f64> = None;
        let mut first: Option<f64> = None;
        let mut last: Option<f64> = None;
        for block in &self.blocks {
            for row in block.span.rows.start..block.span.rows.end {
                let Some(top) = block.row_y(row, cell_height) else {
                    continue;
                };
                if nearest.is_none_or(|best: f64| (top - y).abs() < (best - y).abs()) {
                    nearest = Some(top);
                }
                first = Some(first.map_or(top, |edge| f64::min(edge, top)));
                last = Some(last.map_or(top, |edge| f64::max(edge, top)));
            }
        }
        let (Some(nearest), Some(first), Some(last)) = (nearest, first, last) else {
            return y;
        };
        // Beyond the outermost row, keep counting in whole cells from that edge. Snapping back to
        // the edge row instead would collapse the whole overscroll gap on the first settle, which
        // is a detent nobody asked for. INSIDE the content the walk's answer already stands — the
        // chrome between two blocks is wider than a cell, and rounding across it would land on a
        // pixel that is no row's top.
        let edge = if y < first {
            first
        } else if y > last {
            last
        } else {
            return nearest;
        };
        edge + ((y - edge) / cell_height).round() * cell_height
    }
}

/// The window a layout is virtualised against.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Viewport {
    /// How far the content has scrolled, in device pixels.
    pub scroll_y: f64,
    /// The visible height in device pixels.
    pub height: f64,
    /// The visible width in device pixels.
    pub width: f64,
}

/// Splits a frame's rows into blocks.
///
/// [`LayoutMode::Grid`] answers one span covering everything, which is what makes the alt screen
/// the degenerate case. An empty frame answers no spans at all rather than one empty block — there
/// is nothing to place, and a zero-row block would put a header on screen with no command under it.
#[must_use]
pub fn segment(frame: &Frame, mode: LayoutMode) -> Vec<BlockSpan> {
    let count = frame.row_count();
    if count == 0 {
        return Vec::new();
    }
    if mode == LayoutMode::Grid {
        return vec![BlockSpan {
            rows: RowRange { start: 0, end: count },
            prompt_rows: 0,
        }];
    }

    let mut spans: Vec<BlockSpan> = Vec::new();
    for row in 0..count {
        let semantic = frame.row(row).map_or(RowSemantic::Output, |held| held.semantic);
        match semantic {
            // A prompt opens a block. The one before it ends here, whatever it was in the middle of.
            RowSemantic::Prompt => {
                spans.push(BlockSpan {
                    rows: RowRange {
                        start: row,
                        end: row.saturating_add(1),
                    },
                    prompt_rows: 1,
                });
            },
            RowSemantic::PromptContinuation | RowSemantic::Output => {
                let extend_prompt = semantic == RowSemantic::PromptContinuation;
                if let Some(open) = spans.last_mut() {
                    open.rows.end = row.saturating_add(1);
                    // A continuation only counts toward the prompt while the prompt is still the
                    // block's last row. A stray `k=c` after output is a shell bug, and treating it
                    // as prompt would fold output into the part a collapse keeps.
                    if extend_prompt && open.prompt_rows == row - open.rows.start {
                        open.prompt_rows = open.prompt_rows.saturating_add(1);
                    }
                } else {
                    // Rows above the first prompt: output whose command has scrolled off.
                    spans.push(BlockSpan {
                        rows: RowRange {
                            start: row,
                            end: row.saturating_add(1),
                        },
                        prompt_rows: 0,
                    });
                }
            },
        }
    }
    spans
}

/// Places `spans` and resolves the visible rows of the ones the viewport touches.
///
/// `collapsed` is read positionally and a short slice means "not collapsed" for the rest, so a
/// caller whose collapse state lags a resize by one frame draws an expanded block rather than
/// panicking or silently folding the wrong one.
#[must_use]
pub fn lay_out(
    spans: &[BlockSpan],
    collapsed: &[bool],
    chrome: Chrome,
    cell_height: f64,
    viewport: Viewport,
) -> BlockLayout {
    let mut blocks = Vec::with_capacity(spans.len());
    let mut y = 0.0_f64;
    let visible_top = viewport.scroll_y;
    let visible_bottom = viewport.scroll_y + viewport.height;

    for (index, span) in spans.iter().enumerate() {
        let is_collapsed = collapsed.get(index).copied().unwrap_or(false);
        // An orphan has no command to head, so it gets no header — and a collapse would fold away
        // the only thing it holds, so it is never collapsed either.
        let has_header = chrome.header > 0.0 && !span.is_orphan();
        let is_collapsed = is_collapsed && !span.is_orphan();
        let header_height = if has_header { chrome.header } else { 0.0 };

        let drawn_rows = if is_collapsed {
            span.prompt_rows
        } else {
            span.rows.len()
        };
        let body_height = cell_height * f64::from(drawn_rows);
        let height = header_height + body_height;

        let frame = Rect {
            x: 0.0,
            y,
            width: viewport.width,
            height,
        };
        let header = has_header.then_some(Rect {
            height: header_height,
            ..frame
        });
        let body = Rect {
            x: chrome.gutter,
            y: y + header_height,
            width: f64::max(viewport.width - chrome.gutter, 0.0),
            height: body_height,
        };

        // Virtualisation: only a block the viewport touches pays for a row-range resolution.
        let visible = if height > 0.0 && y < visible_bottom && y + height > visible_top {
            visible_rows(
                *span,
                body.y,
                cell_height,
                drawn_rows,
                visible_top,
                visible_bottom,
            )
        } else {
            RowRange::default()
        };

        blocks.push(PlacedBlock {
            span: *span,
            frame,
            header,
            body,
            collapsed: is_collapsed,
            visible,
        });
        y += height + chrome.gap;
    }

    BlockLayout {
        content_height: f64::max(y - chrome.gap, 0.0),
        blocks,
    }
}

/// The frame rows of one block that intersect `top..bottom`.
fn visible_rows(
    span: BlockSpan,
    body_top: f64,
    cell_height: f64,
    drawn_rows: u16,
    top: f64,
    bottom: f64,
) -> RowRange {
    if cell_height <= 0.0 || drawn_rows == 0 {
        return RowRange::default();
    }
    let first = offset_at(top - body_top, cell_height, drawn_rows);
    // The row containing `bottom` is still partly visible, so the end is one past it.
    let last = offset_at(bottom - body_top, cell_height, drawn_rows);
    let end = if (bottom - body_top) > cell_height * f64::from(last) {
        last.saturating_add(1).min(drawn_rows)
    } else {
        last
    };
    if end <= first {
        return RowRange::default();
    }
    RowRange {
        start: span.rows.start.saturating_add(first),
        end: span.rows.start.saturating_add(end),
    }
}

/// Which row offset `distance` device pixels below the body's top lands on, clamped to the block.
fn offset_at(distance: f64, cell_height: f64, drawn_rows: u16) -> u16 {
    if distance.is_nan() || distance <= 0.0 {
        return 0;
    }
    let index = f64::min(distance / cell_height, f64::from(drawn_rows));
    // Floored and fenced to `0.0..=drawn_rows` immediately above.
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "fenced into 0..=drawn_rows by the guard and the min above"
    )]
    let offset = index.floor() as u16;
    offset.min(drawn_rows)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_vterm::{Frame, FrameRow, RowSemantic};

    use super::{BlockLayout, Chrome, LayoutMode, RowRange, Viewport, lay_out, segment};

    fn frame(semantics: &[RowSemantic]) -> Frame {
        Frame {
            cols: 8,
            rows: semantics
                .iter()
                .map(|semantic| {
                    FrameRow {
                        semantic: *semantic,
                        ..FrameRow::default()
                    }
                })
                .collect(),
            ..Frame::new()
        }
    }

    const OUT: RowSemantic = RowSemantic::Output;
    const PROMPT: RowSemantic = RowSemantic::Prompt;
    const CONT: RowSemantic = RowSemantic::PromptContinuation;

    fn viewport(height: f64) -> Viewport {
        Viewport {
            scroll_y: 0.0,
            height,
            width: 400.0,
        }
    }

    const CHROME: Chrome = Chrome {
        header: 24.0,
        gap: 8.0,
        gutter: 12.0,
    };

    #[test]
    fn a_prompt_opens_a_block_and_output_extends_it() {
        let spans = segment(&frame(&[PROMPT, OUT, OUT, PROMPT, OUT]), LayoutMode::Blocks);

        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].rows, RowRange { start: 0, end: 3 });
        assert_eq!(spans[0].prompt_rows, 1);
        assert_eq!(spans[0].output_rows(), 2);
        assert_eq!(spans[1].rows, RowRange { start: 3, end: 5 });
    }

    #[test]
    fn a_wrapped_prompt_counts_as_prompt_and_a_stray_continuation_does_not() {
        let wrapped = segment(&frame(&[PROMPT, CONT, OUT]), LayoutMode::Blocks);
        assert_eq!(wrapped[0].prompt_rows, 2);
        assert_eq!(wrapped[0].output_rows(), 1);

        // A continuation AFTER output is a shell bug; folding output into the prompt would make a
        // collapse keep the wrong rows.
        let stray = segment(&frame(&[PROMPT, OUT, CONT]), LayoutMode::Blocks);
        assert_eq!(stray[0].prompt_rows, 1);
        assert_eq!(stray[0].output_rows(), 2);
    }

    #[test]
    fn rows_above_the_first_prompt_are_an_orphan_block() {
        let spans = segment(&frame(&[OUT, OUT, PROMPT, OUT]), LayoutMode::Blocks);

        assert_eq!(spans.len(), 2);
        assert!(spans[0].is_orphan());
        assert_eq!(spans[0].rows, RowRange { start: 0, end: 2 });
        assert!(!spans[1].is_orphan());
    }

    #[test]
    fn the_alt_screen_is_one_block_with_no_furniture() {
        let spans = segment(&frame(&[PROMPT, OUT, PROMPT]), LayoutMode::Grid);
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].rows, RowRange { start: 0, end: 3 });

        let layout = lay_out(&spans, &[], Chrome::NONE, 20.0, viewport(60.0));
        assert_eq!(layout.blocks[0].header, None);
        assert!((layout.blocks[0].body.y).abs() < f64::EPSILON);
        assert!((layout.content_height - 60.0).abs() < f64::EPSILON);
    }

    #[test]
    fn an_empty_frame_lays_out_nothing() {
        assert!(segment(&Frame::new(), LayoutMode::Blocks).is_empty());
        assert!(segment(&Frame::new(), LayoutMode::Grid).is_empty());
    }

    #[test]
    fn a_collapsed_block_keeps_its_prompt_and_folds_its_output() {
        let spans = segment(&frame(&[PROMPT, OUT, OUT, OUT]), LayoutMode::Blocks);
        let expanded = lay_out(&spans, &[false], CHROME, 20.0, viewport(500.0));
        let collapsed = lay_out(&spans, &[true], CHROME, 20.0, viewport(500.0));

        assert!((expanded.blocks[0].frame.height - (24.0 + 80.0)).abs() < f64::EPSILON);
        assert!((collapsed.blocks[0].frame.height - (24.0 + 20.0)).abs() < f64::EPSILON);
        assert_eq!(collapsed.blocks[0].visible, RowRange { start: 0, end: 1 });
        assert_eq!(
            collapsed.blocks[0].row_y(2, 20.0),
            None,
            "a folded row has no place"
        );
    }

    #[test]
    fn an_orphan_gets_no_header_and_cannot_be_collapsed() {
        let spans = segment(&frame(&[OUT, OUT]), LayoutMode::Blocks);
        let layout = lay_out(&spans, &[true], CHROME, 20.0, viewport(500.0));

        assert_eq!(layout.blocks[0].header, None);
        assert!(!layout.blocks[0].collapsed);
        assert!((layout.blocks[0].frame.height - 40.0).abs() < f64::EPSILON);
    }

    #[test]
    fn blocks_stack_with_a_gap_that_the_content_height_does_not_trail() {
        let spans = segment(&frame(&[PROMPT, OUT, PROMPT, OUT]), LayoutMode::Blocks);
        let layout = lay_out(&spans, &[], CHROME, 20.0, viewport(500.0));

        let first = layout.blocks[0].frame;
        assert!((layout.blocks[1].frame.y - (first.y + first.height + CHROME.gap)).abs() < f64::EPSILON);
        // Two blocks of 24 + 40, one gap of 8 between them and none after.
        assert!((layout.content_height - (64.0 * 2.0 + 8.0)).abs() < f64::EPSILON);
    }

    #[test]
    fn the_body_starts_after_the_header_and_right_of_the_gutter() {
        let spans = segment(&frame(&[PROMPT, OUT]), LayoutMode::Blocks);
        let layout = lay_out(&spans, &[], CHROME, 20.0, viewport(500.0));
        let block = layout.blocks[0];

        assert!((block.body.y - CHROME.header).abs() < f64::EPSILON);
        assert!((block.body.x - CHROME.gutter).abs() < f64::EPSILON);
        assert!((block.body.width - (400.0 - CHROME.gutter)).abs() < f64::EPSILON);
        assert_eq!(block.row_y(1, 20.0), Some(CHROME.header + 20.0));
    }

    #[test]
    fn only_the_blocks_the_viewport_touches_resolve_their_rows() {
        // 40 blocks of one prompt row each: 24 header + 20 body + 8 gap = 52 apiece.
        let semantics: Vec<_> = (0..40).map(|_| PROMPT).collect();
        let spans = segment(&frame(&semantics), LayoutMode::Blocks);
        let layout = lay_out(&spans, &[], CHROME, 20.0, Viewport {
            scroll_y: 520.0,
            height: 104.0,
            width: 400.0,
        });

        assert_eq!(layout.blocks.len(), 40, "every block is still measured");
        let seen: Vec<u16> = layout.visible().map(|block| block.span.rows.start).collect();
        assert_eq!(
            seen,
            vec![10, 11],
            "only the blocks under the window resolved rows"
        );
    }

    #[test]
    fn a_partly_scrolled_block_reports_the_rows_the_window_cuts() {
        let semantics: Vec<_> = std::iter::once(PROMPT)
            .chain(std::iter::repeat_n(OUT, 19))
            .collect();
        let spans = segment(&frame(&semantics), LayoutMode::Blocks);
        let layout = lay_out(&spans, &[], Chrome::NONE, 20.0, Viewport {
            scroll_y: 50.0,
            height: 45.0,
            width: 400.0,
        });

        // 50..95 device pixels over 20-pixel rows covers rows 2, 3 and the top of 4.
        assert_eq!(layout.blocks[0].visible, RowRange { start: 2, end: 5 });
    }

    #[test]
    fn a_row_lookup_finds_its_block() {
        let spans = segment(&frame(&[PROMPT, OUT, PROMPT, OUT]), LayoutMode::Blocks);
        let layout = lay_out(&spans, &[], CHROME, 20.0, viewport(500.0));

        assert_eq!(layout.block_at_row(1).unwrap().span.rows.start, 0);
        assert_eq!(layout.block_at_row(3).unwrap().span.rows.start, 2);
        assert!(layout.block_at_row(9).is_none());
    }

    // ---- the row snap --------------------------------------------------------------------------

    /// Exact arithmetic on whole pixels, asserted the way this file's neighbours do — an epsilon
    /// here is the clippy-shaped spelling of `==`, not a tolerance anyone needs.
    fn is(had: f64, want: f64) {
        assert!((had - want).abs() < f64::EPSILON, "had {had}, wanted {want}");
    }

    /// Two blocks of one prompt and one output row each, 20-pixel rows under a 24-pixel header and
    /// an 8-pixel gap. Row tops: 24, 44 · 96, 116.
    fn snappable() -> BlockLayout {
        let spans = segment(&frame(&[PROMPT, OUT, PROMPT, OUT]), LayoutMode::Blocks);
        lay_out(&spans, &[], CHROME, 20.0, viewport(500.0))
    }

    #[test]
    fn a_snap_lands_on_a_row_and_not_on_a_multiple_of_the_cell() {
        let layout = snappable();
        // 100 is five whole cells and is NO row's top: the header and the gap above it are 32
        // pixels the rounding knows nothing about.
        is(layout.nearest_row_top(100.0, 20.0), 96.0);
        is(layout.nearest_row_top(46.0, 20.0), 44.0);
    }

    #[test]
    fn a_snap_inside_the_chrome_prefers_the_nearer_row_rather_than_rounding_across_it() {
        let layout = snappable();
        // 70 sits in the 32-pixel gutter between rows 44 and 96 — nearer the row above.
        is(layout.nearest_row_top(70.0, 20.0), 44.0);
        is(layout.nearest_row_top(80.0, 20.0), 96.0);
    }

    #[test]
    fn the_overscroll_blank_is_still_counted_in_whole_rows() {
        let layout = snappable();
        // Below the last row top the blank IS made of rows, so the count continues from that edge
        // rather than collapsing back onto it.
        is(layout.nearest_row_top(178.0, 20.0), 176.0);
        // And above the first, where the offsets are negative.
        is(layout.nearest_row_top(-38.0, 20.0), -36.0);
    }

    #[test]
    fn a_layout_with_no_rows_leaves_the_offset_alone() {
        is(BlockLayout::default().nearest_row_top(37.0, 20.0), 37.0);
        is(snappable().nearest_row_top(37.0, 0.0), 37.0);
        assert!(snappable().nearest_row_top(f64::NAN, 20.0).is_nan());
    }
}
