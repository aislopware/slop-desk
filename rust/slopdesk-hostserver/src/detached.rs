//! TTL-bounded store for panes whose client has left.
//!
//! When a client disconnects with detach enabled, the host [`DetachedStore::insert`]s the pane here
//! instead of shutting the shell down. It lives here until either the client returns and
//! [`DetachedStore::claim`]s it, the TTL fires and [`DetachedStore::evict`] kills the shell, or the
//! daemon stops — which is [`DetachedStore::relinquish_all`], and it kills nothing at all.
//!
//! ## Why it holds its own lock, where [`crate::sessions`] holds none
//!
//! Because the two are the opposite shape. The table's atomicity is the SERVER's — its ladders
//! mutate the registry and the object maps together, so a lock in there would be a second one. The
//! store's atomicity is its OWN, and it has to be: the exclusive hand-off is a removal and a timer
//! cancellation in ONE critical section, and no caller can be trusted to hold that for it. The
//! nesting is one-way (server → store, never back), which is what keeps it deadlock-free.
//!
//! ## The two races that shaped it
//!
//! 1. **A fire-and-forget insert** can lose to a fast reconnect's lookup, which then misses the
//!    store and spawns a SECOND shell under the same session id — an orphaned live PTY and two
//!    writers interleaving one scrollback journal. So the insert is synchronous: when it returns, a
//!    reconnect's claim is guaranteed to find the entry.
//! 2. **A lookup that returns the pane without removing it** lets two concurrent reconnects — or a
//!    reconnect racing an armed TTL — both obtain it; the loser's later close then kills the
//!    winner's live PTY and deletes its journal. So there is no lookup. There is only
//!    [`DetachedStore::claim`], which TAKES.
//!
//! ## Where the kills happen
//!
//! Never on the caller's thread. Every kill in here goes through [`TeardownExecutor`], for two
//! reasons that are both about blocking: an overflow eviction fires while the server may hold its
//! own lock, and a relinquish can spend seconds waiting for input-quiet — so `relinquish_all` lets
//! N panes go in PARALLEL rather than one after another. It is an injected executor rather than a
//! loose thread per kill so that a suite can make the whole thing deterministic, which is the same
//! bargain [`slopdesk_hostsession::ResolveExecutor`] already struck.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use slopdesk_muxsession::detach_retention::{self, Occupant, TtlChoice};
use slopdesk_muxsession::registry::Uuid;

use crate::deadline::Deadlines;
use crate::pane::Pane;

/// Where a kill runs, so that it is never the caller's thread.
pub trait TeardownExecutor: Send + Sync + core::fmt::Debug {
    /// Runs `kill` off the caller's thread. Implementations may run them concurrently — a
    /// `relinquish_all` over N panes wants exactly that.
    fn submit(&self, kill: Box<dyn FnOnce() + Send>);
}

/// An executor that runs each kill on its own thread and never joins it.
///
/// hostd's, and the honest description of what the Swift dispatch queue did: `shutdownDetached` was
/// `teardownQueue.async`, and nothing waited for it either. A suite wants the inline one instead.
#[derive(Debug, Clone, Copy)]
pub struct DetachedTeardown;

impl TeardownExecutor for DetachedTeardown {
    fn submit(&self, kill: Box<dyn FnOnce() + Send>) {
        drop(
            std::thread::Builder::new()
                .name("slopdesk-teardown".to_owned())
                .spawn(kill),
        );
    }
}

/// An executor that runs the kill on the calling thread.
///
/// Correct for a caller with no queue behind it — the kill still happens, in order — and the only
/// thing given up is the guarantee that a slow teardown cannot stall the caller.
#[derive(Debug, Clone, Copy)]
pub struct InlineTeardown;

impl TeardownExecutor for InlineTeardown {
    fn submit(&self, kill: Box<dyn FnOnce() + Send>) {
        kill();
    }
}

/// Who hears that the store itself KILLED a parked pane.
///
/// TTL eviction and overflow eviction, and only those two: they are the non-deliberate ends of life
/// that never reach the server's own removal, so this is how the server learns to release the
/// pane's per-id resources — the journal writer fd and the hook-sink key.
///
/// Deliberately NOT fired for three other removals, each for its own reason. A claim's dead-child
/// reap runs under the server's lock and the immediately-following fresh spawn for the same id
/// reuses the journal writer anyway. A displaced same-id duplicate shares the id with the entry
/// that stays, so releasing would tear down the LIVE one's resources. And `remove`/`drain_all`
/// belong to their callers: a detached exit wires its own cleanup, and a drain is the daemon
/// stopping.
///
/// Always invoked OUTSIDE the store lock, after the kill has been submitted.
pub trait EvictionObserver: Send + Sync + core::fmt::Debug {
    /// The pane the store killed. Handed over whole rather than by id, so the handler can tear down
    /// instance-owned resources without guessing whether a same-id successor took the id over.
    fn evicted(&self, pane: &Arc<dyn Pane>);
}

/// An observer that hears nothing. The default, and correct for a store nobody is watching.
#[derive(Debug, Clone, Copy)]
pub struct IgnoreEvictions;

impl EvictionObserver for IgnoreEvictions {
    fn evicted(&self, _pane: &Arc<dyn Pane>) {}
}

/// What a claim concluded.
#[derive(Debug, Clone)]
pub enum Claim {
    /// No entry under that id — either it was never parked, or somebody else took it first.
    NotFound,
    /// The pane, taken exclusively. Exactly one caller can ever reach this for a given id.
    Claimed(Arc<dyn Pane>),
    /// The entry was there but its shell had already exited, so it was reaped instead of handed
    /// over.
    ///
    /// Reported apart from [`Claim::NotFound`] because the caller has just inherited a teardown the
    /// pane's own exit closure stood down from: it still owes the final agent-status `.none` — the
    /// prevent-sleep counter is strictly balanced — and the hook-sink drop, before it spawns the
    /// same-id fresh shell.
    ReapedDeadChild(Arc<dyn Pane>),
}

impl Claim {
    /// The live pane, `None` for the other two outcomes.
    #[must_use]
    pub fn claimed(&self) -> Option<&Arc<dyn Pane>> {
        match self {
            Self::Claimed(pane) => Some(pane),
            Self::NotFound | Self::ReapedDeadChild(_) => None,
        }
    }
}

/// One parked pane.
#[derive(Debug, Clone)]
struct Entry {
    pane: Arc<dyn Pane>,
    detached_at: Instant,
}

/// The parked panes, and the two rules that decide who may take one.
#[derive(Debug)]
pub struct DetachedStore {
    held: Mutex<HashMap<Uuid, Entry>>,
    /// Armed TTLs, by session id. Its own lock, taken only after this one is released.
    deadlines: Deadlines,
    /// Where every kill runs.
    teardown: Arc<dyn TeardownExecutor>,
    /// Who hears an eviction.
    on_evicted: Arc<dyn EvictionObserver>,
    /// OPT-IN cap on concurrently-parked panes, or `None` for UNBOUNDED.
    ///
    /// `None` is the default and the tmux/zellij semantics — verified against both sources: neither
    /// imposes a session count limit, and neither ever silently kills a live detached session.
    /// Their resource bound is per-pane scrollback, which `SlopDesk` already has and stricter. When
    /// a cap IS set, the OLDEST by park time is killed to make room.
    cap: Option<usize>,
    /// The zero instant every stamp is measured from, so the rule can read them as `f64` seconds
    /// the way the wire and the Swift both did.
    epoch: Instant,
}

impl DetachedStore {
    /// A store with no cap, nothing watching it, and kills on their own threads.
    #[must_use]
    pub fn new() -> Self {
        Self::with(None, Arc::new(DetachedTeardown), Arc::new(IgnoreEvictions))
    }

    /// A store with every seam given.
    #[must_use]
    pub fn with(
        cap: Option<usize>,
        teardown: Arc<dyn TeardownExecutor>,
        on_evicted: Arc<dyn EvictionObserver>,
    ) -> Self {
        Self {
            held: Mutex::new(HashMap::new()),
            deadlines: Deadlines::new(),
            teardown,
            on_evicted,
            cap,
            epoch: Instant::now(),
        }
    }

    /// Parks `pane` under its session id and arms a TTL, killing the oldest entry first if the cap
    /// is set and full.
    ///
    /// IDEMPOTENT per pane: re-parking one the store already holds keeps the ORIGINAL entry, its
    /// park time and its armed TTL. The failed-rebind re-park and the link-down handler can both
    /// park the same pane on a mid-reattach drop, and a second arm beside an entry that already has
    /// one is precisely the leak that rule prevents — both evict by ID, so the first to fire kills
    /// whatever entry holds that id by then.
    ///
    /// `ttl` of `None` keeps the pane parked INDEFINITELY, which is the default and the tmux/zellij
    /// semantics; the cap is the resource bound in that mode.
    ///
    /// Synchronous by contract: when this returns, a reconnect's [`Self::claim`] is guaranteed to
    /// find the entry. The caller must invoke it inline, never fire-and-forget.
    pub fn insert(self: &Arc<Self>, pane: &Arc<dyn Pane>, ttl: Option<Duration>) {
        let id = pane.id();
        let mut displaced = None;
        let mut victim = None;
        let arms;
        {
            let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
            // The store is a map and the rule reads a LIST, so one ordering is taken here and every
            // answer comes back as a position into that same ordering.
            let entries: Vec<(Uuid, Entry)> = held.iter().map(|(id, entry)| (*id, entry.clone())).collect();
            let occupant = entries
                .iter()
                .position(|(filed, _)| *filed == id)
                .map(|position| {
                    let same = entries
                        .get(position)
                        .is_some_and(|(_, entry)| crate::pane::same_pane(&entry.pane, pane));
                    Occupant {
                        position,
                        same_session: same,
                    }
                });
            let stamps: Vec<f64> = entries
                .iter()
                .map(|(_, entry)| self.seconds(entry.detached_at))
                .collect();
            let verdict = detach_retention::insert_verdict(&stamps, occupant, self.cap);
            if verdict.idempotent {
                return;
            }
            if verdict.displace {
                // Same id, DIFFERENT pane: newest wins, but the displaced entry's TTL must be
                // cancelled — it would evict the NEW entry later — and its now-unreachable pane
                // reaped rather than leaked.
                //
                // What keeps this rare is the JOIN: a live id routes to the pane that already
                // exists, so two connections holding one pane share ONE object and park it exactly
                // once, when the last subscriber leaves. But "should be unreachable" is not a
                // licence to reap blind, which is why the reap below is conditional on nobody
                // holding it: a pane with members is live and reachable, and killing it here would
                // take down a client's running agent to make room for a store entry.
                displaced = held.remove(&id);
            }
            if let Some(position) = verdict.victim
                && let Some((doomed, _)) = entries.get(position)
            {
                victim = held.remove(doomed);
            }
            // Whether there is to be a timer is the rule's; running one is not.
            arms = detach_retention::ttl_on_insert(verdict.idempotent, ttl.is_some()) == TtlChoice::Arm;
            held.insert(id, Entry {
                pane: Arc::clone(pane),
                detached_at: Instant::now(),
            });
        }

        // BEFORE the arm below, and the order is the whole correctness of this pair. The wheel is
        // keyed by SESSION id, not by entry, so the displaced entry's timer and the new entry's are
        // one key: cancelling after arming would disarm the successor and leave the store holding a
        // pane whose TTL silently never fires. Swift could write these the other way round because
        // its timer hung off the `Entry` object; this one cannot.
        if let Some(displaced) = displaced {
            self.deadlines.cancel(id);
            // Reaped only when nothing is watching it — see the note at the removal above.
            if displaced.pane.member_count() == 0 {
                self.kill(displaced.pane);
            }
        }
        if let (true, Some(ttl)) = (arms, ttl) {
            // WEAK, not strong, and it is a leak rather than a style choice: the callback lives in
            // `self.deadlines`, which is a field of `self`, so a strong handle would be a cycle no
            // drop could ever break — the wheel only clears its queue when the store drops, and the
            // store cannot drop while the queue holds it. An armed TTL for a store that is already
            // gone has nothing to evict.
            let store = Arc::downgrade(self);
            self.deadlines.arm(
                id,
                ttl,
                Box::new(move || {
                    if let Some(store) = store.upgrade() {
                        store.evict(id);
                    }
                }),
            );
        }
        if let Some(victim) = victim {
            self.deadlines.cancel(victim.pane.id());
            self.on_evicted.evicted(&victim.pane);
            self.kill(victim.pane);
        }
    }

    /// Atomically TAKES the pane parked under `session` — the removal and the TTL cancellation are
    /// one hand-off — or answers why it could not.
    ///
    /// Exclusivity is the point: of two concurrent reconnects presenting the same id, exactly ONE
    /// gets the pane; the other sees [`Claim::NotFound`] and falls through to the fresh-shell path,
    /// where the server's live-id guard refuses the duplicate. Cancelling the TTL closes the
    /// reattach-vs-eviction race from the other end — once claimed, an armed eviction finds nothing
    /// filed and can never kill the PTY out from under the in-flight rebind.
    ///
    /// A pane whose child has already exited is AUTO-REAPED rather than handed over: the zombie
    /// would be reaped when its exit fires, but a client that reconnects first wants a fresh shell,
    /// not a dead one.
    pub fn claim(&self, session: Uuid) -> Claim {
        let entry = {
            self.held
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&session)
        };
        // Cancelled after the lock is released, and that is safe for the reason the module note
        // gives: the REMOVAL above is the latch, so an eviction that fires between the two finds
        // nothing filed, wins no verdict and kills nothing.
        self.deadlines.cancel(session);

        // Asked outside the lock, deliberately. `is_child_exited` reads the pane's own exit latch,
        // and the notification that sets it runs a teardown that comes back through `remove` —
        // taking that lock under this one would put the two in a cycle.
        let child_exited = entry.as_ref().is_some_and(|entry| entry.pane.is_child_exited());
        let verdict = detach_retention::take(entry.is_some(), child_exited);
        let Some(entry) = entry.filter(|_| verdict.won) else {
            return Claim::NotFound;
        };
        if !verdict.reap_dead_child {
            return Claim::Claimed(entry.pane);
        }
        let reaped = Arc::clone(&entry.pane);
        self.kill(entry.pane);
        Claim::ReapedDeadChild(reaped)
    }

    /// Whether a pane is parked under `session`.
    ///
    /// The server's failed-rebind recovery asks it to decide whether a refused reattach must
    /// RE-park the pane, which the link-down handler may already have done. Safe under the server's
    /// lock — the nesting is one-way.
    #[must_use]
    pub fn contains(&self, session: Uuid) -> bool {
        self.held
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(&session)
    }

    /// How many panes are parked.
    #[must_use]
    pub fn len(&self) -> usize {
        self.held.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Whether nothing is parked.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Every parked pane, oldest first.
    ///
    /// A pane whose client quit is ALIVE — that is the entire point of the store — but it lived
    /// outside every enumeration the product had, so `slopdesk-ctl list-panes` reported nothing for
    /// exactly the panes a returning user cares about. Ordered by park time so the listing is
    /// stable rather than map-ordered.
    #[must_use]
    pub fn all(&self) -> Vec<Arc<dyn Pane>> {
        let entries: Vec<Entry> = {
            let held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
            held.values().cloned().collect()
        };
        let stamps: Vec<f64> = entries
            .iter()
            .map(|entry| self.seconds(entry.detached_at))
            .collect();
        detach_retention::detached_order(&stamps)
            .into_iter()
            .filter_map(|position| entries.get(position).map(|entry| Arc::clone(&entry.pane)))
            .collect()
    }

    /// Drops the entry WITHOUT killing the shell, and answers whether THIS call removed it.
    ///
    /// Called when the shell exits naturally while its pane is parked: the PTY is already dead, so
    /// there is nothing to kill and only the entry to drop.
    ///
    /// `false` means a claim, an eviction or a drain already took it and owns the per-id teardown.
    /// A stale exit closure firing afterwards must then stand down, or it releases the journal
    /// writer and hook-sink key a same-id SUCCESSOR is already using — which silently kills the
    /// live pane's journaling and agent-status routing.
    pub fn remove(&self, session: Uuid) -> bool {
        let entry = {
            self.held
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&session)
        };
        // `child_exited: false` is a statement, not a shrug: the shell's own exit is WHY this is
        // being called, so there is nothing left to discover about the child and nothing to reap.
        let verdict = detach_retention::take(entry.is_some(), false);
        if verdict.ttl == TtlChoice::Cancel {
            self.deadlines.cancel(session);
        }
        verdict.won
    }

    /// Kills and drops the pane parked under `session` — the TTL's own callback, and the overflow
    /// path's name for what it does.
    ///
    /// A no-op when the entry was already claimed or removed: the eviction-vs-reattach race
    /// resolves in the reattach's favour, and this is where that is spelled.
    pub fn evict(&self, session: Uuid) {
        let entry = {
            self.held
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&session)
        };
        // The same take, read for the same latch. `child_exited` is not asked because the answer
        // changes nothing here — this path kills either way, and a dead child's kill is idempotent.
        let verdict = detach_retention::take(entry.is_some(), false);
        let Some(entry) = entry.filter(|_| verdict.won) else {
            return;
        };
        if verdict.ttl == TtlChoice::Cancel {
            self.deadlines.cancel(session);
        }
        self.on_evicted.evicted(&entry.pane);
        self.kill(entry.pane);
    }

    /// Kills every parked pane.
    ///
    /// NOT the daemon-stop path — see [`Self::relinquish_all`]. This is for the callers that really
    /// do mean "end these panes": a store being torn down for good.
    pub fn drain_all(&self) {
        for entry in self.take_all() {
            self.deadlines.cancel(entry.pane.id());
            self.kill(entry.pane);
        }
    }

    /// Lets every parked pane GO without killing a single shell — the daemon-stop path.
    ///
    /// A parked pane is, by definition, one whose client already left and whose shell the user
    /// still wants. Killing exactly those on a daemon stop was the sharpest edge of the old
    /// behaviour. The ENTRIES are dropped because the store belongs to this hostd; the PANES do
    /// not, and superd hands them back to the next one.
    ///
    /// Every pane is let go on the executor rather than in this loop, because a relinquish can
    /// block on input-quiet and N of them in series is N times that wait. Answers a handle the
    /// caller can wait on — the stop order needs to know they all landed.
    pub fn relinquish_all(&self) -> Relinquished {
        let entries = self.take_all();
        let outstanding = Arc::new((Mutex::new(entries.len()), std::sync::Condvar::new()));
        for entry in entries {
            self.deadlines.cancel(entry.pane.id());
            let pane = entry.pane;
            let remaining = Arc::clone(&outstanding);
            self.teardown.submit(Box::new(move || {
                pane.relinquish();
                let (count, wake) = &*remaining;
                let mut left = count.lock().unwrap_or_else(PoisonError::into_inner);
                *left = left.saturating_sub(1);
                drop(left);
                wake.notify_all();
            }));
        }
        Relinquished { outstanding }
    }

    /// Stops the TTL thread without firing anything still armed.
    ///
    /// Separate from the two drains because it is a different sentence: they decide the panes' fate
    /// and this only ends the timer. Called last in the stop order, after whichever drain ran.
    pub fn stop(&self) {
        self.deadlines.stop();
    }

    /// How many TTLs are armed — what a test watches instead of waiting one out.
    #[must_use]
    pub fn armed(&self) -> usize {
        self.deadlines.armed()
    }

    /// Empties the map under one lock hold and answers what was in it.
    fn take_all(&self) -> Vec<Entry> {
        let mut held = self.held.lock().unwrap_or_else(PoisonError::into_inner);
        held.drain().map(|(_, entry)| entry).collect()
    }

    /// A kill, off the caller's thread — see the module note on where kills happen.
    fn kill(&self, pane: Arc<dyn Pane>) {
        self.teardown.submit(Box::new(move || pane.shutdown()));
    }

    /// One park time, as seconds since this store's epoch. The rules read `f64` stamps because the
    /// two callers they were written for both had one.
    fn seconds(&self, at: Instant) -> f64 {
        at.saturating_duration_since(self.epoch).as_secs_f64()
    }
}

impl Default for DetachedStore {
    fn default() -> Self {
        Self::new()
    }
}

/// A [`DetachedStore::relinquish_all`] in flight.
#[derive(Debug, Clone)]
pub struct Relinquished {
    outstanding: Arc<(Mutex<usize>, std::sync::Condvar)>,
}

impl Relinquished {
    /// Waits until every pane has been let go, or `timeout` elapses. Answers whether they all did.
    ///
    /// Bounded rather than open-ended on purpose: this runs in hostd's stop order, and a pane whose
    /// relinquish wedges must not be able to hold the daemon open forever.
    pub fn wait(&self, timeout: Duration) -> bool {
        let (count, wake) = &*self.outstanding;
        let (left, _) = wake
            .wait_timeout_while(
                count.lock().unwrap_or_else(PoisonError::into_inner),
                timeout,
                |left| *left > 0,
            )
            .unwrap_or_else(PoisonError::into_inner);
        let landed = *left == 0;
        // Released before the answer leaves, rather than at the end of the scope: a caller that
        // waits on two of these in a row must not hold the first one's lock through the second.
        drop(left);
        landed
    }
}
