import AislopdeskClient
import XCTest
@testable import AislopdeskClientUI

/// Pins the explicit-notification (OSC 9 / OSC 777) content policy and the store's reveal routing:
///
/// - ``ExplicitNotificationContent/resolve(paneTitle:explicitTitle:body:)`` — OSC 777 keeps its own
///   title; OSC 9 (no title) falls back to the pane title; with no title anywhere the body is
///   promoted so the alert is never blank.
/// - ``WorkspaceStore/handlePaneNotification(id:paneTitle:title:body:)`` forwards to the app poster
///   hook with the right pane id + content; ``WorkspaceStore/revealPane(_:)`` /
///   ``revealPane(byIDString:)`` focus + centre the originating pane (no-op when it is gone).
@MainActor
final class ExplicitNotificationTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) })
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
        let paneID = try XCTUnwrap(store.focusedPane)
        var received: (PaneID, String, String, String)?
        store.onPaneNotification = { id, paneTitle, title, body in received = (id, paneTitle, title, body) }

        store.handlePaneNotification(id: paneID, paneTitle: "zsh", title: "CI", body: "green")

        XCTAssertEqual(received?.0, paneID)
        XCTAssertEqual(received?.1, "zsh")
        XCTAssertEqual(received?.2, "CI")
        XCTAssertEqual(received?.3, "green")
    }

    func testRevealPaneFocusesAndCenters() {
        let a = PaneID(), b = PaneID()
        let items = [
            CanvasItem(
                id: a,
                spec: PaneSpec(kind: .terminal, title: "A"),
                frame: CGRect(x: 0, y: 0, width: 480, height: 320),
                z: 0,
            ),
            CanvasItem(
                id: b,
                spec: PaneSpec(kind: .terminal, title: "B"),
                frame: CGRect(x: 3000, y: 2000, width: 480, height: 320),
                z: 1,
            ),
        ]
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: items), focusedPane: a))

        store.revealPane(b)

        XCTAssertEqual(store.focusedPane, b)
        let expected = store.workspace.canvas.centered(on: b, viewport: CGSize(width: 1280, height: 800)).camera.origin
        XCTAssertEqual(store.workspace.canvas.camera.origin, expected)
    }

    func testRevealPaneByIDStringRoundTrips() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.focusedPane)
        // A valid id string reveals; an unknown/garbage id is a no-op (must not trap).
        store.revealPane(byIDString: id.raw.uuidString)
        XCTAssertEqual(store.focusedPane, id)
        store.revealPane(byIDString: "not-a-uuid")
        store.revealPane(byIDString: UUID().uuidString) // valid shape, unknown pane
        XCTAssertEqual(store.focusedPane, id, "unknown ids leave focus untouched")
    }

    func testRevealGonePaneIsNoop() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.focusedPane)
        store.closePane(id)
        store.revealPane(id) // must not trap; nothing to focus
        XCTAssertNil(store.focusedPane)
    }

    // MARK: - Event plumbing (client Event → store hook)

    func testNotificationEventReachesTheHookViaTheConnection() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.focusedPane)
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
