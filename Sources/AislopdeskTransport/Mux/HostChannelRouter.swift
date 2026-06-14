import AislopdeskProtocol
import Foundation

/// PURE per-channel mux router for the HOST side.
///
/// The host is the RESPONDER: it does not allocate channel ids (clients allocate odd
/// ids) — it registers the peer-initiated channels it sees in `channelOpen` and
/// services them. Demux logic is otherwise identical to the client, so it shares the
/// same pure ``MuxRoutingCore``: a `channelData` frame yields `(channelID, opaque
/// WireMessage bytes)`; open / openAck / close / windowAdjust advance the
/// ``ChannelTable``; an unknown / closed channel's DATA is dropped (never a crash).
///
/// Like ``MuxRouter`` it owns NO sockets and NO per-channel `FrameDecoder`s — the
/// (later-built) IO layer owns per-channel decoding and flow-control windows.
public struct HostChannelRouter: Sendable {
    private var table: ChannelTable

    /// Creates a host router. An empty table is the default; pass a pre-populated
    /// table only in tests that want to seed channel state.
    public init(table: ChannelTable = ChannelTable()) {
        self.table = table
    }

    /// The channels the router still considers live (not fully closed).
    public var liveChannelIDs: Set<UInt32> { table.liveChannelIDs }

    /// Whether `channelID` is currently fully open (routable for data).
    public func isOpen(_ channelID: UInt32) -> Bool { table.isOpen(channelID) }

    /// Routes one decoded mux frame, mutating the channel table as needed. A
    /// `channelOpen` from the client registers and opens the peer-initiated channel.
    public mutating func route(_ frame: MuxFrame) -> MuxRoutingDecision {
        MuxRoutingCore.route(frame, in: &table)
    }
}
