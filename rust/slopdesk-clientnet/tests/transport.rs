//! The three facts one channel is for — which lane a verb rides, where a paste is split, and when
//! the merged stream ends — plus the two the pool can only be asked about from here.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.3. The connection is real, the same way
//! `tests/registry.rs`'s is: two loopback sockets served as `Role::Client`, with the RESPONDER's
//! ends kept by the test. A double would answer the lane question by construction, and the lane
//! question is the whole of §1 — so the proof has to be which SOCKET carried the bytes, read from
//! the far side of a real link.
//!
//! What is faked is the same seam the pool is built over: the dialler factory. It hands the pooled
//! connection two loopback pairs and hands this file the other two ends. Nothing here reaches
//! around a type — a test speaks mux frames on a socket, exactly as a host would.
//!
//! The responder is hand-rolled rather than a `Role::Host` connection: what these tests assert is
//! frame-for-frame (this envelope, on this link), and a second `MuxConnection` in the way would
//! decode, route and re-derive those frames before the assertion could see them.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::{io, thread};

use slopdesk_clientnet::dial::Endpoint;
use slopdesk_clientnet::registry::ConnectionRegistry;
use slopdesk_clientnet::transport::{ChannelTransport, InboundSink};
use slopdesk_muxnet::connection::{
    ConnectionThreads, MuxConnection, MuxEvent, OpenRequest, PairedConnection,
};
use slopdesk_muxnet::link::TcpByteLink;
use slopdesk_muxnet::preamble::ConnectionId;
use slopdesk_muxnet::subchannel::ChannelEnd;
use slopdesk_wire::mux::admission::Role;
use slopdesk_wire::{FrameDecoder, MuxCloseReason, MuxFlowControl, MuxFrame, MuxFrameDecoder, WireMessage};

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

/// How long one poll of a peer socket may block. Short, because a wait here is a LOOP over both
/// lanes and this is its granularity, not its bound.
const POLL: Duration = Duration::from_millis(5);

/// Everything one built connection keeps alive that no test reads: the event stream and the receive
/// loops its owner would normally hold.
#[expect(
    dead_code,
    reason = "held to keep the receive loops and their event stream alive, never read"
)]
#[derive(Debug)]
struct Kept {
    events: Receiver<MuxEvent>,
    threads: ConnectionThreads,
}

/// The responder's end of ONE link: the socket, and every whole mux frame that has come out of it.
///
/// Frames accumulate rather than being consumed, because most of what these tests assert is about
/// what a lane carried in total — "one `channelClose` and not two" is not a question a stream that
/// forgets can answer.
#[derive(Debug)]
struct Lane {
    socket: TcpStream,
    decoder: MuxFrameDecoder,
    frames: Vec<MuxFrame>,
    /// Set once the peer hung up, so a wait after a close polls instead of spinning on EOF.
    ended: bool,
}

impl Lane {
    fn new(socket: TcpStream) -> Self {
        socket
            .set_read_timeout(Some(POLL))
            .expect("a read timeout on the peer socket");
        Self {
            socket,
            decoder: MuxFrameDecoder::new(),
            frames: Vec::new(),
            ended: false,
        }
    }

    /// Reads whatever has arrived and decodes every complete frame in it.
    ///
    /// Blocks for at most one [`POLL`] when the lane is idle, which is what makes a wait built out
    /// of this both prompt and bounded.
    fn pump(&mut self) {
        let mut buffer = [0_u8; 16 * 1024];
        loop {
            match self.socket.read(&mut buffer) {
                Ok(0) => {
                    self.ended = true;
                    break;
                },
                Ok(read) => {
                    let Some(chunk) = buffer.get(..read) else { break };
                    self.decoder.append(chunk);
                },
                // A timeout is the ordinary answer for an idle lane; both kinds appear, because
                // `SO_RCVTIMEO` surfaces as either depending on the platform.
                Err(ref failure)
                    if matches!(
                        failure.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                },
                Err(_) => {
                    self.ended = true;
                    break;
                },
            }
        }
        while let Ok(Some(frame)) = self.decoder.next_frame() {
            self.frames.push(frame);
        }
        if self.ended {
            // Nothing more will ever arrive, so a caller's poll loop must not become a spin.
            thread::sleep(POLL);
        }
    }

    /// Writes one frame as the host would.
    fn send(&mut self, frame: &MuxFrame) {
        self.socket
            .write_all(&frame.encode())
            .expect("the responder's write");
    }

    /// The inner `WireMessage`s this lane carried, reassembled across `channelData` boundaries.
    ///
    /// The envelope split is the mux's business — a send is chunked against the credit window — so
    /// the messages, not the envelopes, are what a claim about `input` or `resize` is about.
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

    /// The credit this lane was granted, in the order it was granted.
    fn grants(&self) -> Vec<u32> {
        self.frames
            .iter()
            .filter_map(|frame| {
                match *frame {
                    MuxFrame::WindowAdjust { bytes_to_add, .. } => Some(bytes_to_add),
                    _ => None,
                }
            })
            .collect()
    }

    /// How many `channelClose` frames this lane carried.
    fn closes(&self) -> usize {
        self.frames
            .iter()
            .filter(|frame| matches!(**frame, MuxFrame::ChannelClose { .. }))
            .count()
    }

    /// Whether the open this end initiated has arrived here.
    fn saw_open(&self) -> bool {
        self.frames
            .iter()
            .any(|frame| matches!(*frame, MuxFrame::ChannelOpen { .. }))
    }
}

/// The host's end of the one connection under test.
#[derive(Debug)]
struct Responder {
    control: Lane,
    data: Lane,
}

impl Responder {
    fn pump(&mut self) {
        self.control.pump();
        self.data.pump();
    }
}

/// What the sink was told, in the order it was told.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Told {
    /// One inbound message, from either lane.
    Message(WireMessage),
    /// The end, and the reason it carried.
    Ended(ChannelEnd),
}

/// The FFI door, shrunk to a log.
///
/// ONE ordered `Vec` rather than a counter beside a queue, because "nothing follows the end" is a
/// claim about ORDER and two containers could not state it.
#[derive(Debug, Default)]
struct Recorder {
    told: Mutex<Vec<Told>>,
}

impl Recorder {
    fn told(&self) -> Vec<Told> {
        self.told.lock().map(|told| told.clone()).unwrap_or_default()
    }

    fn messages(&self) -> Vec<WireMessage> {
        self.told()
            .into_iter()
            .filter_map(|told| {
                match told {
                    Told::Message(message) => Some(message),
                    Told::Ended(_) => None,
                }
            })
            .collect()
    }

    fn ends(&self) -> Vec<ChannelEnd> {
        self.told()
            .into_iter()
            .filter_map(|told| {
                match told {
                    Told::Ended(end) => Some(end),
                    Told::Message(_) => None,
                }
            })
            .collect()
    }
}

impl InboundSink for Recorder {
    fn message(&self, message: &WireMessage) {
        if let Ok(mut told) = self.told.lock() {
            told.push(Told::Message(message.clone()));
        }
    }

    fn ended(&self, end: &ChannelEnd) {
        if let Ok(mut told) = self.told.lock() {
            told.push(Told::Ended(end.clone()));
        }
    }
}

/// A pool whose dialler hands the test the far end of everything it builds.
#[derive(Debug)]
struct Harness {
    registry: Arc<ConnectionRegistry>,
    responders: Arc<Mutex<Vec<Responder>>>,
    /// Parked here for the length of the test, because a dropped `ConnectionThreads` would take the
    /// receive loops with it and every claim below is about what those loops carried.
    #[expect(dead_code, reason = "held to keep the receive loops alive, never read")]
    kept: Arc<Mutex<Vec<Kept>>>,
}

impl Harness {
    fn new() -> Self {
        let responders: Arc<Mutex<Vec<Responder>>> = Arc::new(Mutex::new(Vec::new()));
        let kept: Arc<Mutex<Vec<Kept>>> = Arc::new(Mutex::new(Vec::new()));
        let far = Arc::clone(&responders);
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
            if let Ok(mut far) = far.lock() {
                far.push(Responder {
                    control: Lane::new(peer_control),
                    data: Lane::new(peer_data),
                });
            }
            if let Ok(mut held) = held.lock() {
                held.push(Kept { events, threads });
            }
            Ok(connection)
        });
        Self {
            registry: Arc::new(registry),
            responders,
            kept,
        }
    }

    /// The far end of the connection the pool just built.
    fn responder(&self) -> Responder {
        self.responders
            .lock()
            .expect("the responder slot")
            .pop()
            .expect("the dialler built a connection")
    }
}

fn loopback_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind loopback");
    let port = listener.local_addr().expect("local addr").port();
    let peer = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("dial loopback");
    let (ours, _from) = listener.accept().expect("accept the dial");
    (peer, ours)
}

/// One transport on one pooled connection, with the responder's end of both its links.
///
/// The open is waited for here rather than in each test: it is the first frame on the DATA link —
/// an open is initiated there, always — and every lane assertion below reads past it.
fn opened(harness: &Harness) -> (ChannelTransport, Arc<Recorder>, Responder) {
    let recorder = Arc::new(Recorder::default());
    // The annotation is the unsizing coercion: the test keeps the concrete recorder to read, the
    // transport gets the same object as the trait object it takes.
    let sink: Arc<dyn InboundSink> = recorder.clone();
    let transport = ChannelTransport::open(Arc::clone(&harness.registry), &endpoint(), &request(), sink)
        .expect("the channel opened");
    let mut peer = harness.responder();
    eventually("the open to reach the responder on DATA", || {
        peer.pump();
        peer.data.saw_open()
    });
    (transport, recorder, peer)
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

/// A `channelData` envelope carrying one inner message, as the host writes it.
fn carrying(channel_id: u32, message: &WireMessage) -> MuxFrame {
    MuxFrame::ChannelData {
        channel_id,
        payload: message.encode(),
    }
}

const fn resize() -> WireMessage {
    WireMessage::Resize {
        cols: 120,
        rows: 40,
        px_width: 0,
        px_height: 0,
    }
}

/// §1, and the reason the face exists at all: a keystroke and a resize are the same call shape and
/// different links. Read from the two sockets separately, because that is the only place the split
/// is observable — and it is the fact the seven Swift call sites each spelled for themselves.
#[test]
fn input_rides_the_data_link_and_a_control_verb_rides_the_control_link() {
    let harness = Harness::new();
    let (transport, _recorder, mut peer) = opened(&harness);

    transport.send_input(b"ls\r").expect("the input");
    transport.send_control(&resize()).expect("the resize");

    eventually("both lanes to carry their message", || {
        peer.pump();
        !peer.data.messages().is_empty() && !peer.control.messages().is_empty()
    });

    // Equality on BOTH lanes, not membership on one: a misrouted frame does not vanish, it lands on
    // the other socket — so it is the pair of assertions that makes this a claim about routing
    // rather than about arrival.
    assert_eq!(
        peer.data.messages(),
        vec![WireMessage::Input(b"ls\r".to_vec())],
        "the DATA lane did not carry exactly the input"
    );
    assert_eq!(
        peer.control.messages(),
        vec![resize()],
        "the CONTROL lane did not carry exactly the resize"
    );
    transport.close();
}

/// §2. The cap is the flow-control constant, never a literal here: it is cross-clamped against the
/// tunable window at its source, and a copy of the number in this file would be a second spelling
/// that an env override could make wrong.
///
/// Both halves of the boundary in one test, because the boundary is the property: an input AT the
/// cap is one message, and one over it is several — none of them over the cap, and the bytes
/// unchanged and in order. The keystroke goes FIRST so the counting is exact rather than a wait for
/// "no more": with it at the head, four messages total is only reachable if it was not split.
///
/// Every send here stays inside the 64 KiB initial window, so nothing parks on credit and no grant
/// from the responder is needed to make the test finish.
#[test]
fn a_paste_over_the_cap_is_split_and_an_input_at_the_cap_is_not() {
    let harness = Harness::new();
    let (transport, _recorder, mut peer) = opened(&harness);
    let cap =
        usize::try_from(MuxFlowControl::max_data_message_payload_bytes()).expect("the cap fits a usize");
    // A non-repeating pattern, so a reordering or a duplicated chunk cannot reassemble by accident.
    let paste: Vec<u8> = (0..cap + cap + 500)
        .map(|index| u8::try_from(index % 251).unwrap_or(0))
        .collect();
    let at_cap = paste
        .get(..cap)
        .expect("the paste is longer than the cap")
        .to_vec();

    transport.send_input(&at_cap).expect("the input at the cap");
    transport.send_input(&paste).expect("the paste");

    eventually("the paste to arrive", || {
        peer.pump();
        peer.data.messages().len() >= 4
    });

    let messages = peer.data.messages();
    assert_eq!(
        messages.len(),
        4,
        "one input at the cap plus a paste of two and a half caps is four messages"
    );
    let mut rejoined = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        match *message {
            WireMessage::Input(ref bytes) => {
                assert!(
                    bytes.len() <= cap,
                    "chunk {index} is over the cap at {} bytes",
                    bytes.len()
                );
                if index > 0 {
                    rejoined.extend_from_slice(bytes);
                } else {
                    assert_eq!(bytes, &at_cap, "an input AT the cap was split");
                }
            },
            ref other => panic!("a paste arrived as something other than input: {other:?}"),
        }
    }
    assert_eq!(
        rejoined, paste,
        "the chunks do not rejoin into the paste, in order"
    );
    transport.close();
}

/// §3. A peer close on ONE link finishes that lane's sub-channel and leaves the other live, which
/// is exactly the state the merged stream has to end in: a channel with one live lane is not a
/// usable channel.
///
/// The second assertion is the trap the port had to avoid: an `mpsc` receiver ends on the LAST
/// sender drop, so a merge built out of one would say nothing here and announce the end only when
/// `close` finished the surviving lane — one end, at the wrong time. Counting the calls across BOTH
/// endings is what tells the two designs apart.
#[test]
fn the_merged_stream_ends_on_the_first_lane_to_end() {
    let harness = Harness::new();
    let (transport, recorder, mut peer) = opened(&harness);
    let ending = MuxFrame::ChannelClose {
        channel_id: transport.channel_id(),
        reason: MuxCloseReason::SubscriberEvicted,
    };

    peer.control.send(&ending);
    eventually("the end to reach the sink", || !recorder.ends().is_empty());

    assert_eq!(
        recorder.ends(),
        vec![ChannelEnd::Peer(MuxCloseReason::SubscriberEvicted)],
        "the reason the peer named did not survive to the sink"
    );
    assert_eq!(
        transport.end(),
        Some(ChannelEnd::Peer(MuxCloseReason::SubscriberEvicted)),
        "the transport reports a different end than the sink was told"
    );

    // `close` finishes the lane that was still live, and JOINS both forwarders — so by the time it
    // returns, the second forwarder has run its epilogue and had its chance to speak.
    transport.close();
    assert_eq!(
        recorder.ends().len(),
        1,
        "the second lane to end announced it as well"
    );
}

/// The other half of §3, which [`InboundSink`] states as "`ended` … is called exactly once and
/// always LAST": nothing follows it.
///
/// A peer close on CONTROL ends the merged stream while the DATA lane is still open in the mux —
/// registered, unfinished, still SENDABLE, and with a host at the other end that has no way to know
/// this client considers the channel over. So the frames keep coming, and the lane that did not end
/// is the one that has to swallow them.
///
/// It is a memory claim, not a tidiness one: the FFI door frees its Swift callback context when it
/// is told the channel ended, and a message delivered afterwards arrives on the OTHER lane's
/// thread, unordered against that teardown.
///
/// The same message BEFORE the close is asserted to arrive, because without it this test would pass
/// just as well against a DATA lane that was never wired to the sink at all.
#[test]
fn nothing_reaches_the_sink_after_the_end() {
    let harness = Harness::new();
    let (transport, recorder, mut peer) = opened(&harness);
    let channel_id = transport.channel_id();
    let early = WireMessage::Output {
        seq: 8,
        bytes: b"before the end".to_vec(),
    };
    let late = WireMessage::Output {
        seq: 9,
        bytes: b"after the end".to_vec(),
    };

    peer.data.send(&carrying(channel_id, &early));
    eventually("the DATA lane to reach the sink at all", || {
        recorder.messages().contains(&early)
    });

    peer.control.send(&MuxFrame::ChannelClose {
        channel_id,
        reason: MuxCloseReason::Retired,
    });
    eventually("the end to reach the sink", || !recorder.ends().is_empty());
    peer.data.send(&carrying(channel_id, &late));

    // Every chance to be delivered, so that "it did not arrive" means suppressed rather than late.
    for _ in 0_u8..100 {
        if recorder.messages().contains(&late) {
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }

    let told = recorder.told();
    let ended_at = told
        .iter()
        .position(|told| matches!(*told, Told::Ended(_)))
        .expect("the end was recorded");
    let after = told.get(ended_at + 1..).unwrap_or(&[]);
    assert!(
        after.is_empty(),
        "the sink was told {after:?} after it was told the channel ended"
    );
    // The suppression is this transport's doing and not the mux's: the lane that swallowed the
    // message is still open enough to send on.
    assert!(
        transport.send_input(b"x").is_ok(),
        "the DATA lane was not still live, so the test proved nothing about the forwarder"
    );
    transport.close();
}

/// Both lanes reach the ONE sink, with the payload the peer sent. The merge is what makes the door
/// above this a single stream, and a lane wired to nothing would be invisible to every other test
/// here — `send` would still work on it.
#[test]
fn inbound_from_both_lanes_reaches_the_sink_intact() {
    let harness = Harness::new();
    let (transport, recorder, mut peer) = opened(&harness);
    let channel_id = transport.channel_id();
    let output = WireMessage::Output {
        seq: 7,
        bytes: b"\x1b[1mhello\x1b[0m".to_vec(),
    };
    let title = WireMessage::Title("pane".to_owned());

    peer.data.send(&carrying(channel_id, &output));
    peer.control.send(&carrying(channel_id, &title));
    eventually("both lanes' messages to reach the sink", || {
        recorder.messages().len() >= 2
    });

    // Two lanes are two threads, so the order BETWEEN them is not a property and asserting one
    // would be asserting a scheduler. That both arrived, unchanged, is.
    let seen = recorder.messages();
    assert_eq!(
        seen.len(),
        2,
        "the sink was told something else as well: {seen:?}"
    );
    assert!(
        seen.contains(&output),
        "the DATA lane's message did not arrive: {seen:?}"
    );
    assert!(
        seen.contains(&title),
        "the CONTROL lane's message did not arrive: {seen:?}"
    );
    transport.close();
}

/// Credit is granted at CONSUMPTION, and the grant rides CONTROL. Both halves are here because
/// either one alone is satisfiable by a wrong wiring: a grant on DATA would queue behind the flood
/// it is meant to open, and a grant at demux would let a flooding pane commit the window to bytes
/// nothing has rendered.
///
/// The sub-threshold consume is asserted by the COUNT rather than by a wait for silence: one grant
/// in total is only reachable if the first call accumulated instead of emitting, and the granted
/// figure includes its byte, which is what proves it was accumulated rather than discarded.
#[test]
fn note_output_consumed_grants_credit_on_the_control_link() {
    let harness = Harness::new();
    let (transport, _recorder, mut peer) = opened(&harness);
    let window = usize::try_from(MuxFlowControl::initial_window_bytes()).expect("a positive window");

    // Below the accountant's half-window threshold: pending credit, and nothing on the wire.
    transport.note_output_consumed(1);
    // Across it: the whole accumulation is granted at once.
    transport.note_output_consumed(window);

    eventually("the grant to reach the wire", || {
        peer.pump();
        !peer.control.grants().is_empty()
    });
    assert_eq!(
        peer.control.grants(),
        vec![u32::try_from(window + 1).expect("the grant fits a u32")],
        "one grant, for everything consumed"
    );
    assert!(
        peer.data.grants().is_empty(),
        "a grant rode the flooded lane it exists to open"
    );
    transport.close();
}

/// A caller that saw the end and a caller that decided to leave are the same caller, and it does
/// not know which of them ran first — so the second `close` must be free. What it must not do is
/// release the pool entry twice: the id is gone from the entry by then, so a second release would
/// decrement nothing, but a second `channelClose` would still reach a peer that has already retired
/// the pane.
#[test]
fn close_is_idempotent_and_releases_the_pool_entry() {
    let harness = Harness::new();
    let (transport, recorder, mut peer) = opened(&harness);
    assert_eq!(harness.registry.channel_count(&endpoint()), 1);

    transport.close();
    assert_eq!(
        harness.registry.channel_count(&endpoint()),
        0,
        "the pool still counts a closed channel"
    );
    assert_eq!(
        harness.registry.pooled_connection_count(),
        0,
        "the last channel's close left the connection pooled"
    );
    // `close` joins both forwarders, so the end has already been delivered by the time it returns.
    assert_eq!(recorder.ends(), vec![ChannelEnd::Local]);

    transport.close();
    assert_eq!(harness.registry.channel_count(&endpoint()), 0);
    assert_eq!(
        recorder.ends().len(),
        1,
        "the second close announced a second end"
    );

    eventually("the close to reach the peer on both lanes", || {
        peer.pump();
        peer.data.closes() >= 1 && peer.control.closes() >= 1
    });
    assert_eq!(peer.data.closes(), 1, "the DATA lane carried a second close");
    assert_eq!(
        peer.control.closes(),
        1,
        "the CONTROL lane carried a second close"
    );
}
