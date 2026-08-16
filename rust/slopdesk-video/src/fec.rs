//! Forward-error-correction over a frame's data fragments — a systematic Reed-Solomon erasure code
//! over GF(2^8).
//!
//! doc 17 §3.6 calls for ~20% parity per frame (the Sunshine default). Each group of `k` data
//! fragments produces `m` parity fragments and recovers up to `m` losses per group;
//! `k = 5, m = 1` is the shipped operating point.
//!
//! ## Parity layout
//!
//! [`ReedSolomonFec::parity`] returns `group_count * m` parity fragments in **group-major, then
//! parity-rank** order: group 0's ranks `0..m`, then group 1's, and so on.
//! [`ReedSolomonFec::recover`] indexes the parity slice as `parity[group * m + rank]`. At `m == 1`
//! this collapses to one parity per group at `parity[group]` — the v1 wire layout.
//!
//! ## `m == 1` is byte-identical to plain XOR, and that is a wire contract
//!
//! A Cauchy parity row is *not* all-ones, so a literal RS encode at `m == 1` would emit different
//! parity BYTES than a plain XOR even though recovery would still be correct. The wire contract
//! guarantees `m == 1` matches the v1 XOR format exactly — a mixed fleet depends on it, and
//! `golden/golden_vectors.json` pins it — so the codec special-cases `m == 1` to plain XOR
//! internally. `tests/golden_vectors.rs` is what holds that, against bytes generated before this
//! port existed.
//!
//! ## Framing
//!
//! Every shard enters the code as `[u32 BE len][bytes]`, zero-padded to the group's widest member,
//! so recovery reproduces the *exact* original length even when group members differ in size. The
//! linear code is over those padded encodings, never over the raw fragments.
//!
//! ## Hostile input
//!
//! `recover` is fed whatever arrived on a UDP socket. It never panics: a group beyond its repair
//! budget, a missing parity shard, a singular submatrix or a corrupt length prefix all leave the
//! hole exactly as it was, and the caller escalates to a recovery request.

use crate::bytes::truncating_u32;
use crate::{gf256, rs_matrix};

/// Systematic Reed-Solomon erasure code over GF(2^8) — the production FEC scheme.
///
/// Value type, immutable after construction, `Copy`; safe to share across threads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReedSolomonFec {
    /// Data shards per group (the code's `k`).
    group_size: usize,
    /// Parity shards per group (the code's `m`).
    parity: usize,
}

impl Default for ReedSolomonFec {
    /// `k = 5, m = 1` ⇒ 20% parity, wire-identical to the v1 XOR format (the doc-17 default).
    fn default() -> Self {
        Self {
            group_size: 5,
            parity: 1,
        }
    }
}

impl ReedSolomonFec {
    /// Builds an `[n = k + m, k]` Reed-Solomon codec.
    ///
    /// # Panics
    /// Panics if `k < 1`, `m < 1`, or `k + m > 255` (the Cauchy index sets must fit GF(2^8)). These
    /// are construction-time configuration errors, not input: the per-call `group_size` passed to
    /// [`parity`](Self::parity) / [`recover`](Self::recover) is floored to 1 defensively and never
    /// panics.
    #[must_use]
    pub const fn new(k: usize, m: usize) -> Self {
        assert!(k >= 1, "k (group_size) must be >= 1");
        assert!(m >= 1, "m (parity count) must be >= 1");
        assert!(k + m <= 255, "k + m must be <= 255 to fit GF(2^8)");
        Self {
            group_size: k,
            parity: m,
        }
    }

    /// The DEFAULT group size (`k`): how many data fragments share a group's parity when no
    /// explicit per-frame group size is supplied.
    #[must_use]
    pub const fn group_size(&self) -> usize {
        self.group_size
    }

    /// Parity shards per group (the code's `m`): how many losses per group the scheme repairs.
    #[must_use]
    pub const fn parity_count(&self) -> usize {
        self.parity
    }

    /// Parity for `data`, grouping by `group_size`, at the codec's configured `m`.
    #[must_use]
    pub fn parity(&self, data: &[&[u8]], group_size: usize) -> Vec<Vec<u8>> {
        self.parity_m(data, group_size, self.parity)
    }

    /// Parity at an explicit per-frame multiplicity `m`, overriding the codec's configured one.
    ///
    /// This is the adaptive-FEC path: the host picks `m` per frame from the measured loss and
    /// signals it through the wire FEC tier, with no wire-format change.
    #[must_use]
    pub fn parity_with_m(&self, data: &[&[u8]], group_size: usize, m: usize) -> Vec<Vec<u8>> {
        self.parity_m(data, group_size, m.max(1))
    }

    /// Fills recoverable holes (`None`) in `data` in place from `parity`, grouping by `group_size`
    /// at the codec's configured `m`. Entries that cannot be recovered stay `None`.
    pub fn recover(&self, data: &mut [Option<Vec<u8>>], parity: &[Option<Vec<u8>>], group_size: usize) {
        self.recover_m(data, parity, group_size, self.parity);
    }

    /// Recover at an explicit per-frame multiplicity `m` — the counterpart of
    /// [`parity_with_m`](Self::parity_with_m).
    ///
    /// The `m` MUST be the one the parity was encoded with: it sets both the per-group parity
    /// stride (`parity[group * m + rank]`) and the recovery budget.
    pub fn recover_with_m(
        &self,
        data: &mut [Option<Vec<u8>>],
        parity: &[Option<Vec<u8>>],
        group_size: usize,
        m: usize,
    ) {
        self.recover_m(data, parity, group_size, m.max(1));
    }

    // ---------------------------------------------------------------------- //
    // Effective grouping width

    /// The per-call grouping width for a requested `group_size` at parity multiplicity `m`.
    ///
    /// `m == 1` (plain XOR, no matrix) honours the request EXACTLY — NO clamp to `k` — so the
    /// parity bytes stay byte-identical to the standalone length-prefixed XOR for ANY group
    /// size (the production path drives an adaptive per-frame group size that can exceed the
    /// codec's `k`). `m >= 2` (the Cauchy code) clamps down to `k`, its column count, because
    /// the encoder has exactly `k` columns and a wider group could not be decoded. A
    /// non-positive size floors to 1 either way (a 0 size must never loop forever).
    #[inline]
    const fn effective_group_size(&self, requested: usize, m: usize) -> usize {
        let floored = if requested < 1 { 1 } else { requested };
        // `usize::MAX` spells "no ceiling" for the XOR path, so the clamp below is one expression
        // rather than two arms that differ only in whether they clamp at all.
        let ceiling = if m == 1 { usize::MAX } else { self.group_size };
        if floored < ceiling { floored } else { ceiling }
    }

    // ---------------------------------------------------------------------- //
    // Parity (encode)

    /// Parity at multiplicity `m`. Groups `data` at
    /// [`effective_group_size`](Self::effective_group_size) and emits each group's `m` parity
    /// shards in rank order (group-major, then rank).
    fn parity_m(&self, data: &[&[u8]], requested: usize, m: usize) -> Vec<Vec<u8>> {
        let group_size = self.effective_group_size(requested, m);
        let mut parities = Vec::new();
        if !data.is_empty() {
            // `m` shards per full group + a tail group ⇒ exact-ish reservation, no growth churn.
            parities.reserve(data.len().div_ceil(group_size) * m);
        }
        if m == 1 {
            parities.extend(data.chunks(group_size).map(xor_encoded));
            return parities;
        }
        // The parity coefficients — and so their multiplication tables — are the SAME for every
        // group in the frame, because the Cauchy block depends only on `(k, m)`. Building them here
        // rather than inside the group loop turns 255 table lookups per coefficient per GROUP into
        // 255 per coefficient per FRAME: on a 170-fragment IDR at `k = 5, m = 3` that is 15 tables
        // built instead of 510.
        let coeffs = rs_matrix::parity_rows(self.group_size, m);
        let tables: Vec<gf256::MulTable> = coeffs.iter().map(|&coeff| gf256::MulTable::new(coeff)).collect();
        for group in data.chunks(group_size) {
            self.encode_group(group, m, &tables, &mut parities);
        }
        parities
    }

    /// Encodes one group's `m` parity shards, appended in rank order.
    ///
    /// Frames each up-to-`k` data shard (length-prefixed) ONCE into a reusable buffer, zero-pads to
    /// the group's widest member `W`, then for each parity row folds `coeff * framed_shard` into a
    /// single reused `W`-wide accumulator (zeroed between ranks, so no stale byte leaks — the
    /// result is bit-identical to a fresh per-rank buffer).
    ///
    /// `tables` is the frame's `m × k` coefficient tables, row-major, from
    /// [`parity_m`](Self::parity_m).
    fn encode_group(&self, group: &[&[u8]], m: usize, tables: &[gf256::MulTable], out: &mut Vec<Vec<u8>>) {
        let framed: Vec<Vec<u8>> = group.iter().map(|shard| length_prefixed(shard)).collect();
        let width = framed.iter().map(Vec::len).max().unwrap_or(0);
        let mut acc = vec![0_u8; width];
        for rank in 0..m {
            acc.fill(0);
            for (j, shard) in framed.iter().enumerate() {
                // The table for parity `rank` over data shard `j`. A short final group holds fewer
                // than k shards; only the present ones contribute.
                if let Some(table) = tables.get(rank * self.group_size + j) {
                    table.add_scaled(shard, &mut acc);
                }
            }
            out.push(acc.clone());
        }
    }

    // ---------------------------------------------------------------------- //
    // Recover (decode)

    /// Recover at multiplicity `m`, walking the same grouping [`parity_m`](Self::parity_m) used.
    fn recover_m(
        &self,
        data: &mut [Option<Vec<u8>>],
        parity: &[Option<Vec<u8>>],
        requested: usize,
        m: usize,
    ) {
        let group_size = self.effective_group_size(requested, m);
        let mut group_index = 0;
        let mut index = 0;
        while index < data.len() {
            let upper = (index + group_size).min(data.len());
            self.recover_group(data, parity, index, upper, group_index, m);
            index += group_size;
            group_index += 1;
        }
    }

    /// Recovers a single group's holes in place (indices `index..upper` of `data`), using the
    /// group's `m` parity shards at `parity[group_index * m .. group_index * m + m]`.
    ///
    /// Leaves every hole untouched when unrecoverable (no holes, more holes than `m`, too few
    /// surviving parity, a singular submatrix, or a corrupt length prefix) — never panics.
    fn recover_group(
        &self,
        data: &mut [Option<Vec<u8>>],
        parity: &[Option<Vec<u8>>],
        index: usize,
        upper: usize,
        group_index: usize,
        m: usize,
    ) {
        let k = self.group_size;
        let group_len = upper - index;

        // Holes are missing DATA shards; their position within the group is `i - index`.
        let holes: Vec<usize> = (index..upper)
            .filter(|&i| data.get(i).is_some_and(Option::is_none))
            .collect();
        if holes.is_empty() || holes.len() > m {
            return; // nothing to do, or beyond this group's repair budget
        }

        // m == 1: a single hole, plain XOR recover — byte-identical to the legacy XOR.
        if m == 1 {
            if let Some(Some(parity_bytes)) = parity.get(group_index) {
                let survivors: Vec<&[u8]> = (index..upper).filter_map(|i| data.get(i)?.as_deref()).collect();
                if let Some(bytes) = strip_length_prefix(&xor_recover(parity_bytes, &survivors))
                    && let Some(hole) = holes.first().and_then(|&h| data.get_mut(h))
                {
                    *hole = Some(bytes);
                }
            }
            return;
        }

        let parity_coeffs = rs_matrix::parity_rows(k, m);

        // Collect k survivor (encoder-row, framed-bytes) pairs. Encoder indices: 0..k are the data
        // rows (identity), k..k+m are the parity rows. Any k linearly independent survivors suffice,
        // and every k-subset of an MDS encoder is independent.
        let mut survivor_rows: Vec<Vec<u8>> = Vec::with_capacity(k);
        let mut survivor_bytes: Vec<Vec<u8>> = Vec::with_capacity(k);

        // 1) Present real data shards contribute their identity row e_j and framed bytes.
        for slot in 0..group_len {
            if let Some(bytes) = data.get(index + slot).and_then(Option::as_deref) {
                survivor_rows.push(unit_row(k, slot));
                survivor_bytes.push(length_prefixed(bytes));
            }
        }
        // 2) The encoder treats a short final group (group_len < k) as having (k - group_len) implicit
        //    all-zero data shards in slots group_len..k. Those phantom shards are never missing (they are
        //    the constant 0), so they always count as survivors — which is what lets a short group still
        //    reach k independent rows.
        for slot in group_len..k {
            survivor_rows.push(unit_row(k, slot));
            survivor_bytes.push(Vec::new()); // all-zero contributes nothing
        }
        // 3) Fill the remaining slots from present parity shards (their Cauchy rows).
        let parity_base = group_index * m;
        let mut rank = 0;
        while survivor_rows.len() < k && rank < m {
            if let Some(Some(parity_bytes)) = parity.get(parity_base + rank)
                && let Some(row) = parity_coeffs.get(rank * k..rank * k + k)
            {
                survivor_rows.push(row.to_vec());
                survivor_bytes.push(parity_bytes.clone());
            }
            rank += 1;
        }

        if survivor_rows.len() < k {
            return; // not enough surviving shards to solve — leave the holes
        }
        // Use exactly k survivors (data + phantom may already have reached k).
        survivor_rows.truncate(k);
        survivor_bytes.truncate(k);

        // Invert the k×k encoder submatrix of the chosen survivors.
        let Some(inverse) = rs_matrix::invert_subset(&survivor_rows, k) else {
            return; // singular (should not happen for a true MDS subset) — leave the holes
        };

        // Width of the working accumulator: the widest survivor's framed length.
        let width = survivor_bytes.iter().map(Vec::len).max().unwrap_or(0);

        // For each missing DATA slot, the original framed shard is row `slot` of
        // (inverse · survivor_bytes): acc = Σ_t inverse[slot * k + t] * survivor_bytes[t]. One
        // accumulator reused across holes, zeroed per hole so no stale bytes leak.
        let mut acc = vec![0_u8; width];
        for &hole in &holes {
            let slot = hole - index; // 0..k position of the missing data shard
            acc.fill(0);
            for (t, sbytes) in survivor_bytes.iter().enumerate() {
                let coeff = inverse.get(slot * k + t).copied().unwrap_or(0);
                gf256::mul_add(coeff, sbytes, &mut acc);
            }
            if let Some(bytes) = strip_length_prefix(&acc)
                && let Some(cell) = data.get_mut(hole)
            {
                *cell = Some(bytes);
            }
        }
    }
}

/// The `k`-wide unit row `e_slot` — the encoder row of a data shard that survived.
fn unit_row(k: usize, slot: usize) -> Vec<u8> {
    let mut row = vec![0_u8; k];
    if let Some(cell) = row.get_mut(slot) {
        *cell = 1;
    }
    row
}

/// XOR of the length-prefixed encodings of a group, zero-padded to the longest member.
///
/// The inner accumulate is `iter_mut().zip(member)` rather than an indexed loop: every member is no
/// longer than the accumulator (which is sized to the widest), so the zip is complete AND free of
/// per-iteration bounds checks, which is what lets LLVM autovectorise it.
fn xor_encoded(group: &[&[u8]]) -> Vec<u8> {
    // Width = the widest length-prefixed member = 4 + the longest member's byte count.
    let width = group.iter().map(|m| PREFIX_BYTES + m.len()).max().unwrap_or(0);
    let mut acc = Vec::with_capacity(width);
    let Some((first, rest)) = group.split_first() else {
        return acc;
    };
    // SEEDED with the first member rather than zeroed and then XORed with it. `0 ^ x == x`, so the
    // bytes are identical; what goes away is a full-width zero-fill plus one of the k read-modify-
    // write passes over the accumulator, on the one function every encoded frame walks.
    acc.extend_from_slice(&truncating_u32(first.len()).to_be_bytes());
    acc.extend_from_slice(first);
    acc.resize(width, 0);
    for member in rest {
        xor_length_prefixed(member, &mut acc);
    }
    acc
}

/// `parity XOR (encoded survivors)` = the encoded form of the single missing member, zero-padded.
/// Trailing zeros past the embedded length are harmless: [`strip_length_prefix`] cuts to the
/// declared length.
fn xor_recover(parity: &[u8], survivors: &[&[u8]]) -> Vec<u8> {
    let widest_survivor = survivors
        .iter()
        .map(|m| PREFIX_BYTES + m.len())
        .max()
        .unwrap_or(0);
    // Seeded with the parity shard for the same reason [`xor_encoded`] seeds with its first
    // member: `0 ^ x == x`, so this is one memcpy instead of a zero-fill and a first XOR pass.
    let width = parity.len().max(widest_survivor);
    let mut acc = Vec::with_capacity(width);
    acc.extend_from_slice(parity);
    acc.resize(width, 0);
    for member in survivors {
        xor_length_prefixed(member, &mut acc);
    }
    acc
}

/// `acc[0..4 + member.len()] ^= length_prefixed(member)`, WITHOUT materialising the framed copy.
/// `acc` is always at least `4 + member.len()` wide (it is sized to the widest member), so the
/// whole framing lands inside it.
fn xor_length_prefixed(member: &[u8], acc: &mut [u8]) {
    let length = truncating_u32(member.len()).to_be_bytes();
    gf256::xor_add(&length, acc);
    if let Some(body) = acc.get_mut(PREFIX_BYTES..) {
        gf256::xor_add(member, body);
    }
}

/// The `[u32 BE len]` header every shard carries into the code.
const PREFIX_BYTES: usize = 4;

/// `[u32 BE len][bytes]`. A fragment never approaches 4 GiB (it is MTU-bounded), so the `u32` holds
/// by construction. Both the XOR and the Cauchy path operate over this framed, zero-padded encoding
/// so recovery reproduces the *exact* original length even when group members differ in size.
fn length_prefixed(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(PREFIX_BYTES + data.len());
    out.extend_from_slice(&truncating_u32(data.len()).to_be_bytes());
    out.extend_from_slice(data);
    out
}

/// Inverse of [`length_prefixed`]: reads the embedded length and slices exactly that many bytes,
/// ignoring trailing zero padding. `None` if the declared length does not fit — a corrupt prefix on
/// hostile input, where recovery leaves the hole rather than crashing. VALIDATE before allocating:
/// the bounds are checked before the slice copy.
fn strip_length_prefix(data: &[u8]) -> Option<Vec<u8>> {
    let header: [u8; PREFIX_BYTES] = data.get(..PREFIX_BYTES)?.try_into().ok()?;
    let length = usize::try_from(u32::from_be_bytes(header)).ok()?;
    let end = PREFIX_BYTES.checked_add(length)?;
    Some(data.get(PREFIX_BYTES..end)?.to_vec())
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{ReedSolomonFec, length_prefixed, strip_length_prefix};

    /// An INDEPENDENT plain-XOR parity, written from the wire format rather than from the codec, so
    /// "m == 1 is byte-identical to the v1 XOR" is checked against something that shares no code
    /// with the thing it is checking.
    fn naive_xor_parity(group: &[&[u8]], group_size: usize) -> Vec<Vec<u8>> {
        group
            .chunks(group_size)
            .map(|chunk| {
                let width = chunk.iter().map(|m| 4 + m.len()).max().unwrap_or(0);
                let mut acc = vec![0_u8; width];
                for member in chunk {
                    let framed = length_prefixed(member);
                    for (a, b) in acc.iter_mut().zip(framed.iter()) {
                        *a ^= *b;
                    }
                }
                acc
            })
            .collect()
    }

    fn owned(fragments: &[&[u8]]) -> Vec<Option<Vec<u8>>> {
        fragments.iter().map(|f| Some(f.to_vec())).collect()
    }

    #[test]
    fn m1_parity_is_the_plain_xor_for_every_group_size() {
        let data: Vec<Vec<u8>> = (0..11_u8).map(|i| vec![i; usize::from(i) + 1]).collect();
        let refs: Vec<&[u8]> = data.iter().map(Vec::as_slice).collect();
        for group_size in 1..=13 {
            let codec = ReedSolomonFec::new(5, 1);
            assert_eq!(
                codec.parity(&refs, group_size),
                naive_xor_parity(&refs, group_size),
                "m == 1 must be plain XOR at group size {group_size}, even past k"
            );
        }
    }

    #[test]
    fn m1_recovers_a_single_hole_and_leaves_two() {
        let data: Vec<&[u8]> = vec![&[1, 2], &[3], &[4, 5, 6], &[7], &[8, 9]];
        let codec = ReedSolomonFec::new(5, 1);
        let parity: Vec<Option<Vec<u8>>> = codec.parity(&data, 5).into_iter().map(Some).collect();

        let mut one = owned(&data);
        one[2] = None;
        codec.recover(&mut one, &parity, 5);
        assert_eq!(
            one[2].as_deref(),
            Some(data[2]),
            "one hole per group is repairable"
        );

        let mut two = owned(&data);
        two[0] = None;
        two[1] = None;
        codec.recover(&mut two, &parity, 5);
        assert!(
            two[0].is_none() && two[1].is_none(),
            "two holes exceed m == 1's budget"
        );
    }

    #[test]
    fn a_missing_parity_shard_leaves_the_hole() {
        let data: Vec<&[u8]> = vec![&[1, 2], &[3], &[4, 5, 6]];
        let codec = ReedSolomonFec::new(5, 1);
        let mut holed = owned(&data);
        holed[1] = None;
        codec.recover(&mut holed, &[None], 5);
        assert!(holed[1].is_none(), "no parity, no repair — and no crash");
    }

    #[test]
    fn multi_loss_recovers_up_to_m_per_group() {
        let data: Vec<Vec<u8>> = (0..8_u8)
            .map(|i| vec![i.wrapping_mul(17); usize::from(i) + 3])
            .collect();
        let refs: Vec<&[u8]> = data.iter().map(Vec::as_slice).collect();
        let codec = ReedSolomonFec::new(4, 3);
        let parity: Vec<Option<Vec<u8>>> = codec.parity(&refs, 4).into_iter().map(Some).collect();
        assert_eq!(parity.len(), 6, "two groups of four, three parity shards each");

        // Every 3-subset of the first group is recoverable.
        for a in 0..4 {
            for b in (a + 1)..4 {
                for c in (b + 1)..4 {
                    let mut holed = owned(&refs);
                    holed[a] = None;
                    holed[b] = None;
                    holed[c] = None;
                    codec.recover(&mut holed, &parity, 4);
                    for slot in [a, b, c] {
                        assert_eq!(
                            holed[slot].as_deref(),
                            Some(refs[slot]),
                            "loss pattern ({a},{b},{c}) must repair slot {slot}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn multi_loss_stops_at_the_budget() {
        let data: Vec<&[u8]> = vec![&[1, 1], &[2, 2], &[3, 3], &[4, 4]];
        let codec = ReedSolomonFec::new(4, 2);
        let parity: Vec<Option<Vec<u8>>> = codec.parity(&data, 4).into_iter().map(Some).collect();
        let mut holed = owned(&data);
        holed[0] = None;
        holed[1] = None;
        holed[2] = None;
        codec.recover(&mut holed, &parity, 4);
        assert!(
            holed[0].is_none() && holed[1].is_none() && holed[2].is_none(),
            "three losses exceed m == 2 — all three stay holes, none is half-written"
        );
    }

    #[test]
    fn a_short_final_group_recovers_through_its_phantom_shards() {
        // Six fragments at k = 4: the second group holds two real shards and two implicit zeros.
        let data: Vec<&[u8]> = vec![&[1], &[2, 2], &[3, 3, 3], &[4], &[5, 5], &[6]];
        let codec = ReedSolomonFec::new(4, 2);
        let parity: Vec<Option<Vec<u8>>> = codec.parity(&data, 4).into_iter().map(Some).collect();
        let mut holed = owned(&data);
        holed[4] = None;
        holed[5] = None;
        codec.recover(&mut holed, &parity, 4);
        assert_eq!(holed[4].as_deref(), Some(data[4]));
        assert_eq!(holed[5].as_deref(), Some(data[5]));
    }

    #[test]
    fn m_over_two_clamps_the_group_to_k_but_m_one_does_not() {
        let data: Vec<Vec<u8>> = (0..9_u8).map(|i| vec![i; 3]).collect();
        let refs: Vec<&[u8]> = data.iter().map(Vec::as_slice).collect();
        // k = 3, m = 2: a requested group of 9 clamps to 3, so three groups × two shards.
        assert_eq!(ReedSolomonFec::new(3, 2).parity(&refs, 9).len(), 6);
        // k = 3, m = 1: the request is honoured exactly, so one group and one shard.
        assert_eq!(ReedSolomonFec::new(3, 1).parity(&refs, 9).len(), 1);
    }

    #[test]
    fn a_zero_group_size_floors_to_one_rather_than_looping() {
        let data: Vec<&[u8]> = vec![&[1], &[2]];
        let codec = ReedSolomonFec::new(5, 1);
        assert_eq!(
            codec.parity(&data, 0).len(),
            2,
            "a 0 size groups one fragment at a time"
        );
    }

    #[test]
    fn a_corrupt_length_prefix_leaves_the_hole() {
        assert!(strip_length_prefix(&[0, 0]).is_none(), "shorter than the prefix");
        assert!(
            strip_length_prefix(&[0xFF, 0xFF, 0xFF, 0xFF, 1, 2]).is_none(),
            "length past the end"
        );
        assert_eq!(
            strip_length_prefix(&[0, 0, 0, 2, 1, 2, 0, 0]).unwrap(),
            vec![1, 2],
            "pad ignored"
        );
    }

    #[test]
    fn an_empty_frame_produces_no_parity() {
        let codec = ReedSolomonFec::new(5, 1);
        assert!(codec.parity(&[], 5).is_empty());
        assert!(codec.parity_with_m(&[], 5, 3).is_empty());
    }

    #[test]
    fn a_zero_length_fragment_round_trips_as_a_zero_length_fragment() {
        // The framing is what makes this work: an empty shard is `00000000`, not "absent".
        let data: Vec<&[u8]> = vec![&[], &[7, 7], &[]];
        let codec = ReedSolomonFec::new(3, 1);
        let parity: Vec<Option<Vec<u8>>> = codec.parity(&data, 3).into_iter().map(Some).collect();
        let mut holed = owned(&data);
        holed[0] = None;
        codec.recover(&mut holed, &parity, 3);
        assert_eq!(
            holed[0].as_deref(),
            Some(&[][..]),
            "recovered as empty, not as None"
        );
    }

    #[test]
    fn the_configured_m_and_the_per_frame_m_agree_when_they_are_the_same() {
        let data: Vec<&[u8]> = vec![&[1, 2, 3], &[4], &[5, 6], &[7, 8, 9, 10]];
        let codec = ReedSolomonFec::new(4, 2);
        assert_eq!(codec.parity(&data, 4), codec.parity_with_m(&data, 4, 2));
    }

    #[test]
    fn recovery_is_a_no_op_when_nothing_is_missing() {
        let data: Vec<&[u8]> = vec![&[1, 2], &[3, 4], &[5, 6]];
        let codec = ReedSolomonFec::new(3, 2);
        let parity: Vec<Option<Vec<u8>>> = codec.parity(&data, 3).into_iter().map(Some).collect();
        let mut intact = owned(&data);
        codec.recover(&mut intact, &parity, 3);
        assert_eq!(intact, owned(&data));
    }
}
