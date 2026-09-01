//! Arrows and triangles that MEET a box rule — U+2190…U+2193 and U+25B2/25B6/25BC/25C0.
//!
//! ```text
//! ←↑→↓ ▲▶▼◀
//! ```
//!
//! ## The one family here that is not a port
//!
//! Ghostty draws no arrow and no triangle as a sprite; every one of them comes from the font, and
//! that is a reasonable choice for a terminal whose arrows appear in prose. It is the wrong choice
//! for a diagram. `───→` in a font is a rule that stops short of a floating arrowhead, because the
//! rule is drawn on the cell's centre line and the arrow is drawn on the FONT's centre line, and
//! the two are only accidentally the same. Every ASCII-art diagram, every `tree`-style graph and
//! every state machine drawn in a comment shows the seam.
//!
//! What this module draws is the arrow re-cut on the box rule's own geometry — [`light_edge`] and
//! [`Thickness::Light`], the same two numbers `box_drawing` uses — so the stem is a continuation of
//! the rule rather than a neighbour of it.
//!
//! ## Why it only fires next to a rule
//!
//! An arrow in ordinary text must keep the font's design; a reader who types `→` in a sentence is
//! asking for the typeface's arrow, not ours. So the sprite is taken only when a rule actually
//! arrives at one of this cell's edges — [`JoinMask`] empty means fall through to the shaper, and
//! the setting that turns the feature off simply never builds a non-empty mask. There is therefore
//! no state in which this module has to imitate a font's arrow, which is the trap that makes
//! "draw arrows ourselves" a bad idea in general.

#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use super::box_drawing::light_edge;
use super::canvas::{Canvas, pt};
use super::common::{Cell, CellEdge, JoinMask, Shade, Thickness, signed};

/// How much of the cell the arrowhead runs back from its point.
const HEAD_LENGTH: f64 = 0.42;
/// Half the arrowhead's span across the stem.
const HEAD_HALF_WIDTH: f64 = 0.28;
/// Half a triangle marker's span across its axis.
const TRIANGLE_HALF_WIDTH: f64 = 0.34;
/// How far a point sits inside an edge no rule arrives at.
const FREE_INSET: f64 = 0.10;

/// Whether this crate would draw `cp` itself, GIVEN a rule to join.
///
/// Distinct from every other family's `covers`: the answer here is conditional, and the caller must
/// have a non-empty [`JoinMask`] before it means anything.
pub(crate) const fn covers(cp: u32) -> bool {
    matches!(cp, 0x2190..=0x2193 | 0x25B2 | 0x25B6 | 0x25BC | 0x25C0)
}

/// Draws `cp` joined to the rules `join` names, answering whether it was one of ours.
///
/// An empty mask draws nothing and answers `false`, so the caller falls through to the font — the
/// standalone case, deliberately left alone.
pub(crate) fn draw(cp: u32, canvas: &mut Canvas, cell: Cell, join: JoinMask) -> bool {
    if join.is_empty() {
        return false;
    }
    let Some(shape) = classify(cp) else {
        return false;
    };
    let geometry = Geometry::of(cell);

    // Stubs first, so the head's ink lies over them where they meet.
    for edge in CellEdge::ALL {
        if join.has(edge) {
            geometry.stub(canvas, edge);
        }
    }

    match shape {
        Shape::Arrow(direction) => {
            geometry.stem(canvas, direction, join);
            geometry.head(canvas, direction, join, HEAD_LENGTH, HEAD_HALF_WIDTH);
        },
        Shape::Triangle(direction) => {
            geometry.head(
                canvas,
                direction,
                join,
                1.0 - 2.0 * FREE_INSET,
                TRIANGLE_HALF_WIDTH,
            );
        },
    }
    true
}

/// Which way a glyph points, and whether it has a tail.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Shape {
    /// An arrow: a head with a stem behind it.
    Arrow(CellEdge),
    /// A solid triangle marker: a head and nothing else.
    Triangle(CellEdge),
}

/// Which glyph is which.
const fn classify(cp: u32) -> Option<Shape> {
    Some(match cp {
        0x2190 => Shape::Arrow(CellEdge::Left),
        0x2191 => Shape::Arrow(CellEdge::Up),
        0x2192 => Shape::Arrow(CellEdge::Right),
        0x2193 => Shape::Arrow(CellEdge::Down),
        0x25B2 => Shape::Triangle(CellEdge::Up),
        0x25B6 => Shape::Triangle(CellEdge::Right),
        0x25BC => Shape::Triangle(CellEdge::Down),
        0x25C0 => Shape::Triangle(CellEdge::Left),
        _ => return None,
    })
}

/// The cell measured the way a box rule measures it.
#[derive(Debug, Clone, Copy)]
struct Geometry {
    width: f64,
    height: f64,
    /// The light rule's weight in pixels.
    thick: u32,
    /// The light rule's left edge, across the cell's width.
    stem_x: u32,
    /// The light rule's top edge, down the cell's height.
    stem_y: u32,
    /// The shorter cell dimension, which every proportion is taken from.
    span: f64,
}

impl Geometry {
    fn of(cell: Cell) -> Self {
        let width = f64::from(cell.width);
        let height = f64::from(cell.height);
        Self {
            width,
            height,
            thick: Thickness::Light.height(cell.thickness),
            stem_x: light_edge(cell.width, cell.thickness),
            stem_y: light_edge(cell.height, cell.thickness),
            span: f64::min(width, height),
        }
    }

    /// The rule's centre line, horizontally and vertically.
    fn center(self) -> (f64, f64) {
        let half = f64::from(self.thick) / 2.0;
        (f64::from(self.stem_x) + half, f64::from(self.stem_y) + half)
    }

    /// A light rule from the cell's centre out to `edge`, at exactly the box family's weight.
    fn stub(self, canvas: &mut Canvas, edge: CellEdge) {
        let ink = Shade::On.alpha();
        let x0 = signed(self.stem_x);
        let x1 = x0.saturating_add(signed(self.thick));
        let y0 = signed(self.stem_y);
        let y1 = y0.saturating_add(signed(self.thick));
        match edge {
            CellEdge::Up => canvas.fill_box(x0, 0, x1, y1, ink),
            CellEdge::Down => canvas.fill_box(x0, y0, x1, round(self.height), ink),
            CellEdge::Left => canvas.fill_box(0, y0, x1, y1, ink),
            CellEdge::Right => canvas.fill_box(x0, y0, round(self.width), y1, ink),
        }
    }

    /// The arrow's tail: a rule from the edge OPPOSITE the point, back to the head.
    ///
    /// It runs the full way to that edge whether or not a rule arrives there, because an arrow with
    /// no tail is a triangle. What the join decides is where the POINT lands, not whether there is
    /// a shaft behind it.
    fn stem(self, canvas: &mut Canvas, direction: CellEdge, join: JoinMask) {
        let (_, base) = self.axis(direction, join, HEAD_LENGTH);
        let ink = Shade::On.alpha();
        let x0 = signed(self.stem_x);
        let x1 = x0.saturating_add(signed(self.thick));
        let y0 = signed(self.stem_y);
        let y1 = y0.saturating_add(signed(self.thick));
        match direction {
            CellEdge::Up => canvas.fill_box(x0, round(base), x1, round(self.height), ink),
            CellEdge::Down => canvas.fill_box(x0, 0, x1, round(base), ink),
            CellEdge::Left => canvas.fill_box(round(base), y0, round(self.width), y1, ink),
            CellEdge::Right => canvas.fill_box(0, y0, round(base), y1, ink),
        }
    }

    /// Where the point sits and where its base sits, along the axis it points down.
    ///
    /// A point flush with the edge would collide with whatever is drawn in the next cell — unless
    /// that next cell is the rule the arrow is joining, in which case flush is exactly right and
    /// anything less leaves a gap. So the inset is conditional on the join, and on nothing else.
    fn axis(self, direction: CellEdge, join: JoinMask, length: f64) -> (f64, f64) {
        let inset = if join.has(direction) {
            0.0
        } else {
            self.span * FREE_INSET
        };
        let run = self.span * length;
        match direction {
            // Up and Left share an arm because both point at the cell's NEAR edge, which is zero
            // on either axis. Down and Left differ only in which dimension they measure back from.
            CellEdge::Up | CellEdge::Left => (inset, inset + run),
            CellEdge::Down => (self.height - inset, self.height - inset - run),
            CellEdge::Right => (self.width - inset, self.width - inset - run),
        }
    }

    /// The solid head — an arrowhead or a whole triangle, which differ only in their proportions.
    fn head(self, canvas: &mut Canvas, direction: CellEdge, join: JoinMask, length: f64, half_width: f64) {
        let (tip, base) = self.axis(direction, join, length);
        let spread = self.span * half_width;
        let (cx, cy) = self.center();
        let points = match direction {
            CellEdge::Up | CellEdge::Down => vec![pt(cx, tip), pt(cx + spread, base), pt(cx - spread, base)],
            CellEdge::Left | CellEdge::Right => {
                vec![pt(tip, cy), pt(base, cy + spread), pt(base, cy - spread)]
            },
        };
        canvas.fill_polygons(&[points], Shade::On.alpha());
    }
}

/// A pixel coordinate as the integer box filler wants it.
#[expect(
    clippy::cast_possible_truncation,
    reason = "clamped into the i32 range before it is narrowed"
)]
const fn round(value: f64) -> i32 {
    if value.is_nan() {
        return 0;
    }
    value.round().clamp(-2_147_483_000.0, 2_147_483_000.0) as i32
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::integer_division,
        reason = "a panic in a test is the failure report, not a runtime fault, and a test that reaches for \
                  the middle of a cell wants the whole pixel"
    )]

    use super::super::box_drawing;
    use super::{Canvas, Cell, CellEdge, JoinMask, covers, draw};

    const W: usize = 16;
    const H: usize = 32;

    fn cell() -> Cell {
        Cell {
            width: 16,
            height: 32,
            thickness: 2,
        }
    }

    fn render(cp: u32, join: JoinMask) -> Canvas {
        let mut canvas = Canvas::new(16, 32).expect("canvas");
        assert!(draw(cp, &mut canvas, cell(), join), "{cp:#06x} is ours");
        canvas
    }

    fn rule(cp: u32) -> Canvas {
        let mut canvas = Canvas::new(16, 32).expect("canvas");
        assert!(box_drawing::draw(cp, &mut canvas, cell()));
        canvas
    }

    #[test]
    fn every_covered_codepoint_draws_something_when_joined() {
        for cp in [0x2190_u32, 0x2191, 0x2192, 0x2193, 0x25B2, 0x25B6, 0x25BC, 0x25C0] {
            assert!(covers(cp), "{cp:#06x} is not claimed");
            let canvas = render(cp, JoinMask::NONE.with(CellEdge::Left));
            let inked = (0..W).any(|x| (0..H).any(|y| canvas.texel(x, y) > 0));
            assert!(inked, "{cp:#06x} drew nothing");
        }
        assert!(!covers(0x2194), "only the four cardinal arrows");
        assert!(!covers(0x25B3), "only the four solid triangles");
    }

    #[test]
    fn a_standalone_arrow_is_left_to_the_font() {
        // The rule that keeps prose alone: with nothing to join, this module declines and the
        // shaper draws the typeface's own arrow.
        let mut canvas = Canvas::new(16, 32).expect("canvas");
        assert!(!draw(0x2192, &mut canvas, cell(), JoinMask::NONE));
        assert!(
            (0..W).all(|x| (0..H).all(|y| canvas.texel(x, y) == 0)),
            "declining must also draw nothing"
        );
    }

    #[test]
    fn the_stem_lands_on_the_rules_own_rows() {
        // The whole point of the family. `→` joined on its left must ink EXACTLY the rows `─`
        // inks, or the join shows as a step.
        let arrow = render(0x2192, JoinMask::NONE.with(CellEdge::Left));
        let horizontal = rule(0x2500);
        let rows = |canvas: &Canvas| -> Vec<usize> { (0..H).filter(|&y| canvas.texel(0, y) > 0).collect() };
        assert_eq!(
            rows(&arrow),
            rows(&horizontal),
            "the stem is off the rule's centre line"
        );
        assert!(!rows(&arrow).is_empty(), "and there is a stem at all");
    }

    #[test]
    fn a_vertical_arrows_stem_lands_on_the_vertical_rules_own_columns() {
        let arrow = render(0x2193, JoinMask::NONE.with(CellEdge::Up));
        let vertical = rule(0x2502);
        let columns =
            |canvas: &Canvas| -> Vec<usize> { (0..W).filter(|&x| canvas.texel(x, 0) > 0).collect() };
        assert_eq!(columns(&arrow), columns(&vertical));
    }

    #[test]
    fn an_arrow_reaches_the_edge_the_rule_arrives_at() {
        // Joined on the left, `→` must ink column zero — a one-pixel gap there is the seam the
        // whole feature exists to remove.
        let canvas = render(0x2192, JoinMask::NONE.with(CellEdge::Left));
        assert!(
            (0..H).any(|y| canvas.texel(0, y) > 0),
            "the tail reaches the left edge"
        );
    }

    #[test]
    fn a_point_touches_the_far_edge_only_when_a_rule_is_waiting_there() {
        let free = render(0x2192, JoinMask::NONE.with(CellEdge::Left));
        let joined = render(0x2192, JoinMask::NONE.with(CellEdge::Left).with(CellEdge::Right));
        let far = |canvas: &Canvas| (0..H).any(|y| canvas.texel(W - 1, y) > 0);
        assert!(!far(&free), "an unjoined point stops short of the edge");
        assert!(far(&joined), "a joined point runs into the rule");
    }

    #[test]
    fn a_perpendicular_join_adds_a_stub_to_that_edge() {
        // `↓` sitting on a horizontal rule: it keeps its own vertical shaft AND grows the left and
        // right arms of the rule it interrupts.
        let canvas = render(0x2193, JoinMask::NONE.with(CellEdge::Left).with(CellEdge::Right));
        let middle = H / 2;
        assert!(
            (0..H).any(|y| canvas.texel(0, y) > 0),
            "a rule arrives from the left and is met"
        );
        assert!((0..H).any(|y| canvas.texel(W - 1, y) > 0), "and from the right");
        assert!(canvas.texel(W / 2, middle) > 0, "and the shaft still crosses");
    }

    #[test]
    fn a_triangle_has_no_tail_but_still_meets_its_rule() {
        let triangle = render(0x25B6, JoinMask::NONE.with(CellEdge::Left));
        let arrow = render(0x2192, JoinMask::NONE.with(CellEdge::Left));
        let count = |canvas: &Canvas| {
            (0..W)
                .flat_map(|x| (0..H).map(move |y| (x, y)))
                .filter(|&(x, y)| canvas.texel(x, y) > 0)
                .count()
        };
        assert!(
            count(&triangle) > count(&arrow),
            "a marker is heavier than an arrowhead"
        );
        assert!(
            (0..H).any(|y| triangle.texel(0, y) > 0),
            "the stub still reaches the rule"
        );
    }

    #[test]
    fn each_direction_points_the_way_it_should() {
        let far_ink = |cp: u32, edge: CellEdge| render(cp, JoinMask::NONE.with(edge));
        // `↑` joined from below: ink near the top, none in the bottom corners.
        let up = far_ink(0x2191, CellEdge::Down);
        assert!((0..W).any(|x| up.texel(x, 3) > 0), "`↑` reaches upward");
        assert_eq!(up.texel(0, H - 1), 0, "and not into the bottom-left corner");

        // `←` joined from the right: ink near the left, none in the right corners.
        let left = far_ink(0x2190, CellEdge::Right);
        assert!((0..H).any(|y| left.texel(3, y) > 0), "`←` reaches leftward");
        assert_eq!(left.texel(W - 1, 0), 0, "and not into the top-right corner");
    }

    #[test]
    fn nothing_outside_the_family_is_claimed() {
        let mut canvas = Canvas::new(16, 32).expect("canvas");
        let join = JoinMask::NONE.with(CellEdge::Left);
        assert!(!draw(0x2500, &mut canvas, cell(), join));
        assert!(!draw(0x0041, &mut canvas, cell(), join));
    }
}
