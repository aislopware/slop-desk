import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// PURE pointer-mapping correctness (doc 17 §3.7). The input encoder's `normalize` must
/// be the EXACT inverse of the renderer's aspect-fit + zoom/pan transform, so a click
/// lands on the host pixel under the on-screen cursor. Also pins the renderer's `fit`
/// formula to `displayedVideoRect` so render-forward and input-inverse can never drift.
final class PointerMappingTests: XCTestCase {
    // MARK: normalize, zoom == 1, letterboxed (the macOS case)

    func testNormalizeLetterboxedCornersMapToZeroAndOne() {
        // View 1600x1000, video 1920x1080 → displayed rect (0,50,1600,900).
        let view = VideoSize(width: 1600, height: 1000)
        let video = VideoSize(width: 1920, height: 1080)
        // Top-left of the displayed video (0,50) → (0,0).
        let tl = InputEventEncoder.normalize(
            viewPoint: VideoPoint(x: 0, y: 50),
            layerSize: view,
            videoNativeSize: video,
        )
        XCTAssertEqual(tl.x, 0, accuracy: 1e-9)
        XCTAssertEqual(tl.y, 0, accuracy: 1e-9)
        // Bottom-right of the displayed video (1600,950) → (1,1).
        let br = InputEventEncoder.normalize(
            viewPoint: VideoPoint(x: 1600, y: 950),
            layerSize: view,
            videoNativeSize: video,
        )
        XCTAssertEqual(br.x, 1, accuracy: 1e-9)
        XCTAssertEqual(br.y, 1, accuracy: 1e-9)
    }

    func testNormalizeCenterIsHalfHalf() {
        let n = InputEventEncoder.normalize(
            viewPoint: VideoPoint(x: 800, y: 500),
            layerSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
    }

    func testNormalizeClickInsideLetterboxBarClampsToEdge() {
        // A click in the top black bar (y=10, above the displayed rect's y=50) clamps to 0;
        // x at the left edge stays 0.
        let inBar = InputEventEncoder.normalize(
            viewPoint: VideoPoint(x: 0, y: 10),
            layerSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        XCTAssertEqual(inBar.y, 0, accuracy: 1e-9)
        // A click in the bottom bar (y=990, below y=950) clamps to 1.
        let inBottomBar = InputEventEncoder.normalize(
            viewPoint: VideoPoint(x: 1600, y: 990),
            layerSize: VideoSize(width: 1600, height: 1000),
            videoNativeSize: VideoSize(width: 1920, height: 1080),
        )
        XCTAssertEqual(inBottomBar.y, 1, accuracy: 1e-9)
    }

    func testNormalizePillarboxBarsClampHorizontally() {
        // View 1600x1000, video 1000x1000 → displayed rect (300,0,1000,1000); a click at
        // x=100 (left bar) clamps to 0, x=1500 (right bar) clamps to 1.
        let view = VideoSize(width: 1600, height: 1000)
        let video = VideoSize(width: 1000, height: 1000)
        XCTAssertEqual(
            InputEventEncoder.normalize(viewPoint: VideoPoint(x: 100, y: 500), layerSize: view, videoNativeSize: video)
                .x,
            0,
            accuracy: 1e-9,
        )
        XCTAssertEqual(
            InputEventEncoder.normalize(viewPoint: VideoPoint(x: 1500, y: 500), layerSize: view, videoNativeSize: video)
                .x,
            1,
            accuracy: 1e-9,
        )
    }

    // MARK: zoom > 1 + pan (iOS): render-forward then input-inverse must be identity

    func testZoomPanRoundTripIsIdentity() {
        let view = VideoSize(width: 1600, height: 1000)
        let video = VideoSize(width: 1920, height: 1080)
        let zoom = 2.5
        let pan = VideoPoint(x: 0.1, y: -0.05)
        // Take several known host points (within the cropped-visible region for this pan so
        // the inverse is not clamped), push each through the FORWARD transform to a view
        // point, then through the INVERSE (normalize) back to a normalized source point, and
        // assert it equals the original source 0..1.
        let hostPoints = [VideoPoint(x: 960, y: 540), VideoPoint(x: 1100, y: 600), VideoPoint(x: 820, y: 480)]
        for host in hostPoints {
            let vp = AspectFit.viewPoint(
                forHostPoint: host,
                viewSize: view,
                videoNativeSize: video,
                zoom: zoom,
                pan: pan,
            )
            let back = InputEventEncoder.normalize(
                viewPoint: vp,
                layerSize: view,
                videoNativeSize: video,
                zoom: zoom,
                pan: pan,
            )
            // The original normalized source = host / videoNativeSize.
            XCTAssertEqual(back.x, host.x / video.width, accuracy: 1e-6)
            XCTAssertEqual(back.y, host.y / video.height, accuracy: 1e-6)
        }
    }

    // MARK: cursor overlay tracks where clicks land (2d)

    func testCursorOverlayLandsInsideLetterboxedDisplayedRect() {
        // Host cursor at the window center (960,540) on a letterboxed layer must place the
        // overlay tip at the displayed-rect center (800,500) — minus the hotspot — i.e. the
        // SAME place a click at that view point maps back from (round-trip consistency).
        let view = VideoSize(width: 1600, height: 1000)
        let video = VideoSize(width: 1920, height: 1080)
        let update = CursorUpdate(
            position: VideoPoint(x: 960, y: 540),
            shapeID: 1,
            hotspot: VideoPoint(x: 0, y: 0),
            visible: true,
        )
        let frame = ClientCursorCompositor.layerFrame(
            for: update,
            viewSize: view,
            videoNativeSize: video,
            zoom: 1,
            pan: VideoPoint(x: 0, y: 0),
            cursorSize: VideoSize(width: 16, height: 16),
        )
        XCTAssertEqual(frame.origin.x, 800, accuracy: 1e-9)
        XCTAssertEqual(frame.origin.y, 500, accuracy: 1e-9)
        // And a click at the overlay tip maps back to the host cursor's normalized source.
        let back = InputEventEncoder.normalize(
            viewPoint: VideoPoint(x: 800, y: 500),
            layerSize: view,
            videoNativeSize: video,
        )
        XCTAssertEqual(back.x, 960 / video.width, accuracy: 1e-9)
        XCTAssertEqual(back.y, 540 / video.height, accuracy: 1e-9)
    }

    func testCursorOverlayHotspotScaledByDisplayedRect() {
        // View 800x600 displaying a 1600x1200 video (equal aspect, scale 0.5): a 4-point
        // host hotspot becomes 2 view points; position (400,400) → view (200,200) minus 2.
        let view = VideoSize(width: 800, height: 600)
        let video = VideoSize(width: 1600, height: 1200)
        let update = CursorUpdate(
            position: VideoPoint(x: 400, y: 400),
            shapeID: 1,
            hotspot: VideoPoint(x: 4, y: 4),
            visible: true,
        )
        let frame = ClientCursorCompositor.layerFrame(
            for: update,
            viewSize: view,
            videoNativeSize: video,
            zoom: 1,
            pan: VideoPoint(x: 0, y: 0),
            cursorSize: VideoSize(width: 24, height: 24),
        )
        XCTAssertEqual(frame.origin.x, 198, accuracy: 1e-9) // 400*0.5 - 4*0.5
        XCTAssertEqual(frame.origin.y, 198, accuracy: 1e-9)
    }

    // MARK: macOS overlay Y-flip — top-left placement → bottom-left layer space

    func testBottomLeftOriginYIsTheStandardRectFlip() {
        // y' = parentHeight - y - height. A cursor whose TOP-LEFT origin is y=50 in a 1000-tall
        // parent, 16 tall, sits at bottom-left origin 1000-50-16 = 934.
        XCTAssertEqual(
            ClientCursorCompositor.bottomLeftOriginY(topLeftY: 50, height: 16, parentHeight: 1000),
            934,
            accuracy: 1e-9,
        )
    }

    func testOverlayAtWindowTopStaysAtViewTopAfterFlip() {
        // The bug: a cursor at the WINDOW TOP (host y≈0) was written verbatim into the macOS
        // bottom-left layer, mirroring it to the view BOTTOM. After the flip a top-of-window
        // cursor must sit near the view TOP — i.e. a LARGE bottom-left origin-Y (just under the
        // parent's full height), NOT near 0.
        let view = VideoSize(width: 1600, height: 1000)
        let video = VideoSize(width: 1920, height: 1080) // letterboxed: displayed rect (0,50,1600,900)
        let cursor = VideoSize(width: 16, height: 16)
        // Host cursor at the window's top edge.
        let topUpdate = CursorUpdate(
            position: VideoPoint(x: 960, y: 0),
            shapeID: 1,
            hotspot: VideoPoint(x: 0, y: 0),
            visible: true,
        )
        let topFrame = ClientCursorCompositor.layerFrame(
            for: topUpdate,
            viewSize: view,
            videoNativeSize: video,
            zoom: 1,
            pan: VideoPoint(x: 0, y: 0),
            cursorSize: cursor,
        )
        let topFlipped = ClientCursorCompositor.bottomLeftOriginY(
            topLeftY: topFrame.origin.y,
            height: cursor.height,
            parentHeight: view.height,
        )
        // Displayed rect top is view y=50 (top-left) → bottom-left origin 1000-50-16 = 934 (high = near top).
        XCTAssertEqual(topFlipped, 934, accuracy: 1e-9)

        // Host cursor at the window's bottom edge → near the view BOTTOM → a SMALL bottom-left origin.
        let bottomUpdate = CursorUpdate(
            position: VideoPoint(x: 960, y: 1080),
            shapeID: 1,
            hotspot: VideoPoint(x: 0, y: 0),
            visible: true,
        )
        let bottomFrame = ClientCursorCompositor.layerFrame(
            for: bottomUpdate,
            viewSize: view,
            videoNativeSize: video,
            zoom: 1,
            pan: VideoPoint(x: 0, y: 0),
            cursorSize: cursor,
        )
        let bottomFlipped = ClientCursorCompositor.bottomLeftOriginY(
            topLeftY: bottomFrame.origin.y,
            height: cursor.height,
            parentHeight: view.height,
        )
        // Displayed rect bottom is view y=950 (top-left) → bottom-left origin 1000-950-16 = 34 (low = near bottom).
        XCTAssertEqual(bottomFlipped, 34, accuracy: 1e-9)
        XCTAssertGreaterThan(
            topFlipped,
            bottomFlipped,
            "window-top cursor is ABOVE window-bottom cursor in bottom-left space",
        )
    }

    // MARK: renderer fit == displayedVideoRect-derived fit (2e — drift guard)

    func testRendererFitFormulaEqualsDisplayedVideoRect() {
        // The renderer's pre-refactor fit formula (letterbox/pillarbox quad scale) MUST
        // equal the fit derived from displayedVideoRect for any (view, video) pair —
        // otherwise the rendered image and the input/cursor mapping diverge.
        let cases: [(VideoSize, VideoSize)] = [
            (VideoSize(width: 1600, height: 1000), VideoSize(width: 1920, height: 1080)), // wider video
            (VideoSize(width: 1600, height: 1000), VideoSize(width: 1000, height: 1000)), // taller/narrower video
            (VideoSize(width: 800, height: 600), VideoSize(width: 1600, height: 1200)), // equal aspect
            (VideoSize(width: 1080, height: 1920), VideoSize(
                width: 1920,
                height: 1080,
            )), // portrait layer, landscape video
        ]
        for (view, video) in cases {
            // Reference: the renderer's original aspect-comparison formula.
            var fx = 1.0, fy = 1.0
            let videoAspect = video.width / video.height
            let viewAspect = view.width / view.height
            if videoAspect > viewAspect { fy = viewAspect / videoAspect } else { fx = videoAspect / viewAspect }
            // Derived from displayedVideoRect (what the renderer now computes).
            let r = AspectFit.displayedVideoRect(viewSize: view, videoNativeSize: video)
            XCTAssertEqual(r.size.width / view.width, fx, accuracy: 1e-9, "fit.x mismatch for \(view)/\(video)")
            XCTAssertEqual(r.size.height / view.height, fy, accuracy: 1e-9, "fit.y mismatch for \(view)/\(video)")
        }
    }

    // MARK: .fill (cover) — forward then inverse must STILL be identity (incl. cropped points)

    func testFillModeRoundTripIsIdentity() {
        // In .fill the video COVERS the layer (overflow cropped). The forward transform can map
        // a host point to a view point OUTSIDE the layer bounds (the cropped region); normalize
        // with mode:.fill must invert it back to the original source 0..1 — proving render and
        // input agree in fill mode exactly as they do in fit. (zoom == 1, the macOS fill case.)
        let view = VideoSize(width: 1600, height: 1000) // aspect 1.6
        let video = VideoSize(width: 1920, height: 1080) // aspect 1.778 → fill crops left/right
        for host in [
            VideoPoint(x: 0, y: 0),
            VideoPoint(x: 960, y: 540),
            VideoPoint(x: 1920, y: 1080),
            VideoPoint(x: 1500, y: 200),
        ] {
            let vp = AspectFit.viewPoint(forHostPoint: host, viewSize: view, videoNativeSize: video, mode: .fill)
            let back = InputEventEncoder.normalize(viewPoint: vp, layerSize: view, videoNativeSize: video, mode: .fill)
            XCTAssertEqual(back.x, host.x / video.width, accuracy: 1e-6, "x for \(host)")
            XCTAssertEqual(back.y, host.y / video.height, accuracy: 1e-6, "y for \(host)")
        }
    }

    func testRendererFillFitCoversTheDrawable() {
        // In .fill the renderer's quad must COVER the drawable: both fit.x and fit.y ≥ 1, with
        // the tighter axis exactly 1 (the other overflows and is viewport-clipped). Derived from
        // displayedVideoRect(.fill) — the single source the input/cursor mapping also invert.
        let cases: [(VideoSize, VideoSize)] = [
            (VideoSize(width: 1600, height: 1000), VideoSize(width: 1920, height: 1080)),
            (VideoSize(width: 1600, height: 1000), VideoSize(width: 1000, height: 1000)),
            (VideoSize(width: 1080, height: 1920), VideoSize(width: 1920, height: 1080)),
        ]
        for (view, video) in cases {
            let r = AspectFit.displayedVideoRect(viewSize: view, videoNativeSize: video, mode: .fill)
            let fx = r.size.width / view.width, fy = r.size.height / view.height
            XCTAssertGreaterThanOrEqual(fx, 1 - 1e-9, "fit.x must cover for \(view)/\(video)")
            XCTAssertGreaterThanOrEqual(fy, 1 - 1e-9, "fit.y must cover for \(view)/\(video)")
            XCTAssertEqual(min(fx, fy), 1, accuracy: 1e-9, "tighter axis is exactly 1 (cover)")
        }
    }
}

#if os(macOS)
import AppKit

/// PURE keyCode → modifier-mask + press/release detection for `flagsChanged`. Without
/// this seam the host never receives a modifier KEY-UP, so a ⌘ flag latched on the
/// shared CGEventSource stays stuck and corrupts later text insertion (the Cmd+Delete
/// → "enter" bug).
final class FlagsChangedModifierTests: XCTestCase {
    func testLeftCommandKeyCodeWithCommandFlagIsDown() {
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 55, flags: [.command]), true)
    }

    func testRightCommandKeyCodeWithoutCommandFlagIsUp() {
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 54, flags: []), false)
    }

    func testShiftKeyCodes() {
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 56, flags: [.shift]), true)
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 60, flags: []), false)
    }

    func testControlOptionFnCapsLock() {
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 59, flags: [.control]), true)
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 58, flags: [.option]), true)
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 63, flags: [.function]), true)
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 57, flags: [.capsLock]), true)
    }

    func testNonModifierKeyCodeReturnsNil() {
        XCTAssertNil(MetalLayerBackedView.modifierDown(keyCode: 0, flags: [.command])) // 'a'
        XCTAssertNil(MetalLayerBackedView.modifierDown(keyCode: 36, flags: [])) // return
    }

    func testDownDetectionDependsOnFlagPresenceNotKeyCode() {
        // The same ⌘ keyCode (55) yields down=true when ⌘ is present and down=false when
        // absent — that flag check is the only way to tell the press edge from the release.
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 55, flags: [.command]), true)
        XCTAssertEqual(MetalLayerBackedView.modifierDown(keyCode: 55, flags: []), false)
    }

    /// R14: `MetalLayerBackedView.clampClickCount` saturates `NSEvent.clickCount` (an unbounded Int) into the
    /// wire UInt8 instead of the trapping `UInt8(Int)` that crashed the client on a 256th rapid in-place
    /// click. Byte-identical for the real 1/2/3-click range.
    func testClampClickCountSaturatesInsteadOfTrapping() {
        XCTAssertEqual(MetalLayerBackedView.clampClickCount(0), 0)
        XCTAssertEqual(MetalLayerBackedView.clampClickCount(1), 1)
        XCTAssertEqual(MetalLayerBackedView.clampClickCount(3), 3)
        XCTAssertEqual(MetalLayerBackedView.clampClickCount(255), 255)
        XCTAssertEqual(MetalLayerBackedView.clampClickCount(256), 255) // would have trapped pre-R14
        XCTAssertEqual(MetalLayerBackedView.clampClickCount(100_000), 255)
    }
}
#endif
