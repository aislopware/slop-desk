//! Turning a split tree into rectangles: the flex-weight partition, and the solved geometry both
//! the renderer and the focus resolver read.
//!
//! ## One geometry, two readers
//!
//! [`SolvedLayout`] is the single source of truth for where a pane is. The renderer draws from it
//! and the focus resolver navigates by it, which is the whole reason "move focus left" can never
//! disagree with the pane the person actually sees to the left. Two solvers would be two answers.
//!
//! ## Fixed bands are reserved before flex divides
//!
//! A fixed child takes its points off the top, clamped against a RUNNING remainder so no band can
//! overrun the bound and two bands can never overlap. Whatever is left is what the flex children
//! divide, in proportion to their weights. The reserved extent is recorded in the first pass and
//! reused verbatim in the second — emitting the same per-child share rather than re-deriving it —
//! because two derivations of the same number is exactly how they come to differ.

use std::collections::BTreeMap;

use crate::geometry::{Rect, Size};
use crate::identity::PaneId;
use crate::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

/// The smallest a leaf is ever solved to.
///
/// The clamp is a FLOOR, not a fit: when the bound genuinely cannot hold every sibling the rects
/// overflow it rather than collapsing a pane to nothing, because a pane with no area is a pane that
/// cannot be clicked to be closed.
pub const DEFAULT_MIN_LEAF: Size = Size::new(160.0, 120.0);

/// Every pane's exact rectangle.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SolvedLayout {
    /// The frames, keyed by pane. Ordered by id, so any iteration of it is deterministic.
    pub frames: BTreeMap<PaneId, Rect>,
}

impl SolvedLayout {
    /// No panes — the degenerate base case.
    #[must_use]
    pub fn empty() -> Self {
        Self::default()
    }

    /// One pane's frame.
    #[must_use]
    pub fn frame_of(&self, pane: PaneId) -> Option<Rect> {
        self.frames.get(&pane).copied()
    }

    /// Whether anything was solved.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}

/// Solves a tree inside a bound.
///
/// Total: a finite bound yields finite rects for exactly the tree's panes, and every leaf's extents
/// are floored at `min_leaf`.
#[must_use]
pub fn solve(root: &SplitNode, rect: Rect, min_leaf: Size) -> SolvedLayout {
    let mut layout = SolvedLayout::empty();
    place(root, rect, min_leaf, &mut layout.frames);
    layout
}

/// The same solve at the standard floor.
#[must_use]
pub fn solve_default(root: &SplitNode, rect: Rect) -> SolvedLayout {
    solve(root, rect, DEFAULT_MIN_LEAF)
}

fn place(node: &SplitNode, rect: Rect, min_leaf: Size, into: &mut BTreeMap<PaneId, Rect>) {
    match node {
        SplitNode::Leaf(id) => {
            into.insert(*id, clamp_leaf(rect, min_leaf));
        },
        SplitNode::Split { axis, children, .. } => {
            if children.is_empty() {
                return;
            }
            let lengths = extents(children, axis_length(rect, *axis));
            let mut cursor = axis_origin(rect, *axis);
            for (child, extent) in children.iter().zip(lengths) {
                place(&child.node, sub_rect(rect, *axis, cursor, extent), min_leaf, into);
                cursor += extent;
            }
        },
    }
}

/// Each child's extent along the split axis, within a total length.
///
/// Public because the divider handles have to land on the SAME seams the solver tiles to; a second
/// copy of this partition would drift from it the first time either changed.
#[must_use]
pub fn extents(children: &[WeightedChild], total: f64) -> Vec<f64> {
    // Pass one reserves the fixed bands against a running remainder and records each one.
    let mut fixed_total = 0.0;
    let mut flex_sum = 0.0;
    let mut flex_count = 0_u32;
    let mut reserved: Vec<Option<f64>> = Vec::with_capacity(children.len());
    for child in children {
        match child.weight {
            SplitWeight::Fixed(points) => {
                let remaining = (total - fixed_total).max(0.0);
                let extent = points.max(0.0).min(remaining);
                reserved.push(Some(extent));
                fixed_total += extent;
            },
            SplitWeight::Flex(weight) => {
                reserved.push(None);
                flex_sum += weight.max(0.0);
                flex_count += 1;
            },
        }
    }

    let flex_budget = (total - fixed_total).max(0.0);
    children
        .iter()
        .zip(reserved)
        .map(|(child, reserved)| {
            match child.weight {
                // The per-child reserved extent, never the whole bound: that is what keeps fixed bands
                // tiling instead of stacking on top of each other.
                SplitWeight::Fixed(_) => reserved.unwrap_or(0.0),
                SplitWeight::Flex(weight) => {
                    if flex_sum > 0.0 {
                        let share = flex_budget * weight.max(0.0);
                        share / flex_sum
                    } else if flex_count > 0 {
                        // Every flex weight collapsed to zero: an equal split, so no pane vanishes.
                        flex_budget / f64::from(flex_count)
                    } else {
                        0.0
                    }
                },
            }
        })
        .collect()
}

const fn axis_length(rect: Rect, axis: SplitAxis) -> f64 {
    match axis {
        SplitAxis::Horizontal => rect.size.width,
        SplitAxis::Vertical => rect.size.height,
    }
}

const fn axis_origin(rect: Rect, axis: SplitAxis) -> f64 {
    match axis {
        SplitAxis::Horizontal => rect.min_x(),
        SplitAxis::Vertical => rect.min_y(),
    }
}

/// A child rect at an offset along the axis; the cross axis spans the whole parent.
const fn sub_rect(rect: Rect, axis: SplitAxis, origin: f64, extent: f64) -> Rect {
    match axis {
        SplitAxis::Horizontal => Rect::xywh(origin, rect.min_y(), extent, rect.size.height),
        SplitAxis::Vertical => Rect::xywh(rect.min_x(), origin, rect.size.width, extent),
    }
}

/// A leaf's rect with its extents floored, and any non-finite value replaced rather than forwarded
/// — a NaN that reaches the renderer takes the whole frame with it.
const fn clamp_leaf(rect: Rect, min_leaf: Size) -> Rect {
    let width = if rect.size.width.is_finite() {
        rect.size.width.max(min_leaf.width)
    } else {
        min_leaf.width
    };
    let height = if rect.size.height.is_finite() {
        rect.size.height.max(min_leaf.height)
    } else {
        min_leaf.height
    };
    let x = if rect.min_x().is_finite() {
        rect.min_x()
    } else {
        0.0
    };
    let y = if rect.min_y().is_finite() {
        rect.min_y()
    } else {
        0.0
    };
    Rect::xywh(x, y, width, height)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        clippy::panic,
        reason = "the extents are exact divisions of the fixtures' own bound, and a missing frame is a test \
                  failure with nothing to return"
    )]

    use super::{DEFAULT_MIN_LEAF, extents, solve, solve_default};
    use crate::geometry::Rect;
    use crate::identity::{PaneId, SplitNodeId};
    use crate::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn row(children: Vec<WeightedChild>) -> SplitNode {
        SplitNode::Split {
            id: SplitNodeId::from_bytes([1; 16]),
            axis: SplitAxis::Horizontal,
            children,
        }
    }

    fn bound() -> Rect {
        Rect::xywh(0.0, 0.0, 1000.0, 600.0)
    }

    fn frame(layout: &super::SolvedLayout, id: PaneId) -> Rect {
        let Some(rect) = layout.frame_of(id) else {
            panic!("pane {id:?} was not solved");
        };
        rect
    }

    #[test]
    fn a_lone_leaf_takes_the_whole_bound() {
        let layout = solve_default(&SplitNode::Leaf(pane(1)), bound());
        assert_eq!(frame(&layout, pane(1)), bound());
    }

    #[test]
    fn equal_weights_divide_the_axis_equally_and_span_the_other() {
        let tree = row(vec![WeightedChild::leaf(pane(1)), WeightedChild::leaf(pane(2))]);
        let layout = solve_default(&tree, bound());
        assert_eq!(frame(&layout, pane(1)), Rect::xywh(0.0, 0.0, 500.0, 600.0));
        assert_eq!(frame(&layout, pane(2)), Rect::xywh(500.0, 0.0, 500.0, 600.0));
    }

    #[test]
    fn the_partition_is_proportional_to_the_weights() {
        let tree = row(vec![
            WeightedChild::new(SplitWeight::Flex(3.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        let layout = solve_default(&tree, bound());
        assert_eq!(frame(&layout, pane(1)).size.width, 750.0);
        assert_eq!(frame(&layout, pane(2)).size.width, 250.0);
    }

    #[test]
    fn a_vertical_split_partitions_the_height() {
        let tree = SplitNode::Split {
            id: SplitNodeId::from_bytes([1; 16]),
            axis: SplitAxis::Vertical,
            children: vec![WeightedChild::leaf(pane(1)), WeightedChild::leaf(pane(2))],
        };
        let layout = solve_default(&tree, bound());
        assert_eq!(frame(&layout, pane(1)), Rect::xywh(0.0, 0.0, 1000.0, 300.0));
        assert_eq!(frame(&layout, pane(2)), Rect::xywh(0.0, 300.0, 1000.0, 300.0));
    }

    #[test]
    fn a_fixed_band_is_reserved_before_the_flex_children_divide() {
        let tree = row(vec![
            WeightedChild::new(SplitWeight::Fixed(200.0), SplitNode::Leaf(pane(1))),
            WeightedChild::leaf(pane(2)),
            WeightedChild::leaf(pane(3)),
        ]);
        let layout = solve_default(&tree, bound());
        assert_eq!(frame(&layout, pane(1)).size.width, 200.0);
        assert_eq!(frame(&layout, pane(2)).size.width, 400.0);
        assert_eq!(frame(&layout, pane(3)).size.width, 400.0);
    }

    #[test]
    fn fixed_bands_tile_instead_of_overrunning_the_bound() {
        let children = vec![
            WeightedChild::new(SplitWeight::Fixed(700.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Fixed(700.0), SplitNode::Leaf(pane(2))),
        ];
        // The second band is clamped by what the first left, so the sum is the bound exactly.
        assert_eq!(extents(&children, 1000.0), vec![700.0, 300.0]);
    }

    #[test]
    fn a_negative_fixed_extent_reserves_nothing() {
        let children = vec![
            WeightedChild::new(SplitWeight::Fixed(-50.0), SplitNode::Leaf(pane(1))),
            WeightedChild::leaf(pane(2)),
        ];
        assert_eq!(extents(&children, 1000.0), vec![0.0, 1000.0]);
    }

    #[test]
    fn all_zero_flex_weights_fall_back_to_an_equal_split() {
        let children = vec![
            WeightedChild::new(SplitWeight::Flex(0.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(0.0), SplitNode::Leaf(pane(2))),
        ];
        assert_eq!(extents(&children, 1000.0), vec![500.0, 500.0], "no pane vanishes");
    }

    #[test]
    fn a_leaf_is_floored_rather_than_collapsed_when_the_bound_cannot_hold_it() {
        let tree = row(vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
            WeightedChild::leaf(pane(3)),
        ]);
        let layout = solve(&tree, Rect::xywh(0.0, 0.0, 90.0, 600.0), DEFAULT_MIN_LEAF);
        assert_eq!(
            frame(&layout, pane(1)).size.width,
            DEFAULT_MIN_LEAF.width,
            "the rects overflow the bound rather than leaving a pane unclickable",
        );
    }

    #[test]
    fn a_non_finite_bound_never_reaches_the_renderer() {
        let layout = solve_default(
            &SplitNode::Leaf(pane(1)),
            Rect::xywh(f64::NAN, 0.0, f64::NAN, 600.0),
        );
        let solved = frame(&layout, pane(1));
        assert_eq!(solved.min_x(), 0.0);
        assert_eq!(solved.size.width, DEFAULT_MIN_LEAF.width);
        assert_eq!(solved.size.height, 600.0);
    }

    #[test]
    fn a_nested_split_tiles_within_its_parents_share() {
        let inner = SplitNode::Split {
            id: SplitNodeId::from_bytes([2; 16]),
            axis: SplitAxis::Vertical,
            children: vec![WeightedChild::leaf(pane(2)), WeightedChild::leaf(pane(3))],
        };
        let tree = row(vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::new(SplitWeight::Flex(1.0), inner),
        ]);
        let layout = solve_default(&tree, bound());
        assert_eq!(frame(&layout, pane(2)), Rect::xywh(500.0, 0.0, 500.0, 300.0));
        assert_eq!(frame(&layout, pane(3)), Rect::xywh(500.0, 300.0, 500.0, 300.0));
    }

    #[test]
    fn exactly_the_trees_panes_are_solved() {
        let tree = row(vec![WeightedChild::leaf(pane(1)), WeightedChild::leaf(pane(2))]);
        let layout = solve_default(&tree, bound());
        assert_eq!(layout.frames.len(), 2);
        assert!(layout.frame_of(pane(9)).is_none());
    }
}
