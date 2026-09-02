//! Burst-resilient transmission order — the deleted `SlopDeskVideoProtocol.FragmentInterleaver`.
//!
//! ## Why
//!
//! Single-parity FEC recovers exactly ONE lost fragment per group of `group_size` CONSECUTIVE data
//! fragments. Sending fragments in that same consecutive order means a burst that drops just TWO
//! ADJACENT datagrams lands both losses in the SAME group — unrecoverable, so a partial decode that
//! the next frame only half-fixes, which reads as FLICKER on a fast scroll. It bites hardest at
//! high bitrate and `HiDPI`, where each frame fragments into many more pieces and adjacent-loss
//! odds rise with them.
//!
//! ## What
//!
//! Reorder TRANSMISSION — not `frag_index`, which is untouched — into column-major "one per group"
//! order, so consecutive datagrams on the wire belong to DIFFERENT FEC groups. A burst of up to
//! `num_groups` adjacent losses then spreads across distinct groups, each losing at most one, all
//! recoverable. The data section still precedes the parity section: a lossless client decodes
//! without waiting for parity, and parity still arrives LAST, which is what the reassembler's
//! reorder grace is built around.
//!
//! HOST-ONLY, NO WIRE CHANGE. The client keys data by `frag_index` and parity by
//! `frag_index - data_count`, both purely header-derived and reorder-tolerant by design — UDP
//! already reorders — so the receiver reconstructs identically whatever order the sender chose.
//!
//! ## m-awareness
//!
//! For `m` parity shards per group the FEC emits parity group-major-then-rank
//! (`[g0p0, g0p1, …, g1p0, …]`). Both sections walk column-major — rank outer, group inner — so a
//! burst inside EITHER spreads across groups. With `m == 1` every group has exactly one shard, so
//! the parity walk reduces to "append parity in group order, last", which is byte-identical to the
//! single-parity wire. `m` is recovered from the parity count and the group count, so the caller
//! passes only the data `group_size`.

/// Returns `items` — the first `data_count` of them data, the rest parity, as the packetizer emits
/// them — reordered for burst-resilient transmission.
///
/// Generic over the item because the send path holds finished wire datagrams and never parses
/// them back into fragments: the order is a function of the two counts and the group size alone,
/// so the permutation is computed on positions and applied to whatever the positions hold.
///
/// A byte-for-byte pass-through when `group_size <= 1`, when there is at most one data group, or
/// when there are no more items than one group. The result is always a PERMUTATION of the input —
/// the same items with every `frag_index` preserved — including when the parity count does not
/// divide evenly by the group count, in which case the strided walk's leftovers are swept up in
/// original order.
#[must_use]
pub fn interleave<T>(items: Vec<T>, data_count: usize, group_size: usize) -> Vec<T> {
    if group_size <= 1 || items.len() <= group_size {
        return items;
    }
    // A single data group gains nothing: any two losses inside it are unrecoverable regardless.
    let data_count = data_count.min(items.len());
    if data_count <= group_size {
        return items;
    }

    let mut data: Vec<Option<T>> = Vec::with_capacity(data_count);
    let mut parity: Vec<Option<T>> = Vec::with_capacity(items.len().saturating_sub(data_count));
    for (position, item) in items.into_iter().enumerate() {
        if position < data_count {
            data.push(Some(item));
        } else {
            parity.push(Some(item));
        }
    }

    let num_groups = data_count.div_ceil(group_size);
    let mut ordered = Vec::with_capacity(data.len() + parity.len());
    // DATA column-major: rank 0 of every group, then rank 1 of every group, and so on, so
    // consecutive emissions come from distinct groups. Each (rank, group) pair is visited exactly
    // once, so no slot can be moved twice.
    take_column_major(&mut data, group_size, num_groups, &mut ordered);
    // PARITY column-major over the same rank-outer, group-inner walk. `m == 1` makes this the
    // original group-order append — parity last, byte-identical.
    let m = parity.len().checked_div(num_groups).unwrap_or(0);
    take_column_major(&mut parity, m, num_groups, &mut ordered);
    // Sweep up anything the strided walk did not cover — `m == 0`, or a ragged parity count —
    // preserving original order, so the result is a full permutation no matter the count.
    ordered.extend(parity.into_iter().flatten());
    ordered
}

/// Moves `slots` into `ordered` in rank-outer, group-inner order, leaving `None` behind. A `stride`
/// of zero moves nothing, which is what makes the caller's sweep the only thing that runs when the
/// parity section has no uniform shape.
fn take_column_major<T>(slots: &mut [Option<T>], stride: usize, num_groups: usize, ordered: &mut Vec<T>) {
    for rank in 0..stride {
        for group in 0..num_groups {
            let Some(index) = group.checked_mul(stride).and_then(|base| base.checked_add(rank)) else {
                continue;
            };
            if let Some(slot) = slots.get_mut(index)
                && let Some(item) = slot.take()
            {
                ordered.push(item);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::interleave;
    use crate::fragment::{Flags, FrameFragment, FrameFragmentHeader};

    /// Builds a frame's worth of fragments: `data_count` data then `parity_count` parity, with
    /// `frag_index` counting straight through both sections, as the packetizer emits them.
    fn frame(data_count: u16, parity_count: u16) -> Vec<FrameFragment> {
        let total = data_count + parity_count;
        (0..total)
            .map(|index| {
                let flags = if index < data_count {
                    Flags::empty()
                } else {
                    Flags::PARITY
                };
                FrameFragment::new(
                    FrameFragmentHeader::new(u32::from(index), 1, index, total, flags, 0, 0),
                    Vec::new(),
                )
            })
            .collect()
    }

    fn indices(fragments: &[FrameFragment]) -> Vec<u16> {
        fragments
            .iter()
            .map(|fragment| fragment.header.frag_index)
            .collect()
    }

    fn is_permutation_of(before: &[FrameFragment], after: &[FrameFragment]) -> bool {
        let mut left = indices(before);
        let mut right = indices(after);
        left.sort_unstable();
        right.sort_unstable();
        left == right
    }

    #[test]
    fn consecutive_datagrams_come_from_different_groups() {
        // Nine data fragments in groups of three: 0,3,6, 1,4,7, 2,5,8.
        let ordered = interleave(frame(9, 3), 9, 3);
        assert_eq!(indices(&ordered)[..9], [0, 3, 6, 1, 4, 7, 2, 5, 8]);
    }

    #[test]
    fn parity_still_arrives_last() {
        let ordered = interleave(frame(9, 3), 9, 3);
        let tail = &indices(&ordered)[9..];
        assert_eq!(
            tail,
            [9, 10, 11],
            "the reassembler's reorder grace depends on this"
        );
    }

    #[test]
    fn single_parity_keeps_the_parity_section_in_group_order() {
        // m == 1: the column-major parity walk must reduce to a plain append.
        let ordered = interleave(frame(6, 2), 6, 3);
        assert_eq!(indices(&ordered), [0, 3, 1, 4, 2, 5, 6, 7]);
    }

    #[test]
    fn multi_parity_spreads_the_parity_section_across_groups_too() {
        // Two groups of three with m == 2: parity 6,7 belong to group 0 and 8,9 to group 1, so the
        // rank-outer walk emits 6,8 then 7,9.
        let ordered = interleave(frame(6, 4), 6, 3);
        assert_eq!(indices(&ordered)[6..], [6, 8, 7, 9]);
    }

    #[test]
    fn a_ragged_parity_count_still_yields_a_permutation() {
        // Three groups with five parity shards: the strided walk covers one each, and the sweep
        // must pick up the rest without dropping or duplicating any.
        let before = frame(9, 5);
        let after = interleave(before.clone(), 9, 3);
        assert!(is_permutation_of(&before, &after));
        assert_eq!(after.len(), before.len());
    }

    #[test]
    fn the_no_op_cases_pass_through_byte_for_byte() {
        for (data, parity, group) in [(9_u16, 3_u16, 1_usize), (2, 1, 3), (3, 1, 3)] {
            let before = frame(data, parity);
            assert_eq!(
                interleave(before.clone(), usize::from(data), group),
                before,
                "data {data} parity {parity} group {group} must not reorder"
            );
        }
    }

    #[test]
    fn every_shape_yields_a_permutation_with_indices_untouched() {
        for data in 1_u16..24 {
            for parity in 0_u16..6 {
                for group in 1_usize..8 {
                    let before = frame(data, parity);
                    let after = interleave(before.clone(), usize::from(data), group);
                    assert!(
                        is_permutation_of(&before, &after),
                        "data {data} parity {parity} group {group} lost or duplicated a fragment"
                    );
                }
            }
        }
    }
}
