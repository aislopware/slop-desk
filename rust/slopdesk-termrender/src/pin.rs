//! The head of the block you are reading, kept on screen while its output scrolls under it.
//!
//! ## What it is for
//!
//! A block's command is one line at the TOP of a block, and the output that makes a block worth
//! scrolling is everything below it. So the longer the output, the longer the reader spends looking
//! at rows whose command has left the screen — which is the exact moment "what produced this?"
//! becomes unanswerable without scrolling back, losing your place, and scrolling forward again.
//! Pinning the head answers it for free, and only in the case where the answer is missing: a block
//! whose command is still on screen is never pinned, because there would be two of it.
//!
//! ## The two kinds of head, and why there have to be two
//!
//! A block's prompt can be off the top of two different things, and only one of them is a scroll.
//!
//! **It scrolled out of the LIST.** The prompt rows are still in the frame — the chrome above them
//! (header band, gap) is what pushed them past the content box's top edge. Then the head is
//! [`crate::paint::Painter::paint_row`] over those same rows at a new y: same cells, same runs,
//! same selection, same coalescing, by construction rather than by a second implementation. The
//! row on screen is the SHELL's rendering of the command — the prompt, its colours, the git branch,
//! the exit mark the user's own theme prints — and nothing else can stand in for it.
//!
//! **It scrolled out of the FRAME.** ⚠️ This is the case the feature exists for, and the first
//! version of this module could not draw it. The frame is one screenful, so a command whose output
//! is taller than the grid leaves a viewport with no prompt row in it at all — [`crate::block`]
//! calls that block an ORPHAN and gives it no header, because there is no command row to put in
//! one. `head_height` is therefore zero and the band never came up, which meant a pinned head that
//! worked only inside the few dozen pixels of chrome overhead and vanished for the whole rest of
//! the scroll. A band that appears and then drops out mid-gesture is worse than no band.
//!
//! The prompt is not gone, only out of the frame: it is still in the engine's scrollback, and
//! [`slopdesk_vterm::VtSession::prompt_span_above_viewport`] walks to it. The caller reads those
//! rows as TEXT and hands them over as [`Recovered`], which this module prints. Plain text is a
//! real loss of fidelity against the redraw above — no colours, no attributes — and it is the price
//! of naming the command at all; recovering cells would mean a second frame-scan path over the
//! scrollback for a one-line band.
//!
//! Both kinds are the same height by construction: [`Recovered::header_height`] is the header this
//! block will wear the moment its prompt scrolls into view, and the row count is the same
//! `prompt_rows` the frame would have segmented. So the band does not resize as the two paths hand
//! over to each other.
//!
//! ## Why the head never slides
//!
//! The obvious polish is the shove: as the next block's head arrives at the top, push the pinned
//! one up and out. This renderer cannot draw it. There is no scissor rect anywhere in
//! `slopdesk-apple-metal` — see its `renderer::encode`, six fixed passes and no clip — so a band
//! moved above the content box would spill its glyphs into the drawable's top inset, and a glyph
//! cannot be clipped after the fact the way [`crate::image`] clips a placement on the CPU.
//!
//! It costs nothing, because the swap has somewhere better to happen. The head is dropped as soon
//! as the NEXT block's own header reaches the band, and what the reader sees in its place is that
//! real header scrolling in — the thing the band was standing in for, arriving. Nothing pops,
//! nothing overlaps, and no frame draws two heads.

use slopdesk_terminal::geometry::{CellMetrics, Rect};
use slopdesk_vterm::Frame;

use crate::block::{BlockLayout, PlacedBlock};
use crate::chrome::{BlockStatus, ChromeFrame, ChromeStyle, label, solid, status_columns};
use crate::glyph::{GlyphCache, GlyphRasterizer, TextShaper};
use crate::layout::CellGeometry;
use crate::paint::{PaintStyle, Painter};
use crate::quad::DrawList;

/// The prompt line of an ORPHAN block, recovered from the scrollback above the frame.
///
/// What the caller could not read off the frame, because the frame is one screenful and this
/// block's prompt is older than it. Absent when the caller has nothing to recover — a session's
/// opening banner, a pane joined mid-stream, a shell with no OSC 133 integration — and the band
/// then stays down, which is the same answer the first version of this module always gave.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Recovered<'a> {
    /// Those prompt rows as the shell rendered them, oldest first, one per line.
    ///
    /// Newline-separated rather than a slice so the caller can hand over the string it already
    /// builds for the block join, and so an empty one is trivially "nothing recovered".
    pub text: &'a str,
    /// The header band this block will wear once its prompt scrolls back into the frame.
    ///
    /// Passed in rather than measured here because an orphan has no header of its own to measure —
    /// that is what makes it an orphan — and guessing from a sibling would give a lone orphan a
    /// different band from a neighboured one.
    pub header_height: f64,
}

impl Recovered<'_> {
    /// How many rows the recovered prompt covers, saturating.
    fn rows(&self) -> u16 {
        u16::try_from(self.text.lines().count()).unwrap_or(u16::MAX)
    }
}

/// Where the band's command text comes from.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Ink<'a> {
    /// The block's own prompt rows, still in the frame, redrawn at the band.
    Rows,
    /// The prompt recovered from above the frame, printed as text.
    Recovered(&'a str),
}

/// The block whose head is on the band this frame, already in the drawable's space.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Head<'a> {
    /// Its place in [`BlockLayout::blocks`], which is what indexes the caller's statuses.
    index: usize,
    /// The block itself, translated — see [`PlacedBlock::translated`].
    block: PlacedBlock,
    /// How tall the band is.
    height: f64,
    /// The header strip inside it — the block's own, or the one an orphan is owed.
    header_height: f64,
    /// What to draw in it.
    ink: Ink<'a>,
}

/// Which block's head belongs on the band, if any.
///
/// Three questions, and all three have to answer yes. Its own head is off the top, so there is
/// something to stand in for. Some of the block is still on screen, so there is something to label.
/// And the next block's header has not yet reached the band, so the band is not about to cover the
/// very thing it exists to announce.
///
/// ⚠️ "Off the top" means two different things, which is why an orphan does not take the early
/// break. An ordinary block qualifies by having been SCROLLED above the content box. An orphan's
/// prompt was never in the frame to be scrolled, so it qualifies wherever the list happens to have
/// put it — including at the very top, at rest, which is where a long command's output always
/// leaves it.
///
/// At most one block can satisfy the first two — they stack, in order — so the loop returns on its
/// first match rather than scanning for a best one.
fn head<'a>(
    layout: &BlockLayout,
    text: &PaintStyle,
    viewport: Rect,
    recovered: Option<Recovered<'a>>,
) -> Option<Head<'a>> {
    let cell_height = text.geometry.metrics.cell_height;
    let (dx, dy) = (text.geometry.metrics.origin_x, text.content_origin_y);
    for (index, block) in layout.blocks.iter().enumerate() {
        let block = block.translated(dx, dy);
        let orphan = block.span.is_orphan();
        // Blocks are stacked in order, so the first one whose head is still on screen ends the
        // search — nothing below it can have scrolled off the top.
        if block.frame.y >= viewport.y && !orphan {
            break;
        }
        if block.frame.y + block.frame.height <= viewport.y {
            continue;
        }
        let (height, header_height, ink) = if orphan {
            // An orphan with nothing recovered has no command anywhere — not in the frame, not in
            // the scrollback — so there is no head to pin and no later block can straddle the top
            // either.
            let recovered = recovered?;
            let rows = recovered.rows();
            (
                recovered.header_height + cell_height * f64::from(rows),
                recovered.header_height,
                Ink::Recovered(recovered.text),
            )
        } else {
            (
                block.head_height(cell_height),
                block.header.map_or(0.0, |header| header.height),
                Ink::Rows,
            )
        };
        // Capped at the viewport: a shell with a five-line prompt is a choice its user made, but a
        // band taller than the screen is not a band.
        let height = f64::min(height, viewport.height);
        if height <= 0.0 {
            return None;
        }
        let arriving = layout
            .blocks
            .get(index + 1)
            .is_some_and(|next| next.translated(dx, dy).frame.y <= viewport.y + height);
        if arriving {
            return None;
        }
        // Nothing of the block would be left under its own band. A head labels the output you are
        // looking at, so a band that covers every visible row of it has replaced the thing it was
        // announcing — which is what a short orphan does, since an orphan qualifies for the band at
        // rest and may be only a row or two tall just after a scroll.
        if block.frame.y + block.frame.height <= viewport.y + height {
            return None;
        }
        return Some(Head {
            index,
            block,
            height,
            header_height,
            ink,
        });
    }
    None
}

/// Draws the pinned head, if this frame has one.
///
/// Runs after [`crate::chrome::paint`] and lifts everything it emits into the list's pinned
/// buffers, so it draws over every unpinned instance whatever order the passes ran in.
#[expect(
    clippy::too_many_arguments,
    reason = "the frame, its layout, the design, this frame's state, the records, the font stack and the \
              sink — each used once, exactly as `chrome::paint` takes them"
)]
pub fn paint(
    frame: &Frame,
    layout: &BlockLayout,
    style: &ChromeStyle,
    view: &ChromeFrame,
    statuses: &[Option<BlockStatus>],
    recovered: Option<Recovered<'_>>,
    text: &PaintStyle,
    painter: &mut Painter,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    let Some(head) = head(layout, text, view.viewport, recovered) else {
        return;
    };
    let band = Rect {
        x: view.viewport.x,
        y: view.viewport.y,
        width: view.viewport.width,
        height: head.height,
    };
    let mark = out.mark();

    // The bed is the colour the render pass CLEARS to, so the band is the terminal's own ground
    // rather than a surface laid over it — and it is opaque for the reason `paint`'s preedit bed
    // is: the rows sliding under the band must not read through it.
    out.push_background(solid(band, frame.colors.background.into()));

    // The gutter shifts column zero, the same way the main pass shifts it per block — so the
    // pinned command sits on the column it sits on when it is scrolled into view, and the band is
    // the line staying still rather than the line moving sideways.
    //
    // ⚠️ `body.x` ALONE, where `crate::paint` adds the pass's own `origin_x` to it. This block has
    // already been through `translated`, which is where its `origin_x` went; adding it again put
    // the pinned line one left inset to the right of the line it stands in for.
    let geometry = CellGeometry {
        metrics: CellMetrics {
            origin_x: head.block.body.x,
            ..text.geometry.metrics
        },
        ..text.geometry
    };
    let cell_height = geometry.metrics.cell_height;
    let top_of = |offset: u16| band.y + head.header_height + cell_height * f64::from(offset);
    match head.ink {
        Ink::Rows => {
            for offset in 0..head.block.span.prompt_rows {
                let row_index = head.block.span.rows.start.saturating_add(offset);
                // ⚠️ Straight to `frame.row`, past `block.visible`. That is not a hole in the
                // virtualisation: `visible` is the rows the LAYOUT places, and the whole premise of
                // a pinned head is a row the layout placed off screen. The frame holds every row it
                // segmented, so the lookup is bounded by the same list `block::segment` walked.
                let Some(row) = frame.row(row_index) else {
                    continue;
                };
                let top = top_of(offset);
                if top + cell_height > band.y + band.height {
                    break;
                }
                painter.paint_row(
                    row, row_index, top, &geometry, frame, text, cache, shaper, rasterizer, out,
                );
            }
        },
        // The terminal's own foreground rather than the chrome's label ink: this is standing in for
        // a line of output, not annotating one. It is the closest a plain-text band can get to the
        // row it replaces, and it is what makes the handover to `Ink::Rows` read as the same line.
        Ink::Recovered(recovered) => {
            for (offset, line) in recovered.lines().enumerate() {
                let offset = u16::try_from(offset).unwrap_or(u16::MAX);
                let top = top_of(offset);
                if top + cell_height > band.y + band.height {
                    break;
                }
                label(
                    line,
                    geometry.metrics.origin_x,
                    top + geometry.font.baseline,
                    frame.colors.foreground.into(),
                    text.size_px,
                    cache,
                    shaper,
                    rasterizer,
                    out,
                );
            }
        },
    }

    // The ACTIVE block never wears an outcome, for the reason `chrome::paint` states where it makes
    // the same skip: its command has not finished, so it has none — and the join upstream can still
    // hand one over, by mapping a retyped command onto the previous run. Skipping in one pass and
    // not the other would put a stale `✗ 1` on the band and nothing on the header it stands in for.
    if view.active != Some(head.index) {
        paint_status(&head, statuses, style, text, band, cache, shaper, rasterizer, out);
    }

    // The hairline is what makes the band read as pinned rather than as a row that stopped moving.
    // Its own ink, and the divider's: this is the same seam between two blocks the list already
    // draws, seen from the other side.
    out.push_overlay(solid(
        Rect {
            y: band.y + band.height - f64::max(style.divider_thickness, 1.0),
            height: f64::max(style.divider_thickness, 1.0),
            ..band
        },
        style.divider,
    ));

    out.lift_pinned(mark);
}

/// The pinned block's exit code and duration, against the band's trailing edge.
///
/// The same right-aligned column [`crate::chrome`] prints a header's status in, so a status does
/// not jump sideways when its block reaches the top. The caller has already refused the ACTIVE
/// block; a running one has nothing to print either way, since its label is empty.
#[expect(
    clippy::too_many_arguments,
    reason = "the same stack the band itself takes, minus the frame it does not read"
)]
fn paint_status(
    head: &Head<'_>,
    statuses: &[Option<BlockStatus>],
    style: &ChromeStyle,
    text: &PaintStyle,
    band: Rect,
    cache: &mut GlyphCache,
    shaper: &mut impl TextShaper,
    rasterizer: &mut impl GlyphRasterizer,
    out: &mut DrawList,
) {
    let Some(Some(status)) = statuses.get(head.index) else {
        return;
    };
    // An orphan has no header of its own — that is what makes it an orphan — so the column is the
    // one its header WILL occupy: same x and width as the block, the height the band reserved. The
    // status must not move sideways when the prompt scrolls back into the frame and the real
    // header takes over.
    let header = head.block.header.unwrap_or(Rect {
        height: head.header_height,
        ..head.block.frame
    });
    if header.height <= 0.0 {
        return;
    }
    let geometry = text.geometry;
    // The band's own y, and the header's height: the head is drawn where the viewport starts, not
    // where the block it stands for is.
    let baseline = band.y + (header.height - geometry.metrics.cell_height) / 2.0 + geometry.font.baseline;
    status_columns(
        *status, header, baseline, style, text, cache, shaper, rasterizer, out,
    );
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::{CellMetrics, Rect};
    use slopdesk_vterm::{Frame, FrameCell, FrameRow, Rgb, RowSemantic, TextSpan};

    use super::{Recovered, paint};
    use crate::atlas::AtlasFormat;
    use crate::block::{BlockLayout, Chrome, LayoutMode, Viewport, lay_out, segment};
    use crate::chrome::{BlockStatus, ChromeFrame, ChromeStyle};
    use crate::glyph::{
        GlyphCache, GlyphKey, GlyphRasterizer, RasterGlyph, ShapedGlyph, TextRun, TextShaper,
    };
    use crate::layout::{CellGeometry, FontMetrics};
    use crate::paint::{PaintStyle, Painter, SelectionColors};
    use crate::quad::{DrawList, Rgba};

    /// One glyph per char, a cell apart — the fake every pass in this crate tests against.
    #[derive(Debug, Default)]
    struct OneToOne {
        runs: Vec<String>,
    }

    impl TextShaper for OneToOne {
        fn shape(&mut self, run: &TextRun<'_>, out: &mut Vec<ShapedGlyph>) {
            self.runs.push(run.text.to_owned());
            for (index, ch) in run.text.chars().enumerate() {
                let offset = u16::try_from(index).unwrap_or(u16::MAX);
                out.push(ShapedGlyph {
                    key: GlyphKey {
                        font: 0,
                        glyph: ch as u32,
                        size_px: run.size_px,
                        subpixel: run.subpixel,
                        synthetic: crate::glyph::Synthetic {
                            bold: run.bold,
                            italic: run.italic,
                        },
                    },
                    x: f32::from(offset) * 10.0,
                    y: 0.0,
                    cell: offset,
                });
            }
        }
    }

    /// Every glyph an 8×8 square.
    #[derive(Debug)]
    struct Square;

    impl GlyphRasterizer for Square {
        fn rasterize(&mut self, _key: GlyphKey) -> Option<RasterGlyph> {
            Some(RasterGlyph {
                width: 8,
                height: 8,
                bearing_x: 0.0,
                bearing_y: 8.0,
                format: AtlasFormat::Alpha8,
                pixels: vec![0xFF; 64],
            })
        }
    }

    const INSET: f64 = 8.0;
    const CELL_HEIGHT: f64 = 20.0;
    const VIEWPORT_HEIGHT: f64 = 200.0;
    const CHROME: Chrome = Chrome {
        header: 20.0,
        gap: 10.0,
        gutter: 14.0,
    };

    fn row(text: &str, semantic: RowSemantic) -> FrameRow {
        let mut row = FrameRow {
            semantic,
            ..FrameRow::default()
        };
        for ch in text.chars() {
            let start = row.text.len();
            let mut buffer = [0_u8; 4];
            row.text.push_str(ch.encode_utf8(&mut buffer));
            row.cells.push(FrameCell {
                fg: Rgb::new(200, 200, 200),
                bg: Rgb::BLACK,
                underline_color: Rgb::new(200, 200, 200),
                text: TextSpan {
                    offset: u32::try_from(start).unwrap_or_default(),
                    len: u32::try_from(row.text.len() - start).unwrap_or_default(),
                },
                ..FrameCell::default()
            });
        }
        row
    }

    /// Two commands, each one prompt row over twelve of output, and an optional orphan on top.
    fn frame_of(orphan_rows: u16) -> Frame {
        let mut rows: Vec<FrameRow> = (0..orphan_rows)
            .map(|_| row("orphan", RowSemantic::Output))
            .collect();
        for command in ["make build", "ls -la"] {
            rows.push(row(command, RowSemantic::Prompt));
            for _ in 0..12 {
                rows.push(row("output", RowSemantic::Output));
            }
        }
        Frame {
            cols: 10,
            rows,
            ..Frame::new()
        }
    }

    fn style(scroll_y: f64) -> PaintStyle {
        PaintStyle {
            geometry: CellGeometry {
                metrics: CellMetrics {
                    cell_width: 10.0,
                    cell_height: CELL_HEIGHT,
                    origin_x: INSET,
                    origin_y: INSET,
                },
                font: FontMetrics {
                    baseline: 15.0,
                    underline_position: 17.0,
                    underline_thickness: 1.0,
                    strikethrough_position: 10.0,
                    strikethrough_thickness: 1.0,
                    cursor_thickness: 2.0,
                },
            },
            size_px: 24,
            content_origin_y: INSET - scroll_y,
            selection: SelectionColors {
                background: Rgba::opaque(40, 60, 90),
                foreground: None,
            },
            focused: true,
            blink_visible: true,
            cursor_opacity: 1.0,
            cursor_text: None,
        }
    }

    fn chrome_style() -> ChromeStyle {
        ChromeStyle {
            divider: Rgba::opaque(1, 1, 1),
            divider_thickness: 1.0,
            gutter: Rgba::opaque(2, 2, 2),
            gutter_active: Rgba::opaque(3, 3, 3),
            gutter_thickness: 2.0,
            hover: Rgba::opaque(4, 4, 4),
            label: Rgba::opaque(5, 5, 5),
            status_err: Rgba::opaque(7, 7, 7),
            scrollbar: Rgba::opaque(6, 6, 6),
            scrollbar_thickness: 4.0,
            scrollbar_min_height: 24.0,
            scrollbar_inset: 4.0,
        }
    }

    fn view(active: Option<usize>) -> ChromeFrame {
        ChromeFrame {
            hovered: None,
            active,
            viewport: Rect {
                x: INSET,
                y: INSET,
                width: 400.0,
                height: VIEWPORT_HEIGHT,
            },
            thumb: None,
        }
    }

    fn layout_of(frame: &Frame, scroll_y: f64) -> BlockLayout {
        lay_out(
            &segment(frame, LayoutMode::Blocks),
            &[],
            CHROME,
            CELL_HEIGHT,
            Viewport {
                scroll_y,
                height: VIEWPORT_HEIGHT,
                width: 400.0,
            },
        )
    }

    /// The main pass, then the band — so a test sees the band's instances beside the frame's own.
    fn draw(
        orphan_rows: u16,
        scroll_y: f64,
        statuses: &[Option<BlockStatus>],
        recovered: Option<Recovered<'_>>,
        active: Option<usize>,
    ) -> (DrawList, Vec<String>) {
        let frame = frame_of(orphan_rows);
        let layout = layout_of(&frame, scroll_y);
        let text = style(scroll_y);
        let mut out = DrawList::new();
        let mut cache = GlyphCache::new();
        let mut shaper = OneToOne::default();
        let mut painter = Painter::new();
        painter.paint(
            &frame,
            &layout,
            &text,
            None,
            &mut cache,
            &mut shaper,
            &mut Square,
            &mut out,
        );
        let unpinned = (out.backgrounds.len(), out.glyphs.len(), out.overlays.len());
        let runs_before = shaper.runs.len();
        paint(
            &frame,
            &layout,
            &chrome_style(),
            &view(active),
            statuses,
            recovered,
            &text,
            &mut painter,
            &mut cache,
            &mut shaper,
            &mut Square,
            &mut out,
        );
        assert_eq!(
            (out.backgrounds.len(), out.glyphs.len(), out.overlays.len()),
            unpinned,
            "the band left nothing behind in the ordinary buffers"
        );
        (out, shaper.runs.split_off(runs_before))
    }

    /// The x of the band's leftmost glyph — column zero, whichever ink drew it.
    ///
    /// ⚠️ Worth a helper because the double-count SHIPPED once. `crate::paint` composes its own
    /// `origin_x + block.body.x` from a block it has NOT translated; the band's block has already
    /// been through `PlacedBlock::translated`, which is where its `origin_x` went, so adding
    /// the inset a second time put the pinned line one left inset right of the line it stands
    /// in for. No test asserted an x, which is exactly how it got past the suite and into the
    /// pixels.
    fn column_zero(drawn: &DrawList) -> f64 {
        drawn
            .pinned_glyphs
            .iter()
            .map(|glyph| f64::from(glyph.x))
            .fold(f64::INFINITY, f64::min)
    }

    /// The prompt this crate could not have read off the frame, as its caller recovers it.
    fn recovered(text: &str) -> Recovered<'_> {
        Recovered {
            text,
            header_height: CHROME.header,
        }
    }

    /// The case the module exists for: the command has scrolled off, its output has not.
    #[test]
    fn the_head_of_the_block_you_are_reading_stays_on_screen() {
        let (drawn, runs) = draw(0, 100.0, &[], None, None);
        assert!(!drawn.pinned_backgrounds.is_empty(), "the band has a bed");
        assert!(!drawn.pinned_glyphs.is_empty(), "and the command on it");
        assert!(
            runs.iter().any(|run| run.contains("make")),
            "the head is the command that produced what is on screen: {runs:?}"
        );

        // The bed is the first thing lifted, so the row's own cells draw over it.
        let bed = drawn.pinned_backgrounds[0];
        assert!(
            (f64::from(bed.y) - INSET).abs() < 1e-4,
            "pinned to the content box's top"
        );
        // The header band plus one prompt row.
        assert!((f64::from(bed.height) - (CHROME.header + CELL_HEIGHT)).abs() < 1e-4);
        // And on the column the main pass gives that same cell, not one inset right of it.
        assert!(
            (column_zero(&drawn) - (INSET + CHROME.gutter)).abs() < 1e-4,
            "the band's column zero moved sideways: {}",
            column_zero(&drawn)
        );

        // Nothing the band draws may leave it — there is no scissor rect to catch it.
        let bottom = INSET + CHROME.header + CELL_HEIGHT;
        assert!(
            drawn
                .pinned_glyphs
                .iter()
                .all(|glyph| f64::from(glyph.y) >= INSET && f64::from(glyph.y) <= bottom),
            "a pinned glyph escaped the band"
        );
    }

    /// A command still on screen is never pinned — there would be two of it.
    #[test]
    fn a_command_already_on_screen_is_left_alone() {
        let (drawn, runs) = draw(0, 0.0, &[], None, None);
        assert!(drawn.pinned_backgrounds.is_empty());
        assert!(drawn.pinned_glyphs.is_empty());
        assert!(drawn.pinned_overlays.is_empty());
        assert!(runs.is_empty(), "{runs:?}");
    }

    /// ⚠️ The handoff, and the reason the band never slides.
    ///
    /// Scrolled far enough that the NEXT command's own header has reached the band, the band goes
    /// away rather than being pushed out of a viewport it cannot be clipped against. What the
    /// reader sees in its place is that real header arriving.
    #[test]
    fn the_band_gives_way_to_the_header_arriving_under_it() {
        // The first block is 13 rows under a 20pt header, so the second one's header reaches the
        // band — 40 tall — once the scroll passes 250.
        let (drawn, runs) = draw(0, 260.0, &[], None, None);
        assert!(drawn.pinned_backgrounds.is_empty());
        assert!(drawn.pinned_glyphs.is_empty());
        assert!(runs.is_empty(), "{runs:?}");
    }

    /// An orphan with nothing recovered has no command ANYWHERE, so there is nothing to pin.
    ///
    /// The rows before the session's first prompt — a shell's login banner, a `tmux` reattach, a
    /// shell with no OSC 133 integration at all — have no prompt in the frame and none above it
    /// either, and a band over them would be an empty bed.
    #[test]
    fn an_orphan_with_nothing_recovered_has_no_head_to_pin() {
        let (drawn, _) = draw(12, 100.0, &[], None, None);
        assert!(
            drawn.pinned_backgrounds.is_empty(),
            "a block with no command drew a band anyway"
        );
    }

    /// ⚠️ THE FLAGSHIP CASE. Output taller than the grid, so the command is not in the frame at
    /// all — and the band names it anyway, from the prompt the caller recovered above the viewport.
    ///
    /// At rest, scroll zero: an orphan's prompt was never in the list to be scrolled off, so unlike
    /// every other block it qualifies for the band where the layout puts it.
    #[test]
    fn a_command_that_left_the_frame_is_named_from_the_scrollback() {
        let (drawn, runs) = draw(12, 0.0, &[], Some(recovered("$ seq 1 400")), None);
        assert!(!drawn.pinned_backgrounds.is_empty(), "the band has a bed");
        assert!(
            runs.iter().any(|run| run.contains("seq 1 400")),
            "the recovered command was not printed: {runs:?}"
        );

        // The same height its own header will be when the prompt scrolls back into the frame, so
        // the two paths hand over without the band resizing.
        let bed = drawn.pinned_backgrounds[0];
        assert!((f64::from(bed.height) - (CHROME.header + CELL_HEIGHT)).abs() < 1e-4);
        // Same column as the redrawn kind, so the handover between the two inks does not shift the
        // line sideways either.
        assert!(
            (column_zero(&drawn) - (INSET + CHROME.gutter)).abs() < 1e-4,
            "the recovered band's column zero moved sideways: {}",
            column_zero(&drawn)
        );
        let bottom = INSET + CHROME.header + CELL_HEIGHT;
        assert!(
            drawn
                .pinned_glyphs
                .iter()
                .all(|glyph| f64::from(glyph.y) >= INSET && f64::from(glyph.y) <= bottom),
            "a pinned glyph escaped the band"
        );
    }

    /// A wrapped prompt is recovered whole, and the band grows to hold it.
    #[test]
    fn a_recovered_prompt_of_two_rows_gets_a_band_of_two_rows() {
        let (drawn, runs) = draw(12, 0.0, &[], Some(recovered("~/src on main\n$ seq 1 400")), None);
        let bed = drawn.pinned_backgrounds[0];
        assert!((f64::from(bed.height) - (CHROME.header + CELL_HEIGHT * 2.0)).abs() < 1e-4);
        assert!(runs.iter().any(|run| run.contains("~/src on main")), "{runs:?}");
        assert!(runs.iter().any(|run| run.contains("seq 1 400")), "{runs:?}");
    }

    /// ⚠️ Deep in an output the caller cannot prove WHICH run this is, so it hands over no status
    /// and the band prints the command alone.
    ///
    /// Pinned here rather than in the caller because it is this module that would draw the wrong
    /// answer: a confidently-placed stale `✗ 1` over someone's output is worse than no outcome at
    /// all, and the shape that produces it — a repeated command, a newer record — is the ordinary
    /// case, not an exotic one.
    #[test]
    fn a_recovered_head_with_no_confirmed_record_prints_no_outcome() {
        let (_, runs) = draw(12, 0.0, &[None], Some(recovered("$ seq 1 400")), None);
        assert!(
            runs.iter().all(|run| !run.contains('✗') && !run.contains('✓')),
            "an unjoined orphan printed an outcome: {runs:?}"
        );
    }

    /// The head carries the same status its header carries, in the same column.
    #[test]
    fn the_head_prints_the_outcome_its_header_would() {
        let statuses = [Some(BlockStatus {
            exit_code: Some(1),
            duration_ms: Some(2400),
        })];
        let (_, runs) = draw(0, 100.0, &statuses, None, None);
        // Two runs, because the header's two halves take two inks and the band shares that painter
        // rather than owning a second right-alignment of its own.
        assert!(runs.iter().any(|run| run == "✗ 1"), "{runs:?}");
        assert!(runs.iter().any(|run| run == "2.4s"), "{runs:?}");
    }

    /// A recovered head that DID join prints its outcome in the same column a header would — the
    /// case where the frame still holds a later prompt to anchor the count on.
    #[test]
    fn a_recovered_head_that_joined_prints_its_outcome() {
        let statuses = [Some(BlockStatus {
            exit_code: Some(0),
            duration_ms: Some(1500),
        })];
        let (_, runs) = draw(12, 0.0, &statuses, Some(recovered("$ seq 1 400")), None);
        assert!(runs.iter().any(|run| run == "1.5s"), "{runs:?}");
    }

    /// ⚠️ The ACTIVE block wears no outcome on the band either, matching `chrome::paint`.
    ///
    /// Its command has not finished, so it HAS none — and the join upstream can still hand one over
    /// by mapping a retyped command onto the previous run. Skipping in one pass and not the other
    /// would put a stale `✗ 1` on the band and nothing on the header it stands in for.
    #[test]
    fn the_running_block_wears_no_outcome_on_the_band() {
        let statuses = [Some(BlockStatus {
            exit_code: Some(1),
            duration_ms: Some(2400),
        })];
        let (_, runs) = draw(0, 100.0, &statuses, None, Some(0));
        assert!(
            runs.iter().all(|run| !run.contains('✗')),
            "the active block printed an outcome: {runs:?}"
        );
    }

    /// A band that would cover every visible row of its own block has replaced the thing it was
    /// announcing, so it stays down.
    ///
    /// Two rows of orphan under a band that is a header plus a row: there is nothing left to label.
    /// The next block's header is still well below the band, so this is the rule doing it and not
    /// the handover.
    #[test]
    fn a_band_that_would_cover_its_whole_block_stays_down() {
        let (drawn, runs) = draw(2, 0.0, &[], Some(recovered("$ seq 1 400")), None);
        assert!(
            drawn.pinned_backgrounds.is_empty(),
            "the band covered its own block"
        );
        assert!(runs.is_empty(), "{runs:?}");
    }
}
