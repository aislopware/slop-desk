import Foundation

// MARK: - Topology

/// The half of the workspace document an INTENT writes and a host restart restores.
///
/// The split that matters is topology vs liveness. Liveness (``PaneLiveness``) is derived from a
/// running process and is republished on every host start — restoring it would render a pane whose
/// child is long gone as fake-live. Topology is what the user ARRANGED, and losing it is losing the
/// workspace, so it is the persisted half and the half an intent may change.
///
/// It wraps ``TreeWorkspace`` rather than re-modelling it because the intent ops map 1:1 onto the
/// pure `WorkspaceTreeOps` statics that already operate on that value — that reuse is the whole
/// implementation lever. What it ADDS are the four facts docs/45 §4.1 moves host-side and that the
/// tree value has never held: they lived in the client store, where two clients computing them
/// independently is exactly the divergence this document exists to end.
public struct WorkspaceTopology: Equatable, Sendable {
    /// The arrangement itself — sessions, tabs, split trees, per-pane specs.
    public var tree: TreeWorkspace

    /// Tabs with sync-input armed. tmux models `synchronize-panes` as a server-side WINDOW option,
    /// and it has to be: hosting only the armed bit while fanning client-side would mean client B's
    /// keystrokes silently do not fan.
    public var syncInputTabs: Set<TabID>

    /// Per-session tab MRU, most-recent first — the ring `closeTab` reads to pick a successor.
    ///
    /// Shared rather than per-client because close IS an intent: two clients computing successors
    /// from two local rings pick two different tabs, and the host's index clamp then reintroduces the
    /// cross-project jump `ed76f137` fixed.
    public var focusMRU: [SessionID: [TabID]]

    /// ⇧⌘T's ring, newest last. A per-client undo stack over shared state is incoherent — the tab it
    /// reopens has panes that live host-side.
    ///
    /// The RECORDS, not just the ids: a `TabID` alone cannot rebuild a tab, and the reopen has to put
    /// back the split tree and every pane's spec. They ride in the document as ordinary `tab/*`,
    /// `splitNode/*` and `pane/*` entries — a closed tab is exactly a tab whose `tab/sessionID` names
    /// a session that does not list it in `tabOrder` — so this costs no new grammar, only the rule
    /// that the reaper must leave them alone.
    public var closedTabs: [ClosedTab]

    /// The host-owned session that parents panes with no client (ctl-spawned). Without it the host
    /// has two disagreeing pane inventories.
    public var unattachedSessionID: SessionID?

    /// What this host calls itself, so a client can label the workspace it is looking at.
    public var hostDisplayName: String

    /// Where a pane's shell was asked to start, keyed by pane. Distinct from `pane/cwd`, which is
    /// where the shell IS: a respawn after a host restart has no live shell to ask, and starting it
    /// at the last-observed cwd would silently relocate a pane the user placed deliberately.
    public var spawnCwd: [PaneID: String]

    /// One tab the user closed, kept whole so ⇧⌘T can put it back.
    public struct ClosedTab: Equatable, Sendable {
        /// The session it belonged to. Its `tab/sessionID` back-pointer is what identifies it as
        /// closed rather than orphaned, and where the reopen puts it.
        public var sessionID: SessionID
        public var tab: Tab
        public var specs: [PaneID: PaneSpec]

        public init(sessionID: SessionID, tab: Tab, specs: [PaneID: PaneSpec]) {
            self.sessionID = sessionID
            self.tab = tab
            self.specs = specs
        }
    }

    /// The ring as ids — what `root/closedTabRing` carries.
    public var closedTabRing: [TabID] { closedTabs.map(\.tab.id) }

    /// The cap. A ring that grew without bound would keep every pane the user ever closed alive in
    /// the document, on every client, forever.
    public static let closedTabRingCap = 25

    /// The MRU cap. A handful of switches back is all the close path can meaningfully use, and the
    /// ring rides in every snapshot.
    public static let focusMRUCap = 16

    public init(
        tree: TreeWorkspace,
        syncInputTabs: Set<TabID> = [],
        focusMRU: [SessionID: [TabID]] = [:],
        closedTabs: [ClosedTab] = [],
        unattachedSessionID: SessionID? = nil,
        hostDisplayName: String = "",
        spawnCwd: [PaneID: String] = [:],
    ) {
        self.tree = tree
        self.syncInputTabs = syncInputTabs
        self.focusMRU = focusMRU
        self.closedTabs = closedTabs
        self.unattachedSessionID = unattachedSessionID
        self.hostDisplayName = hostDisplayName
        self.spawnCwd = spawnCwd
    }
}

// MARK: - What does NOT cross

/// State the document deliberately does not carry, named as a value rather than left implicit —
/// a silently-dropped field is the failure mode this whole document exists to end.
///
/// The device-local facts are not on ``TreeWorkspace``: the latched video modes, the committed
/// connection target and the preset library live in the client's `device-prefs.json` (docs/45 §7.3),
/// because the tree is the LAYOUT and the layout is identical on every attached client. A 27″ Studio
/// and an iPhone must not share an immersive-mode latch, and "which host am I talking to" is
/// definitionally a client concept.
///
/// What remains omitted from a tree that otherwise crosses whole:
///
/// - `schemaVersion` is a property of the client's persistence FILE. The document has an `epoch`
///   instead, and a foreign epoch means reset-then-snapshot rather than migrate.
/// - `root` fields 3–5 stay RESERVED (docs/45 §5.3). Nothing writes them, and a topology write must
///   not reap a value some future build put there — hence ``reservedRootFields``.
public enum WorkspaceTopologyOmissions {
    /// The `root` fields reserved for config that does not cross.
    public static let reservedRootFields: Set<UInt8> = [
        WorkspaceRootField.layoutPresets,
        WorkspaceRootField.launchPresets,
        WorkspaceRootField.sessionTemplates,
    ]
}

// MARK: - Projection

public extension WorkspaceTopology {
    /// This topology as document entries, in no particular order (``HostWorkspaceState`` sorts).
    func entries() -> [WorkspaceEntry] {
        var out: [WorkspaceEntry] = []
        appendRoot(into: &out)
        for session in tree.sessions {
            appendSession(session, into: &out)
            for tab in session.tabs {
                appendTab(tab, sessionID: session.id, into: &out)
                appendWeights(of: tab.root, into: &out)
            }
            for id in session.specs.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
                guard let spec = session.specs[id] else { continue }
                appendPane(id, spec: spec, into: &out)
            }
        }
        // A closed tab is a tab no session lists. It rides as the same entries a live one does — the
        // ring names it and its `tab/sessionID` says where it goes back.
        for closed in closedTabs {
            appendTab(closed.tab, sessionID: closed.sessionID, into: &out)
            appendWeights(of: closed.tab.root, into: &out)
            for id in closed.specs.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
                guard let spec = closed.specs[id] else { continue }
                appendPane(id, spec: spec, into: &out)
            }
        }
        return out
    }

    private func appendRoot(into out: inout [WorkspaceEntry]) {
        out.append(WorkspaceEntry(
            key: .root(WorkspaceRootField.sessionOrder),
            value: WorkspaceStateCodec.encodeUUIDList(tree.sessions.map(\.id.raw)),
        ))
        out.append(WorkspaceEntry(
            key: .root(WorkspaceRootField.closedTabRing),
            value: WorkspaceStateCodec.encodeUUIDList(closedTabRing.map(\.raw)),
        ))
        out.append(WorkspaceEntry(
            key: .root(WorkspaceRootField.hostDisplayName),
            value: WorkspaceStateCodec.encodeString(hostDisplayName),
        ))
        if let active = tree.activeSessionID {
            out.append(WorkspaceEntry(
                key: .root(WorkspaceRootField.activeSessionID),
                value: WorkspaceStateCodec.encodeUUID(active.raw),
            ))
        }
        if let unattached = unattachedSessionID {
            out.append(WorkspaceEntry(
                key: .root(WorkspaceRootField.unattachedSessionID),
                value: WorkspaceStateCodec.encodeUUID(unattached.raw),
            ))
        }
    }

    private func appendSession(_ session: Session, into out: inout [WorkspaceEntry]) {
        func entry(_ field: UInt8, _ value: Data) {
            out.append(WorkspaceEntry(key: WorkspaceKey(.session, session.id.raw, field), value: value))
        }
        entry(WorkspaceSessionField.name, WorkspaceStateCodec.encodeString(session.name))
        entry(WorkspaceSessionField.tabOrder, WorkspaceStateCodec.encodeUUIDList(session.tabs.map(\.id.raw)))
        entry(
            WorkspaceSessionField.detachedPanes,
            WorkspaceStateCodec.encodeDetachedPanes(session.detached.map { ($0.pane.raw, $0.originTab?.raw) }),
        )
        entry(
            WorkspaceSessionField.focusMRU,
            WorkspaceStateCodec.encodeUUIDList((focusMRU[session.id] ?? []).map(\.raw)),
        )
        // The ACTIVE TAB rides as an id, never the index it is stored as. Indices are exactly what
        // broke in `ed76f137`: two clients reordering tabs make the same integer name two different
        // tabs, and nothing on the wire can tell.
        if session.tabs.indices.contains(session.activeTabIndex) {
            entry(
                WorkspaceSessionField.activeTabID,
                WorkspaceStateCodec.encodeUUID(session.tabs[session.activeTabIndex].id.raw),
            )
        }
    }

    private func appendTab(_ tab: Tab, sessionID: SessionID, into out: inout [WorkspaceEntry]) {
        func entry(_ field: UInt8, _ value: Data) {
            out.append(WorkspaceEntry(key: WorkspaceKey(.tab, tab.id.raw, field), value: value))
        }
        entry(WorkspaceTabField.title, WorkspaceStateCodec.encodeString(tab.title))
        entry(WorkspaceTabField.sessionID, WorkspaceStateCodec.encodeUUID(sessionID.raw))
        entry(WorkspaceTabField.layoutStructure, WorkspaceStateCodec.encodeLayout(Self.layout(of: tab.root)))
        if let active = tab.activePane {
            entry(WorkspaceTabField.activePaneID, WorkspaceStateCodec.encodeUUID(active.raw))
        }
        if let zoomed = tab.zoomedPane {
            entry(WorkspaceTabField.zoomedPaneID, WorkspaceStateCodec.encodeUUID(zoomed.raw))
        }
        // Written only when ARMED. A default that is also the absent value keeps the default document
        // small, and `bool()` already reads a missing key as `false`.
        if syncInputTabs.contains(tab.id) {
            entry(WorkspaceTabField.syncInputArmed, WorkspaceStateCodec.encodeBool(true))
        }
    }

    private func appendWeights(of node: SplitNode, into out: inout [WorkspaceEntry]) {
        guard case let .split(id, _, children) = node else { return }
        out.append(WorkspaceEntry(
            key: WorkspaceKey(.splitNode, id.raw, WorkspaceSplitNodeField.weight),
            value: WorkspaceStateCodec.encodeWeights(children.map(\.weight)),
        ))
        for child in children { appendWeights(of: child.node, into: &out) }
    }

    private func appendPane(_ id: PaneID, spec: PaneSpec, into out: inout [WorkspaceEntry]) {
        func entry(_ field: UInt8, _ value: Data) {
            out.append(WorkspaceEntry(key: WorkspaceKey(.pane, id.raw, field), value: value))
        }
        entry(WorkspacePaneField.kind, WorkspaceStateCodec.encodeU8(WorkspacePaneKindTag.byte(for: spec.kind)))
        entry(WorkspacePaneField.title, WorkspaceStateCodec.encodeString(spec.title))
        if spec.userRenamed {
            entry(WorkspacePaneField.userRenamed, WorkspaceStateCodec.encodeBool(true))
        }
        if let video = spec.video {
            entry(WorkspacePaneField.videoTarget, WorkspaceStateCodec.encodeVideoTarget(video))
        }
        if let cwd = spawnCwd[id] {
            entry(WorkspacePaneField.spawnCwd, WorkspaceStateCodec.encodeString(cwd))
        }
    }

    /// The tab's shape with weights stripped — they ride as their own `splitNode/weight` entries, so
    /// a divider drag rewrites one small cell instead of the whole structure.
    static func layout(of node: SplitNode) -> WorkspaceLayoutNode {
        switch node {
        case let .leaf(id):
            .leaf(id)
        case let .split(id, axis, children):
            .split(id: id, axis: axis, children: children.map { layout(of: $0.node) })
        }
    }
}

// MARK: - Ingestion

public extension WorkspaceTopology {
    /// Rebuilds a topology from document entries, or `nil` when there is no workspace in them.
    ///
    /// Validate-then-drop throughout: these bytes reached a client over the network, and every
    /// structural claim they make is checked against what is actually present rather than trusted.
    /// A tab named in `session/tabOrder` with no `layoutStructure` is SKIPPED, not defaulted — a
    /// fabricated empty tab is a phantom every client would then render.
    ///
    /// - Returns: `nil` when `root/sessionOrder` names no session that has a usable tab. That is the
    ///   "I have no document" answer, distinct from an empty-but-real workspace, which cannot exist:
    ///   the host mints a default rather than publishing nothing.
    init?(entries state: HostWorkspaceState) {
        guard let sessionIDs = state.uuidList(.root(WorkspaceRootField.sessionOrder)) else { return nil }
        var sessions: [Session] = []
        for sessionID in sessionIDs.map({ SessionID(raw: $0) }) {
            guard let session = Self.session(sessionID, from: state) else { continue }
            sessions.append(session)
        }
        guard !sessions.isEmpty else { return nil }

        var focus: [SessionID: [TabID]] = [:]
        var armed: Set<TabID> = []
        var cwds: [PaneID: String] = [:]
        var live: Set<TabID> = []
        for session in sessions {
            let key = WorkspaceKey(.session, session.id.raw, WorkspaceSessionField.focusMRU)
            if let ids = state.uuidList(key), !ids.isEmpty {
                focus[session.id] = ids.map { TabID(raw: $0) }
            }
            for tab in session.tabs {
                live.insert(tab.id)
                if state.bool(WorkspaceKey(.tab, tab.id.raw, WorkspaceTabField.syncInputArmed)) {
                    armed.insert(tab.id)
                }
            }
            for id in session.specs.keys {
                let key = WorkspaceKey(.pane, id.raw, WorkspacePaneField.spawnCwd)
                if let cwd = state.string(key) { cwds[id] = cwd }
            }
        }

        // A closed tab is one the ring names that no session lists. A ring entry that IS live is
        // dropped rather than duplicated — one tab cannot be both open and reopenable, and rendering
        // it twice is worse than losing one undo step.
        var closed: [ClosedTab] = []
        let sessionIDSet = Set(sessions.map(\.id))
        for tabID in (state.uuidList(.root(WorkspaceRootField.closedTabRing)) ?? []).map({ TabID(raw: $0) })
            where !live.contains(tabID)
        {
            guard let tab = Self.tab(tabID, from: state),
                  let owner = state.uuid(WorkspaceKey(.tab, tabID.raw, WorkspaceTabField.sessionID))
                  .map({ SessionID(raw: $0) }),
                  sessionIDSet.contains(owner)
            else { continue }
            var specs: [PaneID: PaneSpec] = [:]
            for paneID in tab.allPaneIDs() {
                specs[paneID] = Self.spec(paneID, from: state)
                if let cwd = state.string(WorkspaceKey(.pane, paneID.raw, WorkspacePaneField.spawnCwd)) {
                    cwds[paneID] = cwd
                }
            }
            closed.append(ClosedTab(sessionID: owner, tab: tab, specs: specs))
        }

        self.init(
            tree: TreeWorkspace(
                sessions: sessions,
                activeSessionID: state.uuid(.root(WorkspaceRootField.activeSessionID)).map { SessionID(raw: $0) },
            ),
            syncInputTabs: armed,
            focusMRU: focus,
            closedTabs: closed,
            unattachedSessionID: state.uuid(.root(WorkspaceRootField.unattachedSessionID))
                .map { SessionID(raw: $0) },
            hostDisplayName: state.string(.root(WorkspaceRootField.hostDisplayName)) ?? "",
            spawnCwd: cwds,
        )
    }

    private static func session(_ id: SessionID, from state: HostWorkspaceState) -> Session? {
        let tabIDs = state.uuidList(WorkspaceKey(.session, id.raw, WorkspaceSessionField.tabOrder)) ?? []
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for tabID in tabIDs.map({ TabID(raw: $0) }) {
            guard let tab = tab(tabID, from: state) else { continue }
            tabs.append(tab)
            for paneID in tab.allPaneIDs() { specs[paneID] = spec(paneID, from: state) }
        }
        // A session with no usable tab is not a session. Minting one would invent a workspace the
        // host never published — the opposite of the point.
        guard !tabs.isEmpty else { return nil }

        var detached: [DetachedPane] = []
        let key = WorkspaceKey(.session, id.raw, WorkspaceSessionField.detachedPanes)
        for record in state.detachedPanes(key) ?? [] {
            let pane = PaneID(raw: record.pane)
            // A detached pane that is ALSO a tree leaf would break the specs invariant in both
            // directions at once. Tree membership wins, matching `normalizingSpecs()`.
            guard specs[pane] == nil else { continue }
            specs[pane] = spec(pane, from: state)
            detached.append(DetachedPane(pane: pane, originTab: record.originTab.map { TabID(raw: $0) }))
        }

        // The active tab arrives as an IDENTITY and becomes an index here — the one place the
        // conversion happens, so a reorder on another client can never leave this one pointing at a
        // position that has since become a different tab.
        let activeID = state.uuid(WorkspaceKey(.session, id.raw, WorkspaceSessionField.activeTabID))
        let activeIndex = activeID.flatMap { raw in tabs.firstIndex { $0.id.raw == raw } } ?? 0
        return Session(
            id: id,
            name: state.string(WorkspaceKey(.session, id.raw, WorkspaceSessionField.name)) ?? "",
            tabs: tabs,
            activeTabIndex: activeIndex,
            specs: specs,
            detached: detached,
        )
    }

    private static func tab(_ id: TabID, from state: HostWorkspaceState) -> Tab? {
        guard let blob = state[WorkspaceKey(.tab, id.raw, WorkspaceTabField.layoutStructure)],
              let layout = try? WorkspaceStateCodec.decodeLayout(blob)
        else { return nil }
        let root = splitNode(layout, from: state)
        let leaves = Set(root.allPaneIDs())
        let active = state.uuid(WorkspaceKey(.tab, id.raw, WorkspaceTabField.activePaneID)).map { PaneID(raw: $0) }
        let zoomed = state.uuid(WorkspaceKey(.tab, id.raw, WorkspaceTabField.zoomedPaneID)).map { PaneID(raw: $0) }
        return Tab(
            id: id,
            title: state.string(WorkspaceKey(.tab, id.raw, WorkspaceTabField.title)) ?? "",
            root: root,
            // A focus or zoom naming a pane this tab does not contain is dropped rather than
            // rendered: `normalizingActive()` would repair it anyway, and repairing here keeps the
            // value usable without a normalization pass the host may not run.
            activePane: active.flatMap { leaves.contains($0) ? $0 : nil } ?? root.allPaneIDs().first,
            zoomedPane: zoomed.flatMap { leaves.contains($0) ? $0 : nil },
        )
    }

    /// Re-weaves the stripped weights back into the shape.
    ///
    /// A split whose weight entry is missing, wrong-width, or the wrong ARITY falls back to an even
    /// flex share. That is not a guess: `.flex(1)` across N children is exactly the layout solver's
    /// default, so a lost weight cell degrades to an evenly-split tab rather than a mis-sized one.
    private static func splitNode(_ node: WorkspaceLayoutNode, from state: HostWorkspaceState) -> SplitNode {
        switch node {
        case let .leaf(id):
            return .leaf(id)
        case let .split(id, axis, children):
            let stored = state[WorkspaceKey(.splitNode, id.raw, WorkspaceSplitNodeField.weight)]
                .flatMap { WorkspaceStateCodec.decodeWeights($0) }
            let weights = stored?.count == children.count ? stored : nil
            return .split(
                id: id,
                axis: axis,
                children: children.enumerated().map { index, child in
                    WeightedChild(
                        // Repaired, not trusted: a hostile file can carry NaN or zero, and a weight
                        // of zero starves a pane to nothing.
                        weight: (weights?[index] ?? .flex(1)).repaired(),
                        node: splitNode(child, from: state),
                    )
                },
            )
        }
    }

    private static func spec(_ id: PaneID, from state: HostWorkspaceState) -> PaneSpec {
        let kindByte = state[WorkspaceKey(.pane, id.raw, WorkspacePaneField.kind)]
            .flatMap { WorkspaceStateCodec.decodeU8($0) } ?? WorkspacePaneKindTag.terminal
        return PaneSpec(
            kind: WorkspacePaneKindTag.kind(for: kindByte),
            title: state.string(WorkspaceKey(.pane, id.raw, WorkspacePaneField.title)) ?? "Terminal",
            video: state[WorkspaceKey(.pane, id.raw, WorkspacePaneField.videoTarget)]
                .flatMap { WorkspaceStateCodec.decodeVideoTarget($0) },
            userRenamed: state.bool(WorkspaceKey(.pane, id.raw, WorkspacePaneField.userRenamed)),
        )
    }
}

// MARK: - State: typed reads and the topology swap

public extension HostWorkspaceState {
    func string(_ key: WorkspaceKey) -> String? {
        self[key].flatMap { WorkspaceStateCodec.decodeString($0) }
    }

    func bool(_ key: WorkspaceKey) -> Bool {
        self[key].flatMap { WorkspaceStateCodec.decodeBool($0) } ?? false
    }

    func uuid(_ key: WorkspaceKey) -> UUID? {
        self[key].flatMap { WorkspaceStateCodec.decodeUUID($0) }
    }

    func uuidList(_ key: WorkspaceKey) -> [UUID]? {
        self[key].flatMap { WorkspaceStateCodec.decodeUUIDList($0) }
    }

    func detachedPanes(_ key: WorkspaceKey) -> [(pane: UUID, originTab: UUID?)]? {
        self[key].flatMap { WorkspaceStateCodec.decodeDetachedPanes($0) }
    }

    /// Whether a key belongs to the topology half — the half an intent writes and a restart restores.
    ///
    /// Pane keys split by FIELD, which is the whole reason this predicate exists: a pane's `title` is
    /// topology and its `liveTitle` is not, and they live one byte apart under the same objectID.
    static func isTopology(_ key: WorkspaceKey) -> Bool {
        switch WorkspaceObjectKind(rawValue: key.kind) {
        case .root:
            // The preset fields are reserved but do not cross yet; treating them as topology would
            // make every `write(topology:)` DELETE whatever a future build had put there.
            !WorkspaceTopologyOmissions.reservedRootFields.contains(key.field)
        case .session,
             .tab,
             .splitNode:
            true
        case .pane:
            PaneLiveness.topologyFields().contains(key.field)
        case .project,
             nil:
            // A project's git summary is derived, and an unknown kind from a newer host is not ours
            // to reap — dropping it would make this client's `entries` stop matching its own ack.
            false
        }
    }

    /// Replaces the topology half wholesale, leaving liveness and projects untouched.
    ///
    /// Wholesale rather than incremental because a topology write must be able to REMOVE: closing a
    /// tab has to take `tab/*` with it, and an incremental merge would leave the closed tab in the
    /// document forever, rendered by every client.
    mutating func write(topology: WorkspaceTopology) {
        let next = topology.entries()
        let supplied = Set(next.map(\.key))
        for key in entries.keys where Self.isTopology(key) && !supplied.contains(key) {
            self[key] = nil
        }
        for entry in next { set(entry.key, entry.value) }
    }

    /// The topology half as a value, or `nil` when this state carries no workspace.
    var topology: WorkspaceTopology? { WorkspaceTopology(entries: self) }
}
