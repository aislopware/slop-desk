//! The initiator's half: minting a channel, and collecting the verdict on it.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.2. `role.rs` proves that nothing on the RECEIVING
//! side reads the role; this file is the one place that does — `open_channel` refuses at a
//! responder, because `admit` judges arrivals and an open going out is not one.
//!
//! The rest of it is the openAck rendezvous, and every test here is about the same obligation from
//! a different side: **a waiter must be answered.** A verdict, a refusal, a close, a dead link and
//! an elapsed bound are five ways for the answer to arrive, and the only bug this rendezvous can
//! have is a sixth way for it not to.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

use std::io::Read as _;
use std::net::TcpStream;
use std::thread;
use std::time::{Duration, Instant};

use slopdesk_muxnet::connection::{MuxEvent, OpenAck, OpenFailure, OpenRequest};
use slopdesk_wire::MuxFrame;
use slopdesk_wire::mux::admission::Role;
use slopdesk_wire::mux::{MuxCloseReason, MuxFrameDecoder};

mod common;

use common::{GENEROUS, SETTLE, Wired, write_all};

/// The responder's answer. Only this file writes one, because only an initiator waits for it.
fn ack_frame(channel_id: u32, accepted: bool, resume_from_seq: i64) -> Vec<u8> {
    MuxFrame::ChannelOpenAck {
        channel_id,
        accepted,
        resume_from_seq,
    }
    .encode()
}

/// Reads until one whole frame has arrived from the connection under test.
///
/// Bounded by a socket read timeout so a frame that is never sent fails the test rather than
/// hanging it — the same reason [`GENEROUS`] exists for the event channel.
fn read_frame(socket: &TcpStream) -> MuxFrame {
    socket
        .set_read_timeout(Some(GENEROUS))
        .expect("bound the read so a missing frame fails rather than hangs");
    let mut socket = socket;
    let mut decoder = MuxFrameDecoder::new();
    let mut buffer = [0_u8; 512];
    loop {
        if let Ok(Some((frame, _payload))) = decoder.next_frame_leaving_payload() {
            return frame;
        }
        let read = socket
            .read(&mut buffer)
            .expect("read a frame from the connection");
        assert!(read > 0, "the connection closed instead of sending a frame");
        decoder.append(buffer.get(..read).expect("the read is within the buffer"));
    }
}

/// A bound short enough that meeting it proves the waiter was WOKEN rather than merely bounded.
const IMPATIENT: Duration = Duration::from_millis(100);

fn request() -> OpenRequest {
    OpenRequest {
        session_id: [9; 16],
        last_received_seq: 3,
        channel_class: 0,
        initial_cwd: Some("/tmp".to_owned()),
    }
}

/// The frame the responder is waiting for, with the fields the caller asked for, on the link an
/// open is initiated on — and one channel registered here to receive the answer.
#[test]
fn an_open_reaches_the_data_link_carrying_what_was_asked_for() {
    let wired = Wired::up(Role::Client);
    let opened = wired
        .connection
        .open_channel(&request())
        .expect("a client may open a channel");

    match read_frame(&wired.peer_data) {
        MuxFrame::ChannelOpen {
            channel_id,
            session_id,
            last_received_seq,
            channel_class,
            initial_cwd,
        } => {
            assert_eq!(channel_id, opened.channel_id);
            assert_eq!(channel_id % 2, 1, "the initiator allocates ODD ids");
            assert_eq!(session_id, [9; 16]);
            assert_eq!(last_received_seq, 3);
            assert_eq!(channel_class, 0);
            assert_eq!(initial_cwd.as_deref(), Some("/tmp"));
        },
        other => panic!("the open did not reach the DATA link: {other:?}"),
    }
    assert_eq!(wired.connection.live_channel_count(), 1);
    wired.down();
}

/// `Role::initiates_opens`, spent on the sending side.
///
/// A responder registers the ids it is SHOWN. One that minted its own would hand out an id from a
/// space the initiator is also allocating from, so two panes would collide on one channel — and
/// `admit` cannot catch it, because by then the frame has been sent.
#[test]
fn a_responder_refuses_to_initiate_an_open() {
    let wired = Wired::up(Role::Host);
    assert!(
        matches!(
            wired.connection.open_channel(&request()),
            Err(OpenFailure::NotInitiator)
        ),
        "a responder minted a channel id of its own"
    );
    assert_eq!(
        wired.connection.live_channel_count(),
        0,
        "the refused open registered a channel anyway"
    );
    wired.down();
}

/// The verdict is the whole reason to wait: the responder decides where a resumed pane restarts
/// from, and the initiator's own `last_received_seq` was only a request.
#[test]
fn the_verdict_the_responder_sends_is_the_verdict_the_waiter_reads() {
    let wired = Wired::up(Role::Client);
    let opened = wired.connection.open_channel(&request()).expect("open");
    write_all(&wired.peer_data, &ack_frame(opened.channel_id, true, 4242));

    assert_eq!(
        wired.connection.await_open_ack(opened.channel_id, GENEROUS),
        OpenAck {
            accepted: true,
            resume_from_seq: 4242,
        }
    );
    wired.down();
}

/// The ack routinely beats the caller: the host opens on the first `channelOpen`, so on a mesh link
/// the answer can be back before the pane above has finished being told the channel exists. A
/// rendezvous that only resolved PARKED waiters would drop it, and the first ask would then wait
/// out its whole bound for a frame that already arrived.
#[test]
fn an_ack_that_arrives_before_anyone_asks_is_still_collected() {
    let wired = Wired::up(Role::Client);
    let opened = wired.connection.open_channel(&request()).expect("open");
    write_all(&wired.peer_data, &ack_frame(opened.channel_id, true, 7));
    thread::sleep(SETTLE);

    // A ZERO bound: this can only pass on a verdict that was already recorded.
    assert_eq!(
        wired.connection.await_open_ack(opened.channel_id, Duration::ZERO),
        OpenAck {
            accepted: true,
            resume_from_seq: 7,
        }
    );
    wired.down();
}

/// A verdict is the answer to a handshake, not a state, so it is collected once. An id nobody
/// opened gets the same answer, which is the phantom-id discipline: a peer cannot make this end
/// remember an id by sending an ack for it.
#[test]
fn a_verdict_is_collected_once_and_an_unknown_id_is_refused() {
    let wired = Wired::up(Role::Client);
    let opened = wired.connection.open_channel(&request()).expect("open");
    write_all(&wired.peer_data, &ack_frame(opened.channel_id, true, 11));

    assert!(
        wired
            .connection
            .await_open_ack(opened.channel_id, GENEROUS)
            .accepted
    );
    assert_eq!(
        wired.connection.await_open_ack(opened.channel_id, IMPATIENT),
        OpenAck::REFUSED,
        "the same verdict was handed out twice"
    );
    assert_eq!(
        wired.connection.await_open_ack(9999, IMPATIENT),
        OpenAck::REFUSED,
        "an id this end never opened was waited on rather than refused"
    );
    wired.down();
}

/// A refusal is an ANSWER, and it must reach the waiter as one — with the channel retired behind
/// it, since a refused channel never opened.
#[test]
fn a_refusal_reaches_the_waiter_and_retires_the_channel() {
    let wired = Wired::up(Role::Client);
    let opened = wired.connection.open_channel(&request()).expect("open");
    write_all(&wired.peer_data, &ack_frame(opened.channel_id, false, 0));

    let verdict = wired.connection.await_open_ack(opened.channel_id, GENEROUS);
    assert!(!verdict.accepted);
    thread::sleep(SETTLE);
    assert_eq!(
        wired.connection.live_channel_count(),
        0,
        "a refused channel stayed registered, so the pool would never retire this connection"
    );
    wired.down();
}

/// THE trap of this stage. A waiter parks on a condvar, not on the link, so a dead link reaches it
/// only if the teardown goes and tells it. Without that a reconnecting client parks on a corpse for
/// as long as its bound allows, which in the Swift was forever.
#[test]
fn a_dead_link_wakes_a_parked_waiter() {
    let wired = Wired::up(Role::Client);
    let opened = wired.connection.open_channel(&request()).expect("open");

    let connection = std::sync::Arc::clone(&wired.connection);
    let channel_id = opened.channel_id;
    let parked = thread::spawn(move || {
        let started = Instant::now();
        (connection.await_open_ack(channel_id, GENEROUS), started.elapsed())
    });
    thread::sleep(SETTLE); // let it park, so this proves a wake rather than an early return
    drop(wired.peer_data);
    drop(wired.peer_control);

    let (verdict, waited) = parked.join().expect("the waiter thread panicked");
    assert_eq!(verdict, OpenAck::REFUSED);
    assert!(
        waited < GENEROUS / 2,
        "the waiter timed out rather than being woken: {waited:?}"
    );
    // The owner hears about the same death, and hears about the channel that was on it — the waiter
    // being answered is not INSTEAD of the event, it is the half of the teardown a condvar owes.
    match wired.events.recv_timeout(GENEROUS) {
        Ok(MuxEvent::LinkDown { channels, .. }) => assert_eq!(channels, vec![channel_id]),
        other => panic!("the dead link was not reported to the owner: {other:?}"),
    }
    wired.connection.close();
    wired.threads.join();
}

/// The same obligation one channel down: a connect that raced its own teardown closes the channel
/// it just opened, and the waiter it left behind is owed an answer by that close.
#[test]
fn closing_a_channel_wakes_a_waiter_that_will_never_hear() {
    let wired = Wired::up(Role::Client);
    let opened = wired.connection.open_channel(&request()).expect("open");

    let connection = std::sync::Arc::clone(&wired.connection);
    let channel_id = opened.channel_id;
    let parked = thread::spawn(move || {
        let started = Instant::now();
        (connection.await_open_ack(channel_id, GENEROUS), started.elapsed())
    });
    thread::sleep(SETTLE);
    wired
        .connection
        .close_channel(channel_id, MuxCloseReason::Retired);

    let (verdict, waited) = parked.join().expect("the waiter thread panicked");
    assert_eq!(verdict, OpenAck::REFUSED);
    assert!(
        waited < GENEROUS / 2,
        "the close did not wake the waiter: {waited:?}"
    );
    assert_eq!(wired.connection.live_channel_count(), 0);
    wired.down();
}

/// A pooled connection outlives the pane that made it, so a reconnecting pane can be handed one
/// whose links died a moment ago. Registering a channel on it would leave one nothing ever
/// finishes, holding the live count above zero and keeping the corpse pooled forever.
#[test]
fn an_open_on_a_dead_connection_registers_nothing() {
    let wired = Wired::up(Role::Client);
    wired.connection.close();

    assert!(
        matches!(
            wired.connection.open_channel(&request()),
            Err(OpenFailure::LinkDown)
        ),
        "a channel was opened on a torn-down connection"
    );
    assert_eq!(wired.connection.live_channel_count(), 0);
    drop(wired.peer_control);
    drop(wired.peer_data);
    wired.threads.join();
}
