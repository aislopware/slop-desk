import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + hostile-decode for the window-snapshot preview pair (MERIDIAN C4):
/// `windowPreviewRequest` (type 16, client→host, session-less) and `windowPreviewChunk`
/// (type 17, host→client, chunked JPEG), plus the pure chunker/assembler that carries the
/// image across the unpacketized control channel. Untrusted-UDP discipline throughout:
/// a corrupt/mismatching datagram DROPS, never crashes or over-allocates.
final class WindowPreviewCodecTests: XCTestCase {
    // MARK: windowPreviewRequest (type 16)

    func testPreviewRequestRoundTripPreservesEveryField() throws {
        let msg = VideoControlMessage.windowPreviewRequest(windowID: 0xDEAD_BEEF, maxEdge: 320, token: 7)
        XCTAssertEqual(msg.messageType, 16)
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
    }

    func testPreviewRequestTruncatedBodyThrows() {
        var data = Data([16])
        data.appendBE(UInt32(42)) // windowID, then nothing — maxEdge/token missing
        XCTAssertThrowsError(try VideoControlMessage.decode(data))
    }

    // MARK: windowPreviewChunk (type 17)

    func testPreviewChunkRoundTripPreservesEveryField() throws {
        let msg = VideoControlMessage.windowPreviewChunk(
            token: 9,
            windowID: 604,
            imageWidth: 320,
            imageHeight: 200,
            chunkIndex: 2,
            chunkCount: 5,
            payload: Data([0xFF, 0xD8, 0x00, 0x41]),
        )
        XCTAssertEqual(msg.messageType, 17)
        XCTAssertEqual(try VideoControlMessage.decode(msg.encode()), msg)
    }

    func testPreviewChunkPayloadLengthOverrunsDatagramThrows() {
        var data = Data([17])
        data.appendBE(UInt32(9)) // token
        data.appendBE(UInt32(604)) // windowID
        data.appendBE(UInt16(320)) // imageWidth
        data.appendBE(UInt16(200)) // imageHeight
        data.appendBE(UInt16(0)) // chunkIndex
        data.appendBE(UInt16(1)) // chunkCount
        data.appendBE(UInt16(9999)) // payloadLen = 9999 but no bytes follow
        XCTAssertThrowsError(
            try VideoControlMessage.decode(data),
            "an oversized payload length prefix must throw, not over-read",
        )
    }

    // MARK: chunker — pure split

    func testChunkerSplitsAtPayloadMaxWithShortTail() throws {
        let payloadMax = VideoControlMessage.previewChunkPayloadMax
        let jpeg = Data(repeating: 0xAB, count: payloadMax * 2 + 100)
        let chunks = try XCTUnwrap(WindowPreviewChunker.chunks(
            token: 1, windowID: 2, imageWidth: 320, imageHeight: 200, jpeg: jpeg,
        ))
        XCTAssertEqual(chunks.count, 3)
        for (index, chunk) in chunks.enumerated() {
            guard case let .windowPreviewChunk(token, windowID, iw, ih, chunkIndex, chunkCount, payload) = chunk
            else {
                XCTFail("chunker must emit windowPreviewChunk")
                return
            }
            XCTAssertEqual(token, 1)
            XCTAssertEqual(windowID, 2)
            XCTAssertEqual(iw, 320)
            XCTAssertEqual(ih, 200)
            XCTAssertEqual(Int(chunkIndex), index)
            XCTAssertEqual(chunkCount, 3)
            XCTAssertEqual(payload.count, index == 2 ? 100 : payloadMax, "only the FINAL chunk is short")
        }
    }

    func testChunkerRefusesOversizedAndEmptyImages() {
        let tooBig = Data(
            repeating: 0,
            count: VideoControlMessage.previewChunkPayloadMax * VideoControlMessage.previewChunkCountMax + 1,
        )
        XCTAssertNil(
            WindowPreviewChunker.chunks(token: 1, windowID: 2, imageWidth: 1, imageHeight: 1, jpeg: tooBig),
            "an image over the chunk-count budget is refused (the caller re-encodes smaller)",
        )
        XCTAssertNil(WindowPreviewChunker.chunks(token: 1, windowID: 2, imageWidth: 1, imageHeight: 1, jpeg: Data()))
    }

    func testChunkerHandlesNonZeroBasedSlice() throws {
        // Data slices keep their parent's indices; the chunker must re-base or the first chunk
        // subscripts out of range.
        let parent = Data(repeating: 0xCD, count: 500)
        let slice = parent.dropFirst(100)
        let chunks = try XCTUnwrap(WindowPreviewChunker.chunks(
            token: 1, windowID: 2, imageWidth: 8, imageHeight: 8, jpeg: slice,
        ))
        guard case let .windowPreviewChunk(_, _, _, _, _, _, payload) = chunks[0]
        else {
            XCTFail("expected a chunk")
            return
        }
        XCTAssertEqual(payload.count, 400)
    }

    // MARK: assembler — reassembly, loss, and hostile chunks

    private func assembled(_ jpeg: Data, shuffle: Bool = false) -> WindowPreviewAssembler.Image? {
        guard var chunks = WindowPreviewChunker.chunks(
            token: 77, windowID: 5, imageWidth: 256, imageHeight: 160, jpeg: jpeg,
        ) else { return nil }
        if shuffle { chunks.reverse() }
        var assembler = WindowPreviewAssembler(token: 77)
        var result: WindowPreviewAssembler.Image?
        for chunk in chunks {
            if let image = assembler.feed(chunk) { result = image }
        }
        return result
    }

    func testAssemblerRoundTripsChunkerOutputEvenOutOfOrder() {
        let jpeg = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) })
        for shuffle in [false, true] {
            let image = assembled(jpeg, shuffle: shuffle)
            XCTAssertEqual(image?.data, jpeg, "reassembly is byte-exact (shuffled: \(shuffle))")
            XCTAssertEqual(image?.width, 256)
            XCTAssertEqual(image?.height, 160)
        }
    }

    func testAssemblerStaysIncompleteOnLossAndDuplicatesAreIdempotent() throws {
        let jpeg = Data(repeating: 0x11, count: VideoControlMessage.previewChunkPayloadMax * 3)
        let chunks = try XCTUnwrap(WindowPreviewChunker.chunks(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4, jpeg: jpeg,
        ))
        var assembler = WindowPreviewAssembler(token: 1)
        XCTAssertNil(assembler.feed(chunks[0]))
        XCTAssertNil(assembler.feed(chunks[0]), "a duplicate chunk never completes the image")
        XCTAssertNil(assembler.feed(chunks[2]), "with chunk 1 lost the image never completes")
        XCTAssertNotNil(assembler.feed(chunks[1]), "the late chunk completes it")
    }

    func testAssemblerDropsForeignTokenAndMismatchedGeometry() throws {
        // A TWO-chunk genuine image, so the first genuine chunk pins geometry without completing.
        let jpeg = Data(repeating: 0x22, count: VideoControlMessage.previewChunkPayloadMax + 100)
        let good = try XCTUnwrap(WindowPreviewChunker.chunks(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4, jpeg: jpeg,
        ))
        XCTAssertEqual(good.count, 2)
        var assembler = WindowPreviewAssembler(token: 1)
        XCTAssertNil(assembler.feed(good[0]), "first genuine chunk pins geometry, image incomplete")
        // A straggler from an EARLIER request (different token) must not be stitched in.
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 99, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 1, chunkCount: 2, payload: Data([0x33]),
        )))
        // A chunk disagreeing with the PINNED count/geometry is a stale/corrupt datagram — dropped.
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 1, chunkCount: 3, payload: Data([0x33]),
        )))
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 999, imageHeight: 4,
            chunkIndex: 1, chunkCount: 2, payload: Data([0x33]),
        )))
        let image = assembler.feed(good[1])
        XCTAssertEqual(image?.data, jpeg, "the genuine tail chunk still completes after hostile drops")
    }

    func testAssemblerBoundsUntrustedCountIndexAndPayload() {
        var assembler = WindowPreviewAssembler(token: 1)
        // chunkCount over the budget → dropped before any allocation grows.
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 0, chunkCount: UInt16(VideoControlMessage.previewChunkCountMax + 1),
            payload: Data([0]),
        )))
        // chunkCount 0 is malformed.
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 0, chunkCount: 0, payload: Data([0]),
        )))
        // index ≥ count is malformed.
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 2, chunkCount: 2, payload: Data([0]),
        )))
        // an over-budget payload is malformed (the chunker never emits one).
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 0, chunkCount: 2,
            payload: Data(repeating: 0, count: VideoControlMessage.previewChunkPayloadMax + 1),
        )))
        // a SHORT non-final chunk is a corrupt datagram (would splice a truncated image).
        XCTAssertNil(assembler.feed(.windowPreviewChunk(
            token: 1, windowID: 2, imageWidth: 4, imageHeight: 4,
            chunkIndex: 0, chunkCount: 2, payload: Data([0, 1, 2]),
        )))
    }

    // MARK: datagram budget

    func testEncodedChunkClearsTheWireGuardMTU() {
        let msg = VideoControlMessage.windowPreviewChunk(
            token: .max,
            windowID: .max,
            imageWidth: .max,
            imageHeight: .max,
            chunkIndex: .max,
            chunkCount: .max,
            payload: Data(repeating: 0xFF, count: VideoControlMessage.previewChunkPayloadMax),
        )
        XCTAssertLessThan(
            msg.encode().count, 1400,
            "a full chunk datagram must clear the ~1420 WireGuard path MTU so it never IP-fragments",
        )
    }
}
