//! The host's single copy of the workspace, and the SINGLE SERIALIZATION POINT for every write to
//! it.
//!
//! The bug this exists to end is not a persistence bug. The host already derives every per-pane
//! fact with a stateful parser — it just published each one as an EDGE (types 21/23/26/27/32/33/34
//! /36) and kept no current value anywhere a client could ask for. A client that was not listening
//! at the instant of the edge lost the fact permanently and had no way to request it. Retaining the
//! facts as one versioned value, and letting any client ask for it at any time, is the whole
//! design.
//!
//! **Every mutation runs under one lock**, so `state_num` is monotone by construction and there is
//! no merge function anywhere: the last write to a `(kind, object_id, field)` cell wins by ARRIVAL
//! here. That is Figma's model, and the reason a CRDT is not warranted — the precedent is Zed,
//! which uses CRDTs for text buffers and host-authoritative RPC for the worktree tree. This is the
//! worktree tree.
//!
//! **The `epoch` is minted per hostd start and is not optional.** Without it a restarted daemon
//! counts `state_num` back up from zero and a returning client sitting one behind accepts a delta
//! computed against a completely different document — divergence that is permanent, silent, and has
//! no detector. The epoch is also the no-migration directive expressed on the wire: a foreign epoch
//! means reset-then-snapshot, which is the same code path as a missed frame and as a four-hour
//! reconnect.
//!
//! ## What is a seam here, and why
//!
//! Three, and each of them is a thing this crate must not decide:
//!
//! - [`WorkspaceStore`] — where the document lives on disk. The document says WHEN to save; a path,
//!   a debounce and an atomic rename are the store's, exactly as [`crate::Transcripts`] holds the
//!   journal.
//! - [`Panes`] — the pane inventory, which is the SERVER's live session maps. Asked at broadcast
//!   time rather than pushed, because a copy kept here would be one more thing that can go stale;
//!   held WEAKLY, because the document is reachable from the server and a strong edge back would be
//!   a cycle.
//! - [`crate::SessionIds`] — the entropy an intent that mints a tab or a pane needs. One seam per
//!   crate for the runtime's randomness, which is the one this crate already has.
//!
//! ## The document's own half of `docs/60` D.6.4
//!
//! [`WorkspaceSubscriber`](crate::WorkspaceSubscriber) is one subscriber's send path and
//! [`WorkspaceService`](crate::WorkspaceService) is the channel that carries it. What is HERE is
//! the value they publish and the ONE rule that makes the version number mean anything: a bump
//! happens if and only if the state actually changed.

use std::collections::BTreeSet;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use slopdesk_ids::identity::{IdSource, PaneId, SessionId, SplitNodeId, TabId};
use slopdesk_wire::document::{
    self, HostWorkspaceState, PaneLiveness, WorkspaceKey, WorkspaceObjectKind, WorkspaceTopology, codec,
    fields,
};
use slopdesk_wire::message::RawUuid;
use slopdesk_wire::workspace::{
    WorkspaceIntentStatus, WorkspacePresenceRoster, WorkspaceRosterPane, WorkspaceSubscribe,
};

use crate::host::SessionIds;
use crate::subscriber::WorkspaceSubscriber;

/// The workspace document's home on disk.
///
/// A trait rather than a path because the two answers this crate needs — "has this host ever had a
/// workspace?" and "what is it?" — are one question about a FILE, and the file's location, its
/// debounce and its corrupt-file quarantine are not decisions the document makes.
pub trait WorkspaceStore: Send + Sync + fmt::Debug {
    /// Whether this host has ever written a workspace.
    ///
    /// The question `adoptWorkspace` asks, and a file on disk answers it yes however plain its
    /// contents. Deliberately separate from [`Self::load`], which returns a usable document either
    /// way and so cannot say which it was.
    fn has_stored(&self) -> bool;

    /// The workspace this host starts with — a restored one, or a freshly minted default.
    ///
    /// Never fails: a corrupt file must not brick the daemon for every client at once.
    fn load(&self) -> HostWorkspaceState;

    /// Offers the freshest document to be written. Coalescing on the store's side.
    fn schedule_save(&self, state: &HostWorkspaceState);
}

/// A host that keeps no workspace on disk — every start mints a fresh default.
///
/// Degraded, not broken, and it is what a host whose Application Support cannot be resolved
/// actually does. `has_stored` is `false`, so such a host stays PRISTINE and a client may still
/// upload the layout it has.
#[derive(Debug, Clone, Copy)]
pub struct NoStore;

impl WorkspaceStore for NoStore {
    fn has_stored(&self) -> bool {
        false
    }

    fn load(&self) -> HostWorkspaceState {
        HostWorkspaceState::new()
    }

    fn schedule_save(&self, _state: &HostWorkspaceState) {}
}

/// The pane inventory the document is derived FROM and reaps INTO.
///
/// Four questions, and every one of them is about the server's live session maps rather than about
/// the document. Held weakly by the document — see the module note.
pub trait Panes: Send + Sync + fmt::Debug {
    /// One capture of every pane the host knows about, from all three inventories.
    ///
    /// A full sweep rather than a per-fact push, deliberately. The facts arrive from at least five
    /// independent producers (the sniffer's read-loop thread, the foreground poll, the hook socket,
    /// the blocks segmenter, the project-key resolver), and wiring each one separately is how a
    /// fact goes missing — which is the bug this document exists to end.
    fn capture(&self) -> Vec<PaneLiveness>;

    /// The roster's pane half: the RESOLVED grid and the attachments for every pane the server
    /// owns, so a client that is not driving the size can render a labelled letterbox instead of
    /// guessing.
    fn roster(&self) -> Vec<WorkspaceRosterPane>;

    /// Tears down every pane the topology no longer names: close each subscriber's channel for it
    /// and kill the shell.
    ///
    /// Unconditional and refcount-blind. Skipping it would leave a running shell with no UI
    /// anywhere and no document entry — the orphan `docs/45` §8.6 forbids — and it is what makes
    /// §8.7's "tear down only on `channelClose`" satisfiable, because the host always sends one.
    fn reap(&self, gone: &BTreeSet<RawUuid>);

    /// Re-decides whether this connection's panes count in the size fold.
    ///
    /// The subscribe is where a connection's DEVICE KIND becomes known, and the fold's predicate
    /// depends on it. Panes opened on this connection before the subscribe landed were resolved
    /// against a workspace channel that did not exist yet.
    fn resolve_size_passivity(&self, connection: RawUuid);
}

/// A document with no server behind it: no panes to capture, none to reap.
#[derive(Debug, Clone, Copy)]
pub struct NoPanes;

impl Panes for NoPanes {
    fn capture(&self) -> Vec<PaneLiveness> {
        Vec::new()
    }

    fn roster(&self) -> Vec<WorkspaceRosterPane> {
        Vec::new()
    }

    fn reap(&self, _gone: &BTreeSet<RawUuid>) {}

    fn resolve_size_passivity(&self, _connection: RawUuid) {}
}

/// [`IdSource`] over the crate's ONE entropy seam.
///
/// `slopdesk-ids` refuses to mint for the reason [`SessionIds`] exists, and the intent applier
/// needs four kinds of fresh id. A mint that fails answers all-zero rather than trapping: an intent
/// that would have created an object under a zero id is refused downstream by the applier's own
/// duplicate-id check, which is a refusal a client can act on, and a dead daemon is not.
#[derive(Debug)]
struct Minting<'a>(&'a dyn SessionIds);

impl Minting<'_> {
    fn raw(&self) -> RawUuid {
        self.0.mint().unwrap_or_default()
    }
}

impl IdSource for Minting<'_> {
    fn pane(&mut self) -> PaneId {
        PaneId::from_bytes(self.raw())
    }

    fn tab(&mut self) -> TabId {
        TabId::from_bytes(self.raw())
    }

    fn session(&mut self) -> SessionId {
        SessionId::from_bytes(self.raw())
    }

    fn split(&mut self) -> SplitNodeId {
        SplitNodeId::from_bytes(self.raw())
    }
}

/// Everything one mutation may need to touch, under one lock.
#[derive(Debug)]
struct Inner {
    /// Monotone, and bumped ONLY when the state actually changed. Every bump costs every subscriber
    /// a frame, so a no-op recapture must never move it — an idle host has to be silent.
    ///
    /// Starts at **1**, never 0. Zero is the "I know nothing" sentinel a client sends in
    /// `subscribe` and the base every snapshot declares; if the host could also legitimately BE
    /// at 0, a client that had genuinely received and acked the empty opening document would be
    /// indistinguishable from one that had never connected — and the host would keep
    /// re-snapshotting it for ever.
    state_num: i64,
    /// The document, behind an `Arc` so a broadcast to N subscribers costs N refcount bumps rather
    /// than N copies of the whole tree. Replaced wholesale on a change; never mutated in place
    /// while a subscriber holds it.
    state: Arc<HostWorkspaceState>,
    subscribers: Vec<Arc<WorkspaceSubscriber>>,
    /// Whether this document is still exactly what the host minted for a first run.
    ///
    /// Read by one thing only: `adoptWorkspace`, the legacy bootstrap. A client may upload its
    /// local tree to a host that has never had one, and to no other kind of host — which makes this
    /// the difference between importing somebody's layout and destroying it.
    pristine: bool,
    /// Where the topology half goes when it changes.
    ///
    /// Only the topology half, because liveness does not survive a restart and offering it would
    /// rewrite the same filtered bytes on every reconciler tick for a host nobody is even using.
    store: Option<Arc<dyn WorkspaceStore>>,
    /// Whether a reconcile pass is running, and whether one was asked for while it ran. Depth-1: a
    /// kick during a pass sets the flag rather than stacking another pass.
    reconciling: bool,
    kicked: bool,
}

/// The host's copy of the workspace.
#[derive(Debug)]
pub struct WorkspaceDocument {
    /// Identity of THIS document instance. A new one on every host start, and on any
    /// non-recoverable rebuild.
    epoch: RawUuid,
    inner: Mutex<Inner>,
    /// The server's live session maps. Weak — see the module note.
    panes: Mutex<Weak<dyn Panes>>,
    ids: Arc<dyn SessionIds>,
}

impl WorkspaceDocument {
    /// A document at version 1, holding nothing, with no subscribers and no store.
    #[must_use]
    pub fn new(epoch: RawUuid, ids: Arc<dyn SessionIds>) -> Self {
        Self {
            epoch,
            inner: Mutex::new(Inner {
                state_num: 1,
                state: Arc::new(HostWorkspaceState::new()),
                subscribers: Vec::new(),
                pristine: true,
                store: None,
                reconciling: false,
                kicked: false,
            }),
            panes: Mutex::new(Weak::<NoPanes>::new()),
            ids,
        }
    }

    /// Identity of this document instance, which every frame it publishes is stamped with.
    #[must_use]
    pub const fn epoch(&self) -> RawUuid {
        self.epoch
    }

    /// Installs the workspace this host starts with — restored from disk, or freshly minted.
    ///
    /// `pristine` says which. A restored document has a workspace somebody built and must refuse an
    /// upload; a minted one is the only kind that may accept one.
    ///
    /// No version bump: this runs before any subscriber exists, and a bump would only make the
    /// first snapshot claim to be the second.
    pub fn install(
        &self,
        restored: HostWorkspaceState,
        pristine: bool,
        store: Option<Arc<dyn WorkspaceStore>>,
    ) {
        let mut inner = self.lock();
        inner.state = Arc::new(restored);
        inner.pristine = pristine;
        inner.store = store;
    }

    /// Installs from `store`, minting the default when there is nothing to restore.
    ///
    /// `has_stored` is asked BEFORE the load, which mints a default when there is nothing to
    /// restore and so can no longer tell the two apart afterwards.
    pub fn install_from(&self, store: &Arc<dyn WorkspaceStore>) {
        let had = store.has_stored();
        let restored = store.load();
        self.install(restored, !had, Some(Arc::clone(store)));
    }

    /// Wires the server's session maps in. Separate from [`Self::install`] because it comes from
    /// live objects rather than from disk.
    pub fn set_panes(&self, panes: &Arc<dyn Panes>) {
        *self.panes.lock().unwrap_or_else(PoisonError::into_inner) = Arc::downgrade(panes);
    }

    /// The document as a value. Read-only; the only way to change it is through this type.
    #[must_use]
    pub fn snapshot(&self) -> Arc<HostWorkspaceState> {
        Arc::clone(&self.lock().state)
    }

    /// The topology half as a value, or `None` before one is installed.
    #[must_use]
    pub fn topology(&self) -> Option<WorkspaceTopology> {
        WorkspaceTopology::from_document(&self.lock().state)
    }

    /// How many clients are subscribed.
    #[must_use]
    pub fn subscriber_count(&self) -> usize {
        self.lock().subscribers.len()
    }

    /// Whether this document is still exactly what the host minted for a first run.
    #[must_use]
    pub fn is_pristine(&self) -> bool {
        self.lock().pristine
    }

    // MARK: - Mutation

    /// Applies an arbitrary edit and broadcasts iff it changed anything.
    ///
    /// The change test is on the VALUE: [`HostWorkspaceState`] is `PartialEq` precisely so a caller
    /// cannot accidentally version a no-op.
    pub fn mutate(&self, body: impl FnOnce(&mut HostWorkspaceState)) -> bool {
        let mut inner = self.lock();
        let mut next = (*inner.state).clone();
        body(&mut next);
        if next == *inner.state {
            return false;
        }
        inner.state = Arc::new(next);
        Self::bump(&mut inner, self.epoch);
        drop(inner);
        true
    }

    /// Replaces one pane's liveness fields, leaving its topology fields untouched.
    pub fn merge_liveness(&self, record: &PaneLiveness) -> bool {
        self.mutate(|state| {
            document::merge_pane_liveness(state, record);
        })
    }

    /// One reconciler pass: fold in what was captured, and decide what the rest of the panes are.
    ///
    /// The decision the naive "reap what was not captured" rule gets wrong once topology lives
    /// here. A pane the host restored from disk has no process — that is the whole point of a
    /// restart — but it is still a REAL pane in a REAL tab, and deleting it would erase the user's
    /// layout every time hostd restarted. The rule itself is [`document::reconcile`]'s. What stays
    /// here is the part that could not be pure: one lock serialises it, so a tick that moved three
    /// panes costs ONE `state_num` rather than three.
    pub fn reconcile(&self, captured: &[PaneLiveness]) -> bool {
        self.mutate(|state| {
            document::reconcile(state, captured);
        })
    }

    /// Marks one pane as having no process — the detached store's eviction hook.
    ///
    /// Without it the document goes semantically stale with no signal: the store kills a session
    /// behind the document's back, and every client keeps rendering a live row for a shell that was
    /// reaped on a TTL.
    pub fn mark_pane_dead(&self, pane: RawUuid) -> bool {
        self.mutate(|state| {
            document::mark_pane_dead(state, pane);
        })
    }

    /// Reaps every pane object the host no longer knows about.
    ///
    /// A pane that vanished without a close — a child that exited, a detached session the store
    /// evicted — otherwise lingers in the document for ever, and every client keeps rendering a row
    /// for a process that does not exist.
    pub fn remove_panes(&self, keeping: &BTreeSet<RawUuid>) -> bool {
        let stale: Vec<RawUuid> = self
            .lock()
            .state
            .keys()
            .into_iter()
            .filter(|key| key.kind == WorkspaceObjectKind::Pane.as_byte())
            .map(|key| key.object_id)
            .filter(|id| !keeping.contains(id))
            .collect();
        if stale.is_empty() {
            return false;
        }
        self.mutate(|state| {
            for pane in stale {
                state.remove_object(WorkspaceObjectKind::Pane.as_byte(), pane);
            }
        })
    }

    /// Publishes a project's git summary — the type-35 body verbatim.
    ///
    /// Keyed by PROJECT, not by pane: the summary is a property of the repository, and a pane-keyed
    /// copy would be N copies of one fact that can disagree. Without this a never-seen-this-host
    /// client renders no git line at all until the first `FSEvents` edge happens to fire.
    pub fn set_project(&self, project: RawUuid, key: &str, git_summary: Option<Vec<u8>>) -> bool {
        self.mutate(|state| {
            state.set(
                WorkspaceKey::of(WorkspaceObjectKind::Project, project, fields::project::KEY),
                codec::encode_string(key, codec::MAX_STRING_BYTES),
            );
            state.set_or_clear(
                WorkspaceKey::of(
                    WorkspaceObjectKind::Project,
                    project,
                    fields::project::GIT_SUMMARY,
                ),
                git_summary,
            );
        })
    }

    // MARK: - Intents

    /// Applies one client's requested topology change, and answers what became of it.
    ///
    /// The decision itself is [`document::apply`] — pure, and the same function the client runs for
    /// its optimistic overlay. What happens HERE is the part that cannot be pure: one lock
    /// serialises it, so two clients racing the same cell resolve by arrival order rather than by a
    /// merge function nobody can reason about.
    ///
    /// The second half of the answer is the panes the topology STOPPED naming, which the caller
    /// reaps. Computed under the same lock as the apply, because a set read afterwards could have
    /// moved.
    pub fn apply_intent(&self, op: u8, args: &[u8]) -> (WorkspaceIntentStatus, BTreeSet<RawUuid>) {
        let mut inner = self.lock();
        let Some(current) = WorkspaceTopology::from_document(&inner.state) else {
            // No workspace to change. A client that got this far has a document; one that has not
            // will be snapshotted the moment there is one.
            return (WorkspaceIntentStatus::RejectedNotFound, BTreeSet::new());
        };
        let before = topology_pane_ids(&current);
        let outcome = document::apply(
            op,
            args,
            &current,
            &mut Minting(self.ids.as_ref()),
            inner.pristine,
            &|pane| inner.state.project_key_for_pane(pane),
        );
        let next = match outcome {
            document::IntentOutcome::Applied(topology) => *topology,
            document::IntentOutcome::RejectedStale => {
                return (WorkspaceIntentStatus::RejectedStale, BTreeSet::new());
            },
            document::IntentOutcome::RejectedInvalid => {
                return (WorkspaceIntentStatus::RejectedInvalid, BTreeSet::new());
            },
            document::IntentOutcome::RejectedNotFound => {
                return (WorkspaceIntentStatus::RejectedNotFound, BTreeSet::new());
            },
            document::IntentOutcome::UnknownOp => {
                return (WorkspaceIntentStatus::UnknownOp, BTreeSet::new());
            },
        };
        // The bootstrap is the one op that may not run twice, so ANY accepted intent ends pristine
        // — including one that changed nothing. A client that renamed a tab to its own name has
        // still taken ownership of this workspace.
        inner.pristine = false;
        let gone: BTreeSet<RawUuid> = before.difference(&topology_pane_ids(&next)).copied().collect();
        let mut written = (*inner.state).clone();
        document::write_topology(&mut written, &next);
        if written != *inner.state {
            inner.state = Arc::new(written);
            Self::bump(&mut inner, self.epoch);
        }
        // The persistence sink, and only the topology half of it: liveness does not survive a
        // restart, and offering it would rewrite the same filtered bytes on every reconciler tick
        // for a host nobody is even using.
        let saving = inner.store.clone().map(|store| (store, Arc::clone(&inner.state)));
        drop(inner);
        if let Some((store, state)) = saving {
            store.schedule_save(&state);
        }
        (WorkspaceIntentStatus::Applied, gone)
    }

    // MARK: - Reconcile

    /// Re-captures every pane the host knows about and folds the result into the document.
    ///
    /// Because [`Self::mutate`] reports whether anything changed and `state_num` only moves when it
    /// did, an idle host stays completely silent.
    pub fn reconcile_now(&self) {
        // No audience, no work: a wall of detached agents must not keep capturing for nobody.
        if self.subscriber_count() == 0 {
            return;
        }
        loop {
            let Some(panes) = self.begin_reconcile() else {
                return;
            };
            self.reconcile(&panes.capture());
            if !self.finish_reconcile() {
                return;
            }
        }
    }

    /// Asks for a reconcile, running one only if none is already in flight.
    ///
    /// Depth-1: a kick arriving while a pass runs sets a flag rather than stacking another pass.
    /// The pass itself is idempotent and an unchanged capture produces no version bump, so a
    /// redundant kick costs a few lock acquisitions and nothing on the wire.
    pub fn kick_reconcile(&self) {
        self.reconcile_now();
    }

    /// Claims the pass, or `None` when one is already running or there is no server to ask.
    fn begin_reconcile(&self) -> Option<Arc<dyn Panes>> {
        let mut inner = self.lock();
        if inner.reconciling {
            inner.kicked = true;
            return None;
        }
        inner.reconciling = true;
        drop(inner);
        let panes = self.panes();
        if panes.is_none() {
            let mut inner = self.lock();
            inner.reconciling = false;
            inner.kicked = false;
        }
        panes
    }

    /// Ends the pass. `true` when a kick arrived while it ran and another is owed.
    fn finish_reconcile(&self) -> bool {
        let mut inner = self.lock();
        inner.reconciling = false;
        let owed = inner.kicked;
        inner.kicked = false;
        owed
    }

    // MARK: - Subscribers

    /// Registers a subscriber and immediately offers it the current document.
    ///
    /// The offer is unconditional: a subscriber that has never seen this host needs a snapshot, and
    /// one that HAS gets an empty diff it never sends. Deciding here would duplicate the reasoning
    /// that already lives, correctly, in the subscriber.
    pub fn add_subscriber(&self, subscriber: &Arc<WorkspaceSubscriber>) {
        let mut inner = self.lock();
        inner.subscribers.push(Arc::clone(subscriber));
        subscriber.deliver_state(self.epoch, inner.state_num, Arc::clone(&inner.state));
        drop(inner);
        self.broadcast_roster();
    }

    /// Retires a subscriber and tells everyone else.
    ///
    /// The null broadcast when the last one leaves is deliberate: a roster that simply stops
    /// arriving is indistinguishable from a stalled host, and every remaining client would keep
    /// rendering a viewer who is gone.
    pub fn remove_subscriber(&self, id: RawUuid) {
        let mut inner = self.lock();
        let Some(index) = inner.subscribers.iter().position(|held| held.id() == id) else {
            return;
        };
        let gone = inner.subscribers.remove(index);
        drop(inner);
        gone.close();
        self.broadcast_roster();
    }

    /// The subscriber with this id, if it is still registered.
    #[must_use]
    pub fn subscriber(&self, id: RawUuid) -> Option<Arc<WorkspaceSubscriber>> {
        self.lock()
            .subscribers
            .iter()
            .find(|held| held.id() == id)
            .map(Arc::clone)
    }

    /// Records a client's ack of a state number it holds.
    pub fn note_ack(&self, id: RawUuid, state_num: i64) {
        if let Some(subscriber) = self.subscriber(id) {
            subscriber.note_ack(state_num);
        }
    }

    /// A repeat `subscribe` IS the resync verb.
    pub fn note_resubscribe(&self, id: RawUuid, request: WorkspaceSubscribe) {
        let Some(subscriber) = self.subscriber(id) else {
            return;
        };
        subscriber.note_resubscribe(request);
        let inner = self.lock();
        subscriber.deliver_state(self.epoch, inner.state_num, Arc::clone(&inner.state));
        drop(inner);
        self.broadcast_roster();
    }

    /// Rebuilds the roster and fans it to everyone.
    ///
    /// Presence never touches `state_num`: a kind-2 frame that advanced it would make the host
    /// retire, via the ladder's assumed-acked base, a diff it never sent — permanent silent
    /// divergence on the very first rename. Presence is derived, TTL-expired and never persisted,
    /// so it is broadcast whole.
    pub fn broadcast_roster(&self) {
        let subscribers = self.lock().subscribers.clone();
        let mut clients: Vec<_> = subscribers.iter().map(|held| held.roster_record()).collect();
        clients.sort_by_key(|client| client.client_instance_id);
        let roster = WorkspacePresenceRoster {
            clients,
            panes: self.panes().map(|panes| panes.roster()).unwrap_or_default(),
        };
        for subscriber in &subscribers {
            subscriber.deliver_roster(roster.clone());
        }
    }

    /// Tears every subscriber down — daemon shutdown.
    pub fn shutdown(&self) {
        let mut inner = self.lock();
        let gone = std::mem::take(&mut inner.subscribers);
        drop(inner);
        for subscriber in gone {
            subscriber.close();
        }
    }

    /// Bumps the version and offers the new document to everyone.
    fn bump(inner: &mut Inner, epoch: RawUuid) {
        inner.state_num = inner.state_num.saturating_add(1);
        for subscriber in &inner.subscribers {
            subscriber.deliver_state(epoch, inner.state_num, Arc::clone(&inner.state));
        }
    }

    /// The server's session maps, or `None` when none is wired in or the server is gone.
    ///
    /// Publishing no panes is the honest answer for a document nobody has given an inventory to.
    #[must_use]
    pub fn panes(&self) -> Option<Arc<dyn Panes>> {
        self.panes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .upgrade()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Every pane the topology currently PLACES.
///
/// A closed tab's panes are deliberately excluded: the ring keeps their records so ⇧⌘T can rebuild
/// the layout, but their shells go with the close, exactly as they always have.
#[must_use]
pub fn topology_pane_ids(topology: &WorkspaceTopology) -> BTreeSet<RawUuid> {
    topology
        .tree
        .all_pane_ids()
        .into_iter()
        .map(PaneId::bytes)
        .collect()
}
