//! UDP-side mux foundation for the GUI video path — a port of Swift
//! `VideoMuxHeaderCodec` / `MuxFrameFragmentHeader`.
//!
//! A `u32` BE channelID prefix lets several logical lanes share one UDP socket. These
//! are NEW, additive types beside [`FrameFragment`](crate::fragment::FrameFragment); the
//! live transport does not yet construct them.
//!
//! ⚠️ Faithful-port note: Swift defines `MuxFrameFragmentHeader.size = channelIDLength +
//! FrameFragmentHeader.size = 4 + 19 = 23`, but its `encode`/`decode` only read/write a
//! 19-byte header (channelID + the pre-`hostSendTsMillis` fields, NO `host_send_ts`). The
//! `size` constant predates the `hostSendTsMillis` field being added to the standalone
//! header and was never reconciled — a harmless artifact because the type is unwired. We
//! reproduce the Swift constant value (23) AND the 19-byte wire exactly for parity.

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::Result;
use crate::fragment::{Flags, FrameFragmentHeader, VideoPacketizer};

/// Length of the big-endian `u32` channelID prefix that fronts a muxed datagram.
pub const CHANNEL_ID_LENGTH: usize = 4;

/// A bare `[u32 BE channelID][payload…]` prefix codec for opaque media/cursor lanes.
pub mod video_mux_header {
    use super::{ByteReader, ByteWriter, Result, CHANNEL_ID_LENGTH};

    /// Prepends `channel_id` to an opaque payload (carried verbatim).
    #[must_use]
    pub fn encode(channel_id: u32, payload: &[u8]) -> Vec<u8> {
        let mut w = ByteWriter::with_capacity(CHANNEL_ID_LENGTH + payload.len());
        w.put_u32(channel_id);
        w.put_bytes(payload);
        w.into_vec()
    }

    /// Splits a muxed datagram into its leading `channel_id` and the opaque remainder
    /// (a zero-copy borrow). Returns `Truncated` if fewer than 4 bytes are present.
    pub fn decode(datagram: &[u8]) -> Result<(u32, &[u8])> {
        let mut r = ByteReader::new(datagram);
        let channel_id = r.read_u32()?;
        Ok((channel_id, r.remaining()))
    }
}

/// A [`FrameFragmentHeader`]-shaped header carrying its lane's `channel_id` at offset 0.
/// The muxed sibling of the standalone header; additive and not yet wired.
///
/// Wire (19 bytes): `u32 channel_id · u32 stream_seq · u32 frame_id · u16 frag_index ·
/// u16 frag_count · u8 flags · u16 payload_len`. (No `host_send_ts_millis` — see the
/// module note.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MuxFrameFragmentHeader {
    /// The logical lane this fragment belongs to (offset 0).
    pub channel_id: u32,
    /// Monotonic per-datagram sequence number.
    pub stream_seq: u32,
    /// Groups fragments of one encoded video frame.
    pub frame_id: u32,
    /// 0-based index of this fragment within the frame.
    pub frag_index: u16,
    /// Total fragments in the frame.
    pub frag_count: u16,
    /// Fragment flags.
    pub flags: Flags,
    /// Bytes of payload that follow.
    pub payload_length: u16,
}

impl MuxFrameFragmentHeader {
    /// Header size constant as defined in Swift: `channelIDLength + FrameFragmentHeader
    /// .size` = `4 + 19 = 23`. See the module note: the ENCODED header is 19 bytes; this
    /// constant carries the historical artifact verbatim for parity.
    pub const SIZE: usize = CHANNEL_ID_LENGTH + FrameFragmentHeader::SIZE;

    /// Max payload bytes per fragment against [`SIZE`](Self::SIZE) (`1200 - 23 = 1177`),
    /// matching Swift's `maxPayloadSize`.
    pub const MAX_PAYLOAD_SIZE: usize = VideoPacketizer::MAX_DATAGRAM_SIZE - Self::SIZE;

    /// Serialises `header + payload` (channelID first, then the standalone field order,
    /// 19-byte header). The on-wire payload length is the actual payload byte count.
    #[must_use]
    pub fn encode(&self, payload: &[u8]) -> Vec<u8> {
        let mut w = ByteWriter::with_capacity(Self::SIZE + payload.len());
        w.put_u32(self.channel_id);
        w.put_u32(self.stream_seq);
        w.put_u32(self.frame_id);
        w.put_u16(self.frag_index);
        w.put_u16(self.frag_count);
        w.put_u8(self.flags.raw());
        debug_assert!(
            u16::try_from(payload.len()).is_ok(),
            "mux fragment payload exceeds u16"
        );
        w.put_u16(payload.len() as u16);
        w.put_bytes(payload);
        w.into_vec()
    }

    /// Parses one muxed datagram into `(header, payload)`. Trailing bytes beyond the
    /// declared payload length are ignored (matches Swift).
    pub fn decode(datagram: &[u8]) -> Result<(Self, Vec<u8>)> {
        let mut r = ByteReader::new(datagram);
        let channel_id = r.read_u32()?;
        let stream_seq = r.read_u32()?;
        let frame_id = r.read_u32()?;
        let frag_index = r.read_u16()?;
        let frag_count = r.read_u16()?;
        let flags = Flags(r.read_u8()?);
        let payload_length = r.read_u16()?;
        let payload = r.read_bytes(usize::from(payload_length))?.to_vec();
        Ok((
            Self {
                channel_id,
                stream_seq,
                frame_id,
                frag_index,
                frag_count,
                flags,
                payload_length,
            },
            payload,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_prefix_round_trip() {
        let bytes = video_mux_header::encode(0x0102_0304, &[9, 8, 7]);
        assert_eq!(bytes[..4], [1, 2, 3, 4]);
        let (channel_id, payload) = video_mux_header::decode(&bytes).unwrap();
        assert_eq!(channel_id, 0x0102_0304);
        assert_eq!(payload, &[9, 8, 7]);
    }

    #[test]
    fn bare_prefix_short_is_truncated() {
        assert!(video_mux_header::decode(&[1, 2, 3]).is_err());
    }

    #[test]
    fn muxed_header_round_trip_is_19_bytes() {
        let header = MuxFrameFragmentHeader {
            channel_id: 0xAABB_CCDD,
            stream_seq: 1,
            frame_id: 2,
            frag_index: 3,
            frag_count: 4,
            flags: Flags::KEYFRAME,
            payload_length: 2,
        };
        let bytes = header.encode(&[0xEE, 0xFF]);
        assert_eq!(bytes.len(), 19 + 2); // ENCODED header is 19 bytes (not SIZE=23)
        let (back, payload) = MuxFrameFragmentHeader::decode(&bytes).unwrap();
        assert_eq!(back, header);
        assert_eq!(payload, vec![0xEE, 0xFF]);
    }

    #[test]
    fn size_constant_matches_swift_artifact() {
        assert_eq!(MuxFrameFragmentHeader::SIZE, 23);
        assert_eq!(MuxFrameFragmentHeader::MAX_PAYLOAD_SIZE, 1177);
    }
}
