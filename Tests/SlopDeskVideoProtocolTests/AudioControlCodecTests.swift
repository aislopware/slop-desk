import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec for the `audioControl` control message (type 26, the live per-session audio
/// wish): client → host on/off for the host's app-audio lane. Body = one `UInt8` enable
/// flag. Pattern of StreamSettingsCodecTests: round-trip + exact layout + type adjacency +
/// truncation + unknown-type tolerance. The bool decodes as `byte != 0` like every wire bool.
final class AudioControlCodecTests: XCTestCase {
    func testRoundTripBothStates() throws {
        for enabled in [true, false] {
            let msg = VideoControlMessage.audioControl(enabled: enabled)
            XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        }
    }

    func testWireLayoutIsTypeByteEnabledByte() {
        let on = VideoControlMessage.audioControl(enabled: true)
        XCTAssertEqual(on.messageType, 26)
        XCTAssertEqual(on.encode(), Data([26, 1]), "type 26 | UInt8 enabled — exactly 2 bytes")
        XCTAssertEqual(VideoControlMessage.audioControl(enabled: false).encode(), Data([26, 0]))
    }

    func testTypeByteIsNextFreeAfterStreamSettings() {
        XCTAssertEqual(VideoControlMessage.streamSettings(fpsCap: 0, bitrateCeilingBps: 0).messageType, 25)
        XCTAssertEqual(VideoControlMessage.audioControl(enabled: false).messageType, 26)
    }

    /// Any non-zero enable byte decodes `true` — the `byte != 0` wire-bool contract (a
    /// hand-rolled sender setting 0xFF must not read as OFF).
    func testNonZeroEnabledByteDecodesTrue() throws {
        for byte in [UInt8(2), 0x7F, 0xFF] {
            XCTAssertEqual(
                try VideoControlMessage.decode(Data([26, byte])),
                .audioControl(enabled: true),
            )
        }
    }

    /// A truncated body (bare type byte) THROWS — bounds-checked decode, never an over-read
    /// or a crash (validate-then-drop).
    func testTruncatedBodyThrows() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([26]))) { error in
            guard case VideoProtocolError.truncated = error else {
                return XCTFail("bodyless audioControl must throw .truncated, got \(error)")
            }
        }
    }

    /// The decoder's `default` arm still rejects a type PAST the highest defined (26) as
    /// `.malformed` — the forward-compatibility contract for a future type 27.
    func testUnknownTypePastAudioControlThrowsMalformed() {
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([27]))) { error in
            guard case VideoProtocolError.malformed = error else {
                return XCTFail("unknown type must throw .malformed, got \(error)")
            }
        }
    }

    /// Adding case 26 perturbs none of the existing encodings.
    func testExistingCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.bye.encode(), Data([3]))
        XCTAssertEqual(VideoControlMessage.keepalive.encode(), Data([6]))
        XCTAssertEqual(VideoControlMessage.streamCadence(fps: 60).encode(), Data([10, 0x00, 0x3C]))
        XCTAssertEqual(
            VideoControlMessage.streamSettings(fpsCap: 24, bitrateCeilingBps: 8_000_000).encode(),
            Data([25, 24, 0x00, 0x7A, 0x12, 0x00]),
        )
        let hd = VideoControlMessage.helloDisplay(
            protocolVersion: 1, requestedDisplayID: 7, viewport: VideoSize(width: 800, height: 600),
        )
        XCTAssertEqual(try VideoControlMessage.decode(hd.encode()), hd)
    }
}
