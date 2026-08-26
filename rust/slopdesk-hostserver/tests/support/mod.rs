//! A pane that is only its answers.
//!
//! Every question [`slopdesk_hostserver::Pane`] asks is a fact about a pane rather than an effect
//! on one, and the two effects it has — the shutdown and the relinquish — are counted here instead
//! of performed. That is the whole reason the trait exists: a real
//! [`slopdesk_hostsession::PaneSession`] is a PTY, a superd socket and six threads, and a store
//! suite that had to build one per entry would be testing the pane rather than the retention.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostserver::service::ServiceHandle;
use slopdesk_hostserver::{EvictionObserver, Pane, TeardownExecutor};
use slopdesk_muxsession::registry::{self, Slot, Uuid};

/// A pane with no process behind it.
#[derive(Debug)]
pub struct Ghost {
    id: Uuid,
    slot: Slot,
    exited: AtomicBool,
    members: AtomicUsize,
    shutdowns: AtomicUsize,
    relinquishes: AtomicUsize,
}

impl Ghost {
    /// A live pane serving conversation `id`, with a fresh object identity.
    #[must_use]
    pub fn new(id: Uuid) -> Arc<Self> {
        Arc::new(Self {
            id,
            slot: registry::mint_slot(),
            exited: AtomicBool::new(false),
            members: AtomicUsize::new(0),
            shutdowns: AtomicUsize::new(0),
            relinquishes: AtomicUsize::new(0),
        })
    }

    /// A pane under a conversation id built from one byte, for the suites that only need distinct
    /// ids and do not care what they are.
    #[must_use]
    pub fn numbered(id: u8) -> Arc<Self> {
        let mut bytes = [0_u8; 16];
        bytes[0] = id;
        Self::new(bytes)
    }

    /// Says the shell has already exited.
    pub fn kill_child(&self) {
        self.exited.store(true, Ordering::SeqCst);
    }

    /// Says `count` members hold this pane.
    pub fn hold(&self, count: usize) {
        self.members.store(count, Ordering::SeqCst);
    }

    /// How many times the pane was ENDED.
    pub fn shutdowns(&self) -> usize {
        self.shutdowns.load(Ordering::SeqCst)
    }

    /// How many times the pane was let GO.
    pub fn relinquishes(&self) -> usize {
        self.relinquishes.load(Ordering::SeqCst)
    }
}

impl Pane for Ghost {
    fn id(&self) -> Uuid {
        self.id
    }

    fn slot(&self) -> Slot {
        self.slot
    }

    fn is_child_exited(&self) -> bool {
        self.exited.load(Ordering::SeqCst)
    }

    fn member_count(&self) -> usize {
        self.members.load(Ordering::SeqCst)
    }

    fn shutdown(&self) {
        self.shutdowns.fetch_add(1, Ordering::SeqCst);
    }

    fn relinquish(&self) {
        self.relinquishes.fetch_add(1, Ordering::SeqCst);
    }
}

/// The trait-object handle the table and the store take.
///
/// The turbofish is load-bearing: `Arc::clone` takes its target type from the CONTEXT, and the
/// context here is the `dyn` return — so the bare spelling asks for an `&Arc<dyn Pane>` it was
/// never given. Naming the source type pins the clone and leaves the coercion to the return.
pub fn as_pane(ghost: &Arc<Ghost>) -> Arc<dyn Pane> {
    Arc::<Ghost>::clone(ghost)
}

/// The same, for an eviction ledger a test wants to keep a typed handle on.
pub fn as_observer(seen: &Arc<Evictions>) -> Arc<dyn EvictionObserver> {
    Arc::<Evictions>::clone(seen)
}

/// A supervised child that is only its answers — the [`ServiceHandle`] half of [`Ghost`].
///
/// A real one is a superd fork behind a PTY and a subscription, and a lifecycle suite that had to
/// build one per round would be testing Node's boot time.
#[derive(Debug)]
pub struct Backend {
    running: AtomicBool,
    terminates: AtomicUsize,
    relinquishes: AtomicUsize,
}

impl Backend {
    /// A child that is running.
    #[must_use]
    pub fn up() -> Arc<Self> {
        Arc::new(Self {
            running: AtomicBool::new(true),
            terminates: AtomicUsize::new(0),
            relinquishes: AtomicUsize::new(0),
        })
    }

    /// Says the child has exited — a crash, or superd going away.
    pub fn die(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    /// How many times the service was ENDED.
    pub fn terminates(&self) -> usize {
        self.terminates.load(Ordering::SeqCst)
    }

    /// How many times it was let GO.
    pub fn relinquishes(&self) -> usize {
        self.relinquishes.load(Ordering::SeqCst)
    }
}

impl ServiceHandle for Backend {
    fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    fn terminate(&self) {
        self.running.store(false, Ordering::SeqCst);
        self.terminates.fetch_add(1, Ordering::SeqCst);
    }

    fn relinquish(&self) {
        self.relinquishes.fetch_add(1, Ordering::SeqCst);
    }
}

/// The trait-object handle a lifecycle takes, turbofished for the reason [`as_pane`] is.
pub fn as_service(backend: &Arc<Backend>) -> Arc<dyn ServiceHandle> {
    Arc::<Backend>::clone(backend)
}

/// An executor that runs each kill on the calling thread, so a test never has to wait for one.
#[derive(Debug, Clone, Copy)]
pub struct Now;

impl TeardownExecutor for Now {
    fn submit(&self, kill: Box<dyn FnOnce() + Send>) {
        kill();
    }
}

/// Every pane the store said it evicted, in the order it said so.
#[derive(Debug, Default)]
pub struct Evictions {
    seen: Mutex<Vec<Uuid>>,
}

impl Evictions {
    /// The session ids reported, oldest first.
    pub fn seen(&self) -> Vec<Uuid> {
        self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl EvictionObserver for Evictions {
    fn evicted(&self, pane: &Arc<dyn Pane>) {
        self.seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(pane.id());
    }
}
