import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``WorkspaceTreeOps/moveTab(from:to:in:)`` — the PURE tab-reorder op (E6 plan WI-3 / Design #4)
/// behind manual drag-to-reorder. It permutes the active session's `tabs` array ONLY (the leaf set
/// is unchanged ⇒ the store wrapper's reconcile is a registry no-op), clamps an out-of-range destination,
/// and keeps `activeTabIndex` pointed at the SAME tab id across the move. Each assertion fails before the
/// op exists (revert-to-confirm-fail = the static is absent → compile failure).
final class MoveTabTests: XCTestCase {
    // MARK: Fixtures

    /// A one-session workspace with `count` single-leaf tabs, the `activeIndex`-th selected. Returns the
    /// workspace + the tab ids in array order.
    private func workspace(tabCount count: Int, activeIndex: Int) -> (TreeWorkspace, [TabID]) {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for i in 0..<count {
            let pane = PaneID()
            tabs.append(Tab(root: .leaf(pane), activePane: pane))
            specs[pane] = PaneSpec(kind: .terminal, title: "T\(i)")
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: activeIndex, specs: specs)
        return (TreeWorkspace(sessions: [session], activeSessionID: session.id), tabs.map(\.id))
    }

    private func tabIDs(_ ws: TreeWorkspace) -> [TabID] {
        ws.activeSession?.tabs.map(\.id) ?? []
    }

    private func activeTabID(_ ws: TreeWorkspace) -> TabID? {
        ws.activeSession?.activeTab?.id
    }

    // MARK: - Permutation

    func testMoveFromFrontToBackPermutesOrder() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[2], ids[0]], "moving index 0 to 2 rotates it to the end")
    }

    func testMoveFromBackToFrontPermutesOrder() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 2, to: 0, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[2], ids[0], ids[1]])
    }

    // MARK: - Selection follows the same tab id

    func testActiveSelectionFollowsTheSameTabIDAcrossTheMove() {
        // The MIDDLE tab is active; moving the FIRST tab past it must keep the middle tab selected.
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 1)
        XCTAssertEqual(activeTabID(ws), ids[1])
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        // New order: [ids1, ids2, ids0]; ids1 is now at index 0.
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[2], ids[0]])
        XCTAssertEqual(activeTabID(moved), ids[1], "the previously-active tab id stays selected")
        XCTAssertEqual(moved.activeSession?.activeTabIndex, 0, "and activeTabIndex re-points at its new slot")
    }

    func testMovingTheActiveTabKeepsItActive() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        XCTAssertEqual(activeTabID(moved), ids[0], "the moved-and-active tab stays selected at its new index")
        XCTAssertEqual(moved.activeSession?.activeTabIndex, 2)
    }

    // MARK: - Clamping / no-ops

    func testOutOfRangeDestinationClampsToLastIndex() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 99, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[2], ids[0]], "an OOB destination clamps to the last slot")
    }

    func testNegativeDestinationClampsToFront() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 2, to: -5, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[2], ids[0], ids[1]], "a negative destination clamps to index 0")
    }

    func testOutOfRangeSourceIsANoOp() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 99, to: 0, in: ws)
        XCTAssertEqual(moved, ws, "an out-of-range source returns the workspace unchanged")
        XCTAssertEqual(tabIDs(moved), ids)
    }

    func testMoveToSameIndexIsANoOp() {
        let (ws, _) = workspace(tabCount: 3, activeIndex: 1)
        let moved = WorkspaceTreeOps.moveTab(from: 1, to: 1, in: ws)
        XCTAssertEqual(moved, ws, "a move to the same index is a no-op")
    }

    func testSingleTabSessionIsANoOp() {
        let (ws, _) = workspace(tabCount: 1, activeIndex: 0)
        let moved = WorkspaceTreeOps.moveTab(from: 0, to: 0, in: ws)
        XCTAssertEqual(moved, ws, "a single-tab session cannot reorder")
    }

    // MARK: - Leaf set unchanged (reconcile no-op)

    func testLeafSetIsUnchangedByTheMove() {
        let (ws, _) = workspace(tabCount: 4, activeIndex: 0)
        let before = Set(ws.allPaneIDs())
        let moved = WorkspaceTreeOps.moveTab(from: 3, to: 0, in: ws)
        XCTAssertEqual(Set(moved.allPaneIDs()), before, "moveTab adds/removes no leaf (reconcile stays a no-op)")
        XCTAssertTrue(moved.isInvariantHeld(), "the specs == leafIDs invariant survives the permutation")
    }

    // MARK: - WYSIWYG rendered-order move (rendered order ≠ array order, e.g. Sort = Updated)

    /// The fix's core: when the RENDERED order differs from the `session.tabs` array order (as it does under
    /// ``TabSort/updated``), a drag must move ONLY the dragged row relative to what the user SEES — not
    /// reshuffle the whole list back to array order. ``WorkspaceTreeOps/moveTab(renderedOrder:from:to:in:)``
    /// materializes the rendered order then moves by RENDERED position. This FAILS on the old absolute-index
    /// path (`moveTab(from:to:)` on the raw array would produce the array reshuffle, not this).
    func testRenderedOrderMoveIsWYSIWYGNotArrayReshuffle() {
        // Array order: [t0, t1, t2, t3]. Rendered (e.g. recency) order is a DIFFERENT permutation.
        let (ws, ids) = workspace(tabCount: 4, activeIndex: 0)
        let rendered = [ids[3], ids[1], ids[0], ids[2]] // what the user sees, ≠ array order
        // Drag the row at rendered position 0 (t3) to rendered position 2.
        let moved = WorkspaceTreeOps.moveTab(renderedOrder: rendered, from: 0, to: 2, in: ws)
        // Expected: the RENDERED list with ONLY t3 moved to slot 2 → [t1, t0, t3, t2].
        XCTAssertEqual(
            tabIDs(moved), [ids[1], ids[0], ids[3], ids[2]],
            "only the dragged row moves, relative to the rendered order the user sees",
        )
        // It must NOT be the raw-array reshuffle that the old absolute-index path produced.
        let arrayReshuffle = WorkspaceTreeOps.moveTab(from: 0, to: 2, in: ws)
        XCTAssertNotEqual(
            tabIDs(moved), tabIDs(arrayReshuffle),
            "the WYSIWYG move differs from the absolute-array-index move (the bug)",
        )
    }

    func testRenderedOrderMoveBackToFront() {
        let (ws, ids) = workspace(tabCount: 4, activeIndex: 0)
        let rendered = [ids[3], ids[1], ids[0], ids[2]]
        // Drag rendered position 3 (t2) to the front (rendered position 0).
        let moved = WorkspaceTreeOps.moveTab(renderedOrder: rendered, from: 3, to: 0, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[2], ids[3], ids[1], ids[0]])
    }

    func testRenderedOrderMoveKeepsActiveSelectionByID() {
        // The middle-of-RENDERED tab is active; moving another tab must keep it selected.
        let (ws, ids) = workspace(tabCount: 4, activeIndex: 1) // active = t1 (rendered position 1)
        XCTAssertEqual(activeTabID(ws), ids[1])
        let rendered = [ids[3], ids[1], ids[0], ids[2]]
        let moved = WorkspaceTreeOps.moveTab(renderedOrder: rendered, from: 0, to: 2, in: ws)
        XCTAssertEqual(tabIDs(moved), [ids[1], ids[0], ids[3], ids[2]])
        XCTAssertEqual(activeTabID(moved), ids[1], "the previously-active tab id stays selected across the move")
    }

    func testRenderedOrderMoveToSamePositionIsANoOp() {
        let (ws, ids) = workspace(tabCount: 4, activeIndex: 0)
        let rendered = [ids[3], ids[1], ids[0], ids[2]]
        let moved = WorkspaceTreeOps.moveTab(renderedOrder: rendered, from: 1, to: 1, in: ws)
        XCTAssertEqual(moved, ws, "a move to its own rendered slot leaves the workspace (and array) untouched")
        XCTAssertEqual(tabIDs(moved), ids, "the array is NOT materialized for a null drag")
    }

    func testRenderedOrderThatIsNotAPermutationIsDropped() {
        let (ws, ids) = workspace(tabCount: 3, activeIndex: 0)
        // A stale/foreign order (wrong length, or a ghost id) must be dropped — never reorder on bad input.
        let wrongLength = WorkspaceTreeOps.moveTab(renderedOrder: [ids[0], ids[1]], from: 0, to: 1, in: ws)
        XCTAssertEqual(wrongLength, ws, "a rendered order that isn't an exact permutation is a no-op")
        let ghost = WorkspaceTreeOps.moveTab(
            renderedOrder: [ids[0], ids[1], TabID()], from: 0, to: 2, in: ws,
        )
        XCTAssertEqual(ghost, ws, "a rendered order with a foreign tab id is dropped")
    }
}
