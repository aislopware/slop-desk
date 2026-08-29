//! The PATH-4 wire — the CLIENT's end of it, the mirror of [`crate::protocol`].
//!
//! [`protocol`](crate::protocol) decodes the client→host types (1–5) and encodes the host→client
//! types (6–9). This does the exact opposite and nothing else: it encodes a [`Request`] and decodes
//! a [`Reply`], plus the incremental frame splitter a client needs to turn arbitrary TCP chunks
//! back into whole replies. Two ENDS of one protocol is the only duplication the tree allows; the
//! same capability twice is not, which is why there is no request decoder or reply encoder here.
//!
//! ## Why it lives in dropd's crate
//! Because then the round-trip is a TEST. While the client end was Swift it lived in its own
//! module, a module away from the receiver, and nothing asserted that what one wrote the other
//! would read — the two agreed by review. Here
//! `encode_request_payload` and `decode_request` sit in one crate and a test walks every frame type
//! through both.

use crate::protocol::{DecodeError, MAX_FRAME_PAYLOAD, Reader, Reply, Request, push_string};

/// Upload body chunk size the client sends, well under [`MAX_FRAME_PAYLOAD`]. 256 KiB keeps
/// per-chunk latency low while amortising the framing overhead.
pub const CHUNK_BYTE_COUNT: usize = 256 * 1024;

/// The full framed bytes for `request`: `[u32 BE payload length][u8 type][body]`.
///
/// A chunk body is bounded by [`CHUNK_BYTE_COUNT`] at the call site, so the length always fits.
#[must_use]
pub fn encode_request_frame(request: &Request) -> Vec<u8> {
    let payload = encode_request_payload(request);
    let mut frame = Vec::with_capacity(4 + payload.len());
    push_frame_prefix(&mut frame, payload.len());
    frame.extend_from_slice(&payload);
    frame
}

/// The exact size of the frame a chunk body of `body_len` bytes rides in.
///
/// The one length a caller is allowed to know before it has the frame, and the reason is the FFI's
/// calling convention: a caller asks for the size, allocates, then asks for the bytes. Sizing a
/// chunk by BUILDING it would copy 256 KiB to learn a number that is two additions, and the copy
/// would be paid four thousand times per gigabyte uploaded. Every other frame is small enough that
/// building it twice costs nothing, so no other frame gets this.
#[must_use]
pub const fn chunk_frame_len(body_len: usize) -> usize {
    FRAME_PREFIX + CHUNK_PAYLOAD_HEADER + body_len
}

/// Writes the whole frame for one chunk into `out`, whose length must be at least
/// [`chunk_frame_len`]. Answers `false`, having written nothing past what fit, if it is not.
///
/// This is what a client with a body already in hand calls: the body is copied ONCE, from wherever
/// the caller holds it into the buffer that goes to the socket. [`encode_request_payload`]'s chunk
/// arm reaches the same writer through [`push_chunk_payload`], so there is one encoder for type 3.
pub fn write_chunk_frame(out: &mut [u8], transfer_id: u32, data: &[u8]) -> bool {
    let Ok(payload_len) = u32::try_from(CHUNK_PAYLOAD_HEADER + data.len()) else {
        return false;
    };
    let Some(prefix) = out.get_mut(..FRAME_PREFIX) else {
        return false;
    };
    prefix.copy_from_slice(&payload_len.to_be_bytes());
    out.get_mut(FRAME_PREFIX..)
        .is_some_and(|rest| write_chunk_payload(rest, transfer_id, data))
}

/// The bytes a frame spends on its length prefix.
const FRAME_PREFIX: usize = 4;

/// The bytes a chunk payload spends before its body: the type and the transfer id.
const CHUNK_PAYLOAD_HEADER: usize = 1 + 4;

/// Writes the `[u32 BE payload length]` a frame opens with.
fn push_frame_prefix(out: &mut Vec<u8>, payload_len: usize) {
    out.extend_from_slice(&u32::try_from(payload_len).unwrap_or(u32::MAX).to_be_bytes());
}

/// Writes a chunk payload — `[u8 3][u32 BE transferId][body]` — into the head of `out`.
fn write_chunk_payload(out: &mut [u8], transfer_id: u32, data: &[u8]) -> bool {
    let Some(head) = out.get_mut(..CHUNK_PAYLOAD_HEADER) else {
        return false;
    };
    let Some((kind, id)) = head.split_first_mut() else {
        return false;
    };
    *kind = 3;
    id.copy_from_slice(&transfer_id.to_be_bytes());
    let Some(body) = out.get_mut(CHUNK_PAYLOAD_HEADER..CHUNK_PAYLOAD_HEADER + data.len()) else {
        return false;
    };
    body.copy_from_slice(data);
    true
}

/// Appends a chunk payload to `out`, through the writer the borrowing path uses.
///
/// The owned path pays a zero-fill the borrowing one does not; it is the path taken by a caller who
/// already chose to own the body, which is not the path a 256 KiB upload takes.
fn push_chunk_payload(out: &mut Vec<u8>, transfer_id: u32, data: &[u8]) {
    let start = out.len();
    out.resize(start + CHUNK_PAYLOAD_HEADER + data.len(), 0);
    if let Some(room) = out.get_mut(start..) {
        write_chunk_payload(room, transfer_id, data);
    }
}

/// The payload only (`[u8 type][body]`), for callers that frame separately.
///
/// [`Request::HostBound`] encodes to nothing: it is the decoder's name for a host→client type that
/// arrived on the wrong side, and a client has no business spelling one.
#[must_use]
pub fn encode_request_payload(request: &Request) -> Vec<u8> {
    let mut out = Vec::new();
    match *request {
        Request::Hello { version } => {
            out.push(1);
            out.push(version);
        },
        Request::Offer {
            transfer_id,
            file_size,
            ref name,
        } => {
            out.push(2);
            out.extend_from_slice(&transfer_id.to_be_bytes());
            out.extend_from_slice(&file_size.to_be_bytes());
            push_string(&mut out, name);
        },
        Request::Chunk {
            transfer_id,
            ref data,
        } => push_chunk_payload(&mut out, transfer_id, data),
        Request::Finish { transfer_id } => {
            out.push(4);
            out.extend_from_slice(&transfer_id.to_be_bytes());
        },
        Request::Cancel { transfer_id } => {
            out.push(5);
            out.extend_from_slice(&transfer_id.to_be_bytes());
        },
        Request::HostBound => {},
    }
    out
}

/// Decodes one reply payload (`[u8 type][body]`).
///
/// Types 1–5 are the CLIENT's own vocabulary. Seeing one arrive means the peer is not a dropd, so
/// they are rejected as unknown rather than decoded into something to ignore — the opposite of the
/// tolerance [`Request::HostBound`] extends in the other direction, and deliberately: a confused
/// client costs an upload, a peer that is not dropd at all costs a file written somewhere unknown.
///
/// # Errors
/// [`DecodeError`] on an empty, truncated, unknown-type or non-UTF-8 payload.
pub fn decode_reply_payload(payload: &[u8]) -> Result<Reply, DecodeError> {
    let mut reader = Reader::new(payload);
    match reader.u8()? {
        6 => {
            Ok(Reply::HelloAck {
                accepted: reader.u8()? != 0,
            })
        },
        7 => {
            Ok(Reply::Accept {
                transfer_id: reader.u32()?,
            })
        },
        8 => {
            Ok(Reply::Complete {
                transfer_id: reader.u32()?,
            })
        },
        9 => {
            Ok(Reply::Failed {
                transfer_id: reader.u32()?,
                reason: reader.string()?,
            })
        },
        other => Err(DecodeError::UnknownType(other)),
    }
}

/// Why the frame splitter gave up.
#[expect(
    variant_size_differences,
    reason = "the whole enum is two machine words; boxing the length to even the variants out would put an \
              allocation on the path taken when a peer is already misbehaving"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameError {
    /// A length prefix exceeded [`MAX_FRAME_PAYLOAD`] — refused before allocating or waiting.
    FrameTooLarge(usize),
    /// The payload behind a complete length prefix would not decode.
    Decode(DecodeError),
}

impl core::fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match *self {
            Self::FrameTooLarge(bytes) => write!(formatter, "frame payload of {bytes} bytes over the cap"),
            Self::Decode(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for FrameError {}

/// The incremental splitter that turns arbitrary TCP chunks into whole [`Reply`] values.
///
/// A partial frame is NOT an error: [`next_reply`](Self::next_reply) answers `Ok(None)` and waits
/// for more bytes. A decode fault POISONS the decoder — the byte boundary for the whole stream is
/// lost, so every later byte is untrustworthy. Further [`append`](Self::append) is dropped and
/// `next_reply` re-reports the original fault: fail-stop, never resynchronise onto attacker bytes.
///
/// One decoder per physical connection.
#[derive(Debug, Clone, Default)]
pub struct ReplyFrameDecoder {
    buffer: Vec<u8>,
    read_offset: usize,
    fault: Option<FrameError>,
}

impl ReplyFrameDecoder {
    /// The length prefix's width.
    const PREFIX_LEN: usize = 4;
    /// How many consumed bytes may accumulate before the head is compacted away.
    const COMPACTION_THRESHOLD: usize = 64 * 1024;

    /// A decoder with an empty buffer.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            buffer: Vec::new(),
            read_offset: 0,
            fault: None,
        }
    }

    /// Appends a freshly received chunk.
    ///
    /// A no-op once poisoned. The buffer was cleared at the fault, so a peer that holds the socket
    /// open cannot grow it without bound.
    pub fn append(&mut self, chunk: &[u8]) {
        if self.fault.is_none() {
            self.buffer.extend_from_slice(chunk);
        }
    }

    /// How many bytes are buffered — the assertion that a poisoned decoder cannot be grown.
    #[must_use]
    pub const fn buffered_len(&self) -> usize {
        self.buffer.len()
    }

    /// Whether a fault has poisoned this decoder.
    #[must_use]
    pub const fn is_poisoned(&self) -> bool {
        self.fault.is_some()
    }

    /// The next complete reply, or `Ok(None)` when a whole frame is not yet buffered.
    ///
    /// # Errors
    /// [`FrameError`] on an over-cap length prefix or a malformed payload. The same error is
    /// re-reported by every later call.
    pub fn next_reply(&mut self) -> Result<Option<Reply>, FrameError> {
        if let Some(fault) = self.fault {
            return Err(fault);
        }

        let available = self.buffer.len().saturating_sub(self.read_offset);
        if available < Self::PREFIX_LEN {
            self.compact_consumed();
            return Ok(None);
        }

        let payload_len = self.read_prefix();
        if payload_len > MAX_FRAME_PAYLOAD {
            return Err(self.poison(FrameError::FrameTooLarge(payload_len)));
        }

        let frame_len = Self::PREFIX_LEN + payload_len;
        if available < frame_len {
            self.compact_consumed();
            return Ok(None);
        }

        let start = self.read_offset + Self::PREFIX_LEN;
        let payload = self
            .buffer
            .get(start..self.read_offset + frame_len)
            .unwrap_or(&[])
            .to_vec();
        self.read_offset += frame_len;
        if self.read_offset >= Self::COMPACTION_THRESHOLD {
            self.compact_consumed();
        }

        match decode_reply_payload(&payload) {
            Ok(reply) => Ok(Some(reply)),
            Err(error) => Err(self.poison(FrameError::Decode(error))),
        }
    }

    /// Records the fault and drops the buffer, so the fail-stop cannot be starved into an OOM.
    fn poison(&mut self, error: FrameError) -> FrameError {
        self.fault = Some(error);
        self.buffer = Vec::new();
        self.read_offset = 0;
        error
    }

    /// Drops the already-consumed head, keeping the cursor arithmetic honest.
    fn compact_consumed(&mut self) {
        if self.read_offset > 0 {
            self.buffer.drain(..self.read_offset);
            self.read_offset = 0;
        }
    }

    /// The big-endian length prefix at the cursor. Zero when the buffer is somehow short, which the
    /// caller has already ruled out.
    fn read_prefix(&self) -> usize {
        let bytes = self
            .buffer
            .get(self.read_offset..self.read_offset + Self::PREFIX_LEN)
            .and_then(|slice| <[u8; 4]>::try_from(slice).ok())
            .unwrap_or([0; 4]);
        u32::from_be_bytes(bytes) as usize
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        CHUNK_BYTE_COUNT, FRAME_PREFIX, FrameError, ReplyFrameDecoder, chunk_frame_len, decode_reply_payload,
        encode_request_frame, encode_request_payload, write_chunk_frame,
    };
    use crate::protocol::{
        DecodeError, MAX_FRAME_PAYLOAD, Reply, Request, VERSION, decode_request, encode_reply_frame,
        encode_reply_payload,
    };

    /// Every client→host frame, so the round-trip test covers the whole vocabulary.
    fn every_request() -> Vec<Request> {
        vec![
            Request::Hello { version: VERSION },
            Request::Offer {
                transfer_id: 7,
                file_size: 4096,
                name: "réport final.pdf".to_owned(),
            },
            Request::Chunk {
                transfer_id: 7,
                data: vec![0xDE, 0xAD, 0xBE, 0xEF],
            },
            Request::Chunk {
                transfer_id: 7,
                data: Vec::new(),
            },
            Request::Finish { transfer_id: 7 },
            Request::Cancel { transfer_id: 7 },
        ]
    }

    /// Every host→client frame.
    fn every_reply() -> Vec<Reply> {
        vec![
            Reply::HelloAck { accepted: true },
            Reply::HelloAck { accepted: false },
            Reply::Accept { transfer_id: 7 },
            Reply::Complete { transfer_id: 7 },
            Reply::Failed {
                transfer_id: 7,
                reason: "disk full".to_owned(),
            },
        ]
    }

    #[test]
    fn what_this_end_encodes_the_other_end_decodes() {
        for request in every_request() {
            let payload = encode_request_payload(&request);
            assert_eq!(decode_request(&payload), Ok(request.clone()), "{request:?}");
        }
    }

    #[test]
    fn what_the_other_end_encodes_this_end_decodes() {
        for reply in every_reply() {
            let payload = encode_reply_payload(&reply);
            assert_eq!(decode_reply_payload(&payload), Ok(reply.clone()), "{reply:?}");
        }
    }

    #[test]
    fn a_request_frame_carries_its_payload_length_first() {
        let body = b"a body the caller keeps";
        let mut borrowed = vec![0u8; chunk_frame_len(body.len())];
        assert!(write_chunk_frame(&mut borrowed, 11, body));
        let owned = encode_request_frame(&Request::Chunk {
            transfer_id: 11,
            data: body.to_vec(),
        });
        assert_eq!(borrowed, owned, "the borrowing chunk encoder is the same encoder");
        let mut tiny = vec![0u8; FRAME_PREFIX];
        assert!(
            !write_chunk_frame(&mut tiny, 11, body),
            "a buffer too small to hold the frame is refused, not half-filled"
        );

        let frame = encode_request_frame(&Request::Finish { transfer_id: 9 });
        let (prefix, payload) = frame.split_at(4);
        assert_eq!(
            u32::from_be_bytes(prefix.try_into().expect("four bytes")) as usize,
            payload.len()
        );
        assert_eq!(payload, [4, 0, 0, 0, 9]);
    }

    #[test]
    fn a_host_bound_request_encodes_to_nothing_because_a_client_cannot_spell_one() {
        assert!(encode_request_payload(&Request::HostBound).is_empty());
    }

    #[test]
    fn a_client_bound_type_arriving_as_a_reply_is_rejected_rather_than_ignored() {
        for kind in 1..=5_u8 {
            assert_eq!(
                decode_reply_payload(&[kind, 0, 0, 0, 1]),
                Err(DecodeError::UnknownType(kind)),
                "{kind}"
            );
        }
    }

    #[test]
    fn an_empty_or_truncated_reply_payload_is_named_as_such() {
        assert_eq!(decode_reply_payload(&[]), Err(DecodeError::Empty));
        assert_eq!(decode_reply_payload(&[7, 0, 0]), Err(DecodeError::Truncated));
        // A reason whose length prefix outruns the body.
        assert_eq!(
            decode_reply_payload(&[9, 0, 0, 0, 1, 0, 40, b'n', b'o']),
            Err(DecodeError::Truncated)
        );
    }

    #[test]
    fn a_reason_that_is_not_utf8_is_named_as_such() {
        assert_eq!(
            decode_reply_payload(&[9, 0, 0, 0, 1, 0, 1, 0xFF]),
            Err(DecodeError::BadUtf8)
        );
    }

    #[test]
    fn the_splitter_reassembles_replies_across_arbitrary_chunk_boundaries() {
        let stream: Vec<u8> = every_reply().iter().flat_map(encode_reply_frame).collect();
        for chunk_size in [1, 2, 3, 7, 64, stream.len()] {
            let mut decoder = ReplyFrameDecoder::new();
            let mut seen = Vec::new();
            for chunk in stream.chunks(chunk_size) {
                decoder.append(chunk);
                while let Some(reply) = decoder.next_reply().expect("a well-formed stream") {
                    seen.push(reply);
                }
            }
            assert_eq!(seen, every_reply(), "at chunk size {chunk_size}");
        }
    }

    #[test]
    fn a_partial_frame_waits_rather_than_failing() {
        let frame = encode_reply_frame(&Reply::Accept { transfer_id: 3 });
        let mut decoder = ReplyFrameDecoder::new();
        for byte in frame.iter().take(frame.len() - 1) {
            decoder.append(&[*byte]);
            assert_eq!(decoder.next_reply(), Ok(None));
        }
        decoder.append(frame.last().map_or(&[][..], core::slice::from_ref));
        assert_eq!(decoder.next_reply(), Ok(Some(Reply::Accept { transfer_id: 3 })));
    }

    #[test]
    fn an_oversize_length_prefix_is_refused_before_the_body_is_waited_for() {
        let mut decoder = ReplyFrameDecoder::new();
        let too_large = u32::try_from(MAX_FRAME_PAYLOAD + 1).expect("inside u32");
        decoder.append(&too_large.to_be_bytes());
        assert_eq!(
            decoder.next_reply(),
            Err(FrameError::FrameTooLarge(MAX_FRAME_PAYLOAD + 1))
        );
    }

    #[test]
    fn a_fault_poisons_the_decoder_and_a_peer_cannot_grow_it_afterwards() {
        let mut decoder = ReplyFrameDecoder::new();
        // A complete frame whose payload names a client-bound type.
        decoder.append(&[0, 0, 0, 2, 3, 0]);
        let first = decoder.next_reply();
        assert_eq!(first, Err(FrameError::Decode(DecodeError::UnknownType(3))));
        assert!(decoder.is_poisoned());
        assert_eq!(decoder.buffered_len(), 0);

        // Every later call re-reports the ORIGINAL fault, and appends are dropped on the floor.
        decoder.append(&vec![0_u8; 4096]);
        assert_eq!(decoder.buffered_len(), 0);
        assert_eq!(decoder.next_reply(), first);
    }

    #[test]
    fn the_consumed_head_is_compacted_so_a_long_stream_does_not_grow_without_bound() {
        let frame = encode_reply_frame(&Reply::Complete { transfer_id: 1 });
        let mut decoder = ReplyFrameDecoder::new();
        for _ in 0..20_000 {
            decoder.append(&frame);
            while decoder.next_reply().expect("well-formed").is_some() {}
        }
        assert!(
            decoder.buffered_len() < ReplyFrameDecoder::COMPACTION_THRESHOLD,
            "buffered {} bytes",
            decoder.buffered_len()
        );
    }

    #[test]
    fn a_chunk_the_client_sends_fits_the_frame_cap_with_room_to_spare() {
        let frame = encode_request_frame(&Request::Chunk {
            transfer_id: 1,
            data: vec![0; CHUNK_BYTE_COUNT],
        });
        assert!(frame.len() - 4 <= MAX_FRAME_PAYLOAD);
    }

    #[test]
    fn a_name_longer_than_the_length_prefix_can_hold_is_truncated_not_trapped() {
        let payload = encode_request_payload(&Request::Offer {
            transfer_id: 1,
            file_size: 1,
            name: "a".repeat(usize::from(u16::MAX) + 10),
        });
        let decoded = decode_request(&payload).expect("still decodes");
        assert_eq!(decoded, Request::Offer {
            transfer_id: 1,
            file_size: 1,
            name: "a".repeat(usize::from(u16::MAX)),
        });
    }
}
