//! Braille Patterns — U+2800…U+28FF.
//!
//! ```text
//! ⠀⠁⠂⠃⠄⠅⠆⠇⠈⠉⠊⠋⠌⠍⠎⠏⡀⡁⡂⡃⡄⡅⡆⡇⢀⢁⣀⣤⣶⣿
//! ```
//!
//! Ported from Ghostty's `src/font/sprite/draw/braille.zig` (MIT), including the six-stage fitting
//! algorithm, which is the whole substance of the family.
//!
//! Braille is not text here. Every plotting TUI in existence — `gnuplot`'s dumb terminal, `btop`,
//! `bandwhich`, half the Rust TUI ecosystem — draws its curves as a 2×4 dot matrix per cell, which
//! makes these 256 codepoints the highest-resolution drawing surface a terminal has. A font's
//! Braille is designed to be READ by a finger, so its dots are large, round and widely spaced; used
//! as a plot they smear. Drawing them from the cell's own pixels is the difference between a
//! legible graph and a grey wash.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use super::canvas::Canvas;
use super::common::{Cell, Shade, signed};

/// Whether this crate draws `cp` itself rather than asking the font.
pub(crate) const fn covers(cp: u32) -> bool {
    matches!(cp, 0x2800..=0x28FF)
}

/// Draws `cp` into `canvas`, answering whether it was one of ours.
///
/// The codepoint's low byte IS the dot pattern — Unicode laid the block out so that bit 0 is the
/// top-left dot, bit 3 the top-right, and bits 6 and 7 the two eight-dot extensions at the bottom.
/// Nothing is decoded; the bits are read where they lie.
pub(crate) fn draw(cp: u32, canvas: &mut Canvas, cell: Cell) -> bool {
    if !covers(cp) {
        return false;
    }
    let Some(layout) = Layout::fit(cell) else {
        return true;
    };
    let pattern = cp & 0xFF;
    let ink = Shade::On.alpha();
    // Bit order, low to high: top-left, upper-left, lower-left, top-right, upper-right,
    // lower-right, bottom-left, bottom-right.
    for (bit, (column, row)) in [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        .into_iter()
        .enumerate()
    {
        if pattern & (1 << bit) == 0 {
            continue;
        }
        let (Some(&x), Some(&y)) = (layout.x.get(column), layout.y.get(row)) else {
            continue;
        };
        canvas.fill_box(
            signed(x),
            signed(y),
            signed(x.saturating_add(layout.dot)),
            signed(y.saturating_add(layout.dot)),
            ink,
        );
    }
    true
}

/// Where the eight dots land in a cell, and how big they are.
#[derive(Debug, Clone, Copy)]
struct Layout {
    /// Dot side in pixels, always at least one.
    dot: u32,
    /// The two column origins.
    x: [u32; 2],
    /// The four row origins.
    y: [u32; 4],
}

impl Layout {
    /// Fits a 2×4 dot matrix into the cell, or `None` when even one pixel per dot will not go.
    ///
    /// The six stages are the reference's, in its order, and the ORDER is the design: dot size is
    /// bought first because a zero-width dot is not a dot at all, then a margin so the pattern does
    /// not touch its neighbours, then spacing so the dots stay countable, then margin again, and
    /// only then a second pixel of dot. Spending the pixels the other way round gives fat dots in a
    /// cell they overflow.
    fn fit(cell: Cell) -> Option<Self> {
        let (width, height) = (cell.width, cell.height);
        let mut dot = quarter(width).min(eighth(height));
        let mut x_spacing = quarter(width);
        let mut y_spacing = eighth(height);
        let mut x_margin = halve(x_spacing);
        let mut y_margin = halve(y_spacing);

        let mut x_left =
            i64::from(width) - 2 * i64::from(x_margin) - i64::from(x_spacing) - 2 * i64::from(dot);
        let mut y_left =
            i64::from(height) - 2 * i64::from(y_margin) - 3 * i64::from(y_spacing) - 4 * i64::from(dot);

        // First, try hard to make the dot itself non-zero.
        if x_left >= 2 && y_left >= 4 && dot == 0 {
            dot += 1;
            x_left -= 2;
            y_left -= 4;
        }
        // Second, prefer a non-zero margin.
        if x_left >= 2 && x_margin == 0 {
            x_margin = 1;
            x_left -= 2;
        }
        if y_left >= 2 && y_margin == 0 {
            y_margin = 1;
            y_left -= 2;
        }
        // Third, spacing.
        if x_left >= 1 {
            x_spacing += 1;
            x_left -= 1;
        }
        if y_left >= 3 {
            y_spacing += 1;
            y_left -= 3;
        }
        // Fourth, margins again.
        if x_left >= 2 {
            x_margin += 1;
            x_left -= 2;
        }
        if y_left >= 2 {
            y_margin += 1;
            y_left -= 2;
        }
        // Last, a second pixel of dot.
        if x_left >= 2 && y_left >= 4 {
            dot += 1;
        }

        if dot == 0 {
            return None;
        }

        let step_x = dot.saturating_add(x_spacing);
        let step_y = dot.saturating_add(y_spacing);
        Some(Self {
            dot,
            x: [x_margin, x_margin.saturating_add(step_x)],
            y: [
                y_margin,
                y_margin.saturating_add(step_y),
                y_margin.saturating_add(step_y.saturating_mul(2)),
                y_margin.saturating_add(step_y.saturating_mul(3)),
            ],
        })
    }
}

/// A quarter of a dimension, floored — the two Braille columns.
#[expect(
    clippy::integer_division,
    reason = "a dot origin is a whole pixel; the floor IS the measurement"
)]
const fn quarter(value: u32) -> u32 {
    value / 4
}

/// An eighth of a dimension, floored — the four Braille rows.
#[expect(
    clippy::integer_division,
    reason = "a dot origin is a whole pixel; the floor IS the measurement"
)]
const fn eighth(value: u32) -> u32 {
    value / 8
}

/// Half of a dimension, floored.
#[expect(
    clippy::integer_division,
    reason = "a margin is a whole pixel; the floor IS the measurement"
)]
const fn halve(value: u32) -> u32 {
    value / 2
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Canvas, Cell, covers, draw};

    fn cell(width: u32, height: u32) -> Cell {
        Cell {
            width,
            height,
            thickness: 2,
        }
    }

    fn render(cp: u32, width: u32, height: u32) -> Canvas {
        let mut canvas = Canvas::new(width, height).expect("canvas");
        assert!(draw(cp, &mut canvas, cell(width, height)), "{cp:#06x} is ours");
        canvas
    }

    fn inked(canvas: &Canvas, width: u32, height: u32) -> usize {
        let width = usize::try_from(width).unwrap_or(0);
        let height = usize::try_from(height).unwrap_or(0);
        (0..width)
            .flat_map(|x| (0..height).map(move |y| (x, y)))
            .filter(|&(x, y)| canvas.texel(x, y) > 0)
            .count()
    }

    #[test]
    fn the_range_is_covered_end_to_end() {
        for cp in 0x2800..=0x28FF_u32 {
            assert!(covers(cp), "{cp:#06x} has no sprite");
        }
        assert!(!covers(0x27FF));
        assert!(!covers(0x2900));
    }

    #[test]
    fn the_blank_pattern_draws_nothing() {
        let canvas = render(0x2800, 10, 20);
        assert_eq!(inked(&canvas, 10, 20), 0);
    }

    #[test]
    fn every_dot_count_matches_its_popcount() {
        // The reason the family works at all: the low byte IS the pattern, so a codepoint with
        // three bits set must show exactly three dots, all the same size.
        let one = inked(&render(0x2801, 12, 24), 12, 24);
        assert!(one > 0, "a single dot leaves ink");
        for cp in 0x2800..=0x28FF_u32 {
            let bits = usize::try_from((cp & 0xFF).count_ones()).expect("a byte has few bits");
            let count = inked(&render(cp, 12, 24), 12, 24);
            assert_eq!(count, one * bits, "{cp:#06x} has {bits} bits set");
        }
    }

    #[test]
    fn the_eight_dots_land_in_two_columns_and_four_rows() {
        // `⣿`, every dot on.
        let canvas = render(0x28FF, 12, 24);
        let columns: Vec<usize> = (0..12)
            .filter(|&x| (0..24).any(|y| canvas.texel(x, y) > 0))
            .collect();
        let rows: Vec<usize> = (0..24)
            .filter(|&y| (0..12).any(|x| canvas.texel(x, y) > 0))
            .collect();
        let column_runs = runs(&columns);
        let row_runs = runs(&rows);
        assert_eq!(column_runs, 2, "two dot columns");
        assert_eq!(row_runs, 4, "four dot rows");
    }

    #[test]
    fn the_left_column_is_left_of_the_right_one() {
        let left = render(0x2801, 12, 24);
        let right = render(0x2808, 12, 24);
        let first = |canvas: &Canvas| (0..12).find(|&x| (0..24).any(|y| canvas.texel(x, y) > 0));
        assert!(first(&left) < first(&right), "bit 0 is left of bit 3");
    }

    #[test]
    fn the_pattern_fits_inside_a_cell_far_too_small_for_it() {
        // Nothing may draw outside the bitmap, and nothing may panic. A 3×5 cell cannot hold eight
        // separated dots, and the fitting algorithm has to say so rather than overflow.
        for width in 1..6_u32 {
            for height in 1..10_u32 {
                let canvas = render(0x28FF, width, height);
                let _ = inked(&canvas, width, height);
            }
        }
    }

    #[test]
    fn nothing_outside_the_range_is_claimed() {
        let mut canvas = Canvas::new(10, 20).expect("canvas");
        assert!(!draw(0x2500, &mut canvas, cell(10, 20)));
    }

    fn runs(indices: &[usize]) -> usize {
        let mut count = 0;
        let mut previous: Option<usize> = None;
        for &index in indices {
            if previous.is_none_or(|last| index != last + 1) {
                count += 1;
            }
            previous = Some(index);
        }
        count
    }
}
