//! What a dialler puts on the wire before anything else does: two sockets, 34 bytes.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.2. Checked against a bare `TcpListener` rather than
//! against `slopdesk-hostnet`, on purpose: this crate must not depend on the host's, not even for a
//! test, or the dependency direction its own manifest argues for would only be true in release
//! builds. What the listener does here is what `docs/20` says a listener does — read 17 bytes and
//! believe them — so the two ends are pinned to the format rather than to each other's code.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::Read as _;
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

use slopdesk_clientnet::dial::{Endpoint, dial};
use slopdesk_muxnet::preamble::{ConnectionId, Lane, PREAMBLE_BYTE_COUNT, Preamble, decode};

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

const ID: [u8; 16] = [0xAB; 16];

fn read_preamble(socket: &mut TcpStream) -> Preamble {
    socket
        .set_read_timeout(Some(GENEROUS))
        .expect("bound the read so a missing preamble fails rather than hangs");
    let mut bytes = [0_u8; PREAMBLE_BYTE_COUNT];
    socket
        .read_exact(&mut bytes)
        .expect("the dialler wrote its preamble");
    decode(&bytes).expect("the preamble decodes")
}

/// The pairing contract, from the side that has to be believed: two sockets, the SAME id, DIFFERENT
/// lanes, CONTROL first. An id that differed would leave both halves parked in the host's pending
/// map until the reaper closed them, which is a connect that fails fifteen seconds later for no
/// visible reason.
#[test]
fn both_sockets_announce_the_same_connection_on_their_own_lanes() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind a listener");
    let port = listener.local_addr().expect("local addr").port();
    let target = Endpoint::new("127.0.0.1", port);

    let dialler = std::thread::spawn(move || dial(&target, ConnectionId::from_bytes(ID), GENEROUS));

    let (mut first, _from) = listener.accept().expect("accept the CONTROL dial");
    let control = read_preamble(&mut first);
    let (mut second, _also) = listener.accept().expect("accept the DATA dial");
    let data = read_preamble(&mut second);

    let pair = dialler
        .join()
        .expect("the dialler thread panicked")
        .expect("the dial");
    assert_eq!(control.lane, Lane::Control, "CONTROL is dialled first");
    assert_eq!(data.lane, Lane::Data);
    assert_eq!(control.connection, ConnectionId::from_bytes(ID));
    assert_eq!(
        data.connection, control.connection,
        "the two halves named one connection"
    );
    assert_eq!(
        pair.connection, control.connection,
        "the pair carries the id it announced"
    );
}

/// A dial to nowhere ends, and ends BY the bound it was given.
///
/// `NWConnection` parks in `.waiting` forever on an unreachable host, which is why the Swift
/// wrapped the whole establishment in a task-group race. Here the bound is an argument to
/// `connect_timeout`, and this test is the reason that difference is worth a paragraph: a connect
/// that cannot fail is a UI stuck at "connecting" with nothing to cancel it.
#[test]
fn an_unreachable_endpoint_fails_inside_its_own_deadline() {
    // TEST-NET-1 (RFC 5737): reserved for documentation, so it is not routed anywhere. Either the
    // stack answers "no route" at once or the SYN goes unanswered and the deadline ends it — both
    // are this test passing, because both are a bounded failure.
    let unreachable = Endpoint::new("192.0.2.1", 9);
    let bound = Duration::from_millis(300);

    let started = Instant::now();
    let outcome = dial(&unreachable, ConnectionId::from_bytes(ID), bound);
    let waited = started.elapsed();

    assert!(outcome.is_err(), "a documentation address answered a dial");
    assert!(
        waited < GENEROUS / 2,
        "the dial outlived its bound by far: {waited:?}"
    );
}

/// An endpoint that resolves to nothing is reported rather than silently treated as a connect that
/// never happened — the caller is reconnecting on this answer, so "no address" and "refused" must
/// both be errors it sees.
#[test]
fn an_endpoint_that_resolves_to_nothing_is_an_error() {
    let nowhere = Endpoint::new("this-host-does-not-exist.invalid", 1);
    assert!(dial(&nowhere, ConnectionId::from_bytes(ID), GENEROUS).is_err());
}

/// A failing dial leaks no descriptor.
///
/// The Swift needed a `catch` holding both `NWConnection`s to cancel them, and its comment says
/// why: the caller of a throwing factory has no handle on the half-built sockets, so every retry
/// against a flaky host leaked one fd toward exhaustion. Here every socket is a local and `?` drops
/// it, so there is nothing to remember — which is why this counts descriptors rather than asserting
/// the shape of a `catch` that no longer exists. These dials fail at the CONTROL connect; the
/// half-built case is the SAME local dropped by the same `?` one line further down.
#[test]
fn a_batch_of_failed_dials_leaks_no_descriptor() {
    let refused = Endpoint::new("127.0.0.1", closed_port());
    // Warm up first: the resolver and the runtime open descriptors of their own on first use, and
    // those are a one-time cost rather than a leak.
    for _ in 0_u8..4 {
        drop(dial(&refused, ConnectionId::from_bytes(ID), GENEROUS));
    }
    let before = open_descriptor_count();
    for _ in 0_u8..16 {
        assert!(
            dial(&refused, ConnectionId::from_bytes(ID), GENEROUS).is_err(),
            "a closed port answered a dial"
        );
    }
    let after = open_descriptor_count();
    assert!(
        after <= before,
        "sixteen failed dials left descriptors behind: {before} → {after}"
    );
}

/// A port nothing is listening on: bound, read, and released.
fn closed_port() -> u16 {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind a listener");
    listener.local_addr().expect("local addr").port()
}

/// How many descriptors this process holds. `0` where neither directory exists, which makes the
/// assertion above vacuous rather than false on a platform that cannot answer.
fn open_descriptor_count() -> usize {
    ["/dev/fd", "/proc/self/fd"]
        .into_iter()
        .find_map(|directory| std::fs::read_dir(directory).ok())
        .map_or(0, Iterator::count)
}
