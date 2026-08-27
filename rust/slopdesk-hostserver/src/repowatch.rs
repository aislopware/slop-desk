//! The host's event-driven git-status source: one filesystem watch per repo with a live pane.
//!
//! `RepoStatusWatcher.swift` is 316 lines of which every DECISION already
//! belongs to [`slopdesk_muxsession::repo_watch`] — the refcounts, the debounce generation, the
//! one-reading-in-flight guard and its single re-arm, the dirty guard. What the Swift still held
//! was the machinery around that fold: a serial queue, a table of live streams, a timer, and a
//! second queue for the reading. That is what is here, and it is the last of `docs/60` stage E.
//!
//! ## Three seams, because three different things can hang
//! [`Watches`] is the filesystem (production: `slopdesk-apple-fsevents`), [`ReadsRepos`] is the git
//! walk, and [`Offload`] is where a slow thing runs. A suite drives all three inline and asserts on
//! ORDER — that a stale generation does nothing, that a reading arriving after its repo was
//! released is an ordinary answer — which is precisely what the Swift's `makeEventSource` seam
//! existed for and could only half-reach.
//!
//! ## Two locks, in one order, and never held across an EFFECT
//! `rules` is the fold and `handles` is the table of live watches, and the ORDER is rules → handles
//! with neither held while a door is STARTED, CANCELLED or PUSHED to. The one door asked under a
//! lock is [`ReadsRepos::is_repo_root`] — a single `stat`, which cannot re-enter this fold; see the
//! comment at its call site for why it is asked there rather than a round trip later. Keeping the
//! EFFECTS outside is not tidiness: dropping a `slopdesk_apple_fsevents::Watch` takes that crate's
//! own registry lock from inside `Drop`, and a `Watch` that fires while it is being dropped would
//! then be waiting for a lock this side holds.
//! Every method below therefore takes its verdict, releases the guard, and only then starts,
//! cancels or pushes anything. The Swift bought the same property with a serial queue and paid for
//! it with a second queue for the reading; here the reading is [`Offload`]'s and the queue is gone.
//!
//! ## The reading runs OFF the caller's thread, always
//! A repo on a wedged NFS mount must stall only its own reading — never another repo's event
//! delivery, never a pane's key resolve, never the stop. `Threads` gives one thread per reading and
//! the fold's own `probing` set bounds that at one per live repo.

use core::fmt;
use core::time::Duration;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use slopdesk_muxsession::repo_watch::{DEBOUNCE_SECONDS, ProbeVerdict, RepoWatch};
use slopdesk_wire::message::ProjectGitStatus;

use crate::channel::Offload;

/// A live filesystem watch, cancelled by DROP.
///
/// The trait carries no methods on purpose. `slopdesk-apple-fsevents`'s `Watch` already stops,
/// invalidates and releases its stream in `Drop`, and a `cancel()` beside that would be a second
/// way to end one thing — the shape `docs/60` §D.6.5 spent a whole module separating for the four
/// endings of a pane. Here there is one ending, so there is one door: `drop`.
pub trait Cancels: Send + Sync + fmt::Debug {}

/// The filesystem, as this fold needs it.
pub trait Watches: Send + Sync + fmt::Debug {
    /// Starts a recursive watch at `repo`, calling `on_change` for every burst under it.
    ///
    /// `None` when the framework refused, and that is an honest state rather than an error: the
    /// fold counts the repo as watched and simply never hears from it, so every later verdict about
    /// it is unreachable and the cancel it is eventually told to perform finds nothing. The Swift
    /// says the same thing in `startSourceOnQueue`.
    fn watch(&self, repo: &str, on_change: Box<dyn Fn() + Send + Sync>) -> Option<Box<dyn Cancels>>;
}

/// The two filesystem questions about a repo that are not events.
pub trait ReadsRepos: Send + Sync + fmt::Debug {
    /// Whether `path` is a repository toplevel — a `stat` of `path/.git`.
    ///
    /// An OPTIMISATION input, not half of a rule: the fold re-asks the same question itself, so a
    /// door that always answered `false` would only make the watcher do less work, never something
    /// different. That is why it is asked once per key change rather than per event.
    fn is_repo_root(&self, path: &str) -> bool;

    /// The repo's current git line, or `None` when it is not a repository after all.
    ///
    /// Runs on an [`Offload`] thread. It is a walk over someone's worktree and it is allowed to be
    /// slow; nothing above it holds a lock while it runs.
    fn status(&self, repo: &str) -> Option<ProjectGitStatus>;
}

/// Where a reading that is news goes, and whether anyone is listening.
pub trait Announces: Send + Sync + fmt::Debug {
    /// Ships one status to every attached session sectioned under its repo.
    fn push(&self, status: &ProjectGitStatus);

    /// Whether any client is attached at all.
    ///
    /// `false` skips the reading ENTIRELY rather than computing and dropping it — a wall of
    /// detached agent panes must not walk their worktrees for nobody. Catch-up is the client's
    /// existing reconnect pull, so nothing is lost, only deferred.
    fn has_audience(&self) -> bool;
}

/// The watcher: the fold, the live watches, and the three doors.
///
/// Held as an `Arc` because every seam hands back a callback that has to reach it again — an event
/// arriving, a debounce firing, a reading returning. The callbacks hold `Weak`, so a dropped
/// watcher makes an in-flight reading resolve to nothing rather than keeping the whole server
/// alive until a wedged mount answers.
#[derive(Debug)]
pub struct RepoWatcher<W, R, A, O> {
    rules: Mutex<RepoWatch>,
    handles: Mutex<HashMap<String, Box<dyn Cancels>>>,
    watches: W,
    repos: R,
    audience: A,
    offload: O,
    debounce: Duration,
}

impl<W: Watches + 'static, R: ReadsRepos + 'static, A: Announces + 'static, O: Offload + 'static>
    RepoWatcher<W, R, A, O>
{
    /// A watcher over the three doors, with the fold's own debounce.
    #[must_use]
    pub fn new(watches: W, repos: R, audience: A, offload: O) -> Arc<Self> {
        Self::with_debounce(
            watches,
            repos,
            audience,
            offload,
            Duration::from_secs_f64(DEBOUNCE_SECONDS),
        )
    }

    /// The same, with the debounce named — the seam a suite needs to fire a timer without waiting.
    #[must_use]
    pub fn with_debounce(watches: W, repos: R, audience: A, offload: O, debounce: Duration) -> Arc<Self> {
        Arc::new(Self {
            rules: Mutex::new(RepoWatch::new()),
            handles: Mutex::new(HashMap::new()),
            watches,
            repos,
            audience,
            offload,
            debounce,
        })
    }

    /// A pane's By-Project key latched: release the owner's prior repo and retain the new one.
    ///
    /// The first owner of a repo starts its watch; a NON-repo key (a plain-directory section)
    /// starts nothing. A `cd` out of a repo is the release, which is what keeps a repo from staying
    /// watched for the life of the process.
    pub fn note_project_key(self: &Arc<Self>, owner: u64, key: &str) {
        let effects = {
            let mut rules = self.lock_rules();
            if !rules.wants_key(owner, key) {
                return;
            }
            // Asked here rather than inside the guard's scope by accident: `is_repo_root` is a
            // filesystem call and the lock is held. It is one `stat` of a path the caller just
            // named, on the same thread that named it — the alternative is a second round trip
            // through the fold, which is the drift `docs/55` §6 is about.
            let is_root = self.repos.is_repo_root(key);
            rules.note_project_key(owner, key, is_root)
        };
        if let Some(cancel) = effects.cancel {
            self.cancel(&cancel);
        }
        if let Some(create) = effects.create {
            self.start(create);
        }
    }

    /// A pane ended: release its repo. The LAST owner leaving cancels the watch.
    pub fn drop_owner(&self, owner: u64) {
        let cancelled = self.lock_rules().drop_owner(owner);
        if let Some(repo) = cancelled {
            self.cancel(&repo);
        }
    }

    /// Daemon stop: cancel every watch and refuse all further work.
    ///
    /// The table is emptied wholesale afterwards rather than key by key, because the fold's list is
    /// what it BELIEVES is watched and the table is what actually is — a repo whose watch the
    /// framework refused is in one and not the other, and a stop that trusted the fold's list would
    /// leave that row behind forever.
    pub fn shutdown(&self) {
        let repos = self.lock_rules().shutdown();
        let stragglers = {
            let mut handles = self.lock_handles();
            for repo in &repos {
                drop(handles.remove(repo));
            }
            core::mem::take(&mut *handles)
        };
        drop(stragglers);
    }

    /// Whether a repo is being watched right now — the seam a suite asserts cancellation through.
    #[must_use]
    pub fn is_watching(&self, repo: &str) -> bool {
        self.lock_handles().contains_key(repo)
    }

    /// Starts the watch for a repo the fold just asked for one for.
    fn start(self: &Arc<Self>, repo: String) {
        let watcher = Arc::downgrade(self);
        let named = repo.clone();
        let Some(handle) = self.watches.watch(
            &repo,
            Box::new(move || {
                if let Some(watcher) = watcher.upgrade() {
                    watcher.source_event(&named);
                }
            }),
        ) else {
            return;
        };
        drop(self.lock_handles().insert(repo, handle));
    }

    /// Cancels one repo's watch, if this side ever managed to start it.
    fn cancel(&self, repo: &str) {
        let handle = self.lock_handles().remove(repo);
        drop(handle);
    }

    /// A burst landed for `repo`: re-arm the debounce, latest edge winning.
    fn source_event(self: &Arc<Self>, repo: &str) {
        let armed = self.lock_rules().source_event(repo);
        if let Some(generation) = armed {
            self.arm(repo.to_owned(), generation);
        }
    }

    /// Arms one debounce. The generation is what makes "latest wins" decidable when it fires.
    fn arm(self: &Arc<Self>, repo: String, generation: u64) {
        let watcher = Arc::downgrade(self);
        self.offload.after(
            self.debounce,
            Box::new(move || {
                if let Some(watcher) = watcher.upgrade() {
                    watcher.debounce_fired(&repo, generation);
                }
            }),
        );
    }

    /// A debounce fired holding `generation`. Only [`ProbeVerdict::Probe`] reads anything.
    fn debounce_fired(self: &Arc<Self>, repo: &str, generation: u64) {
        // Read one step earlier than the Swift used to, because the fold decides the
        // stale/gated/deferred ORDER and wants the answer with the question.
        let has_audience = self.audience.has_audience();
        let verdict = self.lock_rules().debounce_fired(repo, generation, has_audience);
        if verdict != ProbeVerdict::Probe {
            return;
        }
        let watcher = Arc::downgrade(self);
        let named = repo.to_owned();
        self.offload.run(Box::new(move || {
            let Some(watcher) = watcher.upgrade() else {
                return;
            };
            let status = watcher.repos.status(&named);
            watcher.finish(&named, status);
        }));
    }

    /// A reading returned. Push it if it is news, and re-arm if edges arrived while it ran.
    fn finish(self: &Arc<Self>, repo: &str, status: Option<ProjectGitStatus>) {
        let verdict = self.lock_rules().probe_finished(repo, status.as_ref());
        if verdict.push
            && let Some(status) = status
        {
            self.audience.push(&status);
        }
        if let Some(generation) = verdict.rearm {
            self.arm(repo.to_owned(), generation);
        }
    }

    /// The fold, with a poisoned lock treated as ordinary state.
    ///
    /// A panic in a caller's push sink must not take the watcher down with it: everything behind
    /// this lock is refcounts and generations, and every method on it is already total over
    /// hostile ordering, so the worst a half-applied verdict costs is one extra reading.
    fn lock_rules(&self) -> MutexGuard<'_, RepoWatch> {
        self.rules.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The live-watch table, on the same terms.
    fn lock_handles(&self) -> MutexGuard<'_, HashMap<String, Box<dyn Cancels>>> {
        self.handles.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The production git door: one status read AT the repo toplevel.
///
/// It goes through `slopdesk-git` directly rather than through a pane's metadata probe because
/// there is no pane here — the fd-less `-1, -1` the Swift used to construct was a stand-in for a
/// PTY the git questions never touched. `repo_root` is pinned to the WATCH key, the canonical
/// toplevel the type-34 resolver latched, so the client's section lookup matches byte for byte.
#[derive(Debug, Clone, Copy)]
pub struct GitRepos;

impl ReadsRepos for GitRepos {
    fn is_repo_root(&self, path: &str) -> bool {
        std::fs::exists(format!("{path}/.git")).unwrap_or(false)
    }

    fn status(&self, repo: &str) -> Option<ProjectGitStatus> {
        let payload = slopdesk_git::status::of_path(repo);
        if !payload.has_repo {
            return None;
        }
        let counts = payload.folded_counts();
        Some(ProjectGitStatus {
            repo_root: repo.to_owned(),
            branch: payload.branch,
            ahead: payload.ahead,
            behind: payload.behind,
            stash_count: payload.stash_count,
            staged: u32::try_from(counts.staged).unwrap_or(u32::MAX),
            modified: u32::try_from(counts.modified).unwrap_or(u32::MAX),
            untracked: u32::try_from(counts.untracked).unwrap_or(u32::MAX),
            conflicted: u32::try_from(counts.conflicted).unwrap_or(u32::MAX),
            changed_count: u32::try_from(payload.files.len()).unwrap_or(u32::MAX),
        })
    }
}

/// The production filesystem door: one `slopdesk-apple-fsevents` watch per repo, on one queue.
///
/// The queue is held here rather than created per watch because the framework delivers on whichever
/// queue the stream was given, and one serial queue for every repo is what makes "the callbacks do
/// not race each other" true without a second lock. It is a `DispatchQueue` and not a Rust thread
/// because that is the only thing `FSEventStreamSetDispatchQueue` takes.
#[cfg(target_os = "macos")]
#[derive(Debug)]
pub struct FsEvents {
    queue: dispatch2::DispatchRetained<dispatch2::DispatchQueue>,
}

#[cfg(target_os = "macos")]
impl FsEvents {
    /// A door with its own delivery queue.
    #[must_use]
    pub fn new() -> Self {
        Self {
            queue: dispatch2::DispatchQueue::new("slopdesk.host.repo-watch", None),
        }
    }
}

#[cfg(target_os = "macos")]
impl Default for FsEvents {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(target_os = "macos")]
impl Cancels for slopdesk_apple_fsevents::Watch {}

#[cfg(target_os = "macos")]
impl Watches for FsEvents {
    fn watch(&self, repo: &str, on_change: Box<dyn Fn() + Send + Sync>) -> Option<Box<dyn Cancels>> {
        let watch = slopdesk_apple_fsevents::Watch::watching(repo, &self.queue, on_change)?;
        Some(Box::new(watch))
    }
}
