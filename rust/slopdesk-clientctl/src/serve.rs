//! The client control socket itself: an `AF_UNIX` listener, one thread per connection, and the
//! NDJSON loop between them.
//!
//! Mirrors the host's own control listener (`slopdesk-hostserver`'s `ctlserve`), because it is the
//! same socket shape one verb set over: a stream socket bound at a stable path, chmod `0600`, one
//! blocking `read` loop per accepted connection, and a response line per request line. What differs
//! is only what the verbs DO, and that is the executor's — [`ControlClient`] — which is the one
//! thing this module does not own.
//!
//! ## Why the executor is a trait and not a function
//! The running client's stores are main-actor isolated on the other side of an FFI boundary, so
//! "run this op" is a call that hops threads and comes back. A trait names that as the ONE seam:
//! everything above it — the bind, the accept, the framing, the decode, the reply — is here and
//! runs on threads this module started, and everything below it is the GUI's. A test conforms a
//! fake and drives the whole path with no socket and no GUI, which is the property the Swift
//! dispatcher had and the reason its tests move here rather than disappearing.
//!
//! ## Hang-safety
//! The accept loop and every connection's blocking `read` run on DEDICATED threads. Nothing here
//! runs on a caller's thread, and nothing here holds a lock across the executor call — so a client
//! that stops reading parks its own connection thread and nothing else.

use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use crate::reply::{self, Outcome};
use crate::request::{Decoded, MAX_REQUEST_BYTES, Op, Refusal, UNKNOWN_ID, decode};

/// The env var the running app exports and the CLI reads to find the socket.
///
/// The CLI's `--socket` flag overrides it on that side; this side resolves env, then the default.
pub const SOCKET_ENV: &str = "SLOPDESK_CLIENT_SOCKET";

/// The socket's file name inside the app's container — a sibling of `workspace.json` and
/// `folders-frecency.json`.
pub const SOCKET_FILE: &str = "cli-control.sock";

/// How much of a connection is read at once.
const READ_CHUNK: usize = 4096;

/// Where the socket lives: the `SLOPDESK_CLIENT_SOCKET` override, else [`SOCKET_FILE`] inside the
/// app's container.
///
/// The override is taken only when it is not blank: an exported-but-empty variable is a shell
/// accident rather than a request to bind the empty path.
#[must_use]
pub fn socket_path_in(container: &Path, override_path: Option<&str>) -> PathBuf {
    match override_path.map(str::trim) {
        Some(chosen) if !chosen.is_empty() => PathBuf::from(chosen),
        _ => container.join(SOCKET_FILE),
    }
}

/// What runs a decoded request against the live client.
///
/// One method, because a dispatcher that could be asked several things would be a place for a
/// second decision to grow. Everything the executor needs to know about the request has already
/// been read, bounded and typed by [`decode`]; everything it wants to say back is an [`Outcome`].
pub trait ControlClient: Send + Sync {
    /// Runs one op and describes what happened.
    ///
    /// Called from a connection thread, one request at a time per connection but concurrently
    /// across connections. An implementation that needs a particular thread is what does that
    /// hop — this module makes no promise about which one it is called on.
    fn run(&self, op: &Op) -> Outcome;
}

/// One request line's answer, LF-terminated, or `None` for a line there is nothing to respond to.
///
/// The whole protocol in one function, so a test drives the socket's behaviour without a socket.
#[must_use]
pub fn answer(line: &str, client: &dyn ControlClient) -> Option<String> {
    match decode(line) {
        Decoded::Blank => None,
        Decoded::Refused(refused) => Some(refused + "\n"),
        Decoded::Run { id, op } => Some(reply::line(&id, &client.run(&op)) + "\n"),
    }
}

/// A bound, listening client control socket.
///
/// Dropping it stops the listener and unlinks the path, so the socket's lifetime is the value's and
/// there is no "did anyone call stop" question to get wrong.
#[derive(Debug)]
pub struct Server {
    path: PathBuf,
    stopped: Arc<AtomicBool>,
}

impl Server {
    /// Binds `path`, restricts it to this user, and begins accepting.
    ///
    /// A stale socket file is unlinked first: this is a single-user tool and the newest app owns
    /// the stable path, which is the same posture the host's listener takes.
    ///
    /// # Errors
    /// The bind or the listen failing — a path longer than `sun_path`, a directory that is not
    /// there, a permission the user does not have.
    pub fn bind(path: &Path, client: Arc<dyn ControlClient>) -> std::io::Result<Self> {
        if let Some(parent) = path.parent() {
            // Best-effort: a container that cannot be created will fail the bind below with the
            // errno that actually explains it, which is a better report than one from here.
            drop(std::fs::create_dir_all(parent));
        }
        drop(std::fs::remove_file(path));
        // `std`'s listen backlog is 128, deeper than the 16 the host's listener asks for — so a
        // burst of `slopdesk` invocations queues rather than being refused, and there is no socket
        // option to set here that would improve on it.
        let listener = UnixListener::bind(path)?;
        // Same-uid only, the posture the host ctl socket keeps. There is no app-layer auth on this
        // wire by design (`CLAUDE.md`): the file mode IS the boundary.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;

        let stopped = Arc::new(AtomicBool::new(false));
        let server = Self {
            path: path.to_owned(),
            stopped: Arc::clone(&stopped),
        };
        drop(
            thread::Builder::new()
                .name("slopdesk-clientctl-accept".to_owned())
                .spawn(move || accept_loop(&listener, &client, &stopped))?,
        );
        Ok(server)
    }

    /// The path the socket is bound at.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        // Order matters: the flag first, then ONE dial to wake the `accept` that is parked on it,
        // then the unlink. Waking before unlinking is what lets the accept thread find the path it
        // is listening on; unlinking first would leave it parked on a socket nothing can reach.
        self.stopped.store(true, Ordering::Release);
        drop(UnixStream::connect(&self.path));
        drop(std::fs::remove_file(&self.path));
    }
}

/// Accepts until the server is dropped.
fn accept_loop(listener: &UnixListener, client: &Arc<dyn ControlClient>, stopped: &Arc<AtomicBool>) {
    while let Ok((connection, _)) = listener.accept() {
        if stopped.load(Ordering::Acquire) {
            return;
        }
        let client = Arc::clone(client);
        drop(
            thread::Builder::new()
                .name("slopdesk-clientctl-serve".to_owned())
                .spawn(move || serve(connection, client.as_ref())),
        );
    }
}

/// One connection's NDJSON loop, until EOF or an I/O error.
///
/// Connections are long-lived: the CLI may pipeline requests on one, and each is answered in the
/// order it arrived.
fn serve(mut connection: UnixStream, client: &dyn ControlClient) {
    let mut pending: Vec<u8> = Vec::new();
    let mut chunk = [0_u8; READ_CHUNK];
    loop {
        let read = match connection.read(&mut chunk) {
            Ok(0) => return,
            Ok(count) => count,
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        pending.extend_from_slice(chunk.get(..read).unwrap_or_default());

        while let Some(cut) = pending.iter().position(|byte| *byte == b'\n') {
            let line = pending.drain(..=cut).collect::<Vec<u8>>();
            // Validate-then-drop: a line that is not UTF-8 never reaches the decoder. It is
            // answered rather than ignored, because the caller is owed a reply per line and
            // `String::from_utf8_lossy` would invent characters nobody sent.
            let answered = std::str::from_utf8(line.get(..cut).unwrap_or_default()).map_or_else(
                |_| Some(reply::refusal_line(UNKNOWN_ID, Refusal::Malformed, "") + "\n"),
                |text| answer(text, client),
            );
            if let Some(response) = answered
                && connection.write_all(response.as_bytes()).is_err()
            {
                // A control client that has gone away is not something a listener can do anything
                // about, which is the same drop-on-failure contract the host's listener keeps.
                return;
            }
        }

        // A hostile, newline-less stream must not grow this buffer without bound. Dropping the
        // partial line is the refusal: there is no `id` in it yet to answer under.
        if pending.len() > MAX_REQUEST_BYTES {
            pending.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::sync::{Arc, Mutex};

    use slopdesk_agent::badge::TabBadge;

    use super::{ControlClient, Server, answer, socket_path_in};
    use crate::reply::{Outcome, Window};
    use crate::request::Op;

    /// A client that records what it was asked and answers a fixed shape. The whole point of the
    /// [`ControlClient`] seam: the socket's behaviour is testable with no GUI behind it.
    #[derive(Default)]
    struct Recorder {
        seen: Mutex<Vec<Op>>,
    }

    impl ControlClient for Recorder {
        fn run(&self, op: &Op) -> Outcome {
            if let Ok(mut seen) = self.seen.lock() {
                seen.push(op.clone());
            }
            match *op {
                Op::Windows => {
                    Outcome::Windows(vec![Window {
                        id: "w1".to_owned(),
                        title: "Work".to_owned(),
                        tab_count: 1,
                        focused: true,
                    }])
                },
                Op::TabBadge { kind, .. } => Outcome::Badge(kind),
                _ => Outcome::Done,
            }
        }
    }

    // -- the pure half --------------------------------------------------------------------------

    #[test]
    fn a_a_request_reaches_the_client_and_its_outcome_comes_back_as_a_line() {
        let client = Recorder::default();
        let said =
            answer(r#"{"id":"7","method":"windows","params":{}}"#, &client).expect("a request is answered");
        assert_eq!(
            said,
            "{\"id\":\"7\",\"ok\":true,\"result\":{\"windows\":[{\"focused\":true,\"id\":\"w1\",\"tabCount\"\
             :1,\"title\":\"Work\"}]}}\n",
        );
        assert_eq!(
            client.seen.lock().map(|seen| seen.clone()).unwrap_or_default(),
            vec![Op::Windows],
        );
    }

    #[test]
    fn a_blank_line_is_answered_with_nothing_at_all() {
        let client = Recorder::default();
        assert_eq!(answer("   \t ", &client), None);
        assert!(
            client.seen.lock().is_ok_and(|seen| seen.is_empty()),
            "a blank line never reaches the client",
        );
    }

    /// A refusal is answered WITHOUT the client being asked — the decode is the gate, so a hostile
    /// line cannot reach the running GUI even to be rejected by it.
    #[test]
    fn a_refused_request_never_reaches_the_client() {
        let client = Recorder::default();
        let said = answer(r#"{"id":"1","method":"teleport"}"#, &client).expect("a refusal is a line");
        assert!(said.contains("unknown method: teleport"));
        assert!(client.seen.lock().is_ok_and(|seen| seen.is_empty()));
    }

    #[test]
    fn every_answer_is_one_lf_terminated_line() {
        let client = Recorder::default();
        for line in [
            r#"{"id":"1","method":"windows"}"#,
            r#"{"id":"1","method":"tab-badge","params":{"kind":"error"}}"#,
            "not json",
        ] {
            let said = answer(line, &client).expect("a line is answered");
            assert!(said.ends_with('\n'), "{line}");
            assert_eq!(said.matches('\n').count(), 1, "{line}");
        }
    }

    #[test]
    fn a_badge_token_round_trips_through_the_op_and_back_out() {
        let client = Recorder::default();
        let said = answer(
            r#"{"id":"1","method":"tab-badge","params":{"kind":"unread"}}"#,
            &client,
        )
        .expect("a request is answered");
        assert!(
            said.contains(r#""kind":"finished""#),
            "`unread` names `finished`, and the reply prints the CANONICAL token: {said}",
        );
        assert_eq!(
            client.seen.lock().map(|seen| seen.clone()).unwrap_or_default(),
            vec![Op::TabBadge {
                tab_id: None,
                kind: TabBadge::Finished,
            }],
        );
    }

    // -- the socket -----------------------------------------------------------------------------

    /// The whole path over a real socket: bind, dial, pipeline two requests, read two replies.
    #[test]
    fn b_the_socket_answers_one_line_per_request_line() {
        let dir = std::env::temp_dir().join(format!("slopdesk-ctl-{}", std::process::id()));
        drop(std::fs::create_dir_all(&dir));
        let path = socket_path_in(&dir, None);
        let client: Arc<dyn ControlClient> = Arc::new(Recorder::default());
        let server = Server::bind(&path, client).expect("the socket binds");
        assert_eq!(server.path(), path.as_path());

        let mut dialled = UnixStream::connect(&path).expect("the socket accepts a dial");
        dialled
            .write_all(b"{\"id\":\"1\",\"method\":\"windows\"}\n\n{\"id\":\"2\",\"method\":\"teleport\"}\n")
            .expect("the request is written");
        let mut reader = BufReader::new(dialled.try_clone().expect("the stream clones"));

        let mut first = String::new();
        let _read = reader.read_line(&mut first).expect("a reply arrives");
        assert!(first.contains(r#""id":"1""#), "{first}");
        assert!(first.contains(r#""windows""#), "{first}");

        // The blank line between the two produced NO reply, so the next line read is the second
        // request's answer rather than an empty one.
        let mut second = String::new();
        let _read = reader.read_line(&mut second).expect("a second reply arrives");
        assert!(second.contains(r#""id":"2""#), "{second}");
        assert!(second.contains("unknown method: teleport"), "{second}");

        drop(server);
        drop(std::fs::remove_dir_all(&dir));
    }

    /// Dropping the server unlinks the path, so a stale socket file never outlives the app that
    /// bound it.
    #[test]
    fn dropping_the_server_takes_the_socket_file_with_it() {
        let dir = std::env::temp_dir().join(format!("slopdesk-ctl-drop-{}", std::process::id()));
        drop(std::fs::create_dir_all(&dir));
        let path = socket_path_in(&dir, None);
        let client: Arc<dyn ControlClient> = Arc::new(Recorder::default());
        let server = Server::bind(&path, client).expect("the socket binds");
        assert!(path.exists());
        drop(server);
        assert!(!path.exists());
        drop(std::fs::remove_dir_all(&dir));
    }

    /// Binding over a stale file succeeds: the newest app owns the stable path.
    #[test]
    fn a_stale_socket_file_is_replaced_rather_than_refused() {
        let dir = std::env::temp_dir().join(format!("slopdesk-ctl-stale-{}", std::process::id()));
        drop(std::fs::create_dir_all(&dir));
        let path = socket_path_in(&dir, None);
        std::fs::write(&path, b"stale").expect("a stale file is planted");
        let client: Arc<dyn ControlClient> = Arc::new(Recorder::default());
        let server = Server::bind(&path, client).expect("the stale file does not refuse the bind");
        assert!(UnixStream::connect(&path).is_ok());
        drop(server);
        drop(std::fs::remove_dir_all(&dir));
    }

    // -- the path -------------------------------------------------------------------------------

    #[test]
    fn c_the_default_path_is_the_containers_and_an_override_wins() {
        let container = std::path::Path::new("/tmp/SlopDesk");
        assert_eq!(
            socket_path_in(container, None),
            std::path::Path::new("/tmp/SlopDesk/cli-control.sock"),
        );
        assert_eq!(
            socket_path_in(container, Some("/var/run/x.sock")),
            std::path::Path::new("/var/run/x.sock"),
        );
    }

    /// An exported-but-blank override is a shell accident, not a request to bind the empty path.
    #[test]
    fn a_blank_override_is_not_an_override() {
        let container = std::path::Path::new("/tmp/SlopDesk");
        for blank in ["", " ", "\t\n"] {
            assert_eq!(
                socket_path_in(container, Some(blank)),
                std::path::Path::new("/tmp/SlopDesk/cli-control.sock"),
                "{blank:?}",
            );
        }
    }
}
