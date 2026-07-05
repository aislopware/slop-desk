import Foundation

// MARK: - moveTab (manual drag-reorder — pure permutation of the active session's tab array)

/// The pure tab-reorder op behind manual drag-to-reorder in the vertical sidebar (E6 plan WI-3 /
/// Design #4). It ONLY permutes the active session's ``Session/tabs`` array — the **leaf set is
/// unchanged**, so the store wrapper's ``WorkspaceStore/reconcileTree()`` is a registry no-op (no
/// `teardown`, no surface rebuild; the memory rule "never tear down surface"). Selection follows the SAME
/// tab id across the move, mirroring ``WorkspaceTreeOps/selectTab(_:in:)``'s active-state shape.
public extension WorkspaceTreeOps {
    /// Moves the tab at `from` to index `to` in the ACTIVE session, clamping `to` into the valid range and
    /// keeping `activeTabIndex` pointed at the tab that was selected before the move. No-op (returns `ws`
    /// unchanged) when there is no active session, fewer than two tabs, an out-of-range `from`, or the move
    /// is a no-op (`to` clamps back to `from`). Pure — preserves the specs == leafIDs invariant (no leaf is
    /// added/removed) and the active-selection invariants.
    static func moveTab(from: Int, to: Int, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var session = ws.sessions[sIdx]
        let count = session.tabs.count
        // Need ≥ 2 tabs and a real source index; a single-tab session can't reorder.
        guard count > 1, session.tabs.indices.contains(from) else { return ws }
        // Clamp the destination into [0, count - 1] (validate-then-clamp on an untrusted drag index).
        let dest = min(max(to, 0), count - 1)
        guard dest != from else { return ws }
        // Remember the selected tab's IDENTITY so selection follows it across the permutation.
        let activeID = session.tabs.indices.contains(session.activeTabIndex)
            ? session.tabs[session.activeTabIndex].id
            : nil
        let moving = session.tabs.remove(at: from)
        session.tabs.insert(moving, at: dest)
        if let activeID, let newActive = session.tabs.firstIndex(where: { $0.id == activeID }) {
            session.activeTabIndex = newActive
        }
        var copy = ws
        copy.sessions[sIdx] = session
        return copy
    }

    /// Rendered-order-aware manual reorder — the **WYSIWYG** drag entry. `renderedOrder` is the flat list of
    /// the active session's tab ids AS DISPLAYED (``WorkspaceStore/orderedTabGroups(now:)`` flattened); `from`
    /// and `to` are positions INTO that rendered list, **not** raw `session.tabs` indices. It FIRST
    /// materializes the rendered order into `session.tabs` (so a recency-driven ``TabSort/updated`` order
    /// becomes the concrete array the user is looking at), THEN moves the single dragged tab by its rendered
    /// position — so only that one row moves and the rest stay exactly where they were on screen: a drag
    /// converts the live order into `manual` without reshuffling siblings.
    ///
    /// A no-op (`from == clamped(to)`, an out-of-range `from`, fewer than two tabs, or a `renderedOrder` that
    /// is not an exact permutation of the live tabs) returns `ws` UNCHANGED — it neither materializes nor
    /// reshuffles, so the store wrapper won't flip the sort on a dud drag. Pure; preserves the
    /// specs == leafIDs invariant (no leaf added/removed) and keeps `activeTabIndex` on the SAME tab id.
    static func moveTab(renderedOrder: [TabID], from: Int, to: Int, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var session = ws.sessions[sIdx]
        let count = session.tabs.count
        // Need ≥ 2 tabs and a real source position (an index into the rendered list, == the tab count).
        guard count > 1, session.tabs.indices.contains(from) else { return ws }
        // The rendered list must be an EXACT permutation of the live tabs (validate-then-drop on an untrusted
        // order): same length AND same id set ⇒ no tab is dropped or duplicated by a stale / foreign order.
        let liveIDs = session.tabs.map(\.id)
        guard renderedOrder.count == count, Set(renderedOrder) == Set(liveIDs) else { return ws }
        // Materialize the rendered order into a concrete tab array (every lookup is guaranteed by the check
        // above; the guard stays as a belt-and-braces drop rather than a force-unwrap).
        let byID = Dictionary(session.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rendered: [Tab] = []
        rendered.reserveCapacity(count)
        for id in renderedOrder {
            guard let tab = byID[id] else { return ws }
            rendered.append(tab)
        }
        // Clamp the destination into [0, count - 1] (validate-then-clamp on an untrusted drag position); a
        // move to its own rendered slot is a no-op (don't materialize / flip the sort for a null drag).
        let dest = min(max(to, 0), count - 1)
        guard dest != from else { return ws }
        // Remember the selected tab's IDENTITY so selection follows it across the materialize + move.
        let activeID = session.tabs.indices.contains(session.activeTabIndex)
            ? session.tabs[session.activeTabIndex].id
            : nil
        let moving = rendered.remove(at: from)
        rendered.insert(moving, at: dest)
        session.tabs = rendered
        if let activeID, let newActive = session.tabs.firstIndex(where: { $0.id == activeID }) {
            session.activeTabIndex = newActive
        }
        var copy = ws
        copy.sessions[sIdx] = session
        return copy
    }
}
