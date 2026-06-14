import XCTest
@testable import AislopdeskClientUI

/// Pure-logic tests for the PATH 2 ``RemoteWindowModel``: field parsing, the `canOpen` gate,
/// and that `open()` builds a complete-endpoint ``RemoteWindowDescriptor`` (so the app factory
/// takes the LIVE `VideoWindowView(title:connection:)` path). No video frameworks involved.
@MainActor
final class RemoteWindowModelTests: XCTestCase {
    /// The host + UDP ports now come from the app-global ``ConnectionTarget``; only the windowID is
    /// per-pane, so `canOpen` is purely "is the window id parseable".
    private let target = ConnectionTarget(host: "h.local", port: 7420, mediaPort: 9000, cursorPort: 9001)

    func testCanOpenRequiresWindowID() {
        let m = RemoteWindowModel(target: { self.target }) // empty windowID
        XCTAssertFalse(m.canOpen)
        m.windowID = "12345"
        XCTAssertTrue(m.canOpen, "a valid window id ⇒ can open (host/ports come from the app target)")
    }

    func testCanOpenRejectsUnparseableWindowID() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "notanumber")
        XCTAssertFalse(m.canOpen)
        m.windowID = "1"
        XCTAssertTrue(m.canOpen)
    }

    func testOpenBuildsDescriptorFromAppTarget() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "42", title: "Safari")
        m.open()
        guard let d = m.active else { XCTFail("open() should set active")
            return
        }
        XCTAssertEqual(d.windowID, 42)
        XCTAssertEqual(d.host, "h.local", "host comes from the app target")
        XCTAssertEqual(d.mediaPort, 9000)
        XCTAssertEqual(d.cursorPort, 9001)
        XCTAssertEqual(d.title, "Safari")
        XCTAssertTrue(d.hasEndpoint, "descriptor carries a live endpoint ⇒ factory takes live path")
    }

    func testOpenWithInvalidWindowIDIsNoOp() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "x")
        m.open()
        XCTAssertNil(m.active)
    }

    func testEmptyTitleFallsBackToWindowID() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "7", title: "")
        m.open()
        XCTAssertEqual(m.active?.title, "window 7")
    }

    func testCloseClearsActive() {
        let m = RemoteWindowModel(target: { self.target }, windowID: "1")
        m.open()
        XCTAssertNotNil(m.active)
        m.close()
        XCTAssertNil(m.active)
    }

    func testTitleOnlyDescriptorHasNoEndpoint() {
        // The placeholder/preview path: a descriptor with no host is NOT live.
        let d = RemoteWindowDescriptor(title: "x", windowID: 3)
        XCTAssertFalse(d.hasEndpoint)
    }

    // MARK: - Picker discovery (docs/31) — the refresh()/pick() state machine via the injected seam

    /// `RemoteWindowDiscovery.shared` is a process-global static — reset it after every test so a stub
    /// set here never bleeds into another test (or the app's AppMain wiring).
    override func tearDown() {
        RemoteWindowDiscovery.shared = nil
        super.tearDown()
    }

    func testRefreshWithNoSeamSurfacesUnavailable() async {
        RemoteWindowDiscovery.shared = nil
        let m = RemoteWindowModel(target: { self.target })
        await m.refresh()
        XCTAssertTrue(m.availableWindows.isEmpty)
        XCTAssertFalse(m.isLoading)
        XCTAssertEqual(m.loadError, "Window discovery is unavailable — enter a window id manually.")
    }

    func testRefreshEmptyResultSurfacesNoWindows() async {
        RemoteWindowDiscovery.shared = { _, _, _ in [] }
        let m = RemoteWindowModel(target: { self.target })
        await m.refresh()
        XCTAssertTrue(m.availableWindows.isEmpty)
        XCTAssertFalse(m.isLoading)
        XCTAssertNotNil(m.loadError, "an empty list surfaces the 'no windows' hint (+ manual fallback)")
    }

    func testRefreshPopulatesAvailableWindows() async {
        let rows = [
            RemoteWindowSummary(windowID: 604, appName: "Google Chrome", title: "Claude", width: 1800, height: 943),
            RemoteWindowSummary(windowID: 464, appName: "Ghostty", title: "", width: 1408, height: 889),
        ]
        RemoteWindowDiscovery.shared = { host, media, cursor in
            XCTAssertEqual(host, "h.local")
            XCTAssertEqual(media, 9000)
            XCTAssertEqual(cursor, 9001)
            return rows
        }
        let m = RemoteWindowModel(target: { self.target })
        await m.refresh()
        XCTAssertEqual(m.availableWindows, rows, "the seam result populates the picker, queried with the app target")
        XCTAssertNil(m.loadError)
        XCTAssertFalse(m.isLoading)
    }

    func testPickFillsWindowIDAndTitleWithAppNameFallback() {
        let m = RemoteWindowModel(target: { self.target })
        m.pick(RemoteWindowSummary(windowID: 42, appName: "Safari", title: "Apple", width: 100, height: 50))
        XCTAssertEqual(m.windowID, "42")
        XCTAssertEqual(m.title, "Apple")
        XCTAssertTrue(m.canOpen, "a picked row makes the pane openable")

        m.pick(RemoteWindowSummary(windowID: 7, appName: "Finder", title: "", width: 100, height: 50))
        XCTAssertEqual(m.windowID, "7")
        XCTAssertEqual(m.title, "Finder", "an empty window title falls back to the app name")
        XCTAssertEqual(m.appName, "Finder", "pick records the owning app (PANE REBIND)")
    }

    // MARK: - PANE REBIND (2026-06-12): endpoint commit + stale-binding revalidation

    func testOpenCommitsEndpointWithAppName() {
        let m = RemoteWindowModel(target: { self.target })
        var committed: VideoEndpoint?
        m.onEndpointCommitted = { committed = $0 }
        m.pick(RemoteWindowSummary(windowID: 42, appName: "Safari", title: "Apple", width: 100, height: 50))
        m.open()
        XCTAssertEqual(
            committed,
            VideoEndpoint(windowID: 42, title: "Apple", appName: "Safari"),
            "open() persists the binding (app+title travel with the id)",
        )
    }

    func testRevalidateKeepsLiveBinding() async {
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 58, appName: "Code", title: "main.swift", width: 100, height: 50)]
        }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "main.swift", appName: "Code")
        m.open()
        let outcome = await m.revalidateBinding()
        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(m.active?.windowID, 58, "a valid binding streams untouched")
    }

    func testRevalidateRebindsStaleIDAndRecommits() async {
        RemoteWindowDiscovery.shared = { _, _, _ in
            [RemoteWindowSummary(windowID: 77, appName: "Code", title: "new.swift — proj", width: 100, height: 50)]
        }
        // Restored binding: id 58 died with the host restart; 77 is the same app's window now.
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "old.swift — proj", appName: "Code")
        var committed: VideoEndpoint?
        m.onEndpointCommitted = { committed = $0 }
        m.open()
        let outcome = await m.revalidateBinding()
        XCTAssertEqual(outcome, .rebound)
        XCTAssertEqual(m.active?.windowID, 77, "the pane re-opened on the rebound window")
        XCTAssertEqual(committed?.windowID, 77, "the healed binding is persisted (stale id overwritten)")
        XCTAssertEqual(committed?.appName, "Code")
    }

    func testRevalidateUnbindsWhenAppGone() async {
        let rows = [RemoteWindowSummary(windowID: 9, appName: "Safari", title: "Apple", width: 100, height: 50)]
        RemoteWindowDiscovery.shared = { _, _, _ in rows }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "main.swift", appName: "Code")
        m.open()
        let outcome = await m.revalidateBinding()
        XCTAssertEqual(outcome, .unbound)
        XCTAssertNil(m.active, "no window of that app remains — back to the picker form")
        XCTAssertEqual(m.availableWindows, rows, "the picker is pre-warmed with the fetched list")
        XCTAssertNotNil(m.loadError, "the form explains why the pane fell back")
    }

    func testRevalidateSkipsOnUnreachableHostOrNoSeam() async {
        // Empty list (host unreachable / discovery timeout): NOT evidence of staleness.
        RemoteWindowDiscovery.shared = { _, _, _ in [] }
        let m = RemoteWindowModel(target: { self.target }, windowID: "58", title: "t", appName: "Code")
        m.open()
        let unreachable = await m.revalidateBinding()
        XCTAssertEqual(unreachable, .skipped)
        XCTAssertEqual(m.active?.windowID, 58, "an unreachable host changes nothing")

        RemoteWindowDiscovery.shared = nil
        let noSeam = await m.revalidateBinding()
        XCTAssertEqual(noSeam, .skipped, "no seam ⇒ no-op")
    }
}

// MARK: - Picker filter (RemoteWindowModel.filtered — pure)

/// Pins the picker's filter-field policy: token-AND, case-insensitive, over title + app name.
@MainActor
final class RemoteWindowFilterTests: XCTestCase {
    private let windows = [
        RemoteWindowSummary(
            windowID: 1,
            appName: "Google Chrome",
            title: "Claude — research",
            width: 1800,
            height: 943,
        ),
        RemoteWindowSummary(windowID: 2, appName: "Ghostty", title: "", width: 1408, height: 889),
        RemoteWindowSummary(
            windowID: 3,
            appName: "Xcode",
            title: "Aislopdesk — WorkspaceStore.swift",
            width: 1600,
            height: 1000,
        ),
        RemoteWindowSummary(
            windowID: 4,
            appName: "Google Chrome",
            title: "GitHub — aislopdesk",
            width: 1280,
            height: 800,
        ),
    ]

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "").map(\.windowID), [1, 2, 3, 4])
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "   ").map(\.windowID), [1, 2, 3, 4])
    }

    func testMatchesTitleAndAppNameCaseInsensitively() {
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "claude").map(\.windowID), [1])
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "CHROME").map(\.windowID), [1, 4])
        XCTAssertEqual(
            RemoteWindowModel.filtered(windows, query: "ghostty").map(\.windowID),
            [2],
            "an empty title still matches via the app name",
        )
    }

    func testMultiTokenIsANDAcrossTitleAndApp() {
        XCTAssertEqual(RemoteWindowModel.filtered(windows, query: "chrome github").map(\.windowID), [4])
        XCTAssertTrue(RemoteWindowModel.filtered(windows, query: "chrome xcode").isEmpty)
    }

    func testFilterEmptyMessageIsActionable() {
        // The empty-list message names the filter AND tells the user there ARE windows behind it (the list
        // only renders when discovery found ≥1), with the fix (clear the filter) and correct pluralization.
        let many = RemoteWindowModel.windowFilterEmptyMessage(filter: "xcode", totalCount: 4)
        XCTAssertTrue(many.contains("“xcode”"), "names the filter token")
        XCTAssertTrue(many.contains("clear the filter"), "points at the fix")
        XCTAssertTrue(many.contains("4 windows"), "tells the user how many windows the filter hid")

        let one = RemoteWindowModel.windowFilterEmptyMessage(filter: "  xcode  ", totalCount: 1)
        XCTAssertTrue(one.contains("“xcode”"), "the filter is trimmed before display")
        XCTAssertTrue(one.contains("1 window."), "singular when exactly one window is hidden")
    }
}
