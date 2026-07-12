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

/// PURE per-window AX-evidence ledger behind the probe (the phantom-window junk filter):
/// fold semantics, the explicit not-listed verdict for swept-but-absent ids, and the
/// closed-window prune. Headless — no AX.
final class WindowAXLedgerTests: XCTestCase {
    func testFoldMarksSweptWindowsListedAndAbsentOffScreenOnesPhantom() {
        var ledger = WindowAXLedger()
        // The app's sweep returned windows 10 (normal) and 11 (minimized); CGWindowList also showed
        // off-screen ids 11 and 99 for this pid — 99 is the phantom.
        ledger.fold(sweep: [10: false, 11: true], offScreenIDs: [11, 99])
        XCTAssertEqual(ledger.verdict(for: 10), .init(axListed: true, minimized: false))
        XCTAssertEqual(ledger.verdict(for: 11), .init(axListed: true, minimized: true))
        XCTAssertEqual(ledger.verdict(for: 99), .init(axListed: false, minimized: false))
        XCTAssertNil(ledger.verdict(for: 42), "never-probed windows have NO verdict (not a phantom one)")
    }

    func testPhantomVerdictIsOverwrittenWhenALaterSweepListsTheWindow() {
        // A window can be born between the CG enumeration and the AX sweep (or its id recycled) —
        // the NEXT successful sweep must win over the stale phantom verdict.
        var ledger = WindowAXLedger()
        ledger.fold(sweep: [:], offScreenIDs: [7])
        XCTAssertEqual(ledger.verdict(for: 7)?.axListed, false)
        ledger.fold(sweep: [7: true], offScreenIDs: [7])
        XCTAssertEqual(ledger.verdict(for: 7), .init(axListed: true, minimized: true))
    }

    func testRetainPrunesClosedWindows() {
        var ledger = WindowAXLedger()
        ledger.fold(sweep: [10: false], offScreenIDs: [99])
        ledger.retain(only: [10])
        XCTAssertNotNil(ledger.verdict(for: 10))
        XCTAssertNil(ledger.verdict(for: 99), "closed windows leave the ledger")
    }
}
