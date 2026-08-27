//! Rebuild `slopdesk-hostd` and restart the running one, IDENTICALLY.
//!
//! `docs/51` made the restart itself cheap: `slopdesk-superd` holds every pane's PTY master, both
//! child-facing sockets and the panel backends, so stopping hostd costs a client reconnect instead
//! of whatever `claude` was mid-way through. What stayed expensive was the RITUAL — find the
//! process without `pkill` matching too much, wait long enough, remember which flags it had,
//! notice that `--port 0` bound something else. A restart that is technically free but manually
//! fiddly still gets postponed, which is the behaviour this subsystem set out to change.
//!
//! So the daemon states its own launch — a `LaunchRecord`, written once the REAL bound port is
//! known — and this reads it. Nothing here parses `ps` for a flag, guesses a port or retypes an
//! argument.
//!
//! ## What the port to Rust actually changed
//! `jq` stopped being a hard dependency. The shell read six fields with six `jq -r` forks and then
//! reached for `@sh` + `eval` for the two ARRAY fields, because an environment value holding a
//! space, a quote or a newline is not hypothetical and no other bash spelling survives one. That
//! whole apparatus is a `serde` derive now — and it is the SAME derive the daemon writes with
//! ([`slopdesk_hostlaunch::record`]), which is the part that matters here. This module used to
//! carry its own reader for a Swift `Codable` struct's eight fields: two spellings of one document,
//! in two languages, where a rename on either side compiles, passes and silently breaks the
//! restart. Reading is now the writer's own type, and the fields cannot come apart.
//!
//! ## The order, which is the thing that must not change
//! The launchd job is booted out BEFORE the stop, because `com.slopdesk.hostd` keeps itself alive
//! and would otherwise relaunch the installed binary into a race with the replayed one — a race
//! whose loser exits 0, so losing it is silent (`ops::launchd`'s `HOSTD`).
//! Everything is read from the record UP FRONT, because hostd DELETES it on an orderly shutdown
//! (an absent file means "no hostd", which is worth telling apart from "one died badly"). The
//! build comes BEFORE the stop, because a build that fails must leave the running daemon alone
//! rather than replace it with nothing. The stop is SIGTERM and never SIGKILL, because the handler
//! runs the orderly drain — panes relinquished to superd, backends relinquished, clients told
//! `bye`, journals flushed. And the readiness test is a real LISTENER, never the record file: a
//! file a previous run left behind is exactly how a readiness check lies.
//!
//! ## The build step is `cargo` now, and one launch record is REFUSED
//! `docs/60` stage F made hostd a cargo binary, so the build is `cargo build` in
//! `rust/slopdesk-hostd` rather than `swift build --product`. The rest of the ritual is untouched,
//! because none of it ever knew what compiled the binary — the record names an absolute path and
//! this replays it.
//!
//! The one case that could not stay silent is a record naming a `.build/` artifact: a daemon
//! started before the cutover, still running, whose launch this can no longer reproduce because the
//! target that produced it is gone. Building the cargo binary and then replaying that record would
//! report a fresh build and start the old daemon — the exact "running last week's code with this
//! week's version on the box" failure `audit.rs` exists to catch. It refuses in words instead, the
//! way an absent record does, and says which binary to start by hand once.
//!
//! `docs/51-process-supervision.md` §9, `docs/46-gates-env-paths.md`, `docs/60-hostd-in-rust.md`.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use slopdesk_hostlaunch::record::{self, LaunchRecord};

use super::{launchd, log_dir, say};
use crate::proc;

/// What the caller asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Plan {
    /// Rebuild before stopping.
    pub build: bool,
    /// Stop the recorded daemon.
    pub stop: bool,
    /// Start a replacement.
    pub start: bool,
}

impl Plan {
    /// The whole loop: build, stop, start, verify.
    pub const FULL: Self = Self {
        build: true,
        stop: true,
        start: true,
    };
    /// Report and change nothing.
    pub const STATUS: Self = Self {
        build: false,
        stop: false,
        start: false,
    };

    /// True when there is nothing to do but report.
    #[must_use]
    pub const fn is_status_only(self) -> bool {
        !self.build && !self.stop && !self.start
    }
}

/// The port the recorded argv ASKED for, in either spelling, if it named one at all.
///
/// `--port 0` is the case this exists for: it asks the OS for an ephemeral port, so the number the
/// old process bound says nothing about the new one, and polling it would time out on a daemon
/// that is up and well.
#[must_use]
pub fn requested_port(arguments: &[String]) -> Option<String> {
    let mut found = None;
    let mut previous: Option<&str> = None;
    for argument in arguments {
        if let Some(joined) = argument.strip_prefix("--port=") {
            found = Some(joined.to_owned());
        } else if matches!(previous, Some("--port" | "-p")) {
            found = Some(argument.clone());
        }
        previous = Some(argument);
    }
    found
}

/// Which build configuration the recorded binary came from.
///
/// Read off the PATH rather than guessed: a `release/…` component is a release build and anything
/// else is a debug one, which is what the default has always been. It reads a `cargo` target
/// directory for the same reason it read a `SwiftPM` one — both spell the configuration as a path
/// component — so the cutover cost this function nothing.
#[must_use]
pub fn configuration_of(binary: &Path) -> &'static str {
    if binary.components().any(|part| part.as_os_str() == "release") {
        "release"
    } else {
        "debug"
    }
}

/// Whether a recorded binary is the `SwiftPM` host that `docs/60` stage F deleted.
///
/// The `.build` component is the whole test, and it is enough: `SwiftPM` puts every artifact under
/// it, cargo puts none there. A record naming one is not a stale path to repair — it is a daemon
/// from before the cutover, still running, whose launch cannot be reproduced by building anything
/// that exists now.
#[must_use]
pub fn is_swiftpm_artifact(binary: &Path) -> bool {
    binary.components().any(|part| part.as_os_str() == ".build")
}

/// Where the record lives — the writer's own answer, not a second derivation of it.
///
/// `SLOPDESK_APP_SUPPORT_DIR` moves the container and this honours it for the same reason the
/// daemon does: a test, or a second host on the same machine, gets its own record without a second
/// name having to be invented. Asking [`record::path`] rather than rebuilding the join is what
/// keeps the override one rule.
fn record_path() -> Option<PathBuf> {
    record::path()
}

/// True when a pid exists — the cheap half of the identity check.
fn pid_exists(pid: i32) -> bool {
    proc::ask("/bin/kill", &["-0", &pid.to_string()], Path::new("/")).is_some()
}

/// The executable the kernel actually ran for a pid, or `None` when `lsof` declines.
///
/// `lsof -d txt`, not `ps -o comm=`. `comm` is argv[0] as the caller typed it — usually the
/// relative `.build/release/slopdesk-hostd` — while `txt` is the vnode the kernel executed, which
/// is what the record holds (`slopdesk_hostlaunch::record`'s `running_executable`, symlinks
/// resolved on both sides so `.build/release` and `.build/arm64-apple-macosx/release` are one
/// file).
fn running_executable(pid: i32) -> Option<String> {
    let dump = proc::ask(
        "/usr/sbin/lsof",
        &["-a", "-p", &pid.to_string(), "-d", "txt", "-Fn"],
        Path::new("/"),
    )?;
    dump.lines()
        .find_map(|line| line.strip_prefix('n'))
        .map(str::to_owned)
}

/// Whether the recorded daemon is the process at the recorded pid.
///
/// Pids are recycled, so existence is not identity — signalling a reused pid is the failure mode
/// that made `pkill` a trap in the first place.
fn is_alive(record: &LaunchRecord) -> bool {
    if !pid_exists(record.pid) {
        return false;
    }
    match running_executable(record.pid) {
        Some(path) if Path::new(&path) == record.binary => true,
        Some(path) => {
            say(
                "host-restart",
                &format!(
                    "record pid {} is alive but runs '{path}', not '{}' — pid reused, the record is stale",
                    record.pid,
                    record.binary.display()
                ),
            );
            false
        },
        None => {
            // lsof declined (permissions, a hardened process). The name is weaker than the vnode
            // and still stronger than signalling a pid on trust alone.
            let comm = proc::ask(
                "/bin/ps",
                &["-o", "comm=", "-p", &record.pid.to_string()],
                Path::new("/"),
            )
            .unwrap_or_default();
            let same = Path::new(comm.trim()).file_name() == record.binary.file_name();
            if same {
                say(
                    "host-restart",
                    &format!(
                        "could not read pid {}'s executable — matched on name only",
                        record.pid
                    ),
                );
            }
            same
        },
    }
}

/// How many children superd is holding, as a printable answer.
///
/// Counted by PARENTAGE rather than by asking superd: superd is the parent of every pane's shell
/// and of both panel backends, which is the whole architecture in one number, and it needs no
/// protocol, no client and no socket — all three of which are exactly what is unavailable
/// mid-restart.
fn superd_children() -> String {
    let Some(pid) = proc::ask("/usr/bin/pgrep", &["-x", "slopdesk-superd"], Path::new("/"))
        .and_then(|list| list.lines().next().map(str::to_owned))
    else {
        return "superd not running".to_owned();
    };
    let count = proc::ask("/usr/bin/pgrep", &["-P", pid.trim()], Path::new("/")).map_or(0, |children| {
        children.lines().filter(|line| !line.trim().is_empty()).count()
    });
    count.to_string()
}

/// True when something is LISTENING on a port.
fn listening(port: &str) -> bool {
    proc::ask(
        "/usr/sbin/lsof",
        &["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-t"],
        Path::new("/"),
    )
    .is_some_and(|answer| !answer.trim().is_empty())
}

/// Poll a condition until it holds, or give up after `budget`.
fn until(budget: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    condition()
}

/// The whole loop.
///
/// # Errors
/// When the build fails, the daemon will not stop, the port stays held, there is no record to
/// reproduce, or nothing is listening afterwards.
#[expect(
    clippy::too_many_lines,
    reason = "the shape IS the restart sequence, and splitting it would scatter an order that has to be \
              read in order"
)]
pub fn run(root: &Path, plan: Plan) -> Result<(), String> {
    let path = record_path().ok_or_else(|| {
        "no home directory, so there is no container a launch record could be in".to_owned()
    })?;
    let record = match fs::read_to_string(&path) {
        Ok(text) => Some(record::parse(&text)?),
        Err(_) => None,
    };

    let alive = record.as_ref().is_some_and(is_alive);
    match record.as_ref() {
        None => {
            say(
                "host-restart",
                &format!(
                    "no launch record at {} — no hostd has run since the last clean stop",
                    path.display()
                ),
            );
        },
        Some(found) if alive => {
            say(
                "host-restart",
                &format!(
                    "hostd pid {} on port {} (v{}), started {}",
                    found.pid, found.port, found.version, found.started_at
                ),
            );
        },
        Some(found) => {
            say(
                "host-restart",
                &format!(
                    "launch record names pid {}, which is gone — hostd died without an orderly stop",
                    found.pid
                ),
            );
        },
    }
    let children_before = superd_children();
    say(
        "host-restart",
        &format!("superd is holding {children_before} child process(es)"),
    );

    if plan.is_status_only() {
        return Ok(());
    }

    if plan.build {
        // The ONE launch this cannot rebuild: a record still naming the `SwiftPM` artifact. hostd is
        // a cargo binary as of `docs/60` stage F, so `.build/` holds last week's daemon — and
        // replaying that record after a `cargo build` would start the OLD one while reporting a
        // fresh build, which is the "running last week's code" failure the version audit exists to
        // catch. Refused in words, the way a missing record is, rather than silently substituting a
        // path: `make host-restart` replays the recorded launch EXACTLY, and swapping the binary
        // under it would make that sentence false.
        if let Some(found) = record.as_ref().filter(|found| is_swiftpm_artifact(&found.binary)) {
            return Err(format!(
                "the launch record names the SwiftPM host ({}), which stage F deleted — stop it, start \
                 rust/slopdesk-hostd/target/release/slopdesk-hostd once by hand, and this takes over from \
                 the record that one writes",
                found.binary.display()
            ));
        }
        // `release` with no record, where the `SwiftPM` build defaulted to `debug`. A first launch on
        // this machine is the release binary `make host` produces, and a debug daemon is a
        // different program at the operating point the fan-out was measured at.
        let configuration = record
            .as_ref()
            .map_or("release", |found| configuration_of(&found.binary));
        let arguments: &[&str] = if configuration == "release" {
            &["build", "--release"]
        } else {
            &["build"]
        };
        say(
            "host-restart",
            &format!("cargo build ({configuration}) in rust/slopdesk-hostd"),
        );
        proc::run("cargo", arguments, &root.join("rust/slopdesk-hostd"))?;
    }

    let mut stopped_at = None;
    if plan.stop {
        // BEFORE the SIGTERM, and unconditionally. `com.slopdesk.hostd` carries
        // `KeepAlive: SuccessfulExit=false` (`ops::launchd`'s `HOSTD`), so a signalled daemon under
        // that agent is relaunched within seconds — from `~/Library/Application Support`, which is
        // whatever `install hostd` last copied there, not what was just built. That relaunch RACES
        // the replay below for the port, and the loser exits 0, which is what makes the wrong winner
        // SILENT: the listener check passes, this reports success, and the daemon on the port is
        // last week's. Booting the job out is what makes the replay the only bidder.
        if launchd::bootout(&launchd::HOSTD, Duration::from_secs(20))? {
            say(
                "host-restart",
                &format!(
                    "booted {} out of launchd — the replay owns the port now; `slopdesk-ops install hostd` \
                     puts the agent back",
                    launchd::HOSTD.label
                ),
            );
        }
        if let (true, Some(found)) = (alive, record.as_ref()) {
            stopped_at = Some(Instant::now());
            say("host-restart", &format!("SIGTERM → pid {}", found.pid));
            let _ = proc::ask("/bin/kill", &["-TERM", &found.pid.to_string()], Path::new("/"));
            if !until(Duration::from_secs(20), || !pid_exists(found.pid)) {
                return Err(format!(
                    "pid {} did not exit within 20s of SIGTERM — investigate rather than forcing it; a \
                     SIGKILL here skips the orderly drain",
                    found.pid
                ));
            }
            say("host-restart", &format!("pid {} exited", found.pid));

            // The port, SEPARATELY. An exited process is not a freed listener, and launching into
            // a port that is not free yet is the "left a host on the port" failure by another route.
            let port = found.port.to_string();
            if !until(Duration::from_secs(20), || !listening(&port)) {
                return Err(format!(
                    "port {port} is still listening 20s after pid {} exited — something else holds it",
                    found.pid
                ));
            }
        } else {
            say("host-restart", "nothing running to stop");
        }
    }

    if !plan.start {
        say(
            "host-restart",
            &format!(
                "stopped — superd is holding {} child process(es), unchanged",
                superd_children()
            ),
        );
        return Ok(());
    }

    let found = record.as_ref().ok_or_else(|| {
        "no launch record, so there is nothing to reproduce — start hostd once by hand and this takes over"
            .to_owned()
    })?;
    if !found.binary.is_file() {
        return Err(format!(
            "recorded binary is not executable: {}",
            found.binary.display()
        ));
    }
    if !found.working_directory.is_dir() {
        return Err(format!(
            "recorded working directory is gone: {}",
            found.working_directory.display()
        ));
    }

    let log = log_dir()?.join("hostd.log");
    say(
        "host-restart",
        &format!(
            "starting {} {}",
            found.binary.display(),
            found.arguments.join(" ")
        ),
    );
    spawn_detached(found, &log)?;

    // Usually the recorded port. Not for `--port 0` — see `requested_port`.
    let expected = if requested_port(&found.arguments).as_deref() == Some("0") {
        say(
            "host-restart",
            "launched with --port 0 — waiting for the new daemon to publish its bound port",
        );
        let mut bound = None;
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline && bound.is_none() {
            if let Ok(text) = fs::read_to_string(&path)
                && let Ok(fresh) = record::parse(&text)
                && fresh.pid != found.pid
                && pid_exists(fresh.pid)
            {
                bound = Some(fresh.port.to_string());
            }
            if bound.is_none() {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        let bound = bound.ok_or_else(|| {
            format!(
                "the new daemon never published a launch record 30s after launch — see {}",
                log.display()
            )
        })?;
        say(
            "host-restart",
            &format!(
                "the new daemon bound port {bound} (the old one had {})",
                found.port
            ),
        );
        bound
    } else {
        found.port.to_string()
    };

    if !until(Duration::from_secs(30), || listening(&expected)) {
        return Err(format!(
            "nothing is listening on port {expected} 30s after launch — see {}",
            log.display()
        ));
    }

    if let Some(at) = stopped_at {
        say(
            "host-restart",
            &format!(
                "listening again on {expected} — down for {:.2}s",
                at.elapsed().as_secs_f64()
            ),
        );
    } else {
        say("host-restart", &format!("listening on {expected}"));
    }
    say(
        "host-restart",
        &format!(
            "superd is holding {} child process(es) — was {children_before} before the restart",
            superd_children()
        ),
    );
    say("host-restart", &format!("log: {}", log.display()));
    Ok(())
}

/// Start the recorded daemon so that it OUTLIVES this process.
///
/// The shell's `nohup … &` inside a subshell. Here the child gets its own session — a fresh
/// process group detached from this terminal — so a Ctrl-C at the prompt this returns to does not
/// take the daemon with it, and its streams are the append-mode log rather than inherited pipes.
fn spawn_detached(record: &LaunchRecord, log: &Path) -> Result<(), String> {
    use std::process::{Command, Stdio};

    let out = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .map_err(|error| format!("{}: {error}", log.display()))?;
    let err = out
        .try_clone()
        .map_err(|error| format!("{}: {error}", log.display()))?;

    // `/usr/bin/env --` is not portable to macOS's `env`, and it is not needed: the recorded pairs
    // are `SLOPDESK_*=…` by construction (`slopdesk_hostlaunch::record`'s `config_variables`), so
    // none can be mistaken for an option.
    let mut command = Command::new("/usr/bin/env");
    command
        .arg("-P")
        .arg("/usr/bin:/bin")
        // Flattened to the `KEY=VALUE` pairs `env` takes. A value holding a space, a quote or a
        // newline is carried verbatim here, which is the whole reason the shell needed `@sh`.
        .args(
            record
                .environment
                .iter()
                .map(|(key, value)| format!("{key}={value}")),
        )
        .arg(&record.binary)
        .args(&record.arguments)
        .current_dir(&record.working_directory)
        .stdin(Stdio::null())
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(err));
    command
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("{}: {error}", record.binary.display()))
}

#[cfg(test)]
mod tests {
    // The record's own round-trip, its key order and its required-versus-report fields are
    // `slopdesk_hostlaunch::record`'s tests, where the declaration is. Asserting them again here
    // would be the second spelling this module just stopped carrying.

    /// Both spellings of the flag, and the LAST one winning, which is what the daemon's own parse
    /// does.
    #[test]
    fn the_requested_port_is_read_from_either_spelling() {
        let split = [
            "--port".to_owned(),
            "0".to_owned(),
            "--shell".to_owned(),
            "/bin/sh".to_owned(),
        ];
        assert_eq!(super::requested_port(&split).as_deref(), Some("0"));

        let joined = ["--port=47420".to_owned()];
        assert_eq!(super::requested_port(&joined).as_deref(), Some("47420"));

        let short = ["-p".to_owned(), "9000".to_owned()];
        assert_eq!(super::requested_port(&short).as_deref(), Some("9000"));

        let none = ["--shell".to_owned(), "/bin/sh".to_owned()];
        assert_eq!(super::requested_port(&none), None);
    }

    /// `--shell` whose VALUE is `--port` must not be read as a flag — the value wins its own turn.
    #[test]
    fn a_flag_value_that_looks_like_a_flag_is_still_a_value() {
        let tricky = [
            "--shell".to_owned(),
            "--port".to_owned(),
            "--port".to_owned(),
            "8080".to_owned(),
        ];
        assert_eq!(super::requested_port(&tricky).as_deref(), Some("8080"));
    }

    /// The configuration comes off the path, and anything that is not release is debug.
    #[test]
    fn the_build_configuration_is_read_off_the_recorded_path() {
        assert_eq!(
            super::configuration_of(std::path::Path::new("/r/.build/release/slopdesk-hostd")),
            "release"
        );
        assert_eq!(
            super::configuration_of(std::path::Path::new(
                "/r/.build/arm64-apple-macosx/release/slopdesk-hostd"
            )),
            "release"
        );
        assert_eq!(
            super::configuration_of(std::path::Path::new("/r/.build/debug/slopdesk-hostd")),
            "debug"
        );
        assert_eq!(
            super::configuration_of(std::path::Path::new("/usr/local/bin/slopdesk-hostd")),
            "debug"
        );
        // The cargo target directory spells the configuration the same way, which is why the
        // cutover changed nothing here.
        assert_eq!(
            super::configuration_of(std::path::Path::new(
                "/r/rust/slopdesk-hostd/target/release/slopdesk-hostd"
            )),
            "release"
        );
        assert_eq!(
            super::configuration_of(std::path::Path::new(
                "/r/rust/slopdesk-hostd/target/debug/slopdesk-hostd"
            )),
            "debug"
        );
    }

    /// A record from before the cutover is recognised, and one from after it is not mistaken for
    /// one.
    ///
    /// The pair matters more than either half. `.build` and `target` both hold a `release`
    /// component, so a test that only checked the `SwiftPM` path would pass just as well against a
    /// rule that refused every launch record there is.
    #[test]
    fn the_swiftpm_host_is_told_apart_from_the_cargo_one() {
        assert!(super::is_swiftpm_artifact(std::path::Path::new(
            "/r/.build/arm64-apple-macosx/release/slopdesk-hostd"
        )));
        assert!(!super::is_swiftpm_artifact(std::path::Path::new(
            "/r/rust/slopdesk-hostd/target/release/slopdesk-hostd"
        )));
        assert!(!super::is_swiftpm_artifact(std::path::Path::new(
            "/usr/local/bin/slopdesk-hostd"
        )));
    }

    /// `--status` changes nothing, and the full plan does all three.
    #[test]
    fn the_status_plan_is_the_only_one_that_does_nothing() {
        assert!(super::Plan::STATUS.is_status_only());
        assert!(!super::Plan::FULL.is_status_only());
        assert!(
            !super::Plan {
                build: false,
                stop: true,
                start: false
            }
            .is_status_only()
        );
    }
}
