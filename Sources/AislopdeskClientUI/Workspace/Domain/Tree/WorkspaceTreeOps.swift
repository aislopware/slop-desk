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

        // FLOATING pane fast-path: a floating pane lives in `tab.floatingPanes`, NOT the tree, so
        // `tab.root.removing(target)` would return the root unchanged and leave a DANGLING floating id with
        // no spec (which `normalizingSpecs()` would then re-seed into a ghost). Remove it from the floating
        // layer + drop its spec and DON'T fall into the empty-tab cascade — the tiled tree is untouched, so
        // the tab is never emptied by closing a float.
        if tab.floatingPanes.contains(target) {
            tab.floatingPanes.removeAll { $0 == target }
            session.specs.removeValue(forKey: target)
            if tab.activePane == target { tab.activePane = refocus ?? tab.root.firstLeafID ?? tab.floatingPanes.first }
            session.tabs[tIdx] = tab
            copy.sessions[sIdx] = session
            return copy.normalizingSpecs()
        }

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

    // MARK: Layouts (select-layout parity — tmux/zellij re-tile)

    /// The algorithmic re-tile layouts (tmux/zellij `select-layout`). The `allCases` order is the
    /// ``cycleLayout(activeTabContaining:from:in:)`` step order.
    ///
    /// - ``evenHorizontal``: every leaf side-by-side in one row (a single `.horizontal` split).
    /// - ``evenVertical``: every leaf stacked in one column (a single `.vertical` split).
    /// - ``mainVertical``: the active leaf large on the LEFT, the rest evenly stacked on the right.
    /// - ``mainHorizontal``: the active leaf large on TOP, the rest evenly in a row below.
    /// - ``tiled``: a balanced grid (≈ even rows × cols) — the tmux "tiled" arrangement.
    public enum LayoutPreset: String, CaseIterable, Sendable, Hashable {
        case evenHorizontal
        case evenVertical
        case mainVertical
        case mainHorizontal
        case tiled
    }

    /// Re-tiles the tiled tree of the tab that owns `pane` into `preset`, **preserving every leaf
    /// `PaneID`** (a pure geometry change — no surface is created or destroyed, so the store's reconcile
    /// materializes/tears down nothing). The rebuilt tree resets all split weights to an EQUAL `.flex(1)`
    /// share (any prior divider drags are intentionally discarded — `select-layout` semantics).
    ///
    /// The leaf ORDER is the tab's pre-order DFS (``SplitNode/allPaneIDs()``); for the `main-*` presets the
    /// ACTIVE leaf (``Tab/activePane`` when it is a tiled leaf, else the first leaf) is moved to the front so
    /// it becomes the large pane. FLOATING panes (`tab.floatingPanes`) are untouched — only `tab.root` is
    /// rebuilt. A ZOOM is cleared first (re-tiling under a full-screen single-pane zoom is meaningless;
    /// tmux's `select-layout` exits zoom). A tab with 0 or 1 tiled leaf is a NO-OP (returns `ws` unchanged —
    /// a 1-child split would violate the ≥2-children invariant). No-op if `pane` is absent.
    public static func applyLayout(
        _ preset: LayoutPreset,
        activeTabContaining pane: PaneID,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(pane, in: ws) else { return ws }
        let tab = ws.sessions[sIdx].tabs[tIdx]

        // Collect the TILED leaves in pre-order DFS (floats are not in `tab.root`).
        let dfs = tab.root.allPaneIDs()
        guard dfs.count > 1 else { return ws } // 0/1 leaf → nothing to re-tile.

        // The active leaf goes to the front for the main-* presets (only when it is actually a tiled leaf —
        // a nil / floating activePane falls back to the first tiled leaf, the DFS head).
        let active = tab.activePane.flatMap { dfs.contains($0) ? $0 : nil }
        let leaves: [PaneID] =
            switch preset {
            case .mainVertical,
                 .mainHorizontal:
                if let active {
                    [active] + dfs.filter { $0 != active }
                } else {
                    dfs
                }
            case .evenHorizontal,
                 .evenVertical,
                 .tiled:
                dfs // even/tiled keep DFS order
            }

        var copy = ws
        var newTab = tab
        newTab.root = rebuild(preset, leaves: leaves)
        newTab.zoomedPane = nil // un-zoom then tile (tmux select-layout exits zoom)
        copy.sessions[sIdx].tabs[tIdx] = newTab
        // The leaf set is identical, so this is a no-op for materialization, but keep it for parity-safety.
        return copy.normalizingSpecs()
    }

    /// Advances one step through ``LayoutPreset/allCases`` from `current` (wrapping; `nil` → the first
    /// preset) and re-tiles the tab owning `pane` into it, returning the new workspace + the applied preset
    /// (the store stores it as the next cycle cursor). A 0/1-leaf tab still advances the returned preset (so
    /// the cursor moves) but ``applyLayout(_:activeTabContaining:in:)`` leaves the tree a no-op. No-op
    /// (returns `ws` + `current ?? .evenHorizontal`) if `pane` is absent.
    public static func cycleLayout(
        activeTabContaining pane: PaneID,
        from current: LayoutPreset?,
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, LayoutPreset) {
        let all = LayoutPreset.allCases
        let idx = current.flatMap { all.firstIndex(of: $0) } ?? -1
        let next = all[(idx + 1) % all.count]
        return (applyLayout(next, activeTabContaining: pane, in: ws), next)
    }

    /// Builds the flat (depth ≤ 2) ``SplitNode`` tree for `preset` over `leaves` (caller guarantees
    /// `leaves.count >= 2`). Every minted ``WeightedChild`` carries `.flex(1)` (re-normalized to an equal
    /// share at solve time) and every `.split` gets a fresh out-of-tree ``SplitNodeID`` (reconcile keys on
    /// ``PaneID``s, never split ids). Single-child intermediaries collapse to the bare leaf to honour the
    /// `.split` ≥ 2-children invariant. Pure; the index math is integer arithmetic.
    private static func rebuild(_ preset: LayoutPreset, leaves: [PaneID]) -> SplitNode {
        switch preset {
        case .evenHorizontal:
            return flatSplit(.horizontal, leaves: leaves)
        case .evenVertical:
            return flatSplit(.vertical, leaves: leaves)
        case .mainVertical:
            // Active leaf large on the LEFT, the rest stacked on the right.
            let rest = Array(leaves.dropFirst())
            let right = flatSplit(.vertical, leaves: rest) // collapses to a bare leaf when rest.count == 1
            return .split(
                id: SplitNodeID(), axis: .horizontal,
                children: [evenChild(.leaf(leaves[0])), evenChild(right)],
            )
        case .mainHorizontal:
            // Active leaf large on TOP, the rest in a row below.
            let rest = Array(leaves.dropFirst())
            let bottom = flatSplit(.horizontal, leaves: rest)
            return .split(
                id: SplitNodeID(), axis: .vertical,
                children: [evenChild(.leaf(leaves[0])), evenChild(bottom)],
            )
        case .tiled:
            return tiled(leaves: leaves)
        }
    }

    /// A `.split` along `axis` of `leaves` with equal `.flex(1)` weights — but a 1-element `leaves`
    /// collapses to the bare leaf (never a 1-child split, which violates the ≥2-children invariant).
    private static func flatSplit(_ axis: SplitAxis, leaves: [PaneID]) -> SplitNode {
        if leaves.count == 1 { return .leaf(leaves[0]) }
        return .split(id: SplitNodeID(), axis: axis, children: leaves.map { evenChild(.leaf($0)) })
    }

    /// A balanced grid (tmux "tiled"): `cols = ceil(sqrt(n))`, `rows = ceil(n / cols)`; an outer
    /// `.vertical` split of `rows` row-nodes, each row a `.horizontal` split of its leaf slice. A grid /
    /// row of one element collapses to the bare leaf.
    ///
    /// The leaves are spread across the rows as `rows` NEAR-EQUAL slices (the first `n % rows` rows get one
    /// extra leaf) — the symmetric tmux `select-layout tiled` fill — rather than greedily packing every row
    /// to `cols` and dumping the remainder in the last row (which makes a lopsided last row, e.g. n=7 →
    /// `[3,3,1]` instead of the balanced `[3,2,2]`). Both keep the same leaf SET; this is purely the
    /// cosmetic row distribution. `cols`/`rows` set how many rows exist; the per-row width is then balanced.
    private static func tiled(leaves: [PaneID]) -> SplitNode {
        let n = leaves.count
        // Integer ceil(sqrt) and ceil division — pure index arithmetic (no float / fma concerns). The
        // ceil-sqrt is computed by incrementing `cols` while `cols*cols < n` so there is no floating
        // perfect-square rounding edge for large n.
        var cols = 1
        while cols * cols < n { cols += 1 }
        let safeCols = max(cols, 1)
        let rows = (n + safeCols - 1) / safeCols // ceil(n / cols)
        let safeRows = max(rows, 1)
        // Balance the n leaves across `safeRows` rows: `base` per row, the first `extra` rows get one more.
        let base = n / safeRows
        let extra = n % safeRows
        var rowNodes: [SplitNode] = []
        var start = 0
        for r in 0..<safeRows {
            let width = base + (r < extra ? 1 : 0)
            let end = min(start + width, n)
            let slice = Array(leaves[start..<end])
            rowNodes.append(flatSplit(.horizontal, leaves: slice)) // a 1-leaf row collapses to the bare leaf
            start = end
        }
        if rowNodes.count == 1 { return rowNodes[0] } // a single row IS the grid
        return .split(id: SplitNodeID(), axis: .vertical, children: rowNodes.map { evenChild($0) })
    }

    /// A ``WeightedChild`` carrying `node` with the equal-share `.flex(1)` weight (the rebuilt-tree idiom).
    private static func evenChild(_ node: SplitNode) -> WeightedChild {
        WeightedChild(weight: .flex(1), node: node)
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

    // MARK: Floating panes (zellij-style overlay scratch panes)

    /// The smallest a floating pane may ever be (points) — the clamp floor for every floating-frame write,
    /// so a stray gesture / hostile persisted file can't produce a 0-size or sub-grabbable card.
    public static let floatingMinSize = CGSize(width: 320, height: 200)

    /// Toggles pane `target` between the tiled tree and the floating overlay layer (zellij "toggle float").
    ///
    /// - If `target` is currently FLOATING: **embed** it — drop it from `tab.floatingPanes`, clear its
    ///   `floatingFrame`, and re-insert it into the tiled tree (split off the current `activePane`/first
    ///   tiled leaf, or seed it as the lone leaf if the tree somehow has none), then focus it.
    /// - If `target` is a TILED leaf: **float** it — prune it from `tab.root` (GUARDED: a tab whose only
    ///   leaf is `target` cannot float — that would empty the tiled tree — so it's a no-op), append it to
    ///   `tab.floatingPanes`, stamp its spec's `floatingFrame` with the clamped `defaultFrame`, and focus
    ///   it.
    ///
    /// The spec never leaves `session.specs`, so the **specs == leafIDs invariant** holds throughout
    /// (`Tab.allPaneIDs()` counts the floating layer). No-op if `target` is absent.
    ///
    /// On EMBED, `embedAnchor` (if it is a live tiled leaf) is the pane the re-inserted float splits off —
    /// the store passes the pane the user was last working in so the embedded card lands next to it rather
    /// than always next to the first leaf. A `nil` / stale anchor falls back to the current tiled active
    /// pane, then the first tiled leaf (the prior behaviour).
    public static func toggleFloating(
        _ target: PaneID,
        defaultFrame: CGRect,
        bounds: CGRect,
        embedAnchor: PaneID? = nil,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        var copy = ws
        var session = copy.sessions[sIdx]
        var tab = session.tabs[tIdx]

        if tab.floatingPanes.contains(target) {
            // EMBED: floating → tiled.
            tab.floatingPanes.removeAll { $0 == target }
            if var spec = session.specs[target] {
                spec.floatingFrame = nil
                session.specs[target] = spec
            }
            // Re-insert into the tree: split off `embedAnchor` (the pane the user was last on, if it is a
            // live tiled leaf), else the current tiled active pane, else the first tiled leaf. If the tree
            // has NO leaves (degenerate — shouldn't happen for a live tab) seed it as the root leaf.
            let anchor = (embedAnchor.flatMap { tab.root.contains($0) ? $0 : nil })
                ?? (tab.activePane.flatMap { tab.root.contains($0) ? $0 : nil })
                ?? tab.root.firstLeafID
            if let host = anchor, let newRoot = tab.root.splitting(host, axis: .horizontal, inserting: target) {
                tab.root = newRoot
            } else if tab.root.firstLeafID == nil {
                tab.root = .leaf(target)
            }
            tab.activePane = target
        } else {
            // FLOAT: tiled → floating. Guard the lone-leaf case (floating it would empty the tiled tree).
            guard tab.root.leafCount > 1, let pruned = tab.root.removing(target) else {
                return ws
            }
            tab.root = pruned
            if tab.zoomedPane == target { tab.zoomedPane = nil }
            tab.floatingPanes.append(target)
            if var spec = session.specs[target] {
                spec.floatingFrame = clampFloatingFrame(defaultFrame, in: bounds)
                session.specs[target] = spec
            }
            tab.activePane = target
        }

        session.tabs[tIdx] = tab
        copy.sessions[sIdx] = session
        return copy
    }

    /// Spawns a BRAND-NEW pane directly into the floating overlay of the active session's active tab
    /// (zellij "new floating pane"). Mints a fresh ``PaneID``, appends it to `tab.floatingPanes`, stores
    /// `newSpec` (with `floatingFrame` = the clamped `defaultFrame`) in the side table, and focuses it.
    /// Returns the new workspace + minted id. No-op (throw-away id) if there is no active session/tab.
    public static func spawnFloating(
        _ newSpec: PaneSpec,
        defaultFrame: CGRect,
        bounds: CGRect,
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, PaneID) {
        let newID = PaneID()
        guard let sIdx = ws.activeSessionIndex else { return (ws, newID) }
        var copy = ws
        let tIdx = copy.sessions[sIdx].activeTabIndex
        guard copy.sessions[sIdx].tabs.indices.contains(tIdx) else { return (ws, newID) }
        var spec = newSpec
        spec.floatingFrame = clampFloatingFrame(defaultFrame, in: bounds)
        var tab = copy.sessions[sIdx].tabs[tIdx]
        tab.floatingPanes.append(newID)
        tab.activePane = newID
        copy.sessions[sIdx].tabs[tIdx] = tab
        copy.sessions[sIdx].specs[newID] = spec
        return (copy, newID)
    }

    /// Raises floating pane `target` to the FRONT of its tab's `floatingPanes` (z-order: last = topmost),
    /// so a focused / just-grabbed float draws above any overlapping neighbour (zellij/any WM raises the
    /// active float). Pure: only re-orders the floating array — the tree, specs, and frames are untouched,
    /// so the **specs == leafIDs invariant** holds. No-op if `target` is absent, is not floating, or is
    /// already topmost (so `focusPaneTree` → `raiseFloating` doesn't churn a reconcile when nothing moves).
    public static func raiseFloating(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        var tab = ws.sessions[sIdx].tabs[tIdx]
        guard tab.floatingPanes.contains(target), tab.floatingPanes.last != target else { return ws }
        tab.floatingPanes.removeAll { $0 == target }
        tab.floatingPanes.append(target)
        var copy = ws
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    /// Moves floating pane `target` so its origin becomes `origin` (keeping its current size), clamped into
    /// `bounds` with the min-size floor. No-op if `target` is absent or has no `floatingFrame` (i.e. is not
    /// floating). The split tree is untouched — only the spec's geometry moves.
    public static func moveFloating(
        _ target: PaneID,
        to origin: CGPoint,
        bounds: CGRect,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        updatingSpec(target, in: ws) { spec in
            guard let current = spec.floatingFrame else { return }
            spec.floatingFrame = clampFloatingFrame(CGRect(origin: origin, size: current.size), in: bounds)
        }
    }

    /// Resizes floating pane `target` to `frame`, clamped into `bounds` with the min-size floor. No-op if
    /// `target` is absent or not floating. The split tree is untouched.
    public static func resizeFloating(
        _ target: PaneID,
        to frame: CGRect,
        bounds: CGRect,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        updatingSpec(target, in: ws) { spec in
            guard spec.floatingFrame != nil else { return }
            spec.floatingFrame = clampFloatingFrame(frame, in: bounds)
        }
    }

    /// Clamps `frame` to sit fully inside `bounds` with at least ``floatingMinSize``. Pure; the house float
    /// idiom — separate `*`/`+`/`/`, NaN-faithful ordered `Double.maximum`/`Double.minimum`. A non-finite or
    /// empty `bounds` (e.g. before first layout) returns `frame` unchanged so the caller never writes a NaN.
    public static func clampFloatingFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            return frame
        }
        // Size: at least the min, at most the container (so it always fits).
        let minW = Double.minimum(Double(floatingMinSize.width), Double(bounds.width))
        let minH = Double.minimum(Double(floatingMinSize.height), Double(bounds.height))
        let w = Double.minimum(Double.maximum(Double(frame.width), minW), Double(bounds.width))
        let h = Double.minimum(Double.maximum(Double(frame.height), minH), Double(bounds.height))
        // Origin: keep the (clamped) rect inside [bounds.min, bounds.max - size].
        let maxX = Double(bounds.minX) + (Double(bounds.width) - w)
        let maxY = Double(bounds.minY) + (Double(bounds.height) - h)
        let x = Double.minimum(Double.maximum(Double(frame.minX), Double(bounds.minX)), maxX)
        let y = Double.minimum(Double.maximum(Double(frame.minY), Double(bounds.minY)), maxY)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A sensible default centered floating frame for a new/just-floated pane: ~`fraction` of `bounds`
    /// (clamped to the min size), centered in `bounds`. Used when no frame is remembered.
    public static func defaultFloatingFrame(in bounds: CGRect, fraction: CGFloat = 0.6) -> CGRect {
        let safeFraction = Double.minimum(Double.maximum(Double(fraction), 0.2), 1.0)
        let w = Double.maximum(Double(bounds.width) * safeFraction, Double(floatingMinSize.width))
        let h = Double.maximum(Double(bounds.height) * safeFraction, Double(floatingMinSize.height))
        let x = Double(bounds.minX) + (Double(bounds.width) - w) / 2
        let y = Double(bounds.minY) + (Double(bounds.height) - h) / 2
        return clampFloatingFrame(CGRect(x: x, y: y, width: w, height: h), in: bounds)
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
