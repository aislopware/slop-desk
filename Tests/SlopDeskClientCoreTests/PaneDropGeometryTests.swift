// Pins the drop-zone RECT MATH and the drop REGISTER — the two pieces of the pane-move block that
// had no direct coverage at all while they sat in the view target.
//
// Both were reachable only through their callers (`SplitContainer`'s live resolution, the coordinator's
// chip), so every one of these rules was asserted at most indirectly, through a resolution that could
// have been right for the wrong reason. Four of them are the kind that fails QUIETLY: the gutter's
// clamp (a 4K canvas would otherwise dock from 120pt in), the deepest-wins tiebreak (a corner resolves
// to SOMETHING either way — just not the same something twice), the no-op-dock predicate's `eps = 1`
// (a solver rounding of half a point turns a suppressed dock back on), and the register's fallback
// name (an untitled pane read `swap ` with a trailing space).
//
// Headless by construction: rectangles and fractions in, an edge or a string out.

import CoreGraphics
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

final class PaneDropGeometryTests: XCTestCase {
    /// The canvas the container-gutter cases run against. 2000×1000 is deliberately BIG: `min(w,h) ·
    /// 0.06` is 60 here, so every assertion below is also an assertion that the 28pt cap applied.
    private let wide = CGRect(x: 0, y: 0, width: 2000, height: 1000)

    // MARK: - The three tuned numbers

    /// The metrics are an affordance, not a flag — but they are still the numbers every case below
    /// derives from, so a change to one has to come through here first.
    func testMetricsAreTheTunedAffordance() {
        XCTAssertEqual(PaneDropMetrics.edgeBandFraction, 0.30, accuracy: 1e-9)
        XCTAssertEqual(PaneDropMetrics.containerGutterFraction, 0.06, accuracy: 1e-9)
        XCTAssertEqual(PaneDropMetrics.containerGutterMax, 28, accuracy: 1e-9)
        XCTAssertLessThan(
            PaneDropMetrics.edgeBandFraction, 0.5,
            "the MOVE band must leave a centre box — at 0.5 the swap zone vanishes and every drop re-splits",
        )
    }

    // MARK: - `containerEdge`: the gutter width

    /// `min(28, min(w, h) · 0.06)`, and on a big canvas the cap is what answers. Without it a 4K
    /// window would dock from 120pt in, which swallows the whole first column of panes.
    func testGutterIsCappedAtTwentyEightOnALargeCanvas() {
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 27, y: 500), container: wide, sourceRect: nil),
            .left,
        )
        XCTAssertNil(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 29, y: 500), container: wide, sourceRect: nil),
            "29pt in is past the 28pt cap — min(w,h)·0.06 would have been 60 here",
        )
    }

    /// Below the cap the gutter is PROPORTIONAL, and it follows the SHORT side: a 200×100 container
    /// gets 6pt, not 12.
    func testGutterIsProportionalToTheShortSideBelowTheCap() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 5, y: 50), container: small, sourceRect: nil),
            .left,
        )
        XCTAssertNil(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 7, y: 50), container: small, sourceRect: nil),
            "7pt is outside a 6pt gutter — the 28pt cap must not be the answer on a small container",
        )
    }

    /// A container with no area reports nothing rather than dividing by it.
    func testDegenerateContainerHasNoGutter() {
        XCTAssertNil(PaneDropGeometry.containerEdge(at: .zero, container: .zero, sourceRect: nil))
        XCTAssertNil(
            PaneDropGeometry.containerEdge(
                at: CGPoint(x: 1, y: 1), container: CGRect(x: 0, y: 0, width: 0, height: 600),
                sourceRect: nil,
            ),
        )
    }

    // MARK: - `containerEdge`: deepest wins, ties go vertical

    /// In a CORNER two gutters contain the cursor. The deeper one — the smaller distance — wins, so
    /// sliding along the top edge toward the left corner flips to `.left` only once the cursor is
    /// genuinely closer to it.
    func testDeepestGutterWinsInACorner() {
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 5, y: 3), container: wide, sourceRect: nil),
            .top, "3pt into the top beats 5pt into the left",
        )
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 3, y: 5), container: wide, sourceRect: nil),
            .left, "and the other way round",
        )
    }

    /// An EXACT tie goes to the vertical (left/right) edge, on both corners — the iteration order
    /// left, right, top, bottom plus a strictly-less-than comparison is what encodes that, and a `<=`
    /// slipped in there would silently flip every corner in the app to a horizontal dock.
    func testExactTieGoesToAVerticalEdge() {
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 5, y: 5), container: wide, sourceRect: nil),
            .left,
        )
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 1995, y: 995), container: wide, sourceRect: nil),
            .right,
        )
    }

    // MARK: - `sourceSpans`: the no-op dock, and its one-point epsilon

    private let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// A pane that already fills an edge cannot be docked to it — the op would change nothing, and
    /// previewing a full-span rail for a no-op is the affordance lying. So the edge is skipped and the
    /// cursor falls through to whatever else is under it (here: nothing).
    func testAnEdgeTheSourceAlreadySpansIsSuppressed() {
        let leftHalf = CGRect(x: 0, y: 0, width: 400, height: 600)
        XCTAssertNil(
            PaneDropGeometry.containerEdge(
                at: CGPoint(x: 5, y: 300), container: canvas, sourceRect: leftHalf,
            ),
            "the source already IS the left column — docking it left is the identity op",
        )
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(
                at: CGPoint(x: 795, y: 300), container: canvas, sourceRect: leftHalf,
            ),
            .right, "the OTHER edges stay live — only the spanned one is suppressed",
        )
    }

    /// An INSERT drag has no source in this tab, so every edge is meaningful — the same point that
    /// resolved `nil` above docks here.
    func testInsertDragSuppressesNoEdge() {
        XCTAssertEqual(
            PaneDropGeometry.containerEdge(at: CGPoint(x: 5, y: 300), container: canvas, sourceRect: nil),
            .left,
        )
    }

    /// `eps = 1`: a solver leaves sub-point gaps, so "spans" has to mean "within a point". One point
    /// of slack still spans; two do not.
    func testSpansToleratesExactlyOnePointOfSlack() {
        XCTAssertTrue(
            PaneDropGeometry.sourceSpans(CGRect(x: 1, y: 0, width: 399, height: 600), .left, canvas),
            "a 1pt gap at the edge is a rounding, not a gap",
        )
        XCTAssertFalse(
            PaneDropGeometry.sourceSpans(CGRect(x: 2, y: 0, width: 398, height: 600), .left, canvas),
        )
        XCTAssertTrue(
            PaneDropGeometry.sourceSpans(CGRect(x: 0, y: 0, width: 400, height: 599), .left, canvas),
            "and 1pt short on the CROSS axis is still a full span",
        )
        XCTAssertFalse(
            PaneDropGeometry.sourceSpans(CGRect(x: 0, y: 0, width: 400, height: 598), .left, canvas),
        )
    }

    /// Each of the four edges reads its own pair of conditions — a position on the edge's own axis and
    /// a FULL length on the cross axis. A pane that touches an edge without spanning it does not.
    func testEachEdgeChecksItsOwnAxisAndTheFullCrossSpan() {
        XCTAssertTrue(
            PaneDropGeometry.sourceSpans(CGRect(x: 400, y: 0, width: 400, height: 600), .right, canvas),
        )
        XCTAssertTrue(
            PaneDropGeometry.sourceSpans(CGRect(x: 0, y: 0, width: 800, height: 300), .top, canvas),
        )
        XCTAssertTrue(
            PaneDropGeometry.sourceSpans(CGRect(x: 0, y: 300, width: 800, height: 300), .bottom, canvas),
        )
        XCTAssertFalse(
            PaneDropGeometry.sourceSpans(CGRect(x: 0, y: 0, width: 400, height: 300), .top, canvas),
            "a top-LEFT quarter touches the top edge but does not span it — docking there is real",
        )
    }

    // MARK: - `leaf`: ordered, and the source excluded

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

    // MARK: - `dominantEdge`: deepest penetration, ties go vertical

    /// With the MOVE band the caller has already established the cursor is out of the centre box, so
    /// at least one penetration is positive and the deepest one answers.
    func testDominantEdgeTakesTheDeepestPenetration() {
        let band = PaneDropMetrics.edgeBandFraction
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.05, v: 0.5, band: band), .left)
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.95, v: 0.5, band: band), .right)
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.5, v: 0.05, band: band), .top)
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.5, v: 0.95, band: band), .bottom)
    }

    /// The same vertical tiebreak as the container gutter, and for the same reason: the corner of a
    /// pane must resolve the same way twice. Both diagonal corners answer with their vertical edge.
    func testDominantEdgeTieGoesToAVerticalEdge() {
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.1, v: 0.1, band: 0.3), .left)
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.9, v: 0.9, band: 0.3), .right)
    }

    /// Band 0.5 is the INSERT drag's: every interior point maps to its nearest edge, so there is no
    /// dead centre for a drag that has no swap to offer. The exact centre is a four-way tie and lands
    /// on the vertical edge the tiebreak names.
    func testHalfBandLeavesNoDeadCentre() {
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.5, v: 0.5, band: 0.5), .left)
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.6, v: 0.5, band: 0.5), .right)
        XCTAssertEqual(PaneDropGeometry.dominantEdge(u: 0.5, v: 0.9, band: 0.5), .bottom)
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
