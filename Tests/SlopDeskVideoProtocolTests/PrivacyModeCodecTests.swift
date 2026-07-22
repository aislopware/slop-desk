import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec for the `privacyMode` control message (type 28, privacy blank): client → host toggle
/// for a full-desktop session's display blackout + local-input swallow. Body = one enable byte.
/// Pattern of AudioControlCodecTests: round-trip + exact layout + truncation + unknown-type tolerance.
final class PrivacyModeCodecTests: XCTestCase {
    func testRoundTrip() throws {
        for enabled in [true, false] {
            let msg = VideoControlMessage.privacyMode(enabled: enabled)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testWireLayoutIsTypeBytePlusEnableByte() {
        XCTAssertEqual(VideoControlMessage.privacyMode(enabled: true).messageType, 28)
        XCTAssertEqual(VideoControlMessage.privacyMode(enabled: true).encode(), Data([28, 1]))
        XCTAssertEqual(VideoControlMessage.privacyMode(enabled: false).encode(), Data([28, 0]))
    }

    /// Any non-zero byte decodes as enabled (the wire-bool contract).
    func testNonZeroByteIsEnabled() throws {
        XCTAssertEqual(try VideoControlMessage.decode(Data([28, 0xFF])), .privacyMode(enabled: true))
    }

    func testTypeByteIsNextFreeAfterHostStats() {
        XCTAssertEqual(
            VideoControlMessage.hostStats(rttTenthsMillis: 1, encodeTenthsMillis: 1).messageType, 27,
        )
        XCTAssertEqual(VideoControlMessage.privacyMode(enabled: true).messageType, 28)
    }

    func testTruncatedBodyThrows() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([28]))) { error in
            XCTAssertTrue(error is VideoProtocolError, "truncated privacyMode must throw a protocol error")
        }
    }

    func testUnknownTypePastDefinedStillThrowsMalformed() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([29]))) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("unknown type must throw .malformed, got \(error)")
            }
        }
    }
}
