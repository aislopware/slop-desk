import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pure tests for ``CanvasSnap`` — the smart-snap solver behind canvas drag-to-move / resize:
/// engage/release hysteresis, pane edge/centre alignment, gutter adjacency, viewport edges, the
/// grid fallback, the objects-beat-grid priority, the gutter>edge tie-break, per-axis independence,
/// resize min-size DISCARD (never clamp), preview≡commit determinism, and guide synthesis.
///
/// Default config: engage 8 / release 12, gutter 16, grid quantum 16 (engage 6 / release 9).
/// NOTE on fixture Y values: with a 16pt grid quantum and 6pt grid engage, a coordinate is
/// grid-FREE only when its residue mod 16 is in 7…9 (e.g. 855). Fixtures use such values wherever
/// an axis must stay unsnapped.
final class CanvasSnapTests: XCTestCase {
    private let eps: CGFloat = 1e-6
    private let config = CanvasSnap.Config()
    /// Pane/viewport snapping only (grid off) — isolates pane-candidate behaviour.
    private var paneOnly: CanvasSnap.Config {
        var c = config
        c.snapsToGrid = false
        return c
    }

    private func assertRect(
        _ a: CGRect,
        _ b: CGRect,
        _ msg: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(a.minX, b.minX, accuracy: eps, "\(msg) x", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: eps, "\(msg) y", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: eps, "\(msg) w", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: eps, "\(msg) h", file: file, line: line)
    }

    private func paneSnappedX(_ r: CanvasSnap.Resolution) -> Bool { r.stickX.map { !$0.isGrid } ?? false }
    private func paneSnappedY(_ r: CanvasSnap.Resolution) -> Bool { r.stickY.map { !$0.isGrid } ?? false }

    // MARK: Move — pane edge alignment

    func testMoveSnapsLeftEdgeToNeighbourLeftEdge() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let dragged = CGRect(x: 105, y: 855, width: 150, height: 80) // y 855 = grid-free residue 7
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        assertRect(r.frame, CGRect(x: 100, y: 855, width: 150, height: 80), "minX→minX, Y free")
        XCTAssertTrue(paneSnappedX(r))
        XCTAssertNil(r.stickY)
    }

    func testMoveSnapsRightEdgeToNeighbourRightEdge() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100) // maxX = 300
        let dragged = CGRect(x: 156, y: 855, width: 150, height: 80) // maxX = 306 → δ −6
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.frame.maxX, 300, accuracy: eps, "maxX→maxX")
        XCTAssertTrue(paneSnappedX(r))
    }

    func testMoveSnapsCentreToNeighbourCentre() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100) // midX = 200
        let dragged = CGRect(x: 130, y: 855, width: 150, height: 80) // midX = 205 → δ −5
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.frame.midX, 200, accuracy: eps, "midX→midX")
        XCTAssertTrue(paneSnappedX(r))
    }

    func testMoveVerticalAxisSnapsIndependently() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        // X far from any candidate AND grid-free (777 has residue 9); Y minY 5pt off the neighbour's.
        let dragged = CGRect(x: 777, y: 505, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.frame.minY, 500, accuracy: eps, "minY→minY (edge beats the equidistant centre tie)")
        XCTAssertEqual(r.frame.minX, 777, accuracy: eps, "x untouched")
        XCTAssertTrue(paneSnappedY(r))
        XCTAssertNil(r.stickX)
    }

    // MARK: Move — gutter adjacency

    func testMoveSnapsToGutterRightOfNeighbour() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100) // maxX = 300 → adjacency at 316
        let dragged = CGRect(x: 311, y: 855, width: 150, height: 80) // minX 5pt off 316
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.frame.minX, 316, accuracy: eps, "minX→other.maxX + gutter")
        XCTAssertTrue(paneSnappedX(r))
    }

    func testMoveSnapsToGutterLeftOfNeighbour() {
        let other = CGRect(x: 400, y: 500, width: 200, height: 100) // minX = 400 → adjacency at 384
        let dragged = CGRect(x: 230, y: 855, width: 150, height: 80) // maxX = 380, 4pt off 384
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.frame.maxX, 384, accuracy: eps, "maxX→other.minX − gutter")
        XCTAssertTrue(paneSnappedX(r))
    }

    // MARK: Move — selection rules

    func testMoveNearestCandidateWins() {
        // Two neighbours offer minX targets at 100 (δ −7) and 110 (δ +3) → 110 wins (smaller |δ|).
        let a = CGRect(x: 100, y: 500, width: 50, height: 50)
        let b = CGRect(x: 110, y: 700, width: 50, height: 50)
        let dragged = CGRect(x: 107, y: 855, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [a, b], config: config)
        XCTAssertEqual(r.frame.minX, 110, accuracy: eps, "smaller |δ| wins")
    }

    func testTieBreakGutterBeatsEdge() {
        // Equidistant ±3: a gutter target at 100 (other.maxX 84 + 16) vs an edge target at 106
        // (other2.minX). The gutter class wins the near-tie regardless of candidate order.
        let gutterSource = CGRect(x: 0, y: 500, width: 84, height: 50)
        let edgeSource = CGRect(x: 106, y: 700, width: 50, height: 50)
        let dragged = CGRect(x: 103, y: 855, width: 150, height: 80)
        let r1 = CanvasSnap.move(dragged, others: [gutterSource, edgeSource], config: paneOnly)
        XCTAssertEqual(r1.frame.minX, 100, accuracy: eps, "gutter beats edge on a tie")
        let r2 = CanvasSnap.move(dragged, others: [edgeSource, gutterSource], config: paneOnly)
        XCTAssertEqual(r2.frame.minX, 100, accuracy: eps, "…order-independently")
    }

    func testNearTieSelectionIsOrderIndependentWithThreeCandidates() {
        // Three candidates straddling the near-tie band: center δ +7.2 (nearest), edge δ +7.6
        // (within 0.5 of the minimum → tie → EDGE beats center), gutter δ +8.0 (OUTSIDE the band:
        // 8.0 > 7.2 + 0.5 — its class priority must NOT let it win). A pairwise comparator is
        // non-transitive here and the winner would depend on array order; the two-pass selection
        // must produce the SAME edge snap for every permutation.
        let gutterSource = CGRect(
            x: 42,
            y: 500,
            width: 50,
            height: 50,
        ) // maxX 92 → gutter target 108 (δ+8.0); edge 92 (δ−8.0)
        let edgeSource = CGRect(x: 107.6, y: 700, width: 50, height: 50) // minX target δ +7.6
        let centerSource = CGRect(x: 157.2, y: 300, width: 50, height: 50) // midX 182.2 → mid δ +7.2
        let dragged = CGRect(x: 100, y: 855, width: 150, height: 80)
        let orders: [[CGRect]] = [
            [gutterSource, edgeSource, centerSource],
            [centerSource, edgeSource, gutterSource],
            [edgeSource, centerSource, gutterSource],
        ]
        for others in orders {
            let r = CanvasSnap.move(dragged, others: others, config: paneOnly)
            XCTAssertEqual(
                r.frame.minX,
                107.6,
                accuracy: eps,
                "edge wins the near-tie band in every candidate order",
            )
        }
    }

    func testMoveEngageBoundary() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        // 7.9pt off → engages; 8.2pt off → free (pane snapping only, so no grid interference).
        let near = CanvasSnap.move(
            CGRect(x: 107.9, y: 855, width: 150, height: 80),
            others: [other],
            config: paneOnly,
        )
        XCTAssertEqual(near.frame.minX, 100, accuracy: eps, "7.9 ≤ engage 8 → snaps")
        let far = CanvasSnap.move(
            CGRect(x: 108.2, y: 855, width: 150, height: 80),
            others: [other],
            config: paneOnly,
        )
        XCTAssertEqual(far.frame.minX, 108.2, accuracy: eps, "8.2 > engage 8 → free")
        XCTAssertNil(far.stickX)
    }

    // MARK: Move — hysteresis (engage 8 / release 12)

    func testHeldStickSurvivesToReleaseThenLandsUnderPointer() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let start = CanvasSnap.move(
            CGRect(x: 105, y: 855, width: 150, height: 80),
            others: [other],
            config: paneOnly,
        )
        XCTAssertEqual(start.frame.minX, 100, accuracy: eps)

        // Drift to 11.9pt past the target: still held (release is 12).
        let held = CanvasSnap.move(
            CGRect(x: 111.9, y: 855, width: 150, height: 80),
            others: [other],
            config: paneOnly,
            previous: start,
        )
        XCTAssertEqual(held.frame.minX, 100, accuracy: eps, "11.9 < release 12 → still held")
        XCTAssertNotNil(held.stickX)

        // 12.1pt: releases AND lands exactly under the pointer (solver is raw-input pure — no drift).
        let released = CanvasSnap.move(
            CGRect(x: 112.1, y: 855, width: 150, height: 80),
            others: [other],
            config: paneOnly,
            previous: held,
        )
        XCTAssertEqual(released.frame.minX, 112.1, accuracy: eps, "breakaway lands at the raw position")
        XCTAssertNil(released.stickX)
    }

    func testHeldStickIgnoresNearerNewcomer() {
        // Held on target 100; at raw 106 a second pane offers 108 (δ2, nearer) — the hold wins (no
        // mid-hold re-targeting).
        let a = CGRect(x: 100, y: 500, width: 50, height: 50)
        let b = CGRect(x: 108, y: 700, width: 50, height: 50)
        let start = CanvasSnap.move(
            CGRect(x: 102, y: 855, width: 150, height: 80),
            others: [a],
            config: paneOnly,
        )
        XCTAssertEqual(start.frame.minX, 100, accuracy: eps)
        let held = CanvasSnap.move(
            CGRect(x: 106, y: 855, width: 150, height: 80),
            others: [a, b],
            config: paneOnly,
            previous: start,
        )
        XCTAssertEqual(held.frame.minX, 100, accuracy: eps, "held stick beats the nearer newcomer")
    }

    func testHeldStickReleasesWhenSourceVanishes() {
        // Engage on a neighbour's edge, then the neighbour disappears (pane closed mid-drag): the
        // hold must DROP — a pane must never stay magnetized to a phantom coordinate that no guide
        // could justify.
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let start = CanvasSnap.move(
            CGRect(x: 105, y: 855, width: 150, height: 80),
            others: [other],
            config: paneOnly,
        )
        XCTAssertEqual(start.frame.minX, 100, accuracy: eps)
        let after = CanvasSnap.move(
            CGRect(x: 105, y: 855, width: 150, height: 80),
            others: [],
            config: paneOnly,
            previous: start,
        )
        XCTAssertEqual(after.frame.minX, 105, accuracy: eps, "vanished source → hold dropped, raw passes through")
        XCTAssertNil(after.stickX)
    }

    func testIdempotentResolve() {
        // Re-solving the SAME raw input with the previous result is a fixed point (preview ≡ commit).
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let raw = CGRect(x: 105, y: 855, width: 150, height: 80)
        let first = CanvasSnap.move(raw, others: [other], config: config)
        let second = CanvasSnap.move(raw, others: [other], config: config, previous: first)
        XCTAssertEqual(first, second, "solve is idempotent at a fixed raw input")
    }

    func testCorrectionNeverExceedsRelease() {
        // Sweep a drag across the target: at every step the applied correction is < release.
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        var previous: CanvasSnap.Resolution?
        var x: CGFloat = 90
        while x <= 120 {
            let raw = CGRect(x: x, y: 855, width: 150, height: 80)
            let r = CanvasSnap.move(raw, others: [other], config: paneOnly, previous: previous)
            XCTAssertLessThan(
                abs(r.frame.minX - x),
                config.release + eps,
                "correction bounded by release at raw x=\(x)",
            )
            previous = r
            x += 0.7
        }
    }

    // MARK: Move — viewport edges

    func testMoveSnapsToViewportInsetEdgeAndCenter() {
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        // minX 21 is 5pt off the 16pt-inset left edge.
        let edge = CanvasSnap.move(
            CGRect(x: 21, y: 855, width: 150, height: 80),
            others: [],
            viewport: viewport,
            config: paneOnly,
        )
        XCTAssertEqual(edge.frame.minX, 16, accuracy: eps, "minX→viewport inset edge")
        XCTAssertEqual(edge.guides.first?.kind, .viewportEdge)

        // midX 595 is 5pt off the viewport centreline 600.
        let center = CanvasSnap.move(
            CGRect(x: 520, y: 855, width: 150, height: 80),
            others: [],
            viewport: viewport,
            config: paneOnly,
        )
        XCTAssertEqual(center.frame.midX, 600, accuracy: eps, "midX→viewport centre")
    }

    // MARK: Move — grid fallback + priority

    func testMoveFallsBackToGridWhenNoPaneCandidate() {
        // No others: x 230 is 6pt off the 224 grid line (quantum 16) → quantizes; y 855 (residue 7,
        // beyond grid engage 6) stays free. Grid snaps draw NO guides.
        let dragged = CGRect(x: 230, y: 855, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [], config: config)
        XCTAssertEqual(r.frame.minX, 224, accuracy: eps, "grid quantize within grid engage")
        XCTAssertEqual(r.frame.minY, 855, accuracy: eps, "grid beyond engage → free")
        XCTAssertEqual(r.stickX?.isGrid, true)
        XCTAssertFalse(paneSnappedX(r))
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testPaneCandidateBeatsCloserGridLine() {
        // Pane target at minX 100 (δ 6); grid line at 96 (δ 2 — closer). Pane must still win: the
        // grid is a FALLBACK, never a competitor.
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let dragged = CGRect(x: 94, y: 855, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.frame.minX, 100, accuracy: eps, "objects beat grid")
        XCTAssertTrue(paneSnappedX(r))
    }

    func testDisabledConfigSnapsNothing() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let dragged = CGRect(x: 101, y: 501, width: 150, height: 80)
        let r = CanvasSnap.move(
            dragged,
            others: [other],
            viewport: CGRect(x: 0, y: 0, width: 1200, height: 800),
            config: .disabled,
        )
        assertRect(r.frame, dragged, "⌘-drag: fully free")
        XCTAssertTrue(r.guides.isEmpty)
        XCTAssertNil(r.stickX)
        XCTAssertNil(r.stickY)
    }

    // MARK: Move — guides

    func testGuideSpansDraggedAndAlignedNeighbour() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let dragged = CGRect(x: 105, y: 855, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        let vertical = r.guides.filter { $0.orientation == .vertical }
        XCTAssertEqual(vertical.count, 1, "one vertical guide at the shared minX")
        guard let g = vertical.first else { return }
        XCTAssertEqual(g.position, 100, accuracy: eps)
        XCTAssertEqual(g.start, 500, accuracy: eps, "span covers the neighbour's top")
        XCTAssertEqual(g.end, 935, accuracy: eps, "…through the dragged frame's bottom")
        XCTAssertEqual(g.kind, .edge)
    }

    func testGuideCollectsAllAgreeingNeighbours() {
        // Two neighbours share minX = 100 → ONE guide whose span unions both + the dragged frame.
        let a = CGRect(x: 100, y: 200, width: 50, height: 50)
        let b = CGRect(x: 100, y: 600, width: 50, height: 50)
        let dragged = CGRect(x: 103, y: 855, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [a, b], config: config)
        let vertical = r.guides.filter { $0.orientation == .vertical && abs($0.position - 100) < 0.5 }
        XCTAssertEqual(vertical.count, 1)
        guard let g = vertical.first else { return }
        XCTAssertEqual(g.start, 200, accuracy: eps, "from the topmost agreeing neighbour")
        XCTAssertEqual(g.end, 935, accuracy: eps, "to the dragged frame's bottom")
    }

    func testGuideDrawsAtExactSnappedPositionAndNeverDuplicates() {
        // Two neighbour edges 0.5pt apart (100.2 / 100.7): the snap lands on the nearer (100.7) and
        // BOTH coincide within the guide ε — they must collapse to ONE guide drawn at the EXACT
        // snapped coordinate (no 0.5pt-bucket rounding offset, no straddle duplicate).
        let a = CGRect(x: 100.2, y: 200, width: 50, height: 50)
        let b = CGRect(x: 100.7, y: 600, width: 50, height: 50)
        let dragged = CGRect(x: 103, y: 855, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [a, b], config: paneOnly)
        XCTAssertEqual(r.frame.minX, 100.7, accuracy: eps, "nearer edge wins")
        let vertical = r.guides.filter { $0.orientation == .vertical }
        XCTAssertEqual(vertical.count, 1, "coincident candidates collapse to one guide")
        XCTAssertEqual(
            vertical.first?.position ?? 0,
            100.7,
            accuracy: eps,
            "the guide draws at the true snapped coordinate",
        )
    }

    func testGutterGuideKind() {
        let other = CGRect(x: 100, y: 500, width: 200, height: 100)
        let dragged = CGRect(x: 311, y: 855, width: 150, height: 80) // gutter-snaps to 316
        let r = CanvasSnap.move(dragged, others: [other], config: config)
        XCTAssertEqual(r.guides.first?.kind, .gutter)
        XCTAssertEqual(
            r.guides.first?.position ?? 0,
            316,
            accuracy: eps,
            "gutter guide draws at the dragged pane's snapped edge",
        )
    }

    // MARK: Resize

    func testResizeSnapsMovingRightEdgeToNeighbourEdge() {
        let other = CGRect(x: 0, y: 0, width: 300, height: 100) // maxX = 300
        let preview = CGRect(x: 50, y: 600, width: 246, height: 200) // maxX = 296 → δ 4
        let r = CanvasSnap.resize(preview, anchor: .right, others: [other], config: config)
        XCTAssertEqual(r.frame.minX, 50, accuracy: eps, "pinned edge untouched")
        XCTAssertEqual(r.frame.maxX, 300, accuracy: eps, "moving edge snapped")
        XCTAssertTrue(paneSnappedX(r))
        XCTAssertNil(r.stickY, "resize .right never touches Y")
    }

    func testResizePinnedEdgeNeverSnaps() {
        // Dragging .right while the LEFT edge is 3pt off a neighbour edge: left must NOT move.
        let other = CGRect(x: 47, y: 0, width: 100, height: 100)
        let preview = CGRect(x: 50, y: 600, width: 500, height: 200)
        let r = CanvasSnap.resize(preview, anchor: .right, others: [other], config: config)
        XCTAssertEqual(r.frame.minX, 50, accuracy: eps, "pinned edge stays put")
    }

    func testResizeDiscardsMinSizeViolatingCandidate() {
        // The neighbour edge at 195 would shrink the pane below min width 160 → the candidate is
        // DISCARDED (not clamped): no snap, the raw preview passes through, and no guide can lie.
        let other = CGRect(x: 0, y: 0, width: 195, height: 100)
        let preview = CGRect(x: 40, y: 600, width: 162, height: 200) // maxX = 202, 7 off 195
        let r = CanvasSnap.resize(preview, anchor: .right, others: [other], config: paneOnly)
        XCTAssertEqual(r.frame.maxX, 202, accuracy: eps, "violating candidate discarded → free")
        XCTAssertEqual(r.frame.width, 162, accuracy: eps)
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testResizeTopLeftSnapsBothMovingEdges() {
        let other = CGRect(x: 100, y: 100, width: 200, height: 200)
        let preview = CGRect(x: 104, y: 96, width: 300, height: 300) // BR pinned at (404, 396)
        let r = CanvasSnap.resize(preview, anchor: .topLeft, others: [other], config: config)
        XCTAssertEqual(r.frame.minX, 100, accuracy: eps, "left edge → neighbour left")
        XCTAssertEqual(r.frame.minY, 100, accuracy: eps, "top edge → neighbour top")
        XCTAssertEqual(r.frame.maxX, 404, accuracy: eps, "pinned corner untouched")
        XCTAssertEqual(r.frame.maxY, 396, accuracy: eps, "pinned corner untouched")
    }

    func testResizeGutterAdjacency() {
        // Dragging .right toward a neighbour that starts at 400: butt-with-gutter target is 384.
        let other = CGRect(x: 400, y: 600, width: 200, height: 100)
        let preview = CGRect(x: 100, y: 600, width: 281, height: 200) // maxX = 381, 3 off 384
        let r = CanvasSnap.resize(preview, anchor: .right, others: [other], config: config)
        XCTAssertEqual(r.frame.maxX, 384, accuracy: eps, "edge butts with the standard gutter")
    }

    func testResizeHysteresisHoldsAcrossFrames() {
        let other = CGRect(x: 0, y: 0, width: 300, height: 100)
        let first = CanvasSnap.resize(
            CGRect(x: 50, y: 600, width: 246, height: 200),
            anchor: .right,
            others: [other],
            config: paneOnly,
        )
        XCTAssertEqual(first.frame.maxX, 300, accuracy: eps)
        // Raw edge drifts to 310 (10pt past target — beyond engage 8, inside release 12): held.
        let held = CanvasSnap.resize(
            CGRect(x: 50, y: 600, width: 260, height: 200),
            anchor: .right,
            others: [other],
            config: paneOnly,
            previous: first,
        )
        XCTAssertEqual(held.frame.maxX, 300, accuracy: eps, "edge held inside the release band")
        // 13pt past: released, raw passes through.
        let released = CanvasSnap.resize(
            CGRect(x: 50, y: 600, width: 263, height: 200),
            anchor: .right,
            others: [other],
            config: paneOnly,
            previous: held,
        )
        XCTAssertEqual(released.frame.maxX, 313, accuracy: eps)
    }

    // MARK: Sanity

    func testMoveWithNoOthersAndNoGridIsIdentity() {
        let dragged = CGRect(x: 123.4, y: 567.8, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [], config: paneOnly)
        assertRect(r.frame, dragged)
        XCTAssertTrue(r.guides.isEmpty)
    }

    func testMoveOutputIsSanitized() {
        // A non-finite input collapses (the Canvas.sanitize origin rule) instead of propagating NaN.
        let dragged = CGRect(x: CGFloat.nan, y: 100, width: 150, height: 80)
        let r = CanvasSnap.move(dragged, others: [], config: config)
        XCTAssertTrue(r.frame.minX.isFinite)
        XCTAssertTrue(r.frame.minY.isFinite)
    }
}
