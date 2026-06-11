import XCTest
@testable import AislopdeskVideoProtocol

/// Coordinate-mapping math (doc 18 §B SOLVED, doc 05 §2): normalised→host-window
/// point (no Y flip for the click), the multi-monitor CG→Cocoa flip for screen pick,
/// and Retina backingScaleFactor handling. Exhaustive single + multi-monitor + Retina.
final class CoordinateMappingTests: XCTestCase {

    // MARK: normalised → host-window point (CG top-left, no Y flip)

    func testWindowPointCenterOfWindow() {
        let bounds = VideoRect(x: 100, y: 200, width: 800, height: 600)
        let center = CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0.5, y: 0.5), windowBounds: bounds)
        XCTAssertEqual(center, VideoPoint(x: 500, y: 500))
    }

    func testWindowPointCornersMapToWindowEdgesNoYFlip() {
        let bounds = VideoRect(x: 100, y: 200, width: 800, height: 600)
        // (0,0) = top-left of the window (CG top-left space — NOT flipped, doc 05 §2).
        XCTAssertEqual(CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0, y: 0), windowBounds: bounds), VideoPoint(x: 100, y: 200))
        // (1,1) = bottom-right.
        XCTAssertEqual(CoordinateMapping.windowPoint(normalized: VideoPoint(x: 1, y: 1), windowBounds: bounds), VideoPoint(x: 900, y: 800))
    }

    func testWindowPointWindowAtNegativeOriginMultiMonitorLeft() {
        // A window on a display to the LEFT of primary has a negative x origin in CG
        // space; the continuous plane handles it (doc 05 §2 multi-monitor).
        let bounds = VideoRect(x: -1920, y: 0, width: 1920, height: 1080)
        let pt = CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0.5, y: 0.5), windowBounds: bounds)
        XCTAssertEqual(pt, VideoPoint(x: -960, y: 540))
    }

    // MARK: CG → Cocoa flip

    func testCGRectToCocoaFlipOnPrimary() {
        // Primary is 1080 tall. A window at CG top y=0, height 200 sits at the TOP of
        // the primary → its Cocoa bottom-left y = 1080 - 0 - 200 = 880.
        let cg = VideoRect(x: 0, y: 0, width: 400, height: 200)
        let cocoa = CoordinateMapping.cgRectToCocoa(cg, primaryHeight: 1080)
        XCTAssertEqual(cocoa, VideoRect(x: 0, y: 880, width: 400, height: 200))
    }

    func testCGRectToCocoaFlipBottomOfPrimary() {
        // A window flush to the bottom of the primary: CG y = 1080 - 200 = 880,
        // height 200 → Cocoa y = 1080 - 880 - 200 = 0.
        let cg = VideoRect(x: 0, y: 880, width: 400, height: 200)
        let cocoa = CoordinateMapping.cgRectToCocoa(cg, primaryHeight: 1080)
        XCTAssertEqual(cocoa.origin.y, 0)
    }

    // MARK: multi-monitor screen pick + Retina backing scale

    /// Two screens: primary 1080p @1x at Cocoa origin (0,0); a Retina @2x display
    /// stacked ABOVE it. A window on the top (Retina) display must resolve to scale
    /// 2.0 — the bug doc 18 §B fixes (without the Cocoa flip it would pick primary).
    func testMultiMonitorPicksRetinaScreenAfterFlip() {
        let primaryHeight = 1080.0
        // Cocoa space: primary frame (0,0,1920,1080); secondary Retina ABOVE it
        // occupies Cocoa y in [1080, 2520) (height 1440).
        let primary = ScreenInfo(cocoaFrame: VideoRect(x: 0, y: 0, width: 1920, height: 1080), backingScaleFactor: 1.0)
        let retina = ScreenInfo(cocoaFrame: VideoRect(x: 0, y: 1080, width: 2560, height: 1440), backingScaleFactor: 2.0)

        // A window fully on the Retina display: in CG top-left space its top is above
        // the primary. Primary top is CG y=0; the secondary sits ABOVE, so CG y is
        // negative. Place the window at CG y = -1000, height 800 → CG-bottom = -200,
        // entirely above the primary.
        let windowCG = VideoRect(x: 100, y: -1000, width: 1280, height: 800)
        let scale = CoordinateMapping.backingScaleFactor(
            forWindowBoundsCG: windowCG, screens: [primary, retina], primaryHeight: primaryHeight
        )
        XCTAssertEqual(scale, 2.0, "window on the secondary Retina display resolves to 2x")
    }

    func testSingleMonitorPicksPrimaryScale() {
        let primary = ScreenInfo(cocoaFrame: VideoRect(x: 0, y: 0, width: 1440, height: 900), backingScaleFactor: 2.0)
        let windowCG = VideoRect(x: 100, y: 100, width: 600, height: 400) // inside primary
        let scale = CoordinateMapping.backingScaleFactor(
            forWindowBoundsCG: windowCG, screens: [primary], primaryHeight: 900
        )
        XCTAssertEqual(scale, 2.0)
    }

    func testWindowOnNoScreenReturnsNil() {
        let primary = ScreenInfo(cocoaFrame: VideoRect(x: 0, y: 0, width: 1920, height: 1080), backingScaleFactor: 1.0)
        // Window far off to the right, no overlap.
        let windowCG = VideoRect(x: 10_000, y: 0, width: 100, height: 100)
        XCTAssertNil(CoordinateMapping.backingScaleFactor(forWindowBoundsCG: windowCG, screens: [primary], primaryHeight: 1080))
    }

    func testLargestOverlapWins() {
        let a = ScreenInfo(cocoaFrame: VideoRect(x: 0, y: 0, width: 1000, height: 1000), backingScaleFactor: 1.0)
        let b = ScreenInfo(cocoaFrame: VideoRect(x: 1000, y: 0, width: 1000, height: 1000), backingScaleFactor: 2.0)
        // Window straddling the seam but mostly on screen B (Cocoa space).
        // CG window: most area to the right. primaryHeight 1000, height 100, CG y=0 →
        // Cocoa y = 1000-0-100 = 900, within both screens' y range.
        let windowCG = VideoRect(x: 900, y: 0, width: 600, height: 100) // x in [900,1500): 100 on A, 500 on B
        let scale = CoordinateMapping.backingScaleFactor(forWindowBoundsCG: windowCG, screens: [a, b], primaryHeight: 1000)
        XCTAssertEqual(scale, 2.0, "the screen with the larger overlap (B) is chosen")
    }

    // MARK: Retina pixel path (the rare client-sends-pixels case — no double-scale)

    func testPixelToWindowPointDividesByScaleOnce() {
        // If the client ever sends raw ScreenCaptureKit PIXELS, divide by scale ONCE
        // to get points (doc 05 §2: don't double-apply scale).
        let bounds = VideoRect(x: 100, y: 200, width: 800, height: 600)
        // A pixel at (400, 300) on a 2x backing = (200, 150) points + window origin.
        let pt = CoordinateMapping.windowPoint(pixel: VideoPoint(x: 400, y: 300), windowBoundsCG: bounds, backingScaleFactor: 2.0)
        XCTAssertEqual(pt, VideoPoint(x: 100 + 200, y: 200 + 150))
    }
}
