import AislopdeskProtocol
import Foundation

/// The exact surface ``AislopdeskClient/AislopdeskClient`` drives on its session transport: a logical
/// channel riding a shared ``MuxNWConnection`` (``MuxClientTransport``).
///
/// ## Why a protocol
/// `AislopdeskClient` takes an injectable `makeTransport` factory so the per-pane client can be backed
/// by a `MuxClientTransport` (bound to the per-host shared connection via the ``ConnectionRegistry``)
/// WITHOUT the per-message hot path (`sendInput`/`sendResize`/the inbound pump),
/// `ConnectionViewModel`, `LivePaneSession`, or `reconcile` knowing about the mux layer below.
///
/// All members are `async` (the live conformer is an `actor`); `inbound` is `nonisolated`.
public protocol ClientTransporting: Sendable {
    /// The authoritative session id learned from the handshake. `nil` until connected.
    var sessionID: UUID? { get async }
    /// The seq the host replayed from in the most recent handshake.
    var resumeFromSeq: Int64 { get async }
    /// Whether the host treated the most recent connect as a returning client.
    var returningClient: Bool { get async }

    /// Merged inbound stream of host→client messages (`output`/`exit`/`title`/`bell`).
    var inbound: AsyncThrowingStream<WireMessage, Error> { get }

    /// Connects (or resumes) the session and completes the handshake.
    func connect(
        host: String,
        port: UInt16,
        resume: UUID,
        lastReceivedSeq: Int64,
        handshakeTimeout: Duration,
    ) async throws

    /// Sends raw keystroke/paste bytes as `input`.
    func sendInput(_ bytes: Data) async throws
    /// Sends a `resize`.
    func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) async throws
    /// Sends an `ack` (highest contiguous output seq durably received).
    func sendAck(seq: Int64) async throws
    /// Sends a clean `bye`.
    func sendBye() async throws
    /// Sends an RTT probe (`ping`) on the control channel. Default no-op (fakes).
    func sendPing(timestampMS: UInt64) async throws

    /// Reports that the consumer actually CONSUMED `wireBytes` of data-class inbound
    /// (`output`/`exit`) — drives the mux receive-window re-grant (credit-at-consumption).
    /// Default no-op for transports without windowed flow control (fakes/tests).
    func noteOutputConsumed(wireBytes: Int) async

    /// Tears down the transport and finishes the inbound stream.
    func close() async
}

public extension ClientTransporting {
    /// Default no-op: only windowed transports (the mux) account consumption.
    func noteOutputConsumed(wireBytes _: Int) {}
    /// Default no-op: only the mux transport carries the RTT probe.
    func sendPing(timestampMS _: UInt64) {}
}
