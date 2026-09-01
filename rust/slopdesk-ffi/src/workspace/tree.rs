//! The split tree: its two shared metrics, the flat walk it crosses as, every operation over it,
//! and the layouts a re-tile answers.
//!
//! The flat encoding is argued at the `// MARK: The tiled tree` banner below, and it is the reason
//! this is one module rather than four — the walk, the operations and the tiler all speak
//! `TreeNode`, and a file that held the shape without the operations would export a vocabulary with
//! no verbs.

use slopdesk_ids::identity::{IdSource, SessionId};
use slopdesk_ids::{PaneId, SplitNodeId, TabId};
use slopdesk_tree::tree_ops::TileLayout;
use slopdesk_tree::{
    Size, SplitAxis, SplitNode, SplitWeight, WeightedChild, geometry, split_layout, split_tree, tree_ops,
};
use slopdesk_workspace::state_codec;

use super::{CPoint, CRect, Frame, Uuid, borrow_array, deliver_id, pane_id};

// MARK: The split tree's two shared metrics

/// The minimum flex weight a divider may take, from the crate that enforces it.
///
/// `repaired()` clamps to this number, so a client that drew or asserted against a transcribed
/// copy would be describing a rule it does not share.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_min_weight() -> f64 {
    split_tree::MIN_WEIGHT
}

/// The deepest nesting a layout may KEEP, from the crate that caps it.
///
/// It sat beside [`slopdesk_ws_min_weight`] as a transcribed `12` on the Swift side until
/// 2026-08-20, and `docs/55` §8 named the pair as the anti-pattern it is: two numbers with one
/// meaning, one asked for through a door and one written down again, where the second is only
/// right until somebody tunes the first. Three separate rules clamp to it — the persisted split
/// tree's decode, the template layout's repair, and the solver recursion both of them feed — so a
/// caller that disagreed about it would build a tree the crate refuses to walk.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_depth() -> usize {
    split_tree::MAX_DEPTH
}

/// The schema version the persisted workspace shape writes, from the crate that owns the shape.
///
/// It is the version a load COMPARES against, and there is no migration behind the comparison — a
/// file carrying any other number is set aside. So the two spellings could not have been caught by
/// a test: they agreed, and the day one of them was bumped alone the near side would either keep
/// writing a version the far side calls stale, or set aside every file the far side just wrote.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_schema_version() -> i64 {
    slopdesk_tree::CURRENT_SCHEMA_VERSION
}

/// The longest a string field may be, from the codec that clamps it.
///
/// `slopdesk_ws_encode_string` takes the bound as an argument, because a field's own limit is not
/// always the protocol's — a `renameTab` name is clamped tighter than a title. A caller with no
/// tighter limit of its own asks for the protocol's HERE rather than writing the number down: the
/// number is a wire property, and a near side that disagreed about it would either refuse a value
/// the far end accepts or offer one it drops.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_string_bytes() -> usize {
    state_codec::MAX_STRING_BYTES
}

// MARK: The tiled tree
//
// ## Why the tree crosses FLAT and not as its own JSON
// Both languages already agree on a persisted encoding for a `SplitNode`, and reusing it here would
// have been two lines. It is the wrong instrument: `solve` runs on every layout pass, and a parse
// plus an allocation per frame is exactly the kind of regression `CLAUDE.md` says is the only veto
// on a port. So the tree crosses as its PRE-ORDER walk — one array, one pass, no parse — and the
// persisted codec stays what it is for, which is disk.
//
// ## The shape, and what makes it total
// Each node carries how many DIRECT children follow it. A well-formed array is consumed exactly; a
// hostile one — a `child_count` that overruns, a truncated tail — stops the walk and answers `None`
// rather than indexing past the end. That is the same obligation every entry point here carries,
// and it matters more for this one: a tree arrives from a peer over the workspace channel, not just
// from the client's own memory.

/// One node of the pre-order walk.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TreeNode {
    /// 0 leaf · 1 split. Total: anything else reads as a leaf, which is the shape that cannot
    /// recurse and so cannot be made to walk off the end.
    pub kind: u8,
    /// A leaf's pane id, or a split's divider-group id.
    pub id: Uuid,
    /// 0 horizontal (columns) · 1 vertical (rows). Splits only.
    pub axis: u8,
    /// Whether this node's own share is a FIXED extent in points rather than a flex share.
    pub weight_is_fixed: bool,
    /// How many direct children follow, in order. Leaves carry 0.
    pub child_count: u32,
    /// This node's share within its parent. The root's is ignored — it has no parent to share with.
    pub weight: f64,
}

impl TreeNode {
    const fn split_weight(self) -> SplitWeight {
        if self.weight_is_fixed {
            SplitWeight::Fixed(self.weight)
        } else {
            SplitWeight::Flex(self.weight)
        }
    }
}

/// Rebuilds one subtree from `nodes[*cursor..]`, advancing the cursor past everything it consumed.
///
/// `None` for a truncated or over-claiming array. Recursion is bounded by the array's length,
/// because every level consumes at least one node before descending.
pub(crate) fn decode_tree(nodes: &[TreeNode], cursor: &mut usize) -> Option<SplitNode> {
    let node = *nodes.get(*cursor)?;
    *cursor += 1;
    if node.kind != 1 {
        return Some(SplitNode::Leaf(PaneId::from_bytes(node.id.bytes)));
    }
    let count = usize::try_from(node.child_count).ok()?;
    let mut children = Vec::with_capacity(count.min(nodes.len()));
    for _ in 0..count {
        let child = *nodes.get(*cursor)?;
        let subtree = decode_tree(nodes, cursor)?;
        children.push(WeightedChild::new(child.split_weight(), subtree));
    }
    Some(SplitNode::Split {
        id: SplitNodeId::from_bytes(node.id.bytes),
        axis: if node.axis == 1 {
            SplitAxis::Vertical
        } else {
            SplitAxis::Horizontal
        },
        children,
    })
}

/// Borrows a caller's pre-order walk as a tree.
///
/// # Safety
/// `nodes` must be null, or point to `count` initialised [`TreeNode`]s live for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C array pointer becoming a slice"
)]
pub(crate) unsafe fn borrow_tree(nodes: *const TreeNode, count: usize) -> Option<SplitNode> {
    // SAFETY: the caller's obligation, restated above; `borrow_array` states its own.
    let walk = unsafe { borrow_array(nodes, count) };
    let mut cursor = 0;
    decode_tree(walk, &mut cursor)
}

/// One child's share, for the partition that does not need the subtrees under it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Share {
    /// Fixed points rather than a flex share.
    pub is_fixed: bool,
    /// The magnitude.
    pub value: f64,
}

/// The default floor on a solved leaf, from the crate rather than transcribed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_min_leaf() -> CPoint {
    let size = geometry::MIN_ITEM_SIZE;
    CPoint {
        x: size.width,
        y: size.height,
    }
}

/// Tiles `nodes` inside `rect`, answering one frame per leaf.
///
/// Returns the leaf count NEEDED, or 0 for a tree the walk could not rebuild — which is the same
/// answer an empty tree gives, and the right one either way: nothing to draw.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`
/// [`Frame`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_solve_layout(
    nodes: *const TreeNode,
    count: usize,
    rect: CRect,
    min_width: f64,
    min_height: f64,
    out: *mut Frame,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return 0;
        };
        let solved = split_layout::solve(&root, rect.resolve(), Size::new(min_width, min_height));
        let frames: Vec<Frame> = solved
            .frames
            .iter()
            .map(|(pane, frame)| {
                Frame {
                    id: Uuid { bytes: pane.bytes() },
                    rect: CRect::of(*frame),
                }
            })
            .collect();
        deliver_frames(&frames, out, cap)
    }
}

/// Writes a frame array under §4's convention.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`Frame`]s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
const unsafe fn deliver_frames(frames: &[Frame], out: *mut Frame, cap: usize) -> usize {
    if frames.len() > cap || out.is_null() {
        return frames.len();
    }
    // SAFETY: `frames.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `frames` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(frames.as_ptr(), out, frames.len()) };
    frames.len()
}

/// One draggable seam, flat.
///
/// The rect is where the handle is drawn and hit; everything after it is what a DRAG needs — the
/// span it converts pixels against, the flex sum it converts them into, and the pair of weights it
/// moves between. They ride the same struct because the two predicates below are answered from
/// them alone, so a caller that has a handle never has to reassemble one.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct DividerHandle {
    /// The split that owns the seam.
    pub split: Uuid,
    /// The LEADING child's index: the seam is between it and the next child.
    pub child_index: u32,
    /// 0 horizontal (a column seam, dragged left/right) · 1 vertical.
    pub axis: u8,
    /// The handle's band.
    pub rect: CRect,
    /// The owning split's axis length — a NESTED split's own, not the container's.
    pub parent_span: f64,
    /// The owning split's flex-weight sum.
    pub flex_sum: f64,
    /// The leading child's flex weight; `0` for a fixed child, which is not draggable.
    pub leading_weight: f64,
    /// The trailing child's flex weight; `0` fixed.
    pub trailing_weight: f64,
}

impl DividerHandle {
    pub(crate) const fn of(divider: &split_layout::Divider) -> Self {
        Self {
            split: Uuid {
                bytes: divider.split.bytes(),
            },
            #[expect(
                clippy::cast_possible_truncation,
                reason = "a child index counts siblings of one split; the decoder caps a tree far below 2^32"
            )]
            child_index: divider.child_index as u32,
            axis: if matches!(divider.axis, SplitAxis::Vertical) {
                1
            } else {
                0
            },
            rect: CRect::of(divider.rect),
            parent_span: divider.parent_span,
            flex_sum: divider.flex_sum,
            leading_weight: divider.leading_weight,
            trailing_weight: divider.trailing_weight,
        }
    }

    /// The rule's own shape again, so the two predicates read one implementation.
    const fn resolve(self) -> split_layout::Divider {
        split_layout::Divider {
            split: SplitNodeId::from_bytes(self.split.bytes),
            child_index: self.child_index as usize,
            axis: axis_from(self.axis),
            rect: self.rect.resolve(),
            parent_span: self.parent_span,
            flex_sum: self.flex_sum,
            leading_weight: self.leading_weight,
            trailing_weight: self.trailing_weight,
        }
    }
}

/// The band thickness a seam is drawn and hit with.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_divider_thickness() -> f64 {
    split_layout::DIVIDER_THICKNESS
}

/// Every seam of `nodes` solved into `rect`, in pre-order.
///
/// Returns the seam count NEEDED, or 0 for a tree the walk could not rebuild — the same answer a
/// single leaf gives, and the right one either way: nothing to drag.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`
/// [`DividerHandle`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_dividers(
    nodes: *const TreeNode,
    count: usize,
    rect: CRect,
    thickness: f64,
    out: *mut DividerHandle,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return 0;
        };
        let handles: Vec<DividerHandle> = split_layout::dividers(&root, rect.resolve(), thickness)
            .iter()
            .map(DividerHandle::of)
            .collect();
        if handles.len() > cap || out.is_null() {
            return handles.len();
        }
        // SAFETY: `handles.len() <= cap`, `out` is writable for `cap` by the caller's obligation,
        // and `handles` was allocated inside this call so it cannot overlap.
        core::ptr::copy_nonoverlapping(handles.as_ptr(), out, handles.len());
        handles.len()
    }
}

/// Whether `handle` can still be dragged toward one of its children — the hover cursor's one-way
/// versus two-way answer, from the same floor the drag clamps at.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_divider_can_move(handle: DividerHandle, toward_leading: bool) -> bool {
    let divider = handle.resolve();
    if toward_leading {
        divider.can_move_toward_leading()
    } else {
        divider.can_move_toward_trailing()
    }
}

/// A live drag's proposed leading weight, clamped so both panes keep their pixel floor.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_divider_clamped_weight(handle: DividerHandle, proposed: f64) -> f64 {
    handle.resolve().clamped_leading_weight(proposed)
}

/// One incremental pixel drag along `handle`'s axis, as the flex-weight delta to offset from.
///
/// The seam's own span and flex sum are already inside the handle, so a caller cannot pair one
/// split's span with another's partition. A handle without geometry answers `0`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_divider_weight_delta(handle: DividerHandle, pixel_increment: f64) -> f64 {
    handle.resolve().weight_delta(pixel_increment)
}

/// The live drag's ratio readout: the pair as whole percentages that sum to exactly 100.
///
/// `false` is a degenerate pair — a fixed side, or float residue — and then neither out-param is
/// touched: the readout is ABSENT rather than wrong. The two percentages cross as two numbers
/// rather than one plus a complement, so no caller can round the second one itself.
///
/// # Safety
/// `leading` and `trailing` must each be null or point to one writable `u32`, live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_divider_percents(
    handle: DividerHandle,
    leading: *mut u32,
    trailing: *mut u32,
) -> bool {
    let Some((lead, trail)) = handle.resolve().split_percents() else {
        return false;
    };
    // SAFETY: the caller's obligations, restated above.
    unsafe {
        if !leading.is_null() {
            leading.write(lead);
        }
        if !trailing.is_null() {
            trailing.write(trail);
        }
    }
    true
}

// MARK: The tree's own operations
//
// Every one of these ANSWERS a tree, so the walk crosses in both directions. The encoder below is
// the exact inverse of `decode_tree`, and the round trip is what the Swift tests already assert —
// they compare whole `SplitNode` values, so a lossy leg would fail loudly rather than subtly.
//
// Each op is its own entry point rather than one dispatcher with a wide argument list. A dispatcher
// would be less Swift, but `slopdesk_ws_tree_splitting(nodes, count, target, axis, new_leaf, …)`
// says which arguments it reads and a `(op, a, b, index, value)` tuple does not — and this is the
// boundary where a mis-assigned argument is a silently rearranged layout.

/// Appends `node` and its subtree to a pre-order walk, at the share it holds within its parent.
pub(crate) fn encode_tree(node: &SplitNode, weight: SplitWeight, walk: &mut Vec<TreeNode>) {
    let (is_fixed, magnitude) = match weight {
        SplitWeight::Flex(share) => (false, share),
        SplitWeight::Fixed(points) => (true, points),
    };
    match node {
        SplitNode::Leaf(pane) => {
            walk.push(TreeNode {
                kind: 0,
                id: Uuid { bytes: pane.bytes() },
                axis: 0,
                weight_is_fixed: is_fixed,
                child_count: 0,
                weight: magnitude,
            });
        },
        SplitNode::Split { id, axis, children } => {
            walk.push(TreeNode {
                kind: 1,
                id: Uuid { bytes: id.bytes() },
                axis: u8::from(*axis == SplitAxis::Vertical),
                weight_is_fixed: is_fixed,
                child_count: u32::try_from(children.len()).unwrap_or(u32::MAX),
                weight: magnitude,
            });
            for child in children {
                encode_tree(&child.node, child.weight, walk);
            }
        },
    }
}

/// Writes an answered tree under §4's convention, with [`usize::MAX`] for an op that did not apply.
///
/// The two are different answers and the caller must be able to tell them apart: "this pane is not
/// in this tree" has to leave the arrangement alone, where a zero-node tree would erase it.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`TreeNode`]s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
unsafe fn deliver_tree(answer: Option<SplitNode>, out: *mut TreeNode, cap: usize) -> usize {
    let Some(tree) = answer else {
        return usize::MAX;
    };
    let mut walk = Vec::new();
    encode_tree(&tree, SplitWeight::Flex(1.0), &mut walk);
    if walk.len() > cap || out.is_null() {
        return walk.len();
    }
    // SAFETY: `walk.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `walk` was allocated inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(walk.as_ptr(), out, walk.len()) };
    walk.len()
}

/// The axis a byte names. Total, defaulting to horizontal — columns, the arrangement a fresh split
/// makes when nobody said otherwise.
const fn axis_from(byte: u8) -> SplitAxis {
    if byte == 1 {
        SplitAxis::Vertical
    } else {
        SplitAxis::Horizontal
    }
}

/// Runs `op` over the tree in `nodes` and writes what it answered.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: reading and writing through the caller's pointers"
)]
unsafe fn tree_op(
    nodes: *const TreeNode,
    count: usize,
    out: *mut TreeNode,
    cap: usize,
    op: impl FnOnce(&SplitNode) -> Option<SplitNode>,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return usize::MAX;
        };
        deliver_tree(op(&root), out, cap)
    }
}

/// Splits `target` in two, the new leaf taking half of what it had.
///
/// [`usize::MAX`] when `target` is not in this tree — the arrangement is then left alone, which is
/// not the same as being replaced by an empty one.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `out` null or writable for `cap`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_splitting(
    nodes: *const TreeNode,
    count: usize,
    target: Uuid,
    axis: u8,
    new_leaf: Uuid,
    before: bool,
    fresh_split: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            root.splitting(
                pane_id(target),
                axis_from(axis),
                pane_id(new_leaf),
                before,
                SplitNodeId::from_bytes(fresh_split.bytes),
            )
        })
    }
}

/// Inserts an EXISTING leaf beside `target`, which is the drag-to-dock gesture rather than a split.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_inserting_beside(
    nodes: *const TreeNode,
    count: usize,
    leaf: Uuid,
    target: Uuid,
    axis: u8,
    before: bool,
    fresh_split: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            root.inserting_beside(
                pane_id(leaf),
                pane_id(target),
                axis_from(axis),
                before,
                SplitNodeId::from_bytes(fresh_split.bytes),
            )
        })
    }
}

/// Docks a leaf against the whole container's edge. Always applies, so never [`usize::MAX`].
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_inserting_at_root(
    nodes: *const TreeNode,
    count: usize,
    leaf: Uuid,
    axis: u8,
    before: bool,
    fresh_split: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.inserting_at_root(
                pane_id(leaf),
                axis_from(axis),
                before,
                SplitNodeId::from_bytes(fresh_split.bytes),
            ))
        })
    }
}

/// Closes a pane, the survivors dividing what it had. [`usize::MAX`] when it was the last one — the
/// tab is then empty, which is the caller's decision to act on, not this function's.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_removing(
    nodes: *const TreeNode,
    count: usize,
    target: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe { tree_op(nodes, count, out, cap, |root| root.removing(pane_id(target))) }
}

/// Drags one divider by `delta`, its two neighbours trading the difference.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_resizing_divider(
    nodes: *const TreeNode,
    count: usize,
    split: Uuid,
    leading_index: usize,
    delta: f64,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.resizing_divider(SplitNodeId::from_bytes(split.bytes), leading_index, delta))
        })
    }
}

/// Evens ONE seam — both its children take their pair mean. Every other divider is untouched, which
/// is what makes this different from a rebalance.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_evening_divider(
    nodes: *const TreeNode,
    count: usize,
    split: Uuid,
    leading_index: usize,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.evening_divider(SplitNodeId::from_bytes(split.bytes), leading_index))
        })
    }
}

/// Sets a divider's ABSOLUTE leading weight, the trailing sibling taking the remainder — the
/// cursor-matched form used during a live drag.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_setting_divider_weight(
    nodes: *const TreeNode,
    count: usize,
    split: Uuid,
    leading_index: usize,
    leading_weight: f64,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.setting_divider_weight(
                SplitNodeId::from_bytes(split.bytes),
                leading_index,
                leading_weight,
            ))
        })
    }
}

/// Exchanges two panes' positions, every weight staying where it was.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_swapping(
    nodes: *const TreeNode,
    count: usize,
    a: Uuid,
    b: Uuid,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe {
        tree_op(nodes, count, out, cap, |root| {
            Some(root.swapping(pane_id(a), pane_id(b)))
        })
    }
}

/// Resets every weight in the tree to an equal share.
///
/// # Safety
/// As [`slopdesk_ws_tree_splitting`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_rebalanced(
    nodes: *const TreeNode,
    count: usize,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `tree_op` states its own.
    unsafe { tree_op(nodes, count, out, cap, |root| Some(root.rebalanced())) }
}

/// Where a pane sits relative to the nearest enclosing split on an axis — which divider a resize
/// keystroke should move, and how many siblings share it.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Enclosing {
    /// The split's identity.
    pub split: Uuid,
    /// The index of that split's DIRECT child subtree holding the pane.
    pub child_index: usize,
    /// How many children that split has.
    pub child_count: usize,
}

/// The nearest split enclosing `pane` on `axis`. False when there is none — the pane occupies that
/// axis alone, and there is no divider for a keystroke to move.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `answer` null or writable for one
/// [`Enclosing`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_enclosing_split(
    nodes: *const TreeNode,
    count: usize,
    pane: Uuid,
    axis: u8,
    answer: *mut Enclosing,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow_tree` states its own.
    let Some(root) = (unsafe { borrow_tree(nodes, count) }) else {
        return false;
    };
    let Some(found) = root.enclosing_split(pane_id(pane), axis_from(axis)) else {
        return false;
    };
    if !answer.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `Enclosing`.
        unsafe {
            *answer = Enclosing {
                split: Uuid {
                    bytes: found.split_id.bytes(),
                },
                child_index: found.child_index,
                child_count: found.child_count,
            };
        }
    }
    true
}

/// The first leaf in pre-order — where focus lands when a tab has no better answer. False for a
/// tree the walk could not rebuild.
///
/// # Safety
/// `nodes` must be null or point to `count` live [`TreeNode`]s; `answer` null or writable for one
/// [`Uuid`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_first_leaf(
    nodes: *const TreeNode,
    count: usize,
    answer: *mut Uuid,
) -> bool {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let Some(root) = borrow_tree(nodes, count) else {
            return false;
        };
        let Some(first) = root.first_leaf_id() else {
            return false;
        };
        deliver_id(first.bytes(), answer)
    }
}

/// Whether two trees have the same SHAPE and the same panes in the same places, ignoring every
/// weight and every split identity.
///
/// The question a persistence round trip asks: a restore that repaired a divider position still
/// restored the same arrangement, and reporting that as a change would make every launch look
/// dirty.
///
/// # Safety
/// Both `(nodes, count)` pairs must be null or point to that many live [`TreeNode`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_tree_structurally_equal(
    left: *const TreeNode,
    left_count: usize,
    right: *const TreeNode,
    right_count: usize,
) -> bool {
    // SAFETY: the caller's obligations, restated above; `borrow_tree` states its own.
    let (Some(lhs), Some(rhs)) = (unsafe { borrow_tree(left, left_count) }, unsafe {
        borrow_tree(right, right_count)
    }) else {
        return false;
    };
    lhs.is_structurally_equal(&rhs)
}

// MARK: The re-tile layouts
//
// `tree_ops::rebuild` builds the tree; the workspace-level `apply_layout` around it does not cross,
// because it takes and answers a whole `TreeWorkspace` — sessions, tabs, titles, specs — and that
// document is what SwiftUI diffs. What crosses is the leaf ORDER in and the tree out, which is the
// only part of a re-tile that is a decision.

/// A caller's pool of pre-minted identities, handed out in order.
///
/// The crate mints nothing (`identity.rs`), and a re-tile needs one identity per split it creates.
/// Rather than trampolining into Swift per split, the caller passes a pool and this walks it. A
/// pool that runs dry repeats its last entry rather than panicking — see [`slopdesk_ws_retile`] for
/// why the documented pool size makes that unreachable.
struct Pool<'a> {
    splits: &'a [Uuid],
    next: usize,
}

impl IdSource for Pool<'_> {
    fn pane(&mut self) -> PaneId {
        // A re-tile preserves every leaf, so it never asks for one. Answering the first entry keeps
        // the trait total without inventing an identity the caller did not supply.
        PaneId::from_bytes(self.splits.first().map_or([0; 16], |id| id.bytes))
    }

    fn tab(&mut self) -> TabId {
        TabId::from_bytes(self.splits.first().map_or([0; 16], |id| id.bytes))
    }

    fn session(&mut self) -> SessionId {
        SessionId::from_bytes(self.splits.first().map_or([0; 16], |id| id.bytes))
    }

    fn split(&mut self) -> SplitNodeId {
        let picked = self.splits.get(self.next).or_else(|| self.splits.last());
        self.next += 1;
        SplitNodeId::from_bytes(picked.map_or([0; 16], |id| id.bytes))
    }
}

/// The tree a re-tile layout makes over `leaves`, in the caller's order.
///
/// `layout` is `LayoutPreset`'s case index: evenHorizontal, evenVertical, mainVertical,
/// mainHorizontal, tiled. The main-\* layouts take the FIRST leaf as the large one, so a caller
/// that wants the active pane there passes it first — putting that choice at the call site, where
/// the notion of "active" lives, rather than in the tiler.
///
/// `splits` is the identity pool. A tiled layout of `n` leaves creates at most `n` splits (one row
/// node per row, plus the outer), so `n + 1` entries is always enough and the pool cannot run dry.
///
/// Fewer than two leaves answers nothing: a one-child split would violate the tree's arity rule,
/// which is a no-op at the call site rather than a tree to install.
///
/// # Safety
/// `leaves` must be null or point to `count` live [`Uuid`]s, `splits` null or to `split_count` live
/// ones, and `out` null or writable for `cap` [`TreeNode`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_retile(
    leaves: *const Uuid,
    count: usize,
    layout: u8,
    splits: *const Uuid,
    split_count: usize,
    out: *mut TreeNode,
    cap: usize,
) -> usize {
    if leaves.is_null() || count < 2 {
        return usize::MAX;
    }
    // `TileLayout::ALL`'s order, not a second copy of it. An unknown byte re-tiles as one even row,
    // which is the layout a caller that named nothing meaningful should get.
    let layout = TileLayout::from_index(layout).unwrap_or(TileLayout::EvenHorizontal);
    // SAFETY: non-null and, by the caller's obligation, `count` live `Uuid`s for the call.
    let panes: Vec<PaneId> = unsafe { core::slice::from_raw_parts(leaves, count) }
        .iter()
        .map(|id| PaneId::from_bytes(id.bytes))
        .collect();
    let pool: &[Uuid] = if splits.is_null() || split_count == 0 {
        &[]
    } else {
        // SAFETY: non-null and, by the caller's obligation, `split_count` live `Uuid`s.
        unsafe { core::slice::from_raw_parts(splits, split_count) }
    };
    let mut ids = Pool {
        splits: pool,
        next: 0,
    };
    // SAFETY: the caller's obligation, restated above; `deliver_tree` states its own.
    unsafe { deliver_tree(Some(tree_ops::rebuild(layout, &panes, &mut ids)), out, cap) }
}
