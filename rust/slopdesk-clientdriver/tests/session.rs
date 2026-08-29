//! One connection, end to end: the open it presents, the output it accepts, the acks it sends and
//! the exit that ends it.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.5. This is `SlopDeskClientSmokeTests`,
//! `SlopDeskClientDedupTests`, `SlopDeskClientBatchDrainTests` and
//! `SlopDeskClientExitTerminalTests` — four Swift suites that drove the session actor through a
//! fake transport it defined itself — asked instead of a driver whose bytes went over a socket.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{GENEROUS, Harness, OpenPolicy, PORT, Recorder, Seen, endpoint_host, quiet_config};
use slopdesk_clientdriver::PaneDriver;
use slopdesk_clientsession::seq::ResumeOutcome;
use slopdesk_wire::{MuxFrame, WireMessage};

/// The recorder as the trait object the driver takes.
fn observer(log: &Arc<Recorder>) -> Arc<dyn slopdesk_clientdriver::Observer> {
    Arc::<Recorder>::clone(log)
}

/// A driver on a fresh harness, connected, with the log it wrote.
struct Live {
    harness: Harness,
    driver: PaneDriver,
    log: Arc<Recorder>,
}

fn connected(policy: OpenPolicy, config: slopdesk_clientdriver::DriverConfig) -> Live {
    let harness = Harness::new(policy);
    let log = Arc::new(Recorder::default());
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), config)
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");
    Live { harness, driver, log }
}

/// The whole of a first connection, in the order the wire carries it: an open naming a fresh
/// session and seq zero, then output, then the ack that releases it.
#[test]
fn a_cold_connect_presents_a_new_session_and_acks_what_it_gets() {
    let live = connected(OpenPolicy::Accept(0), quiet_config());
    let host = live.harness.host(0);
    host.wait_opens(1);

    let opens = host.opens();
    let Some(&MuxFrame::ChannelOpen {
        last_received_seq,
        channel_class,
        ..
    }) = opens.first()
    else {
        panic!("the open frame: {opens:?}");
    };
    assert_eq!(last_received_seq, 0, "a cold client has nothing to resume from");
    assert_eq!(channel_class, 0, "the pane class");

    host.send_output(1, b"hello");
    let seen = live.log.wait_until("the wake", |_| live.log.wakes() > 0);
    assert!(
        seen.is_empty(),
        "output is not an event, it is inbox bytes: {seen:?}"
    );

    let mut drained: Vec<Vec<u8>> = Vec::new();
    let taken = live.driver.take_output(|chunk| drained.push(chunk.to_vec()));
    assert_eq!(taken, 1);
    assert_eq!(drained, vec![b"hello".to_vec()]);
    assert_eq!(live.driver.highest_contiguous_seq(), 1);

    host.wait_received("the coalesced ack", |sent| {
        sent.iter()
            .any(|message| matches!(*message, WireMessage::Ack { seq: 1 }))
    });
}

/// The dedup, which is the whole reason the marks exist: a replayed tail splices in gap-free and
/// dup-free, and the bytes already rendered do not arrive twice.
#[test]
fn a_replayed_tail_is_dropped_rather_than_delivered_twice() {
    let live = connected(OpenPolicy::Accept(0), quiet_config());
    let host = live.harness.host(0);
    host.wait_opens(1);

    for seq in 1_i64..=3 {
        host.send_output(seq, format!("{seq}").as_bytes());
    }
    live.log.wait_until("three wakes", |_| live.log.wakes() >= 3);
    let mut first: Vec<Vec<u8>> = Vec::new();
    live.driver.take_output(|chunk| first.push(chunk.to_vec()));
    assert_eq!(first, vec![b"1".to_vec(), b"2".to_vec(), b"3".to_vec()]);

    // The tail the host would replay after a reattach: every seq already fed, plus one that is not.
    for seq in 1_i64..=4 {
        host.send_output(seq, format!("{seq}").as_bytes());
    }
    live.log.wait_until("the fourth wake", |_| live.log.wakes() >= 4);
    let mut second: Vec<Vec<u8>> = Vec::new();
    live.driver.take_output(|chunk| second.push(chunk.to_vec()));
    assert_eq!(second, vec![b"4".to_vec()], "only the seq past the mark is new");
    assert_eq!(live.driver.highest_contiguous_seq(), 4);
}

/// A drain takes the WHOLE backlog atomically and leaves nothing behind it, which is what makes the
/// consumer's "one wake, one batch, one render flush" contract true.
#[test]
fn a_drain_empties_the_inbox_in_one_take() {
    let live = connected(OpenPolicy::Accept(0), quiet_config());
    let host = live.harness.host(0);
    host.wait_opens(1);

    for seq in 1_i64..=5 {
        host.send_output(seq, b"x");
    }
    live.log.wait_until("five wakes", |_| live.log.wakes() >= 5);

    let mut batch = 0_usize;
    let taken = live.driver.take_output(|_| batch += 1);
    assert_eq!(taken, 5);
    assert_eq!(batch, 5);
    let again = live.driver.take_output(|_| panic!("the inbox was not emptied"));
    assert_eq!(again, 0);
}

/// The exit is TERMINAL: it reaches the near side as an event, it is recorded before that event
/// goes out, and a connect after it is refused rather than spawning a shell into an inbox no
/// consumer will drain.
#[test]
fn a_child_exit_is_terminal_for_the_session() {
    let live = connected(OpenPolicy::Accept(0), quiet_config());
    let host = live.harness.host(0);
    host.wait_opens(1);

    host.send(&WireMessage::Exit { code: 3 });
    live.log.wait_until("the exit event", |seen| {
        seen.iter()
            .any(|one| matches!(*one, Seen::Message(WireMessage::Exit { code: 3 })))
    });
    assert!(live.driver.is_exited());

    let refused = live
        .driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect_err("a connect after the child exited");
    assert!(
        matches!(refused, slopdesk_clientdriver::ConnectError::Refused(_)),
        "{refused:?}"
    );
}

/// The resume verdict, which gates a surface wipe: a first seq PAST the presented mark is the same
/// shell, and anything else is a new one.
#[test]
fn a_seq_past_the_presented_mark_reads_as_the_same_shell() {
    let harness = Harness::new(OpenPolicy::Accept(7));
    let log = Arc::new(Recorder::default());
    let mut config = quiet_config();
    config.resume_seed = Some(slopdesk_clientdriver::ResumeSeed {
        session_id: [9; 16],
        last_seq: 7,
    });
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), config)
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");

    let host = harness.host(0);
    host.wait_opens(1);
    let opens = host.opens();
    let Some(&MuxFrame::ChannelOpen {
        session_id,
        last_received_seq,
        ..
    }) = opens.first()
    else {
        panic!("the open frame: {opens:?}");
    };
    assert_eq!(session_id, [9; 16], "a seeded pane presents the id it held");
    assert_eq!(last_received_seq, 7, "and the seq it last rendered");

    assert_eq!(driver.resume_outcome(), ResumeOutcome::Undetermined);
    host.send_output(8, b"tail");
    log.wait_until("the wake", |_| log.wakes() > 0);
    assert_eq!(driver.resume_outcome(), ResumeOutcome::ResumedSession);
    assert_eq!(
        driver.highest_contiguous_seq(),
        8,
        "a real resume keeps its seeded marks"
    );
}

/// A host that refuses the class answers the connect rather than leaving it to time out, and the
/// three ways a verdict can fail to arrive read alike.
#[test]
fn a_refused_open_fails_the_connect() {
    let harness = Harness::new(OpenPolicy::Refuse);
    let log = Arc::new(Recorder::default());
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), quiet_config())
        .expect("the supervisor thread starts");
    let failure = driver
        .connect(endpoint_host(), PORT, Duration::from_secs(2))
        .expect_err("a refused open");
    assert!(
        matches!(failure, slopdesk_clientdriver::ConnectError::NoVerdict),
        "{failure:?}"
    );
    assert!(!driver.is_connected(), "nothing was adopted");
}
