import Foundation

/// Connection + session-retention lifecycle helpers for ``WorkspaceStore`` (R-lifecycle). Split into an
/// extension to keep the core store body within the lint budget, mirroring the existing `WorkspaceStore+*`
/// splits. These cover two keep-alive concerns the keep-all-mounted compositor exposed:
///   1. re-dialling pane channels that gave up while the app-global connection was down, once it (re)establishes;
///   2. keeping the previously-active session's surfaces MOUNTED across a session switch (LRU-bounded) so an
///      A→B→A round-trip does not repaint from the lossy ring.
@MainActor
extension WorkspaceStore {
    // MARK: - Re-dial on app-connection (re)establish (R-lifecycle #1)

    /// Re-dials EVERY live terminal pane whose channel is stuck disconnected/failed/unreachable — the recovery
    /// fan-out the app shell invokes when the app-global connection (re)establishes
    /// (``AppConnection/onConnectionEstablished``). The per-pane channel's only automatic dial trigger is the
    /// leaf's connect-on-appear `.task`, which does NOT re-fire under keep-all-mounted (the live id is stable),
    /// so a pane that gave up to `.failed`/`.unreachable` while the host was down would otherwise stay a dead,
    /// blank terminal behind a green "Connected" pill until a manual per-pane Reconnect. Each channel is routed
    /// through ``ConnectionViewModel/connectIfNeeded()``, which NO-OPS on a healthy / in-flight / supervised
    /// channel and only actually dials a genuinely idle/dead one — so it is safe to fan across every pane. Only
    /// reachable once the app connection is up (its sole caller), so a channel build never races the
    /// connect-gate. A no-op for non-terminal (`.remoteGUI` / faked) handles. Unions in
    /// ``TreeWorkspace/detachedPaneIDs()`` (mirroring ``WorkspaceStore/reconcileTree()``'s desired-set union) so a
    /// satellite-window pane's channel redials too — otherwise it stays dead until a manual per-pane Reconnect.
    public func redialDisconnectedPanes() {
        for id in tree.allPaneIDs() + tree.detachedPaneIDs() {
            guard let connection = (handle(for: id) as? LivePaneSession)?.connection else { continue }
            Task { @MainActor in await connection.connectIfNeeded() }
        }
    }

    // MARK: - Session-retention LRU (R-lifecycle #3)

    /// Active session + previous — the minimum that makes an A→B→A switch loss-free without pinning every
    /// session's surfaces on-window. Beyond this the LRU evicts the least-recently-active session.
    static var retainedSessionCap: Int { 2 }

    /// Pure LRU push for ``retainedSessionIDs``: promote the newly-`selected` session to the front, KEEP the
    /// `previous` (outgoing) active session retained behind it (seeding it on the first switch away — it was
    /// never itself `selected` via this path), dedupe, and cap at `cap`.
    static func pushingSessionRetention(
        _ selected: SessionID,
        previous: SessionID?,
        into list: [SessionID],
        cap: Int = retainedSessionCap,
    ) -> [SessionID] {
        var out = list
        if let previous, !out.contains(previous) { out.insert(previous, at: 0) }
        out.removeAll { $0 == selected }
        out.insert(selected, at: 0)
        if out.count > cap { out.removeLast(out.count - cap) }
        return out
    }

    /// Records that the active session changed to `selected` (from `previous`) into the retention LRU so the
    /// outgoing session's surfaces stay mounted across the switch.
    func noteActiveSessionChanged(to selected: SessionID, from previous: SessionID?) {
        retainedSessionIDs = Self.pushingSessionRetention(selected, previous: previous, into: retainedSessionIDs)
    }

    /// Drops a closed session from the retention LRU and re-seeds the now-active session so it renders.
    func noteSessionClosed(_ sessionID: SessionID) {
        retainedSessionIDs.removeAll { $0 == sessionID }
        if let active = tree.activeSessionID {
            retainedSessionIDs = Self.pushingSessionRetention(active, previous: nil, into: retainedSessionIDs)
        }
    }
}
