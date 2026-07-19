// ConnectHostViewCloseGuardTests — pins `ConnectHostView.shouldCloseAfterConnect(status:)`, the decision
// that used to be missing entirely: `connectAndClose()` closed the sheet unconditionally once `connect()`
// returned, so a failed connect (bad host/port, refused connection) vanished the sheet with the failure
// reason reachable only via the status-pill tooltip. Only `.failed` must now keep the sheet open.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class ConnectHostViewCloseGuardTests: XCTestCase {
    func testFailedConnectKeepsSheetOpen() {
        XCTAssertFalse(ConnectHostView.shouldCloseAfterConnect(status: .failed("connection refused")))
    }

    func testConnectedClosesTheSheet() {
        XCTAssertTrue(ConnectHostView.shouldCloseAfterConnect(status: .connected))
    }

    func testEveryNonFailedTerminalStatusClosesTheSheet() {
        XCTAssertTrue(ConnectHostView.shouldCloseAfterConnect(status: .disconnected))
        XCTAssertTrue(ConnectHostView.shouldCloseAfterConnect(status: .unreachable))
        XCTAssertTrue(ConnectHostView.shouldCloseAfterConnect(status: .reconnecting(attempt: 1, nextRetry: nil)))
    }
}
