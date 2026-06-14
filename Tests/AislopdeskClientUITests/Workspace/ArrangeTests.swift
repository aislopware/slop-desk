import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the pure align + distribute Canvas ops and the store's Arrange targeting (multi-selection or
/// all panes) + multi-selection state and group move-together.
@MainActor
final class ArrangeTests: XCTestCase {
    private let eps: CGFloat = 1e-6

    private func item(_ id: PaneID, _ frame: CGRect) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: .terminal, title: "p"), frame: frame, z: 0)
    }

    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    // MARK: - Align (pure)

    func testAlignLeftMovesAllToBoundingMinX() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let canvas = Canvas(items: [
            item(a, CGRect(x: 100, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 40, y: 200, width: 100, height: 80)),
            item(c, CGRect(x: 300, y: 400, width: 100, height: 80)),
        ])
        let out = canvas.aligning([a, b, c], to: .left)
        for id in [a, b, c] {
            XCTAssertEqual(try XCTUnwrap(out.frame(of: id)?.minX), 40, accuracy: eps, "all left edges at bbox.minX")
        }
        // Y untouched.
        XCTAssertEqual(try XCTUnwrap(out.frame(of: c)?.minY), 400, accuracy: eps)
    }

    func testAlignCenterVerticalUsesBoxMidY() throws {
        // Frames ≥ minItemSize (160×120) so Canvas.sanitize never resizes them under us.
        let a = PaneID(), b = PaneID()
        let canvas = Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 160, height: 120)), // 0..120
            item(b, CGRect(x: 0, y: 120, width: 160, height: 120)), // 120..240
        ])
        let out = canvas.aligning([a, b], to: .centerVertical)
        let boxMidY: CGFloat = 120 // bbox 0..240 → mid 120
        XCTAssertEqual(try XCTUnwrap(out.frame(of: a)?.midY), boxMidY, accuracy: eps)
        XCTAssertEqual(try XCTUnwrap(out.frame(of: b)?.midY), boxMidY, accuracy: eps)
    }

    func testAlignNoopForFewerThanTwo() {
        let a = PaneID()
        let canvas = Canvas(items: [item(a, CGRect(x: 5, y: 5, width: 10, height: 10))])
        XCTAssertEqual(canvas.aligning([a], to: .left).frame(of: a), CGRect(x: 5, y: 5, width: 10, height: 10))
    }

    // MARK: - Distribute (pure)

    func testDistributeHorizontalEqualisesGaps() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        // a at 0..100, c at 400..500, b crammed near a → should land centred with equal gaps.
        let canvas = Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 100, height: 50)),
            item(b, CGRect(x: 110, y: 0, width: 100, height: 50)),
            item(c, CGRect(x: 400, y: 0, width: 100, height: 50)),
        ])
        let out = canvas.distributing([a, b, c], horizontal: true)
        // span 0..500 = 500; sumWidths 300; gap = (500-300)/2 = 100. a:0..100, b:200..300, c:400..500.
        XCTAssertEqual(try XCTUnwrap(out.frame(of: a)?.minX), 0, accuracy: eps)
        XCTAssertEqual(try XCTUnwrap(out.frame(of: b)?.minX), 200, accuracy: eps)
        XCTAssertEqual(try XCTUnwrap(out.frame(of: c)?.minX), 400, accuracy: eps)
        // Gaps equal.
        let gap1 = try XCTUnwrap(out.frame(of: b)?.minX) - out.frame(of: a)!.maxX
        let gap2 = try XCTUnwrap(out.frame(of: c)?.minX) - out.frame(of: b)!.maxX
        XCTAssertEqual(gap1, gap2, accuracy: eps)
    }

    func testDistributeNoopForFewerThanThree() throws {
        let a = PaneID(), b = PaneID()
        let canvas = Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 50, height: 50)),
            item(b, CGRect(x: 500, y: 0, width: 50, height: 50)),
        ])
        XCTAssertEqual(
            try XCTUnwrap(canvas.distributing([a, b], horizontal: true).frame(of: b)?.minX),
            500,
            accuracy: eps,
        )
    }

    func testDistributeClampsNegativeGapSoPanesNeverOverlap() throws {
        // Panes collectively WIDER than their span ⇒ the ideal even gap is negative. The old code placed
        // them overlapping; the clamp packs them flush (gap 0) instead. Widths ≥ minItemSize so sanitize
        // doesn't resize the math out from under us.
        let a = PaneID(), b = PaneID(), c = PaneID()
        let canvas = Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 200, height: 120)), // 0..200
            item(b, CGRect(x: 50, y: 0, width: 200, height: 120)),
            item(c, CGRect(x: 100, y: 0, width: 200, height: 120)), // span = 300, sumWidths = 600
        ])
        let out = canvas.distributing([a, b, c], horizontal: true)
        let fa = try XCTUnwrap(out.frame(of: a)), fb = try XCTUnwrap(out.frame(of: b)),
            fc = try XCTUnwrap(out.frame(of: c))
        XCTAssertGreaterThanOrEqual(fb.minX, fa.maxX - eps, "b must not overlap a")
        XCTAssertGreaterThanOrEqual(fc.minX, fb.maxX - eps, "c must not overlap b")
        // Flush packing: the clamped gap is exactly 0.
        XCTAssertEqual(fb.minX - fa.maxX, 0, accuracy: 1e-3)
        XCTAssertEqual(fc.minX - fb.maxX, 0, accuracy: 1e-3)
    }

    // MARK: - Store targeting + selection

    func testArrangeTargetsAllWhenNoSelection() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 100, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 40, y: 0, width: 100, height: 80)),
            item(c, CGRect(x: 300, y: 0, width: 100, height: 80)),
        ]), focusedPane: a))
        store.alignPanes(to: .left)
        for id in [a, b, c] { XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: id)?.minX),
            40,
            accuracy: eps,
        ) }
    }

    func testArrangeTargetsOnlySelectionWhenSet() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 100, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 40, y: 0, width: 100, height: 80)),
            item(c, CGRect(x: 300, y: 0, width: 100, height: 80)),
        ]), focusedPane: a))
        store.setSelection([a, b]) // c excluded
        store.alignPanes(to: .left)
        XCTAssertEqual(try XCTUnwrap(store.workspace.canvas.frame(of: a)?.minX), 40, accuracy: eps)
        XCTAssertEqual(try XCTUnwrap(store.workspace.canvas.frame(of: b)?.minX), 40, accuracy: eps)
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: c)?.minX),
            300,
            accuracy: eps,
            "unselected pane untouched",
        )
    }

    // MARK: - Command routing (align / distribute / save-layout reachable from ⌘K + menu)

    func testApplyAlignCommandRoutesToAlignPanes() throws {
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 100, y: 0, width: 160, height: 120)),
            item(b, CGRect(x: 40, y: 300, width: 160, height: 120)),
        ]), focusedPane: a))
        store.setSelection([a, b])
        apply(.align(.left), to: store)
        XCTAssertEqual(try XCTUnwrap(store.workspace.canvas.frame(of: a)?.minX), 40, accuracy: eps)
        XCTAssertEqual(try XCTUnwrap(store.workspace.canvas.frame(of: b)?.minX), 40, accuracy: eps)
    }

    func testApplyDistributeCommandRoutesToDistribute() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 160, height: 120)),
            item(b, CGRect(x: 200, y: 0, width: 160, height: 120)), // crammed; distribute re-spaces it
            item(c, CGRect(x: 1000, y: 0, width: 160, height: 120)),
        ]), focusedPane: a))
        store.setSelection([a, b, c])
        apply(.distribute(horizontal: true), to: store)
        // Equal gaps: a stays at 0, c stays at its right edge; b's gap to a equals c's gap to b.
        let fa = try XCTUnwrap(store.workspace.canvas.frame(of: a)),
            fb = try XCTUnwrap(store.workspace.canvas.frame(of: b)),
            fc = try XCTUnwrap(store.workspace.canvas.frame(of: c))
        XCTAssertEqual(fb.minX - fa.maxX, fc.minX - fb.maxX, accuracy: 1e-3, "distribute equalised the horizontal gaps")
    }

    func testApplySaveLayoutOpensTheSavePrompt() {
        let store = makeStore()
        XCTAssertFalse(store.pendingSaveLayout)
        apply(.saveLayout, to: store)
        XCTAssertTrue(store.pendingSaveLayout, "the command opens the Save Current Layout… prompt")
    }

    func testSelectAllPanesSelectsEveryPaneAndRoutes() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 160, height: 120)),
            item(b, CGRect(x: 200, y: 0, width: 160, height: 120)),
            item(c, CGRect(x: 400, y: 0, width: 160, height: 120)),
        ]), focusedPane: a))
        apply(.selectAllPanes, to: store)
        XCTAssertEqual(store.selectedPanes, Set([a, b, c]), "every pane is selected")
    }

    func testSelectAllPanesBoundToOptCmdANotBareCmdA() {
        let interp = CommandInterpreter()
        XCTAssertEqual(interp.feed(KeyChord(character: "a", [.option, .command])), .selectAllPanes)
        // Bare ⌘A must stay UNBOUND — it is the focused terminal's select-all-text (the §5 conflict rule).
        XCTAssertNil(interp.feed(KeyChord(character: "a", [.command])))
    }

    func testToggleAndClearSelection() {
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 200, y: 0, width: 100, height: 80)),
        ]), focusedPane: a))
        store.toggleSelection(a)
        store.toggleSelection(b)
        XCTAssertEqual(store.selectedPanes, [a, b])
        store.toggleSelection(a)
        XCTAssertEqual(store.selectedPanes, [b])
        store.clearSelection()
        XCTAssertTrue(store.selectedPanes.isEmpty)
    }

    func testSelectionPrunedWhenPaneCloses() {
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 200, y: 0, width: 100, height: 80)),
        ]), focusedPane: a))
        store.setSelection([a, b])
        store.closePane(b)
        XCTAssertEqual(store.selectedPanes, [a], "a closed pane drops out of the selection")
    }

    func testMoveSelectionTranslatesAllAndRaisesAnchor() {
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 200, y: 0, width: 100, height: 80)),
        ]), focusedPane: a))
        store.setSelection([a, b])
        store.moveSelection(by: CGSize(width: 50, height: 30), anchor: a)
        XCTAssertEqual(store.workspace.canvas.frame(of: a)?.origin, CGPoint(x: 50, y: 30))
        XCTAssertEqual(store.workspace.canvas.frame(of: b)?.origin, CGPoint(x: 250, y: 30))
        XCTAssertEqual(store.focusedPane, a, "the dragged anchor is focused")
    }

    func testMoveSelectionNoopWhenAnchorNotSelected() throws {
        let a = PaneID(), b = PaneID()
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: [
            item(a, CGRect(x: 0, y: 0, width: 100, height: 80)),
            item(b, CGRect(x: 200, y: 0, width: 100, height: 80)),
        ]), focusedPane: a))
        store.setSelection([b])
        store.moveSelection(by: CGSize(width: 50, height: 0), anchor: a)
        XCTAssertEqual(
            try XCTUnwrap(store.workspace.canvas.frame(of: b)?.minX),
            200,
            "single-pane move falls back, group untouched",
        )
    }
}
