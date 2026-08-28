import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The §8.2 table's OFF row, reached the way a real phone reaches it: by NOT setting the flag.
///
/// `Tests/SlopDeskWorkspaceCoreTests/Workspace/FollowSessionFocusTests` pins both rows, but it calls
/// `setFollowSessionFocus(_:)` on the way in — so it proves the MECHANISM and says nothing about
/// which row a device lands on. On a phone nothing calls that setter: the behaviour is entirely
/// `DevicePreferences.platformDefaultFollowSessionFocus`, and a macOS build of that expression reads
/// `true`. This suite therefore only means anything on the iOS triple, which is where it runs.
@MainActor
final class UnfollowingFocusOnIOSTests: XCTestCase {
    // MARK: - Fixture

    private struct Seed {
        var workspace: TreeWorkspace
        var first: TabID
        var second: TabID
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
        )
    }

    /// A store built exactly as the app builds it — the follow flag is never touched, so it holds
    /// whatever this platform defaults to.
    private func makeStore(_ tree: TreeWorkspace) -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: tree,
            makeSession: { FakePaneSession($0.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// The tab HOST TRUTH calls active — `entries`, never the optimistic layer, never the projection.
    private func hostTruthActiveTab(_ store: WorkspaceStore) -> TabID? {
        WorkspaceTopology(entries: store.workspaceMirror.hostTruth)?
            .tree.activeSession?.activeTab?.id
    }

    // MARK: - The default row

    /// The whole point of the iOS default: a phone glancing at a build log must not drag a Studio's
    /// screen with it. The shared layout stays where it was; only this device's projection moves.
    func testTheDefaultDeviceMovesOnlyItsOwnView() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        XCTAssertFalse(
            store.devicePreferences.followSessionFocus,
            "precondition: an untouched phone does not follow",
        )
        XCTAssertEqual(hostTruthActiveTab(store), seed.first)

        store.selectTab(1)

        XCTAssertEqual(
            hostTruthActiveTab(store), seed.first,
            "the shared layout is UNTOUCHED — no focusTab intent went out",
        )
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.id, seed.second,
            "…while this device is looking at the tab it picked",
        )
    }

    /// Presence is the only way the other clients learn where an unfollowing device is looking, so
    /// the overlay has to show through the report even though the document never moved.
    func testTheDefaultDeviceStillPublishesWhereItIsLooking() {
        let seed = seed()
        let store = makeStore(seed.workspace)

        store.selectTab(1)

        XCTAssertEqual(
            store.currentWorkspaceView().tabID, seed.second.raw,
            "a device that does not move the layout still says where it is",
        )
    }

    /// Turning following back ON is what re-attaches a phone to host truth — and it must drop the
    /// overlay in the same breath, or the device would keep rendering its own tab while claiming to
    /// follow.
    func testAdoptingTheFollowFlagDropsTheOverlay() {
        let seed = seed()
        let store = makeStore(seed.workspace)
        store.selectTab(1)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.id, seed.second)

        store.setFollowSessionFocus(true)

        XCTAssertNil(store.deviceFocus, "following again means host truth, with nothing on top")
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.id, hostTruthActiveTab(store),
            "…so the projection snaps back to what every other client renders",
        )
    }
}
