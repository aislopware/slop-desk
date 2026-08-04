// AndroidScreenLayoutTests — where the frame sits and how a point in the panel becomes a point on the
// device.
//
// This is the part that can be wrong in a way nobody notices until a tap lands two rows off, so the
// asymmetries are pinned explicitly: a DOWN outside the frame is refused, a MOVE outside it is
// clamped, and the sign of a scroll is passed straight through.

#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class AndroidScreenLayoutTests: XCTestCase {
    private let fitted = CGRect(x: 20, y: 10, width: 200, height: 400)

    // MARK: Fitting

    func testTheFrameKeepsItsAspectAndIsCentred() {
        let rect = AndroidScreenLayout.fittedRect(
            content: CGSize(width: 9, height: 16), in: CGSize(width: 200, height: 200),
        )
        XCTAssertEqual(rect.height, 200)
        XCTAssertEqual(rect.width, 113) // 200 × 9/16, rounded
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(rect.minX, 44)
    }

    func testADegenerateSizeIsNothingToDrawRatherThanADivideByZero() {
        // The truth before the session packet has named a size.
        XCTAssertEqual(
            AndroidScreenLayout.fittedRect(content: .zero, in: CGSize(width: 100, height: 100)),
            .zero,
        )
        XCTAssertEqual(
            AndroidScreenLayout.fittedRect(content: CGSize(width: 9, height: 16), in: .zero), .zero,
        )
    }

    // MARK: Panel space → device space

    func testAPointInsideTheFrameIsRebasedOntoIt() {
        XCTAssertEqual(
            AndroidScreenLayout.devicePoint(from: CGPoint(x: 30, y: 60), fitted: fitted),
            CGPoint(x: 10, y: 50),
        )
    }

    func testAClickBesideTheDeviceIsNotATapOnItsEdge() {
        // Clamping here would make the surround a permanently-armed strip that taps the outermost
        // column of the screen.
        XCTAssertNil(AndroidScreenLayout.devicePoint(from: CGPoint(x: 5, y: 60), fitted: fitted))
        XCTAssertNil(AndroidScreenLayout.devicePoint(from: CGPoint(x: 30, y: 900), fitted: fitted))
    }

    func testADragThatLeavesTheFrameIsClampedRatherThanDropped() {
        // A drag legitimately runs off the edge — that is how a shade is pulled down and how a
        // swipe-back finishes. Dropping those moves would freeze the gesture while the button is
        // still held.
        XCTAssertEqual(
            AndroidScreenLayout.clampedDevicePoint(from: CGPoint(x: -100, y: 60), fitted: fitted),
            CGPoint(x: 0, y: 50),
        )
        XCTAssertEqual(
            AndroidScreenLayout.clampedDevicePoint(from: CGPoint(x: 9999, y: 9999), fitted: fitted),
            CGPoint(x: 199, y: 399),
        )
    }

    // MARK: The fields that ride on every positional message

    func testTheSurfaceSizeSaturatesRatherThanWrapping() {
        // The field is 16 bits; a video past 65535 pixels would otherwise wrap and place every touch
        // in the top-left corner.
        let huge = AndroidScreenLayout.Surface(
            fitted: fitted, video: CGSize(width: 70000, height: 10),
        )
        XCTAssertEqual(huge.width, .max)
        XCTAssertEqual(huge.height, 10)
        XCTAssertEqual(AndroidScreenLayout.clampToUInt16(-1), 0)
        XCTAssertEqual(AndroidScreenLayout.clampToUInt16(.nan), 0)
    }

    /// The pair on the wire names the VIDEO, never the panel. `scrcpy`'s `PositionMapper` compares it
    /// against the size it is encoding and discards the event on any difference — see
    /// ``AndroidScreenLayout``. Sending the panel's own size is what made every touch a no-op while
    /// the toolbar's keycodes still worked.
    func testTheSurfaceReportsTheVideoRatherThanThePanel() {
        let surface = AndroidScreenLayout.Surface(
            fitted: CGRect(x: 12, y: 30, width: 200, height: 400),
            video: CGSize(width: 460, height: 1024),
        )
        XCTAssertEqual(surface.width, 460)
        XCTAssertEqual(surface.height, 1024)
        // The fitted rect's ORIGIN is not in the conversion: a point handed to `pixels` has already
        // been rebased by `devicePoint`, and subtracting the origin twice would drag every touch up
        // and to the left by however far the frame is inset.
        XCTAssertEqual(surface.pixels(.zero), .zero)
        XCTAssertEqual(surface.pixels(CGPoint(x: 100, y: 200)), CGPoint(x: 230, y: 512))
    }

    func testAnUnusableSurfaceConvertsToTheOriginRatherThanDividingByZero() {
        let blank = AndroidScreenLayout.Surface(fitted: .zero, video: .zero)
        XCTAssertFalse(blank.isUsable)
        XCTAssertEqual(blank.pixels(CGPoint(x: 10, y: 10)), .zero)
        // A frame drawn but not yet named by a session packet is just as unusable.
        let unnamed = AndroidScreenLayout.Surface(fitted: fitted, video: .zero)
        XCTAssertFalse(unnamed.isUsable)
    }

    func testCoordinatesSaturateAtInt32AndSurviveNaN() {
        XCTAssertEqual(AndroidScreenLayout.clampToInt32(1e12), .max)
        XCTAssertEqual(AndroidScreenLayout.clampToInt32(-1e12), .min)
        XCTAssertEqual(AndroidScreenLayout.clampToInt32(.nan), 0)
        XCTAssertEqual(AndroidScreenLayout.clampToInt32(-3.7), -3)
    }

    // MARK: Scrolling

    func testAWheelNotchIsWorthManyPointsAndATrackpadDeltaIsWorthItself() {
        // AppKit reports a trackpad's delta in points and a wheel's in LINES. A line taken as a point
        // is one or two pixels of finger travel — under Android's own touch slop, so the device
        // discards it and the panel looks like it eats scrolls.
        XCTAssertEqual(
            AndroidScreenLayout.scrollVector(delta: CGSize(width: 0, height: -3), isPrecise: true),
            CGSize(width: 0, height: -3),
        )
        XCTAssertEqual(
            AndroidScreenLayout.scrollVector(delta: CGSize(width: 0, height: -3), isPrecise: false),
            CGSize(width: 0, height: -3 * AndroidScreenLayout.pointsPerLine),
        )
    }

    func testTheScrollSignIsPassedThroughUntouched() {
        // AppKit has ALREADY applied the user's scroll-direction preference. Folding
        // `isDirectionInvertedFromDevice` in on top double-applies it — the trap `docs/47` records
        // for the simulator panel, in the same event here.
        let up = AndroidScreenLayout.scrollVector(delta: CGSize(width: 5, height: 9), isPrecise: true)
        XCTAssertEqual(up, CGSize(width: 5, height: 9))
    }

    // MARK: Pinch

    func testAPinchsTwoContactsStraddleTheCentreOnTheDiagonal() {
        // The diagonal rather than the horizontal, so a spread has room in both axes on a screen far
        // taller than it is wide.
        let (first, second) = AndroidScreenLayout.pinchFingers(
            centre: CGPoint(x: 100, y: 200), spread: 40,
            fitted: CGRect(x: 0, y: 0, width: 200, height: 400),
        )
        XCTAssertEqual(first.x, 114.142, accuracy: 0.01)
        XCTAssertEqual(first.y, 214.142, accuracy: 0.01)
        XCTAssertEqual(second.x, 85.858, accuracy: 0.01)
        XCTAssertEqual(second.y, 185.858, accuracy: 0.01)
    }

    func testAPinchNearTheEdgeKeepsBothFingersOnTheScreen() {
        // A finger past the edge is a system gesture rather than a zoom.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 400)
        let (first, second) = AndroidScreenLayout.pinchFingers(
            centre: CGPoint(x: 2, y: 2), spread: 400, fitted: frame,
        )
        for point in [first, second] {
            XCTAssertGreaterThanOrEqual(point.x, 1)
            XCTAssertLessThanOrEqual(point.x, frame.width - 1)
            XCTAssertGreaterThanOrEqual(point.y, 1)
            XCTAssertLessThanOrEqual(point.y, frame.height - 1)
        }
    }
}
#endif
