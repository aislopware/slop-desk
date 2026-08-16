import XCTest
@testable import SlopDeskFileTransfer

/// The CLIENT end of PATH 4's codec — now a face over `rust/slopdesk-dropd`'s `client` module.
///
/// The layouts are the crate's and are pinned there. What these tests pin is the MAPPING across the
/// door, which is the thing that can be wrong here and nowhere else: which case becomes which type
/// byte, which field lands in the scalar slot and which in the borrowed blob, and which verdict
/// comes back as which Swift error. A swapped `fileSize`/`transferId` argument type-checks and
/// round-trips through the crate's own tests untouched; it shows up as the wrong bytes here.
final class FileTransferCodecTests: XCTestCase {
    func testHelloIsTypeOneFollowedByTheVersion() {
        XCTAssertEqual(Array(FileTransferCodec.encodePayload(.hello(version: 1))), [1, 1])
    }

    func testOfferIsBigEndianWithALengthPrefixedName() {
        let payload = FileTransferCodec.encodePayload(
            .offer(transferId: 7, fileSize: 1234, name: "a.c"),
        )
        var expected: [UInt8] = [2]
        expected += [0, 0, 0, 7] // transferId
        expected += [0, 0, 0, 0, 0, 0, 4, 210] // fileSize = 1234
        expected += [0, 3] // name length
        expected += Array("a.c".utf8)
        XCTAssertEqual(Array(payload), expected)
    }

    func testAUnicodeNameRidesAsItsUTF8ByteCountNotItsCharacterCount() {
        let name = "résumé — café ✨.txt"
        let payload = FileTransferCodec.encodePayload(.offer(transferId: 1, fileSize: 10, name: name))
        let byteCount = Array(name.utf8).count
        XCTAssertGreaterThan(byteCount, name.count)
        XCTAssertEqual(Array(payload.suffix(byteCount)), Array(name.utf8))
        XCTAssertEqual(Array(payload.dropFirst(13).prefix(2)), [UInt8(byteCount >> 8), UInt8(byteCount & 0xFF)])
    }

    func testAChunkIsTheIdFollowedByTheRawBodyIncludingAnEmptyOne() {
        let body = Data([0, 1, 2, 3, 255, 128])
        let payload = FileTransferCodec.encodePayload(.chunk(transferId: 7, data: body))
        XCTAssertEqual(Array(payload), [3, 0, 0, 0, 7] + Array(body))
        XCTAssertEqual(Array(FileTransferCodec.encodePayload(.chunk(transferId: 7, data: Data()))), [3, 0, 0, 0, 7])
    }

    func testFinishAndCancelAreTheirIdAndNothingElse() {
        XCTAssertEqual(Array(FileTransferCodec.encodePayload(.finish(transferId: 1))), [4, 0, 0, 0, 1])
        XCTAssertEqual(Array(FileTransferCodec.encodePayload(.cancel(transferId: 9))), [5, 0, 0, 0, 9])
    }

    func testFramePrefixIsBigEndianPayloadLength() {
        let frame = FileTransferCodec.encodeFrame(.finish(transferId: 1))
        // finish payload = [4][UInt32 transferId] = 5 bytes.
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(frame.count, 4 + 5)
    }

    // MARK: - Decode (host → client)

    func testEveryReplyDecodes() throws {
        XCTAssertEqual(try FileTransferCodec.decodeReplyPayload(Data([6, 1])), .helloAck(accepted: true))
        XCTAssertEqual(try FileTransferCodec.decodeReplyPayload(Data([6, 0])), .helloAck(accepted: false))
        XCTAssertEqual(try FileTransferCodec.decodeReplyPayload(Data([7, 0, 0, 0, 7])), .accept(transferId: 7))
        XCTAssertEqual(try FileTransferCodec.decodeReplyPayload(Data([8, 0, 0, 0, 7])), .complete(transferId: 7))
        var failed = Data([9, 0, 0, 0, 7, 0, 4])
        failed.append(contentsOf: Array("oops".utf8))
        XCTAssertEqual(
            try FileTransferCodec.decodeReplyPayload(failed),
            .failed(transferId: 7, reason: "oops"),
        )
    }

    /// A REQUEST arriving on the client's inbound stream means the peer is not a dropd. It is
    /// rejected as unknown rather than decoded into something to ignore — there is no client-side
    /// decoder for the client's own vocabulary, which is the point of splitting the two enums.
    func testTheClientsOwnVocabularyIsNotDecodableHere() {
        for type in UInt8(1)...UInt8(5) {
            XCTAssertThrowsError(try FileTransferCodec.decodeReplyPayload(Data([type, 0, 0, 0, 0]))) { error in
                XCTAssertEqual(error as? FileTransferCodec.DecodeError, .unknownType(type))
            }
        }
    }

    func testDecodeEmptyThrows() {
        XCTAssertThrowsError(try FileTransferCodec.decodeReplyPayload(Data())) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .empty)
        }
    }

    func testDecodeUnknownTypeThrows() {
        XCTAssertThrowsError(try FileTransferCodec.decodeReplyPayload(Data([200]))) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .unknownType(200))
        }
    }

    func testDecodeTruncatedThrows() {
        // type 9 (failed) needs 4 id bytes + a 2-byte length; give only the type + 2 bytes.
        XCTAssertThrowsError(try FileTransferCodec.decodeReplyPayload(Data([9, 0, 0]))) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .truncated)
        }
    }

    func testDecodeBadUTF8Throws() {
        // failed with a reason length of 1 but an invalid UTF-8 byte (0xFF).
        var payload = Data([9])
        payload.append(contentsOf: [0, 0, 0, 1]) // transferId
        payload.append(contentsOf: [0, 1]) // reasonLen = 1
        payload.append(0xFF)
        XCTAssertThrowsError(try FileTransferCodec.decodeReplyPayload(payload)) { error in
            XCTAssertEqual(error as? FileTransferCodec.DecodeError, .badUTF8)
        }
    }

    /// Every prefix of a well-formed reply must answer rather than trap — the validate-then-drop
    /// contract, checked exhaustively rather than at the two offsets someone thought of.
    func testEveryTruncationOfEveryReplyThrowsRatherThanTraps() {
        var full = Data([9, 0, 0, 0, 3, 0, 5])
        full.append(contentsOf: Array("short".utf8))
        for cut in 1..<full.count {
            XCTAssertThrowsError(try FileTransferCodec.decodeReplyPayload(full.prefix(cut)), "cut \(cut)")
        }
    }
}
