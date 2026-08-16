//! [`WireMessage::encode`] and [`WireMessage::decode`] — the byte layout of every message type.
//!
//! ## Encoding builds ONE buffer
//! A four-byte length placeholder goes down first, then `[type][body…]`, then the prefix is
//! BACK-PATCHED with the finished payload length. Building the body separately and concatenating
//! would memcpy an up-to-128 KiB `.output` payload twice under a flood, which is the traffic shape
//! this codec exists for. The buffer is pre-sized from
//! [`wire_byte_count`](WireMessage::wire_byte_count), so a well-formed message never reallocates.
//!
//! ## Decoding validates before it reads
//! Every length-prefixed field checks its declared length against what remains BEFORE reading it,
//! so a hostile body can only ever shorten a frame — never make the reader over-read. Fixed-field
//! decoders ignore trailing bytes, which is the forward-tolerant half of the additive-type rule: a
//! future field appended to an existing type does not break an old peer.
//!
//! ## Strings are strict UTF-8
//! An invalid sequence is [`WireError::MalformedBody`], never a replacement-character repair. Only
//! the video path is lossy, and it is not this path.

use core::ops::Range;

use crate::bytes::{ByteReader, ByteWriter};
use crate::error::{Result, WireError};
use crate::message::{CommandStatus, ProjectGitStatus, RawUuid, SESSION_ID_BYTE_COUNT, WireMessage};

/// The `u32` a `usize` length occupies on the wire.
///
/// Matches Swift's `UInt32(truncatingIfNeeded:)` by masking rather than saturating, so the two
/// encoders agree bit-for-bit even on a length no frame could legitimately carry. The mask makes
/// the conversion total, so this cannot panic and needs no cast.
fn wire_length(value: usize) -> u32 {
    u32::try_from(value & 0xFFFF_FFFF).unwrap_or(u32::MAX)
}

/// Reads the next 16 bytes as a [`RawUuid`], naming `field` if they are not there.
fn read_uuid(reader: &mut ByteReader<'_>, field: &str) -> Result<RawUuid> {
    let bytes = reader.read_bytes(SESSION_ID_BYTE_COUNT)?;
    RawUuid::try_from(bytes).map_err(|_| WireError::malformed(format!("{field}: invalid uuid bytes")))
}

/// Reads a `u32`-length-prefixed opaque payload, validating the declared length first, and records
/// where it sat. Answers an empty vector instead of a copy when `elide` is set — see
/// [`WireMessage::decode_leaving_opaque_run`].
fn read_sized_payload(reader: &mut ByteReader<'_>, run: &mut Range<usize>, elide: bool) -> Result<Vec<u8>> {
    // A declared length wider than this platform's `usize` cannot possibly be present, so it is
    // truncation — the same answer `read_bytes` would give, reached without a cast.
    let len = usize::try_from(reader.read_u32()?).map_err(|_| WireError::Truncated)?;
    let start = reader.position();
    let bytes = reader.read_bytes(len)?;
    *run = start..start.saturating_add(bytes.len());
    Ok(if elide { Vec::new() } else { bytes.to_vec() })
}

/// Takes everything left as the message's opaque run, recording where it sat. The trailing-run
/// counterpart of [`read_sized_payload`], and elides the copy on the same terms.
fn read_trailing_payload(reader: &mut ByteReader<'_>, run: &mut Range<usize>, elide: bool) -> Vec<u8> {
    let start = reader.position();
    let bytes = reader.remaining();
    *run = start..start.saturating_add(bytes.len());
    if elide { Vec::new() } else { bytes.to_vec() }
}

impl WireMessage {
    /// Encodes this message into a complete frame, ready to write to a socket.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut w = ByteWriter::with_capacity(self.wire_byte_count());
        self.encode_into(self.opaque_run(), &mut w);
        w.into_vec()
    }

    /// Encodes into a buffer the CALLER owns, with the opaque byte run supplied APART from the
    /// message, and answers the size under the §4 convention: `n <= out.len()` wrote the frame,
    /// `n > out.len()` left `out` unspecified and asks to be called again with that much room.
    ///
    /// The pair exists for one reason, and it is the reason the wire has a hot path at all: an
    /// `.output` under a flood is 32 KiB of payload wrapped in nine bytes of header. Going through
    /// [`encode`](Self::encode) at an FFI boundary copies those 32 KiB THREE times — once to put
    /// them in the message, once into the encoder's `Vec`, once out of it. Handing the run over as
    /// a slice and lending the encoder the destination makes it one.
    pub fn encode_with_run_into(&self, run: &[u8], out: &mut [u8]) -> usize {
        let needed = self.wire_byte_count_with_run(run.len());
        if needed > out.len() {
            return needed;
        }
        let mut w = ByteWriter::borrowing(out);
        self.encode_into(run, &mut w);
        w.len()
    }

    /// The message's own opaque byte run — empty for the arms that do not end in one.
    #[must_use]
    pub fn opaque_run(&self) -> &[u8] {
        match *self {
            Self::Output { ref bytes, .. } | Self::Input(ref bytes) => bytes,
            Self::BlockOutput { ref output, .. } => output,
            Self::MetadataRequest { ref payload, .. }
            | Self::MetadataResponse { ref payload, .. }
            | Self::WorkspaceRequest { ref payload, .. }
            | Self::WorkspaceEvent { ref payload, .. } => payload,
            _ => &[],
        }
    }

    #[expect(
        clippy::too_many_lines,
        reason = "one arm per message type; splitting the table hides the layout it exists to show"
    )]
    fn encode_into(&self, run: &[u8], w: &mut ByteWriter<'_>) {
        w.put_u32(0); // length placeholder, back-patched below
        w.put_u8(self.message_type());

        match *self {
            Self::Output { seq, .. } => {
                w.put_i64(seq);
                w.put_bytes(run);
            },

            Self::Exit { code } => w.put_i32(code),

            Self::Input(_) => w.put_bytes(run),

            Self::Hello {
                protocol_version,
                ref session_id,
                last_received_seq,
            } => {
                w.put_u16(protocol_version);
                w.put_bytes(session_id);
                w.put_i64(last_received_seq);
            },

            Self::Resize {
                cols,
                rows,
                px_width,
                px_height,
            } => {
                w.put_u16(cols);
                w.put_u16(rows);
                w.put_u16(px_width);
                w.put_u16(px_height);
            },

            Self::Ack { seq } => w.put_i64(seq),

            Self::Bye | Self::Bell => {}, // empty body

            Self::Ping { timestamp_ms } | Self::Pong { timestamp_ms } => w.put_u64(timestamp_ms),

            Self::RequestBlockOutput { index } => w.put_u32(index),

            Self::HelloAck {
                ref session_id,
                resume_from_seq,
                returning_client,
            } => {
                w.put_bytes(session_id);
                w.put_i64(resume_from_seq);
                w.put_bool(returning_client);
            },

            // A single trailing string: the remainder IS the value, so no length prefix is needed
            // for it to be unambiguous.
            Self::Title(ref text)
            | Self::Cwd(ref text)
            | Self::ProjectKey(ref text)
            | Self::AgentSessionIntent(ref text) => w.put_bytes(text.as_bytes()),

            Self::ForegroundProcess { ref name } => w.put_bytes(name.as_bytes()),

            // [u16 rootLen][repoRoot][u16 branchLen][branch][3× i32][5× u32]. BOTH strings are
            // length-prefixed because the branch is not the last field, and both are clamped so a
            // pathological value cannot wrap its length and mis-split the fixed trailer.
            Self::ProjectGitStatus(ref status) => {
                w.put_length_prefixed_str(&status.repo_root);
                w.put_length_prefixed_str(&status.branch);
                w.put_i32(status.ahead);
                w.put_i32(status.behind);
                w.put_i32(status.stash_count);
                w.put_u32(status.staged);
                w.put_u32(status.modified);
                w.put_u32(status.untracked);
                w.put_u32(status.conflicted);
                w.put_u32(status.changed_count);
            },

            // [u16 titleLen][title][body] — the title is length-prefixed so the body, which may
            // contain anything including no delimiter, is the unambiguous remainder.
            Self::Notification { ref title, ref body } => {
                w.put_length_prefixed_str(title);
                w.put_bytes(body.as_bytes());
            },

            // [u8 state][u8 kind][u16 labelLen][label] — the label is length-prefixed so an EMPTY
            // label stays distinguishable from an absent one.
            Self::ClaudeStatus {
                state,
                kind,
                ref label,
            } => {
                w.put_u8(state);
                w.put_u8(kind);
                w.put_length_prefixed_str(label);
            },

            // Fixed fields, then the length-prefixed command line last. Absent optionals travel as
            // a 0 presence flag plus a 0 value, so the body stays fixed-size up to the text.
            Self::CommandBlock {
                index,
                exit_code,
                duration_ms,
                complete,
                output_len,
                ref command_text,
                prompt_ordinal,
            } => {
                w.put_u32(index);
                w.put_bool(exit_code.is_some());
                w.put_i32(exit_code.unwrap_or(0));
                w.put_bool(duration_ms.is_some());
                w.put_u32(duration_ms.unwrap_or(0));
                w.put_bool(complete);
                w.put_u32(output_len);
                w.put_u32(prompt_ordinal);
                w.put_length_prefixed_str(command_text);
            },

            Self::BlockOutput { index, .. } => {
                w.put_u32(index);
                w.put_u32(wire_length(run.len()));
                w.put_bytes(run);
            },

            // The three verb-multiplexed envelopes share one layout: [u32 id][u8 discriminant]
            // [u32 payloadLen][payload]. The payload is length-prefixed so the decoder validates
            // before reading, and opaque so this crate never parses workspace or metadata state.
            Self::MetadataRequest {
                request_id: id,
                verb: tag,
                ..
            }
            | Self::MetadataResponse {
                request_id: id,
                status: tag,
                ..
            }
            | Self::WorkspaceRequest {
                request_seq: id,
                verb: tag,
                ..
            } => {
                w.put_u32(id);
                w.put_u8(tag);
                w.put_u32(wire_length(run.len()));
                w.put_bytes(run);
            },

            // [u8 kind][16B epoch][i64 base][i64 new][u32 payloadLen][payload] — the epoch and both
            // state numbers sit AHEAD of the payload so a mis-based frame is rejected after a fixed
            // 33-byte header read, without parsing state about to be discarded.
            Self::WorkspaceEvent {
                kind,
                ref epoch,
                base_state_num,
                new_state_num,
                ..
            } => {
                w.put_u8(kind);
                w.put_bytes(epoch);
                w.put_i64(base_state_num);
                w.put_i64(new_state_num);
                w.put_u32(wire_length(run.len()));
                w.put_bytes(run);
            },

            Self::InputEcho { enabled } => w.put_bool(enabled),

            Self::Progress { state, percent } => {
                w.put_u8(state);
                w.put_u8(percent);
            },

            // A tag byte discriminates the two cases; `Idle`'s body is FIXED-SIZE, so it needs no
            // length prefix.
            Self::CommandStatus(status) => {
                match status {
                    CommandStatus::Running => w.put_u8(0),
                    CommandStatus::Idle {
                        exit_code,
                        duration_ms,
                    } => {
                        w.put_u8(1);
                        w.put_bool(exit_code.is_some());
                        w.put_i32(exit_code.unwrap_or(0));
                        w.put_u32(duration_ms);
                    },
                }
            },
        }

        // payloadLength counts [type][body] — everything after the 4-byte prefix.
        let payload_length = wire_length(w.len().saturating_sub(4));
        w.patch_u32(0, payload_length);
    }

    /// Decodes a message from a COMPLETE payload (`[u8 message_type][body…]`, without the length
    /// prefix — framing is [`FrameDecoder`](crate::FrameDecoder)'s job).
    ///
    /// # Errors
    /// [`WireError::Truncated`] when the body is shorter than its type requires,
    /// [`WireError::UnknownMessageType`] for an unrecognised type byte, or
    /// [`WireError::MalformedBody`] for a right-length-but-invalid body.
    pub fn decode(payload: &[u8]) -> Result<Self> {
        Self::decode_inner(payload, &mut (0..0), false)
    }

    /// Decodes without materialising the message's opaque byte run, answering WHERE it sits.
    ///
    /// Six arms end in a run of bytes this codec never looks inside — an `output` payload, an
    /// `input`, a block's captured output, a metadata or workspace body. For a caller that still
    /// holds the datagram, a copy of that run is worse than useless: it takes a copy the caller
    /// then copies again, and the run is exactly the field big enough for that to show up. So this
    /// form answers the RANGE and leaves the field empty.
    ///
    /// The returned message's opaque field is EMPTY — it is not the message, it is everything but
    /// the run. A message with no opaque run answers an empty range, which is the same instruction:
    /// there are no bytes to read in place.
    ///
    /// # Errors
    /// Whatever [`Self::decode`] answers — this is the same parser, on the same table.
    pub fn decode_leaving_opaque_run(payload: &[u8]) -> Result<(Self, Range<usize>)> {
        let mut run = 0..0;
        let message = Self::decode_inner(payload, &mut run, true)?;
        Ok((message, run))
    }

    #[expect(
        clippy::too_many_lines,
        reason = "one arm per message type; splitting the table hides the layout it exists to show"
    )]
    fn decode_inner(payload: &[u8], run: &mut Range<usize>, elide: bool) -> Result<Self> {
        let mut r = ByteReader::new(payload);
        let message_type = r.read_u8()?;

        match message_type {
            1 => {
                Ok(Self::Output {
                    seq: r.read_i64()?,
                    bytes: read_trailing_payload(&mut r, run, elide),
                })
            },

            2 => Ok(Self::Exit { code: r.read_i32()? }),

            3 => Ok(Self::Input(read_trailing_payload(&mut r, run, elide))),

            10 => {
                let protocol_version = r.read_u16()?;
                let session_id = read_uuid(&mut r, "hello")?;
                Ok(Self::Hello {
                    protocol_version,
                    session_id,
                    last_received_seq: r.read_i64()?,
                })
            },

            11 => {
                Ok(Self::Resize {
                    cols: r.read_u16()?,
                    rows: r.read_u16()?,
                    px_width: r.read_u16()?,
                    px_height: r.read_u16()?,
                })
            },

            12 => Ok(Self::Ack { seq: r.read_i64()? }),

            13 => Ok(Self::Bye),

            14 => {
                Ok(Self::Ping {
                    timestamp_ms: r.read_u64()?,
                })
            },

            15 => Ok(Self::RequestBlockOutput { index: r.read_u32()? }),

            16 => {
                let request_id = r.read_u32()?;
                let verb = r.read_u8()?;
                Ok(Self::MetadataRequest {
                    request_id,
                    verb,
                    payload: read_sized_payload(&mut r, run, elide)?,
                })
            },

            17 => {
                let request_seq = r.read_u32()?;
                let verb = r.read_u8()?;
                Ok(Self::WorkspaceRequest {
                    request_seq,
                    verb,
                    payload: read_sized_payload(&mut r, run, elide)?,
                })
            },

            20 => {
                let session_id = read_uuid(&mut r, "helloAck")?;
                Ok(Self::HelloAck {
                    session_id,
                    resume_from_seq: r.read_i64()?,
                    returning_client: r.read_bool()?,
                })
            },

            21 => Ok(Self::Title(r.remaining_str("title")?)),

            22 => Ok(Self::Bell),

            23 => {
                match r.read_u8()? {
                    0 => Ok(Self::CommandStatus(CommandStatus::Running)),
                    1 => {
                        let has_exit = r.read_bool()?;
                        let exit_raw = r.read_i32()?;
                        Ok(Self::CommandStatus(CommandStatus::Idle {
                            exit_code: has_exit.then_some(exit_raw),
                            duration_ms: r.read_u32()?,
                        }))
                    },
                    tag => Err(WireError::malformed(format!("commandStatus: invalid tag {tag}"))),
                }
            },

            24 => {
                Ok(Self::Pong {
                    timestamp_ms: r.read_u64()?,
                })
            },

            25 => {
                let title = r.read_length_prefixed_str("notification title")?;
                Ok(Self::Notification {
                    title,
                    body: r.remaining_str("notification body")?,
                })
            },

            26 => {
                Ok(Self::ForegroundProcess {
                    name: r.remaining_str("foregroundProcess")?,
                })
            },

            27 => {
                let state = r.read_u8()?;
                let kind = r.read_u8()?;
                Ok(Self::ClaudeStatus {
                    state,
                    kind,
                    label: r.read_length_prefixed_str("claudeStatus label")?,
                })
            },

            28 => {
                let index = r.read_u32()?;
                let has_exit = r.read_bool()?;
                let exit_raw = r.read_i32()?;
                let has_duration = r.read_bool()?;
                let duration_raw = r.read_u32()?;
                let complete = r.read_bool()?;
                let output_len = r.read_u32()?;
                let prompt_ordinal = r.read_u32()?;
                Ok(Self::CommandBlock {
                    index,
                    exit_code: has_exit.then_some(exit_raw),
                    duration_ms: has_duration.then_some(duration_raw),
                    complete,
                    output_len,
                    command_text: r.read_length_prefixed_str("commandBlock commandText")?,
                    prompt_ordinal,
                })
            },

            29 => {
                let index = r.read_u32()?;
                Ok(Self::BlockOutput {
                    index,
                    output: read_sized_payload(&mut r, run, elide)?,
                })
            },

            30 => {
                let request_id = r.read_u32()?;
                let status = r.read_u8()?;
                Ok(Self::MetadataResponse {
                    request_id,
                    status,
                    payload: read_sized_payload(&mut r, run, elide)?,
                })
            },

            31 => {
                Ok(Self::InputEcho {
                    enabled: r.read_bool()?,
                })
            },

            32 => {
                Ok(Self::Progress {
                    state: r.read_u8()?,
                    percent: r.read_u8()?,
                })
            },

            33 => Ok(Self::Cwd(r.remaining_str("cwd")?)),

            34 => Ok(Self::ProjectKey(r.remaining_str("projectKey")?)),

            35 => {
                Ok(Self::ProjectGitStatus(ProjectGitStatus {
                    repo_root: r.read_length_prefixed_str("projectGitStatus repoRoot")?,
                    branch: r.read_length_prefixed_str("projectGitStatus branch")?,
                    ahead: r.read_i32()?,
                    behind: r.read_i32()?,
                    stash_count: r.read_i32()?,
                    staged: r.read_u32()?,
                    modified: r.read_u32()?,
                    untracked: r.read_u32()?,
                    conflicted: r.read_u32()?,
                    changed_count: r.read_u32()?,
                }))
            },

            36 => Ok(Self::AgentSessionIntent(r.remaining_str("agentSessionIntent")?)),

            37 => {
                let kind = r.read_u8()?;
                let epoch = read_uuid(&mut r, "workspaceEvent epoch")?;
                let base_state_num = r.read_i64()?;
                let new_state_num = r.read_i64()?;
                Ok(Self::WorkspaceEvent {
                    kind,
                    epoch,
                    base_state_num,
                    new_state_num,
                    payload: read_sized_payload(&mut r, run, elide)?,
                })
            },

            unknown => Err(WireError::UnknownMessageType(unknown)),
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use crate::error::WireError;
    use crate::message::{CommandStatus, NEW_SESSION_ID, ProjectGitStatus, RawUuid, WireMessage};

    fn uuid(seed: u8) -> RawUuid {
        let mut bytes = [0_u8; 16];
        for (i, slot) in bytes.iter_mut().enumerate() {
            *slot = seed.wrapping_add(u8::try_from(i).unwrap_or(0));
        }
        bytes
    }

    /// One value per message type — the list the round-trip and size tests both sweep. Split in
    /// two only because each half is a long literal; the tests always sweep the concatenation.
    fn every_variant() -> Vec<WireMessage> {
        let mut all = client_to_host();
        all.append(&mut host_to_client());
        all
    }

    fn client_to_host() -> Vec<WireMessage> {
        vec![
            WireMessage::Output {
                seq: 1,
                bytes: b"hello \x1b[31mworld".to_vec(),
            },
            WireMessage::Exit { code: -1 },
            WireMessage::Input(b"ls -la\r".to_vec()),
            WireMessage::Hello {
                protocol_version: 1,
                session_id: NEW_SESSION_ID,
                last_received_seq: 0,
            },
            WireMessage::Hello {
                protocol_version: 1,
                session_id: uuid(3),
                last_received_seq: i64::MAX,
            },
            WireMessage::Resize {
                cols: 80,
                rows: 24,
                px_width: 640,
                px_height: 480,
            },
            WireMessage::Ack { seq: 42 },
            WireMessage::Bye,
            WireMessage::Ping {
                timestamp_ms: u64::MAX,
            },
            WireMessage::RequestBlockOutput { index: 7 },
            WireMessage::MetadataRequest {
                request_id: 9,
                verb: 3,
                payload: vec![1, 2, 3],
            },
            WireMessage::MetadataRequest {
                request_id: 9,
                verb: 3,
                payload: Vec::new(),
            },
            WireMessage::WorkspaceRequest {
                request_seq: 4,
                verb: 0,
                payload: vec![0xFF],
            },
        ]
    }

    fn host_to_client() -> Vec<WireMessage> {
        vec![
            WireMessage::HelloAck {
                session_id: uuid(9),
                resume_from_seq: -5,
                returning_client: true,
            },
            WireMessage::Title("~/src/slop-desk — zsh ✅".to_owned()),
            WireMessage::Bell,
            WireMessage::CommandStatus(CommandStatus::Running),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(-2),
                duration_ms: 1234,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            }),
            WireMessage::Pong { timestamp_ms: 7 },
            WireMessage::Notification {
                title: String::new(),
                body: "build done".to_owned(),
            },
            WireMessage::Notification {
                title: "µ".to_owned(),
                body: String::new(),
            },
            WireMessage::ForegroundProcess {
                name: "claude".to_owned(),
            },
            WireMessage::ForegroundProcess { name: String::new() },
            WireMessage::ClaudeStatus {
                state: 4,
                kind: 1,
                label: "needs permission".to_owned(),
            },
            WireMessage::ClaudeStatus {
                state: 0,
                kind: 0,
                label: String::new(),
            },
            WireMessage::CommandBlock {
                index: 2,
                exit_code: Some(0),
                duration_ms: Some(90),
                complete: true,
                output_len: 4096,
                command_text: "cargo test".to_owned(),
                prompt_ordinal: 11,
            },
            WireMessage::CommandBlock {
                index: 0,
                exit_code: None,
                duration_ms: None,
                complete: false,
                output_len: 0,
                command_text: String::new(),
                prompt_ordinal: 0,
            },
            WireMessage::BlockOutput {
                index: 2,
                output: vec![0, 1, 2, 3],
            },
            WireMessage::MetadataResponse {
                request_id: 9,
                status: 2,
                payload: vec![7],
            },
            WireMessage::InputEcho { enabled: false },
            WireMessage::InputEcho { enabled: true },
            WireMessage::Progress {
                state: 1,
                percent: 50,
            },
            WireMessage::Cwd("/Volumes/Lacie/Workspace".to_owned()),
            WireMessage::ProjectKey("/Volumes/Lacie/Workspace/oss/slop-desk".to_owned()),
            WireMessage::ProjectGitStatus(ProjectGitStatus {
                repo_root: "/repo".to_owned(),
                branch: "main".to_owned(),
                ahead: 2,
                behind: -1,
                stash_count: 3,
                staged: 4,
                modified: 5,
                untracked: 6,
                conflicted: 7,
                changed_count: 8,
            }),
            WireMessage::ProjectGitStatus(ProjectGitStatus::default()),
            WireMessage::AgentSessionIntent("fix the flaky CI test".to_owned()),
            WireMessage::WorkspaceEvent {
                kind: 1,
                epoch: uuid(200),
                base_state_num: 5,
                new_state_num: 6,
                payload: vec![9, 9, 9],
            },
        ]
    }

    fn round_trip(message: &WireMessage) -> WireMessage {
        let frame = message.encode();
        // Strip the 4-byte length prefix; `decode` takes the payload, not the frame.
        WireMessage::decode(frame.get(4..).expect("a frame always carries its prefix"))
            .expect("a self-encoded frame decodes")
    }

    #[test]
    fn every_variant_survives_a_round_trip_unchanged() {
        for message in every_variant() {
            assert_eq!(round_trip(&message), message, "round trip changed {message:?}");
        }
    }

    #[test]
    fn the_length_prefix_matches_the_bytes_that_follow_it() {
        for message in every_variant() {
            let frame = message.encode();
            let prefix = frame.get(..4).expect("a frame always carries its prefix");
            let declared = usize::try_from(u32::from_be_bytes(<[u8; 4]>::try_from(prefix).unwrap())).unwrap();
            assert_eq!(
                declared,
                frame.len() - 4,
                "a wrong prefix desynchronises the peer's stream for {message:?}"
            );
        }
    }

    #[test]
    fn wire_byte_count_predicts_the_encoded_size_exactly() {
        // Not a nicety: flow control debits the sender per encoded frame and credits the receiver
        // per `wire_byte_count`, so any disagreement leaks window permanently rather than cancelling.
        for message in every_variant() {
            assert_eq!(
                message.wire_byte_count(),
                message.encode().len(),
                "size prediction disagrees with the encoder for {message:?}"
            );
        }
    }

    #[test]
    fn each_variant_carries_its_documented_type_byte() {
        for message in every_variant() {
            let frame = message.encode();
            assert_eq!(
                frame.get(4).copied(),
                Some(message.message_type()),
                "the type byte must be the first byte after the prefix for {message:?}"
            );
        }
    }

    #[test]
    fn an_absent_optional_is_indistinguishable_from_zero_only_by_its_flag() {
        // The presence flag is the whole difference — `Some(0)` and `None` both write a zero value.
        let present = WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: Some(0),
            duration_ms: 1,
        });
        let absent = WireMessage::CommandStatus(CommandStatus::Idle {
            exit_code: None,
            duration_ms: 1,
        });
        assert_ne!(present.encode(), absent.encode());
        assert_eq!(round_trip(&present), present);
        assert_eq!(round_trip(&absent), absent);
    }

    #[test]
    fn a_frame_can_be_sized_with_its_opaque_run_held_apart() {
        // What the FFI boundary does: decode without the run, then size the frame from the message
        // and the run's length. It must land on the same number `encode` produces.
        for message in every_variant() {
            let frame = message.encode();
            let payload = frame.get(4..).expect("a frame carries its own payload");
            let (elided, run) = WireMessage::decode_leaving_opaque_run(payload).expect("the corpus decodes");
            assert_eq!(
                elided.wire_byte_count_with_run(run.len()),
                frame.len(),
                "sized wrong for {message:?}"
            );
        }
    }

    #[test]
    fn writing_into_a_lent_buffer_is_byte_identical_to_encoding_into_a_vec() {
        // The whole point of the run-apart encoder is that it is the SAME table, so the two forms
        // must agree byte for byte on every variant — including the five whose run is
        // length-prefixed, where a run sourced from the wrong place would still produce a frame of
        // the right SIZE.
        for message in every_variant() {
            let expected = message.encode();
            let mut lent = vec![0xAA; expected.len()];
            let written = message.encode_with_run_into(message.opaque_run(), &mut lent);
            assert_eq!(written, expected.len(), "sized wrong for {message:?}");
            assert_eq!(lent, expected, "wrote differently for {message:?}");
        }
    }

    #[test]
    fn a_lent_buffer_that_is_too_small_is_told_the_size_and_left_alone() {
        let message = WireMessage::Output {
            seq: 7,
            bytes: vec![9; 64],
        };
        let full = message.encode().len();
        for room in 0..full {
            let mut lent = vec![0xAA; room];
            assert_eq!(
                message.encode_with_run_into(message.opaque_run(), &mut lent),
                full
            );
            assert!(
                lent.iter().all(|&byte| byte == 0xAA),
                "wrote into a buffer it refused"
            );
        }
    }

    #[test]
    fn the_eliding_decode_answers_where_every_opaque_run_actually_is() {
        // The two forms are one parser, and this is what holds them to it: for EVERY variant, the
        // range the eliding form reports must select exactly the bytes the copying form returned.
        // Nothing else checks that — an off-by-one in a header width would decode every scalar
        // correctly and hand the caller a payload shifted by a byte.
        for message in every_variant() {
            let frame = message.encode();
            let payload = frame.get(4..).expect("a frame carries its own payload");
            let copied = WireMessage::decode(payload).expect("the corpus decodes");
            let (elided, run) =
                WireMessage::decode_leaving_opaque_run(payload).expect("and decodes the other way");
            let in_place = payload.get(run).expect("the run must be inside the payload");

            match (&copied, &elided) {
                (WireMessage::Output { bytes, .. }, WireMessage::Output { bytes: empty, .. })
                | (WireMessage::Input(bytes), WireMessage::Input(empty))
                | (
                    WireMessage::BlockOutput { output: bytes, .. },
                    WireMessage::BlockOutput { output: empty, .. },
                )
                | (
                    WireMessage::MetadataRequest { payload: bytes, .. },
                    WireMessage::MetadataRequest { payload: empty, .. },
                )
                | (
                    WireMessage::MetadataResponse { payload: bytes, .. },
                    WireMessage::MetadataResponse { payload: empty, .. },
                )
                | (
                    WireMessage::WorkspaceRequest { payload: bytes, .. },
                    WireMessage::WorkspaceRequest { payload: empty, .. },
                )
                | (
                    WireMessage::WorkspaceEvent { payload: bytes, .. },
                    WireMessage::WorkspaceEvent { payload: empty, .. },
                ) => {
                    assert_eq!(in_place, bytes.as_slice(), "wrong run for {copied:?}");
                    assert!(empty.is_empty(), "the eliding form must not carry the run");
                },
                _ => {
                    assert_eq!(
                        &copied, &elided,
                        "an arm with no opaque run must decode identically"
                    );
                    assert!(in_place.is_empty(), "and must report no run: {copied:?}");
                },
            }
        }
    }

    #[test]
    fn an_unknown_type_byte_is_dropped_rather_than_trapping() {
        // What makes a new message type additive within wire version 1.
        assert_eq!(
            WireMessage::decode(&[0xFE]),
            Err(WireError::UnknownMessageType(0xFE))
        );
        assert_eq!(WireMessage::decode(&[99]), Err(WireError::UnknownMessageType(99)));
    }

    #[test]
    fn an_empty_payload_is_truncated_not_a_panic() {
        assert_eq!(WireMessage::decode(&[]), Err(WireError::Truncated));
    }

    #[test]
    fn a_body_shorter_than_its_type_requires_is_truncated() {
        // `exit` needs four bytes after the type byte.
        assert_eq!(WireMessage::decode(&[2, 0, 0]), Err(WireError::Truncated));
        // `hello` needs 2 + 16 + 8.
        assert_eq!(WireMessage::decode(&[10, 0, 1]), Err(WireError::Truncated));
    }

    #[test]
    fn a_declared_length_longer_than_the_body_is_refused() {
        // metadataResponse claiming a 1 MiB payload it did not send.
        let mut hostile = vec![30, 0, 0, 0, 1, 0];
        hostile.extend_from_slice(&0x0010_0000_u32.to_be_bytes());
        assert_eq!(WireMessage::decode(&hostile), Err(WireError::Truncated));
    }

    #[test]
    fn an_invalid_command_status_tag_is_malformed() {
        let err = WireMessage::decode(&[23, 9]).unwrap_err();
        assert_eq!(err, WireError::malformed("commandStatus: invalid tag 9"));
    }

    #[test]
    fn invalid_utf8_in_a_string_field_is_malformed_not_repaired() {
        // A title of one stray continuation byte.
        let err = WireMessage::decode(&[21, 0xFF]).unwrap_err();
        assert_eq!(err, WireError::malformed("title: invalid UTF-8"));
    }

    #[test]
    fn trailing_bytes_after_a_fixed_field_body_are_ignored() {
        // The forward-tolerant half of the additive rule: an old peer meeting a NEW trailing field
        // on a type it knows must keep working, not fault.
        let mut frame = WireMessage::Progress {
            state: 1,
            percent: 50,
        }
        .encode();
        frame.extend_from_slice(b"a future field");
        let payload = frame.get(4..).expect("a frame always carries its prefix");
        assert_eq!(WireMessage::decode(payload).unwrap(), WireMessage::Progress {
            state: 1,
            percent: 50
        });
    }

    #[test]
    fn an_unknown_state_byte_is_carried_verbatim_for_the_consumer_to_clamp() {
        // The decoder must NOT clamp: clamping here would make the byte round-trip lossy and break
        // the pinned vector, and the client is the layer that knows what it can render.
        let future = WireMessage::ClaudeStatus {
            state: 250,
            kind: 199,
            label: String::new(),
        };
        assert_eq!(round_trip(&future), future);
        let future = WireMessage::Progress {
            state: 250,
            percent: 200,
        };
        assert_eq!(round_trip(&future), future);
    }

    #[test]
    fn an_empty_label_stays_distinguishable_because_it_is_length_prefixed() {
        let empty = WireMessage::ClaudeStatus {
            state: 1,
            kind: 0,
            label: String::new(),
        };
        let space = WireMessage::ClaudeStatus {
            state: 1,
            kind: 0,
            label: " ".to_owned(),
        };
        assert_ne!(empty.encode(), space.encode());
        assert_eq!(round_trip(&empty), empty);
    }

    #[test]
    fn a_notification_body_containing_the_title_delimiter_shape_still_splits_correctly() {
        // The reason the title is length-prefixed and the body is not: the body may contain
        // anything at all, including bytes that look like a length.
        let message = WireMessage::Notification {
            title: "t".to_owned(),
            body: "\u{0}\u{1}; ; ;".to_owned(),
        };
        assert_eq!(round_trip(&message), message);
    }

    #[test]
    fn a_data_channel_message_is_data_and_everything_else_is_control() {
        use crate::message::Channel;
        for message in every_variant() {
            let expected = match message.message_type() {
                1..=3 => Channel::Data,
                _ => Channel::Control,
            };
            assert_eq!(message.channel(), expected, "wrong channel for {message:?}");
        }
    }
}
