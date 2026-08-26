//! One thread that fires callbacks at times, for the store's TTL evictions.
//!
//! ## Why not [`slopdesk_hostsession`]'s `Timers`
//!
//! Because the two want opposite things from a re-arm, and both are right about their own case. A
//! pane's resize timer is trailing-edge — arming again during a drag REPLACES the deadline, which
//! is the entire point at sixty arms a second. A detach TTL must do the reverse: re-parking a
//! session the store already holds keeps the ORIGINAL deadline, because the clock started when the
//! client left and a mid-reattach link drop is not a fresh departure. Sharing one type would mean
//! one of the two callers passing a flag to switch off the other's semantics.
//!
//! The other half of the answer is scale, in the direction that makes this the cheap one. Detach
//! evictions are rare and OFF by default (`SLOPDESK_DETACH_TTL_SECS` unset means never), so this
//! thread usually does not exist at all — and when it does, it is ONE thread for every parked pane
//! rather than the one-per-entry a `Task` per entry becomes once `Task` is a thread.
//!
//! ## The race it does not have to win
//!
//! A fired callback that lost to a claim is harmless, so nothing here needs to be atomic with the
//! store's map. The store's REMOVAL is the latch: an eviction that runs after a claim finds nothing
//! filed, wins no verdict and kills nothing. That is why [`Deadlines::cancel`] may be called after
//! the store lock is released, and why a callback firing while a cancel is in flight is a miss
//! rather than a bug.

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use slopdesk_muxsession::registry::Uuid;

/// What one armed deadline is: when it fires, and what it runs.
type Fire = Box<dyn FnOnce() + Send>;

/// Armed deadlines, ordered by when they fire. The id is in the key so two deadlines at the same
/// instant still get distinct entries, and so a cancel can find its own.
#[derive(Default)]
struct Armed {
    /// (fires-at, id) → the callback. Ordered, so the head is always the next to run.
    pending: BTreeMap<(Instant, Uuid), Fire>,
    /// id → the key it is filed under, so a cancel is one lookup rather than a scan.
    filed: BTreeMap<Uuid, Instant>,
    /// Set once, by [`Deadlines::stop`]. The thread drains and exits.
    stopping: bool,
}

/// A timer wheel: arm by id, cancel by id, one thread.
#[derive(Debug)]
pub struct Deadlines {
    state: Arc<(Mutex<Armed>, Condvar)>,
    /// Spawned on the FIRST arm, not at construction: a store with no TTL configured — the default
    /// — never starts one.
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl core::fmt::Debug for Armed {
    fn fmt(&self, out: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        out.debug_struct("Armed")
            .field("pending", &self.pending.len())
            .field("filed", &self.filed.len())
            .field("stopping", &self.stopping)
            .finish()
    }
}

impl Default for Deadlines {
    fn default() -> Self {
        Self::new()
    }
}

impl Deadlines {
    /// A wheel with nothing armed and no thread running.
    #[must_use]
    pub fn new() -> Self {
        Self {
            state: Arc::new((Mutex::new(Armed::default()), Condvar::new())),
            thread: Mutex::new(None),
        }
    }

    /// Arms `fire` to run `after` from now, replacing whatever `id` had armed before.
    ///
    /// The replacement is not the store's re-park semantics leaking in — the store never arms twice
    /// for one entry, which is what `ttl_on_insert`'s idempotent arm exists to guarantee. It is
    /// here so that a second arm cannot orphan the first, which would fire against an id its
    /// successor now holds.
    pub fn arm(&self, id: Uuid, after: Duration, fire: Fire) {
        let (lock, wake) = &*self.state;
        let at = Instant::now() + after;
        {
            let mut armed = lock.lock().unwrap_or_else(PoisonError::into_inner);
            if armed.stopping {
                return;
            }
            if let Some(previous) = armed.filed.insert(id, at) {
                armed.pending.remove(&(previous, id));
            }
            armed.pending.insert((at, id), fire);
        }
        wake.notify_all();
        self.ensure_thread();
    }

    /// Disarms `id`, if it is armed. A miss is the ordinary case, not an error — see the module
    /// note on the race this does not have to win.
    pub fn cancel(&self, id: Uuid) {
        let (lock, wake) = &*self.state;
        {
            let mut armed = lock.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(at) = armed.filed.remove(&id) else {
                return;
            };
            armed.pending.remove(&(at, id));
        }
        wake.notify_all();
    }

    /// How many deadlines are armed — what a test watches instead of waiting one out.
    #[must_use]
    pub fn armed(&self) -> usize {
        let (lock, _) = &*self.state;
        lock.lock().unwrap_or_else(PoisonError::into_inner).pending.len()
    }

    /// Drops every armed deadline WITHOUT firing it and joins the thread.
    ///
    /// Not firing is the point: a stop is hostd going away, and every path that ends a parked pane
    /// on the way out is the store's own — `drain_all` or `relinquish_all` — which have already
    /// decided whether the shell dies. A wheel that flushed its queue here would kill exactly the
    /// panes `relinquish_all` just handed back to superd.
    pub fn stop(&self) {
        let (lock, wake) = &*self.state;
        {
            let mut armed = lock.lock().unwrap_or_else(PoisonError::into_inner);
            armed.stopping = true;
            armed.pending.clear();
            armed.filed.clear();
        }
        wake.notify_all();
        let handle = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(handle) = handle {
            // A self-join would deadlock, and it is reachable: a fired callback runs ON this thread
            // and may end up calling `stop`. The thread is left for the process to reap in that
            // case, which is what it does with every other thread at exit.
            if handle.thread().id() == std::thread::current().id() {
                return;
            }
            drop(handle.join());
        }
    }

    /// Spawns the thread if it is not already running.
    fn ensure_thread(&self) {
        let mut held = self.thread.lock().unwrap_or_else(PoisonError::into_inner);
        if held.is_some() {
            return;
        }
        let state = Arc::clone(&self.state);
        *held = std::thread::Builder::new()
            .name("slopdesk-deadlines".to_owned())
            .spawn(move || run(&state))
            .ok();
    }
}

impl Drop for Deadlines {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The wheel: park until the head is due, take it, run it OUTSIDE the lock.
///
/// Running outside the lock is what keeps the nesting one-way. Every callback the store arms comes
/// straight back into the store's own lock, and a callback that ran holding this one would put the
/// two in a cycle the first eviction would find.
fn run(state: &Arc<(Mutex<Armed>, Condvar)>) {
    let (lock, wake) = &**state;
    loop {
        let mut armed = lock.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if armed.stopping {
                return;
            }
            let Some((&(at, id), _)) = armed.pending.iter().next() else {
                // Nothing armed. Park indefinitely: an arm or a stop is what wakes this.
                armed = wake.wait(armed).unwrap_or_else(PoisonError::into_inner);
                continue;
            };
            let now = Instant::now();
            if at > now {
                let (again, _) = wake
                    .wait_timeout(armed, at - now)
                    .unwrap_or_else(PoisonError::into_inner);
                armed = again;
                continue;
            }
            armed.filed.remove(&id);
            let due = armed.pending.remove(&(at, id));
            // Unlocked BEFORE the callback runs, always: see the note above this function.
            drop(armed);
            if let Some(fire) = due {
                fire();
            }
            break;
        }
    }
}
