//! Block Elements — U+2580…U+259F.
//!
//! ```text
//! ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟
//! ```
//!
//! Ported from Ghostty's `src/font/sprite/draw/block.zig` (MIT).
//!
//! Every glyph here is one or two axis-aligned rectangles, which is why this is the shortest family
//! and also the one that matters most: `█` and the shade blocks are what a progress bar, a
//! sparkline and every TUI's fill are made of, drawn thousands of times a screen. Taking them from
//! the cell's own dimensions rather than a font is what makes a run of `█` a solid bar with no
//! seams and no sliver of background at the end.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use super::canvas::Canvas;
use super::common::{Cell, Frac, Shade, signed};

/// Which corner blocks a quadrant glyph paints, as a bitset.
///
/// A bitset rather than four `bool` parameters, which is both unreadable at the call site and what
/// clippy's `fn_params_excessive_bools` is for. The reference packs the same four bits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Quads(u8);

impl Quads {
    /// The top-left quarter.
    const TL: Self = Self(1);
    /// The top-right quarter.
    const TR: Self = Self(2);
    /// The bottom-left quarter.
    const BL: Self = Self(4);
    /// The bottom-right quarter.
    const BR: Self = Self(8);

    /// Both sets of corners.
    const fn and(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// Whether every corner in `other` is in this set.
    const fn has(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

/// Which edge a partial block is flush with along one axis.
///
/// No centred case, because nothing in the range is centred — every partial block in Unicode grows
/// from an edge, which is exactly what makes them stackable into bars.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Align {
    /// Flush with the near edge — left or top.
    Near,
    /// Flush with the far edge — right or bottom.
    Far,
}

/// Whether this crate draws `cp` itself rather than asking the font.
pub(crate) const fn covers(cp: u32) -> bool {
    matches!(cp, 0x2580..=0x259F)
}

/// Draws `cp` into `canvas`, answering whether it was one of ours.
pub(crate) fn draw(cp: u32, canvas: &mut Canvas, cell: Cell) -> bool {
    let ink = Shade::On;
    match cp {
        // Horizontal bars, from the top or the bottom.
        0x2580 => block(canvas, cell, Align::Near, Align::Near, 1.0, 0.5, ink),
        0x2581 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.125, ink),
        0x2582 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.25, ink),
        0x2583 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.375, ink),
        0x2584 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.5, ink),
        0x2585 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.625, ink),
        0x2586 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.75, ink),
        0x2587 => block(canvas, cell, Align::Near, Align::Far, 1.0, 0.875, ink),
        0x2588 => full(canvas, cell, Shade::On),
        // Vertical bars, from the left.
        0x2589 => block(canvas, cell, Align::Near, Align::Near, 0.875, 1.0, ink),
        0x258A => block(canvas, cell, Align::Near, Align::Near, 0.75, 1.0, ink),
        0x258B => block(canvas, cell, Align::Near, Align::Near, 0.625, 1.0, ink),
        0x258C => block(canvas, cell, Align::Near, Align::Near, 0.5, 1.0, ink),
        0x258D => block(canvas, cell, Align::Near, Align::Near, 0.375, 1.0, ink),
        0x258E => block(canvas, cell, Align::Near, Align::Near, 0.25, 1.0, ink),
        0x258F => block(canvas, cell, Align::Near, Align::Near, 0.125, 1.0, ink),

        0x2590 => block(canvas, cell, Align::Far, Align::Near, 0.5, 1.0, ink),
        0x2591 => full(canvas, cell, Shade::Light),
        0x2592 => full(canvas, cell, Shade::Medium),
        0x2593 => full(canvas, cell, Shade::Dark),
        0x2594 => block(canvas, cell, Align::Near, Align::Near, 1.0, 0.125, ink),
        0x2595 => block(canvas, cell, Align::Far, Align::Near, 0.125, 1.0, ink),
        // Quadrants.
        0x2596 => quadrants(canvas, cell, Quads::BL),
        0x2597 => quadrants(canvas, cell, Quads::BR),
        0x2598 => quadrants(canvas, cell, Quads::TL),
        0x2599 => quadrants(canvas, cell, Quads::TL.and(Quads::BL).and(Quads::BR)),
        0x259A => quadrants(canvas, cell, Quads::TL.and(Quads::BR)),
        0x259B => quadrants(canvas, cell, Quads::TL.and(Quads::TR).and(Quads::BL)),
        0x259C => quadrants(canvas, cell, Quads::TL.and(Quads::TR).and(Quads::BR)),
        0x259D => quadrants(canvas, cell, Quads::TR),
        0x259E => quadrants(canvas, cell, Quads::TR.and(Quads::BL)),
        0x259F => quadrants(canvas, cell, Quads::TR.and(Quads::BL).and(Quads::BR)),
        _ => return false,
    }
    true
}

/// A partial block, sized as a fraction of the cell and aligned within it.
fn block(
    canvas: &mut Canvas,
    cell: Cell,
    horizontal: Align,
    vertical: Align,
    width: f64,
    height: f64,
    shade: Shade,
) {
    let w = scale(cell.width, width);
    let h = scale(cell.height, height);
    let x = place(cell.width, w, horizontal);
    let y = place(cell.height, h, vertical);
    canvas.fill_box(
        signed(x),
        signed(y),
        signed(x.saturating_add(w)),
        signed(y.saturating_add(h)),
        shade.alpha(),
    );
}

/// The whole cell at one shade — `█`, `░`, `▒`, `▓`.
fn full(canvas: &mut Canvas, cell: Cell, shade: Shade) {
    canvas.fill_box(0, 0, signed(cell.width), signed(cell.height), shade.alpha());
}

/// Any combination of the four quarter-cell blocks.
///
/// Placed with [`Frac`]'s min/max asymmetry rather than by halving twice, so that `▘` and `▝` are
/// exactly the same size in a cell of odd width instead of differing by a pixel.
fn quadrants(canvas: &mut Canvas, cell: Cell, quads: Quads) {
    let ink = Shade::On.alpha();
    let (left, middle_x, right) = (
        Frac::ZERO.min(cell.width),
        (Frac::HALF.min(cell.width), Frac::HALF.max(cell.width)),
        Frac::FULL.max(cell.width),
    );
    let (top, middle_y, bottom) = (
        Frac::ZERO.min(cell.height),
        (Frac::HALF.min(cell.height), Frac::HALF.max(cell.height)),
        Frac::FULL.max(cell.height),
    );
    if quads.has(Quads::TL) {
        canvas.fill_box(left, top, middle_x.1, middle_y.1, ink);
    }
    if quads.has(Quads::TR) {
        canvas.fill_box(middle_x.0, top, right, middle_y.1, ink);
    }
    if quads.has(Quads::BL) {
        canvas.fill_box(left, middle_y.0, middle_x.1, bottom, ink);
    }
    if quads.has(Quads::BR) {
        canvas.fill_box(middle_x.0, middle_y.0, right, bottom, ink);
    }
}

/// A fraction of a dimension, rounded to whole pixels.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the product of a 0..=1 fraction and a cell dimension, rounded, cannot leave u32"
)]
fn scale(size: u32, fraction: f64) -> u32 {
    let scaled = (f64::from(size) * fraction).round();
    if !scaled.is_finite() || scaled <= 0.0 {
        return 0;
    }
    if scaled >= f64::from(size) {
        size
    } else {
        scaled as u32
    }
}

/// Where a block of `extent` pixels sits inside `size`.
const fn place(size: u32, extent: u32, align: Align) -> u32 {
    match align {
        Align::Near => 0,
        Align::Far => size.saturating_sub(extent),
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Canvas, Cell, covers, draw};

    fn cell() -> Cell {
        Cell {
            width: 8,
            height: 16,
            thickness: 2,
        }
    }

    fn render(cp: u32) -> Canvas {
        let mut canvas = Canvas::new(8, 16).expect("canvas");
        assert!(draw(cp, &mut canvas, cell()), "{cp:#06x} is ours");
        canvas
    }

    #[test]
    fn the_range_is_covered_end_to_end() {
        for cp in 0x2580..=0x259F_u32 {
            assert!(covers(cp), "{cp:#06x} has no sprite");
            let canvas = render(cp);
            let inked = (0..8).any(|x| (0..16).any(|y| canvas.texel(x, y) > 0));
            assert!(inked, "{cp:#06x} drew nothing");
        }
    }

    #[test]
    fn a_full_block_fills_every_texel() {
        // The one that has to be perfect: a run of `█` is a solid bar, and a single uninked column
        // at a cell edge shows as a hairline right through it.
        let canvas = render(0x2588);
        for x in 0..8 {
            for y in 0..16 {
                assert_eq!(canvas.texel(x, y), 0xFF, "({x}, {y}) is not solid");
            }
        }
    }

    #[test]
    fn the_shades_are_partial_ink_over_the_whole_cell() {
        let light = render(0x2591);
        let medium = render(0x2592);
        let dark = render(0x2593);
        assert!(light.texel(4, 8) < medium.texel(4, 8));
        assert!(medium.texel(4, 8) < dark.texel(4, 8));
        assert!(dark.texel(4, 8) < 0xFF);
        assert!(light.texel(0, 0) > 0, "a shade covers the whole cell");
        assert!(light.texel(7, 15) > 0);
    }

    #[test]
    fn a_lower_half_block_fills_the_bottom_and_nothing_above_it() {
        let canvas = render(0x2584);
        assert_eq!(canvas.texel(4, 7), 0, "the top half is empty");
        assert_eq!(canvas.texel(4, 8), 0xFF, "the bottom half is solid");
        assert_eq!(canvas.texel(0, 15), 0xFF, "including the far corner");
    }

    #[test]
    fn a_left_half_block_fills_the_left_and_nothing_right_of_it() {
        let canvas = render(0x258C);
        assert_eq!(canvas.texel(3, 8), 0xFF);
        assert_eq!(canvas.texel(4, 8), 0);
    }

    #[test]
    fn a_left_and_a_right_half_block_tile_into_a_full_one() {
        // The property that makes the family usable: side by side they must cover the cell exactly
        // once — no overlap, no gap. This is what `Frac`'s min/max asymmetry buys.
        let left = render(0x258C);
        let right = render(0x2590);
        for y in 0..16 {
            for x in 0..8 {
                let covered = left.texel(x, y) > 0 || right.texel(x, y) > 0;
                let doubled = left.texel(x, y) > 0 && right.texel(x, y) > 0;
                assert!(covered, "({x}, {y}) is covered by neither half");
                assert!(!doubled, "({x}, {y}) is covered by both halves");
            }
        }
    }

    #[test]
    fn the_four_quadrants_tile_the_cell_exactly() {
        let quads = [0x2598_u32, 0x259D, 0x2596, 0x2597];
        let rendered: Vec<Canvas> = quads.into_iter().map(render).collect();
        for y in 0..16 {
            for x in 0..8 {
                let hits = rendered.iter().filter(|c| c.texel(x, y) > 0).count();
                assert_eq!(hits, 1, "({x}, {y}) is covered {hits} times, not once");
            }
        }
    }

    #[test]
    fn an_eighth_block_is_an_eighth() {
        let canvas = render(0x2581);
        let rows = (0..16).filter(|&y| canvas.texel(4, y) > 0).count();
        assert_eq!(rows, 2, "one eighth of sixteen rows");
    }

    #[test]
    fn nothing_outside_the_range_is_claimed() {
        let mut canvas = Canvas::new(8, 16).expect("canvas");
        assert!(
            !draw(0x2500, &mut canvas, cell()),
            "box drawing is another family"
        );
        assert!(!draw(0x0041, &mut canvas, cell()));
    }
}
