//! The pane inventory the workspace document is derived FROM, over the server's live tables.
//!
//! [`crate::workspace::Panes`] asks four questions and this is where the host answers them. Two are
//! already [`Host`]'s own — the reap is [`Host::reap_panes`] and the passivity re-decision is
//! [`Host::resolve_size_passivity`], both landed with the ending ladders — so what is here is the
//! two READS.
//!
//! ## The three inventories, and why they are asked as three
//!
//! A pane is in exactly one of them: on a channel (`live_panes`), standing alone because ctl
//! spawned it (`control_panes`), or parked in the detached store. They are disjoint by
//! CONSTRUCTION — a detach removes from the registry before inserting into the store, and a claim
//! removes before the reattach re-registers — which is the same argument `list-panes` relies on, so
//! walking all three cannot double-count.
//!
//! What the split decides is the LIVENESS byte, and it is the one fact a pane cannot supply about
//! itself: whether anybody is holding it lives in a table it cannot see. A ctl-spawned or parked
//! pane is `detached` in exactly the sense the client renders — live, running, nobody watching —
//! and calling it `attached` would claim a viewer that does not exist. An exited child is `dead`
//! wherever it is filed.
//!
//! ## A full sweep, not a per-fact push
//!
//! Deliberately, and `crate::workspace::Panes::capture` says why: the facts arrive from at least
//! five independent producers, and wiring each one separately is how a fact goes missing — the bug
//! the document exists to end. A sweep is one lock acquisition per pane (see
//! [`crate::pane::Pane::latches`]) and is cheap enough to run on every tick.
//!
//! ## Both reads copy the panes out under the lock and ask them AFTERWARDS
//!
//! `Sessions` is behind the server's one mutex, and a pane's own readers take the pane's locks. A
//! sweep that asked a pane while still holding the server's would nest the two in an order nothing
//! else uses — and the ORDER is the whole reason there is a rule: the eviction ladder already takes
//! a pane's lock and then the server's. Copying the `Arc`s out first makes the nesting impossible
//! rather than merely unlikely.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use slopdesk_muxsession::registry::{Slot, Subscriber, Uuid};
use slopdesk_wire::document::fields::PaneLivenessState;
use slopdesk_wire::document::liveness::PaneLiveness;
use slopdesk_wire::workspace::WorkspaceRosterPane;

use crate::capture::{liveness_record, roster_record, sort_roster};
use crate::host::Host;
use crate::pane::Pane;
use crate::workspace::Panes;

/// The three tables as two lists: the panes a client is holding, and the panes nobody is.
type Inventories = (Vec<Arc<dyn Pane>>, Vec<Arc<dyn Pane>>);

/// One pane read into a record, at the liveness its inventory decided.
///
/// An exited child is `Dead` wherever it is filed — the store's parked pane and the channel's
/// attached one alike — because the byte describes the PROCESS, and the process is over.
fn record(pane: &Arc<dyn Pane>, alive: PaneLivenessState) -> PaneLiveness {
    let liveness = if pane.is_child_exited() {
        PaneLivenessState::Dead
    } else {
        alive
    };
    liveness_record(pane.id(), liveness, &pane.latches(), pane.window_size())
}

impl Panes for Host {
    fn capture(&self) -> Vec<PaneLiveness> {
        let (attached, unattached) = self.inventories();
        let mut records = Vec::with_capacity(attached.len() + unattached.len());
        records.extend(
            attached
                .iter()
                .map(|pane| record(pane, PaneLivenessState::Attached)),
        );
        records.extend(
            unattached
                .iter()
                .map(|pane| record(pane, PaneLivenessState::Detached)),
        );
        records
    }

    fn roster(&self) -> Vec<WorkspaceRosterPane> {
        let (attached, unattached) = self.inventories();
        let holders = self.holders();
        let workspace = self.workspace();
        let mut records = Vec::with_capacity(attached.len() + unattached.len());
        for pane in &attached {
            let (resolved, attachments) = pane.attachments();
            let held = holders.get(&pane.slot());
            records.push(roster_record(pane.id(), resolved, &attachments, |subscriber| {
                held.and_then(|held| held.get(&subscriber))
                    .and_then(|connection| workspace.client_instance(*connection))
            }));
        }
        // A ctl-spawned or parked pane has ZERO attachments by construction — nobody is watching
        // it. It keeps its last resolved size (`docs/45` §8.3 rule 4), and the empty list is what
        // says so; dropping the row instead would make the pane look unsized rather than unheld.
        for pane in &unattached {
            let (resolved, _) = pane.attachments();
            records.push(roster_record(pane.id(), resolved, &[], |_| None));
        }
        sort_roster(&mut records);
        records
    }

    fn reap(&self, gone: &BTreeSet<Uuid>) {
        self.reap_panes(gone);
    }

    fn resolve_size_passivity(&self, connection: Uuid, passive: bool) {
        // The INHERENT one, which shares this name: a path resolves to the inherent method before
        // the trait's, so this delegates rather than recurses. `tests/panes.rs` asserts the
        // difference by watching the passivity reach a pane's own fold — a recursion would blow the
        // stack instead, which is a failure mode worth having a test rather than a comment.
        Self::resolve_size_passivity(self, connection, passive);
    }
}

impl Host {
    /// The three inventories as two lists: the panes a client is holding, and the panes nobody is.
    ///
    /// The store is read OUTSIDE the server's lock. It takes its own, and the nesting contract runs
    /// one way — the same discipline every other ladder in this crate keeps.
    fn inventories(&self) -> Inventories {
        let (attached, control) = {
            let sessions = self.sessions();
            (sessions.live_panes(), sessions.control_panes())
        };
        let parked = self.detached().map(|store| store.all()).unwrap_or_default();
        let mut unattached = control;
        unattached.extend(parked);
        (attached, unattached)
    }

    /// Which CONNECTION each of a pane's members rides, by pane and then by member.
    ///
    /// Keyed by [`Pane::slot`] rather than by session id, because the id is the CONVERSATION's name
    /// and outlives the pane: during a detach window a fresh pane can be minted under an id its
    /// predecessor is still winding down on, and a table keyed by that id would name both.
    ///
    /// ONE entry per member, so a fanned-out pane publishes one row with one attachment per
    /// watching device rather than N duplicate rows the receiver's diff would read as churn.
    fn holders(&self) -> BTreeMap<Slot, BTreeMap<Subscriber, Uuid>> {
        let mut holders: BTreeMap<Slot, BTreeMap<Subscriber, Uuid>> = BTreeMap::new();
        // Bound before the loop, so the server's lock is RELEASED before a single pane is asked
        // anything — the nesting this module's header is about.
        let members = self.sessions().members();
        for held in members {
            holders
                .entry(held.pane.slot())
                .or_default()
                .insert(held.subscriber, held.key.connection);
        }
        holders
    }
}
