import Foundation

// WorkspaceConnectionAlert (C8 improvement 3) — the pure, `Equatable` fold of every live pane's PATH-1
// connection status into a compact "is anything wrong" summary. It backs the collapsed-sidebar connection
// indicator: with the tabs panel hidden (⌘⇧L) a dropped / reconnecting pane otherwise has no per-pane
// visible surface until the user re-opens the sidebar, so a tiny always-on-top chip answers "how many panes
// are unhealthy, how bad, and which one is worst (the click-to-focus target)" without re-opening it.
//
// `nil` (from `resolve(from:)`) ⇒ every pane is healthy — the chip renders nothing. Pure + value type so the
// fold (hidden-when-healthy, severity ranking, worst-pane tie-break) is unit-pinned headlessly, no view.

/// A compact connection-health summary across the workspace's live panes. `nil` from ``resolve(from:)``
/// means all panes are healthy (nothing to surface).
public struct WorkspaceConnectionAlert: Equatable, Sendable {
    /// The UNHEALTHY connection states, ordered by ascending salience (a higher `rawValue` is more urgent).
    /// Only these three raise the indicator — a `.connecting` initial dial, a deliberate `.disconnected`,
    /// and a live `.connected` are NOT alarms. Mirrors the sidebar rail's fold order
    /// (`unreachable > failed > reconnecting`).
    public enum Severity: Int, Sendable, Comparable {
        /// A transport drop the supervisor is retrying (amber — recovering).
        case reconnecting = 0
        /// The initial connect refused / timed out (red — down).
        case failed = 1
        /// The reconnect campaign gave up after the dead-host timeout (red — down).
        case unreachable = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How many panes are unhealthy (in any ``Severity``).
    public let count: Int
    /// The most-salient severity across the unhealthy panes — drives the indicator's dot colour.
    public let worst: Severity
    /// The pane the indicator focuses on click: the FIRST pane (in the caller's stable order) at the worst
    /// severity, so a click lands on the most-urgent affected pane.
    public let worstPane: PaneID

    public init(count: Int, worst: Severity, worstPane: PaneID) {
        self.count = count
        self.worst = worst
        self.worstPane = worstPane
    }

    /// Classify one pane's connection status into an alert severity, or `nil` when it is healthy / not an
    /// alarm — connected, an initial `.connecting` dial, a deliberate `.disconnected`, or no PATH-1
    /// connection at all (a video pane / faked handle, whose status is `nil`).
    public static func severity(of status: ConnectionStatus?) -> Severity? {
        switch status {
        case .reconnecting: .reconnecting
        case .failed: .failed
        case .unreachable: .unreachable
        case .connected,
             .connecting,
             .disconnected,
             .none: nil
        }
    }

    /// Fold live per-pane statuses into an alert, or `nil` when no pane is unhealthy. `entries` MUST be in a
    /// STABLE order (the store passes tree DFS order) so the worst-pane tie-break — "the FIRST pane at the
    /// worst severity" — is deterministic. A pane at a strictly higher severity supersedes the current worst;
    /// ties keep the earlier pane.
    public static func resolve(
        from entries: [(pane: PaneID, status: ConnectionStatus?)],
    ) -> Self? {
        var count = 0
        var worst: Severity?
        var worstPane: PaneID?
        for entry in entries {
            guard let severity = severity(of: entry.status) else { continue }
            count += 1
            if let current = worst {
                if severity > current {
                    worst = severity
                    worstPane = entry.pane
                }
            } else {
                worst = severity
                worstPane = entry.pane
            }
        }
        guard let worst, let worstPane else { return nil }
        return Self(count: count, worst: worst, worstPane: worstPane)
    }

    /// The compact chip label: the unhealthy count + the worst severity's word — "1 reconnecting",
    /// "2 disconnected", "1 unreachable". A `.failed` reads to the user as "disconnected" (an initial
    /// connect that never landed); `.unreachable` names the give-up state plainly.
    public var label: String {
        let word =
            switch worst {
            case .reconnecting: "reconnecting"
            case .failed: "disconnected"
            case .unreachable: "unreachable"
            }
        return "\(count) \(word)"
    }
}
