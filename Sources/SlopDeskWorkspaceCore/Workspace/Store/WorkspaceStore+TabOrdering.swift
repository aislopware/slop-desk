import Foundation
import SlopDeskWorkspaceModel

// MARK: - Sidebar ordering (ALWAYS grouped By-Project, in creation order) + tab selection helpers

/// The sidebar-ordering surface factored out of ``WorkspaceStore`` so the class body stays under the
/// `type_body_length` ceiling (like `WorkspaceStore+Attention.swift` / `WorkspaceStore+Completion.swift`).
///
/// The sidebar has exactly ONE layout (see `docs/DECISIONS.md`): panes bucket by their By-Project key
/// and both sections and rows follow first-appearance in `session.tabs` (creation order). There is no
/// client-side grouping/sorting, recency stamps, manual drag-reorder, or git-toplevel sweep — the key is
/// HOST-pushed (wire type 34 → ``WorkspaceStore/setProjectKey(_:for:)``) so every reconnect converges on
/// the same sections regardless of client-side state.
public extension WorkspaceStore {
    /// The active session's tab ids in ARRAY (== creation) order — the within-section row-order basis for
    /// the per-pane By-Project sectioning (``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``).
    /// Empty when there is no active session.
    func flatOrderedTabIDs() -> [TabID] {
        tree.activeSession?.tabs.map(\.id) ?? []
    }

    /// This store's reading of ``TabOrderingEngine/paneProjectKey(_:projectKey:cwd:)`` — pane `id`'s
    /// HOST-pushed `pane/projectKey` (wire type 34), else its `pane/cwd` until the first push lands.
    /// `nil` ⇒ the pane lands in the "Other" bucket.
    ///
    /// The write sinks (``WorkspaceStore/setProjectKey(_:for:)``, ``WorkspaceStore/setLastKnownCwd(_:for:)``)
    /// already drop a transient plugin-cache reading; the engine's guard is the read-side backstop so
    /// grouping stays clean even if one slips through.
    func paneProjectKey(_ id: PaneID) -> String? {
        TabOrderingEngine.paneProjectKey(
            id, projectKey: { projectKey(for: $0) }, cwd: { paneCwd(for: $0) },
        )
    }

    // MARK: Close → next selection

    /// The tab MRU the close path returns to — the DOCUMENT's, most-recent first.
    ///
    /// Host-owned (``WorkspaceTopology/focusMRU``), because close is an intent: the successor is picked
    /// by ``WorkspaceIntentApplier``, and two clients computing it from two local rings pick two
    /// different tabs. Empty for a session with nothing visited yet, which is what makes a cold launch
    /// fall through to the project-section rule.
    var tabFocusMRU: [TabID] {
        observeWorkspaceMirror()
        guard let topology = workspaceMirror.topology, let session = topology.tree.activeSessionID
        else { return [] }
        return topology.focusMRU[session] ?? []
    }

    /// Prunes the TREE-keyed sidebar mirror to the live tree on every ``reconcileTree()``: the E20 manual
    /// tab-badge override (keyed by ``TabID``). A closed tab must not keep a stale manual badge (and the
    /// dict must not grow unbounded across a long session of open/close). Empty in the common case ⇒ cheap.
    func pruneTreeSidebarMirrors() {
        guard !tabBadgeOverrides.isEmpty else { return }
        let liveTabs = Set(tree.sessions.flatMap { session in session.tabs.map(\.id) })
        tabBadgeOverrides = tabBadgeOverrides.filter { liveTabs.contains($0.key) }
    }

    /// Selects the tab `delta` away from the active tab in the active session, clamped to the tab range
    /// (no wrap — a list stops at its ends, like the palette). The "next/prev tab" command entry. No-op
    /// without an active session.
    func cycleTab(by delta: Int) {
        guard let session = tree.activeSession else { return }
        let count = session.tabs.count
        guard count > 1 else { return }
        let next = min(max(session.activeTabIndex + delta, 0), count - 1)
        guard next != session.activeTabIndex else { return }
        selectTab(next)
    }

    /// Selects the `number`-th tab (1-based) of the active session, if it exists. The ⌘1…⌘9 command entry;
    /// a number past the tab count is a no-op (clamps to nothing rather than the last tab — a missing tab
    /// number simply does nothing, the native ⌘N tab idiom).
    func selectTabNumber(_ number: Int) {
        guard let session = tree.activeSession else { return }
        let index = number - 1
        guard session.tabs.indices.contains(index) else { return }
        selectTab(index)
    }
}
