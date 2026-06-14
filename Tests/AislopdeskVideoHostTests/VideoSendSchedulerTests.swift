import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoHost

/// PURE packet-scheduling: turns encoder output + per-stream messages into ordered,
/// channel-tagged datagrams. No socket; just channel assignment + ordering.
final class VideoSendSchedulerTests: XCTestCase {
    private let scheduler = VideoSendScheduler()

    private func makeAVCC(naluSizes: [Int]) -> Data {
        let units = naluSizes.enumerated().map { i, size in
            Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ i &* 7) })
        }
        return NALUnit.join(units)
    }

    func testFrameSchedulesAllFragmentsOnVideoChannelInOrder() {
        var packetizer = VideoPacketizer(fec: XORParityFEC())
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize * 2 + 9])
        let fragments = packetizer.packetize(frame: frame, keyframe: true)
        let outgoing = scheduler.scheduleFrame(fragments)

        XCTAssertEqual(outgoing.count, fragments.count)
        for (i, out) in outgoing.enumerated() {
            XCTAssertEqual(out.channel, .video)
            XCTAssertEqual(out.bytes, fragments[i].encode(), "scheduler preserves packetizer order + bytes")
        }
    }

    func testFrameRoundTripsThroughSchedulerToReassembler() throws {
        var packetizer = VideoPacketizer()
        let frame = makeAVCC(naluSizes: [VideoPacketizer.maxPayloadSize + 100, 30])
        let fragments = packetizer.packetize(frame: frame, keyframe: true, crisp: true)
        let outgoing = scheduler.scheduleFrame(fragments)

        var reassembler = FrameReassembler()
        var completed: ReassembledFrame?
        for out in outgoing {
            XCTAssertEqual(out.channel, .video)
            let parsed = try FrameFragment.decode(out.bytes)
            if case let .completed(f) = reassembler.ingest(parsed) { completed = f }
        }
        XCTAssertEqual(completed?.avcc, frame)
        XCTAssertEqual(completed?.keyframe, true)
        XCTAssertEqual(completed?.crisp, true)
    }

    func testGeometryGoesOnGeometryChannel() throws {
        let message = WindowGeometryMessage.bounds(VideoRect(x: 1, y: 2, width: 3, height: 4))
        let out = scheduler.scheduleGeometry(message)
        XCTAssertEqual(out.channel, .geometry)
        XCTAssertEqual(try WindowGeometryMessage.decode(out.bytes), message)
    }

    func testCursorUpdateAndShapeBothGoOnCursorChannel() throws {
        let update = CursorChannelMessage.update(CursorUpdate(
            position: VideoPoint(x: 5, y: 6),
            shapeID: 2,
            hotspot: VideoPoint(x: 0, y: 0),
        ))
        let shape = CursorChannelMessage.shape(CursorShapeMessage(
            shapeID: 2,
            size: VideoSize(width: 16, height: 16),
            hotspot: VideoPoint(x: 1, y: 1),
            bitmap: Data([1, 2, 3]),
        ))

        let outUpdate = scheduler.scheduleCursor(update)
        let outShape = scheduler.scheduleCursor(shape)
        XCTAssertEqual(outUpdate.channel, .cursor)
        XCTAssertEqual(outShape.channel, .cursor)
        XCTAssertEqual(try CursorChannelMessage.decode(outUpdate.bytes), update)
        XCTAssertEqual(try CursorChannelMessage.decode(outShape.bytes), shape)
    }

    func testControlGoesOnControlChannel() throws {
        let message = VideoControlMessage.helloAck(
            accepted: true,
            streamID: 3,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        )
        let out = scheduler.scheduleControl(message)
        XCTAssertEqual(out.channel, .control)
        XCTAssertEqual(try VideoControlMessage.decode(out.bytes), message)
    }

    /// The 1-byte media-socket channel tags are the wire contract; the client carries a
    /// byte-identical copy. Pin them so neither side drifts (recovery=5 is the new
    /// dedicated channel that fixed the input collision).
    func testChannelWireTagsArePinned() {
        XCTAssertEqual(VideoChannel.control.rawValue, 0)
        XCTAssertEqual(VideoChannel.video.rawValue, 1)
        XCTAssertEqual(VideoChannel.geometry.rawValue, 2)
        XCTAssertEqual(VideoChannel.cursor.rawValue, 3)
        XCTAssertEqual(VideoChannel.input.rawValue, 4)
        XCTAssertEqual(VideoChannel.recovery.rawValue, 5)
    }
}
