import Foundation
import SlopDeskVideoProtocol

/// Seam over the UDP transport the host orchestrator sends datagrams on and receives
/// client datagrams from.
///
/// This protocol is the **hang-safe test seam**: the production conformer is a
/// ``VideoMuxChannelTransport`` lane over the shared ``NWVideoMuxDatagramTransport``, which
/// opens real `NWListener`/`NWConnection` `.udp` sockets and is NEVER instantiated in a test;
/// the orchestrator's pure logic is exercised against an in-memory fake that records sent
/// datagrams and feeds synthetic received ones (mirroring the SlopDeskTransport `MessageChannel`
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
