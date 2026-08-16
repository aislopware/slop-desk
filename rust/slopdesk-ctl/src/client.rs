//! The socket end: dial the agent-control `AF_UNIX` listener, send one NDJSON line, read the
//! answer — or, for `subscribe`/`events`, keep reading until the host hangs up.
//!
//! The line-pump is generic over `BufRead`/`Write` so the streaming rules (skip a blank line, stop
//! on `closed`, surface an `ok: false`, drop an unterminated tail) are reachable from a unit test.
//! In the Swift original that loop was inlined next to the `connect(2)` call and could only be
//! reviewed, never run.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;

use crate::protocol::decode_response_line;

/// The longest path an `AF_UNIX` address can carry on Darwin.
///
/// `sockaddr_un.sun_path` is 104 bytes and one of them is the terminator. Checked before the
/// syscall so the failure names the path rather than surfacing as a generic `EINVAL` from deep
/// inside `connect(2)`.
pub const MAX_SOCKET_PATH: usize = 103;

/// The ceiling on one response line.
///
/// Generous — a `read --full` answer carries a whole scrollback ring — but finite, so a host that
/// never sends its LF cannot make the CLI consume memory until the machine notices.
pub const MAX_RESPONSE_BYTES: u64 = 64 * 1024 * 64;

/// The ceiling on one streamed event line.
///
/// `subscribe` runs for as long as a pane lives, so this is the bound that stops a single
/// malformed frame from growing without end.
const MAX_EVENT_LINE_BYTES: usize = 16 * 1024 * 1024;

/// Opens a connection to the control socket.
///
/// # Errors
/// A path over [`MAX_SOCKET_PATH`], or any `connect(2)` failure, as the message `die` will print.
pub fn connect(socket_path: &str) -> Result<UnixStream, String> {
    if socket_path.len() > MAX_SOCKET_PATH {
        return Err(format!("socket path too long: {socket_path}"));
    }
    UnixStream::connect(socket_path).map_err(|err| format!("connect '{socket_path}': {err}"))
}

/// Sends `request_line` (an LF is appended when missing) and reads back one response line, with the
/// trailing LF removed.
///
/// # Errors
/// A connect failure, a write failure, or a response that is not valid UTF-8.
pub fn send_request(socket_path: &str, request_line: &str) -> Result<String, String> {
    let mut stream = connect(socket_path)?;
    write_line(&mut stream, request_line)?;

    let mut buffer = Vec::new();
    BufReader::new(stream.try_clone().map_err(|err| format!("dup socket: {err}"))?)
        .take(MAX_RESPONSE_BYTES)
        .read_until(b'\n', &mut buffer)
        .map_err(|err| format!("read from socket failed: {err}"))?;

    if buffer.last() == Some(&b'\n') {
        buffer.pop();
    }
    String::from_utf8(buffer).map_err(|_| "response from host is not valid UTF-8".to_owned())
}

/// Writes `line` and a terminating LF, retrying a short write until the whole line is out.
///
/// # Errors
/// Any write failure, as the message `die` will print.
pub fn write_line(sink: &mut impl Write, line: &str) -> Result<(), String> {
    let mut payload = line.to_owned();
    if !payload.ends_with('\n') {
        payload.push('\n');
    }
    // `write_all` already retries on a short write and on EINTR, which is what the Swift's manual
    // offset loop was doing by hand.
    sink.write_all(payload.as_bytes())
        .map_err(|err| format!("write to socket failed: {err}"))
}

/// Streams NDJSON event lines from `reader` to `sink` until the host hangs up.
///
/// Returns the process exit code: `0` for both a `{"event":"closed"}` line and a plain hang-up
/// (a host that restarted mid-stream is not the caller's failure).
///
/// # Errors
/// A read failure, or an `{"ok":false}` response — the host refusing the subscription, e.g. for a
/// pane that does not exist.
pub fn pump_events(mut reader: impl BufRead, sink: &mut (impl Write + ?Sized)) -> Result<u8, String> {
    let mut buffer = Vec::new();
    loop {
        buffer.clear();
        let read = (&mut reader)
            .take(MAX_EVENT_LINE_BYTES as u64)
            .read_until(b'\n', &mut buffer)
            .map_err(|err| format!("read from socket failed: {err}"))?;
        if read == 0 {
            // The host closed without a `closed` event — a restart, most likely. Not an error.
            return Ok(0);
        }
        if buffer.last() == Some(&b'\n') {
            buffer.pop();
        } else {
            // An unterminated tail is a fragment of a line the host never finished. Dropping it is
            // what the Swift's "scan for the next LF" loop did, and printing it would hand the
            // caller half a JSON object to parse.
            return Ok(0);
        }
        // A line that is not UTF-8 is dropped rather than printed: the caller parses these.
        let Ok(line) = std::str::from_utf8(&buffer) else {
            continue;
        };
        if line.is_empty() {
            continue;
        }
        writeln!(sink, "{line}").map_err(|err| format!("write to stdout failed: {err}"))?;

        if let Some(obj) = decode_response_line(line) {
            if obj.get("event").and_then(serde_json::Value::as_str) == Some("closed") {
                return Ok(0);
            }
            if obj.get("ok").and_then(serde_json::Value::as_bool) == Some(false) {
                let message = obj
                    .get("error")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("(no error)");
                return Err(format!("subscribe: {message}"));
            }
        }
    }
}

/// Opens the socket, sends a `subscribe` request and pumps its events to `sink`.
///
/// # Errors
/// Anything [`connect`], [`write_line`] or [`pump_events`] can fail with.
pub fn stream_subscribe(
    socket_path: &str,
    request_line: &str,
    sink: &mut (impl Write + ?Sized),
) -> Result<u8, String> {
    let mut stream = connect(socket_path)?;
    write_line(&mut stream, request_line)?;
    // The host never reads this fd again after accepting, so there is nothing to half-close for.
    let reader = BufReader::new(stream.try_clone().map_err(|err| format!("dup socket: {err}"))?);
    pump_events(reader, sink)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::Cursor;

    use super::{connect, pump_events, write_line};

    fn pump(input: &str) -> (Result<u8, String>, String) {
        let mut out = Vec::new();
        let result = pump_events(Cursor::new(input.as_bytes().to_vec()), &mut out);
        (
            result,
            String::from_utf8(out).expect("the pump only writes what it read as UTF-8"),
        )
    }

    #[test]
    fn every_event_line_is_echoed_until_the_closed_one_ends_the_stream() {
        let (code, out) =
            pump("{\"event\":\"output\",\"text\":\"a\"}\n{\"event\":\"closed\"}\n{\"event\":\"never\"}\n");
        assert_eq!(code, Ok(0));
        assert_eq!(
            out, "{\"event\":\"output\",\"text\":\"a\"}\n{\"event\":\"closed\"}\n",
            "nothing after `closed` is read"
        );
    }

    #[test]
    fn a_plain_hangup_is_a_clean_exit_because_a_restarted_host_is_not_a_caller_error() {
        let (code, out) = pump("{\"event\":\"output\",\"text\":\"a\"}\n");
        assert_eq!(code, Ok(0));
        assert_eq!(out, "{\"event\":\"output\",\"text\":\"a\"}\n");
    }

    #[test]
    fn a_refusal_is_surfaced_after_the_line_that_carried_it() {
        let (code, out) = pump("{\"ok\":false,\"error\":\"pane not found\"}\n");
        assert_eq!(code, Err("subscribe: pane not found".to_owned()));
        assert_eq!(
            out, "{\"ok\":false,\"error\":\"pane not found\"}\n",
            "the raw line is still printed"
        );
    }

    #[test]
    fn a_refusal_with_no_message_still_names_itself() {
        let (code, _) = pump("{\"ok\":false}\n");
        assert_eq!(code, Err("subscribe: (no error)".to_owned()));
    }

    #[test]
    fn a_blank_line_is_skipped_rather_than_echoed() {
        let (code, out) = pump("\n\n{\"event\":\"closed\"}\n");
        assert_eq!(code, Ok(0));
        assert_eq!(out, "{\"event\":\"closed\"}\n");
    }

    #[test]
    fn an_unterminated_tail_is_dropped_rather_than_handed_over_half_parsed() {
        let (code, out) = pump("{\"event\":\"output\"}\n{\"event\":\"out");
        assert_eq!(code, Ok(0));
        assert_eq!(out, "{\"event\":\"output\"}\n");
    }

    #[test]
    fn a_non_json_line_is_echoed_but_decides_nothing() {
        // The contract is "print the raw NDJSON line and let the caller parse it", so a line the
        // CLI cannot read is still the caller's to see.
        let (code, out) = pump("not json\n{\"event\":\"closed\"}\n");
        assert_eq!(code, Ok(0));
        assert_eq!(out, "not json\n{\"event\":\"closed\"}\n");
    }

    #[test]
    fn an_over_long_socket_path_is_refused_by_name_before_any_syscall() {
        let long = "/tmp/".to_owned() + &"a".repeat(200);
        let err = connect(&long).expect_err("the path is over the cap");
        assert_eq!(err, format!("socket path too long: {long}"));
    }

    #[test]
    fn a_missing_socket_names_the_path_it_could_not_reach() {
        let err = connect("/tmp/slopdesk-ctl-no-such-socket.sock").expect_err("nothing is listening");
        assert!(
            err.starts_with("connect '/tmp/slopdesk-ctl-no-such-socket.sock': "),
            "{err}"
        );
    }

    #[test]
    fn a_request_line_gets_exactly_one_terminator_however_it_arrived() {
        let mut sink = Vec::new();
        write_line(&mut sink, "{\"a\":1}").expect("writes");
        write_line(&mut sink, "{\"b\":2}\n").expect("writes");
        assert_eq!(String::from_utf8(sink).expect("utf8"), "{\"a\":1}\n{\"b\":2}\n");
    }
}
