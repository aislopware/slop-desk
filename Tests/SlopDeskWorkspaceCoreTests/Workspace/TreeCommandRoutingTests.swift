import CoreGraphics
import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore
#if canImport(SwiftUI)
import SwiftUI
#endif

/// W6 (docs/42 §"W6 — Keybindings + command palette + cheat sheet"): pins the **tree-command-routing**
/// contract — the single ``WorkspaceBindingRegistry`` source of truth that the menu bar, the ⌘K command
/// palette, the ⌘/ cheat sheet, AND this test all read. Each registered ``WorkspaceAction`` must, when
/// routed through ``WorkspaceBindingRegistry/route(_:to:)`` on a `.tree`-live store, land on the intended
/// store TREE op — asserted through the resulting ``TreeWorkspace`` / registry change, never a recompute
/// of the registry itself (no tautology).
///
/// The suite injects the spec-only `makeSession` seam with a ``FakePaneSession`` (never a real
/// `SlopDeskClient` / `HostServer`) and builds every store with ``WorkspaceStore/LiveModel/tree`` so the
/// tree is the live source the routing drives. No SwiftUI view is constructed — `route(_:to:)` is the pure
/// seam under test, identical to what a menu `Button` / palette row / chord dispatch invokes.
@MainActor
final class TreeCommandRoutingTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store seeded from `restoringTree` (default: one terminal pane), backed by the
    /// `FakePaneSession` seam — so init reconciles the TREE and the routing then drives it.
    private func makeTreeStore(restoringTree: TreeWorkspace = .defaultWorkspace()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    /// The tree's leaf ids in DFS order.
    private func leaves(_ store: WorkspaceStore) -> [PaneID] { store.tree.allPaneIDs() }

    /// The active tab's active pane.
    private func activePane(_ store: WorkspaceStore) -> PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }

    /// Routes `action` through the single-source-of-truth registry (the production seam).
    private func route(_ action: WorkspaceAction, _ store: WorkspaceStore) {
        // The production `route(...)` now mints an in-pane `.chooser` pane for the new-pane verbs (that
        // behaviour is pinned by `PaneChooserRoutingTests`); this suite drives the tree ops over REAL panes,
        // so translate those verbs to a direct terminal creation. Every OTHER action routes unchanged.
        switch action {
        case .splitRight: store.splitActivePane(axis: .horizontal, kind: .terminal)
        case .splitDown: store.splitActivePane(axis: .vertical, kind: .terminal)
        case .newTab: store.newTab(kind: .terminal)
        default: WorkspaceBindingRegistry.route(action, to: store)
        }
    }

    // MARK: - Interactive resize flag (drives the pane scrim's paused-drag hold)

    /// `setTerminalResizeSuspended(true/false)` (the divider-drag bracket, shared by the pane divider and
    /// the AppKit sidebar divider) drives the store's `isInteractiveResizeActive`, which the pane scrim
    /// reads to stay up across a PAUSED drag. Idempotent at both edges.
    func testInteractiveResizeFlagTracksTheDividerBracket() {
        let store = makeTreeStore()
        XCTAssertFalse(store.isInteractiveResizeActive, "idle: no drag in progress")
        store.setTerminalResizeSuspended(true) // divider mouse-down
        XCTAssertTrue(store.isInteractiveResizeActive)
        store.setTerminalResizeSuspended(true) // redundant begin — still active, no flap
        XCTAssertTrue(store.isInteractiveResizeActive)
        store.setTerminalResizeSuspended(false) // mouse-up / settle
        XCTAssertFalse(store.isInteractiveResizeActive)
    }

    // MARK: - Panes: split adds a leaf + materializes a fake

    /// `.splitRight` adds exactly one leaf (a horizontal sibling) to the active tab and materializes a new
    /// `FakePaneSession` for it — the new leaf becomes the active pane.
    func testSplitRightAddsLeafAndMaterializesFake() throws {
        let store = makeTreeStore()
        let original = leaves(store)[0]
        XCTAssertEqual(store.allSessions.count, 1, "default tree = one materialized leaf")

        route(.splitRight, store)

        XCTAssertEqual(leaves(store).count, 2, "splitRight added exactly one leaf")
        XCTAssertEqual(store.allSessions.count, 2, "reconcileTree materialized exactly one new handle")
        let added = try XCTUnwrap(leaves(store).first { $0 != original })
        XCTAssertEqual(activePane(store), added, "the new leaf is the active pane")
        XCTAssertNotNil(store.handle(for: added) as? FakePaneSession, "the new leaf has a fake handle")
    }

    /// `.splitDown` also adds one leaf — proving the axis routes through too (a vertical split). We assert
    /// the leaf count grows and the new leaf is focused; the axis difference vs. `.splitRight` is pinned by
    /// the `WorkspaceTreeOps` suite, so here it suffices that the action reaches the split op.
    func testSplitDownAddsLeaf() throws {
        let store = makeTreeStore()
        let original = leaves(store)[0]

        route(.splitDown, store)

        XCTAssertEqual(leaves(store).count, 2, "splitDown added exactly one leaf")
        let added = try XCTUnwrap(leaves(store).first { $0 != original })
        XCTAssertEqual(activePane(store), added, "the new leaf is the active pane")
    }

    /// `.closePane` removes the active pane and tears down exactly its fake (the survivor is untouched).
    func testClosePaneRemovesActivePane() async throws {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store)
        let b = try XCTUnwrap(activePane(store)) // the new pane is active
        XCTAssertNotEqual(a, b)
        let bFake = store.handle(for: b) as? FakePaneSession

        route(.closePane, store)

        XCTAssertNil(store.handle(for: b), "closed leaf removed from the registry synchronously")
        XCTAssertEqual(leaves(store), [a], "only the survivor remains")
        await store.quiesce()
        XCTAssertEqual(bFake?.teardownCount, 1, "the closed leaf was torn down exactly once")
    }

    // MARK: - Focus: geometric move works without a pre-seeded layout report

    /// `.focusLeft` / `.focusRight` move the active pane geometrically WITHOUT any `updateSolvedLayout`
    /// pre-seed — the store solves the tree itself (direction is scale-invariant), so the ⌃⌘arrow chords
    /// work from the first frame. The audit found the old guard waited on a report NO production view ever
    /// sent (the deleted `SplitTreeView` was its only caller), leaving every directional chord permanently
    /// dead; this test fails on that un-wired path (the routes below were silent no-ops).
    func testFocusRightThenLeftMovesActivePane() throws {
        let store = makeTreeStore()
        let left = leaves(store)[0]
        route(.splitRight, store) // a horizontal split: [left | right], right focused
        let right = try XCTUnwrap(activePane(store))

        route(.focusLeft, store)
        XCTAssertEqual(activePane(store), left, "focusLeft lands on the left pane")

        route(.focusRight, store)
        XCTAssertEqual(activePane(store), right, "focusRight lands back on the right pane")
    }

    // MARK: - View: zoom toggles the active tab's zoomedPane

    /// `.toggleZoom` sets then clears the active tab's `zoomedPane` (render-only zoom; the tree is untouched).
    func testToggleZoomTogglesZoomedPane() {
        let store = makeTreeStore()
        let only = leaves(store)[0]
        XCTAssertNil(store.tree.activeSession?.activeTab?.zoomedPane, "no zoom initially")

        route(.toggleZoom, store)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.zoomedPane, only, "toggleZoom zoomed the active pane")

        route(.toggleZoom, store)
        XCTAssertNil(store.tree.activeSession?.activeTab?.zoomedPane, "toggleZoom again cleared the zoom")
    }

    // MARK: - Tabs: new / next / prev / select-N

    /// `.newTab` adds a tab (single leaf) to the active session and selects it; the leaf is materialized.
    func testNewTabAddsTabAndSelectsIt() {
        let store = makeTreeStore()
        let session0 = try? XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session0?.tabs.count, 1, "default session = one tab")

        route(.newTab, store)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "newTab added a tab")
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "the new tab is selected")
        XCTAssertEqual(leaves(store).count, 2, "the new tab's leaf was materialized")
        XCTAssertEqual(store.allSessions.count, 2)
    }

    /// `.nextTab` / `.prevTab` cycle the active session's `activeTabIndex` without changing the leaf set.
    func testNextAndPrevTabCycleActiveIndex() {
        let store = makeTreeStore()
        route(.newTab, store) // now two tabs, index 1 active
        route(.newTab, store) // three tabs, index 2 active
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2)
        let leafCount = leaves(store).count

        route(.prevTab, store)
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "prevTab stepped back one tab")

        route(.nextTab, store)
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "nextTab stepped forward one tab")

        XCTAssertEqual(leaves(store).count, leafCount, "cycling tabs never changes the leaf set")
    }

    /// `.selectTab(N)` (1-based) selects the Nth tab of the active session.
    func testSelectTabNumberSelectsThatTab() {
        let store = makeTreeStore()
        route(.newTab, store)
        route(.newTab, store) // three tabs (indices 0,1,2), index 2 active

        route(.selectTab(1), store) // 1-based ⇒ index 0
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 0, "selectTab(1) selected the first tab")

        route(.selectTab(3), store) // 1-based ⇒ index 2
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 2, "selectTab(3) selected the third tab")
    }

    /// `.breakPaneToTab` ejects the active pane into a new tab of its session (the source tab collapses).
    func testBreakPaneToTabEjectsActivePane() throws {
        let store = makeTreeStore()
        route(.splitRight, store) // two leaves in one tab
        let moved = try XCTUnwrap(activePane(store))
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "both leaves share one tab")

        route(.breakPaneToTab, store)

        XCTAssertEqual(store.tree.activeSession?.tabs.count, 2, "break-pane created a second tab")
        // The moved pane is alone in some tab (the new one).
        let owningTab = try XCTUnwrap(store.tree.activeSession?.tabs.first { $0.contains(moved) })
        XCTAssertEqual(owningTab.allPaneIDs(), [moved], "the broken-out pane is alone in its new tab")
    }

    // MARK: - Panes: move / resize / balance (keyboard pane management)

    /// `.movePaneRight` swaps the active pane with its right neighbour (the leaf order flips); the moved pane
    /// keeps focus (PaneID identity preserved). Like the focus chords above, this must work WITHOUT any
    /// `updateSolvedLayout` pre-seed (the store solves the tree itself) — it fails on the un-wired path
    /// where the swap guarded on a layout report no production view ever sent.
    func testMovePaneRightSwapsActiveWithRightNeighbour() throws {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store) // [a | b], b active
        let b = try XCTUnwrap(activePane(store))
        store.focusPaneTree(a) // make a active so we move IT right

        route(.movePaneRight, store)

        XCTAssertEqual(store.tree.activeSession?.activeTab?.root.allPaneIDs(), [b, a], "a moved right past b")
        XCTAssertEqual(activePane(store), a, "the moved pane keeps focus")
    }

    /// `.resizePaneRight` grows the active pane wider (a sum-preserving divider nudge) — the leaf set is
    /// unchanged. Proven to fail before the action routes to `resizeActivePane`.
    func testResizePaneRightGrowsActivePaneWidth() {
        let store = makeTreeStore()
        let a = leaves(store)[0]
        route(.splitRight, store) // [a | b], b active
        store.focusPaneTree(a)
        guard case let .split(_, _, before)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        func flex(_ c: WeightedChild) -> Double { if case let .flex(w) = c.weight { return w }
            return 0
        }

        route(.resizePaneRight, store)

        guard case let .split(_, _, after)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        XCTAssertGreaterThan(flex(after[0]), flex(before[0]), "the active (leading) pane grew")
        XCTAssertEqual(leaves(store).count, 2, "resize never changes the leaf set")
    }

    /// `.balancePanes` resets the active tab's split weights to equal after an off-balance nudge — the leaf
    /// set is unchanged. Proven to fail before the action routes to `balanceActivePaneSplits`.
    func testBalancePanesEqualizesActiveTabSplit() {
        let store = makeTreeStore()
        route(.splitRight, store) // [a | b]
        guard case let .split(splitID, _, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        store.resizeDividerTree(splitID: splitID, leadingChildIndex: 0, delta: 0.4) // off-balance

        route(.balancePanes, store)

        guard case let .split(_, _, children)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected split")
            return
        }
        func flex(_ c: WeightedChild) -> Double { if case let .flex(w) = c.weight { return w }
            return 0
        }
        XCTAssertEqual(flex(children[0]), flex(children[1]), accuracy: 1e-9, "balance equalized the two columns")
        XCTAssertEqual(leaves(store).count, 2, "balance never changes the leaf set")
    }

    /// Double-clicking ONE divider evens ONLY that seam: `evenDividerTree` resets the clicked pair to an
    /// equal share (sum-preserving) while every OTHER split keeps its dragged ratio. The audit bug: the
    /// `PaneDivider` double-click was wired to `balanceActivePaneSplits()`, which rebalances EVERY split of
    /// the tab — wiping the other seams' carefully dragged ratios. Proven to fail before the targeted op
    /// exists (compile), and behaviourally: the whole-tab reset would flatten `after[0]` back to 1.
    func testEvenDividerTreeResetsOnlyTheClickedSeam() {
        let store = makeTreeStore()
        route(.splitRight, store) // [a | b]
        route(.splitDown, store) // b's slot → nested [b / c]; root = horizontal[a, vertical[b, c]]
        guard case let .split(rootID, _, rootChildren)? = store.tree.activeSession?.activeTab?.root,
              case let .split(nestedID, _, _) = rootChildren[1].node
        else {
            XCTFail("expected [a | [b / c]]")
            return
        }
        func flex(_ c: WeightedChild) -> Double { if case let .flex(w) = c.weight { return w }
            return 0
        }
        // Drag BOTH seams off-balance (each pair starts 1/1).
        store.resizeDividerTree(splitID: rootID, leadingChildIndex: 0, delta: 0.4) // a | … → 1.4 / 0.6
        store.resizeDividerTree(splitID: nestedID, leadingChildIndex: 0, delta: 0.4) // b / c → 1.4 / 0.6

        store.evenDividerTree(splitID: nestedID, leadingChildIndex: 0) // double-click the b/c seam only

        guard case let .split(_, _, after)? = store.tree.activeSession?.activeTab?.root,
              case let .split(_, _, nestedAfter) = after[1].node
        else {
            XCTFail("the tree shape is unchanged by an even-out")
            return
        }
        XCTAssertEqual(flex(nestedAfter[0]), flex(nestedAfter[1]), accuracy: 1e-9, "the clicked seam evened out")
        XCTAssertEqual(
            flex(nestedAfter[0]) + flex(nestedAfter[1]), 2.0, accuracy: 1e-9, "the pair sum is preserved",
        )
        XCTAssertEqual(flex(after[0]), 1.4, accuracy: 1e-9, "the OTHER split's dragged ratio survives")
        XCTAssertEqual(flex(after[1]), 0.6, accuracy: 1e-9, "the OTHER split's dragged ratio survives")
    }

    /// `store.swapPanesTree(a, b)` exchanges two leaves' positions (the drag-to-move-pane commit) while
    /// keeping the EXACT leaf set + every materialized handle — both ids survive, so reconcile is a registry
    /// no-op (no surface teardown). A self-swap is a guarded no-op. Fails if the store method doesn't swap.
    func testSwapPanesTreeExchangesPositionsKeepingHandles() {
        let store = makeTreeStore()
        route(.splitRight, store) // [a | b], DFS order [a, b]
        let ordered = leaves(store)
        XCTAssertEqual(ordered.count, 2)
        let a = ordered[0], b = ordered[1]
        XCTAssertNotNil(store.handle(for: a))
        XCTAssertNotNil(store.handle(for: b))

        store.swapPanesTree(a, b)

        XCTAssertEqual(leaves(store), [b, a], "swap exchanged the two leaves' DFS positions")
        XCTAssertEqual(Set(leaves(store)), Set(ordered), "swap never changes the leaf set")
        XCTAssertNotNil(store.handle(for: a), "a keeps its handle through the swap (no teardown)")
        XCTAssertNotNil(store.handle(for: b), "b keeps its handle through the swap (no teardown)")

        store.swapPanesTree(a, a) // self-swap is a no-op
        XCTAssertEqual(leaves(store), [b, a], "self-swap left the order unchanged")
    }

    /// `store.moveLeafTree(source, beside: target, axis:before:)` is the drag-to-EDGE-drop commit: it prunes
    /// `source` and re-inserts it beside `target` on the requested side, KEEPING both ids (reconcile is a
    /// registry no-op — no surface teardown). Here a side-by-side `[a | b]` becomes a STACKED split when `a`
    /// is dropped on `b`'s TOP edge (axis `.vertical`, `before: true`) — the user's "dọc → ngang". Proven to
    /// fail before the store method relocates.
    func testMoveLeafTreeReSplitsAlongTheOtherAxisKeepingHandles() {
        let store = makeTreeStore()
        route(.splitRight, store) // [a | b] horizontal (side-by-side), DFS [a, b]
        let ordered = leaves(store)
        XCTAssertEqual(ordered.count, 2)
        let a = ordered[0], b = ordered[1]
        guard case .split(_, .horizontal, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("precondition: a horizontal (side-by-side) split")
            return
        }
        XCTAssertNotNil(store.handle(for: a))
        XCTAssertNotNil(store.handle(for: b))

        store.moveLeafTree(a, beside: b, axis: .vertical, before: true)

        XCTAssertEqual(Set(leaves(store)), Set(ordered), "re-split never changes the leaf set")
        XCTAssertEqual(leaves(store), [a, b], "a re-inserted ABOVE b (before:true)")
        guard case .split(_, .vertical, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("the side-by-side split became a stacked (vertical) one")
            return
        }
        XCTAssertNotNil(store.handle(for: a), "a keeps its handle through the re-split (no teardown)")
        XCTAssertNotNil(store.handle(for: b), "b keeps its handle through the re-split (no teardown)")
        XCTAssertEqual(activePane(store), a, "the moved pane stays focused")
    }

    /// `store.moveLeafToRootEdgeTree(source, edge:)` docks a pane to the tab's OUTERMOST edge: dropped in the
    /// container's TOP gutter, a nested pane becomes a full-width top row spanning the WHOLE tab (not just
    /// beside one leaf), every id surviving (no teardown). Proven to fail before the store method docks.
    func testMoveLeafToRootEdgeDocksFullSpanKeepingHandles() throws {
        let store = makeTreeStore()
        route(.splitRight, store) // [a | b] horizontal
        let a = leaves(store)[0]
        let b = try XCTUnwrap(activePane(store)) // b is the new active pane
        route(.splitDown, store) // b's slot → nested [b / c]; root = horizontal[a, vertical[b, c]]
        let c = try XCTUnwrap(activePane(store)) // c is the new active pane
        XCTAssertEqual(Set(leaves(store)), Set([a, b, c]))
        for id in [a, b, c] { XCTAssertNotNil(store.handle(for: id)) }

        store.moveLeafToRootEdgeTree(c, edge: .top) // dock c to the full-width TOP of the whole tab

        XCTAssertEqual(Set(leaves(store)), Set([a, b, c]), "dock never changes the leaf set")
        XCTAssertEqual(leaves(store), [c, a, b], "c docked as the FIRST (top) row, a|b below")
        guard case let .split(_, .vertical, children)? = store.tree.activeSession?.activeTab?.root,
              children.count == 2
        else {
            XCTFail("the root wrapped into a vertical 2-child split [c, (a|b)]")
            return
        }
        XCTAssertEqual(children[0].node, .leaf(c), "c spans the whole top edge (full-width row)")
        for id in [a, b, c] { XCTAssertNotNil(store.handle(for: id), "leaf \(id) keeps its handle (no teardown)") }
        XCTAssertEqual(activePane(store), c, "the docked pane stays focused")
    }

    /// A drop that REPRODUCES the current arrangement (drop a pane on the edge it already occupies relative
    /// to its sibling) must be a true no-op — NOT churn a reconcile/save under a freshly-minted split id.
    /// `[a|b]`, dropping `a` on `b`'s LEFT edge re-creates `[a|b]` at equal weights, so the split id must be
    /// unchanged. Proven to fail before the structural-equality guard short-circuits the op.
    func testMoveLeafTreeReproducingArrangementIsANoOp() {
        let store = makeTreeStore()
        route(.splitRight, store) // [a|b], DFS [a, b]
        let a = leaves(store)[0]
        let b = leaves(store)[1]
        guard case let .split(idBefore, _, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected a split")
            return
        }

        // a before b along .horizontal == the current arrangement → structural no-op.
        store.moveLeafTree(a, beside: b, axis: .horizontal, before: true)

        XCTAssertEqual(leaves(store), [a, b], "order unchanged")
        guard case let .split(idAfter, _, _)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("expected a split")
            return
        }
        XCTAssertEqual(idBefore, idAfter, "a structural no-op must not rebuild the split (no reconcile churn)")
    }

    // MARK: - Layouts (select-layout parity): routing + chord pin

    /// `.applyLayout(.evenHorizontal)` re-tiles the active tab into a single horizontal split while keeping
    /// the exact leaf set + every fake handle mounted (the no-teardown invariant). Proven to fail before the
    /// action routes to `store.applyLayout(_)`.
    func testApplyLayoutRetilesPreservingPanesAndHandles() {
        let store = makeTreeStore()
        route(.splitDown, store) // [a / b] — a vertical (stacked) split
        route(.splitDown, store) // 3 leaves stacked
        let before = Set(leaves(store))
        XCTAssertEqual(before.count, 3)

        route(.applyLayout(.evenHorizontal), store)

        XCTAssertEqual(Set(leaves(store)), before, "re-tile keeps the EXACT leaf set (no teardown)")
        guard case let .split(_, axis, children)? = store.tree.activeSession?.activeTab?.root else {
            XCTFail("even-horizontal is a single split")
            return
        }
        XCTAssertEqual(axis, .horizontal, "even-horizontal = side-by-side columns")
        XCTAssertEqual(children.count, 3)
        // Every surviving leaf still has its materialized handle (nothing was torn down + recreated).
        for id in before { XCTAssertNotNil(store.handle(for: id), "leaf \(id) keeps its handle through a re-tile") }
        XCTAssertEqual(store.allSessions.count, 3, "no handle materialized or destroyed by the re-tile")
    }

    /// `.cycleLayout` advances the layout each press (the leaf set never changes) — and the first press
    /// applies the FIRST preset (even-horizontal). Proven to fail before `.cycleLayout` routes.
    func testCycleLayoutSteppingKeepsLeafSet() {
        let store = makeTreeStore()
        route(.splitRight, store)
        route(.splitRight, store) // 3 leaves
        let before = Set(leaves(store))

        route(.cycleLayout, store) // → even-horizontal (first preset)
        XCTAssertEqual(Set(leaves(store)), before, "cycle keeps the leaf set")
        if case let .split(_, axis, _)? = store.tree.activeSession?.activeTab?.root {
            XCTAssertEqual(axis, .horizontal, "first cycle press applies even-horizontal")
        } else {
            XCTFail("expected a re-tiled split")
        }

        route(.cycleLayout, store) // → even-vertical
        if case let .split(_, axis, _)? = store.tree.activeSession?.activeTab?.root {
            XCTAssertEqual(axis, .vertical, "second cycle press applies even-vertical")
        } else {
            XCTFail("expected a re-tiled split")
        }
        XCTAssertEqual(Set(leaves(store)), before, "still the same leaf set after the second press")
    }

    /// Pins the Cycle Layout chord to its documented free default ⌃⌘L, and that the five named presets are
    /// chord-LESS (menu/palette only) — a wrong-but-unique value would slip past the collision guard.
    func testCycleLayoutChordIsControlCommandLAndPresetsHaveNoChord() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.cycleLayout), KeyChord(character: "l", [.control, .command]), "cycle layout = ⌃⌘L")
        for preset in WorkspaceTreeOps.LayoutPreset.allCases {
            XCTAssertNil(chord(.applyLayout(preset)), "named preset \(preset) is menu/palette only — no chord")
        }
    }

    /// Pins the nine new pane-management chords to their documented defaults (move = ⌥⌘⇧arrows,
    /// divider-move = ⌃⌘⇧arrows, balance = ⌃⌘=) — distinct from focus (⌃⌘arrows) and the ⌃⌘bracket block jumps.
    func testPaneManagementChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.movePaneLeft), KeyChord(.leftArrow, [.option, .command, .shift]), "move left = ⌥⌘⇧←")
        XCTAssertEqual(chord(.movePaneRight), KeyChord(.rightArrow, [.option, .command, .shift]), "move right = ⌥⌘⇧→")
        XCTAssertEqual(chord(.movePaneUp), KeyChord(.upArrow, [.option, .command, .shift]), "move up = ⌥⌘⇧↑")
        XCTAssertEqual(chord(.movePaneDown), KeyChord(.downArrow, [.option, .command, .shift]), "move down = ⌥⌘⇧↓")
        // Move divider = ⌃⌘⇧arrows (docs/ui-shell/spec/reference__keybindings.md:86-89).
        XCTAssertEqual(
            chord(.resizePaneLeft),
            KeyChord(.leftArrow, [.control, .command, .shift]),
            "divider left = ⌃⌘⇧←",
        )
        XCTAssertEqual(
            chord(.resizePaneRight), KeyChord(.rightArrow, [.control, .command, .shift]), "divider right = ⌃⌘⇧→",
        )
        XCTAssertEqual(chord(.resizePaneUp), KeyChord(.upArrow, [.control, .command, .shift]), "divider up = ⌃⌘⇧↑")
        XCTAssertEqual(
            chord(.resizePaneDown),
            KeyChord(.downArrow, [.control, .command, .shift]),
            "divider down = ⌃⌘⇧↓",
        )
        XCTAssertEqual(chord(.balancePanes), KeyChord(character: "=", [.control, .command]), "balance = ⌃⌘=")
    }

    /// ⌃⌘F is reserved for **Toggle Fullscreen** (the macOS-native Enter/Exit Full
    /// Screen). SlopDesk must NOT bind ⌃⌘F to any workspace action — the app-level NSEvent dispatcher reads
    /// `resolvedChordTable`, so a binding there would resolve + SWALLOW ⌃⌘F and the system Full-Screen menu
    /// item could never fire. This pins that ⌃⌘F is free (no action).
    func testControlCommandFIsFreeForSystemToggleFullscreen() {
        let controlCommandF = KeyChord(character: "f", [.control, .command])
        XCTAssertNil(
            WorkspaceBindingRegistry.chordTable[controlCommandF],
            "⌃⌘F must be unbound so it passes through to the system Toggle Fullscreen menu item",
        )
    }

    // MARK: - Tabs: Close Window (⌘⇧W) routes to the window-close gate (E7 carry-over #5)

    /// `.closeWindow` (⌘⇧W) routes to `store.requestCloseWindow()` — parking `pendingWindowClose` for the
    /// active session when the close must confirm (here: a busy pane under the default `.process` window
    /// policy). Proven to fail before `.closeWindow` exists / is routed (the pre-E7 ⌘⇧W closed the TAB instead).
    @MainActor
    func testCloseWindowRoutesToRequestCloseWindow() throws {
        // Self-contained: the default `.process` policy + a busy pane must park the window close.
        UserDefaults.standard.removeObject(forKey: SettingsKey.closeConfirmWindowKey)
        let store = makeTreeStore()
        let sessionID = try XCTUnwrap(store.tree.activeSessionID)
        let active = try XCTUnwrap(activePane(store))
        (store.handle(for: active) as? FakePaneSession)?.isShellBusy = true

        WorkspaceBindingRegistry.route(.closeWindow, to: store)

        XCTAssertEqual(
            store.pendingWindowClose, sessionID,
            "⌘⇧W routes to requestCloseWindow(), parking the active session's window close — not a tab close",
        )
        XCTAssertNil(store.pendingTabCloseID, "⌘⇧W is a WINDOW close now, never a tab close")
    }

    /// `.closeWindow` (⌘⇧W / View ▸ Close Window) ACTUATES a real close: when an actuator closure is
    /// supplied (the live app wires it to `window.performClose(nil)` → the native `windowShouldClose` →
    /// `WindowCloseGate` confirmation) the route FORWARDS to it EXACTLY once and does NOT silently park
    /// `pendingWindowClose`. The audit found the bare-park path had no SwiftUI observer, so ⌘⇧W parked a flag
    /// nothing read and never closed the window — this proves the chord now drives a close instead.
    ///
    /// REVERT-TO-CONFIRM-FAIL: with the routing case left `case .closeWindow: store.requestCloseWindow()` the
    /// actuator never fires (`fired == 0`) AND the busy window close is PARKED (`pendingWindowClose ==
    /// sessionID`) — both assertions below flip, exactly the dead-control regression.
    @MainActor
    func testCloseWindowActuatesCloseActuatorInsteadOfSilentPark() throws {
        // A busy pane under the default `.process` window policy is the case the OLD code PARKED (and nothing
        // observed the park) — so it sharpens the contrast: the actuator must fire and NOT park.
        UserDefaults.standard.removeObject(forKey: SettingsKey.closeConfirmWindowKey)
        let store = makeTreeStore()
        let active = try XCTUnwrap(activePane(store))
        (store.handle(for: active) as? FakePaneSession)?.isShellBusy = true

        var fired = 0
        WorkspaceBindingRegistry.route(.closeWindow, to: store, closeWindow: { fired += 1 })

        XCTAssertEqual(fired, 1, "⌘⇧W forwards to the close actuator exactly once (it ACTUATES a close)")
        XCTAssertNil(
            store.pendingWindowClose,
            "with an actuator supplied ⌘⇧W must NOT silently park pendingWindowClose (the dead-control bug)",
        )
    }

    // MARK: - Rename: ⌘⇧R targets the active TAB on the tree shell (ITEM B1)

    /// B1: `.renamePane` on a `.tree` store records the active TAB as the pending tab-rename target (the
    /// `TabBarView` inline field opens) — the tree/registry are untouched, a command-layer UI nudge. It must
    /// NOT set `pendingRename` (the canvas pane-rename request no tree view observes — the old dead-end).
    func testRenameActionTargetsActiveTab() throws {
        let store = makeTreeStore()
        let activeTab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        let treeBefore = store.tree
        let sessionsBefore = store.allSessions.count

        route(.renamePane, store)

        XCTAssertEqual(store.pendingTabRename, activeTab, "renamePane records the active TAB as the rename target")
        XCTAssertNil(store.pendingRename, "the dead canvas pane-rename request is NOT set on the tree shell")
        XCTAssertEqual(store.tree, treeBefore, "renamePane never mutates the tree")
        XCTAssertEqual(store.allSessions.count, sessionsBefore, "renamePane never touches the registry")
    }

    // MARK: - Registry integrity (the single source of truth)

    /// C1: every binding the DISPATCHER sees (``allBindings`` — incl. the nine generated ⌘1…⌘9 select-tab
    /// chords the `bindings` table omits) has a stable, unique id and (for the chord-carrying ones) a unique
    /// chord. Iterating only `bindings` (the old test) missed the nine digit chords the dispatcher actually
    /// routes, so a collision among them — or with a ⌘-digit elsewhere — could slip past. We ALSO assert
    /// `chordTable.count == #chord-bearing allBindings + #aliasChords`, proving no two entries collapsed onto
    /// one chord (the dict would silently drop a duplicate) while accounting for the display-less aliases.
    func testRegistryBindingsHaveUniqueIDsAndChords() {
        let ids = WorkspaceBindingRegistry.allBindings.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "all binding ids (incl. select-tab digits) are unique")

        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "no two bindings share a chord (conflict-free)")
        // An alias chord (e.g. ⌘+ → increaseFontSize) shares its ACTION, not its chord, with a real binding,
        // so it must not collide with any registered chord — else it would shadow/overwrite a live binding.
        let aliases = WorkspaceBindingRegistry.aliasChords
        XCTAssertTrue(
            Set(aliases.keys).isDisjoint(with: Set(chords)),
            "alias chords never collide with a registered binding's chord",
        )
        // The chord → action table is built from allBindings ∪ aliasChords; if two entries shared a chord the
        // dict would collapse them, dropping the count below (#chord-bearing bindings + #aliases).
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable.count,
            chords.count + aliases.count,
            "every chord-bearing binding + every alias has its OWN chordTable entry (no collision collapsed two)",
        )
    }

    /// The cheat sheet's SINGLE source (``groupedForDisplay``) must surface a Tabs-group row collapsing the
    /// nine generated ⌘1…⌘9 select-tab chords — the doc contract (lines 204-207 / 524-526) promises one
    /// representative row, yet the nine per-digit chords live only in ``selectTabBindings`` (absent from the
    /// `bindings` table groupedForDisplay iterates). Without the synthesized representative, the cheat sheet
    /// silently omits the whole "switch to tab N" family. FAILS on the un-fixed code (no such row exists).
    func testGroupedForDisplaySurfacesCollapsedSelectTabRow() {
        let tabs = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .tabs }
        XCTAssertNotNil(tabs, "the Tabs group is present in the cheat-sheet display set")
        let selectTabRow = tabs?.bindings.first { $0.title.contains("⌘1…⌘9") }
        XCTAssertNotNil(
            selectTabRow,
            "groupedForDisplay surfaces ONE representative ⌘1…⌘9 select-tab row (the doc-promised collapse)",
        )
        // The representative is display-only: chord:nil so the overlay renders the glyph baked into the
        // title (no single-chord hint chip), and the real per-digit chords stay in selectTabBindings.
        XCTAssertNil(selectTabRow?.chord, "the collapsed row carries no single chord (glyph is in the title)")
        XCTAssertEqual(
            WorkspaceBindingRegistry.selectTabBindings.count, 9,
            "the nine real per-digit chords still live in selectTabBindings (not the display set)",
        )
    }

    /// C1: every chord-carrying binding the DISPATCHER sees (``allBindings``) is ⌘- or ⌥-prefixed (the
    /// load-bearing §5 conflict rule: a bare key / Ctrl-letter must fall through to the focused terminal).
    /// Iterating `allBindings` (not just `bindings`) covers the nine ⌘-digit select-tab chords too.
    func testEveryChordIsCommandOrOptionPrefixed() {
        for binding in WorkspaceBindingRegistry.allBindings {
            guard let chord = binding.chord else { continue }
            // E1 exemption: a NON-PRINTABLE named navigation key (PageUp/PageDown/Home/End) cannot steal a
            // printable terminal letter, so a ⇧-prefixed scroll chord (⇧PageUp, ⇧Home, …) is allowed even
            // though it is not ⌘/⌥-prefixed. The §5 rule still binds EVERY printable-key chord (below).
            switch chord.key {
            case .pageUp,
                 .pageDown,
                 .home,
                 .end:
                continue
            default:
                break
            }
            XCTAssertTrue(
                chord.modifiers.contains(.command) || chord.modifiers.contains(.option),
                "binding \(binding.id) chord must be ⌘- or ⌥-prefixed (never steal a terminal key)",
            )
        }
    }

    /// E17 ES-E17-2 / WI-5: the Vi Mode entry chord ⌃⇧Space resolves (through the dispatcher's
    /// ``resolvedChordTable``, which folds ``aliasChords``) to `.toggleCopyMode` — the SAME action as the
    /// canonical ⌘⇧C display chord. Space is the NAMED `.space` key (keyCode 49), and ⌃⇧Space must be free.
    /// Revert-to-confirm-fail: before the alias existed, ⌃⇧Space resolved to `nil` and the command was titled
    /// "Copy Mode" with no "vi" surface name.
    func testViModeEntryChordAndTitle() {
        // ⌃⇧Space was unbound before this fix (no collision with another binding's chord).
        let viChord = KeyChord(.space, [.control, .shift])
        let plainChords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertFalse(plainChords.contains(viChord), "⌃⇧Space is FREE — no registered binding already owns it")
        // The dispatcher's resolved table folds the alias → it fires Vi / Copy mode.
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChordTable[viChord], .toggleCopyMode,
            "⌃⇧Space (Vi Mode entry) resolves to the vi/copy-mode action via the alias",
        )
        // The command is discoverable as "Vi Mode", keeping "copy mode" as a search synonym.
        let binding = WorkspaceBindingRegistry.binding(for: .toggleCopyMode)
        XCTAssertEqual(binding?.title, "Vi Mode", "the command surfaces as 'Vi Mode'")
        XCTAssertEqual(binding?.chord, KeyChord(character: "c", [.command, .shift]), "the display chord stays ⌘⇧C")
        XCTAssertTrue(
            binding?.keywords?.contains("copy mode") == true,
            "'copy mode' stays a keyword so existing palette search still finds it",
        )
    }

    /// E17 ES-E17-2 / WI-5: the "Vi Mode Key Hints" command is DISCOVERABLE (a registry row in the View group,
    /// chord-less because `⌘/` is owned by the cheat sheet) and routes to the active pane's hint-bar toggle.
    /// Revert-to-confirm-fail: before this fix there was no `.toggleViKeyHints` action / row, so the hint bar was
    /// reachable only via the contextual `⌘/` while already in vi mode (binding(for:) would be `nil`).
    func testViModeKeyHintsCommandIsDiscoverableAndRoutes() throws {
        let binding = try XCTUnwrap(
            WorkspaceBindingRegistry.binding(for: .toggleViKeyHints),
            "the Vi Mode Key Hints command has a registry row",
        )
        XCTAssertEqual(binding.title, "Vi Mode Key Hints")
        XCTAssertEqual(binding.category, .view)
        XCTAssertNil(binding.chord, "chord-less — ⌘/ is owned by the cheat sheet (contextual)")
        // It is surfaced in the palette/cheat-sheet display set (the View group).
        let viewRows = WorkspaceBindingRegistry.groupedForDisplay.first { $0.category == .view }?.bindings ?? []
        XCTAssertTrue(
            viewRows.contains { $0.action == .toggleViKeyHints },
            "the command appears in the View group's display rows (palette / cheat sheet)",
        )
        // (The end-to-end ROUTING of `.toggleViKeyHints` onto a live model's hint bar is pinned by
        // `ViKeyHintsRoutingTests.testViKeyHintsCommandRoutesToActivePaneHintBar`, which uses a real-model
        // session — `FakePaneSession` here carries no `TerminalViewModel`.)
    }

    /// The chord table resolves the documented coding-IDE defaults — pins the exact chords the cheat sheet
    /// advertises so a transposed modifier can't slip past the "every action has a row" drift guard.
    func testDefaultChordsMatchTheDocumentedTable() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.newTab), KeyChord(character: "t", [.command]), "new tab = ⌘T")
        XCTAssertEqual(chord(.closePane), KeyChord(character: "w", [.command]), "close pane = ⌘W")
        XCTAssertEqual(chord(.splitRight), KeyChord(character: "d", [.command]), "split right = ⌘D")
        XCTAssertEqual(chord(.splitDown), KeyChord(character: "d", [.command, .shift]), "split down = ⌘⇧D")
        XCTAssertEqual(chord(.focusLeft), KeyChord(.leftArrow, [.control, .command]), "focus left = ⌃⌘←")
        XCTAssertEqual(chord(.toggleZoom), KeyChord(.return, [.command, .shift]), "zoom = ⌘⇧↩")
        // E1 re-scope (ES-E1-2 / DECISIONS): tab cycling moved to ⌘⇧]/⌘⇧[ (was ⌘]/⌘[ under the old Muxy
        // parity); plain ⌘]/⌘[ now drive sequential PANE cycling (`focus.cycleNext`/`focus.cyclePrev`). These
        // pins are ours to re-scope.
        XCTAssertEqual(chord(.nextTab), KeyChord(character: "]", [.command, .shift]), "next tab = ⌘⇧] (E1 re-scope)")
        XCTAssertEqual(chord(.prevTab), KeyChord(character: "[", [.command, .shift]), "prev tab = ⌘⇧[ (E1 re-scope)")
        // E7 carry-over #5 / DECISIONS: ⌘⇧W reconciled Close Tab → Close WINDOW. Close Tab is now CHORD-LESS
        // (reachable via the ⌘W cascade + palette/menu — Close Tab ships with no dedicated chord); ⌘⇧W = Close
        // Window.
        XCTAssertNil(chord(.closeTab), "close tab is chord-less (E7: ⌘⇧W moved to Close Window)")
        XCTAssertEqual(chord(.closeWindow), KeyChord(character: "w", [.command, .shift]), "close window = ⌘⇧W (E7)")
        // E1 review fix: the sidebar toggle was ⌘B, which routed to the LEGACY
        // `store.sidebarCollapsed` the native split shell never reads (a DEAD chord). Re-bound to
        // ⌘⇧L "Toggle Tabs Panel" (docs/ui-shell/spec/reference__keybindings.md:66), routed through a `chrome`
        // view-closure.
        XCTAssertEqual(
            chord(.toggleSidebar), KeyChord(character: "l", [.command, .shift]), "toggle sidebar = ⌘⇧L",
        )
        XCTAssertEqual(chord(.selectTab(1)), KeyChord(character: "1", [.command]), "select tab 1 = ⌘1")
        XCTAssertEqual(chord(.selectTab(9)), KeyChord(character: "9", [.command]), "select tab 9 = ⌘9")
        XCTAssertEqual(chord(.find), KeyChord(character: "f", [.command]), "find = ⌘F (W14)")
        // WB2 Warp-style Blocks chords.
        XCTAssertEqual(
            chord(.commandNavigator), KeyChord(character: "o", [.control, .command]), "navigator = ⌃⌘O",
        )
        XCTAssertEqual(
            chord(.jumpPreviousBlock), KeyChord(character: "[", [.control, .command]), "prev block = ⌃⌘[",
        )
        XCTAssertEqual(
            chord(.jumpNextBlock), KeyChord(character: "]", [.control, .command]), "next block = ⌃⌘]",
        )
    }

    // MARK: - View: WB2 block actions route to the active-pane store hooks

    /// The WB2 navigator / jump-to-block actions route to the store's active-pane hooks (no closure path) —
    /// a no-op against a FakePaneSession (not a live terminal), but they must not trap or mutate the tree.
    /// Pins that the three new actions are wired to the store, not dropped. Proven to fail before routing.
    @MainActor
    func testBlockActionsRouteToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.commandNavigator, to: store)
        WorkspaceBindingRegistry.route(.jumpPreviousBlock, to: store)
        WorkspaceBindingRegistry.route(.jumpNextBlock, to: store)
        XCTAssertEqual(store.tree, before, "the WB2 block actions are active-pane affordances — the tree is unchanged")
    }

    /// WB3: the re-run-last + jump-to-failed actions route to the store's active-pane hooks WITHOUT trapping
    /// or mutating the tree. Against a `FakePaneSession` (not a live terminal) the hooks no-op, so this only
    /// pins tree-immutability + trap-freedom — it is BLIND to which store hook fires or the forward/backward
    /// mapping. The BEHAVIORAL dispatch (re-run bytes, the `.jumpPreviousFailed`/`.jumpNextFailed` direction
    /// inversion) is proven in `WB3BlockRoutingDispatchTests` over a live-model recording double.
    @MainActor
    func testWB3BlockActionsRouteToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.reRunLastCommand, to: store)
        WorkspaceBindingRegistry.route(.jumpPreviousFailed, to: store)
        WorkspaceBindingRegistry.route(.jumpNextFailed, to: store)
        XCTAssertEqual(store.tree, before, "the WB3 block actions are active-pane affordances — the tree is unchanged")
    }

    /// WB3: pins the three new chords are exactly ⌃⌘R / ⌃⌘⇧[ / ⌃⌘⇧] (and so distinct from the existing
    /// ⌃⌘[ / ⌃⌘] block-jump + ⌘[ / ⌘] tab-cycle chords). The generic uniqueness guard
    /// (`testRegistryBindingsHaveUniqueIDsAndChords`) catches a collision; this pins the intended values.
    @MainActor
    func testWB3ChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.reRunLastCommand), KeyChord(character: "r", [.control, .command]), "re-run = ⌃⌘R")
        XCTAssertEqual(
            chord(.jumpPreviousFailed), KeyChord(character: "[", [.control, .command, .shift]), "prev failed = ⌃⌘⇧[",
        )
        XCTAssertEqual(
            chord(.jumpNextFailed), KeyChord(character: "]", [.control, .command, .shift]), "next failed = ⌃⌘⇧]",
        )
    }

    // MARK: - View: find routes to the overlay toggle (W14 #5)

    /// `.find` with an explicit `toggleFind` override fires the closure (the root view's find-bar `@State`),
    /// NOT a store mutation — and leaves the tree untouched. Proven to fail before `.find` is routed.
    @MainActor
    func testFindActionFiresToggleClosureAndDoesNotMutateTree() {
        let store = makeTreeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.find, to: store, toggleFind: { fired += 1 })
        XCTAssertEqual(fired, 1, "the find action invoked the toggleFind closure")
        XCTAssertEqual(store.tree, before, "find is a view overlay — the tree is unchanged")
    }

    /// `.find` WITHOUT a `toggleFind` override (the menu / keyboard path) routes to the store's
    /// `requestFindInActivePane()` — a no-op against a FakePaneSession (not a live terminal), but it must
    /// not trap or mutate the tree. Pins that the no-closure path is wired to the store, not dropped.
    @MainActor
    func testFindActionWithoutClosureRoutesToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.find, to: store) // no toggleFind ⇒ store path
        XCTAssertEqual(store.tree, before, "the store find path leaves the tree unchanged")
    }

    // MARK: - View: E5 find-nav (⌘G/⇧⌘G) + global search (⇧⌘F) — chords + routing

    /// E5: pins the three new chords to their documented free defaults — ⌘G Find Next, ⇧⌘G Find Previous,
    /// ⇧⌘F Global Search. The generic uniqueness guard catches a COLLISION; this pins the intended values so a
    /// transposed modifier can't slip past it.
    func testE5FindNavAndGlobalSearchChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.findNext), KeyChord(character: "g", [.command]), "find next = ⌘G")
        XCTAssertEqual(chord(.findPrev), KeyChord(character: "g", [.command, .shift]), "find previous = ⇧⌘G")
        XCTAssertEqual(chord(.globalSearch), KeyChord(character: "f", [.command, .shift]), "global search = ⇧⌘F")
    }

    /// E5: the find/search chords must be present in ``allBindings`` AND chord-unique against the whole
    /// table. The generic uniqueness test asserts no two share a chord over the FULL set; this adds the
    /// explicit presence of the `f`/`g` family.
    func testE5NewChordsArePresentAndChordUnique() {
        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "no two bindings share a chord after the E5 additions")
        // The `f` family: ⌘F find, ⇧⌘F global search — DISTINCT chords on the same key (⌃⌘F is deliberately
        // ABSENT — reserved for Toggle Fullscreen).
        XCTAssertTrue(chords.contains(KeyChord(character: "f", [.command])), "⌘F find present")
        XCTAssertTrue(chords.contains(KeyChord(character: "f", [.command, .shift])), "⇧⌘F global search present")
        XCTAssertFalse(
            chords.contains(KeyChord(character: "f", [.control, .command])),
            "⌃⌘F is reserved for system Toggle Fullscreen — not a workspace binding",
        )
        XCTAssertTrue(chords.contains(KeyChord(character: "g", [.command])), "⌘G find next present")
        XCTAssertTrue(chords.contains(KeyChord(character: "g", [.command, .shift])), "⇧⌘G find previous present")
    }

    /// `.findNext` / `.findPrev` WITHOUT any per-pane find callback installed (a `FakePaneSession` is not a live
    /// terminal, so `terminalModel` is nil) must route to the store's open-if-closed path WITHOUT trapping or
    /// mutating the tree. Pins that ⌘G / ⇧⌘G are wired to the store (not dropped) and degrade gracefully — the
    /// behavioural "opens the bar when closed" is proven over a live model elsewhere.
    @MainActor
    func testFindNavActionsRouteToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.findNext, to: store)
        WorkspaceBindingRegistry.route(.findPrev, to: store)
        XCTAssertEqual(store.tree, before, "the find-nav actions are active-pane affordances — the tree is unchanged")
    }

    /// `.globalSearch` WITH an explicit `toggleGlobalSearch` override fires the closure (the OverlayCoordinator
    /// flag) and does NOT mutate the tree. Proven to fail before `.globalSearch` exists / is routed.
    @MainActor
    func testGlobalSearchFiresToggleClosureAndDoesNotMutateTree() {
        let store = makeTreeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.globalSearch, to: store, toggleGlobalSearch: { fired += 1 })
        XCTAssertEqual(fired, 1, "the global-search action invoked the toggleGlobalSearch closure")
        XCTAssertEqual(store.tree, before, "global search is a view overlay — the tree is unchanged")
    }

    /// `.globalSearch` WITHOUT a `toggleGlobalSearch` override (the headless / test default) is a graceful
    /// no-op — never a trap, never a tree mutation. Pins the nil-closure path stays inert.
    @MainActor
    func testGlobalSearchWithoutClosureIsAGracefulNoOp() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.globalSearch, to: store) // no closure ⇒ no-op
        XCTAssertEqual(store.tree, before, "global search with no closure leaves the tree unchanged")
    }

    // MARK: - View: Open Quickly (⌘⇧O) + the folded-in Jump-To (⌘J) (E11/WI-7)

    /// `.openQuickly` WITH an explicit `openQuickly` override fires the closure (the app binds it to
    /// `overlay.toggleOpenQuickly(filter: .all)` — the merged All pill) and does NOT mutate the tree. The
    /// chord is GLOBAL (owned by the NSEvent dispatcher) only while the picker is HIDDEN; once it is open the
    /// dispatcher's `isOverlayCapturingKeys` gate yields the keyboard to the picker, so the pill / ⌘1–9 / Tab /
    /// ⌘K chords are picker-local and never reach `route`. FAILS on pre-WI-7 code (`.openQuickly` was a dead
    /// `break`, no closure arg).
    @MainActor
    func testOpenQuicklyFiresToggleClosureAndDoesNotMutateTree() {
        let store = makeTreeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.openQuickly, to: store, openQuickly: { fired += 1 })
        XCTAssertEqual(fired, 1, "the open-quickly action invoked the openQuickly closure")
        XCTAssertEqual(store.tree, before, "open quickly is a view overlay — the tree is unchanged")
    }

    /// `.openQuickly` WITHOUT an `openQuickly` override (the headless / test default) is a graceful no-op —
    /// never a trap, never a tree mutation. Pins the nil-closure path stays inert (the chord is never dead,
    /// but with no overlay wired it does nothing rather than crashing).
    @MainActor
    func testOpenQuicklyWithoutClosureIsAGracefulNoOp() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.openQuickly, to: store) // no closure ⇒ no-op
        XCTAssertEqual(store.tree, before, "open quickly with no closure leaves the tree unchanged")
    }

    /// `.jumpTo` (⌘J) stays a DISTINCT routing case from `.openQuickly`: it fires its OWN `toggleJumpTo`
    /// closure (the app re-points that to `overlay.toggleOpenQuickly(filter: .current)`), independent of the
    /// `openQuickly` toggle. Pins that the two global chords remain separately routed (no double-fire / alias)
    /// — passing `openQuickly` must NOT fire on a `.jumpTo`, and vice-versa.
    @MainActor
    func testJumpToAndOpenQuicklyAreSeparatelyRoutedClosures() {
        let store = makeTreeStore()
        let before = store.tree
        var jumpToFired = 0
        var openQuicklyFired = 0
        WorkspaceBindingRegistry.route(
            .jumpTo, to: store,
            toggleJumpTo: { jumpToFired += 1 },
            openQuickly: { openQuicklyFired += 1 },
        )
        XCTAssertEqual(jumpToFired, 1, "⌘J fired its own toggleJumpTo closure")
        XCTAssertEqual(openQuicklyFired, 0, "⌘J did NOT fire the openQuickly (⌘⇧O) closure")
        WorkspaceBindingRegistry.route(
            .openQuickly, to: store,
            toggleJumpTo: { jumpToFired += 1 },
            openQuickly: { openQuicklyFired += 1 },
        )
        XCTAssertEqual(openQuicklyFired, 1, "⌘⇧O fired the openQuickly closure")
        XCTAssertEqual(jumpToFired, 1, "⌘⇧O did NOT re-fire the toggleJumpTo closure")
        XCTAssertEqual(store.tree, before, "both are view overlays — the tree is unchanged")
    }

    // MARK: - View: read-only (E17 ES-E17-1) — chord-less registry pin + active-pane routing

    /// `.toggleReadOnly` is registered, in the View category, and CHORD-LESS by design — it must never
    /// collide with a chord yet must not be a dead row. Revert-to-confirm-fail by
    /// removing the registry case (this test then fails to find the binding).
    func testReadOnlyBindingIsViewAndChordless() {
        let binding = WorkspaceBindingRegistry.binding(for: .toggleReadOnly)
        XCTAssertEqual(binding?.id, "view.readOnly", "read-only has the stable id view.readOnly")
        XCTAssertEqual(binding?.category, .view, "read-only is a View command")
        XCTAssertNil(binding?.chord, "read-only is unbound by default (no default chord)")
    }

    /// Routing `.toggleReadOnly` flips the ACTIVE pane's membership in the convergent `paneReadOnly` set
    /// (the single source the pill `×` + the sidebar lock both read) WITHOUT mutating the tree, and a second
    /// route clears it. Proven to fail before the action / routing case / store seam exist.
    func testToggleReadOnlyRoutesToActivePaneAndIsReversible() throws {
        let store = makeTreeStore()
        let active = try XCTUnwrap(activePane(store))
        let treeBefore = store.tree
        XCTAssertFalse(store.isReadOnly(for: active), "panes start writable")

        WorkspaceBindingRegistry.route(.toggleReadOnly, to: store)
        XCTAssertTrue(store.paneReadOnly.contains(active), "toggleReadOnly locked the active pane")
        XCTAssertTrue(store.isReadOnly(for: active), "isReadOnly reflects the convergent set")

        WorkspaceBindingRegistry.route(.toggleReadOnly, to: store)
        XCTAssertFalse(store.paneReadOnly.contains(active), "a second toggle cleared the lock")
        XCTAssertEqual(store.tree, treeBefore, "read-only is a view-state gate — the tree is unchanged")
    }

    // MARK: - View: Release Stuck Input (C5) — chord-less registry pin + active-pane routing

    /// `.releaseStuckInput` is registered, in the View category, and CHORD-LESS by design (the chord-less
    /// idiom — like `view.readOnly`). Revert-to-confirm-fail by removing the registry case.
    func testReleaseStuckInputBindingIsViewAndChordless() {
        let binding = WorkspaceBindingRegistry.binding(for: .releaseStuckInput)
        XCTAssertEqual(binding?.id, "view.releaseStuckInput", "stable id for override keying")
        XCTAssertEqual(binding?.category, .view, "Release Stuck Input is a View command")
        XCTAssertNil(binding?.chord, "unbound by default (palette/menu only)")
    }

    /// Routing `.releaseStuckInput` fires the ACTIVE pane handle's `releaseStuckInput()` — and ONLY the
    /// active pane's — without mutating the tree. (On a live `.remoteGUI` pane the handle forwards to the
    /// `RemoteWindowModel`'s published release sink; that forwarding is pinned separately.)
    func testReleaseStuckInputRoutesToActivePaneHandleOnly() throws {
        let store = makeTreeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal) // a sibling proves "only the active" fires
        let active = try XCTUnwrap(activePane(store))
        let treeBefore = store.tree

        WorkspaceBindingRegistry.route(.releaseStuckInput, to: store)

        for id in leaves(store) {
            let fake = try XCTUnwrap(store.handle(for: id) as? FakePaneSession)
            XCTAssertEqual(
                fake.releaseStuckInputCount, id == active ? 1 : 0,
                "the escape hatch fires exactly once, on the active pane only",
            )
        }
        XCTAssertEqual(store.tree, treeBefore, "a synthetic input release never mutates the tree")
    }

    // MARK: - View: Paste as Keystrokes (C7) — ⌥⌘V registry pin + active-pane clipboard routing

    /// `.pasteAsKeystrokes` is registered, in the View category, and bound to ⌥⌘V (FREE — `v` is in no other
    /// chord); the chord table resolves ⌥⌘V to it. Revert-to-confirm-fail by removing the registry row.
    func testPasteAsKeystrokesBindingIsViewAndOptCmdV() {
        let binding = WorkspaceBindingRegistry.binding(for: .pasteAsKeystrokes)
        XCTAssertEqual(binding?.id, "view.pasteAsKeystrokes", "stable id for override keying")
        XCTAssertEqual(binding?.category, .view, "Paste as Keystrokes is a View command")
        XCTAssertEqual(binding?.chord, KeyChord(character: "v", [.command, .option]), "⌥⌘V")
        XCTAssertEqual(
            WorkspaceBindingRegistry.chordTable[KeyChord(character: "v", [.command, .option])],
            .pasteAsKeystrokes, "⌥⌘V resolves to .pasteAsKeystrokes in the dispatcher table",
        )
    }

    /// Routing `.pasteAsKeystrokes` types the CURRENT local clipboard into the ACTIVE pane's handle — and
    /// ONLY the active pane's — reading the live clipboard via the injected provider, without mutating the
    /// tree. (On a live `.remoteGUI` pane the handle forwards to the `RemoteWindowModel`'s key sink.)
    func testPasteAsKeystrokesRoutesCurrentClipboardToActivePaneHandleOnly() throws {
        let store = makeTreeStore()
        store.clipboardTextProvider = { "s3cret-from-clipboard" }
        store.splitActivePane(axis: .horizontal, kind: .terminal) // a sibling proves "only the active" fires
        let active = try XCTUnwrap(activePane(store))
        let treeBefore = store.tree

        WorkspaceBindingRegistry.route(.pasteAsKeystrokes, to: store)

        for id in leaves(store) {
            let fake = try XCTUnwrap(store.handle(for: id) as? FakePaneSession)
            XCTAssertEqual(
                fake.pastedKeystrokes, id == active ? ["s3cret-from-clipboard"] : [],
                "the clipboard is typed exactly once, into the active pane only",
            )
        }
        XCTAssertEqual(store.tree, treeBefore, "typing the clipboard never mutates the tree")
    }

    /// An EMPTY (or whitespace-only) local clipboard makes ⌥⌘V a graceful no-op — never a dead chord, and
    /// nothing reaches any pane.
    func testPasteAsKeystrokesWithEmptyClipboardIsNoOp() throws {
        let store = makeTreeStore()
        store.clipboardTextProvider = { "   \n\t " }
        let active = try XCTUnwrap(activePane(store))

        WorkspaceBindingRegistry.route(.pasteAsKeystrokes, to: store)

        let fake = try XCTUnwrap(store.handle(for: active) as? FakePaneSession)
        XCTAssertTrue(fake.pastedKeystrokes.isEmpty, "a blank clipboard types nothing")
    }

    /// `currentLocalClipboard()` prefers the injected provider, and falls back to the ring head when no
    /// provider is wired (so a recorded clip is still typable when the app hasn't installed the reader).
    func testCurrentLocalClipboardPrefersProviderThenRingHead() {
        let store = makeTreeStore()
        XCTAssertNil(store.currentLocalClipboard(), "no provider + empty ring ⇒ nothing")
        store.recordClip("ring-head")
        XCTAssertEqual(store.currentLocalClipboard(), "ring-head", "falls back to the most recent clip")
        store.clipboardTextProvider = { "live-clipboard" }
        XCTAssertEqual(store.currentLocalClipboard(), "live-clipboard", "the live provider wins over the ring")
    }

    // MARK: - View: peek-and-reply falls back to the store when no overlay closure (no dead ⌘⇧J)

    /// `.peekAndReply` WITH an explicit `togglePeekReply` override fires the closure (the future overlay
    /// toggle) and does NOT mutate the tree.
    @MainActor
    func testPeekReplyFiresToggleClosureWhenProvided() {
        let store = makeTreeStore()
        let before = store.tree
        var fired = 0
        WorkspaceBindingRegistry.route(.peekAndReply, to: store, togglePeekReply: { fired += 1 })
        XCTAssertEqual(fired, 1, "the peekAndReply action invoked the togglePeekReply closure")
        XCTAssertEqual(store.tree, before, "with a closure, peek-reply is a view overlay — tree unchanged")
    }

    /// `.peekAndReply` WITHOUT a `togglePeekReply` override (the keyboard-bank path, until the overlay
    /// lands) must NOT be a dead key: it falls back to focusing the oldest attention pane. Proven to fail
    /// on the pre-fix routing where the nil closure was a silent no-op (focus would NOT move).
    @MainActor
    func testPeekReplyWithoutClosureFocusesOldestAttentionPane() throws {
        let store = makeTreeStore()
        let firstPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        route(.newTab, store) // a second tab becomes active
        let secondPane = try XCTUnwrap(activePane(store))
        XCTAssertNotEqual(firstPane, secondPane)
        store.setAgentStatus(.needsPermission, for: firstPane) // the BACKGROUND pane is blocked

        WorkspaceBindingRegistry.route(.peekAndReply, to: store) // no closure ⇒ store fallback
        XCTAssertEqual(activePane(store), firstPane, "⌘⌥J without an overlay jumps to the blocked pane")
    }

    // MARK: - View: Hint Mode (E10 WI-9, ES-E10-6) — chord pins + active-pane routing

    /// Pins the three Hint Mode chords to their E10 defaults: ⌘⇧J Hint to Open, ⌘⇧Y Hint to Copy, and Hint to
    /// Reveal CHORD-LESS (⌘⇧R is already slopdesk's Toggle Details chord). ALSO pins that peek-and-reply RE-POINTED
    /// ⌘⇧J → ⌘⌥J so Hint to Open could own ⌘⇧J (the carryover binding). The generic uniqueness guard catches a
    /// COLLISION; this pins the intended values so a transposed modifier can't slip past it. Revert-to-confirm-fail
    /// by removing the hint bindings (this fails to find them) or leaving peek-and-reply on ⌘⇧J (a collision).
    func testHintModeChordsAreTheDocumentedDefaults() {
        func chord(_ action: WorkspaceAction) -> KeyChord? {
            WorkspaceBindingRegistry.binding(for: action)?.chord
        }
        XCTAssertEqual(chord(.hintToOpen), KeyChord(character: "j", [.command, .shift]), "hint to open = ⌘⇧J")
        XCTAssertEqual(chord(.hintToCopy), KeyChord(character: "y", [.command, .shift]), "hint to copy = ⌘⇧Y")
        XCTAssertNil(chord(.hintToReveal), "hint to reveal is chord-less (⌘⇧R is Toggle Details on slopdesk)")
        XCTAssertEqual(
            chord(.peekAndReply), KeyChord(character: "j", [.command, .option]),
            "peek & reply re-pointed ⌘⇧J → ⌘⌥J (E10 owns ⌘⇧J for Hint Mode)",
        )
    }

    /// The four `j`/`y` chords must coexist chord-uniquely: ⌘J jump-to, ⌘⇧J hint-open, ⌘⌥J peek-and-reply, and
    /// ⌘⇧Y hint-copy — the exact set E10 reshuffled. The generic uniqueness test asserts no two share a chord;
    /// this adds the explicit presence + disambiguation so the re-point can't silently drop or collide a chord.
    func testHintModeChordsArePresentAndChordUnique() {
        let chords = WorkspaceBindingRegistry.allBindings.compactMap(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count, "no two bindings share a chord after the E10 hint additions")
        XCTAssertTrue(chords.contains(KeyChord(character: "j", [.command])), "⌘J jump-to present")
        XCTAssertTrue(chords.contains(KeyChord(character: "j", [.command, .shift])), "⌘⇧J hint-to-open present")
        XCTAssertTrue(chords.contains(KeyChord(character: "j", [.command, .option])), "⌘⌥J peek-and-reply present")
        XCTAssertTrue(chords.contains(KeyChord(character: "y", [.command, .shift])), "⌘⇧Y hint-to-copy present")
    }

    /// The three hint actions route to the store's active-pane hook (`activeTerminalModel?.beginHint`) — a no-op
    /// against a `FakePaneSession` (not a live terminal), but they must not trap or mutate the tree. Pins that
    /// the new actions are wired to the store, not dropped. Proven to fail before the routing cases exist (the
    /// exhaustive switch would not compile, then would mis-route).
    @MainActor
    func testHintActionsRouteToStoreWithoutMutatingTree() {
        let store = makeTreeStore()
        let before = store.tree
        WorkspaceBindingRegistry.route(.hintToOpen, to: store)
        WorkspaceBindingRegistry.route(.hintToCopy, to: store)
        WorkspaceBindingRegistry.route(.hintToReveal, to: store)
        XCTAssertEqual(store.tree, before, "the hint actions are active-pane affordances — the tree is unchanged")
    }

    // L0: the cheat-sheet drift-guard tests (testTreeCheatSheetChordsEqualRegistryChords /
    // testTreeCheatSheetSectionsAreWellFormed) were DELETED — they generated from
    // `KeyboardCheatSheet.treeSections()`, a static on the deleted SwiftUI cheat-sheet overlay. The
    // registry chords themselves stay pinned by the other tests in this file; the rebuilt cheat sheet
    // (L5) re-asserts the registry→sheet generation.
}
