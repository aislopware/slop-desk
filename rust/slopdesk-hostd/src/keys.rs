//! A pane's By-Project key, and the repo watch it refcounts.
//!
//! ## Two halves of one fact, and only one of them is a session's to report
//! [`KeyObserver`] is a session telling the world "this pane's project key changed". The other half
//! — "this pane is gone, release whatever it was holding" — is not a key event at all, so it does
//! not belong on that trait. It arrives here as a [`CloseTap`], which is the session's own end-of-
//! life door, and the two together are what keep the watcher's refcounts balanced: every `latched`
//! has exactly one `closed` after it, whatever ends the pane.
//!
//! ## The owner id is minted here, not borrowed from the pane
//! [`RepoWatcher`](slopdesk_hostserver::RepoWatcher) refcounts by an opaque `u64`. The obvious
//! candidate — the pane's `Slot` — is minted by `LivePane::adopt`, which happens AFTER the session
//! that needs the observer exists. Rather than reorder the build around a refcount key, the spawner
//! mints one of its own per pane; nothing outside this process ever sees it, and the only property
//! required of it is that no two live panes share one.
//!
//! ## Why a trait rather than the watcher itself
//! `RepoWatcher` is generic over its four doors, so naming it in a field would carry four type
//! parameters through the spawner and into every struct that holds one. [`ProjectKeySink`] is the
//! two calls hostd actually makes, object-safe, so the spawner holds one pointer and the assembly
//! decides what is behind it — including nothing, on a host with repo watching switched off.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use slopdesk_hostsession::{CloseTap, KeyObserver};

/// The next repo-watch owner id.
///
/// Process-wide rather than per-spawner because the property required of the number is that no two
/// LIVE panes share one, and a counter per spawner would be one counter per spawner to keep that
/// true across. Wrapping is not a concern at one id per pane spawn.
static OWNERS: AtomicU64 = AtomicU64::new(1);

/// Mints an owner id for one pane's hold on the repo watches.
///
/// `Relaxed` is the whole ordering requirement: nothing is published alongside the number, and the
/// only thing asked of two calls is that they differ, which the atomic guarantees on its own.
pub fn mint_owner() -> u64 {
    OWNERS.fetch_add(1, Ordering::Relaxed)
}

/// The refcounted half of repo watching, as the two calls a pane makes into it.
pub trait ProjectKeySink: Send + Sync + core::fmt::Debug {
    /// `owner` now sits under `key`. Releases whatever it was under before.
    fn latched(&self, owner: u64, key: &str);

    /// `owner` is gone. The LAST owner of a repo leaving is what cancels its watch.
    fn dropped(&self, owner: u64);
}

/// One pane's end of [`ProjectKeySink`]: the owner id is bound, so the session passes only the key.
#[derive(Debug)]
pub struct WatchKeys {
    sink: Arc<dyn ProjectKeySink>,
    owner: u64,
}

impl WatchKeys {
    /// Binds `owner` to `sink` for this pane's life.
    #[must_use]
    pub fn new(sink: &Arc<dyn ProjectKeySink>, owner: u64) -> Self {
        Self {
            sink: Arc::clone(sink),
            owner,
        }
    }
}

impl KeyObserver for WatchKeys {
    fn latched(&self, key: &str) {
        self.sink.latched(self.owner, key);
    }
}

impl CloseTap for WatchKeys {
    /// The pane ended, so its hold on whatever repo it was in ends with it.
    ///
    /// Installed as a close tap rather than driven from the host's close ladder because the ladder
    /// has several ends — a shell exit, a link drop, a TTL sweep, a topology reap — and a refcount
    /// released on some of them is a repo watched for the life of the process. The tap fires once,
    /// from the exit thread, whichever end it was.
    fn closed(&self) {
        self.sink.dropped(self.owner);
    }
}
