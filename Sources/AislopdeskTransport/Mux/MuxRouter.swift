import AislopdeskProtocol
import Foundation

/// The routed decision for one decoded ``MuxFrame``.
///
/// PURE demux logic in the spirit of `InputDatagramRouter.Decision`: given a frame
/// the router says what the IO layer should DO — without owning sockets, per-channel
/// `FrameDecoder`s, or any clock. A `channelData` frame yields the opaque inner
/// ``WireMessage`` bytes plus the channel id so the IO layer can feed that channel's
/// own decoder; lifecycle frames advance the ``ChannelTable``; a frame for an
/// unknown / already-closed channel is **dropped** (never a crash).
public enum MuxRoutingDecision: Equatable, Sendable {
    /// Feed `payload` (opaque inner ``WireMessage`` frame bytes) to `channelID`'s
    /// per-channel stream. The IO layer owns the actual per-channel `FrameDecoder`.
    case deliverData(channelID: UInt32, payload: Data)
    /// A channel-lifecycle frame was applied to the table; `newState` is the channel's
    /// resulting state (for open/openAck/close/windowAdjust the router advanced the
    /// `ChannelTable` accordingly).
    case lifecycle(channelID: UInt32, newState: ChannelState)
    /// The frame was for an unknown or already-closed channel and was dropped.
    /// `reason` is a short human-readable explanation (never a fatal condition).
    case dropUnknownChannel(channelID: UInt32, reason: String)
}

/// PURE per-channel mux router for the CLIENT side.
///
/// Wraps a ``ChannelTable`` and turns each decoded ``MuxFrame`` into a
/// ``MuxRoutingDecision`` via the shared ``MuxRoutingCore``. It does NOT open sockets
/// or per-channel `FrameDecoder`s — it returns the opaque bytes + channel id and lets
/// the (later-built) IO layer own the per-channel decoding.
public struct MuxRouter: Sendable {
    private var table: ChannelTable

    /// Creates a router. An empty table is the client default; pass a pre-populated
    /// table only in tests that want to seed channel state.
    public init(table: ChannelTable = ChannelTable()) {
        self.table = table
    }

    /// The channels the router still considers live (not fully closed).
    public var liveChannelIDs: Set<UInt32> { table.liveChannelIDs }

    /// Whether `channelID` is currently fully open (routable for data).
    public func isOpen(_ channelID: UInt32) -> Bool { table.isOpen(channelID) }

    /// Allocates a fresh **odd** client channel id (delegates to ``ChannelTable``).
    public mutating func allocateChannel() -> UInt32 { table.allocate() }

    /// Routes one decoded mux frame, mutating the channel table as needed.
    public mutating func route(_ frame: MuxFrame) -> MuxRoutingDecision {
        MuxRoutingCore.route(frame, in: &table)
    }
}
