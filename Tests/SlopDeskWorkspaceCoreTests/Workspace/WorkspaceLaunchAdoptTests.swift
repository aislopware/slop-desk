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

    /// Every pane the store materialized, in order — one entry per shell the app would have dialled.
    private final class Materializations {
        var panes: [PaneID] = []
    }

    private func makeStore(_ tree: TreeWorkspace, log: Materializations = Materializations()) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { seed in
                log.panes.append(seed.id)
                return FakePaneSession(seed.spec)
            },
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

    /// …and it takes it WITHOUT the panes ever leaving. This is the ordinary user's version of the
    /// two-shell bug the automation bootstrap had.
    ///
    /// RED before the fix: the host's first-run default lands one turn BEFORE the offer can go out —
    /// `box.apply` fires the document reconcile, `publish(.live)` fires the offer — and the projection
    /// drives the registry. So that one turn tore down all three restored panes, materialized the
    /// host's own default pane (a fourth shell, abandoned the moment the offer was accepted), and then
    /// rebuilt alpha/beta/gamma as brand-new sessions. On hardware: every terminal blanks and replays
    /// on first connect to a pristine host, and a PTY is left running on it.
    ///
    /// `handle(for:) != nil` above cannot see any of that — a REPLACEMENT is also non-nil. What pins
    /// it is handle IDENTITY plus a materialization count, the same pair `AutomationBootstrapLaunchTests`
    /// needed.
    func testTheRestoredPanesKeepTheSessionsTheWindowAlreadyDialled() throws {
        let log = Materializations()
        let restored = clientTree()
        let store = makeStore(restored, log: log)
        var launched: [PaneID: FakePaneSession] = [:]
        for pane in restored.allPaneIDs() {
            launched[pane] = try XCTUnwrap(store.handle(for: pane) as? FakePaneSession)
        }
        // Everything past this line happens AFTER the window is up and every pane holds a PTY.
        log.panes.removeAll()

        _ = attachHostDocument(to: store, pristine: true)

        XCTAssertEqual(
            log.panes, [],
            "no restored pane is materialized twice, and the host's own default never gets a shell",
        )
        for pane in restored.allPaneIDs() {
            XCTAssertTrue(
                store.handle(for: pane) === launched[pane],
                "…and every restored pane is the SAME live session — a replacement is a second shell",
            )
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

    /// …and the refusal leaves NOTHING behind. The offer is staged optimistically — that is what holds
    /// the restored panes through the round trip when the host does take it — so a `rejectedStale`
    /// has to snap the patch away and the registry has to follow host truth down to its one pane.
    /// A patch that outlived its refusal would shadow host truth until some later intent swept it.
    func testARefusedAdoptLeavesHostTruthAloneAndNoPatchBehind() {
        let restored = clientTree()
        let store = makeStore(restored)

        _ = attachHostDocument(to: store, pristine: false)

        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0, "the refused patch is gone")
        XCTAssertEqual(store.allSessionHandles.count, 1, "only the host's own pane is live")
        XCTAssertNil(store.pendingLaunchAdopt, "and the one offer this launch had is spent")
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
