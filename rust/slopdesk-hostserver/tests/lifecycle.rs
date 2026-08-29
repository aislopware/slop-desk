//! `docs/60` D.6.5 — the four ways a pane, a link and the daemon end.
//!
//! Every test here is about a DIFFERENCE between two of them, because that is what the ladder is:
//! nothing below computes a value, and the same four objects — a pane, a key, a link, a note — come
//! out in a different state depending on which door they left by. A leave is not a reap, a link
//! drop is not a close, and a daemon stop is not either. Each of those pairs was a comment in the
//! Swift; here each is a name.
//!
//! The one thing that is NOT asserted inline is the stop's join. `Threads` is real there on
//! purpose: "the stop does not return until every pane has been let go" is a claim about a thread
//! finishing, and an inline offload would make it true by construction.

pub mod support;

use core::time::Duration;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;

use slopdesk_hostserver::control::SpawnRefused;
use slopdesk_hostserver::{
    Adopted, DetachedStore, Fresh, Host, HostEnv, HostObserver, HostParts, Offload, Pane, Peer, Spawner,
    Standalone, Threads, WorkspaceChannels,
};
use slopdesk_ids::uuid_text;
use slopdesk_muxnet::connection::ChannelOpen;
use slopdesk_muxsession::registry::{Key, PRIMARY_SUBSCRIBER, Subscriber, Uuid};
use slopdesk_wire::mux::envelope::MuxCloseReason;
use support::{Ghost, as_pane};

#[expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod suite {
    use super::*;

    // -------------------------------------------------------------------------------- the fakes

    /// One link, as a ledger of every close it was told to send.
    #[derive(Debug)]
    struct Link {
        connection: Uuid,
        channel_closes: Mutex<Vec<(u32, MuxCloseReason)>>,
        hangups: AtomicUsize,
    }

    impl Link {
        fn on(connection: u8) -> Arc<Self> {
            let mut id = [0_u8; 16];
            id[0] = connection;
            Arc::new(Self {
                connection: id,
                channel_closes: Mutex::new(Vec::new()),
                hangups: AtomicUsize::new(0),
            })
        }

        fn closes(&self) -> Vec<(u32, MuxCloseReason)> {
            self.channel_closes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        fn hung_up(&self) -> usize {
            self.hangups.load(Ordering::SeqCst)
        }
    }

    impl Peer for Link {
        fn connection(&self) -> Uuid {
            self.connection
        }

        fn ack(&self, _channel: u32, _accepted: bool, _resume_from: i64) {}

        fn close_channel(&self, channel: u32, reason: MuxCloseReason) {
            self.channel_closes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((channel, reason));
        }

        fn close(&self) {
            self.hangups.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn as_peer(link: &Arc<Link>) -> Arc<dyn Peer> {
        Arc::<Link>::clone(link)
    }

    /// An offload that runs everything on the calling thread.
    #[derive(Debug, Clone, Copy)]
    struct Inline;

    impl Offload for Inline {
        fn run(&self, work: Box<dyn FnOnce() + Send>) {
            work();
        }

        fn after(&self, _delay: Duration, work: Box<dyn FnOnce() + Send>) {
            work();
        }
    }

    /// An offload that REFUSES — the exhausted-process path the stop's join has to survive.
    #[derive(Debug, Clone, Copy)]
    struct Refuses;

    impl Offload for Refuses {
        fn run(&self, work: Box<dyn FnOnce() + Send>) {
            drop(work);
        }

        fn after(&self, _delay: Duration, work: Box<dyn FnOnce() + Send>) {
            drop(work);
        }
    }

    /// Every connection count published and every line logged, in order.
    #[derive(Debug, Default)]
    struct Ledger {
        counts: Mutex<Vec<usize>>,
        lines: Mutex<Vec<String>>,
    }

    impl Ledger {
        fn counts(&self) -> Vec<usize> {
            self.counts.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn said(&self, needle: &str) -> bool {
            self.lines
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .iter()
                .any(|line| line.contains(needle))
        }
    }

    impl HostObserver for Ledger {
        fn connection_count(&self, count: usize) {
            self.counts
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(count);
        }

        fn log(&self, line: &str) {
            self.lines
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(line.to_owned());
        }
    }

    /// The workspace door, as a count of what it was told and in which order.
    #[derive(Debug, Default)]
    struct Document {
        kicks: AtomicUsize,
        dropped: Mutex<Vec<Uuid>>,
        shutdowns: AtomicUsize,
    }

    impl Document {
        fn kicks(&self) -> usize {
            self.kicks.load(Ordering::SeqCst)
        }

        fn dropped(&self) -> Vec<Uuid> {
            self.dropped
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        fn shutdowns(&self) -> usize {
            self.shutdowns.load(Ordering::SeqCst)
        }
    }

    impl WorkspaceChannels for Document {
        fn open(&self, _open: Box<ChannelOpen>, _peer: &Arc<dyn Peer>) -> bool {
            false
        }

        fn fact_changed(&self) {
            self.kicks.fetch_add(1, Ordering::SeqCst);
        }

        /// This document keeps no subscriber table, so no attachment can be named through it.
        fn client_instance(&self, _connection: Uuid) -> Option<Uuid> {
            None
        }

        fn drop_connection(&self, connection: Uuid) {
            self.dropped
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(connection);
        }

        fn shutdown(&self) {
            self.shutdowns.fetch_add(1, Ordering::SeqCst);
        }
    }

    /// A fork that refuses everything: this suite is about ENDINGS, and a pane it did not place
    /// itself is a pane no assertion below is about.
    #[derive(Debug, Default)]
    struct Barren;

    impl Spawner for Barren {
        fn spawn(&self, _request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from("this suite drives the endings")))
        }

        fn start(&self, _pane: &Arc<dyn Pane>, _cwd: Option<&str>) {}

        fn adopt(&self, _request: Adopted<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from("this suite drives the endings")))
        }

        fn open(&self, _request: Fresh<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from("this suite drives the endings")))
        }
    }

    // ------------------------------------------------------------------------------ the fixture

    struct Bench {
        host: Arc<Host>,
        store: Arc<DetachedStore>,
        ledger: Arc<Ledger>,
        document: Arc<Document>,
    }

    fn bench() -> Bench {
        bench_on(Arc::new(Inline))
    }

    fn bench_on(offload: Arc<dyn Offload>) -> Bench {
        bench_with(offload, true)
    }

    fn bench_on_a_host_with_no_retention() -> Bench {
        bench_with(Arc::new(Inline), false)
    }

    fn bench_with(offload: Arc<dyn Offload>, retention: bool) -> Bench {
        let store = Arc::new(DetachedStore::new());
        let ledger = Arc::new(Ledger::default());
        let document = Arc::new(Document::default());
        let host = Host::assemble(HostParts {
            detached: retention.then(|| Arc::clone(&store)),
            detach_ttl: Some(Duration::from_secs(60)),
            offload,
            workspace: Arc::<Document>::clone(&document),
            observer: Arc::<Ledger>::clone(&ledger),
            env: HostEnv {
                parent: BTreeMap::new(),
                term: String::from("xterm-ghostty"),
                version: String::from("9.9.9"),
                shell: String::from("/bin/zsh"),
                agent_socket_path: None,
                control_socket_path: None,
                ctl_binary_path: None,
            },
            ..HostParts::around(Arc::new(Barren))
        });
        Bench {
            host,
            store,
            ledger,
            document,
        }
    }

    impl Bench {
        /// Files `pane` under `key` as the connection's PRIMARY member, holding `members` of them.
        fn place(&self, key: Key, pane: &Arc<Ghost>, members: usize) {
            pane.hold(members);
            self.host.sessions().attach_primary(key, &as_pane(pane));
        }

        /// Files `pane` under `key` as one JOINED member of a fan-out.
        fn join(&self, key: Key, pane: &Arc<Ghost>, subscriber: Subscriber) {
            self.host.sessions().attach(key, &as_pane(pane), subscriber);
        }
    }

    const fn key(connection: u8, channel: u32) -> Key {
        let mut id = [0_u8; 16];
        id[0] = connection;
        Key::new(id, channel)
    }

    // ------------------------------------------------------------------- one client leaving

    #[test]
    fn a_client_leaving_a_shared_pane_stops_watching_and_the_shell_keeps_running() {
        let bench = bench();
        let pane = Ghost::numbered(1);
        let mac = key(1, 7);
        let phone = key(2, 3);
        bench.place(mac, &pane, 2);
        bench.join(phone, &pane, 9);

        bench.host.leave_channel(phone);

        assert_eq!(pane.shutdowns(), 0, "somebody else is still holding the pane");
        assert_eq!(pane.departed(), vec![9], "only THIS client's membership ended");
        assert!(
            bench.host.sessions().pane(mac).is_some(),
            "the other client's key survives its neighbour leaving",
        );
        assert!(bench.host.sessions().pane(phone).is_none());
        assert!(bench.ledger.said("left shared pane"));
    }

    #[test]
    fn the_last_client_leaving_a_pane_ends_it() {
        let bench = bench();
        let pane = Ghost::numbered(1);
        let only = key(1, 7);
        bench.place(only, &pane, 1);

        bench.host.leave_channel(only);

        assert_eq!(
            pane.shutdowns(),
            1,
            "the last member out reaps, exactly as a close always has"
        );
        assert_eq!(pane.relinquishes(), 0, "a deliberate close is not a let-go");
        assert!(bench.host.sessions().pane(only).is_none());
    }

    #[test]
    fn a_leave_of_a_key_that_is_already_gone_is_a_no_op() {
        let bench = bench();
        let pane = Ghost::numbered(1);
        let only = key(1, 7);
        bench.place(only, &pane, 1);
        bench.host.leave_channel(only);
        let counted = bench.ledger.counts().len();

        bench.host.leave_channel(only);

        assert_eq!(
            pane.shutdowns(),
            1,
            "the peer close and the child exit race, and both land here"
        );
        assert_eq!(
            bench.ledger.counts().len(),
            counted,
            "and neither re-publishes a count"
        );
    }

    #[test]
    fn the_audience_is_counted_in_links_rather_than_in_panes() {
        let bench = bench();
        let link = Link::on(2);
        bench.host.note_peer(&as_peer(&link));

        assert_eq!(
            bench.host.peer_count(),
            1,
            "an accepted link is an audience the moment it is filed…",
        );
        assert_eq!(
            bench.host.sessions().connection_count(),
            0,
            "…which is BEFORE it holds any pane, and the two counts are different questions",
        );

        let pane = Ghost::numbered(1);
        bench.place(key(2, 7), &pane, 1);
        assert_eq!(
            bench.host.peer_count(),
            1,
            "taking a channel does not make one link into two",
        );
        assert_eq!(bench.host.sessions().connection_count(), 1);

        let _closed = bench.host.forget_connection(link.connection);
        assert_eq!(
            bench.host.peer_count(),
            0,
            "and forgetting the connection ends the audience even with the pane still filed",
        );
    }

    #[test]
    fn an_evicted_member_is_told_the_pane_is_still_there_rather_than_retired() {
        let bench = bench();
        let link = Link::on(2);
        bench.host.note_peer(&as_peer(&link));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 2);
        bench.join(key(2, 3), &pane, 9);

        bench.host.evict_subscriber(&as_pane(&pane), 9);

        assert_eq!(
            link.closes(),
            vec![(3, MuxCloseReason::SubscriberEvicted)],
            "the close frame is the only thing the evicted client is ever told, so the reason rides it",
        );
        assert_eq!(
            pane.shutdowns(),
            0,
            "the pane, its shell and its other members are untouched"
        );
    }

    #[test]
    fn an_eviction_of_a_member_that_has_no_channel_touches_nothing() {
        let bench = bench();
        let link = Link::on(2);
        bench.host.note_peer(&as_peer(&link));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 2);

        bench.host.evict_subscriber(&as_pane(&pane), 9);

        assert!(link.closes().is_empty());
        assert_eq!(pane.departed(), Vec::<Subscriber>::new());
    }

    // --------------------------------------------------------------------- the topology reap

    #[test]
    fn a_topology_delete_closes_every_channel_that_named_the_pane_before_it_kills_the_shell() {
        let bench = bench();
        let mac = Link::on(1);
        let phone = Link::on(2);
        bench.host.note_peer(&as_peer(&mac));
        bench.host.note_peer(&as_peer(&phone));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 2);
        bench.join(key(2, 3), &pane, 9);

        bench.host.reap_panes(&std::iter::once(pane.id()).collect());

        assert_eq!(
            mac.closes(),
            vec![(7, MuxCloseReason::Retired)],
            "a re-open under this session id is a SPAWN, and the reason says so",
        );
        assert_eq!(phone.closes(), vec![(3, MuxCloseReason::Retired)]);
        assert_eq!(
            pane.shutdowns(),
            1,
            "refcount-BLIND: closePane is a layout fact, and leaving the shell alive would be the orphan",
        );
        assert!(bench.host.sessions().pane(key(1, 7)).is_none());
        assert!(bench.host.sessions().pane(key(2, 3)).is_none());
    }

    #[test]
    fn a_reap_of_nothing_touches_no_link_at_all() {
        let bench = bench();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 1);

        bench.host.reap_panes(&BTreeSet::new());

        assert!(link.closes().is_empty());
        assert_eq!(pane.shutdowns(), 0);
    }

    #[test]
    fn a_reap_of_a_pane_this_host_does_not_have_is_a_no_op_rather_than_a_panic() {
        let bench = bench();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));

        bench.host.reap_panes(&std::iter::once([0x99_u8; 16]).collect());

        assert!(link.closes().is_empty());
    }

    // ------------------------------------------------------------------------ the size fold

    #[test]
    fn a_connection_turning_passive_retires_the_vote_of_every_pane_it_already_opened() {
        let bench = bench();
        let first = Ghost::numbered(1);
        let second = Ghost::numbered(2);
        bench.place(key(1, 7), &first, 1);
        bench.join(key(1, 8), &second, 4);

        bench.host.resolve_size_passivity(key(1, 0).connection, true);

        assert!(bench.host.size_passive(key(1, 0).connection));
        assert_eq!(
            first.contributors(),
            vec![(PRIMARY_SUBSCRIBER, true)],
            "a pane opened before the subscribe landed was resolved against a channel that did not exist",
        );
        assert_eq!(
            second.contributors(),
            vec![(4, true)],
            "addressed to the SUBSCRIBER this connection rides, never to the pane's primary",
        );
    }

    #[test]
    fn the_verdict_reaches_only_the_connection_it_was_about() {
        let bench = bench();
        let mine = Ghost::numbered(1);
        let theirs = Ghost::numbered(2);
        bench.place(key(1, 7), &mine, 1);
        bench.place(key(2, 7), &theirs, 1);

        bench.host.resolve_size_passivity(key(1, 0).connection, true);

        assert_eq!(
            theirs.contributors(),
            Vec::new(),
            "a phone must never crush a Mac"
        );
    }

    // ------------------------------------------------------------------------- the link drop

    #[test]
    fn a_link_drop_parks_the_pane_rather_than_ending_it() {
        let bench = bench();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 1);

        bench.host.handle_link_down(link.connection);

        assert_eq!(
            pane.shutdowns(),
            0,
            "a client going away is not a pane being over"
        );
        assert!(
            pane.is_detached(),
            "the shell keeps running, and a returning client may claim it"
        );
        assert!(bench.store.contains(pane.id()));
        assert!(bench.host.sessions().pane(key(1, 7)).is_none());
        assert_eq!(link.hung_up(), 1);
    }

    #[test]
    fn a_link_drop_on_a_host_with_no_retention_ends_the_pane_rather_than_stranding_it() {
        // The Swift runs its detach loop only `if detachEnabled`, so a host with retention off
        // drops the link and leaves its panes in the live map. `slopdesk-hostnet` named that branch
        // when it made the policy the owner's; here the loop always runs and `park` is what differs.
        let bench = bench_on_a_host_with_no_retention();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 1);

        bench.host.handle_link_down(link.connection);

        assert_eq!(
            pane.shutdowns(),
            1,
            "no store means nowhere to park, so the pane is ENDED"
        );
        assert!(
            bench.host.sessions().pane(key(1, 7)).is_none(),
            "and never left in a table nobody will drain",
        );
    }

    #[test]
    fn a_link_drop_under_a_fan_out_parks_nothing_while_another_client_is_still_watching() {
        let bench = bench();
        let mac = Link::on(1);
        let phone = Link::on(2);
        bench.host.note_peer(&as_peer(&mac));
        bench.host.note_peer(&as_peer(&phone));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 2);
        bench.join(key(2, 3), &pane, 9);

        bench.host.handle_link_down(phone.connection);

        assert!(
            !pane.is_detached(),
            "detaching per key engages the offline gate while the other client is still watching",
        );
        assert!(!bench.store.contains(pane.id()));
        assert!(bench.host.sessions().pane(key(1, 7)).is_some());
        assert_eq!(pane.departed(), vec![9]);
    }

    #[test]
    fn a_link_drop_kicks_the_document_once_rather_than_once_per_pane() {
        let bench = bench();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));
        for channel in 1_u32..=3 {
            let pane = Ghost::numbered(u8::try_from(channel).unwrap());
            bench.place(key(1, channel), &pane, 1);
        }

        bench.host.handle_link_down(link.connection);

        assert_eq!(
            bench.document.kicks(),
            1,
            "three panes going detached at once is ONE fact, and N kicks would cost N reconciles",
        );
        assert_eq!(bench.document.dropped(), vec![link.connection]);
    }

    #[test]
    fn a_link_that_carried_no_pane_is_still_closed_and_forgotten() {
        let bench = bench();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));
        bench.host.set_size_passive(link.connection, true);

        bench.host.handle_link_down(link.connection);

        assert_eq!(
            link.hung_up(),
            1,
            "a link with no channel still holds a socket pair and two receive loops",
        );
        assert!(
            !bench.host.size_passive(link.connection),
            "and its size verdict goes with it"
        );
        assert_eq!(bench.document.dropped(), vec![link.connection]);
        assert_eq!(bench.document.kicks(), 0, "nothing about the topology changed");
        assert!(bench.ledger.counts().is_empty(), "and no count was re-published");
    }

    #[test]
    fn a_second_link_drop_for_the_same_connection_is_a_no_op() {
        let bench = bench();
        let link = Link::on(1);
        bench.host.note_peer(&as_peer(&link));
        bench.host.handle_link_down(link.connection);

        bench.host.handle_link_down(link.connection);

        assert_eq!(link.hung_up(), 1, "the link was already taken out of the table");
    }

    // ------------------------------------------------------------------------------ the stop

    #[test]
    fn the_stop_notes_every_pane_it_is_letting_go_before_it_drains_the_table_that_names_them() {
        let bench = bench();
        let live = Ghost::numbered(1);
        let parked = Ghost::numbered(2);
        bench.place(key(1, 7), &live, 1);
        bench.store.insert(&as_pane(&parked), None);

        bench.host.stop();

        assert!(
            bench.host.let_go().holds(&uuid_text(live.id())),
            "after the drains there is nothing left to enumerate, so the note goes first",
        );
        assert!(bench.host.let_go().holds(&uuid_text(parked.id())), "both halves");
    }

    #[test]
    fn the_stop_lets_panes_go_rather_than_ending_them() {
        let bench = bench();
        let live = Ghost::numbered(1);
        let parked = Ghost::numbered(2);
        bench.place(key(1, 7), &live, 1);
        bench.store.insert(&as_pane(&parked), None);

        bench.host.stop();

        assert_eq!(live.relinquishes(), 1);
        assert_eq!(
            live.shutdowns(),
            0,
            "hostd is going away; these panes are not over"
        );
        assert_eq!(
            parked.relinquishes(),
            1,
            "killing exactly the panes nobody was watching was the sharpest edge of the old behaviour",
        );
        assert_eq!(parked.shutdowns(), 0);
    }

    #[test]
    fn the_stop_refuses_a_spawn_that_races_it() {
        let bench = bench();

        bench.host.stop();

        assert!(
            bench.host.is_stopping(),
            "the accepted connections' receive loops keep running past a listener cancel",
        );
    }

    #[test]
    fn the_stop_publishes_an_empty_table_and_ends_the_document() {
        let bench = bench();
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 1);

        bench.host.stop();

        assert_eq!(
            bench.ledger.counts(),
            vec![0],
            "the map is empty, so nobody holds a pane"
        );
        assert_eq!(bench.document.shutdowns(), 1);
        assert_eq!(bench.host.sessions().member_count(), 0);
    }

    #[test]
    fn the_stop_closes_every_link_including_the_ones_carrying_no_channel() {
        let bench = bench();
        let busy = Link::on(1);
        let idle = Link::on(2);
        bench.host.note_peer(&as_peer(&busy));
        bench.host.note_peer(&as_peer(&idle));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 1);

        bench.host.stop();

        assert_eq!(busy.hung_up(), 1);
        assert_eq!(
            idle.hung_up(),
            1,
            "the idle link is the half that makes this a fix for the drift rather than for its visible part",
        );
        assert!(
            bench.host.drain_peers().is_empty(),
            "and the table is empty afterwards"
        );
    }

    #[test]
    fn a_stop_with_nothing_open_is_still_a_clean_stop() {
        let bench = bench();

        bench.host.stop();

        assert!(bench.host.is_stopping());
        assert_eq!(bench.document.shutdowns(), 1);
        assert!(!bench.ledger.said("did not finish"));
    }

    #[test]
    fn the_stop_does_not_return_until_every_pane_has_actually_been_let_go() {
        // The one test with a REAL thread pool: the claim is that the stop JOINS, and an inline
        // offload would make it true by construction. hostd's duplicate of every master must be
        // closed before the process calls `exit(0)`, or a half-torn-down pane's last bytes never
        // reach its journal.
        let bench = bench_on(Arc::new(Threads));
        let panes: Vec<Arc<Ghost>> = (1_u8..=8).map(Ghost::numbered).collect();
        for (channel, pane) in panes.iter().enumerate() {
            // Long enough that a stop which merely SPAWNED the threads would return first.
            pane.stalls_for(40);
            bench.place(key(1, u32::try_from(channel).unwrap() + 1), pane, 1);
        }

        bench.host.stop();

        for pane in &panes {
            assert_eq!(
                pane.relinquishes(),
                1,
                "every one of them finished BEFORE the stop returned",
            );
        }
    }

    #[test]
    fn a_stop_whose_offload_refuses_a_thread_still_ends_rather_than_parking_for_ever() {
        let bench = bench_on(Arc::new(Refuses));
        let pane = Ghost::numbered(1);
        bench.place(key(1, 7), &pane, 1);

        let done = Arc::new(AtomicUsize::new(0));
        let host = Arc::clone(&bench.host);
        let flag = Arc::clone(&done);
        let stopping = thread::spawn(move || {
            host.stop();
            flag.store(1, Ordering::SeqCst);
        });
        stopping.join().expect("the stop thread must not panic");

        assert_eq!(done.load(Ordering::SeqCst), 1);
        assert!(
            bench.ledger.said("did not finish being let go in time"),
            "a stop that cannot finish is worse than a stop that finished without one pane's last bytes",
        );
    }
}
