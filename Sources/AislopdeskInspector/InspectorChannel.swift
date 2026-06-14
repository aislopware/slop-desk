import Foundation

/// A bidirectional raw-byte channel for the inspector's second connection.
///
/// The inspector deliberately defines its **own** minimal framed channel rather than
/// reusing `AislopdeskTransport`'s `MessageChannel` (which is hard-typed to the terminal
/// `WireMessage`). This keeps the inspector self-contained, free of `Network` in the
/// pure layer, and unit-testable over an in-process loopback — while still riding the
/// same length-prefixed framing *style* (``InspectorFrameDecoder``).
///
/// The production `NWConnection`-backed conformer lives in ``NWByteChannel`` (this
/// file). Tests use ``LoopbackByteChannel`` for a deterministic round-trip.
public protocol ByteChannel: Sendable {
    /// Writes raw bytes (a complete frame). Throws on transport failure.
    func send(_ data: Data) async throws
    /// Inbound raw byte chunks (arbitrary boundaries — the decoder reassembles frames).
    var inbound: AsyncThrowingStream<Data, Error> { get }
    /// Closes the channel.
    func close()
}

/// Host side: serialises ``InspectorEvent``s onto a ``ByteChannel`` (NWConnection #2).
///
/// Read-only: it only *sends* events (host → client) and, optionally, reads a
/// lightweight `.subscribe` control from the client. It never produces any signal that
/// reaches the agent.
public actor InspectorSource {
    private let channel: ByteChannel

    public init(channel: ByteChannel) {
        self.channel = channel
    }

    /// Sends one event frame to the client.
    public func send(_ event: InspectorEvent) async throws {
        try await channel.send(InspectorCodec.encode(.event(event)))
    }

    /// Sends a keep-alive frame (so a quiet workflow run reads as alive).
    public func sendKeepAlive() async throws {
        try await channel.send(InspectorCodec.encode(.keepAlive))
    }

    /// Pumps an entire ``InspectorEvent`` stream to the client, in order.
    public func stream(_ events: AsyncStream<InspectorEvent>) async {
        for await event in events {
            try? await send(event)
        }
    }

    /// Inbound lightweight control from the client (subscribe/replay-from only).
    public func controls() -> AsyncThrowingStream<InspectorWireMessage, Error> {
        decodeStream(channel.inbound)
    }

    public func close() {
        channel.close()
    }
}

/// Client side: deserialises a ``ByteChannel`` into an ``InspectorEvent`` stream for
/// the SwiftUI views. It may send a single lightweight `.subscribe` control (the only
/// thing the client is allowed to send — never agent input).
public actor InspectorClient {
    private let channel: ByteChannel

    public init(channel: ByteChannel) {
        self.channel = channel
    }

    /// Requests (re)delivery of events. `fromSeq == 0` = full replay; a higher value
    /// resumes after a reconnect. Read-only control.
    public func subscribe(fromSeq: Int64 = 0) async throws {
        try await channel.send(InspectorCodec.encode(.subscribe(fromSeq: fromSeq)))
    }

    /// The decoded inbound stream, filtered to ``InspectorEvent`` (keep-alives are
    /// swallowed; they exist only for liveness).
    public func events() -> AsyncThrowingStream<InspectorEvent, Error> {
        let messages = decodeStream(channel.inbound)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in messages {
                        if case let .event(event) = message {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() {
        channel.close()
    }
}

/// Wraps a raw byte stream in an ``InspectorFrameDecoder`` and yields whole messages.
/// Shared by both ends.
///
/// **Resilience (BUG-G).** A single bad *payload* must not kill the whole inspector for
/// the session. ``InspectorFrameDecoder/nextMessage()`` removes a frame's bytes from the
/// buffer *before* decoding its payload, so a `CodecError.malformedBody` (a future /
/// corrupt event JSON) or `.unknownType` (a tag this build does not know) is recoverable:
/// the frame boundary is intact, the next frame still decodes. We therefore **log +
/// continue** on those two, draining the rest of the current chunk and resuming the live
/// stream — the inspector survives one rogue event.
///
/// `CodecError.frameTooLarge` is different: it is thrown from the *length-prefix* read,
/// before any bytes are consumed, so the byte stream is framing-desynced and every
/// subsequent read is garbage. That is genuinely unrecoverable in-band, so we finish the
/// stream (throwing) and the feed simply ends. There is no in-session live resubscribe
/// today — automatic in-band reconnect is deferred to PIECE C. Recovery happens on the
/// next iOS pause/resume cycle: ``LivePaneSession`` resume calls `subscribeInspector`,
/// which opens a fresh connection and `subscribe(fromSeq:)`s from 0, getting a clean
/// framed stream from the host's replay log.
private func decodeStream(
    _ inbound: AsyncThrowingStream<Data, Error>,
) -> AsyncThrowingStream<InspectorWireMessage, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var decoder = InspectorFrameDecoder()
            do {
                for try await chunk in inbound {
                    decoder.append(chunk)
                    // Drain every complete frame currently buffered, skipping individually
                    // bad payloads but propagating a framing desync (frameTooLarge).
                    drain: while true {
                        do {
                            guard let message = try decoder.nextMessage() else { break drain }
                            continuation.yield(message)
                        } catch let error as InspectorCodec.CodecError {
                            switch error {
                            case .malformedBody,
                                 .unknownType,
                                 .truncated:
                                // Recoverable: the frame was already consumed (its bytes
                                // removed before decode), so the boundary is intact. Skip
                                // this one message and keep decoding the next frame.
                                // (`.truncated` here means a short/garbled body inside an
                                // otherwise well-framed payload — same in-band recovery.)
                                continue drain
                            case .frameTooLarge:
                                // Framing desync (bad length prefix, no bytes consumed):
                                // unrecoverable in-band — finish so the client resubscribes.
                                throw error
                            }
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - In-process loopback (tests)

/// An in-process ``ByteChannel`` pair for deterministic transport round-trip tests.
/// `a.send` bytes surface on `b.inbound` and vice-versa, frame boundaries preserved by
/// the framing (each `send` is one frame; the decoder reassembles regardless).
public final class LoopbackByteChannel: ByteChannel, @unchecked Sendable {
    private let outbound: AsyncThrowingStream<Data, Error>.Continuation
    public let inbound: AsyncThrowingStream<Data, Error>

    private init(
        inbound: AsyncThrowingStream<Data, Error>,
        peerInbound: AsyncThrowingStream<Data, Error>.Continuation,
    ) {
        self.inbound = inbound
        outbound = peerInbound
    }

    /// Creates a connected pair `(host, client)`.
    public static func pair() -> (LoopbackByteChannel, LoopbackByteChannel) {
        var aCont: AsyncThrowingStream<Data, Error>.Continuation?
        let aIn = AsyncThrowingStream<Data, Error> { aCont = $0 }
        var bCont: AsyncThrowingStream<Data, Error>.Continuation?
        let bIn = AsyncThrowingStream<Data, Error> { bCont = $0 }
        guard let aCont, let bCont else {
            preconditionFailure(
                "AsyncThrowingStream runs its build closure synchronously, so the continuations are set",
            )
        }
        // `a.send` → `b.inbound` (bCont); `b.send` → `a.inbound` (aCont).
        let a = LoopbackByteChannel(inbound: aIn, peerInbound: bCont)
        let b = LoopbackByteChannel(inbound: bIn, peerInbound: aCont)
        return (a, b)
    }

    public func send(_ data: Data) {
        outbound.yield(data)
    }

    public func close() {
        outbound.finish()
    }
}
