//! Find-in-terminal's matches, in C.
//!
//! One §4 entry over [`slopdesk_rowscan::find::matches`], not §4b's handle. The link and hint scans
//! need a handle because their records carry STRINGS, and a string has no size until the scan runs;
//! a match here is three numbers, so the whole answer is a fixed-stride array and the usual
//! size-then-read retry is enough.
//!
//! ## The count is in the answer, not in the return
//!
//! `[u32 count]` leads the blob so that ZERO matches is 4 bytes rather than 0 — and 0 from a §4
//! entry means "no answer", which a find bar reaches on every keystroke that has not matched
//! anything yet. A caller must be able to tell "nothing matched" from "ask again", and inferring
//! the count from `needed / 12` would make those the same number.
//!
//! ## Columns are UTF-16 units
//!
//! The crate counts them, not this door. The caller highlights a match by handing the column to a
//! surface that indexes in UTF-16, and converting on the way out would mean a second walk over the
//! same line, in the caller, per match.

use core::ffi::c_uchar;

use slopdesk_rowscan::find::matches;

use crate::link_detect::split;
use crate::{borrow, deliver, records_of};

/// `[u32 BE line][u32 BE column][u32 BE length]`.
const RECORD: usize = 12;

/// Every match of `query` in `row_count` rows, ordered by row then column.
///
/// `rows`/`row_lengths` are the flat UTF-8 blob and its per-row byte counts, the same shape the
/// link and hint scans take. The answer is `[u32 BE count]` followed by `count` records of
/// `[u32 BE line][u32 BE column][u32 BE length]`, all big-endian.
///
/// An empty query, or a regex that does not compile, answers a count of zero — both are states a
/// find field passes through on its way to a real pattern, and neither is an error.
///
/// # Safety
/// Each `(ptr, len)` pair must be null or describe live memory for the whole call, and `out` must
/// be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_find_matches(
    rows: *const c_uchar,
    rows_len: usize,
    row_lengths: *const usize,
    row_count: usize,
    query: *const c_uchar,
    query_len: usize,
    case_sensitive: bool,
    is_regex: bool,
    whole_word: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: every pair is null or live for the call by the caller's obligation, discharged on the
    // Swift side by `withUnsafeBufferPointer`, whose scope is exactly this call.
    let row_text = split(unsafe { borrow(rows, rows_len) }, unsafe {
        records_of(row_lengths, row_count)
    });
    // SAFETY: as above.
    let needle = String::from_utf8_lossy(unsafe { borrow(query, query_len) }).into_owned();
    let borrowed: Vec<&str> = row_text.iter().map(String::as_str).collect();
    let found = matches(&borrowed, &needle, case_sensitive, is_regex, whole_word);

    let mut blob = Vec::with_capacity(4_usize.saturating_add(found.len().saturating_mul(RECORD)));
    blob.extend_from_slice(&count(found.len()).to_be_bytes());
    for hit in &found {
        blob.extend_from_slice(&count(hit.line).to_be_bytes());
        blob.extend_from_slice(&count(hit.column).to_be_bytes());
        blob.extend_from_slice(&count(hit.length).to_be_bytes());
    }
    // SAFETY: `out` is null or writable for `cap` bytes by the caller's obligation, and `blob` is a
    // live local that cannot overlap it.
    unsafe { deliver(&blob, out, cap) }
}

/// A count as the `u32` the blob spells it in, saturating rather than wrapping — a scrollback with
/// four billion rows is not a shape this has to encode, and a wrap would name the wrong row.
fn count(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{RECORD, slopdesk_find_matches};

    /// One scan through the door, decoded back to `(line, column, length)`.
    fn scan(rows: &[&str], query: &str, is_regex: bool, whole_word: bool) -> Vec<(u32, u32, u32)> {
        let mut blob = Vec::new();
        let mut lengths = Vec::new();
        for row in rows {
            blob.extend_from_slice(row.as_bytes());
            lengths.push(row.len());
        }
        let call = |out: *mut u8, cap: usize| {
            // SAFETY: every pointer names a live local for the duration of the call.
            unsafe {
                slopdesk_find_matches(
                    blob.as_ptr(),
                    blob.len(),
                    lengths.as_ptr(),
                    lengths.len(),
                    query.as_ptr(),
                    query.len(),
                    false,
                    is_regex,
                    whole_word,
                    out,
                    cap,
                )
            }
        };
        let needed = call(core::ptr::null_mut(), 0);
        let mut answer = vec![0_u8; needed];
        let written = call(answer.as_mut_ptr(), answer.len());
        assert_eq!(written, needed, "the sizing call and the filling call must agree");
        let word = |at: usize| {
            answer
                .get(at..at + 4)
                .and_then(|bytes| <[u8; 4]>::try_from(bytes).ok())
                .map_or(0, u32::from_be_bytes)
        };
        let total = word(0) as usize;
        (0..total)
            .map(|index| {
                let at = 4 + index * RECORD;
                (word(at), word(at + 4), word(at + 8))
            })
            .collect()
    }

    #[test]
    fn no_matches_is_four_bytes_and_not_a_refusal() {
        let rows = ["nothing here"];
        let blob: Vec<u8> = rows.concat().into_bytes();
        let lengths = [rows[0].len()];
        let query = "zzz";
        // SAFETY: every pointer names a live local for the duration of the call.
        let needed = unsafe {
            slopdesk_find_matches(
                blob.as_ptr(),
                blob.len(),
                lengths.as_ptr(),
                lengths.len(),
                query.as_ptr(),
                query.len(),
                false,
                false,
                false,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 4, "a count of zero, not the §4 refusal");
    }

    #[test]
    fn the_records_cross_in_reading_order() {
        assert_eq!(scan(&["x x", "x"], "x", false, false), vec![
            (0, 0, 1),
            (0, 2, 1),
            (1, 0, 1)
        ]);
    }

    #[test]
    fn the_three_modes_cross_as_themselves() {
        assert_eq!(scan(&["the theory"], "the", false, false).len(), 2);
        assert_eq!(scan(&["the theory"], "the", false, true).len(), 1, "whole word");
        assert_eq!(scan(&["the theory"], "th.", true, false).len(), 2, "regex");
        assert!(
            scan(&["the theory"], "([unclosed", true, false).is_empty(),
            "invalid pattern"
        );
    }
}
