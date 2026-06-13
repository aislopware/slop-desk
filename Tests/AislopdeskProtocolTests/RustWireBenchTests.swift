import Foundation
import XCTest

@testable import AislopdeskProtocol

/// Micro-benchmark of the native Swift wire codec vs the Rust-backed codec (the FFI path),
/// so the Swift→Rust swap can be held to the hard "no performance regression" rule.
///
/// It prints a `native ns/op | rust ns/op | ratio` table (read in the morning report) and
/// asserts only *loose absolute* sanity ceilings — a hard ratio assertion would flake under
/// machine load; the perf decision is made from the printed numbers. Run on this Mac Studio:
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

    func testEncodeDecodePerfIsNotRegressed() throws {
        let sid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let scenarios: [(String, WireMessage, Int)] = [
            ("ack (13 B control)", .ack(seq: 123_456), 200_000),
            ("output 1 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 1024)), 100_000),
            ("output 2 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 2 * 1024)), 100_000),
            ("output 4 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 4 * 1024)), 80_000),
            ("output 8 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 8 * 1024)), 60_000),
            ("output 16 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 16 * 1024)), 40_000),
            ("output 64 KiB", .output(seq: 1, bytes: Data(repeating: 0xAB, count: 64 * 1024)), 20_000),
            ("output 128 KiB", .output(seq: 1, bytes: Data(repeating: 0xCD, count: 128 * 1024)), 10_000),
            ("hello (handshake)", .hello(protocolVersion: 1, sessionID: sid, lastReceivedSeq: 9), 200_000),
        ]

        print("\n=== WireMessage encode: native vs Rust (ns/op, lower is better) ===")
        print(String(format: "%-22@ %12@ %12@ %8@", "scenario" as NSString, "native" as NSString, "rust" as NSString, "ratio" as NSString))
        for (name, msg, iters) in scenarios {
            let native = nsPerOp(iters) { sink &+= msg.encodeNative().count }
            let rust = nsPerOp(iters) { sink &+= msg.encode().count }
            print(String(format: "%-22@ %12.1f %12.1f %7.2fx", name as NSString, native, rust, rust / native))
            // Loose absolute ceiling: even 128 KiB through the FFI must stay well under 1 ms/op.
            XCTAssertLessThan(rust, 1_000_000, "rust encode \(name) absurdly slow")
        }

        print("\n=== WireMessage decode: native vs Rust (ns/op, lower is better) ===")
        print(String(format: "%-22@ %12@ %12@ %8@", "scenario" as NSString, "native" as NSString, "rust" as NSString, "ratio" as NSString))
        for (name, msg, iters) in scenarios {
            let payload = Data(msg.encodeNative().dropFirst(4))
            let native = nsPerOp(iters) { sink &+= ((try? WireMessage.decodeNative(payload: payload))?.messageType).map(Int.init) ?? 0 }
            let rust = nsPerOp(iters) { sink &+= ((try? WireMessage.decode(payload: payload))?.messageType).map(Int.init) ?? 0 }
            print(String(format: "%-22@ %12.1f %12.1f %7.2fx", name as NSString, native, rust, rust / native))
            XCTAssertLessThan(rust, 1_000_000, "rust decode \(name) absurdly slow")
        }
        print("(sink: \(sink))\n")
    }
}
