import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pure tests for ``CanvasNonOverlap`` — the non-overlap layout solver behind canvas drags:
/// swept collide-and-slide (flush stop, tangential slide, inside-corner tuck, path-independence),
/// the commit-time make-space relaxation (symmetric parting, intent gate, no-overlap invariant,
/// order-independence, dense-pack termination), group bodies, and the disabled-bypass identity.
///
/// Default config: gutter 16, skin 0.1, insertCoverage 0.5. Fixtures keep neighbours on integer
/// grids; slide assertions allow ±skin on the contact axis (the safe-side back-off), exact on the
/// free axis.
final class CanvasNonOverlapTests: XCTestCase {
    private let cfg = CanvasNonOverlap.Config()

    private func pane(_ rect: CGRect, _ id: PaneID = PaneID()) -> CanvasNonOverlap.Body {
        CanvasNonOverlap.Body(id: .pane(id), rect: rect)
    }

    /// Whether two rects are separated by at least `gutter − ε` (the output invariant). Uses the solver's
    /// own ``CanvasNonOverlap/separation(_:_:gutter:)`` predicate so the test and the solver agree.
    private func separated(_ a: CGRect, _ b: CGRect, gutter: CGFloat = 16, eps: CGFloat = 0.2) -> Bool {
        CanvasNonOverlap.separation(a, b.insetBy(dx: eps, dy: eps), gutter: gutter) == nil
    }

    // MARK: - Slide

    func testSlideEndsFlushAtGutter() {
        // Box driven straight right into a neighbour's left face stops one gutter short, Y untouched.
        let neighbour = pane(CGRect(x: 300, y: 0, width: 200, height: 200))
        let box = CGRect(x: 0, y: 100, width: 150, height: 100)
        let r = CanvasNonOverlap.slide(box.offsetBy(dx: 200, dy: 0), from: box.origin, bodies: [neighbour], config: cfg)
        XCTAssertEqual(r.frame.maxX, 284, accuracy: 0.3, "right edge flush at neighbour.minX − gutter")
        XCTAssertEqual(r.frame.minY, 100, accuracy: 1e-6, "free axis preserved")
        XCTAssertTrue(separated(r.frame, neighbour.rect), "no overlap")
    }

    func testSlideIsTangentialIntoWall() {
        // Dragging down-and-right into a tall wall: the X (into-face) motion is cancelled at the wall,
        // the full Y (along-face) motion is preserved — the box slid DOWN the boundary.
        let wall = pane(CGRect(x: 300, y: 0, width: 200, height: 400))
        let box = CGRect(x: 0, y: 50, width: 150, height: 100)
        let r = CanvasNonOverlap.slide(box.offsetBy(dx: 250, dy: 200), from: box.origin, bodies: [wall], config: cfg)
        XCTAssertEqual(r.frame.maxX, 284, accuracy: 0.3, "blocked flush on X")
        XCTAssertEqual(r.frame.minY, 250, accuracy: 0.3, "full Y travel preserved (slid along the wall)")
        XCTAssertTrue(separated(r.frame, wall.rect))
    }

    func testSlideTucksIntoInsideCorner() {
        // Two abutting neighbours form an inside corner; the box ends flush against BOTH (multi-pass
        // re-sweep), proving it does not tunnel through the second after stopping on the first.
        let right = pane(CGRect(x: 300, y: 0, width: 200, height: 300))
        let below = pane(CGRect(x: 0, y: 300, width: 500, height: 200))
        let box = CGRect(x: 0, y: 0, width: 150, height: 100)
        let r = CanvasNonOverlap.slide(
            box.offsetBy(dx: 300, dy: 300),
            from: box.origin,
            bodies: [right, below],
            config: cfg,
        )
        XCTAssertEqual(r.frame.maxX, 284, accuracy: 0.3, "flush against the right neighbour")
        XCTAssertEqual(r.frame.maxY, 284, accuracy: 0.3, "flush against the below neighbour")
        XCTAssertTrue(separated(r.frame, right.rect))
        XCTAssertTrue(separated(r.frame, below.rect))
    }

    func testSlideClearsNeighbourExactlyOneGutterOnPerpendicularAxis() {
        // Regression: a neighbour exactly one gutter BELOW (the tidied-grid row pitch) must NOT block a
        // horizontal slide. With the old inclusive zero-velocity slab the drag froze at x≈0.
        let below = pane(CGRect(x: 0, y: 216, width: 200, height: 200)) // dragged box maxY 200, gap = 16
        let box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = CanvasNonOverlap.slide(box.offsetBy(dx: 600, dy: 0), from: box.origin, bodies: [below], config: cfg)
        XCTAssertEqual(r.frame.minX, 600, accuracy: 0.3, "slides freely past the gutter-below neighbour")
    }

    func testSlideStillBlocksSameRowNeighbourAfterStrictFix() {
        // The strict slab must not weaken real blocking: a same-row neighbour still stops the slide flush.
        let right = pane(CGRect(x: 500, y: 0, width: 200, height: 200))
        let box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = CanvasNonOverlap.slide(box.offsetBy(dx: 600, dy: 0), from: box.origin, bodies: [right], config: cfg)
        XCTAssertEqual(r.frame.maxX, 484, accuracy: 0.3, "stops one gutter short of the same-row neighbour")
    }

    func testSlideNoNeighboursIsIdentity() {
        let box = CGRect(x: 0, y: 0, width: 150, height: 100)
        let target = box.offsetBy(dx: 320, dy: 110)
        let r = CanvasNonOverlap.slide(target, from: box.origin, bodies: [], config: cfg)
        XCTAssertEqual(r.frame, target, "nothing to hit → snapped target unchanged")
    }

    func testSlideIsFunctionOfRawTranslationNotPath() {
        // The solver carries NO frame-to-frame state: a single big slide and the .onEnded recompute from
        // the same (from, snapped) are byte-identical — the preview≡commit invariant.
        let n = pane(CGRect(x: 300, y: 0, width: 200, height: 400))
        let box = CGRect(x: 0, y: 50, width: 150, height: 100)
        let target = box.offsetBy(dx: 250, dy: 200)
        let a = CanvasNonOverlap.slide(target, from: box.origin, bodies: [n], config: cfg)
        let b = CanvasNonOverlap.slide(target, from: box.origin, bodies: [n], config: cfg)
        XCTAssertEqual(a, b)
    }

    func testSlideDepenetratesAlreadyOverlappingStart() {
        // Box starts overlapping (feature turned on over a stacked layout); a zero-translation slide still
        // pops it gutter-clear.
        let n = pane(CGRect(x: 100, y: 100, width: 200, height: 200))
        let box = CGRect(x: 150, y: 150, width: 150, height: 150) // overlaps n
        let r = CanvasNonOverlap.slide(box, from: box.origin, bodies: [n], config: cfg)
        XCTAssertTrue(separated(r.frame, n.rect), "depenetrated to non-overlapping")
        XCTAssertEqual(r.frame.size, box.size, "size preserved")
    }

    // MARK: - Make-space

    func testMakeSpacePartsTwoNeighboursSymmetrically() throws {
        let lID = PaneID(), rID = PaneID()
        let left = pane(CGRect(x: 0, y: 0, width: 300, height: 300), lID)
        let right = pane(CGRect(x: 300, y: 0, width: 300, height: 300), rID)
        // Box dropped centred on the seam (x=300), overlapping each by 100 → 0.5 coverage, opposing sides.
        let target = CGRect(x: 200, y: 50, width: 200, height: 200)
        let result = CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(PaneID()),
            bodies: [left, right],
            config: cfg,
        )
        let r = try XCTUnwrap(result, "insert intent should arm")
        // 100 overlap + 16 gutter = 116 each, symmetric.
        XCTAssertEqual(
            try XCTUnwrap(r.frames[.pane(lID)]?.minX),
            -116,
            accuracy: 0.01,
            "left parted left by overlap+gutter",
        )
        XCTAssertEqual(
            try XCTUnwrap(r.frames[.pane(rID)]?.minX),
            416,
            accuracy: 0.01,
            "right parted right symmetrically",
        )
        XCTAssertTrue(try separated(XCTUnwrap(r.frames[.pane(lID)]), target))
        XCTAssertTrue(try separated(XCTUnwrap(r.frames[.pane(rID)]), target))
        XCTAssertEqual(r.frames.count, 3, "dragged + both neighbours")
    }

    func testMakeSpaceLeavesDraggedAtDropExactly() throws {
        let left = pane(CGRect(x: 0, y: 0, width: 300, height: 300))
        let right = pane(CGRect(x: 300, y: 0, width: 300, height: 300))
        let dID = PaneID()
        let target = CGRect(x: 200, y: 50, width: 200, height: 200)
        let r = try XCTUnwrap(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(dID),
            bodies: [left, right],
            config: cfg,
        ))
        XCTAssertEqual(r.frames[.pane(dID)], target, "the pinned dragged body stays pixel-exact at its drop")
    }

    func testIntentGateStaysSlideOnEdgeBrush() {
        // A shallow single-side brush (20% coverage) is NOT an insert → nil (caller keeps the slid frame).
        let l = pane(CGRect(x: 0, y: 0, width: 300, height: 300))
        let target = CGRect(x: 260, y: 50, width: 200, height: 200) // 40-wide overlap → 0.2 coverage
        XCTAssertNil(CanvasNonOverlap.makeSpace(target: target, draggedID: .pane(PaneID()), bodies: [l], config: cfg))
    }

    func testIntentGateDisarmsBelowCoverage() {
        // Wedged between two neighbours but each overlap is tiny → coverage gate keeps it slide-only.
        let l = pane(CGRect(x: 0, y: 0, width: 300, height: 300))
        let r = pane(CGRect(x: 360, y: 0, width: 300, height: 300))
        let target = CGRect(x: 280, y: 50, width: 100, height: 200) // overlaps each ~20 → low coverage
        XCTAssertNil(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(PaneID()),
            bodies: [l, r],
            config: cfg,
        ))
    }

    func testMakeSpaceNoOverlappersIsNil() {
        let l = pane(CGRect(x: 0, y: 0, width: 200, height: 200))
        let target = CGRect(x: 400, y: 0, width: 200, height: 200) // clear of l
        XCTAssertNil(CanvasNonOverlap.makeSpace(target: target, draggedID: .pane(PaneID()), bodies: [l], config: cfg))
    }

    func testMakeSpaceCascadesWithoutOutputOverlap() throws {
        // Drop into the centre of a 3×3 tight block; everything must end non-overlapping (cascade).
        var bodies: [CanvasNonOverlap.Body] = []
        for row in 0..<3 { for col in 0..<3 {
            bodies.append(pane(CGRect(x: CGFloat(col) * 210, y: CGFloat(row) * 210, width: 200, height: 200)))
        } }
        let target = CGRect(x: 180, y: 180, width: 200, height: 200) // smothers the centre cell (≥0.5 coverage)
        let r = try XCTUnwrap(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(PaneID()),
            bodies: bodies,
            config: cfg,
        ))
        // Reconstruct the full output set (moved frames override originals) + the dragged target.
        var out: [CGRect] = [target]
        for b in bodies { out.append(r.frames[b.id] ?? b.rect) }
        for i in out.indices { for j in (i + 1)..<out.count {
            XCTAssertTrue(separated(out[i], out[j]), "pair \(i),\(j) overlaps after make-space")
        } }
    }

    // MARK: - Determinism

    func testSlideIsOrderIndependentUnderPermutedBodies() {
        let a = pane(CGRect(x: 300, y: 0, width: 200, height: 400))
        let b = pane(CGRect(x: 0, y: 300, width: 500, height: 200))
        let box = CGRect(x: 0, y: 0, width: 150, height: 100)
        let target = box.offsetBy(dx: 300, dy: 300)
        let r1 = CanvasNonOverlap.slide(target, from: box.origin, bodies: [a, b], config: cfg)
        let r2 = CanvasNonOverlap.slide(target, from: box.origin, bodies: [b, a], config: cfg)
        XCTAssertEqual(r1, r2, "internal canonical sort → input order cannot change the result")
    }

    func testMakeSpaceIsOrderIndependentUnderPermutedBodies() throws {
        let l = pane(CGRect(x: 0, y: 0, width: 300, height: 300))
        let r = pane(CGRect(x: 300, y: 0, width: 300, height: 300))
        let dID = PaneID()
        let target = CGRect(x: 200, y: 50, width: 200, height: 200)
        let a = try XCTUnwrap(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(dID),
            bodies: [l, r],
            config: cfg,
        ))
        let b = try XCTUnwrap(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(dID),
            bodies: [r, l],
            config: cfg,
        ))
        XCTAssertEqual(a, b)
    }

    func testDensePackTerminatesFiniteAndInBound() throws {
        var bodies: [CanvasNonOverlap.Body] = []
        for i in 0..<25 { bodies.append(pane(CGRect(x: CGFloat(i) * 5, y: CGFloat(i) * 5, width: 200, height: 200))) }
        let target = CGRect(x: 60, y: 60, width: 200, height: 200)
        let r = try XCTUnwrap(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(PaneID()),
            bodies: bodies,
            config: cfg,
        ))
        for (_, f) in r.frames {
            XCTAssertTrue(f.minX.isFinite && f.minY.isFinite && f.width.isFinite && f.height.isFinite, "finite")
            XCTAssertLessThanOrEqual(abs(f.minX), Canvas.coordinateBound)
            XCTAssertGreaterThanOrEqual(f.width, 0)
        }
    }

    // MARK: - Groups

    func testGroupBodyIsSeparatedLikeAPane() throws {
        // A .group body parts exactly like a pane when the dragged pane is dropped over it.
        let gID = PaneGroupID()
        let group = CanvasNonOverlap.Body(id: .group(gID), rect: CGRect(x: 250, y: 0, width: 300, height: 300))
        let target = CGRect(x: 100, y: 50, width: 300, height: 200) // overlaps the group box heavily
        let r = try XCTUnwrap(CanvasNonOverlap.makeSpace(
            target: target,
            draggedID: .pane(PaneID()),
            bodies: [group],
            config: cfg,
        ))
        let moved = try XCTUnwrap(r.frames[.group(gID)], "the group box was displaced")
        XCTAssertTrue(separated(moved, target), "group box parted clear of the dragged pane")
    }

    // MARK: - Resize clamp

    func testClampResizeStopsGrowingEdgeAtNeighbour() {
        let neighbour = pane(CGRect(x: 380, y: 0, width: 200, height: 200))
        // A pane grown rightward to maxX 400 (anchor .right) is clamped to neighbour.minX − gutter.
        let grown = CGRect(x: 0, y: 0, width: 400, height: 200)
        let out = CanvasNonOverlap.clampResize(
            grown,
            anchor: .right,
            bodies: [neighbour],
            minSize: Canvas.minItemSize,
            config: cfg,
        )
        XCTAssertEqual(out.maxX, 364, accuracy: 1e-6, "right edge stops one gutter short of the neighbour")
        XCTAssertEqual(out.minX, 0, accuracy: 1e-6, "pinned edge never moves")
    }

    func testClampResizeIgnoresShrink() {
        let neighbour = pane(CGRect(x: 380, y: 0, width: 200, height: 200))
        let shrunk = CGRect(x: 0, y: 0, width: 180, height: 200) // receding away from the neighbour
        let out = CanvasNonOverlap.clampResize(
            shrunk,
            anchor: .right,
            bodies: [neighbour],
            minSize: Canvas.minItemSize,
            config: cfg,
        )
        XCTAssertEqual(out, shrunk, "a shrink is never constrained")
    }

    func testClampResizeRespectsMinSize() {
        let neighbour = pane(CGRect(x: 100, y: 0, width: 200, height: 200)) // no room — closer than minSize
        let grown = CGRect(x: 0, y: 0, width: 400, height: 200)
        let out = CanvasNonOverlap.clampResize(
            grown,
            anchor: .right,
            bodies: [neighbour],
            minSize: Canvas.minItemSize,
            config: cfg,
        )
        XCTAssertEqual(out.width, Canvas.minItemSize.width, accuracy: 1e-6, "never clamped below the min width")
    }

    func testClampResizeDisabledIsIdentity() {
        let neighbour = pane(CGRect(x: 380, y: 0, width: 200, height: 200))
        let grown = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(
            CanvasNonOverlap
                .clampResize(
                    grown,
                    anchor: .right,
                    bodies: [neighbour],
                    minSize: Canvas.minItemSize,
                    config: .disabled,
                ),
            grown,
        )
    }

    // MARK: - Canvas integration (collisionBodies + applying)

    private func spec() -> PaneSpec { PaneSpec(kind: .terminal, title: "p") }

    func testCollisionBodiesIsUngroupedPanesPlusGroupBoxes() {
        let u = PaneID(), g1 = PaneID(), g2 = PaneID()
        let gid = PaneGroupID()
        let canvas = Canvas(items: [
            CanvasItem(id: u, spec: spec(), frame: CGRect(x: 0, y: 0, width: 200, height: 200), z: 0),
            CanvasItem(id: g1, spec: spec(), frame: CGRect(x: 400, y: 0, width: 200, height: 200), z: 1, groupID: gid),
            CanvasItem(id: g2, spec: spec(), frame: CGRect(x: 700, y: 0, width: 200, height: 200), z: 2, groupID: gid),
        ])
        let region = CGRect(x: -500, y: -500, width: 3000, height: 3000)
        // Dragging the ungrouped pane: bodies = the group box only (its own pane excluded).
        let dragU = canvas.collisionBodies(
            excludingPane: u,
            excludingGroup: nil,
            region: region,
            groups: [PaneGroup(id: gid, name: "G")],
        )
        XCTAssertEqual(dragU.count, 1)
        XCTAssertEqual(dragU.first?.id, .group(gid))
        XCTAssertEqual(dragU.first?.rect, canvas.groupBoundingBox(gid))
        // Dragging a group member: bodies = the ungrouped pane only (own group + members excluded).
        let dragG1 = canvas.collisionBodies(
            excludingPane: g1,
            excludingGroup: gid,
            region: region,
            groups: [PaneGroup(id: gid, name: "G")],
        )
        XCTAssertEqual(dragG1.map(\.id), [.pane(u)])
    }

    func testApplyingDistributesGroupDeltaToAllMembers() throws {
        let g1 = PaneID(), g2 = PaneID()
        let gid = PaneGroupID()
        let canvas = Canvas(items: [
            CanvasItem(
                id: g1,
                spec: spec(),
                frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                z: 0,
                groupID: gid,
            ),
            CanvasItem(
                id: g2,
                spec: spec(),
                frame: CGRect(x: 350, y: 100, width: 200, height: 200),
                z: 1,
                groupID: gid,
            ),
        ])
        let box = try XCTUnwrap(canvas.groupBoundingBox(gid))
        // A make-space result that shifts the group box by (+60, +40).
        let result = CanvasNonOverlap.CommitResult(frames: [.group(gid): box.offsetBy(dx: 60, dy: 40)])
        let out = canvas.applying(result, groups: [PaneGroup(id: gid, name: "G")])
        XCTAssertEqual(out.frame(of: g1)?.origin, CGPoint(x: 160, y: 140), "member 1 shifted rigidly")
        XCTAssertEqual(
            out.frame(of: g2)?.origin,
            CGPoint(x: 410, y: 140),
            "member 2 shifted rigidly (internal layout preserved)",
        )
    }

    func testMovingGroupTranslatesAllMembers() {
        let g1 = PaneID(), g2 = PaneID(), gid = PaneGroupID()
        let canvas = Canvas(items: [
            CanvasItem(id: g1, spec: spec(), frame: CGRect(x: 0, y: 0, width: 200, height: 200), z: 0, groupID: gid),
            CanvasItem(id: g2, spec: spec(), frame: CGRect(x: 300, y: 0, width: 200, height: 200), z: 1, groupID: gid),
        ])
        let out = canvas.movingGroup(gid, by: CGSize(width: 50, height: 30))
        XCTAssertEqual(out.frame(of: g1)?.origin, CGPoint(x: 50, y: 30))
        XCTAssertEqual(out.frame(of: g2)?.origin, CGPoint(x: 350, y: 30))
    }

    func testResizingGroupAffineRemapsMembers() {
        let g1 = PaneID(), g2 = PaneID(), gid = PaneGroupID()
        let canvas = Canvas(items: [
            CanvasItem(id: g1, spec: spec(), frame: CGRect(x: 0, y: 0, width: 200, height: 200), z: 0, groupID: gid),
            CanvasItem(id: g2, spec: spec(), frame: CGRect(x: 300, y: 0, width: 200, height: 200), z: 1, groupID: gid),
        ])
        // Box (0,0,500,200) → (0,0,1000,400): scale ×2 both axes.
        let out = canvas.resizingGroup(gid, toBox: CGRect(x: 0, y: 0, width: 1000, height: 400))
        XCTAssertEqual(out.frame(of: g1), CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertEqual(out.frame(of: g2), CGRect(x: 600, y: 0, width: 400, height: 400))
    }

    /// The floored version of a proposed group box: a group can never be smaller than a pane, so the
    /// production code clamps the proposed box up to at least minItemSize per axis. Tests assert
    /// containment against THIS box (NOT `groupBoundingBox`, which is the union of the members — asserting
    /// members lie within their own union is a tautology that passes even against the un-fixed code).
    private func flooredBox(_ proposed: CGRect) -> CGRect {
        CGRect(
            x: proposed.minX,
            y: proposed.minY,
            width: Swift.max(proposed.width, Canvas.minItemSize.width),
            height: Swift.max(proposed.height, Canvas.minItemSize.height),
        )
    }

    func testResizingGroupToSubFloorBoxKeepsMembersContained() throws {
        // Two minItemSize panes, shrunk to a single-pane box: members floor at minItemSize and cannot
        // scale below it, so the naive affine remap spilled the second member to maxX≈249 — OUTSIDE the
        // box — and could feed the non-overlap solver overlapping input. Every member must stay inside the
        // FLOORED PROPOSED box (asserted against that box, not the members' own union).
        let g1 = PaneID(), g2 = PaneID(), gid = PaneGroupID()
        let min = Canvas.minItemSize
        let canvas = Canvas(items: [
            CanvasItem(id: g1, spec: spec(), frame: CGRect(origin: CGPoint.zero, size: min), z: 0, groupID: gid),
            CanvasItem(
                id: g2,
                spec: spec(),
                frame: CGRect(origin: CGPoint(x: min.width + 40, y: 0), size: min),
                z: 1,
                groupID: gid,
            ),
        ])
        let proposed = CGRect(x: 0, y: 0, width: 160, height: 160)
        let out = canvas.resizingGroup(gid, toBox: proposed)
        let box = flooredBox(proposed)
        for id in [g1, g2] {
            let f = try XCTUnwrap(out.frame(of: id))
            XCTAssertGreaterThanOrEqual(f.minX, box.minX - 0.001, "member \(id) leaks left of the floored box")
            XCTAssertGreaterThanOrEqual(f.minY, box.minY - 0.001, "member \(id) leaks above the floored box")
            XCTAssertLessThanOrEqual(f.maxX, box.maxX + 0.001, "member \(id) leaks right of the floored box")
            XCTAssertLessThanOrEqual(f.maxY, box.maxY + 0.001, "member \(id) leaks below the floored box")
            XCTAssertGreaterThanOrEqual(f.width, min.width - 0.001, "member kept its minItemSize width floor")
            XCTAssertGreaterThanOrEqual(f.height, min.height - 0.001, "member kept its minItemSize height floor")
        }
    }

    func testResizingGroupFloorsASubFloorBoxToMinItemSize() throws {
        // A MULTI-member group asked to shrink to a 10×10 box. A single member can't distinguish the
        // box-floor (per-member sanitize alone floors it); with two members the naive remap spills the
        // second past the floored width (box.maxX≈166 > 160), so asserting the resulting box never
        // exceeds the floored proposed box is a real regression net.
        let g1 = PaneID(), g2 = PaneID(), gid = PaneGroupID()
        let min = Canvas.minItemSize
        let canvas = Canvas(items: [
            CanvasItem(id: g1, spec: spec(), frame: CGRect(x: 0, y: 0, width: 200, height: 200), z: 0, groupID: gid),
            CanvasItem(id: g2, spec: spec(), frame: CGRect(x: 300, y: 0, width: 200, height: 200), z: 1, groupID: gid),
        ])
        let proposed = CGRect(x: 0, y: 0, width: 10, height: 10)
        let out = canvas.resizingGroup(gid, toBox: proposed)
        let floored = flooredBox(proposed)
        let box = try XCTUnwrap(out.groupBoundingBox(gid))
        XCTAssertLessThanOrEqual(box.maxX, floored.maxX + 0.001, "the group box never exceeds the floored width")
        XCTAssertLessThanOrEqual(box.maxY, floored.maxY + 0.001, "the group box never exceeds the floored height")
        XCTAssertGreaterThanOrEqual(box.width, min.width - 0.001, "the box is floored to at least minItemSize wide")
        XCTAssertGreaterThanOrEqual(box.height, min.height - 0.001, "the box is floored to at least minItemSize tall")
    }

    // MARK: - Bypass

    func testDisabledConfigIsIdentity() {
        let n = pane(CGRect(x: 300, y: 0, width: 200, height: 200))
        let box = CGRect(x: 0, y: 100, width: 150, height: 100)
        let target = box.offsetBy(dx: 320, dy: 0)
        XCTAssertEqual(
            CanvasNonOverlap.slide(target, from: box.origin, bodies: [n], config: .disabled).frame,
            target,
            "disabled slide is identity",
        )
        XCTAssertNil(
            CanvasNonOverlap.makeSpace(target: target, draggedID: .pane(PaneID()), bodies: [n], config: .disabled),
            "disabled make-space never arms",
        )
    }
}
