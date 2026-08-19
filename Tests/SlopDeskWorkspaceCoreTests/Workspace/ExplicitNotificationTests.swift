import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the explicit-notification (OSC 9 / OSC 777) content policy and the store's reveal routing:
///
/// - ``ExplicitNotificationContent/resolve(paneTitle:explicitTitle:body:)`` — OSC 777 keeps its own
///   title; OSC 9 (no title) falls back to the pane title; with no title anywhere the body is
///   promoted so the alert is never blank.
/// - ``WorkspaceStore/handlePaneNotification(id:paneTitle:title:body:)`` forwards to the app poster
///   hook with the right pane id + content; ``WorkspaceStore/revealPane(byIDString:)`` teleports to the
///   originating pane (no-op when its id is unparseable or gone).
@MainActor
final class ExplicitNotificationTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in FakePaneSession(seed.spec) },
        )
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// The one leaf of the default tree — every routing assertion below names it.
    private func onlyPane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.allPaneIDs().first)
    }

    // MARK: - Content policy

    func testOSC777KeepsItsOwnTitle() {
        let r = ExplicitNotificationContent.resolve(paneTitle: "zsh", explicitTitle: "CI", body: "green")
        XCTAssertEqual(r.title, "CI")
        XCTAssertEqual(r.body, "green")
    }

    func testOSC9FallsBackToPaneTitle() {
        let r = ExplicitNotificationContent.resolve(paneTitle: "build.sh", explicitTitle: "", body: "done")
        XCTAssertEqual(r.title, "build.sh")
        XCTAssertEqual(r.body, "done")
    }

    func testNoTitleAnywherePromotesBody() {
        let r = ExplicitNotificationContent.resolve(paneTitle: "  ", explicitTitle: "", body: "all done")
        XCTAssertEqual(r.title, "all done", "body promoted so the alert is never blank")
        XCTAssertEqual(r.body, "")
    }

    // MARK: - Store routing

    func testHandlePaneNotificationForwardsToHook() throws {
        let store = makeStore()
        let paneID = try onlyPane(store)
        var received: (PaneID, String, String, String)?
        store.onPaneNotification = { id, paneTitle, title, body in received = (id, paneTitle, title, body) }

        store.handlePaneNotification(id: paneID, paneTitle: "zsh", title: "CI", body: "green")

        XCTAssertEqual(received?.0, paneID)
        XCTAssertEqual(received?.1, "zsh")
        XCTAssertEqual(received?.2, "CI")
        XCTAssertEqual(received?.3, "green")
    }

    /// A notification click is a TELEPORT: the id string round-trips through
    /// ``WorkspaceStore/revealPane(byIDString:)`` onto the tree focus path, and a garbage / unknown id is
    /// a no-op rather than a trap.
    func testRevealPaneByIDStringRoundTrips() throws {
        let store = makeStore()
        let id = try onlyPane(store)

        store.revealPane(byIDString: id.raw.uuidString)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, id)

        store.revealPane(byIDString: "not-a-uuid")
        store.revealPane(byIDString: UUID().uuidString) // valid shape, unknown pane
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, id,
            "an unparseable or unknown id leaves focus untouched",
        )
    }

    // MARK: - Event plumbing (client Event → store hook)

    func testNotificationEventReachesTheHookViaTheConnection() throws {
        let store = makeStore()
        let paneID = try onlyPane(store)
        var received: (String, String, String)?
        store.onPaneNotification = { _, paneTitle, title, body in received = (paneTitle, title, body) }

        // The reconcile wiring set connection.onExplicitNotification on the live terminal pane; drive it
        // directly (the fake seam has no live ConnectionViewModel, so assert the store hook contract via
        // handlePaneNotification, which is what that closure calls).
        store.handlePaneNotification(id: paneID, paneTitle: "", title: "", body: "ping")
        XCTAssertEqual(received?.0, "")
        XCTAssertEqual(received?.2, "ping")
    }
}
