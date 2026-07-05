import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// E11 WI-2 (ES-E11-4): the cwd-visit hook on ``WorkspaceStore``. `setLastKnownCwd(_:for:)` fires an injected
/// `onCwdVisited: ((String) -> Void)?` closure with the NEW cwd whenever it records a CHANGED directory (the
/// app wires this to ``FolderFrecencyStore/record(cwd:)`` so the Open-Quickly Folders filter learns visited
/// dirs) — but ONLY after the dirty guard, so an unchanged re-write never records a phantom visit.
///
/// These pin the WIRING, keeping the store SwiftUI-/Folders-agnostic (the hook is a plain closure, not a
/// dependency). Drives a LIVE `.tree` store through the `FakePaneSession` seam — no real client / view.
@MainActor
final class CwdVisitHookStoreTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTreeStore(restoringTree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: restoringTree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 2,
            persistence: nil,
        )
    }

    /// A single-session, single-pane workspace whose pane carries `cwd` as its last-known cwd.
    private func singlePaneWorkspace(_ pane: PaneID, cwd: String?) -> TreeWorkspace {
        let tab = Tab(root: .leaf(pane), activePane: pane)
        let specs: [PaneID: PaneSpec] = [pane: PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: cwd)]
        let session = Session(name: "Local", tabs: [tab], activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    // MARK: - Fires on a CHANGED cwd

    func testHookFiresWithNewCwdOnChange() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        var visited: [String] = []
        store.onCwdVisited = { visited.append($0) }

        store.setLastKnownCwd("/Users/me/project", for: pane)

        XCTAssertEqual(
            visited, ["/Users/me/project"],
            "a changed cwd fires the visit hook once with the new directory",
        )
        // And the spec was actually updated (the hook is downstream of the real write, not instead of it).
        XCTAssertEqual(store.tree.spec(for: pane)?.lastKnownCwd, "/Users/me/project")
    }

    func testHookFiresOncePerDistinctChange() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        var visited: [String] = []
        store.onCwdVisited = { visited.append($0) }

        store.setLastKnownCwd("/a", for: pane)
        store.setLastKnownCwd("/b", for: pane)
        store.setLastKnownCwd("/c", for: pane)

        XCTAssertEqual(visited, ["/a", "/b", "/c"], "each distinct cd records a visit in order")
    }

    // MARK: - Silent when UNCHANGED (the dirty guard)

    func testHookDoesNotFireWhenCwdUnchanged() {
        let pane = PaneID()
        // Seed the pane already at this cwd so the first call is a no-op behind the dirty guard.
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: "/Users/me/project"))
        var visited: [String] = []
        store.onCwdVisited = { visited.append($0) }

        store.setLastKnownCwd("/Users/me/project", for: pane) // identical to the seeded cwd ⇒ guarded out

        XCTAssertEqual(visited, [], "an unchanged cwd is guarded out → no phantom visit recorded")
    }

    func testHookFiresOnceAcrossARepeatedWrite() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        var visited: [String] = []
        store.onCwdVisited = { visited.append($0) }

        store.setLastKnownCwd("/srv/app", for: pane) // change → fires
        store.setLastKnownCwd("/srv/app", for: pane) // same → guarded out

        XCTAssertEqual(visited, ["/srv/app"], "the repeated identical write does not double-record the visit")
    }

    // MARK: - No hook ⇒ clean no-op (headless / tests)

    func testNoHookIsACleanNoOp() {
        let pane = PaneID()
        let store = makeTreeStore(restoringTree: singlePaneWorkspace(pane, cwd: nil))
        // onCwdVisited left nil (the default): setLastKnownCwd must still update the spec without crashing.
        store.setLastKnownCwd("/Users/me/project", for: pane)
        XCTAssertEqual(store.tree.spec(for: pane)?.lastKnownCwd, "/Users/me/project")
    }
}
