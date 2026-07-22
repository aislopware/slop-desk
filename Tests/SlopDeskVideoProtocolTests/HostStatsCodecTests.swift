import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec for the `hostStats` control message (type 27, stats HUD): host → client echo of the
/// host-side latency halves — smoothed RTT + encode-wall EWMA, both in tenths of a millisecond
/// (`0` = no reading yet). Body = two big-endian UInt16s. Pattern of StreamCadenceCodecTests:
/// round-trip + exact layout + truncation + unknown-type tolerance.
final class HostStatsCodecTests: XCTestCase {
    func testRoundTripAcrossExtremes() throws {
        for (rtt, enc): (UInt16, UInt16) in [(0, 0), (1, 1), (123, 45), (65535, 65535)] {
            let msg = VideoControlMessage.hostStats(rttTenthsMillis: rtt, encodeTenthsMillis: enc)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testWireLayoutIsTypeBytePlusTwoBigEndianUInt16s() {
        let msg = VideoControlMessage.hostStats(rttTenthsMillis: 0x0102, encodeTenthsMillis: 0x0304)
        XCTAssertEqual(msg.messageType, 27)
        XCTAssertEqual(
            msg.encode(),
            Data([27, 0x01, 0x02, 0x03, 0x04]),
            "type 27 | UInt16 BE rttTenths | UInt16 BE encodeTenths — exactly 5 bytes",
        )
    }

    func testTypeByteIsNextFreeAfterAudioControl() {
        XCTAssertEqual(VideoControlMessage.audioControl(enabled: true).messageType, 26)
        XCTAssertEqual(
            VideoControlMessage.hostStats(rttTenthsMillis: 1, encodeTenthsMillis: 1).messageType, 27,
        )
    }

    /// A truncated body (type byte alone, or only the first UInt16) THROWS — bounds-checked
    /// decode, never an over-read or a crash.
    func testTruncatedBodyThrows() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([27]))) { error in
            XCTAssertTrue(error is VideoProtocolError, "truncated hostStats must throw a protocol error")
        }
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([27, 0x00, 0x01])))
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([27, 0x00, 0x01, 0x02])))
    }

    /// The decoder's `default` arm still drops a type PAST the highest defined (28 = privacyMode) as
    /// `.malformed` — the forward-compatibility contract (a future control type claims 29+).
    func testUnknownTypePastDefinedStillThrowsMalformed() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([29]))) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("unknown type must throw .malformed, got \(error)")
            }
        }
    }

    /// Adding case 27 perturbs none of the existing encodings.
    func testExistingCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.audioControl(enabled: true).encode(), Data([26, 1]))
        let sc = VideoControlMessage.streamCadence(fps: 60)
        XCTAssertEqual(try VideoControlMessage.decode(sc.encode()), sc)
    }
}
