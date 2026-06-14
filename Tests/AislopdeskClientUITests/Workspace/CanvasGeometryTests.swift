import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pure tests for ``CanvasGeometry`` — the screen transform (a rigid 1:1 translate), the 8-anchor
/// resize math, and new-pane placement (docs/30 §3, §9.1). The resize table is the canvas analogue of
/// `SplitContainerTests`' `applyingDelta` coverage.
final class CanvasGeometryTests: XCTestCase {
    private let eps: CGFloat = 1e-6
    private let minSize = Canvas.minItemSize // 160 × 120

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

    // MARK: screenRect — 1:1 translate

    func testScreenRectIsPureTranslate() {
        let f = CGRect(x: 100, y: 50, width: 640, height: 420)
        let cam = CanvasCamera(origin: CGPoint(x: 30, y: -20))
        let r = CanvasGeometry.screenRect(f, camera: cam)
        assertRect(r, CGRect(x: 70, y: 70, width: 640, height: 420), "translate only, size verbatim")
    }

    func testScreenRectRoundTripsCanvasPoint() {
        let cam = CanvasCamera(origin: CGPoint(x: 12, y: 34))
        let screen = CGPoint(x: 5, y: 6)
        let canvasPt = CanvasGeometry.canvasPoint(screen, camera: cam)
        XCTAssertEqual(canvasPt, CGPoint(x: 17, y: 40))
        // screenRect of a zero-size frame at canvasPt maps back to screen.
        let back = CanvasGeometry.screenRect(CGRect(origin: canvasPt, size: .zero), camera: cam)
        XCTAssertEqual(back.origin, screen)
    }

    // MARK: resize — all 8 anchors

    /// Start 200×200 at (100,100); drag each anchor by (+40,+30). Opposite edge(s) pinned.
    func testResizeAllAnchors() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 200) // edges: L100 R300 T100 B300
        let d = CGSize(width: 40, height: 30)
        func r(_ a: ResizeAnchor) -> CGRect { CanvasGeometry.resizing(base, anchor: a, by: d, minSize: minSize) }

        assertRect(r(.right), CGRect(x: 100, y: 100, width: 240, height: 200), "right edge +40")
        assertRect(r(.left), CGRect(x: 140, y: 100, width: 160, height: 200), "left edge +40 (R pinned)")
        assertRect(r(.bottom), CGRect(x: 100, y: 100, width: 200, height: 230), "bottom +30")
        assertRect(r(.top), CGRect(x: 100, y: 130, width: 200, height: 170), "top +30 (B pinned)")
        assertRect(r(.bottomRight), CGRect(x: 100, y: 100, width: 240, height: 230), "BR both grow")
        assertRect(r(.topLeft), CGRect(x: 140, y: 130, width: 160, height: 170), "TL both, opposite pinned")
        assertRect(r(.topRight), CGRect(x: 100, y: 130, width: 240, height: 170), "TR: R grows, T moves")
        assertRect(r(.bottomLeft), CGRect(x: 140, y: 100, width: 160, height: 230), "BL: L moves, B grows")
    }

    func testResizeFloorsByPushingMovedEdge() {
        let base = CGRect(x: 100, y: 100, width: 200, height: 200)
        // Drag the LEFT edge far right (shrinks width past min): right edge (300) stays pinned, left
        // clamps to 300 - 160 = 140.
        let r = CanvasGeometry.resizing(base, anchor: .left, by: CGSize(width: 999, height: 0), minSize: minSize)
        assertRect(r, CGRect(x: 140, y: 100, width: 160, height: 200), "left clamp keeps right pinned")
        // Drag the RIGHT edge far left: left edge (100) pinned, right clamps to 100 + 160 = 260.
        let r2 = CanvasGeometry.resizing(base, anchor: .right, by: CGSize(width: -999, height: 0), minSize: minSize)
        assertRect(r2, CGRect(x: 100, y: 100, width: 160, height: 200), "right clamp keeps left pinned")
    }

    // MARK: placement

    func testPlacementCascadesFromNear() {
        let near = CGRect(x: 200, y: 200, width: 640, height: 420)
        let p = CanvasGeometry.placement(
            near: near,
            existing: [near],
            viewport: CGRect(x: 0, y: 0, width: 1280, height: 800),
            size: Canvas.defaultItemSize,
        )
        // first cascade step lands at near.origin + (28,28); overlap with `near` there is tested to be
        // ≤25% so it is accepted (640×420 shifted 28,28 overlaps ~ (612*392)/(640*420) ≈ 0.89 of its
        // area → MUST nudge further). So it keeps stepping until overlap ≤ 25%.
        XCTAssertGreaterThan(p.origin.x, near.origin.x, "stepped down-right past the source")
        XCTAssertGreaterThan(p.origin.y, near.origin.y)
        // Final candidate overlaps the source by ≤ 25% of its own area.
        let inter = p.intersection(near)
        let frac = inter.isNull ? 0 : (inter.width * inter.height) / (p.width * p.height)
        XCTAssertLessThanOrEqual(frac, CanvasGeometry.overlapThreshold + eps)
    }

    func testPlacementCentersWhenNoNear() {
        let vp = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let p = CanvasGeometry.placement(
            near: nil,
            existing: [],
            viewport: vp,
            size: Canvas.defaultItemSize,
        )
        XCTAssertEqual(p.midX, vp.midX, accuracy: eps)
        XCTAssertEqual(p.midY, vp.midY, accuracy: eps)
    }

    func testPlacementNoCollisionReturnsSeed() {
        let near = CGRect(x: 0, y: 0, width: 100, height: 100)
        // No existing → seed (near.origin + cascade) is accepted immediately.
        let p = CanvasGeometry.placement(
            near: near,
            existing: [],
            viewport: CGRect(x: 0, y: 0, width: 1280, height: 800),
            size: Canvas.defaultItemSize,
        )
        assertRect(
            p,
            CGRect(origin: CGPoint(x: Canvas.cascadeStep, y: Canvas.cascadeStep), size: Canvas.defaultItemSize),
        )
    }

    // MARK: offscreenBeacons

    private func item(_ id: PaneID, _ frame: CGRect, kind: PaneKind = .terminal) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: kind, title: "p"), frame: frame, z: 0)
    }

    func testNoBeaconForAVisiblePane() {
        let id = PaneID()
        let items = [item(id, CGRect(x: 100, y: 100, width: 200, height: 150))]
        let beacons = CanvasGeometry.offscreenBeacons(
            items,
            camera: .zero,
            viewport: CGSize(width: 1280, height: 800),
        )
        XCTAssertTrue(beacons.isEmpty, "a pane intersecting the viewport gets no beacon")
    }

    func testBeaconEdgeAndClampForEachDirection() {
        let vp = CGSize(width: 1000, height: 800)
        let inset: CGFloat = 18
        // A pane far to the RIGHT (off the right edge).
        let right = PaneID()
        let rb = CanvasGeometry.offscreenBeacons(
            [item(right, CGRect(x: 5000, y: 300, width: 100, height: 100))],
            camera: .zero,
            viewport: vp,
            inset: inset,
        )
        XCTAssertEqual(rb.count, 1)
        XCTAssertEqual(rb[0].edge, .right)
        XCTAssertEqual(rb[0].screenPoint.x, vp.width - inset, accuracy: eps, "clamped to the right inset")
        // ABOVE (off the top edge).
        let up = PaneID()
        let ub = CanvasGeometry.offscreenBeacons(
            [item(up, CGRect(x: 400, y: -4000, width: 100, height: 100))],
            camera: .zero,
            viewport: vp,
            inset: inset,
        )
        XCTAssertEqual(ub[0].edge, .top)
        XCTAssertEqual(ub[0].screenPoint.y, inset, accuracy: eps)
        // LEFT.
        let left = PaneID()
        let lb = CanvasGeometry.offscreenBeacons(
            [item(left, CGRect(x: -5000, y: 300, width: 100, height: 100))],
            camera: .zero,
            viewport: vp,
            inset: inset,
        )
        XCTAssertEqual(lb[0].edge, .left)
        XCTAssertEqual(lb[0].screenPoint.x, inset, accuracy: eps)
        // BELOW.
        let down = PaneID()
        let db = CanvasGeometry.offscreenBeacons(
            [item(down, CGRect(x: 400, y: 6000, width: 100, height: 100))],
            camera: .zero,
            viewport: vp,
            inset: inset,
        )
        XCTAssertEqual(db[0].edge, .bottom)
        XCTAssertEqual(db[0].screenPoint.y, vp.height - inset, accuracy: eps)
    }

    func testBeaconTracksCamera() {
        // A pane at canvas (2000, 100): off-screen with camera at origin (right edge)…
        let id = PaneID()
        let items = [item(id, CGRect(x: 2000, y: 100, width: 200, height: 150))]
        let vp = CGSize(width: 1280, height: 800)
        XCTAssertEqual(CanvasGeometry.offscreenBeacons(items, camera: .zero, viewport: vp).count, 1)
        // …but VISIBLE once the camera pans to it → no beacon.
        let panned = CanvasCamera(origin: CGPoint(x: 1900, y: 0))
        XCTAssertTrue(CanvasGeometry.offscreenBeacons(items, camera: panned, viewport: vp).isEmpty)
    }
}
