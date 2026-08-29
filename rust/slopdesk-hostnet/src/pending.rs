//! The map of half-paired links — the one place in this crate that owns a live file descriptor.
//!
//! A client dials twice and the two sockets become one connection only once both have shown the
//! same 16-byte id. Whichever lands first waits here.
//!
//! ## This module decides nothing
//!
//! `slopdesk_muxsession::pairing` decides. [`PendingLinks::admit`] asks it once per arrival and
//! obeys the answer; [`PendingLinks::reap`] asks `pending_expired` and obeys that. The reason is
//! written out in that module's header and it is worth repeating in the module that holds the fds:
//! the two questions — "did this arrival complete a pair" and "is this arrival displacing an
//! already-parked half of the SAME side" — differ only in which bool is set, and the arm that gets
//! the second one wrong does not return a wrong value, it leaks a socket. Once per arrival, from
//! one function, with the whole state space pinned by a test table.
//!
//! ## Everything this map drops, it closes
//!
//! There is no `Drop` doing it implicitly. A displaced half is closed at the moment it is
//! displaced, an expired entry at the moment it expires, and every entry at [`PendingLinks::stop`].
//! The one thing that is NOT closed here is a completed pair: both its links leave in a
//! [`PairedConnection`], and closing them is then the connection's business.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use slopdesk_muxnet::connection::PairedConnection;
use slopdesk_muxnet::link::ByteLink;
use slopdesk_muxnet::preamble::{ConnectionId, Lane, Preamble};
use slopdesk_muxsession::pairing::{decide, pending_expired};

/// One id's half-pair, and when the first of it arrived.
#[derive(Debug)]
struct Half {
    control: Option<Box<dyn ByteLink>>,
    data: Option<Box<dyn ByteLink>>,
    /// When the FIRST of the pair arrived — what [`PendingLinks::reap`] measures against.
    ///
    /// NOT restamped on a same-side re-park. A peer re-sending one side in a loop would otherwise
    /// push its own deadline out ahead of itself forever, so the leak would grow while the thing
    /// that bounds it kept being deferred.
    created_at: Instant,
}

impl Half {
    fn close_all(self) {
        if let Some(control) = self.control {
            control.close();
        }
        if let Some(data) = self.data {
            data.close();
        }
    }
}

/// Half-paired links, keyed by the id their preambles carried.
#[derive(Debug)]
pub struct PendingLinks {
    entries: HashMap<ConnectionId, Half>,
    timeout: Duration,
    stopped: bool,
}

impl PendingLinks {
    /// A map that expires a half-pair after `timeout`.
    ///
    /// The timeout is injected rather than constant so a test drives expiry with a tiny value
    /// instead of a wall-clock sleep. Production is [`crate::listener::PENDING_PARTNER_TIMEOUT`].
    #[must_use]
    pub fn new(timeout: Duration) -> Self {
        Self {
            entries: HashMap::new(),
            timeout,
            stopped: false,
        }
    }

    /// Takes an arriving half-link and returns the completed pair, if this arrival completed one.
    ///
    /// After [`Self::stop`] nothing is parked and nothing is paired: the arriving link is closed,
    /// and so is any half already waiting under its id. Accepting after stop is how a fully-started
    /// connection ends up owned by nobody — the relay owner has already drained, so it never sees
    /// it and never closes it.
    pub fn admit(
        &mut self,
        preamble: Preamble,
        link: Box<dyn ByteLink>,
        now: Instant,
    ) -> Option<PairedConnection> {
        if self.stopped {
            link.close();
            if let Some(existing) = self.entries.remove(&preamble.connection) {
                existing.close_all();
            }
            return None;
        }

        let is_control = matches!(preamble.lane, Lane::Control);
        let existing = self.entries.get(&preamble.connection);
        // ONE reading of the arrival, used by both arms below.
        let decision = decide(
            existing.is_some_and(|half| half.control.is_some()),
            existing.is_some_and(|half| half.data.is_some()),
            is_control,
        );

        if decision.paired {
            // The opposite side is parked; it is going into the connection, not into the bin.
            let mut parked = self.entries.remove(&preamble.connection)?;
            let (control, data) = if is_control {
                (link, parked.data.take()?)
            } else {
                (parked.control.take()?, link)
            };
            return Some(PairedConnection {
                connection: preamble.connection,
                control,
                data,
            });
        }

        // `or_insert_with` keeps an EXISTING entry's `created_at` untouched, which is the whole
        // point: only a first arrival stamps the clock the reaper measures against.
        let entry = self.entries.entry(preamble.connection).or_insert_with(|| {
            Half {
                control: None,
                data: None,
                created_at: now,
            }
        });
        let slot = if is_control {
            &mut entry.control
        } else {
            &mut entry.data
        };
        // `replace` rather than assign: the displaced half is a live fd and the map is the only
        // thing that was holding it. `decision.closes_displaced_same_side` says one is here.
        if let Some(displaced) = slot.replace(link) {
            debug_assert!(
                decision.closes_displaced_same_side,
                "displaced a half the rule did not name"
            );
            displaced.close();
        }
        None
    }

    /// Closes and drops every half-pair that has waited longer than the timeout. Returns how many.
    ///
    /// Bounds the hostile case the Swift original named: a peer opening CONTROL sockets under fresh
    /// ids and never sending their partners. Each one is an fd; without this each one is forever.
    pub fn reap(&mut self, now: Instant) -> usize {
        let timeout_nanos = duration_nanos(self.timeout);
        let expired: Vec<ConnectionId> = self
            .entries
            .iter()
            .filter(|(_, half)| {
                pending_expired(
                    duration_nanos(now.saturating_duration_since(half.created_at)),
                    timeout_nanos,
                )
            })
            .map(|(id, _)| *id)
            .collect();
        for id in &expired {
            if let Some(half) = self.entries.remove(id) {
                half.close_all();
            }
        }
        expired.len()
    }

    /// Refuses every future arrival and closes everything currently parked.
    ///
    /// One-way. A `PendingLinks` is single-use for the reason the Swift `HostTransport` was: the
    /// stream its pairs are published on is finished by the same stop, so a restarted map would
    /// accept pairs into a consumer that no longer exists — accept-then-leak instead of refuse.
    pub fn stop(&mut self) {
        self.stopped = true;
        for (_, half) in self.entries.drain() {
            half.close_all();
        }
    }

    /// How many ids are currently half-paired.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether nothing is waiting.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// A span in whole nanoseconds, saturating — the unit `pending_expired` compares in.
///
/// Saturating rather than wrapping: a `Duration` past `u64::MAX` nanoseconds is 584 years, and
/// every answer at that end of the range is "expired".
fn duration_nanos(span: Duration) -> u64 {
    u64::try_from(span.as_nanos()).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use std::io;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    use slopdesk_muxnet::link::ByteLink;
    use slopdesk_muxnet::preamble::{ConnectionId, Lane, Preamble};

    use super::{PendingLinks, duration_nanos};

    /// A link that records only whether it was closed — which is the whole property this module is
    /// responsible for. No socket: the Swift original could not be tested without one.
    #[derive(Debug, Clone, Default)]
    struct CountingLink {
        closes: Arc<AtomicUsize>,
    }

    impl CountingLink {
        fn closed(&self) -> usize {
            self.closes.load(Ordering::SeqCst)
        }
    }

    impl ByteLink for CountingLink {
        fn send(&self, _bytes: &[u8]) -> io::Result<()> {
            Ok(())
        }

        fn recv(&self, _buf: &mut [u8]) -> io::Result<usize> {
            Ok(0)
        }

        fn close(&self) {
            self.closes.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn id(byte: u8) -> ConnectionId {
        ConnectionId::from_bytes([byte; 16])
    }

    fn preamble(lane: Lane, byte: u8) -> Preamble {
        Preamble {
            lane,
            connection: id(byte),
        }
    }

    #[test]
    fn the_second_side_completes_the_pair_and_neither_half_is_closed() {
        let mut pending = PendingLinks::new(Duration::from_secs(15));
        let now = Instant::now();
        let control = CountingLink::default();
        let data = CountingLink::default();

        assert!(
            pending
                .admit(preamble(Lane::Control, 1), Box::new(control.clone()), now)
                .is_none()
        );
        assert_eq!(pending.len(), 1);

        let paired = pending
            .admit(preamble(Lane::Data, 1), Box::new(data.clone()), now)
            .expect("the second side completes the pair");
        assert_eq!(paired.connection, id(1));
        assert!(pending.is_empty(), "a completed pair leaves the map");
        assert_eq!(
            control.closed(),
            0,
            "a paired half is the connection's, not the bin's"
        );
        assert_eq!(data.closed(), 0);
    }

    /// The client may dial data-first; that is legal and pairs the same way.
    #[test]
    fn data_first_pairs_too() {
        let mut pending = PendingLinks::new(Duration::from_secs(15));
        let now = Instant::now();
        assert!(
            pending
                .admit(preamble(Lane::Data, 2), Box::new(CountingLink::default()), now)
                .is_none()
        );
        assert!(
            pending
                .admit(preamble(Lane::Control, 2), Box::new(CountingLink::default()), now)
                .is_some()
        );
    }

    /// The fd-leak case the pairing rule exists for.
    #[test]
    fn a_same_side_repark_closes_the_half_it_displaces() {
        let mut pending = PendingLinks::new(Duration::from_secs(15));
        let now = Instant::now();
        let first = CountingLink::default();
        let second = CountingLink::default();

        assert!(
            pending
                .admit(preamble(Lane::Control, 3), Box::new(first.clone()), now)
                .is_none()
        );
        assert!(
            pending
                .admit(preamble(Lane::Control, 3), Box::new(second.clone()), now)
                .is_none()
        );

        assert_eq!(
            first.closed(),
            1,
            "the displaced half is closed at the moment it is displaced"
        );
        assert_eq!(second.closed(), 0);
        assert_eq!(pending.len(), 1, "one id, still one entry");
    }

    /// A peer re-sending one side in a loop must not push its own deadline out ahead of itself.
    #[test]
    fn a_repark_does_not_restamp_the_expiry_deadline() {
        let mut pending = PendingLinks::new(Duration::from_secs(10));
        let start = Instant::now();
        pending.admit(
            preamble(Lane::Control, 4),
            Box::new(CountingLink::default()),
            start,
        );

        let late = start
            .checked_add(Duration::from_secs(9))
            .expect("instant arithmetic");
        pending.admit(
            preamble(Lane::Control, 4),
            Box::new(CountingLink::default()),
            late,
        );

        let past_original = start
            .checked_add(Duration::from_secs(11))
            .expect("instant arithmetic");
        assert_eq!(
            pending.reap(past_original),
            1,
            "measured from the FIRST arrival, not the last"
        );
    }

    #[test]
    fn the_reaper_closes_what_it_expires_and_leaves_what_is_young() {
        let mut pending = PendingLinks::new(Duration::from_secs(15));
        let start = Instant::now();
        let stale = CountingLink::default();
        pending.admit(preamble(Lane::Control, 5), Box::new(stale.clone()), start);

        let on_the_deadline = start
            .checked_add(Duration::from_secs(15))
            .expect("instant arithmetic");
        assert_eq!(
            pending.reap(on_the_deadline),
            0,
            "STRICTLY greater — on the deadline it stays"
        );
        assert_eq!(stale.closed(), 0);

        let past = start
            .checked_add(Duration::from_secs(16))
            .expect("instant arithmetic");
        assert_eq!(pending.reap(past), 1);
        assert_eq!(stale.closed(), 1);
        assert!(pending.is_empty());
    }

    #[test]
    fn after_stop_an_arrival_is_closed_and_takes_its_waiting_partner_with_it() {
        let mut pending = PendingLinks::new(Duration::from_secs(15));
        let now = Instant::now();
        let parked = CountingLink::default();
        pending.admit(preamble(Lane::Control, 6), Box::new(parked.clone()), now);

        pending.stop();
        assert_eq!(parked.closed(), 1, "stop closes what it drains");

        let late = CountingLink::default();
        assert!(
            pending
                .admit(preamble(Lane::Data, 6), Box::new(late.clone()), now)
                .is_none()
        );
        assert_eq!(
            late.closed(),
            1,
            "an arrival after stop is refused, not paired into a dead consumer"
        );
        assert!(pending.is_empty());
    }

    #[test]
    fn a_span_past_the_representable_range_saturates_rather_than_wrapping() {
        assert_eq!(duration_nanos(Duration::from_nanos(1)), 1);
        assert_eq!(duration_nanos(Duration::MAX), u64::MAX);
    }
}
