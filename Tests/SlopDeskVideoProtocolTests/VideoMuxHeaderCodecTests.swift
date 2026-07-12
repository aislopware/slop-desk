import XCTest
@testable import SlopDeskVideoProtocol

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
        // 19-byte live FrameFragmentHeader (15-byte base + 4-byte host-send-timestamp) + 4-byte channelID.
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

    // MARK: Send/receive framing pins (copy-elimination)

    // These pin the EXACT wire bytes both transports construct, against an INDEPENDENT manual
    // construction (never the code under test called twice), so the single-allocation send path
    // and the slice-through receive path stay byte-identical to the two-copy originals.

    func testMediaSendShapePinsManualWireBytes() {
        // Media-socket send (host ``NWVideoMuxDatagramTransport/send`` + client
        // ``NWVideoMuxClientFlow/send``): `[UInt32 BE channelID][UInt8 tag][payload...]`.
        let cases: [(channelID: UInt32, tag: UInt8, payload: Data)] = [
            (0x0A0B_0C0D, 4, Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x7F])), // input-shaped
            (1, 0, Data([0x05])), // control bye-shaped
            (.max, 1, Data((0..<1200).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 3) })), // video burst
            (0, 2, Data()), // empty geometry payload
        ]
        for (channelID, tag, payload) in cases {
            // Independent manual construction of the expected wire.
            var expected = Data([
                UInt8(truncatingIfNeeded: channelID >> 24),
                UInt8(truncatingIfNeeded: channelID >> 16),
                UInt8(truncatingIfNeeded: channelID >> 8),
                UInt8(truncatingIfNeeded: channelID),
                tag,
            ])
            expected.append(payload)
            // The OLD two-copy call-site shape (inner = tag + payload, then prefix-encode).
            var inner = Data(capacity: payload.count + 1)
            inner.append(tag)
            inner.append(payload)
            XCTAssertEqual(
                VideoMuxHeaderCodec.encode(channelID: channelID, payload: inner), expected,
                "two-step media framing differs for channelID \(channelID) tag \(tag)",
            )
            // The single-allocation variant the transports now call is byte-identical to both
            // the manual wire and the old two-step shape it replaced.
            XCTAssertEqual(
                VideoMuxHeaderCodec.encodeMedia(channelID: channelID, tag: tag, payload: payload), expected,
                "encodeMedia framing differs for channelID \(channelID) tag \(tag)",
            )
        }
    }

    func testCursorSendShapePinsManualWireBytes() {
        // Cursor-socket send (no tag): `[UInt32 BE channelID][payload...]`.
        let payload = Data([0x00, 0x11, 0x22])
        var expected = Data([0x00, 0x00, 0x00, 0x09])
        expected.append(payload)
        XCTAssertEqual(VideoMuxHeaderCodec.encode(channelID: 9, payload: payload), expected)
        XCTAssertEqual(VideoMuxHeaderCodec.encode(channelID: 9, payload: Data()), Data([0, 0, 0, 9]))
    }

    func testDecodeAcceptsNonzeroStartIndexDatagramSlice() throws {
        // A receive path handing the decoder a SLICE (startIndex > 0) must behave exactly like a
        // freshly-allocated Data — catches any zero-based-index assumption in the reader.
        let payload = Data([0x61, 0x62, 0x63, 0x64])
        let datagram = VideoMuxHeaderCodec.encode(channelID: 7, payload: payload)
        var padded = Data([0xFF, 0xEE, 0xDD])
        padded.append(datagram)
        let slice = padded[(padded.startIndex + 3)...]
        XCTAssertGreaterThan(slice.startIndex, 0, "the fixture must actually exercise a nonzero startIndex")
        let (channelID, rest) = try VideoMuxHeaderCodec.decode(slice)
        XCTAssertEqual(channelID, 7)
        XCTAssertEqual(rest, payload)
    }

    func testTagStrippedSliceFeedsControlDecodeWithoutCopy() throws {
        // The transports' media receive shape: decode → peel the 1-byte tag as a SLICE (no
        // intermediate Data copy) → inner codec decode. Pins that the inner decoders are
        // startIndex-relative.
        var inner = Data([0x00]) // control tag
        inner.append(VideoControlMessage.bye.encode())
        let framed = VideoMuxHeaderCodec.encode(channelID: 3, payload: inner)
        let (channelID, rest) = try VideoMuxHeaderCodec.decode(framed)
        XCTAssertEqual(channelID, 3)
        XCTAssertEqual(rest[rest.startIndex], 0x00)
        let stripped = rest[(rest.startIndex + 1)...]
        XCTAssertEqual(try VideoControlMessage.decode(stripped), .bye)
    }

    func testFrameFragmentDecodeFromTagStrippedSliceKeepsDurablePayloadCopy() throws {
        // Video-lane receive: `[channelID][tag=1][FrameFragment bytes]`. The fragment decoder must
        // (a) be startIndex-relative over the tag-stripped slice, and (b) return a payload that is
        // a DURABLE re-based copy — the one NECESSARY copy — so storing it in the reassembler
        // never pins the whole parent datagram buffer.
        let fragment = FrameFragment(
            header: FrameFragmentHeader(
                streamSeq: 11, frameID: 22, fragIndex: 1, fragCount: 3,
                flags: [.keyframe], payloadLength: 5, hostSendTsMillis: 44,
            ),
            payload: Data([9, 8, 7, 6, 5]),
        )
        var inner = Data([0x01]) // video tag
        inner.append(fragment.encode())
        let framed = VideoMuxHeaderCodec.encode(channelID: 0xFEED_F00D, payload: inner)
        let (channelID, rest) = try VideoMuxHeaderCodec.decode(framed)
        XCTAssertEqual(channelID, 0xFEED_F00D)
        let slice = rest[(rest.startIndex + 1)...]
        XCTAssertGreaterThan(slice.startIndex, 0, "the fixture must actually exercise a nonzero startIndex")
        let decoded = try FrameFragment.decode(slice)
        XCTAssertEqual(decoded, fragment)
        XCTAssertEqual(decoded.payload.startIndex, 0, "fragment payload must be a re-based durable copy")
    }

    func testVideoByteReaderRemainingOverSliceInput() throws {
        // `remaining()` must be startIndex-relative (the reader is routinely constructed over a
        // slice) and consume the reader.
        let backing = Data([0xAA, 1, 2, 3, 4, 5, 6])
        let slice = backing[(backing.startIndex + 1)...]
        var reader = VideoByteReader(slice)
        _ = try reader.readUInt16()
        let rest = reader.remaining()
        XCTAssertEqual(Array(rest), [3, 4, 5, 6])
        XCTAssertEqual(reader.bytesRemaining, 0)
        XCTAssertEqual(reader.remaining(), Data(), "a second remaining() is empty")
    }

    // MARK: Differential — the codec is byte-identical to an independent reference implementation

    /// A framing implementation built independently of `VideoMuxHeaderCodec`
    /// (`appendBE` for encode, `VideoByteReader` for decode), kept ONLY so the differential below can
    /// prove the codec under test matches it byte-for-byte rather than trusting the codec to check itself.
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
                // Encode: the codec's wire output is byte-identical to the independent reference.
                let rust = VideoMuxHeaderCodec.encode(channelID: channelID, payload: payload)
                let native = NativeMuxReference.encode(channelID: channelID, payload: payload)
                XCTAssertEqual(rust, native, "encode differs for channelID \(channelID), \(payload.count)B")

                // Decode the reference-encoded bytes through the codec under test: same channelID +
                // payload as the reference decoder, proving the borrow+offset decode reproduces `remaining()`.
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
