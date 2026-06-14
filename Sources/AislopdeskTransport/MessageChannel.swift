import AislopdeskProtocol
import Foundation

/// A bidirectional, framed transport for ``WireMessage``.
///
/// One channel maps to one ``Channel`` (data or control). The conformer is
/// ``MuxSubChannel`` — one logical channel multiplexed over a shared ``MuxNWConnection`` (whose
/// physical links use ``TransportParameters/makeTCP()``, so `TCP_NODELAY` is always set).
///
/// Sending is an `async` call; receiving is an `AsyncThrowingStream` so the receive
/// loop can `for try await` decoded messages produced by a per-channel
/// ``AislopdeskProtocol/FrameDecoder``.
public protocol MessageChannel: Sendable {
    /// Which logical channel this transport carries.
    var channel: Channel { get }

    /// Frames and writes one message. Throws if the connection has failed.
    func send(_ message: WireMessage) async throws

    /// A stream of fully decoded inbound messages for this channel. Bytes arrive in
    /// arbitrary chunks and are reassembled by a ``AislopdeskProtocol/FrameDecoder`` before
    /// being yielded here. The stream finishes when the peer closes cleanly and errors
    /// on transport / decode failure.
    var inbound: AsyncThrowingStream<WireMessage, Error> { get }
}
