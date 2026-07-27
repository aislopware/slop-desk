import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The layout a client restored at launch is OFFERED to a host that has never had one.
///
/// The upgrade path is the whole point. A user with six tabs and a wall of splits in `workspace.json`
/// meets a host whose `workspace-state.json` does not exist yet; the host publishes its first-run
/// single-pane default, and the projection becomes that. Op 0 exists precisely so the client can hand
/// its tree over instead — `documentIsPristine` means the host would take it.
@MainActor
final class WorkspaceLaunchAdoptTests: XCTestCase {
    private func clientTree() -> TreeWorkspace {
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for title in ["alpha", "beta", "gamma"] {
            let pane = PaneID()
            specs[pane] = PaneSpec(kind: .terminal, title: title)
            tabs.append(Tab(title: title, root: .leaf(pane), activePane: pane))
        }
        let session = Session(name: "restored", tabs: tabs, activeTabIndex: 0, specs: specs)
        return TreeWorkspace(sessions: [session], activeSessionID: session.id)
    }

    private func makeStore(_ tree: TreeWorkspace) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
        )
    }

    /// A host document minted for a FIRST RUN — its own epoch, its own default tree, `pristine`.
    private func attachHostDocument(
        to store: WorkspaceStore,
        tree: TreeWorkspace = .defaultWorkspace(),
        pristine: Bool,
    ) -> LoopbackWorkspaceDocument {
        let document = LoopbackWorkspaceDocument(box: store.workspaceMirror, epoch: UUID())
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: tree.normalized()))
        document.install(state, pristine: pristine)
        store.attachWorkspaceChannel(.loopback(document: document))
        return document
    }

    /// RED before the launch adopt had a caller: `stageAdopt` was reachable only from the automation
    /// bootstrap, so a normal launch discarded the restored layout the moment the host's own default
    /// arrived — with no way to upload it.
    func testAPristineHostTakesTheLayoutThisClientRestored() {
        let restored = clientTree()
        let store = makeStore(restored)
        let document = attachHostDocument(to: store, pristine: true)

        XCTAssertEqual(
            document.topology?.tree.sessions.first?.tabs.map(\.title), ["alpha", "beta", "gamma"],
            "the host's first-run default gives way to the workspace somebody built",
        )
        XCTAssertEqual(store.tree.sessions.first?.tabs.count, 3)
        for pane in restored.allPaneIDs() {
            XCTAssertNotNil(store.handle(for: pane), "…and every restored pane comes back live")
        }
    }

    /// A host that already has a workspace keeps it — that tree is the only copy of a layout somebody
    /// built, and the ⌘T history of every other client is in it.
    func testAHostThatAlreadyHasAWorkspaceKeepsIt() {
        let store = makeStore(clientTree())
        let hostPane = PaneID()
        let hostSession = Session(
            name: "host",
            tabs: [Tab(title: "host tab", root: .leaf(hostPane), activePane: hostPane)],
            activeTabIndex: 0,
            specs: [hostPane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        let hostTree = TreeWorkspace(sessions: [hostSession], activeSessionID: hostSession.id)

        let document = attachHostDocument(to: store, tree: hostTree, pristine: false)

        XCTAssertEqual(document.topology?.tree.sessions.first?.tabs.map(\.title), ["host tab"])
        XCTAssertEqual(store.tree.sessions.first?.tabs.map(\.title), ["host tab"])
    }

    /// …and the refusal costs nothing on screen. The proposal is not staged optimistically, so the
    /// user never sees their old layout flash up — which, with the projection driving the registry,
    /// would also mean spawning a shell per restored pane and killing them all a round trip later.
    func testARefusedAdoptNeverShowsTheLayoutItProposed() {
        let restored = clientTree()
        let store = makeStore(restored)

        _ = attachHostDocument(to: store, pristine: false)

        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0, "nothing was staged optimistically")
        XCTAssertEqual(store.allSessionHandles.count, 1, "only the host's own pane is live")
    }

    /// Once per launch. A reconnect must not re-offer a tree that describes the workspace as it was
    /// before every change made since.
    func testTheOfferIsMadeOnlyOnce() throws {
        let store = makeStore(clientTree())
        _ = attachHostDocument(to: store, pristine: true)
        store.newTab(kind: .terminal)
        let afterMutation = try XCTUnwrap(store.tree.sessions.first?.tabs.count)
        XCTAssertEqual(afterMutation, 4)

        // A second subscription against a host that reports itself pristine again.
        let second = attachHostDocument(to: store, tree: .defaultWorkspace(), pristine: true)

        XCTAssertEqual(
            second.topology?.tree.sessions.first?.tabs.count, 1,
            "the launch tree is spent — the second document stands as the host published it",
        )
    }

    /// The in-process seam every test and the headless path use adopts the SEED, which IS this tree.
    /// Offering it back would spend the document's one pristine chance on a no-op.
    func testTheLoopbackSeamDoesNotConsumeTheOffer() {
        let store = makeStore(clientTree())

        store.attachLoopbackWorkspaceDocument()

        XCTAssertNotNil(store.pendingLaunchAdopt, "still on offer for the host that eventually turns up")
        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0)
    }
}
