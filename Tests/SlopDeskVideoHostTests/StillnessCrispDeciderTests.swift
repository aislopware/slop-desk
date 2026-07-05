import XCTest
@testable import SlopDeskVideoHost

/// PURE event-driven crisp re-anchor logic (2026-06-16). N consecutive byte-identical `.complete`
/// frames ⇒ fire the crisp re-anchor once, re-arm on any change. No hashing/clocks/pixels — safe
/// under `swift test --filter StillnessCrispDeciderTests`.
final class StillnessCrispDeciderTests: XCTestCase {
    func testStartsNotAtRest() {
        let d = StillnessCrispDecider()
        XCTAssertEqual(d.consecutiveEqual, 0)
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2))
    }

    func testFiresAfterThresholdEqualFrames() {
        var d = StillnessCrispDecider()
        d.onFrame(hashEqualToPrevious: true) // 1
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2), "one equal frame < threshold ⇒ no fire")
        d.onFrame(hashEqualToPrevious: true) // 2
        XCTAssertTrue(d.shouldFireCrisp(restThreshold: 2), "threshold reached ⇒ fire")
    }

    func testFiresOncePerRest() {
        var d = StillnessCrispDecider()
        d.onFrame(hashEqualToPrevious: true)
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertTrue(d.shouldFireCrisp(restThreshold: 2))
        d.noteCrispFired()
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2), "already fired this rest ⇒ no re-fire")
        // More identical frames must NOT re-fire while still at rest.
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2))
    }

    func testChangedFrameReArms() {
        var d = StillnessCrispDecider()
        d.onFrame(hashEqualToPrevious: true)
        d.onFrame(hashEqualToPrevious: true)
        d.noteCrispFired()
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2))
        // Motion resumes (a changed frame): count + firedThisRest reset.
        d.onFrame(hashEqualToPrevious: false)
        XCTAssertEqual(d.consecutiveEqual, 0)
        XCTAssertFalse(d.firedThisRest)
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2))
        // New rest period ⇒ fires again.
        d.onFrame(hashEqualToPrevious: true)
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertTrue(d.shouldFireCrisp(restThreshold: 2))
    }

    func testThresholdOneFiresOnFirstEqual() {
        var d = StillnessCrispDecider()
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertTrue(d.shouldFireCrisp(restThreshold: 1))
    }

    func testThresholdClampsToOne() {
        var d = StillnessCrispDecider()
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertTrue(d.shouldFireCrisp(restThreshold: 0), "threshold < 1 clamps to 1")
    }

    func testChangedFrameMidRunResetsCount() {
        var d = StillnessCrispDecider()
        d.onFrame(hashEqualToPrevious: true)
        d.onFrame(hashEqualToPrevious: false) // a change before threshold
        XCTAssertEqual(d.consecutiveEqual, 0)
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertFalse(d.shouldFireCrisp(restThreshold: 2), "count restarted ⇒ need threshold again")
        d.onFrame(hashEqualToPrevious: true)
        XCTAssertTrue(d.shouldFireCrisp(restThreshold: 2))
    }
}
