import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// `WorkspaceBindingRegistry.route(...)` under the TabSide partition (the in-pane chooser is no longer
/// minted, 2026-07-03): every new-pane verb creates + FOCUSES a real pane of the gesture's side directly —
/// `.newTab` a terminal, a terminal-side split a terminal (a GUI-side split mints a remote-window pane;
/// see `PaneChooserStoreLandingTests`). This suite pins the pure routing seam (`route(_:to:)`).
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

    func testNewTabRoutesToTerminalPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.newTab, to: store)
        XCTAssertEqual(leafCount(store), before + 1, "newTab mints a pane immediately")
        XCTAssertEqual(activeKind(store), .terminal, "⌘T mints a TERMINAL directly — no chooser step")
    }

    func testSplitRightRoutesToFocusedTerminalPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.splitRight, to: store)
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .terminal, "splitRight FOCUSES the new terminal pane")
    }

    func testSplitDownRoutesToFocusedTerminalPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.splitDown, to: store)
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .terminal)
    }

    // MARK: - terminal right-click "Split" mints a focused terminal pane targeting the acted-on pane

    func testContextMenuSplitMintsTerminalFocusingNewPane() {
        let store = makeTreeStore()
        let target = store.tree.allPaneIDs()[0]
        let before = leafCount(store)
        store.splitFromContextMenu(paneID: target, horizontal: true)
        XCTAssertEqual(leafCount(store), before + 1, "the right-click split mints a terminal pane")
        XCTAssertEqual(activeKind(store), .terminal, "focus lands on the new terminal pane")
    }
}
