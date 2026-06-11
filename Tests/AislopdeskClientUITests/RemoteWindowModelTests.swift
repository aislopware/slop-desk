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
        let m = RemoteWindowModel(target: { self.target })   // empty windowID
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
        guard let d = m.active else { return XCTFail("open() should set active") }
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
            XCTAssertEqual(host, "h.local"); XCTAssertEqual(media, 9000); XCTAssertEqual(cursor, 9001)
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
    }
}
