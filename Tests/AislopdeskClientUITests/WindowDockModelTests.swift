// WindowDockModelTests — pins the GUI column's dock derivation (`WindowDockModel.items`): open
// remote-window tabs lead (tab order, enriched with the discovery bundleID), remaining host windows
// follow (discovery order), an open tab whose host window vanished keeps a tile, and the letter-avatar
// hue is launch-stable. Headless (macOS-only view code, pure model).

#if os(macOS)
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class WindowDockModelTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    private func summary(_ id: UInt32, app: String, title: String, bundle: String) -> RemoteWindowSummary {
        RemoteWindowSummary(windowID: id, appName: app, title: title, width: 800, height: 600, bundleID: bundle)
    }

    func testOpenTabsLeadAndAreMatchedToHostWindows() throws {
        let store = makeStore()
        store.newRemoteWindowTab(windowID: 7, title: "Xcode — main.swift", appName: "Xcode")
        let session = try XCTUnwrap(store.tree.activeSession)
        let windows = [
            summary(7, app: "Xcode", title: "Xcode — main.swift", bundle: "com.apple.dt.Xcode"),
            summary(9, app: "Safari", title: "Docs", bundle: "com.apple.Safari"),
        ]

        let items = WindowDockModel.items(windows: windows, session: session)
        XCTAssertEqual(items.count, 2, "the open window's host tile is folded into its tab tile (no dup)")
        let open = try XCTUnwrap(items.first)
        XCTAssertTrue(open.isOpen)
        XCTAssertEqual(open.windowID, 7)
        XCTAssertEqual(open.bundleID, "com.apple.dt.Xcode", "the tab tile is enriched with the discovery bundleID")
        let closed = try XCTUnwrap(items.last)
        XCTAssertFalse(closed.isOpen)
        XCTAssertEqual(closed.windowID, 9)
        XCTAssertEqual(closed.title, "Docs")
    }

    func testOpenTabWhoseWindowVanishedKeepsATile() throws {
        let store = makeStore()
        store.newRemoteWindowTab(windowID: 7, title: "Gone Window", appName: "Ghost")
        let session = try XCTUnwrap(store.tree.activeSession)

        let items = WindowDockModel.items(windows: [], session: session)
        XCTAssertEqual(items.count, 1, "an open tab stays reachable even when discovery lists nothing")
        XCTAssertTrue(try XCTUnwrap(items.first).isOpen)
        XCTAssertEqual(items.first?.bundleID, "", "no discovery match ⇒ letter-avatar fallback (empty bundleID)")
    }

    func testUntitledHostWindowFallsBackToAppName() {
        let items = WindowDockModel.items(
            windows: [summary(3, app: "Terminal", title: "", bundle: "com.apple.Terminal")],
            session: nil,
        )
        XCTAssertEqual(items.first?.title, "Terminal", "an untitled window titles its tile by the app name")
    }

    func testStableHueIsDeterministicAndBounded() {
        let a = AppIconResolver.stableHue(for: "Xcode")
        XCTAssertEqual(a, AppIconResolver.stableHue(for: "Xcode"), "the avatar hue must not change per launch")
        for name in ["Xcode", "Safari", "", "アプリ"] {
            let hue = AppIconResolver.stableHue(for: name)
            XCTAssertTrue(hue >= 0 && hue < 1, "hue \(hue) for \(name) is in 0..<1")
        }
    }
}
#endif
