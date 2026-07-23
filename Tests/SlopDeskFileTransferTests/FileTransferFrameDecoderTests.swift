import XCTest
@testable import SlopDeskFileTransfer

final class FileTransferFrameDecoderTests: XCTestCase {
    func testWholeFrame() throws {
        var decoder = FileTransferFrameDecoder()
        decoder.append(FileTransferCodec.encodeFrame(.finish(transferId: 3)))
        XCTAssertEqual(try decoder.nextMessage(), .finish(transferId: 3))
        XCTAssertNil(try decoder.nextMessage())
    }

    func testMultipleFramesInOneChunk() throws {
        var decoder = FileTransferFrameDecoder()
        var bytes = Data()
        bytes.append(FileTransferCodec.encodeFrame(.hello(version: 1)))
        bytes.append(FileTransferCodec.encodeFrame(.accept(transferId: 5)))
        bytes.append(FileTransferCodec.encodeFrame(.complete(transferId: 5)))
        decoder.append(bytes)
        XCTAssertEqual(try decoder.nextMessage(), .hello(version: 1))
        XCTAssertEqual(try decoder.nextMessage(), .accept(transferId: 5))
        XCTAssertEqual(try decoder.nextMessage(), .complete(transferId: 5))
        XCTAssertNil(try decoder.nextMessage())
    }

    func testFrameSplitAcrossReads() throws {
        var decoder = FileTransferFrameDecoder()
        let frame = FileTransferCodec.encodeFrame(.offer(transferId: 1, fileSize: 42, name: "a.txt"))
        // Feed one byte at a time; only the final byte completes the frame.
        for (i, byte) in frame.enumerated() {
            decoder.append(Data([byte]))
            if i < frame.count - 1 {
                XCTAssertNil(try decoder.nextMessage(), "frame completed early at byte \(i)")
            }
        }
        XCTAssertEqual(try decoder.nextMessage(), .offer(transferId: 1, fileSize: 42, name: "a.txt"))
    }

    func testChunkBodyPreserved() throws {
        var decoder = FileTransferFrameDecoder()
        let body = Data((0..<1000).map { UInt8($0 % 256) })
        decoder.append(FileTransferCodec.encodeFrame(.chunk(transferId: 2, data: body)))
        XCTAssertEqual(try decoder.nextMessage(), .chunk(transferId: 2, data: body))
    }

    func testOversizeFramePoisons() {
        var decoder = FileTransferFrameDecoder()
        // A length prefix just over the cap; the body never needs to arrive.
        let tooBig = UInt32(FileTransferProtocolConstants.maxFramePayloadLength + 1)
        var bytes = Data([
            UInt8((tooBig >> 24) & 0xFF),
            UInt8((tooBig >> 16) & 0xFF),
            UInt8((tooBig >> 8) & 0xFF),
            UInt8(tooBig & 0xFF),
        ])
        bytes.append(1) // start of a payload
        decoder.append(bytes)
        XCTAssertThrowsError(try decoder.nextMessage()) { error in
            XCTAssertEqual(error as? FileTransferFrameDecoderError, .frameTooLarge(Int(tooBig)))
        }
        // Poisoned: further appends are dropped and nextMessage keeps rethrowing.
        decoder.append(FileTransferCodec.encodeFrame(.finish(transferId: 1)))
        XCTAssertEqual(decoder.bufferedByteCountForTesting, 0)
        XCTAssertThrowsError(try decoder.nextMessage())
    }

    func testMalformedPayloadPoisons() {
        var decoder = FileTransferFrameDecoder()
        // A well-framed but unknown-type payload (length 1, type 200).
        decoder.append(Data([0, 0, 0, 1, 200]))
        XCTAssertThrowsError(try decoder.nextMessage())
        XCTAssertThrowsError(try decoder.nextMessage()) // still poisoned
    }
}
