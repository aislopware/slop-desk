import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins "Resize to Native Stream Size": snapPaneToContentSize caches the native frame size, and
/// resizeToNativeSize restores it (origin pinned) after a manual resize.
@MainActor
final class SnapToNativeTests: XCTestCase {
    private func remoteStore() -> (WorkspaceStore, PaneID) {
        let id = PaneID()
        let item = CanvasItem(
            id: id,
            spec: PaneSpec(
                kind: .remoteGUI,
                title: "win",
                video: VideoEndpoint(windowID: 1, title: "win"),
            ),
            frame: CGRect(x: 50, y: 60, width: 800, height: 600),
            z: 0,
        )
        let store = WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: [item]), focusedPane: id),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
        return (store, id)
    }

    func testNoNativeSizeUntilReported() {
        let (store, id) = remoteStore()
        XCTAssertFalse(store.hasNativeSize(id))
        store.resizeToNativeSize(id) // no-op, no trap
        XCTAssertEqual(store.workspace.canvas.frame(of: id)?.size, CGSize(width: 800, height: 600))
    }

    func testSnapCachesNativeFrameAndResizeRestoresIt() throws {
        let (store, id) = remoteStore()
        // The stream reports native content 1280×720 vs current content 760×560 (chrome inset 40).
        // snap adjusts the frame by the content delta and caches the native frame size.
        store.snapPaneToContentSize(
            id,
            target: CGSize(width: 1280, height: 720),
            current: CGSize(width: 760, height: 560),
        )
        XCTAssertTrue(store.hasNativeSize(id))
        let nativeFrame = try XCTUnwrap(store.workspace.canvas.frame(of: id)?.size)
        XCTAssertEqual(nativeFrame, CGSize(width: 800 + 520, height: 600 + 160)) // 1320×760

        // User manually shrinks the pane.
        store.resizePane(id, to: CGRect(x: 50, y: 60, width: 400, height: 300))
        XCTAssertEqual(store.workspace.canvas.frame(of: id)?.size, CGSize(width: 400, height: 300))

        // Resize to native restores the cached size, origin pinned.
        store.resizeToNativeSize(id)
        XCTAssertEqual(store.workspace.canvas.frame(of: id)?.size, nativeFrame)
        XCTAssertEqual(store.workspace.canvas.frame(of: id)?.origin, CGPoint(x: 50, y: 60), "origin pinned")
    }
}
