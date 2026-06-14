#if canImport(Network)
import XCTest
@testable import AislopdeskVideoClient

/// BUG-L regression (client side): the UDP receive loop must survive a transient
/// per-datagram error and keep itself armed, stopping ONLY when the connection is dead.
///
/// The old loop re-armed `if error == nil`, so a single recoverable per-datagram error
/// (e.g. ICMP port-unreachable surfaced as ECONNREFUSED while the `NWConnection` stays
/// `.ready`) ended the loop forever and the client silently stopped receiving all video.
/// The re-arm decision is now purely "is the connection still alive?" (driven by the
/// connection's `stateUpdateHandler`, not the per-receive error), which is unit-testable
/// without a socket. The live socket teardown still needs the hardware video pass.
final class UDPReceiveLoopPolicyTests: XCTestCase {
    func testRearmsWhileConnectionAlive() {
        // A transient receive error with the connection still alive → keep receiving.
        XCTAssertTrue(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: true))
    }

    func testStopsWhenConnectionDead() {
        // The state handler marked the connection dead (.failed/.cancelled) → stop the
        // loop; do NOT spin on a genuinely dead socket.
        XCTAssertFalse(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: false))
    }

    // MARK: F3 — consecutive-error backoff (no busy-loop)

    /// No error → immediate re-arm. The normal hot path (a good datagram resets the
    /// consecutive-error count to 0) must never be delayed.
    func testNoBackoffWithoutError() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 0), 0)
    }

    /// The first error re-arms after the 5 ms base delay, then doubles per consecutive
    /// error: 5 → 10 → 20 → 40 → 80 ms. Without this a sustained ECONNREFUSED storm
    /// re-armed with zero delay → 100% CPU busy-loop (F3).
    func testBackoffGrowsExponentiallyFromBase() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 1), 0.005, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 2), 0.010, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 3), 0.020, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 4), 0.040, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 5), 0.080, accuracy: 1e-9)
    }

    /// The delay is capped (~250 ms) so a long error storm settles at the cap instead of
    /// growing unbounded — and a very large count cannot overflow the shift.
    func testBackoffIsCapped() {
        XCTAssertEqual(
            UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 7),
            0.250,
            accuracy: 1e-9,
        ) // 5·2^6 = 320ms → cap
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 100), 0.250, accuracy: 1e-9) // no overflow
        XCTAssertEqual(
            UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 6),
            0.160,
            accuracy: 1e-9,
        ) // last value below the cap
    }

    /// The reset-to-0 path is what restores the hot path: after errors, the first good
    /// datagram passes `consecutiveErrors: 0` → immediate re-arm again.
    func testBackoffResetsToImmediateAfterSuccess() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 5), 0.080, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 0), 0) // good datagram resets
    }
}
#endif
