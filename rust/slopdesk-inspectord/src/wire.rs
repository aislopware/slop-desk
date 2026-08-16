//! The inspector's framed wire — the mirror of `Sources/SlopDeskInspector/InspectorWire.swift`.
//!
//! ```text
//! [ u32 BE payloadLength ][ u8 typeTag ][ body… ]
//! ```
//!
//! `payloadLength` counts the tag plus the body and excludes the four prefix bytes, capped at
//! [`MAX_FRAME_PAYLOAD`] — the same 16 MiB ceiling the terminal protocol uses. `Event` and
//! `Subscribe` bodies are JSON and 8-byte big-endian respectively; `KeepAlive` has no body.
//!
//! **A protocol's two ENDS are allowed to exist in two languages; its LOGIC is not.** This file
//! encodes what the client decodes and decodes what the client encodes, and nothing else. The wire
//! did not change when the inspector moved here and must not: a shipped client is the other end.
//!
//! Unlike the terminal hot path — manual binary, no JSON — the payload here is JSON, because the
//! event rate is per-turn rather than per-keystroke and the schema is rich and still evolving.

use std::fmt;

use crate::event::InspectorEvent;

/// The frame payload ceiling, matching `SlopDesk.maxFramePayloadLength`.
pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;

/// The 4-byte big-endian length prefix.
pub const PREFIX_LENGTH: usize = 4;

/// Reclaim the consumed prefix once the cursor passes this, so the buffer's wasted head stays
/// bounded during a burst. 64 KiB is the max single read chunk, so in the common case compaction
/// happens at most once per chunk received.
const COMPACTION_THRESHOLD: usize = 64 * 1024;

/// Type tag for an event frame.
const TAG_EVENT: u8 = 1;
/// Type tag for a keep-alive frame.
const TAG_KEEP_ALIVE: u8 = 2;
/// Type tag for a subscribe frame.
const TAG_SUBSCRIBE: u8 = 3;

/// One inspector wire message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireMessage {
    /// A structured event — the whole read-only stream, host → client.
    Event(Box<InspectorEvent>),
    /// Heartbeat, host → client, so a quiet run is not mistaken for a dead connection.
    KeepAlive,
    /// The client's only control: (re)send events from this absolute sequence number. `0` is a full
    /// replay. Read-only — it decides what the CLIENT receives, never anything the agent sees.
    Subscribe {
        /// The absolute sequence number to replay from.
        from_seq: i64,
    },
}

/// A decode failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodecError {
    /// The length prefix exceeded [`MAX_FRAME_PAYLOAD`]. Thrown from the PREFIX read, before any
    /// bytes are consumed, so the stream is framing-desynced and unrecoverable in band.
    FrameTooLarge(usize),
    /// The payload ended early.
    Truncated,
    /// A tag this build does not know.
    UnknownType(u8),
    /// A body that did not parse — a future or corrupt event.
    MalformedBody(String),
}

impl fmt::Display for CodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FrameTooLarge(length) => write!(formatter, "frame payload too large: {length}"),
            Self::Truncated => write!(formatter, "truncated frame"),
            Self::UnknownType(tag) => write!(formatter, "unknown frame type {tag}"),
            Self::MalformedBody(detail) => write!(formatter, "malformed body: {detail}"),
        }
    }
}

impl std::error::Error for CodecError {}

impl CodecError {
    /// Whether the stream can carry on after this.
    ///
    /// A bad PAYLOAD is recoverable — the frame's bytes were already consumed, so the boundary is
    /// intact and the next frame still decodes; one rogue event must not end the inspector for the
    /// session. A bad LENGTH PREFIX is not: nothing was consumed, so every subsequent read is
    /// garbage and the connection has to be rebuilt.
    #[must_use]
    pub const fn is_recoverable(&self) -> bool {
        !matches!(self, Self::FrameTooLarge(_))
    }
}

/// Encodes one message into a complete frame.
///
/// # Errors
/// [`CodecError::FrameTooLarge`] when the encoded body exceeds [`MAX_FRAME_PAYLOAD`] — an event
/// whose JSON is over 16 MiB is dropped by the caller rather than desyncing the peer's framing.
pub fn encode(message: &WireMessage) -> Result<Vec<u8>, CodecError> {
    let mut body = Vec::new();
    match message {
        WireMessage::Event(event) => {
            body.push(TAG_EVENT);
            serde_json::to_writer(&mut body, event.as_ref())
                .map_err(|error| CodecError::MalformedBody(error.to_string()))?;
        },
        WireMessage::KeepAlive => body.push(TAG_KEEP_ALIVE),
        WireMessage::Subscribe { from_seq } => {
            body.push(TAG_SUBSCRIBE);
            body.extend_from_slice(&from_seq.to_be_bytes());
        },
    }

    if body.len() > MAX_FRAME_PAYLOAD {
        return Err(CodecError::FrameTooLarge(body.len()));
    }

    let length = u32::try_from(body.len()).map_err(|_| CodecError::FrameTooLarge(body.len()))?;
    let mut frame = Vec::with_capacity(PREFIX_LENGTH + body.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(&body);
    Ok(frame)
}

/// What the CLIENT end reads out of a payload, without reading the body.
///
/// The client parses an event's JSON into its own model, so the only thing it needs from this crate
/// is which frame arrived and where its body sits. Answering with a RANGE rather than a value is
/// what lets the body stay in the caller's buffer instead of being copied to be handed back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientFrame {
    /// An event; the range covers its JSON body inside the payload that was passed in.
    Event(core::ops::Range<usize>),
    /// A keep-alive, which has no body.
    KeepAlive,
}

/// Splits one payload the way the CLIENT end reads it: the tag, and where the body is.
///
/// Tag 3 is the client's OWN control. Seeing it arrive means the daemon echoed the client's
/// control back, which is not a frame this end has any reading for, so it is refused as unknown
/// rather than decoded — the same asymmetry [`decode`] has in the other direction.
///
/// # Errors
/// [`CodecError::Truncated`] for an empty payload, [`CodecError::UnknownType`] for a tag this end
/// does not read.
pub fn decode_client(payload: &[u8]) -> Result<ClientFrame, CodecError> {
    let (tag, _) = payload.split_first().ok_or(CodecError::Truncated)?;
    match *tag {
        TAG_EVENT => Ok(ClientFrame::Event(1..payload.len())),
        TAG_KEEP_ALIVE => Ok(ClientFrame::KeepAlive),
        unknown => Err(CodecError::UnknownType(unknown)),
    }
}

/// Decodes one whole payload — the type tag included, the length prefix already stripped.
///
/// # Errors
/// [`CodecError::Truncated`] for an empty or short payload, [`CodecError::UnknownType`] for a tag
/// this build does not know, [`CodecError::MalformedBody`] for a body that does not parse.
pub fn decode(payload: &[u8]) -> Result<WireMessage, CodecError> {
    let (tag, body) = payload.split_first().ok_or(CodecError::Truncated)?;
    match *tag {
        TAG_EVENT => {
            serde_json::from_slice::<InspectorEvent>(body)
                .map(|event| WireMessage::Event(Box::new(event)))
                .map_err(|error| CodecError::MalformedBody(format!("event JSON: {error}")))
        },
        TAG_KEEP_ALIVE => Ok(WireMessage::KeepAlive),
        TAG_SUBSCRIBE => {
            let bytes: [u8; 8] = body.try_into().map_err(|_| CodecError::Truncated)?;
            Ok(WireMessage::Subscribe {
                from_seq: i64::from_be_bytes(bytes),
            })
        },
        unknown => Err(CodecError::UnknownType(unknown)),
    }
}

/// Reassembles whole frames from arbitrary byte chunks.
///
/// Completed frames are NOT removed per parse: a front-removal memmoves the entire tail forward,
/// which is O(n) per frame and O(n²) for a chunk of many small ones — exactly the shape a full
/// history replay produces on reconnect. A cursor advances past consumed frames instead and the
/// head is compacted lazily, amortising the total work to O(bytes).
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
    /// Leading bytes already consumed by completed frames but not yet physically removed.
    read_offset: usize,
}

impl FrameDecoder {
    /// An empty decoder.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds received bytes.
    pub fn append(&mut self, data: &[u8]) {
        self.buffer.extend_from_slice(data);
    }

    /// The next complete message, or `None` when more bytes are needed.
    ///
    /// # Errors
    /// [`CodecError::FrameTooLarge`] on a bad length prefix (framing desync — the caller must give
    /// up on the connection), or any per-payload error from [`decode`], which IS recoverable: the
    /// frame's bytes are consumed before its payload is parsed, so the next call resumes cleanly at
    /// the following frame boundary.
    pub fn next_message(&mut self) -> Result<Option<WireMessage>, CodecError> {
        self.next_payload()?
            .map_or(Ok(None), |payload| decode(&payload).map(Some))
    }

    /// The next complete payload — the tag included, the length prefix stripped — or `None` when
    /// more bytes are needed.
    ///
    /// This is the splitter itself; [`next_message`](Self::next_message) is it plus [`decode`]. A
    /// caller that parses the body into its own model asks for the payload and does the rest, which
    /// is what the client end does: there is one frame splitter here, not one per model.
    ///
    /// # Errors
    /// [`CodecError::FrameTooLarge`] on a bad length prefix — a framing desync the caller cannot
    /// recover from in band.
    pub fn next_payload(&mut self) -> Result<Option<Vec<u8>>, CodecError> {
        let Some(payload_length) = self.peek_payload_len()? else {
            self.compact();
            return Ok(None);
        };

        let frame_length = PREFIX_LENGTH + payload_length;
        let start = self.read_offset + PREFIX_LENGTH;
        let payload = self
            .buffer
            .get(start..self.read_offset + frame_length)
            .ok_or(CodecError::Truncated)?
            .to_vec();
        // Consume BEFORE handing the payload back, so a body that does not parse leaves the frame
        // boundary intact and the next call resumes cleanly.
        self.read_offset += frame_length;
        if self.read_offset >= COMPACTION_THRESHOLD {
            self.compact();
        }

        Ok(Some(payload))
    }

    /// How many bytes are buffered, the consumed head included — the assertion that a drained
    /// decoder is empty.
    #[must_use]
    pub const fn buffered_len(&self) -> usize {
        self.buffer.len()
    }

    /// How long the next complete payload is, WITHOUT consuming it, or `None` when a whole frame is
    /// not yet buffered.
    ///
    /// The question a caller with a fixed buffer has to ask before it commits: a frame consumed
    /// into a buffer too small for it is a frame lost, and the answer here is what lets the caller
    /// grow first and read second. [`next_payload`](Self::next_payload) asks it too, so the prefix
    /// read and the cap check happen in one place.
    ///
    /// # Errors
    /// [`CodecError::FrameTooLarge`] on a length prefix over the cap — the framing desync, reported
    /// before anything is consumed, exactly as it would be by a read.
    pub fn peek_payload_len(&self) -> Result<Option<usize>, CodecError> {
        let available = self.buffer.len() - self.read_offset;
        if available < PREFIX_LENGTH {
            return Ok(None);
        }

        let payload_length = self.read_prefix()? as usize;
        if payload_length > MAX_FRAME_PAYLOAD {
            return Err(CodecError::FrameTooLarge(payload_length));
        }

        if available < PREFIX_LENGTH + payload_length {
            return Ok(None);
        }
        Ok(Some(payload_length))
    }

    /// Drops the consumed prefix once — the single memmove that replaces the per-frame one.
    fn compact(&mut self) {
        if self.read_offset == 0 {
            return;
        }
        self.buffer.drain(..self.read_offset);
        self.read_offset = 0;
    }

    /// Reads the length prefix at the cursor without consuming it, so an incomplete frame leaves it
    /// in place for the next call.
    fn read_prefix(&self) -> Result<u32, CodecError> {
        let bytes: [u8; PREFIX_LENGTH] = self
            .buffer
            .get(self.read_offset..self.read_offset + PREFIX_LENGTH)
            .ok_or(CodecError::Truncated)?
            .try_into()
            .map_err(|_| CodecError::Truncated)?;
        Ok(u32::from_be_bytes(bytes))
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{CodecError, FrameDecoder, MAX_FRAME_PAYLOAD, PREFIX_LENGTH, WireMessage, decode, encode};
    use crate::event::InspectorEvent;

    fn sample_event() -> InspectorEvent {
        InspectorEvent::UnknownLine {
            raw: "a line".to_owned(),
        }
    }

    #[test]
    fn the_frame_layout_is_a_big_endian_prefix_then_the_tag() {
        let frame = encode(&WireMessage::KeepAlive).expect("encodes");
        assert_eq!(frame, vec![0, 0, 0, 1, 2]);

        let frame = encode(&WireMessage::Subscribe { from_seq: 1 }).expect("encodes");
        assert_eq!(frame, vec![0, 0, 0, 9, 3, 0, 0, 0, 0, 0, 0, 0, 1]);
    }

    #[test]
    fn a_negative_from_seq_survives_the_round_trip() {
        for seq in [0_i64, -1, i64::MIN, i64::MAX] {
            let frame = encode(&WireMessage::Subscribe { from_seq: seq }).expect("encodes");
            let payload = frame.get(PREFIX_LENGTH..).expect("has a payload");
            assert_eq!(decode(payload), Ok(WireMessage::Subscribe { from_seq: seq }));
        }
    }

    #[test]
    fn an_event_round_trips_through_a_frame() {
        let message = WireMessage::Event(Box::new(sample_event()));
        let frame = encode(&message).expect("encodes");
        let payload = frame.get(PREFIX_LENGTH..).expect("has a payload");
        assert_eq!(decode(payload), Ok(message));
    }

    #[test]
    fn an_empty_payload_is_truncated_not_a_panic() {
        assert_eq!(decode(&[]), Err(CodecError::Truncated));
    }

    #[test]
    fn a_short_subscribe_body_is_truncated() {
        assert_eq!(decode(&[3, 0, 0]), Err(CodecError::Truncated));
    }

    #[test]
    fn an_unknown_tag_is_reported_and_recoverable() {
        let error = decode(&[99]).expect_err("an unknown tag fails");
        assert_eq!(error, CodecError::UnknownType(99));
        assert!(error.is_recoverable());
    }

    #[test]
    fn a_malformed_event_body_is_recoverable_but_a_bad_prefix_is_not() {
        let malformed = decode(&[1, b'{']).expect_err("bad JSON fails");
        assert!(malformed.is_recoverable());
        assert!(!CodecError::FrameTooLarge(1).is_recoverable());
    }

    #[test]
    fn frames_split_across_chunks_reassemble() {
        let frame = encode(&WireMessage::Event(Box::new(sample_event()))).expect("encodes");
        let mut decoder = FrameDecoder::new();
        for byte in &frame {
            // One byte at a time — every partial state must be `Ok(None)`, never an error.
            let pending = decoder.next_message().expect("a partial frame is not an error");
            assert!(pending.is_none());
            decoder.append(&[*byte]);
        }
        let message = decoder.next_message().expect("decodes").expect("a whole frame");
        assert_eq!(message, WireMessage::Event(Box::new(sample_event())));
        assert!(decoder.next_message().expect("no error").is_none());
        assert_eq!(
            decoder.buffered_len(),
            0,
            "a drained splitter has compacted its consumed head away"
        );
    }

    #[test]
    fn many_frames_in_one_chunk_all_drain_in_order() {
        let mut chunk = Vec::new();
        for index in 0..500_i64 {
            chunk.extend_from_slice(&encode(&WireMessage::Subscribe { from_seq: index }).expect("encodes"));
        }
        let mut decoder = FrameDecoder::new();
        decoder.append(&chunk);
        for index in 0..500_i64 {
            assert_eq!(
                decoder.next_message().expect("decodes"),
                Some(WireMessage::Subscribe { from_seq: index })
            );
        }
        assert!(decoder.next_message().expect("no error").is_none());
    }

    #[test]
    fn a_bad_payload_does_not_desync_the_frames_after_it() {
        let mut chunk = Vec::new();
        // A well-framed frame whose body is not valid event JSON.
        chunk.extend_from_slice(&[0, 0, 0, 2, 1, b'{']);
        chunk.extend_from_slice(&encode(&WireMessage::KeepAlive).expect("encodes"));

        let mut decoder = FrameDecoder::new();
        decoder.append(&chunk);
        let error = decoder.next_message().expect_err("the bad body fails");
        assert!(error.is_recoverable());
        assert_eq!(
            decoder.next_message().expect("the next frame still decodes"),
            Some(WireMessage::KeepAlive)
        );
    }

    #[test]
    fn an_oversized_length_prefix_is_rejected_before_any_allocation() {
        let mut decoder = FrameDecoder::new();
        let bogus = u32::try_from(MAX_FRAME_PAYLOAD).expect("fits") + 1;
        decoder.append(&bogus.to_be_bytes());
        let error = decoder.next_message().expect_err("rejected");
        assert!(!error.is_recoverable());
    }
}
