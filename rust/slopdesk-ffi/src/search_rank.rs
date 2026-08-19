//! The one ranking every search field in the app asks for.
//!
//! The rule is `slopdesk_workspace::search_rank`; what is here is the marshalling. A candidate's
//! fields cross as spans into one blob, `stride` of them per candidate in priority order, so a
//! caller with one searchable field and a caller with three use the same door with a different
//! number rather than two doors with the same body.
//!
//! ## Two answers, one call
//!
//! The ranking comes back as placements in the caller's own indices, and the highlight comes back
//! as a flat run of scalar offsets those placements point into. They are one call because they are
//! one pass: the matcher backtraces while its alignment matrix is still filled, and asking for the
//! underline afterwards would mean scoring every title a second time on every keystroke.

use core::ffi::c_uchar;

use slopdesk_workspace::search_rank;

use crate::borrow;
use crate::workspace::{Span, borrow_array, text_of};

/// The shape of one ranking request — the numbers, where the strings ride separately.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CSearchRankInputs {
    /// How many candidates the `fields` array describes.
    pub candidate_count: usize,
    /// How many fields each candidate carries, in priority order. `0` answers nothing.
    pub stride: usize,
    /// Whether `positions_tier` means anything. False asks for no highlight at all, which skips
    /// every backtrace.
    pub positions_wanted: bool,
    /// The ONE field the caller will underline; only rows that matched it carry positions.
    pub positions_tier: usize,
}

/// Where one candidate placed.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CSearchRanked {
    /// The candidate's index in the list the caller passed in.
    pub candidate: usize,
    /// Which of its fields matched; 0 is the most important and a lower tier always wins.
    pub tier: usize,
    /// The fzf score within that tier.
    pub score: i32,
    /// Where this row's highlight starts in the `positions` array.
    pub position_offset: usize,
    /// How many scalar offsets it runs for; `0` for a row nothing underlines.
    pub position_count: usize,
}

/// Every candidate that matches `query`, best first.
///
/// Returns how many rows matched. A `cap` or a `positions_cap` too small for the answer leaves BOTH
/// buffers untouched and still reports both sizes, so one §4-shaped retry with the two numbers is
/// always enough.
///
/// # Safety
/// `fields` must be null or point to `candidate_count * stride` live [`Span`]s; `strings` null or
/// `strings_len` initialised bytes; `query` null or `query_len` initialised bytes; `out` null or
/// writable for `cap` [`CSearchRanked`]s; `positions` null or writable for `positions_cap` `u32`s;
/// `positions_needed` null or one writable `usize`. All live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_ws_search_rank(
    inputs: CSearchRankInputs,
    fields: *const Span,
    strings: *const c_uchar,
    strings_len: usize,
    query: *const c_uchar,
    query_len: usize,
    out: *mut CSearchRanked,
    cap: usize,
    positions: *mut u32,
    positions_cap: usize,
    positions_needed: *mut usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; the helpers state their own.
    unsafe {
        let blob = borrow(strings, strings_len);
        let needle = core::str::from_utf8(borrow(query, query_len)).unwrap_or_default();
        let held: Vec<Option<&str>> =
            borrow_array(fields, inputs.candidate_count.saturating_mul(inputs.stride))
                .iter()
                .map(|span| text_of(*span, blob))
                .collect();
        let ranked = search_rank::rank(
            &held,
            inputs.stride,
            needle,
            inputs.positions_wanted.then_some(inputs.positions_tier),
        );
        let runs: usize = ranked.iter().map(|found| found.positions.len()).sum();
        if !positions_needed.is_null() {
            positions_needed.write(runs);
        }
        if out.is_null() || cap < ranked.len() || positions.is_null() && runs > 0 || positions_cap < runs {
            return ranked.len();
        }
        let mut cursor = 0_usize;
        for (index, found) in ranked.iter().enumerate() {
            for (step, offset) in found.positions.iter().enumerate() {
                // SAFETY: `cursor + step` stays below `runs`, which is at most `positions_cap`.
                positions.add(cursor + step).write(*offset);
            }
            // SAFETY: `index` is below `ranked.len()`, which is at most `cap`.
            out.add(index).write(CSearchRanked {
                candidate: found.candidate,
                tier: found.tier,
                score: found.score,
                position_offset: cursor,
                position_count: found.positions.len(),
            });
            cursor += found.positions.len();
        }
        ranked.len()
    }
}

/// The most rows a search field hands back, however many matched.
///
/// Asked for rather than transcribed: a copy that drifted would let one surface build rows the one
/// beside it capped away.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_max_search_results() -> usize {
    search_rank::MAX_SEARCH_RESULTS
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{CSearchRankInputs, CSearchRanked, slopdesk_ws_max_search_results, slopdesk_ws_search_rank};
    use crate::workspace::Span;

    #[derive(Default)]
    struct Blob {
        bytes: Vec<u8>,
    }

    impl Blob {
        fn span(&mut self, text: Option<&str>) -> Span {
            let Some(text) = text else {
                return Span {
                    offset: 0,
                    len: 0,
                    present: false,
                };
            };
            let offset = self.bytes.len();
            self.bytes.extend_from_slice(text.as_bytes());
            Span {
                offset,
                len: text.len(),
                present: true,
            }
        }
    }

    /// Ranks a three-field list, answering `(placements, positions)`.
    fn ranked(rows: &[[Option<&str>; 3]], query: &str) -> (Vec<CSearchRanked>, Vec<u32>) {
        let mut blob = Blob::default();
        let fields: Vec<Span> = rows.iter().flatten().map(|field| blob.span(*field)).collect();
        let inputs = CSearchRankInputs {
            candidate_count: rows.len(),
            stride: 3,
            positions_wanted: true,
            positions_tier: 0,
        };
        let mut out = vec![
            CSearchRanked {
                candidate: 0,
                tier: 0,
                score: 0,
                position_offset: 0,
                position_count: 0,
            };
            rows.len()
        ];
        let mut positions = vec![0_u32; rows.len() * query.len().max(1)];
        let mut needed = 0_usize;
        // SAFETY: five live local buffers, borrowed for the duration of the call.
        let count = unsafe {
            slopdesk_ws_search_rank(
                inputs,
                fields.as_ptr(),
                blob.bytes.as_ptr(),
                blob.bytes.len(),
                query.as_ptr(),
                query.len(),
                out.as_mut_ptr(),
                out.len(),
                positions.as_mut_ptr(),
                positions.len(),
                &raw mut needed,
            )
        };
        out.truncate(count);
        positions.truncate(needed);
        (out, positions)
    }

    #[test]
    fn the_tier_rides_the_answer_and_the_highlight_points_into_the_run() {
        let (placed, positions) = ranked(
            &[
                [Some("Reload Custom Keymap"), None, None],
                [Some("Split Right"), Some("lock"), None],
                [Some("Read Only"), None, Some("lock freeze")],
            ],
            "lock",
        );
        assert_eq!(
            placed
                .iter()
                .map(|row| (row.candidate, row.tier))
                .collect::<Vec<_>>(),
            [(0, 0), (1, 1), (2, 2)],
            "title, then subtitle, then the hidden synonym"
        );
        assert_eq!(
            placed
                .iter()
                .map(|row| (row.position_offset, row.position_count))
                .collect::<Vec<_>>(),
            [(0, 4), (4, 0), (4, 0)],
            "only the title row carries a highlight, and the others point past it"
        );
        assert_eq!(positions.len(), 4, "one offset per query scalar");
    }

    #[test]
    fn a_short_buffer_reports_both_sizes_and_writes_neither() {
        let mut blob = Blob::default();
        let fields = [blob.span(Some("make check")), blob.span(Some("make"))];
        let inputs = CSearchRankInputs {
            candidate_count: 2,
            stride: 1,
            positions_wanted: true,
            positions_tier: 0,
        };
        let mut out = [CSearchRanked {
            candidate: 9,
            tier: 9,
            score: 0,
            position_offset: 0,
            position_count: 0,
        }; 1];
        let mut needed = 0_usize;
        // SAFETY: four live local buffers, borrowed for the duration of the call.
        let count = unsafe {
            slopdesk_ws_search_rank(
                inputs,
                fields.as_ptr(),
                blob.bytes.as_ptr(),
                blob.bytes.len(),
                b"make".as_ptr(),
                4,
                out.as_mut_ptr(),
                out.len(),
                core::ptr::null_mut(),
                0,
                &raw mut needed,
            )
        };
        assert_eq!(count, 2, "both matched");
        assert_eq!(needed, 8, "four offsets each");
        assert_eq!(out[0].candidate, 9, "and nothing was written");
    }

    #[test]
    fn the_cap_comes_from_the_crate() {
        assert_eq!(slopdesk_ws_max_search_results(), 250);
    }
}
