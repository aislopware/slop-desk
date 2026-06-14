import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins ``SystemDialogMonitor``'s reconcile diff, focusing on the RESPAWN fix: a dialog pane the user
/// manually closes while the host dialog is still present must come back after a grace window (an
/// off-screen password prompt can't be dismissed into invisibility forever) — but a deliberate close
/// gets that grace window first. Uses an injected clock so the suppression is deterministic.
@MainActor
final class SystemDialogRespawnTests: XCTestCase {
    /// A controllable clock for the suppression window.
    private final class TestClock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        func date() -> Date { now }
        func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    private func makeMonitor(
        _ store: WorkspaceStore,
        clock: TestClock,
        suppression: TimeInterval = 10,
    ) -> SystemDialogMonitor {
        SystemDialogMonitor(
            store: store,
            isConnected: { true },
            target: { .default },
            respawnSuppression: suppression,
            clock: clock.date,
        )
    }

    private func dialog(_ wid: UInt32) -> SystemDialogInfo {
        SystemDialogInfo(windowID: wid, owner: "SecurityAgent", title: "sudo", width: 400, height: 200, isSecure: true)
    }

    private func dialogPaneIDs(_ store: WorkspaceStore) -> [PaneID] {
        store.workspace.canvas.allIDs().filter { store.workspace.canvas.spec(for: $0)?.kind == .systemDialog }
    }

    func testSpawnsAndClosesWithTheHostDialog() {
        let store = makeStore()
        let clock = TestClock()
        let monitor = makeMonitor(store, clock: clock)

        monitor.reconcileForTesting([dialog(1)])
        XCTAssertEqual(dialogPaneIDs(store).count, 1, "a present dialog spawns a pane")

        monitor.reconcileForTesting([]) // dialog gone host-side
        XCTAssertEqual(dialogPaneIDs(store).count, 0, "the pane closes with the dialog")
    }

    func testManualCloseRespawnsAfterSuppressionWindow() throws {
        let store = makeStore()
        let clock = TestClock()
        let monitor = makeMonitor(store, clock: clock, suppression: 10)

        monitor.reconcileForTesting([dialog(1)])
        let firstPane = try XCTUnwrap(dialogPaneIDs(store).first)

        // User manually closes the dialog pane while the host dialog is STILL present.
        store.closePane(firstPane)
        XCTAssertEqual(dialogPaneIDs(store).count, 0)

        // Next poll within the grace window: stays closed (a deliberate close is respected briefly).
        // This poll DETECTS the manual close and starts the grace timer (detection-relative).
        clock.advance(3)
        monitor.reconcileForTesting([dialog(1)])
        XCTAssertEqual(dialogPaneIDs(store).count, 0, "within the grace window the pane stays closed")

        // Poll AFTER the grace window (>10s since detection): the still-present prompt re-spawns.
        clock.advance(12)
        monitor.reconcileForTesting([dialog(1)])
        XCTAssertEqual(dialogPaneIDs(store).count, 1, "a still-present dialog re-spawns after the window")
        XCTAssertNotEqual(dialogPaneIDs(store).first, firstPane, "respawn is a fresh pane")
    }

    func testManualCloseStateResetsWhenDialogLeavesHostSide() throws {
        let store = makeStore()
        let clock = TestClock()
        let monitor = makeMonitor(store, clock: clock, suppression: 10)

        monitor.reconcileForTesting([dialog(1)])
        try store.closePane(XCTUnwrap(dialogPaneIDs(store).first))
        clock.advance(2)
        monitor.reconcileForTesting([dialog(1)]) // still suppressed → no pane
        XCTAssertEqual(dialogPaneIDs(store).count, 0)

        // The dialog leaves host-side, then a NEW dialog with the same windowID appears: it must spawn
        // IMMEDIATELY (the prior manual-close grace was reset when the dialog left).
        monitor.reconcileForTesting([])
        monitor.reconcileForTesting([dialog(1)])
        XCTAssertEqual(dialogPaneIDs(store).count, 1, "a fresh appearance after a host-side close is not suppressed")
    }

    func testNoRespawnWhilePaneIsStillOpen() {
        let store = makeStore()
        let clock = TestClock()
        let monitor = makeMonitor(store, clock: clock)
        monitor.reconcileForTesting([dialog(1)])
        clock.advance(100)
        monitor.reconcileForTesting([dialog(1)]) // pane still open → idempotent
        XCTAssertEqual(dialogPaneIDs(store).count, 1, "an open pane is never duplicated")
    }
}
