import XCTest
@testable import AislopdeskVideoProtocol

/// Wire codec for the `streamCadence` control message (type 10, FPS governor 2026-06-11):
/// host → client content-cadence announcement, sent at session start and on every governed fps
/// step (dup ×2). Body = one big-endian UInt16 fps. Pattern of KeepaliveCodecTests /
/// FocusWindowCodecTests: round-trip + truncation + unknown-type tolerance.
final class StreamCadenceCodecTests: XCTestCase {
    func testRoundTripAcrossLadderAndExtremes() throws {
        for fps: UInt16 in [60, 30, 20, 15, 1, 65535] {
            let msg = VideoControlMessage.streamCadence(fps: fps)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testWireLayoutIsTypeBytePlusBigEndianUInt16() {
        let msg = VideoControlMessage.streamCadence(fps: 60)
        XCTAssertEqual(msg.messageType, 10)
        XCTAssertEqual(msg.encode(), Data([10, 0x00, 0x3C]), "type 10 | UInt16 BE fps — exactly 3 bytes")
        XCTAssertEqual(
            VideoControlMessage.streamCadence(fps: 0x0102).encode(),
            Data([10, 0x01, 0x02]),
            "big-endian byte order",
        )
    }

    func testTypeByteIsNextFreeAfterFocusWindow() {
        XCTAssertEqual(VideoControlMessage.focusWindow.messageType, 9)
        XCTAssertEqual(VideoControlMessage.streamCadence(fps: 1).messageType, 10)
    }

    /// A truncated body (type byte alone, or only half the UInt16) THROWS — bounds-checked
    /// decode, never an over-read or a crash.
    func testTruncatedBodyThrows() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([10]))) { error in
            XCTAssertTrue(error is VideoProtocolError, "truncated streamCadence must throw a protocol error")
        }
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([10, 0x00])))
    }

    /// The decoder's `default` arm still drops a type PAST the highest defined (15 = displayMax) as
    /// `.malformed` — the forward-compatibility contract (a future control type claims 16+). Type 15
    /// (displayMax) is now DEFINED, so a bare type byte for it throws `.truncated` (short body), not
    /// `.malformed`; the "unknown type" probe must sit past the max.
    func testUnknownTypePastDefinedStillThrowsMalformed() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([16]))) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("unknown type must throw .malformed, got \(error)")
            }
        }
        // displayMax (type 15) is DEFINED → a bare type byte (no 4-byte body) throws `.truncated`.
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([15]))) { error in
            guard case VideoProtocolError.truncated = error else {
                return XCTFail("short displayMax body must throw .truncated, got \(error)")
            }
        }
    }

    /// Adding case 10 perturbs none of the existing encodings.
    func testExistingCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.bye.encode(), Data([3]))
        XCTAssertEqual(VideoControlMessage.keepalive.encode(), Data([6]))
        XCTAssertEqual(VideoControlMessage.focusWindow.encode(), Data([9]))
        let ra = VideoControlMessage.resizeAck(captureWidth: 800, captureHeight: 600, epoch: 4)
        XCTAssertEqual(try VideoControlMessage.decode(ra.encode()), ra)
    }
}
