import Foundation
import Network

/// A raw bidirectional byte channel for one PATH-4 connection. Framing/decoding lives one layer up
/// (``FileTransferFrameDecoder`` / ``FileTransferCodec``); this only moves bytes — the same
/// separation the inspector's `NWByteChannel` uses. A seam so the server/client logic is driven over
/// an in-process ``LoopbackFileTransferChannel`` in tests (no live socket, per hang-safety).
public protocol FileTransferChannel: Sendable {
    /// Inbound raw bytes; finishes on clean close, throws on transport failure.
    var inbound: AsyncThrowingStream<Data, Error> { get }
    /// Sends raw bytes to the peer.
    func send(_ data: Data) async throws
    /// Closes the channel and releases the socket.
    func close()
}

/// Production channel over one `NWConnection`. `TCP_NODELAY` so a small control frame (accept/complete)
/// is not delayed by Nagle behind a body burst. Mirrors `NWByteChannel`'s lifecycle discipline.
public actor NWFileTransferChannel: FileTransferChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "slopdesk.filetransfer.channel")
    private let inboundStream: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var started = false

    public init(connection: NWConnection) {
        self.connection = connection
        var cont: AsyncThrowingStream<Data, Error>.Continuation?
        inboundStream = AsyncThrowingStream { cont = $0 }
        guard let cont else {
            preconditionFailure("AsyncThrowingStream's build closure runs synchronously")
        }
        inboundContinuation = cont
        inboundContinuation.onTermination = { [connection] _ in connection.cancel() }
    }

    /// PATH-4 TCP parameters: `TCP_NODELAY` + keepalive, no app crypto (WireGuard encrypts).
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    public nonisolated var inbound: AsyncThrowingStream<Data, Error> { inboundStream }

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

    private func failInbound(_ error: NWError) { inboundContinuation.finish(throwing: error) }
    private func finishInbound() { inboundContinuation.finish() }

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
            connection.cancel()
            return
        }
        if let data, !data.isEmpty { inboundContinuation.yield(data) }
        if isComplete {
            inboundContinuation.finish()
            connection.cancel()
            return
        }
        receiveLoop()
    }
}
