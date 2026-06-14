//! The terminal (PTY) protocol message — a port of Swift
//! `AislopdeskProtocol.WireMessage` (+ its `encode` / `decode` / `wireByteCount`
//! extensions).
//!
//! Wire layout of a frame is `[u32 BE payloadLength][u8 messageType][body…]` where
//! `payloadLength` counts `messageType` + `body` (it excludes the 4 prefix bytes). All
//! multi-byte integers are big-endian. The keystroke/output hot path uses this manual
//! binary encoding — never JSON.

use super::error::{Result, TerminalProtocolError};
use super::reader::BigEndianReader;
use super::session::SessionId;
use crate::bytes::ByteWriter;

/// The two TCP connections that make up an Aislopdesk session.
///
/// A session uses **two** TCP connections so that a burst of PTY output on the data
/// channel cannot delay a resize / disconnect intent on the control channel. This enum
/// is advisory metadata: [`WireMessage::channel`] states which connection a message is
/// expected to travel on; the framing and decoder are identical on both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    /// PTY byte stream: `output`, `exit` (host → client) and `input` (client → host).
    Data,
    /// Session lifecycle & sizing: `hello`/`resize`/`ack`/`bye`/`ping` (client → host)
    /// and `helloAck`/`title`/`bell`/`commandStatus`/`pong`/`notification` (host → client).
    Control,
}

/// The semantic state of the foreground command in a pane's shell (from OSC 133).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandStatus {
    /// OSC 133;C — a command began executing (preexec). The pane is RUNNING.
    Running,
    /// OSC 133;D — the command finished (precmd of the next prompt). The pane is IDLE
    /// again. `exit_code` is the command's `$?` (`None` if the shell did not report one);
    /// `duration_ms` is the host-measured C→D wall-clock time.
    Idle {
        /// The command's exit status, or `None` if the shell did not report one.
        exit_code: Option<i32>,
        /// Host-measured C→D wall-clock time in milliseconds.
        duration_ms: u32,
    },
}

/// One decoded Aislopdesk terminal-protocol message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireMessage {
    // DATA channel, host → client
    /// PTY output. `seq` is a monotonic per-message index starting at 1 (NOT a byte
    /// offset); `bytes` is the raw VT payload.
    Output {
        /// Monotonic per-message index, starting at 1.
        seq: i64,
        /// Raw VT payload bytes.
        bytes: Vec<u8>,
    },
    /// Child process exited with the given status `code`.
    Exit {
        /// Child process exit status.
        code: i32,
    },

    // DATA channel, client → host
    /// Bytes to write to the PTY's stdin (keystrokes, pasted text, etc.).
    Input(Vec<u8>),

    // CONTROL channel, client → host
    /// Session handshake. An all-zero `session_id` means "open a NEW session"; a non-zero
    /// id means "resume this session". `last_received_seq` is the highest contiguous
    /// output seq the client already has, so the host can replay only newer output.
    Hello {
        /// Negotiated wire-protocol version.
        protocol_version: u16,
        /// The session to resume, or [`SessionId::NEW_SESSION`] for a new one.
        session_id: SessionId,
        /// Highest contiguous output seq the client already holds.
        last_received_seq: i64,
    },
    /// Terminal resize. Character cells plus optional pixel dimensions (0 if unknown).
    Resize {
        /// Columns (character cells).
        cols: u16,
        /// Rows (character cells).
        rows: u16,
        /// Pixel width (0 if unknown).
        px_width: u16,
        /// Pixel height (0 if unknown).
        px_height: u16,
    },
    /// Acknowledge receipt of output up to and including `seq`.
    Ack {
        /// Highest contiguous output seq durably received.
        seq: i64,
    },
    /// Client is leaving cleanly (empty body).
    Bye,
    /// Application-layer RTT probe (client → host). The host echoes `timestamp_ms` back
    /// verbatim in [`WireMessage::Pong`].
    Ping {
        /// The client's monotonic-clock timestamp (interpreted only by the client).
        timestamp_ms: u64,
    },

    // CONTROL channel, host → client
    /// Handshake reply. `session_id` is authoritative; `resume_from_seq` is the seq the
    /// host will replay from; `returning_client` is decided by the host.
    HelloAck {
        /// Authoritative session id.
        session_id: SessionId,
        /// Seq the host will replay from.
        resume_from_seq: i64,
        /// `true` if the host recognized a resuming client (it replays the tail).
        returning_client: bool,
    },
    /// Window/title text (UTF-8). Driven by OSC 0/2.
    Title(String),
    /// Terminal bell (empty body).
    Bell,
    /// Per-command semantic status, derived host-side from OSC 133 C/D marks.
    CommandStatus(CommandStatus),
    /// RTT probe reply: the client's [`WireMessage::Ping`] timestamp echoed verbatim.
    Pong {
        /// The client timestamp echoed verbatim.
        timestamp_ms: u64,
    },
    /// An explicit desktop notification the child requested via OSC 9 / OSC 777. An OSC 9
    /// with no explicit title carries an empty `title`.
    Notification {
        /// Notification title (empty for an untitled OSC 9).
        title: String,
        /// Notification body.
        body: String,
    },
}

impl WireMessage {
    /// The on-wire message-type byte for this case.
    #[must_use]
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::Output { .. } => 1,
            Self::Exit { .. } => 2,
            Self::Input(_) => 3,
            Self::Hello { .. } => 10,
            Self::Resize { .. } => 11,
            Self::Ack { .. } => 12,
            Self::Bye => 13,
            Self::Ping { .. } => 14,
            Self::HelloAck { .. } => 20,
            Self::Title(_) => 21,
            Self::Bell => 22,
            Self::CommandStatus(_) => 23,
            Self::Pong { .. } => 24,
            Self::Notification { .. } => 25,
        }
    }

    /// The channel this message is expected to travel on (advisory; see [`Channel`]).
    #[must_use]
    pub const fn channel(&self) -> Channel {
        match self {
            Self::Output { .. } | Self::Exit { .. } | Self::Input(_) => Channel::Data,
            Self::Hello { .. }
            | Self::Resize { .. }
            | Self::Ack { .. }
            | Self::Bye
            | Self::Ping { .. }
            | Self::HelloAck { .. }
            | Self::Title(_)
            | Self::Bell
            | Self::CommandStatus(_)
            | Self::Pong { .. }
            | Self::Notification { .. } => Channel::Control,
        }
    }

    /// Encodes this message into a complete frame, ready to write to a socket:
    /// `[u32 BE payloadLength][u8 messageType][body…]`. `payloadLength` counts
    /// `messageType` + `body` and excludes the 4 prefix bytes — exactly what
    /// [`FrameDecoder`](super::FrameDecoder) expects.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        // Build [messageType][body…] first, then prepend the big-endian length prefix.
        // Byte-identical to Swift's single-buffer back-patch.
        let mut w = ByteWriter::new();
        w.put_u8(self.message_type());

        match self {
            Self::Output { seq, bytes } => {
                w.put_i64(*seq);
                w.put_bytes(bytes);
            }
            Self::Exit { code } => w.put_i32(*code),
            Self::Input(bytes) => w.put_bytes(bytes),
            Self::Hello {
                protocol_version,
                session_id,
                last_received_seq,
            } => {
                w.put_u16(*protocol_version);
                w.put_bytes(session_id.bytes());
                w.put_i64(*last_received_seq);
            }
            Self::Resize {
                cols,
                rows,
                px_width,
                px_height,
            } => {
                w.put_u16(*cols);
                w.put_u16(*rows);
                w.put_u16(*px_width);
                w.put_u16(*px_height);
            }
            Self::Ack { seq } => w.put_i64(*seq),
            Self::Bye | Self::Bell => {} // empty body
            Self::Ping { timestamp_ms } | Self::Pong { timestamp_ms } => w.put_u64(*timestamp_ms),
            Self::HelloAck {
                session_id,
                resume_from_seq,
                returning_client,
            } => {
                w.put_bytes(session_id.bytes());
                w.put_i64(*resume_from_seq);
                w.put_u8(u8::from(*returning_client));
            }
            Self::Title(string) => w.put_bytes(string.as_bytes()),
            Self::Notification { title, body } => {
                // [u16 BE titleLen][title UTF-8][body UTF-8]. The title is clamped to the
                // u16 length field's limit so an absurd >64 KiB title can never wrap the
                // length and corrupt the body (see `clamped_notification_title`).
                let title_bytes = clamped_notification_title(title).as_bytes();
                w.put_u16(title_bytes.len() as u16);
                w.put_bytes(title_bytes);
                w.put_bytes(body.as_bytes());
            }
            Self::CommandStatus(status) => match status {
                CommandStatus::Running => w.put_u8(0),
                CommandStatus::Idle {
                    exit_code,
                    duration_ms,
                } => {
                    w.put_u8(1);
                    w.put_u8(u8::from(exit_code.is_some())); // hasExit
                    w.put_i32(exit_code.unwrap_or(0)); // Int32 BE (0 when absent)
                    w.put_u32(*duration_ms); // UInt32 BE
                }
            },
        }

        let payload = w.into_vec();
        let payload_length = payload.len() as u32;
        let mut frame = Vec::with_capacity(4 + payload.len());
        frame.extend_from_slice(&payload_length.to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    /// The exact number of bytes [`encode`](WireMessage::encode) produces, computed
    /// WITHOUT building the frame. The receive-side flow-control crediting credits
    /// `wire_byte_count` per consumed message, matching the sender's per-frame debit.
    #[must_use]
    pub fn wire_byte_count(&self) -> usize {
        // Each arm states a DISTINCT field layout; several coincidentally sum to the same
        // byte count (Resize = 4×u16, Ack = i64, Ping/Pong = u64 all = 8). Keeping them
        // separate mirrors the Swift source 1:1 and documents each size at its variant.
        #[allow(clippy::match_same_arms)]
        let body: usize = match self {
            Self::Output { bytes, .. } => 8 + bytes.len(), // seq i64 + payload
            Self::Exit { .. } => 4,                        // code i32
            Self::Input(bytes) => bytes.len(),
            Self::Hello { .. } => 2 + SessionId::BYTE_COUNT + 8, // u16 + id + i64
            Self::Resize { .. } => 8,                            // 4 × u16
            Self::Ack { .. } => 8,                               // seq i64
            Self::Bye | Self::Bell => 0,
            Self::Ping { .. } | Self::Pong { .. } => 8, // timestamp u64
            Self::HelloAck { .. } => SessionId::BYTE_COUNT + 8 + 1, // id + i64 + bool
            Self::Title(string) => string.len(),
            Self::Notification { title, body } => {
                2 + clamped_notification_title(title).len() + body.len()
            }
            Self::CommandStatus(status) => match status {
                CommandStatus::Running => 1,                 // tag
                CommandStatus::Idle { .. } => 1 + 1 + 4 + 4, // tag + hasExit + i32 + u32
            },
        };
        // 4-byte length prefix + 1 type byte + body.
        4 + 1 + body
    }

    /// Decodes a message from a **complete payload** (`[u8 messageType][body…]`, without
    /// the length prefix — framing is handled by [`FrameDecoder`](super::FrameDecoder)).
    ///
    /// # Errors
    /// Returns [`TerminalProtocolError::Truncated`] if the body is shorter than the type
    /// requires, [`TerminalProtocolError::UnknownMessageType`] for an unrecognized type
    /// byte, or [`TerminalProtocolError::MalformedBody`] for a right-length-but-invalid
    /// body (e.g. bad UTF-8).
    pub fn decode(payload: &[u8]) -> Result<Self> {
        let mut reader = BigEndianReader::new(payload);
        let type_byte = reader.read_u8()?;

        match type_byte {
            1 => {
                let seq = reader.read_i64()?;
                Ok(Self::Output {
                    seq,
                    bytes: reader.remaining().to_vec(),
                })
            }
            2 => Ok(Self::Exit {
                code: reader.read_i32()?,
            }),
            3 => Ok(Self::Input(reader.remaining().to_vec())),
            10 => {
                let protocol_version = reader.read_u16()?;
                let session_id = SessionId::from_slice(reader.read_bytes(SessionId::BYTE_COUNT)?);
                let last_received_seq = reader.read_i64()?;
                Ok(Self::Hello {
                    protocol_version,
                    session_id,
                    last_received_seq,
                })
            }
            11 => Ok(Self::Resize {
                cols: reader.read_u16()?,
                rows: reader.read_u16()?,
                px_width: reader.read_u16()?,
                px_height: reader.read_u16()?,
            }),
            12 => Ok(Self::Ack {
                seq: reader.read_i64()?,
            }),
            13 => Ok(Self::Bye),
            14 => Ok(Self::Ping {
                timestamp_ms: reader.read_u64()?,
            }),
            20 => {
                let session_id = SessionId::from_slice(reader.read_bytes(SessionId::BYTE_COUNT)?);
                let resume_from_seq = reader.read_i64()?;
                let returning_byte = reader.read_u8()?;
                Ok(Self::HelloAck {
                    session_id,
                    resume_from_seq,
                    returning_client: returning_byte != 0,
                })
            }
            21 => {
                let bytes = reader.remaining();
                let string = String::from_utf8(bytes.to_vec())
                    .map_err(|_| TerminalProtocolError::malformed("title: invalid UTF-8"))?;
                Ok(Self::Title(string))
            }
            22 => Ok(Self::Bell),
            23 => {
                let tag = reader.read_u8()?;
                match tag {
                    0 => Ok(Self::CommandStatus(CommandStatus::Running)),
                    1 => {
                        let has_exit = reader.read_u8()?;
                        let exit_raw = reader.read_i32()?;
                        let duration_ms = reader.read_u32()?;
                        Ok(Self::CommandStatus(CommandStatus::Idle {
                            exit_code: if has_exit != 0 { Some(exit_raw) } else { None },
                            duration_ms,
                        }))
                    }
                    other => Err(TerminalProtocolError::malformed(format!(
                        "commandStatus: invalid tag {other}"
                    ))),
                }
            }
            24 => Ok(Self::Pong {
                timestamp_ms: reader.read_u64()?,
            }),
            25 => {
                let title_len = usize::from(reader.read_u16()?);
                let title_bytes = reader.read_bytes(title_len)?;
                let title = String::from_utf8(title_bytes.to_vec()).map_err(|_| {
                    TerminalProtocolError::malformed("notification: invalid title UTF-8")
                })?;
                let body = String::from_utf8(reader.remaining().to_vec()).map_err(|_| {
                    TerminalProtocolError::malformed("notification: invalid body UTF-8")
                })?;
                Ok(Self::Notification { title, body })
            }
            other => Err(TerminalProtocolError::UnknownMessageType(other)),
        }
    }
}

/// A notification title whose UTF-8 fits the wire's `u16` length field (≤ 65535 bytes),
/// clamped at a `char` boundary so it stays valid UTF-8.
///
/// Identity for any sane title (the
/// only producer caps the OSC at 1 KiB); only an absurd >64 KiB title is shortened —
/// preventing the length field from wrapping and corrupting the body.
///
/// Deviation note (unreachable): Swift clamps at a `Character` (grapheme-cluster)
/// boundary, this clamps at a Rust `char` (Unicode-scalar) boundary. They agree for every
/// title that does not exceed 64 KiB (clamp never fires) and for all-ASCII titles; they
/// could differ only if the 65535-byte cut fell *inside* a multi-scalar grapheme of a
/// >64 KiB title — which no producer emits. Both always yield valid UTF-8.
#[must_use]
pub fn clamped_notification_title(title: &str) -> &str {
    if u16::try_from(title.len()).is_ok() {
        return title; // already fits the u16 length field — the common case
    }
    let limit = u16::MAX as usize;
    let mut count = 0;
    let mut end = 0;
    for (i, ch) in title.char_indices() {
        let n = ch.len_utf8();
        if count + n > limit {
            break;
        }
        count += n;
        end = i + n;
    }
    &title[..end]
}

#[cfg(test)]
mod tests {
    use super::super::frame_decoder::FrameDecoder;
    use super::*;

    /// Deterministic stand-in for Swift's random `UUID()` — any 16 bytes round-trip.
    fn sid(seed: u8) -> SessionId {
        let mut b = [0u8; 16];
        for (i, slot) in b.iter_mut().enumerate() {
            *slot = seed.wrapping_add(i as u8).wrapping_mul(7).wrapping_add(1);
        }
        SessionId(b)
    }

    /// Encodes a message, feeds the frame bytes through a fresh `FrameDecoder`, and
    /// returns the decoded message — the canonical round-trip helper.
    fn round_trip(message: &WireMessage) -> Option<WireMessage> {
        let mut decoder = FrameDecoder::new();
        decoder.append(&message.encode());
        decoder.next_message().expect("decode should not error")
    }

    fn assert_round_trips(cases: &[WireMessage]) {
        for message in cases {
            assert_eq!(round_trip(message).as_ref(), Some(message));
        }
    }

    #[test]
    fn output_round_trip_representative_and_boundary() {
        assert_round_trips(&[
            WireMessage::Output {
                seq: 1,
                bytes: b"hello".to_vec(),
            },
            WireMessage::Output {
                seq: i64::MAX,
                bytes: Vec::new(),
            },
            WireMessage::Output {
                seq: 42,
                bytes: vec![0x1b, 0x5b, 0x32, 0x4a],
            },
        ]);
    }

    #[test]
    fn exit_round_trip() {
        for code in [0, 1, -1, i32::MAX, i32::MIN] {
            let m = WireMessage::Exit { code };
            assert_eq!(round_trip(&m).as_ref(), Some(&m));
        }
    }

    #[test]
    fn input_round_trip() {
        assert_round_trips(&[
            WireMessage::Input(Vec::new()),
            WireMessage::Input(b"ls -la\n".to_vec()),
            WireMessage::Input(vec![0x00, 0xff, 0x80, 0x7f]),
        ]);
    }

    #[test]
    fn hello_round_trip_new_and_resume_sessions() {
        assert_round_trips(&[
            WireMessage::Hello {
                protocol_version: super::super::PROTOCOL_VERSION,
                session_id: SessionId::NEW_SESSION,
                last_received_seq: 0,
            },
            WireMessage::Hello {
                protocol_version: 1,
                session_id: sid(1),
                last_received_seq: i64::MAX,
            },
            WireMessage::Hello {
                protocol_version: u16::MAX,
                session_id: sid(2),
                last_received_seq: -1,
            },
        ]);
    }

    #[test]
    fn resize_round_trip_boundaries() {
        assert_round_trips(&[
            WireMessage::Resize {
                cols: 0,
                rows: 0,
                px_width: 0,
                px_height: 0,
            },
            WireMessage::Resize {
                cols: 65535,
                rows: 65535,
                px_width: 65535,
                px_height: 65535,
            },
            WireMessage::Resize {
                cols: 80,
                rows: 24,
                px_width: 640,
                px_height: 384,
            },
        ]);
    }

    #[test]
    fn ack_round_trip() {
        for seq in [0, 1, i64::MAX, -1] {
            let m = WireMessage::Ack { seq };
            assert_eq!(round_trip(&m).as_ref(), Some(&m));
        }
    }

    #[test]
    fn bye_round_trip() {
        assert_eq!(round_trip(&WireMessage::Bye), Some(WireMessage::Bye));
    }

    #[test]
    fn ping_pong_round_trip() {
        for ts in [0u64, 1, 1_749_700_000_123, u64::MAX] {
            assert_eq!(
                round_trip(&WireMessage::Ping { timestamp_ms: ts }),
                Some(WireMessage::Ping { timestamp_ms: ts })
            );
            assert_eq!(
                round_trip(&WireMessage::Pong { timestamp_ms: ts }),
                Some(WireMessage::Pong { timestamp_ms: ts })
            );
        }
    }

    #[test]
    fn hello_ack_round_trip() {
        assert_round_trips(&[
            WireMessage::HelloAck {
                session_id: sid(3),
                resume_from_seq: 1,
                returning_client: true,
            },
            WireMessage::HelloAck {
                session_id: SessionId::NEW_SESSION,
                resume_from_seq: 0,
                returning_client: false,
            },
            WireMessage::HelloAck {
                session_id: sid(4),
                resume_from_seq: i64::MAX,
                returning_client: true,
            },
        ]);
    }

    #[test]
    fn title_round_trip_including_cjk_and_emoji() {
        assert_round_trips(&[
            WireMessage::Title(String::new()),
            WireMessage::Title("zsh — ~/project".to_string()),
            WireMessage::Title("日本語タイトル".to_string()),
            WireMessage::Title("build ✅ done 🚀 — café".to_string()),
        ]);
    }

    #[test]
    fn bell_round_trip() {
        assert_eq!(round_trip(&WireMessage::Bell), Some(WireMessage::Bell));
    }

    #[test]
    fn notification_round_trip_including_empty_title_and_unicode() {
        assert_round_trips(&[
            WireMessage::Notification {
                title: String::new(),
                body: "build done".to_string(),
            },
            WireMessage::Notification {
                title: "CI".to_string(),
                body: "all green ✅".to_string(),
            },
            WireMessage::Notification {
                title: "日本語".to_string(),
                body: "完了 🚀".to_string(),
            },
            WireMessage::Notification {
                title: "only title".to_string(),
                body: String::new(),
            },
            WireMessage::Notification {
                title: "semis;in;title".to_string(),
                body: "and;in;body;too".to_string(),
            },
        ]);
    }

    #[test]
    fn notification_overlong_title_clamps_without_corrupting_body() {
        let body = "the body must survive intact — ✅";
        let decoded = round_trip(&WireMessage::Notification {
            title: "T".repeat(70_000),
            body: body.to_string(),
        });
        let Some(WireMessage::Notification {
            title: d_title,
            body: d_body,
        }) = decoded
        else {
            panic!("not a notification");
        };
        assert_eq!(d_body, body, "body is never corrupted by an overlong title");
        assert!(
            u16::try_from(d_title.len()).is_ok(),
            "title clamped to the u16 length limit"
        );
        assert!(
            d_title.bytes().all(|c| c == b'T'),
            "the clamped title is a valid prefix of the original"
        );
    }

    #[test]
    fn command_status_round_trip() {
        assert_round_trips(&[
            WireMessage::CommandStatus(CommandStatus::Running),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(0),
                duration_ms: 12_000,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(1),
                duration_ms: 300,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(130),
                duration_ms: 0,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(-1),
                duration_ms: 1,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(i32::MIN),
                duration_ms: u32::MAX,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 5_000,
            }),
        ]);
    }

    #[test]
    fn command_status_invalid_tag_throws_malformed_body() {
        // type 23 + bogus tag 9 (only 0=running / 1=idle valid).
        let body = [23u8, 0x09];
        let mut frame = (body.len() as u32).to_be_bytes().to_vec();
        frame.extend_from_slice(&body);
        let mut decoder = FrameDecoder::new();
        decoder.append(&frame);
        assert!(matches!(
            decoder.next_message(),
            Err(TerminalProtocolError::MalformedBody(_))
        ));
    }

    #[test]
    fn message_type_bytes_match_contract() {
        assert_eq!(
            (WireMessage::Output {
                seq: 1,
                bytes: vec![]
            })
            .message_type(),
            1
        );
        assert_eq!((WireMessage::Exit { code: 0 }).message_type(), 2);
        assert_eq!(WireMessage::Input(vec![]).message_type(), 3);
        assert_eq!(
            (WireMessage::Hello {
                protocol_version: 1,
                session_id: sid(0),
                last_received_seq: 0
            })
            .message_type(),
            10
        );
        assert_eq!(
            (WireMessage::Resize {
                cols: 0,
                rows: 0,
                px_width: 0,
                px_height: 0
            })
            .message_type(),
            11
        );
        assert_eq!((WireMessage::Ack { seq: 0 }).message_type(), 12);
        assert_eq!(WireMessage::Bye.message_type(), 13);
        assert_eq!((WireMessage::Ping { timestamp_ms: 0 }).message_type(), 14);
        assert_eq!(
            (WireMessage::HelloAck {
                session_id: sid(0),
                resume_from_seq: 0,
                returning_client: false
            })
            .message_type(),
            20
        );
        assert_eq!(WireMessage::Title(String::new()).message_type(), 21);
        assert_eq!(WireMessage::Bell.message_type(), 22);
        assert_eq!(
            WireMessage::CommandStatus(CommandStatus::Running).message_type(),
            23
        );
        assert_eq!(
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(0),
                duration_ms: 0
            })
            .message_type(),
            23
        );
        assert_eq!((WireMessage::Pong { timestamp_ms: 0 }).message_type(), 24);
        assert_eq!(
            (WireMessage::Notification {
                title: String::new(),
                body: String::new()
            })
            .message_type(),
            25
        );
    }

    #[test]
    fn channel_assignment() {
        assert_eq!(
            (WireMessage::Output {
                seq: 1,
                bytes: vec![]
            })
            .channel(),
            Channel::Data
        );
        assert_eq!((WireMessage::Exit { code: 0 }).channel(), Channel::Data);
        assert_eq!(WireMessage::Input(vec![]).channel(), Channel::Data);
        assert_eq!(
            (WireMessage::Hello {
                protocol_version: 1,
                session_id: sid(0),
                last_received_seq: 0
            })
            .channel(),
            Channel::Control
        );
        assert_eq!(WireMessage::Bye.channel(), Channel::Control);
        assert_eq!(WireMessage::Bell.channel(), Channel::Control);
        assert_eq!(
            WireMessage::CommandStatus(CommandStatus::Running).channel(),
            Channel::Control
        );
        assert_eq!(
            (WireMessage::Ping { timestamp_ms: 0 }).channel(),
            Channel::Control
        );
        assert_eq!(
            (WireMessage::Pong { timestamp_ms: 0 }).channel(),
            Channel::Control
        );
    }

    #[test]
    fn complete_frame_with_short_body_throws_truncated() {
        // exit (type 2) needs a 4-byte i32 code; supply only the type byte.
        let exit_body = [2u8];
        let mut exit_frame = (exit_body.len() as u32).to_be_bytes().to_vec();
        exit_frame.extend_from_slice(&exit_body);
        let mut exit_decoder = FrameDecoder::new();
        exit_decoder.append(&exit_frame);
        assert_eq!(
            exit_decoder.next_message(),
            Err(TerminalProtocolError::Truncated)
        );

        // resize (type 11) needs 8 body bytes; supply only 3.
        let resize_body = [11u8, 0x00, 0x50, 0x00];
        let mut resize_frame = (resize_body.len() as u32).to_be_bytes().to_vec();
        resize_frame.extend_from_slice(&resize_body);
        let mut resize_decoder = FrameDecoder::new();
        resize_decoder.append(&resize_frame);
        assert_eq!(
            resize_decoder.next_message(),
            Err(TerminalProtocolError::Truncated)
        );
    }

    #[test]
    fn title_with_invalid_utf8_throws_malformed_body() {
        let body = [21u8, 0xFF, 0xFE, 0xFD];
        let mut frame = (body.len() as u32).to_be_bytes().to_vec();
        frame.extend_from_slice(&body);
        let mut decoder = FrameDecoder::new();
        decoder.append(&frame);
        assert!(matches!(
            decoder.next_message(),
            Err(TerminalProtocolError::MalformedBody(_))
        ));
    }

    #[test]
    fn frame_layout_length_prefix_excludes_prefix_bytes() {
        // output(seq:1, "abc") => body = type(1) + seq(8) + 3 = 12.
        let frame = (WireMessage::Output {
            seq: 1,
            bytes: b"abc".to_vec(),
        })
        .encode();
        assert_eq!(frame.len(), 4 + 12);
        let prefix = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]);
        assert_eq!(prefix, 12);
        assert_eq!(frame[4], 1); // first payload byte is the message type
    }

    // --- wireByteCount parity (WireMessageWireByteCountTests) ---

    #[test]
    fn wire_byte_count_matches_encode_for_every_variant() {
        let payloads: [Vec<u8>; 3] = [Vec::new(), b"x".to_vec(), vec![0x41u8; 128 * 1024]];
        let mut messages: Vec<WireMessage> = Vec::new();
        for p in &payloads {
            messages.push(WireMessage::Output {
                seq: 1,
                bytes: p.clone(),
            });
            messages.push(WireMessage::Output {
                seq: i64::MAX,
                bytes: p.clone(),
            });
            messages.push(WireMessage::Input(p.clone()));
        }
        messages.extend([
            WireMessage::Exit { code: 0 },
            WireMessage::Exit { code: -1 },
            WireMessage::Hello {
                protocol_version: 1,
                session_id: sid(9),
                last_received_seq: 42,
            },
            WireMessage::Hello {
                protocol_version: u16::MAX,
                session_id: SessionId::NEW_SESSION,
                last_received_seq: 0,
            },
            WireMessage::Resize {
                cols: 80,
                rows: 24,
                px_width: 0,
                px_height: 0,
            },
            WireMessage::Ack { seq: 7 },
            WireMessage::Bye,
            WireMessage::Ping { timestamp_ms: 0 },
            WireMessage::Ping {
                timestamp_ms: u64::MAX,
            },
            WireMessage::Pong {
                timestamp_ms: 12_345,
            },
            WireMessage::HelloAck {
                session_id: sid(10),
                resume_from_seq: 3,
                returning_client: true,
            },
            WireMessage::HelloAck {
                session_id: sid(11),
                resume_from_seq: 0,
                returning_client: false,
            },
            WireMessage::Title(String::new()),
            WireMessage::Title("hello".to_string()),
            WireMessage::Title("tiếng Việt — đa byte ✓".to_string()),
            WireMessage::Bell,
            WireMessage::CommandStatus(CommandStatus::Running),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(0),
                duration_ms: 12,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(-127),
                duration_ms: u32::MAX,
            }),
            WireMessage::Notification {
                title: String::new(),
                body: "done".to_string(),
            },
            WireMessage::Notification {
                title: "CI".to_string(),
                body: "green ✅ — đa byte".to_string(),
            },
            WireMessage::Notification {
                title: "only title".to_string(),
                body: String::new(),
            },
            WireMessage::Notification {
                title: "T".repeat(70_000),
                body: "overlong title is clamped".to_string(),
            },
        ]);
        for message in &messages {
            assert_eq!(
                message.wire_byte_count(),
                message.encode().len(),
                "wire_byte_count must equal encode().len() for {message:?}"
            );
        }
    }

    // --- back-patched length prefix (FrameDecoderCursorTests) ---

    #[test]
    fn wire_message_encode_prefix_equals_payload_length() {
        let samples = [
            WireMessage::Output {
                seq: 42,
                bytes: b"hello".to_vec(),
            },
            WireMessage::Output {
                seq: 1,
                bytes: Vec::new(),
            },
            WireMessage::Exit { code: 137 },
            WireMessage::Input(vec![0x1B, 0x5B, 0x41]),
            WireMessage::Resize {
                cols: 200,
                rows: 50,
                px_width: 1,
                px_height: 2,
            },
            WireMessage::Ack { seq: 9_000_000_000 },
            WireMessage::Bye,
            WireMessage::Bell,
            WireMessage::HelloAck {
                session_id: sid(7),
                resume_from_seq: 7,
                returning_client: true,
            },
            WireMessage::Title("a-very-long-title-string-with-emoji-✅-and-more".to_string()),
            WireMessage::CommandStatus(CommandStatus::Running),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(-1),
                duration_ms: 1234,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            }),
        ];
        for m in &samples {
            let f = m.encode();
            assert!(f.len() >= 5, "frame is at least prefix(4) + type(1)");
            let prefix = u32::from_be_bytes([f[0], f[1], f[2], f[3]]);
            assert_eq!(
                prefix as usize,
                f.len() - 4,
                "prefix must equal payload length"
            );
            let mut d = FrameDecoder::new();
            d.append(&f);
            assert_eq!(d.next_message().unwrap().as_ref(), Some(m));
            assert_eq!(d.next_message().unwrap(), None);
        }
    }
}
