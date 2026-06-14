import Foundation
import XCTest
@testable import AislopdeskVideoProtocol

/// Differential equivalence between the native Swift cursor codec and the Rust-backed codec
/// (now the production path). Golden vectors prove the Rust core matches Swift byte-for-byte;
/// this re-proves it *through the Swift FFI marshaling* so `encode()`/`decode()` are
/// guaranteed drop-in replacements for `encodeNative()`/`decodeNative()`.
final class CursorRustParityTests: XCTestCase {
    private static func corpus() -> [CursorUpdate] {
        [
            CursorUpdate(position: VideoPoint(x: 0, y: 0), shapeID: 0, hotspot: VideoPoint(x: 0, y: 0), visible: false),
            CursorUpdate(
                position: VideoPoint(x: 1920, y: 1080),
                shapeID: 42,
                hotspot: VideoPoint(x: 8, y: 8),
                visible: true,
            ),
            CursorUpdate(
                position: VideoPoint(x: -1e9, y: 1e9),
                shapeID: 65535,
                hotspot: VideoPoint(x: -0.5, y: 0.25),
                visible: true,
            ),
            CursorUpdate(
                position: VideoPoint(x: 0.1, y: -0.1),
                shapeID: 7,
                hotspot: VideoPoint(x: 1, y: 2),
                visible: false,
            ),
        ]
    }

    func testEncodeByteIdenticalToNative() {
        for c in Self.corpus() {
            XCTAssertEqual(RustVideoFFI.encode(c), c.encodeNative(), "encode parity for shape \(c.shapeID)")
        }
    }

    func testDecodeMatchesNativeAndRoundTrips() throws {
        for c in Self.corpus() {
            let bytes = c.encodeNative()
            let viaRust = try RustVideoFFI.decodeCursor(bytes)
            let viaNative = try CursorUpdate.decodeNative(bytes)
            XCTAssertEqual(viaRust, viaNative, "decode parity for shape \(c.shapeID)")
            XCTAssertEqual(viaRust, c, "round-trip identity for shape \(c.shapeID)")
        }
    }

    /// Random byte payloads must never crash and must agree on success/failure (and value when
    /// both succeed) between the Rust and native decoders.
    func testFuzzDecodeAgrees() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let len = Int.random(in: 0...40, using: &rng)
            let data = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let r = Result { try RustVideoFFI.decodeCursor(data) }
            let n = Result { try CursorUpdate.decodeNative(data) }
            switch (r, n) {
            case let (.success(a), .success(b)):
                XCTAssertEqual(a, b, "cursor fuzz value mismatch for \(Array(data))")
            case (.failure, .failure):
                break
            default:
                XCTFail("cursor fuzz disagreement (one threw) for \(Array(data))")
            }
        }
    }
}
