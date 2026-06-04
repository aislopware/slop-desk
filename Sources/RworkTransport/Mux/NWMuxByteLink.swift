import Foundation
import Network
import RworkProtocol

/// A ``MuxByteLink`` backed by one real `NWConnection` — the production physical link under a
/// shared ``MuxNWConnection`` (one such link is the CONTROL socket, one the DATA socket).
///
/// It is a thin raw-byte adapter: it does NOT frame or decode (the ``MuxFrameDecoder`` inside
/// ``MuxNWConnection`` owns that). It just writes raw bytes and surfaces inbound chunks — the same
/// receive-loop shape as ``NWMessageChannel`` but one level lower (no `WireMessage` framing here).
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
        self.queue = DispatchQueue(label: "rwork.mux.link.\(label)")
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
                    continuation.resume(throwing: RworkTransportError.sendFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() async {
        connection.cancel()
        chunkContinuation.finish()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.chunkContinuation.finish(throwing: RworkTransportError.receiveFailed(String(describing: error)))
                return
            }
            if let data, !data.isEmpty {
                self.chunkContinuation.yield(data)
            }
            if isComplete {
                self.chunkContinuation.finish()
                return
            }
            self.receiveLoop()
        }
    }
}

/// Builds the production shared ``MuxNWConnection`` for an endpoint: opens the CONTROL + DATA
/// `NWConnection`s, writes the mux preamble on each, wraps them as ``NWMuxByteLink``s, and starts
/// the receive loops. This is the `makeConnection` factory the production ``ConnectionRegistry``
/// injects (the gate is checked by the registry before this is ever called).
///
/// Both ends MUST agree on `RWORK_TCP_MUX` (spec constraint #2): the wire here (mux preamble +
/// envelope framing) is incompatible with the today preamble/framing, so a mixed-mode pairing is
/// unsupported by design — there is no negotiation, the flag is the contract.
public enum LiveMuxConnectionFactory {
    @MainActor
    public static func makeConnection(host: String, port: UInt16) async throws -> MuxNWConnection {
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let endpointHost = NWEndpoint.Host(host)

        // One connectionID pairs the two physical sockets into one shared connection on the host.
        let connectionID = UUID()

        let controlConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
        try await controlConn.startAndWaitReady(on: DispatchQueue(label: "rwork.mux.control.ready"))
        try await controlConn.sendRaw(ChannelAssociation.muxControlPreamble(connectionID: connectionID))

        let dataConn = NWConnection(host: endpointHost, port: endpointPort, using: TransportParameters.makeTCP())
        try await dataConn.startAndWaitReady(on: DispatchQueue(label: "rwork.mux.data.ready"))
        try await dataConn.sendRaw(ChannelAssociation.muxDataPreamble(connectionID: connectionID))

        let connection = MuxNWConnection(
            role: .client,
            controlLink: NWMuxByteLink(connection: controlConn, label: "control"),
            dataLink: NWMuxByteLink(connection: dataConn, label: "data"),
            // S2 sub-gate: read `RWORK_TCP_MUX_FLOW` ONCE here (alongside `RWORK_TCP_MUX`, which the
            // registry already checked before calling this factory). OFF → infinite window (S1).
            flowControl: MuxFlowControl.flowEnabledFromEnvironment()
        )
        await connection.start()
        return connection
    }
}
