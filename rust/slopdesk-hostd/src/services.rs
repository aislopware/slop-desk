//! The production doors behind the twelve side-effecting metadata verbs.
//!
//! [`slopdesk_hostserver`] holds the DECISIONS — which verb routes where, what a malformed payload
//! answers, when a child is respawned. This module holds the effects those decisions actuate: where
//! a binary is, how a child is forked, whether a port answers, what a settings file says. Same
//! split as `repowatch`, and for the same reason: the decisions are testable without a machine and
//! these are not testable without one.
//!
//! ## Three ports collapse into calls
//! `CodeSeed.swift` forked `slopdesk-codeseed` six ways and parsed a JSON object off its stdout;
//! `AndroidServiceManager` kept a string literal equal to `androidd`'s announce marker by a lint
//! rule; `HostServiceProcess` re-implemented a binary search order the Rust already owned. All
//! three were Swift reaching a Rust program it could not link. hostd IS Rust, so it links them: the
//! seeder's six questions are six function calls, the marker is
//! [`slopdesk_androidd::server::ANNOUNCE_PREFIX`] itself, and the search order is
//! [`slopdesk_androidd::toolchain::locate_tool`]. Nothing here re-spells a fact another crate
//! holds.
//!
//! ## Every service is superd's child, not this daemon's
//! [`ServiceProcess::spawn_or_adopt`] under a stable `service:<name>` pane id. A restart ADOPTS
//! what it finds, so a workbench, a simulator panel and a live device mirror all survive
//! `just host-restart`, and the port is re-learned by replaying the child's own announce line from
//! offset 0 of superd's ring. No state file, nothing to go stale.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use slopdesk_hostserver::ServiceProcess;
use slopdesk_hostserver::agentaction::InstallsAgentHooks;
use slopdesk_hostserver::bridge::CodeBridgeServer;
use slopdesk_hostserver::code::{CodeServerSeams, Profile as CodeProfile, directory_exists};
use slopdesk_hostserver::ensure::Profile as EnsureProfile;
use slopdesk_hostserver::service::{BinaryLocator, LogSink, ReadinessProbe, ServiceHandle, Spawner};
use slopdesk_sidecars::service_lifecycle::{
    ServiceState, announced_version, port_after_last_colon_following,
};
use slopdesk_superclient::client::SupervisorClient;
use slopdesk_wire::metadata::MetadataVerb;

use crate::observer::Stderr;

/// The bounded loopback connect a readiness probe is.
///
/// 250 ms, the Swift's own budget: this runs on a pane's serial executor answering an RPC with a
/// five-second client deadline, and a filtered or blackholed port must time out rather than park
/// the executor that the same pane's project-key walk uses. `connect_timeout` is a non-blocking
/// connect plus a `poll`, which is exactly what the Swift hand-wrote.
const PROBE_TIMEOUT: Duration = Duration::from_millis(250);

/// `code-server`'s override variable. Everything the seeder writes is keyed to a workbench version,
/// so the pinned copy leading the search order matters more here than for any other tool.
const CODE_SERVER_BIN_ENV_KEY: &str = "SLOPDESK_CODE_SERVER_BIN";

/// The simulator server's override variable; the hardware gate points it at its own build.
const SIMULATOR_BIN_ENV_KEY: &str = "SLOPDESK_SIMULATOR_SERVER_BIN";

/// The simulator server's program name.
const SIMULATOR_BINARY: &str = "baguette";

/// The Android bridge daemon's program name, and with it the pane id `service:androidd`.
const ANDROID_BINARY: &str = "slopdesk-androidd";

/// What superd files the bridge under.
const ANDROID_SERVICE: &str = "androidd";

/// Whether something is listening on `127.0.0.1:port`. Bounded, never hangs.
#[must_use]
pub fn is_listening(port: u16) -> bool {
    slopdesk_androidd::net::connect_loopback(port, PROBE_TIMEOUT).is_some()
}

/// The production readiness probe, shared by all three ensure-verb services.
#[must_use]
pub fn loopback_probe() -> ReadinessProbe {
    Arc::new(is_listening)
}

// MARK: - Where a program is

/// The vendored prefix and the committed `scrcpy-server` jar for the checkout this binary sits in.
///
/// Resolved ONCE from `current_exe`, because the answer cannot change while the process lives, and
/// `None` outside a checkout — which is the right answer for a released build, not a degradation:
/// the search order simply falls through to `PATH` and the host's own installs.
#[derive(Clone, Debug, Default)]
pub struct Vendored {
    /// `ThirdParty/tools/.prefix/bin`, the rung that outranks `PATH`.
    pub bin_dir: Option<PathBuf>,
    /// `ThirdParty/tools/vendor/scrcpy-server`, passed to the bridge daemon's argv.
    pub scrcpy_server_jar: Option<PathBuf>,
}

impl Vendored {
    /// The two paths for the checkout this executable sits in.
    #[must_use]
    pub fn from_current_exe() -> Self {
        let Ok(here) = std::env::current_exe() else {
            return Self::default();
        };
        Self {
            bin_dir: slopdesk_androidd::toolchain::vendored_bin_dir(&here),
            scrcpy_server_jar: slopdesk_androidd::toolchain::scrcpy_server_jar(&here),
        }
    }
}

/// The path hostd would spawn for `name`, under the one search order this repository has:
/// `$override`, then the vendored prefix, then `PATH`, then the homes `PATH` misses when hostd is
/// launched by launchd rather than a login shell.
#[must_use]
fn locate(name: &str, override_key: &str, vendored: Option<&Path>) -> Option<String> {
    let home = std::env::var("HOME").ok();
    let path = std::env::var("PATH").unwrap_or_default();
    slopdesk_androidd::toolchain::locate_tool(
        name,
        std::env::var(override_key).ok().as_deref(),
        &path,
        vendored,
        &slopdesk_androidd::toolchain::host_service_fallback_dirs(home.as_deref()),
    )
    .map(|found| found.to_string_lossy().into_owned())
}

/// A locator for `name`, resolving the environment at every call.
///
/// Per call rather than once, deliberately: a host that INSTALLS the tool while hostd runs starts
/// working on the next ensure round, which is the same self-healing the crash-drop gives.
fn locator(name: &'static str, override_key: &'static str, vendored: Option<PathBuf>) -> BinaryLocator {
    Arc::new(move || locate(name, override_key, vendored.as_deref()))
}

/// A locator for one of THIS tree's own daemons — a different search order, and the difference is
/// the point.
///
/// [`locate`] above finds somebody else's program, so it searches `PATH`. These five ship with this
/// checkout and speak a wire pinned to it, so a same-named binary on a `PATH` must never become
/// one: the rungs are the override, the installed copy, the directory this executable sits in, and
/// the crate's own cargo target. That rule is `slopdesk_sidecars::paths`, which is also where the
/// version audit resolves the binary it compares against — an audit reading a version off a path
/// the spawn would not use is an audit about nothing.
///
/// Per call, for [`locator`]'s reason: a host that installs the daemon while hostd runs starts
/// finding it on the next round.
pub(crate) fn own_daemon_locator(tool: &'static str) -> BinaryLocator {
    Arc::new(move || {
        slopdesk_sidecars::paths::locate_from_env(tool).map(|found| found.to_string_lossy().into_owned())
    })
}

// MARK: - How a child is forked

/// A spawner that hands `service` to superd, so the child outlives this daemon.
///
/// `environment` is the child's whole environment, not a delta: `code-server` needs the seeder's
/// marketplace gallery and bridge socket, while the other two inherit hostd's verbatim so that an
/// operator's `DEVELOPER_DIR`, `ANDROID_HOME` or `SLOPDESK_ANDROID_*` reaches their locators
/// unchanged — without this file knowing any of those names.
pub(crate) fn spawner(
    service: &'static str,
    environment: BTreeMap<String, String>,
    supervisor: &Arc<SupervisorClient>,
    log: &Arc<Stderr>,
) -> Spawner {
    let supervisor = Arc::clone(supervisor);
    let log = Arc::clone(log);
    Arc::new(move |binary: &str, arguments: &[String], on_line: LogSink| {
        let notes = Arc::clone(&log);
        let on_log: LogSink = Arc::new(move |line: &str| notes.say(line));
        ServiceProcess::spawn_or_adopt(
            service,
            binary,
            arguments.to_vec(),
            environment.clone(),
            &supervisor,
            on_line,
            Some(on_log),
        )
        .map(|process| -> Arc<dyn ServiceHandle> { process })
    })
}

/// hostd's own environment, as the map a spawn takes.
pub(crate) fn inherited_environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

// MARK: - The simulator server (verb 21)

/// The simulator server's profile.
///
/// argv: port `0` — learn the real one from the child's own line, no pre-bind race — on `0.0.0.0`
/// so mesh clients reach it. The client fronts it with a loopback relay anyway, and `baguette`
/// trusts loopback `Host`/`Origin` values by default, which is exactly what that relay presents.
///
/// A spawn that FAILED reports `unavailable`: a present-but-unrunnable `baguette` — a broken
/// Homebrew link, a quarantined build — reads the same as an absent one, and the panel's install
/// hint is the right surface for both.
#[must_use]
pub fn simulator_profile(
    vendored: &Vendored,
    supervisor: &Arc<SupervisorClient>,
    log: &Arc<Stderr>,
) -> EnsureProfile {
    EnsureProfile {
        verb: MetadataVerb::EnsureSimulatorServer,
        binary_locator: locator(SIMULATOR_BINARY, SIMULATOR_BIN_ENV_KEY, vendored.bin_dir.clone()),
        spawner: spawner(SIMULATOR_BINARY, inherited_environment(), supervisor, log),
        arguments: ["serve", "--port", "0", "--host", "0.0.0.0"]
            .map(str::to_owned)
            .to_vec(),
        parse_port: Arc::new(parse_simulator_port),
        parse_version: None,
        unspawnable: ServiceState::Unavailable,
    }
}

/// The port out of the SERVER FRAMEWORK's line, e.g. `… [HummingbirdCore] Server started and
/// listening on 0.0.0.0:54593`.
///
/// That line is the only usable source: `baguette`'s own `[baguette] listening on
/// http://0.0.0.0:0/simulators` banner echoes the port it was ASKED for, which under `--port 0` is
/// literally `0` — and the parser refuses a zero, so the banner cannot win even if a future build
/// reworded it into this shape.
///
/// The LAST-colon rule, because this is a third-party line naming an address we do not control: a
/// bracketed IPv6 host, a bare IPv4 and a whole URL all put the port after the final colon.
fn parse_simulator_port(line: &str) -> Option<u16> {
    port_after_last_colon_following("listening on ", line)
}

// MARK: - The Android bridge (verb 22)

/// The bridge daemon's profile.
///
/// The two vendored paths are PASSED rather than left to the far side to find: hostd already walks
/// up for `ThirdParty/tools/tools.lock` — it does so for the code and simulator panels too — and a
/// daemon adopted from a differently-configured hostd must not silently resolve to different tools.
///
/// A spawn that FAILED reports `starting`, unlike the panel backends: superd unreachable or a
/// thread limit says nothing about whether this host HAS a bridge, and `unavailable` would render
/// the install hint over a daemon that is merely late. `unavailable` here means only that there is
/// no `slopdesk-androidd` on this machine — a missing `adb`, `emulator` or `scrcpy-server` is
/// reported by the daemon per operation, against the action that wanted it.
#[must_use]
pub fn android_profile(
    vendored: &Vendored,
    supervisor: &Arc<SupervisorClient>,
    log: &Arc<Stderr>,
) -> EnsureProfile {
    let mut arguments = vec!["--port".to_owned(), "0".to_owned()];
    if let Some(directory) = vendored.bin_dir.as_ref() {
        arguments.push("--vendored-bin".to_owned());
        arguments.push(directory.to_string_lossy().into_owned());
    }
    if let Some(jar) = vendored.scrcpy_server_jar.as_ref() {
        arguments.push("--vendored-jar".to_owned());
        arguments.push(jar.to_string_lossy().into_owned());
    }
    EnsureProfile {
        verb: MetadataVerb::EnsureAndroidBridge,
        binary_locator: own_daemon_locator(ANDROID_BINARY),
        spawner: spawner(ANDROID_SERVICE, inherited_environment(), supervisor, log),
        arguments,
        parse_port: Arc::new(parse_android_port),
        parse_version: Some(Arc::new(parse_android_version)),
        unspawnable: ServiceState::Starting,
    }
}

/// The port out of `androidd: listening on 0.0.0.0:<port> (v… , adb …)`.
///
/// Directly-after rather than last-colon: our own line carries a parenthetical whose
/// `127.0.0.1:5037` would win the final colon. The marker is
/// [`slopdesk_androidd::server::ANNOUNCE_PREFIX`] itself — the crate that PRINTS the line owns the
/// spelling, which is what retires the lint rule that kept the Swift copy equal to it.
fn parse_android_port(line: &str) -> Option<u16> {
    slopdesk_sidecars::service_lifecycle::port_directly_after(
        slopdesk_androidd::server::ANNOUNCE_PREFIX,
        line,
    )
}

/// The crate version off the same line, or `None` from an androidd that predates the field — which
/// is exactly what a survivor adopted across an upgrade is, and it must read `unknown` rather than
/// `current`.
fn parse_android_version(line: &str) -> Option<String> {
    announced_version(
        slopdesk_androidd::server::ANNOUNCE_PREFIX,
        slopdesk_androidd::server::ANNOUNCE_VERSION_PREFIX,
        line,
    )
    .map(str::to_owned)
}

// MARK: - The embedded workbench (verbs 18–20)

/// The ten seams a [`CodeServerManager`](slopdesk_hostserver::code::CodeServerManager) is built
/// from, over the linked seeder and superd.
///
/// The seeder's answers are resolved from THIS process's environment, which is hostd's — the same
/// environment the code-server child inherits. That is why the resolution belongs to one program:
/// it decides from the environment the child actually gets.
#[must_use]
pub fn code_seams(
    vendored: &Vendored,
    bridge: &Arc<CodeBridgeServer>,
    supervisor: &Arc<SupervisorClient>,
    log: &Arc<Stderr>,
) -> CodeServerSeams {
    let environment = slopdesk_codeseed::paths::process_environment();
    let data_dir = slopdesk_codeseed::paths::data_dir_in(&environment);
    let extensions_dir = slopdesk_codeseed::paths::extensions_dir_in(&environment);
    let user_settings = slopdesk_codeseed::paths::user_settings_in(&environment);
    let bridge_socket = slopdesk_codeseed::paths::bridge_socket_in(&environment)
        .to_string_lossy()
        .into_owned();

    // hostd's environment plus the seeder's delta — the marketplace gallery unless the operator
    // exported their own, and the bridge socket the seeded extension dials back on.
    let mut child_environment = inherited_environment();
    for (key, value) in slopdesk_codeseed::launch::environment_additions(&environment) {
        child_environment.insert(key, value);
    }

    CodeServerSeams {
        binary_locator: locator("code-server", CODE_SERVER_BIN_ENV_KEY, vendored.bin_dir.clone()),
        spawner: spawner("code-server", child_environment.clone(), supervisor, log),
        readiness_probe: loopback_probe(),
        settings_seeder: Arc::new(move || {
            let _changed = slopdesk_codeseed::seed_profile(&data_dir);
        }),
        cli_runner: Arc::new(move |binary: &str, arguments: &[String]| {
            run_to_exit(binary, arguments, &child_environment)
        }),
        missing_extensions: Arc::new(move || {
            slopdesk_codeseed::extensions::missing_bundled_extensions_at(&extensions_dir)
                .into_iter()
                .map(str::to_owned)
                .collect()
        }),
        font_sync: Arc::new(move |spec| {
            slopdesk_codeseed::settings::sync_editor_font(
                &user_settings,
                &spec.family,
                spec.size,
                spec.line_height,
            )
        }),
        profile_reader: Arc::new(move || {
            Some(CodeProfile {
                arguments: slopdesk_codeseed::launch::arguments()
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
                bridge_socket: bridge_socket.clone(),
            })
        }),
        is_directory: Arc::new(directory_exists),
        bridge: {
            let listener: Arc<CodeBridgeServer> = Arc::clone(bridge);
            listener
        },
    }
}

/// Runs the code-server CLI once to completion and answers its exit status.
///
/// Output is discarded: the exit code is the whole answer, and code-server's "No opened code-server
/// instances found" complaint arrives as a non-zero exit. `None` when the exec itself failed —
/// which the caller treats exactly as a non-zero, because both mean the open did not land.
fn run_to_exit(binary: &str, arguments: &[String], environment: &BTreeMap<String, String>) -> Option<i32> {
    std::process::Command::new(binary)
        .args(arguments)
        .env_clear()
        .envs(environment)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .ok()?
        .code()
}

// MARK: - The agent hooks (verbs 11–13)

/// The host's own `~/.claude/settings.json`, as the three answers the wire has.
///
/// The installer speaks `io::Result<String>` — the path it wrote — and the wire has room for
/// neither the path nor the reason. This door is where one becomes the other: the reason goes to
/// the daemon's log, where an operator can act on it, and the client is told whether the state
/// change happened.
#[derive(Debug)]
pub struct ClaudeHooks {
    log: Arc<Stderr>,
}

impl ClaudeHooks {
    /// A door writing its refusals to `log`.
    #[must_use]
    pub fn new(log: &Arc<Stderr>) -> Self {
        Self { log: Arc::clone(log) }
    }

    /// Installs the hooks unless they already are — what the daemon calls once at LAUNCH.
    ///
    /// `is_installed` first, so a host whose hooks are there does no work and writes nothing. The
    /// merge touches only entries carrying our own marker, which is what makes re-running it every
    /// launch produce the same file it already wrote.
    ///
    /// Never fatal: a `settings.json` this daemon cannot write is the user's file, and refusing to
    /// serve terminals over it would trade the product for one feature. A file that does not decode
    /// reads as not installed, and the install then refuses to touch it and says so on the log —
    /// one line per launch, and the user's settings exactly as they left them.
    pub fn install_if_absent(&self) {
        if !self.is_installed() {
            let _attempted = self.install();
        }
    }

    /// Where this host's Claude settings live, resolved fresh per call so that a
    /// `CLAUDE_CONFIG_DIR` exported into a restart is honoured without one.
    fn settings() -> PathBuf {
        let environment = slopdesk_hook::install::process_environment();
        let home = slopdesk_hook::install::home_in(&environment);
        slopdesk_hook::install::settings_path(&environment, &home)
    }
}

/// The relay binary beside this one, or `None` on a host built without `just hook`.
///
/// Beside THIS executable rather than on `PATH`: the two ship together, and a relay found somewhere
/// else is a different build's.
#[must_use]
pub fn staged_relay() -> Option<PathBuf> {
    let here = std::env::current_exe().ok()?;
    let candidate = here.parent()?.join(slopdesk_hook::install::RELAY_NAME);
    candidate.is_file().then_some(candidate)
}

impl InstallsAgentHooks for ClaudeHooks {
    fn install(&self) -> bool {
        let environment = slopdesk_hook::install::process_environment();
        let home = slopdesk_hook::install::home_in(&environment);
        let settings = slopdesk_hook::install::settings_path(&environment, &home);
        let hook = slopdesk_hook::install::hook_path(&environment, &home);
        // A relay that was never staged beside this daemon is a `false`, not a partial install:
        // writing hook entries that point at a binary this host does not have would leave the
        // settings card reporting green over hooks that can never fire.
        let Some(relay) = staged_relay() else {
            self.log
                .say("cannot install the Claude Code hooks: no relay beside this daemon");
            return false;
        };
        match slopdesk_hook::install::install(&settings, &hook, &relay) {
            Ok(written) => {
                self.log
                    .say(&format!("installed the Claude Code hooks → {written}"));
                true
            },
            Err(why) => {
                self.log
                    .say(&format!("could not install the Claude Code hooks: {why}"));
                false
            },
        }
    }

    fn uninstall(&self) -> bool {
        match slopdesk_hook::install::uninstall(&Self::settings()) {
            Ok(written) => {
                self.log
                    .say(&format!("removed the Claude Code hooks → {written}"));
                true
            },
            Err(why) => {
                self.log
                    .say(&format!("could not remove the Claude Code hooks: {why}"));
                false
            },
        }
    }

    fn is_installed(&self) -> bool {
        slopdesk_hook::install::is_installed(&Self::settings())
    }
}
