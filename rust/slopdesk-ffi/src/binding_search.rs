//! The keybindings editor's search filter.
//!
//! One door over `slopdesk_workspace::binding_search`, and the whole point of it is that the caller
//! hands over EVERY row at once. The rows are lent rather than owned by the far side because a
//! binding's title and keywords are written beside the `WorkspaceAction` case they route to; see
//! that module's header for why they stay there and why the filter does not.
//!
//! The answer is POSITIONS in the lent list, the way `slopdesk_settings_row_matches` answers
//! positions in its own table — the same retry protocol, and the same reading of `0`.

use core::ffi::c_uchar;

use slopdesk_workspace::binding_search;

use crate::borrow;

/// The rows a query keeps, as POSITIONS in the lent record list; returns how many there are.
///
/// `records` is `[u32 count]` then `count` records, each `[u8 field_count]` then that many
/// `[u32 len][len bytes]` fields, little-endian. A binding row lends four: its title, its keyword
/// run, its chord's glyph and its chord's canonical spelling, the last two empty for a row with no
/// chord.
///
/// `needed > cap` means nothing was written — ask again at that size. `0` means no row matched,
/// which is also what a query that is not UTF-8 and a malformed record list answer: all three end
/// at an empty list, and the near side builds the list itself, so a fourth reading would be a
/// distinction no caller could act on.
///
/// # Safety
/// `(query, query_len)` and `(records, records_len)` must be readable for the call, and `(out,
/// cap)` writable for `cap` entries.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_binding_row_matches(
    query: *const c_uchar,
    query_len: usize,
    records: *const c_uchar,
    records_len: usize,
    out: *mut usize,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above.
    let asked = unsafe { borrow(query, query_len) };
    // SAFETY: the caller's obligation, restated above.
    let rows = unsafe { borrow(records, records_len) };
    let Ok(query) = core::str::from_utf8(asked) else {
        return 0;
    };
    let Ok(hits) = binding_search::matches(query, rows) else {
        return 0;
    };
    if hits.len() > cap || out.is_null() {
        return hits.len();
    }
    for (slot, index) in hits.iter().enumerate() {
        // SAFETY: `slot < hits.len() <= cap`, and the caller promised `cap` writable entries.
        unsafe { out.add(slot).write(*index) };
    }
    hits.len()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, and these blobs are the test's own"
)]
mod tests {
    use super::slopdesk_ws_binding_row_matches;

    /// The registry's four spellings per row, shaped like the ones Swift marshals.
    const ROWS: [[&str; 4]; 6] = [
        [
            "Split Right",
            "split column side vertical divider new pane",
            "⌘D",
            "cmd+d",
        ],
        [
            "Split Down",
            "split row stacked horizontal divider new pane below",
            "⌘⇧D",
            "cmd+shift+d",
        ],
        ["Close Pane", "quit kill end terminate remove", "⌘W", "cmd+w"],
        ["Rename Tab", "title label name tab", "", ""],
        ["New Tab", "create open fresh tab", "⌘T", "cmd+t"],
        ["Select Pane 1", "switch jump pane tab 1", "⌘1", "cmd+1"],
    ];

    /// Writes the blob exactly the way the Swift face does.
    fn blob(rows: &[[&str; 4]]) -> Vec<u8> {
        let mut out = u32::try_from(rows.len())
            .expect("a row count")
            .to_le_bytes()
            .to_vec();
        for row in rows {
            out.push(u8::try_from(row.len()).expect("a field count"));
            for field in row {
                let len = u32::try_from(field.len()).expect("a field length");
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(field.as_bytes());
            }
        }
        out
    }

    /// Asks through the door the way Swift does — size, then fill.
    fn ask(query: &str, rows: &[[&str; 4]]) -> Vec<usize> {
        let records = blob(rows);
        let q = query.as_bytes();
        // SAFETY: both slices are live for both calls, and the first lends no output at all.
        let needed = unsafe {
            slopdesk_ws_binding_row_matches(
                q.as_ptr(),
                q.len(),
                records.as_ptr(),
                records.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        let mut out = vec![usize::MAX; needed];
        // SAFETY: the same two slices, and `out` is this function's own with `needed` entries.
        let written = unsafe {
            slopdesk_ws_binding_row_matches(
                q.as_ptr(),
                q.len(),
                records.as_ptr(),
                records.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, needed, "the fill disagreed with the measure");
        out
    }

    #[test]
    fn the_whole_table_filters_in_one_crossing() {
        assert_eq!(ask("", &ROWS), vec![0, 1, 2, 3, 4, 5]);
        assert_eq!(ask("split", &ROWS), vec![0, 1]);
        assert_eq!(ask("cmd+t", &ROWS), vec![4]);
        assert_eq!(ask("⌘W", &ROWS), vec![2]);
        assert_eq!(ask("nothing here", &ROWS), Vec::<usize>::new());
    }

    /// THE ONE THAT KEEPS THE TWO CALLERS HONEST. A caller may ask about ONE row (`DeviceRowFilter`
    /// re-checking a row it already has) or about the whole table in one crossing; a batch that
    /// answered differently from the single-member call would show a row in the list that the row's
    /// own predicate says is filtered out. Walked over EVERY member against EVERY query the other
    /// members could be searched by.
    #[test]
    fn every_member_answers_the_same_alone_as_it_does_in_the_batch() {
        let mut checked = 0;
        let queries: Vec<String> = ROWS
            .iter()
            .flat_map(|row| row.iter())
            .flat_map(|field| {
                (0..=field.len())
                    .filter_map(|end| field.get(..end))
                    .map(str::to_owned)
                    .collect::<Vec<_>>()
            })
            .collect();
        for query in &queries {
            let batch = ask(query, &ROWS);
            for (index, row) in ROWS.iter().enumerate() {
                let alone = ask(query, core::slice::from_ref(row));
                assert_eq!(
                    alone == vec![0],
                    batch.contains(&index),
                    "row {index} disagreed with the batch on {query:?}"
                );
                checked += 1;
            }
        }
        assert!(checked > 1000, "the walk covered {checked} pairs");
    }

    #[test]
    fn a_short_buffer_writes_nothing_and_reports_what_it_needed() {
        let records = blob(&ROWS);
        let q = b"";
        let mut out = [usize::MAX; 6];
        // SAFETY: both slices are live and `out` is the caller's own, deliberately lent short.
        let needed = unsafe {
            slopdesk_ws_binding_row_matches(
                q.as_ptr(),
                0,
                records.as_ptr(),
                records.len(),
                out.as_mut_ptr(),
                3,
            )
        };
        assert_eq!(needed, 6, "it reports what the answer needs");
        assert_eq!(out, [usize::MAX; 6], "and it wrote nothing");
    }

    #[test]
    fn a_query_that_is_not_utf8_and_a_torn_record_list_both_match_nothing() {
        let records = blob(&ROWS);
        let bad = [0xFF_u8, 0xFE];
        // SAFETY: both slices are live for the call and no output is lent.
        let hits = unsafe {
            slopdesk_ws_binding_row_matches(
                bad.as_ptr(),
                bad.len(),
                records.as_ptr(),
                records.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(hits, 0);
        let torn = &records[..records.len() - 1];
        let q = b"split";
        // SAFETY: both slices are live for the call and no output is lent.
        let cut = unsafe {
            slopdesk_ws_binding_row_matches(
                q.as_ptr(),
                q.len(),
                torn.as_ptr(),
                torn.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(cut, 0, "a torn list is refused whole");
    }

    #[test]
    fn a_null_record_list_is_an_empty_one() {
        let q = b"split";
        // SAFETY: the query is live; a null record pointer with length 0 is the documented empty
        // pair.
        let hits = unsafe {
            slopdesk_ws_binding_row_matches(
                q.as_ptr(),
                q.len(),
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(hits, 0);
    }
}
