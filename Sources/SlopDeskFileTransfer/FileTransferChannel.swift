import Foundation
import SlopDeskNet

/// A raw bidirectional byte channel for one PATH-4 connection. Framing/decoding lives one layer up
/// (``FileTransferFrameDecoder`` / ``FileTransferCodec``); this only moves bytes — the same
/// separation the inspector's `NWByteChannel` uses.
///
/// The in-process loopback conformer this used to have is gone with the Swift server: the receiving
/// end is `slopdesk-dropd` now, so the end-to-end test dials the real daemon over a real socket
/// rather than short-circuiting one Swift half into the other (`docs/53`).
public protocol FileTransferChannel: Sendable {
    /// Inbound raw bytes; finishes on clean close, throws on transport failure.
    var inbound: AsyncThrowingStream<Data, Error> { get }
    /// Sends raw bytes to the peer.
    func send(_ data: Data) async throws
    /// Closes the channel and releases the socket.
    func close()
}

/// PATH-4's lane IS the shared ``NWByteChannel``; this line is the whole production conformer.
///
/// The actor it used to spell out moved to `SlopDeskNet` when it turned out the inspector's
/// `NWByteChannel` was the same actor line for line, down to the `onTermination` cancel and the
/// `cancel()` beside every `finish()`. ``FileTransferChannel`` stays because it is THIS lane's
/// vocabulary — what a caller here is allowed to ask for — not because the socket differs.
extension NWByteChannel: FileTransferChannel {}
