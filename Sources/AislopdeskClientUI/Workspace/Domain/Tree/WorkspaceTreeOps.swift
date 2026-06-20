import CoreGraphics
import Foundation

// MARK: - WorkspaceTreeOps (the facade over Session / Tab / split tree)

/// The pure operation facade over the tree-rooted ``TreeWorkspace`` (docs/42 §"Pure ops"). Every method
/// is a pure transformation on the value types — it returns a NEW ``TreeWorkspace`` (some also the minted
/// ``PaneID``), never mutates in place, never does I/O or touches the GUI. Each op preserves the
/// **specs == leafIDs invariant** and keeps the active-selection invariants (active session / tab /
/// pane never dangle), so the store cutover (W4) can wrap these directly before `reconcile()`.
///
/// Float math follows the house idiom: separate `*`/`+`/`/` (never `addingProduct`/`fma`) and
/// NaN-faithful ordered `Double.maximum`/`Double.minimum`.
public enum WorkspaceTreeOps {
    // MARK: Split

    /// Splits the pane `target` along `axis`, creating a new leaf carrying `newSpec`. The new pane is
    /// inserted as a sibling if the parent split already has `axis`, else `target` becomes a 2-child
    /// split (see ``SplitNode/splitting(_:axis:inserting:)``). The new pane is focused/activated. Returns
    /// the new workspace and the minted ``PaneID``. A no-op (target absent) returns the workspace
    /// unchanged with a throw-away id that is not in the tree — callers split a real pane.
    public static func splitPane(
        _ target: PaneID,
        axis: SplitAxis,
        newSpec: PaneSpec,
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, PaneID) {
        let newID = PaneID()
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return (ws, newID) }
        var copy = ws
        var session = copy.sessions[sIdx]
        var tab = session.tabs[tIdx]
        guard let newRoot = tab.root.splitting(target, axis: axis, inserting: newID) else { return (ws, newID) }
        tab.root = newRoot
        tab.activePane = newID // the freshly split pane takes focus
        session.tabs[tIdx] = tab
        session.specs[newID] = newSpec // keep the specs == leafIDs invariant
        copy.sessions[sIdx] = session
        return (copy, newID)
    }

    // MARK: Close a pane (cascade + rebalance + refocus)

    /// Closes pane `target`: removes it from its tab's tree (collapsing the single-child parent and
    /// re-balancing surviving siblings), drops its spec, and cascades —
    /// - the tab's **last** pane closing closes the tab (selecting an adjacent tab);
    /// - the session's **last** tab closing closes the session (selecting another session);
    /// - the workspace's **last** pane closing re-seeds a fresh default pane (the workspace is never
    ///   empty).
    /// A dangling zoom on the closed pane is cleared; focus moves to a geometric neighbour via
    /// ``FocusResolver`` (else the surviving first leaf). No-op if `target` is absent. Preserves the
    /// invariant.
    public static func closePane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        var copy = ws
        var session = copy.sessions[sIdx]
        var tab = session.tabs[tIdx]

        // Pick the replacement focus BEFORE the tree mutates (geometric neighbour of the closing pane).
        let refocus = neighbour(of: target, in: tab)

        let pruned = tab.root.removing(target)
        session.specs.removeValue(forKey: target) // drop the closed pane's spec

        guard let newRoot = pruned else {
            // The tab emptied → close the tab and cascade.
            session.tabs.remove(at: tIdx)
            copy.sessions[sIdx] = session
            return cascadeAfterTabRemoval(sessionIndex: sIdx, removedTabIndex: tIdx, in: copy).normalized()
        }

        tab.root = newRoot
        // Clear a dangling zoom; repoint focus.
        if tab.zoomedPane == target { tab.zoomedPane = nil }
        if tab.activePane == target { tab.activePane = refocus ?? newRoot.firstLeafID }
        session.tabs[tIdx] = tab
        copy.sessions[sIdx] = session
        return copy.normalizingSpecs()
    }

    /// Cascade housekeeping after a tab was removed from `sessionIndex`: if the session has no tabs left,
    /// remove the session too; if that was the last session, re-seed a default. Otherwise just clamp the
    /// session's active tab index. Pure.
    private static func cascadeAfterTabRemoval(
        sessionIndex: Int,
        removedTabIndex: Int,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        var copy = ws
        if copy.sessions[sessionIndex].tabs.isEmpty {
            // Session emptied → drop it.
            let removedID = copy.sessions[sessionIndex].id
            copy.sessions.remove(at: sessionIndex)
            if copy.sessions.isEmpty {
                return .defaultWorkspace()
            }
            // Repoint the active session if it pointed at the removed one.
            if copy.activeSessionID == removedID {
                let newIndex = Int(Double.minimum(Double(sessionIndex), Double(copy.sessions.count - 1)))
                copy.activeSessionID = copy.sessions[newIndex].id
            }
            return copy
        }
        // Session survives → select an adjacent tab.
        var session = copy.sessions[sessionIndex]
        let newIndex = Int(Double.minimum(Double(removedTabIndex), Double(session.tabs.count - 1)))
        session.activeTabIndex = Int(Double.maximum(Double(newIndex), 0))
        copy.sessions[sessionIndex] = session
        return copy
    }

    // MARK: Zoom (out-of-tree)

    /// Toggles render-only zoom on `target`: sets the owning tab's `zoomedPane` to `target` (or clears it
    /// if already zoomed on that pane). The split TREE is untouched — zoom is out-of-tree state. No-op if
    /// `target` is absent.
    public static func toggleZoom(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        var copy = ws
        var tab = copy.sessions[sIdx].tabs[tIdx]
        tab.zoomedPane = (tab.zoomedPane == target) ? nil : target
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    // MARK: Resize

    /// Shifts flex weight by `delta` between the children at `leadingChildIndex` and `leadingChildIndex+1`
    /// of split `splitID` (the divider between them). Sum-preserving + clamped at ``SplitWeight/minWeight``
    /// (see ``SplitNode/resizingDivider(splitID:leadingIndex:delta:)``). Searches the active session's
    /// active tab. No-op if the split / indices are absent.
    public static func resizeDivider(
        splitID: SplitNodeID,
        leadingChildIndex: Int,
        delta: Double,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var copy = ws
        let tIdx = copy.sessions[sIdx].activeTabIndex
        guard copy.sessions[sIdx].tabs.indices.contains(tIdx) else { return ws }
        var tab = copy.sessions[sIdx].tabs[tIdx]
        tab.root = tab.root.resizingDivider(splitID: splitID, leadingIndex: leadingChildIndex, delta: delta)
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    // MARK: Move / swap

    /// Exchanges the positions of two leaves within whichever tab(s) own them (same-tab swap moves both
    /// ids; cross-tab is not attempted — the ids move only if both are in the same tab). No-op if either
    /// is absent or they are in different tabs. Preserves the invariant (specs unchanged, leaf set
    /// unchanged).
    public static func swapPanes(_ a: PaneID, _ b: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard a != b, let (sa, ta) = locate(a, in: ws), let (sb, tb) = locate(b, in: ws), sa == sb, ta == tb
        else { return ws }
        var copy = ws
        var tab = copy.sessions[sa].tabs[ta]
        tab.root = tab.root.swapping(a, b)
        copy.sessions[sa].tabs[ta] = tab
        return copy
    }

    /// Moves pane `pane` in `direction` by EXCHANGING it with its geometric neighbour on that side (Zellij
    /// "move pane"): resolves the directional neighbour against the active tab solved into `bounds` (the same
    /// geometry the user sees + ``moveFocus(_:bounds:in:)`` reads), then ``swapPanes(_:_:in:)`` the two.
    /// `.next`/`.previous` and "no neighbour that side" are no-ops (returns `ws` unchanged). Because
    /// `swapPanes` keeps the ``PaneID`` identity, `pane` stays the active pane after the move. Preserves the
    /// invariant (specs + leaf set unchanged — only positions move).
    public static func movePaneInDirection(
        _ pane: PaneID,
        _ direction: FocusDirection,
        bounds: CGRect,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(pane, in: ws) else { return ws }
        switch direction {
        case .next,
             .previous:
            return ws // directional move only — cycling has no "swap" meaning
        case .left,
             .right,
             .up,
             .down:
            let tab = ws.sessions[sIdx].tabs[tIdx]
            let frames = SplitLayoutSolver.solve(tab.root, in: bounds)
            guard let neighbour = FocusResolver.neighbor(of: pane, direction, in: SolvedLayout(frames: frames)),
                  neighbour != pane
            else { return ws }
            return swapPanes(pane, neighbour, in: ws)
        }
    }

    // MARK: Resize the active pane (keyboard divider nudge)

    /// Grows / shrinks pane `pane` along `direction` by nudging the divider of the nearest enclosing split
    /// on the relevant axis (the keyboard counterpart to a drag-resize). `.left`/`.right` act on the nearest
    /// enclosing **horizontal** split (width); `.up`/`.down` on the nearest **vertical** split (height).
    /// `.right`/`.down` GROW the pane, `.left`/`.up` SHRINK it. `.next`/`.previous` and "no enclosing split"
    /// are no-ops. The underlying ``resizeDivider(splitID:leadingChildIndex:delta:in:)`` is sum-preserving +
    /// clamped at ``SplitWeight/minWeight``, so the active pane can never starve a sibling to nothing.
    /// Preserves the invariant (the leaf set is unchanged).
    public static func resizeActivePane(
        _ pane: PaneID,
        _ direction: FocusDirection,
        step: Double,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        let axis: SplitAxis
        let grow: Bool
        switch direction {
        case .left: (axis, grow) = (.horizontal, false)
        case .right: (axis, grow) = (.horizontal, true)
        case .up: (axis, grow) = (.vertical, false)
        case .down: (axis, grow) = (.vertical, true)
        case .next,
             .previous:
            return ws
        }
        guard let (sIdx, tIdx) = locate(pane, in: ws),
              let enclosing = ws.sessions[sIdx].tabs[tIdx].root.enclosingSplit(of: pane, axis: axis)
        else { return ws }

        let i = enclosing.childIndex
        let lastIndex = enclosing.childCount - 1
        // Map (grow/shrink, position) to which divider to nudge and by what signed delta so the ACTIVE pane
        // grows/shrinks. For a non-last child the divider to its right (leadingIndex == i) governs it:
        // a +delta there grows the leading (active) child. For the LAST child there is no divider to its
        // right, so the i-1 divider governs it with the sign flipped (a −delta there grows the trailing
        // (active) child).
        let leadingIndex: Int
        let delta: Double
        if i < lastIndex {
            leadingIndex = i
            delta = grow ? step : -step
        } else {
            leadingIndex = i - 1
            delta = grow ? -step : step
        }
        // Mutate the LOCATED tab directly (mirror swapPanes / balanceSplits) — not the active-tab-scoped
        // resizeDivider — so the nudge lands even when `pane` is in a non-active tab.
        var copy = ws
        var tab = copy.sessions[sIdx].tabs[tIdx]
        tab.root = tab.root.resizingDivider(splitID: enclosing.splitID, leadingIndex: leadingIndex, delta: delta)
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    // MARK: Balance splits (tmux even-layout)

    /// Resets every `.split`'s `.flex` children in the tab that owns `pane` to an EQUAL share (tmux
    /// "select-layout even-*"), leaving `.fixed` bands untouched. The tree SHAPE and leaf set are unchanged
    /// — only the weights equalize — so the invariant holds. No-op if `pane` is absent.
    public static func balanceSplits(activeTabContaining pane: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(pane, in: ws) else { return ws }
        var copy = ws
        copy.sessions[sIdx].tabs[tIdx].root = copy.sessions[sIdx].tabs[tIdx].root.rebalanced()
        return copy
    }

    // MARK: Focus

    /// Focuses `target` (sets the owning tab's `activePane` and selects that session/tab). No-op if
    /// absent.
    public static func focusPane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        var copy = ws
        copy.activeSessionID = copy.sessions[sIdx].id
        copy.sessions[sIdx].activeTabIndex = tIdx
        copy.sessions[sIdx].tabs[tIdx].activePane = target
        return copy
    }

    /// Moves focus in `direction` from the active tab's `activePane`, resolved geometrically against the
    /// freshly solved layout (so "move left" matches the pane the user sees). `bounds` is the area the
    /// active tab is solved into (the store passes the live viewport; tests pass any finite rect). No-op
    /// if there is no active pane / no neighbour.
    public static func moveFocus(
        _ direction: FocusDirection,
        bounds: CGRect,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        let session = ws.sessions[sIdx]
        let tIdx = session.activeTabIndex
        guard session.tabs.indices.contains(tIdx) else { return ws }
        let tab = session.tabs[tIdx]
        guard let from = tab.activePane else { return ws }

        let target: PaneID?
        switch direction {
        case .next,
             .previous:
            target = FocusResolver.cycle(tab.root.allPaneIDs(), from: from, forward: direction == .next)
        case .left,
             .right,
             .up,
             .down:
            let frames = SplitLayoutSolver.solve(tab.root, in: bounds)
            target = FocusResolver.neighbor(of: from, direction, in: SolvedLayout(frames: frames))
        }
        guard let next = target else { return ws }
        return focusPane(next, in: ws)
    }

    // MARK: Tabs

    /// Adds a new tab (single leaf carrying `spec`) to the active session and selects it. Returns the new
    /// workspace + the new pane's id. No-op (returns a throw-away id) if there is no active session.
    public static func newTab(in ws: TreeWorkspace, spec: PaneSpec) -> (TreeWorkspace, PaneID) {
        let paneID = PaneID()
        guard let sIdx = ws.activeSessionIndex else { return (ws, paneID) }
        var copy = ws
        let tab = Tab(root: .leaf(paneID), activePane: paneID)
        copy.sessions[sIdx].tabs.append(tab)
        copy.sessions[sIdx].activeTabIndex = copy.sessions[sIdx].tabs.count - 1
        copy.sessions[sIdx].specs[paneID] = spec
        return (copy, paneID)
    }

    /// Closes tab `tabID` (in whichever session owns it), dropping every pane's spec, and cascades to the
    /// session/default exactly like ``closePane(_:in:)``. Selects an adjacent tab. No-op if absent.
    public static func closeTab(_ tabID: TabID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locateTab(tabID, in: ws) else { return ws }
        var copy = ws
        // Drop the closing tab's specs.
        let closing = copy.sessions[sIdx].tabs[tIdx]
        for id in closing.allPaneIDs() { copy.sessions[sIdx].specs.removeValue(forKey: id) }
        copy.sessions[sIdx].tabs.remove(at: tIdx)
        return cascadeAfterTabRemoval(sessionIndex: sIdx, removedTabIndex: tIdx, in: copy).normalized()
    }

    /// Selects tab at `index` in the active session (clamped). No-op if out of range / no active session.
    public static func selectTab(_ index: Int, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex, ws.sessions[sIdx].tabs.indices.contains(index) else { return ws }
        var copy = ws
        copy.sessions[sIdx].activeTabIndex = index
        return copy
    }

    /// Renames tab `tabID` (no-op if absent).
    public static func renameTab(_ tabID: TabID, to title: String, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locateTab(tabID, in: ws) else { return ws }
        var copy = ws
        copy.sessions[sIdx].tabs[tIdx].title = title
        return copy
    }

    // MARK: Sessions

    /// Adds a new session (one tab, one leaf carrying `spec`) and selects it. Returns the new workspace +
    /// the new pane's id.
    public static func newSession(in ws: TreeWorkspace, name: String, spec: PaneSpec) -> (TreeWorkspace, PaneID) {
        let session = Session.singlePane(name: name, spec: spec)
        var copy = ws
        copy.sessions.append(session)
        copy.activeSessionID = session.id
        return (copy, session.allPaneIDs()[0])
    }

    /// Inserts a pre-built `session` (e.g. one ``SessionTemplateEngine/makeSession(from:name:)`` expanded)
    /// into `ws`, appending it to `sessions`; when `makeActive` it also becomes the selected session. Other
    /// sessions are untouched (their tabs / specs / active state are preserved), so the **specs == leafIDs
    /// invariant** holds for the whole workspace as long as the inserted session holds it. Mirrors the tail
    /// of ``newSession(in:name:spec:)`` for an already-constructed session. Pure.
    public static func insertSession(
        _ session: Session,
        in ws: TreeWorkspace,
        makeActive: Bool,
    ) -> TreeWorkspace {
        var copy = ws
        copy.sessions.append(session)
        if makeActive {
            copy.activeSessionID = session.id
        }
        return copy
    }

    /// Closes session `sessionID` (dropping all its tabs/panes); selects another session, or re-seeds a
    /// default when it was the only one (the workspace is never empty). No-op if absent.
    public static func closeSession(_ sessionID: SessionID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let sIdx = ws.sessions.firstIndex(where: { $0.id == sessionID }) else { return ws }
        var copy = ws
        copy.sessions.remove(at: sIdx)
        if copy.sessions.isEmpty {
            return .defaultWorkspace()
        }
        if copy.activeSessionID == sessionID {
            let newIndex = Int(Double.minimum(Double(sIdx), Double(copy.sessions.count - 1)))
            copy.activeSessionID = copy.sessions[newIndex].id
        }
        return copy.normalized()
    }

    /// Selects session `sessionID` (no-op if absent).
    public static func selectSession(_ sessionID: SessionID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard ws.sessions.contains(where: { $0.id == sessionID }) else { return ws }
        var copy = ws
        copy.activeSessionID = sessionID
        return copy
    }

    /// Renames session `sessionID` (no-op if absent).
    public static func renameSession(_ sessionID: SessionID, to name: String, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let sIdx = ws.sessions.firstIndex(where: { $0.id == sessionID }) else { return ws }
        var copy = ws
        copy.sessions[sIdx].name = name
        return copy
    }

    // MARK: Spec mutation (side table, not the tree)

    /// Mutates the ``PaneSpec`` of leaf `target` in place via `transform` (a rename / title / video edit)
    /// — the SPLIT TREE is never touched, so a rename can't churn a tree diff. No-op if absent.
    public static func updatingSpec(
        _ target: PaneID,
        in ws: TreeWorkspace,
        _ transform: (inout PaneSpec) -> Void,
    ) -> TreeWorkspace {
        guard let (sIdx, _) = locate(target, in: ws), var spec = ws.sessions[sIdx].specs[target] else { return ws }
        transform(&spec)
        var copy = ws
        copy.sessions[sIdx].specs[target] = spec
        return copy
    }

    // MARK: Break pane to a new tab

    /// Ejects pane `target` from its current tab into a NEW tab of the same session (Zellij/Herdr "break
    /// pane"). The source tab collapses/rebalances as if the pane closed; the new tab holds the pane as
    /// its lone leaf. Its spec stays in the same session's side table, so the invariant holds. No-op if
    /// absent or the pane is its tab's only leaf (nothing to break out).
    public static func breakPaneToTab(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        let session = ws.sessions[sIdx]
        let sourceTab = session.tabs[tIdx]
        guard sourceTab.root.leafCount > 1 else { return ws }
        guard let prunedRoot = sourceTab.root.removing(target) else { return ws }

        var copy = ws
        // Shrink the source tab.
        var src = copy.sessions[sIdx].tabs[tIdx]
        if src.zoomedPane == target { src.zoomedPane = nil }
        if src.activePane == target { src.activePane = prunedRoot.firstLeafID }
        src.root = prunedRoot
        copy.sessions[sIdx].tabs[tIdx] = src
        // Append the new tab and select it.
        let newTab = Tab(root: .leaf(target), activePane: target)
        copy.sessions[sIdx].tabs.append(newTab)
        copy.sessions[sIdx].activeTabIndex = copy.sessions[sIdx].tabs.count - 1
        return copy
    }

    // MARK: Locate helpers

    /// The (sessionIndex, tabIndex) owning leaf `id`, or `nil`.
    public static func locate(_ id: PaneID, in ws: TreeWorkspace) -> (Int, Int)? {
        for (sIdx, session) in ws.sessions.enumerated() {
            if let tIdx = session.tabIndex(containing: id) { return (sIdx, tIdx) }
        }
        return nil
    }

    /// The (sessionIndex, tabIndex) of tab `tabID`, or `nil`.
    private static func locateTab(_ tabID: TabID, in ws: TreeWorkspace) -> (Int, Int)? {
        for (sIdx, session) in ws.sessions.enumerated() {
            if let tIdx = session.tabs.firstIndex(where: { $0.id == tabID }) { return (sIdx, tIdx) }
        }
        return nil
    }

    /// The geometric neighbour of `pane` within `tab` (solved into a unit-square bound — direction is
    /// scale-invariant). Used to pick a sane focus before a close. `nil` if there is no neighbour.
    private static func neighbour(of pane: PaneID, in tab: Tab) -> PaneID? {
        let frames = SplitLayoutSolver.solve(
            tab.root,
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            minLeaf: .zero,
        )
        // Try each cardinal direction; the first that lands on a surviving (non-target) pane wins.
        let solved = SolvedLayout(frames: frames)
        for dir in [FocusDirection.left, .right, .up, .down] {
            if let n = FocusResolver.neighbor(of: pane, dir, in: solved), n != pane {
                return n
            }
        }
        // Fall back to the pre-order successor/predecessor among surviving leaves.
        let leaves = tab.root.allPaneIDs().filter { $0 != pane }
        return leaves.first
    }
}
