//! The TCP-mux envelope — a port of Swift `AislopdeskProtocol.MuxEnvelope`
//! (`MuxFrameType` / `MuxFrame` / `MuxEnvelopeCodec`).
//!
//! The mux layer multiplexes many logical channels over one physical TCP connection
//! (SSH-style: `CHANNEL_OPEN` / `CHANNEL_DATA` / `CHANNEL_CLOSE` / `CHANNEL_WINDOW_ADJUST`).
//! Wire layout of a mux frame is
//! `[u32 BE muxFrameLength][u32 BE channelID][u8 muxType][body…]` where `muxFrameLength`
//! counts `channelID` + `muxType` + `body` (it excludes the 4-byte prefix). This mirrors
//! the terminal [`WireMessage`](crate::terminal::WireMessage) frame one level up: the mux
//! envelope is the OUTER frame, and a `ChannelData` body is an INNER `WireMessage` frame
//! carried opaquely — the codec never inspects it.

use crate::bytes::ByteWriter;
use crate::terminal::error::{Result, TerminalProtocolError};
use crate::terminal::reader::BigEndianReader;
use crate::terminal::session::SessionId;

/// The frame types carried by the TCP mux envelope. One byte selects the frame's meaning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MuxFrameType {
    /// Initiator asks to open a new logical channel.
    ChannelOpen,
    /// Responder accepts (or refuses) a channel open.
    ChannelOpenAck,
    /// Opaque application payload for an open channel (an inner `WireMessage` frame).
    ChannelData,
    /// One side is done sending on the channel (SSH `CHANNEL_CLOSE`).
    ChannelClose,
    /// Replenish a channel's flow-control window (SSH `CHANNEL_WINDOW_ADJUST`).
    WindowAdjust,
}

impl MuxFrameType {
    /// The on-wire type byte.
    #[must_use]
    pub const fn raw_value(self) -> u8 {
        match self {
            Self::ChannelOpen => 1,
            Self::ChannelOpenAck => 2,
            Self::ChannelData => 3,
            Self::ChannelClose => 4,
            Self::WindowAdjust => 5,
        }
    }

    /// Maps a wire type byte to its case, or `None` for an unrecognized byte (mirrors
    /// Swift's failable `MuxFrameType(rawValue:)`).
    #[must_use]
    pub const fn from_raw(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::ChannelOpen),
            2 => Some(Self::ChannelOpenAck),
            3 => Some(Self::ChannelData),
            4 => Some(Self::ChannelClose),
            5 => Some(Self::WindowAdjust),
            _ => None,
        }
    }
}

/// One decoded TCP mux frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MuxFrame {
    /// Open `channel_id` carrying a resume hint and a class selector.
    ChannelOpen {
        /// The logical channel being opened.
        channel_id: u32,
        /// Resume hint: the session to resume, or [`SessionId::NEW_SESSION`].
        session_id: SessionId,
        /// Highest contiguous output seq the initiator already holds.
        last_received_seq: i64,
        /// Application-defined channel class selector.
        channel_class: u8,
    },
    /// `accepted` is `true` if the responder will service the channel.
    ChannelOpenAck {
        /// The logical channel being answered.
        channel_id: u32,
        /// Whether the responder accepted the open.
        accepted: bool,
    },
    /// OPAQUE inner `WireMessage` frame bytes for `channel_id`.
    ChannelData {
        /// The logical channel carrying the payload.
        channel_id: u32,
        /// The opaque inner-frame bytes (carried verbatim).
        payload: Vec<u8>,
    },
    /// This side will send no more frames on `channel_id`.
    ChannelClose {
        /// The logical channel being closed.
        channel_id: u32,
    },
    /// Grant `bytes_to_add` more flow-control credit on `channel_id`.
    WindowAdjust {
        /// The logical channel being credited.
        channel_id: u32,
        /// Additional flow-control credit, in bytes.
        bytes_to_add: u32,
    },
}

impl MuxFrame {
    /// The logical channel this frame addresses.
    #[must_use]
    pub const fn channel_id(&self) -> u32 {
        match self {
            Self::ChannelOpen { channel_id, .. }
            | Self::ChannelOpenAck { channel_id, .. }
            | Self::ChannelData { channel_id, .. }
            | Self::ChannelClose { channel_id }
            | Self::WindowAdjust { channel_id, .. } => *channel_id,
        }
    }

    /// The on-wire mux-type for this frame.
    #[must_use]
    pub const fn mux_type(&self) -> MuxFrameType {
        match self {
            Self::ChannelOpen { .. } => MuxFrameType::ChannelOpen,
            Self::ChannelOpenAck { .. } => MuxFrameType::ChannelOpenAck,
            Self::ChannelData { .. } => MuxFrameType::ChannelData,
            Self::ChannelClose { .. } => MuxFrameType::ChannelClose,
            Self::WindowAdjust { .. } => MuxFrameType::WindowAdjust,
        }
    }
}

/// Encodes / decodes the TCP mux envelope. A manual big-endian binary codec; `ChannelData`
/// bodies are carried byte-for-byte and never inspected.
pub struct MuxEnvelopeCodec;

impl MuxEnvelopeCodec {
    /// Smallest legal `muxFrameLength`: channelID (4) + muxType (1). The shortest frames
    /// (`ChannelClose`) have an empty body.
    pub const MIN_MUX_FRAME_LENGTH: usize = 4 + 1;

    /// Encodes a frame into the complete mux envelope, ready to write to a socket:
    /// `[u32 BE muxFrameLength][u32 BE channelID][u8 muxType][body…]`. `muxFrameLength`
    /// counts `channelID` + `muxType` + `body` — what [`MuxFrameDecoder`] expects.
    #[must_use]
    pub fn encode(frame: &MuxFrame) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.put_u32(frame.channel_id());
        w.put_u8(frame.mux_type().raw_value());

        match frame {
            MuxFrame::ChannelOpen {
                session_id,
                last_received_seq,
                channel_class,
                ..
            } => {
                w.put_bytes(session_id.bytes());
                w.put_i64(*last_received_seq);
                w.put_u8(*channel_class);
            }
            MuxFrame::ChannelOpenAck { accepted, .. } => w.put_u8(u8::from(*accepted)),
            MuxFrame::ChannelData { payload, .. } => w.put_bytes(payload), // opaque — verbatim
            MuxFrame::ChannelClose { .. } => {}                            // empty body
            MuxFrame::WindowAdjust { bytes_to_add, .. } => w.put_u32(*bytes_to_add),
        }

        let inner = w.into_vec();
        let inner_length = inner.len() as u32;
        let mut out = Vec::with_capacity(4 + inner.len());
        out.extend_from_slice(&inner_length.to_be_bytes());
        out.extend_from_slice(&inner);
        out
    }

    /// Decodes a frame from a **complete inner run** (`[channelID][muxType][body…]`,
    /// without the length prefix — framing is handled by [`MuxFrameDecoder`]).
    ///
    /// # Errors
    /// Returns [`TerminalProtocolError::Truncated`] if the body is shorter than the mux
    /// type requires, or [`TerminalProtocolError::UnknownMessageType`] for an unrecognized
    /// mux-type byte.
    pub fn decode(inner: &[u8]) -> Result<MuxFrame> {
        let mut reader = BigEndianReader::new(inner);
        let channel_id = reader.read_u32()?;
        let type_byte = reader.read_u8()?;
        let Some(mux_type) = MuxFrameType::from_raw(type_byte) else {
            return Err(TerminalProtocolError::UnknownMessageType(type_byte));
        };

        match mux_type {
            MuxFrameType::ChannelOpen => {
                let session_id = SessionId::from_slice(reader.read_bytes(SessionId::BYTE_COUNT)?);
                let last_received_seq = reader.read_i64()?;
                let channel_class = reader.read_u8()?;
                Ok(MuxFrame::ChannelOpen {
                    channel_id,
                    session_id,
                    last_received_seq,
                    channel_class,
                })
            }
            MuxFrameType::ChannelOpenAck => Ok(MuxFrame::ChannelOpenAck {
                channel_id,
                accepted: reader.read_u8()? != 0,
            }),
            MuxFrameType::ChannelData => Ok(MuxFrame::ChannelData {
                channel_id,
                payload: reader.remaining().to_vec(),
            }),
            MuxFrameType::ChannelClose => Ok(MuxFrame::ChannelClose { channel_id }),
            MuxFrameType::WindowAdjust => Ok(MuxFrame::WindowAdjust {
                channel_id,
                bytes_to_add: reader.read_u32()?,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::frame_decoder::MuxFrameDecoder;
    use super::*;
    use crate::terminal::wire_message::WireMessage;

    fn sid(seed: u8) -> SessionId {
        let mut b = [0u8; 16];
        for (i, slot) in b.iter_mut().enumerate() {
            *slot = seed.wrapping_add(i as u8).wrapping_mul(3).wrapping_add(2);
        }
        SessionId(b)
    }

    fn round_trip(frame: &MuxFrame) -> Option<MuxFrame> {
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&MuxEnvelopeCodec::encode(frame));
        decoder.next_frame().expect("decode should not error")
    }

    fn assert_round_trips(cases: &[MuxFrame]) {
        for frame in cases {
            assert_eq!(round_trip(frame).as_ref(), Some(frame));
        }
    }

    #[test]
    fn channel_open_round_trip() {
        assert_round_trips(&[
            MuxFrame::ChannelOpen {
                channel_id: 1,
                session_id: SessionId::NEW_SESSION,
                last_received_seq: 0,
                channel_class: 0,
            },
            MuxFrame::ChannelOpen {
                channel_id: 3,
                session_id: sid(1),
                last_received_seq: i64::MAX,
                channel_class: 7,
            },
            MuxFrame::ChannelOpen {
                channel_id: u32::MAX,
                session_id: sid(2),
                last_received_seq: -1,
                channel_class: 255,
            },
        ]);
    }

    #[test]
    fn channel_open_ack_round_trip() {
        assert_round_trips(&[
            MuxFrame::ChannelOpenAck {
                channel_id: 1,
                accepted: true,
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 5,
                accepted: false,
            },
        ]);
    }

    #[test]
    fn channel_close_round_trip() {
        for id in [0u32, 1, 3, u32::MAX] {
            let frame = MuxFrame::ChannelClose { channel_id: id };
            assert_eq!(round_trip(&frame).as_ref(), Some(&frame));
        }
    }

    #[test]
    fn window_adjust_round_trip() {
        assert_round_trips(&[
            MuxFrame::WindowAdjust {
                channel_id: 1,
                bytes_to_add: 0,
            },
            MuxFrame::WindowAdjust {
                channel_id: 3,
                bytes_to_add: 65536,
            },
            MuxFrame::WindowAdjust {
                channel_id: 7,
                bytes_to_add: u32::MAX,
            },
        ]);
    }

    #[test]
    fn channel_data_body_round_trips_byte_identically() {
        let payloads: Vec<Vec<u8>> = vec![
            Vec::new(),
            b"ls -la\n".to_vec(),
            vec![0x00, 0xff, 0x80, 0x7f],
            WireMessage::Output {
                seq: 42,
                bytes: "vt output ✅".as_bytes().to_vec(),
            }
            .encode(),
            (0..4096).map(|i| (i & 0xFF) as u8).collect(),
        ];
        for payload in payloads {
            let frame = MuxFrame::ChannelData {
                channel_id: 9,
                payload: payload.clone(),
            };
            let decoded = round_trip(&frame);
            assert_eq!(decoded.as_ref(), Some(&frame));
            let Some(MuxFrame::ChannelData {
                payload: decoded_payload,
                ..
            }) = decoded
            else {
                panic!("expected channelData");
            };
            assert_eq!(decoded_payload, payload);
        }
    }

    #[test]
    fn mux_type_bytes_match_contract() {
        assert_eq!(MuxFrameType::ChannelOpen.raw_value(), 1);
        assert_eq!(MuxFrameType::ChannelOpenAck.raw_value(), 2);
        assert_eq!(MuxFrameType::ChannelData.raw_value(), 3);
        assert_eq!(MuxFrameType::ChannelClose.raw_value(), 4);
        assert_eq!(MuxFrameType::WindowAdjust.raw_value(), 5);
    }

    #[test]
    fn envelope_layout_length_prefix_excludes_prefix_bytes() {
        // windowAdjust body = 4 bytes => inner = channelID(4) + type(1) + body(4) = 9.
        let frame = MuxFrame::WindowAdjust {
            channel_id: 0x0102_0304,
            bytes_to_add: 0x0A0B_0C0D,
        };
        let bytes = MuxEnvelopeCodec::encode(&frame);
        assert_eq!(bytes.len(), 4 + 9);
        let prefix = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        assert_eq!(prefix, 9);
        assert_eq!(&bytes[4..8], &[0x01, 0x02, 0x03, 0x04]); // channelID BE
        assert_eq!(bytes[8], MuxFrameType::WindowAdjust.raw_value());
    }

    #[test]
    fn mux_frame_encode_prefix_equals_inner_length() {
        let samples = [
            MuxFrame::ChannelOpen {
                channel_id: 1,
                session_id: sid(3),
                last_received_seq: 5,
                channel_class: 0,
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 2,
                accepted: true,
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 3,
                accepted: false,
            },
            MuxFrame::ChannelData {
                channel_id: 4,
                payload: b"payload-bytes".to_vec(),
            },
            MuxFrame::ChannelData {
                channel_id: 5,
                payload: Vec::new(),
            },
            MuxFrame::ChannelClose { channel_id: 6 },
            MuxFrame::WindowAdjust {
                channel_id: 7,
                bytes_to_add: 262_144,
            },
        ];
        for fr in &samples {
            let f = MuxEnvelopeCodec::encode(fr);
            assert!(
                f.len() >= 9,
                "mux frame is at least prefix(4) + channelID(4) + type(1)"
            );
            let prefix = u32::from_be_bytes([f[0], f[1], f[2], f[3]]);
            assert_eq!(prefix as usize, f.len() - 4, "prefix equals inner length");
            let mut d = MuxFrameDecoder::new();
            d.append(&f);
            assert_eq!(d.next_frame().unwrap().as_ref(), Some(fr));
            assert_eq!(d.next_frame().unwrap(), None);
        }
    }

    // --- decode error paths ---

    fn framed(inner: &[u8]) -> Vec<u8> {
        let mut out = (inner.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(inner);
        out
    }

    #[test]
    fn unknown_mux_type_throws() {
        let mut inner = 7u32.to_be_bytes().to_vec(); // channelID
        inner.push(0xFF); // unknown mux type
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&framed(&inner));
        assert_eq!(
            decoder.next_frame(),
            Err(TerminalProtocolError::UnknownMessageType(0xFF))
        );
    }

    #[test]
    fn complete_frame_with_short_body_throws_truncated() {
        // windowAdjust (type 5) needs 4 body bytes after channelID+type; supply 2.
        let mut inner = 3u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::WindowAdjust.raw_value());
        inner.extend_from_slice(&[0x00, 0x10]);
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&framed(&inner));
        assert_eq!(decoder.next_frame(), Err(TerminalProtocolError::Truncated));
    }

    #[test]
    fn inner_run_shorter_than_header_throws_truncated() {
        let inner = [0x00u8, 0x00, 0x01]; // 3 bytes — fewer than channelID(4)
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&framed(&inner));
        assert_eq!(decoder.next_frame(), Err(TerminalProtocolError::Truncated));
    }

    #[test]
    fn channel_open_short_body_throws_truncated() {
        let mut inner = 1u32.to_be_bytes().to_vec();
        inner.push(MuxFrameType::ChannelOpen.raw_value());
        inner.extend_from_slice(sid(0).bytes()); // 16 sessionID bytes, then nothing
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&framed(&inner));
        assert_eq!(decoder.next_frame(), Err(TerminalProtocolError::Truncated));
    }

    #[test]
    fn oversize_frame_throws_frame_too_large() {
        let oversized = crate::terminal::MAX_FRAME_PAYLOAD_LENGTH + 1;
        let mut decoder = MuxFrameDecoder::new();
        decoder.append(&(oversized as u32).to_be_bytes());
        assert_eq!(
            decoder.next_frame(),
            Err(TerminalProtocolError::FrameTooLarge(oversized))
        );
    }
}
