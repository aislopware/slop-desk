//! The client control socket: where it is, and one request over it.
//!
//! `AF_UNIX`, NDJSON, one line each way. The Swift original hand-built a `sockaddr_un` and drove
//! `connect(2)`/`read(2)` through `withUnsafeMutablePointer`; `std::os::unix::net::UnixStream` does
//! the same three syscalls with none of it, which is why the root workspace can keep
//! `forbid(unsafe_code)` over a CLI whose whole job is a socket.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use crate::clientctl::{Params, decode_response_line, encode_request_line};
use crate::shell::{Control, Ctx, Failure, SOCKET_ENV};

/// The longest path an `AF_UNIX` address can carry on Darwin.
///
/// `sockaddr_un.sun_path` is 104 bytes and one of them is the terminator. Checked before the
/// syscall so the failure names the path rather than surfacing as a generic `EINVAL` from deep
/// inside `connect(2)`.
pub const MAX_SOCKET_PATH: usize = 103;

/// The ceiling on one response line.
///
/// Generous, because a `pane capture` answer is a screen's worth of scrollback, but finite, so an
/// app that never sends its LF cannot make the CLI consume memory until the machine notices.
pub const MAX_RESPONSE_BYTES: u64 = 64 * 1024 * 64;

/// Resolve the client control socket path: `--socket`, then [`SOCKET_ENV`], then the Application
/// Support default.
///
/// Mirrors `ClientControlServer.resolveSocketPath` so a separately-launched CLI and the app agree
/// without coordination — including the part that looks like an oversight and is not: the default
/// is built from `$HOME` directly and does NOT honour `SLOPDESK_APP_SUPPORT_DIR`. The app's own
/// resolution does not either, and the two have to name the same file or the CLI dials nothing.
/// (The sidecars RECORD, which only this program writes, does honour it.)
#[must_use]
pub fn resolve_socket_path(ctx: &Ctx) -> String {
    if let Some(explicit) = ctx
        .invocation
        .socket_path
        .as_deref()
        .filter(|path| !path.is_empty())
    {
        return explicit.to_owned();
    }
    if let Some(from_env) = ctx.environment.get(SOCKET_ENV) {
        return from_env.to_owned();
    }
    format!(
        "{}/Library/Application Support/SlopDesk/cli-control.sock",
        ctx.environment.home()
    )
}

/// One connection per request, which is what the app's listener expects and what a program that
/// answers one question and exits wants anyway.
#[derive(Debug, Clone)]
pub struct SocketControl {
    /// The resolved socket path.
    pub socket_path: String,
    /// The per-request IPC wait, applied to BOTH directions.
    pub timeout_ms: i64,
}

impl SocketControl {
    /// The control end this invocation's flags and environment name.
    #[must_use]
    pub fn new(ctx: &Ctx) -> Self {
        Self {
            socket_path: resolve_socket_path(ctx),
            timeout_ms: ctx.invocation.timeout_ms,
        }
    }

    /// The `--timeout` as a duration, or `None` for a non-positive one, which means "do not set
    /// one" rather than "time out immediately".
    fn timeout(&self) -> Option<Duration> {
        u64::try_from(self.timeout_ms)
            .ok()
            .filter(|ms| *ms > 0)
            .map(Duration::from_millis)
    }

    /// Opens a connection with the IPC timeout applied to both directions.
    fn connect(&self) -> Result<UnixStream, Failure> {
        if self.socket_path.len() > MAX_SOCKET_PATH {
            return Err(Failure::plain(format!(
                "socket path too long: {}",
                self.socket_path
            )));
        }
        let stream = UnixStream::connect(&self.socket_path).map_err(|error| {
            Failure::no_app(format!(
                "requires a running SlopDesk app (no control socket at {}: {error})",
                self.socket_path
            ))
        })?;
        if let Some(timeout) = self.timeout() {
            // A timeout the kernel refuses is not worth failing the request over — the read below
            // would simply block the way it did before `--timeout` existed.
            drop(stream.set_read_timeout(Some(timeout)));
            drop(stream.set_write_timeout(Some(timeout)));
        }
        Ok(stream)
    }
}

impl Control for SocketControl {
    fn call(&mut self, method: &str, params: Params) -> Result<Params, Failure> {
        let line = encode_request_line("1", method, params);
        let response = self.send_request(&line)?;
        let object = decode_response_line(&response).ok_or_else(|| {
            Failure::no_app(format!("malformed response from the SlopDesk app: {response}"))
        })?;
        require_ok(&object)
    }
}

impl SocketControl {
    /// Sends `request_line` and a terminating LF, then reads back one LF-terminated line.
    ///
    /// # Errors
    /// A connect, write or read failure, a timeout, or a response that is not valid UTF-8 — all of
    /// them exit 3, because from a script's side they are the same event: the app did not answer.
    pub fn send_request(&self, request_line: &str) -> Result<String, Failure> {
        let mut stream = self.connect()?;
        write_line(&mut stream, request_line)
            .map_err(|error| Failure::no_app(format!("write to control socket failed: {error}")))?;

        let reader = stream
            .try_clone()
            .map_err(|error| Failure::no_app(format!("dup socket: {error}")))?;
        let mut buffer = Vec::new();
        BufReader::new(reader)
            .take(MAX_RESPONSE_BYTES)
            .read_until(b'\n', &mut buffer)
            .map_err(|error| {
                if is_timeout(&error) {
                    Failure::no_app(format!(
                        "timed out after {}ms waiting for the SlopDesk app",
                        self.timeout_ms
                    ))
                } else {
                    Failure::no_app(format!("read from control socket failed: {error}"))
                }
            })?;

        if buffer.last() == Some(&b'\n') {
            buffer.truncate(buffer.len().saturating_sub(1));
        }
        String::from_utf8(buffer)
            .map_err(|_| Failure::no_app("response from the SlopDesk app is not valid UTF-8"))
    }
}

/// Connect and write ONE line, ignoring whatever the far end answers.
///
/// The `-e <cmd>` forward, and the only caller that wants this shape: the GUI is already up, which
/// is the xterm-compat guarantee, so every failure here is a `false` the caller retries rather than
/// a [`Failure`] it reports. Reading a response would also be wrong on its own terms — the app is
/// still building its first window, and the forward is fire-and-forget by design.
#[must_use]
pub fn deliver(socket_path: &str, request_line: &str) -> bool {
    if socket_path.len() > MAX_SOCKET_PATH {
        return false;
    }
    UnixStream::connect(socket_path)
        .and_then(|mut stream| write_line(&mut stream, request_line))
        .is_ok()
}

/// Whether a read error is the socket timeout rather than a real I/O failure.
///
/// Darwin reports a `SO_RCVTIMEO` expiry as `EAGAIN`, which Rust maps to `WouldBlock`; the
/// `TimedOut` arm is there because the mapping is not promised to stay that way.
fn is_timeout(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    )
}

/// Writes `line` and a terminating LF, retrying a short write until the whole line is out.
///
/// # Errors
/// Any write failure.
pub fn write_line(sink: &mut impl Write, line: &str) -> Result<(), std::io::Error> {
    let mut payload = line.to_owned();
    if !payload.ends_with('\n') {
        payload.push('\n');
    }
    // `write_all` already retries on a short write and on EINTR, which is what the Swift's manual
    // offset loop was doing by hand.
    sink.write_all(payload.as_bytes())
}

/// Requires an `ok:true` response and hands back its `result` object.
///
/// # Errors
/// The app's own error message, at exit 1: the app was reachable and refused, which is a different
/// event from "there is no app" and a script wants to tell them apart.
pub fn require_ok(object: &Params) -> Result<Params, Failure> {
    if object.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return Ok(object
            .get("result")
            .and_then(serde_json::Value::as_object)
            .cloned()
            .unwrap_or_default());
    }
    let message = object
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("(no error message)");
    Err(Failure::plain(format!("app error: {message}")))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use serde_json::{Map, Value};

    use super::{MAX_SOCKET_PATH, SocketControl, require_ok, resolve_socket_path, write_line};
    use crate::args::Invocation;
    use crate::shell::{Ctx, EXIT_NO_APP, Environment, SOCKET_ENV};

    fn ctx(socket_flag: Option<&str>, pairs: &[(&str, &str)]) -> Ctx {
        Ctx {
            invocation: Invocation {
                socket_path: socket_flag.map(str::to_owned),
                ..Invocation::default()
            },
            environment: Environment::from_pairs(pairs),
            program: "slopdesk".to_owned(),
        }
    }

    #[test]
    fn the_socket_flag_outranks_the_environment_and_the_environment_outranks_the_default() {
        assert_eq!(
            resolve_socket_path(&ctx(Some("/tmp/flag.sock"), &[(SOCKET_ENV, "/tmp/env.sock")])),
            "/tmp/flag.sock"
        );
        assert_eq!(
            resolve_socket_path(&ctx(None, &[(SOCKET_ENV, "/tmp/env.sock")])),
            "/tmp/env.sock"
        );
        assert_eq!(
            resolve_socket_path(&ctx(None, &[("HOME", "/Users/x")])),
            "/Users/x/Library/Application Support/SlopDesk/cli-control.sock"
        );
    }

    /// The app resolves its default from `$HOME` too, and does NOT honour the app-support override
    /// — so neither may this, or the two name different files and every verb exits 3.
    #[test]
    fn the_default_ignores_the_app_support_override_the_way_the_app_does() {
        let path = resolve_socket_path(&ctx(None, &[
            ("HOME", "/Users/x"),
            ("SLOPDESK_APP_SUPPORT_DIR", "/tmp/container"),
        ]));
        assert_eq!(
            path,
            "/Users/x/Library/Application Support/SlopDesk/cli-control.sock"
        );
    }

    #[test]
    fn an_over_long_path_is_refused_by_name_before_any_syscall() {
        let long = format!("/tmp/{}", "a".repeat(MAX_SOCKET_PATH));
        let control = SocketControl {
            socket_path: long.clone(),
            timeout_ms: 3000,
        };
        let failure = control.send_request("{}").expect_err("the path is over the cap");
        assert_eq!(failure.message, format!("socket path too long: {long}"));
    }

    /// The message a script sees when `SlopDesk` is not running, and the code it branches on.
    #[test]
    fn a_missing_socket_says_to_start_the_app_and_exits_three() {
        let control = SocketControl {
            socket_path: "/tmp/slopdesk-no-such-cli-socket.sock".to_owned(),
            timeout_ms: 3000,
        };
        let failure = control.send_request("{}").expect_err("nothing is listening");
        assert_eq!(failure.code, EXIT_NO_APP);
        assert!(
            failure.message.starts_with("requires a running SlopDesk app"),
            "{failure:?}"
        );
    }

    #[test]
    fn a_request_line_gets_exactly_one_terminator_however_it_arrived() {
        let mut sink = Vec::new();
        write_line(&mut sink, "{\"a\":1}").expect("writes");
        write_line(&mut sink, "{\"b\":2}\n").expect("writes");
        assert_eq!(String::from_utf8(sink).expect("utf8"), "{\"a\":1}\n{\"b\":2}\n");
    }

    #[test]
    fn an_ok_response_yields_its_result_and_a_refusal_yields_the_apps_own_words() {
        let mut ok = Map::new();
        drop(ok.insert("ok".to_owned(), Value::Bool(true)));
        let mut result = Map::new();
        drop(result.insert("path".to_owned(), Value::from("/tmp")));
        drop(ok.insert("result".to_owned(), Value::Object(result)));
        assert_eq!(
            require_ok(&ok).expect("ok").get("path").and_then(Value::as_str),
            Some("/tmp")
        );

        // `ok:true` with no result at all is an empty answer, not a failure — several verbs are
        // silent on success.
        let mut bare = Map::new();
        drop(bare.insert("ok".to_owned(), Value::Bool(true)));
        assert!(require_ok(&bare).expect("ok").is_empty());

        let mut refused = Map::new();
        drop(refused.insert("ok".to_owned(), Value::Bool(false)));
        drop(refused.insert("error".to_owned(), Value::from("no such pane")));
        let failure = require_ok(&refused).expect_err("refused");
        assert_eq!(
            failure.code, 1,
            "the app answered — that is not a transport failure"
        );
        assert_eq!(failure.message, "app error: no such pane");

        // A response with no verdict at all is a refusal too, and says so rather than reading as ok.
        let failure = require_ok(&Map::new()).expect_err("no verdict");
        assert_eq!(failure.message, "app error: (no error message)");
    }
}
