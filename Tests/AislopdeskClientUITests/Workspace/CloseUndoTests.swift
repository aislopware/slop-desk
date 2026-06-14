import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the close-undo ("Reopen Closed Pane") + busy-shell close-guard contract of ``WorkspaceStore``:
///
/// - ``WorkspaceStore/closePane(_:)`` records a single-slot ``WorkspaceStore/RecentlyClosedPane``
///   (spec + exact frame + group) for every NON-ephemeral pane; ephemeral system-dialog panes are
///   auto-managed and never recorded.
/// - ``WorkspaceStore/reopenClosedPane()`` restores the spec at the exact former frame with a FRESH
///   ``PaneID`` (the old session teardown is async — reusing the id would race it), focuses + raises
///   the pane, rejoins a still-existing group (a deleted group degrades to ungrouped), consumes the
///   slot, and materializes a session (the registry invariant holds).
/// - ``WorkspaceStore/requestClosePane(_:)`` closes an idle-shell pane immediately, but PARKS a
///   busy-shell pane behind ``WorkspaceStore/pendingClose`` until confirmed/cancelled — the dialog
///   the root view hosts.
/// - The ⇧⌘T chord maps to `.reopenClosedPane`, and `apply` routes `.closePane` through the guard.
///
/// Same seam as every store suite: the ``FakePaneSession`` factory, never a real client/host.
@MainActor
final class CloseUndoTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) })
    }

    /// A two-pane workspace with known frames (so frame restoration is assertable).
    private func twoPaneWorkspace() -> (Workspace, PaneID, PaneID) {
        let a = PaneID(), b = PaneID()
        let items = [
            CanvasItem(
                id: a,
                spec: PaneSpec(kind: .terminal, title: "A"),
                frame: CGRect(x: 100, y: 100, width: 480, height: 320),
                z: 0,
            ),
            CanvasItem(
                id: b,
                spec: PaneSpec(kind: .terminal, title: "B"),
                frame: CGRect(x: 700, y: 100, width: 480, height: 320),
                z: 1,
            ),
        ]
        return (Workspace(canvas: Canvas(items: items), focusedPane: a), a, b)
    }

    // MARK: - Recording

    func testCloseRecordsSpecFrameAndGroup() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        let gid = store.addGroup(name: "G")
        store.assignPane(a, toGroup: gid)
        let frame = store.workspace.canvas.frame(of: a)

        store.closePane(a)

        let record = store.recentlyClosed
        XCTAssertEqual(record?.spec.title, "A")
        XCTAssertEqual(record?.spec.kind, .terminal)
        XCTAssertEqual(record?.frame, frame)
        XCTAssertEqual(record?.group, gid)
    }

    func testEphemeralDialogCloseIsNotRecorded() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        let dialogID = store.addSystemDialogPane(windowID: 42, owner: "SecurityAgent", title: "sudo", isSecure: true)

        store.closePane(dialogID)

        XCTAssertNil(store.recentlyClosed, "ephemeral system-dialog closes must not occupy the reopen slot")
    }

    func testNewerCloseReplacesTheSlot() {
        let (ws, a, b) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.closePane(a)
        store.closePane(b)
        XCTAssertEqual(store.recentlyClosed?.spec.title, "B", "single slot — the last close wins")
    }

    // MARK: - Reopen

    func testReopenRestoresFrameFocusGroupAndMaterializes() async throws {
        let (ws, a, b) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        let gid = store.addGroup(name: "G")
        store.assignPane(a, toGroup: gid)
        let originalFrame = store.workspace.canvas.frame(of: a)

        store.closePane(a)
        await store.quiesce()
        let reopened = store.reopenClosedPane()

        let id = try XCTUnwrap(reopened)
        XCTAssertNotEqual(id, a, "reopen mints a FRESH id (old teardown is async)")
        XCTAssertEqual(store.workspace.canvas.frame(of: id), originalFrame, "exact former frame")
        XCTAssertEqual(store.workspace.canvas.spec(for: id)?.title, "A")
        XCTAssertEqual(store.focusedPane, id)
        XCTAssertEqual(store.workspace.canvas.item(id)?.groupID, gid, "rejoins the surviving group")
        XCTAssertNotNil(store.handle(for: id), "session materialized for the reopened pane")
        XCTAssertEqual(store.handle(for: id)?.id, id, "handle adopted the new pane id")
        XCTAssertGreaterThan(
            try XCTUnwrap(store.workspace.canvas.item(id)?.z),
            try XCTUnwrap(store.workspace.canvas.item(b)?.z),
            "reopened pane is frontmost",
        )
        XCTAssertNil(store.recentlyClosed, "the slot is consumed")
    }

    func testReopenAfterDeletedGroupDegradesToUngrouped() throws {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        let gid = store.addGroup(name: "G")
        store.assignPane(a, toGroup: gid)

        store.closePane(a)
        store.removeGroup(gid)
        let reopened = store.reopenClosedPane()

        let id = try XCTUnwrap(reopened)
        XCTAssertNil(
            store.workspace.canvas.item(id)?.groupID,
            "a dead group must not be restored (dangling groupID)",
        )
    }

    func testReopenLastClosedPaneFromEmptyCanvas() {
        let a = PaneID()
        let ws = Workspace(canvas: Canvas(items: [CanvasItem(
            id: a, spec: PaneSpec(kind: .terminal, title: "Solo"),
            frame: CGRect(x: 0, y: 0, width: 480, height: 320), z: 0,
        )]), focusedPane: a)
        let store = makeStore(restoring: ws)

        store.closePane(a)
        XCTAssertTrue(store.workspace.canvas.items.isEmpty)
        XCTAssertNil(store.focusedPane)

        let id = store.reopenClosedPane()
        XCTAssertNotNil(id)
        XCTAssertEqual(store.workspace.canvas.items.count, 1)
        XCTAssertEqual(store.focusedPane, id)
    }

    func testReopenWithEmptySlotIsNoop() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        XCTAssertNil(store.reopenClosedPane())
        XCTAssertEqual(store.workspace.canvas.items.count, 2)
    }

    // MARK: - Busy-shell close guard

    func testRequestCloseIdleShellClosesImmediately() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)

        store.requestClosePane(a)

        XCTAssertFalse(store.workspace.canvas.contains(a))
        XCTAssertNil(store.pendingClose)
    }

    func testRequestCloseBusyShellParksBehindConfirmation() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        (store.handle(for: a) as? FakePaneSession)?.isShellBusy = true

        store.requestClosePane(a)

        XCTAssertTrue(store.workspace.canvas.contains(a), "busy pane must NOT close yet")
        XCTAssertEqual(store.pendingClose, a)

        store.confirmPendingClose()
        XCTAssertFalse(store.workspace.canvas.contains(a))
        XCTAssertNil(store.pendingClose)
    }

    func testCancelPendingCloseKeepsThePane() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        (store.handle(for: a) as? FakePaneSession)?.isShellBusy = true

        store.requestClosePane(a)
        store.cancelPendingClose()

        XCTAssertTrue(store.workspace.canvas.contains(a))
        XCTAssertNil(store.pendingClose)
        store.confirmPendingClose() // nothing pending — must be a no-op
        XCTAssertTrue(store.workspace.canvas.contains(a))
    }

    func testDirectCloseClearsAMatchingPendingClose() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        (store.handle(for: a) as? FakePaneSession)?.isShellBusy = true
        store.requestClosePane(a)
        XCTAssertEqual(store.pendingClose, a)

        store.closePane(a) // e.g. another path closed it while the dialog was up

        XCTAssertNil(store.pendingClose, "a stale pendingClose must not survive the pane")
    }

    // MARK: - Command wiring

    func testShiftCmdTMapsToReopenClosedPane() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(
            interpreter.feed(KeyChord(character: "t", [.command, .shift])),
            .reopenClosedPane,
        )
    }

    func testApplyClosePaneRoutesThroughBusyGuard() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        (store.handle(for: a) as? FakePaneSession)?.isShellBusy = true
        store.focus(a)

        apply(.closePane, to: store)

        XCTAssertTrue(store.workspace.canvas.contains(a), "apply(.closePane) must respect the guard")
        XCTAssertEqual(store.pendingClose, a)
    }

    func testApplyReopenClosedPane() throws {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.focus(a)
        apply(.closePane, to: store)
        XCTAssertFalse(store.workspace.canvas.contains(a))

        apply(.reopenClosedPane, to: store)

        XCTAssertEqual(store.workspace.canvas.items.count, 2)
        XCTAssertEqual(try store.workspace.canvas.spec(for: XCTUnwrap(store.focusedPane))?.title, "A")
    }
}
