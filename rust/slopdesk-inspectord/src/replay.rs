//! The bounded replay window and the live fan-out.
//!
//! One engine thread produces events; any number of connections want the FULL history from the
//! beginning and then the live tail. [`ReplayLog`] is that seam: [`ReplayLog::append`] records an
//! event and pushes it to every attached subscriber, and [`ReplayLog::subscribe`] hands back a
//! snapshot-plus-live queue.
//!
//! ## Sequence numbering
//! The window is append-only, so an index into it IS a sequence number: retained event `i` is
//! `base_seq + i`. That is what the wire's `fromSeq` means — `0` for a full replay, `N` to resume
//! after a reconnect, skipping the prefix already rendered. Ignoring `fromSeq` would hand a
//! reconnecting client a blank inspector after every drop.
//!
//! ## Snapshot-then-attach is ATOMIC
//! `subscribe` takes the snapshot AND attaches the live queue under ONE lock acquisition. Nothing
//! can append in between, so no event slips through the gap: an event appended before the call is
//! in the snapshot, one appended after lands on the queue. Getting this wrong is invisible in
//! testing and loses exactly one event under load.
//!
//! ## Both directions are bounded
//! The shared window is capped (a diagnostic inspector on a week-long session must not be a slow
//! OOM), and so is each subscriber's queue — a stalled peer (a backgrounded phone, a dead TCP whose
//! FIN never arrived) must not make every append pile up in a buffer nobody drains. A subscriber
//! that stalls loses its OLDEST live events and resubscribes on the gap; the replay SNAPSHOT is
//! never dropped, because the bound is sized to hold it.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::event::InspectorEvent;

/// Retained events before the oldest are dropped. Generous for a diagnostic session.
pub const MAX_RETAINED: usize = 50_000;

/// How far the window is cut back on overflow, so the drop is one batch rather than one per append.
pub const RETAIN_TARGET: usize = 37_500;

/// Live-tail headroom beyond a subscriber's replay snapshot. A healthy consumer stays far below it.
pub const LIVE_SUBSCRIBER_SLACK: usize = 1024;

/// What a subscriber's blocking pull returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pull {
    /// An event to send.
    Event(Box<InspectorEvent>),
    /// Nothing arrived within the timeout — the caller's cue to send a keep-alive.
    Idle,
    /// The subscription is over: the daemon is shutting down, or the connection was detached.
    Finished,
}

/// One subscriber's bounded queue.
#[derive(Debug)]
pub struct Subscriber {
    queue: Mutex<SubscriberQueue>,
    ready: Condvar,
}

#[derive(Debug)]
struct SubscriberQueue {
    events: VecDeque<InspectorEvent>,
    /// Maximum queued events; past it the oldest droppable one goes.
    bound: usize,
    /// How many leading entries are still UNCONSUMED REPLAY. They are exempt from the drop: a
    /// subscriber that stalls may lose live tail it has not read, but it must never be handed a
    /// history with a hole in the middle and no marker saying so. Falls to zero as the replay is
    /// pulled, after which every entry is droppable.
    protected: usize,
    finished: bool,
}

impl Subscriber {
    /// Blocks for up to `timeout` waiting for the next event.
    ///
    /// A poisoned lock is treated as [`Pull::Finished`] rather than propagated: the only way to
    /// poison it is a panic while holding it, and the honest response is to end THIS subscription,
    /// not to take the daemon down with it.
    #[must_use]
    pub fn pull(&self, timeout: Duration) -> Pull {
        let Ok(mut queue) = self.queue.lock() else {
            return Pull::Finished;
        };
        loop {
            if let Some(event) = queue.events.pop_front() {
                queue.protected = queue.protected.saturating_sub(1);
                return Pull::Event(Box::new(event));
            }
            if queue.finished {
                return Pull::Finished;
            }
            let Ok((next, wait)) = self.ready.wait_timeout(queue, timeout) else {
                return Pull::Finished;
            };
            queue = next;
            if wait.timed_out() && queue.events.is_empty() && !queue.finished {
                return Pull::Idle;
            }
        }
    }

    /// Ends this subscription and wakes anything blocked in [`Subscriber::pull`].
    pub fn finish(&self) {
        if let Ok(mut queue) = self.queue.lock() {
            queue.finished = true;
        }
        self.ready.notify_all();
    }

    /// Queues one live event, dropping the oldest DROPPABLE one if the bound is reached.
    ///
    /// "Droppable" excludes the unconsumed replay prefix, so the bound bites on the live tail only.
    fn push(&self, event: InspectorEvent) {
        if let Ok(mut queue) = self.queue.lock() {
            if queue.events.len() >= queue.bound {
                let oldest_droppable = queue.protected;
                drop(queue.events.remove(oldest_droppable));
            }
            queue.events.push_back(event);
        }
        self.ready.notify_all();
    }

    /// Queued but unconsumed events — diagnostics and tests.
    #[must_use]
    pub fn queued(&self) -> usize {
        self.queue.lock().map_or(0, |queue| queue.events.len())
    }
}

/// A subscription handle: the queue plus the id needed to detach it.
#[derive(Debug, Clone)]
pub struct Subscription {
    /// The queue to pull from.
    pub subscriber: Arc<Subscriber>,
    /// The id [`ReplayLog::unsubscribe`] takes.
    pub id: u64,
}

/// The shared window and its subscribers.
#[derive(Debug)]
pub struct ReplayLog {
    inner: Mutex<Inner>,
}

#[derive(Debug)]
struct Inner {
    history: VecDeque<InspectorEvent>,
    /// The absolute seq of `history[0]`, advanced when the oldest are dropped so a subscriber's
    /// `fromSeq` keeps meaning the same event.
    base_seq: i64,
    max_retained: usize,
    retain_target: usize,
    subscribers: HashMap<u64, Arc<Subscriber>>,
    next_id: u64,
    finished: bool,
}

impl Default for ReplayLog {
    fn default() -> Self {
        Self::new(MAX_RETAINED, RETAIN_TARGET)
    }
}

impl ReplayLog {
    /// A log retaining `max_retained` events, cut back to `retain_target` on overflow.
    ///
    /// A target at or above the cap would mean "drop nothing, forever", so it is clamped below —
    /// this is a config path, and a silent unbounded window is worse than a clamped one.
    #[must_use]
    pub fn new(max_retained: usize, retain_target: usize) -> Self {
        let max_retained = max_retained.max(1);
        Self {
            inner: Mutex::new(Inner {
                history: VecDeque::new(),
                base_seq: 0,
                max_retained,
                retain_target: retain_target.min(max_retained - 1),
                subscribers: HashMap::new(),
                next_id: 0,
                finished: false,
            }),
        }
    }

    /// Appends one event and pushes it to every live subscriber, under one lock.
    pub fn append(&self, event: &InspectorEvent) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        inner.history.push_back(event.clone());
        if inner.history.len() > inner.max_retained {
            let drop = inner.history.len() - inner.retain_target;
            inner.history.drain(..drop);
            inner.base_seq = inner
                .base_seq
                .saturating_add(i64::try_from(drop).unwrap_or(i64::MAX));
        }
        for subscriber in inner.subscribers.values() {
            subscriber.push(event.clone());
        }
    }

    /// Marks the upstream finished and closes every live subscriber. Idempotent.
    pub fn finish(&self) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        if inner.finished {
            return;
        }
        inner.finished = true;
        for subscriber in inner.subscribers.values() {
            subscriber.finish();
        }
        inner.subscribers.clear();
    }

    /// The total number of events ever appended — `base_seq + retained`, i.e. the NEXT seq to be
    /// assigned. Stable across retention drops, so a client may resume from it for the live tail
    /// alone.
    #[must_use]
    pub fn history_count(&self) -> i64 {
        self.inner.lock().map_or(0, |inner| {
            inner
                .base_seq
                .saturating_add(i64::try_from(inner.history.len()).unwrap_or(i64::MAX))
        })
    }

    /// Events currently RETAINED — distinct from [`ReplayLog::history_count`].
    #[must_use]
    pub fn retained_count(&self) -> usize {
        self.inner.lock().map_or(0, |inner| inner.history.len())
    }

    /// Attached live subscribers.
    #[must_use]
    pub fn subscriber_count(&self) -> usize {
        self.inner.lock().map_or(0, |inner| inner.subscribers.len())
    }

    /// Subscribes from `from_seq`: the retained events at or after it, then the live tail.
    ///
    /// - `from_seq` BELOW the window (those events were dropped) clamps to the oldest retained one
    ///   and the snapshot is prefixed with [`InspectorEvent::HistoryTruncated`], so the client
    ///   renders "N earlier steps dropped" instead of believing it received a complete history.
    /// - `from_seq` PAST the end ("I already have everything") yields an empty snapshot, then live.
    ///
    /// `from_seq` is peer-controlled and unauthenticated, so the index arithmetic is saturating
    /// throughout: `i64::MIN` here must mean "everything retained", not a panicking overflow that
    /// takes the daemon down on one crafted frame.
    #[must_use]
    pub fn subscribe(&self, from_seq: i64) -> Subscription {
        let Ok(mut inner) = self.inner.lock() else {
            // A poisoned log can still answer honestly: an empty, already-finished subscription.
            return Subscription {
                subscriber: Arc::new(Subscriber {
                    queue: Mutex::new(SubscriberQueue {
                        events: VecDeque::new(),
                        bound: 1,
                        protected: 0,
                        finished: true,
                    }),
                    ready: Condvar::new(),
                }),
                id: 0,
            };
        };

        let relative = from_seq.saturating_sub(inner.base_seq);
        let retained = i64::try_from(inner.history.len()).unwrap_or(i64::MAX);
        let lower = relative.clamp(0, retained);
        let start = usize::try_from(lower).unwrap_or(0);

        let mut snapshot: VecDeque<InspectorEvent> = inner.history.iter().skip(start).cloned().collect();

        if relative < 0 {
            // How many absolute seqs are missing ahead of the oldest retained event.
            let dropped = inner.base_seq.saturating_sub(from_seq.max(0));
            if dropped > 0 {
                snapshot.push_front(InspectorEvent::HistoryTruncated {
                    dropped_count: dropped,
                });
            }
        }

        // The bound holds the whole snapshot plus headroom, so only a subscriber that stops
        // consuming can lose anything, and never its replay.
        let protected = snapshot.len();
        let bound = protected.saturating_add(LIVE_SUBSCRIBER_SLACK);
        let subscriber = Arc::new(Subscriber {
            queue: Mutex::new(SubscriberQueue {
                events: snapshot,
                bound,
                protected,
                finished: inner.finished,
            }),
            ready: Condvar::new(),
        });

        if inner.finished {
            // No live tail will ever arrive: deliver the snapshot and let the pull finish.
            return Subscription { subscriber, id: 0 };
        }

        let id = inner.next_id.wrapping_add(1);
        inner.next_id = id;
        inner.subscribers.insert(id, Arc::clone(&subscriber));
        Subscription { subscriber, id }
    }

    /// Detaches a subscriber and ends its queue. No-op if it is already gone.
    pub fn unsubscribe(&self, id: u64) {
        let Ok(mut inner) = self.inner.lock() else {
            return;
        };
        if let Some(subscriber) = inner.subscribers.remove(&id) {
            subscriber.finish();
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    use super::{LIVE_SUBSCRIBER_SLACK, Pull, ReplayLog};
    use crate::event::InspectorEvent;

    const INSTANT: Duration = Duration::from_millis(50);

    fn event(index: i64) -> InspectorEvent {
        InspectorEvent::HistoryTruncated { dropped_count: index }
    }

    /// Drains everything immediately available, stopping at the first idle or finish.
    fn drain(subscription: &super::Subscription) -> Vec<InspectorEvent> {
        let mut out = Vec::new();
        loop {
            match subscription.subscriber.pull(INSTANT) {
                Pull::Event(inner) => out.push(*inner),
                Pull::Idle | Pull::Finished => return out,
            }
        }
    }

    #[test]
    fn a_full_replay_delivers_the_history_in_order_then_the_live_tail() {
        let log = ReplayLog::default();
        log.append(&event(0));
        log.append(&event(1));

        let subscription = log.subscribe(0);
        log.append(&event(2));

        assert_eq!(drain(&subscription), vec![event(0), event(1), event(2)]);
    }

    #[test]
    fn a_resume_skips_the_prefix_the_client_already_rendered() {
        let log = ReplayLog::default();
        for index in 0..5 {
            log.append(&event(index));
        }
        let subscription = log.subscribe(3);
        assert_eq!(drain(&subscription), vec![event(3), event(4)]);
    }

    #[test]
    fn a_from_seq_past_the_end_replays_nothing_and_then_goes_live() {
        let log = ReplayLog::default();
        log.append(&event(0));
        let subscription = log.subscribe(99);
        assert!(drain(&subscription).is_empty());
        log.append(&event(1));
        assert_eq!(drain(&subscription), vec![event(1)]);
    }

    #[test]
    fn the_window_is_bounded_and_the_absolute_sequence_survives_the_drop() {
        let log = ReplayLog::new(10, 4);
        for index in 0..12 {
            log.append(&event(index));
        }
        assert_eq!(log.history_count(), 12);
        assert!(log.retained_count() <= 10);
    }

    #[test]
    fn a_replay_below_the_window_is_prefixed_with_a_truncation_marker() {
        let log = ReplayLog::new(10, 4);
        for index in 0..12 {
            log.append(&event(index));
        }
        let subscription = log.subscribe(0);
        let replayed = drain(&subscription);
        let [InspectorEvent::HistoryTruncated { dropped_count }, ..] = replayed.as_slice() else {
            panic!("expected a truncation marker first, got {replayed:?}");
        };
        assert!(*dropped_count > 0);
        assert_eq!(
            replayed.len(),
            log.retained_count() + 1,
            "the marker plus everything still retained"
        );
    }

    #[test]
    fn a_crafted_from_seq_cannot_take_the_daemon_down() {
        let log = ReplayLog::new(4, 2);
        for index in 0..8 {
            log.append(&event(index));
        }
        // i64::MIN would underflow a naive `from_seq - base_seq`; it must simply mean
        // "everything retained".
        let subscription = log.subscribe(i64::MIN);
        assert!(!drain(&subscription).is_empty());
        let subscription = log.subscribe(i64::MAX);
        assert!(drain(&subscription).is_empty());
    }

    #[test]
    fn a_stalled_subscriber_loses_its_oldest_live_events_never_its_replay() {
        let log = ReplayLog::default();
        for index in 0..3 {
            log.append(&event(index));
        }
        let subscription = log.subscribe(0);
        // Never pull; flood past the bound.
        let flood = i64::try_from(LIVE_SUBSCRIBER_SLACK).expect("the slack fits") + 500;
        for index in 3..(3 + flood) {
            log.append(&event(index));
        }
        let got = drain(&subscription);
        assert_eq!(
            got.len(),
            3 + LIVE_SUBSCRIBER_SLACK,
            "the queue is bounded at snapshot + slack"
        );
        assert_eq!(
            &got[..3],
            &[event(0), event(1), event(2)],
            "the replay snapshot itself is never dropped"
        );
    }

    #[test]
    fn an_idle_subscription_reports_idle_so_the_caller_can_keep_alive() {
        let log = ReplayLog::default();
        let subscription = log.subscribe(0);
        assert_eq!(subscription.subscriber.pull(INSTANT), Pull::Idle);
    }

    #[test]
    fn finishing_the_log_closes_every_subscriber() {
        let log = ReplayLog::default();
        let subscription = log.subscribe(0);
        log.finish();
        assert_eq!(subscription.subscriber.pull(INSTANT), Pull::Finished);
        assert_eq!(log.subscriber_count(), 0);
    }

    #[test]
    fn subscribing_after_the_end_still_gets_the_history_then_finishes() {
        let log = ReplayLog::default();
        log.append(&event(0));
        log.finish();
        let subscription = log.subscribe(0);
        assert_eq!(
            subscription.subscriber.pull(INSTANT),
            Pull::Event(Box::new(event(0)))
        );
        assert_eq!(subscription.subscriber.pull(INSTANT), Pull::Finished);
    }

    #[test]
    fn unsubscribing_detaches_and_wakes_the_puller() {
        let log = ReplayLog::default();
        let subscription = log.subscribe(0);
        assert_eq!(log.subscriber_count(), 1);
        log.unsubscribe(subscription.id);
        assert_eq!(log.subscriber_count(), 0);
        assert_eq!(subscription.subscriber.pull(INSTANT), Pull::Finished);
    }

    #[test]
    fn a_blocked_puller_wakes_the_moment_an_event_lands() {
        let log = Arc::new(ReplayLog::default());
        let subscription = log.subscribe(0);
        let writer = Arc::clone(&log);
        let handle = thread::spawn(move || {
            thread::sleep(Duration::from_millis(20));
            writer.append(&event(42));
        });
        // A generous timeout: the assertion is that the event arrives, not that it is slow.
        assert_eq!(
            subscription.subscriber.pull(Duration::from_secs(5)),
            Pull::Event(Box::new(event(42)))
        );
        handle.join().expect("the writer thread finishes");
    }

    #[test]
    fn concurrent_subscribers_each_receive_every_event() {
        let log = Arc::new(ReplayLog::default());
        let subscriptions: Vec<_> = (0..4).map(|_| log.subscribe(0)).collect();
        for index in 0..50 {
            log.append(&event(index));
        }
        for subscription in &subscriptions {
            assert_eq!(drain(subscription).len(), 50);
        }
    }
}
