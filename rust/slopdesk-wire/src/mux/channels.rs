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

    /// What to do with one decoded frame on this table — the DEMUX RULE, which is the same rule at
    /// both ends of the mux and now lives once, here, beside the state it reads and advances.
    ///
    /// It used to be a Swift `MuxRoutingCore.route` calling six of this type's methods across the
    /// FFI boundary, which is the shape that invites drift: every branch below reads a state and
    /// then writes one, and a rule split from its own table can be edited on one side only. Swift
    /// keeps the marshalling and the payload — the bytes never cross — and nothing else.
    ///
    /// `accepted` is read for [`FrameKind::ChannelOpenAck`] alone; every other kind ignores it.
    pub fn route(&mut self, kind: FrameKind, id: u32, accepted: bool) -> RoutingDecision {
        match kind {
            // Only a FULLY open channel is fed; everything else is dropped, never a crash. The two
            // drop reasons are kept apart because they mean different things to a reader: an
            // unknown id is a stale or hostile frame, a known-but-not-open one is a late frame on a
            // channel that really existed.
            FrameKind::ChannelData => {
                if self.is_open(id) {
                    RoutingDecision::DeliverData { channel_id: id }
                } else {
                    let reason = if self.state_of(id).is_some() {
                        DropReason::NonOpenChannel
                    } else {
                        DropReason::UnknownChannel
                    };
                    RoutingDecision::Drop {
                        channel_id: id,
                        reason,
                    }
                }
            },
            // The responder registers a peer-initiated channel. `open` is a no-op for a closing or
            // closed id, so a late open cannot resurrect a dead channel.
            FrameKind::ChannelOpen => {
                self.open(id);
                self.lifecycle(id, ChannelState::Open)
            },
            // The responder ACCEPTED or REFUSED the open we initiated. Only an accept advances the
            // channel; a refusal marks it dead through `reject`, because routing data to a refused
            // channel was a real defect once.
            //
            // An accept advances ONLY an id we ALREADY track. The client records the id as open at
            // `openChannel()` time — before it sends the frame — so a LEGITIMATE ack always lands on
            // an existing entry. An ack for an unknown id is spurious or hostile, and `open` would
            // materialise a permanent phantom entry for it: the same unbounded-table memory DoS
            // that `channelClose` and `channelOpen` already close, which this path once missed.
            FrameKind::ChannelOpenAck => {
                if accepted {
                    if self.state_of(id).is_some() {
                        self.open(id);
                    }
                    self.lifecycle(id, ChannelState::Closed)
                } else {
                    RoutingDecision::Lifecycle {
                        channel_id: id,
                        state: self.reject(id),
                    }
                }
            },
            FrameKind::ChannelClose => {
                RoutingDecision::Lifecycle {
                    channel_id: id,
                    state: self.remote_close(id),
                }
            },
            // Window credit belongs to the IO layer's flow policy; the table is unchanged. Report
            // the current state, or closed for an id never known — a stale adjust is harmless and
            // delivers nothing.
            FrameKind::WindowAdjust => self.lifecycle(id, ChannelState::Closed),
        }
    }

    /// A lifecycle answer for `id`, falling back to `absent` when the table has no entry.
    ///
    /// The two callers want different fallbacks for the same reason — an id with no entry has no
    /// state to report — so the fallback is the argument rather than a second spelling.
    fn lifecycle(&self, id: u32, absent: ChannelState) -> RoutingDecision {
        RoutingDecision::Lifecycle {
            channel_id: id,
            state: self.state_of(id).unwrap_or(absent),
        }
    }
}

/// The frame kinds the demux rule distinguishes — the mux envelope's own type byte, which is wire
/// vocabulary and so is spelled with its wire values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameKind {
    /// Initiator asks to open a channel.
    ChannelOpen = 1,
    /// Responder accepts or refuses that open.
    ChannelOpenAck = 2,
    /// Opaque application payload for an open channel.
    ChannelData = 3,
    /// One side is done sending (SSH `CHANNEL_CLOSE`).
    ChannelClose = 4,
    /// Replenish a channel's flow-control window.
    WindowAdjust = 5,
}

impl FrameKind {
    /// The kind a wire type byte names, or `None` for a byte no kind claims.
    ///
    /// Fails CLOSED, unlike the platform tables elsewhere in this repo: an unrecognised mux type is
    /// not a frame this rule can reason about, and guessing at one would route bytes on a channel
    /// nobody described.
    #[must_use]
    pub const fn from_wire(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::ChannelOpen),
            2 => Some(Self::ChannelOpenAck),
            3 => Some(Self::ChannelData),
            4 => Some(Self::ChannelClose),
            5 => Some(Self::WindowAdjust),
            _ => None,
        }
    }
}

/// Why a frame was dropped rather than routed. Two reasons, kept apart because they describe
/// different situations; the human wording for each belongs to whoever logs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DropReason {
    /// The channel exists but is not fully open — a late frame on a real channel.
    NonOpenChannel,
    /// No entry for the id at all — never allocated, or long since evicted.
    UnknownChannel,
}

/// What the router must do with one frame.
///
/// The payload is deliberately absent: the bytes stay with whoever decoded them, and this says only
/// WHERE they go. A decision carrying the payload would copy every chunk across a boundary for
/// nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoutingDecision {
    /// Feed the frame's payload to this channel's stream.
    DeliverData {
        /// The channel the bytes belong to.
        channel_id: u32,
    },
    /// A lifecycle frame was applied; this is the channel's resulting state.
    Lifecycle {
        /// The channel the frame named.
        channel_id: u32,
        /// Its state after the frame was applied.
        state: ChannelState,
    },
    /// The frame was for an unknown or non-open channel and was dropped.
    Drop {
        /// The channel the frame named.
        channel_id: u32,
        /// Which of the two drop situations this is.
        reason: DropReason,
    },
}

#[cfg(test)]
mod tests {
    use super::{ChannelState, ChannelTable, DropReason, FrameKind, RoutingDecision, TERMINAL_RING_CAP};

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

    /// Data is delivered ONLY to a fully open channel, and the two refusals are told apart: a
    /// channel that exists but is not open is a late frame, an id with no entry is stale or
    /// hostile. Conflating them would lose the only signal a reader has about which it is.
    #[test]
    fn data_routes_only_to_an_open_channel_and_says_why_it_did_not() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        assert_eq!(
            table.route(FrameKind::ChannelData, id, false),
            RoutingDecision::Drop {
                channel_id: id,
                reason: DropReason::NonOpenChannel
            },
            "an allocated-but-idle channel is known and not open",
        );

        table.open(id);
        assert_eq!(
            table.route(FrameKind::ChannelData, id, false),
            RoutingDecision::DeliverData { channel_id: id },
        );

        assert_eq!(
            table.route(FrameKind::ChannelData, 404, false),
            RoutingDecision::Drop {
                channel_id: 404,
                reason: DropReason::UnknownChannel
            },
        );

        table.remote_close(id);
        assert_eq!(
            table.route(FrameKind::ChannelData, id, false),
            RoutingDecision::Drop {
                channel_id: id,
                reason: DropReason::NonOpenChannel
            },
            "half-closed is not open — the strict predicate is the routing one",
        );
    }

    /// A refused open must mark the channel dead rather than leave it open, and an ACCEPT for an id
    /// the table never issued must create no entry. The second half is the memory-DoS this path
    /// once missed while the close and open paths were already guarded.
    #[test]
    fn an_ack_advances_only_a_channel_we_already_track() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id); // the client marks it open optimistically, before sending
        assert_eq!(
            table.route(FrameKind::ChannelOpenAck, id, false),
            RoutingDecision::Lifecycle {
                channel_id: id,
                state: ChannelState::Closed
            },
            "a refusal closes the optimistically opened channel",
        );

        let before = table.state_count();
        assert_eq!(
            table.route(FrameKind::ChannelOpenAck, 777, true),
            RoutingDecision::Lifecycle {
                channel_id: 777,
                state: ChannelState::Closed
            },
        );
        assert_eq!(
            table.state_count(),
            before,
            "an accept for an id we never issued must materialise no phantom entry",
        );
    }

    /// A window adjust reads the table and never writes it — the credit maths belongs to the IO
    /// layer's flow policy, and a rule that quietly advanced a channel here would be two owners for
    /// one piece of state.
    #[test]
    fn a_window_adjust_reports_state_without_changing_any() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        let before = table.state_count();

        assert_eq!(
            table.route(FrameKind::WindowAdjust, id, false),
            RoutingDecision::Lifecycle {
                channel_id: id,
                state: ChannelState::Open
            },
        );
        assert_eq!(
            table.route(FrameKind::WindowAdjust, 999, false),
            RoutingDecision::Lifecycle {
                channel_id: 999,
                state: ChannelState::Closed
            },
            "an adjust for an id we never knew reports closed and stays harmless",
        );
        assert_eq!(table.state_count(), before);
        assert_eq!(table.state_of(id), Some(ChannelState::Open));
    }

    /// A close routed through the rule is the same one-step symmetric machine `remote_close` runs,
    /// and a late open cannot resurrect what it closed.
    #[test]
    fn a_routed_close_is_symmetric_and_a_late_open_cannot_undo_it() {
        let mut table = ChannelTable::new();
        let id = table.allocate();
        table.open(id);
        assert_eq!(
            table.route(FrameKind::ChannelClose, id, false),
            RoutingDecision::Lifecycle {
                channel_id: id,
                state: ChannelState::HalfClosed
            },
        );
        assert_eq!(
            table.route(FrameKind::ChannelClose, id, false),
            RoutingDecision::Lifecycle {
                channel_id: id,
                state: ChannelState::Closed
            },
        );
        assert_eq!(
            table.route(FrameKind::ChannelOpen, id, false),
            RoutingDecision::Lifecycle {
                channel_id: id,
                state: ChannelState::Closed
            },
            "open is a no-op on a dead channel, so the rule reports it dead",
        );
    }

    /// The wire byte is the kind, and a byte no kind claims fails CLOSED — an unrecognised mux type
    /// is not a frame this rule can reason about.
    #[test]
    fn every_wire_type_byte_names_its_kind_and_nothing_else_does() {
        for (byte, kind) in [
            (1u8, FrameKind::ChannelOpen),
            (2, FrameKind::ChannelOpenAck),
            (3, FrameKind::ChannelData),
            (4, FrameKind::ChannelClose),
            (5, FrameKind::WindowAdjust),
        ] {
            assert_eq!(FrameKind::from_wire(byte), Some(kind));
            assert_eq!(kind as u8, byte, "the kind IS its wire byte");
        }
        assert!(FrameKind::from_wire(0).is_none());
        assert!(FrameKind::from_wire(6).is_none());
    }
}
