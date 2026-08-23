//! Measures the code panel backend's spawn → "HTTP server listening" latency.
//!
//! That is the half of panel-open cost the HOST owns; the other half — the workbench boot inside
//! the client's webview — is browser-side and measured with the workbench's own `code/*`
//! performance marks. Until the 2026-08-07 startup-latency pass nothing in-repo had ever measured
//! this chain: the numbers behind the prewarm decision lived in one session's scratchpad. Having it
//! here means a code-server pin bump (`docs/46` — "bumping a pin has a tail") can check the boot
//! did not regress.
//!
//! Each run spawns the binary against a THROWAWAY `HOME` — the seed and extension state of the real
//! profile is deliberately out of frame, because this measures the server bootstrap, not the
//! profile. The binary resolves the way the host resolves it: `SLOPDESK_CODE_SERVER_BIN`, then the
//! vendored prefix, then `PATH`.
//!
//! ## What the port changed
//! The shell called `python3` three times per run purely to read a clock and subtract; that is
//! [`Instant`] here, which is also monotonic where `time.time()` was not — a run that straddled an
//! NTP step used to report a latency that never happened.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use super::say;
use crate::proc;

/// How long a bootstrap may take before the harness gives up, matching the shell's 1200 × 50 ms.
const PATIENCE: Duration = Duration::from_secs(60);
/// The line code-server prints once its listener is bound.
const LISTENING: &str = "HTTP server listening";

/// The binary the host would pick, in the host's own order: override, vendored prefix, `PATH`.
///
/// `override_` is `SLOPDESK_CODE_SERVER_BIN` passed in rather than read here, so the order is a
/// property a test can state without touching a process-global the harness runs threaded across.
///
/// # Errors
/// When no executable is found at any of the three.
pub fn resolve(root: &Path, override_: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(explicit) = override_.filter(|path| !path.as_os_str().is_empty()) {
        return Ok(explicit.to_path_buf());
    }
    let vendored = root.join("ThirdParty/tools/.prefix/bin/code-server");
    if is_executable(&vendored) {
        return Ok(vendored);
    }
    proc::ask("/usr/bin/which", &["code-server"], root)
        .map(PathBuf::from)
        .filter(|path| is_executable(path))
        .ok_or_else(|| "no code-server binary (run 'make provision')".to_owned())
}

/// True for a file with an execute bit — `[[ -x ]]`, without the shell.
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// Time one bootstrap against a throwaway `HOME`.
///
/// # Errors
/// When the binary cannot be spawned, or never reports a listener within [`PATIENCE`].
fn measure_once(binary: &Path, fixture_home: &Path) -> Result<Duration, String> {
    fs::create_dir_all(fixture_home).map_err(|error| format!("{}: {error}", fixture_home.display()))?;
    let log = fixture_home.join("out.log");
    let sink = fs::File::create(&log).map_err(|error| format!("{}: {error}", log.display()))?;
    let errors = sink
        .try_clone()
        .map_err(|error| format!("{}: {error}", log.display()))?;

    let started = Instant::now();
    let mut child = Command::new(binary)
        .args([
            "--auth",
            "none",
            "--bind-addr",
            "127.0.0.1:0",
            "--disable-telemetry",
            "--disable-update-check",
            "--disable-workspace-trust",
            "--disable-getting-started-override",
        ])
        .env("HOME", fixture_home)
        .stdin(Stdio::null())
        .stdout(Stdio::from(sink))
        .stderr(Stdio::from(errors))
        .spawn()
        .map_err(|error| format!("{}: {error}", binary.display()))?;

    let mut elapsed = None;
    while started.elapsed() < PATIENCE {
        if fs::read_to_string(&log).is_ok_and(|text| text.contains(LISTENING)) {
            elapsed = Some(started.elapsed());
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
    let _ = fs::remove_dir_all(fixture_home);

    elapsed.ok_or_else(|| {
        format!(
            "no listen line after {}s (log: {})",
            PATIENCE.as_secs(),
            log.display()
        )
    })
}

/// Report the live host's code-server child, which a prewarmed hostd should already have.
///
/// A missing child right after a hostd restart is the regression this section catches; a child that
/// still carries `--idle-timeout-seconds` is a pre-prewarm build still running.
fn report_live_child(root: &Path) {
    let Some(pid) = proc::ask(
        "/usr/bin/pgrep",
        &["-f", "code-server.*--bind-addr 0.0.0.0:0"],
        root,
    )
    .and_then(|text| text.lines().next().map(str::to_owned))
    .filter(|pid| !pid.is_empty()) else {
        say(
            "code-server",
            "live host child: none (no hostd running, or its prewarm failed)",
        );
        return;
    };
    let since = proc::ask("/bin/ps", &["-o", "lstart=", "-p", &pid], root).unwrap_or_default();
    say(
        "code-server",
        &format!("live host child: pid {pid} up since {}", since.trim()),
    );
    if proc::ask("/bin/ps", &["-o", "command=", "-p", &pid], root)
        .is_some_and(|command| command.contains("--idle-timeout-seconds"))
    {
        say(
            "code-server",
            "  WARNING: live child still runs with --idle-timeout-seconds (pre-prewarm build?)",
        );
    }
}

/// Measure `runs` bootstraps and report, then describe the live host's own child.
///
/// # Errors
/// When the binary cannot be resolved or a run never reaches its listener.
pub fn run(root: &Path, runs: u32) -> Result<(), String> {
    let override_ = std::env::var_os("SLOPDESK_CODE_SERVER_BIN").map(PathBuf::from);
    let binary = resolve(root, override_.as_deref())?;
    say("code-server", &format!("binary: {}", binary.display()));
    let version = proc::capture(&binary.to_string_lossy(), &["--version"], root)?;
    say(
        "code-server",
        &format!("version: {}", version.lines().next().unwrap_or_default()),
    );

    say(
        "code-server",
        &format!("spawn → listening, {runs} runs (throwaway HOME each):"),
    );
    let scratch = std::env::temp_dir();
    for index in 1..=runs {
        let fixture_home = scratch.join(format!("sd-cs-measure.{}.{index}", std::process::id()));
        let elapsed = measure_once(&binary, &fixture_home)?;
        say(
            "code-server",
            &format!("  run {index}: {:.2}s", elapsed.as_secs_f64()),
        );
    }
    report_live_child(root);
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    /// A directory is not a binary, and neither is a file without an execute bit.
    #[test]
    fn only_an_executable_file_counts_as_the_binary() {
        let root = std::env::temp_dir().join(format!("slopdesk-ops-exec-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("the scratch directory is creatable");
        let plain = root.join("plain");
        std::fs::write(&plain, "not a program").expect("the file is writable");

        assert!(!super::is_executable(&root), "a directory is not an executable");
        assert!(
            !super::is_executable(&plain),
            "a mode-644 file is not an executable"
        );
        assert!(
            super::is_executable(std::path::Path::new("/bin/sh")),
            "/bin/sh is"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// An explicit override wins over the vendored prefix and over `PATH`, unexamined.
    ///
    /// Unexamined on purpose: the host does not stat it either, so a typo'd override has to fail
    /// as a spawn error naming the path, not as "no code-server binary (run 'make provision')".
    #[test]
    fn an_override_wins_and_is_taken_as_written() {
        let root = PathBuf::from("/nonexistent-repo-root");
        let wanted = PathBuf::from("/opt/somewhere/code-server");
        assert_eq!(
            super::resolve(&root, Some(&wanted)).expect("the override resolves"),
            wanted
        );
    }

    /// An EMPTY override is `SLOPDESK_CODE_SERVER_BIN=` — set but unset, so resolution continues.
    #[test]
    fn an_empty_override_falls_through_rather_than_resolving_to_nothing() {
        let root = PathBuf::from("/nonexistent-repo-root");
        let resolved = super::resolve(&root, Some(std::path::Path::new("")));
        assert!(
            !matches!(&resolved, Ok(path) if path.as_os_str().is_empty()),
            "an empty override never becomes the answer, got {resolved:?}"
        );
    }
}
