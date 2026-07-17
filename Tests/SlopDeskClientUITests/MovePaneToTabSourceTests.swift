// MovePaneToTabSourceTests — pins the dynamic "Move Pane to Tab: …" palette rows (the keyboard twin of
// dropping a pane on a sidebar row): the snapshot enumerates every tab EXCEPT the active one, and the
// accepted row's `.store` arm moves the ACTIVE pane beside the destination tab's active pane
// (`moveLeafAcrossTabsTree` — PaneID-preserving; the destination tab becomes active with the moved
// pane focused).
//
// Headless: a tree-model `WorkspaceStore` over the `MountTestPaneSession` fake (no socket / video /
// Metal — hang-safety).

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class MovePaneToTabSourceTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// Three tabs, tab C (index 2) active — so A and B are candidate destinations.
    private func makeThreeTabStore() -> WorkspaceStore {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab B
        store.newTab(kind: .terminal, launchGrace: .zero) // tab C — active
        return store
    }

    func testSnapshotListsEveryTabExceptTheActiveOne() throws {
        let store = makeThreeTabStore()
        let session = try XCTUnwrap(store.tree.activeSession)
        let rows = MovePaneToTabSource.snapshot(store).candidates(query: "")

        XCTAssertEqual(rows.count, 2, "three tabs, one active ⇒ two destinations")
        XCTAssertFalse(
            rows.contains { $0.id.contains(session.tabs[session.activeTabIndex].id.raw.uuidString) },
            "moving a pane 'to its own tab' is the identity op — the active tab is never a destination",
        )
        // Position-based titles: every fresh pane is titled "Terminal", so a title-based label would
        // render indistinguishable twins — the live pane title rides the subtitle instead.
        XCTAssertEqual(rows.map(\.title).sorted(), ["Move Pane to Tab 1", "Move Pane to Tab 2"])
        XCTAssertEqual(rows.compactMap(\.subtitle), ["Terminal", "Terminal"], "pane titles ride the subtitle")
    }

    func testSnapshotIsEmptyOnASingleTabSession() {
        XCTAssertTrue(
            MovePaneToTabSource.snapshot(makeStore()).isEmpty,
            "one tab ⇒ nowhere to move — no dead verbs in the palette",
        )
    }

    func testAcceptedRowMovesTheActivePaneBesideTheDestinationTabsActivePane() throws {
        let store = makeThreeTabStore()
        let session = try XCTUnwrap(store.tree.activeSession)
        let source = try XCTUnwrap(session.activeTab?.activePane)
        let destTab = session.tabs[0]
        let anchor = try XCTUnwrap(destTab.activePane)

        let row = try XCTUnwrap(
            MovePaneToTabSource.snapshot(store).candidates(query: "")
                .first { $0.id.contains(destTab.id.raw.uuidString) },
        )
        guard case let .store(run) = row.action else {
            XCTFail("a move row must carry a .store arm")
            return
        }
        run(store)

        let after = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(after.activeTabIndex, 0, "the destination tab is revealed with the moved pane")
        XCTAssertEqual(after.tabs[0].activePane, source, "the moved pane keeps focus (same PaneID — no teardown)")
        let destLeaves = after.tabs[0].allPaneIDs()
        XCTAssertTrue(destLeaves.contains(source) && destLeaves.contains(anchor), "source landed beside the anchor")
        XCTAssertEqual(after.tabs.count, 2, "the source tab (sole leaf) dissolved after its pane left")
    }
}
