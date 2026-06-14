import XCTest
@testable import AislopdeskProtocol

/// Encodes a mux frame, feeds the resulting envelope bytes through a fresh
/// `MuxFrameDecoder`, and returns the decoded frame — the canonical round-trip helper
/// (mirrors `WireMessageRoundTripTests.roundTrip`).
private func roundTrip(_ frame: MuxFrame, file _: StaticString = #filePath, line _: UInt = #line) throws -> MuxFrame? {
    var decoder = MuxFrameDecoder()
    decoder.append(MuxEnvelopeCodec.encode(frame))
    return try decoder.nextFrame()
}

final class MuxEnvelopeCodecTests: XCTestCase {
    func testChannelOpenRoundTrip() throws {
        let cases: [MuxFrame] = [
            .channelOpen(channelID: 1, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0, channelClass: 0),
            .channelOpen(channelID: 3, sessionID: UUID(), lastReceivedSeq: Int64.max, channelClass: 7),
            .channelOpen(channelID: UInt32.max, sessionID: UUID(), lastReceivedSeq: -1, channelClass: 255),
        ]
        for frame in cases {
            XCTAssertEqual(try roundTrip(frame), frame)
        }
    }

    func testChannelOpenAckRoundTrip() throws {
        let cases: [MuxFrame] = [
            .channelOpenAck(channelID: 1, accepted: true),
            .channelOpenAck(channelID: 5, accepted: false),
        ]
        for frame in cases {
            XCTAssertEqual(try roundTrip(frame), frame)
        }
    }

    func testChannelCloseRoundTrip() throws {
        for id: UInt32 in [0, 1, 3, UInt32.max] {
            let frame = MuxFrame.channelClose(channelID: id)
            XCTAssertEqual(try roundTrip(frame), frame)
        }
    }

    func testWindowAdjustRoundTrip() throws {
        let cases: [MuxFrame] = [
            .windowAdjust(channelID: 1, bytesToAdd: 0),
            .windowAdjust(channelID: 3, bytesToAdd: 65536),
            .windowAdjust(channelID: 7, bytesToAdd: UInt32.max),
        ]
        for frame in cases {
            XCTAssertEqual(try roundTrip(frame), frame)
        }
    }

    /// The crux of the design: a `channelData` body is OPAQUE — it must survive byte
    /// for byte, including when it happens to be a real (inner) WireMessage frame.
    func testChannelDataBodyRoundTripsByteIdentically() throws {
        let payloads: [Data] = [
            Data(), // empty
            Data("ls -la\n".utf8),
            Data([0x00, 0xFF, 0x80, 0x7F]), // NUL + high bit
            WireMessage.output(seq: 42, bytes: Data("vt output ✅".utf8)).encode(), // a real inner frame
            Data((0..<4096).map { UInt8($0 & 0xFF) }), // 4 KiB
        ]
        for payload in payloads {
            let frame = MuxFrame.channelData(channelID: 9, payload: payload)
            let decoded = try roundTrip(frame)
            XCTAssertEqual(decoded, frame)
            // And the carried bytes are byte-identical (the mux layer never mutated them).
            guard case let .channelData(_, decodedPayload) = decoded else {
                XCTFail("expected channelData, got \(String(describing: decoded))")
                return
            }
            XCTAssertEqual(decodedPayload, payload)
        }
    }

    func testMuxTypeBytesMatchContract() {
        XCTAssertEqual(MuxFrameType.channelOpen.rawValue, 1)
        XCTAssertEqual(MuxFrameType.channelOpenAck.rawValue, 2)
        XCTAssertEqual(MuxFrameType.channelData.rawValue, 3)
        XCTAssertEqual(MuxFrameType.channelClose.rawValue, 4)
        XCTAssertEqual(MuxFrameType.windowAdjust.rawValue, 5)
    }

    /// Envelope layout: `[UInt32 BE muxFrameLength][UInt32 BE channelID][UInt8 muxType][body]`
    /// where muxFrameLength counts channelID(4) + type(1) + body. (Mirrors
    /// `testFrameLayoutLengthPrefixExcludesPrefixBytes`.)
    func testEnvelopeLayoutLengthPrefixExcludesPrefixBytes() {
        // windowAdjust body = 4 bytes => inner = 4 (channelID) + 1 (type) + 4 (body) = 9.
        let frame = MuxFrame.windowAdjust(channelID: 0x0102_0304, bytesToAdd: 0x0A0B_0C0D)
        let bytes = MuxEnvelopeCodec.encode(frame)
        XCTAssertEqual(bytes.count, 4 + 9)
        let prefix = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        XCTAssertEqual(prefix, 9)
        // channelID big-endian right after the prefix.
        XCTAssertEqual(Array(bytes[4..<8]), [0x01, 0x02, 0x03, 0x04])
        // Then the mux-type byte (windowAdjust == 5).
        XCTAssertEqual(bytes[8], MuxFrameType.windowAdjust.rawValue)
    }

    // MARK: Decode error paths (complete-but-invalid inner runs)

    func testUnknownMuxTypeThrows() {
        // inner = [channelID(4)][type 0xFF] — a valid-length run with an unknown type.
        var inner = Data()
        inner.appendBE(UInt32(7)) // channelID
        inner.append(0xFF) // unknown mux type
        var frame = Data()
        frame.appendBE(UInt32(inner.count))
        frame.append(inner)

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? AislopdeskError, .unknownMessageType(0xFF))
        }
    }

    /// A complete frame whose body is shorter than the mux type requires must throw
    /// `.truncated` at decode time (distinct from a partial read, which merely waits).
    func testCompleteFrameWithShortBodyThrowsTruncated() {
        // windowAdjust (type 5) needs a 4-byte UInt32 after channelID+type; supply 2.
        var inner = Data()
        inner.appendBE(UInt32(3)) // channelID
        inner.append(MuxFrameType.windowAdjust.rawValue)
        inner.append(contentsOf: [0x00, 0x10]) // only 2 of 4 body bytes
        var frame = Data()
        frame.appendBE(UInt32(inner.count))
        frame.append(inner)

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    /// An inner run too short to even hold channelID + type must throw `.truncated`.
    func testInnerRunShorterThanHeaderThrowsTruncated() {
        // inner = 3 bytes — fewer than channelID(4); readUInt32 throws .truncated.
        var inner = Data([0x00, 0x00, 0x01])
        var frame = Data()
        frame.appendBE(UInt32(inner.count))
        frame.append(inner)
        inner = Data()

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    /// A channelOpen whose sessionID slot is present but lastReceivedSeq/class are
    /// missing must throw `.truncated` (right type, short body).
    func testChannelOpenShortBodyThrowsTruncated() {
        var inner = Data()
        inner.appendBE(UInt32(1)) // channelID
        inner.append(MuxFrameType.channelOpen.rawValue)
        inner.append(UUID().dataBytes) // 16 sessionID bytes, but then nothing
        var frame = Data()
        frame.appendBE(UInt32(inner.count))
        frame.append(inner)

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? AislopdeskError, .truncated)
        }
    }

    /// A length prefix > maxFramePayloadLength is rejected before any body need arrive.
    func testOversizeFrameThrowsFrameTooLarge() {
        let oversized = Aislopdesk.maxFramePayloadLength + 1
        var frame = Data()
        frame.appendBE(UInt32(oversized))

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? AislopdeskError, .frameTooLarge(oversized))
        }
    }
}
