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
//! The furniture around a block — gutter, divider, collapse mark, scrollbar. That is
//! [`crate::chrome`]'s pass, running after this one into the same [`DrawList`], and the split is
//! between the two KINDS of thing on the surface rather than between two owners: this pass draws
//! what the PROGRAM emitted, and that one draws what the client decided. Its header argues why the
//! decision still crosses from Swift while the drawing does not.

use slopdesk_terminal::geometry::{CellMetrics, Rect};
use slopdesk_vterm::{
    CellFlags, ColumnSpan, CursorShape, Frame, FrameCell, FrameCursor, FrameRow, Rgb, UnderlineStyle,
};

use crate::atlas::AtlasFormat;
use crate::block::BlockLayout;
use crate::glyph::{GlyphCache, GlyphKey, GlyphRasterizer, ShapedGlyph, TextRun, TextShaper};
use crate::layout::CellGeometry;
use crate::quad::{DrawList, GlyphInstance, RectInstance, RectStyle, Rgba, px};
use crate::sprite::{self, CellEdge, JoinMask, SpriteKey};

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
    /// How opaque the cursor is drawn, `0.0`–`1.0`.
    ///
    /// A RENDERER setting rather than an engine one, and it has to be: the terminal protocol has no
    /// way to say it. `OSC 12` sets a cursor COLOUR, and every escape that touches the caret picks
    /// a shape or a blink — none of them carries an alpha, so there is nothing for a program to
    /// override and no default for the engine to hold. The paint owns the cursor rect, so the paint
    /// is where the number belongs.
    ///
    /// Clamped where it is applied rather than on the way in, so a caller cannot construct a style
    /// that paints an out-of-range cursor.
    pub cursor_opacity: f64,
    /// The colour the glyph under a filled cursor takes, or `None` to keep the cell's background.
    ///
    /// A renderer setting for [`cursor_opacity`](Self::cursor_opacity)'s reason — no escape names
    /// this colour, so there is nothing for a program to override. `None` is the default and it is
    /// the one that is always readable: taking the cell's own background guarantees the glyph
    /// contrasts with the caret drawn in that cell's foreground. A theme that names a colour is
    /// asserting it knows better, which is a claim only a theme can make.
    pub cursor_text: Option<Rgba>,
    /// Whether an arrow that a box rule runs into is drawn with a stem continuing that rule.
    ///
    /// Only the arrows are conditional; the other four sprite families are unconditional and no
    /// setting reaches them, because a font's `█` is wrong in a way nobody wants back. An arrow is
    /// different: `→` in prose is a CHARACTER, and someone whose typeface draws a nicer one is
    /// entitled to it. The condition already keeps prose out — a standalone arrow has an empty mask
    /// and falls through — so this flag is for the reader who does not want the joined form even in
    /// a diagram.
    pub arrow_box_drawing_join: bool,
}

/// Text an input method is still composing, drawn at the cursor and not yet in the grid.
///
/// ## Why it is drawn HERE rather than echoed into the engine
///
/// A composition is not terminal output. Nothing has been sent to the pty, the shell has not seen a
/// byte, and an input method may replace the whole run on the next keystroke — feeding it to the
/// engine would put text on the grid that the program never emitted and that no `\b` can take back.
/// So it is painted over the cells the cursor is standing on, and it disappears without the grid
/// ever having changed.
///
/// This is `docs/68` §5.1 item 8, and Telex is why it is on the critical path: typing `Tieengs` to
/// get `Tiếng` is SEVEN keystrokes of composition, so a surface that draws nothing until the commit
/// shows the user nothing at all for the whole word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Preedit<'t> {
    /// The composing text, exactly as the input method last reported it.
    pub text: &'t str,
    /// How many CELLS it takes, measured by the engine's own segmenter — see
    /// [`slopdesk_vterm::text_cells`]. Carried rather than re-derived because the measurement is
    /// taken once where the input method reports, never on the sixty-times-a-second path.
    pub cells: u16,
    /// How many cells into `text` the composition's own caret sits.
    pub cursor_cells: u16,
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
        preedit: Option<Preedit<'_>>,
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

        // A composition REPLACES the caret rather than sitting beside it: the input method owns the
        // insertion point while it is composing, and two carets on one cell — the terminal's and
        // the composition's — is the picture that makes a Telex user unsure which one their
        // next keystroke goes to.
        match preedit.filter(|preedit| preedit.cells > 0) {
            Some(preedit) => {
                self.preedit_pass(preedit, frame, layout, style, cache, shaper, rasterizer, out);
            },
            None => paint_cursor(frame, layout, style, out),
        }
    }

    /// Draws one composition over the cells the cursor stands on.
    ///
    /// Everything it emits is one span wide: a bed so the shell's own echo cannot read through, the
    /// underline every platform draws under uncommitted text, the composition's caret, and the text
    /// itself. Nothing here consults a row, because the composing text is not in one.
    #[expect(
        clippy::too_many_arguments,
        reason = "the same six owners `paint` itself takes, plus the composition — every one used once"
    )]
    fn preedit_pass(
        &mut self,
        preedit: Preedit<'_>,
        frame: &Frame,
        layout: &BlockLayout,
        style: &PaintStyle,
        cache: &mut GlyphCache,
        shaper: &mut impl TextShaper,
        rasterizer: &mut impl GlyphRasterizer,
        out: &mut DrawList,
    ) {
        // No cursor means no insertion point, and a composition drawn at a guessed one would be
        // worse than a composition not drawn: it would claim the next keystroke lands somewhere it
        // does not.
        let Some((cursor, geometry, top)) = cursor_placement(frame, layout, style) else {
            return;
        };
        let cols = ColumnSpan {
            start: cursor.x,
            end: cursor.x.saturating_add(preedit.cells),
        };
        let bounds = geometry.span(top, cols);

        // The bed is opaque and in the BACKGROUND buffer, so the glyphs of the composition draw
        // over it and the grid's own cells under it do not. Drawn even on the default
        // background, unlike `background_pass`'s coalescing: the cells beneath may carry
        // any colour at all, and this is the one rect whose job is to hide them.
        out.push_background(rect_instance(
            bounds,
            frame.colors.background.into(),
            RectStyle::Solid,
        ));

        let underline = geometry.underline(top, cols, UnderlineStyle::Single);
        for line in [underline.first, underline.second].into_iter().flatten() {
            out.push_overlay(rect_instance(
                line,
                frame.colors.foreground.into(),
                underline.style,
            ));
        }

        // A BAR, whatever shape the terminal's own cursor has: this caret sits between two
        // composing characters rather than on one, and a block drawn there would cover the
        // character the user is about to change. `focused: true` because a composition only
        // exists while the surface holds the keyboard — there is no unfocused state for it
        // to be hollow in.
        let caret = geometry.cursor(
            top,
            FrameCursor {
                x: cursor.x.saturating_add(preedit.cursor_cells),
                shape: CursorShape::Bar,
                blinking: false,
                at_wide_tail: false,
                ..cursor
            },
            true,
        );
        out.push_overlay(rect_instance(
            caret.rect,
            cursor_color(cursor, style),
            caret.style,
        ));

        self.shape_and_emit(
            preedit.text,
            cols,
            top,
            geometry.baseline(top),
            &geometry,
            style,
            TextKey {
                color: frame.colors.foreground.into(),
                bold: false,
                italic: false,
            },
            cache,
            shaper,
            rasterizer,
            out,
        );
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "a paint pass needs the frame, the row, its place, the style and three sinks; bundling \
                  them into a struct would move the argument list rather than shorten it"
    )]
    pub(crate) fn paint_row(
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
            row_index,
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
        row_index: u16,
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

            // The sprite intercept sits HERE and not earlier: `paints_text` has already answered
            // blink and the hidden attribute, and `text_key` has already folded in the selection
            // and the cursor's inversion. A sprite that skipped both would keep drawing through
            // the dark half of a blink and stay the wrong colour under the caret.
            if let Some(placed) = placed_sprite(row, cell, col, row_index, top, geometry, frame, style) {
                emit_sprite(placed, key.color, cache, out);
                col = col.saturating_add(1);
                continue;
            }

            let start = col;
            let mut end = col.saturating_add(1);
            // A run stops at the cursor cell so its glyph can be recoloured on its own, at any cell
            // that changes the font or has nothing to shape, and at a sprite — which is not text
            // and must not be handed to the shaper as though it were.
            while let Some(next) = row.cells.get(end as usize).copied() {
                if inverting_cursor_col == Some(end)
                    || !paints_text(row, next, style)
                    || text_key(next, end, frame, style, selected, inverting_cursor_col) != key
                    || placed_sprite(row, next, end, row_index, top, geometry, frame, style).is_some()
                {
                    break;
                }
                end = end.saturating_add(1);
            }

            let cols = ColumnSpan { start, end };
            if let Some(text) = run_text(row, cols) {
                self.shape_and_emit(
                    text, cols, top, baseline, geometry, style, key, cache, shaper, rasterizer, out,
                );
            }
            col = end;
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "one run, its place, its font, the atlas and the sink — every argument is used once"
    )]
    fn shape_and_emit(
        &mut self,
        text: &str,
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
    let Some((cursor, geometry, top)) = cursor_placement(frame, layout, style) else {
        return;
    };
    if !cursor_visible(cursor, style) {
        return;
    }
    let placed = geometry.cursor(top, cursor, style.focused);
    let instance = rect_instance(placed.rect, cursor_color(cursor, style), placed.style);
    if placed.inverts_glyph {
        out.push_background(instance);
    } else {
        out.push_overlay(instance);
    }
}

/// The cursor's colour with [`PaintStyle::cursor_opacity`] folded into its alpha.
///
/// The engine decides the HUE — a theme's default or whatever `OSC 12` last set — and the renderer
/// decides how solid it is, so the two meet exactly here and nowhere else.
///
/// `f64::max` then `f64::min` rather than `clamp`, because a NaN opacity has to land somewhere
/// honest: `max` puts NaN at `0.0` and `min` leaves it, so a caller that computed its way to NaN
/// gets an invisible cursor rather than an alpha byte cast from garbage. `clamp` RETURNS NaN, which
/// is exactly the value the cast below has no answer for.
#[expect(
    clippy::manual_clamp,
    reason = "the NaN behaviour is the reason for the pair — `clamp` propagates it, this does not"
)]
fn cursor_color(cursor: FrameCursor, style: &PaintStyle) -> Rgba {
    let opacity = f64::min(f64::max(style.cursor_opacity, 0.0), 1.0);
    let alpha = opacity * 255.0;
    Rgba {
        r: cursor.color.r,
        g: cursor.color.g,
        b: cursor.color.b,
        // `as` after the bound above is exact for `0.0..=255.0`, and saturating rather than wrapping
        // for anything that somehow got through — including the NaN the `max` already sent to zero.
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "the value is bounded to 0.0..=255.0 two lines up, where `as` is exact"
        )]
        a: alpha.round() as u8,
    }
}

/// Where the insertion point is this frame: the cursor, its block's geometry, and the row's top.
///
/// Shared by the caret and the composition so the two can never land on different cells. The blink
/// clock is deliberately NOT consulted here — a composition is drawn through the dark half of the
/// cycle, and folding the test in would have made that a special case rather than the caller's
/// rule.
fn cursor_placement(
    frame: &Frame,
    layout: &BlockLayout,
    style: &PaintStyle,
) -> Option<(FrameCursor, CellGeometry, f64)> {
    let cursor = frame.cursor?;
    let block = layout
        .block_at_row(cursor.y)
        .filter(|block| block.visible.contains(cursor.y))?;
    let content_y = block.row_y(cursor.y, style.geometry.metrics.cell_height)?;
    let geometry = CellGeometry {
        metrics: CellMetrics {
            origin_x: style.geometry.metrics.origin_x + block.body.x,
            ..style.geometry.metrics
        },
        ..style.geometry
    };
    Some((cursor, geometry, style.content_origin_y + content_y))
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
        style.cursor_text.unwrap_or_else(|| {
            Rgba::from(if cell.bg == frame.colors.background {
                frame.colors.background
            } else {
                cell.bg
            })
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

/// A sprite that has been keyed and placed, ready to rasterise and emit.
#[derive(Debug, Clone, Copy)]
struct PlacedSprite {
    /// What to draw, at what size.
    key: SpriteKey,
    /// The snapped left edge in device pixels.
    x: f64,
    /// The snapped top edge in device pixels.
    y: f64,
}

/// The sprite a cell draws instead of a glyph, or `None` when the cell is ordinary text.
///
/// Placement comes from the CELL and not from the baseline, which is the whole point of the family:
/// a sprite carries no bearing and fills the snapped cell box exactly, so a column of `│` is one
/// unbroken rule however the row heights fall. Shaping the same character would place it against a
/// baseline that moves with the font's ascent.
#[expect(
    clippy::too_many_arguments,
    reason = "the cell, where it sits, the grid it sits in and the frame around it — each read once"
)]
fn placed_sprite(
    row: &FrameRow,
    cell: FrameCell,
    col: u16,
    row_index: u16,
    top: f64,
    geometry: &CellGeometry,
    frame: &Frame,
    style: &PaintStyle,
) -> Option<PlacedSprite> {
    let glyph = cell_char(row, cell)?;
    // The cheap test first: all but five ranges are decided by the codepoint alone, and every other
    // cell in a frame is ordinary text that must not pay for a neighbour lookup.
    if !sprite::covers_unconditionally(glyph as u32) && !sprite::is_joinable(glyph) {
        return None;
    }

    let bounds = geometry.cell(top, col);
    let (x, width) = sprite::snap(bounds.x, bounds.x + bounds.width)?;
    let (y, height) = sprite::snap(top, top + geometry.metrics.cell_height)?;

    let join = if style.arrow_box_drawing_join && sprite::is_joinable(glyph) {
        join_mask(frame, row_index, col)
    } else {
        JoinMask::NONE
    };
    let key = SpriteKey::new(glyph, width, height, line_weight(geometry), join)?;
    Some(PlacedSprite { key, x, y })
}

/// Rasterises a placed sprite and pushes it at the cell's own corner.
fn emit_sprite(placed: PlacedSprite, color: Rgba, cache: &mut GlyphCache, out: &mut DrawList) {
    let Some(glyph) = cache.sprite(placed.key) else {
        return;
    };
    if glyph.is_blank() {
        return;
    }
    // Always the alpha atlas: a sprite is coverage, and the colour is the cell's foreground with
    // the selection and the cursor already folded in by `text_key`.
    let uv = cache.alpha_atlas().uv(glyph.region);
    out.push_glyph(GlyphInstance {
        x: px(placed.x),
        y: px(placed.y),
        width: px(f64::from(glyph.region.width)),
        height: px(f64::from(glyph.region.height)),
        uv,
        color,
        color_atlas: 0,
    });
}

/// The cell's single character, or `None` for anything a sprite cannot be.
///
/// A sprite is one codepoint by definition, so a cluster with a combining mark, a variation
/// selector or a ZWJ sequence is not one — `→\u{FE0F}` is an emoji presentation request and belongs
/// to the font. An empty cell answers `None` too, though `paints_text` has already excluded it.
fn cell_char(row: &FrameRow, cell: FrameCell) -> Option<char> {
    let mut chars = row.cell_text(cell).chars();
    let first = chars.next()?;
    chars.next().is_none().then_some(first)
}

/// Which of the four neighbours runs a box rule into this cell.
///
/// Reads across rows as well as within one, which is why the pass carries `row_index`: `│` above a
/// `↓` is the case the whole feature exists for, and a within-row-only mask would miss both
/// vertical arms. A neighbour off the edge of the frame simply does not join.
fn join_mask(frame: &Frame, row_index: u16, col: u16) -> JoinMask {
    let neighbour = |row: u16, col: u16| -> Option<char> {
        let row = frame.row(row)?;
        let cell = row.cells.get(col as usize).copied()?;
        cell_char(row, cell)
    };
    let facing = |edge: CellEdge, at: Option<(u16, u16)>| -> bool {
        at.and_then(|(row, col)| neighbour(row, col))
            .is_some_and(|glyph| sprite::faces(glyph, edge))
    };

    let up = row_index.checked_sub(1).map(|row| (row, col));
    let down = row_index.checked_add(1).map(|row| (row, col));
    let left = col.checked_sub(1).map(|col| (row_index, col));
    let right = col.checked_add(1).map(|col| (row_index, col));

    let mut mask = JoinMask::NONE;
    for (edge, at) in [
        (CellEdge::Up, up),
        (CellEdge::Down, down),
        (CellEdge::Left, left),
        (CellEdge::Right, right),
    ] {
        if facing(edge, at) {
            mask = mask.with(edge);
        }
    }
    mask
}

/// The base line weight a sprite draws its rules at, in whole device pixels.
///
/// The underline's thickness, because that is the one weight the font already publishes that was
/// chosen to sit alongside its glyphs at this size — Ghostty's `box_thickness` is the same number
/// by the same argument. Never zero: every family divides by it.
fn line_weight(geometry: &CellGeometry) -> u16 {
    let thickness = geometry.font.underline_thickness;
    if !thickness.is_finite() {
        return 1;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "bounded to 1.0..=u16::MAX and integral by the round"
    )]
    let weight = f64::min(f64::max(thickness.round(), 1.0), f64::from(u16::MAX)) as u16;
    weight
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
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::CellMetrics;
    use slopdesk_vterm::{
        CellFlags, ColumnSpan, CursorShape, Frame, FrameCell, FrameCursor, FrameRow, Rgb, RowSemantic,
        UnderlineStyle,
    };

    use super::{PaintStyle, Painter, Preedit, SelectionColors};
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
            cursor_opacity: 1.0,
            cursor_text: None,
            arrow_box_drawing_join: true,
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
        paint_with(frame, style, None)
    }

    fn paint_with(frame: &Frame, style: &PaintStyle, preedit: Option<Preedit<'_>>) -> (DrawList, OneToOne) {
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
            preedit,
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
            cursor_opacity: 1.0,
            cursor_text: None,
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
    fn cursor_opacity_reaches_the_caret_alpha_and_nothing_else() {
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

        for (opacity, alpha) in [(1.0, 255_u8), (0.5, 128), (2.0, 255), (-1.0, 255)] {
            let (list, _) = paint(&frame, &PaintStyle {
                cursor_opacity: opacity,
                cursor_text: None,
                ..style()
            });
            // `-1.0` clamps to `0.0`, whose caret is dropped before it reaches the list — so the
            // only out-of-range case with a rect to inspect is the high one. The low one is
            // asserted below, where its DISAPPEARANCE is the observable fact.
            let Some(caret) = list.overlays.first() else {
                assert!(
                    opacity < 0.0,
                    "only a transparent caret is dropped, not opacity {opacity}"
                );
                continue;
            };
            assert_eq!(list.overlays.len(), 1, "the bar caret at opacity {opacity}");
            assert_eq!(caret.color.a, alpha, "opacity {opacity} out of range clamps");
            assert_eq!(
                (caret.color.r, caret.color.g, caret.color.b),
                (0xFF, 0xFF, 0xFF),
                "the HUE stays the engine's — opacity only touches the alpha"
            );
        }

        let (invisible, _) = paint(&frame, &PaintStyle {
            cursor_opacity: 0.0,
            cursor_text: None,
            ..style()
        });
        assert!(
            invisible.overlays.is_empty(),
            "a fully transparent caret is dropped rather than encoded, which is what makes opacity zero a \
             real way to turn the cursor off"
        );
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
    fn cursor_text_recolours_only_the_glyph_the_caret_covers() {
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
        let magenta = Rgba {
            r: 0xFF,
            g: 0x00,
            b: 0xFF,
            a: 0xFF,
        };

        let (default, _) = paint(&frame, &style());
        let (themed, _) = paint(&frame, &PaintStyle {
            cursor_text: Some(magenta),
            ..style()
        });

        assert!(
            !default.glyphs.iter().any(|glyph| glyph.color == magenta),
            "no colour arrives unasked — `None` keeps the cell's own background"
        );
        assert_eq!(
            themed
                .glyphs
                .iter()
                .filter(|glyph| glyph.color == magenta)
                .count(),
            1,
            "exactly the one glyph under the caret, never the three beside it"
        );
        assert_eq!(
            default.glyphs.len(),
            themed.glyphs.len(),
            "a recolour is not a reflow: the same glyphs are drawn either way"
        );
        assert_eq!(
            default.overlays, themed.overlays,
            "the caret rect itself is untouched — this setting is about the text under it"
        );
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
            cursor_opacity: 1.0,
            cursor_text: None,
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
            cursor_opacity: 1.0,
            cursor_text: None,
            ..style()
        });
        assert!(dark.overlays.is_empty());
    }

    /// One row per string, all `Output`, so a sprite can read the cell above and below it.
    fn frame_of_rows(rows: &[&str]) -> Frame {
        let mut frame = Frame::new();
        for text in rows {
            let single = frame_of(text, |_| {});
            frame.cols = frame.cols.max(single.cols);
            frame.rows.extend(single.rows);
        }
        frame
    }

    /// The glyph instances that came from the sprite face: a sprite fills its cell exactly, and the
    /// fake rasteriser draws text as an 8×8 square, so the size alone separates them.
    fn sprites(list: &DrawList) -> Vec<crate::quad::GlyphInstance> {
        list.glyphs
            .iter()
            .filter(|glyph| glyph.width > 8.0 || glyph.height > 8.0)
            .copied()
            .collect()
    }

    #[test]
    fn a_box_rule_is_drawn_here_and_never_reaches_the_shaper() {
        // The whole reason the intercept sits inside the walk rather than beside it: `─` must not
        // be shaped, AND it must break the run around it so `a` and `b` are still shaped
        // separately.
        let frame = frame_of("a─b", |_| {});
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(shaper.runs, vec!["a".to_owned(), "b".to_owned()]);
        let drawn = sprites(&list);
        assert_eq!(drawn.len(), 1, "one sprite for one rule");
        assert!((drawn[0].x - 10.0).abs() < 1e-6, "at its own cell's left edge");
        assert!(
            (drawn[0].y - 0.0).abs() < 1e-6,
            "at the cell's top, not against a baseline"
        );
        assert!((drawn[0].width - 10.0).abs() < 1e-6);
        assert!((drawn[0].height - 20.0).abs() < 1e-6);
        assert_eq!(
            drawn[0].color_atlas, 0,
            "coverage, tinted by the cell's foreground"
        );
    }

    #[test]
    fn a_run_of_rules_tiles_with_no_seam_and_no_overlap() {
        let frame = frame_of("────", |_| {});
        let (list, shaper) = paint(&frame, &style());

        assert!(shaper.runs.is_empty(), "nothing here is text");
        let drawn = sprites(&list);
        assert_eq!(drawn.len(), 4);
        for pair in drawn.windows(2) {
            let (Some(left), Some(right)) = (pair.first(), pair.get(1)) else {
                continue;
            };
            assert!(
                (left.x + left.width - right.x).abs() < 1e-6,
                "cell {} ends at {}, the next starts at {}",
                left.x,
                left.x + left.width,
                right.x
            );
        }
    }

    #[test]
    fn a_standalone_arrow_keeps_the_typefaces_own() {
        // `→` in prose is a character. Nothing joins it, so it falls through to the shaper.
        let frame = frame_of("a → b", |_| {});
        let (list, shaper) = paint(&frame, &style());

        assert!(sprites(&list).is_empty(), "no sprite for a lone arrow");
        assert!(
            shaper.runs.iter().any(|run| run.contains('→')),
            "the font drew it"
        );
    }

    #[test]
    fn an_arrow_a_rule_runs_into_is_drawn_here_instead() {
        let frame = frame_of("──→", |_| {});
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(sprites(&list).len(), 3, "two rules and the arrow they run into");
        assert!(shaper.runs.is_empty(), "the arrow left the font");
    }

    #[test]
    fn the_join_reads_the_row_above_as_well_as_the_one_beside() {
        // The case `row_index` is threaded for. A `│` stacked over a `↓` is a vertical join, and a
        // pass that could only see within its own row would miss both vertical arms.
        let frame = frame_of_rows(&["│", "↓"]);
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(sprites(&list).len(), 2, "the rule and the arrow under it");
        assert!(shaper.runs.is_empty());
    }

    #[test]
    fn an_arrow_beside_something_that_is_not_a_rule_stays_with_the_font() {
        // A block element is not a rule: joining a stem to the middle of a solid bar is the wrong
        // picture, so `faces` answers false and the arrow falls through.
        let frame = frame_of("█→", |_| {});
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(sprites(&list).len(), 1, "only the block");
        assert!(shaper.runs.iter().any(|run| run.contains('→')));
    }

    #[test]
    fn turning_the_join_off_returns_the_arrow_to_the_font_and_leaves_the_rules() {
        let frame = frame_of("──→", |_| {});
        let style = PaintStyle {
            arrow_box_drawing_join: false,
            ..style()
        };
        let (list, shaper) = paint(&frame, &style);

        assert_eq!(sprites(&list).len(), 2, "the rules are unconditional");
        assert!(shaper.runs.iter().any(|run| run.contains('→')));
    }

    #[test]
    fn a_blinking_rule_disappears_on_the_dark_half_of_the_cycle() {
        // Why the intercept sits AFTER `paints_text`: a sprite that skipped it would keep drawing
        // through the dark half, and a blinking table would have a rule that never blinked.
        let frame = frame_of("─", |cell| cell.flags = CellFlags::BLINK);
        let style = PaintStyle {
            blink_visible: false,
            ..style()
        };
        let (list, _) = paint(&frame, &style);

        assert!(sprites(&list).is_empty());
    }

    #[test]
    fn a_rule_under_the_block_cursor_takes_the_cursor_text_colour() {
        // Why the intercept sits AFTER `text_key`: the colour is the one the cell resolved to,
        // selection and caret inversion included, not the cell's raw foreground.
        let magenta = Rgba::opaque(200, 30, 200);
        let mut frame = frame_of("─", |_| {});
        frame.cursor = Some(FrameCursor {
            x: 0,
            y: 0,
            shape: CursorShape::Block,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        });
        let style = PaintStyle {
            cursor_text: Some(magenta),
            ..style()
        };
        let (list, _) = paint(&frame, &style);

        let drawn = sprites(&list);
        assert_eq!(drawn.len(), 1);
        assert_eq!(drawn[0].color, magenta);
    }

    #[test]
    fn an_emoji_presentation_arrow_is_a_character_and_not_a_sprite() {
        // `→\u{FE0F}` asks for the emoji form. A sprite is one codepoint by definition, so the
        // cluster goes to the font even with a rule beside it.
        let mut frame = frame_of("─→", |_| {});
        let cell = frame.rows[0].cells[1];
        let start = cell.text.offset as usize + cell.text.len as usize;
        frame.rows[0].text.insert(start, '\u{FE0F}');
        frame.rows[0].cells[1].text.len += 3;
        let (list, shaper) = paint(&frame, &style());

        assert_eq!(sprites(&list).len(), 1, "only the rule");
        assert!(shaper.runs.iter().any(|run| run.contains('→')));
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
            None,
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

    /// A frame with the caret parked on column one, for the composition tests.
    fn frame_with_cursor(text: &str) -> Frame {
        let mut frame = frame_of(text, |_| {});
        frame.cursor = Some(FrameCursor {
            x: 1,
            y: 0,
            shape: CursorShape::Block,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        });
        frame
    }

    #[test]
    fn a_composition_draws_its_text_over_the_cells_at_the_cursor() {
        let frame = frame_with_cursor("abcd");
        let (list, shaper) = paint_with(
            &frame,
            &style(),
            Some(Preedit {
                text: "ế",
                cells: 1,
                cursor_cells: 1,
            }),
        );

        assert!(
            shaper.runs.contains(&"ế".to_owned()),
            "the composing text is shaped: {:?}",
            shaper.runs
        );
        let bed = list
            .backgrounds
            .iter()
            .find(|rect| (f64::from(rect.x) - 10.0).abs() < 1e-6)
            .expect("a bed under the composition, at the cursor's column");
        assert!((f64::from(bed.width) - 10.0).abs() < 1e-6, "one cell wide");
    }

    #[test]
    fn a_composition_replaces_the_terminal_caret_rather_than_joining_it() {
        let frame = frame_with_cursor("abcd");
        let (bare, _) = paint(&frame, &style());
        let (composing, _) = paint_with(
            &frame,
            &style(),
            Some(Preedit {
                text: "ế",
                cells: 1,
                cursor_cells: 1,
            }),
        );

        // The block caret is a BACKGROUND rect; the composition's bar is an overlay. Two carets on
        // one cell is the picture this asserts against.
        assert_eq!(
            bare.overlays.len(),
            0,
            "the terminal's own block caret draws no overlay"
        );
        assert_eq!(
            composing.overlays.len(),
            2,
            "the composition's underline and its bar caret, and nothing else"
        );
    }

    #[test]
    fn a_wide_composition_beds_and_underlines_every_cell_it_takes() {
        let frame = frame_with_cursor("abcd");
        let (list, _) = paint_with(
            &frame,
            &style(),
            Some(Preedit {
                text: "漢字",
                cells: 4,
                cursor_cells: 4,
            }),
        );

        let bed = list
            .backgrounds
            .iter()
            .find(|rect| (f64::from(rect.x) - 10.0).abs() < 1e-6)
            .expect("a bed at the cursor's column");
        assert!(
            (f64::from(bed.width) - 40.0).abs() < 1e-6,
            "two double-width clusters is four cells"
        );
        let underline = list
            .overlays
            .iter()
            .find(|rect| (f64::from(rect.width) - 40.0).abs() < 1e-6)
            .expect("an underline across the whole composition");
        assert_eq!(underline.style, RectStyle::Solid);
    }

    #[test]
    fn an_empty_composition_leaves_the_terminals_own_caret_standing() {
        let frame = frame_with_cursor("abcd");
        let (list, _) = paint_with(
            &frame,
            &style(),
            Some(Preedit {
                text: "",
                cells: 0,
                cursor_cells: 0,
            }),
        );
        assert_eq!(list.backgrounds.len(), 1, "the block caret, and no bed");
        assert!(list.overlays.is_empty());
    }

    #[test]
    fn a_composition_draws_through_the_dark_half_of_the_blink() {
        let frame = frame_with_cursor("abcd");
        let (list, shaper) = paint_with(
            &frame,
            &PaintStyle {
                blink_visible: false,
                cursor_opacity: 1.0,
                cursor_text: None,
                ..style()
            },
            Some(Preedit {
                text: "ế",
                cells: 1,
                cursor_cells: 1,
            }),
        );
        assert!(
            shaper.runs.contains(&"ế".to_owned()),
            "a composition that blinked out would hide what the user is typing"
        );
        assert_eq!(list.overlays.len(), 2);
    }

    #[test]
    fn a_composition_with_no_cursor_to_stand_on_draws_nothing() {
        let frame = frame_of("abcd", |_| {});
        let (list, shaper) = paint_with(
            &frame,
            &style(),
            Some(Preedit {
                text: "ế",
                cells: 1,
                cursor_cells: 1,
            }),
        );
        assert!(!shaper.runs.contains(&"ế".to_owned()));
        assert!(list.backgrounds.is_empty());
        assert!(list.overlays.is_empty());
    }

    #[test]
    fn painting_twice_does_not_accumulate() {
        let frame = frame_of("abcd", |cell| cell.bg = Rgb::new(10, 20, 30));
        let (first, _) = paint(&frame, &style());
        let (second, _) = paint(&frame, &style());
        assert_eq!(first.len(), second.len());
    }
}
