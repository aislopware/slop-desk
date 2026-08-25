import CSlopDeskFFI
import SlopDeskWorkspaceModel

// WorkspaceConnectionAlert (C8 improvement 3) — the `Equatable` fold of every live pane's PATH-1
// connection status into a compact "is anything wrong" summary, as a face over
// `slopdesk_workspace::connection`.
//
// It backs the collapsed-sidebar connection indicator: with the tabs panel hidden (⌘⇧L) a dropped /
// reconnecting pane otherwise has no per-pane visible surface until the user re-opens the sidebar, so
// a tiny always-on-top chip answers "how many panes are unhealthy, how bad, and which one is worst
// (the click-to-focus target)" without re-opening it.
//
// `nil` (from `resolve(from:)`) ⇒ every pane is healthy — the chip renders nothing. What crosses is
// the STATUS CODES, in the caller's own order, and what comes back is a position in that same order:
// a `PaneID` is a UUID the crate has no use for, and the tie-break is positional anyway.

/// A compact connection-health summary across the workspace's live panes. `nil` from ``resolve(from:)``
/// means all panes are healthy (nothing to surface).
public struct WorkspaceConnectionAlert: Equatable, Sendable {
    /// The UNHEALTHY connection states, ordered by ascending salience (a higher `rawValue` is more urgent).
    /// Only these three raise the indicator — a `.connecting` initial dial, a deliberate `.disconnected`,
    /// and a live `.connected` are NOT alarms. Mirrors the sidebar rail's fold order
    /// (`unreachable > failed > reconnecting`); the raw values ARE the boundary's own severity codes.
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
    /// The compact chip label: the unhealthy count + the worst severity's word — "1 reconnecting",
    /// "2 disconnected", "1 unreachable". A `.failed` reads to the user as "disconnected" (an initial
    /// connect that never landed); `.unreachable` names the give-up state plainly.
    public let label: String

    public init(count: Int, worst: Severity, worstPane: PaneID, label: String) {
        self.count = count
        self.worst = worst
        self.worstPane = worstPane
        self.label = label
    }

    /// Classify one pane's connection status into an alert severity, or `nil` when it is healthy / not an
    /// alarm — connected, an initial `.connecting` dial, a deliberate `.disconnected`, or no PATH-1
    /// connection at all (a video pane / faked handle, whose status is `nil`).
    ///
    /// A pane with no connection crosses as `.disconnected`, which is the status that is not an alarm
    /// for the same reason: nothing is trying, so nothing has failed.
    public static func severity(of status: ConnectionStatus?) -> Severity? {
        let alert = resolve(codes: [status?.terms.code ?? SLOPDESK_CONNECTION_STATUS_DISCONNECTED])
        return alert.map(\.worst)
    }

    /// Fold live per-pane statuses into an alert, or `nil` when no pane is unhealthy. `entries` MUST be in a
    /// STABLE order (the store passes tree DFS order) so the worst-pane tie-break — "the FIRST pane at the
    /// worst severity" — is deterministic.
    public static func resolve(
        from entries: [(pane: PaneID, status: ConnectionStatus?)],
    ) -> Self? {
        let codes = entries.map { $0.status?.terms.code ?? SLOPDESK_CONNECTION_STATUS_DISCONNECTED }
        guard let found = resolve(codes: codes),
              let pane = entries[safe: found.worstIndex]?.pane else { return nil }
        return Self(count: found.count, worst: found.worst, worstPane: pane, label: found.label)
    }

    /// The crossing itself, in the door's own vocabulary: status codes in, a position back.
    ///
    /// `worstPane` is filled in by the caller from that position, which is why this answers an index
    /// and the public fold answers a `PaneID` — the crate has no use for a UUID, and the tie-break it
    /// is deciding is about ORDER rather than identity.
    private static func resolve(
        codes: [UInt32],
    ) -> (count: Int, worst: Severity, worstIndex: Int, label: String)? {
        var bytes = codes.map { UInt8(truncatingIfNeeded: $0) }
        let blob = bytes.withUnsafeMutableBufferPointer { lent in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_connection_alert(lent.baseAddress, lent.count, out, cap))
            }
        }
        let head = Int(SLOPDESK_WS_CONNECTION_ALERT_HEAD_BYTES)
        guard blob.count >= head else { return nil }
        let number = { (at: Int) in (0..<4).reduce(0) { $0 << 8 | Int(blob[at + $1]) } }
        guard let worst = Severity(rawValue: number(4)) else { return nil }
        let label = wsRuns(Array(blob.dropFirst(head)), count: 1)[0]
        return (count: number(0), worst: worst, worstIndex: number(8), label: label)
    }
}

private extension Array {
    /// The element at `index`, or `nil` where the door and the caller disagree about how many panes
    /// there were — which must lose the alert rather than focus whichever pane happens to be last.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
