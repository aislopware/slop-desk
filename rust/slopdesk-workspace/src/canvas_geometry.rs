//! Where a pane goes: the eight-anchor resize, new-pane placement, culling, and the two overlays
//! that tell the user about panes they cannot currently see.
//!
//! All of it is arithmetic over the plane, which is the point — the resize math is the same rule
//! whether a mouse or a network peer asked for it, and none of it needs a view to be exercised.

use crate::geometry::{CASCADE_STEP, CULL_MARGIN, Camera, Point, Rect, Size, sanitize, sanitized_extent};

/// Which corner or edge of a pane a resize is dragging.
///
/// The anchored edges follow the drag and the opposite ones stay PINNED, including when the floor
/// stops the drag: the clamp pushes the moved edge back rather than letting the pinned edge shift,
/// so a pane resized down to the floor does not creep across the plane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResizeAnchor {
    /// The top-left corner.
    TopLeft,
    /// The top edge.
    Top,
    /// The top-right corner.
    TopRight,
    /// The left edge.
    Left,
    /// The right edge.
    Right,
    /// The bottom-left corner.
    BottomLeft,
    /// The bottom edge.
    Bottom,
    /// The bottom-right corner.
    BottomRight,
}

impl ResizeAnchor {
    /// Every anchor, for a caller that wants to sweep them.
    pub const ALL: [Self; 8] = [
        Self::TopLeft,
        Self::Top,
        Self::TopRight,
        Self::Left,
        Self::Right,
        Self::BottomLeft,
        Self::Bottom,
        Self::BottomRight,
    ];

    /// The byte for this anchor — [`Self::ALL`]'s position, which is what crosses the ABI.
    ///
    /// Exhaustive on purpose: see [`crate::canvas::AlignEdge::index`]. The shim's decoder used to
    /// restate this map and fall back to `BottomRight`, so a ninth anchor would have resized from
    /// the wrong corner rather than failing.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::TopLeft => 0,
            Self::Top => 1,
            Self::TopRight => 2,
            Self::Left => 3,
            Self::Right => 4,
            Self::BottomLeft => 5,
            Self::Bottom => 6,
            Self::BottomRight => 7,
        }
    }

    /// The anchor a byte names, or `None` when it names none.
    #[must_use]
    pub fn from_index(index: u8) -> Option<Self> {
        Self::ALL.get(usize::from(index)).copied()
    }

    /// Whether the left edge follows the drag.
    #[must_use]
    pub const fn moves_left(self) -> bool {
        matches!(self, Self::TopLeft | Self::Left | Self::BottomLeft)
    }

    /// Whether the right edge follows the drag.
    #[must_use]
    pub const fn moves_right(self) -> bool {
        matches!(self, Self::TopRight | Self::Right | Self::BottomRight)
    }

    /// Whether the top edge follows the drag.
    #[must_use]
    pub const fn moves_top(self) -> bool {
        matches!(self, Self::TopLeft | Self::Top | Self::TopRight)
    }

    /// Whether the bottom edge follows the drag.
    #[must_use]
    pub const fn moves_bottom(self) -> bool {
        matches!(self, Self::BottomLeft | Self::Bottom | Self::BottomRight)
    }
}

/// The frame after dragging one anchor by a delta, with each dimension floored.
#[must_use]
pub fn resizing(frame: Rect, anchor: ResizeAnchor, delta: Size, min_size: Size) -> Rect {
    let mut left = frame.min_x();
    let mut right = frame.max_x();
    let mut top = frame.min_y();
    let mut bottom = frame.max_y();

    if anchor.moves_left() {
        left += delta.width;
    }
    if anchor.moves_right() {
        right += delta.width;
    }
    if anchor.moves_top() {
        top += delta.height;
    }
    if anchor.moves_bottom() {
        bottom += delta.height;
    }

    // Floor by pushing back whichever edge MOVED, so the pinned edge never shifts.
    if right - left < min_size.width {
        if anchor.moves_left() {
            left = right - min_size.width;
        } else {
            right = left + min_size.width;
        }
    }
    if bottom - top < min_size.height {
        if anchor.moves_top() {
            top = bottom - min_size.height;
        } else {
            bottom = top + min_size.height;
        }
    }

    sanitize(Rect::xywh(left, top, right - left, bottom - top))
}

/// The fraction of a candidate's own area that, once overlapped, counts as a collision.
///
/// It is deliberately not "any overlap at all": panes on a free plane routinely clip each other by
/// a few points, and treating that as a collision would send every new pane cascading off into
/// empty space away from the work.
pub const OVERLAP_THRESHOLD: f64 = 0.25;

/// How many cascade steps are tried before the grid scan takes over.
pub const MAX_CASCADE_STEPS: u32 = 12;

/// How many rows and columns the fallback grid scan walks.
pub const GRID_SCAN_SPAN: u32 = 8;

/// Whether a candidate overlaps anything by more than the threshold share of its own area.
#[must_use]
pub fn collides(candidate: Rect, existing: &[Rect]) -> bool {
    let area = candidate.area();
    if area <= 0.0 {
        return false;
    }
    existing.iter().any(|frame| {
        candidate
            .intersection(*frame)
            .is_some_and(|shared| shared.area() / area > OVERLAP_THRESHOLD)
    })
}

/// A clean canvas-space frame for a NEW pane.
///
/// It seeds beside the pane being split from — the cascade convention — or at the viewport's centre
/// when there is nothing to split from, then cascade-steps while it collides. The bounded grid scan
/// after that is what guarantees BOTH a non-overlapping slot in any ordinary board and termination
/// in a pathological one; the final fallback returns the cascaded candidate, which is still a valid
/// finite frame, because a pane placed imperfectly beats a placement loop that never ends.
#[must_use]
pub fn placement(near: Option<Rect>, existing: &[Rect], viewport: Rect, size: Size, cascade: f64) -> Rect {
    let seed = near.map_or_else(
        || {
            Point::new(
                viewport.mid_x() - size.width / 2.0,
                viewport.mid_y() - size.height / 2.0,
            )
        },
        |anchor| Point::new(anchor.origin.x + cascade, anchor.origin.y + cascade),
    );

    let mut candidate = Rect::new(seed, size);
    let mut steps = 0;
    while collides(candidate, existing) && steps < MAX_CASCADE_STEPS {
        candidate = candidate.offset_by(cascade, cascade);
        steps += 1;
    }
    if !collides(candidate, existing) {
        return candidate;
    }

    let step_x = size.width + cascade;
    let step_y = size.height + cascade;
    for row in 0..GRID_SCAN_SPAN {
        for col in 0..GRID_SCAN_SPAN {
            let cell = Rect::xywh(
                viewport.min_x() + f64::from(col) * step_x,
                viewport.min_y() + f64::from(row) * step_y,
                size.width,
                size.height,
            );
            if !collides(cell, existing) {
                return cell;
            }
        }
    }
    candidate
}

/// The same placement at the standard cascade step.
#[must_use]
pub fn default_placement(near: Option<Rect>, existing: &[Rect], viewport: Rect, size: Size) -> Rect {
    placement(near, existing, viewport, size, CASCADE_STEP)
}

/// One pane on the plane, as the geometry sees it.
///
/// The identity is the caller's own — the domain never mints one and never looks inside it, so a
/// UUID, an index or anything else orderable works.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlacedPane<Id> {
    /// The caller's pane identity.
    pub id: Id,
    /// The pane's canvas-space frame.
    pub frame: Rect,
    /// Whether this pane streams video, which is the ONLY kind culling may unmount.
    pub is_video: bool,
}

impl<Id> PlacedPane<Id> {
    /// A pane.
    #[must_use]
    pub const fn new(id: Id, frame: Rect, is_video: bool) -> Self {
        Self { id, frame, is_video }
    }
}

/// Whether one pane should stay mounted.
///
/// Only VIDEO panes are ever culled, and that asymmetry is deliberate. Unmounting a live terminal
/// closes its surface, and panning back to it can show a stale alt-screen frame; the system
/// occludes an off-viewport view cheaply anyway, so a terminal stays mounted and simply repaints. A
/// video pane costs a decode slot, so culling one off-viewport frees something real. The focused
/// pane is never culled whatever its kind.
#[must_use]
pub fn is_visible<Id: PartialEq>(
    pane: &PlacedPane<Id>,
    camera: Camera,
    viewport: Size,
    focused: Option<&Id>,
    margin: f64,
) -> bool {
    if focused.is_some_and(|id| *id == pane.id) {
        return true;
    }
    if !pane.is_video {
        return true;
    }
    pane.frame
        .intersects(camera.viewport_rect(viewport).outset_by(margin, margin))
}

/// Every pane that should stay mounted, at the standard overscan.
pub fn visible_panes<'a, Id: PartialEq>(
    panes: &'a [PlacedPane<Id>],
    camera: Camera,
    viewport: Size,
    focused: Option<&'a Id>,
) -> Vec<&'a PlacedPane<Id>> {
    panes
        .iter()
        .filter(|pane| is_visible(pane, camera, viewport, focused, CULL_MARGIN))
        .collect()
}

/// The panes whose frame touches the viewport itself — no overscan, no kind filter.
///
/// This is the "on screen" membership the live-video cap consumes, and it is kept separate from
/// culling ON PURPOSE: terminals being held mounted must not pollute the set, or the cap would
/// count panes that are nowhere near the screen.
pub fn viewport_members<Id>(panes: &[PlacedPane<Id>], camera: Camera, viewport: Size) -> Vec<&Id> {
    let rect = camera.viewport_rect(viewport);
    panes
        .iter()
        .filter(|pane| pane.frame.intersects(rect))
        .map(|pane| &pane.id)
        .collect()
}

/// The default padding around the fit-all overview.
pub const OVERVIEW_PADDING: f64 = 48.0;

/// One pane's card in the fit-all overview.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OverviewCard<Id> {
    /// Which pane.
    pub id: Id,
    /// Its screen-space rect under the overview scale.
    pub rect: Rect,
}

/// The fit-all overview: one uniform scale and a card per pane.
#[derive(Debug, Clone, PartialEq)]
pub struct OverviewLayout<Id> {
    /// The scale every card is drawn at. It NEVER exceeds one — a single small pane stays its own
    /// size, centred, rather than being magnified into a blurry hero.
    pub scale: f64,
    /// The cards, in the order the panes were given.
    pub cards: Vec<OverviewCard<Id>>,
}

/// Lays out every pane at once inside the viewport.
pub fn overview_layout<Id: Copy>(
    panes: &[PlacedPane<Id>],
    viewport: Size,
    padding: f64,
) -> OverviewLayout<Id> {
    let Some(first) = panes.first() else {
        return OverviewLayout {
            scale: 1.0,
            cards: Vec::new(),
        };
    };
    let mut min_x = first.frame.min_x();
    let mut min_y = first.frame.min_y();
    let mut max_x = first.frame.max_x();
    let mut max_y = first.frame.max_y();
    for pane in panes {
        min_x = min_x.min(pane.frame.min_x());
        min_y = min_y.min(pane.frame.min_y());
        max_x = max_x.max(pane.frame.max_x());
        max_y = max_y.max(pane.frame.max_y());
    }
    let box_width = 1.0_f64.max(max_x - min_x);
    let box_height = 1.0_f64.max(max_y - min_y);
    let available_width = 1.0_f64.max(viewport.width - 2.0 * padding);
    let available_height = 1.0_f64.max(viewport.height - 2.0 * padding);
    let scale = 1.0_f64.min((available_width / box_width).min(available_height / box_height));
    let origin_x = (viewport.width - box_width * scale) / 2.0;
    let origin_y = (viewport.height - box_height * scale) / 2.0;
    let cards = panes
        .iter()
        .map(|pane| {
            OverviewCard {
                id: pane.id,
                rect: Rect::xywh(
                    // keep mul+add separate — FMA breaks bit-exact parity
                    origin_x + (pane.frame.min_x() - min_x) * scale,
                    origin_y + (pane.frame.min_y() - min_y) * scale,
                    pane.frame.size.width * scale,
                    pane.frame.size.height * scale,
                ),
            }
        })
        .collect();
    OverviewLayout { scale, cards }
}

/// The default inset that keeps an off-screen beacon's pill from clipping the viewport edge.
pub const BEACON_INSET: f64 = 18.0;

/// Which viewport edge an off-screen pane lies past.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BeaconEdge {
    /// Above.
    Top,
    /// Below.
    Bottom,
    /// To the left.
    Left,
    /// To the right.
    Right,
}

/// A pill on the viewport border saying "a pane is over there".
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OffscreenBeacon<Id> {
    /// Which pane it points at.
    pub id: Id,
    /// Where to centre the pill, in viewport coordinates, already inset from every edge.
    pub screen_point: Point,
    /// The edge it sits on, which drives the little direction arrow.
    pub edge: BeaconEdge,
}

/// Projects every pane that does NOT touch the viewport onto its border.
///
/// A pane that intersects the viewport gets no beacon, because the user can already see it. The
/// DOMINANT overflow — how far past each edge the pane's centre is — picks the edge, so a pane far
/// up and slightly right reads as "above" rather than flickering between the two.
pub fn offscreen_beacons<Id: Copy>(
    panes: &[PlacedPane<Id>],
    camera: Camera,
    viewport: Size,
    inset: f64,
) -> Vec<OffscreenBeacon<Id>> {
    let viewport_rect = camera.viewport_rect(viewport);
    let min_x = inset;
    let min_y = inset;
    let max_x = inset.max(viewport.width - inset);
    let max_y = inset.max(viewport.height - inset);
    panes
        .iter()
        .filter(|pane| !pane.frame.intersects(viewport_rect))
        .map(|pane| {
            let sx = pane.frame.mid_x() - camera.origin.x;
            let sy = pane.frame.mid_y() - camera.origin.y;
            let past_left = min_x - sx;
            let past_right = sx - max_x;
            let past_top = min_y - sy;
            let past_bottom = sy - max_y;
            let horizontal = past_left.max(past_right);
            let vertical = past_top.max(past_bottom);
            let edge = if horizontal >= vertical {
                if past_left >= past_right {
                    BeaconEdge::Left
                } else {
                    BeaconEdge::Right
                }
            } else if past_top >= past_bottom {
                BeaconEdge::Top
            } else {
                BeaconEdge::Bottom
            };
            OffscreenBeacon {
                id: pane.id,
                screen_point: Point::new(sx.max(min_x).min(max_x), sy.max(min_y).min(max_y)),
                edge,
            }
        })
        .collect()
}

/// A frame centred on the viewport, so a pane summoned from off-screen lands where the user is
/// looking rather than wherever it was last saved.
#[must_use]
pub fn centered(size: Size, viewport: Rect) -> Rect {
    Rect::xywh(
        viewport.mid_x() - size.width / 2.0,
        viewport.mid_y() - size.height / 2.0,
        sanitized_extent(size.width, 0.0),
        sanitized_extent(size.height, 0.0),
    )
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the fixtures are exact integers of the plane's constants, and a missing beacon is a test \
                  failure with nothing to return"
    )]

    use super::{
        BEACON_INSET, BeaconEdge, OVERVIEW_PADDING, PlacedPane, ResizeAnchor, centered, collides,
        default_placement, is_visible, offscreen_beacons, overview_layout, resizing, viewport_members,
        visible_panes,
    };
    use crate::geometry::{CULL_MARGIN, Camera, MIN_ITEM_SIZE, Point, Rect, Size};

    fn body() -> Rect {
        Rect::xywh(100.0, 100.0, 400.0, 300.0)
    }

    /// The two halves of the ABI byte agree, and the mapping is total both ways.
    ///
    /// `ALL` and `index` are separately written — one an array, one a match — so this is what ties
    /// them together. A case added to the array but not the match will not compile; a case added to
    /// both in DIFFERENT positions compiles fine and fails here, and nothing else would notice: the
    /// byte would cross the boundary naming another anchor.
    #[test]
    fn every_resize_anchor_round_trips_through_its_abi_byte() {
        for (position, anchor) in ResizeAnchor::ALL.iter().enumerate() {
            assert_eq!(
                usize::from(anchor.index()),
                position,
                "{anchor:?} is at position {position}"
            );
            assert_eq!(ResizeAnchor::from_index(anchor.index()), Some(*anchor));
        }
        let past_the_end = ResizeAnchor::ALL
            .last()
            .map_or(0, |anchor| anchor.index().saturating_add(1));
        assert_eq!(
            ResizeAnchor::from_index(past_the_end),
            None,
            "a byte naming no case must read as none, not as the last one"
        );
        assert_eq!(ResizeAnchor::from_index(u8::MAX), None);
    }

    #[test]
    fn every_anchor_moves_its_own_edges_and_pins_the_others() {
        let delta = Size::new(50.0, 40.0);
        let floor = Size::new(10.0, 10.0);
        for anchor in ResizeAnchor::ALL {
            let resized = resizing(body(), anchor, delta, floor);
            if anchor.moves_left() {
                assert_eq!(resized.min_x(), 150.0, "{anchor:?}");
            } else {
                assert_eq!(resized.min_x(), 100.0, "{anchor:?} must pin the left edge");
            }
            if anchor.moves_right() {
                assert_eq!(resized.max_x(), 550.0, "{anchor:?}");
            } else {
                assert_eq!(resized.max_x(), 500.0, "{anchor:?} must pin the right edge");
            }
            if anchor.moves_top() {
                assert_eq!(resized.min_y(), 140.0, "{anchor:?}");
            } else {
                assert_eq!(resized.min_y(), 100.0, "{anchor:?} must pin the top edge");
            }
            if anchor.moves_bottom() {
                assert_eq!(resized.max_y(), 440.0, "{anchor:?}");
            } else {
                assert_eq!(resized.max_y(), 400.0, "{anchor:?} must pin the bottom edge");
            }
        }
    }

    #[test]
    fn the_floor_pushes_the_moved_edge_back_rather_than_dragging_the_pinned_one() {
        let floor = Size::new(200.0, 150.0);
        let squeezed = resizing(body(), ResizeAnchor::Left, Size::new(999.0, 0.0), floor);
        assert_eq!(squeezed.max_x(), 500.0, "the pinned right edge does not move");
        assert_eq!(
            squeezed.min_x(),
            300.0,
            "so the pane creeps nowhere as it hits the floor"
        );
        assert_eq!(squeezed.size.width, 200.0);

        let other_way = resizing(body(), ResizeAnchor::Right, Size::new(-999.0, 0.0), floor);
        assert_eq!(other_way.min_x(), 100.0, "and symmetrically from the other side");
        assert_eq!(other_way.size.width, 200.0);
    }

    #[test]
    fn a_resize_still_leaves_a_frame_the_plane_will_accept() {
        let mad = resizing(
            body(),
            ResizeAnchor::TopLeft,
            Size::new(f64::NAN, 0.0),
            Size::new(1.0, 1.0),
        );
        assert!(mad.origin.x.is_finite() && mad.size.width.is_finite());
        assert!(
            mad.size.width >= MIN_ITEM_SIZE.width,
            "the sanitation floor still applies"
        );
    }

    #[test]
    fn a_few_points_of_clipping_is_not_a_collision() {
        let existing = [Rect::xywh(0.0, 0.0, 400.0, 300.0)];
        let barely = Rect::xywh(380.0, 280.0, 400.0, 300.0);
        assert!(
            !collides(barely, &existing),
            "panes clip each other constantly on a free plane"
        );
        let stacked = Rect::xywh(10.0, 10.0, 400.0, 300.0);
        assert!(collides(stacked, &existing));
    }

    #[test]
    fn the_collision_share_is_measured_against_the_candidates_own_area() {
        // A huge existing pane fully covering a small candidate is a collision at any threshold.
        let existing = [Rect::xywh(0.0, 0.0, 4000.0, 3000.0)];
        assert!(collides(Rect::xywh(10.0, 10.0, 100.0, 100.0), &existing));
    }

    #[test]
    fn a_new_pane_cascades_off_the_one_it_was_split_from() {
        let near = Rect::xywh(100.0, 100.0, 400.0, 300.0);
        let placed = default_placement(
            Some(near),
            &[near],
            Rect::xywh(0.0, 0.0, 1600.0, 1000.0),
            near.size,
        );
        assert!(placed.origin.x > near.origin.x && placed.origin.y > near.origin.y);
        assert!(!collides(placed, &[near]));
    }

    #[test]
    fn a_pane_with_nothing_to_split_from_opens_in_the_middle_of_the_view() {
        let viewport = Rect::xywh(0.0, 0.0, 1600.0, 1000.0);
        let size = Size::new(640.0, 420.0);
        let placed = default_placement(None, &[], viewport, size);
        assert_eq!(placed.center(), viewport.center());
    }

    #[test]
    fn a_crowded_board_still_terminates_and_still_returns_a_finite_frame() {
        // Tile the whole grid-scan region so neither the cascade nor the scan can find a slot.
        let mut existing = Vec::new();
        for row in 0..12 {
            for col in 0..12 {
                existing.push(Rect::xywh(
                    f64::from(col) * 60.0,
                    f64::from(row) * 60.0,
                    640.0,
                    420.0,
                ));
            }
        }
        let placed = default_placement(
            None,
            &existing,
            Rect::xywh(0.0, 0.0, 1600.0, 1000.0),
            Size::new(640.0, 420.0),
        );
        assert!(placed.origin.x.is_finite() && placed.origin.y.is_finite());
    }

    #[test]
    fn a_terminal_is_never_culled_however_far_away_it_is() {
        let far = PlacedPane::new(1_u32, Rect::xywh(500_000.0, 500_000.0, 400.0, 300.0), false);
        assert!(
            is_visible(&far, Camera::ZERO, Size::new(1600.0, 1000.0), None, CULL_MARGIN),
            "unmounting a live terminal closes its surface, which costs more than the memory saves",
        );
    }

    #[test]
    fn a_video_pane_past_the_overscan_is_culled_but_the_focused_one_never_is() {
        let far = PlacedPane::new(1_u32, Rect::xywh(500_000.0, 500_000.0, 400.0, 300.0), true);
        let viewport = Size::new(1600.0, 1000.0);
        assert!(!is_visible(&far, Camera::ZERO, viewport, None, CULL_MARGIN));
        assert!(is_visible(
            &far,
            Camera::ZERO,
            viewport,
            Some(&1_u32),
            CULL_MARGIN
        ));
    }

    #[test]
    fn the_overscan_keeps_a_pane_about_to_pan_in_already_warm() {
        let just_off = PlacedPane::new(1_u32, Rect::xywh(1900.0, 0.0, 400.0, 300.0), true);
        let viewport = Size::new(1600.0, 1000.0);
        assert!(is_visible(&just_off, Camera::ZERO, viewport, None, CULL_MARGIN));
        assert!(
            !is_visible(&just_off, Camera::ZERO, viewport, None, 0.0),
            "and with no overscan it would have popped in cold",
        );
    }

    #[test]
    fn the_video_cap_membership_ignores_the_terminals_held_mounted() {
        let panes = [
            PlacedPane::new(1_u32, Rect::xywh(0.0, 0.0, 400.0, 300.0), true),
            PlacedPane::new(2_u32, Rect::xywh(5000.0, 0.0, 400.0, 300.0), false),
        ];
        let camera = Camera::ZERO;
        let viewport = Size::new(1600.0, 1000.0);
        assert_eq!(visible_panes(&panes, camera, viewport, None).len(), 2);
        assert_eq!(
            viewport_members(&panes, camera, viewport),
            vec![&1_u32],
            "only what actually touches the screen counts against the cap",
        );
    }

    #[test]
    fn the_overview_fits_everything_and_never_magnifies() {
        let panes = [
            PlacedPane::new(1_u32, Rect::xywh(0.0, 0.0, 400.0, 300.0), false),
            PlacedPane::new(2_u32, Rect::xywh(4000.0, 3000.0, 400.0, 300.0), false),
        ];
        let wide = overview_layout(&panes, Size::new(1600.0, 1000.0), OVERVIEW_PADDING);
        assert!(wide.scale < 1.0 && wide.scale > 0.0);
        assert_eq!(wide.cards.len(), 2);

        let single = [PlacedPane::new(1_u32, Rect::xywh(0.0, 0.0, 400.0, 300.0), false)];
        let roomy = overview_layout(&single, Size::new(1600.0, 1000.0), OVERVIEW_PADDING);
        assert_eq!(
            roomy.scale, 1.0,
            "one small pane stays its own size rather than becoming a blur"
        );
    }

    #[test]
    fn an_empty_board_has_an_overview_with_nothing_in_it() {
        let empty: [PlacedPane<u32>; 0] = [];
        let layout = overview_layout(&empty, Size::new(1600.0, 1000.0), OVERVIEW_PADDING);
        assert_eq!(layout.scale, 1.0);
        assert!(layout.cards.is_empty());
    }

    #[test]
    fn a_visible_pane_gets_no_beacon() {
        let panes = [PlacedPane::new(
            1_u32,
            Rect::xywh(10.0, 10.0, 400.0, 300.0),
            false,
        )];
        assert!(offscreen_beacons(&panes, Camera::ZERO, Size::new(1600.0, 1000.0), BEACON_INSET).is_empty());
    }

    #[test]
    fn the_dominant_overflow_picks_the_edge() {
        let panes = [
            PlacedPane::new(1_u32, Rect::xywh(-5000.0, 400.0, 400.0, 300.0), false),
            PlacedPane::new(2_u32, Rect::xywh(400.0, -5000.0, 400.0, 300.0), false),
            PlacedPane::new(3_u32, Rect::xywh(9000.0, 400.0, 400.0, 300.0), false),
            PlacedPane::new(4_u32, Rect::xywh(400.0, 9000.0, 400.0, 300.0), false),
        ];
        let beacons = offscreen_beacons(&panes, Camera::ZERO, Size::new(1600.0, 1000.0), BEACON_INSET);
        let edges: Vec<BeaconEdge> = beacons.iter().map(|beacon| beacon.edge).collect();
        assert_eq!(edges, vec![
            BeaconEdge::Left,
            BeaconEdge::Top,
            BeaconEdge::Right,
            BeaconEdge::Bottom
        ],);
    }

    #[test]
    fn a_beacon_pill_is_clamped_inside_the_viewport_so_it_cannot_clip() {
        let panes = [PlacedPane::new(
            1_u32,
            Rect::xywh(-5000.0, -5000.0, 400.0, 300.0),
            false,
        )];
        let beacons = offscreen_beacons(&panes, Camera::ZERO, Size::new(1600.0, 1000.0), BEACON_INSET);
        let Some(beacon) = beacons.first() else {
            panic!("an off-screen pane must produce a beacon");
        };
        assert_eq!(beacon.screen_point, Point::new(BEACON_INSET, BEACON_INSET));
    }

    #[test]
    fn a_summoned_pane_lands_where_the_user_is_looking() {
        let viewport = Rect::xywh(2000.0, 1000.0, 1600.0, 1000.0);
        let placed = centered(Size::new(640.0, 420.0), viewport);
        assert_eq!(placed.center(), viewport.center());
    }
}
