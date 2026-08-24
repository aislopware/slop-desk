//! The command palette's card, in C.
//!
//! The rules are [`slopdesk_workspace::palette_card`]; what is here is the marshalling, and it is
//! `docs/55` §6's by-value shape twice over: two measurements that are only ever wanted together
//! cross as one `struct`, and the page stride crosses as arithmetic — the renderer MEASURES a row,
//! this side DECIDES how many of them a page is.

use slopdesk_workspace::palette_card;

/// The palette card's two measurements.
///
/// By value, on [`CFindBarRung`](crate::find_bar::CFindBarRung)'s argument: numbers with no
/// interior, wanted together, and a caller that asked for them one at a time could size a card by
/// one spelling of the spec and its viewport by another.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CPaletteCard {
    /// The card's fixed width, in points.
    pub panel_width: f64,
    /// The tallest the results viewport may be, in points.
    pub results_max_height: f64,
}

/// The card's measurements.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_palette_card() -> CPaletteCard {
    CPaletteCard {
        panel_width: palette_card::PANEL_WIDTH,
        results_max_height: palette_card::RESULTS_MAX_HEIGHT,
    }
}

/// One ⇞/⇟ stride: the whole rows one full viewport shows, never fewer than one.
///
/// `row_height` is the renderer's own measurement. A row height that is not a positive, finite
/// measurement — which is what a renderer that has not laid out yet asks with — still answers a
/// stride that MOVES, because a page key that does nothing reads as a dropped keystroke.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_palette_page_stride(row_height: f64) -> u32 {
    palette_card::page_stride(row_height)
}

#[cfg(test)]
mod tests {
    use slopdesk_workspace::palette_card;

    use super::{slopdesk_ws_palette_card, slopdesk_ws_palette_page_stride};

    #[test]
    fn both_measurements_cross_by_value() {
        let card = slopdesk_ws_palette_card();
        assert!((card.panel_width - palette_card::PANEL_WIDTH).abs() < f64::EPSILON);
        assert!((card.results_max_height - palette_card::RESULTS_MAX_HEIGHT).abs() < f64::EPSILON);
    }

    #[test]
    fn every_measurement_a_renderer_can_hand_over_crosses_unchanged() {
        for row_height in [
            0.0,
            -4.0,
            f64::NAN,
            1.0,
            48.0,
            palette_card::RESULTS_MAX_HEIGHT * 3.0,
        ] {
            assert_eq!(
                slopdesk_ws_palette_page_stride(row_height),
                palette_card::page_stride(row_height),
                "{row_height}",
            );
        }
    }
}
