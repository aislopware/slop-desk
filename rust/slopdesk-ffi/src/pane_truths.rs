//! One pane's latched truths and the fold that produces them — docs/59 step 4.
//!
//! `rust/slopdesk-muxsession`'s `truths` owns the decisions. This is the door.
//!
//! ## Why this one is a HANDLE
//! The same test [`crate::pane_outbox`] and [`crate::pane_fanout`] answer, and this time it answers
//! for SEVEN pieces of state at once. The title latch, the progress badge, the command edge, the
//! exit code, the running block, the echo anchor and the turn counter each lived behind their own
//! `NSLock` in hostd, all seven written on the read-loop thread and read from a control socket's.
//! They were separate because the FIELDS were separate — never because the truths are: one sniffed
//! batch folds most of them in one pass. Seven acquisitions bought no concurrency against a serial
//! writer and cost every reader the chance of a torn view, so they cross as one handle under one
//! lock.
//!
//! ## What did NOT cross
//! - **The clock.** Both stamps are parameters. Two clocks are in play deliberately, and a fold
//!   that read either one could not be tested.
//! - **The agent detector.** It is its own handle with its own feeds ([`crate::agent`]), and two
//!   handles never hold each other. The one thing the fold needs from it —
//!   `suppresses_child_notifications` — crosses as a `bool` the caller reads under the same lock.
//! - **The wire vocabulary.** A verdict names a KIND and a ROUTE. Building the frame is the Swift
//!   marshaller's job, out of the row it already holds.
//!
//! ## Text crosses ONCE, by reference
//! A batch arrives already decoded into rows and a byte arena (`slopdesk_sniff_batch_rows`). The
//! fold BORROWS out of that arena and a verdict names its fact by INDEX, so a chunk carrying ten
//! titles allocates nothing on the way in and nothing on the way out. Only the two truths that must
//! OUTLIVE the batch — the title and the running command line — are copied, and only when they
//! change.

use std::os::raw::c_uchar;

use slopdesk_agent::attention::mints_finished_turn;
use slopdesk_agent::status::ClaudeStatus;
use slopdesk_muxsession::truths::{CwdGate, Fact, Kind, Reassert, Scalars, Stamps, Truths};
use slopdesk_terminal::echo::is_edge;

use crate::{arena_span, deliver, lent, optional, records_of, spill};

/// One thing the shell said, as the caller's decoded row.
///
/// The text fields are `(offset, length)` pairs into the arena the caller lends alongside, never
/// pointers: a row that made Swift own a lifetime would be a row Swift could not put in an array.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskTruthFact {
    /// Which [`Kind`] this is. A discriminant this build has no name for is SKIPPED.
    pub kind: u8,
    /// Title / cwd / notification title / block command text.
    pub primary_offset: u32,
    /// Its length in arena bytes.
    pub primary_length: u32,
    /// Notification body.
    pub secondary_offset: u32,
    /// Its length in arena bytes.
    pub secondary_length: u32,
    /// Whether `exit_code` carries a value — the code-less `D` mark carries none.
    pub has_exit_code: bool,
    /// The command's exit status.
    pub exit_code: i32,
    /// Whether `duration_ms` carries a value.
    pub has_duration: bool,
    /// superd-measured C→D wall clock.
    pub duration_ms: u32,
    /// The validated OSC 9;4 state.
    pub progress_state: u8,
    /// The clamped OSC 9;4 percentage.
    pub progress_percent: u8,
    /// The block's index in the pane's ring.
    pub index: u32,
    /// How many bytes of block output superd has retained.
    pub output_len: u32,
    /// Which prompt the block belongs to.
    pub prompt_ordinal: u32,
    /// Whether the block is closed.
    pub complete: bool,
}

/// One decision the fold took, naming its fact by index.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskTruthVerdict {
    /// Which fact of the ingested array this is about.
    pub fact: u32,
    /// What it is, so the marshaller can switch without indexing back.
    pub kind: u8,
    /// Where its message goes: `0` the output FIFO, `1` every control sender, `2` withheld from
    /// the client and kept by the pane.
    pub route: u8,
}

/// One pane's latched truths, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskPaneTruths {
    /// The state the caller's one lock guards.
    inner: Truths,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_pane_truths_new`] that has not been
/// freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskPaneTruths) -> Option<&'a mut SlopDeskPaneTruths> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// Reads one row as the fact it names, borrowing its text out of `arena`.
///
/// `None` for a kind this build has no name for — the batch stays countable and the member is
/// skipped, never guessed at.
fn fact_of<'arena>(row: &SlopDeskTruthFact, arena: &'arena [u8]) -> Option<Fact<'arena>> {
    let kind = Kind::from_raw(row.kind)?;
    Some(Fact {
        kind,
        primary: text_of(arena, row.primary_offset, row.primary_length),
        secondary: text_of(arena, row.secondary_offset, row.secondary_length),
        scalars: Scalars {
            exit_code: row.has_exit_code.then_some(row.exit_code),
            duration_ms: row.has_duration.then_some(row.duration_ms),
            progress_state: row.progress_state,
            progress_percent: row.progress_percent,
            index: row.index,
            output_len: row.output_len,
            prompt_ordinal: row.prompt_ordinal,
            complete: row.complete,
        },
    })
}

/// One arena span as borrowed text.
///
/// Lossy would mean allocating, which is the one thing this path must not do per event, so a span
/// that is not UTF-8 reads EMPTY instead. The bytes came from `slopdesk-superwire`'s decode, which
/// already answered `String`, so the arm is unreachable in practice and cheap where it is not.
fn text_of(arena: &[u8], offset: u32, length: u32) -> &str {
    std::str::from_utf8(arena_span(arena, offset, length)).unwrap_or_default()
}

/// The verdicts a fold answered, in the caller's record array.
///
/// A MUTATING call cannot be retried, and does not need to be: a fold answers at most one verdict
/// per fact it was handed, so a caller that lends `count` slots always has room.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
unsafe fn spill_verdicts(
    verdicts: &[slopdesk_muxsession::truths::Verdict],
    out: *mut SlopDeskTruthVerdict,
    cap: usize,
) -> usize {
    let rows: Vec<SlopDeskTruthVerdict> = verdicts
        .iter()
        .map(|verdict| {
            SlopDeskTruthVerdict {
                fact: verdict.fact,
                kind: verdict.kind as u8,
                route: verdict.route as u8,
            }
        })
        .collect();
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through to `spill`.
    unsafe { spill(&rows, out, cap) }
}

/// A pane that has said nothing yet.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_truths_new() -> *mut SlopDeskPaneTruths {
    Box::into_raw(Box::new(SlopDeskPaneTruths { inner: Truths::new() }))
}

/// Frees a pane's truths. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_pane_truths_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_free(handle: *mut SlopDeskPaneTruths) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one SNIFFED batch, answering what to do with each member.
///
/// `suppress_child_notifications` is the agent detector's verdict, read by the caller under the
/// same lock: while a pane's agent announces its own edges through the hook feed, its OSC
/// notification duplicates the type-27 the client already banners.
///
/// A dead handle answers `0` — no verdicts, nothing latched.
///
/// # Safety
/// `facts` must describe `count` live rows and `arena` `arena_len` live bytes for the call; `out`
/// must be null or writable for `cap` records. See the module header for the convention.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_ingest_sniffed(
    handle: *mut SlopDeskPaneTruths,
    facts: *const SlopDeskTruthFact,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    reference: f64,
    uptime: f64,
    suppress_child_notifications: bool,
    out: *mut SlopDeskTruthVerdict,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: by the caller's obligation both arrays are live for this call.
    let rows = unsafe { records_of(facts, count) };
    // SAFETY: same obligation, for the byte arena the rows index into.
    let bytes = unsafe { records_of(arena, arena_len) };
    let batch: Vec<Fact<'_>> = rows.iter().filter_map(|row| fact_of(row, bytes)).collect();
    let verdicts =
        truths
            .inner
            .ingest_sniffed(&batch, Stamps { reference, uptime }, suppress_child_notifications);
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { spill_verdicts(&verdicts, out, cap) }
}

/// Folds one BLOCK batch. Every member broadcasts on the control sender.
///
/// # Safety
/// The same obligation as [`slopdesk_pane_truths_ingest_sniffed`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_ingest_blocks(
    handle: *mut SlopDeskPaneTruths,
    facts: *const SlopDeskTruthFact,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    out: *mut SlopDeskTruthVerdict,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: by the caller's obligation both arrays are live for this call.
    let rows = unsafe { records_of(facts, count) };
    // SAFETY: same obligation, for the byte arena the rows index into.
    let bytes = unsafe { records_of(arena, arena_len) };
    let batch: Vec<Fact<'_>> = rows.iter().filter_map(|row| fact_of(row, bytes)).collect();
    let verdicts = truths.inner.ingest_blocks(&batch);
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { spill_verdicts(&verdicts, out, cap) }
}

/// The pane's current window title, through the two-call convention. `0` is a PRESENT empty title,
/// which is what an ownership retirement leaves behind.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes; the handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_title(
    handle: *mut SlopDeskPaneTruths,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { deliver(truths.inner.title().as_bytes(), out, cap) }
}

/// When the title was sniffed, on the reference scale. `false` once retired or never said.
///
/// # Safety
/// `at` must be null or writable for one `f64`; the handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_title_at(
    handle: *mut SlopDeskPaneTruths,
    at: *mut f64,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    let (present, value) = optional(truths.inner.title_at(), 0.0);
    // SAFETY: by the caller's obligation `at` is null or writable for one `f64`.
    unsafe { write_scalar(present, value, at) }
}

/// Records that the agent owning the title has gone: the title and its stamp are dropped, and the
/// sniffer's coalescing anchor is asked to retire.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_retire_title(handle: *mut SlopDeskPaneTruths) {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    if let Some(truths) = unsafe { held(handle) } {
        truths.inner.retire_title();
    }
}

/// TAKES the pending coalescing-reset request, counting it when there was one.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_take_title_coalescing_reset(
    handle: *mut SlopDeskPaneTruths,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    unsafe { held(handle) }.is_some_and(|truths| truths.inner.take_title_coalescing_reset())
}

/// How many times the read loop has been asked to retire the title anchor.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_title_anchor_retirements(
    handle: *mut SlopDeskPaneTruths,
) -> u64 {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    unsafe { held(handle) }.map_or(0, |truths| truths.inner.title_anchor_retirements())
}

/// The freshest OSC 9;4 pair. `false` when the badge is down.
///
/// # Safety
/// `state` and `percent` must each be null or writable for one `u8`; the handle obligation is the
/// module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_progress(
    handle: *mut SlopDeskPaneTruths,
    state: *mut u8,
    percent: *mut u8,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some((latched_state, latched_percent)) = truths.inner.progress() else {
        return false;
    };
    // SAFETY: by the caller's obligation each out-pointer is null or writable for one `u8`.
    unsafe {
        _ = write_scalar(true, latched_state, state);
        _ = write_scalar(true, latched_percent, percent);
    }
    true
}

/// The freshest code-carrying `D` exit status. `false` until the first one.
///
/// # Safety
/// `code` must be null or writable for one `i32`; the handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_last_exit(
    handle: *mut SlopDeskPaneTruths,
    code: *mut i32,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    let (present, value) = optional(truths.inner.last_exit(), 0);
    // SAFETY: by the caller's obligation `code` is null or writable for one `i32`.
    unsafe { write_scalar(present, value, code) }
}

/// The host-measured C→D duration of the last completed command.
///
/// # Safety
/// `duration_ms` must be null or writable for one `u32`; the handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_last_duration(
    handle: *mut SlopDeskPaneTruths,
    duration_ms: *mut u32,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    let (present, value) = optional(truths.inner.last_duration(), 0);
    // SAFETY: by the caller's obligation `duration_ms` is null or writable for one `u32`.
    unsafe { write_scalar(present, value, duration_ms) }
}

/// When the command now running started, on the uptime scale. `false` at a prompt.
///
/// # Safety
/// `since` must be null or writable for one `f64`; the handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_command_running_since(
    handle: *mut SlopDeskPaneTruths,
    since: *mut f64,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    let (present, value) = optional(truths.inner.command_running_since(), 0.0);
    // SAFETY: by the caller's obligation `since` is null or writable for one `f64`.
    unsafe { write_scalar(present, value, since) }
}

/// The command line the pane is running, through the two-call convention. A pane at a prompt
/// answers `0`, which the caller reads as no running command — the same as an empty one.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes; the handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_running_command(
    handle: *mut SlopDeskPaneTruths,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    let running = truths.inner.running_command().unwrap_or_default();
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { deliver(running.as_bytes(), out, cap) }
}

/// Folds one detected status TRANSITION and answers the completion epoch it leaves standing.
///
/// Whether `previous → status` is the SHAPE of a finished turn is `slopdesk-agent`'s answer, asked
/// here against the status this handle already stands at, so the caller never has to carry the
/// previous one back and forth. The `quiet` VETO is the fold's.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_fold_completion(
    handle: *mut SlopDeskPaneTruths,
    status: u8,
    quiet: bool,
) -> u32 {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    let previous = ClaudeStatus::from_urgency(truths.inner.last_completion_status());
    let next = ClaudeStatus::from_urgency(status);
    truths
        .inner
        .fold_completion(status, quiet, mints_finished_turn(previous, next))
}

/// How many turns have finished on this pane.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_completion_epoch(handle: *mut SlopDeskPaneTruths) -> u32 {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    unsafe { held(handle) }.map_or(0, |truths| truths.inner.completion_epoch())
}

/// Folds one termios `ECHO` sample: `-1` no edge, `0` emit echo-off, `1` emit echo-on.
///
/// The dedupe is `slopdesk-terminal`'s and the warm-up gate is the fold's — a freshly connected
/// master reads `ECHO`-cleared for a sample or two before the line discipline settles, and treating
/// that as an edge would latch the client's Secure-Input pill on an ordinary prompt.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_fold_echo(
    handle: *mut SlopDeskPaneTruths,
    echo_on: bool,
) -> i32 {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return -1;
    };
    emitted(truths.inner.fold_echo(echo_on, is_edge))
}

/// RE-ANCHORS the echo detector, then folds `echo_on` against the baseline.
///
/// The reattach re-assert, which is NOT gated by the warm-up. Same answer shape as
/// [`slopdesk_pane_truths_fold_echo`].
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_reanchor_echo(
    handle: *mut SlopDeskPaneTruths,
    echo_on: bool,
) -> i32 {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return -1;
    };
    emitted(truths.inner.reanchor_echo(echo_on, is_edge))
}

/// Opens one batch's cwd derivation: `0` skip, `1` use the batch's OSC-7, `2` prefer the probe.
///
/// The gate MUTATES — a command edge warms this pane up permanently — so the answer is also the
/// record that the warm-up happened.
///
/// # Safety
/// The handle obligation is the module's.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_pane_truths_open_cwd_gate(
    handle: *mut SlopDeskPaneTruths,
    has_osc: bool,
    prompt_edge: bool,
    command_edge: bool,
) -> u8 {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return CwdGate::Skip as u8;
    };
    truths.inner.open_cwd_gate(has_osc, prompt_edge, command_edge) as u8
}

/// Latches an accepted cwd, answering whether it is a change worth publishing.
///
/// # Safety
/// The handle obligation is the module's; `cwd`/`cwd_len` must name a readable span for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_latch_cwd(
    handle: *mut SlopDeskPaneTruths,
    cwd: *const c_uchar,
    cwd_len: usize,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation on `cwd`/`cwd_len` is passed straight through.
    truths.inner.latch_cwd(unsafe { lent(cwd, cwd_len) })
}

/// Seeds the cwd from the SPAWN directory, which an already-latched truth always wins.
///
/// # Safety
/// The handle obligation is the module's; `cwd`/`cwd_len` must name a readable span for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_seed_cwd(
    handle: *mut SlopDeskPaneTruths,
    cwd: *const c_uchar,
    cwd_len: usize,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation on `cwd`/`cwd_len` is passed straight through.
    truths.inner.seed_cwd(unsafe { lent(cwd, cwd_len) })
}

/// Latches a resolved project key against the cwd it was resolved for, answering whether to
/// publish it.
///
/// # Safety
/// The handle obligation is the module's; both spans must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_latch_project_key(
    handle: *mut SlopDeskPaneTruths,
    cwd: *const c_uchar,
    cwd_len: usize,
    key: *const c_uchar,
    key_len: usize,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation on both spans is passed straight through.
    let (cwd, key) = unsafe { (lent(cwd, cwd_len), lent(key, key_len)) };
    truths.inner.latch_project_key(cwd, key)
}

/// The freshest host-observed cwd, through the two-call convention. Empty means none observed.
///
/// # Safety
/// The handle obligation is the module's; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_cwd(
    handle: *mut SlopDeskPaneTruths,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    let cwd = truths.inner.cwd().unwrap_or_default();
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { deliver(cwd.as_bytes(), out, cap) }
}

/// The freshest By-Project key, through the two-call convention. Empty means unresolved.
///
/// # Safety
/// The handle obligation is the module's; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_project_key(
    handle: *mut SlopDeskPaneTruths,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    let key = truths.inner.project_key().unwrap_or_default();
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { deliver(key.as_bytes(), out, cap) }
}

/// Is this pane sectioned under `repo_root`? The type-35 fan-in's latch compare.
///
/// # Safety
/// The handle obligation is the module's; the span must be readable for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_project_key_matches(
    handle: *mut SlopDeskPaneTruths,
    repo_root: *const c_uchar,
    repo_root_len: usize,
) -> bool {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: the caller's obligation on the span is passed straight through.
    truths
        .inner
        .project_key_matches(unsafe { lent(repo_root, repo_root_len) })
}

/// The reattach ladder BEFORE the agent detector's own re-assert, in order.
///
/// A read, so the two-call convention applies — but the answer is at most two bytes, so every
/// caller lends a fixed pair and never sees the retry.
///
/// # Safety
/// The handle obligation is the module's; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_reestablish_head(
    handle: *mut SlopDeskPaneTruths,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { ladder(&truths.inner.reestablish_head(), out, cap) }
}

/// The reattach ladder AFTER that re-assert, in order — the half the title's freshness depends on.
///
/// # Safety
/// The handle obligation is the module's; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_truths_reestablish_tail(
    handle: *mut SlopDeskPaneTruths,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: by the caller's obligation the handle is live and exclusively held for this call.
    let Some(truths) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through.
    unsafe { ladder(&truths.inner.reestablish_tail(), out, cap) }
}

/// One ladder as its discriminant bytes, through the shared delivery convention.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the boundary"
)]
unsafe fn ladder(entries: &[Reassert], out: *mut c_uchar, cap: usize) -> usize {
    let bytes: Vec<u8> = entries.iter().map(|entry| *entry as u8).collect();
    // SAFETY: the caller's obligation on `out`/`cap` is passed straight through to `deliver`.
    unsafe { deliver(&bytes, out, cap) }
}

/// An echo fold's answer as the tri-state the C ABI carries: `-1` nothing to emit, else the state.
const fn emitted(edge: Option<bool>) -> i32 {
    match edge {
        None => -1,
        Some(false) => 0,
        Some(true) => 1,
    }
}

/// Writes one optional scalar through the presence convention, answering whether it was present.
///
/// # Safety
/// `out` must be null or writable for one `T`.
#[expect(
    unsafe_code,
    reason = "writing into the caller's out-parameter is the other half of the boundary"
)]
const unsafe fn write_scalar<T: Copy>(present: bool, value: T, out: *mut T) -> bool {
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `T`.
        unsafe { out.write(value) };
    }
    present
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use slopdesk_muxsession::truths::Route;

    use super::*;

    /// A live handle for one test, freed by the caller.
    fn open() -> *mut SlopDeskPaneTruths {
        slopdesk_pane_truths_new()
    }

    fn close(handle: *mut SlopDeskPaneTruths) {
        unsafe { slopdesk_pane_truths_free(handle) };
    }

    /// One row of `kind` whose primary text is the whole arena.
    const fn row(kind: Kind, length: u32) -> SlopDeskTruthFact {
        SlopDeskTruthFact {
            kind: kind as u8,
            primary_offset: 0,
            primary_length: length,
            secondary_offset: 0,
            secondary_length: 0,
            has_exit_code: false,
            exit_code: 0,
            has_duration: false,
            duration_ms: 0,
            progress_state: 0,
            progress_percent: 0,
            index: 0,
            output_len: 0,
            prompt_ordinal: 0,
            complete: false,
        }
    }

    /// Folds `rows` against `arena` and answers the verdicts written.
    fn sniff(
        handle: *mut SlopDeskPaneTruths,
        rows: &[SlopDeskTruthFact],
        arena: &str,
        suppress: bool,
    ) -> Vec<SlopDeskTruthVerdict> {
        let mut out = vec![SlopDeskTruthVerdict::default(); rows.len()];
        let written = unsafe {
            slopdesk_pane_truths_ingest_sniffed(
                handle,
                rows.as_ptr(),
                rows.len(),
                arena.as_ptr(),
                arena.len(),
                100.0,
                7.0,
                suppress,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        out.truncate(written);
        out
    }

    /// The title the handle stands at, through the two-call convention.
    fn title(handle: *mut SlopDeskPaneTruths) -> String {
        let needed = unsafe { slopdesk_pane_truths_title(handle, std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        let written = unsafe { slopdesk_pane_truths_title(handle, out.as_mut_ptr(), out.len()) };
        out.truncate(written);
        String::from_utf8_lossy(&out).into_owned()
    }

    #[test]
    fn a_title_crosses_and_comes_back_whole() {
        let handle = open();
        let verdicts = sniff(handle, &[row(Kind::Title, 5)], "main.go", false);
        assert_eq!(verdicts.len(), 1);
        assert_eq!(verdicts.first().map(|v| v.route), Some(Route::Fifo as u8));
        assert_eq!(title(handle), "main.");
        let mut at = 0.0;
        assert!(unsafe { slopdesk_pane_truths_title_at(handle, &raw mut at) });
        assert!((at - 100.0).abs() < f64::EPSILON);
        close(handle);
    }

    #[test]
    fn a_kind_this_build_cannot_name_is_skipped_rather_than_guessed_at() {
        let handle = open();
        let mut unknown = row(Kind::Title, 0);
        unknown.kind = 200;
        assert!(sniff(handle, &[unknown], "", false).is_empty());
        close(handle);
    }

    #[test]
    fn a_span_past_the_end_of_the_arena_reads_empty_rather_than_trapping() {
        let handle = open();
        let mut wild = row(Kind::Title, 4096);
        wild.primary_offset = 9000;
        drop(sniff(handle, &[wild], "short", false));
        assert_eq!(title(handle), "");
        close(handle);
    }

    #[test]
    fn a_command_edge_opens_and_closes_through_the_door() {
        let handle = open();
        drop(sniff(handle, &[row(Kind::CommandRunning, 0)], "", false));
        let mut since = 0.0;
        assert!(unsafe { slopdesk_pane_truths_command_running_since(handle, &raw mut since) });
        let mut close_row = row(Kind::CommandIdle, 0);
        close_row.has_exit_code = true;
        close_row.exit_code = 7;
        close_row.has_duration = true;
        close_row.duration_ms = 900;
        drop(sniff(handle, &[close_row], "", false));
        assert!(!unsafe { slopdesk_pane_truths_command_running_since(handle, &raw mut since) });
        let mut code = 0;
        assert!(unsafe { slopdesk_pane_truths_last_exit(handle, &raw mut code) });
        assert_eq!(code, 7);
        let mut duration = 0;
        assert!(unsafe { slopdesk_pane_truths_last_duration(handle, &raw mut duration) });
        assert_eq!(duration, 900);
        close(handle);
    }

    #[test]
    fn a_hook_established_pane_withholds_the_child_notification() {
        let handle = open();
        assert!(sniff(handle, &[row(Kind::Notification, 0)], "", true).is_empty());
        assert_eq!(sniff(handle, &[row(Kind::Notification, 0)], "", false).len(), 1);
        close(handle);
    }

    #[test]
    fn a_block_latches_its_command_line_and_broadcasts() {
        let handle = open();
        let rows = [row(Kind::Block, 10)];
        let arena = "cargo test";
        let mut out = vec![SlopDeskTruthVerdict::default(); 1];
        let written = unsafe {
            slopdesk_pane_truths_ingest_blocks(
                handle,
                rows.as_ptr(),
                rows.len(),
                arena.as_ptr(),
                arena.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 1);
        assert_eq!(out.first().map(|v| v.route), Some(Route::Broadcast as u8));
        let needed = unsafe { slopdesk_pane_truths_running_command(handle, std::ptr::null_mut(), 0) };
        assert_eq!(needed, arena.len());
        close(handle);
    }

    #[test]
    fn the_turn_counter_asks_the_agent_crate_for_the_shape_and_vetoes_the_quiet_ones() {
        let handle = open();
        let working = ClaudeStatus::Working.urgency();
        let idle = ClaudeStatus::Idle.urgency();
        assert_eq!(
            unsafe { slopdesk_pane_truths_fold_completion(handle, working, false) },
            0
        );
        assert_eq!(
            unsafe { slopdesk_pane_truths_fold_completion(handle, idle, false) },
            1
        );
        assert_eq!(
            unsafe { slopdesk_pane_truths_fold_completion(handle, working, false) },
            1
        );
        assert_eq!(
            unsafe { slopdesk_pane_truths_fold_completion(handle, idle, true) },
            1,
            "a bookkeeping correction moves the status without counting a turn",
        );
        assert_eq!(unsafe { slopdesk_pane_truths_completion_epoch(handle) }, 1);
        close(handle);
    }

    #[test]
    fn the_echo_door_warms_up_before_it_will_report_a_no_echo_prompt() {
        let handle = open();
        assert_eq!(unsafe { slopdesk_pane_truths_fold_echo(handle, false) }, -1);
        assert_eq!(unsafe { slopdesk_pane_truths_fold_echo(handle, true) }, -1);
        assert_eq!(unsafe { slopdesk_pane_truths_fold_echo(handle, false) }, 0);
        assert_eq!(
            unsafe { slopdesk_pane_truths_reanchor_echo(handle, false) },
            0,
            "a reattach re-tells a spanning no-echo prompt",
        );
        close(handle);
    }

    #[test]
    fn a_retirement_clears_the_title_and_is_taken_once() {
        let handle = open();
        drop(sniff(handle, &[row(Kind::Title, 6)], "claude", false));
        assert_eq!(title(handle), "claude");
        unsafe { slopdesk_pane_truths_retire_title(handle) };
        assert_eq!(title(handle), "", "an empty title IS the retirement signal");
        let mut at = 0.0;
        assert!(!unsafe { slopdesk_pane_truths_title_at(handle, &raw mut at) });
        assert!(unsafe { slopdesk_pane_truths_take_title_coalescing_reset(handle) });
        assert!(!unsafe { slopdesk_pane_truths_take_title_coalescing_reset(handle) });
        assert_eq!(
            unsafe { slopdesk_pane_truths_title_anchor_retirements(handle) },
            1
        );
        close(handle);
    }

    #[test]
    fn a_null_handle_is_inert_rather_than_a_crash() {
        let null: *mut SlopDeskPaneTruths = std::ptr::null_mut();
        assert!(sniff(null, &[row(Kind::Title, 0)], "", false).is_empty());
        assert_eq!(title(null), "");
        assert!(!unsafe { slopdesk_pane_truths_take_title_coalescing_reset(null) });
        assert_eq!(unsafe { slopdesk_pane_truths_title_anchor_retirements(null) }, 0);
        assert!(!unsafe { slopdesk_pane_truths_progress(null, std::ptr::null_mut(), std::ptr::null_mut()) });
        assert_eq!(unsafe { slopdesk_pane_truths_fold_echo(null, true) }, -1);
        assert_eq!(unsafe { slopdesk_pane_truths_completion_epoch(null) }, 0);
        unsafe { slopdesk_pane_truths_retire_title(null) };
        unsafe { slopdesk_pane_truths_free(null) };
    }

    /// Any two-call text door, read through the convention it documents.
    fn read_back(
        handle: *mut SlopDeskPaneTruths,
        door: unsafe extern "C" fn(*mut SlopDeskPaneTruths, *mut c_uchar, usize) -> usize,
    ) -> String {
        let needed = unsafe { door(handle, std::ptr::null_mut(), 0) };
        let mut out = vec![0_u8; needed];
        let written = unsafe { door(handle, out.as_mut_ptr(), out.len()) };
        out.truncate(written);
        String::from_utf8_lossy(&out).into_owned()
    }

    /// Text crossing the other way: the caller lends a span, the door latches what it accepts.
    fn latch(handle: *mut SlopDeskPaneTruths, cwd: &str) -> bool {
        unsafe { slopdesk_pane_truths_latch_cwd(handle, cwd.as_ptr(), cwd.len()) }
    }

    /// One ladder door's answer as the discriminants it wrote.
    fn ladder_of(handle: *mut SlopDeskPaneTruths, head: bool) -> Vec<u8> {
        let mut out = [0u8; 8];
        let written = if head {
            unsafe { slopdesk_pane_truths_reestablish_head(handle, out.as_mut_ptr(), out.len()) }
        } else {
            unsafe { slopdesk_pane_truths_reestablish_tail(handle, out.as_mut_ptr(), out.len()) }
        };
        // A ladder never writes past the buffer it was lent, so the fallback is unreachable — but
        // an empty answer is the honest one for a door that claimed more than it was given.
        out.get(..written).unwrap_or_default().to_vec()
    }

    #[test]
    fn the_cwd_gate_crosses_as_the_three_answers_it_has() {
        let handle = open();
        assert_eq!(
            unsafe { slopdesk_pane_truths_open_cwd_gate(handle, true, false, false) },
            CwdGate::Skip as u8
        );
        assert_eq!(
            unsafe { slopdesk_pane_truths_open_cwd_gate(handle, true, true, true) },
            CwdGate::PreferProbe as u8
        );
        assert_eq!(
            unsafe { slopdesk_pane_truths_open_cwd_gate(handle, true, false, false) },
            CwdGate::UseOsc as u8
        );
        close(handle);
    }

    #[test]
    fn a_project_truth_crosses_once_and_is_read_back_by_reference() {
        let handle = open();
        assert!(latch(handle, "/a"));
        assert!(!latch(handle, "/a"));
        let key = "/repo";
        assert!(unsafe {
            slopdesk_pane_truths_latch_project_key(handle, "/a".as_ptr(), 2, key.as_ptr(), key.len())
        });
        assert!(unsafe { slopdesk_pane_truths_project_key_matches(handle, key.as_ptr(), key.len()) });
        assert_eq!(read_back(handle, slopdesk_pane_truths_cwd), "/a");
        assert_eq!(read_back(handle, slopdesk_pane_truths_project_key), "/repo");
        assert!(
            !unsafe { slopdesk_pane_truths_seed_cwd(handle, "/spawn".as_ptr(), 6) },
            "the spawn seed never clobbers a real observation"
        );
        close(handle);
    }

    #[test]
    fn the_reattach_ladder_keeps_the_title_behind_the_command_stamp() {
        let handle = open();
        assert!(ladder_of(handle, true).is_empty());
        assert!(ladder_of(handle, false).is_empty());

        drop(sniff(
            handle,
            &[row(Kind::CommandRunning, 0), row(Kind::Title, 6)],
            "claude",
            false,
        ));
        assert!(latch(handle, "/a"));
        assert_eq!(ladder_of(handle, true), vec![Reassert::CommandRunning as u8]);
        assert_eq!(ladder_of(handle, false), vec![
            Reassert::Cwd as u8,
            Reassert::Title as u8
        ]);
        close(handle);
    }

    #[test]
    fn a_null_handle_is_inert_on_every_project_door() {
        let null: *mut SlopDeskPaneTruths = std::ptr::null_mut();
        assert_eq!(
            unsafe { slopdesk_pane_truths_open_cwd_gate(null, true, true, true) },
            CwdGate::Skip as u8
        );
        assert!(!latch(null, "/a"));
        assert!(!unsafe { slopdesk_pane_truths_seed_cwd(null, "/a".as_ptr(), 2) });
        assert!(!unsafe { slopdesk_pane_truths_latch_project_key(null, "/a".as_ptr(), 2, "/r".as_ptr(), 2) });
        assert!(!unsafe { slopdesk_pane_truths_project_key_matches(null, "/r".as_ptr(), 2) });
        assert!(ladder_of(null, true).is_empty());
        assert!(ladder_of(null, false).is_empty());
    }

    #[test]
    fn a_span_that_is_not_utf8_latches_nothing() {
        let handle = open();
        let bytes = [0xFFu8, 0xFE];
        assert!(
            !unsafe { slopdesk_pane_truths_latch_cwd(handle, bytes.as_ptr(), bytes.len()) },
            "an undecodable path is not a truth"
        );
        assert!(!unsafe { slopdesk_pane_truths_latch_cwd(handle, std::ptr::null(), 4) });
        close(handle);
    }
}
