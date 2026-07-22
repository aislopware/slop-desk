import XCTest
@testable import SlopDeskVideoHost

/// ``HostDisplayWake`` refcount logic against fake raise/drop seams — no real power assertion is
/// ever created in a test run.
final class HostDisplayWakeTests: XCTestCase {
    private var raised = 0
    private var dropped: [UInt32] = []
    private var raiseResult: UInt32? = 7

    private func makeWake() -> HostDisplayWake {
        HostDisplayWake(
            raise: { [self] in
                raised += 1
                return raiseResult
            },
            drop: { [self] in dropped.append($0) },
        )
    }

    func testFirstAcquireRaisesOnce() {
        let wake = makeWake()
        wake.acquire()
        wake.acquire()
        wake.acquire()
        XCTAssertEqual(raised, 1, "one assertion covers every concurrent display session")
        XCTAssertTrue(wake.isHolding)
    }

    func testLastReleaseDrops() {
        let wake = makeWake()
        wake.acquire()
        wake.acquire()
        wake.release()
        XCTAssertEqual(dropped, [], "the assertion outlives all but the last holder")
        wake.release()
        XCTAssertEqual(dropped, [7])
        XCTAssertFalse(wake.isHolding)
    }

    func testUnbalancedReleaseClampsAtZero() {
        let wake = makeWake()
        wake.release()
        wake.acquire()
        XCTAssertEqual(raised, 1, "a stray release must not pre-consume the next holder")
        XCTAssertTrue(wake.isHolding)
        wake.release()
        XCTAssertEqual(dropped, [7])
    }

    func testFailedRaiseRetriesOnNextFreshAcquire() {
        raiseResult = nil
        let wake = makeWake()
        wake.acquire()
        XCTAssertFalse(wake.isHolding)
        wake.release()
        raiseResult = 9
        wake.acquire()
        XCTAssertEqual(raised, 2, "a failed platform call retries when holders return")
        XCTAssertTrue(wake.isHolding)
        wake.release()
        XCTAssertEqual(dropped, [9])
    }

    func testReacquireAfterFullReleaseRaisesAgain() {
        let wake = makeWake()
        wake.acquire()
        wake.release()
        wake.acquire()
        XCTAssertEqual(raised, 2)
        XCTAssertEqual(dropped, [7])
        XCTAssertTrue(wake.isHolding)
    }
}
