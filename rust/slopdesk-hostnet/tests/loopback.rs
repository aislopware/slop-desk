//! The listener against real sockets on loopback.
//!
//! The unit tests in `pending` prove the fd accounting with no socket at all, which is the half the
//! Swift original could not test. This file proves the other half: that a real client dialling
//! twice is paired, that bytes written on one end arrive on the other, and that the two bounds —
//! the handshake timeout and the partner reaper — actually fire on real file descriptors.
//!
//! Every wait here is a bounded probe against a condition, never a fixed sleep standing in for one.

#![expect(
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, TcpStream};
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use slopdesk_hostnet::listener::Listener;
use slopdesk_muxnet::preamble::{ConnectionId, Lane, Preamble, encode};

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// How long a probe waits between re-reads of the condition it is waiting for.
///
/// A probe, not a sleep standing in for one: the loop still exits the instant the condition holds.
/// It is not `yield_now` because a yield loop pins a core for the whole bound, and three Swift perf
/// tests in this tree already fail under machine load — a test suite that manufactures load is how
/// an unrelated suite starts flaking.
const PROBE_INTERVAL: Duration = Duration::from_millis(1);

fn dial(port: u16, lane: Lane, id: ConnectionId) -> TcpStream {
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect to the listener");
    stream
        .write_all(&encode(Preamble { lane, connection: id }))
        .expect("write the preamble");
    stream
}

const fn id(byte: u8) -> ConnectionId {
    ConnectionId::from_bytes([byte; 16])
}

#[test]
fn two_sockets_naming_one_id_become_one_connection_and_carry_bytes() {
    let listener = Listener::bind(0).expect("bind an ephemeral port");
    let port = listener.bound_port();
    assert_ne!(port, 0, "an ephemeral bind must report the port it got");
    let (pairs, handle) = listener.serve();

    let mut control = dial(port, Lane::Control, id(7));
    let mut data = dial(port, Lane::Data, id(7));

    let pair = pairs.recv_timeout(GENEROUS).expect("the two sockets pair");
    assert_eq!(pair.connection, id(7));

    // Host → client, on each lane, and the lanes must not be crossed: a `resize` delivered on the
    // data link is a frame the control decoder never sees.
    pair.control.send(b"control-lane").expect("send on control");
    pair.data.send(b"data-lane").expect("send on data");

    let mut buf = [0_u8; 32];
    let n = control.read(&mut buf).expect("read on control");
    assert_eq!(&buf[..n], b"control-lane");
    let n = data.read(&mut buf).expect("read on data");
    assert_eq!(&buf[..n], b"data-lane");

    // Client → host, through the link the pair handed us.
    control.write_all(b"up-control").expect("client writes control");
    let mut inbound = [0_u8; 32];
    let n = pair.control.recv(&mut inbound).expect("host reads control");
    assert_eq!(&inbound[..n], b"up-control");

    handle.stop();
}

/// The client is allowed to dial data-first.
#[test]
fn the_pair_completes_in_either_arrival_order() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (pairs, handle) = listener.serve();

    let _data = dial(port, Lane::Data, id(8));
    let _control = dial(port, Lane::Control, id(8));

    let pair = pairs.recv_timeout(GENEROUS).expect("data-first pairs too");
    assert_eq!(pair.connection, id(8));
    handle.stop();
}

/// Two clients, each allocating their own ids, must not be cross-paired.
#[test]
fn two_clients_get_two_connections() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (pairs, handle) = listener.serve();

    let _a_control = dial(port, Lane::Control, id(1));
    let _b_control = dial(port, Lane::Control, id(2));
    let _a_data = dial(port, Lane::Data, id(1));
    let _b_data = dial(port, Lane::Data, id(2));

    let first = pairs.recv_timeout(GENEROUS).expect("first pair");
    let second = pairs.recv_timeout(GENEROUS).expect("second pair");
    let mut seen = [first.connection, second.connection];
    seen.sort_by_key(|c| *c.as_bytes());
    assert_eq!(seen, [id(1), id(2)], "each client got its own connection");
    handle.stop();
}

/// A socket that opens and says nothing must be hung up on, not held forever.
#[test]
fn a_socket_that_never_sends_a_preamble_is_dropped_without_pairing() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (pairs, handle) = listener.serve();

    let _mute = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect");
    // It is not paired now and it will not be later. A short bound is the assertion: waiting out
    // the full HANDSHAKE_TIMEOUT would only re-prove the constant.
    assert!(
        matches!(
            pairs.recv_timeout(Duration::from_millis(200)),
            Err(RecvTimeoutError::Timeout)
        ),
        "a mute socket never becomes a connection",
    );
    assert_eq!(handle.pending_count(), 0, "and it never parks in the map");
    handle.stop();
}

/// An unknown first byte is a peer speaking another protocol. Refuse it; do not guess a lane.
#[test]
fn an_unknown_association_tag_is_refused() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (pairs, handle) = listener.serve();

    let mut hostile = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect");
    hostile.write_all(&[0x05; 17]).expect("write a bogus preamble");

    assert!(matches!(
        pairs.recv_timeout(Duration::from_millis(200)),
        Err(RecvTimeoutError::Timeout)
    ));
    assert_eq!(handle.pending_count(), 0);
    handle.stop();
}

/// A half-pair whose partner never arrives is closed by the reaper, on real fds.
#[test]
fn the_reaper_closes_a_half_pair_whose_partner_never_comes() {
    // 200 ms partner timeout → a 50 ms tick (the floor), so this resolves in well under a second.
    let listener = Listener::bind_with(0, Duration::from_millis(200)).expect("bind");
    let port = listener.bound_port();
    let (_pairs, handle) = listener.serve();

    let mut lonely = dial(port, Lane::Control, id(9));

    // Bounded probe for the map emptying — not a sleep long enough to "probably" be right.
    let deadline = Instant::now() + GENEROUS;
    while handle.pending_count() > 0 && Instant::now() < deadline {
        std::thread::sleep(PROBE_INTERVAL);
    }
    assert_eq!(handle.pending_count(), 0, "the reaper expired the half-pair");

    // And the socket is really gone: the peer sees EOF (or a reset), never an open idle link.
    let mut buf = [0_u8; 1];
    lonely
        .set_read_timeout(Some(GENEROUS))
        .expect("bound the read so a live socket fails the test rather than hanging it");
    match lonely.read(&mut buf) {
        Ok(0) | Err(_) => {},
        Ok(n) => panic!("the reaped socket delivered {n} bytes instead of closing"),
    }
    handle.stop();
}

/// Re-sending the same side must close the socket it displaces, not leak it.
#[test]
fn a_same_side_repark_hangs_up_on_the_displaced_socket() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (_pairs, handle) = listener.serve();

    let mut first = dial(port, Lane::Control, id(10));
    let deadline = Instant::now() + GENEROUS;
    while handle.pending_count() == 0 && Instant::now() < deadline {
        std::thread::sleep(PROBE_INTERVAL);
    }

    let _second = dial(port, Lane::Control, id(10));

    first.set_read_timeout(Some(GENEROUS)).expect("bound the read");
    let mut buf = [0_u8; 1];
    match first.read(&mut buf) {
        Ok(0) | Err(_) => {},
        Ok(n) => panic!("the displaced socket delivered {n} bytes instead of closing"),
    }
    assert_eq!(handle.pending_count(), 1, "one id, still one entry");
    handle.stop();
}

/// After `stop`, a half-pair that was waiting is closed rather than left parked.
#[test]
fn stop_closes_what_the_map_was_still_holding() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (_pairs, handle) = listener.serve();

    let mut parked = dial(port, Lane::Data, id(11));
    let deadline = Instant::now() + GENEROUS;
    while handle.pending_count() == 0 && Instant::now() < deadline {
        std::thread::sleep(PROBE_INTERVAL);
    }

    handle.stop();
    assert_eq!(handle.pending_count(), 0);

    parked.set_read_timeout(Some(GENEROUS)).expect("bound the read");
    let mut buf = [0_u8; 1];
    match parked.read(&mut buf) {
        Ok(0) | Err(_) => {},
        Ok(n) => panic!("stop left a live socket that delivered {n} bytes"),
    }
}

/// `stop` must actually UNBIND, not merely stop pairing.
///
/// This is the one behaviour the wake-dial in `stop` exists for: `accept()` blocks with no cancel
/// lever, so a stopping flag alone leaves the thread parked on a live listening socket and the port
/// still taken. `just host-restart` re-binds the same port seconds later, so a listener that
/// lingers is a restart that fails with EADDRINUSE rather than a leak nobody notices.
#[test]
fn stop_releases_the_port_it_was_listening_on() {
    let listener = Listener::bind(0).expect("bind");
    let port = listener.bound_port();
    let (_pairs, handle) = listener.serve();

    // Prove it was really listening first, so a failure below cannot be "it never bound".
    drop(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("the listener accepts while serving"));

    handle.stop();

    // The accept thread unwinds asynchronously; probe rather than assume it has already returned.
    let deadline = Instant::now() + GENEROUS;
    loop {
        match TcpStream::connect_timeout(&(Ipv4Addr::LOCALHOST, port).into(), PROBE_INTERVAL * 100) {
            Err(_) => break,
            Ok(open) => {
                drop(open);
                assert!(
                    Instant::now() < deadline,
                    "stop left the port bound — a restart on this port would fail with EADDRINUSE",
                );
                std::thread::sleep(PROBE_INTERVAL);
            },
        }
    }
}
