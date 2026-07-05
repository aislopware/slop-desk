import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskVideoClient

/// PURE 1:1 pane-snap math (``StreamSizeSnap``): the point size at which a decoded stream renders
/// without a fractional resample is the HOST WINDOW's point size — `decoded pixels / the HOST
/// captureScale` — and a snap is warranted only when that target differs from the current layer
/// size by a visible delta. The host captureScale is inferred from the first frame (`decoded
/// pixels / acked window points`). No layer / decoder touched — the inputs are passed in.
final class StreamSizeSnapTests: XCTestCase {
    // MARK: targetPoints (divisor is the HOST captureScale, not the client contentsScale)

    func testTargetPointsDividesPixelsByCaptureScale() {
        // A 1331×829-point host window captured at 2× (virtual display) decodes as 2662×1658 px;
        // the host window's point size — and so the snap target — is 1331×829.
        let target = StreamSizeSnap.targetPoints(
            pixelSize: VideoSize(width: 2662, height: 1658), captureScale: 2,
        )
        XCTAssertEqual(target, VideoSize(width: 1331, height: 829))
    }

    func testTargetPointsAtCaptureScale1IsThePixelSize() {
        // No virtual display ⇒ the host captures at 1× ⇒ decoded pixels == window points, so the
        // snap target is the full pixel size IN POINTS. (Combined with a 2× Retina client this is
        // soft — a 2× upscale — but it is the host window's TRUE point size, so the pane is the
        // right SIZE and the resize loop converges; see `testResizeLoopConvergesAtAnyScale`.)
        let target = StreamSizeSnap.targetPoints(
            pixelSize: VideoSize(width: 1680, height: 969), captureScale: 1,
        )
        XCTAssertEqual(target, VideoSize(width: 1680, height: 969))
    }

    func testOddPixelsAtCaptureScale2YieldHalfPoints() {
        // Half-point sizes are pixel-exact at a 2× capture (0.5 pt = 1 px) — they must NOT be
        // rounded away, or the snapped window points would be off by one capture pixel.
        let target = StreamSizeSnap.targetPoints(
            pixelSize: VideoSize(width: 2661, height: 1657), captureScale: 2,
        )
        XCTAssertEqual(target, VideoSize(width: 1330.5, height: 828.5))
    }

    func testNonPositiveCaptureScaleFallsBackTo1() {
        let zero = StreamSizeSnap.targetPoints(pixelSize: VideoSize(width: 100, height: 50), captureScale: 0)
        XCTAssertEqual(zero, VideoSize(width: 100, height: 50))
        let negative = StreamSizeSnap.targetPoints(pixelSize: VideoSize(width: 100, height: 50), captureScale: -2)
        XCTAssertEqual(negative, VideoSize(width: 100, height: 50))
    }

    // MARK: inferredCaptureScale (decoded pixels per negotiated window point)

    func testInferredCaptureScaleAtOneX() {
        // No-VD path: a 1680-pt window captured at 1× decodes as 1680 px → captureScale 1.
        let s = StreamSizeSnap.inferredCaptureScale(
            decodedPixels: VideoSize(width: 1680, height: 969),
            windowPoints: VideoSize(width: 1680, height: 969),
        )
        XCTAssertEqual(s, 1.0, accuracy: 0.0001)
    }

    func testInferredCaptureScaleAtTwoX() {
        // VD path: a 1331-pt window captured at 2× decodes as 2662 px → captureScale 2.
        let s = StreamSizeSnap.inferredCaptureScale(
            decodedPixels: VideoSize(width: 2662, height: 1658),
            windowPoints: VideoSize(width: 1331, height: 829),
        )
        XCTAssertEqual(s, 2.0, accuracy: 0.0001)
    }

    func testInferredCaptureScaleDegenerateWindowFallsBackTo1() {
        let s = StreamSizeSnap.inferredCaptureScale(
            decodedPixels: VideoSize(width: 1000, height: 600),
            windowPoints: VideoSize(width: 0, height: 0),
        )
        XCTAssertEqual(s, 1.0, accuracy: 0.0001)
    }

    // MARK: the regression — the resize feedback loop must CONVERGE at any scale

    /// Models the resize round-trip exactly as the session composes it: the host renders the
    /// requested window at its OWN capture scale (decoded pixels = requested points × captureScale),
    /// and the client snaps the pane to `targetPoints(decoded, inferredCaptureScale)`. The snap
    /// MUST land back on the requested points (loop gain 1) for EVERY host-capture × client-Retina
    /// combination — otherwise a user drag never sticks. The no-VD bug divided by the CLIENT
    /// contentsScale (2), so a 1× capture halved the pane every cycle.
    func testResizeLoopConvergesAtAnyScale() {
        for hostCaptureScale in [1.0, 2.0, 3.0] {
            let requested = VideoSize(width: 1680, height: 969) // what the user dragged the pane to
            // Host renders the window at its capture scale → decoded pixel dims.
            let decoded = VideoSize(
                width: requested.width * hostCaptureScale,
                height: requested.height * hostCaptureScale,
            )
            // Client infers the (constant) capture scale from the first frame, then snaps.
            let inferred = StreamSizeSnap.inferredCaptureScale(decodedPixels: decoded, windowPoints: requested)
            let snapped = StreamSizeSnap.targetPoints(pixelSize: decoded, captureScale: inferred)
            XCTAssertEqual(
                snapped.width,
                requested.width,
                accuracy: 0.001,
                "snap must return to the dragged size at captureScale \(hostCaptureScale)",
            )
            XCTAssertEqual(snapped.height, requested.height, accuracy: 0.001)
        }
    }

    /// Pins the BUG so a future refactor can't quietly reintroduce it: dividing a 1×-capture
    /// stream by a 2× CLIENT contentsScale yields HALF the window points — the pane that shrank
    /// on every resize. The fix divides by the HOST captureScale (1) instead (test above).
    func testClientContentsScaleWouldHalveTheNoVDPane() {
        let decoded = VideoSize(width: 1680, height: 969) // 1680-pt window captured at 1×
        let buggy = StreamSizeSnap.targetPoints(pixelSize: decoded, captureScale: 2 /* client Retina */ )
        XCTAssertEqual(buggy, VideoSize(width: 840, height: 484.5)) // half — the shrink
    }

    // MARK: shouldSnap

    func testMeaningfulDeltaSnaps() {
        XCTAssertTrue(StreamSizeSnap.shouldSnap(
            target: VideoSize(width: 1331, height: 829),
            current: VideoSize(width: 1200, height: 800),
        ))
    }

    func testSubEpsilonDeltaHolds() {
        // A 0.2-pt wobble on both axes is layout noise — snapping would churn the canvas
        // frame + persistence for an invisible change.
        XCTAssertFalse(StreamSizeSnap.shouldSnap(
            target: VideoSize(width: 1331.2, height: 829.1),
            current: VideoSize(width: 1331.0, height: 829.0),
        ))
    }

    func testExactMatchHolds() {
        let size = VideoSize(width: 1331, height: 829)
        XCTAssertFalse(
            StreamSizeSnap.shouldSnap(target: size, current: size),
            "an already-1:1 pane must not be re-resized on reconnect",
        )
    }

    func testSingleAxisDeltaSnaps() {
        XCTAssertTrue(
            StreamSizeSnap.shouldSnap(
                target: VideoSize(width: 1331, height: 900),
                current: VideoSize(width: 1331, height: 829),
            ),
            "one axis off by ≥ epsilon is enough — both axes must match for 1:1",
        )
    }
}
