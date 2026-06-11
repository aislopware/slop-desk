import XCTest
import AislopdeskVideoProtocol

/// Round-trip tests for the NEW PATH 2 wire types introduced for the host
/// orchestrator: the session-control message (hello/helloAck/bye) and the
/// out-of-band cursor SHAPE bitmap message + the cursor-channel routing envelope.
/// Pure codec tests (no platform).
final class VideoWireTypeTests: XCTestCase {

    // MARK: VideoControlMessage

    func testControlHelloRoundTrip() throws {
        let message = VideoControlMessage.hello(protocolVersion: AislopdeskVideoProtocol.version, requestedWindowID: 0xDEAD_BEEF, viewport: VideoSize(width: 1280.5, height: 800.25))
        XCTAssertEqual(try VideoControlMessage.decode(message.encode()), message)
    }

    func testControlHelloAckRoundTrip() throws {
        let message = VideoControlMessage.helloAck(accepted: true, streamID: 7, captureWidth: 1920, captureHeight: 1080, windowBoundsCG: VideoRect(x: -100.5, y: 50.25, width: 800, height: 600), fullRange: true)
        XCTAssertEqual(try VideoControlMessage.decode(message.encode()), message)
    }

    func testControlByeRoundTrip() throws {
        XCTAssertEqual(try VideoControlMessage.decode(VideoControlMessage.bye.encode()), .bye)
    }

    func testControlRejectAckRoundTrip() throws {
        let message = VideoControlMessage.helloAck(accepted: false, streamID: 0, captureWidth: 0, captureHeight: 0, windowBoundsCG: VideoRect(x: 0, y: 0, width: 0, height: 0), fullRange: false)
        XCTAssertEqual(try VideoControlMessage.decode(message.encode()), message)
    }

    func testControlUnknownTypeThrows() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([0x7F])))
    }

    func testControlTruncatedThrows() {
        // type=1 (hello) with no body.
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([0x01])))
    }

    // MARK: CursorShapeMessage

    func testCursorShapeRoundTrip() throws {
        let bitmap = Data((0 ..< 200).map { UInt8(truncatingIfNeeded: $0) })
        let message = CursorShapeMessage(shapeID: 5, size: VideoSize(width: 24, height: 24), hotspot: VideoPoint(x: 2, y: 3), bitmap: bitmap)
        let decoded = try CursorShapeMessage.decode(message.encode())
        XCTAssertEqual(decoded.shapeID, 5)
        XCTAssertEqual(decoded.size, VideoSize(width: 24, height: 24))
        XCTAssertEqual(decoded.hotspot, VideoPoint(x: 2, y: 3))
        XCTAssertEqual(decoded.bitmap, bitmap)
    }

    func testCursorShapeEmptyBitmapRoundTrip() throws {
        let message = CursorShapeMessage(shapeID: 0, size: VideoSize(width: 0, height: 0), hotspot: VideoPoint(x: 0, y: 0), bitmap: Data())
        XCTAssertEqual(try CursorShapeMessage.decode(message.encode()), message)
    }

    func testCursorShapeWrongTypeByteThrows() {
        // A position-update (type=1) decoded as a shape must throw.
        let update = CursorUpdate(position: VideoPoint(x: 1, y: 1), shapeID: 1, hotspot: VideoPoint(x: 0, y: 0))
        XCTAssertThrowsError(try CursorShapeMessage.decode(update.encode()))
    }

    func testCursorShapeFitsInOneDatagram() {
        // A realistic 64x64 RGBA cursor PNG is well under the 1200-byte datagram cap.
        // Simulate a 2KB-ish PNG... actually a cursor PNG is small; assert the header
        // overhead is fixed and tiny so a typical cursor needs no fragmentation.
        let message = CursorShapeMessage(shapeID: 1, size: VideoSize(width: 32, height: 32), hotspot: VideoPoint(x: 0, y: 0), bitmap: Data(repeating: 0xAB, count: 800))
        XCTAssertEqual(message.encode().count, CursorShapeMessage.headerSize + 800)
        XCTAssertLessThanOrEqual(message.encode().count, VideoPacketizer.maxDatagramSize)
    }

    // MARK: CursorChannelMessage routing envelope

    func testCursorChannelRoutesUpdate() throws {
        let update = CursorUpdate(position: VideoPoint(x: 10, y: 20), shapeID: 3, hotspot: VideoPoint(x: 1, y: 1), visible: true)
        let routed = try CursorChannelMessage.decode(CursorChannelMessage.update(update).encode())
        XCTAssertEqual(routed, .update(update))
    }

    func testCursorChannelRoutesShape() throws {
        let shape = CursorShapeMessage(shapeID: 3, size: VideoSize(width: 16, height: 16), hotspot: VideoPoint(x: 0, y: 0), bitmap: Data([9, 8, 7]))
        let routed = try CursorChannelMessage.decode(CursorChannelMessage.shape(shape).encode())
        XCTAssertEqual(routed, .shape(shape))
    }

    func testCursorChannelUnknownTypeThrows() {
        XCTAssertThrowsError(try CursorChannelMessage.decode(Data([0x42])))
    }

    func testCursorChannelEmptyThrows() {
        XCTAssertThrowsError(try CursorChannelMessage.decode(Data()))
    }
}
