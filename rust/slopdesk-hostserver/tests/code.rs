//! The workbench manager: the four gates, the root validation, and the two open routes.
//!
//! Nothing here forks Node, binds a socket or touches a settings file — every one of the ten seams
//! is a closure, which is the same hang-safety line the Swift suite drew. What is under test is the
//! ORDER: seed before bridge before install before spawn, each latched once, and an install that
//! continues the boot it deferred rather than waiting for the next round.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

pub mod support;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use slopdesk_hostserver::code::{
    CodeBridge, CodeServerManager, CodeServerSeams, Profile, parse_listening_port,
};
use slopdesk_hostserver::service::{Endpoint, LogSink, ServiceHandle, SpawnFailed, Spawner};
use slopdesk_sidecars::service_lifecycle::ServiceState;
use support::{Backend, as_service};

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// No round in here may cross it: every probe these tests want is the first one.
const NEVER_AGAIN: Duration = Duration::from_secs(3600);

/// The retry delay a test that expects NO retry can afford to have.
const IMPATIENT: Duration = Duration::from_millis(10);

/// The one root these tests call real.
const ROOT: &str = "/work/slop-desk";

// MARK: - The seams

/// A bridge that counts what it was asked and answers what it was told.
#[derive(Debug)]
struct Bridge {
    claims: bool,
    starts: Mutex<Vec<String>>,
    opens: AtomicUsize,
    stops: AtomicUsize,
}

impl Bridge {
    fn new(claims: bool) -> Arc<Self> {
        Arc::new(Self {
            claims,
            starts: Mutex::new(Vec::new()),
            opens: AtomicUsize::new(0),
            stops: AtomicUsize::new(0),
        })
    }

    fn bound(&self) -> Vec<String> {
        self.starts.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl CodeBridge for Bridge {
    fn start(&self, path: &str) {
        self.starts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(path.to_owned());
    }

    fn open(&self, _target: &str) -> bool {
        self.opens.fetch_add(1, Ordering::SeqCst);
        self.claims
    }

    fn stop(&self) {
        self.stops.fetch_add(1, Ordering::SeqCst);
    }
}

/// Everything a test wants to look at after a round.
struct Ledger {
    seeds: Arc<AtomicUsize>,
    installs: Arc<Mutex<Vec<String>>>,
    spawns: Arc<AtomicUsize>,
    spawned: Receiver<()>,
    backend: Arc<Backend>,
}

impl Ledger {
    fn installed(&self) -> Vec<String> {
        self.installs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

/// A manager over fakes, plus the ledger of what they were asked.
///
/// `missing` is what the profile registry is short of, `profile` whether this host has a seeder at
/// all, and `binary` whether it has an executable.
fn manager(
    missing: Vec<String>,
    profile: Option<Profile>,
    binary: Option<String>,
    bridge: &Arc<Bridge>,
) -> (Arc<CodeServerManager>, Ledger) {
    let seeds = Arc::new(AtomicUsize::new(0));
    let installs = Arc::new(Mutex::new(Vec::new()));
    let spawns = Arc::new(AtomicUsize::new(0));
    let backend = Backend::up();
    let (child_started, spawned): (Sender<()>, Receiver<()>) = channel();

    let seeding = Arc::clone(&seeds);
    let installing = Arc::clone(&installs);
    let spawning = Arc::clone(&spawns);
    let handle = Arc::clone(&backend);
    let forks: Spawner = Arc::new(move |_binary, _arguments, _sink: LogSink| {
        spawning.fetch_add(1, Ordering::SeqCst);
        let _ignored = child_started.send(());
        Ok(as_service(&handle))
    });

    let seams = CodeServerSeams {
        binary_locator: Arc::new(move || binary.clone()),
        spawner: forks,
        readiness_probe: Arc::new(|_port| false),
        settings_seeder: Arc::new(move || {
            seeding.fetch_add(1, Ordering::SeqCst);
        }),
        cli_runner: Arc::new(move |_binary, arguments| {
            installing
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .extend(arguments.iter().cloned());
            Some(0)
        }),
        missing_extensions: Arc::new(move || missing.clone()),
        font_sync: Arc::new(|_spec| true),
        profile_reader: Arc::new(move || profile.clone()),
        is_directory: Arc::new(|path| path == ROOT),
        bridge: Arc::<Bridge>::clone(bridge),
    };
    let manager = Arc::new(CodeServerManager::new(seams, NEVER_AGAIN, IMPATIENT));
    (manager, Ledger {
        seeds,
        installs,
        spawns,
        spawned,
        backend,
    })
}

/// A seeder profile.
fn profile() -> Profile {
    Profile {
        arguments: vec!["--auth".to_owned(), "none".to_owned()],
        bridge_socket: "/tmp/slopdesk-code-bridge.sock".to_owned(),
    }
}

// MARK: - The gates

#[test]
fn a_host_with_no_seeder_reports_unavailable_and_spawns_nothing() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(Vec::new(), None, Some("/bin/code-server".to_owned()), &bridge);

    let endpoint = manager.ensure(ROOT);

    assert_eq!(endpoint, Some(Endpoint::nothing(ServiceState::Unavailable)));
    assert_eq!(ledger.spawns.load(Ordering::SeqCst), 0);
    assert_eq!(
        ledger.seeds.load(Ordering::SeqCst),
        0,
        "a host that cannot launch must not be seeded for a launch it will not make",
    );
    assert!(bridge.bound().is_empty());
}

#[test]
fn a_host_with_no_binary_reports_unavailable() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(Vec::new(), Some(profile()), None, &bridge);

    assert_eq!(
        manager.ensure(ROOT),
        Some(Endpoint::nothing(ServiceState::Unavailable))
    );
    assert_eq!(ledger.spawns.load(Ordering::SeqCst), 0);
}

#[test]
fn the_seed_and_the_bridge_bind_happen_once_and_the_child_spawns() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );

    let first = manager.ensure(ROOT);
    manager.prewarm();
    let third = manager.ensure(ROOT);

    assert_eq!(first, Some(Endpoint::nothing(ServiceState::Starting)));
    assert_eq!(third, Some(Endpoint::nothing(ServiceState::Starting)));
    assert_eq!(
        ledger.spawns.load(Ordering::SeqCst),
        1,
        "one child serves every folder"
    );
    assert_eq!(ledger.seeds.load(Ordering::SeqCst), 1);
    assert_eq!(bridge.bound(), vec![profile().bridge_socket]);
    assert!(ledger.installed().is_empty(), "nothing was missing");
}

/// The install DEFERS the spawn — a boot writing `extensions.json` while the CLI writes it is how
/// registrations get lost — and then continues it rather than waiting for the next round. A
/// prewarmed host has no client polling to pick that up.
#[test]
fn missing_extensions_defer_the_spawn_and_the_install_continues_it() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        vec!["slopdesk.theme".to_owned(), "slopdesk.bridge".to_owned()],
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );

    let deferred = manager.ensure(ROOT);
    ledger
        .spawned
        .recv_timeout(GENEROUS)
        .expect("the install continues the boot it deferred");

    assert_eq!(
        deferred,
        Some(Endpoint::nothing(ServiceState::Starting)),
        "the round that defers still reports starting, and the client keeps polling",
    );
    assert_eq!(ledger.installed(), vec![
        "--install-extension".to_owned(),
        "slopdesk.theme".to_owned(),
        "--install-extension".to_owned(),
        "slopdesk.bridge".to_owned(),
    ],);
    assert_eq!(ledger.spawns.load(Ordering::SeqCst), 1);
    assert_eq!(
        ledger.seeds.load(Ordering::SeqCst),
        1,
        "the seed and the bind happen on the round that defers, not with the spawn",
    );
    assert_eq!(bridge.bound().len(), 1);
}

// MARK: - The root

#[test]
fn a_root_the_host_cannot_see_is_refused_without_booting() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );

    assert_eq!(manager.ensure("/nowhere"), None);
    assert_eq!(manager.ensure("relative/path"), None);
    assert_eq!(
        ledger.spawns.load(Ordering::SeqCst),
        0,
        "never hand out an endpoint for a path the host cannot see",
    );
}

#[test]
fn a_trailing_slash_names_the_same_project() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );

    assert!(manager.ensure(&format!("{ROOT}/")).is_some());
    assert!(manager.ensure(ROOT).is_some());
    assert_eq!(ledger.spawns.load(Ordering::SeqCst), 1);
}

// MARK: - The end of a workbench's life

#[test]
fn a_relinquish_lets_the_workbench_go_and_still_stops_the_bridge() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );
    assert!(manager.ensure(ROOT).is_some());

    manager.relinquish();

    assert_eq!(ledger.backend.relinquishes(), 1);
    assert_eq!(ledger.backend.terminates(), 0);
    assert_eq!(
        bridge.stops.load(Ordering::SeqCst),
        1,
        "that socket is hostd's, not superd's",
    );
    // The bind gate reopened with it, so the next boot binds again rather than serving a listener
    // this manager already closed.
    assert!(manager.ensure(ROOT).is_some());
    assert_eq!(bridge.bound().len(), 2);
}

#[test]
fn a_shutdown_ends_the_workbench() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );
    assert!(manager.ensure(ROOT).is_some());

    manager.shutdown();

    assert_eq!(ledger.backend.terminates(), 1);
    assert_eq!(ledger.backend.relinquishes(), 0);
}

// MARK: - The two open routes

#[test]
fn the_bridge_wins_the_open_and_the_cli_never_runs() {
    let bridge = Bridge::new(true);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );

    let landed = manager
        .open_in_workbench("/work/slop-desk/README.md:12", ROOT, None)
        .expect("a host with a binary answers a handle")
        .join()
        .expect("the open thread finishes");

    assert!(landed);
    assert_eq!(bridge.opens.load(Ordering::SeqCst), 1);
    assert!(
        ledger.installed().is_empty(),
        "the CLI is a whole Node process, and an attached window means it never runs",
    );
}

#[test]
fn the_cli_is_the_fallback_when_no_window_claims_the_path() {
    let bridge = Bridge::new(false);
    let (manager, ledger) = manager(
        Vec::new(),
        Some(profile()),
        Some("/bin/code-server".to_owned()),
        &bridge,
    );

    let landed = manager
        .open_in_workbench("/work/slop-desk/README.md", ROOT, None)
        .expect("a host with a binary answers a handle")
        .join()
        .expect("the open thread finishes");

    assert!(landed);
    assert_eq!(
        bridge.opens.load(Ordering::SeqCst),
        1,
        "the bridge is tried first"
    );
    assert_eq!(
        ledger.installed(),
        vec!["-r".to_owned(), "/work/slop-desk/README.md".to_owned()],
        "`-r` is the form every shipped code-server accepts; the long spelling is not",
    );
}

#[test]
fn a_host_with_no_binary_answers_no_open_handle() {
    let bridge = Bridge::new(true);
    let (manager, _ledger) = manager(Vec::new(), Some(profile()), None, &bridge);

    assert!(
        manager.open_in_workbench("/work/x", ROOT, None).is_none(),
        "the caller falls back to a default-app open",
    );
}

// MARK: - The announce line

#[test]
fn the_announce_line_is_read_after_its_last_colon() {
    assert_eq!(
        parse_listening_port("[2026-08-26] info  HTTP server listening on http://0.0.0.0:62636/"),
        Some(62636),
    );
    assert_eq!(
        parse_listening_port("[2026-08-26] info  HTTP server listening on http://[::1]:8080/"),
        Some(8080),
        "a bracketed IPv6 host puts the port after the final colon too",
    );
    assert_eq!(
        parse_listening_port("[2026-08-26] info  Using config file /x/y"),
        None
    );
}

/// A spawn that fails is `unavailable` for this face — a broken binary reads the same as an absent
/// one — and it leaves no record, so the next round tries again.
#[test]
fn a_failed_spawn_is_unavailable_and_leaves_nothing_behind() {
    let bridge = Bridge::new(false);
    let refusing: Spawner = Arc::new(|_binary, _arguments, _sink| {
        Err(SpawnFailed {
            reason: "superd is not running".to_owned(),
        })
    });
    let seams = CodeServerSeams {
        binary_locator: Arc::new(|| Some("/bin/code-server".to_owned())),
        spawner: refusing,
        readiness_probe: Arc::new(|_port| false),
        settings_seeder: Arc::new(|| {}),
        cli_runner: Arc::new(|_binary, _arguments| Some(0)),
        missing_extensions: Arc::new(Vec::new),
        font_sync: Arc::new(|_spec| true),
        profile_reader: Arc::new(|| Some(profile())),
        is_directory: Arc::new(|path| path == ROOT),
        bridge: Arc::<Bridge>::clone(&bridge),
    };
    let manager = Arc::new(CodeServerManager::new(seams, NEVER_AGAIN, IMPATIENT));

    assert_eq!(
        manager.ensure(ROOT),
        Some(Endpoint::nothing(ServiceState::Unavailable)),
    );
    assert_eq!(
        manager.ensure(ROOT),
        Some(Endpoint::nothing(ServiceState::Unavailable)),
        "a boot that produced no child leaves nothing for the next round to observe",
    );
}

/// The handle the manager hands out is the one superd holds, and the two ends of its life are the
/// only effects the table ever has on it.
#[test]
fn the_handle_a_manager_holds_answers_the_service_questions() {
    let backend = Backend::up();
    let handle: Arc<dyn ServiceHandle> = as_service(&backend);

    assert!(handle.is_running());
    backend.die();
    assert!(
        !handle.is_running(),
        "a dead child is the next round's cue to respawn"
    );
}
