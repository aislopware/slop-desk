// SlateEmptyStateTests — pins the typed empty-state copy (cause → symbol/title/caption/action) and
// the ContentColumn's status → cause resolution, so the pane area's "nothing here" wording can't
// drift per call site and a give-up state never renders the self-healing "Reconnecting…" caption.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

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

    func testEmptyCauseResolution() {
        XCTAssertEqual(ContentColumn.emptyCause(status: .connected, host: "h"), .noTabs)
        XCTAssertEqual(
            ContentColumn.emptyCause(status: .reconnecting(attempt: 2, nextRetry: nil), host: "mac-studio"),
            .linkDown(host: "mac-studio"),
        )
        // Fresh launch, in-flight first dial, and unreachable all read not-connected (whose action
        // opens the Connect editor) — never the self-healing "Reconnecting…" caption.
        XCTAssertEqual(ContentColumn.emptyCause(status: .disconnected, host: "h"), .neverConnected)
        XCTAssertEqual(ContentColumn.emptyCause(status: .connecting, host: "h"), .neverConnected)
        XCTAssertEqual(ContentColumn.emptyCause(status: .unreachable, host: "h"), .neverConnected)
        // An explicit failed connect keeps its reason — it must NOT fold into the generic copy.
        // Unknown payloads pass through verbatim; known transport dumps arrive already run through
        // `ConnectionPresenter.friendlyFailure` (the same voice as the status pill).
        XCTAssertEqual(
            ContentColumn.emptyCause(status: .failed("boom"), host: "h"),
            .connectFailed(reason: "boom"),
        )
        XCTAssertEqual(
            ContentColumn.emptyCause(status: .failed("POSIXErrorCode(rawValue: 61): Connection refused"), host: "h"),
            .connectFailed(reason: "Connection refused — is slopdesk-hostd running on the host?"),
        )
    }
}
