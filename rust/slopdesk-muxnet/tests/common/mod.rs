//! One connection on two real loopback sockets, and the sockets the peer writes on.
//!
//! Shared by every integration test in this crate, because a second copy of a harness is a second
//! definition of what "a connection under test" means. Real sockets, not a double: the crate has an
//! in-memory link in `subchannel`'s unit tests for the questions that do not need one, and a
//! connection's whole job is two link threads, so these do.

// Every item here is used by BOTH test binaries. A helper only one of them needs lives in that
// binary instead: an integration test compiles this module fresh per binary, so an item used by one
// is dead code in the other, and a blanket `allow(dead_code)` to paper over that is exactly the
// stale opt-out `scoped-opt-outs` exists to refuse.
#![expect(
    clippy::expect_used,
    reason = "a failed setup step in a test is the failure report"
)]
// A test harness reached through `mod common;` is a private module in a binary that exports
// nothing, so `unreachable_pub` and `redundant_pub_crate` want opposite things from every item
// below. `pub` is the one the compiler accepts from both test binaries.
#![expect(
    unreachable_pub,
    reason = "a private module in a test binary that exports nothing"
)]

use std::io::Write as _;
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::mpsc::Receiver;
use std::time::Duration;

use slopdesk_muxnet::connection::{ConnectionThreads, MuxConnection, MuxEvent, PairedConnection};
use slopdesk_muxnet::link::TcpByteLink;
use slopdesk_muxnet::preamble::ConnectionId;
use slopdesk_wire::mux::admission::Role;

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
pub const GENEROUS: Duration = Duration::from_secs(10);

/// Long enough that a frame that WAS going to produce an effect has produced it.
///
/// Only ever used to prove an absence, or to force an ordering a test is about, so a false pass
/// here is a slow machine rather than a wrong answer — and the frame it waits on has already
/// crossed a loopback socket and been decoded.
pub const SETTLE: Duration = Duration::from_millis(250);

/// A connection at `role`, and the two peer sockets whose bytes reach it.
pub struct Wired {
    pub peer_control: TcpStream,
    pub peer_data: TcpStream,
    pub events: Receiver<MuxEvent>,
    pub connection: Arc<MuxConnection>,
    pub threads: ConnectionThreads,
}

impl Wired {
    pub fn up(role: Role) -> Self {
        let (peer_control, ours_control) = loopback_pair();
        let (peer_data, ours_data) = loopback_pair();
        let pair = PairedConnection {
            connection: ConnectionId::from_bytes([7; 16]),
            control: Box::new(TcpByteLink::new(ours_control, "test.control")),
            data: Box::new(TcpByteLink::new(ours_data, "test.data")),
        };
        let (connection, events, threads) = MuxConnection::serve(pair, role);
        Self {
            peer_control,
            peer_data,
            events,
            connection,
            threads,
        }
    }

    pub fn down(self) {
        self.connection.close();
        drop(self.peer_control);
        drop(self.peer_data);
        self.threads.join();
    }
}

/// Two ends of one real TCP connection: `(what the peer writes on, what the mux reads)`.
pub fn loopback_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind loopback");
    let port = listener.local_addr().expect("local addr").port();
    let peer = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("dial loopback");
    let (ours, _from) = listener.accept().expect("accept the dial");
    (peer, ours)
}

pub fn write_all(socket: &TcpStream, bytes: &[u8]) {
    let mut socket = socket;
    socket.write_all(bytes).expect("write to the peer socket");
}
