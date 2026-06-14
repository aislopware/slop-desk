import AislopdeskVideoProtocol
import Foundation

/// The logical sub-streams that share one PATH 2 UDP session (doc 17 §3.3/§3.6/§3.8).
///
/// This is the **client-side mirror** of `AislopdeskVideoHost.VideoChannel`: the raw
/// values are the byte-identical wire tags (control=0 / video=1 / geometry=2 /
/// cursor=3 / input=4) so the 1-byte media-socket channel tag matches the host
/// exactly. The client and host live in separate modules (the client must not depend
/// on the macOS-only host), so each carries the same pure enum — the wire contract is
/// the agreement, not a shared Swift type. (The docs step should hoist this into
/// `AislopdeskVideoProtocol` so both sides reference one definition.)
public enum VideoChannel: UInt8, Sendable, CaseIterable {
    /// Session bring-up control (``VideoControlMessage``): hello / helloAck / bye.
    case control = 0
    /// Encoded video fragments (``FrameFragment``) — received by the client.
    case video = 1
    /// Window move/resize/title (``WindowGeometryMessage``) — received by the client.
    case geometry = 2
    /// Cursor position + shape (``CursorChannelMessage``) — its own socket.
    case cursor = 3
    /// Client → host input (``InputEvent``) — SENT by the client.
    case input = 4
    /// Client → host loss recovery (``RecoveryMessage``: requestLTRRefresh /
    /// requestIDR / ack) — SENT by the client. A DEDICATED channel (not multiplexed
    /// onto `.input`): `RecoveryMessage`'s leading type bytes overlap `InputEvent`'s,
    /// so sharing `.input` would have the host mis-decode recovery as a phantom mouse
    /// event. Byte-identical raw value (5) to the host's `VideoChannel.recovery`.
    case recovery = 5
}

/// Seam over the UDP transport the client orchestrator sends datagrams on (control /
/// input) and receives host datagrams from (control / video / geometry on the media
/// socket; cursor on the dedicated cursor socket).
///
/// This protocol is the **hang-safe test seam**, the exact mirror of the host's
/// `AislopdeskVideoHost.VideoDatagramTransport`. The production conformer
/// (``VideoMuxClientTransport``, a lane on the shared ``NWVideoMuxClientFlow``) opens real
/// `NWConnection` `.udp` flows and is NEVER instantiated in a test; the orchestrator's pure
/// logic is exercised against an in-memory fake that records sent datagrams and feeds
/// synthetic received ones.
///
/// Channel discipline (must match the host's shared video flow):
/// - The **media** socket multiplexes control / video / geometry / input with a
///   1-byte ``AislopdeskVideoProtocol/VideoChannel`` tag prefix. The client SENDS control
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

    /// Tears the flows down.
    func stop() async
}
