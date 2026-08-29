import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// Regression: `ConnectionViewModel.connect()`/`resume()` must NOT whitewash a torn-down or
/// superseded pane to `.connected`. Because `SlopDeskClient.connect` RETURNS (not throws) when it was
/// closed/paused/superseded mid-handshake (the zombie-transport fix), the VM's `do` success branch
/// would otherwise set `status = .connected` (+ overwrite `sessionID`) for a pane the user already
/// disconnected. The fix: a `connectGeneration` + `self.client === client` identity guard before the
/// post-await writes. Looped to shake the interleaving.
@MainActor
final class ConnectionViewModelSupersedeTests: XCTestCase {
    /// A `disconnect()` landing while `connect()` is suspended in the handshake must leave the pane
    /// `.disconnected`, never `.connected`.
    func testDisconnectDuringInflightConnectStaysDisconnected() async {
        for _ in 0..<120 {
            let rec = PaneDriverRecorder(gated: true)
            let vm = ConnectionViewModel(
                terminal: TerminalViewModel(), target: { ConnectionTarget(host: "h", port: 1) },
                makeClient: { SlopDeskClient(driver: rec.make()) },
            )
            let connectTask = Task { await vm.connect() }
            await rec.waitForStartedDials(1) // connect() is parked in the handshake gate
            await vm.disconnect() // the user closes the pane mid-handshake
            rec.releaseAll() // let the handshake complete + connect() resume
            await connectTask.value

            XCTAssertEqual(
                vm.status,
                .disconnected,
                "a disconnect during the in-flight connect must NOT be whitewashed to .connected",
            )
        }
    }

    /// A LATE `.reconnected` event — drained from the broadcaster buffer AFTER a deliberate
    /// `disconnect()` (a buffered AsyncStream element is delivered even post-cancel/finish) — must NOT
    /// whitewash the closed pane back to green `.connected`. Folded synchronously via the DEBUG hook.
    func testLateReconnectedAfterDisconnectStaysDisconnected() async {
        let vm = ConnectionViewModel(
            terminal: TerminalViewModel(), target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(driver: FakePaneDriver.inert("never connected in this test")) },
        )
        await vm.disconnect() // deliberatelyClosed = true; status = .disconnected (never connected)
        XCTAssertEqual(vm.status, .disconnected)

        vm.foldEventForTesting(.reconnected(sessionID: UUID(), resumeFromSeq: 0))
        XCTAssertEqual(
            vm.status,
            .disconnected,
            "a late .reconnected after a deliberate disconnect must not flip the pane to .connected",
        )
    }
}
