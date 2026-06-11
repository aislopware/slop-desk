import Foundation
import Network
import AislopdeskProtocol

/// A ``MuxByteLink`` backed by one real `NWConnection` — the production physical link under a
/// shared ``MuxNWConnection`` (one such link is the CONTROL socket, one the DATA socket).
///
/// It is a thin raw-byte adapter: it does NOT frame or decode (the ``MuxFrameDecoder`` inside
/// ``MuxNWConnection`` owns that). It just writes raw bytes and surfaces inbound chunks — a
/// receive-loop over an `NWConnection` at the raw-byte level (no `WireMessage` framing here).
///
/// All mutable state (the inbound continuation) is set up at init; the receive loop re-arms itself
/// via the `NWConnection` callback (no actor needed — the continuation is `Sendable` and the
/// callbacks are serialized on the connection's queue).
public final class NWMuxByteLink: MuxByteLink, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let chunkStream: AsyncThrowingStream<Data, Error>
    private let chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation

    /// Wraps an already-ready `NWConnection` (the mux preamble is written before this is built) and
    /// starts its receive loop.
    public init(connection: NWConnection, label: String) {
        self.connection = connection
        self.queue = DispatchQueue(label: "aislopdesk.mux.link.\(label)")
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.chunkStream = AsyncThrowingStream { continuation = $0 }
        self.chunkContinuation = continuation
        receiveLoop()
    }

    public var receiveChunks: AsyncThrowingStream<Data, Error> { chunkStream }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AislopdeskTransportError.sendFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Hot-path send: enqueues on the `NWConnection` (FIFO with ``send(_:)``) and returns
    /// immediately — no per-frame dispatch round trip. The awaited variant cost one
    /// completion round trip through the connection's queue PER FRAME, which serialized
    /// the host output drain at frames-per-dispatch-hop and bought nothing: ordering is
    /// NWConnection's own FIFO, and in-flight bytes are bounded by the mux credit window
    /// (debited BEFORE the send). A failure is routed into the SAME path a receive error
    /// takes — finish the inbound stream throwing + cancel — so `MuxNWConnection.finishLink`
    /// / reconnect fire exactly as today. Captures the continuation + connection directly
    /// (not weak self) so an in-flight failure is never dropped; finish-after-finish is a
    /// no-op and cancel is idempotent.
    public func sendPipelined(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [chunkContinuation, connection] error in
            guard let error else { return }
            chunkContinuation.finish(throwing: AislopdeskTransportError.sendFailed(String(describing: error)))
            connection.cancel()
        })
    }

    public func close() async {
        connection.cancel()
        chunkContinuation.finish()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.chunkContinuation.finish(throwing: AislopdeskTransportError.receiveFailed(String(describing: error)))
                self.connection.cancel() // R11: free the socket fd — finishing the stream alone leaves the
                return                   // NWConnection (and its fd) alive (the R6 #10 fix, missed on the mux link).
            }
            if let data, !data.isEmpty {
                self.chunkContinuation.yield(data)
            }
            if isComplete {
                self.chunkContinuation.finish()
                self.connection.cancel() // R11: a CLEAN FIN must also release the fd — the host's connection
                return                   // reap (linkDownHandler) only fires on `error != nil`, so a graceful
                                         // client disconnect would otherwise leak both sockets + the MuxNWConnection.
            }
            self.receiveLoop()
        }
    }
}

/// Builds the production shared ``MuxNWConnection`` for an endpoint: opens the CONTROL + DATA
/// `NWConnection`s, writes the mux preamble on each, wraps them as ``NWMuxByteLink``s, and starts
/// the receive loops. This is the `makeConnection` factory the production ``ConnectionRegistry``
/// injects.
public enum LiveMuxConnectionFactory {
    /// Wall-clock ceiling on the whole socket-establishment + preamble sequence. A dead/unreachable
    /// host parks `NWConnection` in `.waiting` (waitForConnectivity) FOREVER — never a terminal state
    /// — so without this the connect hangs and the UI is stuck at "connecting" indefinitely. Matches
    /// the client's default `handshakeTimeout` (`AislopdeskClient.connect`, `.seconds(10)`).
    public static let connectTimeout: Duration = .seconds(10)

    @MainActor
    public static func makeConnection(host: String, port: UInt16) async throws -> MuxNWConnection {
        try await makeConnection(host: host, port: port, timeout: connectTimeout)
    }

    /// Timeout-bounded variant. The whole control+data establishment + preamble write runs inside one
    /// `withMuxConnectTimeout`: if it does not finish within `timeout`, the work branch is CANCELLED.
    /// `startAndWaitReady` is cancellation-aware — cancellation calls `NWConnection.cancel()`, driving
    /// the socket to `.cancelled` (so it is torn down, not leaked) and unblocking the awaiter — so the
    /// timeout is clean and the dead-host case surfaces a thrown ``AislopdeskTransportError/timedOut(_:)``
    /// instead of hanging. This is the "transport-level handshake deadline" the client UI asks for; it
    /// does NOT wrap `AislopdeskClient.connect` in a task group (which deadlocked the cooperative pool — see
    /// `ConnectionViewModel.connect`), only the inner NWConnection establishment.
    @MainActor
    static func makeConnection(host: String, port: UInt16, timeout: Duration) async throws -> MuxNWConnection {
        try await withMuxConnectTimeout(timeout, host: host, port: port) {
            let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
            let endpointHost = NWEndpoint.Host(host)

            // One connectionID pairs the two physical sockets into one shared connection on the host.
            let connectionID = UUID()

            let controlConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
            var dataConn: NWConnection?
            do {
                try await controlConn.startAndWaitReady(on: DispatchQueue(label: "aislopdesk.mux.control.ready"))
                try await controlConn.sendRaw(ChannelAssociation.muxControlPreamble(connectionID: connectionID))

                let data = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
                dataConn = data
                try await data.startAndWaitReady(on: DispatchQueue(label: "aislopdesk.mux.data.ready"))
                try await data.sendRaw(ChannelAssociation.muxDataPreamble(connectionID: connectionID))

                let connection = MuxNWConnection(
                    role: .client,
                    controlLink: NWMuxByteLink(connection: controlConn, label: "control"),
                    dataLink: NWMuxByteLink(connection: data, label: "data")
                )
                await connection.start()
                return connection
            } catch {
                // R11: cancel any half-built sockets before rethrowing. Once `controlConn` is `.ready` it
                // is a live fd; if DATA establishment then fails (flaky/dead host), the caller
                // (ConnectionRegistry's `makeConnection`) only sees the error and has NO handle to these
                // sockets — so without this they leak, accumulating toward fd exhaustion on every retry.
                controlConn.cancel()
                dataConn?.cancel()
                throw error
            }
        }
    }
}

/// Races `body` against a `Task.sleep(timeout)`; whichever finishes first wins and the loser is
/// CANCELLED. On timeout, throws ``AislopdeskTransportError/timedOut(_:)``; the cancelled `body`'s
/// in-flight `startAndWaitReady` cancels its `NWConnection`, so the socket is torn down (no leak).
///
/// This is the structured-race equivalent of `Tests/.../withTestTimeout`, in the transport target so
/// production can bound the dead-host connect. It races the SOCKET ESTABLISHMENT (a child of THIS
/// task group) — NOT the higher-level `AislopdeskClient.connect` — so it does not reintroduce the
/// `ConnectionViewModel` deadlock (which came from wrapping `client.connect` itself).
private func withMuxConnectTimeout(
    _ timeout: Duration,
    host: String,
    port: UInt16,
    _ body: @escaping @Sendable () async throws -> MuxNWConnection
) async throws -> MuxNWConnection {
    try await withThrowingTaskGroup(of: MuxNWConnection?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil   // timer branch: a `nil` result signals "timed out"
        }
        defer { group.cancelAll() }
        // The FIRST branch to finish decides the outcome. If the connect won it returns a real
        // connection; if the timer won (or the connect returned nil — impossible for `body`) it is
        // `nil` ⇒ timeout. Either way `cancelAll()` (deferred) cancels the loser, so a still-pending
        // `startAndWaitReady` cancels its NWConnection and the socket is reclaimed.
        while let result = try await group.next() {
            if let connection = result { return connection }   // connect branch won
            // Timer branch won first → bounded timeout. (The deferred cancelAll tears down the connect.)
            throw AislopdeskTransportError.timedOut("connect to \(host):\(port) exceeded \(timeout)")
        }
        // Group drained without a connection (connect branch threw and timer was cancelled): the thrown
        // error already propagated out of `group.next()`. Defensive fallback only.
        throw AislopdeskTransportError.timedOut("connect to \(host):\(port) exceeded \(timeout)")
    }
}
