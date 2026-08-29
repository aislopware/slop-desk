//! Incremental, streaming decoder turning arbitrary chunks of TCP bytes into whole
//! [`WireMessage`] values.
//!
//! TCP is a byte stream with no message boundaries: one read may deliver half a frame, three
//! frames, or a frame split across many reads. [`FrameDecoder`] buffers raw bytes via
//! [`append`](FrameDecoder::append) and yields complete messages via
//! [`next_message`](FrameDecoder::next_message), answering `Ok(None)` whenever no complete frame is
//! buffered yet — a partial frame is **not** an error, it is the normal case.
//!
//! ## Why a cursor instead of removing each frame
//! Removing a completed frame from the front memmoves the whole tail forward: O(n) per frame, O(n²)
//! for one chunk carrying many small frames. Instead a read cursor advances past consumed frames
//! and the head is compacted LAZILY — on a drain that returns `None`, or once the cursor crosses
//! [`COMPACTION_THRESHOLD`](crate::framing::COMPACTION_THRESHOLD) — amortising total work to
//! O(bytes). One decoder per channel per
//! connection.
//!
//! ## Fail-stop
//! A decode fault loses the byte-boundary for the whole channel stream, so no later byte can be
//! trusted to START a frame. A poisoned decoder therefore DROPS all further input and keeps
//! returning the fault, rather than resynchronising onto attacker-chosen bytes. This is the one
//! place the resurrected code was behind: poisoning postdates the retirement, and was translated
//! from the Swift `FrameDecoder` that used to sit over this one through a handle. `docs/63` G.4
//! deleted that handle — the client's receive path is `slopdesk-clientnet`'s now and frames a
//! channel's bytes on this side of the boundary — so this is the only frame decoder there is.

use core::ops::Range;

use crate::error::Result;
use crate::framing::PrefixedReader;
use crate::message::WireMessage;

/// Streaming length-prefixed frame decoder.
///
/// Carries mutable buffer state for a single receive loop and is deliberately not shared across
/// tasks. The buffer, the cursor, the poisoning and the compaction schedule are
/// [`PrefixedReader`]'s — this type is what a framed payload MEANS, and nothing else. The mux
/// envelope decoder is the same three lines over the same reader.
#[derive(Debug, Clone, Default)]
pub struct FrameDecoder {
    reader: PrefixedReader,
}

impl FrameDecoder {
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
    /// that keeps feeding a dead channel cannot grow it without bound.
    pub fn append(&mut self, data: &[u8]) {
        self.reader.append(data);
    }

    /// Bytes currently buffered. Lets a caller assert a poisoned decoder cannot be grown.
    #[must_use]
    pub const fn buffered_byte_count(&self) -> usize {
        self.reader.buffered_byte_count()
    }

    /// The next complete message, or `Ok(None)` when a full frame is not yet buffered (append more
    /// bytes and retry).
    ///
    /// # Errors
    /// [`WireError::FrameTooLarge`](crate::error::WireError::FrameTooLarge) when a length prefix
    /// exceeds [`MAX_FRAME_PAYLOAD_LENGTH`](crate::MAX_FRAME_PAYLOAD_LENGTH), or any fault from
    /// [`WireMessage::decode`] (unknown type, malformed or truncated body). Once either happens the
    /// same fault is returned by every later call.
    pub fn next_message(&mut self) -> Result<Option<WireMessage>> {
        Ok(self.next_inner(false)?.map(|(message, _)| message))
    }

    /// The next complete message WITHOUT its opaque byte run, and where that run sits in this
    /// decoder's own buffer.
    ///
    /// For the caller that is going to copy the run somewhere of its own anyway — the FFI boundary,
    /// whose Swift owner wants it as a `Data`. Handing back a span means an `.output` payload under
    /// a flood is copied once, out of here and into the caller, rather than once into the message
    /// and again out of it.
    ///
    /// The span is into memory this decoder owns and is void at the NEXT call on it, whichever call
    /// that is. Copy before you continue.
    ///
    /// # Errors
    /// The same faults as [`next_message`](Self::next_message), and with the same fail-stop.
    pub fn next_message_leaving_opaque_run(&mut self) -> Result<Option<(WireMessage, Range<usize>)>> {
        self.next_inner(true)
    }

    fn next_inner(&mut self, elide: bool) -> Result<Option<(WireMessage, Range<usize>)>> {
        self.reader.next_payload(elide, |payload| {
            if elide {
                WireMessage::decode_leaving_opaque_run(payload)
            } else {
                WireMessage::decode(payload).map(|message| (message, 0..0))
            }
        })
    }

    /// The bytes a span from
    /// [`next_message_leaving_opaque_run`](Self::next_message_leaving_opaque_run) names, for a
    /// caller in this address space. Empty for a span the buffer has since outlived.
    #[must_use]
    pub fn run_bytes(&self, run: &Range<usize>) -> &[u8] {
        self.reader.bytes(run)
    }
}

#[cfg(test)]
mod eliding_tests {
    #![expect(
        clippy::expect_used,
        reason = "a test that cannot get its fixture has already failed"
    )]

    use super::FrameDecoder;
    use crate::message::WireMessage;

    /// The two forms are one parser, and a streaming decoder is where a span can go stale without
    /// anybody noticing: the head is compacted mid-burst, so a run reported before a compaction and
    /// read after one would name the wrong bytes. This drives enough frames through to cross the
    /// threshold and checks every run against the copying form.
    #[test]
    fn the_eliding_stream_answers_where_every_run_sits_even_across_a_compaction() {
        let payload: Vec<u8> = (0..=255u8).cycle().take(4096).collect();
        let mut eliding = FrameDecoder::new();
        let mut copying = FrameDecoder::new();
        for seq in 0..64_i64 {
            let frame = WireMessage::Output {
                seq,
                bytes: payload.clone(),
            }
            .encode();
            eliding.append(&frame);
            copying.append(&frame);
        }
        for seq in 0..64_i64 {
            let (message, run) = eliding
                .next_message_leaving_opaque_run()
                .expect("the corpus decodes")
                .expect("a whole frame was appended");
            let expected = copying
                .next_message()
                .expect("the corpus decodes")
                .expect("a whole frame was appended");
            assert_eq!(message, WireMessage::Output {
                seq,
                bytes: Vec::new()
            });
            assert_eq!(
                eliding.run_bytes(&run),
                expected.opaque_run(),
                "run wrong at {seq}"
            );
        }
    }

    /// A poisoned decoder must fail-stop through the eliding door too — it is the door the FFI
    /// boundary uses, so a fault that only the other form reported would be a fault the whole
    /// product never sees.
    #[test]
    fn a_fault_reached_through_the_eliding_door_still_poisons() {
        let mut decoder = FrameDecoder::new();
        decoder.append(&[0xFF, 0xFF, 0xFF, 0xFF]);
        assert!(decoder.next_message_leaving_opaque_run().is_err());
        decoder.append(&WireMessage::Bye.encode());
        assert!(decoder.next_message_leaving_opaque_run().is_err());
        assert_eq!(decoder.buffered_byte_count(), 0);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::FrameDecoder;
    use crate::MAX_FRAME_PAYLOAD_LENGTH;
    use crate::error::WireError;
    use crate::framing::COMPACTION_THRESHOLD;
    use crate::message::WireMessage;

    fn sample_messages() -> Vec<WireMessage> {
        vec![
            WireMessage::Output {
                seq: 7,
                bytes: "partial-read test ✅".as_bytes().to_vec(),
            },
            WireMessage::Resize {
                cols: 120,
                rows: 40,
                px_width: 0,
                px_height: 0,
            },
            WireMessage::HelloAck {
                session_id: [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
                resume_from_seq: 9,
                returning_client: true,
            },
        ]
    }

    fn concatenated(messages: &[WireMessage]) -> Vec<u8> {
        let mut out = Vec::new();
        for m in messages {
            out.extend_from_slice(&m.encode());
        }
        out
    }

    fn drain_all(decoder: &mut FrameDecoder) -> Vec<WireMessage> {
        let mut out = Vec::new();
        while let Some(m) = decoder.next_message().expect("no decode fault") {
            out.push(m);
        }
        out
    }

    #[test]
    fn a_stream_delivered_one_byte_at_a_time_decodes_identically() {
        let messages = sample_messages();
        let combined = concatenated(&messages);
        let mut decoder = FrameDecoder::new();
        let mut collected = Vec::new();
        for &byte in &combined {
            decoder.append(&[byte]);
            collected.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(collected, messages);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn many_frames_in_one_append_all_come_back() {
        let messages = sample_messages();
        let mut decoder = FrameDecoder::new();
        decoder.append(&concatenated(&messages));
        assert_eq!(drain_all(&mut decoder), messages);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn an_oversized_length_prefix_faults_before_the_body_is_waited_for() {
        let oversized = MAX_FRAME_PAYLOAD_LENGTH + 1;
        let mut decoder = FrameDecoder::new();
        #[expect(clippy::cast_possible_truncation, reason = "the cap is far below u32::MAX")]
        decoder.append(&(oversized as u32).to_be_bytes());
        assert_eq!(decoder.next_message(), Err(WireError::FrameTooLarge(oversized)));
    }

    #[test]
    fn a_prefix_exactly_at_the_cap_waits_rather_than_faulting() {
        // The guard is `<=`. An off-by-one here would reject the largest legitimate frame.
        let mut decoder = FrameDecoder::new();
        #[expect(clippy::cast_possible_truncation, reason = "the cap is far below u32::MAX")]
        decoder.append(&(MAX_FRAME_PAYLOAD_LENGTH as u32).to_be_bytes());
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn a_multi_hundred_kb_payload_round_trips() {
        let big: Vec<u8> = (0..(256 * 1024))
            .map(|i| u8::try_from(i & 0xFF).unwrap_or(0))
            .collect();
        let message = WireMessage::Output { seq: 99, bytes: big };
        let mut decoder = FrameDecoder::new();
        decoder.append(&message.encode());
        assert_eq!(decoder.next_message().unwrap(), Some(message));
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn an_unknown_message_type_faults_with_the_offending_byte() {
        let mut frame = 1_u32.to_be_bytes().to_vec();
        frame.push(0xFF);
        let mut decoder = FrameDecoder::new();
        decoder.append(&frame);
        assert_eq!(decoder.next_message(), Err(WireError::UnknownMessageType(0xFF)));
    }

    #[test]
    fn a_frame_missing_its_last_byte_waits_instead_of_misparsing() {
        let full = WireMessage::Exit { code: 256 }.encode();
        let (head, tail) = full.split_at(full.len() - 1);
        let mut decoder = FrameDecoder::new();
        decoder.append(head);
        assert_eq!(decoder.next_message().unwrap(), None);
        assert_eq!(
            decoder.next_message().unwrap(),
            None,
            "asking twice must not consume anything"
        );
        decoder.append(tail);
        assert_eq!(
            decoder.next_message().unwrap(),
            Some(WireMessage::Exit { code: 256 })
        );
    }

    #[test]
    fn empty_and_sub_prefix_inputs_are_not_faults() {
        let mut decoder = FrameDecoder::new();
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(&[]);
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(&[0x00, 0x00]);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn a_complete_frame_survives_a_partial_frame_behind_it() {
        let first = WireMessage::Bell.encode();
        let second = WireMessage::Title("incomplete".to_owned()).encode();
        let (head, tail) = second.split_at(second.len() - 3);
        let mut decoder = FrameDecoder::new();
        decoder.append(&first);
        decoder.append(head);
        assert_eq!(decoder.next_message().unwrap(), Some(WireMessage::Bell));
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.append(tail);
        assert_eq!(
            decoder.next_message().unwrap(),
            Some(WireMessage::Title("incomplete".to_owned()))
        );
    }

    // --- fail-stop -------------------------------------------------------------------------- //

    #[test]
    fn a_poisoned_decoder_keeps_returning_the_same_fault() {
        let mut decoder = FrameDecoder::new();
        let mut frame = 1_u32.to_be_bytes().to_vec();
        frame.push(0xFF);
        decoder.append(&frame);
        assert_eq!(decoder.next_message(), Err(WireError::UnknownMessageType(0xFF)));
        // A well-formed frame after the fault must NOT decode: the byte-boundary is lost, so these
        // bytes are attacker-chosen as far as the stream is concerned.
        decoder.append(&WireMessage::Bell.encode());
        assert_eq!(decoder.next_message(), Err(WireError::UnknownMessageType(0xFF)));
    }

    #[test]
    fn a_poisoned_decoder_cannot_be_grown_without_bound() {
        let mut decoder = FrameDecoder::new();
        let mut frame = 1_u32.to_be_bytes().to_vec();
        frame.push(0xFF);
        decoder.append(&frame);
        drop(decoder.next_message());
        decoder.append(&vec![0_u8; 1024 * 1024]);
        assert_eq!(
            decoder.buffered_byte_count(),
            0,
            "input after the fault is dropped, not held"
        );
    }

    // --- cursor + lazy compaction ----------------------------------------------------------- //

    fn small_frames(n: usize) -> (Vec<WireMessage>, Vec<u8>) {
        let mut frames = Vec::with_capacity(n);
        let mut bytes = Vec::new();
        for i in 0..n {
            let lo = u8::try_from(i & 0xFF).unwrap_or(0);
            let hi = u8::try_from((i >> 8) & 0xFF).unwrap_or(0);
            let m = WireMessage::Output {
                seq: i64::try_from(i).unwrap_or(0) + 1,
                bytes: vec![lo, hi],
            };
            bytes.extend_from_slice(&m.encode());
            frames.push(m);
        }
        (frames, bytes)
    }

    #[test]
    fn a_chunk_past_the_compaction_threshold_decodes_identically() {
        let (expected, bytes) = small_frames(12_000);
        assert!(
            bytes.len() > COMPACTION_THRESHOLD,
            "the test must actually cross the threshold"
        );
        let mut decoder = FrameDecoder::new();
        decoder.append(&bytes);
        assert_eq!(drain_all(&mut decoder), expected);
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn arbitrary_split_points_decode_identically() {
        let (expected, bytes) = small_frames(3_000);
        let mut decoder = FrameDecoder::new();
        let mut collected = Vec::new();
        // 7-byte slices, so frames straddle append boundaries over and over.
        for chunk in bytes.chunks(7) {
            decoder.append(chunk);
            collected.append(&mut drain_all(&mut decoder));
        }
        assert_eq!(collected, expected);
        assert_eq!(decoder.next_message().unwrap(), None);
    }
}
