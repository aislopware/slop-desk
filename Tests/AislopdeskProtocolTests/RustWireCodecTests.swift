import Foundation
import XCTest
@testable import AislopdeskProtocol

/// The terminal `WireMessage` wire codec is Rust-core canonical (no native Swift codec). These
/// tests pin the Swift FFI marshaling — the layer the Rust golden vectors cannot see — to the wire
/// format: full round-trips through the production `encode()`/`decode()`, hand-computed byte vectors
/// (which catch a *symmetric* marshaling bug a round-trip alone would miss, notably on the zero-copy
/// `.output`/`.input` data-frame path), the decode error contract, and a decode fuzz that must never
/// crash.
final class RustWireCodecTests: XCTestCase {
    /// A representative message of every variant, including edge sizes and Unicode.
    private static func corpus() -> [WireMessage] {
        let small = Data([0x00, 0xFF, 0x80, 0x7F, 0x1B])
        let large = Data((0..<(128 * 1024)).map { UInt8($0 & 0xFF) })
        let sid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        return [
            .output(seq: 1, bytes: small),
            .output(seq: 9_000_000_000, bytes: large),
            .output(seq: 1, bytes: Data()),
            .exit(code: 0), .exit(code: -1), .exit(code: Int32.min), .exit(code: Int32.max),
            .input(small), .input(large), .input(Data()),
            .hello(protocolVersion: 1, sessionID: sid, lastReceivedSeq: 42),
            .hello(protocolVersion: 0, sessionID: WireMessage.newSessionID, lastReceivedSeq: 0),
            .resize(cols: 80, rows: 24, pxWidth: 1920, pxHeight: 1080),
            .resize(cols: 65535, rows: 0, pxWidth: 0, pxHeight: 65535),
            .ack(seq: 0), .ack(seq: Int64.max),
            .bye,
            .ping(timestampMS: 0), .ping(timestampMS: UInt64.max),
            .pong(timestampMS: 123_456_789),
            .helloAck(sessionID: sid, resumeFromSeq: 7, returningClient: true),
            .helloAck(sessionID: WireMessage.newSessionID, resumeFromSeq: 0, returningClient: false),
            .title(""), .title("hello"), .title("emoji 🚀 + accents éàü + 中文"),
            .bell,
            .commandStatus(.running),
            .commandStatus(.idle(exitCode: 0, durationMS: 0)),
            .commandStatus(.idle(exitCode: -1, durationMS: 5000)),
            .commandStatus(.idle(exitCode: nil, durationMS: 250)),
            .notification(title: "", body: ""),
            .notification(title: "Build", body: "done ✅"),
            .notification(title: "t", body: "multi\nline\u{0}body"),
        ]
    }

    /// `encode()` → strip the length prefix → `decode()` must reproduce every variant identically.
    func testEncodeDecodeRoundTripsEveryVariant() throws {
        for msg in Self.corpus() {
            let frame = msg.encode()
            // The 4-byte length prefix must equal the payload length the FrameDecoder peels off.
            XCTAssertGreaterThanOrEqual(frame.count, 5)
            let prefix = frame.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
            XCTAssertEqual(Int(prefix), frame.count - 4, "length prefix for \(msg.messageType)")
            XCTAssertEqual(frame.count, msg.wireByteCount, "wireByteCount for \(msg.messageType)")
            let decoded = try WireMessage.decode(payload: Data(frame.dropFirst(4)))
            XCTAssertEqual(decoded, msg, "round-trip identity for \(msg.messageType)")
        }
    }

    /// Hand-computed wire vectors pinning the marshaling — especially the zero-copy `.output`/
    /// `.input` data-frame path (`seq` is big-endian, then the bulk bytes verbatim).
    func testWireVectors() throws {
        let cases: [(WireMessage, [UInt8])] = [
            // ack: [len=9][12][i64 seq=1]
            (.ack(seq: 1), [0, 0, 0, 9, 12, 0, 0, 0, 0, 0, 0, 0, 1]),
            // exit 256: [len=5][2][i32 0x00000100]
            (.exit(code: 256), [0, 0, 0, 5, 2, 0, 0, 1, 0]),
            // output(seq:1,"Hi"): [len=11][1][i64 seq=1]["Hi"]
            (
                .output(seq: 1, bytes: Data("Hi".utf8)),
                [0, 0, 0, 11, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0x48, 0x69],
            ),
            // input("Hi"): [len=3][3]["Hi"]
            (.input(Data("Hi".utf8)), [0, 0, 0, 3, 3, 0x48, 0x69]),
            // input(""): [len=1][3]
            (.input(Data()), [0, 0, 0, 1, 3]),
            // bye: [len=1][13]
            (.bye, [0, 0, 0, 1, 13]),
        ]
        for (msg, expected) in cases {
            XCTAssertEqual(Array(msg.encode()), expected, "encode vector \(msg.messageType)")
            XCTAssertEqual(
                try WireMessage.decode(payload: Data(expected.dropFirst(4))),
                msg,
                "decode vector \(msg.messageType)",
            )
        }
    }

    /// A >64 KiB notification title is clamped at a Unicode-scalar boundary to fit the UInt16 length
    /// field (matching the Rust core), never corrupting the body, and `wireByteCount == encode().count`.
    func testOverlongNotificationTitleClampRoundTrips() throws {
        let title = String(repeating: "T", count: 65534) + "e\u{0301}" // base+combining at the cut
        let msg = WireMessage.notification(title: title, body: "x")
        XCTAssertEqual(msg.wireByteCount, msg.encode().count, "wireByteCount must equal encode().count")
        let decoded = try WireMessage.decode(payload: Data(msg.encode().dropFirst(4)))
        guard case let .notification(dTitle, dBody) = decoded else {
            XCTFail("not a notification")
            return
        }
        XCTAssertEqual(dBody, "x", "body survives an overlong title")
        XCTAssertLessThanOrEqual(dTitle.utf8.count, Int(UInt16.max), "title clamped to the u16 limit")
        // The scalar-boundary cut keeps "…Te" (the combining mark past 65535 bytes is dropped, so it
        // splits the "é" grapheme). The clamped title is therefore a valid UTF-8 BYTE prefix of the
        // original — compare at the byte level, since Swift's grapheme-aware `hasPrefix` would not see
        // "…Te" as a prefix of "…Té".
        XCTAssertTrue(
            Array(title.utf8).starts(with: Array(dTitle.utf8)),
            "clamped title is a valid UTF-8 byte prefix of the original",
        )
    }

    /// The decode error contract: each malformed payload throws the specific expected case.
    func testDecodeRejectsMalformed() {
        func decodeError(_ payload: Data) -> AislopdeskError? {
            do { _ = try WireMessage.decode(payload: payload)
                return nil
            } catch { return error as? AislopdeskError }
        }
        XCTAssertEqual(decodeError(Data([0xFF])), .unknownMessageType(0xFF))
        XCTAssertEqual(decodeError(Data([0x00])), .unknownMessageType(0))
        for truncated in [Data(), Data([2, 0]), Data([10, 0]), Data([1, 0, 0]), Data([25, 0, 5])] {
            XCTAssertEqual(decodeError(truncated), .truncated, "expected .truncated for \(Array(truncated))")
        }
        // title invalid UTF-8 and a bad commandStatus tag are .malformedBody (detail string may vary).
        for malformed in [Data([21, 0xFF, 0xFE]), Data([23, 9])] {
            guard case .malformedBody = decodeError(malformed) else {
                XCTFail("expected .malformedBody for \(Array(malformed))")
                return
            }
        }
    }

    /// Random byte payloads must never crash the Rust-backed decoder.
    func testFuzzDecodeNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let len = Int.random(in: 0...64, using: &rng)
            let payload = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? WireMessage.decode(payload: payload)
        }
    }
}
