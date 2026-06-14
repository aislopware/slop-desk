#if os(macOS)
import CoreGraphics
import XCTest
@testable import AislopdeskVideoHost

/// PURE point↔pixel↔mm math for the HiDPI virtual display (feature #1). No CoreGraphics IPC, no
/// private API — safe headless. The live VD creation / AX move are HW-gated (window server + TCC)
/// and not unit-tested; this covers the arithmetic that decides the mode/descriptor/placement.
final class VirtualDisplayGeometryTests: XCTestCase {
    // MARK: virtual display geometry (Rust core via FFI)

    // 2× HiDPI: a 1920×1080-POINT display is backed by 3840×2160 PIXELS.
    func testTwoXBackingPixels() {
        let g = RustVideoHostFFI.vdGeometry(pointWidth: 1920, pointHeight: 1080, scale: 2)
        XCTAssertEqual(g.pixelWidth, 3840)
        XCTAssertEqual(g.pixelHeight, 2160)
        XCTAssertFalse(g.exceedsPixelLimit, "3840 < 7680 chip limit")
    }

    // 1× (scale 1): pixels == points (the fallback / non-HiDPI case).
    func testOneXBacking() {
        let g = RustVideoHostFFI.vdGeometry(pointWidth: 1440, pointHeight: 900, scale: 1)
        XCTAssertEqual(g.pixelWidth, 1440)
        XCTAssertEqual(g.pixelHeight, 900)
    }

    // The chip horizontal pixel limit gates oversized framebuffers (default 7680, Studio Ultra).
    func testExceedsPixelLimit() {
        // 3840 points × 2 = 7680 px → exactly the limit, NOT exceeding.
        XCTAssertFalse(RustVideoHostFFI.vdGeometry(pointWidth: 3840, pointHeight: 2160, scale: 2).exceedsPixelLimit)
        // 3841 points × 2 = 7682 px → over the limit.
        XCTAssertTrue(RustVideoHostFFI.vdGeometry(pointWidth: 3841, pointHeight: 2160, scale: 2).exceedsPixelLimit)
        // Base-M chip limit 6144: 3072×2 = 6144 ok; 3200×2 = 6400 over.
        XCTAssertFalse(RustVideoHostFFI.vdGeometry(
            pointWidth: 3072,
            pointHeight: 1920,
            scale: 2,
            maxHorizontalPixels: 6144,
        )
        .exceedsPixelLimit)
        XCTAssertTrue(RustVideoHostFFI.vdGeometry(
            pointWidth: 3200,
            pointHeight: 1800,
            scale: 2,
            maxHorizontalPixels: 6144,
        )
        .exceedsPixelLimit)
    }

    // sizeInMillimeters derives from the PIXEL dims at the target PPI (so the reported density matches).
    func testSizeInMillimeters() {
        let g = RustVideoHostFFI.vdGeometry(pointWidth: 1920, pointHeight: 1080, scale: 2)
        let mm = g.sizeInMillimeters(targetPPI: 163)
        // 3840 px / 163 PPI × 25.4 ≈ 598.5 mm ; 2160 / 163 × 25.4 ≈ 336.6 mm
        XCTAssertEqual(mm.width, 3840.0 / 163.0 * 25.4, accuracy: 0.01)
        XCTAssertEqual(mm.height, 2160.0 / 163.0 * 25.4, accuracy: 0.01)
        XCTAssertEqual(mm.width, 598.5, accuracy: 1.0)
    }

    // Degenerate inputs are clamped to ≥1 (never zero/negative → never a div-by-zero or bad descriptor).
    func testDegenerateInputsClamped() {
        let g = RustVideoHostFFI.vdGeometry(pointWidth: 0, pointHeight: -5, scale: 0)
        XCTAssertEqual(g.pointWidth, 1)
        XCTAssertEqual(g.pointHeight, 1)
        XCTAssertEqual(g.scale, 1)
        XCTAssertEqual(g.pixelWidth, 1)
    }

    // MARK: window placement (Rust core via FFI)

    // A window smaller than the display: no resize, placed at the display origin.
    func testPlacementFitsNoResize() {
        let p = RustVideoHostFFI.windowPlacement(
            windowSize: CGSize(width: 1200, height: 800),
            displayBounds: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
        )
        XCTAssertEqual(p.origin, CGPoint(x: 3840, y: 0))
        XCTAssertEqual(p.size, CGSize(width: 1200, height: 800))
        XCTAssertFalse(p.needsResize)
    }

    // A window larger than the display on one axis: clamp that axis, flag resize.
    func testPlacementClampsOversizedWidth() {
        let p = RustVideoHostFFI.windowPlacement(
            windowSize: CGSize(width: 2400, height: 900),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        )
        XCTAssertEqual(p.size, CGSize(width: 1920, height: 900))
        XCTAssertTrue(p.needsResize)
    }

    // Larger on both axes: clamp both.
    func testPlacementClampsBothAxes() {
        let p = RustVideoHostFFI.windowPlacement(
            windowSize: CGSize(width: 4000, height: 3000),
            displayBounds: CGRect(x: 100, y: 50, width: 1920, height: 1080),
        )
        XCTAssertEqual(p.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(p.size, CGSize(width: 1920, height: 1080))
        XCTAssertTrue(p.needsResize)
    }

    // Exactly display-sized: no resize (½-pt tolerance guards float equality).
    func testPlacementExactSizeNoResize() {
        let p = RustVideoHostFFI.windowPlacement(
            windowSize: CGSize(width: 1920, height: 1080),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        )
        XCTAssertFalse(p.needsResize)
        XCTAssertEqual(p.size, CGSize(width: 1920, height: 1080))
    }

    // MARK: window fits (Rust core via FFI)

    // A window that fits (≤ bounds, with ½-pt tolerance) passes; one that overhangs either axis fails.
    func testFitsWithinBounds() {
        let vd = CGRect(x: 3840, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(RustVideoHostFFI.windowFits(CGSize(width: 1920, height: 1080), within: vd)) // exact
        XCTAssertTrue(RustVideoHostFFI.windowFits(CGSize(width: 1200, height: 800), within: vd)) // smaller
        XCTAssertTrue(RustVideoHostFFI.windowFits(CGSize(width: 1920.4, height: 1080), within: vd)) // within tol
        XCTAssertFalse(RustVideoHostFFI.windowFits(CGSize(width: 1921, height: 1080), within: vd)) // width over
        XCTAssertFalse(RustVideoHostFFI.windowFits(CGSize(width: 1920, height: 1200), within: vd)) // height over
    }

    // MARK: RustVideoHostFFI.vdOriginToRight

    // Single display: the VD lands flush to the right of it (the historical (mainWidth, 0)).
    func testOriginToRightSingleDisplay() {
        let o = RustVideoHostFFI.vdOriginToRight(of: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(o, CGPoint(x: 1920, y: 0))
    }

    // Multi-display: the VD lands past the RIGHTMOST edge (never overlapping a secondary monitor).
    func testOriginToRightMultiDisplay() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080), // main
            CGRect(x: 1920, y: 0, width: 2560, height: 1440), // secondary to the right
        ]
        // rightmost maxX = 1920 + 2560 = 4480
        XCTAssertEqual(RustVideoHostFFI.vdOriginToRight(of: displays), CGPoint(x: 4480, y: 0))
    }

    // No displays (degenerate): origin (0,0) — never negative/NaN.
    func testOriginToRightEmpty() {
        XCTAssertEqual(RustVideoHostFFI.vdOriginToRight(of: []), .zero)
    }

    // A display LEFT of the origin (negative X) still resolves the rightmost edge correctly.
    func testOriginToRightWithNegativeDisplay() {
        let displays = [
            CGRect(x: -1440, y: 0, width: 1440, height: 900), // to the LEFT of main
            CGRect(x: 0, y: 0, width: 1920, height: 1080), // main
        ]
        XCTAssertEqual(RustVideoHostFFI.vdOriginToRight(of: displays), CGPoint(x: 1920, y: 0))
    }

    // The rightmost display is NOT the last array element → proves we take max(maxX), not last.maxX.
    func testOriginToRightRightmostNotLast() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080), // main
            CGRect(x: 5000, y: 0, width: 1000, height: 1080), // rightmost (maxX 6000), but not last
            CGRect(x: 1920, y: 0, width: 800, height: 1080), // last element (maxX 2720)
        ]
        XCTAssertEqual(RustVideoHostFFI.vdOriginToRight(of: displays), CGPoint(x: 6000, y: 0))
    }

    // MARK: RustVideoHostFFI.vdChipPixelLimit

    // Base M-series (all generations) = 6144; Pro/Max/Ultra = 7680; Intel/unknown → permissive 7680.
    func testChipPixelLimit() {
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M1"), 6144)
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M2"), 6144)
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M3"), 6144) // base M3 is 6144, NOT 7680
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M4"), 6144) // base M4 is 6144
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M2 Pro"), 7680)
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M3 Max"), 7680)
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Apple M2 Ultra"), 7680)
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: "Intel(R) Core(TM) i9"), 7680)
        XCTAssertEqual(RustVideoHostFFI.vdChipPixelLimit(cpuBrand: ""), 7680)
    }

    // MARK: RustVideoHostFFI.vdRefreshRates

    // At 60fps: just the 60/30 baseline (descending, deduped).
    func testRefreshRatesDefault() {
        XCTAssertEqual(RustVideoHostFFI.vdRefreshRates(fps: 60), [60, 30])
        XCTAssertEqual(RustVideoHostFFI.vdRefreshRates(fps: 30), [60, 30])
    }

    // Above 60fps: add the fps mode so a VD-parked window can be composited that fast.
    func testRefreshRatesHighFPS() {
        XCTAssertEqual(RustVideoHostFFI.vdRefreshRates(fps: 90), [90, 60, 30])
        XCTAssertEqual(RustVideoHostFFI.vdRefreshRates(fps: 120), [120, 60, 30])
    }
}
#endif
