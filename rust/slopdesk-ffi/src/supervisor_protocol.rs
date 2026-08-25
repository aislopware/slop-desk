//! The superd control protocol, in C — `Sources/SlopDeskSupervisor/SupervisorClient.swift`.
//!
//! The message set is [`slopdesk_superwire::protocol`]. It was, and so was hostd's copy:
//! `protocol.rs` and `SupervisorProtocol.swift` each opened by calling the other a mirror, ~1,660
//! lines spelling one JSON vocabulary twice. Unlike the FRAMING that [`crate::supervisor_frame`]
//! folded, a disagreement here did not desynchronise a socket — it passed both suites and produced
//! a `nil`, which is the more expensive kind precisely because nothing reports it.
//!
//! ## What did NOT move
//! The syscalls, the reply-waiter table, the serial write queue and the reader thread. hostd still
//! owns every one of them, because each is about a connection this crate cannot see. What crosses
//! is the two things that were spelled twice: what a request LOOKS like, and what a reply MEANS.
//!
//! ## The two shapes, and why the reply is a handle
//! Encoding is [`crate`]'s pure convention — arguments in, bytes out, no allocation retained.
//! Decoding is not, and cannot be: a `blockOutput` reply carries up to a frame's worth of base64,
//! and a caller reads a dozen fields off one reply. Under the pure convention each field would
//! re-parse the whole body. So the reply takes the HANDLE convention documented in `lib.rs`:
//! [`slopdesk_supervisor_reply_open`] parses once, the scalars come back in one struct, the
//! variable-length parts are projected into the caller's own buffers, and
//! [`slopdesk_supervisor_reply_free`] ends it.
//!
//! ## Why the verb doors are grouped by SHAPE
//! Thirteen of the eighteen verbs carry a pane id and at most one other value, so they share four
//! doors selected by a `SLOPDESK_SUPERVISOR_VERB_*` constant —
//! [`crate::supervisor_frame::slopdesk_supervisor_tag`]'s precedent. A door REFUSES a selector
//! outside its own shape, answering `0`: a `pause` sent through the number door would otherwise
//! encode a `paused` field that superd reads as a bool it never got.

use core::ffi::c_uchar;

use slopdesk_superwire::blockwire::{BlockMeta, ControlBlock};
use slopdesk_superwire::protocol::{
    self, AdoptRequest, BlockOutputRequest, BlockReadRequest, BlocksRequest, ForgetTitleRequest,
    HelloRequest, JournalRequest, JournalSpawn, ListenRequest, PaneRecord, PauseRequest, ReleaseRequest,
    Request, ResizeRequest, SignalRequest, SpawnRequest, Status, SubscribeRequest, UnsubscribeRequest, verb,
};

use crate::{borrow, deliver};

// MARK: - Verb selectors

/// [`verb::ADOPT`] — for [`slopdesk_supervisor_encode_pane`].
pub const SLOPDESK_SUPERVISOR_VERB_ADOPT: u32 = 0;
/// [`verb::UNSUBSCRIBE`] — for [`slopdesk_supervisor_encode_pane`].
pub const SLOPDESK_SUPERVISOR_VERB_UNSUBSCRIBE: u32 = 1;
/// [`verb::FORGET_TITLE`] — for [`slopdesk_supervisor_encode_pane`].
pub const SLOPDESK_SUPERVISOR_VERB_FORGET_TITLE: u32 = 2;
/// [`verb::BLOCK_SNAPSHOT`] — for [`slopdesk_supervisor_encode_pane`].
pub const SLOPDESK_SUPERVISOR_VERB_BLOCK_SNAPSHOT: u32 = 3;
/// [`verb::SIGNAL`] — for [`slopdesk_supervisor_encode_pane_number`], carrying the signal number.
pub const SLOPDESK_SUPERVISOR_VERB_SIGNAL: u32 = 4;
/// [`verb::SUBSCRIBE`] — for [`slopdesk_supervisor_encode_pane_number`], carrying the offset.
pub const SLOPDESK_SUPERVISOR_VERB_SUBSCRIBE: u32 = 5;
/// [`verb::BLOCK_OUTPUT`] — for [`slopdesk_supervisor_encode_pane_number`], carrying the index.
pub const SLOPDESK_SUPERVISOR_VERB_BLOCK_OUTPUT: u32 = 6;
/// [`verb::BLOCK_CONTROL`] — for [`slopdesk_supervisor_encode_pane_number`], carrying the limit.
pub const SLOPDESK_SUPERVISOR_VERB_BLOCK_CONTROL: u32 = 7;
/// [`verb::RELEASE`] — for [`slopdesk_supervisor_encode_pane_flag`], where the flag is `kill`.
pub const SLOPDESK_SUPERVISOR_VERB_RELEASE: u32 = 8;
/// [`verb::PAUSE`] — for [`slopdesk_supervisor_encode_pane_flag`], where the flag is `paused`.
pub const SLOPDESK_SUPERVISOR_VERB_PAUSE: u32 = 9;
/// [`verb::JOURNAL_INFO`] — for [`slopdesk_supervisor_encode_journal`].
pub const SLOPDESK_SUPERVISOR_VERB_JOURNAL_INFO: u32 = 10;
/// [`verb::JOURNAL_DELETE`] — for [`slopdesk_supervisor_encode_journal`].
pub const SLOPDESK_SUPERVISOR_VERB_JOURNAL_DELETE: u32 = 11;
/// [`verb::JOURNAL_SWEEP`] — for [`slopdesk_supervisor_encode_journal`].
pub const SLOPDESK_SUPERVISOR_VERB_JOURNAL_SWEEP: u32 = 12;

// MARK: - Status and event codes

/// The verb succeeded.
pub const SLOPDESK_SUPERVISOR_STATUS_OK: u32 = 0;
/// The verb is known and failed.
pub const SLOPDESK_SUPERVISOR_STATUS_ERROR: u32 = 1;
/// The verb is not in this superd's vocabulary.
pub const SLOPDESK_SUPERVISOR_STATUS_UNSUPPORTED: u32 = 2;
/// A status this build has no name for — a failure, never a success. See [`Status::Unrecognised`].
pub const SLOPDESK_SUPERVISOR_STATUS_UNRECOGNISED: u32 = 3;

/// The reply is an answer, not a push.
pub const SLOPDESK_SUPERVISOR_EVENT_NONE: u32 = 0;
/// [`protocol::event::EXITED`].
pub const SLOPDESK_SUPERVISOR_EVENT_EXITED: u32 = 1;
/// [`protocol::event::CONNECTION`].
pub const SLOPDESK_SUPERVISOR_EVENT_CONNECTION: u32 = 2;
/// A push this build has no name for. Named rather than folded into `NONE`, which would make a
/// newer superd's notification read as an ANSWER to whatever request holds id `0`.
pub const SLOPDESK_SUPERVISOR_EVENT_UNKNOWN: u32 = 3;

/// No listener kind — the reply is not a `connection` push.
pub const SLOPDESK_SUPERVISOR_LISTENER_NONE: u32 = 0;
/// [`protocol::listener_kind::HOOK`].
pub const SLOPDESK_SUPERVISOR_LISTENER_HOOK: u32 = 1;
/// [`protocol::listener_kind::CONTROL`].
pub const SLOPDESK_SUPERVISOR_LISTENER_CONTROL: u32 = 2;
/// A kind this build has no name for. The descriptor still arrived, and dropping it silently would
/// leak an accepted socket, so the caller is told there is one it cannot serve.
pub const SLOPDESK_SUPERVISOR_LISTENER_UNKNOWN: u32 = 3;

// MARK: - Text selectors

/// [`protocol::Reply::message`].
pub const SLOPDESK_SUPERVISOR_TEXT_MESSAGE: u32 = 0;
/// The `hello` reply's hook socket path.
pub const SLOPDESK_SUPERVISOR_TEXT_HOOK_SOCKET: u32 = 1;
/// The `hello` reply's agent-control socket path.
pub const SLOPDESK_SUPERVISOR_TEXT_CONTROL_SOCKET: u32 = 2;
/// The `hello` reply's `buildVersion`.
pub const SLOPDESK_SUPERVISOR_TEXT_BUILD_VERSION: u32 = 3;
/// The `journalInfo` reply's path.
pub const SLOPDESK_SUPERVISOR_TEXT_JOURNAL_PATH: u32 = 4;
/// The `exited` push's pane id.
pub const SLOPDESK_SUPERVISOR_TEXT_EXITED_PANE: u32 = 5;
/// The running block's command line, from a `blockControl` reply.
pub const SLOPDESK_SUPERVISOR_TEXT_OPEN_COMMAND: u32 = 6;

/// The single `pane` a `spawn` or `adopt` answers with.
pub const SLOPDESK_SUPERVISOR_PANES_SINGLE: u32 = 0;
/// The `panes` array a `list` answers with.
pub const SLOPDESK_SUPERVISOR_PANES_LIST: u32 = 1;

// MARK: - Encoding

/// Encodes `request`, or answers `0` when it will not serialise.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[expect(unsafe_code, reason = "the delivery is the boundary this module documents")]
unsafe fn emit(request: &Request, out: *mut c_uchar, cap: usize) -> usize {
    let Some(bytes) = request.encode() else {
        return 0;
    };
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(&bytes, out, cap) }
}

/// A `(ptr, len)` pair as a `String`, lossily. Null or empty is the empty string.
///
/// # Safety
/// `ptr` must be null, or point to `len` live bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "reading the caller's bytes is what this helper exists to do once"
)]
unsafe fn text(ptr: *const c_uchar, len: usize) -> String {
    // SAFETY: the caller's obligation above is `borrow`'s.
    String::from_utf8_lossy(unsafe { borrow(ptr, len) }).into_owned()
}

/// A `(ptr, len)` pair as an OPTIONAL `String`, where a NULL pointer is absent.
///
/// Null rather than empty is the absence test, and the difference is load-bearing: `argv0` empty is
/// a legal `argv[0]`, and `autoProgressCommands` empty means the operator turned the feature off,
/// which is a different instruction from never having set it.
///
/// # Safety
/// `ptr` must be null, or point to `len` live bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "reading the caller's bytes is what this helper exists to do once"
)]
unsafe fn optional_text(ptr: *const c_uchar, len: usize) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller's obligation, as above.
    Some(unsafe { text(ptr, len) })
}

/// The `[u32 big-endian length][UTF-8]` runs in `blob`, in order.
///
/// The framing [`crate::push_text`] writes and [`crate::spawn_env`] reads, used here for the two
/// genuinely variable-length parts of a spawn. A truncated prefix, a length that overruns, or a run
/// that is not UTF-8 ends the read: continuing past one would dress every later run in its
/// neighbour's text.
fn runs(blob: &[u8]) -> Vec<String> {
    let mut collected = Vec::new();
    let mut cursor = 0_usize;
    while cursor < blob.len() {
        let Some(prefix) = blob.get(cursor..cursor.saturating_add(4)) else {
            break;
        };
        let Ok(prefix) = <[u8; 4]>::try_from(prefix) else {
            break;
        };
        let Ok(length) = usize::try_from(u32::from_be_bytes(prefix)) else {
            break;
        };
        let start = cursor.saturating_add(4);
        let Some(end) = start.checked_add(length) else {
            break;
        };
        let Some(run) = blob
            .get(start..end)
            .and_then(|bytes| core::str::from_utf8(bytes).ok())
        else {
            break;
        };
        collected.push(run.to_owned());
        cursor = end;
    }
    collected
}

/// The `hello` handshake, at this build's version pair.
///
/// The versions are NOT parameters. They are the protocol's, they live beside the message set, and
/// a caller that could pass its own would be a second place the handshake is decided — which is the
/// drift the whole fold removes. `slopdesk-invariants` used to compare hostd's two literals against
/// superd's two; there is nothing left for it to compare.
///
/// # Safety
/// `(client, client_len)` must describe live memory for the call, and `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_hello(
    id: u64,
    client: *const c_uchar,
    client_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut request = Request::new(id, verb::HELLO);
    request.hello = Some(HelloRequest {
        version_major: protocol::VERSION_MAJOR,
        version_minor: protocol::VERSION_MINOR,
        // SAFETY: the caller's obligation.
        client: unsafe { text(client, client_len) },
    });
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// The version pair this build speaks, for a caller that has to REPORT it rather than send it.
///
/// Two doors instead of one struct because the two numbers mean different things: the major gates
/// the handshake and the minor is capability negotiation, and a caller wanting one never wants
/// both.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_supervisor_version_major() -> i32 {
    protocol::VERSION_MAJOR
}

/// See [`slopdesk_supervisor_version_major`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_supervisor_version_minor() -> i32 {
    protocol::VERSION_MINOR
}

/// The reserved id that marks a reply as an unsolicited notification.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_supervisor_notification_id() -> u64 {
    protocol::NOTIFICATION_ID
}

/// `list` — the one verb with no payload at all.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_list(id: u64, out: *mut c_uchar, cap: usize) -> usize {
    // SAFETY: the caller's obligation.
    unsafe { emit(&Request::new(id, verb::LIST), out, cap) }
}

/// The four verbs whose whole payload is a pane id.
///
/// Answers `0` for a selector outside this shape, writing nothing. That refusal is the reason the
/// grouping is safe: a `pause` routed here would encode without its `paused` field, and superd
/// would read the absent bool as `false` and resume a pane the caller meant to stop.
///
/// # Safety
/// `(pane, pane_len)` must describe live memory for the call, and `out` must be null or writable
/// for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_pane(
    which: u32,
    id: u64,
    pane: *const c_uchar,
    pane_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation.
    let pane_id = unsafe { text(pane, pane_len) };
    let mut request = match which {
        SLOPDESK_SUPERVISOR_VERB_ADOPT => {
            let mut request = Request::new(id, verb::ADOPT);
            request.adopt = Some(AdoptRequest { pane_id });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_UNSUBSCRIBE => {
            let mut request = Request::new(id, verb::UNSUBSCRIBE);
            request.unsubscribe = Some(UnsubscribeRequest { pane_id });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_FORGET_TITLE => {
            let mut request = Request::new(id, verb::FORGET_TITLE);
            request.forget_title = Some(ForgetTitleRequest { pane_id });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_BLOCK_SNAPSHOT => {
            let mut request = Request::new(id, verb::BLOCK_SNAPSHOT);
            request.block_read = Some(BlockReadRequest { pane_id, limit: 0 });
            request
        },
        _ => return 0,
    };
    request.id = id;
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// The four verbs whose payload is a pane id and one number.
///
/// One `u64` for four differently-typed fields — an `i32` signal, a `u64` offset, a `u32` index and
/// a `usize` limit — narrowed per verb here rather than at the call site. A value that will not fit
/// its field SATURATES rather than wrapping: a `blockOutput` for index `2^33` is a block that does
/// not exist either way, and a wrapped index would fetch the WRONG one.
///
/// # Safety
/// `(pane, pane_len)` must describe live memory for the call, and `out` must be null or writable
/// for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_pane_number(
    which: u32,
    id: u64,
    pane: *const c_uchar,
    pane_len: usize,
    value: u64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation.
    let pane_id = unsafe { text(pane, pane_len) };
    let request = match which {
        SLOPDESK_SUPERVISOR_VERB_SIGNAL => {
            let mut request = Request::new(id, verb::SIGNAL);
            request.signal = Some(SignalRequest {
                pane_id,
                signal: i32::try_from(value).unwrap_or(i32::MAX),
            });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_SUBSCRIBE => {
            let mut request = Request::new(id, verb::SUBSCRIBE);
            request.subscribe = Some(SubscribeRequest {
                pane_id,
                from_offset: value,
            });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_BLOCK_OUTPUT => {
            let mut request = Request::new(id, verb::BLOCK_OUTPUT);
            request.block_output = Some(BlockOutputRequest {
                pane_id,
                index: u32::try_from(value).unwrap_or(u32::MAX),
            });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_BLOCK_CONTROL => {
            let mut request = Request::new(id, verb::BLOCK_CONTROL);
            request.block_read = Some(BlockReadRequest {
                pane_id,
                limit: usize::try_from(value).unwrap_or(usize::MAX),
            });
            request
        },
        _ => return 0,
    };
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// The two verbs whose payload is a pane id and one flag.
///
/// # Safety
/// `(pane, pane_len)` must describe live memory for the call, and `out` must be null or writable
/// for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_pane_flag(
    which: u32,
    id: u64,
    pane: *const c_uchar,
    pane_len: usize,
    flag: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation.
    let pane_id = unsafe { text(pane, pane_len) };
    let request = match which {
        SLOPDESK_SUPERVISOR_VERB_RELEASE => {
            let mut request = Request::new(id, verb::RELEASE);
            request.release = Some(ReleaseRequest { pane_id, kill: flag });
            request
        },
        SLOPDESK_SUPERVISOR_VERB_PAUSE => {
            let mut request = Request::new(id, verb::PAUSE);
            request.pause = Some(PauseRequest {
                pane_id,
                paused: flag,
            });
            request
        },
        _ => return 0,
    };
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// `resize` — the one verb with two numbers, so it keeps a door.
///
/// # Safety
/// `(pane, pane_len)` must describe live memory for the call, and `out` must be null or writable
/// for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_resize(
    id: u64,
    pane: *const c_uchar,
    pane_len: usize,
    rows: u16,
    cols: u16,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut request = Request::new(id, verb::RESIZE);
    request.resize = Some(ResizeRequest {
        // SAFETY: the caller's obligation.
        pane_id: unsafe { text(pane, pane_len) },
        rows,
        cols,
    });
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// `listen` — claim the child-facing listeners, by kind.
///
/// Two bools rather than a list of strings, because there are two kinds and their names are wire
/// values this crate already spells. A caller passing a kind by name would be re-typing a constant
/// it can only get wrong.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_listen(
    id: u64,
    hook: bool,
    control: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut kinds = Vec::with_capacity(2);
    if hook {
        kinds.push(protocol::listener_kind::HOOK.to_owned());
    }
    if control {
        kinds.push(protocol::listener_kind::CONTROL.to_owned());
    }
    let mut request = Request::new(id, verb::LISTEN);
    request.listen = Some(ListenRequest { kinds });
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// The three journal verbs, which share one payload and differ only in which fields they read.
///
/// # Safety
/// Both `(ptr, len)` pairs must describe live memory for the call, and `out` must be null or
/// writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_journal(
    which: u32,
    id: u64,
    directory: *const c_uchar,
    directory_len: usize,
    session: *const c_uchar,
    session_len: usize,
    max_age_seconds: u64,
    keep_newest: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let name = match which {
        SLOPDESK_SUPERVISOR_VERB_JOURNAL_INFO => verb::JOURNAL_INFO,
        SLOPDESK_SUPERVISOR_VERB_JOURNAL_DELETE => verb::JOURNAL_DELETE,
        SLOPDESK_SUPERVISOR_VERB_JOURNAL_SWEEP => verb::JOURNAL_SWEEP,
        _ => return 0,
    };
    let mut request = Request::new(id, name);
    request.journal = Some(JournalRequest {
        // SAFETY: the caller's obligation.
        directory: unsafe { text(directory, directory_len) },
        // SAFETY: the caller's obligation.
        session_id: unsafe { text(session, session_len) },
        max_age_seconds,
        keep_newest,
    });
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

/// Everything a spawn decides that is a NUMBER or a FLAG.
///
/// The strings are separate `(ptr, len)` parameters rather than fields here, which is `lib.rs`'s
/// convention and the reason this struct is scalars only: a pointer inside a `repr(C)` input record
/// would be a second kind of borrow obligation, and there is one on purpose.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorSpawnFields {
    /// Initial window size.
    pub rows: u16,
    /// Initial window size.
    pub cols: u16,
    /// Whether to install the zsh shell-integration shim.
    pub shell_integration: bool,
    /// Whether the pane is journaled at all. The DIRECTORY is a separate parameter; this says
    /// whether to send the payload, so a caller may pass a directory it will not use.
    pub journal: bool,
    /// Per-file byte cap for the journal. `0` means "do not journal this pane".
    pub journal_cap_bytes: usize,
    /// Whether the pane has a command-block tap. Absent is different from every-bound-zero: it
    /// means no segmenter touches the stream at all.
    pub blocks: bool,
    /// Per-block output ceiling; `0` takes superd's default.
    pub blocks_output_cap: usize,
    /// How many finished blocks keep their output; `0` takes superd's default.
    pub blocks_max_blocks: usize,
    /// Total retained output ceiling; `0` takes superd's default.
    pub blocks_max_total_output_bytes: usize,
}

/// `spawn` — fork a shell under a PTY.
///
/// The two variable-length parts cross as `[u32 big-endian length][UTF-8]` run blobs, the framing
/// [`crate::spawn_env`] already reads for exactly this data: `arguments` is one run per argument,
/// and `environment` is KEY, VALUE runs in pairs. Everything else is a named parameter, so nothing
/// here depends on argument ORDER the way a single positional blob would.
///
/// `argv0`, `cwd`, `owner`, `journal_directory` and `auto_progress` are ABSENT when their pointer
/// is null, which is not the same as empty for the last of them: `Some("")` means the operator
/// cleared the auto-progress list and the feature is off, `None` means they never set it and
/// superd's built-in list applies.
///
/// # Safety
/// Every `(ptr, len)` pair must be null or describe live memory for the whole call, and `out` must
/// be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_encode_spawn(
    id: u64,
    pane: *const c_uchar,
    pane_len: usize,
    session: *const c_uchar,
    session_len: usize,
    executable: *const c_uchar,
    executable_len: usize,
    argv0: *const c_uchar,
    argv0_len: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    owner: *const c_uchar,
    owner_len: usize,
    arguments: *const c_uchar,
    arguments_len: usize,
    environment: *const c_uchar,
    environment_len: usize,
    journal_directory: *const c_uchar,
    journal_directory_len: usize,
    auto_progress: *const c_uchar,
    auto_progress_len: usize,
    fields: SlopDeskSupervisorSpawnFields,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: every borrow below is the caller's obligation, discharged by Swift's
    // `withUnsafeBytes` at the call site, whose scope is exactly this call.
    let environment = unsafe { borrow(environment, environment_len) };
    let mut pairs = runs(environment).into_iter();
    let mut child_environment = std::collections::BTreeMap::new();
    while let (Some(key), Some(value)) = (pairs.next(), pairs.next()) {
        let _ignored = child_environment.insert(key, value);
    }

    let mut request = Request::new(id, verb::SPAWN);
    request.spawn = Some(SpawnRequest {
        // SAFETY: as above.
        pane_id: unsafe { text(pane, pane_len) },
        // SAFETY: as above.
        session_id: unsafe { text(session, session_len) },
        // SAFETY: as above.
        executable: unsafe { text(executable, executable_len) },
        // SAFETY: as above.
        argv0: unsafe { optional_text(argv0, argv0_len) },
        // SAFETY: as above.
        arguments: runs(unsafe { borrow(arguments, arguments_len) }),
        environment: child_environment,
        // SAFETY: as above.
        cwd: unsafe { optional_text(cwd, cwd_len) },
        rows: fields.rows,
        cols: fields.cols,
        // SAFETY: as above.
        owner: unsafe { optional_text(owner, owner_len) },
        shell_integration: fields.shell_integration,
        journal: fields.journal.then(|| {
            JournalSpawn {
                // SAFETY: as above.
                directory: unsafe { text(journal_directory, journal_directory_len) },
                cap_bytes: fields.journal_cap_bytes,
            }
        }),
        blocks: fields.blocks.then(|| {
            BlocksRequest {
                // SAFETY: as above.
                auto_progress_commands: unsafe { optional_text(auto_progress, auto_progress_len) },
                output_cap: fields.blocks_output_cap,
                max_blocks: fields.blocks_max_blocks,
                max_total_output_bytes: fields.blocks_max_total_output_bytes,
            }
        }),
    });
    // SAFETY: the caller's obligation.
    unsafe { emit(&request, out, cap) }
}

// MARK: - The reply

/// One parsed reply. See the module comment for why this half is a handle.
#[derive(Debug)]
pub struct SlopDeskSupervisorReply {
    reply: protocol::Reply,
}

/// Every scalar on a reply, in one crossing.
///
/// One struct rather than a door per field because a caller reads most of these for every reply:
/// the read loop has to know the id, the status and whether it is a push before it can route the
/// frame at all. The presence flags are what let a caller tell "absent" from "empty" for the texts
/// projected separately — a `message` of `""` and no `message` are the same length.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorReplyHead {
    /// The request this answers, or [`slopdesk_supervisor_notification_id`].
    pub id: u64,
    /// One of the `SLOPDESK_SUPERVISOR_STATUS_*` constants.
    pub status: u32,
    /// One of the `SLOPDESK_SUPERVISOR_EVENT_*` constants.
    pub event: u32,
    /// Whether a diagnostic is present at all.
    pub has_message: bool,
    /// Whether the `hello` payload is present.
    pub has_hello: bool,
    /// superd's major, when `has_hello`.
    pub hello_version_major: i32,
    /// superd's minor, when `has_hello`.
    pub hello_version_minor: i32,
    /// superd's pid, when `has_hello`.
    pub hello_superd_pid: i32,
    /// Whether the `hello` reply carried a hook socket path.
    pub has_hook_socket: bool,
    /// Whether the `hello` reply carried an agent-control socket path.
    pub has_control_socket: bool,
    /// Whether the `hello` reply carried a `buildVersion`. Absent is NOT "same" — see
    /// [`protocol::HelloReply::build_version`].
    pub has_build_version: bool,
    /// Whether a single `pane` record is present, for [`SLOPDESK_SUPERVISOR_PANES_SINGLE`].
    pub has_pane: bool,
    /// Whether a `panes` array is present. Distinct from a count of `0`, which is a `list` with
    /// nothing supervised.
    pub has_panes: bool,
    /// How many rows [`SLOPDESK_SUPERVISOR_PANES_LIST`] will project.
    pub pane_count: usize,
    /// Whether the `exited` payload is present.
    pub has_exited: bool,
    /// The reaped child's pid, when `has_exited`.
    pub exited_pid: i32,
    /// The exit code, or `128 + signal`, when `has_exited`.
    pub exited_code: i32,
    /// One of the `SLOPDESK_SUPERVISOR_LISTENER_*` constants.
    pub connection_kind: u32,
    /// Whether the `stream` payload is present.
    pub has_stream: bool,
    /// Where the backlog begins, when `has_stream`.
    pub stream_start: u64,
    /// Where live frames continue, when `has_stream`.
    pub stream_head: u64,
    /// Whether anything was lost before `stream_start`.
    pub stream_lossy: bool,
    /// Whether the child is already gone, so `stream_head` is final.
    pub stream_ended: bool,
    /// Whether the `journal` payload is present. Absent means the session has no transcript, which
    /// is a different answer from an empty one — only the first may fall back.
    pub has_journal: bool,
    /// The transcript's size on disk, when `has_journal`.
    pub journal_bytes: u64,
    /// The geometry the transcript was written at, or `0`.
    pub journal_rows: u16,
    /// See [`Self::journal_rows`].
    pub journal_cols: u16,
    /// Whether a LIVE pane is journaling there, so the head offset is meaningful.
    pub journal_has_head: bool,
    /// How much of the live stream is already in the file, when `journal_has_head`.
    pub journal_head: u64,
    /// Whether the `blocks` payload is present. Absent means the pane has no tap — blocks are off —
    /// which a caller reports differently from "this pane has run nothing yet".
    pub has_blocks: bool,
    /// Whether a `blockOutput` answered with bytes. Absent is an evicted or unknown index.
    pub has_block_output: bool,
    /// How many bytes [`slopdesk_supervisor_reply_block_output`] will deliver.
    pub block_output_len: usize,
    /// Whether a `blockSnapshot` answered at all.
    pub has_block_snapshot: bool,
    /// How many rows the snapshot projection will write.
    pub block_snapshot_count: usize,
    /// Whether a `blockControl` answered with recent blocks.
    pub has_block_recent: bool,
    /// How many rows the recent-blocks projection will write.
    pub block_recent_count: usize,
    /// Whether a command is still running.
    pub has_open_block: bool,
    /// How much the running command has printed, when `has_open_block`.
    pub open_block_output_len: u32,
    /// Whether the `run --wait` baseline is present.
    pub has_next_index: bool,
    /// The index the next command typed at this prompt will close under.
    pub next_index: u32,
}

/// One pane record's scalars, with its strings as offsets into the projection's arena.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorPaneRow {
    /// The child's pid. Valid to `kill`, not to `waitpid`.
    pub pid: i32,
    /// Last known window size.
    pub rows: u16,
    /// Last known window size.
    pub cols: u16,
    /// Unix seconds.
    pub spawned_at: i64,
    /// Whether some hostd currently holds a duplicate of this pane's master fd.
    pub attached: bool,
    /// Whether the record carried a working directory.
    pub has_cwd: bool,
    /// Whether the record carried an owner. Absent means UNKNOWN, never "yours".
    pub has_owner: bool,
    /// Offset into the arena.
    pub pane_id_offset: usize,
    /// Length in the arena.
    pub pane_id_length: usize,
    /// Offset into the arena.
    pub session_id_offset: usize,
    /// Length in the arena.
    pub session_id_length: usize,
    /// Offset into the arena.
    pub executable_offset: usize,
    /// Length in the arena.
    pub executable_length: usize,
    /// Offset into the arena.
    pub cwd_offset: usize,
    /// Length in the arena.
    pub cwd_length: usize,
    /// Offset into the arena.
    pub owner_offset: usize,
    /// Length in the arena.
    pub owner_length: usize,
}

/// One block's metadata, with its command line as an offset into the projection's arena.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorBlockRow {
    /// The block's index in emission order.
    pub index: u32,
    /// Whether the shell reported a `$?`.
    pub has_exit_code: bool,
    /// The command's `$?`, when `has_exit_code`.
    pub exit_code: i32,
    /// Whether a `C`→`D` duration was measured.
    pub has_duration: bool,
    /// The measured milliseconds, when `has_duration`.
    pub duration_ms: u32,
    /// Whether the matching `D` has arrived.
    pub complete: bool,
    /// How many output bytes superd holds for this block.
    pub output_len: u32,
    /// The block's prompt-row ordinal, `0` when unknown.
    pub prompt_ordinal: u32,
    /// Offset into the text arena.
    pub command_offset: usize,
    /// Length in the text arena.
    pub command_length: usize,
}

/// One finished block WITH its bytes: the command line lands in a text arena, the output in its
/// own.
///
/// Two arenas rather than one, because the output is up to 256 KiB per block and the command line
/// is a line: a caller that wants only the texts would otherwise have to lend space for a quarter
/// of a megabyte per row to find out how long they are.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorRecordRow {
    /// The block's index.
    pub index: u32,
    /// Whether the shell reported a `$?`.
    pub has_exit_code: bool,
    /// The command's `$?`, when `has_exit_code`.
    pub exit_code: i32,
    /// Whether a `C`→`D` duration was measured.
    pub has_duration: bool,
    /// The measured milliseconds, when `has_duration`.
    pub duration_ms: u32,
    /// Whether the block closed on its own `D` rather than on a fresh prompt.
    pub complete: bool,
    /// Offset into the text arena.
    pub command_offset: usize,
    /// Length in the text arena.
    pub command_length: usize,
    /// Offset into the byte arena.
    pub output_offset: usize,
    /// Length in the byte arena.
    pub output_length: usize,
}

/// What a projection needs, and therefore what it wrote when it fits.
///
/// Answered whether or not anything was written, so a caller that guessed too small learns both
/// sizes at once rather than one per retry.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSupervisorCounts {
    /// How many records the projection has.
    pub row_count: usize,
    /// How many bytes its text arena needs.
    pub text_length: usize,
    /// How many bytes its byte arena needs. Always `0` except for the record projection.
    pub byte_length: usize,
}

impl SlopDeskSupervisorCounts {
    /// Nothing to project.
    pub(crate) const EMPTY: Self = Self {
        row_count: 0,
        text_length: 0,
        byte_length: 0,
    };
}

/// Parses one reply body.
///
/// `null` means the bytes are not this protocol's JSON at all — a corrupt or truncated frame. It
/// deliberately does NOT mean "vocabulary this build does not know": an unrecognised status decodes
/// to [`SLOPDESK_SUPERVISOR_STATUS_UNRECOGNISED`] and an unrecognised push to
/// [`SLOPDESK_SUPERVISOR_EVENT_UNKNOWN`], because a caller that drops a frame here never wakes the
/// waiter registered under its id, and a pane that hangs is worse than one that fails.
///
/// # Safety
/// `(json, len)` must describe live memory for the call. The returned pointer must be freed exactly
/// once with [`slopdesk_supervisor_reply_free`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_open(
    json: *const c_uchar,
    len: usize,
) -> *mut SlopDeskSupervisorReply {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let bytes = unsafe { borrow(json, len) };
    protocol::Reply::decode(bytes).map_or(core::ptr::null_mut(), |reply| {
        Box::into_raw(Box::new(SlopDeskSupervisorReply { reply }))
    })
}

/// Frees a reply. Null is a no-op.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_supervisor_reply_open`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_free(handle: *mut SlopDeskSupervisorReply) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `open` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Borrows a reply for the duration of one call.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_supervisor_reply_open`].
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *const SlopDeskSupervisorReply) -> Option<&'a protocol::Reply> {
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    unsafe { handle.as_ref() }.map(|held| &held.reply)
}

/// Every scalar on the reply, in one crossing.
///
/// A null handle answers the zeroed head, whose status is [`SLOPDESK_SUPERVISOR_STATUS_OK`] — which
/// would be wrong, so it cannot happen: `open` returning null is the only way to have no handle,
/// and a caller that got null never calls this. The zero is the `Default`, not a decision.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_head(
    handle: *const SlopDeskSupervisorReply,
) -> SlopDeskSupervisorReplyHead {
    // SAFETY: the caller's obligation.
    let Some(reply) = (unsafe { held(handle) }) else {
        return SlopDeskSupervisorReplyHead::default();
    };
    let blocks = reply.blocks.as_ref();
    let open = blocks.and_then(|blocks| blocks.open.as_ref());
    SlopDeskSupervisorReplyHead {
        id: reply.id,
        status: match reply.status {
            Status::Ok => SLOPDESK_SUPERVISOR_STATUS_OK,
            Status::Error => SLOPDESK_SUPERVISOR_STATUS_ERROR,
            Status::Unsupported => SLOPDESK_SUPERVISOR_STATUS_UNSUPPORTED,
            Status::Unrecognised => SLOPDESK_SUPERVISOR_STATUS_UNRECOGNISED,
        },
        event: reply
            .event
            .as_deref()
            .map_or(SLOPDESK_SUPERVISOR_EVENT_NONE, |name| {
                match name {
                    protocol::event::EXITED => SLOPDESK_SUPERVISOR_EVENT_EXITED,
                    protocol::event::CONNECTION => SLOPDESK_SUPERVISOR_EVENT_CONNECTION,
                    _ => SLOPDESK_SUPERVISOR_EVENT_UNKNOWN,
                }
            }),
        has_message: reply.message.is_some(),
        has_hello: reply.hello.is_some(),
        hello_version_major: reply.hello.as_ref().map_or(0, |hello| hello.version_major),
        hello_version_minor: reply.hello.as_ref().map_or(0, |hello| hello.version_minor),
        hello_superd_pid: reply.hello.as_ref().map_or(0, |hello| hello.superd_pid),
        has_hook_socket: reply
            .hello
            .as_ref()
            .is_some_and(|hello| hello.hook_socket_path.is_some()),
        has_control_socket: reply
            .hello
            .as_ref()
            .is_some_and(|hello| hello.control_socket_path.is_some()),
        has_build_version: reply
            .hello
            .as_ref()
            .is_some_and(|hello| hello.build_version.is_some()),
        has_pane: reply.pane.is_some(),
        has_panes: reply.panes.is_some(),
        pane_count: reply.panes.as_ref().map_or(0, Vec::len),
        has_exited: reply.exited.is_some(),
        exited_pid: reply.exited.as_ref().map_or(0, |exited| exited.pid),
        exited_code: reply.exited.as_ref().map_or(0, |exited| exited.code),
        connection_kind: reply
            .connection
            .as_ref()
            .map_or(SLOPDESK_SUPERVISOR_LISTENER_NONE, |notice| {
                match notice.kind.as_str() {
                    protocol::listener_kind::HOOK => SLOPDESK_SUPERVISOR_LISTENER_HOOK,
                    protocol::listener_kind::CONTROL => SLOPDESK_SUPERVISOR_LISTENER_CONTROL,
                    _ => SLOPDESK_SUPERVISOR_LISTENER_UNKNOWN,
                }
            }),
        has_stream: reply.stream.is_some(),
        stream_start: reply.stream.map_or(0, |stream| stream.start),
        stream_head: reply.stream.map_or(0, |stream| stream.head),
        stream_lossy: reply.stream.is_some_and(|stream| stream.lossy),
        stream_ended: reply.stream.is_some_and(|stream| stream.ended),
        has_journal: reply.journal.is_some(),
        journal_bytes: reply.journal.as_ref().map_or(0, |journal| journal.bytes),
        journal_rows: reply.journal.as_ref().map_or(0, |journal| journal.rows),
        journal_cols: reply.journal.as_ref().map_or(0, |journal| journal.cols),
        journal_has_head: reply
            .journal
            .as_ref()
            .is_some_and(|journal| journal.head.is_some()),
        journal_head: reply
            .journal
            .as_ref()
            .and_then(|journal| journal.head)
            .unwrap_or_default(),
        has_blocks: blocks.is_some(),
        has_block_output: blocks.is_some_and(|blocks| blocks.output.is_some()),
        block_output_len: blocks
            .and_then(|blocks| blocks.output.as_deref())
            .map_or(0, |encoded| {
                slopdesk_superwire::blockwire::unbase64(encoded).len()
            }),
        has_block_snapshot: blocks.is_some_and(|blocks| blocks.snapshot.is_some()),
        block_snapshot_count: blocks
            .and_then(|blocks| blocks.snapshot.as_ref())
            .map_or(0, Vec::len),
        has_block_recent: blocks.is_some_and(|blocks| blocks.recent.is_some()),
        block_recent_count: blocks
            .and_then(|blocks| blocks.recent.as_ref())
            .map_or(0, Vec::len),
        has_open_block: open.is_some(),
        open_block_output_len: open.map_or(0, |open| open.output_len),
        has_next_index: blocks.is_some_and(|blocks| blocks.next_index.is_some()),
        next_index: blocks.and_then(|blocks| blocks.next_index).unwrap_or_default(),
    }
}

/// One of the reply's single strings, by selector.
///
/// `0` is both "absent" and "empty"; the head's `has_*` flags are what tell them apart, and they
/// have to, because a `message` of `""` is not the same as a verb that answered without one.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_text(
    handle: *const SlopDeskSupervisorReply,
    which: u32,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation.
    let Some(reply) = (unsafe { held(handle) }) else {
        return 0;
    };
    let answer = match which {
        SLOPDESK_SUPERVISOR_TEXT_MESSAGE => reply.message.as_deref(),
        SLOPDESK_SUPERVISOR_TEXT_HOOK_SOCKET => {
            reply
                .hello
                .as_ref()
                .and_then(|hello| hello.hook_socket_path.as_deref())
        },
        SLOPDESK_SUPERVISOR_TEXT_CONTROL_SOCKET => {
            reply
                .hello
                .as_ref()
                .and_then(|hello| hello.control_socket_path.as_deref())
        },
        SLOPDESK_SUPERVISOR_TEXT_BUILD_VERSION => {
            reply
                .hello
                .as_ref()
                .and_then(|hello| hello.build_version.as_deref())
        },
        SLOPDESK_SUPERVISOR_TEXT_JOURNAL_PATH => reply.journal.as_ref().map(|journal| journal.path.as_str()),
        SLOPDESK_SUPERVISOR_TEXT_EXITED_PANE => reply.exited.as_ref().map(|exited| exited.pane_id.as_str()),
        SLOPDESK_SUPERVISOR_TEXT_OPEN_COMMAND => {
            reply
                .blocks
                .as_ref()
                .and_then(|blocks| blocks.open.as_ref())
                .map(|open| open.command_text.as_str())
        },
        _ => None,
    };
    // SAFETY: the caller's obligation.
    unsafe { deliver(answer.unwrap_or_default().as_bytes(), out, cap) }
}

/// Copies `source` into `arena` at `offset`, answering the offset and length to record.
///
/// # Safety
/// `arena` must be writable for at least `offset + source.len()` bytes.
#[expect(
    unsafe_code,
    reason = "writing into the caller's arena IS the projection this module documents"
)]
pub(crate) const unsafe fn park(source: &str, arena: *mut c_uchar, offset: &mut usize) -> (usize, usize) {
    let bytes = source.as_bytes();
    let start = *offset;
    // SAFETY: the caller's obligation; the source is owned by the reply, which the caller may not
    // alias, so the copy cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr(), arena.add(start), bytes.len()) };
    *offset = start.saturating_add(bytes.len());
    (start, bytes.len())
}

/// The pane records, into the caller's rows and one arena their strings live in.
///
/// `which` picks the single `pane` a spawn or adopt answers with, or the `panes` array a list does.
/// Nothing is written unless BOTH buffers fit, so a caller that guessed too small gets two sizes to
/// lend rather than a half-filled array.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `rows` must be null or writable for `row_cap`
/// records, and `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_panes(
    handle: *const SlopDeskSupervisorReply,
    which: u32,
    rows: *mut SlopDeskSupervisorPaneRow,
    row_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskSupervisorCounts {
    // SAFETY: the caller's obligation.
    let Some(reply) = (unsafe { held(handle) }) else {
        return SlopDeskSupervisorCounts::EMPTY;
    };
    let single: [PaneRecord; 0] = [];
    let records: &[PaneRecord] = match which {
        SLOPDESK_SUPERVISOR_PANES_SINGLE => reply.pane.as_ref().map_or(&single, core::slice::from_ref),
        SLOPDESK_SUPERVISOR_PANES_LIST => reply.panes.as_deref().unwrap_or(&single),
        _ => &single,
    };
    let counts = SlopDeskSupervisorCounts {
        row_count: records.len(),
        text_length: records.iter().map(pane_text_length).sum(),
        byte_length: 0,
    };
    if rows.is_null() || arena.is_null() || counts.row_count > row_cap || counts.text_length > arena_cap {
        return counts;
    }
    let mut offset = 0_usize;
    for (position, record) in records.iter().enumerate() {
        // SAFETY: every `park` below writes inside `text_length`, which was just checked against
        // `arena_cap`, and `arena` is writable for that many bytes by the caller's obligation.
        let (pane_id_offset, pane_id_length) = unsafe { park(&record.pane_id, arena, &mut offset) };
        // SAFETY: as above.
        let (session_id_offset, session_id_length) = unsafe { park(&record.session_id, arena, &mut offset) };
        // SAFETY: as above.
        let (executable_offset, executable_length) = unsafe { park(&record.executable, arena, &mut offset) };
        // SAFETY: as above.
        let (cwd_offset, cwd_length) =
            unsafe { park(record.cwd.as_deref().unwrap_or_default(), arena, &mut offset) };
        // SAFETY: as above.
        let (owner_offset, owner_length) =
            unsafe { park(record.owner.as_deref().unwrap_or_default(), arena, &mut offset) };
        let row = SlopDeskSupervisorPaneRow {
            pid: record.pid,
            rows: record.rows,
            cols: record.cols,
            spawned_at: record.spawned_at,
            attached: record.attached,
            has_cwd: record.cwd.is_some(),
            has_owner: record.owner.is_some(),
            pane_id_offset,
            pane_id_length,
            session_id_offset,
            session_id_length,
            executable_offset,
            executable_length,
            cwd_offset,
            cwd_length,
            owner_offset,
            owner_length,
        };
        // SAFETY: `position < row_count <= row_cap` was checked above, and `rows` is writable for
        // `row_cap` records by the caller's obligation.
        unsafe { rows.add(position).write(row) };
    }
    counts
}

/// How many arena bytes one pane record's five strings need.
fn pane_text_length(record: &PaneRecord) -> usize {
    record.pane_id.len()
        + record.session_id.len()
        + record.executable.len()
        + record.cwd.as_deref().unwrap_or_default().len()
        + record.owner.as_deref().unwrap_or_default().len()
}

/// The retained bytes of a `blockOutput` reply, base64 decoded here.
///
/// Decoded on this side rather than handed over encoded, because the caller wants BYTES and the
/// codec is the one this crate already owns — a second decoder on the far side would be a second
/// place a transcript could silently lie.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_block_output(
    handle: *const SlopDeskSupervisorReply,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation.
    let Some(reply) = (unsafe { held(handle) }) else {
        return 0;
    };
    let bytes = reply
        .blocks
        .as_ref()
        .and_then(|blocks| blocks.output.as_deref())
        .map(slopdesk_superwire::blockwire::unbase64)
        .unwrap_or_default();
    // SAFETY: the caller's obligation.
    unsafe { deliver(&bytes, out, cap) }
}

/// The `blockSnapshot` metadata, into the caller's rows and one arena for the command lines.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `rows` must be null or writable for `row_cap`
/// records, and `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_block_metas(
    handle: *const SlopDeskSupervisorReply,
    rows: *mut SlopDeskSupervisorBlockRow,
    row_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskSupervisorCounts {
    // SAFETY: the caller's obligation.
    let Some(reply) = (unsafe { held(handle) }) else {
        return SlopDeskSupervisorCounts::EMPTY;
    };
    let empty: [BlockMeta; 0] = [];
    let metas: &[BlockMeta] = reply
        .blocks
        .as_ref()
        .and_then(|blocks| blocks.snapshot.as_deref())
        .unwrap_or(&empty);
    let counts = SlopDeskSupervisorCounts {
        row_count: metas.len(),
        text_length: metas.iter().map(|meta| meta.command_text.len()).sum(),
        byte_length: 0,
    };
    if rows.is_null() || arena.is_null() || counts.row_count > row_cap || counts.text_length > arena_cap {
        return counts;
    }
    let mut offset = 0_usize;
    for (position, meta) in metas.iter().enumerate() {
        // SAFETY: the write stays inside `text_length`, checked above against `arena_cap`.
        let (command_offset, command_length) = unsafe { park(&meta.command_text, arena, &mut offset) };
        let row = SlopDeskSupervisorBlockRow {
            index: meta.index,
            has_exit_code: meta.exit_code.is_some(),
            exit_code: meta.exit_code.unwrap_or_default(),
            has_duration: meta.duration_ms.is_some(),
            duration_ms: meta.duration_ms.unwrap_or_default(),
            complete: meta.complete,
            output_len: meta.output_len,
            prompt_ordinal: meta.prompt_ordinal,
            command_offset,
            command_length,
        };
        // SAFETY: `position < row_count <= row_cap`, checked above.
        unsafe { rows.add(position).write(row) };
    }
    counts
}

/// The `blockControl` records, into the caller's rows and TWO arenas — one for the command lines,
/// one for the retained bytes.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `rows` must be null or writable for `row_cap`
/// records, `text_arena` must be null or writable for `text_cap` bytes, and `byte_arena` must be
/// null or writable for `byte_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_supervisor_reply_block_records(
    handle: *const SlopDeskSupervisorReply,
    rows: *mut SlopDeskSupervisorRecordRow,
    row_cap: usize,
    text_arena: *mut c_uchar,
    text_cap: usize,
    byte_arena: *mut c_uchar,
    byte_cap: usize,
) -> SlopDeskSupervisorCounts {
    // SAFETY: the caller's obligation.
    let Some(reply) = (unsafe { held(handle) }) else {
        return SlopDeskSupervisorCounts::EMPTY;
    };
    let empty: [ControlBlock; 0] = [];
    let records: &[ControlBlock] = reply
        .blocks
        .as_ref()
        .and_then(|blocks| blocks.recent.as_deref())
        .unwrap_or(&empty);
    let counts = SlopDeskSupervisorCounts {
        row_count: records.len(),
        text_length: records.iter().map(|record| record.command_text.len()).sum(),
        byte_length: records.iter().map(|record| record.output.len()).sum(),
    };
    if rows.is_null()
        || text_arena.is_null()
        || byte_arena.is_null()
        || counts.row_count > row_cap
        || counts.text_length > text_cap
        || counts.byte_length > byte_cap
    {
        return counts;
    }
    let mut text_offset = 0_usize;
    let mut byte_offset = 0_usize;
    for (position, record) in records.iter().enumerate() {
        // SAFETY: the write stays inside `text_length`, checked above against `text_cap`.
        let (command_offset, command_length) =
            unsafe { park(&record.command_text, text_arena, &mut text_offset) };
        let output_offset = byte_offset;
        // SAFETY: the offsets run over one pass of the same records the length was summed from, so
        // this write stays inside `byte_length`, checked above against `byte_cap`. The source is
        // owned by the reply, which the caller may not alias.
        unsafe {
            core::ptr::copy_nonoverlapping(
                record.output.as_ptr(),
                byte_arena.add(output_offset),
                record.output.len(),
            );
        }
        byte_offset = byte_offset.saturating_add(record.output.len());
        let row = SlopDeskSupervisorRecordRow {
            index: record.index,
            has_exit_code: record.exit_code.is_some(),
            exit_code: record.exit_code.unwrap_or_default(),
            has_duration: record.duration_ms.is_some(),
            duration_ms: record.duration_ms.unwrap_or_default(),
            complete: record.complete,
            command_offset,
            command_length,
            output_offset,
            output_length: record.output.len(),
        };
        // SAFETY: `position < row_count <= row_cap`, checked above.
        unsafe { rows.add(position).write(row) };
    }
    counts
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the C ABI is the thing under test"
)]
mod tests {
    use super::{
        SLOPDESK_SUPERVISOR_EVENT_EXITED, SLOPDESK_SUPERVISOR_EVENT_UNKNOWN,
        SLOPDESK_SUPERVISOR_LISTENER_HOOK, SLOPDESK_SUPERVISOR_PANES_LIST, SLOPDESK_SUPERVISOR_PANES_SINGLE,
        SLOPDESK_SUPERVISOR_STATUS_UNRECOGNISED, SLOPDESK_SUPERVISOR_TEXT_MESSAGE,
        SLOPDESK_SUPERVISOR_VERB_ADOPT, SLOPDESK_SUPERVISOR_VERB_BLOCK_OUTPUT,
        SLOPDESK_SUPERVISOR_VERB_JOURNAL_SWEEP, SLOPDESK_SUPERVISOR_VERB_PAUSE,
        SLOPDESK_SUPERVISOR_VERB_RELEASE, SlopDeskSupervisorPaneRow, SlopDeskSupervisorRecordRow,
        SlopDeskSupervisorSpawnFields, slopdesk_supervisor_encode_journal, slopdesk_supervisor_encode_listen,
        slopdesk_supervisor_encode_pane, slopdesk_supervisor_encode_pane_flag,
        slopdesk_supervisor_encode_pane_number, slopdesk_supervisor_encode_spawn,
        slopdesk_supervisor_reply_block_output, slopdesk_supervisor_reply_block_records,
        slopdesk_supervisor_reply_free, slopdesk_supervisor_reply_head, slopdesk_supervisor_reply_open,
        slopdesk_supervisor_reply_panes, slopdesk_supervisor_reply_text,
    };

    /// The ask-size-then-fill dance every encoding door answers to.
    fn encoded(call: impl Fn(*mut u8, usize) -> usize) -> Option<String> {
        let needed = call(std::ptr::null_mut(), 0);
        if needed == 0 {
            return None;
        }
        let mut buffer = vec![0_u8; needed];
        assert_eq!(call(buffer.as_mut_ptr(), buffer.len()), needed);
        Some(String::from_utf8(buffer).unwrap())
    }

    fn pane_door(which: u32, id: u64) -> Option<String> {
        encoded(|out, cap| unsafe {
            slopdesk_supervisor_encode_pane(which, id, b"pane-a".as_ptr(), 6, out, cap)
        })
    }

    #[test]
    fn a_pane_verb_encodes_the_payload_its_verb_names() {
        assert_eq!(
            pane_door(SLOPDESK_SUPERVISOR_VERB_ADOPT, 5).unwrap(),
            r#"{"id":5,"verb":"adopt","adopt":{"paneID":"pane-a"}}"#
        );
    }

    /// The refusal that makes the grouping safe. A `pause` routed through the pane door would
    /// encode without its `paused` field, and superd would read the absent bool as `false`.
    #[test]
    fn a_verb_outside_a_doors_shape_is_refused_rather_than_half_encoded() {
        assert!(pane_door(SLOPDESK_SUPERVISOR_VERB_PAUSE, 1).is_none());
        assert!(pane_door(SLOPDESK_SUPERVISOR_VERB_JOURNAL_SWEEP, 1).is_none());
        assert!(pane_door(u32::MAX, 1).is_none());
        // And the same value IS accepted by the door whose shape it belongs to.
        assert!(
            encoded(|out, cap| unsafe {
                slopdesk_supervisor_encode_pane_flag(
                    SLOPDESK_SUPERVISOR_VERB_PAUSE,
                    1,
                    b"p".as_ptr(),
                    1,
                    true,
                    out,
                    cap,
                )
            })
            .unwrap()
            .contains(r#""paused":true"#)
        );
    }

    /// A number that will not fit its field saturates. A wrapped block index would fetch the WRONG
    /// block's output, which is the one outcome worse than fetching none.
    #[test]
    fn a_number_too_wide_for_its_field_saturates_rather_than_wrapping() {
        let json = encoded(|out, cap| unsafe {
            slopdesk_supervisor_encode_pane_number(
                SLOPDESK_SUPERVISOR_VERB_BLOCK_OUTPUT,
                1,
                b"p".as_ptr(),
                1,
                u64::from(u32::MAX) + 1,
                out,
                cap,
            )
        })
        .unwrap();
        assert!(json.contains(r#""index":4294967295"#), "{json}");
    }

    /// Null is absent and empty is present, for the one field where the difference is an
    /// instruction: `Some("")` turns auto-progress OFF, `None` leaves superd's built-in list on.
    #[test]
    fn a_null_optional_is_absent_where_an_empty_one_is_present() {
        let spawn = |auto: *const u8, auto_len: usize| {
            encoded(|out, cap| unsafe {
                slopdesk_supervisor_encode_spawn(
                    1,
                    b"p".as_ptr(),
                    1,
                    b"s".as_ptr(),
                    1,
                    b"/bin/zsh".as_ptr(),
                    8,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    auto,
                    auto_len,
                    SlopDeskSupervisorSpawnFields {
                        rows: 24,
                        cols: 80,
                        blocks: true,
                        ..SlopDeskSupervisorSpawnFields::default()
                    },
                    out,
                    cap,
                )
            })
            .unwrap()
        };
        assert!(
            spawn(b"".as_ptr(), 0).contains(r#""autoProgressCommands":"""#),
            "an empty run is the operator clearing the list"
        );
        assert!(
            !spawn(std::ptr::null(), 0).contains("autoProgressCommands"),
            "null is never having set it, and must not be sent"
        );
        // And an absent journal takes its whole payload with it rather than sending a bare cap.
        assert!(!spawn(std::ptr::null(), 0).contains("journal"));
    }

    /// The two run blobs, in the framing `spawn_env` already writes.
    #[test]
    fn the_argument_and_environment_blobs_read_as_runs() {
        let mut arguments = Vec::new();
        for run in ["-l", "-c"] {
            arguments.extend_from_slice(&u32::try_from(run.len()).unwrap().to_be_bytes());
            arguments.extend_from_slice(run.as_bytes());
        }
        let mut environment = Vec::new();
        for run in ["TERM", "xterm-256color", "LANG", "C"] {
            environment.extend_from_slice(&u32::try_from(run.len()).unwrap().to_be_bytes());
            environment.extend_from_slice(run.as_bytes());
        }
        let json = encoded(|out, cap| unsafe {
            slopdesk_supervisor_encode_spawn(
                2,
                b"p".as_ptr(),
                1,
                b"s".as_ptr(),
                1,
                b"/bin/zsh".as_ptr(),
                8,
                b"-zsh".as_ptr(),
                4,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                arguments.as_ptr(),
                arguments.len(),
                environment.as_ptr(),
                environment.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                SlopDeskSupervisorSpawnFields {
                    rows: 24,
                    cols: 80,
                    ..SlopDeskSupervisorSpawnFields::default()
                },
                out,
                cap,
            )
        })
        .unwrap();
        assert!(json.contains(r#""arguments":["-l","-c"]"#), "{json}");
        assert!(
            json.contains(r#""environment":{"LANG":"C","TERM":"xterm-256color"}"#),
            "{json}"
        );
        assert!(json.contains(r#""argv0":"-zsh""#), "{json}");
    }

    /// A truncated blob yields the runs that were intact rather than a wrong pairing — continuing
    /// past a bad length would dress every later run in its neighbour's text.
    #[test]
    fn a_truncated_run_blob_stops_rather_than_misreading_the_rest() {
        let blob = [0, 0, 0, 2, b'o', b'k', 0, 0, 0, 9, b'x'];
        let json = encoded(|out, cap| unsafe {
            slopdesk_supervisor_encode_spawn(
                3,
                b"p".as_ptr(),
                1,
                b"s".as_ptr(),
                1,
                b"/bin/zsh".as_ptr(),
                8,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                blob.as_ptr(),
                blob.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                SlopDeskSupervisorSpawnFields::default(),
                out,
                cap,
            )
        })
        .unwrap();
        assert!(json.contains(r#""arguments":["ok"]"#), "{json}");
    }

    #[test]
    fn listen_names_the_kinds_it_claims_and_omits_the_ones_it_does_not() {
        let both = encoded(|out, cap| unsafe { slopdesk_supervisor_encode_listen(7, true, true, out, cap) })
            .unwrap();
        assert_eq!(
            both,
            r#"{"id":7,"verb":"listen","listen":{"kinds":["hook","control"]}}"#
        );
        let neither =
            encoded(|out, cap| unsafe { slopdesk_supervisor_encode_listen(7, false, false, out, cap) })
                .unwrap();
        assert!(neither.contains(r#""kinds":[]"#), "{neither}");
    }

    #[test]
    fn the_journal_door_answers_all_three_verbs_and_refuses_a_fourth() {
        let sweep = encoded(|out, cap| unsafe {
            slopdesk_supervisor_encode_journal(
                SLOPDESK_SUPERVISOR_VERB_JOURNAL_SWEEP,
                4,
                b"/tmp/j".as_ptr(),
                6,
                std::ptr::null(),
                0,
                86_400,
                12,
                out,
                cap,
            )
        })
        .unwrap();
        assert!(sweep.contains(r#""verb":"journalSweep""#), "{sweep}");
        assert!(sweep.contains(r#""maxAgeSeconds":86400"#), "{sweep}");
        assert!(sweep.contains(r#""keepNewest":12"#), "{sweep}");
        assert!(
            encoded(|out, cap| unsafe {
                slopdesk_supervisor_encode_journal(
                    SLOPDESK_SUPERVISOR_VERB_RELEASE,
                    4,
                    b"/tmp".as_ptr(),
                    4,
                    std::ptr::null(),
                    0,
                    0,
                    0,
                    out,
                    cap,
                )
            })
            .is_none()
        );
    }

    /// Opens a reply, runs a body against it, and frees it exactly once.
    fn with_reply<T>(json: &str, body: impl Fn(*const super::SlopDeskSupervisorReply) -> T) -> T {
        let handle = unsafe { slopdesk_supervisor_reply_open(json.as_ptr(), json.len()) };
        assert!(!handle.is_null(), "{json}");
        let answer = body(handle);
        unsafe { slopdesk_supervisor_reply_free(handle) };
        answer
    }

    /// A vocabulary this build does not know must still OPEN. A caller that drops the frame never
    /// wakes the waiter registered under its id.
    #[test]
    fn an_unknown_status_or_event_opens_rather_than_answering_null() {
        let head = with_reply(r#"{"id":3,"status":"deferred","event":"teleported"}"#, |handle| {
            unsafe { slopdesk_supervisor_reply_head(handle) }
        });
        assert_eq!(head.status, SLOPDESK_SUPERVISOR_STATUS_UNRECOGNISED);
        assert_eq!(head.event, SLOPDESK_SUPERVISOR_EVENT_UNKNOWN);
        // And bytes that are not this protocol at all DO answer null.
        for body in ["", "[]", "{", "null", r#"{"verb":"spawn"}"#] {
            let handle = unsafe { slopdesk_supervisor_reply_open(body.as_ptr(), body.len()) };
            assert!(handle.is_null(), "{body}");
        }
    }

    #[test]
    fn the_head_carries_every_scalar_a_read_loop_routes_on() {
        let json = r#"{"id":0,"status":"ok","event":"exited","exited":{"paneID":"pane-a","pid":9,
            "code":137},"stream":{"start":4,"head":90,"lossy":true}}"#;
        let head = with_reply(json, |handle| unsafe { slopdesk_supervisor_reply_head(handle) });
        assert_eq!(head.id, 0);
        assert_eq!(head.event, SLOPDESK_SUPERVISOR_EVENT_EXITED);
        assert!(head.has_exited);
        assert_eq!(head.exited_pid, 9);
        assert_eq!(head.exited_code, 137);
        assert!(head.has_stream && head.stream_lossy);
        assert_eq!(head.stream_start, 4);
        assert_eq!(head.stream_head, 90);
        assert!(!head.stream_ended, "absent means not known to have ended");
        assert!(!head.has_message, "an absent diagnostic is not an empty one");

        let kind = with_reply(
            r#"{"id":0,"status":"ok","event":"connection","connection":{"kind":"hook"}}"#,
            |handle| unsafe { slopdesk_supervisor_reply_head(handle) },
        );
        assert_eq!(kind.connection_kind, SLOPDESK_SUPERVISOR_LISTENER_HOOK);
    }

    /// An empty diagnostic and an absent one deliver the same zero — the head's flag is what tells
    /// them apart, which is the whole reason the flag exists.
    #[test]
    fn an_empty_text_and_an_absent_one_are_told_apart_by_the_head_and_not_the_length() {
        for (json, present) in [
            (r#"{"id":1,"status":"error","message":""}"#, true),
            (r#"{"id":1,"status":"ok"}"#, false),
        ] {
            with_reply(json, |handle| {
                let head = unsafe { slopdesk_supervisor_reply_head(handle) };
                assert_eq!(head.has_message, present, "{json}");
                let needed = unsafe {
                    slopdesk_supervisor_reply_text(
                        handle,
                        SLOPDESK_SUPERVISOR_TEXT_MESSAGE,
                        std::ptr::null_mut(),
                        0,
                    )
                };
                assert_eq!(needed, 0, "{json}");
            });
        }
    }

    #[test]
    fn the_pane_projection_writes_every_row_and_one_arena() {
        let json = r#"{"id":2,"status":"ok","panes":[
            {"paneID":"a","sessionID":"s1","pid":1,"executable":"/bin/zsh","cwd":"/tmp",
             "rows":24,"cols":80,"spawnedAt":1700000000,"attached":true,"owner":"hostd"},
            {"paneID":"bb","sessionID":"s2","pid":2,"executable":"/bin/sh",
             "rows":10,"cols":20,"spawnedAt":1700000001,"attached":false}]}"#;
        with_reply(json, |handle| {
            let head = unsafe { slopdesk_supervisor_reply_head(handle) };
            assert!(head.has_panes);
            assert_eq!(head.pane_count, 2);

            // The size query writes nothing.
            let counts = unsafe {
                slopdesk_supervisor_reply_panes(
                    handle,
                    SLOPDESK_SUPERVISOR_PANES_LIST,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    0,
                )
            };
            assert_eq!(counts.row_count, 2);
            assert_eq!(
                counts.text_length,
                "a".len()
                    + "s1".len()
                    + "/bin/zsh".len()
                    + "/tmp".len()
                    + "hostd".len()
                    + "bb".len()
                    + "s2".len()
                    + "/bin/sh".len()
            );

            let mut rows = vec![SlopDeskSupervisorPaneRow::default(); counts.row_count];
            let mut arena = vec![0_u8; counts.text_length];
            let filled = unsafe {
                slopdesk_supervisor_reply_panes(
                    handle,
                    SLOPDESK_SUPERVISOR_PANES_LIST,
                    rows.as_mut_ptr(),
                    rows.len(),
                    arena.as_mut_ptr(),
                    arena.len(),
                )
            };
            assert_eq!(filled.row_count, counts.row_count);
            let text = |offset: usize, length: usize| {
                String::from_utf8(arena[offset..offset + length].to_vec()).unwrap()
            };
            assert_eq!(text(rows[0].pane_id_offset, rows[0].pane_id_length), "a");
            assert_eq!(text(rows[0].owner_offset, rows[0].owner_length), "hostd");
            assert_eq!(
                text(rows[1].executable_offset, rows[1].executable_length),
                "/bin/sh"
            );
            assert!(rows[0].has_cwd && rows[0].has_owner);
            assert!(
                !rows[1].has_cwd && !rows[1].has_owner,
                "absent is unknown, never yours"
            );
            assert_eq!(rows[1].spawned_at, 1_700_000_001);

            // The single-pane selector is empty for a `list` reply, and vice versa.
            let single = unsafe {
                slopdesk_supervisor_reply_panes(
                    handle,
                    SLOPDESK_SUPERVISOR_PANES_SINGLE,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    0,
                )
            };
            assert_eq!(single.row_count, 0);
        });
    }

    /// An undersized projection writes NOTHING and reports both sizes — a half-filled array would
    /// be read as a complete one.
    #[test]
    fn an_undersized_projection_writes_nothing_and_reports_both_sizes() {
        let json = r#"{"id":2,"status":"ok","panes":[{"paneID":"a","sessionID":"s","pid":1,
            "executable":"/bin/zsh","rows":1,"cols":1,"spawnedAt":0,"attached":false}]}"#;
        with_reply(json, |handle| {
            let mut rows = vec![SlopDeskSupervisorPaneRow::default(); 1];
            let mut tiny = [0xAA_u8; 1];
            let counts = unsafe {
                slopdesk_supervisor_reply_panes(
                    handle,
                    SLOPDESK_SUPERVISOR_PANES_LIST,
                    rows.as_mut_ptr(),
                    rows.len(),
                    tiny.as_mut_ptr(),
                    tiny.len(),
                )
            };
            assert_eq!(counts.row_count, 1);
            assert!(counts.text_length > tiny.len());
            assert_eq!(
                tiny[0], 0xAA,
                "an undersized call must not write a partial answer"
            );
            assert_eq!(rows[0].pid, 0, "and must not write a partial row either");
        });
    }

    #[test]
    fn the_block_reads_project_their_rows_their_texts_and_their_bytes() {
        // "Zm9v" is "foo"; "!!" is not base64 at all and must land as empty rather than a guess.
        let json = r#"{"id":3,"status":"ok","blocks":{"output":"Zm9v","nextIndex":9,
            "open":{"commandText":"tail -f","outputLen":40},
            "recent":[{"index":1,"commandText":"ls","exitCode":0,"durationMS":5,"complete":true,
                       "output":"Zm9v"},
                      {"index":2,"commandText":"cat","output":"!!"}]}}"#;
        with_reply(json, |handle| {
            let head = unsafe { slopdesk_supervisor_reply_head(handle) };
            assert!(head.has_blocks && head.has_block_output);
            assert_eq!(head.block_output_len, 3);
            assert_eq!(head.block_recent_count, 2);
            assert!(head.has_open_block && head.open_block_output_len == 40);
            assert!(head.has_next_index && head.next_index == 9);
            assert!(!head.has_block_snapshot, "a control read answers no snapshot");

            let mut output = vec![0_u8; head.block_output_len];
            let written =
                unsafe { slopdesk_supervisor_reply_block_output(handle, output.as_mut_ptr(), output.len()) };
            assert_eq!(written, 3);
            assert_eq!(output, b"foo");

            let counts = unsafe {
                slopdesk_supervisor_reply_block_records(
                    handle,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    0,
                )
            };
            assert_eq!(counts.row_count, 2);
            assert_eq!(counts.text_length, "ls".len() + "cat".len());
            assert_eq!(counts.byte_length, 3, "the unusable body contributes nothing");

            let mut rows = vec![SlopDeskSupervisorRecordRow::default(); counts.row_count];
            let mut texts = vec![0_u8; counts.text_length];
            let mut bytes = vec![0_u8; counts.byte_length];
            let filled = unsafe {
                slopdesk_supervisor_reply_block_records(
                    handle,
                    rows.as_mut_ptr(),
                    rows.len(),
                    texts.as_mut_ptr(),
                    texts.len(),
                    bytes.as_mut_ptr(),
                    bytes.len(),
                )
            };
            assert_eq!(filled.row_count, 2);
            let text = |row: &SlopDeskSupervisorRecordRow| {
                String::from_utf8(texts[row.command_offset..row.command_offset + row.command_length].to_vec())
                    .unwrap()
            };
            assert_eq!(text(&rows[0]), "ls");
            assert_eq!(
                text(&rows[1]),
                "cat",
                "the second row reads past the first, not from zero"
            );
            assert_eq!(
                &bytes[rows[0].output_offset..rows[0].output_offset + rows[0].output_length],
                b"foo"
            );
            assert_eq!(
                rows[1].output_offset, 3,
                "the byte arena packs, it does not restart"
            );
            assert_eq!(
                rows[1].output_length, 0,
                "an unusable body is empty, never a guess"
            );
            assert!(
                rows[1].complete,
                "a record with no `complete` key is a closed block"
            );
        });
    }
}
