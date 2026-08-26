//! The adoption ladder: what a hostd does with the shells that outlived the one before it.
//!
//! `adoptSurvivingPanes`, `adoptSurvivingPane`, `reportUnclaimedPanes`, `resumePointForSurvivor`
//! and the three static note keepers around them — `HostServer.swift`'s start-up half, in one
//! module.
//!
//! ## Why this is not "just enumerate and take"
//! superd outlives hostd by design: a `slopdesk-hostd` restart leaves every shell running, and the
//! next daemon's job is to pick them back up with their `claude` sessions mid-thought. Which of
//! the panes superd lists are THIS daemon's is four questions, not one, and the wrong answer in
//! either direction is unrecoverable rather than merely wrong:
//!
//! - Take a pane another live hostd is holding, and two daemons share one master fd, one journal
//!   file and one eviction timer. The second one to arm a TTL `SIGHUP`s a pane a client is typing
//!   into.
//! - Refuse a pane that IS ours, and the shell survives perfectly and reaches no tab ever again: it
//!   is in no map, in no store, and every later `start()` reads it as somebody else's.
//!
//! [`slopdesk_muxsession::open_route::survivor`] is the decision, as a table. What is here is the
//! ORDER around it — read the list, spend the notes, take each master, park each pane — and the
//! one piece of state that cannot live in a pure function.
//!
//! ## The note set, and why it outlives the host
//! hostd deliberately never disconnects from superd in `stop()`: a `release` still has to travel,
//! and disconnecting there was tried — it cut exactly that verb, and a pane the user had closed
//! came back adopted after the restart. The cost is that superd keeps reporting this process's
//! released panes as `attached` for as long as the process lives.
//!
//! An ordinary restart hides the whole question behind `exit(0)`. The menu-bar host does not: it
//! stops and starts in ONE process, and there the next `start()` saw its own panes as another
//! daemon's and left them running for ever. [`LetGo`] is the note that says otherwise, and it is
//! injected through [`HostParts`](crate::HostParts) rather than owned by a [`Host`] for exactly the
//! reason the Swift made it `static`: the point is that it outlives the host that wrote it.
//!
//! ## What deliberately did NOT come here
//! - **The masters.** [`Spawner::adopt`](crate::Spawner) takes the fd back and builds the session;
//!   this module decides which ids to ask about and what to do with each pane afterwards.
//! - **The note WRITER's enumeration.** [`Host::note_panes_let_go`] walks the tables this crate
//!   already owns, but the stop order that calls it is D.6.5's.

use core::fmt;
use std::collections::BTreeSet;
use std::sync::{Arc, Mutex, PoisonError};

use slopdesk_hostsession::StatusObserver;
use slopdesk_ids::uuid_text;
use slopdesk_muxsession::open_route::{Survivor, SurvivorFacts, survivor};
use slopdesk_muxsession::registry::{Key, Uuid};
use slopdesk_superwire::protocol::PaneRecord;

use crate::channel::Restored;
use crate::host::{Fan, Host};

/// What superd is holding, as the adoption ladder asks about it.
///
/// Two questions, which is all the ladder has: is the link up, and what is running. Narrow on
/// purpose — a seam that could reach the whole supervisor client would let the ladder `release`,
/// `signal` and `subscribe`, none of which is adoption's.
pub trait Survivors: Send + Sync + fmt::Debug {
    /// Whether the supervisor link is up. A ladder with no link adopts nothing and says nothing:
    /// there is no list to be wrong about.
    fn is_connected(&self) -> bool;

    /// Every pane superd is supervising right now.
    ///
    /// # Errors
    /// The message superd or the socket gave, verbatim — logged, never acted on. A list that could
    /// not be read is not an empty list, and treating it as one would relinquish the notes for
    /// panes that are still there.
    fn list(&self) -> Result<Vec<PaneRecord>, String>;
}

/// A supervisor that is not there, so is holding nothing.
#[derive(Debug, Clone, Copy)]
pub struct NoSurvivors;

impl Survivors for NoSurvivors {
    fn is_connected(&self) -> bool {
        false
    }

    fn list(&self) -> Result<Vec<PaneRecord>, String> {
        Ok(Vec::new())
    }
}

/// The panes THIS process let go, so it can tell its own shells from a stranger's.
///
/// See the module header for why the set exists at all, and why it is injected rather than owned.
/// Everything here is one lock hold over a `BTreeSet<String>`; the set holds one entry per pane
/// this process has ever released, and [`LetGo::prune`] is what keeps that from being "ever" in a
/// menu-bar host that stops and starts all day.
#[derive(Debug, Default)]
pub struct LetGo {
    notes: Mutex<BTreeSet<String>>,
}

impl LetGo {
    /// An empty set — a process that has released nothing yet.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records panes this process is about to release. Called at the TOP of the stop order, before
    /// the maps are drained — after that there is nothing left to enumerate.
    pub fn note(&self, pane_ids: impl IntoIterator<Item = String>) {
        let mut notes = self.notes.lock().unwrap_or_else(PoisonError::into_inner);
        notes.extend(pane_ids);
    }

    /// Whether an attached pane is one this process left behind.
    ///
    /// A PURE question. Spending the note here — which is what the Swift did before it was a bug —
    /// spends the only authorisation the pane will ever get on an ATTEMPT: an adoption that failed
    /// halfway then left the pane in no map and no store with its note gone, while superd still
    /// reported it attached. [`LetGo::spend`] is what consumes a note, and only success calls it.
    #[must_use]
    pub fn holds(&self, pane_id: &str) -> bool {
        self.notes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(pane_id)
    }

    /// Consumes the note for a pane this process has taken back.
    pub fn spend(&self, pane_id: &str) {
        let _spent = self
            .notes
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(pane_id);
    }

    /// Drops every note for a pane superd did not list. Those shells are gone; the note is not
    /// authorising anything any more, and without this the set grows for the life of the process.
    pub fn prune(&self, live: &BTreeSet<String>) {
        let mut notes = self.notes.lock().unwrap_or_else(PoisonError::into_inner);
        notes.retain(|pane_id| live.contains(pane_id));
    }

    /// How many notes are outstanding — what a suite watches instead of guessing.
    #[must_use]
    pub fn len(&self) -> usize {
        self.notes.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Whether no note is outstanding.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// One surviving shell, fully resolved — the master not taken back yet.
///
/// [`Fresh`](crate::Fresh)'s sibling for the other way a hostd comes to hold a pane, and the two
/// differ in exactly what the difference is about: there are no client lanes here. Nobody has
/// opened a channel on this pane, and nobody may have for hours — the spawner wires inert ones and
/// a later reattach supplies the real pair.
#[derive(Debug)]
pub struct Adopted<'a> {
    /// The conversation this pane is already known by. Its journal is filed under it.
    pub session: Uuid,
    /// superd's own name for the pane, which is the string its `adopt` verb takes.
    pub pane_id: &'a str,
    /// Whether superd segments this pane into command blocks.
    pub blocks: bool,
    /// The pane's transcript from BEFORE the restart.
    ///
    /// Required, not an optimisation: a reattach replays the SESSION's buffers, and an adopted
    /// session's buffers start empty. Without this the user reconnects to a live shell showing a
    /// blank pane, which looks exactly like having lost the work.
    pub restored: Option<Restored>,
    /// Where the supervised stream is subscribed from. See
    /// [`Transcripts::position`](crate::Transcripts).
    pub resume_from: u64,
    /// Who hears the agent inside it move.
    pub status: Arc<dyn StatusObserver>,
}

impl Host {
    /// Takes back every surviving pane that is this daemon's, and parks each one.
    ///
    /// The whole start-up half. Four buckets come out of the list and only the first is acted on;
    /// the other three are named in the log, because "not adopted" covers three different futures
    /// and an operator deciding whether to `slopdesk-ctl` something needs to know which.
    pub fn adopt_survivors(self: &Arc<Self>) {
        if !self.survivors().is_connected() {
            return;
        }
        if self.detached().is_none() {
            // Detach off ⇒ nowhere to park, and a pane with no home would be invisible to every
            // enumeration. Report it rather than adopting into a void.
            self.report_unclaimed("detach is disabled on this hostd");
            return;
        }
        let records = match self.survivors().list() {
            Ok(records) => records,
            Err(why) => {
                self.observer().log(&format!(
                    "supervisor: could not list surviving panes ({why}) — none adopted"
                ));
                return;
            },
        };
        // Spent here rather than accumulating for the life of a menu-bar host that stops and
        // starts many times. Before the emptiness check, because a superd holding NOTHING is
        // precisely when every outstanding note is stale.
        self.let_go()
            .prune(&records.iter().map(|record| record.pane_id.clone()).collect());
        if records.is_empty() {
            return;
        }

        let mut adopted = 0_usize;
        let mut foreign: Vec<&str> = Vec::new();
        let mut services: Vec<&str> = Vec::new();
        let mut held: Vec<&str> = Vec::new();
        for record in &records {
            let facts = SurvivorFacts {
                pane_id: &record.pane_id,
                owner: record.owner.as_deref().unwrap_or_default(),
                attached: record.attached,
                relinquished_here: self.let_go().holds(&record.pane_id),
            };
            match survivor(&facts, self.owner()) {
                Survivor::Service(name) => services.push(name),
                Survivor::Foreign => foreign.push(&record.pane_id),
                Survivor::HeldElsewhere => held.push(&record.pane_id),
                Survivor::Adopt(session) => {
                    if self.adopt_one(record, session) {
                        adopted += 1;
                        // Spent only NOW. A refusal leaves the note in place so the next `start()`
                        // in this process can try again, rather than reading its own pane as a
                        // stranger's for ever.
                        self.let_go().spend(&record.pane_id);
                    }
                },
            }
        }
        self.report_adoption(adopted, &services, &held, &foreign);
    }

    /// One pane's adoption: take the master back, rebuild the session, park it. Answers whether it
    /// landed.
    ///
    /// The ORDER is [`Host::spawn_fresh`](crate::Host::open_channel)'s, minus the ack nobody is
    /// waiting for: adopt, start, seed, route, park. The start has to run — the shell is alive and
    /// its output must keep reaching the journal and the detector while nobody is watching, which
    /// is exactly the state a detached pane is already in.
    fn adopt_one(self: &Arc<Self>, record: &PaneRecord, session: Uuid) -> bool {
        let position = self.transcripts().position(session);
        if position.unpositioned {
            self.observer().log(&format!(
                "supervisor: pane {} has a stored transcript but superd holds no position in its stream — \
                 resuming from now, so nothing is shown twice",
                record.pane_id
            ));
        }
        let fan = Arc::new(Fan::unaimed(self.weak()));
        let taken = self.spawner().adopt(Adopted {
            session,
            pane_id: &record.pane_id,
            blocks: self.blocks_enabled(),
            restored: self.transcripts().restore(session),
            resume_from: position.offset,
            status: Arc::<Fan>::clone(&fan),
        });
        let pane = match taken {
            Ok(pane) => pane,
            Err(refused) => {
                self.observer().log(&format!(
                    "supervisor: pane {} (pid {}) not adopted: {}",
                    record.pane_id, record.pid, refused.0
                ));
                return false;
            },
        };
        fan.aim(&pane);
        pane.start();
        if let Some(cwd) = record.cwd.as_deref()
            && !cwd.is_empty()
        {
            pane.seed_project(cwd);
        }
        self.register_hook(&pane);
        // A SYNTHETIC key: the store needs one, and no connection owns this pane yet. A minted id
        // rather than a fixed one, so two adopted panes cannot collide on it, and channel 0 —
        // never a real client channel — is what makes an adopted-but-never-reattached pane obvious
        // in a log line rather than looking like a channel that went wrong.
        let key = Key {
            connection: self.mint_id().unwrap_or(session),
            channel: 0,
        };
        self.park(key, &pane);
        true
    }

    /// Names the panes superd is holding that this hostd is not going to take, so an operator can
    /// see them. Called when adoption cannot run AT ALL.
    fn report_unclaimed(&self, reason: &str) {
        let Ok(records) = self.survivors().list() else {
            return;
        };
        // Panel backends are counted out: they are not unadopted, they are adopted elsewhere and
        // later, and telling an operator to `slopdesk-ctl` them would be advice to kill the editor.
        let shells = records
            .iter()
            .filter(|record| !matches!(survivor(&unowned(record), self.owner()), Survivor::Service(_)))
            .count();
        if shells == 0 {
            return;
        }
        self.observer().log(&format!(
            "supervisor: {shells} supervised pane(s) left running and unadopted ({reason}) — their shells \
             are alive; `slopdesk-ctl` can end them deliberately",
        ));
    }

    /// The four lines one adoption round can produce, in the order an operator reads them.
    fn report_adoption(&self, adopted: usize, services: &[&str], held: &[&str], foreign: &[&str]) {
        if adopted > 0 {
            self.observer().log(&format!(
                "supervisor: adopted {adopted} surviving pane(s) — their shells ran straight through this \
                 restart and are parked for reattach",
            ));
        }
        if !services.is_empty() {
            self.observer().log(&format!(
                "supervisor: panel backend(s) ran straight through this restart and will be adopted on \
                 first use: {}",
                services.join(", ")
            ));
        }
        if !held.is_empty() {
            self.observer().log(&format!(
                "supervisor: {} supervised pane(s) are attached to another live hostd and were left alone: \
                 {}",
                held.len(),
                held.join(", ")
            ));
        }
        if !foreign.is_empty() {
            self.observer().log(&format!(
                "supervisor: {} supervised pane(s) are not ours and were left running: {}",
                foreign.len(),
                foreign.join(", ")
            ));
        }
    }

    /// Records every pane this host is about to let go, so the NEXT `start()` in this process can
    /// tell them from a stranger's.
    ///
    /// Called at the top of the stop order — D.6.5's — because after the drains there is nothing
    /// left to enumerate. Both halves: the panes with a live client and the ones already parked.
    pub fn note_panes_let_go(&self) {
        let live = {
            let sessions = self.sessions();
            let mut panes = sessions.live_panes();
            panes.extend(sessions.control_panes());
            panes
        };
        let parked = self.detached().map(|store| store.all()).unwrap_or_default();
        self.let_go()
            .note(live.iter().chain(parked.iter()).map(|pane| uuid_text(pane.id())));
    }
}

/// A record read for its ID ALONE — the shape [`Host::report_unclaimed`] needs, where ownership and
/// attachment have already been decided by the fact that adoption is not running.
fn unowned(record: &PaneRecord) -> SurvivorFacts<'_> {
    SurvivorFacts {
        pane_id: &record.pane_id,
        owner: "",
        attached: false,
        relinquished_here: false,
    }
}

/// How superd records which hostd spawned a pane.
///
/// Pure, so a test can pin the shape without a server. The state directory is part of it because
/// two hostds on one machine are told apart by their state scope as much as by their port — a
/// second daemon on a second scope is a different owner, and its panes are a stranger's.
#[must_use]
pub fn owner_identity(port: u16, state_dir: Option<&str>) -> String {
    let scope = state_dir.filter(|dir| !dir.is_empty()).unwrap_or("default");
    format!("hostd port={port} state={scope}")
}
