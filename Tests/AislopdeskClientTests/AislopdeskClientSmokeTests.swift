import AislopdeskProtocol
import AislopdeskTransport
import XCTest
@testable import AislopdeskClient

/// Smoke tests so the target compiles and the basic seams behave. Real connect /
/// reconnect / dedup are exercised by the e2e tests in this target.
final class AislopdeskClientSmokeTests: XCTestCase {
    /// An `AislopdeskClient` whose transport factory is inert (never invoked — these tests never
    /// `connect()`). Mirrors how production injects a `MuxClientTransport` over a shared connection.
    private func makeUnconnectedClient() -> AislopdeskClient {
        AislopdeskClient(makeTransport: {
            MuxClientTransport(
                acquire: { _, _, _, _ in throw AislopdeskTransportError.notConnected("inert test transport") },
                release: { _, _, _ in },
            )
        })
    }

    func testAislopdeskClientStartsUnconnected() async {
        let client = makeUnconnectedClient()
        let sid = await client.sessionID
        let seq = await client.highestContiguousSeq
        XCTAssertNil(sid)
        XCTAssertEqual(seq, 0)
    }

    func testReconnectManagerDefaultBackoffCappedAtTwoSeconds() {
        let manager = ReconnectManager(client: makeUnconnectedClient())
        XCTAssertEqual(manager.backoff.multiplier, 2.0)
        XCTAssertEqual(manager.backoff.maximum, .seconds(2))
    }

    func testBackoffNextCapsAtMaximum() {
        let backoff = ReconnectManager.Backoff(initial: .milliseconds(250), maximum: .seconds(2), multiplier: 2.0)
        var d = backoff.initial
        XCTAssertEqual(d, .milliseconds(250))
        d = backoff.next(after: d) // 500ms
        XCTAssertEqual(d, .milliseconds(500))
        d = backoff.next(after: d) // 1s
        XCTAssertEqual(d, .seconds(1))
        d = backoff.next(after: d) // 2s (cap)
        XCTAssertEqual(d, .seconds(2))
        d = backoff.next(after: d) // stays 2s
        XCTAssertEqual(d, .seconds(2))
    }

    /// The PURE retries→delay schedule (capped exponential backoff). Deterministic, no clock, no
    /// client — a HostServer-free unit test of the reconnect backoff curve. Asserts the closed-form
    /// `delay(forAttempt:)` produces the EXACT same capped sequence as chaining `next(after:)`, and
    /// that it saturates (never exceeds) the maximum no matter how large the attempt count grows
    /// (proving the auto-reconnect delay is bounded — it cannot run away).
    func testBackoffDelayForAttemptIsCappedExponential() {
        let backoff = ReconnectManager.Backoff(initial: .milliseconds(250), maximum: .seconds(2), multiplier: 2.0)
        // 1-indexed: attempt 1 waits `initial`, doubling each attempt until it saturates at `maximum`.
        XCTAssertEqual(backoff.delay(forAttempt: 1), .milliseconds(250))
        XCTAssertEqual(backoff.delay(forAttempt: 2), .milliseconds(500))
        XCTAssertEqual(backoff.delay(forAttempt: 3), .seconds(1))
        XCTAssertEqual(backoff.delay(forAttempt: 4), .seconds(2)) // reaches the cap
        XCTAssertEqual(backoff.delay(forAttempt: 5), .seconds(2)) // stays capped
        XCTAssertEqual(backoff.delay(forAttempt: 30), .seconds(2)) // far past the cap — still bounded
        // A non-positive / first attempt is exactly `initial` (defensive lower bound).
        XCTAssertEqual(backoff.delay(forAttempt: 0), .milliseconds(250))
        // Equivalence with the chained `next(after:)` form (same schedule, different encoding).
        var chained = backoff.initial
        for attempt in 1...8 {
            XCTAssertEqual(backoff.delay(forAttempt: attempt), chained, "attempt \(attempt) closed-form == chained")
            chained = backoff.next(after: chained)
        }
    }
}
