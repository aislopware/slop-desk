//! Bookkeeping for the set of logical channels on one mux connection: the id allocator and the
//! per-channel close state machine.
//!
//! No IO, no clock, no sockets — just the integer allocator and the state machine — so it is
//! testable in isolation, which is the discipline the whole `mux` module follows.

use std::collections::{HashMap, HashSet};

/// Insertion-ordered ring capacity for ids that have reached a terminal state.
///
/// Sized at or above the live-channel cap (`MuxFlowControl::MAX_CHANNELS_PER_CONNECTION`) so
/// legitimate churn is never evicted while still routable.
const TERMINAL_RING_CAP: usize = 1024;

/// Lifecycle state of one logical mux channel.
///
/// SSH-style close symmetry: a channel is only fully [`Closed`](ChannelState::Closed) after BOTH
/// sides have sent their close. While exactly one side has, the channel is
/// [`HalfClosed`](ChannelState::HalfClosed) — frames may still arrive from the side that has not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChannelState {
    /// Allocated id with no open recorded yet (never carried data).
    Idle,
    /// Both sides live; the channel routes data.
    Open,
    /// Exactly one side has sent close; awaiting the peer's.
    HalfClosed,
    /// Both sides have closed; the channel is dead and will not be reused.
    Closed,
}

/// The channel table for one mux connection.
///
/// Allocates **odd** ids (1, 3, 5, …) — even ids and 0 are the peer's / reserved — from a monotonic
/// counter that NEVER reuses a live id, so a stale frame for a dead channel can never collide with
/// a fresh one.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChannelTable {
    /// Per-channel state. Closed channels are retained so their ids are never reused.
    states: HashMap<u32, ChannelState>,
    /// The last odd id handed out by [`allocate`](ChannelTable::allocate); 0 means none yet.
    last_allocated: u32,
    /// Ids that have reached a terminal-ish state, oldest-first within the ring.
    terminal_ring: Vec<u32>,
    /// Write position in [`Self::terminal_ring`] once it is full.
    terminal_ring_head: usize,
}

impl ChannelTable {
    /// An empty table.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records `id` as newly terminal and, once the ring is full, evicts the OLDEST terminal id
    /// from `states` — O(1), overwriting a ring slot rather than shifting.
    ///
    /// Terminal entries are otherwise retained forever, so a monotonic id is never reused. But on
    /// the HOST the PEER chooses ids, so sustained open→close churn with a fresh id each cycle
    /// would grow `states` without bound: the live-channel cap never trips because the live count
    /// returns to ~0 between cycles. This ring is what bounds it. An evicted id's late frame reads
    /// as `state_of == None` and is dropped as unknown, never as a crash; `last_allocated` is
    /// monotonic and independent of `states`, so eviction can never make the local allocator
    /// re-hand out an id.
    ///
    /// Call EXACTLY once per id, on its first transition into a terminal state, so one id never
    /// occupies two ring slots.
    ///
    /// INVARIANT (load-bearing): only ever record an id that is FULLY DETACHED from routing — its
    /// owner has already removed it from the dispatch maps. A [`ChannelState::HalfClosed`] id still
    /// counts as live in [`live_channel_ids`](ChannelTable::live_channel_ids), so eviction CAN drop
    /// a logically half-closed entry; that is safe only because both close paths tear the dispatch
    /// entry down at the FIRST close. If a future change ever kept a half-closed channel ROUTABLE
    /// (true SSH half-close, where the unclosed direction keeps flowing), recording it here would
    /// let the ring silently drop a still-flowing channel after `TERMINAL_RING_CAP` distinct closes
    /// on one connection. Do not record routable ids.
    fn note_terminal(&mut self, id: u32) {
        if self.terminal_ring.len() < TERMINAL_RING_CAP {
            self.terminal_ring.push(id);
            return;
        }
        if let Some(slot) = self.terminal_ring.get_mut(self.terminal_ring_head) {
            let evicted = *slot;
            *slot = id;
            if evicted != id {
                self.states.remove(&evicted);
            }
        }
        self.terminal_ring_head += 1;
        if self.terminal_ring_head == TERMINAL_RING_CAP {
            self.terminal_ring_head = 0;
        }
    }

    /// Allocates the next unused **odd** channel id and records it as [`ChannelState::Idle`].
    ///
    /// Monotonic: an id is never handed out twice, even across closes.
    pub fn allocate(&mut self) -> u32 {
        // First id is 1; thereafter advance by 2 to stay odd. Saturating rather than wrapping: an
        // exhausted allocator must not silently start re-handing out live ids, and 2^31 channels on
        // one connection is not a case any real peer reaches.
        let id = if self.last_allocated == 0 {
            1
        } else {
            self.last_allocated.saturating_add(2)
        };
        self.last_allocated = id;
        self.states.insert(id, ChannelState::Idle);
        id
    }

    /// Marks `id` as [`ChannelState::Open`]. Idempotent for an already-open channel; a no-op for an
    /// already-closing or closed one.
    ///
    /// An UNKNOWN id becomes open, which is how a responder registers a peer-initiated id it did
    /// not allocate.
    pub fn open(&mut self, id: u32) {
        match self.states.get(&id) {
            None | Some(ChannelState::Idle | ChannelState::Open) => {
                self.states.insert(id, ChannelState::Open);
            },
            Some(ChannelState::HalfClosed | ChannelState::Closed) => {}, // do not re-open
        }
    }

    /// Records that the responder REFUSED our open (`accepted: false`) and returns the resulting
    /// state.
    ///
    /// A refused channel never opened, so there is NO half-close handshake — the id goes straight
    /// to [`ChannelState::Closed`], retained and never reused like any closed id.
    ///
    /// Accepts the transition from BOTH `Idle` AND `Open`: the production client marks a channel
    /// open OPTIMISTICALLY before the frame is even sent, so by ack time the state is never `Idle`.
    /// An `Idle`-only guard would make a real host refusal a silent no-op — the router would report
    /// open, the sub-channels would never finish, and the pane would hang open and silent forever.
    ///
    /// A stray refusal for an id that was never allocated creates NO entry.
    pub fn reject(&mut self, id: u32) -> ChannelState {
        match self.states.get(&id) {
            Some(ChannelState::Idle | ChannelState::Open) => {
                self.states.insert(id, ChannelState::Closed);
                self.note_terminal(id);
            },
            // Already terminal (ring-recorded at its first close) or unknown.
            Some(ChannelState::HalfClosed | ChannelState::Closed) | None => {},
        }
        self.states.get(&id).copied().unwrap_or(ChannelState::Closed)
    }

    /// Records that THIS side sent close on `id` and returns the resulting state.
    pub fn local_close(&mut self, id: u32) -> ChannelState {
        self.advance_close(id)
    }

    /// Records that the PEER sent close on `id` and returns the resulting state.
    ///
    /// Symmetric with [`local_close`](ChannelTable::local_close): the first close half-closes, the
    /// second fully closes.
    pub fn remote_close(&mut self, id: u32) -> ChannelState {
        self.advance_close(id)
    }

    /// The shared close transition — close symmetry means a close from either direction advances
    /// the same one-step machine.
    fn advance_close(&mut self, id: u32) -> ChannelState {
        match self.states.get(&id) {
            Some(ChannelState::Idle | ChannelState::Open) => {
                self.states.insert(id, ChannelState::HalfClosed);
                self.note_terminal(id); // newly terminal — bound the retained entries
                ChannelState::HalfClosed
            },
            Some(ChannelState::HalfClosed) => {
                // Second close — both sides done. Already ring-recorded at the half-close.
                self.states.insert(id, ChannelState::Closed);
                ChannelState::Closed
            },
            Some(ChannelState::Closed) => ChannelState::Closed,
            None => {
                // A close for an id we NEVER registered must create NO entry. Inserting one here
                // would let a hostile peer grow `states` without bound by spamming closes for
                // arbitrary ids — small-frame-in, permanent-allocation-out. The monotonic-no-reuse
                // guarantee only needs to cover LOCALLY allocated ids, which always go through
                // `allocate`/`open`.
                ChannelState::Closed
            },
        }
    }

    /// The current state of `id`, or `None` if it was never allocated or registered.
    #[must_use]
    pub fn state_of(&self, id: u32) -> Option<ChannelState> {
        self.states.get(&id).copied()
    }

    /// Whether `id` is currently routable.
    ///
    /// A half-closed channel is NOT open here — the caller decides whether to keep feeding it; this
    /// is the strict "fully live" predicate.
    #[must_use]
    pub fn is_open(&self, id: u32) -> bool {
        self.states.get(&id) == Some(&ChannelState::Open)
    }

    /// Ids that are not fully closed — the channels still capable of carrying or completing
    /// traffic.
    #[must_use]
    pub fn live_channel_ids(&self) -> HashSet<u32> {
        self.states
            .iter()
            .filter(|(_, state)| **state != ChannelState::Closed)
            .map(|(id, _)| *id)
            .collect()
    }

    /// Total retained id entries, live and closed.
    ///
    /// Diagnostics: asserts the router table cannot be grown without bound by hostile open/close
    /// spam.
    #[must_use]
    pub fn state_count(&self) -> usize {
        self.states.len()
    }
}

#[cfg(test)]
mod tests {
    use super::{ChannelState, ChannelTable, TERMINAL_RING_CAP};

    #[test]
    fn allocation_is_odd_and_monotonic_across_closes() {
        let mut table = ChannelTable::new();
        let first = table.allocate();
        let second = table.allocate();
        assert_eq!((first, second), (1, 3));
        table.local_close(first);
        table.remote_close(first);
        assert_eq!(table.state_of(first), Some(ChannelState::Closed));
        // A closed id is never handed back out.
        assert_eq!(table.allocate(), 5);
    }

    #[test]
    fn a_close_from_each_side_is_needed_to_reach_closed() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        assert!(table.is_open(id));
        assert_eq!(table.local_close(id), ChannelState::HalfClosed);
        assert!(!table.is_open(id), "half-closed is not routable");
        assert!(table.live_channel_ids().contains(&id), "but it is still live");
        assert_eq!(table.remote_close(id), ChannelState::Closed);
        assert!(!table.live_channel_ids().contains(&id));
    }

    #[test]
    fn a_half_closed_or_closed_channel_never_re_opens() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        table.local_close(id);
        table.open(id);
        assert_eq!(table.state_of(id), Some(ChannelState::HalfClosed));
        table.remote_close(id);
        table.open(id);
        assert_eq!(table.state_of(id), Some(ChannelState::Closed));
    }

    #[test]
    fn a_responder_may_register_a_peer_chosen_id_it_never_allocated() {
        let mut table = ChannelTable::new();
        table.open(2);
        assert!(table.is_open(2));
    }

    #[test]
    fn a_refusal_closes_an_optimistically_opened_channel() {
        // The production client marks a channel open before the frame is even sent, so by ack time
        // the state is `Open`, never `Idle`. An `Idle`-only guard here would hang the pane.
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        assert_eq!(table.reject(id), ChannelState::Closed);
    }

    #[test]
    fn a_refusal_for_an_unknown_id_creates_no_entry() {
        let mut table = ChannelTable::new();
        assert_eq!(table.reject(999), ChannelState::Closed);
        assert_eq!(table.state_count(), 0);
        assert_eq!(table.state_of(999), None);
    }

    #[test]
    fn closes_for_unknown_ids_cannot_grow_the_table() {
        // The memory-DoS shape: small frames in, permanent allocation out.
        let mut table = ChannelTable::new();
        for id in 0..100_000_u32 {
            assert_eq!(table.remote_close(id), ChannelState::Closed);
        }
        assert_eq!(table.state_count(), 0);
    }

    #[test]
    fn sustained_peer_chosen_churn_is_bounded_by_the_terminal_ring() {
        // The host does not choose these ids, and the live count returns to ~0 between cycles, so
        // the live-channel cap never trips. The ring is the only thing bounding this.
        let mut table = ChannelTable::new();
        let cycles = u32::try_from(TERMINAL_RING_CAP).unwrap_or(u32::MAX) * 4;
        for id in 1..=cycles {
            table.open(id);
            table.local_close(id);
            table.remote_close(id);
        }
        assert!(
            table.state_count() <= TERMINAL_RING_CAP,
            "retained entries stay bounded: {}",
            table.state_count()
        );
        assert!(table.live_channel_ids().is_empty());
    }

    #[test]
    fn an_evicted_id_reads_as_unknown_rather_than_as_a_live_channel() {
        let mut table = ChannelTable::new();
        let cycles = u32::try_from(TERMINAL_RING_CAP).unwrap_or(u32::MAX) * 2;
        for id in 1..=cycles {
            table.open(id);
            table.local_close(id);
            table.remote_close(id);
        }
        assert_eq!(table.state_of(1), None, "the oldest terminal id was evicted");
        assert!(!table.is_open(1), "and a late frame for it is dropped");
    }
}
