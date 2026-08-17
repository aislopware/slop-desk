//! The TCP accept loop: one thread per connection, one [`DiskSink`] per connection.
//!
//! A thread that panics takes its own upload down and nothing else — the reason this crate builds
//! with `panic = "unwind"`. There is no shared mutable state at all: each connection owns its state
//! machine and its destinations, so the only thing two uploads can contend for is the disk.
//!
//! Framing is a blocking `read_exact` rather than the incremental splitter the Swift original
//! needed: `NWConnection` hands you arbitrary chunks on a callback, a blocking socket hands you
//! exactly what you ask for. A fault ends the connection, so there is no poisoned-decoder state to
//! carry — a stream whose frame boundaries are in doubt cannot be resynchronised onto attacker
//! bytes anyway.

use std::io::{BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};

use crate::protocol::{MAX_FRAME_PAYLOAD, Reply, decode_request, encode_reply_frame};
use crate::receive::{Effect, ReceiveLogic};
use crate::sink::DiskSink;

/// The marker hostd looks for when it re-learns the port of a dropd that survived its restart.
///
/// The service's own first words ARE the record — there is no state file and no port handshake, the
/// same discipline `SupervisedServiceProcess` applies to the panel backends (`docs/51` §6.7).
pub const ANNOUNCE_PREFIX: &str = "dropd: listening on 0.0.0.0:";

/// What the RUNNING build's version is prefixed with inside the announce parenthetical.
///
/// ## Why the version rides on this line rather than on the wire
/// This daemon is superd's child, not hostd's, and it survives a hostd restart — which is the whole
/// reason `ANNOUNCE_PREFIX` exists. hostd re-learns the port by reading this line back off the
/// retained ring, so it is already the one channel that carries facts about a dropd hostd did not
/// start. The running build's version is exactly such a fact, and putting it here means the adopt
/// path and the spawn path learn it the same way, with no handshake added to a wire that has none.
///
/// FIRST in the parenthetical and `v`-prefixed so the position is stable however the rest of that
/// text grows. Spelled identically in the other two announcing daemons and in
/// `SidecarAnnounce.versionMarker`; `scripts/check-supervisor.sh` ratchets all four.
pub const ANNOUNCE_VERSION_PREFIX: &str = "(v";

/// Binds the upload port.
///
/// # Errors
/// Propagates the bind failure — the caller reports it and exits, because a dropd that is not on
/// its port is a dropd no client can reach.
pub fn bind(port: u16) -> std::io::Result<TcpListener> {
    TcpListener::bind(("0.0.0.0", port))
}

/// Announces the bound port on stderr, in the shape hostd parses.
///
/// # Errors
/// Propagates the failure to read the listener's own address.
pub fn announce(listener: &TcpListener, drop_dir: &Path) -> std::io::Result<u16> {
    let port = listener.local_addr()?.port();
    eprintln!("{}", announce_line(port, drop_dir));
    Ok(port)
}

/// The exact line [`announce`] prints.
///
/// Split out so the shape hostd parses is a value a test can hold, rather than a side effect on a
/// file descriptor. `env!` reads THIS binary's compile-time version — never a number off disk.
#[must_use]
pub fn announce_line(port: u16, drop_dir: &Path) -> String {
    format!(
        "{ANNOUNCE_PREFIX}{port} {ANNOUNCE_VERSION_PREFIX}{}, drop dir {})",
        env!("CARGO_PKG_VERSION"),
        drop_dir.display(),
    )
}

/// Accepts connections until the process is killed.
///
/// # Errors
/// Propagates an accept failure that is not per-connection; a per-connection error is logged and
/// dropped.
pub fn serve(listener: &TcpListener, drop_dir: &Path) -> std::io::Result<()> {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let directory = drop_dir.to_path_buf();
                // A failed spawn (thread limit) costs this one connection, not the daemon.
                if let Err(error) = std::thread::Builder::new()
                    .name("dropd-conn".to_owned())
                    .spawn(move || handle_connection(stream, directory))
                {
                    eprintln!("dropd: cannot spawn connection thread: {error}");
                }
            },
            Err(error) => eprintln!("dropd: accept failed: {error}"),
        }
    }
    Ok(())
}

/// Serves one connection to completion (EOF, a decode fault, or a transport error).
///
/// Anything still open when this returns is swept by [`DiskSink`]'s `Drop`, so a dropped connection
/// leaves no partial file under any name.
fn handle_connection(stream: TcpStream, drop_dir: PathBuf) {
    // A small control frame (accept/complete) must not wait behind a body burst in Nagle's buffer.
    if let Err(error) = stream.set_nodelay(true) {
        eprintln!("dropd: cannot set TCP_NODELAY: {error}");
    }
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    // 256 KiB matches the client's chunk size, so a chunk is typically one read.
    let mut reader = BufReader::with_capacity(256 * 1024, read_half);
    let mut writer = stream;
    let mut logic = ReceiveLogic::new();
    let mut sink = DiskSink::new(drop_dir);
    // Transfers the SINK failed on. The client already has its `failed`, so a later `accept` or
    // `complete` for the same id must be suppressed rather than contradict it.
    let mut failed: Vec<u32> = Vec::new();

    loop {
        let body = match read_frame(&mut reader) {
            Ok(Some(body)) => body,
            Ok(None) => break, // clean EOF
            Err(error) => {
                eprintln!("dropd: read failed: {error}");
                break;
            },
        };
        let request = match decode_request(&body) {
            Ok(request) => request,
            Err(error) => {
                eprintln!("dropd: refusing a malformed frame: {error}");
                break;
            },
        };
        for effect in logic.handle(request) {
            if !execute(effect, &mut sink, &mut writer, &mut failed) {
                return;
            }
        }
    }
}

/// Runs one effect. Returns `false` when the connection can no longer be served.
fn execute(effect: Effect, sink: &mut DiskSink, writer: &mut TcpStream, failed: &mut Vec<u32>) -> bool {
    match effect {
        Effect::Open { transfer_id, name } => {
            if let Err(error) = sink.open(transfer_id, &name) {
                eprintln!("dropd: cannot open a destination: {error}");
                failed.push(transfer_id);
                sink.abort(transfer_id);
                return send(writer, &fail(transfer_id, "cannot open destination"));
            }
            true
        },
        Effect::Write { transfer_id, data } => {
            if failed.contains(&transfer_id) {
                return true;
            }
            if let Err(error) = sink.write(transfer_id, &data) {
                eprintln!("dropd: write failed: {error}");
                failed.push(transfer_id);
                sink.abort(transfer_id);
                return send(writer, &fail(transfer_id, "write failed"));
            }
            true
        },
        Effect::Finalize { transfer_id } => {
            if failed.contains(&transfer_id) {
                return true;
            }
            if let Err(error) = sink.finalize(transfer_id) {
                eprintln!("dropd: finalize failed: {error}");
                failed.push(transfer_id);
                sink.abort(transfer_id);
                return send(writer, &fail(transfer_id, "finalize failed"));
            }
            true
        },
        Effect::Abort { transfer_id } => {
            sink.abort(transfer_id);
            true
        },
        Effect::Send(reply) => {
            // Suppress a success for a transfer the sink already failed — the client got its
            // `failed` and must not also see an accept or a complete.
            let identifier = match reply {
                Reply::Accept { transfer_id } | Reply::Complete { transfer_id } => Some(transfer_id),
                Reply::HelloAck { .. } | Reply::Failed { .. } => None,
            };
            if identifier.is_some_and(|id| failed.contains(&id)) {
                return true;
            }
            send(writer, &reply)
        },
    }
}

fn fail(transfer_id: u32, reason: &str) -> Reply {
    Reply::Failed {
        transfer_id,
        reason: reason.to_owned(),
    }
}

/// Writes one reply. Returns `false` when the peer is gone.
fn send(writer: &mut TcpStream, reply: &Reply) -> bool {
    match writer.write_all(&encode_reply_frame(reply)) {
        Ok(()) => true,
        Err(error) => {
            eprintln!("dropd: write to the client failed: {error}");
            false
        },
    }
}

/// Reads one length-prefixed frame body, or `None` at a clean EOF.
fn read_frame(reader: &mut impl Read) -> std::io::Result<Option<Vec<u8>>> {
    let mut length = [0u8; 4];
    match reader.read_exact(&mut length) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let declared = u32::from_be_bytes(length) as usize;
    if declared > MAX_FRAME_PAYLOAD {
        // Validate-then-drop: refused BEFORE the allocation, which is the whole point of a cap.
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame of {declared} bytes"),
        ));
    }
    let mut body = vec![0u8; declared];
    reader.read_exact(&mut body)?;
    Ok(Some(body))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::Cursor;
    use std::path::Path;

    use super::{ANNOUNCE_PREFIX, ANNOUNCE_VERSION_PREFIX, announce_line, read_frame};
    use crate::protocol::MAX_FRAME_PAYLOAD;

    #[test]
    fn the_announce_line_still_leads_with_the_port_hostd_parses() {
        let line = announce_line(7411, Path::new("/tmp/drop"));
        let rest = line
            .strip_prefix(ANNOUNCE_PREFIX)
            .expect("the announce marker is the line's prefix");
        // hostd takes the digits directly after the marker as a run, so nothing may sit between.
        assert!(rest.starts_with("7411 "), "port must follow the marker: {line}");
    }

    #[test]
    fn the_announce_line_carries_the_running_builds_version_first_in_the_parenthetical() {
        let line = announce_line(7411, Path::new("/tmp/drop"));
        let at = line
            .find(ANNOUNCE_VERSION_PREFIX)
            .expect("the version marker is on the line");
        let after = line
            .get(at + ANNOUNCE_VERSION_PREFIX.len()..)
            .expect("the marker is not the line's tail");
        let version = after
            .split([',', ')'])
            .next()
            .expect("split always yields a first field");
        assert_eq!(version, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn a_clean_eof_is_none_rather_than_an_error() {
        let mut empty = Cursor::new(Vec::new());
        assert_eq!(read_frame(&mut empty).expect("reads"), None);
    }

    #[test]
    fn a_frame_is_read_whole_and_the_next_one_follows() {
        let mut stream = Vec::new();
        stream.extend_from_slice(&3u32.to_be_bytes());
        stream.extend_from_slice(b"abc");
        stream.extend_from_slice(&1u32.to_be_bytes());
        stream.extend_from_slice(b"z");
        let mut cursor = Cursor::new(stream);
        assert_eq!(read_frame(&mut cursor).expect("reads"), Some(b"abc".to_vec()));
        assert_eq!(read_frame(&mut cursor).expect("reads"), Some(b"z".to_vec()));
        assert_eq!(read_frame(&mut cursor).expect("reads"), None);
    }

    #[test]
    fn an_oversized_length_is_refused_before_it_allocates() {
        let mut stream = Vec::new();
        let over = u32::try_from(MAX_FRAME_PAYLOAD)
            .unwrap_or(u32::MAX)
            .saturating_add(1);
        stream.extend_from_slice(&over.to_be_bytes());
        let mut cursor = Cursor::new(stream);
        let error = read_frame(&mut cursor).expect_err("an over-cap length is refused");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn a_truncated_body_is_an_error_rather_than_a_short_frame() {
        let mut stream = Vec::new();
        stream.extend_from_slice(&8u32.to_be_bytes());
        stream.extend_from_slice(b"only4");
        let mut cursor = Cursor::new(stream);
        assert!(read_frame(&mut cursor).is_err());
    }
}
