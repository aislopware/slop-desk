#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskVideoHost

/// Where a remoted window goes when it is parked, and whether it fits once it is there — the Swift
/// face of `rust/slopdesk-video`'s `window_placement`, exercised through ``WindowPlacementMath``.
/// No CoreGraphics IPC, no private API, safe headless; the AX move itself is HW-gated.
///
/// The virtual display's own arithmetic used to be tested here too. It is
/// `slopdesk_video::virtual_display`'s now, tested there and replayed against the pinned corpus by
/// ``VirtualDisplayGoldenVectorTests`` — a second set of assertions on this side would be a
/// cross-language mirror of the one implementation, which is exactly what the port removed.
final class WindowPlacementMathTests: XCTestCase {
    // MARK: window placement (Rust core via FFI)

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

    // MARK: window fits (Rust core via FFI)

    // A window that fits (≤ bounds, with ½-pt tolerance) passes; one that overhangs either axis fails.
    func testFitsWithinBounds() {
        let vd = CGRect(x: 3840, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(WindowPlacementMath.fits(CGSize(width: 1920, height: 1080), within: vd)) // exact
        XCTAssertTrue(WindowPlacementMath.fits(CGSize(width: 1200, height: 800), within: vd)) // smaller
        XCTAssertTrue(WindowPlacementMath.fits(CGSize(width: 1920.4, height: 1080), within: vd)) // within tol
        XCTAssertFalse(WindowPlacementMath.fits(CGSize(width: 1921, height: 1080), within: vd)) // width over
        XCTAssertFalse(WindowPlacementMath.fits(CGSize(width: 1920, height: 1200), within: vd)) // height over
    }
}
#endif
