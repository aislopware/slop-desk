//! The PATH-1 terminal message codec — `[u8 message_type][body…]`, 30 types, both directions.
//!
//! This is the wire the whole product sits on: every keystroke, every byte of PTY output, every
//! title, every agent-status edge. `rust/slopdesk-wire` has carried the whole table since the
//! port's stage 1; this module is what finally lets Swift call it instead of keeping a second copy.
//!
//! ## What crosses is the RECORD, not a frame
//! It used to be both. `docs/63` G.3 moved the client's socket into `slopdesk-clientnet` and G.4
//! deleted what that left stranded: the two byte doors, and the Swift `FrameDecoder` and
//! `encode()`/`decode(payload:)` above them. Nothing on the client wanted a frame any more —
//! `mux_transport`'s inbound callback [`pack`]s a decoded message and `slopdesk_mux_transport_send`
//! [`unpack`]s one — so the only callers the byte pair had left were its own tests and the golden
//! generator. What is exported here is [`pack`]/[`unpack`], the size question the flow control has
//! to ask, and the constants both ends are reasoned against.
//!
//! ## The opaque run never enters the arena, in either direction
//! Six arms end in a run of bytes the codec never looks inside — an `output` payload under a flood,
//! an `input`, a block's captured output, a metadata or workspace body. That run is the only field
//! big enough for a copy to matter, and the old Swift codec copied it exactly once in each
//! direction. So does this boundary: the run is its own `(ptr, len)` span beside the record,
//! `blob_length` says how long it is, and neither side interns it.
//!
//! ## Why there is an arena at all, and what is in it
//! The short TEXT fields cannot be spans: a message may carry two of them (`notification`'s title
//! and body, a git status's repo root and branch), and on the encode side they come from Swift
//! `String`s that have no wire representation until something writes their UTF-8 down. So both
//! directions share a flat byte ARENA holding text and nothing else, with `text_a` / `text_b`
//! naming `(offset, length)` inside it. A title is tens of bytes; the copy is unmeasurable, and it
//! buys a boundary with no allocation crossing it.
//!
//! **`text_*` offsets are into the ARENA. `blob_*` offsets are into the DATAGRAM.** They are
//! different address spaces on purpose, because the two fields have opposite costs.
//!
//! ## Flat, not a union
//! One `#[repr(C)]` struct with a named field per wire scalar. A C union would have to be kept in
//! step with a Rust enum by hand on both sides, which is the exact drift this port removes.

use std::ffi::c_uchar;

use slopdesk_wire::{
    CommandStatus, MAX_FRAME_PAYLOAD_LENGTH, PROTOCOL_VERSION, ProjectGitStatus, SESSION_ID_BYTE_COUNT,
    TCP_KEEPALIVE_IDLE_SECONDS, TCP_KEEPALIVE_INTERVAL_SECONDS, TCP_KEEPALIVE_RETRY_COUNT, WireError,
    WireMessage,
};

use crate::{arena_text, borrow, saturating_u32};

/// The message decoded; every span is valid.
pub const WIRE_DECODE_OK: u32 = 0;
/// The body was shorter than its type requires — drop the frame.
pub const WIRE_DECODE_TRUNCATED: u32 = 1;
/// The first byte was not a message type this build knows.
///
/// A peer that meets one DROPS the frame; that is what makes a new type additive within wire
/// version 1.
pub const WIRE_DECODE_UNKNOWN_TYPE: u32 = 2;
/// The body was the right length but its contents were not — bad UTF-8, a bad uuid.
pub const WIRE_DECODE_MALFORMED: u32 = 3;
/// The arena did not fit; `arena_length` says how much it needs. Nothing else was written.
pub const WIRE_DECODE_AGAIN: u32 = 4;

/// How a [`WireError`] reaches Swift.
pub(crate) const fn verdict(error: &WireError) -> u32 {
    match *error {
        WireError::Truncated => WIRE_DECODE_TRUNCATED,
        WireError::UnknownMessageType(_) => WIRE_DECODE_UNKNOWN_TYPE,
        // A frame's length prefix is the FRAME decoder's business, not this table's; if one ever
        // reached here it is a body that cannot be read, which is what malformed means.
        WireError::FrameTooLarge(_) | WireError::MalformedBody(_) => WIRE_DECODE_MALFORMED,
    }
}

/// One terminal message, flattened.
///
/// Every field is named for the wire field it carries and is meaningful only for the arms that
/// carry it; the rest are zero. `message_type` says which arm, and it is the wire's own type byte.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskWireMessage {
    /// `output.seq` / `ack.seq` — a monotonic per-message index, never a byte offset.
    pub seq: i64,
    /// `hello.lastReceivedSeq`.
    pub last_received_seq: i64,
    /// `helloAck.resumeFromSeq`.
    pub resume_from_seq: i64,
    /// `workspaceEvent.baseStateNum`.
    pub base_state_num: i64,
    /// `workspaceEvent.newStateNum`.
    pub new_state_num: i64,
    /// `ping`/`pong`'s echoed client clock reading.
    pub timestamp_ms: u64,
    /// `exit.code`, or the optional `$?` of a `commandStatus`/`commandBlock` — see
    /// [`Self::has_exit_code`].
    pub exit_code: i32,
    /// `projectGitStatus.ahead`.
    pub ahead: i32,
    /// `projectGitStatus.behind`.
    pub behind: i32,
    /// `projectGitStatus.stashCount`.
    pub stash_count: i32,
    /// The block index of a `requestBlockOutput`, `blockOutput` or `commandBlock`.
    pub index: u32,
    /// A `commandStatus`/`commandBlock` duration — see [`Self::has_duration_ms`].
    pub duration_ms: u32,
    /// `commandBlock.outputLen` — bytes the host holds, NOT bytes on this frame.
    pub output_len: u32,
    /// `commandBlock.promptOrdinal`; 0 means unknown.
    pub prompt_ordinal: u32,
    /// The correlation id of a `metadataRequest`/`metadataResponse`.
    pub request_id: u32,
    /// `workspaceRequest.requestSeq`.
    pub request_seq: u32,
    /// `projectGitStatus.staged`.
    pub staged: u32,
    /// `projectGitStatus.modified`.
    pub modified: u32,
    /// `projectGitStatus.untracked`.
    pub untracked: u32,
    /// `projectGitStatus.conflicted`.
    pub conflicted: u32,
    /// `projectGitStatus.changedCount`.
    pub changed_count: u32,
    /// Where this message's first text field starts IN THE ARENA.
    pub text_a_offset: u32,
    /// How long it is. Zero length means the field is empty or absent — the same instruction.
    pub text_a_length: u32,
    /// Where the second text field starts IN THE ARENA (`notification.body`, a branch name).
    pub text_b_offset: u32,
    /// How long it is.
    pub text_b_length: u32,
    /// Where the opaque byte run starts IN THE DATAGRAM, when decoding. Unused when encoding, where
    /// the run is its own argument.
    pub blob_offset: u32,
    /// How long the opaque run is.
    pub blob_length: u32,
    /// `hello.protocolVersion`.
    pub protocol_version: u16,
    /// `resize.cols`.
    pub cols: u16,
    /// `resize.rows`.
    pub rows: u16,
    /// `resize.pxWidth`, 0 if unknown.
    pub px_width: u16,
    /// `resize.pxHeight`, 0 if unknown.
    pub px_height: u16,
    /// The wire's own message-type byte.
    pub message_type: u8,
    /// For a `commandStatus`: 0 running, 1 idle. The one arm whose body is itself a choice.
    pub command_status: u8,
    /// The raw verb byte of a `metadataRequest` or `workspaceRequest`.
    pub verb: u8,
    /// `metadataResponse.status`, raw.
    pub status: u8,
    /// `claudeStatus.state` or `progress.state`, raw — an unknown future value is the consumer's to
    /// clamp, never this boundary's.
    pub state: u8,
    /// `claudeStatus.kind`, or `workspaceEvent.kind`.
    pub kind: u8,
    /// `progress.percent`, `0…100`.
    pub percent: u8,
    /// `helloAck.returningClient` — decided by the host.
    pub returning_client: bool,
    /// `commandBlock.complete`.
    pub complete: bool,
    /// `inputEcho.enabled`; false is a no-echo password prompt.
    pub enabled: bool,
    /// Whether [`Self::exit_code`] is present. `Some(0)` and `None` write the same value, so the
    /// flag IS the difference.
    pub has_exit_code: bool,
    /// Whether [`Self::duration_ms`] is present.
    pub has_duration_ms: bool,
    /// `hello`/`helloAck`'s session id, 16 raw bytes; all-zero opens a new session.
    pub session_id: [u8; SESSION_ID_BYTE_COUNT],
    /// `workspaceEvent.epoch`, 16 raw bytes; a foreign epoch means reset-then-snapshot.
    pub epoch: [u8; SESSION_ID_BYTE_COUNT],
}

/// A message flattened onto scalars plus the text it interned.
#[derive(Debug)]
pub(crate) struct Packed {
    pub(crate) flat: SlopDeskWireMessage,
    pub(crate) arena: Vec<u8>,
}

impl Packed {
    fn new(message_type: u8) -> Self {
        Self {
            flat: SlopDeskWireMessage {
                message_type,
                ..SlopDeskWireMessage::default()
            },
            arena: Vec::new(),
        }
    }

    /// Appends text to the arena and answers where it went.
    fn intern(&mut self, text: &str) -> (u32, u32) {
        let offset = saturating_u32(self.arena.len());
        self.arena.extend_from_slice(text.as_bytes());
        (offset, saturating_u32(text.len()))
    }

    fn text_a(&mut self, text: &str) {
        let (offset, length) = self.intern(text);
        self.flat.text_a_offset = offset;
        self.flat.text_a_length = length;
    }

    fn text_b(&mut self, text: &str) {
        let (offset, length) = self.intern(text);
        self.flat.text_b_offset = offset;
        self.flat.text_b_length = length;
    }
}

/// Flattens a decoded message, interning its text.
#[expect(
    clippy::too_many_lines,
    reason = "one arm per message type; splitting the table hides the mapping it exists to show"
)]
pub(crate) fn pack(message: &WireMessage, run: &core::ops::Range<usize>) -> Packed {
    let mut packed = Packed::new(message.message_type());
    packed.flat.blob_offset = saturating_u32(run.start);
    packed.flat.blob_length = saturating_u32(run.end.saturating_sub(run.start));

    match *message {
        WireMessage::Output { seq, .. } | WireMessage::Ack { seq } => packed.flat.seq = seq,
        WireMessage::Exit { code } => {
            packed.flat.exit_code = code;
            packed.flat.has_exit_code = true;
        },
        WireMessage::Input(_) | WireMessage::Bye | WireMessage::Bell => {},
        WireMessage::Hello {
            protocol_version,
            session_id,
            last_received_seq,
        } => {
            packed.flat.protocol_version = protocol_version;
            packed.flat.session_id = session_id;
            packed.flat.last_received_seq = last_received_seq;
        },
        WireMessage::Resize {
            cols,
            rows,
            px_width,
            px_height,
        } => {
            packed.flat.cols = cols;
            packed.flat.rows = rows;
            packed.flat.px_width = px_width;
            packed.flat.px_height = px_height;
        },
        WireMessage::Ping { timestamp_ms } | WireMessage::Pong { timestamp_ms } => {
            packed.flat.timestamp_ms = timestamp_ms;
        },
        WireMessage::RequestBlockOutput { index } | WireMessage::BlockOutput { index, .. } => {
            packed.flat.index = index;
        },
        WireMessage::MetadataRequest { request_id, verb, .. } => {
            packed.flat.request_id = request_id;
            packed.flat.verb = verb;
        },
        WireMessage::WorkspaceRequest {
            request_seq, verb, ..
        } => {
            packed.flat.request_seq = request_seq;
            packed.flat.verb = verb;
        },
        WireMessage::HelloAck {
            session_id,
            resume_from_seq,
            returning_client,
        } => {
            packed.flat.session_id = session_id;
            packed.flat.resume_from_seq = resume_from_seq;
            packed.flat.returning_client = returning_client;
        },
        WireMessage::Title(ref text)
        | WireMessage::Cwd(ref text)
        | WireMessage::ProjectKey(ref text)
        | WireMessage::AgentSessionIntent(ref text)
        | WireMessage::ForegroundProcess { name: ref text } => packed.text_a(text),
        WireMessage::CommandStatus(status) => {
            match status {
                CommandStatus::Running => packed.flat.command_status = 0,
                CommandStatus::Idle {
                    exit_code,
                    duration_ms,
                } => {
                    packed.flat.command_status = 1;
                    packed.flat.has_exit_code = exit_code.is_some();
                    packed.flat.exit_code = exit_code.unwrap_or(0);
                    packed.flat.duration_ms = duration_ms;
                    packed.flat.has_duration_ms = true;
                },
            }
        },
        WireMessage::Notification { ref title, ref body } => {
            packed.text_a(title);
            packed.text_b(body);
        },
        WireMessage::ClaudeStatus {
            state,
            kind,
            ref label,
        } => {
            packed.flat.state = state;
            packed.flat.kind = kind;
            packed.text_a(label);
        },
        WireMessage::CommandBlock {
            index,
            exit_code,
            duration_ms,
            complete,
            output_len,
            ref command_text,
            prompt_ordinal,
        } => {
            packed.flat.index = index;
            packed.flat.has_exit_code = exit_code.is_some();
            packed.flat.exit_code = exit_code.unwrap_or(0);
            packed.flat.has_duration_ms = duration_ms.is_some();
            packed.flat.duration_ms = duration_ms.unwrap_or(0);
            packed.flat.complete = complete;
            packed.flat.output_len = output_len;
            packed.flat.prompt_ordinal = prompt_ordinal;
            packed.text_a(command_text);
        },
        WireMessage::MetadataResponse {
            request_id, status, ..
        } => {
            packed.flat.request_id = request_id;
            packed.flat.status = status;
        },
        WireMessage::InputEcho { enabled } => packed.flat.enabled = enabled,
        WireMessage::Progress { state, percent } => {
            packed.flat.state = state;
            packed.flat.percent = percent;
        },
        WireMessage::ProjectGitStatus(ref git) => {
            packed.text_a(&git.repo_root);
            packed.text_b(&git.branch);
            packed.flat.ahead = git.ahead;
            packed.flat.behind = git.behind;
            packed.flat.stash_count = git.stash_count;
            packed.flat.staged = git.staged;
            packed.flat.modified = git.modified;
            packed.flat.untracked = git.untracked;
            packed.flat.conflicted = git.conflicted;
            packed.flat.changed_count = git.changed_count;
        },
        WireMessage::WorkspaceEvent {
            kind,
            epoch,
            base_state_num,
            new_state_num,
            ..
        } => {
            packed.flat.kind = kind;
            packed.flat.epoch = epoch;
            packed.flat.base_state_num = base_state_num;
            packed.flat.new_state_num = new_state_num;
        },
    }
    packed
}

/// Puts a flat message back together, with `blob` as its opaque run.
#[expect(
    clippy::too_many_lines,
    reason = "one arm per message type; splitting the table hides the mapping it exists to show"
)]
pub(crate) fn unpack(flat: &SlopDeskWireMessage, arena: &[u8], blob: &[u8]) -> Option<WireMessage> {
    let first = arena_text(arena, flat.text_a_offset, flat.text_a_length);
    let message = match flat.message_type {
        1 => {
            WireMessage::Output {
                seq: flat.seq,
                bytes: blob.to_vec(),
            }
        },
        2 => WireMessage::Exit { code: flat.exit_code },
        3 => WireMessage::Input(blob.to_vec()),
        10 => {
            WireMessage::Hello {
                protocol_version: flat.protocol_version,
                session_id: flat.session_id,
                last_received_seq: flat.last_received_seq,
            }
        },
        11 => {
            WireMessage::Resize {
                cols: flat.cols,
                rows: flat.rows,
                px_width: flat.px_width,
                px_height: flat.px_height,
            }
        },
        12 => WireMessage::Ack { seq: flat.seq },
        13 => WireMessage::Bye,
        14 => {
            WireMessage::Ping {
                timestamp_ms: flat.timestamp_ms,
            }
        },
        15 => WireMessage::RequestBlockOutput { index: flat.index },
        16 => {
            WireMessage::MetadataRequest {
                request_id: flat.request_id,
                verb: flat.verb,
                payload: blob.to_vec(),
            }
        },
        17 => {
            WireMessage::WorkspaceRequest {
                request_seq: flat.request_seq,
                verb: flat.verb,
                payload: blob.to_vec(),
            }
        },
        20 => {
            WireMessage::HelloAck {
                session_id: flat.session_id,
                resume_from_seq: flat.resume_from_seq,
                returning_client: flat.returning_client,
            }
        },
        21 => WireMessage::Title(first),
        22 => WireMessage::Bell,
        23 => {
            WireMessage::CommandStatus(if flat.command_status == 0 {
                CommandStatus::Running
            } else {
                CommandStatus::Idle {
                    exit_code: flat.has_exit_code.then_some(flat.exit_code),
                    duration_ms: flat.duration_ms,
                }
            })
        },
        24 => {
            WireMessage::Pong {
                timestamp_ms: flat.timestamp_ms,
            }
        },
        25 => {
            WireMessage::Notification {
                title: first,
                body: arena_text(arena, flat.text_b_offset, flat.text_b_length),
            }
        },
        26 => WireMessage::ForegroundProcess { name: first },
        27 => {
            WireMessage::ClaudeStatus {
                state: flat.state,
                kind: flat.kind,
                label: first,
            }
        },
        28 => {
            WireMessage::CommandBlock {
                index: flat.index,
                exit_code: flat.has_exit_code.then_some(flat.exit_code),
                duration_ms: flat.has_duration_ms.then_some(flat.duration_ms),
                complete: flat.complete,
                output_len: flat.output_len,
                command_text: first,
                prompt_ordinal: flat.prompt_ordinal,
            }
        },
        29 => {
            WireMessage::BlockOutput {
                index: flat.index,
                output: blob.to_vec(),
            }
        },
        30 => {
            WireMessage::MetadataResponse {
                request_id: flat.request_id,
                status: flat.status,
                payload: blob.to_vec(),
            }
        },
        31 => {
            WireMessage::InputEcho {
                enabled: flat.enabled,
            }
        },
        32 => {
            WireMessage::Progress {
                state: flat.state,
                percent: flat.percent,
            }
        },
        33 => WireMessage::Cwd(first),
        34 => WireMessage::ProjectKey(first),
        35 => {
            WireMessage::ProjectGitStatus(ProjectGitStatus {
                repo_root: first,
                branch: arena_text(arena, flat.text_b_offset, flat.text_b_length),
                ahead: flat.ahead,
                behind: flat.behind,
                stash_count: flat.stash_count,
                staged: flat.staged,
                modified: flat.modified,
                untracked: flat.untracked,
                conflicted: flat.conflicted,
                changed_count: flat.changed_count,
            })
        },
        36 => WireMessage::AgentSessionIntent(first),
        37 => {
            WireMessage::WorkspaceEvent {
                kind: flat.kind,
                epoch: flat.epoch,
                base_state_num: flat.base_state_num,
                new_state_num: flat.new_state_num,
                payload: blob.to_vec(),
            }
        },
        _ => return None,
    };
    Some(message)
}

/// The byte count this message would occupy as a COMPLETE frame — the four-byte length prefix
/// included — WITHOUT building one.
///
/// The receive side credits this per consumed message and it must match the sender's per-frame
/// debit exactly — a mismatch leaks or over-grants window forever, because the error accumulates
/// rather than cancelling. `blob_len` is the opaque run's length; the run itself is not needed,
/// which is the whole point of asking rather than encoding.
///
/// Answers 0 for a `message_type` no arm claims.
///
/// # Safety
/// `message` must point at one live struct and `arena` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wire_message_byte_count(
    message: *const SlopDeskWireMessage,
    arena: *const c_uchar,
    arena_len: usize,
    blob_len: usize,
) -> usize {
    // SAFETY: one borrow and one struct read, neither outliving the call.
    unsafe {
        let arena = borrow(arena, arena_len);
        unpack(&*message, arena, &[]).map_or(0, |message| message.wire_byte_count_with_run(blob_len))
    }
}

/// Vends the numbers both ends would otherwise spell twice.
///
/// `0` the wire version this build speaks · `1` the bytes a session id occupies · `2` the frame
/// payload ceiling · `3`/`4`/`5` the TCP keepalive ladder every PATH-1 socket is configured with,
/// as idle seconds, probe interval seconds and retry count. Any other index answers 0.
///
/// The ladder is here rather than in the Swift that sets the sockopts because the LISTENER and the
/// DIALLER are two programs — `slopdesk-hostnet` on one side, `NWProtocolTCP.Options` on the other
/// — and a keepalive configured on one end only is a half-open connection neither end reports.
///
/// The two seconds counts are declared `u64` because that is what `Duration::from_secs` takes, and
/// they arrive here as `usize` because that is what C's `size_t` is. Widening one to the other is
/// lossless on every target this ships to and lossy in the type system, so the narrowing is spelled
/// as a `try_from` that falls back to the same `0` an unknown index answers with — an
/// unrepresentable value and an unknown index are the same thing to the caller, and the test below
/// pins all three so the fallback can never be reached silently.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_wire_constant(index: u32) -> usize {
    match index {
        0 => PROTOCOL_VERSION as usize,
        1 => SESSION_ID_BYTE_COUNT,
        2 => MAX_FRAME_PAYLOAD_LENGTH,
        3 => usize::try_from(TCP_KEEPALIVE_IDLE_SECONDS).unwrap_or(0),
        4 => usize::try_from(TCP_KEEPALIVE_INTERVAL_SECONDS).unwrap_or(0),
        5 => TCP_KEEPALIVE_RETRY_COUNT as usize,
        _ => 0,
    }
}

#[cfg(test)]
// The fixtures are built inline and known-good, so `unwrap` IS the assertion, and calling the raw
// entry points the way Swift does is the thing under test.
#[expect(
    clippy::too_many_lines,
    unsafe_code,
    reason = "a panic in a test is the failure report, and the C ABI is what is being exercised"
)]
mod tests {
    use slopdesk_wire::{CommandStatus, ProjectGitStatus, WireMessage};

    use super::{
        SlopDeskWireMessage, pack, slopdesk_wire_constant, slopdesk_wire_message_byte_count, unpack,
    };

    /// Crosses the boundary the way the shipped path does: `pack` on the way out, `unpack` on the
    /// way back, with the opaque run handed over as its own span.
    ///
    /// This is not a convenience — it is the ONLY shape the boundary has. `docs/63` G.4 deleted the
    /// two byte doors these helpers used to drive, because after G.3 put the socket in
    /// `slopdesk-clientnet` nothing on the client asked for a frame: `mux_transport`'s inbound
    /// callback packs, and `slopdesk_mux_transport_send` unpacks. So the round trip below exercises
    /// the pair the product runs, rather than a pair kept alive to be tested.
    fn there_and_back(message: &WireMessage) -> Option<WireMessage> {
        let run = message.opaque_run();
        let packed = pack(message, &(0..run.len()));
        unpack(&packed.flat, &packed.arena, run)
    }

    /// One value per arm — the corpus every test here sweeps.
    fn every_variant() -> Vec<WireMessage> {
        vec![
            WireMessage::Output {
                seq: 42,
                bytes: b"hello \x1b[31mworld".to_vec(),
            },
            WireMessage::Exit { code: -1 },
            WireMessage::Input(b"ls -la\r".to_vec()),
            WireMessage::Hello {
                protocol_version: 1,
                session_id: [7; 16],
                last_received_seq: i64::MAX,
            },
            WireMessage::Resize {
                cols: 80,
                rows: 24,
                px_width: 640,
                px_height: 480,
            },
            WireMessage::Ack { seq: 9 },
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
            WireMessage::WorkspaceRequest {
                request_seq: 4,
                verb: 3,
                payload: vec![9, 9],
            },
            WireMessage::HelloAck {
                session_id: [3; 16],
                resume_from_seq: 5,
                returning_client: true,
            },
            WireMessage::Title("a — títle".to_owned()),
            WireMessage::Bell,
            WireMessage::CommandStatus(CommandStatus::Running),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: Some(0),
                duration_ms: 1234,
            }),
            WireMessage::CommandStatus(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 1234,
            }),
            WireMessage::Pong { timestamp_ms: 8 },
            WireMessage::Notification {
                title: String::new(),
                body: "build done".to_owned(),
            },
            WireMessage::ForegroundProcess {
                name: "claude".to_owned(),
            },
            WireMessage::ClaudeStatus {
                state: 4,
                kind: 1,
                label: "needs permission".to_owned(),
            },
            WireMessage::CommandBlock {
                index: 2,
                exit_code: Some(-9),
                duration_ms: Some(70),
                complete: true,
                output_len: 4096,
                command_text: "cargo test".to_owned(),
                prompt_ordinal: 3,
            },
            WireMessage::CommandBlock {
                index: 2,
                exit_code: None,
                duration_ms: None,
                complete: false,
                output_len: 0,
                command_text: String::new(),
                prompt_ordinal: 0,
            },
            WireMessage::BlockOutput {
                index: 2,
                output: vec![0xAA; 300],
            },
            WireMessage::MetadataResponse {
                request_id: 11,
                status: 2,
                payload: vec![],
            },
            WireMessage::InputEcho { enabled: false },
            WireMessage::Progress {
                state: 1,
                percent: 40,
            },
            WireMessage::Cwd("/Volumes/x".to_owned()),
            WireMessage::ProjectKey("/Volumes".to_owned()),
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
            WireMessage::AgentSessionIntent("fix the flaky test".to_owned()),
            WireMessage::WorkspaceEvent {
                kind: 1,
                epoch: [9; 16],
                base_state_num: 3,
                new_state_num: 4,
                payload: vec![1, 2, 3, 4],
            },
        ]
    }

    /// Every arm survives the trip out and back, and comes back as the same message.
    #[test]
    fn every_message_round_trips_through_the_boundary() {
        for message in every_variant() {
            assert_eq!(there_and_back(&message).as_ref(), Some(&message), "{message:?}");
        }
    }

    /// The flat record's own answer for how many bytes the frame takes is the crate's answer.
    ///
    /// This is the one number the flow control depends on and the only reason the door survives:
    /// the receive side credits it per consumed message and it must equal the sender's per-frame
    /// debit exactly, because the error accumulates rather than cancelling. Checked against
    /// `encode().len()` — the crate that owns the layout — and never against a second count here.
    #[test]
    fn the_size_a_frame_is_asked_for_is_the_size_the_crate_encodes_to() {
        for message in every_variant() {
            let run = message.opaque_run();
            let packed = pack(&message, &(0..run.len()));
            // SAFETY: the arena is a live local for the duration of the call.
            let asked = unsafe {
                slopdesk_wire_message_byte_count(
                    &raw const packed.flat,
                    packed.arena.as_ptr(),
                    packed.arena.len(),
                    run.len(),
                )
            };
            assert_eq!(asked, message.encode().len(), "{message:?}");
        }
    }

    /// The opaque run crosses as its own span and never enters the arena.
    ///
    /// The arena is for the SHORT strings — a title, a cwd, a branch name. An `.output` payload
    /// under a flood is the one field big enough for a copy to be felt, so it is handed over
    /// beside the record rather than interned into it.
    #[test]
    fn the_opaque_run_never_enters_the_arena() {
        let message = WireMessage::Output {
            seq: 1,
            bytes: vec![0xEE; 4096],
        };
        let run = message.opaque_run();
        let packed = pack(&message, &(0..run.len()));
        assert_eq!(packed.flat.blob_length, 4096);
        assert_eq!(packed.flat.blob_offset, 0);
        assert!(packed.arena.is_empty(), "the run must not enter the arena");
    }

    /// A type byte no arm answers to unpacks to nothing rather than to a wrong message.
    #[test]
    fn an_unknown_type_unpacks_to_nothing() {
        let flat = SlopDeskWireMessage {
            message_type: 0xFE,
            ..SlopDeskWireMessage::default()
        };
        assert!(unpack(&flat, &[], &[]).is_none());
        // And the size door agrees: 0 bytes, not a frame of the wrong shape.
        // SAFETY: null input pairs are explicitly permitted by the door.
        let needed = unsafe { slopdesk_wire_message_byte_count(&raw const flat, std::ptr::null(), 0, 0) };
        assert_eq!(needed, 0);
    }

    /// The vended constants are the crate's, not a second spelling of them.
    #[test]
    fn the_constants_come_from_the_crate() {
        assert_eq!(slopdesk_wire_constant(0), 1);
        assert_eq!(slopdesk_wire_constant(1), 16);
        assert_eq!(slopdesk_wire_constant(2), 16 * 1024 * 1024);
        assert_eq!(slopdesk_wire_constant(3), 10);
        assert_eq!(slopdesk_wire_constant(4), 5);
        assert_eq!(slopdesk_wire_constant(5), 3);
        assert_eq!(slopdesk_wire_constant(99), 0);
    }
}
