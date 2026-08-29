//! A host on loopback, and a log of everything the driver said.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.5. The twelve Swift suites this replaces drove the
//! session actor through a FAKE transport — a protocol the driver itself defined, whose conformer
//! could answer any way the test liked. That is a weaker pin than it looks: a suite proving the
//! dedup could not tell you whether the bytes it deduped had ever been on a wire.
//!
//! Here the connection is real. Two loopback socket pairs are served as `Role::Client`, the far
//! ends are the test's, and a responder thread speaks mux frames the way `docs/20` says a host
//! does: it answers a `channelOpen` with a `channelOpenAck` and it writes `output` as
//! `channelData`. Nothing reaches around a type.
//!
//! The responder is hand-rolled rather than a `Role::Host` connection, for the reason
//! `slopdesk-clientnet`'s own suite gives: what these tests assert is frame-for-frame, and a second
//! `MuxConnection` in the way would decode and re-derive those frames before the assertion could
//! see them.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]
// A helper only one binary needs would be dead code in the other, because an integration test
// compiles this module fresh per binary. Each suite here uses a different slice of the host.
#![expect(dead_code, reason = "each test binary uses its own slice of the harness")]
// A test harness reached through `mod common;` is a private module in a binary that exports
// nothing, so `unreachable_pub` and `redundant_pub_crate` want opposite things from every item
// below. `pub` is the one the compiler accepts from every test binary.
#![expect(
    unreachable_pub,
    reason = "a private module in a test binary that exports nothing"
)]

use std::collections::VecDeque;
use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use std::{fmt, io};

use slopdesk_clientdriver::event::{Event, Observer};
use slopdesk_clientdriver::{DriverConfig, PaneDriver};
use slopdesk_clientnet::dial::Endpoint;
use slopdesk_clientnet::registry::ConnectionRegistry;
use slopdesk_muxnet::connection::{ConnectionThreads, MuxConnection, MuxEvent, PairedConnection};
use slopdesk_muxnet::link::TcpByteLink;
use slopdesk_muxnet::preamble::ConnectionId;
use slopdesk_wire::mux::admission::Role;
use slopdesk_wire::{FrameDecoder, MuxCloseReason, MuxFrame, MuxFrameDecoder, WireMessage};

/// Long enough that a loaded machine does not fail a suite, short enough that a real hang does.
pub const GENEROUS: Duration = Duration::from_secs(10);

/// How long a waiter sleeps between two looks at the thing it is waiting for.
///
/// The responder never BLOCKS for this long — its sockets are non-blocking and it sleeps between
/// turns rather than inside one. A responder that blocked on `read` while holding the host's lock
/// would hold it for all but a few microseconds of every turn, and `pthread`'s first-fit mutex is
/// not fair: a test thread asking for the same lock would starve for seconds behind it.
const POLL: Duration = Duration::from_millis(2);

/// A driver configured the way every suite here wants it: no campaign unless the suite asks, and
/// tickers slow enough that a test's assertions are not racing them.
pub const fn quiet_config() -> DriverConfig {
    DriverConfig {
        channel_class: 0,
        ack_interval: Duration::from_millis(5),
        ping_interval: Duration::from_secs(3_600),
        reconnect: None,
        resume_seed: None,
    }
}

// -- the observer --------------------------------------------------------------------------- //

/// One thing the driver said, owned so it outlives the borrow it arrived in.
#[derive(Debug, Clone, PartialEq)]
pub enum Seen {
    Message(WireMessage),
    RoundTrip(f64),
    Disconnected(String),
    Reconnected {
        session_id: [u8; 16],
        resume_from_seq: i64,
    },
    Retry {
        attempt: u32,
        delay_ms: u64,
    },
    GaveUp {
        attempts: u32,
    },
    Log(String),
}

/// The FFI door, shrunk to a log plus a wake counter.
///
/// ONE ordered `Vec` rather than a counter beside a queue, because most of what these suites assert
/// is about ORDER — that the exit was recorded before the event went out, that nothing follows a
/// disconnect — and two containers could not state it.
#[derive(Debug, Default)]
pub struct Recorder {
    seen: Mutex<Vec<Seen>>,
    wakes: AtomicI64,
}

impl Recorder {
    pub fn seen(&self) -> Vec<Seen> {
        self.seen.lock().map(|seen| seen.clone()).unwrap_or_default()
    }

    pub fn wakes(&self) -> i64 {
        self.wakes.load(Ordering::SeqCst)
    }

    /// Waits until `predicate` holds over the log, or gives up after [`GENEROUS`].
    pub fn wait_until(&self, what: &str, predicate: impl Fn(&[Seen]) -> bool) -> Vec<Seen> {
        let deadline = Instant::now() + GENEROUS;
        loop {
            let seen = self.seen();
            if predicate(&seen) {
                return seen;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}: {seen:?}"
            );
            thread::sleep(POLL);
        }
    }
}

impl Observer for Recorder {
    fn event(&self, event: &Event<'_>) {
        let seen = match *event {
            Event::Message(message) => Seen::Message(message.clone()),
            Event::RoundTrip(reading) => Seen::RoundTrip(reading),
            Event::Disconnected { reason } => Seen::Disconnected(reason.to_owned()),
            Event::Reconnected {
                session_id,
                resume_from_seq,
            } => {
                Seen::Reconnected {
                    session_id,
                    resume_from_seq,
                }
            },
            Event::Retry { attempt, delay_ms } => Seen::Retry { attempt, delay_ms },
            Event::GaveUp { attempts } => Seen::GaveUp { attempts },
            Event::Log(line) => Seen::Log(line.to_owned()),
            _ => return,
        };
        if let Ok(mut log) = self.seen.lock() {
            log.push(seen);
        }
    }

    fn output_ready(&self) {
        self.wakes.fetch_add(1, Ordering::SeqCst);
    }
}

// -- the host ------------------------------------------------------------------------------- //

/// The responder's end of ONE link: the socket, and every whole mux frame that came out of it.
#[derive(Debug)]
struct Lane {
    socket: TcpStream,
    decoder: MuxFrameDecoder,
    frames: Vec<MuxFrame>,
    ended: bool,
    /// One read buffer per lane, kept rather than made per turn: the responder pumps every
    /// [`POLL`], and a fresh 64 KiB allocation at that rate is noise this harness does not need.
    buffer: Box<[u8]>,
}

impl Lane {
    fn new(socket: TcpStream) -> Self {
        socket.set_nonblocking(true).expect("a non-blocking peer socket");
        Self {
            socket,
            decoder: MuxFrameDecoder::new(),
            frames: Vec::new(),
            ended: false,
            buffer: vec![0_u8; 64 * 1024].into_boxed_slice(),
        }
    }

    fn pump(&mut self) {
        let Self {
            socket,
            decoder,
            frames,
            ended,
            buffer,
        } = self;
        loop {
            match socket.read(buffer) {
                Ok(0) => {
                    *ended = true;
                    break;
                },
                Ok(read) => {
                    let Some(chunk) = buffer.get(..read) else { break };
                    decoder.append(chunk);
                },
                Err(ref failure)
                    if matches!(
                        failure.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                },
                Err(_) => {
                    *ended = true;
                    break;
                },
            }
        }
        while let Ok(Some(frame)) = decoder.next_frame() {
            frames.push(frame);
        }
    }

    /// Writes one whole frame, retrying the short writes a non-blocking socket is entitled to.
    ///
    /// `write_all` cannot be used here: on a socket that answers `WouldBlock` it reports the error
    /// and forgets how much it had already written, which would leave a half-frame on the wire and
    /// desynchronise the client's decoder for the rest of the test.
    fn send(&mut self, frame: &MuxFrame) {
        let bytes = frame.encode();
        let deadline = Instant::now() + GENEROUS;
        let mut written = 0_usize;
        while let Some(rest) = bytes.get(written..).filter(|rest| !rest.is_empty()) {
            match self.socket.write(rest) {
                Ok(0) => break,
                Ok(wrote) => written += wrote,
                Err(ref failure)
                    if matches!(
                        failure.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    assert!(Instant::now() < deadline, "the peer socket never drained");
                    thread::sleep(POLL);
                },
                Err(_) => break,
            }
        }
    }

    /// The inner `WireMessage`s this lane carried, reassembled across `channelData` boundaries.
    fn messages(&self) -> Vec<WireMessage> {
        let mut decoder = FrameDecoder::new();
        for frame in &self.frames {
            if matches!(*frame, MuxFrame::ChannelData { .. }) {
                decoder.append(frame.opaque_payload());
            }
        }
        let mut messages = Vec::new();
        while let Ok(Some(message)) = decoder.next_message() {
            messages.push(message);
        }
        messages
    }
}

/// What the host does with an arriving `channelOpen`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenPolicy {
    /// Accept, resuming from this seq. `0` is the fresh-shell answer.
    Accept(i64),
    /// Refuse the channel outright.
    Refuse,
    /// Say nothing, so the client's handshake bound is what ends the wait.
    Ignore,
}

/// What each DIAL's host is born answering with.
///
/// A redial builds a whole new `Host`, so [`Host::set_open_policy`] cannot reach it — it only
/// changes the host already in hand. The reconnect suites need exactly what it cannot say: accept
/// the first dial and refuse every one after it. The plan is read once per dial, so `scripted`
/// spends itself in dial order and `fallback` answers for every dial past the script.
#[derive(Debug)]
struct Plan {
    scripted: VecDeque<OpenPolicy>,
    fallback: OpenPolicy,
}

#[derive(Debug)]
struct Inner {
    control: Lane,
    data: Lane,
    opens: Vec<MuxFrame>,
    policy: OpenPolicy,
}

/// One connection's far end, pumped by its own thread.
#[derive(Debug)]
pub struct Host {
    inner: Mutex<Inner>,
    stop: AtomicBool,
}

impl Host {
    /// Every `channelOpen` this host has been shown, in order.
    pub fn opens(&self) -> Vec<MuxFrame> {
        self.locked(|inner| inner.opens.clone())
    }

    /// The channel id of the open at `index`.
    pub fn channel_id(&self, index: usize) -> u32 {
        match self.opens().get(index) {
            Some(&MuxFrame::ChannelOpen { channel_id, .. }) => channel_id,
            other => panic!("no open at {index}: {other:?}"),
        }
    }

    /// Every message the client sent, both lanes, in the order each lane carried them.
    pub fn received(&self) -> Vec<WireMessage> {
        self.locked(|inner| {
            let mut all = inner.control.messages();
            all.extend(inner.data.messages());
            all
        })
    }

    /// Waits until `predicate` holds over what the client sent.
    pub fn wait_received(&self, what: &str, predicate: impl Fn(&[WireMessage]) -> bool) -> Vec<WireMessage> {
        let deadline = Instant::now() + GENEROUS;
        loop {
            let received = self.received();
            if predicate(&received) {
                return received;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}: {received:?}"
            );
            thread::sleep(POLL);
        }
    }

    /// Waits until the client has opened at least `count` channels here.
    pub fn wait_opens(&self, count: usize) {
        let deadline = Instant::now() + GENEROUS;
        while self.opens().len() < count {
            assert!(Instant::now() < deadline, "timed out waiting for {count} open(s)");
            thread::sleep(POLL);
        }
    }

    /// Writes one host→client message onto the lane it belongs on.
    pub fn send(&self, message: &WireMessage) {
        let data = matches!(*message, WireMessage::Output { .. } | WireMessage::Exit { .. });
        let channel = self.channel_id(self.opens().len().saturating_sub(1));
        let frame = MuxFrame::ChannelData {
            channel_id: channel,
            payload: message.encode(),
        };
        self.locked(|inner| {
            if data {
                inner.data.send(&frame);
            } else {
                inner.control.send(&frame);
            }
        });
    }

    /// One `output`, on the windowed DATA lane.
    pub fn send_output(&self, seq: i64, bytes: &[u8]) {
        self.send(&WireMessage::Output {
            seq,
            bytes: bytes.to_vec(),
        });
    }

    /// Every window credit the client granted on this connection, summed over both lanes.
    ///
    /// The reconnect reset's whole hazard, in one number: bytes carried over from a channel that
    /// died must credit ZERO on the new one, whose peer never sent them. A grant larger than what
    /// this connection actually delivered is the phantom over-grant.
    pub fn credited(&self) -> u64 {
        self.locked(|inner| {
            inner
                .control
                .frames
                .iter()
                .chain(inner.data.frames.iter())
                .filter_map(|frame| {
                    match *frame {
                        MuxFrame::WindowAdjust { bytes_to_add, .. } => Some(u64::from(bytes_to_add)),
                        _ => None,
                    }
                })
                .sum()
        })
    }

    /// Closes the current channel from the host's side, with the reason it names.
    pub fn close_channel(&self, reason: MuxCloseReason) {
        let channel = self.channel_id(self.opens().len().saturating_sub(1));
        let frame = MuxFrame::ChannelClose {
            channel_id: channel,
            reason,
        };
        self.locked(|inner| {
            inner.data.send(&frame);
            inner.control.send(&frame);
        });
    }

    /// Drops both sockets, which is what a mesh path flap looks like from the client's end.
    pub fn cut_the_link(&self) {
        self.locked(|inner| {
            drop(inner.control.socket.shutdown(std::net::Shutdown::Both));
            drop(inner.data.socket.shutdown(std::net::Shutdown::Both));
        });
    }

    /// What this host does with the NEXT open.
    pub fn set_open_policy(&self, policy: OpenPolicy) {
        self.locked(|inner| inner.policy = policy);
    }

    fn locked<T>(&self, body: impl FnOnce(&mut Inner) -> T) -> T {
        body(&mut self.inner.lock().expect("the host's own lock"))
    }

    /// One turn of the responder: read what arrived, and answer any open that did.
    fn turn(&self) {
        self.locked(|inner| {
            inner.control.pump();
            inner.data.pump();
            let arrived: Vec<MuxFrame> = inner
                .control
                .frames
                .iter()
                .chain(inner.data.frames.iter())
                .filter(|frame| matches!(**frame, MuxFrame::ChannelOpen { .. }))
                .cloned()
                .collect();
            if arrived.len() <= inner.opens.len() {
                return;
            }
            let fresh: Vec<MuxFrame> = arrived.into_iter().skip(inner.opens.len()).collect();
            for open in fresh {
                let MuxFrame::ChannelOpen { channel_id, .. } = open else {
                    continue;
                };
                inner.opens.push(open.clone());
                match inner.policy {
                    OpenPolicy::Accept(resume_from_seq) => {
                        inner.control.send(&MuxFrame::ChannelOpenAck {
                            channel_id,
                            accepted: true,
                            resume_from_seq,
                        });
                    },
                    OpenPolicy::Refuse => {
                        inner.control.send(&MuxFrame::ChannelOpenAck {
                            channel_id,
                            accepted: false,
                            resume_from_seq: 0,
                        });
                    },
                    OpenPolicy::Ignore => {},
                }
            }
        });
    }
}

/// Everything one built connection keeps alive that no test reads.
#[expect(
    dead_code,
    reason = "held to keep the receive loops and their event stream alive, never read"
)]
#[derive(Debug)]
struct Kept {
    events: Receiver<MuxEvent>,
    threads: ConnectionThreads,
}

/// A pool whose dialler hands the test the far end of everything it builds.
pub struct Harness {
    pub registry: Arc<ConnectionRegistry>,
    hosts: Arc<Mutex<Vec<Arc<Host>>>>,
    pumps: Arc<Mutex<Vec<JoinHandle<()>>>>,
    stops: Arc<Mutex<Vec<Arc<Host>>>>,
    plan: Arc<Mutex<Plan>>,
    #[expect(dead_code, reason = "held to keep the receive loops alive, never read")]
    kept: Arc<Mutex<Vec<Kept>>>,
}

impl fmt::Debug for Harness {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("Harness").finish_non_exhaustive()
    }
}

impl Harness {
    /// A pool that answers every dial's first open with `policy`.
    pub fn new(policy: OpenPolicy) -> Self {
        Self::scripted(Vec::new(), policy)
    }

    /// A pool that answers dial `n` with `scripted[n]`, and every dial past the script with
    /// `fallback`. This is how a suite says "accept once, then never again".
    pub fn scripted(scripted: impl IntoIterator<Item = OpenPolicy>, fallback: OpenPolicy) -> Self {
        let plan = Arc::new(Mutex::new(Plan {
            scripted: scripted.into_iter().collect(),
            fallback,
        }));
        let dialling = Arc::clone(&plan);
        let hosts: Arc<Mutex<Vec<Arc<Host>>>> = Arc::new(Mutex::new(Vec::new()));
        let pumps: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::new(Mutex::new(Vec::new()));
        let stops: Arc<Mutex<Vec<Arc<Host>>>> = Arc::new(Mutex::new(Vec::new()));
        let kept: Arc<Mutex<Vec<Kept>>> = Arc::new(Mutex::new(Vec::new()));
        let far = Arc::clone(&hosts);
        let running = Arc::clone(&pumps);
        let stopping = Arc::clone(&stops);
        let held = Arc::clone(&kept);
        let registry = ConnectionRegistry::new(move |_target| {
            let (peer_control, ours_control) = loopback_pair();
            let (peer_data, ours_data) = loopback_pair();
            let pair = PairedConnection {
                connection: ConnectionId::from_bytes([3; 16]),
                control: Box::new(TcpByteLink::new(ours_control, "test.control")),
                data: Box::new(TcpByteLink::new(ours_data, "test.data")),
            };
            let (connection, events, threads) = MuxConnection::serve(pair, Role::Client);
            let policy = dialling.lock().map_or(fallback, |mut plan| {
                plan.scripted.pop_front().unwrap_or(plan.fallback)
            });
            let host = Arc::new(Host {
                inner: Mutex::new(Inner {
                    control: Lane::new(peer_control),
                    data: Lane::new(peer_data),
                    opens: Vec::new(),
                    policy,
                }),
                stop: AtomicBool::new(false),
            });
            let pump = Arc::clone(&host);
            let handle = thread::Builder::new()
                .name("slopdesk-test-host".to_owned())
                .spawn(move || {
                    while !pump.stop.load(Ordering::SeqCst) {
                        pump.turn();
                        // OUTSIDE the turn, so the host's lock is free for all but a few
                        // microseconds of each pass and a waiting test thread is never starved.
                        thread::sleep(POLL);
                    }
                })
                .expect("the responder thread");
            if let Ok(mut running) = running.lock() {
                running.push(handle);
            }
            if let Ok(mut stopping) = stopping.lock() {
                stopping.push(Arc::clone(&host));
            }
            if let Ok(mut far) = far.lock() {
                far.push(host);
            }
            if let Ok(mut held) = held.lock() {
                held.push(Kept { events, threads });
            }
            Ok(connection)
        });
        Self {
            registry: Arc::new(registry),
            hosts,
            pumps,
            stops,
            plan,
            kept,
        }
    }

    /// Rewrites the plan mid-test, for a suite whose later dials depend on what the earlier ones
    /// did. Only dials made AFTER this call see it.
    pub fn replan(&self, scripted: impl IntoIterator<Item = OpenPolicy>, fallback: OpenPolicy) {
        if let Ok(mut plan) = self.plan.lock() {
            plan.scripted = scripted.into_iter().collect();
            plan.fallback = fallback;
        }
    }

    /// How many connections the pool has dialled.
    pub fn connections(&self) -> usize {
        self.hosts.lock().map_or(0, |hosts| hosts.len())
    }

    /// The `index`-th connection's far end, waiting for it to exist.
    pub fn host(&self, index: usize) -> Arc<Host> {
        let deadline = Instant::now() + GENEROUS;
        loop {
            if let Ok(hosts) = self.hosts.lock()
                && let Some(host) = hosts.get(index)
            {
                return Arc::clone(host);
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for connection {index} to be dialled"
            );
            thread::sleep(POLL);
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        if let Ok(stops) = self.stops.lock() {
            for host in stops.iter() {
                host.stop.store(true, Ordering::SeqCst);
            }
        }
        if let Ok(mut pumps) = self.pumps.lock() {
            for handle in pumps.drain(..) {
                drop(handle.join());
            }
        }
    }
}

// -- a driver already on the wire ----------------------------------------------------------- //

/// The recorder as the trait object the driver takes.
///
/// The turbofish is load-bearing: a bare `Arc::clone(log)` infers `T` from the RETURN type and then
/// demands an `&Arc<dyn Observer>` it was never given.
pub fn observer(log: &Arc<Recorder>) -> Arc<dyn Observer> {
    Arc::<Recorder>::clone(log)
}

/// A harness, the driver on it, and the log that driver wrote — kept together because a suite that
/// dropped the harness while holding the driver would be asserting against a host with no pump.
pub struct Live {
    pub harness: Harness,
    pub driver: PaneDriver,
    pub log: Arc<Recorder>,
}

/// A driver connected to dial 0, under the plan that governs its redials.
///
/// The plan rather than a single policy, because the interesting connections are the LATER ones: a
/// redial builds a whole new `Host`, so nothing reachable from the first one can say how the second
/// should answer.
pub fn connected(
    scripted: impl IntoIterator<Item = OpenPolicy>,
    fallback: OpenPolicy,
    config: DriverConfig,
) -> Live {
    let harness = Harness::scripted(scripted, fallback);
    let log = Arc::new(Recorder::default());
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), config)
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");
    Live { harness, driver, log }
}

pub const fn endpoint_host() -> &'static str {
    "127.0.0.1"
}

pub const PORT: u16 = 4242;

pub fn target() -> Endpoint {
    Endpoint::new(endpoint_host(), PORT)
}

fn loopback_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind loopback");
    let port = listener.local_addr().expect("local addr").port();
    let peer = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("dial loopback");
    let (ours, _from) = listener.accept().expect("accept the dial");
    (peer, ours)
}
