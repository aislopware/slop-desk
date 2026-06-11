import XCTest
@testable import AislopdeskVideoClient
import AislopdeskVideoProtocol

/// PURE 1:1 pane-snap math (``StreamSizeSnap``): the point size at which a decoded stream
/// renders pixel-for-pixel is `pixels / contentsScale`, and a snap is warranted only when the
/// target differs from the current layer size by a visible delta. No layer / decoder touched —
/// the view passes its scale + current size in.
final class StreamSizeSnapTests: XCTestCase {

    // MARK: targetPoints

    func testTargetPointsDividesPixelsByScale() {
        // The live case: a 1331×829-point host window captured at 2× (virtual display)
        // decodes as 2662×1658 px; on a 2× client the 1:1 point size is 1331×829.
        let target = StreamSizeSnap.targetPoints(
            pixelSize: VideoSize(width: 2662, height: 1658), contentsScale: 2)
        XCTAssertEqual(target, VideoSize(width: 1331, height: 829))
    }

    func testTargetPointsAtScale1IsThePixelSize() {
        // A 1× client display renders 1:1 only at the full pixel size (the pane gets BIG —
        // that is the correct trade for zero resample).
        let target = StreamSizeSnap.targetPoints(
            pixelSize: VideoSize(width: 2662, height: 1658), contentsScale: 1)
        XCTAssertEqual(target, VideoSize(width: 2662, height: 1658))
    }

    func testOddPixelsAtScale2YieldHalfPoints() {
        // Half-point sizes are pixel-exact on a 2× display (0.5 pt = 1 px) — they must NOT be
        // rounded away, or the drawable would be off by one pixel and resample again.
        let target = StreamSizeSnap.targetPoints(
            pixelSize: VideoSize(width: 2661, height: 1657), contentsScale: 2)
        XCTAssertEqual(target, VideoSize(width: 1330.5, height: 828.5))
    }

    func testNonPositiveScaleFallsBackTo1() {
        let zero = StreamSizeSnap.targetPoints(pixelSize: VideoSize(width: 100, height: 50), contentsScale: 0)
        XCTAssertEqual(zero, VideoSize(width: 100, height: 50))
        let negative = StreamSizeSnap.targetPoints(pixelSize: VideoSize(width: 100, height: 50), contentsScale: -2)
        XCTAssertEqual(negative, VideoSize(width: 100, height: 50))
    }

    // MARK: shouldSnap

    func testMeaningfulDeltaSnaps() {
        XCTAssertTrue(StreamSizeSnap.shouldSnap(
            target: VideoSize(width: 1331, height: 829),
            current: VideoSize(width: 1200, height: 800)))
    }

    func testSubEpsilonDeltaHolds() {
        // A 0.2-pt wobble on both axes is layout noise — snapping would churn the canvas
        // frame + persistence for an invisible change.
        XCTAssertFalse(StreamSizeSnap.shouldSnap(
            target: VideoSize(width: 1331.2, height: 829.1),
            current: VideoSize(width: 1331.0, height: 829.0)))
    }

    func testExactMatchHolds() {
        let size = VideoSize(width: 1331, height: 829)
        XCTAssertFalse(StreamSizeSnap.shouldSnap(target: size, current: size),
                       "an already-1:1 pane must not be re-resized on reconnect")
    }

    func testSingleAxisDeltaSnaps() {
        XCTAssertTrue(StreamSizeSnap.shouldSnap(
            target: VideoSize(width: 1331, height: 900),
            current: VideoSize(width: 1331, height: 829)),
                      "one axis off by ≥ epsilon is enough — both axes must match for 1:1")
    }
}
