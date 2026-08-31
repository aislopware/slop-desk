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

    /// Waits for an ARRIVAL rather than settling a fixed number of yields. How many yields the dial
    /// tasks need to get scheduled is a property of the machine's load, not of the redial under test,
    /// so a yield count reads as a regression beside a parallel build when it is only contention.
    /// Same shape as `EvictedSubscriberRedialTests`' — a deadline, and a named failure when it passes.
    private func expect(
        _ what: String,
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

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
        // The wait has to be for the CONNECT and not for the dial. `rec.count` rises when the driver
        // is handed the channel; the status becomes `.connected` a continuation later, so waiting on
        // the count alone leaves a window in which a loaded machine reports `.connecting` — which is
        // the redial having worked, reported as the regression this test exists to catch.
        await expect("both channels to connect") {
            rec.count == 2
                && liveLeft.connection?.status == .connected
                && liveRight.connection?.status == .connected
        }

        XCTAssertEqual(rec.count, 2, "both the tiled AND the detached pane's channels were dialed")
        XCTAssertEqual(liveLeft.connection?.status, .connected)
        XCTAssertEqual(liveRight.connection?.status, .connected, "the satellite's channel is no longer dead")
    }
}
