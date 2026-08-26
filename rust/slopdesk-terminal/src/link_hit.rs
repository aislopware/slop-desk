//! Which detected span a point lands on — the one hit-test a cursor and a fingertip both run.
//!
//! ## Why the rule belongs beside the record and not beside the view
//!
//! [`DetectedLink`] is already this crate's. [`crate::link::detect`] mints it, the boundary hands
//! it over as `(row, col_start, col_end)` plus two arena spans, and the Swift face reassembles the
//! record on the far side. So the question "which of these did the user point at" was arithmetic
//! over a value this crate had produced one call earlier, asked in the language that merely
//! received it — the arrangement `docs/55` names when it explains why `ChannelTable`'s routing rule
//! stopped being Swift: a rule kept apart from the state it reasons about is the arrangement that
//! lets one of them be edited alone. `col_end` is exclusive here because it is exclusive in the
//! scan, and nothing but this module and [`crate::link`] should ever have to know that.
//!
//! ## Two passes, and the order is the whole contract
//!
//! 1. **The exact cell.** The first span in the scan's own row-major order whose half-open column
//!    range contains the cell wins. With `slop` at zero this is the ONLY pass, so a pointer's
//!    reading is unchanged by the existence of the second one.
//! 2. **Within `slop` points**, when a positive one is given and the exact cell hit nothing: the
//!    NEAREST span whose rect is within `slop` on both axes, measured vertically first because a
//!    row is the coarser mistake a finger makes. A point above or left of the viewport origin is
//!    eligible here even though pass 1 dropped it — that is exactly the finger that landed a hair
//!    off the first row.
//!
//! A pointer is one pixel and lands where it is aimed; a fingertip is a contact patch tens of
//! points wide whose reported centre is a guess, and the phone gets ONE shot at the question, on
//! the release of a long press, with no hover to correct it. That is why the slop is a parameter
//! rather than a constant: the Mac passes zero and keeps its exact reading, the phone passes its
//! own touch number, and neither has to know the other's.
//!
//! ## Why the distance is a PAIR
//!
//! Collapsing "how far off vertically" and "how far off horizontally" into one number needs a
//! weighting nobody can defend. A pair needs none: it orders the two mistakes in the order a finger
//! makes them, and `<=` against the running best keeps the EARLIER span on a tie, which is pass 1's
//! row-major order carried into pass 2 so the two passes cannot answer differently about which of
//! two equally-good spans is "the" one.
//!
//! ## The span rect is [`crate::geometry`]'s, and that pair is CLOSED
//!
//! This module used to carry its own `span_rect` — the same two multiplies and two adds
//! `TerminalCellMetrics.rect(row:colStart:colEnd:)` spelled in Swift — and recorded the pair here
//! as `docs/55` §8's drift class, deferred because facing `rect` would have put the shim into a
//! target whose whole dependency list was `SlopDeskProtocol`.
//!
//! That is settled. `SlopDeskTerminal` links `CSlopDeskFFI` now, `rect` is [`geometry::rect`] and
//! the Swift is its face, and [`span_rect`] below calls the same function the underline and the
//! hint labels draw with. One implementation, and the hit-test measures against exactly the
//! rectangle the user can see.
//!
//! ## Bit-exact, deliberately
//!
//! `a * b + c` stays a separate `*` and `+` (never `mul_add`: FMA rounds once where the view
//! geometry rounds twice), and the clamp is [`f64::max`] in the same nesting order the Swift
//! `CGFloat.maximum(CGFloat.maximum(a, b), 0)` used — never a `<` ternary, which disagrees with it
//! about NaN. This is view geometry rather than the codec cluster, but `CLAUDE.md`'s habit is kept
//! for the reason the habit exists: the numbers are pinned by hand-computed test cases, and a fused
//! multiply-add moves the last bit of one of them without failing anything else.
//!
//! ## Total over hostile geometry
//!
//! Every input here can be a number a layout pass produced under duress — a zero cell size before
//! the first layout, a point off an unbounded scroll view. The guards are written in the POSITIVE
//! (`width > 0`, not `!(width <= 0)`) so a NaN falls out as "no hit" the way Swift's `guard` did,
//! and the truncation refuses a non-finite ratio outright: Swift's `Int(_:)` TRAPS on a NaN or an
//! out-of-range double, and a trap on this side of the boundary is an abort of the whole client,
//! since the release profile that reaches C is `panic = "abort"`.

/// The live cell geometry a hit-test measures against — [`crate::geometry::CellMetrics`],
/// re-exported so a caller that only imports this module keeps its old spelling.
///
/// It used to be declared here. Measuring where a point IS and computing where a span DRAWS turned
/// out to want the same four numbers, and two structs with identical fields would have been the
/// same drift the pair below closed, one level up.
pub use crate::geometry::CellMetrics;
use crate::geometry::{self, Rect};
use crate::link::DetectedLink;

/// The 0-based grid cell under a point.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    /// Row, counting down from the viewport's top edge.
    pub row: usize,
    /// Display-cell column, counting right from the viewport's left edge.
    pub column: usize,
}

/// One candidate span, as the hit-test reads it: a row and a half-open column range.
///
/// The hit-test needs three numbers out of a [`DetectedLink`] and none of its text, so this is what
/// crosses when the caller is asking on behalf of an array it already holds. The answer is then an
/// INDEX into that array and no record has to travel back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkSpan {
    /// Index into the rows that were scanned — the same row the metrics describe.
    pub row: usize,
    /// First display cell of the span.
    pub col_start: usize,
    /// One past the last display cell.
    pub col_end: usize,
}

impl From<&DetectedLink> for LinkSpan {
    /// The three fields of a detected span the hit-test measures, and nothing else.
    fn from(link: &DetectedLink) -> Self {
        Self {
            row: link.row,
            col_start: link.col_start,
            col_end: link.col_end,
        }
    }
}

/// The 0-based cell under a top-left-origin point, or `None` for geometry that cannot answer.
///
/// `None` covers three refusals that are one answer to a caller: a degenerate cell size (nothing
/// can divide), a point above or left of the viewport origin (dropped rather than force-floored to
/// cell 0, so a hover an inch above the terminal does not light up its first row), and a ratio that
/// is not finite.
#[must_use]
pub fn cell(metrics: CellMetrics, point_x: f64, point_y: f64) -> Option<Cell> {
    // Positive form on purpose: `!(cell_width <= 0.0)` would let a NaN width through, where Swift's
    // `guard metrics.cellWidth > 0` dropped it. Same for the origin test below.
    let divisible = metrics.cell_width > 0.0 && metrics.cell_height > 0.0;
    if !divisible {
        return None;
    }
    let inside = point_x >= metrics.origin_x && point_y >= metrics.origin_y;
    if !inside {
        return None;
    }
    let column = floor_cell((point_x - metrics.origin_x) / metrics.cell_width)?;
    let row = floor_cell((point_y - metrics.origin_y) / metrics.cell_height)?;
    Some(Cell { row, column })
}

/// The index in `spans` under a top-left-origin point, or `None` when the point is over none.
///
/// `spans` is read in the order given, which is the scan's row-major order, and both passes prefer
/// the earlier entry — see the module docs for why that is the contract rather than an accident.
/// `slop` is how far off a span the point may be and still count, in points; `0` is an exact cell
/// hit-test and is what a pointer passes.
#[must_use]
pub fn link(
    spans: &[LinkSpan],
    metrics: CellMetrics,
    point_x: f64,
    point_y: f64,
    slop: f64,
) -> Option<usize> {
    if let Some(hit) = cell(metrics, point_x, point_y) {
        let exact = spans
            .iter()
            .position(|span| span.row == hit.row && (span.col_start..span.col_end).contains(&hit.column));
        if exact.is_some() {
            return exact;
        }
    }
    // The widened pass needs a divisible grid too, even though it never divides: a grid with no
    // cells has no spans to be NEAR, and every rect it could measure would be a degenerate point.
    let widened = slop > 0.0 && metrics.cell_width > 0.0 && metrics.cell_height > 0.0;
    if !widened {
        return None;
    }
    let mut best: Option<(usize, f64, f64)> = None;
    for (index, span) in spans.iter().enumerate() {
        let rect = span_rect(metrics, *span);
        // The clamp `CGFloat.maximum(CGFloat.maximum(near, far), 0)`, in its own order: a point
        // inside the span's extent on this axis is zero away from it, not negatively away.
        let dx = f64::max(f64::max(rect.min_x() - point_x, point_x - rect.max_x()), 0.0);
        let dy = f64::max(f64::max(rect.min_y() - point_y, point_y - rect.max_y()), 0.0);
        let within = dx <= slop && dy <= slop;
        if !within {
            continue;
        }
        // `<=` keeps the running best, so a tie keeps the EARLIER span.
        if best.is_some_and(|(_, best_dy, best_dx)| (best_dy, best_dx) <= (dy, dx)) {
            continue;
        }
        best = Some((index, dy, dx));
    }
    best.map(|(index, ..)| index)
}

/// Where a `(row, col_start..col_end)` span sits, in points.
///
/// [`geometry::rect`] is the arithmetic, and that is the point: the pair this module's header
/// recorded as a cross-language duplicate is one implementation again, and the hit-test measures
/// against exactly the rect the underline draws.
///
/// The coordinates widen to `i64` saturating rather than converting fallibly. A span index past
/// `i64::MAX` cannot be reached — the scan caps a row at `MAX_SCAN_COLUMNS` cells — and a
/// saturated one is a miss, where an `expect` would be a panic reached through the C boundary,
/// which aborts the process. `Rect` standardises its own edges the way `CGRect.minX`/`maxX` do, so
/// a hand-built span whose end precedes its start is a miss rather than a crash; the scan never
/// emits one.
fn span_rect(metrics: CellMetrics, span: LinkSpan) -> Rect {
    let widen = |index: usize| i64::try_from(index).unwrap_or(i64::MAX);
    geometry::rect(
        metrics,
        widen(span.row),
        widen(span.col_start),
        widen(span.col_end),
    )
}

/// `Int(_:)` of a cell ratio, narrowed to the non-negative answers this rule can use.
///
/// `as` truncates toward zero, which for a ratio the caller's guards have already made non-negative
/// is a floor — the same thing Swift's `Int(_:)` did, and the reason neither side needs a `floor()`
/// call. Where the two part company is the refusal: `Int(_:)` traps on a NaN or on a value past
/// `Int`'s range, and `as` saturates. Neither is reachable from a finite point over a finite grid,
/// so rather than pick between a trap and a saturated cell index nobody asked for, a non-finite
/// ratio is simply no cell. The `< 0` test is Swift's own redundant guard kept: it cannot fire
/// behind the origin test in [`cell`], and it is what makes that independent of this.
#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "truncation toward zero IS the floor this rule wants, and the sign is tested first"
)]
const fn floor_cell(ratio: f64) -> Option<usize> {
    if !ratio.is_finite() {
        return None;
    }
    let whole = ratio as i64;
    if whole < 0 { None } else { Some(whole as usize) }
}

#[cfg(test)]
mod tests {
    use super::{Cell, CellMetrics, LinkSpan, cell, link};
    use crate::link::{LinkSchemePolicy, MAX_SCAN_COLUMNS, detect};

    /// The face the Swift suite measures against: a 10 × 20 point cell at the view's origin.
    const GRID: CellMetrics = CellMetrics {
        cell_width: 10.0,
        cell_height: 20.0,
        origin_x: 0.0,
        origin_y: 0.0,
    };

    /// The spans a row scans to, in the scan's own order — the composition the door performs, so
    /// the rule's tests measure the records this crate actually mints rather than hand-built ones.
    fn spans(rows: &[&str]) -> Vec<LinkSpan> {
        detect(rows, None, &LinkSchemePolicy::All, MAX_SCAN_COLUMNS)
            .iter()
            .map(LinkSpan::from)
            .collect()
    }

    #[test]
    fn a_point_maps_to_the_cell_that_contains_it_on_both_axes() {
        assert_eq!(cell(GRID, 65.0, 5.0), Some(Cell { row: 0, column: 6 }));
        assert_eq!(cell(GRID, 65.0, 25.0), Some(Cell { row: 1, column: 6 }));
        // The cell's own left/top edge belongs to it; one point short belongs to the neighbour.
        assert_eq!(cell(GRID, 60.0, 20.0), Some(Cell { row: 1, column: 6 }));
        assert_eq!(cell(GRID, 59.0, 19.0), Some(Cell { row: 0, column: 5 }));
    }

    #[test]
    fn the_origin_shifts_the_grid_and_a_point_before_it_is_dropped_not_floored() {
        let shifted = CellMetrics {
            origin_x: 50.0,
            origin_y: 40.0,
            ..GRID
        };
        assert_eq!(cell(shifted, 65.0, 45.0), Some(Cell { row: 0, column: 1 }));
        assert_eq!(
            cell(shifted, 20.0, 60.0),
            None,
            "left of the origin is no cell at all"
        );
        assert_eq!(cell(shifted, 60.0, 10.0), None, "and so is above it");
    }

    #[test]
    fn geometry_that_cannot_divide_answers_nothing_rather_than_trapping() {
        let zero = CellMetrics {
            cell_width: 0.0,
            cell_height: 0.0,
            ..GRID
        };
        assert_eq!(cell(zero, 65.0, 5.0), None);
        // A NaN reaches every guard in this module, and every one of them is written so it falls
        // out here rather than dividing, truncating or comparing its way to an answer.
        let nan = CellMetrics {
            cell_width: f64::NAN,
            ..GRID
        };
        assert_eq!(cell(nan, 65.0, 5.0), None);
        assert_eq!(cell(GRID, f64::NAN, 5.0), None);
        assert_eq!(
            cell(GRID, f64::INFINITY, 5.0),
            None,
            "an unbounded point is not cell 0"
        );
    }

    #[test]
    fn a_point_inside_a_span_hits_it_and_the_ends_are_half_open() {
        // "see /usr/local/bin" — the path occupies cells 4..<18, i.e. x in [40, 180).
        let row = spans(&["see /usr/local/bin"]);
        assert_eq!(link(&row, GRID, 65.0, 5.0, 0.0), Some(0), "cell 6 is inside");
        assert_eq!(
            link(&row, GRID, 45.0, 5.0, 0.0),
            Some(0),
            "cell 4 is the inclusive start"
        );
        assert_eq!(
            link(&row, GRID, 185.0, 5.0, 0.0),
            None,
            "cell 18 is the exclusive end"
        );
        assert_eq!(
            link(&row, GRID, 35.0, 5.0, 0.0),
            None,
            "cell 3 is before the span"
        );
        assert_eq!(
            link(&row, GRID, 65.0, 25.0, 0.0),
            None,
            "the right column on the wrong row"
        );
    }

    #[test]
    fn the_row_is_the_vertical_axis_and_the_column_the_horizontal_one() {
        // The axis-swap regression: "/opt/data" is on row 1 at cells 3..<12, and the same column on
        // row 0 is over prose. A rule that read the point's row as its column would answer both.
        let rows = spans(&["nothing here", "go /opt/data"]);
        assert_eq!(link(&rows, GRID, 55.0, 25.0, 0.0), Some(0));
        assert_eq!(link(&rows, GRID, 55.0, 5.0, 0.0), None);
    }

    #[test]
    fn a_wide_glyph_costs_two_columns_because_the_scan_counted_cells() {
        // 你好 is 4 cells, the space is cell 4, and "/tmp/x" starts at cell 5. A hit-test over
        // character offsets rather than display cells would be two cells to the left of the glyph.
        let row = spans(&["你好 /tmp/x"]);
        assert_eq!(link(&row, GRID, 65.0, 5.0, 0.0), Some(0));
        assert_eq!(
            link(&row, GRID, 15.0, 5.0, 0.0),
            None,
            "the wide glyph itself is not a link"
        );
    }

    #[test]
    fn a_pointer_gets_no_slop_at_all() {
        // The case that fails the instant a non-zero slop leaks into the exact reading: cell 18 is
        // one past an exclusive end, which is a miss for a mouse and a hit for a finger.
        let row = spans(&["see /usr/local/bin"]);
        assert_eq!(link(&row, GRID, 185.0, 5.0, 0.0), None);
        assert_eq!(link(&row, GRID, 185.0, 5.0, 15.0), Some(0));
    }

    #[test]
    fn the_slop_reaches_exactly_as_far_as_it_says_in_both_directions() {
        // The rect runs x in [40, 180). 190 is 10 points past its right edge and 200 is 20; 30 is
        // 10 short of its left edge and 20 is 20. A slop that widened by a whole cell regardless of
        // the number given would answer all four the same way.
        let row = spans(&["see /usr/local/bin"]);
        assert_eq!(link(&row, GRID, 190.0, 5.0, 15.0), Some(0));
        assert_eq!(link(&row, GRID, 200.0, 5.0, 15.0), None);
        assert_eq!(link(&row, GRID, 30.0, 5.0, 15.0), Some(0));
        assert_eq!(link(&row, GRID, 20.0, 5.0, 15.0), None);
    }

    #[test]
    fn the_slop_reaches_up_into_the_first_row_from_above_the_origin() {
        // The finger that landed a hair above the terminal. Pass 1 drops it — there is no cell
        // there — and pass 2 must still see it, which is why the origin guard is pass 1's alone.
        let row = spans(&["see /usr/local/bin"]);
        assert_eq!(link(&row, GRID, 65.0, -5.0, 0.0), None);
        assert_eq!(link(&row, GRID, 65.0, -5.0, 15.0), Some(0));
    }

    #[test]
    fn a_degenerate_grid_has_no_spans_to_be_near_even_with_a_slop() {
        let row = spans(&["see /usr/local/bin"]);
        let zero = CellMetrics {
            cell_width: 0.0,
            cell_height: 0.0,
            ..GRID
        };
        assert_eq!(link(&row, zero, 65.0, 5.0, 0.0), None);
        assert_eq!(link(&row, zero, 65.0, 5.0, 40.0), None);
    }

    #[test]
    fn the_nearer_of_two_spans_on_one_row_wins_both_ways_round() {
        // "/tmp/a    /tmp/b": cells 0..<6 (x in [0, 60)) and 10..<16 (x in [100, 160)). A pass that
        // took the first candidate within reach would answer the left span for both probes.
        let row = spans(&["/tmp/a    /tmp/b"]);
        assert_eq!(
            link(&row, GRID, 70.0, 5.0, 35.0),
            Some(0),
            "10 off the left, 30 off the right"
        );
        assert_eq!(
            link(&row, GRID, 90.0, 5.0, 35.0),
            Some(1),
            "30 off the left, 10 off the right"
        );
    }

    #[test]
    fn the_row_is_compared_before_the_column() {
        // Two spans in the same columns with an empty row between them, so only the vertical
        // distance can decide. Row 0 ends at y = 20 and row 2 begins at y = 40.
        let rows = spans(&["/tmp/a", "", "/tmp/b"]);
        assert_eq!(
            link(&rows, GRID, 25.0, 32.0, 15.0),
            Some(1),
            "8 below row 2, 12 above row 0"
        );
        assert_eq!(
            link(&rows, GRID, 25.0, 28.0, 15.0),
            Some(0),
            "8 under row 0, 12 over row 2"
        );
    }

    #[test]
    fn an_exactly_tied_pair_keeps_the_earlier_span() {
        // The point sits in the one-cell gap between two spans, equidistant from both: cells 0..<6
        // end at x = 60, cells 7..<13 begin at x = 70, and 65 is five points from each. The tie
        // must go to the row-major earlier span, which is the order pass 1 would have used.
        let row = spans(&["/tmp/a /tmp/b"]);
        assert_eq!(link(&row, GRID, 65.0, 5.0, 15.0), Some(0));
    }

    #[test]
    fn a_generous_slop_never_re_aims_a_point_that_is_already_on_a_span() {
        // Both probes are inside their own span with the neighbour well within reach. The exact
        // pass runs first, so a slop can only ever ADD an answer where there was none.
        let row = spans(&["/tmp/a /tmp/b"]);
        assert_eq!(
            link(&row, GRID, 25.0, 5.0, 40.0),
            Some(0),
            "cell 2 is inside the left span"
        );
        assert_eq!(
            link(&row, GRID, 75.0, 5.0, 40.0),
            Some(1),
            "cell 7 is inside the right span"
        );
    }

    #[test]
    fn an_empty_scan_answers_nothing_at_any_slop() {
        assert_eq!(link(&[], GRID, 65.0, 5.0, 0.0), None);
        assert_eq!(link(&[], GRID, 65.0, 5.0, 400.0), None);
    }

    #[test]
    fn a_span_whose_end_precedes_its_start_is_a_miss_rather_than_a_panic() {
        // Nothing the scan emits looks like this; a caller's array is measured, not trusted, and
        // the arithmetic that would have underflowed on `usize` runs in `f64` for this reason.
        let backwards = [LinkSpan {
            row: 0,
            col_start: 8,
            col_end: 2,
        }];
        assert_eq!(link(&backwards, GRID, 65.0, 5.0, 0.0), None);
        // Standardised the way `CGRect` standardises: the rect it describes runs x in [20, 80), so
        // a point 10 points past that edge is within a 15-point slop of it.
        assert_eq!(link(&backwards, GRID, 90.0, 5.0, 15.0), Some(0));
    }

    #[test]
    fn a_nan_slop_is_no_slop() {
        // `slop > 0.0` is false for a NaN, so the widened pass never runs — the same answer Swift's
        // `guard slop > 0` gave, and the reason the guard is not written as `!(slop <= 0.0)`.
        let row = spans(&["see /usr/local/bin"]);
        assert_eq!(link(&row, GRID, 185.0, 5.0, f64::NAN), None);
    }
}
