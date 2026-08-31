//! Where things are: cells, decorations, the cursor, the scrollbar.
//!
//! ## Device pixels, all the way through
//!
//! Every number in this module is a DEVICE pixel. Points stop at the view, which multiplies by the
//! contents scale once and hands the result down. The alternative — carrying points here and
//! scaling at the shader — puts the scale in two places, and a renderer that is half a pixel off on
//! a 2× display looks like a font bug for a week before anyone suspects the units.
//!
//! ## Reusing `slopdesk_terminal::geometry`
//!
//! [`Rect`] and the span arithmetic are that module's, not a second copy: its header records
//! `span_rect` as a drift pair it closed, and re-spelling `origin + cell_width * col` here would
//! reopen it. What is new here is everything a *renderer* needs and a hit-test does not —
//! baselines, underline placement, cursor shapes, thumb geometry.
//!
//! ## Bit-exact, for the same reason as the module it borrows from
//!
//! `a * b + c` stays a separate `*` and `+`, never `mul_add`; clamps are [`f64::max`]/[`f64::min`],
//! never a `<` ternary. The cases below are pinned by hand-computed numbers, and a fused
//! multiply-add moves the last bit of one of them without failing anything else.

use slopdesk_terminal::geometry::{CellMetrics, Rect, rect};
use slopdesk_vterm::{ColumnSpan, CursorShape, FrameCursor, UnderlineStyle};

use crate::quad::RectStyle;

/// What the font says about drawing inside a cell.
///
/// Every offset is measured DOWN from the cell's top edge, which is the coordinate space every
/// other number in this crate uses. Core Text reports underline position as a negative offset from
/// the baseline; converting once, at the boundary, is why nothing below has to remember a sign
/// convention.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FontMetrics {
    /// The baseline's offset from the cell's top edge.
    pub baseline: f64,
    /// The underline's top edge, from the cell's top edge.
    pub underline_position: f64,
    /// How thick an underline is. Never drawn thinner than one device pixel.
    pub underline_thickness: f64,
    /// The strikethrough's top edge, from the cell's top edge.
    pub strikethrough_position: f64,
    /// How thick a strikethrough is.
    pub strikethrough_thickness: f64,
    /// How thick a bar cursor is, and how thick an underline cursor is.
    ///
    /// Separate from [`FontMetrics::underline_thickness`] because a cursor is a UI affordance
    /// rather than typography: it stays legible at a weight the font's own underline would not.
    pub cursor_thickness: f64,
}

impl FontMetrics {
    /// The gap between the cell's top edge and an overline.
    ///
    /// An overline has no metric of its own in any font this ships with, so it is placed
    /// symmetrically to the underline: the same distance from the top that the underline sits from
    /// the bottom would be, which reads as deliberate rather than as an underline drawn upside
    /// down.
    #[must_use]
    pub fn overline_position(self, cell_height: f64) -> f64 {
        f64::max(
            cell_height - self.underline_position - self.underline_thickness,
            0.0,
        )
    }
}

/// A cell grid, measured.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellGeometry {
    /// Cell size and the grid's origin inside the drawable.
    pub metrics: CellMetrics,
    /// What the font says about drawing inside one.
    pub font: FontMetrics,
}

/// An underline, which is one rect for most styles and two for [`UnderlineStyle::Double`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Underline {
    /// Which pipeline draws both rects.
    pub style: RectStyle,
    /// The line itself, or the upper of the two.
    pub first: Option<Rect>,
    /// The lower line of a double underline.
    pub second: Option<Rect>,
}

impl Underline {
    /// Nothing to draw.
    pub const NONE: Self = Self {
        style: RectStyle::Solid,
        first: None,
        second: None,
    };
}

/// Where the cursor draws and what it does to the cell under it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cursor {
    /// The rect to fill.
    pub rect: Rect,
    /// Which pipeline draws it.
    pub style: RectStyle,
    /// Whether the glyph under the cursor must be redrawn in the background colour.
    ///
    /// True only for a filled block: it covers the cell, so leaving the glyph in its own colour
    /// would hide the character the user is about to overwrite. Every other shape leaves the glyph
    /// alone, which is why this is a field and not something the caller re-derives from the shape.
    pub inverts_glyph: bool,
}

impl CellGeometry {
    /// The top edge of a row of an UNBROKEN grid, counted from the grid's own origin.
    ///
    /// Only correct where rows are evenly stacked, which is the alternate screen and nothing else.
    /// Under block layout a row's top comes from [`crate::block::PlacedBlock::row_y`], because a
    /// header or a collapse puts rows somewhere this arithmetic cannot predict. Every method below
    /// therefore takes a row TOP rather than a row INDEX: there is one place that decides where a
    /// row is, and it is never here.
    #[must_use]
    pub fn row_top(self, row: u16) -> f64 {
        self.metrics.origin_y + self.metrics.cell_height * f64::from(row)
    }

    /// The rect of one cell on the row whose top edge is `row_top`.
    #[must_use]
    pub fn cell(self, row_top: f64, col: u16) -> Rect {
        self.span(row_top, ColumnSpan {
            start: col,
            end: col.saturating_add(1),
        })
    }

    /// The rect of a half-open column span on the row whose top edge is `row_top`.
    #[must_use]
    pub fn span(self, row_top: f64, cols: ColumnSpan) -> Rect {
        let placed = CellMetrics {
            origin_y: row_top,
            ..self.metrics
        };
        rect(placed, 0, i64::from(cols.start), i64::from(cols.end))
    }

    /// The baseline's y for the row whose top edge is `row_top`.
    #[must_use]
    pub fn baseline(self, row_top: f64) -> f64 {
        row_top + self.font.baseline
    }

    /// The underline for a span, or [`Underline::NONE`] for [`UnderlineStyle::None`].
    ///
    /// A double underline is two lines inside the space one would occupy — the second is placed
    /// below the first by twice the thickness, and both are pulled up so the pair still sits above
    /// the cell's bottom edge. Squeezing them rather than letting the lower one hang is what keeps
    /// a double underline from colliding with the row beneath it.
    #[must_use]
    pub fn underline(self, row_top: f64, cols: ColumnSpan, style: UnderlineStyle) -> Underline {
        let thickness = f64::max(self.font.underline_thickness, 1.0);
        let bounds = self.span(row_top, cols);
        if bounds.width <= 0.0 {
            return Underline::NONE;
        }
        let top = row_top;
        let line = |offset: f64| {
            Rect {
                x: bounds.x,
                y: top + offset,
                width: bounds.width,
                height: thickness,
            }
        };

        match style {
            UnderlineStyle::None => Underline::NONE,
            UnderlineStyle::Double => {
                let span = thickness * 3.0;
                let first = f64::max(self.font.underline_position - span + thickness, 0.0);
                Underline {
                    style: RectStyle::Solid,
                    first: Some(line(first)),
                    second: Some(line(first + thickness * 2.0)),
                }
            },
            // A curly underline needs vertical room the flat styles do not: the wave is drawn inside
            // the rect, so the rect is three times a line's thickness and rides that much higher.
            UnderlineStyle::Curly => {
                let height = thickness * 3.0;
                let top_offset = f64::max(self.font.underline_position - thickness, 0.0);
                Underline {
                    style: RectStyle::Curly,
                    first: Some(Rect {
                        height,
                        ..line(top_offset)
                    }),
                    second: None,
                }
            },
            UnderlineStyle::Single | UnderlineStyle::Dotted | UnderlineStyle::Dashed => {
                Underline {
                    style: match style {
                        UnderlineStyle::Dotted => RectStyle::Dotted,
                        UnderlineStyle::Dashed => RectStyle::Dashed,
                        // `Single`, and — the match above having taken every other named style — nothing
                        // else can arrive here.
                        _ => RectStyle::Solid,
                    },
                    first: Some(line(self.font.underline_position)),
                    second: None,
                }
            },
        }
    }

    /// The strikethrough for a span.
    #[must_use]
    pub fn strikethrough(self, row_top: f64, cols: ColumnSpan) -> Rect {
        let bounds = self.span(row_top, cols);
        let top = row_top;
        Rect {
            x: bounds.x,
            y: top + self.font.strikethrough_position,
            width: bounds.width,
            height: f64::max(self.font.strikethrough_thickness, 1.0),
        }
    }

    /// The overline for a span.
    #[must_use]
    pub fn overline(self, row_top: f64, cols: ColumnSpan) -> Rect {
        let bounds = self.span(row_top, cols);
        let top = row_top;
        Rect {
            x: bounds.x,
            y: top + self.font.overline_position(self.metrics.cell_height),
            width: bounds.width,
            height: f64::max(self.font.underline_thickness, 1.0),
        }
    }

    /// Where the cursor draws.
    ///
    /// `focused` overrides the shape rather than being folded into it upstream: the terminal asks
    /// for a shape, and losing key focus is the client's fact, not the shell's. An unfocused
    /// surface draws the outline whatever was asked for, which is the convention every terminal
    /// on this platform uses and the one users read as "typing goes elsewhere".
    #[must_use]
    pub fn cursor(self, row_top: f64, cursor: FrameCursor, focused: bool) -> Cursor {
        // A bar on the trailing half of a wide character belongs at the PAIR's leading edge, not in
        // the middle of the glyph. The frame flags the case; here is where it is honoured.
        let col = if cursor.at_wide_tail {
            cursor.x.saturating_sub(1)
        } else {
            cursor.x
        };
        let cell = self.cell(row_top, col);
        let thickness = f64::max(self.font.cursor_thickness, 1.0);

        if !focused {
            return Cursor {
                rect: cell,
                style: RectStyle::Hollow,
                inverts_glyph: false,
            };
        }

        match cursor.shape {
            CursorShape::Bar => {
                Cursor {
                    rect: Rect {
                        width: f64::min(thickness, cell.width),
                        ..cell
                    },
                    style: RectStyle::Solid,
                    inverts_glyph: false,
                }
            },
            CursorShape::Underline => {
                let height = f64::min(thickness, cell.height);
                Cursor {
                    rect: Rect {
                        y: cell.y + cell.height - height,
                        height,
                        ..cell
                    },
                    style: RectStyle::Solid,
                    inverts_glyph: false,
                }
            },
            CursorShape::Hollow => {
                Cursor {
                    rect: cell,
                    style: RectStyle::Hollow,
                    inverts_glyph: false,
                }
            },
            CursorShape::Block => {
                Cursor {
                    rect: cell,
                    style: RectStyle::Solid,
                    inverts_glyph: true,
                }
            },
        }
    }
}

/// The insets between the drawable's edges and the grid, in device pixels.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Insets {
    /// Top inset.
    pub top: f64,
    /// Leading inset.
    pub left: f64,
    /// Bottom inset.
    pub bottom: f64,
    /// Trailing inset.
    pub right: f64,
}

impl Insets {
    /// The same inset on every edge.
    #[must_use]
    pub const fn uniform(value: f64) -> Self {
        Self {
            top: value,
            left: value,
            bottom: value,
            right: value,
        }
    }
}

/// How many cells fit in `width × height` device pixels, after `insets`.
///
/// Never answers zero in either axis. A one-cell grid is wrong on a window too small to hold one,
/// but it is *drawable*, and every layer downstream — the engine's resize, the frame's row vector,
/// the block layout — is written against a grid that exists. Answering zero would push a special
/// case into all three to describe a window the user is still dragging.
#[must_use]
pub fn grid_size(width: f64, height: f64, insets: Insets, cell_width: f64, cell_height: f64) -> (u16, u16) {
    let usable_width = width - insets.left - insets.right;
    let usable_height = height - insets.top - insets.bottom;
    (fit(usable_width, cell_width), fit(usable_height, cell_height))
}

/// How many `cell` fit in `available`, at least one.
///
/// Guards are written in the POSITIVE so a NaN falls out as "one cell" rather than choosing an arm
/// — the same discipline `slopdesk_terminal::geometry` states in its own header.
fn fit(available: f64, cell: f64) -> u16 {
    if cell > 0.0 && available >= cell {
        let count = f64::min(available / cell, f64::from(u16::MAX));
        // Floored and fenced to `0.0..=u16::MAX` immediately above.
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "fenced into 1..=u16::MAX by the guard and the min above"
        )]
        let cells = count.floor() as u16;
        cells.max(1)
    } else {
        1
    }
}

/// Where a scrollbar's thumb sits on its track.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Thumb {
    /// The thumb's top edge, in device pixels down the track.
    pub y: f64,
    /// The thumb's height in device pixels.
    pub height: f64,
}

/// The thumb for a scrollable run of content, or `None` when everything already fits.
///
/// This replaces `ghostty_surface_viewport_info` and the fork's `SCROLLBAR` action — the one piece
/// of viewport state the surface API was answering that this crate now has to answer itself. It is
/// arithmetic over three lengths, which is why losing the surface costs nothing here.
///
/// DEVICE PIXELS, not rows, and that is the whole reason it is not a row count: what scrolls under
/// a block layout is rows PLUS chrome, and a short session with no scrollback at all can still
/// overflow its viewport by one header per command. A row-counting thumb would answer `None` for
/// exactly that case — scrollable content, no thumb — so the unit has to be the one the overflow is
/// measured in. The caller converts its scrollback rows on the way in, where the cell height is.
///
/// `min_height` keeps the thumb grabbable in a million-line scrollback, where a proportional thumb
/// would be a fraction of a pixel. The track it is squeezed out of comes off the travel, not off
/// the thumb, so the thumb still reaches both ends.
#[must_use]
pub fn scrollbar(content: f64, viewport: f64, offset: f64, track: f64, min_height: f64) -> Option<Thumb> {
    // Written in the POSITIVE so a NaN in any length falls out here rather than propagating into a
    // thumb rect — the same rule `grid_size` and the surface's pointer guards follow.
    if !(viewport > 0.0 && content > viewport && track > 0.0) {
        return None;
    }
    let (total, visible) = (content, viewport);
    let top = f64::min(f64::max(offset, 0.0), content - viewport);

    let proportional = track * (visible / total);
    let height = f64::min(f64::max(proportional, f64::min(min_height, track)), track);
    let travel = track - height;
    let scrollable = total - visible;
    let progress = if scrollable > 0.0 { top / scrollable } else { 0.0 };
    // `f64::min`/`f64::max` and not `clamp`: `CLAUDE.md`'s rule, and the reason it exists — `clamp`
    // answers NaN for a NaN input, where this chain answers zero and puts the thumb at the top.
    #[expect(clippy::manual_clamp, reason = "clamp propagates NaN where min/max fences it")]
    let fraction = f64::min(f64::max(progress, 0.0), 1.0);
    Some(Thumb {
        y: travel * fraction,
        height,
    })
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use slopdesk_terminal::geometry::CellMetrics;
    use slopdesk_vterm::{ColumnSpan, CursorShape, FrameCursor, Rgb, UnderlineStyle};

    use super::{CellGeometry, FontMetrics, Insets, grid_size, scrollbar};
    use crate::quad::RectStyle;

    fn geometry() -> CellGeometry {
        CellGeometry {
            metrics: CellMetrics {
                cell_width: 10.0,
                cell_height: 20.0,
                origin_x: 5.0,
                origin_y: 3.0,
            },
            font: FontMetrics {
                baseline: 15.0,
                underline_position: 17.0,
                underline_thickness: 1.0,
                strikethrough_position: 10.0,
                strikethrough_thickness: 1.0,
                cursor_thickness: 2.0,
            },
        }
    }

    fn cursor(shape: CursorShape) -> FrameCursor {
        FrameCursor {
            x: 4,
            y: 2,
            shape,
            color: Rgb::WHITE,
            blinking: false,
            at_wide_tail: false,
            password_input: false,
        }
    }

    #[test]
    fn a_cell_lands_where_the_metrics_say() {
        let cell = geometry().cell(geometry().row_top(2), 3);
        assert!((cell.x - 35.0).abs() < f64::EPSILON);
        assert!((cell.y - 43.0).abs() < f64::EPSILON);
        assert!((cell.width - 10.0).abs() < f64::EPSILON);
        assert!((cell.height - 20.0).abs() < f64::EPSILON);
    }

    #[test]
    fn a_double_underline_is_two_lines_that_both_stay_inside_the_cell() {
        let geometry = geometry();
        let under = geometry.underline(
            geometry.row_top(0),
            ColumnSpan { start: 0, end: 4 },
            UnderlineStyle::Double,
        );
        let (first, second) = (under.first.unwrap(), under.second.unwrap());

        assert!(first.y < second.y);
        assert!(second.y + second.height <= geometry.metrics.origin_y + geometry.metrics.cell_height);
        assert_eq!(under.style, RectStyle::Solid);
    }

    #[test]
    fn a_curly_underline_asks_for_a_taller_rect_and_its_own_pipeline() {
        let geometry = geometry();
        let curly = geometry.underline(
            geometry.row_top(0),
            ColumnSpan { start: 0, end: 1 },
            UnderlineStyle::Curly,
        );
        let single = geometry.underline(
            geometry.row_top(0),
            ColumnSpan { start: 0, end: 1 },
            UnderlineStyle::Single,
        );

        assert_eq!(curly.style, RectStyle::Curly);
        assert!(curly.first.unwrap().height > single.first.unwrap().height);
        assert_eq!(single.style, RectStyle::Solid);
    }

    #[test]
    fn dotted_and_dashed_differ_only_in_the_pipeline() {
        let geometry = geometry();
        let dotted = geometry.underline(
            geometry.row_top(0),
            ColumnSpan { start: 0, end: 3 },
            UnderlineStyle::Dotted,
        );
        let dashed = geometry.underline(
            geometry.row_top(0),
            ColumnSpan { start: 0, end: 3 },
            UnderlineStyle::Dashed,
        );

        assert_eq!(dotted.style, RectStyle::Dotted);
        assert_eq!(dashed.style, RectStyle::Dashed);
        assert_eq!(dotted.first, dashed.first);
    }

    #[test]
    fn no_underline_draws_nothing() {
        let under = geometry().underline(
            geometry().row_top(0),
            ColumnSpan { start: 0, end: 3 },
            UnderlineStyle::None,
        );
        assert!(under.first.is_none() && under.second.is_none());
    }

    #[test]
    fn a_block_cursor_covers_the_cell_and_inverts_it() {
        let drawn = geometry().cursor(geometry().row_top(2), cursor(CursorShape::Block), true);
        assert_eq!(drawn.rect, geometry().cell(geometry().row_top(2), 4));
        assert!(drawn.inverts_glyph);
        assert_eq!(drawn.style, RectStyle::Solid);
    }

    #[test]
    fn an_unfocused_cursor_is_hollow_whatever_the_shell_asked_for() {
        for shape in [CursorShape::Block, CursorShape::Bar, CursorShape::Underline] {
            let drawn = geometry().cursor(geometry().row_top(2), cursor(shape), false);
            assert_eq!(drawn.style, RectStyle::Hollow, "{shape:?} stayed filled");
            assert!(!drawn.inverts_glyph);
        }
    }

    #[test]
    fn a_bar_on_a_wide_tail_moves_to_the_pairs_leading_edge() {
        let geometry = geometry();
        let tail = FrameCursor {
            at_wide_tail: true,
            ..cursor(CursorShape::Bar)
        };
        let drawn = geometry.cursor(geometry.row_top(2), tail, true);
        assert!((drawn.rect.x - geometry.cell(geometry.row_top(2), 3).x).abs() < f64::EPSILON);
        assert!((drawn.rect.width - 2.0).abs() < f64::EPSILON);
    }

    #[test]
    fn an_underline_cursor_sits_on_the_cells_bottom_edge() {
        let geometry = geometry();
        let drawn = geometry.cursor(geometry.row_top(2), cursor(CursorShape::Underline), true);
        let cell = geometry.cell(geometry.row_top(2), 4);
        assert!((drawn.rect.y + drawn.rect.height - (cell.y + cell.height)).abs() < f64::EPSILON);
    }

    #[test]
    fn the_grid_never_collapses_to_nothing() {
        assert_eq!(
            grid_size(1000.0, 500.0, Insets::uniform(10.0), 10.0, 20.0),
            (98, 24)
        );
        assert_eq!(grid_size(4.0, 4.0, Insets::uniform(10.0), 10.0, 20.0), (1, 1));
        assert_eq!(grid_size(f64::NAN, 500.0, Insets::default(), 10.0, 20.0), (1, 25));
        assert_eq!(grid_size(100.0, 100.0, Insets::default(), 0.0, 0.0), (1, 1));
    }

    #[test]
    fn content_that_fits_has_no_thumb() {
        assert_eq!(scrollbar(480.0, 480.0, 0.0, 100.0, 20.0), None);
        assert_eq!(scrollbar(20_000.0, 0.0, 0.0, 100.0, 20.0), None);
        assert_eq!(scrollbar(f64::NAN, 480.0, 0.0, 100.0, 20.0), None);
    }

    #[test]
    fn chrome_alone_is_enough_to_earn_a_thumb() {
        // No scrollback at all — one viewport of rows, pushed past its own height by the headers
        // the block layout spends above each command. The row count would call this unscrollable.
        let thumb = scrollbar(520.0, 480.0, 0.0, 100.0, 20.0).unwrap();
        assert!(thumb.height < 100.0);
    }

    #[test]
    fn the_thumb_reaches_both_ends_and_never_leaves_the_track() {
        let track = 100.0;
        let top = scrollbar(20_000.0, 500.0, 0.0, track, 20.0).unwrap();
        let bottom = scrollbar(20_000.0, 500.0, 19_500.0, track, 20.0).unwrap();

        assert!(top.y.abs() < f64::EPSILON);
        assert!((bottom.y + bottom.height - track).abs() < 1e-9);
        assert!(
            bottom.height >= 20.0,
            "the thumb shrank below the grabbable floor"
        );
    }

    #[test]
    fn a_scroll_past_the_end_clamps_rather_than_overshooting() {
        let thumb = scrollbar(20_000.0, 500.0, f64::MAX, 100.0, 20.0).unwrap();
        assert!((thumb.y + thumb.height - 100.0).abs() < 1e-9);
    }

    #[test]
    fn a_track_shorter_than_the_floor_still_yields_a_thumb_inside_it() {
        let thumb = scrollbar(2_000_000.0, 500.0, 0.0, 8.0, 20.0).unwrap();
        assert!(thumb.height <= 8.0);
        assert!(thumb.height > 0.0);
    }
}
