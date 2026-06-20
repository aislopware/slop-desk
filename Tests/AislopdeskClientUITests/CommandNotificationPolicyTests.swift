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

/// B3: the PURE background-completion decision shared by the badge AND the long-command notification's
/// focus gate. UN-free, clock-free — proves the DECISION (the poster + SwiftUI badge are the thin shims).
final class BackgroundCompletionPolicyTests: XCTestCase {
    private let threshold = CommandNotificationPolicy.longRunningThresholdMS // 10_000

    // MARK: badge

    /// A FOCUSED pane never badges (you're watching it) — regardless of exit / duration. THE B3 gate.
    func testFocusedPaneNeverBadges() {
        XCTAssertNil(BackgroundCompletionPolicy.badge(
            exitCode: 1, durationMS: 60000, isPaneFocused: true, longThresholdMS: threshold,
        ), "a focused failure does not badge")
        XCTAssertNil(BackgroundCompletionPolicy.badge(
            exitCode: 0, durationMS: 60000, isPaneFocused: true, longThresholdMS: threshold,
        ), "a focused long success does not badge")
    }

    /// A BACKGROUND failure badges `.failure` immediately — even a QUICK failing command (no duration gate
    /// on failures; a backgrounded `make` that bailed in 1s is worth surfacing).
    func testBackgroundFailureShortBadgesFailure() {
        XCTAssertEqual(BackgroundCompletionPolicy.badge(
            exitCode: 2, durationMS: 500, isPaneFocused: false, longThresholdMS: threshold,
        ), .failure)
    }

    /// A BACKGROUND short SUCCESS does NOT badge — no `ls`/`cd` noise on the sidebar.
    func testBackgroundShortSuccessDoesNotBadge() {
        XCTAssertNil(BackgroundCompletionPolicy.badge(
            exitCode: 0, durationMS: 500, isPaneFocused: false, longThresholdMS: threshold,
        ))
    }

    /// A BACKGROUND LONG success badges `.success`.
    func testBackgroundLongSuccessBadgesSuccess() {
        XCTAssertEqual(BackgroundCompletionPolicy.badge(
            exitCode: 0, durationMS: threshold, isPaneFocused: false, longThresholdMS: threshold,
        ), .success, "exactly at the threshold counts as long")
        XCTAssertEqual(BackgroundCompletionPolicy.badge(
            exitCode: 0, durationMS: 60000, isPaneFocused: false, longThresholdMS: threshold,
        ), .success)
    }

    /// `exitCode == nil` (a completion carrying no code) is treated as a clean exit 0.
    func testNilExitCodeTreatedAsSuccess() {
        XCTAssertNil(BackgroundCompletionPolicy.badge(
            exitCode: nil, durationMS: 500, isPaneFocused: false, longThresholdMS: threshold,
        ), "a short nil-exit completion is a short success → no badge")
        XCTAssertEqual(BackgroundCompletionPolicy.badge(
            exitCode: nil, durationMS: 60000, isPaneFocused: false, longThresholdMS: threshold,
        ), .success, "a long nil-exit completion is a long success → .success")
    }

    // MARK: shouldNotify (the B3 focus gate)

    /// FOCUSED → never notify (a foreground long command must not spam), even when long + enabled.
    func testFocusedLongCommandDoesNotNotify() {
        XCTAssertFalse(BackgroundCompletionPolicy.shouldNotify(
            durationMS: 60000, isPaneFocused: true, enabled: true, longThresholdMS: threshold,
        ))
    }

    /// BACKGROUND + long + enabled → notify.
    func testBackgroundLongEnabledNotifies() {
        XCTAssertTrue(BackgroundCompletionPolicy.shouldNotify(
            durationMS: threshold, isPaneFocused: false, enabled: true, longThresholdMS: threshold,
        ))
    }

    /// BACKGROUND short → no notify (only LONG commands alert).
    func testBackgroundShortDoesNotNotify() {
        XCTAssertFalse(BackgroundCompletionPolicy.shouldNotify(
            durationMS: 9999, isPaneFocused: false, enabled: true, longThresholdMS: threshold,
        ))
    }

    /// enabled=false → no notify (the toggle is honored) — but the BADGE is unaffected by `enabled`
    /// (badge has no `enabled` parameter), so a disabled toggle still surfaces the in-app badge.
    func testDisabledTogglesNotifyOffButBadgeUnaffected() {
        XCTAssertFalse(BackgroundCompletionPolicy.shouldNotify(
            durationMS: 60000, isPaneFocused: false, enabled: false, longThresholdMS: threshold,
        ), "the toggle gates the desktop notification")
        XCTAssertEqual(BackgroundCompletionPolicy.badge(
            exitCode: 0, durationMS: 60000, isPaneFocused: false, longThresholdMS: threshold,
        ), .success, "the badge does not depend on the notification toggle")
    }
}

/// B3: the PURE `userInfo` builder for the long-command notification's click-to-reveal wiring — proven
/// without instantiating `UNUserNotificationCenter`.
final class LongCommandNotificationUserInfoTests: XCTestCase {
    func testEmbedsPaneIDKeyUnderRouterKey() {
        let info = LongCommandNotificationUserInfo.make(paneIDUserInfoKey: "k", paneIDKey: "PANE-1")
        XCTAssertEqual(info, ["k": "PANE-1"], "a present key reveals the originating pane")
    }

    func testNilKeyYieldsEmptyUserInfo() {
        XCTAssertEqual(
            LongCommandNotificationUserInfo.make(paneIDUserInfoKey: "k", paneIDKey: nil),
            [:],
            "no key ⇒ no reveal target",
        )
    }
}
