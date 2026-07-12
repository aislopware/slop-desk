// Pins the rail-window drop-zone mapping (docs/45): where a HOST WINDOW dragged off the
// right rail would land, resolved by the pure `SplitContainer.resolveWindowDropZone` — the
// insert-drag mirror of the pane-move resolver. Headless: pure rect math over hand-placed leaves.

#if os(macOS)
import SlopDeskWorkspaceCore
import XCTest
@testable import SlopDeskClientUI

final class HostWindowDropZoneTests: XCTestCase {
    /// A 1000×600 container split side-by-side into two 500pt columns.
    private let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let left = PaneID()
    private let right = PaneID()
    private var leaves: [SplitTreeRenderModel.PlacedLeaf] {
        [
            .init(id: left, rect: CGRect(x: 0, y: 0, width: 500, height: 600)),
            .init(id: right, rect: CGRect(x: 500, y: 0, width: 500, height: 600)),
        ]
    }

    private func zone(_ x: CGFloat, _ y: CGFloat, source: PaneID? = nil) -> HostWindowDropZone {
        SplitContainer.resolveWindowDropZone(
            at: CGPoint(x: x, y: y), leaves: leaves, container: container, source: source,
        )
    }

    func testCentreOfAPaneFallsBackToNewTab() {
        // The centre box is the rail CLICK's verb — no swap exists for an insert drag.
        XCTAssertEqual(zone(250, 300), .newTab)
        XCTAssertEqual(zone(750, 300), .newTab)
    }

    func testEdgeBandsResolveToASplitBesideThatPane() {
        XCTAssertEqual(zone(460, 300), .resplit(target: left, edge: .right), "left pane's right band")
        XCTAssertEqual(zone(540, 300), .resplit(target: right, edge: .left), "right pane's left band")
        XCTAssertEqual(zone(250, 60), .resplit(target: left, edge: .top))
        XCTAssertEqual(zone(750, 550), .resplit(target: right, edge: .bottom))
    }

    func testContainerGutterDocksAndOutranksTheEdgeBand() {
        // Gutter = min(28, 600·0.06 = 36) = 28. x=10 is inside BOTH the left pane's left band and
        // the container gutter — the full-span dock must win (the pane-move precedence, no source
        // suppression: an insert drag docks against ANY edge, even one a lone pane already spans).
        XCTAssertEqual(zone(10, 300), .dock(edge: .left))
        XCTAssertEqual(zone(990, 300), .dock(edge: .right))
        XCTAssertEqual(zone(500, 8), .dock(edge: .top))
        XCTAssertEqual(zone(500, 592), .dock(edge: .bottom))
    }

    func testEmptyLeavesAndGapsFallBackToNewTab() {
        XCTAssertEqual(
            SplitContainer.resolveWindowDropZone(
                at: CGPoint(x: 300, y: 300), leaves: [], container: container,
            ),
            .newTab, "no leaves (nothing solved yet) — the drop still lands as a new tab",
        )
    }

    // MARK: MOVE drags (the dragged window is already streamed — its pane is `source`)

    func testMoveDragOverItsOwnPaneResolvesKeep() {
        // The whole own rect — centre AND edge bands — is "already here": without this the `.newTab`
        // fallback would EJECT the pane to a new tab when the user just put it back down, and an
        // own-edge resplit would be a structural no-op previewed as a split.
        XCTAssertEqual(zone(250, 300, source: left), .keep, "own centre")
        XCTAssertEqual(zone(460, 300, source: left), .keep, "own edge band")
    }

    func testMoveDragStillSplitsDocksAndBreaksOutElsewhere() {
        XCTAssertEqual(zone(540, 300, source: left), .resplit(target: right, edge: .left))
        XCTAssertEqual(zone(990, 300, source: left), .dock(edge: .right))
        XCTAssertEqual(zone(750, 300, source: left), .newTab, "another pane's centre still breaks out")
    }

    func testMoveDragSuppressesDockOnAnEdgeTheSourceAlreadySpans() {
        // The left pane fully spans the container's LEFT edge — docking there changes nothing, so
        // that gutter is suppressed (the pane-move rule) and the cursor falls into the own-rect
        // `.keep` instead of previewing a no-op dock.
        XCTAssertEqual(zone(10, 300, source: left), .keep)
        XCTAssertEqual(zone(990, 300, source: left), .dock(edge: .right), "an unspanned gutter still docks")
    }

    func testMoveDragFromABackgroundTabResolvesLikeAnInsert() {
        // The source pane lives in another tab — no rect in THIS layout, so every zone is a valid
        // landing (the commit still MOVES the existing pane).
        let ghost = PaneID()
        XCTAssertEqual(zone(250, 300, source: ghost), .newTab)
        XCTAssertEqual(zone(460, 300, source: ghost), .resplit(target: left, edge: .right))
        XCTAssertEqual(zone(10, 300, source: ghost), .dock(edge: .left))
    }

    /// The chip always names the verb a release would commit — the drag's legibility contract.
    func testZoneLabelsLeadWithTheWindowName() {
        XCTAssertEqual(HostWindowDropOverlay.zoneLabel(.newTab, name: "ChatGPT"), "ChatGPT — new tab")
        XCTAssertEqual(
            HostWindowDropOverlay.zoneLabel(.resplit(target: left, edge: .right), name: "ChatGPT"),
            "ChatGPT — split right",
        )
        XCTAssertEqual(
            HostWindowDropOverlay.zoneLabel(.dock(edge: .top), name: "ChatGPT"),
            "ChatGPT — dock top",
        )
    }

    /// A MOVE drag's chip says "move" — the one word telling a relocation from a duplicate before
    /// release — and its own rect reads as the no-op it is.
    func testStreamedZoneLabelsSayMove() {
        XCTAssertEqual(
            HostWindowDropOverlay.zoneLabel(.newTab, name: "ChatGPT", streamed: true),
            "ChatGPT — move to new tab",
        )
        XCTAssertEqual(
            HostWindowDropOverlay.zoneLabel(.resplit(target: left, edge: .right), name: "ChatGPT", streamed: true),
            "ChatGPT — move · split right",
        )
        XCTAssertEqual(
            HostWindowDropOverlay.zoneLabel(.dock(edge: .top), name: "ChatGPT", streamed: true),
            "ChatGPT — move · dock top",
        )
        XCTAssertEqual(
            HostWindowDropOverlay.zoneLabel(.keep, name: "ChatGPT", streamed: true),
            "ChatGPT — already here",
        )
    }
}
#endif
