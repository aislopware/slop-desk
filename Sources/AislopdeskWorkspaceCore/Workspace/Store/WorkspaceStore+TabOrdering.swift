import Defaults
import Foundation

// MARK: - Tab grouping / sort + manual reorder (E6 WI-3 — the store-backed sidebar order)

/// The E6 sidebar-hamburger logic factored out of ``WorkspaceStore`` so the class body stays under the
/// `type_body_length` ceiling (like `WorkspaceStore+Attention.swift` / `WorkspaceStore+Completion.swift`).
/// The stored state (``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` /
/// ``WorkspaceStore/tabLastActiveAt`` / ``WorkspaceStore/paneGitToplevel``) lives on the class —
/// `@Observable` synthesises on it; only the mutators + the pure derivation are here.
///
/// The grouping/sort selection is the SINGLE source of truth for the rendered row order (the carryover's
/// "mutate the store order, not local `@State`"); the rail is a pure derivation via ``orderedTabGroups(now:)``.
public extension WorkspaceStore {
    /// Sets the sidebar grouping (the sidebar hamburger's "Group By") and PERSISTS it (Defaults-backed
    /// ``SettingsKey/tabGrouping``). Idempotent — a no-op when unchanged so it never churns the rail.
    func setTabGrouping(_ grouping: TabGrouping) {
        guard tabGrouping != grouping else { return }
        tabGrouping = grouping
        Defaults[.tabGrouping] = grouping
        // E6 WI-7: picking By-Project kicks off the debounced git-toplevel sweep so the sections upgrade
        // from the cwd fallback to the precise repo root. A self-guarded no-op for None / By-Date.
        refreshProjectKeysIfNeeded()
    }

    /// Sets the within-section tab sort (the sidebar hamburger's "Sort By") and PERSISTS it
    /// (``SettingsKey/tabSort``). Idempotent.
    func setTabSort(_ sort: TabSort) {
        guard tabSort != sort else { return }
        tabSort = sort
        Defaults[.tabSort] = sort
    }

    /// Manual drag-reorder of the active session's tabs (dragging a tab sets Sort = Manual). Permutes
    /// `session.tabs` only — the leaf set is unchanged, so ``reconcileTree()`` is a registry no-op (no
    /// surface teardown; Design #4). A genuine move flips ``tabSort`` to ``TabSort/manual`` and persists the
    /// new order; a no-op move (same index / out-of-range) leaves the sort untouched.
    func moveTab(from: Int, to: Int) {
        let next = WorkspaceTreeOps.moveTab(from: from, to: to, in: tree)
        guard next != tree else { return }
        tree = next
        setTabSort(.manual)
        reconcileTree()
    }

    /// The WYSIWYG manual drag entry (the sidebar's `.draggable`/`.dropDestination` glue): `from`/`to` are
    /// positions into the RENDERED flat order (``orderedTabGroups(now:)`` flattened), NOT raw `session.tabs`
    /// indices. Manual order is a FLAT-LIST affordance, so this is a **no-op while ``tabGrouping`` is not
    /// ``TabGrouping/none``** — you cannot hand-order across derived buckets, and pretending to would silently
    /// discard a cross-group drop. With grouping off it materializes the rendered order into `session.tabs`
    /// then moves the single dragged tab (``WorkspaceTreeOps/moveTab(renderedOrder:from:to:in:)``), so a
    /// ``TabSort/updated`` list converts to ``TabSort/manual`` with ONLY the dragged row moving — the rest
    /// stay where they visually were. The leaf set is unchanged ⇒ ``reconcileTree()`` is a registry no-op.
    func moveTabRendered(from: Int, to: Int) {
        // Manual reorder is a flat-list affordance — disabled (a no-op) under any grouping.
        guard tabGrouping == .none else { return }
        let renderedOrder = orderedTabGroups().flatMap(\.tabIDs)
        let next = WorkspaceTreeOps.moveTab(renderedOrder: renderedOrder, from: from, to: to, in: tree)
        guard next != tree else { return }
        tree = next
        setTabSort(.manual)
        reconcileTree()
    }

    /// The rendered sidebar sections for the active session, derived purely from ``tabGrouping`` /
    /// ``tabSort`` + the recency mirror via ``TabOrderingEngine``. Empty when there is no active session.
    /// `now` is injectable (tests pin the `.byDate` boundaries); production reads the wall clock once here.
    func orderedTabGroups(now: Date = Date()) -> [OrderedTabGroup] {
        guard let session = tree.activeSession else { return [] }
        // Snapshot the main-actor lookups into plain value maps so the engine's (nonisolated) closures are
        // pure dictionary reads — no actor hop, no escaping capture of the store.
        var projectKeys: [PaneID: String] = [:]
        for tab in session.tabs {
            if let pane = tab.activePane, let key = paneProjectKey(pane) { projectKeys[pane] = key }
        }
        let recency = tabLastActiveAt
        return TabOrderingEngine.groups(
            tabs: session.tabs,
            grouping: tabGrouping,
            sort: tabSort,
            projectKey: { projectKeys[$0] },
            lastActiveAt: { recency[$0] },
            now: now,
        )
    }

    /// The ``TabGrouping/byProject`` key for pane `id`: the cached git toplevel when present
    /// (``paneGitToplevel``, populated by E6 WI-7; empty until then), else the pane's last-known cwd from
    /// the active session's spec side table. `nil` ⇒ the pane lands in the "Other" bucket.
    func paneProjectKey(_ id: PaneID) -> String? {
        if let root = paneGitToplevel[id], !root.isEmpty { return root }
        return tree.activeSession?.specs[id]?.lastKnownCwd
    }

    /// Stamps `tabID` as just-active in the runtime ``tabLastActiveAt`` recency mirror (E6 WI-3) so the
    /// ``TabSort/updated`` order floats it first. Runtime-only (NOT persisted — Design #2); pruned to the
    /// live tab set on every ``reconcileTree()``. Last write wins.
    func stampTabActivity(_ tabID: TabID, at date: Date = Date()) {
        tabLastActiveAt[tabID] = date
    }

    /// Stamps the tab that OWNS pane `id` (the agent / command-completion activity path) so a background
    /// tab with live work still floats up under ``TabSort/updated``. A no-op when the pane is not in any
    /// tab (e.g. a canvas-mode store) — resolves the owner via `tree.tab(containing:)`.
    func stampTabActivity(forPane id: PaneID, at date: Date = Date()) {
        guard let (_, tabID) = tree.tab(containing: id) else { return }
        stampTabActivity(tabID, at: date)
    }

    /// Hydrates ``tabGrouping`` / ``tabSort`` from the persisted ``SettingsKey`` (Defaults-backed, same
    /// idiom as `newTabPosition`). An absent key reads the declared default; a stale / invalid raw value
    /// repairs to the default through the typed key. Called once from `init`.
    func hydrateTabPreferences() {
        tabGrouping = SettingsKey.tabGrouping
        tabSort = SettingsKey.tabSort
    }

    /// Prunes the TREE-keyed sidebar mirrors to the live tree on every ``reconcileTree()``: the tab-recency
    /// map + the E20 manual tab-badge override (both keyed by ``TabID``) and the per-pane git-toplevel cache
    /// (a tree-only By-Project key, E6 WI-7). A closed tab / pane must not keep a stale stamp (so `.updated`
    /// can't reference a ghost, a closed tab can't keep a manual badge, and no dict grows unbounded across a
    /// long session of open/close). All are empty in the common case ⇒ cheap.
    func pruneTreeSidebarMirrors() {
        // Both the recency mirror and the E20 manual tab-badge override are TabID-keyed → share one live-tab
        // set, computed once only when either needs pruning (both empty in the common case ⇒ cheap).
        if !tabLastActiveAt.isEmpty || !tabBadgeOverrides.isEmpty {
            let liveTabs = Set(tree.sessions.flatMap { session in session.tabs.map(\.id) })
            if !tabLastActiveAt.isEmpty {
                tabLastActiveAt = tabLastActiveAt.filter { liveTabs.contains($0.key) }
            }
            if !tabBadgeOverrides.isEmpty {
                tabBadgeOverrides = tabBadgeOverrides.filter { liveTabs.contains($0.key) }
            }
        }
        if !paneGitToplevel.isEmpty {
            let liveLeaves = Set(tree.allPaneIDs())
            paneGitToplevel = paneGitToplevel.filter { liveLeaves.contains($0.key) }
        }
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
