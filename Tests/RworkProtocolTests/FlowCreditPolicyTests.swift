import XCTest
@testable import RworkProtocol

/// Pure SSH-window credit-math tests for `FlowCreditPolicy`. No IO.
final class FlowCreditPolicyTests: XCTestCase {

    func testInitialWindowIsFullCreditAndUnblocked() {
        let policy = FlowCreditPolicy(initialWindow: 1024)
        XCTAssertEqual(policy.initialWindow, 1024)
        XCTAssertEqual(policy.remaining, 1024)
        XCTAssertFalse(policy.isBlocked)
    }

    func testConsumeWithinWindowDebitsRemaining() {
        var policy = FlowCreditPolicy(initialWindow: 100)
        XCTAssertEqual(policy.consume(30), .allowed(remaining: 70))
        XCTAssertEqual(policy.remaining, 70)
        XCTAssertEqual(policy.consume(70), .allowed(remaining: 0))
        XCTAssertEqual(policy.remaining, 0)
        XCTAssertTrue(policy.isBlocked, "consuming exactly to zero blocks further sends")
    }

    func testConsumeBeyondWindowIsAllOrNothing() {
        var policy = FlowCreditPolicy(initialWindow: 50)
        // Asking for more than remains consumes NOTHING and reports what's available.
        XCTAssertEqual(policy.consume(51), .insufficient(available: 50))
        XCTAssertEqual(policy.remaining, 50, "an over-budget request must not partially debit")
        XCTAssertFalse(policy.isBlocked)
    }

    func testExhaustionBlocks() {
        var policy = FlowCreditPolicy(initialWindow: 10)
        XCTAssertEqual(policy.consume(10), .allowed(remaining: 0))
        XCTAssertTrue(policy.isBlocked)
        // Any further consume (even 1 byte) is refused while blocked.
        XCTAssertEqual(policy.consume(1), .insufficient(available: 0))
    }

    func testAdjustReplenishesAndUnblocks() {
        var policy = FlowCreditPolicy(initialWindow: 8)
        XCTAssertEqual(policy.consume(8), .allowed(remaining: 0))
        XCTAssertTrue(policy.isBlocked)

        policy.adjust(bytesToAdd: 16)
        XCTAssertFalse(policy.isBlocked, "a window-adjust unblocks the channel")
        XCTAssertEqual(policy.remaining, 16)
        XCTAssertEqual(policy.consume(12), .allowed(remaining: 4))
    }

    func testAdjustCanGrowBeyondInitialWindow() {
        // SSH windows can be grown past their initial size; initialWindow is only the
        // starting reference, not a hard cap on remaining.
        var policy = FlowCreditPolicy(initialWindow: 4)
        policy.adjust(bytesToAdd: 100)
        XCTAssertEqual(policy.remaining, 104)
        XCTAssertEqual(policy.initialWindow, 4)
    }

    func testNegativeAndZeroGrantsIgnored() {
        var policy = FlowCreditPolicy(initialWindow: 5)
        policy.adjust(bytesToAdd: 0)
        XCTAssertEqual(policy.remaining, 5)
        policy.adjust(bytesToAdd: -10)
        XCTAssertEqual(policy.remaining, 5, "a negative grant must not shrink the window")
    }

    func testZeroAndNegativeConsumeIsAllowedAndConsumesNothing() {
        var policy = FlowCreditPolicy(initialWindow: 5)
        XCTAssertEqual(policy.consume(0), .allowed(remaining: 5))
        XCTAssertEqual(policy.consume(-3), .allowed(remaining: 5))
        XCTAssertEqual(policy.remaining, 5)
    }

    func testNegativeInitialWindowClampsToZeroAndBlocks() {
        let policy = FlowCreditPolicy(initialWindow: -100)
        XCTAssertEqual(policy.initialWindow, 0)
        XCTAssertEqual(policy.remaining, 0)
        XCTAssertTrue(policy.isBlocked)
    }
}
