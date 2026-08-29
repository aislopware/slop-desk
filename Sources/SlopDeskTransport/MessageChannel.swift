import SlopDeskProtocol

/// A bidirectional, framed transport for ``WireMessage``.
///
/// The production conformer is ``MuxControlChannel`` — the CONTROL lane of one
/// ``MuxClientTransport``, multiplexed over the per-host shared mux that `rust/slopdesk-clientnet`
/// owns end to end.
///
/// Sending is an `async` call; receiving is an `AsyncThrowingStream`, so the receive loop can
/// `for try await` decoded messages.
///
/// It used to carry a `channel: Channel` requirement, naming which of a session's two sockets it
/// rode. Nothing ever read it — the socket is chosen by the sender that already holds one, never
/// re-derived — and `docs/63` G.4 deleted the `Channel` enum with it. What the requirement
/// described is still true and is now spelled where it is decided: this protocol has exactly one
/// production conformer and it is the CONTROL lane.
public protocol MessageChannel: Sendable {
    /// Frames and writes one message. Throws if the connection has failed.
    func send(_ message: WireMessage) async throws

    /// A stream of fully decoded inbound messages for this channel. Bytes arrive in arbitrary
    /// chunks and are reassembled by `rust/slopdesk-wire`'s frame decoder, below the boundary,
    /// before being yielded here. The stream finishes when the peer closes cleanly and errors on
    /// transport / decode failure.
    var inbound: AsyncThrowingStream<WireMessage, Error> { get }
}
