import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// Regression for the report that switching tabs lost the entire scrollback history. A pane's SwiftUI `.task(id:)` re-fires
/// on every REMOUNT — including a mere pane remount when the user switches TABS — so calling
/// `connect()` unconditionally would tear down a healthy channel and wipe the terminal replay ring, leaving the
/// pane blank. `ConnectionViewModel.connectIfNeeded()` is the idempotent guard: it dials only a
/// genuinely idle/dead channel and NO-OPS on a live/in-flight/supervised one, leaving the ring intact.
@MainActor
final class ConnectionViewModelConnectIfNeededTests: XCTestCase {
    /// Once CONNECTED, a `connectIfNeeded()` (the tab-switch remount path) must NOT re-dial (no new
    /// driver) and must NOT wipe the terminal replay ring — the prior screen has to survive the remount.
    func testConnectIfNeededNoOpsWhenAlreadyConnected() async {
        let rec = PaneDriverRecorder()
        let terminal = TerminalViewModel()
        let vm = ConnectionViewModel(
            terminal: terminal,
            target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(driver: rec.make()) },
        )

        await vm.connect()
        XCTAssertEqual(vm.status, .connected)
        XCTAssertEqual(rec.count, 1, "the initial connect builds exactly one driver")

        // Accumulate some scrollback into the replay ring — this is the "history" the tab switch must keep.
        terminal.ingestOutput(Data("prior screen contents\n".utf8))
        let ringBefore = terminal.ringByteCount
        XCTAssertGreaterThan(ringBefore, 0)

        await vm.connectIfNeeded() // a tab switch remounts the pane and re-fires the `.task`

        XCTAssertEqual(vm.status, .connected, "a remount must not disturb a live channel")
        XCTAssertEqual(rec.count, 1, "connectIfNeeded must NOT re-dial when already connected")
        XCTAssertEqual(terminal.ringByteCount, ringBefore, "the replay ring (history) must survive the remount")
    }

    /// A genuinely idle channel (`.disconnected`) still dials on `connectIfNeeded()` — the initial mount
    /// path must keep working; only an ALREADY-live channel is skipped.
    func testConnectIfNeededDialsWhenDisconnected() async {
        let rec = PaneDriverRecorder()
        let vm = ConnectionViewModel(
            terminal: TerminalViewModel(),
            target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(driver: rec.make()) },
        )
        XCTAssertEqual(vm.status, .disconnected)

        await vm.connectIfNeeded()

        XCTAssertEqual(vm.status, .connected, "an idle channel must dial on connectIfNeeded")
        XCTAssertEqual(rec.count, 1)
    }
}
