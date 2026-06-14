//! Burst-resilient transmission-order interleaver — a port of Swift
//! `FragmentInterleaver`.
//!
//! [`XorParityFec`](crate::fec::XorParityFec) recovers exactly one lost fragment per
//! group of `group_size` CONSECUTIVE data fragments. Sending fragments in that same
//! consecutive order means a 2-adjacent-datagram burst lands two losses in one group →
//! unrecoverable → visible flicker. This reorders TRANSMISSION (not the fragments'
//! `frag_index`, which are untouched) into column-major "one-per-group" order so
//! consecutive datagrams belong to DIFFERENT FEC groups; a burst of up to `num_groups`
//! adjacent losses then spreads across distinct groups, each recoverable.
//!
//! Host-only, NO wire change: the client reassembler keys by header fields and is
//! reorder-tolerant by design, so it reconstructs identically regardless of send order.

use crate::fragment::{Flags, FrameFragment};

/// Returns `fragments` reordered for burst-resilient transmission: data fragments
/// emitted column-major across FEC groups, then parity (each its own group).
///
/// A no-op
/// (returns the input unchanged, original order) when `group_size <= 1`, there is ≤1
/// group, or there are no more fragments than one group. The result is a permutation of
/// the input — same set of fragments, every `frag_index` preserved.
#[must_use]
pub fn interleave(fragments: Vec<FrameFragment>, group_size: usize) -> Vec<FrameFragment> {
    if group_size <= 1 || fragments.len() <= group_size {
        return fragments;
    }
    // Single data group → no interleave benefit (any 2 losses in it are unrecoverable
    // regardless). Count without consuming so the fallback preserves the original order.
    let data_count = fragments
        .iter()
        .filter(|f| !f.header.flags.contains(Flags::PARITY))
        .count();
    if data_count <= group_size {
        return fragments;
    }

    let mut data: Vec<Option<FrameFragment>> = Vec::with_capacity(data_count);
    let mut parity: Vec<FrameFragment> = Vec::new();
    for f in fragments {
        if f.header.flags.contains(Flags::PARITY) {
            parity.push(f);
        } else {
            data.push(Some(f));
        }
    }

    let num_groups = data_count.div_ceil(group_size);
    let mut ordered: Vec<FrameFragment> = Vec::with_capacity(data_count + parity.len());
    // Column-major: rank 0 of every group, then rank 1 of every group, … Consecutive
    // emissions are thus from distinct groups. Each (rank, group) index is visited
    // exactly once across the whole loop, so `take` never sees an already-moved slot.
    for rank in 0..group_size {
        for group in 0..num_groups {
            let idx = group * group_size + rank;
            if idx < data.len() {
                if let Some(fragment) = data[idx].take() {
                    ordered.push(fragment);
                }
            }
        }
    }
    ordered.extend(parity); // parity LAST; each parity is its own group → burst-safe
    ordered
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fec::XorParityFec;
    use crate::fragment::{FrameFragmentHeader, VideoPacketizer};

    fn fids(frags: &[FrameFragment]) -> Vec<u16> {
        frags.iter().map(|f| f.header.frag_index).collect()
    }

    #[test]
    fn small_frame_is_unchanged() {
        let mut p = VideoPacketizer::new(None);
        let frags = p.packetize(&[1, 2, 3], crate::fragment::PacketizeOptions::default());
        let before = fids(&frags);
        let after = interleave(frags, 5);
        assert_eq!(fids(&after), before);
    }

    #[test]
    fn group_size_one_is_noop() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![0u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 4];
        let frags = p.packetize(&frame, crate::fragment::PacketizeOptions::default());
        let before = fids(&frags);
        let after = interleave(frags, 1);
        assert_eq!(fids(&after), before);
    }

    #[test]
    fn column_major_spreads_groups_and_preserves_set() {
        // 7 data fragments, group size 3 → groups [0,1,2][3,4,5][6]. num_groups=3.
        // Column-major: rank0: 0,3,6 ; rank1: 1,4 ; rank2: 2,5 → [0,3,6,1,4,2,5].
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(3))));
        let frame = vec![9u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 7];
        let frags = p.packetize(&frame, crate::fragment::PacketizeOptions::default());
        let data_count = frags
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .count();
        assert_eq!(data_count, 7);
        let before: std::collections::BTreeSet<u16> = fids(&frags).into_iter().collect();

        let after = interleave(frags, 3);
        let after_data: Vec<u16> = after
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .map(|f| f.header.frag_index)
            .collect();
        assert_eq!(after_data, vec![0, 3, 6, 1, 4, 2, 5]);
        // parity stays last
        assert!(after
            .iter()
            .skip(7)
            .all(|f| f.header.flags.contains(Flags::PARITY)));
        // permutation: same set of frag_index values
        let after_set: std::collections::BTreeSet<u16> =
            after.iter().map(|f| f.header.frag_index).collect();
        assert_eq!(after_set, before);
        let _ = FrameFragmentHeader::SIZE;
    }
}
