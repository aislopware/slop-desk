// PaneEmptyCopyTests — pins the typed empty-state COPY (cause → symbol/title/caption/action), so the
// pane area's "nothing here" wording cannot drift per call site OR per renderer.
//
// It was `SlateEmptyStateTests` in `SlopDeskClientUITests` until R12, and it followed the tables down:
// the four are `String`-valued and frameworkless, so they descended to the floor both canvases read
// instead of being pinned as a cross-renderer pair (docs/56 §3, P6). The status → cause RESOLUTION
// already lived here — `PaneEmptyCause.resolve`, pinned by `PaneCanvasPolicyTests`.

import XCTest
@testable import SlopDeskClientCore

final class PaneEmptyCopyTests: XCTestCase {
    func testPinnedCopyPerCause() {
        XCTAssertEqual(PaneEmptyCause.neverConnected.title, "Not Connected")
        XCTAssertEqual(PaneEmptyCause.neverConnected.caption, "Connect to a host to open a terminal.")
        XCTAssertEqual(PaneEmptyCause.neverConnected.actionLabel, "Connect to Host…")
        XCTAssertEqual(PaneEmptyCause.neverConnected.symbolName, "bolt.horizontal")

        XCTAssertEqual(PaneEmptyCause.linkDown(host: "mac-studio").title, "Connection Lost")
        XCTAssertEqual(PaneEmptyCause.linkDown(host: "mac-studio").caption, "Reconnecting to mac-studio…")
        // Link-down redials itself — offering a button would suggest the user must act.
        XCTAssertNil(PaneEmptyCause.linkDown(host: "mac-studio").actionLabel)

        XCTAssertEqual(PaneEmptyCause.noTabs.title, "No Open Tabs")
        XCTAssertEqual(PaneEmptyCause.noTabs.caption, "Open a tab to get started.")
        XCTAssertEqual(PaneEmptyCause.noTabs.actionLabel, "New Tab")

        // Connect-failed names the REAL reason verbatim and re-offers the Connect editor.
        let failed = PaneEmptyCause.connectFailed(reason: "Connection refused")
        XCTAssertEqual(failed.title, "Connect Failed")
        XCTAssertEqual(failed.caption, "Connection refused")
        XCTAssertEqual(failed.actionLabel, "Connect to Host…")
    }

    /// Every cause names a symbol, and no two causes share one — the glyph is part of the distinction
    /// the copy is spent making, so a copy-paste that left two causes on `terminal` must be loud.
    func testEverySymbolIsDistinct() {
        let causes: [PaneEmptyCause] = [
            .neverConnected, .linkDown(host: "h"), .noTabs, .connectFailed(reason: "r"),
        ]
        let symbols = causes.map(\.symbolName)
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        XCTAssertEqual(Set(symbols).count, causes.count)
    }
}
