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

    public init() {}

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
        case .idle, .open, .none:
            // `.none` lets a responder register a peer-initiated id it did not allocate.
            states[id] = .open
        case .halfClosed, .closed:
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
        if states[id] == .idle { states[id] = .closed }
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
        let next: ChannelState
        switch states[id] {
        case .idle, .open:
            next = .halfClosed // first close from either side
        case .halfClosed:
            next = .closed // second close — both sides done
        case .closed:
            next = .closed // already dead
        case .none:
            next = .closed // close for an id we never knew → treat as dead
        }
        states[id] = next
        return next
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
}
