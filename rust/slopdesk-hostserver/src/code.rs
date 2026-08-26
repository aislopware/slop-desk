//! The host's code-server, and the four gates in front of it — the port of
//! `Sources/SlopDeskHost/CodeServerManager.swift`.
//!
//! **ONE shared instance, prewarmed.** code-server serves every folder from a single process — the
//! workbench resolves its folder from the client's `?folder=` query, so per-project children were
//! pure overhead (a Node runtime and an extension host each) AND fought over the session socket,
//! which is per user-data-dir and has exactly one owner. The requested root is still validated —
//! never report an endpoint for a path the host cannot see — but every root shares the one child.
//!
//! **`ensure` never waits.** It spawns, or observes, and answers the CURRENT state: the caller sits
//! on a metadata queue answering an RPC with a five-second client-side deadline, and a code-server
//! cold start can exceed it. The child is spawned with port `0` and the real port is learned from
//! its own `HTTP server listening on http://…` line — no pre-bind allocation race.
//!
//! **No idle reaper, deliberately.** The daemon prewarms at boot precisely so the workbench is
//! always warm, and a reaper would undo that every quiet stretch: the cold boot it forces onto the
//! next panel expand costs more than the idle Node runtime it frees.
//!
//! **No auth token.** The child runs `--auth none`: security is the `WireGuard` mesh, identically
//! to every other port hostd opens.
//!
//! ## The gates are on their own lock, and that is the one departure
//!
//! The Swift put the four boot gates under `ProbedPortService`'s single `NSLock`, to avoid keeping
//! two. That lock is no longer available to a face, because the boot closure now runs OUTSIDE it —
//! see `crate::service`'s header for the deadlock that forced it. So the gates are here, behind
//! their own mutex, taken only inside the boot closure. The nesting is one-way: a round takes the
//! service's lock, drops it, and only then takes this one.
//!
//! Nothing is lost by the split, because the gates and the child state were never read together:
//! the gates decide whether to spawn, and the child state decides whether to ask.

use std::fmt;
use std::path::Path;
use std::sync::{Arc, Mutex, Weak};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use slopdesk_sidecars::service_lifecycle::{
    BootAction, BootGates, CodeCommand, ExtensionInstall, OPEN_ATTEMPTS, ServiceState, boot_step,
    canonical_root, code_cli_flag, port_after_last_colon_following,
};
use slopdesk_wire::metadata::CodeFontSpec;

use crate::service::{
    BinaryLocator, Boot, Endpoint, LogSink, ProbedPortService, ReadinessProbe, ServiceHandle, Spawner,
};

/// The marker code-server's own announce line puts the port after — `[…] info  HTTP server
/// listening on http://0.0.0.0:62636/`.
const LISTENING_MARKER: &str = "HTTP server listening on http://";

/// The bound port in code-server's own announce line, or `None` for every other line.
///
/// The LAST-colon rule, because this is a third-party line naming an address we do not control: a
/// bracketed IPv6 host, a bare IPv4 or a whole URL all put the port after the final colon.
#[must_use]
pub fn parse_listening_port(line: &str) -> Option<u16> {
    port_after_last_colon_following(LISTENING_MARKER, line)
}

/// The host end of the workbench's command channel, as this manager needs it.
///
/// A seam, so a unit test never binds a real `AF_UNIX` listener — the same hang-safety rule that
/// makes the spawner injectable. The routing itself, and the terminal-run request the editor sends
/// back, are `docs/60` stage D.3's; what is here is the three calls the LIFECYCLE makes.
pub trait CodeBridge: Send + Sync + fmt::Debug {
    /// Binds the listener at `path`. Idempotent, and failures are silent: the bridge is an
    /// ACCELERATOR, and a host that cannot bind still opens files through the CLI.
    fn start(&self, path: &str);

    /// Asks the workbench window that owns `target` to open it. `false` means no connected window
    /// claims the path — nothing booted yet, or the file lives outside every open folder — which is
    /// the caller's signal to fall back to the CLI.
    fn open(&self, target: &str) -> bool;

    /// Closes the listener, drops every connection, unlinks the socket file. Idempotent.
    fn stop(&self);
}

/// Everything the seeder decides about a LAUNCH.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Profile {
    /// The child's argv after the binary path.
    pub arguments: Vec<String>,
    /// Where the bridge binds and the seeded extension dials back — pid-free, so a workbench that
    /// outlived a hostd reconnects to the same name (`docs/51` §1).
    pub bridge_socket: String,
}

/// Seeds the workbench profile before the FIRST spawn — settings, extensions, the retired sweep.
/// One fork of `slopdesk-codeseed`, which owns every one of those decisions.
pub type SettingsSeeder = Arc<dyn Fn() + Send + Sync>;

/// Runs the code-server CLI once to completion and answers its exit status; `None` when the exec
/// itself failed.
///
/// Distinct from a [`Spawner`]: the CLI is a short-lived command whose EXIT CODE is the whole
/// answer, not a supervised child.
pub type CliRunner = Arc<dyn Fn(&str, &[String]) -> Option<i32> + Send + Sync>;

/// The bundled marketplace extensions the profile registry does not carry yet. Empty spawns
/// straight away.
pub type MissingExtensions = Arc<dyn Fn() -> Vec<String> + Send + Sync>;

/// Everything the seeder decides about a launch. `None` means this host has no seeder, and the
/// panel reports unavailable rather than spawning a workbench on guessed arguments.
pub type ProfileReader = Arc<dyn Fn() -> Option<Profile> + Send + Sync>;

/// Folds a client's font spec into the live settings file; `true` when the file changed.
pub type FontSync = Arc<dyn Fn(&CodeFontSpec) -> bool + Send + Sync>;

/// Answers whether `path` is a directory the host can see. Injected because it is the one part of
/// root validation that can answer differently on two calls with the same argument.
pub type DirectoryCheck = Arc<dyn Fn(&str) -> bool + Send + Sync>;

/// The production directory check: a `stat`, and the reason `canonical_root` stops where it does.
#[must_use]
pub fn directory_exists(path: &str) -> bool {
    Path::new(path).is_dir()
}

/// The four one-shot gates between "there is a binary" and "spawn".
#[derive(Debug)]
struct Gates {
    /// Latched by the first spawn — the settings seed runs at most once per manager lifetime. The
    /// seeder is a no-op when the file exists anyway; this skips the repeat file checks.
    settings_seeded: bool,
    /// Latched with it — the listener binds once, lazily, so a host whose user never opens the code
    /// panel never creates the socket at all.
    bridge_started: bool,
    /// Where the one-shot marketplace install stands.
    install: ExtensionInstall,
}

/// Supervises the host's code-server: the backend of the client's right-sidebar embedded editor.
pub struct CodeServerManager {
    service: Arc<ProbedPortService>,
    gates: Mutex<Gates>,
    locate_binary: BinaryLocator,
    spawn: Spawner,
    seed_settings: SettingsSeeder,
    run_cli: CliRunner,
    missing_extensions: MissingExtensions,
    read_profile: ProfileReader,
    sync_font: FontSync,
    is_directory: DirectoryCheck,
    bridge: Arc<dyn CodeBridge>,
    open_retry_delay: Duration,
}

/// The seams a manager is built from, one struct because there are ten of them and a ten-argument
/// constructor is a line of call sites nobody can read.
#[derive(Clone)]
pub struct CodeServerSeams {
    /// Finds the code-server executable, or `None` when the host has none.
    pub binary_locator: BinaryLocator,
    /// Spawns the child through superd.
    pub spawner: Spawner,
    /// The bounded loopback connect.
    pub readiness_probe: ReadinessProbe,
    /// The profile seed.
    pub settings_seeder: SettingsSeeder,
    /// The one-shot CLI.
    pub cli_runner: CliRunner,
    /// The registry read.
    pub missing_extensions: MissingExtensions,
    /// The font patch.
    pub font_sync: FontSync,
    /// The seeder's launch answers.
    pub profile_reader: ProfileReader,
    /// Whether a path is a directory the host can see.
    pub is_directory: DirectoryCheck,
    /// The workbench's command channel.
    pub bridge: Arc<dyn CodeBridge>,
}

impl fmt::Debug for CodeServerSeams {
    /// Written out because nine of the ten fields are bare closures, and there is nothing to print
    /// about one.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CodeServerSeams")
            .field("bridge", &self.bridge)
            .finish_non_exhaustive()
    }
}

impl fmt::Debug for CodeServerManager {
    /// Written out because eight of the twelve fields are bare closures. The three that carry state
    /// are the three a reader wants.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CodeServerManager")
            .field("service", &self.service)
            .field("gates", &self.gates)
            .field("bridge", &self.bridge)
            .finish_non_exhaustive()
    }
}

impl CodeServerManager {
    /// The CLI open retry delay the Swift defaulted to: ten attempts at two seconds is an
    /// eighteen-second window, which covers a cold server boot, the client's poll and the webview's
    /// workbench boot before the session socket exists.
    pub const DEFAULT_OPEN_RETRY_DELAY: Duration = Duration::from_secs(2);

    /// A manager over `seams`.
    #[must_use]
    pub fn new(seams: CodeServerSeams, probe_interval: Duration, open_retry_delay: Duration) -> Self {
        Self {
            service: Arc::new(ProbedPortService::new(
                Arc::clone(&seams.readiness_probe),
                probe_interval,
            )),
            gates: Mutex::new(Gates {
                settings_seeded: false,
                bridge_started: false,
                install: ExtensionInstall::Unchecked,
            }),
            locate_binary: seams.binary_locator,
            spawn: seams.spawner,
            seed_settings: seams.settings_seeder,
            run_cli: seams.cli_runner,
            missing_extensions: seams.missing_extensions,
            read_profile: seams.profile_reader,
            sync_font: seams.font_sync,
            is_directory: seams.is_directory,
            bridge: seams.bridge,
            open_retry_delay,
        }
    }

    /// Boots the shared code-server WITHOUT a client request — the daemon calls this once its
    /// listeners are up, so the first panel expand finds a live workbench instead of paying the
    /// seed, install and Node-boot chain interactively.
    ///
    /// Identical to [`CodeServerManager::ensure`] minus the root validation: there is no root, one
    /// child serves every folder. A host with no binary is a silent no-op — `unavailable` is the
    /// verb's ANSWER, not a boot failure.
    pub fn prewarm(self: &Arc<Self>) {
        let _ignored = self.boot();
    }

    /// Ensures the shared code-server and reports where it stands RIGHT NOW. Never waits.
    ///
    /// `None` when `project_root` is not an absolute path to an existing host directory — never
    /// hand out an endpoint for a path the host cannot see.
    #[must_use]
    pub fn ensure(self: &Arc<Self>, project_root: &str) -> Option<Endpoint> {
        let root = canonical_root(project_root)?;
        if !(self.is_directory)(root) {
            return None;
        }
        Some(self.boot())
    }

    /// Opens `target` — a host file path, optionally `:line[:col]`-suffixed — in the running
    /// workbench, on a thread of its own.
    ///
    /// TWO routes, tried in that order on EVERY attempt rather than once: the bridge socket, one
    /// line to the already-attached extension host of the window whose folder contains the file;
    /// then `code-server -r`, a fresh Node CLI routed through the per-user session socket to the
    /// most recently registered workbench. On a cold start neither exists yet and whichever appears
    /// first should win the race; once a window is attached the bridge returns on the opening
    /// attempt and the CLI — a whole Node process — never runs at all.
    ///
    /// Answers `None` when there is no code-server binary, which is the caller's cue to fall back
    /// to a default-app open. Otherwise the join handle, which the caller is NOT expected to
    /// wait on: accepted-not-completed, mirroring `ensure`'s never-wait contract.
    pub fn open_in_workbench(
        self: &Arc<Self>,
        target: &str,
        project_root: &str,
        on_log: Option<LogSink>,
    ) -> Option<JoinHandle<bool>> {
        let binary = (self.locate_binary)()?;
        let _ignored = self.ensure(project_root);
        let run = Arc::clone(&self.run_cli);
        let bridge = Arc::clone(&self.bridge);
        let delay = self.open_retry_delay;
        let target = target.to_owned();
        thread::Builder::new()
            .name("slopdesk-code-open".to_owned())
            .spawn(move || {
                for attempt in 0..OPEN_ATTEMPTS {
                    if bridge.open(&target) {
                        return true;
                    }
                    let argv = [code_cli_flag(CodeCommand::ReuseWindow).to_owned(), target.clone()];
                    if run(&binary, &argv) == Some(0) {
                        return true;
                    }
                    if attempt.saturating_add(1) >= OPEN_ATTEMPTS {
                        break;
                    }
                    thread::sleep(delay);
                }
                if let Some(on_log) = on_log {
                    on_log(&format!(
                        "code-server -r {target} never landed (no workbench session?)",
                    ));
                }
                false
            })
            .ok()
    }

    /// Folds a client's font spec into the live settings file. `true` when the file changed.
    ///
    /// Serialized under the gates lock like every other settings touch. The patch itself belongs to
    /// the seeder: it is a decision about a JSON file the workbench also writes.
    pub fn sync_editor_font(&self, spec: &CodeFontSpec) -> bool {
        let Ok(_gates) = self.gates.lock() else {
            return false;
        };
        (self.sync_font)(spec)
    }

    /// The port the running workbench announced, once it has.
    #[must_use]
    pub fn served_port(&self) -> Option<u16> {
        self.service.served_port()
    }

    /// Ends the workbench for good. With no idle reaper this is the ONLY thing that stops it.
    ///
    /// **Not the daemon-shutdown path** — that is [`CodeServerManager::relinquish`]. Routing a
    /// hostd stop back through here restores exactly what `docs/51` exists to remove, one panel
    /// down: every host edit would again cost the user a Node boot before the editor came back.
    pub fn shutdown(&self) {
        if let Some(stranded) = self.forget() {
            stranded.terminate();
        }
    }

    /// Lets the workbench GO: hostd stops listening and superd keeps the Node process running, so
    /// the next hostd adopts it and the panel is warm the instant it comes back.
    ///
    /// The bridge listener DOES stop — that socket is hostd's, not superd's. The surviving
    /// extension host reconnects to the same pid-free path within one of its five-second ticks.
    pub fn relinquish(&self) {
        if let Some(released) = self.forget() {
            released.relinquish();
        }
    }

    // MARK: Internals

    /// The one shared boot path: observe a live child, or walk the gates and spawn.
    ///
    /// The observe-or-drop head, the spawn generation and the probe are [`ProbedPortService`]'s;
    /// the four gates between the binary and the spawn are what the WORKBENCH adds to that
    /// shape, and the reason this manager passes a closure rather than being one.
    fn boot(self: &Arc<Self>) -> Endpoint {
        let manager = Arc::clone(self);
        let service = Arc::clone(&self.service);
        service.ensure(move |generation| manager.gated_spawn(generation))
    }

    /// The gates, and the spawn behind them. Runs with the service's lock RELEASED.
    fn gated_spawn(self: &Arc<Self>, generation: u64) -> Boot {
        let binary = (self.locate_binary)();
        // A host with no seeder has no argv and no bridge socket to give the child. Reporting
        // unavailable is the honest answer: a workbench launched on guessed arguments is a different
        // program, not a degraded panel — which is why the rule reads the two as one `launchable`.
        let profile = (self.read_profile)();
        let launchable = binary.is_some() && profile.is_some();

        let Ok(mut gates) = self.gates.lock() else {
            return Boot::NotYet(ServiceState::Starting);
        };
        // Reading the registry is a fork, so it happens only on the round that could act on it.
        let missing = if launchable && gates.install == ExtensionInstall::Unchecked {
            (self.missing_extensions)()
        } else {
            Vec::new()
        };
        let step = boot_step(BootGates {
            missing: missing.len(),
            install: gates.install,
            launchable,
            settings_seeded: gates.settings_seeded,
            bridge_started: gates.bridge_started,
        });
        gates.install = step.install;
        if step.seed_settings {
            gates.settings_seeded = true;
            (self.seed_settings)();
        }
        if let (true, Some(profile)) = (step.start_bridge, profile.as_ref()) {
            gates.bridge_started = true;
            self.bridge.start(&profile.bridge_socket);
        }
        if let (true, Some(binary)) = (step.install_extensions, binary.as_ref()) {
            self.install_bundled_extensions(missing, binary);
        }
        drop(gates);

        let (BootAction::Spawn, Some(binary), Some(profile)) = (step.action, binary, profile) else {
            return match step.action {
                BootAction::Report(state) => Boot::NotYet(state),
                // Unreachable: the destructuring above only falls through on a `Report`, or on a
                // `Spawn` the rule answers exclusively when `launchable` — which is both halves
                // present. `starting` keeps the client polling either way.
                BootAction::Spawn => Boot::NotYet(ServiceState::Starting),
            };
        };
        let on_line = self
            .service
            .port_sink(generation, None, Arc::new(parse_listening_port));
        match (self.spawn)(&binary, &profile.arguments, on_line) {
            Ok(handle) => Boot::Spawned(handle),
            Err(_failed) => Boot::NotYet(ServiceState::Unavailable),
        }
    }

    /// Runs `code-server --install-extension <id>` for each missing bundled extension, then latches
    /// the install `Done` — unconditionally: a failed install (an offline host, a marketplace
    /// hiccup) logs and moves on, and the next hostd launch retries because the registry still
    /// misses the id.
    ///
    /// The caller holds the gates lock and has already latched `Installing`, so a racing second
    /// round never double-spawns this.
    fn install_bundled_extensions(self: &Arc<Self>, identifiers: Vec<String>, binary: &str) {
        let manager = Arc::downgrade(self);
        let run = Arc::clone(&self.run_cli);
        let binary = binary.to_owned();
        let started = thread::Builder::new()
            .name("slopdesk-code-extensions".to_owned())
            .spawn(move || {
                for identifier in &identifiers {
                    let argv = [
                        code_cli_flag(CodeCommand::InstallExtension).to_owned(),
                        identifier.clone(),
                    ];
                    let _ignored = run(&binary, &argv);
                }
                if let Some(manager) = Weak::upgrade(&manager) {
                    manager.finish_bundled_extension_install();
                }
            });
        if started.is_err() {
            // A process out of threads cannot install, and leaving the gate at `Installing` would
            // wedge the panel at `starting` for the rest of the daemon's life. Latch it here
            // instead; the next hostd launch retries because the registry still misses the ids.
            if let Ok(mut gates) = self.gates.lock() {
                gates.install = ExtensionInstall::Done;
            }
        }
    }

    /// The `Done` latch, and then the CONTINUATION of the boot the install deferred: the spawn
    /// happens right here, not on the next round — a prewarmed host has no client polling to pick
    /// it up, and a polled one saves a round.
    fn finish_bundled_extension_install(self: &Arc<Self>) {
        if let Ok(mut gates) = self.gates.lock() {
            gates.install = ExtensionInstall::Done;
        }
        let _ignored = self.boot();
    }

    /// Drops the record and stops the bridge, and decides nothing about the child. Answers the
    /// handle for the caller to end or release.
    fn forget(&self) -> Option<Arc<dyn ServiceHandle>> {
        let stranded = self.service.forget();
        if let Ok(mut gates) = self.gates.lock() {
            gates.bridge_started = false;
        }
        self.bridge.stop();
        stranded
    }
}
