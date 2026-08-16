//! The window-feed snapshot reassembly: chunks of a generation, folded into one list.
//!
//! A HANDLE, for the reason the blob assembler next door is one — the accumulator is a list of
//! records with three strings each, held across chunks, and up to four generations of them at once.
//!
//! The records cross in the shape the control decode already answers in: flat rows with
//! `(offset, length)` pairs into one arena, so no record makes either side own a lifetime. That is
//! deliberate — the near side is holding exactly this shape when a chunk arrives, so a fold costs
//! it the same marshalling an encode already does, and nothing here needs a second record type.

use std::ffi::c_uchar;

use slopdesk_video::video_control::{HostWindowFlags, HostWindowRecord};
use slopdesk_video::window_feed::WindowFeedAssembler;

use crate::video_control::SlopDeskControlRecord;
use crate::{TextArena, arena_text, borrow, deliver, records_of};

/// The reassembler, plus the snapshot its last fold completed and has not yet handed over.
#[derive(Debug)]
pub struct SlopDeskWindowFeed {
    /// The reassembler proper.
    assembler: WindowFeedAssembler,
    /// The completed snapshot awaiting its take, already flattened into the crossing shape.
    completed: Option<(Vec<SlopDeskControlRecord>, Vec<u8>)>,
}

/// The reassembly's own bounds, so neither language writes them down twice.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskWindowFeedBounds {
    /// How many partial generations are kept at once.
    pub max_partial_generations: usize,
    /// The absolute record cap for one assembled generation.
    pub max_records_per_generation: usize,
}

/// What one fold produced.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskWindowFeedFold {
    /// The completed generation.
    pub generation: u32,
    /// How many records it holds, ready for one take.
    pub record_count: usize,
    /// How many arena bytes those records name.
    pub arena_len: usize,
    /// Whether this chunk is the one that finished a generation.
    pub complete: bool,
}

/// The fold that finished nothing.
const NOTHING: SlopDeskWindowFeedFold = SlopDeskWindowFeedFold {
    generation: 0,
    record_count: 0,
    arena_len: 0,
    complete: false,
};

/// What one take copied out, or would need to.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SlopDeskWindowFeedTake {
    /// The record count, whether or not it fit.
    pub record_count: usize,
    /// The arena length, whether or not it fit.
    pub arena_len: usize,
    /// Whether both halves were written. False leaves the snapshot in place for a bigger retry.
    pub copied: bool,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer returned by [`slopdesk_window_feed_new`] that has not been
/// freed, with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskWindowFeed) -> Option<&'a mut SlopDeskWindowFeed> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// One flat row read back as the record it describes.
pub(crate) fn record_of(row: &SlopDeskControlRecord, arena: &[u8]) -> HostWindowRecord {
    HostWindowRecord {
        window_id: row.id,
        width_pt: row.width,
        height_pt: row.height,
        flags: HostWindowFlags::from_bits(row.flags),
        display_index: row.display_index,
        bundle_id: arena_text(arena, row.bundle_offset, row.bundle_length),
        app_name: arena_text(arena, row.name_offset, row.name_length),
        title: arena_text(arena, row.title_offset, row.title_length),
    }
}

/// One record flattened into a row, its three strings interned into `arena`.
pub(crate) fn row_of(record: &HostWindowRecord, arena: &mut TextArena) -> SlopDeskControlRecord {
    let (name_offset, name_length) = arena.intern(record.app_name.as_bytes());
    let (title_offset, title_length) = arena.intern(record.title.as_bytes());
    let (bundle_offset, bundle_length) = arena.intern(record.bundle_id.as_bytes());
    SlopDeskControlRecord {
        id: record.window_id,
        name_offset,
        name_length,
        title_offset,
        title_length,
        bundle_offset,
        bundle_length,
        width: record.width_pt,
        height: record.height_pt,
        x: 0,
        y: 0,
        flags: record.flags.bits(),
        display_index: record.display_index,
        is_main: false,
        is_secure: false,
    }
}

/// The reassembly's bounds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_window_feed_bounds() -> SlopDeskWindowFeedBounds {
    SlopDeskWindowFeedBounds {
        max_partial_generations: WindowFeedAssembler::MAX_PARTIAL_GENERATIONS,
        max_records_per_generation: WindowFeedAssembler::MAX_RECORDS_PER_GENERATION,
    }
}

/// A reassembler with nothing in flight. Never null unless allocation itself failed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_feed_new() -> *mut SlopDeskWindowFeed {
    Box::into_raw(Box::new(SlopDeskWindowFeed {
        assembler: WindowFeedAssembler::new(),
        completed: None,
    }))
}

/// Frees a reassembler. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_window_feed_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_feed_free(handle: *mut SlopDeskWindowFeed) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Folds one decoded chunk in, reporting the snapshot's shape when this chunk finishes its
/// generation. The records stay here until [`slopdesk_window_feed_take`] copies them out.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `records` must point to `record_count` readable
/// rows and `arena` to `arena_len` readable bytes, or be null with a zero count, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_feed_fold(
    handle: *mut SlopDeskWindowFeed,
    generation: u32,
    chunk_index: u8,
    chunk_count: u8,
    records: *const SlopDeskControlRecord,
    record_count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) -> SlopDeskWindowFeedFold {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(state) = (unsafe { held(handle) }) else {
        return NOTHING;
    };
    // SAFETY: as above — the rows and the arena are the caller's for the duration of this call.
    let rows = unsafe { records_of(records, record_count) };
    // SAFETY: as above.
    let pool = unsafe { borrow(arena, arena_len) };
    let folded = state.assembler.fold(
        generation,
        chunk_index,
        chunk_count,
        rows.iter().map(|row| record_of(row, pool)).collect(),
    );
    let Some(snapshot) = folded else {
        state.completed = None;
        return NOTHING;
    };
    let mut pool = TextArena::default();
    let flattened: Vec<_> = snapshot
        .records
        .iter()
        .map(|record| row_of(record, &mut pool))
        .collect();
    let answer = SlopDeskWindowFeedFold {
        generation: snapshot.generation,
        record_count: flattened.len(),
        arena_len: pool.0.len(),
        complete: true,
    };
    state.completed = Some((flattened, pool.0));
    answer
}

/// Copies out the snapshot the last fold completed, and forgets it. A take that did not fit leaves
/// it in place and reports both lengths, so a caller sized wrong retries rather than losing it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation; `records` must either be null or point to
/// `record_cap` writable rows, and `arena` either null or point to `arena_cap` writable bytes, for
/// the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_feed_take(
    handle: *mut SlopDeskWindowFeed,
    records: *mut SlopDeskControlRecord,
    record_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskWindowFeedTake {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskWindowFeedTake {
            record_count: 0,
            arena_len: 0,
            copied: false,
        };
    };
    let Some((rows, pool)) = state.completed.as_ref() else {
        return SlopDeskWindowFeedTake {
            record_count: 0,
            arena_len: 0,
            copied: false,
        };
    };
    let shape = SlopDeskWindowFeedTake {
        record_count: rows.len(),
        arena_len: pool.len(),
        copied: rows.len() <= record_cap && pool.len() <= arena_cap && !records.is_null(),
    };
    if !shape.copied {
        return shape;
    }
    // SAFETY: `rows.len() <= record_cap` was just checked, `records` is non-null and writable for
    // `record_cap` rows by the caller's obligation, and the source is a live Vec that cannot
    // overlap it — it was built inside a previous call and is owned here.
    unsafe { std::ptr::copy_nonoverlapping(rows.as_ptr(), records, rows.len()) };
    // SAFETY: as above, for the arena's bytes.
    unsafe { deliver(pool, arena, arena_cap) };
    state.completed = None;
    shape
}

/// Drops every partial generation, and any snapshot not taken — the round teardown.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_feed_reset(handle: *mut SlopDeskWindowFeed) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(state) = unsafe { held(handle) } {
        state.assembler.reset();
        state.completed = None;
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        unsafe_code,
        reason = "the fixture is built here, and reaching a pointer entry from a test is what the entry is \
                  for"
    )]

    use std::ptr;

    use super::{
        SlopDeskWindowFeed, SlopDeskWindowFeedFold, slopdesk_window_feed_bounds, slopdesk_window_feed_fold,
        slopdesk_window_feed_free, slopdesk_window_feed_new, slopdesk_window_feed_reset,
        slopdesk_window_feed_take,
    };
    use crate::TextArena;
    use crate::video_control::SlopDeskControlRecord;

    /// One chunk of one window, whose app name is the only text it carries.
    fn chunk(
        handle: *mut SlopDeskWindowFeed,
        generation: u32,
        index: u8,
        count: u8,
        id: u32,
        name: &str,
    ) -> SlopDeskWindowFeedFold {
        let mut arena = TextArena::default();
        let (name_offset, name_length) = arena.intern(name.as_bytes());
        let row = SlopDeskControlRecord {
            id,
            name_offset,
            name_length,
            title_offset: 0,
            title_length: 0,
            bundle_offset: 0,
            bundle_length: 0,
            width: 800,
            height: 600,
            x: 0,
            y: 0,
            flags: 0,
            display_index: 0,
            is_main: false,
            is_secure: false,
        };
        unsafe {
            slopdesk_window_feed_fold(
                handle,
                generation,
                index,
                count,
                &raw const row,
                1,
                arena.0.as_ptr(),
                arena.0.len(),
            )
        }
    }

    #[test]
    fn a_split_generation_reassembles_in_chunk_order_and_is_taken_once() {
        let handle = slopdesk_window_feed_new();
        assert!(!chunk(handle, 7, 1, 2, 200, "Second").complete);
        let done = chunk(handle, 7, 0, 2, 100, "First");
        assert!(done.complete);
        assert_eq!(done.generation, 7);
        assert_eq!(done.record_count, 2);

        let shape = unsafe { slopdesk_window_feed_take(handle, ptr::null_mut(), 0, ptr::null_mut(), 0) };
        assert!(!shape.copied, "a caller sized wrong keeps its snapshot");
        assert_eq!(shape.record_count, 2);

        let mut rows = vec![
            SlopDeskControlRecord {
                id: 0,
                name_offset: 0,
                name_length: 0,
                title_offset: 0,
                title_length: 0,
                bundle_offset: 0,
                bundle_length: 0,
                width: 0,
                height: 0,
                x: 0,
                y: 0,
                flags: 0,
                display_index: 0,
                is_main: false,
                is_secure: false,
            };
            shape.record_count
        ];
        let mut arena = vec![0u8; shape.arena_len];
        let copied = unsafe {
            slopdesk_window_feed_take(
                handle,
                rows.as_mut_ptr(),
                rows.len(),
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert!(copied.copied);
        assert_eq!(
            rows.first().map(|row| row.id),
            Some(100),
            "chunk order, not arrival order"
        );
        assert_eq!(rows.get(1).map(|row| row.id), Some(200));
        let first = rows.first().expect("a row");
        let start = first.name_offset as usize;
        let name = arena
            .get(start..start + first.name_length as usize)
            .unwrap_or_default();
        assert_eq!(name, b"First");
        assert!(
            !unsafe {
                slopdesk_window_feed_take(
                    handle,
                    rows.as_mut_ptr(),
                    rows.len(),
                    arena.as_mut_ptr(),
                    arena.len(),
                )
            }
            .copied,
            "and taking it twice answers nothing"
        );
        unsafe { slopdesk_window_feed_free(handle) };
    }

    #[test]
    fn a_hostile_sender_is_bounded_at_every_edge() {
        let bounds = slopdesk_window_feed_bounds();
        assert_eq!(bounds.max_partial_generations, 4);
        assert_eq!(bounds.max_records_per_generation, 512);

        let handle = slopdesk_window_feed_new();
        assert!(!chunk(handle, 1, 0, 2, 10, "a").complete);
        assert!(
            !chunk(handle, 1, 1, 3, 11, "b").complete,
            "chunks disagreeing about the count discard the whole generation"
        );
        assert!(
            !chunk(handle, 1, 1, 2, 11, "b").complete,
            "and the discarded generation does not complete from its survivors"
        );

        assert!(!chunk(handle, 2, 0, 2, 20, "a").complete);
        unsafe { slopdesk_window_feed_reset(handle) };
        assert!(
            !chunk(handle, 2, 1, 2, 21, "b").complete,
            "a reset drops what was in flight"
        );
        unsafe { slopdesk_window_feed_free(handle) };
    }
}
