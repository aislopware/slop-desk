// DevicePanelGeometryTests — the crossing for where a device's frame sits and what a point in it means.
//
// The LAWS are `rust/slopdesk-devicepanel`'s `geometry` and pinned there, exhaustively. What these
// check is the door: that a `CGPoint`/`CGSize`/`CGRect` reaches it and comes back as the right shape
// — and, for the two answers that can decline, as `nil` rather than the code the C answer carries.
//
// They were the two panels' tests, each pinning the same arithmetic against its own numbers.

#if os(macOS)
import CoreGraphics
import XCTest
@testable import SlopDeskDevicePanels

final class DevicePanelGeometryTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 200, height: 400)

    // MARK: Fitting

    func testTheFrameKeepsItsAspectAndIsCentredOnWholePoints() {
        let rect = DevicePanelGeometry.fittedRect(
            content: CGSize(width: 9, height: 16), in: CGSize(width: 200, height: 200),
        )
        XCTAssertEqual(rect.height, 200)
        XCTAssertEqual(rect.width, 113, "200 × 9/16, rounded to a whole point")
        XCTAssertEqual(rect.minY, 0)
        XCTAssertEqual(rect.minX, 44)
    }

    func testADegenerateSizeIsNothingToDrawRatherThanADivideByZero() {
        // The truth before the stream has named a size — and the one place this differs from the
        // renderer's shared law, which answers the full view rect.
        XCTAssertEqual(
            DevicePanelGeometry.fittedRect(content: .zero, in: CGSize(width: 100, height: 100)), .zero,
        )
        XCTAssertEqual(
            DevicePanelGeometry.fittedRect(content: CGSize(width: 9, height: 16), in: .zero), .zero,
        )
    }

    // MARK: Panel space → frame space

    func testAPointInsideTheFrameIsRebasedOntoIt() {
        let inset = CGRect(x: 20, y: 10, width: 200, height: 400)
        XCTAssertEqual(
            DevicePanelGeometry.devicePoint(from: CGPoint(x: 30, y: 60), fitted: inset),
            CGPoint(x: 10, y: 50),
        )
    }

    func testAClickBesideTheDeviceIsNotATapOnItsEdge() {
        // Clamping here would make the surround a permanently-armed strip that taps the outermost
        // column of the screen — so the door declines, and `nil` is what the decline reads as.
        let inset = CGRect(x: 20, y: 10, width: 200, height: 400)
        XCTAssertNil(DevicePanelGeometry.devicePoint(from: CGPoint(x: 5, y: 60), fitted: inset))
        XCTAssertNil(DevicePanelGeometry.devicePoint(from: CGPoint(x: 30, y: 900), fitted: inset))
        XCTAssertNil(DevicePanelGeometry.devicePoint(from: CGPoint(x: 30, y: 60), fitted: .zero))
    }

    func testADragThatLeavesTheFrameIsClampedRatherThanDropped() {
        // A drag legitimately runs off the edge — that is how a shade is pulled down and how a
        // swipe-back finishes. Dropping those moves would freeze the gesture while the button is
        // still held.
        let inset = CGRect(x: 20, y: 10, width: 200, height: 400)
        XCTAssertEqual(
            DevicePanelGeometry.clampedDevicePoint(from: CGPoint(x: -100, y: 60), fitted: inset),
            CGPoint(x: 0, y: 50),
        )
        XCTAssertEqual(
            DevicePanelGeometry.clampedDevicePoint(from: CGPoint(x: 9999, y: 9999), fitted: inset),
            CGPoint(x: 199, y: 399), "the LAST addressable point, not the size itself",
        )
    }

    func testAPointCrossesIntoTheGridTheStreamIsEncoding() {
        let video = CGSize(width: 460, height: 1024)
        XCTAssertTrue(DevicePanelGeometry.surfaceIsUsable(fitted: frame, video: video))
        XCTAssertEqual(
            DevicePanelGeometry.videoPixels(CGPoint(x: 100, y: 200), fitted: frame, video: video),
            CGPoint(x: 230, y: 512),
        )
        XCTAssertFalse(DevicePanelGeometry.surfaceIsUsable(fitted: frame, video: .zero))
        XCTAssertEqual(
            DevicePanelGeometry.videoPixels(CGPoint(x: 10, y: 10), fitted: frame, video: .zero), .zero,
        )
    }

    // MARK: The wire's geometry fields

    func testTheGeometryFieldsSaturateRatherThanWrapping() {
        // The size field is 16 bits; a video past 65535 pixels would otherwise wrap and place every
        // touch in the top-left corner.
        XCTAssertEqual(DevicePanelGeometry.clampToUInt16(70000), .max)
        XCTAssertEqual(DevicePanelGeometry.clampToUInt16(-1), 0)
        XCTAssertEqual(DevicePanelGeometry.clampToUInt16(.nan), 0)
        XCTAssertEqual(DevicePanelGeometry.clampToInt32(1e12), .max)
        XCTAssertEqual(DevicePanelGeometry.clampToInt32(-1e12), .min)
        XCTAssertEqual(DevicePanelGeometry.clampToInt32(.nan), 0)
        XCTAssertEqual(DevicePanelGeometry.clampToInt32(-3.7), -3)
    }

    // MARK: Scrolling

    func testAWheelNotchIsWorthManyPointsAndATrackpadDeltaIsWorthItself() {
        XCTAssertEqual(
            DevicePanelGeometry.scrollVector(delta: CGSize(width: 0, height: -3), isPrecise: true),
            CGSize(width: 0, height: -3),
        )
        XCTAssertEqual(
            DevicePanelGeometry.scrollVector(delta: CGSize(width: 0, height: -3), isPrecise: false),
            CGSize(width: 0, height: -3 * DevicePanelGeometry.pointsPerLine),
        )
        // Sign is pass-through: AppKit has ALREADY applied the user's scroll-direction preference,
        // and folding `isDirectionInvertedFromDevice` in on top double-applies it (`docs/47`).
        XCTAssertEqual(
            DevicePanelGeometry.scrollVector(delta: CGSize(width: 5, height: 9), isPrecise: true),
            CGSize(width: 5, height: 9),
        )
    }

    func testAQuarterTurnIsUndoneRatherThanApproximated() {
        let vector = CGSize(width: 3, height: 7)
        XCTAssertEqual(DevicePanelGeometry.unrotated(vector, by: 0), vector)
        XCTAssertEqual(DevicePanelGeometry.unrotated(vector, by: 180), CGSize(width: -3, height: -7))
        XCTAssertEqual(
            DevicePanelGeometry.unrotated(DevicePanelGeometry.unrotated(vector, by: 90), by: -90),
            vector,
        )
    }

    // MARK: Pinch, and where a synthetic finger may be planted

    func testAPinchsTwoContactsStraddleTheCentreOnTheDiagonal() {
        // The diagonal rather than the horizontal, so a spread has room in both axes on a screen far
        // taller than it is wide.
        let (first, second) = DevicePanelGeometry.pinchFingers(
            centre: CGPoint(x: 100, y: 200), spread: 40, fitted: frame,
        )
        XCTAssertEqual(first.x, 114.142, accuracy: 0.01)
        XCTAssertEqual(first.y, 214.142, accuracy: 0.01)
        XCTAssertEqual(second.x, 85.858, accuracy: 0.01)
        XCTAssertEqual(second.y, 185.858, accuracy: 0.01)
    }

    func testAPinchNearTheEdgeKeepsBothFingersOnTheScreen() {
        // A finger past the edge is a system gesture rather than a zoom.
        let (first, second) = DevicePanelGeometry.pinchFingers(
            centre: CGPoint(x: 2, y: 2), spread: 400, fitted: frame,
        )
        for point in [first, second] {
            XCTAssertGreaterThanOrEqual(point.x, 1)
            XCTAssertLessThanOrEqual(point.x, frame.width - 1)
            XCTAssertGreaterThanOrEqual(point.y, 1)
            XCTAssertLessThanOrEqual(point.y, frame.height - 1)
        }
    }

    func testASyntheticFingerIsPlantedOutOfTheSystemGestureBand() {
        let margin = DevicePanelGeometry.edgeMargin
        XCTAssertEqual(DevicePanelGeometry.planted(.zero, in: frame), CGPoint(x: margin, y: margin))
        XCTAssertEqual(
            DevicePanelGeometry.planted(CGPoint(x: 9999, y: 9999), in: frame),
            CGPoint(x: 200 - margin, y: 400 - margin),
        )
        // A sliver has no valid band at all, so the middle — the only place that is not an edge.
        let sliver = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(DevicePanelGeometry.planted(.zero, in: sliver), CGPoint(x: 5, y: 5))
    }

    func testARegripLandsAtTheFarEndOfTheAxisTheFingerWasTravelling() {
        // What makes a long scroll one gesture rather than a series of unrelated flicks: the hand
        // lifts and replants with the full height still to move through.
        let margin = DevicePanelGeometry.edgeMargin
        XCTAssertEqual(
            DevicePanelGeometry.regrip(travel: CGSize(width: 0, height: 30), in: frame),
            CGPoint(x: 100, y: margin),
        )
        XCTAssertEqual(
            DevicePanelGeometry.regrip(travel: CGSize(width: 0, height: -30), in: frame),
            CGPoint(x: 100, y: 400 - margin),
        )
        XCTAssertEqual(
            DevicePanelGeometry.regrip(travel: CGSize(width: -30, height: 1), in: frame),
            CGPoint(x: 200 - margin, y: 200),
        )
    }

    // MARK: Edges

    func testAContactInTheBandsCarriesTheEdgeTheHostNeeds() {
        XCTAssertEqual(
            DevicePanelGeometry.systemEdge(at: CGPoint(x: 100, y: 395), fitted: frame, isUpsideDown: false),
            .bottom,
        )
        XCTAssertEqual(
            DevicePanelGeometry.systemEdge(at: CGPoint(x: 100, y: 4), fitted: frame, isUpsideDown: false),
            .top,
        )
        XCTAssertNil(
            DevicePanelGeometry.systemEdge(at: CGPoint(x: 100, y: 200), fitted: frame, isUpsideDown: false),
        )
    }

    func testUpsideDownMovesTheBandsOntoTheOtherAxis() {
        // The one orientation that is not a rotation of the others: the physical home-indicator edge
        // lands on visual LEFT, so the bands swap axes rather than ends.
        XCTAssertEqual(
            DevicePanelGeometry.systemEdge(at: CGPoint(x: 4, y: 200), fitted: frame, isUpsideDown: true),
            .bottom,
        )
        XCTAssertNil(
            DevicePanelGeometry.systemEdge(at: CGPoint(x: 100, y: 395), fitted: frame, isUpsideDown: true),
        )
    }
}
#endif
