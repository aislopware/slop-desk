import AislopdeskVideoProtocol
import XCTest
@testable import AislopdeskVideoClient

/// PURE received-media routing: a media datagram is decoded into a typed value by the
/// channel it arrived on; control is always processed, video/geometry only while
/// streaming, cursor/input ignored on the media path, malformed → drop.
final class ReceivedDatagramRouterTests: XCTestCase {
    private let router = ReceivedDatagramRouter()

    func testControlIsAlwaysDecodedEvenBeforeStreaming() {
        let ack = VideoControlMessage.helloAck(
            accepted: true,
            streamID: 1,
            captureWidth: 800,
            captureHeight: 600,
            windowBoundsCG: VideoRect(x: 0, y: 0, width: 800, height: 600),
            fullRange: false,
        )
        let routed = router.route(channel: .control, data: ack.encode(), mediaFlowing: false)
        XCTAssertEqual(routed, .control(ack))
    }

    func testVideoIgnoredUntilStreaming() {
        var packetizer = VideoPacketizer()
        let frags = packetizer.packetize(frame: NALUnit.join([Data([1, 2, 3])]), keyframe: true)
        let routed = router.route(channel: .video, data: frags[0].encode(), mediaFlowing: false)
        XCTAssertEqual(routed, .ignore)
    }

    func testVideoFragmentDecodedWhileStreaming() throws {
        var packetizer = VideoPacketizer()
        let frags = packetizer.packetize(frame: NALUnit.join([Data([1, 2, 3, 4])]), keyframe: true)
        let routed = router.route(channel: .video, data: frags[0].encode(), mediaFlowing: true)
        guard case let .videoFragment(f) = routed else { XCTFail("expected videoFragment, got \(routed)")
            return
        }
        XCTAssertEqual(f, try FrameFragment.decode(frags[0].encode()))
    }

    func testGeometryDecodedWhileStreaming() {
        let message = WindowGeometryMessage.bounds(VideoRect(x: 1, y: 2, width: 3, height: 4))
        let routed = router.route(channel: .geometry, data: message.encode(), mediaFlowing: true)
        XCTAssertEqual(routed, .geometry(message))
    }

    func testCursorInputAndRecoveryChannelsIgnoredOnMediaPath() {
        // Cursor arrives on its own socket; input + recovery are client→host only, so the
        // client never RECEIVES them on the media path.
        XCTAssertEqual(router.route(channel: .cursor, data: Data([1, 2]), mediaFlowing: true), .ignore)
        XCTAssertEqual(router.route(channel: .input, data: Data([1, 2]), mediaFlowing: true), .ignore)
        XCTAssertEqual(router.route(channel: .recovery, data: Data([1, 2]), mediaFlowing: true), .ignore)
    }

    /// Byte-identical raw values to the host's `VideoChannel` (the wire contract). The
    /// two modules carry their own copies; if either drifts the 1-byte tag breaks.
    func testRecoveryChannelHasExpectedWireTag() {
        XCTAssertEqual(VideoChannel.recovery.rawValue, 5)
    }

    func testMalformedControlDrops() {
        if case .drop = router.route(channel: .control, data: Data([0x7F]), mediaFlowing: true) {} else {
            XCTFail("malformed control should drop")
        }
    }

    func testMalformedVideoDropsWhileStreaming() {
        // A truncated fragment (claims a payload longer than present).
        if case .drop = router.route(channel: .video, data: Data([0, 0, 0, 1]), mediaFlowing: true) {} else {
            XCTFail("malformed video should drop")
        }
    }
}
