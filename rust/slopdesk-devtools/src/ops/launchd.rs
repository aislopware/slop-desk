//! The four `LaunchAgent`s, as ONE installer and four descriptions.
//!
//! `install-superd.sh` and `install-screend.sh` were 294 lines that differed in six things: the
//! label, the binary, the log file, one `EnvironmentVariables` block, one `KeepAlive` shape and
//! whether restarting costs the developer anything. Everything else — the release build, the
//! rename-into-place, the plist write, the bootout/bootstrap/kickstart, the `state = running`
//! poll — was duplicated verbatim, and the duplication was load-bearing in the worst way: a fix
//! to one was a fix to neither until somebody remembered the other file existed.
//!
//! Here they are [`SUPERD`], [`SCREEND`], [`HOSTD`] and [`VIDEOHOSTD`], four [`Agent`] values, and
//! the installer is one function that reads them.
//!
//! ## Why hostd is one of them now
//! It was not, and the reason it was not is gone: a menu-bar app spawned the daemon, so a first
//! start had a button behind it. `docs/60` deleted the app — hostd is controlled entirely by CLI —
//! and `restart-hostd` replays a launch RECORD, which by construction cannot produce the first
//! one. This is the rung under it: `slopdesk-ops install hostd` gives a cold machine a hostd, and
//! `restart-hostd` takes over from there.
//!
//! ## The two shapes of `KeepAlive`, which are not interchangeable
//! screend takes a bare `true`: it holds no children and no durable state, so relaunching it is
//! free and always right.
//!
//! superd takes `SuccessfulExit: false`, and a bare `true` there is a BUG that shipped once.
//! superd exits 0 ON PURPOSE when another instance already holds its lock file — "exiting rather
//! than stealing its socket" — so under a bare `KeepAlive` the loser respawned every ten seconds
//! for ever and wrote that line to the log each time. A clean SIGTERM at logout is also an exit 0
//! and must not be restarted either. Two agents can coexist (this one and the Homebrew formula's,
//! `docs/49`) with whichever booted first holding the panes and the other quiet.
//!
//! ## Why the binary is installed OUT of the build tree
//! launchd re-execs the path in the plist. A `cargo clean` — or a rebuild replacing the inode
//! mid-flight — must not be able to leave the agent pointing at nothing, so the release binary is
//! copied to `~/Library/Application Support/SlopDesk/bin/` and replaced there by RENAME. A `cp`
//! onto a running binary is `ETXTBSY`, and a partial write would leave launchd re-execing a
//! truncated file.

#![expect(
    clippy::print_stdout,
    clippy::print_stderr,
    reason = "the install prompt and the closing status are this verb's report"
)]

use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::{home, log_dir, say};
use crate::proc;

/// What restarting an agent costs the developer, which decides whether they are asked first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestartCost {
    /// Nothing durable: no children, no state a repaint cannot refill. Never prompts.
    Free,
    /// One SIGHUP per live pane, agents included. Prompts unless `--force`.
    EveryLivePane,
}

/// One `LaunchAgent`, in the six ways the two differ.
#[derive(Debug, Clone, Copy)]
pub struct Agent {
    /// The launchd label, which is also the plist's basename.
    pub label: &'static str,
    /// The crate directory under `rust/`, which is both the build root and the binary name.
    pub crate_name: &'static str,
    /// What a reinstall costs.
    pub cost: RestartCost,
    /// `EnvironmentVariables` pairs, if the agent needs any.
    pub environment: &'static [(&'static str, &'static str)],
    /// The `KeepAlive` value, verbatim, as the plist body between the key and the next key.
    pub keep_alive: &'static str,
    /// What the closing report says about the socket.
    pub socket: &'static str,
}

/// superd: the process that holds every pane's PTY master (`docs/51`).
pub const SUPERD: Agent = Agent {
    label: "com.slopdesk.superd",
    crate_name: "slopdesk-superd",
    cost: RestartCost::EveryLivePane,
    environment: &[],
    // See the module doc: a bare `true` respawns the instance that deliberately exited 0.
    keep_alive: "    <dict>\n        <key>SuccessfulExit</key>\n        <false/>\n    </dict>",
    socket: "$TMPDIR/slopdesk-superd.sock",
};

/// screend: the VT screen engine (`docs/52`).
pub const SCREEND: Agent = Agent {
    label: "com.slopdesk.screend",
    crate_name: "slopdesk-screend",
    cost: RestartCost::Free,
    // Never exit on idleness: this copy's lifetime belongs to launchd, and `KeepAlive` would
    // relaunch it seconds later anyway — an exit/respawn loop for as long as nobody uses it. An
    // engine hostd started for ITSELF keeps the default timeout and goes away with it.
    environment: &[("SLOPDESK_SCREEND_IDLE_EXIT", "0")],
    keep_alive: "    <true/>",
    socket: "$TMPDIR/slopdesk-screend.sock",
};

/// hostd itself: the daemon the clients dial (`docs/60`).
///
/// `SuccessfulExit: false`, for superd's reason rather than its own: hostd exits 0 on `AddrInUse`
/// — another host is already serving the port — and a bare `KeepAlive` would respawn the loser for
/// ever. A clean SIGTERM at logout is also an exit 0.
///
/// That exit-0 is what makes `just host-restart` converge under this agent rather than loop.
/// Signal death is not a successful exit, so launchd relaunches the hostd that `restart-hostd`
/// just `SIGTERM`ed, and that relaunch RACES the replayed one for the port. One of the two loses
/// the bind — and because losing is an exit 0, launchd lets it stay dead instead of feeding it back
/// into the same race. Wire that bind to `exit(1)` and this becomes an endless respawn.
///
/// What that convergence does NOT decide is WHICH BUILD wins. This installer copies the release
/// binary to `~/Library/Application Support/SlopDesk/bin/`, and `restart-hostd` replays a record
/// naming `rust/target/release` — two paths that drift apart the moment either is rebuilt without
/// the other. So on a machine with this agent installed, a `host-restart` is a coin flip between
/// the daemon just built and whatever was installed last, and the loser exiting 0 makes the wrong
/// winner SILENT: the replay sees a live listener and reports success. `install hostd` is therefore
/// for a machine that has NO hostd, not a second way to run one beside the build tree.
///
/// So `ops::hostd` boots this job out before it replays, through [`bootout`] — unconditionally,
/// because "is an agent installed" is not something a developer should have to remember
/// mid-restart, and the answer on a build-tree machine is a cheap `launchctl print` that says no.
/// The convergence above is still what makes the SIGTERM safe; the bootout is what makes the winner
/// the daemon that was just built.
///
/// `EveryLivePane` even though hostd holds no PTY: superd does, and every one of them is wired to
/// this process's fan-out. A restart costs the developer exactly what `just host-restart` costs,
/// so it asks first for exactly the same reason.
pub const HOSTD: Agent = Agent {
    label: "com.slopdesk.hostd",
    crate_name: "slopdesk-hostd",
    cost: RestartCost::EveryLivePane,
    environment: &[],
    keep_alive: "    <dict>\n        <key>SuccessfulExit</key>\n        <false/>\n    </dict>",
    socket: "tcp/7420 (slopdesk_hostlaunch::args::DEFAULT_PORT)",
};

/// videohostd: the GUI video host (`docs/61`), the daemon behind the client's remote-window pane.
///
/// A `LaunchAgent` and NOT a hostd child, for TCC's sake. Screen Recording and Accessibility are
/// granted to the RESPONSIBLE process, and a child of a launchd job inherits its parent's — so a
/// videohostd forked under superd the way dropd is would have the user granting Screen Recording
/// to `slopdesk-superd`, and revoking it there. A job of its own is its own responsible process,
/// and the prompt names the binary that captures. (Disclaiming responsibility at spawn is an SPI
/// `slopdesk-posix` does not carry — `docs/57` — and `docs/70` §3 records the trade.)
///
/// superd's `KeepAlive` shape, for hostd's reason: `EADDRINUSE` — a checkout's videohostd already
/// on 9000/9001, or a relaunch racing the process it replaced — is a deliberate exit 0 in
/// `slopdesk-videohostd`'s `main`, and a bare `true` would respawn the loser for ever.
///
/// `Free`: it holds no PTY and no durable state. A reinstall costs one live GUI session, and the
/// client rebuilds that on its own (`VideoWindowPipeline.rebuildAfterHostEndedSession`).
pub const VIDEOHOSTD: Agent = Agent {
    label: "com.slopdesk.videohostd",
    crate_name: "slopdesk-videohostd",
    cost: RestartCost::Free,
    environment: &[],
    keep_alive: "    <dict>\n        <key>SuccessfulExit</key>\n        <false/>\n    </dict>",
    socket: "udp/9000 media + udp/9001 cursor (slopdesk_videohostd::args defaults)",
};

/// The agent a verb names, or the list of the ones that exist.
///
/// # Errors
/// When the name is not one of the four.
pub fn by_name(name: &str) -> Result<&'static Agent, String> {
    match name {
        "superd" => Ok(&SUPERD),
        "screend" => Ok(&SCREEND),
        "hostd" => Ok(&HOSTD),
        "videohostd" => Ok(&VIDEOHOSTD),
        other => {
            Err(format!(
                "unknown agent: {other} (superd | screend | hostd | videohostd)"
            ))
        },
    }
}

/// Where launchd is asked about this user's agents.
fn domain() -> Result<String, String> {
    let uid = proc::capture("/usr/bin/id", &["-u"], Path::new("/"))?;
    Ok(format!("gui/{uid}"))
}

/// Where the plist goes.
fn plist_path(agent: &Agent) -> PathBuf {
    home().join(format!("Library/LaunchAgents/{}.plist", agent.label))
}

/// Where the running copy of the binary lives — out of the build tree, on purpose.
fn installed_binary(agent: &Agent) -> PathBuf {
    home().join(format!(
        "Library/Application Support/SlopDesk/bin/{}",
        agent.crate_name
    ))
}

/// The plist text for an agent, given the two paths that vary per machine.
///
/// A pure function so the shape is testable without a `launchctl` on the other end — the shell
/// versions were unquoted heredocs, which is a `<!-- backtick -->` away from being a command
/// substitution the shell runs (shellcheck caught exactly that in the first draft of one).
#[must_use]
pub fn plist(agent: &Agent, binary: &Path, log: &Path) -> String {
    let mut environment = String::new();
    if !agent.environment.is_empty() {
        environment.push_str("    <key>EnvironmentVariables</key>\n    <dict>\n");
        for (key, value) in agent.environment {
            environment.push_str("        <key>");
            environment.push_str(key);
            environment.push_str("</key>\n        <string>");
            environment.push_str(value);
            environment.push_str("</string>\n");
        }
        environment.push_str("    </dict>\n");
    }
    // `TMPDIR` is deliberately absent: launchd already gives an agent the per-user, 0700 `$TMPDIR`
    // that makes an un-suffixed socket name safe, and hardcoding one would put the agent and hostd
    // in different directories — the pid-in-the-path bug wearing a new hat.
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
{keep_alive}
{environment}    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>{log}</string>
    <key>StandardErrorPath</key>
    <string>{log}</string>
</dict>
</plist>
"#,
        label = agent.label,
        binary = binary.display(),
        keep_alive = agent.keep_alive,
        environment = environment,
        log = log.display(),
    )
}

/// The pid launchd reports for a job, from a `launchctl print` dump.
///
/// A parser rather than a pipe to `awk`, so the shape is pinned by a test: the line is a TAB then
/// `pid = N`, and a `state = running` job with no pid line is a job that is about to have one.
#[must_use]
pub fn printed_pid(dump: &str) -> Option<i32> {
    dump.lines()
        .filter_map(|line| line.trim().strip_prefix("pid = "))
        .find_map(|value| value.trim().parse().ok())
}

/// True when a `launchctl print` dump says the job reached `running`.
#[must_use]
pub fn printed_running(dump: &str) -> bool {
    dump.lines().any(|line| line.trim() == "state = running")
}

/// How many children the agent is holding — one process per live pane, for superd.
///
/// Every failure answers zero rather than propagating, and that is not defensive noise: the state
/// that produces one is the agent running with NO panes, which is exactly the state the banner
/// tells the developer to reach before upgrading. The shell's `pgrep | wc -l` exited 1 there,
/// `pipefail` promoted it, and the installer aborted silently — the build succeeded, nothing was
/// installed, and the fix under test never loaded.
fn supervised_children(agent: &Agent) -> usize {
    let Ok(domain) = domain() else { return 0 };
    let Some(dump) = proc::ask(
        "/bin/launchctl",
        &["print", &format!("{domain}/{}", agent.label)],
        Path::new("/"),
    ) else {
        return 0;
    };
    let Some(pid) = printed_pid(&dump) else { return 0 };
    proc::ask("/usr/bin/pgrep", &["-P", &pid.to_string()], Path::new("/")).map_or(0, |children| {
        children.lines().filter(|line| !line.trim().is_empty()).count()
    })
}

/// Asks before a restart that costs live panes, unless `force`.
///
/// # Errors
/// When the developer declines.
fn confirm_restart(agent: &Agent, force: bool) -> Result<(), String> {
    if agent.cost == RestartCost::Free {
        return Ok(());
    }
    let count = supervised_children(agent);
    if count == 0 {
        return Ok(());
    }
    if force {
        println!(
            "⚠️  --force: restarting {} and killing {count} live pane(s)",
            agent.label
        );
        return Ok(());
    }
    println!(
        "⚠️  {} is currently supervising {count} live pane(s).",
        agent.label
    );
    println!("    Restarting it sends SIGHUP to every one of them — including any running agent.");
    print!("    Continue? [y/N] ");
    io::stdout().flush().map_err(|error| format!("stdout: {error}"))?;
    let mut answer = String::new();
    io::stdin()
        .read_line(&mut answer)
        .map_err(|error| format!("stdin: {error}"))?;
    if matches!(answer.trim(), "y" | "Y") {
        Ok(())
    } else {
        Err("aborted".to_owned())
    }
}

/// Whether launchd currently holds a job by this name in this user's domain.
///
/// `launchctl print` rather than a `list` grep: `list` prints a label that merely LOOKS loaded for
/// a job in the middle of being torn down, and `print` is the call that answers about one job.
fn loaded(job: &str) -> bool {
    proc::ask("/bin/launchctl", &["print", job], Path::new("/")).is_some()
}

/// Boot the agent's job out of this user's launchd domain, and WAIT for launchd to let go.
///
/// The mechanism half of the fix [`HOSTD`]'s own doc names and declines to make here: this knows
/// what "unloaded" costs, [`super::hostd`] knows when a replay has to be the only bidder for the
/// port. `Ok(false)` is the ordinary case on a build-tree machine — no agent installed, nothing to
/// boot out — and is deliberately not an error, so the caller can ask unconditionally.
///
/// The wait is the point. `bootout` returns as soon as launchd has ACCEPTED the request, not when
/// the job's process has finished exiting, so returning here on the exit code alone would hand the
/// caller a domain that still owns the socket it is about to bind.
///
/// # Errors
/// When the domain cannot be named, or the job is still loaded after `budget`.
pub fn bootout(agent: &Agent, budget: Duration) -> Result<bool, String> {
    let domain = domain()?;
    let job = format!("{domain}/{}", agent.label);
    if !loaded(&job) {
        return Ok(false);
    }
    // `ask`, not `run`: a job that exits between the probe above and this call boots itself out,
    // and launchd's non-zero for "no such process" is that race, not a failure.
    let _ignored = proc::ask("/bin/launchctl", &["bootout", &job], Path::new("/"));

    let deadline = Instant::now() + budget;
    while Instant::now() < deadline {
        if !loaded(&job) {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(format!(
        "{job} is still loaded {}s after bootout — launchd did not let go, so a replay would race it",
        budget.as_secs()
    ))
}

/// Unload the agent and take its plist away, leaving the installed binary in place.
///
/// # Errors
/// When the developer declines a restart that costs panes, or the plist cannot be removed.
pub fn uninstall(agent: &Agent, force: bool) -> Result<(), String> {
    confirm_restart(agent, force)?;
    let domain = domain()?;
    let plist_file = plist_path(agent);
    // `ask`, not `run`: booting out a job that is not loaded is the ordinary case here.
    let _ignored = proc::ask(
        "/bin/launchctl",
        &["bootout", &format!("{domain}/{}", agent.label)],
        Path::new("/"),
    );
    if plist_file.exists() {
        fs::remove_file(&plist_file).map_err(|error| format!("{}: {error}", plist_file.display()))?;
    }
    println!("✓ {} unloaded and {} removed", agent.label, plist_file.display());
    println!(
        "  (the binary at {} was left in place)",
        installed_binary(agent).display()
    );
    Ok(())
}

/// Build, install, load and VERIFY.
///
/// # Errors
/// When the build fails, the developer declines, launchd refuses the plist, or the job never
/// reaches `running`.
pub fn install(root: &Path, agent: &Agent, force: bool) -> Result<(), String> {
    let crate_dir = root.join("rust").join(agent.crate_name);
    say("install", &format!("building {} (release)", agent.crate_name));
    proc::run("cargo", &["build", "--release"], &crate_dir)?;
    let built = crate_dir.join("target/release").join(agent.crate_name);
    if !built.is_file() {
        return Err(format!("build produced no binary at {}", built.display()));
    }

    // AFTER the build, exactly as the shell did: a build that fails must not have cost the
    // developer their panes for nothing.
    confirm_restart(agent, force)?;

    let logs = log_dir()?;
    let log = logs.join(format!(
        "{}.log",
        agent.crate_name.trim_start_matches("slopdesk-")
    ));
    let installed = installed_binary(agent);
    let plist_file = plist_path(agent);
    for directory in [installed.parent(), plist_file.parent()].into_iter().flatten() {
        fs::create_dir_all(directory).map_err(|error| format!("{}: {error}", directory.display()))?;
    }

    // Replace by RENAME, never by overwrite — see the module doc.
    let staging = installed.with_extension("new");
    fs::copy(&built, &staging).map_err(|error| format!("{}: {error}", staging.display()))?;
    proc::run("/bin/chmod", &["755", &staging.to_string_lossy()], Path::new("/"))?;
    fs::rename(&staging, &installed).map_err(|error| format!("{}: {error}", installed.display()))?;

    fs::write(&plist_file, plist(agent, &installed, &log))
        .map_err(|error| format!("{}: {error}", plist_file.display()))?;

    let domain = domain()?;
    let job = format!("{domain}/{}", agent.label);
    let _ignored = proc::ask("/bin/launchctl", &["bootout", &job], Path::new("/"));
    proc::run(
        "/bin/launchctl",
        &["bootstrap", &domain, &plist_file.to_string_lossy()],
        Path::new("/"),
    )?;
    let _ignored = proc::ask("/bin/launchctl", &["kickstart", &job], Path::new("/"));

    // Verified, rather than trusting `bootstrap`'s exit code: a job that exits immediately still
    // bootstraps "successfully".
    for _ in 0..30 {
        if proc::ask("/bin/launchctl", &["print", &job], Path::new("/"))
            .is_some_and(|dump| printed_running(&dump))
        {
            println!("✓ {} is running", agent.label);
            println!("  binary: {}", installed.display());
            println!("  log:    {}", log.display());
            println!("  socket: {}", agent.socket);
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let tail = fs::read_to_string(&log).unwrap_or_default();
    let last: Vec<&str> = tail.lines().rev().take(20).collect();
    for line in last.iter().rev() {
        eprintln!("{line}");
    }
    Err(format!(
        "✗ {} did not reach 'running' (log: {})",
        agent.label,
        log.display()
    ))
}

#[cfg(test)]
mod tests {
    #![expect(clippy::expect_used, reason = "a panic in a test is the failure report")]
    use std::path::Path;

    /// superd's `KeepAlive` is the dict, not the bare `true` that once respawned a deliberate exit.
    #[test]
    fn superd_never_restarts_a_deliberate_exit() {
        let text = super::plist(
            &super::SUPERD,
            Path::new("/bin/superd"),
            Path::new("/tmp/superd.log"),
        );
        assert!(text.contains("<key>SuccessfulExit</key>"), "the guarded shape");
        assert!(
            !text.contains("<key>KeepAlive</key>\n    <true/>"),
            "never the bare one"
        );
    }

    /// hostd takes superd's guarded shape for superd's reason: it exits 0 when the port is held,
    /// and a bare `KeepAlive` respawns the loser for ever.
    #[test]
    fn hostd_never_restarts_a_deliberate_exit_either() {
        let text = super::plist(
            &super::HOSTD,
            Path::new("/bin/slopdesk-hostd"),
            Path::new("/tmp/hostd.log"),
        );
        assert!(text.contains("<key>SuccessfulExit</key>"), "the guarded shape");
        assert!(
            !text.contains("<key>KeepAlive</key>\n    <true/>"),
            "never the bare one"
        );
        assert!(text.contains("com.slopdesk.hostd"));
    }

    /// Every agent the installer can be asked for is one it can name back.
    #[test]
    fn every_installable_agent_resolves_by_name() {
        for name in ["superd", "screend", "hostd", "videohostd"] {
            assert!(super::by_name(name).is_ok(), "{name}");
        }
        assert!(
            super::by_name("androidd").is_err(),
            "superd's child, not an agent"
        );
    }

    /// videohostd exits 0 when its ports are held, so it takes the guarded shape too — and it
    /// carries no environment: its operating point is `video-prefs.json`'s, folded by the daemon.
    #[test]
    fn videohostd_never_restarts_a_deliberate_exit_either() {
        let text = super::plist(
            &super::VIDEOHOSTD,
            Path::new("/bin/videohostd"),
            Path::new("/tmp/videohostd.log"),
        );
        assert!(text.contains("<key>SuccessfulExit</key>"), "the guarded shape");
        assert!(
            !text.contains("<key>KeepAlive</key>\n    <true/>"),
            "never the bare one"
        );
        assert!(!text.contains("<key>EnvironmentVariables</key>"));
    }

    /// screend's is the bare `true`, and it carries the idle-exit override superd has no use for.
    #[test]
    fn screend_keeps_alive_unconditionally_and_never_idles_out() {
        let text = super::plist(
            &super::SCREEND,
            Path::new("/bin/screend"),
            Path::new("/tmp/screend.log"),
        );
        assert!(text.contains("<key>KeepAlive</key>\n    <true/>"));
        assert!(text.contains("<key>SLOPDESK_SCREEND_IDLE_EXIT</key>"));
        assert!(text.contains("<string>0</string>"));
    }

    /// An agent with no environment emits no empty `EnvironmentVariables` dict.
    #[test]
    fn an_agent_with_no_environment_writes_no_dict_for_it() {
        let text = super::plist(
            &super::SUPERD,
            Path::new("/bin/superd"),
            Path::new("/tmp/superd.log"),
        );
        assert!(!text.contains("EnvironmentVariables"));
    }

    /// Both plists name the INSTALLED path, never a `target/` one.
    #[test]
    fn the_plist_names_the_path_it_is_given() {
        let text = super::plist(
            &super::SCREEND,
            Path::new("/Users/x/Library/Application Support/SlopDesk/bin/slopdesk-screend"),
            Path::new("/Users/x/Library/Logs/SlopDesk/screend.log"),
        );
        assert!(
            text.contains(
                "<string>/Users/x/Library/Application Support/SlopDesk/bin/slopdesk-screend</string>"
            )
        );
        assert!(text.contains("<string>/Users/x/Library/Logs/SlopDesk/screend.log</string>"));
    }

    /// The `launchctl print` scrape, including the shape that has no pid yet.
    #[test]
    fn a_launchctl_dump_yields_its_pid_and_its_state() {
        let dump = "com.slopdesk.superd = {\n\tactive count = 1\n\tpid = 4242\n\tstate = running\n}\n";
        assert_eq!(super::printed_pid(dump), Some(4242));
        assert!(super::printed_running(dump));

        let waiting = "com.slopdesk.superd = {\n\tstate = waiting\n}\n";
        assert_eq!(super::printed_pid(waiting), None);
        assert!(!super::printed_running(waiting));
    }

    /// Each name resolves to its OWN label, and one that does not exist is refused rather than
    /// defaulted to whichever arm happens to be first.
    #[test]
    fn each_agent_resolves_to_its_own_label() {
        assert_eq!(
            super::by_name("superd").expect("superd").label,
            "com.slopdesk.superd"
        );
        assert_eq!(
            super::by_name("screend").expect("screend").label,
            "com.slopdesk.screend"
        );
        assert!(
            super::by_name("dropd").is_err(),
            "an agent that does not exist is an error"
        );
    }
}
