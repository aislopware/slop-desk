//! The recursive, n-ary tiled split tree a tab is made of, and every pure transformation on it.
//!
//! The tree stores only identities and geometry. A pane's spec — its command, its title, its kind —
//! lives in the owning session's side table, so renaming a pane never churns a tree diff.
//!
//! ## N-ary, not binary
//!
//! Three panes side by side are ONE split with three children, not a split containing a split. That
//! is what makes closing the middle one redistribute the freed space equally among the survivors
//! instead of handing it all to whichever sibling happened to share its intermediary node. It also
//! means the invariant "no split shares its parent's axis" has to be maintained by every operation
//! that can produce one — the same-axis merge below is that maintenance, and it runs on the LIVE
//! path, not only at decode, because the live ops never re-run the decoder's repair.
//!
//! ## Invariants
//!
//! A split always has at least two children; no split shares its parent's axis; every pane id
//! appears once; every flex weight is finite and at least [`MIN_WEIGHT`]; the depth is at most
//! [`MAX_DEPTH`]. Every operation here preserves all five given them, and the decoder repairs a
//! file that violates any.
//!
//! ## Nothing here invents an identity
//!
//! An operation that has to create a split takes the fresh [`SplitNodeId`] as an argument. See
//! [`crate::identity`] — the crate has no entropy, and that is deliberate rather than a limitation.

use std::collections::BTreeSet;

use crate::identity::{PaneId, SplitNodeId};

/// The direction a split lays its children out.
///
/// The discriminants are the ON-WIRE bytes, and the byte is part of this type rather than of the
/// codec because a second enum on the transport side would be one axis mapping written twice — the
/// easy place to invert something and not notice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
#[repr(u8)]
pub enum SplitAxis {
    /// Children sit side by side as columns — the split partitions the bound's WIDTH.
    #[default]
    Horizontal = 0,
    /// Children stack as rows — the split partitions the bound's HEIGHT.
    Vertical = 1,
}

impl SplitAxis {
    /// The axis a byte names, C-style: any non-zero is [`Vertical`](Self::Vertical).
    ///
    /// Total by construction. A byte off the network gets the same interop rule the rest of the
    /// codebase uses rather than a rejection — there is no third axis for an unexpected value to
    /// mean.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        if byte == 0 {
            Self::Horizontal
        } else {
            Self::Vertical
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// A side a pane can be dropped against, in the drag-to-re-split and dock-to-edge gestures.
///
/// It maps a screen edge to an axis and an insertion side, so the hit-test and the tree ops read
/// one source of truth and the mapping cannot drift — this is the easy place to invert something
/// and not notice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum PaneDropEdge {
    /// The leading edge, forming columns.
    #[default]
    Left = 0,
    /// The trailing edge, forming columns.
    Right = 1,
    /// The top edge, forming rows.
    Top = 2,
    /// The bottom edge, forming rows.
    Bottom = 3,
}

impl PaneDropEdge {
    /// Every edge, for a hit-test that wants to score them all.
    pub const ALL: [Self; 4] = [Self::Left, Self::Right, Self::Top, Self::Bottom];

    /// The edge a byte names.
    ///
    /// An unknown byte docks at the LEADING edge. Every value is a legal dock, so there is nothing
    /// to reject — and defaulting keeps the pane on screen rather than dropping the gesture.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Self {
        match byte {
            1 => Self::Right,
            2 => Self::Top,
            3 => Self::Bottom,
            _ => Self::Left,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }

    /// The axis a drop on this edge forms. Left and right make COLUMNS, top and bottom make ROWS —
    /// so dropping a side-by-side pane on another's top edge stacks them, which is what the gesture
    /// has to mean.
    #[must_use]
    pub const fn axis(self) -> SplitAxis {
        match self {
            Self::Left | Self::Right => SplitAxis::Horizontal,
            Self::Top | Self::Bottom => SplitAxis::Vertical,
        }
    }

    /// Whether the dropped pane is inserted before the target along that axis.
    #[must_use]
    pub const fn inserts_before(self) -> bool {
        matches!(self, Self::Left | Self::Top)
    }
}

/// The floor every flex share is clamped to.
///
/// A pane keeps a sliver of the axis even when a corrupt or hostile file set its weight to zero, to
/// a negative, or to NaN — a pane that cannot be seen cannot be closed.
pub const MIN_WEIGHT: f64 = 0.05;

/// The deepest nesting the decoder keeps.
///
/// Far above any real layout — a person nests a handful — and it exists so a hostile file cannot
/// stack-overflow the solver or the renderer. Past it the over-deep tail collapses to its first
/// leaf.
pub const MAX_DEPTH: usize = 12;

/// A child's share of its parent split along the split axis.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SplitWeight {
    /// A proportional share, normalized against its siblings at layout time. `Flex(1.0)` is an
    /// equal share and is the default.
    Flex(f64),
    /// A fixed number of points along the parent axis, taken out of the bound BEFORE the flex
    /// children divide the remainder. Reserved for fixed sidebars: the solver honours it, the tree
    /// ops only ever mint flex.
    Fixed(f64),
}

impl Default for SplitWeight {
    fn default() -> Self {
        Self::Flex(1.0)
    }
}

impl SplitWeight {
    /// This weight with any non-finite or sub-floor magnitude repaired.
    ///
    /// A flex share floors at [`MIN_WEIGHT`]; a fixed extent floors at zero, because a fixed child
    /// may legitimately be zero points — absent — but never NaN.
    #[must_use]
    pub const fn repaired(self) -> Self {
        match self {
            Self::Flex(weight) => {
                Self::Flex(if weight.is_finite() {
                    weight.max(MIN_WEIGHT)
                } else {
                    MIN_WEIGHT
                })
            },
            Self::Fixed(points) => Self::Fixed(if points.is_finite() { points.max(0.0) } else { 0.0 }),
        }
    }

    /// The flex share, or `None` for a fixed child.
    #[must_use]
    pub(crate) const fn flex(self) -> Option<f64> {
        match self {
            Self::Flex(weight) => Some(weight),
            Self::Fixed(_) => None,
        }
    }

    /// The raw `f64`, whichever case carries it.
    #[must_use]
    pub const fn value(self) -> f64 {
        match self {
            Self::Flex(value) | Self::Fixed(value) => value,
        }
    }

    /// The on-wire discriminator: `0` flex, `1` fixed.
    #[must_use]
    pub const fn kind_byte(self) -> u8 {
        match self {
            Self::Flex(_) => 0,
            Self::Fixed(_) => 1,
        }
    }
}

/// One child slot of a split: a subtree plus its share of the parent axis.
#[derive(Debug, Clone, PartialEq)]
pub struct WeightedChild {
    /// Its share.
    pub weight: SplitWeight,
    /// Its subtree.
    pub node: SplitNode,
}

impl WeightedChild {
    /// A child at a weight.
    #[must_use]
    pub const fn new(weight: SplitWeight, node: SplitNode) -> Self {
        Self { weight, node }
    }

    /// A leaf child at an equal share.
    #[must_use]
    pub(crate) const fn leaf(id: PaneId) -> Self {
        Self {
            weight: SplitWeight::Flex(1.0),
            node: SplitNode::Leaf(id),
        }
    }
}

/// The recursive n-ary split tree of a tab.
#[derive(Debug, Clone, PartialEq)]
pub enum SplitNode {
    /// A single pane.
    Leaf(PaneId),
    /// A partition of the bound along an axis, among children weighted by their shares.
    Split {
        /// The divider group's identity.
        id: SplitNodeId,
        /// Which way it partitions.
        axis: SplitAxis,
        /// Its children, in visual order.
        children: Vec<WeightedChild>,
    },
}

/// Where a pane sits relative to the nearest enclosing split on an axis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnclosingSplit {
    /// The split's identity.
    pub split_id: SplitNodeId,
    /// The index of that split's DIRECT child subtree holding the pane.
    pub child_index: usize,
    /// How many children that split has.
    pub child_count: usize,
}

impl SplitNode {
    /// Every pane id, in pre-order.
    ///
    /// The order is deterministic because the focus cycle and the carousel read it as a sequence,
    /// not just as a set.
    #[must_use]
    pub fn all_pane_ids(&self) -> Vec<PaneId> {
        let mut ids = Vec::new();
        self.collect_pane_ids(&mut ids);
        ids
    }

    fn collect_pane_ids(&self, into: &mut Vec<PaneId>) {
        match self {
            Self::Leaf(id) => into.push(*id),
            Self::Split { children, .. } => {
                for child in children {
                    child.node.collect_pane_ids(into);
                }
            },
        }
    }

    /// How many panes the tree holds.
    #[must_use]
    pub fn leaf_count(&self) -> usize {
        match self {
            Self::Leaf(_) => 1,
            Self::Split { children, .. } => children.iter().map(|child| child.node.leaf_count()).sum(),
        }
    }

    /// The nesting depth. A leaf is one; a split is one more than its deepest child.
    #[must_use]
    pub fn depth(&self) -> usize {
        match self {
            Self::Leaf(_) => 1,
            Self::Split { children, .. } => {
                1 + children.iter().map(|child| child.node.depth()).max().unwrap_or(0)
            },
        }
    }

    /// Whether a pane is a leaf anywhere in the tree.
    #[must_use]
    pub(crate) fn contains(&self, id: PaneId) -> bool {
        match self {
            Self::Leaf(leaf) => *leaf == id,
            Self::Split { children, .. } => children.iter().any(|child| child.node.contains(id)),
        }
    }

    /// The first leaf in pre-order — the sensible default focus, and the first survivor of a close.
    ///
    /// `None` only for a split with no children, which the invariants forbid. Reporting it honestly
    /// beats inventing an identity no pane answers to.
    #[must_use]
    pub fn first_leaf_id(&self) -> Option<PaneId> {
        match self {
            Self::Leaf(id) => Some(*id),
            Self::Split { children, .. } => children.first().and_then(|child| child.node.first_leaf_id()),
        }
    }

    /// Structural equality that IGNORES split identities.
    ///
    /// Two trees are structurally equal when they have the same shape, the same leaves in the same
    /// places, and the same weights. Derived equality includes the split id, so a rebuild that
    /// reproduces the same arrangement under freshly-minted ids reads as changed — which is exactly
    /// what makes dropping a pane back where it already sat look like a real edit. A relocate uses
    /// this to recognise that no-op and skip the reconcile.
    #[must_use]
    pub fn is_structurally_equal(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Leaf(a), Self::Leaf(b)) => a == b,
            (
                Self::Split {
                    axis: axis_a,
                    children: children_a,
                    ..
                },
                Self::Split {
                    axis: axis_b,
                    children: children_b,
                    ..
                },
            ) => {
                axis_a == axis_b
                    && children_a.len() == children_b.len()
                    && children_a
                        .iter()
                        .zip(children_b)
                        .all(|(a, b)| a.weight == b.weight && a.node.is_structurally_equal(&b.node))
            },
            _ => false,
        }
    }

    /// Splits a leaf along an axis, inserting a BRAND-NEW pane beside it.
    ///
    /// `before` puts the new pane on the leading side — left of a horizontal split, above a
    /// vertical one — which is what the split-left and split-up chords ask for; every other
    /// split takes the trailing side. `None` means the target is not in this tree, which the
    /// caller treats as a no-op.
    ///
    /// When the target's PARENT split already runs along this axis the new pane joins it as a plain
    /// sibling, with no intermediary node. Otherwise the target leaf becomes a fresh two-child
    /// split.
    #[must_use]
    pub fn splitting(
        &self,
        target: PaneId,
        axis: SplitAxis,
        new_leaf: PaneId,
        before: bool,
        fresh_split: SplitNodeId,
    ) -> Option<Self> {
        self.contains(target)
            .then(|| self.insert_beside_impl(new_leaf, target, axis, before, fresh_split))
    }

    /// Inserts an EXISTING pane beside a target along an axis.
    ///
    /// The drop-on-an-edge counterpart to [`Self::splitting`]. The caller has already pruned the
    /// pane from wherever it was, so the leaf set grows by exactly one; `None` means the target
    /// is absent.
    #[must_use]
    pub fn inserting_beside(
        &self,
        leaf: PaneId,
        target: PaneId,
        axis: SplitAxis,
        before: bool,
        fresh_split: SplitNodeId,
    ) -> Option<Self> {
        self.contains(target)
            .then(|| self.insert_beside_impl(leaf, target, axis, before, fresh_split))
    }

    /// The shared worker. The same-axis sibling insert is detected at each split, which owns its
    /// children, so the parent axis never has to be threaded down the recursion.
    fn insert_beside_impl(
        &self,
        leaf: PaneId,
        target: PaneId,
        axis: SplitAxis,
        before: bool,
        fresh_split: SplitNodeId,
    ) -> Self {
        match self {
            Self::Leaf(id) => {
                if *id != target {
                    return self.clone();
                }
                let target_child = WeightedChild::leaf(target);
                let new_child = WeightedChild::leaf(leaf);
                Self::Split {
                    id: fresh_split,
                    axis,
                    children: if before {
                        vec![new_child, target_child]
                    } else {
                        vec![target_child, new_child]
                    },
                }
            },
            Self::Split {
                id,
                axis: split_axis,
                children,
            } => {
                let direct = children
                    .iter()
                    .position(|child| matches!(child.node, Self::Leaf(candidate) if candidate == target));
                if *split_axis == axis
                    && let Some(index) = direct
                {
                    // The n-ary insert: a plain sibling, no redundant intermediary.
                    let mut new_children = children.clone();
                    let inserted =
                        WeightedChild::new(SplitWeight::Flex(insert_weight(children)), Self::Leaf(leaf));
                    new_children.insert(if before { index } else { index + 1 }, inserted);
                    return Self::Split {
                        id: *id,
                        axis: *split_axis,
                        children: new_children,
                    };
                }
                Self::Split {
                    id: *id,
                    axis: *split_axis,
                    children: children
                        .iter()
                        .map(|child| {
                            if child.node.contains(target) {
                                WeightedChild::new(
                                    child.weight,
                                    child
                                        .node
                                        .insert_beside_impl(leaf, target, axis, before, fresh_split),
                                )
                            } else {
                                child.clone()
                            }
                        })
                        .collect(),
                }
            },
        }
    }

    /// Inserts an EXISTING pane as the OUTERMOST child along an axis — the drag-to-dock drop, where
    /// there is no target leaf to sit beside and the new pane spans the whole cross axis.
    ///
    /// When the root already splits along this axis the pane simply joins it at one end, and the
    /// full span falls out of the flat split with no nesting. Otherwise the whole root is
    /// wrapped in a fresh two-child split.
    #[must_use]
    pub fn inserting_at_root(
        &self,
        leaf: PaneId,
        axis: SplitAxis,
        before: bool,
        fresh_split: SplitNodeId,
    ) -> Self {
        if let Self::Split {
            id,
            axis: split_axis,
            children,
        } = self
            && *split_axis == axis
        {
            let mut new_children = children.clone();
            let inserted = WeightedChild::new(SplitWeight::Flex(insert_weight(children)), Self::Leaf(leaf));
            let at = if before { 0 } else { new_children.len() };
            new_children.insert(at, inserted);
            return Self::Split {
                id: *id,
                axis: *split_axis,
                children: new_children,
            };
        }
        let root_child = WeightedChild::new(SplitWeight::Flex(1.0), self.clone());
        let new_child = WeightedChild::leaf(leaf);
        Self::Split {
            id: fresh_split,
            axis,
            children: if before {
                vec![new_child, root_child]
            } else {
                vec![root_child, new_child]
            },
        }
    }

    /// Removes a pane, collapsing the now-single-child parent and re-balancing the survivors.
    ///
    /// `None` means the removal emptied the tree — the caller runs its empty-tab cascade. A pane
    /// that was never here yields the tree unchanged rather than `None`, so "absent" and
    /// "emptied" stay distinguishable.
    #[must_use]
    pub fn removing(&self, target: PaneId) -> Option<Self> {
        if self.contains(target) {
            self.remove_impl(target)
        } else {
            Some(self.clone())
        }
    }

    fn remove_impl(&self, target: PaneId) -> Option<Self> {
        match self {
            Self::Leaf(id) => (*id != target).then(|| self.clone()),
            Self::Split { id, axis, children } => {
                let mut survivors = Vec::with_capacity(children.len());
                for child in children {
                    if matches!(child.node, Self::Leaf(leaf) if leaf == target) {
                        continue;
                    }
                    if let Some(pruned) = child.node.remove_impl(target) {
                        survivors.push(WeightedChild::new(child.weight, pruned));
                    }
                }
                // Splice any survivor that is itself a split on THIS axis up into this level. A
                // collapse can float a grandchild that happens to share the grandparent's axis —
                // `V[ H[V[a,b], c], d ]` losing `c` collapses the `H` and leaves `V[V[a,b], d]` — and
                // the live path never re-runs the decoder's repair, so without this merge the tree
                // carries a same-axis nest that skews the rebalance and over-counts the depth. One
                // pass is enough: a valid child split never nests its own axis, so nothing spliced up
                // can share it either.
                let merged = merge_same_axis(survivors, *axis);
                match merged.len() {
                    0 => None,
                    1 => merged.into_iter().next().map(|child| child.node),
                    _ => {
                        Some(Self::Split {
                            id: *id,
                            axis: *axis,
                            children: rebalance_flex(merged),
                        })
                    },
                }
            },
        }
    }

    /// Shifts flex weight between the two children either side of a divider.
    ///
    /// The pair's SUM is preserved — the leading child grows by exactly what the trailing one gives
    /// up — and both stay at or above [`MIN_WEIGHT`], so neither pane can be dragged out of
    /// existence. A no-op when the split or the indices are absent, or either child is fixed.
    #[must_use]
    pub fn resizing_divider(&self, split_id: SplitNodeId, leading_index: usize, delta: f64) -> Self {
        self.map_split(split_id, &|children| {
            adjust_pair(children, leading_index, &|lead, _trail| lead + delta)
        })
    }

    /// Evens ONLY one seam: both children take their pair mean.
    ///
    /// Unlike [`Self::rebalanced`], every other divider in the split — and every other split in the
    /// tree — keeps the ratio it was dragged to. This is the divider double-click.
    #[must_use]
    pub fn evening_divider(&self, split_id: SplitNodeId, leading_index: usize) -> Self {
        self.map_split(split_id, &|children| {
            adjust_pair(children, leading_index, &|lead, trail| f64::midpoint(lead, trail))
        })
    }

    /// Sets the ABSOLUTE leading weight of a divider, the trailing sibling taking the remainder.
    ///
    /// The cursor-matched form of [`Self::resizing_divider`], for a live drag: the caller derives
    /// the weight from a stable cursor translation, so an over-drag holds at the clamp and
    /// resumes the moment the cursor comes back — where an accumulated delta would have drifted
    /// away from the pointer and never returned.
    #[must_use]
    pub fn setting_divider_weight(
        &self,
        split_id: SplitNodeId,
        leading_index: usize,
        leading_weight: f64,
    ) -> Self {
        self.map_split(split_id, &|children| {
            adjust_pair(children, leading_index, &|_lead, _trail| leading_weight)
        })
    }

    /// Rewrites the children of one split, recursing to find it.
    fn map_split(
        &self,
        split_id: SplitNodeId,
        rewrite: &impl Fn(&[WeightedChild]) -> Vec<WeightedChild>,
    ) -> Self {
        match self {
            Self::Leaf(_) => self.clone(),
            Self::Split { id, axis, children } => {
                if *id == split_id {
                    return Self::Split {
                        id: *id,
                        axis: *axis,
                        children: rewrite(children),
                    };
                }
                Self::Split {
                    id: *id,
                    axis: *axis,
                    children: children
                        .iter()
                        .map(|child| {
                            WeightedChild::new(child.weight, child.node.map_split(split_id, rewrite))
                        })
                        .collect(),
                }
            },
        }
    }

    /// Exchanges two panes' positions. The weights stay with the slot; only the identities move.
    #[must_use]
    pub fn swapping(&self, a: PaneId, b: PaneId) -> Self {
        if a == b || !self.contains(a) || !self.contains(b) {
            return self.clone();
        }
        self.map_leaves(&|id| {
            if id == a {
                b
            } else if id == b {
                a
            } else {
                id
            }
        })
    }

    /// Every leaf id passed through a transform. The shape and the weights are untouched.
    #[must_use]
    fn map_leaves(&self, transform: &impl Fn(PaneId) -> PaneId) -> Self {
        match self {
            Self::Leaf(id) => Self::Leaf(transform(*id)),
            Self::Split { id, axis, children } => {
                Self::Split {
                    id: *id,
                    axis: *axis,
                    children: children
                        .iter()
                        .map(|child| WeightedChild::new(child.weight, child.node.map_leaves(transform)))
                        .collect(),
                }
            },
        }
    }

    /// The nearest ancestor split on an axis that contains a pane.
    ///
    /// Nearest means DEEPEST: a keyboard resize should nudge the divider closest to the focused
    /// pane, so the descent keeps overwriting a shallower hit with a deeper one. `None` when no
    /// ancestor on that axis holds the pane — a sole leaf, or a pane that only sits under the
    /// other axis.
    #[must_use]
    pub fn enclosing_split(&self, pane: PaneId, axis: SplitAxis) -> Option<EnclosingSplit> {
        if !self.contains(pane) {
            return None;
        }
        let mut best = None;
        self.enclosing_split_impl(pane, axis, &mut best);
        best
    }

    fn enclosing_split_impl(&self, pane: PaneId, axis: SplitAxis, best: &mut Option<EnclosingSplit>) {
        let Self::Split {
            id,
            axis: split_axis,
            children,
        } = self
        else {
            return;
        };
        // Exactly one direct child holds the pane, because pane ids are unique.
        let Some(index) = children.iter().position(|child| child.node.contains(pane)) else {
            return;
        };
        if *split_axis == axis {
            *best = Some(EnclosingSplit {
                split_id: *id,
                child_index: index,
                child_count: children.len(),
            });
        }
        if let Some(child) = children.get(index) {
            child.node.enclosing_split_impl(pane, axis, best);
        }
    }

    /// The full repair pass: every invariant re-established, nothing rejected.
    ///
    /// A persisted tree is untrusted — an older build wrote it, or a person edited it — so decode
    /// REPAIRS rather than traps. In order: anything nested past [`MAX_DEPTH`] collapses to its
    /// first leaf; a split with no valid children is dropped; a single-child split becomes its
    /// child; a child split sharing its parent's axis is spliced in; a pane id already seen
    /// anywhere in the tree is re-minted, because the live registry is keyed one-to-one by it;
    /// and every weight is clamped.
    ///
    /// `None` means the whole tree was degenerate and the caller should substitute a fresh single
    /// leaf. `mint` supplies the replacement ids — this crate has no entropy — and is called only
    /// for a genuine duplicate, so a well-formed tree never invokes it.
    ///
    /// The depth cap is a POST-decode bound on the kept structure, not decode-time stack safety:
    /// the parser has to have survived the file before this can run at all. That is the
    /// parser's job, and it is why a hostile deep file fails cleanly there rather than here.
    #[must_use]
    pub(crate) fn normalized(&self, mint: &mut impl FnMut() -> PaneId) -> Option<Self> {
        let mut seen = BTreeSet::new();
        self.normalize_impl(0, &mut seen, mint)
    }

    fn normalize_impl(
        &self,
        depth: usize,
        seen: &mut BTreeSet<PaneId>,
        mint: &mut impl FnMut() -> PaneId,
    ) -> Option<Self> {
        match self {
            Self::Leaf(id) => Some(Self::Leaf(accept_leaf(*id, seen, mint))),
            Self::Split { id, axis, children } => {
                // Past the cap the whole subtree collapses to its first surviving leaf, so the kept
                // structure stays shallow however deep the file went.
                if depth + 1 >= MAX_DEPTH {
                    return Some(self.first_leaf_repaired(seen, mint));
                }
                let mut repaired = Vec::with_capacity(children.len());
                for child in children {
                    let Some(node) = child.node.normalize_impl(depth + 1, seen, mint) else {
                        continue;
                    };
                    match node {
                        Self::Split {
                            axis: child_axis,
                            children: grandchildren,
                            ..
                        } if child_axis == *axis => repaired.extend(grandchildren),
                        node => repaired.push(WeightedChild::new(child.weight.repaired(), node)),
                    }
                }
                match repaired.len() {
                    0 => None,
                    1 => repaired.into_iter().next().map(|child| child.node),
                    _ => {
                        Some(Self::Split {
                            id: *id,
                            axis: *axis,
                            children: repaired,
                        })
                    },
                }
            },
        }
    }

    /// The first leaf of a collapsed subtree, still respecting the running duplicate set. A split
    /// with no children at all yields a minted leaf, because the repair never returns an empty
    /// tree.
    fn first_leaf_repaired(&self, seen: &mut BTreeSet<PaneId>, mint: &mut impl FnMut() -> PaneId) -> Self {
        match self {
            Self::Leaf(id) => Self::Leaf(accept_leaf(*id, seen, mint)),
            Self::Split { children, .. } => {
                if let Some(child) = children.first() {
                    child.node.first_leaf_repaired(seen, mint)
                } else {
                    let fresh = mint();
                    Self::Leaf(accept_leaf(fresh, seen, mint))
                }
            },
        }
    }

    /// Every split's flex children reset to an equal share, recursively. Fixed children keep their
    /// points, and the shape and leaf order are untouched — the even-layout idiom.
    #[must_use]
    pub fn rebalanced(&self) -> Self {
        match self {
            Self::Leaf(_) => self.clone(),
            Self::Split { id, axis, children } => {
                Self::Split {
                    id: *id,
                    axis: *axis,
                    children: children
                        .iter()
                        .map(|child| {
                            let weight = match child.weight {
                                SplitWeight::Flex(_) => SplitWeight::Flex(1.0),
                                SplitWeight::Fixed(_) => child.weight,
                            };
                            WeightedChild::new(weight, child.node.rebalanced())
                        })
                        .collect(),
                }
            },
        }
    }
}

/// How many times the repair asks for a replacement id before it gives up on a colliding leaf.
const DUPLICATE_MINT_ATTEMPTS: u32 = 8;

/// Records a leaf id, re-minting it when the tree has already used it.
///
/// A duplicate pane id is not a cosmetic flaw: the live registry is keyed one-to-one by it, so two
/// leaves claiming the same pane would render the same content twice and route input to whichever
/// one the lookup happened to reach. The retry is bounded because a `mint` that keeps returning a
/// seen id is the caller's bug, and taking the last candidate — losing one leaf to the collision —
/// beats hanging the decode over it.
fn accept_leaf(id: PaneId, seen: &mut BTreeSet<PaneId>, mint: &mut impl FnMut() -> PaneId) -> PaneId {
    let mut candidate = id;
    for _ in 0..DUPLICATE_MINT_ATTEMPTS {
        if seen.insert(candidate) {
            return candidate;
        }
        candidate = mint();
    }
    seen.insert(candidate);
    candidate
}

/// The flex share a newly inserted sibling takes: the MEAN of the existing flex children, so the
/// insert lands at an equal share and does not visibly resize its new neighbours. One when there
/// are no flex children to average.
fn insert_weight(children: &[WeightedChild]) -> f64 {
    let mut sum = 0.0;
    let mut count = 0_u32;
    for child in children {
        if let Some(weight) = child.weight.flex() {
            sum += weight;
            count += 1;
        }
    }
    if count == 0 { 1.0 } else { sum / f64::from(count) }
}

/// Splices any child that is itself a split on this axis up into this level.
fn merge_same_axis(children: Vec<WeightedChild>, axis: SplitAxis) -> Vec<WeightedChild> {
    let mut out = Vec::with_capacity(children.len());
    for child in children {
        match child.node {
            SplitNode::Split {
                axis: child_axis,
                children: grandchildren,
                ..
            } if child_axis == axis => out.extend(grandchildren),
            _ => out.push(child),
        }
    }
    out
}

/// Every flex child takes an equal share of the original total, so the freed space redistributes
/// evenly among the survivors. Fixed children keep their points. Sum-preserving, and floored so a
/// degenerate near-zero total cannot drop a pane below the floor.
fn rebalance_flex(children: Vec<WeightedChild>) -> Vec<WeightedChild> {
    let mut sum = 0.0;
    let mut count = 0_u32;
    for child in &children {
        if let Some(weight) = child.weight.flex() {
            sum += weight;
            count += 1;
        }
    }
    if count == 0 {
        return children;
    }
    let share = (sum / f64::from(count)).max(MIN_WEIGHT);
    children
        .into_iter()
        .map(|child| {
            match child.weight {
                SplitWeight::Flex(_) => WeightedChild::new(SplitWeight::Flex(share), child.node),
                SplitWeight::Fixed(_) => child,
            }
        })
        .collect()
}

/// Rewrites the two flex children either side of a divider, preserving their sum.
///
/// `propose` receives the pair's current weights and returns the requested LEADING weight; it is
/// then clamped into `[MIN_WEIGHT, sum - MIN_WEIGHT]` so both children stay above the floor and the
/// sum comes out exactly unchanged. A NaN proposal floors, because the ordered clamp lets the bound
/// win. The children are returned untouched when an index is out of range or either child is fixed.
fn adjust_pair(
    children: &[WeightedChild],
    leading_index: usize,
    propose: &impl Fn(f64, f64) -> f64,
) -> Vec<WeightedChild> {
    let trailing_index = leading_index + 1;
    let (Some(leading), Some(trailing)) = (children.get(leading_index), children.get(trailing_index)) else {
        return children.to_vec();
    };
    let (Some(lead), Some(trail)) = (leading.weight.flex(), trailing.weight.flex()) else {
        return children.to_vec();
    };
    let pair_sum = lead + trail;
    let upper = (pair_sum - MIN_WEIGHT).max(MIN_WEIGHT);
    let new_lead = propose(lead, trail).max(MIN_WEIGHT).min(upper);
    let new_trail = pair_sum - new_lead;

    let mut out = children.to_vec();
    if let Some(slot) = out.get_mut(leading_index) {
        slot.weight = SplitWeight::Flex(new_lead);
    }
    if let Some(slot) = out.get_mut(trailing_index) {
        slot.weight = SplitWeight::Flex(new_trail);
    }
    out
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing subtree is a test failure with nothing to return"
    )]

    use super::{
        EnclosingSplit, MAX_DEPTH, MIN_WEIGHT, PaneDropEdge, SplitAxis, SplitNode, SplitWeight, WeightedChild,
    };
    use crate::identity::{PaneId, SplitNodeId};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn split_id(byte: u8) -> SplitNodeId {
        SplitNodeId::from_bytes([byte; 16])
    }

    fn row(id: u8, children: Vec<WeightedChild>) -> SplitNode {
        SplitNode::Split {
            id: split_id(id),
            axis: SplitAxis::Horizontal,
            children,
        }
    }

    fn column(id: u8, children: Vec<WeightedChild>) -> SplitNode {
        SplitNode::Split {
            id: split_id(id),
            axis: SplitAxis::Vertical,
            children,
        }
    }

    fn weights(node: &SplitNode) -> Vec<f64> {
        match node {
            SplitNode::Leaf(_) => Vec::new(),
            SplitNode::Split { children, .. } => children.iter().filter_map(|c| c.weight.flex()).collect(),
        }
    }

    #[test]
    fn a_lone_leaf_becomes_a_two_child_split() {
        let tree = SplitNode::Leaf(pane(1));
        let Some(split) = tree.splitting(pane(1), SplitAxis::Horizontal, pane(2), false, split_id(9)) else {
            panic!("the target is the tree itself");
        };
        assert_eq!(split.all_pane_ids(), vec![pane(1), pane(2)]);
        assert_eq!(split.depth(), 2);
    }

    #[test]
    fn splitting_before_puts_the_new_pane_on_the_leading_side() {
        let tree = SplitNode::Leaf(pane(1));
        let Some(split) = tree.splitting(pane(1), SplitAxis::Horizontal, pane(2), true, split_id(9)) else {
            panic!("the target is the tree itself");
        };
        assert_eq!(split.all_pane_ids(), vec![pane(2), pane(1)]);
    }

    #[test]
    fn splitting_along_the_parents_own_axis_adds_a_sibling_rather_than_a_nest() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        let Some(split) = tree.splitting(pane(1), SplitAxis::Horizontal, pane(3), false, split_id(9)) else {
            panic!("the target is a direct child");
        };
        assert_eq!(split.all_pane_ids(), vec![pane(1), pane(3), pane(2)]);
        assert_eq!(split.depth(), 2, "no redundant intermediary was minted");
    }

    #[test]
    fn splitting_along_the_other_axis_does_nest() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        let Some(split) = tree.splitting(pane(1), SplitAxis::Vertical, pane(3), false, split_id(9)) else {
            panic!("the target is a direct child");
        };
        assert_eq!(split.all_pane_ids(), vec![pane(1), pane(3), pane(2)]);
        assert_eq!(split.depth(), 3);
    }

    #[test]
    fn splitting_an_absent_pane_is_not_a_tree() {
        let tree = SplitNode::Leaf(pane(1));
        assert!(
            tree.splitting(pane(7), SplitAxis::Horizontal, pane(2), false, split_id(9))
                .is_none(),
        );
    }

    #[test]
    fn an_inserted_sibling_takes_the_mean_share_so_its_neighbours_do_not_jump() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(3.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        let Some(split) = tree.inserting_beside(pane(3), pane(1), SplitAxis::Horizontal, false, split_id(9))
        else {
            panic!("the target is a direct child");
        };
        assert_eq!(weights(&split), vec![3.0, 2.0, 1.0]);
    }

    #[test]
    fn a_dock_onto_a_matching_root_axis_stays_flat() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        let docked = tree.inserting_at_root(pane(3), SplitAxis::Horizontal, true, split_id(9));
        assert_eq!(docked.all_pane_ids(), vec![pane(3), pane(1), pane(2)]);
        assert_eq!(
            docked.depth(),
            2,
            "the full cross-axis span falls out of the flat split"
        );
    }

    #[test]
    fn a_dock_onto_the_other_axis_wraps_the_whole_root() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        let docked = tree.inserting_at_root(pane(3), SplitAxis::Vertical, false, split_id(9));
        assert_eq!(docked.all_pane_ids(), vec![pane(1), pane(2), pane(3)]);
        assert_eq!(docked.depth(), 3);
    }

    #[test]
    fn removing_the_only_pane_empties_the_tree() {
        assert!(SplitNode::Leaf(pane(1)).removing(pane(1)).is_none());
    }

    #[test]
    fn removing_an_absent_pane_leaves_the_tree_alone() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        assert_eq!(tree.removing(pane(7)), Some(tree));
    }

    #[test]
    fn a_single_child_split_collapses_into_its_child() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        assert_eq!(tree.removing(pane(2)), Some(SplitNode::Leaf(pane(1))));
    }

    #[test]
    fn the_survivors_of_a_close_share_the_freed_space_equally() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
            WeightedChild::new(SplitWeight::Flex(4.0), SplitNode::Leaf(pane(3))),
        ]);
        let Some(pruned) = tree.removing(pane(2)) else {
            panic!("two panes survive");
        };
        assert_eq!(
            weights(&pruned),
            vec![2.5, 2.5],
            "the total is conserved and split evenly"
        );
    }

    #[test]
    fn a_collapse_that_floats_a_same_axis_child_merges_it_rather_than_nesting() {
        // V[ H[ V[a, b], c ], d ] losing c collapses the H and would leave V[V[a,b], d].
        let inner = column(2, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        let tree = column(1, vec![
            WeightedChild::new(
                SplitWeight::Flex(1.0),
                row(3, vec![
                    WeightedChild::new(SplitWeight::Flex(1.0), inner),
                    WeightedChild::leaf(pane(3)),
                ]),
            ),
            WeightedChild::leaf(pane(4)),
        ]);
        let Some(pruned) = tree.removing(pane(3)) else {
            panic!("three panes survive");
        };
        assert_eq!(pruned.all_pane_ids(), vec![pane(1), pane(2), pane(4)]);
        assert_eq!(
            pruned.depth(),
            2,
            "the same-axis nest was flattened, not left for the decoder"
        );
    }

    #[test]
    fn a_divider_drag_preserves_the_pair_sum() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        let resized = tree.resizing_divider(split_id(1), 0, 0.3);
        assert_eq!(weights(&resized), vec![1.3, 0.7]);
    }

    #[test]
    fn a_divider_drag_cannot_collapse_either_pane() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        let crushed = tree.resizing_divider(split_id(1), 0, -100.0);
        assert_eq!(weights(&crushed), vec![MIN_WEIGHT, 2.0 - MIN_WEIGHT]);
    }

    #[test]
    fn an_absolute_set_holds_at_the_clamp_instead_of_drifting() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        let over = tree.setting_divider_weight(split_id(1), 0, 99.0);
        // The trailing child takes the REMAINDER, not the floor, so the pair sum is preserved to the
        // bit even at the clamp — which is what stops a long over-drag from leaking width.
        assert_eq!(weights(&over), vec![2.0 - MIN_WEIGHT, 2.0 - (2.0 - MIN_WEIGHT)]);
        // The cursor comes back: the seam resumes exactly where the weight says, with no accumulated
        // drift to unwind.
        let back = over.setting_divider_weight(split_id(1), 0, 1.2);
        assert_eq!(weights(&back), vec![1.2, 0.8]);
    }

    #[test]
    fn evening_one_seam_leaves_every_other_divider_alone() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(3.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
            WeightedChild::new(SplitWeight::Flex(4.0), SplitNode::Leaf(pane(3))),
        ]);
        let evened = tree.evening_divider(split_id(1), 0);
        assert_eq!(weights(&evened), vec![2.0, 2.0, 4.0]);
    }

    #[test]
    fn a_fixed_child_is_never_dragged() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Fixed(200.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        assert_eq!(tree.resizing_divider(split_id(1), 0, 0.5), tree);
    }

    #[test]
    fn a_divider_op_on_an_unknown_split_is_a_no_op() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        assert_eq!(tree.resizing_divider(split_id(200), 0, 0.5), tree);
        assert_eq!(
            tree.resizing_divider(split_id(1), 9, 0.5),
            tree,
            "and so is a stale index"
        );
    }

    #[test]
    fn swapping_moves_the_panes_and_leaves_the_weights_with_the_slots() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(3.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(2))),
        ]);
        let swapped = tree.swapping(pane(1), pane(2));
        assert_eq!(swapped.all_pane_ids(), vec![pane(2), pane(1)]);
        assert_eq!(weights(&swapped), vec![3.0, 1.0]);
    }

    #[test]
    fn swapping_an_absent_pane_changes_nothing() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        assert_eq!(tree.swapping(pane(1), pane(7)), tree);
        assert_eq!(tree.swapping(pane(1), pane(1)), tree);
    }

    #[test]
    fn the_enclosing_split_is_the_one_nearest_the_pane() {
        let inner = row(2, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        // Same axis at both levels — only the decoder's flatten forbids that, and this is the query,
        // so the deepest must still win.
        let tree = SplitNode::Split {
            id: split_id(1),
            axis: SplitAxis::Horizontal,
            children: vec![
                WeightedChild::new(SplitWeight::Flex(1.0), inner),
                WeightedChild::leaf(pane(3)),
            ],
        };
        assert_eq!(
            tree.enclosing_split(pane(1), SplitAxis::Horizontal),
            Some(EnclosingSplit {
                split_id: split_id(2),
                child_index: 0,
                child_count: 2,
            }),
        );
    }

    #[test]
    fn a_pane_under_no_split_on_that_axis_has_no_enclosing_one() {
        let tree = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        assert!(tree.enclosing_split(pane(1), SplitAxis::Vertical).is_none());
        assert!(tree.enclosing_split(pane(7), SplitAxis::Horizontal).is_none());
        assert!(
            SplitNode::Leaf(pane(1))
                .enclosing_split(pane(1), SplitAxis::Horizontal)
                .is_none()
        );
    }

    #[test]
    fn rebalancing_equalizes_the_flex_and_leaves_the_fixed_alone() {
        let tree = row(1, vec![
            WeightedChild::new(SplitWeight::Flex(7.0), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Fixed(200.0), SplitNode::Leaf(pane(2))),
            WeightedChild::new(SplitWeight::Flex(1.0), SplitNode::Leaf(pane(3))),
        ]);
        let even = tree.rebalanced();
        assert_eq!(weights(&even), vec![1.0, 1.0]);
        assert_eq!(even.all_pane_ids(), tree.all_pane_ids(), "the shape is untouched");
    }

    #[test]
    fn structural_equality_ignores_the_split_identities() {
        let a = row(1, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        let b = row(200, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(2)),
        ]);
        assert_ne!(a, b, "derived equality does see the fresh id");
        assert!(
            a.is_structurally_equal(&b),
            "and a no-op drop must not read as an edit"
        );
    }

    #[test]
    fn a_corrupt_weight_is_repaired_rather_than_believed() {
        assert_eq!(
            SplitWeight::Flex(f64::NAN).repaired(),
            SplitWeight::Flex(MIN_WEIGHT)
        );
        assert_eq!(SplitWeight::Flex(-3.0).repaired(), SplitWeight::Flex(MIN_WEIGHT));
        assert_eq!(
            SplitWeight::Fixed(f64::INFINITY).repaired(),
            SplitWeight::Fixed(0.0)
        );
        assert_eq!(
            SplitWeight::Fixed(0.0).repaired(),
            SplitWeight::Fixed(0.0),
            "absent is legal"
        );
    }

    #[test]
    fn a_drop_edge_maps_to_one_axis_and_one_side() {
        assert_eq!(PaneDropEdge::Top.axis(), SplitAxis::Vertical);
        assert_eq!(PaneDropEdge::Left.axis(), SplitAxis::Horizontal);
        assert!(PaneDropEdge::Left.inserts_before() && PaneDropEdge::Top.inserts_before());
        assert!(!PaneDropEdge::Right.inserts_before() && !PaneDropEdge::Bottom.inserts_before());
    }

    /// A mint that walks a fixed sequence, so a repair is reproducible in a test.
    fn minter(mut next: u8) -> impl FnMut() -> PaneId {
        move || {
            let id = pane(next);
            next += 1;
            id
        }
    }

    #[test]
    fn a_well_formed_tree_is_returned_untouched_and_never_mints() {
        let tree = row(9, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::new(SplitWeight::Flex(2.0), SplitNode::Leaf(pane(2))),
        ]);
        let mut minted = 0_u32;
        let Some(repaired) = tree.normalized(&mut || {
            minted += 1;
            pane(200)
        }) else {
            panic!("a valid tree survives");
        };
        assert!(repaired.is_structurally_equal(&tree));
        assert_eq!(weights(&repaired), vec![1.0, 2.0]);
        assert_eq!(minted, 0, "a well-formed tree must not need entropy");
    }

    #[test]
    fn a_single_child_split_collapses_to_its_child() {
        let tree = row(9, vec![WeightedChild::leaf(pane(1))]);
        assert_eq!(tree.normalized(&mut minter(50)), Some(SplitNode::Leaf(pane(1))));
    }

    #[test]
    fn an_empty_split_is_dropped_entirely() {
        assert!(row(9, Vec::new()).normalized(&mut minter(50)).is_none());
    }

    #[test]
    fn an_empty_child_is_dropped_and_its_siblings_stay() {
        let tree = row(9, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::new(SplitWeight::Flex(1.0), column(8, Vec::new())),
            WeightedChild::leaf(pane(2)),
        ]);
        let Some(repaired) = tree.normalized(&mut minter(50)) else {
            panic!("two leaves survive");
        };
        assert_eq!(repaired.all_pane_ids(), vec![pane(1), pane(2)]);
        assert_eq!(repaired.leaf_count(), 2);
    }

    #[test]
    fn a_child_split_sharing_its_parents_axis_is_spliced_in() {
        let tree = row(9, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::new(
                SplitWeight::Flex(1.0),
                row(8, vec![
                    WeightedChild::leaf(pane(2)),
                    WeightedChild::leaf(pane(3)),
                ]),
            ),
        ]);
        let Some(repaired) = tree.normalized(&mut minter(50)) else {
            panic!("three leaves survive");
        };
        assert_eq!(
            repaired.depth(),
            2,
            "the nested row is gone, not merely reweighted"
        );
        assert_eq!(repaired.all_pane_ids(), vec![pane(1), pane(2), pane(3)]);
    }

    #[test]
    fn a_child_split_on_the_other_axis_is_left_nested() {
        let tree = row(9, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::new(
                SplitWeight::Flex(1.0),
                column(8, vec![
                    WeightedChild::leaf(pane(2)),
                    WeightedChild::leaf(pane(3)),
                ]),
            ),
        ]);
        let Some(repaired) = tree.normalized(&mut minter(50)) else {
            panic!("three leaves survive");
        };
        assert_eq!(repaired.depth(), 3);
    }

    #[test]
    fn a_duplicate_pane_id_is_re_minted_so_the_registry_stays_one_to_one() {
        let tree = row(9, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(1)),
        ]);
        let Some(repaired) = tree.normalized(&mut minter(50)) else {
            panic!("both leaves survive");
        };
        assert_eq!(
            repaired.all_pane_ids(),
            vec![pane(1), pane(50)],
            "the FIRST occurrence keeps the id; the later one takes a fresh one",
        );
    }

    #[test]
    fn a_mint_that_keeps_colliding_still_terminates() {
        let tree = row(9, vec![
            WeightedChild::leaf(pane(1)),
            WeightedChild::leaf(pane(1)),
        ]);
        let Some(repaired) = tree.normalized(&mut || pane(1)) else {
            panic!("the repair returns rather than hanging");
        };
        assert_eq!(repaired.all_pane_ids(), vec![pane(1), pane(1)]);
    }

    #[test]
    fn every_weight_is_clamped_on_the_way_through() {
        let tree = row(9, vec![
            WeightedChild::new(SplitWeight::Flex(f64::NAN), SplitNode::Leaf(pane(1))),
            WeightedChild::new(SplitWeight::Flex(-4.0), SplitNode::Leaf(pane(2))),
        ]);
        let Some(repaired) = tree.normalized(&mut minter(50)) else {
            panic!("both leaves survive");
        };
        assert_eq!(weights(&repaired), vec![MIN_WEIGHT, MIN_WEIGHT]);
    }

    #[test]
    fn nesting_past_the_depth_cap_collapses_to_the_first_leaf() {
        // Deeper than MAX_DEPTH by construction: one leaf per level, alternating axis so nothing is
        // flattened by the same-axis splice before the cap can be reached.
        let mut tree = SplitNode::Leaf(pane(1));
        for level in 0..u8::try_from(MAX_DEPTH).unwrap_or(u8::MAX) + 4 {
            let children = vec![
                WeightedChild::new(SplitWeight::Flex(1.0), tree),
                WeightedChild::leaf(pane(100 + level)),
            ];
            tree = if level % 2 == 0 {
                row(level, children)
            } else {
                column(level, children)
            };
        }
        let Some(repaired) = tree.normalized(&mut minter(50)) else {
            panic!("the outermost split survives");
        };
        assert!(
            repaired.depth() <= MAX_DEPTH,
            "the kept structure must respect the cap, not merely the file",
        );
        assert_eq!(
            repaired.all_pane_ids().len(),
            repaired.leaf_count(),
            "collapsing must not leave a duplicate behind",
        );
    }
}
