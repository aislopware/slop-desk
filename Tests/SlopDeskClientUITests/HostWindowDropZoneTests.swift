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

    private func zone(_ x: CGFloat, _ y: CGFloat) -> HostWindowDropZone {
        SplitContainer.resolveWindowDropZone(
            at: CGPoint(x: x, y: y), leaves: leaves, container: container,
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
}
#endif
