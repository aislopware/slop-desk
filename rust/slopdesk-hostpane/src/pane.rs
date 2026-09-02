//! One pane's child process, as hostd holds it.
//!
//! ## hostd does not fork. It adopts.
//! No code in this repository forks a pane except `slopdesk-superd`, which stays the child's parent
//! for the pane's whole life (`docs/51`). hostd asks for a shell over an `AF_UNIX` socket and
//! receives a **duplicate** of the PTY master through `SCM_RIGHTS`.
//!
//! That one indirection is the entire point of the design. The last close of a PTY master sends
//! `SIGHUP` to the foreground process group, so whoever holds the only copy holds the shell's life
//! in their hands. When that was hostd, restarting hostd killed every running agent. Now superd
//! keeps a copy, hostd's copy dies with hostd, and the shell never notices — a hostd rebuild costs
//! a reconnect, not a session (`DECISIONS.md` 2026-08-11).
//!
//! So there is no fork window here and no pre-`execve` discipline to keep. That contract lives
//! once, in `rust/slopdesk-posix/src/pty.rs`, with its own disassembly pin.
//!
//! ## What is still hostd's
//! Everything downstream of holding an fd: `write` (keystrokes), `TIOCSWINSZ` (resizes),
//! `TIOCGWINSZ` and `tcgetpgrp` (the zero-config half of agent detection). Never `read` — superd
//! owns that on every master, and a second reader steals bytes rather than observing them.
//!
//! Signals and the final close route through superd instead. Not because hostd *cannot* `kill(2)` a
//! non-child — it can — but so superd's record of the pane stays true, and so "hostd went away" and
//! "the user closed the pane" never look the same.
//!
//! ## One contract for the layer above
//! [`PtyProcess::hangup`], [`PtyProcess::terminate`], [`PtyProcess::force_terminate`] and
//! [`PtyProcess::release`] park for superd's reply, and that reply can only arrive on the
//! supervisor client's reader thread. **None of them may be called from inside a
//! [`crate::PaneChunkSink`]**, which runs on that thread: doing so waits for a message only the
//! waiting thread could deliver. A session that tears down on EOF must hand the teardown to another
//! thread first. Everything else here — the ioctls, the nudge, the resize notice, the exit peeks —
//! is safe from anywhere.

// `significant_drop_tightening` wants every mutex guard released as early as the borrows allow, and
// in THIS module holding one longer is the entire discipline. A pane's descriptor and its identity
// live under one lock precisely so nothing can land between reading the fd and using it:
// `close_master` takes the descriptor, the kernel is then free to hand that number to the next
// `open`, and a `TIOCSWINSZ` issued against a number read a moment earlier would resize an
// unrelated file. Every guard the lint points at is held across a syscall on purpose, and those
// syscalls are microsecond, non-blocking, and never re-enter this type. The opt-out is on the
// module that earns it rather than in the manifest, so it cannot cover a file nobody has written.
#![expect(
    clippy::significant_drop_tightening,
    reason = "a guard held across the syscall is the TOCTOU discipline, not an oversight"
)]

use std::os::fd::{AsRawFd as _, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::Duration;

use nix::errno::Errno;
use nix::sys::signal::{Signal, kill, killpg};
use nix::unistd::Pid;
use slopdesk_superclient::client::{ClientError, SupervisorClient};
use slopdesk_superwire::blockwire::BlockMeta;
use slopdesk_superwire::protocol::{BlocksReply, PaneRecord, SpawnRequest};

use crate::cwd::resolve_cwd;
use crate::stream::{PaneChunkSink, PaneOutputStream};

/// A terminal's window size, character cells and pixels.
///
/// The pixel fields are not decoration: the size fold compares its resolved grid against the LIVE
/// winsize to decide whether an apply is needed, and comparing only rows and columns would silently
/// swallow a DPI change that never reaches the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct WindowSize {
    /// Rows, in character cells.
    pub rows: u16,
    /// Columns, in character cells.
    pub cols: u16,
    /// Width in pixels, or `0` when the client has not reported cell metrics.
    pub px_width: u16,
    /// Height in pixels.
    pub px_height: u16,
}

impl From<libc::winsize> for WindowSize {
    fn from(size: libc::winsize) -> Self {
        Self {
            rows: size.ws_row,
            cols: size.ws_col,
            px_width: size.ws_xpixel,
            px_height: size.ws_ypixel,
        }
    }
}

impl From<WindowSize> for libc::winsize {
    fn from(size: WindowSize) -> Self {
        Self {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: size.px_width,
            ws_ypixel: size.px_height,
        }
    }
}

/// The token [`PtyProcess::begin_redraw_jiggle`] hands to [`PtyProcess::end_redraw_jiggle`].
///
/// It carries the pre-jiggle size to restore AND the shrunk size, so the restore can detect an
/// intervening client resize and yield to it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RedrawJiggle {
    original: WindowSize,
    jiggled: WindowSize,
}

/// Everything a pane's identity is, once superd has answered.
#[derive(Debug, Clone)]
struct Identity {
    pane_id: String,
    /// Valid to `kill`, never to `waitpid` — this process is not the child's parent.
    pid: i32,
    /// When superd forked this pane, in unix seconds: the identity of the pane LIFE as opposed to
    /// of the session. Stamped onto the journal's resume sidecar, because an offset into a pane's
    /// output stream is only meaningful for the fork that produced it.
    spawned_at: i64,
}

/// The descriptor and the identity, under one lock.
///
/// One lock rather than two because every use reads both: an ioctl needs the fd AND has to be sure
/// the pane it belongs to has not been closed and its number recycled underneath it. In Swift that
/// was a discipline a comment asked for; here the borrow checker enforces it, because the fd cannot
/// be named outside the guard.
#[derive(Debug, Default)]
struct Held {
    master: Option<OwnedFd>,
    identity: Option<Identity>,
}

/// One-shot exit plumbing, shared with the handler superd's notice lands in.
///
/// Deliberately separate from [`PtyProcess`] and holding no reference back to it: the handler is
/// stored in the supervisor client, so a closure capturing the pane would be a reference cycle
/// through the client for as long as the pane went unreleased.
#[derive(Debug, Default)]
struct ExitState {
    code: Mutex<Option<i32>>,
    reaped: Condvar,
}

impl ExitState {
    /// Records an exit code exactly as an `exited` notification would. The first call wins; every
    /// later one is ignored, because an end declared twice is a session torn down twice.
    fn complete(&self, code: i32) {
        let mut held = self.code.lock().unwrap_or_else(PoisonError::into_inner);
        if held.is_none() {
            *held = Some(code);
            self.reaped.notify_all();
        }
    }

    fn peek(&self) -> Option<i32> {
        *self.code.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn wait(&self) -> i32 {
        let mut held = self.code.lock().unwrap_or_else(PoisonError::into_inner);
        while held.is_none() {
            held = self.reaped.wait(held).unwrap_or_else(PoisonError::into_inner);
        }
        held.unwrap_or_default()
    }

    fn wait_timeout(&self, timeout: Duration) -> bool {
        let held = self.code.lock().unwrap_or_else(PoisonError::into_inner);
        let (held, _timed_out) = self
            .reaped
            .wait_timeout_while(held, timeout, |code| code.is_none())
            .unwrap_or_else(PoisonError::into_inner);
        held.is_some()
    }
}

/// A child process attached to a pseudo-terminal, held by the hostd that did not fork it.
#[derive(Debug)]
pub struct PtyProcess {
    /// The supervisor this pane belongs to. Held for the pane's whole life: signals, resizes and
    /// the final release all go through it.
    client: Arc<SupervisorClient>,
    held: Mutex<Held>,
    exit: Arc<ExitState>,
    took_over_a_survivor: AtomicBool,
}

impl PtyProcess {
    /// A pane with no child yet. [`PtyProcess::spawn`] or [`PtyProcess::adopt`] gives it one.
    #[must_use]
    pub fn new(client: Arc<SupervisorClient>) -> Self {
        Self {
            client,
            held: Mutex::new(Held::default()),
            exit: Arc::new(ExitState::default()),
            took_over_a_survivor: AtomicBool::new(false),
        }
    }

    // MARK: Spawn

    /// Asks superd for a shell on a fresh PTY and adopts the master it sends back.
    ///
    /// `request.cwd` is REWRITTEN before the request goes out — see [`resolve_cwd`]. Every other
    /// field crosses verbatim, including `blocks`, whose command list superd owns both the parse
    /// and the built-in half of: resolving it here would put a second copy of that list back.
    ///
    /// # Errors
    /// superd's refusal, when the surviving-pane takeover below does not apply.
    ///
    /// # Panics
    /// Never in practice — the `expect` is on an identity this function just installed.
    pub fn spawn(&self, mut request: SpawnRequest) -> Result<(), ClientError> {
        // Validate the requested cwd HOST-SIDE, before the request goes out: the child's `chdir`
        // runs pre-`execve` and is best-effort, so a stale, deleted or `~`-style path would
        // silently leave the pane in superd's directory rather than the user's. Repairing
        // it here is policy, and policy is hostd's — superd is told a directory, not asked
        // to choose one.
        request.cwd = resolve_cwd(
            request.cwd.as_deref(),
            request.environment.get("HOME").map(String::as_str),
        );
        let pane_id = request.pane_id.clone();

        // Registered BEFORE the request: a child that dies instantly (a bad executable, an `exit
        // 1`) can be reaped and broadcast while this thread is still inside `spawn`, and a
        // dropped `exited` leaves a dead pane looking alive until someone types into it.
        self.observe_exit(&pane_id);

        match self.client.spawn(request) {
            Ok((record, master)) => {
                self.install(master, &record);
                Ok(())
            },
            Err(error) => {
                // superd refuses a duplicate pane id, and it is right to: two forks under one id
                // would orphan the first child. But a duplicate here does not mean a mistake — it
                // means the pane this id names is STILL RUNNING, left behind by a hostd that
                // relinquished it and never adopted it back. Refusing would hand the user a dead
                // tab per surviving shell, permanently, and the only cure would be
                // killing superd, which is killing their agents.
                //
                // So the surviving pane is taken over instead. Not blindly: a pane another live
                // hostd is ATTACHED to is that daemon's, and this reports the original refusal
                // rather than stealing it.
                if let Some((record, master)) = self.take_over_survivor(&pane_id) {
                    self.install(master, &record);
                    // Said out loud, because the caller's next decision depends on it: what came
                    // back is a shell with a HISTORY, not the fresh fork it asked for, and its
                    // output stream must not be subscribed from offset 0 on top of a restored
                    // transcript.
                    self.took_over_a_survivor.store(true, Ordering::Release);
                    return Ok(());
                }
                self.client.forget_exit_handler(&pane_id);
                Err(error)
            },
        }
    }

    /// Takes over the unattached pane already filed under `pane_id`, or answers `None`.
    ///
    /// The `attached` check is what keeps this from being a second daemon's pane theft: it means
    /// some hostd holds a duplicate of that master right now, which after the rekey to a bare
    /// session UUID is the only way to tell one daemon's panes from another's.
    fn take_over_survivor(&self, pane_id: &str) -> Option<(PaneRecord, OwnedFd)> {
        let records = self.client.list().ok()?;
        let existing = records.iter().find(|record| record.pane_id == pane_id)?;
        if existing.attached {
            return None;
        }
        self.client.adopt(pane_id).ok()
    }

    /// Takes ownership of a master fd superd handed over, and of the child on the other end of it.
    ///
    /// Two callers: [`PtyProcess::spawn`], and the restart path — a fresh hostd that adopts a pane
    /// an earlier hostd left running. The second is why this is separate: from here down, a pane
    /// spawned an hour ago by a binary that no longer exists is indistinguishable from one spawned
    /// a moment ago.
    ///
    /// # Errors
    /// superd's refusal, or a reply with no master descriptor in it.
    pub fn adopt(&self, pane_id: &str) -> Result<(), ClientError> {
        let (record, master) = self.client.adopt(pane_id)?;
        self.install(master, &record);
        Ok(())
    }

    /// Records the descriptor and identity superd answered with, and wires the exit route.
    ///
    /// The Swift trapped on a second install. This replaces instead, which is where the languages
    /// genuinely differ rather than a rule being relaxed: a `PtyProcess` is one pane by
    /// construction — `spawn` and `adopt` are the only callers and neither runs twice on a live
    /// object — and if one somehow did, the previous `OwnedFd` closes as it is replaced. Trapping
    /// would take a whole daemon down over a bug that leaks nothing.
    fn install(&self, master: OwnedFd, record: &PaneRecord) {
        {
            let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
            held.master = Some(master);
            held.identity = Some(Identity {
                pane_id: record.pane_id.clone(),
                pid: record.pid,
                spawned_at: record.spawned_at,
            });
        }
        // Wired here rather than only in `spawn`: an adopted pane's child can die like any other,
        // and a pane that never hears about it reports a corpse as running for ever. `spawn`
        // registers this itself, EARLIER — before the request, so an instantly dying child cannot
        // be reaped before anyone is listening — and re-registering here replaces that
        // closure with an identical one.
        self.observe_exit(&record.pane_id);
    }

    /// Installs the exit handler. It captures the exit state alone, never the pane: the client
    /// holds this closure, so capturing the pane would keep the pane alive through the client.
    fn observe_exit(&self, pane_id: &str) {
        let exit = Arc::clone(&self.exit);
        self.client
            .observe_exit(pane_id, Arc::new(move |code| exit.complete(code)));
    }

    /// Whether [`PtyProcess::spawn`] ended up TAKING OVER an existing pane instead of forking one.
    ///
    /// The caller has to know, because a pane with a history needs a resume offset, not the `0`
    /// that is right for a fresh fork.
    #[must_use]
    pub fn took_over_a_survivor(&self) -> bool {
        self.took_over_a_survivor.load(Ordering::Acquire)
    }

    /// The pane identity superd files this child under, or `None` before spawn or adopt.
    #[must_use]
    pub fn pane_id(&self) -> Option<String> {
        self.identity().map(|identity| identity.pane_id)
    }

    /// The child's pid. Valid to signal, never to `waitpid`.
    #[must_use]
    pub fn pid(&self) -> Option<i32> {
        self.identity().map(|identity| identity.pid)
    }

    /// The master's descriptor NUMBER, for a probe that must run without this type's lock.
    ///
    /// The one door that lets the number out, and it exists for exactly one caller: the metadata
    /// RPC, whose read verbs resolve the pane's foreground group from the master and whose work
    /// then blocks on `git`/`lsof` for as long as those take. Holding the pane's lock across that
    /// would stall every resize and keystroke behind a repository walk, so the number is
    /// snapshotted instead — and a snapshot is a promise about an instant, not about the future.
    ///
    /// **Every other probe must use the methods above**, which do their syscall inside the hold.
    /// The window here is real: a caller that races [`PtyProcess::release`] can probe a number the
    /// kernel has already given to the next `openpty`. It is accepted only because the alternative
    /// is worse for the pane, and it closes when the metadata builder itself is Rust and can take
    /// the hold for the microsecond `tcgetpgrp` without taking it for the fork behind it.
    #[must_use]
    pub fn master_fd_snapshot(&self) -> Option<i32> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        // Spelled through the qualified path rather than a closure: the file imports the trait
        // anonymously (`AsRawFd as _`), so the bare method name has no type to hang off here.
        held.master.as_ref().map(std::os::fd::AsRawFd::as_raw_fd)
    }

    /// When superd forked this pane, in unix seconds. `0` for a pane that was never spawned or
    /// adopted, and for a superd too old to report it.
    #[must_use]
    pub fn spawned_at(&self) -> i64 {
        self.identity().map_or(0, |identity| identity.spawned_at)
    }

    fn identity(&self) -> Option<Identity> {
        self.held
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .identity
            .clone()
    }

    /// Builds this pane's output stream.
    ///
    /// Here rather than at the call site because the pane id and the supervisor client are both
    /// private to this type, and because there is exactly one correct pairing of them: a stream
    /// built against the wrong pane id subscribes successfully and delivers another window's bytes.
    #[must_use]
    pub fn make_output_stream(&self, from_offset: u64, sink: Arc<dyn PaneChunkSink>) -> PaneOutputStream {
        PaneOutputStream::new(Arc::clone(&self.client), self.pane_id(), from_offset, sink)
    }

    // MARK: The descriptor

    /// Writes keystrokes to the child, whole.
    ///
    /// The one direction that never leaves this process: input goes straight down hostd's own
    /// duplicate of the master, with no hop through superd. That was a named reason the full-relay
    /// design was rejected (`DECISIONS.md` 2026-08-11) and it survives intact.
    ///
    /// Partial writes are retried and `EINTR` is resumed. `O_NONBLOCK` is deliberately never set:
    /// the file DESCRIPTION is shared with superd's original by `SCM_RIGHTS`, so a flag set here
    /// would change how superd's pump reads.
    ///
    /// # Errors
    /// [`Errno::EBADF`] for a pane with no master, or the `write(2)` errno. `EPIPE` means the child
    /// is gone.
    pub fn write(&self, bytes: &[u8]) -> Result<(), Errno> {
        if bytes.is_empty() {
            return Ok(());
        }
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let master = held.master.as_ref().ok_or(Errno::EBADF)?;
        let mut written = 0;
        while let Some(rest) = bytes.get(written..).filter(|rest| !rest.is_empty()) {
            match nix::unistd::write(master, rest) {
                Ok(0) => return Err(Errno::EIO),
                Ok(count) => written += count,
                Err(Errno::EINTR) => (),
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    /// The PTY's current window size, pixel fields included, or `None` on a closed or unspawned
    /// master.
    #[must_use]
    pub fn window_size(&self) -> Option<WindowSize> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        Self::read_size(&held)
    }

    /// The `TIOCGWINSZ` under an already-taken guard, so the callers that read-then-write do both
    /// inside one hold.
    fn read_size(held: &Held) -> Option<WindowSize> {
        let master = held.master.as_ref()?;
        slopdesk_posix::pty::window_size(master.as_raw_fd())
            .ok()
            .map(WindowSize::from)
    }

    /// Applies a terminal size via `TIOCSWINSZ`. The kernel then delivers `SIGWINCH` to the child's
    /// foreground process group.
    ///
    /// This ioctl is the ONLY write to the terminal — one writer, hostd's own duplicate, as
    /// `docs/51` §6.9 requires. superd's `resize` verb RECORDS the numbers and touches no
    /// `TIOCSWINSZ`, which is what makes the notification that follows safe to fire and forget: it
    /// can land after the redraw jiggle's shrink without undoing it. What it buys is the record —
    /// superd's spawn-time size is what `list` reports, and a stale one there is a lie about the
    /// pane in every log and every enumeration.
    pub fn set_window_size(&self, size: WindowSize) {
        let identity = {
            let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(master) = held.master.as_ref() else {
                return;
            };
            let _ignored = slopdesk_posix::pty::set_window_size(master.as_raw_fd(), size.into());
            held.identity.clone()
        };
        // Tell superd too, so its record stops being a lie. Un-awaited, and outside the lock: the
        // verb takes the socket, and nothing about a pane's descriptor should wait on one.
        if let Some(identity) = identity {
            self.client.resize(&identity.pane_id, size.rows, size.cols);
        }
    }

    // MARK: The probes over the descriptor

    // Four reads a pane's DETECTION needs, and they are methods here for one reason: the master is
    // an `OwnedFd` behind this type's lock, and every caller that took the number out to probe it
    // itself would be racing `close_master` for a descriptor the kernel is free to hand to the next
    // `openpty`. So the fd never leaves the hold; what crosses is the answer.
    //
    // Each body is one call into `slopdesk-posix`, which owns the syscall and the rule behind it —
    // `echo_enabled` in particular is NOT "is the `ECHO` bit clear", and that reasoning stays where
    // the termios read is rather than being re-derived per caller.

    /// Whether the line discipline would echo what a client types.
    ///
    /// `false` for a closed or unspawned master, which reads the same way an ordinary no-echo
    /// prompt does — and is the safe direction: a client told the host is hiding input protects
    /// the keystrokes it has not sent yet.
    #[must_use]
    pub fn echo_enabled(&self) -> bool {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        held.master
            .as_ref()
            .is_some_and(|master| slopdesk_posix::pty::echo_enabled(master.as_raw_fd()))
    }

    /// The PTY's foreground process group, or `None` when it has none.
    ///
    /// Having none is the ORDINARY state between one child exiting and the next starting, not a
    /// failure — which is why it is an `Option` rather than an error.
    #[must_use]
    pub fn foreground_group(&self) -> Option<i32> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let master = held.master.as_ref()?;
        slopdesk_posix::pty::foreground_process_group(master.as_raw_fd())
            .ok()
            .filter(|group| *group > 0)
    }

    /// The foreground group leader's executable path — the CHEAP presence probe.
    #[must_use]
    pub fn foreground_executable(&self) -> Option<String> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let master = held.master.as_ref()?;
        slopdesk_posix::proc::foreground_executable(master.as_raw_fd())
    }

    /// The whole foreground job: the group id, and every member with its `comm` and its argv.
    ///
    /// The DEEP probe, and it enumerates a process group — so a caller reaches for it exactly when
    /// [`Self::foreground_executable`] answered a generic runtime or shell, never per tick.
    #[must_use]
    pub fn foreground_job(&self) -> Option<(i32, Vec<slopdesk_posix::proc::ProcessSnapshot>)> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let master = held.master.as_ref()?;
        slopdesk_posix::proc::foreground_job(master.as_raw_fd())
    }

    // MARK: The redraw jiggle

    /// Full-repaint resize dance, step 1: shrink the PTY by one ROW — one COLUMN for a single-row
    /// PTY — preserving the pixel fields.
    ///
    /// Why a real size change and not [`PtyProcess::nudge_redraw`]: differential renderers keep an
    /// in-memory model of the screen and, on a `SIGWINCH` whose size is unchanged, repaint only the
    /// rows they believe changed. After a cold-reattach replay — whose transcript is
    /// transform-collapsed, so the live alt-screen frame arrives incomplete — that leaves the
    /// collapsed rows permanently blank. Shrinking by one row is a REAL size change: the kernel
    /// delivers `SIGWINCH` and the app must re-layout the whole frame.
    ///
    /// The caller holds the shrunk size briefly, so the app's event loop observes it — two
    /// back-to-back ioctls coalesce into "size unchanged" — then calls
    /// [`PtyProcess::end_redraw_jiggle`] for the second full re-layout at the true size.
    ///
    /// `None` on a closed or unspawned master, or a degenerate 1×1 PTY; callers fall back to a
    /// plain nudge.
    #[must_use]
    pub fn begin_redraw_jiggle(&self) -> Option<RedrawJiggle> {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let master = held.master.as_ref()?;
        let original = Self::read_size(&held)?;
        let mut jiggled = original;
        if jiggled.rows > 1 {
            jiggled.rows -= 1;
        } else if jiggled.cols > 1 {
            jiggled.cols -= 1;
        } else {
            return None;
        }
        let _ignored = slopdesk_posix::pty::set_window_size(master.as_raw_fd(), jiggled.into());
        Some(RedrawJiggle { original, jiggled })
    }

    /// Step 2: restore the pre-jiggle size — a second real size change, so a second full re-layout,
    /// now at the size the client renders.
    ///
    /// Yields to an intervening resize: if the CURRENT size no longer matches the shrunk one, a
    /// client resize landed during the hold, its own `SIGWINCH` already forced the full repaint at
    /// the size the client actually wants, and restoring the stale pre-jiggle size would stomp it.
    /// A safe no-op on a closed master.
    pub fn end_redraw_jiggle(&self, jiggle: RedrawJiggle) {
        let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(master) = held.master.as_ref() else {
            return;
        };
        if Self::read_size(&held) != Some(jiggle.jiggled) {
            return;
        }
        let _ignored = slopdesk_posix::pty::set_window_size(master.as_raw_fd(), jiggle.original.into());
    }

    /// Delivers `SIGWINCH` to the PTY's foreground process group so shells and full-screen apps
    /// repaint immediately after a client reattach.
    ///
    /// On reattach the client terminal is fresh and holds no buffered output, so the pane is blank
    /// until a keypress makes the shell redraw its prompt. `SIGWINCH` is the safe repaint signal:
    /// it asks the foreground process to re-query its size and redraw, and it cannot corrupt a
    /// running app.
    ///
    /// `tcgetpgrp` rather than the child's own group, because it honours job control — the shell
    /// may have suspended itself with a `vim` in the foreground. A group of zero means the
    /// terminal is quiescent or already closed, and the child is nudged directly instead.
    ///
    /// Reattach path only. A redundant `SIGWINCH` on a fresh shell is harmless but noisy for apps
    /// that re-clear the screen.
    pub fn nudge_redraw(&self) {
        let (group, child) = {
            let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(master) = held.master.as_ref() else {
                return;
            };
            let Some(identity) = held.identity.as_ref() else {
                return;
            };
            (
                slopdesk_posix::pty::foreground_process_group(master.as_raw_fd()).unwrap_or(0),
                identity.pid,
            )
        };
        if group > 0 {
            let _ignored = killpg(Pid::from_raw(group), Signal::SIGWINCH);
        } else if child > 0 {
            let _ignored = kill(Pid::from_raw(child), Signal::SIGWINCH);
        }
    }

    // MARK: superd's bookkeeping

    /// Retires superd's sniffer title-coalescing anchor for this pane.
    ///
    /// Called when a detected agent EXITS. superd dedupes a title against the last one it emitted,
    /// and the next agent's opening title is very often byte-identical to the one just retired —
    /// deduped away, the pane simply stays untitled. Fire and forget: the anchor is an
    /// optimisation, so losing the race costs a stale title, not a wrong one.
    pub fn forget_title_coalescing(&self) {
        if let Some(identity) = self.identity() {
            self.client.forget_title_coalescing(&identity.pane_id);
        }
    }

    /// One finished command block's retained output, from superd's ring.
    ///
    /// The ring lives there rather than here because hostd's did not survive its own restart: a
    /// client that clicked a block from before a restart got an empty body for output superd had
    /// never stopped holding (`docs/51` §6.14).
    ///
    /// `None` for a pane with no identity or no tap. An EMPTY vector is the other answer and a
    /// different one: the block aged out of the ring, or never existed.
    #[must_use]
    pub fn block_output(&self, index: u32) -> Option<Vec<u8>> {
        let identity = self.identity()?;
        self.client.block_output(&identity.pane_id, index).ok()?
    }

    /// Every block superd's tap still knows about this pane, ascending — the reattach backfill.
    #[must_use]
    pub fn block_snapshot(&self) -> Option<Vec<BlockMeta>> {
        let identity = self.identity()?;
        self.client.block_snapshot(&identity.pane_id).ok()?
    }

    /// The agent-control read: recent blocks with their bytes, the running command, and the index
    /// the next one will close under — one round trip, because the three are only consistent with
    /// each other if superd read them together.
    #[must_use]
    pub fn block_control(&self, limit: usize) -> Option<BlocksReply> {
        let identity = self.identity()?;
        self.client.block_control(&identity.pane_id, limit).ok()?
    }

    // MARK: Lifecycle

    /// Sends `SIGHUP` — the "terminal closed" signal a real emulator delivers when its window goes
    /// away.
    ///
    /// An interactive shell treats it as a deliberate end of session: zsh persists its in-memory
    /// command history to `$HISTFILE` before exiting. It IGNORES `SIGTERM`, and `SIGKILL` discards
    /// everything typed since launch, so the destroy-path ladder leads with this one — without it,
    /// every pane close and every daemon stop silently throws away the user's typed history.
    pub fn hangup(&self) {
        self.send(Signal::SIGHUP);
    }

    /// Sends `SIGTERM`. The child is a session leader, so this reaches the group through the
    /// controlling tty's hangup machinery once the master closes too.
    pub fn terminate(&self) {
        self.send(Signal::SIGTERM);
    }

    /// Sends `SIGKILL` — the un-ignorable escalation when a `SIGTERM` did not take.
    ///
    /// It is what GUARANTEES superd's parked read on the master returns, so a later
    /// [`PtyProcess::close_master`] cannot block. A no-op once the child is reaped: the kernel
    /// drops a signal to a dead-and-reaped pid.
    pub fn force_terminate(&self) {
        self.send(Signal::SIGKILL);
    }

    /// Asks superd to signal the child.
    ///
    /// hostd could `kill(2)` it directly — a same-uid process may signal a non-child — and that is
    /// exactly why this goes the long way instead. superd is the only holder of the pane's true
    /// state, and a shell that dies from a signal superd never saw is a pane superd still believes
    /// is alive: it keeps the master fd open and the record in its table until the reaper catches
    /// up. Routing through the socket keeps the two in step, and costs one `AF_UNIX` round trip on
    /// a path that only runs at teardown.
    ///
    /// Best effort by design: the child may already be gone, or superd may have restarted. Neither
    /// is worth failing a teardown over — the ladder above escalates anyway.
    fn send(&self, signal: Signal) {
        let Some(identity) = self.identity() else {
            return;
        };
        if identity.pid > 0 {
            // Nothing to escalate to: this IS the escalation path.
            let _ignored = self.client.signal(&identity.pane_id, signal as i32);
        }
    }

    /// The child's exit code, blocking until superd reports one. Every waiter wakes with the same
    /// code.
    #[must_use]
    pub fn wait_for_exit(&self) -> i32 {
        self.exit.wait()
    }

    /// Waits, bounded, for the child to be reaped.
    ///
    /// The destroy path needs a wait that does not wedge a shell mid-redraw, and this is it: a
    /// condvar, woken by the `exited` notice itself, rather than the poll loop the Swift used.
    ///
    /// It does NOT `waitpid` and it does not drain the master. It cannot do the first — this
    /// process is not the parent — and it must not do the second: superd's pump drains every
    /// pane for the pane's whole life whether or not hostd is subscribed, so a private drain
    /// here would be a SECOND reader on a description superd is reading, stealing bytes it owed
    /// to whoever else was still subscribed.
    ///
    /// Returns whether the exit was observed inside the window. `false` is the caller's cue to
    /// escalate.
    #[must_use]
    pub fn wait_until_exited(&self, timeout: Duration) -> bool {
        self.exit.wait_timeout(timeout)
    }

    /// A non-blocking peek at the exit code, or `None` while the child is still running.
    #[must_use]
    pub fn exit_code(&self) -> Option<i32> {
        self.exit.peek()
    }

    /// Declares the child gone because the CUSTODIAN is gone.
    ///
    /// hostd cannot `waitpid` a pane it did not fork, so every exit it learns about arrives as
    /// superd's notice. When superd itself has restarted, the shells it held died with it — it was
    /// the last holder of every master — and no notice is coming from anybody: a session left
    /// waiting for one waits for ever and its tab never closes.
    ///
    /// `128 + SIGHUP`, which is what superd reports for a hung-up child and, for that matter, what
    /// actually happened: the master's last close sent one.
    pub fn complete_exit_from_supervisor_loss(&self) {
        self.exit.complete(128_i32.wrapping_add(Signal::SIGHUP as i32));
    }

    /// Closes hostd's duplicate of the PTY master, exactly once.
    ///
    /// ## This does not hang up the shell
    /// The last close of a PTY master `SIGHUP`s the foreground group, and this used to BE the last
    /// close. It is not any more: superd holds the original, and what is closed here is the
    /// duplicate the kernel installed out of an `SCM_RIGHTS` message. Ending the pane for good is
    /// [`PtyProcess::release`] — a separate, explicit act, and the distinction that lets hostd exit
    /// without taking the shells with it (`docs/51` §2).
    ///
    /// The owner calls this after stopping the output stream. Idempotent, and [`Drop`] catches any
    /// path that forgot.
    pub fn close_master(&self) {
        let taken = self
            .held
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .master
            .take();
        drop(taken);
    }

    /// Ends the pane for good: superd drops its own master fd, and the shell finally gets its
    /// `SIGHUP`.
    ///
    /// The counterpart to [`PtyProcess::close_master`], and the line the whole daemon is drawn
    /// along. Closing hostd's fd means "hostd is done looking at this pane"; this means "this pane
    /// is over". Only a deliberate close — the user closing a tab, an exit already observed — may
    /// call it. **Never on hostd shutdown**: that would restore exactly the behaviour superd exists
    /// to remove, killing every running agent on every rebuild.
    ///
    /// `kill: false` when the child is already known dead and this is bookkeeping.
    ///
    /// Returns whether superd accepted it. `false` means the pane is still out there — superd was
    /// unreachable, and a restarted hostd will find it in `list` and can release it then, which is
    /// why the caller reports this rather than letting a tab the user closed come back adopted
    /// after the next restart.
    pub fn release(&self, kill: bool) -> bool {
        let Some(identity) = self.identity() else {
            return false;
        };
        // Nothing to forget here: `SupervisorClient::release` drops the sink and the exit handler
        // itself, before the verb goes out. That is why `release` is the LAST rung of the teardown
        // ladder rather than a step in the middle — hangup, then the bounded wait, then the kill
        // escalation, and only then this. Anything still parked in `wait_for_exit` when this runs
        // is waiting for a notice that will now be routed nowhere.
        self.client.release(&identity.pane_id, kill).is_ok()
    }
}

impl Drop for PtyProcess {
    /// Two safety nets, and neither of them releases the pane: a pane object being dropped is a
    /// hostd event, not a user one, and the pane must survive it.
    ///
    /// The descriptor goes because `OwnedFd` closes on drop — a leak here cost one fd per pane, and
    /// a long-running daemon hit the 256-fd soft limit after a few hundred sessions. The handler
    /// goes because the client outlives this object and would otherwise hold a closure for a pane
    /// nobody is watching.
    fn drop(&mut self) {
        let identity = self
            .held
            .get_mut()
            .unwrap_or_else(PoisonError::into_inner)
            .identity
            .clone();
        if let Some(identity) = identity {
            self.client.forget_exit_handler(&identity.pane_id);
        }
    }
}
