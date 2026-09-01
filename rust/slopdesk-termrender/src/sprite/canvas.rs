//! The rasteriser a sprite glyph is drawn with.
//!
//! ## Why there is one at all
//!
//! Every other glyph in this crate comes from Core Text through [`crate::glyph::GlyphRasterizer`],
//! and that is the right seam for text. It is the wrong seam for a box rule, because a font's `─`
//! is designed for the font's own em square and not for THIS cell: two of them side by side leave a
//! hairline where the advance and the ink disagree, and a `┼` lands its crossing wherever the type
//! designer put it rather than on the same centre line the `│` above it used. Drawing the rules
//! from the cell's own dimensions is the only way a table closes.
//!
//! ## Why it is this small
//!
//! Roughly nineteen glyphs in twenty are axis-aligned rectangles — every line, tee, cross, half
//! line, block, quadrant and Braille dot — and [`Canvas::fill_box`] answers those in integer
//! arithmetic with no antialiasing at all, which is exactly right: a rule that lands on a pixel
//! boundary should be crisp, and a rule that does not should still be crisp, because the caller
//! already snapped the cell to device pixels. What is left — three diagonals, four arcs, the
//! Powerline wedges and the arrowheads — needs coverage, and gets it from one scanline filler.
//!
//! The filler is nonzero-winding rather than even-odd, and that choice is load-bearing: a stroked
//! path is emitted as one quad per segment plus a disc at every interior vertex, and those pieces
//! OVERLAP. Under even-odd an overlap cancels and a stroke would grow holes at its own joins.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use crate::atlas::AtlasFormat;
use crate::glyph::RasterGlyph;

/// Sub-scanlines per pixel row.
///
/// Sixteen rather than four because a Powerline wedge is a near-horizontal edge across a whole
/// cell, which is the worst case for vertical undersampling, and rather than sixty-four because
/// the x coverage inside each sub-scanline is computed EXACTLY — only the y axis is sampled, so
/// the error this number controls is already one dimension smaller than a supersampler's.
const SUBSAMPLES: u32 = 16;

/// Points on the flattened form of one cubic segment.
///
/// Fixed rather than adaptive: the curves here are quarter-circles no larger than a text cell, so
/// the adaptive test would cost more than the segments it saved.
const CUBIC_STEPS: u32 = 24;

/// Sides on the disc that rounds a stroke's interior vertex.
const DISC_SIDES: u32 = 16;

/// A point in the sprite's own pixel space — top-left origin, y downwards.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Point {
    /// Pixels right of the cell's left edge.
    pub x: f64,
    /// Pixels below the cell's top edge.
    pub y: f64,
}

/// A [`Point`], shorter at the call site — these come in dozens at a time.
pub(crate) const fn pt(x: f64, y: f64) -> Point {
    Point { x, y }
}

/// An alpha-8 bitmap exactly one cell across, drawn into and then handed to the atlas.
#[derive(Debug)]
pub(crate) struct Canvas {
    width: usize,
    height: usize,
    pixels: Vec<u8>,
}

impl Canvas {
    /// A transparent canvas of `width × height` pixels, or `None` when that is not a bitmap.
    ///
    /// A zero dimension is not an error — a one-pixel-wide cell is a legitimate consequence of a
    /// tiny font — but it has no sprite, and answering `None` lets the caller fall back to the font
    /// rather than caching an empty region under a key that will never draw.
    pub(crate) fn new(width: u32, height: u32) -> Option<Self> {
        let width = usize::try_from(width).ok()?;
        let height = usize::try_from(height).ok()?;
        if width == 0 || height == 0 {
            return None;
        }
        let len = width.checked_mul(height)?;
        Some(Self {
            width,
            height,
            pixels: vec![0; len],
        })
    }

    /// The canvas's width in pixels.
    pub(crate) const fn width(&self) -> u32 {
        as_u32(self.width)
    }

    /// The canvas's height in pixels.
    pub(crate) const fn height(&self) -> u32 {
        as_u32(self.height)
    }

    /// Fills the half-open rectangle `x0..x1 × y0..y1`, clipped to the canvas.
    ///
    /// The workhorse. No antialiasing and none wanted: a box rule's edges are integers by
    /// construction, and softening them would blur the one thing this module exists to keep sharp.
    /// Coverage is taken as a MAXIMUM rather than added, so two rules crossing stay one solid ink
    /// instead of saturating to a brighter square at the join.
    pub(crate) fn fill_box(&mut self, x0: i32, y0: i32, x1: i32, y1: i32, shade: u8) {
        let (Some(left), Some(right)) = (clamp_index(x0, self.width), clamp_index(x1, self.width)) else {
            return;
        };
        let (Some(top), Some(bottom)) = (clamp_index(y0, self.height), clamp_index(y1, self.height)) else {
            return;
        };
        if right <= left || bottom <= top {
            return;
        }
        let width = self.width;
        for row in self.pixels.chunks_exact_mut(width).skip(top).take(bottom - top) {
            for texel in row.iter_mut().skip(left).take(right - left) {
                *texel = (*texel).max(shade);
            }
        }
    }

    /// Fills every polygon in one nonzero-winding pass.
    ///
    /// One pass and not one per polygon, because the pieces of a stroked path overlap and filling
    /// them separately would blend their antialiased edges into a visible seam down the middle of
    /// every straight run. Winding them consistently and resolving them together makes an overlap
    /// interior rather than doubled — which is also why every polygon this module emits is wound
    /// the same way round, and why [`disc`] runs its angle backwards to match [`Self::stroke`]'s
    /// quads.
    ///
    /// Each polygon is implicitly closed; a non-finite point drops the edge it belongs to rather
    /// than poisoning the whole shape.
    pub(crate) fn fill_polygons(&mut self, polygons: &[Vec<Point>], shade: u8) {
        let mut edges: Vec<(Point, Point, i32)> = Vec::new();
        for polygon in polygons {
            let Some(&last) = polygon.last() else {
                continue;
            };
            let mut previous = last;
            for &current in polygon {
                if edge_crosses_rows(previous, current) {
                    let direction = if current.y > previous.y { 1 } else { -1 };
                    edges.push((previous, current, direction));
                }
                previous = current;
            }
        }
        if edges.is_empty() {
            return;
        }

        let width = self.width;
        let subsamples = f64::from(SUBSAMPLES);
        let mut coverage = vec![0.0_f64; width];
        let mut crossings: Vec<(f64, i32)> = Vec::new();

        for (y, row) in self.pixels.chunks_exact_mut(width).enumerate() {
            coverage.fill(0.0);
            for step in 0..SUBSAMPLES {
                let scan = to_f64(y) + (f64::from(step) + 0.5) / subsamples;
                crossings.clear();
                for &(p0, p1, direction) in &edges {
                    let (low, high) = if p0.y < p1.y { (p0.y, p1.y) } else { (p1.y, p0.y) };
                    if scan < low || scan >= high {
                        continue;
                    }
                    let along = (scan - p0.y) / (p1.y - p0.y);
                    crossings.push((p0.x + along * (p1.x - p0.x), direction));
                }
                crossings.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));

                let mut winding = 0_i32;
                let mut span_start = 0.0_f64;
                for &(x, direction) in &crossings {
                    if winding == 0 {
                        span_start = x;
                    }
                    winding = winding.saturating_add(direction);
                    if winding == 0 {
                        add_span(&mut coverage, span_start, x);
                    }
                }
            }
            for (texel, cell) in row.iter_mut().zip(coverage.iter()) {
                *texel = (*texel).max(alpha(*cell / subsamples, shade));
            }
        }
    }

    /// Strokes `path` at `line_width`, butt-capped at the ends and rounded at every turn.
    ///
    /// Butt caps are what let a stroked arc meet the straight rule in the next cell without a bulge
    /// past the cell edge. Round joins are a DEVIATION from the reference, which strokes with plain
    /// mitre-free segments: at a text cell's scale a flattened curve turns by a couple of degrees
    /// per vertex, so the disc is invisible, and it costs nothing to be certain no join can notch.
    pub(crate) fn stroke(&mut self, path: &[Point], line_width: f64, closed: bool, shade: u8) {
        let half = line_width / 2.0;
        if half <= 0.0 || !half.is_finite() || path.len() < 2 {
            return;
        }
        let count = path.len();
        let segments = if closed { count } else { count - 1 };

        let mut polygons: Vec<Vec<Point>> = Vec::with_capacity(segments * 2);
        for index in 0..segments {
            let (Some(&p0), Some(&p1)) = (path.get(index), path.get((index + 1) % count)) else {
                continue;
            };
            let along_x = p1.x - p0.x;
            let along_y = p1.y - p0.y;
            let length = along_x.hypot(along_y);
            if length <= 0.0 || !length.is_finite() {
                continue;
            }
            let normal_x = -along_y / length * half;
            let normal_y = along_x / length * half;
            polygons.push(vec![
                pt(p0.x + normal_x, p0.y + normal_y),
                pt(p1.x + normal_x, p1.y + normal_y),
                pt(p1.x - normal_x, p1.y - normal_y),
                pt(p0.x - normal_x, p0.y - normal_y),
            ]);
        }

        let joins = if closed {
            0..count
        } else {
            1..count.saturating_sub(1)
        };
        for index in joins {
            if let Some(&vertex) = path.get(index) {
                polygons.push(disc(vertex, half));
            }
        }

        self.fill_polygons(&polygons, shade);
    }

    /// Mirrors the bitmap left to right.
    ///
    /// Half the Powerline set is the other half reflected, and reflecting the PIXELS rather than
    /// the geometry is what keeps the two halves exactly symmetric: deriving mirrored coordinates
    /// would round each side independently and leave `` a pixel wider than ``.
    pub(crate) fn flip_horizontal(&mut self) {
        let width = self.width;
        for row in self.pixels.chunks_exact_mut(width) {
            row.reverse();
        }
    }

    /// One texel's coverage — what every sprite test in this module tree asserts on.
    #[cfg(test)]
    pub(crate) fn texel(&self, x: usize, y: usize) -> u8 {
        if x >= self.width {
            return 0;
        }
        self.pixels
            .get(y.saturating_mul(self.width).saturating_add(x))
            .copied()
            .unwrap_or_default()
    }

    /// The finished bitmap, placed by the caller rather than by a bearing.
    ///
    /// Both bearings are zero and mean it: a sprite is not positioned against a baseline like a
    /// glyph, it fills its cell, and [`crate::paint`] draws it at the cell's own snapped corner.
    pub(crate) fn into_raster(self) -> RasterGlyph {
        RasterGlyph {
            width: as_u32(self.width),
            height: as_u32(self.height),
            bearing_x: 0.0,
            bearing_y: 0.0,
            format: AtlasFormat::Alpha8,
            pixels: self.pixels,
        }
    }
}

/// Appends the flattening of one cubic to `out`, excluding `p0` and including `p3`.
pub(crate) fn flatten_cubic(p0: Point, c1: Point, c2: Point, p3: Point, out: &mut Vec<Point>) {
    for step in 1..=CUBIC_STEPS {
        let along = f64::from(step) / f64::from(CUBIC_STEPS);
        let back = 1.0 - along;
        // The Bernstein basis, spelled out. `a * b + c` stays a separate `*` and `+` throughout,
        // per `CLAUDE.md` — never `mul_add`, which rounds once where this rounds twice.
        let w0 = back * back * back;
        let w1 = 3.0 * back * back * along;
        let w2 = 3.0 * back * along * along;
        let w3 = along * along * along;
        out.push(pt(
            w0 * p0.x + w1 * c1.x + w2 * c2.x + w3 * p3.x,
            w0 * p0.y + w1 * c1.y + w2 * c2.y + w3 * p3.y,
        ));
    }
}

/// A closed disc, wound to match the quads [`Canvas::stroke`] emits.
///
/// The angle DECREASES. In a y-down space that makes the ring's signed area negative, which is the
/// sign a segment quad has whichever way the segment runs — and matching signs is the whole reason
/// a stroke can overlap itself without punching a hole.
fn disc(center: Point, radius: f64) -> Vec<Point> {
    (0..DISC_SIDES)
        .map(|step| {
            let angle = -core::f64::consts::TAU * f64::from(step) / f64::from(DISC_SIDES);
            pt(center.x + radius * angle.cos(), center.y + radius * angle.sin())
        })
        .collect()
}

/// Whether an edge spans any scanline at all — a horizontal edge contributes no crossing.
///
/// Exact inequality, and it has to be: the test is "does this edge cross a scanline", and an edge
/// whose endpoints differ by a millionth of a pixel crosses one that falls between them. Widening
/// this to an epsilon would silently drop the near-horizontal edges a Powerline wedge is made of.
#[expect(
    clippy::float_cmp,
    reason = "the question is whether the edge is exactly horizontal, not whether it is nearly so"
)]
fn edge_crosses_rows(p0: Point, p1: Point) -> bool {
    p0.x.is_finite() && p0.y.is_finite() && p1.x.is_finite() && p1.y.is_finite() && p0.y != p1.y
}

/// Adds one filled span's exact x coverage to a row accumulator.
fn add_span(coverage: &mut [f64], x0: f64, x1: f64) {
    let width = to_f64(coverage.len());
    let start = f64::max(x0, 0.0);
    let end = f64::min(x1, width);
    if !start.is_finite() || !end.is_finite() || end <= start {
        return;
    }
    let Some(first) = floor_index(start) else {
        return;
    };
    let last = ceil_index(end).unwrap_or(coverage.len()).min(coverage.len());
    for (index, cell) in coverage
        .iter_mut()
        .enumerate()
        .skip(first)
        .take(last.saturating_sub(first))
    {
        let left = f64::max(start, to_f64(index));
        let right = f64::min(end, to_f64(index) + 1.0);
        if right > left {
            *cell += right - left;
        }
    }
}

/// A coverage fraction as an alpha, scaled by the shade the caller asked for.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the product is clamped to 0..=255 before it is narrowed"
)]
fn alpha(coverage: f64, shade: u8) -> u8 {
    if !coverage.is_finite() {
        return 0;
    }
    let clamped = coverage.clamp(0.0, 1.0);
    (clamped * f64::from(shade)).round() as u8
}

/// A signed pixel coordinate clamped into `0..=limit`, or `None` when `limit` will not fit an
/// `i32`.
fn clamp_index(value: i32, limit: usize) -> Option<usize> {
    let limit = i32::try_from(limit).ok()?;
    usize::try_from(value.clamp(0, limit)).ok()
}

/// The pixel a coordinate falls in, or `None` when it is not one.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the value is checked non-negative and a sprite is a few hundred pixels across"
)]
fn floor_index(value: f64) -> Option<usize> {
    let floored = value.floor();
    (0.0..1.0e9).contains(&floored).then_some(floored as usize)
}

/// One past the pixel a coordinate ends in, or `None` when it is not one.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the value is checked non-negative and a sprite is a few hundred pixels across"
)]
fn ceil_index(value: f64) -> Option<usize> {
    let ceiled = value.ceil();
    (0.0..1.0e9).contains(&ceiled).then_some(ceiled as usize)
}

/// A count as a float, for the scanline arithmetic.
#[expect(
    clippy::cast_precision_loss,
    reason = "a sprite is a few hundred pixels across, exactly representable"
)]
const fn to_f64(value: usize) -> f64 {
    value as f64
}

/// A dimension back as a `u32`, saturating rather than wrapping.
#[expect(
    clippy::cast_possible_truncation,
    reason = "saturated to u32::MAX first, which no cell dimension can reach"
)]
const fn as_u32(value: usize) -> u32 {
    if value > u32::MAX as usize {
        u32::MAX
    } else {
        value as u32
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{Canvas, pt};

    fn coverage(canvas: &Canvas, x: usize, y: usize) -> u8 {
        canvas.texel(x, y)
    }

    #[test]
    fn a_zero_dimension_has_no_canvas() {
        assert!(Canvas::new(0, 10).is_none());
        assert!(Canvas::new(10, 0).is_none());
    }

    #[test]
    fn a_box_is_exact_and_clipped() {
        let mut canvas = Canvas::new(4, 4).expect("canvas");
        canvas.fill_box(-2, 1, 2, 3, 0xFF);
        assert_eq!(coverage(&canvas, 0, 0), 0, "the box starts on row 1");
        assert_eq!(coverage(&canvas, 0, 1), 0xFF);
        assert_eq!(coverage(&canvas, 1, 2), 0xFF);
        assert_eq!(coverage(&canvas, 2, 2), 0, "the box is half-open at x1");
        assert_eq!(coverage(&canvas, 0, 3), 0, "the box is half-open at y1");
    }

    #[test]
    fn overlapping_boxes_take_the_darker_shade_rather_than_adding() {
        let mut canvas = Canvas::new(4, 4).expect("canvas");
        canvas.fill_box(0, 0, 4, 4, 0x80);
        canvas.fill_box(0, 0, 4, 4, 0x40);
        assert_eq!(
            coverage(&canvas, 2, 2),
            0x80,
            "a lighter shade must not lighten ink"
        );
        canvas.fill_box(0, 0, 4, 4, 0xC0);
        assert_eq!(coverage(&canvas, 2, 2), 0xC0);
    }

    #[test]
    fn a_pixel_aligned_polygon_is_solid_with_no_soft_edge() {
        let mut canvas = Canvas::new(4, 4).expect("canvas");
        canvas.fill_polygons(
            &[vec![pt(1.0, 1.0), pt(3.0, 1.0), pt(3.0, 3.0), pt(1.0, 3.0)]],
            0xFF,
        );
        assert_eq!(coverage(&canvas, 1, 1), 0xFF);
        assert_eq!(coverage(&canvas, 2, 2), 0xFF);
        assert_eq!(coverage(&canvas, 0, 1), 0, "nothing outside the polygon");
        assert_eq!(coverage(&canvas, 3, 3), 0);
    }

    #[test]
    fn a_half_covered_pixel_is_half_ink() {
        let mut canvas = Canvas::new(2, 1).expect("canvas");
        canvas.fill_polygons(
            &[vec![pt(0.0, 0.0), pt(0.5, 0.0), pt(0.5, 1.0), pt(0.0, 1.0)]],
            0xFF,
        );
        let half = coverage(&canvas, 0, 0);
        assert!((0x7C..=0x82).contains(&half), "half coverage read as {half:#04x}");
    }

    #[test]
    fn a_self_overlapping_stroke_has_no_hole_at_its_join() {
        // A path that doubles back on itself: under even-odd winding the overlap would cancel and
        // the corner would be transparent. This is the reason the filler is nonzero.
        let mut canvas = Canvas::new(12, 12).expect("canvas");
        canvas.stroke(&[pt(2.0, 6.0), pt(9.0, 6.0), pt(2.0, 6.0)], 4.0, false, 0xFF);
        assert_eq!(coverage(&canvas, 5, 6), 0xFF, "the doubled run must stay solid");
    }

    #[test]
    fn a_stroked_corner_is_filled_through_the_turn() {
        let mut canvas = Canvas::new(16, 16).expect("canvas");
        canvas.stroke(&[pt(8.0, 1.0), pt(8.0, 8.0), pt(15.0, 8.0)], 3.0, false, 0xFF);
        assert_eq!(coverage(&canvas, 8, 8), 0xFF, "the vertex itself is inked");
        assert_eq!(coverage(&canvas, 8, 3), 0xFF, "the upright arm");
        assert_eq!(coverage(&canvas, 12, 8), 0xFF, "the horizontal arm");
        assert_eq!(coverage(&canvas, 2, 2), 0, "and nothing in the far corner");
    }

    #[test]
    fn a_flip_mirrors_the_bitmap() {
        let mut canvas = Canvas::new(4, 1).expect("canvas");
        canvas.fill_box(0, 0, 1, 1, 0xFF);
        canvas.flip_horizontal();
        assert_eq!(coverage(&canvas, 0, 0), 0);
        assert_eq!(coverage(&canvas, 3, 0), 0xFF);
    }

    #[test]
    fn a_raster_carries_no_bearing() {
        let canvas = Canvas::new(3, 5).expect("canvas");
        let raster = canvas.into_raster();
        assert_eq!((raster.width, raster.height), (3, 5));
        assert_eq!((raster.bearing_x, raster.bearing_y), (0.0, 0.0));
        assert_eq!(raster.pixels.len(), 15);
    }
}
