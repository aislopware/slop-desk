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

    /// The active session's panes in ONE flat order: tabs in creation order, and within each tab its
    /// split tree in pre-order DFS (``Tab/allPaneIDs()`` — the same walk the reconcile diff and the
    /// ⌘]/⌘[ cycle read).
    ///
    /// The tail every ⌃⇥ ring falls back to. NOT the ⌘1…⌘9 numbering — the digits count
    /// ``displayOrderedPaneIDs()``, the project-grouped order the sidebar draws.
    func flatOrderedPaneIDs() -> [PaneID] {
        tree.activeSession?.tabs.flatMap { $0.allPaneIDs() } ?? []
    }

    /// The active session's panes in the order the sidebar DRAWS them: ``flatOrderedPaneIDs()``
    /// re-bucketed through the SAME By-Project sectioning the rail renders
    /// (``TabOrderingEngine/bucketedByProject(_:projectKey:)`` over each pane's OWN key — a
    /// non-terminal / keyless pane in the "Other" bucket, matching `RailRowsBuilder`'s per-row key),
    /// then flattened section by section.
    ///
    /// This is the numbering ⌘1…⌘9 lands on: the digit must name the row the EYE counts down the
    /// sidebar, and the sidebar is project-grouped — the moment a new tab for an already-open project
    /// appends past a different project's tab, creation order and drawn order disagree (the pane-level
    /// twin of ``TabOrderingEngine/projectGroupedTabOrder(_:projectKey:)``, which exists for the same
    /// reason at tab granularity). Section collapse and the search filter are view state and
    /// deliberately do NOT move numbers — a number moves only when a pane opens, closes, moves, or
    /// changes project.
    func displayOrderedPaneIDs() -> [PaneID] {
        guard let session = tree.activeSession else { return [] }
        let keyed = session.tabs.flatMap { tab in
            tab.allPaneIDs().map { id -> (id: PaneID, key: String?) in
                let kind = session.specs[id]?.kind ?? .terminal
                return (id, kind == .terminal ? paneProjectKey(id) : nil)
            }
        }
        return TabOrderingEngine.bucketedByProject(keyed, projectKey: \.key)
            .flatMap { $0.elements.map(\.id) }
    }

    /// The ⌘-digit that focuses pane `id`, or `nil` when it has none (only the first NINE panes of
    /// ``displayOrderedPaneIDs()`` get one — there is no ⌘10). The rail's ⌘-held number hint reads
    /// this, so the digit a row shows and the pane ``selectPaneNumber(_:)`` lands on can never
    /// disagree.
    func shortcutNumber(for id: PaneID) -> Int? {
        guard let index = displayOrderedPaneIDs().firstIndex(of: id), index < 9 else { return nil }
        return index + 1
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

    /// Focuses the `number`-th PANE (1-based) of the active session in ``displayOrderedPaneIDs()``
    /// order — the ⌘1…⌘9 command entry. A number past the pane count is a no-op (it clamps to nothing
    /// rather than the last pane: a missing number simply does nothing, the native ⌘-digit idiom).
    ///
    /// The digit names a PANE rather than a tab because the pane is this workspace's unit of work — it
    /// is what the sidebar lists, what ⌃⇥ walks and what a notification points at. Numbering tabs while
    /// every other surface counts panes made ⌘3 mean one thing in the chord and another on screen. And
    /// it counts the DRAWN order, not creation order, because the digit is an act of pointing at the
    /// rail: counting `session.tabs` while the rail groups by project made ⌘3 land on a row nowhere
    /// near the third one on screen.
    /// Landing goes through ``revealPaneTree(_:)``, so a pane in a background tab brings its tab with it.
    func selectPaneNumber(_ number: Int) {
        let panes = displayOrderedPaneIDs()
        let index = number - 1
        guard panes.indices.contains(index) else { return }
        revealPaneTree(panes[index])
    }
}
