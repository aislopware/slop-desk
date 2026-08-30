//! The host send path — `VideoPacketizer` in
//! `Sources/SlopDeskVideoProtocol/FramePacketizer.swift`.
//!
//! Fragments one encoded frame — an AVCC byte buffer — into datagrams of at most 1200 bytes,
//! appends FEC parity, optionally interleaves for burst resilience, and stamps the 19-byte header.
//! The symmetric counterpart of the reassembler.
//!
//! The two counters live here: `stream_seq` is monotonic per DATAGRAM, `frame_id` per FRAME. Both
//! wrap rather than overflow, because a session long enough to exhaust a `u32` must keep streaming
//! rather than fail.
//!
//! ## The tier decides two things at once
//!
//! `fec_tier` selects BOTH the per-frame group size and the per-frame parity multiplicity `m`, and
//! is stamped into every fragment's flags so the client splits data and parity the same way. Tier 0
//! sets no bits and changes no parity shape, so the default path is byte-identical to the
//! pre-adaptive wire.
//!
//! For tiers that resolve to the codec's own `m` — every tier on the production single-parity
//! codec — the frame's own [`ReedSolomonFec`] computes parity directly. Only the m-tiers on a
//! multi-loss codec need a different `m`, and those build a per-frame codec at the requested
//! `(k, m)`. The `m >= 2` Cauchy encoder has exactly `k` columns and clamps a per-call group to
//! `min(g, k)`, which is why [`crate::adaptive_fec::wire_tier`] forces tier 0 whenever multi-loss
//! is on: a group size that is not `k` feeds the decoder a window the matrix was never built for
//! and fails to repair SILENTLY.

use crate::bytes::truncating_u16;
use crate::fec::ReedSolomonFec;
use crate::fragment::{Flags, FrameFragment, FrameFragmentHeader, MAX_PAYLOAD_SIZE};
use crate::{adaptive_fec, interleaver};

/// What the host asks of one frame.
#[expect(
    clippy::struct_excessive_bools,
    reason = "these ARE the frame's flag bits — grouping them into sub-structs would move the wire layout \
              further from the code that stamps it"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketizeOptions {
    /// Whether this is an IDR.
    pub keyframe: bool,
    /// Whether this is a crisp near-lossless static refresh. Informational.
    pub crisp: bool,
    /// Host-monotonic ms since session start, stamped on EVERY fragment of this frame. 0 = off.
    pub host_send_ts_millis: u32,
    /// The adaptive-FEC tier.
    pub fec_tier: u8,
    /// Whether this frame is a Long-Term Reference — bit 6, so the client acks it after decode.
    pub is_ltr: bool,
    /// Whether this frame is a `ForceLTRRefresh` product — bit 7.
    pub acked_anchored: bool,
    /// Whether to run the burst-resilient transmit reorder.
    pub interleave: bool,
}

impl Default for PacketizeOptions {
    /// Every field off, at tier [`adaptive_fec::DEFAULT_TIER`] — the byte-identical baseline.
    fn default() -> Self {
        Self {
            keyframe: false,
            crisp: false,
            host_send_ts_millis: 0,
            fec_tier: adaptive_fec::DEFAULT_TIER,
            is_ltr: false,
            acked_anchored: false,
            interleave: false,
        }
    }
}

impl PacketizeOptions {
    /// The baseline with the keyframe flag set.
    #[must_use]
    pub fn keyframe() -> Self {
        Self {
            keyframe: true,
            ..Self::default()
        }
    }
}

/// Fragments encoded frames into wire datagrams, carrying the send path's two counters.
#[expect(
    missing_copy_implementations,
    reason = "a packetizer IS its two counters — an implicit copy would fork the stream sequence and hand \
              two senders the same `stream_seq`, which reads as duplicate datagrams"
)]
#[derive(Debug)]
pub struct VideoPacketizer {
    fec: Option<ReedSolomonFec>,
    next_stream_seq: u32,
    next_frame_id: u32,
}

impl VideoPacketizer {
    /// Builds a packetizer. `fec` of `None` sends data fragments only.
    #[must_use]
    pub const fn new(fec: Option<ReedSolomonFec>) -> Self {
        Self {
            fec,
            next_stream_seq: 0,
            next_frame_id: 0,
        }
    }

    /// The configured FEC scheme, which the host also reads for its group size.
    #[must_use]
    pub const fn fec(&self) -> Option<ReedSolomonFec> {
        self.fec
    }

    /// The `stream_seq` the next emitted datagram will carry. A pure read — it does NOT advance.
    #[must_use]
    pub const fn peek_next_stream_seq(&self) -> u32 {
        self.next_stream_seq
    }

    /// The `frame_id` the next [`Self::packetize`] will assign. A pure read.
    ///
    /// The host reads this BEFORE packetizing so it can record the frame's `frame_id ↔ LTR token`
    /// mapping for the frame it is about to send.
    #[must_use]
    pub const fn peek_next_frame_id(&self) -> u32 {
        self.next_frame_id
    }

    /// Fragments one encoded frame into data fragments, then parity fragments, in send order.
    pub fn packetize(&mut self, frame: &[u8], options: PacketizeOptions) -> Vec<FrameFragment> {
        let fragments = self.packetize_fragments(frame, options);
        if !options.interleave {
            return fragments;
        }
        // Interleave is keyed by the SAME per-frame group size the parity used, so the OFF tier's
        // `None` collapses to 1 and the reorder becomes a no-op.
        let default_group = self.fec.map_or(1, |scheme| scheme.group_size());
        let group = adaptive_fec::group_size(options.fec_tier, default_group).unwrap_or(1);
        interleaver::interleave(fragments, group)
    }

    /// The send-path fast path: finished wire datagrams, skipping the fragment parse and re-encode
    /// the host never needs. Byte-identical to `packetize(..)` followed by encoding each fragment.
    pub fn packetize_raw(&mut self, frame: &[u8], options: PacketizeOptions) -> Vec<Vec<u8>> {
        self.packetize(frame, options)
            .iter()
            .map(FrameFragment::encode)
            .collect()
    }

    /// Builds the frame's fragments — data, then parity — assigning the per-frame `frame_id` and a
    /// monotonic `stream_seq` per datagram. Shared by both entry points so the counters advance
    /// once per frame whichever the caller used.
    fn packetize_fragments(&mut self, frame: &[u8], options: PacketizeOptions) -> Vec<FrameFragment> {
        let frame_id = self.next_frame_id;
        self.next_frame_id = self.next_frame_id.wrapping_add(1);

        // Split into MTU-bounded payloads. A zero-byte frame still occupies one fragment.
        let payloads: Vec<&[u8]> = if frame.is_empty() {
            vec![&[]]
        } else {
            frame.chunks(MAX_PAYLOAD_SIZE).collect()
        };

        // Per-frame group size from the tier; `None` is the OFF tier, so no parity at all. Tier 0
        // maps to the codec's configured `k`, keeping the parity shape identical to the plain path.
        let parity_payloads = self.parity_payloads(&payloads, options.fec_tier);

        let frag_count = truncating_u16(payloads.len() + parity_payloads.len());

        let mut base_flags = Flags::empty();
        if options.keyframe {
            base_flags.insert(Flags::KEYFRAME);
        }
        if options.crisp {
            base_flags.insert(Flags::CRISP);
        }
        if options.is_ltr {
            base_flags.insert(Flags::IS_LTR);
        }
        if options.acked_anchored {
            base_flags.insert(Flags::ACKED_ANCHORED);
        }
        // Stamp the tier BEFORE forking data and parity flags. Tier 0 leaves bits 3-5 zero.
        base_flags.set_fec_tier(options.fec_tier);
        let parity_flags = base_flags.union(Flags::PARITY);

        let mut fragments = Vec::with_capacity(payloads.len() + parity_payloads.len());
        let mut frag_index: u16 = 0;
        for payload in payloads {
            fragments.push(self.make_fragment(
                frame_id,
                frag_index,
                frag_count,
                base_flags,
                payload.to_vec(),
                options.host_send_ts_millis,
            ));
            frag_index = frag_index.wrapping_add(1);
        }
        for payload in parity_payloads {
            fragments.push(self.make_fragment(
                frame_id,
                frag_index,
                frag_count,
                parity_flags,
                payload,
                options.host_send_ts_millis,
            ));
            frag_index = frag_index.wrapping_add(1);
        }
        fragments
    }

    /// This frame's parity shards, at the group size and multiplicity the tier selects.
    fn parity_payloads(&self, payloads: &[&[u8]], fec_tier: u8) -> Vec<Vec<u8>> {
        let Some(scheme) = self.fec else {
            return Vec::new();
        };
        let Some(group) = adaptive_fec::group_size(fec_tier, scheme.group_size()) else {
            return Vec::new();
        };
        let m = adaptive_fec::parity_count(fec_tier, scheme.parity_count());
        // One call covers both cases: at the codec's own `m` this IS `scheme.parity(..)`.
        //
        // The Swift builds a fresh codec at `(k = group, m)` for the adaptive branch. That is
        // equivalent here and NOT merely similar: an m-tier resolves its group size to the default,
        // so `group == scheme.group_size()` exactly, and the Cauchy rows depend only on `(k,
        // rank)`. Going through the configured codec instead of constructing one avoids the
        // `k + m <= 255` construction assert on a path a wire tier reaches.
        scheme.parity_with_m(payloads, group, m)
    }

    const fn make_fragment(
        &mut self,
        frame_id: u32,
        frag_index: u16,
        frag_count: u16,
        flags: Flags,
        payload: Vec<u8>,
        host_send_ts_millis: u32,
    ) -> FrameFragment {
        let stream_seq = self.next_stream_seq;
        self.next_stream_seq = self.next_stream_seq.wrapping_add(1);
        let header = FrameFragmentHeader::new(
            stream_seq,
            frame_id,
            frag_index,
            frag_count,
            flags,
            truncating_u16(payload.len()),
            host_send_ts_millis,
        );
        FrameFragment::new(header, payload)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{PacketizeOptions, VideoPacketizer};
    use crate::adaptive_fec;
    use crate::fec::ReedSolomonFec;
    use crate::fragment::{Flags, FrameFragment, MAX_PAYLOAD_SIZE};

    fn frame_of(len: usize) -> Vec<u8> {
        (0..len).map(truncate).collect()
    }

    fn truncate(value: usize) -> u8 {
        #[expect(clippy::cast_possible_truncation, reason = "a deterministic test pattern")]
        {
            value as u8
        }
    }

    fn data_and_parity(fragments: &[FrameFragment]) -> (usize, usize) {
        let parity = fragments
            .iter()
            .filter(|fragment| fragment.header.flags.contains(Flags::PARITY))
            .count();
        (fragments.len() - parity, parity)
    }

    #[test]
    fn a_zero_byte_frame_still_occupies_one_fragment() {
        let mut packetizer = VideoPacketizer::new(None);
        let fragments = packetizer.packetize(&[], PacketizeOptions::default());
        assert_eq!(fragments.len(), 1);
        assert!(fragments[0].payload.is_empty());
        assert_eq!(fragments[0].header.frag_count, 1);
    }

    #[test]
    fn the_split_is_ceil_division_over_the_mtu_budget() {
        let mut packetizer = VideoPacketizer::new(None);
        for len in [
            1,
            MAX_PAYLOAD_SIZE,
            MAX_PAYLOAD_SIZE + 1,
            MAX_PAYLOAD_SIZE * 3 - 1,
        ] {
            let fragments = packetizer.packetize(&frame_of(len), PacketizeOptions::default());
            assert_eq!(
                fragments.len(),
                len.div_ceil(MAX_PAYLOAD_SIZE),
                "frame of {len} bytes"
            );
            let rejoined: Vec<u8> = fragments
                .iter()
                .flat_map(|fragment| fragment.payload.clone())
                .collect();
            assert_eq!(rejoined, frame_of(len), "the split must lose nothing");
        }
    }

    #[test]
    fn the_counters_advance_once_per_datagram_and_once_per_frame() {
        let mut packetizer = VideoPacketizer::new(None);
        assert_eq!(packetizer.peek_next_frame_id(), 0);
        assert_eq!(packetizer.peek_next_stream_seq(), 0);

        let first = packetizer.packetize(&frame_of(MAX_PAYLOAD_SIZE * 2), PacketizeOptions::default());
        assert_eq!(first.len(), 2);
        assert_eq!(packetizer.peek_next_frame_id(), 1);
        assert_eq!(packetizer.peek_next_stream_seq(), 2);

        let second = packetizer.packetize(&frame_of(10), PacketizeOptions::default());
        assert_eq!(second[0].header.frame_id, 1);
        assert_eq!(second[0].header.stream_seq, 2);
    }

    #[test]
    fn peeking_does_not_advance_anything() {
        let mut packetizer = VideoPacketizer::new(None);
        drop(packetizer.packetize(&frame_of(10), PacketizeOptions::default()));
        let seq = packetizer.peek_next_stream_seq();
        let frame_id = packetizer.peek_next_frame_id();
        assert_eq!(packetizer.peek_next_stream_seq(), seq);
        assert_eq!(packetizer.peek_next_frame_id(), frame_id);
    }

    #[test]
    fn the_raw_path_is_byte_identical_to_encoding_each_fragment() {
        let options = PacketizeOptions {
            host_send_ts_millis: 77,
            ..PacketizeOptions::keyframe()
        };
        let frame = frame_of(MAX_PAYLOAD_SIZE * 2 + 5);
        let mut through_fragments = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let mut through_raw = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let encoded: Vec<Vec<u8>> = through_fragments
            .packetize(&frame, options)
            .iter()
            .map(FrameFragment::encode)
            .collect();
        assert_eq!(through_raw.packetize_raw(&frame, options), encoded);
    }

    #[test]
    fn every_fragment_of_a_frame_carries_the_same_stamp_and_tier() {
        let options = PacketizeOptions {
            host_send_ts_millis: 4242,
            fec_tier: 3,
            ..PacketizeOptions::keyframe()
        };
        let mut packetizer = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let fragments = packetizer.packetize(&frame_of(MAX_PAYLOAD_SIZE * 4), options);
        assert!(fragments.len() > 4);
        for fragment in &fragments {
            assert_eq!(fragment.header.host_send_ts_millis, 4242);
            assert_eq!(fragment.header.flags.fec_tier(), 3);
            assert!(fragment.header.flags.contains(Flags::KEYFRAME));
            assert_eq!(fragment.header.frag_count, truncate_u16(fragments.len()));
        }
    }

    fn truncate_u16(value: usize) -> u16 {
        #[expect(clippy::cast_possible_truncation, reason = "a small test count")]
        {
            value as u16
        }
    }

    #[test]
    fn only_the_parity_section_carries_the_parity_bit_and_it_comes_last() {
        let mut packetizer = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let fragments = packetizer.packetize(&frame_of(MAX_PAYLOAD_SIZE * 6), PacketizeOptions::default());
        let (data, parity) = data_and_parity(&fragments);
        assert_eq!(data, 6);
        assert_eq!(
            parity, 2,
            "six data fragments in groups of five is two parity shards"
        );
        assert!(
            fragments[..data]
                .iter()
                .all(|f| !f.header.flags.contains(Flags::PARITY)),
            "the data section must precede the parity section"
        );
        assert!(
            fragments[data..]
                .iter()
                .all(|f| f.header.flags.contains(Flags::PARITY))
        );
    }

    #[test]
    fn the_off_tier_emits_no_parity_at_all() {
        let mut packetizer = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let fragments = packetizer.packetize(&frame_of(MAX_PAYLOAD_SIZE * 6), PacketizeOptions {
            fec_tier: 1,
            ..PacketizeOptions::default()
        });
        assert_eq!(data_and_parity(&fragments), (6, 0));
    }

    #[test]
    fn the_tier_changes_the_group_size_and_so_the_parity_count() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 6);
        // Tier 4 is g2, so six data fragments become three groups and three parity shards.
        let mut packetizer = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let fragments = packetizer.packetize(&frame, PacketizeOptions {
            fec_tier: 4,
            ..PacketizeOptions::default()
        });
        assert_eq!(data_and_parity(&fragments), (6, 3));
    }

    #[test]
    fn tier_zero_with_no_options_is_the_byte_identical_baseline() {
        // The whole compatibility claim: the default path sets no flag bits beyond what it is asked
        // for, so a pre-adaptive receiver sees exactly what it always saw.
        let mut packetizer = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let fragments = packetizer.packetize(&frame_of(100), PacketizeOptions::default());
        assert_eq!(fragments[0].header.flags.bits(), 0);
    }

    #[test]
    fn an_m_tier_on_a_multi_loss_codec_changes_the_shard_count_per_group() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 5);
        let codec = ReedSolomonFec::new(5, 2);
        // Tier 6 is the NORMAL parity tier: m = 3 rather than the codec's own 2.
        let mut packetizer = VideoPacketizer::new(Some(codec));
        let fragments = packetizer.packetize(&frame, PacketizeOptions {
            fec_tier: adaptive_fec::PARITY_TIER_NORMAL,
            ..PacketizeOptions::default()
        });
        assert_eq!(data_and_parity(&fragments), (5, 3));
    }

    #[test]
    fn an_m_tier_on_the_production_codec_is_inert() {
        // `default_m == 1` makes every tier resolve to 1, which is the mixed-fleet guarantee.
        let frame = frame_of(MAX_PAYLOAD_SIZE * 5);
        let mut packetizer = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let fragments = packetizer.packetize(&frame, PacketizeOptions {
            fec_tier: adaptive_fec::PARITY_TIER_BURST,
            ..PacketizeOptions::default()
        });
        assert_eq!(data_and_parity(&fragments), (5, 1));
    }

    #[test]
    fn interleaving_reorders_transmission_without_touching_any_frag_index() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 9);
        let options = PacketizeOptions {
            fec_tier: 3,
            interleave: true,
            ..PacketizeOptions::default()
        };
        let mut plain = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let mut woven = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let straight = plain.packetize(&frame, PacketizeOptions {
            interleave: false,
            ..options
        });
        let reordered = woven.packetize(&frame, options);

        assert_ne!(
            reordered
                .iter()
                .map(|f| f.header.frag_index)
                .collect::<Vec<u16>>(),
            straight.iter().map(|f| f.header.frag_index).collect::<Vec<u16>>(),
            "tier 3 is g3 over nine data fragments, so the order must actually change"
        );
        let mut sorted = reordered;
        sorted.sort_by_key(|fragment| fragment.header.frag_index);
        assert_eq!(sorted, straight, "and it must stay the same set of fragments");
    }

    #[test]
    fn the_off_tier_makes_interleaving_a_no_op() {
        let frame = frame_of(MAX_PAYLOAD_SIZE * 9);
        let mut plain = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let mut woven = VideoPacketizer::new(Some(ReedSolomonFec::default()));
        let options = PacketizeOptions {
            fec_tier: 1,
            ..PacketizeOptions::default()
        };
        assert_eq!(
            woven.packetize(&frame, PacketizeOptions {
                interleave: true,
                ..options
            }),
            plain.packetize(&frame, options)
        );
    }

    #[test]
    fn a_packetizer_without_a_scheme_sends_data_only() {
        let mut packetizer = VideoPacketizer::new(None);
        let fragments = packetizer.packetize(&frame_of(MAX_PAYLOAD_SIZE * 6), PacketizeOptions::default());
        assert_eq!(data_and_parity(&fragments), (6, 0));
        assert!(packetizer.fec().is_none());
    }

    #[test]
    fn the_parity_a_frame_carries_actually_repairs_a_lost_fragment() {
        // Not a shape check: encode a frame, drop one data fragment, and rebuild it from the parity
        // the packetizer itself emitted.
        let frame = frame_of(MAX_PAYLOAD_SIZE * 3 + 17);
        let codec = ReedSolomonFec::default();
        let mut packetizer = VideoPacketizer::new(Some(codec));
        let fragments = packetizer.packetize(&frame, PacketizeOptions::default());
        let (data_count, _) = data_and_parity(&fragments);

        let mut data: Vec<Option<Vec<u8>>> = fragments[..data_count]
            .iter()
            .map(|fragment| Some(fragment.payload.clone()))
            .collect();
        let parity: Vec<Option<Vec<u8>>> = fragments[data_count..]
            .iter()
            .map(|fragment| Some(fragment.payload.clone()))
            .collect();
        let lost = data[1].clone().expect("the fragment exists before it is dropped");
        data[1] = None;

        codec.recover(&mut data, &parity, codec.group_size());
        assert_eq!(data[1].as_ref(), Some(&lost));
    }
}
