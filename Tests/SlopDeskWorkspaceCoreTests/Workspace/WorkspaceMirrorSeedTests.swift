import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The store's mirror starts out holding the SAME layout the store restored.
///
/// A client that has yet to receive a type-37 frame — a fresh launch, an offline relaunch — reads
/// `nil` from `workspaceMirror.topology` without this seed, and
/// every mirror-backed read then answers "nothing known". That is silent: `WorkspaceMirrorBox.stageIntent`
/// returns `nil` for a nil topology and every mutating call built on it becomes a no-op with no error
/// anywhere.
///
/// It is also what an in-process document takes over: `attachLoopbackWorkspaceDocument()` ADOPTS the
/// seed rather than publishing one of its own, so a seed that never landed leaves the document with
/// nothing to be authoritative about.
@MainActor
final class WorkspaceMirrorSeedTests: XCTestCase {
    /// A three-pane tree: two tabs in one session, the first tab split.
    private func threePaneTree() -> (TreeWorkspace, [PaneID], [TabID], SessionID) {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let tabOne = Tab(
            id: TabID(),
            title: "one",
            root: .split(id: SplitNodeID(), axis: .horizontal, children: [
                WeightedChild(weight: .flex(1), node: .leaf(a)),
                WeightedChild(weight: .flex(1), node: .leaf(b)),
            ]),
            activePane: a,
        )
        let tabTwo = Tab(id: TabID(), title: "two", root: .leaf(c), activePane: c)
        let session = Session(
            id: SessionID(),
            name: "Local",
            tabs: [tabOne, tabTwo],
            specs: [
                a: PaneSpec(kind: .terminal, title: "Terminal"),
                b: PaneSpec(kind: .terminal, title: "Terminal"),
                c: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        return (tree, [a, b, c], [tabOne.id, tabTwo.id], session.id)
    }

    func testTheMirrorIsSeededFromRestoringTree() {
        let (tree, panes, tabs, sessionID) = threePaneTree()
        let store = WorkspaceStore(
            restoringTree: tree,
            makeSession: { seed in FakePaneSession(seed.spec) },
        )
        store.attachLoopbackWorkspaceDocument()

        guard let seeded = store.workspaceMirror.topology else {
            XCTFail("the mirror holds no topology at all — every mirror-backed read is blind")
            return
        }
        // Assert NON-EMPTY explicitly: an empty tree satisfies a set-equality assertion vacuously, and
        // that is exactly the failure this test exists to catch.
        XCTAssertEqual(seeded.tree.sessions.count, 1)
        XCTAssertEqual(Set(seeded.tree.allPaneIDs()).count, 3)

        let expected = tree.normalized()
        XCTAssertEqual(
            Set(seeded.tree.allPaneIDs()), Set(expected.allPaneIDs()),
            "the seeded pane ids are the restored tree's own",
        )
        XCTAssertEqual(Set(seeded.tree.allPaneIDs()), Set(panes))
        XCTAssertEqual(
            seeded.tree.sessions.flatMap { $0.tabs.map(\.id) }, tabs,
            "tab identity and order survive the projection",
        )
        XCTAssertEqual(seeded.tree.sessions.first?.id, sessionID)
        XCTAssertEqual(seeded.tree.activeSessionID, sessionID)
    }

    /// The default (no `restoringTree:`) launch seeds too — a fresh workspace is still a workspace.
    func testTheDefaultTreeIsSeededToo() {
        let store = WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        guard let seeded = store.workspaceMirror.topology else {
            XCTFail("the default launch left the mirror empty")
            return
        }
        XCTAssertEqual(Set(seeded.tree.allPaneIDs()), Set(store.tree.allPaneIDs()))
        XCTAssertFalse(seeded.tree.allPaneIDs().isEmpty)
    }
}
