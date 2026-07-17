// Pins the PURE cross-container drop resolution behind the free pane drag (move across tabs / break to
// a new tab / tear off to a window / merge a satellite back): ``PaneDragResolver``'s external
// precedence (sidebar row → New-Tab slot → dead chrome → tear-off), the INSERT zone mapping a
// satellite-origin drag resolves over the canvas (no swap, nearest-edge re-split, gutter dock), and the
// screen ⇄ canvas-local coordinate flip. All inputs are plain rects — no views, windows, or stores.

import CoreGraphics
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

final class PaneDragResolverTests: XCTestCase {
    // MARK: Fixtures (screen coords, bottom-left origin — the resolver never cares, only containment)

    private let sourcePane = PaneID()
    private let rowPane = PaneID()

    /// Main window 0,0–1000×800; sidebar list on the left 0,100–220×600; one row inside it; the
    /// New-Tab slot just below the list.
    private func targets(newTab: Bool = true) -> PaneDragExternalTargets {
        PaneDragExternalTargets(
            mainWindow: CGRect(x: 0, y: 0, width: 1000, height: 800),
            sidebarList: CGRect(x: 0, y: 100, width: 220, height: 600),
            rows: [(pane: rowPane, rect: CGRect(x: 8, y: 620, width: 204, height: 40))],
            newTabZone: newTab ? CGRect(x: 8, y: 40, width: 204, height: 40) : nil,
        )
    }

    private func resolve(
        _ point: CGPoint,
        origin: PaneDragOrigin = .tree,
        soleLeaf: Bool = false,
        targets: PaneDragExternalTargets? = nil,
    ) -> PaneDragDestination {
        PaneDragResolver.externalDestination(
            at: point, targets: targets ?? self.targets(), origin: origin,
            source: sourcePane, sourceIsSoleLeafOfItsTab: soleLeaf,
        )
    }

    // MARK: External precedence

    func testRowHitResolvesSidebarRowForBothOrigins() {
        let onRow = CGPoint(x: 100, y: 640)
        XCTAssertEqual(resolve(onRow), .sidebarRow(rowPane))
        XCTAssertEqual(resolve(onRow, origin: .detached), .sidebarRow(rowPane))
    }

    func testSourceOwnRowResolvesNone() {
        var t = targets()
        t.rows = [(pane: sourcePane, rect: CGRect(x: 8, y: 620, width: 204, height: 40))]
        XCTAssertEqual(
            resolve(CGPoint(x: 100, y: 640), targets: t), PaneDragDestination.none,
            "dropping a pane on its own row is a no-op — the preview must say so honestly",
        )
    }

    func testRowOutsideListViewportDoesNotHit() {
        // The row's rect sits BELOW the list viewport (a LazyVStack keeps scrolled-away rows mounted).
        var t = targets()
        t.rows = [(pane: rowPane, rect: CGRect(x: 8, y: 20, width: 204, height: 40))]
        XCTAssertEqual(
            resolve(CGPoint(x: 100, y: 50), targets: t), .newTab,
            "a scrolled-away row must not shadow the target under the cursor (here: the New-Tab slot)",
        )
    }

    func testNewTabSlotResolvesAndGatesOnSoleLeaf() {
        let onSlot = CGPoint(x: 100, y: 60)
        XCTAssertEqual(resolve(onSlot), .newTab)
        XCTAssertEqual(
            resolve(onSlot, soleLeaf: true), PaneDragDestination.none,
            "breaking a sole-leaf tab into 'its own tab' is the identity op — reads as a cancel",
        )
        XCTAssertEqual(
            resolve(onSlot, origin: .detached, soleLeaf: true), .newTab,
            "a satellite always reattaches into a fresh tab — the sole-leaf gate is tree-only",
        )
    }

    func testDeadChromeInsideWindowResolvesNone() {
        XCTAssertEqual(resolve(CGPoint(x: 110, y: 750)), PaneDragDestination.none, "the traffic-light strip")
        XCTAssertEqual(resolve(CGPoint(x: 100, y: 350)), PaneDragDestination.none, "list body between rows")
    }

    func testOutsideWindowTearsOffTreeDragsOnly() {
        let outside = CGPoint(x: 1400, y: 400)
        XCTAssertEqual(resolve(outside), .tearOff)
        XCTAssertEqual(
            resolve(outside, origin: .detached), PaneDragDestination.none,
            "a satellite already is its own window — releasing outside keeps it one",
        )
        var t = targets()
        t.mainWindow = nil
        XCTAssertEqual(
            resolve(outside, targets: t), PaneDragDestination.none,
            "without a known window frame the geometry is unreliable — never tear off on a guess",
        )
    }

    // MARK: Insert zones (satellite-origin drag over the canvas — canvas-local, top-left coords)

    func testInsertZoneDocksInTheContainerGutter() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frames = [rowPane: container]
        XCTAssertEqual(
            PaneDragResolver.insertZone(at: CGPoint(x: 5, y: 300), frames: frames, container: container),
            .dock(edge: .left),
            "an INSERT drag docks on EVERY edge — no source rect suppresses one",
        )
        XCTAssertEqual(
            PaneDragResolver.insertZone(at: CGPoint(x: 400, y: 597), frames: frames, container: container),
            .dock(edge: .bottom),
        )
    }

    func testInsertZoneResplitsTowardTheNearestEdgeWithNoDeadCentre() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frames = [rowPane: container]
        XCTAssertEqual(
            PaneDragResolver.insertZone(at: CGPoint(x: 100, y: 300), frames: frames, container: container),
            .resplit(target: rowPane, edge: .left),
        )
        XCTAssertEqual(
            PaneDragResolver.insertZone(at: CGPoint(x: 400, y: 500), frames: frames, container: container),
            .resplit(target: rowPane, edge: .bottom),
            "band 0.5 ⇒ every interior point maps to its dominant edge — a swap-less drag has no dead centre",
        )
    }

    func testInsertZoneOutsideContainerIsNone() {
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(
            PaneDragResolver.insertZone(
                at: CGPoint(x: -10, y: 300), frames: [rowPane: container], container: container,
            ),
            PaneDropZone.none,
        )
        XCTAssertEqual(
            PaneDragResolver.insertZone(at: CGPoint(x: 100, y: 100), frames: [:], container: .zero),
            PaneDropZone.none,
            "a zero container (nothing reported yet) resolves nothing",
        )
    }

    // MARK: Sidebar edge auto-scroll step

    func testAutoScrollStepRampsInTheTopAndBottomBands() {
        let list = CGRect(x: 0, y: 100, width: 220, height: 600) // top edge y=700, bottom y=100
        // Top band (44pt): scroll UP ⇒ negative, deeper into the band ⇒ faster.
        let shallow = PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 667), list: list) ?? 0
        let deep = PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 699), list: list) ?? 0
        XCTAssertLessThan(shallow, 0)
        XCTAssertLessThan(deep, shallow, "deeper into the band scrolls faster")
        // Bottom band: scroll DOWN ⇒ positive.
        let down = PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 105), list: list)
        XCTAssertGreaterThan(down ?? 0, 0)
    }

    func testAutoScrollStepIsNilOutsideTheBandsAndOutsideTheList() {
        let list = CGRect(x: 0, y: 100, width: 220, height: 600)
        XCTAssertNil(
            PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 400), list: list),
            "the list body between the bands never scrolls",
        )
        XCTAssertNil(
            PaneDragResolver.autoScrollStep(at: CGPoint(x: 300, y: 699), list: list),
            "band height alone is not enough — the cursor must be over the list",
        )
    }

    func testAutoScrollBandsShrinkOnAShortListWithoutOverlapping() {
        // 60pt list: the default 44pt bands would overlap — they shrink to height/3 (20pt), leaving a
        // neutral middle third.
        let list = CGRect(x: 0, y: 100, width: 220, height: 60)
        XCTAssertNil(
            PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 130), list: list),
            "the centre of a short list is neutral — overlapping bands would jitter directions",
        )
        XCTAssertLessThan(
            PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 155), list: list) ?? 0, 0,
        )
        XCTAssertGreaterThan(
            PaneDragResolver.autoScrollStep(at: CGPoint(x: 100, y: 105), list: list) ?? 0, 0,
        )
    }

    // MARK: Screen ⇄ canvas-local flip

    func testScreenAndCanvasLocalConversionsRoundTrip() {
        // Canvas at screen 300,200–1100×900 (bottom-left origin). Canvas-local is top-left origin.
        let canvas = CGRect(x: 300, y: 200, width: 800, height: 700)
        let local = CGPoint(x: 50, y: 60)
        let screen = PaneDragResolver.screenPoint(fromCanvasLocal: local, canvas: canvas)
        XCTAssertEqual(screen, CGPoint(x: 350, y: 840), "top-left local ⇒ near the canvas's TOP in screen coords")
        XCTAssertEqual(PaneDragResolver.canvasLocal(fromScreen: screen, canvas: canvas), local)
    }
}
