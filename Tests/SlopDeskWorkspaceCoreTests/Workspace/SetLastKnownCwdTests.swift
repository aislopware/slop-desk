import XCTest
@testable import SlopDeskWorkspaceCore

/// E4 WI-5: pins ``WorkspaceStore/setLastKnownCwd(_:for:)`` — the live-model-aware write path the Details
/// Panel's Info tab uses to mirror the host-resolved `cwd` verb into ``PaneSpec/lastKnownCwd`` (which the
/// titlebar / rail / palette read). Before E4 `lastKnownCwd` was decode-only with NO runtime writer, so this
/// is a real new behaviour: the method must persist a value on a `.tree`-live store and GUARD an unchanged
/// re-set (a re-focus must not spend a reconcile). `.tree`-live + `FakePaneSession` — no real client / view.
@MainActor
final class SetLastKnownCwdTests: XCTestCase {
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func singlePaneWorkspace(_ pane: PaneID) -> TreeWorkspace {
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal")]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    func testWritesCwdIntoSpec() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        XCTAssertNil(store.tree.spec(for: pane)?.lastKnownCwd, "unset until the cwd verb resolves")

        store.setLastKnownCwd("/Users/me/project", for: pane)
        XCTAssertEqual(store.tree.spec(for: pane)?.lastKnownCwd, "/Users/me/project")
    }

    func testUpdatesToANewValue() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        store.setLastKnownCwd("/Users/me/a", for: pane)
        store.setLastKnownCwd("/Users/me/b", for: pane)
        XCTAssertEqual(store.tree.spec(for: pane)?.lastKnownCwd, "/Users/me/b", "a changed cwd overwrites")
    }

    func testRepeatedSameValueIsStable() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        store.setLastKnownCwd("/Users/me/project", for: pane)
        // The guarded no-op path must keep the value (and not crash / clear it).
        store.setLastKnownCwd("/Users/me/project", for: pane)
        XCTAssertEqual(store.tree.spec(for: pane)?.lastKnownCwd, "/Users/me/project")
    }

    func testUnknownPaneIsANoOp() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        // A stale id (e.g. a pane closed mid-flight) must not trap or mutate another pane.
        store.setLastKnownCwd("/tmp/ghost", for: PaneID())
        XCTAssertNil(store.tree.spec(for: pane)?.lastKnownCwd, "the live pane is untouched")
    }
}
