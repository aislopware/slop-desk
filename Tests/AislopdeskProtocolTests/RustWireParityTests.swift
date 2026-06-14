import Foundation
import XCTest
@testable import AislopdeskProtocol

/// Differential equivalence between the native Swift wire codec and the Rust-backed codec
/// (now the production path). Golden vectors already prove the Rust core matches Swift
/// byte-for-byte; this re-proves it *through the Swift FFI marshaling* — the layer the
/// golden test cannot see — so `encode()`/`decode()` are guaranteed drop-in replacements
/// for `encodeNative()`/`decodeNative()`.
final class RustWireParityTests: XCTestCase {
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

    func testEncodeIsByteIdenticalToNative() {
        // Drive the Rust path directly (not the size-gated `encode()`) so Rust is proven for
        // ALL sizes incl. the bulk payloads the gate routes to native — Android uses Rust
        // unconditionally.
        for msg in Self.corpus() {
            XCTAssertEqual(RustFFI.encodeFrame(msg), msg.encodeNative(), "encode parity for \(msg.messageType)")
        }
    }

    func testDecodeMatchesNativeAndRoundTrips() throws {
        for msg in Self.corpus() {
            let frame = msg.encodeNative()
            let payload = Data(frame.dropFirst(4)) // strip the 4-byte length prefix
            let viaRust = try RustFFI.decodePayload(payload)
            let viaNative = try WireMessage.decodeNative(payload: payload)
            XCTAssertEqual(viaRust, viaNative, "decode parity for \(msg.messageType)")
            XCTAssertEqual(viaRust, msg, "round-trip identity for \(msg.messageType)")
        }
    }

    /// Regression for the adversarial-review finding: a >64 KiB notification title whose
    /// 65535-byte cut straddles a multi-scalar grapheme. `encode()` (Rust, scalar clamp),
    /// `encodeNative()` (now scalar clamp), and `wireByteCount` must all agree byte-for-byte.
    /// (Unreachable in production — the OSC producer caps titles at ~1 KiB — but it pins the
    /// encode()↔wireByteCount flow-control parity contract.)
    func testOverlongNotificationTitleClampParity() {
        let title = String(repeating: "T", count: 65534) + "e\u{0301}" // base+combining at the cut
        let msg = WireMessage.notification(title: title, body: "x")
        XCTAssertEqual(RustFFI.encodeFrame(msg), msg.encodeNative(), "notification clamp: Rust == native")
        XCTAssertEqual(msg.wireByteCount, msg.encode().count, "wireByteCount must equal encode().count")
        // Decoding the clamped frame must round-trip the clamped (not original) title identically.
        let payload = Data(msg.encodeNative().dropFirst(4))
        XCTAssertEqual(try? RustFFI.decodePayload(payload), try? WireMessage.decodeNative(payload: payload))
    }

    func testDecodeErrorsMatchNative() {
        // (payload, human label) pairs that the native decoder rejects.
        let cases: [(Data, String)] = [
            (Data([0xFF]), "unknown type"),
            (Data([0x00]), "unknown type 0"),
            (Data([2, 0]), "exit truncated"),
            (Data([10, 0]), "hello truncated"),
            (Data(), "empty payload"),
            (Data([21, 0xFF, 0xFE]), "title invalid UTF-8"),
            (Data([23, 9]), "commandStatus bad tag"),
            (Data([25, 0, 5]), "notification title len overruns"),
        ]
        for (payload, label) in cases {
            XCTAssertTrue(
                sameErrorCase(rust: payload, native: payload),
                "decode error parity for \(label)",
            )
        }
    }

    /// Fuzz: random byte payloads must never crash and must agree on success/failure (and on
    /// the decoded value when both succeed) between the Rust and native decoders.
    func testFuzzDecodeAgrees() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let len = Int.random(in: 0...64, using: &rng)
            let payload = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let rustResult = Result { try RustFFI.decodePayload(payload) }
            let nativeResult = Result { try WireMessage.decodeNative(payload: payload) }
            switch (rustResult, nativeResult) {
            case let (.success(r), .success(n)):
                XCTAssertEqual(r, n, "fuzz decode mismatch for \(Array(payload))")
            case (.failure, .failure):
                break // both reject — error-detail divergence (malformedBody string) is allowed
            default:
                XCTFail("fuzz decode disagreement (one threw) for \(Array(payload))")
            }
        }
    }

    // MARK: - Helpers

    private func sameErrorCase(rust rustPayload: Data, native nativePayload: Data) -> Bool {
        let rustErr = (try? RustFFI.decodePayload(rustPayload)) == nil
            ? caughtError(rustPayload, rust: true) : nil
        let nativeErr = (try? WireMessage.decodeNative(payload: nativePayload)) == nil
            ? caughtError(nativePayload, rust: false) : nil
        guard let rustErr, let nativeErr else { return false }
        switch (rustErr, nativeErr) {
        case (.truncated, .truncated): return true
        case let (.unknownMessageType(x), .unknownMessageType(y)): return x == y
        case (.malformedBody, .malformedBody): return true // detail string may differ by design
        case let (.frameTooLarge(x), .frameTooLarge(y)): return x == y
        default: return false
        }
    }

    private func caughtError(_ payload: Data, rust: Bool) -> AislopdeskError? {
        do {
            _ = rust
                ? try RustFFI.decodePayload(payload)
                : try WireMessage.decodeNative(payload: payload)
            return nil
        } catch {
            return error as? AislopdeskError
        }
    }
}
