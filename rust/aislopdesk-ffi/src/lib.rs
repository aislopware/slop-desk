//! # aislopdesk-ffi
//!
//! The **C-ABI boundary** over [`aislopdesk_core`]. The core is a pure, 100%-safe,
//! zero-dependency reimplementation of Aislopdesk's wire codecs / FEC / reassembly /
//! controllers; this crate is the thin `extern "C"` shim that lets a non-Rust platform
//! shell call into it — Swift on macOS/iOS today, a JNI shim on Android later — so every
//! client runs *the identical algorithm bytes*, not a per-platform re-implementation.
//!
//! ## Why a separate crate
//!
//! [`aislopdesk_core`] is `#![forbid(unsafe_code)]`. Every FFI surface unavoidably needs
//! `unsafe` (raw pointers, `extern "C"`, handing buffers across a language boundary), so it
//! is quarantined *here*: this is the one crate that may write `unsafe`, and it does so in
//! small, individually-documented blocks that only ever validate a pointer and copy bytes —
//! the actual protocol logic stays in the safe core.
//!
//! ## Memory & error contract (read before calling from C)
//!
//! * **Rust allocates, Rust frees.** Any [`AisdBytes`] handed back to the caller (decoded
//!   payloads, encoded frames) owns a Rust allocation and MUST be released with
//!   [`aisd_bytes_free`] / [`aisd_wire_message_free`] — never C `free`. Buffers the caller
//!   passes *in* are borrowed for the duration of the call and never freed by Rust.
//! * **Opaque handles** ([`AisdFrameDecoder`]) are created by `*_new` and destroyed by
//!   `*_free`; using one after free, or freeing twice, is undefined behaviour (as in C).
//! * **Status codes.** Fallible functions return an [`AisdStatus`] (`0` = ok; `1` =
//!   [`AISD_EMPTY`], a decoder that needs more bytes; negatives are errors). A null
//!   required pointer is reported as [`AISD_ERR_NULL`], never dereferenced.
//! * **Never unwinds.** The core never panics on untrusted input, so no panic crosses this
//!   boundary; the shipped library is built `panic = "abort"` regardless.

use aislopdesk_core::seq::distance_wrapped;
use aislopdesk_core::terminal::{
    CommandStatus, FrameDecoder, SessionId, TerminalProtocolError, WireMessage,
};

/// The video-path C ABI (codecs + scalar policies), kept in its own module so this file
/// stays the shared-infrastructure + terminal hub. Reuses [`AisdBytes`] / [`AisdStatus`] /
/// the byte helpers below.
pub mod video;

// ---------------------------------------------------------------------------------------
// Status codes
// ---------------------------------------------------------------------------------------

/// Result of a fallible boundary call: `0` ok, `1` "needs more bytes", negative = error.
pub type AisdStatus = i32;

/// The call succeeded.
pub const AISD_OK: AisdStatus = 0;
/// A decoder has no complete message buffered yet — append more bytes and retry. Not an
/// error: the wire is a byte stream and a frame may arrive in pieces.
pub const AISD_EMPTY: AisdStatus = 1;
/// A required pointer argument was null. Nothing was dereferenced.
pub const AISD_ERR_NULL: AisdStatus = -1;
/// A frame's length prefix exceeded the protocol maximum (corrupt/hostile stream).
pub const AISD_ERR_FRAME_TOO_LARGE: AisdStatus = -2;
/// A complete frame's body was shorter than its message type requires.
pub const AISD_ERR_TRUNCATED: AisdStatus = -3;
/// The frame's first byte was not a recognized message type.
pub const AISD_ERR_UNKNOWN_TYPE: AisdStatus = -4;
/// A body had the right length but invalid contents (e.g. non-UTF-8 title).
pub const AISD_ERR_MALFORMED: AisdStatus = -5;
/// The caller supplied an [`AisdWireMessage`] that does not describe a valid message
/// (unknown `tag`, or non-UTF-8 bytes where a string is required).
pub const AISD_ERR_INVALID_ARGUMENT: AisdStatus = -6;

// ---------------------------------------------------------------------------------------
// Owned byte buffer (Rust-allocated, Rust-freed)
// ---------------------------------------------------------------------------------------

/// A length-counted byte buffer that crosses the boundary. When returned by a function it
/// owns a Rust allocation; release it with [`aisd_bytes_free`] (or [`aisd_wire_message_free`]
/// for the buffers inside an [`AisdWireMessage`]). An empty buffer is `{ ptr: null, len: 0,
/// cap: 0 }`. When *passed in* (e.g. to [`aisd_wire_message_encode`]) only `ptr`/`len` are
/// read and the buffer is borrowed, not freed.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdBytes {
    /// Pointer to `len` bytes, or null when `len == 0`.
    pub ptr: *mut u8,
    /// Number of valid bytes at `ptr`.
    pub len: usize,
    /// Allocation capacity (an implementation detail of the Rust owner; the caller must
    /// pass an [`AisdBytes`] back to the matching `*_free` unchanged).
    pub cap: usize,
}

impl AisdBytes {
    /// The canonical empty buffer: null pointer, zero length, zero capacity.
    pub const EMPTY: AisdBytes = AisdBytes {
        ptr: core::ptr::null_mut(),
        len: 0,
        cap: 0,
    };
}

/// Moves a `Vec<u8>` across the boundary as an owned [`AisdBytes`]. An empty vec becomes
/// [`AisdBytes::EMPTY`] (no allocation leaked, free is a no-op).
pub(crate) fn bytes_from_vec(mut v: Vec<u8>) -> AisdBytes {
    if v.is_empty() {
        return AisdBytes::EMPTY;
    }
    let ptr = v.as_mut_ptr();
    let len = v.len();
    let cap = v.capacity();
    core::mem::forget(v);
    AisdBytes { ptr, len, cap }
}

/// Reconstructs and drops the `Vec<u8>` behind an owned [`AisdBytes`]. No-op on a null
/// pointer (an empty buffer).
///
/// # Safety
/// `b` must be a buffer previously produced by this crate and not yet freed.
pub(crate) unsafe fn drop_bytes(b: AisdBytes) {
    if !b.ptr.is_null() {
        drop(Vec::from_raw_parts(b.ptr, b.len, b.cap));
    }
}

/// Copies the bytes a caller-owned (borrowed) [`AisdBytes`] points at into a fresh `Vec`.
/// Empty (or null) input yields an empty vec.
///
/// # Safety
/// If `b.len != 0` then `b.ptr` must point to at least `b.len` readable bytes.
pub(crate) unsafe fn copy_in(b: AisdBytes) -> Vec<u8> {
    if b.ptr.is_null() || b.len == 0 {
        Vec::new()
    } else {
        core::slice::from_raw_parts(b.ptr, b.len).to_vec()
    }
}

/// Releases an owned [`AisdBytes`] returned by this library.
///
/// # Safety
/// `bytes` must be a buffer this library returned (e.g. from [`aisd_wire_message_encode`])
/// and not already freed. Passing [`AisdBytes::EMPTY`] is safe and does nothing.
#[no_mangle]
pub unsafe extern "C" fn aisd_bytes_free(bytes: AisdBytes) {
    drop_bytes(bytes);
}

// ---------------------------------------------------------------------------------------
// Sequence arithmetic (a trivial, stateless smoke of the boundary)
// ---------------------------------------------------------------------------------------

/// Wrap-aware signed distance `a - b` in 32-bit sequence space (positive ⇒ `a` is ahead).
/// Wraps [`aislopdesk_core::seq::distance_wrapped`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_seq_distance(a: u32, b: u32) -> i32 {
    distance_wrapped(a, b)
}

// ---------------------------------------------------------------------------------------
// WireMessage as a flat C struct
// ---------------------------------------------------------------------------------------

/// Message-type tag of an [`AisdWireMessage`] — PTY output (host → client).
pub const AISD_WIRE_OUTPUT: u8 = 1;
/// Child process exited (host → client).
pub const AISD_WIRE_EXIT: u8 = 2;
/// Bytes to write to the PTY's stdin (client → host).
pub const AISD_WIRE_INPUT: u8 = 3;
/// Session handshake (client → host).
pub const AISD_WIRE_HELLO: u8 = 10;
/// Terminal resize (client → host).
pub const AISD_WIRE_RESIZE: u8 = 11;
/// Acknowledge received output up to a seq (client → host).
pub const AISD_WIRE_ACK: u8 = 12;
/// Client leaving cleanly (client → host).
pub const AISD_WIRE_BYE: u8 = 13;
/// RTT probe (client → host).
pub const AISD_WIRE_PING: u8 = 14;
/// Handshake reply (host → client).
pub const AISD_WIRE_HELLO_ACK: u8 = 20;
/// Window/title text (host → client).
pub const AISD_WIRE_TITLE: u8 = 21;
/// Terminal bell (host → client).
pub const AISD_WIRE_BELL: u8 = 22;
/// Per-command semantic status from OSC 133 (host → client).
pub const AISD_WIRE_COMMAND_STATUS: u8 = 23;
/// RTT probe reply (host → client).
pub const AISD_WIRE_PONG: u8 = 24;
/// Desktop notification from OSC 9 / 777 (host → client).
pub const AISD_WIRE_NOTIFICATION: u8 = 25;

/// A decoded (or to-be-encoded) terminal-protocol message, flattened for the C ABI.
///
/// `tag` selects which fields are meaningful — it equals the on-wire message type and one
/// of the `AISD_WIRE_*` constants. Numeric fields are zero when not used by the tag; the
/// variable-length `data` / `data2` buffers are [`AisdBytes::EMPTY`] when not used. After a
/// successful [`aisd_frame_decoder_next`], release the buffers with [`aisd_wire_message_free`].
///
/// Field usage by tag:
/// * `OUTPUT`: `seq`, `data` (raw VT bytes)
/// * `EXIT`: `code`
/// * `INPUT`: `data` (stdin bytes)
/// * `HELLO`: `protocol_version`, `session_id`, `last_received_seq`
/// * `RESIZE`: `cols`, `rows`, `px_width`, `px_height`
/// * `ACK`: `seq`
/// * `BYE` / `BELL`: (none)
/// * `PING` / `PONG`: `timestamp_ms`
/// * `HELLO_ACK`: `session_id`, `resume_from_seq`, `returning_client`
/// * `TITLE`: `data` (UTF-8)
/// * `COMMAND_STATUS`: `cmd_running`; if idle, `cmd_has_exit_code` + `code` + `duration_ms`
/// * `NOTIFICATION`: `data` (UTF-8 title), `data2` (UTF-8 body)
#[repr(C)]
pub struct AisdWireMessage {
    /// Message type; equals one of the `AISD_WIRE_*` constants.
    pub tag: u8,
    /// `OUTPUT.seq` / `ACK.seq` — monotonic per-message index.
    pub seq: i64,
    /// `EXIT.code`, or the idle `COMMAND_STATUS` exit code (valid iff `cmd_has_exit_code`).
    pub code: i32,
    /// `HELLO.protocol_version`.
    pub protocol_version: u16,
    /// `HELLO.last_received_seq`.
    pub last_received_seq: i64,
    /// `HELLO_ACK.resume_from_seq`.
    pub resume_from_seq: i64,
    /// `RESIZE.cols` (character cells).
    pub cols: u16,
    /// `RESIZE.rows` (character cells).
    pub rows: u16,
    /// `RESIZE.px_width` (0 if unknown).
    pub px_width: u16,
    /// `RESIZE.px_height` (0 if unknown).
    pub px_height: u16,
    /// `PING.timestamp_ms` / `PONG.timestamp_ms`.
    pub timestamp_ms: u64,
    /// `HELLO_ACK.returning_client` — `0` = false, any nonzero = true. (A plain byte, not a
    /// Rust `bool`, so a C/JNI caller storing e.g. a `jboolean` of `2` is read as `!= 0`
    /// rather than triggering `bool`-validity UB.)
    pub returning_client: u8,
    /// `HELLO` / `HELLO_ACK` 16-byte session id (all-zero requests a new session).
    pub session_id: [u8; 16],
    /// `COMMAND_STATUS`: nonzero = running, `0` = idle (a byte, read as `!= 0`).
    pub cmd_running: u8,
    /// Idle `COMMAND_STATUS`: nonzero if `code` carries a reported exit status (read as `!= 0`).
    pub cmd_has_exit_code: u8,
    /// Idle `COMMAND_STATUS`: host-measured command wall-clock time in milliseconds.
    pub duration_ms: u32,
    /// Primary variable-length payload (see per-tag usage above).
    pub data: AisdBytes,
    /// Secondary variable-length payload (`NOTIFICATION` body only).
    pub data2: AisdBytes,
}

impl AisdWireMessage {
    /// An all-zero message with empty buffers — the base every decode fills in.
    fn zeroed() -> Self {
        Self {
            tag: 0,
            seq: 0,
            code: 0,
            protocol_version: 0,
            last_received_seq: 0,
            resume_from_seq: 0,
            cols: 0,
            rows: 0,
            px_width: 0,
            px_height: 0,
            timestamp_ms: 0,
            returning_client: 0,
            session_id: [0u8; 16],
            cmd_running: 0,
            cmd_has_exit_code: 0,
            duration_ms: 0,
            data: AisdBytes::EMPTY,
            data2: AisdBytes::EMPTY,
        }
    }
}

/// Flattens a safe-core [`WireMessage`] into the C struct, allocating owned buffers for any
/// variable-length payload.
fn wire_message_to_c(msg: &WireMessage) -> AisdWireMessage {
    let mut out = AisdWireMessage::zeroed();
    out.tag = msg.message_type();
    match msg {
        WireMessage::Output { seq, bytes } => {
            out.seq = *seq;
            out.data = bytes_from_vec(bytes.clone());
        }
        WireMessage::Exit { code } => out.code = *code,
        WireMessage::Input(bytes) => out.data = bytes_from_vec(bytes.clone()),
        WireMessage::Hello {
            protocol_version,
            session_id,
            last_received_seq,
        } => {
            out.protocol_version = *protocol_version;
            out.session_id = *session_id.bytes();
            out.last_received_seq = *last_received_seq;
        }
        WireMessage::Resize {
            cols,
            rows,
            px_width,
            px_height,
        } => {
            out.cols = *cols;
            out.rows = *rows;
            out.px_width = *px_width;
            out.px_height = *px_height;
        }
        WireMessage::Ack { seq } => out.seq = *seq,
        WireMessage::Bye | WireMessage::Bell => {}
        WireMessage::Ping { timestamp_ms } | WireMessage::Pong { timestamp_ms } => {
            out.timestamp_ms = *timestamp_ms;
        }
        WireMessage::HelloAck {
            session_id,
            resume_from_seq,
            returning_client,
        } => {
            out.session_id = *session_id.bytes();
            out.resume_from_seq = *resume_from_seq;
            out.returning_client = u8::from(*returning_client);
        }
        WireMessage::Title(text) => out.data = bytes_from_vec(text.clone().into_bytes()),
        WireMessage::CommandStatus(status) => match status {
            CommandStatus::Running => out.cmd_running = 1,
            CommandStatus::Idle {
                exit_code,
                duration_ms,
            } => {
                out.cmd_running = 0;
                out.cmd_has_exit_code = u8::from(exit_code.is_some());
                out.code = exit_code.unwrap_or(0);
                out.duration_ms = *duration_ms;
            }
        },
        WireMessage::Notification { title, body } => {
            out.data = bytes_from_vec(title.clone().into_bytes());
            out.data2 = bytes_from_vec(body.clone().into_bytes());
        }
    }
    out
}

/// Rebuilds a safe-core [`WireMessage`] from the caller-supplied C struct, validating the
/// tag and any UTF-8 payloads.
///
/// # Safety
/// Any non-empty `data` / `data2` in `m` must point to that many readable bytes.
unsafe fn c_to_wire_message(m: &AisdWireMessage) -> Result<WireMessage, AisdStatus> {
    // A closure does NOT inherit the enclosing `unsafe fn` context, so the `copy_in` call
    // needs its own `unsafe` block.
    let utf8 = |b: AisdBytes| -> Result<String, AisdStatus> {
        String::from_utf8(unsafe { copy_in(b) }).map_err(|_| AISD_ERR_INVALID_ARGUMENT)
    };
    let message = match m.tag {
        AISD_WIRE_OUTPUT => WireMessage::Output {
            seq: m.seq,
            bytes: copy_in(m.data),
        },
        AISD_WIRE_EXIT => WireMessage::Exit { code: m.code },
        AISD_WIRE_INPUT => WireMessage::Input(copy_in(m.data)),
        AISD_WIRE_HELLO => WireMessage::Hello {
            protocol_version: m.protocol_version,
            session_id: SessionId(m.session_id),
            last_received_seq: m.last_received_seq,
        },
        AISD_WIRE_RESIZE => WireMessage::Resize {
            cols: m.cols,
            rows: m.rows,
            px_width: m.px_width,
            px_height: m.px_height,
        },
        AISD_WIRE_ACK => WireMessage::Ack { seq: m.seq },
        AISD_WIRE_BYE => WireMessage::Bye,
        AISD_WIRE_PING => WireMessage::Ping {
            timestamp_ms: m.timestamp_ms,
        },
        AISD_WIRE_HELLO_ACK => WireMessage::HelloAck {
            session_id: SessionId(m.session_id),
            resume_from_seq: m.resume_from_seq,
            returning_client: m.returning_client != 0,
        },
        AISD_WIRE_TITLE => WireMessage::Title(utf8(m.data)?),
        AISD_WIRE_BELL => WireMessage::Bell,
        AISD_WIRE_COMMAND_STATUS => {
            let status = if m.cmd_running != 0 {
                CommandStatus::Running
            } else {
                CommandStatus::Idle {
                    exit_code: if m.cmd_has_exit_code != 0 {
                        Some(m.code)
                    } else {
                        None
                    },
                    duration_ms: m.duration_ms,
                }
            };
            WireMessage::CommandStatus(status)
        }
        AISD_WIRE_PONG => WireMessage::Pong {
            timestamp_ms: m.timestamp_ms,
        },
        AISD_WIRE_NOTIFICATION => WireMessage::Notification {
            title: utf8(m.data)?,
            body: utf8(m.data2)?,
        },
        _ => return Err(AISD_ERR_INVALID_ARGUMENT),
    };
    Ok(message)
}

/// Encodes a caller-built [`AisdWireMessage`] into a complete length-prefixed wire frame.
///
/// On [`AISD_OK`], `*out` receives an owned frame buffer — release it with
/// [`aisd_bytes_free`]. Returns [`AISD_ERR_NULL`] for a null argument or
/// [`AISD_ERR_INVALID_ARGUMENT`] for an unknown `tag` / non-UTF-8 string payload.
///
/// # Safety
/// `msg` and `out` must be valid, writable pointers; any non-empty `data` / `data2` inside
/// `*msg` must point to that many readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_wire_message_encode(
    msg: *const AisdWireMessage,
    out: *mut AisdBytes,
) -> AisdStatus {
    if msg.is_null() || out.is_null() {
        return AISD_ERR_NULL;
    }
    match c_to_wire_message(&*msg) {
        Ok(message) => {
            out.write(bytes_from_vec(message.encode()));
            AISD_OK
        }
        Err(status) => status,
    }
}

/// Decodes a single complete payload (`[type byte][body…]`, WITHOUT the 4-byte length
/// prefix — framing is the caller's job) into `*out`.
///
/// This mirrors the safe core's [`WireMessage::decode`]; it is the counterpart to
/// [`aisd_wire_message_encode`] for callers that already de-frame the stream themselves
/// (e.g. a Swift `FrameDecoder` keeping its hardened buffering) and only want the protocol
/// body parsed by the shared Rust codec. On [`AISD_OK`], `*out` owns buffers — release with
/// [`aisd_wire_message_free`]. `payload` may be null only when `len == 0`.
///
/// # Safety
/// `out` must be a writable [`AisdWireMessage`]; if `len != 0`, `payload` must point to at
/// least `len` readable bytes. On a non-[`AISD_OK`] return `*out` is left untouched; on
/// [`AISD_OK`] it is overwritten as raw output without freeing prior contents (see
/// [`aisd_frame_decoder_next`]).
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_wire_message_decode(
    payload: *const u8,
    len: usize,
    out: *mut AisdWireMessage,
) -> AisdStatus {
    if out.is_null() || (payload.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    let slice = if len == 0 {
        &[][..]
    } else {
        core::slice::from_raw_parts(payload, len)
    };
    match WireMessage::decode(slice) {
        Ok(message) => {
            out.write(wire_message_to_c(&message));
            AISD_OK
        }
        Err(error) => status_for_error(&error),
    }
}

/// Releases the owned buffers inside an [`AisdWireMessage`] (its `data` / `data2`) and
/// resets them to empty. Idempotent: safe to call twice; the struct itself is caller-owned.
///
/// # Safety
/// `msg` must point to a writable [`AisdWireMessage`] previously filled by this library.
#[no_mangle]
pub unsafe extern "C" fn aisd_wire_message_free(msg: *mut AisdWireMessage) {
    if msg.is_null() {
        return;
    }
    let m = &mut *msg;
    drop_bytes(m.data);
    drop_bytes(m.data2);
    m.data = AisdBytes::EMPTY;
    m.data2 = AisdBytes::EMPTY;
}

// ---------------------------------------------------------------------------------------
// Streaming frame decoder (opaque handle — the canonical "Rust owns the pipeline" boundary)
// ---------------------------------------------------------------------------------------

/// Opaque streaming length-prefixed frame decoder. Create with [`aisd_frame_decoder_new`],
/// feed raw socket bytes with [`aisd_frame_decoder_append`], drain whole messages with
/// [`aisd_frame_decoder_next`], destroy with [`aisd_frame_decoder_free`]. One per channel
/// per connection; not thread-safe (drive it from one receive loop).
pub struct AisdFrameDecoder {
    inner: FrameDecoder,
}

/// Creates a new, empty frame decoder. Destroy it with [`aisd_frame_decoder_free`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_frame_decoder_new() -> *mut AisdFrameDecoder {
    Box::into_raw(Box::new(AisdFrameDecoder {
        inner: FrameDecoder::new(),
    }))
}

/// Destroys a decoder created by [`aisd_frame_decoder_new`]. No-op on null.
///
/// # Safety
/// `decoder` must be a pointer from [`aisd_frame_decoder_new`] that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn aisd_frame_decoder_free(decoder: *mut AisdFrameDecoder) {
    if !decoder.is_null() {
        drop(Box::from_raw(decoder));
    }
}

/// Appends `len` freshly received bytes to the decoder's buffer. `data` may be null only
/// when `len == 0`. Returns [`AISD_OK`], or [`AISD_ERR_NULL`].
///
/// # Safety
/// `decoder` must be a live decoder handle; if `len != 0`, `data` must point to at least
/// `len` readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_frame_decoder_append(
    decoder: *mut AisdFrameDecoder,
    data: *const u8,
    len: usize,
) -> AisdStatus {
    if decoder.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    if len != 0 {
        (*decoder)
            .inner
            .append(core::slice::from_raw_parts(data, len));
    }
    AISD_OK
}

/// Drains the next complete message into `*out`. Returns [`AISD_OK`] (a message was
/// written; release its buffers with [`aisd_wire_message_free`]), [`AISD_EMPTY`] (need more
/// bytes — nothing written), or a negative decode error.
///
/// # Safety
/// `decoder` must be a live decoder handle and `out` a writable [`AisdWireMessage`]. On a
/// non-[`AISD_OK`] return `*out` is left untouched. On [`AISD_OK`] `*out` is overwritten as
/// raw output WITHOUT freeing any prior contents, so a previously-decoded message held in
/// the same storage must be released with [`aisd_wire_message_free`] first (or use fresh
/// storage) to avoid leaking its buffers.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_frame_decoder_next(
    decoder: *mut AisdFrameDecoder,
    out: *mut AisdWireMessage,
) -> AisdStatus {
    if decoder.is_null() || out.is_null() {
        return AISD_ERR_NULL;
    }
    match (*decoder).inner.next_message() {
        Ok(Some(message)) => {
            out.write(wire_message_to_c(&message));
            AISD_OK
        }
        Ok(None) => AISD_EMPTY,
        Err(error) => status_for_error(&error),
    }
}

/// Maps a core decode error to its boundary status code.
fn status_for_error(error: &TerminalProtocolError) -> AisdStatus {
    match error {
        TerminalProtocolError::FrameTooLarge(_) => AISD_ERR_FRAME_TOO_LARGE,
        TerminalProtocolError::Truncated => AISD_ERR_TRUNCATED,
        TerminalProtocolError::UnknownMessageType(_) => AISD_ERR_UNKNOWN_TYPE,
        TerminalProtocolError::MalformedBody(_) => AISD_ERR_MALFORMED,
    }
}
