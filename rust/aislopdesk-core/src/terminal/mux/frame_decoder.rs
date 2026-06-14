//! Streaming splitter that turns arbitrary chunks of TCP bytes into whole [`MuxFrame`]
//! values
//!
//! — a port of Swift `AislopdeskProtocol.MuxFrameDecoder`, the direct analogue of
//! [`FrameDecoder`](crate::terminal::FrameDecoder) one layer up (mux envelopes instead of
//! terminal `WireMessage` frames).
//!
//! Same cursor + lazy-compaction discipline as [`FrameDecoder`](crate::terminal::FrameDecoder):
//! completed frames advance a read cursor rather than being front-removed, and the head is
//! compacted lazily, amortizing total work to O(bytes). One decoder per physical mux
//! connection.

use super::envelope::{MuxEnvelopeCodec, MuxFrame};
use crate::terminal::error::{Result, TerminalProtocolError};
use crate::terminal::MAX_FRAME_PAYLOAD_LENGTH;

/// Length of the big-endian `u32` mux-frame-length prefix.
const PREFIX_LENGTH: usize = 4;

/// Reclaim the consumed prefix once the read cursor has advanced past this many bytes.
const COMPACTION_THRESHOLD: usize = 64 * 1024;

/// Streaming mux-envelope decoder. Value type; intentionally not shared across tasks.
#[derive(Debug, Clone, Default)]
pub struct MuxFrameDecoder {
    buffer: Vec<u8>,
    read_offset: usize,
}

impl MuxFrameDecoder {
    /// A fresh decoder with an empty buffer.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends a freshly received chunk of bytes to the internal buffer.
    pub fn append(&mut self, data: &[u8]) {
        self.buffer.extend_from_slice(data);
    }

    /// Returns the next complete mux frame, or `Ok(None)` if a full frame is not yet
    /// buffered (the caller should `append` more bytes and retry).
    ///
    /// # Errors
    /// Returns [`TerminalProtocolError::FrameTooLarge`] if a length prefix exceeds
    /// [`MAX_FRAME_PAYLOAD_LENGTH`]; or any error from [`MuxEnvelopeCodec::decode`].
    pub fn next_frame(&mut self) -> Result<Option<MuxFrame>> {
        let available = self.buffer.len() - self.read_offset;
        if available < PREFIX_LENGTH {
            self.compact_consumed();
            return Ok(None);
        }

        let mux_frame_length = self.read_prefix() as usize;

        if mux_frame_length > MAX_FRAME_PAYLOAD_LENGTH {
            return Err(TerminalProtocolError::FrameTooLarge(mux_frame_length));
        }

        let frame_length = PREFIX_LENGTH + mux_frame_length;
        if available < frame_length {
            self.compact_consumed();
            return Ok(None);
        }

        let base = self.read_offset;
        let inner_start = base + PREFIX_LENGTH;
        let inner = self.buffer[inner_start..base + frame_length].to_vec();
        self.read_offset += frame_length;
        if self.read_offset >= COMPACTION_THRESHOLD {
            self.compact_consumed();
        }

        MuxEnvelopeCodec::decode(&inner).map(Some)
    }

    fn compact_consumed(&mut self) {
        if self.read_offset > 0 {
            self.buffer.drain(..self.read_offset);
            self.read_offset = 0;
        }
    }

    fn read_prefix(&self) -> u32 {
        let base = self.read_offset;
        u32::from_be_bytes([
            self.buffer[base],
            self.buffer[base + 1],
            self.buffer[base + 2],
            self.buffer[base + 3],
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::session::SessionId;
    use crate::terminal::wire_message::WireMessage;

    fn sid(seed: u8) -> SessionId {
        let mut b = [0u8; 16];
        for (i, slot) in b.iter_mut().enumerate() {
            *slot = seed.wrapping_add(i as u8);
        }
        SessionId(b)
    }

    fn sample_frames() -> Vec<MuxFrame> {
        vec![
            MuxFrame::ChannelOpen {
                channel_id: 1,
                session_id: sid(8),
                last_received_seq: 7,
                channel_class: 0,
            },
            MuxFrame::ChannelData {
                channel_id: 1,
                payload: WireMessage::Output {
                    seq: 3,
                    bytes: "coalesced ✅".as_bytes().to_vec(),
                }
                .encode(),
            },
            MuxFrame::ChannelClose { channel_id: 1 },
        ]
    }

    fn concatenated(frames: &[MuxFrame]) -> Vec<u8> {
        let mut out = Vec::new();
        for f in frames {
            out.extend_from_slice(&MuxEnvelopeCodec::encode(f));
        }
        out
    }

    fn drain_all(decoder: &mut MuxFrameDecoder) -> Vec<MuxFrame> {
        let mut out = Vec::new();
        while let Some(f) = decoder.next_frame().expect("no decode error") {
            out.push(f);
        }
        out
    }

    #[test]
    fn two_frames_in_one_chunk_both_drain() {
        let two = vec![
            MuxFrame::ChannelOpenAck {
                channel_id: 3,
                accepted: true,
            },
            MuxFrame::WindowAdjust {
                channel_id: 3,
                bytes_to_add: 1024,
            },
        ];
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&concatenated(&two));
        assert_eq!(drain_all(&mut decoder), two);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn three_frames_in_one_append() {
        let frames = sample_frames();
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&concatenated(&frames));
        assert_eq!(drain_all(&mut decoder), frames);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn one_frame_split_across_two_appends() {
        let frame = MuxFrame::ChannelData {
            channel_id: 5,
            payload: b"split across appends".to_vec(),
        };
        let bytes = MuxEnvelopeCodec::encode(&frame);
        let split = bytes.len() / 2;
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&bytes[..split]);
        assert_eq!(decoder.next_frame().unwrap(), None, "first half: must wait");
        decoder.append(&bytes[split..]);
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn partial_length_prefix_buffered_then_completes() {
        let frame = MuxFrame::WindowAdjust {
            channel_id: 9,
            bytes_to_add: 42,
        };
        let bytes = MuxEnvelopeCodec::encode(&frame);
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&bytes[..2]); // only 2 of the 4 prefix bytes
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.append(&bytes[2..]);
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
    }

    #[test]
    fn partial_channel_id_prefix_buffered_then_completes() {
        let frame = MuxFrame::ChannelClose {
            channel_id: 0x1122_3344,
        };
        let bytes = MuxEnvelopeCodec::encode(&frame);
        let cut = 6; // prefix(4) + 2 of the 4 channelID bytes
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&bytes[..cut]);
        assert_eq!(
            decoder.next_frame().unwrap(),
            None,
            "header partial: must wait"
        );
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.append(&bytes[cut..]);
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
    }

    #[test]
    fn one_byte_at_a_time_drains_all_frames() {
        let frames = sample_frames();
        let combined = concatenated(&frames);
        let mut decoder = MuxFrameDecoder::new();
        let mut decoded = Vec::new();
        for &byte in &combined {
            decoder.append(&[byte]);
            decoded.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(decoded, frames);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn frame_too_large_throws() {
        let oversized = MAX_FRAME_PAYLOAD_LENGTH + 1;
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&(oversized as u32).to_be_bytes());
        assert_eq!(
            decoder.next_frame(),
            Err(TerminalProtocolError::FrameTooLarge(oversized))
        );
    }

    #[test]
    fn max_size_prefix_is_accepted_not_rejected() {
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&(MAX_FRAME_PAYLOAD_LENGTH as u32).to_be_bytes());
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn empty_and_short_inputs_wait() {
        let mut decoder = MuxFrameDecoder::new();
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.append(&[]);
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.append(&[0x00, 0x00]);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    // --- cursor + lazy-compaction (FrameDecoderCursorTests, mux side) ---

    fn small_mux_frames(n: usize) -> (Vec<MuxFrame>, Vec<u8>) {
        let mut frames = Vec::with_capacity(n);
        let mut bytes = Vec::new();
        for i in 0..n {
            // channelClose is the smallest mux frame (empty body) — maximal fragmentation.
            let f = MuxFrame::ChannelClose {
                channel_id: (i % 64 + 1) as u32,
            };
            bytes.extend_from_slice(&MuxEnvelopeCodec::encode(&f));
            frames.push(f);
        }
        (frames, bytes)
    }

    #[test]
    fn decodes_many_small_frames_identically_in_one_chunk() {
        let (expected, bytes) = small_mux_frames(12_000);
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&bytes);
        assert_eq!(drain_all(&mut decoder), expected);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn decodes_identically_across_arbitrary_splits() {
        let (expected, bytes) = small_mux_frames(3_000);
        let mut decoder = MuxFrameDecoder::new();
        let mut decoded = Vec::new();
        for chunk in bytes.chunks(5) {
            decoder.append(chunk);
            decoded.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(decoded, expected);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn scales_linearly_not_quadratically() {
        let small = drain_time(8_000);
        let large = drain_time(32_000);
        assert!(
            large / small.max(1e-9) < 8.0,
            "mux decode time must scale ~linearly (got {}× for 4× frames)",
            large / small
        );
    }

    fn drain_time(n: usize) -> f64 {
        let (_, bytes) = small_mux_frames(n);
        for _ in 0..2 {
            let mut d = MuxFrameDecoder::new();
            d.append(&bytes);
            while d.next_frame().unwrap().is_some() {}
        }
        let start = std::time::Instant::now();
        let mut d = MuxFrameDecoder::new();
        d.append(&bytes);
        while d.next_frame().unwrap().is_some() {}
        start.elapsed().as_secs_f64()
    }
}
