import XCTest
@testable import SlopDeskVideoProtocol

/// Wire codec + assembly rules for the icon/blob pair (docs/45 Phase 3): type 19 `appIconRequest`
/// (c→h), type 20 `blobChunk` (h→c, the ONE shared blob reply), the shared `BlobAssembler`, the
/// host `BlobChunker`, and image-magic validation.
final class BlobCodecTests: XCTestCase {
    // MARK: Codec

    func testAppIconRequestRoundTripAndLayout() throws {
        let msg = VideoControlMessage.appIconRequest(sizePx: 64, bundleID: "com.mitchellh.ghostty")
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        XCTAssertEqual(msg.messageType, 19)
        var expected = Data([19, 0x00, 0x40, 0x00, 0x15]) // type | u16 sizePx | lp len 21
        expected.append(contentsOf: Array("com.mitchellh.ghostty".utf8))
        XCTAssertEqual(msg.encode(), expected)
    }

    func testBlobChunkRoundTripAndLayout() throws {
        let msg = VideoControlMessage.blobChunk(
            blobKind: 0, blobID: 0x0102_0304_0506_0708, metaA: 64, metaB: 0,
            chunkIndex: 1, chunkCount: 3, bytes: Data([0xAA, 0xBB]),
        )
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        XCTAssertEqual(msg.messageType, 20)
        XCTAssertEqual(
            msg.encode(),
            Data([
                20, 0x00,
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x00, 0x40, 0x00, 0x00,
                0x01, 0x03,
                0x00, 0x02, 0xAA, 0xBB,
            ]),
        )
    }

    func testBlobChunkValidatesSlotAndByteCount() {
        // Invalid slot (index ≥ count) → malformed.
        var bad = Data([20, 0])
        bad.append(contentsOf: [UInt8](repeating: 0, count: 12)) // id + meta
        bad.append(contentsOf: [3, 3, 0, 0]) // chunk 3/3, 0 bytes
        XCTAssertThrowsError(try VideoControlMessage.decode(bad))
        // Claimed byteCount past the datagram end → truncated, never an over-read.
        let msg = VideoControlMessage.blobChunk(
            blobKind: 0, blobID: 1, metaA: 0, metaB: 0, chunkIndex: 0, chunkCount: 1,
            bytes: Data([0x01]),
        )
        var data = msg.encode()
        data[data.count - 3] = 0xFF // byteCount hi-byte → 65281 claimed, 1 available
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }

    func testWindowPreviewRequestRoundTripAndLayout() throws {
        let msg = VideoControlMessage.windowPreviewRequest(windowID: 0xAABB_CCDD, maxWidthPx: 640)
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
        XCTAssertEqual(msg.messageType, 21)
        XCTAssertEqual(msg.encode(), Data([21, 0xAA, 0xBB, 0xCC, 0xDD, 0x02, 0x80]))
        XCTAssertThrowsError(try VideoControlMessage.decode(Data([21, 0x00])), "truncated body throws")
    }

    // MARK: Chunker ↔ assembler round trip

    func testChunkerSplitsAndAssemblerReassemblesByteIdentical() throws {
        let blob = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        let chunks = try XCTUnwrap(BlobChunker.encodedChunks(
            blobKind: BlobAssembler.iconKind, blobID: 42, metaA: 64, metaB: 0, bytes: blob,
        ))
        XCTAssertEqual(chunks.count, 5) // 5000 / 1177 → 5 chunks
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count + 5, VideoPacketizer.maxDatagramSize)
        }
        var assembler = BlobAssembler()
        var complete: BlobAssembler.CompleteBlob?
        for chunk in chunks.shuffled() { // arrival order is UDP's business, not ours
            guard case let .blobChunk(kind, id, a, b, index, count, bytes) =
                try VideoControlMessage.decode(chunk)
            else {
                XCTFail("decoded to a different case")
                return
            }
            if let done = assembler.fold(
                blobKind: kind, blobID: id, metaA: a, metaB: b,
                chunkIndex: index, chunkCount: count, bytes: bytes,
            ) { complete = done }
        }
        XCTAssertEqual(complete?.bytes, blob, "reassembly is byte-identical regardless of arrival order")
        XCTAssertEqual(complete?.metaA, 64)
    }

    func testChunkerRefusesOverCapAndEmptyBlobs() {
        XCTAssertNil(BlobChunker.encodedChunks(
            blobKind: BlobAssembler.iconKind, blobID: 1, metaA: 0, metaB: 0,
            bytes: Data(count: VideoControlMessage.iconBlobMaxBytes + 1),
        ))
        XCTAssertNil(BlobChunker.encodedChunks(
            blobKind: BlobAssembler.iconKind, blobID: 1, metaA: 0, metaB: 0, bytes: Data(),
        ))
    }

    func testAssemblerCapsHostileAccumulationPerKind() {
        // A hostile sender claims kind 0 (32 KB cap) but streams more: the assembly is discarded.
        var assembler = BlobAssembler()
        let chunkBytes = Data(count: VideoControlMessage.blobBytesPerChunk)
        let needed = (VideoControlMessage.iconBlobMaxBytes / chunkBytes.count) + 2
        var completed: BlobAssembler.CompleteBlob?
        for index in 0..<needed {
            completed = assembler.fold(
                blobKind: 0, blobID: 9, metaA: 0, metaB: 0,
                chunkIndex: UInt8(index), chunkCount: UInt8(needed), bytes: chunkBytes,
            )
        }
        XCTAssertNil(completed, "an over-cap assembly never reaches the consumer")
    }

    func testUnknownBlobKindsAssembleToNothing() {
        var assembler = BlobAssembler()
        XCTAssertNil(assembler.fold(
            blobKind: 9, blobID: 1, metaA: 0, metaB: 0, chunkIndex: 0, chunkCount: 1,
            bytes: Data([0x01]),
        ), "future kinds bump the codec first — an unknown kind is dropped, never buffered")
    }

    // MARK: Magic validation + FNV

    func testImageMagicValidation() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertTrue(BlobImageValidator.validates(png, forKind: BlobAssembler.iconKind))
        XCTAssertFalse(BlobImageValidator.validates(jpeg, forKind: BlobAssembler.iconKind))
        XCTAssertTrue(BlobImageValidator.validates(jpeg, forKind: BlobAssembler.previewKind))
        XCTAssertFalse(BlobImageValidator.validates(Data(), forKind: BlobAssembler.previewKind))
    }

    func testFNV1a64IsThePinnedConstant() {
        // Pinned vectors (standard FNV-1a 64): both ends derive the icon blobID independently.
        XCTAssertEqual(BlobChunker.fnv1a64(""), 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual(BlobChunker.fnv1a64("a"), 0xAF63_DC4C_8601_EC8C)
        XCTAssertEqual(BlobChunker.fnv1a64("foobar"), 0x8594_4171_F739_67E8)
    }
}
