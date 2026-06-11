#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// BUG-L regression (host side): the host's UDP receive loop must survive a transient
/// per-datagram error and keep itself armed, stopping ONLY when the flow is dead.
///
/// The old loop re-armed `if error == nil`, so a single recoverable per-datagram error
/// (e.g. ICMP port-unreachable surfaced as ECONNREFUSED while the flow stays `.ready`)
/// ended the loop forever and the host silently stopped receiving the client's input /
/// recovery requests. The re-arm decision is now purely "is the flow still alive?"
/// (driven by the connection's state handler, not the per-receive error). The live
/// socket teardown still needs the hardware video pass.
final class UDPReceiveLoopPolicyTests: XCTestCase {
    func testRearmsWhileFlowAlive() {
        XCTAssertTrue(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: true))
    }

    func testStopsWhenFlowDead() {
        XCTAssertFalse(UDPReceiveLoopPolicy.shouldRearm(connectionIsAlive: false))
    }

    // MARK: F3 — consecutive-error backoff (no busy-loop), identical to the client policy.

    func testNoBackoffWithoutError() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 0), 0)
    }

    /// 5 → 10 → 20 → 40 → 80 ms: the base-5 ms delay doubles per consecutive error.
    /// Without it a sustained ECONNREFUSED storm re-armed with zero delay → busy-loop (F3).
    func testBackoffGrowsExponentiallyFromBase() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 1), 0.005, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 2), 0.010, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 3), 0.020, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 4), 0.040, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 5), 0.080, accuracy: 1e-9)
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 6), 0.160, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 7), 0.250, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 100), 0.250, accuracy: 1e-9)
    }

    func testBackoffResetsToImmediateAfterSuccess() {
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 5), 0.080, accuracy: 1e-9)
        XCTAssertEqual(UDPReceiveLoopPolicy.nextBackoff(consecutiveErrors: 0), 0)
    }
}
#endif
