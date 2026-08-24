import CoreGraphics
import CSlopDeskFFI

// MARK: - WorkspaceTreeOps (what a viewport decides, over Session / Tab / split tree)

/// Pure operation facade over the tree-rooted ``TreeWorkspace`` (docs/42 §"Pure ops"). Every method
/// returns a NEW ``TreeWorkspace`` — no in-place mutation, no I/O, no GUI. Each op preserves the
/// **specs == leafIDs invariant** and the active-selection invariants (active session / tab / pane
/// never dangle), so the store wraps these directly before `reconcile()`.
///
/// What is LEFT here after the applier moved to Rust (2026-08-17) is one kind of op: the ones a
/// VIEWPORT answers. A divider nudge, a directional focus step, a directional move and a re-tile all
/// need the geometry the person is looking at — solved frames, a live `CGRect` — which the document
/// does not have and must not grow. Everything that changes the SHAPE of the document is an intent
/// now: `slopdesk_wire::document::apply` behind `WorkspaceIntentApplier` decides splits, closes,
/// spawns, detaches, zooms and every session/tab verb, so the host and the client's optimistic
/// overlay cannot drift. The tiler these presets rebuild through is Rust too — see ``rebuild``.
///
/// Float math follows the house idiom: separate `*`/`+`/`/` (never `addingProduct`/`fma`) and
/// NaN-faithful ordered `Double.maximum`/`Double.minimum`.
public enum WorkspaceTreeOps {
    // MARK: Dividers

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

        /// The CASE index — the crate's enum order, pinned by `rust/slopdesk-invariants`.
        var ffiByte: UInt8 {
            switch self {
            case .evenHorizontal: 0
            case .evenVertical: 1
            case .mainVertical: 2
            case .mainHorizontal: 3
            case .tiled: 4
            }
        }
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

    /// The flat (depth ≤ 2) ``SplitNode`` tree for `preset` over `leaves` (caller guarantees
    /// `leaves.count >= 2`), built by `rust/slopdesk-workspace`'s `tree_ops::rebuild` (docs/55).
    ///
    /// Only the tiler crossed, not ``applyLayout(_:activeTabContaining:in:)`` around it: that reads a
    /// whole ``TreeWorkspace`` — sessions, tabs, titles, specs — and the document stays here, where
    /// SwiftUI diffs it. What crosses is the leaf ORDER in and the tree out, which is the only part of
    /// a re-tile that is a decision. The main-\* presets' "which leaf is large" choice is made by the
    /// caller ordering `leaves`, so the notion of ACTIVE never has to cross at all.
    ///
    /// The crate mints nothing, so the split identities are minted here and passed as a pool. A tiled
    /// layout of `n` leaves creates at most `n` splits, so `n + 1` entries cannot run dry.
    private static func rebuild(_ preset: LayoutPreset, leaves: [PaneID]) -> SplitNode {
        var ids = leaves.map(\.ffi)
        var pool = (0...leaves.count).map { _ in SlopDeskWsUuid(SplitNodeID().raw) }
        let tree = ids.withUnsafeMutableBufferPointer { panes -> SplitNode? in
            pool.withUnsafeMutableBufferPointer { splits in
                WsTree.decode(WsTree.answer { out, cap in
                    slopdesk_ws_retile(
                        panes.baseAddress,
                        panes.count,
                        preset.ffiByte,
                        splits.baseAddress,
                        splits.count,
                        out,
                        cap,
                    )
                })
            }
        }
        // Unreachable for the guarded `leaves.count >= 2`, and a bare first leaf is the only answer
        // that keeps every pane addressable if it ever were reached.
        return tree ?? .leaf(leaves[0])
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

    /// The pane a sequential ⌘]/⌘[ pane-cycle step would focus, or `nil` for a
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

    // MARK: Locate

    /// The (sessionIndex, tabIndex) owning leaf `id`, or `nil`.
    public static func locate(_ id: PaneID, in ws: TreeWorkspace) -> (Int, Int)? {
        for (sIdx, session) in ws.sessions.enumerated() {
            if let tIdx = session.tabIndex(containing: id) { return (sIdx, tIdx) }
        }
        return nil
    }
}
