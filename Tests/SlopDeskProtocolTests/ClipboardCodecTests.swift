import XCTest
@testable import SlopDeskProtocol

/// The clipboard-sync sub-codec (``MetadataVerb/setClipboard`` = 15 / ``MetadataVerb/readClipboard``
/// = 16 payloads): round-trips, the kind-0 "unchanged" arm, and validate-then-drop on hostile bytes.
final class ClipboardCodecTests: XCTestCase {
    // MARK: setClipboard request  ([UInt8 kind][content])

    func testSetRoundTripText() throws {
        let clip = MetadataCodec.ClipboardClip(kind: .text, bytes: Data("hello 🌏".utf8))
        let decoded = try MetadataCodec.decodeClipboardSet(MetadataCodec.encodeClipboardSet(clip))
        XCTAssertEqual(decoded, clip)
        XCTAssertEqual(decoded.kind, .text)
    }

    func testSetRoundTripImageBytesAreOpaque() throws {
        // PNG bytes are NOT UTF-8 — the codec must carry them untouched.
        let clip = MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]))
        let decoded = try MetadataCodec.decodeClipboardSet(MetadataCodec.encodeClipboardSet(clip))
        XCTAssertEqual(decoded, clip)
        XCTAssertEqual(decoded.kind, .imagePNG)
    }

    func testSetEmptyContentRoundTrips() throws {
        // An empty content is wire-valid (1 byte total); the APPLIER rejects empty text, not the codec.
        let clip = MetadataCodec.ClipboardClip(kind: .text, bytes: Data())
        XCTAssertEqual(try MetadataCodec.decodeClipboardSet(MetadataCodec.encodeClipboardSet(clip)), clip)
    }

    func testSetUnknownKindByteIsCarriedForwardTolerantly() throws {
        let decoded = try MetadataCodec.decodeClipboardSet(Data([200, 1, 2, 3]))
        XCTAssertEqual(decoded.kindByte, 200)
        XCTAssertNil(decoded.kind, "an unknown future kind decodes to nil — receiver drops, never traps")
    }

    func testSetEmptyPayloadThrowsTruncated() {
        XCTAssertThrowsError(try MetadataCodec.decodeClipboardSet(Data()))
    }

    func testSetOverCapContentThrows() {
        var payload = Data([MetadataCodec.ClipboardKind.text.rawValue])
        payload.append(Data(count: MetadataCodec.maxClipboardContentBytes + 1))
        XCTAssertThrowsError(try MetadataCodec.decodeClipboardSet(payload))
    }

    func testSetAtCapContentDecodes() throws {
        var payload = Data([MetadataCodec.ClipboardKind.imagePNG.rawValue])
        payload.append(Data(count: MetadataCodec.maxClipboardContentBytes))
        XCTAssertEqual(
            try MetadataCodec.decodeClipboardSet(payload).bytes.count,
            MetadataCodec.maxClipboardContentBytes,
        )
    }

    // MARK: readClipboard request  ([Int64 lastSeenChangeCount])

    func testReadRequestRoundTrip() throws {
        XCTAssertEqual(
            try MetadataCodec.decodeClipboardReadRequest(
                MetadataCodec.encodeClipboardReadRequest(lastSeenChangeCount: 123_456_789),
            ),
            123_456_789,
        )
    }

    func testReadRequestBaselineProbeRoundTrip() throws {
        XCTAssertEqual(
            try MetadataCodec.decodeClipboardReadRequest(
                MetadataCodec.encodeClipboardReadRequest(
                    lastSeenChangeCount: MetadataCodec.clipboardBaselineProbe,
                ),
            ),
            MetadataCodec.clipboardBaselineProbe,
        )
    }

    func testReadRequestTruncatedThrows() {
        XCTAssertThrowsError(try MetadataCodec.decodeClipboardReadRequest(Data([0, 0, 0])))
    }

    // MARK: readClipboard response  ([Int64 changeCount][UInt8 kind][content])

    func testReadResponseRoundTripWithClip() throws {
        let clip = MetadataCodec.ClipboardClip(kind: .imagePNG, bytes: Data([1, 2, 3]))
        let (count, decoded) = try MetadataCodec.decodeClipboardReadResponse(
            MetadataCodec.encodeClipboardReadResponse(changeCount: 42, clip: clip),
        )
        XCTAssertEqual(count, 42)
        XCTAssertEqual(decoded, clip)
    }

    func testReadResponseRoundTripUnchanged() throws {
        let (count, decoded) = try MetadataCodec.decodeClipboardReadResponse(
            MetadataCodec.encodeClipboardReadResponse(changeCount: 7, clip: nil),
        )
        XCTAssertEqual(count, 7)
        XCTAssertNil(decoded, "kind 0 = unchanged/empty — no clip")
    }

    func testReadResponseKindZeroWithTrailingBytesThrows() {
        var payload = MetadataCodec.encodeClipboardReadResponse(changeCount: 7, clip: nil)
        payload.append(contentsOf: [1, 2, 3])
        XCTAssertThrowsError(try MetadataCodec.decodeClipboardReadResponse(payload))
    }

    func testReadResponseTruncatedThrows() {
        // Change count present but no kind byte.
        var payload = Data()
        payload.appendBE(Int64(9))
        XCTAssertThrowsError(try MetadataCodec.decodeClipboardReadResponse(payload))
    }

    func testReadResponseOverCapContentThrows() {
        var payload = Data()
        payload.appendBE(Int64(9))
        payload.append(MetadataCodec.ClipboardKind.text.rawValue)
        payload.append(Data(count: MetadataCodec.maxClipboardContentBytes + 1))
        XCTAssertThrowsError(try MetadataCodec.decodeClipboardReadResponse(payload))
    }

    func testReadResponseUnknownKindIsCarriedForwardTolerantly() throws {
        var payload = Data()
        payload.appendBE(Int64(9))
        payload.append(77)
        payload.append(contentsOf: [4, 5])
        let (_, clip) = try MetadataCodec.decodeClipboardReadResponse(payload)
        XCTAssertEqual(clip?.kindByte, 77)
        XCTAssertNil(clip?.kind)
    }
}
