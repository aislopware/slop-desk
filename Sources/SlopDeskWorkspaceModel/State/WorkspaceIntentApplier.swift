import Foundation

/// Turns one client's request into a new topology, or into a refusal.
///
/// **Pure, and deliberately shared by both ends.** The host runs it to decide what the document
/// becomes; the client runs the SAME function to build its optimistic overlay. Two implementations of
/// "what does a split do" would drift, and the drift would look exactly like a sync bug — the client
/// showing one layout and the host publishing another, with no way to tell which is wrong.
///
/// Everything here is validation. The transformation itself is `WorkspaceTreeOps`, which has been in
/// production against trusted local input for a long time; what it has never had is a caller that is
/// a network peer. So: every referenced id must already exist, every proposed id must not, every
/// count is bounded before it allocates, and the RESULT is checked against the depth cap and the
/// specs invariant before it is accepted.
public enum WorkspaceIntentApplier {
    /// Applies one intent.
    ///
    /// - Parameters:
    ///   - documentIsPristine: whether the document is still the untouched default. Only
    ///     ``WorkspaceIntentOp/adoptWorkspace`` reads it — a bootstrap that arrives after the host has
    ///     a real workspace is `rejectedStale`, and the loser keeps its tree rather than losing it.
    public static func apply(
        op rawOp: UInt8,
        args: Data,
        to topology: WorkspaceTopology,
        documentIsPristine: Bool = false,
    ) -> WorkspaceIntentOutcome {
        guard let op = WorkspaceIntentOp(rawValue: rawOp) else { return .unknownOp }
        var reader = WorkspaceIntentArgs.Reader(args)
        switch op {
        case .adoptWorkspace: return adopt(args, into: topology, pristine: documentIsPristine)
        case .renamePane: return renamePane(&reader, topology)
        case .renameTab: return renameTab(&reader, topology)
        case .renameSession: return renameSession(&reader, topology)
        case .closePane: return closePane(&reader, topology)
        case .closeTab: return closeTab(&reader, topology)
        case .splitPane: return splitPane(&reader, topology)
        case .spawnPane: return spawnPane(&reader, topology)
        case .movePane: return movePane(&reader, topology)
        case .reorderTabs: return reorderTabs(&reader, topology)
        case .focusTab: return focusTab(&reader, topology)
        case .focusPane: return focusPane(&reader, topology)
        case .setSyncInput: return setSyncInput(&reader, topology)
        case .spawnTab: return spawnTab(&reader, topology)
        case .setZoom: return setZoom(&reader, topology)
        case .detachPane: return detachPane(&reader, topology)
        case .reattachPane: return reattachPane(&reader, topology)
        case .setDividerWeight: return setDividerWeight(&reader, topology)
        case .newSession: return newSession(&reader, topology)
        case .closeSession: return closeSession(&reader, topology)
        case .reopenClosedTab: return reopenClosedTab(topology)
        }
    }

    // MARK: - Acceptance

    /// The last gate every op passes through.
    ///
    /// The tree ops are pure and well-tested, but they were written for a caller that could not
    /// supply nonsense. Re-checking the RESULT — rather than trying to enumerate every hostile input
    /// — is what makes that difference safe: a structure that breaches the decoder's depth cap would
    /// lose a leaf (and therefore a live pane) the next time it round-trips, and a broken specs
    /// invariant hands the next op a corrupt input.
    private static func accept(_ next: WorkspaceTopology) -> WorkspaceIntentOutcome {
        guard next.tree.isInvariantHeld() else { return .rejectedInvalid }
        for session in next.tree.sessions {
            for tab in session.tabs where tab.root.depth > SplitNode.maxDepth {
                return .rejectedInvalid
            }
        }
        return .applied(next)
    }

    /// Re-derives the side maps that name panes and tabs, after an op may have removed some.
    ///
    /// Without this a closed pane's `spawnCwd`, a closed tab's sync-input bit and a dead tab in the
    /// MRU ring all linger — and the MRU one is not cosmetic: `closeTab` reads it to pick a successor,
    /// so a stale entry sends every client to a tab that is not there.
    private static func pruned(_ topology: WorkspaceTopology) -> WorkspaceTopology {
        var next = topology
        let liveTabs = Set(next.tree.sessions.flatMap { $0.tabs.map(\.id) })
        let livePanes = Set(next.tree.sessions.flatMap(\.specs.keys))
            .union(next.closedTabs.flatMap(\.specs.keys))
        next.syncInputTabs = next.syncInputTabs.filter { liveTabs.contains($0) }
        next.spawnCwd = next.spawnCwd.filter { livePanes.contains($0.key) }
        // A tab that came back is no longer reopenable. One cannot be both open and in the ring, and
        // rendering it twice is worse than losing one undo step.
        next.closedTabs = next.closedTabs.filter { !liveTabs.contains($0.tab.id) }
        var focus: [SessionID: [TabID]] = [:]
        for session in next.tree.sessions {
            let kept = (next.focusMRU[session.id] ?? []).filter { liveTabs.contains($0) }
            if !kept.isEmpty { focus[session.id] = kept }
        }
        next.focusMRU = focus
        return next
    }

    /// Records `tab` at the head of its session's MRU ring — the successor `closeTab` will read.
    private static func noting(focus tabID: TabID, in topology: WorkspaceTopology) -> WorkspaceTopology {
        var next = topology
        guard let session = next.tree.sessions.first(where: { $0.tabs.contains { $0.id == tabID } })
        else { return next }
        var ring = (next.focusMRU[session.id] ?? []).filter { $0 != tabID }
        ring.insert(tabID, at: 0)
        next.focusMRU[session.id] = Array(ring.prefix(WorkspaceTopology.focusMRUCap))
        return next
    }

    // MARK: - Lookups

    private static func hasPane(_ id: PaneID, in topology: WorkspaceTopology) -> Bool {
        topology.tree.contains(id) || topology.tree.isDetached(id)
    }

    private static func hasTab(_ id: TabID, in topology: WorkspaceTopology) -> Bool {
        topology.tree.sessions.contains { $0.tabs.contains { $0.id == id } }
    }

    private static func hasSession(_ id: SessionID, in topology: WorkspaceTopology) -> Bool {
        topology.tree.sessions.contains { $0.id == id }
    }

    /// Whether a proposed id is free. A pane id already in use would alias two panes onto one PTY the
    /// moment the channel opens — the exact hazard the mux's own exclusivity check exists for.
    private static func isFree(_ id: PaneID, in topology: WorkspaceTopology) -> Bool {
        !hasPane(id, in: topology) && !topology.closedTabs.contains { $0.tab.contains(id) }
    }

    // MARK: - Ops

    private static func adopt(
        _ args: Data,
        into topology: WorkspaceTopology,
        pristine: Bool,
    ) -> WorkspaceIntentOutcome {
        // A bootstrap, not a migration. Refused forever once the host has a workspace of its own —
        // and the loser is told so rather than silently overwritten, because its tree is the only
        // copy of a layout somebody built.
        guard pristine else { return .rejectedStale }
        guard let state = try? WorkspaceStateCodec.decodeSnapshot(args),
              let uploaded = WorkspaceTopology(entries: state)
        else { return .rejectedInvalid }
        var next = uploaded
        // The host keeps its OWN identity and its own ctl session — those are facts about this
        // daemon, not about the tree somebody uploaded.
        next.hostDisplayName = topology.hostDisplayName
        next.unattachedSessionID = topology.unattachedSessionID
        return accept(pruned(next))
    }

    private static func renamePane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let title = reader.name(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard hasPane(paneID, in: topology) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.updatingSpec(paneID, in: next.tree) { spec in
            spec.title = title
            // A rename is AUTHORSHIP, and the flag is what makes the live-title derivations yield to
            // it. Setting the title without it would let the next OSC title overwrite the user.
            spec.userRenamed = true
        }
        return accept(next)
    }

    private static func renameTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let title = reader.name(), reader.isAtEnd else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        guard hasTab(tabID, in: topology) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.renameTab(tabID, to: title, in: next.tree)
        return accept(next)
    }

    private static func renameSession(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let name = reader.name(), reader.isAtEnd else { return .rejectedInvalid }
        let sessionID = SessionID(raw: raw)
        guard hasSession(sessionID, in: topology) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.renameSession(sessionID, to: name, in: next.tree)
        return accept(next)
    }

    private static func closePane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard hasPane(paneID, in: topology) else { return .rejectedNotFound }
        var next = topology
        // The pane's tab may go with it. The successor comes from the SHARED MRU ring, which is the
        // whole reason that ring is host-owned: two clients computing it from two local rings pick
        // two different tabs, and the index clamp underneath reintroduces the cross-project jump.
        let owningTab = next.tree.tab(containing: paneID)
        let successor = owningTab.flatMap { successorAfterClosing($0.1, in: next) }
        next.tree = WorkspaceTreeOps.closePane(paneID, tabSuccessor: successor, in: next.tree)
        return accept(pruned(next))
    }

    private static func closeTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        guard hasTab(tabID, in: topology) else { return .rejectedNotFound }
        var next = topology
        // Kept WHOLE, not as an id: ⇧⌘T has to put the split tree and every pane's spec back, and a
        // `TabID` alone cannot rebuild either.
        if let session = next.tree.sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
           let tab = session.tabs.first(where: { $0.id == tabID })
        {
            var specs: [PaneID: PaneSpec] = [:]
            for paneID in tab.allPaneIDs() { specs[paneID] = session.specs[paneID] }
            next.closedTabs.append(WorkspaceTopology.ClosedTab(
                sessionID: session.id, tab: tab, specs: specs,
            ))
            if next.closedTabs.count > WorkspaceTopology.closedTabRingCap {
                next.closedTabs.removeFirst(next.closedTabs.count - WorkspaceTopology.closedTabRingCap)
            }
        }
        next.tree = WorkspaceTreeOps.closeTab(
            tabID, successor: successorAfterClosing(tabID, in: next), in: next.tree,
        )
        return accept(pruned(next))
    }

    /// The tab to select when `closing` goes away: the most recent OTHER tab in its session, else
    /// `nil` so the tree op's index clamp takes over.
    private static func successorAfterClosing(_ closing: TabID, in topology: WorkspaceTopology) -> TabID? {
        guard let session = topology.tree.sessions.first(where: { $0.tabs.contains { $0.id == closing } })
        else { return nil }
        let live = Set(session.tabs.map(\.id))
        return (topology.focusMRU[session.id] ?? []).first { $0 != closing && live.contains($0) }
    }

    private static func splitPane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let axis = reader.axis(), let before = reader.bool(),
              let newRaw = reader.uuid(), let cwd = reader.name(), reader.isAtEnd
        else { return .rejectedInvalid }
        let target = PaneID(raw: raw)
        let newPane = PaneID(raw: newRaw)
        guard topology.tree.contains(target) else { return .rejectedNotFound }
        guard isFree(newPane, in: topology) else { return .rejectedInvalid }
        return inserting(newPane, splitting: target, axis: axis, before: before, cwd: cwd, in: topology)
    }

    /// `spawnPane` targets a TAB rather than a pane — "give me another pane in here" — and splits
    /// whatever that tab has focused. A distinct op because the client knows which tab it means and
    /// should not have to guess which pane will be focused when the intent lands.
    private static func spawnPane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let axis = reader.axis(), let before = reader.bool(),
              let newRaw = reader.uuid(), let cwd = reader.name(), reader.isAtEnd
        else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        let newPane = PaneID(raw: newRaw)
        guard let session = topology.tree.sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let tab = session.tabs.first(where: { $0.id == tabID }),
              let target = tab.activePane ?? tab.allPaneIDs().first
        else { return .rejectedNotFound }
        guard isFree(newPane, in: topology) else { return .rejectedInvalid }
        return inserting(newPane, splitting: target, axis: axis, before: before, cwd: cwd, in: topology)
    }

    private static func inserting(
        _ newPane: PaneID,
        splitting target: PaneID,
        axis: SplitAxis,
        before: Bool,
        cwd: String,
        in topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        var next = topology
        let (grown, minted) = WorkspaceTreeOps.splitPane(
            target,
            axis: axis,
            newSpec: PaneSpec(kind: .terminal, title: "Terminal"),
            before: before,
            id: newPane,
            in: next.tree,
        )
        // The op is a no-op when the split would not fit. Nothing changed IS the refusal — reporting
        // `applied` would retire a client's optimistic patch against a document that never moved.
        guard grown.contains(minted) else { return .rejectedInvalid }
        next.tree = grown
        if !cwd.isEmpty { next.spawnCwd[newPane] = cwd }
        if let tab = next.tree.tab(containing: newPane) { next = noting(focus: tab.1, in: next) }
        return accept(next)
    }

    private static func movePane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let sourceRaw = reader.uuid(), let targetRaw = reader.uuid(),
              let axis = reader.axis(), let before = reader.bool(), reader.isAtEnd
        else { return .rejectedInvalid }
        let source = PaneID(raw: sourceRaw), target = PaneID(raw: targetRaw)
        guard topology.tree.contains(source), topology.tree.contains(target) else { return .rejectedNotFound }
        guard source != target else { return .rejectedInvalid }
        var next = topology
        next.tree = WorkspaceTreeOps.moveLeafAcrossTabs(
            source, beside: target, axis: axis, before: before, in: next.tree,
        )
        // The op validates the destination itself and returns the input untouched when the insert
        // would breach the depth cap. An unmoved pane is a refusal, not a satisfied request.
        guard next.tree.tab(containing: source)?.1 == next.tree.tab(containing: target)?.1
        else { return .rejectedInvalid }
        return accept(next)
    }

    private static func reorderTabs(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let order = reader.uuidList(), reader.isAtEnd else { return .rejectedInvalid }
        let sessionID = SessionID(raw: raw)
        guard let index = topology.tree.sessions.firstIndex(where: { $0.id == sessionID })
        else { return .rejectedNotFound }
        let session = topology.tree.sessions[index]
        let wanted = order.map { TabID(raw: $0) }
        // A PERMUTATION or nothing. A partial order would silently drop the tabs it left out, and a
        // reorder is the one op where "some of it applied" is indistinguishable from a close.
        guard Set(wanted) == Set(session.tabs.map(\.id)), wanted.count == session.tabs.count
        else { return .rejectedInvalid }
        let activeID = session.tabs.indices.contains(session.activeTabIndex)
            ? session.tabs[session.activeTabIndex].id
            : nil
        var next = topology
        next.tree.sessions[index].tabs = wanted.compactMap { id in session.tabs.first { $0.id == id } }
        // Selection follows the TAB, not the slot it used to sit in.
        next.tree.sessions[index].activeTabIndex = activeID
            .flatMap { id in wanted.firstIndex(of: id) } ?? 0
        return accept(next)
    }

    private static func focusTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        guard let sIdx = topology.tree.sessions.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let tIdx = topology.tree.sessions[sIdx].tabs.firstIndex(where: { $0.id == tabID })
        else { return .rejectedNotFound }
        var next = topology
        next.tree.activeSessionID = next.tree.sessions[sIdx].id
        next.tree.sessions[sIdx].activeTabIndex = tIdx
        return accept(noting(focus: tabID, in: next))
    }

    private static func focusPane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard topology.tree.contains(paneID) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.focusPane(paneID, in: next.tree)
        if let tab = next.tree.tab(containing: paneID) { next = noting(focus: tab.1, in: next) }
        return accept(next)
    }

    private static func setSyncInput(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let armed = reader.bool(), reader.isAtEnd else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        guard hasTab(tabID, in: topology) else { return .rejectedNotFound }
        var next = topology
        if armed { next.syncInputTabs.insert(tabID) } else { next.syncInputTabs.remove(tabID) }
        return accept(next)
    }

    private static func spawnTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let newRaw = reader.uuid(), let positionByte = reader.u8(),
              let cwd = reader.name(), reader.isAtEnd
        else { return .rejectedInvalid }
        let sessionID = SessionID(raw: raw)
        let newPane = PaneID(raw: newRaw)
        guard hasSession(sessionID, in: topology) else { return .rejectedNotFound }
        guard isFree(newPane, in: topology) else { return .rejectedInvalid }
        var next = topology
        // `newTab` works on the ACTIVE session. Selecting first is not a side effect to apologise
        // for — a client asking for a tab in a session is asking to be looking at that session.
        next.tree = WorkspaceTreeOps.selectSession(sessionID, in: next.tree)
        let (grown, minted) = WorkspaceTreeOps.newTab(
            in: next.tree,
            spec: PaneSpec(kind: .terminal, title: "Terminal"),
            at: WorkspaceIntentArgs.position(for: positionByte),
            id: newPane,
        )
        guard grown.contains(minted) else { return .rejectedInvalid }
        next.tree = grown
        if !cwd.isEmpty { next.spawnCwd[newPane] = cwd }
        if let tab = next.tree.tab(containing: newPane) { next = noting(focus: tab.1, in: next) }
        return accept(next)
    }

    private static func setZoom(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let zoomed = reader.bool(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard let (sIdx, tIdx) = WorkspaceTreeOps.locate(paneID, in: topology.tree) else { return .rejectedNotFound }
        var next = topology
        // Set, not toggle. A toggle over shared state resolves differently depending on how many
        // clients sent it, which is the class of bug an idempotent assignment cannot have.
        next.tree.sessions[sIdx].tabs[tIdx].zoomedPane = zoomed ? paneID : nil
        return accept(next)
    }

    private static func detachPane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard topology.tree.contains(paneID) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.detachPane(paneID, in: next.tree)
        return accept(pruned(next))
    }

    private static func reattachPane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard topology.tree.isDetached(paneID) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.reattachPane(paneID, in: next.tree)
        guard !next.tree.isDetached(paneID) else { return .rejectedInvalid }
        return accept(pruned(next))
    }

    private static func setDividerWeight(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let index = reader.u16(), let bits = reader.u64(), reader.isAtEnd
        else { return .rejectedInvalid }
        let splitID = SplitNodeID(raw: raw)
        // A weight that is not a finite positive number would starve a pane to nothing. Checked here
        // rather than left to the layout solver's clamp, so the DOCUMENT never carries the nonsense.
        let weight = Double(bitPattern: bits)
        guard weight.isFinite, weight >= SplitWeight.minWeight else { return .rejectedInvalid }
        guard containsSplit(splitID, in: topology) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.setDividerWeight(
            splitID: splitID, leadingChildIndex: index, leadingWeight: weight, in: next.tree,
        )
        return accept(next)
    }

    private static func containsSplit(_ splitID: SplitNodeID, in topology: WorkspaceTopology) -> Bool {
        func walk(_ node: SplitNode) -> Bool {
            guard case let .split(id, _, children) = node else { return false }
            if id == splitID { return true }
            return children.contains { walk($0.node) }
        }
        return topology.tree.sessions.contains { $0.tabs.contains { walk($0.root) } }
    }

    private static func newSession(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let newRaw = reader.uuid(), let name = reader.name(), reader.isAtEnd
        else { return .rejectedInvalid }
        let sessionID = SessionID(raw: raw)
        let newPane = PaneID(raw: newRaw)
        guard !hasSession(sessionID, in: topology), isFree(newPane, in: topology) else { return .rejectedInvalid }
        var next = topology
        let tab = Tab(root: .leaf(newPane), activePane: newPane)
        next.tree = WorkspaceTreeOps.insertSession(
            Session(
                id: sessionID,
                name: name.isEmpty ? "Local" : name,
                tabs: [tab],
                specs: [newPane: PaneSpec(kind: .terminal, title: "Terminal")],
            ),
            in: next.tree,
            makeActive: true,
        )
        return accept(noting(focus: tab.id, in: next))
    }

    private static func closeSession(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let sessionID = SessionID(raw: raw)
        guard hasSession(sessionID, in: topology) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.closeSession(sessionID, in: next.tree)
        return accept(pruned(next))
    }

    private static func reopenClosedTab(_ topology: WorkspaceTopology) -> WorkspaceIntentOutcome {
        // Nothing to reopen is NOT an error — ⇧⌘T on an empty ring is a satisfied request that
        // changes nothing, and answering `rejected` would make every client roll back a patch it
        // never made.
        guard let restored = topology.closedTabs.last else { return .applied(topology) }
        guard let index = topology.tree.sessions.firstIndex(where: { $0.id == restored.sessionID })
        else { return .rejectedNotFound }
        var next = topology
        next.closedTabs.removeLast()
        next.tree = WorkspaceTreeOps.selectSession(restored.sessionID, in: next.tree)
        next.tree = WorkspaceTreeOps.insertTab(
            restored.tab, specs: restored.specs, at: .end, in: next.tree,
        )
        guard next.tree.sessions[index].tabs.contains(where: { $0.id == restored.tab.id })
        else { return .rejectedInvalid }
        return accept(noting(focus: restored.tab.id, in: next))
    }
}
