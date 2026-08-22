//! The host's side of the window feed: what to list, how to pack it, who to push it to, and when.
//!
//! `rust/slopdesk-video`'s `window_feed_host` owns all four. This is the door.
//!
//! ## What crosses as what
//! The cache and the subscriber table are HANDLES — the cache holds a record list AND its encoded
//! chunks, up to sixty-four rows of three strings each plus the datagrams they pack into, and the
//! near side reads one reply out of it per subscribe. The push policy is two optional timestamps
//! and folds BY VALUE, because the caller holds it and reads it whole every tick. The inclusion
//! verdict, the snapshot build and the chunk packing are functions of their inputs and cross as
//! calls.
//!
//! ## The records cross in the shape the control codec already answers in
//! Flat rows naming `(offset, length)` spans in one arena — [`crate::video_control`]'s
//! `SlopDeskControlRecord`, the codebase's one flat record type. The near side is already holding
//! exactly that shape when it encodes a snapshot, so nothing here needs a second one, and no record
//! makes either side own a lifetime.
//!
//! ## Why the pure builders answer twice
//! A snapshot and a chunk list are variable-length products with strings in them, so they follow
//! §4's two-step: the call reports the shape it would write, and a second call with a big enough
//! buffer writes it. They are pure, so recomputing costs a pass over at most sixty-four rows, four
//! times a second at the very most — cheaper than the scratch allocation a handle would need to
//! hold an answer nobody asked for yet.

use std::ffi::c_uchar;

use slopdesk_video::video_control::HostWindowRecord;
use slopdesk_video::window_feed_host::{
    APP_NAME_MAX_BYTES, BUNDLE_ID_MAX_BYTES, BURST_TICK, BURST_WINDOW, FOCUS_COALESCE, FeedChange, IDLE_TICK,
    MAX_RECORDS, MIN_DIMENSION_PT, PushPolicyState, TITLE_COALESCE, WindowFeedCache, WindowFeedPushPolicy,
    WindowFeedSourceWindow, WindowFeedSubscriberTable, classify_change, encoded_chunks, includes_window,
    snapshot_records,
};

use crate::host_state::SlopDeskByteSpan;
use crate::video_control::SlopDeskControlRecord;
use crate::window_feed::{record_of, row_of};
use crate::{TextArena, arena_text, borrow, records_of};

/// Nothing changed between the two record sets.
pub const SLOPDESK_FEED_CHANGE_NONE: u32 = 0;
/// The window set, a visibility bit or a size moved — fold now and open the burst.
pub const SLOPDESK_FEED_CHANGE_STRUCTURAL: u32 = 1;
/// Only volatile fields moved, and no title was among them.
pub const SLOPDESK_FEED_CHANGE_VOLATILE: u32 = 2;
/// Only volatile fields moved, and a title WAS among them — the slower coalesce gate.
pub const SLOPDESK_FEED_CHANGE_VOLATILE_TITLE: u32 = 3;

/// The feed's fixed numbers, so neither language writes them down twice.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFeedConstants {
    /// The post-filter record cap for one snapshot.
    pub max_records: usize,
    /// The wire cap for a record's bundle identifier.
    pub bundle_id_max_bytes: usize,
    /// The wire cap for a record's app name.
    pub app_name_max_bytes: usize,
    /// Windows smaller than this in either axis are indicators, not streamable windows.
    pub min_dimension_pt: i32,
    /// The idle tick, in seconds.
    pub idle_tick: f64,
    /// The tick inside a structural burst, in seconds.
    pub burst_tick: f64,
    /// How long a structural change keeps the differ in burst, in seconds.
    pub burst_window: f64,
    /// The coalesce gate for a title-only change, in seconds.
    pub title_coalesce: f64,
    /// The coalesce gate for a focus- or order-only change, in seconds.
    pub focus_coalesce: f64,
}

/// One raw enumerated window, as the glue observed it. Its three strings name spans in the arena
/// the caller lends alongside the array.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskFeedSource {
    /// The window server's id.
    pub window_id: u32,
    /// The owning app's name — the inclusion key. An empty span means absent.
    pub owner: SlopDeskByteSpan,
    /// The owning app's bundle identifier — the icon cache key.
    pub bundle: SlopDeskByteSpan,
    /// The window title.
    pub title: SlopDeskByteSpan,
    /// The window layer. Only layer 0 is listable.
    pub layer: i32,
    /// Width in points.
    pub width_pt: i32,
    /// Height in points.
    pub height_pt: i32,
    /// Ordinal of the display the window sits on; 0 when unknown or single.
    pub display_index: u8,
    /// Whether the window server calls it on-screen.
    pub is_on_screen: bool,
    /// Whether the owning app is hidden.
    pub is_app_hidden: bool,
    /// Whether the owning app is frontmost.
    pub is_frontmost_app: bool,
    /// Whether accessibility reports it minimized.
    pub is_minimized: bool,
    /// Whether the accessibility probe has seen it in its app's window list.
    pub is_ax_listed: bool,
}

/// The shape of a variable-length answer, so a caller knows what to lend.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskFeedShape {
    /// How many entries the answer has — records, or chunks.
    pub count: usize,
    /// How many bytes their arena takes.
    pub arena_len: usize,
}

/// The differ's tick and fold policy, folded by value.
///
/// Two optional timestamps, and an absent one is spelled with its own flag rather than a sentinel:
/// a caller could legitimately pass a negative `now`, and a sentinel would then read as a live
/// burst.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskFeedPushPolicy {
    /// When the structural burst ends, meaningful only under `has_burst`.
    pub burst_until: f64,
    /// When the last volatile fold happened, meaningful only under `has_volatile_fold`.
    pub last_volatile_fold: f64,
    /// Whether a structural change has ever opened a burst.
    pub has_burst: bool,
    /// Whether a volatile change has ever folded.
    pub has_volatile_fold: bool,
}

/// The snapshot cache: the records, their encoded chunks, and the staleness stamp.
#[derive(Debug)]
pub struct SlopDeskFeedCache {
    /// The cache proper.
    inner: WindowFeedCache,
}

/// The subscriber table.
#[derive(Debug)]
pub struct SlopDeskFeedSubscribers {
    /// The table proper.
    inner: WindowFeedSubscriberTable,
}

/// Turns a caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null, or a pointer from this module's matching `new` that has not been freed,
/// with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a, T>(handle: *mut T) -> Option<&'a mut T> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// One lent span of the caller's arena as the string it holds. An empty span IS the empty string
/// here — every one of these three fields is legitimately empty on real desktops.
fn span(arena: &[u8], run: SlopDeskByteSpan) -> String {
    arena_text(arena, run.offset, run.length)
}

/// One lent row as the source window it describes.
fn source_of(row: &SlopDeskFeedSource, arena: &[u8]) -> WindowFeedSourceWindow {
    WindowFeedSourceWindow {
        window_id: row.window_id,
        owner_name: span(arena, row.owner),
        bundle_id: span(arena, row.bundle),
        layer: row.layer,
        is_on_screen: row.is_on_screen,
        title: span(arena, row.title),
        width_pt: row.width_pt,
        height_pt: row.height_pt,
        display_index: row.display_index,
        is_app_hidden: row.is_app_hidden,
        is_frontmost_app: row.is_frontmost_app,
        is_minimized: row.is_minimized,
        is_ax_listed: row.is_ax_listed,
    }
}

/// The change a code names. An unknown code reads as no change, which folds nothing.
const fn change_of(code: u32) -> FeedChange {
    match code {
        SLOPDESK_FEED_CHANGE_STRUCTURAL => FeedChange::Structural,
        SLOPDESK_FEED_CHANGE_VOLATILE => FeedChange::VolatileOnly { title_changed: false },
        SLOPDESK_FEED_CHANGE_VOLATILE_TITLE => FeedChange::VolatileOnly { title_changed: true },
        _ => FeedChange::None,
    }
}

/// The code a change crosses as.
const fn change_code(change: FeedChange) -> u32 {
    match change {
        FeedChange::None => SLOPDESK_FEED_CHANGE_NONE,
        FeedChange::Structural => SLOPDESK_FEED_CHANGE_STRUCTURAL,
        FeedChange::VolatileOnly { title_changed: false } => SLOPDESK_FEED_CHANGE_VOLATILE,
        FeedChange::VolatileOnly { title_changed: true } => SLOPDESK_FEED_CHANGE_VOLATILE_TITLE,
    }
}

/// Writes a record list out as rows and an arena, if both fit, and reports the shape either way.
///
/// # Safety
/// `rows` must be null or writable for `row_cap` records, and `arena` null or writable for
/// `arena_cap` bytes, for the whole call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffers is the other half of the boundary"
)]
unsafe fn spill_records(
    records: &[HostWindowRecord],
    rows: *mut SlopDeskControlRecord,
    row_cap: usize,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskFeedShape {
    let mut pool = TextArena::default();
    let flat: Vec<SlopDeskControlRecord> = records.iter().map(|record| row_of(record, &mut pool)).collect();
    let bytes = &pool.0;
    let shape = SlopDeskFeedShape {
        count: flat.len(),
        arena_len: bytes.len(),
    };
    if flat.len() > row_cap || bytes.len() > arena_cap || (rows.is_null() && !flat.is_empty()) {
        return shape;
    }
    if !flat.is_empty() {
        // SAFETY: the counts were just checked against the caller's caps, and both sources are Rust
        // allocations made inside this call, so neither can overlap the caller's buffers.
        unsafe { std::ptr::copy_nonoverlapping(flat.as_ptr(), rows, flat.len()) };
    }
    if !bytes.is_empty() && !arena.is_null() {
        // SAFETY: as above, for the arena.
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), arena, bytes.len()) };
    }
    shape
}

/// Writes a payload list out as spans and one concatenated buffer, if both fit.
///
/// # Safety
/// `spans` must be null or writable for `span_cap` spans, and `bytes` null or writable for
/// `bytes_cap` bytes, for the whole call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffers is the other half of the boundary"
)]
unsafe fn spill_payloads(
    payloads: &[Vec<u8>],
    spans: *mut SlopDeskByteSpan,
    span_cap: usize,
    bytes: *mut c_uchar,
    bytes_cap: usize,
) -> SlopDeskFeedShape {
    let mut runs = Vec::with_capacity(payloads.len());
    let mut pool: Vec<u8> = Vec::new();
    for payload in payloads {
        let offset = u32::try_from(pool.len()).unwrap_or(u32::MAX);
        let length = u32::try_from(payload.len()).unwrap_or(u32::MAX);
        runs.push(SlopDeskByteSpan { offset, length });
        pool.extend_from_slice(payload);
    }
    let shape = SlopDeskFeedShape {
        count: runs.len(),
        arena_len: pool.len(),
    };
    if runs.len() > span_cap || pool.len() > bytes_cap || (spans.is_null() && !runs.is_empty()) {
        return shape;
    }
    if !runs.is_empty() {
        // SAFETY: the counts were just checked against the caller's caps, and both sources are Rust
        // allocations made inside this call, so neither can overlap the caller's buffers.
        unsafe { std::ptr::copy_nonoverlapping(runs.as_ptr(), spans, runs.len()) };
    }
    if !pool.is_empty() && !bytes.is_null() {
        // SAFETY: as above, for the concatenated payloads.
        unsafe { std::ptr::copy_nonoverlapping(pool.as_ptr(), bytes, pool.len()) };
    }
    shape
}

/// Borrows a lent record list back into the records it describes.
///
/// # Safety
/// `rows` must be null or describe `count` live entries, and `arena` null or `arena_len` live
/// bytes, for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's arrays IS the boundary this module documents"
)]
unsafe fn records_from(
    rows: *const SlopDeskControlRecord,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) -> Vec<HostWindowRecord> {
    // SAFETY: the caller's obligation above is this function's, restated on the two helpers.
    let (flat, pool) = unsafe { (records_of(rows, count), borrow(arena, arena_len)) };
    flat.iter().map(|row| record_of(row, pool)).collect()
}

/// The feed's fixed numbers.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_feed_constants() -> SlopDeskFeedConstants {
    SlopDeskFeedConstants {
        max_records: MAX_RECORDS,
        bundle_id_max_bytes: BUNDLE_ID_MAX_BYTES,
        app_name_max_bytes: APP_NAME_MAX_BYTES,
        min_dimension_pt: MIN_DIMENSION_PT,
        idle_tick: IDLE_TICK,
        burst_tick: BURST_TICK,
        burst_window: BURST_WINDOW,
        title_coalesce: TITLE_COALESCE,
        focus_coalesce: FOCUS_COALESCE,
    }
}

/// The ONE inclusion verdict, shared by the picker and the feed.
///
/// # Safety
/// Each pointer must be null, or point to its stated number of live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_includes(
    owner: *const c_uchar,
    owner_len: usize,
    title: *const c_uchar,
    title_len: usize,
    width_pt: i32,
    height_pt: i32,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    let (owner_bytes, title_bytes) = unsafe { (borrow(owner, owner_len), borrow(title, title_len)) };
    includes_window(
        &String::from_utf8_lossy(owner_bytes),
        &String::from_utf8_lossy(title_bytes),
        width_pt,
        height_pt,
    )
}

/// Maps raw enumerated windows to one snapshot's wire records, preserving z-order.
///
/// Reports the shape it would write and writes it when both buffers fit, so a caller sizes with one
/// call and fills with a second.
///
/// # Safety
/// `sources`/`in_arena` must describe live input for the call, and `out_rows`/`out_arena` must be
/// null or writable for their stated capacities.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_snapshot(
    sources: *const SlopDeskFeedSource,
    source_count: usize,
    in_arena: *const c_uchar,
    in_arena_len: usize,
    out_rows: *mut SlopDeskControlRecord,
    row_cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskFeedShape {
    // SAFETY: the caller's obligation above is this function's, restated on the two helpers.
    let (rows, pool) = unsafe { (records_of(sources, source_count), borrow(in_arena, in_arena_len)) };
    let windows: Vec<WindowFeedSourceWindow> = rows.iter().map(|row| source_of(row, pool)).collect();
    // SAFETY: the caller's obligation on the output buffers is restated on `spill_records`.
    unsafe {
        spill_records(
            &snapshot_records(&windows),
            out_rows,
            row_cap,
            out_arena,
            arena_cap,
        )
    }
}

/// Packs one snapshot's records into ready-to-send chunk payloads, in the same two-step shape.
///
/// # Safety
/// The input pointers must describe live data for the call, and the output pointers must be null or
/// writable for their stated capacities.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_chunks(
    generation: u32,
    rows: *const SlopDeskControlRecord,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    out_spans: *mut SlopDeskByteSpan,
    span_cap: usize,
    out_bytes: *mut c_uchar,
    bytes_cap: usize,
) -> SlopDeskFeedShape {
    // SAFETY: the caller's obligation above is this function's, restated on `records_from`.
    let records = unsafe { records_from(rows, count, arena, arena_len) };
    // SAFETY: the caller's obligation on the output buffers is restated on `spill_payloads`.
    unsafe {
        spill_payloads(
            &encoded_chunks(generation, &records),
            out_spans,
            span_cap,
            out_bytes,
            bytes_cap,
        )
    }
}

/// A cache that has never built anything, answering subscribes for `ttl` seconds per build.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_feed_cache_new(ttl: f64) -> *mut SlopDeskFeedCache {
    Box::into_raw(Box::new(SlopDeskFeedCache {
        inner: WindowFeedCache::new(ttl),
    }))
}

/// Frees a cache. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_feed_cache_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_cache_free(handle: *mut SlopDeskFeedCache) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// The last published generation, zero when nothing has been built.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_cache_generation(handle: *mut SlopDeskFeedCache) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.generation())
}

/// Whether the caller must enumerate and fold before answering.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_cache_needs_rebuild(handle: *mut SlopDeskFeedCache, now: f64) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.needs_rebuild(now))
}

/// Folds a freshly built record set, bumping the generation only when it actually differs.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and the input pointers must describe live data.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_cache_fold(
    handle: *mut SlopDeskFeedCache,
    rows: *const SlopDeskControlRecord,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    now: f64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `records_from`.
    let fresh = unsafe { records_from(rows, count, arena, arena_len) };
    // SAFETY: as above, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.fold(fresh, now);
    }
}

/// The cached records, in the two-step shape.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and the output pointers must be null or writable
/// for their stated capacities.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_cache_records(
    handle: *mut SlopDeskFeedCache,
    out_rows: *mut SlopDeskControlRecord,
    row_cap: usize,
    out_arena: *mut c_uchar,
    arena_cap: usize,
) -> SlopDeskFeedShape {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskFeedShape::default();
    };
    // SAFETY: the caller's obligation on the output buffers is restated on `spill_records`.
    unsafe { spill_records(state.inner.records(), out_rows, row_cap, out_arena, arena_cap) }
}

/// The datagrams answering one subscribe carrying the client's known generation.
///
/// `out_is_snapshot` says whether they are a full snapshot, which the sender duplicates on the
/// wire; it is written on every call that has a handle, shape or no shape.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `out_is_snapshot` must be null or writable for one
/// `bool`, and the output buffers must be null or writable for their stated capacities.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_cache_reply(
    handle: *mut SlopDeskFeedCache,
    known_generation: u32,
    out_is_snapshot: *mut bool,
    out_spans: *mut SlopDeskByteSpan,
    span_cap: usize,
    out_bytes: *mut c_uchar,
    bytes_cap: usize,
) -> SlopDeskFeedShape {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return SlopDeskFeedShape::default();
    };
    let reply = state.inner.reply(known_generation);
    if !out_is_snapshot.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one `bool`.
        unsafe { out_is_snapshot.write(reply.is_snapshot) };
    }
    // SAFETY: the caller's obligation on the output buffers is restated on `spill_payloads`.
    unsafe { spill_payloads(&reply.payloads, out_spans, span_cap, out_bytes, bytes_cap) }
}

/// A subscriber table with nobody in it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_feed_subscribers_new(ttl: f64, capacity: usize) -> *mut SlopDeskFeedSubscribers {
    Box::into_raw(Box::new(SlopDeskFeedSubscribers {
        inner: WindowFeedSubscriberTable::new(ttl, capacity),
    }))
}

/// Frees a subscriber table. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_feed_subscribers_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_subscribers_free(handle: *mut SlopDeskFeedSubscribers) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// How many entries the table holds, expired ones included until they are reaped.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_subscribers_count(handle: *mut SlopDeskFeedSubscribers) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(0, |state| state.inner.len())
}

/// Records a renewal. False means the table was full of FRESH subscribers and this id was refused.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_subscribers_renew(
    handle: *mut SlopDeskFeedSubscribers,
    channel_id: u32,
    now: f64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.renew(channel_id, now))
}

/// Drops every expired subscriber and reports their ids, so the caller can retire those lanes.
///
/// A reap CONSUMES what it reports, so the caller lends at the table's own size rather than sizing
/// with a first call that would empty it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for `cap` ids.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_subscribers_reap(
    handle: *mut SlopDeskFeedSubscribers,
    now: f64,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`/`cap` is restated on `spill`.
    unsafe { crate::spill(&state.inner.reap_expired(now), out, cap) }
}

/// The live subscriber ids — the push targets.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `out` must be null or writable for `cap` ids.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_subscribers_live(
    handle: *mut SlopDeskFeedSubscribers,
    now: f64,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`/`cap` is restated on `spill`.
    unsafe { crate::spill(&state.inner.subscribers(now), out, cap) }
}

/// Classifies the difference between two record sets.
///
/// # Safety
/// Both record arrays and both arenas must describe live data for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_classify(
    old_rows: *const SlopDeskControlRecord,
    old_count: usize,
    old_arena: *const c_uchar,
    old_arena_len: usize,
    new_rows: *const SlopDeskControlRecord,
    new_count: usize,
    new_arena: *const c_uchar,
    new_arena_len: usize,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `records_from`.
    let (old, new) = unsafe {
        (
            records_from(old_rows, old_count, old_arena, old_arena_len),
            records_from(new_rows, new_count, new_arena, new_arena_len),
        )
    };
    change_code(classify_change(&old, &new))
}

/// A policy that has seen no change yet.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_feed_policy_new() -> SlopDeskFeedPushPolicy {
    SlopDeskFeedPushPolicy {
        burst_until: 0.0,
        last_volatile_fold: 0.0,
        has_burst: false,
        has_volatile_fold: false,
    }
}

/// Whether this change may fold into the cache NOW, bumping the generation and so pushing.
///
/// # Safety
/// `policy` must be null or point to one live, writable `SlopDeskFeedPushPolicy` for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_feed_should_fold(
    policy: *mut SlopDeskFeedPushPolicy,
    change: u32,
    now: f64,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(flat) = (unsafe { held(policy) }) else {
        return false;
    };
    let mut inner = inner_policy(*flat);
    let folds = inner.should_fold(change_of(change), now);
    *flat = flat_policy(inner);
    folds
}

/// The differ's next tick interval — four times the idle rate inside a structural burst.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_feed_tick_interval(policy: SlopDeskFeedPushPolicy, now: f64) -> f64 {
    if policy.has_burst && now < policy.burst_until {
        BURST_TICK
    } else {
        IDLE_TICK
    }
}

/// The crate's policy, restored from the flat one the caller holds.
const fn inner_policy(flat: SlopDeskFeedPushPolicy) -> WindowFeedPushPolicy {
    WindowFeedPushPolicy::restored(PushPolicyState {
        burst_until: if flat.has_burst {
            Some(flat.burst_until)
        } else {
            None
        },
        last_volatile_fold: if flat.has_volatile_fold {
            Some(flat.last_volatile_fold)
        } else {
            None
        },
    })
}

/// The flat policy the caller carries away.
const fn flat_policy(inner: WindowFeedPushPolicy) -> SlopDeskFeedPushPolicy {
    let state = inner.state();
    SlopDeskFeedPushPolicy {
        burst_until: match state.burst_until {
            Some(until) => until,
            None => 0.0,
        },
        last_volatile_fold: match state.last_volatile_fold {
            Some(folded) => folded,
            None => 0.0,
        },
        has_burst: state.burst_until.is_some(),
        has_volatile_fold: state.last_volatile_fold.is_some(),
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{
        SLOPDESK_FEED_CHANGE_NONE, SLOPDESK_FEED_CHANGE_STRUCTURAL, SlopDeskFeedSource,
        slopdesk_feed_cache_fold, slopdesk_feed_cache_free, slopdesk_feed_cache_generation,
        slopdesk_feed_cache_needs_rebuild, slopdesk_feed_cache_new, slopdesk_feed_cache_reply,
        slopdesk_feed_classify, slopdesk_feed_constants, slopdesk_feed_includes, slopdesk_feed_policy_new,
        slopdesk_feed_should_fold, slopdesk_feed_snapshot, slopdesk_feed_subscribers_free,
        slopdesk_feed_subscribers_new, slopdesk_feed_subscribers_reap, slopdesk_feed_subscribers_renew,
        slopdesk_feed_tick_interval,
    };
    use crate::host_state::SlopDeskByteSpan;
    use crate::video_control::SlopDeskControlRecord;

    /// One arena holding an owner name, a bundle id and a title, and the spans naming them.
    fn arena() -> (Vec<u8>, [SlopDeskByteSpan; 3]) {
        let mut pool = Vec::new();
        let mut span = |text: &str| {
            let run = SlopDeskByteSpan {
                offset: u32::try_from(pool.len()).unwrap_or_default(),
                length: u32::try_from(text.len()).unwrap_or_default(),
            };
            pool.extend_from_slice(text.as_bytes());
            run
        };
        let runs = [span("Ghostty"), span("com.mitchellh.ghostty"), span("make")];
        (pool, runs)
    }

    fn source(runs: [SlopDeskByteSpan; 3]) -> SlopDeskFeedSource {
        SlopDeskFeedSource {
            window_id: 41,
            owner: runs[0],
            bundle: runs[1],
            title: runs[2],
            layer: 0,
            width_pt: 900,
            height_pt: 600,
            is_on_screen: true,
            is_frontmost_app: true,
            ..SlopDeskFeedSource::default()
        }
    }

    #[test]
    fn a_tiny_indicator_is_excluded_and_a_real_window_is_not() {
        let owner = b"Ghostty";
        let dock = b"Dock";
        unsafe {
            assert!(slopdesk_feed_includes(
                owner.as_ptr(),
                owner.len(),
                std::ptr::null(),
                0,
                900,
                600
            ));
            assert!(!slopdesk_feed_includes(
                owner.as_ptr(),
                owner.len(),
                std::ptr::null(),
                0,
                40,
                600
            ));
            assert!(!slopdesk_feed_includes(
                dock.as_ptr(),
                dock.len(),
                std::ptr::null(),
                0,
                900,
                600
            ));
        }
    }

    #[test]
    fn a_snapshot_reports_its_shape_then_fills_the_buffers_it_was_told_to_lend() {
        let (pool, runs) = arena();
        let sources = [source(runs)];
        let shape = unsafe {
            slopdesk_feed_snapshot(
                sources.as_ptr(),
                sources.len(),
                pool.as_ptr(),
                pool.len(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(shape.count, 1);
        assert!(shape.arena_len > 0);
        let mut rows = vec![SlopDeskControlRecord::default(); shape.count];
        let mut out = vec![0_u8; shape.arena_len];
        let filled = unsafe {
            slopdesk_feed_snapshot(
                sources.as_ptr(),
                sources.len(),
                pool.as_ptr(),
                pool.len(),
                rows.as_mut_ptr(),
                rows.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(filled, shape);
        assert_eq!(rows.first().map(|row| (row.id, row.width)), Some((41, 900)));
    }

    #[test]
    fn the_cache_answers_a_current_client_short_and_a_stale_one_whole() {
        let (pool, runs) = arena();
        let sources = [source(runs)];
        let shape = unsafe {
            slopdesk_feed_snapshot(
                sources.as_ptr(),
                sources.len(),
                pool.as_ptr(),
                pool.len(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            )
        };
        let mut rows = vec![SlopDeskControlRecord::default(); shape.count];
        let mut built = vec![0_u8; shape.arena_len];
        let cache = slopdesk_feed_cache_new(1.0);
        unsafe {
            slopdesk_feed_snapshot(
                sources.as_ptr(),
                sources.len(),
                pool.as_ptr(),
                pool.len(),
                rows.as_mut_ptr(),
                rows.len(),
                built.as_mut_ptr(),
                built.len(),
            );
            assert!(slopdesk_feed_cache_needs_rebuild(cache, 0.0));
            slopdesk_feed_cache_fold(cache, rows.as_ptr(), rows.len(), built.as_ptr(), built.len(), 0.0);
            let generation = slopdesk_feed_cache_generation(cache);
            assert_eq!(generation, 1);
            assert!(!slopdesk_feed_cache_needs_rebuild(cache, 0.5));
            let mut is_snapshot = true;
            let current = slopdesk_feed_cache_reply(
                cache,
                generation,
                &raw mut is_snapshot,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            );
            assert!(!is_snapshot);
            assert_eq!(current.count, 1, "the five-byte you-are-current reply");
            let stale = slopdesk_feed_cache_reply(
                cache,
                0,
                &raw mut is_snapshot,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
            );
            assert!(is_snapshot);
            assert_eq!(stale.count, 1);
            // An identical fold refreshes the stamp without bumping the generation.
            slopdesk_feed_cache_fold(cache, rows.as_ptr(), rows.len(), built.as_ptr(), built.len(), 2.0);
            assert_eq!(slopdesk_feed_cache_generation(cache), generation);
            slopdesk_feed_cache_free(cache);
        }
    }

    #[test]
    fn an_empty_pair_of_record_sets_is_no_change_at_all() {
        let code = unsafe {
            slopdesk_feed_classify(
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
            )
        };
        assert_eq!(code, SLOPDESK_FEED_CHANGE_NONE);
    }

    #[test]
    fn a_structural_change_opens_the_burst_and_the_burst_closes_on_its_own() {
        let law = slopdesk_feed_constants();
        let mut policy = slopdesk_feed_policy_new();
        assert!((slopdesk_feed_tick_interval(policy, 100.0) - law.idle_tick).abs() < 1e-12);
        unsafe {
            assert!(slopdesk_feed_should_fold(
                &raw mut policy,
                SLOPDESK_FEED_CHANGE_STRUCTURAL,
                100.0
            ));
        }
        assert!((slopdesk_feed_tick_interval(policy, 100.1) - law.burst_tick).abs() < 1e-12);
        assert!((slopdesk_feed_tick_interval(policy, 103.1) - law.idle_tick).abs() < 1e-12);
    }

    #[test]
    fn three_missed_renewals_reap_the_silent_subscriber() {
        let table = slopdesk_feed_subscribers_new(6.0, 8);
        let mut out = [0_u32; 4];
        unsafe {
            assert!(slopdesk_feed_subscribers_renew(table, 1, 100.0));
            assert!(slopdesk_feed_subscribers_renew(table, 2, 102.0));
            assert!(slopdesk_feed_subscribers_renew(table, 1, 104.0));
            let reaped = slopdesk_feed_subscribers_reap(table, 108.5, out.as_mut_ptr(), out.len());
            assert_eq!(reaped, 1);
            assert_eq!(out[0], 2);
            slopdesk_feed_subscribers_free(table);
        }
    }
}
