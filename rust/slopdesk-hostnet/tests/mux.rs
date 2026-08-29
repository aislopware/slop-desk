//! The whole host stack against a real client on real sockets.
//!
//! Stage A's suite stops at the preamble: two sockets pair, and bytes cross. This one starts where
//! that ends and drives the thing hostd actually is — a client dials, sends a `channelOpen`, is
//! answered, streams input through the mux and closes — with nothing faked between the socket and
//! the channel. Every frame below is built by `slopdesk_wire::mux` and written to a `TcpStream`, so
//! a decode that disagreed with the encoder would fail here rather than in production.
//!
//! There is no in-memory link double: the crate already has one (`Recorder`, in `subchannel`'s unit
//! tests) for the questions that do not need a socket, and the questions here all do.

#![expect(
    clippy::expect_used,
    clippy::panic,
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, Shutdown, TcpStream};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use slopdesk_hostnet::listener::{Listener, ListenerHandle};
use slopdesk_muxnet::connection::{ChannelOpen, ConnectionThreads, MuxConnection, MuxEvent};
use slopdesk_muxnet::preamble::{ConnectionId, Lane, Preamble, encode as encode_preamble};
use slopdesk_wire::mux::admission::Role;
use slopdesk_wire::{MuxCloseReason, MuxFrame, MuxFrameDecoder, WireMessage};

/// Long enough that a loaded machine does not fail this suite, short enough that a real hang does.
const GENEROUS: Duration = Duration::from_secs(10);

/// A client's two sockets, and the host connection they were paired into.
struct Wired {
    control: TcpStream,
    data: TcpStream,
    host: Arc<MuxConnection>,
    events: Receiver<MuxEvent>,
    listener: ListenerHandle,
    threads: ConnectionThreads,
}

impl Wired {
    /// Binds, dials both lanes, and serves the pair — the whole way in, once.
    fn up() -> Self {
        let listener = Listener::bind(0).expect("bind an ephemeral port");
        let port = listener.bound_port();
        let (pairs, listener) = listener.serve();
        let id = ConnectionId::from_bytes([42; 16]);
        let control = dial(port, Lane::Control, id);
        let data = dial(port, Lane::Data, id);
        let pair = pairs.recv_timeout(GENEROUS).expect("the two sockets pair");
        let (host, events, threads) = MuxConnection::serve(pair, Role::Host);
        Self {
            control,
            data,
            host,
            events,
            listener,
            threads,
        }
    }

    fn next_event(&self) -> MuxEvent {
        self.events.recv_timeout(GENEROUS).expect("an event arrives")
    }

    fn no_event_within(&self, bound: Duration) {
        match self.events.recv_timeout(bound) {
            Err(RecvTimeoutError::Timeout) => {},
            other => panic!("expected silence, got {other:?}"),
        }
    }

    /// Opens a channel the way the client does and takes the host's side of it.
    fn open(&mut self, channel_id: u32) -> ChannelOpen {
        write_frame(&mut self.data, &MuxFrame::ChannelOpen {
            channel_id,
            session_id: [0; 16],
            last_received_seq: 0,
            channel_class: 0,
            initial_cwd: Some("/tmp".to_owned()),
        });
        match self.next_event() {
            MuxEvent::Opened(open) => *open,
            other => panic!("expected an open, got {other:?}"),
        }
    }

    fn shut_down(self) {
        self.host.close();
        self.threads.join();
        self.listener.stop();
    }
}

fn dial(port: u16, lane: Lane, connection: ConnectionId) -> TcpStream {
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect to the listener");
    stream
        .write_all(&encode_preamble(Preamble { lane, connection }))
        .expect("write the preamble");
    stream
        .set_read_timeout(Some(GENEROUS))
        .expect("bound every client read so a hang fails rather than wedges");
    stream
}

fn write_frame(stream: &mut TcpStream, frame: &MuxFrame) {
    stream.write_all(&frame.encode()).expect("write a mux frame");
}

/// Reads until one whole mux frame is available on `stream`.
fn read_frame(stream: &mut TcpStream, decoder: &mut MuxFrameDecoder) -> MuxFrame {
    loop {
        if let Some(frame) = decoder.next_frame().expect("the host writes whole frames") {
            return frame;
        }
        let mut buf = [0_u8; 4096];
        let read = stream.read(&mut buf).expect("read from the host");
        assert_ne!(read, 0, "the host closed before answering");
        decoder.append(&buf[..read]);
    }
}

#[test]
fn a_client_open_becomes_a_channel_and_its_input_reaches_the_pane() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    assert_eq!(open.channel_id, 1);
    assert_eq!(open.initial_cwd.as_deref(), Some("/tmp"));

    // The host answers on the DATA link — the only link an open is initiated on.
    wired.host.send_open_ack(1, true, 0);
    let mut decoder = MuxFrameDecoder::new();
    assert!(
        matches!(
            read_frame(&mut wired.data, &mut decoder),
            MuxFrame::ChannelOpenAck {
                channel_id: 1,
                accepted: true,
                ..
            }
        ),
        "the ack rides DATA",
    );

    // A keystroke, wrapped the way the client wraps it: an inner frame inside a `channelData` body.
    let keystroke = WireMessage::Input(b"ls -la\r".to_vec());
    write_frame(&mut wired.data, &MuxFrame::ChannelData {
        channel_id: 1,
        payload: keystroke.encode(),
    });
    assert_eq!(
        open.data_inbound
            .recv_timeout(GENEROUS)
            .expect("the keystroke arrives"),
        keystroke,
    );

    wired.shut_down();
}

/// A frame split across two writes must still reassemble — the whole reason the decoders are
/// streaming rather than message-at-a-time.
#[test]
fn a_frame_split_across_two_writes_is_reassembled() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    let keystroke = WireMessage::Input(b"a much longer line of input than one byte".to_vec());
    let bytes = MuxFrame::ChannelData {
        channel_id: 1,
        payload: keystroke.encode(),
    }
    .encode();
    let (head, tail) = bytes.split_at(7);
    wired.data.write_all(head).expect("write the head");
    wired.data.flush().expect("flush");
    wired.data.write_all(tail).expect("write the tail");
    assert_eq!(
        open.data_inbound
            .recv_timeout(GENEROUS)
            .expect("the whole message arrives"),
        keystroke,
    );
    wired.shut_down();
}

/// Control frames route on the CONTROL link, and never onto the data channel.
#[test]
fn the_two_lanes_are_not_crossed() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    let resize = WireMessage::Resize {
        cols: 120,
        rows: 40,
        px_width: 0,
        px_height: 0,
    };
    write_frame(&mut wired.control, &MuxFrame::ChannelData {
        channel_id: 1,
        payload: resize.encode(),
    });
    assert_eq!(
        open.control_inbound
            .recv_timeout(GENEROUS)
            .expect("the resize arrives"),
        resize,
    );
    assert!(
        open.data_inbound.try_recv().is_err(),
        "a resize on CONTROL must not surface on the DATA channel",
    );
    wired.shut_down();
}

/// Credit-at-consumption: the grant follows a real consumer, and it rides CONTROL.
#[test]
fn consuming_a_window_grants_credit_back_on_the_control_link() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    let window = usize::try_from(slopdesk_wire::MuxFlowControl::initial_window_bytes()).unwrap();
    open.data.note_consumed(window);

    let mut decoder = MuxFrameDecoder::new();
    let frame = read_frame(&mut wired.control, &mut decoder);
    assert!(
        matches!(frame, MuxFrame::WindowAdjust { channel_id: 1, .. }),
        "the grant names the channel and rides CONTROL: {frame:?}",
    );
    wired.shut_down();
}

/// The peer closing ONE channel is a decision, reported once with the reason it gave.
#[test]
fn a_peer_close_reports_the_reason_and_finishes_both_sub_channels() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    write_frame(&mut wired.data, &MuxFrame::ChannelClose {
        channel_id: 1,
        reason: MuxCloseReason::SubscriberEvicted,
    });
    match wired.next_event() {
        MuxEvent::Closed { channel_id, reason } => {
            assert_eq!(channel_id, 1);
            assert_eq!(
                reason,
                MuxCloseReason::SubscriberEvicted,
                "the reason decides a reattach from a respawn upstream, so it must survive the trip",
            );
        },
        other => panic!("expected a close, got {other:?}"),
    }
    assert!(open.data.is_finished(), "the named link's channel ends");
    assert!(
        open.control.is_finished(),
        "and so does its sibling — the pair is one pane"
    );
    assert_eq!(wired.host.live_channel_count(), 0);
    wired.shut_down();
}

/// A link dropping is an ACCIDENT: it names no channel, so it reports the ids rather than closing
/// them one by one.
#[test]
fn a_dropped_link_reports_link_down_with_the_ids_that_were_live() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    drop(open); // the host still holds its side
    // A clean hang-up, which is what ⌘Q on the client looks like from here.
    wired
        .data
        .shutdown(Shutdown::Both)
        .expect("the client hangs up on the data link");

    match wired.next_event() {
        MuxEvent::LinkDown { failed, channels } => {
            assert!(!failed, "a client hanging up cleanly is a FIN, not a failure");
            assert_eq!(channels, vec![1]);
        },
        other => panic!("expected a link-down, got {other:?}"),
    }
    // One dead link is a dead connection: the CONTROL link ends too, and reports nothing more.
    wired.no_event_within(Duration::from_millis(200));
    assert_eq!(wired.host.live_channel_count(), 0);

    wired.host.close();
    wired.threads.join();
    wired.listener.stop();
}

/// An open on the CONTROL link is a frame a correct peer cannot send, and there is nobody
/// legitimate to answer.
#[test]
fn an_open_on_the_control_link_is_dropped_without_an_answer() {
    let mut wired = Wired::up();
    write_frame(&mut wired.control, &MuxFrame::ChannelOpen {
        channel_id: 1,
        session_id: [0; 16],
        last_received_seq: 0,
        channel_class: 0,
        initial_cwd: None,
    });
    wired.no_event_within(Duration::from_millis(200));
    assert_eq!(
        wired.host.live_channel_count(),
        0,
        "and no phantom entry is left behind"
    );
    wired.shut_down();
}

/// A retransmitted open for a live id must not mint a second pane: that forks a second shell and
/// orphans the first, leaking its master fd, its child and its reaper.
#[test]
fn a_duplicate_open_for_a_live_id_does_not_mint_a_second_pane() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    write_frame(&mut wired.data, &MuxFrame::ChannelOpen {
        channel_id: 1,
        session_id: [0; 16],
        last_received_seq: 0,
        channel_class: 0,
        initial_cwd: None,
    });
    wired.no_event_within(Duration::from_millis(200));
    assert_eq!(wired.host.live_channel_count(), 1);

    // And the original channel still routes, which is what "suppressed" has to mean.
    let keystroke = WireMessage::Input(b"still here".to_vec());
    write_frame(&mut wired.data, &MuxFrame::ChannelData {
        channel_id: 1,
        payload: keystroke.encode(),
    });
    assert_eq!(open.data_inbound.recv_timeout(GENEROUS).unwrap(), keystroke);
    wired.shut_down();
}

/// Reopening an id that already reached a terminal state is refused with an ANSWER, because the
/// initiator is waiting on one. Ids are monotonic and never reused, so this is a stale retransmit
/// or a peer trying to spend one id on many shells.
#[test]
fn a_reopen_of_a_closed_id_is_refused_rather_than_dropped() {
    let mut wired = Wired::up();
    let _open = wired.open(1);
    write_frame(&mut wired.data, &MuxFrame::ChannelClose {
        channel_id: 1,
        reason: MuxCloseReason::Retired,
    });
    assert!(matches!(wired.next_event(), MuxEvent::Closed {
        channel_id: 1,
        ..
    }));

    write_frame(&mut wired.data, &MuxFrame::ChannelOpen {
        channel_id: 1,
        session_id: [0; 16],
        last_received_seq: 0,
        channel_class: 0,
        initial_cwd: None,
    });
    let mut decoder = MuxFrameDecoder::new();
    assert!(
        matches!(
            read_frame(&mut wired.data, &mut decoder),
            MuxFrame::ChannelOpenAck {
                channel_id: 1,
                accepted: false,
                ..
            }
        ),
        "a refusal is an answer, not a silence",
    );
    wired.no_event_within(Duration::from_millis(200));
    wired.shut_down();
}

/// Two panes on one connection, interleaved on the wire, must not see each other's bytes.
#[test]
fn two_channels_on_one_connection_do_not_cross() {
    let mut wired = Wired::up();
    let first = wired.open(1);
    let second = wired.open(3);
    for (id, text) in [(1_u32, &b"one"[..]), (3, &b"three"[..]), (1, b"one again")] {
        write_frame(&mut wired.data, &MuxFrame::ChannelData {
            channel_id: id,
            payload: WireMessage::Input(text.to_vec()).encode(),
        });
    }
    assert_eq!(
        first.data_inbound.recv_timeout(GENEROUS).unwrap(),
        WireMessage::Input(b"one".to_vec()),
    );
    assert_eq!(
        first.data_inbound.recv_timeout(GENEROUS).unwrap(),
        WireMessage::Input(b"one again".to_vec()),
        "in wire order, which is this link's thread's order",
    );
    assert_eq!(
        second.data_inbound.recv_timeout(GENEROUS).unwrap(),
        WireMessage::Input(b"three".to_vec()),
    );
    wired.shut_down();
}

/// `close` is the owner's, so it is silent: it asked for this and does not need to be told.
#[test]
fn an_owner_close_finishes_the_channels_without_reporting_a_link_down() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    wired.host.close();
    assert!(open.data.is_finished());
    assert!(open.control.is_finished());
    wired.no_event_within(Duration::from_millis(200));
    wired.threads.join();
    wired.listener.stop();
}

/// A `channelOpenAck` is a frame the HOST sends, so one arriving here is spurious or hostile. It is
/// still routed, and the routing rule reads its `accepted` bool: `false` rejects the id, which
/// retires a live channel and reaps the pane behind it. So the frame's own bool has to be carried
/// rather than assumed — assuming `false` would let a peer kill any live pane with fourteen bytes.
#[test]
fn a_spurious_accepted_ack_does_not_retire_a_live_channel() {
    let mut wired = Wired::up();
    let open = wired.open(1);
    write_frame(&mut wired.data, &MuxFrame::ChannelOpenAck {
        channel_id: 1,
        accepted: true,
        resume_from_seq: 0,
    });
    wired.no_event_within(Duration::from_millis(200));

    // Still live: input written after the stray ack reaches the same channel.
    let keystroke = WireMessage::Input(b"still here\r".to_vec());
    write_frame(&mut wired.data, &MuxFrame::ChannelData {
        channel_id: 1,
        payload: keystroke.encode(),
    });
    assert_eq!(
        open.data_inbound
            .recv_timeout(GENEROUS)
            .expect("the channel still routes"),
        keystroke,
    );
    wired.shut_down();
}
