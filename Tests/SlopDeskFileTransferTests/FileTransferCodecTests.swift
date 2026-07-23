import XCTest
@testable import SlopDeskFileTransfer

final class FileTransferCodecTests: XCTestCase {
    private func roundTrip(_ message: FileTransferMessage, file: StaticString = #filePath, line: UInt = #line) {
        let payload = FileTransferCodec.encodePayload(message)
        let decoded = try? FileTransferCodec.decodePayload(payload)
        XCTAssertEqual(decoded, message, file: file, line: line)
    }

    func testRoundTripEveryMessage() {
        roundTrip(.hello(version: 1))
        roundTrip(.offer(transferId: 7, fileSize: 123_456_789, name: "report.pdf"))
        roundTrip(.chunk(transferId: 7, data: Data([0, 1, 2, 3, 255, 128])))
        roundTrip(.chunk(transferId: 7, data: Data())) // empty flush
        roundTrip(.finish(transferId: 7))
        roundTrip(.cancel(transferId: 9))
        roundTrip(.helloAck(accepted: true))
        roundTrip(.helloAck(accepted: false))
        roundTrip(.accept(transferId: 7))
        roundTrip(.complete(transferId: 7))
        roundTrip(.failed(transferId: 7, reason: "invalid file name"))
    }

    func testRoundTripUnicodeName() {
        roundTrip(.offer(transferId: 1, fileSize: 10, name: "résumé — café ✨.txt"))
    }

    func testFramePrefixIsBigEndianPayloadLength() {
        let frame = FileTransferCodec.encodeFrame(.finish(transferId: 1))
        // finish payload = [4][UInt32 transferId] = 5 bytes.
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(frame.count, 4 + 5)
    }

    func testDecodeEmptyThrows() {
        XCTAssertThrowsError(try FileTransferCodec.decodePayload(Data())) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .empty)
        }
    }

    func testDecodeUnknownTypeThrows() {
        XCTAssertThrowsError(try FileTransferCodec.decodePayload(Data([200]))) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .unknownType(200))
        }
    }

    func testDecodeTruncatedThrows() {
        // type 2 (offer) needs 4+8+2 header bytes; give only the type + 2 bytes.
        XCTAssertThrowsError(try FileTransferCodec.decodePayload(Data([2, 0, 0]))) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .truncated)
        }
    }

    func testDecodeBadUTF8Throws() {
        // offer with a name length of 1 but an invalid UTF-8 byte (0xFF).
        var payload = Data([2])
        payload.append(contentsOf: [0, 0, 0, 1]) // transferId
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // fileSize
        payload.append(contentsOf: [0, 1]) // nameLen = 1
        payload.append(0xFF)
        XCTAssertThrowsError(try FileTransferCodec.decodePayload(payload)) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .badUTF8)
        }
    }
}
