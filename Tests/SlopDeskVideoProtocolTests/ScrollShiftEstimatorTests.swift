import XCTest
@testable import SlopDeskVideoProtocol

/// Tests for the host-side scroll-shift estimator and the per-row hashing it shares with adaptive-QP.
///
/// Two things are pinned here:
///  1. **The `rowHashes` optimization is byte-identical** — the allocation-free per-row hash
///     (`FrameHasher.hashRow`) must produce exactly the values the per-row `hashNV12` reference does,
///     so swapping the streaming hasher for the contiguous one can't shift the scroll/adaptive-QP math.
///  2. **The brittle-exact-hash bug is fixed** — real captured scroll carries per-pixel capture noise
///     (resample / dither / ±LSB). With EXACT row-hash matching a single noisy pixel changes a row's
///     hash, so a truly-translated row stops matching itself, confidence collapses below the 0.5 gate,
///     and the host reports "no scroll" every frame (the documented `measureScrollOffset == 0` bug).
///     Quantizing the luma (dropping the low bits) collapses that noise so the shift is detected —
///     while a uniform / random / static frame still produces no confident non-zero shift.
final class ScrollShiftEstimatorTests: XCTestCase {
    // MARK: - Synthetic NV12 luma planes (an "editor": uniform background + distinct text rows)

    /// Background luma byte. `≡ 4 (mod 8)` so it sits at the CENTRE of an 8-wide quantization bucket:
    /// ±3 of noise never crosses a `>> 3` bucket boundary, making the quantized-match test deterministic.
    private static let bgByte: UInt8 = 4

    /// A text-row luma byte for `line` at column `x`: a per-(line,x) value, also `≡ 4 (mod 8)`, spread
    /// across buckets 1...24 so every text row has horizontal structure AND a distinct content/hash.
    private static func textByte(line: Int, x: Int) -> UInt8 {
        let bucket = ((line * 5 + x) % 24) + 1 // 1...24 (0 is the background bucket)
        return UInt8(bucket * 8 + 4) // 12...196, ≡ 4 (mod 8)
    }

    /// A row is a "text" row (informative) when `r % 4 == 2`; the rest are uniform background. Each
    /// text row's line id is its own index, so distinct rows have distinct content (unambiguous shift).
    private func editorPlane(w: Int, h: Int, stride: Int) -> [UInt8] {
        var p = [UInt8](repeating: Self.bgByte, count: stride * h)
        for r in 0..<h where r % 4 == 2 {
            for x in 0..<w { p[r * stride + x] = Self.textByte(line: r, x: x) }
        }
        return p
    }

    /// Translates `src` DOWN by `s` rows (content moves down; the top `s` rows reveal background).
    private func shiftDown(_ src: [UInt8], w: Int, h: Int, stride: Int, by s: Int) -> [UInt8] {
        var d = [UInt8](repeating: Self.bgByte, count: stride * h)
        for i in s..<h {
            for x in 0..<w { d[i * stride + x] = src[(i - s) * stride + x] }
        }
        return d
    }

    /// Adds deterministic per-pixel noise in `[-3, 3]` (distinct per `salt`), modelling independent
    /// capture noise on two frames. With the `≡ 4 (mod 8)` base values this never crosses a `>> 3`
    /// bucket edge, so the quantized hashes still match while the exact hashes diverge.
    private func addNoise(_ src: [UInt8], w: Int, h: Int, stride: Int, salt: UInt64) -> [UInt8] {
        var d = src
        for r in 0..<h {
            for x in 0..<w {
                var s = salt &+ UInt64(r) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(x) &* 0xBF58_476D_1CE4_E5B9
                s ^= s >> 31
                let n = Int(s % 7) - 3 // [-3, 3]
                let idx = r * stride + x
                d[idx] = UInt8(max(0, min(255, Int(src[idx]) + n)))
            }
        }
        return d
    }

    /// Drives the pointer entry over two `[UInt8]` planes.
    private func estimate(
        _ prev: [UInt8], _ cur: [UInt8], w: Int, h: Int, stride: Int, maxShift: Int, q: UInt8,
    ) -> (shift: Int32, confidenceMilli: UInt32, bandTop: Int32, bandBottom: Int32) {
        prev.withUnsafeBytes { pb in
            cur.withUnsafeBytes { cb in
                ScrollShiftEstimator.estimateNV12(
                    prevY: pb.baseAddress, prevStride: stride,
                    curY: cb.baseAddress, curStride: stride,
                    width: w, height: h, maxShift: maxShift, quantizeShift: q,
                )
            }
        }
    }

    // MARK: - 1. rowHashes optimization is byte-identical to the hashNV12 reference

    func testRowHashesMatchHashNV12Reference() {
        // A padded plane (stride > width) AND a tight one, several heights, so the per-row path and the
        // contiguous fast path inside hashRow are both exercised and pinned against the public hash.
        for (w, h, pad) in [(37, 20, 11), (64, 8, 0), (1, 5, 3), (100, 33, 7)] {
            let stride = w + pad
            var plane = [UInt8](repeating: 0, count: stride * h)
            var s: UInt64 = 0x1234_5678_9ABC_DEF0
            for i in 0..<plane.count {
                s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                plane[i] = UInt8(truncatingIfNeeded: s >> 33)
            }
            plane.withUnsafeBufferPointer { buf in
                let rows = rowHashes(buf, stride, w, h)
                XCTAssertEqual(rows.count, h, "one hash per row")
                for r in 0..<h {
                    let slice = Array(plane[(r * stride)..<(r * stride + w)])
                    let ref = FrameHasher.hashNV12Scalar(
                        y: slice, yStride: w, width: w, height: 1, cbcr: [], cbcrStride: 0,
                    )
                    XCTAssertEqual(rows[r], ref, "rowHashes[\(r)] must equal the per-row hashNV12 (w=\(w) pad=\(pad))")
                }
            }
        }
    }

    // MARK: - 2. The estimator detects a clean integer scroll (the baseline still works)

    func testDetectsExactIntegerScroll() {
        let w = 40, h = 64, stride = 40, shift = 5
        let prev = editorPlane(w: w, h: h, stride: stride)
        let cur = shiftDown(prev, w: w, h: h, stride: stride, by: shift)
        let r = estimate(prev, cur, w: w, h: h, stride: stride, maxShift: max(8, h / 4), q: 0)
        XCTAssertEqual(r.shift, Int32(shift), "a clean pixel-exact scroll is detected by the exact path")
        XCTAssertGreaterThanOrEqual(r.confidenceMilli, 500, "and is confident")
        XCTAssertGreaterThanOrEqual(r.bandTop, 0, "a real shift carries a moving-content band")
        XCTAssertGreaterThan(r.bandBottom, r.bandTop)
    }

    // MARK: - 3. THE BUG + FIX: exact hashing fails on noisy scroll; quantizing detects it

    func testExactHashFailsOnNoisyScrollQuantizedDetects() {
        let w = 40, h = 64, stride = 40, shift = 5
        let prevClean = editorPlane(w: w, h: h, stride: stride)
        let curClean = shiftDown(prevClean, w: w, h: h, stride: stride, by: shift)
        // Both frames carry INDEPENDENT capture noise (different salts) — the realistic case.
        let prevNoisy = addNoise(prevClean, w: w, h: h, stride: stride, salt: 0xA1)
        let curNoisy = addNoise(curClean, w: w, h: h, stride: stride, salt: 0xB2)
        let maxShift = max(8, h / 4)

        // EXACT (q == 0): every noisy pixel changes its row's hash, so the translated rows no longer
        // match — confidence collapses and the true shift is NOT confidently reported. This is the
        // host's real-world "measureScrollOffset == 0 every frame" failure.
        let exact = estimate(prevNoisy, curNoisy, w: w, h: h, stride: stride, maxShift: maxShift, q: 0)
        XCTAssertFalse(
            exact.shift == Int32(shift) && exact.confidenceMilli >= 500,
            "exact row-hash matching must be too brittle to detect a NOISY scroll (got shift=\(exact.shift) conf=\(exact.confidenceMilli))",
        )

        // QUANTIZED (q == 3): dropping the low 3 luma bits collapses the ±3 noise into one bucket, so
        // the translated rows match again — the true shift is detected confidently.
        let quant = estimate(prevNoisy, curNoisy, w: w, h: h, stride: stride, maxShift: maxShift, q: 3)
        XCTAssertEqual(quant.shift, Int32(shift), "quantized matching recovers the true shift under noise")
        XCTAssertGreaterThanOrEqual(quant.confidenceMilli, 500, "and clears the host's confidence gate")
    }

    // MARK: - 4. False-positive guards (quantizing must not invent scroll)

    func testStaticNoisyFrameReportsNoScroll() {
        // A static window captured twice (same content, INDEPENDENT noise) must NOT read as a scroll.
        let w = 40, h = 64, stride = 40
        let clean = editorPlane(w: w, h: h, stride: stride)
        let a = addNoise(clean, w: w, h: h, stride: stride, salt: 0x11)
        let b = addNoise(clean, w: w, h: h, stride: stride, salt: 0x22)
        let r = estimate(a, b, w: w, h: h, stride: stride, maxShift: max(8, h / 4), q: 3)
        XCTAssertEqual(r.shift, 0, "a static (un-scrolled) frame must report zero shift even quantized")
    }

    func testUniformFrameNoDetection() {
        let w = 32, h = 48, stride = 32
        let flat = [UInt8](repeating: 7, count: stride * h)
        let r = estimate(flat, flat, w: w, h: h, stride: stride, maxShift: max(8, h / 4), q: 3)
        XCTAssertEqual(r.shift, 0, "a fully-uniform frame has no informative rows ⇒ no shift")
        XCTAssertEqual(r.bandTop, -1, "and no band")
        XCTAssertEqual(r.confidenceMilli, 0)
    }

    func testRandomFramesNoConfidentShift() {
        // Two unrelated random frames must not clear the confidence gate at any shift.
        let w = 40, h = 64, stride = 40
        func randomPlane(_ seed: UInt64) -> [UInt8] {
            var s = seed
            var p = [UInt8](repeating: 0, count: stride * h)
            for i in 0..<p.count {
                s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                p[i] = UInt8(truncatingIfNeeded: s >> 33)
            }
            return p
        }
        let r = estimate(randomPlane(1), randomPlane(99), w: w, h: h, stride: stride, maxShift: max(8, h / 4), q: 3)
        XCTAssertLessThan(r.confidenceMilli, 500, "unrelated frames must stay below the host's 0.5 confidence gate")
    }
}
