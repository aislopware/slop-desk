import XCTest
@testable import AislopdeskProtocol

/// Pure half-window replenish-decision tests for `ReceiveWindowAccountant`. No IO.
/// This is the receiver-side decider that decides WHEN to emit a `windowAdjust` back to the
/// sender (S2 scope #3): accumulate consumed bytes, grant the whole pending amount once the
/// half-window threshold is crossed.
final class ReceiveWindowAccountantTests: XCTestCase {
    func testNoGrantBelowHalfWindowThreshold() {
        var acc = ReceiveWindowAccountant(initialWindow: 1000)
        XCTAssertEqual(acc.threshold, 500)
        XCTAssertNil(acc.consume(100), "100 < 500 → accumulate, no grant yet")
        XCTAssertNil(acc.consume(399), "499 < 500 → still below threshold")
        XCTAssertEqual(acc.pendingCredit, 499)
    }

    func testGrantsWholePendingOnceThresholdCrossed() {
        var acc = ReceiveWindowAccountant(initialWindow: 1000)
        XCTAssertNil(acc.consume(300))
        // Crossing the half-window (500) grants the WHOLE accumulated amount, topping the sender
        // back up to full, and resets pending to 0.
        XCTAssertEqual(acc.consume(250), 550, "300+250=550 ≥ 500 → grant the full 550")
        XCTAssertEqual(acc.pendingCredit, 0, "pending resets after a grant")
        XCTAssertNil(acc.consume(100), "fresh accumulation after a grant starts below threshold again")
    }

    func testSingleLargeConsumeCrossesThresholdImmediately() {
        var acc = ReceiveWindowAccountant(initialWindow: 1000)
        XCTAssertEqual(acc.consume(800), 800, "a single consume past half-window grants immediately")
        XCTAssertEqual(acc.pendingCredit, 0)
    }

    func testExactThresholdGrants() {
        var acc = ReceiveWindowAccountant(initialWindow: 1000)
        XCTAssertEqual(acc.consume(500), 500, "consuming exactly the threshold grants")
    }

    func testZeroAndNegativeConsumeGrantsNothing() {
        var acc = ReceiveWindowAccountant(initialWindow: 1000)
        XCTAssertNil(acc.consume(0))
        XCTAssertNil(acc.consume(-50))
        XCTAssertEqual(acc.pendingCredit, 0, "non-positive consume accumulates nothing")
    }

    func testZeroWindowNeverGrants() {
        // A zero/negative window means flow control is effectively disabled for this accountant —
        // it must NEVER emit a grant (threshold is Int.max), regardless of bytes consumed.
        var acc = ReceiveWindowAccountant(initialWindow: 0)
        XCTAssertNil(acc.consume(1_000_000))
        XCTAssertEqual(acc.threshold, Int.max)
        let neg = ReceiveWindowAccountant(initialWindow: -100)
        XCTAssertEqual(neg.initialWindow, 0, "negative window clamps to zero")
    }

    func testTinyWindowThresholdIsAtLeastOne() {
        var acc = ReceiveWindowAccountant(initialWindow: 1)
        XCTAssertEqual(acc.threshold, 1, "a 1-byte window still makes progress (threshold ≥ 1)")
        XCTAssertEqual(acc.consume(1), 1)
    }
}
