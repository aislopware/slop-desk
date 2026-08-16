//! The bounded send history a selective retransmit is answered from.
//!
//! It maps a frame id to the exact wire datagrams that frame went out as, so a client's negative
//! acknowledgement can be answered by re-sending only the MISSING fragments — cheaper than a
//! recovery keyframe, and with the client's playout buffer well above the round trip the repair
//! lands before playout, so nothing stutters. Oldest-first eviction past either the frame count or
//! the byte ceiling, because a send history is exactly the kind of structure a long stream would
//! otherwise grow without bound.

use std::collections::BTreeMap;

use crate::fragment::FrameFragment;

/// The bounded per-frame datagram history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetransmitRing {
    /// Frame ids in record order, oldest first.
    order: Vec<u32>,
    /// The datagrams each recorded frame went out as.
    by_frame: BTreeMap<u32, Vec<Vec<u8>>>,
    /// The bytes currently held.
    total_bytes: usize,
    /// The most frames retained.
    max_frames: usize,
    /// The most bytes retained, always leaving at least one frame.
    max_bytes: usize,
}

impl RetransmitRing {
    /// A ring with the given ceilings, each floored at one.
    #[must_use]
    pub const fn new(max_frames: usize, max_bytes: usize) -> Self {
        Self {
            order: Vec::new(),
            by_frame: BTreeMap::new(),
            total_bytes: 0,
            max_frames: if max_frames > 1 { max_frames } else { 1 },
            max_bytes: if max_bytes > 1 { max_bytes } else { 1 },
        }
    }

    /// The bytes currently held.
    #[must_use]
    pub const fn total_bytes(&self) -> usize {
        self.total_bytes
    }

    /// How many frames are currently held.
    #[must_use]
    pub const fn frame_count(&self) -> usize {
        self.order.len()
    }

    /// Records a frame's datagrams.
    ///
    /// A repeat frame id — the duplicate-keyframe re-enqueue, say — KEEPS the first copy: the two
    /// are byte-identical, so a repair is the same answer either way, and keeping the first avoids
    /// double-counting the bytes.
    pub fn record(&mut self, frame_id: u32, datagrams: Vec<Vec<u8>>) {
        if self.by_frame.contains_key(&frame_id) {
            return;
        }
        self.total_bytes += datagrams.iter().map(Vec::len).sum::<usize>();
        self.order.push(frame_id);
        self.by_frame.insert(frame_id, datagrams);
        while self.order.len() > self.max_frames
            || (self.total_bytes > self.max_bytes && self.order.len() > 1)
        {
            let evicted = self.order.remove(0);
            if let Some(gone) = self.by_frame.remove(&evicted) {
                self.total_bytes -= gone.iter().map(Vec::len).sum::<usize>();
            }
        }
    }

    /// The datagrams for the requested DATA fragment indices of `frame_id`, or empty when the frame
    /// has aged out.
    ///
    /// The filter reads each datagram's own header rather than trusting record order, so a
    /// reordered or partially-parity send answers correctly. No mux prefix is present here — the
    /// transport prepends that at send time.
    #[must_use]
    pub fn fragments(&self, frame_id: u32, frag_indices: &[u16]) -> Vec<Vec<u8>> {
        let Some(datagrams) = self.by_frame.get(&frame_id) else {
            return Vec::new();
        };
        datagrams
            .iter()
            .filter(|bytes| {
                FrameFragment::decode(bytes)
                    .is_ok_and(|fragment| frag_indices.contains(&fragment.header.frag_index))
            })
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::RetransmitRing;
    use crate::fragment::{Flags, FrameFragment, FrameFragmentHeader};

    /// One datagram carrying the header a repair is selected by, padded to a plausible size.
    fn datagram(frame_id: u32, frag_index: u16, frag_count: u16, payload_len: usize) -> Vec<u8> {
        let header = FrameFragmentHeader::new(
            u32::from(frag_index),
            frame_id,
            frag_index,
            frag_count,
            Flags::empty(),
            u16::try_from(payload_len).unwrap_or(0),
            0,
        );
        FrameFragment::new(header, vec![0xAB; payload_len]).encode()
    }

    #[test]
    fn only_the_requested_fragments_come_back() {
        let mut ring = RetransmitRing::new(8, 1 << 20);
        let sent: Vec<Vec<u8>> = (0..4).map(|index| datagram(10, index, 4, 100)).collect();
        ring.record(10, sent);
        let repair = ring.fragments(10, &[1, 3]);
        assert_eq!(repair.len(), 2);
        for bytes in &repair {
            let fragment = FrameFragment::decode(bytes).expect("a recorded datagram");
            let index = fragment.header.frag_index;
            assert!(index == 1 || index == 3, "unexpected fragment {index}");
        }
    }

    #[test]
    fn a_frame_that_aged_out_answers_with_nothing() {
        let ring = RetransmitRing::new(8, 1 << 20);
        assert!(ring.fragments(10, &[0]).is_empty());
    }

    #[test]
    fn a_repeated_frame_id_keeps_the_first_copy_and_counts_its_bytes_once() {
        let mut ring = RetransmitRing::new(8, 1 << 20);
        ring.record(10, vec![datagram(10, 0, 1, 100)]);
        let before = ring.total_bytes();
        ring.record(10, vec![datagram(10, 0, 1, 100)]);
        assert_eq!(ring.total_bytes(), before, "the duplicate is not double-counted");
        assert_eq!(ring.frame_count(), 1);
    }

    #[test]
    fn the_frame_count_ceiling_evicts_oldest_first() {
        let mut ring = RetransmitRing::new(2, 1 << 20);
        for frame_id in 0..3 {
            ring.record(frame_id, vec![datagram(frame_id, 0, 1, 100)]);
        }
        assert!(ring.fragments(0, &[0]).is_empty(), "the oldest went");
        assert!(!ring.fragments(2, &[0]).is_empty());
        assert_eq!(ring.frame_count(), 2);
    }

    #[test]
    fn the_byte_ceiling_evicts_too_but_always_leaves_one_frame() {
        let mut ring = RetransmitRing::new(64, 200);
        for frame_id in 0..4 {
            ring.record(frame_id, vec![datagram(frame_id, 0, 1, 500)]);
        }
        assert_eq!(ring.frame_count(), 1, "one oversized frame is still answerable");
        assert!(!ring.fragments(3, &[0]).is_empty(), "and it is the newest");
    }

    #[test]
    fn a_truncated_datagram_is_skipped_rather_than_mis_selected() {
        let mut ring = RetransmitRing::new(8, 1 << 20);
        ring.record(10, vec![vec![0x01, 0x02], datagram(10, 0, 1, 100)]);
        assert_eq!(
            ring.fragments(10, &[0]).len(),
            1,
            "only the parseable one answers"
        );
    }
}
