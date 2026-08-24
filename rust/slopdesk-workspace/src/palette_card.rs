//! The command palette's card: how big it is, and how far one page of it moves.
//!
//! Both numbers are `spec/user-interface__command-palette.md`'s — a centred panel at ~720pt with a
//! results viewport that stops at ~7 rows so the card never grows to the height of the window — and
//! both were spelled in Swift beside the view that drew them, which is one spelling per renderer as
//! soon as there are two renderers.
//!
//! The card's width is deliberately NOT the window's. A palette that stretched with a full-screen
//! workspace would put its keycap column a screen away from its titles, which is the failure the
//! fixed width exists to prevent.
//!
//! [`page_stride`] is here rather than at either call site because it is DERIVED from the same
//! number that sizes the viewport: re-tuning the card has to re-tune the page, or a ⇞ skips a
//! different amount than the eye just travelled. A stride computed by the renderer is a stride that
//! can be left behind by a change to the card.
//!
//! GOLDEN-SAFE: measurements only. Nothing here reads or writes a value or touches a wire codec.

/// The card's fixed width, in points.
pub const PANEL_WIDTH: f64 = 720.0;

/// The tallest the results viewport may be, in points. Past this the list scrolls instead of the
/// card growing.
pub const RESULTS_MAX_HEIGHT: f64 = 336.0;

/// One ⇞/⇟ stride: the whole rows one full viewport shows, never fewer than one.
///
/// A row height of zero or less is not a measurement — a renderer that has not laid out yet asks
/// with one — and the answer for it is the smallest stride that still moves, because a page key
/// that does nothing reads as a dropped keystroke.
#[must_use]
pub fn page_stride(row_height: f64) -> u32 {
    if !row_height.is_finite() || row_height <= 0.0 {
        return 1;
    }
    // `as` after the floor and the clamp: the quotient is finite and positive here, and the ceiling
    // is the viewport's own height in one-point rows, which no `u32` can lose.
    let rows = (RESULTS_MAX_HEIGHT / row_height).floor();
    if rows < 1.0 {
        return 1;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "floored, and bounded above by RESULTS_MAX_HEIGHT with row_height > 0"
    )]
    let rows = rows as u32;
    rows
}

#[cfg(test)]
mod tests {
    use super::{PANEL_WIDTH, RESULTS_MAX_HEIGHT, page_stride};

    #[test]
    fn a_page_is_the_whole_rows_a_viewport_shows() {
        assert_eq!(page_stride(48.0), 7, "the ~7 rows the spec names");
        assert_eq!(page_stride(RESULTS_MAX_HEIGHT), 1);
        assert_eq!(page_stride(100.0), 3, "a partial row is not a row");
    }

    /// A stride always MOVES, whatever the renderer measured.
    #[test]
    fn no_measurement_can_produce_a_stride_that_stands_still() {
        for row_height in [0.0, -1.0, f64::NAN, f64::INFINITY, RESULTS_MAX_HEIGHT * 2.0] {
            assert!(page_stride(row_height) >= 1, "{row_height}");
        }
    }

    /// The card is wider than it is tall, which is what makes the keycap column readable beside the
    /// titles rather than under them.
    #[test]
    fn the_card_is_a_landscape_plate() {
        const { assert!(PANEL_WIDTH > RESULTS_MAX_HEIGHT) }
    }
}
