import CSlopDeskFFI

/// Lifecycle state of one logical mux channel.
///
/// SSH-style `CHANNEL_CLOSE` symmetry: a channel is only fully ``closed`` after BOTH
/// sides have sent their close. While exactly one side has closed, the channel is
/// ``halfClosed`` — frames may still arrive from the side that has not closed yet.
public enum ChannelState: UInt32, Sendable, Equatable {
    /// Allocated id with no `open` recorded yet (never carried data).
    case idle = 0
    /// Both sides live; the channel routes data.
    case open = 1
    /// Exactly one side has sent `CHANNEL_CLOSE`; awaiting the peer's close.
    case halfClosed = 2
    /// Both sides have closed; the channel is dead and will not be reused.
    case closed = 3
}

/// Bookkeeping for the set of logical channels on one mux connection.
///
/// Allocates **odd** channel ids (1, 3, 5, …) — even ids and 0 are reserved for the
/// peer / future use — using a monotonic counter that NEVER reuses a live id (an id
/// is "live" until it reaches ``ChannelState/closed``). Tracks each channel's
/// ``ChannelState`` with SSH `CHANNEL_CLOSE` symmetry: each side sends close, and the
/// channel is fully closed only after both.
///
/// The allocator, the state machine and the eviction ring that bounds the retained entries against
/// peer-chosen id churn all live in `rust/slopdesk-wire`'s `mux::channels`. This is the handle: a
/// `final class` because a map plus a ring cannot cross a boundary in a call, and intentionally
/// **not** `Sendable` — one table per connection, driven by its owner.
public final class ChannelTable {
    /// The Rust table. Owned outright: one `new` here, one `free` in `deinit`.
    private let handle: OpaquePointer

    public init() {
        guard let handle = slopdesk_channel_table_new() else {
            preconditionFailure("out of memory for a channel table")
        }
        self.handle = handle
    }

    deinit { slopdesk_channel_table_free(handle) }

    /// Allocates the next unused **odd** channel id (client-initiated convention) and
    /// records it as ``ChannelState/idle``. Monotonic: an id is never handed out
    /// twice, even across closes, so a stale frame for a dead id can never collide
    /// with a fresh channel.
    public func allocate() -> UInt32 {
        slopdesk_channel_table_allocate(handle)
    }

    /// Marks `id` as ``ChannelState/open`` (both sides live). Idempotent for an
    /// already-open channel; a no-op for an already-closed id. An id the table has never seen
    /// becomes open, which is how a responder registers a peer-initiated channel.
    public func open(_ id: UInt32) {
        slopdesk_channel_table_open(handle, id)
    }

    /// Records that the responder REFUSED our channel-open (it replied
    /// ``MuxFrame/channelOpenAck`` with `accepted: false`). A refused channel never
    /// opened, so there is NO half-close handshake — the id goes straight to
    /// ``ChannelState/closed`` (retained, never reused, like any closed id).
    ///
    /// A stray refusal for an id that was never allocated creates no entry.
    @discardableResult
    public func reject(_ id: UInt32) -> ChannelState {
        state(slopdesk_channel_table_reject(handle, id))
    }

    /// Records that THIS side sent `CHANNEL_CLOSE` on `id` and returns the resulting
    /// state. `open`/`idle` → ``ChannelState/halfClosed``; an already ``halfClosed``
    /// channel (peer closed first) → ``ChannelState/closed`` (both sides done).
    @discardableResult
    public func localClose(_ id: UInt32) -> ChannelState {
        state(slopdesk_channel_table_local_close(handle, id))
    }

    /// Records that the PEER sent `CHANNEL_CLOSE` on `id` and returns the resulting
    /// state. Symmetric with ``localClose(_:)``: the first close half-closes, the
    /// second fully closes.
    @discardableResult
    public func remoteClose(_ id: UInt32) -> ChannelState {
        state(slopdesk_channel_table_remote_close(handle, id))
    }

    /// The current ``ChannelState`` of `id`, or `nil` if the id was never allocated /
    /// registered — or if its terminal entry has since been evicted by the ring. Both read as
    /// "unknown", and an unknown id's late frame is dropped rather than routed.
    public func state(of id: UInt32) -> ChannelState? {
        ChannelState(rawValue: slopdesk_channel_table_state(handle, id))
    }

    /// Whether `id` is currently routable (``ChannelState/open``). A ``halfClosed``
    /// channel is NOT considered open here — the caller decides whether to keep
    /// feeding it; ``isOpen(_:)`` is the strict "fully live" predicate.
    public func isOpen(_ id: UInt32) -> Bool {
        slopdesk_channel_table_state(handle, id) == ChannelState.open.rawValue
    }

    /// Ids that are not fully ``ChannelState/closed`` (idle, open, or half-closed) —
    /// the channels still capable of carrying or completing traffic.
    public var liveChannelIDs: Set<UInt32> {
        let count = slopdesk_channel_table_live(handle, nil, 0)
        guard count > 0 else { return [] }
        return withUnsafeTemporaryAllocation(of: UInt32.self, capacity: count) { room in
            let written = slopdesk_channel_table_live(handle, room.baseAddress, room.count)
            // The table cannot grow between the sizing call and this one: both run inside this
            // property, on the one thread its owner drives it from.
            precondition(written == count, "the channel table resized between two reads of it")
            return Set(room)
        }
    }

    /// Total number of retained id entries (live + closed). Diagnostics / tests — used to assert the
    /// router table cannot be grown without bound by hostile channelOpen/Close spam.
    public var stateCount: Int { slopdesk_channel_table_state_count(handle) }

    /// A state ordinal, read back. An unknown id answers ``ChannelState/closed`` here, which is what
    /// every close-path caller has always been told: there is nothing left to close.
    private func state(_ ordinal: UInt32) -> ChannelState {
        ChannelState(rawValue: ordinal) ?? .closed
    }
}
