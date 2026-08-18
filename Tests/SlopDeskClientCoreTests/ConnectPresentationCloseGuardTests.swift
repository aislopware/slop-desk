// ConnectPresentationCloseGuardTests — pins `ConnectPresentation.shouldCloseAfterConnect(status:)`, the
// decision that used to be missing entirely: the form closed unconditionally once `connect()` returned, so
// a failed connect (bad host/port, refused connection) vanished the card with the failure reason reachable
// only via the status-pill tooltip. Only `.failed` must keep it open.
//
// Pinned HERE rather than against either form: the Mac draws the form in AppKit and the phone in SwiftUI
// (docs/56 stage D), and this is the one rule they share, so it is the one thing there is to pin.

import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class ConnectPresentationCloseGuardTests: XCTestCase {
    func testFailedConnectKeepsTheFormOpen() {
        XCTAssertFalse(ConnectPresentation.shouldCloseAfterConnect(status: .failed("connection refused")))
    }

    func testConnectedClosesTheForm() {
        XCTAssertTrue(ConnectPresentation.shouldCloseAfterConnect(status: .connected))
    }

    func testEveryNonFailedTerminalStatusClosesTheForm() {
        XCTAssertTrue(ConnectPresentation.shouldCloseAfterConnect(status: .disconnected))
        XCTAssertTrue(ConnectPresentation.shouldCloseAfterConnect(status: .unreachable))
        XCTAssertTrue(
            ConnectPresentation.shouldCloseAfterConnect(status: .reconnecting(attempt: 1, nextRetry: nil)),
        )
    }
}
