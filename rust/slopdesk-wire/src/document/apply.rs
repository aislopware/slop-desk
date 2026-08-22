//! Turns one client's request into a new topology, or into a refusal.
//!
//! **Pure, and deliberately shared by both ends.** The host runs it to decide what the document
//! becomes; the client runs the SAME function to build its optimistic overlay. Two implementations
//! of "what does a split do" would drift, and the drift would look exactly like a sync bug — the
//! client showing one layout and the host publishing another, with no way to tell which is wrong.
//!
//! Everything here is VALIDATION. The transformation itself is
//! [`slopdesk_tree::tree_ops`], which was written for a caller that could not supply nonsense;
//! what it has never had is a caller that is a network peer. So: every referenced id must already
//! exist, every proposed id must not, every count is bounded before it allocates — the argument
//! decoders in [`super::intent`] own that part — and the RESULT is re-checked against the depth cap
//! and the spec invariant before it is accepted.
//!
//! ## Nothing changed IS the refusal
//!
//! The tree ops answer their input unchanged when an op cannot apply. Several checks below
//! therefore ask "did the pane actually move" rather than trying to re-derive the op's own
//! preconditions. Reporting `Applied` for a document that never moved would retire a client's
//! optimistic patch against a state that does not exist — the one outcome worse than a refusal.

use std::collections::{BTreeMap, BTreeSet};

use slopdesk_ids::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
use slopdesk_tree::session::{PaneKind, PaneSpec, Session, Tab};
use slopdesk_tree::split_tree::{MAX_DEPTH, MIN_WEIGHT, SplitNode, SplitWeight, WeightedChild};
use slopdesk_tree::workspace::{DEFAULT_DESKTOP_PANE_TITLE, DEFAULT_PANE_TITLE, DEFAULT_SESSION_NAME};
use slopdesk_tree::{tab_ordering, tree_ops};

use super::codec::{self, WorkspaceLayoutNode};
use super::intent::{self, WorkspaceIntentOp};
use super::topology::{CLOSED_TAB_RING_CAP, ClosedTab, FOCUS_MRU_CAP, WorkspaceTopology};

/// The title a video pane is born with when its endpoint names none.
///
/// The word itself is [`DEFAULT_DESKTOP_PANE_TITLE`], beside the other two seeded names, because
/// the client mints desktop panes too. Spelling it here as well would let a locally-made pane and a
/// document-restored one carry different titles after a rename that only touched one side.
const DEFAULT_VIDEO_TITLE: &str = DEFAULT_DESKTOP_PANE_TITLE;

/// What one intent did.
#[derive(Debug, Clone, PartialEq)]
pub enum IntentOutcome {
    /// The desired state now holds.
    ///
    /// Reported even when nothing CHANGED: focusing an already-focused pane is a satisfied request,
    /// and a state-transfer system has no business distinguishing the two — that is also what makes
    /// a duplicated intent free.
    Applied(Box<WorkspaceTopology>),
    /// A bootstrap that arrived too late: the document has already been touched.
    RejectedStale,
    /// Well-formed but not allowed — a malformed payload, a proposed id already in use, a structure
    /// that would breach the depth cap or break the spec invariant.
    RejectedInvalid,
    /// A referenced pane, tab or session is not in the document.
    RejectedNotFound,
    /// An op byte this build does not know.
    UnknownOp,
}

impl IntentOutcome {
    /// The topology this outcome carries, if it applied.
    #[must_use]
    pub fn topology(&self) -> Option<&WorkspaceTopology> {
        match self {
            Self::Applied(topology) => Some(topology),
            _ => None,
        }
    }

    /// Whether the request was satisfied.
    #[must_use]
    pub const fn is_applied(&self) -> bool {
        matches!(self, Self::Applied(_))
    }
}

/// The project-key lookup for a caller with no document cells to read.
///
/// Puts every pane in one section, which reduces the close rule to MRU-then-neighbour. A caller
/// that owns a document supplies [`super::HostWorkspaceState::project_key_for_pane`] instead.
#[must_use]
pub const fn no_project_keys(_: PaneId) -> Option<String> {
    None
}

/// Applies one intent.
///
/// `pristine` is whether the document is still the untouched default. Only
/// [`WorkspaceIntentOp::AdoptWorkspace`] reads it — a bootstrap that arrives after the host has a
/// real workspace is [`IntentOutcome::RejectedStale`], and the loser is told so rather than
/// silently overwritten, because its tree is the only copy of a layout somebody built.
///
/// `project_key` resolves a pane's by-project key. Only the close ops read it, to keep focus inside
/// the section the closed tab lived in.
#[must_use]
pub fn apply(
    op: u8,
    args: &[u8],
    topology: &WorkspaceTopology,
    ids: &mut impl IdSource,
    pristine: bool,
    project_key: &impl Fn(PaneId) -> Option<String>,
) -> IntentOutcome {
    let Some(op) = WorkspaceIntentOp::from_byte(op) else {
        return IntentOutcome::UnknownOp;
    };
    match op {
        WorkspaceIntentOp::AdoptWorkspace => adopt(args, topology, pristine),
        WorkspaceIntentOp::RenamePane => rename_pane(args, topology),
        WorkspaceIntentOp::RenameTab => rename_tab(args, topology),
        WorkspaceIntentOp::RenameSession => rename_session(args, topology),
        WorkspaceIntentOp::ClosePane => close_pane(args, topology, ids, project_key),
        WorkspaceIntentOp::CloseTab => close_tab(args, topology, ids, project_key),
        WorkspaceIntentOp::SplitPane => split_pane(args, topology, ids),
        WorkspaceIntentOp::SpawnPane => spawn_pane(args, topology, ids),
        WorkspaceIntentOp::MovePane => move_pane(args, topology, ids),
        WorkspaceIntentOp::ReorderTabs => reorder_tabs(args, topology),
        WorkspaceIntentOp::FocusTab => focus_tab(args, topology),
        WorkspaceIntentOp::FocusPane => focus_pane(args, topology),
        WorkspaceIntentOp::SetSyncInput => set_sync_input(args, topology),
        WorkspaceIntentOp::SpawnTab => spawn_tab(args, topology, ids),
        WorkspaceIntentOp::SetZoom => set_zoom(args, topology),
        WorkspaceIntentOp::DetachPane => detach_pane(args, topology, ids),
        WorkspaceIntentOp::ReattachPane => reattach_pane(args, topology, ids),
        WorkspaceIntentOp::SetDividerWeight => set_divider_weight(args, topology),
        WorkspaceIntentOp::NewSession => new_session(args, topology, ids),
        WorkspaceIntentOp::CloseSession => close_session(args, topology, ids),
        WorkspaceIntentOp::ReopenClosedTab => reopen_closed_tab(args, topology),
        WorkspaceIntentOp::BreakPaneToTab => break_pane_to_tab(args, topology, ids),
        WorkspaceIntentOp::SwapPanes => swap_panes(args, topology),
        WorkspaceIntentOp::DockPaneAtTabEdge => dock_pane_at_tab_edge(args, topology, ids),
        WorkspaceIntentOp::SetTabLayout => set_tab_layout(args, topology),
        WorkspaceIntentOp::SpawnDetachedPane => spawn_detached_pane(args, topology, ids),
        WorkspaceIntentOp::SetPaneVideoTarget => set_pane_video_target(args, topology),
    }
}

// ---------------------------------------------------------------------------------------------- //
// Acceptance
// ---------------------------------------------------------------------------------------------- //

/// The last gate every op passes through.
///
/// Re-checking the RESULT, rather than trying to enumerate every hostile input, is what makes a
/// network caller safe: a structure past the decoder's depth cap would lose a leaf — and therefore
/// a live pane — the next time it round-tripped, and a broken spec invariant hands the next op a
/// corrupt input.
fn accept(next: WorkspaceTopology) -> IntentOutcome {
    if !next.tree.invariant_holds() {
        return IntentOutcome::RejectedInvalid;
    }
    let too_deep = next
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.tabs.iter())
        .any(|tab| tab.root.depth() > MAX_DEPTH);
    if too_deep {
        return IntentOutcome::RejectedInvalid;
    }
    IntentOutcome::Applied(Box::new(next))
}

/// Re-derives the side maps that name panes and tabs, after an op may have removed some.
///
/// Without this a closed pane's spawn cwd, a closed tab's sync-input bit and a dead tab in the MRU
/// ring all linger — and the ring one is not cosmetic: a close reads it to pick a successor, so a
/// stale entry sends every client to a tab that is not there.
fn pruned(topology: &WorkspaceTopology) -> WorkspaceTopology {
    let mut next = topology.clone();
    let live_tabs: BTreeSet<TabId> = next
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.tabs.iter().map(|tab| tab.id))
        .collect();
    let live_panes: BTreeSet<PaneId> = next
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.specs.keys().copied())
        .chain(
            next.closed_tabs
                .iter()
                .flat_map(|closed| closed.specs.keys().copied()),
        )
        .collect();
    next.sync_input_tabs.retain(|tab| live_tabs.contains(tab));
    next.spawn_cwd.retain(|pane, _| live_panes.contains(pane));
    // A tab that came back is no longer reopenable. One cannot be both open and in the ring, and
    // rendering it twice is worse than losing one undo step.
    next.closed_tabs
        .retain(|closed| !live_tabs.contains(&closed.tab.id));
    let mut focus = BTreeMap::new();
    for session in &next.tree.sessions {
        let kept: Vec<TabId> = next
            .focus_mru
            .get(&session.id)
            .map(|ring| {
                ring.iter()
                    .copied()
                    .filter(|tab| live_tabs.contains(tab))
                    .collect()
            })
            .unwrap_or_default();
        if !kept.is_empty() {
            focus.insert(session.id, kept);
        }
    }
    next.focus_mru = focus;
    next
}

/// Records a tab at the head of its session's MRU ring — the successor a close will read.
fn noting_focus(topology: &WorkspaceTopology, tab: TabId) -> WorkspaceTopology {
    let mut next = topology.clone();
    let Some(session) = next
        .tree
        .sessions
        .iter()
        .find(|session| session.tabs.iter().any(|candidate| candidate.id == tab))
        .map(|session| session.id)
    else {
        return next;
    };
    let mut ring: Vec<TabId> = next
        .focus_mru
        .get(&session)
        .map(|ring| ring.iter().copied().filter(|id| *id != tab).collect())
        .unwrap_or_default();
    ring.insert(0, tab);
    ring.truncate(FOCUS_MRU_CAP);
    next.focus_mru.insert(session, ring);
    next
}

// ---------------------------------------------------------------------------------------------- //
// Lookups
// ---------------------------------------------------------------------------------------------- //

fn has_pane(topology: &WorkspaceTopology, pane: PaneId) -> bool {
    topology.tree.contains(pane) || topology.tree.is_detached(pane)
}

fn has_tab(topology: &WorkspaceTopology, tab: TabId) -> bool {
    topology
        .tree
        .sessions
        .iter()
        .any(|session| session.tabs.iter().any(|candidate| candidate.id == tab))
}

fn has_session(topology: &WorkspaceTopology, session: SessionId) -> bool {
    topology
        .tree
        .sessions
        .iter()
        .any(|candidate| candidate.id == session)
}

/// Whether a proposed id is free.
///
/// A pane id already in use would alias two panes onto one PTY the moment the channel opens — the
/// exact hazard the mux's own exclusivity check exists for. The reopen ring counts as in use: those
/// panes are still alive.
fn is_free(topology: &WorkspaceTopology, pane: PaneId) -> bool {
    !has_pane(topology, pane)
        && !topology
            .closed_tabs
            .iter()
            .any(|closed| closed.tab.contains(pane))
}

/// The session and tab owning a tab id.
fn session_of_tab(topology: &WorkspaceTopology, tab: TabId) -> Option<(usize, usize)> {
    topology
        .tree
        .sessions
        .iter()
        .enumerate()
        .find_map(|(index, session)| {
            session
                .tabs
                .iter()
                .position(|candidate| candidate.id == tab)
                .map(|position| (index, position))
        })
}

/// The tab a pane sits in.
fn tab_of_pane(topology: &WorkspaceTopology, pane: PaneId) -> Option<TabId> {
    topology.tree.location_of(pane).map(|(_, tab)| tab)
}

// ---------------------------------------------------------------------------------------------- //
// Ops
// ---------------------------------------------------------------------------------------------- //

fn adopt(args: &[u8], topology: &WorkspaceTopology, pristine: bool) -> IntentOutcome {
    // A bootstrap, not a migration. Refused forever once the host has a workspace of its own.
    if !pristine {
        return IntentOutcome::RejectedStale;
    }
    let Ok(state) = codec::decode_snapshot(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let Some(mut uploaded) = WorkspaceTopology::from_document(&state) else {
        return IntentOutcome::RejectedInvalid;
    };
    // The host keeps its OWN identity and its own ctl session — those are facts about this daemon,
    // not about the tree somebody uploaded.
    uploaded.host_display_name.clone_from(&topology.host_display_name);
    uploaded.unattached_session_id = topology.unattached_session_id;
    accept(pruned(&uploaded))
}

fn rename_pane(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, title)) = intent::decode_name(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    if !has_pane(topology, pane) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::updating_spec(&next.tree, pane, |spec| {
        spec.title = title;
        // A rename is AUTHORSHIP, and the flag is what makes the live-title derivations yield to it.
        // Setting the title without it would let the next OSC title overwrite the person.
        spec.user_renamed = true;
    });
    accept(next)
}

fn rename_tab(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, title)) = intent::decode_name(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let tab = TabId::from_bytes(raw);
    if !has_tab(topology, tab) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::rename_tab(&next.tree, tab, title);
    accept(next)
}

fn rename_session(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, name)) = intent::decode_name(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let session = SessionId::from_bytes(raw);
    if !has_session(topology, session) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::rename_session(&next.tree, session, name);
    accept(next)
}

fn close_pane(
    args: &[u8],
    topology: &WorkspaceTopology,
    ids: &mut impl IdSource,
    project_key: &impl Fn(PaneId) -> Option<String>,
) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    if !has_pane(topology, pane) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    // A DETACHED pane has no tab to walk. Without this branch the op would accept the id and the
    // tree op — which locates LEAVES only — would hand back the same tree: the client retires its
    // optimistic patch against a document that never moved, and the satellite window keeps a zombie
    // handle streaming.
    if next.tree.is_detached(pane) {
        next.tree = tree_ops::close_detached_pane(&next.tree, pane);
        return accept(pruned(&next));
    }
    let owning = tab_of_pane(&next, pane);
    let successor = owning.and_then(|tab| successor_after_closing(&next, tab, project_key));
    // A pane that is its tab's SOLE leaf takes the whole tab with it, and a cascaded-away tab is as
    // reopenable as an explicitly closed one — the person closed the same thing either way. The
    // capture happens BEFORE the op, because afterwards there is no tab left to record.
    if let Some(tab) = owning
        && sole_leaf(&next, tab) == Some(pane)
    {
        next = capturing(&next, tab);
    }
    next.tree = tree_ops::close_pane(&next.tree, pane, successor, ids);
    accept(pruned(&next))
}

fn close_tab(
    args: &[u8],
    topology: &WorkspaceTopology,
    ids: &mut impl IdSource,
    project_key: &impl Fn(PaneId) -> Option<String>,
) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let tab = TabId::from_bytes(raw);
    if !has_tab(topology, tab) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = capturing(topology, tab);
    let successor = successor_after_closing(&next, tab, project_key);
    next.tree = tree_ops::close_tab(&next.tree, tab, successor, ids);
    accept(pruned(&next))
}

/// Files a tab whole onto the reopen ring — its split tree, its title, and every leaf's spec.
///
/// Kept WHOLE, not as an id: the reopen has to put the split tree and every pane's spec back, and a
/// [`TabId`] alone cannot rebuild either.
fn capturing(topology: &WorkspaceTopology, tab: TabId) -> WorkspaceTopology {
    let mut next = topology.clone();
    let Some(session) = next
        .tree
        .sessions
        .iter()
        .find(|session| session.tabs.iter().any(|candidate| candidate.id == tab))
    else {
        return next;
    };
    let Some(found) = session.tabs.iter().find(|candidate| candidate.id == tab) else {
        return next;
    };
    let specs: BTreeMap<PaneId, PaneSpec> = found
        .all_pane_ids()
        .into_iter()
        .filter_map(|pane| session.specs.get(&pane).map(|spec| (pane, spec.clone())))
        .collect();
    let record = ClosedTab {
        session_id: session.id,
        tab: found.clone(),
        specs,
    };
    next.closed_tabs.push(record);
    let overflow = next.closed_tabs.len().saturating_sub(CLOSED_TAB_RING_CAP);
    next.closed_tabs.drain(..overflow);
    next
}

/// The pane a tab would be emptied by losing — its ONLY leaf. `None` when the tab has siblings and
/// therefore survives.
fn sole_leaf(topology: &WorkspaceTopology, tab: TabId) -> Option<PaneId> {
    let found = topology
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.tabs.iter())
        .find(|candidate| candidate.id == tab)?;
    (found.root.leaf_count() == 1)
        .then(|| found.root.all_pane_ids())?
        .into_iter()
        .next()
}

/// The tab to select when one goes away.
///
/// Closing a BACKGROUND tab returns the session's own ACTIVE tab: the person dismissed something
/// they were not looking at, and focus has no business moving. That comes ahead of the ring,
/// because the ring's head is where they were BEFORE — which is not where they are now. Then the
/// most recent surviving tab, then the section rule the sidebar itself draws with.
///
/// The ring alone is not enough: a fresh launch has an empty one and the tabs are in CREATION
/// order, so the tree op's index clamp underneath lands on whatever tab sits at that index —
/// routinely a different project than the one being read.
fn successor_after_closing(
    topology: &WorkspaceTopology,
    closing: TabId,
    project_key: &impl Fn(PaneId) -> Option<String>,
) -> Option<TabId> {
    let session = topology
        .tree
        .sessions
        .iter()
        .find(|session| session.tabs.iter().any(|candidate| candidate.id == closing))?;
    if let Some(active) = session.tabs.get(session.active_tab_index)
        && active.id != closing
    {
        return Some(active.id);
    }
    let empty = Vec::new();
    let ring = topology.focus_mru.get(&session.id).unwrap_or(&empty);
    let live: BTreeSet<TabId> = session.tabs.iter().map(|tab| tab.id).collect();
    if let Some(recent) = ring.iter().find(|tab| **tab != closing && live.contains(tab)) {
        return Some(*recent);
    }
    let tab_key = |tab: TabId| tab_ordering::tab_project_key(tab, session, project_key);
    let order =
        tab_ordering::project_grouped_tab_order(session.tabs.iter().map(|tab| tab.id).collect(), tab_key);
    tab_ordering::successor_after_close(closing, &order, tab_key, ring)
}

fn split_pane(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(split) = intent::decode_split(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let target = PaneId::from_bytes(split.target);
    let pane = PaneId::from_bytes(split.new_pane);
    if !topology.tree.contains(target) {
        return IntentOutcome::RejectedNotFound;
    }
    if !is_free(topology, pane) {
        return IntentOutcome::RejectedInvalid;
    }
    inserting(
        topology,
        pane,
        target,
        split.axis,
        split.before,
        &split.spawn_cwd,
        ids,
    )
}

/// `spawnPane` targets a TAB rather than a pane — "give me another pane in here" — and splits
/// whatever that tab has focused.
///
/// A distinct op because the client knows which tab it means and should not have to guess which
/// pane will be focused when the intent lands.
fn spawn_pane(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(split) = intent::decode_split(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let tab = TabId::from_bytes(split.target);
    let pane = PaneId::from_bytes(split.new_pane);
    let Some(target) = topology
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.tabs.iter())
        .find(|candidate| candidate.id == tab)
        .and_then(|found| found.active_pane.or_else(|| found.root.first_leaf_id()))
    else {
        return IntentOutcome::RejectedNotFound;
    };
    if !is_free(topology, pane) {
        return IntentOutcome::RejectedInvalid;
    }
    inserting(
        topology,
        pane,
        target,
        split.axis,
        split.before,
        &split.spawn_cwd,
        ids,
    )
}

fn inserting(
    topology: &WorkspaceTopology,
    pane: PaneId,
    target: PaneId,
    axis: slopdesk_tree::SplitAxis,
    before: bool,
    cwd: &str,
    ids: &mut impl IdSource,
) -> IntentOutcome {
    let mut next = topology.clone();
    let spec = PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE);
    let grown = tree_ops::split_pane(&next.tree, target, axis, spec, before, pane, ids);
    if !grown.contains(pane) {
        return IntentOutcome::RejectedInvalid;
    }
    next.tree = grown;
    if !cwd.is_empty() {
        next.spawn_cwd.insert(pane, cwd.to_owned());
    }
    if let Some(tab) = tab_of_pane(&next, pane) {
        next = noting_focus(&next, tab);
    }
    accept(next)
}

fn move_pane(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(moved) = intent::decode_move(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let source = PaneId::from_bytes(moved.source);
    let target = PaneId::from_bytes(moved.target);
    if !topology.tree.contains(source) || !topology.tree.contains(target) {
        return IntentOutcome::RejectedNotFound;
    }
    if source == target {
        return IntentOutcome::RejectedInvalid;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::move_leaf_across_tabs(&next.tree, source, target, moved.axis, moved.before, ids);
    // The op validates the destination itself and answers its input untouched when the insert would
    // breach the depth cap. An unmoved pane is a refusal, not a satisfied request.
    if tab_of_pane(&next, source) != tab_of_pane(&next, target) {
        return IntentOutcome::RejectedInvalid;
    }
    accept(next)
}

fn reorder_tabs(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, order)) = intent::decode_reorder_tabs(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let session_id = SessionId::from_bytes(raw);
    let Some(index) = topology
        .tree
        .sessions
        .iter()
        .position(|session| session.id == session_id)
    else {
        return IntentOutcome::RejectedNotFound;
    };
    let Some(session) = topology.tree.sessions.get(index) else {
        return IntentOutcome::RejectedNotFound;
    };
    let wanted: Vec<TabId> = order.into_iter().map(TabId::from_bytes).collect();
    // A PERMUTATION or nothing. A partial order would silently drop the tabs it left out, and a
    // reorder is the one op where "some of it applied" is indistinguishable from a close.
    let have: BTreeSet<TabId> = session.tabs.iter().map(|tab| tab.id).collect();
    let asked: BTreeSet<TabId> = wanted.iter().copied().collect();
    if asked != have || wanted.len() != session.tabs.len() {
        return IntentOutcome::RejectedInvalid;
    }
    let active = session.tabs.get(session.active_tab_index).map(|tab| tab.id);
    let reordered: Vec<Tab> = wanted
        .iter()
        .filter_map(|id| session.tabs.iter().find(|tab| tab.id == *id).cloned())
        .collect();
    let mut next = topology.clone();
    let Some(session) = next.tree.sessions.get_mut(index) else {
        return IntentOutcome::RejectedNotFound;
    };
    session.tabs = reordered;
    // Selection follows the TAB, not the slot it used to sit in.
    session.active_tab_index = active
        .and_then(|id| wanted.iter().position(|tab| *tab == id))
        .unwrap_or(0);
    accept(next)
}

fn focus_tab(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let tab = TabId::from_bytes(raw);
    let Some((session_index, tab_index)) = session_of_tab(topology, tab) else {
        return IntentOutcome::RejectedNotFound;
    };
    let mut next = topology.clone();
    let Some(session) = next.tree.sessions.get_mut(session_index) else {
        return IntentOutcome::RejectedNotFound;
    };
    session.active_tab_index = tab_index;
    next.tree.active_session_id = Some(session.id);
    accept(noting_focus(&next, tab))
}

fn focus_pane(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    if !topology.tree.contains(pane) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::focus_pane(&next.tree, pane);
    if let Some(tab) = tab_of_pane(&next, pane) {
        next = noting_focus(&next, tab);
    }
    accept(next)
}

fn set_sync_input(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, armed)) = intent::decode_flag(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let tab = TabId::from_bytes(raw);
    if !has_tab(topology, tab) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    if armed {
        next.sync_input_tabs.insert(tab);
    } else {
        next.sync_input_tabs.remove(&tab);
    }
    accept(next)
}

fn spawn_tab(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(spawn) = intent::decode_spawn_tab(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let session = SessionId::from_bytes(spawn.session);
    let pane = PaneId::from_bytes(spawn.new_pane);
    if !has_session(topology, session) {
        return IntentOutcome::RejectedNotFound;
    }
    if !is_free(topology, pane) {
        return IntentOutcome::RejectedInvalid;
    }
    let mut next = topology.clone();
    // The tab op works on the ACTIVE session. Selecting first is not a side effect to apologise for
    // — a client asking for a tab in a session is asking to be looking at that session.
    next.tree = tree_ops::select_session(&next.tree, session);
    let tab = ids.tab();
    let spec = PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE);
    let grown = tree_ops::new_tab(&next.tree, spec, spawn.position, tab, pane);
    if !grown.contains(pane) {
        return IntentOutcome::RejectedInvalid;
    }
    next.tree = grown;
    if !spawn.spawn_cwd.is_empty() {
        next.spawn_cwd.insert(pane, spawn.spawn_cwd);
    }
    accept(noting_focus(&next, tab))
}

fn set_zoom(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, zoomed)) = intent::decode_flag(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    let Some((session_index, tab_index)) = tree_ops::locate(&topology.tree, pane) else {
        return IntentOutcome::RejectedNotFound;
    };
    let mut next = topology.clone();
    let Some(tab) = next
        .tree
        .sessions
        .get_mut(session_index)
        .and_then(|session| session.tabs.get_mut(tab_index))
    else {
        return IntentOutcome::RejectedNotFound;
    };
    // Set, not toggle. A toggle over shared state resolves differently depending on how many clients
    // sent it, which is the class of bug an idempotent assignment cannot have.
    tab.zoomed_pane = zoomed.then_some(pane);
    accept(next)
}

fn detach_pane(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    if !topology.tree.contains(pane) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::detach_pane(&next.tree, pane, ids);
    accept(pruned(&next))
}

fn reattach_pane(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    if !topology.tree.is_detached(pane) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::reattach_pane(&next.tree, pane, ids.tab(), ids);
    if next.tree.is_detached(pane) {
        return IntentOutcome::RejectedInvalid;
    }
    accept(pruned(&next))
}

fn set_divider_weight(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, index, weight)) = intent::decode_divider_weight(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    // A weight that is not a finite positive number would starve a pane to nothing. Checked here
    // rather than left to the layout solver's clamp, so the DOCUMENT never carries the nonsense.
    if !weight.is_finite() || weight < MIN_WEIGHT {
        return IntentOutcome::RejectedInvalid;
    }
    let split = SplitNodeId::from_bytes(raw);
    if !contains_split(topology, split) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::set_divider_weight(&next.tree, split, usize::from(index), weight);
    accept(next)
}

fn contains_split(topology: &WorkspaceTopology, split: SplitNodeId) -> bool {
    fn walk(node: &SplitNode, split: SplitNodeId) -> bool {
        let SplitNode::Split { id, children, .. } = node else {
            return false;
        };
        *id == split || children.iter().any(|child| walk(&child.node, split))
    }
    topology
        .tree
        .sessions
        .iter()
        .flat_map(|session| session.tabs.iter())
        .any(|tab| walk(&tab.root, split))
}

fn new_session(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(new) = intent::decode_new_session(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let session_id = SessionId::from_bytes(new.session);
    let pane = PaneId::from_bytes(new.new_pane);
    if has_session(topology, session_id) || !is_free(topology, pane) {
        return IntentOutcome::RejectedInvalid;
    }
    let mut next = topology.clone();
    if !new.spawn_cwd.is_empty() {
        next.spawn_cwd.insert(pane, new.spawn_cwd);
    }
    let tab = ids.tab();
    let name = if new.name.is_empty() {
        DEFAULT_SESSION_NAME.to_owned()
    } else {
        new.name
    };
    let spec = PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE);
    let session = Session::single_pane(session_id, name, tab, pane, spec);
    next.tree = tree_ops::insert_session(&next.tree, session, true);
    accept(noting_focus(&next, tab))
}

fn close_session(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let session = SessionId::from_bytes(raw);
    if !has_session(topology, session) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::close_session(&next.tree, session, ids);
    accept(pruned(&next))
}

fn reopen_closed_tab(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((lifo_index, position)) = intent::decode_reopen_closed_tab(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    // The ring is newest-LAST, and the index counts from the newest.
    let from_end = usize::from(lifo_index) + 1;
    let Some(array_index) = topology.closed_tabs.len().checked_sub(from_end) else {
        // Nothing to reopen — an empty ring, or an index past its end — is NOT an error. The gesture
        // on an empty ring is a satisfied request that changes nothing, and answering rejected would
        // make every client roll back a patch it never made.
        return IntentOutcome::Applied(Box::new(topology.clone()));
    };
    let Some(restored) = topology.closed_tabs.get(array_index).cloned() else {
        return IntentOutcome::Applied(Box::new(topology.clone()));
    };
    let mut next = topology.clone();
    next.closed_tabs.remove(array_index);
    // The owning session may have been closed while the record sat on the ring. The tab still holds
    // live panes, so it lands in whichever session IS active rather than being refused — refusing
    // would strand the only copy of those panes in a ring entry that was just consumed.
    if next
        .tree
        .sessions
        .iter()
        .any(|session| session.id == restored.session_id)
    {
        next.tree = tree_ops::select_session(&next.tree, restored.session_id);
    }
    let Some(index) = next.tree.active_session_index() else {
        return IntentOutcome::RejectedNotFound;
    };
    let tab_id = restored.tab.id;
    next.tree = tree_ops::insert_tab(&next.tree, restored.tab, &restored.specs, position);
    let landed = next
        .tree
        .sessions
        .get(index)
        .is_some_and(|session| session.tabs.iter().any(|tab| tab.id == tab_id));
    if !landed {
        return IntentOutcome::RejectedInvalid;
    }
    accept(noting_focus(&next, tab_id))
}

fn break_pane_to_tab(args: &[u8], topology: &WorkspaceTopology, ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(raw) = intent::decode_identity(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    let Some(origin) = tab_of_pane(topology, pane) else {
        return IntentOutcome::RejectedNotFound;
    };
    let mut next = topology.clone();
    next.tree = tree_ops::break_pane_to_tab(&next.tree, pane, ids.tab());
    // The op is a no-op when the pane is its tab's ONLY leaf — there is nothing to break out of.
    let Some(landed) = tab_of_pane(&next, pane).filter(|landed| *landed != origin) else {
        return IntentOutcome::RejectedInvalid;
    };
    accept(noting_focus(&next, landed))
}

fn swap_panes(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw_a, raw_b)) = intent::decode_swap_panes(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let (a, b) = (PaneId::from_bytes(raw_a), PaneId::from_bytes(raw_b));
    if !topology.tree.contains(a) || !topology.tree.contains(b) {
        return IntentOutcome::RejectedNotFound;
    }
    if a == b {
        return IntentOutcome::RejectedInvalid;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::swap_panes(&next.tree, a, b);
    accept(next)
}

fn dock_pane_at_tab_edge(
    args: &[u8],
    topology: &WorkspaceTopology,
    ids: &mut impl IdSource,
) -> IntentOutcome {
    let Ok(dock) = intent::decode_dock_at_tab_edge(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let source = PaneId::from_bytes(dock.source);
    let tab = TabId::from_bytes(dock.tab);
    if !topology.tree.contains(source) || !has_tab(topology, tab) {
        return IntentOutcome::RejectedNotFound;
    }
    let mut next = topology.clone();
    next.tree = tree_ops::move_leaf_to_tab_root_edge(&next.tree, source, tab, dock.edge, ids);
    // The op declines a same-tab dock against a lone leaf, a dock past the depth cap, a dock the pane
    // already sits at, and a destination in another SESSION — so "did the source end up in the tab
    // the client named" is the one check that covers every refusal.
    if tab_of_pane(&next, source) != Some(tab) {
        return IntentOutcome::RejectedInvalid;
    }
    accept(pruned(&next))
}

fn set_tab_layout(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, blob)) = intent::decode_set_tab_layout(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let tab = TabId::from_bytes(raw);
    // The decoder enforces the depth cap while it descends, so an over-deep shape never materializes
    // as a value at all.
    let Ok(layout) = codec::decode_layout(&blob) else {
        return IntentOutcome::RejectedInvalid;
    };
    let Some((session_index, tab_index)) = session_of_tab(topology, tab) else {
        return IntentOutcome::RejectedNotFound;
    };
    let Some(current) = topology
        .tree
        .sessions
        .get(session_index)
        .and_then(|session| session.tabs.get(tab_index))
        .map(|tab| tab.root.all_pane_ids())
    else {
        return IntentOutcome::RejectedNotFound;
    };
    let Some(leaves) = valid_leaves(&layout) else {
        return IntentOutcome::RejectedInvalid;
    };
    // A RE-LAYOUT moves panes, it does not create or destroy them. A shape that adds a leaf would
    // invent a pane with no spec; one that drops a leaf would strand a live PTY with nothing
    // rendering it. Either is a different op, and neither is what a re-tile means.
    let asked: BTreeSet<PaneId> = leaves.iter().copied().collect();
    let have: BTreeSet<PaneId> = current.iter().copied().collect();
    if leaves.len() != current.len() || asked != have {
        return IntentOutcome::RejectedInvalid;
    }
    let mut next = topology.clone();
    let Some(target) = next
        .tree
        .sessions
        .get_mut(session_index)
        .and_then(|session| session.tabs.get_mut(tab_index))
    else {
        return IntentOutcome::RejectedNotFound;
    };
    // Every split comes back at an EQUAL share — a re-tile discards the divider drags that described
    // the OLD shape — and the tab EXITS zoom, because a zoomed tab renders one pane, so re-shaping
    // under a zoom would change nothing the person can see while the caller's cursor advances.
    target.root = rebuilt(&layout);
    target.zoomed_pane = None;
    accept(next)
}

/// The layout's leaves, or `None` when the shape itself is not one a tab may hold.
///
/// A split with fewer than two children breaks the tree's arity rule, and a repeated leaf would
/// alias two positions onto one pane. Neither is caught by the spec invariant [`accept`] re-checks.
fn valid_leaves(node: &WorkspaceLayoutNode) -> Option<Vec<PaneId>> {
    match node {
        WorkspaceLayoutNode::Leaf(id) => Some(vec![PaneId::from_bytes(*id)]),
        WorkspaceLayoutNode::Split { children, .. } => {
            if children.len() < 2 {
                return None;
            }
            let mut out = Vec::new();
            for child in children {
                out.extend(valid_leaves(child)?);
            }
            let unique: BTreeSet<PaneId> = out.iter().copied().collect();
            (unique.len() == out.len()).then_some(out)
        },
    }
}

fn rebuilt(node: &WorkspaceLayoutNode) -> SplitNode {
    match node {
        WorkspaceLayoutNode::Leaf(id) => SplitNode::Leaf(PaneId::from_bytes(*id)),
        WorkspaceLayoutNode::Split { id, axis, children } => {
            SplitNode::Split {
                id: SplitNodeId::from_bytes(*id),
                axis: *axis,
                children: children
                    .iter()
                    .map(|child| WeightedChild::new(SplitWeight::Flex(1.0), rebuilt(child)))
                    .collect(),
            }
        },
    }
}

fn spawn_detached_pane(args: &[u8], topology: &WorkspaceTopology, _ids: &mut impl IdSource) -> IntentOutcome {
    let Ok(spawn) = intent::decode_spawn_detached_pane(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(spawn.new_pane);
    if !is_free(topology, pane) {
        return IntentOutcome::RejectedInvalid;
    }
    // A zero-length blob is "no target"; bytes that are present but do not decode are malformed,
    // never a silently target-less pane — that would open a satellite window streaming nothing.
    let video = if spawn.video.is_empty() {
        None
    } else {
        let Some(decoded) = codec::decode_video_target(&spawn.video) else {
            return IntentOutcome::RejectedInvalid;
        };
        Some(decoded)
    };
    let mut spec = PaneSpec::new(spawn.kind, born_title(spawn.kind, video.as_ref()));
    spec.video = video;
    let mut next = topology.clone();
    let grown = tree_ops::mint_detached_pane(&next.tree, spec, pane);
    // The mint is a no-op when there is no session to park the pane in.
    if !grown.is_detached(pane) {
        return IntentOutcome::RejectedInvalid;
    }
    next.tree = grown;
    accept(next)
}

/// Re-points an existing pane's video binding.
///
/// The DERIVED title follows the binding, and only while it was tracking the previous one: a pane
/// whose title still reads as the old target's is renamed to the new target's, and a title the
/// person authored is left alone. That rule lives here rather than in a client, because the
/// document is where the spec is, and two clients deciding it separately is the divergence this
/// document exists to end.
fn set_pane_video_target(args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
    let Ok((raw, blob)) = intent::decode_set_pane_video_target(args) else {
        return IntentOutcome::RejectedInvalid;
    };
    let pane = PaneId::from_bytes(raw);
    // A zero-length blob UNBINDS; bytes that are present but do not decode are malformed.
    let video = if blob.is_empty() {
        None
    } else {
        let Some(decoded) = codec::decode_video_target(&blob) else {
            return IntentOutcome::RejectedInvalid;
        };
        Some(decoded)
    };
    let Some(index) = topology
        .tree
        .sessions
        .iter()
        .position(|session| session.specs.contains_key(&pane))
    else {
        return IntentOutcome::RejectedNotFound;
    };
    let mut next = topology.clone();
    let Some(spec) = next
        .tree
        .sessions
        .get_mut(index)
        .and_then(|session| session.specs.get_mut(&pane))
    else {
        return IntentOutcome::RejectedNotFound;
    };
    let tracking = spec
        .video
        .as_ref()
        .is_none_or(|current| spec.title == current.title);
    if !spec.user_renamed && tracking {
        spec.title = born_title(spec.kind, video.as_ref());
    }
    spec.video = video;
    accept(next)
}

/// The title a video-bound pane is born with: the endpoint's own when it has one — that is what the
/// person picked in the picker — else the kind's plain noun.
fn born_title(kind: PaneKind, video: Option<&codec::VideoEndpoint>) -> String {
    if let Some(endpoint) = video
        && !endpoint.title.is_empty()
    {
        return endpoint.title.clone();
    }
    if kind.is_video() {
        DEFAULT_VIDEO_TITLE.to_owned()
    } else {
        DEFAULT_PANE_TITLE.to_owned()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a refused intent in a test that expected one applied has nothing to return"
    )]

    use std::cell::Cell;

    use slopdesk_ids::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
    use slopdesk_tree::session::{NewTabPosition, PaneKind, PaneSpec};
    use slopdesk_tree::split_tree::{PaneDropEdge, SplitAxis, SplitNode};
    use slopdesk_tree::tree_ops;
    use slopdesk_tree::workspace::TreeWorkspace;

    use super::super::codec::{self, VideoEndpoint, WorkspaceLayoutNode};
    use super::super::intent::{self, WorkspaceIntentOp};
    use super::super::topology::WorkspaceTopology;
    use super::{IntentOutcome, apply, no_project_keys};

    thread_local! {
        /// Minted ids have to stay unique across the WHOLE test, not just one call — every helper
        /// below builds its topology by chaining applies, and a counter that restarted each time
        /// would hand two tabs one id and make the ring tests silently dedup.
        static NEXT_ID: Cell<u32> = const { Cell::new(0) };
    }

    #[derive(Debug)]
    struct Counter;

    impl Counter {
        /// Distinct from every hand-written `[byte; 16]` in this module, and ordered by mint.
        fn raw() -> [u8; 16] {
            let next = NEXT_ID.with(|cell| {
                let next = cell.get().wrapping_add(1);
                cell.set(next);
                next
            });
            let mut out = [0xEE_u8; 16];
            for (slot, byte) in out.iter_mut().zip(next.to_be_bytes()) {
                *slot = byte;
            }
            out
        }
    }

    impl IdSource for Counter {
        fn pane(&mut self) -> PaneId {
            PaneId::from_bytes(Self::raw())
        }

        fn tab(&mut self) -> TabId {
            TabId::from_bytes(Self::raw())
        }

        fn session(&mut self) -> SessionId {
            SessionId::from_bytes(Self::raw())
        }

        fn split(&mut self) -> SplitNodeId {
            SplitNodeId::from_bytes(Self::raw())
        }
    }

    const fn ids() -> Counter {
        Counter
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

    fn one_pane() -> WorkspaceTopology {
        WorkspaceTopology::new(TreeWorkspace::single_pane(
            session_id(1),
            tab_id(1),
            pane(1),
            PaneSpec::new(PaneKind::Terminal, "Terminal"),
        ))
    }

    fn run(op: WorkspaceIntentOp, args: &[u8], topology: &WorkspaceTopology) -> IntentOutcome {
        apply(op.as_byte(), args, topology, &mut ids(), false, &no_project_keys)
    }

    fn applied(op: WorkspaceIntentOp, args: &[u8], topology: &WorkspaceTopology) -> WorkspaceTopology {
        match run(op, args, topology) {
            IntentOutcome::Applied(next) => *next,
            other => panic!("expected an applied intent, got {other:?}"),
        }
    }

    /// Two panes in one tab — the shape most ops need.
    fn two_panes() -> WorkspaceTopology {
        applied(
            WorkspaceIntentOp::SplitPane,
            &intent::encode_split(
                &pane(1).bytes(),
                SplitAxis::Horizontal,
                false,
                &pane(2).bytes(),
                "",
            ),
            &one_pane(),
        )
    }

    #[test]
    fn an_unknown_op_byte_is_named_as_such() {
        assert_eq!(
            apply(0xFE, &[], &one_pane(), &mut ids(), false, &no_project_keys),
            IntentOutcome::UnknownOp,
        );
    }

    #[test]
    fn a_truncated_payload_is_refused_rather_than_read_past() {
        assert_eq!(
            run(WorkspaceIntentOp::FocusPane, &[1, 2, 3], &one_pane()),
            IntentOutcome::RejectedInvalid,
        );
    }

    #[test]
    fn a_reference_to_a_pane_that_is_not_there_is_not_found() {
        assert_eq!(
            run(
                WorkspaceIntentOp::FocusPane,
                &intent::encode_identity(&pane(90).bytes()),
                &one_pane(),
            ),
            IntentOutcome::RejectedNotFound,
        );
    }

    #[test]
    fn a_bootstrap_after_the_host_has_a_workspace_is_stale() {
        let snapshot = codec::encode_snapshot(&super::super::state::HostWorkspaceState::from_entries(
            two_panes().entries(),
        ));
        assert_eq!(
            apply(
                WorkspaceIntentOp::AdoptWorkspace.as_byte(),
                &snapshot,
                &one_pane(),
                &mut ids(),
                false,
                &no_project_keys,
            ),
            IntentOutcome::RejectedStale,
        );
    }

    #[test]
    fn a_bootstrap_into_a_pristine_host_keeps_the_hosts_own_identity() {
        let mut host = one_pane();
        host.host_display_name = "studio".to_owned();
        host.unattached_session_id = Some(session_id(7));
        let snapshot = codec::encode_snapshot(&super::super::state::HostWorkspaceState::from_entries(
            two_panes().entries(),
        ));
        let IntentOutcome::Applied(next) = apply(
            WorkspaceIntentOp::AdoptWorkspace.as_byte(),
            &snapshot,
            &host,
            &mut ids(),
            true,
            &no_project_keys,
        ) else {
            panic!("a pristine host adopts");
        };
        assert_eq!(next.host_display_name, "studio");
        assert_eq!(next.unattached_session_id, Some(session_id(7)));
        assert_eq!(next.tree.all_pane_ids(), vec![pane(1), pane(2)]);
    }

    #[test]
    fn a_rename_marks_the_title_as_authored() {
        let next = applied(
            WorkspaceIntentOp::RenamePane,
            &intent::encode_name(&pane(1).bytes(), "Build"),
            &one_pane(),
        );
        let Some(spec) = next.tree.spec_for(pane(1)) else {
            panic!("the pane has a spec");
        };
        assert_eq!(spec.title, "Build");
        assert!(
            spec.user_renamed,
            "the next OSC title must not overwrite the person"
        );
    }

    #[test]
    fn a_split_proposing_an_id_already_in_use_is_refused() {
        assert_eq!(
            run(
                WorkspaceIntentOp::SplitPane,
                &intent::encode_split(
                    &pane(1).bytes(),
                    SplitAxis::Horizontal,
                    false,
                    &pane(1).bytes(),
                    ""
                ),
                &one_pane(),
            ),
            IntentOutcome::RejectedInvalid,
            "an aliased id would put two panes on one PTY",
        );
    }

    #[test]
    fn a_split_records_the_spawn_cwd_and_the_focus() {
        let next = applied(
            WorkspaceIntentOp::SplitPane,
            &intent::encode_split(
                &pane(1).bytes(),
                SplitAxis::Vertical,
                false,
                &pane(2).bytes(),
                "/work/repo",
            ),
            &one_pane(),
        );
        assert_eq!(
            next.spawn_cwd.get(&pane(2)).map(String::as_str),
            Some("/work/repo")
        );
        assert_eq!(next.focus_mru.get(&session_id(1)), Some(&vec![tab_id(1)]));
        assert!(next.tree.invariant_holds());
    }

    #[test]
    fn spawn_pane_splits_whatever_the_named_tab_has_focused() {
        let next = applied(
            WorkspaceIntentOp::SpawnPane,
            &intent::encode_split(
                &tab_id(1).bytes(),
                SplitAxis::Horizontal,
                false,
                &pane(2).bytes(),
                "",
            ),
            &one_pane(),
        );
        assert_eq!(next.tree.all_pane_ids(), vec![pane(1), pane(2)]);
    }

    #[test]
    fn closing_a_pane_that_owns_its_tab_files_the_tab_for_reopening() {
        let two_tabs = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(&session_id(1).bytes(), &pane(2).bytes(), NewTabPosition::End, ""),
            &one_pane(),
        );
        let next = applied(
            WorkspaceIntentOp::ClosePane,
            &intent::encode_identity(&pane(2).bytes()),
            &two_tabs,
        );
        assert_eq!(
            next.closed_tabs.len(),
            1,
            "a cascaded-away tab is as reopenable as a closed one"
        );
        assert!(!next.tree.contains(pane(2)));
        assert!(next.tree.invariant_holds());
    }

    #[test]
    fn closing_a_detached_pane_takes_the_handle_with_it() {
        let detached = applied(
            WorkspaceIntentOp::DetachPane,
            &intent::encode_identity(&pane(2).bytes()),
            &two_panes(),
        );
        assert_eq!(detached.tree.detached_pane_ids(), vec![pane(2)]);
        let closed = applied(
            WorkspaceIntentOp::ClosePane,
            &intent::encode_identity(&pane(2).bytes()),
            &detached,
        );
        assert!(closed.tree.detached_pane_ids().is_empty());
        assert!(closed.tree.spec_for(pane(2)).is_none());
    }

    #[test]
    fn a_close_prunes_the_side_maps_that_named_the_dead() {
        let with_cwd = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(
                &session_id(1).bytes(),
                &pane(2).bytes(),
                NewTabPosition::End,
                "/work",
            ),
            &one_pane(),
        );
        let Some(tab) = with_cwd.tree.location_of(pane(2)).map(|(_, tab)| tab) else {
            panic!("the spawned pane has a tab");
        };
        let armed = applied(
            WorkspaceIntentOp::SetSyncInput,
            &intent::encode_flag(&tab.bytes(), true),
            &with_cwd,
        );
        let closed = applied(
            WorkspaceIntentOp::CloseTab,
            &intent::encode_identity(&tab.bytes()),
            &armed,
        );
        assert!(closed.sync_input_tabs.is_empty(), "a dead tab keeps no armed bit");
        assert!(
            !closed.focus_mru.values().any(|ring| ring.contains(&tab)),
            "a stale ring entry sends every client to a tab that is not there",
        );
        assert!(
            closed.spawn_cwd.contains_key(&pane(2)),
            "the pane is on the reopen ring, so its cwd is still live",
        );
    }

    #[test]
    fn a_reopen_puts_the_tab_and_its_specs_back() {
        let two_tabs = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(&session_id(1).bytes(), &pane(2).bytes(), NewTabPosition::End, ""),
            &one_pane(),
        );
        let Some(tab) = two_tabs.tree.location_of(pane(2)).map(|(_, tab)| tab) else {
            panic!("the spawned pane has a tab");
        };
        let closed = applied(
            WorkspaceIntentOp::CloseTab,
            &intent::encode_identity(&tab.bytes()),
            &two_tabs,
        );
        let reopened = applied(
            WorkspaceIntentOp::ReopenClosedTab,
            &intent::encode_reopen_closed_tab(0, NewTabPosition::End),
            &closed,
        );
        assert!(reopened.tree.contains(pane(2)));
        assert!(
            reopened.closed_tabs.is_empty(),
            "a tab that came back is no longer reopenable"
        );
        assert!(reopened.tree.invariant_holds());
    }

    #[test]
    fn a_reopen_on_an_empty_ring_is_a_satisfied_request() {
        let before = one_pane();
        let next = applied(
            WorkspaceIntentOp::ReopenClosedTab,
            &intent::encode_reopen_closed_tab(0, NewTabPosition::End),
            &before,
        );
        assert_eq!(
            next, before,
            "rolling back a patch nobody made is worse than doing nothing"
        );
    }

    #[test]
    fn a_partial_reorder_is_refused_because_it_would_read_as_a_close() {
        let two_tabs = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(&session_id(1).bytes(), &pane(2).bytes(), NewTabPosition::End, ""),
            &one_pane(),
        );
        assert_eq!(
            run(
                WorkspaceIntentOp::ReorderTabs,
                &intent::encode_reorder_tabs(&session_id(1).bytes(), &[tab_id(1).bytes()]),
                &two_tabs,
            ),
            IntentOutcome::RejectedInvalid,
        );
    }

    #[test]
    fn a_reorder_keeps_the_selection_on_the_tab_rather_than_the_slot() {
        let two_tabs = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(&session_id(1).bytes(), &pane(2).bytes(), NewTabPosition::End, ""),
            &one_pane(),
        );
        let Some(session) = two_tabs.tree.sessions.first() else {
            panic!("one session");
        };
        let order: Vec<TabId> = session.tabs.iter().map(|tab| tab.id).collect();
        let Some(active) = session.tabs.get(session.active_tab_index).map(|tab| tab.id) else {
            panic!("an active tab");
        };
        let reversed: Vec<[u8; 16]> = order.iter().rev().map(|id| id.bytes()).collect();
        let next = applied(
            WorkspaceIntentOp::ReorderTabs,
            &intent::encode_reorder_tabs(&session_id(1).bytes(), &reversed),
            &two_tabs,
        );
        let Some(session) = next.tree.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(
            session.tabs.get(session.active_tab_index).map(|tab| tab.id),
            Some(active),
        );
    }

    #[test]
    fn a_zoom_is_set_rather_than_toggled() {
        let armed = applied(
            WorkspaceIntentOp::SetZoom,
            &intent::encode_flag(&pane(1).bytes(), true),
            &two_panes(),
        );
        let twice = applied(
            WorkspaceIntentOp::SetZoom,
            &intent::encode_flag(&pane(1).bytes(), true),
            &armed,
        );
        assert_eq!(twice, armed, "an idempotent assignment cannot race two clients");
        let cleared = applied(
            WorkspaceIntentOp::SetZoom,
            &intent::encode_flag(&pane(1).bytes(), false),
            &armed,
        );
        let Some(tab) = cleared.tree.sessions.first().and_then(|s| s.tabs.first()) else {
            panic!("one tab");
        };
        assert_eq!(tab.zoomed_pane, None);
    }

    #[test]
    fn a_divider_weight_that_would_starve_a_pane_is_refused() {
        let before = two_panes();
        let Some(SplitNode::Split { id, .. }) = before
            .tree
            .sessions
            .first()
            .and_then(|s| s.tabs.first())
            .map(|tab| tab.root.clone())
        else {
            panic!("a split root");
        };
        for weight in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            assert_eq!(
                run(
                    WorkspaceIntentOp::SetDividerWeight,
                    &intent::encode_divider_weight(&id.bytes(), 0, weight),
                    &before,
                ),
                IntentOutcome::RejectedInvalid,
                "the document must never carry a weight the solver would have to repair",
            );
        }
        assert!(
            run(
                WorkspaceIntentOp::SetDividerWeight,
                &intent::encode_divider_weight(&id.bytes(), 0, 1.5),
                &before,
            )
            .is_applied()
        );
    }

    #[test]
    fn a_divider_weight_for_a_split_that_is_not_there_is_not_found() {
        assert_eq!(
            run(
                WorkspaceIntentOp::SetDividerWeight,
                &intent::encode_divider_weight(&[0x77; 16], 0, 1.5),
                &two_panes(),
            ),
            IntentOutcome::RejectedNotFound,
        );
    }

    #[test]
    fn a_new_session_naming_one_that_exists_is_refused() {
        assert_eq!(
            run(
                WorkspaceIntentOp::NewSession,
                &intent::encode_new_session(&session_id(1).bytes(), &pane(9).bytes(), "Other", ""),
                &one_pane(),
            ),
            IntentOutcome::RejectedInvalid,
        );
    }

    #[test]
    fn a_new_session_lands_selected_with_its_cwd_recorded() {
        let next = applied(
            WorkspaceIntentOp::NewSession,
            &intent::encode_new_session(&session_id(5).bytes(), &pane(9).bytes(), "", "/work"),
            &one_pane(),
        );
        assert_eq!(next.tree.active_session_id, Some(session_id(5)));
        assert_eq!(next.spawn_cwd.get(&pane(9)).map(String::as_str), Some("/work"));
        assert_eq!(
            next.tree.sessions.get(1).map(|session| session.name.clone()),
            Some("Local".to_owned()),
            "an empty name falls back rather than rendering blank",
        );
        assert!(next.tree.invariant_holds());
    }

    #[test]
    fn a_re_layout_that_adds_or_drops_a_leaf_is_refused() {
        let before = two_panes();
        let three = WorkspaceLayoutNode::Split {
            id: [9; 16],
            axis: SplitAxis::Horizontal,
            children: vec![
                WorkspaceLayoutNode::Leaf(pane(1).bytes()),
                WorkspaceLayoutNode::Leaf(pane(2).bytes()),
                WorkspaceLayoutNode::Leaf(pane(3).bytes()),
            ],
        };
        assert_eq!(
            run(
                WorkspaceIntentOp::SetTabLayout,
                &intent::encode_set_tab_layout(&tab_id(1).bytes(), &three),
                &before,
            ),
            IntentOutcome::RejectedInvalid,
            "a re-tile moves panes, it does not invent one",
        );
    }

    #[test]
    fn a_re_layout_with_a_repeated_leaf_is_refused() {
        let aliased = WorkspaceLayoutNode::Split {
            id: [9; 16],
            axis: SplitAxis::Horizontal,
            children: vec![
                WorkspaceLayoutNode::Leaf(pane(1).bytes()),
                WorkspaceLayoutNode::Leaf(pane(1).bytes()),
            ],
        };
        assert_eq!(
            run(
                WorkspaceIntentOp::SetTabLayout,
                &intent::encode_set_tab_layout(&tab_id(1).bytes(), &aliased),
                &two_panes(),
            ),
            IntentOutcome::RejectedInvalid,
        );
    }

    #[test]
    fn a_re_layout_resets_the_weights_and_exits_zoom() {
        let zoomed = applied(
            WorkspaceIntentOp::SetZoom,
            &intent::encode_flag(&pane(1).bytes(), true),
            &two_panes(),
        );
        let flipped = WorkspaceLayoutNode::Split {
            id: [9; 16],
            axis: SplitAxis::Vertical,
            children: vec![
                WorkspaceLayoutNode::Leaf(pane(2).bytes()),
                WorkspaceLayoutNode::Leaf(pane(1).bytes()),
            ],
        };
        let next = applied(
            WorkspaceIntentOp::SetTabLayout,
            &intent::encode_set_tab_layout(&tab_id(1).bytes(), &flipped),
            &zoomed,
        );
        let Some(tab) = next.tree.sessions.first().and_then(|s| s.tabs.first()) else {
            panic!("one tab");
        };
        assert_eq!(tab.zoomed_pane, None);
        assert_eq!(tab.all_pane_ids(), vec![pane(2), pane(1)]);
        let SplitNode::Split { children, .. } = &tab.root else {
            panic!("a split root");
        };
        for child in children {
            assert_eq!(child.weight, slopdesk_tree::SplitWeight::Flex(1.0));
        }
    }

    #[test]
    fn a_video_pane_is_born_with_its_endpoints_title() {
        let endpoint = VideoEndpoint {
            window_id: 0,
            title: "Studio Display".to_owned(),
            app_name: String::new(),
            display_id: Some(0),
        };
        let next = applied(
            WorkspaceIntentOp::SpawnDetachedPane,
            &intent::encode_spawn_detached_pane(&pane(70).bytes(), PaneKind::Desktop, Some(&endpoint)),
            &one_pane(),
        );
        assert_eq!(next.tree.detached_pane_ids(), vec![pane(70)]);
        assert_eq!(
            next.tree.spec_for(pane(70)).map(|spec| spec.title.clone()),
            Some("Studio Display".to_owned()),
        );
    }

    #[test]
    fn a_video_blob_that_does_not_decode_is_malformed_rather_than_target_less() {
        let mut args = intent::encode_spawn_detached_pane(&pane(70).bytes(), PaneKind::Desktop, None);
        args.extend_from_slice(&[0, 3, 1, 2, 3]);
        assert_eq!(
            run(WorkspaceIntentOp::SpawnDetachedPane, &args, &one_pane()),
            IntentOutcome::RejectedInvalid,
        );
    }

    #[test]
    fn re_pointing_a_video_target_moves_a_derived_title_and_leaves_an_authored_one() {
        let first = VideoEndpoint {
            window_id: 0,
            title: "Display One".to_owned(),
            app_name: String::new(),
            display_id: Some(0),
        };
        let second = VideoEndpoint {
            window_id: 0,
            title: "Display Two".to_owned(),
            app_name: String::new(),
            display_id: Some(1),
        };
        let born = applied(
            WorkspaceIntentOp::SpawnDetachedPane,
            &intent::encode_spawn_detached_pane(&pane(70).bytes(), PaneKind::Desktop, Some(&first)),
            &one_pane(),
        );
        let moved = applied(
            WorkspaceIntentOp::SetPaneVideoTarget,
            &intent::encode_set_pane_video_target(&pane(70).bytes(), Some(&second)),
            &born,
        );
        assert_eq!(
            moved.tree.spec_for(pane(70)).map(|spec| spec.title.clone()),
            Some("Display Two".to_owned()),
        );

        let renamed = applied(
            WorkspaceIntentOp::RenamePane,
            &intent::encode_name(&pane(70).bytes(), "Mine"),
            &born,
        );
        let after = applied(
            WorkspaceIntentOp::SetPaneVideoTarget,
            &intent::encode_set_pane_video_target(&pane(70).bytes(), Some(&second)),
            &renamed,
        );
        assert_eq!(
            after.tree.spec_for(pane(70)).map(|spec| spec.title.clone()),
            Some("Mine".to_owned()),
            "a title the person authored is not moved by a re-point",
        );
    }

    #[test]
    fn an_unbind_clears_the_target_without_refusing() {
        let endpoint = VideoEndpoint {
            window_id: 4,
            title: "Window".to_owned(),
            app_name: "Xcode".to_owned(),
            display_id: None,
        };
        let born = applied(
            WorkspaceIntentOp::SpawnDetachedPane,
            &intent::encode_spawn_detached_pane(&pane(70).bytes(), PaneKind::Desktop, Some(&endpoint)),
            &one_pane(),
        );
        let next = applied(
            WorkspaceIntentOp::SetPaneVideoTarget,
            &intent::encode_set_pane_video_target(&pane(70).bytes(), None),
            &born,
        );
        assert!(
            next.tree
                .spec_for(pane(70))
                .is_some_and(|spec| spec.video.is_none())
        );
    }

    #[test]
    fn a_dock_into_a_tab_the_pane_cannot_reach_is_refused() {
        let before = two_panes();
        assert_eq!(
            run(
                WorkspaceIntentOp::DockPaneAtTabEdge,
                &intent::encode_dock_at_tab_edge(&pane(1).bytes(), &tab_id(9).bytes(), PaneDropEdge::Left),
                &before,
            ),
            IntentOutcome::RejectedNotFound,
        );
        let docked = applied(
            WorkspaceIntentOp::DockPaneAtTabEdge,
            &intent::encode_dock_at_tab_edge(&pane(1).bytes(), &tab_id(1).bytes(), PaneDropEdge::Right),
            &before,
        );
        let Some(tab) = docked.tree.sessions.first().and_then(|s| s.tabs.first()) else {
            panic!("one tab");
        };
        assert_eq!(
            tab.all_pane_ids(),
            vec![pane(2), pane(1)],
            "a same-tab dock re-roots the pane"
        );
        assert!(docked.tree.invariant_holds());
    }

    #[test]
    fn a_break_out_of_a_lone_leaf_tab_is_a_refusal_rather_than_a_no_op_applied() {
        assert_eq!(
            run(
                WorkspaceIntentOp::BreakPaneToTab,
                &intent::encode_identity(&pane(1).bytes()),
                &one_pane(),
            ),
            IntentOutcome::RejectedInvalid,
        );
        let next = applied(
            WorkspaceIntentOp::BreakPaneToTab,
            &intent::encode_identity(&pane(2).bytes()),
            &two_panes(),
        );
        assert_eq!(next.tree.sessions.first().map(|s| s.tabs.len()), Some(2));
        assert!(next.tree.invariant_holds());
    }

    #[test]
    fn a_swap_of_a_pane_with_itself_is_refused() {
        assert_eq!(
            run(
                WorkspaceIntentOp::SwapPanes,
                &intent::encode_swap_panes(&pane(1).bytes(), &pane(1).bytes()),
                &two_panes(),
            ),
            IntentOutcome::RejectedInvalid,
        );
        let next = applied(
            WorkspaceIntentOp::SwapPanes,
            &intent::encode_swap_panes(&pane(1).bytes(), &pane(2).bytes()),
            &two_panes(),
        );
        let Some(tab) = next.tree.sessions.first().and_then(|s| s.tabs.first()) else {
            panic!("one tab");
        };
        assert_eq!(tab.all_pane_ids(), vec![pane(2), pane(1)]);
    }

    #[test]
    fn a_detach_and_reattach_round_trips_the_pane_without_losing_its_spec() {
        let detached = applied(
            WorkspaceIntentOp::DetachPane,
            &intent::encode_identity(&pane(2).bytes()),
            &two_panes(),
        );
        let back = applied(
            WorkspaceIntentOp::ReattachPane,
            &intent::encode_identity(&pane(2).bytes()),
            &detached,
        );
        assert!(back.tree.contains(pane(2)));
        assert!(back.tree.detached_pane_ids().is_empty());
        assert!(back.tree.invariant_holds());
    }

    #[test]
    fn a_reattach_of_a_pane_that_is_not_detached_is_not_found() {
        assert_eq!(
            run(
                WorkspaceIntentOp::ReattachPane,
                &intent::encode_identity(&pane(1).bytes()),
                &two_panes(),
            ),
            IntentOutcome::RejectedNotFound,
        );
    }

    #[test]
    fn closing_a_background_tab_leaves_focus_where_it_was() {
        let two_tabs = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(&session_id(1).bytes(), &pane(2).bytes(), NewTabPosition::End, ""),
            &one_pane(),
        );
        // The spawned tab is the active one; closing the OTHER one must not move the selection.
        let Some(active) = two_tabs
            .tree
            .sessions
            .first()
            .and_then(|session| session.tabs.get(session.active_tab_index))
            .map(|tab| tab.id)
        else {
            panic!("an active tab");
        };
        let next = applied(
            WorkspaceIntentOp::CloseTab,
            &intent::encode_identity(&tab_id(1).bytes()),
            &two_tabs,
        );
        let Some(session) = next.tree.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(
            session.tabs.get(session.active_tab_index).map(|tab| tab.id),
            Some(active),
            "the person dismissed something they were not looking at",
        );
    }

    #[test]
    fn every_op_byte_the_table_names_is_dispatched() {
        for op in WorkspaceIntentOp::ALL {
            assert_ne!(
                apply(
                    op.as_byte(),
                    &[],
                    &one_pane(),
                    &mut ids(),
                    false,
                    &no_project_keys
                ),
                IntentOutcome::UnknownOp,
                "{op:?} must reach a handler rather than falling off the table",
            );
        }
    }

    #[test]
    fn the_focus_ring_is_capped_and_newest_first() {
        let mut topology = one_pane();
        let mut byte = 2;
        for _ in 0..(super::FOCUS_MRU_CAP + 4) {
            topology = applied(
                WorkspaceIntentOp::SpawnTab,
                &intent::encode_spawn_tab(
                    &session_id(1).bytes(),
                    &pane(byte).bytes(),
                    NewTabPosition::End,
                    "",
                ),
                &topology,
            );
            byte += 1;
        }
        let Some(ring) = topology.focus_mru.get(&session_id(1)) else {
            panic!("the session has a ring");
        };
        assert_eq!(ring.len(), super::FOCUS_MRU_CAP);
        let Some(newest) = topology.tree.location_of(pane(byte - 1)).map(|(_, tab)| tab) else {
            panic!("the last spawned pane has a tab");
        };
        assert_eq!(ring.first(), Some(&newest));
    }

    #[test]
    fn the_reopen_ring_is_capped() {
        let mut topology = one_pane();
        for byte in (2..).take(super::CLOSED_TAB_RING_CAP + 3) {
            topology = applied(
                WorkspaceIntentOp::SpawnTab,
                &intent::encode_spawn_tab(
                    &session_id(1).bytes(),
                    &pane(byte).bytes(),
                    NewTabPosition::End,
                    "",
                ),
                &topology,
            );
            let Some(tab) = topology.tree.location_of(pane(byte)).map(|(_, tab)| tab) else {
                panic!("the spawned pane has a tab");
            };
            topology = applied(
                WorkspaceIntentOp::CloseTab,
                &intent::encode_identity(&tab.bytes()),
                &topology,
            );
        }
        assert_eq!(topology.closed_tabs.len(), super::CLOSED_TAB_RING_CAP);
    }

    #[test]
    fn a_proposed_id_still_alive_on_the_reopen_ring_is_not_free() {
        let two_tabs = applied(
            WorkspaceIntentOp::SpawnTab,
            &intent::encode_spawn_tab(&session_id(1).bytes(), &pane(2).bytes(), NewTabPosition::End, ""),
            &one_pane(),
        );
        let Some(tab) = two_tabs.tree.location_of(pane(2)).map(|(_, tab)| tab) else {
            panic!("the spawned pane has a tab");
        };
        let closed = applied(
            WorkspaceIntentOp::CloseTab,
            &intent::encode_identity(&tab.bytes()),
            &two_tabs,
        );
        assert_eq!(
            run(
                WorkspaceIntentOp::SplitPane,
                &intent::encode_split(
                    &pane(1).bytes(),
                    SplitAxis::Horizontal,
                    false,
                    &pane(2).bytes(),
                    ""
                ),
                &closed,
            ),
            IntentOutcome::RejectedInvalid,
            "those panes are still alive behind the ring",
        );
    }

    #[test]
    fn the_tree_op_and_the_intent_agree_on_what_a_split_does() {
        let mut counter = ids();
        let direct = tree_ops::split_pane(
            &one_pane().tree,
            pane(1),
            SplitAxis::Horizontal,
            PaneSpec::new(PaneKind::Terminal, "Terminal"),
            false,
            pane(2),
            &mut counter,
        );
        let through = two_panes();
        assert_eq!(
            through.tree.all_pane_ids(),
            direct.all_pane_ids(),
            "the client's overlay and the host's document must not drift",
        );
    }
}
