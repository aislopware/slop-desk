//! The three arrange commands, as rules over FRAMES rather than over a plane.
//!
//! Align, distribute and tidy read a pane's id and its frame and write a frame. They never look at
//! a spec, a group, a z or a camera — so they are stated here over `(id, rect)` pairs, and
//! [`Canvas`](crate::Canvas) projects into them rather than carrying the whole document through the
//! arithmetic.
//!
//! That is what lets the same body serve both callers. The plane's own methods delegate here, and
//! so does the FFI shim, which has only the projection to hand: there is one implementation of
//! "aligned to a shared edge", not one per caller.
//!
//! Each answers a map of the frames that MOVED, so a caller applies it by lookup and a pane nobody
//! named is untouched by construction rather than by a copy that happened to reproduce it.

use std::collections::BTreeMap;

use crate::canvas::{AlignEdge, clamping};
use crate::geometry::{DEFAULT_ITEM_SIZE, MIN_ITEM_SIZE, sanitize};
use crate::identity::PaneId;
use crate::{Point, Rect};

/// The named panes aligned to a shared edge or centre of THEIR bounding box.
///
/// Only the moved axis changes: the perpendicular position and every size stay put. Fewer than two
/// targets moves nothing, because a single pane's bounding box is itself and aligning it to itself
/// would churn the document to no effect.
#[must_use]
pub fn aligned(targets: &[(PaneId, Rect)], edge: AlignEdge) -> BTreeMap<PaneId, Rect> {
    let mut moved = BTreeMap::new();
    let Some(((_, first), rest)) = targets.split_first() else {
        return moved;
    };
    if rest.is_empty() {
        return moved;
    }
    let box_rect = rest.iter().fold(*first, |acc, (_, frame)| acc.union(*frame));
    for (id, frame) in targets {
        let size = frame.size;
        let origin = match edge {
            AlignEdge::Left => Point::new(box_rect.min_x(), frame.min_y()),
            AlignEdge::Right => Point::new(box_rect.max_x() - size.width, frame.min_y()),
            AlignEdge::Top => Point::new(frame.min_x(), box_rect.min_y()),
            AlignEdge::Bottom => Point::new(frame.min_x(), box_rect.max_y() - size.height),
            AlignEdge::CenterHorizontal => Point::new(box_rect.mid_x() - size.width / 2.0, frame.min_y()),
            AlignEdge::CenterVertical => Point::new(frame.min_x(), box_rect.mid_y() - size.height / 2.0),
        };
        moved.insert(*id, sanitize(Rect::new(origin, size)));
    }
    moved
}

/// The named panes spread so the GAPS between adjacent ones are equal.
///
/// The two extremes stay put and the interior panes move, which is what makes the operation feel
/// like an adjustment rather than a re-layout. Fewer than three targets moves nothing — there is
/// nothing interior to redistribute.
///
/// When the panes are collectively wider than their spread the even gap would be NEGATIVE, which
/// would overlap them silently. It is clamped at zero instead, so they pack flush and the trailing
/// extreme shifts rather than the panes overlapping — the plane's own non-overlap ethos applied to
/// an arrange command.
#[must_use]
pub fn distributed(targets: &[(PaneId, Rect)], horizontal: bool) -> BTreeMap<PaneId, Rect> {
    let mut moved = BTreeMap::new();
    if targets.len() < 3 {
        return moved;
    }
    let mut ordered: Vec<(PaneId, Rect)> = targets.to_vec();
    // Ties break by id so the spread is a function of the SET, not of the order it arrived in — two
    // panes with the same leading edge must not swap places depending on how the caller iterated.
    ordered.sort_by(|(left_id, left), (right_id, right)| {
        let lead = if horizontal {
            left.min_x().total_cmp(&right.min_x())
        } else {
            left.min_y().total_cmp(&right.min_y())
        };
        lead.then_with(|| left_id.cmp(right_id))
    });
    let (Some((_, first)), Some((_, last))) = (ordered.first(), ordered.last()) else {
        return moved;
    };
    let span = if horizontal {
        last.max_x() - first.min_x()
    } else {
        last.max_y() - first.min_y()
    };
    let extent = |frame: &Rect| {
        if horizontal {
            frame.size.width
        } else {
            frame.size.height
        }
    };
    let sum: f64 = ordered.iter().map(|(_, frame)| extent(frame)).sum();
    let slots = ordered.len().saturating_sub(1);
    let divisor = if slots == 0 { 1.0 } else { slots_as_f64(slots) };
    let gap = ((span - sum) / divisor).max(0.0);
    let mut cursor = if horizontal { first.min_x() } else { first.min_y() };
    for (id, frame) in &ordered {
        let origin = if horizontal {
            Point::new(cursor, frame.min_y())
        } else {
            Point::new(frame.min_x(), cursor)
        };
        moved.insert(*id, sanitize(Rect::new(origin, frame.size)));
        cursor += extent(frame) + gap;
    }
    moved
}

/// A slot count as a divisor. Bounded by the item count, so the conversion is exact for any plane a
/// person could build.
fn slots_as_f64(slots: usize) -> f64 {
    u32::try_from(slots).map_or(f64::MAX, f64::from)
}

/// Every pane packed into a square grid at the plane's origin, in the order given.
///
/// The ORDER is the caller's, not a sort: tidy should preserve whatever sequence the plane already
/// reads in, so a board someone arranged left-to-right tidies into the same reading order.
///
/// The camera is NOT this function's business — the plane re-centres afterwards, which is a
/// separate decision and one a caller may not want.
#[must_use]
pub fn tidied(items: &[(PaneId, Rect)], gutter: f64) -> BTreeMap<PaneId, Rect> {
    let mut moved = BTreeMap::new();
    if items.len() < 2 {
        return moved;
    }
    // The square grid's column count, as the smallest `cols` with `cols² ≥ count`. Computed by
    // integer growth rather than `ceil(sqrt(n))` so it needs no float round-trip to be exact.
    let mut cols = 1_usize;
    while cols.saturating_mul(cols) < items.len() {
        cols += 1;
    }
    // The widest and tallest pane set the cell, so no pane is clipped by its own cell. The default
    // size is only the empty-plane fallback, never a floor: making it a floor would space a board of
    // small panes out as though they were all default-sized.
    let widest = items
        .iter()
        .map(|(_, frame)| frame.size.width)
        .fold(f64::NEG_INFINITY, f64::max);
    let tallest = items
        .iter()
        .map(|(_, frame)| frame.size.height)
        .fold(f64::NEG_INFINITY, f64::max);
    let cell_width = if widest.is_finite() {
        widest
    } else {
        DEFAULT_ITEM_SIZE.width
    } + gutter;
    let cell_height = if tallest.is_finite() {
        tallest
    } else {
        DEFAULT_ITEM_SIZE.height
    } + gutter;
    let (mut col, mut row) = (0_u32, 0_u32);
    for (id, frame) in items {
        let origin = Point::new(f64::from(col) * cell_width, f64::from(row) * cell_height);
        moved.insert(*id, sanitize(Rect::new(origin, frame.size)));
        col += 1;
        if usize::try_from(col).unwrap_or(usize::MAX) >= cols {
            col = 0;
            row += 1;
        }
    }
    moved
}

/// A group's members affinely remapped from their own bounding box into a new one.
///
/// Each member's offset within the box and its size scale by the per-axis ratio, so the group's
/// footprint becomes `proposed` while the relative layout inside it is preserved. The old box is
/// derived from the members rather than passed in — it is a function of them, and a caller that
/// computed it separately could hand over one that no longer matches.
///
/// The box is FLOORED at the minimum pane size and every member is clamped back inside it. A group
/// box can never be smaller than a single pane: members floor at that size, so scaling toward a
/// sub-floor box would force them LARGER than the box and spill them outside it — which corrupts
/// the non-overlap solver, since it moves a group as one rigid body from that box.
///
/// Nothing moves for an empty or degenerate group: a zero-extent box has no ratio to scale by.
#[must_use]
pub fn resized_group(members: &[(PaneId, Rect)], proposed: Rect) -> BTreeMap<PaneId, Rect> {
    let mut moved = BTreeMap::new();
    let Some(old_box) = bounding_box(&members.iter().map(|(_, frame)| *frame).collect::<Vec<_>>()) else {
        return moved;
    };
    if old_box.size.width <= 0.0 || old_box.size.height <= 0.0 {
        return moved;
    }
    let new_box = Rect::xywh(
        proposed.min_x(),
        proposed.min_y(),
        proposed.size.width.max(MIN_ITEM_SIZE.width),
        proposed.size.height.max(MIN_ITEM_SIZE.height),
    );
    let scale_x = new_box.size.width / old_box.size.width;
    let scale_y = new_box.size.height / old_box.size.height;
    for (id, frame) in members {
        let scaled = sanitize(Rect::xywh(
            new_box.min_x() + (frame.min_x() - old_box.min_x()) * scale_x,
            new_box.min_y() + (frame.min_y() - old_box.min_y()) * scale_y,
            frame.size.width * scale_x,
            frame.size.height * scale_y,
        ));
        moved.insert(*id, clamping(scaled, new_box));
    }
    moved
}

/// The box containing every frame given, or `None` when there are none.
#[must_use]
pub fn bounding_box(frames: &[Rect]) -> Option<Rect> {
    let (first, rest) = frames.split_first()?;
    Some(rest.iter().fold(*first, |acc, frame| acc.union(*frame)))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::indexing_slicing,
        reason = "the fixtures are exact integer literals, so a tolerance would pass on the drift the \
                  assertion exists to catch — and a missing key is the failure, not a panic to be dressed \
                  up as one"
    )]

    use super::{aligned, distributed, resized_group, tidied};
    use crate::canvas::{AlignEdge, clamping};
    use crate::geometry::MIN_ITEM_SIZE;
    use crate::identity::PaneId;
    use crate::{Point, Rect, Size};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn at(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect::new(Point::new(x, y), Size::new(width, height))
    }

    /// The point of a group resize: the box becomes what was asked for and the layout INSIDE it
    /// survives, rather than the members being re-flowed into the new footprint.
    #[test]
    fn resizing_a_group_preserves_its_internal_layout() {
        let moved = resized_group(
            &[
                (pane(1), at(0.0, 0.0, 400.0, 400.0)),
                (pane(2), at(400.0, 0.0, 400.0, 400.0)),
            ],
            at(0.0, 0.0, 1600.0, 400.0),
        );
        assert_eq!(moved[&pane(1)], at(0.0, 0.0, 800.0, 400.0));
        assert_eq!(moved[&pane(2)], at(800.0, 0.0, 800.0, 400.0));
    }

    /// Members floor at the minimum pane size, so a box asked to go below it would otherwise hold
    /// panes LARGER than itself — and the non-overlap solver, which drags the group as one rigid
    /// body from that box, would sweep a body that is not where the box says it is.
    #[test]
    fn a_sub_floor_group_box_never_spills_its_members_outside_it() {
        let moved = resized_group(
            &[
                (pane(1), at(0.0, 0.0, 400.0, 400.0)),
                (pane(2), at(400.0, 0.0, 400.0, 400.0)),
            ],
            at(0.0, 0.0, 1.0, 1.0),
        );
        let floor = at(0.0, 0.0, MIN_ITEM_SIZE.width, MIN_ITEM_SIZE.height);
        for byte in [1_u8, 2] {
            let frame = moved[&pane(byte)];
            assert_eq!(
                clamping(frame, floor),
                frame,
                "every member stays inside the floored box"
            );
        }
    }

    /// A group with no members and one with no extent both have no ratio to scale by. Answering an
    /// empty map rather than a frame keeps "nothing moved" distinct from "moved to where it was".
    #[test]
    fn an_empty_or_flat_group_moves_nothing() {
        assert!(resized_group(&[], at(0.0, 0.0, 400.0, 400.0)).is_empty());
        assert!(
            resized_group(
                &[(pane(1), at(10.0, 10.0, 0.0, 50.0))],
                at(0.0, 0.0, 400.0, 400.0)
            )
            .is_empty()
        );
    }

    /// One pane's bounding box is itself, so aligning it moves nothing — and the caller must see
    /// that as "nothing moved" rather than as a frame that happens to equal the old one.
    #[test]
    fn a_lone_pane_has_nothing_to_align_to() {
        assert!(aligned(&[(pane(1), at(10.0, 10.0, 100.0, 100.0))], AlignEdge::Left).is_empty());
    }

    /// The perpendicular axis is untouched: a left-align slides panes horizontally and must not
    /// quietly stack them vertically as well.
    #[test]
    fn aligning_moves_one_axis_only() {
        let moved = aligned(
            &[
                (pane(1), at(10.0, 10.0, 100.0, 50.0)),
                (pane(2), at(80.0, 200.0, 40.0, 50.0)),
            ],
            AlignEdge::Left,
        );
        assert_eq!(moved[&pane(2)].min_x(), 10.0, "flush to the box's left edge");
        assert_eq!(moved[&pane(2)].min_y(), 200.0, "and nowhere else");
    }

    /// Panes wider than their own spread would need a negative gap. Packing them flush is the
    /// answer; overlapping them silently is not.
    #[test]
    fn an_impossible_spread_packs_flush_rather_than_overlapping() {
        let moved = distributed(
            &[
                (pane(1), at(0.0, 0.0, 100.0, 10.0)),
                (pane(2), at(10.0, 0.0, 100.0, 10.0)),
                (pane(3), at(20.0, 0.0, 100.0, 10.0)),
            ],
            true,
        );
        assert_eq!(moved[&pane(1)].min_x(), 0.0);
        assert_eq!(moved[&pane(2)].min_x(), 100.0, "flush, not overlapped");
        assert_eq!(moved[&pane(3)].min_x(), 200.0);
    }

    /// Five panes want three columns, because four would leave a row of one and two would make a
    /// column taller than the screen.
    #[test]
    fn tidy_grows_the_grid_to_the_smallest_square_that_fits() {
        let items: Vec<(PaneId, Rect)> = (1..=5)
            .map(|byte| (pane(byte), at(0.0, 0.0, 100.0, 100.0)))
            .collect();
        let moved = tidied(&items, 10.0);
        assert_eq!(moved[&pane(1)].origin, Point::new(0.0, 0.0));
        assert_eq!(moved[&pane(3)].origin, Point::new(220.0, 0.0), "third column");
        assert_eq!(moved[&pane(4)].origin, Point::new(0.0, 110.0), "and then wrap");
    }
}
