import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins ``WorkspaceStore/setLastKnownCwd(_:for:)`` — the ONE sink every cwd source funnels into,
/// writing `pane/cwd` (which the titlebar / rail / palette read back through the mirror). The method
/// must land a value and GUARD an unchanged re-set (a re-focus must spend nothing). `.tree`-live +
/// `FakePaneSession` — no real client / view.
@MainActor
final class SetLastKnownCwdTests: XCTestCase {
    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
    }

    private func singlePaneWorkspace(_ pane: PaneID) -> TreeWorkspace {
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal")]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    func testWritesCwdIntoTheMirror() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        XCTAssertNil(store.paneCwd(for: pane), "unset until the cwd verb resolves")

        store.setLastKnownCwd("/Users/me/project", for: pane)
        XCTAssertEqual(store.paneCwd(for: pane), "/Users/me/project")
    }

    func testUpdatesToANewValue() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        store.setLastKnownCwd("/Users/me/a", for: pane)
        store.setLastKnownCwd("/Users/me/b", for: pane)
        XCTAssertEqual(store.paneCwd(for: pane), "/Users/me/b", "a changed cwd overwrites")
    }

    func testRepeatedSameValueIsStable() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        store.setLastKnownCwd("/Users/me/project", for: pane)
        // The guarded no-op path must keep the value (and not crash / clear it).
        store.setLastKnownCwd("/Users/me/project", for: pane)
        XCTAssertEqual(store.paneCwd(for: pane), "/Users/me/project")
    }

    /// A stale id (a pane closed mid-flight) writes only its own key — never another pane's — and the
    /// reconcile prune collects it.
    func testAStaleIdWritesOnlyItsOwnKey() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        store.setLastKnownCwd("/tmp/ghost", for: PaneID())
        XCTAssertNil(store.paneCwd(for: pane), "the live pane is untouched")
    }

    /// The plugin-cwd guard survives the move: a zinit turbo `builtin cd` caught by the host `cwd` RPC
    /// must never become a pane's cwd, or it poisons the inherit source for every later split.
    func testATransientPluginCwdIsDropped() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane))
        store.setLastKnownCwd("/Users/me/project", for: pane)
        store.setLastKnownCwd("/x/.zinit/plugins/zsh-users---zsh-autosuggestions", for: pane)
        XCTAssertEqual(store.paneCwd(for: pane), "/Users/me/project", "the poison never landed")
    }
}
