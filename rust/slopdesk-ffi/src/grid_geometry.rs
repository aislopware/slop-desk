//! Where a cell span draws, and where a grid the client did not choose goes.
//!
//! `rust/slopdesk-terminal`'s `geometry` owns both. This is the door.
//!
//! ## Why it exists now and not before
//! [`crate::link_hit`]'s own header recorded this as a deliberately-open pair: `span_rect` in Rust
//! and `TerminalCellMetrics.rect` in Swift were the same two multiplies and two adds, and facing
//! one of them would have put this crate into a target whose whole dependency list was
//! `SlopDeskProtocol`. That held while `rect` was alone. It stopped holding once the letterbox
//! arithmetic beside it was counted: one dependency now buys a cluster, and the drift pair closes
//! as a side effect rather than as its own justification.
//!
//! ## Value in, value out
//! Nothing is allocated on either side. Every answer is a small `#[repr(C)]` record returned by
//! value, and the two that can be absent take `docs/55` §4's value-plus-flag shape rather than a
//! sentinel: a rect at the origin with no extent and a letterbox with no scale are both perfectly
//! ordinary answers, so there is no number outside the range to spend on "no answer".
//!
//! ## Signed coordinates
//! Rows and columns cross as `int64_t`, which is Swift's `Int`. A detector handing back a span that
//! starts left of the viewport is a bug, but reading it as an enormous unsigned column would draw
//! the decoration a screen away instead of off the near edge where it can be SEEN to be wrong.

use slopdesk_terminal::geometry::{
    CellMetrics, Rect, clamped_rect, fit as fit_grid, placement as place_grid, rect as cell_rect,
};

/// A rectangle in the caller's coordinate space, plus whether there is one.
///
/// `present` is false only from [`slopdesk_grid_clamped_rect`]; the unclamped door always answers.
/// The four coordinates are left untouched when it is false, and reading them then is the one
/// mistake this shape exists to make visible rather than plausible.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskGridRect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Extent along X. May be negative for a span whose end precedes its start.
    pub width: f64,
    /// Extent along Y — always one cell.
    pub height: f64,
    /// Whether the span can be drawn at all.
    pub present: bool,
}

/// A letterbox placement, plus whether there is one.
///
/// The natural size is carried WITH the fit because the two are only correct together: the surface
/// is framed at `natural_*` and then transformed by `scale`. Framing it at the scaled rect would
/// make the renderer derive its own grid from its own bounds, which is the reflow size-passivity
/// exists to stop.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskGridPlacement {
    /// Left edge of the drawn grid, in the container's own space.
    pub content_x: f64,
    /// Top edge of the drawn grid.
    pub content_y: f64,
    /// Drawn width.
    pub content_width: f64,
    /// Drawn height.
    pub content_height: f64,
    /// The factor the natural size draws at. Never above 1 — a magnified glyph grid is blur.
    pub scale: f64,
    /// The grid's width at natural cell metrics, before the scale.
    pub natural_width: f64,
    /// The grid's height at natural cell metrics.
    pub natural_height: f64,
    /// Whether anything could be placed. False for a zero grid, unknown cell metrics, or a
    /// container with no area — in each of which the caller draws full-bleed as it always did.
    pub present: bool,
}

/// The metrics four scalars describe, assembled once so every door spells the order the same way.
const fn metrics_of(cell_width: f64, cell_height: f64, origin_x: f64, origin_y: f64) -> CellMetrics {
    CellMetrics {
        cell_width,
        cell_height,
        origin_x,
        origin_y,
    }
}

/// A rect that exists, flattened for the boundary.
const fn present(rect: Rect) -> SlopDeskGridRect {
    SlopDeskGridRect {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
        present: true,
    }
}

/// The rect of the cell span `row, col_start .. col_end`, `col_end` EXCLUSIVE.
///
/// Always `present`: an unclamped span has a rect whatever its numbers are, and the callers that
/// need one refused instead ask [`slopdesk_grid_clamped_rect`].
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_grid_rect(
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
    row: i64,
    col_start: i64,
    col_end: i64,
) -> SlopDeskGridRect {
    present(cell_rect(
        metrics_of(cell_width, cell_height, origin_x, origin_y),
        row,
        col_start,
        col_end,
    ))
}

/// The same rect, clamped to the `cols` visible columns.
///
/// `present` is false for a grid with no columns, a span starting at or past the last visible
/// column, and a span whose clamped end does not follow its start — three refusals the caller
/// treats as one, which is why they are one flag and not a taxonomy.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_grid_clamped_rect(
    cell_width: f64,
    cell_height: f64,
    origin_x: f64,
    origin_y: f64,
    cols: i64,
    row: i64,
    col_start: i64,
    col_end: i64,
) -> SlopDeskGridRect {
    clamped_rect(
        metrics_of(cell_width, cell_height, origin_x, origin_y),
        cols,
        row,
        col_start,
        col_end,
    )
    .map_or_else(SlopDeskGridRect::default, present)
}

/// Fits a `cols × rows` grid drawn at `cell_width × cell_height` inside a container, and reports
/// the natural size the surface must be framed at.
///
/// Shrink to fit, never magnify. `present` is false for any degenerate input — including a NaN
/// anywhere, which the rule's positive guards drop rather than propagate.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_grid_placement(
    cols: i64,
    rows: i64,
    cell_width: f64,
    cell_height: f64,
    container_width: f64,
    container_height: f64,
) -> SlopDeskGridPlacement {
    place_grid(
        cols,
        rows,
        cell_width,
        cell_height,
        container_width,
        container_height,
    )
    .map_or_else(SlopDeskGridPlacement::default, |placed| {
        SlopDeskGridPlacement {
            content_x: placed.fit.content_x,
            content_y: placed.fit.content_y,
            content_width: placed.fit.content_width,
            content_height: placed.fit.content_height,
            scale: placed.fit.scale,
            natural_width: placed.natural_width,
            natural_height: placed.natural_height,
            present: true,
        }
    })
}

/// Whether a placement draws a bar on either axis.
///
/// A separate door rather than a field, because it is a QUESTION about a placement the caller is
/// already holding: a face that stored the answer beside the rect would have two things to keep in
/// step, and an exact fit that reported a hairline is the drift that would follow.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_grid_is_letterboxed(content_x: f64, content_y: f64) -> bool {
    content_x > 0.0 || content_y > 0.0
}

/// The grid `cols × rows` at natural metrics, without placing it.
///
/// The fit alone is not enough for a caller that only wants the frame — an iOS surface sized before
/// its container is measured — and asking for a placement it would discard would make the absent
/// container look like an absent grid.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_grid_fit(
    cols: i64,
    rows: i64,
    cell_width: f64,
    cell_height: f64,
    container_width: f64,
    container_height: f64,
) -> SlopDeskGridPlacement {
    fit_grid(
        cols,
        rows,
        cell_width,
        cell_height,
        container_width,
        container_height,
    )
    .map_or_else(SlopDeskGridPlacement::default, |box_| {
        SlopDeskGridPlacement {
            content_x: box_.content_x,
            content_y: box_.content_y,
            content_width: box_.content_width,
            content_height: box_.content_height,
            scale: box_.scale,
            // The fit alone says nothing about the natural size; a caller that needs it asks
            // `slopdesk_grid_placement`, and a zero here is honestly "not answered" rather than a
            // size it would be wrong to frame at.
            natural_width: 0.0,
            natural_height: 0.0,
            present: true,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{
        slopdesk_grid_clamped_rect, slopdesk_grid_fit, slopdesk_grid_is_letterboxed, slopdesk_grid_placement,
        slopdesk_grid_rect,
    };

    #[test]
    fn a_span_crosses_as_the_rule_answers_it() {
        let span = slopdesk_grid_rect(9.0, 20.0, 4.0, 6.0, 3, 2, 7);
        assert!(span.present);
        assert_eq!(
            (span.x, span.y, span.width, span.height),
            (22.0, 66.0, 45.0, 20.0)
        );
    }

    #[test]
    fn a_clamped_span_that_cannot_be_drawn_is_absent_rather_than_a_zero_rect() {
        let off = slopdesk_grid_clamped_rect(9.0, 20.0, 4.0, 6.0, 10, 0, 10, 12);
        assert!(!off.present);
        let trimmed = slopdesk_grid_clamped_rect(9.0, 20.0, 4.0, 6.0, 10, 1, 8, 40);
        assert!(trimmed.present);
        assert_eq!((trimmed.x, trimmed.width), (76.0, 18.0));
    }

    #[test]
    fn a_placement_carries_the_natural_size_and_the_fit_does_not() {
        let placed = slopdesk_grid_placement(80, 24, 10.0, 20.0, 400.0, 480.0);
        assert!(placed.present);
        assert_eq!((placed.scale, placed.content_y), (0.5, 120.0));
        assert_eq!((placed.natural_width, placed.natural_height), (800.0, 480.0));

        let fitted = slopdesk_grid_fit(80, 24, 10.0, 20.0, 400.0, 480.0);
        assert_eq!((fitted.scale, fitted.content_y), (placed.scale, placed.content_y));
        assert_eq!((fitted.natural_width, fitted.natural_height), (0.0, 0.0));
    }

    #[test]
    fn a_degenerate_grid_is_absent_on_both_doors() {
        assert!(!slopdesk_grid_placement(0, 24, 10.0, 20.0, 400.0, 480.0).present);
        assert!(!slopdesk_grid_fit(80, 24, f64::NAN, 20.0, 400.0, 480.0).present);
    }

    #[test]
    fn an_exact_fit_draws_no_bar() {
        let exact = slopdesk_grid_placement(40, 12, 10.0, 20.0, 400.0, 240.0);
        assert!(!slopdesk_grid_is_letterboxed(exact.content_x, exact.content_y));
        let boxed = slopdesk_grid_placement(80, 24, 10.0, 20.0, 400.0, 480.0);
        assert!(slopdesk_grid_is_letterboxed(boxed.content_x, boxed.content_y));
    }
}
