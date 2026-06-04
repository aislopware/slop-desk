import Foundation
import RworkProtocol

/// The exact surface ``RworkClient/RworkClient`` drives on its session transport — extracted
/// so the per-pane client can be backed EITHER by the today-shaped one-TCP-pair
/// ``ClientTransport`` (the default, byte-identical path) OR, behind the `RWORK_TCP_MUX`
/// gate, by a logical channel riding a shared ``MuxNWConnection`` (``MuxClientTransport``).
///
/// ## Why a protocol (and why this is OFF-path-safe)
/// `RworkClient` historically constructed `ClientTransport()` inline in `connect()`. Routing a
/// pane over a shared mux connection requires swapping *that one construction site* for a
/// different transport — WITHOUT touching the per-message hot path (`sendInput`/`sendResize`/
/// the inbound pump), `ConnectionViewModel`, `LivePaneSession`, or `reconcile`. This protocol is
/// that seam: `RworkClient` takes an injectable `makeTransport` factory defaulting to
/// `{ ClientTransport() }`, so with the gate unset the client allocates the *identical* concrete
/// `ClientTransport` it always did and every downstream call binds to the same methods — the OFF
/// path is provably unchanged. ``ClientTransport`` conforms with **zero** behavioural change
/// (the protocol is a strict subset of its existing async surface).
///
/// All members mirror `ClientTransport` exactly (including actor-isolation: the getters and
/// methods are `async` because the live conformer is an `actor`); `inbound` is `nonisolated`.
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
        handshakeTimeout: Duration
    ) async throws

    /// Sends raw keystroke/paste bytes as `input`.
    func sendInput(_ bytes: Data) async throws
    /// Sends a `resize`.
    func sendResize(cols: UInt16, rows: UInt16, pxWidth: UInt16, pxHeight: UInt16) async throws
    /// Sends an `ack` (highest contiguous output seq durably received).
    func sendAck(seq: Int64) async throws
    /// Sends a clean `bye`.
    func sendBye() async throws

    /// Tears down the transport and finishes the inbound stream.
    func close() async
}

// `ClientTransport`'s existing methods already match every requirement (same names,
// same async/throws shape, same defaults at the call sites). The conformance is a pure
// declaration — no method is added or changed, so the live one-TCP-pair path is untouched.
extension ClientTransport: ClientTransporting {}
