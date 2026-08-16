//! The NV12 frame hash: one strong 64-bit value per captured frame, and one per luma row.
//!
//! The fold is xxHash64-shaped (see [`PRIME64_E`] — it is not xxHash64 itself) over the VISIBLE
//! bytes of each `stride`-spaced row, so two captures of the
//! same picture hash equal no matter what row padding the capture stack chose. The host uses the
//! whole-frame value to skip re-encoding an unchanged frame, and the per-row values to measure how
//! much of the picture moved ([`crate::scroll_shift`]) or changed ([`crate::adaptive_qp`]).
//!
//! ## Why this port is the point of the exercise
//!
//! The Swift original walks the planes through `UnsafeBufferPointer` and pointer arithmetic, on
//! bytes an `IOSurface` handed it: a wrong stride is a read past the mapping. Here a plane is a
//! `&[u8]` and every row is a `get(start..end)` that returns `None` instead of reading. The
//! `SENTINEL`/short-plane guards below are the same guards the Swift has — they are just no longer
//! the only thing between a hostile stride and a fault.
//!
//! ## Bit-exact traps
//!
//! * Every add/mul is `wrapping_*` — xxHash64 is defined on wrapping arithmetic, and a plain `+`
//!   would panic in debug on the first real frame.
//! * [`le_u64`] / [`le_u32`] ZERO-FILL past the end of the tail rather than reading or panicking.
//! * The 32-byte carry buffer must land the block boundary identically however a plane is sliced,
//!   so the contiguous fast path and the per-row path agree to the bit.
//!
//! The Swift carries a second, allocation-free entry (`hashRow`) beside the streaming hasher,
//! because its 32-byte carry buffer is a heap `[UInt8]` and a 1080-row plane would pay for 1080 of
//! them. [`StreamHasher`]'s carry is a `[u8; 32]` field, so there is nothing to avoid and nothing
//! to keep in step: [`hash_run`] IS the streaming hasher over one slice.

/// The first xxHash64 lane prime.
const PRIME64_A: u64 = 0x9E37_79B1_85EB_CA87;
/// The second xxHash64 lane prime.
const PRIME64_B: u64 = 0xC2B2_AE3D_27D4_EB4F;
/// The third xxHash64 lane prime.
const PRIME64_C: u64 = 0x1656_67B1_9E37_79F9;
/// The fourth xxHash64 lane prime.
const PRIME64_D: u64 = 0x85EB_CA77_C2B2_AE63;
/// The fifth lane prime — the short-input hash base.
///
/// NOT xxHash64's published `PRIME64_5` (`0x27D4_EB2F_1656_67C5`). This constant has been the
/// repo's since the original Rust reference, so the fold is an xxHash64-SHAPED private hash rather
/// than xxHash64: it will not agree with `xxh64sum`, and its outputs must not be published as if it
/// did. That costs nothing here — the value is only ever compared against another value from this
/// same code, on both ends of a wire that ships together — and changing it now would invalidate
/// every pinned hash below for no gain.
const PRIME64_E: u64 = 0x2752_5BA1_84B2_3A5D;

/// The fixed seed for the NV12 frame hash (the ASCII bytes `AISLOPDE`).
///
/// A constant rather than an env knob, so every consumer agrees on the exact value for a given
/// frame image and a row hash can be compared across processes.
pub const FRAME_HASH_SEED: u64 = 0x4149_534C_4F50_4445;

/// What a degenerate or guarded-out call returns instead of a hash.
///
/// `u64::MAX`, deliberately not `0`: a genuine all-zero plane hashes to a real avalanche value, so
/// "no measurement" stays distinguishable from "hashed a black frame".
pub const SENTINEL: u64 = u64::MAX;

/// The largest plane dimension [`borrow_plane`] will admit — above any real display, so an absurd
/// width or height is a rejected measurement rather than a multi-gigabyte row-hash array.
pub const MAX_PLANE_DIMENSION: usize = 16384;

/// One xxHash64 round: `acc = rotl(acc + lane * P2, 31) * P1`.
const fn xxh_round(acc: u64, lane: u64) -> u64 {
    acc.wrapping_add(lane.wrapping_mul(PRIME64_B))
        .rotate_left(31)
        .wrapping_mul(PRIME64_A)
}

/// Merges one finished lane accumulator into the running hash (xxHash64's `mergeRound`).
const fn merge_round(hash: u64, acc: u64) -> u64 {
    (hash ^ xxh_round(0, acc))
        .wrapping_mul(PRIME64_A)
        .wrapping_add(PRIME64_D)
}

/// Combines the four lane accumulators into one value (xxHash64's long-input fold):
/// `rotl(a1,1) + rotl(a2,7) + rotl(a3,12) + rotl(a4,18)`, then four merges.
const fn merge_lanes(lanes: [u64; 4]) -> u64 {
    let [a1, a2, a3, a4] = lanes;
    let folded = a1
        .rotate_left(1)
        .wrapping_add(a2.rotate_left(7))
        .wrapping_add(a3.rotate_left(12))
        .wrapping_add(a4.rotate_left(18));
    merge_round(merge_round(merge_round(merge_round(folded, a1), a2), a3), a4)
}

/// xxHash64's final avalanche: scrambles every bit of the folded value.
const fn avalanche(hash: u64) -> u64 {
    let h = hash ^ (hash >> 33);
    let h = h.wrapping_mul(PRIME64_B);
    let h = h ^ (h >> 29);
    let h = h.wrapping_mul(PRIME64_C);
    h ^ (h >> 32)
}

/// Seeds the four accumulator lanes from a base seed, exactly as xxHash64 does.
const fn seed_lanes(seed: u64) -> [u64; 4] {
    [
        seed.wrapping_add(PRIME64_A).wrapping_add(PRIME64_B),
        seed.wrapping_add(PRIME64_B),
        seed,
        seed.wrapping_sub(PRIME64_A),
    ]
}

/// Reads 8 little-endian bytes of `buf` at `off`, zero-filling past the end.
fn le_u64(buf: &[u8], off: usize) -> u64 {
    let mut value = 0_u64;
    for (index, &byte) in buf.iter().skip(off).take(8).enumerate() {
        value |= u64::from(byte) << (index * 8);
    }
    value
}

/// Reads 4 little-endian bytes of `buf` at `off`, zero-filling past the end.
fn le_u32(buf: &[u8], off: usize) -> u32 {
    let mut value = 0_u32;
    for (index, &byte) in buf.iter().skip(off).take(4).enumerate() {
        value |= u32::from(byte) << (index * 8);
    }
    value
}

/// Splits one full 32-byte block into its four little-endian `u64` lanes.
///
/// The parameter is a `&[u8; 32]` — a BORROWED fixed-size array — and both halves of that matter,
/// each worth about a fifth of the fold's cost at 1080p. Taking it by value copies every block to
/// the stack on the way in, three megabytes moved per frame to hash three megabytes (278 → 259 µs).
/// Taking it as a plain `&[u8]` costs the other half: the length is then unknown at compile time,
/// so the `chunks_exact` walk below stays a runtime loop instead of unrolling into four loads
/// (259 → 214 µs, which is where the Swift original stood).
fn block_lanes(block: &[u8; 32]) -> [u64; 4] {
    let mut lanes = [0_u64; 4];
    for (lane, chunk) in lanes.iter_mut().zip(block.chunks_exact(8)) {
        *lane = u64::from_le_bytes(chunk.try_into().unwrap_or([0; 8]));
    }
    lanes
}

/// Folds a sub-32-byte tail plus the total length into the hash, reproducing xxHash64's tail loop:
/// 8-byte groups, then one 4-byte group, then single bytes, then the avalanche.
fn finalize_tail(hash: u64, tail: &[u8], total_len: u64) -> u64 {
    let mut hash = hash.wrapping_add(total_len);
    let mut off = 0;
    while tail.len() - off >= 8 {
        hash ^= xxh_round(0, le_u64(tail, off));
        hash = hash
            .rotate_left(27)
            .wrapping_mul(PRIME64_A)
            .wrapping_add(PRIME64_D);
        off += 8;
    }
    if tail.len() - off >= 4 {
        hash ^= u64::from(le_u32(tail, off)).wrapping_mul(PRIME64_A);
        hash = hash
            .rotate_left(23)
            .wrapping_mul(PRIME64_B)
            .wrapping_add(PRIME64_C);
        off += 4;
    }
    for &byte in tail.iter().skip(off) {
        hash ^= u64::from(byte).wrapping_mul(PRIME64_E);
        hash = hash.rotate_left(11).wrapping_mul(PRIME64_A);
    }
    avalanche(hash)
}

/// A streaming fold over a byte stream presented in pieces.
///
/// The pieces are the visible, un-padded rows of a plane. The partial 32-byte block is carried
/// across them, so the result equals the hash of the concatenation of every row.
#[derive(Debug, Clone, Copy)]
pub struct StreamHasher {
    /// The four lane accumulators, live once at least one 32-byte block has been folded.
    lanes: [u64; 4],
    /// The seed, which is also the hash base for a total under 32 bytes (xxHash64's short path).
    seed: u64,
    /// Total bytes consumed; folded into the finish and selects short vs long path.
    total: u64,
    /// Bytes carried toward the next full block, in `0..32`.
    buf: [u8; 32],
    /// How many of `buf`'s bytes are live.
    buf_len: usize,
    /// Whether the 32-byte main loop has ever run.
    started: bool,
}

impl StreamHasher {
    /// A fresh hasher seeded with `seed`.
    #[must_use]
    pub const fn new(seed: u64) -> Self {
        Self {
            lanes: seed_lanes(seed),
            seed,
            total: 0,
            buf: [0; 32],
            buf_len: 0,
            started: false,
        }
    }

    /// Folds one full 32-byte block into the accumulators.
    fn consume_block(&mut self, block: &[u8; 32]) {
        let [w, x, y, z] = block_lanes(block);
        self.lanes = [
            xxh_round(self.lanes[0], w),
            xxh_round(self.lanes[1], x),
            xxh_round(self.lanes[2], y),
            xxh_round(self.lanes[3], z),
        ];
        self.started = true;
    }

    /// Appends `input` to the stream. Carries across calls, so feeding a plane row by row is exact.
    pub fn update(&mut self, input: &[u8]) {
        self.total = self.total.wrapping_add(input.len() as u64);
        let mut rest = input;

        // Top off a partially-filled carry buffer first.
        if self.buf_len > 0 {
            let take = (32 - self.buf_len).min(rest.len());
            let (head, tail) = rest.split_at(take);
            if let Some(slot) = self.buf.get_mut(self.buf_len..self.buf_len + take) {
                slot.copy_from_slice(head);
            }
            self.buf_len += take;
            rest = tail;
            if self.buf_len < 32 {
                return; // still short of a block
            }
            // Copied off the carry first, because folding it borrows the hasher mutably. This is
            // the one 32-byte copy the fold still makes, and it happens at most once per row.
            let carried = self.buf;
            self.consume_block(&carried);
            self.buf_len = 0;
        }

        // Consume whole 32-byte blocks straight out of `input`. The `try_from` is a length check
        // `chunks_exact` has already made — it converts the borrow, it does not copy — and its
        // point is telling the compiler the length, which is what unrolls the lane reads.
        let mut blocks = rest.chunks_exact(32);
        for chunk in &mut blocks {
            if let Ok(block) = <&[u8; 32]>::try_from(chunk) {
                self.consume_block(block);
            }
        }

        // Carry the remainder to the next call.
        let remainder = blocks.remainder();
        if !remainder.is_empty() {
            if let Some(slot) = self.buf.get_mut(..remainder.len()) {
                slot.copy_from_slice(remainder);
            }
            self.buf_len = remainder.len();
        }
    }

    /// The final 64-bit hash: the lane merge (or the short-input base), then the tail and
    /// avalanche.
    #[must_use]
    pub fn finish(&self) -> u64 {
        let base = if self.started {
            merge_lanes(self.lanes)
        } else {
            // Under 32 bytes total, xxHash64 starts from `seed + PRIME5` and the whole input is tail.
            self.seed.wrapping_add(PRIME64_E)
        };
        finalize_tail(base, self.buf.get(..self.buf_len).unwrap_or(&[]), self.total)
    }
}

/// Hashes one contiguous run of bytes — the whole of [`StreamHasher`] over a single slice, which is
/// what the per-row hashers want.
#[must_use]
pub fn hash_run(bytes: &[u8], seed: u64) -> u64 {
    let mut hasher = StreamHasher::new(seed);
    hasher.update(bytes);
    hasher.finish()
}

/// Folds the visible `width × height` region of one `stride`-spaced plane into `hasher`.
///
/// Only the first `width` bytes of each row are read, so row padding never reaches the hash. A
/// plane shorter than `stride * height` stops at the last whole row it does hold.
fn hash_plane(hasher: &mut StreamHasher, plane: &[u8], stride: usize, width: usize, height: usize) {
    if width == 0 || height == 0 || stride < width {
        return;
    }
    // CONTIGUOUS FAST PATH: with no row padding the visible region is `width * height` back-to-back
    // bytes, and one `update` over that run is byte-identical to the per-row loop — the streaming
    // fold does not care how a contiguous run is sliced. Falls through when the plane is truncated,
    // so the row loop can stop early instead.
    if stride == width
        && let Some(run) = width.checked_mul(height).and_then(|total| plane.get(..total))
    {
        hasher.update(run);
        return;
    }
    for row in 0..height {
        let Some(run) = row
            .checked_mul(stride)
            .and_then(|start| Some((start, start.checked_add(width)?)))
            .and_then(|(start, end)| plane.get(start..end))
        else {
            break;
        };
        hasher.update(run);
    }
}

/// Hashes an NV12 frame's luma and interleaved-chroma planes into one 64-bit value.
///
/// Reads only the first `width` bytes of each `*_stride`-spaced row, so the value depends on the
/// picture and not on the capture's padding. Returns [`SENTINEL`] for a degenerate dimension, a
/// stride narrower than the width, or a `stride * height` that overflows. `cbcr` of `None` — or a
/// chroma plane whose own dimensions are degenerate — hashes luma only.
#[must_use]
pub fn hash_nv12(
    y: &[u8],
    y_stride: usize,
    width: usize,
    height: usize,
    cbcr: Option<&[u8]>,
    cbcr_stride: usize,
) -> u64 {
    if width == 0 || height == 0 || y_stride < width {
        return SENTINEL;
    }
    let Some(y_len) = y_stride.checked_mul(height) else {
        return SENTINEL;
    };

    let mut hasher = StreamHasher::new(FRAME_HASH_SEED);
    hash_plane(&mut hasher, y.get(..y_len).unwrap_or(y), y_stride, width, height);

    // NV12 chroma: half the luma height, each row carrying `width / 2` interleaved Cb,Cr pairs, so
    // an even byte count per row. A pathological `stride * rows` falls back to luma-only.
    let chroma_rows = height.checked_div(2).unwrap_or(0);
    if let Some(plane) = cbcr
        && cbcr_stride > 0
        && chroma_rows > 0
        && let Some(len) = cbcr_stride.checked_mul(chroma_rows)
    {
        // `width & !1` is `(width / 2) * 2`: the even bytes an NV12 chroma row carries.
        let chroma_width = width & !1;
        hash_plane(
            &mut hasher,
            plane.get(..len).unwrap_or(plane),
            cbcr_stride,
            chroma_width,
            chroma_rows,
        );
    }
    hasher.finish()
}

/// Validates one NV12 luma plane's dimensions and narrows it to exactly the `stride * height` bytes
/// the walk may read, or returns `None` for any degenerate, absurd or overflowing input.
///
/// Shared by the scroll-shift and adaptive-QP entries, which both need "is this measurable at all"
/// answered once before they hash anything.
#[must_use]
pub fn borrow_plane(plane: &[u8], stride: usize, width: usize, height: usize) -> Option<&[u8]> {
    if width == 0
        || height == 0
        || width > MAX_PLANE_DIMENSION
        || height > MAX_PLANE_DIMENSION
        || stride < width
    {
        return None;
    }
    let len = stride.checked_mul(height)?;
    Some(plane.get(..len).unwrap_or(plane))
}

/// One captured luma plane: the bytes and the row stride they are spaced by.
///
/// The pair travels together because neither half means anything alone — the whole class of bug
/// this port removes is a plane read at another plane's stride.
#[derive(Debug, Clone, Copy)]
pub struct LumaPlane<'a> {
    /// The plane's bytes, at least `stride * height` of them for a full read.
    pub bytes: &'a [u8],
    /// Bytes from the start of one row to the start of the next.
    pub stride: usize,
}

impl<'a> LumaPlane<'a> {
    /// A plane over `bytes`, whose rows are `stride` bytes apart.
    #[must_use]
    pub const fn new(bytes: &'a [u8], stride: usize) -> Self {
        Self { bytes, stride }
    }

    /// The plane's per-row hashes, or `None` when the dimensions make it unmeasurable.
    ///
    /// This is the one entry the frame-difference measurements share: [`borrow_plane`]'s validation
    /// and [`row_hashes_quantized`]'s walk, which neither of them should be doing separately.
    #[must_use]
    pub fn row_hashes(&self, width: usize, height: usize, q_shift: u8) -> Option<Vec<u64>> {
        let visible = borrow_plane(self.bytes, self.stride, width, height)?;
        Some(row_hashes_quantized(visible, self.stride, width, height, q_shift))
    }
}

/// Per-row luma hashes: the first `width` bytes of each of the `height` `stride`-spaced rows.
///
/// Bounds-guarded per row, so an over-stated `height` stops at the last whole row the plane holds
/// rather than reading past it. Each row is hashed exactly as a one-row luma-only frame would be.
#[must_use]
pub fn row_hashes(y: &[u8], stride: usize, width: usize, height: usize) -> Vec<u64> {
    row_hashes_quantized(y, stride, width, height, 0)
}

/// Per-row luma hashes over QUANTIZED luma: every byte is right-shifted by `q_shift` bits before
/// hashing, so rows that differ only by capture noise hash the same.
///
/// The scroll estimator matches rows by exact hash equality, which is too brittle for real captured
/// scroll: one resampled or dithered pixel changes a row's hash, the row stops matching its own
/// translated self, and the confidence collapses to "no scroll". Dropping the low `q_shift` bits
/// puts that noise in the same bucket. Distinct content still hashes differently, and the caller's
/// confidence gate remains the false-positive guard. `q_shift == 0` is the exact, byte-for-byte
/// path. A `q_shift` of 8 or more shifts every byte out and hashes a row of zeros, which is what
/// Swift's over-wide shift already did; it is out of the caller's documented `0..=7` either way.
#[must_use]
pub fn row_hashes_quantized(y: &[u8], stride: usize, width: usize, height: usize, q_shift: u8) -> Vec<u64> {
    let mut out = Vec::new();
    if width == 0 {
        return out;
    }
    out.reserve(height);
    let shift = u32::from(q_shift);
    let mut scratch = Vec::new();
    for row in 0..height {
        let Some(run) = row
            .checked_mul(stride)
            .and_then(|start| Some((start, start.checked_add(width)?)))
            .and_then(|(start, end)| y.get(start..end))
        else {
            break;
        };
        if shift == 0 {
            out.push(hash_run(run, FRAME_HASH_SEED));
        } else {
            scratch.clear();
            scratch.extend(run.iter().map(|&byte| byte.checked_shr(shift).unwrap_or(0)));
            out.push(hash_run(&scratch, FRAME_HASH_SEED));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::cast_possible_truncation,
        reason = "the synthetic planes are built from small row/column arithmetic, and a wrapped byte would \
                  still be a deterministic byte"
    )]

    use super::{
        FRAME_HASH_SEED, SENTINEL, StreamHasher, borrow_plane, hash_nv12, hash_run, row_hashes,
        row_hashes_quantized,
    };

    /// The values the Swift original produced, transcribed from a run of it against these exact
    /// inputs. This is the whole parity argument for the port: the fold has no external oracle —
    /// its `PRIME64_E` is not xxHash64's, so `xxh64sum` would disagree — and the numbers below are
    /// the only thing standing between a transcription slip and a frame hash that quietly means
    /// something else.
    ///
    /// Every path is covered: the under-32-byte tail, the 8- and 4-byte tail groups, the four-lane
    /// main loop, and both seeds.
    #[test]
    fn every_hash_the_swift_produced_is_the_hash_this_produces() {
        assert_eq!(hash_run(b"", 0), 0xFAB2_67E1_BE24_D671, "the empty short path");
        assert_eq!(hash_run(b"a", 0), 0x6C82_8EE9_411B_B22A, "a single tail byte");
        assert_eq!(hash_run(b"abc", 0), 0x276E_35C9_8ABE_9992);
        assert_eq!(
            hash_run(b"abcdefghijklmnop", 0),
            0x42DE_7B67_B7BA_4610,
            "8- and 4-byte groups"
        );
        assert_eq!(
            hash_run(&[0_u8; 64], 0),
            0x257B_09A1_47B8_2A19,
            "two whole blocks, no tail"
        );
        assert_eq!(
            hash_run(b"abcdefghijklmnopqrstuvwxyz012345", 0),
            0xBF2C_D639_B414_3B80,
            "exactly one block",
        );
        assert_eq!(
            hash_run(b"", FRAME_HASH_SEED),
            0xA9AF_BC49_8AD6_889F,
            "the frame seed"
        );
        let long: Vec<u8> = (0..200_u32).map(|value| (value % 251) as u8).collect();
        assert_eq!(
            hash_run(&long, FRAME_HASH_SEED),
            0x3CE4_5941_AA63_688B,
            "blocks and a tail"
        );
    }

    /// The same pin for the plane walk: padding skipped, chroma folded in after luma, and each row
    /// hashed on its own — the shapes a stride bug would silently change.
    #[test]
    fn every_plane_hash_the_swift_produced_is_the_hash_this_produces() {
        let mut y = vec![0xAB_u8; 12 * 8];
        for row in 0..8_usize {
            for column in 0..8_usize {
                if let Some(slot) = y.get_mut(row * 12 + column) {
                    *slot = (row * 40 + column * 3 + 1) as u8;
                }
            }
        }
        let mut cbcr = vec![0xCD_u8; 10 * 4];
        for row in 0..4_usize {
            for column in 0..8_usize {
                if let Some(slot) = cbcr.get_mut(row * 10 + column) {
                    *slot = (row * 7 + column * 5 + 2) as u8;
                }
            }
        }
        assert_eq!(
            hash_nv12(&y, 12, 8, 8, None, 0),
            0x49BF_776E_2121_DC9A,
            "luma only"
        );
        assert_eq!(
            hash_nv12(&y, 12, 8, 8, Some(&cbcr), 10),
            0xEAFC_F634_D579_23F3,
            "luma then chroma",
        );

        let rows = row_hashes(&y, 12, 8, 8);
        assert_eq!(rows.len(), 8);
        assert_eq!(rows.first().copied(), Some(0x0E5E_F459_353D_ACAF));
        assert_eq!(rows.last().copied(), Some(0xBBDF_B697_33A9_3B3D));
        assert_eq!(
            row_hashes_quantized(&y, 12, 8, 8, 2).first().copied(),
            Some(0x6B6E_D74B_9CCA_87CD),
        );
    }

    /// The streaming carry has to land the 32-byte boundary the same however the caller slices, or
    /// the per-row plane walk and the contiguous fast path would disagree.
    #[test]
    fn every_slicing_of_the_same_run_folds_to_the_same_hash() {
        let data: Vec<u8> = (0..200_u32).map(|value| (value % 251) as u8).collect();
        let whole = hash_run(&data, FRAME_HASH_SEED);
        for cut in 1..data.len() {
            let mut hasher = StreamHasher::new(FRAME_HASH_SEED);
            let (head, tail) = data.split_at(cut);
            hasher.update(head);
            hasher.update(tail);
            assert_eq!(hasher.finish(), whole, "split at {cut}");
        }
        // Three pieces, including one that lands exactly on a block boundary.
        let mut hasher = StreamHasher::new(FRAME_HASH_SEED);
        hasher.update(data.get(..32).unwrap_or_default());
        hasher.update(data.get(32..33).unwrap_or_default());
        hasher.update(data.get(33..).unwrap_or_default());
        assert_eq!(hasher.finish(), whole);
    }

    /// The whole point of hashing rows rather than the buffer: padding must not reach the hash.
    #[test]
    fn row_padding_does_not_reach_the_hash() {
        let width = 7;
        let height = 4;
        let mut padded = vec![0_u8; 16 * height];
        let mut tight = Vec::new();
        for row in 0..height {
            for column in 0..width {
                let value = (row * 31 + column * 7) as u8;
                if let Some(slot) = padded.get_mut(row * 16 + column) {
                    *slot = value;
                }
                tight.push(value);
            }
            // Padding bytes carry garbage that must be invisible.
            for column in width..16 {
                if let Some(slot) = padded.get_mut(row * 16 + column) {
                    *slot = 0xAB;
                }
            }
        }
        assert_eq!(
            hash_nv12(&padded, 16, width, height, None, 0),
            hash_nv12(&tight, width, width, height, None, 0),
        );
    }

    #[test]
    fn a_degenerate_frame_is_the_sentinel_and_never_a_hash() {
        assert_eq!(hash_nv12(&[1, 2, 3], 3, 0, 1, None, 0), SENTINEL);
        assert_eq!(hash_nv12(&[1, 2, 3], 3, 3, 0, None, 0), SENTINEL);
        assert_eq!(
            hash_nv12(&[1, 2, 3], 2, 3, 1, None, 0),
            SENTINEL,
            "stride under width"
        );
        assert_eq!(
            hash_nv12(&[1, 2, 3], usize::MAX, 3, 4, None, 0),
            SENTINEL,
            "stride*height wraps"
        );
        // A genuine all-zero plane is a real hash, which is the reason the sentinel is not zero.
        assert_ne!(hash_nv12(&[0_u8; 64], 8, 8, 8, None, 0), SENTINEL);
        assert_ne!(hash_nv12(&[0_u8; 64], 8, 8, 8, None, 0), 0);
    }

    #[test]
    fn chroma_changes_the_frame_hash_and_a_missing_chroma_is_luma_only() {
        let y = vec![9_u8; 64];
        let luma_only = hash_nv12(&y, 8, 8, 8, None, 0);
        let with_chroma = hash_nv12(&y, 8, 8, 8, Some(&[5_u8; 32]), 8);
        assert_ne!(luma_only, with_chroma);
        // A zero chroma stride is "no chroma plane", not a division by it.
        assert_eq!(hash_nv12(&y, 8, 8, 8, Some(&[5_u8; 32]), 0), luma_only);
    }

    /// A truncated plane stops at the last whole row instead of reading — the property the raw
    /// pointer walk could only assert.
    #[test]
    fn a_truncated_plane_stops_at_the_last_whole_row() {
        let full = vec![3_u8; 40];
        let hashes = row_hashes(&full, 10, 10, 8);
        assert_eq!(hashes.len(), 4, "the plane only holds four rows");
        assert_eq!(row_hashes(&full, 10, 10, 4), hashes);
    }

    #[test]
    fn a_row_hash_is_the_hash_of_that_row_alone() {
        let plane: Vec<u8> = (0..48_u8).collect();
        let hashes = row_hashes(&plane, 16, 12, 3);
        assert_eq!(hashes.len(), 3);
        for (row, hash) in hashes.iter().enumerate() {
            let start = row * 16;
            let expected = hash_run(plane.get(start..start + 12).unwrap_or_default(), FRAME_HASH_SEED);
            assert_eq!(*hash, expected);
        }
    }

    /// Quantizing is the whole defence against capture noise: one flipped low bit must not change a
    /// row's hash, while genuinely different content still must.
    #[test]
    fn quantizing_folds_low_bit_noise_but_not_real_content() {
        let clean: Vec<u8> = (0..64_u8).map(|value| value.wrapping_mul(3)).collect();
        let mut noisy = clean.clone();
        for byte in &mut noisy {
            *byte ^= 1;
        }
        assert_ne!(row_hashes(&clean, 64, 64, 1), row_hashes(&noisy, 64, 64, 1));
        assert_eq!(
            row_hashes_quantized(&clean, 64, 64, 1, 2),
            row_hashes_quantized(&noisy, 64, 64, 1, 2),
        );
        let different: Vec<u8> = (0..64_u8).map(|value| value.wrapping_mul(7)).collect();
        assert_ne!(
            row_hashes_quantized(&clean, 64, 64, 1, 2),
            row_hashes_quantized(&different, 64, 64, 1, 2),
        );
        // Past 8 bits every byte shifts out, so the row hashes as zeros rather than panicking.
        assert_eq!(
            row_hashes_quantized(&clean, 64, 64, 1, 9),
            row_hashes(&[0_u8; 64], 64, 64, 1),
        );
    }

    #[test]
    fn a_plane_is_borrowed_only_at_a_sane_dimension() {
        let plane = vec![0_u8; 64];
        assert_eq!(borrow_plane(&plane, 8, 8, 8).map(<[u8]>::len), Some(64));
        assert!(borrow_plane(&plane, 8, 0, 8).is_none());
        assert!(borrow_plane(&plane, 8, 8, 0).is_none());
        assert!(borrow_plane(&plane, 8, 9, 8).is_none(), "stride under width");
        assert!(borrow_plane(&plane, 20000, 20000, 1).is_none(), "absurd width");
        assert!(borrow_plane(&plane, 1, 1, 20000).is_none(), "absurd height");
        assert!(
            borrow_plane(&plane, usize::MAX, 1, 4).is_none(),
            "stride*height wraps"
        );
        // A short plane borrows what it has, so the row walk can stop early on its own.
        assert_eq!(borrow_plane(&plane, 16, 16, 8).map(<[u8]>::len), Some(64));
    }
}
