//! Which detected span a point lands on, in C —
//! `Sources/SlopDeskWorkspaceCore/Terminal/TerminalLinkHitTest.swift`.
//!
//! The rule is [`slopdesk_terminal::link_hit`]; what is here is the marshalling. It is the shortest
//! trip this crate makes, because the thing being asked about never has to travel: the caller is
//! holding an array of `DetectedLink`s that [`crate::link_detect`] handed it moments earlier, so
//! what crosses is the three numbers per span the rule measures — row, first cell, one past the
//! last — and what comes back is an INDEX into the array the caller already has. No record is
//! rebuilt, no string is copied, and the near side reads `resolvedAbsolute ?? raw` off its own
//! value the way it always did.
//!
//! ## Why the spans are one flat array
//!
//! Same argument as [`crate::link_detect`]'s rows: the caller has to build something contiguous for
//! the boundary either way, and one buffer of `size_t` triples means one pointer, one lifetime and
//! one bounds rule instead of `span_count` of each. The triple is `(row, col_start, col_end)` in
//! that order, and `span_count` counts SPANS rather than values — so the door reads exactly three
//! times as many, never the tail of a longer buffer, and a count whose triples would wrap the
//! address space is refused before anything is read at all.
//!
//! ## The two answers, and why only one of them is a sentinel
//!
//! [`slopdesk_link_hit_span`] answers `-1` for "the point is over nothing". That is admissible for
//! the reason `docs/55` gives for `slopdesk_fuzzy_rank`'s `-1`: the answer's range is an index into
//! the CALLER'S array, so it is `0..span_count` by construction, and no negative value can be one.
//! A slice cannot hold more than `isize::MAX` elements either, so the top of the range cannot reach
//! the sentinel from the other side.
//!
//! [`slopdesk_link_hit_cell`] cannot use one. Its answer is a `(row, column)` pair and cell `(0,
//! 0)` is the most ordinary landing a point has, so `0` is a real answer on both axes and there is
//! no value outside the range to spend. It therefore takes the shape `docs/55` §4 asks for when a
//! sentinel is not available by construction — a VALUE plus a FLAG, returned by value as a small
//! `#[repr(C)]` record, with the flag read first.

use slopdesk_terminal::link_hit::{CellMetrics, LinkSpan, cell, link};

use crate::records_of;

/// The answer to "the point is over no span at all".
///
/// Outside the answer's range by construction — see the module docs.
pub const SLOPDESK_LINK_HIT_NONE: isize = -1;

/// How many `size_t` values one span occupies in the packed array: row, `col_start`, `col_end`.
const SPAN_STRIDE: usize = 3;

/// The grid cell under a point, as a value plus the flag that says whether there is one.
///
/// Widest field first, so the layout has no padding for the hand-written header to transcribe.
/// `row` and `column` are untouched when `hit` is false, and reading them then is the one mistake
/// this shape exists to make visible rather than plausible.
#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct SlopDeskLinkCell {
    /// 0-based row, counting down from the viewport's top edge. Read only when `hit`.
    pub row: usize,
    /// 0-based display-cell column, counting right from the viewport's left edge. Read only when
    /// `hit`.
    pub column: usize,
    /// Whether the geometry could answer at all.
    pub hit: bool,
}

/// The metrics four scalars describe, assembled once so both doors spell the order the same way.
const fn metrics_of(cell_width: f64, cell_height: f64, origin_x: f64, origin_y: f64) -> CellMetrics {
    CellMetrics {
        cell_width,
        cell_height,
        origin_x,
        origin_y,
    }
}

/// The 0-based grid cell under a top-left-origin point in POINTS.
///
/// `hit` is false for a degenerate cell size, for a point above or left of the viewport origin, and
/// for a ratio that is not finite — three refusals the caller treats as one, which is why they are
/// one flag and not a taxonomy.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_link_hit_cell(
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
    point_x: f64,
    point_y: f64,
) -> SlopDeskLinkCell {
    let metrics = metrics_of(cell_width, cell_height, origin_x, origin_y);
    cell(metrics, point_x, point_y).map_or(
        SlopDeskLinkCell {
            row: 0,
            column: 0,
            hit: false,
        },
        |found| {
            SlopDeskLinkCell {
                row: found.row,
                column: found.column,
                hit: true,
            }
        },
    )
}

/// The index of the span under a top-left-origin point, or [`SLOPDESK_LINK_HIT_NONE`].
///
/// `spans` holds `span_count` triples of `(row, col_start, col_end)`; `slop` is how far off a span
/// the point may be and still count, in points, and `0` is the exact cell hit-test a pointer wants.
///
/// # Safety
/// `spans` must be null, or readable for `span_count * 3` `size_t` values for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `spans` is the caller's array"
)]
pub unsafe extern "C" fn slopdesk_link_hit_span(
    spans: *const usize,
    span_count: usize,
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
    point_x: f64,
    point_y: f64,
    slop: f64,
) -> isize {
    // A count whose triples cannot be counted describes no array anyone could have built, so it is
    // refused here rather than allowed to wrap into a short one.
    let Some(flat_len) = span_count.checked_mul(SPAN_STRIDE) else {
        return SLOPDESK_LINK_HIT_NONE;
    };
    // SAFETY: the caller's contract, and `records_of` answers an empty slice for a null pointer.
    let flat = unsafe { records_of::<usize>(spans, flat_len) };
    // One small `Vec` per call, on a path whose other door already builds an arena and a string per
    // detected span: the alternative is a layout promise from the domain crate about a type whose
    // shape is nobody's business but the rule's.
    let spans: Vec<LinkSpan> = flat
        .as_chunks::<SPAN_STRIDE>()
        .0
        .iter()
        .map(|[row, col_start, col_end]| {
            LinkSpan {
                row: *row,
                col_start: *col_start,
                col_end: *col_end,
            }
        })
        .collect();
    let metrics = metrics_of(cell_width, cell_height, origin_x, origin_y);
    let Some(index) = link(&spans, metrics, point_x, point_y, slop) else {
        return SLOPDESK_LINK_HIT_NONE;
    };
    // An index into a slice is below `isize::MAX` by construction; the fallible conversion is here
    // so that stays a fact the compiler checks rather than one this comment asserts.
    isize::try_from(index).unwrap_or(SLOPDESK_LINK_HIT_NONE)
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{SLOPDESK_LINK_HIT_NONE, slopdesk_link_hit_cell, slopdesk_link_hit_span};

    /// The face the Swift suite measures against: a 10 × 20 point cell at the view's origin.
    const CELL_WIDTH: f64 = 10.0;
    const CELL_HEIGHT: f64 = 20.0;

    /// `"see /usr/local/bin"` scans to one span on row 0 covering cells 4..<18 — x in [40, 180).
    const PATH_SPAN: [usize; 3] = [0, 4, 18];

    /// The same span with a second on row 1 behind it, cells 3..<12 — x in [30, 120), y in [20,
    /// 40).
    const TWO_SPANS: [usize; 6] = [0, 4, 18, 1, 3, 12];

    fn hit(spans: &[usize], count: usize, point_x: f64, point_y: f64, slop: f64) -> isize {
        // SAFETY: the array is a live local for the length of the call.
        unsafe {
            slopdesk_link_hit_span(
                spans.as_ptr(),
                count,
                CELL_WIDTH,
                CELL_HEIGHT,
                0.0,
                0.0,
                point_x,
                point_y,
                slop,
            )
        }
    }

    #[test]
    fn the_cell_door_answers_a_pair_and_a_flag_rather_than_a_magic_row() {
        let inside = slopdesk_link_hit_cell(CELL_WIDTH, CELL_HEIGHT, 0.0, 0.0, 65.0, 25.0);
        assert!(inside.hit);
        assert_eq!((inside.row, inside.column), (1, 6));
        // Cell (0, 0) is a real answer, which is the whole reason the flag exists.
        let origin = slopdesk_link_hit_cell(CELL_WIDTH, CELL_HEIGHT, 0.0, 0.0, 0.0, 0.0);
        assert!(origin.hit);
        assert_eq!((origin.row, origin.column), (0, 0));
        let outside = slopdesk_link_hit_cell(CELL_WIDTH, CELL_HEIGHT, 0.0, 0.0, -1.0, 5.0);
        assert!(!outside.hit);
        let degenerate = slopdesk_link_hit_cell(0.0, 0.0, 0.0, 0.0, 65.0, 5.0);
        assert!(!degenerate.hit);
    }

    #[test]
    fn the_span_door_answers_the_callers_own_index() {
        assert_eq!(hit(&TWO_SPANS, 2, 65.0, 5.0, 0.0), 0);
        assert_eq!(
            hit(&TWO_SPANS, 2, 55.0, 25.0, 0.0),
            1,
            "the second triple is the second row"
        );
        assert_eq!(hit(&TWO_SPANS, 2, 185.0, 5.0, 0.0), SLOPDESK_LINK_HIT_NONE);
    }

    #[test]
    fn the_slop_crosses_as_a_number_and_zero_is_the_exact_reading() {
        let spans = PATH_SPAN;
        assert_eq!(hit(&spans, 1, 185.0, 5.0, 0.0), SLOPDESK_LINK_HIT_NONE);
        assert_eq!(hit(&spans, 1, 185.0, 5.0, 15.0), 0);
        assert_eq!(hit(&spans, 1, 200.0, 5.0, 15.0), SLOPDESK_LINK_HIT_NONE);
    }

    #[test]
    fn an_empty_or_absent_array_is_a_miss_rather_than_a_read() {
        assert_eq!(hit(&[], 0, 65.0, 5.0, 40.0), SLOPDESK_LINK_HIT_NONE);
        // SAFETY: a null pointer is one of the two shapes the contract admits.
        let null = unsafe {
            slopdesk_link_hit_span(
                core::ptr::null(),
                4,
                CELL_WIDTH,
                CELL_HEIGHT,
                0.0,
                0.0,
                65.0,
                5.0,
                40.0,
            )
        };
        assert_eq!(null, SLOPDESK_LINK_HIT_NONE);
    }

    #[test]
    fn a_count_whose_triples_would_wrap_is_refused_before_anything_is_read() {
        let spans = PATH_SPAN;
        assert_eq!(
            hit(&spans, usize::MAX, 65.0, 5.0, 0.0),
            SLOPDESK_LINK_HIT_NONE,
            "the multiply is checked, so a hostile count cannot become a short one",
        );
    }

    #[test]
    fn a_buffer_longer_than_the_count_is_read_only_as_far_as_the_count() {
        // The count is what says how much of the caller's array is a span list. A door that read to
        // the end of what it was handed would answer with an index the caller cannot use.
        assert_eq!(hit(&TWO_SPANS, 1, 55.0, 25.0, 0.0), SLOPDESK_LINK_HIT_NONE);
        assert_eq!(hit(&TWO_SPANS, 2, 55.0, 25.0, 0.0), 1);
    }
}
