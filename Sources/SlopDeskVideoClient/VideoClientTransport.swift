import Foundation
import SlopDeskVideoProtocol

/// Seam over the UDP transport the client orchestrator sends datagrams on (control /
/// input) and receives host datagrams from (control / video / geometry on the media
/// socket; cursor on the dedicated cursor socket).
///
/// This protocol is the **hang-safe test seam**, the exact mirror of the host's
/// `slopdesk-videohostd` `sendlane::DatagramSink`. The production conformer
/// (``VideoMuxClientTransport``, a lane on the shared ``VideoMuxClientFlow``) opens real
/// `NWConnection` `.udp` flows and is NEVER instantiated in a test; the orchestrator's pure
/// logic is exercised against an in-memory fake that records sent datagrams and feeds
/// synthetic received ones.
///
/// Channel discipline (must match the host's shared video flow):
/// - The **media** socket multiplexes control / video / geometry / input with a
///   1-byte ``SlopDeskVideoProtocol/VideoChannel`` tag prefix. The client SENDS control
///   + input and RECEIVES control / video / geometry there.
/// - The **cursor** socket is dedicated and carries bare ``CursorChannelMessage``
///   bytes (no tag) — receive-only on the client.
public protocol VideoClientTransport: Sendable {
    /// Connects the media + cursor UDP flows and starts delivering received datagrams.
    /// `onMedia` fires for each media-socket datagram (channel demultiplexed from the
    /// 1-byte tag + the tag-stripped payload); `onCursor` fires for each cursor-socket
    /// datagram (bare ``CursorChannelMessage`` bytes).
    func start(
        onMedia: @escaping @Sendable (VideoChannel, Data) -> Void,
        onCursor: @escaping @Sendable (Data) -> Void,
    ) async throws

    /// Sends one datagram on `channel` (control or input). Fire-and-forget (UDP): an
    /// error is logged, never surfaced as backpressure — the input path must not block.
    /// The conformer prepends the 1-byte channel tag (media socket).
    func send(_ datagram: Data, on channel: VideoChannel)

    /// Whether the underlying send path is currently viable. `false` = the media connection is
    /// on a dead path (`.waiting`) where Network.framework would buffer every datagram
    /// in-process indefinitely — the session's PERIODIC senders (NetworkStats, keepalive) skip
    /// their fire while it holds. Sparse best-effort sends (input, hello, recovery) stay
    /// ungated. Defaulted `true` (fakes / transports without path tracking send as today).
    var sendPathViable: Bool { get }

    /// Tears the flows down.
    func stop() async
}

public extension VideoClientTransport {
    var sendPathViable: Bool { true }
}
