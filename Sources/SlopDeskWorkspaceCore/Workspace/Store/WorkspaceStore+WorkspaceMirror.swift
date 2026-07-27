import Foundation
import SlopDeskProtocol
import SlopDeskTransport
import SlopDeskWorkspaceModel

// The store's side of the workspace document (docs/45 §7.2).
//
// Two directions. Outward: the per-pane control sinks write ``WorkspaceStore/workspaceMirror``'s
// FAST PATH — never `entries` — so the focused pane still paints sub-frame. Inward: the title chain
// reads back through the mirror, which is where host truth wins.
extension WorkspaceStore {
    // MARK: - Identity

    /// Pane `id`'s identity IN THE DOCUMENT — the HOST-minted pane id (the mux session id), which is
    /// not this client's ``PaneID``.
    ///
    /// They are different UUIDs and always were: a `PaneID` is minted HERE when the pane is created,
    /// while the document keys panes by the id the host mints on channel open. Reading the document
    /// under the local id would query a key host truth never writes — the whole document would land
    /// where nothing looks, and the two mirror layers would be keyed apart so the erasure rule that
    /// keeps them disjoint could never fire.
    ///
    /// ``PaneSpec/resumeSessionID`` is where the host's id already lands: `onResumeIdentitySnapshot`
    /// fires on every connect (not only under the detach flag) and the store persists it, so the
    /// mapping survives a relaunch exactly as the document does.
    ///
    /// Falls back to the LOCAL id for a pane that has never connected. Nothing host-side can be keyed
    /// by it, so an overlay written there is private to this client — which is correct, because before
    /// a connect there is no host truth to reconcile with. A pane whose next connect mints a DIFFERENT
    /// id (a resume that failed into a fresh shell) strands its old overlay under the old key, and
    /// ``pruneWorkspaceMirror(keeping:)`` collects it on the reconcile that follows.
    func documentPaneID(_ id: PaneID) -> UUID {
        let resumeID =
            switch liveModel {
            case .tree: tree.spec(for: id)?.resumeSessionID
            case .canvas: workspace.canvas.spec(for: id)?.resumeSessionID
            }
        return resumeID ?? id.raw
    }

    /// Records what the host told us about pane `id`'s session: the HOST-MINTED session id and the
    /// highest contiguous seq, so the next launch can feed both into `seedResumeIdentity` →
    /// RETURNING_CLIENT reattach.
    ///
    /// The same id is this pane's identity in the workspace document (``documentPaneID(_:)``), which
    /// is why the two sinks that used to write it inline share one funnel now — a second transcription
    /// would be free to drift, and this one decides where every mirror key for this pane goes.
    ///
    /// An id that CHANGED (a resume that failed into a fresh shell) strands the old key's overlay; the
    /// `reconcileTree` this write runs through prunes it in the same breath.
    func noteResumeIdentity(sessionID: UUID, seq: Int64, for id: PaneID) {
        updateSpecLive(id) { spec in
            guard spec.resumeSessionID != sessionID || spec.resumeLastReceivedSeq != seq else { return }
            spec.resumeSessionID = sessionID
            spec.resumeLastReceivedSeq = seq
        }
    }

    // MARK: - Fast-path producers

    /// Folds a wire-21 title push for `id`.
    ///
    /// Writes the title AND the freshness verdict, because the two are one fact: a title is only
    /// worth showing while the program that asserted it is still the one running. The verdict comes
    /// from ``PaneTitleFreshness`` — the SAME function the host evaluates — so the client's fallback
    /// answer and the host's authoritative one can never disagree by construction, only by having
    /// different stamps.
    ///
    /// Evaluated at the EDGE rather than at read time. That is the whole repair: the old read-time
    /// comparison needed two in-memory dictionaries that were empty on every app launch, so a title
    /// asserted before the relaunch could never be believed again — `nvim`'s title decaying back to
    /// `vi .` was exactly that.
    func noteTitlePushed(_ title: String, for id: PaneID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectID = documentPaneID(id)
        workspaceMirror.writeFastPath(pane: objectID, field: WorkspacePaneField.liveTitle, string: trimmed)
        workspaceMirror.writeFastPath(
            pane: objectID,
            field: WorkspacePaneField.titleFresh,
            bool: PaneTitleFreshness.isFresh(
                // The push IS the stamp — a title arriving now is, by definition, asserted now.
                titleStampedAt: Date().timeIntervalSinceReferenceDate,
                commandStartedAt: paneCommandStartedAt[id]?.timeIntervalSinceReferenceDate,
                liveness: .attached,
            ),
        )
    }

    /// Re-evaluates `id`'s title freshness after the COMMAND side of the comparison moved.
    ///
    /// A command starting makes the standing title stale (the new program has asserted nothing yet);
    /// a command finishing removes the start stamp, and a title with no command to postdate is
    /// trusted again — rule 1 of docs/45 §4.4, which is what keeps a hookless shell (Starship, a bare
    /// `sh`) from being permanently unable to show a program title.
    func refreshTitleFreshness(for id: PaneID) {
        let objectID = documentPaneID(id)
        let key = WorkspaceKey(.pane, objectID, WorkspacePaneField.liveTitle)
        // No title observed ⇒ no verdict to hold. Writing one would claim a fact about nothing.
        guard workspaceMirror.mirror.fastPath[key] != nil else { return }
        workspaceMirror.writeFastPath(
            pane: objectID,
            field: WorkspacePaneField.titleFresh,
            bool: PaneTitleFreshness.isFresh(
                // The stamp is unknown here — only that a title EXISTS. Zero is the earliest possible
                // instant, so a live command always wins and an absent one always yields.
                titleStampedAt: 0,
                commandStartedAt: paneCommandStartedAt[id]?.timeIntervalSinceReferenceDate,
                liveness: .attached,
            ),
        )
    }

    /// Drops a closed pane's whole overlay. Called from the reconcile prune, beside the other
    /// per-pane maps — an overlay for a leaf that no longer exists is unreachable memory.
    func pruneWorkspaceMirror(keeping leaves: Set<PaneID>) {
        let live = Set(leaves.map { documentPaneID($0) })
        for paneID in workspaceMirror.mirror.fastPathPaneIDs where !live.contains(paneID) {
            workspaceMirror.clearFastPath(pane: paneID)
        }
    }

    // MARK: - Reads

    /// The pane's PROGRAM-SET title, but only while it is FRESH — the title `nvim` asserted, not a
    /// leftover from whatever ran before it.
    ///
    /// Reads the mirror, so it answers from the HOST's verdict whenever the workspace document is
    /// live and from this client's own edge-computed one otherwise. `nil` when no title was ever
    /// observed, when the standing title predates the running command, or when the title was RETIRED
    /// (an empty wire-21 — the agent giving up ownership), which stays distinct from absent all the
    /// way down.
    ///
    /// The caller strips agent glyph prefixes (``RailRowsBuilder`` `strippedProgramTitle`).
    public func liveProgramTitle(for id: PaneID) -> String? {
        observeWorkspaceMirror()
        let objectID = documentPaneID(id)
        guard workspaceMirror.bool(.pane, objectID, WorkspacePaneField.titleFresh) else { return nil }
        let title = workspaceMirror.string(.pane, objectID, WorkspacePaneField.liveTitle)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    /// The pane's RUNNING command line — what a busy row titles itself by.
    ///
    /// The HOST's own open block leads, and this is the one liveness fact where that matters most.
    /// A returning client gets types 26/27/36 re-asserted for it (foreground process, agent status +
    /// label, session intent), so those recover on their own; the open command's TEXT does not. It
    /// lives in this client's ``CommandBlock`` model, which is per-MATERIALIZATION — a pane whose
    /// bytes were never rendered here has no blocks at all and no way to learn of any.
    ///
    /// Then this client's own newest open block, then `processLabel` (the caller's cleaned-up
    /// foreground-process name — the string rules stay in the UI target). `nil` when nothing is known,
    /// so the caller's remaining chain keeps resolving.
    ///
    /// No fast-path writer, deliberately: the block model IS this client's live copy of the fact, so
    /// an overlay entry would only be a second place for it to go stale.
    public func liveRunningCommand(for id: PaneID, processLabel: String?) -> String? {
        observeWorkspaceMirror()
        let hosted = workspaceMirror.string(.pane, documentPaneID(id), WorkspacePaneField.runningCommand)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let hosted, !hosted.isEmpty { return hosted }
        let open = commandBlocks(for: id).last { !$0.complete }?
            .commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open, !open.isEmpty { return open }
        return processLabel
    }
}

extension HostWorkspaceMirror {
    /// Every pane with an overlay entry. Distinct from ``paneIDs``, which enumerates the DOCUMENT.
    var fastPathPaneIDs: Set<UUID> {
        var ids = Set<UUID>()
        for key in fastPath.keys where key.kind == WorkspaceObjectKind.pane.rawValue { ids.insert(key.objectID) }
        return ids
    }
}

// MARK: - The workspace channel's lifecycle

public extension WorkspaceStore {
    /// Installs the workspace-document channel. `nil` (headless, tests, automation) leaves the store
    /// running on the control-push overlay alone, which is exactly the flag-off shape.
    func attachWorkspaceChannel(_ client: WorkspaceChannelClient?) {
        workspaceChannel?.stop()
        workspaceChannel = client
    }

    /// Opens (or re-opens) the channel for the connection that just established.
    ///
    /// Re-opening on every establish is deliberate: the previous subscription died with the old link,
    /// and the target may have CHANGED — a host that refused the class is not evidence about the next
    /// one. `stop()` clears the refusal for that reason.
    func startWorkspaceChannelIfEnabled() {
        guard let workspaceChannel, WorkspaceChannelClient.isEnabledByDefault else { return }
        workspaceChannel.stop()
        workspaceChannel.start()
    }

    func stopWorkspaceChannel() {
        workspaceChannel?.stop()
    }

    /// Builds the production channel and installs it. The app shell's one-liner.
    func installWorkspaceChannel(
        muxRegistry: ConnectionRegistry,
        target: @escaping @MainActor () -> ConnectionTarget,
    ) {
        attachWorkspaceChannel(Self.liveWorkspaceChannel(
            box: workspaceMirror,
            muxRegistry: muxRegistry,
            target: target,
        ))
    }

    /// Builds the production channel: `channelClass 1` on the app-global shared connection.
    ///
    /// The pool refcounts it exactly like a pane channel, so the workspace subscription holds the
    /// shared connection up on its own — which is what a client with every pane closed needs in
    /// order to keep rendering the rail.
    @MainActor
    static func liveWorkspaceChannel(
        box: WorkspaceMirrorBox,
        muxRegistry: ConnectionRegistry,
        target: @escaping @MainActor () -> ConnectionTarget,
        clientKind: WorkspaceClientKind = .thisPlatform,
        label: String = WorkspaceChannelClient.localDeviceLabel(),
    ) -> WorkspaceChannelClient {
        WorkspaceChannelClient(
            box: box,
            clientKind: clientKind,
            label: label,
            open: {
                let endpoint = await target()
                let acquisition = try await muxRegistry.acquire(
                    host: endpoint.host,
                    port: endpoint.port,
                    // The workspace document is not a pane, so it carries the zero session id and no
                    // resume position — there is no PTY behind it to reattach to.
                    sessionID: WireMessage.newSessionID,
                    lastReceivedSeq: 0,
                    channelClass: MuxChannelClass.workspace.rawValue,
                )
                return WorkspaceChannelClient.Handle(acquisition)
            },
            close: { channelID in
                let endpoint = await target()
                await muxRegistry.release(host: endpoint.host, port: endpoint.port, channelID: channelID)
            },
        )
    }
}
