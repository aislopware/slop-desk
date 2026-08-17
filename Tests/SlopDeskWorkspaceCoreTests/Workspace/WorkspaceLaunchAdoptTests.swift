import Foundation
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

    private func makeStore(
        _ tree: TreeWorkspace,
        log: Materializations = Materializations(),
        cache: WorkspaceCacheStore? = nil,
        cacheHostKey: String = "",
    ) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: tree,
            makeSession: { seed in
                log.panes.append(seed.id)
                return FakePaneSession(seed.spec)
            },
            documentCache: cache,
            cacheHostKey: cacheHostKey,
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

    /// …and it costs exactly ONE materialization: the host's own pane, dialled once.
    ///
    /// The live-handle count above cannot see this. Losing three restored panes and gaining the
    /// host's one is the CORRECT outcome of a refusal — the host's tree is the only copy of a layout
    /// somebody built — but `allSessionHandles.count == 1` reads the same whether the host's pane was
    /// materialized once or the restored three were rebuilt and torn down again around it. That
    /// difference is three abandoned PTYs on the host, on every single connect.
    ///
    /// RED without the reconcile hold `reconcileTreeFromDocument()` keeps while an offer is
    /// outstanding: the host frame lands first and materializes its pane, the optimistic patch then
    /// projects the restored tree and materializes alpha/beta/gamma a second time, and the refusal
    /// tears all three down again — four materializations for one connect.
    func testARefusedAdoptMaterializesTheHostsOwnPaneExactlyOnce() {
        let log = Materializations()
        let restored = clientTree()
        let store = makeStore(restored, log: log)
        let hostPane = PaneID()
        let hostSession = Session(
            name: "host",
            tabs: [Tab(title: "host tab", root: .leaf(hostPane), activePane: hostPane)],
            activeTabIndex: 0,
            specs: [hostPane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        // Everything past this line happens AFTER the window is up and every restored pane holds a PTY.
        log.panes.removeAll()

        _ = attachHostDocument(
            to: store,
            tree: TreeWorkspace(sessions: [hostSession], activeSessionID: hostSession.id),
            pristine: false,
        )

        XCTAssertEqual(
            log.panes, [hostPane],
            "a refused adopt dials the host's pane once and no restored pane a second time",
        )
    }

    // MARK: - What the offer carries

    /// The offer carries each pane's SPAWN DIRECTORY, not just the shape of the tree.
    ///
    /// `pane/spawnCwd` is a TOPOLOGY fact, and on a cold launch this device is the only thing that
    /// remembers it: the panes have no live shell to ask, so the value comes from
    /// `workspace-cache.json` and `seedWorkspaceMirror(from:cache:)` folds it into the seeded topology
    /// for exactly that reason. A proposal rebuilt from the TREE alone defaults `spawnCwd` to `[:]`,
    /// so a pristine host that ACCEPTS the layout republishes every pane with its project directory
    /// stripped — and the first cwd push after that rewrites the cache from the mirror, writing the
    /// loss to disk. Next launch every shell starts in hostd's cwd and By-Project collapses to one
    /// section.
    func testAnAcceptedAdoptCarriesEveryPanesSpawnDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-adopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WorkspaceCacheStore(fileURL: directory.appendingPathComponent("workspace-cache.json"))
        let hostKey = "mac-studio:7420"

        let restored = clientTree()
        let panes = restored.allPaneIDs().sorted { $0.raw.uuidString < $1.raw.uuidString }
        let spawnCwds = Dictionary(uniqueKeysWithValues: panes.enumerated().map { ($1, "/work/project-\($0)") })
        var cached = HostWorkspaceState()
        for (pane, cwd) in spawnCwds {
            cached.set(
                WorkspaceKey(.pane, pane.raw, WorkspacePaneField.spawnCwd),
                WorkspaceStateCodec.encodeString(cwd),
            )
        }
        try cache.save(cached, hostKey: hostKey)

        let store = makeStore(restored, cache: cache, cacheHostKey: hostKey)
        for (pane, cwd) in spawnCwds {
            XCTAssertEqual(store.spawnCwd(for: pane), cwd, "the seed reads the cache — the launch is fine")
        }

        let document = attachHostDocument(to: store, pristine: true)

        for (pane, cwd) in spawnCwds {
            XCTAssertEqual(
                document.topology?.spawnCwd[pane], cwd,
                "the host adopted a layout whose panes have no spawn directory",
            )
            XCTAssertEqual(store.spawnCwd(for: pane), cwd, "…and the client can no longer answer for one")
        }
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
