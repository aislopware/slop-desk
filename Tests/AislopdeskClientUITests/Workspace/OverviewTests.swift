import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the fit-all overview: the pure ``CanvasGeometry/overviewLayout`` (scale to fit all panes,
/// centred, never magnified past 1×) and the store's overview presentation state + command wiring.
@MainActor
final class OverviewTests: XCTestCase {
    private let eps: CGFloat = 1e-6

    private func item(_ id: PaneID, _ frame: CGRect) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: .terminal, title: "p"), frame: frame, z: 0)
    }

    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) })
    }

    // MARK: - Geometry

    func testEmptyCanvasOverviewIsIdentity() {
        let layout = CanvasGeometry.overviewLayout([], viewport: CGSize(width: 1000, height: 800))
        XCTAssertEqual(layout.scale, 1)
        XCTAssertTrue(layout.cards.isEmpty)
    }

    func testSingleSmallPaneIsNotMagnified() throws {
        let id = PaneID()
        let layout = CanvasGeometry.overviewLayout(
            [item(id, CGRect(x: 0, y: 0, width: 200, height: 150))],
            viewport: CGSize(width: 1000, height: 800),
            padding: 48,
        )
        XCTAssertEqual(layout.scale, 1, "a pane that already fits is never zoomed IN")
        // Centred: card centre == viewport centre.
        let card = try XCTUnwrap(layout.cards[id])
        XCTAssertEqual(card.midX, 500, accuracy: eps)
        XCTAssertEqual(card.midY, 400, accuracy: eps)
    }

    func testLargeSpreadIsScaledToFitWithPadding() throws {
        let a = PaneID(), b = PaneID()
        // Bounding box 4000 wide → must scale down to fit a 1000-wide viewport (minus padding).
        let items = [
            item(a, CGRect(x: 0, y: 0, width: 500, height: 400)),
            item(b, CGRect(x: 3500, y: 0, width: 500, height: 400)),
        ]
        let vp = CGSize(width: 1000, height: 800)
        let layout = CanvasGeometry.overviewLayout(items, viewport: vp, padding: 48)
        XCTAssertLessThan(layout.scale, 1, "a wide spread scales down")
        // Both cards fit inside the viewport.
        for card in layout.cards.values {
            XCTAssertGreaterThanOrEqual(card.minX, -eps)
            XCTAssertLessThanOrEqual(card.maxX, vp.width + eps)
            XCTAssertGreaterThanOrEqual(card.minY, -eps)
            XCTAssertLessThanOrEqual(card.maxY, vp.height + eps)
        }
        // Relative geometry preserved: b is right of a.
        XCTAssertGreaterThan(try XCTUnwrap(layout.cards[b]?.minX), try XCTUnwrap(layout.cards[a]?.minX))
    }

    // MARK: - Store state + commands

    func testToggleOverviewOnNonEmptyCanvas() {
        let store = makeStore() // default workspace has one pane
        XCTAssertFalse(store.overviewActive)
        store.toggleOverview()
        XCTAssertTrue(store.overviewActive)
        store.toggleOverview()
        XCTAssertFalse(store.overviewActive)
    }

    func testToggleOverviewNoopOnEmptyCanvas() throws {
        let store = makeStore()
        try store.closePane(XCTUnwrap(store.focusedPane))
        XCTAssertTrue(store.workspace.canvas.items.isEmpty)
        store.toggleOverview()
        XCTAssertFalse(store.overviewActive, "nothing to overview on an empty canvas")
    }

    func testOverviewExitsMaximize() {
        let store = makeStore()
        store.toggleZoom()
        XCTAssertNotNil(store.workspace.maximizedPane)
        store.toggleOverview()
        XCTAssertTrue(store.overviewActive)
        XCTAssertNil(store.workspace.maximizedPane, "the two full-canvas modes are mutually exclusive")
    }

    func testSelectFromOverviewJumpsAndExits() {
        let a = PaneID(), b = PaneID()
        let items = [
            item(a, CGRect(x: 0, y: 0, width: 480, height: 320)),
            item(b, CGRect(x: 3000, y: 2000, width: 480, height: 320)),
        ]
        let store = makeStore(restoring: Workspace(canvas: Canvas(items: items), focusedPane: a))
        store.toggleOverview()
        store.selectFromOverview(b)
        XCTAssertFalse(store.overviewActive)
        XCTAssertEqual(store.focusedPane, b, "selecting a card focuses that pane")
    }

    func testChordAndApplyWiring() {
        let interpreter = CommandInterpreter()
        XCTAssertEqual(interpreter.feed(KeyChord(character: "\\", [.command])), .toggleOverview)
        let store = makeStore()
        apply(.toggleOverview, to: store)
        XCTAssertTrue(store.overviewActive)
    }
}
