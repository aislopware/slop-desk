//! Output that lands BEFORE the open's verdict.
//!
//! A host's first frames ride the DATA link and its `channelOpenAck` rides the CONTROL link, and
//! the kernel orders nothing between two sockets. A restored transcript, a reattach's replayed
//! tail and the first prompt bytes can all reach the client while `connect()` is still waiting for
//! the ack — with the previous connection's marks, the previous connection's verdict and no
//! transport to credit. Every case here forces that order by holding the ack back until the data
//! is on the wire, and asserts the three things a pre-ack byte must keep: it is handed up, it is
//! credited to the connection that carried it, and the marks and the verdict describe it.

#![expect(
    clippy::expect_used,
    clippy::integer_division,
    reason = "a panic in a test is the failure report; the byte counts are whole chunks by construction"
)]

mod common;

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use common::{GENEROUS, Harness, OpenPolicy, PORT, Recorder, endpoint_host, observer, quiet_config};
use slopdesk_clientdriver::{DriverConfig, PaneDriver, ResumeSeed};
use slopdesk_clientsession::seq::ResumeOutcome;

/// One `output` frame's payload.
const CHUNK: usize = 4096;

/// What one `output` frame costs on the wire beyond its payload — the count `credited` sums.
const FRAME_OVERHEAD: u64 = 13;

/// The saved pane, as the client persisted it before the app went away.
const SAVED: [u8; 16] = [0xAB; 16];

/// Long enough that the data is folded — or staged — before the ack can possibly arrive.
const HOLD_THE_ACK: Duration = Duration::from_millis(200);

/// The receive window's grant point: consumed credit is granted back all at once when it reaches
/// half the window, so a run's `credited` is the total consumed minus a remainder below this.
const GRANT_POINT: u64 = 32 * 1024;

/// What one run of the host's pre-ack shape left behind.
struct Outcome {
    /// Every window grant the host received, summed.
    credited: u64,
    /// The client's contiguous mark afterwards.
    highest: i64,
    /// Payload bytes the near side was handed.
    handed: usize,
    /// The resume verdict for the connection.
    verdict: ResumeOutcome,
}

/// How the host behaves around the ack.
struct Shape {
    /// Output bytes sent BEFORE the ack, on the data lane.
    before: usize,
    /// Output bytes sent AFTER `connect()` returned.
    after: usize,
    /// The identity the client was restored with, if any.
    seed: Option<i64>,
    /// The resume seq the ack names.
    resume: i64,
    /// The seq of the first `output` frame.
    first_seq: i64,
    /// How long the host waits between its last pre-ack frame and the ack.
    hold: Duration,
}

/// The wire cost of `frames` frames of `bytes` payload in total.
fn wire_cost(bytes: usize, frames: usize) -> u64 {
    u64::try_from(bytes).expect("small") + FRAME_OVERHEAD * u64::try_from(frames).expect("small")
}

/// Runs one connect against a host of the given shape and reports what it left.
fn run(shape: &Shape) -> Outcome {
    let harness = Harness::new(OpenPolicy::Ignore);
    let log = Arc::new(Recorder::default());
    let config = DriverConfig {
        resume_seed: shape.seed.map(|last_seq| {
            ResumeSeed {
                session_id: SAVED,
                last_seq,
            }
        }),
        ..quiet_config()
    };
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), config)
        .expect("the supervisor thread starts");
    let hosts = Arc::clone(&harness.hosts);
    let frames_before = shape.before / CHUNK;
    let first_seq = shape.first_seq;
    let resume = shape.resume;
    let hold = shape.hold;
    // The host's side of the race, on its own thread: the dial is still inside `connect()` when
    // these frames go out, which is the whole point.
    let host_side = thread::spawn(move || {
        let deadline = Instant::now() + GENEROUS;
        let host = loop {
            if let Some(host) = hosts.lock().expect("hosts").first() {
                break Arc::clone(host);
            }
            assert!(Instant::now() < deadline, "the driver never dialled");
            thread::sleep(Duration::from_millis(2));
        };
        host.wait_opens(1);
        for frame in 0..frames_before {
            let seq = first_seq + i64::try_from(frame).expect("small");
            host.send_output(seq, &[b'a'; CHUNK]);
        }
        thread::sleep(hold);
        host.ack(resume);
    });
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");
    host_side.join().expect("the host side");

    let host = harness.host(0);
    let frames_after = shape.after / CHUNK;
    for frame in 0..frames_after {
        let seq = first_seq + i64::try_from(frames_before + frame).expect("small");
        host.send_output(seq, &[b'a'; CHUNK]);
    }
    let expected = shape.before + shape.after;
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut handed = 0_usize;
    while handed < expected && Instant::now() < deadline {
        driver.take_output(|bytes| handed += bytes.len());
        thread::sleep(Duration::from_millis(2));
    }
    // One more take after a pause, so a byte that arrived late is counted rather than missed, and
    // a flush so the credit the last take issued is on the wire before it is read.
    thread::sleep(Duration::from_millis(100));
    driver.take_output(|bytes| handed += bytes.len());
    driver.flush_ack();
    thread::sleep(Duration::from_millis(100));
    Outcome {
        credited: host.credited(),
        highest: driver.highest_contiguous_seq(),
        handed,
        verdict: driver.resume_outcome(),
    }
}

/// A cold client and a host that sends nothing before the ack: the shape every other suite runs,
/// pinned here so the numbers below have a baseline.
#[test]
fn everything_after_the_ack_is_handed_up_and_credited() {
    let out = run(&Shape {
        before: 0,
        after: 64 * 1024,
        seed: None,
        resume: 0,
        first_seq: 1,
        hold: Duration::ZERO,
    });
    assert_eq!(out.handed, 64 * 1024);
    assert_eq!(out.credited, wire_cost(64 * 1024, 16));
    assert_eq!(out.highest, 16);
    assert_eq!(out.verdict, ResumeOutcome::FreshShell);
}

/// Half a window before the ack: the bytes reach the screen, the host gets its window back, and
/// the marks count them.
#[test]
fn output_that_beats_the_ack_keeps_its_credit_and_its_marks() {
    let out = run(&Shape {
        before: 32 * 1024,
        after: 32 * 1024,
        seed: None,
        resume: 0,
        first_seq: 1,
        hold: HOLD_THE_ACK,
    });
    assert_eq!(
        out.handed,
        64 * 1024,
        "bytes delivered before the ack are handed up"
    );
    assert_eq!(
        out.credited,
        wire_cost(64 * 1024, 16),
        "bytes delivered before the ack are credited to the connection that carried them"
    );
    assert_eq!(out.highest, 16, "the marks describe what was handed up");
    assert_eq!(out.verdict, ResumeOutcome::FreshShell);
}

/// A restore the size of the whole window, all of it before the ack. The host has spent every
/// byte of credit it holds and parks until it is granted back — so a client that dropped this
/// credit would leave the pane showing its restored transcript and never another byte.
#[test]
fn a_host_that_spends_its_whole_window_before_the_ack_gets_it_back() {
    let out = run(&Shape {
        before: 64 * 1024,
        after: 0,
        seed: None,
        resume: 0,
        first_seq: 1,
        hold: HOLD_THE_ACK,
    });
    assert_eq!(out.handed, 64 * 1024);
    assert_eq!(out.credited, wire_cost(64 * 1024, 16));
    assert_eq!(out.highest, 16);
}

/// A restored pane presents its saved seq, the host answers with a FRESH shell (resume 0) whose
/// restored transcript numbers from 1 — every seq of which is BELOW the saved mark. Folded before
/// the reset, those seqs would be duplicates of a session that no longer exists.
#[test]
fn a_restore_below_a_seeded_mark_is_not_a_duplicate_once_the_marks_reset() {
    let out = run(&Shape {
        before: 32 * 1024,
        after: 32 * 1024,
        seed: Some(500),
        resume: 0,
        first_seq: 1,
        hold: HOLD_THE_ACK,
    });
    assert_eq!(
        out.handed,
        64 * 1024,
        "the restored transcript reaches the screen"
    );
    assert_eq!(out.credited, wire_cost(64 * 1024, 16));
    assert_eq!(out.highest, 16);
    assert_eq!(out.verdict, ResumeOutcome::FreshShell);
}

/// A reattach whose replayed tail lands entirely before the ack. The verdict must be resolved
/// against the seq THIS connection presented, and it can only be once the ack has been adopted —
/// a verdict given by the first pre-ack byte would be reset by the adoption and never re-asked,
/// and the near side reads an undetermined verdict as a fresh shell and wipes the screen.
#[test]
fn a_reattach_whose_whole_tail_beats_the_ack_still_reads_as_resumed() {
    let out = run(&Shape {
        before: 40 * 1024,
        after: 0,
        seed: Some(500),
        resume: 500,
        first_seq: 501,
        hold: HOLD_THE_ACK,
    });
    assert_eq!(out.handed, 40 * 1024);
    assert_eq!(out.credited, wire_cost(40 * 1024, 10));
    assert_eq!(out.highest, 510);
    assert_eq!(
        out.verdict,
        ResumeOutcome::ResumedSession,
        "a tail past the presented seq is the same shell"
    );
}

/// The ack and a full window of data sent back to back, so the two lanes race for real and the
/// split between staged and live frames falls wherever the kernel puts it. Whichever order it
/// picks, every byte is handed up and marked, and the host is never left waiting on more than
/// one grant's worth of credit — which is what makes the order not matter.
#[test]
fn either_arrival_order_of_the_data_and_the_ack_yields_the_same_session() {
    for _ in 0..6 {
        let out = run(&Shape {
            before: 64 * 1024,
            after: 0,
            seed: None,
            resume: 0,
            first_seq: 1,
            hold: Duration::ZERO,
        });
        assert_eq!(out.handed, 64 * 1024);
        assert_eq!(out.highest, 16);
        let outstanding = wire_cost(64 * 1024, 16) - out.credited;
        assert!(
            outstanding < GRANT_POINT,
            "the host is owed {outstanding} bytes, a whole grant's worth of credit went missing"
        );
    }
}
