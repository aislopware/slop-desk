import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the viewport-bookmark contract (⇧⌘1–9 save / ⌘1–9 recall):
///
/// - ``WorkspaceStore/saveBookmark(_:)`` records the focused pane (the recall anchor), the current
///   camera origin (after folding any in-flight scroll pan), and the pane's title as the name.
/// - ``WorkspaceStore/recallBookmark(_:)`` FOLLOWS the anchor pane when it still exists (focus +
///   centre — live panes relocate, raw coordinates go stale), and falls back to the raw camera
///   origin when the pane is gone. Empty slots are no-ops; slots outside 1–9 never record.
/// - The chord table maps ⇧⌘n → `.saveBookmark(n)` and ⌘n → `.recallBookmark(n)` for all nine slots,
///   and bookmarks round-trip through the Codable workspace (they persist).
@MainActor
final class BookmarkTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) })
    }

    /// The store's default viewport (no view has reported one in headless tests).
    private let viewport = CGSize(width: 1280, height: 800)

    private func twoPaneWorkspace() -> (Workspace, PaneID, PaneID) {
        let a = PaneID(), b = PaneID()
        let items = [
            CanvasItem(
                id: a,
                spec: PaneSpec(kind: .terminal, title: "Build"),
                frame: CGRect(x: 100, y: 100, width: 480, height: 320),
                z: 0,
            ),
            CanvasItem(
                id: b,
                spec: PaneSpec(kind: .terminal, title: "Logs"),
                frame: CGRect(x: 2000, y: 1500, width: 480, height: 320),
                z: 1,
            ),
        ]
        return (Workspace(canvas: Canvas(items: items), focusedPane: a), a, b)
    }

    // MARK: - Save

    func testSaveRecordsAnchorCameraAndName() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.commitCamera(CanvasCamera(origin: CGPoint(x: 40, y: 60)))

        store.saveBookmark(3)

        let bookmark = store.workspace.bookmarks[3]
        XCTAssertEqual(bookmark?.pane, a)
        XCTAssertEqual(bookmark?.cameraOrigin, CGPoint(x: 40, y: 60))
        XCTAssertEqual(bookmark?.name, "Build")
    }

    func testSaveFoldsInFlightScrollPanFirst() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.commitCamera(CanvasCamera(origin: .zero))
        // A live scroll that has NOT committed yet (the 110ms debounce hasn't fired): the camera the
        // user SEES is offset; the bookmark must capture that, not the stale committed origin.
        store.scrollPan(by: CGSize(width: 100, height: 50))

        store.saveBookmark(1)

        XCTAssertEqual(
            store.workspace.bookmarks[1]?.cameraOrigin,
            CGPoint(x: 100, y: 50),
            "the in-flight scroll folds into the camera before the save reads it",
        )
        XCTAssertEqual(store.liveCameraOffset, .zero, "nothing left pending")
    }

    func testInvalidSlotsNeverRecord() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.saveBookmark(0)
        store.saveBookmark(10)
        XCTAssertTrue(store.workspace.bookmarks.isEmpty)
    }

    // MARK: - Recall

    func testRecallFollowsSurvivingPane() {
        let (ws, a, b) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.focus(b)
        store.saveBookmark(2) // anchored to "Logs" at (2000,1500)
        store.focus(a)
        // The pane MOVES after the save — recall must follow it, not the stale coordinate.
        store.movePane(b, by: CGSize(width: 500, height: 0))
        store.commitCamera(CanvasCamera(origin: .zero))

        store.recallBookmark(2)

        XCTAssertEqual(store.focusedPane, b, "recall focuses the anchor pane")
        let expected = store.workspace.canvas.centered(on: b, viewport: viewport).camera.origin
        XCTAssertEqual(
            store.workspace.canvas.camera.origin,
            expected,
            "recall centres the pane at its CURRENT position",
        )
    }

    func testRecallFallsBackToRawCameraWhenPaneGone() {
        let (ws, a, b) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.commitCamera(CanvasCamera(origin: CGPoint(x: 77, y: 33)))
        store.focus(b)
        store.saveBookmark(4)
        store.closePane(b)
        store.commitCamera(CanvasCamera(origin: .zero))

        store.recallBookmark(4)

        XCTAssertEqual(
            store.workspace.canvas.camera.origin,
            CGPoint(x: 77, y: 33),
            "anchor gone → the raw saved viewport comes back",
        )
        XCTAssertEqual(store.focusedPane, a, "focus untouched by a camera-only recall")
    }

    func testRecallEmptySlotIsNoop() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.commitCamera(CanvasCamera(origin: CGPoint(x: 5, y: 5)))
        store.recallBookmark(7)
        XCTAssertEqual(store.workspace.canvas.camera.origin, CGPoint(x: 5, y: 5))
    }

    // MARK: - Chords + apply routing

    func testChordTableCoversAllNineSlots() {
        let interpreter = CommandInterpreter()
        for n in 1...9 {
            let digit = Character("\(n)")
            XCTAssertEqual(
                interpreter.feed(KeyChord(character: digit, [.command, .shift])),
                .saveBookmark(n),
            )
            XCTAssertEqual(
                interpreter.feed(KeyChord(character: digit, [.command])),
                .recallBookmark(n),
            )
        }
    }

    func testApplyRoutesBookmarkCommands() {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        apply(.saveBookmark(5), to: store)
        XCTAssertEqual(store.workspace.bookmarks[5]?.pane, a)
        store.commitCamera(CanvasCamera(origin: CGPoint(x: 999, y: 999)))
        apply(.recallBookmark(5), to: store)
        let expected = store.workspace.canvas.centered(on: a, viewport: viewport).camera.origin
        XCTAssertEqual(store.workspace.canvas.camera.origin, expected)
    }

    // MARK: - Persistence round-trip

    func testBookmarksSurviveCodableRoundTrip() throws {
        let (ws, a, _) = twoPaneWorkspace()
        var workspace = ws
        workspace.bookmarks[8] = CanvasBookmark(pane: a, cameraOrigin: CGPoint(x: 1, y: 2), name: "Build")

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded.bookmarks[8]?.pane, a)
        XCTAssertEqual(decoded.bookmarks[8]?.cameraOrigin, CGPoint(x: 1, y: 2))
        XCTAssertEqual(decoded.bookmarks[8]?.name, "Build")
    }
}
