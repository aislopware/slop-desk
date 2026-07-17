// PaneDragSpringLoadTests — pins the spring-loaded tab reveal's TARGET rule
// (``PaneDragCoordinator/springLoadTabIndex(for:in:)``): dwelling a live pane drag on a sidebar row
// reveals that row's tab, but only when there is genuinely a tab to reveal — the active tab's own rows
// and a detached pane's row must never fire a tab switch under the drag.
//
// Headless: a tree-model `WorkspaceStore` over the `MountTestPaneSession` fake (no socket / video /
// Metal — hang-safety). The dwell/cancel TIMING rides a Task the gesture drives; only the pure target
// resolution is pinned here.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class PaneDragSpringLoadTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// Two tabs; tab B (index 1) in the background — the canonical spring-load scenario.
    private func makeBackgroundTabScenario() throws -> (store: WorkspaceStore, bgPane: PaneID) {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab B (index 1), now active
        let bgPane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.selectTab(0) // back to tab A → tab B is a background tab
        return (store, bgPane)
    }

    func testBackgroundTabRowResolvesItsOwningTabIndex() throws {
        let (store, bgPane) = try makeBackgroundTabScenario()
        XCTAssertEqual(
            PaneDragCoordinator.springLoadTabIndex(for: bgPane, in: store.tree), 1,
            "dwelling on a background tab's row must reveal that tab",
        )
    }

    func testActiveTabRowResolvesNil() throws {
        let (store, _) = try makeBackgroundTabScenario()
        let activePane = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNil(
            PaneDragCoordinator.springLoadTabIndex(for: activePane, in: store.tree),
            "the active tab is already revealed — a spring-load here would churn selection for nothing",
        )
    }

    func testDetachedPaneRowResolvesNil() throws {
        let (store, bgPane) = try makeBackgroundTabScenario()
        store.detachPaneToWindow(bgPane) // the pane leaves every tab's tree
        XCTAssertNil(
            PaneDragCoordinator.springLoadTabIndex(for: bgPane, in: store.tree),
            "a detached pane owns no tab — there is nothing to spring to",
        )
    }
}
