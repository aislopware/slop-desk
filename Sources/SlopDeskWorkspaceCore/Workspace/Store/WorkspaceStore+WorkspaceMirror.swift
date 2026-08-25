import Foundation
import SlopDeskProtocol
import SlopDeskTerminal
import SlopDeskTransport
import SlopDeskWorkspaceModel

// The store's side of the workspace document (docs/45 §7.2).
//
// Two directions. Outward: the per-pane control sinks write ``WorkspaceStore/workspaceMirror``'s
// FAST PATH — never `entries` — so the focused pane still paints sub-frame. Inward: the title chain
// reads back through the mirror, which is where host truth wins.
extension WorkspaceStore {
    // MARK: - Identity

    /// Pane `id`'s identity IN THE DOCUMENT — its own ``PaneID``, verbatim.
    ///
    /// One namespace, by construction. The client PROPOSES object ids (DECISIONS, Multi-client
    /// Phase 5 ruling 1) and presents each pane's id as the mux session id on `channelOpen`, so the
    /// host files that pane's liveness under the very key the topology names it by. Two namespaces
    /// with a translation table between them is what made an overlay and host truth land on different
    /// keys — where the erasure rule that keeps the two mirror layers disjoint could never fire.
    ///
    /// Kept as a named funnel rather than inlining `id.raw` at forty call sites: it is the sentence
    /// "the document calls this pane what we call it", and it belongs somewhere it can be read.
    func documentPaneID(_ id: PaneID) -> UUID { id.raw }

    // MARK: - Seeding

    /// The epoch a SEEDED mirror carries: the zero UUID, the wire's "none".
    ///
    /// It has to be a value that is not a document identity, because everything scoped BY the document
    /// epoch — the device's `seenCompletionEpoch` map above all — would otherwise read the seed as "a
    /// different document" and throw itself away on every single launch.
    static let seedEpoch = WireMessage.newSessionID

    /// Encodes `tree` into ``workspaceMirror`` as a kind-0 snapshot at state 1 — the store's own
    /// layout, published to itself — with `cache`'s per-pane facts folded back in.
    ///
    /// A SNAPSHOT rather than a diff because the mirror has nothing to diff against yet. The first real
    /// host frame carries the HOST's epoch, which differs from ``seedEpoch``, so it resets the mirror
    /// and replaces the seed wholesale rather than diffing onto a document the host never wrote.
    ///
    /// `cache` (``WorkspaceCacheStore``, docs/45 §7.3) lands in TWO layers, and the split is the whole
    /// correctness argument:
    /// - `pane/spawnCwd` is a TOPOLOGY fact — where this pane's shell is asked to start — so it joins
    ///   the seeded topology. Without it a relaunch respawns every pane in `$HOME` instead of its
    ///   project directory, because the client has no live shell left to ask.
    /// - `pane/cwd` and `pane/projectKey` are LIVENESS: they describe where a shell IS. They go to the
    ///   FAST PATH, where the erasure rule deletes them for any key the first host frame supplies —
    ///   so a cached folder name paints the rail instantly and is replaced, never promoted.
    ///
    /// Facts for panes the restored tree no longer contains are dropped: a cached row with no leaf to
    /// hang on is unreachable memory that the next save would write out again.
    ///
    /// - Returns: the topology it seeded — the tree WITH the cached spawn directories on it. That is
    ///   the value ``WorkspaceStore/runArmedLaunchAdoptIfPossible()`` offers a pristine host, and it
    ///   has to be captured here: by the time the offer goes out the mirror holds the host's own first
    ///   frame, which has already replaced these entries.
    @discardableResult
    func seedWorkspaceMirror(
        from tree: TreeWorkspace,
        cache: HostWorkspaceState = HostWorkspaceState(),
    ) -> WorkspaceTopology {
        var topology = WorkspaceTopology(tree: tree)
        let livePanes = Set(tree.allPaneIDs()).union(tree.detachedPaneIDs())
        for pane in livePanes {
            let key = WorkspaceKey(.pane, documentPaneID(pane), WorkspacePaneField.spawnCwd)
            guard let cwd = cache[key].flatMap({ WorkspaceStateCodec.decodeString($0) }), !cwd.isEmpty
            else { continue }
            topology.spawnCwd[pane] = cwd
        }
        var state = HostWorkspaceState()
        state.write(topology: topology)
        workspaceMirror.apply(
            kind: WorkspaceEventKind.snapshot.rawValue,
            epoch: Self.seedEpoch,
            baseStateNum: 0,
            newStateNum: 1,
            payload: WorkspaceStateCodec.encodeSnapshot(state),
        )
        for pane in livePanes {
            for field in [WorkspacePaneField.cwd, WorkspacePaneField.projectKey] {
                let key = WorkspaceKey(.pane, documentPaneID(pane), field)
                guard let value = cache[key] else { continue }
                workspaceMirror.writeFastPath(key, value)
            }
        }
        return topology
    }

    /// The three per-pane facts the cache carries: where the shell STARTS (`pane/spawnCwd`), where it
    /// IS (`pane/cwd`), and which project that puts it in (`pane/projectKey`).
    static let cachedPaneFields: [UInt8] = [
        WorkspacePaneField.spawnCwd,
        WorkspacePaneField.cwd,
        WorkspacePaneField.projectKey,
    ]

    /// What ``WorkspaceCacheStore`` writes — exactly the rows ``seedWorkspaceMirror(from:cache:)``
    /// reads back, for exactly the panes that still exist.
    ///
    /// Read off `resolved` rather than `entries`, because with the workspace document off `entries`
    /// holds only the launch seed: every folder name the control pushes have landed since lives in
    /// the fast path, and those are the ones the next cold launch needs.
    ///
    /// Scoped to the live leaves plus the reopen ring for two reasons. A cached row for a pane no
    /// loader will ever look up is a file that only grows; and while the client still owns the tree,
    /// the layout half of the mirror is a launch-time seed rather than a picture of anything, so
    /// writing it out would persist a snapshot of the tree as it was at launch under the name of the
    /// document.
    func documentFactsSnapshot() -> HostWorkspaceState {
        let live = Set(tree.allPaneIDs()).union(tree.detachedPaneIDs())
        let ids = Set(live.map { documentPaneID($0) }).union(reopenableDocumentPaneIDs())
        let resolved = workspaceMirror.mirror.resolved
        var out = HostWorkspaceState()
        for id in ids {
            for field in Self.cachedPaneFields {
                let key = WorkspaceKey(.pane, id, field)
                guard let value = resolved[key], !value.isEmpty else { continue }
                out.set(key, value)
            }
        }
        // Re-filtered through the file's own policy, which is where "what may touch the disk" lives.
        return WorkspaceStateFile.persisting(out)
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
        // A title that trims to nothing is written as the empty string, not skipped: an empty
        // wire-21 is the agent RETIRING its title, which stays distinct from absent all the way down.
        let trimmed = SupervisionFold.normalized(title) ?? ""
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
    ///
    /// The reopen-closed-tab ring counts as live. Its records keep the original ``PaneID``s, so a
    /// ⇧⌘T restores the very panes this sweep just saw leave the tree; reaping their facts here
    /// would bring each one back with no cwd and no spawn directory. It is also the rule the HOST's
    /// applier already follows (`WorkspaceIntentApplier.pruned` unions `closedTabs`), and the two
    /// answering differently is the divergence the document exists to end.
    func pruneWorkspaceMirror(keeping leaves: Set<PaneID>) {
        let live = Set(leaves.map { documentPaneID($0) })
            .union(reopenableDocumentPaneIDs())
        for paneID in workspaceMirror.mirror.fastPathPaneIDs where !live.contains(paneID) {
            workspaceMirror.clearFastPath(pane: paneID)
        }
    }

    /// The document ids of every pane a ⇧⌘T could bring back.
    func reopenableDocumentPaneIDs() -> Set<UUID> {
        Set(closedTabRecords.flatMap { $0.specs.keys.map { documentPaneID($0) } })
    }

    // MARK: - Reconciling what the document changed

    /// Diffs the registry against the layout a DOCUMENT change just produced.
    ///
    /// ``WorkspaceStore/tree`` is a projection, so the leaf set moves with no local gesture behind it:
    /// another client splits, the host's first snapshot after a subscribe replaces the launch seed with
    /// pane ids this device has never seen, an optimistic patch rolls back. Each of those has to reach
    /// the registry — a leaf the document added needs a live session, and one it removed must not keep
    /// its mux channel open forever. Every mutator reconciles on its own next line, which is exactly
    /// what made this look covered.
    ///
    /// A reconcile ALREADY RUNNING skips: it clears the overlay of every pane it orphaned, each clear
    /// announces itself, and the pass in flight is the one that owns the diff.
    ///
    /// So does the ABSENCE of a document, which is not an empty one. ``WorkspaceChannelClient/stop()``
    /// resets the mirror on the way to every re-subscribe; reconciling against the zero sessions that
    /// leaves would tear down every live pane and rebuild it from the snapshot a moment later, so a
    /// reconnect would dismantle every terminal on screen and replay it back.
    func reconcileTreeFromDocument() {
        // The four refusals are one rule — `slopdesk-workspace::mirror_fold::reconcile_admitted`,
        // where each is written out. What stays here is reading the four facts off the store: a pass
        // already in flight, no projection at all, an armed bootstrap, and an outstanding launch
        // adopt against a REAL host document (this client's own seed IS the tree on offer, so there
        // is nothing to hold against — and a host that refuses `channelClass 1` would otherwise stop
        // this client reconciling for good).
        guard MirrorFold.reconcileAdmitted(
            reconciling: isReconcilingTree,
            projected: mirroredTopology != nil,
            bootstrapArmed: armedBootstrapEnvironment != nil,
            adoptPending: pendingLaunchAdopt != nil,
            epochIsSeed: workspaceMirror.knownEpoch == Self.seedEpoch,
        ) else { return }
        reconcileTree(acknowledgingFocus: false)
    }

    /// Updates the spec for `id` in the tree's side table. Used by the pane-rebind wiring so a committed
    /// endpoint persists.
    ///
    /// The spec belongs to the document, so the transform is run against the current
    /// value and the RESULT is expressed as an intent. Two spec fields have one: an AUTHORED title
    /// (`renamePane`, which writes the `userRenamed` flag that is what "authored" means) and the VIDEO
    /// BINDING (`setPaneVideoTarget` — the pane-rebind sink's whole job, since a display switch or a
    /// window re-pick moves a stream that is already running).
    ///
    /// A DERIVED title needs no op of its own: it follows the binding, and the applier renames the
    /// pane alongside the re-point. Sending it as a rename instead would set the authorship flag and
    /// make the NEXT re-pick unable to update it. Anything else a transform touches is named in the
    /// debug log rather than dropped silently, because a spec field with no intent behind it is a fact
    /// this client cannot publish and the next host frame will erase.
    func updateSpecLive(_ id: PaneID, _ transform: (inout PaneSpec) -> Void) {
        guard var spec = tree.spec(for: id) else { return }
        let before = spec
        transform(&spec)
        guard spec != before else { return }
        switch MirrorFold.specIntent(
            videoMoved: spec.video != before.video,
            userRenamed: spec.userRenamed,
            titleMoved: spec.title != before.title,
            wasUserRenamed: before.userRenamed,
        ) {
        case .videoTarget:
            guard stage(.setPaneVideoTarget, WorkspaceIntentArgs.encode(
                pane: id, video: spec.video,
            )) else { return }
        case .rename:
            guard stage(.renamePane, WorkspaceIntentArgs.encode(id: id.raw, name: spec.title)) else { return }
        case .refused:
            logIntentRefusal(.renamePane, "spec change with no intent for pane \(id.raw)")
            return
        }
        reconcileTree()
    }

    // MARK: - Presence

    /// Publishes this client's VIEW on the workspace channel — which tab and pane it is looking at.
    ///
    /// Driven from the reconcile funnel: every tab switch, rail click and pane focus passes through
    /// it, and reporting at the individual gestures instead would miss whichever one gets added next. The channel's own dirty guard drops the reconciles
    /// that changed something other than the view.
    ///
    /// The pane and the tab both travel as their own ids — the client proposes object ids, so the
    /// roster names the same objects every other client's topology does.
    ///
    /// `cols`/`rows` stay zero. Phase 4's subscribe declares no `contributesSize`, so a number here
    /// would be an offer nobody folds — and inventing one is how the first client that DOES fold it
    /// ends up letterboxing against a fiction.
    func publishWorkspacePresence() {
        guard let workspaceChannel else { return }
        let view = currentWorkspaceView()
        workspaceChannel.updatePresence(
            viewingTabID: view.tabID, viewingPaneID: view.paneID, cols: 0, rows: 0,
        )
    }

    /// What ``publishWorkspacePresence()`` would report, as a value — so the report is pinnable with
    /// no socket in sight. A tab with no active pane reports the ZERO id, which the roster reads as
    /// "looking at no pane in particular".
    func currentWorkspaceView() -> WorkspaceViewReport {
        let tab = tree.activeSession?.activeTab
        return WorkspaceViewReport(
            tabID: tab?.id.raw ?? WireMessage.newSessionID,
            paneID: tab?.activePane.map { documentPaneID($0) } ?? WireMessage.newSessionID,
        )
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
    /// The caller normalizes agent glyph prefixes (``RailRowsBuilder`` `normalizedProgramTitle`).
    public func liveProgramTitle(for id: PaneID) -> String? {
        observeWorkspaceMirror()
        let objectID = documentPaneID(id)
        guard workspaceMirror.bool(.pane, objectID, WorkspacePaneField.titleFresh) else { return nil }
        // A RETIRED title (the empty wire-21) and a title of pure whitespace are both absence here.
        return SupervisionFold.normalized(workspaceMirror.string(.pane, objectID, WorkspacePaneField.liveTitle))
    }

    /// The banner/toast title for a command that just finished in pane `id`
    /// (``PaneLabel/completionNotificationTitle(title:cwd:liveTitle:)``), resolved against the mirror.
    ///
    /// Reads the FRESHNESS-GATED ``liveProgramTitle(for:)`` rather than raw `pane/liveTitle`: a banner
    /// naming the program that ran BEFORE this command is worse than one naming the folder.
    func completionNotificationTitle(for id: PaneID) -> String {
        let paneSpec = tree.spec(for: id)
        return PaneLabel.completionNotificationTitle(
            title: paneSpec?.title ?? "",
            cwd: paneCwd(for: id),
            liveTitle: liveProgramTitle(for: id),
        )
    }

    /// The labels of the OTHER clients currently looking at pane `id`, in roster order.
    ///
    /// VIEWING is a separate fact from HOLDING, and both are worth saying. A client can have a pane
    /// on screen with no channel on it (the tab it last looked at), and it can hold a channel on a
    /// pane it is not showing. ``paneHolders(for:)`` answers the other question.
    public func paneViewers(for id: PaneID) -> [String] {
        observeWorkspaceMirror()
        let objectID = documentPaneID(id)
        guard let roster = workspaceMirror.roster, let mine = workspaceChannel?.clientInstanceID
        else { return [] }
        var tokens = RosterTokens()
        let clients = roster.clients.map { client in
            MirrorFold.PresenceClient(
                token: tokens.token(for: client.clientInstanceID),
                labelled: !client.label.isEmpty,
                viewing: client.viewingPaneID == objectID,
            )
        }
        return MirrorFold.viewers(clients, own: tokens.token(for: mine)).compactMap { position in
            roster.clients.indices.contains(position) ? roster.clients[position].label : nil
        }
    }

    /// What an attachment with no workspace channel behind it is called.
    ///
    /// `slopdesk-client` opens no workspace channel, so the host publishes its attachment with the
    /// all-zero `clientInstanceID` and nothing can name it. It is still a real client holding a real
    /// pane at a real size — the honest readout is "somebody", never silence.
    public static let unlabelledHolder = "another client"

    /// The labels of the OTHER clients holding a channel on pane `id`, in roster order.
    ///
    /// Reads the roster's `panes` half — one `WorkspaceRosterPane` per pane, carrying one attachment
    /// per attached device — and joins each attachment's `clientInstanceID` to `clients` for a
    /// human-readable label. This client's own attachment is filtered out: it is not "also" holding
    /// its own pane.
    ///
    /// The join is OPTIONAL and legitimately misses. It is never a force-unwrap and never a drop:
    /// an attachment whose id names no roster client is a CLI, and it is reported as
    /// ``unlabelledHolder``. Dropping it would make a pane held by a `slopdesk-client` read as
    /// unheld, and make the resolved grid's arithmetic unexplainable.
    public func paneHolders(for id: PaneID) -> [String] {
        observeWorkspaceMirror()
        guard let roster = workspaceMirror.roster else { return [] }
        let objectID = documentPaneID(id)
        guard let record = roster.panes.first(where: { $0.paneID == objectID }) else { return [] }
        var tokens = RosterTokens()
        let clients = roster.clients.map { client in
            MirrorFold.PresenceClient(
                token: tokens.token(for: client.clientInstanceID),
                labelled: !client.label.isEmpty,
                viewing: false,
            )
        }
        let attachments = record.attachments.map { tokens.token(for: $0.clientInstanceID) }
        let mine = workspaceChannel.map { tokens.token(for: $0.clientInstanceID) }
        return MirrorFold.holders(attachments: attachments, clients: clients, own: mine).map { position in
            guard let position, roster.clients.indices.contains(position) else { return Self.unlabelledHolder }
            return roster.clients[position].label
        }
    }

    /// How many clients hold a channel on pane `id`, INCLUDING this one and including the ones no
    /// roster client names. The count the resolved grid has to be explainable against.
    public func paneAttachmentCount(for id: PaneID) -> Int {
        observeWorkspaceMirror()
        guard let roster = workspaceMirror.roster else { return 0 }
        let objectID = documentPaneID(id)
        return roster.panes.first { $0.paneID == objectID }?.attachments.count ?? 0
    }

    /// The grid the HOST resolved for pane `id` (docs/45 §8.3), or `nil` when the roster has not
    /// published one. What a size-passive client places behind a letterbox instead of reflowing to
    /// its own window.
    public func paneResolvedGrid(for id: PaneID) -> (cols: Int, rows: Int)? {
        observeWorkspaceMirror()
        guard let roster = workspaceMirror.roster else { return nil }
        let objectID = documentPaneID(id)
        guard let record = roster.panes.first(where: { $0.paneID == objectID }),
              MirrorFold.gridPublished(cols: Int(record.resolvedCols), rows: Int(record.resolvedRows))
        else { return nil }
        return (cols: Int(record.resolvedCols), rows: Int(record.resolvedRows))
    }

    /// §8.3 rule 7's readout for pane `id` — `120×40 · sized by MacBook Pro` — or `nil` when the
    /// host has resolved no grid for it.
    ///
    /// This is what makes the size policy debuggable on hardware: without it a phone shows a pane
    /// that is the wrong size for no stated reason, and a rule reads as a bug.
    public func paneGridReadout(for id: PaneID) -> String? {
        observeWorkspaceMirror()
        guard let roster = workspaceMirror.roster else { return nil }
        let objectID = documentPaneID(id)
        guard let record = roster.panes.first(where: { $0.paneID == objectID }) else { return nil }
        var labels: [UUID: String] = [:]
        for client in roster.clients where !client.label.isEmpty {
            labels[client.clientInstanceID] = client.label
        }
        return TerminalGridReadout.text(
            for: record,
            labels: labels,
            selfClientInstanceID: workspaceChannel?.clientInstanceID,
        )
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
        switch MirrorFold.runningCommand(
            hosted: workspaceMirror.string(.pane, documentPaneID(id), WorkspacePaneField.runningCommand),
            open: commandBlocks(for: id).last { !$0.complete }?.commandText,
            hasProcessLabel: processLabel != nil,
        ) {
        case let .hosted(text),
             let .open(text): return text
        case .processLabel: return processLabel
        case .absent: return nil
        }
    }
}

/// Dense `UInt32` tokens for the roster's client ids — the minting the presence joins are asked in.
///
/// The joins themselves run in `slopdesk-workspace::mirror_fold` and answer POSITIONS, so no `UUID`
/// and no label ever crosses. What they need instead is a number per identity that is stable for the
/// length of one join, which is all this is: first sight mints the next number, every later sight
/// gets the same one. An id nothing has seen — this client, when it is not in the roster — simply
/// mints a token that matches nothing, which is the right answer rather than a special case.
private struct RosterTokens {
    private var minted: [UUID: UInt32] = [:]

    mutating func token(for id: UUID) -> UInt32 {
        if let held = minted[id] { return held }
        let next = UInt32(minted.count)
        minted[id] = next
        return next
    }
}

/// Which tab and pane a client is looking at, in DOCUMENT ids.
struct WorkspaceViewReport: Equatable {
    let tabID: UUID
    let paneID: UUID
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
    /// running on the control-push overlay alone — per-pane facts still arrive, the LAYOUT does not.
    func attachWorkspaceChannel(_ client: WorkspaceChannelClient?) {
        workspaceChannel?.stop()
        workspaceChannel = client
        // The automation bootstrap reshapes the HOST's workspace, so it can only run once there is a
        // subscription with a topology behind it. Both edges matter: a loopback document is already
        // `.live` when it is attached (so the call below fires it), and a real channel reaches `.live`
        // several round trips later (so the hook does). The launch adopt rides the same two edges for
        // the same reason.
        workspaceChannelState = client?.state ?? .idle
        client?.onStateChange = { [weak self] in
            guard let self else { return }
            // Read back off the store's OWN reference rather than capturing `client`: the closure is
            // held by the object it would capture, and that cycle would keep a dead subscription (and
            // its box) alive for the life of the store.
            workspaceChannelState = workspaceChannel?.state ?? .idle
            runArmedBootstrapIfPossible()
            runArmedLaunchAdoptIfPossible()
            // A REFUSED or CLOSED channel is a definite answer that no document is coming, and it
            // releases the dial hold that the `.opening` state put on (``panesMayDial``).
            refreshPaneDialGate()
        }
        runArmedBootstrapIfPossible()
        runArmedLaunchAdoptIfPossible()
        refreshPaneDialGate()
    }

    /// Opens (or re-opens) the channel for the connection that just established.
    ///
    /// Re-opening on every establish is deliberate: the previous subscription died with the old link,
    /// and the target may have CHANGED — a host that refused the class is not evidence about the next
    /// one. `stop()` clears the refusal for that reason.
    func startWorkspaceChannel() {
        guard let workspaceChannel else { return }
        workspaceChannel.stop()
        workspaceChannel.start()
    }

    /// Installs an in-process document that answers this store's intents synchronously, seeded from
    /// the layout the store already restored.
    ///
    /// The seam a caller with no host reaches for. ``WorkspaceChannelClient/send(intent:args:now:)``
    /// refuses anything that is not `.live`, and `.live` arrives only from inside the async run loop —
    /// so without this, every synchronous mutation against a document-driven layout is a no-op that
    /// compiles, logs nothing, and simply does not happen.
    ///
    /// Deliberately NOT called from ``init``. A client that can rewrite its own workspace with no host
    /// in the loop is the locally-owned tree this document replaces, and it stays something a caller
    /// asks for by name.
    ///
    /// - Returns: the document, so the caller can drive its liveness half too.
    @discardableResult
    func attachLoopbackWorkspaceDocument(label: String = "loopback") -> LoopbackWorkspaceDocument {
        let document = LoopbackWorkspaceDocument(box: workspaceMirror)
        // Adopt rather than install: `seedWorkspaceMirror(from:cache:)` has already published the
        // restored tree and the cached per-pane facts, and re-publishing them would churn every
        // observer for a document that did not change.
        document.adopt(pristine: true)
        attachWorkspaceChannel(.loopback(document: document, label: label))
        return document
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

    /// Points the unread-finish marker's DEVICE half at the preferences store and seeds it.
    ///
    /// The document supplies each pane's completion counter; this remembers which of those counters
    /// this Mac has already READ. Persisted, so quitting the app is not the same as reading
    /// everything — the failure the in-memory latch had on every relaunch.
    func attachCompletionSeenStore(_ preferences: PreferencesStore) {
        completionSeen.load = { preferences.seenCompletionEpochs() }
        completionSeen.save = { preferences.setSeenCompletionEpochs($0) }
        loadCompletionSeen()
    }

    /// What the store does when the app-global shared connection comes up: redial the panes the drop
    /// left disconnected, then re-open the workspace subscription.
    ///
    /// The order is forced, and the forcing thing is ``startWorkspaceChannel()``: it stops the old
    /// subscription, `stop()` resets the mirror, and ``WorkspaceStore/tree`` is a pure PROJECTION of
    /// that mirror. So a fan-out placed after this line has an empty pane set to iterate on every
    /// live channel — three dead terminals behind a green "Connected" pill, which is the whole point
    /// of the fan-out inverted. What keeps the earlier fan-out safe is not the order but
    /// ``panesMayDial``, which is holding by the time this runs whenever the target has changed:
    /// ``commitConnectionTarget(_:)`` stamps the new host before the connection reports up, and the
    /// provenance rule refuses ids the attached host has not named.
    ///
    /// ``armPaneRedialOnDocument()`` covers what neither ordering can: the establish that arrives
    /// while the mirror is ALREADY empty, because the previous establish re-opened the subscription
    /// and the link died again before the snapshot answered. That fan-out has nothing to iterate at
    /// any point in this method, and the gate never moves, so its second chance has to hang off the
    /// document itself.
    ///
    /// Re-opening every time is deliberate — see ``startWorkspaceChannel()``.
    func handleConnectionEstablished() {
        armPaneRedialOnDocument()
        redialDisconnectedPanes()
        startWorkspaceChannel()
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
