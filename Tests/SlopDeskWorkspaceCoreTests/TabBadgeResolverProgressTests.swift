import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// E14/K1 WI-2 — the OSC 9;4 PROGRESS input to the pure ``TabBadgeResolver``. WI-2 routes a live
/// ``PaneProgress`` into the EXISTING precedence (no new badge kind): an active in-progress / indeterminate
/// resolves to the `.running` spinner; a `9;4;2` error resolves to the `.error` alert (ranked at the error
/// tier, above a stale completion dot). A cleared progress (`nil`) falls through to the pre-E14 badge.
///
/// REVERT-TO-CONFIRM-FAIL: each test compares a progress-FED resolver against the un-fed (`progress: nil`)
/// result — on the pre-WI-2 resolver (no `progress` parameter) these would not compile, and the fed-vs-unfed
/// pairs prove the parameter actually changes the output (never a tautology). Headless: pure static, no clock.
final class TabBadgeResolverProgressTests: XCTestCase {
    /// All-clear convenience caller; each test overrides only the axes it exercises.
    private func badge(
        agent: ClaudeStatus = .none,
        completion: PaneCompletionBadge? = nil,
        isBusy: Bool = false,
        foregroundProcess: String? = nil,
        completionFreshness: TabBadgeResolver.CompletionFreshness = .settled,
        progress: PaneProgress? = nil,
    ) -> TabBadgeKind? {
        TabBadgeResolver.badge(
            agent: agent, completion: completion, isBusy: isBusy,
            foregroundProcess: foregroundProcess, completionFreshness: completionFreshness, progress: progress,
        )
    }

    // MARK: - active progress → the running spinner

    /// An OSC 9;4;3 indeterminate spinner ⇒ `.running` (otherwise the idle row is all-clear).
    func testIndeterminateProgressMapsToRunning() {
        XCTAssertNil(badge(progress: nil), "no progress on an otherwise idle row is all-clear")
        XCTAssertEqual(badge(progress: .indeterminate), .running, "an OSC 9;4;3 spinner ⇒ running")
    }

    /// An OSC 9;4;1;<pct> determinate value ⇒ `.running`, at any percent (0…100; not-yet-cleared still spins).
    func testInProgressDeterminateMapsToRunning() {
        XCTAssertEqual(badge(progress: .determinate(percent: 40)), .running, "an OSC 9;4;1;40 ⇒ running")
        XCTAssertEqual(badge(progress: .determinate(percent: 0)), .running, "even 0% in-progress ⇒ running")
        XCTAssertEqual(badge(progress: .determinate(percent: 100)), .running, "100% (not yet cleared) ⇒ running")
    }

    // MARK: - error progress (state 2) → the error alert

    /// An OSC 9;4;2[;<pct>] held-red error ⇒ `.error`, with or without a held percent.
    func testErrorProgressMapsToError() {
        XCTAssertEqual(badge(progress: .error(percent: 80)), .error, "an OSC 9;4;2;80 ⇒ error")
        XCTAssertEqual(badge(progress: .error(percent: 0)), .error, "an OSC 9;4;2 (no percent) ⇒ error")
    }

    // MARK: - cleared progress falls through to the existing badge

    /// A `nil` progress must not disturb the pre-E14 fused badge — a settled clean completion still shows its
    /// persistent `.finished` accent dot; an otherwise idle row is still all-clear.
    func testClearedProgressFallsThroughToExistingBadge() {
        XCTAssertEqual(
            badge(completion: .success, completionFreshness: .settled, progress: nil),
            .finished, "cleared progress leaves the existing completion badge",
        )
        XCTAssertNil(badge(progress: nil), "cleared progress on an idle row is all-clear")
    }

    // MARK: - precedence

    /// progress-error sits at the ERROR tier — ABOVE a stale completion dot (the carryover requirement that a
    /// held-red `9;4;2` outranks a settled "unread output" marker).
    func testProgressErrorOutranksStaleCompletionDot() {
        XCTAssertEqual(
            badge(completion: .success, completionFreshness: .settled, progress: nil),
            .finished, "baseline: a settled success is the accent dot",
        )
        XCTAssertEqual(
            badge(completion: .success, completionFreshness: .settled, progress: .error(percent: 50)),
            .error, "a held-red OSC 9;4;2 outranks the stale completion dot",
        )
    }

    /// The fixed precedence is preserved around the new input: a running progress spinner outranks a privilege
    /// badge (a running privileged command still spins — active states rank above the caffeinate/sudo badge),
    /// but a failed exit and a blocked agent still outrank it.
    func testProgressRunningKeepsFixedPrecedence() {
        XCTAssertEqual(
            badge(agent: .needsPermission, progress: .indeterminate), .awaitingInput,
            "a blocked agent still outranks a running spinner",
        )
        XCTAssertEqual(
            badge(completion: .failure, progress: .indeterminate), .error,
            "a failed exit still outranks a running spinner",
        )
        XCTAssertEqual(
            badge(foregroundProcess: "sudo", progress: .indeterminate), .running,
            "an active progress spinner outranks the sudo badge (a running privileged command spins)",
        )
    }
}
