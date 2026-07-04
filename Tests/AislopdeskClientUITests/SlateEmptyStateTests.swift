// SlateEmptyStateTests — pins the typed empty-state copy (cause → symbol/title/caption/action) and
// the ContentColumn's status → cause resolution, so the pane area's "nothing here" wording can't
// drift per call site and a give-up state never renders the self-healing "Reconnecting…" caption.

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

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
    }

    func testEmptyCauseResolution() {
        XCTAssertEqual(ContentColumn.emptyCause(status: .connected, host: "h"), .noTabs)
        XCTAssertEqual(
            ContentColumn.emptyCause(status: .reconnecting(attempt: 2, nextRetry: nil), host: "mac-studio"),
            .linkDown(host: "mac-studio"),
        )
        // Fresh launch, in-flight first dial, and the give-up states all read not-connected (whose
        // action opens the Connect editor) — never the self-healing "Reconnecting…" caption.
        XCTAssertEqual(ContentColumn.emptyCause(status: .disconnected, host: "h"), .neverConnected)
        XCTAssertEqual(ContentColumn.emptyCause(status: .connecting, host: "h"), .neverConnected)
        XCTAssertEqual(ContentColumn.emptyCause(status: .unreachable, host: "h"), .neverConnected)
        XCTAssertEqual(ContentColumn.emptyCause(status: .failed("boom"), host: "h"), .neverConnected)
    }
}
