//! A frame becomes instances. This is the pass that runs sixty times a second.
//!
//! ## Three passes over a row, not one
//!
//! Backgrounds, decorations and text are built in separate walks, and they group by different keys.
//! A background run breaks where the background colour changes; an underline run breaks where the
//! underline changes; a text run breaks where the *font* changes. Merging them into one walk would
//! mean breaking every run wherever ANY of the three changes — turning one background rect under
//! `\e[4mhello\e[24m world` into six, because the underline ended in the middle of it.
//!
//! The decoration pass is also the one that must see cells the text pass skips. `ls -l` underlines
//! the spaces between columns, and a wide character's trailing half continues the underline of its
//! head. Both are cells with nothing to draw and something to decorate.
//!
//! ## Runs are slices of the row's arena, not copies
//!
//! [`slopdesk_vterm::FrameRow`] interns every cell's grapheme cluster back to back into one
//! `String` in column order. So the text of a run of adjacent cells is already a contiguous slice
//! of it, and shaping a run costs a `&str` rather than a `String` built per run per row per frame.
//! That is the reason the frame was given a per-row arena in the first place, and this is the call
//! site the decision was made for.
//!
//! ## What this pass does NOT draw
//!
//! Block headers, gutter marks, the scrollbar and the input box. Those are chrome — colours,
//! typography and affordances that belong to the client's design system, and `docs/68` does not put
//! a design language in the renderer. [`crate::block`] hands over their rects; the client fills
//! them, into the same [`DrawList`] if it wants.

use slopdesk_terminal::geometry::{CellMetrics, Rect};
use slopdesk_vterm::{CellFlags, ColumnSpan, Frame, FrameCell, FrameCursor, FrameRow, Rgb, UnderlineStyle};

use crate::atlas::AtlasFormat;
use crate::block::BlockLayout;
use crate::glyph::{GlyphCache, GlyphKey, GlyphRasterizer, ShapedGlyph, TextRun, TextShaper};
use crate::layout::CellGeometry;
use crate::quad::{DrawList, GlyphInstance, RectInstance, RectStyle, Rgba, px};

/// How a selection recolours the cells under it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionColors {
    /// The fill drawn under selected cells.
    pub background: Rgba,
    /// The colour selected text takes, or `None` to leave every cell its own foreground.
    ///
    /// `None` is the honest default for a translucent selection, where the text below still has to
    /// read as itself. A theme with an opaque selection sets this, or it selects invisible text.
    pub foreground: Option<Rgba>,
}

/// Everything the pass needs that is not the frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PaintStyle {
    /// Cell size, grid origin and font metrics.
    pub geometry: CellGeometry,
    /// The size glyphs are rasterised at, in device pixels.
    pub size_px: u16,
    /// Where content-space y zero lands in the drawable — the grid's top inset minus the scroll.
    pub content_origin_y: f64,
    /// How a selection recolours what it covers.
    pub selection: SelectionColors,
    /// Whether the surface has key focus. Drives the hollow cursor.
    pub focused: bool,
    /// The renderer's blink clock: `false` is the dark half of the cycle.
    ///
    /// One flag for both blinking TEXT and a blinking cursor, deliberately — two clocks would drift
    /// apart on screen, and a cursor blinking out of phase with the text under it looks broken in a
    /// way nobody can name.
    pub blink_visible: bool,
}

/// The reusable scratch a paint pass needs.
///
/// Held across frames so a repaint allocates nothing: the shaped-glyph buffer is the only
/// per-run allocation in the pass, and it is cleared rather than dropped.
#[derive(Debug, Default)]
pub struct Painter {
    shaped: Vec<ShapedGlyph>,
}

/// What a background run groups by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct BackgroundKey {
    color: Rgba,
}

/// What a decoration run groups by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DecorationKey {
    underline: UnderlineStyle,
    underline_color: Rgb,
    strikethrough: bool,
    overline: bool,
    color: Rgb,
}

impl DecorationKey {
    const fn draws_nothing(self) -> bool {
        matches!(self.underline, UnderlineStyle::None) && !self.strikethrough && !self.overline
    }
}

/// What a text run groups by — the font, and nothing else that does not change it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TextKey {
    color: Rgba,
    bold: bool,
    italic: bool,
}

impl Painter {
    /// A painter with empty scratch.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Fills `out` with everything `frame`'s visible rows draw.
    ///
    /// `layout` decides which rows are on screen and where each one sits, so this never re-derives
    /// a row's y — see [`CellGeometry::row_top`] for why that is a rule rather than a
    /// preference. `out` is cleared first: a caller that wants to add its own chrome appends
    /// after this returns.
    #[expect(
        clippy::too_many_arguments,
        reason = "the frame, its layout, the style, the atlas, the font stack and the sink — every one is a \
                  different owner, and a bundling struct would move the list rather than shorten it"
    )]
    pub fn paint(
        &mut self,
        frame: &Frame,
        layout: &BlockLayout,
        style: &PaintStyle,
        cache: &mut GlyphCache,
        shaper: &mut impl TextShaper,
        rasterizer: &mut impl GlyphRasterizer,
        out: &mut DrawList,
    ) {
        out.clear();
        let cell_height = style.geometry.metrics.cell_height;

        for block in layout.visible() {
            // The gutter shifts column zero. Applying it per block rather than per row is what lets
            // the alternate screen — gutter zero — share this code with no branch.
            let geometry = CellGeometry {
                metrics: CellMetrics {
                    origin_x: style.geometry.metrics.origin_x + block.body.x,
                    ..style.geometry.metrics
                },
                ..style.geometry
            };

            for row_index in block.visible.start..block.visible.end {
                let (Some(row), Some(content_y)) =
                    (frame.row(row_index), block.row_y(row_index, cell_height))
                else {
                    continue;
                };
                let top = style.content_origin_y + content_y;
                self.paint_row(
                    row, row_index, top, &geometry, frame, style, cache, shaper, rasterizer, out,
                );
            }
        }

        paint_cursor(frame, layout, style, out);
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "a paint pass needs the frame, the row, its place, the style and three sinks; bundling \
                  them into a struct would move the argument list rather than shorten it"
    )]
    fn paint_row(
        &mut self,
        row: &FrameRow,
        row_index: u16,
        top: f64,
        geometry: &CellGeometry,
        frame: &Frame,
        style: &PaintStyle,
        cache: &mut GlyphCache,
        shaper: &mut impl TextShaper,
        rasterizer: &mut impl GlyphRasterizer,
        out: &mut DrawList,
    ) {
        let selected = |col: u16| row.selection.is_some_and(|span| span.contains(col));
        let inverting_cursor_col = frame
            .cursor
            .filter(|cursor| cursor.y == row_index && style.focused && cursor_visible(*cursor, style))
            .and_then(|cursor| {
                let placed = geometry.cursor(top, cursor, style.focused);
                placed.inverts_glyph.then_some(cursor.x)
            });

        background_pass(row, top, geometry, frame, style, &selected, out);
        decoration_pass(row, top, geometry, style, &selected, out);
        self.text_pass(
            row,
            top,
            geometry,
            frame,
            style,
            &selected,
            inverting_cursor_col,
            cache,
            shaper,
            rasterizer,
            out,
        );
    }
}

/// Coalesces adjacent cells with the same background into one rect.
fn background_pass(
    row: &FrameRow,
    top: f64,
    geometry: &CellGeometry,
    frame: &Frame,
    style: &PaintStyle,
    selected: &impl Fn(u16) -> bool,
    out: &mut DrawList,
) {
    let default: Rgba = frame.colors.background.into();
    run_over_row(row, |col, cell| {
        let color = if selected(col) {
            style.selection.background
        } else {
            Rgba::from(cell.bg)
        };
        // The commonest cell in a terminal is a space on the default background. Emitting a rect
        // for each would double an ordinary frame's instance count to paint the colour the
        // render pass already cleared to.
        if color == default {
            BackgroundKey { color: Rgba::CLEAR }
        } else {
            BackgroundKey { color }
        }
    })
    .for_each(|(key, cols)| {
        let bounds = geometry.span(top, cols);
        out.push_background(RectInstance {
            x: px(bounds.x),
            y: px(bounds.y),
            width: px(bounds.width),
            height: px(bounds.height),
            color: key.color,
            style: RectStyle::Solid,
        });
    });
}

/// Coalesces adjacent cells with the same decorations, blanks and wide tails included.
fn decoration_pass(
    row: &FrameRow,
    top: f64,
    geometry: &CellGeometry,
    style: &PaintStyle,
    selected: &impl Fn(u16) -> bool,
    out: &mut DrawList,
) {
    run_over_row(row, |col, cell| {
        let color = selected(col)
            .then_some(style.selection.foreground)
            .flatten()
            .map_or(cell.fg, |over| Rgb::new(over.r, over.g, over.b));
        DecorationKey {
            underline: cell.underline,
            underline_color: cell.underline_color,
            strikethrough: cell.flags.contains(CellFlags::STRIKETHROUGH),
            overline: cell.flags.contains(CellFlags::OVERLINE),
            color,
        }
    })
    .for_each(|(key, cols)| {
        if key.draws_nothing() {
            return;
        }
        let underline = geometry.underline(top, cols, key.underline);
        for line in [underline.first, underline.second].into_iter().flatten() {
            out.push_overlay(rect_instance(line, key.underline_color.into(), underline.style));
        }
        if key.strikethrough {
            out.push_overlay(rect_instance(
                geometry.strikethrough(top, cols),
                key.color.into(),
                RectStyle::Solid,
            ));
        }
        if key.overline {
            out.push_overlay(rect_instance(
                geometry.overline(top, cols),
                key.color.into(),
                RectStyle::Solid,
            ));
        }
    });
}

impl Painter {
    #[expect(
        clippy::too_many_arguments,
        reason = "the shaping path needs the font stack, the atlas and the sink on top of the row"
    )]
    fn text_pass(
        &mut self,
        row: &FrameRow,
        top: f64,
        geometry: &CellGeometry,
        frame: &Frame,
        style: &PaintStyle,
        selected: &impl Fn(u16) -> bool,
        inverting_cursor_col: Option<u16>,
        cache: &mut GlyphCache,
        shaper: &mut impl TextShaper,
        rasterizer: &mut impl GlyphRasterizer,
        out: &mut DrawList,
    ) {
        let baseline = geometry.baseline(top);
        let mut col = 0_u16;
        while (col as usize) < row.cells.len() {
            let Some(cell) = row.cells.get(col as usize).copied() else {
                break;
            };
            if !paints_text(row, cell, style) {
                col = col.saturating_add(1);
                continue;
            }

            let key = text_key(cell, col, frame, style, selected, inverting_cursor_col);
            let start = col;
            let mut end = col.saturating_add(1);
            // A run stops at the cursor cell so its glyph can be recoloured on its own, and at any
            // cell that changes the font or has nothing to shape.
            while let Some(next) = row.cells.get(end as usize).copied() {
                if inverting_cursor_col == Some(end)
                    || !paints_text(row, next, style)
                    || text_key(next, end, frame, style, selected, inverting_cursor_col) != key
                {
                    break;
                }
                end = end.saturating_add(1);
            }

            self.shape_and_emit(
                row,
                ColumnSpan { start, end },
                top,
                baseline,
                geometry,
                style,
                key,
                cache,
                shaper,
                rasterizer,
                out,
            );
            col = end;
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "one run, its place, its font, the atlas and the sink — every argument is used once"
    )]
    fn shape_and_emit(
        &mut self,
        row: &FrameRow,
        cols: ColumnSpan,
        top: f64,
        baseline: f64,
        geometry: &CellGeometry,
        style: &PaintStyle,
        key: TextKey,
        cache: &mut GlyphCache,
        shaper: &mut impl TextShaper,
        rasterizer: &mut impl GlyphRasterizer,
        out: &mut DrawList,
    ) {
        let Some(text) = run_text(row, cols) else {
            return;
        };
        let origin_x = geometry.span(top, cols).x;

        self.shaped.clear();
        shaper.shape(
            &TextRun {
                text,
                start_col: cols.start,
                cells: cols.width(),
                bold: key.bold,
                italic: key.italic,
                size_px: style.size_px,
                subpixel: GlyphKey::phase(origin_x),
            },
            &mut self.shaped,
        );

        for shaped in &self.shaped {
            let Some(glyph) = cache.get(shaped.key, rasterizer) else {
                continue;
            };
            if glyph.is_blank() {
                continue;
            }
            let atlas = match glyph.format {
                AtlasFormat::Alpha8 => cache.alpha_atlas(),
                AtlasFormat::Bgra8 => cache.color_atlas(),
            };
            let uv = atlas.uv(glyph.region);
            let color_atlas = u32::from(glyph.format == AtlasFormat::Bgra8);
            out.push_glyph(GlyphInstance {
                x: px(origin_x + f64::from(shaped.x) + f64::from(glyph.bearing_x)),
                y: px(baseline + f64::from(shaped.y) - f64::from(glyph.bearing_y)),
                width: px(f64::from(glyph.region.width)),
                height: px(f64::from(glyph.region.height)),
                uv,
                color: key.color,
                color_atlas,
            });
        }
    }
}

/// The cursor, placed against the block that holds its row.
///
/// Last, and outside the row walk, because a cursor is one instance per frame and putting it in the
/// walk would cost a test per row to answer "is the cursor here". A filled block goes into the
/// BACKGROUND buffer so the glyph the text pass recoloured draws over it; everything else is an
/// overlay.
fn paint_cursor(frame: &Frame, layout: &BlockLayout, style: &PaintStyle, out: &mut DrawList) {
    let Some(cursor) = frame.cursor else {
        return;
    };
    if !cursor_visible(cursor, style) {
        return;
    }
    let Some(block) = layout
        .block_at_row(cursor.y)
        .filter(|block| block.visible.contains(cursor.y))
    else {
        return;
    };
    let cell_height = style.geometry.metrics.cell_height;
    let Some(content_y) = block.row_y(cursor.y, cell_height) else {
        return;
    };

    let geometry = CellGeometry {
        metrics: CellMetrics {
            origin_x: style.geometry.metrics.origin_x + block.body.x,
            ..style.geometry.metrics
        },
        ..style.geometry
    };
    let placed = geometry.cursor(style.content_origin_y + content_y, cursor, style.focused);
    let instance = rect_instance(placed.rect, cursor.color.into(), placed.style);
    if placed.inverts_glyph {
        out.push_background(instance);
    } else {
        out.push_overlay(instance);
    }
}

/// Whether the cursor draws this frame.
///
/// A password field suppresses the blink rather than the cursor: hiding it would leave no caret at
/// all, and a caret that blinks is a keystroke counter for anyone watching the screen.
const fn cursor_visible(cursor: FrameCursor, style: &PaintStyle) -> bool {
    !cursor.blinking || cursor.password_input || style.blink_visible
}

/// Whether a cell contributes a glyph.
fn paints_text(row: &FrameRow, cell: FrameCell, style: &PaintStyle) -> bool {
    if cell.flags.hides_glyph() {
        return false;
    }
    if cell.flags.contains(CellFlags::BLINK) && !style.blink_visible {
        return false;
    }
    !row.cell_text(cell).is_empty()
}

/// The font a cell wants, with the selection and the cursor folded in.
fn text_key(
    cell: FrameCell,
    col: u16,
    frame: &Frame,
    style: &PaintStyle,
    selected: &impl Fn(u16) -> bool,
    inverting_cursor_col: Option<u16>,
) -> TextKey {
    // Under a filled block cursor the glyph takes the cell's BACKGROUND, which is what makes the
    // character under the caret readable against the caret.
    let color = if inverting_cursor_col == Some(col) {
        Rgba::from(if cell.bg == frame.colors.background {
            frame.colors.background
        } else {
            cell.bg
        })
    } else if selected(col) {
        style.selection.foreground.unwrap_or_else(|| cell.fg.into())
    } else {
        cell.fg.into()
    };
    TextKey {
        color,
        bold: cell.flags.contains(CellFlags::BOLD),
        italic: cell.flags.contains(CellFlags::ITALIC),
    }
}

/// The contiguous slice of the row's arena that `cols` covers.
///
/// `None` when the run has no text — the arena is in column order, so the slice runs from the first
/// cell's offset to the last one's end and needs no copy. A cell with an empty span in the middle
/// of a run is not a hole: it contributes zero bytes and the slice stays contiguous.
fn run_text(row: &FrameRow, cols: ColumnSpan) -> Option<&str> {
    let first = row.cells.get(cols.start as usize)?;
    let last = row.cells.get(cols.end.checked_sub(1)? as usize)?;
    let start = first.text.offset as usize;
    let end = (last.text.offset as usize).saturating_add(last.text.len as usize);
    row.text.get(start..end).filter(|text| !text.is_empty())
}

/// A [`Rect`] as an instance.
const fn rect_instance(bounds: Rect, color: Rgba, style: RectStyle) -> RectInstance {
    RectInstance {
        x: px(bounds.x),
        y: px(bounds.y),
        width: px(bounds.width),
        height: px(bounds.height),
        color,
        style,
    }
}

/// Walks a row, coalescing adjacent cells whose `key` matches into one span.
///
/// The one loop shape all three passes share. Each pass supplies what it groups by, and none of
/// them re-implements the run-breaking — which is where an off-by-one would show as a missing
/// column at a colour change, the kind of bug that survives a screenshot.
fn run_over_row<K: PartialEq + Copy>(
    row: &FrameRow,
    key: impl Fn(u16, FrameCell) -> K,
) -> impl Iterator<Item = (K, ColumnSpan)> {
    let mut runs = Vec::new();
    let mut open: Option<(K, u16)> = None;
    for (index, cell) in row.cells.iter().enumerate() {
        let col = u16::try_from(index).unwrap_or(u16::MAX);
        let current = key(col, *cell);
        match open {
            Some((held, _)) if held == current => {},
            Some((held, start)) => {
                runs.push((held, ColumnSpan { start, end: col }));
                open = Some((current, col));
            },
            None => open = Some((current, col)),
        }
    }
    if let Some((held, start)) = open {
        let end = u16::try_from(row.cells.len()).unwrap_or(u16::MAX);
        runs.push((held, ColumnSpan { start, end }));
    }
    runs.into_iter()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::CellMetrics;
    use slopdesk_vterm::{
        CellFlags, ColumnSpan, CursorShape, Frame, FrameCell, FrameCursor, FrameRow, Rgb, RowSemantic,
        UnderlineStyle,
    };

    use super::{PaintStyle, Painter, SelectionColors};
    use crate::atlas::AtlasFormat;
    use crate::block::{Chrome, LayoutMode, Viewport, lay_out, segment};
    use crate::glyph::{GlyphKey, GlyphRasterizer, RasterGlyph, ShapedGlyph, TextRun, TextShaper};
    use crate::layout::{CellGeometry, FontMetrics};
    use crate::quad::{DrawList, RectStyle, Rgba};

    /// A shaper that emits one glyph per char, one cell wide, with no ligatures.
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

    /// A rasteriser that draws every glyph as an 8×8 square with no bearing.
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

    fn style() -> PaintStyle {
        PaintStyle {
            geometry: CellGeometry {
                metrics: CellMetrics {
                    cell_width: 10.0,
                    cell_height: 20.0,
                    origin_x: 0.0,
                    origin_y: 0.0,
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
            content_origin_y: 0.0,
            selection: SelectionColors {
                background: Rgba::opaque(40, 60, 90),
                foreground: None,
            },
            focused: true,
            blink_visible: true,
        }
    }

    /// Builds a one-row frame from `text`, applying `decorate` to every cell.
    fn frame_of(text: &str, decorate: impl Fn(&mut FrameCell)) -> Frame {
        let mut row = FrameRow {
            semantic: RowSemantic::Output,
            ..FrameRow::default()
        };
        for ch in text.chars() {
            let mut cell = FrameCell {
                fg: Rgb::new(200, 200, 200),
                bg: Rgb::BLACK,
                underline_color: Rgb::new(200, 200, 200),
                ..FrameCell::default()
            };
            decorate(&mut cell);
            let start = row.text.len();
            let mut buffer = [0_u8; 4];
            let encoded: &str = ch.encode_utf8(&mut buffer);
            row.text.push_str(if ch == ' ' { "" } else { encoded });
            cell.text = slopdesk_vterm::TextSpan {
                offset: u32::try_from(start).unwrap(),
                len: u32::try_from(row.text.len() - start).unwrap(),
            };
            row.cells.push(cell);
        }
        Frame {
            cols: u16::try_from(row.cells.len()).unwrap(),
            rows: vec![row],
            ..Frame::new()
        }
    }

    fn paint(frame: &Frame, style: &PaintStyle) -> (DrawList, OneToOne) {
        let spans = segment(frame, LayoutMode::Grid);
        let layout = lay_out(&spans, &[], Chrome::NONE, 20.0, Viewport {
            scroll_y: 0.0,
            height: 400.0,
            width: 400.0,
        });
        let mut out = DrawList::new();
        let mut shaper = OneToOne::default();
        let mut cache = crate::glyph::GlyphCache::new();
        Painter::new().paint(
            frame,
            &layout,
            style,
            &mut cache,
            &mut shaper,
            &mut Square,
            &mut out,
        );
        (out, shaper)
    }

    #[test]
    fn a_default_background_emits_no_rect_at_all() {
        let frame = frame_of("hello", |_| {});
        let (list, _) = paint(&frame, &style());
        assert!(
            list.backgrounds.is_empty(),
            "the render pass already cleared to this colour"
        );
        assert_eq!(list.glyphs.len(), 5);
    }

    #[test]
    fn adjacent_cells_of_one_colour_coalesce_into_one_rect() {
        let frame = frame_of("abcd", |cell| cell.bg = Rgb::new(10, 20, 30));
        let (list, _) = paint(&frame, &style());

        assert_eq!(list.backgrounds.len(), 1);
        assert!((f64::from(list.backgrounds[0].width) - 40.0).abs() < 1e-6);
    }

    #[test]
    fn a_colour_change_breaks_the_background_run_but_not_the_text_run() {
        let mut frame = frame_of("abcd", |cell| cell.bg = Rgb::new(10, 20, 30));
        frame.rows[0].cells[2].bg = Rgb::new(90, 90, 90);
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(list.backgrounds.len(), 3, "two colours, three runs: ab / c / d");
        assert_eq!(shaper.runs, vec!["abcd".to_owned()], "the font never changed");
    }

    #[test]
    fn a_bold_span_breaks_the_text_run() {
        let mut frame = frame_of("abcd", |_| {});
        frame.rows[0].cells[1].flags = CellFlags::BOLD;
        frame.rows[0].cells[2].flags = CellFlags::BOLD;
        let (_, shaper) = paint(&frame, &style());

        assert_eq!(shaper.runs, vec!["a".to_owned(), "bc".to_owned(), "d".to_owned()]);
    }

    #[test]
    fn an_underline_under_spaces_still_draws() {
        let frame = frame_of("a  b", |cell| cell.underline = UnderlineStyle::Single);
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(list.overlays.len(), 1, "one underline across all four cells");
        assert!((f64::from(list.overlays[0].width) - 40.0).abs() < 1e-6);
        assert_eq!(
            shaper.runs,
            vec!["a".to_owned(), "b".to_owned()],
            "spaces shape nothing"
        );
    }

    #[test]
    fn a_wide_tail_continues_its_heads_underline_and_shapes_nothing() {
        // Three cells: the wide head, the tail the engine parks under its right half, and an
        // ordinary one after it. The tail's own text is never drawn, so what it carries does not
        // matter — what matters is that it neither shapes nor breaks the underline.
        let mut frame = frame_of("漢-x", |cell| cell.underline = UnderlineStyle::Single);
        frame.rows[0].cells[0].flags = CellFlags::WIDE;
        frame.rows[0].cells[1].flags = CellFlags::WIDE_TAIL;
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(list.overlays.len(), 1, "the tail did not break the underline");
        assert!((f64::from(list.overlays[0].width) - 30.0).abs() < 1e-6);
        assert_eq!(
            shaper.runs,
            vec!["漢".to_owned(), "x".to_owned()],
            "the tail shaped nothing"
        );
    }

    #[test]
    fn a_curly_underline_asks_for_the_curly_pipeline() {
        let frame = frame_of("ab", |cell| cell.underline = UnderlineStyle::Curly);
        let (list, _) = paint(&frame, &style());
        assert_eq!(list.overlays[0].style, RectStyle::Curly);
    }

    #[test]
    fn a_double_underline_emits_both_lines() {
        let frame = frame_of("ab", |cell| cell.underline = UnderlineStyle::Double);
        let (list, _) = paint(&frame, &style());
        assert_eq!(list.overlays.len(), 2);
    }

    #[test]
    fn a_strikethrough_and_an_overline_are_separate_overlays() {
        let frame = frame_of("ab", |cell| {
            cell.flags = CellFlags::STRIKETHROUGH.union(CellFlags::OVERLINE);
        });
        let (list, _) = paint(&frame, &style());
        assert_eq!(list.overlays.len(), 2);
    }

    #[test]
    fn a_selection_repaints_the_background_and_leaves_the_text_alone_by_default() {
        let mut frame = frame_of("abcd", |_| {});
        frame.rows[0].selection = Some(ColumnSpan { start: 1, end: 3 });
        let (list, _) = paint(&frame, &style());

        assert_eq!(list.backgrounds.len(), 1);
        assert_eq!(list.backgrounds[0].color, Rgba::opaque(40, 60, 90));
        assert!((f64::from(list.backgrounds[0].x) - 10.0).abs() < 1e-6);
        assert!((f64::from(list.backgrounds[0].width) - 20.0).abs() < 1e-6);
    }

    #[test]
    fn an_opaque_selection_recolours_the_text_it_covers() {
        let mut frame = frame_of("abcd", |_| {});
        frame.rows[0].selection = Some(ColumnSpan { start: 1, end: 3 });
        let over = Rgba::opaque(255, 255, 255);
        let (_, shaper) = paint(&frame, &PaintStyle {
            selection: SelectionColors {
                background: Rgba::opaque(40, 60, 90),
                foreground: Some(over),
            },
            ..style()
        });

        assert_eq!(shaper.runs, vec!["a".to_owned(), "bc".to_owned(), "d".to_owned()]);
    }

    #[test]
    fn blinking_text_disappears_on_the_dark_half_of_the_cycle() {
        let frame = frame_of("ab", |cell| cell.flags = CellFlags::BLINK);
        let (lit, _) = paint(&frame, &style());
        let (dark, _) = paint(&frame, &PaintStyle {
            blink_visible: false,
            ..style()
        });

        assert_eq!(lit.glyphs.len(), 2);
        assert!(dark.glyphs.is_empty());
    }

    #[test]
    fn a_block_cursor_goes_under_the_glyph_and_recolours_it() {
        let mut frame = frame_of("abcd", |_| {});
        frame.cursor = Some(FrameCursor {
            x: 2,
            y: 0,
            shape: CursorShape::Block,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        });
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(
            list.backgrounds.len(),
            1,
            "the caret is a background, so the glyph draws over it"
        );
        assert_eq!(list.backgrounds[0].style, RectStyle::Solid);
        assert_eq!(shaper.runs, vec!["ab".to_owned(), "c".to_owned(), "d".to_owned()]);
    }

    #[test]
    fn a_bar_cursor_goes_over_the_glyph_and_leaves_the_run_alone() {
        let mut frame = frame_of("abcd", |_| {});
        frame.cursor = Some(FrameCursor {
            x: 2,
            y: 0,
            shape: CursorShape::Bar,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        });
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(list.overlays.len(), 1);
        assert_eq!(shaper.runs, vec!["abcd".to_owned()]);
    }

    #[test]
    fn an_unfocused_cursor_is_hollow_and_does_not_recolour_anything() {
        let mut frame = frame_of("abcd", |_| {});
        frame.cursor = Some(FrameCursor {
            x: 2,
            y: 0,
            shape: CursorShape::Block,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        });
        let (list, shaper) = paint(&frame, &PaintStyle {
            focused: false,
            ..style()
        });

        assert_eq!(list.overlays.len(), 1);
        assert_eq!(list.overlays[0].style, RectStyle::Hollow);
        assert_eq!(shaper.runs, vec!["abcd".to_owned()]);
    }

    #[test]
    fn a_password_cursor_ignores_the_blink_clock() {
        let mut frame = frame_of("ab", |_| {});
        frame.cursor = Some(FrameCursor {
            x: 0,
            y: 0,
            shape: CursorShape::Bar,
            color: Rgb::WHITE,
            blinking: true,
            at_wide_tail: false,
            password_input: true,
        });
        let (dark, _) = paint(&frame, &PaintStyle {
            blink_visible: false,
            ..style()
        });
        assert_eq!(dark.overlays.len(), 1, "hiding it would leave no caret at all");
    }

    #[test]
    fn a_blinking_cursor_disappears_on_the_dark_half() {
        let mut frame = frame_of("ab", |_| {});
        frame.cursor = Some(FrameCursor {
            x: 0,
            y: 0,
            shape: CursorShape::Bar,
            color: Rgb::WHITE,
            blinking: true,
            at_wide_tail: false,
            password_input: false,
        });
        let (dark, _) = paint(&frame, &PaintStyle {
            blink_visible: false,
            ..style()
        });
        assert!(dark.overlays.is_empty());
    }

    #[test]
    fn a_glyph_lands_on_the_baseline_at_its_cells_left_edge() {
        let frame = frame_of("a", |_| {});
        let (list, _) = paint(&frame, &style());

        // The fake rasteriser reports bearing_y 8 with an 8-texel bitmap, so the glyph's top edge
        // is the baseline minus its whole height.
        assert!((f64::from(list.glyphs[0].x)).abs() < 1e-6);
        assert!((f64::from(list.glyphs[0].y) - 7.0).abs() < 1e-6);
    }

    #[test]
    fn a_block_layout_offsets_rows_by_its_header_and_gutter() {
        let mut frame = frame_of("ab", |_| {});
        frame.rows[0].semantic = RowSemantic::Prompt;
        let spans = segment(&frame, LayoutMode::Blocks);
        let chrome = Chrome {
            header: 24.0,
            gap: 8.0,
            gutter: 12.0,
        };
        let layout = lay_out(&spans, &[], chrome, 20.0, Viewport {
            scroll_y: 0.0,
            height: 400.0,
            width: 400.0,
        });

        let mut out = DrawList::new();
        let mut shaper = OneToOne::default();
        let mut cache = crate::glyph::GlyphCache::new();
        Painter::new().paint(
            &frame,
            &layout,
            &style(),
            &mut cache,
            &mut shaper,
            &mut Square,
            &mut out,
        );

        assert!(
            (f64::from(out.glyphs[0].x) - 12.0).abs() < 1e-6,
            "the gutter shifts column zero"
        );
        assert!(
            (f64::from(out.glyphs[0].y) - (24.0 + 7.0)).abs() < 1e-6,
            "the header pushes the row down"
        );
    }

    #[test]
    fn a_scrolled_row_moves_by_the_content_origin() {
        let frame = frame_of("a", |_| {});
        let (list, _) = paint(&frame, &PaintStyle {
            content_origin_y: -50.0,
            ..style()
        });
        assert!((f64::from(list.glyphs[0].y) - (7.0 - 50.0)).abs() < 1e-6);
    }

    #[test]
    fn painting_twice_does_not_accumulate() {
        let frame = frame_of("abcd", |cell| cell.bg = Rgb::new(10, 20, 30));
        let (first, _) = paint(&frame, &style());
        let (second, _) = paint(&frame, &style());
        assert_eq!(first.len(), second.len());
    }
}
