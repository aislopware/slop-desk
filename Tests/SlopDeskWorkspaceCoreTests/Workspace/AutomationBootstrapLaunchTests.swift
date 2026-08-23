import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The automation launch — `slopdesk-guigate macos --connect`'s client, in the order the app shell runs it.
///
/// `SlopDeskClientApp.init` builds the store, calls ``WorkspaceStore/bootstrapFromEnvironment(_:)``,
/// and only THEN installs the workspace channel. The window mounts as soon as that initializer
/// returns, and every leaf in it dials a PTY on appear — so whichever tree the store holds when the
/// bootstrap returns is the tree that gets SHELLS. If the document later publishes a different one,
/// those shells are abandoned on the host and a second set is spawned in their place.
///
/// The GUI gate sees that as two `shell /bin/sh (pid …) attached` lines for one auto-connect, and as
/// an OUT-path proof that never lands: the autotype seam arms on the pane that is about to be
/// destroyed. Nothing in the headless suite could see it, because every other test attaches its
/// document BEFORE it bootstraps.
@MainActor
final class AutomationBootstrapLaunchTests: XCTestCase {
    private let automationEnv = [
        "SLOPDESK_AUTOCONNECT_HOST": "127.0.0.1",
        "SLOPDESK_AUTOCONNECT_PORT": "47420",
    ]

    /// Every pane the store materialized, in order — one entry per shell the app would have dialled.
    private final class Materializations {
        var panes: [PaneID] = []
    }

    /// Automation runs with NO persistence handle, so the store restores nothing and seeds its own
    /// launch default — exactly the state `SlopDeskClientApp` builds it in.
    private func makeStore(_ log: Materializations) -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: nil,
            makeSession: { seed in
                log.panes.append(seed.id)
                return FakePaneSession(seed.spec)
            },
        )
    }

    /// A host document minted for a FIRST RUN: its own epoch, its own single-pane default, pristine
    /// (`slopdesk-guigate macos` wipes `SLOPDESK_WORKSPACE_STATE_DIR` per run). `install` publishes the frame
    /// the way the wire does — the mirror folds it and announces the change — and attaching the
    /// channel is the `.live` edge that follows it in the same turn.
    @discardableResult
    private func attachHostDocument(
        to store: WorkspaceStore,
        tree: TreeWorkspace = .defaultWorkspace(),
        pristine: Bool = true,
    ) -> LoopbackWorkspaceDocument {
        let document = LoopbackWorkspaceDocument(box: store.workspaceMirror, epoch: UUID())
        var state = HostWorkspaceState()
        state.write(topology: WorkspaceTopology(tree: tree.normalized()))
        document.install(state, pristine: pristine)
        store.attachWorkspaceChannel(.loopback(document: document))
        return document
    }

    /// RED before the fix: with no channel to stage an intent on, the bootstrap armed itself and
    /// changed NOTHING, so the tree the window mounted was the store's own launch default.
    func testTheLaunchTreeIsAlreadyTheAutoconnectShape() {
        let store = makeStore(Materializations())

        store.bootstrapFromEnvironment(automationEnv)

        XCTAssertEqual(
            store.tree.sessions.first?.name, "127.0.0.1",
            "the tree the window is about to mount is the autoconnect shape, not a launch default",
        )
        XCTAssertEqual(store.tree.allPaneIDs().count, 1, "one bootstrap leaf")
        XCTAssertEqual(store.committedConnectionTarget?.host, "127.0.0.1", "…named before anything dials")
    }

    /// RED before the fix, and the two-shell bug itself: the pane the window dialled at launch was a
    /// different id from the one the bootstrap adopted once the channel went live, so the first pane's
    /// PTY was abandoned and a second was spawned for the second pane.
    func testTheDocumentPublishesThePaneTheWindowAlreadyDialled() throws {
        let log = Materializations()
        let store = makeStore(log)
        store.bootstrapFromEnvironment(automationEnv)

        // Everything past this line happens AFTER the window is up and its pane holds a PTY.
        let launchPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        let launchHandle = try XCTUnwrap(store.handle(for: launchPane) as? FakePaneSession)
        log.panes.removeAll()

        attachHostDocument(to: store)

        XCTAssertEqual(
            store.tree.allPaneIDs(), [launchPane],
            "the document publishes the pane the window already mounted",
        )
        XCTAssertTrue(
            store.handle(for: launchPane) === launchHandle,
            "…and it is the SAME live session — a replacement is a second shell on the host",
        )
        XCTAssertEqual(log.panes, [], "no pane is materialized a second time")
        XCTAssertEqual(launchHandle.teardownCount, 0, "…and the pane holding the PTY is never torn down")
    }

    /// The bootstrap still reaches the host: the layout it seeded locally is the layout the document
    /// ends up holding, so a second client sees the autoconnect shape too.
    func testTheSeededShapeIsWhatTheDocumentAdopts() throws {
        let store = makeStore(Materializations())
        store.bootstrapFromEnvironment(automationEnv)
        let launchPane = try XCTUnwrap(store.tree.allPaneIDs().first)

        let document = attachHostDocument(to: store)

        XCTAssertEqual(document.topology?.tree.allPaneIDs(), [launchPane], "op 0 uploaded the seeded tree")
        XCTAssertEqual(document.topology?.tree.sessions.first?.name, "127.0.0.1")
    }

    /// A host that already has a workspace keeps it — the bootstrap is a proposal, not a migration.
    /// The optimistic patch snaps away on `rejectedStale` and the client projects host truth.
    func testAHostThatAlreadyHasAWorkspaceRefusesTheBootstrap() {
        let store = makeStore(Materializations())
        store.bootstrapFromEnvironment(automationEnv)

        let hostPane = PaneID()
        let hostSession = Session(
            name: "host",
            tabs: [Tab(title: "host tab", root: .leaf(hostPane), activePane: hostPane)],
            activeTabIndex: 0,
            specs: [hostPane: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        let hostTree = TreeWorkspace(sessions: [hostSession], activeSessionID: hostSession.id)

        attachHostDocument(to: store, tree: hostTree, pristine: false)

        XCTAssertEqual(store.tree.sessions.first?.tabs.map(\.title), ["host tab"], "host truth stands")
        XCTAssertEqual(store.tree.allPaneIDs(), [hostPane])
        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0, "the refused patch is gone")
    }

    /// The window-targeted video autoconnect (`slopdesk-guigate video`) rides the same launch: its TERMINAL
    /// pane is seeded once, and the detached desktop pane it owes the document is minted once too —
    /// so the run that finally reaches a channel spawns exactly the pane the window is showing.
    func testTheVideoAutoconnectSeedsItsTerminalPaneOnce() throws {
        let log = Materializations()
        let store = makeStore(log)

        store.bootstrapFromEnvironment([
            "SLOPDESK_VIDEO_AUTOCONNECT_HOST": "127.0.0.1",
            "SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT": "9000",
            "SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT": "9001",
            "SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID": "42",
        ])
        let launchPane = try XCTUnwrap(store.tree.allPaneIDs().first)
        let launchHandle = try XCTUnwrap(store.handle(for: launchPane) as? FakePaneSession)

        attachHostDocument(to: store)

        XCTAssertEqual(store.tree.allPaneIDs(), [launchPane], "the terminal pane survives the document")
        XCTAssertTrue(store.handle(for: launchPane) === launchHandle, "…as the same live session")
        let detached = try XCTUnwrap(store.tree.activeSession?.detached.first?.pane)
        XCTAssertEqual(store.tree.spec(for: detached)?.video?.windowID, 42, "the desktop window is served")
    }
}
