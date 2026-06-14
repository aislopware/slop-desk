//! Per-datagram video header, fragment codec, and the host packetizer — a port of
//! Swift `FramePacketizer.swift` (`FrameFragmentHeader`, `FrameFragment`,
//! `VideoPacketizer`).
//!
//! Wire header is a fixed **19 bytes, big-endian**:
//! ```text
//! off  0: u32 stream_seq          monotonic per-datagram sequence (loss/order)
//! off  4: u32 frame_id            groups fragments of one encoded frame
//! off  8: u16 frag_index          0-based index within the frame
//! off 10: u16 frag_count          total fragments in the frame
//! off 12: u8  flags               bit0 keyframe, bit1 parity, bit2 crisp,
//!                                 bits3-5 FEC tier, bit6 isLTR, bit7 ackedAnchored
//! off 13: u32 host_send_ts_millis host-monotonic ms since session start (0 = off)
//! off 17: u16 payload_len         bytes of payload that follow
//! off 19: payload[payload_len]
//! ```

use crate::adaptive_fec;
use crate::bytes::{ByteReader, ByteWriter};
use crate::error::Result;
use crate::fec::FecScheme;

/// Per-datagram fragment flags (bit set over the flags byte).
///
/// Mirrors the Swift `OptionSet`. Bits: 0 keyframe, 1 parity, 2 crisp, 3-5 FEC tier,
/// 6 isLTR, 7 ackedAnchored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Flags(pub u8);

impl Flags {
    /// This frame is a keyframe (IDR) — a fresh decode anchor.
    pub const KEYFRAME: Self = Self(1 << 0);
    /// This fragment is an FEC parity fragment, not original data.
    pub const PARITY: Self = Self(1 << 1);
    /// This frame is a crisp near-lossless static refresh (treated as a keyframe).
    pub const CRISP: Self = Self(1 << 2);
    /// Bit 6 — this is a Long-Term-Reference frame; a client that decodes it must ack it.
    pub const IS_LTR: Self = Self(1 << 6);
    /// Bit 7 — encoded via `ForceLTRRefresh`; the decode gate's non-keyframe re-anchor.
    pub const ACKED_ANCHORED: Self = Self(1 << 7);

    const TIER_SHIFT: u8 = 3;
    const TIER_MASK: u8 = 0b0011_1000; // bits 3,4,5

    /// The raw flag byte.
    #[must_use]
    pub const fn raw(self) -> u8 {
        self.0
    }

    /// Whether every bit of `other` is set (`OptionSet.contains`).
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// Sets every bit of `other` (`OptionSet.insert`).
    pub const fn insert(&mut self, other: Self) {
        self.0 |= other.0;
    }

    /// Returns the union of two flag sets.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// The 3-bit FEC tier (0..=7) read from bits 3-5.
    #[must_use]
    pub const fn fec_tier(self) -> u8 {
        (self.0 & Self::TIER_MASK) >> Self::TIER_SHIFT
    }

    /// Sets the 3-bit FEC tier in bits 3-5, preserving every other bit. `t` is masked to
    /// 3 bits, so this can never disturb the other flags or the reserved bits.
    pub const fn set_fec_tier(&mut self, t: u8) {
        self.0 = (self.0 & !Self::TIER_MASK) | ((t & 0b111) << Self::TIER_SHIFT);
    }
}

/// Per-datagram header for the video stream (fixed 19 bytes, big-endian).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameFragmentHeader {
    /// Monotonic per-datagram sequence number (loss / ordering).
    pub stream_seq: u32,
    /// Groups fragments of one encoded video frame.
    pub frame_id: u32,
    /// 0-based index of this fragment within the frame.
    pub frag_index: u16,
    /// Total fragments in the frame (data + parity).
    pub frag_count: u16,
    /// Fragment flags (keyframe / parity / crisp / tier / LTR / acked-anchored).
    pub flags: Flags,
    /// Host-monotonic ms since the host session start (0 = telemetry off / unstamped).
    pub host_send_ts_millis: u32,
    /// Bytes of payload that follow this header.
    pub payload_length: u16,
}

impl FrameFragmentHeader {
    /// Header size in bytes.
    pub const SIZE: usize = 19;
}

/// One fragment datagram = header + payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameFragment {
    /// The 19-byte header.
    pub header: FrameFragmentHeader,
    /// The fragment payload bytes.
    pub payload: Vec<u8>,
}

impl FrameFragment {
    /// Serialises the datagram (header then payload). The on-wire payload length is the
    /// ACTUAL payload byte count (matching Swift, which writes `UInt16(payload.count)`
    /// rather than the stored `payload_length`).
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::with_capacity(FrameFragmentHeader::SIZE + self.payload.len());
        w.put_u32(self.header.stream_seq);
        w.put_u32(self.header.frame_id);
        w.put_u16(self.header.frag_index);
        w.put_u16(self.header.frag_count);
        w.put_u8(self.header.flags.raw());
        w.put_u32(self.header.host_send_ts_millis);
        // Invariant (held by construction — the packetizer chunks to <= MAX_PAYLOAD_SIZE):
        // a fragment payload never exceeds u16. Swift traps here; we assert in debug and
        // stay panic-free in release (a panic across the future C ABI would be UB).
        debug_assert!(
            u16::try_from(self.payload.len()).is_ok(),
            "fragment payload exceeds u16"
        );
        w.put_u16(self.payload.len() as u16);
        w.put_bytes(&self.payload);
        w.into_vec()
    }

    /// Parses one datagram. Returns a [`crate::VideoProtocolError`] on a short /
    /// inconsistent datagram — a corrupt single packet must not crash the receiver.
    /// Trailing bytes beyond the declared payload length are ignored (matches Swift).
    pub fn decode(datagram: &[u8]) -> Result<Self> {
        let mut r = ByteReader::new(datagram);
        let stream_seq = r.read_u32()?;
        let frame_id = r.read_u32()?;
        let frag_index = r.read_u16()?;
        let frag_count = r.read_u16()?;
        let flags = Flags(r.read_u8()?);
        let host_send_ts_millis = r.read_u32()?;
        let payload_length = r.read_u16()?;
        let payload = r.read_bytes(usize::from(payload_length))?.to_vec();
        Ok(Self {
            header: FrameFragmentHeader {
                stream_seq,
                frame_id,
                frag_index,
                frag_count,
                flags,
                host_send_ts_millis,
                payload_length,
            },
            payload,
        })
    }
}

/// Optional per-frame parameters for [`VideoPacketizer::packetize`].
///
/// Mirrors the Swift
/// default arguments (`crisp=false`, `host_send_ts_millis=0`, tier 0, `is_ltr=false`,
/// `acked_anchored=false`). The defaults reproduce the pre-WF-4/WF-8 wire byte-for-byte.
#[derive(Debug, Clone, Copy)]
pub struct PacketizeOptions {
    /// Sets the keyframe (IDR) flag.
    pub keyframe: bool,
    /// Sets the crisp static-refresh flag (informational).
    pub crisp: bool,
    /// Host-monotonic ms since session start, stamped on every fragment of this frame.
    pub host_send_ts_millis: u32,
    /// WF-4 adaptive-FEC tier; selects the per-frame XOR group size and is stamped into
    /// every fragment's flags so the client splits data/parity with the same size.
    pub fec_tier: u8,
    /// WF-8 — sets bit 6 on every fragment so the client acks the frame after decode.
    pub is_ltr: bool,
    /// Sets bit 7 (encoded via `ForceLTRRefresh`).
    pub acked_anchored: bool,
}

impl Default for PacketizeOptions {
    fn default() -> Self {
        Self {
            keyframe: false,
            crisp: false,
            host_send_ts_millis: 0,
            fec_tier: adaptive_fec::DEFAULT_TIER,
            is_ltr: false,
            acked_anchored: false,
        }
    }
}

/// Fragments a NALU-bearing encoded frame into ≤1200-byte datagrams.
///
/// Stateful only in that it hands out a monotonic per-datagram `stream_seq` and a
/// per-frame `frame_id`; a value type owned by the single send loop.
pub struct VideoPacketizer {
    next_stream_seq: u32,
    next_frame_id: u32,
    fec: Option<Box<dyn FecScheme>>,
}

impl VideoPacketizer {
    /// Max UDP payload size (≤1200 bytes to stay under typical MTU with `WireGuard`
    /// overhead).
    pub const MAX_DATAGRAM_SIZE: usize = 1200;
    /// Max payload bytes per fragment (datagram budget minus the 19-byte header).
    pub const MAX_PAYLOAD_SIZE: usize = Self::MAX_DATAGRAM_SIZE - FrameFragmentHeader::SIZE;

    /// Builds a packetizer. With `Some(fec)`, parity fragments are appended per frame.
    #[must_use]
    pub fn new(fec: Option<Box<dyn FecScheme>>) -> Self {
        Self {
            next_stream_seq: 0,
            next_frame_id: 0,
            fec,
        }
    }

    /// The `stream_seq` the next emitted datagram will carry.
    #[must_use]
    pub const fn peek_next_stream_seq(&self) -> u32 {
        self.next_stream_seq
    }

    /// The `frame_id` the next `packetize` call will assign.
    #[must_use]
    pub const fn peek_next_frame_id(&self) -> u32 {
        self.next_frame_id
    }

    /// Fragments one encoded frame (an AVCC byte buffer) into data fragments, followed
    /// by FEC parity fragments if a scheme is configured. Returns fragments in send
    /// order (data, then parity).
    ///
    /// The total fragment count cannot exceed `u16::MAX` for any real frame (that would
    /// be a >77 MB frame); the invariant is asserted in debug and the cast is panic-free
    /// in release. Swift traps here instead — but the bound holds by construction, so
    /// neither path is reachable from real or untrusted input.
    pub fn packetize(&mut self, frame: &[u8], opts: PacketizeOptions) -> Vec<FrameFragment> {
        let frame_id = self.next_frame_id;
        self.next_frame_id = self.next_frame_id.wrapping_add(1);

        // Split into MTU-bounded payloads. A zero-byte frame still occupies one fragment.
        let payloads: Vec<&[u8]> = if frame.is_empty() {
            vec![&[]]
        } else {
            frame.chunks(Self::MAX_PAYLOAD_SIZE).collect()
        };

        // WF-4: per-frame group size from the tier (None = OFF → no parity). Tier 0 maps
        // to the configured `fec.group_size()` so parity shape matches the pre-WF-4 path.
        let default_group = self.fec.as_ref().map_or(1, |f| f.group_size());
        let group_size = adaptive_fec::group_size(opts.fec_tier, default_group);
        let parity_payloads: Vec<Vec<u8>> = match (group_size, self.fec.as_ref()) {
            (Some(g), Some(fec)) => fec.parity(&payloads, g),
            _ => Vec::new(),
        };

        let total_frags = payloads.len() + parity_payloads.len();
        debug_assert!(
            u16::try_from(total_frags).is_ok(),
            "fragment count exceeds u16"
        );
        let frag_count = total_frags as u16;

        let mut base_flags = Flags::default();
        if opts.keyframe {
            base_flags.insert(Flags::KEYFRAME);
        }
        if opts.crisp {
            base_flags.insert(Flags::CRISP);
        }
        if opts.is_ltr {
            base_flags.insert(Flags::IS_LTR);
        }
        if opts.acked_anchored {
            base_flags.insert(Flags::ACKED_ANCHORED);
        }
        // Stamp the tier into bits 3-5 BEFORE forking data/parity flags. Tier 0 → zero.
        base_flags.set_fec_tier(opts.fec_tier);

        let mut fragments = Vec::with_capacity(payloads.len() + parity_payloads.len());
        let mut frag_index: u16 = 0;
        for payload in payloads {
            fragments.push(self.make_fragment(
                frame_id,
                frag_index,
                frag_count,
                base_flags,
                payload.to_vec(),
                opts.host_send_ts_millis,
            ));
            frag_index += 1;
        }
        for payload in parity_payloads {
            let flags = base_flags.union(Flags::PARITY);
            fragments.push(self.make_fragment(
                frame_id,
                frag_index,
                frag_count,
                flags,
                payload,
                opts.host_send_ts_millis,
            ));
            frag_index += 1;
        }
        fragments
    }

    fn make_fragment(
        &mut self,
        frame_id: u32,
        frag_index: u16,
        frag_count: u16,
        flags: Flags,
        payload: Vec<u8>,
        host_send_ts_millis: u32,
    ) -> FrameFragment {
        let seq = self.next_stream_seq;
        self.next_stream_seq = self.next_stream_seq.wrapping_add(1);
        debug_assert!(
            u16::try_from(payload.len()).is_ok(),
            "fragment payload exceeds u16"
        );
        let payload_length = payload.len() as u16;
        FrameFragment {
            header: FrameFragmentHeader {
                stream_seq: seq,
                frame_id,
                frag_index,
                frag_count,
                flags,
                host_send_ts_millis,
                payload_length,
            },
            payload,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fec::XorParityFec;

    #[test]
    fn flags_tier_packing_preserves_other_bits() {
        let mut f = Flags::KEYFRAME.union(Flags::IS_LTR);
        f.set_fec_tier(3);
        assert_eq!(f.fec_tier(), 3);
        assert!(f.contains(Flags::KEYFRAME));
        assert!(f.contains(Flags::IS_LTR));
        assert!(!f.contains(Flags::PARITY));
        // tier masked to 3 bits
        f.set_fec_tier(0b1111);
        assert_eq!(f.fec_tier(), 0b111);
        assert!(f.contains(Flags::KEYFRAME));
    }

    #[test]
    fn fragment_encode_decode_round_trip() {
        let frag = FrameFragment {
            header: FrameFragmentHeader {
                stream_seq: 0x0102_0304,
                frame_id: 0x0506_0708,
                frag_index: 0x090A,
                frag_count: 0x0B0C,
                flags: Flags::KEYFRAME.union(Flags::CRISP),
                host_send_ts_millis: 0x0D0E_0F10,
                payload_length: 3,
            },
            payload: vec![0xAA, 0xBB, 0xCC],
        };
        let bytes = frag.encode();
        assert_eq!(bytes.len(), FrameFragmentHeader::SIZE + 3);
        let back = FrameFragment::decode(&bytes).unwrap();
        assert_eq!(back, frag);
    }

    #[test]
    fn short_datagram_is_truncated_not_panic() {
        assert!(FrameFragment::decode(&[0, 1, 2]).is_err());
    }

    #[test]
    fn empty_frame_yields_one_fragment() {
        let mut p = VideoPacketizer::new(None);
        let frags = p.packetize(&[], PacketizeOptions::default());
        assert_eq!(frags.len(), 1);
        assert_eq!(frags[0].header.frag_count, 1);
        assert!(frags[0].payload.is_empty());
    }

    #[test]
    fn large_frame_chunks_by_mtu() {
        let mut p = VideoPacketizer::new(None);
        let frame = vec![7u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 2 + 10];
        let frags = p.packetize(&frame, PacketizeOptions::default());
        assert_eq!(frags.len(), 3);
        assert_eq!(frags[0].payload.len(), VideoPacketizer::MAX_PAYLOAD_SIZE);
        assert_eq!(frags[1].payload.len(), VideoPacketizer::MAX_PAYLOAD_SIZE);
        assert_eq!(frags[2].payload.len(), 10);
        // monotonic stream_seq, shared frame_id
        assert_eq!(frags[0].header.stream_seq, 0);
        assert_eq!(frags[2].header.stream_seq, 2);
        assert!(frags.iter().all(|f| f.header.frame_id == 0));
    }

    #[test]
    fn fec_appends_parity_with_tier_stamped() {
        let mut p = VideoPacketizer::new(Some(Box::new(XorParityFec::new(5))));
        let frame = vec![3u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 6]; // 6 data fragments
        let opts = PacketizeOptions {
            keyframe: true,
            ..PacketizeOptions::default()
        };
        let frags = p.packetize(&frame, opts);
        // 6 data + ceil(6/5)=2 parity
        let data: Vec<_> = frags
            .iter()
            .filter(|f| !f.header.flags.contains(Flags::PARITY))
            .collect();
        let parity_count = frags
            .iter()
            .filter(|f| f.header.flags.contains(Flags::PARITY))
            .count();
        assert_eq!(data.len(), 6);
        assert_eq!(parity_count, 2);
        assert!(frags.iter().all(|f| f.header.frag_count == 8));
        assert!(data
            .iter()
            .all(|f| f.header.flags.contains(Flags::KEYFRAME)));
    }
}
