// PaneDropGeometryTests — what the DOOR can get wrong, and the one rule that stayed behind.
//
// The rect math itself is `slopdesk_workspace::pane_drop`: the gutter's clamp, the deepest-wins rule
// and its vertical tiebreak, the no-op-dock epsilon, the slab's half, the seam's inner edge, the
// rail's cap, and the property that ties them together (every point that resolves to a dock lies
// inside the rail that dock draws) are all pinned there, in the language they live in. None of it is
// restated here — a mirror fixture in a second language is two sources, which is the thing the port
// removed.
//
// What is left is what Rust cannot see, and it is exactly the failure the port introduced. The
// boundary speaks `uint32_t` codes and a four-`double` record; this side speaks a `String`-raw enum
// and a `CGRect`. Three ways for that to be wired wrong, none of which any amount of Rust testing
// would notice:
//
//   * an edge that crosses as one code and comes back as a different case (or as `nil`),
//   * a metric bound to the wrong index — a silently wrong affordance, with every rule still right,
//   * a rect whose x/y or width/height swapped in the conversion, invisible in a square.
//
// Plus ``PaneDropGeometry/leaf(at:in:excluding:)``, which did NOT cross: it takes `PlacedLeaf`s and
// answers a `PaneID`, so porting it would carry an identity over the ABI only to compare it with the
// one it came from. Its rules are Swift's, so its tests are too.

import CoreGraphics
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class PaneDropGeometryTests: XCTestCase {
    /// The canvas the door cases run against. 2000×1000 is deliberately BIG and deliberately NOT
    /// square: `min(w,h) · 0.06` is 60 here, so the 28pt cap is what answers, and a width/height
    /// swapped in the rect conversion changes the answer instead of hiding in symmetry.
    private let wide = CGRect(x: 0, y: 0, width: 2000, height: 1000)

    // MARK: - The edge code, both ways

    /// Every case crosses as its own code and comes back as itself. Exhaustive over `allCases`, so a
    /// fifth edge added on either side fails here rather than resolving to `.left` forever.
    ///
    /// `dominantEdge` is the round trip in one call: it takes a point in the named edge's band and
    /// answers an edge, which means the code went out and came back. A transposed pair in either
    /// direction of the mapping shows up as the wrong case.
    func testEveryEdgeCrossesAsItselfAndComesBackAsItself() {
        let probes: [PaneDropEdge: (CGFloat, CGFloat)] = [
            .left: (0.05, 0.5), .right: (0.95, 0.5), .top: (0.5, 0.05), .bottom: (0.5, 0.95),
        ]
        XCTAssertEqual(
            Set(probes.keys), Set(PaneDropEdge.allCases),
            "an edge without a probe is an edge this test cannot see",
        )
        for edge in PaneDropEdge.allCases {
            guard let (u, v) = probes[edge] else { continue }
            XCTAssertEqual(
                PaneDropGeometry.dominantEdge(u: u, v: v, band: PaneDropMetrics.edgeBandFraction),
                edge, "\(edge) did not survive the crossing",
            )
        }
    }

    /// The door's FIFTH answer — no gutter at all — has to arrive as `nil` and not as a case. It is
    /// the one value the wire's own `PaneDropEdge` byte cannot carry, which is why the boundary
    /// spells it with a code of its own; reading that code as an edge would dock every drop in the
    /// middle of the canvas.
    func testTheCursorInNoGutterIsNilAndNotAnEdge() {
        XCTAssertNil(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 1000, y: 500), container: wide, sourceRect: nil),
        )
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 1, y: 500), container: wide, sourceRect: nil),
            .left, "and a real edge still arrives as one",
        )
    }

    /// The source rect is read only when there IS one. Passing `nil` must not send a zero rect that
    /// the far side then treats as a real pane sitting in the top-left corner — which would suppress
    /// the left and top docks of every cross-window INSERT drag.
    func testAnAbsentSourceRectIsAbsenceAndNotAZeroRect() {
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 1, y: 500), container: wide, sourceRect: nil),
            .left,
        )
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 1000, y: 1), container: wide, sourceRect: nil),
            .top,
        )
    }

    // MARK: - The metric codes

    /// Each metric is bound to its own index. Pairwise distinct is the assertion that matters: two
    /// constants reading one code is the whole failure mode, and it is silent — every rule downstream
    /// stays correct while the affordance is wrong.
    func testEachMetricIsBoundToItsOwnCode() {
        let metrics: [CGFloat] = [
            PaneDropMetrics.edgeBandFraction,
            PaneDropMetrics.containerGutterFraction,
            PaneDropMetrics.containerGutterMax,
            PaneDropMetrics.dockRailFraction,
            PaneDropMetrics.dockRailMax,
            PaneDropMetrics.resplitSeamThickness,
        ]
        XCTAssertEqual(Set(metrics).count, metrics.count, "two constants are reading one code")
        for value in metrics {
            XCTAssertGreaterThan(value, 0, "a zero is what an unknown code answers")
        }
    }

    /// And bound to the RIGHT index, checked by the relationships rather than by restating the
    /// numbers: the bands leave a centre box, and the drawn rail is wider than the gutter that
    /// resolved the dock. Any transposition of the six breaks at least one of these.
    func testTheMetricsStillStandInTheRightRelationToEachOther() {
        XCTAssertLessThan(PaneDropMetrics.edgeBandFraction, 0.5)
        XCTAssertGreaterThan(PaneDropMetrics.dockRailFraction, PaneDropMetrics.containerGutterFraction)
        XCTAssertGreaterThan(PaneDropMetrics.dockRailMax, PaneDropMetrics.containerGutterMax)
        XCTAssertLessThan(PaneDropMetrics.resplitSeamThickness, PaneDropMetrics.containerGutterMax)
    }

    // MARK: - The rect conversion

    /// A rect goes out and a rect comes back, and none of the four fields may trade places. The
    /// target is asymmetric in origin AND extent, and `.bottom` is the edge that reads three of the
    /// four — an x/y or a width/height swap moves the slab off the pane rather than resizing it.
    func testAllFourRectFieldsSurviveTheCrossingInTheirOwnPlaces() {
        let target = CGRect(x: 100, y: 200, width: 400, height: 300)
        XCTAssertEqual(
            PaneDropGeometry.slabRect(in: target, edge: .bottom),
            CGRect(x: 100, y: 350, width: 400, height: 150),
        )
        XCTAssertEqual(
            PaneDropGeometry.railRect(in: wide, edge: .right),
            CGRect(x: 1952, y: 0, width: 48, height: 1000),
            "the trailing edge is placed at max − t, which reads x AND width together",
        )
    }

    /// The size and point doors are separate records from the rect one, so they get their own
    /// crossing. A slab of a non-square pane makes a transposed width/height visible.
    func testTheSizeAndPointDoorsCarryTheirOwnTwoFields() {
        let slab = PaneDropGeometry.slabRect(in: CGRect(x: 0, y: 0, width: 400, height: 300), edge: .left)
        XCTAssertEqual(
            PaneDropGeometry.seamSize(slab, edge: .left),
            CGSize(width: PaneDropMetrics.resplitSeamThickness, height: 300),
        )
        XCTAssertEqual(PaneDropGeometry.seamCenter(slab, edge: .left), CGPoint(x: 200, y: 150))
    }

    /// `sourceSpans` is the door with no record coming back at all — a `Bool` over two rects and a
    /// code — so what it can get wrong is the EDGE argument going unthreaded. One rect, four edges,
    /// four answers: a left column spans the left edge and neither horizontal one. An edge dropped
    /// on the floor would answer the same way four times, and every no-op dock would come back.
    ///
    /// (Argument order is deliberately not asserted: for two rects sharing an origin and a cross
    /// extent the predicate really is symmetric, so a swapped pair is not observable from here.
    /// What the pair means is `slopdesk_workspace::pane_drop`'s to pin, and it does.)
    func testTheEdgeArgumentReachesTheSpanPredicate() {
        let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
        let leftColumn = CGRect(x: 0, y: 0, width: 400, height: 600)
        let spanned = PaneDropEdge.allCases.filter {
            PaneDropGeometry.sourceSpans(leftColumn, $0, canvas)
        }
        XCTAssertEqual(spanned, [.left], "a left column spans the left edge and nothing else")
    }

    // MARK: - `leaf`: the rule that stayed in Swift

    /// The leaves arrive ORDERED, and the first containing rect answers. A min-clamped,
    /// over-subscribed layout can overlap two rects, and an unordered dictionary would then resolve a
    /// different target on different runs of the same drag.
    func testLeafTakesTheFirstContainingRectInOrder() {
        let a = PaneID()
        let b = PaneID()
        let overlapping = [
            SplitTreeRenderModel.PlacedLeaf(id: a, rect: CGRect(x: 0, y: 0, width: 500, height: 600)),
            SplitTreeRenderModel.PlacedLeaf(id: b, rect: CGRect(x: 400, y: 0, width: 400, height: 600)),
        ]
        let hit = PaneDropGeometry.leaf(at: CGPoint(x: 450, y: 300), in: overlapping, excluding: nil)
        XCTAssertEqual(hit?.0, a)
    }

    /// The dragged pane is never its own drop target — excluding it is what lets the cursor sitting on
    /// the pane it grabbed resolve to the leaf UNDER it, or to nothing.
    func testLeafExcludesTheDraggedSource() {
        let a = PaneID()
        let leaves = [
            SplitTreeRenderModel.PlacedLeaf(id: a, rect: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ]
        XCTAssertNil(PaneDropGeometry.leaf(at: CGPoint(x: 400, y: 300), in: leaves, excluding: a))
        XCTAssertEqual(
            PaneDropGeometry.leaf(at: CGPoint(x: 400, y: 300), in: leaves, excluding: PaneID())?.0, a,
        )
    }
}

// MARK: - The drop register (one wording, two chips)

/// The canvas overlay's ghost chip and the cross-window panel used to spell these strings separately,
/// and they are never on screen at the same instant — so a drift between them could not be seen. The
/// register is the merge; this is what it says.
final class PaneDropRegisterTests: XCTestCase {
    private let target = PaneID()

    // MARK: In-canvas wording

    func testCanvasWordingIsVerbFirst() {
        XCTAssertEqual(PaneDropRegister.label(for: .swap(target: target), title: "api"), "swap api")
        XCTAssertEqual(
            PaneDropRegister.label(for: .resplit(target: target, edge: .left), title: "api"),
            "split left", "a re-split names the EDGE, not the pane — the preview already shows which",
        )
        XCTAssertEqual(PaneDropRegister.label(for: .dock(edge: .bottom), title: "api"), "dock bottom")
        XCTAssertEqual(PaneDropRegister.label(for: PaneDropZone.none, title: "api"), "cancel")
    }

    /// A pane with no usable title still reads as a sentence. An EMPTY title falls back the same way a
    /// missing one does — the two chips disagreed about exactly this before the merge, and the
    /// overlay's half printed `swap ` with a trailing space.
    func testAnUntitledPaneStillReadsAsASentence() {
        XCTAssertEqual(PaneDropRegister.label(for: .swap(target: target), title: nil), "swap pane")
        XCTAssertEqual(PaneDropRegister.label(for: .swap(target: target), title: ""), "swap pane")
    }

    // MARK: Cross-container wording

    /// Off the canvas the sentence is about WHERE the pane is going, and the verb says which gesture
    /// the user is in the middle of: a tiled pane MOVES within the tree, a satellite MERGES back into it.
    func testRowWordingNamesTheGestureTheOriginIsIn() {
        XCTAssertEqual(
            PaneDropRegister.label(for: .sidebarRow(target), targetTitle: "api", origin: .tree),
            "move beside api",
        )
        XCTAssertEqual(
            PaneDropRegister.label(for: .sidebarRow(target), targetTitle: "api", origin: .detached),
            "merge beside api",
        )
        XCTAssertEqual(
            PaneDropRegister.label(for: .sidebarRow(target), targetTitle: nil, origin: .tree),
            "move beside pane",
        )
    }

    func testContainerDestinationsNameTheContainer() {
        XCTAssertEqual(
            PaneDropRegister.label(for: .newTab, targetTitle: nil, origin: .tree), "new tab",
        )
        XCTAssertEqual(
            PaneDropRegister.label(for: .tearOff, targetTitle: nil, origin: .tree), "new window",
        )
        XCTAssertEqual(
            PaneDropRegister.label(for: PaneDragDestination.none, targetTitle: nil, origin: .tree),
            "cancel", "the same word the canvas chip uses — one register, one cancel",
        )
    }

    /// Over the canvas the floating chip hides, because the in-canvas overlay IS the affordance there
    /// and a floating twin would double it. An empty label is how that is said.
    func testTheFloatingChipSaysNothingOverTheCanvas() {
        XCTAssertEqual(
            PaneDropRegister.label(
                for: .canvas(.swap(target: target)), targetTitle: "api", origin: .tree,
            ),
            "",
        )
    }

    // MARK: Marks

    /// `.left`/`.right` partition WIDTH and make columns; `.top`/`.bottom` partition HEIGHT and make
    /// rows — read off `PaneDropEdge.axis`, so the glyph cannot disagree with the tree op the same
    /// edge drives. A dock draws the same silhouette as a re-split: what differs is the size of the
    /// preview under it, not the shape of the outcome.
    func testSplitMarksFollowTheEdgeAxis() {
        XCTAssertEqual(PaneDropRegister.mark(for: .resplit(target: target, edge: .left)), .splitColumns)
        XCTAssertEqual(PaneDropRegister.mark(for: .resplit(target: target, edge: .right)), .splitColumns)
        XCTAssertEqual(PaneDropRegister.mark(for: .resplit(target: target, edge: .top)), .splitRows)
        XCTAssertEqual(PaneDropRegister.mark(for: .dock(edge: .bottom)), .splitRows)
        XCTAssertEqual(PaneDropRegister.mark(for: .swap(target: target)), .swap)
        XCTAssertEqual(PaneDropRegister.mark(for: PaneDropZone.none), .cancel)
    }

    func testCrossContainerMarksNameTheirOutcome() {
        XCTAssertEqual(PaneDropRegister.mark(for: .sidebarRow(target)), .beside)
        XCTAssertEqual(PaneDropRegister.mark(for: .newTab), .newTab)
        XCTAssertEqual(PaneDropRegister.mark(for: .tearOff), .newWindow)
        XCTAssertEqual(PaneDropRegister.mark(for: PaneDragDestination.none), .cancel)
    }
}
