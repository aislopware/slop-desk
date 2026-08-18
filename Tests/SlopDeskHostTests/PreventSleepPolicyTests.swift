import XCTest
@testable import SlopDeskHost

/// The prevent-sleep CROSSING. The rule — assert iff enabled AND an agent is working — is
/// `slopdesk_agent::sleep`; what is pinned here is that the two flags reach it in the order the door
/// declares, which a swap would hide behind a symmetric-looking truth table.
final class PreventSleepPolicyTests: XCTestCase {
    func testTheTwoFlagsCrossInTheOrderTheDoorDeclares() {
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
}
