import XCTest
@testable import AislopdeskVideoProtocol

/// UDP-side mux foundation: the channelID-prefix codec + the 19-byte
/// ``MuxFrameFragmentHeader`` round-trips, mirroring the CodecTests / FramePacketizer
/// round-trip + truncation-rejection style. PURE: no socket, no transport.
final class VideoMuxHeaderCodecTests: XCTestCase {
    // MARK: 19-byte muxed fragment header

    func testMuxFrameFragmentHeaderRoundTripIncludesChannelIDAtOffsetZero() throws {
        let cases: [(MuxFrameFragmentHeader, Data)] = [
            (
                MuxFrameFragmentHeader(
                    channelID: 0xDEAD_BEEF, streamSeq: 7, frameID: 42,
                    fragIndex: 3, fragCount: 9, flags: [.keyframe, .crisp], payloadLength: 0,
                ),
                Data((0..<500).map { UInt8(truncatingIfNeeded: $0) }),
            ),
            (
                MuxFrameFragmentHeader(
                    channelID: 1, streamSeq: 0, frameID: 0,
                    fragIndex: 0, fragCount: 1, flags: [], payloadLength: 0,
                ),
                Data(),
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

    func testMuxFrameFragmentHeaderSizeIs23() {
        // 19-byte live FrameFragmentHeader (grew from 15 with the host-send-timestamp) + 4-byte channelID.
        XCTAssertEqual(MuxFrameFragmentHeader.size, 23)
        XCTAssertEqual(MuxFrameFragmentHeader.size, FrameFragmentHeader.size + 4)
    }

    func testMuxMaxPayloadSizeIsDatagramMinus23() {
        XCTAssertEqual(MuxFrameFragmentHeader.maxPayloadSize, VideoPacketizer.maxDatagramSize - 23)
        XCTAssertEqual(
            MuxFrameFragmentHeader.maxPayloadSize,
            VideoPacketizer.maxDatagramSize - MuxFrameFragmentHeader.size,
        )
    }

    func testMuxFrameFragmentHeaderRejectsTruncatedDatagram() {
        // Header claims a 100-byte payload but the datagram ends right after the header.
        let header = MuxFrameFragmentHeader(
            channelID: 5, streamSeq: 1, frameID: 1,
            fragIndex: 0, fragCount: 1, flags: [], payloadLength: 100,
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
        let datagram = VideoMuxHeaderCodec.encode(channelID: 0x0102_0304, payload: payload)
        XCTAssertEqual(datagram.count, VideoMuxHeaderCodec.channelIDLength + payload.count)

        let (channelID, decodedPayload) = try VideoMuxHeaderCodec.decode(datagram)
        XCTAssertEqual(channelID, 0x0102_0304)
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

    // MARK: Frame-fragment framing sizes (the mux wire wraps the 19-byte FrameFragmentHeader)

    func testMuxFrameFragmentHeaderWrapsTheLiveHeader() {
        // The mux frame-fragment header is the 19-byte FrameFragmentHeader (15-byte base + 4-byte
        // host-send-timestamp) prefixed by the 4-byte channelID. Pinning the relationship guards the
        // on-wire framing math.
        XCTAssertEqual(FrameFragmentHeader.size, 19)
        XCTAssertEqual(MuxFrameFragmentHeader.size, FrameFragmentHeader.size + VideoMuxHeaderCodec.channelIDLength)
    }

    func testMuxMediaFramingPrefixesChannelIDBeforeTheTodayTagAndPayload() throws {
        // The mux MEDIA framing both transports use is `[UInt32 channelID][UInt8 tag][payload]` — the
        // channelID PREFIXES the today wire (`[tag][payload]`), so stripping the 4-byte channelID
        // yields the exact OFF-path bytes. This is what makes a single-pane mux run decode-identical
        // to today once the channelID is peeled off (and what a mixed-version OFF receiver misframes).
        let tag: UInt8 = 1 // video
        let inner = Data([tag]) + Data([0xAA, 0xBB, 0xCC])
        let framed = VideoMuxHeaderCodec.encode(channelID: 0x0000_0007, payload: inner)
        let (channelID, rest) = try VideoMuxHeaderCodec.decode(framed)
        XCTAssertEqual(channelID, 7)
        XCTAssertEqual(rest, inner, "peeling the channelID yields the byte-identical today [tag][payload]")
    }

    // MARK: Differential — the Rust-routed codec is byte-identical to the prior native framing

    /// The OLD native framing, reproduced verbatim from the pre-port `VideoMuxHeaderCodec` body
    /// (`appendBE` for encode, `VideoByteReader` for decode). The live `VideoMuxHeaderCodec` now
    /// delegates to the Rust core; this reference exists ONLY so the differential below can prove
    /// the new path is byte-for-byte the same as the framing it replaced.
    private enum NativeMuxReference {
        static func encode(channelID: UInt32, payload: Data) -> Data {
            var out = Data(capacity: 4 + payload.count)
            out.appendBE(channelID)
            out.append(payload)
            return out
        }

        static func decode(_ datagram: Data) throws -> (channelID: UInt32, payload: Data) {
            var reader = VideoByteReader(datagram)
            let channelID = try reader.readUInt32()
            return (channelID, reader.remaining())
        }
    }

    func testRustMuxFramingIsByteIdenticalToTheNativeReference() throws {
        // A corpus spanning channelID edge values (0, 1, max, mixed bytes) × payload shapes (empty,
        // one byte, a 1500-byte burst, a real control/cursor payload).
        let channelIDs: [UInt32] = [0, 1, 7, 0x0102_0304, 0xAABB_CCDD, .max]
        let payloads: [Data] = [
            Data(),
            Data([0xFF]),
            Data((0..<1500).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }),
            VideoControlMessage.bye.encode(),
            CursorUpdate(position: VideoPoint(x: 1920, y: 1080), shapeID: 42, hotspot: VideoPoint(x: 8, y: 8)).encode(),
        ]
        for channelID in channelIDs {
            for payload in payloads {
                // Encode: the Rust-routed wire is byte-identical to the native reference.
                let rust = VideoMuxHeaderCodec.encode(channelID: channelID, payload: payload)
                let native = NativeMuxReference.encode(channelID: channelID, payload: payload)
                XCTAssertEqual(rust, native, "encode differs for channelID \(channelID), \(payload.count)B")

                // Decode the native bytes through the Rust path: same channelID + payload as the
                // native decoder, proving the borrow+offset decode reproduces `remaining()`.
                let (rustID, rustPayload) = try VideoMuxHeaderCodec.decode(native)
                let (nativeID, nativePayload) = try NativeMuxReference.decode(native)
                XCTAssertEqual(rustID, nativeID)
                XCTAssertEqual(rustPayload, nativePayload)
                XCTAssertEqual(rustID, channelID)
                XCTAssertEqual(rustPayload, payload)
            }
        }

        // Truncation parity: both reject a < 4-byte datagram with `.truncated`.
        for short in [Data(), Data([0x01]), Data([0x01, 0x02, 0x03])] {
            XCTAssertThrowsError(try VideoMuxHeaderCodec.decode(short)) { XCTAssertEqual(
                $0 as? VideoProtocolError,
                .truncated,
            ) }
            XCTAssertThrowsError(try NativeMuxReference.decode(short)) { XCTAssertEqual(
                $0 as? VideoProtocolError,
                .truncated,
            ) }
        }
    }
}
