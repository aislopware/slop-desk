//! Hint Mode's targets, in C.
//!
//! [`slopdesk_rowscan::hint::targets`] answers a variable-length list of records each carrying up
//! to three strings, which is the same shape [`crate::link_detect`] settled with §4b's handle over
//! §4c's arena — so this is that convention again, not a new one. One scan is one handle: take
//! every input at once, run it, read the records out, free it.
//!
//! ## Why a hint target is not just a link
//!
//! Because a link is one of its four kinds. A `LINK` target carries the whole detected link — its
//! kind and its resolved absolute path — so the actuator routes through the same link policy the
//! ⌘-click and Jump-To paths use, rather than a second mapping that would drift. The other three
//! kinds leave those fields at their absent values, and `CUSTOM` is the only one carrying an action
//! template. One record type rather than four is what keeps the reader on the Swift side a single
//! loop with no second door to size.
//!
//! ## The patterns cross as two parallel blobs
//!
//! `patterns` and `actions` are flat UTF-8 with a length per entry, the same way rows and schemes
//! already cross. An action of length `0` is NO action — a pattern with an empty template and a
//! pattern with none behave identically at the actuation site, so a presence flag would name a
//! distinction nothing downstream can act on.
//!
//! ## What is NOT here
//!
//! The labels. `HintLabelAssigner.labels` / `.filter` stay in Swift — list arithmetic over 26
//! letters with no text and no untrusted input, next to the overlay that holds the result.

use core::ffi::c_uchar;

use slopdesk_rowscan::hint::{Pattern, Target, TargetKind, targets};
use slopdesk_terminal::link::LinkSchemePolicy;

use crate::link_detect::{SLOPDESK_LINK_KIND_NONE, SLOPDESK_LINK_SCHEMES_CUSTOM, kind_code, split};
use crate::{borrow, deliver, records_of};

/// A path, URL, `file://` or `mailto:` span the link scan classified.
pub const SLOPDESK_HINT_KIND_LINK: u32 = 0;
/// A commit-hash-shaped token.
pub const SLOPDESK_HINT_KIND_GIT_HASH: u32 = 1;
/// A dotted-quad IPv4 address.
pub const SLOPDESK_HINT_KIND_IP_ADDRESS: u32 = 2;
/// A user `hint-pattern` match.
pub const SLOPDESK_HINT_KIND_CUSTOM: u32 = 3;
/// Not a target: the answer to an index past the end, and to a null handle.
pub const SLOPDESK_HINT_KIND_NONE: u32 = 4;

/// One hintable target, with each of its strings named as `(offset, length)` into the scan's arena.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskHintTarget {
    /// Index into the rows that were scanned — NOT a scrollback line number.
    pub row: usize,
    /// First display cell of the span.
    pub col_start: usize,
    /// One past the last display cell.
    pub col_end: usize,
    /// One of the `SLOPDESK_HINT_KIND_*` values.
    pub kind: u32,
    /// Where the matched text starts in the arena.
    pub raw_offset: usize,
    /// How long the matched text is, in bytes.
    pub raw_length: usize,
    /// The wrapped link's `SLOPDESK_LINK_KIND_*`; `SLOPDESK_LINK_KIND_NONE` unless `kind` is LINK.
    pub link_kind: u32,
    /// Whether the wrapped link resolved to an absolute path.
    pub has_resolved: bool,
    /// Where that path starts in the arena; read only when `has_resolved`.
    pub resolved_offset: usize,
    /// How long that path is, in bytes; read only when `has_resolved`.
    pub resolved_length: usize,
    /// Whether this target carries a `{0}` action template.
    pub has_action: bool,
    /// Where the template starts in the arena; read only when `has_action`.
    pub action_offset: usize,
    /// How long the template is, in bytes; read only when `has_action`.
    pub action_length: usize,
}

impl SlopDeskHintTarget {
    /// Not a target — an index past the end, or a null handle.
    const NONE: Self = Self {
        row: 0,
        col_start: 0,
        col_end: 0,
        kind: SLOPDESK_HINT_KIND_NONE,
        raw_offset: 0,
        raw_length: 0,
        link_kind: SLOPDESK_LINK_KIND_NONE,
        has_resolved: false,
        resolved_offset: 0,
        resolved_length: 0,
        has_action: false,
        action_offset: 0,
        action_length: 0,
    };
}

/// What one hint scan produced: how many records to read, and how large a buffer the arena needs.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskHintCounts {
    /// Records readable through [`slopdesk_hint_scan_target`], indices `0..target_count`.
    pub target_count: usize,
    /// Bytes [`slopdesk_hint_scan_take_arena`] will write, given a buffer that large.
    pub arena_length: usize,
}

impl SlopDeskHintCounts {
    /// Nothing scanned — the answer to a null handle.
    const EMPTY: Self = Self {
        target_count: 0,
        arena_length: 0,
    };
}

/// The opaque handle: one scan's records and the single buffer their strings live in.
#[derive(Debug, Default)]
pub struct SlopDeskHintScan {
    found: Vec<SlopDeskHintTarget>,
    arena: Vec<u8>,
}

impl SlopDeskHintScan {
    /// Appends `text` to the arena and answers where it landed.
    fn intern(&mut self, text: &str) -> (usize, usize) {
        let offset = self.arena.len();
        self.arena.extend_from_slice(text.as_bytes());
        (offset, text.len())
    }

    /// Interns one target's strings and appends its record.
    fn push(&mut self, target: &Target) {
        let (raw_offset, raw_length) = self.intern(&target.raw);
        let (kind, link_kind, resolved) = match &target.kind {
            TargetKind::Link(link) => {
                (
                    SLOPDESK_HINT_KIND_LINK,
                    kind_code(link.kind),
                    link.resolved_absolute.as_deref(),
                )
            },
            TargetKind::GitHash => (SLOPDESK_HINT_KIND_GIT_HASH, SLOPDESK_LINK_KIND_NONE, None),
            TargetKind::IpAddress => (SLOPDESK_HINT_KIND_IP_ADDRESS, SLOPDESK_LINK_KIND_NONE, None),
            TargetKind::Custom { .. } => (SLOPDESK_HINT_KIND_CUSTOM, SLOPDESK_LINK_KIND_NONE, None),
        };
        let (has_resolved, resolved_offset, resolved_length) = resolved.map_or((false, 0, 0), |path| {
            let (offset, length) = self.intern(path);
            (true, offset, length)
        });
        let action = match &target.kind {
            TargetKind::Custom { action } => action.as_deref(),
            _ => None,
        };
        let (has_action, action_offset, action_length) = action.map_or((false, 0, 0), |template| {
            let (offset, length) = self.intern(template);
            (true, offset, length)
        });
        self.found.push(SlopDeskHintTarget {
            row: target.row,
            col_start: target.col_start,
            col_end: target.col_end,
            kind,
            raw_offset,
            raw_length,
            link_kind,
            has_resolved,
            resolved_offset,
            resolved_length,
            has_action,
            action_offset,
            action_length,
        });
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_hint_scan`] that has not been freed, and no
/// other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskHintScan) -> Option<&'a SlopDeskHintScan> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift face creates the handle, reads it, and frees it inside one function body.
    Some(unsafe { &*handle })
}

/// Scans `row_count` rows for every hintable target and hands back an owned result.
///
/// `rows`, `schemes`, `patterns` and `actions` each cross as a flat UTF-8 blob plus a length per
/// entry. `pattern_count` governs both pattern lists: entry `i` of `actions` is pattern `i`'s
/// template, and a length of `0` there means the pattern carries none. `max_scan_columns` of `0`
/// scans nothing rather than everything.
///
/// Never returns null: an empty scan is a real answer with zero records.
///
/// # Safety
/// Each `(ptr, len)` pair must be null or describe live memory for the whole call. The returned
/// handle must be freed exactly once with [`slopdesk_hint_scan_free`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
// Four flat blobs, each needing its pointer, its byte count and its length table. A struct would
// put the same fields behind a layout both sides then have to agree on, which is the thing an
// `(ptr, len)` argument list exists to avoid.
pub unsafe extern "C" fn slopdesk_hint_scan(
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
    patterns: *const c_uchar,
    patterns_len: usize,
    pattern_lengths: *const usize,
    actions: *const c_uchar,
    actions_len: usize,
    action_lengths: *const usize,
    pattern_count: usize,
    max_scan_columns: usize,
) -> *mut SlopDeskHintScan {
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
    // SAFETY: as above.
    let pattern_text = split(unsafe { borrow(patterns, patterns_len) }, unsafe {
        records_of(pattern_lengths, pattern_count)
    });
    // SAFETY: as above.
    let action_text = split(unsafe { borrow(actions, actions_len) }, unsafe {
        records_of(action_lengths, pattern_count)
    });
    let compiled: Vec<Pattern> = pattern_text
        .into_iter()
        .enumerate()
        .map(|(index, regex)| {
            Pattern {
                regex,
                action: action_text
                    .get(index)
                    .filter(|template| !template.is_empty())
                    .cloned(),
            }
        })
        .collect();

    let borrowed: Vec<&str> = row_text.iter().map(String::as_str).collect();
    let found = targets(
        &borrowed,
        if cwd_text.is_empty() {
            None
        } else {
            Some(&cwd_text)
        },
        &policy,
        &compiled,
        max_scan_columns,
    );

    let mut scan = SlopDeskHintScan {
        found: Vec::with_capacity(found.len()),
        arena: Vec::new(),
    };
    for target in &found {
        scan.push(target);
    }
    Box::into_raw(Box::new(scan))
}

/// Frees a scan. Null is a no-op; anything else must come from exactly one [`slopdesk_hint_scan`]
/// and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_hint_scan`] not yet freed, with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_hint_scan_free(handle: *mut SlopDeskHintScan) {
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
pub unsafe extern "C" fn slopdesk_hint_scan_counts(handle: *mut SlopDeskHintScan) -> SlopDeskHintCounts {
    // SAFETY: the caller's obligation, as above.
    let Some(scan) = (unsafe { held(handle) }) else {
        return SlopDeskHintCounts::EMPTY;
    };
    SlopDeskHintCounts {
        target_count: scan.found.len(),
        arena_length: scan.arena.len(),
    }
}

/// Reads one record.
///
/// An index past the end — or a null handle — answers a record whose kind is
/// `SLOPDESK_HINT_KIND_NONE`, so a caller that miscounts gets a defined non-target rather than a
/// fault or a plausible-looking zero span.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_hint_scan_target(
    handle: *mut SlopDeskHintScan,
    index: usize,
) -> SlopDeskHintTarget {
    // SAFETY: the caller's obligation, as above.
    let Some(scan) = (unsafe { held(handle) }) else {
        return SlopDeskHintTarget::NONE;
    };
    scan.found.get(index).copied().unwrap_or(SlopDeskHintTarget::NONE)
}

/// Copies the arena into the caller's buffer.
///
/// Returns the byte count the arena holds and writes nothing when that exceeds `cap`, following the
/// crate's sizing convention. Reading does not clear it; it lives until the handle is freed.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_hint_scan_take_arena(
    handle: *mut SlopDeskHintScan,
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

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_HINT_KIND_CUSTOM, SLOPDESK_HINT_KIND_GIT_HASH, SLOPDESK_HINT_KIND_LINK,
        SLOPDESK_HINT_KIND_NONE, SlopDeskHintScan, slopdesk_hint_scan, slopdesk_hint_scan_counts,
        slopdesk_hint_scan_free, slopdesk_hint_scan_take_arena, slopdesk_hint_scan_target,
    };
    use crate::link_detect::SLOPDESK_LINK_SCHEMES_ALL;

    /// Flattens strings the way the Swift face does: one blob, one length per entry.
    fn flatten(items: &[&str]) -> (Vec<u8>, Vec<usize>) {
        let mut blob = Vec::new();
        let mut lengths = Vec::new();
        for item in items {
            blob.extend_from_slice(item.as_bytes());
            lengths.push(item.len());
        }
        (blob, lengths)
    }

    /// One scan through the door, read back as `(kind, raw, action)` per record.
    fn scan(rows: &[&str], patterns: &[&str], actions: &[&str]) -> Vec<(u32, String, Option<String>)> {
        let (row_blob, row_lengths) = flatten(rows);
        let (pattern_blob, pattern_lengths) = flatten(patterns);
        let (action_blob, action_lengths) = flatten(actions);
        // SAFETY: every pointer names a live local for the duration of the call, and the handle is
        // freed exactly once below.
        let handle: *mut SlopDeskHintScan = unsafe {
            slopdesk_hint_scan(
                row_blob.as_ptr(),
                row_blob.len(),
                row_lengths.as_ptr(),
                row_lengths.len(),
                core::ptr::null(),
                0,
                SLOPDESK_LINK_SCHEMES_ALL,
                core::ptr::null(),
                0,
                core::ptr::null(),
                0,
                pattern_blob.as_ptr(),
                pattern_blob.len(),
                pattern_lengths.as_ptr(),
                action_blob.as_ptr(),
                action_blob.len(),
                action_lengths.as_ptr(),
                pattern_lengths.len(),
                4096,
            )
        };
        // SAFETY: the handle came from the call above and no other call is in flight.
        let counts = unsafe { slopdesk_hint_scan_counts(handle) };
        let mut arena = vec![0_u8; counts.arena_length];
        // SAFETY: as above; `out` is writable for exactly `arena_length` bytes.
        let written = unsafe { slopdesk_hint_scan_take_arena(handle, arena.as_mut_ptr(), arena.len()) };
        assert_eq!(written, counts.arena_length);
        // `crate::arena_text` rather than a reader spelled here: §4c has one read half, and a
        // second one written for a test is exactly how the eleven Swift copies drifted.
        let text = |offset: usize, length: usize| {
            crate::arena_text(
                &arena,
                u32::try_from(offset).unwrap_or(u32::MAX),
                u32::try_from(length).unwrap_or(0),
            )
        };
        let mut out = Vec::new();
        for index in 0..counts.target_count {
            // SAFETY: as above.
            let record = unsafe { slopdesk_hint_scan_target(handle, index) };
            out.push((
                record.kind,
                text(record.raw_offset, record.raw_length),
                record
                    .has_action
                    .then(|| text(record.action_offset, record.action_length)),
            ));
        }
        // SAFETY: the handle came from one scan and is freed exactly once, here.
        unsafe { slopdesk_hint_scan_free(handle) };
        out
    }

    #[test]
    fn the_four_kinds_cross_with_their_strings() {
        let found = scan(&["see https://x.com and deadbeef1"], &[], &[]);
        assert_eq!(found.len(), 2);
        assert_eq!(
            found.first().map(|record| record.0),
            Some(SLOPDESK_HINT_KIND_LINK)
        );
        assert_eq!(
            found.get(1).map(|record| record.0),
            Some(SLOPDESK_HINT_KIND_GIT_HASH)
        );
    }

    #[test]
    fn an_action_of_zero_length_is_no_action() {
        let found = scan(&["TICKET-9"], &["TICKET-[0-9]+"], &[""]);
        assert_eq!(
            found.first().map(|record| (record.0, record.2.clone())),
            Some((SLOPDESK_HINT_KIND_CUSTOM, None))
        );
        let found = scan(&["TICKET-9"], &["TICKET-[0-9]+"], &["open {0}"]);
        assert_eq!(
            found.first().and_then(|record| record.2.clone()),
            Some("open {0}".to_owned())
        );
    }

    #[test]
    fn a_null_handle_and_an_index_past_the_end_are_both_defined() {
        // SAFETY: a null handle is what every one of these documents as an answerable input.
        unsafe {
            assert_eq!(slopdesk_hint_scan_counts(core::ptr::null_mut()).target_count, 0);
            assert_eq!(
                slopdesk_hint_scan_target(core::ptr::null_mut(), 0).kind,
                SLOPDESK_HINT_KIND_NONE
            );
            assert_eq!(
                slopdesk_hint_scan_take_arena(core::ptr::null_mut(), core::ptr::null_mut(), 0),
                0
            );
            slopdesk_hint_scan_free(core::ptr::null_mut());
        }
    }
}
