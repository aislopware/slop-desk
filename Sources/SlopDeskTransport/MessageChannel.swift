import SlopDeskProtocol

/// A bidirectional, framed transport for ``WireMessage``.
///
/// One channel maps to one ``Channel`` (data or control). The production conformer is
/// ``MuxControlChannel`` — the CONTROL lane of one ``MuxClientTransport``, multiplexed over the
/// per-host shared mux that `rust/slopdesk-clientnet` owns end to end.
///
/// Sending is an `async` call; receiving is an `AsyncThrowingStream` so the receive
/// loop can `for try await` decoded messages produced by a per-channel
/// ``SlopDeskProtocol/FrameDecoder``.
public protocol MessageChannel: Sendable {
    /// Which logical channel this transport carries.
    var channel: Channel { get }

    /// Frames and writes one message. Throws if the connection has failed.
    func send(_ message: WireMessage) async throws

    /// A stream of fully decoded inbound messages for this channel. Bytes arrive in
    /// arbitrary chunks and are reassembled by a ``SlopDeskProtocol/FrameDecoder`` before
    /// being yielded here. The stream finishes when the peer closes cleanly and errors
    /// on transport / decode failure.
    var inbound: AsyncThrowingStream<WireMessage, Error> { get }
}
