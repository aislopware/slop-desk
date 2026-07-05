import XCTest
@testable import SlopDeskAgentDetect

/// Session rollup = the most-urgent status over a set of per-pane statuses, Herdr-style:
/// blocked(needsPermission) > working > done > idle > none. Drives the sidebar dot.
final class ClaudeRollupTests: XCTestCase {
    func testEmptyRollupIsNone() {
        XCTAssertEqual(ClaudeStatus.rollup([]), .none)
    }

    func testAllNoneIsNone() {
        XCTAssertEqual(ClaudeStatus.rollup([.none, .none, .none]), .none)
    }

    func testBlockedBeatsEverything() {
        XCTAssertEqual(ClaudeStatus.rollup([.idle, .working, .done, .needsPermission]), .needsPermission)
        XCTAssertEqual(ClaudeStatus.rollup([.needsPermission, .working]), .needsPermission)
    }

    func testWorkingBeatsDoneAndIdle() {
        XCTAssertEqual(ClaudeStatus.rollup([.idle, .done, .working]), .working)
        XCTAssertEqual(ClaudeStatus.rollup([.done, .working]), .working)
    }

    func testDoneBeatsIdle() {
        XCTAssertEqual(ClaudeStatus.rollup([.idle, .done, .idle]), .done)
    }

    func testIdleBeatsNone() {
        XCTAssertEqual(ClaudeStatus.rollup([.none, .idle, .none]), .idle)
    }

    func testSinglePaneRollsUpToItself() {
        for s in [ClaudeStatus.none, .idle, .working, .needsPermission, .done] {
            XCTAssertEqual(ClaudeStatus.rollup([s]), s)
        }
    }

    // MARK: The total order is explicit and consistent

    func testUrgencyTotalOrder() {
        // Strictly increasing urgency: none < idle < done < working < needsPermission.
        let ordered: [ClaudeStatus] = [.none, .idle, .done, .working, .needsPermission]
        for i in 0..<(ordered.count - 1) {
            XCTAssertLessThan(
                ordered[i].urgency,
                ordered[i + 1].urgency,
                "\(ordered[i]) should be less urgent than \(ordered[i + 1])",
            )
        }
    }

    func testRollupIsTheMaxByUrgency() {
        // Cross-check: rollup result == the element with the max urgency.
        let panes: [ClaudeStatus] = [.idle, .done, .working, .none]
        let expected = panes.max { $0.urgency < $1.urgency }
        XCTAssertEqual(ClaudeStatus.rollup(panes), expected)
    }

    func testRollupOrderIndependence() {
        // Rollup is commutative — any permutation yields the same most-urgent.
        let base: [ClaudeStatus] = [.none, .idle, .working, .done, .needsPermission]
        XCTAssertEqual(ClaudeStatus.rollup(base), .needsPermission)
        XCTAssertEqual(ClaudeStatus.rollup(base.reversed()), .needsPermission)
        XCTAssertEqual(ClaudeStatus.rollup([.done, .needsPermission, .none, .working, .idle]), .needsPermission)
    }
}
