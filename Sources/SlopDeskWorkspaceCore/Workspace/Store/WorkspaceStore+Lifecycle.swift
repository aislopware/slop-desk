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
    /// The rule is PROVENANCE: a pane may dial an id at the host that named it, and nowhere else.
    /// Two windows in a run put a layout on screen no attached host has confirmed, and they are the
    /// same window seen twice.
    ///
    /// **The launch.** `documentIsPristine` is a fact about the host's own file that no cell carries,
    /// so `adoptWorkspace` is staged OPTIMISTICALLY: for one round trip the window shows the layout
    /// read off `workspace.json` as if it were host truth. If the host already has a workspace, every
    /// one of those pane ids is about to be thrown away. Measured on hardware, one hostd and two
    /// launches with divergent ids: three panes on screen, SIX shells spawned.
    ///
    /// **The host switch.** Connecting to a SECOND machine inside one app run is the identical state
    /// with none of the launch's markers: what is on screen is the PREVIOUS host's document, the new
    /// one has published nothing, and every id in it is unknown there. Measured headlessly on the
    /// same rig, three panes settled at one host and the app pointed at another: six channels.
    ///
    /// So: `false` from the moment a proposal or a new host makes the layout unconfirmed until the
    /// attached host answers, either way. Both arms are bounded — the launch offer by the mirror's
    /// `pendingTimeout` sweep, everything else by ``paneDialHoldBackstop`` — because a hold with no
    /// release is a window of panes that never connect, which is strictly worse than the churn.
    ///
    /// `true` everywhere with nothing to wait for:
    /// - the document on screen is the ATTACHED host's own — it named these ids, including after a
    ///   refused offer (the projection has already moved to host truth) and across a wifi flap to the
    ///   same machine (a re-subscribe confirms nothing that host has not already said),
    /// - the automation bootstrap owns its launch's layout and publishes it itself, and the canvas
    ///   model has no document at all,
    /// - there is no channel (headless, a unit test),
    /// - the channel is REFUSED or CLOSED: a definite answer that this host serves no document,
    /// - the channel serves an in-process document, whose loopback adopted the very mirror this store
    ///   seeded.
    ///
    /// Every OTHER intent that mints a pane (a split, a new tab, a reopened one) stays instant: the
    /// client proposes those ids (DECISIONS, Multi-client Phase 5 ruling 1) and its own applier has
    /// already agreed the host will take them, so their panes dial on the frame the user asked for.
    public var panesMayDial: Bool { paneDialGate }

    /// The `host:port` this run is attached to now, or `""` before any target is committed (headless,
    /// a unit test) — the same "no host on it" reading ``documentCacheHostKey`` gives the empty key.
    var attachedHostKey: String {
        committedConnectionTarget.map { DevicePreferences.hostKey(for: $0) } ?? ""
    }

    /// Records which host confirmed the document now on screen, on the fold that delivered it.
    ///
    /// Driven by the mirror's change hook, and gated on the FOLD COUNT rather than on the hook
    /// firing: an optimistic patch, a fast-path push and a presence roster all announce themselves
    /// through the same callback, and any of them landing after a new target is committed but before
    /// the re-subscribe answers would stamp the previous host's layout with the new host's name.
    ///
    /// A `reset()` takes the count back to zero, which is exactly right — the subscription that
    /// vouched for those entries is gone.
    func noteFoldedDocumentProvenance() {
        let frames = workspaceMirror.documentFramesApplied
        guard frames != lastFoldedDocumentFrames else { return }
        lastFoldedDocumentFrames = frames
        // The store's own seed is not a host's answer; it is the question.
        guard frames > 0, workspaceMirror.documentEpoch != Self.seedEpoch else { return }
        dialConfirmedHostKey = attachedHostKey
    }

    /// Recomputes the hold and, on the RELEASING edge, dials everything it was holding.
    ///
    /// Called from the five places that can move it: the mirror's own change hook (an `intentResult`
    /// or the frame that supersedes a patch), the channel's state changes, the offer going out, the
    /// automation bootstrap taking over the launch, and a connect committing a new target.
    func refreshPaneDialGate() {
        let next = resolvedPaneDialGate()
        // The backstop belongs to the HOLD, not to the gate's edges: it is armed for as long as one
        // stands and cancelled the moment any answer arrives, so a hold that releases and re-engages
        // at a second host gets its own full window rather than the remainder of the first.
        if next {
            paneDialHoldBackstopTask?.cancel()
            paneDialHoldBackstopTask = nil
        } else {
            armPaneDialHoldBackstop()
        }
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
        // lands, so nothing in it may open a PTY. Bounded by the mirror's own pending sweep, which
        // drops the patch — and with it the layout nobody confirmed.
        if let launchAdoptIntentID, workspaceMirror.isPending(launchAdoptIntentID) { return false }
        // Nothing is coming, so nothing is waited for.
        guard let workspaceChannel else { return true }
        guard armedBootstrapEnvironment == nil else { return true }
        guard !workspaceChannel.servesLocalDocument else { return true }
        switch workspaceChannelState {
        // A host that does not serve `channelClass 1` is a host that will never publish a document,
        // so nothing about the layout on screen can ever be confirmed and holding for it would hold
        // for the life of the process.
        case .refused: return true
        // `.closed` is NOT that answer, and reading it as one is what makes a host switch churn: the
        // app tears the shared connection down BEFORE it commits the new target, so the state at the
        // moment ``WorkspaceStore/commitConnectionTarget(_:)`` recomputes the gate is `.closed` with
        // the PREVIOUS host's document still on screen. A dead subscription says nothing about whose
        // ids these are — the provenance below does, and a close with no reconnect behind it is what
        // ``paneDialHoldBackstop`` bounds.
        case .closed,
             .idle,
             .live,
             .opening: break
        }
        // PROVENANCE: the ids on screen were named by the host this run is attached to NOW.
        if dialConfirmedHostKey == attachedHostKey { return true }
        return paneDialHoldExpired
    }

    /// Arms the wall clock the current hold may not outlive. Idempotent: one timer per episode.
    private func armPaneDialHoldBackstop() {
        guard paneDialHoldBackstopTask == nil, !paneDialHoldExpired else { return }
        let delay = paneDialHoldBackstop
        paneDialHoldBackstopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            paneDialHoldBackstopTask = nil
            paneDialHoldExpired = true
            refreshPaneDialGate()
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
    /// Held while the layout on screen is unconfirmed by the attached host (``panesMayDial``): the
    /// app connection coming up is what STARTS the workspace subscription, so this fan-out runs
    /// before that host has said which panes exist — on a cold launch, and again on every connect to
    /// a different machine. Dialling here would put the wrong ids on the wire a moment before
    /// learning they are the wrong ones. ``refreshPaneDialGate()`` re-runs it on the release.
    public func redialDisconnectedPanes() {
        guard panesMayDial else { return }
        for id in tree.allPaneIDs() + tree.detachedPaneIDs() {
            guard let connection = (handle(for: id) as? LivePaneSession)?.connection else { continue }
            Task { @MainActor in await connection.connectIfNeeded() }
        }
    }

    /// Books the establish fan-out a second run, on the first document frame the ATTACHED host folds.
    ///
    /// A one-shot per establish. ``handleConnectionEstablished()`` dials what is on screen and then
    /// re-opens the subscription, which empties the mirror — so an establish that finds the mirror
    /// already empty (the previous one re-opened it and the link died again before the snapshot
    /// answered) has no pane set to fan across and no gate edge coming, because the host that
    /// confirmed those ids is still the host being dialled. This is the missing edge.
    func armPaneRedialOnDocument() {
        paneRedialAwaitsDocument = true
    }

    /// Fires that booking the moment the pane set is back on screen AND its provenance is settled —
    /// the one instant at which a fan-out is both possible and legitimate.
    ///
    /// Driven by the mirror's change hook, after the reconcile that materializes the leaves and after
    /// ``refreshPaneDialGate()``, so `handle(for:)` answers and the gate is current. Left armed while
    /// either half is missing: a hold released by ``paneDialHoldBackstop`` with no document behind it
    /// dials an empty tree, and disarming there would spend the booking on nothing.
    func redialArmedPanesOnConfirmedDocument() {
        guard paneRedialAwaitsDocument, panesMayDial else { return }
        guard dialConfirmedHostKey == attachedHostKey else { return }
        paneRedialAwaitsDocument = false
        redialDisconnectedPanes()
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
