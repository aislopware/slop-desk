import XCTest
@testable import SlopDeskVideoClient

/// Pending-decode budget for the off-queue VT decode stage (wifi-flap hardening). Pure decider —
/// the actor admits a frame onto the serial decode queue only while the stage is under both the
/// count and the byte cap; past either, the frame is dropped BEFORE dispatch and routed through
/// the existing loss-recovery machinery (drop-until-anchor gate + IDR request). No
/// `VTDecompressionSession` anywhere (hang-safety rule 6).
final class DecodeAdmissionBudgetTests: XCTestCase {
    func testCountCapRejectsPastBound() {
        var budget = DecodeAdmissionBudget(maxPendingCount: 4, maxPendingBytes: 1 << 30)
        for i in 0..<4 {
            XCTAssertTrue(budget.admit(bytes: 1000), "frame \(i) under the cap must admit")
        }
        XCTAssertFalse(budget.admit(bytes: 1000), "frame past the count cap must be dropped pre-dispatch")
        XCTAssertEqual(budget.pendingCount, 4, "a rejected frame must not count as pending")
        XCTAssertEqual(budget.pendingBytes, 4000, "a rejected frame must not add pending bytes")
    }

    func testByteCapRejectsBeforeCountCap() {
        var budget = DecodeAdmissionBudget(maxPendingCount: 100, maxPendingBytes: 5000)
        XCTAssertTrue(budget.admit(bytes: 3000))
        XCTAssertTrue(budget.admit(bytes: 2000))
        XCTAssertFalse(budget.admit(bytes: 1), "a frame past the byte cap must be dropped pre-dispatch")
        XCTAssertEqual(budget.pendingBytes, 5000)
    }

    func testCompleteFreesBothDimensions() {
        var budget = DecodeAdmissionBudget(maxPendingCount: 2, maxPendingBytes: 4000)
        XCTAssertTrue(budget.admit(bytes: 2000))
        XCTAssertTrue(budget.admit(bytes: 2000))
        XCTAssertFalse(budget.admit(bytes: 100))
        budget.complete(bytes: 2000)
        XCTAssertEqual(budget.pendingCount, 1)
        XCTAssertEqual(budget.pendingBytes, 2000)
        XCTAssertTrue(budget.admit(bytes: 100), "a completed decode must free budget for the next frame")
    }

    func testCompleteClampsAtZero() {
        var budget = DecodeAdmissionBudget(maxPendingCount: 2, maxPendingBytes: 4000)
        budget.complete(bytes: 9999)
        XCTAssertEqual(budget.pendingCount, 0)
        XCTAssertEqual(budget.pendingBytes, 0)
    }

    func testDefaultCapsAdmitASingleLargeIDR() {
        // A ~2 MB IDR must always fit an empty stage under the default caps.
        var budget = DecodeAdmissionBudget()
        XCTAssertTrue(budget.admit(bytes: 2 << 20))
    }

    func testOversizedFrameAdmitsWhenIdle() {
        // A frame whose byte size ALONE exceeds the cap must still admit onto an IDLE stage —
        // rejecting it drops every same-size-class replacement keyframe forever (a livelock)
        // while the decode stage sits empty. The budget bounds QUEUED work, not frame size.
        var budget = DecodeAdmissionBudget(maxPendingCount: 4, maxPendingBytes: 5000)
        XCTAssertTrue(budget.admit(bytes: 9000), "an idle stage must admit regardless of byte size")
        XCTAssertEqual(budget.pendingCount, 1)
        XCTAssertEqual(budget.pendingBytes, 9000)
        XCTAssertFalse(budget.admit(bytes: 100), "the oversized admission still counts against the byte cap")
        budget.complete(bytes: 9000)
        XCTAssertTrue(budget.admit(bytes: 100), "the budget recovers once the oversized decode completes")
    }
}
