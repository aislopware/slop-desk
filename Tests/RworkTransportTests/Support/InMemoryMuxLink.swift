import Foundation
@testable import RworkTransport

/// A pair of in-memory ``MuxByteLink``s that pipe bytes to each other — the headless substitute
/// for two `NWConnection`s, so the mux IO layer (``MuxNWConnection`` + ``MuxSubChannel``) can be
/// exercised end-to-end WITHOUT a socket or a `HostServer` (both of which hang the test process).
///
/// `pair()` returns `(a, b)`: bytes `a.send`-ed surface on `b.receiveChunks` and vice-versa.
final class InMemoryMuxLink: MuxByteLink, @unchecked Sendable {
    private let outbound: AsyncThrowingStream<Data, Error>.Continuation
    private let inbound: AsyncThrowingStream<Data, Error>
    /// Set to the peer's outbound continuation after pairing so `send` writes into it.
    private var peerInbound: AsyncThrowingStream<Data, Error>.Continuation?

    private init(
        inbound: AsyncThrowingStream<Data, Error>,
        outbound: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.inbound = inbound
        self.outbound = outbound
    }

    /// Builds a connected pair. Each end's `send` feeds the OTHER end's `receiveChunks`.
    static func pair() -> (InMemoryMuxLink, InMemoryMuxLink) {
        var aInC: AsyncThrowingStream<Data, Error>.Continuation!
        let aIn = AsyncThrowingStream<Data, Error> { aInC = $0 }
        var bInC: AsyncThrowingStream<Data, Error>.Continuation!
        let bIn = AsyncThrowingStream<Data, Error> { bInC = $0 }
        let a = InMemoryMuxLink(inbound: aIn, outbound: aInC)
        let b = InMemoryMuxLink(inbound: bIn, outbound: bInC)
        // a.send → b's inbound; b.send → a's inbound.
        a.peerInbound = bInC
        b.peerInbound = aInC
        return (a, b)
    }

    var receiveChunks: AsyncThrowingStream<Data, Error> { inbound }

    func send(_ data: Data) async throws {
        peerInbound?.yield(data)
    }

    func close() async {
        peerInbound?.finish()
        outbound.finish()
    }
}
