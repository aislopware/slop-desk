//! The session table: [`slopdesk_muxsession::registry::Registry`] plus the objects it names.
//!
//! ## What was left of `HostSessionRegistry` once the caller became Rust
//!
//! Four hundred lines of Swift, and the audit in `docs/60` D.0 said what most of it was: buffer
//! marshalling. Every door that answers a LIST answered it into a `withUnsafeTemporaryAllocation`
//! sized by a first call and filled by a second, and every key crossed as a flattened struct that
//! had to be built going in and unpacked coming back. None of that is a decision, and none of it
//! survives a caller that can hold a `Vec<Key>`. What DOES survive is the one thing the far side
//! never had: the objects.
//!
//! ## Why it holds no lock
//!
//! Deliberately, and the Swift said so too — "not `Sendable` and deliberately unlocked:
//! `HostServer` calls every method with its `lock` held". That is load-bearing rather than lazy.
//! The join and reattach ladders mutate the registry AND the object maps and must be indivisible
//! across both; a lock in here would make the server either nest two locks on every ladder or go
//! back to the TOCTOU it took the ladder to close. So this is a plain `&mut self` type, D.6 puts it
//! inside the server's one mutex, and this crate's suite drives it directly.
//!
//! ## Why the maps are here and not there
//!
//! A dictionary keyed by an id this side already has is not a relation — it is the retention
//! itself. The registry answers WHICH pane; only an owner of `Arc`s can answer with the pane.

use std::collections::HashMap;
use std::sync::Arc;

use slopdesk_muxsession::registry::{Key, NO_SLOT, PRIMARY_SUBSCRIBER, Registry, Slot, Subscriber, Uuid};

use crate::pane::Pane;

/// One registered channel, resolved back to the pane it names.
#[derive(Debug, Clone)]
pub struct Held {
    /// The channel.
    pub key: Key,
    /// Which subscriber of the pane this channel is.
    pub subscriber: Subscriber,
    /// The pane it names.
    pub pane: Arc<dyn Pane>,
}

/// Every live pane hostd holds, on a channel or standing alone.
#[derive(Debug, Default)]
pub struct Sessions {
    /// The far side, which owns every relation.
    registry: Registry,
    /// slot → the pane it names, for panes on a channel.
    panes: HashMap<Slot, Arc<dyn Pane>>,
    /// slot → the pane it names, for standalone `ctl`-spawned panes.
    controls: HashMap<Slot, Arc<dyn Pane>>,
}

impl Sessions {
    /// An empty table.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    // ---------------------------------------------------------------- live panes

    /// The pane `key` names, or `None` when the key is not registered.
    #[must_use]
    pub fn pane(&self, key: Key) -> Option<&Arc<dyn Pane>> {
        self.resolve(self.registry.slot(key))
    }

    /// Which subscriber of its pane `key` is.
    ///
    /// An unregistered key reads as the primary, which is what every caller that reaches this
    /// without a pane does with the answer anyway.
    #[must_use]
    pub fn subscriber_of(&self, key: Key) -> Subscriber {
        self.registry
            .member(key)
            .map_or(PRIMARY_SUBSCRIBER, |member| member.subscriber)
    }

    /// Registers `key` as `subscriber` of `pane`.
    pub fn attach(&mut self, key: Key, pane: &Arc<dyn Pane>, subscriber: Subscriber) {
        let slot = pane.slot();
        self.panes.insert(slot, Arc::clone(pane));
        self.registry.attach(key, slot, pane.id(), subscriber);
    }

    /// Registers `key` as the pane's ORIGINAL channel.
    pub fn attach_primary(&mut self, key: Key, pane: &Arc<dyn Pane>) {
        self.attach(key, pane, PRIMARY_SUBSCRIBER);
    }

    /// Removes exactly one member — the leaving client, not the pane — and answers the pane it
    /// named. The object is released here only when its LAST channel is gone.
    pub fn detach(&mut self, key: Key) -> Option<Arc<dyn Pane>> {
        let member = self.registry.detach_key(key)?;
        let pane = self.panes.get(&member.slot).map(Arc::clone);
        self.release_if_unattached(member.slot);
        pane
    }

    /// Removes `key` only while it still names `pane`, and answers whether it did.
    ///
    /// The identity guard. The detach window can mint a fresh pane under an id its predecessor is
    /// still winding down on, and an unguarded removal unregisters the LIVE successor.
    pub fn detach_if_names(&mut self, key: Key, pane: &Arc<dyn Pane>) -> bool {
        let slot = pane.slot();
        let removed = self.registry.detach_key_if_slot(key, slot);
        if removed {
            self.release_if_unattached(slot);
        }
        removed
    }

    /// Every key that names `pane`, in key order.
    #[must_use]
    pub fn keys_naming(&self, pane: &Arc<dyn Pane>) -> Vec<Key> {
        self.registry.keys_for_slot(pane.slot())
    }

    /// Removes EVERY key that names `pane` — the reap — and answers them.
    ///
    /// Leaving an alias behind keeps a dead pane in every enumeration hostd has: the ctl listing,
    /// the stop drain, the rebind scan.
    pub fn reap(&mut self, pane: &Arc<dyn Pane>) -> Vec<Key> {
        let slot = pane.slot();
        let doomed = self.registry.detach_slot(slot);
        self.panes.remove(&slot);
        doomed
    }

    /// Whether `pane` is still named by any channel.
    #[must_use]
    pub fn is_attached(&self, pane: &Arc<dyn Pane>) -> bool {
        self.registry.slot_is_attached(pane.slot())
    }

    /// Every member riding `connection`, in key order.
    #[must_use]
    pub fn members_on(&self, connection: Uuid) -> Vec<Held> {
        self.hold(self.registry.members_for_connection(connection))
    }

    /// Removes every member riding `connection` — the link-drop snapshot — and answers them.
    ///
    /// The removal lands BEFORE the caller retires anything, so a racing `channelOpen` cannot find
    /// a member of a connection that is already gone.
    pub fn detach_all_on(&mut self, connection: Uuid) -> Vec<Held> {
        let removed = self.registry.detach_connection(connection);
        let leaving = self.hold(removed);
        for member in &leaving {
            self.release_if_unattached(member.pane.slot());
        }
        leaving
    }

    /// Every member, in key order — the roster's join from a subscriber back to its connection.
    #[must_use]
    pub fn members(&self) -> Vec<Held> {
        self.hold(self.registry.members())
    }

    /// Every DISTINCT pane on a channel.
    ///
    /// A fanned-out pane is N members and ONE pane: an enumeration that repeated it would shut the
    /// same PTY N times and fan N teardowns against a strictly-balanced prevent-sleep counter.
    #[must_use]
    pub fn live_panes(&self) -> Vec<Arc<dyn Pane>> {
        self.registry
            .slots()
            .iter()
            .filter_map(|slot| self.panes.get(slot).map(Arc::clone))
            .collect()
    }

    /// How many CHANNELS are registered — one per watching client, not one per pane.
    #[must_use]
    pub fn member_count(&self) -> usize {
        self.registry.members().len()
    }

    /// How many distinct CONNECTIONS hold at least one pane — the "N client(s) connected" count.
    #[must_use]
    pub fn connection_count(&self) -> usize {
        self.registry.connection_count()
    }

    /// The channel key one SUBSCRIBER of `pane` rides, if it is registered.
    #[must_use]
    pub fn key_of(&self, pane: &Arc<dyn Pane>, subscriber: Subscriber) -> Option<Key> {
        self.registry.key_for(pane.slot(), subscriber)
    }

    /// The live pane serving `session` under some OTHER key — the join question.
    #[must_use]
    pub fn pane_elsewhere(&self, session: Uuid, excluding: Key) -> Option<&Arc<dyn Pane>> {
        self.resolve(self.registry.slot_elsewhere(session, excluding))
    }

    /// The live pane serving `session` from any channel.
    #[must_use]
    pub fn pane_for_session(&self, session: Uuid) -> Option<&Arc<dyn Pane>> {
        self.resolve(self.registry.slot_for_session(session))
    }

    /// Empties the channel map and answers every distinct pane that was in it — the stop drain.
    pub fn drain_panes(&mut self) -> Vec<Arc<dyn Pane>> {
        let live = self.registry.drain_panes();
        let panes = live
            .iter()
            .filter_map(|slot| self.panes.get(slot).map(Arc::clone))
            .collect();
        self.panes.clear();
        panes
    }

    // ------------------------------------------------------ standalone control panes

    /// Registers a `ctl`-spawned pane, which holds no channel and no connection.
    pub fn attach_control(&mut self, pane: &Arc<dyn Pane>) {
        let slot = pane.slot();
        self.controls.insert(slot, Arc::clone(pane));
        self.registry.attach_control(pane.id(), slot);
    }

    /// The standalone pane serving `session`, if any.
    #[must_use]
    pub fn control_pane(&self, session: Uuid) -> Option<&Arc<dyn Pane>> {
        let slot = self.registry.control_slot(session);
        if slot == NO_SLOT {
            None
        } else {
            self.controls.get(&slot)
        }
    }

    /// Removes the standalone pane serving `session` and answers it. Idempotent.
    pub fn detach_control(&mut self, session: Uuid) -> Option<Arc<dyn Pane>> {
        let slot = self.registry.detach_control(session);
        if slot == NO_SLOT {
            None
        } else {
            self.controls.remove(&slot)
        }
    }

    /// Every standalone pane.
    #[must_use]
    pub fn control_panes(&self) -> Vec<Arc<dyn Pane>> {
        self.registry
            .control_slots()
            .iter()
            .filter_map(|slot| self.controls.get(slot).map(Arc::clone))
            .collect()
    }

    /// Empties the standalone map and answers what was in it.
    pub fn drain_control(&mut self) -> Vec<Arc<dyn Pane>> {
        let live = self.registry.drain_control();
        let panes = live
            .iter()
            .filter_map(|slot| self.controls.get(slot).map(Arc::clone))
            .collect();
        self.controls.clear();
        panes
    }

    // ------------------------------------------------------------- agent-hook sinks

    /// Records where `pane`'s agent hooks route.
    ///
    /// The owner is the pane's own object identity, so the teardown guard and every other identity
    /// question read the same number.
    pub fn register_hook(&mut self, pane: &Arc<dyn Pane>, pane_id: &str) {
        self.registry
            .register_hook(pane.id(), pane_id.as_bytes(), pane.slot());
    }

    /// Re-points `pane`'s sink at the current object without moving where it routes — the reattach
    /// edge — and answers the pane id, or `None` when hooks were off at spawn.
    ///
    /// The pane id is the one baked into the child's environment and is immutable for the shell's
    /// life: a per-reattach key could never route AND would leak one dead sink per wifi flap.
    pub fn rebind_hook(&mut self, pane: &Arc<dyn Pane>) -> Option<String> {
        let session = pane.id();
        if !self.registry.rebind_hook(session, pane.slot()) {
            return None;
        }
        // Lossless by construction: the only writer is `register_hook`, which takes a `&str`.
        self.registry
            .hook_pane(session)
            .and_then(|bytes| core::str::from_utf8(bytes).ok())
            .map(str::to_owned)
    }

    /// Removes `pane`'s sink while it still owns it, and answers the pane id it routed to.
    ///
    /// `None` for an entry owned by somebody else: a stale teardown for a same-id ghost stands down
    /// rather than dropping the key its live successor just registered.
    pub fn unregister_hook(&mut self, pane: &Arc<dyn Pane>) -> Option<String> {
        self.registry
            .unregister_hook(pane.id(), pane.slot())
            .and_then(|bytes| String::from_utf8(bytes).ok())
    }

    /// Where `session`'s hooks route, without touching the entry.
    #[must_use]
    pub fn hook_pane(&self, session: Uuid) -> Option<&str> {
        self.registry
            .hook_pane(session)
            .and_then(|bytes| core::str::from_utf8(bytes).ok())
    }

    /// How many hook sinks are registered — the leak check a per-reattach key would fail.
    #[must_use]
    pub fn hook_count(&self) -> usize {
        self.registry.hook_count()
    }

    // ------------------------------------------------------------ project document ids

    /// The document object id for `path`, taking `candidate` the first time the path is seen.
    ///
    /// `candidate` is minted by the caller and DISCARDED for a path that already has one, which is
    /// the shape the far side wants: minting is the caller's, deciding is the registry's.
    pub fn project_id(&mut self, path: &str, candidate: Uuid) -> Uuid {
        self.registry.project_id(path.as_bytes(), candidate)
    }

    /// How many projects have an id.
    #[must_use]
    pub fn project_count(&self) -> usize {
        self.registry.project_count()
    }

    // -------------------------------------------------------------------- internals

    /// A slot, resolved back to the pane it names. [`NO_SLOT`] answers `None` without a lookup.
    fn resolve(&self, slot: Slot) -> Option<&Arc<dyn Pane>> {
        if slot == NO_SLOT {
            None
        } else {
            self.panes.get(&slot)
        }
    }

    /// Drops the object when its last channel is gone, and holds it while any remains.
    fn release_if_unattached(&mut self, slot: Slot) {
        if !self.registry.slot_is_attached(slot) {
            self.panes.remove(&slot);
        }
    }

    /// Members, each resolved back to the object it names. A member whose object has already been
    /// released is skipped rather than faked.
    fn hold(&self, members: Vec<slopdesk_muxsession::registry::Member>) -> Vec<Held> {
        members
            .into_iter()
            .filter_map(|member| {
                self.panes.get(&member.slot).map(|pane| {
                    Held {
                        key: member.key,
                        subscriber: member.subscriber,
                        pane: Arc::clone(pane),
                    }
                })
            })
            .collect()
    }
}
