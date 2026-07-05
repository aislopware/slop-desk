import XCTest
@testable import SlopDeskVideoProtocol

/// Cross-entry agreement tests pinning the two `FrameHasher` entry points byte-identical: the
/// pointer-based `FrameHasher.hashNV12` (the zero-copy entry the host calls) and the array-based
/// `FrameHasher.hashNV12Scalar`. Both now fold through the SAME pure-scalar `StreamHasher` — the
/// xxHash64 NEON kernel was removed (the scalar fold measured faster on Apple Silicon) — so these
/// no longer compare scalar-vs-NEON; they prove the two entry points stay in lockstep over many
/// random NV12 buffers of varied widths/heights/strides, plus they PIN the absolute hash constants
/// (`testHashNV12ValueStability`) so a silent change to the xxHash64 math or byte→lane mapping is
/// caught even though both entries would move together. (Filename keeps its historical "Neon" name.)
/// A missed difference is a wrongly-suppressed real frame (the client freezes on stale content), so
/// it must FAIL on any divergence between the two entries or any drift of the pinned values.
final class FrameHashNeonDifferentialTests: XCTestCase {
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

    /// Widths exercising: empty, sub-32 row tails (1,31), exact blocks (32,64,256), block+tail
    /// (33,100), and the max-byte odd length (255) + a long 1000-byte run.
    private static let widths: [Int] = [0, 1, 31, 32, 33, 64, 100, 255, 256, 1000]

    /// The pointer entry `hashNV12` takes raw plane pointers; drive it from the same `[UInt8]` arrays
    /// the array entry `hashNV12Scalar` sees, so both entries get byte-identical input.
    private func pointerHash(
        y: [UInt8], yStride: Int, width: Int, height: Int, cbcr: [UInt8], cbcrStride: Int,
    ) -> UInt64 {
        y.withUnsafeBytes { yRaw in
            cbcr.withUnsafeBytes { cRaw in
                FrameHasher.hashNV12(
                    y: yRaw.baseAddress,
                    yStride: yStride,
                    width: width,
                    height: height,
                    cbcr: cbcr.isEmpty ? nil : cRaw.baseAddress,
                    cbcrStride: cbcrStride,
                )
            }
        }
    }

    func testNeonHashMatchesScalarOverManyPlanes() {
        var rng = SplitMix64(seed: 0xF00D_BABE_C0DE_1234)
        // Several heights per width, and several strides (tight, +1, +7, +15, +37) so the cross-row
        // 32-byte block boundary lands at every alignment for both entry points.
        let heights = [0, 1, 2, 3, 5, 9, 16, 50]
        for width in Self.widths {
            for height in heights {
                for pad in [0, 1, 7, 15, 37] {
                    let yStride = width + pad
                    let cbcrStride = width + pad
                    var y = [UInt8](repeating: 0, count: max(0, yStride * height))
                    var cbcr = [UInt8](repeating: 0, count: max(0, cbcrStride * (height / 2)))
                    rng.fill(&y)
                    rng.fill(&cbcr)

                    let arrayEntry = FrameHasher.hashNV12Scalar(
                        y: y, yStride: yStride, width: width, height: height,
                        cbcr: cbcr, cbcrStride: cbcrStride,
                    )
                    let pointerEntry = pointerHash(
                        y: y, yStride: yStride, width: width, height: height,
                        cbcr: cbcr, cbcrStride: cbcrStride,
                    )
                    // width==0 / height==0 take the sentinel path in `hashNV12`; the array entry
                    // hashes an empty stream. Only compare on a real (hashable) frame, where both run.
                    if width > 0, height > 0, yStride >= width {
                        XCTAssertEqual(
                            arrayEntry, pointerEntry,
                            "entries diverged at w=\(width) h=\(height) pad=\(pad)",
                        )
                    }

                    // Luma-only path too (empty chroma).
                    if width > 0, height > 0, yStride >= width {
                        let arrayEntryY = FrameHasher.hashNV12Scalar(
                            y: y, yStride: yStride, width: width, height: height,
                            cbcr: [], cbcrStride: 0,
                        )
                        let pointerEntryY = pointerHash(
                            y: y, yStride: yStride, width: width, height: height,
                            cbcr: [], cbcrStride: 0,
                        )
                        XCTAssertEqual(
                            arrayEntryY, pointerEntryY,
                            "luma-only entries diverged at w=\(width) h=\(height) pad=\(pad)",
                        )
                    }
                }
            }
        }
    }

    func testNeonHashMatchesScalarOnSingleByteFlips() {
        // The cross-entry equality must hold even under a one-byte perturbation anywhere — the case
        // that matters (a missed difference is a wrongly-suppressed real frame).
        var rng = SplitMix64(seed: 0x1357_9BDF_2468_ACE0)
        let (w, h) = (48, 40)
        let stride = w + 11
        var y = [UInt8](repeating: 0, count: stride * h)
        rng.fill(&y)
        var i = 0
        while i < y.count {
            y[i] ^= 0x5A
            XCTAssertEqual(
                FrameHasher.hashNV12Scalar(y: y, yStride: stride, width: w, height: h, cbcr: [], cbcrStride: 0),
                pointerHash(y: y, yStride: stride, width: w, height: h, cbcr: [], cbcrStride: 0),
                "pointer != array entry after flipping byte \(i)",
            )
            y[i] ^= 0x5A
            i += 13
        }
    }

    func testNeonHashMatchesScalarForLargeRealisticFrame() {
        // A ~1080p luma+chroma plane with a 64-byte-aligned stride, to exercise the bulk loop hard.
        var rng = SplitMix64(seed: 0xDEAD_BEEF_FEED_FACE)
        let (w, h) = (1920, 1080)
        let yStride = (w + 63) & ~63
        let cbcrStride = yStride
        var y = [UInt8](repeating: 0, count: yStride * h)
        var cbcr = [UInt8](repeating: 0, count: cbcrStride * (h / 2))
        rng.fill(&y)
        rng.fill(&cbcr)
        XCTAssertEqual(
            FrameHasher.hashNV12Scalar(y: y, yStride: yStride, width: w, height: h, cbcr: cbcr, cbcrStride: cbcrStride),
            pointerHash(y: y, yStride: yStride, width: w, height: h, cbcr: cbcr, cbcrStride: cbcrStride),
            "pointer != array entry on a 1080p frame",
        )
    }

    func testOneBytePlaneFlipChangesTheHash() {
        // Sanity that the hash is actually sensitive (not a constant): a single luma-byte change must
        // change BOTH entry points' output (and they stay equal to each other).
        var rng = SplitMix64(seed: 0x0BAD_F00D_1234_5678)
        let (w, h) = (64, 48)
        let stride = w
        var y = [UInt8](repeating: 0, count: stride * h)
        rng.fill(&y)
        let base = pointerHash(y: y, yStride: stride, width: w, height: h, cbcr: [], cbcrStride: 0)
        y[stride * (h / 2) + (w / 2)] ^= 0x01
        let flipped = pointerHash(y: y, yStride: stride, width: w, height: h, cbcr: [], cbcrStride: 0)
        XCTAssertNotEqual(base, flipped, "a one-byte luma change must change the hash")
        XCTAssertEqual(
            flipped,
            FrameHasher.hashNV12Scalar(y: y, yStride: stride, width: w, height: h, cbcr: [], cbcrStride: 0),
            "the two entry points must still agree after the flip",
        )
    }

    // MARK: - Absolute value pins (algorithm-drift gate)

    /// Fills `count` bytes from a stateful SplitMix-style LCG seeded with `seed`, taking the same
    /// high-byte slice (`s >> 33`) every step. Distinct from `SplitMix64` above on purpose: these
    /// pins are reproducible from this exact recipe alone (state advances ONCE per byte).
    private func pinFill(_ count: Int, _ seed: UInt64) -> [UInt8] {
        var s = seed
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out[i] = UInt8(truncatingIfNeeded: s >> 33)
        }
        return out
    }

    /// Pins `hashNV12` to EXACT 64-bit constants on three deterministic frames (contiguous +
    /// padded). The cross-entry tests prove the pointer and array entries agree, but BOTH could
    /// drift together if the xxHash64 math or byte→lane mapping changed; these absolute values catch
    /// that. Any data-movement optimisation (contiguous fast path) MUST leave these unchanged.
    func testHashNV12ValueStability() {
        // (width, height, seed, contiguous-expected, padded-expected). `seed` drives the filler;
        // contiguous uses stride=width with chroma = pinFill(w*(h/2), seed+1); padded uses
        // stride=width+13 over a single luma plane (cbcr=nil) of (width+13)*height whole-buffer bytes
        // filled from seed+2 (distinct stream so the padded pin can't alias the contiguous one).
        // swiftlint:disable:next large_tuple
        let cases: [(Int, Int, UInt64, UInt64, UInt64)] = [
            (64, 4, 7, 0x8C9E_1256_106F_2D4B, 0x2395_75AB_0F80_5B80),
            (1920, 1080, 99, 0x47FD_6165_46FF_6CC1, 0xEA23_AF3A_894F_3C0F),
            (17, 9, 123, 0x75FD_1DCE_E90B_1331, 0x61B8_103F_18D7_E570),
        ]
        for (w, h, seed, expContig, expPadded) in cases {
            // Contiguous (stride == width), luma + chroma.
            let yC = pinFill(w * h, seed)
            let cbcrC = pinFill(w * (h / 2), seed &+ 1)
            let contig = pointerHash(
                y: yC, yStride: w, width: w, height: h, cbcr: cbcrC, cbcrStride: w,
            )
            XCTAssertEqual(
                contig, expContig,
                "contiguous hashNV12 drifted at w=\(w) h=\(h) (got \(String(contig, radix: 16)))",
            )
            // The array entry must pin to the SAME absolute value too (not just match the pointer entry).
            XCTAssertEqual(
                FrameHasher.hashNV12Scalar(
                    y: yC, yStride: w, width: w, height: h, cbcr: cbcrC, cbcrStride: w,
                ),
                expContig, "contiguous scalar drifted at w=\(w) h=\(h)",
            )

            // Padded (stride == width + 13), luma-only (cbcr == nil). Whole-buffer fill from seed+2.
            let pad = 13
            let yP = pinFill((w + pad) * h, seed &+ 2)
            let padded = pointerHash(
                y: yP, yStride: w + pad, width: w, height: h, cbcr: [], cbcrStride: 0,
            )
            XCTAssertEqual(
                padded, expPadded,
                "padded hashNV12 drifted at w=\(w) h=\(h) (got \(String(padded, radix: 16)))",
            )
            XCTAssertEqual(
                FrameHasher.hashNV12Scalar(
                    y: yP, yStride: w + pad, width: w, height: h, cbcr: [], cbcrStride: 0,
                ),
                expPadded, "padded scalar drifted at w=\(w) h=\(h)",
            )
        }
    }
}
