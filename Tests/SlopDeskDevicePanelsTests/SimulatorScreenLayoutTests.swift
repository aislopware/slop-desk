// SimulatorScreenLayoutTests — the geometry between a click in the panel and a tap on the device.
// Worth pinning precisely: this is the code that goes wrong in a way nobody notices until a tap
// lands two rows off.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskDevicePanels

final class SimulatorScreenLayoutTests: XCTestCase {
    /// The real ratio: iPhone 17 Pro at 1206×2622, as the format description reports it.
    private let device = CGSize(width: 1206, height: 2622)

    func testATallDeviceInASidebarIsWIDTHLimitedAndCentred() {
        // The ordinary case, and the counter-intuitive one: the device is tall, but a 320×800 panel
        // is PROPORTIONALLY taller still (0.40 against the device's 0.46), so the fit is bounded by
        // width and the bars land above and below — not either side.
        let fitted = SimulatorScreenLayout.fittedRect(content: device, in: CGSize(width: 320, height: 800))
        XCTAssertEqual(fitted.width, 320)
        XCTAssertEqual(fitted.height, (320 * 2622 / 1206).rounded())
        XCTAssertEqual(fitted.minX, 0)
        XCTAssertEqual(fitted.minY, ((800 - fitted.height) / 2).rounded())
    }

    func testAShortPanelFlipsTheLimitToHeight() {
        // Collapse the panel vertically and the other branch takes over — bars either side.
        let fitted = SimulatorScreenLayout.fittedRect(content: device, in: CGSize(width: 320, height: 400))
        XCTAssertEqual(fitted.height, 400)
        XCTAssertEqual(fitted.width, (400 * 1206 / 2622).rounded())
        XCTAssertEqual(fitted.minY, 0)
        XCTAssertEqual(fitted.minX, ((320 - fitted.width) / 2).rounded())
    }

    func testAWideBoundsIsStillFitRatherThanFilled() {
        // Aspect-FIT, not fill: cropping a phone screen hides the status bar or the home indicator,
        // which are exactly what someone mirroring a device is watching.
        let fitted = SimulatorScreenLayout.fittedRect(content: device, in: CGSize(width: 2000, height: 400))
        XCTAssertEqual(fitted.height, 400)
        XCTAssertLessThan(fitted.width, 2000)
    }

    func testADegenerateSizeDrawsNothingRatherThanDividingByZero() {
        // The state before the first frame, when the content size is still unknown.
        XCTAssertEqual(SimulatorScreenLayout.fittedRect(content: .zero, in: CGSize(width: 10, height: 10)), .zero)
        XCTAssertEqual(SimulatorScreenLayout.fittedRect(content: device, in: .zero), .zero)
    }

    // MARK: Hit testing

    func testAPointInsideTheFrameBecomesAPointInItsOwnSpace() {
        let fitted = CGRect(x: 100, y: 20, width: 200, height: 400)
        XCTAssertEqual(
            SimulatorScreenLayout.devicePoint(from: CGPoint(x: 150, y: 60), fitted: fitted),
            CGPoint(x: 50, y: 40),
        )
    }

    func testAClickOnTheBarsBesideTheFrameIsNotATap() {
        // Clamping instead would make the bezel a permanently-armed strip that taps the outermost
        // row of pixels.
        let fitted = CGRect(x: 100, y: 20, width: 200, height: 400)
        XCTAssertNil(SimulatorScreenLayout.devicePoint(from: CGPoint(x: 40, y: 60), fitted: fitted))
        XCTAssertNil(SimulatorScreenLayout.devicePoint(from: CGPoint(x: 150, y: 500), fitted: fitted))
    }

    func testTheSurfaceSentUpstreamIsTheFittedRectsOwnSize() {
        // Not the panel's, and not the device's: the host scales from the space the coordinates were
        // actually measured in, which is the fitted rect.
        let surface = SimulatorScreenLayout.surface(fitted: CGRect(x: 10, y: 20, width: 200, height: 400))
        XCTAssertEqual(surface.width, 200)
        XCTAssertEqual(surface.height, 400)
    }

    // MARK: Scroll

    func testTheDeltaSSignIsPassedThroughRatherThanReinterpreted() {
        // AppKit has already applied the user's scroll-direction preference: a positive delta always
        // means "toward the top of the document", which on a touch surface is a finger travelling DOWN
        // the screen — +y in this view's flipped space. Measured 2026-08-04: reinterpreting the sign
        // from `isDirectionInvertedFromDevice` double-applies the preference and the device's list
        // moved opposite to a native scroll view given the same gesture.
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: CGSize(width: 0, height: -3), isPrecise: true, orientation: .portrait,
            ).height, -3,
        )
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: CGSize(width: 4, height: 0), isPrecise: true, orientation: .portrait,
            ).width, 4,
        )
    }

    func testAWheelNotchIsScaledFromLinesToPointsButATrackpadIsNot() {
        // AppKit reports a trackpad's delta in POINTS and a wheel's in LINES. Measured 2026-08-04:
        // taking a line as a point moves the finger one or two pixels, under iOS's own pan slop, so
        // the device ignores every tick and the panel looks like it eats scrolls.
        let wheel = SimulatorScreenLayout.scrollVector(
            delta: CGSize(width: 0, height: 3), isPrecise: false, orientation: .portrait,
        )
        XCTAssertEqual(wheel.height, 3 * SimulatorScreenLayout.pointsPerLine)
        let trackpad = SimulatorScreenLayout.scrollVector(
            delta: CGSize(width: 0, height: 3), isPrecise: true, orientation: .portrait,
        )
        XCTAssertEqual(trackpad.height, 3)
    }

    func testATurnedDeviceScrollsTheWayTheUserIsLooking() {
        // The one thing that is NOT pass-through. A scroll delta arrives in SCREEN space — AppKit
        // knows nothing about the `rotationEffect` the bezel is drawn under — while the framebuffer
        // never turns. Before this the panel scrolled sideways on a device held on its side.
        let down = CGSize(width: 0, height: 10)
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: down, isPrecise: true, orientation: .landscapeLeft,
            ),
            CGSize(width: 10, height: 0),
        )
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: down, isPrecise: true, orientation: .landscapeRight,
            ),
            CGSize(width: -10, height: 0),
        )
        XCTAssertEqual(
            SimulatorScreenLayout.scrollVector(
                delta: down, isPrecise: true, orientation: .portraitUpsideDown,
            ),
            CGSize(width: 0, height: -10),
        )
    }

    func testAQuarterTurnIsUndoneRatherThanApproximated() {
        // Spelled out per angle rather than run through trigonometry, so this pins the four cases
        // exactly — a `sin(90°)` that comes back as 0.9999999 would leave a scroll drifting sideways.
        let vector = CGSize(width: 3, height: 7)
        XCTAssertEqual(SimulatorScreenLayout.unrotated(vector, by: 0), vector)
        XCTAssertEqual(
            SimulatorScreenLayout.unrotated(vector, by: 180), CGSize(width: -3, height: -7),
        )
        XCTAssertEqual(
            SimulatorScreenLayout.unrotated(SimulatorScreenLayout.unrotated(vector, by: 90), by: -90),
            vector,
        )
    }

    // MARK: Edges

    func testAContactInTheBandsCarriesTheEdgeTheHostNeeds() {
        // The hint is what lets a drag reach the home indicator and the pull-down shades at all —
        // without it those gestures exist only as toolbar buttons.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        XCTAssertEqual(
            SimulatorScreenLayout.edge(
                at: CGPoint(x: 100, y: 395), fitted: fitted, orientation: .portrait,
            ), "bottom",
        )
        XCTAssertEqual(
            SimulatorScreenLayout.edge(
                at: CGPoint(x: 100, y: 4), fitted: fitted, orientation: .portrait,
            ), "top",
        )
        XCTAssertNil(SimulatorScreenLayout.edge(
            at: CGPoint(x: 100, y: 200), fitted: fitted, orientation: .portrait,
        ))
    }

    func testUpsideDownMovesTheBandsOntoTheOtherAxis() {
        // The one orientation that is not a rotation of the others: the physical home-indicator edge
        // lands on visual LEFT, so the bands swap axes rather than ends.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        XCTAssertEqual(
            SimulatorScreenLayout.edge(
                at: CGPoint(x: 4, y: 200), fitted: fitted, orientation: .portraitUpsideDown,
            ), "bottom",
        )
        XCTAssertNil(SimulatorScreenLayout.edge(
            at: CGPoint(x: 100, y: 395), fitted: fitted, orientation: .portraitUpsideDown,
        ))
    }

    // MARK: Pinch

    func testThePinchPairStraddlesItsCentreAndStaysOnScreen() {
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        let (first, second) = SimulatorScreenLayout.pinchFingers(
            centre: CGPoint(x: 100, y: 200), spread: 100, fitted: fitted,
        )
        XCTAssertEqual((first.x + second.x) / 2, 100, accuracy: 0.001)
        XCTAssertEqual((first.y + second.y) / 2, 200, accuracy: 0.001)
        XCTAssertGreaterThan(first.x, second.x)

        // A spread wider than the frame is clamped: a contact past the edge is a system gesture on
        // iOS rather than a zoom.
        let (wide, _) = SimulatorScreenLayout.pinchFingers(
            centre: CGPoint(x: 100, y: 200), spread: 4000, fitted: fitted,
        )
        XCTAssertLessThanOrEqual(wide.x, fitted.width)
        XCTAssertLessThanOrEqual(wide.y, fitted.height)
    }
}
#endif
