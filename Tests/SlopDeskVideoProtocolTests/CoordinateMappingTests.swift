import XCTest
@testable import SlopDeskVideoProtocol

/// The one coordinate conversion the host performs (doc 18 §B SOLVED, doc 05 §2): normalised →
/// host-window point in CG top-left space, with no Y flip on the click.
///
/// The arithmetic itself lives in `rust/slopdesk-video` and is pinned bit-for-bit by the
/// `coordWindowPoint` golden vector; what these cover is the mapping arriving through the door
/// intact — that the axes are not swapped, that the origin is added and not subtracted, and that a
/// display left of primary (negative CG x) is just a point on the same continuous plane.
final class CoordinateMappingTests: XCTestCase {
    func testWindowPointCenterOfWindow() {
        let bounds = VideoRect(x: 100, y: 200, width: 800, height: 600)
        let center = CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0.5, y: 0.5), windowBounds: bounds)
        XCTAssertEqual(center, VideoPoint(x: 500, y: 500))
    }

    func testWindowPointCornersMapToWindowEdgesNoYFlip() {
        let bounds = VideoRect(x: 100, y: 200, width: 800, height: 600)
        // (0,0) = top-left of the window (CG top-left space — NOT flipped, doc 05 §2).
        XCTAssertEqual(
            CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0, y: 0), windowBounds: bounds),
            VideoPoint(x: 100, y: 200),
        )
        // (1,1) = bottom-right.
        XCTAssertEqual(
            CoordinateMapping.windowPoint(normalized: VideoPoint(x: 1, y: 1), windowBounds: bounds),
            VideoPoint(x: 900, y: 800),
        )
    }

    func testWindowPointAsymmetricNormalizedDoesNotSwapAxes() {
        // x and y take DIFFERENT fractions of DIFFERENT extents, so a transposed pair would show.
        let bounds = VideoRect(x: 100, y: 200, width: 800, height: 600)
        let pt = CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0.25, y: 0.75), windowBounds: bounds)
        XCTAssertEqual(pt, VideoPoint(x: 300, y: 650))
    }

    func testWindowPointWindowAtNegativeOriginMultiMonitorLeft() {
        // A window on a display to the LEFT of primary has a negative x origin in CG
        // space; the continuous plane handles it (doc 05 §2 multi-monitor).
        let bounds = VideoRect(x: -1920, y: 0, width: 1920, height: 1080)
        let pt = CoordinateMapping.windowPoint(normalized: VideoPoint(x: 0.5, y: 0.5), windowBounds: bounds)
        XCTAssertEqual(pt, VideoPoint(x: -960, y: 540))
    }
}
