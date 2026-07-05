// Pure adaptive per-frame QP-ceiling law: "sharp on a small change, blur graded by burst size",
// plus the per-row NEON luma hashing seam over locked NV12 planes.
//
// This is the resurrected, native-Swift port of the Rust `slopdesk-core::adaptive_qp` reference
// (`changed_fraction` / `adaptive_max_qp`) PLUS the `aisd_adaptive_frame_qp_nv12` ABI — the all-Swift
// migration deletes the Rust core + FFI boundary. The row hashing reuses the shared `rowHashes`
// (via `FrameHasher`), byte-identical to the old kernel.
//
// ## Why this exists
//
// Pure-VBR grades quality with complexity, but under congestion control VBR meets the AVERAGE by
// raising QP across EVERY frame — so a 1-row caret move is coarsened alongside a scroll burst. This
// law derives a PER-FRAME ceiling from the frame's measured change magnitude: small change → a tight
// (low) ceiling the RC cannot coarsen past (stays sharp); big burst → the ceiling rides up to the
// configured max (graded blur).
//
// ## Bit-exact trap (THE QP RAMP IS FLOAT)
//
// `t = (b - b_lo) / (b_hi - b_lo); ramp = t * range; q = qp_sharp + ramp` — keep the `mul` and the
// `add` SEPARATE (NEVER `fma`/`*+` fused), THEN `.rounded()` (half-away) + clamp. Float math uses
// ORDERED comparisons; a non-finite `b` is treated as `b_lo` (sharp).

public enum AdaptiveFrameQP {
    // MARK: - Pure laws (array-based; the source of truth, directly testable)

    /// Fraction of rows that changed between two frames' per-row luma hashes (`0.0...1.0`): the count
    /// of indices where the hashes differ, over the compared (min) length. Empty input ⇒ `0.0`.
    /// Mirrors the Rust `changed_fraction`.
    public static func changedFraction(_ prev: [UInt64], _ cur: [UInt64]) -> Double {
        let n = min(prev.count, cur.count)
        if n == 0 { return 0.0 }
        var changed = 0
        for i in 0..<n where prev[i] != cur[i] { changed += 1 }
        return Double(changed) / Double(n)
    }

    /// Maps a change fraction `b` to a per-frame `MaxAllowedFrameQP` ceiling.
    ///
    /// * `b <= bLo` (small change) ⇒ `qpSharp` (a tight, low ceiling — stays sharp).
    /// * `b >= bHi` (big burst) ⇒ `qpMax` (the configured live ceiling — graded blur allowed).
    /// * between ⇒ a linear ramp from `qpSharp` up to `qpMax`.
    ///
    /// `qpSharp` is the sharp (low) end and should be `<= qpMax`; if `qpSharp >= qpMax` returns
    /// `qpMax` (no ramp). A non-finite `b` is treated as `bLo` (sharp). A degenerate band
    /// (`bHi <= bLo`) collapses to a step at `bLo`. Mirrors the Rust `adaptive_max_qp`.
    public static func adaptiveMaxQP(
        _ b: Double, qpSharp: UInt8, qpMax: UInt8, bLo: Double, bHi: Double,
    ) -> UInt8 {
        if qpSharp >= qpMax { return qpMax }
        // ORDERED comparisons: `!b.isFinite` catches NaN/±inf; `b <= bLo` is a single ordered test.
        if !b.isFinite || b <= bLo { return qpSharp }
        if b >= bHi || bHi <= bLo { return qpMax }

        // Linear ramp. t ∈ (0, 1); SEPARATE mul + add (NO fma) to keep the result bit-stable.
        let t = (b - bLo) / (bHi - bLo)
        let range = Double(qpMax) - Double(qpSharp)
        let ramp = t * range // <- separate MUL
        let q = Double(qpSharp) + ramp // <- separate ADD (never fused with the mul above)
        let rounded = q.rounded() // half-away-from-zero (Swift default), matching Rust `f64::round`
        // rounded ∈ [qpSharp, qpMax] ⊂ [0, 255]; clamp defensively before the cast.
        if rounded <= Double(qpSharp) {
            return qpSharp
        }
        if rounded >= Double(qpMax) {
            return qpMax
        }
        return UInt8(rounded)
    }

    // MARK: - NV12 plane entry (matches the old `aisd_adaptive_frame_qp_nv12` ABI)

    // A 1:1 mirror of the wide NV12-plane signature (two planes + strides + the QP curve params),
    // hence the parameter count.
    // swiftlint:disable function_parameter_count
    /// Adaptive per-frame QP ceiling from the inter-frame change magnitude over two locked NV12 luma
    /// planes (BORROWED pointers, zero-copy). Returns `(qp, changeMilli)`: `qp` is the ceiling to set
    /// on the live frame; `changeMilli` is the measured change fraction ×1000 (logging). `bLoMilli` /
    /// `bHiMilli` are the change-fraction thresholds ×1000. A degenerate / null / overflowing input ⇒
    /// `(qpMax, 0)` (no adaptive narrowing — the safe "use the static ceiling" fallback). Mirrors the
    /// Rust FFI exactly.
    public static func computeNV12(
        prevY: UnsafeRawPointer?,
        prevStride: Int,
        curY: UnsafeRawPointer?,
        curStride: Int,
        width: Int,
        height: Int,
        qpSharp: UInt8,
        qpMax: UInt8,
        bLoMilli: UInt32,
        bHiMilli: UInt32,
    ) -> (qp: UInt8, changeMilli: UInt32) {
        guard let prevPlane = borrowPlane(prevY, prevStride, width, height),
              let curPlane = borrowPlane(curY, curStride, width, height)
        else { return (qpMax, 0) } // unmeasurable ⇒ apply the configured static ceiling

        let prevRows = rowHashes(prevPlane, prevStride, width, height)
        let curRows = rowHashes(curPlane, curStride, width, height)
        let b = changedFraction(prevRows, curRows)
        let bLo = Double(bLoMilli) / 1000.0
        let bHi = Double(bHiMilli) / 1000.0
        let qp = adaptiveMaxQP(b, qpSharp: qpSharp, qpMax: qpMax, bLo: bLo, bHi: bHi)
        // b ∈ [0, 1] ⇒ milli ∈ [0, 1000]; SEPARATE clamp then ×1000 then round.
        let changeMilli = UInt32((min(max(b, 0.0), 1.0) * 1000.0).rounded())
        return (qp, changeMilli)
    }
    // swiftlint:enable function_parameter_count
}
