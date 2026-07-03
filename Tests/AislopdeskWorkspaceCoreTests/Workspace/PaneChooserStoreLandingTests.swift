import CoreGraphics
import XCTest
@testable import AislopdeskWorkspaceCore

/// The new-pane store landing under the TabSide partition (the in-pane CHOOSER is no longer minted,
/// 2026-07-03): every new-pane gesture creates a real, FOCUSED pane of the gesture's side directly —
/// `.newTab` (⌘T / `+`) a terminal tab, a terminal-side split a terminal, a GUI-side split an UNBOUND
/// `.remoteGUI` (its content is the in-pane window picker). The `.chooser` kind survives only for
/// persisted legacy panes: ``WorkspaceStore/choosePaneKind(_:kind:)`` still flips one to the real kind
/// IN PLACE (same `PaneID`), and reconcile still skips materializing it — this suite is the headless
/// authority for both halves.
@MainActor
final class PaneChooserStoreLandingTests: XCTestCase {
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

    // MARK: - openChooserPane mints a FOCUSED pane of the gesture's side directly (no chooser step)

    func testNewTabOpensFocusedTerminalPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        store.openChooserPane(.newTab)
        XCTAssertEqual(leafCount(store), before + 1, "a pane is created immediately")
        XCTAssertEqual(activeKind(store), .terminal, "⌘T mints a TERMINAL directly — no chooser step")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    func testSplitOnTerminalSideOpensFocusedTerminalPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        store.openChooserPane(.split(axis: .horizontal))
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .terminal, "a terminal-side split mints a focused TERMINAL")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    func testSplitOnGuiSideOpensUnboundRemoteGUIPane() throws {
        let store = makeTreeStore()
        store.newRemoteWindowTab(windowID: 42, title: "W", appName: "App") // focus moves to the GUI tab
        store.openChooserPane(.split(axis: .vertical))
        let id = try XCTUnwrap(activeID(store))
        XCTAssertEqual(activeKind(store), .remoteGUI, "a GUI-side split mints a remote-window pane")
        XCTAssertNil(store.tree.spec(for: id)?.video, "unbound — its content is the in-pane window picker")
        let session = try XCTUnwrap(store.tree.activeSession)
        XCTAssertFalse(session.tabs.contains(where: session.isMixedTab), "the GUI tab stays side-pure")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    // MARK: - a legacy .chooser pane still materializes NO session (reconcile skips it)

    func testChooserPaneHasNoLiveHandle() throws {
        let store = makeTreeStore()
        store.newTab(kind: .chooser) // the persisted-legacy shape, minted directly for the pin
        let id = try XCTUnwrap(activeID(store))
        XCTAssertNil(store.handle(for: id), "a .chooser pane has no live session until a kind is picked")
    }

    // MARK: - choosePaneKind still flips a legacy chooser IN PLACE + materializes

    func testChoosePaneKindTerminalMaterializesInPlace() throws {
        let store = makeTreeStore()
        store.newTab(kind: .chooser)
        let id = try XCTUnwrap(activeID(store))
        let countAfterChooser = leafCount(store)
        store.choosePaneKind(id, kind: .terminal)
        XCTAssertEqual(activeID(store), id, "the kind flips IN PLACE — same PaneID, still focused")
        XCTAssertEqual(activeKind(store), .terminal)
        XCTAssertEqual(leafCount(store), countAfterChooser, "no new leaf — the chooser pane BECAME the terminal")
        XCTAssertNotNil(store.handle(for: id), "the now-terminal pane has a live session")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    func testChoosePaneKindRemoteLandsUnconfiguredRemoteGUI() throws {
        let store = makeTreeStore()
        store.splitActivePane(axis: .vertical, kind: .chooser, leading: false, launchGrace: .zero)
        let id = try XCTUnwrap(activeID(store))
        store.choosePaneKind(id, kind: .remoteGUI)
        XCTAssertEqual(store.tree.spec(for: id)?.kind, .remoteGUI)
        XCTAssertNil(store.tree.spec(for: id)?.video, "the remoteGUI pane is unconfigured (in-pane window picker path)")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    /// `choosePaneKind` is a no-op on a non-chooser pane (defensive — only a `.chooser` pane transitions).
    func testChoosePaneKindNoOpOnNonChooser() throws {
        let store = makeTreeStore()
        let id = try XCTUnwrap(activeID(store))
        let kindBefore = store.tree.spec(for: id)?.kind
        store.choosePaneKind(id, kind: .remoteGUI)
        XCTAssertEqual(store.tree.spec(for: id)?.kind, kindBefore, "a non-chooser pane's kind is unchanged")
    }
}
