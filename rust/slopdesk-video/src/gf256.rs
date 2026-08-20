//! Arithmetic over the Galois field GF(2^8), the algebraic substrate for the Reed-Solomon erasure
//! code in [`crate::fec`].
//!
//! Elements are bytes; addition is XOR (its own inverse, carry-free) and multiplication is
//! polynomial multiplication modulo the primitive (irreducible) polynomial
//! `x^8 + x^4 + x^3 + x^2 + 1` = `0x11D`. `0x02` (the polynomial `x`) is a generator of the
//! multiplicative group, so the powers `2^0, 2^1, …, 2^254` enumerate every nonzero element exactly
//! once — the basis of the log/exp tables below.
//!
//! ## Tables
//!
//! Both tables are built by a `const fn` at compile time, so they cost no runtime initialisation,
//! no allocation, and no `unsafe` (a `OnceLock`/`LazyLock` would buy interior mutability we do not
//! need for a value the compiler can just fold).
//!
//! * [`EXP`] is `[u8; 512]`: `EXP[i] = 2^(i mod 255)` for the antilog, *doubled* to length 512 so
//!   that `EXP[LOG[a] + LOG[b]]` is always in range without a modular reduction — the standard
//!   branchless-multiply trick (`LOG[a] + LOG[b]` is at most `254 + 254 = 508 < 512`).
//! * [`LOG`] is `[u8; 256]`: `LOG[v]` is the discrete log of `v` base `2`. `LOG[0]` is meaningless
//!   (0 has no log) and is never indexed on a live path — [`mul`] short-circuits a zero operand
//!   before any table lookup.
//!
//! ## The region operations are free functions, not a trait
//!
//! The Swift original ([`GfRegion`] in the deleted `SlopDeskVideoProtocol.GF256`) is a protocol
//! with two conformances: a scalar reference and `NeonGf`, which calls a C target through
//! `UnsafeBufferPointer`. The trait exists ONLY to swap that kernel in. This crate forbids
//! `unsafe`, so there is exactly one implementation and no seam for a second — and a trait with one
//! implementor is an abstraction that has to be read past rather than one that carries weight. If a
//! measurement ever demands the nibble-table `tbl` kernel, it comes back as a trait then, with the
//! number that justified it.

use crate::bytes::truncating_u8;

/// The primitive polynomial `x^8 + x^4 + x^3 + x^2 + 1` (`0x11D`), reduced into a byte by XOR-ing
/// whenever a multiply-by-`x` overflows bit 7. This is the conventional choice (AES, most RS
/// libraries) so the field — and thus every coefficient — matches reference implementations
/// bit-for-bit.
const PRIMITIVE_POLY: u16 = 0x11D;

/// Antilog table, doubled to length 512 (`EXP[i] == EXP[i + 255]` for `i < 255`) so a product's
/// exponent `LOG[a] + LOG[b] ∈ 0..=508` indexes directly without reduction.
///
/// NEVER reduce the index with `% 255`: the doubling IS the reduction, and doing both is how a
/// rewrite of this table silently breaks `EXP[255] == 1`.
const EXP: [u8; 512] = build_exp();

/// Discrete-log table base `2`: `LOG[EXP[i]] == i` for `i ∈ 0..255`. `LOG[0]` is unused.
const LOG: [u8; 256] = build_log(&EXP);

/// Builds the antilog table at compile time by repeatedly multiplying by the generator `0x02`
/// (polynomial `x`) and reducing modulo [`PRIMITIVE_POLY`]. The first 255 entries cycle through
/// every nonzero element; the upper half mirrors the lower so out-of-range reduction is unnecessary
/// in [`mul`].
#[expect(
    clippy::indexing_slicing,
    reason = "every index is a loop counter the `while` bound proves is inside the fixed-size array, and \
              `const fn` cannot call the checked accessors"
)]
#[expect(
    clippy::cast_possible_truncation,
    reason = "the reduction below guarantees `value` is back under 0x100 before every store"
)]
const fn build_exp() -> [u8; 512] {
    let mut table = [0_u8; 512];
    let mut value: u16 = 1;
    let mut i = 0_usize;
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
    let mut j = 255_usize;
    while j < 512 {
        table[j] = table[j - 255];
        j += 1;
    }
    table
}

/// Inverts [`build_exp`] into the log table: `LOG[EXP[i]] = i` for `i ∈ 0..255`. Index 0 is left as
/// 0 (and never read on a live path).
#[expect(
    clippy::indexing_slicing,
    reason = "the read index is bounded by the loop and the write index is a `u8` widened to `usize`, so \
              both are inside their arrays by construction"
)]
#[expect(
    clippy::cast_possible_truncation,
    reason = "`i < 255` is the loop bound, so the cast is exact"
)]
const fn build_log(exp: &[u8; 512]) -> [u8; 256] {
    let mut table = [0_u8; 256];
    let mut i = 0_usize;
    while i < 255 {
        table[exp[i] as usize] = i as u8;
        i += 1;
    }
    table
}

/// Field multiplication: `0` if either operand is `0` (the field's absorbing element), otherwise
/// `EXP[LOG[a] + LOG[b]]`. Branchless after the zero short-circuit thanks to the doubled [`EXP`]
/// table.
#[inline]
#[must_use]
#[expect(
    clippy::indexing_slicing,
    reason = "a `u8` operand indexes LOG in range; the two logs are each at most 254 after the zero \
              short-circuit, so their sum is at most 508 and EXP has 512 entries"
)]
pub const fn mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        return 0;
    }
    EXP[LOG[a as usize] as usize + LOG[b as usize] as usize]
}

/// Multiplicative inverse: the unique `x` with `mul(a, x) == 1`, computed as `EXP[255 - LOG[a]]`
/// (since `a * a^254 == a^255 == 1` in GF(2^8)).
///
/// `inv(0)` is mathematically undefined; it returns `0` and trips a `debug_assert` — callers
/// (Gauss-Jordan pivoting, the Cauchy block) never invert a zero.
#[inline]
#[must_use]
#[expect(
    clippy::indexing_slicing,
    reason = "`a != 0` bounds LOG[a] at 254, so `255 - LOG[a]` lands in 1..=255, inside EXP"
)]
pub const fn inv(a: u8) -> u8 {
    debug_assert!(a != 0, "GF(2^8) inverse of zero is undefined");
    if a == 0 {
        return 0;
    }
    EXP[255 - LOG[a as usize] as usize]
}

/// A scaled XOR-accumulate — the inner step of both encode and decode.
///
/// `dst[i] ^= mul(coeff, src[i])` for every `i ∈ 0..src.len()`. Bytes of `dst` past `src.len()` are
/// left alone (the zero-pad case a short shard produces).
///
/// Written as `iter_mut().zip(src)` rather than an indexed loop: the zip covers every `src` byte
/// with no per-iteration bounds check, which is what lets LLVM autovectorise the accumulate.
#[inline]
pub fn mul_add(coeff: u8, src: &[u8], dst: &mut [u8]) {
    // `coeff == 0` contributes nothing; skip the whole region.
    if coeff == 0 {
        return;
    }
    if coeff == 1 {
        xor_add(src, dst);
        return;
    }
    // Two strategies, split by region length. The per-byte form costs two table lookups and an add;
    // the table form costs 255 of those up front and then ONE lookup per byte. The crossover is
    // where building the table stops dominating — measured at a few dozen bytes, and set well above
    // it so the short regions the matrix inverse folds (a `2k`-wide augmented row) never pay for a
    // table they would not amortise.
    if src.len() >= TABLE_CROSSOVER_BYTES {
        MulTable::new(coeff).add_scaled(src, dst);
        return;
    }
    let log_coeff = usize::from(log_of(coeff));
    for (d, &s) in dst.iter_mut().zip(src.iter()) {
        if s != 0 {
            *d ^= exp_at(log_coeff + usize::from(log_of(s)));
        }
    }
}

/// Region length at which building a per-coefficient multiplication table pays for itself.
const TABLE_CROSSOVER_BYTES: usize = 96;

/// One coefficient's multiplication, as the two 16-entry NIBBLE tables a vector shuffle can hold.
///
/// `mul(c, b)` is a 256-entry lookup, and a 256-entry lookup is a gather — no vector unit does one.
/// But the field multiply distributes over XOR and a byte is two nibbles, so
/// `mul(c, b) == mul(c, b & 0x0f) ^ mul(c, b >> 4)`: two lookups in tables of SIXTEEN, which is one
/// NEON register each and one `vqtbl1q_u8` apiece.
///
/// The tables are built here, where the field is; the shuffle is [`slopdesk_gfsimd`], which has
/// never heard of a field. Constructing a pair costs 30 multiplies against the 255 the flat table
/// cost, so the crossover it has to earn back is far lower than the flat table's ever was.
#[derive(Debug, Clone, Copy)]
pub struct MulTable {
    lo: [u8; 16],
    hi: [u8; 16],
}

impl MulTable {
    /// Builds the nibble pair for `coeff`.
    ///
    /// `coeff == 0` answers two ALL-ZERO tables, which is what `mul(0, v)` is. It falls out of
    /// [`mul`]'s own zero case rather than needing to be spelled out, unlike the flat table this
    /// replaced, where the general form would have filled 256 entries with nonsense because
    /// `LOG[0]` is meaningless.
    #[must_use]
    pub fn new(coeff: u8) -> Self {
        let mut lo = [0_u8; 16];
        let mut hi = [0_u8; 16];
        for (nibble, cell) in lo.iter_mut().enumerate() {
            *cell = mul(coeff, truncating_u8(nibble));
        }
        for (nibble, cell) in hi.iter_mut().enumerate() {
            *cell = mul(coeff, truncating_u8(nibble << 4));
        }
        Self { lo, hi }
    }

    /// `dst[i] ^= mul(coeff, src[i])` for every `i ∈ 0..src.len()`.
    ///
    /// Sixteen bytes per instruction pair on aarch64, the remainder byte at a time — both inside
    /// [`slopdesk_gfsimd`], which is the one crate here allowed to write the loads and stores that
    /// take.
    #[inline]
    pub fn add_scaled(&self, src: &[u8], dst: &mut [u8]) {
        slopdesk_gfsimd::mul_add(&self.lo, &self.hi, src, dst);
    }
}

/// `dst[i] ^= src[i]` for every `i ∈ 0..src.len()` — field addition over a region, and the
/// `coeff == 1` fast path of [`mul_add`].
#[inline]
pub fn xor_add(src: &[u8], dst: &mut [u8]) {
    slopdesk_gfsimd::xor_add(src, dst);
}

/// [`EXP`] at an index the caller has already bounded by the table's construction (a sum of two
/// logs, each at most 254). Falls back to `0` rather than indexing blind, so a future edit that
/// breaks the bound degrades to a wrong byte instead of a panic on the video path.
#[inline]
fn exp_at(index: usize) -> u8 {
    EXP.get(index).copied().unwrap_or(0)
}

/// [`LOG`] indexed by a `u8` — always in range, but spelled as one function so the exemption that
/// proves it lives in a single place rather than at every call site.
#[inline]
#[expect(
    clippy::indexing_slicing,
    reason = "a `u8` index into a 256-entry table cannot be out of bounds"
)]
const fn log_of(value: u8) -> u8 {
    LOG[value as usize]
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{EXP, LOG, MulTable, inv, mul, mul_add, truncating_u8, xor_add};

    /// The shuffle kernel and the FIELD must agree on EVERY coefficient, at every length that
    /// straddles the 16-byte chunk. This is the seam `slopdesk-gfsimd` cannot test on its own: that
    /// crate proves its vector path equals its scalar path over arbitrary tables, and this proves
    /// the tables built here are the ones GF(2^8) actually calls for. A nibble pair that split the
    /// byte the wrong way round would satisfy the other test perfectly.
    #[test]
    fn the_simd_kernel_agrees_with_the_table_on_every_coefficient() {
        let src: Vec<u8> = (0..256_usize).map(truncating_u8).collect();
        for coeff in 0..=255_u8 {
            let table = MulTable::new(coeff);
            for len in [0, 1, 7, 15, 16, 17, 31, 32, 33, 96, 200, 256] {
                let region = src.get(..len).unwrap_or(&src);
                let mut fast = vec![0xA5_u8; region.len()];
                let mut reference = fast.clone();
                table.add_scaled(region, &mut fast);
                for (d, &v) in reference.iter_mut().zip(region.iter()) {
                    *d ^= mul(coeff, v);
                }
                assert_eq!(fast, reference, "coeff {coeff}, len {len}");
            }
        }
    }

    /// A region SHORTER than the destination stops where the source does — the encoder relies on
    /// it, since a short final shard is folded into a wider accumulator.
    #[test]
    fn a_short_source_leaves_the_rest_of_the_destination_alone() {
        let table = MulTable::new(0x1F);
        let src = [0x11_u8; 20];
        let mut dst = [0x22_u8; 64];
        table.add_scaled(&src, &mut dst);
        assert!(dst.get(20..).is_some_and(|tail| tail.iter().all(|&b| b == 0x22)));
    }

    /// Reference (un-optimised) multiply: carry-less polynomial product mod 0x11D. Independent of
    /// the tables, so it catches a table that is self-consistently wrong.
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
        for i in 0_u16..255 {
            let v = EXP[i as usize];
            assert_ne!(v, 0, "EXP has no zero in its cycle");
            assert_eq!(u16::from(LOG[v as usize]), i, "LOG inverts EXP at {i}");
        }
        for i in 0_usize..255 {
            assert_eq!(EXP[i], EXP[i + 255], "EXP is doubled, so no index needs `% 255`");
        }
        assert_eq!(EXP[0], 1, "2^0 == 1");
        assert_eq!(EXP[255], 1, "the cycle closes (2^255 == 1)");
    }

    #[test]
    fn mul_matches_reference_exhaustively() {
        for a in 0..=u8::MAX {
            for b in 0..=u8::MAX {
                assert_eq!(
                    mul(a, b),
                    ref_mul(a, b),
                    "mul disagrees with reference at ({a},{b})"
                );
            }
        }
    }

    #[test]
    fn mul_identity_and_absorbing() {
        for a in 0..=u8::MAX {
            assert_eq!(mul(a, 1), a, "1 is the multiplicative identity");
            assert_eq!(mul(1, a), a);
            assert_eq!(mul(a, 0), 0, "0 is absorbing");
            assert_eq!(mul(0, a), 0);
        }
    }

    #[test]
    fn mul_is_commutative() {
        for a in 0..=u8::MAX {
            for b in 0..=u8::MAX {
                assert_eq!(mul(a, b), mul(b, a));
            }
        }
    }

    #[test]
    fn mul_is_associative() {
        // Full 256^3 is 16M iterations; stepping b and c keeps it brisk while still touching a
        // representative cross-section of the field.
        for a in 0..=u8::MAX {
            for b in (0..=u8::MAX).step_by(7) {
                for c in (0..=u8::MAX).step_by(11) {
                    assert_eq!(
                        mul(mul(a, b), c),
                        mul(a, mul(b, c)),
                        "associativity at ({a},{b},{c})"
                    );
                }
            }
        }
    }

    #[test]
    fn mul_distributes_over_xor() {
        for a in 0..=u8::MAX {
            for b in (0..=u8::MAX).step_by(5) {
                for c in (0..=u8::MAX).step_by(5) {
                    assert_eq!(mul(a, b ^ c), mul(a, b) ^ mul(a, c), "distributivity");
                }
            }
        }
    }

    #[test]
    fn inverse_recovers_identity() {
        for a in 1..=u8::MAX {
            assert_eq!(mul(a, inv(a)), 1, "a * inv(a) == 1 for a={a}");
            assert_eq!(mul(inv(a), a), 1);
        }
    }

    #[test]
    fn region_xor_add_matches_naive() {
        let src = [0x01_u8, 0xFF, 0x10, 0x80, 0x00, 0x7F];
        let mut dst = [0xAA_u8, 0x55, 0x10, 0x01, 0xFE, 0x33];
        let mut reference = dst;
        xor_add(&src, &mut dst);
        for (r, &s) in reference.iter_mut().zip(src.iter()) {
            *r ^= s;
        }
        assert_eq!(dst, reference);
    }

    #[test]
    fn region_mul_add_matches_naive() {
        for coeff in 0..=u8::MAX {
            let src = [0x01_u8, 0xFF, 0x10, 0x80, 0x00, 0x7F, 0x42];
            let mut dst = [0xAA_u8, 0x55, 0x10, 0x01, 0xFE, 0x33, 0x99];
            let mut reference = dst;
            mul_add(coeff, &src, &mut dst);
            for (r, &s) in reference.iter_mut().zip(src.iter()) {
                *r ^= mul(coeff, s);
            }
            assert_eq!(dst, reference, "mul_add region disagrees for coeff={coeff}");
        }
    }

    #[test]
    fn region_mul_add_leaves_the_zero_pad_alone() {
        // dst longer than src: trailing dst bytes untouched (the MDS-width zero-pad case).
        let src = [0x12_u8, 0x34];
        let mut dst = [0x01_u8, 0x02, 0x03, 0x04];
        mul_add(0x03, &src, &mut dst);
        assert_eq!(dst[0], 0x01 ^ mul(0x03, 0x12));
        assert_eq!(dst[1], 0x02 ^ mul(0x03, 0x34));
        assert_eq!(dst[2], 0x03, "byte past src len untouched");
        assert_eq!(dst[3], 0x04);
    }
}
