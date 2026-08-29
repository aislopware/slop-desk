//! The five behaviours the pool exists for, and the one race the port left standing.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.2. The connections are real — two loopback sockets
//! each, served as `Role::Client` — because what the pool decides is when a connection is BUILT and
//! when it is CLOSED, and a double that cannot die would answer the eviction question for free.
//!
//! What is faked is the DIALLER: the factory counts its calls and can be made slow or made to fail.
//! That is the seam the pool is constructed over anyway, so nothing here reaches around the type.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::{io, thread};

use slopdesk_clientnet::dial::Endpoint;
use slopdesk_clientnet::registry::{AcquireError, ConnectionRegistry};
use slopdesk_muxnet::connection::{
    ConnectionThreads, MuxConnection, MuxEvent, OpenRequest, PairedConnection,
};
use slopdesk_muxnet::link::TcpByteLink;
use slopdesk_muxnet::preamble::ConnectionId;
use slopdesk_wire::mux::admission::Role;

const fn request() -> OpenRequest {
    OpenRequest {
        session_id: [5; 16],
        last_received_seq: 0,
        channel_class: 0,
        initial_cwd: None,
    }
}

fn endpoint() -> Endpoint {
    Endpoint::new("host.under.test", 4242)
}

/// Everything one built connection keeps alive: the peer sockets it is talking to, and the threads
/// and event stream its owner would normally hold.
#[expect(
    dead_code,
    reason = "held to keep the sockets and the receive loops alive, never read"
)]
#[derive(Debug)]
struct Kept {
    peers: [TcpStream; 2],
    events: Receiver<MuxEvent>,
    threads: ConnectionThreads,
}

/// A pool whose dialler is counted, and can be made slow or made to fail.
struct Harness {
    registry: ConnectionRegistry,
    builds: Arc<AtomicUsize>,
    kept: Arc<Mutex<Vec<Kept>>>,
    refusing: Arc<AtomicUsize>,
}

impl Harness {
    fn new() -> Self {
        Self::with_build_delay(Duration::ZERO)
    }

    fn with_build_delay(delay: Duration) -> Self {
        let builds = Arc::new(AtomicUsize::new(0));
        let kept: Arc<Mutex<Vec<Kept>>> = Arc::new(Mutex::new(Vec::new()));
        let refusing = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&builds);
        let held = Arc::clone(&kept);
        let refuse = Arc::clone(&refusing);
        let registry = ConnectionRegistry::new(move |_target| {
            counted.fetch_add(1, Ordering::SeqCst);
            thread::sleep(delay);
            if refuse.load(Ordering::SeqCst) > 0 {
                refuse.fetch_sub(1, Ordering::SeqCst);
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionRefused,
                    "the harness refused",
                ));
            }
            let (peer_control, ours_control) = loopback_pair();
            let (peer_data, ours_data) = loopback_pair();
            let pair = PairedConnection {
                connection: ConnectionId::from_bytes([3; 16]),
                control: Box::new(TcpByteLink::new(ours_control, "test.control")),
                data: Box::new(TcpByteLink::new(ours_data, "test.data")),
            };
            let (connection, events, threads) = MuxConnection::serve(pair, Role::Client);
            if let Ok(mut held) = held.lock() {
                held.push(Kept {
                    peers: [peer_control, peer_data],
                    events,
                    threads,
                });
            }
            Ok(connection)
        });
        Self {
            registry,
            builds,
            kept,
            refusing,
        }
    }

    fn builds(&self) -> usize {
        self.builds.load(Ordering::SeqCst)
    }

    /// Makes the next `count` builds fail.
    fn refuse_next(&self, count: usize) {
        self.refusing.store(count, Ordering::SeqCst);
    }

    /// Closes the peer sockets of the connection built at `index`, which kills its links.
    fn kill(&self, index: usize) {
        // A shutdown from the peer side is what a mesh flap looks like to the connection under test:
        // both links end, and the pool has to notice without being told.
        if let Ok(kept) = self.kept.lock()
            && let Some(held) = kept.get(index)
        {
            for peer in &held.peers {
                drop(peer.shutdown(std::net::Shutdown::Both));
            }
        }
    }
}

fn loopback_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind loopback");
    let port = listener.local_addr().expect("local addr").port();
    let peer = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("dial loopback");
    let (ours, _from) = listener.accept().expect("accept the dial");
    (peer, ours)
}

/// Waits for `condition`, so a test never sleeps a fixed amount for something that has already
/// happened — and never passes by sleeping long enough on a slow machine.
fn eventually(what: &str, mut condition: impl FnMut() -> bool) {
    for _ in 0_u16..1000 {
        if condition() {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    panic!("waited ten seconds for: {what}");
}

/// THE reason the pool exists: panes to one host ride one mux. Two connections to one endpoint
/// would double the sockets, the threads and the keepalive traffic, and split the flow-control
/// windows that `docs/45` sizes per connection.
#[test]
fn panes_to_one_endpoint_share_one_connection() {
    let harness = Harness::new();
    let target = endpoint();

    let first = harness
        .registry
        .acquire(&target, &request())
        .expect("the first acquire");
    let second = harness
        .registry
        .acquire(&target, &request())
        .expect("the second acquire");

    assert_eq!(harness.builds(), 1, "the second pane dialled a second connection");
    assert!(Arc::ptr_eq(&first.connection, &second.connection));
    assert_ne!(
        first.channel.channel_id, second.channel.channel_id,
        "two panes, two channels"
    );
    assert_eq!(harness.registry.pooled_connection_count(), 1);
    assert_eq!(harness.registry.channel_count(&target), 2);
}

/// The refcount, from both ends: a connection survives a sibling's release and is retired by the
/// last one. A pool that tore down on the first release would disconnect every other pane on the
/// host; one that never tore down would hold a socket per host forever.
#[test]
fn the_connection_outlives_every_pane_but_the_last() {
    let harness = Harness::new();
    let target = endpoint();
    let first = harness
        .registry
        .acquire(&target, &request())
        .expect("the first acquire");
    let second = harness
        .registry
        .acquire(&target, &request())
        .expect("the second acquire");
    let connection = Arc::clone(&first.connection);

    harness.registry.release(&target, first.channel.channel_id);
    assert_eq!(harness.registry.channel_count(&target), 1);
    assert!(
        !connection.is_down(),
        "one pane closing took the shared connection with it"
    );
    assert_eq!(harness.registry.pooled_connection_count(), 1);

    harness.registry.release(&target, second.channel.channel_id);
    assert_eq!(harness.registry.pooled_connection_count(), 0);
    assert!(
        connection.is_down(),
        "the last release left the connection running"
    );
}

/// Concurrent first acquires must not each dial. The Swift coalesces on a shared `Task`; here they
/// wait on a condvar, and the property is the same one: N callers, one connection, none orphaned.
#[test]
fn concurrent_first_acquires_build_exactly_one_connection() {
    let harness = Arc::new(Harness::with_build_delay(Duration::from_millis(120)));
    let target = endpoint();

    let racers: Vec<_> = (0_u8..8)
        .map(|_| {
            let harness = Arc::clone(&harness);
            let target = target.clone();
            thread::spawn(move || {
                harness
                    .registry
                    .acquire(&target, &request())
                    .map(|acquired| acquired.connection)
            })
        })
        .collect();
    let mut connections = Vec::with_capacity(racers.len());
    for racer in racers {
        connections.push(racer.join().expect("a racer panicked").expect("its acquire"));
    }

    assert_eq!(
        harness.builds(),
        1,
        "the single-flight gate let a second dial through"
    );
    let first = connections.first().expect("eight acquires");
    for other in &connections {
        assert!(Arc::ptr_eq(first, other), "two racers got different connections");
    }
    assert_eq!(harness.registry.channel_count(&target), 8);
}

/// A pooled corpse must never be handed out. A link drop leaves the connection unusable but does
/// not remove it — a surviving sibling channel keeps the entry — so without eviction a reconnecting
/// pane opens a channel on a dead connection, forever.
#[test]
fn a_dead_pooled_connection_is_evicted_and_rebuilt() {
    let harness = Harness::new();
    let target = endpoint();
    let first = harness
        .registry
        .acquire(&target, &request())
        .expect("the first acquire");
    let corpse = Arc::clone(&first.connection);

    harness.kill(0);
    eventually("the connection to notice its links died", || corpse.is_down());

    let second = harness
        .registry
        .acquire(&target, &request())
        .expect("the acquire after the drop");
    assert_eq!(
        harness.builds(),
        2,
        "the pool handed out the corpse instead of rebuilding"
    );
    assert!(!Arc::ptr_eq(&corpse, &second.connection));
    assert!(!second.connection.is_down());
    assert_eq!(
        harness.registry.pooled_connection_count(),
        1,
        "the corpse is still pooled"
    );
}

/// The connect-gate's whole lifecycle: pinned, an endpoint stays up with zero channels, and
/// unpinning retires it. Without the pin, closing the last pane would disconnect the app.
#[test]
fn a_pin_holds_an_endpoint_up_with_no_channels() {
    let harness = Harness::new();
    let target = endpoint();

    let pinned = harness.registry.pin(&target).expect("the pin");
    assert_eq!(harness.builds(), 1);
    assert_eq!(harness.registry.channel_count(&target), 0);
    assert!(harness.registry.is_alive(&target));

    // A pane arrives on the pinned connection and leaves again.
    let acquired = harness
        .registry
        .acquire(&target, &request())
        .expect("the acquire");
    assert!(
        Arc::ptr_eq(&pinned, &acquired.connection),
        "the pin was not reused"
    );
    harness.registry.release(&target, acquired.channel.channel_id);
    assert!(!pinned.is_down(), "the last release retired a PINNED connection");
    assert_eq!(harness.registry.pooled_connection_count(), 1);

    harness.registry.unpin(&target);
    assert!(
        pinned.is_down(),
        "unpinning left a channel-less connection running"
    );
    assert_eq!(harness.registry.pooled_connection_count(), 0);
    assert!(!harness.registry.is_alive(&target));
}

/// A failed dial pools nothing and — the part that is not obvious — leaves the endpoint buildable.
/// A single-flight gate that only cleared itself on success would hang every later acquire for that
/// endpoint on a condvar nobody will ever signal.
#[test]
fn a_failed_dial_pools_nothing_and_leaves_the_endpoint_buildable() {
    let harness = Harness::new();
    let target = endpoint();
    harness.refuse_next(1);

    match harness.registry.acquire(&target, &request()) {
        Err(AcquireError::Dial(failure)) => {
            assert_eq!(failure.kind(), io::ErrorKind::ConnectionRefused);
        },
        other => panic!("a refused dial was not reported as one: {other:?}"),
    }
    assert_eq!(harness.registry.pooled_connection_count(), 0);
    assert!(!harness.registry.is_alive(&target));

    let recovered = harness.registry.acquire(&target, &request()).expect("the retry");
    assert_eq!(harness.builds(), 2);
    assert!(!recovered.connection.is_down());
}

/// A pin whose dial fails leaves no pin behind, or the next release would find an endpoint pinned
/// by a connection that was never built and keep a rebuilt one alive forever.
#[test]
fn a_failed_pin_leaves_no_pin_behind() {
    let harness = Harness::new();
    let target = endpoint();
    harness.refuse_next(1);

    assert!(
        harness.registry.pin(&target).is_err(),
        "a refused dial was pinned"
    );

    let acquired = harness
        .registry
        .acquire(&target, &request())
        .expect("the acquire");
    let connection = Arc::clone(&acquired.connection);
    harness.registry.release(&target, acquired.channel.channel_id);
    assert!(
        connection.is_down(),
        "a stale pin kept the connection alive past its last channel"
    );
}
