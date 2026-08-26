//! The PATH-1 terminal message codec — `[u8 message_type][body…]`, 30 types, both directions.
//!
//! This is the wire the whole product sits on: every keystroke, every byte of PTY output, every
//! title, every agent-status edge. `rust/slopdesk-wire` has carried the whole table since the
//! port's stage 1; this module is what finally lets Swift call it instead of keeping a second copy.
//!
//! ## The opaque run never enters the arena, in either direction
//! Six arms end in a run of bytes the codec never looks inside — an `output` payload under a flood,
//! an `input`, a block's captured output, a metadata or workspace body. That run is the only field
//! big enough for a copy to matter, and the old Swift codec copied it exactly once in each
//! direction. So does this boundary:
//!
//! - **Decoding**, the run answers as `(blob_offset, blob_length)` into the caller's own datagram —
//!   [`WireMessage::decode_leaving_opaque_run`] never materialises it — and Swift makes its one
//!   durable copy straight out of the bytes it already holds.
//! - **Encoding**, the run is its own `(ptr, len)` argument, copied once into the answer.
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

use crate::{arena_text, borrow, deliver, saturating_u32};

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
fn unpack(flat: &SlopDeskWireMessage, arena: &[u8], blob: &[u8]) -> Option<WireMessage> {
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

/// Decodes one message payload (`[type][body…]`, no length prefix — framing is the decoder's job).
///
/// Text lands in `arena` and is named by the `text_*` spans; the opaque byte run is NOT copied —
/// the `blob_*` span points into `payload`, which the caller already holds.
///
/// Returns one of the `SLOPDESK_WIRE_DECODE_*` verdicts. On
/// [`WIRE_DECODE_AGAIN`] the message's `arena_length`… is not available, so the caller retries with
/// a buffer as large as `payload` — text on this wire is a substring of the datagram, so that
/// always fits.
///
/// # Safety
/// `payload` must describe live memory for the call, `out` must be writable for one
/// [`SlopDeskWireMessage`], and `arena` must be writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wire_message_decode(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskWireMessage,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's; `borrow` and `deliver` restate them.
    unsafe {
        let bytes = borrow(payload, payload_len);
        let (message, run) = match WireMessage::decode_leaving_opaque_run(bytes) {
            Ok(decoded) => decoded,
            Err(error) => return verdict(&error),
        };
        let packed = pack(&message, &run);
        if packed.arena.len() > arena_cap || out.is_null() {
            return WIRE_DECODE_AGAIN;
        }
        deliver(&packed.arena, arena, arena_cap);
        out.write(packed.flat);
        WIRE_DECODE_OK
    }
}

/// Encodes one message into a COMPLETE frame — the four-byte length prefix included.
///
/// `arena` holds the text the `text_*` spans name; `blob` is the opaque byte run, passed whole
/// because it is the one field a copy would be felt on. Returns the byte count under the §4
/// convention: `n <= cap` wrote the frame, `n > cap` wrote nothing, `0` means no arm answers to
/// this type byte.
///
/// # Safety
/// `message` must point at one live struct, every input pair must describe live memory for the
/// call, and `out` must be writable for `cap` bytes. The struct crosses by POINTER because it is
/// nearly 200 bytes wide and every caller already holds one — passing it by value made the C ABI
/// copy it into a temporary on both sides of a call this sits on the hot path of.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_wire_message_encode(
    message: *const SlopDeskWireMessage,
    arena: *const c_uchar,
    arena_len: usize,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: as above — one struct read, three borrows and one lent buffer, none outliving the
    // call.
    unsafe {
        let arena = borrow(arena, arena_len);
        let blob = borrow(blob, blob_len);
        // The message is built WITHOUT its opaque run and the run is handed to the encoder beside
        // it, so a 32 KiB `.output` under a flood crosses this boundary copied once — into the
        // caller's own buffer — rather than three times.
        let Some(message) = unpack(&*message, arena, &[]) else {
            return 0;
        };
        let out = if out.is_null() || cap == 0 {
            &mut [][..]
        } else {
            core::slice::from_raw_parts_mut(out, cap)
        };
        message.encode_with_run_into(blob, out)
    }
}

/// The byte count [`slopdesk_wire_message_encode`] would produce, WITHOUT building the frame.
///
/// The receive side credits this per consumed message and it must match the sender's per-frame
/// debit exactly — a mismatch leaks or over-grants window forever, because the error accumulates
/// rather than cancelling. `blob_len` is the opaque run's length; the run itself is not needed,
/// which is the whole point of asking rather than encoding.
///
/// Answers 0 for a `message_type` no arm claims — the same "no answer" the encoder gives.
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
    clippy::indexing_slicing,
    clippy::too_many_lines,
    unsafe_code,
    reason = "a panic in a test is the failure report, and the C ABI is what is being exercised"
)]
mod tests {
    use slopdesk_wire::{CommandStatus, ProjectGitStatus, WireMessage};

    use super::{
        SlopDeskWireMessage, WIRE_DECODE_AGAIN, WIRE_DECODE_OK, WIRE_DECODE_TRUNCATED,
        WIRE_DECODE_UNKNOWN_TYPE, slopdesk_wire_constant, slopdesk_wire_message_byte_count,
        slopdesk_wire_message_decode, slopdesk_wire_message_encode,
    };

    /// Decodes the way the Swift wrapper does, answering the verdict, the flat message and the
    /// arena.
    fn decode(payload: &[u8]) -> (u32, SlopDeskWireMessage, Vec<u8>) {
        let mut flat = SlopDeskWireMessage::default();
        let mut arena = vec![0_u8; payload.len().max(1)];
        // SAFETY: every pointer is a live local for the duration of the call.
        let verdict = unsafe {
            slopdesk_wire_message_decode(
                payload.as_ptr(),
                payload.len(),
                &raw mut flat,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        (verdict, flat, arena)
    }

    /// Encodes the way the Swift wrapper does: size, then write.
    fn encode(flat: SlopDeskWireMessage, arena: &[u8], blob: &[u8]) -> Vec<u8> {
        // SAFETY: the pointers are live locals; a null `out` with cap 0 is the size query.
        let needed = unsafe {
            slopdesk_wire_message_encode(
                &raw const flat,
                arena.as_ptr(),
                arena.len(),
                blob.as_ptr(),
                blob.len(),
                std::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![0_u8; needed];
        // SAFETY: `out` is now large enough, and every input is still live.
        let written = unsafe {
            slopdesk_wire_message_encode(
                &raw const flat,
                arena.as_ptr(),
                arena.len(),
                blob.as_ptr(),
                blob.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed, "the sizing call and the writing call disagreed");
        out
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
            let frame = message.encode();
            let payload = &frame[4..];
            let (verdict, flat, arena) = decode(payload);
            assert_eq!(verdict, WIRE_DECODE_OK, "{message:?}");
            assert_eq!(flat.message_type, message.message_type());

            let blob = &payload[flat.blob_offset as usize..][..flat.blob_length as usize];
            let back = encode(flat, &arena, blob);
            assert_eq!(back, frame, "{message:?}");
        }
    }

    /// The boundary's bytes are the crate's bytes — not merely a round trip that agrees with
    /// itself.
    #[test]
    fn the_frame_is_byte_identical_to_the_crate_that_owns_the_layout() {
        for message in every_variant() {
            let frame = message.encode();
            let (_, flat, arena) = decode(&frame[4..]);
            let blob = &frame[4..][flat.blob_offset as usize..][..flat.blob_length as usize];
            assert_eq!(encode(flat, &arena, blob), frame, "{message:?}");
        }
    }

    /// Asking for the size and encoding must land on the same number, for every arm.
    #[test]
    fn the_size_a_frame_is_asked_for_is_the_size_it_encodes_to() {
        for message in every_variant() {
            let frame = message.encode();
            let (_, flat, arena) = decode(&frame[4..]);
            // SAFETY: the arena is a live local for the duration of the call.
            let asked = unsafe {
                slopdesk_wire_message_byte_count(
                    &raw const flat,
                    arena.as_ptr(),
                    arena.len(),
                    flat.blob_length as usize,
                )
            };
            assert_eq!(asked, frame.len(), "{message:?}");
        }
    }

    /// The opaque run is answered as a span into the CALLER's datagram, never copied out.
    #[test]
    fn the_opaque_run_is_a_span_into_the_datagram() {
        let message = WireMessage::Output {
            seq: 1,
            bytes: vec![0xEE; 4096],
        };
        let frame = message.encode();
        let payload = &frame[4..];
        let (verdict, flat, arena) = decode(payload);
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(flat.blob_length, 4096);
        assert_eq!(&payload[flat.blob_offset as usize..], &[0xEE; 4096][..]);
        assert!(
            arena.iter().all(|byte| *byte == 0),
            "the run must not enter the arena"
        );
    }

    /// An arena too small for the text is `AGAIN`, and nothing is written.
    #[test]
    fn an_undersized_arena_asks_to_be_called_again() {
        let frame = WireMessage::Title("a long enough title".to_owned()).encode();
        let mut flat = SlopDeskWireMessage::default();
        let mut arena = [0xAA_u8; 4];
        // SAFETY: the pointers are live locals for the duration of the call.
        let verdict = unsafe {
            slopdesk_wire_message_decode(
                frame[4..].as_ptr(),
                frame.len() - 4,
                &raw mut flat,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(verdict, WIRE_DECODE_AGAIN);
        assert_eq!(
            arena, [0xAA; 4],
            "an undersized call must not write a partial answer"
        );
        assert_eq!(flat.message_type, 0, "nor a partial message");
    }

    /// The two ways a hostile frame is refused reach Swift as different verdicts.
    #[test]
    fn a_refused_frame_says_which_way_it_was_refused() {
        assert_eq!(decode(&[]).0, WIRE_DECODE_TRUNCATED);
        assert_eq!(decode(&[2, 0, 0]).0, WIRE_DECODE_TRUNCATED);
        assert_eq!(decode(&[0xFE]).0, WIRE_DECODE_UNKNOWN_TYPE);
    }

    /// A type byte no arm answers to encodes as 0 rather than a wrong frame.
    #[test]
    fn an_unknown_type_encodes_to_nothing() {
        let flat = SlopDeskWireMessage {
            message_type: 0xFE,
            ..SlopDeskWireMessage::default()
        };
        // SAFETY: null input pairs are explicitly permitted; a null `out` with cap 0 is the size query.
        let needed = unsafe {
            slopdesk_wire_message_encode(
                &raw const flat,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                0,
            )
        };
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
