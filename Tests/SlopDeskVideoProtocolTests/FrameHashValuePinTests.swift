import XCTest
@testable import SlopDeskVideoProtocol

/// Absolute value pins for the NV12 frame hash, over the real door.
///
/// The fold itself lives in `rust/slopdesk-video`'s `frame_hash` and is unit-tested there. These
/// constants are older than that port: they were produced by the Swift original, and they are kept
/// here precisely because they are the one thing the Rust could have got subtly wrong and no test
/// on its own side would have noticed. The hash is xxHash64-SHAPED but not xxHash64 (its fifth lane
/// prime is the repo's own), so there is no published oracle to check it against — only these.
///
/// A drift here is not cosmetic: the whole-frame value decides whether a captured frame is a
/// byte-identical re-delivery and can skip the encoder. Hashing two different frames equal freezes
/// the client on stale content.
///
/// What used to be here as well — a differential between a pointer entry and an array entry — went
/// with the port. There is one entry now, so there is nothing to hold in step with it.
final class FrameHashValuePinTests: XCTestCase {
    /// Drives the pointer entry over `[UInt8]` planes the test owns.
    private func hash(
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

    /// Fills `count` bytes from a stateful LCG seeded with `seed`, taking the same high-byte slice
    /// (`s >> 33`) every step, so the pins below are reproducible from this recipe alone.
    private func pinFill(_ count: Int, _ seed: UInt64) -> [UInt8] {
        var s = seed
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out[i] = UInt8(truncatingIfNeeded: s >> 33)
        }
        return out
    }

    /// Pins the hash to EXACT 64-bit constants on three deterministic frames, contiguous and padded.
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
            let contig = hash(
                y: pinFill(w * h, seed), yStride: w, width: w, height: h,
                cbcr: pinFill(w * (h / 2), seed &+ 1), cbcrStride: w,
            )
            XCTAssertEqual(
                contig, expContig,
                "contiguous hashNV12 drifted at w=\(w) h=\(h) (got \(String(contig, radix: 16)))",
            )
            // Padded (stride == width + 13), luma-only (cbcr == nil). Whole-buffer fill from seed+2.
            let pad = 13
            let padded = hash(
                y: pinFill((w + pad) * h, seed &+ 2), yStride: w + pad, width: w, height: h,
                cbcr: [], cbcrStride: 0,
            )
            XCTAssertEqual(
                padded, expPadded,
                "padded hashNV12 drifted at w=\(w) h=\(h) (got \(String(padded, radix: 16)))",
            )
        }
    }

    /// The hash must be sensitive to any single visible byte — a missed difference is a real frame
    /// suppressed, which the viewer sees as a freeze.
    func testOneBytePlaneFlipChangesTheHash() {
        let (w, h) = (64, 48)
        var y = pinFill(w * h, 0x0BAD_F00D_1234_5678)
        let base = hash(y: y, yStride: w, width: w, height: h, cbcr: [], cbcrStride: 0)
        var index = 0
        while index < y.count {
            y[index] ^= 0x01
            XCTAssertNotEqual(
                base, hash(y: y, yStride: w, width: w, height: h, cbcr: [], cbcrStride: 0),
                "flipping byte \(index) left the hash unchanged",
            )
            y[index] ^= 0x01
            index += 37
        }
    }

    /// Padding is not part of the picture: the same visible bytes behind a wider stride hash equal.
    func testPaddingDoesNotReachTheHash() {
        let (w, h, pad) = (37, 20, 11)
        let tight = pinFill(w * h, 0x1234_5678_9ABC_DEF0)
        var padded = [UInt8](repeating: 0xA5, count: (w + pad) * h)
        for row in 0..<h {
            for column in 0..<w { padded[row * (w + pad) + column] = tight[row * w + column] }
        }
        XCTAssertEqual(
            hash(y: tight, yStride: w, width: w, height: h, cbcr: [], cbcrStride: 0),
            hash(y: padded, yStride: w + pad, width: w, height: h, cbcr: [], cbcrStride: 0),
            "a padded plane must hash as its visible bytes",
        )
    }

    /// An unhashable call answers the sentinel the door vends, and never faults.
    func testDegenerateInputAnswersTheSentinel() {
        let plane = pinFill(64, 1)
        XCTAssertEqual(
            FrameHasher.hashNV12(y: nil, yStride: 8, width: 8, height: 8, cbcr: nil, cbcrStride: 0),
            FrameHash.SENTINEL, "a null plane must answer the sentinel",
        )
        // A stride narrower than the visible width describes a plane that cannot exist.
        XCTAssertEqual(
            hash(y: plane, yStride: 4, width: 8, height: 8, cbcr: [], cbcrStride: 0),
            FrameHash.SENTINEL, "a stride under the width must answer the sentinel",
        )
        XCTAssertEqual(
            hash(y: plane, yStride: 8, width: 8, height: 0, cbcr: [], cbcrStride: 0),
            FrameHash.SENTINEL, "a zero height must answer the sentinel",
        )
    }
}
