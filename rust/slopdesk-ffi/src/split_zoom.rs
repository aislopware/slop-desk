//! What a split tab renders once zoom has had its say, in C.
//!
//! The rules are [`slopdesk_workspace::split_zoom`]; what is here is the marshalling.
//!
//! ## Why the SEAMS have a door here as well
//!
//! `slopdesk_ws_dividers` already answers a tree's draggable seams, and a zoomed tab has none. It
//! would have been one line on the near side to ask for them and then not draw them — and that one
//! line would be a second copy of the zoom verdict, sitting in a renderer, where nobody would look
//! for it when the first copy changed. So [`slopdesk_ws_render_dividers`] takes the zoom and
//! answers 0 while one is active. The near side asks unconditionally and draws what it is given.
//!
//! ## The tree crosses as its walk, the same one the partition already takes
//!
//! Not the persisted JSON: this runs on every layout pass, and a parse plus an allocation per frame
//! is what `CLAUDE.md` says vetoes a port. The walk is `slopdesk_ws_solve_layout`'s, decoded by the
//! same decoder, so a tree that solver refuses is a tree these doors refuse too.
//!
//! ## Zoom is an OPTIONAL pane id, which is a flag and a value
//!
//! `docs/55` §4b: an absent optional crosses as a value plus a presence flag, never a pointer.
//! Every sixteen-byte pattern is a legitimate pane id — including the all-zero one — so a sentinel
//! would have collided with a real pane.

use slopdesk_ids::PaneId;
use slopdesk_tree::geometry::Size;
use slopdesk_workspace::split_zoom;

use crate::optional_of;
use crate::workspace::{CRect, DividerHandle, Frame, TreeNode, Uuid, borrow_tree};

/// One placed pane, and whether the zoom is hiding it.
///
/// The hidden ones are the point: a pane the renderer stops emitting is a pane the view unmounts,
/// and unmounting one dismantles the terminal surface or video stream behind it. So every pane of
/// the tab comes back on every layout, and this flag is what the view draws at `opacity 0` instead.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RenderLeaf {
    /// Which pane, and where.
    pub frame: Frame,
    /// ZOOM-hidden: mounted and laid out at its UN-zoomed rect, not drawn and not hit-tested.
    pub hidden: bool,
}

/// The zoomed pane a caller named, if it named one.
const fn zoom_of(has_zoom: bool, zoomed: Uuid) -> Option<PaneId> {
    match optional_of(has_zoom, zoomed) {
        Some(id) => Some(PaneId::from_bytes(id.bytes)),
        None => None,
    }
}

/// Whether a tab is zoomed: `zoomed` is named AND is a leaf of this tree.
///
/// A zoom naming a pane that has since been closed is IGNORED — honouring it would collapse the tab
/// onto a pane that does not exist, which renders as an empty window with no way out. Scalar in and
/// scalar out: there is nothing to size and nothing to retry.
///
/// # Safety
/// `nodes` must be null, or point to `count` live [`TreeNode`]s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `nodes` is the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_zoom_is_active(
    nodes: *const TreeNode,
    count: usize,
    has_zoom: bool,
    zoomed: Uuid,
) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(root) = (unsafe { borrow_tree(nodes, count) }) else {
        return false;
    };
    split_zoom::is_zoom_active(&root, zoom_of(has_zoom, zoomed))
}

/// Every pane of the tab, placed and tagged, in the tree's PRE-ORDER.
///
/// Visible leaves come first — one of them while a zoom is active, all of them otherwise — and the
/// zoom-hidden ones trail in the same order behind. A pane appears exactly once, so the caller can
/// key ONE collection on the id and never see a duplicate or a gap: the whole reason the answer is
/// one array rather than two is that a pane crossing the hidden↔visible line must not move between
/// collections, which is what makes a view tear its surface down.
///
/// Returns the leaf count NEEDED, or 0 for a tree the walk could not rebuild — the same answer an
/// empty tree gives, and the right one either way: nothing to draw.
///
/// # Safety
/// `nodes` must be null, or point to `count` live [`TreeNode`]s; `out` null, or writable for `cap`
/// [`RenderLeaf`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_render_leaves(
    nodes: *const TreeNode,
    count: usize,
    rect: CRect,
    min_width: f64,
    min_height: f64,
    has_zoom: bool,
    zoomed: Uuid,
    out: *mut RenderLeaf,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(root) = (unsafe { borrow_tree(nodes, count) }) else {
        return 0;
    };
    let layout = split_zoom::render(
        &root,
        rect.resolve(),
        zoom_of(has_zoom, zoomed),
        Size::new(min_width, min_height),
        // The seams are the other door's; this one never places one, so its band does not matter.
        0.0,
    );
    let leaves: Vec<RenderLeaf> = layout
        .leaves
        .iter()
        .map(|leaf| {
            RenderLeaf {
                frame: Frame {
                    id: Uuid {
                        bytes: leaf.pane.bytes(),
                    },
                    rect: CRect::of(leaf.rect),
                },
                hidden: leaf.hidden,
            }
        })
        .collect();
    // SAFETY: the caller's obligation, restated above; `deliver_items` writes at most `cap`.
    unsafe { deliver_items(&leaves, out, cap) }
}

/// The seams this tab actually DRAWS: every one of the tree's, or none while a zoom is active.
///
/// The zoom gate is here rather than at the call site for the reason the module header gives — a
/// renderer that decided for itself would be the second copy of the verdict.
///
/// Returns the seam count needed. 0 is a lone leaf, a tree the walk could not rebuild, and a zoomed
/// tab; all three draw nothing, so nothing distinguishes them to a caller.
///
/// # Safety
/// `nodes` must be null, or point to `count` live [`TreeNode`]s; `out` null, or writable for `cap`
/// [`DividerHandle`]s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_ws_render_dividers(
    nodes: *const TreeNode,
    count: usize,
    rect: CRect,
    thickness: f64,
    has_zoom: bool,
    zoomed: Uuid,
    out: *mut DividerHandle,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(root) = (unsafe { borrow_tree(nodes, count) }) else {
        return 0;
    };
    let layout = split_zoom::render(
        &root,
        rect.resolve(),
        zoom_of(has_zoom, zoomed),
        // The leaf floor is the leaves' door's; a seam is placed on the UN-clamped partition, so
        // nothing this door answers reads it.
        Size::new(0.0, 0.0),
        thickness,
    );
    let seams: Vec<DividerHandle> = layout.dividers.iter().map(DividerHandle::of).collect();
    // SAFETY: the caller's obligation, restated above; `deliver_items` writes at most `cap`.
    unsafe { deliver_items(&seams, out, cap) }
}

/// Writes an array of plain values under §4's convention.
///
/// # Safety
/// `out` must be null, or writable for `cap` `T`s for the call.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: writing through a caller's pointer"
)]
const unsafe fn deliver_items<T: Copy>(items: &[T], out: *mut T, cap: usize) -> usize {
    if items.len() > cap || out.is_null() {
        return items.len();
    }
    // SAFETY: `items.len() <= cap`, `out` is non-null and writable for `cap` by the caller's
    // obligation, and `items` was built inside this call so it cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(items.as_ptr(), out, items.len()) };
    items.len()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
    #![expect(
        clippy::panic,
        reason = "an unreachable branch in a test IS the report — a silent `return` would pass"
    )]

    use super::{
        RenderLeaf, slopdesk_ws_render_dividers, slopdesk_ws_render_leaves, slopdesk_ws_zoom_is_active,
    };
    use crate::workspace::{CRect, DividerHandle, Frame, TreeNode, Uuid};

    const BOUNDS: CRect = CRect {
        x: 0.0,
        y: 0.0,
        width: 400.0,
        height: 300.0,
    };

    const fn id(byte: u8) -> Uuid {
        Uuid { bytes: [byte; 16] }
    }

    const fn node(kind: u8, id: Uuid, child_count: u32) -> TreeNode {
        TreeNode {
            kind,
            id,
            axis: 0,
            weight_is_fixed: false,
            child_count,
            weight: 1.0,
        }
    }

    /// `[a | b]` as its pre-order walk, the shape every door here takes.
    fn two_leaves(a: Uuid, b: Uuid) -> Vec<TreeNode> {
        vec![node(1, id(9), 2), node(0, a, 0), node(0, b, 0)]
    }

    const fn blank() -> RenderLeaf {
        RenderLeaf {
            frame: Frame {
                id: id(0),
                rect: BOUNDS,
            },
            hidden: true,
        }
    }

    /// Runs the leaves door with the two-call retry the convention describes.
    fn leaves(walk: &[TreeNode], has_zoom: bool, zoomed: Uuid) -> Vec<RenderLeaf> {
        let ask = |out: *mut RenderLeaf, cap: usize| unsafe {
            slopdesk_ws_render_leaves(
                walk.as_ptr(),
                walk.len(),
                BOUNDS,
                80.0,
                60.0,
                has_zoom,
                zoomed,
                out,
                cap,
            )
        };
        let needed = ask(core::ptr::null_mut(), 0);
        let mut out = vec![blank(); needed];
        let written = ask(out.as_mut_ptr(), out.len());
        assert_eq!(
            written, needed,
            "the size answer did not change under a second call"
        );
        out
    }

    fn seams(walk: &[TreeNode], has_zoom: bool, zoomed: Uuid) -> usize {
        unsafe {
            slopdesk_ws_render_dividers(
                walk.as_ptr(),
                walk.len(),
                BOUNDS,
                16.0,
                has_zoom,
                zoomed,
                core::ptr::null_mut(),
                0,
            )
        }
    }

    /// A zoomed tab: one visible leaf at the whole bound, the sibling still emitted and hidden, and
    /// no seams — the three halves of the render that must agree.
    #[test]
    fn a_zoomed_tab_crosses_as_one_visible_leaf_and_a_mounted_sibling() {
        let walk = two_leaves(id(1), id(2));
        let placed = leaves(&walk, true, id(2));
        assert_eq!(placed.len(), 2, "every pane of the tab is still emitted");
        let Some(first) = placed.first() else {
            panic!("two leaves")
        };
        assert!(!first.hidden);
        assert_eq!(first.frame.id.bytes, id(2).bytes);
        assert!((first.frame.rect.width - BOUNDS.width).abs() < f64::EPSILON);
        assert!((first.frame.rect.height - BOUNDS.height).abs() < f64::EPSILON);
        assert!(placed.iter().skip(1).all(|leaf| leaf.hidden));
        assert_eq!(seams(&walk, true, id(2)), 0, "a zoomed tab draws no seams");
    }

    /// Un-zoomed: both leaves visible, in the WALK's order, and the one seam between them. The
    /// leading leaf's id sorts after the trailing one's, so an id-ordered answer would swap them.
    #[test]
    fn an_unzoomed_tab_crosses_tiled_with_its_seam() {
        let walk = two_leaves(id(9), id(1));
        let placed = leaves(&walk, false, id(0));
        assert_eq!(placed.len(), 2);
        assert!(placed.iter().all(|leaf| !leaf.hidden));
        let order: Vec<[u8; 16]> = placed.iter().map(|leaf| leaf.frame.id.bytes).collect();
        assert_eq!(order, vec![id(9).bytes, id(1).bytes], "pre-order, not id order");
        assert_eq!(seams(&walk, false, id(0)), 1);
    }

    /// The zoom verdict, and the stale id that must not be honoured.
    #[test]
    fn the_verdict_needs_a_pane_this_tree_actually_holds() {
        let walk = two_leaves(id(1), id(2));
        assert!(unsafe { slopdesk_ws_zoom_is_active(walk.as_ptr(), walk.len(), true, id(1)) });
        assert!(!unsafe { slopdesk_ws_zoom_is_active(walk.as_ptr(), walk.len(), false, id(1)) });
        assert!(!unsafe { slopdesk_ws_zoom_is_active(walk.as_ptr(), walk.len(), true, id(99)) });
        // And a stale zoom falls through to the tiled layout rather than collapsing the tab.
        let placed = leaves(&walk, true, id(99));
        assert_eq!(placed.len(), 2);
        assert!(placed.iter().all(|leaf| !leaf.hidden));
        assert_eq!(seams(&walk, true, id(99)), 1);
    }

    /// A walk the decoder refuses answers nothing rather than reading past its end — the totality
    /// every door here owes a tree that can arrive from a peer.
    #[test]
    fn a_malformed_walk_answers_nothing_from_all_three_doors() {
        // A split claiming two children and carrying one.
        let walk = vec![node(1, id(9), 2), node(0, id(1), 0)];
        assert_eq!(leaves(&walk, false, id(0)).len(), 0);
        assert_eq!(seams(&walk, false, id(0)), 0);
        assert!(!unsafe { slopdesk_ws_zoom_is_active(walk.as_ptr(), walk.len(), true, id(1)) });
        // A null walk is the same nothing.
        assert!(!unsafe { slopdesk_ws_zoom_is_active(core::ptr::null(), 0, true, id(1)) });
        assert_eq!(
            unsafe {
                slopdesk_ws_render_leaves(
                    core::ptr::null(),
                    0,
                    BOUNDS,
                    80.0,
                    60.0,
                    false,
                    id(0),
                    core::ptr::null_mut(),
                    0,
                )
            },
            0,
        );
    }

    /// An undersized buffer writes NOTHING and reports the size, which is the convention's whole
    /// contract — a partially filled array of leaves would be a layout missing panes.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_reports_what_it_needed() {
        let walk = two_leaves(id(1), id(2));
        let mut one = [blank()];
        let needed = unsafe {
            slopdesk_ws_render_leaves(
                walk.as_ptr(),
                walk.len(),
                BOUNDS,
                80.0,
                60.0,
                false,
                id(0),
                one.as_mut_ptr(),
                1,
            )
        };
        assert_eq!(needed, 2);
        assert!(one.first().is_some_and(|leaf| leaf.hidden), "untouched");

        let mut none: [DividerHandle; 0] = [];
        assert_eq!(
            unsafe {
                slopdesk_ws_render_dividers(
                    walk.as_ptr(),
                    walk.len(),
                    BOUNDS,
                    16.0,
                    false,
                    id(0),
                    none.as_mut_ptr(),
                    0,
                )
            },
            1,
        );
    }
}
