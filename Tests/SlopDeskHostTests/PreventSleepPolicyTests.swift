import XCTest
@testable import SlopDeskHost

/// The pure prevent-sleep decision. Asserts iff the feature is enabled AND at least one
/// agent is currently working; releases otherwise. Headless (no `IOPMAssertion` — the glue is code-reviewed).
final class PreventSleepPolicyTests: XCTestCase {
    func testAssertsOnlyWhenEnabledAndWorking() {
        XCTAssertTrue(
            PreventSleepPolicy.shouldAssert(anyAgentWorking: true, enabled: true),
            "enabled + an agent working ⇒ hold the assertion",
        )
        XCTAssertFalse(
            PreventSleepPolicy.shouldAssert(anyAgentWorking: false, enabled: true),
            "enabled but nothing working ⇒ release (a quiet host sleeps)",
        )
        XCTAssertFalse(
            PreventSleepPolicy.shouldAssert(anyAgentWorking: true, enabled: false),
            "disabled ⇒ never hold, even while working",
        )
        XCTAssertFalse(PreventSleepPolicy.shouldAssert(anyAgentWorking: false, enabled: false))
    }

    /// The transition the daemon drives: hold on the first working pane, release when none remain.
    func testReleaseTransitionFollowsWorkingAggregate() {
        XCTAssertTrue(PreventSleepPolicy.shouldAssert(anyAgentWorking: true, enabled: true), "assert on first working")
        XCTAssertFalse(PreventSleepPolicy.shouldAssert(anyAgentWorking: false, enabled: true), "release when idle")
    }
}
