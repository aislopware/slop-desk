import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// WS-C v2 — `WorkspaceBindingRegistry.route(...)` mints an IN-PANE `.chooser` pane for every new-pane action
/// (no modal, no closure): the pane is created + FOCUSED immediately and renders the kind picker as its
/// content. This suite pins the pure routing seam (`route(_:to:)`) for each new-pane verb.
@MainActor
final class PaneChooserRoutingTests: XCTestCase {
    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func leafCount(_ store: WorkspaceStore) -> Int { store.tree.allPaneIDs().count }
    private func activeKind(_ store: WorkspaceStore) -> PaneKind? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.tree.spec(for: id)?.kind
    }

    func testNewTabRoutesToChooserPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.newTab, to: store)
        XCTAssertEqual(leafCount(store), before + 1, "newTab mints a pane immediately")
        XCTAssertEqual(activeKind(store), .chooser, "the new pane is an in-pane chooser")
    }

    func testSplitRightRoutesToFocusedChooserPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.splitRight, to: store)
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .chooser, "splitRight FOCUSES the new chooser pane")
    }

    func testSplitDownRoutesToFocusedChooserPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.splitDown, to: store)
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .chooser)
    }

    // MARK: - terminal right-click "Split" mints a focused chooser pane targeting the acted-on pane

    func testContextMenuSplitMintsChooserFocusingNewPane() {
        let store = makeTreeStore()
        let target = store.tree.allPaneIDs()[0]
        let before = leafCount(store)
        store.splitFromContextMenu(paneID: target, horizontal: true)
        XCTAssertEqual(leafCount(store), before + 1, "the right-click split mints a chooser pane")
        XCTAssertEqual(activeKind(store), .chooser, "focus lands on the new chooser pane")
    }
}
