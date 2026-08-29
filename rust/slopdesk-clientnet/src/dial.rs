//! Two sockets to one endpoint, each announcing which lane it is and which connection it joins.
//!
//! This is `LiveMuxConnectionFactory.makeConnection` and the half of `ChannelAssociation` that
//! WRITES. The Swift is 60 lines of task group; the work it does is four syscalls and 34 bytes.
//!
//! ## The timeout that was a task group
//!
//! `NWConnection` on an unreachable host parks in `.waiting` forever — `waitForConnectivity` has no
//! terminal state — so the Swift had to race the whole establishment against a `Task.sleep` in a
//! throwing task group, and then cancel the loser carefully enough that a half-open socket was not
//! leaked. [`std::net::TcpStream::connect_timeout`] is that bound as an argument, so the race, the
//! group, the cancellation and the `catch` that had to remember both sockets all go away together:
//! a half-built pair is closed by dropping it, which is the language's own guarantee rather than a
//! branch someone has to keep correct.
//!
//! ## Order matters, and it is the host's order
//!
//! CONTROL first, then DATA — `slopdesk_hostnet::pending` pairs them either way, but a listener
//! reading a CONTROL preamble first is what every host-side test and log was written against, and
//! there is no reason for the two ends to disagree about the normal case.

use std::io::{self, Write as _};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs as _};
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use slopdesk_muxnet::connection::{ConnectionThreads, MuxConnection, MuxEvent, PairedConnection};
use slopdesk_muxnet::link::{ByteLink, TcpByteLink};
use slopdesk_muxnet::params;
use slopdesk_muxnet::preamble::{ConnectionId, Lane, Preamble, encode};
use slopdesk_wire::mux::admission::Role;

/// One host's PATH-1 listener: what a pool is keyed on, and what a dial is aimed at.
///
/// The Swift keys its pool on the interpolated string `"\(host):\(port)"`. A struct instead,
/// because the key and the destination are the same fact and a string is the form in which they
/// drift — a pool keyed on text will happily hold two entries for one host that two callers spelled
/// differently.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Endpoint {
    /// A hostname or a literal address. Resolved at dial time, never cached.
    pub host: String,
    /// The port hostd published.
    pub port: u16,
}

impl Endpoint {
    /// The endpoint at `host:port`.
    #[must_use]
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
        }
    }
}

impl core::fmt::Display for Endpoint {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(formatter, "{}:{}", self.host, self.port)
    }
}

/// Dials `target` twice and announces both sockets as halves of `connection`.
///
/// `within` bounds the whole sequence — every `connect` and both preamble writes share one
/// deadline, so a host that accepts and then stops reading cannot hold the caller past it either.
///
/// The connection id is an ARGUMENT. Nothing in `rust/` mints identities: the crate that owns them
/// (`slopdesk-ids`) states the rule as "no clock and no randomness — every operation that needs a
/// fresh id takes it as an argument", and a transport that invented one would be the second place
/// entropy enters this tree.
///
/// # Errors
/// Whatever the socket layer reports, and [`io::ErrorKind::TimedOut`] when the deadline runs out.
/// On any error nothing is returned and both sockets are closed by being dropped — including the
/// CONTROL half when it is DATA that failed, which is the leak the Swift's `catch` was written for.
pub fn dial(target: &Endpoint, connection: ConnectionId, within: Duration) -> io::Result<PairedConnection> {
    let deadline = Instant::now() + within;
    // Resolution is blocking and is NOT covered by the deadline: `getaddrinfo` takes no timeout and
    // has its own resolver-level one. It is bounded in practice by the mesh's DNS, and the honest
    // alternative — a resolver thread that outlives the call — would be a thread leaked per dead
    // host, which is worse than the bound it buys.
    let addresses: Vec<SocketAddr> = (target.host.as_str(), target.port).to_socket_addrs()?.collect();

    let control = announce(&addresses, connection, Lane::Control, deadline, "control")?;
    let data = announce(&addresses, connection, Lane::Data, deadline, "data")?;
    Ok(PairedConnection {
        connection,
        control,
        data,
    })
}

/// A dialled connection, served: everything `MuxConnection::serve` hands back.
///
/// The three travel together because they are one lifetime — the events are the connection
/// speaking, and the threads are what has to unwind before the process may forget it.
#[derive(Debug)]
pub struct Dialled {
    /// The connection itself. This is what a pool holds.
    pub connection: Arc<MuxConnection>,
    /// Everything it will tell its owner: opens, closes, and the link dying.
    pub events: Receiver<MuxEvent>,
    /// Its two receive loops, to be joined after [`MuxConnection::close`].
    pub threads: ConnectionThreads,
}

/// [`dial`], then served as a client.
///
/// The one place in this crate that names a [`Role`]. Everything the connection does with it after
/// this is `slopdesk_wire::mux::admission`'s.
///
/// [`ConnectionRegistry`](crate::registry::ConnectionRegistry) does NOT call this itself: it pools
/// the connection and nothing else, because the events and the threads belong to whoever pumps them
/// — a session layer, not a map. That is the same seam the Swift drew by injecting
/// `makeConnection`, arrived at for a better reason than testability.
///
/// # Errors
/// Whatever [`dial`] reports.
pub fn establish(target: &Endpoint, connection: ConnectionId, within: Duration) -> io::Result<Dialled> {
    let pair = dial(target, connection, within)?;
    let (connection, events, threads) = MuxConnection::serve(pair, Role::Client);
    Ok(Dialled {
        connection,
        events,
        threads,
    })
}

/// One socket: connected, configured, and told which lane of which connection it is.
fn announce(
    addresses: &[SocketAddr],
    connection: ConnectionId,
    lane: Lane,
    deadline: Instant,
    label: &'static str,
) -> io::Result<Box<dyn ByteLink>> {
    let stream = connect(addresses, deadline)?;
    params::apply(&stream)?;
    // Bounded for the preamble alone, then cleared. A write timeout left in place would apply to
    // every bulk `channelData` send for the life of the link, turning a slow reader into a link
    // failure — but an UNBOUNDED preamble write is a peer that accepts and never reads holding this
    // thread forever, which is the same hang the connect timeout exists to prevent.
    stream.set_write_timeout(Some(remaining(deadline)?))?;
    (&stream).write_all(&encode(Preamble { lane, connection }))?;
    stream.set_write_timeout(None)?;
    Ok(Box::new(TcpByteLink::new(stream, label)))
}

/// Connects to the first address that answers before `deadline`.
///
/// A hostname can resolve to several addresses — v6 and v4 on a mesh routinely — and the deadline
/// is shared across the attempts rather than granted afresh to each, so a host with four dead
/// addresses cannot take four times as long as its caller asked for.
fn connect(addresses: &[SocketAddr], deadline: Instant) -> io::Result<TcpStream> {
    let mut refused = io::Error::new(
        io::ErrorKind::AddrNotAvailable,
        "the endpoint resolved to no address",
    );
    for address in addresses {
        match TcpStream::connect_timeout(address, remaining(deadline)?) {
            Ok(stream) => return Ok(stream),
            Err(failure) => refused = failure,
        }
    }
    Err(refused)
}

/// What is left of the deadline, or the timeout error itself once nothing is.
fn remaining(deadline: Instant) -> io::Result<Duration> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        // Zero is not "no timeout" to `connect_timeout` — it rejects it — and it IS "no timeout" to
        // `set_write_timeout`, which would be an unbounded write. Neither is what an elapsed
        // deadline means, so it is reported as what it is.
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "the mux connect deadline elapsed",
        ));
    }
    Ok(left)
}
