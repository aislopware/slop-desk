import Foundation

/// Errors thrown by the transport layer (distinct from ``AislopdeskProtocol/AislopdeskError``,
/// which is decode-time). These wrap `Network.framework` failures and handshake faults.
public enum AislopdeskTransportError: Error, Equatable, Sendable {
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

extension AislopdeskTransportError {
    /// Whether a ``listenerFailed(_:)`` detail string indicates the bind failed because the
    /// address/port is already in use (POSIX `EADDRINUSE`, errno 48). The host-app classifier uses
    /// this to tell the operator "Port N is already in use" (actionable: change the port / kill the
    /// holder) instead of a generic "could not open port".
    ///
    /// Robust against the false positives a loose `contains("48")` produces: a port number like
    /// `4843`, a different errno like `148`, or a buffer size like `1048576` all embed the digits
    /// "48" but are NOT EADDRINUSE. The errno is therefore matched only as a STANDALONE token
    /// (digit-bounded on both sides), in addition to the canonical "in use" phrase that
    /// `String(describing: NWError.posix(.EADDRINUSE))` produces.
    public static func listenerDetailIndicatesAddressInUse(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        if lower.contains("in use") { return true }       // "Address already in use"
        return Self.containsStandaloneNumber(lower, 48)    // numeric rendering, e.g. "posix(48)"
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
    ///
    /// Pure (errno → Bool) so the "only EADDRINUSE is fatal; transient network errnos keep waiting"
    /// decision is unit-testable without standing up a real `NWListener` (the XCTest pool avoids real
    /// socket binds; the glue is exercised by the subprocess / hardware E2E paths).
    public static func waitingErrnoIsFatalBindConflict(_ posixErrno: Int32) -> Bool {
        posixErrno == EADDRINUSE   // 48 — the one waiting errno that never auto-recovers
    }

    /// True iff `s` contains the decimal `n` as a whole token — not as a substring of a longer run
    /// of digits. So `48` matches in `"errno 48"` / `"posix(48)"` but NOT in `"4843"` / `"148"` /
    /// `"1048576"`.
    static func containsStandaloneNumber(_ s: String, _ n: Int) -> Bool {
        let needle = String(n)
        var searchStart = s.startIndex
        while let range = s.range(of: needle, range: searchStart..<s.endIndex) {
            let beforeOK = range.lowerBound == s.startIndex
                || !s[s.index(before: range.lowerBound)].isNumber
            let afterOK = range.upperBound == s.endIndex
                || !s[range.upperBound].isNumber
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }
}

extension AislopdeskTransportError: LocalizedError {
    /// A short, human-readable summary for the UI failure surface (the pane status header /
    /// host-app status line). Without this, `error.localizedDescription` on a bare `enum: Error`
    /// produces a developer dump ("The operation couldn't be completed. (AislopdeskTransport… error 7.)")
    /// and `String(describing:)` shows the raw case payload (`timedOut("host handshake")`). The
    /// per-case detail string stays available for logs via the associated value; this is the
    /// user-facing line only. Keep these terse + actionable (no internal endpoints / enum syntax).
    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Connection failed"
        case .notConnected:     return "Not connected"
        case .sendFailed:       return "Failed to send data"
        case .receiveFailed:    return "Connection lost"
        case .listenerFailed:   return "Could not start the listener (port in use?)"
        case .handshakeFailed:  return "Handshake failed — is this an aislopdesk host?"
        case .invalidState:     return "Connection is in an invalid state"
        case .timedOut:         return "Connection timed out — host unreachable?"
        }
    }
}
