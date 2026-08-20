import XCTest
@testable import SlopDeskVideoClient

/// PURE half of the phone's touch → host-pointer translation. `MetalLayerBackedView` (a `CAMetalLayer`
/// over a VideoToolbox decoder) can never be built in a test, which is the whole reason the decisions
/// live outside it — so this suite IS the coverage for the phone's gesture vocabulary.
final class TouchPointerPlanTests: XCTestCase {
    // MARK: Tap vs drag

    func testRestingFingerStaysATap() {
        XCTAssertFalse(TouchPointerPlan.escapesTapSlop(dx: 0, dy: 0))
        XCTAssertFalse(TouchPointerPlan.escapesTapSlop(dx: 6, dy: 6), "8.5 pt of roll is still a tap")
        XCTAssertFalse(TouchPointerPlan.escapesTapSlop(dx: -10, dy: 0), "exactly the slop is NOT past it")
    }

    func testDeliberateTravelBecomesADrag() {
        XCTAssertTrue(TouchPointerPlan.escapesTapSlop(dx: 12, dy: 0))
        XCTAssertTrue(TouchPointerPlan.escapesTapSlop(dx: 0, dy: -12))
        XCTAssertTrue(TouchPointerPlan.escapesTapSlop(dx: 8, dy: 8), "11.3 pt diagonally is a drag")
    }

    // MARK: The two-contact route

    func testPairRestIsUndecided() {
        XCTAssertNil(
            TouchPointerPlan.classifyPair(spanDelta: 3, centroidTravel: 2, zoom: 1),
            "two fingers laid down and held must not scroll the remote document",
        )
    }

    func testPairTranslationAtActualSizeScrollsTheHost() {
        XCTAssertEqual(TouchPointerPlan.classifyPair(spanDelta: 0, centroidTravel: 9, zoom: 1), .scroll)
    }

    func testPairTranslationWhileZoomedPansTheViewport() {
        XCTAssertEqual(
            TouchPointerPlan.classifyPair(spanDelta: 0, centroidTravel: 40, zoom: 2), .pan,
            "at >1× there is off-screen stream to reach, and reaching it is what two fingers mean",
        )
    }

    func testSpanBeatsTravel() {
        // A pinch always drags its centroid a little; misreading that as a scroll sends the remote
        // document flying, so the span test runs first and wins outright.
        XCTAssertEqual(
            TouchPointerPlan.classifyPair(spanDelta: -30, centroidTravel: 200, zoom: 1), .zoom,
        )
    }

    func testSmallSplayIsNotAPinch() {
        XCTAssertEqual(
            TouchPointerPlan.classifyPair(spanDelta: 12, centroidTravel: 20, zoom: 1), .scroll,
            "two fingers laid down for a scroll are never perfectly parallel",
        )
    }

    // MARK: The zoom ladder

    func testPinchScalesFromTheGestureBase() {
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 2, spanRatio: 1.5), 3, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 4, spanRatio: 0.5), 2, accuracy: 1e-12)
    }

    func testPinchClampsToTheLadder() {
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 6, spanRatio: 4), TouchPointerPlan.maxZoom)
        XCTAssertEqual(
            TouchPointerPlan.pinchedZoom(base: 2, spanRatio: 0.1), TouchPointerPlan.minZoom,
            "the floor is 1×: the stream already fits the pane, so minifying shows only background",
        )
    }

    func testDegeneratePinchHoldsTheBase() {
        // Both contacts on the same pixel ⇒ a zero base span ⇒ a non-finite ratio. Holding beats
        // NaN reaching the renderer's UV crop.
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 2, spanRatio: .nan), 2)
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 2, spanRatio: .infinity), 2)
        XCTAssertEqual(TouchPointerPlan.pinchedZoom(base: 2, spanRatio: 0), 2)
    }

    func testSteppedZoomWalksTheLadderAndSettlesAtActualSize() {
        var zoom = TouchPointerPlan.steppedZoom(1, stepIn: true)
        XCTAssertEqual(zoom, 1.25, accuracy: 1e-12)
        zoom = TouchPointerPlan.steppedZoom(zoom, stepIn: true)
        XCTAssertEqual(zoom, 1.5625, accuracy: 1e-12)
        // Stepping back out lands on 1.25 then SNAPS to exactly 1 rather than stopping at 1.0000…4.
        zoom = TouchPointerPlan.steppedZoom(zoom, stepIn: false)
        XCTAssertEqual(zoom, 1.25, accuracy: 1e-12)
        zoom = TouchPointerPlan.steppedZoom(zoom, stepIn: false)
        XCTAssertEqual(zoom, 1, "repeated − settles on actual size")
        XCTAssertEqual(TouchPointerPlan.steppedZoom(zoom, stepIn: false), 1, "and cannot go below it")
    }

    func testNearUnitySnapsExactly() {
        XCTAssertEqual(TouchPointerPlan.clampZoom(1.04), 1)
        XCTAssertEqual(TouchPointerPlan.clampZoom(1.08), 1.08, "outside the snap window it is left alone")
        XCTAssertEqual(TouchPointerPlan.clampZoom(.nan), TouchPointerPlan.minZoom)
    }

    // MARK: The pan clamp

    func testActualSizeCannotPan() {
        XCTAssertEqual(
            TouchPointerPlan.clampPan(0.4, zoom: 1), 0,
            "at 1× the whole stream is in the pane — the crop is pinned centred",
        )
    }

    func testPanClampMatchesTheCropLimit() {
        // The renderer's UV crop can travel 0.5·(1 − 1/zoom) each way; a pan the encoder clamps and the
        // renderer does not is a click that lands somewhere the user is not looking.
        XCTAssertEqual(TouchPointerPlan.clampPan(10, zoom: 2), 0.25, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.clampPan(-10, zoom: 2), -0.25, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.clampPan(0.1, zoom: 2), 0.1, accuracy: 1e-12)
        XCTAssertEqual(TouchPointerPlan.clampPan(10, zoom: 4), 0.375, accuracy: 1e-12)
    }

    // MARK: The wire bytes

    func testScrollPhaseSpellsOneGesture() {
        XCTAssertEqual(TouchPointerPlan.scrollPhase(isFirst: true, isLast: false), 1, "began")
        XCTAssertEqual(TouchPointerPlan.scrollPhase(isFirst: false, isLast: false), 2, "changed")
        XCTAssertEqual(TouchPointerPlan.scrollPhase(isFirst: false, isLast: true), 4, "ended")
        XCTAssertEqual(
            TouchPointerPlan.scrollPhase(isFirst: true, isLast: true), 4,
            "a pair that lifts on its first move still ENDS — a began with no end strands the gesture",
        )
    }

    func testClickCountSaturatesInsteadOfTrapping() {
        XCTAssertEqual(TouchPointerPlan.clickCount(0), 1, "UIKit's 0 is still one click")
        XCTAssertEqual(TouchPointerPlan.clickCount(2), 2, "a double-tap is a real double-click")
        XCTAssertEqual(TouchPointerPlan.clickCount(9999), 255, "a very fast tapper is not a crash")
    }
}
