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

use slopdesk_tree::geometry::{Point, Size};

use crate::drop_action::{DropZone, ZONES};

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
    fn normalized_distance(&self, point: Point) -> f64 {
        let dx = (point.x - self.center.x) / self.radius_x;
        let dy = (point.y - self.center.y) / self.radius_y;
        (dx * dx + dy * dy).sqrt()
    }

    /// Whether `point` lies within, or exactly on, this zone's ellipse.
    ///
    /// `cfg(test)` because production never asks the yes/no question: [`zone_at`] needs the depth
    /// to resolve an overlap, so it keeps the distance it already computed and spells the same
    /// `<= 1.0` inline rather than paying for it twice. This is the assertion form of that one
    /// comparison, and it exists so the boundary tests can read.
    #[cfg(test)]
    #[must_use]
    fn contains(&self, point: Point) -> bool {
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

/// Which rung of the one ink ladder a blob's wash is drawn from.
///
/// Named, never coloured: this crate holds no design tokens, and each renderer resolves the rung
/// through its own view of the ladder (`Slate.Status.ok` / `Slate.State.accent` in `SwiftUI`,
/// `Slate.Native.*` in `AppKit`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Ink {
    /// The status-OK rung (green): the hovered zone, and the terminal half at rest.
    Ok = 0,
    /// The accent rung: the pane half at rest.
    Accent = 1,
    /// The muted-accent rung: a zone the dragged content cannot act on — a barely-there neutral,
    /// not a faded accent, so a disabled blob never reads as merely "further away".
    AccentMuted = 2,
}

impl Ink {
    /// This rung in the byte the boundary carries.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Which rung a zone's LABEL is drawn in — the reading ladder, not the status one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum LabelInk {
    /// The hovered zone: full-strength reading ink.
    Primary = 0,
    /// An allowed but un-hovered zone.
    Secondary = 1,
    /// A zone the content cannot act on — faded, matching its muted blob.
    Tertiary = 2,
}

impl LabelInk {
    /// This rung in the byte the boundary carries.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// The alpha the active zone's ring is stroked at. The ring is what says "release now", and two
/// halves that ringed a hover differently would be two different affordances.
pub const ACTIVE_STROKE_OPACITY: f64 = 0.7;

/// The hovered blob's wash: bright enough to read as the target, not so bright it hides the label.
const ACTIVE_WASH: f64 = 0.5;
/// A resting terminal-half blob's wash.
const TERMINAL_WASH: f64 = 0.14;
/// A resting pane-half blob's wash, a shade fainter — the accent rung already reads stronger.
const PANE_WASH: f64 = 0.10;
/// The muted rung is the faint one already, so it is laid down undiluted.
const MUTED_WASH: f64 = 1.0;

/// WHERE one blob and its word are drawn, over a pane of a given size.
///
/// A pair rather than two calls, because the label's place is read off the same ellipse the blob's
/// size is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Marks {
    /// The blob's drawn size, clamped away from negative dimensions: a pane mid-layout answers with
    /// a degenerate box, and neither framework may be handed a negative width.
    pub blob: Size,
    /// Where the zone's label sits in pane-local coordinates.
    pub label_center: Point,
}

/// HOW one blob and its word are inked, for one `(zone, active, allowed)`.
///
/// One value rather than three calls: the wash, the ring and the label's rung all turn on the same
/// two booleans, and a renderer that asked for them separately would be free to ask with a stale
/// pair — a lit blob under a faded word. Nothing here is a colour; see [`Ink`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Wash {
    /// The blob's wash rung.
    pub ink: Ink,
    /// The alpha that rung is laid down at.
    pub opacity: f64,
    /// The alpha the ring is stroked at — `0` when this zone is not the hovered one, so the ring is
    /// one number rather than a branch each renderer writes out.
    pub stroke_opacity: f64,
    /// The label's rung.
    pub label_ink: LabelInk,
}

/// Whether `zone` belongs to the "green / terminal half".
///
/// Those are the two zones that act on the TERMINAL (a new rooted tab, an inject into the live PTY)
/// rather than on the PANE TREE, and so tint green even at rest. The split is the user's whole
/// mental model of the overlay.
#[must_use]
pub const fn is_terminal_half(zone: DropZone) -> bool {
    matches!(zone, DropZone::NewTab | DropZone::InsertPath)
}

/// The label under a zone's blob. Title Case, and "Open In-Place" keeps its capital I and its
/// hyphen — it names the verb the ⌘-click menu already spells that way.
#[must_use]
pub const fn label(zone: DropZone) -> &'static str {
    match zone {
        DropZone::NewTab => "New Tab",
        DropZone::InsertPath => "Insert Path",
        DropZone::OpenInPlace => "Open In-Place",
        DropZone::SplitLeft => "Split Left",
        DropZone::SplitRight => "Split Right",
    }
}

/// Where a zone's label sits in pane-local coordinates: at the blob centre for the three central
/// circles, and inset from the edge for the two side ellipses — whose true centre is ON the pane
/// edge (half the blob is clipped away), so a centred label would be half off-pane. Half the
/// x-radius in from the edge lands it inside the visible half of the ellipse.
///
/// EVERY ZONE IS SPELLED AND THERE IS NO WILDCARD ARM. The three central circles share one arm
/// because they share one ANSWER — an unclipped blob wants its label at its own centre — not
/// because the arm is a place to put the cases nobody has thought about yet: a `_` here would hand
/// a sixth zone the centred label silently, and "centred" is correct only for a blob the pane box
/// does not cut in half.
#[must_use]
fn label_center(zone: DropZone, drawn: ZoneShape, size: Size) -> Point {
    match zone {
        DropZone::NewTab | DropZone::InsertPath | DropZone::OpenInPlace => drawn.center,
        DropZone::SplitLeft => Point::new(drawn.radius_x * 0.5, drawn.center.y),
        DropZone::SplitRight => Point::new(size.width - drawn.radius_x * 0.5, drawn.center.y),
    }
}

/// The blob's wash: the hovered zone glows status-green at half strength; an allowed zone sits as a
/// faint wash (green for the terminal half, accent for the pane half); a disabled zone is a
/// barely-there neutral.
#[must_use]
const fn rung(zone: DropZone, active: bool, allowed: bool) -> (Ink, f64) {
    if active {
        return (Ink::Ok, ACTIVE_WASH);
    }
    if !allowed {
        return (Ink::AccentMuted, MUTED_WASH);
    }
    if is_terminal_half(zone) {
        (Ink::Ok, TERMINAL_WASH)
    } else {
        (Ink::Accent, PANE_WASH)
    }
}

/// The label's rung: bright on the active zone, secondary on an allowed one, tertiary (faded) on a
/// disabled one — so the text tracks its blob rather than announcing a target that is inert.
#[must_use]
const fn label_ink(active: bool, allowed: bool) -> LabelInk {
    if active {
        LabelInk::Primary
    } else if allowed {
        LabelInk::Secondary
    } else {
        LabelInk::Tertiary
    }
}

/// Where `zone`'s blob and word are drawn over a pane of `size`.
///
/// The shape is [`shape`]'s, recomputed here rather than passed in, so the size a renderer draws
/// and the ellipse the receiver hit-tests are the same function's — see the module header.
#[must_use]
pub fn marks(zone: DropZone, size: Size) -> Marks {
    let drawn = shape(zone, size);
    Marks {
        // `max` rather than a `<` ternary, per the float convention. A pane that has not been laid
        // out yet answers proportionally, and a negative dimension makes SwiftUI log and `AppKit`
        // draw garbage.
        blob: Size::new((drawn.radius_x * 2.0).max(0.0), (drawn.radius_y * 2.0).max(0.0)),
        label_center: label_center(zone, drawn, size),
    }
}

/// How `zone`'s blob and word are inked while `active` / `allowed`.
#[must_use]
pub const fn wash(zone: DropZone, active: bool, allowed: bool) -> Wash {
    let (ink, opacity) = rung(zone, active, allowed);
    Wash {
        ink,
        opacity,
        stroke_opacity: if active { ACTIVE_STROKE_OPACITY } else { 0.0 },
        label_ink: label_ink(active, allowed),
    }
}

#[cfg(test)]
#[expect(
    clippy::float_cmp,
    reason = "the proportions are exact, and an off-by-a-pixel blob IS the bug this pins"
)]
mod tests {
    use slopdesk_tree::geometry::{Point, Size};

    use super::{
        ACTIVE_STROKE_OPACITY, Ink, LabelInk, ZONES, is_terminal_half, label, marks, shape, wash, zone_at,
    };
    use crate::drop_action::DropZone;

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

    #[test]
    fn the_terminal_half_is_the_two_zones_that_act_on_the_terminal() {
        assert!(is_terminal_half(DropZone::NewTab));
        assert!(is_terminal_half(DropZone::InsertPath));
        for zone in [DropZone::OpenInPlace, DropZone::SplitLeft, DropZone::SplitRight] {
            assert!(!is_terminal_half(zone), "{zone:?} acts on the PANE TREE");
        }
    }

    /// The five words verbatim. "Open In-Place" keeps its capital I and its hyphen because it names
    /// the verb the `⌘`-click menu already spells that way, and that spelling is exactly what a
    /// second renderer re-types slightly differently — a drift no other gate can see.
    #[test]
    fn the_five_words_are_pinned_letter_for_letter() {
        assert_eq!(label(DropZone::NewTab), "New Tab");
        assert_eq!(label(DropZone::InsertPath), "Insert Path");
        assert_eq!(label(DropZone::OpenInPlace), "Open In-Place");
        assert_eq!(label(DropZone::SplitLeft), "Split Left");
        assert_eq!(label(DropZone::SplitRight), "Split Right");
    }

    #[test]
    fn every_zone_is_labelled_and_no_two_share_a_word() {
        let mut labels: Vec<&str> = ZONES.iter().map(|zone| label(*zone)).collect();
        assert!(!labels.iter().any(|word| word.is_empty()));
        labels.sort_unstable();
        labels.dedup();
        assert_eq!(
            labels.len(),
            ZONES.len(),
            "two blobs that read alike are one target twice"
        );
    }

    #[test]
    fn the_edge_labels_sit_inside_the_visible_half_and_the_others_at_their_centre() {
        for zone in [DropZone::NewTab, DropZone::InsertPath, DropZone::OpenInPlace] {
            let drawn = shape(zone, PANE);
            assert_eq!(marks(zone, PANE).label_center, drawn.center);
        }
        // The edge ellipses are centred ON the edge, so a centred label would be half off-pane.
        let left = marks(DropZone::SplitLeft, PANE).label_center;
        let right = marks(DropZone::SplitRight, PANE).label_center;
        assert!(left.x > 0.0 && left.x < PANE.width);
        assert!(right.x > 0.0 && right.x < PANE.width);
        assert_eq!(left.y, right.y);
    }

    #[test]
    fn a_pane_mid_layout_never_hands_a_renderer_a_negative_blob() {
        let degenerate = Size::new(-40.0, -10.0);
        for zone in ZONES {
            let drawn = marks(zone, degenerate);
            assert!(drawn.blob.width >= 0.0, "{zone:?} width");
            assert!(drawn.blob.height >= 0.0, "{zone:?} height");
        }
    }

    #[test]
    fn the_hovered_zone_glows_and_rings_and_nothing_else_rings() {
        let hovered = wash(DropZone::SplitRight, true, true);
        assert_eq!(
            hovered.ink,
            Ink::Ok,
            "the hover is status-green whichever half it is in"
        );
        assert_eq!(hovered.stroke_opacity, ACTIVE_STROKE_OPACITY);
        assert_eq!(hovered.label_ink, LabelInk::Primary);
        for zone in ZONES {
            assert_eq!(wash(zone, false, true).stroke_opacity, 0.0);
            assert_eq!(wash(zone, false, false).stroke_opacity, 0.0);
        }
    }

    #[test]
    fn a_zone_the_content_cannot_act_on_is_neutral_rather_than_a_faded_accent() {
        for zone in ZONES {
            let barred = wash(zone, false, false);
            assert_eq!(
                barred.ink,
                Ink::AccentMuted,
                "{zone:?} must not read as merely further away"
            );
            assert_eq!(barred.opacity, 1.0, "the muted rung is the faint one already");
            assert_eq!(barred.label_ink, LabelInk::Tertiary, "the word tracks its blob");
        }
    }

    #[test]
    fn at_rest_the_partition_is_what_inks_the_blob() {
        for zone in ZONES {
            let resting = wash(zone, false, true);
            assert_eq!(resting.label_ink, LabelInk::Secondary);
            if is_terminal_half(zone) {
                assert_eq!(resting.ink, Ink::Ok);
            } else {
                assert_eq!(resting.ink, Ink::Accent);
            }
            assert!(
                resting.opacity > 0.0 && resting.opacity < 0.5,
                "a wash, never a glow"
            );
        }
    }

    #[test]
    fn the_bytes_the_boundary_carries_are_distinct_per_rung() {
        assert_eq!(Ink::Ok.as_byte(), 0);
        assert_eq!(Ink::Accent.as_byte(), 1);
        assert_eq!(Ink::AccentMuted.as_byte(), 2);
        assert_eq!(LabelInk::Primary.as_byte(), 0);
        assert_eq!(LabelInk::Secondary.as_byte(), 1);
        assert_eq!(LabelInk::Tertiary.as_byte(), 2);
    }
}
