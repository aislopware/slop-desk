//! The two `LaunchAgent`s, as ONE installer and two descriptions.
//!
//! `install-superd.sh` and `install-screend.sh` were 294 lines that differed in six things: the
//! label, the binary, the log file, one `EnvironmentVariables` block, one `KeepAlive` shape and
//! whether restarting costs the developer anything. Everything else — the release build, the
//! rename-into-place, the plist write, the bootout/bootstrap/kickstart, the `state = running`
//! poll — was duplicated verbatim, and the duplication was load-bearing in the worst way: a fix
//! to one was a fix to neither until somebody remembered the other file existed.
//!
//! Here they are [`SUPERD`] and [`SCREEND`], two [`Agent`] values, and the installer is one
//! function that reads them.
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

use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

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
#[derive(Debug)]
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

/// The agent a verb names, or the list of the ones that exist.
///
/// # Errors
/// When the name is not one of the two.
pub fn by_name(name: &str) -> Result<&'static Agent, String> {
    match name {
        "superd" => Ok(&SUPERD),
        "screend" => Ok(&SCREEND),
        other => Err(format!("unknown agent: {other} (superd | screend)")),
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

/// Unload the agent and take its plist away, leaving the installed binary in place.
///
/// # Errors
/// When the developer declines a restart that costs panes, or the plist cannot be removed.
pub fn uninstall(agent: &Agent, force: bool) -> Result<(), String> {
    confirm_restart(agent, force)?;
    let domain = domain()?;
    let plist_file = plist_path(agent);
    // `ask`, not `run`: booting out a job that is not loaded is the ordinary case here.
    let _ = proc::ask(
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
    let _ = proc::ask("/bin/launchctl", &["bootout", &job], Path::new("/"));
    proc::run(
        "/bin/launchctl",
        &["bootstrap", &domain, &plist_file.to_string_lossy()],
        Path::new("/"),
    )?;
    let _ = proc::ask("/bin/launchctl", &["kickstart", &job], Path::new("/"));

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
        std::thread::sleep(std::time::Duration::from_millis(200));
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

    /// The two names the CLI accepts, and that a third is refused rather than defaulted.
    #[test]
    fn only_the_two_agents_that_exist_resolve() {
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
