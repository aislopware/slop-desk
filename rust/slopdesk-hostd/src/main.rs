//! `slopdesk-hostd` — the headless `SlopDesk` host daemon.
//!
//! Binds a TCP listener, spawns the user's login shell per session through superd, relays PTY bytes
//! over the dual data/control channels with replay-buffer reconnect, and survives client
//! disconnects. Runs until SIGINT or SIGTERM.
//!
//! ## What a `main` is allowed to be
//! An ORDER and nothing else. Every decision below this file is somebody's — a gate's, a policy's,
//! a ladder's — and the only thing that cannot live anywhere else is the sequence they happen in.
//! So there is no logic here beyond "this before that", and each "before" carries the reason it is
//! not the other way round.
//!
//! ## The order, and what each step depends on
//! 1. **Block the signals**, as the FIRST act. Threads inherit the mask, so a SIGTERM landing on
//!    superd's reader thread before this would take the default disposition and kill the process
//!    mid-drain. Everything downstream spawns threads; nothing upstream does.
//! 2. **Raise the fd limit**, before anything opens a file. Every live and detached pane holds a
//!    PTY master and a journal fd, plus per-connection sockets, and macOS's default soft limit of
//!    256 is far under what the detach cap needs.
//! 3. **Fold the settings sidecar**, before any gate is read. `docs/58`: there is no settings GUI
//!    and no live reload, so a toggle applies at the next launch and this is that launch.
//! 4. **The `integration` one-shot**, before the arg parse, so `integration …` never reaches the
//!    listener.
//! 5. **Install the hooks**, idempotently, on every launch. They are INSTALLED, not offered: a host
//!    that had never been told still ran Claude and still reported nothing.
//! 6. **Dial superd.** Fatal if it refuses — nothing else in this process can fork a shell.
//! 7. **Assemble**, publish the late-bound handles, claim the listeners, adopt the survivors, and
//!    only then start accepting. A client that connects before the survivors are adopted would be
//!    offered a fresh shell for a pane that is still running.
//!
//! ## Two things are published AFTER the composition exists, and must be
//! The spawner is built before the host and the host holds the spawner, so the pane-eviction seam
//! and the ctl dispatcher both land through a `OnceLock` once the cycle is closed. See
//! [`slopdesk_hostd::LateHost`] and [`slopdesk_hostd::supervisor::DaemonObserver::serve_control`].

use std::sync::Arc;
use std::time::Duration;

use nix::sys::signal::{SigSet, Signal};
use slopdesk_hostd::LateHost;
use slopdesk_hostd::env::Overlay;
use slopdesk_hostd::hooks::HookTable;
use slopdesk_hostd::keys::ProjectKeySink;
use slopdesk_hostd::observer::Stderr;
use slopdesk_hostd::repowatch::{Fanout, HostRepoWatcher, Keys};
use slopdesk_hostd::screen::{ScreendOracle, ScreendSnapshot};
use slopdesk_hostd::serve::Listening;
use slopdesk_hostd::services::{self, ClaudeHooks, Vendored};
use slopdesk_hostd::sleep::KeepAwake;
use slopdesk_hostd::spawn::{PaneSpawner, Recipe};
use slopdesk_hostd::supervisor::DaemonObserver;
use slopdesk_hostd::survivors::Supervised;
use slopdesk_hostd::transcripts::DiskTranscripts;
use slopdesk_hostd::workspacestore::DiskWorkspace;
use slopdesk_hostserver::agentaction::AgentActions;
use slopdesk_hostserver::bridge::CodeBridgeServer;
use slopdesk_hostserver::channel::{HookRoutes, HostObserver, Offload, Threads, WorkspaceChannels};
use slopdesk_hostserver::clipsync::{Clipboard, GeneralBoard};
use slopdesk_hostserver::code::{CodeBridge, CodeServerManager};
use slopdesk_hostserver::codeaction::CodeActions;
use slopdesk_hostserver::control::{AgentStatusTap, ControlHost, IpcGuards};
use slopdesk_hostserver::ctlserve::ControlConnections;
use slopdesk_hostserver::ensure::EnsuredService;
use slopdesk_hostserver::gates::{self, HostAgentGates};
use slopdesk_hostserver::metadata::{HostMetadata, HostQueries, HostQuerying};
use slopdesk_hostserver::pathaction::{Finder, PathActions};
use slopdesk_hostserver::repowatch::{FsEvents, GitRepos};
use slopdesk_hostserver::route::Performers;
use slopdesk_hostserver::service::ProbedPortService;
use slopdesk_hostserver::workspace::{NoStore, WorkspaceDocument};
use slopdesk_hostserver::wsserve::WorkspaceService;
use slopdesk_hostserver::{
    DetachedStore, Host, HostEnv, HostParts, LetGo, NoTranscripts, Panes, SessionIds, Survivors, SystemIds,
    Transcripts, WorkspaceStore, owner_identity,
};
use slopdesk_hostsession::{MetadataPerformer, ScreenOracle, SnapshotPolicy};
use slopdesk_screenclient::client::ScreenClient;
use slopdesk_superclient::client::{ClientThreads, ListenerKind, SupervisorClient, SupervisorObserver};
use slopdesk_superwire::protocol::BlocksRequest;

/// Everything the composition is built OUT of, gathered so the call is readable.
///
/// Borrowed rather than owned, because every field outlives the call and several are handed to the
/// caller again immediately afterwards — a by-value shape would make this function look like it
/// consumed a daemon it only reads.
struct Composition<'a> {
    gates: &'a HostAgentGates<'a>,
    overlay: &'a Overlay,
    supervisor: &'a Arc<SupervisorClient>,
    screen: &'a Arc<ScreenClient>,
    transcripts: Option<&'a Arc<DiskTranscripts>>,
    hooks: &'a Arc<HookTable>,
    log: &'a Arc<Stderr>,
    metadata: Arc<dyn MetadataPerformer>,
    ctl_binary: Option<&'a str>,
    owner: String,
}

/// The four things the assembly learns that the caller has to act on.
struct Assembled {
    /// Whether this host had no terminfo entry for the ghostty `TERM` — one log line, once.
    term_fell_back: bool,
    /// The ctl dispatcher, when this host claimed that listener.
    control: Option<Arc<ControlConnections>>,
    /// The workspace's home on disk, so the STOP can flush what the debounce still holds.
    store: Arc<dyn WorkspaceStore>,
    /// The repo watches, so the stop can cancel every live `FSEvents` stream.
    watcher: Arc<HostRepoWatcher>,
}

/// Builds the spawner, the workspace and the composition around both.
///
/// A function rather than more of `main`, and the line it draws is the useful one: everything here
/// is a WIRING decision that could be asserted against fakes, and everything left in `main` is an
/// ORDER that cannot be.
fn compose(parts: &Composition<'_>) -> (Arc<Host>, Assembled) {
    let late_host = Arc::new(LateHost::default());
    let detach_enabled = parts.gates.agent_resume_on_recovery;
    let ids: Arc<dyn SessionIds> = Arc::new(SystemIds);
    let offload: Arc<dyn Offload> = Arc::new(Threads);
    let watching: Arc<dyn HostObserver> = parts.log.clone();
    // The EPOCH is this daemon's incarnation: a client holding a document from a previous hostd must
    // be told its version numbers mean nothing now, and a fresh id is how. Minted through the same
    // door every session id comes from, so a host with no entropy source fails one way.
    let epoch = ids.mint().unwrap_or_default();
    let document = Arc::new(WorkspaceDocument::new(epoch, Arc::clone(&ids)));
    // BEFORE the spawner, because the spawner's Recipe holds the sink into it — and after the
    // document, because a finished reading lands in both the document and the panes.
    let watcher = repo_watches(&late_host, &document, &ids);
    let sink: Arc<dyn ProjectKeySink> = Arc::new(Keys::new(&watcher));

    let spawner = Arc::new(PaneSpawner::new(Recipe {
        supervisor: Arc::clone(parts.supervisor),
        owner: parts.owner.clone(),
        log: Arc::<Stderr>::clone(parts.log),
        transcripts: parts.transcripts.cloned(),
        snapshot: snapshot_policy(parts.screen),
        oracle: Some(screen_oracle(parts.screen)),
        keys: Some(sink),
        late_host: Arc::clone(&late_host),
        scrollback_bytes: scrollback_bytes(),
        distill: parts.overlay.on_unless_zero("SLOPDESK_SCROLLBACK_DISTILL"),
        lag_bytes: lag_bytes(parts.overlay),
        poll_interval: POLL_INTERVAL,
        done_to_idle: DONE_TO_IDLE,
        resize_debounce: RESIZE_DEBOUNCE,
        size_settle: SIZE_SETTLE,
        blocks: BlocksRequest::default(),
        metadata: Arc::clone(&parts.metadata),
    }));

    let workspace = WorkspaceService::new(
        Arc::clone(&document),
        Arc::clone(&offload),
        Arc::clone(&watching),
        Arc::clone(&ids),
    );
    let channels: Arc<dyn WorkspaceChannels> = workspace;
    let routes: Arc<dyn HookRoutes> = parts.hooks.clone();
    let survivors: Arc<dyn Survivors> = Arc::new(Supervised::new(parts.supervisor));
    let journals: Arc<dyn Transcripts> = match parts.transcripts.filter(|_| detach_enabled).cloned() {
        Some(disk) => disk,
        None => Arc::new(NoTranscripts),
    };

    let (env, term_fell_back) = host_env(parts.gates, parts.ctl_binary, parts.supervisor);
    let host = Host::assemble(HostParts {
        spawner,
        detached: detach_enabled.then(|| Arc::new(DetachedStore::capped(detach_cap(parts.overlay)))),
        detach_ttl: detach_ttl(),
        env,
        blocks_enabled: parts.gates.blocks,
        ids: Arc::clone(&ids),
        transcripts: journals,
        offload,
        workspace: channels,
        hooks: routes,
        observer: watching,
        survivors,
        let_go: Arc::new(LetGo::new()),
        owner: parts.owner.clone(),
    });

    // The cycle closes here, and everything that needed the composition to exist lands in one place.
    late_host.publish(&host);
    let store = workspace_store(&ids, parts.log);
    let panes: Arc<dyn Panes> = host.clone();
    document.install_from(&store);
    document.set_panes(&panes);
    // The prevent-sleep aggregate rides the SAME fan-out every other status consumer does, so a pane
    // torn down mid-turn clears through `fan_teardown` rather than being kept for ever. The token is
    // dropped because the tap lives as long as the daemon; there is no un-register.
    let steering: Arc<dyn ControlHost> = host.clone();
    if parts.gates.agent_prevent_sleep {
        let awake: Arc<dyn AgentStatusTap> = Arc::new(KeepAwake::new(true));
        let _token = steering.add_status_tap(awake);
    }
    // Built here rather than installed here: the observer that holds it is the caller's, and a
    // composition that reached back into it would make this function's job two things.
    let control = parts.gates.agent_control.then(|| {
        Arc::new(ControlConnections::with_guards(steering, IpcGuards {
            allow_send_keys: parts.gates.ipc_allow_send_keys,
            allow_sensitive_sessions: parts.gates.ipc_allow_sensitive,
        }))
    });

    (host, Assembled {
        term_fell_back,
        control,
        store,
        watcher,
    })
}

/// The repo watches, with their four production doors.
///
/// [`Fanout`] is built here rather than by the caller because it is the ONLY thing that needs both
/// the document and the late-bound host, and handing it out would put that pairing in two places.
fn repo_watches(
    late: &Arc<LateHost>,
    document: &Arc<WorkspaceDocument>,
    ids: &Arc<dyn SessionIds>,
) -> Arc<HostRepoWatcher> {
    HostRepoWatcher::new(
        FsEvents::new(),
        GitRepos,
        Fanout::new(late, document, ids),
        Threads,
    )
}

/// The workspace's home on disk, or the no-op store when the container cannot be resolved.
///
/// DEGRADED rather than broken: such a host still serves a workspace and still lets a client upload
/// the layout it has — it simply mints a fresh default at every start.
fn workspace_store(ids: &Arc<dyn SessionIds>, log: &Arc<Stderr>) -> Arc<dyn WorkspaceStore> {
    if let Some(disk) = DiskWorkspace::from_launch(ids, log) {
        return Arc::new(disk);
    }
    log.say("no Application Support container — the workspace will not survive a restart");
    Arc::new(NoStore)
}

/// The OPT-IN detached-pane cap, or `None` for UNBOUNDED.
///
/// Unbounded is tmux's semantics and the default: the TTL and the fd headroom are the real bounds.
/// A non-positive or unparsable value is NOT a cap of zero — it is the absence of one, which is
/// what keeps a typo from silently killing every parked pane but the newest.
fn detach_cap(overlay: &Overlay) -> Option<usize> {
    overlay
        .get("SLOPDESK_DETACH_MAX_SESSIONS")
        .and_then(|raw| raw.trim().parse::<usize>().ok())
        .filter(|cap| *cap > 0)
}

/// The state-transfer composer, or `None` when `SLOPDESK_SCROLLBACK_SNAPSHOT=0` turned it off.
fn snapshot_policy(screen: &Arc<ScreenClient>) -> Option<Arc<dyn SnapshotPolicy>> {
    let policy = ScreendSnapshot::from_environment(screen)?;
    Some(Arc::new(policy))
}

/// The scan door every pane asks its screen question through.
fn screen_oracle(screen: &Arc<ScreenClient>) -> Arc<dyn ScreenOracle> {
    Arc::new(ScreendOracle::new(screen))
}

/// The soft fd limit this daemon asks for, bounded by the hard limit.
const FD_TARGET: u64 = 8192;

/// How often orphaned journals are swept.
///
/// hostd is a week-long process, so a single sweep at start-up would leave the orphans from every
/// link-drop detach and TTL eviction since unbounded until a restart.
const SWEEP_INTERVAL: Duration = Duration::from_hours(6);

/// How often the foreground poll samples a pane.
const POLL_INTERVAL: Duration = Duration::from_millis(1000);

/// How long a finished turn stays `done` before decaying to `idle`, in seconds.
const DONE_TO_IDLE: f64 = 12.0;

/// The latest-wins window before a resolved grid reaches `TIOCSWINSZ`.
const RESIZE_DEBOUNCE: Duration = Duration::from_millis(40);

/// The longer window a contributor-set change arms — a client joining or leaving moves the resolved
/// grid for a reason that is not somebody dragging an edge, and it deserves to settle.
const SIZE_SETTLE: Duration = Duration::from_millis(250);

/// The laggard threshold: how far one subscriber may fall behind before it is evicted.
const DEFAULT_LAG_BYTES: u64 = 32 * 1024 * 1024;

fn main() {
    // (1) Before ANY thread exists. See the module note.
    let signals = block_shutdown_signals();

    // (2) Before ANY file is opened.
    raise_fd_limit();

    let argv: Vec<String> = std::env::args().collect();
    let program = argv
        .first()
        .and_then(|path| path.rsplit('/').next())
        .unwrap_or("slopdesk-hostd")
        .to_owned();
    let log = Arc::new(Stderr::named(&program));

    // (3) Before ANY gate is read.
    let overlay = Overlay::from_launch();
    if !overlay.applied().is_empty() && std::env::var("SLOPDESK_VIDEO_DEBUG").is_ok() {
        log.say(&format!(
            "applied {} overlay → {:?}",
            "video-prefs.json",
            overlay.applied()
        ));
    }

    // (4) Before the daemon arg parse.
    if let Some(code) = integration_oneshot(&argv, &program) {
        std::process::exit(code);
    }

    let Some(parsed) = slopdesk_hostlaunch::args::parse(&argv) else {
        log.say(&slopdesk_hostlaunch::args::usage(&program));
        std::process::exit(2);
    };

    // (5) Idempotent, every launch. The SAME door verb 11 actuates, so "install the hooks" has one
    // implementation whether this daemon decided it at launch or a client asked for it.
    ClaudeHooks::new(&log).install_if_absent();

    let gates = resolve_gates(&overlay);

    // (6) Fatal, and the only fatal step before the bind: nothing else in this process can fork.
    let hooks = Arc::new(HookTable::new());
    let daemon = Arc::new(DaemonObserver::new(&hooks, &log));
    let (supervisor, client_threads) = dial_superd(&program, daemon.clone(), &log);

    // screend is OPTIONAL in a way superd is not: without it a pane replays raw and runs no scan
    // loop, which is a reduced host rather than a broken one.
    // A client, not a connection: it dials lazily and pools, so nothing is asked of screend here and
    // a daemon that is down costs a pane its scan loop rather than this daemon its start-up.
    let screen = Arc::new(ScreenClient::new());

    let transcripts = DiskTranscripts::from_environment(&supervisor, Some(Arc::clone(&screen))).map(Arc::new);
    let ctl_binary = sibling_ctl(&argv);
    let owner = owner_identity(parsed.port, std::env::var("SLOPDESK_SUPERD_DIR").ok().as_deref());

    let queries: Arc<dyn HostQuerying> = Arc::new(HostQueries::from_environment());
    // Twelve of the twenty-two metadata verbs are claimed by named performers that actuate on
    // host-GLOBAL state — the Finder, the pasteboard, the workbench child, one set of simulated
    // devices. One instance of each per daemon, therefore, and `HostMetadata` hands anything that is
    // not its own read verb to the table below.
    let panels = build_panels(&hooks, &supervisor, &log);
    let metadata: Arc<dyn MetadataPerformer> =
        Arc::new(HostMetadata::new(queries, Arc::clone(&panels.performers)));

    let (host, daemon_parts) = compose(&Composition {
        gates: &gates,
        overlay: &overlay,
        supervisor: &supervisor,
        screen: &screen,
        transcripts: transcripts.as_ref(),
        hooks: &hooks,
        log: &log,
        metadata,
        ctl_binary: ctl_binary.as_deref(),
        owner,
    });
    if daemon_parts.term_fell_back {
        log.say(&format!(
            "no terminfo entry for {} on this host — advertising {}",
            gates::DEFAULT_TERM,
            gates::FALLBACK_TERM
        ));
    }
    if let Some(control) = daemon_parts.control {
        daemon.serve_control(control);
    }
    let stopping = Stopping {
        store: daemon_parts.store,
        watcher: daemon_parts.watcher,
    };

    // The claim, not a bind: superd owns both child-facing addresses. A host that did not claim the
    // control listener is never handed one, and superd advertises `SLOPDESK_CONTROL_SOCKET` to a
    // child only while somebody has.
    let mut claimed = vec![ListenerKind::Hook];
    if gates.agent_control {
        claimed.push(ListenerKind::Control);
    }
    match supervisor.listen(&claimed) {
        Ok(()) => hooks.mark_serving(true),
        Err(why) => log.say(&format!("superd refused the listener claim: {why}")),
    }

    // Before the bind. A client that connected first would be offered a fresh shell for a pane that
    // is still running under superd.
    host.adopt_survivors();

    let listening = match Listening::start(parsed.port, &host) {
        Ok(bound) => bound,
        Err(why) => {
            log.say(&format!("failed to start: {why}"));
            std::process::exit(1);
        },
    };
    let bound = listening.bound_port();
    log.say(&format!("listening on 0.0.0.0:{bound} (mode=shell)"));

    // Now that the REAL bound port is known — `--port 0` mints one that differs from the request.
    // Best-effort: a host that cannot write it still serves every client.
    if let Some(path) = slopdesk_hostlaunch::record::path() {
        let record = slopdesk_hostlaunch::record::current(bound, env!("CARGO_PKG_VERSION"));
        if record.write(&path) {
            log.say(&format!(
                "launch record at {} — `slopdesk-ops restart-hostd` restarts this exact daemon",
                path.display()
            ));
        }
    }

    if let Some(ref disk) = transcripts {
        start_journal_sweep(Arc::clone(disk));
    }

    // AFTER the bind, and never before it: the seed, the one-shot extension install and a Node cold
    // start together take longer than a client is willing to wait, and this daemon's job is to be
    // accepting connections. A host with no `code-server` is a silent no-op — `unavailable` is the
    // verb's answer, not a boot failure.
    panels.code.prewarm();

    // The one blocking call in the process. Everything above it runs on a thread of its own.
    wait_for_shutdown(signals, &log);
    shut_down(&listening, &hooks, &host, &supervisor, &stopping, &panels);
    client_threads.join();
}

/// The stop ladder, in the one order that leaves nothing half-torn.
///
/// The LAUNCH RECORD goes first, and before the drain rather than after: from here this daemon will
/// not serve, and a record naming a dying pid is worse than none. Its ABSENCE is meaningful — a
/// record whose pid is gone means hostd died badly, which is worth telling apart from a clean stop.
///
/// Then accepting stops, then the hook routes, then the panes. Accepting first because a connection
/// arriving mid-drain would be filed into tables that are emptying; the hook routes before the
/// panes because a late POST for a pane that is going away should be dropped rather than folded
/// into a detector whose session is being torn down.
///
/// The supervisor link goes LAST, and it is a disconnect rather than a kill: superd keeps the
/// children, so a session's replay window survives this daemon's restart and the next hostd adopts
/// the same shell. RELINQUISH, never terminate.
fn shut_down(
    listening: &Listening,
    hooks: &HookTable,
    host: &Arc<Host>,
    supervisor: &SupervisorClient,
    stopping: &Stopping,
    panels: &Panels,
) {
    if let Some(path) = slopdesk_hostlaunch::record::path() {
        slopdesk_hostlaunch::record::remove(&path);
    }
    listening.stop();
    hooks.stop();
    // The three panel children are RELINQUISHED, never terminated: superd keeps them, so the next
    // hostd adopts a warm workbench, a live simulator panel and every device mirror still in flight.
    // Terminating here is what `docs/51` exists to end — it would put a Node boot in front of the
    // editor after every host edit.
    panels.code.relinquish();
    panels.simulator.relinquish();
    panels.android.relinquish();
    // The workbench command socket is the exception, because it is hostd's own listener rather than
    // one of superd's children. It unbinds with the rest of this daemon's addresses; the surviving
    // extension host reconnects to the same pid-free path within one of its five-second ticks.
    panels.bridge.stop();
    // Before the panes: cancelling a watch takes `slopdesk-apple-fsevents`' own registry lock from
    // inside `Drop`, and a reading that fired against a pane already being torn down would be work
    // nobody can use.
    stopping.watcher.shutdown();
    host.stop();
    // AFTER the panes, and blocking: the last thing the user did may be the close that `host.stop`
    // just folded into the document, and a debounce that outlives this process loses it.
    stopping.store.flush();
    supervisor.disconnect();
}

/// The two things the stop has to reach that are not the host.
struct Stopping {
    store: Arc<dyn WorkspaceStore>,
    watcher: Arc<HostRepoWatcher>,
}

/// The three host-global panel backends, the workbench's command socket, and the routing table over
/// them.
///
/// Held together because the STOP has to reach each one and the routing table does not expose them:
/// a `dyn MetadataPerformer` can answer a verb and nothing else, while a shutdown must relinquish
/// three children and unbind one listener.
struct Panels {
    /// What [`HostMetadata`] hands every verb that is not one of its own reads.
    performers: Arc<dyn MetadataPerformer>,
    /// The workbench, for the boot-time prewarm and the stop.
    code: Arc<CodeServerManager>,
    /// The simulator server, for the stop.
    simulator: Arc<EnsuredService>,
    /// The Android bridge, for the stop.
    android: Arc<EnsuredService>,
    /// The workbench's command socket. hostd's own listener, not superd's — see [`shut_down`].
    bridge: Arc<CodeBridgeServer>,
}

/// Builds the six host-global doors and the table that routes to them.
///
/// Every one is constructed unconditionally, including on a machine that has none of the three
/// binaries: a locator answering `None` is what makes a panel report `unavailable`, which is the
/// verb's ANSWER. Refusing to build the door would instead answer `unsupportedVerb`, which tells
/// the client this HOST does not speak the verb — a different and false statement.
fn build_panels(hooks: &Arc<HookTable>, supervisor: &Arc<SupervisorClient>, log: &Arc<Stderr>) -> Panels {
    let vendored = Vendored::from_current_exe();
    let bridge = CodeBridgeServer::new(Some({
        let notes = Arc::clone(log);
        Arc::new(move |line: &str| notes.say(line))
    }));
    let code = Arc::new(CodeServerManager::new(
        services::code_seams(&vendored, &bridge, supervisor, log),
        ProbedPortService::DEFAULT_PROBE_INTERVAL,
        CodeServerManager::DEFAULT_OPEN_RETRY_DELAY,
    ));
    let simulator = Arc::new(EnsuredService::new(
        services::simulator_profile(&vendored, supervisor, log),
        services::loopback_probe(),
        ProbedPortService::DEFAULT_PROBE_INTERVAL,
    ));
    let android = Arc::new(EnsuredService::new(
        services::android_profile(&vendored, supervisor, log),
        services::loopback_probe(),
        ProbedPortService::DEFAULT_PROBE_INTERVAL,
    ));
    let performers: Arc<dyn MetadataPerformer> = Arc::new(Performers {
        path: Arc::new(PathActions::from_environment(Finder)),
        agent: Arc::new(AgentActions::new(ClaudeHooks::new(log), {
            // Read at PERFORM time, not captured now: the listener claim is made AFTER this table is
            // built, and it can fail later besides. A flag frozen here would report `false` to every
            // client for the daemon's whole life.
            let table = Arc::clone(hooks);
            Arc::new(move || table.is_listening())
        })),
        clipboard: Arc::new(Clipboard::new(GeneralBoard)),
        code: Arc::new(CodeActions::from_environment(Arc::clone(&code), Finder)),
        simulator: {
            let door: Arc<EnsuredService> = Arc::clone(&simulator);
            door
        },
        android: {
            let door: Arc<EnsuredService> = Arc::clone(&android);
            door
        },
    });
    Panels {
        performers,
        code,
        simulator,
        android,
        bridge,
    }
}

/// Dials superd, or ends the process saying where it looked.
///
/// The one FATAL step before the bind, and the address is computed here rather than passed in
/// because the three environment variables behind it are this crate's to read — that is what makes
/// `slopdesk-hostserver` drivable without any of them.
#[expect(
    clippy::exit,
    reason = "the ONE fatal step before the bind; `main` cannot serve without superd and says where it \
              looked"
)]
fn dial_superd(
    program: &str,
    observer: Arc<dyn SupervisorObserver>,
    log: &Stderr,
) -> (Arc<SupervisorClient>, ClientThreads) {
    let socket = slopdesk_superwire::control_socket_path(
        std::env::var("SLOPDESK_SUPERD_SOCKET").ok().as_deref(),
        std::env::var(slopdesk_superwire::DIRECTORY_ENV_KEY)
            .ok()
            .as_deref(),
        std::env::var("TMPDIR").ok().as_deref(),
    );
    match SupervisorClient::connect(&socket, program, observer) {
        Ok(pair) => pair,
        Err(why) => {
            log.say(&format!("cannot reach superd at {socket}: {why}"));
            std::process::exit(1);
        },
    }
}

/// Blocks SIGINT and SIGTERM on the calling thread, so every thread spawned later inherits the
/// mask.
///
/// Returns the set to `sigwait` on. A mask that could not be applied is still returned: the wait
/// below then competes with the default disposition, which is the same outcome an unhandled signal
/// already had, and refusing to start over it would be worse.
fn block_shutdown_signals() -> SigSet {
    let mut signals = SigSet::empty();
    signals.add(Signal::SIGINT);
    signals.add(Signal::SIGTERM);
    let _applied = signals.thread_block();
    signals
}

/// Parks until one of the blocked signals arrives, then names it.
///
/// `sigwait` rather than a handler, and that is the whole reason the mask exists: a handler runs on
/// whichever thread the signal lands on, with only async-signal-safe calls available to it, while
/// this returns on the main thread with the full language available. There is no one-shot latch to
/// get wrong either — a second SIGTERM during the drain is simply still blocked, and nothing is
/// waiting on it.
fn wait_for_shutdown(signals: SigSet, log: &Stderr) {
    match signals.wait() {
        Ok(signal) => log.say(&format!("{signal} — shutting down")),
        Err(why) => log.say(&format!("signal wait failed ({why}) — shutting down")),
    }
}

/// Raises the soft fd limit toward [`FD_TARGET`], bounded by the hard limit.
///
/// Silent on every failure: a host that could not raise it still serves, with fewer panes before it
/// starts refusing, and there is nothing a person could do with the news at this point in start-up.
fn raise_fd_limit() {
    use nix::sys::resource::{Resource, getrlimit, setrlimit};
    let Ok((soft, hard)) = getrlimit(Resource::RLIMIT_NOFILE) else {
        return;
    };
    let raised = hard.min(soft.max(FD_TARGET));
    if raised > soft {
        let _applied = setrlimit(Resource::RLIMIT_NOFILE, raised, hard);
    }
}

/// The `integration install|uninstall claude` one-shot, or `None` when this argv is not one.
///
/// Answers the exit code rather than exiting, so the ONE `exit` stays in `main` where the order is
/// readable.
fn integration_oneshot(argv: &[String], program: &str) -> Option<i32> {
    if argv.get(1).map(String::as_str) != Some("integration") {
        return None;
    }
    let log = Stderr::named(program);
    let subcommand = argv.get(2).map_or("", String::as_str);
    let target = argv.get(3).map_or("claude", String::as_str);
    if target != "claude" {
        log.say(&format!("unknown integration target '{target}' (only 'claude')"));
        log.say(&format!("usage: {program} integration install|uninstall claude"));
        return Some(2);
    }
    let environment = slopdesk_hook::install::process_environment();
    let home = slopdesk_hook::install::home_in(&environment);
    let settings = slopdesk_hook::install::settings_path(&environment, &home);
    match subcommand {
        "install" => {
            let hook = slopdesk_hook::install::hook_path(&environment, &home);
            let Some(relay) = services::staged_relay() else {
                log.say(&format!(
                    "no {} beside {program} — run `make build`",
                    slopdesk_hook::install::RELAY_NAME
                ));
                return Some(2);
            };
            match slopdesk_hook::install::install(&settings, &hook, &relay) {
                Ok(written) => {
                    log.say(&format!("installed Claude Code hooks → {written}"));
                    log.say("restart claude in a slopdesk pane — the host is already listening.");
                    Some(0)
                },
                Err(why) => {
                    log.say(&format!("integration install failed: {why}"));
                    Some(2)
                },
            }
        },
        "uninstall" => {
            match slopdesk_hook::install::uninstall(&settings) {
                Ok(written) => {
                    log.say(&format!("removed Claude Code hooks from {written}"));
                    Some(0)
                },
                Err(why) => {
                    log.say(&format!("integration uninstall failed: {why}"));
                    Some(2)
                },
            }
        },
        other => {
            log.say(&format!(
                "unknown integration subcommand '{other}' (use install | uninstall)"
            ));
            log.say(&format!("usage: {program} integration install|uninstall claude"));
            Some(2)
        },
    }
}

/// The sibling `slopdesk-ctl`, or `None` when it is not there.
///
/// Derived from `argv[0]`'s directory because hostd and ctl ship together. Absent leaves the
/// export unset, and a spawned agent falls back to a `PATH` lookup.
fn sibling_ctl(argv: &[String]) -> Option<String> {
    let here = std::path::Path::new(argv.first()?);
    let candidate = here.parent()?.join("slopdesk-ctl");
    candidate
        .is_file()
        .then(|| candidate.to_string_lossy().into_owned())
}

/// The seven gates, resolved through the settings overlay.
fn resolve_gates(overlay: &Overlay) -> HostAgentGates<'static> {
    // The texts must outlive the borrow the gates hold, and the ONE non-boolean gate is the reason:
    // `auto_progress_commands` crosses to superd as-is. Leaking it is the honest answer for a value
    // read once at launch and read from for the process's life — the alternative is an owned copy
    // per spawn of a string nobody ever mutates.
    let values: Vec<Option<&'static str>> = gates::KEYS
        .iter()
        .map(|key| overlay.get(key).map(|text| &*Box::leak(text.into_boxed_str())))
        .collect();
    HostAgentGates::from_env(&values)
}

/// The environment every spawned pane is built from.
fn host_env(
    gates: &HostAgentGates<'_>,
    ctl_binary: Option<&str>,
    supervisor: &SupervisorClient,
) -> (HostEnv, bool) {
    let parent: std::collections::BTreeMap<String, String> = std::env::vars().collect();
    let (term, fell_back) =
        slopdesk_probe::terminfo::resolve(gates::DEFAULT_TERM, gates::FALLBACK_TERM, &parent);
    // The two child-facing addresses are superd's, and hostd is TOLD them in the `hello` reply — a
    // constant for either here would be a second answer to a question only superd can settle.
    let handshake = supervisor.handshake();
    let env = HostEnv {
        shell: slopdesk_muxsession::spawn_env::login_shell(&parent).to_owned(),
        parent,
        term,
        version: env!("CARGO_PKG_VERSION").to_owned(),
        agent_socket_path: handshake.and_then(|shook| shook.hook_socket_path.clone()),
        control_socket_path: gates
            .agent_control
            .then(|| handshake.and_then(|shook| shook.control_socket_path.clone()))
            .flatten(),
        ctl_binary_path: ctl_binary.map(str::to_owned),
    };
    (env, fell_back)
}

/// The detach TTL, or `None` for never.
///
/// Never is the default, and it is tmux's: a detached shell is often a running agent the user
/// deliberately left working, and reaping one on a timer is how that work disappears. A POSITIVE
/// `SLOPDESK_DETACH_TTL_SECS` opts into timed eviction; `0` and anything unparseable mean never.
fn detach_ttl() -> Option<Duration> {
    std::env::var("SLOPDESK_DETACH_TTL_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .map(Duration::from_secs)
}

/// The in-memory ring's scrollback cap.
fn scrollback_bytes() -> usize {
    std::env::var("SLOPDESK_SCROLLBACK_BYTES")
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(slopdesk_wire::replay::ReplayBuffer::DEFAULT_SCROLLBACK_BYTES)
}

/// How far one subscriber may fall behind before it is evicted. `0` disables eviction entirely.
fn lag_bytes(overlay: &Overlay) -> u64 {
    overlay
        .get("SLOPDESK_SUB_LAG_BYTES")
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(DEFAULT_LAG_BYTES)
}

/// Sweeps orphaned journals off the start-up path, then on a timer for the daemon's life.
///
/// OFF the start-up path because a cold Application Support scan must never delay a bind, and on a
/// TIMER because a single sweep would leave every later link-drop detach and TTL eviction's orphan
/// unbounded until a restart.
fn start_journal_sweep(transcripts: Arc<DiskTranscripts>) {
    let _spawned = std::thread::Builder::new()
        .name("slopdesk-journal-sweep".to_owned())
        .spawn(move || {
            loop {
                transcripts.sweep();
                std::thread::sleep(SWEEP_INTERVAL);
            }
        });
}
