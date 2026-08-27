//! Where a repo reading GOES, and the two calls a pane makes to keep the watch refcounted.
//!
//! ## The fold is not here, and neither is the filesystem
//! [`RepoWatcher`] owns the debounce, the one-reading-in-flight guard and the table of live
//! streams; `FsEvents` and `GitRepos` are its production filesystem and its git walk. What was
//! missing was the far end — the door the watcher pushes a finished reading THROUGH — and the
//! adapter that lets a pane's project-key latch reach the watcher's refcounts. Both are here
//! because both need the composition, and the composition is what `main` builds.
//!
//! ## One reading, two destinations, and they are not the same fact
//! The FAST path is type 35 on every live pane sectioned under the repo: an edge, delivered now,
//! and the reason the git line moves the moment a commit lands. The RETAINED value is
//! `project/gitSummary` in the workspace document, keyed by PROJECT rather than by pane — one repo
//! is one fact, and a pane-keyed copy would be N copies that can disagree. Without the second, a
//! client that has never seen this host renders no git line at all until the next `FSEvents` edge
//! happens to fire, which on a quiet repo is never.
//!
//! The document's value is the type-35 BODY verbatim — the same bytes the fast path pushes — so it
//! costs no new codec on either end. That is the Swift's rule, carried.
//!
//! ## The latch decides delivery, and the fan-in never reads it
//! [`Fanout::push`] offers the status to every live pane and lets each one's
//! [`Pane::push_git_status`] refuse. A fan-in that filtered by reading the latch itself would be
//! comparing against a value that may have moved between the read and the send, and the pane's own
//! read is the only one that cannot.
//!
//! ## Nothing is called under the sessions lock
//! Both halves snapshot and release. A push runs a send per pane, and a send that ran under the
//! host's one lock would put a slow socket in front of every spawn, attach and metadata verb in the
//! process.

use core::fmt;
use std::sync::Arc;

use slopdesk_hostserver::channel::{Offload, Threads};
use slopdesk_hostserver::repowatch::{Announces, FsEvents, GitRepos, ReadsRepos, RepoWatcher, Watches};
use slopdesk_hostserver::{SessionIds, WorkspaceDocument};
use slopdesk_wire::WireMessage;
use slopdesk_wire::message::ProjectGitStatus;

use crate::evict::LateHost;
use crate::keys::ProjectKeySink;

/// The watcher this daemon runs, with its four production doors named once.
///
/// An alias rather than four parameters spelled at every mention: the stop has to reach it, the
/// spawner's sink has to hold it, and both would otherwise carry the whole list.
pub type HostRepoWatcher = RepoWatcher<FsEvents, GitRepos, Fanout, Threads>;

/// The two destinations one finished reading has.
pub struct Fanout {
    late: Arc<LateHost>,
    document: Arc<WorkspaceDocument>,
    ids: Arc<dyn SessionIds>,
}

impl fmt::Debug for Fanout {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The document is a lock over the whole workspace; naming it here would make a debug print
        // of the watcher take it. The fields that matter to a reader are the two that are not it.
        formatter
            .debug_struct("Fanout")
            .field("late", &self.late)
            .finish_non_exhaustive()
    }
}

impl Fanout {
    /// The fan-in for `document`, resolving its panes through `late`.
    ///
    /// [`LateHost`] rather than an `Arc<Host>` for the reason `evict` has one: the watcher is built
    /// before the composition it pushes into, because the composition's spawner needs the watcher's
    /// refcount sink. The `Weak` inside also means an in-flight reading on a wedged mount resolves
    /// to nothing after a shutdown rather than holding the whole server alive.
    #[must_use]
    pub fn new(late: &Arc<LateHost>, document: &Arc<WorkspaceDocument>, ids: &Arc<dyn SessionIds>) -> Self {
        Self {
            late: Arc::clone(late),
            document: Arc::clone(document),
            ids: Arc::clone(ids),
        }
    }
}

impl Announces for Fanout {
    fn push(&self, status: &ProjectGitStatus) {
        let Some(host) = self.late.resolve() else {
            return;
        };
        // Snapshot, release, THEN send — see the module note. Control panes are included because a
        // `slopdesk-ctl` session is sectioned under a project the same way a client pane is.
        let panes = {
            let sessions = host.sessions();
            let mut every = sessions.live_panes();
            every.extend(sessions.control_panes());
            every
        };
        for pane in &panes {
            pane.push_git_status(status);
        }

        let project = {
            let candidate = self.ids.mint().unwrap_or_default();
            // The candidate is spent only when the repo is new to this daemon; the registry answers
            // the incumbent id otherwise. Minting one per push rather than per MISS keeps the
            // borrow to a single statement, and the cost is bounded by the fold's own debounce.
            host.sessions().project_id(&status.repo_root, candidate)
        };
        self.document
            .set_project(project, &status.repo_root, wire_body(status));
    }

    fn has_audience(&self) -> bool {
        self.late
            .resolve()
            .is_some_and(|host| host.sessions().connection_count() > 0)
    }
}

/// One status as the type-35 body: the framed message minus its 4-byte length and 1-byte tag.
///
/// `None` on a frame too short to hold either, which the encoder cannot produce — the fallback is
/// there so a malformed value clears the field instead of storing a truncated one that decodes far
/// enough to look real.
fn wire_body(status: &ProjectGitStatus) -> Option<Vec<u8>> {
    let framed = WireMessage::ProjectGitStatus(status.clone()).encode();
    framed.get(5..).map(<[u8]>::to_vec)
}

/// The watcher, as the two calls a pane makes into it.
///
/// A wrapper rather than an `impl` on [`RepoWatcher`] itself: the watcher is generic over its four
/// doors, and an implementation on it would carry those four parameters into every struct that
/// holds a sink. Here they are erased once, where the concrete types are already named.
#[derive(Debug)]
pub struct Keys<W, R, A, O> {
    watcher: Arc<RepoWatcher<W, R, A, O>>,
}

impl<W: Watches + 'static, R: ReadsRepos + 'static, A: Announces + 'static, O: Offload + 'static>
    Keys<W, R, A, O>
{
    /// The sink for `watcher`.
    #[must_use]
    pub fn new(watcher: &Arc<RepoWatcher<W, R, A, O>>) -> Self {
        Self {
            watcher: Arc::clone(watcher),
        }
    }
}

impl<W: Watches + 'static, R: ReadsRepos + 'static, A: Announces + 'static, O: Offload + 'static>
    ProjectKeySink for Keys<W, R, A, O>
{
    fn latched(&self, owner: u64, key: &str) {
        self.watcher.note_project_key(owner, key);
    }

    fn dropped(&self, owner: u64) {
        self.watcher.drop_owner(owner);
    }
}
