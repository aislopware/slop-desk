import Foundation

/// Client-side errors surfaced by ``AislopdeskClient`` and ``ReconnectManager``.
public enum ClientError: Error, Equatable, Sendable {
    /// An operation was attempted from a state that does not permit it — e.g. sending
    /// `input`/`resize` before the first `connect`, `resume` before any `connect`, or
    /// `connect` after `close`. The associated string names the offending call site.
    case invalidState(String)
    /// The host's `helloAck` did not match what we expected (e.g. version mismatch).
    case handshakeRejected(String)
    /// Every reconnect attempt in a bounded campaign failed; the supervisor gave up.
    case reconnectExhausted
}
