//! Where a dragged PANE lands over another one, and the rectangles that promise it, in C.
//!
//! The rules are `slopdesk_workspace::pane_drop`'s. Every one is a handful of `f64`s in and a
//! point, a size, a rect or an edge code out, so nothing crosses through a buffer — and the
//! vocabulary is [`crate::video_policy`]'s point/size/rect, the same words
//! [`crate::device_geometry`] already borrows. A second rect struct for pane space would mean two
//! ABI shapes with identical fields, and a Swift face that converted between them for no reason.
//!
//! ## Why an edge is a code and not a byte
//!
//! `PaneDropEdge` has an on-wire byte already, and it is deliberately NOT what crosses here. That
//! byte is total — every value names an edge, `from_byte` defaults unknowns to the leading one —
//! because a wire peer that garbles a dock should still leave the pane on screen. This door has to
//! carry a fifth answer the wire never does: [`SLOPDESK_PANE_DROP_EDGE_NONE`], the cursor being in
//! no gutter at all. Folding that into the same byte space would make "no dock" indistinguishable
//! from a corrupt "dock left".
//!
//! ## The metrics come through a door too
//!
//! Six tuned numbers, by index. They could have been six `#define`s in the header, and that is
//! exactly the failure this avoids: a literal in the header is a SECOND place the affordance is
//! written down, free to drift from the Rust the resolver actually runs. One door, one table.

use slopdesk_tree::PaneDropEdge;
use slopdesk_tree::geometry::{Point, Rect, Size};
use slopdesk_workspace::pane_drop;

use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

/// The leading edge, forming columns.
pub const SLOPDESK_PANE_DROP_EDGE_LEFT: u32 = 0;
/// The trailing edge, forming columns.
pub const SLOPDESK_PANE_DROP_EDGE_RIGHT: u32 = 1;
/// The top edge, forming rows.
pub const SLOPDESK_PANE_DROP_EDGE_TOP: u32 = 2;
/// The bottom edge, forming rows.
pub const SLOPDESK_PANE_DROP_EDGE_BOTTOM: u32 = 3;
/// No edge — the cursor is in no gutter. Only [`slopdesk_pane_drop_container_edge`] answers this.
pub const SLOPDESK_PANE_DROP_EDGE_NONE: u32 = 4;

/// Each edge band as a fraction of the target, leaving the middle as the swap box.
pub const SLOPDESK_PANE_DROP_METRIC_EDGE_BAND_FRACTION: u32 = 0;
/// The container dock gutter's fraction of the smaller dimension.
pub const SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_FRACTION: u32 = 1;
/// The cap on that gutter, in points.
pub const SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_MAX: u32 = 2;
/// The dock preview rail's fraction of the smaller dimension.
pub const SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_FRACTION: u32 = 3;
/// The cap on that rail, in points.
pub const SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_MAX: u32 = 4;
/// The re-split preview seam bar's thickness, in points.
pub const SLOPDESK_PANE_DROP_METRIC_RESPLIT_SEAM_THICKNESS: u32 = 5;

/// The edge a code names, defaulting to the leading one the way the wire's own byte does.
const fn edge(code: u32) -> PaneDropEdge {
    match code {
        SLOPDESK_PANE_DROP_EDGE_RIGHT => PaneDropEdge::Right,
        SLOPDESK_PANE_DROP_EDGE_TOP => PaneDropEdge::Top,
        SLOPDESK_PANE_DROP_EDGE_BOTTOM => PaneDropEdge::Bottom,
        _ => PaneDropEdge::Left,
    }
}

/// The code an edge reports as.
const fn code(edge: PaneDropEdge) -> u32 {
    match edge {
        PaneDropEdge::Left => SLOPDESK_PANE_DROP_EDGE_LEFT,
        PaneDropEdge::Right => SLOPDESK_PANE_DROP_EDGE_RIGHT,
        PaneDropEdge::Top => SLOPDESK_PANE_DROP_EDGE_TOP,
        PaneDropEdge::Bottom => SLOPDESK_PANE_DROP_EDGE_BOTTOM,
    }
}

/// The tree crate's rect, which is the plane's own and not the video path's.
const fn rect_of(rect: SlopDeskVideoRect) -> Rect {
    Rect::xywh(rect.x, rect.y, rect.width, rect.height)
}

/// The record a rect reports as.
const fn rect_from(rect: Rect) -> SlopDeskVideoRect {
    SlopDeskVideoRect {
        x: rect.origin.x,
        y: rect.origin.y,
        width: rect.size.width,
        height: rect.size.height,
    }
}

/// One tuned drop-zone number by code. An unknown code answers `0`, which is not one of them.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_pane_drop_metric(metric: u32) -> f64 {
    pane_drop::metric(metric as usize)
}

/// The container outer edge whose gutter holds `location`, or [`SLOPDESK_PANE_DROP_EDGE_NONE`].
///
/// `source` is read only when `has_source`: the live in-tab drag passes the dragged pane's own rect
/// so an edge it already spans is skipped, and the cross-window INSERT drag passes `false` because
/// it has no pane in this tab to exclude.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_pane_drop_container_edge(
    location: SlopDeskVideoPoint,
    container: SlopDeskVideoRect,
    source: SlopDeskVideoRect,
    has_source: bool,
) -> u32 {
    pane_drop::container_edge(
        Point::new(location.x, location.y),
        rect_of(container),
        has_source.then(|| rect_of(source)),
    )
    .map_or(SLOPDESK_PANE_DROP_EDGE_NONE, code)
}

/// Whether `rect` already fully spans the container's edge, so docking there is a no-op.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_pane_drop_source_spans(
    rect: SlopDeskVideoRect,
    edge_code: u32,
    container: SlopDeskVideoRect,
) -> bool {
    pane_drop::source_spans(rect_of(rect), edge(edge_code), rect_of(container))
}

/// The edge band a cursor at normalised `u`, `v` has penetrated deepest. Always an edge — this one
/// never answers [`SLOPDESK_PANE_DROP_EDGE_NONE`].
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_pane_drop_dominant_edge(u: f64, v: f64, band: f64) -> u32 {
    code(pane_drop::dominant_edge(u, v, band))
}

/// The drop-side half of `rect` — the re-split slab the target is about to become.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_pane_drop_slab_rect(rect: SlopDeskVideoRect, edge_code: u32) -> SlopDeskVideoRect {
    rect_from(pane_drop::slab_rect(rect_of(rect), edge(edge_code)))
}

/// The seam bar's size along the slab's inner edge.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_pane_drop_seam_size(
    slab: SlopDeskVideoRect,
    edge_code: u32,
) -> SlopDeskVideoSize {
    let Size { width, height } = pane_drop::seam_size(rect_of(slab), edge(edge_code));
    SlopDeskVideoSize { width, height }
}

/// The seam bar's centre, on the slab's inner boundary.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_pane_drop_seam_center(
    slab: SlopDeskVideoRect,
    edge_code: u32,
) -> SlopDeskVideoPoint {
    let Point { x, y } = pane_drop::seam_center(rect_of(slab), edge(edge_code));
    SlopDeskVideoPoint { x, y }
}

/// The dock rail band along a whole container edge.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_pane_drop_rail_rect(
    container: SlopDeskVideoRect,
    edge_code: u32,
) -> SlopDeskVideoRect {
    rect_from(pane_drop::rail_rect(rect_of(container), edge(edge_code)))
}

#[cfg(test)]
mod tests {
    use super::{
        SLOPDESK_PANE_DROP_EDGE_LEFT, SLOPDESK_PANE_DROP_EDGE_NONE, SLOPDESK_PANE_DROP_EDGE_TOP,
        SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_MAX, SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_MAX,
        SlopDeskVideoPoint, SlopDeskVideoRect, slopdesk_pane_drop_container_edge, slopdesk_pane_drop_metric,
        slopdesk_pane_drop_rail_rect,
    };

    fn wide() -> SlopDeskVideoRect {
        SlopDeskVideoRect {
            x: 0.0,
            y: 0.0,
            width: 2000.0,
            height: 1000.0,
        }
    }

    #[test]
    fn metric_codes_name_the_numbers_the_header_promises() {
        assert!(
            (slopdesk_pane_drop_metric(SLOPDESK_PANE_DROP_METRIC_CONTAINER_GUTTER_MAX) - 28.0).abs() < 1e-9
        );
        assert!((slopdesk_pane_drop_metric(SLOPDESK_PANE_DROP_METRIC_DOCK_RAIL_MAX) - 48.0).abs() < 1e-9);
        assert!((slopdesk_pane_drop_metric(99) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn no_gutter_is_a_code_and_not_a_corrupt_left() {
        assert_eq!(
            slopdesk_pane_drop_container_edge(
                SlopDeskVideoPoint { x: 500.0, y: 500.0 },
                wide(),
                SlopDeskVideoRect::default(),
                false,
            ),
            SLOPDESK_PANE_DROP_EDGE_NONE
        );
        assert_eq!(
            slopdesk_pane_drop_container_edge(
                SlopDeskVideoPoint { x: 4.0, y: 4.0 },
                wide(),
                SlopDeskVideoRect::default(),
                false,
            ),
            SLOPDESK_PANE_DROP_EDGE_LEFT
        );
        assert_eq!(
            slopdesk_pane_drop_container_edge(
                SlopDeskVideoPoint { x: 5.0, y: 3.0 },
                wide(),
                SlopDeskVideoRect::default(),
                false,
            ),
            SLOPDESK_PANE_DROP_EDGE_TOP
        );
    }

    #[test]
    fn a_source_rect_is_read_only_when_the_flag_says_so() {
        // A full-height left column. WITH the flag the left dock is suppressed as a no-op; without
        // it the same rect is ignored entirely, which is the INSERT drag's contract.
        let source = SlopDeskVideoRect {
            x: 0.0,
            y: 0.0,
            width: 400.0,
            height: 1000.0,
        };
        let at = SlopDeskVideoPoint { x: 5.0, y: 500.0 };
        assert_eq!(
            slopdesk_pane_drop_container_edge(at, wide(), source, true),
            SLOPDESK_PANE_DROP_EDGE_NONE
        );
        assert_eq!(
            slopdesk_pane_drop_container_edge(at, wide(), source, false),
            SLOPDESK_PANE_DROP_EDGE_LEFT
        );
    }

    #[test]
    fn an_unknown_edge_code_docks_at_the_leading_edge() {
        let rail = slopdesk_pane_drop_rail_rect(wide(), 99);
        assert!((rail.x - 0.0).abs() < 1e-9);
        assert!((rail.width - 48.0).abs() < 1e-9);
    }
}
