import XCTest
@testable import AislopdeskProtocol

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

    /// R6 #7 regression: a huge `UInt32`-sized grant (or a long run of grants) must NOT Int-overflow-trap
    /// `remaining += bytesToAdd`; it saturates at `Int.max`. The growable-window semantics
    /// (`testAdjustCanGrowBeyondInitialWindow`) are preserved — we only defuse the overflow trap.
    func testAdjustIsOverflowSafeAndStillGrowable() {
        var policy = FlowCreditPolicy(initialWindow: 1000)
        // Still grows past the initial window (design intent — not clamped).
        policy.adjust(bytesToAdd: 5000)
        XCTAssertEqual(policy.remaining, 6000, "a grant grows the window past initialWindow (SSH auto-tuning)")
        // A near-Int.max remaining + a large grant SATURATES instead of trapping/wrapping negative.
        for _ in 0..<3 { policy.adjust(bytesToAdd: Int.max) }
        XCTAssertEqual(policy.remaining, Int.max, "repeated huge grants saturate at Int.max (no overflow trap)")
        XCTAssertFalse(policy.isBlocked, "a saturated window is not blocked")
        // And a single UInt32-max grant from a fresh policy never traps.
        var p2 = FlowCreditPolicy(initialWindow: 256 * 1024)
        p2.adjust(bytesToAdd: Int(UInt32.max))
        XCTAssertEqual(p2.remaining, 256 * 1024 + Int(UInt32.max), "a UInt32-max grant adds without trapping")
    }
}
