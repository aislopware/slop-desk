import SlopDeskTransport
import XCTest
@testable import SlopDeskClient

/// Smoke tests so the target compiles and the basic seams behave. Real connect /
/// reconnect / dedup are exercised by the e2e tests in this target.
final class SlopDeskClientSmokeTests: XCTestCase {
    /// An `SlopDeskClient` whose transport factory is inert (never invoked — these tests never
    /// `connect()`). Mirrors how production injects a `MuxClientTransport` over a shared connection.
    private func makeUnconnectedClient() -> SlopDeskClient {
        SlopDeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw SlopDeskTransportError.notConnected("inert test transport") },
                release: { _, _, _ in },
            )
        })
    }

    func testSlopDeskClientStartsUnconnected() async {
        let client = makeUnconnectedClient()
        let sid = await client.sessionID
        let seq = await client.highestContiguousSeq
        XCTAssertNil(sid)
        XCTAssertEqual(seq, 0)
    }

    /// The WIRING, not the schedule: that a default-constructed manager reads its ladder from
    /// `slopdesk_clientsession::backoff` rather than from a literal in this module. The curve itself
    /// — the doubling, the cap, the closed form's agreement with the chained form — is pinned by
    /// that crate's own tests; asserting it again here would be the second implementation the
    /// one-implementation rule forbids.
    func testReconnectManagerReadsItsBackoffFromTheSessionCrate() {
        let manager = ReconnectManager(client: makeUnconnectedClient())
        XCTAssertEqual(manager.backoff.multiplier, ReconnectManager.Backoff.defaultMultiplier)
        XCTAssertEqual(manager.backoff.initial, ReconnectManager.Backoff.defaultInitial)
        XCTAssertEqual(manager.backoff.maximum, ReconnectManager.Backoff.defaultMaximum)
        // A delay past the cap saturates rather than running away — the one property the pane
        // depends on, read through the door instead of recomputed beside it.
        XCTAssertEqual(manager.backoff.delay(forAttempt: 30), manager.backoff.maximum)
    }
}
