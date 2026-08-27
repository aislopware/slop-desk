//! When a repo's git line is worth re-reading, and who is still asking.
//!
//! hostd watches every repo that still has a live pane in it, so a project header stays honest
//! within about a second of an edit made OUTSIDE the app — a checkout in another terminal, a commit
//! from an editor, a branch switch. The mechanism is one filesystem event stream per repo TOPLEVEL;
//! everything interesting about it is what happens BETWEEN the events and the push, and that is
//! what is here.
//!
//! Four rules, each preventing a different failure:
//!
//!   1. **Refcounting.** N panes in one repo share ONE stream and ONE reading. Without it a
//!      twelve-pane project runs twelve identical filesystem walks per keystroke burst, and a pane
//!      that `cd`s out of a repo keeps that repo watched for the life of the process.
//!   2. **Debounce with a GENERATION.** A build or a checkout emits thousands of events; the arming
//!      is latest-wins, so they collapse into one reading a fixed delay after the LAST of them. The
//!      generation is what makes "latest wins" decidable: an armed timer that fires holding a stale
//!      number knows a newer edge already replaced it and does nothing. A counter rather than a
//!      timestamp, because two edges inside one clock tick must still be told apart.
//!   3. **One reading in flight per repo, with a single re-arm.** The read is a walk over someone's
//!      worktree and can be slow (a wedged network mount, a repository with a hundred thousand
//!      files). Events that land while it runs must not stack a second walk behind the first — but
//!      they also must not be forgotten, because the answer now returning was computed BEFORE them.
//!      So they collapse into exactly one follow-up, armed when the walk returns. **A dropped
//!      re-arm is the expensive bug in this file:** the git line simply stops updating for that
//!      repo until some unrelated later edge happens to arrive, and nothing anywhere reports that
//!      it has. A DOUBLED re-arm, by contrast, costs one extra walk. The asymmetry is why the
//!      re-arm is a set membership rather than a counter — it can be raised any number of times and
//!      lowered once.
//!   4. **The dirty guard.** `.git/objects` churn, a no-op save, a `git gc` — all of them move the
//!      filesystem without moving the STATUS. Pushing an identical reading wakes every attached
//!      client to redraw a line that did not change, which on a phone is a radio wake. So a reading
//!      is pushed only when it differs from the last one this repo pushed, and equality is
//!      [`ProjectGitStatus`]'s own, field for field — the same value the client would receive.
//!
//! ## What stays outside
//! The event stream itself, the two dispatch queues, the clock the debounce is measured on and the
//! walk that reads the status: all of that is `RepoStatusWatcher.swift`, which
//! is `FSEvents` and Grand Central Dispatch and a subprocess-shaped read. This module holds no
//! handle and starts no timer — it answers, for each edge the host reports, what the host should do
//! next.
//!
//! Sources are named by their repo path rather than held, for that reason: the caller keeps a
//! `path → handle` table and this side keeps the SET of paths a source has been asked for. The two
//! can only disagree when the caller failed to create a stream it was told to, and the answer there
//! is the same either way — a repo whose stream never existed never delivers an edge, so every
//! verdict about it is unreachable, and the cancel it is eventually told to perform finds nothing.
//!
//! ## Owners cross as integers
//! An owner is one pane session, identified by object identity on the caller's side. Identity
//! crosses as an opaque `u64` the same way [`crate::registry`]'s slots do: nothing here
//! dereferences it, compares it for order, or outlives the caller's own table, so any stable
//! per-owner integer is a correct one.

use std::collections::{BTreeMap, BTreeSet};

use slopdesk_wire::message::ProjectGitStatus;

/// How long after the LAST event of a burst the status is re-read, in seconds.
///
/// Long enough that a `git checkout` of a large tree is one reading rather than dozens, short
/// enough that a person who saves a file and looks at the header sees the new count before they
/// look away. The kernel's own event coalescing sits below this, so the number is the outer of two
/// windows.
pub const DEBOUNCE_SECONDS: f64 = 0.75;

/// The streams the caller should start and stop as a result of one key change.
///
/// Both are at most one: a key change releases the owner's PRIOR repo (which cancels only when that
/// owner was its last) and retains the new one (which creates only when this owner is its first).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyEffects {
    /// The repo whose stream has no owners left. The caller cancels its handle and forgets it.
    pub cancel: Option<String>,
    /// The repo that just gained its first owner. The caller starts a stream and files the handle.
    pub create: Option<String>,
}

/// What to do when an armed debounce fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeVerdict {
    /// Nothing: a newer edge already re-armed this repo, its last owner left, or the watcher
    /// stopped.
    Stale,
    /// No client is attached, so the reading is skipped ENTIRELY rather than computed and dropped —
    /// a wall of detached agent panes must not walk their worktrees for nobody. A client that
    /// reconnects pulls the current status itself, so nothing is lost, only deferred.
    NoAudience,
    /// A reading is already in flight for this repo. One follow-up is now armed for when it
    /// returns.
    Deferred,
    /// Read the status now.
    Probe,
}

/// What to do when a reading returns.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FinishVerdict {
    /// Whether this reading is news — see the dirty guard in the module documentation.
    pub push: bool,
    /// The generation to arm a follow-up debounce with, when events arrived during the reading.
    pub rearm: Option<u64>,
}

/// The whole verdict fold: who owns what, what is armed, what is in flight, and what was last said.
///
/// Every method is total over hostile ordering. Edges arrive from a filesystem, timers fire after
/// the thing they were about has been torn down, and a reading can return long after its repo was
/// released — so "this repo is not watched any more" is an ordinary answer at every entry point
/// rather than a state that should not happen.
#[derive(Debug, Default)]
pub struct RepoWatch {
    /// Which repo each owner is currently counted against.
    owner_repo: BTreeMap<u64, String>,
    /// How many owners each repo has.
    repo_owners: BTreeMap<String, usize>,
    /// Repos a stream has been asked for and not yet released.
    watched: BTreeSet<String>,
    /// The last reading pushed for each repo — the dirty guard's memory.
    last_pushed: BTreeMap<String, ProjectGitStatus>,
    /// The generation each repo's currently-armed debounce carries.
    pending_probe: BTreeMap<String, u64>,
    /// The monotonic edge counter the arming above draws from.
    probe_generation: u64,
    /// Repos with a reading in flight — the re-entry guard.
    probing: BTreeSet<String>,
    /// Repos whose events arrived WHILE a reading was in flight.
    rearm_after_probe: BTreeSet<String>,
    /// Whether the daemon has stopped, after which nothing is armed, created or pushed again.
    stopped: bool,
}

impl RepoWatch {
    /// A fold with nothing watched.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether [`note_project_key`](Self::note_project_key) would do anything at all.
    ///
    /// Exists so the caller can skip the filesystem test that answers `is_repo_root` — a `stat` per
    /// pane per prompt edge, almost always for a key that has not moved. It is an OPTIMISATION and
    /// not half of the rule: `note_project_key` re-asks the same question itself, so a caller that
    /// never consults this one behaves identically and only works harder.
    #[must_use]
    pub fn wants_key(&self, owner: u64, key: &str) -> bool {
        !self.stopped && self.owner_repo.get(&owner).map(String::as_str) != Some(key)
    }

    /// An owner latched a By-Project key: release whatever it was counted against and retain the
    /// new repo.
    ///
    /// `is_repo_root` is the caller's filesystem answer for `key`. A key that is NOT a repo
    /// toplevel — a plain-directory section — still releases the prior repo but retains
    /// nothing: there is no git line to keep honest, and watching an arbitrary directory would
    /// put an event stream on a home folder.
    pub fn note_project_key(&mut self, owner: u64, key: &str, is_repo_root: bool) -> KeyEffects {
        if !self.wants_key(owner, key) {
            return KeyEffects::default();
        }
        let cancel = self.release(owner);
        if !is_repo_root {
            return KeyEffects { cancel, create: None };
        }
        self.owner_repo.insert(owner, key.to_owned());
        let owners = self.repo_owners.entry(key.to_owned()).or_default();
        *owners += 1;
        let first = *owners == 1;
        let create = (first && self.watched.insert(key.to_owned())).then(|| key.to_owned());
        KeyEffects { cancel, create }
    }

    /// An owner ended. Answers the repo whose stream the caller should now cancel, if this was its
    /// last one.
    pub fn drop_owner(&mut self, owner: u64) -> Option<String> {
        self.release(owner)
    }

    /// The daemon stopped: every stream the caller should cancel, and nothing is ever armed again.
    ///
    /// `probing` and the re-arm set are deliberately NOT cleared. A reading already in flight will
    /// still return, and what stops it doing anything is the stopped latch every verdict reads
    /// first — clearing the sets would make a returning reading look like one nobody asked for,
    /// which is the same outcome by a less obvious route.
    pub fn shutdown(&mut self) -> Vec<String> {
        self.stopped = true;
        self.owner_repo.clear();
        self.repo_owners.clear();
        self.pending_probe.clear();
        self.last_pushed.clear();
        core::mem::take(&mut self.watched).into_iter().collect()
    }

    /// A filesystem event burst landed for `repo`: (re)arm the debounce, latest edge wins.
    ///
    /// Answers the generation the caller must hand back to [`debounce_fired`](Self::debounce_fired)
    /// when its timer expires, or `None` when this repo is not watched.
    pub fn source_event(&mut self, repo: &str) -> Option<u64> {
        if self.stopped || !self.watched.contains(repo) {
            return None;
        }
        // Wrapping rather than saturating: a saturated counter would make every later generation
        // compare equal to the armed one, so every stale timer would fire. Two edges 2^64 apart is
        // not a scenario, but "wrong forever once it happens" and "correct forever" cost the same.
        self.probe_generation = self.probe_generation.wrapping_add(1);
        self.pending_probe.insert(repo.to_owned(), self.probe_generation);
        Some(self.probe_generation)
    }

    /// The debounce armed at `generation` expired. `has_audience` is the caller's answer to "is any
    /// client attached", read one step earlier than the reading it gates.
    pub fn debounce_fired(&mut self, repo: &str, generation: u64, has_audience: bool) -> ProbeVerdict {
        if self.stopped || self.pending_probe.get(repo) != Some(&generation) || !self.watched.contains(repo) {
            return ProbeVerdict::Stale;
        }
        self.pending_probe.remove(repo);
        if !has_audience {
            return ProbeVerdict::NoAudience;
        }
        if self.probing.contains(repo) {
            self.rearm_after_probe.insert(repo.to_owned());
            return ProbeVerdict::Deferred;
        }
        self.probing.insert(repo.to_owned());
        ProbeVerdict::Probe
    }

    /// A reading returned. `None` means the path is not a repository any more, which is not news to
    /// push — a repo that has gone away pushes nothing rather than pushing an empty line.
    pub fn probe_finished(&mut self, repo: &str, status: Option<&ProjectGitStatus>) -> FinishVerdict {
        self.probing.remove(repo);
        let owed_rearm = self.rearm_after_probe.remove(repo);
        if self.stopped || !self.watched.contains(repo) {
            return FinishVerdict {
                push: false,
                rearm: None,
            };
        }
        let push = status.is_some_and(|status| {
            let news = self.last_pushed.get(repo) != Some(status);
            if news {
                self.last_pushed.insert(repo.to_owned(), status.clone());
            }
            news
        });
        let rearm = if owed_rearm { self.source_event(repo) } else { None };
        FinishVerdict { push, rearm }
    }

    /// Drops one owner's claim, and everything the repo remembered if that was the last of them.
    ///
    /// The push memory goes with the last owner ON PURPOSE. A repo nobody is in should not be able
    /// to suppress the first push after somebody opens a pane in it again — that first push is how
    /// a returning pane gets its line at all, and a remembered reading from before the gap
    /// would make it look unchanged.
    fn release(&mut self, owner: u64) -> Option<String> {
        let repo = self.owner_repo.remove(&owner)?;
        let remaining = self
            .repo_owners
            .get(&repo)
            .copied()
            .unwrap_or(1)
            .saturating_sub(1);
        if remaining > 0 {
            self.repo_owners.insert(repo, remaining);
            return None;
        }
        self.repo_owners.remove(&repo);
        let watched = self.watched.remove(&repo);
        self.last_pushed.remove(&repo);
        self.pending_probe.remove(&repo);
        // An in-flight reading's completion will find the repo unwatched and drop, so the re-arm it
        // was owed must go too — otherwise the next owner of this repo inherits a follow-up armed
        // for events it never saw.
        self.rearm_after_probe.remove(&repo);
        watched.then_some(repo)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a repo the fixture just watched answering None IS the failure report — a default \
                  generation here would let the arming break and still read as an armed debounce"
    )]

    use slopdesk_wire::message::ProjectGitStatus;

    use super::{FinishVerdict, KeyEffects, ProbeVerdict, RepoWatch};

    fn status(modified: u32) -> ProjectGitStatus {
        ProjectGitStatus {
            repo_root: "/repo".to_owned(),
            branch: "main".to_owned(),
            modified,
            changed_count: modified,
            ..ProjectGitStatus::default()
        }
    }

    fn created(repo: &str) -> KeyEffects {
        KeyEffects {
            cancel: None,
            create: Some(repo.to_owned()),
        }
    }

    /// Arms a repo and runs its debounce through to a verdict, the way the host's timer does.
    fn fire(watch: &mut RepoWatch, repo: &str, has_audience: bool) -> ProbeVerdict {
        watch
            .source_event(repo)
            .map_or(ProbeVerdict::Stale, |generation| {
                watch.debounce_fired(repo, generation, has_audience)
            })
    }

    /// Ported from `testNonRepoKeyNeverCreatesASource`: only a repo toplevel is ever watched.
    #[test]
    fn a_plain_directory_section_creates_nothing() {
        let mut watch = RepoWatch::new();
        assert_eq!(
            watch.note_project_key(1, "/scratch", false),
            KeyEffects::default()
        );
        assert_eq!(watch.note_project_key(1, "/repo", true), created("/repo"));
    }

    /// Ported from `testOwnersShareOneSourceAndLastDropCancels`.
    #[test]
    fn owners_share_one_stream_and_the_last_drop_cancels_it() {
        let mut watch = RepoWatch::new();
        assert_eq!(watch.note_project_key(1, "/repo", true), created("/repo"));
        assert_eq!(
            watch.note_project_key(2, "/repo", true),
            KeyEffects::default(),
            "a second owner joins the stream that is already up"
        );

        assert_eq!(watch.drop_owner(1), None, "a non-last drop keeps it");
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Probe);
        assert!(watch.probe_finished("/repo", Some(&status(1))).push);

        assert_eq!(watch.drop_owner(2), Some("/repo".to_owned()));
        assert_eq!(
            fire(&mut watch, "/repo", true),
            ProbeVerdict::Stale,
            "a late event on a released repo reads nothing"
        );
    }

    /// Ported from `testEventBurstDebouncesToOneProbeAndPush`: only the LAST edge of a burst has a
    /// live generation, so a thousand events cost one reading.
    #[test]
    fn a_burst_collapses_to_the_last_edge() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        let first = watch.source_event("/repo").expect("watched");
        let second = watch.source_event("/repo").expect("watched");
        let third = watch.source_event("/repo").expect("watched");
        assert_eq!(watch.debounce_fired("/repo", first, true), ProbeVerdict::Stale);
        assert_eq!(watch.debounce_fired("/repo", second, true), ProbeVerdict::Stale);
        assert_eq!(watch.debounce_fired("/repo", third, true), ProbeVerdict::Probe);
    }

    /// The same timer firing twice must not read twice — the generation is consumed, not compared
    /// and left.
    #[test]
    fn one_armed_generation_fires_once() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        let generation = watch.source_event("/repo").expect("watched");
        assert_eq!(
            watch.debounce_fired("/repo", generation, true),
            ProbeVerdict::Probe
        );
        assert_eq!(
            watch.debounce_fired("/repo", generation, true),
            ProbeVerdict::Stale
        );
    }

    /// Ported from `testUnchangedStatusIsNotRePushed`: porcelain-identical output wakes nobody, and
    /// a real change still does.
    #[test]
    fn an_identical_reading_is_not_pushed_again() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert!(watch.probe_finished("/repo", Some(&status(1))).push);
        assert!(!watch.probe_finished("/repo", Some(&status(1))).push);
        assert!(watch.probe_finished("/repo", Some(&status(2))).push);
    }

    /// A path that stopped being a repository pushes nothing, and does not disturb what was last
    /// said about it either.
    #[test]
    fn a_reading_that_found_no_repository_pushes_nothing() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert!(watch.probe_finished("/repo", Some(&status(1))).push);
        assert!(!watch.probe_finished("/repo", None).push);
        assert!(
            !watch.probe_finished("/repo", Some(&status(1))).push,
            "the memory survived the empty reading"
        );
    }

    /// Ported from `testSlowProbeNeverBlocksControlAndRearmsOnce`: events during an in-flight
    /// reading stack no second one and collapse into exactly ONE follow-up.
    #[test]
    fn events_during_a_reading_become_one_follow_up() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Probe);

        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Deferred);
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Deferred);

        let verdict = watch.probe_finished("/repo", Some(&status(1)));
        assert!(verdict.push);
        let rearm = verdict.rearm.expect("the buffered events are owed a reading");
        assert_eq!(watch.debounce_fired("/repo", rearm, true), ProbeVerdict::Probe);
        let verdict = watch.probe_finished("/repo", Some(&status(1)));
        assert!(!verdict.push, "identical output is still dirty-guarded");
        assert_eq!(
            verdict.rearm, None,
            "the re-arm fires once, not per buffered event"
        );
    }

    /// A reading that returns after its repo was released re-arms nothing and pushes nothing — the
    /// case a naive `probing` reset would turn into a stream nobody can cancel.
    #[test]
    fn a_reading_that_outlives_its_repo_is_dropped_whole() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Probe);
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Deferred);
        assert_eq!(watch.drop_owner(1), Some("/repo".to_owned()));

        assert_eq!(watch.probe_finished("/repo", Some(&status(1))), FinishVerdict {
            push: false,
            rearm: None
        });
    }

    /// A repo re-opened after everyone left gets its line back: the push memory left with the last
    /// owner, so the first reading is news again.
    #[test]
    fn the_push_memory_leaves_with_the_last_owner() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert!(watch.probe_finished("/repo", Some(&status(1))).push);
        watch.drop_owner(1);
        assert_eq!(watch.note_project_key(1, "/repo", true), created("/repo"));
        assert!(
            watch.probe_finished("/repo", Some(&status(1))).push,
            "a returning pane must get its line, not silence"
        );
    }

    /// Ported from `testRekeyReleasesThePriorRepo`: a pane that `cd`s into another repo hands the
    /// old one back in the same step.
    #[test]
    fn a_rekey_releases_the_prior_repo_and_retains_the_new_one() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert_eq!(watch.note_project_key(1, "/other", true), KeyEffects {
            cancel: Some("/repo".to_owned()),
            create: Some("/other".to_owned()),
        });
    }

    /// Re-latching the SAME key is not a rekey — a prompt edge that resolves to the folder the pane
    /// is already in must not cancel and re-create the stream under it.
    #[test]
    fn re_latching_the_same_key_changes_nothing() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert!(!watch.wants_key(1, "/repo"));
        assert_eq!(watch.note_project_key(1, "/repo", true), KeyEffects::default());
    }

    /// Ported from `testClosedProbeGateSkipsTheSubprocess`: no audience, no walk — and the edge is
    /// consumed rather than left armed, so it does not fire again when a client does attach.
    #[test]
    fn no_audience_skips_the_reading_entirely() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        assert_eq!(fire(&mut watch, "/repo", false), ProbeVerdict::NoAudience);
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Probe);
    }

    /// Ported from `testShutdownCancelsEverything`: every stream comes back to be cancelled, and a
    /// stopped fold creates nothing afterwards.
    #[test]
    fn shutdown_hands_back_every_stream_and_refuses_the_next_key() {
        let mut watch = RepoWatch::new();
        watch.note_project_key(1, "/repo", true);
        watch.note_project_key(2, "/other", true);
        assert_eq!(watch.shutdown(), vec!["/other".to_owned(), "/repo".to_owned()]);
        assert_eq!(watch.note_project_key(3, "/repo", true), KeyEffects::default());
        assert_eq!(fire(&mut watch, "/repo", true), ProbeVerdict::Stale);
        assert_eq!(watch.shutdown(), Vec::<String>::new());
    }

    /// An owner nobody ever latched, and a repo nothing ever watched: both are ordinary answers.
    #[test]
    fn an_unknown_owner_and_an_unwatched_repo_are_answers_not_faults() {
        let mut watch = RepoWatch::new();
        assert_eq!(watch.drop_owner(99), None);
        assert_eq!(watch.source_event("/nowhere"), None);
        assert_eq!(watch.debounce_fired("/nowhere", 7, true), ProbeVerdict::Stale);
        assert_eq!(
            watch.probe_finished("/nowhere", Some(&status(1))),
            FinishVerdict {
                push: false,
                rearm: None
            }
        );
    }
}
