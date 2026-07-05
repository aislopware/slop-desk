import CoreGraphics
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoHost

/// Tests for the PURE content-mask conversion (`SlopDeskVideoHostSession.maskRects`) that turns the
/// GLOBAL opaque content rects (window + popups, from the Rust `capture_region::content_rects`) into
/// capture-local PIXEL `MaskRect`s the client masks the black flank with. No session, no SCStream —
/// only the geometry, so it runs headlessly (the session itself is hang-unsafe to instantiate).
final class ContentMaskGeometryTests: XCTestCase {
    /// Real HW geometry (2026-06-17): VS Code window [0,30 1440x900] + gear menu [48,733 269x283],
    /// DIALOG-EXPANDed to the union region [0,30 1440x986], captured @2× (2880x1972 px). The window
    /// becomes the full-width top block and the menu the overhang rect, both in capture pixels.
    func testConvertsGlobalRectsToCaptureLocalPixels() {
        let region = CGRect(x: 0, y: 30, width: 1440, height: 986)
        let content = [
            CGRect(x: 0, y: 30, width: 1440, height: 900), // window block
            CGRect(x: 48, y: 733, width: 269, height: 283), // gear menu (overhangs to y=1016)
        ]
        let rects = SlopDeskVideoHostSession.maskRects(
            contentRectsGlobal: content,
            region: region,
            captureScale: 2,
            pixelWidth: 2880,
            pixelHeight: 1972,
        )
        XCTAssertEqual(rects, [
            MaskRect(x: 0, y: 0, width: 2880, height: 1800),
            MaskRect(x: 96, y: 1406, width: 538, height: 566),
        ])
    }

    /// A rect entirely outside the captured region clamps to zero area → dropped (never a 0×0 rect).
    func testRectFullyOutsideRegionIsDropped() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let content = [CGRect(x: 500, y: 500, width: 50, height: 50)]
        let rects = SlopDeskVideoHostSession.maskRects(
            contentRectsGlobal: content,
            region: region,
            captureScale: 1,
            pixelWidth: 100,
            pixelHeight: 100,
        )
        XCTAssertTrue(rects.isEmpty)
    }

    /// A rect overhanging the region edge is CLAMPED to the frame (not dropped, not overflowing).
    func testRectClampedToFrameBounds() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let content = [CGRect(x: 80, y: 80, width: 60, height: 60)] // extends to 140,140 — past the frame
        let rects = SlopDeskVideoHostSession.maskRects(
            contentRectsGlobal: content,
            region: region,
            captureScale: 1,
            pixelWidth: 100,
            pixelHeight: 100,
        )
        XCTAssertEqual(rects, [MaskRect(x: 80, y: 80, width: 20, height: 20)])
    }
}
