import CoreGraphics
import Foundation

// MARK: - WorkspaceTreeOps (the facade over Session / Tab / split tree)

/// Pure operation facade over the tree-rooted ``TreeWorkspace`` (docs/42 §"Pure ops"). Every method
/// returns a NEW ``TreeWorkspace`` (some also the minted ``PaneID``) — no in-place mutation, no I/O, no
/// GUI. Each op preserves the **specs == leafIDs invariant** and the active-selection invariants (active
/// session / tab / pane never dangle), so the store cutover (W4) wraps these directly before `reconcile()`.
///
/// Float math follows the house idiom: separate `*`/`+`/`/` (never `addingProduct`/`fma`) and
/// NaN-faithful ordered `Double.maximum`/`Double.minimum`.
public enum WorkspaceTreeOps {
    // MARK: Split

    /// Splits pane `target` along `axis`, creating a new leaf carrying `newSpec`. Inserted as a sibling if
    /// the parent split already has `axis`, else `target` becomes a 2-child split (see
    /// ``SplitNode/splitting(_:axis:inserting:before:)``). `before == true` inserts on `target`'s LEADING
    /// side (the split-left/up chords); the default `false` is the trailing insert, so existing call sites
    /// stay byte-identical. The new pane is focused. Returns the new workspace + minted ``PaneID``. No-op
    /// (target absent) returns `ws` unchanged with a throw-away id not in the tree.
    public static func splitPane(
        _ target: PaneID,
        axis: SplitAxis,
        newSpec: PaneSpec,
        before: Bool = false,
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, PaneID) {
        let newID = PaneID()
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return (ws, newID) }
        var copy = ws
        var session = copy.sessions[sIdx]
        var tab = session.tabs[tIdx]
        guard let newRoot = tab.root.splitting(target, axis: axis, inserting: newID, before: before)
        else { return (ws, newID) }
        tab.root = newRoot
        tab.activePane = newID // the freshly split pane takes focus
        tab.zoomedPane = nil // splitting while zoomed exits zoom (the new focused pane must be visible)
        session.tabs[tIdx] = tab
        session.specs[newID] = newSpec // keep the specs == leafIDs invariant
        copy.sessions[sIdx] = session
        return (copy, newID)
    }

    // MARK: Close a pane (cascade + rebalance + refocus)

    /// Closes pane `target`: removes it from its tab's tree (collapsing the single-child parent and
    /// re-balancing siblings), drops its spec, and cascades —
    /// - the tab's **last** pane closing closes the tab (selecting an adjacent tab);
    /// - the session's **last** tab closing closes the session (selecting another session);
    /// - the workspace's **last** pane closing re-seeds a fresh default pane (never empty).
    /// A dangling zoom on the closed pane is cleared; focus moves to a geometric neighbour via
    /// ``FocusResolver`` (else the surviving first leaf). No-op if `target` is absent. Preserves the invariant.
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

    /// Evens ONLY the clicked seam: the divider between children `leadingChildIndex` and
    /// `leadingChildIndex + 1` of split `splitID` resets to an equal pair share (sum-preserving), leaving
    /// every OTHER divider's dragged ratio intact — the divider double-click, unlike
    /// ``balanceSplits(activeTabContaining:in:)`` which evens the whole tab. Searches the active session's
    /// active tab (dividers only render there). No-op if the split / indices are absent.
    public static func evenDivider(
        splitID: SplitNodeID,
        leadingChildIndex: Int,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var copy = ws
        let tIdx = copy.sessions[sIdx].activeTabIndex
        guard copy.sessions[sIdx].tabs.indices.contains(tIdx) else { return ws }
        var tab = copy.sessions[sIdx].tabs[tIdx]
        tab.root = tab.root.eveningDivider(splitID: splitID, leadingIndex: leadingChildIndex)
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    /// Sets split `splitID`'s leading-child weight (at `leadingChildIndex`) to an ABSOLUTE value in the active
    /// session's active tab — the cursor-matched form for a live divider drag (sum-preserving + clamped, see
    /// ``SplitNode/settingDividerWeight(splitID:leadingIndex:leadingWeight:)``). No-op if absent.
    public static func setDividerWeight(
        splitID: SplitNodeID,
        leadingChildIndex: Int,
        leadingWeight: Double,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var copy = ws
        let tIdx = copy.sessions[sIdx].activeTabIndex
        guard copy.sessions[sIdx].tabs.indices.contains(tIdx) else { return ws }
        var tab = copy.sessions[sIdx].tabs[tIdx]
        tab.root = tab.root.settingDividerWeight(
            splitID: splitID, leadingIndex: leadingChildIndex, leadingWeight: leadingWeight,
        )
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    // MARK: Move / swap

    /// Exchanges the positions of two leaves — only if both live in the SAME tab (cross-tab swap isn't
    /// attempted). No-op if either is absent or they're in different tabs. Preserves the invariant (specs +
    /// leaf set unchanged).
    public static func swapPanes(_ a: PaneID, _ b: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard a != b, let (sa, ta) = locate(a, in: ws), let (sb, tb) = locate(b, in: ws), sa == sb, ta == tb
        else { return ws }
        var copy = ws
        var tab = copy.sessions[sa].tabs[ta]
        tab.root = tab.root.swapping(a, b)
        copy.sessions[sa].tabs[ta] = tab
        return copy
    }

    /// Relocates leaf `source` beside leaf `target` along `axis`, on the BEFORE side when `before` (else
    /// after) — the drag-drop **re-split** commit: dropped on an EDGE of `target`, `source` becomes a new
    /// row/column beside it. `source` is pruned from its slot (collapsing/re-balancing as a close would) and
    /// re-inserted as `target`'s sibling **keeping its `PaneID`** — so reconcile is a registry no-op (no
    /// surface teardown, the remote stream survives) and only the geometry changes. `source` stays active.
    /// Dropping side-by-side panes onto each other's TOP/BOTTOM edge flips a `.horizontal` split to
    /// `.vertical` (and vice-versa) — the user's "dọc → ngang".
    ///
    /// No-op if `source == target`, either is absent, or they're in different tabs (cross-tab relocation
    /// isn't attempted — matches ``swapPanes(_:_:in:)``). Preserves the **specs == leafIDs invariant** (leaf
    /// set + specs unchanged — only a position moves).
    public static func moveLeaf(
        _ source: PaneID,
        beside target: PaneID,
        axis: SplitAxis,
        before: Bool,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard source != target,
              let (sa, ta) = locate(source, in: ws), let (sb, tb) = locate(target, in: ws),
              sa == sb, ta == tb
        else { return ws }
        var copy = ws
        var tab = copy.sessions[sa].tabs[ta]
        // Prune `source` first — it can NEVER empty the tab (target shares the tab, so ≥1 leaf survives);
        // guard defensively anyway. Then re-insert beside `target`. A cross-axis insert wraps the target's
        // slot one level deeper: reject if that would breach the decoder's ``SplitNode/maxDepth`` ceiling —
        // a tree the decoder later truncates loses a leaf, i.e. a remote surface.
        guard let pruned = tab.root.removing(source),
              let relocated = pruned.inserting(source, beside: target, axis: axis, before: before),
              relocated.depth <= SplitNode.maxDepth,
              // A drop reproducing the same arrangement still differs by `==` (rebuild mints a fresh split
              // id) — skip it so it doesn't churn a reconcile/save.
              !relocated.isStructurallyEqual(to: tab.root)
        else { return ws }
        tab.root = relocated
        tab.activePane = source // the moved pane keeps focus
        copy.sessions[sa].tabs[ta] = tab
        return copy
    }

    /// Docks leaf `source` to the OUTERMOST `edge` of its tab — the drag-to-CONTAINER-edge commit: dragged
    /// into the outer gutter, `source` becomes a full-span column (`.left`/`.right`) or row
    /// (`.top`/`.bottom`) spanning the whole tab. `source` is pruned (collapse + rebalance) then re-inserted
    /// at the ROOT on `edge.axis`, KEEPING its `PaneID` (reconcile is a registry no-op — no surface
    /// teardown). `source` stays active. Unlike ``moveLeaf(_:beside:axis:before:in:)``, a gutter drop has no
    /// target leaf, so this prepends/appends at the root (or wraps it). No-op if `source` is absent, its tab
    /// has only one leaf (nothing to dock against), or the dock would breach ``SplitNode/maxDepth``.
    /// Preserves the **specs == leafIDs invariant**.
    public static func moveLeafToRootEdge(
        _ source: PaneID,
        edge: PaneDropEdge,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(source, in: ws) else { return ws }
        var copy = ws
        var tab = copy.sessions[sIdx].tabs[tIdx]
        // A lone-leaf tab has nothing to dock against (and wrapping `[source, .leaf(source)]` would dup the
        // id); the >1 guard also makes `removing` non-nil.
        guard tab.root.leafCount > 1, let pruned = tab.root.removing(source) else { return ws }
        let relocated = pruned.insertingAtRoot(source, axis: edge.axis, before: edge.insertsBefore)
        // Reject too-deep or structurally-identical docks (the latter would churn a reconcile under a fresh
        // split id even though the pane already sits at that root edge).
        guard relocated.depth <= SplitNode.maxDepth, !relocated.isStructurallyEqual(to: tab.root) else { return ws }
        tab.root = relocated
        tab.activePane = source
        copy.sessions[sIdx].tabs[tIdx] = tab
        return copy
    }

    /// Inserts a NEW leaf carrying `spec` at the OUTERMOST `edge` of the ACTIVE tab — the rail-drag
    /// "drop a host window into the container gutter" commit (docs/45 round 3). The mint-a-pane sibling
    /// of ``moveLeafToRootEdge(_:edge:in:)``: same root prepend/append/wrap, but creating a leaf instead
    /// of relocating one — so it also works on a lone-leaf tab (a split against the only pane). The new
    /// pane is focused; a zoom is exited (the new focused pane must be visible — mirrors
    /// ``splitPane(_:axis:newSpec:before:in:)``). Returns the new workspace + minted ``PaneID``. No-op
    /// (returns `ws` with a throw-away id not in the tree) when there is no active tab or the insert
    /// would breach ``SplitNode/maxDepth``. Preserves the **specs == leafIDs invariant**.
    public static func insertPaneAtRootEdge(
        spec: PaneSpec,
        edge: PaneDropEdge,
        in ws: TreeWorkspace,
    ) -> (TreeWorkspace, PaneID) {
        let newID = PaneID()
        guard let sIdx = ws.activeSessionIndex else { return (ws, newID) }
        var copy = ws
        var session = copy.sessions[sIdx]
        guard session.tabs.indices.contains(session.activeTabIndex) else { return (ws, newID) }
        var tab = session.tabs[session.activeTabIndex]
        let grown = tab.root.insertingAtRoot(newID, axis: edge.axis, before: edge.insertsBefore)
        guard grown.depth <= SplitNode.maxDepth else { return (ws, newID) }
        tab.root = grown
        tab.activePane = newID
        tab.zoomedPane = nil
        session.tabs[session.activeTabIndex] = tab
        session.specs[newID] = spec // keep the specs == leafIDs invariant
        copy.sessions[sIdx] = session
        return (copy, newID)
    }

    /// Moves pane `pane` in `direction` by EXCHANGING it with its geometric neighbour on that side (Zellij
    /// "move pane"): resolves the neighbour against the active tab solved into `bounds` (the geometry the
    /// user sees + ``moveFocus(_:bounds:in:)`` reads), then ``swapPanes(_:_:in:)`` the two. `.next`/`.previous`
    /// and "no neighbour that side" are no-ops. `swapPanes` keeps ``PaneID`` identity, so `pane` stays
    /// active. Preserves the invariant (specs + leaf set unchanged — only positions move).
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

    /// Grows / shrinks pane `pane` along `direction` by nudging the nearest enclosing split's divider on the
    /// relevant axis (the keyboard counterpart to a drag-resize). `.left`/`.right` act on the nearest
    /// enclosing **horizontal** split (width); `.up`/`.down` on the nearest **vertical** split (height).
    /// `.right`/`.down` GROW the pane, `.left`/`.up` SHRINK it. `.next`/`.previous` and "no enclosing split"
    /// are no-ops. The underlying ``resizeDivider(splitID:leadingChildIndex:delta:in:)`` is sum-preserving +
    /// clamped at ``SplitWeight/minWeight``, so the active pane can never starve a sibling to nothing.
    /// Preserves the invariant (leaf set unchanged).
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
        // Map (grow/shrink, position) to which divider to nudge + signed delta so the ACTIVE pane
        // grows/shrinks. Non-last child: the divider to its right (leadingIndex == i) governs it — +delta
        // grows the leading (active) child. LAST child: no divider to its right, so the i-1 divider governs
        // it with the sign flipped (−delta grows the trailing active child).
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

    /// Re-tiles the tab owning `pane` into `preset`, **preserving every leaf `PaneID`** (a pure geometry
    /// change — reconcile materializes/tears down nothing). The rebuilt tree resets all split weights to an
    /// EQUAL `.flex(1)` share (prior divider drags are intentionally discarded — `select-layout` semantics).
    ///
    /// Leaf ORDER is the tab's pre-order DFS (``SplitNode/allPaneIDs()``); for the `main-*` presets the
    /// ACTIVE leaf (``Tab/activePane`` when a live leaf, else the first) moves to the front to become the
    /// large pane. A ZOOM is cleared first (re-tiling under a full-screen zoom is meaningless; tmux's
    /// `select-layout` exits zoom). A 0/1-leaf tab is a NO-OP (a 1-child split would violate the
    /// ≥2-children invariant). No-op if `pane` is absent.
    public static func applyLayout(
        _ preset: LayoutPreset,
        activeTabContaining pane: PaneID,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(pane, in: ws) else { return ws }
        let tab = ws.sessions[sIdx].tabs[tIdx]

        // Collect the leaves in pre-order DFS.
        let dfs = tab.root.allPaneIDs()
        guard dfs.count > 1 else { return ws } // 0/1 leaf → nothing to re-tile.

        // Active leaf goes to the front for the main-* presets (only when it is a live leaf — a nil /
        // dangling activePane falls back to the first leaf, the DFS head).
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
    /// Leaves spread across rows as `rows` NEAR-EQUAL slices (the first `n % rows` rows get one extra) — the
    /// symmetric tmux `select-layout tiled` fill — rather than greedily packing each row to `cols` and
    /// dumping the remainder in a lopsided last row (n=7 → `[3,3,1]` vs the balanced `[3,2,2]`). Same leaf
    /// SET either way; only the cosmetic row distribution differs.
    private static func tiled(leaves: [PaneID]) -> SplitNode {
        let n = leaves.count
        // Integer ceil(sqrt) and ceil division — pure index arithmetic (no float / fma concerns). ceil-sqrt
        // increments `cols` while `cols*cols < n`, so there's no floating perfect-square rounding edge for
        // large n.
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

    /// Focuses `target` (sets the owning tab's `activePane` and selects that session/tab). Focusing a pane
    /// OTHER than the tab's zoomed one exits zoom first — focus must never land on a pane the zoom collapse
    /// hides; re-focusing the zoomed pane itself keeps the zoom. No-op if absent.
    public static func focusPane(_ target: PaneID, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let (sIdx, tIdx) = locate(target, in: ws) else { return ws }
        var copy = ws
        copy.activeSessionID = copy.sessions[sIdx].id
        copy.sessions[sIdx].activeTabIndex = tIdx
        copy.sessions[sIdx].tabs[tIdx].activePane = target
        if copy.sessions[sIdx].tabs[tIdx].zoomedPane != target {
            copy.sessions[sIdx].tabs[tIdx].zoomedPane = nil
        }
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
            // Cycle through the SAME ordering as the ⌘]/⌘[ pane-cycle (``cyclePaneTarget(forward:in:)`` →
            // ``Tab/allPaneIDs()`` = pre-order DFS). One shared enumerator means the two cycle paths can't
            // drift.
            target = cyclePaneTarget(forward: direction == .next, in: ws)
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

    /// The pane a sequential ⌘]/⌘[ pane-cycle step (E1 ES-E1-2 / E3 ES-E3-5) would focus, or `nil` for a
    /// no-op — the **single source** of the DFS-wrap math the store delegates to
    /// (``WorkspaceStore/paneCycleTreeTarget(forward:)``). Walks the active session's active tab in
    /// ``Tab/allPaneIDs()`` order (pre-order DFS — the same order reconcile + the carousel read);
    /// `forward == true` steps to the NEXT id, `false` the previous, WRAPPING at both ends.
    ///
    /// A no-op (`nil`) when: no active session / tab; the active tab has fewer than two panes; or
    /// ``Tab/activePane`` is `nil` or NOT a live leaf (a dangling active has no place in the walk — cycling
    /// must not silently jump focus to the front). Pure (no focus side effect), so the wrap + guard is
    /// unit-testable in isolation.
    public static func cyclePaneTarget(forward: Bool, in ws: TreeWorkspace) -> PaneID? {
        guard let tab = ws.activeSession?.activeTab else { return nil }
        let ids = tab.allPaneIDs()
        guard ids.count > 1 else { return nil }
        // Step only from a LIVE active pane: a nil active, or a dangling id absent from the tree, has no
        // defined predecessor / successor here, so cycling is a no-op rather than a jump-to-front.
        guard let active = tab.activePane, tab.root.contains(active), let current = ids.firstIndex(of: active)
        else { return nil }
        let next = forward ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
        return ids[next]
    }

    /// Cycles focus to the pane ``cyclePaneTarget(forward:in:)`` resolves, routing through
    /// ``focusPane(_:in:)`` (the shared focus/select path) so the result holds the active-selection
    /// invariants. A no-op (returns `ws` unchanged) whenever the target is `nil` — see
    /// ``cyclePaneTarget(forward:in:)`` for the no-op cases. Pure.
    public static func cyclePaneFocus(forward: Bool, in ws: TreeWorkspace) -> TreeWorkspace {
        guard let target = cyclePaneTarget(forward: forward, in: ws) else { return ws }
        return focusPane(target, in: ws)
    }

    // MARK: Tabs

    /// Adds a new tab (single leaf carrying `spec`) to the active session at `position` and selects it.
    /// Returns the new workspace + the new pane's id. No-op (returns a throw-away id) if there is no active
    /// session.
    ///
    /// `position` defaults to ``NewTabPosition/end`` so existing call sites stay byte-identical to the pre-E3
    /// `tabs.append(...)` (end index = append, selected index = `tabs.count - 1`). Only the ⌘T path passes a
    /// configured ``NewTabPosition``.
    public static func newTab(
        in ws: TreeWorkspace,
        spec: PaneSpec,
        at position: NewTabPosition = .end,
    ) -> (TreeWorkspace, PaneID) {
        let paneID = PaneID()
        guard let sIdx = ws.activeSessionIndex else { return (ws, paneID) }
        var copy = ws
        let tab = Tab(root: .leaf(paneID), activePane: paneID)
        let index = position.insertionIndex(
            activeTabIndex: copy.sessions[sIdx].activeTabIndex,
            tabCount: copy.sessions[sIdx].tabs.count,
        )
        copy.sessions[sIdx].tabs.insert(tab, at: index)
        copy.sessions[sIdx].activeTabIndex = index
        copy.sessions[sIdx].specs[paneID] = spec
        return (copy, paneID)
    }

    /// Inserts a PRE-BUILT `tab` (its split tree + every pane's ``PaneSpec`` in `specs`) into the active
    /// session at `position` and selects it — the reopen-last-closed restore (E3 WI-3). Merges `specs` into
    /// the active session's side table so the **specs == leafIDs invariant** holds for the restored leaves;
    /// `normalizingSpecs()` repairs any leaf whose spec went missing (re-seeding a default), so the result
    /// always holds the invariant. Pure. No-op if there is no active session.
    public static func insertTab(
        _ tab: Tab,
        specs: [PaneID: PaneSpec],
        at position: NewTabPosition,
        in ws: TreeWorkspace,
    ) -> TreeWorkspace {
        guard let sIdx = ws.activeSessionIndex else { return ws }
        var copy = ws
        let index = position.insertionIndex(
            activeTabIndex: copy.sessions[sIdx].activeTabIndex,
            tabCount: copy.sessions[sIdx].tabs.count,
        )
        copy.sessions[sIdx].tabs.insert(tab, at: index)
        copy.sessions[sIdx].activeTabIndex = index
        // Merge the restored panes' specs into the active session (keep the specs == leafIDs invariant).
        for id in tab.allPaneIDs() {
            if let spec = specs[id] { copy.sessions[sIdx].specs[id] = spec }
        }
        return copy.normalizingSpecs()
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

    /// Inserts a pre-built `session` (e.g. a ``SessionTemplateEngine/makeSession(from:name:)`` expansion),
    /// appending it to `sessions`; when `makeActive` it also becomes selected. Other sessions are untouched,
    /// so the **specs == leafIDs invariant** holds for the whole workspace as long as the inserted session
    /// does. Mirrors the tail of ``newSession(in:name:spec:)`` for an already-constructed session. Pure.
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
