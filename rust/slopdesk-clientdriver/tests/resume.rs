//! What a pane carries across a gap: the identity it presents, whose word resets its marks, and
//! how it decides whether the shell on the other end is the one it left.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.5. This is `SlopDeskClientDetachResumeTests`, whose
//! sixteen cases do not survive as sixteen.
//!
//! Three of them were about a Swift hazard rather than a wire contract. `seedResumeIdentity` was an
//! `async` method on an actor, so `LivePaneSession` seeded the client from an UNAWAITED `Task` and
//! nothing ordered that hop ahead of `connect()`'s own — under a cold-launch restore of many panes
//! the seed could lose the race and the pane would present a fresh id instead of the saved one. The
//! Swift fix threaded the identity through `init(resumeSeed:)`; two tests then read the fields back
//! after construction and a third raced 200 iterations to prove the gap was gone. Here the seed is
//! a field of [`DriverConfig`](slopdesk_clientdriver::DriverConfig), read inside `PaneDriver::new`
//! before the supervisor thread exists. There is no window to race, so there is no test for one —
//! what is left to assert is what the OPEN carried, and that is asserted below and in `session.rs`.
//!
//! `session.rs` already owns the resume path's happy half: a seeded pane presenting its saved id
//! and seq, a host honouring it, and the marks surviving. What is here is the other half — the host
//! refusing to resume, the verdict that follows, and the seq a WARM redial presents.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "a panic in a test is the failure report, not a fault"
)]

mod common;

use std::sync::Arc;

use common::{GENEROUS, Harness, OpenPolicy, PORT, Recorder, Seen, endpoint_host, observer, quiet_config};
use slopdesk_clientdriver::{DriverConfig, PaneDriver, ResumeSeed};
use slopdesk_clientsession::backoff::Backoff;
use slopdesk_clientsession::seq::ResumeOutcome;
use slopdesk_wire::MuxFrame;

/// The saved pane, as the client persisted it before the app went away.
const SAVED: [u8; 16] = [0xAB; 16];

/// `quiet_config`, plus the identity a restored pane was built with.
const fn seeded(last_seq: i64) -> DriverConfig {
    DriverConfig {
        resume_seed: Some(ResumeSeed {
            session_id: SAVED,
            last_seq,
        }),
        ..quiet_config()
    }
}

/// The `(session_id, last_received_seq)` the `index`-th dial put in its open.
fn presented(host: &Arc<common::Host>) -> ([u8; 16], i64) {
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
    (session_id, last_received_seq)
}

/// The cold-launch contract, which is the one place a pane deliberately UNDERSTATES what it has:
/// `SLOPDESK_SCROLLBACK_PERSIST` restores a pane from disk with the saved id but seq ZERO, whatever
/// seq that pane last rendered, so the host replays its whole scrollback ring rather than only the
/// un-acked tail. The bytes are on disk in the client's own journal, but the host is the only side
/// that can splice them back into a LIVE stream, and it does that by being told there is nothing.
#[test]
fn a_cold_launch_presents_the_saved_id_and_nothing_to_resume_from() {
    let harness = Harness::new(OpenPolicy::Accept(0));
    let log = Arc::new(Recorder::default());
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), seeded(0))
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");

    let (session_id, last_received_seq) = presented(&harness.host(0));
    assert_eq!(session_id, SAVED, "the saved pane is what the host must look up");
    assert_eq!(
        last_received_seq, 0,
        "seq zero is what makes the host replay the ring rather than the tail"
    );
}

/// The reset is the HOST's call, never the client's guess, and this is the case where the two would
/// disagree: the pane presents seq 500 and the host answers `resume_from_seq == 0`, meaning it
/// found nothing to reattach to and spawned a new shell. Keeping the seeded mark would swallow that
/// shell's whole first screen — its seq restarts at 1, every one of which reads as a stale
/// duplicate below 500 — so the marks must go back to zero and the new stream must be accepted.
#[test]
fn a_host_that_spawned_a_fresh_shell_resets_the_marks_and_says_so() {
    let harness = Harness::new(OpenPolicy::Accept(0));
    let log = Arc::new(Recorder::default());
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), seeded(500))
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");
    let host = harness.host(0);

    assert_eq!(presented(&host).1, 500, "the pane asked to resume from 500");
    assert_eq!(
        driver.highest_contiguous_seq(),
        0,
        "a fresh shell voids the marks the seed set"
    );

    host.send_output(1, b"$ ");
    log.wait_until("the wake", |_| log.wakes() > 0);
    assert_eq!(
        driver.highest_contiguous_seq(),
        1,
        "the fresh shell's first line must be delivered, not dropped as a duplicate"
    );
    assert_eq!(
        driver.resume_outcome(),
        ResumeOutcome::FreshShell,
        "a stream restarting at 1 under a presented 500 is a different shell"
    );
}

/// The other input to the same verdict: a pane with NOTHING to resume — no seed, seq zero — reads
/// as a fresh shell on its first output, without waiting to see where the stream starts. There is
/// no prior screen for the consumer to preserve, so the wipe is free and the verdict says so
/// immediately.
#[test]
fn a_pane_with_nothing_to_resume_reads_as_a_fresh_shell() {
    let live = common::connected([], OpenPolicy::Accept(0), quiet_config());
    let host = live.harness.host(0);
    host.wait_opens(1);

    host.send_output(1, b"$ ");
    live.log.wait_until("the wake", |_| live.log.wakes() > 0);
    assert_eq!(live.driver.resume_outcome(), ResumeOutcome::FreshShell);
}

/// A resolved verdict belongs to the connection that resolved it, and must not outlive it. If a
/// `ResumedSession` survived the drop, the NEXT session — which may well be a fresh shell — would
/// be gated by a stale answer and the consumer would skip a wipe it needed.
///
/// The link is CUT rather than torn down from this side, and the difference is the whole test. A
/// self-inflicted teardown bumps the epoch, which is exactly what makes the end that follows it
/// silent — no announcement, no campaign, and no re-arm either, because all three live behind the
/// same epoch check. Only a drop the driver did not cause reaches that code, so only a real cut can
/// assert what it does. (The Swift suite used a `forceDropForTesting()` seam that had this shape
/// and therefore could not have caught a regression here; the seam is gone.)
#[test]
fn a_dead_link_re_arms_the_verdict() {
    let harness = Harness::new(OpenPolicy::Accept(5));
    let log = Arc::new(Recorder::default());
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), seeded(5))
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");
    let host = harness.host(0);
    host.wait_opens(1);

    host.send_output(6, b"tail");
    log.wait_until("the wake", |_| log.wakes() > 0);
    assert_eq!(
        driver.resume_outcome(),
        ResumeOutcome::ResumedSession,
        "precondition: the verdict resolved on the live link"
    );

    host.cut_the_link();
    log.wait_until("the disconnect", |seen| {
        seen.iter().any(|one| matches!(*one, Seen::Disconnected(_)))
    });
    assert_eq!(
        driver.resume_outcome(),
        ResumeOutcome::Undetermined,
        "the dead link's verdict may not gate the next session's wipe"
    );
}

/// The distinction the cold path exists to preserve: a WARM redial — the link dropped and the
/// campaign put it back, with the process never having gone away — presents the seq the pane has
/// ACTUALLY rendered, not the zero it was seeded with. The pane still holds its screen, so asking
/// for the ring again would replay bytes it already has.
///
/// This is the one assertion no earlier test makes: `session.rs` and the tests above all read the
/// FIRST open, whose seq the seed decides. Here the second open is the subject, and only the live
/// marks can have written it.
#[test]
fn a_warm_redial_presents_the_live_seq_rather_than_the_seed() {
    let harness = Harness::scripted([], OpenPolicy::Accept(0));
    let log = Arc::new(Recorder::default());
    let config = DriverConfig {
        reconnect: Some(Backoff {
            initial_ns: 1_000_000,
            maximum_ns: 2_000_000,
            multiplier: 2.0,
        }),
        ..seeded(0)
    };
    let driver = PaneDriver::new(Arc::clone(&harness.registry), observer(&log), config)
        .expect("the supervisor thread starts");
    driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the host accepts the open");

    let first = harness.host(0);
    assert_eq!(presented(&first).1, 0, "the cold open asked for the ring");
    for seq in 1_i64..=3 {
        first.send_output(seq, b"x");
    }
    log.wait_until("three wakes", |_| log.wakes() >= 3);
    // DRAINED, not merely delivered: the contiguous mark is what the next open presents, and it
    // advances on delivery — but taking the batch is what a real consumer does, and a suite that
    // skipped it would be pinning the mark of a pane nothing had rendered.
    driver.take_output(|_| {});
    assert_eq!(driver.highest_contiguous_seq(), 3);

    first.cut_the_link();
    let second = harness.host(1);
    let (session_id, last_received_seq) = presented(&second);
    assert_eq!(session_id, SAVED, "a redial resumes the same pane");
    assert_eq!(
        last_received_seq, 3,
        "the redial presents what the pane has rendered, not the seed's zero"
    );
}
