// AndroidStreamProtocolTests — the untrusted decoder for `scrcpy`'s stream.
//
// The reassembly is what these lean on hardest, for the reason the decoder's own file comment gives:
// this is a BYTE STREAM, so a header can arrive split down the middle, and a reassembler that gets it
// wrong does not throw — it decodes garbage into a display layer and shows a black rectangle. So every
// framing case here is also fed ONE BYTE AT A TIME and asserted to produce the identical messages.
//
// The fixtures are assembled field by field rather than pasted as one blob, so the meaning of each
// byte is legible where it is asserted.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class AndroidStreamProtocolTests: XCTestCase {
    // MARK: Fixtures

    private func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
    }

    /// A session packet: MSB set, no payload, size at 4 and 8.
    private func sessionPacket(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x80, 0, 0, 0])
        data.append(bigEndian(width))
        data.append(bigEndian(height))
        return data
    }

    /// A media packet: flags in byte 0, PTS ignored, size at 8.
    private func mediaPacket(flags: UInt8, payload: Data) -> Data {
        var data = Data([flags, 0, 0, 0, 0, 0, 0, 0])
        data.append(bigEndian(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    /// Feeds a whole stream in one chunk.
    private func decode(_ stream: Data) -> [AndroidStreamMessage] {
        var parser = AndroidStreamParser()
        return parser.consume(stream)
    }

    /// Feeds the same stream one byte at a time. Any difference from ``decode(_:)`` is a reassembly
    /// bug — which is the class of bug this decoder exists to not have.
    private func decodeByteAtATime(_ stream: Data) -> [AndroidStreamMessage] {
        var parser = AndroidStreamParser()
        var messages: [AndroidStreamMessage] = []
        for byte in stream {
            messages += parser.consume(Data([byte]))
        }
        return messages
    }

    // MARK: The head of the stream

    func testTheCodecIdIsReadOnceAndOnlyOnce() {
        var parser = AndroidStreamParser()
        XCTAssertEqual(parser.consume(Data("h264".utf8)), [.codec("h264")])
        // The next four bytes are a header, not a second codec id.
        XCTAssertEqual(
            parser.consume(sessionPacket(width: 1080, height: 2400)),
            [.session(width: 1080, height: 2400)],
        )
    }

    func testAThreeLetterCodecIsSpelledWithALeadingNul() {
        // `scrcpy` pads `av1` into the four-byte field with a leading NUL. The name is what the
        // caller compares against, so the padding is stripped here rather than at every call site.
        XCTAssertEqual(decode(Data([0x00]) + Data("av1".utf8)), [.codec("av1")])
    }

    func testOnlyTheTwoDecodableCodecsResolve() {
        // AV1 is deliberately not offered: `VTDecompressionSession` gains it only on M3-class
        // hardware, so accepting it would make the panel's ability to show anything depend on which
        // Mac the client runs on.
        XCTAssertEqual(AndroidVideoCodec(streamIdentifier: "h264"), .h264)
        XCTAssertEqual(AndroidVideoCodec(streamIdentifier: "h265"), .h265)
        XCTAssertNil(AndroidVideoCodec(streamIdentifier: "av1"))
    }

    func testAnAllNulCodecIdIsCorruptRatherThanEmpty() {
        var parser = AndroidStreamParser()
        XCTAssertEqual(parser.consume(Data([0, 0, 0, 0])), [])
        XCTAssertTrue(parser.isCorrupt)
    }

    // MARK: Framing

    func testEachHeaderFlagSelectsItsMessage() {
        var stream = Data("h264".utf8)
        stream.append(sessionPacket(width: 460, height: 1024))
        stream.append(mediaPacket(flags: 0x40, payload: Data([0xAA, 0xBB])))
        stream.append(mediaPacket(flags: 0x20, payload: Data([0xCC])))
        stream.append(mediaPacket(flags: 0x00, payload: Data([0xDD])))

        let expected: [AndroidStreamMessage] = [
            .codec("h264"),
            .session(width: 460, height: 1024),
            .configuration(Data([0xAA, 0xBB])),
            .accessUnit(Data([0xCC]), isKeyframe: true),
            .accessUnit(Data([0xDD]), isKeyframe: false),
        ]
        XCTAssertEqual(decode(stream), expected)
        XCTAssertEqual(decodeByteAtATime(stream), expected)
    }

    func testAPacketSplitAcrossReceivesIsHeldUntilItIsWhole() {
        // The failure this prevents: half an access unit handed to CoreMedia as a whole one.
        var parser = AndroidStreamParser()
        _ = parser.consume(Data("h264".utf8))
        let packet = mediaPacket(flags: 0x20, payload: Data(repeating: 0xEE, count: 40))
        XCTAssertEqual(parser.consume(packet.prefix(12 + 39)), [])
        XCTAssertEqual(
            parser.consume(packet.suffix(1)),
            [.accessUnit(Data(repeating: 0xEE, count: 40), isKeyframe: true)],
        )
    }

    func testAHeaderSplitAcrossReceivesIsNotReadEarly() {
        var parser = AndroidStreamParser()
        _ = parser.consume(Data("h264".utf8))
        let session = sessionPacket(width: 1080, height: 2400)
        XCTAssertEqual(parser.consume(session.prefix(11)), [])
        XCTAssertEqual(parser.consume(session.suffix(1)), [.session(width: 1080, height: 2400)])
    }

    func testManyPacketsInOneReceiveAllComeOut() {
        // The ordinary case under load: a 64 KiB read holds several frames.
        var stream = Data("h264".utf8)
        for index in 0..<8 {
            stream.append(mediaPacket(flags: 0, payload: Data([UInt8(index)])))
        }
        XCTAssertEqual(decode(stream).count, 9)
    }

    // MARK: Validate then drop

    func testALengthOfZeroIsCorruptionRatherThanAnEmptyFrame() {
        // `scrcpy`'s own demuxer rejects it outright; a zero here means the stream is no longer where
        // we think it is, and there are no start markers to resynchronise on.
        var parser = AndroidStreamParser()
        _ = parser.consume(Data("h264".utf8))
        XCTAssertEqual(parser.consume(mediaPacket(flags: 0, payload: Data())), [])
        XCTAssertTrue(parser.isCorrupt)
    }

    func testAnAbsurdLengthIsRefusedRatherThanAllocated() {
        // A misaligned header otherwise asks for a multi-gigabyte allocation, which turns a decode
        // bug into a memory panic.
        var parser = AndroidStreamParser()
        _ = parser.consume(Data("h264".utf8))
        var header = Data([0, 0, 0, 0, 0, 0, 0, 0])
        header.append(bigEndian(UInt32(AndroidStreamParser.maximumPacketSize + 1)))
        XCTAssertEqual(parser.consume(header), [])
        XCTAssertTrue(parser.isCorrupt)
    }

    func testACorruptParserStaysSilentForever() {
        // No resynchronisation is attempted, so nothing may leak out afterwards — the connection is
        // torn down and redialled instead.
        var parser = AndroidStreamParser()
        _ = parser.consume(Data([0, 0, 0, 0]))
        XCTAssertTrue(parser.isCorrupt)
        XCTAssertEqual(parser.consume(mediaPacket(flags: 0x20, payload: Data([1]))), [])
    }
}

// MARK: - Annex-B

final class AndroidAnnexBTests: XCTestCase {
    private let fourByte = Data([0, 0, 0, 1])
    private let threeByte = Data([0, 0, 1])

    func testBothStartCodeLengthsAreSplit() {
        // `MediaCodec` writes the 4-byte form ahead of the parameter sets and the first slice and the
        // 3-byte form between the slices of one frame. Handling only the long one yields NALs with
        // `00 00 00 01` buried inside them, which decode as corruption rather than failing.
        var unit = fourByte + Data([0x67, 0x01])
        unit += threeByte + Data([0x68, 0x02])
        unit += fourByte + Data([0x65, 0x03])
        XCTAssertEqual(
            AndroidAnnexB.nalUnits(in: unit),
            [Data([0x67, 0x01]), Data([0x68, 0x02]), Data([0x65, 0x03])],
        )
    }

    func testEveryNalIsRewrittenWithItsFourByteBigEndianLength() {
        let unit = fourByte + Data([0x65, 0xAA, 0xBB]) + threeByte + Data([0x01])
        XCTAssertEqual(
            AndroidAnnexB.avccAccessUnit(from: unit),
            Data([0, 0, 0, 3, 0x65, 0xAA, 0xBB]) + Data([0, 0, 0, 1, 0x01]),
        )
    }

    func testABufferWithNoStartCodeIsRefusedRatherThanPassedThrough() {
        // A payload that is already length-prefixed would be silently mis-framed, and the panel would
        // show a decoder producing nothing with no clue why.
        XCTAssertNil(AndroidAnnexB.avccAccessUnit(from: Data([0x00, 0x00, 0x00, 0x04, 0x65])))
        XCTAssertNil(AndroidAnnexB.avccAccessUnit(from: Data()))
    }

    func testAnEmptyNalBetweenTwoStartCodesIsSkipped() {
        XCTAssertEqual(
            AndroidAnnexB.nalUnits(in: fourByte + fourByte + Data([0x65])), [Data([0x65])],
        )
    }

    func testH264ParameterSetsKeepOnlySpsAndPps() {
        // `CMVideoFormatDescriptionCreateFromH264ParameterSets` rejects the whole set if one member
        // is not a parameter set, and `MediaCodec` is free to put an access unit delimiter or an SEI
        // in the same config buffer.
        var config = fourByte + Data([0x09, 0xF0]) // AUD
        config += fourByte + Data([0x67, 0x64, 0x00]) // SPS
        config += fourByte + Data([0x06, 0x05]) // SEI
        config += fourByte + Data([0x68, 0xEE]) // PPS
        XCTAssertEqual(
            AndroidAnnexB.parameterSets(inConfiguration: config, codec: .h264),
            [Data([0x67, 0x64, 0x00]), Data([0x68, 0xEE])],
        )
    }

    func testH265ReadsItsTypeFromTheOtherBits() {
        // HEVC's NAL type is bits 1..6 of the first header byte, not the low five: 32 VPS, 33 SPS,
        // 34 PPS. Reading it the H.264 way would keep an arbitrary set of slices instead.
        var config = fourByte + Data([32 << 1, 0x01]) // VPS
        config += fourByte + Data([33 << 1, 0x02]) // SPS
        config += fourByte + Data([34 << 1, 0x03]) // PPS
        config += fourByte + Data([1 << 1, 0x04]) // a slice
        XCTAssertEqual(
            AndroidAnnexB.parameterSets(inConfiguration: config, codec: .h265),
            [Data([64, 0x01]), Data([66, 0x02]), Data([68, 0x03])],
        )
    }
}
#endif
