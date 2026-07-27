import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// `followSessionFocus` (docs/45 §8.2) — whether local navigation on THIS device moves the shared
/// layout or only this device's own view of it.
///
/// The two rows of the §8.2 table, pinned against the two things that can disagree: `entries` (host
/// truth, the layout every attached client renders) and `store.tree` (what this device shows). With
/// the flag ON they must move together. With it OFF the first must not move at all while the second
/// does — and ``WorkspaceStore/currentWorkspaceView()`` must still name the locally-chosen tab, since
/// presence is the only way the other clients learn where an unfollowing device is looking.
@MainActor
final class FollowSessionFocusTests: XCTestCase {
    // MARK: - Fixtures

    private struct Seed {
        var workspace: TreeWorkspace
        var first: TabID
        var second: TabID
        var firstPane: PaneID
        var secondPane: PaneID
    }

    private func seed() -> Seed {
        let first = PaneID()
        let second = PaneID()
        let session = Session(
            id: SessionID(),
            name: "slop-desk",
            tabs: [
                Tab(id: TabID(), title: "one", root: .leaf(first), activePane: first),
                Tab(id: TabID(), title: "two", root: .leaf(second), activePane: second),
            ],
            specs: [
                first: PaneSpec(kind: .terminal, title: "Terminal"),
                second: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )
        return Seed(
            workspace: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            first: session.tabs[0].id,
            second: session.tabs[1].id,
            firstPane: first,
            secondPane: second,
        )
    }

    private func makeStore(_ tree: TreeWorkspace, following: Bool) -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: tree,
            liveModel: .tree,
            makeSession: { FakePaneSession($0.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        store.setFollowSessionFocus(following)
        return store
    }

    /// The tab HOST TRUTH calls active — `entries`, never the optimistic layer and never the projection.
    private func hostTruthActiveTab(_ store: WorkspaceStore) -> TabID? {
        WorkspaceTopology(entries: store.workspaceMirror.mirror.entries)?
            .tree.activeSession?.activeTab?.id
    }

    private func hostTruthActivePane(_ store: WorkspaceStore) -> PaneID? {
        WorkspaceTopology(entries: store.workspaceMirror.mirror.entries)?
            .tree.activeSession?.activeTab?.activePane
    }

    // MARK: - Following ON — local navigation is an intent

    /// The macOS default: a tab switch here is a tab switch everywhere.
    func testFollowingOnSendsTheTabFocusAsAnIntent() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: true)
        XCTAssertEqual(hostTruthActiveTab(store), seed.first)

        store.selectTab(1)

        XCTAssertEqual(
            hostTruthActiveTab(store), seed.second,
            "with following ON the shared layout moves — every other client follows",
        )
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.second)
        XCTAssertEqual(store.currentWorkspaceView().tabID, seed.second.raw)
    }

    /// Same rule for a pane focus: op 10 lands and the tab's `activePaneID` is host truth.
    func testFollowingOnSendsThePaneFocusAsAnIntent() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: true)

        store.focusPaneTree(seed.secondPane)

        XCTAssertEqual(hostTruthActivePane(store), seed.secondPane)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.second)
    }

    // MARK: - Following OFF — the device looks away without dragging anyone

    /// The iOS default: the phone changes what IT renders, and host truth does not move a byte.
    ///
    /// Both halves matter. If `entries` moved, an iPhone in a pocket would yank a Studio's screen. If
    /// `store.tree` did not move, the tap would do nothing at all.
    func testFollowingOffMovesThisDeviceOnly() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: false)
        let before = store.workspaceMirror.mirror.entries

        store.selectTab(1)

        XCTAssertEqual(
            store.workspaceMirror.mirror.entries, before,
            "not one cell of host truth moves — no intent was sent",
        )
        XCTAssertEqual(hostTruthActiveTab(store), seed.first)
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.id, seed.second,
            "this device renders the tab it chose",
        )
        XCTAssertEqual(
            store.currentWorkspaceView().tabID, seed.second.raw,
            "presence still tells the other clients where this device is looking",
        )
        XCTAssertEqual(store.workspaceMirror.pendingIntentCount, 0, "nothing was staged optimistically")
    }

    /// A pane focus behaves the same way, and carries its tab with it.
    func testFollowingOffKeepsAPaneFocusLocal() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: false)
        let before = store.workspaceMirror.mirror.entries

        store.focusPaneTree(seed.secondPane)

        XCTAssertEqual(store.workspaceMirror.mirror.entries, before, "host truth is untouched")
        XCTAssertEqual(hostTruthActivePane(store), seed.firstPane)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, seed.secondPane)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.second)
        XCTAssertEqual(store.currentWorkspaceView().paneID, seed.secondPane.raw)
    }

    /// The device's own view yields the moment it starts following again — otherwise turning the flag
    /// back on would leave the Mac pinned to a tab nobody else can see it on.
    func testFollowingAgainDropsTheDeviceLocalView() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: false)
        store.selectTab(1)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.second)

        store.setFollowSessionFocus(true)

        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.id, seed.first,
            "host truth leads again",
        )
    }

    /// A tab another client closed cannot strand this device on a blank view: the overlay applies only
    /// to what the projection still contains.
    func testADeviceLocalTabThatDisappearsFallsBackToHostTruth() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: false)
        store.selectTab(1)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.second)

        // Closing goes through the document regardless of the flag — the flag gates FOCUS, not layout.
        store.closeTab(seed.second)

        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.first)
    }

    /// A LAYOUT gesture on an unfollowing device targets the pane that device is looking at.
    ///
    /// The mutators name their target by id, resolved off `tree` — which carries the overlay — so the
    /// split lands where the user is pointing and not where host truth says focus is. Without that,
    /// an unfollowing device's every split, close and zoom would silently act on another machine's
    /// pane, which is a far worse failure than a focus that does not travel.
    func testAMutationOnAnUnfollowingDeviceTargetsThePaneItSees() throws {
        let seed = seed()
        let store = makeStore(seed.workspace, following: false)
        store.focusPaneTree(seed.secondPane)
        XCTAssertEqual(hostTruthActivePane(store), seed.firstPane, "host truth still names the first pane")

        store.splitActivePane(axis: .horizontal, kind: .terminal)

        let host = try XCTUnwrap(WorkspaceTopology(entries: store.workspaceMirror.mirror.entries))
        let split = try XCTUnwrap(host.tree.sessions.first?.tabs.first { $0.id == seed.second })
        XCTAssertEqual(split.allPaneIDs().count, 2, "the tab this device is looking at gained the leaf")
        XCTAssertEqual(
            host.tree.sessions.first?.tabs.first { $0.id == seed.first }?.allPaneIDs().count, 1,
            "the tab host truth calls active is untouched",
        )
    }

    // MARK: - The flag itself

    /// It is device-local and persisted, so it must be a preference write rather than a document one.
    func testTheFlagIsADevicePreference() {
        let seed = seed()
        let store = makeStore(seed.workspace, following: false)
        let before = store.workspaceMirror.mirror.entries

        XCTAssertFalse(store.devicePreferences.followSessionFocus)
        store.setFollowSessionFocus(true)

        XCTAssertTrue(store.devicePreferences.followSessionFocus)
        XCTAssertEqual(store.workspaceMirror.mirror.entries, before, "the flag never reaches the document")
    }
}
