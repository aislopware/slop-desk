//! The TCP mux envelope — the OUTER frame that carries many logical channels over one connection.
//!
//! ```text
//! [u32 BE mux_frame_length][u32 BE channel_id][u8 mux_type][body…]
//!  \____ excludes these 4 ___/\________ mux_frame_length counts these ________/
//! ```
//!
//! SSH's channel vocabulary, one layer above [`crate::WireMessage`]: `CHANNEL_OPEN` /
//! `CHANNEL_DATA` / `CHANNEL_CLOSE` / `CHANNEL_WINDOW_ADJUST`. A [`MuxFrame::ChannelData`] body is
//! an INNER `WireMessage` frame carried **opaquely** — nothing here parses it, which is what lets
//! one mux connection route panes and the workspace document without either knowing about the
//! other.
//!
//! Every decode is validate-then-drop: a hostile body can shorten a frame or name a type nobody
//! serves, and the answer is a [`WireError`], never an over-read and never a panic.

use core::ops::Range;

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, WireError};
use crate::message::{RawUuid, SESSION_ID_BYTE_COUNT};

/// Length of the big-endian `u32` mux-frame-length prefix.
pub const PREFIX_LENGTH: usize = 4;

/// Smallest legal `mux_frame_length`: `channel_id` (4) + `mux_type` (1).
///
/// The shortest frame there is — a default [`MuxFrame::ChannelClose`] — has an empty body.
pub const MIN_MUX_FRAME_LENGTH: usize = 4 + 1;

/// The mux-type byte selecting a frame's meaning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MuxFrameType {
    /// Initiator asks to open a new logical channel.
    ChannelOpen = 1,
    /// Responder accepts (or refuses) a channel open, and states its resume verdict.
    ChannelOpenAck = 2,
    /// Opaque application payload for an open channel — an inner `WireMessage` frame.
    ChannelData = 3,
    /// One side will send no more frames on the channel (SSH `CHANNEL_CLOSE`).
    ChannelClose = 4,
    /// Replenish a channel's flow-control window (SSH `CHANNEL_WINDOW_ADJUST`).
    WindowAdjust = 5,
}

impl MuxFrameType {
    /// The type for `byte`, or `None` when no mux frame carries it.
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::ChannelOpen),
            2 => Some(Self::ChannelOpenAck),
            3 => Some(Self::ChannelData),
            4 => Some(Self::ChannelClose),
            5 => Some(Self::WindowAdjust),
            _ => None,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// WHY a peer closed one channel — the half of a close that decides what the other end may do next.
///
/// Above the transport a close is a stream that ended, and the two reasons a host closes a PANE
/// channel demand opposite answers. Only the sender knows which it is, so the reason rides the
/// wire.
///
/// It is ADVICE about recovery, never permission to skip the teardown: every value closes the
/// channel identically. That is why an absent body and an unrecognised byte both read as
/// [`Self::Retired`] — the conservative reading, which withholds an automatic re-dial rather than
/// inventing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum MuxCloseReason {
    /// The channel names something the peer no longer has. Re-opening under the same session id is
    /// a fresh SPAWN, so nothing automatic may dial it again.
    #[default]
    Retired = 0,
    /// Only THIS subscriber's attachment ended — the pane, its shell and its other members are
    /// untouched. Re-opening is a reattach rather than a spawn; what it must not be is a reflex,
    /// because an instant re-dial re-joins to be evicted again.
    SubscriberEvicted = 1,
}

impl MuxCloseReason {
    /// The reason for `byte`, falling back to [`Self::Retired`] for anything unrecognised.
    ///
    /// Total on purpose: a close must always CLOSE, so an unknown byte from a newer peer may not
    /// throw and leave the channel open.
    #[must_use]
    pub const fn from_byte_or_retired(byte: u8) -> Self {
        match byte {
            1 => Self::SubscriberEvicted,
            _ => Self::Retired,
        }
    }

    /// The on-wire byte.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// One decoded TCP mux frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MuxFrame {
    /// Open `channel_id`, carrying a resume hint, a class selector, and an optional initial cwd.
    ChannelOpen {
        /// The logical channel being opened.
        channel_id: u32,
        /// The session this channel belongs to; all-zero opens a new one.
        session_id: RawUuid,
        /// Highest sequence number the initiator already holds, for the resume verdict.
        last_received_seq: i64,
        /// What the channel is FOR — see [`super::MuxChannelClass`]. Carried as a raw byte so a
        /// class this build does not serve decodes and is refused, rather than failing the frame.
        channel_class: u8,
        /// Working directory to spawn in, when the initiator has an opinion.
        initial_cwd: Option<String>,
    },
    /// Accept or refuse a channel open.
    ChannelOpenAck {
        /// The channel being answered for.
        channel_id: u32,
        /// Whether the responder will service the channel.
        accepted: bool,
        /// The HOST-authoritative resume verdict: 0 = fresh shell / nothing resumed; > 0 = the SAME
        /// live session was reattached and replay starts after this seq.
        resume_from_seq: i64,
    },
    /// OPAQUE inner `WireMessage` frame bytes.
    ChannelData {
        /// The channel the payload belongs to.
        channel_id: u32,
        /// The inner frame, carried verbatim.
        payload: Vec<u8>,
    },
    /// This side will send no more frames on the channel.
    ChannelClose {
        /// The channel being closed.
        channel_id: u32,
        /// The peer's statement of WHY.
        reason: MuxCloseReason,
    },
    /// Grant more flow-control credit.
    WindowAdjust {
        /// The channel being credited.
        channel_id: u32,
        /// Bytes of credit to add.
        bytes_to_add: u32,
    },
}

impl MuxFrame {
    /// The logical channel this frame addresses.
    #[must_use]
    pub const fn channel_id(&self) -> u32 {
        match *self {
            Self::ChannelOpen { channel_id, .. }
            | Self::ChannelOpenAck { channel_id, .. }
            | Self::ChannelData { channel_id, .. }
            | Self::ChannelClose { channel_id, .. }
            | Self::WindowAdjust { channel_id, .. } => channel_id,
        }
    }

    /// The on-wire mux-type byte for this frame.
    #[must_use]
    pub const fn mux_type(&self) -> MuxFrameType {
        match *self {
            Self::ChannelOpen { .. } => MuxFrameType::ChannelOpen,
            Self::ChannelOpenAck { .. } => MuxFrameType::ChannelOpenAck,
            Self::ChannelData { .. } => MuxFrameType::ChannelData,
            Self::ChannelClose { .. } => MuxFrameType::ChannelClose,
            Self::WindowAdjust { .. } => MuxFrameType::WindowAdjust,
        }
    }

    /// Encodes the complete envelope, ready to write to a socket.
    ///
    /// Built in ONE buffer — a placeholder prefix, then `[channel_id][mux_type][body…]`, then the
    /// prefix BACK-PATCHED. Encoding the body into a separate buffer first would memcpy an
    /// up-to-128 KiB [`Self::ChannelData`] payload twice under a flood, for nothing.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = ByteWriter::with_capacity(self.encoded_hint());
        self.encode_into(self.opaque_payload(), &mut out);
        out.into_vec()
    }

    /// Encodes into a buffer the CALLER owns, with the opaque payload supplied APART from the
    /// frame, and answers the size under the §4 convention: `n <= out.len()` wrote the envelope,
    /// `n > out.len()` left `out` unspecified and asks to be called again with that much room.
    ///
    /// The reason is [`Self::ChannelData`], which is the mux frame a flooding pane is made of:
    /// going through [`encode`](Self::encode) at an FFI boundary copies its payload three times —
    /// into the frame, into the encoder's `Vec`, out of that `Vec` into the caller's buffer.
    pub fn encode_with_payload_into(&self, payload: &[u8], out: &mut [u8]) -> usize {
        let needed = self.encoded_byte_count_with_payload(payload.len());
        if needed > out.len() {
            return needed;
        }
        let mut writer = ByteWriter::borrowing(out);
        self.encode_into(payload, &mut writer);
        writer.len()
    }

    /// The EXACT size [`encode_with_payload_into`](Self::encode_with_payload_into) will produce.
    ///
    /// Counted by running the encoder over a lent buffer of ZERO bytes rather than by a second
    /// table: the writer counts what it was asked for whether or not it had room, so the answer
    /// cannot drift from the layout the way a hand-written size arm can. The payload is the only
    /// verbatim field and nothing after it depends on its length, so it is added at the end.
    #[must_use]
    pub fn encoded_byte_count_with_payload(&self, payload_len: usize) -> usize {
        let mut counter = ByteWriter::borrowing(&mut []);
        self.encode_into(&[], &mut counter);
        counter.len().saturating_add(payload_len)
    }

    /// The frame's own opaque payload — empty for the arms that do not carry one.
    #[must_use]
    pub fn opaque_payload(&self) -> &[u8] {
        match *self {
            Self::ChannelData { ref payload, .. } => payload,
            _ => &[],
        }
    }

    fn encode_into(&self, payload: &[u8], out: &mut ByteWriter<'_>) {
        out.put_u32(0); // mux_frame_length placeholder, back-patched below
        out.put_u32(self.channel_id());
        out.put_u8(self.mux_type().as_byte());

        match self {
            Self::ChannelOpen {
                session_id,
                last_received_seq,
                channel_class,
                initial_cwd,
                ..
            } => {
                out.put_bytes(session_id);
                out.put_i64(*last_received_seq);
                out.put_u8(*channel_class);
                // The field is present only when the initiator HAS an opinion. An absent cwd is an
                // absent field, not a zero-length one, so the common open stays 30 bytes.
                if let Some(cwd) = initial_cwd.as_deref() {
                    // `put_length_prefixed_str` clamps at a `char` boundary, so the written length
                    // and the written bytes always agree even for a pathological path.
                    out.put_length_prefixed_str(cwd);
                }
            },
            Self::ChannelOpenAck {
                accepted,
                resume_from_seq,
                ..
            } => {
                out.put_bool(*accepted);
                out.put_i64(*resume_from_seq);
            },
            Self::ChannelData { .. } => out.put_bytes(payload),
            Self::ChannelClose { reason, .. } => {
                // `Retired` is the ABSENT body — the empty-bodied close every peer has always sent,
                // so the default path stays byte-identical and only a close that means something
                // else costs a byte. The decoder reads the absence back as `Retired`.
                if *reason != MuxCloseReason::Retired {
                    out.put_u8(reason.as_byte());
                }
            },
            Self::WindowAdjust { bytes_to_add, .. } => out.put_u32(*bytes_to_add),
        }

        // The prefix counts the inner run — everything after itself. A frame that somehow grew past
        // `u32::MAX` would be rejected by every decoder anyway; saturating keeps the arithmetic
        // total rather than trusting a cast.
        let inner_length = u32::try_from(out.len().saturating_sub(PREFIX_LENGTH)).unwrap_or(u32::MAX);
        out.patch_u32(0, inner_length);
    }

    /// A capacity guess for [`Self::encode`], so the common frame allocates exactly once.
    fn encoded_hint(&self) -> usize {
        let body = match self {
            Self::ChannelOpen { initial_cwd, .. } => {
                SESSION_ID_BYTE_COUNT + 8 + 1 + initial_cwd.as_ref().map_or(0, |c| 2 + c.len())
            },
            Self::ChannelOpenAck { .. } => 1 + 8,
            Self::ChannelData { payload, .. } => payload.len(),
            Self::ChannelClose { .. } => 1,
            Self::WindowAdjust { .. } => 4,
        };
        PREFIX_LENGTH + MIN_MUX_FRAME_LENGTH + body
    }

    /// Decodes a frame from a **complete inner run** (`[channel_id][mux_type][body…]`, without the
    /// length prefix — framing belongs to [`super::MuxFrameDecoder`]).
    ///
    /// # Errors
    /// [`WireError::Truncated`] when the body is shorter than the type requires,
    /// [`WireError::UnknownMessageType`] for an unrecognised mux-type byte, or
    /// [`WireError::MalformedBody`] for a right-length-but-invalid body.
    pub fn decode(inner: &[u8]) -> Result<Self> {
        Self::decode_inner(inner, &mut (0..0), false)
    }

    /// Decodes without materialising the frame's opaque payload, answering WHERE it sits in
    /// `inner` instead.
    ///
    /// For the caller that already holds the bytes — the FFI boundary, whose Swift owner wants the
    /// payload as its own `Data`. The returned frame's payload is EMPTY; the range names it.
    ///
    /// # Errors
    /// The same faults as [`decode`](Self::decode).
    pub fn decode_leaving_payload(inner: &[u8]) -> Result<(Self, Range<usize>)> {
        let mut run = 0..0;
        let frame = Self::decode_inner(inner, &mut run, true)?;
        Ok((frame, run))
    }

    fn decode_inner(inner: &[u8], run: &mut Range<usize>, elide: bool) -> Result<Self> {
        let mut reader = ByteReader::new(inner);
        let channel_id = reader.read_u32()?;
        let type_byte = reader.read_u8()?;
        let Some(mux_type) = MuxFrameType::from_byte(type_byte) else {
            return Err(WireError::UnknownMessageType(type_byte));
        };

        match mux_type {
            MuxFrameType::ChannelOpen => {
                let id_bytes = reader.read_bytes(SESSION_ID_BYTE_COUNT)?;
                let last_received_seq = reader.read_i64()?;
                let channel_class = reader.read_u8()?;
                // `read_bytes` already guaranteed the length, so this conversion cannot fail; it is
                // written as a fallible read rather than an unwrap so a future edit to the constant
                // could not panic a receive loop.
                let session_id: RawUuid = id_bytes
                    .try_into()
                    .map_err(|_| WireError::malformed("channelOpen: invalid sessionID bytes"))?;
                let initial_cwd = if reader.bytes_remaining() == 0 {
                    None
                } else {
                    let length = usize::from(reader.read_u16()?);
                    let bytes = reader.read_bytes(length)?;
                    if reader.bytes_remaining() != 0 {
                        return Err(WireError::malformed("channelOpen: trailing cwd bytes"));
                    }
                    // A zero-length field decodes as ABSENT, matching the encoder's "no opinion" —
                    // an empty cwd is not a directory to spawn in.
                    if length == 0 {
                        None
                    } else {
                        Some(
                            core::str::from_utf8(bytes)
                                .map_err(|_| WireError::malformed("channelOpen: invalid cwd UTF-8"))?
                                .to_owned(),
                        )
                    }
                };
                Ok(Self::ChannelOpen {
                    channel_id,
                    session_id,
                    last_received_seq,
                    channel_class,
                    initial_cwd,
                })
            },

            MuxFrameType::ChannelOpenAck => {
                let accepted = reader.read_bool()?;
                // `resume_from_seq` is decode-optional, on the `channelOpen` cwd discipline: absent
                // (a pre-resume encoder, or an old golden vector) reads as 0 — "nothing resumed".
                let resume_from_seq = if reader.bytes_remaining() == 0 {
                    0
                } else {
                    let seq = reader.read_i64()?;
                    if reader.bytes_remaining() != 0 {
                        return Err(WireError::malformed("channelOpenAck: trailing bytes"));
                    }
                    seq
                };
                Ok(Self::ChannelOpenAck {
                    channel_id,
                    accepted,
                    resume_from_seq,
                })
            },

            MuxFrameType::ChannelData => {
                let start = reader.position();
                let payload = reader.remaining();
                *run = start..start.saturating_add(payload.len());
                Ok(Self::ChannelData {
                    channel_id,
                    payload: if elide { Vec::new() } else { payload.to_vec() },
                })
            },

            MuxFrameType::ChannelClose => {
                // A close must always CLOSE: the reason only advises what may happen afterwards, so
                // neither an absent body (the default encoding) nor an unrecognised byte may throw
                // and leave the channel open. Trailing bytes PAST the reason are still malformed —
                // that is a framing fault, not an unknown value.
                if reader.bytes_remaining() == 0 {
                    return Ok(Self::ChannelClose {
                        channel_id,
                        reason: MuxCloseReason::Retired,
                    });
                }
                let reason_byte = reader.read_u8()?;
                if reader.bytes_remaining() != 0 {
                    return Err(WireError::malformed("channelClose: trailing bytes"));
                }
                Ok(Self::ChannelClose {
                    channel_id,
                    reason: MuxCloseReason::from_byte_or_retired(reason_byte),
                })
            },

            MuxFrameType::WindowAdjust => {
                Ok(Self::WindowAdjust {
                    channel_id,
                    bytes_to_add: reader.read_u32()?,
                })
            },
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        clippy::panic,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{MIN_MUX_FRAME_LENGTH, MuxCloseReason, MuxFrame, MuxFrameType, PREFIX_LENGTH};
    use crate::error::WireError;

    /// Strips the length prefix, the way `MuxFrameDecoder` hands an inner run to `decode`.
    fn round_trip(frame: &MuxFrame) -> MuxFrame {
        let bytes = frame.encode();
        let declared = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(
            usize::try_from(declared).unwrap(),
            bytes.len() - PREFIX_LENGTH,
            "the prefix must count exactly the inner run"
        );
        MuxFrame::decode(&bytes[PREFIX_LENGTH..]).expect("round trip decodes")
    }

    /// Every shape the envelope has, including the two whose body is conditionally absent.
    fn every_frame() -> Vec<MuxFrame> {
        vec![
            sample_open(None),
            sample_open(Some("/Volumes/Lacie/Workspace/oss/slop-desk")),
            sample_open(Some("")),
            MuxFrame::ChannelOpenAck {
                channel_id: 3,
                accepted: true,
                resume_from_seq: 4096,
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 3,
                accepted: false,
                resume_from_seq: 0,
            },
            MuxFrame::ChannelData {
                channel_id: 7,
                payload: (0..=255u8).cycle().take(4096).collect(),
            },
            MuxFrame::ChannelData {
                channel_id: 7,
                payload: Vec::new(),
            },
            MuxFrame::ChannelClose {
                channel_id: 2,
                reason: MuxCloseReason::Retired,
            },
            MuxFrame::ChannelClose {
                channel_id: 2,
                reason: MuxCloseReason::SubscriberEvicted,
            },
            MuxFrame::WindowAdjust {
                channel_id: 5,
                bytes_to_add: 65_536,
            },
        ]
    }

    #[test]
    fn writing_into_a_lent_buffer_is_byte_identical_to_encoding_into_a_vec() {
        for frame in every_frame() {
            let expected = frame.encode();
            let mut lent = vec![0xAA; expected.len()];
            let written = frame.encode_with_payload_into(frame.opaque_payload(), &mut lent);
            assert_eq!(written, expected.len(), "sized wrong for {frame:?}");
            assert_eq!(lent, expected, "wrote differently for {frame:?}");
        }
    }

    /// The size is counted by running the encoder over a zero-byte buffer, so this is what holds
    /// that trick honest — including for the close whose body is ABSENT by default and the open
    /// whose cwd is clamped at a `char` boundary.
    #[test]
    fn the_counted_size_is_the_size_that_gets_written() {
        for frame in every_frame() {
            assert_eq!(
                frame.encoded_byte_count_with_payload(frame.opaque_payload().len()),
                frame.encode().len(),
                "counted wrong for {frame:?}"
            );
        }
    }

    #[test]
    fn the_eliding_decode_answers_where_the_payload_actually_is() {
        for frame in every_frame() {
            let bytes = frame.encode();
            let inner = &bytes[PREFIX_LENGTH..];
            let (elided, run) = MuxFrame::decode_leaving_payload(inner).expect("the corpus decodes");
            let copying = MuxFrame::decode(inner).expect("the corpus decodes");
            assert_eq!(
                &inner[run.clone()],
                copying.opaque_payload(),
                "run wrong for {frame:?}"
            );
            assert!(elided.opaque_payload().is_empty(), "the eliding form kept a copy");
        }
    }

    fn sample_open(cwd: Option<&str>) -> MuxFrame {
        MuxFrame::ChannelOpen {
            channel_id: 9,
            session_id: [
                0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
                0x00,
            ],
            last_received_seq: -1,
            channel_class: 1,
            initial_cwd: cwd.map(str::to_owned),
        }
    }

    #[test]
    fn every_frame_shape_round_trips() {
        for frame in [
            sample_open(None),
            sample_open(Some("/Users/x/projects/slop desk ✅")),
            MuxFrame::ChannelOpenAck {
                channel_id: 7,
                accepted: true,
                resume_from_seq: 42,
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 5,
                accepted: false,
                resume_from_seq: 0,
            },
            MuxFrame::ChannelData {
                channel_id: 3,
                payload: vec![0, 1, 2, 3, 0xFF],
            },
            MuxFrame::ChannelData {
                channel_id: 4,
                payload: Vec::new(),
            },
            MuxFrame::ChannelClose {
                channel_id: 6,
                reason: MuxCloseReason::Retired,
            },
            MuxFrame::ChannelClose {
                channel_id: 6,
                reason: MuxCloseReason::SubscriberEvicted,
            },
            MuxFrame::WindowAdjust {
                channel_id: 1,
                bytes_to_add: u32::MAX,
            },
        ] {
            assert_eq!(round_trip(&frame), frame);
        }
    }

    #[test]
    fn a_default_close_carries_no_body_and_the_evicted_one_costs_a_byte() {
        let retired = MuxFrame::ChannelClose {
            channel_id: 6,
            reason: MuxCloseReason::Retired,
        }
        .encode();
        assert_eq!(retired.len(), PREFIX_LENGTH + MIN_MUX_FRAME_LENGTH);
        let evicted = MuxFrame::ChannelClose {
            channel_id: 6,
            reason: MuxCloseReason::SubscriberEvicted,
        }
        .encode();
        assert_eq!(evicted.len(), retired.len() + 1);
    }

    #[test]
    fn an_unrecognised_close_reason_still_closes() {
        // A close from a newer peer naming a reason this build has no name for must not be able to
        // leave the channel open.
        let mut inner = 6_u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelClose.as_byte());
        inner.push(0x7F);
        assert_eq!(MuxFrame::decode(&inner).unwrap(), MuxFrame::ChannelClose {
            channel_id: 6,
            reason: MuxCloseReason::Retired,
        });
    }

    #[test]
    fn trailing_bytes_past_a_close_reason_are_malformed() {
        // An unknown VALUE is tolerated; unknown FRAMING is not — the two are different faults.
        let mut inner = 6_u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelClose.as_byte());
        inner.extend_from_slice(&[1, 9]);
        assert!(matches!(
            MuxFrame::decode(&inner),
            Err(WireError::MalformedBody(_))
        ));
    }

    #[test]
    fn an_ack_without_a_resume_field_reads_as_nothing_resumed() {
        let mut inner = 3_u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelOpenAck.as_byte());
        inner.push(1);
        assert_eq!(MuxFrame::decode(&inner).unwrap(), MuxFrame::ChannelOpenAck {
            channel_id: 3,
            accepted: true,
            resume_from_seq: 0,
        });
    }

    #[test]
    fn any_non_zero_accepted_byte_is_true() {
        // The untrusted-bool rule: a byte off the wire is not a `bool`.
        let mut inner = 3_u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelOpenAck.as_byte());
        inner.push(0x5A);
        let MuxFrame::ChannelOpenAck { accepted, .. } = MuxFrame::decode(&inner).unwrap() else {
            panic!("an ack decodes as an ack");
        };
        assert!(accepted);
    }

    #[test]
    fn an_empty_cwd_encodes_present_and_decodes_absent() {
        // Recorded rather than fixed: the encoder writes a zero-length field for `Some("")` and the
        // decoder reads a zero-length field as `None`, because an empty cwd is not a directory to
        // spawn in. The asymmetry is the Swift's, and changing it would move bytes on the wire.
        let encoded = sample_open(Some("")).encode();
        assert_eq!(
            encoded.len(),
            sample_open(None).encode().len() + 2,
            "the empty field still costs its u16 length"
        );
        let MuxFrame::ChannelOpen { initial_cwd, .. } = MuxFrame::decode(&encoded[PREFIX_LENGTH..]).unwrap()
        else {
            panic!("an open decodes as an open");
        };
        assert_eq!(initial_cwd, None);
    }

    #[test]
    fn an_unknown_mux_type_faults_with_the_offending_byte() {
        let mut inner = 1_u32.to_be_bytes().to_vec();
        inner.push(0xFE);
        assert_eq!(MuxFrame::decode(&inner), Err(WireError::UnknownMessageType(0xFE)));
    }

    #[test]
    fn a_short_body_is_truncated_rather_than_over_read() {
        for inner in [
            vec![0, 0, 0],                                               // not even a channel id
            vec![0, 0, 0, 1],                                            // no type byte
            vec![0, 0, 0, 1, MuxFrameType::ChannelOpen.as_byte(), 0, 0], // open, no session id
            vec![0, 0, 0, 1, MuxFrameType::WindowAdjust.as_byte(), 0],   // adjust, short credit
            vec![0, 0, 0, 1, MuxFrameType::ChannelOpenAck.as_byte()],    // ack, no accepted byte
        ] {
            assert_eq!(MuxFrame::decode(&inner), Err(WireError::Truncated));
        }
    }

    #[test]
    fn a_cwd_length_longer_than_the_body_is_truncated() {
        // The declared length is checked before any of it is read, so a hostile 0xFFFF in front of
        // two bytes costs nothing.
        let mut inner = 1_u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelOpen.as_byte());
        inner.extend_from_slice(&[0; 16]);
        inner.extend_from_slice(&0_i64.to_be_bytes());
        inner.push(0);
        inner.extend_from_slice(&u16::MAX.to_be_bytes());
        inner.extend_from_slice(b"xy");
        assert_eq!(MuxFrame::decode(&inner), Err(WireError::Truncated));
    }

    #[test]
    fn an_invalid_utf8_cwd_is_malformed_never_repaired() {
        // Strict, like every string field on this path: a corrupt cwd is dropped, not handed on as
        // `U+FFFD` for something downstream to try to `chdir` into.
        let mut inner = 1_u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelOpen.as_byte());
        inner.extend_from_slice(&[0; 16]);
        inner.extend_from_slice(&0_i64.to_be_bytes());
        inner.push(0);
        inner.extend_from_slice(&2_u16.to_be_bytes());
        inner.extend_from_slice(&[0xC3, 0x28]);
        assert!(matches!(
            MuxFrame::decode(&inner),
            Err(WireError::MalformedBody(_))
        ));
    }

    #[test]
    fn a_data_payload_is_carried_verbatim_including_bytes_that_look_like_frames() {
        // The mux layer does not parse the inner frame, so a payload that happens to be a valid
        // envelope must come back as bytes rather than being re-read as one.
        let nested = MuxFrame::ChannelClose {
            channel_id: 77,
            reason: MuxCloseReason::SubscriberEvicted,
        }
        .encode();
        let frame = MuxFrame::ChannelData {
            channel_id: 2,
            payload: nested.clone(),
        };
        let MuxFrame::ChannelData { payload, .. } = round_trip(&frame) else {
            panic!("data decodes as data");
        };
        assert_eq!(payload, nested);
    }
}
