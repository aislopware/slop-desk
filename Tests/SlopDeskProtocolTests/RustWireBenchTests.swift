import Foundation
import XCTest
@testable import SlopDeskProtocol

/// Micro-benchmark of the Rust-backed terminal wire codec (the only codec — there is no native
/// Swift one). It prints an `encode ns/op | decode ns/op` table across payload sizes so a perf
/// regression on the zero-copy `.output`/`.input` path is visible, and asserts only a loose
/// absolute ceiling (a hard number would flake under machine load). Run on this Mac Studio:
/// `swift test --filter RustWireBenchTests`.
final class RustWireBenchTests: XCTestCase {
    /// Sink to stop the optimizer eliding the work being measured.
    private var sink = 0

    private func nsPerOp(_ iterations: Int, _ block: () -> Void) -> Double {
        // Warm up (codegen, allocator caches) so the timed loop is steady-state.
        for _ in 0..<min(iterations, 1000) { block() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { block() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations)
    }

    func testEncodeDecodePerfIsBounded() throws {
        let sid = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let scenarios: [(String, WireMessage, Int)] = [
            ("ack (13 B control)", .ack(seq: 123_456), 200_000),
            ("output 1 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 1024)), 100_000),
            ("output 8 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 8 * 1024)), 60000),
            ("output 64 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 64 * 1024)), 20000),
            ("output 128 KiB", .output(seq: 1, bytes: Data(repeating: 0xCD, count: 128 * 1024)), 10000),
            ("hello (handshake)", .hello(protocolVersion: 1, sessionID: sid, lastReceivedSeq: 9), 200_000),
            ("notification", .notification(title: "CI", body: "green ✅"), 200_000),
        ]

        print("\n=== WireMessage Rust codec (ns/op, lower is better) ===")
        print(String(format: "%-22@ %12@ %12@", "scenario", "encode", "decode"))
        for (name, msg, iters) in scenarios {
            let enc = nsPerOp(iters) { sink &+= msg.encode().count }
            let payload = Data(msg.encode().dropFirst(4))
            let dec = nsPerOp(iters) {
                sink &+= ((try? WireMessage.decode(payload: payload))?.messageType).map(Int.init) ?? 0
            }
            print(String(format: "%-22@ %12.1f %12.1f", name, enc, dec))
            // Loose absolute ceiling: even 128 KiB through the FFI must stay well under 1 ms/op.
            XCTAssertLessThan(enc, 1_000_000, "encode \(name) absurdly slow")
            XCTAssertLessThan(dec, 1_000_000, "decode \(name) absurdly slow")
        }
        print("(sink: \(sink))\n")
    }
}
