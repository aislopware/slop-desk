import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the four cross-cutting state-lifecycle fixes (2026-06-13 cross-cutting hunt): a whole-canvas swap
/// (switchToLayoutPreset / importWorkspace.replace) must invalidate the workspace-global transients that
/// anchor to the OLD canvas — viewport bookmarks, the close-undo, and armed broadcast — and a repeated
/// identical merge must content-dedup instead of growing the snippet/preset library.
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

    func testSwitchAndImportReplaceClearTheCloseUndo() throws {
        // switch path
        let a = term(0), b = term(400)
        let st = store([a, b], focus: a.id)
        st.saveLayoutPreset(name: "p")
        st.closePane(b.id)
        XCTAssertNotNil(st.recentlyClosed, "precondition: a close was recorded")
        st.switchToLayoutPreset(name: "p")
        XCTAssertNil(st.recentlyClosed, "switch clears the close-undo (it points at the old workspace)")
        XCTAssertNil(st.reopenClosedPane(), "Reopen is a no-op after a switch")

        // import-replace path
        let src = store([term(0, "alpha")], focus: PaneID())
        let data = src.exportWorkspaceData()
        let dst = store([term(0), term(400, "z")], focus: PaneID())
        try dst.closePane(XCTUnwrap(dst.workspace.canvas.allIDs().last))
        XCTAssertNotNil(dst.recentlyClosed)
        XCTAssertTrue(dst.importWorkspace(data, mode: .replace))
        XCTAssertNil(dst.recentlyClosed, "import-replace clears the close-undo")
    }

    func testImportReplaceDisarmsBroadcast() {
        let src = store([term(0, "a")], focus: PaneID())
        let data = src.exportWorkspaceData()
        let st = store([term(0), term(400)], focus: PaneID())
        st.toggleBroadcast()
        XCTAssertTrue(st.broadcastActive, "precondition: broadcast armed")
        XCTAssertTrue(st.importWorkspace(data, mode: .replace))
        XCTAssertFalse(st.broadcastActive, "a whole-canvas swap disarms synchronized input")
    }

    func testRepeatedIdenticalMergeDoesNotGrowLibrary() {
        let src = store([term(0, "alpha")], focus: PaneID())
        src.addSnippet(name: "s", body: "make build<Enter>")
        src.saveLayoutPreset(name: "p")
        let data = src.exportWorkspaceData()

        let dst = store([term(0, "x")], focus: PaneID())
        XCTAssertTrue(dst.importWorkspace(data, mode: .mergeAppend))
        let snippetsAfterFirst = dst.snippets.count
        let presetsAfterFirst = dst.workspace.layoutPresets.count
        XCTAssertEqual(snippetsAfterFirst, 1)
        XCTAssertEqual(presetsAfterFirst, 1)

        XCTAssertTrue(dst.importWorkspace(data, mode: .mergeAppend)) // identical re-merge
        XCTAssertEqual(dst.snippets.count, snippetsAfterFirst, "content-identical snippet is not re-added")
        XCTAssertEqual(dst.workspace.layoutPresets.count, presetsAfterFirst, "content-identical preset is not re-added")
    }
}
