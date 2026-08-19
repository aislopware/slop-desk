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
//!
//! ## The seams come from the same partition
//!
//! [`dividers`] descends the tree through [`extents`] rather than reading the solved frames back,
//! and carries each seam's own span and flex sum so a drag converts pixels to weights against the
//! split it actually belongs to. Everything the drag needs to stop at the pixel floor — which way
//! the seam can still move, and where a proposed weight lands — is on [`Divider`] itself, so the
//! hover cursor and the gesture read one rule rather than two.

use std::collections::BTreeMap;

use crate::geometry::{Rect, Size};
use crate::identity::{PaneId, SplitNodeId};
use crate::split_tree::{MIN_WEIGHT, SplitAxis, SplitNode, SplitWeight, WeightedChild};

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
/// The ONE partition: the tiles [`solve`] places and the seams [`dividers`] places both come from
/// it, so a handle can never end up a pixel off the edge it is supposed to drag.
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

/// The on-screen thickness of a divider's hit band, centred on the seam.
///
/// A comfortable trackpad target rather than a hairline: the drawn line can be thinner than the
/// band the person actually has to hit.
pub const DIVIDER_THICKNESS: f64 = 16.0;

/// How far past its pixel floor a child must sit before the seam counts as movable that way.
///
/// Half a point of slack, so a pane parked AT the floor reads as immovable rather than "movable by
/// 1e-13 px" — the residue repeated drags leave behind.
const PIXEL_SLACK: f64 = 0.5;

/// The same slack in the weight domain, for a handle placed without geometry.
const WEIGHT_SLACK: f64 = 0.0005;

/// A draggable seam between two adjacent siblings of one split.
///
/// Placed on the UN-clamped partition — where the cut falls, regardless of the per-leaf floor the
/// solver applies afterwards — so a handle always sits on the boundary the person sees.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Divider {
    /// The split that owns the seam.
    pub split: SplitNodeId,
    /// The LEADING child's index: the seam sits between it and `child_index + 1`.
    pub child_index: usize,
    /// The owning split's axis. A horizontal split (columns) yields a seam dragged left/right.
    pub axis: SplitAxis,
    /// The handle's band, centred on the seam and spanning the parent's cross axis.
    pub rect: Rect,
    /// The owning split's axis length — the denominator of the pixel→weight conversion. For a
    /// NESTED split this is the nested rect, not the container, so the seam tracks the cursor 1:1.
    pub parent_span: f64,
    /// The owning split's flex-weight sum, exactly as [`extents`] computes it, so the conversion
    /// lands on the same partition the tiles do.
    pub flex_sum: f64,
    /// The leading child's flex weight — the anchor a live drag reads once and offsets from. `0`
    /// for a fixed child, which is not draggable.
    pub leading_weight: f64,
    /// The trailing child's flex weight, the other half of the pair the clamp brackets. `0` fixed.
    pub trailing_weight: f64,
}

impl Divider {
    /// The pixel floor each side keeps ALONG this seam's axis: width for a column seam, height for
    /// a row seam. One source of truth with the solver's own floor, which is what keeps a dragged
    /// pane from being floored at render time and painted over by its neighbour.
    #[must_use]
    pub const fn axis_min_extent(self) -> f64 {
        match self.axis {
            SplitAxis::Horizontal => DEFAULT_MIN_LEAF.width,
            SplitAxis::Vertical => DEFAULT_MIN_LEAF.height,
        }
    }

    /// A child's on-screen extent along the axis — its flex share of the span, ignoring fixed
    /// bands exactly as the drag's pixel→weight conversion does. `0` without geometry.
    fn extent_of(self, weight: f64) -> f64 {
        if self.parent_span > 0.0 && self.flex_sum > 0.0 {
            weight / self.flex_sum * self.parent_span
        } else {
            0.0
        }
    }

    /// Whether the seam can move TOWARD the leading child — shrinking it, growing the trailing one.
    ///
    /// Dead once the leading child sits at its pixel floor, which is exactly where
    /// [`Self::clamped_leading_weight`] stops a live drag, so the hover cursor and the gesture can
    /// never disagree. A fixed neighbour (weight sentinel `0`) kills it outright.
    #[must_use]
    pub fn can_move_toward_leading(self) -> bool {
        self.can_shrink(self.leading_weight)
    }

    /// The mirror of [`Self::can_move_toward_leading`]: movable toward the TRAILING child.
    #[must_use]
    pub fn can_move_toward_trailing(self) -> bool {
        self.can_shrink(self.trailing_weight)
    }

    /// Whether the side carrying `weight` has room left to give.
    fn can_shrink(self, weight: f64) -> bool {
        if self.leading_weight <= 0.0 || self.trailing_weight <= 0.0 {
            return false;
        }
        if self.parent_span > 0.0 {
            self.extent_of(weight) > self.axis_min_extent() + PIXEL_SLACK
        } else {
            weight > MIN_WEIGHT + WEIGHT_SLACK
        }
    }

    /// An incremental pixel drag along this seam's axis, as a flex-weight delta.
    ///
    /// A flex child's on-screen extent is `span * weight / flex_sum` — see [`extents`] — so moving
    /// the seam by Δpixels needs `Δweight = Δpixel / span * flex_sum`. Without the `flex_sum`
    /// factor a 50/50 split (`flex_sum == 2`) tracks at HALF cursor speed, and a nested split —
    /// smaller span, same flex sum — under-tracks further.
    ///
    /// The seam carries its OWN span and flex sum, so the conversion can never be run against
    /// another split's partition. A handle without geometry answers `0`: the drag then sends
    /// nothing rather than a number derived from a division by zero.
    #[must_use]
    pub fn weight_delta(self, pixel_increment: f64) -> f64 {
        if !self.parent_span.is_finite()
            || self.parent_span <= 0.0
            || !self.flex_sum.is_finite()
            || self.flex_sum <= 0.0
            || !pixel_increment.is_finite()
        {
            return 0.0;
        }
        pixel_increment / self.parent_span * self.flex_sum
    }

    /// The live drag's ratio readout: the pair as whole percentages that sum to exactly 100.
    ///
    /// The trailing side is the COMPLEMENT of the rounded leading side, so the pair can never read
    /// `62 · 39`. A degenerate pair — a `Fixed` side reports weight `0`, or float residue — answers
    /// `None`, and the cue is then absent rather than wrong.
    ///
    /// Weight ratio equals on-screen extent ratio, since both sides share the same
    /// `span / flex_sum` factor, so these percentages are the pixel truth and not an approximation
    /// of it.
    #[must_use]
    pub fn split_percents(self) -> Option<(u32, u32)> {
        let (leading, trailing) = (self.leading_weight, self.trailing_weight);
        if !leading.is_finite() || !trailing.is_finite() || leading <= 0.0 || trailing <= 0.0 {
            return None;
        }
        let sum = leading + trailing;
        if sum <= 0.0 {
            return None;
        }
        // Separate divide and multiply, never fused — the readout must round the way the tests read.
        let lead = (leading / sum * 100.0).round().clamp(0.0, 100.0);
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "clamped to 0..=100 on the line above, and `round` left no fraction"
        )]
        let lead = lead as u32;
        Some((lead, 100 - lead))
    }

    /// A live drag's proposed leading weight, clamped so the pair keeps its pixel floor.
    ///
    /// The tree's own floor is RELATIVE, so on a wide parent it alone lets a drag squash a pane to
    /// an invisible sliver. The bounds BRACKET the current weight, so a pair too tight to grant
    /// both floors still behaves: a side already under it can only be GROWN — the drag works toward
    /// balance, never past it — and a pair with both sides under is frozen. Sum-preserving, and the
    /// pixel floor never drops below the weight floor. A handle without geometry passes through.
    #[must_use]
    pub fn clamped_leading_weight(self, proposed: f64) -> f64 {
        if self.parent_span <= 0.0 || self.flex_sum <= 0.0 {
            return proposed;
        }
        let pair_sum = self.leading_weight + self.trailing_weight;
        let floor_weight = (self.axis_min_extent() / self.parent_span * self.flex_sum).max(MIN_WEIGHT);
        let lower = floor_weight.min(self.leading_weight);
        let upper = (pair_sum - floor_weight).max(self.leading_weight);
        proposed.max(lower).min(upper)
    }
}

/// Every draggable seam in a tree solved into a bound, in pre-order.
///
/// The descent partitions with [`extents`] rather than reading the solved frames back, because the
/// solver FLOORS each leaf: on a bound too small to hold every sibling the floored rects overlap,
/// and a handle placed on a floored edge would sit off the seam the person is looking at.
#[must_use]
pub fn dividers(root: &SplitNode, rect: Rect, thickness: f64) -> Vec<Divider> {
    let mut found = Vec::new();
    collect_dividers(root, rect, thickness, &mut found);
    found
}

fn collect_dividers(node: &SplitNode, rect: Rect, thickness: f64, into: &mut Vec<Divider>) {
    let SplitNode::Split { id, axis, children } = node else {
        return;
    };
    if children.is_empty() {
        return;
    }
    let parent_span = axis_length(rect, *axis);
    let lengths = extents(children, parent_span);
    let flex_sum = divider_flex_sum(children);
    let mut cursor = axis_origin(rect, *axis);
    let mut child_rects = Vec::with_capacity(children.len());
    for extent in lengths {
        child_rects.push(sub_rect(rect, *axis, cursor, extent));
        cursor += extent;
    }
    for (index, (pair, rects)) in children.windows(2).zip(child_rects.windows(2)).enumerate() {
        let ([leading, trailing], [leading_rect, _]) = (pair, rects) else {
            continue;
        };
        into.push(Divider {
            split: *id,
            child_index: index,
            axis: *axis,
            rect: handle_rect(trailing_edge(*leading_rect, *axis), *axis, rect, thickness),
            parent_span,
            flex_sum,
            leading_weight: leading.weight.flex().unwrap_or(0.0),
            trailing_weight: trailing.weight.flex().unwrap_or(0.0),
        });
    }
    for (child, child_rect) in children.iter().zip(child_rects) {
        collect_dividers(&child.node, child_rect, thickness, into);
    }
}

/// The flex-weight sum the pixel→weight conversion divides by — the same quantity [`extents`] uses:
/// the sum of the non-negative flex weights, or the flex-child COUNT when that sum is zero (the
/// equal-split fallback). `1` when nothing flexes, since there is no seam to drag in that case.
fn divider_flex_sum(children: &[WeightedChild]) -> f64 {
    let mut sum = 0.0;
    let mut count = 0_u32;
    for child in children {
        if let Some(weight) = child.weight.flex() {
            sum += weight.max(0.0);
            count += 1;
        }
    }
    if sum > 0.0 {
        sum
    } else if count > 0 {
        f64::from(count)
    } else {
        1.0
    }
}

/// The coordinate of a rect's trailing edge along the axis — the seam it shares with the next
/// sibling.
const fn trailing_edge(rect: Rect, axis: SplitAxis) -> f64 {
    match axis {
        SplitAxis::Horizontal => rect.max_x(),
        SplitAxis::Vertical => rect.max_y(),
    }
}

/// A handle band of `thickness` centred on `seam`, spanning the parent's cross axis.
const fn handle_rect(seam: f64, axis: SplitAxis, parent: Rect, thickness: f64) -> Rect {
    let half = thickness / 2.0;
    match axis {
        SplitAxis::Horizontal => Rect::xywh(seam - half, parent.min_y(), thickness, parent.size.height),
        SplitAxis::Vertical => Rect::xywh(parent.min_x(), seam - half, parent.size.width, thickness),
    }
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

    use super::{DEFAULT_MIN_LEAF, DIVIDER_THICKNESS, dividers, extents, solve, solve_default};
    use crate::geometry::Rect;
    use crate::identity::{PaneId, SplitNodeId};
    use crate::split_tree::{MIN_WEIGHT, SplitAxis, SplitNode, SplitWeight, WeightedChild};

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
    fn a_seam_lands_exactly_where_the_tiles_meet() {
        let tree = row(vec![
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(3.0), SplitNode::Leaf(pane(2))),
        ]);
        let bound = Rect::xywh(0.0, 0.0, 800.0, 400.0);
        let seams = dividers(&tree, bound, 8.0);
        assert_eq!(seams.len(), 1);
        let seam = nth(&seams, 0);
        assert_eq!(seam.child_index, 0);
        assert_eq!(seam.axis, SplitAxis::Horizontal);
        assert_eq!(seam.rect.mid_x(), 200.0, "centred on the cut");
        assert_eq!(seam.rect.size.width, 8.0);
        assert_eq!(seam.rect.min_y(), 0.0);
        assert_eq!(
            seam.rect.size.height, 400.0,
            "a column seam spans the parent's height"
        );
        let layout = solve_default(&tree, bound);
        assert_eq!(frame(&layout, pane(1)).max_x(), seam.rect.mid_x());
        assert_eq!(frame(&layout, pane(2)).min_x(), seam.rect.mid_x());
    }

    #[test]
    fn every_seam_carries_its_own_pair_and_its_own_split() {
        let inner = SplitNode::Split {
            id: SplitNodeId::from_bytes([2; 16]),
            axis: SplitAxis::Horizontal,
            children: vec![WeightedChild::leaf(pane(2)), WeightedChild::leaf(pane(3))],
        };
        let tree = row(vec![
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), inner),
        ]);
        let seams = dividers(&tree, Rect::xywh(0.0, 0.0, 800.0, 600.0), DIVIDER_THICKNESS);
        assert_eq!(seams.len(), 2, "one per level");
        let outer = nth(&seams, 0);
        let nested = nth(&seams, 1);
        assert_eq!(outer.parent_span, 800.0);
        assert_eq!(
            nested.parent_span, 400.0,
            "a nested seam's span is its own split's, so the drag tracks the cursor 1:1",
        );
        assert_eq!(nested.split, SplitNodeId::from_bytes([2; 16]));
        assert_eq!((outer.leading_weight, outer.trailing_weight), (1.0, 1.0));
    }

    #[test]
    fn a_fixed_side_reports_the_unresizable_sentinel() {
        let tree = row(vec![
            WeightedChild::new(SplitWeight::Fixed(200.0), SplitNode::Leaf(pane(1))),
            WeightedChild::leaf(pane(2)),
        ]);
        let seam = nth(
            &dividers(&tree, Rect::xywh(0.0, 0.0, 800.0, 600.0), DIVIDER_THICKNESS),
            0,
        );
        assert_eq!(seam.leading_weight, 0.0);
        assert!(!seam.can_move_toward_leading());
        assert!(
            !seam.can_move_toward_trailing(),
            "a fixed side freezes the seam both ways"
        );
    }

    #[test]
    fn a_lone_leaf_and_a_zoomed_tab_have_nothing_to_drag() {
        assert!(dividers(&SplitNode::Leaf(pane(1)), bound(), DIVIDER_THICKNESS).is_empty());
        let three = row(vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
            WeightedChild::leaf(pane(3)),
        ]);
        assert_eq!(
            dividers(&three, bound(), DIVIDER_THICKNESS).len(),
            2,
            "n children, n-1 seams",
        );
    }

    fn nth(seams: &[super::Divider], index: usize) -> super::Divider {
        let Some(seam) = seams.get(index) else {
            panic!("no seam at {index}");
        };
        *seam
    }

    fn seam(leading: f64, trailing: f64, span: f64) -> super::Divider {
        super::Divider {
            split: SplitNodeId::from_bytes([1; 16]),
            child_index: 0,
            axis: SplitAxis::Horizontal,
            rect: Rect::xywh(0.0, 0.0, 0.0, 0.0),
            parent_span: span,
            flex_sum: leading + trailing,
            leading_weight: leading,
            trailing_weight: trailing,
        }
    }

    #[test]
    fn movability_is_the_pixel_floor_rather_than_the_weight_floor() {
        assert!(seam(1.0, 1.0, 800.0).can_move_toward_leading());
        assert!(seam(1.0, 1.0, 800.0).can_move_toward_trailing());
        // 0.5 of a flex sum of 2 over 400 pt renders 100 pt — over the weight floor (the premise of
        // the case), under the pixel one, and the weight-only rule would call it movable.
        let starved = seam(0.5, 1.5, 400.0);
        assert!(starved.leading_weight > MIN_WEIGHT);
        assert!(
            !starved.can_move_toward_leading(),
            "100 pt is under the 160 pt floor"
        );
        assert!(starved.can_move_toward_trailing());
    }

    #[test]
    fn the_clamp_holds_both_pixel_floors_and_stays_sum_preserving() {
        // Span 1000 at a flex sum of 2: the 160 pt column floor is weight 0.32.
        let pair = seam(1.0, 1.0, 1000.0);
        assert_eq!(pair.clamped_leading_weight(0.0), 0.32);
        assert_eq!(
            pair.clamped_leading_weight(5.0),
            1.68,
            "the trailing floor mirrors it"
        );
        assert_eq!(pair.clamped_leading_weight(0.9), 0.9, "in range, untouched");
        let row_seam = super::Divider {
            axis: SplitAxis::Vertical,
            ..seam(1.0, 1.0, 1000.0)
        };
        assert_eq!(
            row_seam.clamped_leading_weight(0.0),
            0.24,
            "a row seam floors at the height"
        );
    }

    #[test]
    fn an_over_tight_pair_can_only_be_dragged_toward_balance() {
        // 210 pt against 90 pt over a 300 pt span: two 160 pt floors do not fit.
        let tight = seam(1.4, 0.6, 300.0);
        let floor_weight = 160.0 / 300.0 * 2.0;
        assert_eq!(
            tight.clamped_leading_weight(0.2),
            floor_weight,
            "shrinking stops at the floor"
        );
        assert_eq!(
            tight.clamped_leading_weight(1.9),
            1.4,
            "growing the over-floor side is refused"
        );
        assert!(tight.can_move_toward_leading());
        assert!(
            !tight.can_move_toward_trailing(),
            "the starved side has nothing to give"
        );

        let frozen = seam(0.5, 0.5, 120.0);
        assert_eq!(
            frozen.clamped_leading_weight(0.1),
            0.5,
            "both under the floor: frozen"
        );
        assert_eq!(frozen.clamped_leading_weight(0.9), 0.5);

        assert_eq!(
            seam(1.0, 1.0, 0.0).clamped_leading_weight(0.001),
            0.001,
            "without geometry the proposal passes through to the tree's own floor",
        );
    }

    #[test]
    fn a_drag_moves_the_seam_one_to_one_with_the_cursor() {
        // A 50/50 top-level split over 800 pt: flex sum 2, so 120 px of cursor is 0.3 of weight, and
        // the leading child's extent moves 0.3 / 2 * 800 = 120 pt. Drop the flex-sum factor and it
        // moves 60 — the seam trailing the cursor at half speed, which is what this pins.
        let top = seam(1.0, 1.0, 800.0);
        let delta = top.weight_delta(120.0);
        assert_eq!(delta, 0.3);
        assert_eq!(delta / top.flex_sum * top.parent_span, 120.0);

        // A NESTED split is narrower with the same flex sum, and tracks 1:1 only because the seam
        // carries its OWN span: 120 px over 400 pt is twice the weight.
        assert_eq!(seam(1.0, 1.0, 400.0).weight_delta(120.0), 0.6);
    }

    #[test]
    fn a_seam_without_geometry_converts_nothing_rather_than_dividing_by_zero() {
        assert_eq!(seam(1.0, 1.0, 0.0).weight_delta(120.0), 0.0);
        assert_eq!(seam(1.0, 1.0, f64::NAN).weight_delta(120.0), 0.0);
        assert_eq!(seam(0.0, 0.0, 800.0).weight_delta(120.0), 0.0, "a zero flex sum");
        assert_eq!(seam(1.0, 1.0, 800.0).weight_delta(f64::INFINITY), 0.0);
    }

    #[test]
    fn the_readout_pair_always_sums_to_exactly_a_hundred() {
        assert_eq!(seam(1.0, 1.0, 800.0).split_percents(), Some((50, 50)));
        // A third rounds to 33; the trailing side is the COMPLEMENT of that, never rounded on its
        // own — 62.5 · 37.5 would independently round to 63 · 38 and read as 101.
        assert_eq!(seam(1.0, 2.0, 800.0).split_percents(), Some((33, 67)));
        assert_eq!(seam(62.5, 37.5, 800.0).split_percents(), Some((63, 37)));
    }

    #[test]
    fn a_degenerate_pair_shows_no_ratio_at_all() {
        // Absent rather than wrong: a `Fixed` side reports weight 0, and float residue never renders.
        assert_eq!(seam(0.0, 1.0, 800.0).split_percents(), None);
        assert_eq!(seam(1.0, 0.0, 800.0).split_percents(), None);
        assert_eq!(seam(f64::NAN, 1.0, 800.0).split_percents(), None);
        assert_eq!(seam(f64::INFINITY, 1.0, 800.0).split_percents(), None);
    }

    #[test]
    fn exactly_the_trees_panes_are_solved() {
        let tree = row(vec![WeightedChild::leaf(pane(1)), WeightedChild::leaf(pane(2))]);
        let layout = solve_default(&tree, bound());
        assert_eq!(layout.frames.len(), 2);
        assert!(layout.frame_of(pane(9)).is_none());
    }
}
