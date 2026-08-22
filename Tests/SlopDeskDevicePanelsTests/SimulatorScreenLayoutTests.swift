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

    /// The boundary this lane used to get wrong, pinned as a NUMBER rather than as "it asks the
    /// door".
    ///
    /// Until 2026-08-22 the simulator surface clamped a runaway drag to the fitted rect's SIZE while
    /// the shared rule clamps to the last addressable point inside it, so a drag off the right edge
    /// of a 200-point frame reported `x = 200` into a surface whose columns are `0..<200`. Nothing
    /// could fail: both numbers are plausible, both round-trip, and the host scales whatever it is
    /// sent — the only trace is a swipe that lands one row off at the very edge. The Android lane
    /// answered 199 for the same drag, from the same door, the whole time.
    ///
    /// An inset rect on purpose: an origin at zero makes the subtraction inert, which is exactly the
    /// case a wrong implementation still passes.
    func testADragOffTheEdgeLandsOnTheLastAddressablePointNotOnTheSize() {
        let inset = CGRect(x: 50, y: 20, width: 200, height: 400)
        XCTAssertEqual(
            SimulatorScreenLayout.clampedDevicePoint(from: CGPoint(x: 9999, y: 9999), fitted: inset),
            CGPoint(x: 199, y: 399),
            "the last addressable point, never the size — 200 is off the end of `0..<200`",
        )
        XCTAssertEqual(
            SimulatorScreenLayout.clampedDevicePoint(from: CGPoint(x: 250, y: 420), fitted: inset),
            CGPoint(x: 199, y: 399),
            "the far edge itself is already outside the frame, the way `devicePoint` reads it",
        )
        XCTAssertEqual(
            SimulatorScreenLayout.clampedDevicePoint(from: CGPoint(x: -100, y: 60), fitted: inset),
            CGPoint(x: 0, y: 40),
            "the near edges are inclusive and the origin is subtracted, not ignored",
        )
        XCTAssertEqual(
            SimulatorScreenLayout.clampedDevicePoint(from: CGPoint(x: 9, y: 9), fitted: .zero),
            .zero,
            "a frame with no area has no point to clamp into",
        )
    }
}
#endif
