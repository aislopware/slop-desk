// SlateEmptyStateTests — pins the typed empty-state COPY (cause → symbol/title/caption/action), so
// the pane area's "nothing here" wording cannot drift per call site.
//
// The status → cause RESOLUTION moved out with the cause: it is `PaneEmptyCause.resolve` now, pinned
// by `Tests/SlopDeskClientCoreTests/PaneCanvasPolicyTests.swift`. That split is the point rather than
// tidiness — the verdict runs on a phone build too, and only the wording is this renderer's.

import SlopDeskClientCore
import SlopDeskSlate
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class SlateEmptyStateTests: XCTestCase {
    func testPinnedCopyPerCause() {
        XCTAssertEqual(SlateEmptyState.title(for: .neverConnected), "Not Connected")
        XCTAssertEqual(SlateEmptyState.caption(for: .neverConnected), "Connect to a host to open a terminal.")
        XCTAssertEqual(SlateEmptyState.actionLabel(for: .neverConnected), "Connect to Host…")

        XCTAssertEqual(SlateEmptyState.title(for: .linkDown(host: "mac-studio")), "Connection Lost")
        XCTAssertEqual(SlateEmptyState.caption(for: .linkDown(host: "mac-studio")), "Reconnecting to mac-studio…")
        // Link-down redials itself — offering a button would suggest the user must act.
        XCTAssertNil(SlateEmptyState.actionLabel(for: .linkDown(host: "mac-studio")))

        XCTAssertEqual(SlateEmptyState.title(for: .noTabs), "No Open Tabs")
        XCTAssertEqual(SlateEmptyState.actionLabel(for: .noTabs), "New Tab")

        // Connect-failed names the REAL reason verbatim and re-offers the Connect editor.
        XCTAssertEqual(SlateEmptyState.title(for: .connectFailed(reason: "Connection refused")), "Connect Failed")
        XCTAssertEqual(SlateEmptyState.caption(for: .connectFailed(reason: "Connection refused")), "Connection refused")
        XCTAssertEqual(
            SlateEmptyState.actionLabel(for: .connectFailed(reason: "Connection refused")),
            "Connect to Host…",
        )
    }
}
