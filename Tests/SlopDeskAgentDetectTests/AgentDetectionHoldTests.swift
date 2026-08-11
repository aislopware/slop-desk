import XCTest
@testable import SlopDeskAgentDetect

/// Parity pins for the temporal layer (herdr `src/pane/agent_detection.rs` tests).
final class AgentDetectionHoldTests: XCTestCase {
    private let working = AgentScreenDetection(state: .working, visibleWorking: true)
    private let plainIdle = AgentScreenDetection(state: .idle)
    private let visibleIdle = AgentScreenDetection(state: .idle, visibleIdle: true)
    private let visibleBlocker = AgentScreenDetection(state: .blocked, visibleBlocker: true)

    /// herdr: hold persists through the 1st and 2nd 100 ms recheck, releases on the 3rd.
    func testWorkingToPlainIdleHoldsForThreeRechecks() {
        var hold = AgentDetectionHold()
        let t0: TimeInterval = 100
        XCTAssertTrue(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: t0,
        ))
        XCTAssertTrue(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: t0 + 0.1,
        ))
        XCTAssertTrue(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: t0 + 0.2,
        ))
        XCTAssertFalse(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: t0 + 0.3,
        ))
    }

    func testVisibleIdleBypassesPlainIdleHold() {
        var hold = AgentDetectionHold()
        XCTAssertFalse(hold.shouldHoldWorkingToIdle(
            previous: working, next: visibleIdle, agentChanged: false, processExited: false, now: 5,
        ))
    }

    func testSevenHundredMillisecondCapForcePublishes() {
        var hold = AgentDetectionHold()
        XCTAssertTrue(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: 0,
        ))
        // A slow caller past the cap force-releases regardless of confirmation count.
        XCTAssertFalse(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: 0.7,
        ))
    }

    func testAgentChangeAndProcessExitBypassTheHold() {
        var hold = AgentDetectionHold()
        XCTAssertFalse(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: true, processExited: false, now: 0,
        ))
        XCTAssertFalse(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: true, now: 0,
        ))
    }

    func testAnInterveningNonIdleReadClearsThePending() {
        var hold = AgentDetectionHold()
        XCTAssertTrue(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: 0,
        ))
        // Working again → pending cleared…
        XCTAssertFalse(hold.shouldHoldWorkingToIdle(
            previous: working, next: working, agentChanged: false, processExited: false, now: 0.1,
        ))
        // …so the next idle starts a fresh 3-recheck hold.
        XCTAssertTrue(hold.shouldHoldWorkingToIdle(
            previous: working, next: plainIdle, agentChanged: false, processExited: false, now: 0.2,
        ))
    }

    func testPublishGateFiresOnAnyStateOrVisibilityChange() {
        XCTAssertTrue(AgentDetectionHold.shouldPublish(
            previous: plainIdle, next: working, agentChanged: false, processExited: false, refreshDue: false,
        ))
        XCTAssertTrue(AgentDetectionHold.shouldPublish(
            previous: plainIdle, next: visibleIdle, agentChanged: false, processExited: false, refreshDue: false,
        ))
        XCTAssertFalse(AgentDetectionHold.shouldPublish(
            previous: plainIdle, next: plainIdle, agentChanged: false, processExited: false, refreshDue: false,
        ))
    }

    func testStableVisibleBlockerRefreshesEveryEightHundredMilliseconds() {
        XCTAssertTrue(AgentDetectionHold.stableVisibleSignalRefreshDue(
            previous: visibleBlocker, next: visibleBlocker, lastRefresh: nil, now: 0,
        ))
        XCTAssertFalse(AgentDetectionHold.stableVisibleSignalRefreshDue(
            previous: visibleBlocker, next: visibleBlocker, lastRefresh: 0, now: 0.5,
        ))
        XCTAssertTrue(AgentDetectionHold.stableVisibleSignalRefreshDue(
            previous: visibleBlocker, next: visibleBlocker, lastRefresh: 0, now: 0.8,
        ))
        // Only the visible-blocker case refreshes.
        XCTAssertFalse(AgentDetectionHold.stableVisibleSignalRefreshDue(
            previous: visibleIdle, next: visibleIdle, lastRefresh: nil, now: 0,
        ))
    }

    // MARK: The blocked→idle hold (ours, not herdr's — user-reported 2026-08-11)

    /// Leaving a block is the consequential edge: it clears the mark AND mints a hook-less
    /// completion across every client. It takes the same three confirming reads.
    func testBlockedToIdleHoldsForThreeRechecks() {
        var hold = AgentDetectionHold()
        let t0: TimeInterval = 100
        for step in 0...2 {
            XCTAssertTrue(hold.shouldHoldBlockedToIdle(
                previous: visibleBlocker, next: plainIdle,
                agentChanged: false, processExited: false, now: t0 + 0.1 * Double(step),
            ), "recheck \(step)")
            XCTAssertTrue(hold.isHoldingIdle, "the hold tightens the recheck cadence")
        }
        XCTAssertFalse(hold.shouldHoldBlockedToIdle(
            previous: visibleBlocker, next: plainIdle,
            agentChanged: false, processExited: false, now: t0 + 0.3,
        ))
        XCTAssertFalse(hold.isHoldingIdle)
    }

    /// ⚠️ The divergence from the working→idle sibling: a VISIBLE idle does NOT bypass this hold.
    /// A mid-repaint dialog reads as `live_prompt_box` — idle, visible — and that is precisely the
    /// verdict that must not be believed on one read.
    func testBlockedToVisibleIdleIsHeldToo() {
        var hold = AgentDetectionHold()
        XCTAssertTrue(hold.shouldHoldBlockedToIdle(
            previous: visibleBlocker, next: visibleIdle,
            agentChanged: false, processExited: false, now: 0,
        ))
        XCTAssertFalse(hold.decide(
            previous: visibleBlocker, next: visibleIdle,
            agentChanged: false, processExited: false, lastRefresh: nil, now: 0.1,
        ), "…and `decide` refuses to publish it")
    }

    func testBlockedToIdleReleasesAtTheCapAndOnAgentChangeOrExit() {
        var hold = AgentDetectionHold()
        XCTAssertTrue(hold.shouldHoldBlockedToIdle(
            previous: visibleBlocker, next: plainIdle,
            agentChanged: false, processExited: false, now: 0,
        ))
        XCTAssertFalse(hold.shouldHoldBlockedToIdle(
            previous: visibleBlocker, next: plainIdle,
            agentChanged: false, processExited: false, now: AgentDetectionHold.pendingIdleCap,
        ), "the cap force-releases")

        // A new agent / a dead process is ground truth, never something to confirm.
        var fresh = AgentDetectionHold()
        XCTAssertFalse(fresh.shouldHoldBlockedToIdle(
            previous: visibleBlocker, next: plainIdle,
            agentChanged: true, processExited: false, now: 0,
        ))
        XCTAssertFalse(fresh.shouldHoldBlockedToIdle(
            previous: visibleBlocker, next: plainIdle,
            agentChanged: false, processExited: true, now: 0,
        ))
    }

    /// The two holds keep separate counters, so a pane that walks working → idle → blocked → idle
    /// never carries a stale confirmation from one into the other.
    func testTheTwoHoldsDoNotShareState() {
        var hold = AgentDetectionHold()
        // Two working→idle rechecks…
        _ = hold.decide(
            previous: working, next: plainIdle,
            agentChanged: false, processExited: false, lastRefresh: nil, now: 0,
        )
        _ = hold.decide(
            previous: working, next: plainIdle,
            agentChanged: false, processExited: false, lastRefresh: nil, now: 0.1,
        )
        // …then a block, then a blocked→idle: the unblock starts its own count from scratch.
        XCTAssertTrue(hold.decide(
            previous: plainIdle, next: visibleBlocker,
            agentChanged: false, processExited: false, lastRefresh: nil, now: 0.2,
        ))
        for step in 0...2 {
            XCTAssertFalse(hold.decide(
                previous: visibleBlocker, next: plainIdle,
                agentChanged: false, processExited: false, lastRefresh: nil, now: 0.3 + 0.1 * Double(step),
            ), "recheck \(step)")
        }
        XCTAssertTrue(hold.decide(
            previous: visibleBlocker, next: plainIdle,
            agentChanged: false, processExited: false, lastRefresh: nil, now: 0.6,
        ))
    }

    func testDecidePublishesVisibleBlockerImmediately() {
        var hold = AgentDetectionHold()
        XCTAssertTrue(hold.decide(
            previous: working,
            next: visibleBlocker,
            agentChanged: false,
            processExited: false,
            lastRefresh: nil,
            now: 0,
        ))
    }
}
