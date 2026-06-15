//! Forward-error-correction over a frame's data fragments — the canonical
//! `FECScheme` family (the Swift shell mirrors it).
//!
//! Two schemes share the [`FecScheme`] trait over the same fragment groups:
//!
//! * [`XorParityFec`] — one XOR parity per group, recovers exactly one lost fragment per
//!   group (the v1 default, byte-stable forever).
//! * [`ReedSolomonFec`] — a systematic Reed-Solomon code over GF(2^8) (see [`crate::gf256`]
//!   / [`crate::rs_matrix`]) producing `m` parity shards per group and recovering up to `m`
//!   lost fragments per group. With `m == 1` it is *byte-identical* to [`XorParityFec`].
//!
//! ## Parity layout (multi-parity schemes)
//!
//! [`parity`](FecScheme::parity) returns `group_count * parity_count_per_group()` parity
//! fragments in **group-major, then parity-rank** order: group 0's rank-0..(m-1), then
//! group 1's rank-0..(m-1), and so on. [`recover`](FecScheme::recover) indexes the parity
//! slice as `parity[group * m + rank]`. For [`XorParityFec`] (`m == 1`) this collapses to
//! one parity per group at `parity[group]` — byte-identical to the v1 wire layout.

use crate::gf256::{GfRegion, ScalarGf};

/// A forward-error-correction scheme over a frame's data fragments.
///
/// `parity` produces parity fragments from the frame's data fragments; `recover` fills
/// any `None` (lost) data fragment it can, leaving still-`None` entries for losses it
/// cannot repair (which the caller escalates to request-recovery).
pub trait FecScheme {
    /// The default group size: how many data fragments share the group's parity when
    /// no explicit per-frame group size is supplied (`5` ⇒ 20% overhead in prod).
    fn group_size(&self) -> usize;

    /// How many parity fragments each group produces (the code's `m`). Defaults to `1`, so
    /// single-parity schemes (e.g. [`XorParityFec`]) and every existing caller compile
    /// unchanged. [`parity`](Self::parity) emits this many parities *per group*, and
    /// [`recover`](Self::recover) reads them at `parity[group * parity_count_per_group() + rank]`.
    fn parity_count_per_group(&self) -> usize {
        1
    }

    /// Computes parity fragments for `data`, grouping by `group_size`, returned in
    /// group-major then parity-rank order (see the module-level layout note). The result
    /// has `ceil(data.len() / group_size) * parity_count_per_group()` entries.
    fn parity(&self, data: &[&[u8]], group_size: usize) -> Vec<Vec<u8>>;

    /// Fills recoverable holes (`None`) in `data` in place, using `parity` (in the same
    /// group-major/parity-rank layout [`parity`](Self::parity) produced), grouping by
    /// `group_size`. Entries that cannot be recovered (more holes than parity, or missing
    /// parity) stay `None`. Never panics on hostile input.
    fn recover(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>], group_size: usize);

    /// Parity using the scheme's configured default [`group_size`](FecScheme::group_size).
    fn parity_default(&self, data: &[&[u8]]) -> Vec<Vec<u8>> {
        self.parity(data, self.group_size())
    }

    /// Recover using the scheme's configured default [`group_size`](FecScheme::group_size).
    fn recover_default(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>]) {
        let group_size = self.group_size();
        self.recover(data, parity, group_size);
    }
}

/// XOR parity FEC: each group of `group_size` data fragments produces one parity
/// fragment = the byte-wise XOR of the group.
///
/// A single missing fragment in a group is
/// recovered as `parity XOR (surviving members)`; two or more losses in one group are
/// unrecoverable.
///
/// Each data fragment is length-prefixed (`[u32 BE len][bytes]`) BEFORE the XOR so that
/// recovery reproduces the *exact* original length even when group members differ in
/// size; the XOR is zero-padded to the longest member.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct XorParityFec {
    group_size: usize,
}

impl Default for XorParityFec {
    /// `group_size = 5` ⇒ 20% parity (the doc-17 / Sunshine default).
    fn default() -> Self {
        Self { group_size: 5 }
    }
}

/// `[u32 BE len][bytes]`. A fragment never approaches 4 GiB (MTU-bounded), so the
/// `u32` length holds by construction; asserted in debug, panic-free in release.
///
/// Shared by [`XorParityFec`] and [`ReedSolomonFec`]: both compute parity over the
/// length-prefixed encoding so recovery reproduces the *exact* original length even when
/// group members differ in size (the linear code is over the zero-padded encodings).
pub(crate) fn length_prefixed(data: &[u8]) -> Vec<u8> {
    debug_assert!(
        u32::try_from(data.len()).is_ok(),
        "FEC fragment exceeds u32 length"
    );
    let mut out = Vec::with_capacity(4 + data.len());
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(data);
    out
}

/// Inverse of [`length_prefixed`]: reads the embedded length and slices exactly that many
/// bytes, ignoring trailing zero padding. `None` if the declared length does not fit (a
/// corrupt prefix on hostile input — recovery then leaves the hole rather than panicking).
pub(crate) fn strip_length_prefix(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() < 4 {
        return None;
    }
    let length = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let end = 4usize.checked_add(length)?;
    if end <= data.len() {
        Some(data[4..end].to_vec())
    } else {
        None
    }
}

impl XorParityFec {
    /// Builds an XOR parity scheme.
    ///
    /// # Panics
    /// Panics if `group_size == 0` (a programming error — matches the Swift
    /// `precondition(groupSize >= 1)`). The per-call `group_size` passed to `parity` /
    /// `recover` is floored to 1 defensively and never panics.
    #[must_use]
    pub const fn new(group_size: usize) -> Self {
        assert!(group_size >= 1, "group_size must be >= 1");
        Self { group_size }
    }

    /// XOR of the length-prefixed encodings of a group, zero-padded to the longest.
    ///
    /// The inner XOR is written as `acc.iter_mut().zip(member)` (not indexed `acc[i] ^= b`):
    /// `member.len() <= acc.len()` always (acc is sized to the longest member), so the zip
    /// covers every member byte while eliding the per-iteration bounds check, which lets LLVM
    /// autovectorise the accumulate to NEON on Apple Silicon. Result is byte-identical.
    #[inline]
    fn xor_encoded(group: &[&[u8]]) -> Vec<u8> {
        let encoded: Vec<Vec<u8>> = group.iter().map(|m| length_prefixed(m)).collect();
        let width = encoded.iter().map(Vec::len).max().unwrap_or(0);
        let mut acc = vec![0u8; width];
        for member in &encoded {
            for (a, b) in acc.iter_mut().zip(member.iter()) {
                *a ^= *b;
            }
        }
        acc
    }

    /// `parity XOR (encoded survivors)` = the encoded form of the missing member,
    /// zero-padded. Trailing zeros beyond the embedded length are harmless because
    /// [`strip_length_prefix`] cuts to the declared length.
    #[inline]
    fn xor_recover(parity: &[u8], survivors: &[&[u8]]) -> Vec<u8> {
        let encoded_survivors: Vec<Vec<u8>> =
            survivors.iter().map(|m| length_prefixed(m)).collect();
        let width = parity
            .len()
            .max(encoded_survivors.iter().map(Vec::len).max().unwrap_or(0));
        let mut acc = vec![0u8; width];
        // `iter_mut().zip()` (not indexed): each operand's len <= acc.len() (acc is sized to the
        // max), so the zip is complete and bounds-check-free, enabling NEON autovectorisation.
        for (a, b) in acc.iter_mut().zip(parity.iter()) {
            *a ^= *b;
        }
        for member in &encoded_survivors {
            for (a, b) in acc.iter_mut().zip(member.iter()) {
                *a ^= *b;
            }
        }
        acc
    }
}

impl FecScheme for XorParityFec {
    fn group_size(&self) -> usize {
        self.group_size
    }

    fn parity(&self, data: &[&[u8]], group_size: usize) -> Vec<Vec<u8>> {
        let group_size = group_size.max(1); // defensive floor: a 0 size must never loop forever.
        let mut parities = Vec::new();
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            parities.push(Self::xor_encoded(&data[index..upper]));
            index += group_size;
        }
        parities
    }

    fn recover(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>], group_size: usize) {
        let group_size = group_size.max(1); // defensive floor (matches `parity`).
        let mut group_index = 0;
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            let missing: Vec<usize> = (index..upper).filter(|&i| data[i].is_none()).collect();
            if missing.len() == 1
                && let Some(Some(parity_bytes)) = parity.get(group_index)
            {
                let survivors: Vec<&[u8]> =
                    (index..upper).filter_map(|i| data[i].as_deref()).collect();
                let recovered_encoded = Self::xor_recover(parity_bytes, &survivors);
                if let Some(bytes) = strip_length_prefix(&recovered_encoded) {
                    data[missing[0]] = Some(bytes);
                }
            }
            index += group_size;
            group_index += 1;
        }
    }
}

/// Systematic Reed-Solomon erasure code over GF(2^8).
///
/// Each group of up to `k` data fragments produces `m` parity fragments, and any `m` losses
/// *within a group* are recoverable (an `[n = k + m, k]` MDS code per group, the baseline
/// most realtime stacks use).
///
/// The code operates over the **length-prefixed, zero-padded** encoding of the group
/// (`[u32 BE len][bytes]` per shard, padded to the group's widest member `W`) exactly like
/// [`XorParityFec`], so recovery reproduces the precise original fragment length. The parity
/// coefficients come from a Cauchy block (see [`crate::rs_matrix`]); decoding inverts the
/// `k × k` encoder submatrix of the survivors over [`crate::gf256`].
///
/// ## `m == 1` is byte-identical to [`XorParityFec`]
///
/// A Cauchy parity row is *not* all-ones, so a literal RS encode with `m == 1` would emit
/// different parity *bytes* than the plain XOR even though recovery would still be correct.
/// Because the contract guarantees `m == 1` matches the v1 XOR wire format exactly, this
/// type **special-cases `m == 1` to plain XOR** internally (delegating to the shared framing
/// helpers): the parity bytes, and the recovered bytes, are bit-for-bit the XOR scheme's.
/// For `m >= 2` the full GF(2^8) Cauchy machinery runs.
///
/// The [`GfRegion`] backend is generic so a SIMD implementation can drop in without
/// touching the codec; [`ScalarGf`] is the portable default.
///
/// [`GfRegion`]: crate::gf256::GfRegion
/// [`ScalarGf`]: crate::gf256::ScalarGf
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReedSolomonFec<G: GfRegion = ScalarGf> {
    /// Data shards per group (the code's `k`).
    group_size: usize,
    /// Parity shards per group (the code's `m`).
    parity: usize,
    /// The GF(2^8) arithmetic backend.
    gf: G,
}

impl ReedSolomonFec<ScalarGf> {
    /// Builds a Reed-Solomon scheme with `k` data + `m` parity shards per group, using the
    /// portable scalar GF(2^8) backend.
    ///
    /// # Panics
    /// Panics if `k < 1`, `m < 1`, or `k + m > 255` (the Cauchy index sets must fit GF(2^8);
    /// `255` leaves the field's elements addressable). These are construction-time
    /// programming errors; the per-call `group_size` passed to `parity`/`recover` is floored
    /// to 1 defensively and never panics.
    #[must_use]
    pub fn new(k: usize, m: usize) -> Self {
        Self::with_backend(k, m, ScalarGf)
    }
}

impl<G: GfRegion> ReedSolomonFec<G> {
    /// Builds a Reed-Solomon scheme over an explicit [`GfRegion`](crate::gf256::GfRegion)
    /// backend (e.g. a SIMD one).
    ///
    /// # Panics
    /// Panics if `k < 1`, `m < 1`, or `k + m > 255` (see [`new`](ReedSolomonFec::new)).
    pub fn with_backend(k: usize, m: usize, gf: G) -> Self {
        assert!(k >= 1, "k (group_size) must be >= 1");
        assert!(m >= 1, "m (parity count) must be >= 1");
        assert!(k + m <= 255, "k + m must be <= 255 to fit GF(2^8)");
        Self {
            group_size: k,
            parity: m,
            gf,
        }
    }

    /// Encodes one group's `m` parity shards into `out` (appended in rank order).
    ///
    /// Frames each of the up-to-`k` data shards (length-prefixed) and zero-pads to the
    /// group's widest member `W`, then for each parity row folds `coeff * framed_shard` into
    /// a fresh `W`-wide accumulator via the GF backend's `mul_add`. `m == 1` takes the plain
    /// XOR path so the bytes match [`XorParityFec`] exactly.
    fn encode_group(&self, group: &[&[u8]], out: &mut Vec<Vec<u8>>) {
        // `m == 1`: byte-identical to XOR parity (the shared encoder).
        if self.parity == 1 {
            out.push(XorParityFec::xor_encoded(group));
            return;
        }
        let framed: Vec<Vec<u8>> = group.iter().map(|s| length_prefixed(s)).collect();
        let width = framed.iter().map(Vec::len).max().unwrap_or(0);
        let coeffs = crate::rs_matrix::parity_rows(self.group_size, self.parity);
        for rank in 0..self.parity {
            let mut acc = vec![0u8; width];
            for (j, shard) in framed.iter().enumerate() {
                // Coefficient for parity `rank` over data shard `j`. A group can hold fewer
                // than k shards (the final short group); only the present shards contribute.
                let coeff = coeffs[rank * self.group_size + j];
                self.gf.mul_add(coeff, shard, &mut acc);
            }
            out.push(acc);
        }
    }

    /// Recovers a single group's holes in place (indices `index..upper` of `data`), using the
    /// group's `m` parity shards at `parity[group_index * m .. group_index * m + m]`.
    ///
    /// Leaves every hole untouched when unrecoverable (`holes == 0`, `holes > m`, too few
    /// surviving parity, a singular submatrix, or a corrupt length prefix) — never panics.
    fn recover_group(
        &self,
        data: &mut [Option<Vec<u8>>],
        parity: &[Option<Vec<u8>>],
        index: usize,
        upper: usize,
        group_index: usize,
    ) {
        let k = self.group_size;
        let m = self.parity;
        let group_len = upper - index;

        // Holes are missing DATA shards; their position within the group is `i - index`.
        let holes: Vec<usize> = (index..upper).filter(|&i| data[i].is_none()).collect();
        if holes.is_empty() || holes.len() > m {
            return; // nothing to do, or beyond this group's repair budget
        }

        // m == 1: a single hole, plain XOR recover (byte-identical to XorParityFec).
        if m == 1 {
            if let Some(Some(parity_bytes)) = parity.get(group_index) {
                let survivors: Vec<&[u8]> =
                    (index..upper).filter_map(|i| data[i].as_deref()).collect();
                let recovered = XorParityFec::xor_recover(parity_bytes, &survivors);
                if let Some(bytes) = strip_length_prefix(&recovered) {
                    data[holes[0]] = Some(bytes);
                }
            }
            return;
        }

        // The encoder treats a short final group (group_len < k) as having (k - group_len)
        // implicit all-zero data shards in slots group_len..k. Those phantom shards are never
        // missing (they are the constant 0), so they always count as survivors.
        let parity_coeffs = crate::rs_matrix::parity_rows(k, m);

        // Collect k survivor (encoder-row, framed-bytes) pairs. Encoder indices: 0..k are the
        // data rows (identity), k..k+m are the parity rows. We need exactly k linearly
        // independent survivors; any k of the n MDS rows suffice.
        let mut survivor_rows: Vec<Vec<u8>> = Vec::with_capacity(k);
        let mut survivor_bytes: Vec<Vec<u8>> = Vec::with_capacity(k);

        // 1) Present real data shards contribute their identity row e_j and framed bytes.
        for slot in 0..group_len {
            if let Some(bytes) = data[index + slot].as_deref() {
                let mut row = vec![0u8; k];
                row[slot] = 1;
                survivor_rows.push(row);
                survivor_bytes.push(length_prefixed(bytes));
            }
        }
        // 2) Phantom zero shards in a short final group are known-zero survivors (identity row,
        //    all-zero bytes). They let a short group still reach k independent rows.
        for slot in group_len..k {
            let mut row = vec![0u8; k];
            row[slot] = 1;
            survivor_rows.push(row);
            survivor_bytes.push(Vec::new()); // all-zero contributes nothing
        }
        // 3) Fill the remaining slots from present parity shards (their Cauchy rows).
        let parity_base = group_index * m;
        let mut rank = 0;
        while survivor_rows.len() < k && rank < m {
            if let Some(Some(parity_bytes)) = parity.get(parity_base + rank) {
                let row = parity_coeffs[rank * k..rank * k + k].to_vec();
                survivor_rows.push(row);
                survivor_bytes.push(parity_bytes.clone());
            }
            rank += 1;
        }

        if survivor_rows.len() < k {
            return; // not enough surviving shards to solve — leave the holes
        }
        // Use exactly k survivors (we may have collected k from data+phantom already).
        survivor_rows.truncate(k);
        survivor_bytes.truncate(k);

        // Invert the k×k encoder submatrix of the chosen survivors.
        let Some(inverse) = crate::rs_matrix::invert_subset(&survivor_rows, k) else {
            return; // singular (should not happen for a true MDS subset) — leave holes
        };

        // Width of the working accumulator: the widest survivor's framed length.
        let width = survivor_bytes.iter().map(Vec::len).max().unwrap_or(0);

        // For each missing DATA slot, the original framed shard is row `slot` of
        // (inverse · survivor_bytes): acc = Σ_t inverse[slot * k + t] * survivor_bytes[t].
        for &hole in &holes {
            let slot = hole - index; // 0..k position of the missing data shard
            let mut acc = vec![0u8; width];
            for (t, sbytes) in survivor_bytes.iter().enumerate() {
                let coeff = inverse[slot * k + t];
                self.gf.mul_add(coeff, sbytes, &mut acc);
            }
            if let Some(bytes) = strip_length_prefix(&acc) {
                data[hole] = Some(bytes);
            }
        }
    }
}

impl<G: GfRegion> FecScheme for ReedSolomonFec<G> {
    fn group_size(&self) -> usize {
        self.group_size
    }

    fn parity_count_per_group(&self) -> usize {
        self.parity
    }

    fn parity(&self, data: &[&[u8]], group_size: usize) -> Vec<Vec<u8>> {
        // The Cauchy encoder has exactly `k = self.group_size` columns, so a group can never
        // hold more than `k` data shards. The per-call `group_size` is honoured up to `k` and
        // clamped down to it (a 0 floors to 1), keeping encode and decode self-consistent.
        let group_size = group_size.max(1).min(self.group_size);
        let mut parities = Vec::new();
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            self.encode_group(&data[index..upper], &mut parities);
            index += group_size;
        }
        parities
    }

    fn recover(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>], group_size: usize) {
        let group_size = group_size.max(1).min(self.group_size); // matches `parity`'s clamp.
        let mut group_index = 0;
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            self.recover_group(data, parity, index, upper, group_index);
            index += group_size;
            group_index += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slices(v: &[Vec<u8>]) -> Vec<&[u8]> {
        v.iter().map(Vec::as_slice).collect()
    }

    #[test]
    fn parity_count_matches_ceil_groups() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = (0..12u8).map(|i| vec![i; 3]).collect();
        // ceil(12/5) = 3 parity fragments.
        assert_eq!(fec.parity(&slices(&data), 5).len(), 3);
    }

    #[test]
    fn recovers_single_loss_per_group() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = vec![vec![1, 2], vec![3], vec![4, 5, 6], vec![7], vec![8, 9]];
        let parity = fec.parity(&slices(&data), 5);
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[2] = None; // lose the middle fragment
        let parity_opt: Vec<Option<Vec<u8>>> = parity.iter().cloned().map(Some).collect();
        fec.recover(&mut received, &parity_opt, 5);
        let recovered: Vec<Vec<u8>> = received.into_iter().map(Option::unwrap).collect();
        assert_eq!(recovered, data);
    }

    #[test]
    fn two_losses_in_one_group_unrecoverable() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = (0..5u8).map(|i| vec![i, i + 1]).collect();
        let parity = fec.parity(&slices(&data), 5);
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[1] = None;
        received[3] = None;
        let parity_opt: Vec<Option<Vec<u8>>> = parity.iter().cloned().map(Some).collect();
        fec.recover(&mut received, &parity_opt, 5);
        assert!(received[1].is_none() && received[3].is_none());
    }

    #[test]
    fn recovers_across_multiple_groups() {
        let fec = XorParityFec::new(2);
        let data: Vec<Vec<u8>> = vec![vec![10], vec![20], vec![30], vec![40], vec![50]];
        let parity = fec.parity(&slices(&data), 2); // 3 groups: [0,1][2,3][4]
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[0] = None; // group 0 hole
        received[3] = None; // group 1 hole
        received[4] = None; // group 2 (single member) hole — recoverable, parity = encoded(member)
        let parity_opt: Vec<Option<Vec<u8>>> = parity.iter().cloned().map(Some).collect();
        fec.recover(&mut received, &parity_opt, 2);
        let recovered: Vec<Vec<u8>> = received.into_iter().map(Option::unwrap).collect();
        assert_eq!(recovered, data);
    }

    #[test]
    fn missing_parity_leaves_hole() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = (0..3u8).map(|i| vec![i]).collect();
        let mut received: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        received[1] = None;
        fec.recover(&mut received, &[None], 5); // parity also lost
        assert!(received[1].is_none());
    }

    #[test]
    fn defensive_zero_group_size_does_not_loop() {
        let fec = XorParityFec::new(5);
        let data: Vec<Vec<u8>> = vec![vec![1], vec![2]];
        // group_size 0 floored to 1 → 2 parity fragments, each a single-member group.
        assert_eq!(fec.parity(&slices(&data), 0).len(), 2);
    }

    // ----- Reed-Solomon -----------------------------------------------------------------

    /// Deterministic `SplitMix64` PRNG (no external crate); good enough to fuzz shard bytes.
    struct SplitMix(u64);
    impl SplitMix {
        const fn new(seed: u64) -> Self {
            Self(seed)
        }
        fn next_u64(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
        fn byte(&mut self) -> u8 {
            self.next_u64() as u8
        }
        fn range(&mut self, n: usize) -> usize {
            (self.next_u64() % (n as u64)) as usize
        }
    }

    fn opt(parity: &[Vec<u8>]) -> Vec<Option<Vec<u8>>> {
        parity.iter().cloned().map(Some).collect()
    }

    /// Recursive worker for [`for_each_subset_up_to`]: chooses indices in increasing order.
    fn subset_recurse(
        start: usize,
        depth: usize,
        n: usize,
        size: usize,
        chosen: &mut [usize],
        f: &mut impl FnMut(&[usize]),
    ) {
        if depth == size {
            f(chosen);
            return;
        }
        for v in start..n {
            chosen[depth] = v;
            subset_recurse(v + 1, depth + 1, n, size, chosen, f);
        }
    }

    /// Enumerate every subset of `0..n` of size `0..=max_size`, invoking `f` with each.
    fn for_each_subset_up_to(n: usize, max_size: usize, mut f: impl FnMut(&[usize])) {
        for size in 0..=max_size {
            let mut chosen = vec![0usize; size];
            subset_recurse(0, 0, n, size, &mut chosen, &mut f);
        }
    }

    #[test]
    fn rs_m1_parity_bytes_identical_to_xor() {
        // The load-bearing anchor: ReedSolomonFec::new(k, 1) emits BYTE-IDENTICAL parity to
        // XorParityFec::new(k), and recovers a single loss to the same bytes, across many
        // seeds and shard-size mixes (the m==1 == XOR guarantee).
        let mut rng = SplitMix::new(0xA15D_0DE5);
        for k in 1..=8usize {
            for trial in 0..40 {
                let count = 1 + rng.range(3 * k); // span several groups
                let data: Vec<Vec<u8>> = (0..count)
                    .map(|_| {
                        let len = rng.range(40); // includes empty shards (len 0)
                        (0..len).map(|_| rng.byte()).collect()
                    })
                    .collect();
                let xor = XorParityFec::new(k);
                let rs = ReedSolomonFec::new(k, 1);
                let xor_par = xor.parity(&slices(&data), k);
                let rs_par = rs.parity(&slices(&data), k);
                assert_eq!(
                    rs_par, xor_par,
                    "RS m=1 parity bytes differ from XOR (k={k}, trial={trial})"
                );

                // Lose one shard per group; both schemes must recover to identical bytes.
                let mut xr: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
                let mut rr = xr.clone();
                for g in 0..count.div_ceil(k) {
                    let base = g * k;
                    let hi = (base + k).min(count);
                    let hole = base + rng.range(hi - base);
                    xr[hole] = None;
                    rr[hole] = None;
                }
                xor.recover(&mut xr, &opt(&xor_par), k);
                rs.recover(&mut rr, &opt(&rs_par), k);
                assert_eq!(xr, rr, "RS m=1 recovery differs from XOR (k={k})");
                assert_eq!(
                    rr.into_iter().map(Option::unwrap).collect::<Vec<_>>(),
                    data,
                    "RS m=1 did not recover original (k={k})"
                );
            }
        }
    }

    #[test]
    fn rs_parity_count_layout() {
        // ceil(count/k) groups × m parities, in group-major then rank order.
        let rs = ReedSolomonFec::new(4, 3);
        let data: Vec<Vec<u8>> = (0..10u8).map(|i| vec![i; 5]).collect();
        // ceil(10/4) = 3 groups × 3 parity = 9.
        assert_eq!(rs.parity(&slices(&data), 4).len(), 9);
        assert_eq!(rs.parity_count_per_group(), 3);
        assert_eq!(FecScheme::group_size(&rs), 4);
    }

    #[test]
    fn rs_exhaustive_erasure_recovery() {
        // For each (k,m), one full group of k shards (with mixed/empty sizes), enumerate
        // EVERY erasure pattern of size 0..=m and assert every lost data shard is recovered.
        let mut rng = SplitMix::new(0x5EED_F00D);
        for k in 1..=8usize {
            for m in 1..=4usize {
                if k + m > 12 {
                    continue;
                }
                // A varied shard-size profile incl. an empty shard and unequal lengths.
                let data: Vec<Vec<u8>> = (0..k)
                    .map(|i| {
                        let len = if i == 0 { 0 } else { 1 + rng.range(31) };
                        (0..len).map(|_| rng.byte()).collect()
                    })
                    .collect();
                let rs = ReedSolomonFec::new(k, m);
                let parity = rs.parity(&slices(&data), k);
                assert_eq!(parity.len(), m, "one group → m parities");

                for_each_subset_up_to(k, m, |erased| {
                    let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
                    for &e in erased {
                        recv[e] = None;
                    }
                    rs.recover(&mut recv, &opt(&parity), k);
                    for (i, original) in data.iter().enumerate() {
                        assert_eq!(
                            recv[i].as_ref(),
                            Some(original),
                            "k={k} m={m} erased={erased:?}: shard {i} not recovered byte-exact"
                        );
                    }
                });
            }
        }
    }

    #[test]
    fn rs_recovers_with_some_parity_also_lost() {
        // Lose 2 data shards AND one parity shard; remaining parity must still suffice when
        // holes <= surviving parity.
        let rs = ReedSolomonFec::new(5, 3);
        let data: Vec<Vec<u8>> = (0..5u8)
            .map(|i| vec![i, i.wrapping_mul(7), i ^ 0x5A])
            .collect();
        let parity = rs.parity(&slices(&data), 5);
        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[1] = None;
        recv[4] = None; // 2 data holes
        let mut parity_opt = opt(&parity);
        parity_opt[1] = None; // lose one of 3 parity shards (2 survive >= 2 holes)
        rs.recover(&mut recv, &parity_opt, 5);
        let recovered: Vec<Vec<u8>> = recv.into_iter().map(Option::unwrap).collect();
        assert_eq!(recovered, data);
    }

    #[test]
    fn rs_more_holes_than_parity_leaves_holes_no_panic() {
        let rs = ReedSolomonFec::new(6, 2);
        let data: Vec<Vec<u8>> = (0..6u8).map(|i| vec![i; 4]).collect();
        let parity = rs.parity(&slices(&data), 6);
        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[0] = None;
        recv[2] = None;
        recv[5] = None; // 3 holes > m=2 → unrecoverable, must stay None
        rs.recover(&mut recv, &opt(&parity), 6);
        assert!(recv[0].is_none() && recv[2].is_none() && recv[5].is_none());
        assert_eq!(recv[1], Some(vec![1; 4]), "untouched survivors intact");
    }

    #[test]
    fn rs_insufficient_surviving_parity_leaves_holes() {
        let rs = ReedSolomonFec::new(5, 3);
        let data: Vec<Vec<u8>> = (0..5u8).map(|i| vec![i; 3]).collect();
        let parity = rs.parity(&slices(&data), 5);
        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[0] = None;
        recv[1] = None; // 2 holes
        let mut parity_opt = opt(&parity);
        parity_opt[0] = None;
        parity_opt[1] = None; // only 1 parity survives, < 2 holes → cannot solve
        rs.recover(&mut recv, &parity_opt, 5);
        assert!(recv[0].is_none() && recv[1].is_none());
    }

    #[test]
    fn rs_all_parity_missing_leaves_holes() {
        let rs = ReedSolomonFec::new(4, 2);
        let data: Vec<Vec<u8>> = (0..4u8).map(|i| vec![i; 2]).collect();
        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[1] = None;
        rs.recover(&mut recv, &[None, None], 4);
        assert!(recv[1].is_none());
    }

    #[test]
    fn rs_empty_and_zero_width_groups_no_panic() {
        let rs = ReedSolomonFec::new(3, 2);
        // All-empty shards: framed width W = 4 (just the length prefix, value 0). Lose two,
        // recover both as empty vecs.
        let data: Vec<Vec<u8>> = vec![Vec::new(), Vec::new(), Vec::new()];
        let parity = rs.parity(&slices(&data), 3);
        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[0] = None;
        recv[2] = None;
        rs.recover(&mut recv, &opt(&parity), 3);
        assert_eq!(recv[0], Some(Vec::new()));
        assert_eq!(recv[2], Some(Vec::new()));

        // Truly empty data slice: no parity, no panic.
        let empty: Vec<&[u8]> = Vec::new();
        assert!(rs.parity(&empty, 3).is_empty());
        let mut none_data: Vec<Option<Vec<u8>>> = Vec::new();
        rs.recover(&mut none_data, &[], 3);
    }

    #[test]
    fn rs_corrupt_length_prefix_survivor_no_panic() {
        // A survivor data shard whose framed prefix decodes to an absurd length must not
        // panic; recovery either fails the strip (leaves hole) or produces a (clamped) value,
        // but never crashes — the hostile-input guarantee.
        let rs = ReedSolomonFec::new(3, 2);
        let data: Vec<Vec<u8>> = vec![vec![0xAA; 6], vec![0xBB; 2], vec![0xCC; 4]];
        let parity = rs.parity(&slices(&data), 3);
        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[0] = None; // hole
        // Corrupt a SURVIVING parity shard's bytes (simulate a flipped datagram).
        let mut parity_opt = opt(&parity);
        if let Some(Some(p)) = parity_opt.get_mut(0) {
            for b in p.iter_mut() {
                *b = b.wrapping_add(0x7F);
            }
        }
        rs.recover(&mut recv, &parity_opt, 3); // must not panic
        // Surviving real shards untouched.
        assert_eq!(recv[1], Some(vec![0xBB; 2]));
        assert_eq!(recv[2], Some(vec![0xCC; 4]));
    }

    #[test]
    fn rs_multi_group_mixed_recoverable_and_not() {
        // 11 shards, k=4 m=2 → groups [0..4][4..8][8..11(short)]. Holes:
        //   group 0: 2 holes (recoverable, == m)
        //   group 1: 3 holes (> m, unrecoverable)
        //   group 2: 1 hole in the short final group (recoverable)
        let rs = ReedSolomonFec::new(4, 2);
        let data: Vec<Vec<u8>> = (0..11u8).map(|i| vec![i, i.wrapping_add(100)]).collect();
        let parity = rs.parity(&slices(&data), 4);
        // 3 groups × 2 = 6 parity shards.
        assert_eq!(parity.len(), 6);

        let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();
        recv[0] = None;
        recv[2] = None; // group 0: 2 holes
        recv[4] = None;
        recv[5] = None;
        recv[6] = None; // group 1: 3 holes (> m)
        recv[9] = None; // group 2 (short): 1 hole
        rs.recover(&mut recv, &opt(&parity), 4);

        // Group 0 recovered.
        assert_eq!(recv[0], Some(data[0].clone()));
        assert_eq!(recv[2], Some(data[2].clone()));
        // Group 1 unrecoverable — holes remain.
        assert!(recv[4].is_none() && recv[5].is_none() && recv[6].is_none());
        // Group 2 short-group hole recovered.
        assert_eq!(recv[9], Some(data[9].clone()));
    }

    #[test]
    fn rs_fuzz_random_patterns_multi_group() {
        // Broad randomised soak: random k/m, random shard sizes across many groups, random
        // erasure patterns. Whenever a group's holes <= surviving parity, every hole recovers.
        let mut rng = SplitMix::new(0xDEAD_BEEF_CAFE);
        for _ in 0..400 {
            let k = 1 + rng.range(8); // 1..=8
            let m = 1 + rng.range(4); // 1..=4
            let count = 1 + rng.range(5 * k); // up to ~5 groups
            let data: Vec<Vec<u8>> = (0..count)
                .map(|_| {
                    let len = rng.range(48);
                    (0..len).map(|_| rng.byte()).collect()
                })
                .collect();
            let rs = ReedSolomonFec::new(k, m);
            let parity = rs.parity(&slices(&data), k);
            let mut parity_opt = opt(&parity);
            let mut recv: Vec<Option<Vec<u8>>> = data.iter().cloned().map(Some).collect();

            // Per group, erase a random number (0..=m+1) of DATA shards and 0..=m parity shards.
            let groups = count.div_ceil(k);
            let mut expected_recoverable: Vec<(usize, Vec<u8>)> = Vec::new();
            for g in 0..groups {
                let base = g * k;
                let hi = (base + k).min(count);
                let glen = hi - base;
                // erase data
                let mut data_holes: Vec<usize> = Vec::new();
                let want_holes = rng.range(m + 2); // 0..=m+1 (sometimes too many)
                let mut pool: Vec<usize> = (base..hi).collect();
                for _ in 0..want_holes.min(glen) {
                    if pool.is_empty() {
                        break;
                    }
                    let idx = rng.range(pool.len());
                    let h = pool.swap_remove(idx);
                    recv[h] = None;
                    data_holes.push(h);
                }
                // erase parity
                let mut surviving_parity = m;
                for r in 0..m {
                    if rng.range(3) == 0 {
                        parity_opt[g * m + r] = None;
                        surviving_parity -= 1;
                    }
                }
                if !data_holes.is_empty() && data_holes.len() <= surviving_parity {
                    for &h in &data_holes {
                        expected_recoverable.push((h, data[h].clone()));
                    }
                }
            }

            rs.recover(&mut recv, &parity_opt, k);

            for (h, original) in expected_recoverable {
                assert_eq!(
                    recv[h].as_ref(),
                    Some(&original),
                    "k={k} m={m}: recoverable hole {h} was not restored"
                );
            }
        }
    }

    #[test]
    fn rs_with_backend_matches_new() {
        // The generic backend ctor produces the identical scheme as `new` for ScalarGf.
        let a = ReedSolomonFec::new(4, 2);
        let b = ReedSolomonFec::with_backend(4, 2, crate::gf256::ScalarGf);
        assert_eq!(a, b);
    }

    #[test]
    #[should_panic(expected = "k + m must be <= 255")]
    fn rs_rejects_oversized_field() {
        let _ = ReedSolomonFec::new(200, 56); // 256 > 255
    }

    #[test]
    #[should_panic(expected = "m (parity count) must be >= 1")]
    fn rs_rejects_zero_parity() {
        let _ = ReedSolomonFec::new(4, 0);
    }
}
