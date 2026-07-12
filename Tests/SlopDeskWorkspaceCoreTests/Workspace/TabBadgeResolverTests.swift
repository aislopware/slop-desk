import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// Tests for ``TabBadgeResolver`` — the PURE fusion policy that collapses the four
/// per-pane badge signals into the single ``TabBadgeKind`` a sidebar tab row shows. The contract is a
/// **fixed precedence** (most-urgent wins, distilled from `progress-state.md` + `parallel-tasks.md`):
///
/// ```
/// awaitingInput  >  error  >  running  >  sudo  >  caffeinate  >  completed/finished  >  nil
/// ```
///
/// Headless: no SwiftUI, no clock, no socket — `badge(...)` is a pure static over plain values.
final class TabBadgeResolverTests: XCTestCase {
    /// Convenience all-clear caller; each test overrides only the axes it exercises.
    private func badge(
        agent: ClaudeStatus = .none,
        completion: PaneCompletionBadge? = nil,
        isBusy: Bool = false,
        foregroundProcess: String? = nil,
        completionFreshness: TabBadgeResolver.CompletionFreshness = .settled,
        progress: PaneProgress? = nil,
    ) -> TabBadgeKind? {
        TabBadgeResolver.badge(
            agent: agent,
            completion: completion,
            isBusy: isBusy,
            foregroundProcess: foregroundProcess,
            completionFreshness: completionFreshness,
            progress: progress,
        )
    }

    // MARK: - Per-signal mapping

    /// A blocked agent ⇒ the hand (awaiting input) — the most-urgent state.
    func testNeedsPermissionMapsToAwaitingInput() {
        XCTAssertEqual(badge(agent: .needsPermission), .awaitingInput)
    }

    /// A failed command ⇒ the alert triangle (error).
    func testFailureCompletionMapsToError() {
        XCTAssertEqual(badge(completion: .failure), .error)
    }

    /// A merely-busy shell ⇒ the bare static busy dot (`.commandBusy`, no spinner); an explicit OSC 9;4
    /// progress report ⇒ the spinner marker (`.commandRunning`), which outranks the busy dot — the ring
    /// is earned by an explicit progress report.
    func testBusyShellIsBareDotProgressIsSpinner() {
        XCTAssertEqual(badge(isBusy: true), .commandBusy)
        XCTAssertEqual(badge(isBusy: true, progress: .indeterminate), .commandRunning)
    }

    /// A working agent ⇒ the loud agent badge (`.running`), even with no shell-busy bit.
    func testWorkingAgentMapsToRunning() {
        XCTAssertEqual(badge(agent: .working), .running)
    }

    /// A working agent OUTRANKS a coexisting busy shell — the pane shows the loud agent badge, not the quiet
    /// command marker.
    func testWorkingAgentBeatsBusyShell() {
        XCTAssertEqual(badge(agent: .working, isBusy: true), .running)
    }

    /// A FRESH clean exit ⇒ the checkmark (completed) — the brief success flash, while the caller still
    /// reports the completion `.fresh`.
    func testFreshSuccessCompletionMapsToCompleted() {
        XCTAssertEqual(badge(completion: .success, completionFreshness: .fresh), .completed)
    }

    /// A SETTLED clean exit ⇒ the accent dot (finished) — the persistent "unread output" marker once the
    /// flash decays. This exercises the `.finished` state, which is otherwise unreachable: a resolver that
    /// maps BOTH freshness states to `.completed` FAILS this assertion (revert-to-confirm-fail), so it is
    /// not tautological.
    func testSettledSuccessCompletionMapsToFinished() {
        XCTAssertEqual(badge(completion: .success, completionFreshness: .settled), .finished)
    }

    /// A FRESH agent turn-finish (`done`) ⇒ completed (the brief task-complete checkmark).
    func testFreshDoneAgentMapsToCompleted() {
        XCTAssertEqual(badge(agent: .done, completionFreshness: .fresh), .completed)
    }

    /// A SETTLED idle/done agent that is still unread ⇒ the accent dot (finished) — a dot when the agent goes
    /// idle. Also fails on a resolver that maps both freshness states to `.completed` (revert-to-confirm-fail).
    func testSettledDoneAgentMapsToFinished() {
        XCTAssertEqual(badge(agent: .done, completionFreshness: .settled), .finished)
    }

    /// The default freshness is `.settled` (the persistent marker): an un-stamped clean completion
    /// resolves to the accent dot, not a perpetual checkmark.
    func testDefaultFreshnessIsSettledFinished() {
        XCTAssertEqual(badge(completion: .success), .finished)
        XCTAssertEqual(badge(agent: .done), .finished)
    }

    /// All-clear ⇒ no badge.
    func testAllClearIsNil() {
        XCTAssertNil(badge())
    }

    /// An at-rest agent (`idle`) on its own contributes no badge.
    func testIdleAgentIsNil() {
        XCTAssertNil(badge(agent: .idle))
    }

    // MARK: - Privilege classification (basename allow-set, validate-then-default)

    /// `sudo` foreground ⇒ the shield, but only when the shell is at rest.
    func testSudoForegroundMapsToSudo() {
        XCTAssertEqual(badge(foregroundProcess: "sudo"), .sudo)
    }

    /// `su` foreground ⇒ the shield (the privilege allow-set is {sudo, su}).
    func testSuForegroundMapsToSudo() {
        XCTAssertEqual(badge(foregroundProcess: "su"), .sudo)
    }

    /// `caffeinate` foreground ⇒ the coffee cup, when the shell is at rest.
    func testCaffeinateForegroundMapsToCaffeinate() {
        XCTAssertEqual(badge(foregroundProcess: "caffeinate"), .caffeinate)
    }

    /// Classification is on the **basename**: a full path resolves to its last component.
    func testFullPathBasenameClassifies() {
        XCTAssertEqual(badge(foregroundProcess: "/usr/bin/sudo"), .sudo)
        XCTAssertEqual(badge(foregroundProcess: "/usr/bin/caffeinate"), .caffeinate)
    }

    /// Basename match is case-insensitive (lowercased compare).
    func testBasenameIsCaseInsensitive() {
        XCTAssertEqual(badge(foregroundProcess: "SUDO"), .sudo)
        XCTAssertEqual(badge(foregroundProcess: "Caffeinate"), .caffeinate)
    }

    /// Surrounding whitespace is trimmed before classifying.
    func testForegroundWhitespaceTrimmed() {
        XCTAssertEqual(badge(foregroundProcess: "  sudo\n"), .sudo)
    }

    /// An UNKNOWN process ⇒ no privilege badge (validate-then-default), never a partial `contains` match.
    func testUnknownProcessYieldsNoPrivilegeBadge() {
        XCTAssertNil(badge(foregroundProcess: "zsh"))
        // `contains` would misfire here; an exact-basename allow-set must not.
        XCTAssertNil(badge(foregroundProcess: "sudoedit"))
        XCTAssertNil(badge(foregroundProcess: "pseudo"))
    }

    /// A `nil` / empty / all-slashes process ⇒ no privilege badge, no crash (no force-unwrap).
    func testEmptyOrNilProcessYieldsNoBadge() {
        XCTAssertNil(badge(foregroundProcess: nil))
        XCTAssertNil(badge(foregroundProcess: ""))
        XCTAssertNil(badge(foregroundProcess: "   "))
        XCTAssertNil(badge(foregroundProcess: "/"))
        XCTAssertNil(badge(foregroundProcess: "///"))
    }

    // MARK: - Fixed precedence (most-urgent wins)

    /// Awaiting input beats EVERYTHING below it (error, running, privilege, completed).
    func testAwaitingInputWinsOverAll() {
        XCTAssertEqual(
            badge(
                agent: .needsPermission,
                completion: .failure,
                isBusy: true,
                foregroundProcess: "sudo",
            ),
            .awaitingInput,
        )
    }

    /// Error beats running, privilege, and completed (but loses to awaiting input, tested above).
    func testErrorWinsOverRunningPrivilegeCompleted() {
        XCTAssertEqual(
            badge(
                agent: .working, // would be running
                completion: .failure,
                isBusy: true,
                foregroundProcess: "sudo",
            ),
            .error,
        )
        // A failure also beats a coexisting success-shaped state.
        XCTAssertEqual(badge(completion: .failure, foregroundProcess: "caffeinate"), .error)
    }

    /// The activity tiers beat privilege + completed: a working agent, an OSC 9;4 progress, and the plain
    /// busy dot all rank above the shield/cup and a stale completion (a running `sudo …` shows activity,
    /// not the privilege badge — Design #5).
    func testActivityWinsOverPrivilegeAndCompleted() {
        XCTAssertEqual(badge(agent: .working, foregroundProcess: "caffeinate"), .running)
        XCTAssertEqual(badge(isBusy: true, foregroundProcess: "sudo", progress: .indeterminate), .commandRunning)
        XCTAssertEqual(badge(isBusy: true, foregroundProcess: "sudo"), .commandBusy)
        XCTAssertEqual(badge(completion: .success, isBusy: true), .commandBusy)
    }

    /// Sudo beats caffeinate and completed — but ONLY when the shell is at rest.
    func testSudoWinsOverCaffeinateAndCompletedAtRest() {
        // `sudo` outranks a coexisting clean completion when not busy.
        XCTAssertEqual(badge(completion: .success, foregroundProcess: "sudo"), .sudo)
    }

    /// Caffeinate beats completed when the shell is at rest.
    func testCaffeinateWinsOverCompletedAtRest() {
        XCTAssertEqual(badge(completion: .success, foregroundProcess: "caffeinate"), .caffeinate)
        XCTAssertEqual(badge(agent: .done, foregroundProcess: "caffeinate"), .caffeinate)
    }

    /// The privilege badges sit BELOW every activity tier: a busy shell with a `caffeinate`/`sudo`
    /// foreground shows the busy dot (or the progress spinner), never collapsing to the cup/shield while
    /// work is in flight.
    func testPrivilegeBadgesSuppressedWhileBusy() {
        XCTAssertEqual(badge(isBusy: true, foregroundProcess: "caffeinate", progress: .indeterminate), .commandRunning)
        XCTAssertEqual(badge(isBusy: true, foregroundProcess: "caffeinate"), .commandBusy)
        XCTAssertEqual(badge(isBusy: true, foregroundProcess: "sudo"), .commandBusy)
    }
}
