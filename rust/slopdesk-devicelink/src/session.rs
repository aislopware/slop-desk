//! The lifetime rules both lanes obey, written once: one reader thread, one writable clone of the
//! socket, and a teardown that cannot leave a callback running after the handle is gone.
//!
//! ## Why the dial happens on the reader thread
//!
//! The caller is a view model on the main thread, and a TCP connect over the mesh is a round trip.
//! `NWConnection.start` was asynchronous for the same reason, so nothing here changes what the
//! panel experiences: [`Session::open`] returns immediately and the first thing the sink hears is
//! either "connected" or "ended".
//!
//! ## The one ordering that matters
//!
//! [`Link::tear_down`] sets the flag BEFORE it shuts the socket down, and the reader checks the
//! flag after every wake. That is what makes a teardown mid-read deliver nothing: the `read`
//! returns zero because of the shutdown, the reader sees the flag, and it exits without wording an
//! ending that the caller already knows about. Doing it the other way round races — the reader can
//! wake from the shutdown, see a flag that is not set yet, and report a link failure for a socket
//! the caller closed on purpose.
//!
//! Dropping a [`Session`] tears down and then JOINS, so a caller that has dropped its handle can
//! rely on the sink never being called again. That is the same promise
//! `slopdesk_pane_driver_free` makes, and it is what lets the Swift face own its sink by reference
//! count rather than by a torn-down flag of its own.

use std::io;
use std::net::{Shutdown, TcpStream, ToSocketAddrs as _};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// How long a dial may take before it is called a failure.
///
/// Ten seconds because the peer is on the mesh and a `WireGuard` handshake plus a TCP one is the
/// worst honest case; past that the panel is better served by "the host could not be reached" than
/// by a spinner that never resolves.
pub const DIAL_TIMEOUT: Duration = Duration::from_secs(10);

/// The socket, and whether the caller has finished with it.
///
/// Every write goes through here rather than through a copy of the stream held by the reader,
/// because writes come from the caller's thread and reads from the session's — the `Mutex` is the
/// one place those two meet, and it is never held across a read.
#[derive(Debug, Default)]
pub struct Link {
    stream: Mutex<Option<TcpStream>>,
    torn: AtomicBool,
}

impl Link {
    /// A link with no socket yet.
    #[must_use]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Dial `host:port` with `TCP_NODELAY` set, or say why not.
    ///
    /// Nagle off is not a tuning choice here, it is the reason this path exists: the upstream
    /// traffic is a gesture message every few milliseconds during a drag, each one tens of bytes,
    /// and coalescing those into a delayed-ACK stall turns a drag into a stutter. The Swift lanes
    /// inherited it from `TransportParameters.makeTCP()`; there is no shared parameter object on
    /// this side, so it is set here, once, for both protocols.
    ///
    /// # Errors
    ///
    /// The last connect failure, or the resolver's — a name that answers no address is the
    /// `NotFound` this seeds, so the caller always has something to word.
    pub fn dial(host: &str, port: u16) -> io::Result<TcpStream> {
        let mut last = io::Error::new(io::ErrorKind::NotFound, "the host resolved to no addresses");
        for address in (host, port).to_socket_addrs()? {
            match TcpStream::connect_timeout(&address, DIAL_TIMEOUT) {
                Ok(stream) => {
                    // A failure to set it is not a reason to refuse the socket — it is a slower
                    // socket, not a broken one.
                    let _ignored = stream.set_nodelay(true);
                    return Ok(stream);
                },
                Err(error) => last = error,
            }
        }
        Err(last)
    }

    /// Take the writable clone of a socket the reader has just opened.
    ///
    /// `false` when the caller tore the session down while the dial was in flight — the socket is
    /// closed here rather than handed on, so a session nobody is listening to does not stay open.
    #[must_use]
    pub fn adopt(&self, stream: &TcpStream) -> bool {
        if self.torn.load(Ordering::Acquire) {
            return false;
        }
        let Ok(writable) = stream.try_clone() else {
            return false;
        };
        let Ok(mut slot) = self.stream.lock() else {
            return false;
        };
        *slot = Some(writable);
        true
    }

    /// Write every byte, or answer `false`.
    ///
    /// A write before the socket is up, or after it is gone, is DROPPED rather than queued. That is
    /// the rule both Swift lanes kept and the reason is the same for both: a gesture delivered late
    /// replays a tap the user has already moved on from, and a queue is how a reconnect ends with a
    /// backlog of them.
    pub fn write(&self, bytes: &[u8]) -> bool {
        use io::Write as _;
        if self.torn.load(Ordering::Acquire) {
            return false;
        }
        let Ok(mut slot) = self.stream.lock() else {
            return false;
        };
        let Some(stream) = slot.as_mut() else {
            return false;
        };
        stream.write_all(bytes).is_ok()
    }

    /// Whether the caller has finished with this link.
    #[must_use]
    pub fn is_torn(&self) -> bool {
        self.torn.load(Ordering::Acquire)
    }

    /// Finish with the link: mark it, then unblock whatever is parked in `read`.
    ///
    /// The order is the whole point — see the module header.
    pub fn tear_down(&self) {
        self.torn.store(true, Ordering::Release);
        if let Ok(mut slot) = self.stream.lock()
            && let Some(stream) = slot.take()
        {
            let _ignored = stream.shutdown(Shutdown::Both);
        }
    }
}

/// One socket's whole life: the link, and the thread reading it.
#[derive(Debug)]
pub struct Session {
    link: Arc<Link>,
    reader: Option<JoinHandle<()>>,
}

impl Session {
    /// Start a session. `body` runs on the new thread and owns the dial and the read loop.
    ///
    /// `name` names the thread, which is what a sample or a crash report prints — the two lanes and
    /// the bridge are told apart there and nowhere else.
    #[must_use]
    pub fn open<Body>(link: Arc<Link>, name: &'static str, body: Body) -> Self
    where
        Body: FnOnce(&Link) + Send + 'static,
    {
        let held = Arc::clone(&link);
        let reader = std::thread::Builder::new()
            .name(name.to_owned())
            .spawn(move || body(&held))
            .ok();
        Self { link, reader }
    }

    /// The link, for writing and for asking whether the caller is done.
    #[must_use]
    pub const fn link(&self) -> &Arc<Link> {
        &self.link
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.link.tear_down();
        if let Some(reader) = self.reader.take() {
            // A reader that panicked is already finished; the join answers the panic and there is
            // nothing left to do about it here.
            let _ignored = reader.join();
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(clippy::unwrap_used, reason = "a panic in a test is the failure report")]

    use std::io::{Read as _, Write as _};
    use std::net::{Ipv4Addr, TcpListener};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    use super::{Link, Session};

    /// A listener that accepts one connection and hands it back.
    fn listening() -> (TcpListener, u16) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        (listener, port)
    }

    #[test]
    fn a_dialled_socket_carries_bytes_both_ways_with_nagle_off() {
        let (listener, port) = listening();
        let server = std::thread::spawn(move || {
            let (mut peer, _) = listener.accept().unwrap();
            let mut seen = [0_u8; 5];
            peer.read_exact(&mut seen).unwrap();
            peer.write_all(b"pong!").unwrap();
            seen
        });

        let stream = Link::dial(&Ipv4Addr::LOCALHOST.to_string(), port).unwrap();
        assert!(stream.nodelay().unwrap(), "the drag path depends on this");
        let link = Link::new();
        assert!(link.adopt(&stream));
        assert!(link.write(b"ping!"));

        let mut reader = stream;
        let mut answer = [0_u8; 5];
        reader.read_exact(&mut answer).unwrap();
        assert_eq!(&answer, b"pong!");
        assert_eq!(&server.join().unwrap(), b"ping!");
    }

    #[test]
    fn a_write_before_the_socket_is_up_is_dropped_rather_than_queued() {
        let link = Link::new();
        assert!(!link.write(b"a gesture nobody will see"));
    }

    #[test]
    fn a_torn_link_refuses_the_socket_the_dial_was_still_fetching() {
        let (listener, port) = listening();
        let server = std::thread::spawn(move || listener.accept().map(|(peer, _)| peer));
        let stream = Link::dial(&Ipv4Addr::LOCALHOST.to_string(), port).unwrap();
        let link = Link::new();
        link.tear_down();
        assert!(!link.adopt(&stream));
        assert!(!link.write(b"x"));
        drop(server.join().unwrap());
    }

    /// The promise the Swift face's reference counting rests on: once the handle is gone, the sink
    /// is not called again, because the drop JOINED the thread that would have called it.
    #[test]
    fn dropping_the_session_unblocks_the_reader_and_joins_it() {
        let (listener, port) = listening();
        let server = std::thread::spawn(move || listener.accept().map(|(peer, _)| peer));
        let stream = Link::dial(&Ipv4Addr::LOCALHOST.to_string(), port).unwrap();
        let held = server.join().unwrap().unwrap();

        let ticks = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&ticks);
        let link = Link::new();
        assert!(link.adopt(&stream));
        let session = Session::open(link, "devicelink.test", move |link| {
            let mut reader = stream;
            let mut scratch = [0_u8; 64];
            loop {
                match std::io::Read::read(&mut reader, &mut scratch) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {},
                }
                if link.is_torn() {
                    break;
                }
            }
            counted.fetch_add(1, Ordering::Release);
        });

        let started = Instant::now();
        drop(session);
        assert_eq!(ticks.load(Ordering::Acquire), 1, "the drop joined the reader");
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "the shutdown unblocked the read"
        );
        drop(held);
    }
}
