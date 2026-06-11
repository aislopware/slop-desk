import Foundation

/// A raw, framing-agnostic byte link the ``MuxNWConnection`` runs its mux receive loop over.
///
/// The mux IO layer needs exactly two things from the physical transport: write raw bytes, and
/// receive raw byte chunks. Abstracting that behind this protocol lets ``MuxNWConnection`` be
/// driven EITHER by a real `NWConnection` (production) OR by an in-memory pipe (the headless
/// loopback mux test) — so the demux-into-correct-per-channel-stream property is provable without
/// a socket or a `HostServer` (both of which hang the test process).
///
/// `send` mirrors `NWConnection.send`'s "suspend until accepted" contract (kept for the
/// call sites whose error handling is load-bearing: `openChannel`'s ghost-channel cleanup,
/// the control sub-channel's ack re-arm); `sendPipelined` is the hot-path variant.
/// `receiveChunks` is a stream of raw byte chunks (a chunk may be a partial frame, several
/// frames, or a frame split across chunks — the ``MuxFrameDecoder`` reassembles them). The
/// stream finishes on clean close (FIN) and throws on transport failure.
public protocol MuxByteLink: Sendable {
    /// Writes raw bytes; suspends until the OS/peer accepts them.
    func send(_ data: Data) async throws
    /// Enqueues raw bytes in CALL ORDER without waiting for the stack to accept them —
    /// FIFO with ``send(_:)`` on the same link. A write failure surfaces on the LINK
    /// failure path (`receiveChunks` finishes throwing → the mux reconnect machinery),
    /// never to the caller. In-flight bytes stay bounded by the per-channel credit window
    /// (debit-before-send), so pipelining cannot grow memory without bound.
    ///
    /// MUST be implemented as a SYNCHRONOUS enqueue — an internal `Task { await send }`
    /// hop breaks per-channel FIFO (the repo's recurring unstructured-Task ordering bug
    /// class) and would scramble flood-order tests nondeterministically.
    func sendPipelined(_ data: Data)
    /// A stream of raw inbound byte chunks (arbitrary boundaries).
    var receiveChunks: AsyncThrowingStream<Data, Error> { get }
    /// Tears the link down (cancels the underlying connection / closes the pipe end).
    func close() async
}
