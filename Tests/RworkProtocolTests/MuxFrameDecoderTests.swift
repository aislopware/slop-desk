import XCTest
@testable import RworkProtocol

/// Streaming-splitter tests for `MuxFrameDecoder` — the direct analogue of
/// `FrameDecoderTests` one layer up (mux envelopes instead of WireMessage frames).
final class MuxFrameDecoderTests: XCTestCase {

    /// Three distinct mux frames spanning all the body shapes, used by the framing tests.
    private let frames: [MuxFrame] = [
        .channelOpen(channelID: 1, sessionID: UUID(), lastReceivedSeq: 7, channelClass: 0),
        .channelData(channelID: 1, payload: WireMessage.output(seq: 3, bytes: Data("coalesced ✅".utf8)).encode()),
        .channelClose(channelID: 1),
    ]

    private func concatenatedFrames() -> Data {
        frames.reduce(into: Data()) { $0.append(MuxEnvelopeCodec.encode($1)) }
    }

    func testTwoFramesInOneChunkBothDrain() throws {
        // Two frames coalesced into one append must both drain in order.
        let two: [MuxFrame] = [
            .channelOpenAck(channelID: 3, accepted: true),
            .windowAdjust(channelID: 3, bytesToAdd: 1024),
        ]
        var decoder = MuxFrameDecoder()
        decoder.append(two.reduce(into: Data()) { $0.append(MuxEnvelopeCodec.encode($1)) })

        var decoded: [MuxFrame] = []
        while let frame = try decoder.nextFrame() { decoded.append(frame) }
        XCTAssertEqual(decoded, two)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testThreeFramesInOneAppend() throws {
        var decoder = MuxFrameDecoder()
        decoder.append(concatenatedFrames())

        var decoded: [MuxFrame] = []
        while let frame = try decoder.nextFrame() { decoded.append(frame) }
        XCTAssertEqual(decoded, frames)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testOneFrameSplitAcrossTwoAppends() throws {
        let frame = MuxFrame.channelData(channelID: 5, payload: Data("split across appends".utf8))
        let bytes = MuxEnvelopeCodec.encode(frame)
        let split = bytes.count / 2

        var decoder = MuxFrameDecoder()
        decoder.append(bytes.prefix(split))
        XCTAssertNil(try decoder.nextFrame(), "first half: must wait")

        decoder.append(Data(bytes.suffix(from: bytes.startIndex + split)))
        XCTAssertEqual(try decoder.nextFrame(), frame)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testPartialLengthPrefixBufferedThenCompletes() throws {
        // Feed fewer than 4 prefix bytes: the decoder waits, then completes once the
        // remaining prefix + body arrive.
        let frame = MuxFrame.windowAdjust(channelID: 9, bytesToAdd: 42)
        let bytes = MuxEnvelopeCodec.encode(frame)

        var decoder = MuxFrameDecoder()
        decoder.append(bytes.prefix(2)) // only 2 of the 4 prefix bytes
        XCTAssertNil(try decoder.nextFrame())

        decoder.append(Data(bytes.suffix(from: bytes.startIndex + 2)))
        XCTAssertEqual(try decoder.nextFrame(), frame)
    }

    func testPartialChannelIDPrefixBufferedThenCompletes() throws {
        // Prefix fully present, but the channelID field only partly arrived: still wait.
        let frame = MuxFrame.channelClose(channelID: 0x11223344)
        let bytes = MuxEnvelopeCodec.encode(frame)
        // prefix(4) + 2 of the 4 channelID bytes = 6 bytes buffered.
        let cut = 6

        var decoder = MuxFrameDecoder()
        decoder.append(bytes.prefix(cut))
        XCTAssertNil(try decoder.nextFrame(), "header partially present: must wait")
        // Still nil on a second call with no new bytes.
        XCTAssertNil(try decoder.nextFrame())

        decoder.append(Data(bytes.suffix(from: bytes.startIndex + cut)))
        XCTAssertEqual(try decoder.nextFrame(), frame)
    }

    func testOneByteAtATimeDrainsAllFrames() throws {
        var decoder = MuxFrameDecoder()
        let combined = concatenatedFrames()
        var decoded: [MuxFrame] = []
        for byte in combined {
            decoder.append(Data([byte]))
            while let frame = try decoder.nextFrame() { decoded.append(frame) }
        }
        XCTAssertEqual(decoded, frames)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testFrameTooLargeThrows() {
        let oversized = Rwork.maxFramePayloadLength + 1
        var frame = Data()
        frame.appendBE(UInt32(oversized))

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertThrowsError(try decoder.nextFrame()) { error in
            XCTAssertEqual(error as? RworkError, .frameTooLarge(oversized))
        }
    }

    func testMaxSizePrefixIsAcceptedNotRejected() throws {
        // Guard is `<=`, so a prefix EXACTLY at the cap waits (no body yet), never throws.
        var frame = Data()
        frame.appendBE(UInt32(Rwork.maxFramePayloadLength))

        var decoder = MuxFrameDecoder()
        decoder.append(frame)
        XCTAssertNoThrow(XCTAssertNil(try decoder.nextFrame()))
    }

    func testEmptyAndShortInputsWait() throws {
        var decoder = MuxFrameDecoder()
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(Data())
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(Data([0x00, 0x00])) // fewer than 4 prefix bytes
        XCTAssertNil(try decoder.nextFrame())
    }
}
