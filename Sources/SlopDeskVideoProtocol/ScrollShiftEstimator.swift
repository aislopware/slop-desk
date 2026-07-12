// Pure dominant-vertical-shift estimator for scroll reprojection (host side), plus the per-row NEON
// luma hashing seam over locked NV12 planes.
//
// This mirrors the Rust `slopdesk-core::scroll_shift` reference (`estimate_vertical_shift`) and the
// `slopdesk-ffi::video::scroll_shift` per-row hashing / `aisd_estimate_scroll_shift_nv12` ABI
// bit-for-bit — any drift from that reference behavior is a bug. The row hashing reuses
// `FrameHasher` (one row hashed as a 1-row luma-only NV12 frame), so row hashes stay byte-identical
// to the per-row NV12 hash path.
//
// ## What it does
//
// The host hashes each ROW of a captured luma plane and, frame-to-frame, asks: *did the content
// translate vertically, and by how many rows?* For an editor that answer is the true scroll amount.
// The host sends it to the client, which warps the last frame by it on spare 120 Hz ticks.
//
// ## The uniform-row trap
//
// A code editor is mostly uniform background rows that all hash IDENTICALLY. If counted as matches,
// EVERY candidate shift would "match" the hundreds of background rows and confidence would be falsely
// ~1.0. So we exclude the MODE hash (the background) and score the shift only over the INFORMATIVE
// rows (text/edges).
//
// ## Bit-exact traps
//
// Integer row-hash compare; NaN-faithful ordered min/max as the Rust form; validate inputs. The
// confidence is `best_matches / informative.len` as `f64` (a plain division, no fma).

/// The result of a vertical-shift estimate. Mirrors the Rust `ShiftEstimate`.
public struct ShiftEstimate: Equatable, Sendable {
    /// The dominant vertical shift in ROWS. Positive = content moved DOWN by `shift` rows
    /// (row `i` of the current frame equals row `i - shift` of the previous frame). `0` = no shift.
    public var shift: Int32
    /// Fraction of INFORMATIVE rows that match at `shift` (0.0...1.0). The caller gates on this.
    public var confidence: Double
    /// Inclusive `[top, bottom]` CURRENT-frame row span of the informative rows that translated by
    /// `shift` — the vertical extent of the MOVING content (chrome excluded). `nil` when there is no
    /// confident non-zero shift.
    public var band: (Int, Int)?

    public init(shift: Int32, confidence: Double, band: (Int, Int)?) {
        self.shift = shift
        self.confidence = confidence
        self.band = band
    }

    /// The "no confident shift" result.
    public static let none = Self(shift: 0, confidence: 0.0, band: nil)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.shift == rhs.shift
            && lhs.confidence == rhs.confidence
            && lhs.band?.0 == rhs.band?.0
            && lhs.band?.1 == rhs.band?.1
    }
}

public enum ScrollShiftEstimator {
    // MARK: - Pure estimator (array-based; the source of truth, directly testable)

    /// Estimates the dominant vertical content shift between two frames' per-row luma hashes.
    ///
    /// `prev` / `cur` are the row-hash arrays (index = row, top to bottom). `maxShift` bounds the
    /// search (rows). Returns `.none` when there is nothing to measure (empty input, an all-uniform
    /// frame, or no informative match). `shift = +k` means the picture scrolled DOWN by `k` rows —
    /// `cur[i] == prev[i - k]`. Mirrors the Rust `estimate_vertical_shift`.
    public static func estimateVerticalShift(
        _ prev: [UInt64], _ cur: [UInt64], _ maxShift: Int,
    ) -> ShiftEstimate {
        let n = min(prev.count, cur.count)
        if n == 0 { return .none }
        let background = modeHash(cur, n)
        // Informative rows = current rows that are NOT the background. Collect their indices once.
        var informative: [Int] = []
        informative.reserveCapacity(n)
        for i in 0..<n where cur[i] != background { informative.append(i) }
        if informative.isEmpty { return .none } // a blank / fully-uniform frame: no scroll signal

        let maxD = Int32(min(maxShift, n))
        var bestShift: Int32 = 0
        var bestMatches = 0
        var d: Int32 = -maxD
        while d <= maxD {
            var matches = 0
            for i in informative {
                let j = Int32(i) - d
                if j >= 0, Int(j) < n, prev[Int(j)] == cur[i] { matches += 1 }
            }
            // Strictly-greater keeps the earlier (more-negative) d on a tie; the explicit
            // |d| < |bestShift| re-bias then prefers the smaller magnitude for determinism (matches
            // the Rust ordering exactly).
            if matches > bestMatches || (matches == bestMatches && d.magnitude < bestShift.magnitude) {
                bestMatches = matches
                bestShift = d
            }
            d += 1
        }

        // The moving-content band: the inclusive top/bottom row span of the informative rows that
        // actually translated by the winning shift. Only meaningful for a real (non-zero, matched)
        // scroll; a `0` shift has nothing to reproject so the band is `nil`.
        var band: (Int, Int)?
        if bestShift != 0, bestMatches > 0 {
            var top: Int?
            var bottom = 0
            for i in informative {
                let j = Int32(i) - bestShift
                if j >= 0, Int(j) < n, prev[Int(j)] == cur[i] {
                    if top == nil { top = i }
                    bottom = i
                }
            }
            if let t = top { band = (t, bottom) }
        }

        return ShiftEstimate(
            shift: bestShift,
            confidence: Double(bestMatches) / Double(informative.count),
            band: band,
        )
    }

    /// The most frequent value in the first `n` entries of `rows` (the background row hash). Linear
    /// scan with a small running-best; for the typical editor the background dominates immediately.
    private static func modeHash(_ rows: [UInt64], _ n: Int) -> UInt64 {
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(n)
        var best = rows[0]
        var bestCount = 0
        for idx in 0..<n {
            let h = rows[idx]
            let c = (counts[h] ?? 0) + 1
            counts[h] = c
            if c > bestCount {
                bestCount = c
                best = h
            }
        }
        return best
    }

    // MARK: - NV12 plane entry (matches the `aisd_estimate_scroll_shift_nv12` ABI)

    /// Estimates the dominant VERTICAL content shift (pixel rows) between two locked NV12 luma planes
    /// over BORROWED pointers (zero-copy). Returns `(shift, confidenceMilli, bandTop, bandBottom)`:
    /// `shift` positive = content moved DOWN; `confidenceMilli` ∈ 0...1000; `bandTop`/`bandBottom`
    /// are the inclusive current-frame ROW span of the moving content (chrome excluded), or `-1`/`-1`
    /// when there is no confident scroll. A degenerate dimension / null pointer / stride overflow ⇒
    /// `(0, 0, -1, -1)` (a non-fault "no measurement"). `quantizeShift` (0...7) right-shifts each
    /// luma byte before row-hashing so real capture noise no longer breaks the exact row match (see
    /// ``rowHashesQuantized``); `0` is the exact, byte-for-byte path. Mirrors the Rust FFI exactly.
    public static func estimateNV12(
        prevY: UnsafeRawPointer?,
        prevStride: Int,
        curY: UnsafeRawPointer?,
        curStride: Int,
        width: Int,
        height: Int,
        maxShift: Int,
        quantizeShift: UInt8 = 0,
    ) -> (shift: Int32, confidenceMilli: UInt32, bandTop: Int32, bandBottom: Int32) {
        // The 16384 ceiling (above any real display) HARD-GUARDS the row-hash arrays against an
        // absurd dimension. Any degenerate / overflowing input ⇒ a defined "no measurement".
        guard let prevPlane = borrowPlane(prevY, prevStride, width, height),
              let curPlane = borrowPlane(curY, curStride, width, height)
        else { return (0, 0, -1, -1) }

        let prevRows = rowHashesQuantized(prevPlane, prevStride, width, height, quantizeShift)
        let curRows = rowHashesQuantized(curPlane, curStride, width, height, quantizeShift)
        let est = estimateVerticalShift(prevRows, curRows, maxShift)
        // confidence ∈ [0, 1] ⇒ milli ∈ [0, 1000]; SEPARATE clamp then ×1000 then round.
        let milli = UInt32((min(max(est.confidence, 0.0), 1.0) * 1000.0).rounded())
        let (bandTop, bandBottom): (Int32, Int32)
        if let b = est.band {
            bandTop = Int32(b.0)
            bandBottom = Int32(b.1)
        } else {
            bandTop = -1
            bandBottom = -1
        }
        return (est.shift, milli, bandTop, bandBottom)
    }
}

/// Validates an NV12 luma plane's dimensions/stride and borrows exactly `stride * height` bytes as a
/// read-only buffer, or returns `nil` for any degenerate / absurd / overflowing input (no fault).
/// Shared by the scroll-shift and adaptive-QP NV12 entries. Pointer borrowed for the call only.
func borrowPlane(
    _ base: UnsafeRawPointer?, _ stride: Int, _ width: Int, _ height: Int,
) -> UnsafeBufferPointer<UInt8>? {
    guard let base, width > 0, height > 0, width <= 16384, height <= 16384, stride >= width
    else { return nil }
    let (len, overflow) = stride.multipliedReportingOverflow(by: height)
    if overflow { return nil }
    return UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: len)
}

/// Per-row luma hashes: hashes the first `width` bytes of each of the `height` `stride`-spaced rows,
/// bounds-guarded per row (an over-stated `height` stops early rather than reading OOB). Each row is
/// hashed via the allocation-free ``FrameHasher/hashRow(_:seed:)`` — byte-identical to hashing it as
/// a 1-row luma-only NV12 frame, but without a per-row `StreamHasher` heap buffer, so a 1080-row
/// plane costs one allocation total rather than 1080 small ones.
func rowHashes(
    _ y: UnsafeBufferPointer<UInt8>, _ stride: Int, _ width: Int, _ height: Int,
) -> [UInt64] {
    var out: [UInt64] = []
    out.reserveCapacity(height)
    guard let yBase = y.baseAddress, width > 0 else { return out }
    for r in 0..<height {
        let start = r * stride
        if start + width > y.count { break }
        out.append(FrameHasher.hashRow(
            UnsafeBufferPointer(start: yBase + start, count: width), seed: FrameHash.frameHashSeed,
        ))
    }
    return out
}

/// Per-row luma hashes over QUANTIZED luma: each byte is right-shifted by `qShift` bits before
/// hashing, so two rows that are the same content under small per-pixel capture noise (resample /
/// dither / ±LSB) hash IDENTICALLY. The scroll estimator matches rows by EXACT hash equality, which
/// is too brittle for real captured scroll (a single noisy pixel changes a row's hash and the row
/// stops matching its translated self → confidence collapses → no scroll detected). Dropping the low
/// `qShift` bits collapses that noise into the same bucket so a truly-translated row still matches.
/// `qShift == 0` is the exact path (delegates to ``rowHashes``). Distinct-content rows still hash
/// differently (the ≥0.5 confidence gate remains the false-positive guard). One reused scratch row,
/// so still a single allocation regardless of height.
func rowHashesQuantized(
    _ y: UnsafeBufferPointer<UInt8>, _ stride: Int, _ width: Int, _ height: Int, _ qShift: UInt8,
) -> [UInt64] {
    if qShift == 0 { return rowHashes(y, stride, width, height) }
    var out: [UInt64] = []
    out.reserveCapacity(height)
    guard let yBase = y.baseAddress, width > 0 else { return out }
    var scratch = [UInt8](repeating: 0, count: width)
    for r in 0..<height {
        let start = r * stride
        if start + width > y.count { break }
        let rowBase = yBase + start
        let h = scratch.withUnsafeMutableBufferPointer { s -> UInt64 in
            for k in 0..<width { s[k] = rowBase[k] >> qShift }
            return FrameHasher.hashRow(UnsafeBufferPointer(s), seed: FrameHash.frameHashSeed)
        }
        out.append(h)
    }
    return out
}
