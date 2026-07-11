import XCTest
@testable import SlopDeskVideoHost

/// PURE budget decider for the Phase-5 AXMinimized probe (docs/45): per-pid TTL, per-tick quota,
/// stale-pid carry-over, and the quit-app stamp prune. Headless — no AX.
final class MinimizedProbeBudgetTests: XCTestCase {
    func testQuotaCapsAndCarryOverWinsLater() {
        var budget = MinimizedProbeBudget(ttl: 3, maxPIDsPerTick: 2)
        XCTAssertEqual(budget.pidsToProbe([5, 1, 3], now: 100), [1, 3], "≤2 per tick, deterministic order")
        XCTAssertEqual(budget.pidsToProbe([5, 1, 3], now: 100.5), [5], "the unpicked stale pid wins next")
        XCTAssertEqual(budget.pidsToProbe([5, 1, 3], now: 101), [], "everyone fresh inside the TTL")
    }

    func testTTLReopensProbes() {
        var budget = MinimizedProbeBudget(ttl: 3, maxPIDsPerTick: 4)
        XCTAssertEqual(budget.pidsToProbe([7], now: 100), [7])
        XCTAssertEqual(budget.pidsToProbe([7], now: 102.9), [])
        XCTAssertEqual(budget.pidsToProbe([7], now: 103), [7], "stale again at the TTL")
    }

    func testQuitAppsDropTheirStamps() {
        var budget = MinimizedProbeBudget(ttl: 3, maxPIDsPerTick: 4)
        _ = budget.pidsToProbe([1, 2], now: 100)
        // Pid 2 quit; pid 1 stays fresh. A NEW pid probes immediately regardless.
        XCTAssertEqual(budget.pidsToProbe([1, 9], now: 101), [9])
    }
}
