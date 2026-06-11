import XCTest
@testable import AislopdeskProtocol

final class FrameDecoderTests: XCTestCase {

    /// Three distinct messages across both channels, used by the framing tests.
    private let messages: [WireMessage] = [
        .output(seq: 7, bytes: Data("partial-read test ✅".utf8)),
        .resize(cols: 120, rows: 40, pxWidth: 0, pxHeight: 0),
        .helloAck(sessionID: UUID(), resumeFromSeq: 9, returningClient: true),
    ]

    private func concatenatedFrames() -> Data {
        messages.reduce(into: Data()) { $0.append($1.encode()) }
    }

    func testPartialReadsOneByteAtATime() throws {
        // Feed the combined buffer ONE byte at a time; assert exactly the 3 messages
        // emerge in order, and nextMessage() returns nil at the end.
        var decoder = FrameDecoder()
        let combined = concatenatedFrames()
        var decoded: [WireMessage] = []

        for byte in combined {
            decoder.append(Data([byte]))
            while let message = try decoder.nextMessage() {
                decoded.append(message)
            }
        }

        XCTAssertEqual(decoded, messages)
        XCTAssertNil(try decoder.nextMessage())
    }

    func testMultipleFramesInOneAppend() throws {
        // Feed all 3 frames in a single append; assert all 3 emerge in order.
        var decoder = FrameDecoder()
        decoder.append(concatenatedFrames())

        var decoded: [WireMessage] = []
        while let message = try decoder.nextMessage() {
            decoded.append(message)
        }

        XCTAssertEqual(decoded, messages)
        XCTAssertNil(try decoder.nextMessage())
    }

    func testOversizedFrameThrowsFrameTooLarge() {
        // Craft a length prefix > 16 MiB. Body never needs to arrive — the prefix
        // alone is rejected.
        let oversized = Aislopdesk.maxFramePayloadLength + 1
        var frame = Data()
        frame.appendBE(UInt32(oversized))

        var decoder = FrameDecoder()
        decoder.append(frame)

        XCTAssertThrowsError(try decoder.nextMessage()) { error in
            XCTAssertEqual(error as? AislopdeskError, .frameTooLarge(oversized))
        }
    }

    func testMaxSizeFramePrefixIsAcceptedNotRejected() throws {
        // The guard is `payloadLength <= maxFramePayloadLength`, so a prefix EXACTLY
        // at the cap must be accepted: with no body yet it should wait (return nil),
        // NOT throw .frameTooLarge. Catches an off-by-one regression to `<`.
        var frame = Data()
        frame.appendBE(UInt32(Aislopdesk.maxFramePayloadLength))

        var decoder = FrameDecoder()
        decoder.append(frame)

        XCTAssertNoThrow(XCTAssertNil(try decoder.nextMessage()))
    }

    func testLargeMultiKBPayloadRoundTrips() throws {
        // Exercise large-payload framing well beyond the few-byte bodies elsewhere.
        let big = Data((0 ..< (256 * 1024)).map { UInt8($0 & 0xFF) }) // 256 KiB
        let message = WireMessage.output(seq: 99, bytes: big)

        var decoder = FrameDecoder()
        decoder.append(message.encode())
        XCTAssertEqual(try decoder.nextMessage(), message)
        XCTAssertNil(try decoder.nextMessage())
    }

    func testUnknownMessageTypeThrows() {
        // Valid frame: payload length 1, type byte 0xFF (no known message).
        var frame = Data()
        frame.appendBE(UInt32(1))
        frame.append(0xFF)

        var decoder = FrameDecoder()
        decoder.append(frame)

        XCTAssertThrowsError(try decoder.nextMessage()) { error in
            XCTAssertEqual(error as? AislopdeskError, .unknownMessageType(0xFF))
        }
    }

    func testTruncatedBodyWaitsRatherThanMisparsing() throws {
        // Length prefix claims N but only N-1 body bytes ever arrive: nextMessage()
        // must return nil (wait) and never mis-parse a short frame.
        let full = WireMessage.exit(code: 256).encode()
        let allButLast = full.prefix(full.count - 1)

        var decoder = FrameDecoder()
        decoder.append(Data(allButLast))

        XCTAssertNil(try decoder.nextMessage())
        // Still nil on a second call without new bytes.
        XCTAssertNil(try decoder.nextMessage())

        // Supplying the final byte completes the frame.
        decoder.append(Data([full.last!]))
        XCTAssertEqual(try decoder.nextMessage(), .exit(code: 256))
    }

    func testEmptyAndZeroLengthInputs() throws {
        var decoder = FrameDecoder()
        // Nothing buffered.
        XCTAssertNil(try decoder.nextMessage())
        // Appending empty data changes nothing.
        decoder.append(Data())
        XCTAssertNil(try decoder.nextMessage())
        // Fewer than 4 prefix bytes: still waiting.
        decoder.append(Data([0x00, 0x00]))
        XCTAssertNil(try decoder.nextMessage())
    }

    func testRemainingFramesSurviveAPartialTrailingFrame() throws {
        // One complete frame followed by a partial second frame: the first decodes,
        // the second waits.
        let first = WireMessage.bell.encode()
        let second = WireMessage.title("incomplete").encode()

        var decoder = FrameDecoder()
        decoder.append(first)
        decoder.append(second.prefix(second.count - 3)) // drop tail of 2nd frame

        XCTAssertEqual(try decoder.nextMessage(), .bell)
        XCTAssertNil(try decoder.nextMessage())

        decoder.append(Data(second.suffix(3)))
        XCTAssertEqual(try decoder.nextMessage(), .title("incomplete"))
    }
}
