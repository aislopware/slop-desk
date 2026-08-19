//! Which folder a user meant: the frecency ranking, and the `slopdesk jump` target it resolves.
//!
//! `rust/slopdesk-workspace`'s `frecency` and `jump` own both. The ranking is asked by the running
//! app — the folder rail, the open-quickly overlay, the store's own cap — and by the CLI, which is
//! precisely why it is one function rather than three sorts, and why this door hands the same one
//! to both.
//!
//! ## The database crosses by value, and the ranking answers in INDICES
//! A folder database is a few hundred short paths the near side already holds, so it is lent as a
//! record array plus one arena of path bytes — §4b's by-value fold, not a handle. The ranking then
//! answers the caller's own indices rather than copying the paths back: a rank is a permutation of
//! what was just lent, and re-crossing the strings to say so would be the one wasteful thing in an
//! otherwise-free call.
//!
//! The REPAIR of a loaded file answers the same way, for the same reason: which entries a
//! hand-edited database keeps is a subset of what was lent, so it comes back as indices too.
//!
//! ## A jump answers two strings, so it answers through an arena
//! The resolved path is one of `$HOME`, the recorded source, or a ranked entry, and the source the
//! caller should persist is a second string that may or may not be present. Both come back in one
//! arena with a fixed-size record naming them, on the two-call shape every variable-length answer
//! on this door uses.

use std::ffi::c_uchar;

use slopdesk_workspace::frecency::{
    DEFAULT_MAX_ENTRIES, FolderEntry, MAX_PATH_SCALARS, ReferenceSeconds, WEIGHT_DAY, WEIGHT_HOUR,
    WEIGHT_MONTH, WEIGHT_STALE, WEIGHT_WEEK, is_valid_path, ranked, recency_weight, sanitized, score,
};
use slopdesk_workspace::jump::resolve;

use crate::host_state::SlopDeskByteSpan;
use crate::{borrow, records_of};

/// Visited within the last hour — the freshest, highest-weight bucket.
pub const SLOPDESK_FOLDER_WEIGHT_HOUR: u32 = 0;
/// Visited within the last day.
pub const SLOPDESK_FOLDER_WEIGHT_DAY: u32 = 1;
/// Visited within the last week.
pub const SLOPDESK_FOLDER_WEIGHT_WEEK: u32 = 2;
/// Visited within the last month.
pub const SLOPDESK_FOLDER_WEIGHT_MONTH: u32 = 3;
/// Older than a month — the lowest weight, still above zero.
pub const SLOPDESK_FOLDER_WEIGHT_STALE: u32 = 4;

/// The default ceiling on stored entries.
pub const SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES: u32 = 0;
/// The longest storable path, in Unicode scalars.
pub const SLOPDESK_FOLDER_LIMIT_PATH_SCALARS: u32 = 1;

/// One folder record as it crosses: a span into the caller's arena, plus the two scored terms.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskFolderEntry {
    /// The visited path, naming bytes in the arena lent alongside.
    pub path: SlopDeskByteSpan,
    /// How many times this folder has been visited — the frequency term.
    pub access_count: i64,
    /// When it was last visited, in seconds since the reference epoch — the recency term.
    pub last_access: f64,
}

/// A resolved `slopdesk jump`: where to go, and the toggle source to persist.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SlopDeskJumpResolution {
    /// The directory to `cd` into, naming bytes in the answer arena.
    pub path: SlopDeskByteSpan,
    /// The toggle source to persist, meaningful only when `has_source`.
    pub source: SlopDeskByteSpan,
    /// Whether a target was resolved at all. False means a query matched no visited folder.
    pub resolved: bool,
    /// Whether there is a source to persist.
    pub has_source: bool,
}

/// The text a `(ptr, len)` pair names, lossily — a path a foreign shell wrote is not guaranteed to
/// be UTF-8, and a jump is never the place to refuse one.
///
/// # Safety
/// The pair must describe live, initialised memory for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
unsafe fn text<'a>(ptr: *const c_uchar, len: usize) -> std::borrow::Cow<'a, str> {
    // SAFETY: the caller's obligation above.
    String::from_utf8_lossy(unsafe { borrow(ptr, len) })
}

/// Rebuilds the lent database as the crate's own entries.
///
/// # Safety
/// The record array and the arena must both be live for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's arrays IS the boundary this module documents"
)]
unsafe fn database(
    entries: *const SlopDeskFolderEntry,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
) -> Vec<FolderEntry> {
    // SAFETY: the caller's obligation above.
    let pool = unsafe { borrow(arena, arena_len) };
    // SAFETY: the caller's obligation above.
    let records = unsafe { records_of(entries, count) };
    records
        .iter()
        .map(|record| {
            let start = record.path.offset as usize;
            let end = start.saturating_add(record.path.length as usize);
            let path = pool.get(start..end).unwrap_or_default();
            FolderEntry::new(
                String::from_utf8_lossy(path).into_owned(),
                record.access_count,
                record.last_access,
            )
        })
        .collect()
}

/// The recency bucket weights, by code, so neither language writes the numbers down twice.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_folder_weight(bucket: u32) -> i64 {
    match bucket {
        SLOPDESK_FOLDER_WEIGHT_HOUR => WEIGHT_HOUR,
        SLOPDESK_FOLDER_WEIGHT_DAY => WEIGHT_DAY,
        SLOPDESK_FOLDER_WEIGHT_WEEK => WEIGHT_WEEK,
        SLOPDESK_FOLDER_WEIGHT_MONTH => WEIGHT_MONTH,
        _ => WEIGHT_STALE,
    }
}

/// The recency weight for an entry last visited at `last_access`, observed at `now`.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_folder_recency_weight(
    now: ReferenceSeconds,
    last_access: ReferenceSeconds,
) -> i64 {
    recency_weight(now, last_access)
}

/// The frecency score: frequency clamped, times the recency weight.
///
/// The path plays no part in a score, so this one takes the two terms rather than a whole record.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_folder_score(
    access_count: i64,
    last_access: ReferenceSeconds,
    now: ReferenceSeconds,
) -> i64 {
    score(&FolderEntry::new(String::new(), access_count, last_access), now)
}

/// Ranks the lent database, answering the caller's own indices in rank order.
///
/// A negative `limit` means "every entry". Returns how many indices the rank HAS: a caller that
/// lent fewer gets the count it should have lent and nothing written, per the door's convention.
///
/// # Safety
/// The record array, the arena and the index buffer must each be null or live for their stated
/// lengths for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_folder_ranked(
    entries: *const SlopDeskFolderEntry,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    now: ReferenceSeconds,
    limit: i64,
    order: *mut u32,
    order_cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let owned = unsafe { database(entries, count, arena, arena_len) };
    let cap = usize::try_from(limit).ok();
    let stride = size_of::<FolderEntry>();
    let base = owned.as_ptr() as usize;
    let indices: Vec<u32> = ranked(&owned, now, cap)
        .into_iter()
        // A ranked reference points into `owned`, so its offset from the base IS its index. The
        // rank is a permutation of what was lent; saying so in indices costs no string copies.
        .map(|entry| {
            let offset = (std::ptr::from_ref(entry) as usize).saturating_sub(base);
            u32::try_from(offset.checked_div(stride).unwrap_or(0)).unwrap_or(u32::MAX)
        })
        .collect();
    if indices.len() > order_cap || order.is_null() || indices.is_empty() {
        return indices.len();
    }
    // SAFETY: the buffer is non-null and holds at least `indices.len()` entries, by the check above
    // and the caller's obligation that it is writable for `order_cap`.
    unsafe { std::ptr::copy_nonoverlapping(indices.as_ptr(), order, indices.len()) };
    indices.len()
}

/// The two limits the store is written against, by code, so neither language writes them down
/// twice.
///
/// `SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES` is the default ceiling on stored entries;
/// `SLOPDESK_FOLDER_LIMIT_PATH_SCALARS` the longest storable path, in Unicode scalars. An unknown
/// code answers `0`, which no caller can mistake for a limit.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_folder_limit(limit: u32) -> usize {
    match limit {
        SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES => DEFAULT_MAX_ENTRIES,
        SLOPDESK_FOLDER_LIMIT_PATH_SCALARS => MAX_PATH_SCALARS,
        _ => 0,
    }
}

/// Whether a path may be STORED at all: not blank, and within the scalar cap.
///
/// # Safety
/// The pair must describe live, initialised memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_folder_path_is_valid(path: *const c_uchar, len: usize) -> bool {
    // SAFETY: the caller's obligation above.
    is_valid_path(&unsafe { text(path, len) })
}

/// Repairs a LOADED database, answering the caller's own indices for the entries worth keeping.
///
/// Same two-call shape as the ranking, and the same reason for indices: the caller holds every
/// record already, so what comes back is which of them survived, in the order they should be
/// stored.
///
/// # Safety
/// The record array, the arena and the index buffer must each be null or live for their stated
/// lengths for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_folder_sanitized(
    entries: *const SlopDeskFolderEntry,
    count: usize,
    arena: *const c_uchar,
    arena_len: usize,
    max_entries: usize,
    order: *mut u32,
    order_cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let owned = unsafe { database(entries, count, arena, arena_len) };
    let kept: Vec<u32> = sanitized(&owned, max_entries)
        .into_iter()
        .map(|index| u32::try_from(index).unwrap_or(u32::MAX))
        .collect();
    if kept.len() > order_cap || order.is_null() || kept.is_empty() {
        return kept.len();
    }
    // SAFETY: the buffer is non-null and holds at least `kept.len()` entries, by the check above and
    // the caller's obligation that it is writable for `order_cap`.
    unsafe { std::ptr::copy_nonoverlapping(kept.as_ptr(), order, kept.len()) };
    kept.len()
}

/// Resolves an `slopdesk jump` target over the lent database.
///
/// An empty `query`, `cwd` or `source` means absent, which is what a blank one already trims to.
/// Answers how many arena bytes the two strings need; the fixed-size record is written on every
/// call that lends one, so a caller can read `resolved` before it allocates.
///
/// # Safety
/// Every input pair must be live for the call; `out` must be null or writable, and `arena` null or
/// writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_jump_resolve(
    query: *const c_uchar,
    query_len: usize,
    entries: *const SlopDeskFolderEntry,
    count: usize,
    entry_arena: *const c_uchar,
    entry_arena_len: usize,
    now: ReferenceSeconds,
    home: *const c_uchar,
    home_len: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    source: *const c_uchar,
    source_len: usize,
    change_directory: bool,
    out: *mut SlopDeskJumpResolution,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above, discharged for every pair by one `withUnsafeBytes`
    // scope on the near side.
    let owned = unsafe { database(entries, count, entry_arena, entry_arena_len) };
    // SAFETY: as above.
    let (asked, home, cwd, source) = unsafe {
        (
            text(query, query_len),
            text(home, home_len),
            text(cwd, cwd_len),
            text(source, source_len),
        )
    };
    let answer = resolve(
        Some(asked.as_ref()),
        &owned,
        now,
        home.as_ref(),
        Some(cwd.as_ref()),
        Some(source.as_ref()),
        change_directory,
    );
    let mut record = SlopDeskJumpResolution::default();
    let mut pool = Vec::new();
    if let Some(answer) = answer {
        record.resolved = true;
        let (offset, length) = intern(&mut pool, answer.path.as_bytes());
        record.path = SlopDeskByteSpan { offset, length };
        if let Some(kept) = answer.last_jump_source.as_deref() {
            record.has_source = true;
            let (offset, length) = intern(&mut pool, kept.as_bytes());
            record.source = SlopDeskByteSpan { offset, length };
        }
    }
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one record.
        unsafe { std::ptr::write(out, record) };
    }
    if !pool.is_empty() && !arena.is_null() && pool.len() <= arena_cap {
        // SAFETY: non-null and large enough, by the check above and the caller's obligation.
        unsafe { std::ptr::copy_nonoverlapping(pool.as_ptr(), arena, pool.len()) };
    }
    pool.len()
}

/// Appends `bytes` to the answer arena and names them.
fn intern(pool: &mut Vec<u8>, bytes: &[u8]) -> (u32, u32) {
    let offset = u32::try_from(pool.len()).unwrap_or(u32::MAX);
    pool.extend_from_slice(bytes);
    (offset, u32::try_from(bytes.len()).unwrap_or(u32::MAX))
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{
        SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES, SLOPDESK_FOLDER_LIMIT_PATH_SCALARS, SLOPDESK_FOLDER_WEIGHT_DAY,
        SLOPDESK_FOLDER_WEIGHT_HOUR, SLOPDESK_FOLDER_WEIGHT_STALE, SlopDeskFolderEntry,
        SlopDeskJumpResolution, slopdesk_folder_limit, slopdesk_folder_path_is_valid, slopdesk_folder_ranked,
        slopdesk_folder_recency_weight, slopdesk_folder_sanitized, slopdesk_folder_score,
        slopdesk_folder_weight, slopdesk_jump_resolve,
    };
    use crate::host_state::SlopDeskByteSpan;

    const NOW: f64 = 1_000_000_000.0;
    const HOME: &str = "/Users/me";

    /// A database as it crosses: the records, and the one arena their paths live in.
    fn database(rows: &[(&str, i64, f64)]) -> (Vec<SlopDeskFolderEntry>, Vec<u8>) {
        let mut arena = Vec::new();
        let records = rows
            .iter()
            .map(|&(path, access_count, age)| {
                let offset = u32::try_from(arena.len()).unwrap_or(u32::MAX);
                arena.extend_from_slice(path.as_bytes());
                SlopDeskFolderEntry {
                    path: SlopDeskByteSpan {
                        offset,
                        length: u32::try_from(path.len()).unwrap_or(u32::MAX),
                    },
                    access_count,
                    last_access: NOW - age,
                }
            })
            .collect();
        (records, arena)
    }

    /// The rank of a database, as indices, through the two-call shape.
    fn rank(rows: &[(&str, i64, f64)], limit: i64) -> Vec<u32> {
        let (records, arena) = database(rows);
        let needed = unsafe {
            slopdesk_folder_ranked(
                records.as_ptr(),
                records.len(),
                arena.as_ptr(),
                arena.len(),
                NOW,
                limit,
                std::ptr::null_mut(),
                0,
            )
        };
        let mut order = vec![0_u32; needed];
        let written = unsafe {
            slopdesk_folder_ranked(
                records.as_ptr(),
                records.len(),
                arena.as_ptr(),
                arena.len(),
                NOW,
                limit,
                order.as_mut_ptr(),
                order.len(),
            )
        };
        assert_eq!(written, needed);
        order
    }

    /// A jump, through the two-call shape, as `(path, source)`.
    fn jump(
        query: &str,
        rows: &[(&str, i64, f64)],
        cwd: &str,
        source: &str,
        change_directory: bool,
    ) -> Option<(String, Option<String>)> {
        let (records, arena) = database(rows);
        let mut record = SlopDeskJumpResolution::default();
        let ask = |out: *mut SlopDeskJumpResolution, pool: *mut u8, cap: usize| unsafe {
            slopdesk_jump_resolve(
                query.as_ptr(),
                query.len(),
                records.as_ptr(),
                records.len(),
                arena.as_ptr(),
                arena.len(),
                NOW,
                HOME.as_ptr(),
                HOME.len(),
                cwd.as_ptr(),
                cwd.len(),
                source.as_ptr(),
                source.len(),
                change_directory,
                out,
                pool,
                cap,
            )
        };
        let needed = ask(&raw mut record, std::ptr::null_mut(), 0);
        if !record.resolved {
            return None;
        }
        let mut pool = vec![0_u8; needed];
        let written = ask(&raw mut record, pool.as_mut_ptr(), pool.len());
        assert_eq!(written, needed);
        let read = |span: SlopDeskByteSpan| {
            let start = span.offset as usize;
            let end = start + span.length as usize;
            String::from_utf8_lossy(pool.get(start..end).unwrap_or_default()).into_owned()
        };
        Some((read(record.path), record.has_source.then(|| read(record.source))))
    }

    #[test]
    fn the_bucket_weights_come_from_the_crate() {
        assert_eq!(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_HOUR), 16);
        assert_eq!(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_DAY), 8);
        assert_eq!(slopdesk_folder_weight(SLOPDESK_FOLDER_WEIGHT_STALE), 1);
        // An unknown bucket is the stale one, never a trap.
        assert_eq!(slopdesk_folder_weight(9), 1);
    }

    #[test]
    fn a_weight_falls_on_the_documented_side_of_its_boundary() {
        assert_eq!(slopdesk_folder_recency_weight(NOW, NOW - 3_599.0), 16);
        assert_eq!(slopdesk_folder_recency_weight(NOW, NOW - 3_600.0), 8);
        // A corrupt timestamp reads as ancient rather than out-ranking a real entry.
        assert_eq!(slopdesk_folder_recency_weight(NOW, f64::NAN), 1);
    }

    #[test]
    fn a_score_is_the_clamped_frequency_times_the_weight() {
        assert_eq!(slopdesk_folder_score(3, NOW, NOW), 48);
        // A hand-edited negative count scores zero rather than inverting the order.
        assert_eq!(slopdesk_folder_score(-5, NOW, NOW), 0);
    }

    #[test]
    fn the_rank_answers_the_callers_own_indices() {
        let rows = [
            ("/a/stale", 10, 5_184_000.0),
            ("/b/fresh", 2, 60.0),
            ("/c/frequent-fresh", 9, 60.0),
        ];
        assert_eq!(rank(&rows, -1), vec![2, 1, 0]);
        // A limit keeps the head of the same order.
        assert_eq!(rank(&rows, 2), vec![2, 1]);
        // An empty database ranks to nothing, through the same call.
        assert!(rank(&[], -1).is_empty());
    }

    #[test]
    fn the_limits_come_from_the_crate_and_an_unknown_code_is_not_one() {
        assert_eq!(slopdesk_folder_limit(SLOPDESK_FOLDER_LIMIT_MAX_ENTRIES), 200);
        assert_eq!(slopdesk_folder_limit(SLOPDESK_FOLDER_LIMIT_PATH_SCALARS), 4096);
        assert_eq!(slopdesk_folder_limit(9), 0);
    }

    #[test]
    fn a_path_crosses_and_comes_back_storable_or_not() {
        let ask = |path: &str| unsafe { slopdesk_folder_path_is_valid(path.as_ptr(), path.len()) };
        assert!(ask("/tmp"));
        assert!(!ask("   "));
        assert!(!ask(""));
        // A null pair is the empty path, not a trap.
        assert!(!unsafe { slopdesk_folder_path_is_valid(std::ptr::null(), 0) });
        let cap = slopdesk_folder_limit(SLOPDESK_FOLDER_LIMIT_PATH_SCALARS);
        assert!(
            ask(&"é".repeat(cap)),
            "the cap counts scalars, and this is twice as many bytes"
        );
        assert!(!ask(&"a".repeat(cap + 1)));
    }

    #[test]
    fn the_repair_answers_the_callers_own_indices() {
        let rows = [
            ("/keep", 3, 90_000.0),
            ("  ", 3, 0.0),
            ("/negative", -1, 0.0),
            ("/fresh", 1, 1.0),
        ];
        let (records, arena) = database(&rows);
        let repair = |max_entries: usize| {
            let needed = unsafe {
                slopdesk_folder_sanitized(
                    records.as_ptr(),
                    records.len(),
                    arena.as_ptr(),
                    arena.len(),
                    max_entries,
                    std::ptr::null_mut(),
                    0,
                )
            };
            let mut order = vec![0_u32; needed];
            let written = unsafe {
                slopdesk_folder_sanitized(
                    records.as_ptr(),
                    records.len(),
                    arena.as_ptr(),
                    arena.len(),
                    max_entries,
                    order.as_mut_ptr(),
                    order.len(),
                )
            };
            assert_eq!(written, needed);
            order
        };
        // The blank path and the negative count could not have been written by the store.
        assert_eq!(repair(200), vec![0, 3]);
        // Over the cap, the freshest survives.
        assert_eq!(repair(1), vec![3]);
    }

    #[test]
    fn a_query_jump_takes_the_most_frecent_match_and_leaves_the_toggle_alone() {
        let rows = [("/work/slopdesk", 10, 60.0), ("/work/other", 1, 60.0)];
        assert_eq!(
            jump("SLOP", &rows, "/somewhere", "/kept", true),
            Some(("/work/slopdesk".to_owned(), Some("/kept".to_owned())))
        );
        // No visited folder matched: the caller reports the error.
        assert_eq!(jump("nowhere", &rows, "", "", true), None);
    }

    #[test]
    fn the_home_toggle_advances_only_on_a_committed_jump() {
        let rows = [("/work/slopdesk", 10, 60.0)];
        assert_eq!(
            jump("", &rows, "/away", "", true),
            Some((HOME.to_owned(), Some("/away".to_owned())))
        );
        // The same resolution as a `--no-cd` preview leaves the source untouched.
        assert_eq!(jump("", &rows, "/away", "", false), Some((HOME.to_owned(), None)));
        // At home with a recorded source, the toggle returns to it and KEEPS it.
        assert_eq!(
            jump("", &rows, HOME, "/back", true),
            Some(("/back".to_owned(), Some("/back".to_owned())))
        );
        // Nothing recorded yet: the single most-frecent folder.
        assert_eq!(
            jump("", &rows, HOME, "", true),
            Some(("/work/slopdesk".to_owned(), None))
        );
        // Nothing learned at all: stay home.
        assert_eq!(jump("", &[], HOME, "", true), Some((HOME.to_owned(), None)));
    }
}
