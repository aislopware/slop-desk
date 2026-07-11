import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// WS-C v2 — the IN-PANE chooser store landing. Every new-pane gesture mints a real, FOCUSED `.chooser`
/// pane (the pane's CONTENT is the kind picker); ``WorkspaceStore/choosePaneKind(_:kind:)`` then flips it to
/// the real kind IN PLACE (same `PaneID`) and reconcile materializes the session. This suite is the headless
/// authority for that contract (`openChooserPane` placement + `choosePaneKind` transition + reconcile-skip).
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

    // MARK: - openChooserPane mints a FOCUSED .chooser pane per context

    func testNewTabOpensFocusedChooserPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        store.openChooserPane(.newTab)
        XCTAssertEqual(leafCount(store), before + 1, "a chooser pane is created immediately")
        XCTAssertEqual(activeKind(store), .chooser, "the new pane is a focused chooser")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    func testSplitOpensFocusedChooserPane() {
        let store = makeTreeStore()
        let before = leafCount(store)
        store.openChooserPane(.split(axis: .horizontal))
        XCTAssertEqual(leafCount(store), before + 1)
        XCTAssertEqual(activeKind(store), .chooser, "the split FOCUSES the new chooser pane")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    // MARK: - a .chooser pane materializes NO session (reconcile skips it)

    func testChooserPaneHasNoLiveHandle() throws {
        let store = makeTreeStore()
        store.openChooserPane(.newTab)
        let id = try XCTUnwrap(activeID(store))
        XCTAssertNil(store.handle(for: id), "a .chooser pane has no live session until a kind is picked")
    }

    // MARK: - choosePaneKind flips the chooser IN PLACE + materializes

    func testChoosePaneKindTerminalMaterializesInPlace() throws {
        let store = makeTreeStore()
        store.openChooserPane(.newTab)
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
        store.openChooserPane(.split(axis: .vertical))
        let id = try XCTUnwrap(activeID(store))
        store.choosePaneKind(id, kind: .remoteGUI)
        XCTAssertEqual(activeKind(store), .remoteGUI)
        XCTAssertNil(store.tree.spec(for: id)?.video, "the remoteGUI pane is unconfigured (in-pane window picker path)")
        XCTAssertTrue(store.tree.isInvariantHeld())
    }

    /// The PRIMARY ⌘T flow end-to-end at the spec level (the "new tab shows 'New Pane'" report,
    /// 2026-07-11): a chooser minted from a pane with a known cwd INHERITS that cwd, and picking
    /// Terminal retitles the spec to "Terminal" — so the rail's `rowTitle` (folder name over
    /// `lastKnownTitle ?? title`) can never be left at the chooser's "New Pane" once resolved, and
    /// the terminal materializes with the inherited cwd as its spawn hint.
    func testChooserResolveKeepsInheritedCwdAndRetitles() throws {
        let store = makeTreeStore()
        let source = try XCTUnwrap(activeID(store))
        store.setLastKnownCwd("/Users/me/projects/slop-desk", for: source)

        store.openChooserPane(.newTab)
        let chooser = try XCTUnwrap(activeID(store))
        XCTAssertEqual(
            store.tree.spec(for: chooser)?.lastKnownCwd, "/Users/me/projects/slop-desk",
            "the chooser spec carries the inherited cwd (ES-E3-2)",
        )
        XCTAssertEqual(store.tree.spec(for: chooser)?.title, "New Pane")

        store.choosePaneKind(chooser, kind: .terminal)
        let spec = try XCTUnwrap(store.tree.spec(for: chooser))
        XCTAssertEqual(spec.title, "Terminal", "the resolve retitles — 'New Pane' must not survive")
        XCTAssertEqual(
            spec.lastKnownCwd, "/Users/me/projects/slop-desk",
            "a Terminal pick KEEPS the inherited cwd (it becomes the spawn hint + the folder-name title source)",
        )
        XCTAssertNil(spec.lastKnownTitle, "no shell title yet — nothing can shadow the folder-name title")
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
