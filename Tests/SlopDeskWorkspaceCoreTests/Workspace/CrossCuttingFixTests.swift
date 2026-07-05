import CoreGraphics
import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the cross-cutting state-lifecycle fixes (2026-06-13 cross-cutting hunt): a whole-canvas swap
/// (switchToLayoutPreset) must invalidate the workspace-global transients that anchor to the OLD canvas —
/// viewport bookmarks and the close-undo.
@MainActor
final class CrossCuttingFixTests: XCTestCase {
    private func store(_ items: [CanvasItem], focus: PaneID) -> WorkspaceStore {
        WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: items), focusedPane: focus),
            makeSession: { FakePaneSession($0) },
            liveVideoCap: 5,
        )
    }

    private func term(_ x: CGFloat, _ title: String = "t") -> CanvasItem {
        CanvasItem(
            id: PaneID(),
            spec: PaneSpec(kind: .terminal, title: title),
            frame: CGRect(x: x, y: 0, width: 300, height: 200),
            z: 0,
        )
    }

    func testSwitchToPresetClearsStaleBookmarks() {
        let a = term(0)
        let st = store([a], focus: a.id)
        st.saveLayoutPreset(name: "p")
        st.saveBookmark(1) // a bookmark anchored to a pane of THIS layout
        XCTAssertNotNil(st.workspace.bookmarks[1], "precondition: a bookmark exists")
        st.switchToLayoutPreset(name: "p")
        XCTAssertTrue(
            st.workspace.bookmarks.isEmpty,
            "a layout switch clears bookmarks (they anchor to the old canvas + frame)",
        )
    }

    func testSwitchClearsTheCloseUndo() {
        let a = term(0), b = term(400)
        let st = store([a, b], focus: a.id)
        st.saveLayoutPreset(name: "p")
        st.closePane(b.id)
        XCTAssertNotNil(st.recentlyClosed, "precondition: a close was recorded")
        st.switchToLayoutPreset(name: "p")
        XCTAssertNil(st.recentlyClosed, "switch clears the close-undo (it points at the old workspace)")
        XCTAssertNil(st.reopenClosedPane(), "Reopen is a no-op after a switch")
    }
}
