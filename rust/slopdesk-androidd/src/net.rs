//! The socket primitives the bridge is built out of, and the note on why they are blocking.
//!
//! The Android bridge carries no message protocol after its first line: it is a byte pump between
//! the client's socket and a socket `adb` forwarded from the device. Two things make blocking the
//! right shape, and both are awkward in a callback chain:
//!
//! 1. **Backpressure for free.** A blocking `write` that stalls stops the `read` above it, which
//!    stops draining `adb`'s socket, which backs the pressure up into the device's encoder — the
//!    same chain scrcpy itself relies on. A completion-callback send buffers instead, and a 2
//!    Mbit/s stream to a client that has stopped reading grows without bound until an explicit
//!    credit scheme is written, which is more code than the pump.
//! 2. **Connect-until-a-byte-arrives.** The `adb forward` tunnel accepts a TCP connection whether
//!    or not anything is listening on the far side, so the only proof the device's server is up is
//!    a byte read back from it (scrcpy's own `connect_and_read_byte`). That is a blocking retry
//!    loop by nature.
//!
//! The Swift original needed ~230 lines of `setsockopt`/`withUnsafePointer` for this, including a
//! hand-set `SO_NOSIGPIPE` on every descriptor — because the default disposition of `SIGPIPE` is to
//! KILL THE PROCESS, and a pump writes to peers that vanish. Rust's `std::net` sets that flag on
//! every socket it creates, so the entire class of bug is simply absent here.

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::time::Duration;

/// Connects to `127.0.0.1:port` with `timeout` on the connect AND on reads, or `None`.
///
/// Loopback only — this dials the tunnel `adb` opened on this machine, never a remote address.
#[must_use]
pub fn connect_loopback(port: u16, timeout: Duration) -> Option<TcpStream> {
    let address = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port));
    let stream = TcpStream::connect_timeout(&address, timeout).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    stream.set_write_timeout(Some(timeout)).ok()?;
    Some(stream)
}

/// Binds an ephemeral port on `0.0.0.0` and starts listening.
///
/// **No credential, by invariant** — every port this project opens is protected by the `WireGuard`
/// mesh and nothing else. It is worth being explicit that the bridge behind this one reaches `adb`:
/// on a host whose mesh is configured as documented that is the same trust boundary the terminal
/// wire already sits behind.
///
/// # Errors
/// Propagates the bind failure — the caller reports it and exits.
pub fn bind(port: u16) -> std::io::Result<TcpListener> {
    TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
}

/// Reads one `\n`-terminated line, byte at a time, up to `limit`.
///
/// Byte-at-a-time because the very next bytes after the newline may be the client's first control
/// messages, and a buffered read would swallow them into a buffer this function is about to
/// discard. The cap makes a peer that never sends a newline a bounded mistake rather than an
/// unbounded allocation.
#[must_use]
pub fn read_request_line(stream: &mut TcpStream, limit: usize) -> Option<Vec<u8>> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    while line.len() < limit {
        // Anything other than exactly one byte is EOF, a timeout or a transport fault, and all three
        // mean the same to a request line: there is no request.
        if !matches!(stream.read(&mut byte), Ok(1)) {
            return None;
        }
        let &first = byte.first()?;
        if first == b'\n' {
            return Some(line);
        }
        line.push(first);
    }
    None
}

/// Reads exactly `count` bytes, or `None` on EOF/error/timeout. Used for the handshake, where the
/// lengths are fixed and known.
#[must_use]
pub fn read_exactly(stream: &mut TcpStream, count: usize) -> Option<Vec<u8>> {
    let mut buffer = vec![0_u8; count];
    stream.read_exact(&mut buffer).ok().map(|()| buffer)
}

/// Pumps every byte from `source` into `sink` until either end stops.
///
/// The whole relay, in one function: a blocking read, a blocking write-all, and no buffer that
/// outlives the call. Whichever direction ends first, the caller closes both sockets, which
/// unblocks the other out of its `read` — there is no cancellation flag for a pump to poll.
pub fn pump(source: &mut TcpStream, sink: &mut TcpStream, chunk: usize) {
    let mut buffer = vec![0_u8; chunk];
    loop {
        let read = match source.read(&mut buffer) {
            Ok(0) | Err(_) => return,
            Ok(read) => read,
        };
        let Some(bytes) = buffer.get(..read) else {
            return;
        };
        if sink.write_all(bytes).is_err() {
            return;
        }
    }
}

/// Writes one framed reply line (`<json>\n`), reporting whether the peer took it.
pub fn write_line(stream: &mut TcpStream, line: &str) -> bool {
    stream.write_all(line.as_bytes()).is_ok() && stream.write_all(b"\n").is_ok()
}

/// Ends a socket in both directions. A blocked `read` on another thread returns immediately, which
/// is how a session is torn down without a flag the pump would have to check.
pub fn shutdown(stream: &TcpStream) {
    let _ignored = stream.shutdown(std::net::Shutdown::Both);
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::io::Write as _;
    use std::net::TcpStream;
    use std::time::Duration;

    use super::{bind, connect_loopback, read_exactly, read_request_line};

    /// A listener, and a connected pair of its two ends.
    fn pair() -> (TcpStream, TcpStream) {
        let listener = bind(0).expect("binds an ephemeral port");
        let port = listener.local_addr().expect("has an address").port();
        let client = connect_loopback(port, Duration::from_secs(2)).expect("dials");
        let (server, _address) = listener.accept().expect("accepts");
        (client, server)
    }

    #[test]
    fn a_request_line_stops_at_the_newline_and_leaves_the_rest() {
        let (mut client, mut server) = pair();
        client.write_all(b"{\"op\":\"list\"}\nRAWBYTES").expect("writes");
        let line = read_request_line(&mut server, 8192).expect("reads the line");
        assert_eq!(String::from_utf8_lossy(&line), "{\"op\":\"list\"}");
        // The bytes after the newline are still there — that is the point of reading one at a time.
        assert_eq!(
            read_exactly(&mut server, 8).map(|bytes| String::from_utf8_lossy(&bytes).into_owned()),
            Some("RAWBYTES".to_owned())
        );
    }

    #[test]
    fn a_peer_that_never_sends_a_newline_is_bounded_rather_than_unbounded() {
        let (mut client, mut server) = pair();
        client.write_all(&[b'x'; 64]).expect("writes");
        assert_eq!(read_request_line(&mut server, 16), None);
    }

    #[test]
    fn a_closed_peer_ends_the_line_read_rather_than_hanging() {
        let (client, mut server) = pair();
        drop(client);
        assert_eq!(read_request_line(&mut server, 8192), None);
    }
}
