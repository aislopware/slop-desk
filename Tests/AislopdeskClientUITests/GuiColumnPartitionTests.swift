// GuiColumnPartitionTests — pins the CLIENT-UI half of the TabSide partition: the GUI column's
// auto-reveal policy (reveal on the first GUI tab, collapse on the last close, honor a manual ⌘⇧E
// within a regime) and the sidebar rail's terminal-side scoping (GUI tabs never mint sidebar rows;
// the ⌘N ordinal counts terminal tabs only).
//
// Headless: a tree-model `WorkspaceStore` over `MountTestPaneSession` (no socket / video / Metal).

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class GuiColumnPartitionTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    // MARK: applyGuiAutoReveal (0↔>0 edges re-assert; manual wins within a regime)

    func testAutoRevealOnFirstGuiTabAndCollapseOnLastClose() {
        let chrome = WorkspaceChromeState()
        XCTAssertTrue(chrome.guiCollapsed, "a fresh window is terminal-first (GUI column collapsed)")

        // First application at 0 tabs: stays collapsed.
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 0, chrome: chrome)
        XCTAssertTrue(chrome.guiCollapsed)

        // 0 → 1: the reveal edge.
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.guiCollapsed, "the first GUI tab reveals the column")

        // 1 → 0: the collapse edge.
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 0, chrome: chrome)
        XCTAssertTrue(chrome.guiCollapsed, "closing the last GUI tab collapses the column")
    }

    func testManualToggleHonoredWithinRegimeButEdgeReasserts() {
        let chrome = WorkspaceChromeState()
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.guiCollapsed)

        // The user hides the column while GUI tabs exist (⌘⇧E) …
        chrome.toggleWindowsPanel()
        XCTAssertTrue(chrome.guiCollapsed)
        // … an unrelated within-regime change (2 tabs, still >0) must NOT fight the manual choice.
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 2, chrome: chrome)
        XCTAssertTrue(chrome.guiCollapsed, "within the >0 regime the manual hide is honored")

        // Crossing to 0 and back re-asserts the auto opinion (manual override cleared on the edge).
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 0, chrome: chrome)
        XCTAssertTrue(chrome.guiCollapsed)
        WorkspaceRootView.applyGuiAutoReveal(guiTabCount: 1, chrome: chrome)
        XCTAssertFalse(chrome.guiCollapsed, "the next 0→>0 edge re-reveals despite the earlier manual hide")
    }

    // MARK: Rail side-scoping (the sidebar is the terminal column's list)

    func testTerminalSideRowsExcludeGuiTabsAndNumberTerminalsOnly() {
        let store = makeStore()
        store.newRemoteWindowTab(windowID: 7, title: "Xcode", appName: "Xcode") // gui tab between terminals
        store.newTab(kind: .terminal, launchGrace: .zero) // terminal #2 (raw index 2)

        let rows = RailRowsBuilder.rows(for: store, side: .terminal)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .terminal }, "no GUI row leaks into the terminal rail")
        XCTAssertEqual(
            rows.map(\.tabNumber), [1, 2],
            "the ⌘N ordinal counts TERMINAL tabs only (the GUI tab at raw index 1 is skipped)",
        )

        // The unscoped build (iOS) still lists everything.
        let allRows = RailRowsBuilder.rows(for: store)
        XCTAssertTrue(allRows.contains { $0.kind == .remoteGUI }, "side nil keeps the GUI rows (iOS shell)")
    }
}
