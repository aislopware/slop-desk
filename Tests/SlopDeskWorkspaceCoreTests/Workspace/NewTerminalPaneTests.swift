import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// The Stage re-scope's new-pane contract: every new-pane gesture (⌘T / ⌘D / the `+` button / the
/// context-menu splits) mints a real, FOCUSED `.terminal` pane DIRECTLY — the in-pane kind chooser is
/// retired, so there is no intermediate `.chooser` hop and the session materializes immediately. This
/// suite is the headless authority for that contract (`newTerminalPane` placement + the
/// `WorkspaceBindingRegistry.route` new-pane verbs + immediate materialization).
@MainActor
final class NewTerminalPaneTests: XCTestCase {
    private func makeTreeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func leafCount(_ store: WorkspaceStore) -> Int { store.tree.allPaneIDs().count }
    private func activeID(_ store: WorkspaceStore) -> PaneID? { store.tree.activeSession?.activeTab?.activePane }
    private func activeKind(_ store: WorkspaceStore) -> PaneKind? {
        guard let id = activeID(store) else { return nil }
        return store.tree.spec(for: id)?.kind
    }

    // MARK: - newTerminalPane mints a FOCUSED .terminal pane per placement

    func testNewTabMintsFocusedTerminal() {
        let store = makeTreeStore()
        let before = leafCount(store)
        store.newTerminalPane(.newTab)
        XCTAssertEqual(leafCount(store), before + 1, "a terminal pane is created immediately")
        XCTAssertEqual(activeKind(store), .terminal, "the new pane is a focused terminal — no chooser hop")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    func testSplitMintsFocusedTerminal() {
        let store = makeTreeStore()
        let before = leafCount(store)
        store.newTerminalPane(.split(axis: .horizontal))
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .terminal, "the split FOCUSES the new terminal pane")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    // MARK: - the new pane materializes its session IMMEDIATELY (no chooser skip in reconcile)

    func testNewPaneHasLiveHandleImmediately() throws {
        let store = makeTreeStore()
        store.newTerminalPane(.newTab)
        let id = try XCTUnwrap(activeID(store))
        XCTAssertNotNil(store.handle(for: id), "the terminal materializes on mint — no deferred kind pick")
        XCTAssertEqual(store.tree.spec(for: id)?.title, "Terminal")
    }

    // MARK: - the routed new-pane verbs mint terminals

    func testRoutedNewTabMintsTerminal() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.newTab, to: store)
        XCTAssertEqual(leafCount(store), before + 1, "newTab mints a pane immediately")
        XCTAssertEqual(activeKind(store), .terminal, "the routed verb mints a terminal directly")
    }

    func testRoutedSplitRightMintsFocusedTerminal() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.splitRight, to: store)
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .terminal, "splitRight FOCUSES the new terminal pane")
    }

    func testRoutedSplitDownMintsFocusedTerminal() {
        let store = makeTreeStore()
        let before = leafCount(store)
        WorkspaceBindingRegistry.route(.splitDown, to: store)
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .terminal)
    }

    // MARK: - terminal right-click "Split" mints a focused terminal targeting the acted-on pane

    func testContextMenuSplitMintsTerminalFocusingNewPane() {
        let store = makeTreeStore()
        let target = store.tree.allPaneIDs()[0]
        let before = leafCount(store)
        store.splitFromContextMenu(paneID: target, horizontal: true)
        XCTAssertEqual(leafCount(store), before + 1, "the right-click split mints a terminal pane")
        XCTAssertEqual(activeKind(store), .terminal, "focus lands on the new terminal pane")
    }
}
