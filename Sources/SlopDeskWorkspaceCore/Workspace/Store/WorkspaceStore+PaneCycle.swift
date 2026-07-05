import Foundation

// MARK: - WorkspaceStore × Sequential pane cycle + reopen-closed (E1 ES-E1-2 store hooks)

/// The E1 sequential-pane-cycle (⌘]/⌘[) and reopen-closed-pane (⌘⇧T) store hooks, split into their own
/// extension so the (already large) ``WorkspaceStore`` body stays under the lint type-body ceiling — the
/// same reason ``WorkspaceStore+FontScroll`` and ``WorkspaceStore+Blocks`` exist.
public extension WorkspaceStore {
    /// Sequentially cycles focus through the ACTIVE TAB's panes in pre-order DFS — the ⌘]/⌘[ "focus next/
    /// previous pane" chord (E1 ES-E1-2; distinct from ⌘⇧]/⌘⇧[ tab cycling). `forward == true` steps to the
    /// next leaf in DFS order, `false` to the previous; the walk WRAPS (last → first / first → last). A no-op
    /// when the active tab has fewer than two panes (nothing to cycle to). Routes the resolved target through
    /// ``focusPaneTree(_:)`` so it shares the focus/raise/reconcile path of every other tree-focus change.
    func cyclePaneFocusTree(forward: Bool) {
        if let target = paneCycleTreeTarget(forward: forward) { focusPaneTree(target) }
    }

    /// The pane a ``cyclePaneFocusTree(forward:)`` step would focus, or `nil` when it is a no-op (no active
    /// tab, fewer than two panes, or no resolvable tiled active pane to step from). Pure (no focus side
    /// effect) so the `count > 1` wrap guard is unit-testable in isolation — mirrors
    /// ``recentPaneTarget(forward:)`` / ``inGroupCycleTarget(forward:)``.
    ///
    /// Delegates straight to the pure ``WorkspaceTreeOps/cyclePaneTarget(forward:in:)`` (E3 WI-5) so the
    /// DFS-wrap math has ONE source — the order is the active tab's ``Tab/allPaneIDs()`` (pre-order DFS),
    /// the same order the reconcile diff + carousel read.
    internal func paneCycleTreeTarget(forward: Bool) -> PaneID? {
        WorkspaceTreeOps.cyclePaneTarget(forward: forward, in: tree)
    }

    /// Reopens the most recently CLOSED tree tab (the ⌘⇧T "Reopen Closed Tab" chord, E3 WI-3). Delegates to
    /// the index-addressed ``reopenClosedTab(at:)`` with LIFO index `0` (the top of the stack — the tab a
    /// `popLast()` would have returned), so the chord and the Open-Quickly "Recent" rows share ONE reopen
    /// path. A graceful no-op when the LIFO is empty.
    func reopenLastClosedPane() {
        reopenClosedTab(at: 0)
    }

    /// Reopens the recently-closed tab at LIFO `lifoIndex` (0 = most-recently closed, the top of the stack;
    /// 1 = the one closed before it; …) — the index-addressed reopen the Open-Quickly **Recent** rows route
    /// through so row N reopens EXACTLY tab N, not always the newest (the bug a plain `popLast()` caused for
    /// every row but the first). Removes that record from the in-memory ``recentlyClosedTabs`` LIFO and
    /// re-inserts it via ``WorkspaceTreeOps/insertTab(_:specs:at:in:)`` at the configured ``NewTabPosition``
    /// — restoring the whole tab (its split tree + every pane's spec, keeping the original ``PaneID``s). The
    /// tab lands back in its OWNING session when that session is still alive; otherwise (the session was
    /// closed while the record sat on the LIFO) it falls back to the active session. The reopened session is
    /// FRESH — scrollback does not survive a close, by design. An out-of-range `lifoIndex` (including a
    /// negative one) is a graceful no-op returning `nil` — never a trap (the picker passes a row-derived
    /// index over untrusted-ish UI state). Returns the active ``PaneID`` of the reopened tab, or `nil` on a
    /// no-op.
    @discardableResult
    func reopenClosedTab(at lifoIndex: Int) -> PaneID? {
        // LIFO index → array index: the stack TOP (index 0) is the LAST element (appended oldest→newest).
        let arrayIndex = recentlyClosedTabs.count - 1 - lifoIndex
        guard recentlyClosedTabs.indices.contains(arrayIndex) else { return nil }
        let record = recentlyClosedTabs.remove(at: arrayIndex)
        // Land the restored tab back in its owning session when it still exists; `insertTab` inserts into
        // whichever session is active, so re-point the active session first (the fallback when the owner
        // vanished is simply to leave the active session as-is).
        if let owner = record.sessionID, tree.sessions.contains(where: { $0.id == owner }) {
            tree.activeSessionID = owner
        }
        tree = WorkspaceTreeOps.insertTab(
            record.tab, specs: record.specs, at: SettingsKey.newTabPosition, in: tree,
        )
        // E6 WI-6: `insertTab` selects the restored tab (sets `activeTabIndex`) — stamp its recency (parity
        // with `newTab` / `selectTab`) so the just-reopened, now-active tab floats first under `.updated`
        // and lands in "Today" under By-Date, instead of sorting last on a nil recency.
        if let newTabID = tree.activeSession?.activeTab?.id { stampTabActivity(newTabID) }
        reconcileTree()
        return tree.activeSession?.activeTab?.activePane
    }
}
