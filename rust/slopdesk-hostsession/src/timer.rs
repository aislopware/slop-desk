//! The pane's three cancel-replace timers, on ONE thread.
//!
//! The resize ladder arms three delayed actions and every one of them is cancel-replace: the 16 ms
//! resize debounce, the 750 ms contributor settle and the 90 ms redraw nudge. In Swift each was a
//! `Task` that a re-arm `cancel()`ed and replaced, which costs an allocation and nothing else. A
//! `std::thread` is not that cheap, and the arming rate is not small — a window drag emits an offer
//! per frame, so ~60 arms a second per pane for as long as the drag lasts. Spawning a thread per
//! arm would spend more time in `pthread_create` than in the ioctl the timer exists to schedule.
//!
//! So the shape here is the opposite one: a single thread per pane, parked on a condvar, holding a
//! table of at most three pending actions. Re-arming OVERWRITES a slot's deadline in place and
//! notifies — no thread is created, none is destroyed, and the cancel is the overwrite. The thread
//! is spawned LAZILY on the first arm, so a pane whose size never changes costs nothing at all.
//!
//! ## The generation guard is not in here
//!
//! [`slopdesk_muxsession::resize_fold::ResizeFold`] already owns the generations, and a timer that
//! kept its own would be a second answer to "is this action still the newest one". A body already
//! past its sleep quotes the generation it was armed with and the FOLD decides whether it still
//! speaks for the current state. That is why [`Timers::arm`] takes a plain `FnOnce` and promises
//! only "not before `delay`, and only if nothing overwrote this slot".
//!
//! ## What is guaranteed, and what is not
//!
//! - **Trailing edge.** A re-arm always moves the deadline forward, so the LAST arm of a burst is
//!   the one that fires. That is the property the debounce exists for.
//! - **At most one live body per slot.** Overwriting drops the previous closure without running it.
//! - **The body runs OUTSIDE the table's lock**, so it may arm another slot — the settle's body
//!   applies a grid, which schedules the nudge, which is a third slot.
//! - **No promise of promptness under load.** The thread wakes at the earliest deadline in the
//!   table; a body that blocks delays the others. Every body here is an ioctl or a signal.

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Which delayed action a slot holds. One slot per kind, because each is cancel-replace against
/// ITSELF and against nothing else: a redraw nudge must not cancel a pending contributor settle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Timer {
    /// The short latest-wins window before a resolved grid reaches `TIOCSWINSZ`.
    Resize,
    /// The longer window a CONTRIBUTOR-SET change arms, so a burst of joins folds once.
    Settle,
    /// The delayed `SIGWINCH` that makes the shell repaint after the client grid has settled.
    Nudge,
}

/// One pending action: when, and what.
struct Pending {
    at: Instant,
    body: Box<dyn FnOnce() + Send>,
}

impl core::fmt::Debug for Pending {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Pending")
            .field("at", &self.at)
            .finish_non_exhaustive()
    }
}

/// The table, and whether the thread should still be running.
#[derive(Debug, Default)]
struct Table {
    slots: BTreeMap<Timer, Pending>,
    /// How many times each kind has been armed, ever. Monotonic on purpose — see [`Timers::armed`].
    armings: BTreeMap<Timer, u64>,
    stopped: bool,
}

/// The shared half: everything the timer thread and its arming callers both touch.
#[derive(Debug, Default)]
struct State {
    table: Mutex<Table>,
    /// Signalled on every arm, cancel and stop, so a thread parked on an older deadline re-reads
    /// the table rather than sleeping through a nearer one.
    changed: Condvar,
}

/// One pane's delayed actions.
#[derive(Debug, Default)]
pub(crate) struct Timers {
    state: Arc<State>,
    /// `None` until the first arm. Under its own lock rather than the table's, so the spawn does
    /// not happen while the thread's own lock is held.
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Timers {
    /// A pane's timers, with no thread yet.
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Schedules `body` to run in `delay`, replacing whatever `kind` was holding.
    ///
    /// The replaced closure is dropped WITHOUT running — that is the cancel. Arming on a stopped
    /// set is a no-op, so a teardown racing a last offer cannot resurrect the thread.
    pub(crate) fn arm(&self, kind: Timer, delay: Duration, body: Box<dyn FnOnce() + Send>) {
        {
            let mut table = self.state.table.lock().unwrap_or_else(PoisonError::into_inner);
            if table.stopped {
                return;
            }
            table.slots.insert(kind, Pending {
                at: Instant::now() + delay,
                body,
            });
            *table.armings.entry(kind).or_default() += 1;
        }
        self.state.changed.notify_all();
        self.ensure_running();
    }

    /// Whether `kind` has an action waiting RIGHT NOW.
    ///
    /// `cfg(test)` because it is only sound for a caller that controls the delay, and the only
    /// such caller is the suite below. A 90 ms nudge observed from another thread can fire between
    /// the arm and the read, which is why anything holding a real one asks [`Timers::armed`].
    #[cfg(test)]
    pub(crate) fn is_armed(&self, kind: Timer) -> bool {
        self.state
            .table
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .slots
            .contains_key(&kind)
    }

    /// How many times `kind` has been armed, ever. A test seam: the nudge is a `SIGWINCH` to
    /// somebody else's process group, which nothing this side of the kernel can observe.
    ///
    /// A COUNT rather than "is one pending", because the assertion those tests want to make is
    /// "a size change schedules exactly one" — which a snapshot of the slot cannot answer either
    /// way. It reads false once the timer fires, so on a loaded machine the same correct behaviour
    /// passes or fails by how fast the reader got there; and it reads true for a drag that armed
    /// sixty, which is the regression the seam exists to catch. Monotonic answers both.
    pub(crate) fn armed(&self, kind: Timer) -> u64 {
        self.state
            .table
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .armings
            .get(&kind)
            .copied()
            .unwrap_or_default()
    }

    /// Drops every pending action, ends the thread and JOINS it.
    ///
    /// Joining is the point: a body still holding a `Weak` upgrade is running real work against a
    /// pane the caller believes is gone, and the census this thread is counted in would never reach
    /// zero. Idempotent, and safe to call on a set that never armed anything.
    pub(crate) fn stop(&self) {
        {
            let mut table = self.state.table.lock().unwrap_or_else(PoisonError::into_inner);
            table.stopped = true;
            table.slots.clear();
        }
        self.state.changed.notify_all();
        let handle = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(handle) = handle {
            // The bodies run on that thread and a teardown can reach here FROM one of them — the
            // settle applies a grid, and an apply can be what a caller tears down under. Joining
            // self would deadlock, so the handle is dropped instead: the thread is already stopping.
            if handle.thread().id() == std::thread::current().id() {
                return;
            }
            drop(handle.join());
        }
    }

    /// Starts the thread if this set has none yet.
    fn ensure_running(&self) {
        let mut held = self.thread.lock().unwrap_or_else(PoisonError::into_inner);
        if held.is_some() {
            return;
        }
        let state = Arc::clone(&self.state);
        // A refused spawn leaves `thread` as `None`, so the next arm tries again — and until one
        // succeeds the pending actions simply do not fire, which for a resize means the pane keeps
        // the size it has. There is no version of this worth panicking over.
        *held = std::thread::Builder::new()
            .name(String::from("slopdesk-pane-timers"))
            .spawn(move || run(&state))
            .ok();
    }
}

/// The timer thread's whole life: wake at the earliest deadline, run whatever is due, park again.
fn run(state: &Arc<State>) {
    loop {
        let due = {
            let mut table = state.table.lock().unwrap_or_else(PoisonError::into_inner);
            loop {
                if table.stopped {
                    return;
                }
                let now = Instant::now();
                // Take EVERY slot that has come due in one pass. Two deadlines a microsecond apart
                // would otherwise cost two full re-locks, and the second's body would be delayed by
                // the first's.
                let ready = table
                    .slots
                    .iter()
                    .filter(|(_, pending)| pending.at <= now)
                    .map(|(&kind, _)| kind)
                    .collect::<Vec<_>>();
                if !ready.is_empty() {
                    break ready
                        .into_iter()
                        .filter_map(|kind| table.slots.remove(&kind))
                        .collect::<Vec<_>>();
                }
                let next = table.slots.values().map(|pending| pending.at).min();
                table = match next {
                    // Nothing pending: park indefinitely. The thread stays for the pane's life
                    // rather than exiting, because a drag re-arms ~60 times a second and a thread
                    // that retired between frames would be re-created just as often.
                    None => state.changed.wait(table).unwrap_or_else(PoisonError::into_inner),
                    Some(at) => {
                        let (guard, _) = state
                            .changed
                            .wait_timeout(table, at.saturating_duration_since(now))
                            .unwrap_or_else(PoisonError::into_inner);
                        guard
                    },
                };
            }
        };
        // OUTSIDE the lock: a body arms another slot (the apply schedules the nudge), and running
        // it under the table's own mutex would be a self-deadlock rather than a subtle one.
        for pending in due {
            (pending.body)();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc::{Receiver, Sender, channel};
    use std::time::Duration;

    use super::{Timer, Timers};

    /// Bounded rather than a sleep: the assertion is "it fired", and a fixed sleep either flakes on
    /// a loaded machine or wastes the same wall clock on every green run.
    fn fired(within: Duration, signals: &Receiver<&'static str>) -> Option<&'static str> {
        signals.recv_timeout(within).ok()
    }

    fn signal(sender: &Sender<&'static str>, what: &'static str) -> Box<dyn FnOnce() + Send> {
        let sender = sender.clone();
        Box::new(move || {
            let _delivered = sender.send(what);
        })
    }

    #[test]
    fn an_armed_body_runs_after_its_delay() {
        let timers = Timers::new();
        let (sender, signals) = channel();
        timers.arm(Timer::Resize, Duration::from_millis(5), signal(&sender, "resize"));
        assert_eq!(fired(Duration::from_secs(2), &signals), Some("resize"));
        timers.stop();
    }

    /// The trailing-edge guarantee the debounce exists for: a burst fires ONCE, at the last arm.
    #[test]
    fn a_re_arm_replaces_the_pending_body_rather_than_adding_one() {
        let timers = Timers::new();
        let runs = Arc::new(AtomicUsize::new(0));
        let (sender, signals) = channel();
        for _ in 0_u8..20 {
            let counted = Arc::clone(&runs);
            timers.arm(
                Timer::Resize,
                Duration::from_millis(30),
                Box::new(move || {
                    counted.fetch_add(1, Ordering::AcqRel);
                }),
            );
        }
        timers.arm(Timer::Resize, Duration::from_millis(35), signal(&sender, "last"));
        assert_eq!(fired(Duration::from_secs(2), &signals), Some("last"));
        assert_eq!(runs.load(Ordering::Acquire), 0, "every earlier arm was cancelled");
        timers.stop();
    }

    /// Three kinds, three slots. A nudge must not cancel a settle.
    ///
    /// The claim is that BOTH bodies survive, which is why this reads the pair as a set rather than
    /// in deadline order: one pass takes every slot that has come due, so a cold first schedule —
    /// the thread is spawned by the arm that precedes it — can leave the two due together, and then
    /// they run in slot order rather than deadline order. That is the design, not a fault, and an
    /// ordered assertion here only fails when the machine is loaded.
    #[test]
    fn the_three_kinds_do_not_cancel_each_other() {
        let timers = Timers::new();
        let (sender, signals) = channel();
        timers.arm(
            Timer::Settle,
            Duration::from_millis(30),
            signal(&sender, "settle"),
        );
        timers.arm(Timer::Nudge, Duration::from_millis(5), signal(&sender, "nudge"));
        let mut heard = [
            fired(Duration::from_secs(2), &signals),
            fired(Duration::from_secs(2), &signals),
        ];
        heard.sort_unstable();
        assert_eq!(heard, [Some("nudge"), Some("settle")]);
        timers.stop();
    }

    /// The right-now readout: armed while waiting, gone once the body has been taken.
    ///
    /// A second wide rather than the nudge's own 90 ms, because the first assertion is a SNAPSHOT
    /// — a delay short enough to elapse while a loaded machine gets around to scheduling this
    /// thread would fail a timer that behaved perfectly. That fragility is the whole reason
    /// anything reading from another thread asks [`Timers::armed`] instead.
    #[test]
    fn a_slot_reads_as_armed_until_it_fires() {
        let timers = Timers::new();
        let (sender, signals) = channel();
        timers.arm(Timer::Nudge, Duration::from_secs(1), signal(&sender, "nudge"));
        assert!(timers.is_armed(Timer::Nudge));
        assert_eq!(fired(Duration::from_secs(5), &signals), Some("nudge"));
        assert!(!timers.is_armed(Timer::Nudge));
        timers.stop();
    }

    /// The readout the resize suite asks "how many nudges did that schedule" with. Monotonic: a
    /// cancel-replace counts twice and a fired timer keeps its count, which is exactly what makes
    /// it readable from a thread that does not own the delay.
    #[test]
    fn every_arm_is_counted_including_the_one_it_replaced() {
        let timers = Timers::new();
        let (sender, signals) = channel();
        assert_eq!(timers.armed(Timer::Nudge), 0);
        timers.arm(Timer::Nudge, Duration::from_secs(30), signal(&sender, "replaced"));
        timers.arm(Timer::Nudge, Duration::from_millis(5), signal(&sender, "nudge"));
        assert_eq!(timers.armed(Timer::Nudge), 2);
        assert_eq!(fired(Duration::from_secs(2), &signals), Some("nudge"));
        assert_eq!(timers.armed(Timer::Nudge), 2, "firing does not decrement");
        assert_eq!(
            timers.armed(Timer::Settle),
            0,
            "one kind's arms are not another's"
        );
        timers.stop();
    }

    /// A teardown must not leave a body to run against a pane that is gone.
    #[test]
    fn stopping_drops_a_pending_body_and_refuses_a_later_arm() {
        let timers = Timers::new();
        let (sender, signals) = channel();
        timers.arm(
            Timer::Resize,
            Duration::from_millis(200),
            signal(&sender, "before"),
        );
        timers.stop();
        timers.arm(Timer::Resize, Duration::from_millis(5), signal(&sender, "after"));
        assert_eq!(fired(Duration::from_millis(400), &signals), None);
    }

    /// A body that arms another slot is the settle → apply → nudge chain, and it must not deadlock
    /// on the table it was called out from under.
    #[test]
    fn a_body_may_arm_another_slot_from_inside_the_timer_thread() {
        let timers = Arc::new(Timers::new());
        let (sender, signals) = channel();
        let chained = Arc::clone(&timers);
        let onward = sender.clone();
        timers.arm(
            Timer::Settle,
            Duration::from_millis(5),
            Box::new(move || {
                chained.arm(
                    Timer::Nudge,
                    Duration::from_millis(5),
                    Box::new(move || {
                        let _delivered = onward.send("nudge");
                    }),
                );
            }),
        );
        assert_eq!(fired(Duration::from_secs(2), &signals), Some("nudge"));
        timers.stop();
    }

    /// A set nobody armed never spawned a thread, and stopping it is still well defined.
    #[test]
    fn stopping_a_set_that_never_armed_anything_is_a_no_op() {
        let timers = Timers::new();
        timers.stop();
        assert!(!timers.is_armed(Timer::Resize));
    }
}
