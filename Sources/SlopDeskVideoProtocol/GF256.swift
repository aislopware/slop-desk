// Arithmetic over the Galois field GF(2^8) — the algebraic substrate for the Reed-Solomon
// erasure code in the video FEC path.
//
// This is the resurrected, native-Swift port of the Rust `slopdesk-core::gf256` reference
// (the all-Swift migration deletes the Rust core + FFI boundary). Elements are bytes; addition is
// XOR and multiplication is polynomial multiplication modulo the primitive polynomial
// x^8 + x^4 + x^3 + x^2 + 1 = 0x11D. `0x02` (the polynomial `x`) generates the multiplicative
// group, so powers 2^0 .. 2^254 enumerate every nonzero element once — the basis of the log/exp
// tables.
//
// THE DOUBLED-512-TABLE TRAP: `EXP` is 512 entries (not 256). `mul` indexes
// `EXP[LOG[a] + LOG[b]]` and that sum reaches up to 254 + 254 = 508, so the upper half MUST mirror
// the lower (`EXP[i] == EXP[i + 255]`). NEVER reduce the index with `% 255` — the doubled table is
// exactly what makes the multiply branchless after the zero short-circuit.
//
// `NeonGf` delegates the hot region multiply to the `CSlopDeskSIMD` C kernel (a tiny C target
// SwiftPM compiles from source with an aarch64 NEON path + scalar fallback). It builds the two
// 16-entry nibble tables here with this same scalar `mul`, so the SIMD result is byte-identical to
// `ScalarGf` — pinned by the differential test.

import CSlopDeskSIMD

/// GF(2^8) field arithmetic: the primitive polynomial and the log/exp tables, plus `mul`/`inv`.
public enum GF256 {
    /// The primitive polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D), reduced into a byte by XOR-ing
    /// whenever a multiply-by-`x` overflows bit 7. The conventional choice (AES, most RS libs).
    public static let primitivePoly: UInt16 = 0x11D

    /// Antilog table, DOUBLED to length 512 (`EXP[i] == EXP[i + 255]` for `i < 255`) so a product's
    /// exponent `LOG[a] + LOG[b]` in 0...508 indexes directly without a `% 255` reduction.
    static let EXP: [UInt8] = buildTables().exp

    /// Discrete-log table base `2`: `LOG[EXP[i]] == i` for `i in 0..<255`. `LOG[0]` is unused
    /// (0 has no log) and is never read on a live path — `mul` short-circuits a zero operand.
    static let LOG: [UInt8] = buildTables().log

    /// Builds both tables once. The cycle is computed in `UInt16` (so the `<< 1` cannot overflow
    /// before the explicit XOR reduction); the upper half of EXP mirrors the lower so `mul` needs
    /// no modular reduction.
    private static func buildTables() -> (exp: [UInt8], log: [UInt8]) {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var value: UInt16 = 1
        var i = 0
        while i < 255 {
            exp[i] = UInt8(value)
            log[Int(value)] = UInt8(i)
            // Multiply by x (left shift), reducing if it overflows the field's 8 bits.
            value <<= 1
            if value & 0x100 != 0 {
                value ^= 0x11D
            }
            i += 1
        }
        // Mirror the cycle into the upper half so EXP[a + b] never needs `% 255`.
        var j = 255
        while j < 512 {
            exp[j] = exp[j - 255]
            j += 1
        }
        return (exp, log)
    }

    /// Field multiplication: `0` if either operand is `0` (the absorbing element), otherwise
    /// `EXP[LOG[a] + LOG[b]]`. The sum is computed in `Int` (it can reach 508 — UInt8 would trap).
    @inline(__always)
    public static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return EXP[Int(LOG[Int(a)]) + Int(LOG[Int(b)])]
    }

    /// Multiplicative inverse: the unique `x` with `mul(a, x) == 1`, computed as
    /// `EXP[255 - LOG[a]]` (since `a * a^254 == a^255 == 1`). Precondition: `a != 0`.
    @inline(__always)
    public static func inv(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "GF(2^8) inverse of zero is undefined")
        return EXP[255 - Int(LOG[Int(a)])]
    }
}

/// A region-wise GF(2^8) arithmetic backend: accumulates over borrowed byte slices in place with
/// zero allocation, so a Reed-Solomon encode/decode folds many shards into a pre-sized accumulator.
public protocol GfRegion {
    /// `dst[i] ^= mul(coeff, src[i])` for every `i in 0..<src.count`. Caller guarantees
    /// `dst.count >= src.count`; bytes past `src.count` are left untouched.
    func mulAdd(coeff: UInt8, src: [UInt8], dst: inout [UInt8])

    /// `dst[i] ^= src[i]` for every `i in 0..<src.count` (the `coeff == 1` fast path).
    func xorAdd(src: [UInt8], dst: inout [UInt8])

    /// `Unsafe`-pointer overload of ``mulAdd(coeff:src:dst:)`` for the FEC hot path: lets a caller
    /// that already holds contiguous buffers fold a scaled shard in WITHOUT `[UInt8]` CoW / bounds
    /// overhead. `dst.count >= src.count`; only the first `src.count` bytes of `dst` are touched.
    /// Byte-identical to the `[UInt8]` overload.
    func mulAdd(coeff: UInt8, src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>)

    /// `Unsafe`-pointer overload of ``xorAdd(src:dst:)`` (the `coeff == 1` region-add fast path).
    func xorAdd(src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>)
}

public extension GfRegion {
    /// Default unsafe overload: bridge the pointers back into the array API so any backend that
    /// does not specialise still satisfies the protocol. The production ``NeonGf``/``ScalarGf``
    /// override these with a zero-copy body.
    func mulAdd(coeff: UInt8, src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>) {
        var dstArray = Array(dst)
        mulAdd(coeff: coeff, src: Array(src), dst: &dstArray)
        for i in 0..<dstArray.count { dst[i] = dstArray[i] }
    }

    func xorAdd(src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>) {
        var dstArray = Array(dst)
        xorAdd(src: Array(src), dst: &dstArray)
        for i in 0..<dstArray.count { dst[i] = dstArray[i] }
    }
}

/// Portable, pure-Swift scalar `GfRegion` driven by the `GF256` tables (one byte at a time).
public struct ScalarGf: GfRegion {
    public init() {}

    @inline(__always)
    public func mulAdd(coeff: UInt8, src: [UInt8], dst: inout [UInt8]) {
        assert(dst.count >= src.count, "mulAdd dst shorter than src")
        // `coeff == 0` contributes nothing; `coeff == 1` is a plain region XOR.
        if coeff == 0 { return }
        if coeff == 1 {
            xorAdd(src: src, dst: &dst)
            return
        }
        let logCoeff = Int(GF256.LOG[Int(coeff)])
        for i in 0..<src.count {
            let s = src[i]
            if s != 0 {
                dst[i] ^= GF256.EXP[logCoeff + Int(GF256.LOG[Int(s)])]
            }
        }
    }

    @inline(__always)
    public func xorAdd(src: [UInt8], dst: inout [UInt8]) {
        assert(dst.count >= src.count, "xorAdd dst shorter than src")
        for i in 0..<src.count {
            dst[i] ^= src[i]
        }
    }

    @inline(__always)
    public func mulAdd(coeff: UInt8, src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>) {
        assert(dst.count >= src.count, "mulAdd dst shorter than src")
        if coeff == 0 { return }
        if coeff == 1 {
            xorAdd(src: src, dst: dst)
            return
        }
        let logCoeff = Int(GF256.LOG[Int(coeff)])
        for i in 0..<src.count {
            let s = src[i]
            if s != 0 {
                dst[i] ^= GF256.EXP[logCoeff + Int(GF256.LOG[Int(s)])]
            }
        }
    }

    @inline(__always)
    public func xorAdd(src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>) {
        assert(dst.count >= src.count, "xorAdd dst shorter than src")
        for i in 0..<src.count {
            dst[i] ^= src[i]
        }
    }
}

/// SIMD `GfRegion` that delegates the inner loop to the `CSlopDeskSIMD` C kernel (aarch64 NEON +
/// scalar fallback). Builds the two 16-entry nibble tables with `GF256.mul`, so the result is
/// byte-identical to `ScalarGf`. Matches the Rust `NeonGf` semantics: only the first `src.count`
/// bytes of `dst` are touched, trailing `dst` stays as-is.
public struct NeonGf: GfRegion {
    public init() {}

    public func mulAdd(coeff: UInt8, src: [UInt8], dst: inout [UInt8]) {
        assert(dst.count >= src.count, "mulAdd dst shorter than src")
        // `coeff == 0` contributes nothing; `coeff == 1` is a plain region XOR.
        if coeff == 0 { return }
        if coeff == 1 {
            xorAdd(src: src, dst: &dst)
            return
        }
        let n = src.count
        if n == 0 { return }
        dst.withUnsafeMutableBufferPointer { dstBuf in
            src.withUnsafeBufferPointer { srcBuf in
                Self.mulAddCore(coeff: coeff, src: srcBuf, dst: dstBuf, n: n)
            }
        }
    }

    public func mulAdd(coeff: UInt8, src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>) {
        assert(dst.count >= src.count, "mulAdd dst shorter than src")
        if coeff == 0 { return }
        if coeff == 1 {
            xorAdd(src: src, dst: dst)
            return
        }
        let n = src.count
        if n == 0 { return }
        Self.mulAddCore(coeff: coeff, src: src, dst: dst, n: n)
    }

    /// The shared SIMD `mulAdd` body. Builds the two 16-entry nibble tables ON THE STACK (no
    /// per-call heap `[UInt8]` allocation) with the SAME scalar multiply so the SIMD output is
    /// byte-identical to ScalarGf: lo[i] = mul(coeff, i), hi[i] = mul(coeff, i << 4) for i in
    /// 0..<16. `i << 4` is taken as a UInt8 (the high nibble values 0x00, 0x10, ..., 0xf0).
    /// Touches only the first `n` bytes of dst (matches the Rust `&mut dst[..n]` slicing).
    /// Precondition: `coeff >= 2`, `n >= 1`, `dst.count >= n`.
    @inline(__always)
    private static func mulAddCore(
        coeff: UInt8,
        src: UnsafeBufferPointer<UInt8>,
        dst: UnsafeMutableBufferPointer<UInt8>,
        n: Int,
    ) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { tableBuf in
            for i in 0..<16 {
                tableBuf[i] = GF256.mul(coeff, UInt8(i)) // table_lo
                tableBuf[16 + i] = GF256.mul(coeff, UInt8(i) << 4) // table_hi
            }
            // SAFETY: caller guaranteed `n >= 1` and `dst.count >= n`, so dst/src baseAddress are
            // non-nil; tableBuf is a 32-byte stack buffer so its baseAddress is non-nil and the
            // lo/hi halves are 16 contiguous bytes each.
            // swiftlint:disable force_unwrapping
            aisd_simd_gf_mul_add(
                dst.baseAddress!,
                src.baseAddress!,
                n,
                tableBuf.baseAddress!,
                tableBuf.baseAddress! + 16,
            )
            // swiftlint:enable force_unwrapping
        }
    }

    public func xorAdd(src: [UInt8], dst: inout [UInt8]) {
        assert(dst.count >= src.count, "xorAdd dst shorter than src")
        let n = src.count
        if n == 0 { return }
        dst.withUnsafeMutableBufferPointer { dstBuf in
            src.withUnsafeBufferPointer { srcBuf in
                // SAFETY: `n == 0` returned above, so dst/src are non-empty and baseAddress non-nil.
                // swiftlint:disable:next force_unwrapping
                aisd_simd_gf_xor_add(dstBuf.baseAddress!, srcBuf.baseAddress!, n)
            }
        }
    }

    public func xorAdd(src: UnsafeBufferPointer<UInt8>, dst: UnsafeMutableBufferPointer<UInt8>) {
        assert(dst.count >= src.count, "xorAdd dst shorter than src")
        let n = src.count
        if n == 0 { return }
        // SAFETY: `n == 0` returned above, so dst/src are non-empty and baseAddress non-nil.
        // swiftlint:disable:next force_unwrapping
        aisd_simd_gf_xor_add(dst.baseAddress!, src.baseAddress!, n)
    }
}
