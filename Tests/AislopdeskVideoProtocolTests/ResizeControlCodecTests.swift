import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip for the two in-session resize control messages (`resizeRequest`,
/// `resizeAck`), PLUS a byte-identity regression guard proving the original
/// hello/helloAck/bye trio still encodes to the EXACT bytes it did before the two
/// cases were added (the fixed-size path must stay wire-byte-identical).
final class ResizeControlCodecTests: XCTestCase {

    // MARK: New cases round-trip

    func testResizeRequestRoundTrip() throws {
        let cases: [VideoControlMessage] = [
            .resizeRequest(desired: VideoSize(width: 0, height: 0), epoch: 0),
            .resizeRequest(desired: VideoSize(width: 1280, height: 800), epoch: 1),
            .resizeRequest(desired: VideoSize(width: 1920.5, height: 1080.25), epoch: 0xDEADBEEF),
            .resizeRequest(desired: VideoSize(width: 3840, height: 2160), epoch: .max),
        ]
        for message in cases {
            let decoded = try VideoControlMessage.decode(message.encode())
            XCTAssertEqual(decoded, message)
        }
    }

    func testResizeAckRoundTrip() throws {
        let cases: [VideoControlMessage] = [
            .resizeAck(captureWidth: 0, captureHeight: 0, epoch: 0),
            .resizeAck(captureWidth: 1280, captureHeight: 800, epoch: 1),
            .resizeAck(captureWidth: .max, captureHeight: .max, epoch: 0xCAFEBABE),
            .resizeAck(captureWidth: 1, captureHeight: 1, epoch: .max),
        ]
        for message in cases {
            let decoded = try VideoControlMessage.decode(message.encode())
            XCTAssertEqual(decoded, message)
        }
    }

    /// The new cases use the NEXT free type bytes (4 and 5) and do NOT collide with the
    /// existing trio (1/2/3).
    func testResizeMessageTypeBytes() {
        XCTAssertEqual(VideoControlMessage.resizeRequest(desired: VideoSize(width: 1, height: 1), epoch: 0).messageType, 4)
        XCTAssertEqual(VideoControlMessage.resizeAck(captureWidth: 1, captureHeight: 1, epoch: 0).messageType, 5)
        // Trio unchanged.
        XCTAssertEqual(VideoControlMessage.hello(protocolVersion: 1, requestedWindowID: 0, viewport: VideoSize(width: 0, height: 0)).messageType, 1)
        XCTAssertEqual(VideoControlMessage.helloAck(accepted: true, streamID: 0, captureWidth: 0, captureHeight: 0, windowBoundsCG: VideoRect(x: 0, y: 0, width: 0, height: 0), fullRange: false).messageType, 2)
        XCTAssertEqual(VideoControlMessage.bye.messageType, 3)
    }

    func testResizeRequestTruncatedRejected() {
        // type 4 + only the desiredW Float64 (no desiredH, no epoch).
        var bad = Data([4]); bad.appendBE(Double(1280))
        XCTAssertThrowsError(try VideoControlMessage.decode(bad))
    }

    func testResizeAckTruncatedRejected() {
        // type 5 + only the captureWidth UInt16 (no height, no epoch).
        var bad = Data([5]); bad.appendBE(UInt16(1280))
        XCTAssertThrowsError(try VideoControlMessage.decode(bad))
    }

    func testUnknownControlTypeStillRejected() {
        // The accepted type set is 1..9 (7 = listWindows, 8 = windowList, 9 = focusWindow — the
        // raise-the-focused-pane's-window signal); anything beyond MUST still be rejected as malformed.
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([10])))
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([99])))
    }

    // MARK: Byte-identity regression guard (fixed-size path unchanged)

    /// A KNOWN hello must encode to the EXACT bytes it always did: `[1][BE ver][BE
    /// windowID][BE viewportW Float64][BE viewportH Float64]` = 23 bytes. Adding the
    /// resize cases must not perturb the hello body.
    func testHelloEncodingByteIdentical() throws {
        let hello = VideoControlMessage.hello(protocolVersion: 1, requestedWindowID: 0x01020304,
                                              viewport: VideoSize(width: 1280, height: 800))
        var expected = Data()
        expected.append(1)                       // type
        expected.appendBE(UInt16(1))             // protocolVersion
        expected.appendBE(UInt32(0x01020304))    // requestedWindowID
        expected.appendBE(Double(1280))          // viewportW
        expected.appendBE(Double(800))           // viewportH
        XCTAssertEqual(hello.encode(), expected)
        XCTAssertEqual(hello.encode().count, 23)
        XCTAssertEqual(hello.encode().first, 1)
        XCTAssertEqual(try VideoControlMessage.decode(hello.encode()), hello)
    }

    /// A KNOWN helloAck: `[2][accepted][BE streamID][BE cw][BE ch][fullRange][BE bounds x/y/w/h
    /// Float64×4]` = 43 bytes (WF-6 #8 added the 1-byte `fullRange` AFTER captureHeight). The OFF
    /// path encodes `fullRange = 0` there; the rest of the body is unchanged.
    func testHelloAckEncodingKnownLayout() throws {
        let ack = VideoControlMessage.helloAck(accepted: true, streamID: 0x0A0B0C0D,
                                               captureWidth: 1280, captureHeight: 800,
                                               windowBoundsCG: VideoRect(x: 10, y: 20, width: 1280, height: 800),
                                               fullRange: false)
        var expected = Data()
        expected.append(2)                       // type
        expected.append(1)                       // accepted
        expected.appendBE(UInt32(0x0A0B0C0D))    // streamID
        expected.appendBE(UInt16(1280))          // captureWidth
        expected.appendBE(UInt16(800))           // captureHeight
        expected.append(0)                       // fullRange (WF-6 #8, OFF)
        expected.appendBE(Double(10))            // boundsX
        expected.appendBE(Double(20))            // boundsY
        expected.appendBE(Double(1280))          // boundsW
        expected.appendBE(Double(800))           // boundsH
        XCTAssertEqual(ack.encode(), expected)
        XCTAssertEqual(ack.encode().count, 43)
        XCTAssertEqual(ack.encode().first, 2)
        XCTAssertEqual(try VideoControlMessage.decode(ack.encode()), ack)
    }

    /// WF-6 (#8): the `fullRange` byte round-trips for BOTH values, and the ON encoding places a `1`
    /// at the documented position (immediately after captureHeight), with no other body change.
    func testHelloAckFullRangeRoundTrip() throws {
        for fr in [false, true] {
            let ack = VideoControlMessage.helloAck(accepted: true, streamID: 9,
                                                   captureWidth: 640, captureHeight: 480,
                                                   windowBoundsCG: VideoRect(x: 1, y: 2, width: 640, height: 480),
                                                   fullRange: fr)
            XCTAssertEqual(try VideoControlMessage.decode(ack.encode()), ack)
            // Byte index: [0]=type [1]=accepted [2..5]=streamID [6..7]=cw [8..9]=ch [10]=fullRange.
            XCTAssertEqual(ack.encode()[10], fr ? 1 : 0)
        }
    }

    /// `bye` is still a single type byte, value 3.
    func testByeEncodingByteIdentical() throws {
        let bye = VideoControlMessage.bye
        XCTAssertEqual(bye.encode(), Data([3]))
        XCTAssertEqual(bye.encode().count, 1)
        XCTAssertEqual(try VideoControlMessage.decode(bye.encode()), bye)
    }
}
