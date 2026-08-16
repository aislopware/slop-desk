import CSlopDeskFFI
import Foundation

/// Errors thrown by the transport layer (distinct from ``SlopDeskProtocol/SlopDeskError``,
/// which is decode-time). These wrap `Network.framework` failures and handshake faults.
public enum SlopDeskTransportError: Error, Equatable, Sendable {
    /// The underlying `NWConnection` failed or was cancelled before/while in use.
    case connectionFailed(String)
    /// A send was attempted on a channel/link that is already `.cancelled`/`.failed` (it is
    /// gone, not a transient send fault). Distinct from ``sendFailed(_:)`` so the relay can
    /// treat it as "client offline → replay on next reconnect" rather than a fatal error.
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

/// The bind-conflict classifier — a face over `slopdesk-workspace`'s `listen`.
///
/// Both questions were written twice, once here and once in Rust, down to the same three false
/// positives in the same comment. The Rust half had the tests and no caller; this half had the
/// caller. The standalone-token scan that made the difference — `48` matches in `"errno 48"` and
/// `"posix(48)"` but not in `"4843"`, `"148"` or `"1048576"` — is now spelled once, over there.
///
/// The port field's half of the same module is ``PortValidation``.
public extension SlopDeskTransportError {
    /// Whether a ``listenerFailed(_:)`` detail string indicates the bind failed because the
    /// address/port is already in use (POSIX `EADDRINUSE`, errno 48). The host-app classifier uses
    /// this to tell the operator "Port N is already in use" (actionable: change the port / kill the
    /// holder) instead of a generic "could not open port".
    static func listenerDetailIndicatesAddressInUse(_ detail: String) -> Bool {
        Array(detail.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_ws_listen_detail_is_address_in_use(bytes.baseAddress, bytes.count)
        }
    }

    /// Whether a listener sitting in Network.framework's `.waiting` state — its retryable
    /// "no usable network path yet" state — is actually parked on a NON-recoverable bind conflict
    /// (`EADDRINUSE`, errno 48) rather than a genuinely transient no-network condition.
    ///
    /// `.waiting` is normally retryable: DHCP not up yet, Wi-Fi joining, a VPN coming up. The
    /// framework watches for a path change and auto-recovers to `.ready` once one appears, so the
    /// host SHOULD keep waiting (bounded by the readiness timeout) — surfacing it as a failure would
    /// false-positive a host that merely started a half-second before the network did.
    ///
    /// The ONE exception is `EADDRINUSE`. On the common macOS path a port collision lands directly in
    /// `.failed(.posix(.EADDRINUSE))` (handled there). But the Network.framework state sequence is
    /// OS-version-dependent: on some versions the conflict instead STICKS in
    /// `.waiting(.posix(.EADDRINUSE))` and never progresses to `.failed`, and EADDRINUSE never
    /// auto-recovers to `.ready` (another process owns the port — only a fresh listener on a free
    /// port helps). Treating ONLY that errno as fatal-in-waiting lets the host surface an immediate,
    /// accurate "port in use" instead of burning the full readiness timeout and then mis-reporting a
    /// generic "timed out" for what is really a bind collision. Every other waiting errno
    /// (`ENETDOWN`, `ENETUNREACH`, `ETIMEDOUT`, `EAGAIN`, …) keeps waiting.
    static func waitingErrnoIsFatalBindConflict(_ posixErrno: Int32) -> Bool {
        slopdesk_ws_listen_waiting_errno_is_fatal(posixErrno)
    }
}

extension SlopDeskTransportError: LocalizedError {
    /// A short, human-readable summary for the UI failure surface (the pane status header /
    /// host-app status line). Without this, `error.localizedDescription` on a bare `enum: Error`
    /// produces a developer dump ("The operation couldn't be completed. (SlopDeskTransport… error 7.)")
    /// and `String(describing:)` shows the raw case payload (`timedOut("host handshake")`). The
    /// per-case detail string stays available for logs via the associated value; this is the
    /// user-facing line only. Keep these terse + actionable (no internal endpoints / enum syntax).
    public var errorDescription: String? {
        switch self {
        case .connectionFailed: "Connection failed"
        case .notConnected: "Not connected"
        case .sendFailed: "Failed to send data"
        case .receiveFailed: "Connection lost"
        case .listenerFailed: "Could not start the listener (port in use?)"
        case .handshakeFailed: "Handshake failed — is this an slopdesk host?"
        case .invalidState: "Connection is in an invalid state"
        case .timedOut: "Connection timed out — host unreachable?"
        }
    }
}
