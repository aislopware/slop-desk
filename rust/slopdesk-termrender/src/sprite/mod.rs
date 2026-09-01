//! Glyphs this crate draws itself, from the cell's own dimensions rather than from a font.
//!
//! ## What a sprite is, and why the font cannot supply one
//!
//! Box drawing, block elements, Braille and Powerline separators are not text. They are TILES: each
//! one is a picture of part of a rectangle, and the only thing that makes a row of them read as a
//! table, a bar or a prompt is that adjacent cells agree on where the ink stops. A font cannot make
//! that promise. Its `─` is drawn for its own em square, its `│` centres on its own stem axis, and
//! the two agree only by luck; its `█` is fitted to an advance that rounds independently of the
//! cell, so a run of them shows background between the blocks. Every terminal that renders these
//! from a font ships with the same three bug reports.
//!
//! Drawing them here removes the disagreement by construction. There is one source of truth for
//! where a rule's centre line is — [`common::Cell`] — and every family measures from it.
//!
//! ## The families
//!
//! | Range | Module | Origin |
//! | --- | --- | --- |
//! | U+2500…257F | [`box_drawing`] | ported from Ghostty (MIT) |
//! | U+2580…259F | [`block_elements`] | ported from Ghostty (MIT) |
//! | U+2800…28FF | [`braille`] | ported from Ghostty (MIT) |
//! | U+E0B0…E0D4 | [`powerline`] | ported from Ghostty (MIT) |
//! | U+2190…2193, U+25B2/B6/BC/C0 | [`arrow`] | ours |
//!
//! The first four are unconditional: the codepoint alone decides the picture. The fifth is not, and
//! that is the interesting one — an arrow is drawn here only when a box rule actually arrives at
//! one of its edges, so a `→` in a sentence keeps the typeface's arrow and a `───→` in a diagram
//! gets a stem that continues the rule. See [`arrow`] for why that condition is the whole design.
//!
//! ## Why this is not behind the `GlyphRasterizer` trait
//!
//! Because a sprite does not have the two things that trait's key carries — a face and a glyph id —
//! and does have two things it does not: the cell's snapped pixel size, and the join mask. Routing
//! sprites through a font-shaped door would mean inventing fake ids for them and then teaching the
//! font side to recognise the fakes. They are a different kind of thing, so they get their own key.

mod arrow;
mod block_elements;
mod box_drawing;
mod braille;
mod canvas;
mod common;
mod powerline;

use canvas::Canvas;
use common::Cell;
pub use common::{CellEdge, JoinMask};

use crate::glyph::RasterGlyph;

/// Everything that decides a sprite's pixels.
///
/// The cell's SNAPPED size and not its nominal one: a fractional cell width is ordinary — a fitted
/// font size or a 1.5× scale produces one — and a sprite rasterised at a rounded average would gap
/// or overlap its neighbour at exactly the joins this module exists to close. The caller snaps each
/// cell's span to device pixels and rasterises that span, which yields at most two distinct widths
/// across a whole grid, so keying on it costs nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SpriteKey {
    /// The codepoint being drawn.
    pub glyph: u32,
    /// The snapped cell width in device pixels.
    pub width: u16,
    /// The snapped cell height in device pixels.
    pub height: u16,
    /// The base line weight in device pixels — the underline's, which is also the box rule's.
    pub thickness: u16,
    /// Which edges a box rule arrives at. Always empty except for [`arrow`]'s family.
    pub join: JoinMask,
}

impl SpriteKey {
    /// The key for `glyph` in a cell of the given snapped size, or `None` when nothing here draws
    /// it.
    ///
    /// `join` is ignored by every family but the arrows, and an arrow with an empty mask answers
    /// `None` — that is the "leave it to the font" case, decided once, here, rather than in every
    /// caller.
    #[must_use]
    pub fn new(glyph: char, width: u16, height: u16, thickness: u16, join: JoinMask) -> Option<Self> {
        let cp = glyph as u32;
        let drawn = if arrow::covers(cp) {
            !join.is_empty()
        } else {
            covers_unconditionally(cp)
        };
        drawn.then_some(Self {
            glyph: cp,
            width,
            height,
            thickness,
            // A family that does not read the mask must not be keyed by it, or `┼` would cache
            // four times over for four identical bitmaps.
            join: if arrow::covers(cp) { join } else { JoinMask::NONE },
        })
    }
}

/// Whether `glyph` is drawn here no matter what surrounds it.
#[must_use]
pub const fn covers_unconditionally(cp: u32) -> bool {
    block_elements::covers(cp) || braille::covers(cp) || powerline::covers(cp) || box_drawing::covers(cp)
}

/// Whether `glyph` is drawn here ONLY when a box rule arrives at one of its edges.
#[must_use]
pub const fn is_joinable(glyph: char) -> bool {
    arrow::covers(glyph as u32)
}

/// Whether `neighbour`, sitting past `edge`, runs a box rule up to the shared boundary.
///
/// `edge` names the side of OUR cell, so `CellEdge::Left` asks whether the character to the left
/// has a rule running to its RIGHT. Anything that is not box drawing answers `false` — a block
/// element is not a rule, and joining an arrow to one would put a stem into the middle of a solid
/// bar.
#[must_use]
pub fn faces(neighbour: char, edge: CellEdge) -> bool {
    let Some(lines) = box_drawing::lines_of(neighbour as u32) else {
        return false;
    };
    match edge {
        CellEdge::Up => lines.down.is_drawn(),
        CellEdge::Right => lines.left.is_drawn(),
        CellEdge::Down => lines.up.is_drawn(),
        CellEdge::Left => lines.right.is_drawn(),
    }
}

/// The device-pixel span a cell covers, snapped so that neighbouring cells share an edge exactly.
///
/// This is the whole answer to fractional cell sizes. Rounding each cell's own start and end means
/// cell *n*'s snapped end and cell *n+1*'s snapped start are the same number by construction, so a
/// tiled rule has no seam and no double-inked column however the grid's arithmetic falls. Returns
/// `None` for a span too small to hold a bitmap.
#[must_use]
pub fn snap(start: f64, end: f64) -> Option<(f64, u16)> {
    let low = start.round();
    let high = end.round();
    if !low.is_finite() || !high.is_finite() {
        return None;
    }
    let extent = high - low;
    if extent < 1.0 || extent > f64::from(u16::MAX) {
        return None;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "checked into 1..=u16::MAX and integral by construction"
    )]
    let extent = extent as u16;
    Some((low, extent))
}

/// Rasterises `key`, or `None` when the cell is too small to hold a bitmap.
///
/// Every family is tried in turn and the first that claims the codepoint draws it. The order is not
/// significant — the ranges are disjoint — but box drawing goes first because it is much the most
/// common, and Powerline last because it is the only one in a private-use area.
#[must_use]
pub fn render(key: SpriteKey) -> Option<RasterGlyph> {
    let mut canvas = Canvas::new(u32::from(key.width), u32::from(key.height))?;
    let cell = Cell {
        width: canvas.width(),
        height: canvas.height(),
        // At least one pixel: a sub-pixel rule is not a rule, and every family divides by this.
        thickness: u32::from(key.thickness).max(1),
    };

    let drawn = box_drawing::draw(key.glyph, &mut canvas, cell)
        || block_elements::draw(key.glyph, &mut canvas, cell)
        || braille::draw(key.glyph, &mut canvas, cell)
        || arrow::draw(key.glyph, &mut canvas, cell, key.join)
        || powerline::draw(key.glyph, &mut canvas, cell);
    drawn.then(|| canvas.into_raster())
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CellEdge, JoinMask, SpriteKey, covers_unconditionally, faces, is_joinable, render, snap};

    fn key(glyph: char, join: JoinMask) -> Option<SpriteKey> {
        SpriteKey::new(glyph, 10, 20, 2, join)
    }

    #[test]
    fn the_four_unconditional_families_are_claimed() {
        for glyph in ['─', '┼', '╬', '█', '▒', '▘', '⠿', '⣿', '\u{E0B0}', '\u{E0B4}'] {
            assert!(
                covers_unconditionally(glyph as u32),
                "{glyph:?} should be drawn here"
            );
            assert!(key(glyph, JoinMask::NONE).is_some());
        }
    }

    #[test]
    fn ordinary_text_is_never_claimed() {
        for glyph in ['a', ' ', '0', '~', '✓', '👍'] {
            assert!(
                !covers_unconditionally(glyph as u32),
                "{glyph:?} belongs to the font"
            );
        }
        assert!(key('a', JoinMask::NONE).is_none());
        assert!(key('a', JoinMask::NONE.with(CellEdge::Left)).is_none());
    }

    #[test]
    fn an_arrow_is_claimed_only_when_something_joins_it() {
        assert!(is_joinable('→'));
        assert!(
            !covers_unconditionally('→' as u32),
            "standalone stays with the font"
        );
        assert!(key('→', JoinMask::NONE).is_none());
        assert!(key('→', JoinMask::NONE.with(CellEdge::Left)).is_some());
    }

    #[test]
    fn a_family_that_ignores_the_mask_is_not_keyed_by_it() {
        // Otherwise `┼` would occupy sixteen atlas slots for one bitmap.
        let bare = key('┼', JoinMask::NONE).expect("`┼` is ours");
        let joined = key('┼', JoinMask::NONE.with(CellEdge::Up).with(CellEdge::Left)).expect("`┼` is ours");
        assert_eq!(bare, joined);
    }

    #[test]
    fn a_neighbour_joins_only_across_the_edge_it_actually_reaches() {
        // `─` to our left has a rule running right, so it meets our left edge.
        assert!(faces('─', CellEdge::Left));
        assert!(faces('─', CellEdge::Right));
        assert!(
            !faces('─', CellEdge::Up),
            "a horizontal rule reaches no vertical edge"
        );
        // `┌` runs down and right: it meets us from the left, and from above.
        assert!(faces('┌', CellEdge::Left));
        assert!(faces('┌', CellEdge::Up));
        assert!(!faces('┌', CellEdge::Right));
        assert!(!faces('┌', CellEdge::Down));
        // Nothing else is a rule.
        assert!(!faces('█', CellEdge::Left), "a block is not a rule");
        assert!(!faces('a', CellEdge::Left));
    }

    #[test]
    fn snapping_makes_neighbouring_cells_share_an_edge_exactly() {
        // The fractional-cell-width case. At 8.4px per cell no boundary is an integer, and the only
        // thing that keeps a tiled rule seamless is that each cell's snapped END is the next one's
        // snapped START.
        let advance = 8.4;
        let mut previous_end = 0.0_f64;
        for column in 0..12 {
            let start = advance * f64::from(column);
            let end = start + advance;
            let (snapped, width) = snap(start, end).expect("a span this size has a bitmap");
            if column > 0 {
                assert!(
                    (snapped - previous_end).abs() < f64::EPSILON,
                    "column {column} starts at {snapped}, not where {previous_end} ended"
                );
            }
            previous_end = snapped + f64::from(width);
        }
    }

    #[test]
    fn snapping_yields_only_a_couple_of_widths_across_a_grid() {
        let advance = 8.4;
        let widths: std::collections::BTreeSet<u16> = (0..80)
            .filter_map(|column| {
                let start = advance * f64::from(column);
                snap(start, start + advance).map(|(_, width)| width)
            })
            .collect();
        assert!(widths.len() <= 2, "a fractional advance snapped to {widths:?}");
    }

    #[test]
    fn a_span_with_no_pixels_has_no_sprite() {
        assert!(snap(0.0, 0.4).is_none());
        assert!(snap(f64::NAN, 10.0).is_none());
        assert!(render(SpriteKey::new('─', 0, 20, 2, JoinMask::NONE).expect("`─` is ours")).is_none());
    }

    #[test]
    fn every_claimed_key_rasterises() {
        let ranges = [(0x2500_u32, 0x257F_u32), (0x2580, 0x259F), (0x2800, 0x28FF)];
        for (first, last) in ranges {
            for cp in first..=last {
                let glyph = char::from_u32(cp).expect("a valid codepoint");
                let key = SpriteKey::new(glyph, 10, 20, 2, JoinMask::NONE).expect("claimed");
                let raster = render(key).expect("a claimed key must rasterise");
                assert_eq!((raster.width, raster.height), (10, 20));
                assert_eq!(raster.pixels.len(), 200);
            }
        }
    }

    #[test]
    fn a_sprite_fills_its_cell_and_carries_no_bearing() {
        // What lets `paint` place it at the cell's own corner instead of against a baseline.
        let key = SpriteKey::new('█', 10, 20, 2, JoinMask::NONE).expect("`█` is ours");
        let raster = render(key).expect("rasterised");
        assert_eq!((raster.bearing_x, raster.bearing_y), (0.0, 0.0));
        assert!(raster.pixels.iter().all(|texel| *texel == 0xFF));
    }
}
