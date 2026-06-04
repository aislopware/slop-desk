#if os(macOS)
import Foundation
import RworkVideoProtocol

/// A per-channel ``VideoDatagramTransport`` view over the ONE shared
/// ``NWVideoMuxDatagramTransport`` — the seam that lets an UNCHANGED
/// ``RworkVideoHostSession`` ride a single lane of the shared UDP flow (Stage S3).
///
/// One of these is minted per client video channel (per `channelID`) by the daemon's
/// session registry. From the session's point of view it has the IDENTICAL surface as
/// ``NWVideoDatagramTransport`` (it conforms to the same ``VideoDatagramTransport``);
/// the difference is entirely below:
/// - `send` stamps THIS lane's `channelID` via the shared transport (which prefixes the
///   datagram with the channelID, see ``NWVideoMuxDatagramTransport/send(_:on:channelID:)``).
/// - `start(onReceive:)` registers this lane's sink SYNCHRONOUSLY into the shared
///   ``VideoMuxSinkTable`` (so the triggering hello is deliverable the instant
///   `session.start()` returns) + admits the lane in the shared router. The shared
///   transport already bound the sockets once, so `start` never opens a socket.
/// - `resetClientFlow()` retires ONLY this lane in the shared ``VideoMuxRouter`` +
///   unregisters its sink (the bye-retires-only-the-closing-lane decision, spec §9):
///   sibling sessions on the same shared flow keep streaming; this lane's still-in-flight
///   datagrams are dropped (reconnect-generation safety) rather than misrouted.
///
/// `@unchecked Sendable`: it holds only immutable bindings (`channelID`, the shared
/// transport, the sink table) and delegates all mutable state to their internal locks.
public final class VideoMuxChannelTransport: VideoDatagramTransport, @unchecked Sendable {
    private let channelID: UInt32
    private let shared: NWVideoMuxDatagramTransport
    private let sinkTable: VideoMuxSinkTable
    /// Called when this lane retires (bye / stop) so the daemon's registry clears its bookkeeping.
    private let onRetire: @Sendable (UInt32) -> Void

    public init(
        channelID: UInt32,
        shared: NWVideoMuxDatagramTransport,
        sinkTable: VideoMuxSinkTable,
        onRetire: @escaping @Sendable (UInt32) -> Void
    ) {
        self.channelID = channelID
        self.shared = shared
        self.sinkTable = sinkTable
        self.onRetire = onRetire
    }

    public func start(onReceive: @escaping @Sendable (VideoChannel, Data) -> Void) async throws {
        // Register the lane sink SYNCHRONOUSLY (so the triggering hello is deliverable the moment
        // session.start() returns) + admit the lane so the shared router routes its datagrams. No
        // socket opened here — the shared transport already bound them once.
        sinkTable.register(channelID, onReceive)
        shared.admit(channelID)
    }

    public func send(_ datagram: Data, on channel: VideoChannel) {
        shared.send(datagram, on: channel, channelID: channelID)
    }

    public func stop() async {
        retireLane()
    }

    public func resetClientFlow() {
        // A `bye` on THIS lane: retire only this channelID. Sibling lanes survive (spec §9). The
        // listener is shared and untouched, so a reconnecting client re-opens under a fresh lane.
        retireLane()
    }

    private func retireLane() {
        shared.retire(channelID)
        sinkTable.unregister(channelID)
        onRetire(channelID)
    }
}
#endif
