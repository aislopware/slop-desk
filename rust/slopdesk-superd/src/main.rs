//! `slopdesk-superd` — the custodian of every long-lived child process.
//!
//! Runs as a launchd agent (`com.slopdesk.superd`), started at login and kept alive. hostd
//! connects to it, borrows PTY masters, and may die and be rebuilt without the shells noticing.
//! See the crate documentation in `lib.rs` for the rule that produced this boundary, and
//! `docs/51-process-supervision.md` for the full design.
//!
//! ## Boot order matters
//! 1. Ignore `SIGPIPE`. A hostd that dies mid-reply would otherwise **kill superd**, and killing
//!    superd is losing every pane. This is the first thing that happens, before any socket exists.
//! 2. Take the single-instance `flock`. A second superd must lose here, not later at `bind` —
//!    `bind` unlinks the incumbent's socket first, which would strand the panes it holds.
//! 3. Bind the child-facing sockets, then the control socket, then serve. The child-facing binds
//!    come first because whether each succeeded is an input to the server: a socket superd could
//!    not bind is one no hostd may claim, and one no hostd claims is never advertised to a child.
//!
//! ## What a `SIGTERM` costs
//! Everything. Exiting closes superd's master fds, each of which is the last reference, so every
//! pane gets `SIGHUP`. That is correct at logout, which is when launchd sends one. It is also the
//! honest limit of this design: superd's own death still takes the panes, and the only mitigation
//! is that superd is small enough to rarely need changing (`docs/51` §4).

// stderr IS superd's log, and the entry point is where the announce line and every startup failure
// are written — the whole reason hostd can read this daemon at all. See the crate's manifest, which
// denies the lint so this stays one of a named few files rather than a blanket.
#![expect(
    clippy::print_stderr,
    reason = "stderr is superd's log; the entry point announces on it"
)]

use std::io;
use std::os::fd::AsFd as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::process::ExitCode;

use nix::fcntl::{Flock, FlockArg};
use slopdesk_superd::listeners::ChildListeners;
use slopdesk_superd::paths::{self, Paths};
use slopdesk_superd::protocol::{VERSION_MAJOR, VERSION_MINOR};
use slopdesk_superd::server::Server;

fn main() -> ExitCode {
    if std::env::args().any(|argument| argument == "--version") {
        return print_version();
    }

    slopdesk_posix::signal::ignore_sigpipe();

    let resolved = Paths::from_process_env();
    let Some(lock) = SingleInstanceLock::take(&resolved.lock) else {
        eprintln!(
            "superd: another instance already holds {} — exiting rather than stealing its socket",
            resolved.lock.display()
        );
        // Not a failure: launchd's `KeepAlive` would restart a job that exited non-zero, and the
        // incumbent is doing its job perfectly well.
        return ExitCode::SUCCESS;
    };

    // The child-facing sockets first, because their outcome is what the server is built with: a
    // kind whose bind failed can never be claimed, and a kind nobody claims is never advertised
    // into a child's environment. A failure here is logged and survived — superd holds live panes
    // and refusing to start over a hook socket would cost every one of them.
    let children = ChildListeners::bind(&resolved);
    let server = Server::new(resolved, children.claims());
    let listener = match server.bind() {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("superd: could not bind the control socket: {error}");
            return ExitCode::FAILURE;
        },
    };
    server.serve_children(children);
    let outcome = server.serve(&listener);
    drop(lock);
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("superd: accept loop failed: {error}");
            ExitCode::FAILURE
        },
    }
}

/// `--version`, on stdout because that is where a version belongs — the rest of this daemon's
/// output is a log and goes to stderr, which launchd captures.
#[expect(clippy::print_stdout, reason = "a --version banner is stdout by convention")]
fn print_version() -> ExitCode {
    println!(
        "slopdesk-superd {} ({}, protocol {VERSION_MAJOR}.{VERSION_MINOR})",
        env!("CARGO_PKG_VERSION"),
        paths::LAUNCH_AGENT_LABEL,
    );
    ExitCode::SUCCESS
}

/// An exclusive `flock` on a lock file, held for the process's life.
///
/// This is what makes "one superd per user" true. Name-based exclusion would not: [`Server::bind`]
/// unlinks a stale socket before binding, so without this lock a second instance would happily
/// take the address away from a live incumbent — and the incumbent is the process holding every
/// pane's master fd. Those panes would survive but become permanently unreachable, which is worse
/// than either alternative.
#[derive(Debug)]
struct SingleInstanceLock {
    /// Held, never read. The lock is released when this is dropped, which is process exit.
    _flock: Flock<std::fs::File>,
}

impl SingleInstanceLock {
    /// Returns `None` when another process already holds the lock.
    fn take(path: &std::path::Path) -> Option<Self> {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .mode(0o600)
            .open(path)
            .ok()?;
        // Non-blocking: losing the race must be an immediate, legible exit, not a daemon that
        // hangs at boot waiting for a lock it will never get.
        let flock = Flock::lock(file, FlockArg::LockExclusiveNonblock).ok()?;
        // Record the pid so an operator staring at a stale lock file can see who holds it.
        let _ignored = write_pid(&flock);
        Some(Self { _flock: flock })
    }
}

/// Overwrites the lock file with this process's pid. Best-effort: a failure here costs a diagnostic
/// and nothing else, so it must not fail the boot.
fn write_pid(file: &std::fs::File) -> io::Result<()> {
    let fd = file.as_fd();
    nix::unistd::ftruncate(fd, 0).map_err(io::Error::from)?;
    let line = format!("{}\n", std::process::id());
    nix::unistd::write(fd, line.as_bytes()).map_err(io::Error::from)?;
    Ok(())
}
