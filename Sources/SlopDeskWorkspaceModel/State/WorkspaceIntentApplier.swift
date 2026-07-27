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
    ///   - projectKey: a pane's resolved By-Project key
    ///     (``TabOrderingEngine/paneProjectKey(_:projectKey:cwd:)`` over the caller's own cells). Only
    ///     the close ops read it, to keep focus inside the section the closed tab lived in. Every
    ///     caller that owns a document supplies it; the default puts every pane in one section, which
    ///     reduces the close rule to MRU-then-array-neighbour and is what a caller with no document
    ///     cells to read — a tree-op unit test — wants.
    public static func apply(
        op rawOp: UInt8,
        args: Data,
        to topology: WorkspaceTopology,
        documentIsPristine: Bool = false,
        projectKey: (PaneID) -> String? = { _ in nil },
    ) -> WorkspaceIntentOutcome {
        guard let op = WorkspaceIntentOp(rawValue: rawOp) else { return .unknownOp }
        var reader = WorkspaceIntentArgs.Reader(args)
        switch op {
        case .adoptWorkspace: return adopt(args, into: topology, pristine: documentIsPristine)
        case .renamePane: return renamePane(&reader, topology)
        case .renameTab: return renameTab(&reader, topology)
        case .renameSession: return renameSession(&reader, topology)
        case .closePane: return closePane(&reader, topology, projectKey)
        case .closeTab: return closeTab(&reader, topology, projectKey)
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
        case .reopenClosedTab: return reopenClosedTab(&reader, topology)
        case .breakPaneToTab: return breakPaneToTab(&reader, topology)
        case .swapPanes: return swapPanes(&reader, topology)
        case .dockPaneAtTabEdge: return dockPaneAtTabEdge(&reader, topology)
        case .setTabLayout: return setTabLayout(&reader, topology)
        case .spawnDetachedPane: return spawnDetachedPane(&reader, topology)
        case .setPaneVideoTarget: return setPaneVideoTarget(&reader, topology)
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
        _ projectKey: (PaneID) -> String?,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard hasPane(paneID, in: topology) else { return .rejectedNotFound }
        var next = topology
        // A DETACHED pane has no tab to walk. `hasPane` unions the detached set, so without this
        // branch the op accepts the id and the tree op — which locates LEAVES only — hands back the
        // same tree: the client retires its optimistic patch against a document that never moved and
        // the satellite window keeps a zombie handle streaming.
        if next.tree.isDetached(paneID) {
            next.tree = WorkspaceTreeOps.closeDetachedPane(paneID, in: next.tree)
            return accept(pruned(next))
        }
        // The pane's tab may go with it. The successor comes from the SHARED MRU ring, which is the
        // whole reason that ring is host-owned: two clients computing it from two local rings pick
        // two different tabs, and the index clamp underneath reintroduces the cross-project jump.
        let owningTab = next.tree.tab(containing: paneID)
        let successor = owningTab.flatMap { successorAfterClosing($0.1, in: next, projectKey) }
        // A pane that is its tab's SOLE leaf takes the whole tab with it, and a cascaded-away tab is
        // as reopenable as an explicitly closed one — the user closed the same thing either way. The
        // capture happens BEFORE the op, because afterwards there is no tab left to record.
        if let removed = owningTab?.1, soleLeaf(of: removed, in: next) == paneID {
            next = capturing(tab: removed, in: next)
        }
        next.tree = WorkspaceTreeOps.closePane(paneID, tabSuccessor: successor, in: next.tree)
        return accept(pruned(next))
    }

    private static func closeTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
        _ projectKey: (PaneID) -> String?,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        guard hasTab(tabID, in: topology) else { return .rejectedNotFound }
        var next = capturing(tab: tabID, in: topology)
        next.tree = WorkspaceTreeOps.closeTab(
            tabID, successor: successorAfterClosing(tabID, in: next, projectKey), in: next.tree,
        )
        return accept(pruned(next))
    }

    /// Files `tabID` whole onto the reopen ring — its split tree, its title, and the ``PaneSpec`` of
    /// every leaf in it.
    ///
    /// Kept WHOLE, not as an id: ⇧⌘T has to put the split tree and every pane's spec back, and a
    /// `TabID` alone cannot rebuild either. Bounded, because a ring that grew without limit would keep
    /// every pane the user ever closed alive in the document, on every client, forever.
    private static func capturing(tab tabID: TabID, in topology: WorkspaceTopology) -> WorkspaceTopology {
        var next = topology
        guard let session = next.tree.sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let tab = session.tabs.first(where: { $0.id == tabID })
        else { return next }
        var specs: [PaneID: PaneSpec] = [:]
        for paneID in tab.allPaneIDs() { specs[paneID] = session.specs[paneID] }
        next.closedTabs.append(WorkspaceTopology.ClosedTab(sessionID: session.id, tab: tab, specs: specs))
        if next.closedTabs.count > WorkspaceTopology.closedTabRingCap {
            next.closedTabs.removeFirst(next.closedTabs.count - WorkspaceTopology.closedTabRingCap)
        }
        return next
    }

    /// The pane `tabID` would be emptied by losing — i.e. its ONLY leaf. `nil` when the tab has
    /// siblings and therefore survives.
    private static func soleLeaf(of tabID: TabID, in topology: WorkspaceTopology) -> PaneID? {
        guard let session = topology.tree.sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
              let tab = session.tabs.first(where: { $0.id == tabID }),
              tab.root.leafCount == 1
        else { return nil }
        return tab.allPaneIDs().first
    }

    /// The tab to select when `closing` goes away: the most recent OTHER tab in its session, else the
    /// neighbour inside `closing`'s own PROJECT SECTION, else its neighbour in the display order
    /// (``TabOrderingEngine/successorAfterClose(closing:displayOrder:projectKey:focusHistory:)``).
    ///
    /// The ring alone is not enough. A fresh launch has an empty ring and `session.tabs` is CREATION
    /// order, so the tree op's `min(removedIndex, count - 1)` clamp underneath lands on whatever tab
    /// happens to sit at that index — routinely a different project than the one the user was reading.
    /// The section rule is the same one the sidebar draws with, run here because the HOST owns the
    /// close and a client cannot correct it afterwards.
    ///
    /// `nil` when no session owns `closing`; the caller then leaves the tree op on its clamp.
    private static func successorAfterClosing(
        _ closing: TabID,
        in topology: WorkspaceTopology,
        _ projectKey: (PaneID) -> String?,
    ) -> TabID? {
        guard let session = topology.tree.sessions.first(where: { $0.tabs.contains { $0.id == closing } })
        else { return nil }
        // Closing a BACKGROUND tab returns the session's OWN active tab: the user dismissed something
        // they were not looking at, and focus has no business moving. Ahead of the ring, because the
        // ring's head is where they were BEFORE — which is not where they are now.
        if session.tabs.indices.contains(session.activeTabIndex) {
            let active = session.tabs[session.activeTabIndex].id
            if active != closing { return active }
        }
        let ring = topology.focusMRU[session.id] ?? []
        let live = Set(session.tabs.map(\.id))
        if let recent = ring.first(where: { $0 != closing && live.contains($0) }) { return recent }
        let tabKey: (TabID) -> String? = {
            TabOrderingEngine.tabProjectKey($0, in: session, paneKey: projectKey)
        }
        return TabOrderingEngine.successorAfterClose(
            closing: closing,
            displayOrder: TabOrderingEngine.projectGroupedTabOrder(
                session.tabs.map(\.id), projectKey: tabKey,
            ),
            projectKey: tabKey,
            focusHistory: ring,
        )
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
        guard let raw = reader.uuid(), let newRaw = reader.uuid(), let name = reader.name(),
              let cwd = reader.name(), reader.isAtEnd
        else { return .rejectedInvalid }
        let sessionID = SessionID(raw: raw)
        let newPane = PaneID(raw: newRaw)
        guard !hasSession(sessionID, in: topology), isFree(newPane, in: topology) else { return .rejectedInvalid }
        var next = topology
        if !cwd.isEmpty { next.spawnCwd[newPane] = cwd }
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

    private static func reopenClosedTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let lifoIndex = reader.u16(), let positionByte = reader.u8(), reader.isAtEnd
        else { return .rejectedInvalid }
        // The ring is newest-LAST, and the index counts from the newest.
        let arrayIndex = topology.closedTabs.count - 1 - lifoIndex
        // Nothing to reopen — an empty ring, or an index past its end — is NOT an error. ⇧⌘T on an
        // empty ring is a satisfied request that changes nothing, and answering `rejected` would make
        // every client roll back a patch it never made.
        guard topology.closedTabs.indices.contains(arrayIndex) else { return .applied(topology) }
        let restored = topology.closedTabs[arrayIndex]
        var next = topology
        next.closedTabs.remove(at: arrayIndex)
        // The owning session may have been closed while the record sat on the ring. The tab still
        // holds live panes, so it lands in whichever session IS active rather than being refused —
        // refusing would strand the only copy of those panes in a ring entry that was just consumed.
        if next.tree.sessions.contains(where: { $0.id == restored.sessionID }) {
            next.tree = WorkspaceTreeOps.selectSession(restored.sessionID, in: next.tree)
        }
        guard let index = next.tree.sessions.firstIndex(where: { $0.id == next.tree.activeSessionID })
        else { return .rejectedNotFound }
        next.tree = WorkspaceTreeOps.insertTab(
            restored.tab,
            specs: restored.specs,
            at: WorkspaceIntentArgs.position(for: positionByte),
            in: next.tree,
        )
        guard next.tree.sessions[index].tabs.contains(where: { $0.id == restored.tab.id })
        else { return .rejectedInvalid }
        return accept(noting(focus: restored.tab.id, in: next))
    }

    private static func breakPaneToTab(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        guard let origin = topology.tree.tab(containing: paneID)?.1 else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.breakPaneToTab(paneID, in: next.tree)
        // The op is a no-op when the pane is its tab's ONLY leaf — there is nothing to break out of.
        // An unmoved pane is a refusal, not a satisfied request.
        guard let landed = next.tree.tab(containing: paneID)?.1, landed != origin else { return .rejectedInvalid }
        return accept(noting(focus: landed, in: next))
    }

    private static func swapPanes(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let rawA = reader.uuid(), let rawB = reader.uuid(), reader.isAtEnd else { return .rejectedInvalid }
        let a = PaneID(raw: rawA), b = PaneID(raw: rawB)
        guard topology.tree.contains(a), topology.tree.contains(b) else { return .rejectedNotFound }
        guard a != b else { return .rejectedInvalid }
        var next = topology
        next.tree = WorkspaceTreeOps.swapPanes(a, b, in: next.tree)
        return accept(next)
    }

    private static func dockPaneAtTabEdge(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let sourceRaw = reader.uuid(), let tabRaw = reader.uuid(), let edgeByte = reader.u8(),
              reader.isAtEnd
        else { return .rejectedInvalid }
        let source = PaneID(raw: sourceRaw)
        let tabID = TabID(raw: tabRaw)
        guard topology.tree.contains(source), hasTab(tabID, in: topology) else { return .rejectedNotFound }
        var next = topology
        next.tree = WorkspaceTreeOps.moveLeafToTabRootEdge(
            source, tab: tabID, edge: WorkspaceIntentArgs.edge(for: edgeByte), in: next.tree,
        )
        // The op no-ops on a same-tab dock against a lone leaf, a dock that would breach the depth
        // cap, a dock the pane already sits at, and a destination in another SESSION — so "did the
        // source end up in the tab the client named" is the one check that covers every refusal.
        guard next.tree.tab(containing: source)?.1 == tabID else { return .rejectedInvalid }
        return accept(pruned(next))
    }

    private static func setTabLayout(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let blob = reader.rest() else { return .rejectedInvalid }
        let tabID = TabID(raw: raw)
        // The decoder enforces the depth cap while it descends, so an over-deep shape never
        // materializes as a value at all.
        guard let layout = try? WorkspaceStateCodec.decodeLayout(blob) else { return .rejectedInvalid }
        guard let sIdx = topology.tree.sessions.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let tIdx = topology.tree.sessions[sIdx].tabs.firstIndex(where: { $0.id == tabID })
        else { return .rejectedNotFound }
        let tab = topology.tree.sessions[sIdx].tabs[tIdx]
        let current = tab.allPaneIDs()
        guard let leaves = validLeaves(of: layout) else { return .rejectedInvalid }
        // A RE-LAYOUT moves panes, it does not create or destroy them. A shape that adds a leaf would
        // invent a pane with no spec; one that drops a leaf would strand a live PTY with nothing
        // rendering it. Either is a different op, and neither is what a re-tile means.
        guard leaves.count == current.count, Set(leaves) == Set(current) else { return .rejectedInvalid }
        var next = topology
        // Every split comes back at an EQUAL `.flex(1)` share — `select-layout` semantics: a re-tile
        // discards the divider drags that described the OLD shape.
        next.tree.sessions[sIdx].tabs[tIdx].root = rebuilt(layout)
        // …and the tab EXITS zoom, `select-layout` semantics. A zoomed tab renders one pane, so a
        // re-tile under a zoom re-shapes the tab invisibly: the user sees nothing happen while the
        // caller's cycle cursor keeps advancing underneath.
        next.tree.sessions[sIdx].tabs[tIdx].zoomedPane = nil
        return accept(next)
    }

    /// The layout's leaves, or `nil` when the shape itself is not one a tab may hold: a split with
    /// fewer than two children breaks the `.split` arity invariant, and a repeated leaf would alias
    /// two positions onto one pane. Neither is caught by the specs invariant `accept` re-checks.
    private static func validLeaves(of node: WorkspaceLayoutNode) -> [PaneID]? {
        switch node {
        case let .leaf(id):
            return [id]
        case let .split(_, _, children):
            guard children.count >= 2 else { return nil }
            var out: [PaneID] = []
            for child in children {
                guard let leaves = validLeaves(of: child) else { return nil }
                out.append(contentsOf: leaves)
            }
            return Set(out).count == out.count ? out : nil
        }
    }

    private static func rebuilt(_ node: WorkspaceLayoutNode) -> SplitNode {
        switch node {
        case let .leaf(id):
            .leaf(id)
        case let .split(id, axis, children):
            .split(
                id: id,
                axis: axis,
                children: children.map { WeightedChild(weight: .flex(1), node: rebuilt($0)) },
            )
        }
    }

    private static func spawnDetachedPane(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let kindByte = reader.u8(), let blob = reader.blob(), reader.isAtEnd
        else { return .rejectedInvalid }
        let newPane = PaneID(raw: raw)
        guard isFree(newPane, in: topology) else { return .rejectedInvalid }
        // A zero-length blob is "no target"; bytes that are present but do not decode are malformed,
        // never a silently target-less pane — that would open a satellite window streaming nothing.
        let video: VideoEndpoint?
        if blob.isEmpty {
            video = nil
        } else {
            guard let decoded = WorkspaceStateCodec.decodeVideoTarget(blob) else { return .rejectedInvalid }
            video = decoded
        }
        let kind = WorkspacePaneKindTag.kind(for: kindByte)
        var next = topology
        let (grown, minted) = WorkspaceTreeOps.mintDetachedPane(
            spec: PaneSpec(kind: kind, title: title(for: kind, video: video), video: video),
            id: newPane,
            in: next.tree,
        )
        // The mint is a no-op when there is no session to park the pane in. Nothing changed IS the
        // refusal — reporting `applied` would retire a client's patch against a document that never
        // moved, leaving a satellite window with no pane behind it.
        guard grown.isDetached(minted) else { return .rejectedInvalid }
        next.tree = grown
        return accept(next)
    }

    /// Re-points an existing pane's `pane/videoTarget`.
    ///
    /// The DERIVED title follows the binding, and only while it was tracking the previous one: a pane
    /// whose title still reads as the old target's is renamed to the new target's, and a title the
    /// user authored is left alone. That rule lives here rather than in the client, because the
    /// document is where the spec is and two clients deciding it separately is the divergence this
    /// whole document exists to end.
    private static func setPaneVideoTarget(
        _ reader: inout WorkspaceIntentArgs.Reader,
        _ topology: WorkspaceTopology,
    ) -> WorkspaceIntentOutcome {
        guard let raw = reader.uuid(), let blob = reader.blob(), reader.isAtEnd
        else { return .rejectedInvalid }
        let paneID = PaneID(raw: raw)
        // A zero-length blob UNBINDS; bytes that are present but do not decode are malformed, never a
        // silently target-less pane — that would leave a satellite window streaming nothing.
        let video: VideoEndpoint?
        if blob.isEmpty {
            video = nil
        } else {
            guard let decoded = WorkspaceStateCodec.decodeVideoTarget(blob) else { return .rejectedInvalid }
            video = decoded
        }
        var next = topology
        guard let sIdx = next.tree.sessions.firstIndex(where: { $0.specs[paneID] != nil }),
              var spec = next.tree.sessions[sIdx].specs[paneID]
        else { return .rejectedNotFound }
        if !spec.userRenamed, spec.title == spec.video?.title || spec.video == nil {
            spec.title = title(for: spec.kind, video: video)
        }
        spec.video = video
        next.tree.sessions[sIdx].specs[paneID] = spec
        return accept(next)
    }

    /// The title a detached pane is born with. The endpoint's own title when it has one — that is
    /// what the user picked in the window/display picker — else the kind's plain noun.
    private static func title(for kind: PaneKind, video: VideoEndpoint?) -> String {
        if let title = video?.title, !title.isEmpty { return title }
        return kind == .desktop ? "Desktop" : "Terminal"
    }
}
