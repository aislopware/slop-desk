import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// PURE videoScale math + cursor placement. videoScale = layer-points / decoded-points;
/// the cursor compositor multiplies the host-space position by it (minus hotspot).
final class VideoScaleMathTests: XCTestCase {
    func testOneToOneScale() {
        let scale = VideoScaleMath.videoScale(
            layerSize: VideoSize(width: 800, height: 600),
            decodedSize: VideoSize(width: 800, height: 600),
        )
        XCTAssertEqual(scale, 1.0, accuracy: 1e-9)
    }

    func testHalfSizeLayerHalvesScale() {
        // The window is captured at 1600 points but displayed in a 800-point layer.
        let scale = VideoScaleMath.videoScale(
            layerSize: VideoSize(width: 800, height: 600),
            decodedSize: VideoSize(width: 1600, height: 1200),
        )
        XCTAssertEqual(scale, 0.5, accuracy: 1e-9)
    }

    func testUpscaledLayerGivesScaleAboveOne() {
        let scale = VideoScaleMath.videoScale(
            layerSize: VideoSize(width: 1600, height: 1200),
            decodedSize: VideoSize(width: 800, height: 600),
        )
        XCTAssertEqual(scale, 2.0, accuracy: 1e-9)
    }

    func testZeroDecodedWidthFallsBackToUnity() {
        let scale = VideoScaleMath.videoScale(
            layerSize: VideoSize(width: 800, height: 600),
            decodedSize: VideoSize(width: 0, height: 0),
        )
        XCTAssertEqual(scale, 1.0, accuracy: 1e-9)
    }

    // MARK: Cursor placement uses the scale (ClientCursorCompositor.layerFrame)

    func testCursorPlacementAtUnityScaleSubtractsHotspot() {
        let update = CursorUpdate(
            position: VideoPoint(x: 100, y: 200),
            shapeID: 1,
            hotspot: VideoPoint(x: 4, y: 6),
            visible: true,
        )
        let frame = ClientCursorCompositor.layerFrame(
            for: update,
            videoScale: 1.0,
            cursorSize: VideoSize(width: 16, height: 16),
        )
        XCTAssertEqual(frame.origin.x, 96, accuracy: 1e-9) // 100*1 - 4
        XCTAssertEqual(frame.origin.y, 194, accuracy: 1e-9) // 200*1 - 6
        XCTAssertEqual(frame.size, VideoSize(width: 16, height: 16))
    }

    func testCursorPlacementScalesPositionByVideoScale() {
        // A host position of (100,200) shown in a 0.5x layer lands at (50,100) minus hotspot.
        let update = CursorUpdate(
            position: VideoPoint(x: 100, y: 200),
            shapeID: 1,
            hotspot: VideoPoint(x: 2, y: 2),
            visible: true,
        )
        let frame = ClientCursorCompositor.layerFrame(
            for: update,
            videoScale: 0.5,
            cursorSize: VideoSize(width: 24, height: 24),
        )
        XCTAssertEqual(frame.origin.x, 48, accuracy: 1e-9) // 100*0.5 - 2
        XCTAssertEqual(frame.origin.y, 98, accuracy: 1e-9) // 200*0.5 - 2
    }

    func testScaleMathAndCursorPlacementCompose() {
        // End-to-end: capture 1600pts → layer 800pts → scale 0.5 → host (400,400) lands
        // at (200,200) minus hotspot, exactly tracking the displayed pixel.
        let scale = VideoScaleMath.videoScale(
            layerSize: VideoSize(width: 800, height: 600),
            decodedSize: VideoSize(width: 1600, height: 1200),
        )
        let update = CursorUpdate(
            position: VideoPoint(x: 400, y: 400),
            shapeID: 1,
            hotspot: VideoPoint(x: 0, y: 0),
            visible: true,
        )
        let frame = ClientCursorCompositor.layerFrame(
            for: update,
            videoScale: scale,
            cursorSize: VideoSize(width: 16, height: 16),
        )
        XCTAssertEqual(frame.origin.x, 200, accuracy: 1e-9)
        XCTAssertEqual(frame.origin.y, 200, accuracy: 1e-9)
    }
}
