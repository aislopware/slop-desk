import XCTest
@testable import AislopdeskVideoProtocol

/// PURE aspect-fit geometry (doc 17 §3.7): `displayedVideoRect` is the single source of
/// truth for where the decoded video is actually drawn inside the layer (letterbox /
/// pillarbox), and `viewPoint(forHostPoint:…)` is the forward render transform whose
/// inverse the input encoder uses. Both must mirror `MetalVideoRenderer`'s fit branch
/// exactly so render-forward and input-inverse can never drift.
final class AspectFitTests: XCTestCase {
    private func assertRect(
        _ r: VideoRect,
        _ x: Double,
        _ y: Double,
        _ w: Double,
        _ h: Double,
        accuracy: Double = 1e-9,
        _ file: StaticString = #filePath,
        _ line: UInt = #line,
    ) {
        XCTAssertEqual(r.origin.x, x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(r.origin.y, y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(r.size.width, w, accuracy: accuracy, "w", file: file, line: line)
        XCTAssertEqual(r.size.height, h, accuracy: accuracy, "h", file: file, line: line)
    }

    // MARK: displayedVideoRect

    func testWiderVideoGetsBarsTopAndBottomCentered() {
        // View 1600x1000 (aspect 1.6), video 1920x1080 (aspect ~1.778) → video is WIDER:
        // full width 1600, height = 1600/1.778 = 900, bars 50 top + 50 bottom.
        let r = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        assertRect(r, 0, 50, 1600, 900)
    }

    func testTallerVideoGetsBarsLeftAndRightCentered() {
        // View 1600x1000 (aspect 1.6), video 1000x1000 (aspect 1.0) → video is TALLER/narrower:
        // full height 1000, width = 1000*1.0 = 1000, bars 300 left + 300 right.
        let r = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1000, height: 1000),
        )
        assertRect(r, 300, 0, 1000, 1000)
    }

    func testEqualAspectFillsLayer() {
        let r = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 800, height: 600),
            videoNativeSize: VideoSize(width: 1600, height: 1200),
        )
        assertRect(r, 0, 0, 800, 600)
    }

    func testDegenerateZeroSizesFallBackToFullRect() {
        let zeroVideo = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 800, height: 600),
            videoNativeSize: VideoSize(width: 0, height: 0),
        )
        assertRect(zeroVideo, 0, 0, 800, 600)
        let zeroView = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 0, height: 0),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        assertRect(zeroView, 0, 0, 0, 0)
    }

    // MARK: displayedVideoRect — .fill (cover, crop-the-overflow)

    func testFillWiderVideoCoversWithLeftRightCrop() {
        // Same inputs as the .fit wider case, but .fill COVERS: scale = max(1600/1920, 1000/1080)
        // = 1000/1080 ≈ 0.92593, so height = 1000 (fills), width = 1920·0.92593 = 1777.78
        // (overflows), centred → origin x = (1600-1777.78)/2 = -88.89 (the crop).
        let r = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
            mode: .fill,
        )
        assertRect(r, -88.8888888889, 0, 1777.7777777778, 1000, accuracy: 1e-6)
    }

    func testFillTallerVideoCoversWithTopBottomCrop() {
        // video 1000x1000 into 1600x1000: scale = max(1.6, 1.0) = 1.6 → 1600x1600 centred,
        // origin y = (1000-1600)/2 = -300 (top+bottom crop), full width 1600.
        let r = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1000, height: 1000),
            mode: .fill,
        )
        assertRect(r, 0, -300, 1600, 1600)
    }

    func testFillEqualAspectMatchesFit() {
        // Equal aspect: min == max, so .fill and .fit are identical (no crop, no bars).
        let fit = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 800, height: 600),
            videoNativeSize: VideoSize(width: 1600, height: 1200),
            mode: .fit,
        )
        let fill = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 800, height: 600),
            videoNativeSize: VideoSize(width: 1600, height: 1200),
            mode: .fill,
        )
        assertRect(fill, fit.origin.x, fit.origin.y, fit.size.width, fit.size.height)
    }

    func testDefaultModeIsFit() {
        // The mode param defaults to .fit so every pre-existing caller is unchanged.
        let def = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        let fit = AspectFit.displayedVideoRect(
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
            mode: .fit,
        )
        assertRect(def, fit.origin.x, fit.origin.y, fit.size.width, fit.size.height)
    }

    func testFillCoversTheWholeViewOnBothAxes() {
        // The defining property of .fill: the displayed rect CONTAINS the view on both axes
        // (origin ≤ 0 and far edge ≥ view extent) — i.e. no bars, the view is fully covered.
        for (view, video) in [
            (VideoSize(width: 1600, height: 1000), VideoSize(width: 1920, height: 1080)),
            (VideoSize(width: 1600, height: 1000), VideoSize(width: 1000, height: 1000)),
            (VideoSize(width: 1080, height: 1920), VideoSize(width: 1920, height: 1080)),
        ] {
            let r = AspectFit.displayedVideoRect(viewSize: view, videoNativeSize: video, mode: .fill)
            XCTAssertLessThanOrEqual(r.origin.x, 1e-9)
            XCTAssertLessThanOrEqual(r.origin.y, 1e-9)
            XCTAssertGreaterThanOrEqual(r.origin.x + r.size.width, view.width - 1e-9)
            XCTAssertGreaterThanOrEqual(r.origin.y + r.size.height, view.height - 1e-9)
        }
    }

    // MARK: viewPoint forward transform (host point → view point)

    func testForwardViewPointCenterAtUnityZoom() {
        // Center of the host window maps to the center of the displayed (letterboxed) rect.
        let p = AspectFit.viewPoint(
            forHostPoint: VideoPoint(x: 960, y: 540),
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        XCTAssertEqual(p.x, 800, accuracy: 1e-9) // layer center x
        XCTAssertEqual(p.y, 500, accuracy: 1e-9) // layer center y (= 50 + 900/2)
    }

    func testForwardViewPointTopLeftLandsOnDisplayedRectOrigin() {
        // Host (0,0) → the displayed rect's origin (0, 50) for the wider-video case.
        let p = AspectFit.viewPoint(
            forHostPoint: VideoPoint(x: 0, y: 0),
            viewSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 50, accuracy: 1e-9)
    }
}
