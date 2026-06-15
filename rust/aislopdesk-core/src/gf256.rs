//! Arithmetic over the Galois field GF(2^8), the algebraic substrate for the
//! Reed-Solomon erasure code in [`crate::fec`].
//!
//! Elements are bytes; addition is XOR (its own inverse, carry-free) and
//! multiplication is polynomial multiplication modulo the primitive (irreducible)
//! polynomial `x^8 + x^4 + x^3 + x^2 + 1` = `0x11D`. `0x02` (the polynomial `x`) is a
//! generator of the multiplicative group, so the powers `2^0, 2^1, …, 2^254` enumerate
//! every nonzero element exactly once — the basis of the log/exp tables below.
//!
//! ## Tables
//!
//! Both tables are built by a `const fn` at compile time, so they cost no runtime
//! initialisation, no allocation, and no `unsafe` (a `OnceLock`/`lazy_static` would
//! need a dependency or interior mutability we deliberately avoid).
//!
//! * [`EXP`] is `[u8; 512]`: `EXP[i] = 2^(i mod 255)` for the antilog, *doubled* to
//!   length 512 so that `EXP[log[a] + log[b]]` is always in range without a modular
//!   reduction — the standard branchless-multiply trick (`log[a] + log[b]` is at most
//!   `254 + 254 = 508 < 512`).
//! * [`LOG`] is `[u8; 256]`: `LOG[v]` is the discrete log of `v` base `2`. `LOG[0]` is
//!   meaningless (0 has no log) and is never indexed on a live path — [`mul`] short-circuits
//!   a zero operand before any table lookup.

/// The primitive polynomial `x^8 + x^4 + x^3 + x^2 + 1` (`0x11D`), reduced into a byte by
/// XOR-ing whenever a multiply-by-`x` overflows bit 7. This is the conventional choice
/// (AES, most RS libraries) so the field — and thus every coefficient — matches reference
/// implementations bit-for-bit.
const PRIMITIVE_POLY: u16 = 0x11D;

/// Antilog table, doubled to length 512 (`EXP[i] == EXP[i + 255]` for `i < 255`) so a
/// product's exponent `log[a] + log[b] ∈ 0..=508` indexes directly without reduction.
const EXP: [u8; 512] = build_exp();

/// Discrete-log table base `2`: `LOG[EXP[i]] == i` for `i ∈ 0..255`. `LOG[0]` is unused.
const LOG: [u8; 256] = build_log(&EXP);

/// Builds the antilog table at compile time by repeatedly multiplying by the generator
/// `0x02` (polynomial `x`) and reducing modulo [`PRIMITIVE_POLY`]. The first 255 entries
/// cycle through every nonzero element; the upper half mirrors the lower so out-of-range
/// reduction is unnecessary in [`mul`].
const fn build_exp() -> [u8; 512] {
    let mut table = [0u8; 512];
    let mut value: u16 = 1;
    let mut i = 0usize;
    while i < 255 {
        table[i] = value as u8;
        // Multiply by x (left shift), reducing if it overflows the field's 8 bits.
        value <<= 1;
        if value & 0x100 != 0 {
            value ^= PRIMITIVE_POLY;
        }
        i += 1;
    }
    // Mirror the cycle into the upper half so EXP[a + b] never needs `% 255`.
    let mut j = 255usize;
    while j < 512 {
        table[j] = table[j - 255];
        j += 1;
    }
    table
}

/// Inverts [`build_exp`] into the log table: `LOG[EXP[i]] = i` for `i ∈ 0..255`. Index 0
/// is left as 0 (and never read on a live path).
const fn build_log(exp: &[u8; 512]) -> [u8; 256] {
    let mut table = [0u8; 256];
    let mut i = 0usize;
    while i < 255 {
        table[exp[i] as usize] = i as u8;
        i += 1;
    }
    table
}

/// Field multiplication: `0` if either operand is `0` (the field's absorbing element),
/// otherwise `exp[log[a] + log[b]]`. Branchless after the zero short-circuit thanks to
/// the doubled [`EXP`] table.
#[inline]
#[must_use]
pub const fn mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        return 0;
    }
    EXP[LOG[a as usize] as usize + LOG[b as usize] as usize]
}

/// Multiplicative inverse: the unique `x` with `mul(a, x) == 1`, computed as
/// `exp[255 - log[a]]` (since `a * a^254 == a^255 == 1` in GF(2^8)).
///
/// `inv(0)` is mathematically undefined; it returns `0` and trips a `debug_assert` —
/// callers (Gauss-Jordan pivoting) never invert a zero pivot.
#[inline]
#[must_use]
pub const fn inv(a: u8) -> u8 {
    debug_assert!(a != 0, "GF(2^8) inverse of zero is undefined");
    if a == 0 {
        return 0;
    }
    EXP[255 - LOG[a as usize] as usize]
}

/// A region-wise GF(2^8) arithmetic backend.
///
/// Implementors accumulate over *borrowed* byte slices in place with **zero allocation**,
/// so a Reed-Solomon encode/decode can fold many shards into a pre-sized accumulator
/// without per-operation heap traffic. A scalar table-driven backend ([`ScalarGf`]) is the
/// portable default; a SIMD backend can implement the same trait later without touching the
/// codec.
pub trait GfRegion: Sync {
    /// `dst[i] ^= mul(coeff, src[i])` for every `i ∈ 0..src.len()` (a scaled XOR-accumulate,
    /// the inner step of both encode and decode). Caller guarantees `dst.len() >= src.len()`.
    fn mul_add(&self, coeff: u8, src: &[u8], dst: &mut [u8]);

    /// `dst[i] ^= src[i]` for every `i ∈ 0..src.len()` (field addition over a region — the
    /// `coeff == 1` fast path). Caller guarantees `dst.len() >= src.len()`.
    fn xor_add(&self, src: &[u8], dst: &mut [u8]);
}

/// Portable, 100%-safe scalar [`GfRegion`] driven by the compile-time [`EXP`]/[`LOG`] tables.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScalarGf;

impl GfRegion for ScalarGf {
    #[inline]
    fn mul_add(&self, coeff: u8, src: &[u8], dst: &mut [u8]) {
        debug_assert!(dst.len() >= src.len(), "mul_add dst shorter than src");
        // `coeff == 0` contributes nothing; skip the whole region.
        if coeff == 0 {
            return;
        }
        if coeff == 1 {
            self.xor_add(src, dst);
            return;
        }
        let log_coeff = LOG[coeff as usize] as usize;
        // `iter_mut().zip(src)` (not indexed `dst[i] ^= …`): `src.len() <= dst.len()`, so the
        // zip covers every src byte while eliding the per-iteration bounds check.
        for (d, &s) in dst.iter_mut().zip(src.iter()) {
            if s != 0 {
                *d ^= EXP[log_coeff + LOG[s as usize] as usize];
            }
        }
    }

    #[inline]
    fn xor_add(&self, src: &[u8], dst: &mut [u8]) {
        debug_assert!(dst.len() >= src.len(), "xor_add dst shorter than src");
        for (d, &s) in dst.iter_mut().zip(src.iter()) {
            *d ^= s;
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::gf256::{EXP, GfRegion, LOG, ScalarGf, inv, mul};

    /// Reference (un-optimised) multiply: carry-less polynomial product mod 0x11D.
    fn ref_mul(mut a: u8, mut b: u8) -> u8 {
        let mut product: u8 = 0;
        let mut i = 0;
        while i < 8 {
            if b & 1 != 0 {
                product ^= a;
            }
            let high = a & 0x80;
            a <<= 1;
            if high != 0 {
                a ^= 0x1D; // 0x11D truncated to a byte (the x^8 bit folds back in)
            }
            b >>= 1;
            i += 1;
        }
        product
    }

    #[test]
    fn tables_are_inverse_bijections() {
        // EXP cycles through all 255 nonzero elements; LOG inverts it.
        for i in 0u16..255 {
            let v = EXP[i as usize];
            assert_ne!(v, 0, "EXP has no zero in its cycle");
            assert_eq!(LOG[v as usize] as u16, i, "LOG inverts EXP at {i}");
        }
        // EXP is doubled: upper half mirrors the lower.
        for i in 0usize..255 {
            assert_eq!(EXP[i], EXP[i + 255]);
        }
        assert_eq!(EXP[0], 1, "2^0 == 1");
        assert_eq!(EXP[255], 1, "the cycle closes (2^255 == 1)");
    }

    #[test]
    fn mul_matches_reference_exhaustively() {
        for a in 0u16..=255 {
            for b in 0u16..=255 {
                assert_eq!(
                    mul(a as u8, b as u8),
                    ref_mul(a as u8, b as u8),
                    "mul disagrees with reference at ({a},{b})"
                );
            }
        }
    }

    #[test]
    fn mul_identity_and_absorbing() {
        for a in 0u16..=255 {
            let a = a as u8;
            assert_eq!(mul(a, 1), a, "1 is the multiplicative identity");
            assert_eq!(mul(1, a), a);
            assert_eq!(mul(a, 0), 0, "0 is absorbing");
            assert_eq!(mul(0, a), 0);
        }
    }

    #[test]
    fn mul_is_commutative() {
        for a in 0u16..=255 {
            for b in 0u16..=255 {
                assert_eq!(mul(a as u8, b as u8), mul(b as u8, a as u8));
            }
        }
    }

    #[test]
    fn mul_is_associative() {
        // Full 256^3 is 16M iterations — fine for a release-opt test, but step b/c to
        // keep it brisk while still touching a representative cross-section.
        for a in 0u16..=255 {
            for b in (0u16..=255).step_by(7) {
                for c in (0u16..=255).step_by(11) {
                    let lhs = mul(mul(a as u8, b as u8), c as u8);
                    let rhs = mul(a as u8, mul(b as u8, c as u8));
                    assert_eq!(lhs, rhs, "associativity at ({a},{b},{c})");
                }
            }
        }
    }

    #[test]
    fn mul_distributes_over_xor() {
        for a in 0u16..=255 {
            for b in (0u16..=255).step_by(5) {
                for c in (0u16..=255).step_by(5) {
                    let a = a as u8;
                    let b = b as u8;
                    let c = c as u8;
                    assert_eq!(mul(a, b ^ c), mul(a, b) ^ mul(a, c), "distributivity");
                }
            }
        }
    }

    #[test]
    fn inverse_recovers_identity() {
        for a in 1u16..=255 {
            let a = a as u8;
            assert_eq!(mul(a, inv(a)), 1, "a * inv(a) == 1 for a={a}");
            assert_eq!(mul(inv(a), a), 1);
        }
    }

    #[test]
    fn region_xor_add_matches_naive() {
        let gf = ScalarGf;
        let src = [0x01u8, 0xFF, 0x10, 0x80, 0x00, 0x7F];
        let mut dst = [0xAAu8, 0x55, 0x10, 0x01, 0xFE, 0x33];
        let mut reference = dst;
        gf.xor_add(&src, &mut dst);
        for (r, &s) in reference.iter_mut().zip(src.iter()) {
            *r ^= s;
        }
        assert_eq!(dst, reference);
    }

    #[test]
    fn region_mul_add_matches_naive() {
        let gf = ScalarGf;
        for coeff in 0u16..=255 {
            let coeff = coeff as u8;
            let src = [0x01u8, 0xFF, 0x10, 0x80, 0x00, 0x7F, 0x42];
            let mut dst = [0xAAu8, 0x55, 0x10, 0x01, 0xFE, 0x33, 0x99];
            let mut reference = dst;
            gf.mul_add(coeff, &src, &mut dst);
            for (r, &s) in reference.iter_mut().zip(src.iter()) {
                *r ^= mul(coeff, s);
            }
            assert_eq!(dst, reference, "mul_add region disagrees for coeff={coeff}");
        }
    }

    #[test]
    fn region_mul_add_handles_shorter_src() {
        // dst longer than src: trailing dst bytes untouched (the MDS-width zero-pad case).
        let gf = ScalarGf;
        let src = [0x12u8, 0x34];
        let mut dst = [0x01u8, 0x02, 0x03, 0x04];
        gf.mul_add(0x03, &src, &mut dst);
        assert_eq!(dst[0], 0x01 ^ mul(0x03, 0x12));
        assert_eq!(dst[1], 0x02 ^ mul(0x03, 0x34));
        assert_eq!(dst[2], 0x03, "byte past src len untouched");
        assert_eq!(dst[3], 0x04);
    }
}
