//! The two sockets, the two readers, and the lane table a datagram is admitted against.
//!
//! ## The wire, which the host's `mux_transport` writes from the other end
//!
//! ```text
//!   [u32 BE channel_id][u8 tag][payload…]   media socket, client→host and host→client
//!   [u32 BE channel_id][payload…]           cursor socket, both ways (no tag)
//! ```
//!
//! Inbound datagrams are channel-id prefixed too, so a datagram is delivered to ONE lane's sink and
//! a datagram for a lane that has closed is dropped rather than broadcast. That is the whole of
//! per-channel loss isolation: a sibling lane's teardown, or a datagram lost on the wire, cannot
//! disturb another lane on the same flow.
//!
//! ## Why a test may open this and the Swift it replaces could not
//!
//! `NWVideoMuxClientFlow` carried a "COMPILED + reviewed, NEVER instantiated in a test" warning,
//! because an `NWConnection` needs a `DispatchQueue`, a state machine and a real path before it
//! delivers anything. A `UdpSocket` on `127.0.0.1` needs none of that, so every behaviour below —
//! the framing, the demux, the drop rules, the prime, the teardown — is driven by a test against a
//! second socket standing in for the host. The rules the flow ASKS are `slopdesk-video`'s and are
//! pinned there; what is pinned here is that this loop asks them.

use std::collections::HashMap;
use std::fmt;
use std::io::{self, Write as _};
use std::net::{SocketAddr, ToSocketAddrs as _, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use slopdesk_video::mux_flow::{receive_backoff, should_rearm};
use slopdesk_video::mux_header;
use slopdesk_video::recovery_routing::VideoChannel;

/// How long a parked reader waits before looking at the teardown flag again.
///
/// `UdpSocket` has no `shutdown`, so a reader blocked in `recv` cannot be woken by the close the
/// way a `NWConnection.cancel()` woke a `receiveMessage`. A read timeout is the wake instead: the
/// reader returns from `recv` empty, re-asks [`should_rearm`], and leaves. Short enough that a
/// teardown is not felt, long enough that an idle flow is not a spin.
const READ_TIMEOUT: Duration = Duration::from_millis(250);

/// The worst case for dropping a [`Flow`]: one parked `recv` plus one full error backoff.
///
/// A reader that has just started sleeping off [`receive_backoff`]'s ceiling wakes, re-checks the
/// flag, and returns — so the join takes at most the sleep plus one timeout. Nothing is delivered
/// after the drop returns, which is the guarantee that matters; the latency is bounded, not zero.
pub const TEARDOWN_LATENCY: Duration = Duration::from_millis(500);

/// The read window, sized so no datagram this wire can carry is ever truncated.
///
/// A `recv` into a short buffer TRUNCATES silently — the tail is gone with no error — so this is
/// the IP ceiling rather than [`slopdesk_video::fragment::MAX_DATAGRAM_SIZE`], which is the size
/// the host packetizes TO and not a size the socket can be trusted to never exceed. One allocation
/// per reader thread, for the life of the flow.
const READ_WINDOW: usize = 65_536;

/// The rx-gap threshold the stutter ladder's stage 3 reports, in seconds.
const DEBUG_GAP_THRESHOLD: f64 = 0.028;

/// Where a lane's inbound datagrams go.
///
/// One implementor per lane, registered under its channel id. The flow calls these from its reader
/// threads, never from the caller's, and never after [`Flow::unregister_lane`] has returned for
/// that lane or the flow has been dropped.
pub trait LaneSink: Send + Sync {
    /// A media datagram for this lane, tag already decoded and stripped.
    fn media(&self, channel: VideoChannel, payload: &[u8]);
    /// A cursor datagram for this lane. Never called with an empty payload.
    fn cursor(&self, payload: &[u8]);
}

/// The stutter ladder's stage 3: report a hole between VIDEO datagrams at the socket.
///
/// A gap here already existed on the wire — a host stall or a path stall — so stages 4 and 5 can
/// only inherit it, never introduce it. Gated on `SLOPDESK_VIDEO_DEBUG`, read once.
struct GapWatch {
    enabled: bool,
    last: Option<Instant>,
}

impl GapWatch {
    fn new() -> Self {
        Self {
            enabled: std::env::var_os("SLOPDESK_VIDEO_DEBUG").is_some(),
            last: None,
        }
    }

    fn note(&mut self, channel: VideoChannel) {
        if !self.enabled || channel != VideoChannel::Video {
            return;
        }
        let now = Instant::now();
        if let Some(previous) = self.last {
            let gap = now.duration_since(previous).as_secs_f64();
            if gap > DEBUG_GAP_THRESHOLD {
                // Formatted, not cast: a `f64 as u64` here would be a lint waiver for a diagnostic
                // that only ever wants the number read.
                let line = format!("SlopDesk[video.client]: rx gap {:.0}ms\n", gap * 1000.0);
                // Not `eprintln!`, which the lint block bars for production code: this is the one
                // developer-gated diagnostic on the path and it writes the bytes itself.
                drop(io::stderr().write_all(line.as_bytes()));
            }
        }
        self.last = Some(now);
    }
}

/// Everything both readers and every caller share: the sockets, the lane table, the two flags.
struct Shared {
    media: UdpSocket,
    cursor: UdpSocket,
    lanes: RwLock<HashMap<u32, Arc<dyn LaneSink>>>,
    /// Set once, by [`Flow::drop`]. The only liveness signal a shared UDP socket has.
    torn: AtomicBool,
    /// The LAST media send's answer. See the crate header for why this is not a state machine.
    send_viable: AtomicBool,
}

impl Shared {
    fn is_alive(&self) -> bool {
        !self.torn.load(Ordering::Acquire)
    }

    fn lane(&self, channel_id: u32) -> Option<Arc<dyn LaneSink>> {
        self.lanes
            .read()
            .map_or(None, |lanes| lanes.get(&channel_id).map(Arc::clone))
    }
}

/// The client half of one host's shared UDP flow.
///
/// One media socket and one cursor socket, shared by every video pane pointed at that host and
/// demultiplexed by channel id. Dropping it tears both down; see [`TEARDOWN_LATENCY`].
pub struct Flow {
    shared: Arc<Shared>,
    readers: Mutex<Vec<JoinHandle<()>>>,
}

impl fmt::Debug for Flow {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Flow")
            .field("lanes", &self.lane_count())
            .field("alive", &self.shared.is_alive())
            .field("send_viable", &self.is_send_path_viable())
            .finish_non_exhaustive()
    }
}

impl Flow {
    /// Opens the media and cursor sockets to `host` and starts both readers.
    ///
    /// Each socket is bound on the address family its peer resolved to and `connect`ed, so a
    /// datagram from anywhere but the host is dropped by the kernel rather than by this code.
    ///
    /// # Errors
    /// When `host` does not resolve, when either port has no route, or when a bind fails. Unlike
    /// `NWConnection.start(queue:)`, which returned nothing and surfaced a real failure only
    /// through a state handler, this is answered before a single datagram is sent.
    pub fn open(host: &str, media_port: u16, cursor_port: u16) -> io::Result<Self> {
        let media = dial(host, media_port)?;
        let cursor = dial(host, cursor_port)?;
        let shared = Arc::new(Shared {
            media,
            cursor,
            lanes: RwLock::new(HashMap::new()),
            torn: AtomicBool::new(false),
            // Optimistic at bring-up, exactly as the Swift flow was, so the first sends — the
            // hello, the prime — are never held back by a path nothing has measured yet.
            send_viable: AtomicBool::new(true),
        });

        let media_reader = spawn_reader(&Arc::clone(&shared), true);
        let cursor_reader = spawn_reader(&Arc::clone(&shared), false);
        Ok(Self {
            shared,
            readers: Mutex::new(vec![media_reader, cursor_reader]),
        })
    }

    /// Registers a lane's sink and primes its cursor flow.
    ///
    /// The prime is the one datagram that has to be sent for the lane to receive cursor updates at
    /// all: the host accepts a cursor flow only on an inbound datagram, and the prime is channel-id
    /// prefixed so the host binds it to THIS lane. Registering a channel id that is already
    /// registered replaces its sink and re-primes.
    pub fn register_lane(&self, channel_id: u32, sink: Arc<dyn LaneSink>) {
        if let Ok(mut lanes) = self.shared.lanes.write() {
            lanes.insert(channel_id, sink);
        }
        self.send_cursor(channel_id, &[0x00]);
    }

    /// Removes a lane's sink. Datagrams for it are dropped from the next one on.
    pub fn unregister_lane(&self, channel_id: u32) {
        if let Ok(mut lanes) = self.shared.lanes.write() {
            lanes.remove(&channel_id);
        }
    }

    /// How many lanes are live. The pool tears the flow down at zero.
    #[must_use]
    pub fn lane_count(&self) -> usize {
        self.shared.lanes.read().map_or(0, |lanes| lanes.len())
    }

    /// Whether the last media send reached the path.
    ///
    /// The session's PERIODIC producers — the 20 Hz stats reports, the 5 s keepalive — skip their
    /// fire while this is false, so a client on a dead wifi path does not keep handing the kernel
    /// datagrams that cannot leave. Sparse best-effort sends (input, hello, recovery) are NOT
    /// gated: the user expects them to ride the first viable window.
    #[must_use]
    pub fn is_send_path_viable(&self) -> bool {
        self.shared.send_viable.load(Ordering::Acquire)
    }

    /// Sends one media datagram for `channel_id`, tag-stamped. Answers whether it left.
    ///
    /// A failure here also updates [`Self::is_send_path_viable`], but only for the errors that
    /// name the PATH. `ECONNREFUSED` — an ICMP port-unreachable from a host that is plainly
    /// reachable — does not revoke viability, because the path it proves is a working one.
    pub fn send_media(&self, channel_id: u32, tag: u8, payload: &[u8]) -> bool {
        let datagram = mux_header::encode_media(channel_id, tag, payload);
        match self.shared.media.send(&datagram) {
            Ok(_) => {
                self.shared.send_viable.store(true, Ordering::Release);
                true
            },
            Err(error) => {
                if names_the_path(&error) {
                    self.shared.send_viable.store(false, Ordering::Release);
                }
                false
            },
        }
    }

    /// Sends one cursor datagram for `channel_id` — the lane's (re-)prime. Answers whether it left.
    ///
    /// The session re-primes with every hello and each keepalive tick, because the cursor socket
    /// carries no other client→host traffic: a host restart or a NAT rebind would otherwise kill
    /// cursor updates for the lane's whole life while video and input self-heal.
    pub fn send_cursor(&self, channel_id: u32, payload: &[u8]) -> bool {
        let datagram = mux_header::encode(channel_id, payload);
        self.shared.cursor.send(&datagram).is_ok()
    }

    /// The bound local addresses, media first. For a test standing in for the host.
    ///
    /// # Errors
    /// When either socket cannot report its own name.
    pub fn local_addrs(&self) -> io::Result<(SocketAddr, SocketAddr)> {
        Ok((self.shared.media.local_addr()?, self.shared.cursor.local_addr()?))
    }
}

impl Drop for Flow {
    fn drop(&mut self) {
        self.shared.torn.store(true, Ordering::Release);
        if let Ok(mut readers) = self.readers.lock() {
            for reader in readers.drain(..) {
                drop(reader.join());
            }
        }
        // Only now, with both readers joined, can the lane table be emptied: a sink dropped while a
        // reader still held a clone of it would be a callback into freed caller state.
        if let Ok(mut lanes) = self.shared.lanes.write() {
            lanes.clear();
        }
    }
}

/// Binds a socket on the peer's own address family and connects it.
fn dial(host: &str, port: u16) -> io::Result<UdpSocket> {
    let peer = (host, port).to_socket_addrs()?.next().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            format!("{host}:{port} resolved to nothing"),
        )
    })?;
    let bind: SocketAddr = if peer.is_ipv6() {
        "[::]:0".parse()
    } else {
        "0.0.0.0:0".parse()
    }
    .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, format!("{error}")))?;
    let socket = UdpSocket::bind(bind)?;
    socket.connect(peer)?;
    socket.set_read_timeout(Some(READ_TIMEOUT))?;
    Ok(socket)
}

/// Whether an error is the PATH's rather than the peer's.
fn names_the_path(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::NetworkUnreachable | io::ErrorKind::HostUnreachable | io::ErrorKind::NetworkDown
    )
}

/// Whether an error is just the read timeout coming round — the parked reader's own wake.
fn is_the_timeout(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

fn spawn_reader(shared: &Arc<Shared>, is_media: bool) -> JoinHandle<()> {
    let shared = Arc::clone(shared);
    let name = if is_media {
        "slopdesk.video.mux.media"
    } else {
        "slopdesk.video.mux.cursor"
    };
    thread::Builder::new()
        .name(name.to_owned())
        .spawn(move || read_loop(&shared, is_media))
        .unwrap_or_else(|_| thread::spawn(move || {}))
}

/// The receive loop, asking [`should_rearm`] the one question a shared UDP socket can answer.
///
/// A per-datagram error does NOT stop the loop — an ICMP port-unreachable surfaces as a receive
/// error while the socket is perfectly healthy — so the loop backs off and re-arms. Only the
/// teardown flag ends it. The count RESETS on the first clean datagram, so the hot path is never
/// delayed by an error that has already passed.
fn read_loop(shared: &Arc<Shared>, is_media: bool) {
    // On the heap, not the stack: a read window this size is exactly the local array the lints
    // refuse, and this one lives on a thread whose stack is not the caller's to size.
    let mut window = vec![0_u8; READ_WINDOW];
    let mut gaps = GapWatch::new();
    let mut consecutive_errors: u32 = 0;

    while should_rearm(shared.is_alive()) {
        let socket = if is_media { &shared.media } else { &shared.cursor };
        match socket.recv(&mut window) {
            Ok(length) => {
                consecutive_errors = 0;
                let Some(datagram) = window.get(..length) else {
                    continue;
                };
                if is_media {
                    dispatch_media(shared, datagram, &mut gaps);
                } else {
                    dispatch_cursor(shared, datagram);
                }
            },
            Err(error) if is_the_timeout(&error) => consecutive_errors = 0,
            Err(_) => {
                consecutive_errors = consecutive_errors.saturating_add(1);
                thread::sleep(Duration::from_secs_f64(receive_backoff(consecutive_errors)));
            },
        }
    }
}

fn dispatch_media(shared: &Arc<Shared>, datagram: &[u8], gaps: &mut GapWatch) {
    let Ok((channel_id, rest)) = mux_header::decode(datagram) else {
        return;
    };
    let Some((tag, payload)) = rest.split_first() else {
        return;
    };
    let Some(channel) = VideoChannel::from_raw_value(*tag) else {
        return;
    };
    gaps.note(channel);
    // A datagram for a closed or unknown lane is dropped, not broadcast — loss isolation.
    if let Some(sink) = shared.lane(channel_id) {
        sink.media(channel, payload);
    }
}

fn dispatch_cursor(shared: &Arc<Shared>, datagram: &[u8]) {
    let Ok((channel_id, payload)) = mux_header::decode(datagram) else {
        return;
    };
    if payload.is_empty() {
        return;
    }
    if let Some(sink) = shared.lane(channel_id) {
        sink.cursor(payload);
    }
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    clippy::panic,
    reason = "a socket test that cannot bind loopback, or is handed the wrong sink, has nothing left to \
              assert"
)]
mod tests {
    use std::sync::mpsc::{Receiver, Sender, channel};

    use super::*;

    /// What the flow handed a lane, in arrival order.
    enum Delivery {
        Media(VideoChannel, Vec<u8>),
        Cursor(Vec<u8>),
    }

    struct Recorder(Mutex<Sender<Delivery>>);

    impl Recorder {
        fn new() -> (Arc<Self>, Receiver<Delivery>) {
            let (sender, receiver) = channel();
            (Arc::new(Self(Mutex::new(sender))), receiver)
        }

        fn say(&self, delivery: Delivery) {
            drop(self.0.lock().unwrap().send(delivery));
        }
    }

    impl LaneSink for Recorder {
        fn media(&self, channel: VideoChannel, payload: &[u8]) {
            self.say(Delivery::Media(channel, payload.to_vec()));
        }

        fn cursor(&self, payload: &[u8]) {
            self.say(Delivery::Cursor(payload.to_vec()));
        }
    }

    /// A socket standing in for the host end of one of the two sockets.
    struct HostEnd(UdpSocket);

    impl HostEnd {
        fn bind() -> Self {
            let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            Self(socket)
        }

        fn port(&self) -> u16 {
            self.0.local_addr().unwrap().port()
        }

        /// The next datagram the client sent, and the address it came from.
        fn next(&self) -> (Vec<u8>, SocketAddr) {
            let mut window = vec![0_u8; READ_WINDOW];
            let (length, from) = self.0.recv_from(&mut window).unwrap();
            window.truncate(length);
            (window, from)
        }
    }

    /// A flow against two host stand-ins, with the flow's own bound addresses in hand.
    fn open_against(media: &HostEnd, cursor: &HostEnd) -> Flow {
        Flow::open("127.0.0.1", media.port(), cursor.port()).unwrap()
    }

    fn next_delivery(receiver: &Receiver<Delivery>) -> Delivery {
        receiver.recv_timeout(Duration::from_secs(2)).unwrap()
    }

    #[test]
    fn register_lane_primes_the_cursor_flow_with_a_channel_id_prefixed_datagram() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (sink, _inbox) = Recorder::new();

        flow.register_lane(0x0102_0304, sink);

        let (prime, _) = cursor.next();
        assert_eq!(
            prime,
            vec![0x01, 0x02, 0x03, 0x04, 0x00],
            "the prime is the id then one zero byte"
        );
    }

    #[test]
    fn a_media_send_stamps_the_tag_between_the_channel_id_and_the_payload() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);

        assert!(flow.send_media(0x0000_0009, VideoChannel::Video.raw_value(), &[0xAA, 0xBB]));

        let (datagram, _) = media.next();
        assert_eq!(datagram, vec![0x00, 0x00, 0x00, 0x09, 0x01, 0xAA, 0xBB]);
    }

    #[test]
    fn a_cursor_send_carries_no_tag() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (sink, _inbox) = Recorder::new();
        flow.register_lane(7, sink);
        drop(cursor.next()); // the prime

        assert!(flow.send_cursor(7, &[0x11, 0x22]));

        let (datagram, _) = cursor.next();
        assert_eq!(datagram, vec![0x00, 0x00, 0x00, 0x07, 0x11, 0x22]);
    }

    #[test]
    fn an_inbound_media_datagram_reaches_only_its_own_lane() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (mine, inbox) = Recorder::new();
        let (sibling, sibling_inbox) = Recorder::new();
        flow.register_lane(11, mine);
        flow.register_lane(22, sibling);

        // Learn where the client's media socket is by making it speak first.
        flow.send_media(11, VideoChannel::Control.raw_value(), &[]);
        let (_, client) = media.next();
        media
            .0
            .send_to(
                &mux_header::encode_media(11, VideoChannel::Video.raw_value(), &[0xDE, 0xAD]),
                client,
            )
            .unwrap();

        match next_delivery(&inbox) {
            Delivery::Media(channel, payload) => {
                assert_eq!(channel, VideoChannel::Video);
                assert_eq!(
                    payload,
                    vec![0xDE, 0xAD],
                    "the tag is stripped, the payload is not"
                );
            },
            Delivery::Cursor(_) => panic!("a media datagram arrived on the cursor sink"),
        }
        assert!(
            sibling_inbox.recv_timeout(Duration::from_millis(200)).is_err(),
            "lane 22 must not see lane 11's datagram"
        );
    }

    #[test]
    fn a_datagram_for_a_lane_that_closed_is_dropped_rather_than_broadcast() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (mine, inbox) = Recorder::new();
        let (survivor, survivor_inbox) = Recorder::new();
        flow.register_lane(11, mine);
        flow.register_lane(22, survivor);
        flow.send_media(11, VideoChannel::Control.raw_value(), &[]);
        let (_, client) = media.next();

        flow.unregister_lane(11);
        media
            .0
            .send_to(
                &mux_header::encode_media(11, VideoChannel::Video.raw_value(), &[0x01]),
                client,
            )
            .unwrap();
        media
            .0
            .send_to(
                &mux_header::encode_media(22, VideoChannel::Video.raw_value(), &[0x02]),
                client,
            )
            .unwrap();

        match next_delivery(&survivor_inbox) {
            Delivery::Media(_, payload) => {
                assert_eq!(payload, vec![0x02], "the survivor gets its own, and only its own");
            },
            Delivery::Cursor(_) => panic!("a media datagram arrived on the cursor sink"),
        }
        assert!(
            inbox.recv_timeout(Duration::from_millis(200)).is_err(),
            "the closed lane hears nothing"
        );
    }

    #[test]
    fn an_unknown_tag_is_dropped_rather_than_delivered_as_some_other_channel() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (sink, inbox) = Recorder::new();
        flow.register_lane(5, sink);
        flow.send_media(5, VideoChannel::Control.raw_value(), &[]);
        let (_, client) = media.next();

        media
            .0
            .send_to(&mux_header::encode_media(5, 0xFE, &[0x01]), client)
            .unwrap();
        media
            .0
            .send_to(
                &mux_header::encode_media(5, VideoChannel::Audio.raw_value(), &[0x02]),
                client,
            )
            .unwrap();

        match next_delivery(&inbox) {
            Delivery::Media(channel, payload) => {
                assert_eq!(
                    channel,
                    VideoChannel::Audio,
                    "the unknown tag was skipped, not renamed"
                );
                assert_eq!(payload, vec![0x02]);
            },
            Delivery::Cursor(_) => panic!("a media datagram arrived on the cursor sink"),
        }
    }

    #[test]
    fn an_inbound_cursor_datagram_reaches_its_lane_and_an_empty_one_does_not() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (sink, inbox) = Recorder::new();
        flow.register_lane(3, sink);
        let (_, client) = cursor.next(); // the prime tells us where the client's cursor socket is

        cursor.0.send_to(&mux_header::encode(3, &[]), client).unwrap();
        cursor.0.send_to(&mux_header::encode(3, &[0x77]), client).unwrap();

        match next_delivery(&inbox) {
            Delivery::Cursor(payload) => {
                assert_eq!(payload, vec![0x77], "the empty one was dropped, not delivered");
            },
            Delivery::Media(..) => panic!("a cursor datagram arrived on the media sink"),
        }
    }

    #[test]
    fn a_short_datagram_that_cannot_hold_a_channel_id_is_dropped() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (sink, inbox) = Recorder::new();
        flow.register_lane(3, sink);
        let (_, client) = cursor.next();

        cursor.0.send_to(&[0x00, 0x00, 0x00], client).unwrap();
        cursor.0.send_to(&mux_header::encode(3, &[0x77]), client).unwrap();

        match next_delivery(&inbox) {
            Delivery::Cursor(payload) => assert_eq!(payload, vec![0x77]),
            Delivery::Media(..) => panic!("a cursor datagram arrived on the media sink"),
        }
    }

    #[test]
    fn the_lane_count_is_what_the_pool_tears_the_flow_down_on() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        assert_eq!(flow.lane_count(), 0);

        let (one, _one_inbox) = Recorder::new();
        let (two, _two_inbox) = Recorder::new();
        flow.register_lane(1, one);
        flow.register_lane(2, two);
        assert_eq!(flow.lane_count(), 2);

        flow.unregister_lane(1);
        assert_eq!(flow.lane_count(), 1);
        flow.unregister_lane(2);
        assert_eq!(flow.lane_count(), 0, "the pool's teardown signal");
    }

    #[test]
    fn re_registering_a_channel_id_replaces_its_sink_and_re_primes() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (first, first_inbox) = Recorder::new();
        let (second, second_inbox) = Recorder::new();

        flow.register_lane(4, first);
        let (_, client) = cursor.next();
        flow.register_lane(4, second);
        drop(cursor.next()); // the second prime — one per registration
        assert_eq!(flow.lane_count(), 1, "a replacement is not a second lane");

        cursor.0.send_to(&mux_header::encode(4, &[0x99]), client).unwrap();
        match next_delivery(&second_inbox) {
            Delivery::Cursor(payload) => assert_eq!(payload, vec![0x99]),
            Delivery::Media(..) => panic!("a cursor datagram arrived on the media sink"),
        }
        assert!(
            first_inbox.recv_timeout(Duration::from_millis(200)).is_err(),
            "the replaced sink is done"
        );
    }

    #[test]
    fn the_send_path_is_optimistic_at_bring_up_and_a_reachable_peer_keeps_it_viable() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        assert!(
            flow.is_send_path_viable(),
            "nothing has been measured yet, so nothing is held back"
        );

        assert!(flow.send_media(1, VideoChannel::Video.raw_value(), &[0x01]));
        assert!(flow.is_send_path_viable());
    }

    #[test]
    fn dropping_the_flow_joins_both_readers_inside_the_documented_latency() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (sink, _inbox) = Recorder::new();
        flow.register_lane(1, sink);
        drop(cursor.next());

        let started = Instant::now();
        drop(flow);
        assert!(
            started.elapsed() < TEARDOWN_LATENCY,
            "a teardown is bounded by the read timeout, not open-ended: took {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn opening_against_a_host_that_does_not_resolve_is_an_error_not_a_deferred_state() {
        // `.invalid` is reserved by RFC 2606 precisely so it can never resolve.
        let outcome = Flow::open("slopdesk-videolink-nowhere.invalid", 9000, 9001);
        assert!(
            outcome.is_err(),
            "a resolution failure is answered here, not through a state handler"
        );
    }

    #[test]
    fn the_two_sockets_are_bound_separately() {
        let media = HostEnd::bind();
        let cursor = HostEnd::bind();
        let flow = open_against(&media, &cursor);
        let (media_local, cursor_local) = flow.local_addrs().unwrap();
        assert_ne!(media_local, cursor_local, "one flow, two sockets");
    }
}
