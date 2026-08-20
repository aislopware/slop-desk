//! The half of the document an INTENT writes and a host restart restores.
//!
//! The split that matters is topology vs liveness. Liveness ([`super::PaneLiveness`]) is derived
//! from a running process and republished on every host start — restoring it would render a pane
//! whose child is long gone as fake-live. Topology is what the person ARRANGED, and losing it is
//! losing the workspace, so it is the persisted half and the half an intent may change.
//!
//! It wraps [`TreeWorkspace`] rather than re-modelling it, because the intent ops map onto the pure
//! tree operations that already work on that value. What it ADDS are the four facts that live
//! host-side and that the tree has never held: they used to live in the client store, where two
//! clients computing them independently is exactly the divergence this document exists to end.
//!
//! ## Why this is in the WIRE crate
//!
//! Every function here is a projection between a domain value and document cells, and the cells are
//! this crate's. The domain crate stays a leaf with no dependencies — the arrow points this way, so
//! nothing in the layout engine has to know a document exists.
//!
//! ## Validate-then-drop, throughout
//!
//! These bytes reached a client over the network. Every structural claim they make is checked
//! against what is actually present rather than trusted: a tab named in `session/tabOrder` with no
//! `layoutStructure` is SKIPPED, never defaulted, because a fabricated empty tab is a phantom every
//! client would then render.

use std::collections::{BTreeMap, BTreeSet};

use slopdesk_workspace::identity::{PaneId, SessionId, SplitNodeId, TabId};
use slopdesk_workspace::session::{DetachedPane, PaneSpec, Session, Tab};
use slopdesk_workspace::split_tree::{SplitNode, SplitWeight, WeightedChild};
use slopdesk_workspace::tab_ordering;
use slopdesk_workspace::workspace::{DEFAULT_PANE_TITLE, TreeWorkspace};

use super::codec::{self, WorkspaceLayoutNode};
use super::fields::{pane, root, session as session_field, split_node, tab as tab_field};
use super::liveness::TOPOLOGY_FIELDS;
use super::state::{HostWorkspaceState, WorkspaceEntry, WorkspaceKey, WorkspaceObjectKind};
use crate::message::RawUuid;

/// The reopen ring's cap.
///
/// A ring that grew without bound would keep every pane the person ever closed alive in the
/// document, on every client, forever.
pub const CLOSED_TAB_RING_CAP: usize = 25;

/// The focus ring's cap. A handful of switches back is all the close path can meaningfully use, and
/// the ring rides in every snapshot.
pub const FOCUS_MRU_CAP: usize = 16;

/// The `root` fields reserved for config that does not cross.
///
/// State the document deliberately does not carry, named as a value rather than left implicit — a
/// silently-dropped field is the failure mode this whole document exists to end. The preset
/// library, the latched video modes and the committed connection target are DEVICE-local: the tree
/// is the layout, and the layout is identical on every attached client, while a 27″ display and a
/// phone must not share an immersive-mode latch.
///
/// Treating them as topology would make every [`write_topology`] DELETE whatever a future build had
/// put there.
pub const RESERVED_ROOT_FIELDS: [u8; 3] = [
    root::LAYOUT_PRESETS,
    root::LAUNCH_PRESETS,
    root::SESSION_TEMPLATES,
];

/// One tab the person closed, kept whole so the reopen gesture can put it back.
#[derive(Debug, Clone, PartialEq)]
pub struct ClosedTab {
    /// The session it belonged to. Its `tab/sessionID` back-pointer is what identifies it as closed
    /// rather than orphaned, and where the reopen puts it.
    pub session_id: SessionId,
    /// The tab itself, split tree and all.
    pub tab: Tab,
    /// Its panes' specs — the only surviving copy once the tab left its session.
    pub specs: BTreeMap<PaneId, PaneSpec>,
}

/// The arrangement, plus the four facts the tree has never held.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkspaceTopology {
    /// The arrangement itself — sessions, tabs, split trees, per-pane specs.
    pub tree: TreeWorkspace,
    /// Tabs with sync-input armed. tmux models `synchronize-panes` as a server-side WINDOW option,
    /// and it has to be: hosting only the armed bit while fanning client-side would mean client B's
    /// keystrokes silently do not fan.
    pub sync_input_tabs: BTreeSet<TabId>,
    /// Per-session tab MRU, most recent first — the ring a close reads to pick a successor.
    ///
    /// Shared rather than per-client because close IS an intent: two clients computing successors
    /// from two local rings pick two different tabs, and the host's index clamp then reintroduces
    /// the cross-project jump that ring was added to stop.
    pub focus_mru: BTreeMap<SessionId, Vec<TabId>>,
    /// The reopen ring, newest last. A per-client undo stack over shared state is incoherent — the
    /// tab it reopens has panes that live host-side.
    ///
    /// The RECORDS, not just the ids: a [`TabId`] alone cannot rebuild a tab, and the reopen has to
    /// put back the split tree and every pane's spec. They ride in the document as ordinary
    /// `tab/*`, `splitNode/*` and `pane/*` entries — a closed tab is exactly a tab whose
    /// `tab/sessionID` names a session that does not list it in `tabOrder` — so this costs no
    /// new grammar, only the rule that the reaper must leave them alone.
    pub closed_tabs: Vec<ClosedTab>,
    /// The host-owned session that parents panes with no client — the ones a `ctl` verb spawned.
    /// Without it the host has two disagreeing pane inventories.
    pub unattached_session_id: Option<SessionId>,
    /// What this host calls itself, so a client can label the workspace it is looking at.
    pub host_display_name: String,
    /// Where a pane's shell was asked to start, keyed by pane.
    ///
    /// Distinct from `pane/cwd`, which is where the shell IS: a respawn after a host restart has no
    /// live shell to ask, and starting it at the last-observed cwd would silently relocate a pane
    /// the person placed deliberately.
    pub spawn_cwd: BTreeMap<PaneId, String>,
}

impl WorkspaceTopology {
    /// A topology over a tree, with nothing else set.
    #[must_use]
    pub const fn new(tree: TreeWorkspace) -> Self {
        Self {
            tree,
            sync_input_tabs: BTreeSet::new(),
            focus_mru: BTreeMap::new(),
            closed_tabs: Vec::new(),
            unattached_session_id: None,
            host_display_name: String::new(),
            spawn_cwd: BTreeMap::new(),
        }
    }

    /// The reopen ring as ids — what `root/closedTabRing` carries.
    #[must_use]
    pub fn closed_tab_ring(&self) -> Vec<TabId> {
        self.closed_tabs.iter().map(|closed| closed.tab.id).collect()
    }

    /// This topology as document entries, in no particular order — [`HostWorkspaceState`] sorts.
    ///
    /// The spec walk is over a [`BTreeMap`], so panes come out in UUID byte order. Swift sorted by
    /// the uuid STRING to defeat dictionary randomization; the two orders are the same one, because
    /// the canonical string is those bytes in hex — the difference is that here it is a property of
    /// the container rather than a sort a future edit could forget.
    #[must_use]
    pub fn entries(&self) -> Vec<WorkspaceEntry> {
        let mut out = Vec::new();
        self.append_root(&mut out);
        for session in &self.tree.sessions {
            self.append_session(session, &mut out);
            for tab in &session.tabs {
                self.append_tab(tab, session.id, &mut out);
                append_weights(&tab.root, &mut out);
            }
            for (id, spec) in &session.specs {
                self.append_pane(*id, spec, &mut out);
            }
        }
        // A closed tab is a tab no session lists. It rides as the same entries a live one does — the
        // ring names it, and its `tab/sessionID` says where it goes back.
        for closed in &self.closed_tabs {
            self.append_tab(&closed.tab, closed.session_id, &mut out);
            append_weights(&closed.tab.root, &mut out);
            for (id, spec) in &closed.specs {
                self.append_pane(*id, spec, &mut out);
            }
        }
        out
    }

    fn append_root(&self, out: &mut Vec<WorkspaceEntry>) {
        let ids: Vec<RawUuid> = self
            .tree
            .sessions
            .iter()
            .map(|session| session.id.bytes())
            .collect();
        out.push(WorkspaceEntry::new(
            WorkspaceKey::root(root::SESSION_ORDER),
            codec::encode_uuid_list(&ids),
        ));
        let ring: Vec<RawUuid> = self.closed_tab_ring().into_iter().map(TabId::bytes).collect();
        out.push(WorkspaceEntry::new(
            WorkspaceKey::root(root::CLOSED_TAB_RING),
            codec::encode_uuid_list(&ring),
        ));
        out.push(WorkspaceEntry::new(
            WorkspaceKey::root(root::HOST_DISPLAY_NAME),
            codec::encode_string(&self.host_display_name, codec::MAX_STRING_BYTES),
        ));
        if let Some(active) = self.tree.active_session_id {
            out.push(WorkspaceEntry::new(
                WorkspaceKey::root(root::ACTIVE_SESSION_ID),
                codec::encode_uuid(&active.bytes()),
            ));
        }
        if let Some(unattached) = self.unattached_session_id {
            out.push(WorkspaceEntry::new(
                WorkspaceKey::root(root::UNATTACHED_SESSION_ID),
                codec::encode_uuid(&unattached.bytes()),
            ));
        }
    }

    fn append_session(&self, session: &Session, out: &mut Vec<WorkspaceEntry>) {
        let key = |field: u8| WorkspaceKey::of(WorkspaceObjectKind::Session, session.id.bytes(), field);
        out.push(WorkspaceEntry::new(
            key(session_field::NAME),
            codec::encode_string(&session.name, codec::MAX_STRING_BYTES),
        ));
        let tabs: Vec<RawUuid> = session.tabs.iter().map(|tab| tab.id.bytes()).collect();
        out.push(WorkspaceEntry::new(
            key(session_field::TAB_ORDER),
            codec::encode_uuid_list(&tabs),
        ));
        let detached: Vec<(RawUuid, Option<RawUuid>)> = session
            .detached
            .iter()
            .map(|entry| (entry.pane.bytes(), entry.origin_tab.map(TabId::bytes)))
            .collect();
        out.push(WorkspaceEntry::new(
            key(session_field::DETACHED_PANES),
            codec::encode_detached_panes(&detached),
        ));
        let mru: Vec<RawUuid> = self
            .focus_mru
            .get(&session.id)
            .map(|ids| ids.iter().map(|id| id.bytes()).collect())
            .unwrap_or_default();
        out.push(WorkspaceEntry::new(
            key(session_field::FOCUS_MRU),
            codec::encode_uuid_list(&mru),
        ));
        // The ACTIVE TAB rides as an id, never the index it is stored as. Indices are exactly what
        // broke before: two clients reordering tabs make the same integer name two different tabs,
        // and nothing on the wire can tell.
        if let Some(active) = session.tabs.get(session.active_tab_index) {
            out.push(WorkspaceEntry::new(
                key(session_field::ACTIVE_TAB_ID),
                codec::encode_uuid(&active.id.bytes()),
            ));
        }
    }

    fn append_tab(&self, tab: &Tab, session_id: SessionId, out: &mut Vec<WorkspaceEntry>) {
        let key = |field: u8| WorkspaceKey::of(WorkspaceObjectKind::Tab, tab.id.bytes(), field);
        out.push(WorkspaceEntry::new(
            key(tab_field::TITLE),
            codec::encode_string(&tab.title, codec::MAX_STRING_BYTES),
        ));
        out.push(WorkspaceEntry::new(
            key(tab_field::SESSION_ID),
            codec::encode_uuid(&session_id.bytes()),
        ));
        out.push(WorkspaceEntry::new(
            key(tab_field::LAYOUT_STRUCTURE),
            codec::encode_layout(&layout_of(&tab.root)),
        ));
        if let Some(active) = tab.active_pane {
            out.push(WorkspaceEntry::new(
                key(tab_field::ACTIVE_PANE_ID),
                codec::encode_uuid(&active.bytes()),
            ));
        }
        if let Some(zoomed) = tab.zoomed_pane {
            out.push(WorkspaceEntry::new(
                key(tab_field::ZOOMED_PANE_ID),
                codec::encode_uuid(&zoomed.bytes()),
            ));
        }
        // Written only when ARMED. A default that is also the absent value keeps the default
        // document small, and a missing bool already reads as `false`.
        if self.sync_input_tabs.contains(&tab.id) {
            out.push(WorkspaceEntry::new(
                key(tab_field::SYNC_INPUT_ARMED),
                codec::encode_bool(true),
            ));
        }
    }

    fn append_pane(&self, id: PaneId, spec: &PaneSpec, out: &mut Vec<WorkspaceEntry>) {
        let key = |field: u8| WorkspaceKey::of(WorkspaceObjectKind::Pane, id.bytes(), field);
        out.push(WorkspaceEntry::new(
            key(pane::KIND),
            codec::encode_u8(spec.kind.as_byte()),
        ));
        out.push(WorkspaceEntry::new(
            key(pane::TITLE),
            codec::encode_string(&spec.title, codec::MAX_STRING_BYTES),
        ));
        if spec.user_renamed {
            out.push(WorkspaceEntry::new(
                key(pane::USER_RENAMED),
                codec::encode_bool(true),
            ));
        }
        if let Some(video) = spec.video.as_ref() {
            out.push(WorkspaceEntry::new(
                key(pane::VIDEO_TARGET),
                codec::encode_video_target(video),
            ));
        }
        if let Some(cwd) = self.spawn_cwd.get(&id) {
            out.push(WorkspaceEntry::new(
                key(pane::SPAWN_CWD),
                codec::encode_string(cwd, codec::MAX_STRING_BYTES),
            ));
        }
    }

    /// Rebuilds a topology from a document, or `None` when there is no workspace in it.
    ///
    /// `None` means `root/sessionOrder` named no session that has a usable tab. That is the "I have
    /// no document" answer, distinct from an empty-but-real workspace, which cannot exist: the host
    /// mints a default rather than publishing nothing.
    #[must_use]
    pub fn from_document(state: &HostWorkspaceState) -> Option<Self> {
        let session_ids = state.uuid_list(&WorkspaceKey::root(root::SESSION_ORDER))?;
        let sessions: Vec<Session> = session_ids
            .into_iter()
            .filter_map(|raw| read_session(SessionId::from_bytes(raw), state))
            .collect();
        if sessions.is_empty() {
            return None;
        }

        let mut focus_mru = BTreeMap::new();
        let mut sync_input_tabs = BTreeSet::new();
        let mut spawn_cwd = BTreeMap::new();
        let mut live = BTreeSet::new();
        for session in &sessions {
            let key = WorkspaceKey::of(
                WorkspaceObjectKind::Session,
                session.id.bytes(),
                session_field::FOCUS_MRU,
            );
            if let Some(ids) = state.uuid_list(&key)
                && !ids.is_empty()
            {
                focus_mru.insert(session.id, ids.into_iter().map(TabId::from_bytes).collect());
            }
            for tab in &session.tabs {
                live.insert(tab.id);
                let armed = WorkspaceKey::of(
                    WorkspaceObjectKind::Tab,
                    tab.id.bytes(),
                    tab_field::SYNC_INPUT_ARMED,
                );
                if state.bool(&armed) {
                    sync_input_tabs.insert(tab.id);
                }
            }
            for id in session.specs.keys() {
                if let Some(cwd) = read_spawn_cwd(*id, state) {
                    spawn_cwd.insert(*id, cwd);
                }
            }
        }

        // A closed tab is one the ring names that no session lists. A ring entry that IS live is
        // dropped rather than duplicated — one tab cannot be both open and reopenable, and rendering
        // it twice is worse than losing one undo step.
        let ring = state
            .uuid_list(&WorkspaceKey::root(root::CLOSED_TAB_RING))
            .unwrap_or_default();
        let mut closed_tabs = Vec::new();
        for tab_id in ring.into_iter().map(TabId::from_bytes) {
            if live.contains(&tab_id) {
                continue;
            }
            // The owner may be GONE — a session emptied by closing its last tab takes its id with
            // it, while the tabs it lost are still reopenable and still carry the only copy of their
            // panes' specs. So the back-pointer must be PRESENT (it says which session to prefer)
            // but need not still resolve; the reopen falls back to the active session for one that
            // does not.
            let Some(tab) = read_tab(tab_id, state) else {
                continue;
            };
            let owner_key = WorkspaceKey::of(WorkspaceObjectKind::Tab, tab_id.bytes(), tab_field::SESSION_ID);
            let Some(owner) = state.uuid(&owner_key).map(SessionId::from_bytes) else {
                continue;
            };
            let mut specs = BTreeMap::new();
            for pane_id in tab.all_pane_ids() {
                specs.insert(pane_id, read_spec(pane_id, state));
                if let Some(cwd) = read_spawn_cwd(pane_id, state) {
                    spawn_cwd.insert(pane_id, cwd);
                }
            }
            closed_tabs.push(ClosedTab {
                session_id: owner,
                tab,
                specs,
            });
        }

        let active = state
            .uuid(&WorkspaceKey::root(root::ACTIVE_SESSION_ID))
            .map(SessionId::from_bytes);
        Some(Self {
            tree: TreeWorkspace::new(sessions, active),
            sync_input_tabs,
            focus_mru,
            closed_tabs,
            unattached_session_id: state
                .uuid(&WorkspaceKey::root(root::UNATTACHED_SESSION_ID))
                .map(SessionId::from_bytes),
            host_display_name: state
                .string(&WorkspaceKey::root(root::HOST_DISPLAY_NAME))
                .unwrap_or_default(),
            spawn_cwd,
        })
    }
}

/// The tab's shape with weights stripped.
///
/// They ride as their own `splitNode/weight` entries, so a divider drag rewrites one small cell
/// instead of the whole structure.
#[must_use]
pub fn layout_of(node: &SplitNode) -> WorkspaceLayoutNode {
    match node {
        SplitNode::Leaf(id) => WorkspaceLayoutNode::Leaf(id.bytes()),
        SplitNode::Split { id, axis, children } => {
            WorkspaceLayoutNode::Split {
                id: id.bytes(),
                axis: *axis,
                children: children.iter().map(|child| layout_of(&child.node)).collect(),
            }
        },
    }
}

fn append_weights(node: &SplitNode, out: &mut Vec<WorkspaceEntry>) {
    let SplitNode::Split { id, children, .. } = node else {
        return;
    };
    let weights: Vec<SplitWeight> = children.iter().map(|child| child.weight).collect();
    out.push(WorkspaceEntry::new(
        WorkspaceKey::of(WorkspaceObjectKind::SplitNode, id.bytes(), split_node::WEIGHT),
        codec::encode_weights(&weights),
    ));
    for child in children {
        append_weights(&child.node, out);
    }
}

fn read_session(id: SessionId, state: &HostWorkspaceState) -> Option<Session> {
    let order_key = WorkspaceKey::of(WorkspaceObjectKind::Session, id.bytes(), session_field::TAB_ORDER);
    let tab_ids = state.uuid_list(&order_key).unwrap_or_default();
    let mut tabs = Vec::new();
    let mut specs = BTreeMap::new();
    for tab_id in tab_ids.into_iter().map(TabId::from_bytes) {
        let Some(tab) = read_tab(tab_id, state) else {
            continue;
        };
        for pane_id in tab.all_pane_ids() {
            specs.insert(pane_id, read_spec(pane_id, state));
        }
        tabs.push(tab);
    }
    // A session with no usable tab is not a session. Minting one would invent a workspace the host
    // never published — the opposite of the point.
    if tabs.is_empty() {
        return None;
    }

    let detached_key = WorkspaceKey::of(
        WorkspaceObjectKind::Session,
        id.bytes(),
        session_field::DETACHED_PANES,
    );
    let mut detached = Vec::new();
    for (raw_pane, raw_origin) in state.detached_panes(&detached_key).unwrap_or_default() {
        let pane_id = PaneId::from_bytes(raw_pane);
        // A detached pane that is ALSO a tree leaf would break the specs invariant in both
        // directions at once. Tree membership wins, matching the tree's own repair.
        if specs.contains_key(&pane_id) {
            continue;
        }
        specs.insert(pane_id, read_spec(pane_id, state));
        detached.push(DetachedPane {
            pane: pane_id,
            origin_tab: raw_origin.map(TabId::from_bytes),
        });
    }

    // The active tab arrives as an IDENTITY and becomes an index here — the one place the conversion
    // happens, so a reorder on another client can never leave this one pointing at a position that
    // has since become a different tab.
    let active_key = WorkspaceKey::of(
        WorkspaceObjectKind::Session,
        id.bytes(),
        session_field::ACTIVE_TAB_ID,
    );
    let active_tab_index = state
        .uuid(&active_key)
        .and_then(|raw| tabs.iter().position(|tab| tab.id.bytes() == raw))
        .unwrap_or(0);
    let name_key = WorkspaceKey::of(WorkspaceObjectKind::Session, id.bytes(), session_field::NAME);
    Some(Session {
        id,
        name: state.string(&name_key).unwrap_or_default(),
        tabs,
        active_tab_index,
        specs,
        detached,
    })
}

fn read_tab(id: TabId, state: &HostWorkspaceState) -> Option<Tab> {
    let layout_key = WorkspaceKey::of(WorkspaceObjectKind::Tab, id.bytes(), tab_field::LAYOUT_STRUCTURE);
    let layout = codec::decode_layout(state.get(&layout_key)?).ok()?;
    let root = read_split_node(&layout, state);
    let leaves: BTreeSet<PaneId> = root.all_pane_ids().into_iter().collect();
    let pane_at = |field: u8| {
        state
            .uuid(&WorkspaceKey::of(WorkspaceObjectKind::Tab, id.bytes(), field))
            .map(PaneId::from_bytes)
            .filter(|pane_id| leaves.contains(pane_id))
    };
    let title_key = WorkspaceKey::of(WorkspaceObjectKind::Tab, id.bytes(), tab_field::TITLE);
    Some(Tab {
        id,
        title: state.string(&title_key).unwrap_or_default(),
        // A focus or zoom naming a pane this tab does not contain is dropped rather than rendered:
        // the tree's own repair would fix it anyway, and repairing here keeps the value usable
        // without a normalization pass the host may not run.
        active_pane: pane_at(tab_field::ACTIVE_PANE_ID).or_else(|| root.first_leaf_id()),
        zoomed_pane: pane_at(tab_field::ZOOMED_PANE_ID),
        root,
    })
}

/// Re-weaves the stripped weights back into the shape.
///
/// A split whose weight entry is missing, wrong-width, or the wrong ARITY falls back to an even
/// flex share. That is not a guess: `Flex(1)` across N children is exactly the layout solver's
/// default, so a lost weight cell degrades to an evenly split tab rather than a mis-sized one.
///
/// The recursion is bounded by the decoder, which refuses a layout nested past
/// [`codec::MAX_LAYOUT_DEPTH`] — this walk cannot be handed a deeper one.
fn read_split_node(node: &WorkspaceLayoutNode, state: &HostWorkspaceState) -> SplitNode {
    match node {
        WorkspaceLayoutNode::Leaf(id) => SplitNode::Leaf(PaneId::from_bytes(*id)),
        WorkspaceLayoutNode::Split { id, axis, children } => {
            let key = WorkspaceKey::of(WorkspaceObjectKind::SplitNode, *id, split_node::WEIGHT);
            let stored = state
                .get(&key)
                .and_then(codec::decode_weights)
                .filter(|weights| weights.len() == children.len());
            SplitNode::Split {
                id: SplitNodeId::from_bytes(*id),
                axis: *axis,
                children: children
                    .iter()
                    .enumerate()
                    .map(|(index, child)| {
                        // Repaired, not trusted: a hostile file can carry NaN or zero, and a weight
                        // of zero starves a pane to nothing.
                        let weight = stored
                            .as_ref()
                            .and_then(|weights| weights.get(index).copied())
                            .unwrap_or_default();
                        WeightedChild::new(weight.repaired(), read_split_node(child, state))
                    })
                    .collect(),
            }
        },
    }
}

fn read_spec(id: PaneId, state: &HostWorkspaceState) -> PaneSpec {
    let key = |field: u8| WorkspaceKey::of(WorkspaceObjectKind::Pane, id.bytes(), field);
    let kind_byte = state
        .get(&key(pane::KIND))
        .and_then(codec::decode_u8)
        .unwrap_or(0);
    PaneSpec {
        kind: slopdesk_workspace::PaneKind::from_byte(kind_byte),
        title: state
            .string(&key(pane::TITLE))
            .unwrap_or_else(|| DEFAULT_PANE_TITLE.to_owned()),
        video: state
            .get(&key(pane::VIDEO_TARGET))
            .and_then(codec::decode_video_target),
        user_renamed: state.bool(&key(pane::USER_RENAMED)),
    }
}

fn read_spawn_cwd(id: PaneId, state: &HostWorkspaceState) -> Option<String> {
    state.string(&WorkspaceKey::of(
        WorkspaceObjectKind::Pane,
        id.bytes(),
        pane::SPAWN_CWD,
    ))
}

/// Whether a key belongs to the topology half — the half an intent writes and a restart restores.
///
/// Pane keys split by FIELD, which is the whole reason this predicate exists: a pane's `title` is
/// topology and its `liveTitle` is not, and they live one byte apart under the same object id.
#[must_use]
pub fn is_topology(key: &WorkspaceKey) -> bool {
    match WorkspaceObjectKind::from_byte(key.kind) {
        Some(WorkspaceObjectKind::Root) => !RESERVED_ROOT_FIELDS.contains(&key.field),
        Some(WorkspaceObjectKind::Session | WorkspaceObjectKind::Tab | WorkspaceObjectKind::SplitNode) => {
            true
        },
        Some(WorkspaceObjectKind::Pane) => TOPOLOGY_FIELDS.contains(&key.field),
        // A project's git summary is derived, and an unknown kind from a newer host is not ours to
        // reap — dropping it would make this client's entries stop matching its own ack.
        Some(WorkspaceObjectKind::Project) | None => false,
    }
}

/// Replaces the topology half wholesale, leaving liveness and projects untouched.
///
/// Wholesale rather than incremental because a topology write must be able to REMOVE: closing a tab
/// has to take `tab/*` with it, and an incremental merge would leave the closed tab in the document
/// forever, rendered by every client.
pub fn write_topology(state: &mut HostWorkspaceState, topology: &WorkspaceTopology) {
    let next = topology.entries();
    let supplied: BTreeSet<WorkspaceKey> = next.iter().map(|entry| entry.key).collect();
    for key in state.keys() {
        if is_topology(&key) && !supplied.contains(&key) {
            state.set_or_clear(key, None);
        }
    }
    for entry in next {
        state.set(entry.key, entry.value);
    }
}

impl HostWorkspaceState {
    /// One cell as a string, or `None` when it is absent or not a string.
    #[must_use]
    pub fn string(&self, key: &WorkspaceKey) -> Option<String> {
        self.get(key).and_then(codec::decode_string)
    }

    /// One cell as a bool. An absent or malformed cell is `false` — the document's defaults are
    /// chosen so that absence IS the default, which is what keeps a fresh document small.
    #[must_use]
    pub fn bool(&self, key: &WorkspaceKey) -> bool {
        self.get(key).and_then(codec::decode_bool).unwrap_or(false)
    }

    /// One cell as a UUID.
    #[must_use]
    pub fn uuid(&self, key: &WorkspaceKey) -> Option<RawUuid> {
        self.get(key).and_then(codec::decode_uuid)
    }

    /// One cell as a UUID list.
    #[must_use]
    pub fn uuid_list(&self, key: &WorkspaceKey) -> Option<Vec<RawUuid>> {
        self.get(key).and_then(codec::decode_uuid_list)
    }

    /// One cell as detached-pane records: each pane and the tab it came from.
    #[must_use]
    pub fn detached_panes(&self, key: &WorkspaceKey) -> Option<Vec<(RawUuid, Option<RawUuid>)>> {
        self.get(key).and_then(codec::decode_detached_panes)
    }

    /// Pane `id`'s resolved by-project key, read from this document's own cells: `pane/projectKey`
    /// (the host's git-toplevel verdict), else `pane/cwd`, under the shared plugin-cwd guards.
    ///
    /// Defined once here so the host document, the loopback and a client's optimistic overlay all
    /// read the same two cells in the same order — three transcriptions of a precedence is three
    /// ways to pick a different tab.
    #[must_use]
    pub fn project_key_for_pane(&self, id: PaneId) -> Option<String> {
        tab_ordering::pane_project_key(
            id,
            |pane_id| {
                self.string(&WorkspaceKey::of(
                    WorkspaceObjectKind::Pane,
                    pane_id.bytes(),
                    pane::PROJECT_KEY,
                ))
            },
            |pane_id| {
                self.string(&WorkspaceKey::of(
                    WorkspaceObjectKind::Pane,
                    pane_id.bytes(),
                    pane::CWD,
                ))
            },
        )
    }

    /// The topology half as a value, or `None` when this document carries no workspace.
    #[must_use]
    pub fn topology(&self) -> Option<WorkspaceTopology> {
        WorkspaceTopology::from_document(self)
    }
}

/// The MALFORMED half of this module is pinned ACROSS THE LANGUAGES, not here.
///
/// `Tests/SlopDeskWorkspaceModelTests/WorkspaceTopologyIngestionDifferentialTests.swift` feeds one
/// corpus of degenerate documents to Swift's `WorkspaceTopology.init(entries:)` and to
/// [`WorkspaceTopology::from_document`] through `slopdesk_ws_apply_intent`, and asserts they land
/// on the same cells. Four tests that used to sit below — a tab with no layout, a focus naming an
/// absent pane, a weight cell of the wrong arity, a starving weight — were the crate's half of a
/// MIRROR FIXTURE: the same input written twice in two languages, which is the shape `CLAUDE.md`
/// bans and `docs/55` §8 records as the way every cross-language bug here has been born. Their
/// absolute assertions survive on the Swift side, where the value is the one a person sees; what
/// this file owes is that the two readings agree, and a differential is the only thing that can say
/// so. Re-adding one here re-creates the pair.
#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing session or tab is a test failure with nothing to return"
    )]

    use std::collections::{BTreeMap, BTreeSet};

    use slopdesk_workspace::identity::{PaneId, SessionId, SplitNodeId, TabId};
    use slopdesk_workspace::session::{DetachedPane, PaneKind, PaneSpec, Tab};
    use slopdesk_workspace::split_tree::{SplitAxis, SplitNode, SplitWeight, WeightedChild};
    use slopdesk_workspace::workspace::TreeWorkspace;

    use super::super::codec;
    use super::super::fields::{pane, project, root, tab as tab_field};
    use super::super::liveness::{LIVENESS_FIELDS, TOPOLOGY_FIELDS};
    use super::super::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};
    use super::{
        CLOSED_TAB_RING_CAP, ClosedTab, FOCUS_MRU_CAP, RESERVED_ROOT_FIELDS, WorkspaceTopology, is_topology,
        write_topology,
    };

    fn pane_id(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn tab_id(byte: u8) -> TabId {
        TabId::from_bytes([byte; 16])
    }

    fn session_id(byte: u8) -> SessionId {
        SessionId::from_bytes([byte; 16])
    }

    fn document(topology: &WorkspaceTopology) -> HostWorkspaceState {
        HostWorkspaceState::from_entries(topology.entries())
    }

    fn one_pane() -> WorkspaceTopology {
        WorkspaceTopology::new(TreeWorkspace::single_pane(
            session_id(1),
            tab_id(1),
            pane_id(1),
            PaneSpec::new(PaneKind::Terminal, "Terminal"),
        ))
    }

    fn split_tab() -> WorkspaceTopology {
        let root = SplitNode::Split {
            id: SplitNodeId::from_bytes([9; 16]),
            axis: SplitAxis::Vertical,
            children: vec![
                WeightedChild::new(SplitWeight::Flex(2.0), SplitNode::Leaf(pane_id(1))),
                WeightedChild::new(SplitWeight::Flex(3.0), SplitNode::Leaf(pane_id(2))),
            ],
        };
        let mut topology = one_pane();
        let Some(session) = topology.tree.sessions.first_mut() else {
            panic!("one session");
        };
        session
            .specs
            .insert(pane_id(2), PaneSpec::new(PaneKind::Terminal, "Two"));
        let Some(tab) = session.tabs.first_mut() else {
            panic!("one tab");
        };
        tab.root = root;
        tab.active_pane = Some(pane_id(2));
        topology
    }

    #[test]
    fn a_workspace_survives_the_round_trip_whole() {
        let mut before = split_tab();
        before.host_display_name = "studio".to_owned();
        before.sync_input_tabs.insert(tab_id(1));
        before.focus_mru.insert(session_id(1), vec![tab_id(1)]);
        before.unattached_session_id = Some(session_id(7));
        before.spawn_cwd.insert(pane_id(1), "/tmp/work".to_owned());
        let Some(after) = document(&before).topology() else {
            panic!("a document with a session decodes");
        };
        assert_eq!(after, before);
    }

    #[test]
    fn a_divider_weight_rides_as_its_own_cell_and_comes_back() {
        let before = split_tab();
        let Some(after) = document(&before).topology() else {
            panic!("a document with a session decodes");
        };
        let Some(SplitNode::Split { children, .. }) = after
            .tree
            .sessions
            .first()
            .and_then(|s| s.tabs.first())
            .map(|t| &t.root)
        else {
            panic!("a split root");
        };
        let weights: Vec<SplitWeight> = children.iter().map(|child| child.weight).collect();
        assert_eq!(weights, vec![SplitWeight::Flex(2.0), SplitWeight::Flex(3.0)]);
    }

    #[test]
    fn a_document_with_no_session_order_is_no_document() {
        assert!(HostWorkspaceState::new().topology().is_none());
    }

    #[test]
    fn the_active_tab_crosses_as_an_identity_so_a_reorder_cannot_rename_it() {
        let mut before = one_pane();
        let Some(session) = before.tree.sessions.first_mut() else {
            panic!("one session");
        };
        session
            .tabs
            .push(Tab::new(tab_id(2), SplitNode::Leaf(pane_id(2))));
        session
            .specs
            .insert(pane_id(2), PaneSpec::new(PaneKind::Terminal, "Two"));
        session.active_tab_index = 1;
        let state = document(&before);
        let Some(after) = state.topology() else {
            panic!("a document with a session decodes");
        };
        let Some(session) = after.tree.sessions.first() else {
            panic!("one session");
        };
        assert_eq!(session.active_tab_index, 1);
        assert_eq!(session.tabs.get(1).map(|tab| tab.id), Some(tab_id(2)));
    }

    #[test]
    fn a_detached_pane_crosses_with_the_tab_it_came_from() {
        let mut before = one_pane();
        let Some(session) = before.tree.sessions.first_mut() else {
            panic!("one session");
        };
        session
            .specs
            .insert(pane_id(70), PaneSpec::new(PaneKind::Terminal, "Floating"));
        session.detached.push(DetachedPane {
            pane: pane_id(70),
            origin_tab: Some(tab_id(1)),
        });
        let Some(after) = document(&before).topology() else {
            panic!("a document with a session decodes");
        };
        assert_eq!(after.tree.detached_pane_ids(), vec![pane_id(70)]);
        assert_eq!(
            after.tree.spec_for(pane_id(70)).map(|spec| spec.title.clone()),
            Some("Floating".to_owned()),
        );
    }

    #[test]
    fn a_closed_tab_rides_as_ordinary_entries_and_comes_back_whole() {
        let mut before = one_pane();
        let mut specs = BTreeMap::new();
        specs.insert(pane_id(50), PaneSpec::new(PaneKind::Terminal, "Closed"));
        before.closed_tabs.push(ClosedTab {
            session_id: session_id(1),
            tab: Tab::new(tab_id(9), SplitNode::Leaf(pane_id(50))),
            specs,
        });
        let Some(after) = document(&before).topology() else {
            panic!("a document with a session decodes");
        };
        assert_eq!(after.closed_tabs.len(), 1);
        assert_eq!(after.closed_tab_ring(), vec![tab_id(9)]);
        assert_eq!(
            after.closed_tabs.first().map(|closed| closed.session_id),
            Some(session_id(1)),
        );
        assert!(
            !after.tree.contains(pane_id(50)),
            "a closed tab's pane is not in any session's tree",
        );
    }

    #[test]
    fn a_ring_entry_that_is_still_live_is_dropped_rather_than_duplicated() {
        let mut state = document(&one_pane());
        state.set(
            WorkspaceKey::root(root::CLOSED_TAB_RING),
            codec::encode_uuid_list(&[tab_id(1).bytes()]),
        );
        let Some(after) = state.topology() else {
            panic!("a document with a session decodes");
        };
        assert!(
            after.closed_tabs.is_empty(),
            "one tab cannot be both open and reopenable",
        );
    }

    #[test]
    fn a_closed_tab_with_no_back_pointer_is_skipped() {
        let mut before = one_pane();
        before.closed_tabs.push(ClosedTab {
            session_id: session_id(1),
            tab: Tab::new(tab_id(9), SplitNode::Leaf(pane_id(50))),
            specs: BTreeMap::new(),
        });
        let mut state = document(&before);
        state.set_or_clear(
            WorkspaceKey::of(WorkspaceObjectKind::Tab, tab_id(9).bytes(), tab_field::SESSION_ID),
            None,
        );
        let Some(after) = state.topology() else {
            panic!("a document with a session decodes");
        };
        assert!(after.closed_tabs.is_empty());
    }

    #[test]
    fn the_topology_predicate_partitions_the_pane_vocabulary() {
        for field in TOPOLOGY_FIELDS {
            assert!(is_topology(&WorkspaceKey::of(
                WorkspaceObjectKind::Pane,
                [1; 16],
                field
            )));
        }
        for field in LIVENESS_FIELDS {
            assert!(!is_topology(&WorkspaceKey::of(
                WorkspaceObjectKind::Pane,
                [1; 16],
                field
            )));
        }
    }

    #[test]
    fn the_reserved_root_fields_are_never_reaped() {
        for field in RESERVED_ROOT_FIELDS {
            assert!(
                !is_topology(&WorkspaceKey::root(field)),
                "a topology write must not delete what a future build put there",
            );
        }
        assert!(is_topology(&WorkspaceKey::root(root::SESSION_ORDER)));
        assert!(!is_topology(&WorkspaceKey::of(
            WorkspaceObjectKind::Project,
            [1; 16],
            0
        )));
        assert!(!is_topology(&WorkspaceKey::new(0xEE, [1; 16], 0)));
    }

    #[test]
    fn a_topology_write_removes_what_the_new_value_no_longer_names() {
        let mut state = document(&split_tab());
        let dropped = WorkspaceKey::of(WorkspaceObjectKind::Pane, pane_id(2).bytes(), pane::TITLE);
        assert!(state.get(&dropped).is_some());
        write_topology(&mut state, &one_pane());
        assert!(
            state.get(&dropped).is_none(),
            "closing a pane has to take its cells with it",
        );
    }

    #[test]
    fn a_topology_write_leaves_liveness_and_projects_alone() {
        let mut state = document(&one_pane());
        let live = WorkspaceKey::of(WorkspaceObjectKind::Pane, pane_id(1).bytes(), pane::LIVE_TITLE);
        let git = WorkspaceKey::of(WorkspaceObjectKind::Project, [4; 16], project::GIT_SUMMARY);
        state.set(live, codec::encode_string("vim", codec::MAX_STRING_BYTES));
        state.set(git, codec::encode_string("main +2", codec::MAX_STRING_BYTES));
        write_topology(&mut state, &split_tab());
        assert!(state.get(&live).is_some());
        assert!(state.get(&git).is_some());
    }

    #[test]
    fn a_project_key_prefers_the_hosts_verdict_over_the_shells_cwd() {
        let mut state = HostWorkspaceState::new();
        let key = |field: u8| WorkspaceKey::of(WorkspaceObjectKind::Pane, pane_id(1).bytes(), field);
        state.set(
            key(pane::CWD),
            codec::encode_string("/work/repo/sub", codec::MAX_STRING_BYTES),
        );
        assert_eq!(
            state.project_key_for_pane(pane_id(1)),
            Some("/work/repo/sub".to_owned()),
        );
        state.set(
            key(pane::PROJECT_KEY),
            codec::encode_string("/work/repo", codec::MAX_STRING_BYTES),
        );
        assert_eq!(
            state.project_key_for_pane(pane_id(1)),
            Some("/work/repo".to_owned())
        );
    }

    #[test]
    fn the_sync_input_bit_is_written_only_when_armed() {
        let plain = document(&one_pane());
        let armed_key = WorkspaceKey::of(
            WorkspaceObjectKind::Tab,
            tab_id(1).bytes(),
            tab_field::SYNC_INPUT_ARMED,
        );
        assert!(plain.get(&armed_key).is_none(), "absence is the default");

        let mut before = one_pane();
        before.sync_input_tabs = BTreeSet::from([tab_id(1)]);
        let Some(after) = document(&before).topology() else {
            panic!("a document with a session decodes");
        };
        assert_eq!(after.sync_input_tabs, BTreeSet::from([tab_id(1)]));
    }

    #[test]
    fn the_caps_are_the_ones_the_close_and_reopen_paths_read() {
        assert_eq!(CLOSED_TAB_RING_CAP, 25);
        assert_eq!(FOCUS_MRU_CAP, 16);
    }
}
