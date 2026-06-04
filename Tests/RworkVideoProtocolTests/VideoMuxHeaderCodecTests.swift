import XCTest
@testable import RworkVideoProtocol

/// UDP-side mux foundation: the channelID-prefix codec + the 19-byte
/// ``MuxFrameFragmentHeader`` round-trips, mirroring the CodecTests / FramePacketizer
/// round-trip + truncation-rejection style. PURE: no socket, no transport.
final class VideoMuxHeaderCodecTests: XCTestCase {

    // MARK: 19-byte muxed fragment header

    func testMuxFrameFragmentHeaderRoundTripIncludesChannelIDAtOffsetZero() throws {
        let cases: [(MuxFrameFragmentHeader, Data)] = [
            (
                MuxFrameFragmentHeader(
                    channelID: 0xDEADBEEF, streamSeq: 7, frameID: 42,
                    fragIndex: 3, fragCount: 9, flags: [.keyframe, .crisp], payloadLength: 0
                ),
                Data((0 ..< 500).map { UInt8(truncatingIfNeeded: $0) })
            ),
            (
                MuxFrameFragmentHeader(
                    channelID: 1, streamSeq: 0, frameID: 0,
                    fragIndex: 0, fragCount: 1, flags: [], payloadLength: 0
                ),
                Data()
            ),
        ]
        for (header, payload) in cases {
            let encoded = header.encode(payload: payload)
            // channelID is the leading big-endian UInt32 (offset 0).
            XCTAssertEqual(Array(encoded.prefix(4)), [
                UInt8(truncatingIfNeeded: header.channelID >> 24),
                UInt8(truncatingIfNeeded: header.channelID >> 16),
                UInt8(truncatingIfNeeded: header.channelID >> 8),
                UInt8(truncatingIfNeeded: header.channelID),
            ], "channelID must be the BE UInt32 at offset 0")

            let (decodedHeader, decodedPayload) = try MuxFrameFragmentHeader.decode(encoded)
            // payloadLength on the wire reflects the actual payload bytes written.
            var expected = header
            expected.payloadLength = UInt16(payload.count)
            XCTAssertEqual(decodedHeader, expected)
            XCTAssertEqual(decodedPayload, payload)
        }
    }

    func testMuxFrameFragmentHeaderSizeIs19() {
        XCTAssertEqual(MuxFrameFragmentHeader.size, 19)
        XCTAssertEqual(MuxFrameFragmentHeader.size, FrameFragmentHeader.size + 4)
    }

    func testMuxMaxPayloadSizeIsDatagramMinus19() {
        XCTAssertEqual(MuxFrameFragmentHeader.maxPayloadSize, VideoPacketizer.maxDatagramSize - 19)
        XCTAssertEqual(MuxFrameFragmentHeader.maxPayloadSize, VideoPacketizer.maxDatagramSize - MuxFrameFragmentHeader.size)
    }

    func testMuxFrameFragmentHeaderRejectsTruncatedDatagram() {
        // Header claims a 100-byte payload but the datagram ends right after the header.
        let header = MuxFrameFragmentHeader(
            channelID: 5, streamSeq: 1, frameID: 1,
            fragIndex: 0, fragCount: 1, flags: [], payloadLength: 100
        )
        var bytes = Data()
        bytes.appendBE(header.channelID)
        bytes.appendBE(header.streamSeq)
        bytes.appendBE(header.frameID)
        bytes.appendBE(header.fragIndex)
        bytes.appendBE(header.fragCount)
        bytes.append(header.flags.rawValue)
        bytes.appendBE(header.payloadLength) // promises 100 bytes that never follow
        XCTAssertThrowsError(try MuxFrameFragmentHeader.decode(bytes)) { error in
            XCTAssertEqual(error as? VideoProtocolError, .truncated)
        }
    }

    func testMuxFrameFragmentHeaderRejectsShortHeader() {
        // Fewer than 19 header bytes → truncated before the fixed fields are read.
        XCTAssertThrowsError(try MuxFrameFragmentHeader.decode(Data([0x00, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? VideoProtocolError, .truncated)
        }
    }

    // MARK: channelID-prefix codec (control / cursor lanes)

    func testChannelIDPrefixRoundTripForControlPayload() throws {
        let payload = VideoControlMessage.bye.encode()
        let datagram = VideoMuxHeaderCodec.encode(channelID: 0x01020304, payload: payload)
        XCTAssertEqual(datagram.count, VideoMuxHeaderCodec.channelIDLength + payload.count)

        let (channelID, decodedPayload) = try VideoMuxHeaderCodec.decode(datagram)
        XCTAssertEqual(channelID, 0x01020304)
        XCTAssertEqual(decodedPayload, payload)
        // The carried payload is opaque — it still decodes as the original control message.
        XCTAssertEqual(try VideoControlMessage.decode(decodedPayload), .bye)
    }

    func testChannelIDPrefixRoundTripForCursorPayload() throws {
        let cursor = CursorUpdate(position: VideoPoint(x: 1920, y: 1080), shapeID: 42, hotspot: VideoPoint(x: 8, y: 8))
        let payload = cursor.encode()
        let datagram = VideoMuxHeaderCodec.encode(channelID: 9, payload: payload)

        let (channelID, decodedPayload) = try VideoMuxHeaderCodec.decode(datagram)
        XCTAssertEqual(channelID, 9)
        XCTAssertEqual(try CursorUpdate.decode(decodedPayload), cursor)
    }

    func testChannelIDPrefixAllowsEmptyPayload() throws {
        let datagram = VideoMuxHeaderCodec.encode(channelID: 7, payload: Data())
        let (channelID, payload) = try VideoMuxHeaderCodec.decode(datagram)
        XCTAssertEqual(channelID, 7)
        XCTAssertEqual(payload, Data())
    }

    func testChannelIDPrefixRejectsTruncatedDatagram() {
        // Fewer than the 4 channelID bytes → truncated.
        XCTAssertThrowsError(try VideoMuxHeaderCodec.decode(Data([0x00, 0x00, 0x00]))) { error in
            XCTAssertEqual(error as? VideoProtocolError, .truncated)
        }
        XCTAssertThrowsError(try VideoMuxHeaderCodec.decode(Data())) { error in
            XCTAssertEqual(error as? VideoProtocolError, .truncated)
        }
    }

    // MARK: RWORK_VIDEO_MUX gate (shared client+host parse, spec §5 / constraint #2)

    func testGateUnsetIsOff() {
        // The load-bearing OFF default: an unset var leaves both ends on the 15-byte path.
        XCTAssertFalse(VideoMuxGate.enabledFromEnvironment([:]))
    }

    func testGateTruthyVocabularyMatchesTCPSide() {
        for on in ["1", "true", "TRUE", "yes", "On"] {
            XCTAssertTrue(VideoMuxGate.enabledFromEnvironment(["RWORK_VIDEO_MUX": on]), "\(on) → ON")
        }
        for off in ["0", "false", "no", "off", ""] {
            XCTAssertFalse(VideoMuxGate.enabledFromEnvironment(["RWORK_VIDEO_MUX": off]), "\(off) → OFF")
        }
    }

    // MARK: OFF-path framing tripwire (constraint #1 byte-identity)

    func testOffPathFrameFragmentHeaderStaysFifteenBytes() {
        // The OFF path emits the unchanged 15-byte FrameFragmentHeader. If this size ever drifts, an
        // OFF-path receiver would misframe — the 19↔15 wire-break would have leaked into the OFF
        // path. Pinning it here guards the byte-identity invariant.
        XCTAssertEqual(FrameFragmentHeader.size, 15)
        XCTAssertEqual(MuxFrameFragmentHeader.size, FrameFragmentHeader.size + VideoMuxHeaderCodec.channelIDLength)
    }

    func testMuxMediaFramingPrefixesChannelIDBeforeTheTodayTagAndPayload() throws {
        // The mux MEDIA framing both transports use is `[UInt32 channelID][UInt8 tag][payload]` — the
        // channelID PREFIXES the today wire (`[tag][payload]`), so stripping the 4-byte channelID
        // yields the exact OFF-path bytes. This is what makes a single-pane mux run decode-identical
        // to today once the channelID is peeled off (and what a mixed-version OFF receiver misframes).
        let tag: UInt8 = 1 // video
        let inner = Data([tag]) + Data([0xAA, 0xBB, 0xCC])
        let framed = VideoMuxHeaderCodec.encode(channelID: 0x00000007, payload: inner)
        let (channelID, rest) = try VideoMuxHeaderCodec.decode(framed)
        XCTAssertEqual(channelID, 7)
        XCTAssertEqual(rest, inner, "peeling the channelID yields the byte-identical today [tag][payload]")
    }
}
