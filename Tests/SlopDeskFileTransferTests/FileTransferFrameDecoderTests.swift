import XCTest
@testable import SlopDeskFileTransfer

/// The client's inbound splitter — now a handle onto `rust/slopdesk-dropd`'s `ReplyFrameDecoder`.
///
/// What is pinned here is the FACE: a partial frame answers `nil` rather than throwing, a verdict
/// becomes the Swift error that names it, the arena carries a reason string out, and the handle
/// stays poisoned across calls. The buffering, compaction and byte layout are the crate's, tested
/// there. The frames these tests feed are still hand-assembled dropd bytes rather than something
/// this module encoded: a splitter tested against its own encoder proves the pair agree, not that
/// either is right.
final class FileTransferFrameDecoderTests: XCTestCase {
    private func frame(_ payload: [UInt8]) -> Data {
        var out = Data([0, 0, 0, UInt8(payload.count)])
        out.append(contentsOf: payload)
        return out
    }

    func testWholeFrame() throws {
        let decoder = FileTransferFrameDecoder()
        decoder.append(frame([8, 0, 0, 0, 3]))
        XCTAssertEqual(try decoder.nextReply(), .complete(transferId: 3))
        XCTAssertNil(try decoder.nextReply())
    }

    func testMultipleFramesInOneChunk() throws {
        let decoder = FileTransferFrameDecoder()
        var bytes = Data()
        bytes.append(frame([6, 1]))
        bytes.append(frame([7, 0, 0, 0, 5]))
        bytes.append(frame([8, 0, 0, 0, 5]))
        decoder.append(bytes)
        XCTAssertEqual(try decoder.nextReply(), .helloAck(accepted: true))
        XCTAssertEqual(try decoder.nextReply(), .accept(transferId: 5))
        XCTAssertEqual(try decoder.nextReply(), .complete(transferId: 5))
        XCTAssertNil(try decoder.nextReply())
    }

    func testFrameSplitAcrossReads() throws {
        let decoder = FileTransferFrameDecoder()
        var payload: [UInt8] = [9, 0, 0, 0, 1, 0, 5]
        payload += Array("oops!".utf8)
        let bytes = frame(payload)
        // Feed one byte at a time; only the final byte completes the frame.
        for (index, byte) in bytes.enumerated() {
            decoder.append(Data([byte]))
            if index < bytes.count - 1 {
                XCTAssertNil(try decoder.nextReply(), "frame completed early at byte \(index)")
            }
        }
        XCTAssertEqual(try decoder.nextReply(), .failed(transferId: 1, reason: "oops!"))
    }

    func testOversizeFramePoisons() {
        let decoder = FileTransferFrameDecoder()
        // A length prefix just over the cap; the body never needs to arrive.
        let tooBig = UInt32(FileTransferProtocolConstants.maxFramePayloadLength + 1)
        var bytes = Data([
            UInt8((tooBig >> 24) & 0xFF),
            UInt8((tooBig >> 16) & 0xFF),
            UInt8((tooBig >> 8) & 0xFF),
            UInt8(tooBig & 0xFF),
        ])
        bytes.append(6) // start of a payload
        decoder.append(bytes)
        XCTAssertThrowsError(try decoder.nextReply()) { error in
            XCTAssertEqual(error as? FileTransferFrameDecoderError, .frameTooLarge(Int(tooBig)))
        }
        // Poisoned: further appends are dropped and nextReply keeps rethrowing.
        decoder.append(frame([8, 0, 0, 0, 1]))
        XCTAssertEqual(decoder.bufferedByteCountForTesting, 0)
        XCTAssertThrowsError(try decoder.nextReply())
    }

    func testMalformedPayloadPoisons() {
        let decoder = FileTransferFrameDecoder()
        // A well-framed but unknown-type payload (length 1, type 200).
        decoder.append(Data([0, 0, 0, 1, 200]))
        XCTAssertThrowsError(try decoder.nextReply())
        XCTAssertThrowsError(try decoder.nextReply()) // still poisoned
    }
}
