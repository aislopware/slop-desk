// SimulatorScreenLayoutTests — the two things about this panel's geometry that are not shared.
//
// The fit, the hit test, the scroll scale, the pinch and the edge BANDS are `DevicePanelGeometry`'s
// and are pinned by `DevicePanelGeometryTests` (and, exhaustively, by `rust/slopdesk-devicepanel`).
// What is only the simulator's is ORIENTATION — its framebuffer never turns, so a delta measured in
// screen space has to be un-rotated — and the wire's SPELLING of an edge, which the host reads as a
// lowercase name rather than a kind.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorScreenLayoutTests: XCTestCase {
    private let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)

    func testTheSurfaceSentUpstreamIsTheFittedRectsOwnSize() {
        // Not the panel's, and not the device's: the host scales from the space the coordinates were
        // actually measured in, which is the fitted rect. (The Android lane cannot do this — see
        // `AndroidScreenLayoutTests`.)
        let surface = SimulatorScreenLayout.surface(fitted: CGRect(x: 10, y: 20, width: 200, height: 400))
        XCTAssertEqual(surface.width, 200)
        XCTAssertEqual(surface.height, 400)
    }

    func testATurnedDeviceScrollsTheWayTheUserIsLooking() {
        // The one thing that is NOT pass-through. A scroll delta arrives in SCREEN space — AppKit
        // knows nothing about the `rotationEffect` the bezel is drawn under — while the framebuffer
        // never turns. Before this the panel scrolled sideways on a device held on its side.
        let down = CGSize(width: 0, height: 10)
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(delta: down, isPrecise: true, orientation: .landscapeLeft),
            CGSize(width: 10, height: 0),
        )
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(delta: down, isPrecise: true, orientation: .landscapeRight),
            CGSize(width: -10, height: 0),
        )
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: down, isPrecise: true, orientation: .portraitUpsideDown,
            ),
            CGSize(width: 0, height: -10),
        )
        // Upright, the shared scale is all that is left — a wheel notch still becomes finger travel.
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: CGSize(width: 0, height: 3), isPrecise: false, orientation: .portrait,
            ),
            CGSize(width: 0, height: 3 * SimulatorScreenLayout.pointsPerLine),
        )
    }

    func testAnEdgeIsSpelledTheWayTheHostReadsIt() {
        // The hint is what lets a drag reach the home indicator and the pull-down shades at all —
        // without it those gestures exist only as toolbar buttons, and the server matches on the name.
        XCTAssertEqual(
            SimulatorScreenLayout.edge(at: CGPoint(x: 100, y: 395), fitted: fitted, orientation: .portrait),
            "bottom",
        )
        XCTAssertEqual(
            SimulatorScreenLayout.edge(at: CGPoint(x: 100, y: 4), fitted: fitted, orientation: .portrait),
            "top",
        )
        XCTAssertNil(
            SimulatorScreenLayout.edge(at: CGPoint(x: 100, y: 200), fitted: fitted, orientation: .portrait),
        )
    }

    func testOnlyUpsideDownMovesTheBandsOntoTheOtherAxis() {
        // The landscape cases deliberately do NOT: the framebuffer stays portrait whichever way the
        // device is held, so the home indicator stays on the same framebuffer edge.
        XCTAssertEqual(
            SimulatorScreenLayout.edge(
                at: CGPoint(x: 4, y: 200), fitted: fitted, orientation: .portraitUpsideDown,
            ),
            "bottom",
        )
        XCTAssertEqual(
            SimulatorScreenLayout.edge(
                at: CGPoint(x: 100, y: 395), fitted: fitted, orientation: .landscapeLeft,
            ),
            "bottom",
        )
        XCTAssertNil(
            SimulatorScreenLayout.edge(
                at: CGPoint(x: 100, y: 395), fitted: fitted, orientation: .portraitUpsideDown,
            ),
        )
    }
}
#endif
