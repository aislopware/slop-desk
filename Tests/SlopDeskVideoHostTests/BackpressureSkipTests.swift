import XCTest
@testable import SlopDeskVideoHost

/// Pins the congestion-backpressure decision: under a backed-up send-lane, ordinary deltas are skipped
/// BEFORE encode (bounding end-to-end latency), but forced obligations always pass and a non-backed-up
/// lane never skips. The skip itself bounds the HW-measured RTT-1475ms / hold-2547ms scroll bufferbloat.
final class BackpressureSkipTests: XCTestCase {
    private func skip(
        enabled: Bool = true, depth: Int, threshold: Int = 3,
        kf: Bool = false, crisp: Bool = false, compact: Bool = false, ltr: Bool = false,
    ) -> Bool {
        SlopDeskVideoHostSession.backpressureSkip(
            enabled: enabled, laneDepth: depth, depthThreshold: threshold,
            forceKeyframe: kf, crisp: crisp, compact: compact, ltrRefresh: ltr,
        )
    }

    func testNotBackedUpNeverSkips() {
        XCTAssertFalse(skip(depth: 0))
        XCTAssertFalse(skip(depth: 3)) // exactly at threshold = not over → keep
    }

    func testBackedUpSkipsOrdinaryDelta() {
        XCTAssertTrue(skip(depth: 4)) // over threshold
        XCTAssertTrue(skip(depth: 20))
    }

    func testForcedObligationsAlwaysPassEvenWhenBackedUp() {
        // Recovery/sharpness anchors must never be dropped, no matter how deep the lane.
        XCTAssertFalse(skip(depth: 50, kf: true))
        XCTAssertFalse(skip(depth: 50, crisp: true))
        XCTAssertFalse(skip(depth: 50, compact: true))
        XCTAssertFalse(skip(depth: 50, ltr: true))
    }

    func testDisabledNeverSkips() {
        XCTAssertFalse(skip(enabled: false, depth: 100))
    }

    func testThresholdIsStrictlyGreaterThan() {
        XCTAssertFalse(skip(depth: 5, threshold: 5))
        XCTAssertTrue(skip(depth: 6, threshold: 5))
    }
}
