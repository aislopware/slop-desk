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
