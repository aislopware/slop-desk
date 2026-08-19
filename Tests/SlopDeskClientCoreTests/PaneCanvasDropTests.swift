// PaneCanvasDropTests — the IN-TAB half of a pane drop: what a cursor is over, and what a release
// there does.
//
// `PaneDropGeometryTests` already pins the rect math underneath. What this suite adds is the two
// things the compositor was deciding on top of it inside a `some View`:
//   • PRECEDENCE — container gutter first, then a target leaf's centre box versus its edge bands.
//     Getting the order wrong is not a subtle bug: a gutter that loses to the edge band means the
//     outermost pane can never be docked, because its own edge band covers the gutter.
//   • THE COMMIT FORK — three different store verbs picked by four cases, where `.none` is a cancel
//     that must commit NOTHING. A `.none` that fell through to a `swap` would move a pane on a
//     release the user aimed at empty space.

import CoreGraphics
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore

@MainActor
final class PaneCanvasDropZoneTests: XCTestCase {
    private let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let source = PaneID()
    private let target = PaneID()

    /// The source occupies the TOP half (full width), the target the bottom half — so the source
    /// already fully SPANS the container's top edge, which is the case the no-op-dock rule is about.
    private var leaves: [SplitTreeRenderModel.PlacedLeaf] {
        [
            SplitTreeRenderModel.PlacedLeaf(id: source, rect: CGRect(x: 0, y: 0, width: 1000, height: 300)),
            SplitTreeRenderModel.PlacedLeaf(id: target, rect: CGRect(x: 0, y: 300, width: 1000, height: 300)),
        ]
    }

    private func zone(at point: CGPoint) -> PaneDropZone {
        PaneCanvasDrop.zone(
            at: point, leaves: leaves, container: container,
            source: source, sourceRect: leaves[0].rect,
        )
    }

    /// PRECEDENCE, first clause: the container's outer gutter wins over whatever leaf happens to be
    /// under it. Without this the edge-most pane is undockable — its own edge band covers the gutter.
    func testTheContainerGutterOutranksTheLeafUnderIt() {
        XCTAssertEqual(zone(at: CGPoint(x: 500, y: 597)), .dock(edge: .bottom))
    }

    /// …and the gutter on an edge the source ALREADY fully spans is suppressed: docking there is a
    /// visual no-op, and previewing one the instant a top pane is grabbed is pure noise.
    func testAnEdgeTheSourceAlreadySpansIsNotOfferedAsADock() {
        XCTAssertEqual(
            zone(at: CGPoint(x: 500, y: 3)), .none,
            "the source already spans the top edge, and it is over its own pane — nothing to commit",
        )
    }

    /// PRECEDENCE, second clause: inside a non-source leaf, the generous CENTRE box swaps and the
    /// bands around it re-split, on whichever edge the cursor has penetrated deepest.
    func testTheTargetsCentreSwapsAndItsBandsResplit() {
        XCTAssertEqual(zone(at: CGPoint(x: 500, y: 450)), .swap(target: target))
        XCTAssertEqual(zone(at: CGPoint(x: 100, y: 450)), .resplit(target: target, edge: .left))
        XCTAssertEqual(zone(at: CGPoint(x: 900, y: 450)), .resplit(target: target, edge: .right))
        XCTAssertEqual(zone(at: CGPoint(x: 500, y: 330)), .resplit(target: target, edge: .top))
        XCTAssertEqual(zone(at: CGPoint(x: 500, y: 570)), .resplit(target: target, edge: .bottom))
    }

    /// The source's OWN pane is not a target — releasing on yourself is a cancel, not a self-swap.
    func testTheSourcesOwnPaneIsACancel() {
        XCTAssertEqual(zone(at: CGPoint(x: 500, y: 150)), .none)
    }

    /// Empty space is a cancel too. Every resolution that cannot name a real target says `.none`
    /// rather than guessing at the nearest one.
    func testEmptySpaceIsACancel() {
        let sparse = [leaves[0]]
        XCTAssertEqual(
            PaneCanvasDrop.zone(
                at: CGPoint(x: 500, y: 450), leaves: sparse, container: container,
                source: source, sourceRect: sparse[0].rect,
            ),
            .none,
        )
    }
}

@MainActor
final class PaneCanvasDropCommitTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func panes(_ store: WorkspaceStore) throws -> [PaneID] {
        try XCTUnwrap(store.tree.activeSession?.activeTab).allPaneIDs()
    }

    /// A swap exchanges the two panes' POSITIONS while both keep their `PaneID` — the whole point of
    /// every path here, since a torn-down surface would drop the live PTY.
    func testASwapExchangesThePositionsAndKeepsBothPanes() throws {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false)
        let before = try panes(store)
        XCTAssertEqual(before.count, 2, "fixture needs two panes")

        PaneCanvasDrop.commit(.swap(target: before[1]), pane: before[0], in: store)

        XCTAssertEqual(try panes(store), [before[1], before[0]])
    }

    /// `.none` IS A CANCEL: a release over empty space, or over the source itself, leaves the tab
    /// exactly as it was.
    func testTheCancelCommitsNothing() throws {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false)
        let before = try panes(store)

        PaneCanvasDrop.commit(.none, pane: before[0], in: store)

        XCTAssertEqual(try panes(store), before)
    }

    /// A dock on the tab's own root edge re-parents the pane to that edge, keeping every id — the
    /// in-tab twin of the cross-tab op ``PaneDragCommit`` owns.
    func testADockMovesThePaneToTheRootEdge() throws {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false)
        let before = try panes(store)

        PaneCanvasDrop.commit(.dock(edge: .left), pane: before[1], in: store)

        let after = try panes(store)
        XCTAssertEqual(Set(after), Set(before), "a dock moves a pane; it never mints or drops one")
        XCTAssertEqual(after.first, before[1], "the docked pane is now the tab's leading child")
    }
}
