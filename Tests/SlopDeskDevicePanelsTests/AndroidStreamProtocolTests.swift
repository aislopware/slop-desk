// AndroidStreamProtocolTests — the MARSHALLING for `scrcpy`'s stream, not the decoding.
//
// The framing itself is `rust/slopdesk-androidd/src/stream.rs` and the Annex-B walk is
// `rust/slopdesk-video/src/annexb.rs`; every behaviour case this file used to carry was ported there
// unchanged, including the one-byte-at-a-time reassembly sweep that is the reason this decoder has
// tests at all. Repeating them here would be the cross-language mirror fixture the tree forbids: two
// suites that can only ever agree or be a bug.
//
// What is left is what only exists on THIS side of the door and can only fail here:
//
// - the handle's lifetime — one `new`, one `free`, no double-read of a freed parser;
// - the buffer sizing — `AGAIN` grows the array and the retry reads the same message;
// - the slicing — `payload_len` bytes off the head of a buffer that is usually much longer;
// - the mapping — a `kind` byte and a span array becoming the enum SwiftUI switches on.
//
// The fixtures are assembled field by field rather than pasted as one blob, so the meaning of each
// byte is legible where it is asserted.

#if os(macOS)
import CSlopDeskFFI
import Foundation
import XCTest
@testable import SlopDeskDevicePanels

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

    // MARK: The mapping

    /// Every `kind` the door can answer becomes its case, with its fields intact — the one thing a
    /// wrong constant or a mis-read struct field would break, and the Rust suite cannot see.
    func testEachKindBecomesItsCase() {
        var stream = Data("h264".utf8)
        stream.append(sessionPacket(width: 460, height: 1024))
        stream.append(mediaPacket(flags: 0x40, payload: Data([0xAA, 0xBB])))
        stream.append(mediaPacket(flags: 0x20, payload: Data([0xCC])))
        stream.append(mediaPacket(flags: 0x00, payload: Data([0xDD])))

        let parser = AndroidStreamParser()
        XCTAssertEqual(parser.consume(stream), [
            .codec("h264"),
            .session(width: 460, height: 1024),
            .configuration(Data([0xAA, 0xBB])),
            .accessUnit(Data([0xCC]), isKeyframe: true),
            .accessUnit(Data([0xDD]), isKeyframe: false),
        ])
        XCTAssertFalse(parser.isCorrupt)
    }

    // MARK: The slicing

    /// A payload is read off the HEAD of a buffer that stays large, so a stale tail must never leak
    /// into a frame. Two different lengths back to back is what catches that.
    func testAPayloadIsCutToItsOwnLengthAndNotTheBuffers() {
        let parser = AndroidStreamParser()
        XCTAssertEqual(parser.consume(Data("h264".utf8)), [.codec("h264")])

        let long = Data(repeating: 0xEE, count: 900)
        XCTAssertEqual(
            parser.consume(mediaPacket(flags: 0x20, payload: long)),
            [.accessUnit(long, isKeyframe: true)],
        )
        let short = Data([0x01, 0x02])
        XCTAssertEqual(
            parser.consume(mediaPacket(flags: 0x00, payload: short)),
            [.accessUnit(short, isKeyframe: false)],
            "the previous frame's tail is still in the buffer and must not follow this one",
        )
    }

    // MARK: The sizing

    /// The retry contract: a payload past the buffer's floor grows it once, and the message the
    /// short call refused is the message the grown call reads.
    func testAPayloadPastTheFloorIsStillReadWhole() {
        let parser = AndroidStreamParser()
        XCTAssertEqual(parser.consume(Data("h264".utf8)), [.codec("h264")])

        // Past the 64 KiB the buffer first grows to, so the door must answer AGAIN at least once.
        let big = Data(repeating: 0xAB, count: 200_000)
        XCTAssertEqual(parser.consume(mediaPacket(flags: 0x20, payload: big)), [
            .accessUnit(big, isKeyframe: true),
        ])
    }

    // MARK: The lifetime

    /// A corrupt verdict latches on THIS side too, so a torn-down session stops calling a parser it
    /// has already been told is finished.
    func testACorruptVerdictLatchesInSwift() {
        let parser = AndroidStreamParser()
        XCTAssertEqual(parser.consume(Data([0, 0, 0, 0])), [])
        XCTAssertTrue(parser.isCorrupt)
        XCTAssertEqual(parser.consume(mediaPacket(flags: 0x20, payload: Data([1]))), [])
    }

    /// Two parsers are two handles: one being fed must not advance the other. The failure this
    /// denies is a shared or double-freed pointer, which is the whole risk a handle ABI carries.
    func testTwoParsersDoNotShareAHandle() {
        let first = AndroidStreamParser()
        let second = AndroidStreamParser()
        XCTAssertEqual(first.consume(Data("h264".utf8)), [.codec("h264")])
        XCTAssertEqual(
            second.consume(Data("h265".utf8)), [.codec("h265")],
            "the second parser is still at the head of its own stream",
        )
    }

    /// The parser is freed when the last reference goes, and freeing must not take the process with
    /// it. Nothing to assert but the absence of a crash — which is exactly what a double free is.
    func testAReleasedParserFreesItsHandle() {
        for _ in 0..<64 {
            let parser = AndroidStreamParser()
            _ = parser.consume(Data("h264".utf8))
        }
    }

    // MARK: The codec vocabulary

    /// The door decides which identifiers decode; this asserts the accepted one lands on the case
    /// the decode session is configured from, and the refused one on `nil`.
    func testOnlyTheDecodableCodecsResolve() {
        XCTAssertEqual(AndroidVideoCodec(streamIdentifier: "h264"), .h264)
        XCTAssertEqual(AndroidVideoCodec(streamIdentifier: "h265"), .h265)
        XCTAssertNil(AndroidVideoCodec(streamIdentifier: "av1"))
        XCTAssertNil(AndroidVideoCodec(streamIdentifier: ""))
    }

    /// The near side never WIDENS the door's set. Named identifiers plus a spread of things a
    /// mis-framed stream can put in those four bytes, each asked of both sides: the enum resolves
    /// exactly when `slopdesk_android_stream_decodable_codec` says the panel can display it.
    ///
    /// This is the pin the fallback used to make impossible. `AndroidStreamConnection` read an
    /// unrecognised identifier as H.264 rather than as a refusal, so the door's `false` reached
    /// nothing that acted on it — the enum could have accepted a string the door rejected and the
    /// only symptom would have been a black rectangle.
    func testTheEnumResolvesExactlyWhenTheDoorSaysDecodable() {
        let identifiers = ["h264", "h265", "av1", "", "H264", "h26", "h2644", "vp9", "\u{1F600}", "\0h264"]
        for identifier in identifiers {
            let bytes = Array(identifier.utf8)
            let decodable = bytes.withUnsafeBufferPointer { input in
                slopdesk_android_stream_decodable_codec(input.baseAddress, input.count)
            }
            XCTAssertEqual(
                AndroidVideoCodec(streamIdentifier: identifier) != nil, decodable,
                "the two sides disagree about \(identifier.debugDescription)",
            )
        }
    }
}

/// The span-array marshalling: a count, an array of offsets, and the slices they name.
final class AndroidAnnexBTests: XCTestCase {
    private let fourByte = Data([0, 0, 0, 1])
    private let threeByte = Data([0, 0, 1])

    /// Every span the door reports is cut out of the caller's own buffer at the offset it named.
    /// An off-by-one in that arithmetic is silent — it yields a NAL the decoder rejects — and it is
    /// the one thing the Rust suite, which never sees a `Data`, cannot catch.
    func testEverySpanIsCutAtTheOffsetItNames() {
        var unit = fourByte
        unit.append(Data([0x67, 0x01]))
        unit.append(threeByte)
        unit.append(Data([0x68, 0x02]))
        unit.append(fourByte)
        unit.append(Data([0x65, 0x03]))

        XCTAssertEqual(AndroidAnnexB.nalUnits(in: unit), [
            Data([0x67, 0x01]), Data([0x68, 0x02]), Data([0x65, 0x03]),
        ])
    }

    /// A buffer with no start code answers an empty array rather than one span of everything.
    func testNoStartCodeIsNoUnits() {
        XCTAssertEqual(AndroidAnnexB.nalUnits(in: Data([0x00, 0x00, 0x00, 0x04, 0x65])), [])
        XCTAssertEqual(AndroidAnnexB.nalUnits(in: Data()), [])
    }

    /// The measure-then-fill retry: the rewrite's needed length is what the second call writes, and
    /// a refusal is `nil` rather than an empty `Data`.
    func testTheRewriteCrossesWholeOrNotAtAll() {
        var unit = fourByte
        unit.append(Data([0x65, 0xAA, 0xBB]))
        unit.append(threeByte)
        unit.append(Data([0x01]))

        XCTAssertEqual(
            AndroidAnnexB.avccAccessUnit(from: unit),
            Data([0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 1, 0x01]),
        )
        XCTAssertNil(AndroidAnnexB.avccAccessUnit(from: Data([0x00, 0x00, 0x00, 0x04, 0x65])))
    }

    // NOTE: `testTheCodecPicksTheReading` left with `AndroidAnnexB.parameterSets` (2026-08-29).
    // The codec flag still picks the NAL-type reading — it just picks the framework entry point in
    // the same call now, which is why the claim is asserted where both choices are made:
    // `slopdesk-ffi`'s `panel_video` proves an H.264 packet read as HEVC is REFUSED rather than
    // silently handed to the wrong builder.
}
#endif
