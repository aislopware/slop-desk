//! `docs/60` D.6.4 — the workspace document, its reconciler, and the channel session that carries
//! it.
//!
//! Three ladders, and the suite is split the same way the port is:
//!
//! - the DOCUMENT, whose one rule is that `state_num` moves if and only if the value changed;
//! - the SUBSCRIBER, whose rules are the mosh ones — diff against the ACKED base, coalesce depth-1,
//!   and never send an empty frame;
//! - the SERVICE, which decides who may open a channel and what a malformed frame costs.
//!
//! The pump thread is deliberately NOT started for most of these. [`Deferred`] drops the work it is
//! handed, and the test calls [`WorkspaceSubscriber::drain`] — the exact function the pump calls —
//! so what is asserted is what ships. One test starts a real pump, because "a delivery wakes the
//! thread" is the one claim inline draining cannot make.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use slopdesk_hostserver::{
    EventSink, HostObserver, NoPanes, NoStore, Offload, Panes, SessionIds, Threads, WorkspaceChannels,
    WorkspaceDocument, WorkspaceService, WorkspaceStore, WorkspaceSubscriber,
};
use slopdesk_ids::identity::{PaneId, SessionId, TabId};
use slopdesk_tree::session::{PaneKind, PaneSpec, Session};
use slopdesk_tree::workspace::TreeWorkspace;
use slopdesk_wire::document::{
    HostWorkspaceState, PaneLiveness, PaneLivenessState, WorkspaceKey, WorkspaceObjectKind,
    WorkspaceTopology, codec, fields, intent,
};
use slopdesk_wire::message::{RawUuid, WireMessage};
use slopdesk_wire::workspace::{
    WorkspaceClientKind, WorkspaceEventKind, WorkspaceIntent, WorkspaceIntentStatus, WorkspacePresenceUpdate,
    WorkspaceRosterPane, WorkspaceSubscribe,
};

const EPOCH: RawUuid = [0xE1; 16];
const OTHER_EPOCH: RawUuid = [0xE2; 16];
const CONNECTION: RawUuid = [0xC1; 16];
const SECOND_CONNECTION: RawUuid = [0xC2; 16];
const CLIENT: RawUuid = [0xC1; 16];
const PANE: RawUuid = [0x11; 16];
const OTHER_PANE: RawUuid = [0x22; 16];
const PROJECT: RawUuid = [0x33; 16];

// ---------------------------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------------------------

/// The frames one subscriber sent, and a switch that kills the link.
#[derive(Debug, Default)]
struct Wire {
    sent: Mutex<Vec<WireMessage>>,
    dead: AtomicBool,
}

impl Wire {
    fn die(&self) {
        self.dead.store(true, Ordering::SeqCst);
    }

    fn frames(&self) -> Vec<WireMessage> {
        self.sent.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Every frame's kind byte, in order.
    fn kinds(&self) -> Vec<u8> {
        self.frames()
            .iter()
            .filter_map(|frame| {
                match *frame {
                    WireMessage::WorkspaceEvent { kind, .. } => Some(kind),
                    _ => None,
                }
            })
            .collect()
    }

    /// The `(base, new)` state numbers of the last document frame, if there was one.
    fn last_document(&self) -> Option<(u8, i64, i64)> {
        self.frames().iter().rev().find_map(|frame| {
            match *frame {
                WireMessage::WorkspaceEvent {
                    kind,
                    base_state_num,
                    new_state_num,
                    ..
                } if kind == WorkspaceEventKind::Snapshot.as_byte()
                    || kind == WorkspaceEventKind::Diff.as_byte() =>
                {
                    Some((kind, base_state_num, new_state_num))
                },
                _ => None,
            }
        })
    }

    fn count(&self) -> usize {
        self.sent.lock().unwrap_or_else(PoisonError::into_inner).len()
    }
}

impl EventSink for Wire {
    fn send(&self, message: &WireMessage) -> bool {
        if self.dead.load(Ordering::SeqCst) {
            return false;
        }
        self.sent
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(message.clone());
        true
    }
}

/// The daemon log, so a refusal can be asserted on rather than inferred from an absence.
#[derive(Debug, Default)]
struct Log(Mutex<Vec<String>>);

impl Log {
    fn said(&self, needle: &str) -> bool {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .any(|line| line.contains(needle))
    }
}

impl HostObserver for Log {
    fn connection_count(&self, _count: usize) {}

    fn log(&self, line: &str) {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(line.to_owned());
    }
}

/// An offload that DROPS what it is handed.
///
/// The suite drives the pump by hand, which is the point: a pump thread would make every assertion
/// a race against a scheduler. The one test that needs a real thread asks for [`Threads`].
#[derive(Debug, Clone, Copy)]
struct Deferred;

impl Offload for Deferred {
    fn run(&self, work: Box<dyn FnOnce() + Send>) {
        drop(work);
    }

    fn after(&self, _delay: Duration, work: Box<dyn FnOnce() + Send>) {
        drop(work);
    }
}

/// Ids that count up, so a test can name what it is about to be handed.
#[derive(Debug, Default)]
struct Counting(Mutex<u8>);

impl SessionIds for Counting {
    fn mint(&self) -> Option<RawUuid> {
        let mut next = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        *next = next.saturating_add(1);
        Some([*next; 16])
    }
}

/// A source that mints nothing — the exhausted-entropy path.
#[derive(Debug, Clone, Copy)]
struct Barren;

impl SessionIds for Barren {
    fn mint(&self) -> Option<RawUuid> {
        None
    }
}

/// The server's session maps, as a ledger.
#[derive(Debug, Default)]
struct Inventory {
    captured: Mutex<Vec<PaneLiveness>>,
    roster: Mutex<Vec<WorkspaceRosterPane>>,
    reaped: Mutex<Vec<RawUuid>>,
    resolved: Mutex<Vec<RawUuid>>,
    passive: Mutex<Vec<bool>>,
}

impl Inventory {
    /// Every size verdict this server was handed, in order.
    fn verdicts(&self) -> Vec<bool> {
        self.passive
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl Panes for Inventory {
    fn capture(&self) -> Vec<PaneLiveness> {
        self.captured
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn roster(&self) -> Vec<WorkspaceRosterPane> {
        self.roster.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn reap(&self, gone: &std::collections::BTreeSet<RawUuid>) {
        self.reaped
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .extend(gone.iter().copied());
    }

    fn resolve_size_passivity(&self, connection: RawUuid, passive: bool) {
        self.passive
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(passive);
        self.resolved
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(connection);
    }
}

/// A store with a document in it, and a ledger of what it was asked to write.
#[derive(Debug)]
struct Disk {
    stored: Option<HostWorkspaceState>,
    saves: Mutex<Vec<HostWorkspaceState>>,
    flushes: Mutex<usize>,
}

impl Disk {
    fn holding(state: Option<HostWorkspaceState>) -> Arc<Self> {
        Arc::new(Self {
            stored: state,
            saves: Mutex::new(Vec::new()),
            flushes: Mutex::new(0),
        })
    }

    fn saves(&self) -> usize {
        self.saves.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// How many times the debounce was told to land what it was holding.
    fn flushes(&self) -> usize {
        *self.flushes.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl WorkspaceStore for Disk {
    fn has_stored(&self) -> bool {
        self.stored.is_some()
    }

    fn load(&self) -> HostWorkspaceState {
        self.stored.clone().unwrap_or_default()
    }

    fn schedule_save(&self, state: &HostWorkspaceState) {
        self.saves
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(state.clone());
    }

    fn flush(&self) {
        *self.flushes.lock().unwrap_or_else(PoisonError::into_inner) += 1;
    }
}

// ---------------------------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------------------------

/// The trait-object shapes the seams take.
///
/// Written as functions rather than `as` casts because the crate denies `trivial_casts` — an
/// unsizing coercion is what these are, and naming it once is cheaper than a temporary per call.
fn sink(wire: &Arc<Wire>) -> Arc<dyn EventSink> {
    Arc::<Wire>::clone(wire)
}

fn watching(log: &Arc<Log>) -> Arc<dyn HostObserver> {
    Arc::<Log>::clone(log)
}

fn stored<S: WorkspaceStore + 'static>(disk: &Arc<S>) -> Arc<dyn WorkspaceStore> {
    Arc::<S>::clone(disk)
}

fn inventoried<P: Panes + 'static>(panes: &Arc<P>) -> Arc<dyn Panes> {
    Arc::<P>::clone(panes)
}

/// A document with counting ids and nothing wired in.
fn document() -> Arc<WorkspaceDocument> {
    Arc::new(WorkspaceDocument::new(EPOCH, Arc::new(Counting::default())))
}

/// One subscriber over `wire`, with the flags a Mac client sends.
fn subscriber(wire: &Arc<Wire>, log: &Arc<Log>, id: RawUuid) -> Arc<WorkspaceSubscriber> {
    Arc::new(WorkspaceSubscriber::new(
        id,
        sink(wire),
        &subscribe(EPOCH, 0),
        watching(log),
    ))
}

fn subscribe(known_epoch: RawUuid, known_state_num: i64) -> WorkspaceSubscribe {
    WorkspaceSubscribe {
        client_instance_id: CLIENT,
        client_kind: 0,
        known_epoch,
        known_state_num,
        flags: WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE,
        label: String::from("MacBook Pro"),
    }
}

/// A one-session, one-tab, two-pane workspace, written into a document state.
fn seeded() -> HostWorkspaceState {
    let mut topology = WorkspaceTopology::new(TreeWorkspace::new(
        vec![Session::single_pane(
            SessionId::from_bytes([0x51; 16]),
            "slop-desk",
            TabId::from_bytes([0x71; 16]),
            PaneId::from_bytes(PANE),
            PaneSpec::new(PaneKind::Terminal, "zsh"),
        )],
        Some(SessionId::from_bytes([0x51; 16])),
    ));
    topology.host_display_name = String::from("mac-studio");
    let mut state = HostWorkspaceState::new();
    slopdesk_wire::document::write_topology(&mut state, &topology);
    state
}

/// One captured pane, live and attached.
fn captured(pane: RawUuid, title: &str) -> PaneLiveness {
    let mut record = PaneLiveness::new(pane, PaneLivenessState::Attached);
    record.live_title = Some(title.to_owned());
    record
}

// ---------------------------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------------------------

#[test]
fn a_document_opens_at_one_so_a_client_that_knows_nothing_is_not_mistaken_for_one_that_is_caught_up() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);

    document.add_subscriber(&held);
    assert!(held.drain());

    assert_eq!(
        wire.last_document(),
        Some((WorkspaceEventKind::Snapshot.as_byte(), 0, 1)),
        "the opening document is version 1, never 0 — 0 is the client's I-know-nothing sentinel",
    );
}

#[test]
fn a_mutation_that_changed_nothing_leaves_the_version_where_it_was() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.add_subscriber(&held);
    assert!(held.drain());
    let before = wire.count();

    let moved = document.mutate(|_state| {});

    assert!(
        !moved,
        "a closure that wrote nothing must not version the document"
    );
    assert!(held.drain());
    assert_eq!(wire.count(), before, "an idle host is silent");
}

#[test]
fn one_reconciler_tick_that_moved_three_panes_costs_one_version() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.add_subscriber(&held);
    assert!(held.drain());
    // Acked, so the next frame is a diff and its `new` number is readable.
    held.note_ack(1);

    let moved = document.reconcile(&[
        captured(PANE, "zsh"),
        captured(OTHER_PANE, "nvim"),
        captured([0x33; 16], "claude"),
    ]);

    assert!(moved);
    assert!(held.drain());
    assert_eq!(
        wire.last_document().map(|(_, _, new)| new),
        Some(2),
        "three panes in one pass is one version, not three",
    );
}

#[test]
fn a_reconcile_that_captured_the_same_facts_twice_versions_the_document_once() {
    let document = document();
    let records = [captured(PANE, "zsh")];

    assert!(document.reconcile(&records));
    assert!(
        !document.reconcile(&records),
        "an unchanged capture must not move the version, or an idle host wakes every client on every tick",
    );
}

#[test]
fn a_pane_the_host_no_longer_knows_about_is_reaped_from_the_document() {
    let document = document();
    document.reconcile(&[captured(PANE, "zsh"), captured(OTHER_PANE, "nvim")]);

    let removed = document.remove_panes(&std::iter::once(PANE).collect());

    assert!(removed);
    let state = document.snapshot();
    assert!(
        state
            .get(&WorkspaceKey::of(
                WorkspaceObjectKind::Pane,
                OTHER_PANE,
                fields::pane::LIVE_TITLE
            ))
            .is_none(),
        "the pane nothing owns is gone",
    );
    assert!(
        state
            .get(&WorkspaceKey::of(
                WorkspaceObjectKind::Pane,
                PANE,
                fields::pane::LIVE_TITLE
            ))
            .is_some(),
        "the pane that was kept is untouched",
    );
}

#[test]
fn a_project_summary_is_filed_by_project_rather_than_copied_onto_every_pane_of_it() {
    let document = document();

    assert!(document.set_project(PROJECT, "slop-desk", Some(vec![1, 2, 3])));

    let state = document.snapshot();
    assert_eq!(
        state.get(&WorkspaceKey::of(
            WorkspaceObjectKind::Project,
            PROJECT,
            fields::project::KEY
        )),
        Some(codec::encode_string("slop-desk", codec::MAX_STRING_BYTES).as_slice()),
    );
    assert_eq!(
        state.get(&WorkspaceKey::of(
            WorkspaceObjectKind::Project,
            PROJECT,
            fields::project::GIT_SUMMARY
        )),
        Some([1, 2, 3].as_slice()),
    );
}

#[test]
fn an_intent_against_a_document_with_no_workspace_is_not_found_rather_than_a_crash() {
    let document = document();

    let (status, gone) = document.apply_intent(
        intent::WorkspaceIntentOp::RenameTab.as_byte(),
        &intent::encode_identity(&PANE),
    );

    assert_eq!(status, WorkspaceIntentStatus::RejectedNotFound);
    assert!(gone.is_empty());
}

#[test]
fn an_op_byte_this_build_does_not_know_is_refused_by_name_rather_than_guessed_at() {
    let document = document();
    document.install(seeded(), true, None);

    let (status, _gone) = document.apply_intent(0xFE, &[]);

    assert_eq!(status, WorkspaceIntentStatus::UnknownOp);
    assert!(document.is_pristine(), "a refused intent does not take ownership");
}

#[test]
fn an_accepted_intent_ends_pristine_so_a_second_upload_cannot_destroy_the_layout() {
    let document = document();
    document.install(seeded(), true, None);

    let (status, _gone) = document.apply_intent(
        intent::WorkspaceIntentOp::RenameTab.as_byte(),
        &intent::encode_name(&[0x71; 16], "build"),
    );

    assert_eq!(status, WorkspaceIntentStatus::Applied);
    assert!(
        !document.is_pristine(),
        "renaming a tab is taking ownership of this workspace",
    );
}

#[test]
fn an_accepted_intent_names_the_panes_the_topology_stopped_placing() {
    let document = document();
    document.install(seeded(), false, None);

    let (status, gone) = document.apply_intent(
        intent::WorkspaceIntentOp::ClosePane.as_byte(),
        &intent::encode_identity(&PANE),
    );

    assert_eq!(status, WorkspaceIntentStatus::Applied);
    assert_eq!(
        gone.into_iter().collect::<Vec<_>>(),
        vec![PANE],
        "the shell behind a closed pane is the caller's to reap, and it can only reap what it is told",
    );
}

#[test]
fn a_topology_change_is_offered_to_the_store_and_a_liveness_change_is_not() {
    let document = document();
    let disk = Disk::holding(Some(seeded()));
    document.install_from(&(stored(&disk)));

    document.reconcile(&[captured(PANE, "zsh")]);
    assert_eq!(
        disk.saves(),
        0,
        "liveness does not survive a restart, so it is not written"
    );

    document.apply_intent(
        intent::WorkspaceIntentOp::RenameTab.as_byte(),
        &intent::encode_name(&[0x71; 16], "build"),
    );
    assert_eq!(disk.saves(), 1, "the topology half is the persistence sink");
}

#[test]
fn a_host_that_has_written_a_workspace_before_refuses_to_have_one_uploaded_over_it() {
    let restored = document();
    restored.install_from(&(stored(&Disk::holding(Some(seeded())))));
    assert!(!restored.is_pristine());

    let fresh = document();
    fresh.install_from(&(stored(&Disk::holding(None))));
    assert!(
        fresh.is_pristine(),
        "a host with nothing on disk is the only kind that may accept somebody's layout",
    );
}

#[test]
fn a_host_with_no_store_at_all_still_serves_a_workspace_and_stays_pristine() {
    let document = document();

    document.install_from(&(stored(&Arc::new(NoStore))));

    assert!(document.is_pristine());
    assert!(document.snapshot().is_empty(), "degraded, not broken");
}

#[test]
fn a_document_nobody_is_watching_captures_nothing() {
    let document = document();
    let inventory = Arc::new(Inventory::default());
    *inventory.captured.lock().unwrap_or_else(PoisonError::into_inner) = vec![captured(PANE, "zsh")];
    document.set_panes(&(inventoried(&inventory)));

    document.reconcile_now();

    assert!(
        document.snapshot().is_empty(),
        "a wall of detached agents must not keep capturing for nobody",
    );
}

#[test]
fn a_document_with_no_inventory_wired_in_publishes_no_panes_rather_than_inventing_them() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.set_panes(&(inventoried(&Arc::new(NoPanes))));

    document.add_subscriber(&held);
    document.reconcile_now();

    assert!(document.snapshot().is_empty());
}

// ---------------------------------------------------------------------------------------------
// The subscriber
// ---------------------------------------------------------------------------------------------

#[test]
fn a_subscriber_that_acked_gets_a_diff_against_what_it_acked_rather_than_the_whole_tree() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.add_subscriber(&held);
    assert!(held.drain());
    held.note_ack(1);

    document.reconcile(&[captured(PANE, "zsh")]);
    assert!(held.drain());

    assert_eq!(
        wire.last_document(),
        Some((WorkspaceEventKind::Diff.as_byte(), 1, 2)),
        "every diff declares the ACKED base, never the last SENT one",
    );
}

#[test]
fn an_offer_that_changed_nothing_since_the_acked_base_costs_no_frame_at_all() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.add_subscriber(&held);
    assert!(held.drain());
    held.note_ack(1);
    let before = wire.count();

    // The same document, offered again — the version moved, the value did not.
    held.deliver_state(EPOCH, 2, document.snapshot());
    assert!(held.drain());

    assert_eq!(
        wire.count(),
        before,
        "an empty diff still costs a frame, a wake and an ack on every client — so it is not sent",
    );
}

#[test]
fn a_second_offer_arriving_mid_flight_is_recomputed_rather_than_queued_behind_the_first() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.add_subscriber(&held);
    assert!(held.drain());
    // No ack: the first frame is still outstanding, so the ladder HOLDS.
    let before = wire.count();

    document.reconcile(&[captured(PANE, "zsh")]);
    document.reconcile(&[captured(PANE, "zsh"), captured(OTHER_PANE, "nvim")]);
    assert!(held.drain());
    assert_eq!(wire.count(), before, "nothing ships while a frame is in flight");

    // The ack unblocks it, and what ships is the FRESHEST document, not the first of the two.
    held.note_ack(1);
    assert!(held.drain());
    let state = document.snapshot();
    let (kind, _base, new) = wire
        .last_document()
        .expect("the unblocked ladder must ship something");
    assert_eq!(kind, WorkspaceEventKind::Diff.as_byte());
    assert_eq!(
        new, 3,
        "the discarded offer left no trace; the freshest one shipped"
    );
    assert!(
        state
            .get(&WorkspaceKey::of(
                WorkspaceObjectKind::Pane,
                OTHER_PANE,
                fields::pane::LIVE_TITLE
            ))
            .is_some(),
    );
}

#[test]
fn a_foreign_epoch_is_reset_before_it_is_snapshotted_so_no_stale_delta_can_be_accepted() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);

    held.deliver_state(EPOCH, 1, Arc::new(seeded()));
    assert!(held.drain());
    held.note_ack(1);
    held.deliver_state(OTHER_EPOCH, 1, Arc::new(seeded()));
    assert!(held.drain());

    assert_eq!(
        wire.kinds(),
        vec![
            WorkspaceEventKind::Snapshot.as_byte(),
            WorkspaceEventKind::Reset.as_byte(),
            WorkspaceEventKind::Snapshot.as_byte(),
        ],
        "reset FIRST, then a snapshot — which is self-contained and so epoch-independent",
    );
}

#[test]
fn a_resubscribe_naming_a_state_the_ladder_still_holds_is_answered_with_a_diff_not_a_snapshot() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    held.deliver_state(EPOCH, 1, Arc::new(HostWorkspaceState::new()));
    assert!(held.drain());

    // The client says exactly where it is, which supersedes the in-flight guess.
    held.note_resubscribe(subscribe(EPOCH, 1));
    held.deliver_state(EPOCH, 2, Arc::new(seeded()));
    assert!(held.drain());

    assert_eq!(
        wire.last_document(),
        Some((WorkspaceEventKind::Diff.as_byte(), 1, 2)),
        "a repeat subscribe IS the resync verb, and an honoured claim costs one diff",
    );
}

#[test]
fn a_resubscribe_naming_a_state_nobody_retained_falls_back_to_the_whole_document() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    held.deliver_state(EPOCH, 1, Arc::new(HostWorkspaceState::new()));
    assert!(held.drain());

    held.note_resubscribe(subscribe(EPOCH, 9_999));
    held.deliver_state(EPOCH, 2, Arc::new(seeded()));
    assert!(held.drain());

    assert_eq!(
        wire.last_document(),
        Some((WorkspaceEventKind::Snapshot.as_byte(), 0, 2)),
        "reconnect, a missed frame and a four-hour absence all land on the one snapshot path",
    );
}

#[test]
fn an_intent_answer_is_never_coalesced_away_however_many_arrive_at_once() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);

    for index in 0..4_u8 {
        held.deliver_result(slopdesk_wire::workspace::WorkspaceIntentResult {
            intent_id: [index; 16],
            status: WorkspaceIntentStatus::Applied.as_byte(),
        });
    }
    assert!(held.drain());

    assert_eq!(
        wire.kinds(),
        vec![WorkspaceEventKind::IntentResult.as_byte(); 4],
        "each answers a distinct intent id, and a dropped one leaves an optimistic patch waiting out a \
         timeout that need not happen",
    );
}

#[test]
fn presence_rides_the_all_zero_epoch_until_a_document_has_named_a_real_one() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);

    held.deliver_roster(slopdesk_wire::workspace::WorkspacePresenceRoster::default());
    assert!(held.drain());

    let WireMessage::WorkspaceEvent { kind, epoch, .. } = wire
        .frames()
        .first()
        .cloned()
        .expect("a roster must have shipped")
    else {
        panic!("a workspace subscriber sends nothing but workspace events")
    };
    assert_eq!(kind, WorkspaceEventKind::Presence.as_byte());
    assert_eq!(
        epoch, [0; 16],
        "kinds 2 and 3 are epoch-independent, so a sentinel beats a fabricated UUID",
    );
}

#[test]
fn a_presence_update_with_an_older_clock_is_ignored_rather_than_merged() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);

    assert!(held.note_presence(&WorkspacePresenceUpdate {
        presence_clock: 7,
        viewing_tab_id: [0x71; 16],
        viewing_pane_id: PANE,
        cols: 120,
        rows: 40,
        flags: WorkspaceSubscribe::FLAG_CONTRIBUTES_SIZE,
    }));
    assert!(!held.note_presence(&WorkspacePresenceUpdate {
        presence_clock: 6,
        viewing_tab_id: [0; 16],
        viewing_pane_id: [0; 16],
        cols: 0,
        rows: 0,
        flags: 0,
    }));

    let record = held.roster_record();
    assert_eq!(record.viewing_pane_id, PANE, "the newer view stands");
    assert_eq!(record.cols, 120);
    assert_eq!(
        record.label, "MacBook Pro",
        "the identity half is the host's, not the ladder's"
    );
}

#[test]
fn a_subscriber_never_retains_more_documents_than_its_window_plus_its_base() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);

    for version in 1..=40_i64 {
        held.deliver_state(EPOCH, version, Arc::new(seeded()));
        assert!(held.drain());
        held.note_ack(version);
    }

    assert!(
        held.retained_count() <= slopdesk_workspace::sync_ladder::MAX_RELEASED,
        "a retained state the ladder stopped needing is a whole workspace leaked per frame, per subscriber, \
         for ever — held {} after forty",
        held.retained_count(),
    );
}

#[test]
fn a_closed_subscriber_holds_no_document_and_accepts_no_more() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    document.add_subscriber(&held);
    assert!(held.drain());
    let before = wire.count();

    held.close();
    held.deliver_state(EPOCH, 2, Arc::new(seeded()));

    assert!(held.is_closed());
    assert_eq!(
        held.retained_count(),
        0,
        "nothing to diff against means nothing worth holding"
    );
    assert!(!held.drain(), "a closed subscriber is finished, not idle");
    assert_eq!(wire.count(), before);
}

#[test]
fn a_link_that_died_mid_send_closes_the_subscriber_rather_than_spinning_on_it() {
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    wire.die();

    held.deliver_state(EPOCH, 1, Arc::new(seeded()));

    assert!(!held.drain(), "the caller stops draining");
    assert!(held.is_closed());
    assert!(log.said("send failed"));
}

#[test]
fn a_delivery_wakes_the_pump_thread_with_nobody_draining_by_hand() {
    let document = document();
    let wire = Arc::new(Wire::default());
    let log = Arc::new(Log::default());
    let held = subscriber(&wire, &log, [1; 16]);
    let offload: Arc<dyn Offload> = Arc::new(Threads);

    held.start(&offload);
    document.add_subscriber(&held);

    // The one claim inline draining cannot make, so the one place a wall clock is warranted.
    let deadline = Instant::now() + Duration::from_secs(5);
    while wire.count() == 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        wire.last_document(),
        Some((WorkspaceEventKind::Snapshot.as_byte(), 0, 1)),
        "the pump parks on the condvar and a delivery is what wakes it",
    );
    held.close();
}

// ---------------------------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------------------------

/// The service, its ledger, and the sink a request answers on.
struct Bench {
    service: Arc<WorkspaceService>,
    document: Arc<WorkspaceDocument>,
    inventory: Arc<Inventory>,
    wire: Arc<Wire>,
    sink: Arc<dyn EventSink>,
    log: Arc<Log>,
}

fn bench() -> Bench {
    let document = document();
    let inventory = Arc::new(Inventory::default());
    document.set_panes(&(inventoried(&inventory)));
    let log = Arc::new(Log::default());
    let wire = Arc::new(Wire::default());
    let service = WorkspaceService::new(
        Arc::clone(&document),
        Arc::new(Deferred),
        watching(&log),
        Arc::new(Counting::default()),
    );
    Bench {
        service,
        document,
        inventory,
        sink: sink(&wire),
        wire,
        log,
    }
}

impl Bench {
    fn subscribe(&self, connection: RawUuid) {
        self.service.handle(
            connection,
            slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe.as_byte(),
            &subscribe(EPOCH, 0).encode(),
            &self.sink,
        );
    }

    fn send(&self, connection: RawUuid, verb: slopdesk_wire::workspace::WorkspaceRequestVerb, body: &[u8]) {
        self.service.handle(connection, verb.as_byte(), body, &self.sink);
    }
}

#[test]
fn a_phone_is_denied_the_size_vote_and_every_other_device_keeps_it() {
    let bench = bench();
    let mut phone = subscribe(EPOCH, 0);
    phone.client_kind = WorkspaceClientKind::Ios.as_byte();

    bench.subscribe(CONNECTION);
    let other = [0x0C_u8; 16];
    bench.send(
        other,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe,
        &phone.encode(),
    );

    assert_eq!(
        bench.inventory.verdicts().as_slice(),
        [false, true],
        "a phone must never crush a Mac, and a device the host cannot name still sizes its own pane",
    );
}

#[test]
fn a_device_the_host_does_not_recognise_still_gets_to_size_its_own_pane() {
    let bench = bench();
    let mut unknown = subscribe(EPOCH, 0);
    unknown.client_kind = 0xEE;

    bench.send(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe,
        &unknown.encode(),
    );

    assert_eq!(
        bench.inventory.verdicts().as_slice(),
        [false],
        "defaulting an unnamed device to passive would leave the shipped CLI unable to resize",
    );
}

#[test]
fn the_stop_lands_the_debounce_before_it_closes_the_clients_watching_it() {
    let disk = Disk::holding(Some(seeded()));
    let document = Arc::new(WorkspaceDocument::new(EPOCH, Arc::new(Counting::default())));
    document.install_from(&stored(&disk));
    let log = Arc::new(Log::default());
    let wire = Arc::new(Wire::default());
    let service = WorkspaceService::new(
        Arc::clone(&document),
        Arc::new(Deferred),
        watching(&log),
        Arc::new(Counting::default()),
    );
    service.handle(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe.as_byte(),
        &subscribe(EPOCH, 0).encode(),
        &sink(&wire),
    );
    assert_eq!(document.subscriber_count(), 1);

    service.shutdown();

    assert_eq!(
        disk.flushes(),
        1,
        "a debounce that outlives the process loses the last edit"
    );
    assert_eq!(document.subscriber_count(), 0);
    // The MAP is cleared too, not just the document's list: otherwise a Start→Stop→Start cycle
    // refuses the returning client's channel as a duplicate.
    service.handle(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe.as_byte(),
        &subscribe(EPOCH, 0).encode(),
        &sink(&wire),
    );
    assert_eq!(
        document.subscriber_count(),
        1,
        "the returning client is a first subscribe, not a duplicate",
    );
}

#[test]
fn a_subscribe_registers_the_connection_settles_its_size_verdict_and_publishes_at_once() {
    let bench = bench();

    bench.subscribe(CONNECTION);

    assert_eq!(bench.document.subscriber_count(), 1);
    assert_eq!(
        bench
            .inventory
            .resolved
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_slice(),
        [CONNECTION],
        "the subscribe is where this connection's device kind becomes known",
    );
}

#[test]
fn a_repeat_subscribe_is_the_resync_verb_rather_than_a_second_subscriber() {
    let bench = bench();
    bench.subscribe(CONNECTION);

    bench.subscribe(CONNECTION);

    assert_eq!(
        bench.document.subscriber_count(),
        1,
        "two subscribers behind one link would each keep their own acked base for one viewer",
    );
}

#[test]
fn a_second_connection_gets_its_own_subscriber() {
    let bench = bench();

    bench.subscribe(CONNECTION);
    bench.subscribe(SECOND_CONNECTION);

    assert_eq!(bench.document.subscriber_count(), 2);
}

#[test]
fn a_malformed_subscribe_is_dropped_and_the_channel_carries_on() {
    let bench = bench();

    bench.send(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe,
        &[0xFF, 0xFF],
    );

    assert_eq!(bench.document.subscriber_count(), 0);
    assert!(bench.log.said("malformed subscribe dropped"));
    bench.subscribe(CONNECTION);
    assert_eq!(
        bench.document.subscriber_count(),
        1,
        "one bad frame is not a teardown"
    );
}

#[test]
fn an_ack_body_that_is_not_exactly_eight_bytes_is_a_framing_bug_rather_than_a_value_to_salvage() {
    let bench = bench();
    bench.subscribe(CONNECTION);
    let held = bench
        .document
        .subscriber([1; 16])
        .expect("the subscribe minted id 1");
    assert!(held.drain());
    let before = bench.wire.count();

    bench.send(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Ack,
        &[0, 0, 0, 1],
    );

    bench.document.reconcile(&[captured(PANE, "zsh")]);
    assert!(held.drain());
    assert_eq!(
        bench.wire.count(),
        before,
        "the ack was dropped, so the first frame is still outstanding and the ladder holds",
    );
}

#[test]
fn an_unknown_verb_is_named_in_the_log_and_changes_nothing() {
    let bench = bench();
    bench.subscribe(CONNECTION);

    bench.service.handle(CONNECTION, 0xFE, &[], &bench.sink);

    assert!(bench.log.said("unknown verb 254 dropped"));
    assert_eq!(bench.document.subscriber_count(), 1);
}

#[test]
fn a_presence_update_from_a_connection_that_never_subscribed_is_dropped() {
    let bench = bench();

    bench.send(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Presence,
        &WorkspacePresenceUpdate {
            presence_clock: 1,
            viewing_tab_id: [0x71; 16],
            viewing_pane_id: PANE,
            cols: 120,
            rows: 40,
            flags: 0,
        }
        .encode(),
    );

    assert_eq!(bench.document.subscriber_count(), 0);
    assert_eq!(bench.wire.count(), 0);
}

#[test]
fn an_applied_intent_reaps_the_shells_the_topology_stopped_placing_and_answers_the_client() {
    let bench = bench();
    bench.document.install(seeded(), false, None);
    bench.subscribe(CONNECTION);
    let held = bench
        .document
        .subscriber([1; 16])
        .expect("the subscribe minted id 1");

    bench.send(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Intent,
        &WorkspaceIntent {
            intent_id: [0x9A; 16],
            op: intent::WorkspaceIntentOp::ClosePane.as_byte(),
            args: intent::encode_identity(&PANE),
        }
        .encode(),
    );
    assert!(held.drain());

    assert_eq!(
        bench
            .inventory
            .reaped
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_slice(),
        [PANE],
        "a running shell with no UI anywhere and no document entry is the orphan §8.6 forbids",
    );
    assert!(
        bench
            .wire
            .kinds()
            .contains(&WorkspaceEventKind::IntentResult.as_byte()),
        "every decodable intent gets a definite answer",
    );
}

#[test]
fn a_malformed_intent_envelope_is_dropped_in_silence_because_there_is_no_id_to_answer_to() {
    let bench = bench();
    bench.subscribe(CONNECTION);
    let held = bench
        .document
        .subscriber([1; 16])
        .expect("the subscribe minted id 1");
    assert!(held.drain());
    let before = bench.wire.count();

    bench.send(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Intent,
        &[0x01],
    );
    assert!(held.drain());

    assert_eq!(bench.wire.count(), before);
}

#[test]
fn a_dropped_connection_retires_its_subscriber_and_tells_everyone_who_is_left() {
    let bench = bench();
    bench.subscribe(CONNECTION);
    bench.subscribe(SECOND_CONNECTION);

    bench.service.drop_subscriber(CONNECTION);

    assert_eq!(bench.document.subscriber_count(), 1);
    let remaining = bench
        .document
        .subscriber([2; 16])
        .expect("the second subscribe minted id 2");
    assert!(remaining.drain());
    assert!(
        bench
            .wire
            .kinds()
            .contains(&WorkspaceEventKind::Presence.as_byte()),
        "a roster that simply stops arriving is indistinguishable from a stalled host",
    );
}

#[test]
fn a_host_that_cannot_mint_a_subscriber_id_refuses_the_subscribe_rather_than_serving_a_nameless_one() {
    let document = document();
    let log = Arc::new(Log::default());
    let wire = Arc::new(Wire::default());
    let service = WorkspaceService::new(
        Arc::clone(&document),
        Arc::new(Deferred),
        watching(&log),
        Arc::new(Barren),
    );

    service.handle(
        CONNECTION,
        slopdesk_wire::workspace::WorkspaceRequestVerb::Subscribe.as_byte(),
        &subscribe(EPOCH, 0).encode(),
        &(sink(&wire)),
    );

    assert_eq!(document.subscriber_count(), 0);
    assert!(log.said("no subscriber id could be minted"));
}

#[test]
fn a_shutdown_closes_every_subscriber_so_no_pump_outlives_the_daemon() {
    let bench = bench();
    bench.subscribe(CONNECTION);
    bench.subscribe(SECOND_CONNECTION);
    let held = bench
        .document
        .subscriber([1; 16])
        .expect("the subscribe minted id 1");

    bench.document.shutdown();

    assert_eq!(bench.document.subscriber_count(), 0);
    assert!(held.is_closed());
}
