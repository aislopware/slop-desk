//! The per-pane command blocks: one record per command the shell ran, as the client knows them.
//!
//! [`slopdesk_terminal::blocks`] holds a ring, a bookmark set, a jump-to-failed walk and an
//! output-request registry. What crosses here is all of it except the two things that cannot: the
//! CALLBACKS a resolved request fans out to, which are Swift closures, and the SF Symbol and label
//! strings a row displays, which belong to the surface. A second copy of a UI string is drift, not
//! a port.
//!
//! ## Why one handle for the ring and the registry
//!
//! Because a reset touches both, in an order that matters: the ring's blocks die and every
//! in-flight request has to be answered "unavailable" so no continuation is left parked. Two
//! handles would put that pairing back on the Swift side, which is the coupling the port exists to
//! move. [`slopdesk_block_store_reset`] does both and answers the stranded indices.
//!
//! ## Why the pure parts are separate entries
//!
//! [`slopdesk_block_status`], [`slopdesk_block_duration_label`] and
//! [`slopdesk_block_adjacent_failed`] take fields, not a handle: `is_failed` is read per row per
//! render, and the jump walk runs over lists a caller built itself — the navigator's newest-first
//! projection in production, a hand-written list in a test. None of the three needs the store, and
//! making them need it would mean a test could not ask the question without building one.
//!
//! ## Why the projection is one call
//!
//! [`slopdesk_block_store_project`] writes every row and the single arena their command texts live
//! in, in one pass. The caller is an observed array rebuilt whole after any mutation, so 64 rows
//! read one at a time would be 64 crossings for one answer.

use core::ffi::c_uchar;

use slopdesk_terminal::blocks::{
    BlockNavigatorFilter, BlockRing, BlockStatus, CommandBlock, OutputRequest, OutputRequests,
    adjacent_failed,
};

use crate::{borrow, deliver, records_of};

/// No OSC 133 `D` yet — the spinner state.
pub const SLOPDESK_BLOCK_STATUS_RUNNING: u32 = 0;
/// Finished at exit 0, or with no code reported at all.
pub const SLOPDESK_BLOCK_STATUS_SUCCEEDED: u32 = 1;
/// Finished at a non-zero code, which the record carries.
pub const SLOPDESK_BLOCK_STATUS_FAILED: u32 = 2;

/// Every block held.
pub const SLOPDESK_BLOCK_FILTER_ALL: u32 = 0;
/// Only finished non-zero exits — jump-to-error.
pub const SLOPDESK_BLOCK_FILTER_FAILED: u32 = 1;
/// Only the starred set.
pub const SLOPDESK_BLOCK_FILTER_BOOKMARKED: u32 = 2;

/// One block's wire fields — everything but the command text.
///
/// The text is absent on purpose: this record is passed BY VALUE for an upsert and read back by
/// value from a projection, and a string cannot travel in either without an arena. So the text
/// travels beside it, as a `(ptr, len)` going in and an `(offset, length)` into the projection's
/// arena coming out.
///
/// Both optional numbers carry a presence flag rather than a sentinel. `exit_code` of 0 is success
/// and no reported code is ALSO success, but they are different facts; `duration_ms` of `None` is
/// what tells a still-running block from an interrupted one that was stamped as it closed.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SlopDeskBlockFields {
    /// The 0-based index in the host segmenter's lifetime — the upsert key and the request key.
    pub index: u32,
    /// Whether `exit_code` means anything.
    pub has_exit_code: bool,
    /// The command's `$?`; read only when `has_exit_code`.
    pub exit_code: i32,
    /// Whether `duration_ms` means anything.
    pub has_duration_ms: bool,
    /// Host-measured wall-clock milliseconds; read only when `has_duration_ms`.
    pub duration_ms: u32,
    /// Set once the matching OSC 133 `D` arrived.
    pub complete: bool,
    /// How many output bytes the host currently holds.
    pub output_len: u32,
    /// The 1-based prompt-cycle ordinal a jump lands on. `0` means unknown.
    pub prompt_ordinal: u32,
}

impl SlopDeskBlockFields {
    /// The fields of a held block, for the projection.
    const fn of(block: &CommandBlock) -> Self {
        let (has_exit_code, exit_code) = match block.exit_code {
            Some(code) => (true, code),
            None => (false, 0),
        };
        let (has_duration_ms, duration_ms) = match block.duration_ms {
            Some(ms) => (true, ms),
            None => (false, 0),
        };
        Self {
            index: block.index,
            has_exit_code,
            exit_code,
            has_duration_ms,
            duration_ms,
            complete: block.complete,
            output_len: block.output_len,
            prompt_ordinal: block.prompt_ordinal,
        }
    }

    /// A block carrying these fields and `text`.
    fn block(self, text: &str) -> CommandBlock {
        CommandBlock {
            index: self.index,
            command_text: text.to_owned(),
            exit_code: self.has_exit_code.then_some(self.exit_code),
            duration_ms: self.has_duration_ms.then_some(self.duration_ms),
            complete: self.complete,
            output_len: self.output_len,
            prompt_ordinal: self.prompt_ordinal,
        }
    }
}

/// One projected row: the fields, plus where its command text sits in the projection's arena.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SlopDeskBlockRow {
    /// The block's wire fields.
    pub fields: SlopDeskBlockFields,
    /// Where the command text starts in the arena.
    pub command_offset: usize,
    /// How long the command text is, in bytes.
    pub command_length: usize,
}

/// A block's derived status, as a kind and the code the failed arm carries.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskBlockStatus {
    /// One of the `SLOPDESK_BLOCK_STATUS_*` values.
    pub kind: u32,
    /// The non-zero exit code; meaningful only under `SLOPDESK_BLOCK_STATUS_FAILED`.
    pub code: i32,
}

/// What a projection or a reset produced.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskBlockCounts {
    /// Rows the store holds, oldest first.
    pub row_count: usize,
    /// Bytes of command text across all of them.
    pub arena_length: usize,
}

impl SlopDeskBlockCounts {
    /// Nothing held — the answer to a null handle.
    const EMPTY: Self = Self {
        row_count: 0,
        arena_length: 0,
    };
}

/// Where an upsert landed.
///
/// A known index REPLACES its slot with exactly the block the caller passed, so a caller mirroring
/// the ring already holds the new row and needs only the slot to write it into. A new index inserts
/// and may evict, which moves every other row, so `replaced` being false means "read the ring
/// again".
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskBlockUpsert {
    /// True when the index was already held and its slot was replaced in place.
    pub replaced: bool,
    /// The slot it now occupies, counted oldest-first. Meaningful only when `replaced`.
    pub position: usize,
}

/// What [`slopdesk_block_store_request`] decided.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskBlockRequest {
    /// Whether this call must put a request on the wire. `false` means it rode along on one that
    /// was already in flight, and no frame should be sent.
    pub send: bool,
    /// The generation this request is under — the token a timeout has to quote back.
    pub generation: u64,
}

impl SlopDeskBlockRequest {
    /// The answer to a null handle: nothing was armed, so nothing should be sent.
    const NONE: Self = Self {
        send: false,
        generation: 0,
    };
}

/// An optional `u64`, as a value and a presence flag.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskBlockGeneration {
    /// Whether `value` means anything — `false` when nothing is in flight for the index.
    pub has_value: bool,
    /// The live generation; read only when `has_value`.
    pub value: u64,
}

impl SlopDeskBlockGeneration {
    /// Nothing in flight.
    const NONE: Self = Self {
        has_value: false,
        value: 0,
    };
}

/// An optional timestamp, as a value and a presence flag.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskBlockFirstSeen {
    /// Whether `value` means anything — `false` for an index never seen, or since evicted.
    pub has_value: bool,
    /// Whatever clock the caller stamped the introducing upsert with.
    pub value: i64,
}

impl SlopDeskBlockFirstSeen {
    /// Never seen.
    const NONE: Self = Self {
        has_value: false,
        value: 0,
    };
}

/// The opaque handle: the ring and the request registry that resets with it.
#[derive(Debug, Default)]
pub struct SlopDeskBlockStore {
    ring: BlockRing,
    requests: OutputRequests,
    /// What the last reset stranded, parked until [`slopdesk_block_store_take_stranded`] reads it.
    ///
    /// A slot rather than a `(out, cap)` answer on the reset itself, because a reset is
    /// DESTRUCTIVE: the "call once to size, once to fill" shape the rest of this door uses
    /// would drain the pending set on the sizing call and hand back an empty list on the second
    /// — every parked continuation stranded silently, which is the exact failure the stranded
    /// list exists to prevent. Same shape and same reason as the input box's render slot.
    stranded: Vec<u32>,
}

/// The filter a `SLOPDESK_BLOCK_FILTER_*` code names.
///
/// Anything else is [`All`](BlockNavigatorFilter::All), matching the crate's own token parsing: a
/// filter written by a newer build should show every block, not none of them.
const fn filter_of(code: u32) -> BlockNavigatorFilter {
    match code {
        SLOPDESK_BLOCK_FILTER_FAILED => BlockNavigatorFilter::Failed,
        SLOPDESK_BLOCK_FILTER_BOOKMARKED => BlockNavigatorFilter::Bookmarked,
        _ => BlockNavigatorFilter::All,
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_block_store_new`] that has not been freed, and
/// no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskBlockStore) -> Option<&'a mut SlopDeskBlockStore> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one store per pane, driven from the main actor.
    Some(unsafe { &mut *handle })
}

// MARK: - The pure parts (no handle)

/// The status a block's fields add up to.
///
/// A block INTERRUPTED by a new prompt — a nested shell or an `ssh` emitting its own OSC 133
/// `A`/`B` with no `D` — is closed on the host with `complete == false` but a stamped duration, so
/// "has a duration" counts as finished or that row spins `running…` forever.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_status(fields: SlopDeskBlockFields) -> SlopDeskBlockStatus {
    match fields.block("").status() {
        BlockStatus::Running => {
            SlopDeskBlockStatus {
                kind: SLOPDESK_BLOCK_STATUS_RUNNING,
                code: 0,
            }
        },
        BlockStatus::Succeeded => {
            SlopDeskBlockStatus {
                kind: SLOPDESK_BLOCK_STATUS_SUCCEEDED,
                code: 0,
            }
        },
        BlockStatus::Failed(code) => {
            SlopDeskBlockStatus {
                kind: SLOPDESK_BLOCK_STATUS_FAILED,
                code,
            }
        },
    }
}

/// Writes the compact duration label — `"340ms"`, `"1.3s"` — and answers the bytes NEEDED.
///
/// Answers `0` when the block is still running, which is a different answer from an empty label:
/// there is no label to show at all. Seconds carry one decimal so a long command's chip cannot
/// jitter in width as it ticks.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_duration_label(
    fields: SlopDeskBlockFields,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Some(label) = fields.block("").duration_label() else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and the label
    // was allocated inside this call so it cannot overlap it.
    unsafe { deliver(label.as_bytes(), out, cap) }
}

/// Finds the next or previous FAILED block from a cursor, over a NEWEST-FIRST list.
///
/// Takes the list rather than a handle because the walk is over whatever the caller projected — the
/// navigator's filtered rows in production, a hand-built list in a test — and never wraps. Writes
/// the found block's index to `out_index` and answers `true`; answers `false` and writes nothing
/// when there is no failure in that direction.
///
/// # Safety
/// `(newest_first, count)` must be null or describe live records for the call, and `out_index` must
/// be null or writable for one `uint32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_adjacent_failed(
    newest_first: *const SlopDeskBlockFields,
    count: usize,
    has_from: bool,
    from_index: u32,
    forward: bool,
    out_index: *mut u32,
) -> bool {
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let fields = unsafe { records_of(newest_first, count) };
    let blocks: Vec<CommandBlock> = fields.iter().map(|entry| entry.block("")).collect();
    let borrowed: Vec<&CommandBlock> = blocks.iter().collect();
    let Some(found) = adjacent_failed(&borrowed, has_from.then_some(from_index), forward) else {
        return false;
    };
    if out_index.is_null() {
        return true;
    }
    // SAFETY: non-null and writable for one `u32` by the caller's obligation.
    unsafe { out_index.write(found.index) };
    true
}

// MARK: - The store

/// Builds an empty store: no blocks, no bookmarks, nothing in flight.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_new() -> *mut SlopDeskBlockStore {
    Box::into_raw(Box::new(SlopDeskBlockStore::default()))
}

/// Frees a store. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_block_store_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_block_store_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_free(handle: *mut SlopDeskBlockStore) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Upserts a block: a new index inserts in index order, a known index replaces in place.
///
/// `now` is the caller's clock, stamped only on the upsert that INTRODUCES an index — a later
/// running→complete update does not move it. Past the ring's bound the oldest block goes, taking
/// its stamp with it.
///
/// Answers WHERE it landed, which is what lets a mirroring caller write one slot instead of reading
/// the whole ring back: the common upsert by far is a running command's output length growing, and
/// the block that replaces its slot is byte for byte the one the caller just passed in.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(text, text_len)` must describe live memory for
/// the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_upsert(
    handle: *mut SlopDeskBlockStore,
    fields: SlopDeskBlockFields,
    text: *const c_uchar,
    text_len: usize,
    now: i64,
) -> SlopDeskBlockUpsert {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(store) = (unsafe { held(handle) }) else {
        return SlopDeskBlockUpsert {
            replaced: false,
            position: 0,
        };
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let command = String::from_utf8_lossy(unsafe { borrow(text, text_len) }).into_owned();
    let held_at = store
        .ring
        .blocks()
        .iter()
        .position(|held| held.index == fields.index);
    store.ring.upsert(fields.block(&command), now);
    held_at.map_or(
        SlopDeskBlockUpsert {
            replaced: false,
            position: 0,
        },
        |position| {
            SlopDeskBlockUpsert {
                replaced: true,
                position,
            }
        },
    )
}

/// Writes every row, oldest first, and the one arena their command texts live in.
///
/// Answers the counts NEEDED either way and writes NOTHING unless both buffers fit, so a caller
/// that guessed too small gets the two sizes to lend rather than a half-filled array. One call
/// rather than a row at a time because the reader is an observable array rebuilt whole after any
/// mutation.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `rows` must be null or writable for `row_cap`
/// records, and `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_project(
    handle: *mut SlopDeskBlockStore,
    rows: *mut SlopDeskBlockRow,
    row_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskBlockCounts {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return SlopDeskBlockCounts::EMPTY;
    };
    let held_blocks = store.ring.blocks();
    let counts = SlopDeskBlockCounts {
        row_count: held_blocks.len(),
        arena_length: held_blocks.iter().map(|block| block.command_text.len()).sum(),
    };
    if rows.is_null() || arena.is_null() || counts.row_count > row_cap || counts.arena_length > arena_cap {
        return counts;
    }
    // Straight into the caller's arena rather than through a staging `Vec`: this runs on every
    // upsert, and a whole extra copy of every command line is not free at 64 of them.
    let mut offset = 0_usize;
    for (position, block) in held_blocks.iter().enumerate() {
        let bytes = block.command_text.as_bytes();
        let row = SlopDeskBlockRow {
            fields: SlopDeskBlockFields::of(block),
            command_offset: offset,
            command_length: bytes.len(),
        };
        // SAFETY: `position < row_count <= row_cap` was checked above, and `rows` is writable for
        // `row_cap` records by the caller's obligation.
        unsafe { rows.add(position).write(row) };
        // SAFETY: the offsets run over one pass of the same blocks the length was summed from, so
        // `offset + bytes.len() <= arena_length <= arena_cap`, and `arena` is writable for that many
        // bytes by the caller's obligation. The source is owned by the store, which the caller may
        // not alias.
        unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr(), arena.add(offset), bytes.len()) };
        offset += bytes.len();
    }
    counts
}

/// When `index` was FIRST seen, on whatever clock the introducing upsert was stamped with.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_first_seen(
    handle: *mut SlopDeskBlockStore,
    index: u32,
) -> SlopDeskBlockFirstSeen {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return SlopDeskBlockFirstSeen::NONE;
    };
    store
        .ring
        .first_seen(index)
        .map_or(SlopDeskBlockFirstSeen::NONE, |value| {
            SlopDeskBlockFirstSeen {
                has_value: true,
                value,
            }
        })
}

/// Writes the block INDICES matching `filter`, newest-first, and answers how many there are.
///
/// Indices rather than rows because the caller already holds the projection and only needs to know
/// which of it to show — and because the filter's rule (a running block is never failed, bookmarked
/// means the starred set) is the thing that must not exist twice.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap`
/// `uint32_t`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_filtered(
    handle: *mut SlopDeskBlockStore,
    filter: u32,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return 0;
    };
    let matched: Vec<u32> = store
        .ring
        .filtered(filter_of(filter))
        .into_iter()
        .map(|block| block.index)
        .collect();
    if out.is_null() || matched.len() > cap {
        return matched.len();
    }
    for (position, index) in matched.iter().enumerate() {
        // SAFETY: `position < matched.len() <= cap`, and `out` is writable for `cap` by the
        // caller's obligation.
        unsafe { out.add(position).write(*index) };
    }
    matched.len()
}

/// Whether `index` is bookmarked.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_is_bookmarked(
    handle: *mut SlopDeskBlockStore,
    index: u32,
) -> bool {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.is_some_and(|store| store.ring.is_bookmarked(index))
}

/// Toggles `index`'s bookmark. Two toggles return to where they started; adding past the cap evicts
/// the oldest-inserted, so the bound is a bound and not a refusal.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_toggle_bookmark(handle: *mut SlopDeskBlockStore, index: u32) {
    // SAFETY: the caller's obligation, as above.
    if let Some(store) = unsafe { held(handle) } {
        store.ring.toggle_bookmark(index);
    }
}

/// SEEDS the bookmark set from persistence.
///
/// A restore, not an edit, so the caller should not persist the result back. Duplicates collapse
/// and an over-long set is trimmed to the first `MAX_BOOKMARKS` in the caller's order, which is
/// also the order future eviction will use.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `(indices, count)` must describe live records
/// for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_set_bookmarks(
    handle: *mut SlopDeskBlockStore,
    indices: *const u32,
    count: usize,
) {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return;
    };
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let seed = unsafe { records_of(indices, count) };
    store.ring.set_bookmarks(seed);
}

/// Writes the bookmarked indices and answers how many there are.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap`
/// `uint32_t`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_bookmarks(
    handle: *mut SlopDeskBlockStore,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return 0;
    };
    let marked: Vec<u32> = store.ring.bookmarks().iter().copied().collect();
    if out.is_null() || marked.len() > cap {
        return marked.len();
    }
    for (position, index) in marked.iter().enumerate() {
        // SAFETY: `position < marked.len() <= cap`, and `out` is writable for `cap` by the caller's
        // obligation.
        unsafe { out.add(position).write(*index) };
    }
    marked.len()
}

// MARK: - Output requests

/// Opens or joins a request for `index`, and says which happened.
///
/// `send == false` means a request for this block was already in flight and this one rode along on
/// it, so nothing goes on the wire. Either way the answer carries the generation, which a timeout
/// has to quote back for it to fire.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_request(
    handle: *mut SlopDeskBlockStore,
    index: u32,
) -> SlopDeskBlockRequest {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return SlopDeskBlockRequest::NONE;
    };
    match store.requests.request(index) {
        OutputRequest::Send(generation) => {
            SlopDeskBlockRequest {
                send: true,
                generation,
            }
        },
        OutputRequest::Coalesced(generation) => {
            SlopDeskBlockRequest {
                send: false,
                generation,
            }
        },
    }
}

/// Whether a request for `index` is still in flight.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_is_pending(
    handle: *mut SlopDeskBlockStore,
    index: u32,
) -> bool {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.is_some_and(|store| store.requests.is_pending(index))
}

/// The generation a live request for `index` armed, or nothing when none is in flight.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_current_generation(
    handle: *mut SlopDeskBlockStore,
    index: u32,
) -> SlopDeskBlockGeneration {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return SlopDeskBlockGeneration::NONE;
    };
    store
        .requests
        .current_generation(index)
        .map_or(SlopDeskBlockGeneration::NONE, |value| {
            SlopDeskBlockGeneration {
                has_value: true,
                value,
            }
        })
}

/// Closes the slot for `index` because a reply arrived. `false` when nothing was pending — a stray
/// or late reply is dropped, not an error, and the caller should fan out to nobody.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_resolve(handle: *mut SlopDeskBlockStore, index: u32) -> bool {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.is_some_and(|store| store.requests.resolve(index))
}

/// Closes the slot for `index` because a timer fired, and says whether it should have.
///
/// Under `has_generation` the timer fires ONLY if its token is still the live one, which is what
/// keeps a stale timer from resolving a LATER request for the same block as unavailable. Without
/// it, whatever is pending times out.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_time_out(
    handle: *mut SlopDeskBlockStore,
    index: u32,
    has_generation: bool,
    generation: u64,
) -> bool {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.is_some_and(|store| {
        store
            .requests
            .time_out(index, has_generation.then_some(generation))
    })
}

/// Clears the blocks, their stamps and the bookmarks, abandons every in-flight request, and PARKS
/// the stranded indices for [`slopdesk_block_store_take_stranded`].
///
/// The two halves are one call because a reset that dropped the blocks without answering the
/// requests would leave a continuation parked forever, and the pairing belongs on this side of the
/// boundary. Request GENERATIONS survive: a slot reopened after a reset must still get a strictly
/// newer token than any timer left over from before it.
///
/// Answers the stranded count and writes nothing, because the reset is destructive and a caller
/// asked to call once for a size and again for the contents would find the second call empty.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_reset(handle: *mut SlopDeskBlockStore) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return 0;
    };
    store.ring.reset();
    store.stranded = store.requests.reset();
    store.stranded.len()
}

/// Copies the indices the last reset stranded into the caller's buffer.
///
/// Returns how many the slot holds — the same number the reset answered — and writes nothing when
/// that exceeds `cap`. Reading does NOT clear the slot: a caller that got its size wrong retries
/// with a bigger buffer rather than losing the list, and losing it means a parked continuation
/// nobody will ever answer.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap`
/// `uint32_t`s.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_block_store_take_stranded(
    handle: *mut SlopDeskBlockStore,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(store) = (unsafe { held(handle) }) else {
        return 0;
    };
    if out.is_null() || store.stranded.len() > cap {
        return store.stranded.len();
    }
    for (position, index) in store.stranded.iter().enumerate() {
        // SAFETY: `position < stranded.len() <= cap`, and `out` is writable for `cap` by the
        // caller's obligation.
        unsafe { out.add(position).write(*index) };
    }
    store.stranded.len()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_BLOCK_FILTER_BOOKMARKED, SLOPDESK_BLOCK_FILTER_FAILED, SLOPDESK_BLOCK_STATUS_FAILED,
        SLOPDESK_BLOCK_STATUS_RUNNING, SLOPDESK_BLOCK_STATUS_SUCCEEDED, SlopDeskBlockCounts,
        SlopDeskBlockFields, SlopDeskBlockRow, SlopDeskBlockStore, SlopDeskBlockUpsert,
        slopdesk_block_adjacent_failed, slopdesk_block_duration_label, slopdesk_block_status,
        slopdesk_block_store_bookmarks, slopdesk_block_store_current_generation,
        slopdesk_block_store_filtered, slopdesk_block_store_first_seen, slopdesk_block_store_free,
        slopdesk_block_store_is_bookmarked, slopdesk_block_store_is_pending, slopdesk_block_store_new,
        slopdesk_block_store_project, slopdesk_block_store_request, slopdesk_block_store_reset,
        slopdesk_block_store_resolve, slopdesk_block_store_set_bookmarks, slopdesk_block_store_take_stranded,
        slopdesk_block_store_time_out, slopdesk_block_store_toggle_bookmark, slopdesk_block_store_upsert,
    };

    /// Fields for a block that finished at `exit`, or is still running when `exit` is `None` and
    /// `complete` is false.
    fn fields(index: u32, exit: Option<i32>, complete: bool) -> SlopDeskBlockFields {
        SlopDeskBlockFields {
            index,
            has_exit_code: exit.is_some(),
            exit_code: exit.unwrap_or(0),
            has_duration_ms: complete,
            duration_ms: 10,
            complete,
            output_len: 0,
            prompt_ordinal: index + 1,
        }
    }

    /// Upserts through the door, the way the Swift face does.
    fn upsert(
        handle: *mut SlopDeskBlockStore,
        index: u32,
        exit: Option<i32>,
        complete: bool,
        now: i64,
    ) -> SlopDeskBlockUpsert {
        let text = format!("cmd{index}");
        unsafe {
            slopdesk_block_store_upsert(
                handle,
                fields(index, exit, complete),
                text.as_ptr(),
                text.len(),
                now,
            )
        }
    }

    /// The sizes a projection would need, asked the way §4 says: lend nothing and read the answer.
    fn counts(handle: *mut SlopDeskBlockStore) -> SlopDeskBlockCounts {
        unsafe { slopdesk_block_store_project(handle, std::ptr::null_mut(), 0, std::ptr::null_mut(), 0) }
    }

    /// Projects the whole store the way the observable array is rebuilt: size, then fill.
    fn project(handle: *mut SlopDeskBlockStore) -> Vec<(u32, String)> {
        let counts = counts(handle);
        let mut rows = vec![SlopDeskBlockRow::default(); counts.row_count];
        let mut arena = vec![0_u8; counts.arena_length];
        let written = unsafe {
            slopdesk_block_store_project(
                handle,
                rows.as_mut_ptr(),
                rows.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(written, counts, "the projection changed size between two calls");
        rows.iter()
            .map(|row| {
                (
                    row.fields.index,
                    // `size_t` pair, like `link_detect`'s — saturating is the exact bridge to the
                    // `u32` the shared reader takes. See `crate::arena_span`.
                    crate::arena_text(
                        &arena,
                        crate::saturating_u32(row.command_offset),
                        crate::saturating_u32(row.command_length),
                    ),
                )
            })
            .collect()
    }

    #[test]
    fn a_new_index_inserts_in_order_and_a_known_one_replaces_in_place() {
        let handle = unsafe { slopdesk_block_store_new() };
        upsert(handle, 2, None, false, 100);
        upsert(handle, 0, Some(0), true, 101);
        upsert(handle, 1, Some(3), true, 102);
        assert_eq!(
            project(handle),
            vec![
                (0, "cmd0".to_owned()),
                (1, "cmd1".to_owned()),
                (2, "cmd2".to_owned())
            ],
            "a late lower index still lands in its ordered slot",
        );
        assert_eq!(
            upsert(handle, 2, Some(0), true, 999),
            SlopDeskBlockUpsert {
                replaced: true,
                position: 2
            },
            "a known index names the slot it replaced, so a mirror can write just that one",
        );
        assert_eq!(
            unsafe { slopdesk_block_store_first_seen(handle, 2) }.value,
            100,
            "an update does not move the first-seen stamp",
        );
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn an_insert_says_so_and_an_eviction_still_says_so() {
        let handle = unsafe { slopdesk_block_store_new() };
        assert_eq!(
            upsert(handle, 7, None, false, 1),
            SlopDeskBlockUpsert {
                replaced: false,
                position: 0
            },
            "a new index moved the ring, so the mirror has to read it back",
        );
        for index in 0..70 {
            let landed = upsert(handle, index, Some(0), true, i64::from(index));
            assert_eq!(
                landed.replaced,
                index == 7,
                "only index 7 was already held; the rest inserted",
            );
        }
        assert!(
            !upsert(handle, 200, Some(0), true, 200).replaced,
            "an insert that evicts is still an insert",
        );
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn the_ring_evicts_the_oldest_and_drops_its_stamp() {
        let handle = unsafe { slopdesk_block_store_new() };
        for index in 0..70 {
            upsert(handle, index, Some(0), true, i64::from(index));
        }
        let counts = counts(handle);
        assert_eq!(counts.row_count, 64, "the ring is bounded at the host's own cap");
        assert!(
            !unsafe { slopdesk_block_store_first_seen(handle, 0) }.has_value,
            "the evicted block's stamp went with it",
        );
        assert!(unsafe { slopdesk_block_store_first_seen(handle, 69) }.has_value);
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn the_filters_read_one_rule_and_answer_newest_first() {
        let handle = unsafe { slopdesk_block_store_new() };
        upsert(handle, 0, Some(0), true, 0);
        upsert(handle, 1, Some(2), true, 1);
        upsert(handle, 2, None, false, 2);
        upsert(handle, 3, Some(1), true, 3);
        unsafe { slopdesk_block_store_toggle_bookmark(handle, 0) };
        unsafe { slopdesk_block_store_toggle_bookmark(handle, 3) };

        let filtered = |filter| {
            let count = unsafe { slopdesk_block_store_filtered(handle, filter, std::ptr::null_mut(), 0) };
            let mut out = vec![0_u32; count];
            let written =
                unsafe { slopdesk_block_store_filtered(handle, filter, out.as_mut_ptr(), out.len()) };
            assert_eq!(written, count);
            out
        };
        assert_eq!(
            filtered(SLOPDESK_BLOCK_FILTER_FAILED),
            vec![3, 1],
            "running is never failed"
        );
        assert_eq!(filtered(SLOPDESK_BLOCK_FILTER_BOOKMARKED), vec![3, 0]);
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn a_bookmark_toggles_back_and_a_seed_does_not_read_as_an_edit() {
        let handle = unsafe { slopdesk_block_store_new() };
        unsafe { slopdesk_block_store_toggle_bookmark(handle, 7) };
        assert!(unsafe { slopdesk_block_store_is_bookmarked(handle, 7) });
        unsafe { slopdesk_block_store_toggle_bookmark(handle, 7) };
        assert!(!unsafe { slopdesk_block_store_is_bookmarked(handle, 7) });

        let seed = [4_u32, 4, 9];
        unsafe { slopdesk_block_store_set_bookmarks(handle, seed.as_ptr(), seed.len()) };
        let count = unsafe { slopdesk_block_store_bookmarks(handle, std::ptr::null_mut(), 0) };
        let mut out = vec![0_u32; count];
        unsafe { slopdesk_block_store_bookmarks(handle, out.as_mut_ptr(), out.len()) };
        assert_eq!(out, vec![4, 9], "duplicates collapse");
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn a_second_request_coalesces_and_a_stale_timer_cannot_kill_a_later_one() {
        let handle = unsafe { slopdesk_block_store_new() };
        let first = unsafe { slopdesk_block_store_request(handle, 5) };
        assert!(first.send, "nothing was in flight, so this one goes on the wire");
        let rider = unsafe { slopdesk_block_store_request(handle, 5) };
        assert!(
            !rider.send,
            "a second click rides along rather than sending again"
        );
        assert_eq!(rider.generation, first.generation);
        assert!(unsafe { slopdesk_block_store_is_pending(handle, 5) });
        assert_eq!(
            unsafe { slopdesk_block_store_current_generation(handle, 5) }.value,
            first.generation,
        );

        assert!(unsafe { slopdesk_block_store_resolve(handle, 5) });
        assert!(
            !unsafe { slopdesk_block_store_resolve(handle, 5) },
            "a stray late reply is dropped, not an error",
        );

        let second = unsafe { slopdesk_block_store_request(handle, 5) };
        assert!(
            second.generation > first.generation,
            "the token only ever advances"
        );
        assert!(
            !unsafe { slopdesk_block_store_time_out(handle, 5, true, first.generation) },
            "the first request's parked timer quotes a stale token and is ignored",
        );
        assert!(unsafe { slopdesk_block_store_time_out(handle, 5, true, second.generation) });
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn a_reset_clears_the_ring_and_hands_back_everything_it_stranded() {
        let handle = unsafe { slopdesk_block_store_new() };
        upsert(handle, 1, Some(0), true, 0);
        unsafe { slopdesk_block_store_toggle_bookmark(handle, 1) };
        let armed = unsafe { slopdesk_block_store_request(handle, 1) };
        unsafe { slopdesk_block_store_request(handle, 2) };

        let count = unsafe { slopdesk_block_store_reset(handle) };
        let mut stranded = vec![0_u32; count];
        let written =
            unsafe { slopdesk_block_store_take_stranded(handle, stranded.as_mut_ptr(), stranded.len()) };
        assert_eq!(written, count, "the slot answered a size it then would not fill");
        assert_eq!(
            stranded,
            vec![1, 2],
            "every parked continuation is named so none is left waiting",
        );
        assert_eq!(
            unsafe { slopdesk_block_store_take_stranded(handle, std::ptr::null_mut(), 0) },
            count,
            "reading the slot does not empty it — a caller that lent too little must be able to retry",
        );
        assert_eq!(counts(handle).row_count, 0);
        assert!(!unsafe { slopdesk_block_store_is_bookmarked(handle, 1) });

        let reopened = unsafe { slopdesk_block_store_request(handle, 1) };
        assert!(
            reopened.generation > armed.generation,
            "a slot reopened after a reset outranks any timer left from before it",
        );
        unsafe { slopdesk_block_store_free(handle) };
    }

    #[test]
    fn the_status_and_the_label_are_the_crates_own_rules() {
        assert_eq!(
            unsafe { slopdesk_block_status(fields(0, None, false)) }.kind,
            SLOPDESK_BLOCK_STATUS_RUNNING,
        );
        assert_eq!(
            unsafe { slopdesk_block_status(fields(0, None, true)) }.kind,
            SLOPDESK_BLOCK_STATUS_SUCCEEDED,
            "no reported code is a success",
        );
        let failed = unsafe { slopdesk_block_status(fields(0, Some(137), true)) };
        assert_eq!(failed.kind, SLOPDESK_BLOCK_STATUS_FAILED);
        assert_eq!(failed.code, 137);

        // An INTERRUPTED block: never marked complete, but stamped as it closed.
        let mut interrupted = fields(0, Some(130), false);
        interrupted.has_duration_ms = true;
        assert_eq!(
            unsafe { slopdesk_block_status(interrupted) }.kind,
            SLOPDESK_BLOCK_STATUS_FAILED,
            "a stamped duration counts as finished, or the row spins forever",
        );

        let label = |ms: u32| {
            let mut held = fields(0, Some(0), true);
            held.duration_ms = ms;
            let needed = unsafe { slopdesk_block_duration_label(held, std::ptr::null_mut(), 0) };
            let mut out = vec![0_u8; needed];
            unsafe { slopdesk_block_duration_label(held, out.as_mut_ptr(), out.len()) };
            String::from_utf8_lossy(&out).into_owned()
        };
        assert_eq!(label(340), "340ms");
        assert_eq!(label(1349), "1.3s");
        // Half-to-EVEN, and 1.25 is exactly representable, so this is "1.2s" and not "1.3s" — which
        // is also what Swift's `%.1f` answers. The two were differentialled over every millisecond
        // from 0 to 5000 when this port landed and agreed on all 5001, so the label is the same
        // string on both sides and not merely the same rule.
        assert_eq!(label(1250), "1.2s");
        assert_eq!(
            unsafe { slopdesk_block_duration_label(fields(0, None, false), std::ptr::null_mut(), 0) },
            0,
            "a running block has no label at all, which is not an empty one",
        );
    }

    #[test]
    fn the_jump_walks_past_the_cursor_and_stops_at_the_ends() {
        // Newest-first, as the navigator projects it: 3 failed, 2 running, 1 failed, 0 ok.
        let newest_first = [
            fields(3, Some(1), true),
            fields(2, None, false),
            fields(1, Some(2), true),
            fields(0, Some(0), true),
        ];
        let walk = |from: Option<u32>, forward: bool| {
            let mut found = 0_u32;
            let hit = unsafe {
                slopdesk_block_adjacent_failed(
                    newest_first.as_ptr(),
                    newest_first.len(),
                    from.is_some(),
                    from.unwrap_or(0),
                    forward,
                    &raw mut found,
                )
            };
            hit.then_some(found)
        };
        assert_eq!(
            walk(None, true),
            Some(3),
            "a first forward jump lands on the newest failure"
        );
        assert_eq!(
            walk(Some(3), true),
            Some(1),
            "a cursor ON a failure advances past it"
        );
        assert_eq!(
            walk(Some(1), true),
            None,
            "the walk stops at the end rather than wrapping"
        );
        assert_eq!(walk(Some(1), false), Some(3));
        assert_eq!(
            walk(None, false),
            Some(1),
            "backward from the far end finds the oldest failure"
        );
    }

    #[test]
    fn a_null_handle_answers_rather_than_faults() {
        assert_eq!(counts(std::ptr::null_mut()).row_count, 0);
        assert!(!unsafe { slopdesk_block_store_request(std::ptr::null_mut(), 0) }.send);
        assert!(!unsafe { slopdesk_block_store_is_pending(std::ptr::null_mut(), 0) });
        assert!(!unsafe { slopdesk_block_store_first_seen(std::ptr::null_mut(), 0) }.has_value);
        assert_eq!(unsafe { slopdesk_block_store_reset(std::ptr::null_mut()) }, 0);
        unsafe { slopdesk_block_store_free(std::ptr::null_mut()) };
    }
}
