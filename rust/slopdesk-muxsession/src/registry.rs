//! Which channel names which pane, who is holding it there, and what a reap takes with it.
//!
//! One pane is one `MuxChannelSession` object, but a FANNED-OUT pane is that one object under N
//! channel keys — one per watching client. Every per-client event (a link drop, a peer
//! `channelClose`, a laggard eviction) concerns exactly ONE of those members, while every
//! end-of-life (a topology delete, a `ctl kill`, a deliberate close) concerns ALL of them. Getting
//! that split wrong is not a crash: leaving an alias behind keeps a dead pane in every enumeration,
//! and reaping too eagerly takes down the OTHER client's running agent.
//!
//! Hostd used to spell the split as two dictionaries written in one critical section — a
//! key→session map and a key→subscriber map, where "no subscriber entry" MEANT the pane's original
//! channel. Two maps that must agree are one invariant nobody can state; here a member is ONE
//! record, so a key either names a pane with a subscriber or does not exist.
//!
//! Object identity crosses as a SLOT: a `u64` minted per session object and carried by it for its
//! whole life. Every identity-guarded action hostd spells with `===` — "remove this key only if it
//! still names THIS session", "is this session still attached anywhere" — is a question about
//! slots, and asking it here is what keeps the answer in one place. The objects themselves stay in
//! hostd, which is the one thing that cannot cross.
//!
//! The maps are ordered, so a drain, a reap and a roster all walk in the same order on every run;
//! the Swift dictionaries they replace had no order at all.

use std::collections::BTreeMap;

/// A UUID in its own byte order — the wire's and the document's, so a sort by id agrees with both.
pub type Uuid = [u8; 16];

/// A session object's identity, minted once per object and stable for its life. Never zero for a
/// live session: [`NO_SLOT`] is the "no such pane" answer a door can return by value.
pub type Slot = u64;

/// Which subscriber of a fanned-out pane a member is.
pub type Subscriber = u64;

/// The answer for "no pane". A minted slot starts at one, so zero can never name a session.
pub const NO_SLOT: Slot = 0;

/// A fresh session identity, unique for the life of the process and never [`NO_SLOT`].
///
/// The counter lives HERE rather than beside either caller, because there are two of them and they
/// mint into the same table: the C door hostd's Swift reaches through today, and
/// `slopdesk-hostserver` once it is the one holding the registry. Two counters would hand two live
/// panes the same number, and every identity guard in this module reads that number as `===`.
///
/// Monotonic and never zero: a wrap would need a daemon to mint one session per nanosecond for five
/// centuries.
#[must_use]
pub fn mint_slot() -> Slot {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// The pane's ORIGINAL channel — the subscriber every un-joined member rides.
///
/// Mirrors `MuxChannelSession.primarySubscriberID`. Recorded EXPLICITLY on every member: the map it
/// replaces stored it by absence, which made "the key is not registered yet" and "the key is the
/// primary" the same reading of the same missing entry.
pub const PRIMARY_SUBSCRIBER: Subscriber = 0;

/// One client's channel: the connection it rides and the channel id that connection allocated.
///
/// The connection half is not decoration. Every connection allocates channel 1 for its first pane,
/// so a channel-only key let connection B's open OVERWRITE connection A's live session and let A's
/// close shut B's pane down.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Key {
    /// The client connection this channel rides.
    pub connection: Uuid,
    /// The channel id, allocated per connection from 1.
    pub channel: u32,
}

impl Key {
    /// A key naming `channel` on `connection`.
    #[must_use]
    pub const fn new(connection: Uuid, channel: u32) -> Self {
        Self { connection, channel }
    }
}

/// A registered channel: the key, the pane it names, and which subscriber of that pane it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Member {
    /// The channel.
    pub key: Key,
    /// The pane object the channel names.
    pub slot: Slot,
    /// Which subscriber of that pane this member is.
    pub subscriber: Subscriber,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Pane {
    slot: Slot,
    session: Uuid,
    subscriber: Subscriber,
}

/// One session's agent-hook routing entry.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Hook {
    pane: Vec<u8>,
    owner: u64,
}

/// Every relation hostd keeps about live panes: channel→pane, pane→session, session→hook sink, and
/// project path→document id.
///
/// Holds ids and nothing else. The session objects, the connections and the workspace channels stay
/// in hostd — this answers WHICH of them an event concerns.
#[derive(Debug, Default)]
pub struct Registry {
    panes: BTreeMap<Key, Pane>,
    control: BTreeMap<Uuid, Slot>,
    hooks: BTreeMap<Uuid, Hook>,
    projects: BTreeMap<Vec<u8>, Uuid>,
}

impl Registry {
    /// An empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    // MARK: - Live panes

    /// Registers `key` as a member of the pane at `slot`.
    ///
    /// Overwrites any previous record for the key: a re-open of a channel id a client already used
    /// is the client's own reuse of its keyspace, and the caller has already decided whose pane
    /// wins (`open_route`). One record means the subscriber can never lag the registration.
    pub fn attach(&mut self, key: Key, slot: Slot, session: Uuid, subscriber: Subscriber) {
        self.panes.insert(key, Pane {
            slot,
            session,
            subscriber,
        });
    }

    /// The member `key` names, if it is registered.
    #[must_use]
    pub fn member(&self, key: Key) -> Option<Member> {
        self.panes.get(&key).map(|pane| {
            Member {
                key,
                slot: pane.slot,
                subscriber: pane.subscriber,
            }
        })
    }

    /// The pane `key` names, if any.
    #[must_use]
    pub fn slot(&self, key: Key) -> Slot {
        self.panes.get(&key).map_or(NO_SLOT, |pane| pane.slot)
    }

    /// Removes exactly one member — the leaving client, not the pane.
    pub fn detach_key(&mut self, key: Key) -> Option<Member> {
        self.panes.remove(&key).map(|pane| {
            Member {
                key,
                slot: pane.slot,
                subscriber: pane.subscriber,
            }
        })
    }

    /// Removes `key` only while it still names `slot`.
    ///
    /// The identity guard hostd spelled `if muxSessions[key] === session`. The detach window can
    /// mint a fresh session under a key a predecessor is still winding down on, and an unguarded
    /// removal there unregisters the LIVE successor.
    pub fn detach_key_if_slot(&mut self, key: Key, slot: Slot) -> bool {
        if self.panes.get(&key).is_some_and(|pane| pane.slot == slot) {
            self.panes.remove(&key);
            return true;
        }
        false
    }

    /// Every key that names `slot`, in key order.
    #[must_use]
    pub fn keys_for_slot(&self, slot: Slot) -> Vec<Key> {
        self.panes
            .iter()
            .filter(|(_, pane)| pane.slot == slot)
            .map(|(key, _)| *key)
            .collect()
    }

    /// Removes EVERY key that names `slot`, and returns them.
    ///
    /// A reap takes all the aliases, not just the one that asked: leaving N−1 behind keeps a dead
    /// pane in every enumeration hostd has — the ctl listing, the stop drain, the rebind scan.
    pub fn detach_slot(&mut self, slot: Slot) -> Vec<Key> {
        let doomed = self.keys_for_slot(slot);
        for key in &doomed {
            self.panes.remove(key);
        }
        doomed
    }

    /// Whether any key still names `slot`.
    #[must_use]
    pub fn slot_is_attached(&self, slot: Slot) -> bool {
        self.panes.values().any(|pane| pane.slot == slot)
    }

    /// Every member riding `connection`, in key order.
    #[must_use]
    pub fn members_for_connection(&self, connection: Uuid) -> Vec<Member> {
        self.panes
            .iter()
            .filter(|(key, _)| key.connection == connection)
            .map(|(key, pane)| {
                Member {
                    key: *key,
                    slot: pane.slot,
                    subscriber: pane.subscriber,
                }
            })
            .collect()
    }

    /// Removes every member riding `connection` — the link-drop snapshot — and returns them.
    ///
    /// Removal happens BEFORE the caller retires anything, so a racing open cannot see a member of
    /// a connection that is already gone.
    pub fn detach_connection(&mut self, connection: Uuid) -> Vec<Member> {
        let leaving = self.members_for_connection(connection);
        for member in &leaving {
            self.panes.remove(&member.key);
        }
        leaving
    }

    /// Every member, in key order — the roster's join from a subscriber back to its connection.
    #[must_use]
    pub fn members(&self) -> Vec<Member> {
        self.panes
            .iter()
            .map(|(key, pane)| {
                Member {
                    key: *key,
                    slot: pane.slot,
                    subscriber: pane.subscriber,
                }
            })
            .collect()
    }

    /// Every distinct pane, in slot order.
    ///
    /// DEDUPED by construction: a fanned-out pane is N members and ONE slot, and an enumeration
    /// that returned it N times would shut the same PTY N times and fan N teardowns against a
    /// strictly-balanced prevent-sleep counter.
    #[must_use]
    pub fn slots(&self) -> Vec<Slot> {
        let mut slots: Vec<Slot> = self.panes.values().map(|pane| pane.slot).collect();
        slots.sort_unstable();
        slots.dedup();
        slots
    }

    /// How many distinct CONNECTIONS hold at least one pane — the "N client(s) connected" count.
    #[must_use]
    pub fn connection_count(&self) -> usize {
        let mut connections: Vec<Uuid> = self.panes.keys().map(|key| key.connection).collect();
        connections.sort_unstable();
        connections.dedup();
        connections.len()
    }

    /// The key one SUBSCRIBER of `slot` rides, if it is registered.
    #[must_use]
    pub fn key_for(&self, slot: Slot, subscriber: Subscriber) -> Option<Key> {
        self.panes
            .iter()
            .find(|(_, pane)| pane.slot == slot && pane.subscriber == subscriber)
            .map(|(key, _)| *key)
    }

    /// The pane serving `session` under some OTHER key, if one is live.
    ///
    /// This is the join question: a second client presenting a session id that is already open
    /// somewhere joins that pane rather than spawning a second shell under one id.
    #[must_use]
    pub fn slot_elsewhere(&self, session: Uuid, excluding: Key) -> Slot {
        self.panes
            .iter()
            .find(|(key, pane)| **key != excluding && pane.session == session)
            .map_or(NO_SLOT, |(_, pane)| pane.slot)
    }

    /// The live pane serving `session`, from any key.
    #[must_use]
    pub fn slot_for_session(&self, session: Uuid) -> Slot {
        self.panes
            .values()
            .find(|pane| pane.session == session)
            .map_or(NO_SLOT, |pane| pane.slot)
    }

    /// Empties the pane map and returns every distinct pane that was in it — the `stop()` drain.
    pub fn drain_panes(&mut self) -> Vec<Slot> {
        let live = self.slots();
        self.panes.clear();
        live
    }

    // MARK: - Control panes

    /// Registers a standalone `ctl`-spawned pane, which has no connection and no channel.
    pub fn attach_control(&mut self, session: Uuid, slot: Slot) {
        self.control.insert(session, slot);
    }

    /// The standalone pane serving `session`, if any.
    #[must_use]
    pub fn control_slot(&self, session: Uuid) -> Slot {
        self.control.get(&session).copied().unwrap_or(NO_SLOT)
    }

    /// Removes the standalone pane serving `session` and returns it.
    pub fn detach_control(&mut self, session: Uuid) -> Slot {
        self.control.remove(&session).unwrap_or(NO_SLOT)
    }

    /// Every standalone pane, in session order.
    #[must_use]
    pub fn control_slots(&self) -> Vec<Slot> {
        self.control.values().copied().collect()
    }

    /// Empties the standalone map and returns what was in it.
    pub fn drain_control(&mut self) -> Vec<Slot> {
        let live = self.control_slots();
        self.control.clear();
        live
    }

    // MARK: - Agent-hook sinks

    /// Records where `session`'s agent hooks route, and who registered it.
    ///
    /// Keyed by the session id and NOT by the channel: the pane id is exported once into the
    /// child's environment and is immutable for the shell's life, so the sink must survive
    /// every detach/reattach cycle the channel keys do not.
    pub fn register_hook(&mut self, session: Uuid, pane: &[u8], owner: u64) {
        self.hooks.insert(session, Hook {
            pane: pane.to_vec(),
            owner,
        });
    }

    /// The pane id `session`'s hooks route to, if one is registered.
    #[must_use]
    pub fn hook_pane(&self, session: Uuid) -> Option<&[u8]> {
        self.hooks.get(&session).map(|hook| hook.pane.as_slice())
    }

    /// Re-points `session`'s sink at `owner` without changing where it routes.
    ///
    /// A reattach mints a new session object for a pane id that is unchanged; the OWNER moves so
    /// the successor can retire the entry, and the pane id stays so the agent's already-tagged
    /// hook POSTs keep landing. Answers `false` when nothing was registered — there is no sink
    /// to move.
    pub fn rebind_hook(&mut self, session: Uuid, owner: u64) -> bool {
        match self.hooks.get_mut(&session) {
            Some(hook) => {
                hook.owner = owner;
                true
            },
            None => false,
        }
    }

    /// Removes `session`'s sink only while `owner` still holds it, and answers the pane id it
    /// routed to.
    ///
    /// The identity guard: a same-UUID predecessor winding down must never retire the entry its
    /// live successor just registered, or that pane's agent-status POSTs stop routing for the
    /// daemon's life with nothing failing.
    pub fn unregister_hook(&mut self, session: Uuid, owner: u64) -> Option<Vec<u8>> {
        if self.hooks.get(&session).is_some_and(|hook| hook.owner == owner) {
            return self.hooks.remove(&session).map(|hook| hook.pane);
        }
        None
    }

    /// How many sinks are registered — the leak check a per-cycle key would fail.
    #[must_use]
    pub fn hook_count(&self) -> usize {
        self.hooks.len()
    }

    // MARK: - Project document ids

    /// The document object id for `path`, minting `candidate` the first time the path is seen.
    ///
    /// MINTED rather than hashed: a v5 id over the path would need a SHA-1 this target does not
    /// otherwise link, and a minted id is exact where a hash is only unlikely to collide. Its one
    /// cost — a different id after a restart — is invisible, because a restart mints a new epoch
    /// and every client re-snapshots against `project/key`, which carries the path itself.
    pub fn project_id(&mut self, path: &[u8], candidate: Uuid) -> Uuid {
        *self.projects.entry(path.to_vec()).or_insert(candidate)
    }

    /// How many projects have an id.
    #[must_use]
    pub fn project_count(&self) -> usize {
        self.projects.len()
    }
}

#[cfg(test)]
mod tests {
    use super::{Key, NO_SLOT, PRIMARY_SUBSCRIBER, Registry};

    const CONN_A: [u8; 16] = [1; 16];
    const CONN_B: [u8; 16] = [2; 16];
    const SESSION: [u8; 16] = [9; 16];
    const OTHER_SESSION: [u8; 16] = [8; 16];

    fn fanned_out() -> Registry {
        let mut registry = Registry::new();
        registry.attach(Key::new(CONN_A, 1), 7, SESSION, PRIMARY_SUBSCRIBER);
        registry.attach(Key::new(CONN_B, 1), 7, SESSION, 42);
        registry
    }

    #[test]
    fn one_pane_under_two_connections_is_one_slot_and_two_members() {
        let registry = fanned_out();
        assert_eq!(registry.slots(), vec![7], "a fan-out is one pane, not two");
        assert_eq!(registry.members().len(), 2);
        assert_eq!(registry.connection_count(), 2);
    }

    #[test]
    fn a_channel_id_is_only_unique_within_its_connection() {
        let registry = fanned_out();
        assert_eq!(registry.slot(Key::new(CONN_A, 1)), 7);
        assert_eq!(registry.slot(Key::new(CONN_B, 1)), 7);
        assert_eq!(
            registry.member(Key::new(CONN_A, 1)).map(|m| m.subscriber),
            Some(PRIMARY_SUBSCRIBER)
        );
        assert_eq!(
            registry.member(Key::new(CONN_B, 1)).map(|m| m.subscriber),
            Some(42)
        );
    }

    #[test]
    fn a_leave_takes_one_member_and_a_reap_takes_every_alias() {
        let mut registry = fanned_out();
        assert!(registry.detach_key(Key::new(CONN_B, 1)).is_some());
        assert!(registry.slot_is_attached(7), "the other client is still watching");

        let mut registry = fanned_out();
        let doomed = registry.detach_slot(7);
        assert_eq!(doomed.len(), 2, "a reap takes both channels naming the pane");
        assert!(!registry.slot_is_attached(7));
        assert_eq!(registry.slots(), Vec::<u64>::new());
    }

    #[test]
    fn a_guarded_removal_refuses_to_unregister_a_successor() {
        let mut registry = Registry::new();
        let key = Key::new(CONN_A, 1);
        registry.attach(key, 7, SESSION, PRIMARY_SUBSCRIBER);
        // The detach window: a fresh object under the same session id took the key over.
        registry.attach(key, 8, SESSION, PRIMARY_SUBSCRIBER);
        assert!(
            !registry.detach_key_if_slot(key, 7),
            "the predecessor no longer owns the key"
        );
        assert_eq!(registry.slot(key), 8, "the live successor stays registered");
        assert!(registry.detach_key_if_slot(key, 8));
        assert_eq!(registry.slot(key), NO_SLOT);
    }

    #[test]
    fn a_link_drop_removes_only_its_own_connections_members() {
        let mut registry = fanned_out();
        let leaving = registry.detach_connection(CONN_A);
        assert_eq!(leaving.len(), 1);
        assert_eq!(leaving.first().map(|m| m.key.connection), Some(CONN_A));
        assert_eq!(registry.connection_count(), 1);
        assert!(
            registry.slot_is_attached(7),
            "the pane survives one client dropping"
        );
    }

    #[test]
    fn a_removed_key_is_not_a_member_of_anything() {
        let mut registry = fanned_out();
        registry.detach_key(Key::new(CONN_A, 1));
        assert_eq!(registry.member(Key::new(CONN_A, 1)), None);
        assert_eq!(registry.members_for_connection(CONN_A), vec![]);
        assert_eq!(registry.key_for(7, PRIMARY_SUBSCRIBER), None);
        assert_eq!(registry.key_for(7, 42), Some(Key::new(CONN_B, 1)));
    }

    #[test]
    fn a_join_finds_the_pane_that_is_live_under_another_key() {
        let registry = fanned_out();
        assert_eq!(registry.slot_elsewhere(SESSION, Key::new(CONN_B, 1)), 7);
        assert_eq!(
            registry.slot_elsewhere(SESSION, Key::new(CONN_A, 1)),
            7,
            "either key sees the other",
        );
        assert_eq!(
            registry.slot_elsewhere(OTHER_SESSION, Key::new(CONN_A, 1)),
            NO_SLOT
        );
    }

    #[test]
    fn a_lone_key_naming_a_session_is_not_elsewhere() {
        let mut registry = Registry::new();
        let key = Key::new(CONN_A, 1);
        registry.attach(key, 7, SESSION, PRIMARY_SUBSCRIBER);
        assert_eq!(
            registry.slot_elsewhere(SESSION, key),
            NO_SLOT,
            "its own key is not another"
        );
        assert_eq!(registry.slot_for_session(SESSION), 7);
    }

    #[test]
    fn a_drain_reports_each_pane_once() {
        let mut registry = fanned_out();
        registry.attach(Key::new(CONN_A, 2), 8, OTHER_SESSION, PRIMARY_SUBSCRIBER);
        assert_eq!(registry.drain_panes(), vec![7, 8]);
        assert_eq!(registry.members(), vec![]);
        assert_eq!(registry.connection_count(), 0);
    }

    #[test]
    fn a_standalone_pane_lives_in_its_own_map() {
        let mut registry = Registry::new();
        registry.attach_control(SESSION, 3);
        assert_eq!(registry.control_slot(SESSION), 3);
        assert_eq!(registry.slot_for_session(SESSION), NO_SLOT, "it holds no channel");
        assert_eq!(registry.detach_control(SESSION), 3);
        assert_eq!(
            registry.detach_control(SESSION),
            NO_SLOT,
            "the second removal is a no-op"
        );
        assert_eq!(registry.drain_control(), Vec::<u64>::new());
    }

    #[test]
    fn a_hook_sink_survives_a_reattach_and_only_its_owner_retires_it() {
        let mut registry = Registry::new();
        registry.register_hook(SESSION, b"pane-1", 100);
        assert_eq!(registry.hook_pane(SESSION), Some(b"pane-1".as_slice()));
        assert!(
            registry.rebind_hook(SESSION, 200),
            "the reattached object takes the entry over"
        );
        assert_eq!(
            registry.hook_pane(SESSION),
            Some(b"pane-1".as_slice()),
            "the exported pane id is immutable for the shell's life",
        );
        assert_eq!(
            registry.unregister_hook(SESSION, 100),
            None,
            "the predecessor cannot retire it"
        );
        assert_eq!(registry.hook_count(), 1);
        assert_eq!(registry.unregister_hook(SESSION, 200), Some(b"pane-1".to_vec()));
        assert_eq!(registry.hook_count(), 0);
        assert!(!registry.rebind_hook(SESSION, 300), "nothing to re-point");
    }

    #[test]
    fn a_project_keeps_the_first_id_it_was_given() {
        let mut registry = Registry::new();
        let first = registry.project_id(b"/src/app", [1; 16]);
        assert_eq!(first, [1; 16]);
        assert_eq!(
            registry.project_id(b"/src/app", [2; 16]),
            [1; 16],
            "the mint is once per path"
        );
        assert_eq!(registry.project_id(b"/src/other", [2; 16]), [2; 16]);
        assert_eq!(registry.project_count(), 2);
    }
}
