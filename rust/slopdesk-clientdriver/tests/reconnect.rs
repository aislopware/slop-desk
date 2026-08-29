//! What happens after the link dies: whether a campaign runs at all, how long it runs, what it
//! keeps across the gap, and what it may not credit on the channel that replaces the dead one.
//!
//! `docs/63-client-transport-in-rust.md` §4 G.5. This is `SlopDeskClientReconnectGiveUpTests`,
//! `SlopDeskClientReconnectClosedTests`, `SlopDeskClientReconnectInboxTests`,
//! `SlopDeskClientReconnectRaceTests` and `SlopDeskClientRTTTests` — five Swift suites, three of
//! which drove `ReconnectManager` as a free function past a client it never really disconnected.
//!
//! The RACE suite is the one that does not survive the port, and its absence is the point. It
//! looped 200× over three interleavings — a `close()`, a `pause()` and a second `connect()` landing
//! inside a suspended handshake — because `SlopDeskClient` was an actor and therefore reentrant at
//! every `await`. One supervisor thread has no such window: a command runs to COMPLETION before the
//! next is taken, so a second connect cannot interleave with the first at all. What is left of that
//! suite is the one race that is still real — a flag set from ANOTHER thread while the supervisor
//! is mid-dial — and it is two tests here rather than six hundred iterations.

#![expect(
    clippy::expect_used,
    reason = "a panic in a test is the failure report, not a fault"
)]

mod common;

use std::sync::Arc;
use std::thread;
use std::time::Duration;

use common::{GENEROUS, Harness, OpenPolicy, PORT, Recorder, Seen, endpoint_host, quiet_config};
use slopdesk_clientdriver::{DriverConfig, PaneDriver};
use slopdesk_clientsession::backoff::{Backoff, MAX_RECONNECT_ATTEMPTS};
use slopdesk_wire::WireMessage;

/// The recorder as the trait object the driver takes.
fn observer(log: &Arc<Recorder>) -> Arc<dyn slopdesk_clientdriver::Observer> {
    Arc::<Recorder>::clone(log)
}

/// A campaign whose whole ladder runs in milliseconds, so a suite pins the COUNT of attempts
/// without waiting out the shipped quarter-second-to-two-second ladder twenty times.
const fn eager_campaign() -> DriverConfig {
    DriverConfig {
        reconnect: Some(Backoff {
            initial_ns: 1_000_000,
            maximum_ns: 2_000_000,
            multiplier: 2.0,
        }),
        ..quiet_config()
    }
}

/// How long a NEGATIVE assertion waits before believing the thing really is not coming.
///
/// Only ever used where the campaign under test would have fired its first retry in ~1 ms, so this
/// is three orders of magnitude of slack rather than a hopeful pause.
const LONG_ENOUGH_TO_HAVE_HAPPENED: Duration = Duration::from_millis(400);

struct Live {
    harness: Harness,
    driver: PaneDriver,
    log: Arc<Recorder>,
}

/// A driver already connected to dial 0, with the plan that governs its redials.
fn connected(
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
        .expect("the host accepts the first open");
    harness.host(0).wait_opens(1);
    Live { harness, driver, log }
}

fn count(log: &Recorder, mut matches: impl FnMut(&Seen) -> bool) -> usize {
    log.seen().iter().filter(|one| matches(one)).count()
}

/// The ceiling, exactly: a campaign against a host that accepts the link but refuses every channel
/// makes EXACTLY `MAX_RECONNECT_ATTEMPTS` attempts and then gives up once.
///
/// This is the regression net for the cap unification — the per-pane campaign once ran to 30 while
/// the UI displayed 20. Both read the one constant now, and this counts it from the outside.
#[test]
fn a_doomed_campaign_stops_at_the_ceiling_and_gives_up_once() {
    let live = connected([OpenPolicy::Accept(0)], OpenPolicy::Refuse, eager_campaign());

    live.harness.host(0).cut_the_link();

    live.log.wait_until("the give-up", |seen| {
        seen.iter().any(|one| matches!(*one, Seen::GaveUp { .. }))
    });

    // Each attempt announces itself with a zero delay ("this one fires now") before it dials, and
    // announces the BACKOFF only if it failed and another is coming. Counting the zero-delay ones
    // counts attempts.
    let attempts = count(&live.log, |one| matches!(*one, Seen::Retry { delay_ms: 0, .. }));
    assert_eq!(
        attempts, MAX_RECONNECT_ATTEMPTS as usize,
        "exactly the constant's worth of attempts, no more and no fewer"
    );
    assert_eq!(
        count(&live.log, |one| matches!(*one, Seen::GaveUp { .. })),
        1,
        "the give-up fires once at the end of the campaign, not once per attempt"
    );
    assert!(
        live.log.seen().iter().any(|one| {
            matches!(
                *one,
                Seen::GaveUp { attempts } if attempts == MAX_RECONNECT_ATTEMPTS
            )
        }),
        "the give-up names the real campaign length"
    );
    assert!(!live.driver.is_connected());
}

/// The positive control for the two guards below: an open driver DOES campaign, and a host that
/// accepts the redial ends it on the first attempt.
#[test]
fn an_open_driver_reconnects_on_the_first_attempt() {
    let live = connected([], OpenPolicy::Accept(0), eager_campaign());

    live.harness.host(0).cut_the_link();

    live.log.wait_until("the resume", |seen| {
        seen.iter()
            .any(|one| matches!(*one, Seen::Log(ref text) if text.contains("resumed")))
    });
    assert!(live.driver.is_connected(), "the campaign adopted its transport");
    assert_eq!(
        count(&live.log, |one| matches!(*one, Seen::GaveUp { .. })),
        0,
        "a campaign that succeeded never gives up"
    );
}

/// A CLOSED driver runs no campaign. The two deliberate-shutdown paths are asymmetric, and a
/// supervisor gating only on "paused" would burn the whole ladder against a pane the owner shut,
/// then fire a spurious give-up at the end of it.
#[test]
fn a_closed_driver_never_campaigns() {
    let live = connected([], OpenPolicy::Accept(0), eager_campaign());

    live.driver.close();
    live.harness.host(0).cut_the_link();
    thread::sleep(LONG_ENOUGH_TO_HAVE_HAPPENED);

    assert!(live.driver.is_closed());
    assert_eq!(
        count(&live.log, |one| matches!(*one, Seen::Retry { .. })),
        0,
        "no attempt is made against a deliberately-closed pane"
    );
    assert_eq!(
        count(&live.log, |one| matches!(*one, Seen::GaveUp { .. })),
        0,
        "and so there is no give-up to report for one"
    );
}

/// A PAUSED driver runs no campaign either — the backgrounded-app case, where the drop is expected
/// and the reconnect is the near side's to ask for.
#[test]
fn a_paused_driver_never_campaigns() {
    let live = connected([], OpenPolicy::Accept(0), eager_campaign());

    live.driver.pause();
    live.harness.host(0).cut_the_link();
    thread::sleep(LONG_ENOUGH_TO_HAVE_HAPPENED);

    assert!(live.driver.is_paused());
    assert_eq!(
        count(&live.log, |one| matches!(*one, Seen::Retry { .. })),
        0,
        "a paused pane's drop is expected, not something to chase"
    );
}

/// The close that lands while the supervisor is mid-dial — the ONE interleaving of the Swift race
/// suite that one thread does not dissolve, because the flag is set from another thread.
///
/// A host that never answers the open holds the dial open for the whole handshake bound, which is
/// the window. What the driver may not do is adopt what it built: the near side asked to stop.
#[test]
fn a_close_landing_during_a_dial_discards_what_the_dial_built() {
    let harness = Harness::new(OpenPolicy::Ignore);
    let log = Arc::new(Recorder::default());
    let driver = Arc::new(
        PaneDriver::new(Arc::clone(&harness.registry), observer(&log), quiet_config())
            .expect("the supervisor thread starts"),
    );

    let dialling = Arc::clone(&driver);
    let dial = thread::spawn(move || {
        dialling
            .connect(endpoint_host(), PORT, Duration::from_millis(600))
            .err()
    });

    // The open is on the wire, so the supervisor is now parked on a verdict that never comes.
    harness.host(0).wait_opens(1);
    driver.close();

    let failure = dial.join().expect("the dialling thread");
    assert!(failure.is_some(), "a dial nobody will answer does not succeed");
    assert!(!driver.is_connected(), "nothing was adopted");
    assert!(driver.is_closed());
}

/// The reconnect RESET branch — the host answers `resume_from_seq = 0`, so the marks are wiped —
/// must NOT drop the inbox with them.
///
/// Those bytes arrived over the wire and were CLAIMED to the host at arrival (the open presented
/// the mark they advanced), so a reattaching host will never resend them: the inbox copy is the
/// only copy, and wiping it is a scrollback gap exactly at the reconnect boundary. The credit is
/// the other half — the new channel's peer never sent them, so crediting them there would be a
/// grant for bytes that were never spent.
#[test]
fn a_reset_keeps_the_undrained_tail_and_credits_the_new_channel_for_none_of_it() {
    let live = connected(
        [OpenPolicy::Accept(0), OpenPolicy::Accept(0)],
        OpenPolicy::Accept(0),
        quiet_config(),
    );
    let first = live.harness.host(0);

    // Three frames arrive and NOBODY drains them: the marks advance at arrival, so the host has
    // already been told these seqs are held.
    for (seq, byte) in [(1_i64, "a"), (2, "b"), (3, "c")] {
        first.send_output(seq, byte.as_bytes());
    }
    live.log.wait_until("three wakes", |_| live.log.wakes() >= 3);
    assert_eq!(
        live.driver.highest_contiguous_seq(),
        3,
        "precondition: the bytes were claimed to the host when they arrived"
    );

    // The link blips and the near side redials. The host answers `resume_from_seq = 0` — a fresh
    // shell — which resets the marks.
    first.cut_the_link();
    live.driver
        .connect(endpoint_host(), PORT, GENEROUS)
        .expect("the second host accepts the open");
    let second = live.harness.host(live.harness.connections() - 1);
    second.wait_opens(1);

    let fresh = WireMessage::Output {
        seq: 1,
        bytes: b"F".to_vec(),
    };
    second.send_output(1, b"F");
    live.log
        .wait_until("the new life's wake", |_| live.log.wakes() >= 4);

    let mut drained: Vec<u8> = Vec::new();
    live.driver.take_output(|chunk| drained.extend_from_slice(chunk));
    assert_eq!(
        drained,
        b"abcF".to_vec(),
        "the pre-reconnect tail survives the reset, in order, ahead of the new life's output"
    );

    assert!(
        second.credited() <= fresh.encode().len() as u64,
        "the carried-over bytes must not credit the channel whose peer never sent them: granted {} for a \
         channel that delivered {}",
        second.credited(),
        fresh.encode().len()
    );
}

/// The RTT fold, which is the latency badge's only datum: a `pong` echoing our own monotonic stamp
/// becomes an EWMA-smoothed reading and an event.
///
/// The driver's clock starts when the driver does, so the test cannot name an absolute stamp. It
/// does not need to: a stamp of ZERO makes each raw sample equal to the driver's whole elapsed
/// time, and the DIFFERENCE between two readings cancels that unknown out entirely — leaving
/// exactly the EWMA's α times the sleep between them.
#[test]
fn a_pong_folds_into_a_smoothed_round_trip() {
    let live = connected([], OpenPolicy::Accept(0), quiet_config());
    let host = live.harness.host(0);
    assert!(
        live.driver.smoothed_rtt_ms().is_none(),
        "no reading before the first pong"
    );

    // A stamp the driver's clock has not reached: the sample would be negative, so it is dropped
    // rather than folded.
    host.send(&WireMessage::Pong {
        timestamp_ms: 60_000_000,
    });
    thread::sleep(LONG_ENOUGH_TO_HAVE_HAPPENED);
    assert!(
        live.driver.smoothed_rtt_ms().is_none(),
        "a nonsensical echo from the future is dropped, never folded as a negative sample"
    );

    host.send(&WireMessage::Pong { timestamp_ms: 0 });
    live.log.wait_until("the first reading", |seen| {
        seen.iter().any(|one| matches!(*one, Seen::RoundTrip(_)))
    });
    let first = live
        .driver
        .smoothed_rtt_ms()
        .expect("the first sample seeds the average directly");

    // A second sample exactly `gap` older than the first. The raw jump is `gap`; the smoothed one
    // must be a QUARTER of it, which is what "the average absorbs an outlier" means numerically.
    let gap = Duration::from_millis(400);
    thread::sleep(gap);
    host.send(&WireMessage::Pong { timestamp_ms: 0 });
    live.log.wait_until("the second reading", |seen| {
        seen.iter()
            .filter(|one| matches!(**one, Seen::RoundTrip(_)))
            .count()
            >= 2
    });
    let second = live.driver.smoothed_rtt_ms().expect("a second reading");

    let moved = second - first;
    let quarter = gap.as_secs_f64() * 1000.0 * 0.25;
    assert!(
        second > first,
        "a slower sample raises the smoothed value: {first} -> {second}"
    );
    assert!(
        moved > quarter * 0.5 && moved < quarter * 1.6,
        "the average moves by about α of the jump, not to the jump: moved {moved}ms, expected about \
         {quarter}ms"
    );
}
