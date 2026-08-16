//! Paths, `path:line:col` diagnostics and URLs, found in the rows of the terminal grid.
//!
//! [`slopdesk_terminal::link::detect`] is a pure fold: rows in, spans out. What it is not is a
//! shape that crosses a C boundary in one value — the answer is a variable-length list of records
//! each carrying up to two strings, and neither the count nor the total text length can be known
//! before the scan runs.
//!
//! ## Why a scan HANDLE for a pure function
//!
//! So the result crosses as an ARENA (§4c) parked behind a handle (§4b): [`slopdesk_link_scan`]
//! takes every input at once, runs the scan, and hands back an owned result the caller reads
//! records out of and then frees. The handle holds no policy and no history — a second scan is a
//! second handle — which is what keeps the Swift face the free function it has always been, with
//! no shared detector for two overlays to race on.
//!
//! Rows arrive as one flat UTF-8 blob plus a length per row rather than as an array of pointers:
//! the caller already has to build something contiguous for the boundary, and one buffer means one
//! allocation and one bounds rule instead of `row_count` of each.
//!
//! ## Why the two width entries are separate
//!
//! [`slopdesk_link_text_cells`] answers for a string; [`slopdesk_link_scalar_cells`] answers for
//! one Unicode scalar the caller is already holding. The callers that walk a line cell by cell —
//! vi-style line motion, the hint assigner's column mapping — would otherwise have to build a
//! one-character string per cell, allocating once per column to ask about a scalar in hand. Same
//! law, spelled once in `slopdesk_terminal`, reached two ways.

use core::ffi::c_uchar;

use slopdesk_terminal::link::{DetectedLinkKind, LinkSchemePolicy, detect, scalar_cells, text_cells};

use crate::{borrow, deliver, records_of};

/// A `/`-rooted filesystem path.
pub const SLOPDESK_LINK_KIND_ABSOLUTE_PATH: u32 = 0;
/// A `~`-anchored path. Expanding it needs the host `$HOME`, so nothing is resolved.
pub const SLOPDESK_LINK_KIND_TILDE_PATH: u32 = 1;
/// A `./…`, `../…` or bare `dir/file` path, resolved against the cwd.
pub const SLOPDESK_LINK_KIND_RELATIVE_PATH: u32 = 2;
/// Any path carrying a `:line` or `:line:col` suffix — compiler and linter output.
pub const SLOPDESK_LINK_KIND_PATH_LINE_COL: u32 = 3;
/// A `scheme://…` URL the policy allows, or an always-on `mailto:` address.
pub const SLOPDESK_LINK_KIND_URL: u32 = 4;
/// A `file://…` URL, whose filesystem path is resolved.
pub const SLOPDESK_LINK_KIND_FILE_URL: u32 = 5;
/// Not a link: the answer to an index past the end of the scan, and to a null handle.
pub const SLOPDESK_LINK_KIND_NONE: u32 = 6;

/// Detect any well-formed `scheme://…`. The default.
pub const SLOPDESK_LINK_SCHEMES_ALL: u32 = 0;
/// Detect only the always-on four plus the list handed to [`slopdesk_link_scan`].
pub const SLOPDESK_LINK_SCHEMES_CUSTOM: u32 = 1;

/// One detected span, with both of its strings named as `(offset, length)` into the scan's arena.
///
/// `col_start..col_end` are display CELLS, so the geometry seam multiplies by the cell width and
/// has a rectangle without measuring anything a second time.
///
/// The resolved path carries a presence flag rather than a zero length: a `file://` URL whose path
/// is genuinely empty is a different fact from a tilde path that cannot be resolved at all.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskDetectedLink {
    /// Index into the rows that were scanned — NOT a scrollback line number.
    pub row: usize,
    /// First display cell of the span.
    pub col_start: usize,
    /// One past the last display cell.
    pub col_end: usize,
    /// One of the `SLOPDESK_LINK_KIND_*` values.
    pub kind: u32,
    /// Where the matched text starts in the arena.
    pub raw_offset: usize,
    /// How long the matched text is, in bytes.
    pub raw_length: usize,
    /// Whether the resolved span means anything.
    pub has_resolved: bool,
    /// Where the resolved absolute path starts in the arena; read only when `has_resolved`.
    pub resolved_offset: usize,
    /// How long the resolved absolute path is, in bytes; read only when `has_resolved`.
    pub resolved_length: usize,
}

impl SlopDeskDetectedLink {
    /// Not a link — an index past the end, or a null handle.
    const NONE: Self = Self {
        row: 0,
        col_start: 0,
        col_end: 0,
        kind: SLOPDESK_LINK_KIND_NONE,
        raw_offset: 0,
        raw_length: 0,
        has_resolved: false,
        resolved_offset: 0,
        resolved_length: 0,
    };
}

/// What one scan produced: how many records to read, and how large a buffer the arena needs.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskLinkCounts {
    /// Records readable through [`slopdesk_link_scan_link`], indices `0..link_count`.
    pub link_count: usize,
    /// Bytes [`slopdesk_link_scan_take_arena`] will write, given a buffer that large.
    pub arena_length: usize,
}

impl SlopDeskLinkCounts {
    /// Nothing scanned — the answer to a null handle.
    const EMPTY: Self = Self {
        link_count: 0,
        arena_length: 0,
    };
}

/// The opaque handle: one scan's records and the single buffer their strings live in.
#[derive(Debug, Default)]
pub struct SlopDeskLinkScan {
    links: Vec<SlopDeskDetectedLink>,
    arena: Vec<u8>,
}

impl SlopDeskLinkScan {
    /// Appends `text` to the arena and answers where it landed.
    fn intern(&mut self, text: &str) -> (usize, usize) {
        let offset = self.arena.len();
        self.arena.extend_from_slice(text.as_bytes());
        (offset, text.len())
    }
}

/// Maps a detected kind onto its wire constant.
const fn kind_code(kind: DetectedLinkKind) -> u32 {
    match kind {
        DetectedLinkKind::AbsolutePath => SLOPDESK_LINK_KIND_ABSOLUTE_PATH,
        DetectedLinkKind::TildePath => SLOPDESK_LINK_KIND_TILDE_PATH,
        DetectedLinkKind::RelativePath => SLOPDESK_LINK_KIND_RELATIVE_PATH,
        DetectedLinkKind::PathLineCol => SLOPDESK_LINK_KIND_PATH_LINE_COL,
        DetectedLinkKind::Url => SLOPDESK_LINK_KIND_URL,
        DetectedLinkKind::FileUrl => SLOPDESK_LINK_KIND_FILE_URL,
    }
}

/// Splits a `(blob, lengths)` pair into strings.
///
/// Lossy because the boundary cannot promise UTF-8 and the scan must stay total; from Swift it is
/// never lossy, since a `String`'s bytes are valid by construction. A length that runs past the end
/// of the blob takes what remains and stops, rather than reading memory it was never given.
fn split(blob: &[u8], lengths: &[usize]) -> Vec<String> {
    let mut cursor = 0_usize;
    let mut out = Vec::with_capacity(lengths.len());
    for length in lengths {
        let end = cursor.saturating_add(*length).min(blob.len());
        out.push(String::from_utf8_lossy(blob.get(cursor..end).unwrap_or(&[])).into_owned());
        cursor = end;
    }
    out
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_link_scan`] that has not been freed, and no
/// other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskLinkScan) -> Option<&'a SlopDeskLinkScan> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift face creates the handle, reads it, and frees it inside one function body.
    Some(unsafe { &*handle })
}

/// Scans `row_count` rows and hands back an owned result.
///
/// `rows`/`row_lengths` are the flat UTF-8 blob and its per-row byte counts. `cwd` is the pane's
/// last-known OSC 7 directory, used only when it is itself absolute; null or empty is no cwd.
/// `scheme_mode` is one of the `SLOPDESK_LINK_SCHEMES_*` values, and the scheme list is read only
/// under `SLOPDESK_LINK_SCHEMES_CUSTOM`. `max_scan_columns` of `0` scans nothing rather than
/// scanning everything.
///
/// Never returns null: an empty scan is a real answer with zero records, and a caller that had to
/// distinguish "no links" from "allocation failed" on every frame would branch for a case Rust
/// aborts on anyway.
///
/// # Safety
/// Each `(ptr, len)` pair must be null or describe live memory for the whole call. The returned
/// handle must be freed exactly once with [`slopdesk_link_scan_free`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_scan(
    rows: *const c_uchar,
    rows_len: usize,
    row_lengths: *const usize,
    row_count: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    scheme_mode: u32,
    schemes: *const c_uchar,
    schemes_len: usize,
    scheme_lengths: *const usize,
    scheme_count: usize,
    max_scan_columns: usize,
) -> *mut SlopDeskLinkScan {
    // SAFETY: every pair is null or live for the call by the caller's obligation, discharged on the
    // Swift side by `withUnsafeBufferPointer`, whose scope is exactly this call.
    let row_text = split(unsafe { borrow(rows, rows_len) }, unsafe {
        records_of(row_lengths, row_count)
    });
    // SAFETY: as above.
    let cwd_text = String::from_utf8_lossy(unsafe { borrow(cwd, cwd_len) }).into_owned();
    let policy = if scheme_mode == SLOPDESK_LINK_SCHEMES_CUSTOM {
        // SAFETY: as above.
        LinkSchemePolicy::Custom(split(unsafe { borrow(schemes, schemes_len) }, unsafe {
            records_of(scheme_lengths, scheme_count)
        }))
    } else {
        LinkSchemePolicy::All
    };

    let borrowed: Vec<&str> = row_text.iter().map(String::as_str).collect();
    let found = detect(
        &borrowed,
        if cwd_text.is_empty() {
            None
        } else {
            Some(&cwd_text)
        },
        &policy,
        max_scan_columns,
    );

    let mut scan = SlopDeskLinkScan {
        links: Vec::with_capacity(found.len()),
        arena: Vec::new(),
    };
    for link in found {
        let (raw_offset, raw_length) = scan.intern(&link.raw);
        let (has_resolved, resolved_offset, resolved_length) =
            link.resolved_absolute.as_ref().map_or((false, 0, 0), |resolved| {
                let (offset, length) = scan.intern(resolved);
                (true, offset, length)
            });
        scan.links.push(SlopDeskDetectedLink {
            row: link.row,
            col_start: link.col_start,
            col_end: link.col_end,
            kind: kind_code(link.kind),
            raw_offset,
            raw_length,
            has_resolved,
            resolved_offset,
            resolved_length,
        });
    }
    Box::into_raw(Box::new(scan))
}

/// Frees a scan. Null is a no-op; anything else must come from exactly one [`slopdesk_link_scan`]
/// and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_link_scan`] not yet freed, with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_scan_free(handle: *mut SlopDeskLinkScan) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one scan and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Reads how much the scan found. A null handle answers an empty scan.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_scan_counts(handle: *mut SlopDeskLinkScan) -> SlopDeskLinkCounts {
    // SAFETY: the caller's obligation, as above.
    let Some(scan) = (unsafe { held(handle) }) else {
        return SlopDeskLinkCounts::EMPTY;
    };
    SlopDeskLinkCounts {
        link_count: scan.links.len(),
        arena_length: scan.arena.len(),
    }
}

/// Reads one record.
///
/// An index past the end — or a null handle — answers a record whose kind is
/// `SLOPDESK_LINK_KIND_NONE`, so a caller that miscounts gets a defined non-link rather than a
/// fault or a plausible-looking zero span.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_scan_link(
    handle: *mut SlopDeskLinkScan,
    index: usize,
) -> SlopDeskDetectedLink {
    // SAFETY: the caller's obligation, as above.
    let Some(scan) = (unsafe { held(handle) }) else {
        return SlopDeskDetectedLink::NONE;
    };
    scan.links
        .get(index)
        .copied()
        .unwrap_or(SlopDeskDetectedLink::NONE)
}

/// Copies the arena into the caller's buffer.
///
/// Returns the byte count the arena holds — the same number the counts answered — and writes
/// nothing when that exceeds `cap`, following the crate's sizing convention. The arena is not
/// cleared by reading it; it lives until the handle is freed.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_scan_take_arena(
    handle: *mut SlopDeskLinkScan,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, as above.
    let Some(scan) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and the arena
    // is a live Rust vector that cannot overlap it.
    unsafe { deliver(&scan.arena, out, cap) }
}

/// Display width of one Unicode scalar in terminal cells.
///
/// A value that is not a scalar — a surrogate, or past U+10FFFF — is not a cluster and answers `0`,
/// exactly as the empty cluster does. Unreachable from Swift, whose `Unicode.Scalar` is valid by
/// construction.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_scalar_cells(scalar: u32) -> usize {
    char::from_u32(scalar).map_or(0, scalar_cells)
}

/// Display width of a UTF-8 string in terminal cells — the sum over its grapheme clusters.
///
/// # Safety
/// `(bytes, len)` must be null or describe live memory for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_link_text_cells(bytes: *const c_uchar, len: usize) -> usize {
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    text_cells(&String::from_utf8_lossy(unsafe { borrow(bytes, len) }))
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_LINK_KIND_ABSOLUTE_PATH, SLOPDESK_LINK_KIND_NONE, SLOPDESK_LINK_KIND_PATH_LINE_COL,
        SLOPDESK_LINK_KIND_URL, SLOPDESK_LINK_SCHEMES_ALL, SLOPDESK_LINK_SCHEMES_CUSTOM,
        SlopDeskDetectedLink, slopdesk_link_scalar_cells, slopdesk_link_scan, slopdesk_link_scan_counts,
        slopdesk_link_scan_free, slopdesk_link_scan_link, slopdesk_link_scan_take_arena,
        slopdesk_link_text_cells,
    };
    use crate::saturating_u32;

    /// One detected span, with its arena spans already resolved to strings — what the Swift face
    /// builds out of a record plus the arena.
    #[derive(Debug, PartialEq, Eq)]
    struct Read {
        row: usize,
        col_start: usize,
        col_end: usize,
        kind: u32,
        raw: String,
        resolved: Option<String>,
    }

    /// Drives the whole door the way the face does: flatten, scan, read every record, free.
    fn scan(rows: &[&str], cwd: Option<&str>, schemes: Option<&[&str]>, max_columns: usize) -> Vec<Read> {
        let mut blob = Vec::new();
        let mut lengths = Vec::new();
        for row in rows {
            blob.extend_from_slice(row.as_bytes());
            lengths.push(row.len());
        }
        let mut scheme_blob = Vec::new();
        let mut scheme_lengths = Vec::new();
        for scheme in schemes.unwrap_or(&[]) {
            scheme_blob.extend_from_slice(scheme.as_bytes());
            scheme_lengths.push(scheme.len());
        }
        let cwd_bytes = cwd.unwrap_or("").as_bytes();
        let handle = unsafe {
            slopdesk_link_scan(
                blob.as_ptr(),
                blob.len(),
                lengths.as_ptr(),
                lengths.len(),
                cwd_bytes.as_ptr(),
                cwd_bytes.len(),
                if schemes.is_some() {
                    SLOPDESK_LINK_SCHEMES_CUSTOM
                } else {
                    SLOPDESK_LINK_SCHEMES_ALL
                },
                scheme_blob.as_ptr(),
                scheme_blob.len(),
                scheme_lengths.as_ptr(),
                scheme_lengths.len(),
                max_columns,
            )
        };
        let counts = unsafe { slopdesk_link_scan_counts(handle) };
        let mut arena = vec![0_u8; counts.arena_length];
        let written = unsafe { slopdesk_link_scan_take_arena(handle, arena.as_mut_ptr(), arena.len()) };
        assert_eq!(
            written, counts.arena_length,
            "the arena answered a size it then would not fill"
        );
        // This door spells its arena pair `size_t`, the way §4 spells every length, where the
        // record-carrying doors spell it `u32`. Saturating is the exact bridge: a pair inside a real
        // arena converts unchanged, and one too wide to be inside any arena answers empty either
        // way. It is the ONE place the two widths meet, which is where the cast belongs.
        let text = |offset: usize, length: usize| {
            crate::arena_text(&arena, saturating_u32(offset), saturating_u32(length))
        };
        let out = (0..counts.link_count)
            .map(|index| {
                let record = unsafe { slopdesk_link_scan_link(handle, index) };
                Read {
                    row: record.row,
                    col_start: record.col_start,
                    col_end: record.col_end,
                    kind: record.kind,
                    raw: text(record.raw_offset, record.raw_length),
                    resolved: record
                        .has_resolved
                        .then(|| text(record.resolved_offset, record.resolved_length)),
                }
            })
            .collect();
        unsafe { slopdesk_link_scan_free(handle) };
        out
    }

    #[test]
    fn an_absolute_path_crosses_with_its_cells_and_its_resolved_form() {
        let found = scan(&["see /usr/local/bin/foo now"], None, None, 4096);
        assert_eq!(found, vec![Read {
            row: 0,
            col_start: 4,
            col_end: 22,
            kind: SLOPDESK_LINK_KIND_ABSOLUTE_PATH,
            raw: "/usr/local/bin/foo".to_owned(),
            resolved: Some("/usr/local/bin/foo".to_owned()),
        }]);
    }

    #[test]
    fn a_relative_diagnostic_resolves_against_the_cwd_and_drops_the_suffix() {
        let found = scan(&["src/lib.rs:42:5"], Some("/work/proj"), None, 4096);
        assert_eq!(
            found,
            vec![Read {
                row: 0,
                col_start: 0,
                col_end: 15,
                kind: SLOPDESK_LINK_KIND_PATH_LINE_COL,
                raw: "src/lib.rs:42:5".to_owned(),
                resolved: Some("/work/proj/src/lib.rs".to_owned()),
            }],
            "the raw keeps the suffix, the resolved drops it",
        );
    }

    #[test]
    fn a_tilde_path_crosses_with_no_resolved_span_at_all() {
        let found = scan(&["~/project/file.swift"], None, None, 4096);
        assert_eq!(
            found.iter().map(|link| link.resolved.clone()).collect::<Vec<_>>(),
            vec![None],
            "the host $HOME is not this side's to know",
        );
    }

    #[test]
    fn the_scheme_policy_travels_and_a_disallowed_scheme_is_dropped() {
        let rows = ["codex://open/1 ssh://host/x"];
        let matched = |found: Vec<Read>| found.into_iter().map(|link| link.raw).collect::<Vec<_>>();
        assert_eq!(
            matched(scan(&rows, None, None, 4096)),
            vec!["codex://open/1", "ssh://host/x"],
            "All takes both",
        );
        let custom = scan(&rows, None, Some(&["codex"]), 4096);
        assert_eq!(custom.iter().map(|link| link.kind).collect::<Vec<_>>(), vec![
            SLOPDESK_LINK_KIND_URL
        ],);
        assert_eq!(
            matched(custom),
            vec!["codex://open/1"],
            "Custom takes only the listed one",
        );
    }

    #[test]
    fn wide_glyphs_move_the_columns_by_two_cells_each() {
        let found = scan(&["日本 /tmp/x"], None, None, 4096);
        assert_eq!(
            found
                .iter()
                .map(|link| (link.col_start, link.col_end))
                .collect::<Vec<_>>(),
            vec![(5, 11)],
            "two wide clusters plus one space put the span at cell 5",
        );
    }

    #[test]
    fn a_zero_column_bound_scans_nothing_and_still_answers() {
        let found = scan(&["/usr/bin/env"], None, None, 0);
        assert!(found.is_empty(), "0 scans nothing rather than everything");
    }

    #[test]
    fn every_row_index_is_the_position_in_the_rows_that_were_handed_over() {
        let found = scan(
            &["nothing here", "/a/b", "", "https://x.test/y"],
            None,
            None,
            4096,
        );
        assert_eq!(found.iter().map(|link| link.row).collect::<Vec<_>>(), vec![1, 3]);
    }

    #[test]
    fn the_cell_width_entries_agree_with_each_other_and_with_the_scan() {
        assert_eq!(unsafe { slopdesk_link_scalar_cells(u32::from('a')) }, 1);
        assert_eq!(unsafe { slopdesk_link_scalar_cells(u32::from('日')) }, 2);
        assert_eq!(
            unsafe { slopdesk_link_scalar_cells(0x115F) },
            0,
            "zero-width is checked before wide",
        );
        assert_eq!(
            unsafe { slopdesk_link_scalar_cells(0xD800) },
            0,
            "a surrogate is not a scalar, so it is not a cluster",
        );
        let text = "日本a";
        assert_eq!(unsafe { slopdesk_link_text_cells(text.as_ptr(), text.len()) }, 5);
        assert_eq!(unsafe { slopdesk_link_text_cells(std::ptr::null(), 0) }, 0);
    }

    #[test]
    fn a_null_handle_and_a_past_the_end_index_both_answer_rather_than_fault() {
        let counts = unsafe { slopdesk_link_scan_counts(std::ptr::null_mut()) };
        assert_eq!(counts.link_count, 0);
        assert_eq!(counts.arena_length, 0);
        assert_eq!(
            unsafe { slopdesk_link_scan_link(std::ptr::null_mut(), 0) },
            SlopDeskDetectedLink::NONE
        );
        assert_eq!(
            unsafe { slopdesk_link_scan_take_arena(std::ptr::null_mut(), std::ptr::null_mut(), 0) },
            0
        );
        unsafe { slopdesk_link_scan_free(std::ptr::null_mut()) };

        let empty: [&str; 0] = [];
        let handle = unsafe {
            slopdesk_link_scan(
                std::ptr::null(),
                0,
                std::ptr::null(),
                empty.len(),
                std::ptr::null(),
                0,
                SLOPDESK_LINK_SCHEMES_ALL,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                4096,
            )
        };
        assert!(!handle.is_null(), "an empty scan is still an answer");
        assert_eq!(
            unsafe { slopdesk_link_scan_link(handle, 7) }.kind,
            SLOPDESK_LINK_KIND_NONE
        );
        unsafe { slopdesk_link_scan_free(handle) };
    }
}
