// CloseConfirmationCopyTests — E7 carry-over #4. The in-app close confirmation hardcoded the subtitle
// "A process is still running. Closing it will stop the command." — FALSE for the `always` / `multiple_tabs`
// close-confirmation policies (an idle shell / a >1-tab window has no running process). These pin the PURE
// `CloseConfirmationCopy` branches both dialogs print, so the subtitle reads accurately per the resolved
// policy + close scope. No dialog is instantiated — the copy is pure static functions (hang-safe). FAILS on
// the pre-fix code (no `reason` function existed; the subtitle was a constant).
//
// Pinned in `SlopDeskClientCoreTests` since docs/56 stage D: the Mac raises an `NSAlert` and the phone a
// SwiftUI `.alert`, and the wording is the one thing between them — three branches and a join, which is
// exactly the amount of logic that drifts when two halves each carry it.

import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class CloseConfirmationCopyTests: XCTestCase {
    func testProcessPolicyNamesTheRunningCommand() {
        XCTAssertEqual(
            CloseConfirmationCopy.reason(for: .process),
            "A process is still running. Closing it will stop the command.",
        )
    }

    func testAlwaysPolicyAsksPlainlyScopedToTab() {
        XCTAssertEqual(
            CloseConfirmationCopy.reason(for: .always), // default scope = .tab
            "Are you sure you want to close this tab?",
        )
    }

    func testAlwaysPolicyScopedToPaneSaysPane() {
        XCTAssertEqual(
            CloseConfirmationCopy.reason(for: .always, scope: .pane),
            "Are you sure you want to close this pane?",
        )
    }

    func testMultipleTabsPolicyWarnsAboutTheTabs() {
        XCTAssertEqual(
            CloseConfirmationCopy.reason(for: .multipleTabs),
            "This window has multiple tabs.",
        )
    }

    // MARK: - the project-loss warning line (a project's last pane / tab)

    func testProjectCloseReasonNamesTheProjectScopedToPane() {
        XCTAssertEqual(
            CloseConfirmationCopy.projectCloseReason(project: "alpha", scope: .pane),
            "This is the last pane of “alpha”. Closing it will close the project.",
        )
    }

    func testProjectCloseReasonScopedToTabSaysTab() {
        XCTAssertEqual(
            CloseConfirmationCopy.projectCloseReason(project: "alpha", scope: .tab),
            "This is the last tab of “alpha”. Closing it will close the project.",
        )
    }

    /// The three policy branches must produce DISTINCT copy — the bug was a single hardcoded subtitle for all
    /// policies. (A non-tautological discriminator: the old panel could not pass this — there was no branch.)
    func testEachPolicyHasDistinctCopy() {
        let process = CloseConfirmationCopy.reason(for: .process)
        let always = CloseConfirmationCopy.reason(for: .always)
        let multiple = CloseConfirmationCopy.reason(for: .multipleTabs)
        XCTAssertNotEqual(process, always)
        XCTAssertNotEqual(process, multiple)
        XCTAssertNotEqual(always, multiple)
    }

    // MARK: - the assembled dialog (title + the join both halves print)

    /// A parked PANE close names the leaf it would take; an untitled pane is named generically rather
    /// than with a pair of empty quotes, and a parked TAB close has no leaf to name at all.
    func testTitleNamesThePaneAndFallsBackHonestly() {
        XCTAssertEqual(CloseConfirmationCopy.title(request(paneTitle: "build")), "Close “build”?")
        XCTAssertEqual(CloseConfirmationCopy.title(request(paneTitle: "")), "Close this pane?")
        XCTAssertEqual(
            CloseConfirmationCopy.title(request(scope: .tab, paneTitle: nil)), "Close this tab?",
        )
    }

    /// BOTH lines when both apply — a busy shell that is also its project's last pane. This is the join
    /// that used to live in the phone's view and could not be reached from the Mac's alert at all.
    func testBothLinesAppearWhenBothApply() {
        let message = CloseConfirmationCopy.message(request(paneTitle: "build", project: "alpha"))
        XCTAssertTrue(message.contains("A process is still running"))
        XCTAssertTrue(message.contains("This is the last pane of “alpha”"))
    }

    /// A park raised ONLY for the project-loss warning must not claim a process is running over an idle
    /// shell — the whole reason `policyGated` is a separate fact from the policy itself.
    func testAnUngatedParkPrintsOnlyTheProjectLine() {
        let message = CloseConfirmationCopy.message(
            request(paneTitle: "idle", policyGated: false, project: "alpha"),
        )
        XCTAssertFalse(message.contains("A process is still running"))
        XCTAssertEqual(message, "This is the last pane of “alpha”. Closing it will close the project.")
    }

    /// A park that matches NEITHER gate — both are resolved live, so either can decay while the dialog is
    /// up — still prints the policy line rather than an empty body.
    func testAParkThatMatchesNeitherGateStillSaysSomething() {
        let message = CloseConfirmationCopy.message(request(paneTitle: "idle", policyGated: false))
        XCTAssertEqual(message, "A process is still running. Closing it will stop the command.")
    }

    private func request(
        scope: CloseScope = .pane,
        paneTitle: String?,
        policyGated: Bool = true,
        policy: CloseConfirmationPolicy? = .process,
        project: String? = nil,
    ) -> CloseConfirmationCopy.Request {
        CloseConfirmationCopy.Request(
            scope: scope, paneTitle: paneTitle, policyGated: policyGated, policy: policy,
            projectName: project,
        )
    }
}
