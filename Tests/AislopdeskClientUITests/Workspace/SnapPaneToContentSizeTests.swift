import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins ``WorkspaceStore/snapPaneToContentSize(_:target:current:)`` — the 1:1 remote-GUI snap
/// (2026-06-11 "pane resizes to match the virtual display"). The video view reports the stream's
/// native point size (`target`) and the video view's current point size (`current`); the store
/// resizes the pane FRAME by the CONTENT delta, so the chrome inset (header + divider) needs no
/// constant and the snap stays correct if the chrome ever changes.
///
/// `WorkspaceStore` is `@MainActor`; the suite uses the spec-only `FakePaneSession` seam.
@MainActor
final class SnapPaneToContentSizeTests: XCTestCase {
    private func makeStoreWithPane() -> (WorkspaceStore, PaneID, CGRect) {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        store.addPane(kind: .remoteGUI)
        let id = store.workspace.focusedPane!
        let frame = store.workspace.canvas.frame(of: id)!
        return (store, id, frame)
    }

    /// The pane frame moves by exactly the CONTENT delta (target − current), origin pinned —
    /// growing right/down with no jump under the cursor, chrome inset untouched.
    func testSnapAdjustsFrameByContentDeltaKeepingOrigin() throws {
        let (store, id, before) = makeStoreWithPane()

        // The video content must go 1200×800 → 1331×829 (the stream's 1:1 size): Δ = (+131, +29).
        store.snapPaneToContentSize(
            id,
            target: CGSize(width: 1331, height: 829),
            current: CGSize(width: 1200, height: 800),
        )

        let after = try XCTUnwrap(store.workspace.canvas.frame(of: id))
        XCTAssertEqual(after.origin, before.origin, "origin stays pinned — the pane grows right/down")
        XCTAssertEqual(after.width, before.width + 131)
        XCTAssertEqual(after.height, before.height + 29)
    }

    /// A shrink (host window smaller than the pane) works symmetrically.
    func testSnapShrinksWhenStreamIsSmaller() throws {
        let (store, id, before) = makeStoreWithPane()

        store.snapPaneToContentSize(
            id,
            target: CGSize(width: 800, height: 600),
            current: CGSize(width: 1000, height: 700),
        )

        let after = try XCTUnwrap(store.workspace.canvas.frame(of: id))
        XCTAssertEqual(after.width, before.width - 200)
        XCTAssertEqual(after.height, before.height - 100)
    }

    /// A sub-half-point delta is layout noise — the canvas value must stay IDENTICAL (no
    /// persistence churn, no re-render).
    func testSubHalfPointDeltaIsIgnored() {
        let (store, id, _) = makeStoreWithPane()
        let canvasBefore = store.workspace.canvas

        store.snapPaneToContentSize(
            id,
            target: CGSize(width: 1200.3, height: 800.2),
            current: CGSize(width: 1200.0, height: 800.0),
        )

        XCTAssertEqual(store.workspace.canvas, canvasBefore, "noise must not mutate the canvas")
    }

    /// While the pane is MAXIMIZED its on-screen size is the viewport override; mutating the
    /// underlying frame would surprise the restore — the snap is skipped.
    func testSnapSkippedWhileMaximized() {
        let (store, id, before) = makeStoreWithPane()
        store.toggleZoom() // focused pane == id → maximized
        XCTAssertEqual(store.workspace.maximizedPane, id, "precondition: the pane is maximized")

        store.snapPaneToContentSize(
            id,
            target: CGSize(width: 1331, height: 829),
            current: CGSize(width: 1200, height: 800),
        )

        XCTAssertEqual(store.workspace.canvas.frame(of: id), before, "frame untouched while maximized")
    }

    /// An unknown pane id is a safe no-op (the pane closed while the snap hopped actors).
    func testUnknownPaneIsANoOp() {
        let (store, _, _) = makeStoreWithPane()
        let canvasBefore = store.workspace.canvas

        store.snapPaneToContentSize(
            PaneID(),
            target: CGSize(width: 1331, height: 829),
            current: CGSize(width: 1200, height: 800),
        )

        XCTAssertEqual(store.workspace.canvas, canvasBefore)
    }
}
