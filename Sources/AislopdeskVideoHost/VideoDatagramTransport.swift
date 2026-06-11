import Foundation
import AislopdeskVideoProtocol

/// The logical sub-streams that share one PATH 2 UDP session (doc 17 §3.3/§3.6/§3.8).
///
/// The cursor channel is a **separate UDP socket** (doc 17 §3.3: "KHÔNG multiplex
/// chung socket video" — never multiplex with video, so video backpressure never
/// delays the cursor). The orchestrator treats each `Channel` as an independent
/// addressable lane; the concrete ``VideoDatagramTransport`` decides whether to back
/// them with one socket + a tag, or distinct sockets. The proven design uses TWO
/// sockets: a media socket (control / video / geometry / input) and a dedicated
/// cursor socket.
public enum VideoChannel: UInt8, Sendable, CaseIterable {
    /// Session bring-up control (``VideoControlMessage``): hello / helloAck / bye.
    case control = 0
    /// Encoded video fragments (``FrameFragment``).
    case video = 1
    /// Window move/resize/title (``WindowGeometryMessage``).
    case geometry = 2
    /// Cursor position + shape (``CursorChannelMessage``) — its own socket.
    case cursor = 3
    /// Client → host input (``InputEvent``) — received, not sent, by the host.
    case input = 4
    /// Client → host loss recovery (``RecoveryMessage``: requestLTRRefresh /
    /// requestIDR / ack) — received, not sent, by the host. A DEDICATED channel (not
    /// multiplexed onto `.input`): `RecoveryMessage`'s leading type bytes (1/2/3)
    /// overlap `InputEvent`'s (mouseMove/Down/Up), so sharing `.input` would mis-decode
    /// a recovery datagram as a phantom mouse event. Keeping the per-purpose channel
    /// design lets the host route recovery to ``InputDatagramRouter``-free handling.
    case recovery = 5
}

/// Seam over the UDP transport the host orchestrator sends datagrams on and receives
/// client datagrams from.
///
/// This protocol is the **hang-safe test seam**: the production conformer is a
/// ``VideoMuxChannelTransport`` lane over the shared ``NWVideoMuxDatagramTransport``, which
/// opens real `NWListener`/`NWConnection` `.udp` sockets and is NEVER instantiated in a test;
/// the orchestrator's pure logic is exercised against an in-memory fake that records sent
/// datagrams and feeds synthetic received ones (mirroring the AislopdeskTransport `MessageChannel`
/// discipline).
public protocol VideoDatagramTransport: Sendable {
    /// Begins listening for the client (binds the media + cursor sockets) and starts
    /// delivering received datagrams to `onReceive`. `onReceive` is called for every
    /// inbound datagram with the channel it arrived on and its raw bytes.
    func start(onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) async throws

    /// Sends one datagram on `channel`. Fire-and-forget (UDP): an error is logged,
    /// not surfaced as backpressure — the media path must never block on a send.
    func send(_ datagram: Data, on channel: VideoChannel)

    /// Tears the sockets down.
    func stop() async

    /// Frees the pinned client flow slots so the listener can RE-PIN a reconnecting client
    /// (CONCURRENCY-HOST-1). Called when the session processes a client `bye`: UDP has no FIN,
    /// so a clean disconnect never fails the host's pinned flow — without this the slot stayed
    /// pinned forever and every reconnect (a fresh source port ⇒ a new 4-tuple) was silently
    /// refused at the listener until the daemon was restarted. The LISTENERS stay up (only the
    /// per-client flows are dropped); the next hello is accepted normally. Best-effort: a LOST
    /// `bye` datagram won't trigger it — a crash-without-bye still needs an idle-timeout reaper.
    func resetClientFlow()
}
