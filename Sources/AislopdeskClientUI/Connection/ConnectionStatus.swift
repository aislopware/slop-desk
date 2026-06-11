import Foundation

/// The connection status the UI renders — shared by the app-global ``AppConnection`` (the one the
/// connect-gate + toolbar show) and the per-pane ``ConnectionViewModel`` (the channel-level dot).
///
/// Mirrors + extends the terminal status with the "deliberately disconnected" distinction the terminal
/// model can't make on its own. Hoisted out of `ConnectionViewModel` so one enum drives both the
/// app-wide gate and each pane's channel dot (docs/31 app-global connection).
public enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    /// A transport drop being retried by the supervisor (WF3 backoff). `attempt` is the 1-based campaign
    /// attempt; `nextRetry` (when set) is the instant the next attempt fires so the UI can render a live
    /// "retrying in Ns" countdown via a `TimelineView` tick — a `Date?` (not a live Int) keeps the case
    /// `Equatable`/`Sendable`. A bare drop (before the supervisor reports an attempt) uses
    /// `attempt: 0, nextRetry: nil` ("Reconnecting…").
    case reconnecting(attempt: Int, nextRetry: Date?)
    /// Terminal WF3 give-up: the reconnect campaign exhausted its attempts without reaching the host.
    /// Distinct from `.failed` (the *initial* connect timeout/refusal) — the *post-connect*
    /// host-died-and-stayed-dead state, so "connecting forever" becomes a visible "Unreachable".
    case unreachable
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case let .reconnecting(attempt, _):
            return attempt > 0 ? "reconnecting (\(attempt))" : "reconnecting"
        case .unreachable: return "unreachable"
        case .failed(let m): return "failed: \(m)"
        }
    }
}
