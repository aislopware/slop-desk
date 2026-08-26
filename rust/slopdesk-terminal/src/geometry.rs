//! Where a cell span DRAWS, and where a grid the client did not choose GOES.
//!
//! Two questions, one module, because they are the same arithmetic asked at two scales: a span's
//! rect is cells laid out inside a viewport, and a letterbox is a viewport laid out inside a
//! container. Both are pure — points in, points out, no renderer and no view.
//!
//! ## Why this exists as a module at all
//!
//! [`rect`] was Swift's `TerminalCellMetrics.rect(row:colStart:colEnd:)`, and
//! [`crate::link_hit`]'s `span_rect` was a SECOND spelling of it in this crate — recorded in that
//! module's own header as `docs/55` §8's drift class, deferred because facing two multiplies and
//! two adds would have pulled the shim into a target that linked nothing.
//!
//! What changed is that the target is no longer alone in that position. [`fit`] and [`placement`]
//! are the same target's other geometry, they carry their own bit-exactness discipline, and
//! `TerminalGridReadout` sat beside them — so the one decision (give `SlopDeskTerminal` the door)
//! now unlocks a cluster rather than a function, and the drift pair closes as a side effect:
//! `span_rect` is [`rect`] now, and there is one copy again.
//!
//! ## Bit-exact, deliberately
//!
//! `a * b + c` stays a separate `*` and `+` — never `mul_add`, which rounds once where view
//! geometry rounds twice — and every clamp is [`f64::max`]/[`f64::min`] in the nesting order the
//! Swift `CGFloat.minimum(CGFloat.minimum(a, b), 1)` used, never a `<` ternary, which disagrees
//! with it about NaN. `CLAUDE.md`'s habit, kept here for the reason the habit exists: these numbers
//! are pinned by hand-computed cases, and a fused multiply-add moves the last bit of one of them
//! without failing anything else.
//!
//! ## Total over hostile geometry
//!
//! Every input can be a number a layout pass produced under duress — a zero cell size before the
//! first layout, a container with no area, a grid the roster has not resolved. Each guard is
//! written in the POSITIVE (`width > 0.0`, never `!(width <= 0.0)`) so a NaN falls out as "no
//! answer" exactly the way Swift's `guard` did. An ABSENT letterbox, never a wrong one: the caller
//! draws full-bleed as it always did.

/// The live cell geometry a rect is measured against, in POINTS.
///
/// Points, not pixels, and a top-left origin: the surface's own convention, the one `sendMousePos`
/// already speaks. The visible `cols`/`rows` are deliberately NOT fields — [`rect`] asks where a
/// span is and never whether the answer is on screen, and [`clamped_rect`], which does ask, takes
/// the column count as its own argument so the two questions cannot be confused for one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CellMetrics {
    /// Per-cell advance width. A fullwidth glyph occupies two cells, not one wide cell.
    pub cell_width: f64,
    /// Per-cell line height.
    pub cell_height: f64,
    /// The viewport's top-left X in the embedding view's coordinate space.
    pub origin_x: f64,
    /// The viewport's top-left Y in the embedding view's coordinate space.
    pub origin_y: f64,
}

/// A rectangle in the embedding view's coordinate space, top-left origin.
///
/// `width` may be negative — [`rect`] does not reorder a span whose end precedes its start, because
/// the callers that care about extent rather than placement (the hit-test) want to see that and
/// normalise it themselves, and the callers that draw are fed by [`clamped_rect`], which refuses
/// it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Extent along X.
    pub width: f64,
    /// Extent along Y — always one cell.
    pub height: f64,
}

impl Rect {
    /// The smaller X edge, whichever way `width` runs.
    #[must_use]
    pub fn min_x(self) -> f64 {
        f64::min(self.x, self.x + self.width)
    }

    /// The larger X edge, whichever way `width` runs.
    #[must_use]
    pub fn max_x(self) -> f64 {
        f64::max(self.x, self.x + self.width)
    }

    /// The smaller Y edge.
    #[must_use]
    pub fn min_y(self) -> f64 {
        f64::min(self.y, self.y + self.height)
    }

    /// The larger Y edge.
    #[must_use]
    pub fn max_y(self) -> f64 {
        f64::max(self.y, self.y + self.height)
    }
}

/// The rect of the cell span `row, col_start .. col_end`, `col_end` EXCLUSIVE.
///
/// The single source of truth the underline overlay, the hint labels and the hit-test all measure
/// against, so the geometry cannot drift between them. Coordinates are signed because the Swift
/// `Int` they came from is: a detector that hands back a span starting left of the viewport is a
/// bug, but silently reading it as a huge unsigned column would draw a decoration a screen away
/// rather than off the near edge where it can be seen to be wrong.
#[must_use]
pub fn rect(metrics: CellMetrics, row: i64, col_start: i64, col_end: i64) -> Rect {
    // `f64::from` is unavailable for i64, and the counts here are grid coordinates: a terminal with
    // 2^53 columns is not a case, and saturating at the f64 mantissa is the harmless reading.
    #[expect(
        clippy::cast_precision_loss,
        reason = "grid coordinates never approach the f64 mantissa; a lossy column is not a case"
    )]
    let (row, col_start, col_end) = (row as f64, col_start as f64, col_end as f64);
    Rect {
        x: metrics.origin_x + metrics.cell_width * col_start,
        y: metrics.origin_y + metrics.cell_height * row,
        width: metrics.cell_width * (col_end - col_start),
        height: metrics.cell_height,
    }
}

/// [`rect`] for a span clamped to the `cols` visible columns, or `None` for one that cannot be
/// drawn.
///
/// Three refusals, and they are one answer to a caller: a grid with no columns, a span starting at
/// or past the last visible column, and a span whose clamped end does not follow its start. Defence
/// in depth for the per-row viewport read — a span whose own `col_start` overshoots the grid is
/// skipped rather than painted into the void.
#[must_use]
pub fn clamped_rect(metrics: CellMetrics, cols: i64, row: i64, col_start: i64, col_end: i64) -> Option<Rect> {
    if cols <= 0 || col_start < 0 || col_start >= cols {
        return None;
    }
    let clamped_end = i64::min(col_end, cols);
    if clamped_end <= col_start {
        return None;
    }
    Some(rect(metrics, row, col_start, clamped_end))
}

/// Where a grid the client did NOT choose goes inside the space it has — docs/45 §8.3.
///
/// iOS is size-passive host-side: a phone's window never votes in a pane's `min` fold, so the
/// resolved grid is whatever the Macs on that pane settled on, and the phone has to place a grid
/// that is almost never its own aspect — shrunk to fit, centred, with bars for the remainder.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Letterbox {
    /// Left edge of the drawn grid, in the container's own space.
    pub content_x: f64,
    /// Top edge of the drawn grid.
    pub content_y: f64,
    /// Drawn width.
    pub content_width: f64,
    /// Drawn height.
    pub content_height: f64,
    /// The factor the renderer's natural size draws at. `1` is natural cell metrics; below `1` the
    /// grid is wider or taller than the container and is shrunk. Never above `1`.
    pub scale: f64,
}

impl Letterbox {
    /// Whether any bar is drawn — the content does not fill the container on at least one axis.
    ///
    /// An exact fit reports `false`, so a pane that is already the right shape gains no hairline.
    #[must_use]
    pub fn is_letterboxed(self) -> bool {
        self.content_x > 0.0 || self.content_y > 0.0
    }
}

/// A fit PLUS the natural, unscaled size the surface must be framed at.
///
/// One value because the two numbers are only correct together: the renderer is framed at
/// `natural` and then TRANSFORMED by `fit.scale`. Framing it at the scaled rect instead would make
/// the renderer derive a different grid from its own bounds — the phone would reflow to its own
/// window, which is the exact thing size-passivity exists to stop.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    /// Where the grid lands, and at what scale.
    pub fit: Letterbox,
    /// The grid's size at the renderer's NATURAL cell metrics, before the scale.
    pub natural_width: f64,
    /// Ditto, vertically.
    pub natural_height: f64,
}

/// Fits a `cols × rows` grid drawn at `cell_width × cell_height` inside a container.
///
/// SHRINK to fit, never magnify: the scale is capped at `1`, so a grid smaller than the container
/// is centred at the renderer's natural cell metrics rather than blown up. Magnifying a glyph grid
/// is blur, and the whole point of a coding tool is that the text is exact.
///
/// `None` for any degenerate input — a zero grid, unknown cell metrics from a headless or
/// pre-layout surface, or a container with no area. The caller renders as it always did.
#[must_use]
pub fn fit(
    cols: i64,
    rows: i64,
    cell_width: f64,
    cell_height: f64,
    container_width: f64,
    container_height: f64,
) -> Option<Letterbox> {
    let sized = cols > 0
        && rows > 0
        && cell_width > 0.0
        && cell_height > 0.0
        && container_width > 0.0
        && container_height > 0.0;
    if !sized {
        return None;
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "grid counts never approach the f64 mantissa; this is the Swift CGFloat(Int) cast"
    )]
    let (cols, rows) = (cols as f64, rows as f64);
    let natural_width = cell_width * cols;
    let natural_height = cell_height * rows;
    let width_scale = container_width / natural_width;
    let height_scale = container_height / natural_height;
    // The nesting order of the Swift `CGFloat.minimum(CGFloat.minimum(w, h), 1)`, kept: a `<`
    // ternary disagrees with it about NaN, and a degenerate container makes NaN reachable.
    let scale = f64::min(f64::min(width_scale, height_scale), 1.0);
    let width = natural_width * scale;
    let height = natural_height * scale;
    Some(Letterbox {
        content_x: (container_width - width) / 2.0,
        content_y: (container_height - height) / 2.0,
        content_width: width,
        content_height: height,
        scale,
    })
}

/// Places a host-resolved grid drawn at a cell size inside a container.
///
/// Degrades to full-bleed, and that IS the contract: `None` whenever anything it depends on is
/// unknown. Every input can legitimately be absent — the roster has not landed, the document is
/// off, the renderer is a placeholder with no cell metrics, the layout pass has not run — and in
/// each case the caller draws at full bleed. An absent letterbox, never a wrong one.
#[must_use]
pub fn placement(
    cols: i64,
    rows: i64,
    cell_width: f64,
    cell_height: f64,
    container_width: f64,
    container_height: f64,
) -> Option<Placement> {
    let fit = fit(
        cols,
        rows,
        cell_width,
        cell_height,
        container_width,
        container_height,
    )?;
    #[expect(
        clippy::cast_precision_loss,
        reason = "grid counts never approach the f64 mantissa; this is the Swift CGFloat(Int) cast"
    )]
    let (cols, rows) = (cols as f64, rows as f64);
    Some(Placement {
        fit,
        natural_width: cell_width * cols,
        natural_height: cell_height * rows,
    })
}

#[cfg(test)]
mod tests {
    use super::{CellMetrics, Letterbox, Placement, Rect, clamped_rect, fit, placement, rect};

    const METRICS: CellMetrics = CellMetrics {
        cell_width: 9.0,
        cell_height: 20.0,
        origin_x: 4.0,
        origin_y: 6.0,
    };

    /// The letterbox five numbers describe, so a case reads as its expected VALUE rather than as an
    /// unwrap the crate's lints would refuse anyway.
    const fn box_of(x: f64, y: f64, width: f64, height: f64, scale: f64) -> Letterbox {
        Letterbox {
            content_x: x,
            content_y: y,
            content_width: width,
            content_height: height,
            scale,
        }
    }

    #[test]
    fn a_span_lands_where_its_cells_are() {
        // Hand-computed: x = 4 + 9*2 = 22, y = 6 + 20*3 = 66, width = 9*(7-2) = 45.
        let span = rect(METRICS, 3, 2, 7);
        assert_eq!(
            (span.x, span.y, span.width, span.height),
            (22.0, 66.0, 45.0, 20.0)
        );
    }

    #[test]
    fn a_reversed_span_keeps_its_sign_and_still_orders_its_edges() {
        // `rect` reports the extent as it was asked for; the edges are ordered on read, which is
        // what the hit-test measures distance against.
        // x = 4 + 9*7 = 67, width = 9*(2-7) = -45, so the edges read back as 22 and 67.
        let backwards = rect(METRICS, 0, 7, 2);
        assert!(backwards.width < 0.0);
        assert_eq!((backwards.min_x(), backwards.max_x()), (22.0, 67.0));
    }

    #[test]
    fn a_clamped_span_is_trimmed_to_the_grid_edge() {
        // 10 columns; a span 8..40 draws 8..10 — two cells, not thirty-two.
        assert_eq!(
            clamped_rect(METRICS, 10, 1, 8, 40),
            Some(Rect {
                x: 76.0,
                y: 26.0,
                width: 18.0,
                height: 20.0,
            }),
        );
    }

    #[test]
    fn a_span_that_cannot_be_drawn_is_absent_rather_than_off_screen() {
        // Past the last column, negative, a degenerate grid, and a range that does not run forward.
        assert_eq!(clamped_rect(METRICS, 10, 0, 10, 12), None);
        assert_eq!(clamped_rect(METRICS, 10, 0, -1, 4), None);
        assert_eq!(clamped_rect(METRICS, 0, 0, 0, 4), None);
        assert_eq!(clamped_rect(METRICS, 10, 0, 5, 5), None);
    }

    #[test]
    fn a_grid_wider_than_its_container_shrinks_and_centres() {
        // 80×24 at 10×20 is 800×480 natural. In 400×480 the width scale is 0.5, the height scale 1,
        // so the fit is 0.5 → 400×240, centred vertically with 120-point bars.
        let box_ = fit(80, 24, 10.0, 20.0, 400.0, 480.0);
        assert_eq!(box_, Some(box_of(0.0, 120.0, 400.0, 240.0, 0.5)));
        assert!(box_.is_some_and(Letterbox::is_letterboxed));
    }

    #[test]
    fn a_grid_smaller_than_its_container_is_centred_at_natural_size_never_magnified() {
        // Magnifying a glyph grid is blur. 400×240 in 800×480 stays 400×240, centred.
        assert_eq!(
            fit(40, 12, 10.0, 20.0, 800.0, 480.0),
            Some(box_of(200.0, 120.0, 400.0, 240.0, 1.0)),
        );
    }

    #[test]
    fn an_exact_fit_draws_no_bar() {
        let box_ = fit(40, 12, 10.0, 20.0, 400.0, 240.0);
        assert_eq!(box_, Some(box_of(0.0, 0.0, 400.0, 240.0, 1.0)));
        assert!(!box_.is_some_and(Letterbox::is_letterboxed));
    }

    #[test]
    fn every_degenerate_input_is_absent_rather_than_a_zero_area_rect() {
        assert_eq!(fit(0, 24, 10.0, 20.0, 400.0, 480.0), None);
        assert_eq!(fit(80, 0, 10.0, 20.0, 400.0, 480.0), None);
        assert_eq!(fit(80, 24, 0.0, 20.0, 400.0, 480.0), None);
        assert_eq!(fit(80, 24, 10.0, 0.0, 400.0, 480.0), None);
        assert_eq!(fit(80, 24, 10.0, 20.0, 0.0, 480.0), None);
        assert_eq!(fit(80, 24, 10.0, 20.0, 400.0, 0.0), None);
    }

    #[test]
    fn a_nan_anywhere_is_absent_rather_than_a_nan_rect() {
        // The guards are written in the positive so a NaN falls out here, exactly as Swift's
        // `guard cellWidth > 0` did rather than as `!(cellWidth <= 0)` would not have.
        assert_eq!(fit(80, 24, f64::NAN, 20.0, 400.0, 480.0), None);
        assert_eq!(fit(80, 24, 10.0, 20.0, f64::NAN, 480.0), None);
    }

    #[test]
    fn the_natural_size_is_the_unscaled_one_the_surface_is_framed_at() {
        // The scaled content is 400×240; the surface is still framed at 800×480 and transformed,
        // or the renderer would derive its own grid from its own bounds and the phone would reflow.
        assert_eq!(
            placement(80, 24, 10.0, 20.0, 400.0, 480.0),
            Some(Placement {
                fit: box_of(0.0, 120.0, 400.0, 240.0, 0.5),
                natural_width: 800.0,
                natural_height: 480.0,
            }),
        );
    }

    #[test]
    fn a_placement_is_absent_exactly_when_its_fit_is() {
        assert_eq!(placement(0, 24, 10.0, 20.0, 400.0, 480.0), None);
    }
}
