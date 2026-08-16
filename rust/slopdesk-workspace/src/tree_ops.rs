//! Every operation a gesture or an intent performs on the arrangement.
//!
//! Each one takes a workspace and answers a NEW one — no in-place mutation, no I/O, no view. Each
//! preserves the two families of invariant [`crate::workspace`] states: the spec table matches the
//! panes, and no selection dangles. That is what lets a caller run one of these and hand the result
//! straight to a reconcile.
//!
//! ## A no-op is a value, never an error
//!
//! Every op answers the workspace UNCHANGED when its target is absent, when the two panes are in
//! different sessions, or when the result would breach the depth cap. There is no error channel,
//! because there is nothing a caller could do with one: a gesture aimed at a pane that just closed
//! is not a failure, it is a gesture with nothing to do.
//!
//! ## Identity is passed in, never invented
//!
//! An op that needs a fresh pane, tab, session or split takes an [`IdSource`]. The reason is
//! [`crate::identity`]'s: with the entropy outside, the same inputs give the same tree forever —
//! and an INTENT can supply the id the host already chose, so a client's optimistic overlay inserts
//! the same leaf the host will, rather than one it has to reconcile away a round trip later.
//!
//! ## Relocation keeps the id
//!
//! Every move, dock and reattach carries the pane's [`PaneId`] across. That is not tidiness: the
//! id is the join to the live process, so a moved pane's PTY or video stream survives the move and
//! only its geometry changes. Minting a new id would tear the session down and open another.

use std::collections::BTreeMap;

use crate::focus::{self, FocusDirection};
use crate::geometry::{Point, Rect, Size};
use crate::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
use crate::session::{DetachedPane, NewTabPosition, PaneSpec, Session, Tab};
use crate::split_layout;
use crate::split_tree::{MAX_DEPTH, PaneDropEdge, SplitAxis, SplitNode, SplitWeight, WeightedChild};
use crate::workspace::TreeWorkspace;

/// The square a close solves its tab into to pick the next focus.
///
/// Any finite square would do — the direction of a neighbour is scale-invariant — and the minimum
/// leaf size is deliberately zero here, so a pane too small to render still counts as a neighbour
/// rather than being clamped on top of another.
const REFOCUS_BOUND: f64 = 1000.0;

// ---------------------------------------------------------------------------------------------- //
// Locating
// ---------------------------------------------------------------------------------------------- //

/// The session and tab INDEX owning a pane.
///
/// Indices rather than ids because every op below then edits in place; the ids are what cross the
/// wire, and [`TreeWorkspace::location_of`] is the version that answers those.
#[must_use]
pub fn locate(ws: &TreeWorkspace, pane: PaneId) -> Option<(usize, usize)> {
    ws.sessions
        .iter()
        .enumerate()
        .find_map(|(index, session)| session.tab_index_containing(pane).map(|tab| (index, tab)))
}

/// The session and tab index of a tab.
#[must_use]
pub fn locate_tab(ws: &TreeWorkspace, tab: TabId) -> Option<(usize, usize)> {
    ws.sessions.iter().enumerate().find_map(|(index, session)| {
        session
            .tabs
            .iter()
            .position(|candidate| candidate.id == tab)
            .map(|position| (index, position))
    })
}

/// Runs an edit against one tab, answering the workspace unchanged when the edit declines.
///
/// The shape most ops below share: the edit reports whether it did anything, and a `false` means
/// the caller gets the ORIGINAL value rather than a clone that happens to be equal — so a rejected
/// gesture cannot churn a save.
fn editing_tab(
    ws: &TreeWorkspace,
    session: usize,
    tab: usize,
    edit: impl FnOnce(&mut Tab) -> bool,
) -> TreeWorkspace {
    let mut next = ws.clone();
    let Some(target) = next
        .sessions
        .get_mut(session)
        .and_then(|session| session.tabs.get_mut(tab))
    else {
        return ws.clone();
    };
    if edit(target) { next } else { ws.clone() }
}

/// The same, one level up: an edit against a whole session.
fn editing_session(
    ws: &TreeWorkspace,
    session: usize,
    edit: impl FnOnce(&mut Session) -> bool,
) -> TreeWorkspace {
    let mut next = ws.clone();
    let Some(target) = next.sessions.get_mut(session) else {
        return ws.clone();
    };
    if edit(target) { next } else { ws.clone() }
}

/// The geometric neighbour of a pane within its tab — the focus a close falls back to.
///
/// Each cardinal direction is tried in turn and the first surviving pane wins; with no neighbour at
/// all, the first OTHER leaf in pre-order does. The point is that focus lands somewhere the person
/// was already looking, rather than jumping to the front of the tree.
fn neighbour(pane: PaneId, tab: &Tab) -> Option<PaneId> {
    let bound = Rect::new(Point::ZERO, Size::new(REFOCUS_BOUND, REFOCUS_BOUND));
    let solved = split_layout::solve(&tab.root, bound, Size::ZERO);
    for direction in [
        FocusDirection::Left,
        FocusDirection::Right,
        FocusDirection::Up,
        FocusDirection::Down,
    ] {
        if let Some(found) = focus::neighbor(pane, direction, &solved)
            && found != pane
        {
            return Some(found);
        }
    }
    tab.root.all_pane_ids().into_iter().find(|id| *id != pane)
}

// ---------------------------------------------------------------------------------------------- //
// Split and close
// ---------------------------------------------------------------------------------------------- //

/// Splits a pane along an axis, the new leaf carrying `spec` and taking focus.
///
/// The new leaf becomes a sibling when the parent split already runs on `axis`, else the target
/// becomes a two-child split. `before` puts the new pane on the target's LEADING side. Splitting
/// while zoomed exits zoom, because the newly focused pane has to be visible.
#[must_use]
pub fn split_pane(
    ws: &TreeWorkspace,
    target: PaneId,
    axis: SplitAxis,
    spec: PaneSpec,
    before: bool,
    pane: PaneId,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate(ws, target) else {
        return ws.clone();
    };
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(tab) = session.tabs.get_mut(tab_index) else {
        return ws.clone();
    };
    let Some(root) = tab.root.splitting(target, axis, pane, before, fresh_split) else {
        return ws.clone();
    };
    tab.root = root;
    tab.active_pane = Some(pane);
    tab.zoomed_pane = None;
    session.specs.insert(pane, spec);
    next
}

/// Closes a pane, cascading as far as the close reaches.
///
/// The tab's last pane closing closes the tab; the session's last tab closing closes the session;
/// the workspace's last pane closing re-seeds a default — the workspace is never empty. A dangling
/// zoom is cleared and focus moves to a geometric neighbour.
///
/// `successor` is consulted ONLY on the cascade, when the tab itself closes. It is the caller's
/// considered choice, which needs the project keys the tree does not carry; the index clamp
/// survives as the fallback for a caller with no opinion.
#[must_use]
pub fn close_pane(
    ws: &TreeWorkspace,
    target: PaneId,
    successor: Option<TabId>,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate(ws, target) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(tab) = session.tabs.get_mut(tab_index) else {
        return ws.clone();
    };
    // The replacement focus is chosen BEFORE the tree mutates — afterwards the closing pane has no
    // position to be a neighbour of.
    let refocus = neighbour(target, tab);
    let pruned = tab.root.removing(target);
    session.specs.remove(&target);

    let Some(root) = pruned else {
        session.tabs.remove(tab_index);
        return cascade_after_tab_removal(&next, session_index, tab_index, successor, ids).normalized(ids);
    };
    if tab.zoomed_pane == Some(target) {
        tab.zoomed_pane = None;
    }
    if tab.active_pane == Some(target) {
        tab.active_pane = refocus.or_else(|| root.first_leaf_id());
    }
    tab.root = root;
    next.normalizing_specs()
}

/// Housekeeping after a tab left a session: drop the session if it is now empty, re-seed if that
/// was the last one, else select the successor.
fn cascade_after_tab_removal(
    ws: &TreeWorkspace,
    session_index: usize,
    removed_tab_index: usize,
    successor: Option<TabId>,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some(session) = ws.sessions.get(session_index) else {
        return ws.clone();
    };
    if session.tabs.is_empty() {
        // A session that still owns DETACHED panes survives its last tab closing — the person closed
        // a TAB, not the satellites, and dropping the session here would orphan their specs and tear
        // live streams down mid-use. The selection repair re-seeds a default tab so the session
        // stays renderable. An explicit `close_session` still drops everything, satellites included.
        if !session.detached.is_empty() {
            return ws.clone();
        }
        let removed = session.id;
        let mut next = ws.clone();
        next.sessions.remove(session_index);
        if next.sessions.is_empty() {
            return TreeWorkspace::default_workspace(ids.session(), ids.tab(), ids.pane());
        }
        if next.active_session_id == Some(removed) {
            let index = session_index.min(next.sessions.len().saturating_sub(1));
            next.active_session_id = next.sessions.get(index).map(|session| session.id);
        }
        return next;
    }
    editing_session(ws, session_index, |session| {
        let index = successor
            .and_then(|id| session.tabs.iter().position(|tab| tab.id == id))
            .unwrap_or_else(|| removed_tab_index.min(session.tabs.len().saturating_sub(1)));
        session.active_tab_index = index;
        true
    })
}

/// Toggles render-only zoom on a pane. The split TREE is untouched — zoom is out-of-tree state.
#[must_use]
pub fn toggle_zoom(ws: &TreeWorkspace, target: PaneId) -> TreeWorkspace {
    let Some((session, tab_index)) = locate(ws, target) else {
        return ws.clone();
    };
    editing_tab(ws, session, tab_index, |tab| {
        tab.zoomed_pane = if tab.zoomed_pane == Some(target) {
            None
        } else {
            Some(target)
        };
        true
    })
}

// ---------------------------------------------------------------------------------------------- //
// Dividers
// ---------------------------------------------------------------------------------------------- //

/// The active session's active tab index, when there is one.
fn active_tab_index(ws: &TreeWorkspace) -> Option<(usize, usize)> {
    let session_index = ws.active_session_index()?;
    let session = ws.sessions.get(session_index)?;
    (session.active_tab_index < session.tabs.len()).then_some((session_index, session.active_tab_index))
}

/// Shifts flex weight across one divider of the active tab. Sum-preserving and clamped, so neither
/// neighbour can be dragged out of existence.
#[must_use]
pub fn resize_divider(
    ws: &TreeWorkspace,
    split: SplitNodeId,
    leading_index: usize,
    delta: f64,
) -> TreeWorkspace {
    let Some((session, tab_index)) = active_tab_index(ws) else {
        return ws.clone();
    };
    editing_tab(ws, session, tab_index, |tab| {
        tab.root = tab.root.resizing_divider(split, leading_index, delta);
        true
    })
}

/// Evens ONLY the clicked seam, leaving every other dragged ratio intact — the divider
/// double-click, unlike [`balance_splits`], which evens the whole tab.
#[must_use]
pub fn even_divider(ws: &TreeWorkspace, split: SplitNodeId, leading_index: usize) -> TreeWorkspace {
    let Some((session, tab_index)) = active_tab_index(ws) else {
        return ws.clone();
    };
    editing_tab(ws, session, tab_index, |tab| {
        tab.root = tab.root.evening_divider(split, leading_index);
        true
    })
}

/// Sets a divider's leading weight to an ABSOLUTE value — the cursor-matched form for a live drag,
/// where an accumulated delta would drift away from the pointer and never come back.
#[must_use]
pub fn set_divider_weight(
    ws: &TreeWorkspace,
    split: SplitNodeId,
    leading_index: usize,
    leading_weight: f64,
) -> TreeWorkspace {
    let Some((session, tab_index)) = active_tab_index(ws) else {
        return ws.clone();
    };
    editing_tab(ws, session, tab_index, |tab| {
        tab.root = tab
            .root
            .setting_divider_weight(split, leading_index, leading_weight);
        true
    })
}

/// Grows or shrinks a pane by nudging the nearest enclosing divider on the relevant axis — the
/// keyboard counterpart to a drag-resize.
///
/// A non-last child is governed by the divider to its right; the LAST child has none, so the one to
/// its left governs it with the sign flipped. The underlying nudge is clamped, so the active pane
/// can never starve a sibling to nothing.
#[must_use]
pub fn resize_active_pane(
    ws: &TreeWorkspace,
    pane: PaneId,
    direction: FocusDirection,
    step: f64,
) -> TreeWorkspace {
    let (axis, grow) = match direction {
        FocusDirection::Left => (SplitAxis::Horizontal, false),
        FocusDirection::Right => (SplitAxis::Horizontal, true),
        FocusDirection::Up => (SplitAxis::Vertical, false),
        FocusDirection::Down => (SplitAxis::Vertical, true),
        FocusDirection::Next | FocusDirection::Previous => return ws.clone(),
    };
    let Some((session_index, tab_index)) = locate(ws, pane) else {
        return ws.clone();
    };
    let Some(enclosing) = ws
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.get(tab_index))
        .and_then(|tab| tab.root.enclosing_split(pane, axis))
    else {
        return ws.clone();
    };
    let last_index = enclosing.child_count.saturating_sub(1);
    let (leading_index, delta) = if enclosing.child_index < last_index {
        (enclosing.child_index, if grow { step } else { -step })
    } else {
        (
            enclosing.child_index.saturating_sub(1),
            if grow { -step } else { step },
        )
    };
    // The LOCATED tab is edited directly rather than the active-tab-scoped `resize_divider`, so the
    // nudge lands even when the pane is in a tab nobody is looking at.
    editing_tab(ws, session_index, tab_index, |tab| {
        tab.root = tab
            .root
            .resizing_divider(enclosing.split_id, leading_index, delta);
        true
    })
}

/// Resets every flex child in a tab to an equal share, leaving fixed bands untouched. The shape and
/// the leaf set are unchanged — only the weights equalize.
#[must_use]
pub fn balance_splits(ws: &TreeWorkspace, pane: PaneId) -> TreeWorkspace {
    let Some((session, tab_index)) = locate(ws, pane) else {
        return ws.clone();
    };
    editing_tab(ws, session, tab_index, |tab| {
        tab.root = tab.root.rebalanced();
        true
    })
}

// ---------------------------------------------------------------------------------------------- //
// Move, swap, dock
// ---------------------------------------------------------------------------------------------- //

/// Exchanges two panes' positions, within one tab. The weights stay with the slot; only the
/// identities move, so the spec table and the leaf set are untouched.
#[must_use]
pub fn swap_panes(ws: &TreeWorkspace, a: PaneId, b: PaneId) -> TreeWorkspace {
    if a == b {
        return ws.clone();
    }
    let (Some(left), Some(right)) = (locate(ws, a), locate(ws, b)) else {
        return ws.clone();
    };
    if left != right {
        return ws.clone();
    }
    editing_tab(ws, left.0, left.1, |tab| {
        tab.root = tab.root.swapping(a, b);
        true
    })
}

/// Relocates a pane beside another along an axis — the drag-drop re-split.
///
/// The source is pruned from its slot exactly as a close would and re-inserted as the target's
/// sibling, KEEPING its id. Dropping side-by-side panes onto each other's top or bottom edge is how
/// a horizontal split becomes vertical.
///
/// Declines a cross-axis insert that would breach [`MAX_DEPTH`] — a tree the decoder would later
/// truncate loses a leaf, which is a live surface — and declines a drop that reproduces the
/// arrangement it started from, which would otherwise churn a save under a freshly minted split id.
#[must_use]
pub fn move_leaf(
    ws: &TreeWorkspace,
    source: PaneId,
    target: PaneId,
    axis: SplitAxis,
    before: bool,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    if source == target {
        return ws.clone();
    }
    let (Some(from), Some(to)) = (locate(ws, source), locate(ws, target)) else {
        return ws.clone();
    };
    if from != to {
        return ws.clone();
    }
    let fresh_split = ids.split();
    editing_tab(ws, from.0, from.1, |tab| {
        // The prune can never empty the tab — the target shares it — but it is checked rather than
        // assumed, because the alternative is a silent leaf loss.
        let Some(pruned) = tab.root.removing(source) else {
            return false;
        };
        let Some(relocated) = pruned.inserting_beside(source, target, axis, before, fresh_split) else {
            return false;
        };
        if relocated.depth() > MAX_DEPTH || relocated.is_structurally_equal(&tab.root) {
            return false;
        }
        tab.root = relocated;
        tab.active_pane = Some(source);
        true
    })
}

/// Docks a pane at the OUTERMOST edge of its own tab — the drag-into-the-gutter commit, where the
/// pane becomes a full-span column or row.
///
/// A lone-leaf tab has nothing to dock against, and wrapping it would duplicate the id.
#[must_use]
pub fn move_leaf_to_root_edge(
    ws: &TreeWorkspace,
    source: PaneId,
    edge: PaneDropEdge,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session, tab_index)) = locate(ws, source) else {
        return ws.clone();
    };
    let fresh_split = ids.split();
    editing_tab(ws, session, tab_index, |tab| {
        if tab.root.leaf_count() <= 1 {
            return false;
        }
        let Some(pruned) = tab.root.removing(source) else {
            return false;
        };
        let relocated = pruned.inserting_at_root(source, edge.axis(), edge.inserts_before(), fresh_split);
        if relocated.depth() > MAX_DEPTH || relocated.is_structurally_equal(&tab.root) {
            return false;
        }
        tab.root = relocated;
        tab.active_pane = Some(source);
        true
    })
}

/// The cross-tab superset of [`move_leaf`], backing the rail drag of an already-streamed window.
///
/// Within one tab this IS [`move_leaf`]. Across tabs of the same SESSION the source leaves its tab
/// — a tab it was the sole leaf of is removed outright — and lands beside the target, keeping its
/// id, so the live session survives the move. The destination tab is selected with the pane focused
/// and zoom exited. Never crosses sessions: a spec lives in one session's side table.
#[must_use]
pub fn move_leaf_across_tabs(
    ws: &TreeWorkspace,
    source: PaneId,
    target: PaneId,
    axis: SplitAxis,
    before: bool,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    if source == target {
        return ws.clone();
    }
    let (Some((source_session, source_tab)), Some((target_session, target_tab))) =
        (locate(ws, source), locate(ws, target))
    else {
        return ws.clone();
    };
    if source_session != target_session {
        return ws.clone();
    }
    if source_tab == target_tab {
        return move_leaf(ws, source, target, axis, before, ids);
    }
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(source_session) else {
        return ws.clone();
    };
    // The destination is validated BEFORE the source tab is touched, so a rejected insert leaves the
    // workspace whole.
    let Some(destination) = session.tabs.get(target_tab).cloned() else {
        return ws.clone();
    };
    let Some(grown) = destination
        .root
        .inserting_beside(source, target, axis, before, fresh_split)
    else {
        return ws.clone();
    };
    if grown.depth() > MAX_DEPTH {
        return ws.clone();
    }
    prune_leaf_from_tab(session, source, source_tab);
    // Removing the source tab may have shifted the destination — it is re-resolved by id.
    let Some(index) = session.tabs.iter().position(|tab| tab.id == destination.id) else {
        return ws.clone();
    };
    let Some(tab) = session.tabs.get_mut(index) else {
        return ws.clone();
    };
    tab.root = grown;
    tab.active_pane = Some(source);
    tab.zoomed_pane = None;
    session.active_tab_index = index;
    next
}

/// The cross-tab superset of [`move_leaf_to_root_edge`] — the rail-drag gutter drop.
///
/// Unlike the same-tab dock this works against a lone-leaf destination: there IS something to dock
/// beside, namely the destination's own leaf.
#[must_use]
pub fn move_leaf_to_tab_root_edge(
    ws: &TreeWorkspace,
    source: PaneId,
    destination: TabId,
    edge: PaneDropEdge,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, source_tab)) = locate(ws, source) else {
        return ws.clone();
    };
    let Some(target_index) = ws
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.iter().position(|tab| tab.id == destination))
    else {
        return ws.clone();
    };
    if source_tab == target_index {
        return move_leaf_to_root_edge(ws, source, edge, ids);
    }
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(target_tab) = session.tabs.get(target_index).cloned() else {
        return ws.clone();
    };
    let grown = target_tab
        .root
        .inserting_at_root(source, edge.axis(), edge.inserts_before(), fresh_split);
    if grown.depth() > MAX_DEPTH {
        return ws.clone();
    }
    prune_leaf_from_tab(session, source, source_tab);
    let Some(index) = session.tabs.iter().position(|tab| tab.id == target_tab.id) else {
        return ws.clone();
    };
    let Some(tab) = session.tabs.get_mut(index) else {
        return ws.clone();
    };
    tab.root = grown;
    tab.active_pane = Some(source);
    tab.zoomed_pane = None;
    session.active_tab_index = index;
    next
}

/// [`move_leaf_to_tab_root_edge`] aimed at the ACTIVE tab — the local gesture, where the
/// destination is wherever the person is looking.
///
/// Also declines when the source lives outside the active session: a drop onto "the active tab"
/// from another window's session names a destination the dragger is not even showing.
#[must_use]
pub fn move_leaf_to_active_tab_root_edge(
    ws: &TreeWorkspace,
    source: PaneId,
    edge: PaneDropEdge,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, _)) = locate(ws, source) else {
        return ws.clone();
    };
    if ws.active_session_index() != Some(session_index) {
        return ws.clone();
    }
    let Some(destination) = ws
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.get(session.active_tab_index))
        .map(|tab| tab.id)
    else {
        return ws.clone();
    };
    move_leaf_to_tab_root_edge(ws, source, destination, edge, ids)
}

/// Removes a leaf from one tab for a cross-tab move: the tab shrinks, or — when the leaf was its
/// sole one — the tab goes.
///
/// The spec is deliberately NOT dropped: the pane lives on in another tab, and a caller holding a
/// tab index re-resolves it afterwards, because a removal shifts them.
fn prune_leaf_from_tab(session: &mut Session, source: PaneId, index: usize) {
    let Some(tab) = session.tabs.get_mut(index) else {
        return;
    };
    if let Some(pruned) = tab.root.removing(source) {
        if tab.zoomed_pane == Some(source) {
            tab.zoomed_pane = None;
        }
        if tab.active_pane == Some(source) {
            tab.active_pane = pruned.first_leaf_id();
        }
        tab.root = pruned;
    } else {
        session.tabs.remove(index);
    }
}

/// Inserts a NEW leaf at the outermost edge of the active tab — the mint-a-pane sibling of
/// [`move_leaf_to_root_edge`].
///
/// Because it creates rather than relocates, it also works on a lone-leaf tab: a split against the
/// only pane. The new pane takes focus and a zoom is exited.
#[must_use]
pub fn insert_pane_at_root_edge(
    ws: &TreeWorkspace,
    spec: PaneSpec,
    edge: PaneDropEdge,
    pane: PaneId,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, tab_index)) = active_tab_index(ws) else {
        return ws.clone();
    };
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(tab) = session.tabs.get_mut(tab_index) else {
        return ws.clone();
    };
    let grown = tab
        .root
        .inserting_at_root(pane, edge.axis(), edge.inserts_before(), fresh_split);
    if grown.depth() > MAX_DEPTH {
        return ws.clone();
    }
    tab.root = grown;
    tab.active_pane = Some(pane);
    tab.zoomed_pane = None;
    session.specs.insert(pane, spec);
    next
}

/// Moves a pane in a direction by EXCHANGING it with its geometric neighbour on that side.
///
/// The neighbour is resolved against the tab solved into `bounds` — the geometry the person
/// actually sees — so "move left" means what it looks like. Cycling has no swap meaning, so it is a
/// no-op.
#[must_use]
pub fn move_pane_in_direction(
    ws: &TreeWorkspace,
    pane: PaneId,
    direction: FocusDirection,
    bounds: Rect,
) -> TreeWorkspace {
    if !direction.is_directional() {
        return ws.clone();
    }
    let Some((session_index, tab_index)) = locate(ws, pane) else {
        return ws.clone();
    };
    let Some(tab) = ws
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.get(tab_index))
    else {
        return ws.clone();
    };
    let solved = split_layout::solve_default(&tab.root, bounds);
    let Some(found) = focus::neighbor(pane, direction, &solved).filter(|found| *found != pane) else {
        return ws.clone();
    };
    swap_panes(ws, pane, found)
}

// ---------------------------------------------------------------------------------------------- //
// Re-tile
// ---------------------------------------------------------------------------------------------- //

/// The algorithmic re-tile arrangements, in the order [`cycle_layout`] steps through them.
///
/// Named `TileLayout` rather than the Swift `LayoutPreset` because a
/// [`LayoutPreset`](crate::canvas::LayoutPreset) already exists and means something else entirely:
/// a SAVED canvas the person built, not an algorithm that rebuilds a tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum TileLayout {
    /// Every leaf side by side in one row.
    #[default]
    EvenHorizontal,
    /// Every leaf stacked in one column.
    EvenVertical,
    /// The active leaf large on the LEFT, the rest evenly stacked to its right.
    MainVertical,
    /// The active leaf large on TOP, the rest evenly in a row below.
    MainHorizontal,
    /// A balanced grid of roughly even rows and columns.
    Tiled,
}

impl TileLayout {
    /// Every layout, in cycle order.
    pub const ALL: [Self; 5] = [
        Self::EvenHorizontal,
        Self::EvenVertical,
        Self::MainVertical,
        Self::MainHorizontal,
        Self::Tiled,
    ];

    /// The persisted spelling.
    #[must_use]
    pub const fn raw(self) -> &'static str {
        match self {
            Self::EvenHorizontal => "evenHorizontal",
            Self::EvenVertical => "evenVertical",
            Self::MainVertical => "mainVertical",
            Self::MainHorizontal => "mainHorizontal",
            Self::Tiled => "tiled",
        }
    }

    /// The layout a persisted spelling names.
    #[must_use]
    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|layout| layout.raw() == raw)
    }

    /// The byte for this layout — [`Self::ALL`]'s position, which is what crosses the ABI.
    ///
    /// The persisted spelling above and this byte are two different encodings of the same enum, and
    /// only the spelling had an inverse. The shim restated the byte map by hand and fell back to
    /// `EvenHorizontal`, so a sixth layout would have silently re-tiled as a single row.
    #[must_use]
    pub const fn index(self) -> u8 {
        match self {
            Self::EvenHorizontal => 0,
            Self::EvenVertical => 1,
            Self::MainVertical => 2,
            Self::MainHorizontal => 3,
            Self::Tiled => 4,
        }
    }

    /// The layout a byte names, or `None` when it names none.
    #[must_use]
    pub fn from_index(index: u8) -> Option<Self> {
        Self::ALL.get(usize::from(index)).copied()
    }

    /// The next layout in cycle order, wrapping.
    #[must_use]
    pub fn next(self) -> Self {
        let index = Self::ALL.iter().position(|layout| *layout == self).unwrap_or(0);
        Self::ALL
            .get((index + 1) % Self::ALL.len())
            .copied()
            .unwrap_or(Self::EvenHorizontal)
    }
}

/// Re-tiles the tab owning a pane, PRESERVING every leaf id — a pure geometry change, so nothing is
/// materialized or torn down.
///
/// Every divider ratio resets to an equal share; prior drags are discarded on purpose, which is
/// what a re-tile means. Leaf order is the tab's pre-order, except that the main-\* layouts move
/// the ACTIVE leaf to the front to become the large pane. A zoom is cleared first, because
/// re-tiling under a full-screen zoom is meaningless. A tab of fewer than two leaves is a no-op: a
/// one-child split would violate the tree's own arity rule.
#[must_use]
pub fn apply_layout(
    ws: &TreeWorkspace,
    layout: TileLayout,
    pane: PaneId,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate(ws, pane) else {
        return ws.clone();
    };
    let Some(tab) = ws
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.get(tab_index))
    else {
        return ws.clone();
    };
    let order = tab.root.all_pane_ids();
    if order.len() <= 1 {
        return ws.clone();
    }
    let active = tab.active_pane.filter(|id| order.contains(id));
    let leaves = match (layout, active) {
        (TileLayout::MainVertical | TileLayout::MainHorizontal, Some(active)) => {
            let mut ordered = vec![active];
            ordered.extend(order.iter().copied().filter(|id| *id != active));
            ordered
        },
        _ => order,
    };
    let root = rebuild(layout, &leaves, ids);
    editing_tab(ws, session_index, tab_index, |tab| {
        tab.root = root;
        tab.zoomed_pane = None;
        true
    })
    .normalizing_specs()
}

/// Advances one step through [`TileLayout::ALL`] and re-tiles into it, answering the layout applied
/// so the caller can store it as the next cursor.
///
/// A tab of fewer than two leaves still advances the returned layout — the cursor moves — while the
/// tree itself is left alone.
#[must_use]
pub fn cycle_layout(
    ws: &TreeWorkspace,
    pane: PaneId,
    current: Option<TileLayout>,
    ids: &mut impl IdSource,
) -> (TreeWorkspace, TileLayout) {
    let next = current.map_or(TileLayout::EvenHorizontal, TileLayout::next);
    (apply_layout(ws, next, pane, ids), next)
}

/// The flat (depth ≤ 2) tree a layout makes over `leaves`, which the caller guarantees has at least
/// two entries.
///
/// `pub` so the FFI shim re-tiles through this exact body rather than through a copy of it: the
/// shim has the leaf order and nothing else, where [`apply_layout`] needs a whole workspace to find
/// that order in. One implementation of "tiled", two callers.
///
/// Every child carries an equal share, and every split takes a fresh identity from `ids` — a
/// single-child intermediary collapses to the bare leaf, because a one-child split would violate
/// the tree's own arity rule.
#[must_use]
pub fn rebuild(layout: TileLayout, leaves: &[PaneId], ids: &mut impl IdSource) -> SplitNode {
    match layout {
        TileLayout::EvenHorizontal => flat_split(SplitAxis::Horizontal, leaves, ids),
        TileLayout::EvenVertical => flat_split(SplitAxis::Vertical, leaves, ids),
        TileLayout::MainVertical => main_split(SplitAxis::Horizontal, SplitAxis::Vertical, leaves, ids),
        TileLayout::MainHorizontal => main_split(SplitAxis::Vertical, SplitAxis::Horizontal, leaves, ids),
        TileLayout::Tiled => tiled(leaves, ids),
    }
}

/// The main-\* shape: the first leaf against everything else, split the other way.
fn main_split(outer: SplitAxis, inner: SplitAxis, leaves: &[PaneId], ids: &mut impl IdSource) -> SplitNode {
    let Some((first, rest)) = leaves.split_first() else {
        return flat_split(outer, leaves, ids);
    };
    let companion = flat_split(inner, rest, ids);
    SplitNode::Split {
        id: ids.split(),
        axis: outer,
        children: vec![even_child(SplitNode::Leaf(*first)), even_child(companion)],
    }
}

/// A split of these leaves along one axis — but a single leaf stays a bare leaf, never a one-child
/// split.
fn flat_split(axis: SplitAxis, leaves: &[PaneId], ids: &mut impl IdSource) -> SplitNode {
    if let [only] = leaves {
        return SplitNode::Leaf(*only);
    }
    SplitNode::Split {
        id: ids.split(),
        axis,
        children: leaves.iter().map(|id| even_child(SplitNode::Leaf(*id))).collect(),
    }
}

/// A balanced grid: rows of near-equal width, stacked.
///
/// The column count grows by integer steps while `cols * cols < n`, and the row count the same way
/// — no `ceil(sqrt(n))`, so there is no floating rounding edge to get wrong at a perfect square.
/// The leaves spread across rows as near-equal SLICES, the first few rows taking one extra, rather
/// than each row greedily packing to `cols` and the last one taking whatever is left: seven panes
/// tile as 3/2/2, not 3/3/1.
fn tiled(leaves: &[PaneId], ids: &mut impl IdSource) -> SplitNode {
    let count = leaves.len();
    let mut cols = 1;
    while cols * cols < count {
        cols += 1;
    }
    let mut rows = 1;
    while rows * cols < count {
        rows += 1;
    }
    // Round-robin over the rows gives exactly the near-equal slices: row `r` takes one leaf for each
    // index congruent to it, which is the base width plus one for the first few rows.
    let mut widths = vec![0_usize; rows];
    for index in 0..count {
        if let Some(width) = widths.get_mut(index % rows) {
            *width += 1;
        }
    }
    let mut row_nodes = Vec::with_capacity(rows);
    let mut start = 0;
    for width in widths {
        let end = (start + width).min(count);
        if let Some(slice) = leaves.get(start..end) {
            row_nodes.push(flat_split(SplitAxis::Horizontal, slice, ids));
        }
        start = end;
    }
    if let [only] = row_nodes.as_slice() {
        return only.clone();
    }
    SplitNode::Split {
        id: ids.split(),
        axis: SplitAxis::Vertical,
        children: row_nodes.into_iter().map(even_child).collect(),
    }
}

/// A child carrying the equal flex share every rebuilt tree uses.
const fn even_child(node: SplitNode) -> WeightedChild {
    WeightedChild::new(SplitWeight::Flex(1.0), node)
}

// ---------------------------------------------------------------------------------------------- //
// Focus
// ---------------------------------------------------------------------------------------------- //

/// Focuses a pane, selecting its session and tab.
///
/// Focusing a pane OTHER than the tab's zoomed one exits zoom first: focus must never land on a
/// pane the zoom hides. Re-focusing the zoomed pane itself keeps the zoom.
#[must_use]
pub fn focus_pane(ws: &TreeWorkspace, target: PaneId) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate(ws, target) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    session.active_tab_index = tab_index;
    let id = session.id;
    let Some(tab) = session.tabs.get_mut(tab_index) else {
        return ws.clone();
    };
    tab.active_pane = Some(target);
    if tab.zoomed_pane != Some(target) {
        tab.zoomed_pane = None;
    }
    next.active_session_id = Some(id);
    next
}

/// Moves focus from the active pane, resolved geometrically against the tab solved into `bounds`,
/// so "move left" matches the pane the person sees.
///
/// Cycling routes through [`cycle_pane_target`] rather than the geometry, so the two cycle paths
/// read one enumerator and cannot drift.
#[must_use]
pub fn move_focus(ws: &TreeWorkspace, direction: FocusDirection, bounds: Rect) -> TreeWorkspace {
    let Some((session_index, tab_index)) = active_tab_index(ws) else {
        return ws.clone();
    };
    let Some(tab) = ws
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.get(tab_index))
    else {
        return ws.clone();
    };
    let Some(from) = tab.active_pane else {
        return ws.clone();
    };
    let target = if direction.is_directional() {
        let solved = split_layout::solve_default(&tab.root, bounds);
        focus::neighbor(from, direction, &solved)
    } else {
        cycle_pane_target(ws, direction == FocusDirection::Next)
    };
    target.map_or_else(|| ws.clone(), |next| focus_pane(ws, next))
}

/// The pane a sequential cycle step would focus — the single source of the wrap arithmetic.
///
/// A no-op when there is no active tab, when the tab holds fewer than two panes, or when the active
/// pane is absent or dangling: a dangling active has no defined successor, and cycling must not
/// silently jump focus to the front.
#[must_use]
pub fn cycle_pane_target(ws: &TreeWorkspace, forward: bool) -> Option<PaneId> {
    let tab = ws.active_session()?.active_tab()?;
    let ids = tab.all_pane_ids();
    if ids.len() <= 1 {
        return None;
    }
    let active = tab.active_pane?;
    if !tab.root.contains(active) {
        return None;
    }
    focus::cycle(&ids, active, forward)
}

/// Cycles focus through [`cycle_pane_target`] and [`focus_pane`], so the result holds the selection
/// invariants the shared focus path guarantees.
#[must_use]
pub fn cycle_pane_focus(ws: &TreeWorkspace, forward: bool) -> TreeWorkspace {
    cycle_pane_target(ws, forward).map_or_else(|| ws.clone(), |target| focus_pane(ws, target))
}

// ---------------------------------------------------------------------------------------------- //
// Tabs
// ---------------------------------------------------------------------------------------------- //

/// Adds a tab holding one pane to the active session and selects it.
#[must_use]
pub fn new_tab(
    ws: &TreeWorkspace,
    spec: PaneSpec,
    position: NewTabPosition,
    tab: TabId,
    pane: PaneId,
) -> TreeWorkspace {
    let Some(session_index) = ws.active_session_index() else {
        return ws.clone();
    };
    editing_session(ws, session_index, |session| {
        let index = position.insertion_index(session.active_tab_index, session.tabs.len());
        session.tabs.insert(index, Tab::new(tab, SplitNode::Leaf(pane)));
        session.active_tab_index = index;
        session.specs.insert(pane, spec);
        true
    })
}

/// Inserts a PRE-BUILT tab and its panes' specs into the active session and selects it — the reopen
/// of a closed tab.
///
/// A leaf whose spec went missing is re-seeded by the spec repair, so the result holds the
/// invariant whatever the caller handed over.
#[must_use]
pub fn insert_tab(
    ws: &TreeWorkspace,
    tab: Tab,
    specs: &BTreeMap<PaneId, PaneSpec>,
    position: NewTabPosition,
) -> TreeWorkspace {
    let Some(session_index) = ws.active_session_index() else {
        return ws.clone();
    };
    editing_session(ws, session_index, |session| {
        let index = position.insertion_index(session.active_tab_index, session.tabs.len());
        for id in tab.all_pane_ids() {
            if let Some(spec) = specs.get(&id) {
                session.specs.insert(id, spec.clone());
            }
        }
        session.tabs.insert(index, tab);
        session.active_tab_index = index;
        true
    })
    .normalizing_specs()
}

/// Closes a tab, dropping every pane's spec and cascading exactly as [`close_pane`] does.
#[must_use]
pub fn close_tab(
    ws: &TreeWorkspace,
    tab: TabId,
    successor: Option<TabId>,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate_tab(ws, tab) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(closing) = session.tabs.get(tab_index).cloned() else {
        return ws.clone();
    };
    for id in closing.all_pane_ids() {
        session.specs.remove(&id);
    }
    session.tabs.remove(tab_index);
    cascade_after_tab_removal(&next, session_index, tab_index, successor, ids).normalized(ids)
}

/// Selects a tab of the active session by index.
#[must_use]
pub fn select_tab(ws: &TreeWorkspace, index: usize) -> TreeWorkspace {
    let Some(session_index) = ws.active_session_index() else {
        return ws.clone();
    };
    editing_session(ws, session_index, |session| {
        if index >= session.tabs.len() {
            return false;
        }
        session.active_tab_index = index;
        true
    })
}

/// Renames a tab.
#[must_use]
pub fn rename_tab(ws: &TreeWorkspace, tab: TabId, title: impl Into<String>) -> TreeWorkspace {
    let Some((session, index)) = locate_tab(ws, tab) else {
        return ws.clone();
    };
    editing_tab(ws, session, index, |tab| {
        tab.title = title.into();
        true
    })
}

// ---------------------------------------------------------------------------------------------- //
// Sessions
// ---------------------------------------------------------------------------------------------- //

/// Adds a session holding one tab and one pane, and selects it.
#[must_use]
pub fn new_session(
    ws: &TreeWorkspace,
    name: impl Into<String>,
    spec: PaneSpec,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let session = Session::single_pane(ids.session(), name, ids.tab(), ids.pane(), spec);
    insert_session(ws, session, true)
}

/// Appends a PRE-BUILT session — a template expansion — leaving every other session untouched.
#[must_use]
pub fn insert_session(ws: &TreeWorkspace, session: Session, make_active: bool) -> TreeWorkspace {
    let mut next = ws.clone();
    let id = session.id;
    next.sessions.push(session);
    if make_active {
        next.active_session_id = Some(id);
    }
    next
}

/// Closes a session and everything in it, selecting another — or re-seeding a default when it was
/// the only one.
///
/// Unlike a tab close, this drops DETACHED panes too: the person asked for the session to go.
#[must_use]
pub fn close_session(ws: &TreeWorkspace, session: SessionId, ids: &mut impl IdSource) -> TreeWorkspace {
    let Some(index) = ws.sessions.iter().position(|candidate| candidate.id == session) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    next.sessions.remove(index);
    if next.sessions.is_empty() {
        return TreeWorkspace::default_workspace(ids.session(), ids.tab(), ids.pane());
    }
    if next.active_session_id == Some(session) {
        let fallback = index.min(next.sessions.len().saturating_sub(1));
        next.active_session_id = next.sessions.get(fallback).map(|session| session.id);
    }
    next.normalized(ids)
}

/// Selects a session.
#[must_use]
pub fn select_session(ws: &TreeWorkspace, session: SessionId) -> TreeWorkspace {
    if !ws.sessions.iter().any(|candidate| candidate.id == session) {
        return ws.clone();
    }
    let mut next = ws.clone();
    next.active_session_id = Some(session);
    next
}

/// Renames a session.
#[must_use]
pub fn rename_session(ws: &TreeWorkspace, session: SessionId, name: impl Into<String>) -> TreeWorkspace {
    let Some(index) = ws.sessions.iter().position(|candidate| candidate.id == session) else {
        return ws.clone();
    };
    editing_session(ws, index, |session| {
        session.name = name.into();
        true
    })
}

// ---------------------------------------------------------------------------------------------- //
// The spec side table
// ---------------------------------------------------------------------------------------------- //

/// Edits one pane's spec in place — a rename, a title, a video binding.
///
/// The split TREE is never touched, so a rename cannot churn a tree diff. It works for a tree leaf
/// OR a detached pane, because both live in the same side table and a detached pane's title still
/// has to persist while it streams in its own window.
#[must_use]
pub fn updating_spec(
    ws: &TreeWorkspace,
    target: PaneId,
    transform: impl FnOnce(&mut PaneSpec),
) -> TreeWorkspace {
    let owner = locate(ws, target)
        .map(|(session, _)| session)
        .or_else(|| ws.sessions.iter().position(|session| session.is_detached(target)));
    let Some(index) = owner else {
        return ws.clone();
    };
    editing_session(ws, index, |session| {
        let Some(spec) = session.specs.get_mut(&target) else {
            return false;
        };
        transform(spec);
        true
    })
}

// ---------------------------------------------------------------------------------------------- //
// Detach and reattach
// ---------------------------------------------------------------------------------------------- //

/// Detaches a pane from its tab into its own window.
///
/// The pane leaves the split tree but KEEPS its spec, and therefore its live handle: the process
/// survives and only the view remounts. The source tab shrinks exactly as a close would, and a tab
/// it was the sole leaf of is removed — but unlike a close, the SESSION always survives, because it
/// owns the detached pane's spec and dropping it would tear the live pane down.
#[must_use]
pub fn detach_pane(ws: &TreeWorkspace, target: PaneId, ids: &mut impl IdSource) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate(ws, target) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(origin) = session.tabs.get(tab_index).map(|tab| tab.id) else {
        return ws.clone();
    };
    prune_leaf_from_tab(session, target, tab_index);
    session.detached.push(DetachedPane {
        pane: target,
        origin_tab: Some(origin),
    });
    session.active_tab_index = session.active_tab_index.min(session.tabs.len().saturating_sub(1));
    next.normalized(ids)
}

/// Whether a pane is detached in this workspace, and where.
fn detached_owner(ws: &TreeWorkspace, target: PaneId) -> Option<usize> {
    let index = ws
        .sessions
        .iter()
        .position(|session| session.is_detached(target))?;
    // A video pane never joins a tab: the remote desktop is always its own window.
    let is_video = ws
        .sessions
        .get(index)
        .and_then(|session| session.spec_for(target))
        .is_some_and(|spec| spec.kind.is_video());
    (!is_video).then_some(index)
}

/// Reattaches a detached pane to its ORIGIN tab, docked as a full-span trailing column.
///
/// A dead origin tab — the pane was its tab's sole leaf, or the tab was closed while the pane was
/// out — gets a FRESH tab instead. That is deliberate: the pane owned a tab when it left, so it
/// gets one back, rather than being grafted into whatever tab happens to be active. A dock that
/// would breach the depth cap takes the same fallback.
#[must_use]
pub fn reattach_pane(
    ws: &TreeWorkspace,
    target: PaneId,
    tab: TabId,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some(session_index) = detached_owner(ws, target) else {
        return ws.clone();
    };
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let origin = session
        .detached
        .iter()
        .find(|entry| entry.pane == target)
        .and_then(|entry| entry.origin_tab);
    session.detached.retain(|entry| entry.pane != target);
    let id = session.id;

    let destination = origin.and_then(|origin| session.tabs.iter().position(|tab| tab.id == origin));
    if let Some(index) = destination
        && let Some(existing) = session.tabs.get(index)
    {
        let grown = existing
            .root
            .inserting_at_root(target, SplitAxis::Horizontal, false, fresh_split);
        if grown.depth() <= MAX_DEPTH
            && let Some(existing) = session.tabs.get_mut(index)
        {
            existing.root = grown;
            existing.active_pane = Some(target);
            existing.zoomed_pane = None;
            session.active_tab_index = index;
            next.active_session_id = Some(id);
            return next;
        }
    }
    session.tabs.push(Tab::new(tab, SplitNode::Leaf(target)));
    session.active_tab_index = session.tabs.len().saturating_sub(1);
    next.active_session_id = Some(id);
    next
}

/// Reattaches a detached pane BESIDE a tree pane — the drag-to-merge commit.
///
/// The anchor must live in the pane's own session: a spec cannot leave its session's side table.
/// The destination is revealed — session and tab selected, pane focused, zoom exited.
#[must_use]
pub fn reattach_pane_beside(
    ws: &TreeWorkspace,
    target: PaneId,
    anchor: PaneId,
    axis: SplitAxis,
    before: bool,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some(session_index) = detached_owner(ws, target) else {
        return ws.clone();
    };
    let Some((anchor_session, anchor_tab)) = locate(ws, anchor) else {
        return ws.clone();
    };
    if anchor_session != session_index {
        return ws.clone();
    }
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let id = session.id;
    // The insert is validated BEFORE the detached entry goes, so a rejected drop leaves the pane
    // floating rather than losing it to a tab that refused it.
    let Some(grown) = session
        .tabs
        .get(anchor_tab)
        .and_then(|tab| {
            tab.root
                .inserting_beside(target, anchor, axis, before, fresh_split)
        })
        .filter(|grown| grown.depth() <= MAX_DEPTH)
    else {
        return ws.clone();
    };
    session.detached.retain(|entry| entry.pane != target);
    let Some(tab) = session.tabs.get_mut(anchor_tab) else {
        return ws.clone();
    };
    tab.root = grown;
    tab.active_pane = Some(target);
    tab.zoomed_pane = None;
    session.active_tab_index = anchor_tab;
    next.active_session_id = Some(id);
    next
}

/// Reattaches a detached pane at the outermost edge of its session's ACTIVE tab — the gutter drop.
///
/// Declines when the pane's session is not the active one: the canvas the person dropped on renders
/// the active session, so any other destination is one they cannot see.
#[must_use]
pub fn reattach_pane_to_active_tab_root_edge(
    ws: &TreeWorkspace,
    target: PaneId,
    edge: PaneDropEdge,
    ids: &mut impl IdSource,
) -> TreeWorkspace {
    let Some(session_index) = detached_owner(ws, target) else {
        return ws.clone();
    };
    if ws.active_session_index() != Some(session_index) {
        return ws.clone();
    }
    let fresh_split = ids.split();
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let id = session.id;
    let tab_index = session.active_tab_index;
    let Some(grown) = session
        .tabs
        .get(tab_index)
        .map(|tab| {
            tab.root
                .inserting_at_root(target, edge.axis(), edge.inserts_before(), fresh_split)
        })
        .filter(|grown| grown.depth() <= MAX_DEPTH)
    else {
        return ws.clone();
    };
    session.detached.retain(|entry| entry.pane != target);
    let Some(tab) = session.tabs.get_mut(tab_index) else {
        return ws.clone();
    };
    tab.root = grown;
    tab.active_pane = Some(target);
    tab.zoomed_pane = None;
    next.active_session_id = Some(id);
    next
}

/// Reattaches a detached pane into a FRESH tab of its own session — the drop on the new-tab slot.
#[must_use]
pub fn reattach_pane_to_new_tab(ws: &TreeWorkspace, target: PaneId, tab: TabId) -> TreeWorkspace {
    let Some(session_index) = detached_owner(ws, target) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let id = session.id;
    session.detached.retain(|entry| entry.pane != target);
    session.tabs.push(Tab::new(tab, SplitNode::Leaf(target)));
    session.active_tab_index = session.tabs.len().saturating_sub(1);
    next.active_session_id = Some(id);
    next
}

/// Mints a brand-new pane DIRECTLY into the active session's detached list — it never passes
/// through a tab.
///
/// This is how a video pane is born: the remote desktop is always its own window, never a pane in
/// the workspace one. The origin tab is recorded only because a detached record carries one; a
/// video pane never reattaches, so it is never consulted.
#[must_use]
pub fn mint_detached_pane(ws: &TreeWorkspace, spec: PaneSpec, pane: PaneId) -> TreeWorkspace {
    let Some(session_index) = ws.active_session_index() else {
        return ws.clone();
    };
    editing_session(ws, session_index, |session| {
        let origin = session
            .tabs
            .get(session.active_tab_index)
            .or_else(|| session.tabs.first())
            .map(|tab| tab.id);
        let Some(origin) = origin else {
            return false;
        };
        session.specs.insert(pane, spec);
        session.detached.push(DetachedPane {
            pane,
            origin_tab: Some(origin),
        });
        true
    })
}

/// Closes a DETACHED pane for real: the record AND the spec go, so a reconcile tears the live
/// handle down. [`close_pane`] only walks the tree, so a close aimed at a detached id routes here.
#[must_use]
pub fn close_detached_pane(ws: &TreeWorkspace, target: PaneId) -> TreeWorkspace {
    let Some(index) = ws.sessions.iter().position(|session| session.is_detached(target)) else {
        return ws.clone();
    };
    editing_session(ws, index, |session| {
        session.detached.retain(|entry| entry.pane != target);
        session.specs.remove(&target);
        true
    })
}

/// Ejects a pane from its tab into a NEW tab of the same session.
///
/// The source tab collapses exactly as if the pane closed. A pane that is its tab's only leaf has
/// nothing to break out of, so it is a no-op.
#[must_use]
pub fn break_pane_to_tab(ws: &TreeWorkspace, target: PaneId, tab: TabId) -> TreeWorkspace {
    let Some((session_index, tab_index)) = locate(ws, target) else {
        return ws.clone();
    };
    let mut next = ws.clone();
    let Some(session) = next.sessions.get_mut(session_index) else {
        return ws.clone();
    };
    let Some(source) = session.tabs.get_mut(tab_index) else {
        return ws.clone();
    };
    if source.root.leaf_count() <= 1 {
        return ws.clone();
    }
    let Some(pruned) = source.root.removing(target) else {
        return ws.clone();
    };
    if source.zoomed_pane == Some(target) {
        source.zoomed_pane = None;
    }
    if source.active_pane == Some(target) {
        source.active_pane = pruned.first_leaf_id();
    }
    source.root = pruned;
    session.tabs.push(Tab::new(tab, SplitNode::Leaf(target)));
    session.active_tab_index = session.tabs.len().saturating_sub(1);
    next
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing session, tab or pane is a test failure with nothing to return"
    )]
    #![expect(clippy::float_cmp, reason = "the weights are exact literals, not computed")]

    use std::collections::BTreeMap;

    use super::{
        TileLayout, apply_layout, balance_splits, break_pane_to_tab, close_detached_pane, close_pane,
        close_session, close_tab, cycle_layout, cycle_pane_focus, cycle_pane_target, detach_pane,
        even_divider, focus_pane, insert_pane_at_root_edge, insert_session, insert_tab, locate,
        mint_detached_pane, move_focus, move_leaf, move_leaf_across_tabs, move_leaf_to_active_tab_root_edge,
        move_leaf_to_root_edge, move_leaf_to_tab_root_edge, move_pane_in_direction, new_session, new_tab,
        reattach_pane, reattach_pane_beside, reattach_pane_to_active_tab_root_edge, reattach_pane_to_new_tab,
        rename_session, rename_tab, resize_active_pane, resize_divider, select_session, select_tab,
        set_divider_weight, split_pane, swap_panes, toggle_zoom, updating_spec,
    };
    use crate::focus::FocusDirection;
    use crate::geometry::{Point, Rect, Size};
    use crate::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
    use crate::session::{NewTabPosition, PaneKind, PaneSpec, Tab};
    use crate::split_tree::{PaneDropEdge, SplitAxis, SplitNode, SplitWeight};
    use crate::workspace::TreeWorkspace;

    /// A counter, so every minted id in these tests is predictable and every run gives one tree.
    struct Counter(u8);

    impl Counter {
        fn step(&mut self) -> u8 {
            self.0 = self.0.wrapping_add(1);
            self.0
        }
    }

    impl IdSource for Counter {
        fn pane(&mut self) -> PaneId {
            PaneId::from_bytes([self.step(); 16])
        }

        fn tab(&mut self) -> TabId {
            TabId::from_bytes([self.step(); 16])
        }

        fn session(&mut self) -> SessionId {
            SessionId::from_bytes([self.step(); 16])
        }

        fn split(&mut self) -> SplitNodeId {
            SplitNodeId::from_bytes([self.step(); 16])
        }
    }

    fn ids() -> Counter {
        Counter(150)
    }

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn tab_id(byte: u8) -> TabId {
        TabId::from_bytes([byte; 16])
    }

    fn session_id(byte: u8) -> SessionId {
        SessionId::from_bytes([byte; 16])
    }

    fn spec(title: &str) -> PaneSpec {
        PaneSpec::new(PaneKind::Terminal, title)
    }

    fn bounds() -> Rect {
        Rect::new(Point::ZERO, Size::new(800.0, 600.0))
    }

    fn one_pane() -> TreeWorkspace {
        TreeWorkspace::single_pane(session_id(1), tab_id(1), pane(1), spec("One"))
    }

    /// Two panes side by side in one tab, split horizontally.
    fn two_panes() -> TreeWorkspace {
        split_pane(
            &one_pane(),
            pane(1),
            SplitAxis::Horizontal,
            spec("Two"),
            false,
            pane(2),
            &mut ids(),
        )
    }

    fn tab_of(ws: &TreeWorkspace, session: usize, tab: usize) -> Tab {
        let Some(found) = ws.sessions.get(session).and_then(|s| s.tabs.get(tab)) else {
            panic!("the tab exists");
        };
        found.clone()
    }

    /// The two halves of the ABI byte agree, and the mapping is total both ways.
    ///
    /// `ALL` and `index` are separately written — one an array, one a match — so this is what ties
    /// them together. A case added to the array but not the match will not compile; a case added to
    /// both in DIFFERENT positions compiles fine and fails here, and nothing else would notice: the
    /// byte would cross the boundary naming another layout.
    #[test]
    fn every_tile_layout_round_trips_through_its_abi_byte() {
        for (position, layout) in TileLayout::ALL.iter().enumerate() {
            assert_eq!(
                usize::from(layout.index()),
                position,
                "{layout:?} is at position {position}"
            );
            assert_eq!(TileLayout::from_index(layout.index()), Some(*layout));
        }
        let past_the_end = TileLayout::ALL
            .last()
            .map_or(0, |layout| layout.index().saturating_add(1));
        assert_eq!(
            TileLayout::from_index(past_the_end),
            None,
            "a byte naming no case must read as none, not as the last one"
        );
        assert_eq!(TileLayout::from_index(u8::MAX), None);
    }

    #[test]
    fn a_split_adds_a_leaf_that_takes_focus_and_exits_zoom() {
        let zoomed = toggle_zoom(&one_pane(), pane(1));
        assert_eq!(tab_of(&zoomed, 0, 0).zoomed_pane, Some(pane(1)));
        let after = split_pane(
            &zoomed,
            pane(1),
            SplitAxis::Horizontal,
            spec("Two"),
            false,
            pane(2),
            &mut ids(),
        );
        let tab = tab_of(&after, 0, 0);
        assert_eq!(tab.all_pane_ids(), vec![pane(1), pane(2)]);
        assert_eq!(tab.active_pane, Some(pane(2)));
        assert_eq!(tab.zoomed_pane, None, "the new focused pane has to be visible");
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_split_before_puts_the_new_pane_on_the_leading_side() {
        let after = split_pane(
            &one_pane(),
            pane(1),
            SplitAxis::Horizontal,
            spec("Two"),
            true,
            pane(2),
            &mut ids(),
        );
        assert_eq!(tab_of(&after, 0, 0).all_pane_ids(), vec![pane(2), pane(1)]);
    }

    #[test]
    fn a_split_of_an_absent_pane_changes_nothing() {
        let before = one_pane();
        let after = split_pane(
            &before,
            pane(90),
            SplitAxis::Horizontal,
            spec("Two"),
            false,
            pane(2),
            &mut ids(),
        );
        assert_eq!(after, before);
    }

    #[test]
    fn closing_a_pane_drops_its_spec_and_refocuses_a_survivor() {
        let after = close_pane(&two_panes(), pane(2), None, &mut ids());
        let tab = tab_of(&after, 0, 0);
        assert_eq!(tab.all_pane_ids(), vec![pane(1)]);
        assert_eq!(tab.active_pane, Some(pane(1)));
        assert!(after.spec_for(pane(2)).is_none());
        assert!(after.invariant_holds());
    }

    #[test]
    fn closing_the_last_pane_of_the_last_tab_re_seeds_rather_than_emptying() {
        let after = close_pane(&one_pane(), pane(1), None, &mut ids());
        assert_eq!(after.sessions.len(), 1);
        assert_eq!(after.all_pane_ids().len(), 1);
        assert!(after.invariant_holds());
    }

    #[test]
    fn closing_a_tabs_last_pane_selects_the_callers_successor() {
        let two_tabs = new_tab(&one_pane(), spec("Two"), NewTabPosition::End, tab_id(2), pane(2));
        let three = new_tab(&two_tabs, spec("Three"), NewTabPosition::End, tab_id(3), pane(3));
        let after = close_pane(&three, pane(2), Some(tab_id(3)), &mut ids());
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.tabs.len(), 2);
        assert_eq!(
            session.tabs.get(session.active_tab_index).map(|tab| tab.id),
            Some(tab_id(3)),
            "the caller's successor wins over the index clamp",
        );
    }

    #[test]
    fn a_session_that_still_owns_a_detached_pane_survives_its_last_tab() {
        let floating = detach_pane(&two_panes(), pane(2), &mut ids());
        let after = close_pane(&floating, pane(1), None, &mut ids());
        assert_eq!(
            after.sessions.len(),
            1,
            "dropping it would tear the live satellite down"
        );
        assert_eq!(after.detached_pane_ids(), vec![pane(2)]);
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_zoom_toggles_and_never_touches_the_tree() {
        let before = two_panes();
        let zoomed = toggle_zoom(&before, pane(2));
        assert_eq!(tab_of(&zoomed, 0, 0).zoomed_pane, Some(pane(2)));
        assert_eq!(tab_of(&zoomed, 0, 0).root, tab_of(&before, 0, 0).root);
        assert_eq!(tab_of(&toggle_zoom(&zoomed, pane(2)), 0, 0).zoomed_pane, None);
    }

    #[test]
    fn a_divider_drag_is_sum_preserving() {
        let before = two_panes();
        let SplitNode::Split { id, .. } = tab_of(&before, 0, 0).root else {
            panic!("a split root");
        };
        let after = resize_divider(&before, id, 0, 0.25);
        let SplitNode::Split { children, .. } = tab_of(&after, 0, 0).root else {
            panic!("a split root");
        };
        let total: f64 = children.iter().filter_map(|child| child.weight.flex()).sum();
        assert_eq!(total, 2.0);
        assert_eq!(children.first().and_then(|child| child.weight.flex()), Some(1.25));
    }

    #[test]
    fn evening_one_seam_and_setting_an_absolute_weight_both_land() {
        let before = two_panes();
        let SplitNode::Split { id, .. } = tab_of(&before, 0, 0).root else {
            panic!("a split root");
        };
        let dragged = set_divider_weight(&before, id, 0, 1.5);
        let SplitNode::Split { children, .. } = tab_of(&dragged, 0, 0).root else {
            panic!("a split root");
        };
        assert_eq!(children.first().and_then(|child| child.weight.flex()), Some(1.5));
        let evened = even_divider(&dragged, id, 0);
        let SplitNode::Split { children, .. } = tab_of(&evened, 0, 0).root else {
            panic!("a split root");
        };
        assert_eq!(children.first().and_then(|child| child.weight.flex()), Some(1.0));
    }

    #[test]
    fn a_keyboard_resize_grows_the_active_pane_from_either_side() {
        let before = two_panes();
        let grown = resize_active_pane(&before, pane(1), FocusDirection::Right, 0.2);
        let SplitNode::Split { children, .. } = tab_of(&grown, 0, 0).root else {
            panic!("a split root");
        };
        assert_eq!(children.first().and_then(|child| child.weight.flex()), Some(1.2));

        // The LAST child has no divider to its right, so the one to its left governs it with the
        // sign flipped.
        let trailing = resize_active_pane(&before, pane(2), FocusDirection::Right, 0.2);
        let SplitNode::Split { children, .. } = tab_of(&trailing, 0, 0).root else {
            panic!("a split root");
        };
        assert_eq!(children.get(1).and_then(|child| child.weight.flex()), Some(1.2));
    }

    #[test]
    fn a_cycle_direction_is_not_a_resize_or_a_move() {
        let before = two_panes();
        assert_eq!(
            resize_active_pane(&before, pane(1), FocusDirection::Next, 0.2),
            before
        );
        assert_eq!(
            move_pane_in_direction(&before, pane(1), FocusDirection::Next, bounds()),
            before
        );
    }

    #[test]
    fn balancing_evens_every_seam_in_the_tab() {
        let before = two_panes();
        let SplitNode::Split { id, .. } = tab_of(&before, 0, 0).root else {
            panic!("a split root");
        };
        let dragged = set_divider_weight(&before, id, 0, 1.8);
        let balanced = balance_splits(&dragged, pane(1));
        let SplitNode::Split { children, .. } = tab_of(&balanced, 0, 0).root else {
            panic!("a split root");
        };
        for child in &children {
            assert_eq!(child.weight, SplitWeight::Flex(1.0));
        }
    }

    #[test]
    fn a_swap_moves_positions_and_leaves_the_leaf_set_alone() {
        let after = swap_panes(&two_panes(), pane(1), pane(2));
        assert_eq!(tab_of(&after, 0, 0).all_pane_ids(), vec![pane(2), pane(1)]);
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_swap_across_tabs_is_declined() {
        let two_tabs = new_tab(
            &two_panes(),
            spec("Three"),
            NewTabPosition::End,
            tab_id(2),
            pane(3),
        );
        assert_eq!(swap_panes(&two_tabs, pane(1), pane(3)), two_tabs);
    }

    #[test]
    fn a_move_that_reproduces_the_same_arrangement_is_declined() {
        let before = two_panes();
        assert_eq!(
            move_leaf(
                &before,
                pane(2),
                pane(1),
                SplitAxis::Horizontal,
                false,
                &mut ids()
            ),
            before,
            "a no-op drop must not churn a save under a fresh split id",
        );
    }

    #[test]
    fn a_cross_axis_drop_reorients_the_split() {
        let after = move_leaf(
            &two_panes(),
            pane(2),
            pane(1),
            SplitAxis::Vertical,
            false,
            &mut ids(),
        );
        let SplitNode::Split { axis, .. } = tab_of(&after, 0, 0).root else {
            panic!("a split root");
        };
        assert_eq!(axis, SplitAxis::Vertical);
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_dock_to_the_root_edge_makes_a_full_span_band() {
        let three = split_pane(
            &two_panes(),
            pane(2),
            SplitAxis::Vertical,
            spec("Three"),
            false,
            pane(3),
            &mut ids(),
        );
        let after = move_leaf_to_root_edge(&three, pane(3), PaneDropEdge::Top, &mut ids());
        let tab = tab_of(&after, 0, 0);
        assert_eq!(tab.all_pane_ids().first(), Some(&pane(3)));
        assert_eq!(tab.active_pane, Some(pane(3)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_lone_leaf_tab_has_nothing_to_dock_against() {
        let before = one_pane();
        assert_eq!(
            move_leaf_to_root_edge(&before, pane(1), PaneDropEdge::Left, &mut ids()),
            before,
        );
    }

    #[test]
    fn a_cross_tab_move_takes_the_pane_and_the_selection_with_it() {
        let two_tabs = new_tab(
            &two_panes(),
            spec("Three"),
            NewTabPosition::End,
            tab_id(2),
            pane(3),
        );
        let after = move_leaf_across_tabs(
            &two_tabs,
            pane(1),
            pane(3),
            SplitAxis::Horizontal,
            false,
            &mut ids(),
        );
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(
            session.tabs.get(session.active_tab_index).map(|tab| tab.id),
            Some(tab_id(2)),
        );
        assert!(tab_of(&after, 0, 1).all_pane_ids().contains(&pane(1)));
        assert!(!tab_of(&after, 0, 0).all_pane_ids().contains(&pane(1)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_cross_tab_move_of_a_sole_leaf_takes_its_tab_with_it() {
        let two_tabs = new_tab(&one_pane(), spec("Two"), NewTabPosition::End, tab_id(2), pane(2));
        let after = move_leaf_across_tabs(
            &two_tabs,
            pane(1),
            pane(2),
            SplitAxis::Horizontal,
            false,
            &mut ids(),
        );
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.tabs.len(), 1, "the emptied tab goes");
        assert_eq!(session.tabs.first().map(|tab| tab.id), Some(tab_id(2)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_gutter_drop_works_against_a_lone_leaf_destination() {
        let two_tabs = new_tab(
            &two_panes(),
            spec("Three"),
            NewTabPosition::End,
            tab_id(2),
            pane(3),
        );
        let after = move_leaf_to_tab_root_edge(&two_tabs, pane(1), tab_id(2), PaneDropEdge::Left, &mut ids());
        assert_eq!(tab_of(&after, 0, 1).all_pane_ids(), vec![pane(1), pane(3)]);
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_gutter_drop_aimed_at_the_active_tab_declines_from_another_session() {
        let two_sessions = new_session(&one_pane(), "Other", spec("Elsewhere"), &mut ids());
        assert_eq!(
            move_leaf_to_active_tab_root_edge(&two_sessions, pane(1), PaneDropEdge::Left, &mut ids()),
            two_sessions,
            "the dragger is not even showing that destination",
        );
    }

    #[test]
    fn inserting_a_pane_at_the_root_edge_works_on_a_lone_leaf_tab() {
        let after = insert_pane_at_root_edge(
            &one_pane(),
            spec("Two"),
            PaneDropEdge::Bottom,
            pane(2),
            &mut ids(),
        );
        let tab = tab_of(&after, 0, 0);
        assert_eq!(tab.all_pane_ids(), vec![pane(1), pane(2)]);
        assert_eq!(tab.active_pane, Some(pane(2)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn moving_a_pane_in_a_direction_exchanges_it_with_what_is_there() {
        let after = move_pane_in_direction(&two_panes(), pane(1), FocusDirection::Right, bounds());
        assert_eq!(tab_of(&after, 0, 0).all_pane_ids(), vec![pane(2), pane(1)]);
    }

    #[test]
    fn every_re_tile_keeps_the_leaf_set_and_resets_the_weights() {
        let mut ws = one_pane();
        for byte in 2..=7 {
            ws = split_pane(
                &ws,
                pane(1),
                SplitAxis::Horizontal,
                spec("More"),
                false,
                pane(byte),
                &mut ids(),
            );
        }
        let before: Vec<PaneId> = tab_of(&ws, 0, 0).all_pane_ids();
        for layout in TileLayout::ALL {
            let after = apply_layout(&ws, layout, pane(1), &mut ids());
            let mut got = tab_of(&after, 0, 0).all_pane_ids();
            let mut want = before.clone();
            got.sort_unstable();
            want.sort_unstable();
            assert_eq!(got, want, "{} must not lose a leaf", layout.raw());
            assert!(after.invariant_holds());
        }
    }

    #[test]
    fn the_main_layouts_put_the_active_pane_first() {
        let three = split_pane(
            &two_panes(),
            pane(2),
            SplitAxis::Horizontal,
            spec("Three"),
            false,
            pane(3),
            &mut ids(),
        );
        let focused = focus_pane(&three, pane(3));
        let after = apply_layout(&focused, TileLayout::MainVertical, pane(3), &mut ids());
        assert_eq!(tab_of(&after, 0, 0).all_pane_ids().first(), Some(&pane(3)));
    }

    #[test]
    fn a_tiled_grid_spreads_the_rows_evenly_rather_than_greedily() {
        let mut ws = one_pane();
        for byte in 2..=7 {
            ws = split_pane(
                &ws,
                pane(1),
                SplitAxis::Horizontal,
                spec("More"),
                false,
                pane(byte),
                &mut ids(),
            );
        }
        let after = apply_layout(&ws, TileLayout::Tiled, pane(1), &mut ids());
        let SplitNode::Split { children, .. } = tab_of(&after, 0, 0).root else {
            panic!("a grid root");
        };
        let widths: Vec<usize> = children.iter().map(|child| child.node.leaf_count()).collect();
        assert_eq!(widths, vec![3, 2, 2], "seven panes tile as 3/2/2, never 3/3/1");
    }

    #[test]
    fn a_re_tile_of_a_lone_leaf_tab_is_a_no_op_but_the_cursor_still_moves() {
        let before = one_pane();
        let (after, layout) = cycle_layout(&before, pane(1), Some(TileLayout::Tiled), &mut ids());
        assert_eq!(after, before);
        assert_eq!(layout, TileLayout::EvenHorizontal, "the cycle wraps");
    }

    #[test]
    fn focusing_a_pane_selects_its_session_and_tab_and_exits_a_foreign_zoom() {
        let two_tabs = new_tab(&one_pane(), spec("Two"), NewTabPosition::End, tab_id(2), pane(2));
        let zoomed = toggle_zoom(&two_tabs, pane(2));
        let after = focus_pane(&zoomed, pane(1));
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.active_tab_index, 0);
        assert_eq!(after.active_session_id, Some(session_id(1)));
        assert_eq!(
            tab_of(&after, 0, 1).zoomed_pane,
            Some(pane(2)),
            "the other tab keeps its zoom"
        );

        let kept = focus_pane(&zoomed, pane(2));
        assert_eq!(
            tab_of(&kept, 0, 1).zoomed_pane,
            Some(pane(2)),
            "re-focusing the zoomed pane keeps the zoom",
        );
    }

    #[test]
    fn moving_focus_lands_on_the_pane_the_person_sees() {
        let after = move_focus(&two_panes(), FocusDirection::Left, bounds());
        assert_eq!(tab_of(&after, 0, 0).active_pane, Some(pane(1)));
    }

    #[test]
    fn cycling_wraps_at_both_ends_and_declines_a_dangling_active() {
        let before = two_panes();
        assert_eq!(cycle_pane_target(&before, true), Some(pane(1)));
        assert_eq!(cycle_pane_target(&before, false), Some(pane(1)));
        let cycled = cycle_pane_focus(&before, true);
        assert_eq!(tab_of(&cycled, 0, 0).active_pane, Some(pane(1)));

        let mut dangling = before;
        let Some(tab) = dangling.sessions.first_mut().and_then(|s| s.tabs.first_mut()) else {
            panic!("one tab");
        };
        tab.active_pane = Some(pane(90));
        assert_eq!(
            cycle_pane_target(&dangling, true),
            None,
            "cycling must not silently jump focus to the front",
        );
    }

    #[test]
    fn a_new_tab_lands_where_the_position_says() {
        let end = new_tab(&one_pane(), spec("Two"), NewTabPosition::End, tab_id(2), pane(2));
        let after = new_tab(
            &end,
            spec("Three"),
            NewTabPosition::AfterCurrent,
            tab_id(3),
            pane(3),
        );
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        let order: Vec<TabId> = session.tabs.iter().map(|tab| tab.id).collect();
        assert_eq!(order, vec![tab_id(1), tab_id(2), tab_id(3)]);
        assert_eq!(session.active_tab_index, 2);
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_reopened_tab_brings_its_specs_and_re_seeds_whatever_is_missing() {
        let mut specs = BTreeMap::new();
        specs.insert(pane(50), spec("Restored"));
        let restored = Tab::new(tab_id(9), SplitNode::Leaf(pane(50)));
        let after = insert_tab(&one_pane(), restored, &specs, NewTabPosition::End);
        assert_eq!(
            after.spec_for(pane(50)).map(|spec| spec.title.clone()),
            Some("Restored".to_owned()),
        );
        assert!(after.invariant_holds());

        let bare = insert_tab(
            &one_pane(),
            Tab::new(tab_id(8), SplitNode::Leaf(pane(60))),
            &BTreeMap::new(),
            NewTabPosition::End,
        );
        assert!(bare.spec_for(pane(60)).is_some(), "a spec-less leaf is re-seeded");
        assert!(bare.invariant_holds());
    }

    #[test]
    fn closing_a_tab_drops_every_pane_in_it() {
        let two_tabs = new_tab(
            &two_panes(),
            spec("Three"),
            NewTabPosition::End,
            tab_id(2),
            pane(3),
        );
        let after = close_tab(&two_tabs, tab_id(1), None, &mut ids());
        assert!(after.spec_for(pane(1)).is_none());
        assert!(after.spec_for(pane(2)).is_none());
        assert_eq!(after.all_pane_ids(), vec![pane(3)]);
        assert!(after.invariant_holds());
    }

    #[test]
    fn selecting_and_renaming_reject_what_is_not_there() {
        let before = one_pane();
        assert_eq!(select_tab(&before, 7), before);
        assert_eq!(rename_tab(&before, tab_id(9), "Nope"), before);
        assert_eq!(select_session(&before, session_id(9)), before);
        assert_eq!(rename_session(&before, session_id(9), "Nope"), before);

        let renamed = rename_tab(&before, tab_id(1), "Build");
        assert_eq!(tab_of(&renamed, 0, 0).title, "Build");
        let named = rename_session(&before, session_id(1), "Work");
        assert_eq!(
            named.sessions.first().map(|s| s.name.clone()),
            Some("Work".to_owned())
        );
    }

    #[test]
    fn a_new_session_is_appended_and_selected() {
        let after = new_session(&one_pane(), "Other", spec("Elsewhere"), &mut ids());
        assert_eq!(after.sessions.len(), 2);
        assert_eq!(
            after.active_session_id,
            after.sessions.get(1).map(|session| session.id),
        );
        assert!(after.invariant_holds());
    }

    #[test]
    fn an_inserted_session_need_not_take_the_selection() {
        let Some(session) = new_session(&one_pane(), "Other", spec("Elsewhere"), &mut ids())
            .sessions
            .get(1)
            .cloned()
        else {
            panic!("two sessions");
        };
        let after = insert_session(&one_pane(), session, false);
        assert_eq!(after.active_session_id, Some(session_id(1)));
        assert_eq!(after.sessions.len(), 2);
    }

    #[test]
    fn closing_the_only_session_re_seeds_a_default() {
        let after = close_session(&one_pane(), session_id(1), &mut ids());
        assert_eq!(after.sessions.len(), 1);
        assert_eq!(after.all_pane_ids().len(), 1);
        assert!(after.invariant_holds());
    }

    #[test]
    fn closing_a_session_takes_its_detached_panes_with_it() {
        let floating = detach_pane(&two_panes(), pane(2), &mut ids());
        let with_other = new_session(&floating, "Other", spec("Elsewhere"), &mut ids());
        let after = close_session(&with_other, session_id(1), &mut ids());
        assert!(after.detached_pane_ids().is_empty());
        assert!(after.spec_for(pane(2)).is_none());
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_spec_edit_reaches_a_detached_pane_and_never_touches_the_tree() {
        let before = detach_pane(&two_panes(), pane(2), &mut ids());
        let after = updating_spec(&before, pane(2), |spec| {
            spec.title = "Renamed".to_owned();
            spec.user_renamed = true;
        });
        assert_eq!(
            after.spec_for(pane(2)).map(|spec| spec.title.clone()),
            Some("Renamed".to_owned()),
        );
        assert_eq!(tab_of(&after, 0, 0).root, tab_of(&before, 0, 0).root);
        assert_eq!(updating_spec(&before, pane(90), |_| {}), before);
    }

    #[test]
    fn detaching_leaves_the_tree_but_keeps_the_spec() {
        let after = detach_pane(&two_panes(), pane(2), &mut ids());
        assert_eq!(after.detached_pane_ids(), vec![pane(2)]);
        assert!(after.spec_for(pane(2)).is_some(), "the live handle survives");
        assert!(!tab_of(&after, 0, 0).all_pane_ids().contains(&pane(2)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn detaching_a_sole_leaf_leaves_a_re_seeded_tab_behind() {
        let after = detach_pane(&one_pane(), pane(1), &mut ids());
        assert_eq!(after.detached_pane_ids(), vec![pane(1)]);
        assert_eq!(
            after.sessions.first().map(|session| session.tabs.len()),
            Some(1),
            "the main window never renders an empty session",
        );
        assert!(after.invariant_holds());
    }

    #[test]
    fn reattaching_prefers_the_origin_tab_and_falls_back_to_a_fresh_one() {
        let detached = detach_pane(&two_panes(), pane(2), &mut ids());
        let home = reattach_pane(&detached, pane(2), tab_id(80), &mut ids());
        assert!(home.detached_pane_ids().is_empty());
        assert_eq!(
            home.sessions.first().map(|session| session.tabs.len()),
            Some(1),
            "the origin tab is still alive, so no new tab is minted",
        );
        assert_eq!(tab_of(&home, 0, 0).active_pane, Some(pane(2)));
        assert!(home.invariant_holds());

        // A pane that owned its tab gets a tab back rather than being grafted into another one.
        let orphan = detach_pane(&one_pane(), pane(1), &mut ids());
        let fresh = reattach_pane(&orphan, pane(1), tab_id(80), &mut ids());
        assert!(fresh.contains(pane(1)));
        assert!(fresh.invariant_holds());
    }

    #[test]
    fn a_video_pane_never_joins_a_tab() {
        let mut ws = one_pane();
        let Some(session) = ws.sessions.first_mut() else {
            panic!("one session");
        };
        session
            .specs
            .insert(pane(70), PaneSpec::new(PaneKind::Desktop, "Display"));
        session.detached.push(crate::session::DetachedPane {
            pane: pane(70),
            origin_tab: Some(tab_id(1)),
        });
        assert_eq!(reattach_pane(&ws, pane(70), tab_id(80), &mut ids()), ws);
        assert_eq!(reattach_pane_to_new_tab(&ws, pane(70), tab_id(80)), ws);
        assert_eq!(
            reattach_pane_beside(&ws, pane(70), pane(1), SplitAxis::Horizontal, false, &mut ids()),
            ws,
        );
    }

    #[test]
    fn reattaching_beside_an_anchor_reveals_the_destination() {
        let two_tabs = new_tab(
            &two_panes(),
            spec("Three"),
            NewTabPosition::End,
            tab_id(2),
            pane(3),
        );
        let detached = detach_pane(&two_tabs, pane(1), &mut ids());
        let after = reattach_pane_beside(&detached, pane(1), pane(3), SplitAxis::Vertical, true, &mut ids());
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.active_tab_index, 1);
        assert!(after.detached_pane_ids().is_empty());
        assert_eq!(tab_of(&after, 0, 1).active_pane, Some(pane(1)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn reattaching_into_the_active_tabs_gutter_declines_from_another_session() {
        let detached = detach_pane(&two_panes(), pane(2), &mut ids());
        let elsewhere = new_session(&detached, "Other", spec("Elsewhere"), &mut ids());
        assert_eq!(
            reattach_pane_to_active_tab_root_edge(&elsewhere, pane(2), PaneDropEdge::Left, &mut ids()),
            elsewhere,
        );
        let after = reattach_pane_to_active_tab_root_edge(&detached, pane(2), PaneDropEdge::Left, &mut ids());
        assert!(after.detached_pane_ids().is_empty());
        assert_eq!(tab_of(&after, 0, 0).all_pane_ids().first(), Some(&pane(2)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn reattaching_into_a_new_tab_appends_and_selects_it() {
        let detached = detach_pane(&two_panes(), pane(2), &mut ids());
        let after = reattach_pane_to_new_tab(&detached, pane(2), tab_id(9));
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.tabs.len(), 2);
        assert_eq!(session.active_tab_index, 1);
        assert!(after.invariant_holds());
    }

    #[test]
    fn a_minted_detached_pane_never_passes_through_a_tab() {
        let after = mint_detached_pane(&one_pane(), PaneSpec::new(PaneKind::Desktop, "Display"), pane(70));
        assert_eq!(after.detached_pane_ids(), vec![pane(70)]);
        assert!(!after.contains(pane(70)));
        assert!(after.invariant_holds());
    }

    #[test]
    fn closing_a_detached_pane_takes_its_spec_so_the_handle_can_be_torn_down() {
        let detached = detach_pane(&two_panes(), pane(2), &mut ids());
        let after = close_detached_pane(&detached, pane(2));
        assert!(after.detached_pane_ids().is_empty());
        assert!(after.spec_for(pane(2)).is_none());
        assert!(after.invariant_holds());
    }

    #[test]
    fn breaking_a_pane_out_needs_something_to_break_out_of() {
        let before = one_pane();
        assert_eq!(break_pane_to_tab(&before, pane(1), tab_id(9)), before);

        let after = break_pane_to_tab(&two_panes(), pane(2), tab_id(9));
        let Some(session) = after.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.tabs.len(), 2);
        assert_eq!(session.active_tab_index, 1);
        assert_eq!(tab_of(&after, 0, 0).all_pane_ids(), vec![pane(1)]);
        assert_eq!(tab_of(&after, 0, 1).all_pane_ids(), vec![pane(2)]);
        assert!(after.invariant_holds());
    }

    #[test]
    fn locate_answers_indices_and_nothing_for_an_absent_pane() {
        assert_eq!(locate(&two_panes(), pane(2)), Some((0, 0)));
        assert_eq!(locate(&two_panes(), pane(90)), None);
    }
}
