//! The adoption ladder: which surviving shells a starting hostd takes back, and what it does to
//! each one it takes.
//!
//! Every test here is about a pane that is ALREADY RUNNING with a user's work in it. There is no
//! recoverable wrong answer: adopt a stranger's pane and two daemons share one master, one journal
//! and one eviction timer; refuse one of our own and the shell runs perfectly for ever with no tab
//! that can reach it. So the suite is mostly about the four buckets and the note that decides the
//! hardest of them — a pane THIS process released, which superd still reports as attached because
//! hostd deliberately never closes its link.
//!
//! The note is spent in exactly one place, and three tests are about that: an adoption that refuses
//! must leave it, an adoption that lands must take it, and a pane superd no longer lists must lose
//! it whether or not anything was adopted.

pub mod support;

use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostserver::control::SpawnRefused;
use slopdesk_hostserver::{
    Adopted, DetachedStore, Fresh, HookRoutes, Host, HostObserver, HostParts, LetGo, Pane, Restored, Spawner,
    Standalone, Survivors, Transcripts, owner_identity,
};
use slopdesk_muxsession::open_route::SurvivorResume;
use slopdesk_muxsession::registry::Uuid;
use slopdesk_superwire::protocol::PaneRecord;
use support::{Ghost, as_pane};

#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod suite {
    use super::*;

    /// This hostd, as superd records it.
    const OURS: &str = "hostd port=7777 state=default";
    /// Another live daemon on the same machine.
    const THEIRS: &str = "hostd port=7778 state=default";

    // -------------------------------------------------------------------------------- the fakes

    /// superd, as a list that can also refuse to be read.
    #[derive(Debug, Default)]
    struct Superd {
        connected: bool,
        records: Mutex<Vec<PaneRecord>>,
        refusal: Mutex<Option<String>>,
        /// How many times the ladder asked. A `list` is a socket round trip, not a field read.
        asks: Mutex<usize>,
    }

    impl Superd {
        fn up(records: Vec<PaneRecord>) -> Arc<Self> {
            Arc::new(Self {
                connected: true,
                records: Mutex::new(records),
                refusal: Mutex::new(None),
                asks: Mutex::new(0),
            })
        }

        fn down() -> Arc<Self> {
            Arc::new(Self::default())
        }

        fn refuse(&self, why: &str) {
            *self.refusal.lock().unwrap_or_else(PoisonError::into_inner) = Some(why.to_owned());
        }

        fn asks(&self) -> usize {
            *self.asks.lock().unwrap_or_else(PoisonError::into_inner)
        }
    }

    impl Survivors for Superd {
        fn is_connected(&self) -> bool {
            self.connected
        }

        fn list(&self) -> Result<Vec<PaneRecord>, String> {
            *self.asks.lock().unwrap_or_else(PoisonError::into_inner) += 1;
            let refusal = self
                .refusal
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone();
            if let Some(why) = refusal {
                return Err(why);
            }
            Ok(self
                .records
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone())
        }
    }

    /// What one adoption was resolved to, with the master not taken.
    #[derive(Debug, Clone)]
    struct Took {
        session: Uuid,
        pane_id: String,
        blocks: bool,
        restored: Option<usize>,
        resume_from: u64,
    }

    /// The supervisor's `adopt`, as a ledger of what it was asked for.
    #[derive(Debug, Default)]
    struct Taker {
        took: Mutex<Vec<Took>>,
        made: Mutex<Vec<Arc<Ghost>>>,
        refuse: Mutex<Option<String>>,
    }

    impl Taker {
        fn took(&self) -> Vec<Took> {
            self.took.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn made(&self) -> Vec<Arc<Ghost>> {
            self.made.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn refuse(&self, why: &str) {
            *self.refuse.lock().unwrap_or_else(PoisonError::into_inner) = Some(why.to_owned());
        }
    }

    impl Spawner for Taker {
        fn spawn(&self, _request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from(
                "this suite drives the adoption ladder",
            )))
        }

        fn start(&self, _pane: &Arc<dyn Pane>, _cwd: Option<&str>) {}

        fn open(&self, _request: Fresh<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from(
                "this suite drives the adoption ladder",
            )))
        }

        fn adopt(&self, request: Adopted<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            self.took
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Took {
                    session: request.session,
                    pane_id: request.pane_id.to_owned(),
                    blocks: request.blocks,
                    restored: request.restored.as_ref().map(|held| held.bytes.len()),
                    resume_from: request.resume_from,
                });
            // Cloned out of the guard and the guard dropped: a lock held across the arm is exactly
            // what makes a fake deadlock against the host.
            let refusal = self.refuse.lock().unwrap_or_else(PoisonError::into_inner).clone();
            if let Some(refusal) = refusal {
                return Err(SpawnRefused(refusal));
            }
            let pane = Ghost::new(request.session);
            self.made
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Arc::clone(&pane));
            Ok(as_pane(&pane))
        }
    }

    /// The journal, as what it holds and where superd's head is in the stream.
    #[derive(Debug, Default)]
    struct Journal {
        restorable: Mutex<Option<Restored>>,
        position: Mutex<SurvivorResume>,
    }

    impl Journal {
        fn holding(bytes: &[u8]) -> Arc<Self> {
            let journal = Arc::new(Self::default());
            *journal.restorable.lock().unwrap_or_else(PoisonError::into_inner) = Some(Restored {
                bytes: bytes.to_vec(),
                snapshot_composed: false,
            });
            journal
        }

        fn at(&self, position: SurvivorResume) {
            *self.position.lock().unwrap_or_else(PoisonError::into_inner) = position;
        }
    }

    impl Transcripts for Journal {
        fn delete(&self, _session: Uuid) {}

        fn restore(&self, _session: Uuid) -> Option<Restored> {
            self.restorable
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        fn position(&self, _session: Uuid) -> SurvivorResume {
            *self.position.lock().unwrap_or_else(PoisonError::into_inner)
        }
    }

    /// The hook relay's half of a route.
    #[derive(Debug, Default)]
    struct Routes {
        bound: Mutex<Vec<String>>,
    }

    impl Routes {
        fn bound(&self) -> Vec<String> {
            self.bound.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl HookRoutes for Routes {
        fn bind(&self, pane_id: &str, _pane: &Arc<dyn Pane>) {
            self.bound
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(pane_id.to_owned());
        }

        fn unbind(&self, _pane_id: &str) {}
    }

    /// Every line the ladder published.
    #[derive(Debug, Default)]
    struct Log {
        lines: Mutex<Vec<String>>,
    }

    impl Log {
        fn lines(&self) -> Vec<String> {
            self.lines.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        /// Whether any line contains `needle` — the ladder's lines are prose, and pinning them
        /// verbatim would make every wording change a test change.
        fn said(&self, needle: &str) -> bool {
            self.lines().iter().any(|line| line.contains(needle))
        }
    }

    impl HostObserver for Log {
        fn connection_count(&self, _count: usize) {}

        fn log(&self, line: &str) {
            self.lines
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(line.to_owned());
        }
    }

    // ------------------------------------------------------------------------------ the fixture

    #[derive(Debug)]
    struct Bench {
        host: Arc<Host>,
        taker: Arc<Taker>,
        store: Arc<DetachedStore>,
        journal: Arc<Journal>,
        routes: Arc<Routes>,
        log: Arc<Log>,
        notes: Arc<LetGo>,
    }

    fn bench(superd: &Arc<Superd>) -> Bench {
        bench_with(superd, Arc::new(Journal::default()), true)
    }

    fn bench_with(superd: &Arc<Superd>, journal: Arc<Journal>, retain: bool) -> Bench {
        let taker = Arc::new(Taker::default());
        let store = Arc::new(DetachedStore::new());
        let routes = Arc::new(Routes::default());
        let log = Arc::new(Log::default());
        let notes = Arc::new(LetGo::new());
        let host = Host::assemble(HostParts {
            detached: retain.then(|| Arc::clone(&store)),
            transcripts: Arc::<Journal>::clone(&journal),
            hooks: Arc::<Routes>::clone(&routes),
            observer: Arc::<Log>::clone(&log),
            survivors: Arc::<Superd>::clone(superd),
            let_go: Arc::clone(&notes),
            owner: String::from(OURS),
            blocks_enabled: true,
            ..HostParts::around(Arc::<Taker>::clone(&taker))
        });
        Bench {
            host,
            taker,
            store,
            journal,
            routes,
            log,
            notes,
        }
    }

    /// A pane superd is holding: ours, free, and named by a real session id.
    fn record(pane_id: &str) -> PaneRecord {
        PaneRecord {
            pane_id: pane_id.to_owned(),
            session_id: pane_id.to_owned(),
            pid: 4_242,
            executable: String::from("/bin/zsh"),
            cwd: Some(String::from("/work/slop-desk")),
            rows: 24,
            cols: 80,
            spawned_at: 1_700_000_000,
            attached: false,
            owner: Some(String::from(OURS)),
        }
    }

    /// A session id as superd holds it: the UPPERCASE spelling `uuid_text` writes, which is what
    /// hostd baked into the child's environment and what every hook route is filed under.
    const ALIVE: &str = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427";
    const OTHER: &str = "2C5F39CB-3FB2-21E3-994F-1127E4DDB538";

    fn bytes_of(text: &str) -> Uuid {
        slopdesk_ids::parse_uuid(text).unwrap()
    }

    // -------------------------------------------------------------------------- the happy ladder

    #[test]
    fn a_surviving_pane_of_ours_is_taken_back_started_seeded_routed_and_parked() {
        let bench = bench(&Superd::up(vec![record(ALIVE)]));

        bench.host.adopt_survivors();

        let took = bench.taker.took();
        assert_eq!(took.len(), 1);
        assert_eq!(took[0].pane_id, ALIVE, "superd's `adopt` takes the STRING");
        assert_eq!(
            took[0].session,
            bytes_of(ALIVE),
            "and the journal is filed under the same id's BYTES"
        );
        assert!(
            took[0].blocks,
            "a pane is tapped for blocks at the take, not later"
        );
        let pane = bench.taker.made()[0].clone();
        assert_eq!(
            pane.starts(),
            1,
            "the shell is alive: its output must keep reaching the journal and the detector while nobody is \
             watching"
        );
        assert_eq!(
            pane.seeded(),
            vec![String::from("/work/slop-desk")],
            "seeded from the directory the child actually got, so it lands in its project section"
        );
        assert_eq!(bench.routes.bound(), vec![String::from(ALIVE)]);
        assert!(
            bench.store.contains(bytes_of(ALIVE)),
            "parked, not held: no client owns it, and a pane in no store is reachable by nothing"
        );
        assert!(bench.log.said("adopted 1 surviving pane"));
    }

    #[test]
    fn an_adopted_pane_carries_the_transcript_its_reattach_will_replay() {
        let superd = Superd::up(vec![record(ALIVE)]);
        let bench = bench_with(&superd, Journal::holding(b"a prior life"), true);

        bench.host.adopt_survivors();

        assert_eq!(
            bench.taker.took()[0].restored,
            Some(12),
            "a reattach replays the SESSION's buffers, and an adopted session's start empty — without this \
             the user reconnects to a live shell showing a blank pane"
        );
    }

    #[test]
    fn an_adopted_panes_stream_resumes_where_superd_wrote_rather_than_from_zero() {
        let superd = Superd::up(vec![record(ALIVE)]);
        let bench = bench_with(&superd, Journal::holding(b"a prior life"), true);
        bench.journal.at(SurvivorResume {
            offset: 4_096,
            unpositioned: false,
        });

        bench.host.adopt_survivors();

        assert_eq!(
            bench.taker.took()[0].resume_from,
            4_096,
            "the ring holds the same bytes the restore does; subscribing from 0 prints the user's history \
             twice and re-feeds the sniffer and the block ledger with it"
        );
        assert!(
            !bench.log.said("holds no position"),
            "a positioned stream is the ordinary case and earns no line"
        );
    }

    #[test]
    fn a_transcript_superd_holds_no_position_in_is_named_rather_than_silently_guessed() {
        let superd = Superd::up(vec![record(ALIVE)]);
        let bench = bench_with(&superd, Journal::holding(b"a prior life"), true);
        bench.journal.at(SurvivorResume {
            offset: u64::MAX,
            unpositioned: true,
        });

        bench.host.adopt_survivors();

        assert_eq!(bench.taker.took()[0].resume_from, u64::MAX);
        assert!(
            bench.log.said("holds no position"),
            "the one case worth a line: the transcript we have, plus everything from now"
        );
    }

    #[test]
    fn an_adopted_pane_with_no_recorded_directory_is_not_seeded_under_an_empty_project() {
        let superd = Superd::up(vec![PaneRecord {
            cwd: None,
            ..record(ALIVE)
        }]);
        let bench = bench(&superd);

        bench.host.adopt_survivors();

        assert!(
            bench.taker.made()[0].seeded().is_empty(),
            "an empty key would file the pane under a project that is not one"
        );
    }

    #[test]
    fn two_survivors_are_parked_under_keys_that_cannot_collide() {
        let bench = bench(&Superd::up(vec![record(ALIVE), record(OTHER)]));

        bench.host.adopt_survivors();

        assert_eq!(bench.taker.took().len(), 2);
        assert!(bench.store.contains(bytes_of(ALIVE)));
        assert!(
            bench.store.contains(bytes_of(OTHER)),
            "a fixed synthetic key would file the second pane over the first"
        );
    }

    // ---------------------------------------------------------------------------- the four buckets

    #[test]
    fn a_panel_backend_is_named_by_its_service_rather_than_adopted_or_counted_as_left_behind() {
        let bench = bench(&Superd::up(vec![record("service:code-server")]));

        bench.host.adopt_survivors();

        assert!(
            bench.taker.took().is_empty(),
            "it is adopted on first use, not here"
        );
        assert!(bench.log.said("code-server"));
        assert!(
            !bench.log.said("are not ours"),
            "telling an operator to end it would be advice to kill the editor"
        );
    }

    #[test]
    fn a_pane_another_live_hostd_is_holding_is_left_alone() {
        let superd = Superd::up(vec![PaneRecord {
            attached: true,
            ..record(ALIVE)
        }]);
        let bench = bench(&superd);

        bench.host.adopt_survivors();

        assert!(
            bench.taker.took().is_empty(),
            "taking it would put a second daemon's shell on this one's journal, one eviction away from \
             SIGHUPing a pane a live client is using"
        );
        assert!(bench.log.said("attached to another live hostd"));
    }

    #[test]
    fn a_strangers_pane_is_left_running_whatever_it_says_about_attachment() {
        let superd = Superd::up(vec![PaneRecord {
            owner: Some(String::from(THEIRS)),
            ..record(ALIVE)
        }]);
        let bench = bench(&superd);

        bench.host.adopt_survivors();

        assert!(bench.taker.took().is_empty());
        assert!(bench.log.said("are not ours"));
    }

    #[test]
    fn an_id_no_hostd_could_have_written_is_counted_with_the_strangers() {
        let bench = bench(&Superd::up(vec![record("not-a-uuid")]));

        bench.host.adopt_survivors();

        assert!(bench.taker.took().is_empty());
        assert!(bench.log.said("are not ours"));
    }

    // ------------------------------------------------------------------------------- the notes

    #[test]
    fn a_pane_this_very_process_let_go_is_taken_back_despite_still_reading_attached() {
        let superd = Superd::up(vec![PaneRecord {
            attached: true,
            ..record(ALIVE)
        }]);
        let bench = bench(&superd);
        bench.notes.note([String::from(ALIVE)]);

        bench.host.adopt_survivors();

        assert_eq!(
            bench.taker.took().len(),
            1,
            "hostd never closes its superd link on stop, so the menu-bar host's own released panes still \
             read attached — without the note it reads them as a stranger's for ever"
        );
        assert!(
            bench.notes.is_empty(),
            "and the note is spent, so a LATER daemon cannot use it to take the same pane twice"
        );
    }

    #[test]
    fn an_adoption_that_refuses_leaves_no_pane_no_route_and_the_note_it_came_in_with() {
        let superd = Superd::up(vec![PaneRecord {
            attached: true,
            ..record(ALIVE)
        }]);
        let bench = bench(&superd);
        bench.notes.note([String::from(ALIVE)]);
        bench.taker.refuse("supervisor blip");

        bench.host.adopt_survivors();

        assert!(!bench.store.contains(bytes_of(ALIVE)), "nothing was parked");
        assert!(bench.routes.bound().is_empty(), "and nothing was routed");
        assert!(
            bench.notes.holds(ALIVE),
            "spending it on an ATTEMPT strands the pane: no map, no store, note gone, and superd still \
             calling it attached"
        );
        assert!(bench.log.said("not adopted: supervisor blip"));
        assert!(!bench.log.said("adopted 1 surviving"), "a refusal is not a count");
    }

    #[test]
    fn a_note_for_a_pane_superd_no_longer_holds_is_dropped_rather_than_kept_for_ever() {
        let bench = bench(&Superd::up(vec![record(ALIVE)]));
        bench.notes.note([
            String::from(ALIVE),
            String::from(OTHER),
            String::from("service:old"),
        ]);

        bench.host.adopt_survivors();

        assert!(
            bench.notes.is_empty(),
            "ALIVE's note was spent by its adoption, and the other two name shells that are gone — without \
             the prune the set grows for the life of a menu-bar host"
        );
    }

    #[test]
    fn a_superd_holding_nothing_still_clears_the_notes_it_made_stale() {
        let bench = bench(&Superd::up(Vec::new()));
        bench.notes.note([String::from(ALIVE)]);

        bench.host.adopt_survivors();

        assert!(
            bench.notes.is_empty(),
            "an empty list is precisely when every outstanding note is stale"
        );
    }

    #[test]
    fn a_list_that_could_not_be_read_is_not_an_empty_list() {
        let superd = Superd::up(vec![record(ALIVE)]);
        superd.refuse("socket closed");
        let bench = bench(&superd);
        bench.notes.note([String::from(ALIVE)]);

        bench.host.adopt_survivors();

        assert!(bench.taker.took().is_empty());
        assert!(
            bench.notes.holds(ALIVE),
            "treating a failed read as an empty list would drop the notes for panes still there"
        );
        assert!(bench.log.said("could not list surviving panes (socket closed)"));
    }

    #[test]
    fn the_note_writer_records_the_panes_with_a_client_and_the_ones_already_parked() {
        let bench = bench(&Superd::down());
        let live = Ghost::new(bytes_of(ALIVE));
        let parked = Ghost::new(bytes_of(OTHER));
        bench.host.sessions().attach_control(&as_pane(&live));
        bench.store.insert(&as_pane(&parked), None);

        bench.host.note_panes_let_go();

        assert!(bench.notes.holds(ALIVE));
        assert!(
            bench.notes.holds(OTHER),
            "a parked pane is exactly the one a menu-bar restart most needs to recognise"
        );
    }

    // ---------------------------------------------------------------------- when it cannot run

    #[test]
    fn a_supervisor_that_is_not_connected_adopts_nothing_and_says_nothing() {
        let superd = Superd::down();
        let bench = bench(&superd);

        bench.host.adopt_survivors();

        assert_eq!(superd.asks(), 0, "there is no list to be wrong about");
        assert!(bench.log.lines().is_empty());
    }

    #[test]
    fn a_host_that_cannot_park_reports_the_shells_it_is_leaving_rather_than_adopting_into_a_void() {
        let superd = Superd::up(vec![record(ALIVE), record("service:code-server")]);
        let bench = bench_with(&superd, Arc::new(Journal::default()), false);

        bench.host.adopt_survivors();

        assert!(bench.taker.took().is_empty());
        assert!(
            bench.log.said("1 supervised pane(s) left running and unadopted"),
            "the panel backend is counted out: it is not unadopted, it is adopted later"
        );
        assert!(bench.log.said("detach is disabled on this hostd"));
    }

    #[test]
    fn a_host_that_cannot_park_and_is_holding_only_backends_says_nothing_at_all() {
        let superd = Superd::up(vec![record("service:code-server")]);
        let bench = bench_with(&superd, Arc::new(Journal::default()), false);

        bench.host.adopt_survivors();

        assert!(
            bench.log.lines().is_empty(),
            "there is no operator advice to give"
        );
    }

    // ------------------------------------------------------------------------------- the identity

    #[test]
    fn an_owner_names_the_port_and_the_state_scope_that_together_pick_a_daemon() {
        assert_eq!(owner_identity(7_777, None), OURS);
        assert_eq!(
            owner_identity(7_777, Some("")),
            OURS,
            "an empty scope is an unset one, not a scope named nothing"
        );
        assert_eq!(
            owner_identity(7_777, Some("/tmp/scope")),
            "hostd port=7777 state=/tmp/scope",
            "two hostds on one port and two scopes are two owners, and each other's strangers"
        );
    }
}
