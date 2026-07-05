// GF(2^8) split-table region multiply — the C translation of `rust/slopdesk-ffi/src/gf_neon.rs`.
//
// Two ops:
//   mul_add: dst[i] ^= mul(coeff, src[i]) over `len` bytes, via the two precomputed 16-entry
//            nibble tables (table_lo[i]=mul(coeff,i), table_hi[i]=mul(coeff,i<<4)). 16 bytes/iter
//            on NEON via two `vqtbl1q_u8` lookups + a `veorq_u8`, exploiting distributivity:
//            mul(c,b) == mul(c, b & 0x0f) ^ mul(c, b >> 4) == table_lo[b&0x0f] ^ table_hi[b>>4].
//   xor_add: dst[i] ^= src[i] over `len` bytes (the coeff==1 region-add fast path).
//
// The NEON path (`__aarch64__`) processes full 16-byte chunks; the (len % 16) tail and the entire
// non-aarch64 build go through the scalar loop. NEON and scalar are byte-identical because the
// tables are filled by the SAME scalar gf256::mul on the Swift side. C unsigned arithmetic wraps
// by default, so no special wrapping handling is needed.

#include "include/slopdesk_simd.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// Scalar mul_add over [0, len): dst[i] ^= table_lo[src[i] & 0x0f] ^ table_hi[src[i] >> 4].
// This is exactly mul(coeff, src[i]) because table_lo indexes low-nibble products and table_hi
// indexes high-nibble products (distributivity of the field multiply over XOR). Doubles as the
// (len % 16) tail handler for the NEON path and the whole non-aarch64 build.
static void gf_mul_add_scalar(uint8_t *dst, const uint8_t *src, size_t len,
                              const uint8_t *table_lo, const uint8_t *table_hi) {
    for (size_t i = 0; i < len; i++) {
        dst[i] ^= (uint8_t)(table_lo[src[i] & 0x0f] ^ table_hi[src[i] >> 4]);
    }
}

// Scalar xor_add over [0, len): dst[i] ^= src[i]. Tail handler + non-aarch64 build.
static void gf_xor_add_scalar(uint8_t *dst, const uint8_t *src, size_t len) {
    for (size_t i = 0; i < len; i++) {
        dst[i] ^= src[i];
    }
}

void aisd_simd_gf_mul_add(uint8_t *dst, const uint8_t *src, size_t len,
                          const uint8_t *table_lo, const uint8_t *table_hi) {
#if defined(__aarch64__)
    // Load the two 16-entry nibble tables once into registers (they are per-coeff constants).
    const uint8x16_t tlo = vld1q_u8(table_lo);
    const uint8x16_t thi = vld1q_u8(table_hi);
    const uint8x16_t lo_mask = vdupq_n_u8(0x0f);

    size_t i = 0;
    // Full 16-byte chunks.
    for (; i + 16 <= len; i += 16) {
        const uint8x16_t v = vld1q_u8(src + i);
        const uint8x16_t low = vandq_u8(v, lo_mask);       // b & 0x0f
        const uint8x16_t high = vshrq_n_u8(v, 4);          // b >> 4
        const uint8x16_t prod_lo = vqtbl1q_u8(tlo, low);   // table_lo[b & 0x0f]
        const uint8x16_t prod_hi = vqtbl1q_u8(thi, high);  // table_hi[b >> 4]
        const uint8x16_t prod = veorq_u8(prod_lo, prod_hi);
        vst1q_u8(dst + i, veorq_u8(vld1q_u8(dst + i), prod));
    }
    // Tail (len % 16) — same arithmetic, byte at a time.
    gf_mul_add_scalar(dst + i, src + i, len - i, table_lo, table_hi);
#else
    gf_mul_add_scalar(dst, src, len, table_lo, table_hi);
#endif
}

void aisd_simd_gf_xor_add(uint8_t *dst, const uint8_t *src, size_t len) {
#if defined(__aarch64__)
    size_t i = 0;
    for (; i + 16 <= len; i += 16) {
        vst1q_u8(dst + i, veorq_u8(vld1q_u8(src + i), vld1q_u8(dst + i)));
    }
    gf_xor_add_scalar(dst + i, src + i, len - i);
#else
    gf_xor_add_scalar(dst, src, len);
#endif
}
