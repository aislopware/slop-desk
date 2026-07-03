import Foundation

// MARK: - Side-partitioned tab display (terminal ⟂ remote-window columns)

/// The store half of the ``TabSide`` partition: the workspace renders TWO side-by-side tab regions —
/// the terminal column (sidebar + content) and the remote-window (GUI) column — over ONE
/// `Session → Tab → Pane` tree. There is still exactly ONE active tab (`Session/activeTabIndex`, the
/// keyboard-focus owner); each column *displays* the active tab when it is on that column's side, else
/// the side's last-active tab (``WorkspaceStore/displayedSideTab``), else the first tab of that side.
/// Factored into its own extension (the `type_body_length` discipline).
public extension WorkspaceStore {
    /// The tab the `side` column should display, or `nil` when the side has no tabs (the column shows
    /// its empty state). Resolution: the ACTIVE tab when it is on `side` (focus wins), else the side's
    /// remembered last-displayed tab (validated live — the tab may have closed or changed side), else
    /// the first tab of that side in tab-bar order.
    func displayedTab(on side: TabSide) -> Tab? {
        guard let session = tree.activeSession else { return nil }
        if let active = session.activeTab, session.side(ofTab: active) == side { return active }
        if let id = displayedSideTab[session.id]?[side],
           let tab = session.tabs.first(where: { $0.id == id }),
           session.side(ofTab: tab) == side
        {
            return tab
        }
        return session.tabs.first { session.side(ofTab: $0) == side }
    }

    /// The id of ``displayedTab(on:)`` — the compositor's reveal key.
    func displayedTabID(on side: TabSide) -> TabID? {
        displayedTab(on: side)?.id
    }

    /// The active session's tab count on `side` — drives the GUI column's auto-reveal/collapse.
    func tabCount(on side: TabSide) -> Int {
        guard let session = tree.activeSession else { return 0 }
        return session.tabs(on: side).count
    }

    /// Stamps the ACTIVE tab as its side's last-displayed tab and prunes stale map entries (closed
    /// sessions / tabs). Called from ``reconcileTree()`` — the funnel every tree mutation passes — so
    /// selecting, opening, closing, or re-kinding a tab keeps each column's memory current.
    func noteDisplayedSideTabs() {
        if let session = tree.activeSession, let active = session.activeTab {
            let side = session.side(ofTab: active)
            if displayedSideTab[session.id]?[side] != active.id {
                displayedSideTab[session.id, default: [:]][side] = active.id
            }
        }
        // Prune: drop closed sessions' entries and any tab id no longer live in its session (a stale id
        // is also TOLERATED at read time — `displayedTab(on:)` validates — but the map must not grow
        // unbounded across a long session of open/close).
        guard !displayedSideTab.isEmpty else { return }
        var pruned: [SessionID: [TabSide: TabID]] = [:]
        for session in tree.sessions {
            guard let sides = displayedSideTab[session.id] else { continue }
            let live = sides.filter { _, tabID in session.tabs.contains { $0.id == tabID } }
            if !live.isEmpty { pruned[session.id] = live }
        }
        displayedSideTab = pruned
    }

    /// Selects tab `tabID` of the active session (the dock / GUI-column entry — tab identity, not
    /// index). No-op when absent.
    func selectTab(id tabID: TabID) {
        guard let session = tree.activeSession,
              let index = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        selectTab(index)
    }
}
