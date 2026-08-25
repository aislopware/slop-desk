//! What the two sidecar lifecycles DECIDE, with every process left where it was.
//!
//! `SupervisedServiceLifecycle.swift` held two shapes that five managers used to spell out
//! longhand: a service whose port the OS picks (spawn with `--port 0`, learn the port off the
//! child's own log line, probe until it answers, never wait) and one whose port hostd picks (spawn
//! or adopt, wait a bounded while for the announce line, verify the port is the wanted one). The
//! `Process`, the `NSLock` and the `Task` are the caller's; what is here is every question they
//! were asked between.
//!
//! It sits in this crate for the reason the crate doc gives: nothing here restarts anything, and
//! the daemons this reasons about are the same ones [`crate::verdict`] reasons about one level up
//! — a version off an announce line is the input to a staleness audit.
//!
//! ## Nothing here knows WHICH daemon it is
//! The socket name, the announce marker, the argv, the env override and the reason a given spawn
//! failure reads `Unavailable` rather than `Starting` stay with the caller, because those are the
//! places the daemons genuinely disagree. The marker is an ARGUMENT to every parse below for that
//! reason, and so is the `(v` that precedes a version: each daemon's `server.rs` spells its own,
//! and `rust/slopdesk-invariants` compares those spellings against the caller's rather than
//! against a copy here.
//!
//! ## The drift this deleted
//! The five copies had already stopped agreeing in the way that is impossible to see one file at a
//! time: one manager wrote its updated probe record INSIDE the `if due` block and two wrote it
//! after, and the dropd/inspectord port parse accepted a `:0` announce where androidd's rejected
//! it. Neither difference was intended by anyone; both read as correct in isolation.

/// What an ensure round reports about a service — the `ServiceState` byte of `docs/20`'s
/// ensure-verb response, spelled here because it is the ANSWER of every fold below.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum ServiceState {
    /// Spawned but not confirmed listening — the client polls the verb again.
    Starting = 0,
    /// Listening, and the port that comes with this is live.
    Ready = 1,
    /// There is nothing on this host to run, so there is nothing to wait for.
    Unavailable = 2,
}

impl ServiceState {
    /// The wire byte, which is the discriminant.
    #[must_use]
    pub const fn byte(self) -> u8 {
        self as u8
    }
}

// MARK: - The announce line

/// The port announced IMMEDIATELY after `marker`, which ends with the address and its colon.
///
/// The marker is matched exactly and the digits are taken as a run, so a build that adds words
/// after the port keeps parsing. Deliberately not the last-colon rule: our daemons' lines carry a
/// parenthetical after the port (`(adb 127.0.0.1:5037)`) whose own colon would win it.
///
/// An EMPTY marker never matches, which is Foundation's `range(of: "")` answering `nil` rather
/// than Rust's `find("")` answering position zero.
#[must_use]
pub fn port_directly_after(marker: &str, line: &str) -> Option<u16> {
    port_of(digit_run(after(marker, line)?))
}

/// The port after the LAST colon of what follows `marker`, for a third-party line naming an
/// address we do not control: bracketed IPv6, a bare IPv4 and a whole URL all put the port after
/// the final colon and nothing else does.
#[must_use]
pub fn port_after_last_colon_following(marker: &str, line: &str) -> Option<u16> {
    let rest = after(marker, line)?;
    let colon = rest.rfind(':')?;
    let tail = rest.get(colon.checked_add(1)?..)?;
    port_of(digit_run(tail))
}

/// The crate version between `version_marker` and the parenthetical's first `,` or `)`, searched
/// from the END of `port_marker` so a `(v` inside a path earlier on the line cannot win.
///
/// The daemons put it first in the parenthetical for that reason, and so the position holds however
/// the rest of that text grows. Empty parses to `None` — an empty string is not a version, and
/// reporting one as if it were would compare unequal to every real one forever.
///
/// Only OUR daemons announce one. `code-server` and the simulator server print third-party lines,
/// so their managers ask for no version and read `None` — "unknown", which the audit never turns
/// into "current".
#[must_use]
pub fn announced_version<'line>(
    port_marker: &str,
    version_marker: &str,
    line: &'line str,
) -> Option<&'line str> {
    let rest = after(port_marker, line)?;
    let tail = after(version_marker, rest)?;
    let end = tail.find([',', ')']).unwrap_or(tail.len());
    let version = tail.get(..end)?;
    if version.is_empty() { None } else { Some(version) }
}

/// What follows the first occurrence of `marker`, or `None` when the line does not carry it.
fn after<'line>(marker: &str, line: &'line str) -> Option<&'line str> {
    if marker.is_empty() {
        return None;
    }
    let start = line.find(marker)?;
    line.get(start.checked_add(marker.len())?..)
}

/// The leading run of NUMERIC characters, which is Swift's `prefix(while: \.isNumber)` — Unicode,
/// not ASCII, so an Eastern Arabic digit is taken into the run and then fails to parse, exactly as
/// `UInt16(_:)` fails on it. A run that stopped at the first non-ASCII digit would instead answer
/// the truncated prefix, which is a port nobody announced.
fn digit_run(rest: &str) -> &str {
    let end = rest
        .find(|character: char| !character.is_numeric())
        .unwrap_or(rest.len());
    rest.get(..end).unwrap_or("")
}

/// The last step of every announce parse: a run of digits is a port, and `0` never is.
///
/// A `:0` in an announce line is the port the child was ASKED for under `--port 0`, echoed back
/// before the OS had picked one — the one value that is always a lie. It was rejected by two of the
/// five parsers this replaced and accepted by three.
fn port_of(digits: &str) -> Option<u16> {
    digits.parse::<u16>().ok().filter(|port| *port > 0)
}

// MARK: - The OS-picks-the-port lifecycle

/// One live child's record, as the face holds it between rounds.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProbeRecord {
    /// Learned from the child's announce line; `None` until it prints one.
    pub port: Option<u16>,
    /// Nanoseconds since the readiness probe last ran, or `None` when it never has.
    pub since_probe: Option<u64>,
    /// Latched by the first successful probe — a listening server is never un-probed.
    pub ready: bool,
    /// Whether the child is still alive. A `false` here is the whole of crash recovery.
    pub running: bool,
}

/// What one ensure round does to a probed-port service.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProbeStep {
    /// There is no live child: drop whatever record there is and boot one. A record that is
    /// present but not running takes this arm too, which is why a crashed child needs no reaper.
    Boot,
    /// Nothing to run this round — report this, and the port that rides along with it.
    Report {
        /// What the client is told.
        state: ServiceState,
        /// The learned port, or `0` when the child has not announced one yet. It rides along even
        /// while starting: it is the honest answer to "where will it be", and the client gates on
        /// the STATE.
        port: u16,
    },
    /// Run the readiness probe on this port, stamp the record with the time it ran, and ask again
    /// with the answer in `probe`. Splitting the round in two is what keeps the syscall on the
    /// caller's side without splitting the RULE in two.
    Probe {
        /// Where to connect.
        port: u16,
    },
}

/// The whole of an ensure round, asked once with `probe` as `None` and — only when the first
/// answer was [`ProbeStep::Probe`] — a second time with the probe's verdict.
///
/// The second call is handed the same `record`: the caller latches nothing until the rule has told
/// it what to latch, so `ready` is still `false` and `since_probe` still the old one. That is why
/// `probe` is read BEFORE the due-ness fold and after the `ready` latch.
#[must_use]
pub const fn probe_step(
    record: Option<ProbeRecord>,
    probe_interval_nanos: u64,
    probe: Option<bool>,
) -> ProbeStep {
    let live = match record {
        Some(live) => live,
        None => return ProbeStep::Boot,
    };
    if !live.running {
        return ProbeStep::Boot;
    }
    let port = match live.port {
        Some(port) => port,
        None => {
            return ProbeStep::Report {
                state: ServiceState::Starting,
                port: 0,
            };
        }
    };
    if live.ready {
        return ProbeStep::Report {
            state: ServiceState::Ready,
            port,
        };
    }
    if let Some(answered) = probe {
        return ProbeStep::Report {
            state: if answered {
                ServiceState::Ready
            } else {
                ServiceState::Starting
            },
            port,
        };
    }
    let due = match live.since_probe {
        Some(elapsed) => elapsed >= probe_interval_nanos,
        None => true,
    };
    if due {
        ProbeStep::Probe { port }
    } else {
        ProbeStep::Report {
            state: ServiceState::Starting,
            port,
        }
    }
}

/// Whether a fact read off a child's log line may be written onto the current record.
///
/// FIRST WRITER WINS, and only for the generation that is still current. The child announces once,
/// so a later line that happened to carry the marker is not a new fact; and a respawn that raced a
/// dying child's last line must not let the old child's port land on the fresh record.
#[must_use]
pub const fn accepts_announcement(
    line_generation: u64,
    spawn_generation: u64,
    has_record: bool,
    already_recorded: bool,
) -> bool {
    line_generation == spawn_generation && has_record && !already_recorded
}

// MARK: - The hostd-picks-the-port lifecycle

/// What to do with the port a daemon announced, against the one hostd advertises.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdoptVerdict {
    /// It is on the wanted port — serve it.
    Adopt,
    /// End it and start one on the port this hostd advertises.
    Respawn,
    /// The relaunch did not land either. End it and serve the other paths — a sidecar that never
    /// came up is not fatal to hostd, exactly as a failed bind never was.
    GiveUp,
}

/// The verify-after-adopt rule, on attempt `attempt` (`0` is the first launch).
///
/// A daemon that never spoke and one that spoke a different port get the SAME answer, and that is
/// the point. The pane id is stable (`service:<name>`, `docs/51` §1) but the port is not: a hostd
/// started on a different `--port` wants a different sidecar port, and the survivor is on the old
/// one. Adopting it would leave hostd advertising a port nothing listens on, which fails with no
/// log line to say why.
#[must_use]
pub const fn adopt_verdict(attempt: u32, announced: Option<u16>, wanted: u16) -> AdoptVerdict {
    let landed = match announced {
        Some(port) => port == wanted,
        None => false,
    };
    if landed {
        AdoptVerdict::Adopt
    } else if attempt == 0 {
        AdoptVerdict::Respawn
    } else {
        AdoptVerdict::GiveUp
    }
}

// MARK: - The workbench's own gates

/// The one-shot marketplace install of the bundled extensions the profile registry does not carry.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum ExtensionInstall {
    /// Not asked yet — the next boot reads the registry.
    Unchecked = 0,
    /// The CLI pass is running, and the spawn waits for it: install and boot writing
    /// `extensions.json` concurrently is how registrations get lost.
    Installing = 1,
    /// Latched, whether the install SUCCEEDED or not — the panel is never held hostage by a
    /// nicety, and the next hostd launch retries because the registry still misses the id.
    Done = 2,
}

impl ExtensionInstall {
    /// The byte this crosses as, which is the discriminant.
    #[must_use]
    pub const fn byte(self) -> u8 {
        self as u8
    }

    /// The inverse. Anything unnamed reads as [`ExtensionInstall::Unchecked`], which costs a
    /// registry read and never skips one.
    #[must_use]
    pub const fn from_byte(raw: u8) -> Self {
        match raw {
            1 => Self::Installing,
            2 => Self::Done,
            _ => Self::Unchecked,
        }
    }
}

/// Everything the workbench's boot gates read, none of which is a process.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BootGates {
    /// How many bundled extensions the profile registry still misses. Zero spawns straight away.
    pub missing: usize,
    /// Where the one-shot install stands.
    pub install: ExtensionInstall,
    /// Whether there is BOTH a binary and a seeder profile. They are one flag because they are one
    /// answer: a workbench launched on guessed arguments is a different program, not a degraded
    /// panel, so a host missing either reports the same `Unavailable` a host missing both does.
    pub launchable: bool,
    /// Whether the profile seed has already run this manager lifetime.
    pub settings_seeded: bool,
    /// Whether the bridge listener is already bound.
    pub bridge_started: bool,
}

/// How a boot round ends.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootAction {
    /// Spawn nothing this round, and report this.
    Report(ServiceState),
    /// Every gate is open — spawn the child. A spawn that then THROWS is the caller's to report;
    /// nothing here has an opinion about a broken binary.
    Spawn,
}

/// What one boot round does, in the order the fields are declared.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BootStep {
    /// The install state to latch, whatever else happens.
    pub install: ExtensionInstall,
    /// What the round ends in.
    pub action: BootAction,
    /// Fork the profile seeder first: after the child has read an absent settings file once, a
    /// seed would need a reload to take.
    pub seed_settings: bool,
    /// Then bind the bridge listener — before the child inherits its path, or the extension's
    /// first connect races the bind and burns a 5 s reconnect delay on every cold start.
    pub start_bridge: bool,
    /// Then run the one-shot marketplace install.
    pub install_extensions: bool,
}

/// The workbench's four gates between "there is a binary" and "spawn".
///
/// The seed and the bridge bind happen on the round that DEFERS for an install too: they are what
/// the child will read, and deferring them with the spawn would only move the cold start.
#[must_use]
pub const fn boot_step(gates: BootGates) -> BootStep {
    if !gates.launchable {
        return BootStep {
            install: gates.install,
            action: BootAction::Report(ServiceState::Unavailable),
            seed_settings: false,
            start_bridge: false,
            install_extensions: false,
        };
    }
    let seed_settings = !gates.settings_seeded;
    let start_bridge = !gates.bridge_started;
    let spawn = BootStep {
        install: ExtensionInstall::Done,
        action: BootAction::Spawn,
        seed_settings,
        start_bridge,
        install_extensions: false,
    };
    match gates.install {
        ExtensionInstall::Unchecked => {
            if gates.missing == 0 {
                spawn
            } else {
                BootStep {
                    install: ExtensionInstall::Installing,
                    action: BootAction::Report(ServiceState::Starting),
                    seed_settings,
                    start_bridge,
                    install_extensions: true,
                }
            }
        }
        ExtensionInstall::Installing => BootStep {
            install: ExtensionInstall::Installing,
            action: BootAction::Report(ServiceState::Starting),
            seed_settings,
            start_bridge,
            install_extensions: false,
        },
        ExtensionInstall::Done => spawn,
    }
}

/// CLI open retries: 10 attempts × the caller's 2 s delay ≈ an 18 s window — enough for a cold
/// server boot, the client's poll and the webview's workbench boot before the session socket
/// exists. The workbench SESSION registers only once a client's webview has booted the page, and
/// the client typically expands the panel in the same breath as the open.
pub const OPEN_ATTEMPTS: u32 = 10;

/// Which one-shot the code-server CLI is being run as.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum CodeCommand {
    /// The one-shot marketplace fetch of a bundled extension.
    InstallExtension = 0,
    /// Open a target in the most recently registered workbench, routed through the per-user
    /// session socket (folder-prefix matches sort first).
    ReuseWindow = 1,
}

/// The flag one code-server CLI one-shot leads with; the argument after it is the caller's own
/// identifier or target, so the whole argv is this and that.
///
/// `-r` is not `--reuse-window` abbreviated by accident: it is the form every shipped code-server
/// accepts, and the long spelling is not.
#[must_use]
pub const fn code_cli_flag(command: CodeCommand) -> &'static str {
    match command {
        CodeCommand::InstallExtension => "--install-extension",
        CodeCommand::ReuseWindow => "-r",
    }
}

/// A request root, normalized: absolute, and with its trailing `/` trimmed the way `projectKey`
/// trims it so one project cannot spawn twins. `None` when the path is not absolute.
///
/// Whether it EXISTS and is a directory is the caller's — that is a `stat`, and the answer to it
/// changes between two calls with the same argument.
#[must_use]
pub fn canonical_root<'path>(path: &'path str) -> Option<&'path str> {
    if !path.starts_with('/') {
        return None;
    }
    let trimmed = path.trim_end_matches('/');
    Some(if trimmed.is_empty() { "/" } else { trimmed })
}

#[cfg(test)]
mod tests {
    use super::{
        AdoptVerdict, BootAction, BootGates, BootStep, CodeCommand, ExtensionInstall, OPEN_ATTEMPTS,
        ProbeRecord, ProbeStep, ServiceState, accepts_announcement, adopt_verdict, announced_version,
        boot_step, canonical_root, code_cli_flag, port_after_last_colon_following,
        port_directly_after, probe_step,
    };

    const INTERVAL: u64 = 500_000_000;

    #[test]
    fn a_port_is_the_digit_run_after_the_marker() {
        assert_eq!(
            port_directly_after("listening on 127.0.0.1:", "dropd listening on 127.0.0.1:5123 (v0.2.0)"),
            Some(5123)
        );
    }

    #[test]
    fn a_parenthetical_colon_never_wins_the_direct_dialect() {
        assert_eq!(
            port_directly_after(
                "androidd listening on 127.0.0.1:",
                "androidd listening on 127.0.0.1:5400 (adb 127.0.0.1:5037)",
            ),
            Some(5400)
        );
    }

    #[test]
    fn a_zero_port_is_the_ask_echoed_back_and_never_an_answer() {
        assert_eq!(port_directly_after("on :", "bound on :0"), None);
        assert_eq!(
            port_after_last_colon_following("HTTP server listening on http://", "HTTP server listening on http://0.0.0.0:0/"),
            None
        );
    }

    #[test]
    fn a_missing_marker_and_an_empty_marker_both_answer_nothing() {
        assert_eq!(port_directly_after("on :", "nothing here"), None);
        assert_eq!(port_directly_after("", "on :5123"), None);
        assert_eq!(port_after_last_colon_following("", "http://0.0.0.0:1/"), None);
    }

    #[test]
    fn the_last_colon_dialect_reads_a_url_and_an_ipv6_alike() {
        assert_eq!(
            port_after_last_colon_following(
                "HTTP server listening on http://",
                "[2026-08-25] info  HTTP server listening on http://0.0.0.0:62636/",
            ),
            Some(62636)
        );
        assert_eq!(
            port_after_last_colon_following("listening on ", "listening on [::1]:9001"),
            Some(9001)
        );
        assert_eq!(
            port_after_last_colon_following("listening on ", "listening on nothing"),
            None
        );
    }

    #[test]
    fn a_unicode_digit_run_fails_to_parse_rather_than_truncating() {
        // Swift takes the whole numeric run and then `UInt16(_:)` refuses it. An ASCII-only run
        // would answer 12, which is a port nothing is listening on.
        assert_eq!(port_directly_after("on :", "on :12\u{0663}4"), None);
    }

    #[test]
    fn a_version_is_read_from_the_end_of_the_port_marker() {
        assert_eq!(
            announced_version("listening on 127.0.0.1:", "(v", "dropd listening on 127.0.0.1:5123 (v0.2.0)"),
            Some("0.2.0")
        );
        assert_eq!(
            announced_version("listening on 127.0.0.1:", "(v", "dropd listening on 127.0.0.1:5123 (v0.2.0, pid 44)"),
            Some("0.2.0")
        );
    }

    #[test]
    fn a_version_marker_before_the_port_cannot_win() {
        assert_eq!(
            announced_version("listening on :", "(v", "/opt/(v9)/dropd listening on :5123 (v0.2.0)"),
            Some("0.2.0")
        );
    }

    #[test]
    fn an_empty_version_is_not_a_version() {
        assert_eq!(announced_version("on :", "(v", "on :5123 (v)"), None);
        assert_eq!(announced_version("on :", "(v", "on :5123 no parenthetical"), None);
    }

    #[test]
    fn no_record_and_a_dead_child_both_boot() {
        assert_eq!(probe_step(None, INTERVAL, None), ProbeStep::Boot);
        let dead = ProbeRecord {
            port: Some(5123),
            since_probe: None,
            ready: true,
            running: false,
        };
        assert_eq!(probe_step(Some(dead), INTERVAL, None), ProbeStep::Boot);
    }

    #[test]
    fn a_child_that_has_not_announced_is_starting_on_no_port() {
        let fresh = ProbeRecord {
            port: None,
            since_probe: None,
            ready: false,
            running: true,
        };
        assert_eq!(
            probe_step(Some(fresh), INTERVAL, None),
            ProbeStep::Report {
                state: ServiceState::Starting,
                port: 0,
            }
        );
    }

    #[test]
    fn readiness_latches_and_is_never_re_probed() {
        let latched = ProbeRecord {
            port: Some(5123),
            since_probe: Some(0),
            ready: true,
            running: true,
        };
        assert_eq!(
            probe_step(Some(latched), INTERVAL, None),
            ProbeStep::Report {
                state: ServiceState::Ready,
                port: 5123,
            }
        );
    }

    #[test]
    fn the_first_round_probes_and_a_recent_one_does_not() {
        let never = ProbeRecord {
            port: Some(5123),
            since_probe: None,
            ready: false,
            running: true,
        };
        assert_eq!(
            probe_step(Some(never), INTERVAL, None),
            ProbeStep::Probe { port: 5123 }
        );
        let recent = ProbeRecord {
            since_probe: Some(INTERVAL - 1),
            ..never
        };
        assert_eq!(
            probe_step(Some(recent), INTERVAL, None),
            ProbeStep::Report {
                state: ServiceState::Starting,
                port: 5123,
            }
        );
        let due = ProbeRecord {
            since_probe: Some(INTERVAL),
            ..never
        };
        assert_eq!(probe_step(Some(due), INTERVAL, None), ProbeStep::Probe { port: 5123 });
    }

    #[test]
    fn the_second_call_folds_the_probes_answer() {
        let waiting = ProbeRecord {
            port: Some(5123),
            since_probe: None,
            ready: false,
            running: true,
        };
        assert_eq!(
            probe_step(Some(waiting), INTERVAL, Some(true)),
            ProbeStep::Report {
                state: ServiceState::Ready,
                port: 5123,
            }
        );
        assert_eq!(
            probe_step(Some(waiting), INTERVAL, Some(false)),
            ProbeStep::Report {
                state: ServiceState::Starting,
                port: 5123,
            }
        );
    }

    #[test]
    fn only_the_current_generations_first_announcement_is_written() {
        assert!(accepts_announcement(3, 3, true, false));
        assert!(!accepts_announcement(2, 3, true, false), "a dying child's last line");
        assert!(!accepts_announcement(3, 3, false, false), "nothing to write onto");
        assert!(!accepts_announcement(3, 3, true, true), "first writer wins");
    }

    #[test]
    fn the_wanted_port_is_adopted_and_anything_else_is_respawned_once() {
        assert_eq!(adopt_verdict(0, Some(7000), 7000), AdoptVerdict::Adopt);
        assert_eq!(adopt_verdict(0, Some(6999), 7000), AdoptVerdict::Respawn);
        assert_eq!(adopt_verdict(0, None, 7000), AdoptVerdict::Respawn);
        assert_eq!(adopt_verdict(1, Some(7000), 7000), AdoptVerdict::Adopt);
        assert_eq!(adopt_verdict(1, Some(6999), 7000), AdoptVerdict::GiveUp);
        assert_eq!(adopt_verdict(1, None, 7000), AdoptVerdict::GiveUp);
    }

    /// The gates a host that can launch starts from.
    const fn gates(install: ExtensionInstall, missing: usize) -> BootGates {
        BootGates {
            missing,
            install,
            launchable: true,
            settings_seeded: false,
            bridge_started: false,
        }
    }

    #[test]
    fn an_unlaunchable_host_reports_unavailable_and_touches_nothing() {
        let step = boot_step(BootGates {
            launchable: false,
            ..gates(ExtensionInstall::Unchecked, 3)
        });
        assert_eq!(
            step,
            BootStep {
                install: ExtensionInstall::Unchecked,
                action: BootAction::Report(ServiceState::Unavailable),
                seed_settings: false,
                start_bridge: false,
                install_extensions: false,
            }
        );
    }

    #[test]
    fn nothing_missing_seeds_binds_and_spawns_in_one_round() {
        let step = boot_step(gates(ExtensionInstall::Unchecked, 0));
        assert_eq!(step.action, BootAction::Spawn);
        assert_eq!(step.install, ExtensionInstall::Done);
        assert!(step.seed_settings);
        assert!(step.start_bridge);
        assert!(!step.install_extensions);
    }

    #[test]
    fn a_missing_extension_defers_the_spawn_but_not_the_seed() {
        let step = boot_step(gates(ExtensionInstall::Unchecked, 2));
        assert_eq!(step.action, BootAction::Report(ServiceState::Starting));
        assert_eq!(step.install, ExtensionInstall::Installing);
        assert!(step.install_extensions);
        assert!(step.seed_settings, "the child will read what the seed writes");
        assert!(step.start_bridge);
    }

    #[test]
    fn a_running_install_defers_without_starting_a_second_one() {
        let step = boot_step(gates(ExtensionInstall::Installing, 2));
        assert_eq!(step.action, BootAction::Report(ServiceState::Starting));
        assert_eq!(step.install, ExtensionInstall::Installing);
        assert!(!step.install_extensions);
    }

    #[test]
    fn a_latched_install_spawns_however_many_are_still_missing() {
        let step = boot_step(gates(ExtensionInstall::Done, 5));
        assert_eq!(step.action, BootAction::Spawn);
        assert_eq!(step.install, ExtensionInstall::Done);
        assert!(!step.install_extensions);
    }

    #[test]
    fn the_once_per_lifetime_gates_stay_shut_after_the_first_round() {
        let step = boot_step(BootGates {
            settings_seeded: true,
            bridge_started: true,
            ..gates(ExtensionInstall::Done, 0)
        });
        assert!(!step.seed_settings);
        assert!(!step.start_bridge);
        assert_eq!(step.action, BootAction::Spawn);
    }

    #[test]
    fn the_install_byte_round_trips_and_an_unknown_one_re_checks() {
        for state in [
            ExtensionInstall::Unchecked,
            ExtensionInstall::Installing,
            ExtensionInstall::Done,
        ] {
            assert_eq!(ExtensionInstall::from_byte(state.byte()), state);
        }
        assert_eq!(ExtensionInstall::from_byte(9), ExtensionInstall::Unchecked);
    }

    #[test]
    fn the_state_bytes_are_the_wires() {
        assert_eq!(ServiceState::Starting.byte(), 0);
        assert_eq!(ServiceState::Ready.byte(), 1);
        assert_eq!(ServiceState::Unavailable.byte(), 2);
    }

    #[test]
    fn the_cli_one_shots_lead_with_two_flags() {
        assert_eq!(code_cli_flag(CodeCommand::InstallExtension), "--install-extension");
        assert_eq!(code_cli_flag(CodeCommand::ReuseWindow), "-r");
        assert_eq!(OPEN_ATTEMPTS, 10);
    }

    #[test]
    fn a_root_is_absolute_and_trailing_slash_free() {
        assert_eq!(canonical_root("/Users/x/proj"), Some("/Users/x/proj"));
        assert_eq!(canonical_root("/Users/x/proj/"), Some("/Users/x/proj"));
        assert_eq!(canonical_root("/Users/x/proj///"), Some("/Users/x/proj"));
        assert_eq!(canonical_root("/"), Some("/"), "the root never trims to nothing");
        assert_eq!(canonical_root("///"), Some("/"));
        assert_eq!(canonical_root("relative/proj"), None);
        assert_eq!(canonical_root(""), None);
    }
}
