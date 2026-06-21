import CoreGraphics
import Foundation
import XCTest
@testable import AislopdeskClientUI

/// Pins the tmux/zellij `select-layout` re-tile transforms (``WorkspaceTreeOps/applyLayout(_:activeTabContaining:in:)``
/// + ``WorkspaceTreeOps/cycleLayout(activeTabContaining:from:in:)``): each preset rebuilds the active tab's
/// tiled tree into the documented SHAPE while **preserving the exact leaf-`PaneID` set** (the no-teardown
/// invariant), resets weights to an equal `.flex(1)` share, is a no-op for 0/1 leaf, leaves floating panes
/// untouched, and un-zooms before tiling.
///
/// Revert-to-confirm-fail: every assertion references `WorkspaceTreeOps.LayoutPreset` /
/// `applyLayout` / `cycleLayout`, which do not exist before the op — so the suite fails to compile on the
/// un-fixed tree (the structural pins below additionally fail on a wrong shape).
final class SelectLayoutTransformTests: XCTestCase {
    // MARK: Fixtures

    private func termSpec(_ title: String = "Terminal") -> PaneSpec {
        PaneSpec(kind: .terminal, title: title)
    }

    /// A `TreeWorkspace` with one session/tab holding `n` tiled leaves (built by repeated horizontal split
    /// off the first leaf, so the DFS order is deterministic). Returns the workspace + the leaf ids in DFS
    /// order. `tab.activePane` is the FIRST leaf.
    private func nLeaves(_ n: Int) -> (TreeWorkspace, [PaneID]) {
        precondition(n >= 1)
        var ws = TreeWorkspace.singlePane(spec: termSpec("p0"))
        let first = ws.allPaneIDs()[0]
        for i in 1..<max(n, 1) where n > 1 {
            let (after, _) = WorkspaceTreeOps.splitPane(first, axis: .horizontal, newSpec: termSpec("p\(i)"), in: ws)
            ws = after
        }
        // Pin the active pane to the first leaf in DFS order (deterministic across the split chain).
        let dfs = ws.sessions[0].tabs[0].root.allPaneIDs()
        ws.sessions[0].tabs[0].activePane = dfs.first
        return (ws, dfs)
    }

    private func activeTab(_ ws: TreeWorkspace) throws -> Tab {
        try XCTUnwrap(XCTUnwrap(ws.activeSession).activeTab)
    }

    private func activeRoot(_ ws: TreeWorkspace) throws -> SplitNode {
        try activeTab(ws).root
    }

    /// Assert every flex weight in the tree equals `.flex(1)` (the equal-share reset) — recursively.
    private func assertAllFlexOne(_ node: SplitNode, file: StaticString = #filePath, line: UInt = #line) {
        if case let .split(_, _, children) = node {
            for child in children {
                guard case let .flex(w) = child.weight else {
                    XCTFail("rebuilt child is not .flex", file: file, line: line)
                    continue
                }
                XCTAssertEqual(w, 1, "rebuilt weights reset to .flex(1)", file: file, line: line)
                assertAllFlexOne(child.node, file: file, line: line)
            }
        }
    }

    // MARK: Leaf-set preservation (no teardown) — the load-bearing invariant

    func testEveryPresetPreservesTheExactLeafSet() throws {
        for n in [2, 3, 4, 5, 6, 7] {
            let (ws, ids) = nLeaves(n)
            for preset in WorkspaceTreeOps.LayoutPreset.allCases {
                let after = WorkspaceTreeOps.applyLayout(preset, activeTabContaining: ids[0], in: ws)
                let newLeaves = try activeRoot(after).allPaneIDs()
                XCTAssertEqual(
                    Set(newLeaves), Set(ids),
                    "preset \(preset) with \(n) leaves must keep the EXACT leaf set (no teardown)",
                )
                XCTAssertEqual(newLeaves.count, n, "no leaf duplicated/dropped for \(preset)/\(n)")
                // Specs == leafIDs invariant survives.
                XCTAssertEqual(Set(after.sessions[0].specs.keys), Set(ids), "specs track the leaf set")
            }
        }
    }

    // MARK: even-horizontal / even-vertical

    func testEvenHorizontalIsOneRowOfColumns() throws {
        let (ws, ids) = nLeaves(3)
        let after = WorkspaceTreeOps.applyLayout(.evenHorizontal, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, children) = try activeRoot(after) else {
            XCTFail("even-horizontal must be a single split")
            return
        }
        XCTAssertEqual(axis, .horizontal, "even-horizontal = side-by-side columns")
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(children.map(\.node), ids.map { SplitNode.leaf($0) }, "leaves in DFS order, all direct children")
        try assertAllFlexOne(activeRoot(after))
    }

    func testEvenVerticalIsOneColumnOfRows() throws {
        let (ws, ids) = nLeaves(3)
        let after = WorkspaceTreeOps.applyLayout(.evenVertical, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, children) = try activeRoot(after) else {
            XCTFail("even-vertical must be a single split")
            return
        }
        XCTAssertEqual(axis, .vertical, "even-vertical = stacked rows")
        XCTAssertEqual(children.map(\.node), ids.map { SplitNode.leaf($0) })
    }

    // MARK: main-vertical / main-horizontal (active leaf large + ≥2-children collapse)

    func testMainVerticalN3HasActiveLeftAndStackedRight() throws {
        let (ws0, ids) = nLeaves(3)
        // Make the SECOND leaf active so we can prove the active pane becomes the "main" (large) one.
        var ws = ws0
        ws.sessions[0].tabs[0].activePane = ids[1]
        let after = WorkspaceTreeOps.applyLayout(.mainVertical, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, children) = try activeRoot(after) else {
            XCTFail("main-vertical must be a 2-child horizontal split")
            return
        }
        XCTAssertEqual(axis, .horizontal, "main-vertical splits left|right (columns)")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].node, .leaf(ids[1]), "the ACTIVE leaf is the large left pane")
        // The right side is a vertical stack of the remaining two leaves (DFS order, active removed).
        guard case let .split(_, rightAxis, rightChildren) = children[1].node else {
            XCTFail("the right side stacks the rest")
            return
        }
        XCTAssertEqual(rightAxis, .vertical, "the rest stack as rows on the right")
        XCTAssertEqual(rightChildren.map(\.node), [SplitNode.leaf(ids[0]), .leaf(ids[2])])
        try assertAllFlexOne(activeRoot(after))
    }

    func testMainVerticalN2CollapsesRightToBareLeaf() throws {
        // With exactly 2 leaves, the "rest" is one element → it must be the bare leaf, NOT a 1-child split.
        let (ws, ids) = nLeaves(2)
        let after = WorkspaceTreeOps.applyLayout(.mainVertical, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, children) = try activeRoot(after) else {
            XCTFail("main-vertical (n=2) is a 2-child split")
            return
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].node, .leaf(ids[0]), "active = first = main")
        XCTAssertEqual(children[1].node, .leaf(ids[1]), "the lone remaining leaf is bare, not a 1-child split")
    }

    func testMainHorizontalN3HasActiveTopAndRowBelow() throws {
        let (ws, ids) = nLeaves(3)
        let after = WorkspaceTreeOps.applyLayout(.mainHorizontal, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, children) = try activeRoot(after) else {
            XCTFail("main-horizontal must be a 2-child vertical split")
            return
        }
        XCTAssertEqual(axis, .vertical, "main-horizontal splits top/bottom (rows)")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].node, .leaf(ids[0]), "the active leaf is the large top pane")
        guard case let .split(_, bottomAxis, bottomChildren) = children[1].node else {
            XCTFail("the bottom is a row of the rest")
            return
        }
        XCTAssertEqual(bottomAxis, .horizontal, "the rest sit in a row below")
        XCTAssertEqual(bottomChildren.map(\.node), [SplitNode.leaf(ids[1]), .leaf(ids[2])])
    }

    // MARK: tiled (balanced grid)

    func testTiledN4IsTwoByTwoGrid() throws {
        let (ws, ids) = nLeaves(4)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: ids[0], in: ws)
        // cols = ceil(sqrt 4) = 2, rows = 2 → outer .vertical of 2 rows, each a .horizontal of 2.
        guard case let .split(_, axis, rows) = try activeRoot(after) else { XCTFail("tiled n=4 is a grid")
            return
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(rows.count, 2, "2 rows")
        for (r, row) in rows.enumerated() {
            guard case let .split(_, rowAxis, cells) = row.node else { XCTFail("each row is a split")
                return
            }
            XCTAssertEqual(rowAxis, .horizontal)
            XCTAssertEqual(cells.map(\.node), [SplitNode.leaf(ids[r * 2]), .leaf(ids[r * 2 + 1])])
        }
        try assertAllFlexOne(activeRoot(after))
    }

    func testTiledN2IsASingleRowNotAGrid() throws {
        // cols = ceil(sqrt 2) = 2, rows = 1 → a single row collapses to the bare horizontal split.
        let (ws, ids) = nLeaves(2)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, children) = try activeRoot(after) else { XCTFail("tiled n=2")
            return
        }
        XCTAssertEqual(axis, .horizontal, "a single row is the bare horizontal split, not wrapped in a vertical")
        XCTAssertEqual(children.map(\.node), ids.map { SplitNode.leaf($0) })
    }

    func testTiledN3IsTwoRowsTwoThenOne() throws {
        // cols = ceil(sqrt 3) = 2, rows = ceil(3/2) = 2 → row0 = [0,1], row1 = [2] (bare leaf).
        let (ws, ids) = nLeaves(3)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, rows) = try activeRoot(after) else { XCTFail("tiled n=3")
            return
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(rows.count, 2)
        guard case let .split(_, _, row0) = rows[0].node else { XCTFail("row0 is a 2-cell split")
            return
        }
        XCTAssertEqual(row0.map(\.node), [SplitNode.leaf(ids[0]), .leaf(ids[1])])
        XCTAssertEqual(rows[1].node, .leaf(ids[2]), "the lone last-row cell collapses to a bare leaf")
    }

    func testTiledN5IsThreeWideTwoRows() throws {
        // cols = ceil(sqrt 5) = 3, rows = ceil(5/3) = 2; balanced base=2, extra=1 → row0 = [0,1,2], row1 = [3,4].
        let (ws, ids) = nLeaves(5)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, _, rows) = try activeRoot(after) else { XCTFail("tiled n=5")
            return
        }
        XCTAssertEqual(rows.count, 2)
        guard case let .split(_, _, row0) = rows[0].node, case let .split(_, _, row1) = rows[1].node else {
            XCTFail("both rows are splits")
            return
        }
        XCTAssertEqual(row0.map(\.node), [SplitNode.leaf(ids[0]), .leaf(ids[1]), .leaf(ids[2])])
        XCTAssertEqual(row1.map(\.node), [SplitNode.leaf(ids[3]), .leaf(ids[4])])
    }

    func testTiledN7IsBalancedThreeTwoTwoNotLopsided() throws {
        // cols = ceil(sqrt 7) = 3, rows = ceil(7/3) = 3. The BALANCED tmux fill spreads 7 across 3 rows as
        // base=2, extra=7%3=1 → [3,2,2], NOT the greedy [3,3,1]. The leaf SET is preserved either way; this
        // pins the symmetric distribution. Revert-to-confirm-fail: the greedy packer produces [3,3,1] and
        // fails the row1 == 2 assertion.
        let (ws, ids) = nLeaves(7)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, axis, rows) = try activeRoot(after) else { XCTFail("tiled n=7")
            return
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(rows.count, 3, "7 panes tile into 3 rows")
        // Row widths: [3, 2, 2] — the first (extra) row is wider, the rest are even (no lopsided last row).
        let widths = rows.map { $0.node.allPaneIDs().count }
        XCTAssertEqual(widths, [3, 2, 2], "balanced fill, not greedy [3,3,1]")
        // Row0 is a 3-cell horizontal split; rows 1 & 2 are 2-cell horizontal splits — in DFS order.
        guard case let .split(_, _, row0) = rows[0].node,
              case let .split(_, _, row1) = rows[1].node,
              case let .split(_, _, row2) = rows[2].node
        else {
            XCTFail("each balanced row is a split")
            return
        }
        XCTAssertEqual(row0.map(\.node), [SplitNode.leaf(ids[0]), .leaf(ids[1]), .leaf(ids[2])])
        XCTAssertEqual(row1.map(\.node), [SplitNode.leaf(ids[3]), .leaf(ids[4])])
        XCTAssertEqual(row2.map(\.node), [SplitNode.leaf(ids[5]), .leaf(ids[6])])
    }

    func testTiledN9IsAThreeByThreeGrid() throws {
        // A perfect square: cols = 3 (integer ceil-sqrt: 3*3 == 9, never rounds to 4), rows = 3, all even.
        let (ws, ids) = nLeaves(9)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: ids[0], in: ws)
        guard case let .split(_, _, rows) = try activeRoot(after) else { XCTFail("tiled n=9")
            return
        }
        XCTAssertEqual(rows.count, 3, "9 → a 3×3 grid (ceil-sqrt of a perfect square stays 3)")
        XCTAssertEqual(rows.map { $0.node.allPaneIDs().count }, [3, 3, 3], "every row is 3 wide")
    }

    // MARK: No-op for 0/1 leaf

    func testSingleLeafIsAByteIdenticalNoOpForEveryPresetAndCycle() {
        let (ws, ids) = nLeaves(1)
        for preset in WorkspaceTreeOps.LayoutPreset.allCases {
            let after = WorkspaceTreeOps.applyLayout(preset, activeTabContaining: ids[0], in: ws)
            XCTAssertEqual(after, ws, "a lone-pane tab is unchanged by \(preset)")
        }
        let (cycled, _) = WorkspaceTreeOps.cycleLayout(activeTabContaining: ids[0], from: nil, in: ws)
        XCTAssertEqual(cycled, ws, "cycle is a no-op on a lone pane too")
    }

    func testAbsentPaneIsNoOp() {
        let (ws, _) = nLeaves(3)
        let after = WorkspaceTreeOps.applyLayout(.tiled, activeTabContaining: PaneID(), in: ws)
        XCTAssertEqual(after, ws, "an unknown pane re-tiles nothing")
    }

    // MARK: Floating panes untouched

    func testFloatingPanesAreUntouched() throws {
        // 2 tiled leaves + 1 floating; apply a preset → the tree re-tiles, the float layer is byte-identical.
        let (ws0, ids) = nLeaves(2)
        // Add a third leaf then float it, so the floating layer is non-empty.
        let (ws1, floatLeaf) = WorkspaceTreeOps.splitPane(ids[0], axis: .vertical, newSpec: termSpec("f"), in: ws0)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = WorkspaceTreeOps.defaultFloatingFrame(in: bounds)
        let ws = WorkspaceTreeOps.toggleFloating(floatLeaf, defaultFrame: frame, bounds: bounds, in: ws1)
        let tiledLeaves = try activeTab(ws).root.allPaneIDs()
        XCTAssertTrue(try activeTab(ws).floatingPanes.contains(floatLeaf), "precondition: the leaf is floating")

        let after = WorkspaceTreeOps.applyLayout(.evenVertical, activeTabContaining: tiledLeaves[0], in: ws)
        XCTAssertEqual(
            try activeTab(after).floatingPanes, try activeTab(ws).floatingPanes,
            "the floating layer (ids + order) is untouched by a re-tile",
        )
        XCTAssertEqual(try activeTab(after).floatingPanes, [floatLeaf])
        XCTAssertEqual(
            after.spec(for: floatLeaf)?.floatingFrame,
            ws.spec(for: floatLeaf)?.floatingFrame,
            "the floated pane keeps its frame",
        )
        // The re-tiled tree has exactly the 2 tiled leaves (the float is NOT folded in).
        XCTAssertEqual(try Set(activeRoot(after).allPaneIDs()), Set(tiledLeaves))
        XCTAssertFalse(try activeRoot(after).contains(floatLeaf), "the float never enters the tiled tree")
    }

    // MARK: Zoom is cleared (un-zoom then tile, not no-op-while-zoomed)

    func testApplyLayoutUnZoomsThenRetiles() throws {
        var (ws, ids) = nLeaves(3)
        ws.sessions[0].tabs[0].zoomedPane = ids[1] // zoom a pane
        XCTAssertNotNil(try activeTab(ws).zoomedPane, "precondition: zoomed")
        let after = WorkspaceTreeOps.applyLayout(.evenHorizontal, activeTabContaining: ids[0], in: ws)
        XCTAssertNil(try activeTab(after).zoomedPane, "re-tile exits zoom (tmux select-layout semantics)")
        // And it actually re-tiled (proves un-zoom-THEN-tile, not a no-op while zoomed).
        guard case let .split(_, axis, _) = try activeRoot(after) else { XCTFail("re-tiled")
            return
        }
        XCTAssertEqual(axis, .horizontal)
    }

    // MARK: cycle

    func testCycleSteppingThroughEveryPresetWrapsAround() {
        let (ws, ids) = nLeaves(2)
        let order = WorkspaceTreeOps.LayoutPreset.allCases
        // From nil → first preset, then each subsequent press advances, wrapping after the last.
        var cursor: WorkspaceTreeOps.LayoutPreset?
        var seen: [WorkspaceTreeOps.LayoutPreset] = []
        for _ in 0..<(order.count + 1) {
            let (_, applied) = WorkspaceTreeOps.cycleLayout(activeTabContaining: ids[0], from: cursor, in: ws)
            seen.append(applied)
            cursor = applied
        }
        XCTAssertEqual(Array(seen.prefix(order.count)), order, "cycle visits every preset in allCases order")
        XCTAssertEqual(seen.last, order.first, "after the last preset it wraps to the first")
    }

    func testCyclePreservesLeafSet() throws {
        let (ws, ids) = nLeaves(4)
        let (after, _) = WorkspaceTreeOps.cycleLayout(activeTabContaining: ids[0], from: nil, in: ws)
        XCTAssertEqual(try Set(activeRoot(after).allPaneIDs()), Set(ids), "cycle keeps the leaf set")
    }
}
