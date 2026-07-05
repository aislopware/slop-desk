import XCTest
@testable import SlopDeskVideoProtocol

/// Differential tests pinning the SIMD `NeonGf` (the `CSlopDeskSIMD` C kernel) byte-identical to
/// the pure-Swift `ScalarGf` over every coefficient, every width, and the accumulation / trailing
/// patterns the RS codec actually exercises. Ported from the Rust `gf_neon.rs` `#[cfg(test)]`
/// suite. This is what proves the NEON and scalar paths agree (and that the C tail handler is
/// correct), so it must FAIL on any divergence.
final class GF256NeonDifferentialTests: XCTestCase {
    /// Deterministic, dependency-free PRNG (SplitMix64) so the differential test is reproducible.
    /// Ported byte-for-byte from the Rust reference; every op is a WRAPPING op (`&+`/`&*`/`&>>`)
    /// because Swift's checked `+`/`*` trap on overflow in release.
    private struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func nextU64() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func fill(_ buf: inout [UInt8]) {
            for i in 0..<buf.count {
                buf[i] = UInt8(nextU64() & 0xFF)
            }
        }
    }

    /// Widths exercising: empty, sub-16 tails (1,7,15), exact blocks (16,32,64), block+tail
    /// (17,31,33,63,100), and a long run with the max-byte odd length (255).
    private static let widths: [Int] = [
        0, 1, 7, 15, 16, 17, 31, 32, 33, 48, 63, 64, 65, 96, 100, 127, 128, 200, 255,
    ]

    func testNeonMulAddMatchesScalarForEveryCoeffAndWidth() {
        var rng = SplitMix64(seed: 0xA15D_0DE5_C0DE_F00D)
        let neon = NeonGf()
        let scalar = ScalarGf()
        for coeffInt in 0...255 {
            let coeff = UInt8(coeffInt)
            for width in Self.widths {
                var src = [UInt8](repeating: 0, count: width)
                rng.fill(&src)
                // Pre-fill dst with non-zero garbage so we exercise ACCUMULATION (`^=`), not a bare
                // store — the two backends must fold into identical pre-existing bytes.
                var dstNeon = [UInt8](repeating: 0, count: width)
                rng.fill(&dstNeon)
                var dstScalar = dstNeon

                neon.mulAdd(coeff: coeff, src: src, dst: &dstNeon)
                scalar.mulAdd(coeff: coeff, src: src, dst: &dstScalar)

                XCTAssertEqual(dstNeon, dstScalar, "mulAdd diverged: coeff=\(coeff) width=\(width)")
            }
        }
    }

    func testNeonXorAddMatchesScalarForEveryWidth() {
        var rng = SplitMix64(seed: 0x0FF1_CE15_DEAD_BEEF)
        let neon = NeonGf()
        let scalar = ScalarGf()
        for width in Self.widths {
            var src = [UInt8](repeating: 0, count: width)
            rng.fill(&src)
            var dstNeon = [UInt8](repeating: 0, count: width)
            rng.fill(&dstNeon)
            var dstScalar = dstNeon

            neon.xorAdd(src: src, dst: &dstNeon)
            scalar.xorAdd(src: src, dst: &dstScalar)

            XCTAssertEqual(dstNeon, dstScalar, "xorAdd diverged: width=\(width)")
        }
    }

    func testNeonMulAddAccumulatesAcrossRepeatedCalls() {
        // Two scaled shards folded into ONE accumulator (the RS encode pattern) must match the
        // scalar backend folded the same way — proves accumulation is correct across calls, not
        // just within one.
        var rng = SplitMix64(seed: 0xBADC_0FFE_E0DD_F00D)
        let neon = NeonGf()
        let scalar = ScalarGf()
        let coeffPairs: [(UInt8, UInt8)] = [(0x53, 0x02), (0x01, 0xFF), (0x9D, 0x10)]
        for width in [16, 17, 64, 100, 255] {
            var a = [UInt8](repeating: 0, count: width)
            var b = [UInt8](repeating: 0, count: width)
            rng.fill(&a)
            rng.fill(&b)
            var accNeon = [UInt8](repeating: 0, count: width)
            var accScalar = accNeon

            for (coeffA, coeffB) in coeffPairs {
                neon.mulAdd(coeff: coeffA, src: a, dst: &accNeon)
                neon.mulAdd(coeff: coeffB, src: b, dst: &accNeon)
                scalar.mulAdd(coeff: coeffA, src: a, dst: &accScalar)
                scalar.mulAdd(coeff: coeffB, src: b, dst: &accScalar)
            }
            XCTAssertEqual(accNeon, accScalar, "accumulation diverged: width=\(width)")
        }
    }

    func testNeonMulAddLeavesTrailingDstUntouched() {
        // dst longer than src: the bytes past src.count must stay exactly as they were (the
        // zero-pad / ragged-shard case in the codec).
        let neon = NeonGf()
        let src: [UInt8] = [0x12, 0x34, 0x56]
        var dst = [UInt8](repeating: 0xAA, count: 20)
        neon.mulAdd(coeff: 0x07, src: src, dst: &dst)
        XCTAssertEqual(
            Array(dst[3...]),
            [UInt8](repeating: 0xAA, count: 17),
            "bytes past src.count were modified",
        )
    }
}
