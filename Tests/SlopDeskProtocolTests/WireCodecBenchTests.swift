import Foundation
import XCTest
@testable import SlopDeskProtocol

/// Micro-benchmark of the terminal (path-1) wire codec. It prints an `encode ns/op | decode ns/op`
/// table across payload sizes so a perf regression on the `.output`/`.input` path is visible, and
/// asserts only a loose absolute ceiling (a hard number would flake under machine load). Run on
/// this Mac Studio: `swift test --filter WireCodecBenchTests`.
///
/// It was called `RustWireBenchTests` until 2026-08-12 and its doc described "the Rust-backed
/// terminal wire codec (the only codec — there is no native Swift one)" measured "through the FFI".
/// None of that was ever true in this repo: the codec is `WireMessage+Encode.swift` /
/// `WireMessage+Decode.swift`, hand-written Swift and golden-pinned, and there is no FFI anywhere
/// (`CLAUDE.md`: a separate binary over a socket, never FFI). The name survived the
/// `Aislopdesk → SlopDesk` rename in `b65d634d` and quietly misreported the architecture to every
/// audit of "what is already in Rust" since. Renamed rather than deleted — the numbers are useful.
final class WireCodecBenchTests: XCTestCase {
    /// Sink to stop the optimizer eliding the work being measured.
    private var sink = 0

    /// One measurement, as the BEST of three passes over the same total work.
    ///
    /// `make quick` runs this beside thousands of other tests, and one timed loop that lands in
    /// another target's CPU slice reads as a tenfold regression — which then costs a full re-run of
    /// the suite to disprove. Splitting the same iteration count into three passes and keeping the
    /// fastest costs no extra work and asks the question the ceiling is actually about: what does
    /// this cost when it has the machine, not what did it cost while it was sharing one.
    private func nsPerOp(_ iterations: Int, _ block: () -> Void) -> Double {
        // Warm up (codegen, allocator caches) so the timed passes are steady-state.
        for _ in 0..<min(iterations, 1000) { block() }
        let passes = 3
        let per = max(iterations / passes, 1)
        var best = Double.infinity
        for _ in 0..<passes {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<per { block() }
            let end = DispatchTime.now().uptimeNanoseconds
            best = Double.minimum(best, Double(end - start) / Double(per))
        }
        return best
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
            // Loose absolute ceiling: even a 128 KiB payload must stay well under 1 ms/op.
            XCTAssertLessThan(enc, 1_000_000, "encode \(name) absurdly slow")
            XCTAssertLessThan(dec, 1_000_000, "decode \(name) absurdly slow")
        }
        print("(sink: \(sink))\n")
    }
}
