//! Powerline and Powerline Extra — U+E0B0…U+E0D4.
//!
//! Ported from Ghostty's `src/font/sprite/draw/powerline.zig` (MIT). The geometric glyphs only —
//! the stylised ones in the block stay with whatever patched font supplies them, exactly as in the
//! reference.
//!
//! ## Why a private-use range is drawn at all
//!
//! Because a Powerline separator is the one glyph in a prompt that MUST bleed to the cell edge: the
//! whole illusion is that the segment's background colour flows into the next segment's, and a font
//! that leaves one pixel of side bearing puts a hairline of terminal background through the middle
//! of the prompt. That is the single most-reported cosmetic bug in every terminal that renders
//! these from a font, and it cannot be fixed in the font — it is a disagreement between the glyph's
//! ink and the cell's advance. Drawn here, the wedge starts at x=0 and ends at x=width by
//! construction.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use super::box_drawing::{diagonal_down_right, diagonal_up_right};
use super::canvas::{Canvas, Point, flatten_cubic, pt};
use super::common::{Cell, Shade, Thickness};

/// Coefficient that turns a cubic into a quarter-circle: `(√2 − 1) · 4/3`.
const CIRCLE_C: f64 = 0.552_284_749_830_793_4;

/// Whether this crate draws `cp` itself rather than asking the font.
pub(crate) const fn covers(cp: u32) -> bool {
    matches!(cp, 0xE0B0..=0xE0BF | 0xE0D2 | 0xE0D4)
}

/// Draws `cp` into `canvas`, answering whether it was one of ours.
pub(crate) fn draw(cp: u32, canvas: &mut Canvas, cell: Cell) -> bool {
    let width = f64::from(cell.width);
    let height = f64::from(cell.height);
    let ink = Shade::On.alpha();
    let thick = f64::from(Thickness::Light.height(cell.thickness));

    match cp {
        // Solid wedges.
        0xE0B0 => {
            triangle(
                canvas,
                pt(0.0, 0.0),
                pt(width, height / 2.0),
                pt(0.0, height),
                ink,
            );
        },
        0xE0B2 => {
            triangle(
                canvas,
                pt(width, 0.0),
                pt(0.0, height / 2.0),
                pt(width, height),
                ink,
            );
        },
        // Chevrons — the wedge as an outline.
        0xE0B1 => chevron(canvas, cell, thick, false),
        0xE0B3 => chevron(canvas, cell, thick, true),
        // Half-height wedges.
        0xE0B8 => triangle(canvas, pt(0.0, 0.0), pt(width, height), pt(0.0, height), ink),
        0xE0BA => triangle(canvas, pt(width, 0.0), pt(width, height), pt(0.0, height), ink),
        0xE0BC => triangle(canvas, pt(0.0, 0.0), pt(width, 0.0), pt(0.0, height), ink),
        0xE0BE => triangle(canvas, pt(0.0, 0.0), pt(width, 0.0), pt(width, height), ink),
        // Their outlines are exactly the box-drawing diagonals, which is the reference's own
        // observation and saves this module a second slope.
        0xE0B9 | 0xE0BF => diagonal_down_right(canvas, cell),
        0xE0BB | 0xE0BD => diagonal_up_right(canvas, cell),
        // Rounded caps.
        0xE0B4 => canvas.fill_polygons(&[rounded_cap(cell, 0.0)], ink),
        0xE0B6 => {
            canvas.fill_polygons(&[rounded_cap(cell, 0.0)], ink);
            canvas.flip_horizontal();
        },
        0xE0B5 => canvas.stroke(&rounded_cap(cell, thick / 2.0), thick, false, ink),
        0xE0B7 => {
            canvas.stroke(&rounded_cap(cell, thick / 2.0), thick, false, ink);
            canvas.flip_horizontal();
        },
        // The split wedge: the same shape as `E0B0` cut along its own centre line.
        0xE0D2 => split_wedge(canvas, cell, thick, ink),
        0xE0D4 => {
            split_wedge(canvas, cell, thick, ink);
            canvas.flip_horizontal();
        },
        _ => return false,
    }
    true
}

/// A filled triangle.
fn triangle(canvas: &mut Canvas, p0: Point, p1: Point, p2: Point, ink: u8) {
    canvas.fill_polygons(&[vec![p0, p1, p2]], ink);
}

/// U+E0B1 and U+E0B3, the wedge drawn as a stroke rather than a fill.
fn chevron(canvas: &mut Canvas, cell: Cell, thick: f64, mirrored: bool) {
    let width = f64::from(cell.width);
    let height = f64::from(cell.height);
    canvas.stroke(
        &[pt(0.0, 0.0), pt(width, height / 2.0), pt(0.0, height)],
        thick,
        false,
        Shade::On.alpha(),
    );
    if mirrored {
        canvas.flip_horizontal();
    }
}

/// The outline of U+E0B4 — a half-capsule open on the left — inset by `d` on every side.
///
/// The reference reaches the inset version through a path-offsetting stroke (`innerStrokePath`).
/// This parametrises the path itself instead, which is the same curve for `d = 0` and avoids a
/// general offsetter for the sake of two glyphs. Both arcs keep their true centres — `(0, radius)`
/// and `(0, height − radius)` — so the inset shrinks the radius rather than translating the curve,
/// and U+E0B5 still sits concentric inside U+E0B4.
fn rounded_cap(cell: Cell, d: f64) -> Vec<Point> {
    let width = f64::from(cell.width);
    let height = f64::from(cell.height);
    let radius = f64::min(width, height / 2.0) - d;
    if !radius.is_finite() || radius <= 0.0 {
        return Vec::new();
    }

    let start = pt(0.0, d);
    let mut path = vec![start];
    flatten_cubic(
        start,
        pt(radius * CIRCLE_C, d),
        pt(radius, d + radius - radius * CIRCLE_C),
        pt(radius, d + radius),
        &mut path,
    );
    let lower = pt(radius, height - d - radius);
    path.push(lower);
    flatten_cubic(
        lower,
        pt(radius, height - d - radius + radius * CIRCLE_C),
        pt(radius * CIRCLE_C, height - d),
        pt(0.0, height - d),
        &mut path,
    );
    path
}

/// U+E0D2, the wedge split along its own centre line by a gap one line weight wide.
fn split_wedge(canvas: &mut Canvas, cell: Cell, thick: f64, ink: u8) {
    let width = f64::from(cell.width);
    let height = f64::from(cell.height);
    let middle = height / 2.0;
    let gap = thick / 2.0;
    canvas.fill_polygons(
        &[
            vec![
                pt(0.0, 0.0),
                pt(width, 0.0),
                pt(width / 2.0, middle - gap),
                pt(0.0, middle - gap),
            ],
            vec![
                pt(0.0, height),
                pt(width, height),
                pt(width / 2.0, middle + gap),
                pt(0.0, middle + gap),
            ],
        ],
        ink,
    );
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::integer_division,
        reason = "a panic in a test is the failure report, not a runtime fault, and a test that reaches for \
                  the middle of a cell wants the whole pixel"
    )]

    use super::{Canvas, Cell, covers, draw};

    const W: usize = 12;
    const H: usize = 24;
    const WIDTH: u32 = 12;
    const HEIGHT: u32 = 24;

    fn cell() -> Cell {
        Cell {
            width: WIDTH,
            height: HEIGHT,
            thickness: 2,
        }
    }

    fn render(cp: u32) -> Canvas {
        let mut canvas = Canvas::new(WIDTH, HEIGHT).expect("canvas");
        assert!(draw(cp, &mut canvas, cell()), "{cp:#06x} is ours");
        canvas
    }

    fn any_ink(canvas: &Canvas) -> bool {
        (0..W).any(|x| (0..H).any(|y| canvas.texel(x, y) > 0))
    }

    #[test]
    fn every_covered_codepoint_draws_something() {
        for cp in 0xE0B0..=0xE0BF_u32 {
            assert!(covers(cp), "{cp:#06x} has no sprite");
            assert!(any_ink(&render(cp)), "{cp:#06x} drew nothing");
        }
        for cp in [0xE0D2_u32, 0xE0D4] {
            assert!(covers(cp));
            assert!(any_ink(&render(cp)));
        }
        assert!(!covers(0xE0AF));
        assert!(!covers(0xE0D3), "the stylised glyphs stay with the font");
    }

    #[test]
    fn a_wedge_bleeds_to_both_cell_edges() {
        // The bug this family exists to fix. `` must ink the left edge top to bottom and reach
        // the right edge at its point — a single uninked column anywhere along the left edge is
        // the hairline that shows through a Powerline prompt.
        let canvas = render(0xE0B0);
        for y in 0..H {
            assert!(canvas.texel(0, y) > 0, "the left edge is open at row {y}");
        }
        assert!(canvas.texel(W - 1, H / 2) > 0, "the point reaches the right edge");
    }

    #[test]
    fn the_mirrored_wedge_bleeds_to_the_right_edge_instead() {
        let canvas = render(0xE0B2);
        for y in 0..H {
            assert!(canvas.texel(W - 1, y) > 0, "the right edge is open at row {y}");
        }
        assert!(canvas.texel(0, H / 2) > 0);
    }

    #[test]
    fn a_chevron_is_hollow_where_the_wedge_is_solid() {
        let solid = render(0xE0B0);
        let hollow = render(0xE0B1);
        let count = |canvas: &Canvas| {
            (0..W)
                .flat_map(|x| (0..H).map(move |y| (x, y)))
                .filter(|&(x, y)| canvas.texel(x, y) > 0)
                .count()
        };
        assert!(count(&hollow) < count(&solid), "an outline is not a fill");
        assert_eq!(hollow.texel(1, H / 2), 0, "the middle is open");
    }

    #[test]
    fn a_flipped_glyph_is_its_partner_mirrored() {
        let left = render(0xE0B4);
        let right = render(0xE0B6);
        for y in 0..H {
            for x in 0..W {
                assert_eq!(
                    left.texel(x, y),
                    right.texel(W - 1 - x, y),
                    "({x}, {y}) is not the mirror of its partner"
                );
            }
        }
    }

    #[test]
    fn a_rounded_cap_is_flush_with_the_edge_it_grows_from() {
        let canvas = render(0xE0B4);
        assert!(canvas.texel(0, 0) > 0, "the cap starts at the top-left corner");
        assert!(canvas.texel(0, H - 1) > 0, "and the bottom-left one");
        assert_eq!(canvas.texel(W - 1, 0), 0, "and bulges nowhere else");
    }

    #[test]
    fn the_hollow_cap_sits_inside_the_solid_one() {
        // What the inset parametrisation buys: U+E0B5 is U+E0B4 with its interior removed, not a
        // differently-placed curve.
        let solid = render(0xE0B4);
        let hollow = render(0xE0B5);
        for y in 0..H {
            for x in 0..W {
                if hollow.texel(x, y) > 0 {
                    assert!(solid.texel(x, y) > 0, "({x}, {y}) is outside the filled cap");
                }
            }
        }
    }

    #[test]
    fn the_split_wedge_has_a_gap_along_its_centre() {
        let canvas = render(0xE0D2);
        assert_eq!(canvas.texel(1, H / 2), 0, "the split is open");
        assert!(canvas.texel(1, 1) > 0, "the top piece");
        assert!(canvas.texel(1, H - 2) > 0, "the bottom piece");
    }

    #[test]
    fn nothing_outside_the_range_is_claimed() {
        let mut canvas = Canvas::new(WIDTH, HEIGHT).expect("canvas");
        assert!(!draw(0x2500, &mut canvas, cell()));
        assert!(!draw(0xE0D0, &mut canvas, cell()));
    }
}
