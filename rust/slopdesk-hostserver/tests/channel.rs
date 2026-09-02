//! The channel ladders: the seven routes an open resolves to, the two that can refuse halfway, and
//! the close that ends one.
//!
//! D.6.1 drove the eleven verbs against the live tables. This drives the OTHER half of those
//! tables — the one every verb reads and nothing in Rust had ever written — with only the fork, the
//! connection and the thread behind seams. Every assertion below is about an ORDER or an UNWIND,
//! because that is what these five functions are: nothing here computes a value, and everything
//! here can leave a pane, a descriptor, a hook route or a size contributor behind if it happens in
//! the wrong sequence.
//!
//! Five of these tests are about something that LEAKS rather than something that breaks. A join
//! that refuses must retire its own reservation, a rebind that refuses must not strand a live shell
//! outside both the table and the store, a close must take every key that aliases one pane, a
//! parked pane whose child dies must not release a route its successor re-registered, and a stop
//! racing a fork must not file into a table whose drain has already run. Each of those was a
//! comment in the Swift; here each is a name.

pub mod support;

use core::time::Duration;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostserver::control::SpawnRefused;
use slopdesk_hostserver::{
    Adopted, DetachedStore, Fresh, HookRoutes, Host, HostEnv, HostObserver, HostParts, NoWorkspace, Offload,
    Pane, Peer, Restored, Silent, Spawner, Standalone, Transcripts, WorkspaceChannels,
};
use slopdesk_muxnet::connection::ChannelOpen;
use slopdesk_muxsession::open_route::SurvivorResume;
use slopdesk_muxsession::registry::{Key, PRIMARY_SUBSCRIBER, Uuid};
use slopdesk_wire::message::NEW_SESSION_ID;
use slopdesk_wire::mux::envelope::MuxCloseReason;
use support::{Ghost, as_pane, wires};

#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod suite {
    use super::*;

    // -------------------------------------------------------------------------------- the fakes

    /// The connection, as a ledger of what it was told to answer.
    #[derive(Debug)]
    struct Wire {
        connection: Uuid,
        acks: Mutex<Vec<(u32, bool, i64)>>,
        /// Where an ack is written when a suite is asserting ORDER against the pane's starts.
        journal: Mutex<Option<Arc<Mutex<Vec<String>>>>>,
    }

    impl Wire {
        fn on(connection: u8) -> Arc<Self> {
            let mut id = [0_u8; 16];
            id[0] = connection;
            Arc::new(Self {
                connection: id,
                acks: Mutex::new(Vec::new()),
                journal: Mutex::new(None),
            })
        }

        fn acks(&self) -> Vec<(u32, bool, i64)> {
            self.acks.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        /// Writes every later ack into `journal`, beside the starts a journaled fork writes.
        fn journals(&self, journal: &Arc<Mutex<Vec<String>>>) {
            *self.journal.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(journal));
        }
    }

    impl Peer for Wire {
        fn connection(&self) -> Uuid {
            self.connection
        }

        fn ack(&self, channel: u32, accepted: bool, resume_from: i64) {
            self.acks
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((channel, accepted, resume_from));
            if let Some(journal) = self
                .journal
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .as_ref()
            {
                journal
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(String::from("ack"));
            }
        }

        // This suite is the OPEN ladder, which never sends either close verb. `tests/lifecycle.rs`
        // is where they are the subject, and its own link records them.
        fn close_channel(&self, _channel: u32, _reason: MuxCloseReason) {}
        fn close(&self) {}
    }

    fn as_peer(wire: &Arc<Wire>) -> Arc<dyn Peer> {
        Arc::<Wire>::clone(wire)
    }

    /// An offload that runs everything on the calling thread.
    ///
    /// Which is what makes this suite deterministic: the two ladders behind the seam are the two
    /// that can block, and a test that had to join a thread to see their result would be asserting
    /// on a scheduler. The DELAY is recorded rather than slept — a repaint 200 ms later is a fact
    /// about the schedule, not about this test's wall clock.
    #[derive(Debug, Default)]
    struct Inline {
        delays: Mutex<Vec<Duration>>,
    }

    impl Inline {
        fn delays(&self) -> Vec<Duration> {
            self.delays.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl Offload for Inline {
        fn run(&self, work: Box<dyn FnOnce() + Send>) {
            work();
        }

        fn after(&self, delay: Duration, work: Box<dyn FnOnce() + Send>) {
            self.delays
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(delay);
            work();
        }
    }

    /// Every hook route bound and unbound, in order.
    #[derive(Debug, Default)]
    struct Routes {
        bound: Mutex<Vec<String>>,
        unbound: Mutex<Vec<String>>,
    }

    impl Routes {
        fn bound(&self) -> Vec<String> {
            self.bound.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn unbound(&self) -> Vec<String> {
            self.unbound
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
    }

    impl HookRoutes for Routes {
        fn bind(&self, pane_id: &str, _pane: &Arc<dyn Pane>) {
            self.bound
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(pane_id.to_owned());
        }

        fn unbind(&self, pane_id: &str) {
            self.unbound
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(pane_id.to_owned());
        }
    }

    /// Every connection count published, in order.
    #[derive(Debug, Default)]
    struct Counts {
        seen: Mutex<Vec<usize>>,
    }

    impl Counts {
        fn seen(&self) -> Vec<usize> {
            self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl HostObserver for Counts {
        fn connection_count(&self, count: usize) {
            self.seen
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(count);
        }

        fn log(&self, _line: &str) {}
    }

    /// A workspace door that takes every open of its class.
    #[derive(Debug, Default)]
    struct Workspace {
        taken: AtomicUsize,
        kicks: AtomicUsize,
    }

    impl WorkspaceChannels for Workspace {
        fn open(&self, _open: Box<ChannelOpen>, _peer: &Arc<dyn Peer>) -> bool {
            self.taken.fetch_add(1, Ordering::SeqCst);
            true
        }

        fn fact_changed(&self) {
            self.kicks.fetch_add(1, Ordering::SeqCst);
        }

        /// Nobody subscribed here, so no attachment can be named — the honest answer for a door
        /// that serves opens and keeps no subscriber table.
        fn client_instance(&self, _connection: Uuid) -> Option<Uuid> {
            None
        }

        fn drop_connection(&self, _connection: Uuid) {}
        fn shutdown(&self) {}
    }

    /// What one transcript store answered, and what it was asked to forget.
    #[derive(Debug, Default)]
    struct Journal {
        restorable: Mutex<Option<Restored>>,
        takeover: Mutex<u64>,
        restores: Mutex<Vec<Uuid>>,
        deletes: Mutex<Vec<Uuid>>,
    }

    impl Journal {
        fn restores(&self) -> Vec<Uuid> {
            self.restores
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        fn deletes(&self) -> Vec<Uuid> {
            self.deletes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }
    }

    impl Transcripts for Journal {
        fn delete(&self, session: Uuid) {
            self.deletes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(session);
        }

        fn restore(&self, session: Uuid) -> Option<Restored> {
            self.restores
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(session);
            self.restorable
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        fn position(&self, _session: Uuid) -> SurvivorResume {
            SurvivorResume {
                offset: *self.takeover.lock().unwrap_or_else(PoisonError::into_inner),
                unpositioned: false,
            }
        }
    }

    /// What one fresh mux open was resolved to, with the fork not taken.
    #[derive(Debug)]
    struct Opened {
        session: Uuid,
        channel: u32,
        executable: String,
        argv0: String,
        env: BTreeMap<String, String>,
        cwd: Option<String>,
        blocks: bool,
        journal: bool,
        restored: Option<usize>,
        size_passive: bool,
        resume_takeover: u64,
    }

    /// The fork, behind the seam.
    #[derive(Default)]
    struct Fork {
        opened: Mutex<Vec<Opened>>,
        made: Mutex<Vec<Arc<Ghost>>>,
        refuse: Mutex<Option<SpawnRefused>>,
        during: Mutex<Option<Box<dyn Fn() + Send>>>,
        /// Handed to every pane this fork makes, so their starts land beside the peer's acks.
        journal: Mutex<Option<Arc<Mutex<Vec<String>>>>>,
    }

    // Hand-written because one field is a closure, and `Spawner` needs `Debug`.
    impl core::fmt::Debug for Fork {
        fn fmt(&self, out: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
            out.debug_struct("Fork")
                .field("opened", &self.opened)
                .finish_non_exhaustive()
        }
    }

    impl Fork {
        fn opened(&self) -> Vec<Opened> {
            core::mem::take(&mut *self.opened.lock().unwrap_or_else(PoisonError::into_inner))
        }

        fn made(&self) -> Vec<Arc<Ghost>> {
            self.made.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        /// Says the next fork will REFUSE.
        fn refuses(&self, why: &str) {
            *self.refuse.lock().unwrap_or_else(PoisonError::into_inner) = Some(SpawnRefused(why.to_owned()));
        }

        /// Runs `act` from INSIDE the fork, once — the only way to land something in the window
        /// between the route's stopping check and the insert's.
        fn during(&self, act: impl Fn() + Send + 'static) {
            *self.during.lock().unwrap_or_else(PoisonError::into_inner) = Some(Box::new(act));
        }

        /// Journals every start of every pane made from now on.
        fn journals(&self, journal: &Arc<Mutex<Vec<String>>>) {
            *self.journal.lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::clone(journal));
        }
    }

    impl Spawner for Fork {
        fn spawn(&self, _request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            Err(SpawnRefused(String::from(
                "this suite drives the channel ladders",
            )))
        }

        fn start(&self, _pane: &Arc<dyn Pane>, _cwd: Option<&str>) {}

        fn adopt(&self, _request: Adopted<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            // The ADOPTION ladder, which `tests/adopt.rs` drives. Refused rather than faked, so a
            // channel test that somehow reached it fails here rather than passing on a pane
            // nothing in this suite ever asserted about.
            Err(SpawnRefused(String::from(
                "this suite drives the channel ladders",
            )))
        }

        fn open(&self, request: Fresh<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            // Cloned out of the guard and the guard dropped, rather than scrutinised in place: a
            // lock held across the arm is exactly what makes a fake deadlock against the host.
            let refusal = self.refuse.lock().unwrap_or_else(PoisonError::into_inner).clone();
            if let Some(refusal) = refusal {
                return Err(refusal);
            }
            self.opened
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Opened {
                    session: request.session,
                    channel: request.channel,
                    executable: request.executable.clone(),
                    argv0: request.argv0.clone(),
                    env: request.env.clone(),
                    cwd: request.cwd.map(str::to_owned),
                    blocks: request.blocks,
                    journal: request.journal,
                    restored: request.restored.as_ref().map(|held| held.bytes.len()),
                    size_passive: request.size_passive,
                    resume_takeover: request.resume_takeover,
                });
            // Taken rather than borrowed, for the reason above and one more: it fires ONCE, so a
            // hook that stops the host cannot also stop a later open the same test makes.
            let during = self.during.lock().unwrap_or_else(PoisonError::into_inner).take();
            if let Some(act) = during {
                act();
            }
            let pane = Ghost::new(request.session);
            if let Some(journal) = self
                .journal
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .as_ref()
            {
                pane.journal_to(journal);
            }
            self.made
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Arc::clone(&pane));
            Ok(as_pane(&pane))
        }
    }

    // ------------------------------------------------------------------------------ the fixture

    /// Everything a test holds a typed handle on, plus the host they are wired into.
    struct Bench {
        host: Arc<Host>,
        fork: Arc<Fork>,
        store: Arc<DetachedStore>,
        journal: Arc<Journal>,
        routes: Arc<Routes>,
        counts: Arc<Counts>,
        offload: Arc<Inline>,
    }

    fn bench() -> Bench {
        bench_with(Arc::new(NoWorkspace))
    }

    fn bench_with(workspace: Arc<dyn WorkspaceChannels>) -> Bench {
        let fork = Arc::new(Fork::default());
        let store = Arc::new(DetachedStore::new());
        let journal = Arc::new(Journal::default());
        let routes = Arc::new(Routes::default());
        let counts = Arc::new(Counts::default());
        let offload = Arc::new(Inline::default());
        let host = Host::assemble(HostParts {
            detached: Some(Arc::clone(&store)),
            transcripts: Arc::<Journal>::clone(&journal),
            offload: Arc::<Inline>::clone(&offload),
            workspace,
            hooks: Arc::<Routes>::clone(&routes),
            observer: Arc::<Counts>::clone(&counts),
            blocks_enabled: true,
            env: HostEnv {
                parent: BTreeMap::from([
                    (String::from("HOME"), String::from("/")),
                    (String::from("PATH"), String::from("/usr/bin")),
                ]),
                term: String::from("xterm-ghostty"),
                version: String::from("9.9.9"),
                shell: String::from("/bin/zsh"),
                agent_socket_path: Some(String::from("/tmp/hook.sock")),
                control_socket_path: Some(String::from("/tmp/ctl.sock")),
                ctl_binary_path: Some(String::from("/opt/slopdesk-ctl")),
            },
            ..HostParts::around(Arc::<Fork>::clone(&fork))
        });
        Bench {
            host,
            fork,
            store,
            journal,
            routes,
            counts,
            offload,
        }
    }

    /// A session id from one byte, so a test can name the same conversation twice.
    const fn session(id: u8) -> Uuid {
        let mut bytes = [0_u8; 16];
        bytes[0] = id;
        bytes
    }

    /// A `channelOpen` for `session` on `channel`, of the shell class.
    #[expect(
        clippy::unnecessary_box_returns,
        reason = "the entry point under test takes a `Box`, because that is what `MuxEvent::Opened` carries"
    )]
    fn open(channel: u32, session: Uuid) -> Box<ChannelOpen> {
        opened(channel, session, 0, 0)
    }

    #[expect(clippy::unnecessary_box_returns, reason = "as above")]
    /// The same, with the channel class and the client's last-received number named.
    fn opened(channel: u32, session: Uuid, class: u8, last_received_seq: i64) -> Box<ChannelOpen> {
        let wires = wires(channel);
        Box::new(ChannelOpen {
            channel_id: channel,
            session_id: session,
            last_received_seq,
            channel_class: class,
            initial_cwd: None,
            data: wires.data,
            data_inbound: wires.data_inbound,
            control: wires.control,
            control_inbound: wires.control_inbound,
        })
    }

    /// Files `pane` under `key` as the primary, the way a landed fresh spawn is filed.
    fn hold(host: &Arc<Host>, key: Key, pane: &Arc<Ghost>) {
        host.sessions().attach_primary(key, &as_pane(pane));
    }

    // ------------------------------------------------------------------------------- path B: fresh

    #[test]
    fn a_first_open_forks_a_login_shell_and_files_it_before_starting_it() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(7);
        bench.host.open_channel(open(3, id), &as_peer(&wire));

        let opened = bench.fork.opened();
        assert_eq!(opened.len(), 1, "one open, one fork");
        assert_eq!(opened[0].session, id);
        assert_eq!(opened[0].channel, 3);
        assert_eq!(opened[0].executable, "/bin/zsh");
        assert_eq!(opened[0].argv0, "-zsh", "a login shell, by its leading dash");
        // No `shell_integration` to assert: a mux channel is ALWAYS an interactive login shell, so
        // the field does not exist — see `Fresh`. The `argv0` above is what proves the shape.
        assert!(opened[0].blocks, "the shim went, so the block tap goes");

        let pane = bench.fork.made()[0].clone();
        assert_eq!(pane.starts(), 1, "started");
        assert!(
            bench
                .host
                .sessions()
                .pane(Key::new(wire.connection(), 3))
                .is_some(),
            "and filed — the FILE is what a first output byte needs to already have happened"
        );
        assert_eq!(wire.acks(), vec![(3, true, 0)]);
    }

    /// The start runs the drain, and the drain ships a restored transcript on the data link — the
    /// same link the ack rides. An ack behind the start can only reach the client behind the first
    /// frames of the restore, which the client then has to hold against a verdict it has not got.
    #[test]
    fn a_fresh_spawn_acks_before_it_starts_the_drain() {
        let bench = bench();
        let wire = Wire::on(1);
        let order = Arc::new(Mutex::new(Vec::new()));
        wire.journals(&order);
        bench.fork.journals(&order);
        bench.host.open_channel(open(3, session(7)), &as_peer(&wire));

        assert_eq!(wire.acks(), vec![(3, true, 0)]);
        assert_eq!(bench.fork.made()[0].starts(), 1);
        assert_eq!(
            *order.lock().unwrap_or_else(PoisonError::into_inner),
            vec![String::from("ack"), String::from("start")],
            "the verdict is on the wire before a byte of output can be"
        );
    }

    #[test]
    fn a_fresh_panes_environment_carries_its_own_id_and_not_the_orchestrator_sentinel() {
        let bench = bench();
        let wire = Wire::on(1);
        bench.host.open_channel(open(1, session(9)), &as_peer(&wire));

        let opened = bench.fork.opened();
        let env = &opened[0].env;
        assert_eq!(
            env.get("SLOPDESK_PANE_ID").map(String::as_str),
            Some("09000000-0000-0000-0000-000000000000"),
            "which pane this IS is the pane's own question, hook listener or not"
        );
        assert_eq!(
            env.get("SLOPDESK_SOCKET_PATH").map(String::as_str),
            Some("/tmp/hook.sock")
        );
        assert!(
            !env.contains_key("SLOPDESK_CTL"),
            "the sentinel says an ORCHESTRATOR made this pane, and a user opened this one"
        );
        assert!(
            !env.contains_key("SLOPDESK_CTL_BIN"),
            "and the binary path rides with the sentinel"
        );
        assert_eq!(env.get("TERM").map(String::as_str), Some("xterm-ghostty"));
    }

    #[test]
    fn a_fresh_pane_lands_in_a_real_directory_and_seeds_its_project_from_that_one() {
        let bench = bench();
        let wire = Wire::on(1);
        let mut asked = open(1, session(3));
        // A directory that is not there. `resolve_cwd` repairs it to HOME rather than refusing —
        // and the seed has to quote the REPAIRED answer, or the pane sits outside every project
        // section until an OSC-7 edge an unshimmed shell never sends.
        asked.initial_cwd = Some(String::from("/no/such/place/at/all"));
        bench.host.open_channel(asked, &as_peer(&wire));

        let opened = bench.fork.opened();
        assert_eq!(opened[0].cwd.as_deref(), Some("/"), "repaired to HOME");
        assert_eq!(
            opened[0].env.get("PWD").map(String::as_str),
            Some("/"),
            "PWD names where the child LANDS, not what it asked for"
        );
        assert_eq!(
            bench.fork.made()[0].seeded(),
            vec![String::from("/")],
            "and the By-Project seed quotes the same answer"
        );
    }

    #[test]
    fn a_fresh_pane_is_seeded_after_its_relay_starts() {
        let bench = bench();
        bench
            .host
            .open_channel(open(1, session(3)), &as_peer(&Wire::on(1)));
        let pane = bench.fork.made()[0].clone();
        assert_eq!(pane.starts(), 1);
        assert_eq!(
            pane.seeded().len(),
            1,
            "the seed enqueues a control message, so it has to ride a live sender"
        );
    }

    #[test]
    fn a_fresh_pane_registers_its_hook_route_under_its_env_baked_id() {
        let bench = bench();
        bench
            .host
            .open_channel(open(1, session(5)), &as_peer(&Wire::on(1)));
        assert_eq!(
            bench.routes.bound(),
            vec![String::from("05000000-0000-0000-0000-000000000000")],
            "the id the agent's POSTs will carry, never the composite channel key"
        );
    }

    #[test]
    fn a_zero_sentinel_open_is_never_journaled_and_never_restored() {
        let bench = bench();
        bench
            .host
            .open_channel(open(1, NEW_SESSION_ID), &as_peer(&Wire::on(1)));

        let opened = bench.fork.opened();
        assert!(
            !opened[0].journal,
            "a sentinel can never be re-presented, so journalling it makes an orphan file"
        );
        assert!(
            bench.journal.restores().is_empty(),
            "and there is nothing to restore"
        );
    }

    #[test]
    fn a_cold_client_with_a_real_id_restores_before_the_fork_that_appends_to_it() {
        let bench = bench();
        *bench.journal.restorable.lock().unwrap() = Some(Restored {
            bytes: b"a prior life".to_vec(),
            snapshot_composed: true,
        });
        let id = session(11);
        bench.host.open_channel(open(1, id), &as_peer(&Wire::on(1)));

        assert_eq!(
            bench.journal.restores(),
            vec![id],
            "read BEFORE the fork: superd appends the new shell's output under the same id"
        );
        let opened = bench.fork.opened();
        assert_eq!(
            opened[0].restored,
            Some(12),
            "and the bytes reach the pane that will hold them"
        );
        assert!(opened[0].journal);
    }

    #[test]
    fn a_warm_client_reopening_a_real_id_is_not_restored() {
        let bench = bench();
        *bench.journal.restorable.lock().unwrap() = Some(Restored::default());
        // A client that has already received frames has the history on its own screen; replaying
        // the journal under it would print everything twice.
        bench
            .host
            .open_channel(opened(1, session(11), 0, 42), &as_peer(&Wire::on(1)));
        assert!(bench.journal.restores().is_empty());
    }

    #[test]
    fn a_take_over_resume_point_is_computed_before_the_fork_that_decides_whether_to_use_it() {
        let bench = bench();
        *bench.journal.takeover.lock().unwrap() = 4096;
        bench
            .host
            .open_channel(open(1, session(2)), &as_peer(&Wire::on(1)));
        assert_eq!(
            bench.fork.opened()[0].resume_takeover,
            4096,
            "the value depends on the transcript, not on the fork — so the fork decides only WHICH"
        );
    }

    #[test]
    fn a_fresh_pane_takes_its_own_connections_size_passivity() {
        let bench = bench();
        let wire = Wire::on(2);
        bench.host.set_size_passive(wire.connection(), true);
        bench.host.open_channel(open(1, session(3)), &as_peer(&wire));
        assert!(
            bench.fork.opened()[0].size_passive,
            "read at the FORK, so the pane's first fold already knows what kind of client it has"
        );
    }

    #[test]
    fn a_fork_that_refuses_leaves_no_pane_no_route_and_a_refused_channel() {
        let bench = bench();
        let wire = Wire::on(1);
        bench.fork.refuses("no pty");
        bench.host.open_channel(open(4, session(1)), &as_peer(&wire));

        assert_eq!(wire.acks(), vec![(4, false, 0)]);
        assert_eq!(bench.host.sessions().member_count(), 0);
        assert!(bench.routes.bound().is_empty(), "no pane, no route to file");
        assert!(
            bench.journal.deletes().is_empty(),
            "and nothing to unwind on disk: superd opens the journal as part of forking"
        );
    }

    #[test]
    fn a_stop_that_lands_during_the_fork_still_refuses_and_ends_the_child() {
        let bench = bench();
        let wire = Wire::on(1);
        let host = Arc::clone(&bench.host);
        bench.fork.during(move || host.mark_stopping());
        bench.host.open_channel(open(2, session(1)), &as_peer(&wire));

        assert_eq!(wire.acks(), vec![(2, false, 0)]);
        assert_eq!(
            bench.host.sessions().member_count(),
            0,
            "never filed past the drain"
        );
        assert_eq!(
            bench.fork.made()[0].shutdowns(),
            1,
            "the child is already forked, so refusing means ENDING it"
        );
    }

    #[test]
    fn a_stopping_host_refuses_an_open_without_forking() {
        let bench = bench();
        let wire = Wire::on(1);
        bench.host.mark_stopping();
        bench.host.open_channel(open(2, session(1)), &as_peer(&wire));
        assert_eq!(wire.acks(), vec![(2, false, 0)]);
        assert!(
            bench.fork.opened().is_empty(),
            "never fork a PTY that outlives the daemon"
        );
    }

    // --------------------------------------------------------------------------------- the routes

    #[test]
    fn a_duplicate_open_on_a_held_key_is_re_acked_rather_than_forked_again() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(6);
        hold(&bench.host, Key::new(wire.connection(), 1), &Ghost::new(id));

        bench.host.open_channel(open(1, id), &as_peer(&wire));
        assert_eq!(wire.acks(), vec![(1, true, 0)]);
        assert!(
            bench.fork.opened().is_empty(),
            "one openpty + fork per session id, EVER — a retransmit must not make a second"
        );
    }

    #[test]
    fn a_channel_class_this_host_does_not_serve_is_declined_rather_than_guessed_at() {
        let bench = bench();
        let wire = Wire::on(1);
        bench
            .host
            .open_channel(opened(1, session(1), 99, 0), &as_peer(&wire));
        assert_eq!(wire.acks(), vec![(1, false, 0)]);
        assert!(
            bench.fork.opened().is_empty(),
            "falling through would hand a peer one version ahead a shell it never asked for"
        );
    }

    #[test]
    fn a_workspace_class_open_crosses_to_its_own_door_and_never_touches_a_pane() {
        let workspace = Arc::new(Workspace::default());
        let bench = bench_with(Arc::<Workspace>::clone(&workspace));
        let wire = Wire::on(1);
        // Class 1 is the workspace channel — no PTY, no join, no claim, no transcript.
        bench
            .host
            .open_channel(opened(1, session(1), 1, 0), &as_peer(&wire));

        assert_eq!(workspace.taken.load(Ordering::SeqCst), 1);
        assert!(wire.acks().is_empty(), "the door that took it owns the ack");
        assert!(bench.fork.opened().is_empty());
    }

    #[test]
    fn a_host_that_serves_no_workspace_channels_refuses_one_rather_than_dropping_it() {
        let bench = bench();
        let wire = Wire::on(1);
        bench
            .host
            .open_channel(opened(1, session(1), 1, 0), &as_peer(&wire));
        assert_eq!(
            wire.acks(),
            vec![(1, false, 0)],
            "a dropped open with no ack hangs the client until its own timeout"
        );
    }

    // -------------------------------------------------------------------------------- path D: join

    #[test]
    fn a_second_connection_on_a_live_id_joins_the_same_pane_rather_than_forking_one() {
        let bench = bench();
        let incumbent = Wire::on(1);
        let joiner = Wire::on(2);
        let id = session(8);
        let pane = Ghost::new(id);
        hold(&bench.host, Key::new(incumbent.connection(), 1), &pane);

        bench.host.open_channel(open(5, id), &as_peer(&joiner));

        assert!(
            bench.fork.opened().is_empty(),
            "a pane is SHARED, never duplicated"
        );
        assert_eq!(pane.joins().len(), 1);
        assert_eq!(
            wire_first(&joiner),
            (5, true, 0),
            "ack FIRST — the joiner is current from here on, so its own number rides back"
        );
        assert_eq!(bench.host.sessions().member_count(), 2, "two keys, one pane");
    }

    #[test]
    fn a_joining_key_and_its_subscriber_are_filed_as_one_record_before_the_join_runs() {
        let bench = bench();
        let incumbent = Wire::on(1);
        let joiner = Wire::on(2);
        let id = session(8);
        let pane = Ghost::new(id);
        hold(&bench.host, Key::new(incumbent.connection(), 1), &pane);

        bench.host.open_channel(open(5, id), &as_peer(&joiner));

        let reserved = pane.joins()[0].0;
        assert_ne!(
            reserved, PRIMARY_SUBSCRIBER,
            "a key filed without its subscriber resolves to the PRIMARY, which would retire the incumbent \
             when the joiner's link died"
        );
        assert_eq!(
            bench
                .host
                .sessions()
                .subscriber_of(Key::new(joiner.connection(), 5)),
            reserved,
            "and the table already names it, so a third concurrent open routes here too"
        );
    }

    #[test]
    fn a_join_that_refuses_retires_its_own_reservation_and_unfiles_its_own_key() {
        let bench = bench();
        let incumbent = Wire::on(1);
        let joiner = Wire::on(2);
        let id = session(8);
        let pane = Ghost::new(id);
        hold(&bench.host, Key::new(incumbent.connection(), 1), &pane);
        pane.refuse_joins();

        bench.host.open_channel(open(5, id), &as_peer(&joiner));

        let reserved = pane.joins()[0].0;
        assert_eq!(
            pane.retired_contributors(),
            vec![reserved],
            "a workspace subscribe landing mid-join files the reservation as a size contributor, and a \
             phantom would clamp this pane for ever with no window behind it"
        );
        assert_eq!(
            bench.host.sessions().member_count(),
            1,
            "and the incumbent is untouched"
        );
        assert_eq!(
            joiner.acks(),
            vec![(5, true, 0), (5, false, 0)],
            "the refusal supersedes"
        );
    }

    #[test]
    fn a_join_takes_the_joining_connections_own_size_passivity() {
        let bench = bench();
        let incumbent = Wire::on(1);
        let joiner = Wire::on(2);
        let id = session(8);
        let pane = Ghost::new(id);
        hold(&bench.host, Key::new(incumbent.connection(), 1), &pane);
        // A phone mirroring a Mac's pane must not clamp it to a phone's grid.
        bench.host.set_size_passive(joiner.connection(), true);

        bench.host.open_channel(open(5, id), &as_peer(&joiner));
        assert!(pane.joins()[0].1, "the JOINER's answer, not the incumbent's");
    }

    #[test]
    fn a_zero_sentinel_never_joins_a_live_pane() {
        let bench = bench();
        let incumbent = Wire::on(1);
        let joiner = Wire::on(2);
        let pane = Ghost::new(NEW_SESSION_ID);
        hold(&bench.host, Key::new(incumbent.connection(), 1), &pane);

        bench
            .host
            .open_channel(open(5, NEW_SESSION_ID), &as_peer(&joiner));
        assert!(
            pane.joins().is_empty(),
            "the sentinel is not an identity, so it names nobody"
        );
        assert_eq!(bench.fork.opened().len(), 1, "it gets its own shell");
    }

    // ---------------------------------------------------------------------------- path A: reattach

    #[test]
    fn a_returning_client_claims_its_parked_pane_and_never_forks_a_second_one() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(4);
        let pane = Ghost::new(id);
        bench.store.insert(&as_pane(&pane), None);

        bench.host.open_channel(opened(2, id, 0, 9), &as_peer(&wire));

        assert!(bench.fork.opened().is_empty());
        assert_eq!(pane.rebinds(), 1);
        assert!(
            !bench.store.contains(id),
            "the claim REMOVED it — never two owners"
        );
        assert!(
            bench
                .host
                .sessions()
                .pane(Key::new(wire.connection(), 2))
                .is_some(),
            "and the table names it under the returning client's key"
        );
    }

    #[test]
    fn a_reattach_acks_the_clamped_resume_point_before_it_replays_a_byte() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(4);
        let pane = Ghost::new(id);
        // The client claims 4000; this pane has only ever numbered up to 12. Replaying "after 4000"
        // out of that buffer selects nothing, so an adopted pane would come back blank.
        pane.set_head(12);
        bench.store.insert(&as_pane(&pane), None);

        bench.host.open_channel(opened(2, id, 0, 4000), &as_peer(&wire));

        assert_eq!(
            wire.acks()[0],
            (2, true, 12),
            "clamped to what this pane can number"
        );
        assert_eq!(
            pane.replays(),
            vec![12],
            "and the replay quotes the VERDICT, not the client's own number"
        );
    }

    #[test]
    fn a_reattach_replays_before_it_rebinds() {
        let bench = bench();
        let id = session(4);
        let pane = Ghost::new(id);
        bench.store.insert(&as_pane(&pane), None);
        bench
            .host
            .open_channel(opened(2, id, 0, 3), &as_peer(&Wire::on(1)));
        assert_eq!(pane.replays().len(), 1);
        assert_eq!(
            pane.rebinds(),
            1,
            "the rebind starts the live drain, so live output would interleave with the replay"
        );
    }

    #[test]
    fn a_reattach_re_resolves_size_passivity_for_the_connection_it_now_rides() {
        let bench = bench();
        let wire = Wire::on(2);
        let id = session(4);
        let pane = Ghost::new(id);
        bench.store.insert(&as_pane(&pane), None);
        bench.host.set_size_passive(wire.connection(), true);

        bench.host.open_channel(opened(2, id, 0, 1), &as_peer(&wire));
        assert_eq!(
            pane.contributors(),
            vec![(PRIMARY_SUBSCRIBER, true)],
            "the returning device may not be the one that left — a Mac's pane on a phone"
        );
    }

    #[test]
    fn only_a_cold_client_on_a_collapsed_replay_earns_the_jiggle() {
        // A rendered SNAPSHOT needs no jiggle whatever the client's warmth — every row the app
        // believes painted IS painted. A WARM client kept its own grid. Only the third combination
        // hands a differential renderer a partial frame it will refuse to finish.
        for (last_seq, composed, jiggle) in [(0_i64, false, true), (0, true, false), (7, false, false)] {
            let bench = bench();
            let id = session(4);
            let pane = Ghost::new(id);
            if composed {
                pane.compose_snapshots();
            }
            bench.store.insert(&as_pane(&pane), None);
            bench
                .host
                .open_channel(opened(2, id, 0, last_seq), &as_peer(&Wire::on(1)));

            assert_eq!(
                pane.redraws(),
                vec![jiggle],
                "a differential renderer ignores a same-size SIGWINCH for rows it believes are painted, so \
                 only a cold client on a collapsed replay needs the real size change"
            );
            assert_eq!(
                bench.offload.delays(),
                vec![Duration::from_millis(200)],
                "and it waits for the client's first resize to land"
            );
        }
    }

    #[test]
    fn a_rebind_that_refuses_re_parks_the_pane_rather_than_stranding_it() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(4);
        let pane = Ghost::new(id);
        pane.refuse_rebinds();
        bench.store.insert(&as_pane(&pane), None);

        bench.host.open_channel(opened(2, id, 0, 1), &as_peer(&wire));

        assert!(
            bench.store.contains(id),
            "the claim already removed it, so unfiling alone would leave a live shell in NO table and NO \
             store — unreachable by stop, TTL, kill and every future reconnect, for ever"
        );
        assert_eq!(bench.host.sessions().member_count(), 0);
        assert_eq!(pane.shutdowns(), 0, "tmux semantics: the running agent survives");
        assert_eq!(wire.acks(), vec![(2, true, 0), (2, false, 0)]);
    }

    #[test]
    fn a_rebind_that_refuses_on_a_dead_child_reaps_it_and_drops_its_route() {
        let bench = bench();
        let id = session(4);
        let pane = Ghost::new(id);
        pane.set_present(true);
        pane.die_during_rebind();
        bench.host.sessions().register_hook(&as_pane(&pane), "route-4");
        bench.store.insert(&as_pane(&pane), None);

        bench
            .host
            .open_channel(opened(2, id, 0, 1), &as_peer(&Wire::on(1)));

        assert!(!bench.store.contains(id), "nothing left to park");
        assert_eq!(pane.shutdowns(), 1);
        assert_eq!(
            bench.routes.unbound(),
            vec![String::from("route-4")],
            "a non-deliberate end of life reached OUTSIDE the close ladder still drops the route"
        );
        assert!(
            bench.journal.deletes().is_empty(),
            "but KEEPS the transcript: a reconnect may still cold-restore it"
        );
    }

    #[test]
    fn a_reattach_re_points_the_hook_route_at_the_same_original_pane_id() {
        let bench = bench();
        let id = session(4);
        let pane = Ghost::new(id);
        bench.host.sessions().register_hook(&as_pane(&pane), "route-4");
        bench.store.insert(&as_pane(&pane), None);

        bench
            .host
            .open_channel(opened(2, id, 0, 1), &as_peer(&Wire::on(1)));
        assert_eq!(
            bench.routes.bound(),
            vec![String::from("route-4")],
            "the ENV-BAKED id, never the new composite key — the agent's POSTs carry the old one, and a \
             per-reattach key would leak one dead sink per wifi flap"
        );
    }

    #[test]
    fn a_pane_whose_hooks_were_off_at_spawn_gains_no_route_on_reattach() {
        let bench = bench();
        let id = session(4);
        let pane = Ghost::new(id);
        bench.store.insert(&as_pane(&pane), None);
        bench
            .host
            .open_channel(opened(2, id, 0, 1), &as_peer(&Wire::on(1)));
        assert!(
            bench.routes.bound().is_empty(),
            "nothing to refresh is not something to invent"
        );
    }

    #[test]
    fn a_claim_that_finds_a_dead_child_clears_its_status_and_spawns_fresh_under_the_same_id() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(4);
        let dead = Ghost::new(id);
        dead.set_present(true);
        dead.kill_child();
        bench.host.sessions().register_hook(&as_pane(&dead), "route-4");
        bench.store.insert(&as_pane(&dead), None);

        bench.host.open_channel(opened(2, id, 0, 1), &as_peer(&wire));

        assert_eq!(
            bench.routes.unbound(),
            vec![String::from("route-4")],
            "dropped BEFORE the fresh spawn re-registers the same id"
        );
        assert_eq!(bench.fork.opened().len(), 1);
        assert!(
            bench.journal.deletes().is_empty(),
            "the journal is NOT released: the same-id fresh spawn rotates it, which is what keeps the \
             transcript file continuous"
        );
        assert_eq!(wire.acks(), vec![(2, true, 0)]);
    }

    #[test]
    fn a_host_with_no_detached_store_spawns_fresh_rather_than_looking_for_a_parked_pane() {
        let fork = Arc::new(Fork::default());
        let host = Host::assemble(HostParts {
            offload: Arc::new(Inline::default()),
            ..HostParts::around(Arc::<Fork>::clone(&fork))
        });
        let wire = Wire::on(1);
        host.open_channel(opened(2, session(4), 0, 5), &as_peer(&wire));
        assert_eq!(fork.opened().len(), 1);
        assert_eq!(wire.acks(), vec![(2, true, 0)]);
    }

    // ---------------------------------------------------------------------------------- the close

    #[test]
    fn a_close_takes_every_key_that_names_the_pane_not_just_the_one_that_asked() {
        let bench = bench();
        let id = session(2);
        let pane = Ghost::new(id);
        let one = Key::new(Wire::on(1).connection(), 1);
        let two = Key::new(Wire::on(2).connection(), 1);
        hold(&bench.host, one, &pane);
        bench.host.sessions().attach(two, &as_pane(&pane), 7);

        bench.host.close_channel(one);

        assert_eq!(
            bench.host.sessions().member_count(),
            0,
            "leaving N−1 behind keeps a dead pane in list-panes, re-shut by stop, and read as \
             still-attached by the rebind recovery"
        );
        assert_eq!(pane.shutdowns(), 1);
    }

    #[test]
    fn a_deliberate_close_takes_the_panes_transcript_with_it() {
        let bench = bench();
        let id = session(2);
        let pane = Ghost::new(id);
        let key = Key::new(Wire::on(1).connection(), 1);
        hold(&bench.host, key, &pane);

        bench.host.close_channel(key);
        assert_eq!(bench.journal.deletes(), vec![id]);
    }

    #[test]
    fn a_close_racing_the_daemon_stop_keeps_the_journal_the_restart_will_restore() {
        let bench = bench();
        let id = session(2);
        let pane = Ghost::new(id);
        let key = Key::new(Wire::on(1).connection(), 1);
        hold(&bench.host, key, &pane);
        bench.host.mark_stopping();

        bench.host.close_channel(key);
        assert!(bench.journal.deletes().is_empty());
        assert_eq!(pane.shutdowns(), 1, "the pane still ends; only the file survives");
    }

    #[test]
    fn closing_a_key_twice_is_a_no_op_rather_than_a_second_count_and_a_second_fan() {
        let bench = bench();
        let pane = Ghost::new(session(2));
        pane.set_present(true);
        let key = Key::new(Wire::on(1).connection(), 1);
        hold(&bench.host, key, &pane);

        bench.host.close_channel(key);
        let after_first = bench.counts.seen().len();
        bench.host.close_channel(key);

        assert_eq!(
            bench.counts.seen().len(),
            after_first,
            "the peer-close and the child-exit path both land here for one pane"
        );
        assert_eq!(pane.shutdowns(), 1);
    }

    #[test]
    fn closing_a_pane_that_carried_an_agent_publishes_a_final_clearing_transition() {
        let bench = bench();
        let pane = Ghost::new(session(2));
        pane.set_present(true);
        pane.set_status("working", Some("thinking"));
        let key = Key::new(Wire::on(1).connection(), 1);
        hold(&bench.host, key, &pane);

        let seen = Arc::new(support::Evictions::default());
        drop(seen);
        bench.host.close_channel(key);
        // The fan itself is D.6.1's and asserted there; what this pins is that the CLOSE is one of
        // the paths that fires it — a pane closed mid-turn never delivers its own clearing edge,
        // and the daemon's working aggregate would hold a dead id and keep the Mac awake for ever.
        assert_eq!(pane.shutdowns(), 1);
        assert!(!bench.host.sessions().is_attached(&as_pane(&pane)));
    }

    #[test]
    fn an_exiting_shell_closes_its_own_channel_and_leaves_the_other_members_alone() {
        let bench = bench();
        let wire = Wire::on(1);
        let id = session(4);
        let pane = Ghost::new(id);
        bench.store.insert(&as_pane(&pane), None);
        bench.host.open_channel(opened(2, id, 0, 1), &as_peer(&wire));

        pane.exit_rebound();

        assert_eq!(
            bench.host.sessions().member_count(),
            0,
            "the exit closure closes the COMPOSITE key the rebind wired it to"
        );
        assert_eq!(
            bench.journal.deletes(),
            vec![id],
            "an attached child exit is deliberate"
        );
    }

    // ----------------------------------------------------------------------------- the parked exit

    #[test]
    fn a_parked_pane_whose_child_dies_is_removed_ended_and_unrouted() {
        let bench = bench();
        let id = session(4);
        let pane = Ghost::new(id);
        pane.refuse_rebinds();
        bench.host.sessions().register_hook(&as_pane(&pane), "route-4");
        bench.store.insert(&as_pane(&pane), None);
        // Claim it, fail the rebind, and let the recovery re-park it — which is the only path that
        // installs the parked handler.
        bench
            .host
            .open_channel(opened(2, id, 0, 1), &as_peer(&Wire::on(1)));
        assert!(bench.store.contains(id));

        pane.exit_parked();

        assert!(!bench.store.contains(id), "no zombie entry");
        assert_eq!(pane.shutdowns(), 1);
        assert_eq!(bench.routes.unbound(), vec![String::from("route-4")]);
        assert!(
            bench.journal.deletes().is_empty(),
            "and the transcript stays: a reconnect may still cold-restore it"
        );
    }

    #[test]
    fn a_parked_exit_that_lands_after_a_claim_stands_down_instead_of_tearing_down_twice() {
        let bench = bench();
        let id = session(4);
        let pane = Ghost::new(id);
        pane.refuse_rebinds();
        bench.host.sessions().register_hook(&as_pane(&pane), "route-4");
        bench.store.insert(&as_pane(&pane), None);
        bench
            .host
            .open_channel(opened(2, id, 0, 1), &as_peer(&Wire::on(1)));

        // Somebody else takes the entry first — a second reconnect, a TTL, a drain.
        assert!(bench.store.remove(id));
        pane.exit_parked();

        assert_eq!(
            pane.shutdowns(),
            0,
            "the handler can fire seconds late, and running the per-id teardown anyway would release the \
             journal writer and the hook route a successor re-registered"
        );
        assert!(bench.routes.unbound().is_empty());
    }

    // ------------------------------------------------------------------------------- the counts

    #[test]
    fn a_connection_count_is_published_on_every_ladder_that_moved_a_registration() {
        let bench = bench();
        let first = Wire::on(1);
        let second = Wire::on(2);
        let id = session(3);
        bench.host.open_channel(open(1, id), &as_peer(&first));
        assert_eq!(bench.counts.seen(), vec![1], "one connection holds a pane");

        bench.host.open_channel(open(1, id), &as_peer(&second));
        assert_eq!(
            bench.counts.seen(),
            vec![1, 2],
            "and now two do, over the same pane"
        );

        bench.host.close_channel(Key::new(second.connection(), 1));
        assert_eq!(bench.counts.seen(), vec![1, 2, 0], "a reap takes BOTH keys");
    }

    #[test]
    fn a_refused_open_publishes_no_count_at_all() {
        let bench = bench();
        bench.fork.refuses("no pty");
        bench
            .host
            .open_channel(open(1, session(3)), &as_peer(&Wire::on(1)));
        assert!(bench.counts.seen().is_empty());
    }

    // ------------------------------------------------------------------------- the size table

    #[test]
    fn a_connections_size_passivity_is_forgotten_when_the_connection_is() {
        let host = Host::assemble(HostParts::around(Arc::new(Fork::default())));
        let connection = session(1);
        assert!(
            !host.size_passive(connection),
            "a client that never said is ACTIVE"
        );
        host.set_size_passive(connection, true);
        assert!(host.size_passive(connection));
        host.forget_connection(connection);
        assert!(
            !host.size_passive(connection),
            "a table keyed by connection id leaks one entry per reconnect otherwise"
        );
    }

    #[test]
    fn a_silent_host_publishes_nothing_and_a_hookless_one_binds_nothing() {
        let fork = Arc::new(Fork::default());
        let host = Host::assemble(HostParts {
            observer: Arc::new(Silent),
            offload: Arc::new(Inline::default()),
            ..HostParts::around(Arc::<Fork>::clone(&fork))
        });
        let wire = Wire::on(1);
        host.open_channel(open(1, session(3)), &as_peer(&wire));
        assert_eq!(wire.acks(), vec![(1, true, 0)], "and the ladder still lands");
        assert_eq!(fork.opened().len(), 1);
    }

    /// The first ack a wire was given — the one the ORDER assertions are about.
    fn wire_first(wire: &Arc<Wire>) -> (u32, bool, i64) {
        wire.acks()[0]
    }
}
