//! WHERE the five drop zones are, so that what is drawn and what is hit are the same shape.
//!
//! [`drop_action`](crate::drop_action) says what each zone MEANS. This says where it is: a central
//! column of three circles over the pane, plus a large ellipse hugging each side edge and spilling
//! off it, so the visible half is what the user aims at.
//!
//! ## One shape, drawn and hit-tested
//!
//! The overlay draws these and the drop receiver hit-tests against them, which is the whole reason
//! the layout is a value rather than two pieces of view code: a `.contentShape`-after-`.position`
//! mistake would move the hit region off the blob without moving the blob, and a drop would land in
//! a zone the user was not pointing at. Draw and hit cannot drift when they read one function.
//!
//! ## Proportions, never points
//!
//! Every number here is a fraction of the pane box, so the layout is the same on a sidebar-sized
//! pane and a full-screen one, and the same on macOS and iOS. The three circles are scaled to the
//! SMALLER dimension so they stay round in a pane of any aspect; the two edge ellipses are scaled
//! per axis, because they are meant to be wide and to run off the edge.
//!
//! ## Overlap resolves by DEPTH
//!
//! The zones can overlap on a narrow pane. The winner is the one the point is most deeply inside —
//! the smallest normalised distance — which is deterministic and makes a zone's own centre
//! (distance `0`) always resolve to that zone. So the middle of a drawn blob always hits it.

use crate::drop_action::DropZone;
use crate::geometry::{Point, Size};

/// The draw and hit order: the central column top-to-bottom, then the two edges.
pub const ZONES: [DropZone; 5] = [
    DropZone::NewTab,
    DropZone::InsertPath,
    DropZone::OpenInPlace,
    DropZone::SplitLeft,
    DropZone::SplitRight,
];

/// Where each central circle sits down the pane, as a fraction of its height.
const NEW_TAB_Y: f64 = 0.18;
/// The middle circle.
const INSERT_PATH_Y: f64 = 0.46;
/// The lower circle.
const OPEN_IN_PLACE_Y: f64 = 0.72;

/// The top circle's radius, as a fraction of the pane's smaller dimension. Slightly tighter than
/// the other two: it is nearest the pane's top edge, where the tab strip already lives.
const NEW_TAB_RADIUS: f64 = 0.15;
/// The other two circles' radius, on the same scale.
const CENTRE_RADIUS: f64 = 0.16;

/// The edge ellipses' horizontal radius, as a fraction of the pane's WIDTH — half of it spills off
/// the edge the ellipse is centred on, which is what makes the target reachable by overshooting.
const EDGE_RADIUS_X: f64 = 0.26;
/// Their vertical radius, as a fraction of the pane's height.
const EDGE_RADIUS_Y: f64 = 0.30;

/// One zone's drawn shape, as an axis-aligned ellipse in pane-local coordinates. A circle is simply
/// `radius_x == radius_y`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ZoneShape {
    /// The ellipse's centre, which may sit ON or past an edge of the pane.
    pub center: Point,
    /// Half-extent along x.
    pub radius_x: f64,
    /// Half-extent along y.
    pub radius_y: f64,
}

impl ZoneShape {
    /// How far `point` is from the centre, in units of the ellipse's own radii: `0` at the centre,
    /// `1` exactly on the boundary, `> 1` outside.
    ///
    /// One number for circles and ellipses alike, and a containment DEPTH rather than a yes/no, so
    /// overlapping zones can be resolved without a tie-break table. A degenerate (zero) radius
    /// makes this non-finite, which fails every `<= 1` test — a zone with no size can never be
    /// hit.
    ///
    /// The two squares are separate multiplies and a separate add. Never fused: the wire and the
    /// golden vectors round twice, and an `mul_add` here would round once.
    #[must_use]
    pub fn normalized_distance(&self, point: Point) -> f64 {
        let dx = (point.x - self.center.x) / self.radius_x;
        let dy = (point.y - self.center.y) / self.radius_y;
        (dx * dx + dy * dy).sqrt()
    }

    /// Whether `point` lies within, or exactly on, this zone's ellipse.
    #[must_use]
    pub fn contains(&self, point: Point) -> bool {
        self.normalized_distance(point) <= 1.0
    }
}

/// The drawn shape of one zone over a pane of `size`, in pane-local coordinates.
#[must_use]
pub fn shape(zone: DropZone, size: Size) -> ZoneShape {
    let (width, height) = (size.width, size.height);
    // The round-circle scale base: the smaller dimension, so a circle stays a circle in a pane of
    // any aspect. `min` rather than a `<` ternary, per the float convention.
    let round = width.min(height);
    let center_x = width / 2.0;
    let circle = |y_fraction: f64, radius_fraction: f64| {
        ZoneShape {
            center: Point::new(center_x, height * y_fraction),
            radius_x: round * radius_fraction,
            radius_y: round * radius_fraction,
        }
    };
    let edge = |x: f64| {
        ZoneShape {
            center: Point::new(x, height / 2.0),
            radius_x: width * EDGE_RADIUS_X,
            radius_y: height * EDGE_RADIUS_Y,
        }
    };
    match zone {
        DropZone::NewTab => circle(NEW_TAB_Y, NEW_TAB_RADIUS),
        DropZone::InsertPath => circle(INSERT_PATH_Y, CENTRE_RADIUS),
        DropZone::OpenInPlace => circle(OPEN_IN_PLACE_Y, CENTRE_RADIUS),
        DropZone::SplitLeft => edge(0.0),
        DropZone::SplitRight => edge(width),
    }
}

/// The zone under `point` over a pane of `size`, or `None` when it lands in a gap.
///
/// Where zones overlap the DEEPEST containment wins — see the module header.
#[must_use]
pub fn zone_at(point: Point, size: Size) -> Option<DropZone> {
    let mut best: Option<(DropZone, f64)> = None;
    for zone in ZONES {
        let depth = shape(zone, size).normalized_distance(point);
        // Asked as "is it inside", never as "is it outside": a degenerate pane makes this NaN, and
        // NaN is not inside anything. A negated `>` would let it through and hit the last zone.
        let inside = depth <= 1.0;
        if !inside {
            continue;
        }
        match best {
            Some((_, current)) if current <= depth => {},
            _ => best = Some((zone, depth)),
        }
    }
    best.map(|(zone, _)| zone)
}

#[cfg(test)]
#[expect(
    clippy::float_cmp,
    reason = "the proportions are exact, and an off-by-a-pixel blob IS the bug this pins"
)]
mod tests {
    use super::{ZONES, shape, zone_at};
    use crate::drop_action::DropZone;
    use crate::geometry::{Point, Size};

    const PANE: Size = Size::new(800.0, 600.0);

    #[test]
    fn the_central_column_shares_the_panes_centre_line_and_stays_round() {
        for zone in [DropZone::NewTab, DropZone::InsertPath, DropZone::OpenInPlace] {
            let drawn = shape(zone, PANE);
            assert_eq!(drawn.center.x, 400.0, "the column is on the centre line");
            assert_eq!(
                drawn.radius_x, drawn.radius_y,
                "a circle, in a pane of any aspect"
            );
            assert!(drawn.radius_x <= 600.0 * 0.16, "scaled to the SMALLER dimension");
        }
        // Top to bottom, in the order they are drawn.
        assert!(shape(DropZone::NewTab, PANE).center.y < shape(DropZone::InsertPath, PANE).center.y);
        assert!(shape(DropZone::InsertPath, PANE).center.y < shape(DropZone::OpenInPlace, PANE).center.y);
    }

    #[test]
    fn the_edge_ellipses_are_centred_on_the_edges_and_spill_off_them() {
        let left = shape(DropZone::SplitLeft, PANE);
        let right = shape(DropZone::SplitRight, PANE);
        assert_eq!(left.center.x, 0.0);
        assert_eq!(right.center.x, 800.0);
        assert_eq!(left.center.y, 300.0);
        assert_eq!(left.center.y, right.center.y);
        // Half of each is off-screen: overshooting the edge still lands on the target.
        assert!(left.radius_x > 0.0 && right.radius_x > 0.0);
        assert!(left.radius_x != left.radius_y, "wide on purpose, not a circle");
    }

    #[test]
    fn a_zones_own_centre_always_resolves_to_that_zone() {
        // Draw-centre == hit-centre, whatever else overlaps it.
        for zone in ZONES {
            assert_eq!(zone_at(shape(zone, PANE).center, PANE), Some(zone));
        }
    }

    #[test]
    fn a_point_in_a_gap_is_not_a_zone() {
        // The very top corner: above the first circle, past the edge ellipses' reach.
        assert_eq!(zone_at(Point::new(400.0, 0.0), PANE), None);
    }

    #[test]
    fn the_boundary_is_inside_and_a_step_past_it_is_not() {
        let circle = shape(DropZone::InsertPath, PANE);
        let on = Point::new(circle.center.x + circle.radius_x, circle.center.y);
        assert!(circle.contains(on), "exactly on the boundary is a hit");
        assert_eq!(circle.normalized_distance(on), 1.0);
        let past = Point::new(circle.center.x + circle.radius_x * 1.01, circle.center.y);
        assert!(!circle.contains(past));
    }

    #[test]
    fn a_pane_with_no_size_can_never_be_hit() {
        // Every radius is zero, so every normalised distance is NaN or infinite — and neither is
        // `<= 1`. A drop over a pane that has not been laid out yet does nothing.
        let nothing = Size::new(0.0, 0.0);
        assert_eq!(zone_at(Point::new(0.0, 0.0), nothing), None);
        assert_eq!(zone_at(Point::new(10.0, 10.0), nothing), None);
    }

    #[test]
    fn an_overlap_resolves_to_the_deeper_containment() {
        // A pane short enough that the first two circles — scaled to the HEIGHT — run into each
        // other. The edge ellipses never can: their radius and the centre line are both fractions
        // of the width, and 0.26 never reaches 0.5.
        let squat = Size::new(1600.0, 400.0);
        let top = shape(DropZone::NewTab, squat);
        let middle = shape(DropZone::InsertPath, squat);
        let seam = Point::new(800.0, 126.0);
        assert!(top.contains(seam) && middle.contains(seam), "the seam is in both");
        // Either side of the seam the answer follows the deeper containment, not the draw order.
        assert_eq!(zone_at(Point::new(800.0, 122.0), squat), Some(DropZone::NewTab));
        assert_eq!(
            zone_at(Point::new(800.0, 130.0), squat),
            Some(DropZone::InsertPath)
        );
    }
}
