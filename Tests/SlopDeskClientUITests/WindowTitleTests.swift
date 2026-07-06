// WindowTitleTests — pins `WorkspaceRootView.windowTitle(for:)`, the pure map from the live store to the
// macOS WINDOW title (Window menu / Mission Control / screenshot names). The window used to stay a static
// "Terminal"; the title must now track the FOCUSED pane — its folder-name label (reusing the sidebar's
// `RailRowsBuilder.rowTitle`) and it must change when the active tab/pane changes.
//
// Headless: a tree-model `WorkspaceStore` over the tiny `MountTestPaneSession` fake (no socket / video /
// Metal — the hang-safety rule), exactly like `RailRowBuilderTests`. Each assertion pins a concrete string,
// not `windowTitle`'s own derivation, so none is tautological.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class WindowTitleTests: XCTestCase {
    /// A headless tree-model store over the fake session (one session, one tab, one terminal pane titled
    /// "Terminal"), mirroring `RailRowBuilderTests`.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// The active pane of the store's active session.
    private func activePane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
    }

    /// A fresh terminal pane with no cwd yet reads as the default "Terminal" — the exact stuck state the user
    /// saw. This is the fallback the folder-name / OSC title replaces once one arrives (below).
    func testDefaultPaneTitleBeforeCwd() {
        let store = makeStore()
        XCTAssertEqual(WorkspaceRootView.windowTitle(for: store), "Terminal")
    }

    /// The window title is the ACTIVE pane's cwd FOLDER NAME (the same line-1 label the sidebar row shows) —
    /// not the generic "Terminal". Fails on the pre-fix build (no window-title binding existed).
    func testWindowTitleIsActivePaneFolderName() throws {
        let store = makeStore()
        let pane = try activePane(store)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        XCTAssertEqual(WorkspaceRootView.windowTitle(for: store), "project-alpha")
    }

    /// The core of the report ("không update theo pane"): switching the active tab RE-TITLES the window to the
    /// newly-focused pane. Two tabs at distinct cwds; the title follows `selectTab`.
    func testWindowTitleFollowsActivePaneSwitch() throws {
        let store = makeStore()
        // Tab 0's pane → "alpha".
        let pane0 = try activePane(store)
        store.setLastKnownCwd("/Users/me/alpha", for: pane0)
        // A 2nd tab (now active) → "beta".
        store.newTab(kind: .terminal, launchGrace: .zero)
        let pane1 = try activePane(store)
        store.setLastKnownCwd("/Users/me/beta", for: pane1)

        XCTAssertEqual(
            WorkspaceRootView.windowTitle(for: store), "beta",
            "the window title is the active (2nd) tab's pane",
        )
        store.selectTab(0)
        XCTAssertEqual(
            WorkspaceRootView.windowTitle(for: store), "alpha",
            "switching tabs re-titles the window to the newly-active pane",
        )
    }

    /// An explicit user rename wins over the folder name (the same precedence as the sidebar row), so the
    /// window title honours a renamed pane.
    func testExplicitRenameWinsOverFolderName() throws {
        let store = makeStore()
        let pane = try activePane(store)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        store.renamePane(pane, to: "build box")
        XCTAssertEqual(WorkspaceRootView.windowTitle(for: store), "build box")
    }
}
