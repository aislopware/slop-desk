import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec for the `streamSettings` control message (type 25, live per-session stream
/// controls): client → host fps cap + bitrate ceiling, `0` = auto on either axis. Body =
/// `UInt8 fpsCap` + big-endian `UInt32 bitrateCeilingBps`. Pattern of StreamCadenceCodecTests:
/// round-trip + exact layout + truncation + unknown-type tolerance. Out-of-range VALUES are a
/// host-apply concern (`UserStreamSettingsPolicy`), not a decode concern — decode rejects only a
/// malformed length.
final class StreamSettingsCodecTests: XCTestCase {
    func testRoundTripAcrossExtremes() throws {
        let probes: [(UInt8, UInt32)] = [
            (0, 0), // both auto
            (24, 8_000_000), // typical user request
            (5, 500_000), // both at the host clamp floor
            (120, 200_000_000), // both at the host clamp ceiling
            (255, UInt32.max), // wire extremes (host clamps on apply)
        ]
        for (fpsCap, ceiling) in probes {
            let msg = VideoControlMessage.streamSettings(fpsCap: fpsCap, bitrateCeilingBps: ceiling)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testWireLayoutIsTypeByteFpsCapByteBigEndianUInt32() {
        let msg = VideoControlMessage.streamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000)
        XCTAssertEqual(msg.messageType, 25)
        XCTAssertEqual(
            msg.encode(),
            Data([25, 24, 0x00, 0x7A, 0x12, 0x00]),
            "type 25 | UInt8 fpsCap | UInt32 BE bitrateCeilingBps — exactly 6 bytes",
        )
        XCTAssertEqual(
            VideoControlMessage.streamSettings(fpsCap: 1, bitrateCeilingBps: 0x0102_0304).encode(),
            Data([25, 1, 0x01, 0x02, 0x03, 0x04]),
            "big-endian byte order",
        )
    }

    func testTypeByteIsNextFreeAfterHelloDisplay() {
        XCTAssertEqual(
            VideoControlMessage.helloDisplay(
                protocolVersion: 1, requestedDisplayID: 0, viewport: VideoSize(width: 1, height: 1),
            ).messageType,
            24,
        )
        XCTAssertEqual(VideoControlMessage.streamSettings(fpsCap: 0, bitrateCeilingBps: 0).messageType, 25)
    }

    /// A truncated body (bare type byte, cap byte only, or a partial UInt32) THROWS —
    /// bounds-checked decode, never an over-read or a crash (validate-then-drop).
    func testTruncatedBodyThrows() {
        for short in [
            Data([25]),
            Data([25, 30]),
            Data([25, 30, 0x00]),
            Data([25, 30, 0x00, 0x7A, 0x12]),
        ] {
            XCTAssertThrowsError(try VideoControlMessage.decode(short)) { error in
                guard case VideoProtocolError.truncated = error else {
                    return XCTFail("short streamSettings body must throw .truncated, got \(error)")
                }
            }
        }
    }

    /// The decoder's `default` arm still rejects a type PAST the highest defined (26,
    /// `audioControl`) as `.malformed` — the forward-compatibility contract for a future type 27.
    func testUnknownTypePastStreamSettingsThrowsMalformed() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([27]))) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("unknown type must throw .malformed, got \(error)")
            }
        }
    }

    /// Adding case 25 perturbs none of the existing encodings.
    func testExistingCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.bye.encode(), Data([3]))
        XCTAssertEqual(VideoControlMessage.keepalive.encode(), Data([6]))
        XCTAssertEqual(VideoControlMessage.streamCadence(fps: 60).encode(), Data([10, 0x00, 0x3C]))
        let hd = VideoControlMessage.helloDisplay(
            protocolVersion: 1, requestedDisplayID: 7, viewport: VideoSize(width: 800, height: 600),
        )
        XCTAssertEqual(try VideoControlMessage.decode(hd.encode()), hd)
    }
}
