import Foundation
import Network

/// One `NWConnection` as a bidirectional stream of raw bytes: an `AsyncThrowingStream` in, an
/// `async` send out, and a `close` that actually releases the fd.
///
/// It carries bytes and NOTHING else — framing, decoding and the message set are the layer above,
/// which is why the same actor serves the inspector's event lane (`docs/16` §3) and PATH-4's file
/// transfer (`docs/53`) without either of them knowing about the other.
///
/// It was that actor TWICE, line for line: `SlopDeskInspector.NWByteChannel` and
/// `SlopDeskFileTransfer.NWFileTransferChannel` differed in the dispatch-queue label and in their
/// prose, and in nothing a compiler or a socket could see. Two copies of a lifecycle this fussy is
/// the kind of thing that survives review precisely because each copy reads as correct on its own:
/// the `onTermination` cancel, the `cancel()` beside every `finish()`, and the idempotent `start()`
/// are three separate fd-leak fixes, and each one had to be made in both places or in neither.
///
/// ## The lifecycle, in one place
///
/// Every path that finishes the inbound stream also cancels the connection, because finishing the
/// stream alone leaves the `NWConnection` — and its file descriptor — alive until the actor
/// deallocates. That covers the three ways a channel can end: the peer closing (`isComplete`), a
/// transport error, and a consumer that stops iterating without calling ``close()``, which the
/// continuation's `onTermination` catches. `cancel()` is idempotent, so the paths may overlap.
///
/// The termination handler captures the connection rather than `self`, so a channel nobody holds is
/// still collectable while its handler is installed.
public actor NWByteChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var started = false

    /// Wraps a connection the caller has built but not started.
    ///
    /// `label` names the dispatch queue and is the ONE thing the two callers ever disagreed about;
    /// it exists so a spindump still says which lane a thread belongs to.
    public init(connection: NWConnection, label: String = "slopdesk.channel") {
        self.connection = connection
        queue = DispatchQueue(label: label)
        var cont: AsyncThrowingStream<Data, Error>.Continuation?
        inboundStream = AsyncThrowingStream { cont = $0 }
        guard let cont else {
            preconditionFailure(
                "AsyncThrowingStream's build closure runs synchronously, so the continuation is always set",
            )
        }
        inboundContinuation = cont
        inboundContinuation.onTermination = { [connection] _ in connection.cancel() }
    }

    /// The TCP parameters both lanes want: `TCP_NODELAY` so a small control frame is not delayed by
    /// Nagle behind a body burst, keepalive, and NO app-layer TLS — the WireGuard mesh is the
    /// security boundary and a second one would only be a second thing to get wrong.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Inbound raw byte chunks, at arbitrary boundaries — the decoder above reassembles frames.
    /// Finishes on a clean close, throws on transport failure.
    public nonisolated var inbound: AsyncThrowingStream<Data, Error> { inboundStream }

    /// Starts the connection and the receive loop. Idempotent — ``send(_:)`` calls it too, so a
    /// caller that only ever sends does not have to remember.
    public func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case let .failed(error) = state {
                Task { await self.failInbound(error) }
            } else if case .cancelled = state {
                Task { await self.finishInbound() }
            }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    /// Sends raw bytes to the peer. Throws on transport failure.
    public func send(_ data: Data) async throws {
        if !started { start() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Closes the channel and releases the socket.
    public nonisolated func close() {
        connection.cancel()
    }

    // MARK: - Internals

    private func failInbound(_ error: NWError) {
        inboundContinuation.finish(throwing: error)
    }

    private func finishInbound() {
        inboundContinuation.finish()
    }

    private func receiveLoop() {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
            }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            inboundContinuation.finish(throwing: error)
            connection.cancel() // free the fd — finishing the stream alone leaves the connection
            return // alive until the actor deallocs.
        }
        if let data, !data.isEmpty {
            inboundContinuation.yield(data)
        }
        if isComplete {
            inboundContinuation.finish()
            connection.cancel() // the peer closed → release the fd (idempotent vs. the state
            return // handler's `.cancelled` finish).
        }
        receiveLoop()
    }
}
