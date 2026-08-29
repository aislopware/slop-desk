//! The process: a raw-mode guard, two byte pumps, a resize wait, and the loop that ends them.
//!
//! ## What this is NOT a port of
//!
//! `main.swift` was 534 lines and four of its types existed only to hold Swift's concurrency
//! together: `ResizeBridge` turned a `DispatchSource` into an `AsyncStream`, `BoundedInputPipe`
//! (118 lines, its own file) re-created `write(2)`'s backpressure because an `AsyncStream` has
//! none, `ExitState` was a lock around one integer because the exit code was written on one task
//! and read on another, and `Shutdown` existed because `finish()` called `exit(3)` from inside a
//! closure and had to stop two foreign producers before the terminal could be put back.
//!
//! None of the four survives, and none is replaced:
//!
//! - The resize wait IS a thread. `SigSet::wait` blocks until `SIGWINCH` arrives, which is the
//!   whole of what the `DispatchSource` was arranging.
//! - The stdin pump's backpressure IS `send_input` blocking. When the mux credit window closes, the
//!   send parks, the reader stops draining stdin, and the upstream writer stalls in its own
//!   `write(2)` — the POSIX contract the bounded pipe was emulating one layer up.
//! - The exit code is a local of [`run`], because every note reaches [`run`]'s loop and nothing
//!   else reads it.
//! - The terminal is restored by [`RawGuard`]'s `Drop`, so there is no exit path that can skip it:
//!   `main` RETURNS a code rather than calling `exit`, which is why the guard's drop actually runs.
//!
//! ## One writer, and the reason
//!
//! Every observer callback and the stdin thread post a [`Note`]; the loop in [`run`] is the only
//! thing that writes to either descriptor. That is not tidiness — an observer that wrote to stderr
//! itself would need a lock, and holding it across a `write(2)` to a terminal that is flow-stopped
//! by a `^S` would park the driver's forwarder thread on the user's scroll lock.

use std::io::{IsTerminal, Read, Write};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread;
use std::time::Duration;

use nix::sys::signal::{SigSet, Signal};
use slopdesk_clientdriver::driver::{DriverConfig, PaneDriver, ResumeSeed};
use slopdesk_clientdriver::event::{Event, Observer};
use slopdesk_clientnet::registry::DiallingPool;
use slopdesk_posix::pty::window_size;
use slopdesk_posix::signal::ignore_sigpipe;
use slopdesk_posix::{fdio, rawmode};
use slopdesk_wire::WireMessage;

use crate::args::Args;

/// Ctrl-] (GS, 0x1d) — the classic telnet escape. In interactive mode it disconnects cleanly,
/// restores the terminal and exits 0. Named in the usage block.
const DISCONNECT_KEY: u8 = 0x1D;

/// How long a dial and its handshake may take, together. Matches the pool's own connect timeout,
/// because a handshake bound shorter than the dial it waits behind can only ever fire early.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// What the stdin pump reads at a time. Interactive typing never fills it; a pipe does, and a
/// bigger buffer here is one fewer `send_input` per screenful of a `cat`.
const READ_CHUNK: usize = 4096;

/// One thing the loop in [`run`] is told, by an observer callback or by the stdin thread.
#[derive(Debug)]
enum Note {
    /// The driver's output inbox has bytes. Coalesced by the loop, not by the sender: several of
    /// these may be queued and one drain answers them all.
    Output,
    /// A line for stderr, already worded.
    Status(String),
    /// The host's terminal bell, to be forwarded to the local one.
    Bell,
    /// The remote child exited. Terminal for the session.
    Exited(i32),
    /// The retry campaign is over and the pane is unreachable.
    GaveUp,
    /// The stdin pump stopped — EOF on a pipe, or the disconnect key on a terminal.
    StdinDone,
}

/// Posts every observation to [`run`]'s loop and decides nothing.
///
/// The whole of what it filters is what has no surface here: a round-trip reading has no latency
/// badge to land in, and the fifteen GUI-facing message types (`CommandStatus`, `Progress`,
/// `ProjectGitStatus`, …) have no sidebar, no tab and no dock. The Swift spelled each of those as
/// its own `case … : break`; a `_ => ()` says the same thing once, and the driver's own
/// `#[non_exhaustive]` event enum means a type added later is silent here by default rather than a
/// compile error in a binary that could not render it anyway.
#[derive(Debug)]
struct Notes {
    notes: Sender<Note>,
    /// Whether the local terminal is rendering. A title is worth a stderr line only when it is NOT
    /// — in raw mode the host's OSC title rides the output stream and the local terminal sets the
    /// window title itself, so echoing it to stderr only smears the screen.
    interactive: bool,
}

impl Observer for Notes {
    fn event(&self, event: &Event<'_>) {
        let note = match *event {
            Event::Message(&WireMessage::Exit { code }) => Note::Exited(code),
            Event::Message(&WireMessage::Bell) => Note::Bell,
            Event::Message(WireMessage::Title(text)) if !self.interactive => {
                Note::Status(format!("title: {text}"))
            },
            Event::Disconnected { reason } => Note::Status(format!("disconnected: {reason}")),
            Event::Reconnected {
                session_id,
                resume_from_seq,
            } => {
                Note::Status(format!(
                    "reconnected (session {}, resumed from seq {resume_from_seq})",
                    slopdesk_ids::identity::uuid_text(session_id)
                ))
            },
            Event::Retry { attempt, delay_ms } if delay_ms > 0 => {
                Note::Status(format!("retry {attempt} in {delay_ms} ms"))
            },
            Event::GaveUp { attempts } => {
                drop(
                    self.notes
                        .send(Note::Status(format!("gave up after {attempts} attempts"))),
                );
                Note::GaveUp
            },
            Event::Log(line) => Note::Status(line.to_owned()),
            _ => return,
        };
        drop(self.notes.send(note));
    }

    fn output_ready(&self) {
        drop(self.notes.send(Note::Output));
    }
}

/// Holds the local terminal in raw mode for as long as it is alive.
///
/// The handlers are installed BEFORE the attributes are applied, which is the order `rawmode`'s own
/// documentation mandates: a handler is a no-op while raw mode is not engaged, so installing first
/// closes the window in which a `SIGTERM` landing just after `tcsetattr` would kill the process
/// with the terminal left raw.
#[derive(Debug)]
struct RawGuard;

impl RawGuard {
    /// Enters raw mode on `terminal`.
    ///
    /// # Errors
    /// The `tcgetattr`/`tcsetattr` errno, unchanged — a terminal this could not enter is one it has
    /// not modified, so the caller may report and exit with nothing to undo.
    fn enter(terminal: i32) -> Result<Self, nix::errno::Errno> {
        rawmode::restore_on_signals();
        rawmode::enter(terminal)?;
        Ok(Self)
    }
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        rawmode::restore();
    }
}

/// Runs the client, answering the process exit code.
///
/// `errors` is where every status line goes — the caller's locked stderr. Terminal bytes never
/// touch it: stdout carries the session and nothing else, which is what makes
/// `slopdesk-client … | grep` a sensible thing to type.
pub fn run(args: &Args<'_>, errors: &mut impl Write) -> u8 {
    // A host that vanishes mid-write must not kill this process with a signal: the write fails, the
    // driver reports it, and the campaign answers. Before any socket exists, so no window is left.
    ignore_sigpipe();

    // Blocked HERE, before any thread exists, because a thread inherits the mask of the one that
    // spawned it. Blocking it later would leave whichever threads already ran with the default
    // disposition, and `SIGWINCH`'s default is to be ignored — so a resize would be lost rather
    // than delivered to the waiter.
    let mut winch = SigSet::empty();
    winch.add(Signal::SIGWINCH);
    let _ignored = winch.thread_block();

    // `IsTerminal` rather than a `libc::isatty` call: the std trait is safe, and this crate is
    // `forbid(unsafe_code)`. A door in `slopdesk-posix` would fail that crate's admission test for
    // the same reason — there IS a safe wrapper, and it is in `std`.
    let interactive = std::io::stdin().is_terminal() && !args.no_raw;

    let guard = if interactive {
        match RawGuard::enter(libc::STDIN_FILENO) {
            Ok(guard) => Some(guard),
            Err(errno) => {
                say(errors, &format!("could not enter raw mode: {errno}"));
                return 1;
            },
        }
    } else {
        None
    };

    let (notes, inbox) = channel();
    let observer = Notes {
        notes: notes.clone(),
        interactive,
    };

    let pool = DiallingPool::new(CONNECT_TIMEOUT);
    let config = DriverConfig {
        resume_seed: args.session_id.map(|session_id| {
            ResumeSeed {
                session_id,
                // A cold start asks for the WHOLE ring: a non-zero seq would tell the host to replay
                // only past it, and this process has rendered nothing.
                last_seq: 0,
            }
        }),
        ..DriverConfig::default()
    };
    let driver = match PaneDriver::new(
        std::sync::Arc::clone(pool.registry()),
        std::sync::Arc::new(observer),
        config,
    ) {
        Ok(driver) => std::sync::Arc::new(driver),
        Err(failure) => {
            say(errors, &format!("could not start the session: {failure}"));
            return 1;
        },
    };

    if let Err(failure) = driver.connect(args.host, args.port, CONNECT_TIMEOUT) {
        say(errors, &format!("connect failed: {failure}"));
        driver.close();
        pool.close();
        return 1;
    }
    let session = driver
        .session_id()
        .map_or_else(|| "?".to_owned(), slopdesk_ids::identity::uuid_text);
    say(
        errors,
        &format!("connected to {}:{} (session {session})", args.host, args.port),
    );

    // The initial size, before the waiter: a terminal that is never resized still has to be told
    // how big it is, and the host's fresh shell is drawn against whatever it is told first.
    push_size(&driver);
    spawn_resize_waiter(&driver, winch);
    spawn_stdin_pump(&driver, notes, interactive);

    let code = pump_output(&inbox, &driver, errors, interactive);

    // Close before the pool: `close` gates the retry campaign, so nothing can dial into a pool that
    // is being torn down. Then the pool closes every connection and JOINS its receive loops, which
    // is what makes the return below a quiescence point for everything except the two pumps.
    driver.close();
    pool.close();

    // The stdin thread is abandoned, parked in `read(2)`, and the resize waiter in `sigwait`. Both
    // are deliberate: neither owns anything the process needs back, and the alternative is the
    // Swift's `Shutdown` — a flag, a `close(STDIN_FILENO)` and a cancellation, three moving parts to
    // retire two threads the kernel retires for free when the process ends. What the guard below
    // still owes is the terminal, and it is dropped before the return rather than at it.
    drop(guard);
    code
}

/// The output pump, and the loop that decides when the session is over.
fn pump_output(
    inbox: &Receiver<Note>,
    driver: &PaneDriver,
    errors: &mut impl Write,
    interactive: bool,
) -> u8 {
    let mut code = 0_u8;
    let mut gave_up = false;
    while let Ok(note) = inbox.recv() {
        match note {
            Note::Output => drain(driver),
            Note::Bell => write_out(&[0x07]),
            Note::Status(line) => say(errors, &line),
            Note::Exited(status) => {
                say(errors, &format!("remote shell exited (code {status})"));
                code = u8::try_from(status).unwrap_or(1);
                break;
            },
            Note::GaveUp => {
                gave_up = true;
                break;
            },
            // On a terminal the disconnect key ends the session. On a pipe it does NOT: the script
            // that just ended with `exit\n` still has that command's output in flight, and cutting
            // here would lose the tail. Only the child's own exit ends a piped run.
            Note::StdinDone if interactive => {
                say(errors, "session ending (disconnect key)");
                break;
            },
            Note::StdinDone => {},
        }
    }

    // THE FINAL DRAIN. Output appended between the last wake this loop read and the break has no
    // wake left to announce it — a `Note::Exited` overtaking the last `Note::Output` is the common
    // case, not the rare one, because the exit is a control message and the output is a data one.
    drain(driver);
    if gave_up { 1 } else { code }
}

/// Takes the whole pending backlog and writes it to stdout in order.
fn drain(driver: &PaneDriver) {
    let _taken = driver.take_output(write_out);
}

/// Writes all of `bytes` to stdout, ignoring the outcome.
///
/// Ignored on purpose: stdout is the terminal the user is looking at, and a failure to reach it has
/// nothing left to be reported ON. The raw descriptor rather than `io::stdout()` because that one
/// is line-buffered — a shell prompt, which by definition ends without a newline, would sit in the
/// buffer and the session would look hung.
fn write_out(bytes: &[u8]) {
    let _outcome = fdio::write_all(libc::STDOUT_FILENO, bytes);
}

/// Writes one status line to stderr, ignoring a failure — if stderr is gone there is nothing left
/// to report the failure on, and the exit code still carries the outcome.
fn say(errors: &mut impl Write, line: &str) {
    drop(writeln!(errors, "slopdesk-client: {line}"));
}

/// Reads the local terminal's size and sends it, if there is one to read.
fn push_size(driver: &PaneDriver) {
    let Ok(size) = window_size(libc::STDIN_FILENO) else {
        return;
    };
    let _sent = driver.send_resize(size.ws_col, size.ws_row, size.ws_xpixel, size.ws_ypixel);
}

/// Starts the thread that waits for `SIGWINCH` and pushes the new size.
///
/// A synchronous `sigwait` rather than a handler, and that is the point: a handler may call only
/// async-signal-safe functions, so the Swift needed a `DispatchSource` to get the work OFF the
/// signal context and an `AsyncStream` to get it back into the async one. Here the signal is
/// blocked process-wide and this thread is the only thing that ever collects it, so the "handler"
/// is ordinary code on an ordinary stack and may do the `ioctl` and the send directly.
fn spawn_resize_waiter(driver: &std::sync::Arc<PaneDriver>, winch: SigSet) {
    let driver = std::sync::Arc::clone(driver);
    drop(
        thread::Builder::new()
            .name("slopdesk-client.winch".to_owned())
            .spawn(move || {
                while winch.wait().is_ok() {
                    push_size(&driver);
                }
            }),
    );
}

/// Starts the thread that relays local stdin to the host.
///
/// A dedicated thread because `read(2)` on stdin blocks — in raw mode `VMIN=1` means it blocks
/// until a single keystroke — and a `send_input` that parks in the mux credit window blocks too.
/// Both are correct here and neither may be on a thread the driver needs: this thread doing nothing
/// but waiting IS the backpressure, and a piped producer stalls in its own `write(2)` rather than
/// filling a buffer at pipe speed.
fn spawn_stdin_pump(driver: &std::sync::Arc<PaneDriver>, notes: Sender<Note>, interactive: bool) {
    let driver = std::sync::Arc::clone(driver);
    drop(
        thread::Builder::new()
            .name("slopdesk-client.stdin".to_owned())
            .spawn(move || {
                let mut stdin = std::io::stdin();
                let mut buffer = [0_u8; READ_CHUNK];
                loop {
                    let read = match stdin.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(count) => count,
                    };
                    let Some(chunk) = buffer.get(..read) else {
                        break;
                    };
                    // The disconnect key ends the relay, and what preceded it in the same chunk
                    // still goes: a paste that happens to contain one is not a reason to drop the
                    // line the user typed before it.
                    let (send, stop) = interactive
                        .then(|| chunk.iter().position(|byte| *byte == DISCONNECT_KEY))
                        .flatten()
                        .map_or((chunk, false), |at| (chunk.get(..at).unwrap_or_default(), true));
                    if !send.is_empty() && driver.send_input(send).is_err() {
                        break;
                    }
                    if stop {
                        break;
                    }
                }
                drop(notes.send(Note::StdinDone));
            }),
    );
}

/// A `read(2)`-shaped hole in the test story, stated rather than hidden.
///
/// What this module can be tested for WITHOUT a host is the arg parse (`crate::args`) and the
/// terminal guard's own idempotence, which is `slopdesk-posix`'s and already pinned there. Every
/// other property of this file — that a disconnect key ends the relay, that a piped run waits for
/// the child's exit rather than for stdin's EOF, that the final drain catches a tail — is a claim
/// about two real descriptors and a real host, so it is pinned in `tests/`, which launches the
/// SHIPPED binaries. That is where `SubprocessE2ETests` moved to, and it is the stronger proof for
/// the same reason it was in Swift: an in-memory harness provably misses the open-order races.
#[cfg(test)]
mod tests {
    use super::DISCONNECT_KEY;

    #[test]
    fn the_disconnect_key_is_the_telnet_escape() {
        // Pinned as a NUMBER because it is a user-facing contract documented in `--help`, and a
        // constant that drifted would silently start eating a byte of someone's paste.
        assert_eq!(DISCONNECT_KEY, 0x1D);
    }
}
