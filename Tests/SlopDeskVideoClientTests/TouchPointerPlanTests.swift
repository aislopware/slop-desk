import XCTest
@testable import SlopDeskVideoClient

/// The DOOR is reached, and the two things marshalling can get wrong on the way back.
///
/// The phone's gesture vocabulary itself — the slops, the ladder, the pan clamp, the span-beats-
/// travel rule and their bit-exact floats — is `rust/slopdesk-video`'s `client_gestures`, tested
/// there. What can only be checked from this side is that the constants arrive at all (an index
/// nobody defined answers `0`, and a `static let` of `0` for the tap slop would make every touch a
/// drag) and that the `Option` rebuilds: an undecided pair must come back `nil` and not as a route.
final class TouchPointerPlanTests: XCTestCase {
    func testTheVocabularyArrivesThroughTheConstantDoor() {
        XCTAssertEqual(TouchPointerPlan.tapSlop, 10)
        XCTAssertEqual(TouchPointerPlan.longPressDelay, 0.5)
        XCTAssertEqual(TouchPointerPlan.pinchSpanSlop, 24)
        XCTAssertEqual(TouchPointerPlan.pairTravelSlop, 8)
        XCTAssertEqual(TouchPointerPlan.minZoom, 1)
        XCTAssertEqual(TouchPointerPlan.maxZoom, 8)
        XCTAssertEqual(TouchPointerPlan.zoomStep, 1.25)
    }

    func testAnUndecidedPairRebuildsAsNilAndADecidedOneAsItsCase() {
        XCTAssertNil(
            TouchPointerPlan.classifyPair(spanDelta: 3, centroidTravel: 2, zoom: 1),
            "two fingers laid down and held must not scroll the remote document",
        )
        XCTAssertEqual(TouchPointerPlan.classifyPair(spanDelta: 0, centroidTravel: 9, zoom: 1), .scroll)
        XCTAssertEqual(TouchPointerPlan.classifyPair(spanDelta: 0, centroidTravel: 40, zoom: 2), .pan)
        XCTAssertEqual(TouchPointerPlan.classifyPair(spanDelta: -30, centroidTravel: 200, zoom: 1), .zoom)
    }

    func testTheScalarDoorsAnswer() {
        XCTAssertTrue(TouchPointerPlan.escapesTapSlop(dx: 12, dy: 0))
        XCTAssertFalse(TouchPointerPlan.escapesTapSlop(dx: 6, dy: 6))
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 2, spanRatio: 1.5), 3, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.steppedZoom(1, stepIn: true), 1.25, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.clampZoom(1.04), 1)
        XCTAssertEqual(TouchPointerPlan.clampPan(10, zoom: 2), 0.25, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.scrollPhase(isFirst: true, isLast: true), 4)
        XCTAssertEqual(TouchPointerPlan.clickCount(9999), 255, "a very fast tapper is not a crash")
    }
}
