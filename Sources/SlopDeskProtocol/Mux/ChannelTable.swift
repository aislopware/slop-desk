import Foundation

/// Lifecycle state of one logical mux channel.
///
/// SSH-style `CHANNEL_CLOSE` symmetry: a channel is only fully ``closed`` after BOTH
/// sides have sent their close. While exactly one side has closed, the channel is
/// ``halfClosed`` — frames may still arrive from the side that has not closed yet.
public enum ChannelState: Sendable, Equatable {
    /// Allocated id with no `open` recorded yet (never carried data).
    case idle
    /// Both sides live; the channel routes data.
    case open
    /// Exactly one side has sent `CHANNEL_CLOSE`; awaiting the peer's close.
    case halfClosed
    /// Both sides have closed; the channel is dead and will not be reused.
    case closed
}

/// Pure value-type bookkeeping for the set of logical channels on one mux connection.
///
/// Allocates **odd** channel ids (1, 3, 5, …) — even ids and 0 are reserved for the
/// peer / future use — using a monotonic counter that NEVER reuses a live id (an id
/// is "live" until it reaches ``ChannelState/closed``). Tracks each channel's
/// ``ChannelState`` with SSH `CHANNEL_CLOSE` symmetry: each side sends close, and the
/// channel is fully closed only after both.
///
/// No IO, no clock, no sockets — just the integer allocator and the per-channel state
/// machine, so it is trivially unit-testable in isolation.
public struct ChannelTable: Sendable, Equatable {
    /// Per-channel state. Closed channels are retained so their ids are never reused.
    private var states: [UInt32: ChannelState] = [:]
    /// The last odd id handed out by ``allocate()``; 0 means none yet (first is 1).
    private var lastAllocated: UInt32 = 0

    /// Insertion-ordered ring of ids that have reached a terminal-ish state (``ChannelState/halfClosed``
    /// or ``ChannelState/closed``). Terminal entries are otherwise retained forever (so a monotonic id
    /// is never reused), but on the HOST the PEER chooses ids, so sustained channelOpen→channelClose
    /// CHURN with a fresh id each cycle would grow `states` without bound — the live-channel cap never
    /// trips because the live count returns to ~0 between cycles (R12 #1). This ring bounds the retained
    /// terminal entries: once full, recording a new terminal id EVICTS the oldest terminal id from
    /// `states`. Sized >= `maxChannelsPerConnection` so legitimate churn is never evicted while still
    /// routable; an evicted id's late frame hits `state(of:) == nil` and is dropped as unknown (never a
    /// crash). `lastAllocated` is monotonic and independent of `states`, so evicting a closed id can
    /// never cause the local allocator to re-hand it out.
    private var terminalRing: [UInt32] = []
    private var terminalRingHead = 0
    private static let terminalRingCap = 1024

    public init() {}

    /// Records `id` as newly terminal and, once the ring is full, evicts the oldest terminal id from
    /// `states` (O(1) — overwrites a ring slot, no array shift). Call EXACTLY once per id, on its first
    /// transition into a terminal state, so a single id never occupies two ring slots.
    ///
    /// INVARIANT (load-bearing): only ever record an id that is FULLY DETACHED from routing — i.e. its
    /// owner has already removed it from the dispatch maps (`dataChannels`/`controlChannels`), so a frame
    /// for an evicted id resolves to `state(of:) == nil` and is dropped as unknown (never a crash). A
    /// `.halfClosed` id still counts as "live" in ``liveChannelIDs``, so eviction CAN drop a logically-
    /// half-closed entry from `states`; that is safe today only because both close paths tear the
    /// dispatch-map entry down at the FIRST close (when noteTerminal fires) and never resurrect it from
    /// `states`. If a future change ever kept a half-closed channel ROUTABLE (true SSH half-close — the
    /// unclosed direction keeps flowing), recording it here would let the ring silently drop a still-
    /// flowing channel after 1024 distinct closes on one connection. Don't record routable ids.
    private mutating func noteTerminal(_ id: UInt32) {
        if terminalRing.count < Self.terminalRingCap {
            terminalRing.append(id)
        } else {
            let evicted = terminalRing[terminalRingHead]
            if evicted != id { states[evicted] = nil }
            terminalRing[terminalRingHead] = id
            terminalRingHead += 1
            if terminalRingHead == Self.terminalRingCap { terminalRingHead = 0 }
        }
    }

    /// Allocates the next unused **odd** channel id (client-initiated convention) and
    /// records it as ``ChannelState/idle``. Monotonic: an id is never handed out
    /// twice, even across closes, so a stale frame for a dead id can never collide
    /// with a fresh channel.
    public mutating func allocate() -> UInt32 {
        // First id is 1; thereafter advance by 2 to stay odd.
        let id = lastAllocated == 0 ? 1 : lastAllocated + 2
        lastAllocated = id
        states[id] = .idle
        return id
    }

    /// Marks `id` as ``ChannelState/open`` (both sides live). Idempotent for an
    /// already-open channel; a no-op for an unknown or already-closed id.
    public mutating func open(_ id: UInt32) {
        switch states[id] {
        case .idle,
             .open,
             .none:
            // `.none` lets a responder register a peer-initiated id it did not allocate.
            states[id] = .open
        case .halfClosed,
             .closed:
            break // closing/closed channels do not re-open
        }
    }

    /// Records that the responder REFUSED our channel-open (it replied
    /// ``MuxFrame/channelOpenAck`` with `accepted: false`). A refused channel never
    /// opened, so there is NO half-close handshake — the locally-allocated `idle` id
    /// goes straight to ``ChannelState/closed`` (retained, never reused, like any closed
    /// id). A no-op for an id that is already open/closing/closed or was never allocated
    /// (a stray refusal for an unknown id creates no entry). Returns the resulting state.
    @discardableResult
    public mutating func reject(_ id: UInt32) -> ChannelState {
        if states[id] == .idle { states[id] = .closed
            noteTerminal(id)
        }
        return states[id] ?? .closed
    }

    /// Records that THIS side sent `CHANNEL_CLOSE` on `id` and returns the resulting
    /// state. `open`/`idle` → ``ChannelState/halfClosed``; an already ``halfClosed``
    /// channel (peer closed first) → ``ChannelState/closed`` (both sides done).
    @discardableResult
    public mutating func localClose(_ id: UInt32) -> ChannelState {
        advanceClose(id)
    }

    /// Records that the PEER sent `CHANNEL_CLOSE` on `id` and returns the resulting
    /// state. Symmetric with ``localClose(_:)``: the first close half-closes, the
    /// second fully closes.
    @discardableResult
    public mutating func remoteClose(_ id: UInt32) -> ChannelState {
        advanceClose(id)
    }

    /// Shared close transition used by both sides — `CHANNEL_CLOSE` symmetry means a
    /// close from either direction advances the same one-step state machine.
    private mutating func advanceClose(_ id: UInt32) -> ChannelState {
        switch states[id] {
        case .idle,
             .open:
            states[id] = .halfClosed // first close from either side
            noteTerminal(id) // newly terminal — bound the retained entries (R12 #1)
            return .halfClosed
        case .halfClosed:
            states[id] = .closed // second close — both sides done (already ring-recorded at half-close)
            return .closed
        case .closed:
            return .closed // already dead
        case .none:
            // A close for an id we NEVER registered must create NO entry. The prior code inserted
            // `states[id] = .closed`, so a hostile peer could grow `states` without bound by spamming
            // `channelClose` for arbitrary peer-chosen ids — a small-frame-in / permanent-allocation-out
            // router memory-DoS. The monotonic-no-reuse guarantee only needs to cover LOCALLY-allocated
            // ids (which are always registered via `allocate`/`open`), never unknown peer ids.
            return .closed
        }
    }

    /// The current ``ChannelState`` of `id`, or `nil` if the id was never allocated /
    /// registered.
    public func state(of id: UInt32) -> ChannelState? {
        states[id]
    }

    /// Whether `id` is currently routable (``ChannelState/open``). A ``halfClosed``
    /// channel is NOT considered open here — the caller decides whether to keep
    /// feeding it; ``isOpen(_:)`` is the strict "fully live" predicate.
    public func isOpen(_ id: UInt32) -> Bool {
        states[id] == .open
    }

    /// Ids that are not fully ``ChannelState/closed`` (idle, open, or half-closed) —
    /// the channels still capable of carrying or completing traffic.
    public var liveChannelIDs: Set<UInt32> {
        Set(states.compactMap { id, state in state == .closed ? nil : id })
    }

    /// Total number of retained id entries (live + closed). Diagnostics / tests — used to assert the
    /// router table cannot be grown without bound by hostile channelOpen/Close spam (R6 #5 / R7 #6).
    public var stateCount: Int { states.count }
}
