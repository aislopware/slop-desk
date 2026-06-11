import Foundation
import Network

/// Production ``ByteChannel`` backed by one `NWConnection` — the inspector's
/// **second** TCP connection (NWConnection #2, doc 00 ③ / doc 16 §3), multiplexed on
/// the same NetBird tunnel beside the terminal PTY stream.
///
/// It carries raw bytes only; framing is the ``InspectorFrameDecoder`` /
/// ``InspectorCodec`` layer above. `TCP_NODELAY` is set so a low-rate event is not
/// delayed by Nagle. All mutable state lives inside the actor — no `@unchecked`.
///
/// This is host-app glue (like the hook HTTP listener) but lives here so the inspector
/// transport is complete; it is compiled but exercised in production, not in the pure
/// unit tests (which use ``LoopbackByteChannel`` for determinism).
public actor NWByteChannel: ByteChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "aislopdesk.inspector.channel")

    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var started = false

    public init(connection: NWConnection) {
        self.connection = connection
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream { cont = $0 }
        self.inboundContinuation = cont
        // R17 INSP-WIRE-2: if the inbound consumer cancels its iteration WITHOUT calling close() (e.g.
        // its draining task is cancelled), cancel the NWConnection so its fd is released deterministically
        // rather than lingering until the actor deallocs. Capture `connection` (not self) so the handler
        // does not retain the actor; cancel() is idempotent vs. the other finish paths.
        inboundContinuation.onTermination = { [connection] _ in connection.cancel() }
    }

    /// Inspector TCP parameters: `TCP_NODELAY`, no app crypto (WireGuard encrypts).
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    public nonisolated var inbound: AsyncThrowingStream<Data, Error> { inboundStream }

    /// Starts the connection + receive loop (idempotent).
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            inboundContinuation.finish(throwing: error)
            connection.cancel() // R6 #10: free the socket fd — finishing the stream alone leaves the
            return              // NWConnection (and its fd) alive until the actor deallocs.
        }
        if let data, !data.isEmpty {
            inboundContinuation.yield(data)
        }
        if isComplete {
            inboundContinuation.finish()
            connection.cancel() // R6 #10: the peer/host closed the channel → cancel to release the fd
            return              // (idempotent vs. the stateUpdateHandler's `.cancelled` finish).
        }
        receiveLoop()
    }
}
