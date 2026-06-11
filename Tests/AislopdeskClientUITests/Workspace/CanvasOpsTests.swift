import XCTest
import CoreGraphics
@testable import AislopdeskClientUI

/// Pure unit tests for ``Canvas`` queries + mutations + camera/arrange (docs/30 §3, §9.1). No client,
/// no async, no view — the ~85% pure seam. Every op returns a NEW value; these pin the invariants
/// (z-order determinism, min-size floor, the `removing → nil` tab-empties contract, lossless dedup,
/// the pan-only camera with no scale term).
final class CanvasOpsTests: XCTestCase {

    private let eps: CGFloat = 1e-6

    /// A PaneID whose UUID string sorts by `n` — so z-tie-break order is predictable in tests.
    private func pid(_ n: Int) -> PaneID {
        PaneID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }

    private func item(_ n: Int, _ frame: CGRect, z: Int, kind: PaneKind = .terminal) -> CanvasItem {
        CanvasItem(id: pid(n), spec: PaneSpec(kind: kind, title: "p\(n)"), frame: frame, z: z)
    }

    private let f0 = CGRect(x: 0, y: 0, width: 640, height: 420)

    // MARK: - Queries

    func testAllIDsSortByZThenID() {
        let canvas = Canvas(items: [
            item(3, f0, z: 2),
            item(1, f0, z: 0),
            item(2, f0, z: 0),   // tie with pid(1) at z=0 → pid(1) first
        ])
        XCTAssertEqual(canvas.allIDs(), [pid(1), pid(2), pid(3)])
    }

    func testItemCountContainsSpecFrameMaxZ() {
        let canvas = Canvas(items: [item(1, f0, z: 0), item(2, CGRect(x: 10, y: 20, width: 200, height: 200), z: 5)])
        XCTAssertEqual(canvas.itemCount, 2)
        XCTAssertTrue(canvas.contains(pid(1)))
        XCTAssertFalse(canvas.contains(pid(99)))
        XCTAssertEqual(canvas.spec(for: pid(2))?.title, "p2")
        XCTAssertEqual(canvas.frame(of: pid(2)), CGRect(x: 10, y: 20, width: 200, height: 200))
        XCTAssertNil(canvas.frame(of: pid(99)))
        XCTAssertEqual(canvas.maxZ, 5)
        XCTAssertEqual(Canvas(items: []).maxZ, -1)
    }

    func testHitTestPicksFrontmostOverlap() {
        // Two fully-overlapping items; the higher z wins.
        let canvas = Canvas(items: [
            item(1, CGRect(x: 0, y: 0, width: 300, height: 300), z: 0),
            item(2, CGRect(x: 0, y: 0, width: 300, height: 300), z: 9),
        ])
        XCTAssertEqual(canvas.hitTest(CGPoint(x: 150, y: 150)), pid(2))
        XCTAssertNil(canvas.hitTest(CGPoint(x: 999, y: 999)))
    }

    func testFramesByID() {
        let canvas = Canvas(items: [item(1, f0, z: 0)])
        XCTAssertEqual(canvas.framesByID()[pid(1)], f0)
    }

    // MARK: - dedup (load-time repair)

    func testDedupingItemIDsReMintsDuplicatesKeepingFirst() {
        // Same id twice — the registry is keyed 1:1 by PaneID, so the SECOND must be re-minted.
        let dup = pid(7)
        let canvas = Canvas(items: [
            CanvasItem(id: dup, spec: PaneSpec(kind: .terminal, title: "first"), frame: f0, z: 0),
            CanvasItem(id: dup, spec: PaneSpec(kind: .claudeCode, title: "second"), frame: CGRect(x: 50, y: 60, width: 300, height: 300), z: 1),
        ])
        var seen = Set<PaneID>()
        let deduped = canvas.dedupingItemIDs(seen: &seen)
        XCTAssertEqual(deduped.itemCount, 2)
        let ids = deduped.items.map(\.id)
        XCTAssertEqual(ids[0], dup, "first occurrence keeps its id")
        XCTAssertNotEqual(ids[1], dup, "duplicate is re-minted")
        XCTAssertEqual(Set(ids).count, 2, "ids now globally unique")
        // Lossless: specs + frames preserved.
        XCTAssertEqual(deduped.items[0].spec.title, "first")
        XCTAssertEqual(deduped.items[1].spec.title, "second")
        XCTAssertEqual(deduped.items[1].frame, CGRect(x: 50, y: 60, width: 300, height: 300))
    }

    // MARK: - Structural mutations

    func testAddingPlacesFrontmostNearFocused() throws {
        let canvas = Canvas(items: [item(1, f0, z: 0)])
        let (next, newID) = canvas.adding(PaneSpec(kind: .terminal, title: "new"), near: pid(1), viewport: CGSize(width: 1280, height: 800))
        XCTAssertEqual(next.itemCount, 2)
        XCTAssertTrue(next.contains(newID))
        XCTAssertEqual(next.item(newID)?.z, 1, "new item is frontmost (maxZ+1)")
        // Cascades down-right of the focused pane; since the new pane is the SAME size as the source it
        // keeps stepping until overlap ≤ 25% (it never stacks exactly on top).
        let newFrame = try XCTUnwrap(next.frame(of: newID))
        XCTAssertGreaterThan(newFrame.origin.x, 0, "placed down-right of the source")
        XCTAssertGreaterThan(newFrame.origin.y, 0)
        let inter = newFrame.intersection(f0)
        let frac = inter.isNull ? 0 : (inter.width * inter.height) / (newFrame.width * newFrame.height)
        XCTAssertLessThanOrEqual(frac, CanvasGeometry.overlapThreshold + eps, "does not stack on the source")
    }

    func testRemovingLastReturnsNil() {
        let canvas = Canvas(items: [item(1, f0, z: 0)])
        XCTAssertNil(canvas.removing(pid(1)), "removing the last item empties the tab (nil contract)")
    }

    func testRemovingPreservesSurvivorZAndAbsentIsNoop() {
        let canvas = Canvas(items: [item(1, f0, z: 3), item(2, f0, z: 7)])
        let next = canvas.removing(pid(1))
        XCTAssertEqual(next?.itemCount, 1)
        XCTAssertEqual(next?.item(pid(2))?.z, 7, "survivor z preserved (no renumber)")
        XCTAssertEqual(canvas.removing(pid(99)), canvas, "absent id is a no-op")
    }

    func testMovingByAndTo() {
        let canvas = Canvas(items: [item(1, CGRect(x: 100, y: 100, width: 640, height: 420), z: 0)])
        XCTAssertEqual(canvas.moving(pid(1), by: CGSize(width: 30, height: -20)).frame(of: pid(1))?.origin,
                       CGPoint(x: 130, y: 80))
        XCTAssertEqual(canvas.moving(pid(1), to: CGPoint(x: 5, y: 6)).frame(of: pid(1))?.origin,
                       CGPoint(x: 5, y: 6))
    }

    func testMovingNonFiniteDeltaIsSanitized() {
        let canvas = Canvas(items: [item(1, f0, z: 0)])
        let moved = canvas.moving(pid(1), by: CGSize(width: CGFloat.nan, height: CGFloat.infinity))
        let origin = moved.frame(of: pid(1))?.origin
        XCTAssertEqual(origin?.x, 0)
        XCTAssertEqual(origin?.y, 0)
    }

    func testResizingFloorsToMinItemSize() {
        let canvas = Canvas(items: [item(1, f0, z: 0)])
        let resized = canvas.resizing(pid(1), to: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(resized.frame(of: pid(1))?.size, Canvas.minItemSize)
    }

    func testRaisingBringsToFrontAndIsIdempotentAtTop() {
        let canvas = Canvas(items: [item(1, f0, z: 0), item(2, f0, z: 1)])
        let raised = canvas.raising(pid(1))
        XCTAssertEqual(raised.item(pid(1))?.z, 2, "raised to maxZ+1")
        XCTAssertEqual(raised.raising(pid(1)), raised, "already uniquely top → no-op")
        XCTAssertEqual(canvas.raising(pid(99)), canvas, "absent id → no-op")
    }

    func testUpdatingSpec() {
        let canvas = Canvas(items: [item(1, f0, z: 0)])
        let renamed = canvas.updatingSpec(pid(1)) { $0.title = "renamed" }
        XCTAssertEqual(renamed.spec(for: pid(1))?.title, "renamed")
    }

    // MARK: - Camera / arrange

    func testPannedHasNoScaleTerm() {
        let canvas = Canvas(items: [item(1, f0, z: 0)], camera: CanvasCamera(origin: CGPoint(x: 10, y: 20)))
        XCTAssertEqual(canvas.panned(by: CGSize(width: 5, height: 7)).camera.origin, CGPoint(x: 15, y: 27))
    }

    func testCenteredOnItem() {
        let canvas = Canvas(items: [item(1, CGRect(x: 200, y: 100, width: 640, height: 420), z: 0)])
        let centered = canvas.centered(on: pid(1), viewport: CGSize(width: 1000, height: 800))
        // item midX=520, midY=310 → camera = center - viewport/2 = (20, -90)
        XCTAssertEqual(centered.camera.origin.x, 20, accuracy: eps)
        XCTAssertEqual(centered.camera.origin.y, -90, accuracy: eps)
    }

    func testCenteredOnAllEmptyIsIdentity() {
        let canvas = Canvas(items: [])
        XCTAssertEqual(canvas.centeredOnAll(viewport: CGSize(width: 1000, height: 800)), canvas)
    }

    func testCenteredOnAllUsesBoundingBox() {
        let canvas = Canvas(items: [
            item(1, CGRect(x: 0, y: 0, width: 200, height: 200), z: 0),
            item(2, CGRect(x: 800, y: 600, width: 200, height: 200), z: 1),
        ])
        // bbox = (0,0)-(1000,800) → center (500,400) → camera = (500-500, 400-400) = (0,0) for 1000x800 vp
        let centered = canvas.centeredOnAll(viewport: CGSize(width: 1000, height: 800))
        XCTAssertEqual(centered.camera.origin.x, 0, accuracy: eps)
        XCTAssertEqual(centered.camera.origin.y, 0, accuracy: eps)
    }

    func testNeedsRecenter() {
        let canvas = Canvas(items: [item(1, CGRect(x: 0, y: 0, width: 200, height: 200), z: 0)],
                            camera: CanvasCamera(origin: CGPoint(x: 5000, y: 5000)))
        XCTAssertTrue(canvas.needsRecenter(viewport: CGSize(width: 800, height: 600)), "panned into empty space")
        XCTAssertFalse(canvas.camera(.zero).needsRecenter(viewport: CGSize(width: 800, height: 600)))
    }

    func testTidiedNoOverlapAndPreservesCountAndZ() {
        let canvas = Canvas(items: [
            item(1, CGRect(x: -500, y: -500, width: 300, height: 200), z: 5),
            item(2, CGRect(x: 0, y: 0, width: 300, height: 200), z: 6),
            item(3, CGRect(x: 9000, y: 9000, width: 300, height: 200), z: 7),
        ])
        let tidy = canvas.tidied(viewport: CGSize(width: 1280, height: 800))
        XCTAssertEqual(tidy.itemCount, 3)
        // z preserved (order-independent stacking).
        XCTAssertEqual(tidy.item(pid(1))?.z, 5)
        XCTAssertEqual(tidy.item(pid(3))?.z, 7)
        // No pairwise overlap after packing.
        let frames = tidy.items.map(\.frame)
        for i in frames.indices {
            for j in (i + 1)..<frames.count {
                XCTAssertTrue(frames[i].intersection(frames[j]).isNull || frames[i].intersection(frames[j]).isEmpty,
                              "tidied items must not overlap")
            }
        }
    }

    // MARK: - SolvedLayout (FocusResolver reuse)

    func testSolvedLayoutHasCanvasFramesAndNoDividers() {
        let canvas = Canvas(items: [item(1, f0, z: 0)], camera: CanvasCamera(origin: CGPoint(x: 99, y: 99)))
        let solved = canvas.solvedLayout()
        XCTAssertEqual(solved.frames[pid(1)], f0, "canvas-space, camera-independent")
    }
}
