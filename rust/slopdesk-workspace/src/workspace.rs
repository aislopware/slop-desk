//! The whole arrangement: sessions, their tabs, their trees — and the repairs that make a
//! hand-edited file usable.
//!
//! It holds the LAYOUT and nothing device-local. The preset library, the latched video modes and
//! the connection target live with the device, because the layout is identical on every attached
//! client while those describe one machine — a large display and a phone must not share an
//! immersive-mode latch.
//!
//! ## One invariant, checkable
//!
//! For every session, the spec side table's keys are exactly its tree leaves plus its detached
//! panes. [`TreeWorkspace::invariant_holds`] states it, every operation preserves it, and
//! [`TreeWorkspace::normalized`] repairs a file that violates it. It is what lets the rest of the
//! crate look a spec up without asking whether one exists.
//!
//! ## Repair, never reject
//!
//! A persisted workspace is untrusted. Losing it is losing the person's work, so every degenerate
//! shape here has a defined repair rather than an error: an orphan spec is dropped, a spec-less
//! leaf is re-seeded, an out-of-range selection is clamped, an empty workspace is re-seeded from
//! scratch.

use std::collections::BTreeSet;

use crate::identity::{IdSource, PaneId, SessionId, TabId};
use crate::session::{PaneKind, PaneSpec, Session, Tab};
use crate::split_tree::SplitNode;

/// The title a re-seeded pane takes.
pub const DEFAULT_PANE_TITLE: &str = "Terminal";

/// The name a fresh workspace's first session takes.
pub const DEFAULT_SESSION_NAME: &str = "Local";

/// The title a minted desktop pane takes.
///
/// Beside the other two rather than in whichever crate happens to mint one, because a desktop pane
/// gets minted from two directions — a local gesture in the client, and a document the wire crate
/// applies — and those two are the ones that must not disagree. A pane the user made and a pane a
/// restored document made would otherwise be titled differently for no reason the user could see.
pub const DEFAULT_DESKTOP_PANE_TITLE: &str = "Desktop";

/// The schema version this shape writes.
///
/// A file carrying any OTHER version is NOT migrated — the load path sets it aside. The bump is
/// what makes that rule true rather than merely stated: a file from an older shape would otherwise
/// decode "successfully" against the fields this shape still recognises, and the next autosave
/// would rewrite it without whatever the old shape carried — silently, with no copy kept.
pub const CURRENT_SCHEMA_VERSION: i64 = 12;

/// Every session, and which one is selected.
#[derive(Debug, Clone, PartialEq)]
pub struct TreeWorkspace {
    /// The persisted shape's version.
    pub schema_version: i64,
    /// The sessions, in sidebar order.
    pub sessions: Vec<Session>,
    /// The selected session. `None` only transiently, before a repair.
    pub active_session_id: Option<SessionId>,
}

impl TreeWorkspace {
    /// A workspace over these sessions.
    #[must_use]
    pub const fn new(sessions: Vec<Session>, active_session_id: Option<SessionId>) -> Self {
        Self {
            schema_version: CURRENT_SCHEMA_VERSION,
            sessions,
            active_session_id,
        }
    }

    /// A fresh workspace: one session, one tab, one pane carrying a spec.
    #[must_use]
    pub fn single_pane(session: SessionId, tab: TabId, pane: PaneId, spec: PaneSpec) -> Self {
        let session = Session::single_pane(session, DEFAULT_SESSION_NAME, tab, pane, spec);
        let id = session.id;
        Self::new(vec![session], Some(id))
    }

    /// The default workspace: one session holding a single terminal.
    #[must_use]
    pub(crate) fn default_workspace(session: SessionId, tab: TabId, pane: PaneId) -> Self {
        Self::single_pane(
            session,
            tab,
            pane,
            PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE),
        )
    }

    /// Every pane in the trees, in a deterministic order: session order, then tab order, then the
    /// tree's own pre-order.
    ///
    /// DETACHED panes are deliberately excluded — tree membership is what drives focus, zoom and
    /// tab semantics. A caller reconciling live handles unions
    /// [`detached_pane_ids`](Self::detached_pane_ids) in separately, so a detached pane's
    /// process stays alive without its window claiming a slot in a tab.
    #[must_use]
    pub fn all_pane_ids(&self) -> Vec<PaneId> {
        self.sessions.iter().flat_map(Session::all_pane_ids).collect()
    }

    /// Every pane detached into its own window, in session order then detach order.
    #[must_use]
    pub fn detached_pane_ids(&self) -> Vec<PaneId> {
        self.sessions
            .iter()
            .flat_map(|session| session.detached.iter().map(|entry| entry.pane))
            .collect()
    }

    /// Whether a pane is detached in any session.
    #[must_use]
    pub fn is_detached(&self, id: PaneId) -> bool {
        self.sessions.iter().any(|session| session.is_detached(id))
    }

    /// Whether a pane is a tree leaf anywhere.
    #[must_use]
    pub fn contains(&self, id: PaneId) -> bool {
        self.sessions.iter().any(|session| session.contains(id))
    }

    /// A pane's spec, from whichever session owns it.
    #[must_use]
    pub fn spec_for(&self, id: PaneId) -> Option<&PaneSpec> {
        self.sessions.iter().find_map(|session| session.spec_for(id))
    }

    /// The session and tab owning a pane.
    #[must_use]
    pub fn location_of(&self, id: PaneId) -> Option<(SessionId, TabId)> {
        self.sessions.iter().find_map(|session| {
            session
                .tabs
                .iter()
                .find(|tab| tab.contains(id))
                .map(|tab| (session.id, tab.id))
        })
    }

    /// The index of the selected session, under the same fallback.
    #[must_use]
    pub fn active_session_index(&self) -> Option<usize> {
        let Some(id) = self.active_session_id else {
            return (!self.sessions.is_empty()).then_some(0);
        };
        self.sessions
            .iter()
            .position(|session| session.id == id)
            .or_else(|| (!self.sessions.is_empty()).then_some(0))
    }

    /// Whether the spec table matches the panes, in every session.
    ///
    /// The load-bearing property: `specs.keys() == leaves ∪ detached`. Both directions matter — an
    /// orphan spec keeps a dead pane's intent alive, and a spec-less leaf is a pane nothing can
    /// materialize.
    #[must_use]
    pub fn invariant_holds(&self) -> bool {
        self.sessions.iter().all(|session| {
            let expected: BTreeSet<PaneId> = session
                .leaf_id_set()
                .union(&session.detached_id_set())
                .copied()
                .collect();
            session.specs.keys().copied().collect::<BTreeSet<_>>() == expected
        })
    }

    /// The workspace with the spec table repaired against the panes.
    ///
    /// The detached list is repaired FIRST so the spec filter sees a consistent membership. A
    /// detached entry that is also a tree leaf is dropped — tree membership wins, because a pane
    /// cannot be both tiled and floating — as is a duplicate, and as is an entry with no spec: a
    /// spec-less detached record is unrecoverable, unlike a spec-less LEAF, whose place in the tree
    /// is itself the demand for a re-seeded default.
    #[must_use]
    pub(crate) fn normalizing_specs(&self) -> Self {
        let mut next = self.clone();
        for session in &mut next.sessions {
            let leaves = session.leaf_id_set();
            let mut seen = BTreeSet::new();
            session.detached.retain(|entry| {
                !leaves.contains(&entry.pane)
                    && session.specs.contains_key(&entry.pane)
                    && seen.insert(entry.pane)
            });
            let keep: BTreeSet<PaneId> = leaves.union(&session.detached_id_set()).copied().collect();
            session.specs.retain(|id, _| keep.contains(id));
            for id in leaves {
                session
                    .specs
                    .entry(id)
                    .or_insert_with(|| PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE));
            }
        }
        next
    }

    /// The workspace with every selection repaired.
    ///
    /// The workspace always ends with at least one session, each session with at least one tab,
    /// each active index inside its list, and each tab's focus and zoom naming a pane that tab
    /// actually holds. `mint` supplies the ids a re-seed needs — this crate has no entropy —
    /// and is called only when a session has no tab at all.
    #[must_use]
    pub(crate) fn normalizing_active(&self, mint: &mut impl IdSource) -> Self {
        if self.sessions.is_empty() {
            return Self::default_workspace(mint.session(), mint.tab(), mint.pane());
        }
        let mut next = self.clone();
        for session in &mut next.sessions {
            if session.tabs.is_empty() {
                let (tab, pane) = (mint.tab(), mint.pane());
                session
                    .specs
                    .insert(pane, PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE));
                session.tabs.push(Tab::new(tab, SplitNode::Leaf(pane)));
            }
            if session.active_tab_index >= session.tabs.len() {
                session.active_tab_index = 0;
            }
            for tab in &mut session.tabs {
                let leaves: BTreeSet<PaneId> = tab.root.all_pane_ids().into_iter().collect();
                if !tab.active_pane.is_some_and(|pane| leaves.contains(&pane)) {
                    tab.active_pane = tab.root.first_leaf_id();
                }
                if !tab.zoomed_pane.is_some_and(|pane| leaves.contains(&pane)) {
                    tab.zoomed_pane = None;
                }
            }
        }
        let names_a_session = next
            .active_session_id
            .is_some_and(|id| next.sessions.iter().any(|session| session.id == id));
        if !names_a_session {
            next.active_session_id = next.sessions.first().map(|session| session.id);
        }
        next
    }

    /// The repairs in the order a load applies them: specs first, so the selection repair sees a
    /// consistent set of panes.
    ///
    /// It deliberately does NOT re-dock detached panes. This runs after every close and cascade, so
    /// folding a re-dock in would instantly undo a detach the person just performed — re-docking is
    /// a LAUNCH-only step.
    #[must_use]
    pub(crate) fn normalized(&self, mint: &mut impl IdSource) -> Self {
        self.normalizing_specs().normalizing_active(mint)
    }

    /// The workspace without any video pane, in every session.
    ///
    /// A LAUNCH-only step. A remote desktop never restores across a relaunch, so a persisted video
    /// pane — a detached one whose window is gone, or a stale tree leaf from an older file — is
    /// DROPPED rather than re-docked. Its spec goes with it, so nothing later opens a stream for a
    /// pane no window will show.
    #[must_use]
    pub(crate) fn dropping_video_panes(&self) -> Self {
        let mut next = self.clone();
        for session in &mut next.sessions {
            let video: Vec<PaneId> = session
                .specs
                .iter()
                .filter(|(_, spec)| spec.kind.is_video())
                .map(|(id, _)| *id)
                .collect();
            if video.is_empty() {
                continue;
            }
            session.detached.retain(|entry| !video.contains(&entry.pane));
            for id in &video {
                session.specs.remove(id);
            }
            // A tab whose every pane was a video pane has nothing left to show — `removing` reports
            // it by returning `None`. It is dropped rather than re-seeded, because a tab that only
            // ever held a stream is not a place the person put anything.
            session.tabs.retain_mut(|tab| {
                for id in &video {
                    if !tab.root.contains(*id) {
                        continue;
                    }
                    let Some(pruned) = tab.root.removing(*id) else {
                        return false;
                    };
                    tab.root = pruned;
                }
                true
            });
        }
        next
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a missing session is a test failure with nothing to return"
    )]

    use std::collections::BTreeMap;

    use super::{DEFAULT_PANE_TITLE, DEFAULT_SESSION_NAME, TreeWorkspace};
    use crate::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
    use crate::session::{DetachedPane, PaneKind, PaneSpec, Session, Tab};
    use crate::split_tree::{SplitAxis, SplitNode, WeightedChild};

    fn pane(byte: u8) -> PaneId {
        PaneId::from_bytes([byte; 16])
    }

    fn tab_id(byte: u8) -> TabId {
        TabId::from_bytes([byte; 16])
    }

    fn session_id(byte: u8) -> SessionId {
        SessionId::from_bytes([byte; 16])
    }

    fn spec() -> PaneSpec {
        PaneSpec::new(PaneKind::Terminal, DEFAULT_PANE_TITLE)
    }

    /// A counter, so every repair in these tests lands on a predictable id.
    struct Counter(u8);

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

    impl Counter {
        fn step(&mut self) -> u8 {
            self.0 = self.0.wrapping_add(1);
            self.0
        }
    }

    fn minter() -> Counter {
        Counter(200)
    }

    fn one_pane() -> TreeWorkspace {
        TreeWorkspace::single_pane(session_id(1), tab_id(1), pane(1), spec())
    }

    fn two_panes() -> TreeWorkspace {
        let root = SplitNode::Split {
            id: SplitNodeId::from_bytes([9; 16]),
            axis: SplitAxis::Horizontal,
            children: vec![WeightedChild::leaf(pane(1)), WeightedChild::leaf(pane(2))],
        };
        let mut specs = BTreeMap::new();
        specs.insert(pane(1), spec());
        specs.insert(pane(2), spec());
        let session = Session {
            id: session_id(1),
            name: DEFAULT_SESSION_NAME.to_owned(),
            tabs: vec![Tab::new(tab_id(1), root)],
            active_tab_index: 0,
            specs,
            detached: Vec::new(),
        };
        TreeWorkspace::new(vec![session], Some(session_id(1)))
    }

    #[test]
    fn a_fresh_workspace_holds_exactly_one_pane_and_satisfies_the_invariant() {
        let workspace = one_pane();
        assert_eq!(workspace.all_pane_ids(), vec![pane(1)]);
        assert!(workspace.invariant_holds());
        assert_eq!(workspace.active_session_id, Some(session_id(1)));
    }

    #[test]
    fn an_orphan_spec_is_dropped_and_a_spec_less_leaf_is_re_seeded() {
        let mut broken = two_panes();
        let Some(session) = broken.sessions.first_mut() else {
            panic!("one session");
        };
        session.specs.insert(pane(90), spec());
        session.specs.remove(&pane(2));
        assert!(!broken.invariant_holds());
        let repaired = broken.normalizing_specs();
        assert!(repaired.invariant_holds());
        assert!(repaired.spec_for(pane(90)).is_none());
        assert_eq!(
            repaired.spec_for(pane(2)).map(|spec| spec.title.clone()),
            Some(DEFAULT_PANE_TITLE.to_owned()),
        );
    }

    #[test]
    fn a_detached_entry_that_is_also_a_leaf_loses_to_the_tree() {
        let mut confused = two_panes();
        let Some(session) = confused.sessions.first_mut() else {
            panic!("one session");
        };
        session.detached.push(DetachedPane {
            pane: pane(2),
            origin_tab: Some(tab_id(1)),
        });
        let repaired = confused.normalizing_specs();
        assert!(
            repaired.detached_pane_ids().is_empty(),
            "a pane cannot be both tiled and floating"
        );
        assert!(repaired.invariant_holds());
    }

    #[test]
    fn a_detached_entry_with_no_spec_is_unrecoverable_and_dropped() {
        let mut broken = one_pane();
        let Some(session) = broken.sessions.first_mut() else {
            panic!("one session");
        };
        session.detached.push(DetachedPane {
            pane: pane(70),
            origin_tab: None,
        });
        assert!(broken.normalizing_specs().detached_pane_ids().is_empty());
    }

    #[test]
    fn a_detached_pane_with_a_spec_survives_and_stays_out_of_the_trees() {
        let mut floating = one_pane();
        let Some(session) = floating.sessions.first_mut() else {
            panic!("one session");
        };
        session.specs.insert(pane(70), spec());
        session.detached.push(DetachedPane {
            pane: pane(70),
            origin_tab: Some(tab_id(1)),
        });
        let repaired = floating.normalizing_specs();
        assert_eq!(repaired.detached_pane_ids(), vec![pane(70)]);
        assert!(repaired.is_detached(pane(70)));
        assert_eq!(
            repaired.all_pane_ids(),
            vec![pane(1)],
            "the tree walk must not report a floating pane",
        );
        assert!(repaired.invariant_holds());
    }

    #[test]
    fn an_empty_workspace_is_re_seeded_rather_than_left_empty() {
        let empty = TreeWorkspace::new(Vec::new(), None);
        let repaired = empty.normalizing_active(&mut minter());
        assert_eq!(repaired.sessions.len(), 1);
        assert_eq!(repaired.all_pane_ids().len(), 1);
        assert!(repaired.invariant_holds());
    }

    #[test]
    fn a_stale_active_session_pointer_falls_back_to_the_first() {
        let mut stale = one_pane();
        stale.active_session_id = Some(session_id(88));
        assert_eq!(
            stale.normalizing_active(&mut minter()).active_session_id,
            Some(session_id(1)),
        );
    }

    #[test]
    fn an_out_of_range_active_tab_index_is_clamped() {
        let mut stale = one_pane();
        let Some(session) = stale.sessions.first_mut() else {
            panic!("one session");
        };
        session.active_tab_index = 7;
        let repaired = stale.normalizing_active(&mut minter());
        assert_eq!(repaired.sessions.first().map(|s| s.active_tab_index), Some(0));
    }

    #[test]
    fn a_focus_or_zoom_naming_an_absent_pane_is_repaired() {
        let mut stale = two_panes();
        let Some(tab) = stale.sessions.first_mut().and_then(|s| s.tabs.first_mut()) else {
            panic!("one tab");
        };
        tab.active_pane = Some(pane(90));
        tab.zoomed_pane = Some(pane(90));
        let repaired = stale.normalizing_active(&mut minter());
        let Some(tab) = repaired.sessions.first().and_then(|s| s.tabs.first()) else {
            panic!("one tab");
        };
        assert_eq!(
            tab.active_pane,
            Some(pane(1)),
            "focus falls back to the first leaf"
        );
        assert_eq!(
            tab.zoomed_pane, None,
            "a zoom on an absent pane is simply dropped"
        );
    }

    #[test]
    fn a_session_with_no_tab_gets_one() {
        let mut hollow = one_pane();
        let Some(session) = hollow.sessions.first_mut() else {
            panic!("one session");
        };
        session.tabs.clear();
        session.specs.clear();
        let repaired = hollow.normalized(&mut minter());
        assert_eq!(repaired.sessions.first().map(|s| s.tabs.len()), Some(1));
        assert!(repaired.invariant_holds());
    }

    #[test]
    fn the_repairs_run_specs_first_so_the_selection_sees_a_consistent_set() {
        let mut broken = two_panes();
        let Some(session) = broken.sessions.first_mut() else {
            panic!("one session");
        };
        session.specs.remove(&pane(2));
        session.specs.insert(pane(90), spec());
        let repaired = broken.normalized(&mut minter());
        assert!(repaired.invariant_holds());
        assert_eq!(repaired.all_pane_ids(), vec![pane(1), pane(2)]);
    }

    #[test]
    fn a_video_pane_never_survives_a_relaunch() {
        let mut with_video = two_panes();
        let Some(session) = with_video.sessions.first_mut() else {
            panic!("one session");
        };
        session
            .specs
            .insert(pane(2), PaneSpec::new(PaneKind::Desktop, "Display"));
        let restored = with_video.dropping_video_panes();
        assert_eq!(restored.all_pane_ids(), vec![pane(1)]);
        assert!(
            restored.spec_for(pane(2)).is_none(),
            "no stream is opened for a pane no window shows"
        );
        assert!(restored.invariant_holds());
    }

    #[test]
    fn a_detached_video_pane_is_dropped_rather_than_re_docked() {
        let mut floating = one_pane();
        let Some(session) = floating.sessions.first_mut() else {
            panic!("one session");
        };
        session
            .specs
            .insert(pane(70), PaneSpec::new(PaneKind::Desktop, "Display"));
        session.detached.push(DetachedPane {
            pane: pane(70),
            origin_tab: Some(tab_id(1)),
        });
        let restored = floating.dropping_video_panes();
        assert!(restored.detached_pane_ids().is_empty());
        assert!(restored.invariant_holds());
    }

    #[test]
    fn the_location_of_a_pane_names_its_session_and_tab() {
        assert_eq!(two_panes().location_of(pane(2)), Some((session_id(1), tab_id(1))));
        assert_eq!(two_panes().location_of(pane(90)), None);
    }
}
