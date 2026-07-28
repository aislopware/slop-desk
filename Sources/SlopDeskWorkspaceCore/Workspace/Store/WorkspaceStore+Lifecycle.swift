import Foundation
import SlopDeskWorkspaceModel

/// Connection + session-retention lifecycle helpers for ``WorkspaceStore`` (R-lifecycle). Split into an
/// extension to keep the core store body within the lint budget, mirroring the existing `WorkspaceStore+*`
/// splits. Three concerns live here, and the first two are what the keep-all-mounted compositor exposed:
///   1. re-dialling pane channels that gave up while the app-global connection was down, once it (re)establishes;
///   2. keeping the previously-active session's surfaces MOUNTED across a session switch (LRU-bounded) so an
///      A→B→A round-trip does not repaint from the lossy ring;
///   3. WHETHER a pane may dial at all — the launch dial hold, which keeps a restored layout's pane ids
///      off the wire until the host has answered the `adoptWorkspace` that offers them.
@MainActor
extension WorkspaceStore {
    // MARK: - The launch dial hold

    /// Whether the panes on screen may open their host channels yet.
    ///
    /// SHOWING a pane and OPENING a shell for it are different acts, and the optimistic overlay only
    /// buys the first one. `HostServer` spawns a fresh PTY for ANY unknown non-zero session id
    /// (PATH B), so a pane that dials an id host truth does not carry gets a shell — and if the
    /// layout it belongs to is then replaced, that shell is abandoned with nobody attached.
    ///
    /// There is exactly one window per launch where that is a live risk, and it is the one op whose
    /// verdict this client cannot predict. `documentIsPristine` is a fact about the host's own file
    /// that no cell carries, so `adoptWorkspace` is staged OPTIMISTICALLY: for one round trip the
    /// window shows the layout read off `workspace.json` as if it were host truth. If the host
    /// already has a workspace, every one of those pane ids is about to be thrown away. Measured on
    /// hardware, one hostd and two launches with divergent ids: three panes on screen, SIX shells
    /// spawned.
    ///
    /// So: `false` from the moment the offer goes out until the host answers it, either way. That is
    /// bounded by the same `pendingTimeout` backstop every optimistic patch has — a host that accepts
    /// and dies before answering releases the hold three seconds later rather than never.
    ///
    /// `true` everywhere with nothing to wait for, which is every other configuration:
    /// - the offer is spent — accepted (these panes ARE host truth) or refused (the projection has
    ///   already moved to host truth, and its panes are the host's own),
    /// - it was never armed — the automation bootstrap owns its launch's layout and publishes it
    ///   itself, and the canvas model has no document at all,
    /// - there is no channel (headless, a unit test),
    /// - the channel is REFUSED or CLOSED: a definite answer that this host serves no document.
    ///   Holding past it would leave a window full of panes that never connect, which is strictly
    ///   worse than the churn,
    /// - the channel is LIVE with the offer still armed — the in-process loopback seam, whose
    ///   document adopted the very mirror this store seeded.
    ///
    /// Every OTHER intent that mints a pane (a split, a new tab, a reopened one) stays instant: the
    /// client proposes those ids (DECISIONS, Multi-client Phase 5 ruling 1) and its own applier has
    /// already agreed the host will take them, so their panes dial on the frame the user asked for.
    public var panesMayDial: Bool { paneDialGate }

    /// Recomputes the hold and, on the RELEASING edge, dials everything it was holding.
    ///
    /// Called from the four places that can move it: the mirror's own change hook (an `intentResult`
    /// or the frame that supersedes a patch), the channel's state changes, the offer going out, and
    /// the automation bootstrap taking over the launch.
    func refreshPaneDialGate() {
        let next = resolvedPaneDialGate()
        guard next != paneDialGate else { return }
        paneDialGate = next
        // The release is a STORE-level fan-out, not something only a mounted leaf can do. The leaf's
        // connect task re-fires on this same edge (its key moves off `nil`), but a pane in a satellite
        // window — or any leaf SwiftUI has not got to yet — would otherwise wait for an unrelated
        // event to nudge it. `connectIfNeeded()` no-ops on a healthy channel, so the overlap is free.
        if next { redialDisconnectedPanes() }
    }

    /// The rule behind ``panesMayDial``. See that doc for why each arm answers the way it does.
    private func resolvedPaneDialGate() -> Bool {
        // This launch's proposal is on the wire. What is on screen is a PREDICTION until the verdict
        // lands, so nothing in it may open a PTY.
        if let launchAdoptIntentID { return !workspaceMirror.isPending(launchAdoptIntentID) }
        guard pendingLaunchAdopt != nil else { return true }
        guard workspaceChannel != nil else { return true }
        switch workspaceChannelState {
        case .idle,
             .opening: return false
        case .live,
             .refused,
             .closed: return true
        }
    }

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
    /// connect-gate. A no-op for non-terminal (video / faked) handles. Unions in
    /// ``TreeWorkspace/detachedPaneIDs()`` (mirroring ``WorkspaceStore/reconcileTree()``'s desired-set union) so a
    /// satellite-window pane's channel redials too — otherwise it stays dead until a manual per-pane Reconnect.
    ///
    /// Held while this launch's offer is unanswered (``panesMayDial``): the app connection coming up
    /// is what STARTS the workspace subscription, so on a cold launch this fan-out runs before the
    /// host has said which panes exist. Dialling here would put the restored ids on the wire a moment
    /// before learning they are the wrong ones. ``refreshPaneDialGate()`` re-runs it on the release.
    public func redialDisconnectedPanes() {
        guard panesMayDial else { return }
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
