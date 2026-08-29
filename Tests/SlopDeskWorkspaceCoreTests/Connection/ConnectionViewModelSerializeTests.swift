import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// Regression for R-lifecycle #4: two overlapping `ConnectionViewModel.connect()` calls (a double / key-repeated
/// "Reconnect Pane") must be SERIALIZED, never interleaved. Before the single-flight chain, the second call's
/// teardown cancel-prefix ran before the first call built its client/observe/output tasks, so both handshakes
/// ran CONCURRENTLY and the first attempt's client survived as a supervised zombie painting into the pane.
/// With the fix the second attempt does not begin until the first fully completes, so at most ONE handshake is
/// in-flight at a time.
@MainActor
final class ConnectionViewModelSerializeTests: XCTestCase {
    func testConcurrentConnectsRunOneHandshakeAtATime() async {
        let rec = PaneDriverRecorder(gated: true)
        let vm = ConnectionViewModel(
            terminal: TerminalViewModel(), target: { ConnectionTarget(host: "h", port: 1) },
            makeClient: { SlopDeskClient(driver: rec.make()) },
        )

        // Fire TWO connect() calls back-to-back (the double-Reconnect scenario).
        let t1 = Task { await vm.connect() }
        let t2 = Task { await vm.connect() }

        // The first attempt parks in its handshake gate.
        await rec.waitForStartedDials(1)
        // Give the SECOND attempt ample room to (incorrectly, on the un-serialized code) start its own
        // concurrent handshake. Serialized, it is still blocked awaiting the first attempt → no 2nd dial.
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(
            rec.startedDials, 1,
            "serialized connect() must not run a second handshake while the first is still in flight",
        )

        // Release the first: it completes, THEN the second attempt begins (tearing the first's client down).
        rec.releaseAll()
        await rec.waitForStartedDials(2)
        rec.releaseAll()
        await t1.value
        await t2.value
    }
}
