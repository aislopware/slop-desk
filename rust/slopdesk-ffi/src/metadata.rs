//! The host metadata RPC's payloads — the bodies inside a `metadataRequest` / `metadataResponse`.
//!
//! `rust/slopdesk-wire`'s `metadata::codec` owns every layout. This is the door.
//!
//! ## The shape, and why it repeats
//! Each payload crosses as a `#[repr(C)]` record — a LIST of them where the payload is a list —
//! plus one ARENA holding every text field, each named by an `(offset, length)` pair into it. That
//! is [`crate::wire_message`]'s shape, for [`crate::wire_message`]'s reason: a record with a
//! pointer in it would make the caller own a lifetime, and a record with a fixed char array in it
//! would put a truncation rule in two places.
//!
//! ## Sizing takes no probing call
//! A decode is bounded by the payload it reads: no arena can exceed the payload's own length, and
//! no list can hold more entries than `payload_len / fixed_bytes_per_entry`. So the caller sizes
//! both buffers from the payload it is already holding and calls ONCE. A caller that under-sizes
//! anyway is told the record count it needed and nothing is written — the §4 convention, not a
//! truncation.
//!
//! ## The verdicts
//! [`crate::wire_message`]'s `SLOPDESK_WIRE_DECODE_*`. `UNKNOWN_TYPE` never appears here: a
//! metadata payload's type is chosen by the verb byte outside it, not by a byte inside it.

use core::ffi::c_uchar;
use core::ops::Range;

use slopdesk_wire::metadata::{
    AGENT_SESSION_FIXED_BYTES, CLIPBOARD_BASELINE_PROBE, CodeFontSpec, DIR_ENTRY_FIXED_BYTES,
    DISK_FREE_UNKNOWN, GIT_FILE_FIXED_BYTES, HostVitals, MAX_CLIPBOARD_CONTENT_BYTES, PORT_ENTRY_FIXED_BYTES,
    PROCESS_ENTRY_FIXED_BYTES, ServiceEndpoint, decode_agent_hook_status, decode_agent_session_list,
    decode_clipboard_read_response_leaving_content, decode_code_open_disposition, decode_dir_listing,
    decode_git_status, decode_host_vitals, decode_port_list, decode_process_list, decode_service_endpoint,
    encode_clipboard_read_request_into, encode_clipboard_set_into, encode_code_font_spec_into,
    fold_status_codes,
};

use crate::wire_message::{WIRE_DECODE_AGAIN, WIRE_DECODE_OK, verdict};
use crate::{TextArena, arena_span, arena_text, borrow, deliver, lend};

/// A text field, as an `(offset, length)` pair into the call's arena.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataText {
    /// Where the field starts in the arena.
    pub offset: u32,
    /// How long it is, in bytes.
    pub length: u32,
}

/// One foreground process of a pane.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataProcess {
    /// The process id.
    pub pid: u32,
    /// Seconds the process has been running, `0` when unknown.
    pub uptime_sec: u32,
    /// The process basename.
    pub name: SlopDeskMetadataText,
}

/// One listening port of a pane.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataPort {
    /// The owning process basename.
    pub proc_name: SlopDeskMetadataText,
    /// The port number.
    pub port: u16,
    /// The transport protocol, carried RAW so an unknown future value never drops the entry.
    pub proto: u8,
}

/// One entry of a single host directory level — a LEAF name, never a path.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataDirEntry {
    /// The leaf name.
    pub name: SlopDeskMetadataText,
    /// Whether the entry is a directory.
    pub is_dir: bool,
}

/// One changed file in a git working tree.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataGitFile {
    /// The repo-relative path.
    pub path: SlopDeskMetadataText,
    /// The porcelain `XY` status packed into one byte, carried RAW.
    pub status_code: u8,
}

/// The git status of a pane's cwd, without its file list — which crosses as its own array.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataGitStatus {
    /// The current branch name; empty when detached or when there is no repo.
    pub branch: SlopDeskMetadataText,
    /// The `origin` remote URL; empty when there is none.
    pub remote_url: SlopDeskMetadataText,
    /// The absolute git toplevel — the By-Project grouping key.
    pub repo_root: SlopDeskMetadataText,
    /// Commits ahead of the upstream.
    pub ahead: i32,
    /// Commits behind the upstream.
    pub behind: i32,
    /// Entries in the repo's stash.
    pub stash_count: i32,
    /// How many changed files the companion array carries.
    pub file_count: u32,
    /// Whether the cwd is inside a git repository.
    pub has_repo: bool,
}

/// One agent session file for a project.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataAgentSession {
    /// Last-modified time in milliseconds since the Unix epoch.
    pub mtime_ms: i64,
    /// The session id or path the client passes back to the read verb.
    pub id: SlopDeskMetadataText,
    /// A human-readable title, possibly empty.
    pub title: SlopDeskMetadataText,
    /// The session's project cwd.
    pub cwd: SlopDeskMetadataText,
    /// The owning agent, carried RAW.
    pub agent_kind: u8,
}

/// One synced clipboard clip.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataClip {
    /// Where the content sits. On DECODE this names a range in the PAYLOAD — the clip is left in
    /// place, because a caller already holding up to 12 MiB must not be handed a copy of them. On
    /// ENCODE it names a range in the caller's own arena.
    pub content: SlopDeskMetadataText,
    /// The content kind, carried RAW so an unknown future kind is dropped by the receiver rather
    /// than failing the decode.
    pub kind: u8,
    /// Whether a clip is present at all — a read response may answer a count with no content.
    pub present: bool,
}

/// The host machine's pulse.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataVitals {
    /// Free space in MiB on the volume the user's work lives on.
    pub disk_free_mib: u32,
    /// All-core CPU busy percent (`0..=100`).
    pub cpu_percent: u8,
    /// Physical memory in use percent (`0..=100`).
    pub memory_percent: u8,
    /// The kernel's memory-pressure level, carried RAW.
    pub pressure: u8,
    /// Whether the host could read the disk at all.
    pub has_disk: bool,
}

/// A lazily-spawned host service's endpoint.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataEndpoint {
    /// The TCP port — `0` unless the state is ready.
    pub port: u16,
    /// The lifecycle state, carried RAW.
    pub state: u8,
}

/// Where the host's slopdesk Claude Code hooks stand.
///
/// TWO flags, never folded into one: without a bound listener an installed hook exits silently, so
/// the card must be able to say installed-but-INACTIVE instead of a green that means nothing.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataHookStatus {
    /// The slopdesk entries are present in the host's `~/.claude/settings.json`.
    pub installed: bool,
    /// The hostd hook listener socket is ACTUALLY bound, so hooks can flow.
    pub listener_active: bool,
}

/// The client's terminal-font truth for the embedded workbench.
///
/// The two doubles ride as IEEE-754 BIT PATTERNS, which is the bit-exact-floats invariant: no
/// textual — or lossy — round-trip may perturb a value the workbench then renders by.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataFontSpec {
    /// The font size in points, as bits.
    pub size_bits: u64,
    /// The effective cell-height ratio, as bits.
    pub line_height_bits: u64,
    /// The font family name.
    pub family: SlopDeskMetadataText,
}

/// The arena a decode fills, and the offsets it hands back.
#[derive(Debug, Default)]
struct Arena(TextArena);

impl Arena {
    /// Appends `bytes` and answers where they landed.
    fn intern(&mut self, bytes: &[u8]) -> SlopDeskMetadataText {
        let (offset, length) = self.0.intern(bytes);
        SlopDeskMetadataText { offset, length }
    }

    /// Everything interned so far, in the order it was interned.
    fn bytes(&self) -> &[u8] {
        &self.0.0
    }
}

/// Reads a text field out of the CALLER's arena.
///
/// Lossy on purpose: these bytes are the caller's, so they are not something this crate refused —
/// unlike a decode, where invalid UTF-8 is malformed.
fn text(arena: &[u8], field: SlopDeskMetadataText) -> String {
    arena_text(arena, field.offset, field.length)
}

/// Reads a raw span out of the caller's arena; empty when it does not fit.
fn span(arena: &[u8], field: SlopDeskMetadataText) -> &[u8] {
    arena_span(arena, field.offset, field.length)
}

/// Writes one list's records and arena under the §4 convention, answering the verdict.
///
/// Nothing is written unless BOTH buffers fit, so a caller that under-sized is never left holding
/// half an answer. `*out_count` is the count either way — that is what a retry needs.
///
/// # Safety
/// `records` must be writable for `records_cap` entries, `arena` for `arena_cap` bytes, and
/// `out_count` for one `usize`.
#[expect(
    unsafe_code,
    reason = "the write is the delivery this module exists to perform"
)]
unsafe fn deliver_list<T: Copy>(
    built: &[T],
    pool: &Arena,
    records: *mut T,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
    out_count: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        if !out_count.is_null() {
            out_count.write(built.len());
        }
        if built.len() > records_cap || pool.bytes().len() > arena_cap || records.is_null() {
            return WIRE_DECODE_AGAIN;
        }
        for (slot, record) in built.iter().enumerate() {
            records.add(slot).write(*record);
        }
        deliver(pool.bytes(), arena, arena_cap);
        WIRE_DECODE_OK
    }
}

/// Decodes a process list.
///
/// # Safety
/// `payload` must describe live memory for the call; see [`deliver_list`] for the outputs.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_processes(
    payload: *const c_uchar,
    payload_len: usize,
    records: *mut SlopDeskMetadataProcess,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
    out_count: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's; `borrow` and `deliver_list` restate
    // them.
    unsafe {
        let items = match decode_process_list(borrow(payload, payload_len)) {
            Ok(items) => items,
            Err(error) => return verdict(&error),
        };
        let mut pool = Arena::default();
        let built: Vec<SlopDeskMetadataProcess> = items
            .iter()
            .map(|item| {
                SlopDeskMetadataProcess {
                    pid: item.pid,
                    uptime_sec: item.uptime_sec,
                    name: pool.intern(item.name.as_bytes()),
                }
            })
            .collect();
        deliver_list(&built, &pool, records, records_cap, arena, arena_cap, out_count)
    }
}

/// Decodes a port list.
///
/// # Safety
/// As [`slopdesk_metadata_decode_processes`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_ports(
    payload: *const c_uchar,
    payload_len: usize,
    records: *mut SlopDeskMetadataPort,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
    out_count: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let items = match decode_port_list(borrow(payload, payload_len)) {
            Ok(items) => items,
            Err(error) => return verdict(&error),
        };
        let mut pool = Arena::default();
        let built: Vec<SlopDeskMetadataPort> = items
            .iter()
            .map(|item| {
                SlopDeskMetadataPort {
                    proc_name: pool.intern(item.proc_name.as_bytes()),
                    port: item.port,
                    proto: item.proto,
                }
            })
            .collect();
        deliver_list(&built, &pool, records, records_cap, arena, arena_cap, out_count)
    }
}

/// Decodes a one-level directory listing.
///
/// # Safety
/// As [`slopdesk_metadata_decode_processes`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_dir_listing(
    payload: *const c_uchar,
    payload_len: usize,
    records: *mut SlopDeskMetadataDirEntry,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
    out_count: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let items = match decode_dir_listing(borrow(payload, payload_len)) {
            Ok(items) => items,
            Err(error) => return verdict(&error),
        };
        let mut pool = Arena::default();
        let built: Vec<SlopDeskMetadataDirEntry> = items
            .iter()
            .map(|item| {
                SlopDeskMetadataDirEntry {
                    name: pool.intern(item.name.as_bytes()),
                    is_dir: item.is_dir,
                }
            })
            .collect();
        deliver_list(&built, &pool, records, records_cap, arena, arena_cap, out_count)
    }
}

/// Decodes an agent-session list.
///
/// # Safety
/// As [`slopdesk_metadata_decode_processes`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_agent_sessions(
    payload: *const c_uchar,
    payload_len: usize,
    records: *mut SlopDeskMetadataAgentSession,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
    out_count: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let items = match decode_agent_session_list(borrow(payload, payload_len)) {
            Ok(items) => items,
            Err(error) => return verdict(&error),
        };
        let mut pool = Arena::default();
        let built: Vec<SlopDeskMetadataAgentSession> = items
            .iter()
            .map(|item| {
                SlopDeskMetadataAgentSession {
                    mtime_ms: item.mtime_ms,
                    id: pool.intern(item.id.as_bytes()),
                    title: pool.intern(item.title.as_bytes()),
                    cwd: pool.intern(item.cwd.as_bytes()),
                    agent_kind: item.agent_kind_byte,
                }
            })
            .collect();
        deliver_list(&built, &pool, records, records_cap, arena, arena_cap, out_count)
    }
}

/// Decodes a git status: the head into `out`, its changed files into `records`.
///
/// # Safety
/// `payload` must describe live memory, `out` must be writable for one
/// [`SlopDeskMetadataGitStatus`], and the rest as [`slopdesk_metadata_decode_processes`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_git_status(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskMetadataGitStatus,
    records: *mut SlopDeskMetadataGitFile,
    records_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
    out_count: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let status = match decode_git_status(borrow(payload, payload_len)) {
            Ok(status) => status,
            Err(error) => return verdict(&error),
        };
        let mut pool = Arena::default();
        // The head's three strings are interned FIRST, so their offsets do not move when a long
        // file list follows them.
        let head = SlopDeskMetadataGitStatus {
            branch: pool.intern(status.branch.as_bytes()),
            remote_url: pool.intern(status.remote_url.as_bytes()),
            repo_root: pool.intern(status.repo_root.as_bytes()),
            ahead: status.ahead,
            behind: status.behind,
            stash_count: status.stash_count,
            file_count: u32::try_from(status.files.len()).unwrap_or(u32::MAX),
            has_repo: status.has_repo,
        };
        let built: Vec<SlopDeskMetadataGitFile> = status
            .files
            .iter()
            .map(|file| {
                SlopDeskMetadataGitFile {
                    path: pool.intern(file.path.as_bytes()),
                    status_code: file.status_code,
                }
            })
            .collect();
        let answer = deliver_list(&built, &pool, records, records_cap, arena, arena_cap, out_count);
        if answer == WIRE_DECODE_OK && !out.is_null() {
            out.write(head);
        }
        answer
    }
}

/// Encodes a set-clipboard payload, reading the content out of the caller's arena.
///
/// `clip.content` names a range in the caller's OWN arena, not in any payload: 12 MiB of clip is
/// never copied through this door, it is read where the caller already holds it.
///
/// # Safety
/// `clip` must point at one live struct, `arena` must describe live memory for the call, and `out`
/// must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_encode_clipboard_set(
    clip: *const SlopDeskMetadataClip,
    arena: *const c_uchar,
    arena_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let arena = borrow(arena, arena_len);
        let clip = *clip;
        let content = span(arena, clip.content);
        lend(out, cap, |writer| {
            encode_clipboard_set_into(writer, clip.kind, content);
        })
    }
}

/// Encodes a read-clipboard REQUEST: the last-seen host change count.
///
/// # Safety
/// `out` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_encode_clipboard_read_request(
    last_seen_change_count: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation is `lend`'s.
    unsafe {
        lend(out, cap, |writer| {
            encode_clipboard_read_request_into(writer, last_seen_change_count);
        })
    }
}

/// A payload range, as the `(offset, length)` pair the boundary carries.
fn located(run: &Range<usize>) -> SlopDeskMetadataText {
    SlopDeskMetadataText {
        offset: u32::try_from(run.start).unwrap_or(u32::MAX),
        length: u32::try_from(run.len()).unwrap_or(u32::MAX),
    }
}

/// Decodes a read-clipboard RESPONSE: the change count into `count_out`, the clip into `out`.
///
/// The one decode here that ELIDES: `out.content` names a range in the PAYLOAD rather than in an
/// arena — the two address spaces the envelope door already distinguishes — for a reason no other
/// payload has, which is that a clip runs to 12 MiB and the caller is holding those bytes already.
/// A response with no clip writes `present: false` and an empty run.
///
/// # Safety
/// `payload` must describe live memory, `count_out` must be null or writable for one `i64`, and
/// `out` writable for one struct.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_clipboard_read_response(
    payload: *const c_uchar,
    payload_len: usize,
    count_out: *mut i64,
    out: *mut SlopDeskMetadataClip,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let (count, clip) = match decode_clipboard_read_response_leaving_content(borrow(payload, payload_len))
        {
            Ok(answer) => answer,
            Err(error) => return verdict(&error),
        };
        if !count_out.is_null() {
            count_out.write(count);
        }
        if !out.is_null() {
            out.write(
                clip.map_or_else(SlopDeskMetadataClip::default, |(kind, content)| {
                    SlopDeskMetadataClip {
                        content: located(&content),
                        kind,
                        present: true,
                    }
                }),
            );
        }
        WIRE_DECODE_OK
    }
}

/// Decodes host vitals.
///
/// # Safety
/// `payload` must describe live memory and `out` must be writable for one struct.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_host_vitals(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskMetadataVitals,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let vitals = match decode_host_vitals(borrow(payload, payload_len)) {
            Ok(vitals) => vitals,
            Err(error) => return verdict(&error),
        };
        if !out.is_null() {
            out.write(SlopDeskMetadataVitals {
                disk_free_mib: vitals.disk_free_mib.unwrap_or(0),
                cpu_percent: vitals.cpu_percent,
                memory_percent: vitals.memory_percent,
                pressure: vitals.pressure_byte,
                has_disk: vitals.disk_free_mib.is_some(),
            });
        }
        WIRE_DECODE_OK
    }
}

/// Decodes a service endpoint.
///
/// # Safety
/// `payload` must describe live memory and `out` must be writable for one struct.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_service_endpoint(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskMetadataEndpoint,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let endpoint = match decode_service_endpoint(borrow(payload, payload_len)) {
            Ok(endpoint) => endpoint,
            Err(error) => return verdict(&error),
        };
        if !out.is_null() {
            out.write(SlopDeskMetadataEndpoint {
                port: endpoint.port,
                state: endpoint.state_byte,
            });
        }
        WIRE_DECODE_OK
    }
}

/// Decodes an agent-hook status into `out`.
///
/// The two flags are separate on purpose: installed alone is not "the integration works", and the
/// card that reads this has to be able to say installed-but-INACTIVE rather than paint a green over
/// hooks that exit silently. A flag is true for the byte `1` and nothing else, and a MISSING second
/// byte — a reply predating the listener flag — reads inactive.
///
/// # Safety
/// `payload` must describe live memory and `out` must be null or writable for one struct.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_agent_hook_status(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskMetadataHookStatus,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let status = match decode_agent_hook_status(borrow(payload, payload_len)) {
            Ok(status) => status,
            Err(error) => return verdict(&error),
        };
        if !out.is_null() {
            out.write(SlopDeskMetadataHookStatus {
                installed: status.installed,
                listener_active: status.listener_active,
            });
        }
        WIRE_DECODE_OK
    }
}

/// Decodes a code-open disposition into `out`.
///
/// # Safety
/// `payload` must describe live memory and `out` must be writable for one `u8`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_decode_code_open_disposition(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut c_uchar,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        match decode_code_open_disposition(borrow(payload, payload_len)) {
            Ok(disposition) => {
                if !out.is_null() {
                    out.write(disposition.as_byte());
                }
                WIRE_DECODE_OK
            },
            Err(error) => verdict(&error),
        }
    }
}

/// What a raw memory-pressure byte MEANS, as a byte this build's table names.
///
/// The two vitals bytes that are levels rather than numbers cross RAW, because the field is the
/// wire's and a re-encode has to put back exactly what came in. That leaves the reading — which
/// byte is which level, and what an unrecognised one is — and the reading is a decision, so it is
/// here rather than restated wherever a surface wants a level. `HostVitals::memory_pressure` is
/// where it lives; this door is how the near side reaches it.
///
/// What the rule actually says is worth carrying at the boundary too, because it is the reason it
/// may not be re-derived by whoever needs it next: a level this build cannot interpret reads as
/// NORMAL. A newer host that grows a fourth pressure level must not make an older client paint the
/// alarm ink — the ink means "this machine is thrashing", and the only honest answer to a byte
/// nobody here can read is that nothing has been established.
///
/// Total over every `u8` by construction: the answer is a byte the table above names, so no caller
/// needs a fallback of its own and the door cannot hand back the question it was asked.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_metadata_memory_pressure(pressure_byte: u8) -> u8 {
    // The reading is a method on the record rather than a free function, so the record is what has
    // to be built to ask it. The other three fields are not read on this path and their values are
    // arbitrary; naming them here rather than reaching for `..Default::default()` keeps the door
    // free of anything that could quietly start to matter.
    let vitals = HostVitals {
        cpu_percent: 0,
        memory_percent: 0,
        pressure_byte,
        disk_free_mib: None,
    };
    vitals.memory_pressure().as_byte()
}

/// What a raw service-state byte MEANS, as a byte this build's table names.
///
/// [`slopdesk_metadata_memory_pressure`]'s shape and its argument, one lifecycle over. The benign
/// reading here is STARTING — "keep polling" — and it is benign for the same structural reason the
/// other one is: the two states a client acts on irreversibly are the ones it must not reach by
/// guessing. Rendering the install hint for a state this build cannot interpret tells a person to
/// install something that is already there, and no further poll ever corrects it, because the
/// panel has stopped asking.
///
/// Total over every `u8`, same as above.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_metadata_service_state(state_byte: u8) -> u8 {
    let endpoint = ServiceEndpoint { state_byte, port: 0 };
    endpoint.state().as_byte()
}

/// Encodes a code-font spec.
///
/// The two doubles are read as BITS out of the caller's record, never as a value this boundary
/// could round.
///
/// # Safety
/// `spec` must point at one live struct, `arena` must describe live memory for the call, and `out`
/// must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_encode_code_font_spec(
    spec: *const SlopDeskMetadataFontSpec,
    arena: *const c_uchar,
    arena_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let arena = borrow(arena, arena_len);
        let spec = *spec;
        let built = CodeFontSpec {
            family: text(arena, spec.family),
            size: f64::from_bits(spec.size_bits),
            line_height: f64::from_bits(spec.line_height_bits),
        };
        lend(out, cap, |writer| encode_code_font_spec_into(writer, &built))
    }
}

/// The porcelain breakdown folded from a git status's packed `XY` status codes.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMetadataGitCounts {
    /// Files with an index change.
    pub staged: u32,
    /// Files with a worktree change.
    pub modified: u32,
    /// Files git has never seen.
    pub untracked: u32,
    /// Files in an unmerged state.
    pub conflicted: u32,
}

/// Folds packed `XY` status codes into their porcelain breakdown.
///
/// The fold rides the boundary rather than being spelled on both sides for the reason the fold
/// exists at all: the client's pane summary and the host's status push must never disagree on what
/// "3 modified" means, and two implementations of one rule is exactly how they would.
///
/// It takes the CODES and not the file records because a caller folds far more often than it
/// decodes — once per render of a pane's summary — and one byte per file is the whole input.
///
/// # Safety
/// `codes` must be null or describe `count` live bytes, and `out` writable for one struct.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_fold_git_codes(
    codes: *const c_uchar,
    count: usize,
    out: *mut SlopDeskMetadataGitCounts,
) {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        if out.is_null() {
            return;
        }
        let counts = fold_status_codes(borrow(codes, count).iter().copied());
        out.write(SlopDeskMetadataGitCounts {
            staged: u32::try_from(counts.staged).unwrap_or(u32::MAX),
            modified: u32::try_from(counts.modified).unwrap_or(u32::MAX),
            untracked: u32::try_from(counts.untracked).unwrap_or(u32::MAX),
            conflicted: u32::try_from(counts.conflicted).unwrap_or(u32::MAX),
        });
    }
}

/// One metadata constant by index, so no caller respells a wire number.
///
/// `0` the per-clip content cap, `1` the clipboard baseline probe, `2` the unreadable-disk value,
/// then the FIXED bytes an entry of each list occupies — `3` a process, `4` a port, `5` a directory
/// entry, `6` a changed file, `7` an agent session. Those five are what lets a caller size a decode
/// without a probing call: a list can hold no more entries than `payload_len / fixed`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_metadata_constant(index: u32) -> i64 {
    match index {
        0 => i64::try_from(MAX_CLIPBOARD_CONTENT_BYTES).unwrap_or(i64::MAX),
        1 => CLIPBOARD_BASELINE_PROBE,
        2 => i64::from(DISK_FREE_UNKNOWN),
        3 => i64::try_from(PROCESS_ENTRY_FIXED_BYTES).unwrap_or(i64::MAX),
        4 => i64::try_from(PORT_ENTRY_FIXED_BYTES).unwrap_or(i64::MAX),
        5 => i64::try_from(DIR_ENTRY_FIXED_BYTES).unwrap_or(i64::MAX),
        6 => i64::try_from(GIT_FILE_FIXED_BYTES).unwrap_or(i64::MAX),
        7 => i64::try_from(AGENT_SESSION_FIXED_BYTES).unwrap_or(i64::MAX),
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "the tests drive the same C entry points every caller does"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "a test that slices its own fixture out of range has already failed"
    )]

    use slopdesk_wire::metadata::{
        ClipboardClip, GitFileChange, GitStatusPayload, MemoryPressure, ProcessInfo, ServiceState,
        encode_clipboard_read_response, encode_clipboard_set, encode_code_font_spec, encode_git_status,
        encode_host_vitals, encode_process_list,
    };

    use super::*;

    /// Decodes a process list into generous buffers, answering the records and their arena.
    fn decode_processes(payload: &[u8], cap: usize) -> (u32, usize, Vec<SlopDeskMetadataProcess>, Vec<u8>) {
        let mut records = vec![SlopDeskMetadataProcess::default(); cap];
        let mut arena = vec![0u8; payload.len()];
        let mut count = 0usize;
        // SAFETY: every buffer above is live and sized as the call is told.
        let verdict = unsafe {
            slopdesk_metadata_decode_processes(
                payload.as_ptr(),
                payload.len(),
                records.as_mut_ptr(),
                cap,
                arena.as_mut_ptr(),
                arena.len(),
                &raw mut count,
            )
        };
        (verdict, count, records, arena)
    }

    #[test]
    fn a_process_list_crosses_with_its_names_in_the_arena() {
        let items = [
            ProcessInfo {
                pid: 7,
                uptime_sec: 42,
                name: "zsh".into(),
            },
            ProcessInfo {
                pid: 9,
                uptime_sec: 0,
                name: "cargo".into(),
            },
        ];
        let payload = encode_process_list(&items);
        let (verdict, count, records, arena) = decode_processes(&payload, 8);
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(count, 2);
        assert_eq!(records[0].pid, 7);
        assert_eq!(records[1].uptime_sec, 0);
        assert_eq!(text(&arena, records[0].name), "zsh");
        assert_eq!(text(&arena, records[1].name), "cargo");
    }

    #[test]
    fn a_short_record_buffer_writes_nothing_and_names_the_count() {
        let items = [
            ProcessInfo {
                pid: 1,
                uptime_sec: 1,
                name: "a".into(),
            },
            ProcessInfo {
                pid: 2,
                uptime_sec: 2,
                name: "b".into(),
            },
        ];
        let (verdict, count, records, _) = decode_processes(&encode_process_list(&items), 1);
        assert_eq!(verdict, WIRE_DECODE_AGAIN);
        assert_eq!(
            count, 2,
            "the count a retry needs is answered even when nothing is written"
        );
        assert_eq!(
            records[0].pid, 0,
            "an under-sized call leaves the caller's buffer untouched"
        );
    }

    #[test]
    fn a_git_status_keeps_its_head_strings_and_its_files_in_one_arena() {
        let status = GitStatusPayload {
            has_repo: true,
            branch: "main".into(),
            remote_url: "git@example:repo.git".into(),
            repo_root: "/tmp/repo".into(),
            ahead: 3,
            behind: 1,
            stash_count: 2,
            files: vec![
                GitFileChange {
                    status_code: 0x4D,
                    path: "src/lib.rs".into(),
                },
                GitFileChange {
                    status_code: 0x3F,
                    path: "docs/new.md".into(),
                },
            ],
        };
        let payload = encode_git_status(&status);
        let mut head = SlopDeskMetadataGitStatus::default();
        let mut records = vec![SlopDeskMetadataGitFile::default(); 8];
        let mut arena = vec![0u8; payload.len()];
        let mut count = 0usize;
        // SAFETY: every buffer is live and sized as the call is told.
        let verdict = unsafe {
            slopdesk_metadata_decode_git_status(
                payload.as_ptr(),
                payload.len(),
                &raw mut head,
                records.as_mut_ptr(),
                8,
                arena.as_mut_ptr(),
                arena.len(),
                &raw mut count,
            )
        };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(count, 2);
        assert_eq!(head.file_count, 2);
        assert_eq!(text(&arena, head.branch), "main");
        assert_eq!(text(&arena, head.repo_root), "/tmp/repo");
        assert_eq!(text(&arena, records[1].path), "docs/new.md");
    }

    #[test]
    fn a_clipboard_response_with_no_clip_answers_its_count_alone() {
        let payload = encode_clipboard_read_response(17, None);
        let mut clip = SlopDeskMetadataClip::default();
        let mut change_count = 0i64;
        // SAFETY: both outputs are live for the call.
        let verdict = unsafe {
            slopdesk_metadata_decode_clipboard_read_response(
                payload.as_ptr(),
                payload.len(),
                &raw mut change_count,
                &raw mut clip,
            )
        };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(change_count, 17);
        assert!(!clip.present);
        assert_eq!(clip.content.length, 0);
    }

    /// The door carries the two doubles as BITS, so the bytes it writes are the bytes the wire's
    /// own encoder writes for the same `f64` — a boundary that rounded either value would
    /// differ here.
    #[test]
    fn a_font_spec_crosses_its_doubles_bit_for_bit() {
        let spec = CodeFontSpec {
            family: "SF Mono".into(),
            size: 13.7,
            line_height: 1.234_567_890_123_456_7,
        };
        let payload = encode_code_font_spec(&spec);
        let family = spec.family.as_bytes();
        let flat = SlopDeskMetadataFontSpec {
            size_bits: spec.size.to_bits(),
            line_height_bits: spec.line_height.to_bits(),
            family: SlopDeskMetadataText {
                offset: 0,
                length: u32::try_from(family.len()).unwrap_or(u32::MAX),
            },
        };
        let mut out = vec![0u8; payload.len()];
        // SAFETY: `flat`, the family arena and `out` are all live and sized as the call is told.
        let written = unsafe {
            slopdesk_metadata_encode_code_font_spec(
                &raw const flat,
                family.as_ptr(),
                family.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, payload.len());
        assert_eq!(out, payload);
    }

    #[test]
    fn vitals_carry_the_absence_of_a_disk_reading_across() {
        for disk in [None, Some(4096u32)] {
            let vitals = HostVitals {
                cpu_percent: 12,
                memory_percent: 34,
                pressure_byte: 1,
                disk_free_mib: disk,
            };
            let payload = encode_host_vitals(&vitals);
            let mut flat = SlopDeskMetadataVitals::default();
            // SAFETY: `flat` is live for the call.
            let verdict = unsafe {
                slopdesk_metadata_decode_host_vitals(payload.as_ptr(), payload.len(), &raw mut flat)
            };
            assert_eq!(verdict, WIRE_DECODE_OK);
            assert_eq!(flat.has_disk, disk.is_some());
            assert_eq!(flat.disk_free_mib, disk.unwrap_or(0));
        }
    }

    #[test]
    fn a_truncated_payload_is_refused_rather_than_guessed() {
        let payload = encode_process_list(&[ProcessInfo {
            pid: 5,
            uptime_sec: 5,
            name: "five".into(),
        }]);
        let (verdict, ..) = decode_processes(&payload[..payload.len() - 2], 8);
        assert_ne!(verdict, WIRE_DECODE_OK);
        assert_ne!(verdict, WIRE_DECODE_AGAIN);
    }

    /// The one payload that elides: the clip stays in the payload, and the door only says where.
    ///
    /// The two directions the client actually has are exercised against the SAME clip — the read
    /// response inbound, the set outbound — so the offset the decode reports and the bytes the
    /// encode writes are checked against one fixture rather than two.
    #[test]
    fn a_clip_is_left_in_the_payload_rather_than_copied_out_of_it() {
        let content = vec![0xA5; 64 * 1024];
        let clip = ClipboardClip {
            kind_byte: 2,
            bytes: content.clone(),
        };

        // Inbound: the run names a range in the PAYLOAD, and the 64 KiB is never copied out of it.
        let payload = encode_clipboard_read_response(9, Some(&clip));
        let mut flat = SlopDeskMetadataClip::default();
        let mut change_count = 0i64;
        // SAFETY: every output is live for the call.
        let verdict = unsafe {
            slopdesk_metadata_decode_clipboard_read_response(
                payload.as_ptr(),
                payload.len(),
                &raw mut change_count,
                &raw mut flat,
            )
        };
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(change_count, 9);
        assert!(flat.present);
        assert_eq!(flat.kind, 2);
        assert_eq!(
            flat.content.offset as usize, 9,
            "the run starts where the header ends, in the PAYLOAD's own address space",
        );
        assert_eq!(span(&payload, flat.content), &content[..]);

        // Outbound: the arena is the caller's, and the encode reads the content out of it.
        let expected = encode_clipboard_set(&clip);
        let mut out = vec![0u8; expected.len()];
        let arena = SlopDeskMetadataClip {
            content: SlopDeskMetadataText {
                offset: 0,
                length: u32::try_from(content.len()).unwrap_or(u32::MAX),
            },
            kind: 2,
            present: true,
        };
        // SAFETY: the clip, the arena and `out` are all live and sized as the call is told.
        let written = unsafe {
            slopdesk_metadata_encode_clipboard_set(
                &raw const arena,
                content.as_ptr(),
                content.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, expected.len());
        assert_eq!(out, expected);
    }

    #[test]
    fn the_fold_is_the_one_the_crate_owns() {
        let codes = [0x77u8, 0x66, 0x11];
        let mut counts = SlopDeskMetadataGitCounts::default();
        // SAFETY: both buffers are live for the call.
        unsafe { slopdesk_metadata_fold_git_codes(codes.as_ptr(), codes.len(), &raw mut counts) }
        assert_eq!(counts.untracked, 1);
        assert_eq!(counts.conflicted, 1);
        assert_eq!(counts.staged, 1);
        assert_eq!(counts.modified, 1);
    }

    #[test]
    fn the_constants_are_the_crate_s_own() {
        assert_eq!(
            slopdesk_metadata_constant(0),
            i64::try_from(MAX_CLIPBOARD_CONTENT_BYTES).unwrap_or(i64::MAX)
        );
        assert_eq!(slopdesk_metadata_constant(1), CLIPBOARD_BASELINE_PROBE);
        assert_eq!(slopdesk_metadata_constant(2), i64::from(DISK_FREE_UNKNOWN));
        assert_eq!(
            slopdesk_metadata_constant(99),
            0,
            "an index with no constant answers zero"
        );
    }

    /// The two level readings answer a byte this build's own table names, for EVERY input — which
    /// is what lets the near side stop carrying a fallback of its own. A door that handed an
    /// unrecognised byte back would simply move the decision one step and leave both sides making
    /// it, which is the arrangement these doors exist to end.
    #[test]
    fn the_level_readings_are_total_and_answer_only_named_bytes() {
        for byte in 0u8..=255 {
            let pressure = slopdesk_metadata_memory_pressure(byte);
            assert!(
                MemoryPressure::from_byte(pressure).is_some(),
                "pressure byte {byte} read as {pressure}, which no level names",
            );
            let state = slopdesk_metadata_service_state(byte);
            assert!(
                ServiceState::from_byte(state).is_some(),
                "state byte {byte} read as {state}, which no state names",
            );
        }
    }

    /// A byte the table DOES name is answered unchanged, and the benign reading is the one the rule
    /// promises. Pinned as the two named levels rather than as `0` twice: they are different enums
    /// whose benign case happens to share a discriminant today, and a test written against the
    /// number would keep passing if one of them renumbered.
    #[test]
    fn a_known_level_is_itself_and_an_unknown_one_is_the_benign_reading() {
        for level in [
            MemoryPressure::Normal,
            MemoryPressure::Warn,
            MemoryPressure::Critical,
        ] {
            assert_eq!(
                slopdesk_metadata_memory_pressure(level.as_byte()),
                level.as_byte()
            );
        }
        for state in [
            ServiceState::Starting,
            ServiceState::Ready,
            ServiceState::Unavailable,
        ] {
            assert_eq!(slopdesk_metadata_service_state(state.as_byte()), state.as_byte());
        }
        for unknown in [3u8, 4, 127, 200, 255] {
            assert_eq!(
                slopdesk_metadata_memory_pressure(unknown),
                MemoryPressure::Normal.as_byte(),
                "an uninterpretable level must never light an alarm ink",
            );
            assert_eq!(
                slopdesk_metadata_service_state(unknown),
                ServiceState::Starting.as_byte(),
                "an uninterpretable state must keep the panel polling, not render the install hint",
            );
        }
    }
}
