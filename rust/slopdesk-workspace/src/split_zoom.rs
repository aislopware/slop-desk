//! What a split tab RENDERS, once zoom has had its say.
//!
//! [`slopdesk_tree::split_layout`] answers where every pane of a tree goes. This module answers the
//! question one floor up, which the partition deliberately knows nothing about: a tab may name ONE
//! pane as zoomed, and a zoomed tab draws that pane over the whole bound with no seams in it.
//!
//! ## The siblings are still SOLVED, and that is the whole point
//!
//! The obvious zoom is "return the zoomed leaf and drop the rest". It is also the bug this module
//! exists to prevent. A pane the renderer stops emitting is a pane the shell unmounts, and
//! unmounting one dismantles what is behind it — a libghostty surface, a live video stream — so
//! un-zooming repaints from the lossy replay ring instead of revealing what was already there.
//!
//! So [`render`] emits EVERY pane of the tab, always. The zoomed one is visible at the whole bound;
//! each sibling rides along [`RenderLeaf::hidden`] at the rect it would have had un-zoomed. The
//! view draws a hidden leaf at `opacity 0` with no hit-testing, so nothing is torn down, nothing
//! reflows while it is away, and un-zoom is a visibility flip rather than a rebuild.
//!
//! That is also why the hidden leaves carry the SOLVER's rects rather than anything cheaper: a
//! hidden surface laid out at the wrong size would reflow twice — once on the way out and once on
//! the way back — and a terminal reflow is not free.
//!
//! ## A stale zoom id is ignored, never honoured
//!
//! A tab can name a pane that has since been closed. [`is_zoom_active`] is the single place that
//! decides, and it demands the id actually be a leaf of THIS tree; a zoom naming nothing falls
//! through to the ordinary tiled layout. The alternative — honouring it — would collapse the tab to
//! a pane that does not exist, which renders as an empty window with no way out of it.
//!
//! ## Order is the tree's, not the map's
//!
//! [`slopdesk_tree::split_layout::SolvedLayout`] is keyed by pane id and so iterates in ID order,
//! which is a hash of nothing anybody chose. The mount order a view keys its children on has to be
//! stable across layouts, so the leaves come back in the tree's own PRE-ORDER walk and the hidden
//! ones keep that same order behind them.
//!
//! ## The seams are gated HERE
//!
//! [`render`] answers the dividers too, and answers NONE while a zoom is active. A caller that
//! asked the partition for seams and then decided for itself whether to draw them would be the
//! second copy of this rule — and the copy that is wrong is always the one nobody is looking at.

use slopdesk_ids::PaneId;
use slopdesk_tree::geometry::{Rect, Size};
use slopdesk_tree::split_layout::{self, Divider};
use slopdesk_tree::split_tree::SplitNode;

/// One pane, placed, and told whether it is on screen.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RenderLeaf {
    /// Which pane.
    pub pane: PaneId,
    /// Where it draws: the whole bound for the zoomed leaf, the solved rect for everything else.
    pub rect: Rect,
    /// ZOOM-hidden: mounted, laid out, and not drawn. Never set while no zoom is active, so the
    /// tiled path is byte-identical to what it was before zoom existed.
    pub hidden: bool,
}

/// Everything a split tab draws for one bound.
#[derive(Debug, Clone, PartialEq)]
pub struct RenderLayout {
    /// Every pane of the tab, visible ones first, each in the tree's pre-order.
    pub leaves: Vec<RenderLeaf>,
    /// The draggable seams — empty for a lone leaf, and empty while a zoom is active.
    pub dividers: Vec<Divider>,
}

/// Whether `zoomed` is a zoom this tree can honour: named, and a leaf that is actually in it.
///
/// The ONE answer to "is this tab zoomed". Everything else — which rect the leaf gets, whether the
/// seams draw — is decided from this, so there is no arrangement in which half the render believes
/// the tab is zoomed and the other half does not.
///
/// Membership is asked of the tree's own leaf walk rather than of the solved frames, so the verdict
/// is the same for a bound that has not been laid out yet.
#[must_use]
pub fn is_zoom_active(root: &SplitNode, zoomed: Option<PaneId>) -> bool {
    zoomed.is_some_and(|pane| root.all_pane_ids().contains(&pane))
}

/// The whole render for `root` inside `bounds`.
///
/// `min_leaf` floors every solved leaf and `thickness` is the seam band, both forwarded to the
/// partition unchanged — this module places nothing itself, it only decides what is shown.
///
/// Total: every pane the partition solved comes back exactly once, so a caller can key a single
/// collection on [`RenderLeaf::pane`] and never see a duplicate or a gap.
#[must_use]
pub fn render(
    root: &SplitNode,
    bounds: Rect,
    zoomed: Option<PaneId>,
    min_leaf: Size,
    thickness: f64,
) -> RenderLayout {
    let solved = split_layout::solve(root, bounds, min_leaf);
    let order = root.all_pane_ids();
    // A leaf the partition did not solve is dropped rather than placed at a guess: the solver
    // answers for exactly the tree's panes, so this can only be reached by a tree that changed
    // under the walk, and an unplaced pane is better than one at the origin.
    let placed = |pane: &PaneId| solved.frames.get(pane).map(|rect| (*pane, *rect));

    // The zoom verdict, read off the walk this call already has rather than off a second one.
    let Some(zoomed) = zoomed.filter(|pane| order.contains(pane)) else {
        return RenderLayout {
            leaves: order
                .iter()
                .filter_map(placed)
                .map(|(pane, rect)| {
                    RenderLeaf {
                        pane,
                        rect,
                        hidden: false,
                    }
                })
                .collect(),
            dividers: split_layout::dividers(root, bounds, thickness),
        };
    };

    let mut leaves = Vec::with_capacity(order.len());
    leaves.push(RenderLeaf {
        pane: zoomed,
        rect: bounds,
        hidden: false,
    });
    leaves.extend(
        order
            .iter()
            .filter(|pane| **pane != zoomed)
            .filter_map(placed)
            .map(|(pane, rect)| {
                RenderLeaf {
                    pane,
                    rect,
                    hidden: true,
                }
            }),
    );
    RenderLayout {
        leaves,
        dividers: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use slopdesk_ids::identity::{PaneId, SplitNodeId};
    use slopdesk_tree::geometry::{Rect, Size};
    use slopdesk_tree::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};

    use super::{RenderLeaf, is_zoom_active, render};

    const BOUNDS: Rect = Rect::xywh(0.0, 0.0, 400.0, 300.0);
    const MIN_LEAF: Size = Size::new(80.0, 60.0);
    const THICKNESS: f64 = 16.0;

    fn pane(seed: u128) -> PaneId {
        PaneId::from_bytes(seed.to_be_bytes())
    }

    /// `[a | b]`, equal shares.
    fn two_leaves(a: PaneId, b: PaneId) -> SplitNode {
        SplitNode::Split {
            id: SplitNodeId::from_bytes([9; 16]),
            axis: SplitAxis::Horizontal,
            children: vec![
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(a)),
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(b)),
            ],
        }
    }

    fn visible(layout: &[RenderLeaf]) -> Vec<PaneId> {
        layout
            .iter()
            .filter(|leaf| !leaf.hidden)
            .map(|leaf| leaf.pane)
            .collect()
    }

    fn hidden(layout: &[RenderLeaf]) -> Vec<PaneId> {
        layout
            .iter()
            .filter(|leaf| leaf.hidden)
            .map(|leaf| leaf.pane)
            .collect()
    }

    /// Ported from `SplitTreeRenderModelTests.testZoomYieldsOneFullBoundsLeafNoDividers`.
    #[test]
    fn a_zoomed_tab_shows_one_leaf_at_the_whole_bound_and_no_seams() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        let layout = render(&root, BOUNDS, Some(b), MIN_LEAF, THICKNESS);
        assert_eq!(visible(&layout.leaves), vec![b]);
        assert_eq!(layout.leaves.first().map(|leaf| leaf.rect), Some(BOUNDS));
        assert!(layout.dividers.is_empty(), "a zoomed tab has nothing to drag");
    }

    /// Ported from `ZoomLayoutFixTests.testZoomKeepsEverySiblingInCompositorLeaves` — the property
    /// the module exists for. A sibling dropped here is a surface torn down.
    #[test]
    fn zoom_keeps_every_sibling_solved_and_mounted() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        let layout = render(&root, BOUNDS, Some(b), MIN_LEAF, THICKNESS);
        let every: Vec<PaneId> = layout.leaves.iter().map(|leaf| leaf.pane).collect();
        assert_eq!(every.len(), 2, "every pane of the tab is still emitted");
        assert!(every.contains(&a) && every.contains(&b));
        assert_eq!(hidden(&layout.leaves), vec![a]);
    }

    /// Ported from `ZoomLayoutFixTests.testZoomHiddenLeavesKeepTheirUnzoomedRects`. A hidden leaf
    /// laid out anywhere but its tiled rect reflows twice per zoom toggle.
    #[test]
    fn a_hidden_sibling_keeps_the_rect_it_had_before_the_zoom() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        let tiled = render(&root, BOUNDS, None, MIN_LEAF, THICKNESS);
        let zoomed = render(&root, BOUNDS, Some(b), MIN_LEAF, THICKNESS);
        let tiled_a = tiled
            .leaves
            .iter()
            .find(|leaf| leaf.pane == a)
            .map(|leaf| leaf.rect);
        let hidden_a = zoomed
            .leaves
            .iter()
            .find(|leaf| leaf.pane == a)
            .map(|leaf| leaf.rect);
        assert_eq!(hidden_a, tiled_a, "no reflow while hidden");
        assert!(tiled_a.is_some(), "precondition: the sibling was solved at all");
    }

    /// Ported from `ZoomLayoutFixTests.testUnzoomedLayoutHasNoHiddenLeaves`.
    #[test]
    fn an_unzoomed_tab_hides_nothing() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        let layout = render(&root, BOUNDS, None, MIN_LEAF, THICKNESS);
        assert!(layout.leaves.iter().all(|leaf| !leaf.hidden));
        assert_eq!(visible(&layout.leaves), vec![a, b]);
        assert_eq!(layout.dividers.len(), 1, "the one seam between the pair");
    }

    /// Ported from `SplitTreeRenderModelTests.testStaleZoomFallsThroughToTiledLayout`. A zoom
    /// naming a closed pane must not collapse the tab onto nothing.
    #[test]
    fn a_zoom_naming_a_pane_that_is_not_in_the_tree_is_ignored() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        assert!(!is_zoom_active(&root, Some(pane(99))));
        let layout = render(&root, BOUNDS, Some(pane(99)), MIN_LEAF, THICKNESS);
        assert_eq!(visible(&layout.leaves), vec![a, b], "the tiled layout renders");
        assert!(hidden(&layout.leaves).is_empty());
        assert_eq!(layout.dividers.len(), 1, "and its seam is still draggable");
    }

    /// The zoom verdict, on its own, for every shape a caller can hand it.
    #[test]
    fn the_zoom_verdict_needs_a_named_pane_that_is_in_this_tree() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        assert!(!is_zoom_active(&root, None), "no zoom named");
        assert!(is_zoom_active(&root, Some(a)));
        assert!(is_zoom_active(&root, Some(b)));
        assert!(!is_zoom_active(&root, Some(pane(3))));
        let lone = SplitNode::Leaf(a);
        assert!(is_zoom_active(&lone, Some(a)), "a lone leaf can be zoomed");
        assert!(!is_zoom_active(&lone, Some(b)));
    }

    /// Mount order is the TREE's pre-order, not the solver map's id order — a view keys its
    /// children on this, so an order that moved would replace every leaf.
    #[test]
    fn the_leaves_come_back_in_the_trees_own_pre_order() {
        // Ids chosen so pre-order and id order DISAGREE: the left leaf sorts last.
        let (left, right) = (pane(9), pane(1));
        let root = two_leaves(left, right);
        let layout = render(&root, BOUNDS, None, MIN_LEAF, THICKNESS);
        assert_eq!(
            visible(&layout.leaves),
            vec![left, right],
            "pre-order, not id order"
        );
        // And the hidden tail keeps it too.
        let three = SplitNode::Split {
            id: SplitNodeId::from_bytes([7; 16]),
            axis: SplitAxis::Vertical,
            children: vec![
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(9))),
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(5))),
                WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            ],
        };
        let zoomed = render(&three, BOUNDS, Some(pane(5)), MIN_LEAF, THICKNESS);
        assert_eq!(visible(&zoomed.leaves), vec![pane(5)]);
        assert_eq!(hidden(&zoomed.leaves), vec![pane(9), pane(1)]);
    }

    /// A lone leaf: one visible pane at the bound, no seams, whether or not it is zoomed.
    #[test]
    fn a_lone_leaf_has_no_seams_either_way() {
        let a = pane(1);
        let root = SplitNode::Leaf(a);
        for zoom in [None, Some(a)] {
            let layout = render(&root, BOUNDS, zoom, MIN_LEAF, THICKNESS);
            assert_eq!(visible(&layout.leaves), vec![a], "{zoom:?}");
            assert!(layout.dividers.is_empty(), "{zoom:?}");
            assert!(hidden(&layout.leaves).is_empty(), "{zoom:?}");
            assert_eq!(layout.leaves.first().map(|leaf| leaf.rect), Some(BOUNDS));
        }
    }

    /// A degenerate bound still answers for every pane — the solver floors rather than collapsing,
    /// and this module places whatever it is handed.
    #[test]
    fn a_zero_bound_still_places_every_pane() {
        let (a, b) = (pane(1), pane(2));
        let root = two_leaves(a, b);
        let empty = Rect::xywh(0.0, 0.0, 0.0, 0.0);
        let layout = render(&root, empty, None, MIN_LEAF, THICKNESS);
        assert_eq!(layout.leaves.len(), 2);
        let zoomed = render(&root, empty, Some(a), MIN_LEAF, THICKNESS);
        assert_eq!(zoomed.leaves.len(), 2);
        assert_eq!(zoomed.leaves.first().map(|leaf| leaf.rect), Some(empty));
    }
}
