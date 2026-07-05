// Tiny native SIMD-kernel C surface for the all-Swift slopdesk path.
//
// These functions are the ONLY genuinely-native-SIMD code in the codebase: a GF(2^8) split-table
// region multiply (+ its coeff==1 region-add fast path). They replace the old Rust FFI NEON
// kernel (`gf_neon.rs`) with C that SwiftPM compiles from source every build — no cbindgen, no
// marshalling, no prebuilt staticlib, no build ordering. (The xxHash64 frame-hash fold once lived
// here too, but the scalar fold MEASURED faster than NEON — aarch64 has no 64-bit lane multiply —
// so frame hashing is pure-Swift scalar now and that kernel was removed.)
//
// Each implementation has an `#if defined(__aarch64__)` NEON path and a scalar fallback (also
// the tail handler, also the whole x86_64 CI/sim build). The NEON and scalar paths produce
// byte-identical output — proven by the Swift differential test.
//
// Pointer + length contract: the CALLER (Swift) owns every buffer. Nothing here heap-allocates
// or takes ownership; the pointers are borrowed for the duration of the call only.

#ifndef SLOPDESK_SIMD_H
#define SLOPDESK_SIMD_H

#include <stddef.h>
#include <stdint.h>

// GF(2^8) region: dst[i] ^= mul(coeff, src[i]) for len bytes, via the two precomputed
// 16-entry nibble tables table_lo[i]=mul(coeff,i), table_hi[i]=mul(coeff,i<<4). Caller (Swift)
// builds the tables with its scalar gf256::mul so the result is byte-identical to scalar.
void aisd_simd_gf_mul_add(uint8_t *dst, const uint8_t *src, size_t len,
                          const uint8_t *table_lo, const uint8_t *table_hi);

// dst[i] ^= src[i] for len bytes (the coeff==1 region-add fast path).
void aisd_simd_gf_xor_add(uint8_t *dst, const uint8_t *src, size_t len);

#endif // SLOPDESK_SIMD_H
