//! What superd PUSHES inside a `0x04` or `0x05` frame — `SniffedEvent.swift`, `BlockEvent.swift`.
//!
//! [`crate::supervisor_frame`] folded the framing and [`crate::supervisor_protocol`] the
//! request/reply vocabulary. This is the third and last thing that was spelled twice: the batch
//! BODIES those two push frames carry. They are [`slopdesk_superwire::sniffwire`] and
//! [`slopdesk_superwire::blockwire`], and hostd read them with two hand-written Swift decoders
//! whose only contract with the writers was that somebody kept the key names in step.
//!
//! ## Why these take handles where the framing did not
//! A tag is one byte and a batch is a chunk's worth of events, arriving once per output chunk on a
//! pane that is printing. Under [`crate`]'s pure convention a caller would decode the JSON once to
//! ask the size and again to fill, per chunk, on the hot path. So these take the HANDLE convention
//! [`crate::supervisor_protocol`]'s reply already documents: parse once, project into buffers the
//! caller reuses, free.
//!
//! ## Why an unknown kind is a ROW and not a dropped event
//! Both wire enums carry an `Unknown` variant produced only on the reading side, for the reason
//! `docs/51` §3 gives: the protocol is append-only, so a newer superd emits kinds this build has no
//! name for, and a batch that silently shrinks is a skew nothing reports. The projection keeps the
//! row, names it [`SLOPDESK_SNIFF_KIND_UNKNOWN`] or [`SLOPDESK_BLOCK_EVENT_UNKNOWN`], and parks the
//! kind string, so the count a caller reads back is the count that arrived.

use core::ffi::c_uchar;

use slopdesk_superwire::blockwire::{self, BlockEvent, SyntheticProgress};
use slopdesk_superwire::sniffwire::{self, CommandStatus, SniffEvent};

use crate::borrow;
use crate::supervisor_protocol::{SlopDeskSupervisorBlockRow, SlopDeskSupervisorCounts, park};

// MARK: - Sniff kinds

/// [`SniffEvent::Title`] — the primary text is the title.
pub const SLOPDESK_SNIFF_KIND_TITLE: u32 = 0;
/// [`SniffEvent::Bell`] — no text, no numbers.
pub const SLOPDESK_SNIFF_KIND_BELL: u32 = 1;
/// [`SniffEvent::Status`] — read `status`, and the code and duration when it is idle.
pub const SLOPDESK_SNIFF_KIND_STATUS: u32 = 2;
/// [`SniffEvent::Cwd`] — the primary text is the directory, already percent-decoded.
pub const SLOPDESK_SNIFF_KIND_CWD: u32 = 3;
/// [`SniffEvent::Notification`] — primary is the title, secondary the body.
pub const SLOPDESK_SNIFF_KIND_NOTIFICATION: u32 = 4;
/// [`SniffEvent::ProgressBody`] — the primary text is the OSC body, verbatim after the `9;`.
pub const SLOPDESK_SNIFF_KIND_PROGRESS: u32 = 5;
/// [`SniffEvent::Unknown`] — the primary text is the `kind` as written, `""` when it carried none.
pub const SLOPDESK_SNIFF_KIND_UNKNOWN: u32 = 6;

/// Not a status row at all.
pub const SLOPDESK_SNIFF_STATUS_NONE: u32 = 0;
/// [`CommandStatus::Running`].
pub const SLOPDESK_SNIFF_STATUS_RUNNING: u32 = 1;
/// [`CommandStatus::Idle`] — `has_exit_code`/`exit_code` and `duration_ms` carry the rest.
pub const SLOPDESK_SNIFF_STATUS_IDLE: u32 = 2;

// MARK: - Block event kinds

/// [`BlockEvent::Meta`] — every field of `meta` is live.
pub const SLOPDESK_BLOCK_EVENT_META: u32 = 0;
/// [`BlockEvent::Progress`] — read `progress`; `meta` is zeroed.
pub const SLOPDESK_BLOCK_EVENT_PROGRESS: u32 = 1;
/// [`BlockEvent::Unknown`] — `meta.command_offset`/`command_length` carry the `kind` as written.
pub const SLOPDESK_BLOCK_EVENT_UNKNOWN: u32 = 2;

/// Not a progress row at all.
pub const SLOPDESK_BLOCK_PROGRESS_NONE: u32 = 0;
/// [`SyntheticProgress::Indeterminate`] — a slow command started, put a spinner up.
pub const SLOPDESK_BLOCK_PROGRESS_INDETERMINATE: u32 = 1;
/// [`SyntheticProgress::Clear`] — its block closed, take the spinner down.
pub const SLOPDESK_BLOCK_PROGRESS_CLEAR: u32 = 2;

// MARK: - Rows

/// One sniffed event, with its strings as offsets into the projection's arena.
///
/// TWO text slots rather than one because exactly one kind carries two strings — a notification's
/// title and body — and a second projection for that one case would cost a second crossing per
/// batch. Every other kind leaves `secondary_length` at `0`.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskSniffRow {
    /// One of the `SLOPDESK_SNIFF_KIND_*` constants.
    pub kind: u32,
    /// One of the `SLOPDESK_SNIFF_STATUS_*` constants; `NONE` unless `kind` is `STATUS`.
    pub status: u32,
    /// Whether the shell reported a `$?`. Only ever true on an idle status.
    pub has_exit_code: bool,
    /// The command's `$?`, when `has_exit_code`.
    pub exit_code: i32,
    /// The measured milliseconds the command ran; `0` unless `status` is `IDLE`.
    pub duration_ms: u32,
    /// Offset into the arena.
    pub primary_offset: usize,
    /// Length in the arena.
    pub primary_length: usize,
    /// Offset into the arena.
    pub secondary_offset: usize,
    /// Length in the arena.
    pub secondary_length: usize,
}

/// One block event: a kind, a badge state, and the block itself.
///
/// `meta` is [`SlopDeskSupervisorBlockRow`], the same record a `blockSnapshot` projects, because it
/// IS the same object — `docs/51` says one decoder reads a block wherever it turns up, and a second
/// record shape for the live case is exactly the drift that costs.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskBlockEventRow {
    /// One of the `SLOPDESK_BLOCK_EVENT_*` constants.
    pub kind: u32,
    /// One of the `SLOPDESK_BLOCK_PROGRESS_*` constants; `NONE` unless `kind` is `PROGRESS`.
    pub progress: u32,
    /// The block, when `kind` is `META`. On an `UNKNOWN` row only its command slot is used, and it
    /// holds the unnamed kind; every other field is zero.
    pub meta: SlopDeskSupervisorBlockRow,
}

// MARK: - Sniff batch

/// One decoded `0x04` body, held across the calls that read it.
#[derive(Debug)]
pub struct SlopDeskSniffBatch {
    events: Vec<SniffEvent>,
}

/// Parses one sniff batch, or answers null when the bytes are not a batch at all.
///
/// Null means malformed JSON or a non-array, never "a kind this build cannot name": that decodes to
/// a [`SLOPDESK_SNIFF_KIND_UNKNOWN`] row, for the append-only reason in this module's header.
///
/// # Safety
/// `(json, len)` must describe live memory for the call. The returned pointer must be freed exactly
/// once with [`slopdesk_sniff_batch_free`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_sniff_batch_open(
    json: *const c_uchar,
    len: usize,
) -> *mut SlopDeskSniffBatch {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let bytes = unsafe { borrow(json, len) };
    sniffwire::decode_batch(bytes).map_or(core::ptr::null_mut(), |events| {
        Box::into_raw(Box::new(SlopDeskSniffBatch { events }))
    })
}

/// Ends a sniff batch. A null pointer is a no-op; a second call on the same pointer is not.
///
/// # Safety
/// `handle` must be null, or a pointer from [`slopdesk_sniff_batch_open`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_sniff_batch_free(handle: *mut SlopDeskSniffBatch) {
    if handle.is_null() {
        return;
    }
    // SAFETY: the caller's obligation; this reclaims the box `open` leaked.
    drop(unsafe { Box::from_raw(handle) });
}

/// The events, into the caller's rows and one arena their strings live in.
///
/// Nothing is written unless BOTH buffers fit, and the sizes come back either way, so a caller that
/// guessed too small learns what to lend in one call and can never read a half-filled array as a
/// whole batch.
///
/// # Safety
/// `handle` must be null or live, `rows` must be null or writable for `row_cap` records, and
/// `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_sniff_batch_rows(
    handle: *const SlopDeskSniffBatch,
    rows: *mut SlopDeskSniffRow,
    row_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskSupervisorCounts {
    // SAFETY: the caller's obligation.
    let Some(batch) = (unsafe { handle.as_ref() }) else {
        return SlopDeskSupervisorCounts::EMPTY;
    };
    let events = batch.events.as_slice();
    let counts = SlopDeskSupervisorCounts {
        row_count: events.len(),
        text_length: events.iter().map(sniff_text_length).sum(),
        byte_length: 0,
    };
    if rows.is_null() || arena.is_null() || counts.row_count > row_cap || counts.text_length > arena_cap {
        return counts;
    }
    let mut offset = 0_usize;
    for (position, event) in events.iter().enumerate() {
        // SAFETY: the writes run over one pass of the same events the length was summed from, so
        // they stay inside `text_length`, checked above against `arena_cap`.
        let row = unsafe { sniff_row(event, arena, &mut offset) };
        // SAFETY: `position < row_count <= row_cap`, checked above.
        unsafe { rows.add(position).write(row) };
    }
    counts
}

/// What one event will park in the arena.
const fn sniff_text_length(event: &SniffEvent) -> usize {
    match *event {
        SniffEvent::Title(ref text)
        | SniffEvent::Cwd(ref text)
        | SniffEvent::ProgressBody(ref text)
        | SniffEvent::Unknown { kind: ref text } => text.len(),
        SniffEvent::Notification { ref title, ref body } => title.len().saturating_add(body.len()),
        SniffEvent::Bell | SniffEvent::Status(_) => 0,
    }
}

/// Parks one event's strings and answers its row.
///
/// # Safety
/// `arena` must be writable for what [`sniff_text_length`] answered for this event, from `offset`.
#[expect(
    unsafe_code,
    reason = "writing into the caller's arena IS the projection this module documents"
)]
unsafe fn sniff_row(event: &SniffEvent, arena: *mut c_uchar, offset: &mut usize) -> SlopDeskSniffRow {
    // SAFETY: the caller's obligation, discharged once for the one or two strings a kind carries.
    let mut park_one = |source: &str| unsafe { park(source, arena, offset) };
    match *event {
        SniffEvent::Title(ref title) => {
            let (primary_offset, primary_length) = park_one(title);
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_TITLE,
                primary_offset,
                primary_length,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::Bell => {
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_BELL,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::Status(CommandStatus::Running) => {
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_STATUS,
                status: SLOPDESK_SNIFF_STATUS_RUNNING,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::Status(CommandStatus::Idle {
            exit_code,
            duration_ms,
        }) => {
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_STATUS,
                status: SLOPDESK_SNIFF_STATUS_IDLE,
                has_exit_code: exit_code.is_some(),
                exit_code: exit_code.unwrap_or_default(),
                duration_ms,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::Cwd(ref cwd) => {
            let (primary_offset, primary_length) = park_one(cwd);
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_CWD,
                primary_offset,
                primary_length,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::Notification { ref title, ref body } => {
            let (primary_offset, primary_length) = park_one(title);
            let (secondary_offset, secondary_length) = park_one(body);
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_NOTIFICATION,
                primary_offset,
                primary_length,
                secondary_offset,
                secondary_length,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::ProgressBody(ref body) => {
            let (primary_offset, primary_length) = park_one(body);
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_PROGRESS,
                primary_offset,
                primary_length,
                ..SlopDeskSniffRow::default()
            }
        },
        SniffEvent::Unknown { ref kind } => {
            let (primary_offset, primary_length) = park_one(kind);
            SlopDeskSniffRow {
                kind: SLOPDESK_SNIFF_KIND_UNKNOWN,
                primary_offset,
                primary_length,
                ..SlopDeskSniffRow::default()
            }
        },
    }
}

// MARK: - Block batch

/// One decoded `0x05` body, held across the calls that read it.
#[derive(Debug)]
pub struct SlopDeskBlockBatch {
    events: Vec<BlockEvent>,
}

/// Parses one block batch, or answers null when the bytes are not a batch at all.
///
/// # Safety
/// `(json, len)` must describe live memory for the call. The returned pointer must be freed exactly
/// once with [`slopdesk_block_batch_free`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_batch_open(
    json: *const c_uchar,
    len: usize,
) -> *mut SlopDeskBlockBatch {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let bytes = unsafe { borrow(json, len) };
    blockwire::decode_batch(bytes).map_or(core::ptr::null_mut(), |events| {
        Box::into_raw(Box::new(SlopDeskBlockBatch { events }))
    })
}

/// Ends a block batch. A null pointer is a no-op; a second call on the same pointer is not.
///
/// # Safety
/// `handle` must be null, or a pointer from [`slopdesk_block_batch_open`] not yet freed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_batch_free(handle: *mut SlopDeskBlockBatch) {
    if handle.is_null() {
        return;
    }
    // SAFETY: the caller's obligation; this reclaims the box `open` leaked.
    drop(unsafe { Box::from_raw(handle) });
}

/// The events, into the caller's rows and one arena for the command lines.
///
/// All-or-nothing, and the sizes come back either way — [`slopdesk_sniff_batch_rows`]'s contract.
///
/// # Safety
/// `handle` must be null or live, `rows` must be null or writable for `row_cap` records, and
/// `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_batch_rows(
    handle: *const SlopDeskBlockBatch,
    rows: *mut SlopDeskBlockEventRow,
    row_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskSupervisorCounts {
    // SAFETY: the caller's obligation.
    let Some(batch) = (unsafe { handle.as_ref() }) else {
        return SlopDeskSupervisorCounts::EMPTY;
    };
    let events = batch.events.as_slice();
    let counts = SlopDeskSupervisorCounts {
        row_count: events.len(),
        text_length: events.iter().map(block_text_length).sum(),
        byte_length: 0,
    };
    if rows.is_null() || arena.is_null() || counts.row_count > row_cap || counts.text_length > arena_cap {
        return counts;
    }
    let mut offset = 0_usize;
    for (position, event) in events.iter().enumerate() {
        // SAFETY: the writes run over one pass of the same events the length was summed from, so
        // they stay inside `text_length`, checked above against `arena_cap`.
        let row = unsafe { block_row(event, arena, &mut offset) };
        // SAFETY: `position < row_count <= row_cap`, checked above.
        unsafe { rows.add(position).write(row) };
    }
    counts
}

/// What one event will park in the arena.
const fn block_text_length(event: &BlockEvent) -> usize {
    match *event {
        BlockEvent::Meta(ref meta) => meta.command_text.len(),
        BlockEvent::Progress(_) => 0,
        BlockEvent::Unknown { ref kind } => kind.len(),
    }
}

/// Parks one event's command line and answers its row.
///
/// # Safety
/// `arena` must be writable for what [`block_text_length`] answered for this event, from `offset`.
#[expect(
    unsafe_code,
    reason = "writing into the caller's arena IS the projection this module documents"
)]
unsafe fn block_row(event: &BlockEvent, arena: *mut c_uchar, offset: &mut usize) -> SlopDeskBlockEventRow {
    match *event {
        BlockEvent::Meta(ref meta) => {
            // SAFETY: the caller's obligation.
            let (command_offset, command_length) = unsafe { park(&meta.command_text, arena, offset) };
            SlopDeskBlockEventRow {
                kind: SLOPDESK_BLOCK_EVENT_META,
                progress: SLOPDESK_BLOCK_PROGRESS_NONE,
                meta: SlopDeskSupervisorBlockRow {
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
                },
            }
        },
        BlockEvent::Progress(state) => {
            SlopDeskBlockEventRow {
                kind: SLOPDESK_BLOCK_EVENT_PROGRESS,
                progress: match state {
                    SyntheticProgress::Indeterminate => SLOPDESK_BLOCK_PROGRESS_INDETERMINATE,
                    SyntheticProgress::Clear => SLOPDESK_BLOCK_PROGRESS_CLEAR,
                },
                meta: SlopDeskSupervisorBlockRow::default(),
            }
        },
        BlockEvent::Unknown { ref kind } => {
            // SAFETY: the caller's obligation.
            let (command_offset, command_length) = unsafe { park(kind, arena, offset) };
            SlopDeskBlockEventRow {
                kind: SLOPDESK_BLOCK_EVENT_UNKNOWN,
                progress: SLOPDESK_BLOCK_PROGRESS_NONE,
                meta: SlopDeskSupervisorBlockRow {
                    command_offset,
                    command_length,
                    ..SlopDeskSupervisorBlockRow::default()
                },
            }
        },
    }
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
        SLOPDESK_BLOCK_EVENT_META, SLOPDESK_BLOCK_EVENT_PROGRESS, SLOPDESK_BLOCK_EVENT_UNKNOWN,
        SLOPDESK_BLOCK_PROGRESS_CLEAR, SLOPDESK_BLOCK_PROGRESS_INDETERMINATE, SLOPDESK_SNIFF_KIND_BELL,
        SLOPDESK_SNIFF_KIND_CWD, SLOPDESK_SNIFF_KIND_NOTIFICATION, SLOPDESK_SNIFF_KIND_PROGRESS,
        SLOPDESK_SNIFF_KIND_STATUS, SLOPDESK_SNIFF_KIND_TITLE, SLOPDESK_SNIFF_KIND_UNKNOWN,
        SLOPDESK_SNIFF_STATUS_IDLE, SLOPDESK_SNIFF_STATUS_RUNNING, SlopDeskBlockEventRow, SlopDeskSniffRow,
        slopdesk_block_batch_free, slopdesk_block_batch_open, slopdesk_block_batch_rows,
        slopdesk_sniff_batch_free, slopdesk_sniff_batch_open, slopdesk_sniff_batch_rows,
    };

    /// Opens a sniff batch, projects it, frees it — the whole crossing a reader does per chunk.
    fn sniff(json: &str) -> (Vec<SlopDeskSniffRow>, String) {
        let handle = unsafe { slopdesk_sniff_batch_open(json.as_ptr(), json.len()) };
        assert!(!handle.is_null(), "the batch should decode");
        let counts =
            unsafe { slopdesk_sniff_batch_rows(handle, std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) };
        let mut rows = vec![SlopDeskSniffRow::default(); counts.row_count];
        let mut arena = vec![0_u8; counts.text_length];
        let filled = unsafe {
            slopdesk_sniff_batch_rows(
                handle,
                rows.as_mut_ptr(),
                rows.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(filled.row_count, counts.row_count);
        unsafe { slopdesk_sniff_batch_free(handle) };
        (rows, String::from_utf8(arena).unwrap())
    }

    fn blocks(json: &str) -> (Vec<SlopDeskBlockEventRow>, String) {
        let handle = unsafe { slopdesk_block_batch_open(json.as_ptr(), json.len()) };
        assert!(!handle.is_null(), "the batch should decode");
        let counts =
            unsafe { slopdesk_block_batch_rows(handle, std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) };
        let mut rows = vec![SlopDeskBlockEventRow::default(); counts.row_count];
        let mut arena = vec![0_u8; counts.text_length];
        unsafe {
            slopdesk_block_batch_rows(
                handle,
                rows.as_mut_ptr(),
                rows.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        unsafe { slopdesk_block_batch_free(handle) };
        (rows, String::from_utf8(arena).unwrap())
    }

    fn slice(arena: &str, offset: usize, length: usize) -> &str {
        &arena[offset..offset + length]
    }

    #[test]
    fn every_sniffed_kind_arrives_as_the_row_its_kind_names() {
        let (rows, arena) = sniff(
            r#"{"events":[{"kind":"title","value":"zsh"},
                {"kind":"bell"},
                {"kind":"status","state":"running"},
                {"kind":"status","state":"idle","exitCode":3,"durationMS":120},
                {"kind":"cwd","value":"/tmp"},
                {"kind":"notification","title":"done","body":"ok"},
                {"kind":"progress","value":"4;1"}]}"#,
        );
        assert_eq!(rows.len(), 7, "seven members, seven rows");
        assert_eq!(rows[0].kind, SLOPDESK_SNIFF_KIND_TITLE);
        assert_eq!(
            slice(&arena, rows[0].primary_offset, rows[0].primary_length),
            "zsh"
        );
        assert_eq!(rows[1].kind, SLOPDESK_SNIFF_KIND_BELL);
        assert_eq!(rows[1].primary_length, 0, "a bell carries no text");
        assert_eq!(rows[2].kind, SLOPDESK_SNIFF_KIND_STATUS);
        assert_eq!(rows[2].status, SLOPDESK_SNIFF_STATUS_RUNNING);
        assert!(!rows[2].has_exit_code, "a running command has not exited");
        assert_eq!(rows[3].status, SLOPDESK_SNIFF_STATUS_IDLE);
        assert!(rows[3].has_exit_code);
        assert_eq!(rows[3].exit_code, 3);
        assert_eq!(rows[3].duration_ms, 120);
        assert_eq!(rows[4].kind, SLOPDESK_SNIFF_KIND_CWD);
        assert_eq!(
            slice(&arena, rows[4].primary_offset, rows[4].primary_length),
            "/tmp"
        );
        assert_eq!(rows[5].kind, SLOPDESK_SNIFF_KIND_NOTIFICATION);
        assert_eq!(
            slice(&arena, rows[5].primary_offset, rows[5].primary_length),
            "done"
        );
        assert_eq!(
            slice(&arena, rows[5].secondary_offset, rows[5].secondary_length),
            "ok",
            "the body is the second slot, not a second row"
        );
        assert_eq!(rows[6].kind, SLOPDESK_SNIFF_KIND_PROGRESS);
        assert_eq!(
            slice(&arena, rows[6].primary_offset, rows[6].primary_length),
            "4;1"
        );
    }

    #[test]
    fn an_idle_status_without_a_code_is_told_apart_from_one_that_exited_zero() {
        let (rows, _) = sniff(
            r#"{"events":[{"kind":"status","state":"idle","durationMS":7},
                {"kind":"status","state":"idle","exitCode":0,"durationMS":7}]}"#,
        );
        assert!(!rows[0].has_exit_code, "no `$?` reported");
        assert!(rows[1].has_exit_code, "a reported zero is not an absent code");
        assert_eq!(rows[1].exit_code, 0);
    }

    #[test]
    fn a_kind_this_build_cannot_name_stays_a_row_rather_than_shrinking_the_batch() {
        let (rows, arena) =
            sniff(r#"{"events":[{"kind":"title","value":"a"},{"kind":"telemetry"},{"kind":"bell"}]}"#);
        assert_eq!(rows.len(), 3, "the count that arrived is the count read back");
        assert_eq!(rows[1].kind, SLOPDESK_SNIFF_KIND_UNKNOWN);
        assert_eq!(
            slice(&arena, rows[1].primary_offset, rows[1].primary_length),
            "telemetry",
            "the unnamed kind is kept so a skew is visible"
        );
        assert_eq!(rows[2].kind, SLOPDESK_SNIFF_KIND_BELL, "the rest still reads");
    }

    #[test]
    fn a_body_that_is_not_a_batch_answers_null_rather_than_an_empty_one() {
        let torn = br#"{"events":[{"kind":"title""#;
        let handle = unsafe { slopdesk_sniff_batch_open(torn.as_ptr(), torn.len()) };
        assert!(handle.is_null(), "a truncated body is not an empty batch");
        unsafe { slopdesk_sniff_batch_free(handle) };
    }

    #[test]
    fn an_undersized_sniff_projection_writes_nothing_and_reports_its_sizes() {
        let json = r#"{"events":[{"kind":"title","value":"zsh"},{"kind":"cwd","value":"/tmp"}]}"#;
        let handle = unsafe { slopdesk_sniff_batch_open(json.as_ptr(), json.len()) };
        let mut rows = vec![SlopDeskSniffRow::default(); 2];
        let mut arena = [0xAA_u8; 4];
        let counts = unsafe {
            slopdesk_sniff_batch_rows(
                handle,
                rows.as_mut_ptr(),
                rows.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(counts.row_count, 2);
        assert_eq!(counts.text_length, 7, "\"zsh\" and \"/tmp\"");
        assert_eq!(arena, [0xAA; 4], "an arena that does not fit is not half-filled");
        assert_eq!(rows[0].kind, 0, "and no row was written either");
        unsafe { slopdesk_sniff_batch_free(handle) };
    }

    #[test]
    fn a_block_batch_carries_its_metas_its_badges_and_its_unnamed_kinds() {
        let (rows, arena) = blocks(
            r#"{"blocks":[{"kind":"block","index":2,"exitCode":null,"durationMS":null,"complete":false,
                 "outputLen":40,"commandText":"make","promptOrdinal":9},
                {"kind":"progress","state":"indeterminate"},
                {"kind":"block","index":3,"exitCode":0,"durationMS":15,"complete":true,
                 "outputLen":0,"commandText":"ls","promptOrdinal":10},
                {"kind":"progress","state":"clear"},
                {"kind":"weather"}]}"#,
        );
        assert_eq!(rows.len(), 5);
        assert_eq!(rows[0].kind, SLOPDESK_BLOCK_EVENT_META);
        assert!(!rows[0].meta.has_exit_code, "a running block has no code yet");
        assert!(!rows[0].meta.has_duration);
        assert_eq!(rows[0].meta.output_len, 40);
        assert_eq!(rows[0].meta.prompt_ordinal, 9);
        assert_eq!(
            slice(&arena, rows[0].meta.command_offset, rows[0].meta.command_length),
            "make"
        );
        assert_eq!(rows[1].kind, SLOPDESK_BLOCK_EVENT_PROGRESS);
        assert_eq!(rows[1].progress, SLOPDESK_BLOCK_PROGRESS_INDETERMINATE);
        assert_eq!(rows[1].meta.command_length, 0, "a badge parks nothing");
        assert!(rows[2].meta.complete);
        assert_eq!(rows[2].meta.exit_code, 0);
        assert!(rows[2].meta.has_exit_code);
        assert_eq!(rows[2].meta.duration_ms, 15);
        assert_eq!(
            slice(&arena, rows[2].meta.command_offset, rows[2].meta.command_length),
            "ls",
            "the second command reads past the first, not from zero"
        );
        assert_eq!(
            rows[2].meta.command_offset, 4,
            "the arena packs, it does not restart"
        );
        assert_eq!(rows[3].progress, SLOPDESK_BLOCK_PROGRESS_CLEAR);
        assert_eq!(rows[4].kind, SLOPDESK_BLOCK_EVENT_UNKNOWN);
        assert_eq!(
            slice(&arena, rows[4].meta.command_offset, rows[4].meta.command_length),
            "weather",
            "an unnamed kind rides the command slot"
        );
    }
}
