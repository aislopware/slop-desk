//! The LIVENESS half of the workspace document: what is true about a pane's running process, and
//! what the document does when that stops being true.
//!
//! ## Why this is a door rather than a shape
//! `slopdesk_wire::document::liveness` holds three decisions and a codec, and every one of them was
//! written twice until this module existed.
//!
//! - A merge is CLEAR-then-write, never write-over. A fact that stopped being true has to
//!   disappear, or the running command latches after the command finished and the agent label after
//!   the agent exited — the same "edge published, value retained nowhere" failure the document
//!   exists to end, moved one layer up.
//! - Marking a pane dead keeps exactly the two fields that describe a PLACE (its directory and the
//!   project that directory belongs to) and drops every claim about a process. The wider answer
//!   renders a wall of fake-live rows; the narrower one re-buckets every restored row out of its
//!   By-Project section.
//! - The reconciler's reap is THREE-way, and the two-way version of it is a data loss with a
//!   version bump as its only trace: a host that has just restarted has a full layout and no
//!   processes at all, so "reap whatever was not captured" deletes the person's workspace on every
//!   restart.
//!
//! None of the three fails when it is answered twice. They RENDER — which is why they are asked.
//!
//! ## The document crosses as its OWN encoding; the record does not, because it has none
//! Every entry point here takes the document in the flat `(CEntry, blob)` form
//! `slopdesk_ws_encode_snapshot` already takes, and answers an encoded snapshot the caller reads
//! with `slopdesk_ws_decode_snapshot` — [`crate::workspace_intent`]'s arrangement, for
//! [`crate::workspace_intent`]'s reason.
//!
//! A liveness RECORD is the one thing on this path with no byte encoding of its own to borrow: it
//! is what the host builds from a live PTY session before any of it has reached a cell, and
//! [`PaneLiveness::entries`] is precisely the rule that turns it into cells. So it crosses as
//! [`CPaneLiveness`] — one `#[repr(C)]` record whose seven strings are SPANS into the same blob the
//! entries span, which is `docs/55` §6's "one string buffer, not one pointer each" at the width of
//! one value. Every optional non-string carries its own presence flag beside it (`has_grid`,
//! `has_progress`, …) rather than reserving a value to mean absent, because a grid of 0×0 and a
//! pane whose size was never observed are different states and a sentinel would make the near side
//! pick which number means "never".
//!
//! The one place that rule bites hardest is `live_title`: `None` is never observed and `Some("")`
//! is RETIRED by the agent that owned it, and a zero-length span with `present` set is how the
//! second of those survives the trip.

use core::ffi::c_uchar;

use slopdesk_wire::document::codec as wire_codec;
use slopdesk_wire::document::fields::PaneLivenessState;
use slopdesk_wire::document::liveness::{
    AgentState, Grid, PaneLiveness, Progress, mark_pane_dead, merge_pane_liveness, reconcile,
};
use slopdesk_wire::document::state::HostWorkspaceState;

use crate::deliver;
use crate::workspace::{CEntry, Span, Uuid, borrow_array, text_of};
use crate::workspace_intent::document;

/// One pane's liveness facts, flattened for the crossing.
///
/// The seven spans index the blob the caller passes alongside — the SAME blob the document's entry
/// values span, so a whole reconciler tick is one pointer and one lifetime rather than one per
/// string. Scalar fields carry their presence flag next to them; the spans carry theirs inside
/// [`Span`].
///
/// Field ORDER here is the C struct's, chosen widest-first so the layout has no padding to
/// transcribe: the pointer-sized spans, then the 64-bit scalar, then 32, 16 and the bytes. A record
/// laid out by meaning would have had holes in it, and a hole is a place two compilers can
/// disagree.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CPaneLiveness {
    /// The host-minted pane id — the mux session id, which is also the document object id.
    pub id: Uuid,
    /// The title the shell last asserted. Absent is never observed; a present empty span is the
    /// agent's retirement signal, and the two are not the same thing.
    pub live_title: Span,
    /// The working directory.
    pub cwd: Span,
    /// The project that directory belongs to.
    pub project_key: Span,
    /// The foreground process's name.
    pub foreground_process: Span,
    /// The host's own open command block.
    pub running_command: Span,
    /// The agent's label.
    pub agent_label: Span,
    /// What the agent says it is doing.
    pub agent_intent: Span,
    /// Milliseconds since the epoch at the last observed activity. Zero is never.
    pub last_activity_ms: i64,
    /// A monotone counter, bumped on every working-to-done edge.
    pub completion_epoch: u32,
    /// How long the last command took, in milliseconds. Read only when `has_last_duration_ms`.
    pub last_duration_ms: u32,
    /// The last command's exit code. Read only when `has_last_exit_code`.
    pub last_exit_code: i32,
    /// The PTY grid's columns. Read only when `has_grid`.
    pub grid_cols: u16,
    /// The PTY grid's rows. Read only when `has_grid`.
    pub grid_rows: u16,
    /// How real the process is — always meaningful, since its presence IS the pane's existence.
    pub liveness: u8,
    /// The agent's urgency byte. Read only when `has_agent`.
    pub agent_state: u8,
    /// The agent's notification class. Read only when `has_agent`.
    pub agent_kind: u8,
    /// The shell's reported progress state. Read only when `has_progress`.
    pub progress_state: u8,
    /// The percentage that goes with it. Read only when `has_progress`.
    pub progress_percent: u8,
    /// The host's verdict on whether the live title still describes what is on screen.
    pub title_fresh: bool,
    /// Whether a command is running right now.
    pub command_running: bool,
    /// Whether an agent published anything at all.
    pub has_agent: bool,
    /// Whether a progress report was seen.
    pub has_progress: bool,
    /// Whether the last command's exit code is known.
    pub has_last_exit_code: bool,
    /// Whether the last command's duration is known.
    pub has_last_duration_ms: bool,
    /// Whether the PTY's size has been observed.
    pub has_grid: bool,
}

impl CPaneLiveness {
    /// The record this describes, resolved against the blob its spans index.
    ///
    /// A span the blob cannot back reads as ABSENT rather than trapping, the same bounds discipline
    /// every other door here applies: the arithmetic came from another process, and a pane with no
    /// title is a document that renders where a panic is a host that is gone (the release profile
    /// is `panic = "abort"`, so a trap here takes the whole daemon with it).
    fn resolve(&self, blob: &[u8]) -> PaneLiveness {
        let text = |span: Span| text_of(span, blob).map(str::to_owned);
        PaneLiveness {
            pane_id: self.id.bytes,
            liveness: PaneLivenessState::from_byte(self.liveness),
            live_title: text(self.live_title),
            title_fresh: self.title_fresh,
            cwd: text(self.cwd),
            project_key: text(self.project_key),
            foreground_process: text(self.foreground_process),
            running_command: text(self.running_command),
            agent_state: self.has_agent.then_some(AgentState {
                state: self.agent_state,
                kind: self.agent_kind,
            }),
            agent_label: text(self.agent_label),
            agent_intent: text(self.agent_intent),
            progress: self.has_progress.then_some(Progress {
                state: self.progress_state,
                percent: self.progress_percent,
            }),
            command_running: self.command_running,
            last_exit_code: self.has_last_exit_code.then_some(self.last_exit_code),
            last_duration_ms: self.has_last_duration_ms.then_some(self.last_duration_ms),
            grid: self.has_grid.then_some(Grid {
                cols: self.grid_cols,
                rows: self.grid_rows,
            }),
            completion_epoch: self.completion_epoch,
            last_activity_ms: self.last_activity_ms,
        }
    }

    /// The flattened form of one record, with its strings appended to `blob`.
    fn flatten(record: &PaneLiveness, blob: &mut Vec<u8>) -> Self {
        let mut span = |value: Option<&String>| {
            value.map_or(
                Span {
                    offset: 0,
                    len: 0,
                    present: false,
                },
                |text| {
                    let offset = blob.len();
                    blob.extend_from_slice(text.as_bytes());
                    Span {
                        offset,
                        len: blob.len() - offset,
                        present: true,
                    }
                },
            )
        };
        Self {
            id: Uuid {
                bytes: record.pane_id,
            },
            live_title: span(record.live_title.as_ref()),
            cwd: span(record.cwd.as_ref()),
            project_key: span(record.project_key.as_ref()),
            foreground_process: span(record.foreground_process.as_ref()),
            running_command: span(record.running_command.as_ref()),
            agent_label: span(record.agent_label.as_ref()),
            agent_intent: span(record.agent_intent.as_ref()),
            last_activity_ms: record.last_activity_ms,
            completion_epoch: record.completion_epoch,
            last_duration_ms: record.last_duration_ms.unwrap_or(0),
            last_exit_code: record.last_exit_code.unwrap_or(0),
            grid_cols: record.grid.map_or(0, |grid| grid.cols),
            grid_rows: record.grid.map_or(0, |grid| grid.rows),
            liveness: record.liveness.as_byte(),
            agent_state: record.agent_state.map_or(0, |agent| agent.state),
            agent_kind: record.agent_state.map_or(0, |agent| agent.kind),
            progress_state: record.progress.map_or(0, |progress| progress.state),
            progress_percent: record.progress.map_or(0, |progress| progress.percent),
            title_fresh: record.title_fresh,
            command_running: record.command_running,
            has_agent: record.agent_state.is_some(),
            has_progress: record.progress.is_some(),
            has_last_exit_code: record.last_exit_code.is_some(),
            has_last_duration_ms: record.last_duration_ms.is_some(),
            has_grid: record.grid.is_some(),
        }
    }
}

/// The records a caller handed over, resolved against their blob.
///
/// # Safety
/// `records` must be null or point to `count` live [`CPaneLiveness`]s.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: a C array pointer becoming a slice"
)]
unsafe fn resolve_all(records: *const CPaneLiveness, count: usize, blob: &[u8]) -> Vec<PaneLiveness> {
    // SAFETY: the caller's obligation, restated above; `borrow_array` states its own.
    let flat = unsafe { borrow_array(records, count) };
    flat.iter().map(|record| record.resolve(blob)).collect()
}

/// The document as an encoded snapshot, with `changed` reported through the caller's flag.
///
/// A document that did not move answers `0` — the §4 "no answer" — and is not encoded at all. That
/// is not an optimisation bolted onto the convention, it is the convention: there is no NEW
/// document to hand back, and a caller that reads `changed` before the bytes (which is the only
/// correct order, since an unmoved document's snapshot says nothing its caller does not already
/// hold) would have thrown the encoding away. It matters because the settled state is the COMMON
/// one: reconcile runs on a 500 ms backstop whose usual answer is "nothing happened", and encoding
/// a whole workspace twice a second to discard it is the cost this door exists to avoid.
///
/// # Safety
/// `changed` must be null or writable for one `bool`; `out` null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "this IS the boundary: one flag and one buffer through C out-parameters"
)]
unsafe fn answer(
    state: &HostWorkspaceState,
    moved: bool,
    changed: *mut bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    if !changed.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `bool`.
        unsafe { *changed = moved };
    }
    if !moved {
        return 0;
    }
    let bytes = wire_codec::encode_snapshot(state);
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(&bytes, out, cap) }
}

/// One record's document cells, as an encoded snapshot.
///
/// The projection rule, and it is a rule rather than a serialization: a field is emitted only when
/// it carries a NON-DEFAULT value, with exactly one exception — the liveness state is always
/// emitted, so the presence of a pane in the document is never ambiguous. A second copy of that
/// would put a pane in the document that the reaper cannot see, or leave a default value written
/// where its absence was the answer.
///
/// Never 0 for a record that is there: the existence marker alone is a cell. `0` is the null
/// record, which is not a record.
///
/// # Safety
/// `record` must be null or point to one live [`CPaneLiveness`]; `blob` null or to `blob_len` live
/// bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_liveness_entries(
    record: *const CPaneLiveness,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (records, bytes) = unsafe { (borrow_array(record, 1), crate::borrow(blob, blob_len)) };
    let Some(flat) = records.first() else {
        return 0;
    };
    let entries = flat.resolve(bytes).entries();
    let answer = wire_codec::encode_snapshot(&HostWorkspaceState::from_entries(entries));
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(&answer, out, cap) }
}

/// One pane's record, read back OUT of a document's cells.
///
/// Every field decodes independently and a malformed one falls back to its default rather than
/// failing the record: these bytes came off a socket, and one bad grid must not blank a pane's
/// title. An unknown liveness byte from a newer host reads as DEAD — rendering a live pane stale is
/// cosmetic, rendering a dead one live is the bug this whole half exists to prevent, so the degrade
/// is toward the safe side.
///
/// `found` is written on EVERY path, including the one where the answer did not fit, so a caller
/// that sized with `(NULL, 0)` learns from the same call whether there is a pane here at all. The
/// return is how many bytes of STRINGS the answer needs, under §4's convention — and `record`'s
/// spans index `out`, so both are written together or neither is. A found record with no strings
/// answers 0, which is why the existence question is `found` and not the return.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `blob` null or to `blob_len` live
/// bytes; `pane` null or to one live [`Uuid`]; `found` null or writable for one `bool`; `record`
/// null or writable for one [`CPaneLiveness`]; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_pane_liveness_read(
    entries: *const CEntry,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    pane: *const Uuid,
    found: *mut bool,
    record: *mut CPaneLiveness,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes, wanted) = unsafe {
        (
            borrow_array(entries, count),
            crate::borrow(blob, blob_len),
            borrow_array(pane, 1),
        )
    };
    let read = wanted
        .first()
        .and_then(|id| PaneLiveness::from_document(id.bytes, &document(cells, bytes)));
    if !found.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `bool`.
        unsafe { *found = read.is_some() };
    }
    let Some(answer) = read else {
        return 0;
    };
    let mut strings = Vec::new();
    let flat = CPaneLiveness::flatten(&answer, &mut strings);
    if strings.len() > cap || record.is_null() {
        // Nothing written, which is §4's contract and this door's too: a caller retrying must find
        // its record untouched rather than half of one.
        return strings.len();
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one record.
    unsafe { *record = flat };
    // SAFETY: null or, by the caller's obligation, writable for `cap` bytes.
    unsafe { deliver(&strings, out, cap) }
}

/// Replaces the LIVENESS half of every named pane, leaving their topology fields untouched, and
/// answers the resulting document as an encoded snapshot.
///
/// Clear-then-write per pane, so a fact that stopped being true disappears. Panes present in the
/// document but absent from `records` are LEFT ALONE — reaping is
/// [`slopdesk_ws_reconcile_panes`], a separate decision with a separate failure mode, and a merge
/// that reaped would delete every pane a just-restarted host has not captured yet. That is the
/// reason these are two doors and not one with a flag: the wrong value of the flag is the person's
/// entire workspace.
///
/// `records` span the SAME `blob` the entries do. `changed` is written on every path, and is what a
/// caller versions by: every bump costs every subscriber a frame, so a no-op recapture must not
/// move a version number. A document that did not move answers `0` and is not encoded — see
/// [`answer`].
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `records` null or to
/// `record_count` live [`CPaneLiveness`]s; `blob` null or to `blob_len` live bytes; `changed` null
/// or writable for one `bool`; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_merge_pane_liveness(
    entries: *const CEntry,
    count: usize,
    records: *const CPaneLiveness,
    record_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    changed: *mut bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes) = unsafe { (borrow_array(entries, count), crate::borrow(blob, blob_len)) };
    // SAFETY: the caller's obligation on `records`, restated above.
    let captured = unsafe { resolve_all(records, record_count, bytes) };
    let mut state = document(cells, bytes);
    let mut moved = false;
    for entry in &captured {
        moved |= merge_pane_liveness(&mut state, entry);
    }
    // SAFETY: the caller's obligations on `changed` and `out`, restated above.
    unsafe { answer(&state, moved, changed, out, cap) }
}

/// Declares that one pane has NO process, keeping only what describes a PLACE.
///
/// The detached store's TTL eviction. Without it the document goes semantically stale with no
/// signal at all: the store kills a session behind the document's back and every client keeps
/// rendering a live row for a shell that was reaped on a timer.
///
/// A pane the document has never heard of is MINTED as a dead one rather than ignored, because the
/// existence marker is always written: an eviction that raced the pane's first capture must leave
/// the row present-and-stale rather than absent, since absent is what the reaper reads as "nothing
/// owns this" one tick later. Behaviour preserved verbatim from the Swift this replaced.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `blob` null or to `blob_len` live
/// bytes; `pane` null or to one live [`Uuid`]; `changed` null or writable for one `bool`; `out`
/// null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_mark_pane_dead(
    entries: *const CEntry,
    count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    pane: *const Uuid,
    changed: *mut bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes, wanted) = unsafe {
        (
            borrow_array(entries, count),
            crate::borrow(blob, blob_len),
            borrow_array(pane, 1),
        )
    };
    let mut state = document(cells, bytes);
    let moved = wanted
        .first()
        .is_some_and(|id| mark_pane_dead(&mut state, id.bytes));
    // SAFETY: the caller's obligations on `changed` and `out`, restated above.
    unsafe { answer(&state, moved, changed, out, cap) }
}

/// One reconciler pass: fold in what was captured, and decide what the rest of the panes are.
///
/// The three-way rule, whose two-way ancestor deleted the person's layout on every host restart:
/// captured panes take what the capture said, panes the topology still names but nothing captured
/// go STALE rather than being deleted, and panes in neither are reaped whole because nothing owns
/// them. A captured pane the topology has never heard of is NOT reaped — a pane spawned between the
/// last topology write and this tick would otherwise be deleted by the tick that first saw it.
///
/// `records` span the SAME `blob` the entries do. `changed` is written on every path: this runs on
/// a 500 ms backstop as well as on every session-lifecycle event, so an idle host reconciling to
/// the same answer must cost nothing.
///
/// # Safety
/// `entries` must be null or point to `count` live [`CEntry`]s; `records` null or to
/// `record_count` live [`CPaneLiveness`]s; `blob` null or to `blob_len` live bytes; `changed` null
/// or writable for one `bool`; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_reconcile_panes(
    entries: *const CEntry,
    count: usize,
    records: *const CPaneLiveness,
    record_count: usize,
    blob: *const c_uchar,
    blob_len: usize,
    changed: *mut bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; each helper states its own.
    let (cells, bytes) = unsafe { (borrow_array(entries, count), crate::borrow(blob, blob_len)) };
    // SAFETY: the caller's obligation on `records`, restated above.
    let captured = unsafe { resolve_all(records, record_count, bytes) };
    let mut state = document(cells, bytes);
    let moved = reconcile(&mut state, &captured);
    // SAFETY: the caller's obligations on `changed` and `out`, restated above.
    unsafe { answer(&state, moved, changed, out, cap) }
}

/// The liveness byte one state carries, by [`PaneLivenessState`]'s own arm order: attached,
/// detached, dead.
///
/// Exported rather than transcribed for the reason every wire byte here is: these numbers ride in
/// `pane/liveness` cells and are therefore golden-pinned, and a caller that spelled
/// `case detached = 1` beside this would be a second copy of a frozen number. An index naming no
/// state answers the DEAD byte, which is the safe degrade this half already picks everywhere else.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_pane_liveness_state(index: c_uchar) -> c_uchar {
    let state = match index {
        0 => PaneLivenessState::Attached,
        1 => PaneLivenessState::Detached,
        _ => PaneLivenessState::Dead,
    };
    state.as_byte()
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the C entry points through their own signatures IS what these pin"
    )]
    #![expect(
        clippy::expect_used,
        clippy::panic,
        reason = "a door that refuses its own fixture IS the report"
    )]

    use slopdesk_wire::document::codec as wire_codec;
    use slopdesk_wire::document::fields::{PaneLivenessState, pane as pane_field};
    use slopdesk_wire::document::liveness::PaneLiveness;
    use slopdesk_wire::document::state::{HostWorkspaceState, WorkspaceKey, WorkspaceObjectKind};

    use super::{
        CPaneLiveness, slopdesk_ws_mark_pane_dead, slopdesk_ws_merge_pane_liveness,
        slopdesk_ws_pane_liveness_entries, slopdesk_ws_pane_liveness_read, slopdesk_ws_pane_liveness_state,
        slopdesk_ws_reconcile_panes,
    };
    use crate::workspace::{CEntry, Span, Uuid};

    const PANE: [u8; 16] = [7; 16];
    const OTHER: [u8; 16] = [9; 16];

    /// The document's cells and the records' strings in ONE blob, which is the arrangement under
    /// test as much as anything else: a reconciler tick is one pointer, not one per string.
    #[derive(Default)]
    struct Flat {
        cells: Vec<CEntry>,
        records: Vec<CPaneLiveness>,
        blob: Vec<u8>,
        /// The document that went in, kept so a helper can answer what an UNMOVED call leaves —
        /// which is the caller's own state, exactly as Swift's `fold` leaves `self` alone.
        source: HostWorkspaceState,
    }

    impl Flat {
        fn of(state: &HostWorkspaceState, captured: &[PaneLiveness]) -> Self {
            let mut blob = Vec::new();
            let cells = state
                .sorted_entries()
                .into_iter()
                .map(|entry| {
                    let offset = blob.len();
                    blob.extend_from_slice(&entry.value);
                    CEntry {
                        kind: entry.key.kind,
                        field: entry.key.field,
                        object: Uuid {
                            bytes: entry.key.object_id,
                        },
                        value: Span {
                            offset,
                            len: blob.len() - offset,
                            present: true,
                        },
                    }
                })
                .collect();
            let records = captured
                .iter()
                .map(|record| CPaneLiveness::flatten(record, &mut blob))
                .collect();
            Self {
                cells,
                records,
                blob,
                source: state.clone(),
            }
        }
    }

    /// One §4 read: probe with a buffer that does not fit, assert nothing was written, grow, read.
    fn sized(mut call: impl FnMut(*mut u8, usize) -> usize) -> Vec<u8> {
        let mut out = vec![0_u8; 1];
        let mut needed = call(out.as_mut_ptr(), out.len());
        if needed > out.len() {
            assert!(
                out.iter().all(|byte| *byte == 0),
                "a probe that did not fit still wrote"
            );
            out = vec![0_u8; needed];
            needed = call(out.as_mut_ptr(), out.len());
        }
        out.truncate(needed);
        out
    }

    fn snapshot_of(bytes: &[u8]) -> HostWorkspaceState {
        wire_codec::decode_snapshot(bytes).expect("the door answered a snapshot")
    }

    /// What a fold LEAVES: the answered snapshot when the document moved, and the caller's own
    /// document when it did not — with the pin that an unmoved call encodes nothing at all.
    fn folded(flat: &Flat, changed: bool, bytes: &[u8]) -> HostWorkspaceState {
        if changed {
            return snapshot_of(bytes);
        }
        assert!(
            bytes.is_empty(),
            "a document that did not move must not be encoded for a caller that will discard it",
        );
        flat.source.clone()
    }

    fn full_record() -> PaneLiveness {
        let mut record = PaneLiveness::new(PANE, PaneLivenessState::Detached);
        record.live_title = Some("vim README.md".to_owned());
        record.title_fresh = true;
        record.cwd = Some("/work/slop-desk".to_owned());
        record.project_key = Some("slop-desk".to_owned());
        record.foreground_process = Some("vim".to_owned());
        record.running_command = Some("make test".to_owned());
        record.agent_state = Some(slopdesk_wire::document::liveness::AgentState { state: 2, kind: 1 });
        record.agent_label = Some("Claude".to_owned());
        record.agent_intent = Some("running the tests".to_owned());
        record.progress = Some(slopdesk_wire::document::liveness::Progress {
            state: 1,
            percent: 42,
        });
        record.command_running = true;
        record.last_exit_code = Some(-1);
        record.last_duration_ms = Some(1234);
        record.grid = Some(slopdesk_wire::document::liveness::Grid { cols: 120, rows: 40 });
        record.completion_epoch = 9;
        record.last_activity_ms = 1_700_000_000_000;
        record
    }

    /// A pane the person ARRANGED — one topology cell, which is all the reap rule reads.
    fn arranged(state: &mut HostWorkspaceState, pane_id: [u8; 16]) {
        state.set(
            WorkspaceKey::of(WorkspaceObjectKind::Pane, pane_id, pane_field::TITLE),
            wire_codec::encode_string("nvim", wire_codec::MAX_STRING_BYTES),
        );
    }

    fn merge(flat: &Flat) -> (bool, HostWorkspaceState) {
        let mut changed = false;
        let bytes = sized(|out, cap| unsafe {
            slopdesk_ws_merge_pane_liveness(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.records.as_ptr(),
                flat.records.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                &raw mut changed,
                out,
                cap,
            )
        });
        (changed, folded(flat, changed, &bytes))
    }

    fn reconcile(flat: &Flat) -> (bool, HostWorkspaceState) {
        let mut changed = false;
        let bytes = sized(|out, cap| unsafe {
            slopdesk_ws_reconcile_panes(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.records.as_ptr(),
                flat.records.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                &raw mut changed,
                out,
                cap,
            )
        });
        (changed, folded(flat, changed, &bytes))
    }

    fn read(state: &HostWorkspaceState, pane_id: [u8; 16]) -> Option<PaneLiveness> {
        let flat = Flat::of(state, &[]);
        let id = Uuid { bytes: pane_id };
        let mut found = false;
        let blank = PaneLiveness::new([0; 16], PaneLivenessState::Dead);
        let mut record = CPaneLiveness::flatten(&blank, &mut Vec::new());
        let strings = sized(|out, cap| unsafe {
            slopdesk_ws_pane_liveness_read(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                &raw const id,
                &raw mut found,
                &raw mut record,
                out,
                cap,
            )
        });
        found.then(|| record.resolve(&strings))
    }

    #[test]
    fn a_record_makes_the_round_trip_through_its_two_doors() {
        // The pair IS the pin: `entries` writes the cells and `read` reads them back, and the
        // record that comes out has to be the one that went in, spans and presence flags included.
        let record = full_record();
        let mut blob = Vec::new();
        let flat = CPaneLiveness::flatten(&record, &mut blob);
        let bytes = sized(|out, cap| unsafe {
            slopdesk_ws_pane_liveness_entries(&raw const flat, blob.as_ptr(), blob.len(), out, cap)
        });
        assert_eq!(read(&snapshot_of(&bytes), PANE), Some(record));
    }

    #[test]
    fn an_empty_title_stays_distinct_from_a_missing_one_across_the_boundary() {
        // A present zero-length span is the agent's RETIREMENT signal; an absent one is a title
        // nobody ever asserted. A crossing that collapsed them would blank a row that had a name.
        let mut retired = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        retired.live_title = Some(String::new());
        let never = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        for (record, expected) in [(retired, Some(String::new())), (never, None)] {
            let mut blob = Vec::new();
            let flat = CPaneLiveness::flatten(&record, &mut blob);
            let bytes = sized(|out, cap| unsafe {
                slopdesk_ws_pane_liveness_entries(&raw const flat, blob.as_ptr(), blob.len(), out, cap)
            });
            assert_eq!(
                read(&snapshot_of(&bytes), PANE).and_then(|back| back.live_title),
                expected,
            );
        }
    }

    #[test]
    fn a_pane_the_document_does_not_hold_is_reported_absent_rather_than_empty() {
        let id = Uuid { bytes: PANE };
        let mut found = true;
        let needed = unsafe {
            slopdesk_ws_pane_liveness_read(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                &raw const id,
                &raw mut found,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert!(!found, "a document with no cells holds no panes");
        assert_eq!(needed, 0);
    }

    #[test]
    fn the_existence_flag_is_written_even_when_the_answer_did_not_fit() {
        // The sizing probe and the existence question are ONE call, which is what stops a caller
        // that guessed too small from having to ask twice whether there is a pane at all.
        let state = HostWorkspaceState::from_entries(full_record().entries());
        let flat = Flat::of(&state, &[]);
        let id = Uuid { bytes: PANE };
        let mut found = false;
        let needed = unsafe {
            slopdesk_ws_pane_liveness_read(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                &raw const id,
                &raw mut found,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert!(found);
        assert!(needed > 0, "a full record has strings in it");
    }

    #[test]
    fn a_merge_clears_a_fact_that_stopped_being_true_and_keeps_the_topology() {
        let mut state = HostWorkspaceState::from_entries(full_record().entries());
        arranged(&mut state, PANE);
        let quiet = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        let (changed, next) = merge(&Flat::of(&state, &[quiet]));
        assert!(changed);
        let Some(back) = read(&next, PANE) else {
            panic!("the pane still exists");
        };
        assert_eq!(back.running_command, None, "the finished command must disappear");
        assert_eq!(back.agent_label, None);
        assert!(!back.command_running);
        assert_eq!(
            next.get(&WorkspaceKey::of(
                WorkspaceObjectKind::Pane,
                PANE,
                pane_field::TITLE
            ))
            .and_then(wire_codec::decode_string)
            .as_deref(),
            Some("nvim"),
            "a liveness recapture must never delete a persisted title",
        );
    }

    #[test]
    fn a_no_op_recapture_reports_no_change() {
        let record = full_record();
        let state = HostWorkspaceState::from_entries(record.entries());
        let (changed, _) = merge(&Flat::of(&state, &[record]));
        assert!(
            !changed,
            "an unchanged recapture must not churn the version every subscriber pays for",
        );
    }

    #[test]
    fn a_merge_never_reaps_a_pane_it_was_not_told_about() {
        // The reason this is not `reconcile` with a flag: the wrong value would be the whole
        // workspace of a host that has restarted and captured nothing yet.
        let mut state = HostWorkspaceState::new();
        arranged(&mut state, PANE);
        arranged(&mut state, OTHER);
        let (_, next) = merge(&Flat::of(&state, &[]));
        assert_eq!(next.keys().len(), 2, "a merge of nothing changes nothing");
    }

    #[test]
    fn a_restart_that_captures_nothing_keeps_every_pane_in_the_layout() {
        let mut state = HostWorkspaceState::new();
        arranged(&mut state, PANE);
        arranged(&mut state, OTHER);
        let (changed, next) = reconcile(&Flat::of(&state, &[]));
        assert!(changed);
        for pane_id in [PANE, OTHER] {
            assert_eq!(
                read(&next, pane_id).map(|record| record.liveness),
                Some(PaneLivenessState::Dead),
                "present, and honestly stale",
            );
        }
    }

    #[test]
    fn a_pane_owned_by_nothing_is_reaped_and_one_the_layout_names_is_not() {
        let mut state = HostWorkspaceState::from_entries(full_record().entries());
        arranged(&mut state, OTHER);
        let (changed, next) = reconcile(&Flat::of(&state, &[]));
        assert!(changed);
        assert_eq!(read(&next, PANE), None, "nothing owns it");
        assert!(
            next.keys_of_object(WorkspaceObjectKind::Pane.as_byte(), PANE)
                .is_empty(),
            "reaped whole, not left as a husk of one field",
        );
        assert!(read(&next, OTHER).is_some());
    }

    #[test]
    fn a_captured_pane_outside_the_topology_survives_its_first_tick() {
        let mut state = HostWorkspaceState::new();
        arranged(&mut state, OTHER);
        let mut fresh = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        fresh.live_title = Some("sh".to_owned());
        let (_, next) = reconcile(&Flat::of(&state, &[fresh]));
        assert_eq!(
            read(&next, PANE).and_then(|record| record.live_title),
            Some("sh".to_owned()),
        );
    }

    #[test]
    fn a_settled_reconcile_is_not_a_version() {
        let mut state = HostWorkspaceState::new();
        arranged(&mut state, PANE);
        let (_, settled) = reconcile(&Flat::of(&state, &[]));
        let (changed, _) = reconcile(&Flat::of(&settled, &[]));
        assert!(!changed, "an idle host must not churn a version number");
    }

    #[test]
    fn eviction_and_reconcile_leave_a_pane_in_the_same_state() {
        let mut state = HostWorkspaceState::from_entries(full_record().entries());
        arranged(&mut state, PANE);
        let flat = Flat::of(&state, &[]);
        let id = Uuid { bytes: PANE };
        let mut changed = false;
        let evicted = sized(|out, cap| unsafe {
            slopdesk_ws_mark_pane_dead(
                flat.cells.as_ptr(),
                flat.cells.len(),
                flat.blob.as_ptr(),
                flat.blob.len(),
                &raw const id,
                &raw mut changed,
                out,
                cap,
            )
        });
        assert!(changed);
        let (_, reconciled) = reconcile(&Flat::of(&state, &[PaneLiveness::new(
            OTHER,
            PaneLivenessState::Attached,
        )]));
        assert_eq!(read(&snapshot_of(&evicted), PANE), read(&reconciled, PANE));
    }

    #[test]
    fn evicting_a_pane_the_document_never_held_mints_a_dead_one() {
        // Not an accident of the merge: the existence marker is ALWAYS written, so an eviction that
        // raced a pane's first capture leaves the row present-and-stale. Absent would read to the
        // reaper as "nothing owns this" on the very next tick.
        let id = Uuid { bytes: PANE };
        let mut changed = false;
        let bytes = sized(|out, cap| unsafe {
            slopdesk_ws_mark_pane_dead(
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                &raw const id,
                &raw mut changed,
                out,
                cap,
            )
        });
        assert!(changed);
        assert_eq!(
            read(&snapshot_of(&bytes), PANE).map(|record| record.liveness),
            Some(PaneLivenessState::Dead),
        );
    }

    #[test]
    fn the_exported_liveness_bytes_are_the_ones_the_states_carry() {
        for (index, state) in [
            PaneLivenessState::Attached,
            PaneLivenessState::Detached,
            PaneLivenessState::Dead,
        ]
        .into_iter()
        .enumerate()
        {
            assert_eq!(
                slopdesk_ws_pane_liveness_state(u8::try_from(index).unwrap_or(u8::MAX)),
                state.as_byte(),
            );
        }
        assert_eq!(
            slopdesk_ws_pane_liveness_state(200),
            PaneLivenessState::Dead.as_byte(),
            "an index naming no state degrades to the safe side",
        );
    }

    #[test]
    fn a_span_the_blob_cannot_back_reads_as_absent() {
        // Not a hypothetical: the offsets are arithmetic done in another process. A record whose
        // title span runs off the end must merge as a pane with no title, not trap — a trap here
        // aborts the whole daemon.
        let mut record = PaneLiveness::new(PANE, PaneLivenessState::Attached);
        record.live_title = Some("gone".to_owned());
        let mut blob = Vec::new();
        let mut flat = CPaneLiveness::flatten(&record, &mut blob);
        flat.live_title.offset = usize::MAX - 1;
        let bytes = sized(|out, cap| unsafe {
            slopdesk_ws_pane_liveness_entries(&raw const flat, blob.as_ptr(), blob.len(), out, cap)
        });
        let back = read(&snapshot_of(&bytes), PANE);
        assert_eq!(
            back.map(|found| found.liveness),
            Some(PaneLivenessState::Attached)
        );
    }

    #[test]
    fn a_null_record_is_not_a_record() {
        let needed = unsafe {
            slopdesk_ws_pane_liveness_entries(
                core::ptr::null(),
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 0, "nothing to project is not an empty projection");
    }
}
