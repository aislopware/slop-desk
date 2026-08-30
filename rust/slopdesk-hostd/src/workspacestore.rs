//! The workspace document's home on disk, and the DEFAULT document for a host that has none.
//!
//! ## Two jobs, together, because getting the second one wrong is unrecoverable
//! They are two answers to one question — "what workspace does this host have?" — and once
//! client-side tree persistence is gone, a host that cannot answer leaves every client staring at a
//! blank window with no way to create the first pane. So a store that finds nothing MINTS a
//! session, a tab and a pane rather than answering empty.
//!
//! ## `workspace-state.json` is a SIBLING of `scrollback/`, not a file inside it
//! superd's journal sweep walks only `*.scrollback` in that directory, so it would never see this
//! file either way — but a workspace living inside a directory something else prunes is the kind of
//! arrangement that survives until the day it does not.
//!
//! ## The debounce is depth-1 and COALESCING
//! A burst of intents costs one write. The pending document is REPLACED rather than queued, and
//! [`WorkspaceStore::flush`] — the only call allowed to block, and only ever reached from the stop
//! — writes whatever is still held. A debounce that outlives the process loses the last thing the
//! user did.
//!
//! ## Write-to-temp-then-rename, and the bad file is kept
//! A half-written workspace file is the one outcome worse than no workspace file, because it
//! decodes far enough to look real. A file that does not decode, or decodes to something with no
//! topology, is moved ASIDE rather than overwritten: losing a workspace to a decode bug is
//! survivable if the bytes are still there to look at.
//!
//! ## The label, and the three rungs under it
//! The Swift labelled the workspace with `Host.current().localizedName` — the name a Mac calls
//! itself in Sharing preferences — fell back to the POSIX hostname, then to a constant. All three
//! rungs are here. The first is `slopdesk_apple_machine::localized_name`, which is that same
//! Foundation call and nothing more; the ORDER is this file's, because which rung to take is a
//! decision and the crate that touches the framework makes none. See `docs/60` §F.7.

use core::time::Duration;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use slopdesk_hostserver::{Minting, SessionIds, WorkspaceStore};
use slopdesk_tree::TreeWorkspace;
use slopdesk_wire::document::topology::write_topology;
use slopdesk_wire::document::{HostWorkspaceState, WorkspaceTopology, state_file};

use crate::observer::Stderr;

/// The document's file name inside the container.
const FILE_NAME: &str = "workspace-state.json";

/// How long a burst of intents is collapsed for before it reaches the disk.
///
/// Carried from the Swift verbatim. Long enough that dragging a split does not write per frame,
/// short enough that a crash loses at most one gesture.
const DEBOUNCE: Duration = Duration::from_millis(600);

/// The environment key that moves this ONE file.
///
/// The same escape hatch `SLOPDESK_SCROLLBACK_DIR` gives the journals, and what makes an end-to-end
/// test able to run against a real store without touching the developer's own workspace.
const DIR_KEY: &str = "SLOPDESK_WORKSPACE_STATE_DIR";

/// The freshest document waiting to be written, and whether a timer is already running for it.
#[derive(Debug, Default)]
struct Pending {
    state: Option<HostWorkspaceState>,
    armed: bool,
}

/// Everything the debounce thread needs, behind one pointer.
///
/// Separate from [`DiskWorkspace`] for one reason: [`WorkspaceStore::schedule_save`] takes `&self`
/// and the timer outlives the call, so the thread has to hold something owned. An `Arc` here rather
/// than `Arc<Self>` at every call site keeps the store an ordinary value the caller can build
/// without knowing that.
#[derive(Debug)]
struct Inner {
    path: PathBuf,
    host_display_name: String,
    ids: Arc<dyn SessionIds>,
    debounce: Duration,
    pending: Mutex<Pending>,
    /// Serialises the two writers — the debounce thread and a `flush` — so a stop that lands mid
    /// debounce cannot interleave two renames onto one path.
    disk: Mutex<()>,
    /// Set by the stop. A debounce thread that wakes after it returns without writing, so the
    /// flush's document is the last one on disk rather than the loser of a race with it.
    stopped: AtomicBool,
    log: Arc<Stderr>,
}

/// hostd's workspace store.
#[derive(Debug)]
pub struct DiskWorkspace {
    inner: Arc<Inner>,
}

impl DiskWorkspace {
    /// The store at the default location, or `None` when the container cannot be resolved.
    ///
    /// `None` is DEGRADED, not broken: the caller falls back to `NoStore`, the host still serves a
    /// workspace, and a client may still upload the layout it has.
    #[must_use]
    pub fn from_launch(ids: &Arc<dyn SessionIds>, log: &Arc<Stderr>) -> Option<Self> {
        let directory = match std::env::var(DIR_KEY) {
            Ok(named) if !named.is_empty() => PathBuf::from(named),
            _ => slopdesk_hostlaunch::record::app_support_dir()?,
        };
        Some(Self::at(&directory.join(FILE_NAME), ids, log))
    }

    /// The store over one exact path. The seam the suite drives.
    #[must_use]
    pub fn at(path: &Path, ids: &Arc<dyn SessionIds>, log: &Arc<Stderr>) -> Self {
        Self::with_debounce(path, ids, log, DEBOUNCE)
    }

    /// The same, with the debounce named — what a suite needs to assert coalescing without waiting.
    #[must_use]
    pub fn with_debounce(
        path: &Path,
        ids: &Arc<dyn SessionIds>,
        log: &Arc<Stderr>,
        debounce: Duration,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                path: path.to_path_buf(),
                host_display_name: host_display_name(),
                ids: Arc::clone(ids),
                debounce,
                pending: Mutex::new(Pending::default()),
                disk: Mutex::new(()),
                stopped: AtomicBool::new(false),
                log: Arc::clone(log),
            }),
        }
    }

    /// One session, one tab, one pane — the shape a first-run host publishes.
    #[must_use]
    pub fn default_document(&self) -> HostWorkspaceState {
        self.inner.default_document()
    }
}

impl Inner {
    /// One session, one tab, one pane.
    ///
    /// An EMPTY tree normalises into exactly that, so the shape is stated in one place —
    /// `slopdesk-tree`'s own repair — rather than spelled out a second time here.
    fn default_document(&self) -> HostWorkspaceState {
        let mut mint = Minting::over(self.ids.as_ref());
        let mut shape = WorkspaceTopology::new(TreeWorkspace::new(Vec::new(), None).normalized(&mut mint));
        shape.host_display_name.clone_from(&self.host_display_name);
        let mut state = HostWorkspaceState::new();
        write_topology(&mut state, &shape);
        state
    }

    /// Moves the current file aside under `reason`, so the bytes survive the decode that rejected
    /// them.
    fn set_aside(&self, reason: &str) {
        // Seconds since the epoch rather than a formatted date: the name only has to be unique and
        // sortable, and a locale-formatted timestamp in a filename is a bug waiting for a
        // traveller.
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let aside = self
            .path
            .with_file_name(format!("workspace-state.{reason}-{stamp}.json"));
        drop(std::fs::remove_file(&aside));
        if let Err(failure) = std::fs::rename(&self.path, &aside) {
            self.log.say(&format!(
                "workspace store: could not keep the previous file aside ({failure})"
            ));
            return;
        }
        self.log.say(&format!(
            "workspace store: previous file kept as {}",
            aside.display()
        ));
    }

    /// Writes whatever is pending, if anything. Runs on the debounce thread and on the stop.
    fn write_pending(&self) {
        let Some(state) = self
            .pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .state
            .take()
        else {
            return;
        };
        let _serialised = self.disk.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(directory) = self.path.parent() {
            drop(std::fs::create_dir_all(directory));
        }
        // Write-to-temp-then-rename by hand, because `std::fs` has no `.atomic`. The temp file is a
        // SIBLING so the rename cannot cross a filesystem boundary and degrade into a copy.
        let temporary = self.path.with_extension("json.writing");
        if let Err(failure) = std::fs::write(&temporary, state_file::encode(&state)) {
            self.log.say(&format!("workspace store: save failed ({failure})"));
            return;
        }
        if let Err(failure) = std::fs::rename(&temporary, &self.path) {
            drop(std::fs::remove_file(&temporary));
            self.log.say(&format!("workspace store: save failed ({failure})"));
        }
    }
}

impl WorkspaceStore for DiskWorkspace {
    fn has_stored(&self) -> bool {
        self.inner.path.exists()
    }

    fn load(&self) -> HostWorkspaceState {
        let Ok(text) = std::fs::read_to_string(&self.inner.path) else {
            return self.inner.default_document();
        };
        let restored = match state_file::decode(&text) {
            Ok(state) => state,
            Err(failure) => {
                self.inner.log.say(&format!(
                    "workspace store: {FILE_NAME} did not decode ({failure:?}) — minting the default"
                ));
                self.inner.set_aside("corrupt");
                return self.inner.default_document();
            },
        };
        // Decoded, but is it a WORKSPACE? A file whose sessions all failed the structural checks
        // has no topology, and publishing it would hand every client an empty window.
        if WorkspaceTopology::from_document(&restored).is_none() {
            self.inner.log.say(&format!(
                "workspace store: {FILE_NAME} holds no workspace — minting the default"
            ));
            self.inner.set_aside("empty");
            return self.inner.default_document();
        }
        restored
    }

    fn schedule_save(&self, state: &HostWorkspaceState) {
        if self.inner.stopped.load(Ordering::Acquire) {
            return;
        }
        let arm = {
            let mut pending = self.inner.pending.lock().unwrap_or_else(PoisonError::into_inner);
            // `persisting` is the FILTER over which cells belong on disk. Applied on the way in so
            // the debounce holds exactly the bytes that will be written, and a flush cannot decide
            // something different from the timer.
            pending.state = Some(state_file::persisting(state));
            let arm = !pending.armed;
            pending.armed = true;
            arm
        };
        if !arm {
            return;
        }
        // One thread per debounce WINDOW, not per save: the window is armed under the lock above
        // and a burst therefore costs one thread and one write however many intents arrive
        // inside it.
        let store = Arc::clone(&self.inner);
        drop(
            std::thread::Builder::new()
                .name(String::from("workspace-save"))
                .spawn(move || {
                    std::thread::sleep(store.debounce);
                    store.pending.lock().unwrap_or_else(PoisonError::into_inner).armed = false;
                    if store.stopped.load(Ordering::Acquire) {
                        return;
                    }
                    store.write_pending();
                }),
        );
    }

    fn flush(&self) {
        // Ordered before the write so a timer that wakes DURING it returns rather than racing the
        // rename with a document one edit older.
        self.inner.stopped.store(true, Ordering::Release);
        self.inner.write_pending();
    }
}

/// What this host calls itself, so a client can label the workspace it is looking at.
///
/// Three rungs, in the Swift's own order. The name the user SET is the one they recognise, so it
/// goes first; the POSIX hostname is what every machine has; and a workspace with no label is still
/// a workspace, so the last rung is a constant rather than an error.
///
/// Each rung rejects an EMPTY answer as well as a missing one. A host whose Sharing name was
/// cleared, or whose `gethostname` answers a zero-length string, has no label at that rung — and a
/// blank caption is the one outcome worse than a generic one, because it reads as a bug in the
/// client rather than as a machine nobody named.
fn host_display_name() -> String {
    if let Some(named) = slopdesk_apple_machine::localized_name() {
        return named;
    }
    let named = nix::unistd::gethostname()
        .ok()
        .and_then(|name| name.into_string().ok())
        .unwrap_or_default();
    if named.is_empty() {
        String::from("SlopDesk")
    } else {
        named
    }
}
