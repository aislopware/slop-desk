// SimulatorScreenLayoutTests — the geometry between a click in the panel and a tap on the device.
// Worth pinning precisely: this is the code that goes wrong in a way nobody notices until a tap
// lands two rows off.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskClientUI

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

    func testTheSwipeRunsTheWayTheVectorPoints() {
        // `swipeEnd` takes an already-resolved SWIPE VECTOR — direction is `swipeVector`'s job, so
        // this end point simply follows it.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        let end = SimulatorScreenLayout.swipeEnd(
            from: CGPoint(x: 100, y: 200), delta: CGSize(width: 0, height: -50), fitted: fitted,
        )
        XCTAssertEqual(end, CGPoint(x: 100, y: 150))
    }

    func testTheDeltaSSignIsPassedThroughRatherThanReinterpreted() {
        // AppKit has already applied the user's scroll-direction preference: a positive delta always
        // means "toward the top of the document", which on a touch surface is a finger travelling DOWN
        // the screen — +y in this view's flipped space. Measured 2026-08-04: reinterpreting the sign
        // from `isDirectionInvertedFromDevice` double-applies the preference and the device's list
        // moved opposite to a native scroll view given the same gesture.
        XCTAssertEqual(
            SimulatorScreenLayout.swipeVector(delta: CGSize(width: 0, height: -3), isPrecise: true).height, -3,
        )
        XCTAssertEqual(
            SimulatorScreenLayout.swipeVector(delta: CGSize(width: 4, height: 0), isPrecise: true).width, 4,
        )
    }

    func testWheelJitterDoesNotFireASwipePerTick() {
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        XCTAssertNil(SimulatorScreenLayout.swipeEnd(
            from: CGPoint(x: 100, y: 200), delta: CGSize(width: 1, height: 1), fitted: fitted,
        ))
    }

    func testAWheelNotchIsScaledFromLinesToPointsButATrackpadIsNot() {
        // AppKit reports a trackpad's delta in POINTS and a wheel's in LINES. Measured 2026-08-04:
        // taking a line as a point sends a swipe of one or two pixels, under iOS's own pan slop, so
        // the device ignores every tick and the panel looks like it eats scrolls.
        let wheel = SimulatorScreenLayout.swipeVector(
            delta: CGSize(width: 0, height: 3), isPrecise: false,
        )
        XCTAssertEqual(wheel.height, 3 * SimulatorScreenLayout.pointsPerLine)
        let trackpad = SimulatorScreenLayout.swipeVector(
            delta: CGSize(width: 0, height: 3), isPrecise: true,
        )
        XCTAssertEqual(trackpad.height, 3)
    }

    func testOneWheelNotchClearsTheSwipeStep() {
        // The point of the scale factor: a single notch must be a swipe the device acts on, not one
        // banked against the next tick.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        let notch = SimulatorScreenLayout.swipeVector(
            delta: CGSize(width: 0, height: 1), isPrecise: false,
        )
        XCTAssertNotNil(SimulatorScreenLayout.swipeEnd(
            from: CGPoint(x: 100, y: 200), delta: notch, fitted: fitted,
        ))
    }

    func testATrackpadFrameIsBankedRatherThanSentAsItsOwnSwipe() {
        // A trackpad emits a delta per frame. Sending each one would put sixty swipes a second on the
        // wire; the step is what makes the caller accumulate them into one.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        let frame = SimulatorScreenLayout.swipeVector(
            delta: CGSize(width: 0, height: 2), isPrecise: true,
        )
        XCTAssertNil(SimulatorScreenLayout.swipeEnd(
            from: CGPoint(x: 100, y: 200), delta: frame, fitted: fitted,
        ))
    }

    func testASwipeIsKeptInsideTheFrameSoItIsNotASystemGesture() {
        // A swipe ending past the edge is the app switcher or control centre on iOS — not what
        // someone scrolling a list meant.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 400)
        let end = SimulatorScreenLayout.swipeEnd(
            from: CGPoint(x: 100, y: 20), delta: CGSize(width: 0, height: -900), fitted: fitted,
        )
        XCTAssertEqual(end, CGPoint(x: 100, y: 1))
        let sideways = SimulatorScreenLayout.swipeEnd(
            from: CGPoint(x: 100, y: 200), delta: CGSize(width: 900, height: 0), fitted: fitted,
        )
        XCTAssertEqual(sideways, CGPoint(x: 199, y: 200))
    }
}
#endif
