import XCTest
@testable import AislopdeskClientUI

/// WF11: the PURE long-command notification policy. Deterministic, no `UNUserNotificationCenter`,
/// HostServer-free — just the threshold boundary. The poster itself is best-effort / GUI-gated and
/// is not exercised here (it needs an app bundle + auth prompt); this proves the DECISION.
final class CommandNotificationPolicyTests: XCTestCase {
    func testThresholdIsTenSeconds() {
        XCTAssertEqual(CommandNotificationPolicy.longRunningThresholdMS, 10000)
    }

    func testQuickCommandsDoNotNotify() {
        XCTAssertFalse(CommandNotificationPolicy.shouldNotify(durationMS: 0))
        XCTAssertFalse(CommandNotificationPolicy.shouldNotify(durationMS: 300)) // a quick `ls`
        XCTAssertFalse(CommandNotificationPolicy.shouldNotify(durationMS: 9999)) // just under
    }

    func testLongCommandsNotify() {
        XCTAssertTrue(CommandNotificationPolicy.shouldNotify(durationMS: 10000)) // exactly at
        XCTAssertTrue(CommandNotificationPolicy.shouldNotify(durationMS: 12000)) // `sleep 12`
        XCTAssertTrue(CommandNotificationPolicy.shouldNotify(durationMS: UInt32.max))
    }
}
