//! The UDP-side mux prefix — `Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift`.
//!
//! A big-endian `u32` channel id PREFIX that lets several logical lanes share one physical UDP
//! datagram socket, the way the terminal path's envelope codec lets several channels share one TCP
//! connection.
//!
//! Two shapes, both additive and both living BESIDE [`crate::fragment`]'s 19-byte header rather
//! than replacing it:
//!
//! * the bare `[u32 channel_id][rest]` prefix for the non-video media lanes — control, geometry —
//!   and the cursor socket. The rest is opaque and carried verbatim; this codec never inspects it.
//! * [`MuxFrameFragmentHeader`], for the high-rate video lane that wants the channel id folded into
//!   the per-fragment header rather than sitting in front of it.
//!
//! ```text
//! off 0: u32 channel_id   — the logical lane this fragment belongs to
//! off 4: u32 stream_seq
//! off 8: u32 frame_id
//! off12: u16 frag_index
//! off14: u16 frag_count
//! off16: u8  flags
//! off17: u16 payload_len
//! ```
//!
//! ## It does NOT carry the host timestamp, and that is why it is 19 bytes too
//!
//! The plain fragment header is also 19 bytes: 15 of fields plus a 4-byte `host_send_ts_millis`.
//! This one is 15 of the same fields plus a 4-byte channel id, with NO timestamp. Two different
//! layouts that happen to be the same size — reading one with the other's decoder would parse
//! cleanly and produce nonsense, so the sizes matching is a coincidence to be careful around, not a
//! compatibility.
//!
//! Pinned by the `muxBare` and `muxFragment` golden vectors.

use crate::bytes::{ByteReader, ByteWriter, truncating_u16};
use crate::error::Result;
use crate::fragment::{Flags, MAX_DATAGRAM_SIZE};

/// Length of the big-endian `u32` channel-id prefix that fronts a muxed datagram.
pub const CHANNEL_ID_LENGTH: usize = 4;

/// The prefix written straight into a caller's buffer: `[u32 channel_id][u8 tag?][payload]`.
///
/// Returns the bytes the framing NEEDS. An `out` shorter than that is left untouched, exactly as
/// the FFI's `(out, cap)` convention has it, so a caller may size with an empty slice first.
///
/// This is the layout, and [`encode`], [`encode_media`] and the FFI shim are all callers of it —
/// a datagram framed on the send path is not framed by a second copy of these four lines.
#[must_use]
pub fn encode_into(channel_id: u32, tag: Option<u8>, payload: &[u8], out: &mut [u8]) -> usize {
    let needed = CHANNEL_ID_LENGTH + usize::from(tag.is_some()) + payload.len();
    if out.len() < needed {
        return needed;
    }
    let (head, mut rest) = out.split_at_mut(CHANNEL_ID_LENGTH);
    head.copy_from_slice(&channel_id.to_be_bytes());
    if let Some(tag) = tag {
        let (slot, tail) = rest.split_at_mut(1);
        slot.copy_from_slice(&[tag]);
        rest = tail;
    }
    rest.get_mut(..payload.len())
        .unwrap_or_default()
        .copy_from_slice(payload);
    needed
}

/// Prepends `channel_id` to an opaque media or cursor payload. The payload is carried verbatim.
#[must_use]
pub fn encode(channel_id: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![0_u8; CHANNEL_ID_LENGTH + payload.len()];
    let _written = encode_into(channel_id, None, payload, &mut out);
    out
}

/// Frames a MEDIA-socket datagram in one pass: `[u32 channel_id][u8 tag][payload]`.
///
/// Byte-identical to [`encode`] over an intermediate `[tag][payload]` buffer — the shape both
/// transports used to build by hand — minus that intermediate copy.
#[must_use]
pub fn encode_media(channel_id: u32, tag: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![0_u8; CHANNEL_ID_LENGTH + 1 + payload.len()];
    let _written = encode_into(channel_id, Some(tag), payload, &mut out);
    out
}

/// Splits a muxed datagram into its leading channel id and the opaque remainder.
///
/// # Errors
/// [`crate::VideoProtocolError::Truncated`] when fewer than four bytes are present — a corrupt
/// single datagram must never crash the receiver.
pub fn decode(datagram: &[u8]) -> Result<(u32, &[u8])> {
    let mut reader = ByteReader::new(datagram);
    let channel_id = reader.read_u32()?;
    Ok((channel_id, reader.remaining()))
}

/// A fragment header carrying its lane's channel id at offset 0 — the muxed sibling of
/// [`crate::fragment::FrameFragmentHeader`].
///
/// The non-channel fields and their meanings are identical. Additive: the live video transport
/// still emits the plain header until the gated migration flips over.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MuxFrameFragmentHeader {
    /// The logical lane this fragment belongs to.
    pub channel_id: u32,
    /// Monotonic per-datagram sequence number.
    pub stream_seq: u32,
    /// Groups the fragments of one encoded frame.
    pub frame_id: u32,
    /// This fragment's 0-based index within the frame.
    pub frag_index: u16,
    /// Total fragments in the frame.
    pub frag_count: u16,
    /// The flag bits, shared verbatim with the plain header.
    pub flags: Flags,
    /// Bytes of payload that follow.
    pub payload_length: u16,
}

impl MuxFrameFragmentHeader {
    /// Header size in bytes, derived from this type's OWN field widths — it does NOT carry a host
    /// timestamp: 4 + 4 + 4 + 2 + 2 + 1 + 2.
    pub const SIZE: usize = 4 + 4 + 4 + 2 + 2 + 1 + 2;
    /// Max payload bytes per fragment against the muxed header.
    pub const MAX_PAYLOAD_SIZE: usize = MAX_DATAGRAM_SIZE - Self::SIZE;

    /// Builds a header.
    #[must_use]
    pub const fn new(
        channel_id: u32,
        stream_seq: u32,
        frame_id: u32,
        frag_index: u16,
        frag_count: u16,
        flags: Flags,
        payload_length: u16,
    ) -> Self {
        Self {
            channel_id,
            stream_seq,
            frame_id,
            frag_index,
            frag_count,
            flags,
            payload_length,
        }
    }

    /// The header and payload written straight into a caller's buffer, channel id first and then
    /// the plain header's field order. Returns the bytes needed; a short `out` is left untouched.
    #[must_use]
    pub fn encode_into(&self, payload: &[u8], out: &mut [u8]) -> usize {
        let needed = Self::SIZE + payload.len();
        if out.len() < needed {
            return needed;
        }
        let mut writer = ByteWriter::with_capacity(Self::SIZE);
        writer.put_u32(self.channel_id);
        writer.put_u32(self.stream_seq);
        writer.put_u32(self.frame_id);
        writer.put_u16(self.frag_index);
        writer.put_u16(self.frag_count);
        writer.put_u8(self.flags.bits());
        writer.put_u16(truncating_u16(payload.len()));
        let header = writer.into_vec();
        let (head, rest) = out.split_at_mut(Self::SIZE);
        head.copy_from_slice(&header);
        rest.get_mut(..payload.len())
            .unwrap_or_default()
            .copy_from_slice(payload);
        needed
    }

    /// Serialises header and payload into a fresh buffer.
    #[must_use]
    pub fn encode(&self, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![0_u8; Self::SIZE + payload.len()];
        let _written = self.encode_into(payload, &mut out);
        out
    }

    /// Parses one muxed datagram into its header and payload.
    ///
    /// # Errors
    /// [`crate::VideoProtocolError::Truncated`] on a short or inconsistent datagram — the same
    /// contract as [`crate::fragment::FrameFragment::decode`].
    pub fn decode(datagram: &[u8]) -> Result<(Self, Vec<u8>)> {
        let mut reader = ByteReader::new(datagram);
        let channel_id = reader.read_u32()?;
        let stream_seq = reader.read_u32()?;
        let frame_id = reader.read_u32()?;
        let frag_index = reader.read_u16()?;
        let frag_count = reader.read_u16()?;
        let flags = Flags::from_bits(reader.read_u8()?);
        let payload_length = reader.read_u16()?;
        let payload = reader.read_bytes(usize::from(payload_length))?.to_vec();
        Ok((
            Self::new(
                channel_id,
                stream_seq,
                frame_id,
                frag_index,
                frag_count,
                flags,
                payload_length,
            ),
            payload,
        ))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CHANNEL_ID_LENGTH, MuxFrameFragmentHeader, decode, encode, encode_media};
    use crate::error::VideoProtocolError;
    use crate::fragment::Flags;

    #[test]
    fn the_bare_prefix_round_trips_and_carries_the_payload_verbatim() {
        let framed = encode(0x0102_0304, &[9, 8, 7]);
        assert_eq!(framed, vec![1, 2, 3, 4, 9, 8, 7]);
        let (channel_id, payload) = decode(&framed).expect("four bytes are present");
        assert_eq!(channel_id, 0x0102_0304);
        assert_eq!(payload, &[9, 8, 7]);
    }

    #[test]
    fn an_empty_payload_is_legal_and_a_short_datagram_is_truncation() {
        let framed = encode(1, &[]);
        assert_eq!(framed.len(), CHANNEL_ID_LENGTH);
        assert!(decode(&framed).expect("still four bytes").1.is_empty());
        assert_eq!(decode(&[0, 0, 0]), Err(VideoProtocolError::Truncated));
    }

    #[test]
    fn the_media_shape_equals_the_bare_prefix_over_a_tag_payload_buffer() {
        // The one-pass form exists to skip an intermediate copy, not to change the bytes.
        let mut tagged = vec![6_u8];
        tagged.extend_from_slice(&[1, 2, 3]);
        assert_eq!(encode_media(77, 6, &[1, 2, 3]), encode(77, &tagged));
    }

    #[test]
    fn the_muxed_fragment_round_trips() {
        let header = MuxFrameFragmentHeader::new(0xAABB_CCDD, 1, 2, 3, 4, Flags::KEYFRAME, 2);
        let bytes = header.encode(&[0xEE, 0xFF]);
        assert_eq!(bytes.len(), MuxFrameFragmentHeader::SIZE + 2);
        let (decoded, payload) = MuxFrameFragmentHeader::decode(&bytes).expect("well-formed");
        assert_eq!(decoded, header);
        assert_eq!(payload, vec![0xEE, 0xFF]);
    }

    #[test]
    fn the_declared_size_matches_what_encode_writes() {
        assert_eq!(
            MuxFrameFragmentHeader::default().encode(&[]).len(),
            MuxFrameFragmentHeader::SIZE
        );
    }

    #[test]
    fn a_length_past_the_datagram_is_truncation() {
        let mut bytes = MuxFrameFragmentHeader::default().encode(&[1, 2]);
        bytes[17] = 0xFF;
        bytes[18] = 0xFF;
        assert_eq!(
            MuxFrameFragmentHeader::decode(&bytes),
            Err(VideoProtocolError::Truncated)
        );
    }
}
