// NavigatorColumnSelectTests — pins the pane→tab resolution the sidebar rail uses when a row is
// clicked (`NavigatorColumn.owningTabIndex(of:in:)`, the seam `NavigatorColumn.select` calls) and the
// badge auto-clear that rides the row-click path.
//
// Headless: a tree-model `WorkspaceStore` over the `MountTestPaneSession` fake (no socket / video / Metal —
// hang-safety).

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class NavigatorColumnSelectTests: XCTestCase {
    /// A headless tree-model store over the fake session (mirrors `RailRowBuilderTests`).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// Builds a two-tab session where TAB B (index 1) holds a split pane, then activates TAB A so tab B is a
    /// BACKGROUND tab. Returns the store, the background pane's id, and tab B's id.
    private func makeBackgroundPaneScenario() throws -> (store: WorkspaceStore, bgPane: PaneID, tabB: TabID) {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab B (index 1), now active
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let bgPane = try XCTUnwrap(
            store.tree.activeSession?.activeTab?.activePane,
            "split yields an active pane",
        )
        let tabB = try XCTUnwrap(store.tree.activeSession?.tabs[1].id, "tab B exists at index 1")

        store.selectTab(0) // activate tab A → tab B becomes a BACKGROUND tab
        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 0, "precondition: tab A is active")
        return (store, bgPane, tabB)
    }

    /// The resolution finds the OWNING tab of a pane in a BACKGROUND tab.
    func testPaneInBackgroundTabResolvesItsOwningTab() throws {
        let (store, bgPane, _) = try makeBackgroundPaneScenario()
        let session = try XCTUnwrap(store.tree.activeSession)

        XCTAssertEqual(
            NavigatorColumn.owningTabIndex(of: bgPane, in: session), 1,
            "a pane in a background tab must resolve to its owning tab (index 1), not nil",
        )
    }

    /// The user-visible consequence: driving exactly what `NavigatorColumn.select` does on a row click —
    /// resolve the owning tab then `selectTab` it — makes the background tab ACTIVE.
    func testSelectingBackgroundRowActivatesOwningTab() throws {
        let (store, bgPane, _) = try makeBackgroundPaneScenario()
        let session = try XCTUnwrap(store.tree.activeSession)

        // The select(_:) sequence (the row-click path) against the resolution seam.
        let resolved = try XCTUnwrap(
            NavigatorColumn.owningTabIndex(of: bgPane, in: session),
            "the background pane must resolve an owning tab (a nil here is the dropped-select regression)",
        )
        store.selectTab(resolved)

        XCTAssertEqual(store.tree.activeSession?.activeTabIndex, 1, "tab B is now the active tab")
    }

    // MARK: - Badge auto-clear on tab-row select

    /// REVERT-TO-CONFIRM-FAIL: without the ``NavigatorColumn/selectRow(_:in:)`` badge-clearing loop the agent
    /// status for the pane remains `.done` after a row click, so the badge persists — failing the `.idle`
    /// assertion below. With the fix the loop clears every pane in the focused tab.
    func testSelectingTabRowWithDoneBadgeClearsBadge() throws {
        let store = makeStore()
        let pane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "initial pane exists")

        // Plant a `.done` agent status (the completion badge that should auto-clear on focus).
        store.setAgentStatus(.done, for: pane)
        XCTAssertEqual(store.agentStatus(for: pane), .done, "precondition: badge is set")

        // Drive the same static select path the rail row's onSelect fires.
        NavigatorColumn.selectRow(pane, in: store)

        // The badge must be gone — `clearAgentBadge` settles `.done` → `.idle`.
        XCTAssertEqual(
            store.agentStatus(for: pane), .idle,
            "selecting a tab row auto-clears the agent badge (badge auto-clears on tab focus)",
        )
    }

    // MARK: - Badge auto-clear on keyboard tab switch (⌘1–⌘9)

    /// REVERT-TO-CONFIRM-FAIL: before `WorkspaceStore.selectTab` gained its badge-clearing loop, switching
    /// tabs via ⌘1–⌘9 (which routes `selectTabNumber → selectTab` WITHOUT going through
    /// `NavigatorColumn.selectRow`) left the `.done` badge intact — failing the `.idle` assertion below.
    /// With the fix `selectTab` itself clears badges so keyboard-driven tab switches are equivalent to
    /// sidebar-click tab switches: the badge auto-clears whenever the tab gains focus.
    func testKeyboardTabSwitchClearsBadge() throws {
        let store = makeStore()

        // Build a second tab so switching tabs via selectTab makes sense.
        store.newTab(kind: .terminal, launchGrace: .zero) // tab index 1, now active
        let paneInTab1 = try XCTUnwrap(
            store.tree.activeSession?.activeTab?.activePane, "tab 1 has an active pane",
        )

        // Plant a `.done` badge on tab 1's pane (simulates a completed agent run).
        store.setAgentStatus(.done, for: paneInTab1)
        XCTAssertEqual(store.agentStatus(for: paneInTab1), .done, "precondition: badge is set on tab 1")

        // Switch AWAY to tab 0, then back to tab 1 via the direct `selectTab` path (⌘1–⌘9 route).
        store.selectTab(0)
        store.selectTab(1)

        // The badge must be cleared — `selectTab` now runs the same badge-clearing loop as `selectRow`.
        XCTAssertEqual(
            store.agentStatus(for: paneInTab1), .idle,
            "keyboard tab switch (⌘1–⌘9 → selectTab) auto-clears the agent badge",
        )
    }
}
