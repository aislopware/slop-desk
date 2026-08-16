//! Byte-region kernels for an 8-bit field, and nothing else.
//!
//! Two operations, each in a SIMD form and a scalar form that are byte-identical by construction:
//!
//! - [`mul_add`] — `dst[i] ^= table_lo[src[i] & 0x0f] ^ table_hi[src[i] >> 4]`
//! - [`xor_add`] — `dst[i] ^= src[i]`
//!
//! ## Why a table pair and not a coefficient
//! Because that is what keeps this crate ignorant. Multiplying a byte by a constant `c` in
//! GF(2^8) is a 256-entry lookup, and a 256-entry lookup is a gather no vector unit will do. But
//! the field multiply distributes over XOR and a byte is two nibbles, so
//! `mul(c, b) == mul(c, b & 0x0f) ^ mul(c, b >> 4)` — two lookups in tables of SIXTEEN, which is
//! exactly one NEON register and exactly what `vqtbl1q_u8` shuffles in one instruction.
//!
//! The caller builds those two tables, because building them needs the field and this crate does
//! not have one. What arrives here is a pair of 16-byte arrays and two spans; the entire safety
//! obligation is that a 16-byte load stays inside a 16-byte chunk, which is a sentence with no
//! slopdesk, no video and no Galois field in it.
//!
//! ## Lengths
//! Every entry point works over `min(src.len(), dst.len())` bytes and leaves the rest of `dst`
//! untouched. Nothing here allocates, returns, or fails.

/// Low nibble of a byte.
const NIBBLE: u8 = 0x0F;
/// Bytes in one NEON vector register.
const LANES: usize = 16;

/// `dst[i] ^= table_lo[src[i] & 0x0f] ^ table_hi[src[i] >> 4]`, one byte at a time.
///
/// The oracle. The vector path is only ever allowed to agree with this, and `tests/differential.rs`
/// is what holds it to that; keep it public for the same reason a reference implementation is kept
/// after it stops being the one that runs.
pub fn mul_add_scalar(table_lo: &[u8; LANES], table_hi: &[u8; LANES], src: &[u8], dst: &mut [u8]) {
    for (d, &s) in dst.iter_mut().zip(src.iter()) {
        let low = usize::from(s & NIBBLE);
        let high = usize::from(s >> 4);
        // Both indices are four bits wide and the tables are sixteen long, so neither `get` can
        // miss; `unwrap_or(0)` is there because `indexing_slicing` is denied, not because it fires.
        *d ^= table_lo.get(low).copied().unwrap_or(0) ^ table_hi.get(high).copied().unwrap_or(0);
    }
}

/// `dst[i] ^= src[i]`, one byte at a time. The oracle for [`xor_add`].
pub fn xor_add_scalar(src: &[u8], dst: &mut [u8]) {
    for (d, &s) in dst.iter_mut().zip(src.iter()) {
        *d ^= s;
    }
}

/// `dst[i] ^= table_lo[src[i] & 0x0f] ^ table_hi[src[i] >> 4]` over the whole overlap.
///
/// Sixteen bytes per iteration on aarch64, the remainder through [`mul_add_scalar`], and the whole
/// thing through [`mul_add_scalar`] everywhere else.
pub fn mul_add(table_lo: &[u8; LANES], table_hi: &[u8; LANES], src: &[u8], dst: &mut [u8]) {
    #[cfg(target_arch = "aarch64")]
    {
        let done = mul_add_neon(table_lo, table_hi, src, dst);
        mul_add_scalar(
            table_lo,
            table_hi,
            src.get(done..).unwrap_or_default(),
            dst.get_mut(done..).unwrap_or_default(),
        );
    }
    #[cfg(not(target_arch = "aarch64"))]
    mul_add_scalar(table_lo, table_hi, src, dst);
}

/// `dst[i] ^= src[i]` over the whole overlap. Sixteen bytes per iteration on aarch64.
pub fn xor_add(src: &[u8], dst: &mut [u8]) {
    #[cfg(target_arch = "aarch64")]
    {
        let done = xor_add_neon(src, dst);
        xor_add_scalar(
            src.get(done..).unwrap_or_default(),
            dst.get_mut(done..).unwrap_or_default(),
        );
    }
    #[cfg(not(target_arch = "aarch64"))]
    xor_add_scalar(src, dst);
}

/// The vector half of [`mul_add`]. Returns how many bytes it handled — always a multiple of 16.
///
/// `vqtbl1q_u8` is a 16-byte permute: given a table register and a vector of indices, it picks
/// `table[index]` per lane, and yields zero for an index above 15 — which cannot arise here, since
/// both index vectors are built by masking to four bits.
#[cfg(target_arch = "aarch64")]
#[expect(
    unsafe_code,
    reason = "`vld1q_u8`/`vst1q_u8` take raw pointers; the 16-byte window each one needs is what \
              `chunks_exact` hands out, and the tables are 16 bytes by type"
)]
fn mul_add_neon(table_lo: &[u8; LANES], table_hi: &[u8; LANES], src: &[u8], dst: &mut [u8]) -> usize {
    use core::arch::aarch64::{vandq_u8, vdupq_n_u8, veorq_u8, vld1q_u8, vqtbl1q_u8, vshrq_n_u8, vst1q_u8};

    // SAFETY: `&[u8; 16]` is sixteen readable bytes by its own type — the load cannot reach past
    // the array it was handed. `vdupq_n_u8` touches no memory at all and is in the block only
    // because every NEON intrinsic carries `#[target_feature(enable = "neon")]`, whose obligation
    // is that the CPU has NEON — which aarch64 guarantees, it being part of the base ISA.
    let (tlo, thi, mask) = unsafe {
        (
            vld1q_u8(table_lo.as_ptr()),
            vld1q_u8(table_hi.as_ptr()),
            vdupq_n_u8(NIBBLE),
        )
    };

    let mut done = 0_usize;
    for (d, s) in dst.chunks_exact_mut(LANES).zip(src.chunks_exact(LANES)) {
        // SAFETY: `chunks_exact`/`chunks_exact_mut` yield slices of EXACTLY 16 bytes and never a
        // short final one, so each 16-byte load and the 16-byte store are wholly inside the chunk
        // they address. `d` and `s` come from a `&mut` and a `&`, which cannot alias.
        unsafe {
            let v = vld1q_u8(s.as_ptr());
            let low = vandq_u8(v, mask);
            let high = vshrq_n_u8::<4>(v);
            let product = veorq_u8(vqtbl1q_u8(tlo, low), vqtbl1q_u8(thi, high));
            vst1q_u8(d.as_mut_ptr(), veorq_u8(vld1q_u8(d.as_ptr()), product));
        }
        done += LANES;
    }
    done
}

/// The vector half of [`xor_add`]. Returns how many bytes it handled — always a multiple of 16.
#[cfg(target_arch = "aarch64")]
#[expect(
    unsafe_code,
    reason = "`vld1q_u8`/`vst1q_u8` take raw pointers; the 16-byte window each one needs is what \
              `chunks_exact` hands out"
)]
fn xor_add_neon(src: &[u8], dst: &mut [u8]) -> usize {
    use core::arch::aarch64::{veorq_u8, vld1q_u8, vst1q_u8};

    let mut done = 0_usize;
    for (d, s) in dst.chunks_exact_mut(LANES).zip(src.chunks_exact(LANES)) {
        // SAFETY: as in `mul_add_neon` — exactly 16 bytes per chunk, and the two do not alias.
        unsafe {
            vst1q_u8(
                d.as_mut_ptr(),
                veorq_u8(vld1q_u8(s.as_ptr()), vld1q_u8(d.as_ptr())),
            );
        }
        done += LANES;
    }
    done
}
