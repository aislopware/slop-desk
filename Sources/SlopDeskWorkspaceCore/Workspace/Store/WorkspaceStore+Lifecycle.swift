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
    public var panesMayDial: Bool {
        observeWorkspaceMirror()
        return core.panesMayDial
    }

    /// The `host:port` this run is attached to now, or `""` before any target is committed (headless,
    /// a unit test) — the same "no host on it" reading the cache's empty key gives.
    var attachedHostKey: String {
        committedConnectionTarget.map { DevicePreferences.hostKey(for: $0) } ?? ""
    }

    /// What the core reads the live channel as.
    ///
    /// The collapse is deliberate and its reasoning lives on ``WorkspaceCoreHandle/Channel``: a
    /// `.closed` subscription is not an answer about whose ids are on screen, so it rides with the
    /// live states rather than with `.refused`.
    private var coreChannel: WorkspaceCoreHandle.Channel {
        guard let workspaceChannel else { return .absent }
        if workspaceChannel.servesLocalDocument { return .localDocument }
        switch workspaceChannelState {
        case .refused: return .refused
        case .closed,
             .idle,
             .live,
             .opening: return .attached
        }
    }

    /// The three facts the gate needs whose owners the core has never seen, read fresh.
    ///
    /// A computed property and never a stored one: each of these moves without announcing itself to
    /// anything the core could observe, so the reading has to be taken at the call rather than
    /// pushed. The offer's in particular — a frame retiring the optimistic patch and an
    /// `intentResult` snapping it away are both verdicts, and neither writes anything else down.
    var coreInputs: WorkspaceCoreHandle.Inputs {
        WorkspaceCoreHandle.Inputs(
            channel: coreChannel,
            bootstrapArmed: armedBootstrapEnvironment != nil,
            offerPending: launchAdoptIntentID.map { workspaceMirror.isPending($0) } ?? false,
        )
    }

    /// Recomputes the hold against the inputs as they stand, and performs whatever the core answers.
    ///
    /// Called from the four places that move an input without folding a frame: the channel's own
    /// state changes, the offer settling, the automation bootstrap taking over the launch, and a
    /// connect committing a new target. The fifth — the mirror's change hook — goes through
    /// ``applyDocumentFrame()``, which folds this in.
    func refreshPaneDialGate() {
        applyGateEdge(core.refreshDialGate(coreInputs))
    }

    /// Folds one document frame: the core stamps the provenance, recomputes the hold, and answers
    /// whether the booked re-dial came due. This side runs the effects and nothing else.
    func applyDocumentFrame() {
        let edge = core.noteDocumentFrame(
            coreInputs,
            framesApplied: workspaceMirror.documentFramesApplied,
            epochIsSeed: workspaceMirror.documentEpoch == Self.seedEpoch,
        )
        applyGateEdge(edge.gate)
        // Fired at the one instant a fan-out is both possible and legitimate — the pane set is back
        // on screen and its provenance is settled — rather than on whichever of the two arrived last.
        if edge.redialBookingFired { redialDisconnectedPanes() }
    }

    /// Performs a gate edge: the timer this side owns, and the fan-out only this side can walk.
    ///
    /// The release is a STORE-level fan-out, not something only a mounted leaf can do. A mounted
    /// leaf's own arm re-fires on this same edge (its connect key moves off `nil`), but a pane in a
    /// satellite window — or any leaf the canvas has not mounted yet — would otherwise wait for an
    /// unrelated event to nudge it. `connectIfNeeded()` no-ops on a healthy channel, so the overlap
    /// is free.
    func applyGateEdge(_ edge: WorkspaceCoreHandle.GateEdge) {
        switch edge.backstop {
        case .arm: armPaneDialHoldBackstop()
        case .cancel:
            paneDialHoldBackstopTask?.cancel()
            paneDialHoldBackstopTask = nil
        case .leave: break
        }
        guard edge.changed else { return }
        // The core already moved its counter for this edge — `panesMayDial` is read through the same
        // memo key the document's projections are. All that is left here is republishing it.
        publishRevision(core.revision)
        if edge.opened { redialDisconnectedPanes() }
    }

    /// Arms the wall clock the current hold may not outlive. One timer per episode — the core answers
    /// ``WorkspaceCoreHandle/Backstop/arm`` exactly once, so this needs no idempotence guard of its
    /// own beyond the handle it replaces.
    private func armPaneDialHoldBackstop() {
        let delay = paneDialHoldBackstop
        paneDialHoldBackstopTask?.cancel()
        paneDialHoldBackstopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            paneDialHoldBackstopTask = nil
            applyGateEdge(core.noteBackstopExpired(coreInputs))
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
        core.armRedialOnDocument()
    }

    // MARK: - Session-retention LRU (R-lifecycle #3)

    /// Active session + previous — the minimum that makes an A→B→A switch loss-free without pinning every
    /// session's surfaces on-window. Beyond this the LRU evicts the least-recently-active session.
    static var retainedSessionCap: Int { 2 }

    /// Records that the active session changed to `selected` (from `previous`) into the retention LRU so the
    /// outgoing session's surfaces stay mounted across the switch.
    ///
    /// The push is ``RecentsRing/pushing(_:into:cap:retaining:)`` — the one dedupe-to-front-and-cap every
    /// ring in the store runs — with the outgoing session as the `retaining` half, which is what seeds it
    /// on the first switch away (it was never itself selected through this path).
    func noteActiveSessionChanged(to selected: SessionID, from previous: SessionID?) {
        retainedSessionIDs = RecentsRing.pushing(
            selected, into: retainedSessionIDs, cap: Self.retainedSessionCap, retaining: previous,
        )
    }

    /// Drops a closed session from the retention LRU and re-seeds the now-active session so it renders.
    func noteSessionClosed(_ sessionID: SessionID) {
        retainedSessionIDs.removeAll { $0 == sessionID }
        if let active = tree.activeSessionID {
            retainedSessionIDs = RecentsRing.pushing(
                active, into: retainedSessionIDs, cap: Self.retainedSessionCap,
            )
        }
    }
}
