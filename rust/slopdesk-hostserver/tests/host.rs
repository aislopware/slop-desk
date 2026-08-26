//! The live [`Host`]: the three pane sources, the kill ladder, the spawn resolution, and the
//! cross-pane fan-out.
//!
//! D.5's suite drove the eleven verbs against a `ControlHost` that was a fixture. This one drives
//! the real thing — the registry D.1 carved, the store D.1 carved, and the observer table that had
//! no Rust at all until now — with only the FORK behind a seam. That split is the file's whole
//! design: everything a spawn DECIDES (the environment, the executable, the `argv[0]`, whether the
//! shell-integration shim goes on, what order the pane is filed in) is asserted here without a PTY,
//! and what is left for the spawner is `posix_spawn` and six threads.
//!
//! Four of these tests are about something that leaks rather than something that breaks. A `kill`
//! that misses one aliasing key leaves a dead pane in `list-panes` for ever; one that skips the
//! teardown fan leaves a `working` row in every client and an `IOPMAssertion` held for the whole of
//! the daemon's life; one that retires the hook route anywhere but here leaks a key per spawned
//! pane. None of them would fail a test that only asked whether the pane died.

pub mod support;

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Map, Value, json};
use slopdesk_hostserver::control::{AgentStatusEvent, AgentStatusTap, ControlHost, SpawnRefused};
use slopdesk_hostserver::host::{HostEnv, SessionIds, Spawner, Standalone, Transcripts};
use slopdesk_hostserver::{DetachedStore, Host, IgnoreEvictions, Pane};
use slopdesk_hostsession::{SessionObserver, StatusObserver};
use slopdesk_ids::uuid_text;
use slopdesk_muxsession::registry::{Key, Uuid};
use support::{Ghost, Now, as_pane};

#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a test asserts by panicking, and a fixture it built itself is not a runtime input"
)]
mod suite {
    use super::*;

    // ------------------------------------------------------------------------------- the fakes

    /// Ids from a counter, so a `spawn`'s answer is something a test can assert.
    ///
    /// The seam exists for exactly this: `SystemIds` reads `/dev/urandom`, and a suite that had to
    /// accept sixteen different bytes every run could only assert that SOMETHING came back.
    #[derive(Debug, Default)]
    struct Counter {
        next: AtomicU64,
    }

    impl SessionIds for Counter {
        fn mint(&self) -> Option<Uuid> {
            let mut raw = [0_u8; 16];
            raw[15] = u8::try_from(self.next.fetch_add(1, Ordering::SeqCst) + 1).unwrap_or(255);
            Some(raw)
        }
    }

    /// An id source that has none — the `/dev/urandom` that would not read.
    #[derive(Debug)]
    struct NoIds;

    impl SessionIds for NoIds {
        fn mint(&self) -> Option<Uuid> {
            None
        }
    }

    /// Every transcript the host asked to be forgotten.
    #[derive(Debug, Default)]
    struct Deletions {
        seen: Mutex<Vec<Uuid>>,
    }

    impl Deletions {
        fn seen(&self) -> Vec<Uuid> {
            self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl Transcripts for Deletions {
        fn delete(&self, session: Uuid) {
            self.seen
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(session);
        }
    }

    /// One spawn as the spawner was asked for it — every decision the host made, kept.
    #[derive(Debug, Clone)]
    struct Asked {
        session: Uuid,
        executable: String,
        argv: Vec<String>,
        argv0: String,
        env: BTreeMap<String, String>,
        cwd: Option<String>,
        rows: u16,
        cols: u16,
        shell_integration: bool,
        blocks: bool,
    }

    /// The pair a spawn is handed: the exit route and the status route. Both are held so a test can
    /// fire the edges a real PTY would.
    type Wired = (Arc<dyn SessionObserver>, Arc<dyn StatusObserver>);

    /// A spawner that forks nothing and remembers everything.
    #[derive(Default)]
    struct Fork {
        asked: Mutex<Vec<Asked>>,
        /// The panes it handed back, in order.
        made: Mutex<Vec<Arc<Ghost>>>,
        /// The two observers the last spawn was given, so a test can fire them.
        wired: Mutex<Option<Wired>>,
        /// Answered instead of a pane, when set.
        refuse: Mutex<Option<SpawnRefused>>,
        /// Run just before the pane is handed back — the window a `stop()` has to survive.
        during: Mutex<Option<Box<dyn Fn() + Send>>>,
        started: Mutex<Vec<(Uuid, Option<String>)>>,
    }

    impl Fork {
        fn asked(&self) -> Vec<Asked> {
            self.asked.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn made(&self) -> Vec<Arc<Ghost>> {
            self.made.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }

        fn started(&self) -> Vec<(Uuid, Option<String>)> {
            self.started
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
        }

        /// Fires the exit the way the session's exit thread would.
        fn exit(&self) {
            let held = self.wired.lock().unwrap_or_else(PoisonError::into_inner).clone();
            if let Some((exit, _)) = held {
                exit.exited(0);
            }
        }

        /// Fires a status transition the way a detector fold would.
        fn moved(&self, status: slopdesk_agent::ClaudeStatus) {
            let held = self.wired.lock().unwrap_or_else(PoisonError::into_inner).clone();
            if let Some((_, status_observer)) = held {
                status_observer.status_changed(status, false);
            }
        }
    }

    // Hand-written because one field is a closure, and `Spawner` needs `Debug`.
    impl core::fmt::Debug for Fork {
        fn fmt(&self, out: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
            out.debug_struct("Fork")
                .field("asked", &self.asked)
                .finish_non_exhaustive()
        }
    }

    impl Spawner for Fork {
        fn spawn(&self, request: &Standalone<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            self.asked
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Asked {
                    session: request.session,
                    executable: request.executable.clone(),
                    argv: request.argv.clone(),
                    argv0: request.argv0.clone(),
                    env: request.env.clone(),
                    cwd: request.cwd.map(str::to_owned),
                    rows: request.rows,
                    cols: request.cols,
                    shell_integration: request.shell_integration,
                    blocks: request.blocks,
                });
            // Cloned out of the guard and the guard dropped, rather than scrutinised in place: a
            // lock held across the arm is exactly what makes a fake deadlock against the host.
            let refusal = self.refuse.lock().unwrap_or_else(PoisonError::into_inner).clone();
            if let Some(refusal) = refusal {
                return Err(refusal);
            }
            *self.wired.lock().unwrap_or_else(PoisonError::into_inner) =
                Some((Arc::clone(&request.exit), Arc::clone(&request.status)));
            let pane = Ghost::new(request.session);
            self.made
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(Arc::clone(&pane));
            // Taken rather than borrowed, for the reason above and one more: it fires ONCE, so a
            // hook that stops the host cannot also stop the retry a later test makes.
            let during = self.during.lock().unwrap_or_else(PoisonError::into_inner).take();
            if let Some(act) = during {
                act();
            }
            Ok(as_pane(&pane))
        }

        fn start(&self, pane: &Arc<dyn Pane>, cwd: Option<&str>) {
            self.started
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push((pane.id(), cwd.map(str::to_owned)));
        }

        fn open(&self, _request: slopdesk_hostserver::Fresh<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            // The CHANNEL ladders, which `tests/channel.rs` drives. This suite is the standalone
            // half, and a fork it never asks for answering anything but a refusal would be a fake
            // pretending to a reach it does not have.
            Err(SpawnRefused(String::from(
                "this suite drives the standalone ladder",
            )))
        }

        fn adopt(&self, _request: slopdesk_hostserver::Adopted<'_>) -> Result<Arc<dyn Pane>, SpawnRefused> {
            // The ADOPTION ladder, which `tests/adopt.rs` drives. Refused for `open`'s reason.
            Err(SpawnRefused(String::from(
                "this suite drives the standalone ladder",
            )))
        }
    }

    /// Every transition the cross-pane stream published.
    #[derive(Debug, Default)]
    struct Watcher {
        seen: Mutex<Vec<AgentStatusEvent>>,
    }

    impl Watcher {
        fn seen(&self) -> Vec<AgentStatusEvent> {
            self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
        }
    }

    impl AgentStatusTap for Watcher {
        fn changed(&self, event: &AgentStatusEvent) {
            self.seen
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(event.clone());
        }
    }

    // ----------------------------------------------------------------------------- the harness

    /// The environment every spawn in this file is built from.
    fn env() -> HostEnv {
        HostEnv {
            parent: [
                (String::from("HOME"), String::from("/Users/tester")),
                (String::from("PATH"), String::from("/usr/bin")),
                (String::from("SHELL"), String::from("/bin/zsh")),
            ]
            .into_iter()
            .collect(),
            term: String::from("xterm-ghostty"),
            version: String::from("9.9.9"),
            shell: String::from("/bin/zsh"),
            agent_socket_path: Some(String::from("/tmp/hook.sock")),
            control_socket_path: Some(String::from("/tmp/ctl.sock")),
            ctl_binary_path: Some(String::from("/opt/slopdesk-ctl")),
        }
    }

    /// A host with retention on, a counted id source and a transcript ledger.
    fn host() -> (Arc<Host>, Arc<Fork>, Arc<Deletions>) {
        let fork = Arc::new(Fork::default());
        let gone = Arc::new(Deletions::default());
        let store = Arc::new(DetachedStore::with(
            None,
            Arc::new(Now),
            Arc::new(IgnoreEvictions),
        ));
        let host = Host::with(
            Arc::<Fork>::clone(&fork),
            Some(store),
            env(),
            true,
            Arc::new(Counter::default()),
            Arc::<Deletions>::clone(&gone),
        );
        (host, fork, gone)
    }

    /// A connection id from one byte, so a test can name two without spelling thirty-two.
    const fn conn(id: u8) -> Uuid {
        let mut bytes = [0_u8; 16];
        bytes[15] = id;
        bytes
    }

    /// A pane under a one-byte session id, as `list-panes` will name it.
    fn named(id: u8) -> (Arc<Ghost>, String) {
        let ghost = Ghost::numbered(id);
        let text = uuid_text(ghost.id());
        (ghost, text)
    }

    // ------------------------------------------------------------------------------ list-panes

    /// The DETACHED source is the one that gets forgotten, and forgetting it makes exactly the pane
    /// an orchestrator is reattaching to invisible in the one API that describes panes.
    #[test]
    fn every_one_of_the_three_sources_is_listed() {
        let (host, _fork, _gone) = host();
        let (mux, mux_id) = named(1);
        let (ctl, ctl_id) = named(2);
        let (parked, parked_id) = named(3);
        host.sessions()
            .attach_primary(Key::new(conn(1), 1), &as_pane(&mux));
        host.sessions().attach_control(&as_pane(&ctl));
        host.detached().unwrap().insert(&as_pane(&parked), None);

        let listed: Vec<String> = host.list_panes().into_iter().map(|row| row.pane_id).collect();

        assert_eq!(listed.len(), 3);
        for wanted in [mux_id, ctl_id, parked_id] {
            assert!(listed.contains(&wanted), "{wanted} is missing from {listed:?}");
        }
    }

    /// One row per PANE, not per attached client. A fanned-out pane is one object under N keys, and
    /// a list that walked the keys would report the same shell three times to a client that opened
    /// it on three devices.
    #[test]
    fn a_fanned_out_pane_is_listed_once() {
        let (host, _fork, _gone) = host();
        let (ghost, _id) = named(1);
        let pane = as_pane(&ghost);
        host.sessions().attach_primary(Key::new(conn(1), 1), &pane);
        host.sessions().attach(Key::new(conn(2), 1), &pane, 7);
        host.sessions().attach(Key::new(conn(3), 1), &pane, 8);

        assert_eq!(host.list_panes().len(), 1);
    }

    /// A pane whose master is gone reports `0 × 0` rather than the renderer's 24×80 fallback: the
    /// list DESCRIBES, and a fabricated grid is a lie a caller cannot tell from a measurement.
    #[test]
    fn a_pane_with_no_master_reports_a_zero_grid_rather_than_a_default_one() {
        let (host, _fork, _gone) = host();
        let (ghost, _id) = named(1);
        ghost.set_window(None);
        ghost.set_pid(-1);
        ghost.kill_child();
        host.sessions().attach_control(&as_pane(&ghost));

        let row = host.list_panes().remove(0);

        assert_eq!((row.rows, row.cols), (0, 0));
        assert_eq!(row.pid, -1);
        assert!(!row.is_alive);
    }

    /// Every field of a row comes off the pane rather than off a cache, which is what makes the
    /// `TIOCGWINSZ` and foreground probe per row worth paying for.
    #[test]
    fn a_row_carries_what_the_pane_answers_right_now() {
        let (host, _fork, _gone) = host();
        let (ghost, id) = named(4);
        ghost.set_title("agent — build");
        ghost.set_cwd(Some("/w/slop-desk"));
        ghost.set_foreground("claude");
        ghost.set_status("working", Some("running the suite"));
        ghost.set_last_exit_code(Some(2));
        ghost.set_window(Some((40, 120)));
        host.sessions().attach_control(&as_pane(&ghost));

        let row = host.list_panes().remove(0);

        assert_eq!(row.pane_id, id);
        assert_eq!(row.title, "agent — build");
        assert_eq!(row.cwd.as_deref(), Some("/w/slop-desk"));
        assert_eq!(row.command, "claude");
        assert_eq!(row.state, "working");
        assert_eq!(row.state_message.as_deref(), Some("running the suite"));
        assert_eq!(row.last_exit_code, Some(2));
        assert_eq!((row.rows, row.cols), (40, 120));
    }

    // ----------------------------------------------------------------------------------- lookup

    #[test]
    fn a_lookup_finds_a_channel_pane_and_a_standalone_one() {
        let (host, _fork, _gone) = host();
        let (mux, mux_id) = named(1);
        let (ctl, ctl_id) = named(2);
        host.sessions()
            .attach_primary(Key::new(conn(1), 1), &as_pane(&mux));
        host.sessions().attach_control(&as_pane(&ctl));

        assert_eq!(
            host.lookup_pane(&mux_id).map(|held| held.slot()),
            Some(mux.slot())
        );
        assert_eq!(
            host.lookup_pane(&ctl_id).map(|held| held.slot()),
            Some(ctl.slot())
        );
    }

    /// A near-miss is refused rather than pointed at a pane. The id is a JOIN KEY, and a lenient
    /// parse is how a caller comes to kill the wrong conversation.
    #[test]
    fn a_pane_id_that_is_not_a_uuid_finds_nothing_and_kills_nothing() {
        let (host, _fork, _gone) = host();
        let (ghost, _id) = named(1);
        host.sessions().attach_control(&as_pane(&ghost));

        for hostile in ["", "p1", "0123456789ABCDEF0001020304050607"] {
            assert!(host.lookup_pane(hostile).is_none());
            assert!(!host.kill_pane(hostile));
        }
        assert_eq!(ghost.shutdowns(), 0);
    }

    /// A DETACHED pane is listed but is not attached, so it is not what a verb that writes should
    /// find — the lookup is the attached tables only, which is what the Swift's was.
    #[test]
    fn a_detached_pane_is_listed_but_not_looked_up() {
        let (host, _fork, _gone) = host();
        let (parked, parked_id) = named(3);
        host.detached().unwrap().insert(&as_pane(&parked), None);

        assert_eq!(host.list_panes().len(), 1);
        assert!(host.lookup_pane(&parked_id).is_none());
    }

    // -------------------------------------------------------------------------------- the kills

    /// EVERY key naming the pane goes, not just the first match. A survivor keeps the killed pane
    /// in `list-panes`, shuts it a second time at stop, and reads as attached to the rebind
    /// recovery.
    #[test]
    fn killing_a_fanned_out_pane_takes_every_key_that_names_it() {
        let (host, _fork, _gone) = host();
        let (ghost, id) = named(1);
        let pane = as_pane(&ghost);
        host.sessions().attach_primary(Key::new(conn(1), 1), &pane);
        host.sessions().attach(Key::new(conn(2), 1), &pane, 7);
        host.sessions().attach(Key::new(conn(3), 1), &pane, 8);

        assert!(host.kill_pane(&id));

        assert_eq!(host.sessions().member_count(), 0, "no key survived");
        assert!(host.list_panes().is_empty());
        assert_eq!(ghost.shutdowns(), 1);
    }

    /// Prevent-sleep STRICT BALANCE. A pane killed mid-turn never delivers its own `working → done`
    /// edge, so without this fan the daemon's `working` aggregate keeps a dead pane id for ever and
    /// the `IOPMAssertion` is held for the rest of the process's life.
    #[test]
    fn killing_a_pane_that_carried_an_agent_publishes_a_final_clearing_transition() {
        let (host, _fork, _gone) = host();
        let (ghost, id) = named(1);
        ghost.set_present(true);
        ghost.set_status("working", None);
        ghost.set_title("claude");
        host.sessions().attach_control(&as_pane(&ghost));
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        assert!(host.kill_pane(&id));

        let seen = watcher.seen();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].pane_id, id);
        assert_eq!(seen[0].state, "idle");
        assert!(!seen[0].agent_present, "the agent is GONE, not resting");
        assert_eq!(seen[0].title, "claude");
    }

    /// The gate on the other side of the same rule: a plain shell that never had an agent must not
    /// publish a supervision event about nothing, or every closed tab becomes one.
    #[test]
    fn killing_a_plain_shell_publishes_nothing() {
        let (host, _fork, _gone) = host();
        let (ghost, id) = named(1);
        host.sessions().attach_control(&as_pane(&ghost));
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        assert!(host.kill_pane(&id));

        assert!(watcher.seen().is_empty());
    }

    /// The exit closure will not find this pane in the table a moment later, so its hook route is
    /// retired HERE — anywhere else and a `kill` leaks one key and one closure per spawned pane for
    /// the daemon's whole life.
    #[test]
    fn killing_a_standalone_pane_retires_its_hook_route() {
        let (host, _fork, _gone) = host();
        let (ghost, id) = named(2);
        let pane = as_pane(&ghost);
        host.sessions().attach_control(&pane);
        host.sessions().register_hook(&pane, &id);
        assert_eq!(host.sessions().hook_count(), 1);

        assert!(host.kill_pane(&id));

        assert_eq!(host.sessions().hook_count(), 0);
        assert_eq!(ghost.shutdowns(), 1);
    }

    /// A pane can be parked two ways — a client that disconnected, and one this host ADOPTED at
    /// start — and ctl must be able to end either. Without this branch every pane that outlived a
    /// restart was unkillable while being perfectly visible in `list-panes`.
    #[test]
    fn killing_a_detached_pane_ends_it_and_forgets_its_transcript() {
        let (host, _fork, gone) = host();
        let (parked, id) = named(3);
        parked.set_present(true);
        host.detached().unwrap().insert(&as_pane(&parked), None);
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        assert!(host.kill_pane(&id));

        assert_eq!(parked.shutdowns(), 1);
        assert_eq!(gone.seen(), vec![parked.id()]);
        assert_eq!(
            watcher.seen().len(),
            1,
            "the teardown fan runs on this branch too"
        );
        assert!(host.list_panes().is_empty());
    }

    /// The dead-child branch. "Kill this pane" asked for a state that already holds, so the answer
    /// is success — but the bookkeeping is NOT optional: a pane that died while detached still
    /// carries its last status, and its exit closure is gated off by design, so nothing else will
    /// ever clear it.
    #[test]
    fn killing_a_detached_pane_whose_child_already_died_still_does_the_bookkeeping() {
        let (host, _fork, gone) = host();
        let (parked, id) = named(3);
        parked.set_present(true);
        parked.kill_child();
        host.detached().unwrap().insert(&as_pane(&parked), None);
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        assert!(host.kill_pane(&id));

        assert_eq!(gone.seen(), vec![parked.id()]);
        assert_eq!(watcher.seen().len(), 1);
        assert_eq!(
            parked.shutdowns(),
            1,
            "the CLAIM tore it down; this branch must not tear it down a second time",
        );
    }

    #[test]
    fn killing_a_pane_nobody_holds_answers_false() {
        let (host, _fork, gone) = host();

        assert!(!host.kill_pane(&uuid_text([9_u8; 16])));
        assert!(gone.seen().is_empty());
    }

    // -------------------------------------------------------------------------------- the spawn

    /// A `cmd`-less spawn is an interactive LOGIN shell, and the leading dash on `argv[0]` is the
    /// only thing that makes zsh source `.zprofile`. The shim rides with it, because the OSC-133
    /// marks it lays down are what every block verb reads.
    #[test]
    fn a_spawn_with_no_command_is_a_login_shell_with_the_shim() {
        let (host, fork, _gone) = host();

        let id = host.spawn_standalone(None, None, None, 24, 80).unwrap();

        let asked = fork.asked().remove(0);
        assert_eq!(uuid_text(asked.session), id);
        assert_eq!(asked.executable, "/bin/zsh");
        assert_eq!(asked.argv0, "-zsh");
        assert!(asked.argv.is_empty());
        assert!(asked.shell_integration);
        assert!(asked.blocks, "the shim went down, so there are marks to segment");
        assert_eq!((asked.rows, asked.cols), (24, 80));
    }

    /// A `cmd` pane is exec'd directly and never sees a prompt, so the shim — which IS prompt
    /// machinery — is skipped, and the block tap with it: a tap on a pane with no OSC-133 marks
    /// would report nothing for the pane's whole life.
    #[test]
    fn a_spawn_with_a_command_skips_the_shim_and_the_block_tap() {
        let (host, fork, _gone) = host();
        let cmd = [
            String::from("/usr/bin/env"),
            String::from("-i"),
            String::from("true"),
        ];

        drop(host.spawn_standalone(Some(&cmd), None, None, 30, 100).unwrap());

        let asked = fork.asked().remove(0);
        assert_eq!(asked.executable, "/usr/bin/env");
        assert_eq!(asked.argv0, "env", "the basename, not the path");
        assert_eq!(asked.argv, vec![String::from("-i"), String::from("true")]);
        assert!(!asked.shell_integration);
        assert!(!asked.blocks);
    }

    /// An empty `cmd` array is a caller asking for a shell in a clumsier way, not a request to exec
    /// nothing.
    #[test]
    fn an_empty_command_array_is_a_login_shell() {
        let (host, fork, _gone) = host();

        drop(host.spawn_standalone(Some(&[]), None, None, 24, 80).unwrap());

        assert_eq!(fork.asked()[0].executable, "/bin/zsh");
        assert!(fork.asked()[0].shell_integration);
    }

    /// The three self-orientation keys, which are what let an agent inside a spawned pane drive its
    /// own pane with zero discovery. `SLOPDESK_PANE_ID` is set whether or not a hook listener is
    /// up: where to POST is the listener's question, but which pane this IS is the pane's own.
    #[test]
    fn a_spawned_panes_environment_carries_the_ctl_sentinel_and_its_own_id() {
        let (host, fork, _gone) = host();

        let id = host
            .spawn_standalone(None, Some("/w/slop-desk"), None, 24, 80)
            .unwrap();

        let env = fork.asked().remove(0).env;
        assert_eq!(env["SLOPDESK_CTL"], "1");
        assert_eq!(env["SLOPDESK_CTL_BIN"], "/opt/slopdesk-ctl");
        assert_eq!(env["SLOPDESK_PANE_ID"], id);
        assert_eq!(env["SLOPDESK_SOCKET_PATH"], "/tmp/hook.sock");
        assert_eq!(env["SLOPDESK_CONTROL_SOCKET"], "/tmp/ctl.sock");
        assert_eq!(env["PWD"], "/w/slop-desk");
        assert_eq!(
            fork.asked()[0].cwd.as_deref(),
            Some("/w/slop-desk"),
            "the chdir is the spawner's, and `PWD` only DESCRIBES it",
        );
        assert_eq!(env["TERM"], "xterm-ghostty");
        assert_eq!(env["TERM_PROGRAM"], "slopdesk");
        assert!(!env.contains_key("SLOPDESK_UNSET"));
    }

    /// A host with no hook listener claimed tells nobody where to POST — a pane handed a socket
    /// path nothing is listening on turns every hook into a timeout instead of a no-op — but it
    /// still tells the pane which pane it is.
    #[test]
    fn a_host_with_no_hook_listener_exports_the_pane_id_and_not_the_socket() {
        let fork = Arc::new(Fork::default());
        let host = Host::with(
            Arc::<Fork>::clone(&fork),
            None,
            HostEnv {
                agent_socket_path: None,
                control_socket_path: None,
                ctl_binary_path: None,
                ..env()
            },
            true,
            Arc::new(Counter::default()),
            Arc::new(slopdesk_hostserver::NoTranscripts),
        );

        let id = host.spawn_standalone(None, None, None, 24, 80).unwrap();

        let env = fork.asked().remove(0).env;
        assert_eq!(env["SLOPDESK_PANE_ID"], id);
        assert!(!env.contains_key("SLOPDESK_SOCKET_PATH"));
        assert!(!env.contains_key("SLOPDESK_CONTROL_SOCKET"));
        assert!(!env.contains_key("SLOPDESK_CTL_BIN"));
        assert_eq!(
            env["SLOPDESK_CTL"], "1",
            "the sentinel is about who MADE the pane"
        );
    }

    /// The caller's variables go over the curated ones — that is what the parameter is for — but a
    /// request cannot make a pane lie to its own agent about which pane it is.
    #[test]
    fn a_callers_environment_is_merged_but_cannot_displace_the_panes_own_identity() {
        let (host, fork, _gone) = host();
        let mut extra = Map::new();
        drop(extra.insert(String::from("MY_FLAG"), json!("on")));
        drop(extra.insert(String::from("SLOPDESK_PANE_ID"), json!("not-a-pane")));
        drop(extra.insert(String::from("SLOPDESK_CTL"), json!("0")));
        drop(extra.insert(String::from("IGNORED"), Value::Null));

        let id = host.spawn_standalone(None, None, Some(&extra), 24, 80).unwrap();

        let env = fork.asked().remove(0).env;
        assert_eq!(env["MY_FLAG"], "on");
        assert_eq!(env["SLOPDESK_PANE_ID"], id);
        assert_eq!(env["SLOPDESK_CTL"], "1");
        assert!(
            !env.contains_key("IGNORED"),
            "a non-string value is not an environment"
        );
    }

    /// The order the Swift landed on and the reason it is one: the route the child was told to POST
    /// to is advertised as `SLOPDESK_PANE_ID`, so it must exist by the time the relay starts — and
    /// a refused insert must leave no key behind for anyone to retire.
    #[test]
    fn a_spawn_files_the_pane_registers_its_hook_route_and_only_then_starts_it() {
        let (host, fork, _gone) = host();

        let id = host
            .spawn_standalone(None, Some("/w/slop-desk"), None, 24, 80)
            .unwrap();

        assert_eq!(host.list_panes().len(), 1);
        assert_eq!(
            host.lookup_pane(&id).map(|held| held.id()),
            Some(fork.made()[0].id())
        );
        assert_eq!(host.sessions().hook_count(), 1);
        assert_eq!(fork.started(), vec![(
            fork.made()[0].id(),
            Some(String::from("/w/slop-desk"))
        )],);
    }

    #[test]
    fn a_stopping_host_refuses_a_spawn_without_forking() {
        let (host, fork, _gone) = host();
        host.mark_stopping();

        let refusal = host.spawn_standalone(None, None, None, 24, 80).unwrap_err();

        assert!(refusal.0.contains("stopping"));
        assert!(fork.asked().is_empty(), "the fork never happened");
    }

    /// The second gate, and the one that matters. A `stop()` that lands WHILE the child is forking
    /// would otherwise file a pane into a table whose sweep has already run, and nothing would ever
    /// end it.
    #[test]
    fn a_stop_that_lands_during_the_fork_still_refuses_and_ends_the_child() {
        let (host, fork, _gone) = host();
        let stopping = Arc::clone(&host);
        *fork.during.lock().unwrap_or_else(PoisonError::into_inner) = Some(Box::new(move || stopping.stop()));

        let refusal = host.spawn_standalone(None, None, None, 24, 80).unwrap_err();

        assert!(refusal.0.contains("stopping"));
        assert_eq!(fork.made()[0].shutdowns(), 1, "the forked child was ended");
        assert!(host.list_panes().is_empty());
        assert_eq!(host.sessions().hook_count(), 0, "no key was left to retire");
        assert!(fork.started().is_empty());
    }

    #[test]
    fn a_spawner_that_refuses_leaves_no_pane_and_no_hook_route() {
        let (host, fork, _gone) = host();
        *fork.refuse.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(SpawnRefused(String::from("no such directory")));

        let refusal = host
            .spawn_standalone(None, Some("/nope"), None, 24, 80)
            .unwrap_err();

        assert_eq!(refusal.0, "no such directory");
        assert!(host.list_panes().is_empty());
        assert_eq!(host.sessions().hook_count(), 0);
    }

    /// A pane id is a join key, and one that is not random points a reattach at the wrong
    /// conversation. Refusing the spawn is the only safe answer.
    #[test]
    fn a_host_that_cannot_mint_an_id_refuses_rather_than_inventing_one() {
        let fork = Arc::new(Fork::default());
        let host = Host::with(
            Arc::<Fork>::clone(&fork),
            None,
            env(),
            true,
            Arc::new(NoIds),
            Arc::new(slopdesk_hostserver::NoTranscripts),
        );

        let refusal = host.spawn_standalone(None, None, None, 24, 80).unwrap_err();

        assert!(refusal.0.contains("entropy"));
        assert!(fork.asked().is_empty());
    }

    // ------------------------------------------------------------------------------ the exit

    /// The exit ladder's host half: the pane leaves the table, its hook route leaves with it, and a
    /// pane that died MID-TURN gets its clearing transition — the same strict balance a `kill`
    /// owes.
    #[test]
    fn an_exiting_standalone_pane_is_unfiled_and_its_route_retired() {
        let (host, fork, _gone) = host();
        drop(host.spawn_standalone(None, None, None, 24, 80).unwrap());
        fork.made()[0].set_present(true);
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        fork.exit();

        assert!(host.list_panes().is_empty());
        assert_eq!(host.sessions().hook_count(), 0);
        assert_eq!(watcher.seen().len(), 1);
        assert!(!watcher.seen()[0].agent_present);
    }

    // ------------------------------------------------------------------------- the fan-out

    /// The pane's own transitions reach the cross-pane stream, carrying the presence bit the
    /// four-token vocabulary cannot: the agent-GONE edge and a resting agent both read `idle`.
    #[test]
    fn a_panes_transition_reaches_every_top_level_subscriber() {
        let (host, fork, _gone) = host();
        let id = host.spawn_standalone(None, None, None, 24, 80).unwrap();
        fork.made()[0].set_title("claude");
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        fork.moved(slopdesk_agent::ClaudeStatus::Working);
        fork.moved(slopdesk_agent::ClaudeStatus::None);

        let seen = watcher.seen();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0].pane_id, id);
        assert_eq!(seen[0].state, "working");
        assert!(seen[0].agent_present);
        assert_eq!(seen[1].state, "idle");
        assert!(!seen[1].agent_present, "gone, not resting");
        assert_eq!(seen[1].title, "claude");
    }

    #[test]
    fn a_retired_subscriber_hears_nothing_more() {
        let (host, fork, _gone) = host();
        drop(host.spawn_standalone(None, None, None, 24, 80).unwrap());
        let watcher = Arc::new(Watcher::default());
        let token = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        fork.moved(slopdesk_agent::ClaudeStatus::Working);
        host.remove_status_tap(token);
        fork.moved(slopdesk_agent::ClaudeStatus::Done);

        assert_eq!(watcher.seen().len(), 1);
    }

    /// Retiring a token twice, or one from another host, is a no-op rather than an error — which is
    /// what a subscriber whose connection dropped mid-verb does.
    #[test]
    fn retiring_a_subscriber_twice_is_a_no_op() {
        let (host, _fork, _gone) = host();
        let watcher = Arc::new(Watcher::default());
        let token = host.add_status_tap(Arc::<Watcher>::clone(&watcher));

        host.remove_status_tap(token);
        host.remove_status_tap(token);
    }

    /// The pane is held WEAKLY by its own status handler: the pane owns the session that owns the
    /// detector that calls it, so a strong edge back would be a cycle that outlives both.
    #[test]
    fn a_dropped_pane_leaves_its_status_handler_harmless() {
        let (host, fork, _gone) = host();
        let id = host.spawn_standalone(None, None, None, 24, 80).unwrap();
        let watcher = Arc::new(Watcher::default());
        let _watching = host.add_status_tap(Arc::<Watcher>::clone(&watcher));
        assert!(host.kill_pane(&id));
        fork.made.lock().unwrap_or_else(PoisonError::into_inner).clear();

        fork.moved(slopdesk_agent::ClaudeStatus::Working);

        assert!(watcher.seen().is_empty(), "no pane, nothing to describe");
    }
}
