//! The rect math a pane MOVE resolves through, and the six numbers that tune it.
//!
//! [`drop_zone`](crate::drop_zone) is the other drop: a FILE arriving over a pane, resolved against
//! five blobs. This is a PANE arriving over another pane — a swap, a re-split, a dock — resolved
//! against a centre box, four edge bands and an outer gutter. The two never meet, and they are
//! deliberately separate rules rather than one parameterised one, because the shapes are different
//! answers to different questions.
//!
//! ## Four callers, and none of them may disagree
//!
//! The point-to-answer half is asked twice: the canvas's LIVE in-tab resolution (with the dragged
//! pane's own rect excluded) and the cross-window INSERT resolution (a satellite drag has no source
//! pane in this tab to exclude). The answer-to-rects half is asked twice too, and this is the pair
//! that actually forced the move: the preview is drawn by `SlopDeskMacUI` in `AppKit` and by
//! `SlopDeskPhoneUI` in `UIKit`, from two files that had each written "pure rect math" over their
//! own copy. Two frameworks re-deriving a slab's half by eye is how one half draws a promise the
//! shared resolver never commits.
//!
//! ## The round trip has to close
//!
//! [`container_edge`] and [`dominant_edge`] turn a point into an ANSWER; [`slab_rect`],
//! [`seam_size`], [`seam_center`] and [`rail_rect`] turn that answer back into RECTANGLES. They are
//! one file for that reason: the preview is a promise about what the commit will do, and the two
//! ends of the trip are only trustworthy together.
//!
//! ## The gutter is a hit band, the rail is a promise
//!
//! [`DOCK_RAIL_FRACTION`] is exactly twice [`CONTAINER_GUTTER_FRACTION`] and [`DOCK_RAIL_MAX`] is
//! most of twice [`CONTAINER_GUTTER_MAX`], and that gap is the affordance rather than an accident.
//! The gutter is aimed at by a cursor already travelling, so it can be thin; the rail is a claim
//! about a full-span column that has to read at a glance over a whole pane of terminal text. A rail
//! drawn AT the gutter's width would show a sliver for an op that takes a column.

use slopdesk_tree::PaneDropEdge;
use slopdesk_tree::geometry::{Point, Rect, Size};

/// Each edge band is this fraction of the target's width/height, so the central SWAP box is the
/// middle `1 - 2·EDGE_BAND_FRACTION` — 40 % at `0.30`.
///
/// A generous centre keeps the common swap easy; 30 % bands stay aimable on a small pane. It must
/// stay under `0.5`: at exactly a half the swap zone vanishes and every drop re-splits.
pub const EDGE_BAND_FRACTION: f64 = 0.30;

/// The container's outer DOCK gutter is `min(CONTAINER_GUTTER_MAX, min(w, h) · this)`.
pub const CONTAINER_GUTTER_FRACTION: f64 = 0.06;

/// The cap on that gutter, in points. Without it a 4K canvas would dock from 120 pt in, which
/// swallows the whole first column of panes.
pub const CONTAINER_GUTTER_MAX: f64 = 28.0;

/// The DOCK PREVIEW's rail is `min(DOCK_RAIL_MAX, min(w, h) · this)` — the band the user SEES,
/// which is deliberately not the gutter that resolved the dock.
pub const DOCK_RAIL_FRACTION: f64 = 0.12;

/// The cap on that rail, in points.
pub const DOCK_RAIL_MAX: f64 = 48.0;

/// The RE-SPLIT preview's seam bar — the would-be new divider, drawn along the slab's inner edge,
/// in points.
///
/// A dimension rather than a design token because the token ladder sits above every caller of this
/// and cannot be named from here. It is deliberately a step over the divider's own dragging width:
/// this bar is a one-second promise about where a seam will land, not the seam.
pub const RESPLIT_SEAM_THICKNESS: f64 = 3.0;

/// How far a rect may miss a container edge and still count as spanning it, in points.
///
/// A solver rounding of half a point would otherwise turn a suppressed no-op dock back on.
const SPAN_EPSILON: f64 = 1.0;

/// The metrics by index, for a caller that cannot name a constant — the C door's only vocabulary.
const METRICS: [f64; 6] = [
    EDGE_BAND_FRACTION,
    CONTAINER_GUTTER_FRACTION,
    CONTAINER_GUTTER_MAX,
    DOCK_RAIL_FRACTION,
    DOCK_RAIL_MAX,
    RESPLIT_SEAM_THICKNESS,
];

/// One tuned number by index, in the order [`METRICS`] declares. An unknown index answers `0.0`,
/// which is not one of them.
#[must_use]
pub fn metric(index: usize) -> f64 {
    METRICS.get(index).copied().unwrap_or(0.0)
}

/// The container outer edge whose gutter contains `location`, or `None` when the cursor is in no
/// gutter.
///
/// Deepest into the gutter wins; an exact tie goes to a VERTICAL edge, which matches the default
/// mental model of a corner. An edge that `source` already fully spans is skipped — docking there
/// would change nothing — and `None` for `source` is the INSERT drag, where every edge is
/// meaningful because the pane is not in this tab yet.
#[must_use]
pub fn container_edge(location: Point, container: Rect, source: Option<Rect>) -> Option<PaneDropEdge> {
    if container.size.width <= 0.0 || container.size.height <= 0.0 {
        return None;
    }
    // `min` rather than a `<` ternary, per the float convention.
    let gutter =
        CONTAINER_GUTTER_MAX.min(container.size.width.min(container.size.height) * CONTAINER_GUTTER_FRACTION);
    let distances = [
        (PaneDropEdge::Left, location.x - container.min_x()),
        (PaneDropEdge::Right, container.max_x() - location.x),
        (PaneDropEdge::Top, location.y - container.min_y()),
        (PaneDropEdge::Bottom, container.max_y() - location.y),
    ];
    let mut best: Option<(PaneDropEdge, f64)> = None;
    for (edge, distance) in distances {
        if source.is_some_and(|rect| source_spans(rect, edge, container)) {
            continue;
        }
        if distance < 0.0 || distance > gutter {
            continue;
        }
        // Strictly less, so the left,right,top,bottom order lets a vertical edge hold an exact tie.
        if best.is_none_or(|(_, current)| distance < current) {
            best = Some((edge, distance));
        }
    }
    best.map(|(edge, _)| edge)
}

/// Whether `rect` already fully spans the container's `edge`, so docking a pane there is a no-op.
#[must_use]
pub fn source_spans(rect: Rect, edge: PaneDropEdge, container: Rect) -> bool {
    match edge {
        PaneDropEdge::Left => {
            rect.min_x() <= container.min_x() + SPAN_EPSILON
                && rect.size.height >= container.size.height - SPAN_EPSILON
        },
        PaneDropEdge::Right => {
            rect.max_x() >= container.max_x() - SPAN_EPSILON
                && rect.size.height >= container.size.height - SPAN_EPSILON
        },
        PaneDropEdge::Top => {
            rect.min_y() <= container.min_y() + SPAN_EPSILON
                && rect.size.width >= container.size.width - SPAN_EPSILON
        },
        PaneDropEdge::Bottom => {
            rect.max_y() >= container.max_y() - SPAN_EPSILON
                && rect.size.width >= container.size.width - SPAN_EPSILON
        },
    }
}

/// The edge band a cursor at normalised `u`, `v` inside the target has penetrated deepest.
///
/// With the MOVE band ([`EDGE_BAND_FRACTION`], under a half) this is asked only when the cursor is
/// NOT in the centre box, so at least one penetration is positive. Band `0.5` — the INSERT drag,
/// which has no centre box — maps every interior point to its nearest edge. An exact tie goes to a
/// vertical edge, the same way [`container_edge`]'s does.
#[must_use]
pub fn dominant_edge(u: f64, v: f64, band: f64) -> PaneDropEdge {
    let penetrations = [
        (PaneDropEdge::Left, band - u),
        (PaneDropEdge::Right, u - (1.0 - band)),
        (PaneDropEdge::Top, band - v),
        (PaneDropEdge::Bottom, v - (1.0 - band)),
    ];
    let mut best = (PaneDropEdge::Left, f64::NEG_INFINITY);
    for (edge, penetration) in penetrations {
        if penetration > best.1 {
            best = (edge, penetration);
        }
    }
    best.0
}

/// The drop-side HALF of `rect` for the re-split slab — the pane the target is about to become.
///
/// Half, and not [`EDGE_BAND_FRACTION`]'s 30 %, on purpose: the band is where you AIM and the half
/// is what you GET. A slab drawn at the band's width would preview a 30/70 split the tree op does
/// not perform.
#[must_use]
pub fn slab_rect(rect: Rect, edge: PaneDropEdge) -> Rect {
    let (width, height) = (rect.size.width, rect.size.height);
    match edge {
        PaneDropEdge::Left => Rect::xywh(rect.min_x(), rect.min_y(), width / 2.0, height),
        PaneDropEdge::Right => Rect::xywh(rect.mid_x(), rect.min_y(), width / 2.0, height),
        PaneDropEdge::Top => Rect::xywh(rect.min_x(), rect.min_y(), width, height / 2.0),
        PaneDropEdge::Bottom => Rect::xywh(rect.min_x(), rect.mid_y(), width, height / 2.0),
    }
}

/// The seam bar's size — [`RESPLIT_SEAM_THICKNESS`] along the slab's inner edge, the CROSS axis
/// spanning that edge in full. A seam short of its own edge would read as a handle rather than as a
/// divider.
#[must_use]
pub const fn seam_size(slab: Rect, edge: PaneDropEdge) -> Size {
    match edge {
        PaneDropEdge::Left | PaneDropEdge::Right => Size::new(RESPLIT_SEAM_THICKNESS, slab.size.height),
        PaneDropEdge::Top | PaneDropEdge::Bottom => Size::new(slab.size.width, RESPLIT_SEAM_THICKNESS),
    }
}

/// The seam bar's centre — on the slab's INNER boundary, the side facing the rest of the target.
///
/// It mirrors [`slab_rect`]'s own edge choice, so the two can never place the slab on one side and
/// its divider on the other.
#[must_use]
pub const fn seam_center(slab: Rect, edge: PaneDropEdge) -> Point {
    match edge {
        PaneDropEdge::Left => Point::new(slab.max_x(), slab.mid_y()),
        PaneDropEdge::Right => Point::new(slab.min_x(), slab.mid_y()),
        PaneDropEdge::Top => Point::new(slab.mid_x(), slab.max_y()),
        PaneDropEdge::Bottom => Point::new(slab.mid_x(), slab.min_y()),
    }
}

/// The dock rail band along a whole container edge: `min(DOCK_RAIL_MAX, min(w, h) ·
/// DOCK_RAIL_FRACTION)` thick, full span on the cross axis.
///
/// That is the shape of the op itself — a dock makes the pane a full-span column or row on that
/// edge — which is what the preview has to say.
#[must_use]
pub fn rail_rect(container: Rect, edge: PaneDropEdge) -> Rect {
    let (width, height) = (container.size.width, container.size.height);
    let thickness = DOCK_RAIL_MAX.min(width.min(height) * DOCK_RAIL_FRACTION);
    match edge {
        PaneDropEdge::Left => Rect::xywh(container.min_x(), container.min_y(), thickness, height),
        PaneDropEdge::Right => {
            Rect::xywh(
                container.max_x() - thickness,
                container.min_y(),
                thickness,
                height,
            )
        },
        PaneDropEdge::Top => Rect::xywh(container.min_x(), container.min_y(), width, thickness),
        PaneDropEdge::Bottom => {
            Rect::xywh(container.min_x(), container.max_y() - thickness, width, thickness)
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CONTAINER_GUTTER_FRACTION, CONTAINER_GUTTER_MAX, DOCK_RAIL_FRACTION, DOCK_RAIL_MAX,
        EDGE_BAND_FRACTION, PaneDropEdge, Point, RESPLIT_SEAM_THICKNESS, Rect, container_edge, dominant_edge,
        metric, rail_rect, seam_center, seam_size, slab_rect, source_spans,
    };

    /// Deliberately BIG: `min(w, h) · 0.06` is 60 here, so every gutter case below is also an
    /// assertion that the 28 pt cap applied.
    fn wide() -> Rect {
        Rect::xywh(0.0, 0.0, 2000.0, 1000.0)
    }

    #[test]
    fn metrics_are_the_tuned_affordance() {
        assert!((metric(0) - EDGE_BAND_FRACTION).abs() < 1e-9);
        assert!((metric(1) - CONTAINER_GUTTER_FRACTION).abs() < 1e-9);
        assert!((metric(2) - CONTAINER_GUTTER_MAX).abs() < 1e-9);
        assert!((metric(3) - DOCK_RAIL_FRACTION).abs() < 1e-9);
        assert!((metric(4) - DOCK_RAIL_MAX).abs() < 1e-9);
        assert!((metric(5) - RESPLIT_SEAM_THICKNESS).abs() < 1e-9);
        assert!(
            (metric(6) - 0.0).abs() < 1e-9,
            "an index past the table is not a metric"
        );
    }

    /// Two relationships between constants, so they are checked where constants are: at COMPILE
    /// time. A `#[test]` would have proved the same thing, one `cargo test` later than the edit
    /// that broke it — and one of these is the difference between a swap zone and no swap zone.
    #[test]
    fn the_tuned_numbers_stand_in_the_right_relation_to_each_other() {
        const {
            assert!(
                EDGE_BAND_FRACTION < 0.5,
                "at a half the swap zone vanishes and every drop re-splits"
            );
        }
        const {
            assert!(
                DOCK_RAIL_FRACTION > CONTAINER_GUTTER_FRACTION,
                "the drawn rail must be wider than the gutter that resolved the dock"
            );
        }
        const {
            assert!(
                DOCK_RAIL_MAX > CONTAINER_GUTTER_MAX,
                "and wider at the cap too, not only below it"
            );
        }
    }

    #[test]
    fn gutter_is_capped_on_a_large_canvas() {
        assert_eq!(
            container_edge(Point::new(27.0, 500.0), wide(), None),
            Some(PaneDropEdge::Left)
        );
        assert_eq!(container_edge(Point::new(29.0, 500.0), wide(), None), None);
    }

    #[test]
    fn a_degenerate_container_is_in_no_gutter() {
        let flat = Rect::xywh(0.0, 0.0, 2000.0, 0.0);
        assert_eq!(container_edge(Point::new(1.0, 0.0), flat, None), None);
    }

    #[test]
    fn the_deepest_gutter_wins_and_a_tie_goes_vertical() {
        // 5 pt from the left, 3 pt from the top — the top is deeper.
        assert_eq!(
            container_edge(Point::new(5.0, 3.0), wide(), None),
            Some(PaneDropEdge::Top)
        );
        // Exactly 4 pt from both: the vertical edge holds the tie.
        assert_eq!(
            container_edge(Point::new(4.0, 4.0), wide(), None),
            Some(PaneDropEdge::Left)
        );
    }

    #[test]
    fn an_edge_the_source_already_spans_is_skipped() {
        let source = Rect::xywh(0.0, 0.0, 400.0, 1000.0);
        // In the left gutter, but the source already IS the left column — the dock is a no-op, so
        // the answer falls through to no edge at all rather than to a pointless dock.
        assert_eq!(container_edge(Point::new(5.0, 500.0), wide(), Some(source)), None);
    }

    #[test]
    fn the_span_predicate_carries_a_point_of_slack() {
        let container = Rect::xywh(0.0, 0.0, 1000.0, 800.0);
        let nearly = Rect::xywh(0.5, 0.0, 300.0, 799.5);
        assert!(source_spans(nearly, PaneDropEdge::Left, container));
        let short = Rect::xywh(0.0, 0.0, 300.0, 700.0);
        assert!(!source_spans(short, PaneDropEdge::Left, container));
    }

    #[test]
    fn the_dominant_edge_is_the_deepest_penetration() {
        // u = 0.05 is 0.25 into the left band; v = 0.5 is outside both horizontal bands.
        assert_eq!(dominant_edge(0.05, 0.5, 0.30), PaneDropEdge::Left);
        assert_eq!(dominant_edge(0.95, 0.5, 0.30), PaneDropEdge::Right);
        assert_eq!(dominant_edge(0.5, 0.05, 0.30), PaneDropEdge::Top);
        assert_eq!(dominant_edge(0.5, 0.95, 0.30), PaneDropEdge::Bottom);
    }

    #[test]
    fn a_corner_tie_goes_to_the_vertical_edge() {
        assert_eq!(dominant_edge(0.1, 0.1, 0.30), PaneDropEdge::Left);
        assert_eq!(dominant_edge(0.9, 0.9, 0.30), PaneDropEdge::Right);
    }

    #[test]
    fn the_insert_band_maps_every_interior_point() {
        // Band 0.5 has no centre box: dead centre still resolves, and to a vertical edge.
        assert_eq!(dominant_edge(0.5, 0.5, 0.5), PaneDropEdge::Left);
        assert_eq!(dominant_edge(0.6, 0.5, 0.5), PaneDropEdge::Right);
    }

    #[test]
    fn the_slab_is_the_drop_side_half() {
        let rect = Rect::xywh(100.0, 200.0, 400.0, 300.0);
        assert_eq!(
            slab_rect(rect, PaneDropEdge::Left),
            Rect::xywh(100.0, 200.0, 200.0, 300.0)
        );
        assert_eq!(
            slab_rect(rect, PaneDropEdge::Right),
            Rect::xywh(300.0, 200.0, 200.0, 300.0)
        );
        assert_eq!(
            slab_rect(rect, PaneDropEdge::Top),
            Rect::xywh(100.0, 200.0, 400.0, 150.0)
        );
        assert_eq!(
            slab_rect(rect, PaneDropEdge::Bottom),
            Rect::xywh(100.0, 350.0, 400.0, 150.0)
        );
    }

    #[test]
    fn the_seam_spans_the_slabs_inner_edge_in_full() {
        let rect = Rect::xywh(100.0, 200.0, 400.0, 300.0);
        for edge in PaneDropEdge::ALL {
            let slab = slab_rect(rect, edge);
            let size = seam_size(slab, edge);
            let center = seam_center(slab, edge);
            match edge {
                PaneDropEdge::Left | PaneDropEdge::Right => {
                    assert!((size.width - RESPLIT_SEAM_THICKNESS).abs() < 1e-9);
                    assert!((size.height - slab.size.height).abs() < 1e-9);
                    assert!((center.y - slab.mid_y()).abs() < 1e-9);
                },
                PaneDropEdge::Top | PaneDropEdge::Bottom => {
                    assert!((size.height - RESPLIT_SEAM_THICKNESS).abs() < 1e-9);
                    assert!((size.width - slab.size.width).abs() < 1e-9);
                    assert!((center.x - slab.mid_x()).abs() < 1e-9);
                },
            }
        }
    }

    #[test]
    fn the_seam_sits_on_the_boundary_facing_the_rest_of_the_target() {
        let rect = Rect::xywh(0.0, 0.0, 400.0, 300.0);
        // A LEFT drop takes the left half, so its divider is on that half's RIGHT edge — the
        // mirror. Getting this backwards would draw the seam on the outer wall of the window.
        assert!(
            (seam_center(slab_rect(rect, PaneDropEdge::Left), PaneDropEdge::Left).x - 200.0).abs() < 1e-9
        );
        assert!(
            (seam_center(slab_rect(rect, PaneDropEdge::Right), PaneDropEdge::Right).x - 200.0).abs() < 1e-9
        );
        assert!((seam_center(slab_rect(rect, PaneDropEdge::Top), PaneDropEdge::Top).y - 150.0).abs() < 1e-9);
        assert!(
            (seam_center(slab_rect(rect, PaneDropEdge::Bottom), PaneDropEdge::Bottom).y - 150.0).abs() < 1e-9
        );
    }

    #[test]
    fn the_rail_spans_the_container_edge_and_is_capped() {
        let container = wide();
        // min(48, min(2000, 1000) · 0.12) = min(48, 120) = 48.
        assert_eq!(
            rail_rect(container, PaneDropEdge::Left),
            Rect::xywh(0.0, 0.0, 48.0, 1000.0)
        );
        assert_eq!(
            rail_rect(container, PaneDropEdge::Right),
            Rect::xywh(1952.0, 0.0, 48.0, 1000.0)
        );
        assert_eq!(
            rail_rect(container, PaneDropEdge::Top),
            Rect::xywh(0.0, 0.0, 2000.0, 48.0)
        );
        assert_eq!(
            rail_rect(container, PaneDropEdge::Bottom),
            Rect::xywh(0.0, 952.0, 2000.0, 48.0)
        );
    }

    #[test]
    fn every_point_that_resolves_to_a_dock_lies_inside_the_rail_it_draws() {
        // The one property that ties the two halves of this file together. Resolution and preview
        // are separate arithmetic over separate constants, so nothing but this stops them drifting
        // into a canvas that docks from 28 pt in while drawing a band that starts at 12.
        for container in [
            wide(),
            Rect::xywh(0.0, 0.0, 800.0, 600.0),
            Rect::xywh(0.0, 0.0, 200.0, 100.0),
            Rect::xywh(-50.0, 30.0, 640.0, 480.0),
        ] {
            let probes = [
                Point::new(container.min_x() + 0.5, container.mid_y()),
                Point::new(container.max_x() - 0.5, container.mid_y()),
                Point::new(container.mid_x(), container.min_y() + 0.5),
                Point::new(container.mid_x(), container.max_y() - 0.5),
            ];
            for probe in probes {
                let resolved = container_edge(probe, container, None);
                assert!(
                    resolved.is_some(),
                    "a point half a point inside {container:?} resolved to no dock edge",
                );
                let Some(edge) = resolved else { continue };
                let rail = rail_rect(container, edge);
                assert!(
                    probe.x >= rail.min_x()
                        && probe.x <= rail.max_x()
                        && probe.y >= rail.min_y()
                        && probe.y <= rail.max_y(),
                    "{probe:?} docks {edge:?} in {container:?} but falls outside its own rail",
                );
            }
        }
    }

    #[test]
    fn opposed_slabs_partition_the_target_exactly() {
        // What makes the preview honest about a re-split: the op produces two children that
        // partition their parent, so a slab at any other fraction promises a ratio the tree never
        // lands on.
        let target = Rect::xywh(100.0, 200.0, 400.0, 300.0);
        let columns = (
            slab_rect(target, PaneDropEdge::Left),
            slab_rect(target, PaneDropEdge::Right),
        );
        assert!(
            (columns.0.max_x() - columns.1.min_x()).abs() < 1e-9,
            "no gap, no overlap"
        );
        assert!((columns.0.min_x() - target.min_x()).abs() < 1e-9);
        assert!((columns.1.max_x() - target.max_x()).abs() < 1e-9);
        let rows = (
            slab_rect(target, PaneDropEdge::Top),
            slab_rect(target, PaneDropEdge::Bottom),
        );
        assert!(
            (rows.0.max_y() - rows.1.min_y()).abs() < 1e-9,
            "no gap, no overlap"
        );
        assert!((rows.0.min_y() - target.min_y()).abs() < 1e-9);
        assert!((rows.1.max_y() - target.max_y()).abs() < 1e-9);
        // The seam both halves of an axis draw is the SAME line — the divider lands there whichever
        // side the pane was dropped on, which is the target's own midline.
        assert_eq!(
            seam_center(columns.0, PaneDropEdge::Left),
            seam_center(columns.1, PaneDropEdge::Right)
        );
        assert_eq!(
            seam_center(rows.0, PaneDropEdge::Top),
            seam_center(rows.1, PaneDropEdge::Bottom)
        );
    }

    #[test]
    fn a_degenerate_container_draws_a_zero_rail() {
        // The same fail-quiet the gutter takes: a canvas is momentarily zero-sized on its first
        // layout pass, and dividing by that area would put a NaN in a frame.
        assert_eq!(rail_rect(Rect::default(), PaneDropEdge::Left), Rect::default());
        let flat = Rect::xywh(0.0, 0.0, 0.0, 600.0);
        assert!((rail_rect(flat, PaneDropEdge::Top).size.height - 0.0).abs() < 1e-9);
    }

    #[test]
    fn the_rail_is_wider_than_the_gutter_it_previews_on_a_small_canvas() {
        // Small enough that BOTH terms are the fraction rather than the cap — the relationship has
        // to hold there too, not only where the two caps do the talking.
        let small = Rect::xywh(0.0, 0.0, 200.0, 200.0);
        let rail = rail_rect(small, PaneDropEdge::Left).size.width;
        let gutter = CONTAINER_GUTTER_MAX.min(200.0 * CONTAINER_GUTTER_FRACTION);
        assert!((rail - 24.0).abs() < 1e-9);
        assert!(rail > gutter);
    }
}
