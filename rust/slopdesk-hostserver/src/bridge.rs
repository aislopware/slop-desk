//! The host end of the embedded editor's command channel — the port of
//! `Sources/SlopDeskHost/CodeBridgeServer.swift`.
//!
//! The other end is `rust/slopdesk-codeseed/resources/bridge/extension.js`, and the message set is
//! [`slopdesk_muxsession::bridge_router`]'s. Every DECISION on this path already lived there before
//! the port started — which window owns a path, what a believed line is, what may be typed at a
//! shell prompt, how a result is spelled. What is left here, and all that is left, is the socket.
//!
//! ## Both directions, and they do not share a shape
//! The host COMMANDS (`open`) with no reply expected, from whatever thread
//! [`crate::code::CodeServerManager::open_in_workbench`] runs on. The extension REQUESTS (`run`,
//! `cd`, carrying a correlation id) and is answered on the same connection from that connection's
//! read thread — which is also where the installed terminal runner executes, so it must be quick
//! and thread-safe.
//!
//! ## One connection per workbench window
//! code-server runs a remote extension host per window, each activating the extension, so the
//! connection set IS "the windows currently open" and the `root` each announces is its workspace
//! folder. That is what makes routing possible at all: the CLI's `-r` picks the most recently
//! registered session, whereas [`bridge_router::route`] picks the window whose folder actually
//! contains the file.
//!
//! ## The one departure: how a `stop` ends the accept
//!
//! The Swift closed the listening descriptor from the stopping thread while the accept thread was
//! parked inside `accept(2)` on it. Darwin wakes the sleeper, so it worked — but it is a close of a
//! descriptor another thread is inside, and between that close and the loop's next syscall any
//! thread in the process can open something that lands on the same number. The loop would then
//! accept on a stranger's descriptor.
//!
//! Here the accept thread OWNS its listener and nobody else may touch it. It parks in `poll` on two
//! descriptors — the listener and a wake pipe — and [`CodeBridgeServer::stop`] writes one byte to
//! the pipe. The loop returns, the listener drops on the way out, and no descriptor is ever closed
//! out from under a syscall. This is `slopdesk-superd`'s pump loop's shape, for its reason.
//!
//! Per-connection reads need none of that: the table keeps a second handle on each accepted socket,
//! and `shutdown(2)` acts on the socket OBJECT rather than on a descriptor, so waking a read
//! through a duplicate is exactly what it is for.

use std::collections::HashMap;
use std::fmt;
use std::io::{Read as _, Write as _};
use std::net::Shutdown;
use std::os::fd::{AsFd as _, AsRawFd as _, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};

use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use slopdesk_muxsession::bridge_router::{self, BridgeWindow, Inbound, MAX_LINE_BYTES, RunRequest};
use slopdesk_terminal::link_action::line_col_suffix;

use crate::code::CodeBridge;
use crate::service::LogSink;

/// What became of a `run`.
///
/// `pane_title` names where the command landed so the editor can say so; `message` is the sentence
/// shown when it did not.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunOutcome {
    /// Whether the command was typed at all.
    pub ok: bool,
    /// The pane it went to, when one took it.
    pub pane_title: Option<String>,
    /// Why it did not, when it did not.
    pub message: Option<String>,
}

impl RunOutcome {
    /// It was typed, into the named pane.
    #[must_use]
    pub fn landed(pane_title: &str) -> Self {
        Self {
            ok: true,
            pane_title: Some(pane_title.to_owned()),
            message: None,
        }
    }

    /// It was not, and this is the sentence the editor shows.
    #[must_use]
    pub fn refused(message: &str) -> Self {
        Self {
            ok: false,
            pane_title: None,
            message: Some(message.to_owned()),
        }
    }
}

/// What happens when the editor asks to type into a terminal pane.
///
/// Installed by whoever holds the sessions. A server standing alone has none, and a request that
/// arrives without one is REFUSED rather than dropped: the editor is waiting on that line to tell
/// the user something.
pub type TerminalRunner = Arc<dyn Fn(&RunRequest) -> RunOutcome + Send + Sync>;

/// The sentence a request gets when nobody has installed a runner.
const NO_RUNNER: &str = "SlopDesk: this host cannot reach a terminal pane right now.";

/// How much is read from a connection at a time. An inbound line is capped far below this by
/// [`MAX_LINE_BYTES`]; the number is only how often the read loop goes round.
const READ_CHUNK_BYTES: usize = 4096;

/// One connected workbench window.
struct Window {
    /// Its workspace folder, empty until the opening `hello` names it — which is what makes the
    /// connection routable. Behind its own lock because the read thread writes it while an `open`
    /// on another thread reads it, and neither wants to hold the table's lock to do so.
    root: Mutex<String>,
    /// Writes go through one lock so two threads cannot interleave halves of two lines into a
    /// parser that reads by newline.
    writer: Mutex<UnixStream>,
    /// A second handle on the same socket, kept OUTSIDE the write lock so a `stop` can wake a read
    /// even while a write to that same window is parked.
    waker: UnixStream,
}

impl fmt::Debug for Window {
    /// Written out because a `Mutex<UnixStream>` prints nothing worth reading, and the crate denies
    /// a missing `Debug`.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("Window").finish_non_exhaustive()
    }
}

/// What a bound server holds that an unbound one does not.
#[derive(Debug)]
struct Bound {
    /// Where it is listening.
    path: PathBuf,
    /// `(st_dev, st_ino)` of the socket FILE, captured right after the bind — see
    /// [`CodeBridgeServer::stop`], which is the only thing that reads it.
    identity: (u64, u64),
    /// One byte here ends the accept loop.
    wake: OwnedFd,
}

/// Everything one lock covers.
#[derive(Debug, Default)]
struct Guarded {
    bound: Option<Bound>,
    windows: HashMap<RawFd, Arc<Window>>,
}

/// Accepts the bridge extension's connections and routes open-commands to the right one.
pub struct CodeBridgeServer {
    /// Handed to the accept and read threads, which must not keep the server alive on their own:
    /// the last owner dropping it is what a `stop` that never came looks like.
    me: Weak<Self>,
    guarded: Mutex<Guarded>,
    /// Its own lock, because a `run` takes it on the read thread while an `open` may be inside
    /// [`Guarded`] on another — and neither wants to wait for the other.
    runner: Mutex<Option<TerminalRunner>>,
    on_log: Option<LogSink>,
}

impl fmt::Debug for CodeBridgeServer {
    /// Written out because the log sink and the runner are bare closures with nothing to print.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CodeBridgeServer")
            .field("bound", &self.bound_path())
            .finish_non_exhaustive()
    }
}

impl CodeBridgeServer {
    /// A server that is not listening yet.
    #[must_use]
    pub fn new(on_log: Option<LogSink>) -> Arc<Self> {
        Arc::new_cyclic(|me| {
            Self {
                me: me.clone(),
                guarded: Mutex::new(Guarded::default()),
                runner: Mutex::new(None),
                on_log,
            }
        })
    }

    /// Installs what happens when the editor asks to type into a terminal pane.
    ///
    /// Deliberately NOT on [`CodeBridge`]: the workbench manager opens files and never types, so a
    /// seam it holds has no business carrying this. Whoever owns the sessions installs it.
    pub fn set_terminal_runner(&self, runner: Option<TerminalRunner>) {
        if let Ok(mut held) = self.runner.lock() {
            *held = runner;
        }
    }

    /// Where it is listening, or `None`.
    #[must_use]
    pub fn bound_path(&self) -> Option<PathBuf> {
        self.guarded
            .lock()
            .ok()
            .and_then(|guarded| guarded.bound.as_ref().map(|bound| bound.path.clone()))
    }

    /// The workspace folder of every connected workbench window, in no order.
    ///
    /// An empty string is a window that has connected but not said `hello` yet — connected is not
    /// routable, and the two are worth telling apart. This is the set
    /// [`bridge_router::route`] chooses from.
    #[must_use]
    pub fn roots(&self) -> Vec<String> {
        self.guarded.lock().map_or_else(
            |_poisoned| Vec::new(),
            |guarded| {
                guarded
                    .windows
                    .values()
                    .map(|window| {
                        window
                            .root
                            .lock()
                            .map_or_else(|poisoned| poisoned.into_inner().clone(), |root| root.clone())
                    })
                    .collect()
            },
        )
    }

    // MARK: Internals

    fn log(&self, line: &str) {
        if let Some(sink) = self.on_log.as_ref() {
            sink(line);
        }
    }

    /// `(st_dev, st_ino)` of the file at `path`, or `None` when it is gone.
    ///
    /// Deliberately a stat on the PATH rather than on the listening descriptor: a bound `AF_UNIX`
    /// socket's descriptor reports the socket object, not the directory entry, so only the path can
    /// answer who owns the NAME now.
    fn identity(path: &Path) -> Option<(u64, u64)> {
        let info = std::fs::metadata(path).ok()?;
        Some((info.dev(), info.ino()))
    }

    /// Takes a connection into the table and starts its read thread.
    fn welcome(&self, stream: UnixStream) {
        let fd = stream.as_raw_fd();
        // A workbench window outlives many a shell this host forks, and an inherited copy would
        // keep the extension's connection open long past the window that owns it.
        slopdesk_posix::pty::set_cloexec(fd);
        // The host writes to this from `open`, long after the peer may have gone. Without this the
        // write raises `SIGPIPE`, and in a linked-into-Swift host that ends the process — see
        // `slopdesk_posix::sock::set_nosigpipe`.
        slopdesk_posix::sock::set_nosigpipe(fd);
        let (Ok(writer), Ok(waker)) = (stream.try_clone(), stream.try_clone()) else {
            return;
        };
        let window = Arc::new(Window {
            root: Mutex::new(String::new()),
            writer: Mutex::new(writer),
            waker,
        });
        if let Ok(mut guarded) = self.guarded.lock() {
            guarded.windows.insert(fd, window);
        }
        let me = self.me.clone();
        let spawned = std::thread::Builder::new()
            .name("code-bridge-window".to_owned())
            .spawn(move || {
                if let Some(server) = Weak::upgrade(&me) {
                    server.read_loop(&stream, fd);
                    server.drop_window(fd);
                }
            });
        if spawned.is_err() {
            // No thread means no reader, and a connection nobody reads is one the extension will
            // wait on for ever. Taking it back out is the honest answer.
            self.drop_window(fd);
        }
    }

    /// Reads the peer's NDJSON until EOF.
    ///
    /// Validate-then-drop throughout: an oversized line, malformed JSON or an unknown verb is
    /// SKIPPED and the connection carries on, because a workbench window is expensive to replace
    /// and one bad line says nothing about the next.
    fn read_loop(&self, stream: &UnixStream, fd: RawFd) {
        let mut buffer: Vec<u8> = Vec::new();
        let mut chunk = [0_u8; READ_CHUNK_BYTES];
        loop {
            let read = match (&mut &*stream).read(&mut chunk) {
                Ok(0) => return,
                Ok(read) => read,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return,
            };
            let Some(fresh) = chunk.get(..read) else {
                return;
            };
            buffer.extend_from_slice(fresh);
            while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
                let rest = buffer.split_off(newline + 1);
                let line = std::mem::replace(&mut buffer, rest);
                let Some(believed) = line
                    .get(..newline)
                    .filter(|line| line.len() <= MAX_LINE_BYTES)
                    .and_then(bridge_router::inbound)
                else {
                    continue;
                };
                match believed {
                    Inbound::Hello(root) => self.note(&root, fd),
                    Inbound::Run(request) => self.perform(&request, fd),
                }
            }
            // A peer that never sends a newline must not grow this without bound.
            if buffer.len() > MAX_LINE_BYTES {
                buffer.clear();
            }
        }
    }

    /// Records the window's workspace folder, which is what makes it routable.
    fn note(&self, root: &str, fd: RawFd) {
        let window = self
            .guarded
            .lock()
            .ok()
            .and_then(|guarded| guarded.windows.get(&fd).map(Arc::clone));
        let noted = window.is_some_and(|window| {
            window.root.lock().is_ok_and(|mut held| {
                held.clear();
                held.push_str(root);
                true
            })
        });
        if noted {
            self.log(&format!("code-bridge: workbench window attached for {root}"));
        }
    }

    /// Runs one request through the installed runner and answers the window that asked.
    fn perform(&self, request: &RunRequest, fd: RawFd) {
        let runner = self
            .runner
            .lock()
            .ok()
            .and_then(|held| held.as_ref().map(Arc::clone));
        let outcome = runner.map_or_else(|| RunOutcome::refused(NO_RUNNER), |run| run(request));
        let line = bridge_router::result_line(
            &request.id,
            outcome.ok,
            outcome.pane_title.as_deref(),
            outcome.message.as_deref(),
        );
        if !line.is_empty() {
            let _ignored = self.write_line(fd, &line);
        }
    }

    /// Writes one command line. A failed write drops the connection: the peer is gone, and a
    /// half-written line would desynchronise its parser.
    fn write_line(&self, fd: RawFd, line: &str) -> bool {
        let Some(window) = self
            .guarded
            .lock()
            .ok()
            .and_then(|guarded| guarded.windows.get(&fd).map(Arc::clone))
        else {
            return false;
        };
        let wrote = window.writer.lock().is_ok_and(|mut writer| {
            writer
                .write_all(line.as_bytes())
                .and_then(|()| writer.flush())
                .is_ok()
        });
        if !wrote {
            self.drop_window(fd);
        }
        wrote
    }

    /// Takes a connection out of the table. The socket closes when the last handle on it drops.
    fn drop_window(&self, fd: RawFd) {
        let gone = self
            .guarded
            .lock()
            .is_ok_and(|mut guarded| guarded.windows.remove(&fd).is_some());
        if gone {
            self.log("code-bridge: workbench window detached");
        }
    }

    /// Parks on the listener and the wake pipe until one of them has something to say.
    ///
    /// The listener is this thread's and nobody else's, which is the whole point — see the module
    /// header. `false` ends the loop.
    fn accept_loop(&self, listener: &UnixListener, wake: &OwnedFd) {
        loop {
            let mut watched = [
                PollFd::new(listener.as_fd(), PollFlags::POLLIN),
                PollFd::new(wake.as_fd(), PollFlags::POLLIN),
            ];
            // No timeout. An idle bridge must cost nothing, and the only two things that can matter
            // here are a window dialling in and a `stop` poking the pipe.
            match poll(&mut watched, PollTimeout::NONE) {
                Ok(_ready) => (),
                Err(Errno::EINTR) => continue,
                Err(_) => return,
            }
            let stopping = watched
                .get(1)
                .and_then(PollFd::revents)
                .is_some_and(|events| !events.is_empty());
            if stopping {
                return;
            }
            match listener.accept() {
                Ok((stream, _address)) => {
                    // The listener is non-blocking so a spurious readiness cannot park this thread;
                    // an accepted connection is not, because its read loop is meant to park.
                    let _ignored = stream.set_nonblocking(false);
                    self.welcome(stream);
                },
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                    ) => {},
                Err(_) => return,
            }
        }
    }
}

impl CodeBridge for CodeBridgeServer {
    /// Binds the listener at `path`.
    ///
    /// Idempotent, and every failure is SILENT: the bridge is an accelerator, and a host that
    /// cannot bind still opens files through the `code-server -r` CLI. There is nothing for a
    /// caller to do differently, so there is nothing to hand it.
    fn start(&self, path: &str) {
        let path = PathBuf::from(path);
        let listener = {
            let Ok(mut guarded) = self.guarded.lock() else {
                return;
            };
            if guarded.bound.is_some() {
                return;
            }
            // A missing file is the normal case; a real failure is reported by `bind` itself, which
            // is also what refuses a path too long for `sun_path`.
            let _ignored = std::fs::remove_file(&path);
            let Ok(listener) = UnixListener::bind(&path) else {
                return;
            };
            // Bound for as long as this host serves, so it must not reach a shell forked later.
            slopdesk_posix::pty::set_cloexec(listener.as_raw_fd());
            // Same-uid only, like every other socket this host binds.
            let _ignored = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            let Some(identity) = Self::identity(&path) else {
                return;
            };
            let Ok((wake_read, wake)) = nix::unistd::pipe() else {
                return;
            };
            slopdesk_posix::pty::set_cloexec(wake_read.as_raw_fd());
            slopdesk_posix::pty::set_cloexec(wake.as_raw_fd());
            if listener.set_nonblocking(true).is_err() {
                return;
            }
            guarded.bound = Some(Bound {
                path: path.clone(),
                identity,
                wake,
            });
            (listener, wake_read)
        };
        let (listener, wake_read) = listener;
        let me = self.me.clone();
        let spawned = std::thread::Builder::new()
            .name("code-bridge-accept".to_owned())
            .spawn(move || {
                if let Some(server) = Weak::upgrade(&me) {
                    server.accept_loop(&listener, &wake_read);
                }
            });
        if spawned.is_err() {
            // A bound listener nobody accepts on is worse than no bridge at all: the extension
            // connects, waits, and never hears back. Undo the bind instead.
            self.stop();
            return;
        }
        self.log(&format!("code-bridge socket listening at {}", path.display()));
    }

    /// Asks the workbench window that owns `target` to open it.
    ///
    /// `false` means no connected window claims the path — nothing booted yet, or the file lives
    /// outside every open folder — which is the caller's signal to fall back to the CLI rather than
    /// drop a file into an unrelated project's window.
    fn open(&self, target: &str) -> bool {
        // The `:line:col` tail is split off through `slopdesk-terminal`'s own splitter, the one the
        // client's link detector uses, so the routing sees a path and the command builder sees the
        // two halves already apart.
        let suffix = line_col_suffix(target);
        let Some(path) = target.get(..target.len() - suffix.len()) else {
            return false;
        };
        let candidates: Vec<BridgeWindow> = match self.guarded.lock() {
            Ok(guarded) => {
                guarded
                    .windows
                    .iter()
                    .map(|(fd, window)| {
                        BridgeWindow {
                            fd: *fd,
                            root: window
                                .root
                                .lock()
                                .map_or_else(|poisoned| poisoned.into_inner().clone(), |root| root.clone()),
                        }
                    })
                    .collect()
            },
            Err(_poisoned) => return false,
        };
        let Some(fd) = bridge_router::route(path, &candidates) else {
            return false;
        };
        let line = bridge_router::open_command(path, suffix);
        !line.is_empty() && self.write_line(fd, &line)
    }

    /// Closes the listener, drops every connection, unlinks the socket file. Idempotent.
    ///
    /// The socket file is removed only if it is still the one this server created. The name is
    /// pid-free by design (`docs/51` §1), so between this server's bind and this stop a SECOND
    /// hostd may have unlinked it and bound its own — and an unconditional unlink here would delete
    /// that live host's name out from under it. Nothing would put it back: the victim's `start`
    /// returns early while it is bound, so its extension hosts would reconnect for five minutes to
    /// a name nobody holds, and open-file and run-in-terminal would stop working with no error
    /// anywhere. Comparing `(st_dev, st_ino)` against what was recorded at bind time is exact: a
    /// rebind is a new inode, always.
    fn stop(&self) {
        let (bound, windows) = match self.guarded.lock() {
            Ok(mut guarded) => {
                (
                    guarded.bound.take(),
                    std::mem::take(&mut guarded.windows)
                        .into_values()
                        .collect::<Vec<_>>(),
                )
            },
            Err(_poisoned) => return,
        };
        for window in &windows {
            // Wakes the read thread through a duplicate. Closing a descriptor it is inside would be
            // the very thing the module header refuses to do to the accept thread.
            let _ignored = window.waker.shutdown(Shutdown::Both);
        }
        let Some(bound) = bound else {
            return;
        };
        // One byte ends the accept loop, which drops the listener on its way out.
        let _ignored = nix::unistd::write(&bound.wake, &[1_u8]);
        if Self::identity(&bound.path) == Some(bound.identity) {
            let _ignored = std::fs::remove_file(&bound.path);
        }
    }
}
