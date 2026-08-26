//! The watcher's ORDER, which is the half the Swift's seams could only reach in pieces.
//!
//! `RepoStatusWatcher` confines everything to a serial queue, so its own tests could hand in a fake
//! event source and a fake probe but never say WHEN a timer fired relative to a reading returning —
//! the queue decided that. Here the debounce is a queue this suite drains by hand, so every test
//! below is about a relative order: an edge during a reading, a timer holding a stale generation, a
//! repo released while its reading was in flight, a stop with a watch the framework never started.
//!
//! Every RULE these tests exercise belongs to `slopdesk_muxsession::repo_watch` and is tested
//! there. What is asked here is the wiring: that a verdict reaches the door it names, that no lock
//! is held while it does, and that the two tables — the fold's belief and the live watches — cannot
//! drift apart.

use core::fmt;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use slopdesk_hostserver::channel::Offload;
use slopdesk_hostserver::repowatch::{Announces, Cancels, ReadsRepos, RepoWatcher, Watches};
use slopdesk_wire::message::ProjectGitStatus;

/// What a live watch is on this side: the callback the framework would fire, keyed by repo.
type Firings = Arc<Mutex<HashMap<String, Arc<dyn Fn() + Send + Sync>>>>;

/// A debounce that has not fired yet.
type Timers = Arc<Mutex<Vec<Box<dyn FnOnce() + Send>>>>;

/// One live watch, which ends the way the real one does — by being dropped.
struct Token {
    repo: String,
    live: Firings,
}

// Hand-written, three times over: a closure has no `Debug` and the seams demand one, because a
// server whose ladders print their own state is how every other suite in this crate reads.
impl fmt::Debug for Token {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        out.debug_struct("Token")
            .field("repo", &self.repo)
            .finish_non_exhaustive()
    }
}

impl Cancels for Token {}

impl Drop for Token {
    fn drop(&mut self) {
        drop(
            self.live
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(&self.repo),
        );
    }
}

/// The filesystem: which repos are watched, and a way to fire a burst under one.
///
/// The table lives behind its own `Arc` so a [`Token`] can outlive the borrow that made it.
#[derive(Clone)]
struct Filesystem {
    live: Firings,
    started: Arc<Mutex<Vec<String>>>,
    refuses: Arc<HashSet<String>>,
}

impl Filesystem {
    fn new() -> Self {
        Self {
            live: Arc::new(Mutex::new(HashMap::new())),
            started: Arc::new(Mutex::new(Vec::new())),
            refuses: Arc::new(HashSet::new()),
        }
    }

    fn refusing(repo: &str) -> Self {
        let mut refuses = HashSet::new();
        refuses.insert(repo.to_owned());
        Self {
            refuses: Arc::new(refuses),
            ..Self::new()
        }
    }

    fn burst(&self, repo: &str) {
        let fire = self
            .live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(repo)
            .map(Arc::clone);
        if let Some(fire) = fire {
            fire();
        }
    }

    fn watching(&self, repo: &str) -> bool {
        self.live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(repo)
    }

    fn started(&self) -> Vec<String> {
        self.started
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl fmt::Debug for Filesystem {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        out.debug_struct("Filesystem")
            .field("started", &self.started())
            .finish_non_exhaustive()
    }
}

impl Watches for Filesystem {
    fn watch(&self, repo: &str, on_change: Box<dyn Fn() + Send + Sync>) -> Option<Box<dyn Cancels>> {
        self.started
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(repo.to_owned());
        if self.refuses.contains(repo) {
            return None;
        }
        drop(
            self.live
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(repo.to_owned(), Arc::from(on_change)),
        );
        Some(Box::new(Token {
            repo: repo.to_owned(),
            live: Arc::clone(&self.live),
        }))
    }
}

/// The git side: which paths are repos, what each one reads as, and how often it was asked.
#[derive(Debug, Clone)]
struct Repos {
    roots: Arc<Mutex<HashSet<String>>>,
    readings: Arc<Mutex<HashMap<String, ProjectGitStatus>>>,
    asked: Arc<Mutex<Vec<String>>>,
}

impl Repos {
    fn holding(repo: &str, branch: &str) -> Self {
        let mut roots = HashSet::new();
        roots.insert(repo.to_owned());
        let mut readings = HashMap::new();
        drop(readings.insert(repo.to_owned(), status(repo, branch)));
        Self {
            roots: Arc::new(Mutex::new(roots)),
            readings: Arc::new(Mutex::new(readings)),
            asked: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// What the next reading of `repo` will answer.
    fn now_reads(&self, repo: &str, branch: &str) {
        drop(
            self.readings
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(repo.to_owned(), status(repo, branch)),
        );
    }

    fn asked(&self) -> Vec<String> {
        self.asked.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl ReadsRepos for Repos {
    fn is_repo_root(&self, path: &str) -> bool {
        self.roots
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(path)
    }

    fn status(&self, repo: &str) -> Option<ProjectGitStatus> {
        self.asked
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(repo.to_owned());
        self.readings
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(repo)
            .cloned()
    }
}

/// The push sink and the audience gate.
#[derive(Debug, Clone)]
struct Sink {
    pushed: Arc<Mutex<Vec<ProjectGitStatus>>>,
    listening: Arc<Mutex<bool>>,
}

impl Sink {
    fn attended() -> Self {
        Self {
            pushed: Arc::new(Mutex::new(Vec::new())),
            listening: Arc::new(Mutex::new(true)),
        }
    }

    fn empty() -> Self {
        let sink = Self::attended();
        *sink.listening.lock().unwrap_or_else(PoisonError::into_inner) = false;
        sink
    }

    fn pushed(&self) -> Vec<ProjectGitStatus> {
        self.pushed.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }
}

impl Announces for Sink {
    fn push(&self, status: &ProjectGitStatus) {
        self.pushed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(status.clone());
    }

    fn has_audience(&self) -> bool {
        *self.listening.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Work runs inline; a DELAY becomes a queue this suite drains, which is what makes order testable.
#[derive(Clone, Default)]
struct Hand {
    timers: Timers,
}

impl Hand {
    /// Runs every timer armed so far. Timers armed BY one of them wait for the next call, which is
    /// the property the re-arm tests turn on.
    fn tick(&self) {
        let due = core::mem::take(&mut *self.timers.lock().unwrap_or_else(PoisonError::into_inner));
        for work in due {
            work();
        }
    }

    fn armed(&self) -> usize {
        self.timers.lock().unwrap_or_else(PoisonError::into_inner).len()
    }
}

impl fmt::Debug for Hand {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        out.debug_struct("Hand").field("armed", &self.armed()).finish()
    }
}

impl Offload for Hand {
    fn run(&self, work: Box<dyn FnOnce() + Send>) {
        work();
    }

    fn after(&self, _delay: Duration, work: Box<dyn FnOnce() + Send>) {
        self.timers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(work);
    }
}

/// One reading, named by its branch so a test can tell two apart.
fn status(repo: &str, branch: &str) -> ProjectGitStatus {
    ProjectGitStatus {
        repo_root: repo.to_owned(),
        branch: branch.to_owned(),
        ahead: 0,
        behind: 0,
        stash_count: 0,
        staged: 0,
        modified: 0,
        untracked: 0,
        conflicted: 0,
        changed_count: 0,
    }
}

/// The four doors and the watcher over them, with the debounce under this suite's hand.
fn watcher(
    fs: &Filesystem,
    repos: &Repos,
    sink: &Sink,
    hand: &Hand,
) -> Arc<RepoWatcher<Filesystem, Repos, Sink, Hand>> {
    RepoWatcher::with_debounce(
        fs.clone(),
        repos.clone(),
        sink.clone(),
        hand.clone(),
        Duration::from_millis(1),
    )
}

#[test]
fn the_first_owner_of_a_repo_starts_its_watch_and_the_second_does_not() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    watch.note_project_key(2, "/r");
    assert_eq!(
        fs.started(),
        vec!["/r".to_owned()],
        "N panes in one repo share ONE stream — twelve identical walks per keystroke burst is the failure \
         this prevents",
    );
    assert!(watch.is_watching("/r"));
}

#[test]
fn a_key_that_is_not_a_repo_starts_nothing() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/not-a-repo");
    assert!(
        fs.started().is_empty(),
        "a plain-directory section is not watched"
    );
    assert!(!watch.is_watching("/not-a-repo"));
}

#[test]
fn the_last_owner_leaving_cancels_the_watch_and_an_earlier_one_does_not() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    watch.note_project_key(2, "/r");
    watch.drop_owner(1);
    assert!(fs.watching("/r"), "one owner left, so the stream stays");
    watch.drop_owner(2);
    assert!(
        !fs.watching("/r"),
        "the LAST owner leaving is what ends it — and the framework handle is actually dropped",
    );
    assert!(!watch.is_watching("/r"));
}

#[test]
fn a_cd_out_of_a_repo_releases_it_rather_than_watching_it_forever() {
    let fs = Filesystem::new();
    let repos = Repos::holding("/r", "main");
    repos
        .roots
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert("/other".to_owned());
    let (sink, hand) = (Sink::attended(), Hand::default());
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    watch.note_project_key(1, "/other");
    assert!(!fs.watching("/r"), "the prior repo is released by the same call");
    assert!(fs.watching("/other"));
}

#[test]
fn a_burst_reads_once_after_the_debounce_and_pushes_what_it_read() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    fs.burst("/r");
    assert!(
        repos.asked().is_empty(),
        "nothing is read before the debounce fires"
    );
    hand.tick();
    assert_eq!(repos.asked(), vec!["/r".to_owned()]);
    assert_eq!(sink.pushed().len(), 1);
    assert_eq!(
        sink.pushed().first().map(|s| s.branch.clone()),
        Some("main".to_owned())
    );
}

#[test]
fn a_thousand_events_collapse_into_one_reading() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    for _ in 0..1_000 {
        fs.burst("/r");
    }
    assert_eq!(
        hand.armed(),
        1_000,
        "every edge arms — latest wins is decided when they FIRE"
    );
    hand.tick();
    assert_eq!(
        repos.asked(),
        vec!["/r".to_owned()],
        "999 of them hold a stale generation and do nothing; a build costs ONE walk",
    );
}

#[test]
fn a_reading_that_says_the_same_thing_twice_is_pushed_once() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    fs.burst("/r");
    hand.tick();
    fs.burst("/r");
    hand.tick();
    assert_eq!(repos.asked().len(), 2, "both edges are read");
    assert_eq!(
        sink.pushed().len(),
        1,
        "the dirty guard is what keeps `.git/objects` churn from waking every client",
    );
}

#[test]
fn a_reading_that_changed_is_news_again() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    fs.burst("/r");
    hand.tick();
    repos.now_reads("/r", "topic");
    fs.burst("/r");
    hand.tick();
    let pushed = sink.pushed();
    assert_eq!(pushed.len(), 2);
    assert_eq!(
        pushed.get(1).map(|status| status.branch.clone()),
        Some("topic".to_owned()),
        "the second push is the reading that changed"
    );
}

#[test]
fn no_audience_skips_the_walk_entirely_rather_than_reading_and_dropping() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::empty(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    fs.burst("/r");
    hand.tick();
    assert!(
        repos.asked().is_empty(),
        "a wall of detached agent panes must not walk their worktrees for nobody",
    );
    assert!(sink.pushed().is_empty());
}

#[test]
fn a_repo_released_before_its_debounce_fires_is_an_ordinary_answer() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    fs.burst("/r");
    watch.drop_owner(1);
    hand.tick();
    assert!(
        repos.asked().is_empty(),
        "a timer firing after the thing it was about was torn down is ordinary, not a bug",
    );
    assert!(sink.pushed().is_empty());
}

#[test]
fn a_watch_the_framework_refused_leaves_the_two_tables_agreeing_that_nothing_is_live() {
    let (fs, repos, sink, hand) = (
        Filesystem::refusing("/r"),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    assert_eq!(fs.started(), vec!["/r".to_owned()], "it was asked for");
    assert!(!watch.is_watching("/r"), "and it is not live");
    watch.drop_owner(1);
    assert!(
        !watch.is_watching("/r"),
        "the cancel it is told to do finds nothing, and says so"
    );
}

#[test]
fn the_stop_cancels_every_watch_and_refuses_everything_after() {
    let fs = Filesystem::new();
    let repos = Repos::holding("/a", "main");
    repos
        .roots
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert("/b".to_owned());
    let (sink, hand) = (Sink::attended(), Hand::default());
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/a");
    watch.note_project_key(2, "/b");
    watch.shutdown();
    assert!(!fs.watching("/a"));
    assert!(!fs.watching("/b"));
    assert!(!watch.is_watching("/a"));
    watch.note_project_key(3, "/a");
    assert_eq!(
        fs.started(),
        vec!["/a".to_owned(), "/b".to_owned()],
        "nothing is created again after the stop",
    );
}

#[test]
fn the_stop_takes_a_row_the_folds_own_list_does_not_know_about() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    watch.shutdown();
    assert!(
        !fs.watching("/r"),
        "the table of what is LIVE is emptied wholesale, not key by key off the fold's belief",
    );
}

#[test]
fn a_dropped_watcher_lets_an_armed_timer_resolve_to_nothing() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    {
        let watch = watcher(&fs, &repos, &sink, &hand);
        watch.note_project_key(1, "/r");
        fs.burst("/r");
    }
    hand.tick();
    assert!(
        repos.asked().is_empty(),
        "the callbacks hold Weak — a dropped watcher must not be kept alive by a pending timer",
    );
}

#[test]
fn an_event_for_a_repo_nobody_watches_does_nothing() {
    let (fs, repos, sink, hand) = (
        Filesystem::new(),
        Repos::holding("/r", "main"),
        Sink::attended(),
        Hand::default(),
    );
    let watch = watcher(&fs, &repos, &sink, &hand);
    watch.note_project_key(1, "/r");
    fs.burst("/never-watched");
    assert_eq!(hand.armed(), 0);
    assert!(repos.asked().is_empty());
}
