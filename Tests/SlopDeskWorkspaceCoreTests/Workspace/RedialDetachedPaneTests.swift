import Foundation
import SlopDeskClient
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Regression: ``WorkspaceStore/redialDisconnectedPanes()`` used to walk only `tree.allPaneIDs()`,
/// so a pane detached into its own satellite window (docs/DECISIONS.md — detach ↔ reattach) never got
/// its channel redialed when the app-global connection (re)established, leaving it a dead, blank
/// terminal (the ``WorkspaceStore/reconcileTree()`` desired set is the union with
/// `tree.detachedPaneIDs()`; this helper must match).
@MainActor
final class RedialDetachedPaneTests: XCTestCase {
    /// A two-terminal-pane (`left` || `right`) tree store whose `makeSession` mints REAL
    /// `LivePaneSession`s backed by `rec`'s in-memory driver — the seam
    /// ``WorkspaceStore/redialDisconnectedPanes()`` actually acts on (it casts to `LivePaneSession`; the
    /// `FakePaneSession` seam used elsewhere would no-op it). Two panes so detaching `right` leaves
    /// `left` as the tree's sole leaf WITHOUT tripping the sole-pane reseed (docs/DECISIONS.md).
    private func makeStore(_ rec: PaneDriverRecorder) -> (WorkspaceStore, left: PaneID, right: PaneID) {
        let base = TreeWorkspace.singlePane(spec: PaneSpec(kind: .terminal, title: "left"))
        let left = base.allPaneIDs()[0]
        let (ws, right) = TreeIntent.splitPane(
            left, axis: .horizontal, newSpec: PaneSpec(kind: .terminal, title: "right"), in: base,
        )
        let store = WorkspaceStore(
            restoringTree: ws,
            makeSession: { seed in
                LivePaneSession.make(
                    paneID: seed.id, spec: seed.spec, spawnCwd: seed.spawnCwd,
                    makeClient: { _ in SlopDeskClient(driver: rec.make()) },
                    makeInspector: { _ in nil },
                    target: { .default },
                )
            },
        )
        store.attachLoopbackWorkspaceDocument()
        return (store, left, right)
    }

    private func megaYield() async { for _ in 0..<50 { await Task.yield() } }

    func testRedialReachesDetachedPane() async throws {
        let rec = PaneDriverRecorder()
        let (store, left, right) = makeStore(rec)
        store.detachPaneToWindow(right)
        XCTAssertTrue(store.tree.isDetached(right), "precondition: the pane left the tree into a satellite")
        XCTAssertTrue(store.tree.contains(left), "precondition: the sibling stayed tiled, no sole-pane reseed")

        let liveLeft = try XCTUnwrap(store.handle(for: left) as? LivePaneSession)
        let liveRight = try XCTUnwrap(store.handle(for: right) as? LivePaneSession)
        XCTAssertEqual(liveRight.connection?.status, .disconnected, "lazy-connect: nothing has dialed yet")

        store.redialDisconnectedPanes()
        await megaYield()

        XCTAssertEqual(rec.count, 2, "both the tiled AND the detached pane's channels were dialed")
        XCTAssertEqual(liveLeft.connection?.status, .connected)
        XCTAssertEqual(liveRight.connection?.status, .connected, "the satellite's channel is no longer dead")
    }
}
