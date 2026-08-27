//! The two daemons hostd CHOOSES the port for: the inspector on `bound + 1`, file drops on
//! `bound + 2`.
//!
//! The port of `InspectorServiceManager.swift` and
//! `FileDropServiceManager.swift` — two files that were the same lifecycle written out twice, down
//! to the blank lines, differing in FOUR values: the socket's name, its announce marker, its argv
//! and the variable that overrides its binary. The lifecycle itself was ported at stage E and lives
//! in [`AnnouncedPortService`]; what is here is those four values, twice, and one thing the Swift
//! did not have.
//!
//! ## What is new: the face remembers what it was started with
//! The Swift auditor could only restart dropd by being HANDED the port and the drop directory
//! again, threaded down from `main.swift` through `HostServer.auditSidecarVersions` as four extra
//! parameters — and its own comment says why that mattered: *"a restart that silently moved the
//! drop directory would be worse than the stale binary it was fixing."* A face that keeps its own
//! argv cannot move it. [`Sidecar::restart`] takes no arguments for exactly that reason, and the
//! four parameters are gone from the audit's signature.
//!
//! ## hostd is in neither byte path
//! Both daemons have always ridden their own TCP connection — the client dials `bound + 1` or
//! `bound + 2` directly and nothing about either touches the terminal mux. What hostd used to
//! contribute was the PROCESS: a per-turn JSON fold and a growing replay window (`docs/54`), and a
//! multi-GiB upload streaming through the daemon that owns every keystroke (`docs/53`). Both are
//! superd's children now, so `make host-restart` takes neither with it.
//!
//! ## Spawn-or-adopt, and why the port is VERIFIED after an adopt
//! The pane id is `service:<name>` — stable, not derived from this hostd (`docs/51` §1) — so a
//! restart ADOPTS the running daemon and an upload in flight across a host rebuild simply
//! continues. The port is not stable: a hostd started on a different `--port` wants a different
//! sidecar port and the survivor is on the old one. That comparison, the bounded wait and the
//! respawn are [`AnnouncedPortService`]'s.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use slopdesk_hostserver::service::{AnnouncedPortService, PortParser, VersionParser};
use slopdesk_sidecars::service_lifecycle::{announced_version, port_directly_after};
use slopdesk_superclient::client::SupervisorClient;

use crate::observer::Stderr;
use crate::services;

/// The gate that turns PATH 4 off. Default-ON: `0` disables, anything else — including unset —
/// leaves file transfer serving.
const FILE_TRANSFER_ENV_KEY: &str = "SLOPDESK_FILE_TRANSFER";

/// Where a dropped file lands, when the operator wants somewhere other than `~/Downloads`.
const FILE_DROP_DIR_ENV_KEY: &str = "SLOPDESK_FILE_DROP_DIR";

/// The four values that make one announced-port lifecycle a particular daemon.
struct Profile {
    /// The name it ships under in `MANIFEST.json`, which is also its executable name, its cargo
    /// target directory and — via [`slopdesk_sidecars::paths::binary_env_key`] — its override.
    tool: &'static str,
    /// What superd files it under, and with it the pane id `service:<name>`.
    service: &'static str,
    parse_port: PortParser,
    parse_version: VersionParser,
}

/// One daemon hostd picked the port for, and everything a version audit needs to fix it.
pub struct Sidecar {
    service: Arc<AnnouncedPortService>,
    profile: Profile,
    /// The port this hostd advertises. Held so a restart re-opens the one a client already holds.
    port: u16,
    /// The child's argv, built once. Held for the reason the module note gives.
    arguments: Vec<String>,
}

impl core::fmt::Debug for Sidecar {
    /// Written out because [`Profile`] is two closures and a pair of names, and there is nothing to
    /// print about a closure.
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Sidecar")
            .field("tool", &self.profile.tool)
            .field("port", &self.port)
            .field("arguments", &self.arguments)
            .finish_non_exhaustive()
    }
}

impl Sidecar {
    /// PATH 3's daemon — `slopdesk-inspectord` on `port`, reading `transcript`.
    ///
    /// The transcript path is passed rather than read from the environment on the far side:
    /// superd's child inherits hostd's environment, and a service whose SUBJECT depended on that
    /// inheritance would silently change meaning the day someone adopted it from a
    /// differently-configured daemon. Without a path the daemon still binds and serves an empty
    /// replay window — the honest state of an inspector with nothing to inspect.
    #[must_use]
    pub fn inspector(
        port: u16,
        transcript: Option<&str>,
        supervisor: &Arc<SupervisorClient>,
        log: &Arc<Stderr>,
    ) -> Self {
        let mut arguments = vec!["--port".to_owned(), port.to_string()];
        if let Some(path) = transcript.filter(|value| !value.is_empty()) {
            arguments.push("--transcript".to_owned());
            arguments.push(path.to_owned());
        }
        Self::new(
            Profile {
                tool: "slopdesk-inspectord",
                service: "inspectord",
                parse_port: Arc::new(|line| {
                    port_directly_after(slopdesk_inspectord::server::ANNOUNCE_PREFIX, line)
                }),
                parse_version: Arc::new(|line| {
                    announced_version(
                        slopdesk_inspectord::server::ANNOUNCE_PREFIX,
                        slopdesk_inspectord::server::ANNOUNCE_VERSION_PREFIX,
                        line,
                    )
                    .map(str::to_owned)
                }),
            },
            port,
            arguments,
            supervisor,
            log,
        )
    }

    /// PATH 4's daemon — `slopdesk-dropd` on `port`, writing into `drop_directory`.
    ///
    /// The destination is passed for the inspector's reason, and the Swift's own: a daemon adopted
    /// from a differently-configured hostd must not quietly write somewhere else.
    #[must_use]
    pub fn drops(
        port: u16,
        drop_directory: &Path,
        supervisor: &Arc<SupervisorClient>,
        log: &Arc<Stderr>,
    ) -> Self {
        Self::new(
            Profile {
                tool: "slopdesk-dropd",
                service: "dropd",
                parse_port: Arc::new(|line| {
                    port_directly_after(slopdesk_dropd::server::ANNOUNCE_PREFIX, line)
                }),
                parse_version: Arc::new(|line| {
                    announced_version(
                        slopdesk_dropd::server::ANNOUNCE_PREFIX,
                        slopdesk_dropd::server::ANNOUNCE_VERSION_PREFIX,
                        line,
                    )
                    .map(str::to_owned)
                }),
            },
            port,
            vec![
                "--port".to_owned(),
                port.to_string(),
                "--drop-dir".to_owned(),
                drop_directory.to_string_lossy().into_owned(),
            ],
            supervisor,
            log,
        )
    }

    fn new(
        profile: Profile,
        port: u16,
        arguments: Vec<String>,
        supervisor: &Arc<SupervisorClient>,
        log: &Arc<Stderr>,
    ) -> Self {
        Self {
            service: Arc::new(AnnouncedPortService::new(
                services::spawner(
                    profile.service,
                    services::inherited_environment(),
                    supervisor,
                    log,
                ),
                services::own_daemon_locator(profile.tool),
                Arc::clone(&profile.parse_port),
                Some(Arc::clone(&profile.parse_version)),
                AnnouncedPortService::DEFAULT_ANNOUNCE_TIMEOUT,
            )),
            profile,
            port,
            arguments,
        }
    }

    /// Brings the daemon up on the port this hostd advertises, adopting a survivor when there is
    /// one.
    ///
    /// `None` when there is no binary, superd is unreachable, or the child never announced. NOT
    /// fatal to the daemon: hostd logs it and serves the other paths, exactly as a failed bind used
    /// to.
    #[must_use]
    pub fn start(&self) -> Option<u16> {
        self.service.start(self.port, &self.arguments)
    }

    /// Ends the running daemon and starts the INSTALLED one, on the same port and the same argv.
    ///
    /// The only remedy a stale verdict permits for these two, and it takes no arguments on purpose
    /// — see the module note.
    #[must_use]
    pub fn restart(&self) -> Option<u16> {
        self.service.shutdown();
        self.start()
    }

    /// The name it ships under in `MANIFEST.json`, which is the version audit's key.
    #[must_use]
    pub const fn tool(&self) -> &'static str {
        self.profile.tool
    }

    /// The port the running daemon announced, once it has.
    #[must_use]
    pub fn served_port(&self) -> Option<u16> {
        self.service.served_port()
    }

    /// The crate version of the daemon actually running, off its announce line. `None` when it has
    /// not announced yet, or announced without one — which is exactly what a survivor adopted
    /// across an upgrade is, and it must read `unknown` rather than `current`.
    #[must_use]
    pub fn running_version(&self) -> Option<String> {
        self.service.announced_version()
    }

    /// Lets the daemon GO: hostd stops listening to its log, superd keeps it — and with it the
    /// replay window, the running tail and every upload in flight. What a daemon SHUTDOWN calls.
    pub fn relinquish(&self) {
        self.service.relinquish();
    }
}

/// Whether PATH 4 serves at all. Default-ON; `0` is the only value that turns it off.
///
/// An unset variable and an unreadable one are the same answer, deliberately: file transfer is a
/// feature of every host that did not say otherwise.
#[must_use]
pub fn file_transfer_enabled() -> bool {
    std::env::var(FILE_TRANSFER_ENV_KEY).as_deref() != Ok("0")
}

/// Where dropped files land: `$SLOPDESK_FILE_DROP_DIR`, or `~/Downloads`.
///
/// The tilde rule is the Swift's three cases and not [`slopdesk_hostserver::pathaction`]'s: this is
/// a directory an OPERATOR exported into this daemon's own environment, so a bare `~` is theirs to
/// mean, and a relative path is honoured rather than refused — a refusal here would silently
/// disable a path the operator asked for.
///
/// ## A relative path is resolved HERE, against hostd's `cwd`
/// The Swift built the fallthrough case with `URL(fileURLWithPath:isDirectory:)`, which absolutizes
/// against the CALLING process's working directory. Taking it at face value instead would hand
/// `--drop-dir inbox` down as-is and let it resolve against *dropd's* cwd — superd's child, whose
/// working directory is not hostd's and is not the operator's. Same-named directory, different
/// machine-place, no error either way: exactly the failure that has no symptom. So the answer this
/// returns is always absolute when `cwd` is, and the argv the daemon receives already names one
/// directory.
///
/// An empty variable is no variable, which is what an unset one exported as `""` is.
#[must_use]
pub fn drop_directory(custom: Option<&str>, home: &Path, cwd: &Path) -> PathBuf {
    let Some(custom) = custom.filter(|value| !value.is_empty()) else {
        return home.join("Downloads");
    };
    if custom == "~" {
        return home.to_path_buf();
    }
    if let Some(tail) = custom.strip_prefix("~/") {
        return home.join(tail);
    }
    let named = Path::new(custom);
    if named.is_absolute() {
        named.to_path_buf()
    } else {
        cwd.join(named)
    }
}

/// [`drop_directory`] against this process's environment.
///
/// A missing or empty `HOME` reads as `/` — the answer every other daemon in this tree gives, and a
/// deliberate refusal to guess at somebody's home. `~/Downloads` then names a directory that cannot
/// be made, so the drop service does not come up and says so, which beats writing a stranger's
/// files somewhere plausible. An unreadable `cwd` reads as `/` for the same reason.
#[must_use]
pub fn drop_directory_from_env() -> PathBuf {
    let home = std::env::var_os("HOME").filter(|value| !value.is_empty());
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    drop_directory(
        std::env::var(FILE_DROP_DIR_ENV_KEY).ok().as_deref(),
        home.as_ref()
            .map_or_else(|| Path::new("/"), |value| Path::new(value)),
        &cwd,
    )
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use super::drop_directory;

    /// The two places a drop directory is measured from, fixed so the cases read as one table.
    const HOME: &str = "/Users/x";
    const CWD: &str = "/Volumes/work";

    fn resolved(custom: Option<&str>) -> PathBuf {
        drop_directory(custom, Path::new(HOME), Path::new(CWD))
    }

    #[test]
    fn no_variable_means_downloads_under_this_users_home() {
        assert_eq!(resolved(None), PathBuf::from("/Users/x/Downloads"));
        assert_eq!(resolved(Some("")), PathBuf::from("/Users/x/Downloads"));
    }

    #[test]
    fn a_bare_tilde_is_the_home_itself_and_a_tilde_slash_is_under_it() {
        assert_eq!(resolved(Some("~")), PathBuf::from("/Users/x"));
        assert_eq!(
            resolved(Some("~/Desktop/in")),
            PathBuf::from("/Users/x/Desktop/in"),
        );
    }

    #[test]
    fn an_absolute_path_is_the_answer_and_nothing_is_prepended_to_it() {
        assert_eq!(
            resolved(Some("/Volumes/scratch")),
            PathBuf::from("/Volumes/scratch"),
        );
    }

    #[test]
    fn a_relative_path_lands_where_the_operator_typed_it_not_where_dropd_starts() {
        // The whole reason the working directory is a parameter: `inbox` means hostd's `inbox`,
        // which is the shell's, and dropd is started by superd from somewhere else entirely.
        assert_eq!(resolved(Some("inbox")), PathBuf::from("/Volumes/work/inbox"));
        assert_eq!(
            resolved(Some("./drops/today")),
            PathBuf::from("/Volumes/work/./drops/today"),
        );
        // `~user` is NOT expanded — the same closed answer the metadata verbs give, reached from
        // the other side: nothing here resolves a second user's home. It is a relative name that
        // happens to start with a tilde, and it is treated as one.
        assert_eq!(
            resolved(Some("~someone/drops")),
            PathBuf::from("/Volumes/work/~someone/drops"),
        );
    }
}
