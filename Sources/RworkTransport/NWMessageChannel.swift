import Foundation
import Network
import RworkProtocol

/// A ``MessageChannel`` backed by one `NWConnection`.
///
/// Responsibilities:
/// - Encode a ``WireMessage`` to a length-prefixed frame (`msg.encode()`) and write
///   it with `NWConnection.send`, bridging the completion callback to `async`.
/// - Run a receive loop that pulls raw byte chunks off the connection, appends every
///   chunk to a per-connection ``RworkProtocol/FrameDecoder``, and **drains all
///   complete messages** before requesting more bytes — this is what makes TCP
///   coalescing (many frames in one read) and splitting (one frame across reads)
///   transparent to callers.
/// - Surface connection state (`ready` / `failed` / `cancelled`) and let callers
///   `await` readiness via ``waitUntilReady()``.
///
/// All mutable state (the decoder, the inbound continuation, the state) lives inside
/// this `actor`, so there is no data race: the `NWConnection` callbacks hop onto the
/// actor's executor before touching anything. No `@unchecked Sendable`.
public actor NWMessageChannel: MessageChannel {
    /// The logical channel this connection carries (advisory; framing is identical).
    public nonisolated let channel: Channel

    /// Observable connection state for this channel.
    public enum State: Sendable, Equatable {
        case setup
        case ready
        case failed(String)
        case cancelled
    }

    private let connection: NWConnection
    private let queue: DispatchQueue

    /// Per-connection streaming frame decoder. Lives inside the actor (not `Sendable`).
    private var decoder = FrameDecoder()

    private var state: State = .setup

    // Inbound stream plumbing.
    private let inboundStream: AsyncThrowingStream<WireMessage, Error>
    private let inboundContinuation: AsyncThrowingStream<WireMessage, Error>.Continuation

    // Readiness waiters: continuations resumed when the connection becomes ready (or fails).
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// Wraps an already-constructed (but not yet started) `NWConnection`.
    ///
    /// The connection must have been built with ``TransportParameters/makeTCP()`` so
    /// `TCP_NODELAY` is set. Call ``start()`` to begin the state machine + receive loop.
    public init(connection: NWConnection, channel: Channel) {
        self.connection = connection
        self.channel = channel
        self.queue = DispatchQueue(label: "rwork.channel.\(channel)")
        var continuation: AsyncThrowingStream<WireMessage, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    public nonisolated var inbound: AsyncThrowingStream<WireMessage, Error> {
        inboundStream
    }

    /// The current connection state (snapshot).
    public var currentState: State { state }

    /// Starts the connection state machine and the receive loop. Idempotent-safe to
    /// call once; calling again after start is a no-op on the underlying connection.
    public func start() {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleStateUpdate(newState) }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    /// Suspends until the connection reaches `.ready`. Throws if it fails/cancels first.
    public func waitUntilReady() async throws {
        switch state {
        case .ready:
            return
        case let .failed(reason):
            throw RworkTransportError.connectionFailed(reason)
        case .cancelled:
            throw RworkTransportError.connectionFailed("cancelled")
        case .setup:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyWaiters.append(continuation)
            }
        }
    }

    /// Frames and writes one message. Suspends until the OS accepts the bytes; throws
    /// on send failure or if the connection is not usable.
    ///
    /// A `.cancelled`/`.failed` channel fails fast with a typed ``RworkTransportError/notConnected``
    /// *before* touching `NWConnection.send`, so a caller (e.g. the host relay) can tell
    /// "the channel is gone" apart from a genuine transient send error — and treat the
    /// former as the client going offline rather than a fatal fault. See the reconnect
    /// race in ``HostSessionTransport/sendOutput(_:)``.
    public func send(_ message: WireMessage) async throws {
        switch state {
        case .failed(let reason):
            throw RworkTransportError.notConnected(reason)
        case .cancelled:
            throw RworkTransportError.notConnected("cancelled")
        case .setup, .ready:
            break
        }
        let frame = message.encode()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RworkTransportError.sendFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Closes the connection. The inbound stream finishes; in-flight `send`s may fail.
    public func close() {
        connection.cancel()
    }

    // MARK: - Internals

    private func handleStateUpdate(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .ready
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }

        case let .failed(error):
            let reason = String(describing: error)
            state = .failed(reason)
            failWaiters(RworkTransportError.connectionFailed(reason))
            inboundContinuation.finish(throwing: RworkTransportError.connectionFailed(reason))

        case .cancelled:
            state = .cancelled
            failWaiters(RworkTransportError.connectionFailed("cancelled"))
            inboundContinuation.finish()

        case .waiting, .preparing, .setup:
            break

        @unknown default:
            break
        }
    }

    private func failWaiters(_ error: Error) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// Issues one `receive`; the completion hops back onto the actor, feeds the
    /// decoder, drains every complete frame, then re-arms itself. One outstanding
    /// receive at a time keeps ordering well-defined.
    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            inboundContinuation.finish(throwing: RworkTransportError.receiveFailed(String(describing: error)))
            return
        }

        if let data, !data.isEmpty {
            decoder.append(data)
            do {
                // Drain ALL complete frames buffered after this chunk.
                while let message = try decoder.nextMessage() {
                    inboundContinuation.yield(message)
                }
            } catch {
                // A decode fault (frameTooLarge / truncated / unknownType / malformedBody)
                // is fatal for the stream — the byte boundary is lost.
                inboundContinuation.finish(throwing: error)
                connection.cancel()
                return
            }
        }

        if isComplete {
            // Peer closed cleanly (FIN).
            inboundContinuation.finish()
            return
        }

        // Re-arm for the next chunk.
        receiveLoop()
    }
}

/// Errors thrown by the transport layer (distinct from ``RworkProtocol/RworkError``,
/// which is decode-time). These wrap `Network.framework` failures and handshake faults.
public enum RworkTransportError: Error, Equatable, Sendable {
    /// The underlying `NWConnection` failed or was cancelled before/while in use.
    case connectionFailed(String)
    /// A send was attempted on a channel that is already `.cancelled`/`.failed` (the
    /// channel is gone, not a transient send fault). Distinct from ``sendFailed(_:)`` so
    /// the relay can treat it as "client offline → replay on next reconnect" rather than
    /// a fatal error.
    case notConnected(String)
    /// `NWConnection.send` reported an error.
    case sendFailed(String)
    /// `NWConnection.receive` reported an error.
    case receiveFailed(String)
    /// The listener failed to start (e.g. port in use).
    case listenerFailed(String)
    /// The handshake did not complete as required (wrong/missing message, version mismatch).
    case handshakeFailed(String)
    /// An operation was attempted on a connection in the wrong state.
    case invalidState(String)
    /// A bounded wait (handshake / readiness) timed out.
    case timedOut(String)
}
