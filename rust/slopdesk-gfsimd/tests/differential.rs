//! The vector path against the scalar one, byte for byte, plus the memory testing that pays for
//! the `unsafe`.
//!
//! ## Why the tables here are arbitrary rather than a real GF(2^8)
//! Because the crate is arbitrary. It gathers two nibble-indexed tables and XORs; it has never
//! heard of a field, and a test that fed it one would be checking `slopdesk-video`'s arithmetic
//! through a hole in the wrong crate. So the tables come out of a fixed LCG, which covers table
//! pairs a real field never produces — a lo/hi pair sharing an entry, a table with duplicates, an
//! all-zero one. Agreement with the ACTUAL field is `slopdesk-video`'s
//! `the_simd_kernel_agrees_with_the_table_on_every_coefficient`, where the field lives.
//!
//! ## What is being memory-tested, and how
//! Every case is run at four different starting offsets into an over-long buffer, so the loads are
//! unaligned as often as not, and every destination is written inside a longer arena whose bytes
//! either side are checked afterwards. Under `cargo test` those catch a wrong LENGTH; under
//! `cargo +nightly miri test`, which `make miri` runs, they also catch a pointer that left its
//! provenance — the failure mode `chunks_exact` is being trusted to prevent.
#![expect(
    clippy::indexing_slicing,
    reason = "an out-of-range index in a test IS the report"
)]

use slopdesk_gfsimd::{mul_add, mul_add_scalar, xor_add, xor_add_scalar};

/// How many table pairs the sweep runs. Miri interprets every instruction, so the full sweep takes
/// half an hour there against a tenth of a second natively — and Miri is not what the 256 pairs are
/// for. What it checks is spatial: a load that leaves its allocation, a pointer that lost its
/// provenance. Four pairs across every length and offset exercise every one of those paths, and the
/// remaining 252 only re-prove arithmetic `cargo test` already proved.
#[cfg(miri)]
const SEEDS: u64 = 4;
/// The full sweep, natively.
#[cfg(not(miri))]
const SEEDS: u64 = 256;

/// Lengths that straddle the 16-byte chunk boundary from both sides, plus a real shard.
const LENGTHS: [usize; 14] = [0, 1, 7, 15, 16, 17, 23, 31, 32, 33, 63, 64, 255, 1204];
/// Offsets into the arena, so the kernel sees unaligned starts as well as aligned ones.
const OFFSETS: [usize; 4] = [0, 1, 3, 8];
/// Bytes of untouchable padding on either side of every destination.
const GUARD: usize = 32;
/// The padding byte — no relation to anything the kernel could legitimately write there.
const CANARY: u8 = 0xC7;

/// A cheap deterministic stream. Not cryptography, not the field — just bytes that differ.
fn lcg(seed: u64) -> impl FnMut() -> u8 {
    let mut state = seed | 1;
    move || {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        // Truncation is the point: the low byte of a stirred word is the byte we want.
        #[expect(clippy::cast_possible_truncation, reason = "taking a byte out of a word")]
        {
            (state >> 33) as u8
        }
    }
}

fn tables(seed: u64) -> ([u8; 16], [u8; 16]) {
    let mut next = lcg(seed);
    let mut lo = [0_u8; 16];
    let mut hi = [0_u8; 16];
    for slot in lo.iter_mut().chain(hi.iter_mut()) {
        *slot = next();
    }
    (lo, hi)
}

fn source(len: usize, seed: u64) -> Vec<u8> {
    let mut next = lcg(seed);
    (0..len).map(|_| next()).collect()
}

/// An arena of `GUARD + len + GUARD` canary bytes with a seeded window in the middle.
fn arena(len: usize, seed: u64) -> Vec<u8> {
    let mut buf = vec![CANARY; GUARD + len + GUARD];
    let mut next = lcg(seed);
    for slot in &mut buf[GUARD..GUARD + len] {
        *slot = next();
    }
    buf
}

fn guards_intact(buf: &[u8], len: usize, what: &str) {
    assert!(
        buf[..GUARD].iter().all(|&b| b == CANARY),
        "{what}: wrote before the destination"
    );
    assert!(
        buf[GUARD + len..].iter().all(|&b| b == CANARY),
        "{what}: wrote past the destination"
    );
}

/// The whole point: for every table pair, every length across the chunk boundary and every
/// alignment, the vector path and the scalar path produce the same bytes and touch the same ones.
#[test]
fn the_vector_path_agrees_with_the_scalar_one_on_every_table_and_length() {
    for seed in 0..SEEDS {
        let (lo, hi) = tables(seed);
        for len in LENGTHS {
            for offset in OFFSETS {
                let src = source(offset + len, seed ^ 0xABCD);
                let src = &src[offset..];

                let mut fast = arena(len, seed ^ 0x1234);
                let mut slow = fast.clone();
                mul_add(&lo, &hi, src, &mut fast[GUARD..GUARD + len]);
                mul_add_scalar(&lo, &hi, src, &mut slow[GUARD..GUARD + len]);

                assert_eq!(fast, slow, "seed {seed}, len {len}, offset {offset}");
                guards_intact(&fast, len, "mul_add");
            }
        }
    }
}

/// The same for the coefficient-one fast path.
#[test]
fn xor_add_agrees_with_the_scalar_one_across_the_chunk_boundary() {
    for seed in 0..SEEDS.min(64) {
        for len in LENGTHS {
            for offset in OFFSETS {
                let src = source(offset + len, seed ^ 0x5EED);
                let src = &src[offset..];

                let mut fast = arena(len, seed);
                let mut slow = fast.clone();
                xor_add(src, &mut fast[GUARD..GUARD + len]);
                xor_add_scalar(src, &mut slow[GUARD..GUARD + len]);

                assert_eq!(fast, slow, "seed {seed}, len {len}, offset {offset}");
                guards_intact(&fast, len, "xor_add");
            }
        }
    }
}

/// A source shorter than the destination stops where it runs out — it does not read on, and it
/// does not zero the rest. The FEC leans on this: a group's fragments differ in length.
#[test]
fn a_short_source_leaves_the_rest_of_the_destination_alone() {
    let (lo, hi) = tables(9);
    let src = source(20, 7);
    let mut dst = arena(100, 11);
    let before = dst.clone();

    mul_add(&lo, &hi, &src, &mut dst[GUARD..GUARD + 100]);

    assert_eq!(
        &dst[GUARD + 20..],
        &before[GUARD + 20..],
        "bytes past the source's end must be untouched"
    );
    guards_intact(&dst, 100, "short source");
}

/// And a destination shorter than the source is not overrun — the same bound from the other side.
#[test]
fn a_short_destination_is_not_overrun() {
    let (lo, hi) = tables(3);
    let src = source(1204, 5);
    for len in [0_usize, 1, 15, 16, 17, 33] {
        let mut dst = arena(len, 13);
        let mut slow = dst.clone();
        mul_add(&lo, &hi, &src, &mut dst[GUARD..GUARD + len]);
        mul_add_scalar(&lo, &hi, &src, &mut slow[GUARD..GUARD + len]);
        assert_eq!(dst, slow, "len {len}");
        guards_intact(&dst, len, "short destination");
    }
}

/// An all-zero table pair annihilates nothing — `dst ^= 0` leaves `dst` exactly as it was. Worth
/// pinning because the vector path reaches the same answer by a completely different route, and a
/// shuffle whose index vector were wrong would still look plausible on random tables.
#[test]
fn a_zero_table_pair_leaves_the_destination_unchanged() {
    let zero = [0_u8; 16];
    let src = source(300, 21);
    let mut dst = arena(300, 22);
    let before = dst.clone();
    mul_add(&zero, &zero, &src, &mut dst[GUARD..GUARD + 300]);
    assert_eq!(dst, before);
}
