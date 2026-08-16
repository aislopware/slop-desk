//! W10 — the Claude Code hook relay.
//!
//! Reads a hook event on stdin and POSTs it to the host's `AF_UNIX` listener
//! (`SLOPDESK_SOCKET_PATH`).
//!
//! This replaces the POSIX-sh script that shelled out to `cat` + `nc`. The
//! script cost ~12.4ms per invocation, ~10ms of which was forking three
//! processes to move ~60 bytes over a socket whose round-trip is ~11µs. Claude
//! Code runs hooks SYNCHRONOUSLY on `PreToolUse`/`PostToolUse`, i.e. twice per
//! tool call, so that fork tax landed directly on the agent's critical path.
//!
//! Contract, inherited verbatim from the script it replaces:
//!
//! - No socket var, or the path is not a socket → silent no-op. A shell that sources these hooks
//!   outside slopdesk must never see an error.
//! - Never fail loudly. Every failure path exits 0; a hook that returns non-zero is surfaced to the
//!   user as a broken turn. The crate denies the whole panic family for the same reason — `panic =
//!   "abort"` would make a stray `unwrap` a non-zero exit.
//! - The relay is SYNCHRONOUS on purpose. Backgrounding it would let two deliveries race and land
//!   `Stop` before the `PreToolUse` it follows, and the host's per-pane handler is a state machine
//!   that reads order as meaning. Bound the wait; do not detach.
//!
//! Record framing (`AgentHookRecord::split` on the host): a `pane=<id>` header
//! line, then the raw hook JSON.
//!
//! The crate also carries [`install`] — the merge that writes the settings entries pointing AT this
//! relay. It is compiled into a second binary (`slopdesk-agenthooks`) and is unreachable from the
//! relay's own `main`, so nothing it depends on is linked into the binary Claude Code forks.

pub mod install;

use std::io::{Read, Write};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// How long a write may block before we give up on the host.
///
/// The host's accept loop hands delivery to a serial queue so it should never
/// park, but a wedged host must cost a bounded moment rather than Claude Code's
/// 30s hook timeout.
pub const WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// What the relay decided.
///
/// Returned instead of exiting so the whole decision tree is unit-testable
/// without a process boundary; `main` maps every variant to exit code 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// `SLOPDESK_SOCKET_PATH` unset or empty — not running under slopdesk.
    NoSocket,
    /// The path exists but is not a socket (stale file, or someone else's).
    NotASocket,
    /// The host is not listening (host down, or a socket left by a crash).
    ConnectFailed,
    /// Connected, but the record could not be written (host wedged past
    /// [`WRITE_TIMEOUT`], or it closed mid-write).
    WriteFailed,
    /// Bytes handed to the kernel.
    Delivered,
}

/// The inputs the relay reads from the environment.
///
/// Passed explicitly rather than read from `std::env` inside the logic, so
/// tests can drive every branch.
#[derive(Debug, Clone, Default)]
pub struct Config {
    /// `SLOPDESK_SOCKET_PATH` — the per-host listener the pane belongs to.
    pub socket_path: Option<String>,
    /// `SLOPDESK_PANE_ID` — routing key. An empty id still frames; the host
    /// resolves it to `nil` and drops the record.
    pub pane_id: String,
}

impl Config {
    /// Reads the config out of the real process environment.
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            socket_path: std::env::var("SLOPDESK_SOCKET_PATH").ok(),
            pane_id: std::env::var("SLOPDESK_PANE_ID").unwrap_or_default(),
        }
    }
}

/// Frames one record: `pane=<id>\n`, the hook JSON, one trailing newline.
///
/// Trailing newlines are stripped from `payload` before the single `\n` is
/// appended, matching the `payload="$(cat)"` command substitution in the script
/// this replaces — the byte stream on the socket is unchanged by the rewrite.
#[must_use]
pub fn build_record(pane_id: &str, payload: &[u8]) -> Vec<u8> {
    let trailing = payload.iter().rev().take_while(|&&b| b == b'\n').count();
    let body = payload.get(..payload.len() - trailing).unwrap_or(payload);

    let mut record = Vec::with_capacity(body.len() + pane_id.len() + 7);
    record.extend_from_slice(b"pane=");
    record.extend_from_slice(pane_id.as_bytes());
    record.push(b'\n');
    record.extend_from_slice(body);
    record.push(b'\n');
    record
}

/// True when `path` exists and is a Unix-domain socket.
///
/// A missing path, a permission error, or a regular file all read as "not
/// ours" — the caller no-ops rather than guessing.
fn is_socket(path: &str) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.file_type().is_socket())
}

/// Reads the hook event and relays it.
///
/// Errors past the socket check are reported through [`Outcome`] rather than
/// raised: a hook that cannot reach its host is a no-op, not a failed turn.
pub fn relay(config: &Config, mut input: impl Read) -> Outcome {
    let Some(path) = config.socket_path.as_deref().filter(|p| !p.is_empty()) else {
        return Outcome::NoSocket;
    };
    if !is_socket(path) {
        return Outcome::NotASocket;
    }

    // Read what we can. A truncated payload is still worth relaying — the host
    // validates-then-drops, so a partial record costs nothing.
    let mut payload = Vec::new();
    let _read = input.read_to_end(&mut payload).ok();

    let Ok(mut stream) = UnixStream::connect(path) else {
        return Outcome::ConnectFailed;
    };
    // Best effort: a socket that refuses the timeout still gets the record.
    let _timeout = stream.set_write_timeout(Some(WRITE_TIMEOUT)).ok();

    let record = build_record(&config.pane_id, &payload);
    if stream.write_all(&record).and_then(|()| stream.flush()).is_err() {
        return Outcome::WriteFailed;
    }
    // Dropping `stream` closes the fd, which is the host's EOF. Unlike `nc`, we
    // do not wait for the peer to close back — there is no reply to read.
    Outcome::Delivered
}

#[cfg(test)]
// Tests assert on known-good fixtures they just created, so `unwrap` IS the
// assertion — a panic here is a failed test, not a broken agent turn. The
// production paths keep the crate-wide deny.
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use std::io::Read as _;
    use std::os::unix::net::UnixListener;

    use super::{Config, Outcome, build_record, relay};

    /// A unique temp dir per test — `AF_UNIX` paths collide across a parallel run.
    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("slopdesk-hook-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_record_carries_the_pane_header_then_the_json() {
        let record = build_record("PANE-1", br#"{"hook_event_name":"Stop"}"#);
        assert_eq!(record, b"pane=PANE-1\n{\"hook_event_name\":\"Stop\"}\n");
    }

    #[test]
    fn trailing_newlines_collapse_to_exactly_one() {
        // `payload="$(cat)"` in the old script stripped every trailing newline
        // and `printf '%s\n'` added one back. Same bytes, or the host sees a
        // different record than it did before the rewrite.
        assert_eq!(build_record("P", b"{}\n\n\n"), b"pane=P\n{}\n");
    }

    #[test]
    fn an_embedded_newline_survives() {
        assert_eq!(build_record("P", b"{\n}"), b"pane=P\n{\n}\n");
    }

    #[test]
    fn an_empty_pane_id_still_frames() {
        // The host resolves an empty id to nil and drops the record; the relay
        // must not invent an id or refuse to send.
        assert_eq!(build_record("", b"{}"), b"pane=\n{}\n");
    }

    #[test]
    fn an_all_newline_payload_does_not_underflow() {
        assert_eq!(build_record("P", b"\n\n\n"), b"pane=P\n\n");
    }

    #[test]
    fn an_empty_payload_still_frames() {
        assert_eq!(build_record("P", b""), b"pane=P\n\n");
    }

    #[test]
    fn a_missing_socket_var_is_a_silent_no_op() {
        let cfg = Config {
            socket_path: None,
            pane_id: "P".to_owned(),
        };
        assert_eq!(relay(&cfg, &b"{}"[..]), Outcome::NoSocket);
    }

    #[test]
    fn an_empty_socket_var_is_a_silent_no_op() {
        let cfg = Config {
            socket_path: Some(String::new()),
            pane_id: "P".to_owned(),
        };
        assert_eq!(relay(&cfg, &b"{}"[..]), Outcome::NoSocket);
    }

    #[test]
    fn a_path_that_is_not_a_socket_is_a_silent_no_op() {
        // A regular file at the socket path must not be written to.
        let dir = temp_dir("file");
        let file = dir.join("not-a-socket");
        std::fs::write(&file, b"x").unwrap();
        let cfg = Config {
            socket_path: Some(file.to_string_lossy().into_owned()),
            pane_id: "P".to_owned(),
        };
        assert_eq!(relay(&cfg, &b"{}"[..]), Outcome::NotASocket);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_dead_host_is_a_silent_no_op() {
        // Bind, then drop the listener but leave the socket file: exactly what
        // a crashed host leaves behind.
        let dir = temp_dir("dead");
        let path = dir.join("s.sock");
        drop(UnixListener::bind(&path).unwrap());
        let cfg = Config {
            socket_path: Some(path.to_string_lossy().into_owned()),
            pane_id: "P".to_owned(),
        };
        assert_eq!(relay(&cfg, &b"{}"[..]), Outcome::ConnectFailed);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_live_host_receives_the_framed_record() {
        let dir = temp_dir("live");
        let path = dir.join("s.sock");
        let listener = UnixListener::bind(&path).unwrap();

        let accept = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            let mut got = Vec::new();
            conn.read_to_end(&mut got).unwrap();
            got
        });

        let cfg = Config {
            socket_path: Some(path.to_string_lossy().into_owned()),
            pane_id: "PANE-9".to_owned(),
        };
        assert_eq!(
            relay(&cfg, &br#"{"hook_event_name":"PreToolUse"}"#[..]),
            Outcome::Delivered
        );

        assert_eq!(
            accept.join().unwrap(),
            b"pane=PANE-9\n{\"hook_event_name\":\"PreToolUse\"}\n"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_payload_larger_than_one_pipe_buffer_arrives_whole() {
        // Hook payloads carry the tool input; a big Write lands well past the
        // 64KB pipe buffer, and a short write would truncate the JSON.
        let dir = temp_dir("big");
        let path = dir.join("s.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let accept = std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            let mut got = Vec::new();
            conn.read_to_end(&mut got).unwrap();
            got
        });

        let big = vec![b'x'; 512 * 1024];
        let cfg = Config {
            socket_path: Some(path.to_string_lossy().into_owned()),
            pane_id: "P".to_owned(),
        };
        assert_eq!(relay(&cfg, &big[..]), Outcome::Delivered);

        let got = accept.join().unwrap();
        assert_eq!(got.len(), big.len() + "pane=P\n".len() + 1);
        std::fs::remove_dir_all(&dir).ok();
    }
}
