#if os(macOS)
import CoreGraphics
import XCTest
@testable import AislopdeskVideoHost

/// PURE point↔pixel↔mm math for the HiDPI virtual display (feature #1). No CoreGraphics IPC, no
/// private API — safe headless. The live VD creation / AX move are HW-gated (window server + TCC)
/// and not unit-tested; this covers the arithmetic that decides the mode/descriptor/placement.
final class VirtualDisplayGeometryTests: XCTestCase {
    // MARK: VirtualDisplayGeometry

    // 2× HiDPI: a 1920×1080-POINT display is backed by 3840×2160 PIXELS.
    func testTwoXBackingPixels() {
        let g = VirtualDisplayGeometry(pointWidth: 1920, pointHeight: 1080, scale: 2)
        XCTAssertEqual(g.pixelWidth, 3840)
        XCTAssertEqual(g.pixelHeight, 2160)
        XCTAssertFalse(g.exceedsPixelLimit, "3840 < 7680 chip limit")
    }

    // 1× (scale 1): pixels == points (the fallback / non-HiDPI case).
    func testOneXBacking() {
        let g = VirtualDisplayGeometry(pointWidth: 1440, pointHeight: 900, scale: 1)
        XCTAssertEqual(g.pixelWidth, 1440)
        XCTAssertEqual(g.pixelHeight, 900)
    }

    // The chip horizontal pixel limit gates oversized framebuffers (default 7680, Studio Ultra).
    func testExceedsPixelLimit() {
        // 3840 points × 2 = 7680 px → exactly the limit, NOT exceeding.
        XCTAssertFalse(VirtualDisplayGeometry(pointWidth: 3840, pointHeight: 2160, scale: 2).exceedsPixelLimit)
        // 3841 points × 2 = 7682 px → over the limit.
        XCTAssertTrue(VirtualDisplayGeometry(pointWidth: 3841, pointHeight: 2160, scale: 2).exceedsPixelLimit)
        // Base-M chip limit 6144: 3072×2 = 6144 ok; 3200×2 = 6400 over.
        XCTAssertFalse(VirtualDisplayGeometry(pointWidth: 3072, pointHeight: 1920, scale: 2, maxHorizontalPixels: 6144)
            .exceedsPixelLimit)
        XCTAssertTrue(VirtualDisplayGeometry(pointWidth: 3200, pointHeight: 1800, scale: 2, maxHorizontalPixels: 6144)
            .exceedsPixelLimit)
    }

    // sizeInMillimeters derives from the PIXEL dims at the target PPI (so the reported density matches).
    func testSizeInMillimeters() {
        let g = VirtualDisplayGeometry(pointWidth: 1920, pointHeight: 1080, scale: 2)
        let mm = g.sizeInMillimeters(targetPPI: 163)
        // 3840 px / 163 PPI × 25.4 ≈ 598.5 mm ; 2160 / 163 × 25.4 ≈ 336.6 mm
        XCTAssertEqual(mm.width, 3840.0 / 163.0 * 25.4, accuracy: 0.01)
        XCTAssertEqual(mm.height, 2160.0 / 163.0 * 25.4, accuracy: 0.01)
        XCTAssertEqual(mm.width, 598.5, accuracy: 1.0)
    }

    // Degenerate inputs are clamped to ≥1 (never zero/negative → never a div-by-zero or bad descriptor).
    func testDegenerateInputsClamped() {
        let g = VirtualDisplayGeometry(pointWidth: 0, pointHeight: -5, scale: 0)
        XCTAssertEqual(g.pointWidth, 1)
        XCTAssertEqual(g.pointHeight, 1)
        XCTAssertEqual(g.scale, 1)
        XCTAssertEqual(g.pixelWidth, 1)
    }

    // MARK: WindowPlacementMath

    // A window smaller than the display: no resize, placed at the display origin.
    func testPlacementFitsNoResize() {
        let p = WindowPlacementMath.placement(
            windowSize: CGSize(width: 1200, height: 800),
            displayBounds: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
        )
        XCTAssertEqual(p.origin, CGPoint(x: 3840, y: 0))
        XCTAssertEqual(p.size, CGSize(width: 1200, height: 800))
        XCTAssertFalse(p.needsResize)
    }

    // A window larger than the display on one axis: clamp that axis, flag resize.
    func testPlacementClampsOversizedWidth() {
        let p = WindowPlacementMath.placement(
            windowSize: CGSize(width: 2400, height: 900),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        )
        XCTAssertEqual(p.size, CGSize(width: 1920, height: 900))
        XCTAssertTrue(p.needsResize)
    }

    // Larger on both axes: clamp both.
    func testPlacementClampsBothAxes() {
        let p = WindowPlacementMath.placement(
            windowSize: CGSize(width: 4000, height: 3000),
            displayBounds: CGRect(x: 100, y: 50, width: 1920, height: 1080),
        )
        XCTAssertEqual(p.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(p.size, CGSize(width: 1920, height: 1080))
        XCTAssertTrue(p.needsResize)
    }

    // Exactly display-sized: no resize (½-pt tolerance guards float equality).
    func testPlacementExactSizeNoResize() {
        let p = WindowPlacementMath.placement(
            windowSize: CGSize(width: 1920, height: 1080),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        )
        XCTAssertFalse(p.needsResize)
        XCTAssertEqual(p.size, CGSize(width: 1920, height: 1080))
    }
}
#endif
