//! The detach/rebind ladder of one pane session, and the two latches its exit task waits on.
//!
//! Everything a `MuxChannelSession` does when a client leaves and comes back is I/O — retire the
//! member's tasks, stop the supervised stream, open a new one at the resume cursor, rebuild the
//! drain. What is HERE is the part that is not I/O: whether this call is the one that acts, what it
//! is allowed to act on, and where the new subscription starts.
//!
//! Three pieces of state used to answer that, under three separate locks:
//!
//! * `started` / `isDetached` / `readLoop != nil` under `taskLock`, read by `detach` and
//!   `rebindRelay` as the guards that make both idempotent,
//! * `eofReached` + `streamOffset` under `eofLock`, written by the ingest path and polled by the
//!   exit task before it may yield `.exit`,
//! * `exitSent` under `exitSentLock`, written by the drain and polled by the exit task before it
//!   may fire `onExit`.
//!
//! The last two are pure latches with a monotone cursor beside them, and neither has any business
//! being a lock in hostd: the ingest path must never block on the lock the teardown ladder holds.
//! They live here, so hostd keeps ONE lock — the one that guards the Swift objects (the `Task`s,
//! the sub-channels, the stream) that cannot cross at all.
//!
//! **The cursor's sentinel is the reason `record_offset` is not a `max`.** A stream seeded
//! `fromNowOn` starts at `u64::MAX`, so a plain maximum would pin the cursor there forever and
//! every rebind would resume past the end of the ring. The first real chunk REPLACES the sentinel;
//! every chunk after that is a maximum, because a cursor that walked backwards would re-deliver
//! bytes this session already shipped.
//!
//! **What does not cross**: the `onExit` handler swap. `detach` rewires it to the detached-exit
//! path and `rebind` rewires it back, both while hostd's lock is held and before the exit task is
//! (re)started — a closure is not a fact, and the atomicity that matters is between the assignment
//! and the task launch, both of which are Swift's. This handle answers WHETHER that swap happens;
//! it never holds the thing being swapped.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// The `PaneOutputStream.fromNowOn` seed: a sentinel, not a position.
pub const FROM_NOW_ON: u64 = u64::MAX;

/// What a `detach` call must do, having already flipped the detached flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DetachVerdict {
    /// `false` for a second detach on an already-detached session — the failed-rebind re-park
    /// racing link-down's own detach. The caller still refreshes the exit handler and then stands
    /// down: the tasks are gone, the subscription is dropped, and re-running the teardown would
    /// only churn state another thread may be reading.
    pub first: bool,
    /// Whether a supervised stream was open and must be stopped. Always `false` when `first` is
    /// `false`.
    pub stop_stream: bool,
}

/// What a `rebind` call may do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RebindVerdict {
    /// The session is not detached, or the returning client's sub-channels are already finished.
    /// NOTHING was changed — the caller must refuse the channel rather than ack a pane whose relay
    /// is wired to somebody else, or flip `isDetached` onto channels every send throws on.
    Refuse,
    /// The relay may be rebound.
    Proceed {
        /// `Some(offset)` when a subscription must be re-opened at that cursor; `None` for a
        /// session that never started a relay, which has none to re-open and keeps its gate.
        resume_from: Option<u64>,
    },
}

/// The lifecycle state of one pane session.
///
/// Interior-mutable on purpose: the ingest path, the drain and the exit task all reach it
/// concurrently, and the whole point of moving the two latches here is that none of them has to
/// take the lock hostd's teardown ladder holds.
#[derive(Debug)]
pub struct Lifecycle {
    state: Mutex<State>,
    /// The two latches are OUTSIDE the mutex on purpose: each is written once, from the ingest path
    /// and the drain respectively, and polled at 2 ms granularity by the exit task. Neither has any
    /// reason to contend with the detach/rebind ladder, and a `Relaxed` set/get is exactly the
    /// "eventually visible, order enforced elsewhere" the poll loop already assumes.
    eof: AtomicBool,
    exit_sent: AtomicBool,
}

#[derive(Debug)]
struct State {
    started: bool,
    detached: bool,
    streaming: bool,
    offset: u64,
}

impl Default for Lifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl Lifecycle {
    /// A session that has not started its relay, is attached, and resumes from nowhere yet.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: Mutex::new(State {
                started: false,
                detached: false,
                streaming: false,
                offset: FROM_NOW_ON,
            }),
            eof: AtomicBool::new(false),
            exit_sent: AtomicBool::new(false),
        }
    }

    /// A poisoned lifecycle lock cannot be recovered from meaningfully — the state it guards is six
    /// plain scalars, and a panic while holding it means the caller died mid-ladder. Take the inner
    /// value either way rather than propagating a `Result` through every door.
    fn locked(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Claims the one-time relay start. `true` for the caller that wins; `false` for every later
    /// call, which must return without starting a second set of tasks.
    pub fn start(&self) -> bool {
        let mut state = self.locked();
        if state.started {
            return false;
        }
        state.started = true;
        true
    }

    /// Whether the relay has been started.
    pub fn is_started(&self) -> bool {
        self.locked().started
    }

    /// Records that a supervised subscription is open, so a later rebind knows to re-open one.
    pub fn stream_opened(&self) {
        self.locked().streaming = true;
    }

    /// Flips the detached flag and answers what this call must tear down.
    pub fn detach(&self) -> DetachVerdict {
        let mut state = self.locked();
        let first = !state.detached;
        state.detached = true;
        let stop_stream = first && state.streaming;
        if first {
            state.streaming = false;
        }
        drop(state);
        DetachVerdict { first, stop_stream }
    }

    /// Whether the session is parked in the detached store.
    pub fn is_detached(&self) -> bool {
        self.locked().detached
    }

    /// Decides a rebind against the returning client's sub-channels, and un-detaches when it
    /// proceeds. `data_finished`/`control_finished` are the near side's own `isFinished` reads: a
    /// connection that died while the reattach was still replaying finishes its sub-channels BEFORE
    /// the link-down handler runs, so a dead pair here means the session is about to be re-parked.
    pub fn rebind(&self, data_finished: bool, control_finished: bool) -> RebindVerdict {
        let mut state = self.locked();
        if !state.detached || data_finished || control_finished {
            return RebindVerdict::Refuse;
        }
        state.detached = false;
        let resume = state.started && !state.streaming;
        if resume {
            state.streaming = true;
        }
        RebindVerdict::Proceed {
            resume_from: resume.then_some(state.offset),
        }
    }

    /// Advances the resume cursor to where the just-ingested chunk ends. Monotone, except that the
    /// first real offset REPLACES the `fromNowOn` sentinel outright.
    pub fn record_offset(&self, end: u64) {
        let mut state = self.locked();
        state.offset = if state.offset == FROM_NOW_ON {
            end
        } else {
            state.offset.max(end)
        };
    }

    /// Where a rebind re-opens the subscription.
    pub fn offset(&self) -> u64 {
        self.locked().offset
    }

    /// Latches "superd drained this master to EOF", which gates the exit task's `.exit` yield so
    /// the final output tail is enqueued ahead of it.
    pub fn signal_eof(&self) {
        self.eof.store(true, Ordering::Relaxed);
    }

    /// Whether the EOF latch is set.
    pub fn is_eof(&self) -> bool {
        self.eof.load(Ordering::Relaxed)
    }

    /// Latches "the drain put `.exit` on the wire", which gates `onExit` so teardown cannot cancel
    /// the drain before the buffered exit code is flushed.
    pub fn signal_exit_sent(&self) {
        self.exit_sent.store(true, Ordering::Relaxed);
    }

    /// Whether the exit-sent latch is set.
    pub fn is_exit_sent(&self) -> bool {
        self.exit_sent.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::{DetachVerdict, FROM_NOW_ON, Lifecycle, RebindVerdict};

    #[test]
    fn start_is_claimed_once() {
        let life = Lifecycle::new();
        assert!(life.start());
        assert!(!life.start());
        assert!(life.is_started());
    }

    #[test]
    fn first_detach_stops_the_stream_and_the_second_does_nothing() {
        let life = Lifecycle::new();
        life.start();
        life.stream_opened();
        assert_eq!(life.detach(), DetachVerdict {
            first: true,
            stop_stream: true
        });
        assert_eq!(life.detach(), DetachVerdict {
            first: false,
            stop_stream: false
        });
        assert!(life.is_detached());
    }

    #[test]
    fn detaching_a_session_that_never_streamed_stops_nothing() {
        let life = Lifecycle::new();
        assert_eq!(life.detach(), DetachVerdict {
            first: true,
            stop_stream: false
        });
    }

    #[test]
    fn rebind_refuses_a_live_session() {
        let life = Lifecycle::new();
        life.start();
        assert_eq!(life.rebind(false, false), RebindVerdict::Refuse);
        assert!(!life.is_detached());
    }

    #[test]
    fn rebind_refuses_dead_sub_channels_and_stays_detached() {
        let life = Lifecycle::new();
        life.start();
        life.stream_opened();
        life.detach();
        assert_eq!(life.rebind(true, false), RebindVerdict::Refuse);
        assert_eq!(life.rebind(false, true), RebindVerdict::Refuse);
        assert!(
            life.is_detached(),
            "a refused rebind leaves the session claimable"
        );
    }

    #[test]
    fn rebind_resumes_a_started_session_at_its_cursor() {
        let life = Lifecycle::new();
        life.start();
        life.stream_opened();
        life.record_offset(4096);
        life.detach();
        assert_eq!(life.rebind(false, false), RebindVerdict::Proceed {
            resume_from: Some(4096)
        });
        assert!(!life.is_detached());
    }

    #[test]
    fn rebind_of_a_never_started_session_reopens_nothing() {
        let life = Lifecycle::new();
        life.detach();
        assert_eq!(life.rebind(false, false), RebindVerdict::Proceed {
            resume_from: None
        });
    }

    #[test]
    fn a_second_rebind_after_a_detach_resumes_again() {
        let life = Lifecycle::new();
        life.start();
        life.stream_opened();
        life.detach();
        assert_eq!(life.rebind(false, false), RebindVerdict::Proceed {
            resume_from: Some(FROM_NOW_ON)
        });
        life.record_offset(64);
        assert_eq!(life.detach(), DetachVerdict {
            first: true,
            stop_stream: true
        });
        assert_eq!(life.rebind(false, false), RebindVerdict::Proceed {
            resume_from: Some(64)
        });
    }

    #[test]
    fn the_first_real_offset_replaces_the_sentinel() {
        let life = Lifecycle::new();
        assert_eq!(life.offset(), FROM_NOW_ON);
        life.record_offset(16);
        assert_eq!(life.offset(), 16);
    }

    #[test]
    fn the_cursor_never_walks_backwards() {
        let life = Lifecycle::new();
        life.record_offset(4096);
        life.record_offset(64);
        assert_eq!(life.offset(), 4096);
    }

    #[test]
    fn both_latches_start_clear_and_set_once() {
        let life = Lifecycle::new();
        assert!(!life.is_eof());
        assert!(!life.is_exit_sent());
        life.signal_eof();
        life.signal_exit_sent();
        assert!(life.is_eof());
        assert!(life.is_exit_sent());
    }

    #[test]
    fn a_detach_does_not_clear_the_latches() {
        let life = Lifecycle::new();
        life.start();
        life.signal_eof();
        life.signal_exit_sent();
        life.detach();
        assert!(life.is_eof(), "the exit task keeps watching a detached child");
        assert!(life.is_exit_sent());
    }
}
