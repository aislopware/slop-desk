//! The per-datagram video header and its fragment codec —
//! `Sources/SlopDeskVideoProtocol/FramePacketizer.swift` (doc 17 §3.6).
//!
//! Fixed 19 bytes, big-endian:
//!
//! ```text
//! off 0: u32 stream_seq           per-datagram counter in PACKETIZE order — informational;
//!                                 not send order under interleave, and loss is tracked by
//!                                 frame_id/frag_index, never by a gap here
//! off 4: u32 frame_id             groups the fragments of one encoded frame
//! off 8: u16 frag_index           0-based index within the frame
//! off10: u16 frag_count           total fragments in the frame — u16 so it can exceed 255
//! off12: u8  flags                bit0 keyframe, bit1 parity, bit2 crisp,
//!                                 bits3-5 FEC tier, bit6 is-LTR, bit7 acked-anchored
//! off13: u32 host_send_ts_millis  host-monotonic ms since the host SESSION start; 0 = off
//! off17: u16 payload_len          bytes of payload that follow
//! off19: payload
//! ```
//!
//! The MTU budget — 1200 bytes, "datagrams <= 1200 bytes" with `WireGuard` overhead in mind — minus
//! this header gives [`MAX_PAYLOAD_SIZE`].
//!
//! ## The timestamp is RELATIVE on purpose
//!
//! `host_send_ts_millis` is milliseconds since the HOST's session start, and the client never
//! compares it against its own clock. It echoes the newest value it saw back in a stats report, and
//! the host subtracts that from its OWN clock to derive RTT. There is therefore no cross-machine
//! clock skew anywhere in the RTT figure — the two ends never need to agree on what time it is.
//!
//! ## Why bit 7 exists when bit 6 looks like it should do the job
//!
//! Bit 6 says "this frame is an LTR — ack it after you decode it". Bit 7 says "this frame
//! references ONLY long-term references you already acknowledged, so it is decodable even with the
//! recent short-term chain broken". They read similarly and are not interchangeable: `VideoToolbox`
//! surfaces an ack token on virtually EVERY frame once LTR is on — measured live at 7865 of 7874
//! frames — so bit 6 carries almost no information about whether decoding is safe past a loss. The
//! client's decode gate admits a non-keyframe re-anchor on bit 7 and only bit 7.
//!
//! Pinned by the `fragmentEncode` golden vectors.

use crate::bytes::{ByteReader, ByteWriter, truncating_u16};
use crate::error::Result;

/// Header size in bytes.
pub const HEADER_SIZE: usize = 19;
/// Max UDP payload size — "<= 1200 bytes" to stay under a typical MTU with `WireGuard` overhead.
pub const MAX_DATAGRAM_SIZE: usize = 1200;
/// Max payload bytes per DATA fragment.
///
/// The datagram budget minus the header, minus the length prefix a parity shard carries: a group's
/// parity is as wide as its widest length-prefixed member, so the parity datagram of a full data
/// fragment is the widest a frame produces, and it is the one the budget must hold.
pub const MAX_PAYLOAD_SIZE: usize = MAX_DATAGRAM_SIZE - HEADER_SIZE - crate::fec::PREFIX_BYTES;

/// Per-fragment flags — a bit set over the flags byte.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Flags(u8);

impl Flags {
    /// This frame is a keyframe (IDR) — a fresh decode anchor.
    pub const KEYFRAME: Self = Self(1 << 0);
    /// This fragment is an FEC parity fragment, not original data.
    pub const PARITY: Self = Self(1 << 1);
    /// This frame is a CRISP near-lossless static refresh — a QP-bumped keyframe emitted when the
    /// window is at rest. Informational on the wire; the client treats it as an ordinary keyframe.
    pub const CRISP: Self = Self(1 << 2);
    /// Bit 6 — a Long-Term-Reference frame; a client that decodes it must ack it.
    pub const IS_LTR: Self = Self(1 << 6);
    /// Bit 7 — encoded via `ForceLTRRefresh`; the decode gate's ONLY non-keyframe re-anchor.
    pub const ACKED_ANCHORED: Self = Self(1 << 7);

    /// Where the 3-bit adaptive-FEC tier sits in the flags byte.
    pub const TIER_SHIFT: u8 = 3;
    /// The mask covering bits 3, 4 and 5.
    pub const TIER_MASK: u8 = 0b0011_1000;

    /// An empty set.
    #[must_use]
    pub const fn empty() -> Self {
        Self(0)
    }

    /// Wraps a raw wire byte.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Self {
        Self(bits)
    }

    /// The raw wire byte.
    #[must_use]
    pub const fn bits(self) -> u8 {
        self.0
    }

    /// Whether every flag in `other` is set.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// This set with `other`'s flags added.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// Adds `other`'s flags in place.
    pub const fn insert(&mut self, other: Self) {
        self.0 |= other.0;
    }

    /// The 3-bit FEC tier from bits 3-5, with keyframe/parity/crisp and bits 6-7 masked out.
    #[must_use]
    pub const fn fec_tier(self) -> u8 {
        (self.0 & Self::TIER_MASK) >> Self::TIER_SHIFT
    }

    /// Sets the 3-bit FEC tier, preserving every other bit. `tier` is masked to three bits, so this
    /// can never disturb keyframe, parity, crisp or the reserved bits.
    pub const fn set_fec_tier(&mut self, tier: u8) {
        self.0 = (self.0 & !Self::TIER_MASK) | ((tier & 0b111) << Self::TIER_SHIFT);
    }
}

/// The fixed 19-byte per-datagram header.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FrameFragmentHeader {
    /// Monotonic per-datagram sequence number, for ordering and loss detection.
    pub stream_seq: u32,
    /// Groups the fragments of one encoded frame.
    pub frame_id: u32,
    /// This fragment's 0-based index within the frame.
    pub frag_index: u16,
    /// Total fragments in the frame, data and parity together.
    pub frag_count: u16,
    /// The flag bits.
    pub flags: Flags,
    /// Host-monotonic milliseconds since the host session start; 0 means telemetry off. Carried on
    /// EVERY fragment of a frame — all of them share one stamp.
    pub host_send_ts_millis: u32,
    /// Bytes of payload that follow. Defensive — UDP bounds it too — and kept IMMEDIATELY before
    /// the payload it sizes.
    pub payload_length: u16,
}

impl FrameFragmentHeader {
    /// Builds a header.
    #[must_use]
    pub const fn new(
        stream_seq: u32,
        frame_id: u32,
        frag_index: u16,
        frag_count: u16,
        flags: Flags,
        payload_length: u16,
        host_send_ts_millis: u32,
    ) -> Self {
        Self {
            stream_seq,
            frame_id,
            frag_index,
            frag_count,
            flags,
            host_send_ts_millis,
            payload_length,
        }
    }

    /// Parses just the header, answering it with the payload still BORROWED from the datagram.
    ///
    /// Separate from [`FrameFragment::decode`] because a reader that already holds the datagram —
    /// the client's router, the FFI boundary — would otherwise pay for a copy of the payload it is
    /// about to hand straight back. One parse, two ways to take the answer.
    ///
    /// # Errors
    /// [`crate::VideoProtocolError::Truncated`] for a datagram shorter than the header, or one
    /// whose declared payload length runs past its end.
    pub fn decode(datagram: &[u8]) -> Result<(Self, &[u8])> {
        let mut reader = ByteReader::new(datagram);
        let stream_seq = reader.read_u32()?;
        let frame_id = reader.read_u32()?;
        let frag_index = reader.read_u16()?;
        let frag_count = reader.read_u16()?;
        let flags = Flags::from_bits(reader.read_u8()?);
        let host_send_ts_millis = reader.read_u32()?;
        let payload_length = reader.read_u16()?;
        let payload = reader.read_bytes(usize::from(payload_length))?;
        Ok((
            Self::new(
                stream_seq,
                frame_id,
                frag_index,
                frag_count,
                flags,
                payload_length,
                host_send_ts_millis,
            ),
            payload,
        ))
    }
}

/// Serialises a header and a BORROWED payload — header then payload.
///
/// The declared length comes from the PAYLOAD, not from `header.payload_length`: the two cannot
/// disagree on the wire even if a caller built the header by hand.
#[must_use]
pub fn encode_datagram(header: &FrameFragmentHeader, payload: &[u8]) -> Vec<u8> {
    let mut out = ByteWriter::with_capacity(HEADER_SIZE + payload.len());
    out.put_u32(header.stream_seq);
    out.put_u32(header.frame_id);
    out.put_u16(header.frag_index);
    out.put_u16(header.frag_count);
    out.put_u8(header.flags.bits());
    out.put_u32(header.host_send_ts_millis);
    out.put_u16(truncating_u16(payload.len()));
    out.put_bytes(payload);
    out.into_vec()
}

/// One fragment datagram: header plus payload.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FrameFragment {
    /// The header.
    pub header: FrameFragmentHeader,
    /// The payload bytes.
    pub payload: Vec<u8>,
}

impl FrameFragment {
    /// Builds a fragment.
    #[must_use]
    pub const fn new(header: FrameFragmentHeader, payload: Vec<u8>) -> Self {
        Self { header, payload }
    }

    /// Serialises the datagram — header then payload. See [`encode_datagram`].
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        encode_datagram(&self.header, &self.payload)
    }

    /// Parses one datagram.
    ///
    /// # Errors
    /// [`crate::VideoProtocolError::Truncated`] for a datagram shorter than the header, or one
    /// whose declared payload length runs past its end. Either way the router drops the single
    /// packet; a corrupt datagram must never take the receiver with it.
    pub fn decode(datagram: &[u8]) -> Result<Self> {
        let (header, payload) = FrameFragmentHeader::decode(datagram)?;
        Ok(Self::new(header, payload.to_vec()))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        Flags, FrameFragment, FrameFragmentHeader, HEADER_SIZE, MAX_DATAGRAM_SIZE, MAX_PAYLOAD_SIZE,
    };
    use crate::error::VideoProtocolError;

    #[test]
    fn a_fragment_round_trips_with_every_flag_bit_set() {
        let header = FrameFragmentHeader::new(0xFFFF_FFFF, 7, 2, 9, Flags::from_bits(0xFF), 3, 1234);
        let fragment = FrameFragment::new(header, vec![0xAA, 0xBB, 0xCC]);
        let bytes = fragment.encode();
        assert_eq!(bytes.len(), HEADER_SIZE + 3);
        assert_eq!(FrameFragment::decode(&bytes), Ok(fragment));
    }

    #[test]
    fn an_empty_payload_is_a_legal_fragment() {
        let fragment = FrameFragment::default();
        let bytes = fragment.encode();
        assert_eq!(bytes.len(), HEADER_SIZE);
        assert_eq!(FrameFragment::decode(&bytes), Ok(fragment));
    }

    #[test]
    fn a_short_datagram_and_an_overlong_length_are_both_truncation() {
        assert_eq!(
            FrameFragment::decode(&[0; 18]),
            Err(VideoProtocolError::Truncated)
        );
        let mut bytes = FrameFragment::new(FrameFragmentHeader::default(), vec![1, 2, 3]).encode();
        bytes[17] = 0xFF;
        bytes[18] = 0xFF;
        assert_eq!(FrameFragment::decode(&bytes), Err(VideoProtocolError::Truncated));
    }

    #[test]
    fn the_declared_length_follows_the_payload_not_the_header_field() {
        // A header claiming a length the payload does not have must not reach the wire.
        let header = FrameFragmentHeader {
            payload_length: 99,
            ..FrameFragmentHeader::default()
        };
        let bytes = FrameFragment::new(header, vec![7, 7]).encode();
        let decoded = FrameFragment::decode(&bytes).expect("the encoder must self-consist");
        assert_eq!(decoded.header.payload_length, 2);
        assert_eq!(decoded.payload, vec![7, 7]);
    }

    #[test]
    fn the_tier_bits_never_disturb_the_other_flags() {
        for tier in 0..=u8::MAX {
            let mut flags = Flags::KEYFRAME
                .union(Flags::PARITY)
                .union(Flags::CRISP)
                .union(Flags::IS_LTR)
                .union(Flags::ACKED_ANCHORED);
            flags.set_fec_tier(tier);
            assert_eq!(flags.fec_tier(), tier & 0b111, "tier {tier} masks to three bits");
            assert!(flags.contains(Flags::KEYFRAME));
            assert!(flags.contains(Flags::PARITY));
            assert!(flags.contains(Flags::CRISP));
            assert!(flags.contains(Flags::IS_LTR));
            assert!(flags.contains(Flags::ACKED_ANCHORED));
        }
    }

    #[test]
    fn tier_zero_leaves_the_flags_byte_untouched() {
        // The byte-identity guarantee: the pre-adaptive wire had no tier bits at all.
        let mut flags = Flags::KEYFRAME;
        flags.set_fec_tier(0);
        assert_eq!(flags.bits(), Flags::KEYFRAME.bits());
    }

    #[test]
    fn the_header_size_matches_what_encode_actually_writes() {
        let written = FrameFragment::default().encode().len();
        assert_eq!(written, HEADER_SIZE);
        assert_eq!(
            MAX_PAYLOAD_SIZE + crate::fec::PREFIX_BYTES,
            MAX_DATAGRAM_SIZE - HEADER_SIZE
        );
    }

    #[test]
    fn the_named_flag_bits_are_the_documented_positions() {
        assert_eq!(Flags::KEYFRAME.bits(), 0b0000_0001);
        assert_eq!(Flags::PARITY.bits(), 0b0000_0010);
        assert_eq!(Flags::CRISP.bits(), 0b0000_0100);
        assert_eq!(Flags::TIER_MASK, 0b0011_1000);
        assert_eq!(Flags::IS_LTR.bits(), 0b0100_0000);
        assert_eq!(Flags::ACKED_ANCHORED.bits(), 0b1000_0000);
        // Disjointness is the property the tier packing depends on.
        assert_eq!(Flags::TIER_MASK & Flags::KEYFRAME.bits(), 0);
        assert_eq!(Flags::TIER_MASK & Flags::IS_LTR.bits(), 0);
        assert_eq!(Flags::TIER_MASK & Flags::ACKED_ANCHORED.bits(), 0);
    }
}
