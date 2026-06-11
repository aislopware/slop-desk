import XCTest
@testable import AislopdeskVideoClient
import AislopdeskVideoProtocol

/// PURE client→host input encoding: view-space points normalise to clamped 0..1
/// window space (the client NEVER sends pixels — doc 05 §2), tags are monotonic, and
/// every event round-trips through the wire codec the host decodes.
final class InputEventEncoderTests: XCTestCase {

    // These exercise the no-letterbox case: `videoNativeSize` shares the layer's aspect
    // ratio, so the displayed rect IS the full layer and the mapping reduces to the simple
    // point/size ratio. The aspect-fit (letterbox) + zoom/pan inverse is covered in
    // DisplayedVideoRectTests / NormalizeInverseTests.

    func testNormalizeCentreOfLayer() {
        let n = InputEventEncoder.normalize(viewPoint: VideoPoint(x: 400, y: 300), layerSize: VideoSize(width: 800, height: 600), videoNativeSize: VideoSize(width: 800, height: 600))
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
    }

    func testNormalizeClampsOutOfBounds() {
        let over = InputEventEncoder.normalize(viewPoint: VideoPoint(x: 1000, y: -50), layerSize: VideoSize(width: 800, height: 600), videoNativeSize: VideoSize(width: 800, height: 600))
        XCTAssertEqual(over.x, 1.0, accuracy: 1e-9)
        XCTAssertEqual(over.y, 0.0, accuracy: 1e-9)
    }

    func testNormalizeZeroLayerIsSafe() {
        let n = InputEventEncoder.normalize(viewPoint: VideoPoint(x: 10, y: 10), layerSize: VideoSize(width: 0, height: 0), videoNativeSize: VideoSize(width: 800, height: 600))
        XCTAssertEqual(n, VideoPoint(x: 0, y: 0))
    }

    func testTagsAreMonotonic() {
        var enc = InputEventEncoder()
        let layer = VideoSize(width: 100, height: 100)
        let e1 = enc.mouseMove(viewPoint: VideoPoint(x: 50, y: 50), layerSize: layer, videoNativeSize: layer)
        let e2 = enc.mouseDown(button: .left, viewPoint: VideoPoint(x: 50, y: 50), layerSize: layer, videoNativeSize: layer, clickCount: 1, modifiers: [])
        let e3 = enc.key(keyCode: 0, down: true, modifiers: [.command])
        XCTAssertEqual(e1.tag, 1)
        XCTAssertEqual(e2.tag, 2)
        XCTAssertEqual(e3.tag, 3)
    }

    func testMouseDownNormalisesAndRoundTrips() throws {
        var enc = InputEventEncoder()
        let event = enc.mouseDown(button: .right, viewPoint: VideoPoint(x: 800, y: 300), layerSize: VideoSize(width: 800, height: 600), videoNativeSize: VideoSize(width: 800, height: 600), clickCount: 2, modifiers: [.shift, .command])
        guard case .mouseDown(let button, let n, let clicks, let mods, let tag) = event else { return XCTFail("not a mouseDown") }
        XCTAssertEqual(button, .right)
        XCTAssertEqual(n.x, 1.0, accuracy: 1e-9) // clamped
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(clicks, 2)
        XCTAssertEqual(mods, [.shift, .command])
        XCTAssertEqual(tag, 1)
        // Round-trips through the wire codec the host uses.
        XCTAssertEqual(try InputEvent.decode(event.encode()), event)
    }

    func testMouseDragNormalisesAndRoundTrips() throws {
        var enc = InputEventEncoder()
        let event = enc.mouseDrag(button: .left, viewPoint: VideoPoint(x: 400, y: 300), layerSize: VideoSize(width: 800, height: 600), videoNativeSize: VideoSize(width: 800, height: 600), clickCount: 1, modifiers: [.shift])
        guard case .mouseDrag(let button, let n, let clicks, let mods, let tag) = event else { return XCTFail("not a mouseDrag") }
        XCTAssertEqual(button, .left)
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(mods, [.shift])   // a shift-drag extends a selection — must survive the wire
        XCTAssertEqual(tag, 1)
        XCTAssertEqual(try InputEvent.decode(event.encode()), event)
    }

    func testScrollAndTextRoundTrip() throws {
        var enc = InputEventEncoder()
        let layer = VideoSize(width: 200, height: 200)
        let scroll = enc.scroll(dx: -3, dy: 7.5, viewPoint: VideoPoint(x: 100, y: 100), layerSize: layer, videoNativeSize: layer)
        let text = enc.text("héllo 𝓊𝓃𝒾𝒸ℴ𝒹ℯ")
        XCTAssertEqual(try InputEvent.decode(scroll.encode()), scroll)
        XCTAssertEqual(try InputEvent.decode(text.encode()), text)
    }

    func testKeyRoundTrip() throws {
        var enc = InputEventEncoder()
        let key = enc.key(keyCode: 36, down: false, modifiers: [.option])
        XCTAssertEqual(try InputEvent.decode(key.encode()), key)
    }
}
