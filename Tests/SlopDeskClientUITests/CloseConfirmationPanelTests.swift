// CloseConfirmationPanelTests — E7 carry-over #4. The in-app close-confirmation panel hardcoded the subtitle
// "A process is still running. Closing it will stop the command." — FALSE for the `always` / `multiple_tabs`
// close-confirmation policies (an idle shell / a >1-tab window has no running process). These pin the PURE
// `CloseConfirmationPanel.reason(for:scope:)` branch the host now feeds the panel, so the subtitle reads
// accurately per the resolved policy + close scope. No view is instantiated — `reason` is a pure static
// function (hang-safe). FAILS on the pre-fix code (no `reason` function existed; the subtitle was a constant).

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

final class CloseConfirmationPanelTests: XCTestCase {
    func testProcessPolicyNamesTheRunningCommand() {
        XCTAssertEqual(
            CloseConfirmationPanel.reason(for: .process),
            "A process is still running. Closing it will stop the command.",
        )
    }

    func testAlwaysPolicyAsksPlainlyScopedToTab() {
        XCTAssertEqual(
            CloseConfirmationPanel.reason(for: .always), // default scope = .tab
            "Are you sure you want to close this tab?",
        )
    }

    func testAlwaysPolicyScopedToPaneSaysPane() {
        XCTAssertEqual(
            CloseConfirmationPanel.reason(for: .always, scope: .pane),
            "Are you sure you want to close this pane?",
        )
    }

    func testMultipleTabsPolicyWarnsAboutTheTabs() {
        XCTAssertEqual(
            CloseConfirmationPanel.reason(for: .multipleTabs),
            "This window has multiple tabs.",
        )
    }

    /// The three policy branches must produce DISTINCT copy — the bug was a single hardcoded subtitle for all
    /// policies. (A non-tautological discriminator: the old panel could not pass this — there was no branch.)
    func testEachPolicyHasDistinctCopy() {
        let process = CloseConfirmationPanel.reason(for: .process)
        let always = CloseConfirmationPanel.reason(for: .always)
        let multiple = CloseConfirmationPanel.reason(for: .multipleTabs)
        XCTAssertNotEqual(process, always)
        XCTAssertNotEqual(process, multiple)
        XCTAssertNotEqual(always, multiple)
    }
}
#endif
