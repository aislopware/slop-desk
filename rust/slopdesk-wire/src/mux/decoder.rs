//! Incremental, streaming decoder turning arbitrary chunks of TCP bytes into whole [`MuxFrame`]
//! values — the direct analogue of [`crate::FrameDecoder`] one layer down.
//!
//! One `recv` may deliver half a mux frame, three frames, or a frame split across many reads.
//! [`MuxFrameDecoder`] buffers via [`append`](MuxFrameDecoder::append) and yields complete frames
//! via [`next_frame`](MuxFrameDecoder::next_frame), answering `Ok(None)` whenever no complete frame
//! is buffered yet — a partial frame is **not** an error.
//!
//! The cursor-and-lazy-compaction shape, the frame-size cap and the fail-stop poisoning are all the
//! same as [`crate::FrameDecoder`] and are documented there. One decoder per physical mux
//! connection.

use core::ops::Range;

use crate::error::Result;
use crate::framing::PrefixedReader;
use crate::mux::envelope::MuxFrame;

/// Streaming length-prefixed mux-envelope decoder.
///
/// The buffer, the cursor, the fail-stop poisoning and the compaction schedule are
/// [`PrefixedReader`]'s, shared with [`crate::FrameDecoder`] — they were the same rule written
/// twice, and the two copies had already drifted. What is left here is what a mux envelope MEANS.
#[derive(Debug, Clone, Default)]
pub struct MuxFrameDecoder {
    reader: PrefixedReader,
}

impl MuxFrameDecoder {
    /// A fresh decoder with an empty buffer.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            reader: PrefixedReader::new(),
        }
    }

    /// Appends a freshly received chunk. Safe with empty input, one byte, or many frames' worth.
    ///
    /// Dropped entirely once the decoder is poisoned — the buffer was freed at the fault, so a peer
    /// that keeps feeding a dead connection cannot grow it without bound.
    pub fn append(&mut self, data: &[u8]) {
        self.reader.append(data);
    }

    /// Bytes currently buffered. Lets a caller assert a poisoned decoder cannot be grown.
    #[must_use]
    pub const fn buffered_byte_count(&self) -> usize {
        self.reader.buffered_byte_count()
    }

    /// The next complete mux frame, or `Ok(None)` when a full frame is not yet buffered.
    ///
    /// # Errors
    /// [`WireError::FrameTooLarge`](crate::error::WireError::FrameTooLarge) when a length prefix
    /// exceeds [`MAX_FRAME_PAYLOAD_LENGTH`](crate::MAX_FRAME_PAYLOAD_LENGTH), or any fault from
    /// [`MuxFrame::decode`]. Once either happens the same fault is returned by every later call.
    pub fn next_frame(&mut self) -> Result<Option<MuxFrame>> {
        Ok(self.next_inner(false)?.map(|(frame, _)| frame))
    }

    /// The next complete mux frame with its opaque payload LEFT in the buffer, answered as a range
    /// into it.
    ///
    /// The reason is [`MuxFrame::ChannelData`], whose body is an inner terminal frame the mux layer
    /// never parses: going through [`next_frame`](Self::next_frame) copies it into a `Vec` that
    /// exists only to be copied out of again. The range is valid until the next
    /// [`append`](Self::append) or decode call, and [`payload_bytes`](Self::payload_bytes) reads it
    /// back.
    ///
    /// # Errors
    /// The same faults as [`next_frame`](Self::next_frame), and with the same fail-stop.
    pub fn next_frame_leaving_payload(&mut self) -> Result<Option<(MuxFrame, Range<usize>)>> {
        self.next_inner(true)
    }

    /// The bytes a range from [`next_frame_leaving_payload`](Self::next_frame_leaving_payload)
    /// names. Empty if the range no longer describes buffered bytes.
    #[must_use]
    pub fn payload_bytes(&self, payload: &Range<usize>) -> &[u8] {
        self.reader.bytes(payload)
    }

    /// One frame, either whole or with its payload left where it lies.
    fn next_inner(&mut self, elide: bool) -> Result<Option<(MuxFrame, Range<usize>)>> {
        self.reader.next_payload(elide, |inner| {
            if elide {
                MuxFrame::decode_leaving_payload(inner)
            } else {
                MuxFrame::decode(inner).map(|frame| (frame, 0..0))
            }
        })
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::MuxFrameDecoder;
    use crate::MAX_FRAME_PAYLOAD_LENGTH;
    use crate::error::WireError;
    use crate::framing::COMPACTION_THRESHOLD;
    use crate::mux::envelope::{MuxCloseReason, MuxFrame};

    fn sample_frames() -> Vec<MuxFrame> {
        vec![
            MuxFrame::ChannelOpen {
                channel_id: 1,
                session_id: [7; 16],
                last_received_seq: 0,
                channel_class: 0,
                initial_cwd: Some("/tmp/partial ✅".to_owned()),
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 1,
                accepted: true,
                resume_from_seq: 12,
            },
            MuxFrame::ChannelData {
                channel_id: 1,
                payload: b"an inner frame's bytes".to_vec(),
            },
            MuxFrame::WindowAdjust {
                channel_id: 1,
                bytes_to_add: 65_536,
            },
            MuxFrame::ChannelClose {
                channel_id: 1,
                reason: MuxCloseReason::SubscriberEvicted,
            },
        ]
    }

    fn concatenated(frames: &[MuxFrame]) -> Vec<u8> {
        let mut out = Vec::new();
        for f in frames {
            out.extend_from_slice(&f.encode());
        }
        out
    }

    fn drain_all(decoder: &mut MuxFrameDecoder) -> Vec<MuxFrame> {
        let mut out = Vec::new();
        while let Some(f) = decoder.next_frame().expect("no decode fault") {
            out.push(f);
        }
        out
    }

    #[test]
    fn a_stream_delivered_one_byte_at_a_time_decodes_identically() {
        let frames = sample_frames();
        let combined = concatenated(&frames);
        let mut decoder = MuxFrameDecoder::new();
        let mut collected = Vec::new();
        for &byte in &combined {
            decoder.append(&[byte]);
            collected.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(collected, frames);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn many_frames_in_one_append_all_come_back() {
        let frames = sample_frames();
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&concatenated(&frames));
        assert_eq!(drain_all(&mut decoder), frames);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn an_oversized_length_prefix_faults_before_the_body_is_waited_for() {
        let oversized = MAX_FRAME_PAYLOAD_LENGTH + 1;
        let mut decoder = MuxFrameDecoder::new();
        #[expect(clippy::cast_possible_truncation, reason = "the cap is far below u32::MAX")]
        decoder.append(&(oversized as u32).to_be_bytes());
        assert_eq!(decoder.next_frame(), Err(WireError::FrameTooLarge(oversized)));
    }

    #[test]
    fn a_prefix_exactly_at_the_cap_waits_rather_than_faulting() {
        let mut decoder = MuxFrameDecoder::new();
        #[expect(clippy::cast_possible_truncation, reason = "the cap is far below u32::MAX")]
        decoder.append(&(MAX_FRAME_PAYLOAD_LENGTH as u32).to_be_bytes());
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn a_128_kib_data_payload_round_trips() {
        let payload: Vec<u8> = (0..(128 * 1024))
            .map(|i| u8::try_from(i & 0xFF).unwrap_or(0))
            .collect();
        let frame = MuxFrame::ChannelData {
            channel_id: 3,
            payload,
        };
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&frame.encode());
        assert_eq!(decoder.next_frame().unwrap(), Some(frame));
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn a_frame_missing_its_last_byte_waits_instead_of_misparsing() {
        let full = MuxFrame::WindowAdjust {
            channel_id: 5,
            bytes_to_add: 4096,
        }
        .encode();
        let (head, tail) = full.split_at(full.len() - 1);
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(head);
        assert_eq!(decoder.next_frame().unwrap(), None);
        assert_eq!(
            decoder.next_frame().unwrap(),
            None,
            "asking twice must not consume anything"
        );
        decoder.append(tail);
        assert_eq!(
            decoder.next_frame().unwrap(),
            Some(MuxFrame::WindowAdjust {
                channel_id: 5,
                bytes_to_add: 4096,
            })
        );
    }

    #[test]
    fn empty_and_sub_prefix_inputs_are_not_faults() {
        let mut decoder = MuxFrameDecoder::new();
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.append(&[]);
        assert_eq!(decoder.next_frame().unwrap(), None);
        decoder.append(&[0x00, 0x00]);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn a_poisoned_decoder_keeps_returning_the_same_fault_and_cannot_be_grown() {
        let mut decoder = MuxFrameDecoder::new();
        let mut frame = 5_u32.to_be_bytes().to_vec();
        frame.extend_from_slice(&1_u32.to_be_bytes());
        frame.push(0xFE); // no mux type carries this
        decoder.append(&frame);
        assert_eq!(decoder.next_frame(), Err(WireError::UnknownMessageType(0xFE)));
        // A well-formed frame after the fault must NOT decode: the byte-boundary is lost, so these
        // bytes are attacker-chosen as far as the connection is concerned.
        decoder.append(
            &MuxFrame::ChannelClose {
                channel_id: 1,
                reason: MuxCloseReason::Retired,
            }
            .encode(),
        );
        assert_eq!(decoder.next_frame(), Err(WireError::UnknownMessageType(0xFE)));
        decoder.append(&vec![0_u8; 1024 * 1024]);
        assert_eq!(
            decoder.buffered_byte_count(),
            0,
            "input after the fault is dropped, not held"
        );
    }

    fn small_frames(n: usize) -> (Vec<MuxFrame>, Vec<u8>) {
        let mut frames = Vec::with_capacity(n);
        let mut bytes = Vec::new();
        for i in 0..n {
            let f = MuxFrame::WindowAdjust {
                channel_id: u32::try_from(i).unwrap_or(0),
                bytes_to_add: 1,
            };
            bytes.extend_from_slice(&f.encode());
            frames.push(f);
        }
        (frames, bytes)
    }

    #[test]
    fn a_chunk_past_the_compaction_threshold_decodes_identically() {
        let (expected, bytes) = small_frames(8_000);
        assert!(
            bytes.len() > COMPACTION_THRESHOLD,
            "the test must actually cross the threshold"
        );
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&bytes);
        assert_eq!(drain_all(&mut decoder), expected);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }

    #[test]
    fn arbitrary_split_points_decode_identically() {
        let (expected, bytes) = small_frames(3_000);
        let mut decoder = MuxFrameDecoder::new();
        let mut collected = Vec::new();
        // 7-byte slices, so frames straddle append boundaries over and over.
        for chunk in bytes.chunks(7) {
            decoder.append(chunk);
            collected.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(collected, expected);
        assert_eq!(decoder.next_frame().unwrap(), None);
    }
}

#[cfg(test)]
mod eliding_tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::MuxFrameDecoder;
    use crate::framing::COMPACTION_THRESHOLD;
    use crate::mux::envelope::MuxFrame;

    /// The whole point of the eliding door: the range it answers has to name the payload's real
    /// bytes, and it has to keep doing so across the compaction the cursor triggers mid-burst.
    #[test]
    fn the_eliding_stream_answers_where_every_payload_sits_even_across_a_compaction() {
        let payloads: Vec<Vec<u8>> = (0..64u8)
            .map(|n| core::iter::repeat_n(n, 4096).collect())
            .collect();
        let mut decoder = MuxFrameDecoder::new();
        let mut seen = 0;
        for payload in &payloads {
            decoder.append(
                &MuxFrame::ChannelData {
                    channel_id: 3,
                    payload: payload.clone(),
                }
                .encode(),
            );
            while let Some((frame, run)) = decoder.next_frame_leaving_payload().expect("no decode fault") {
                assert!(matches!(frame, MuxFrame::ChannelData { .. }));
                assert_eq!(decoder.payload_bytes(&run), &payloads[seen][..]);
                seen += 1;
            }
        }
        assert_eq!(seen, payloads.len());
        assert!(
            payloads.len() * 4096 > COMPACTION_THRESHOLD,
            "the fixture has to cross the compaction threshold to prove anything",
        );
    }

    /// A fault reached through the eliding door poisons exactly as the whole-frame door does.
    #[test]
    fn a_fault_reached_through_the_eliding_door_still_poisons() {
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&[0x00, 0x00, 0x00, 0x06, 0, 0, 0, 1, 0x7F, 0x00]);
        assert!(decoder.next_frame_leaving_payload().is_err());
        decoder.append(
            &MuxFrame::WindowAdjust {
                channel_id: 1,
                bytes_to_add: 8,
            }
            .encode(),
        );
        assert!(decoder.next_frame().is_err(), "the fault must be permanent");
        assert_eq!(decoder.buffered_byte_count(), 0);
    }
}
