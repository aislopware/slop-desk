//! Where a remoted window goes when it is parked on the virtual display.
//!
//! Six numbers in and five out, so both rules cross BY VALUE — there is no state to hold and
//! nothing to own. The near side keeps its window-system semantics: a display's extents are
//! standardised before they cross (`CGRect.width` returns `|size|`) and a window's size is not
//! (`CGSize.width` is a stored field), which is why the two arrive as plain scalars rather than as
//! a rect the far side would have to re-interpret.

use slopdesk_video::window_placement;

/// Where a window goes, at what size, and whether it has to be resized to get there.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskWindowPlacement {
    /// The display origin the window is moved to, verbatim — a negative coordinate included.
    pub origin_x: f64,
    /// The vertical half of that origin.
    pub origin_y: f64,
    /// The width to resize to.
    pub width: f64,
    /// The height to resize to.
    pub height: f64,
    /// Whether the clamp shrank the window by more than the half-point tolerance.
    pub needs_resize: bool,
}

/// Clamps a window to a display — DOWN only — and places it at the display's origin.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_placement(
    window_width: f64,
    window_height: f64,
    display_x: f64,
    display_y: f64,
    display_width: f64,
    display_height: f64,
) -> SlopDeskWindowPlacement {
    let plan = window_placement::place(
        window_width,
        window_height,
        display_x,
        display_y,
        display_width,
        display_height,
    );
    SlopDeskWindowPlacement {
        origin_x: plan.origin_x,
        origin_y: plan.origin_y,
        width: plan.width,
        height: plan.height,
        needs_resize: plan.needs_resize,
    }
}

/// Whether an achieved size fits inside the display, within the half-point tolerance.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_window_fits(
    width: f64,
    height: f64,
    bounds_width: f64,
    bounds_height: f64,
) -> bool {
    window_placement::fits(width, height, bounds_width, bounds_height)
}

#[cfg(test)]
mod tests {
    use super::{slopdesk_window_fits, slopdesk_window_placement};

    #[test]
    fn an_oversized_window_shrinks_and_a_fitting_one_is_left_alone() {
        let shrunk = slopdesk_window_placement(2560.0, 1600.0, -1920.0, 0.0, 1920.0, 1080.0);
        assert_eq!((shrunk.width, shrunk.height), (1920.0, 1080.0));
        assert_eq!((shrunk.origin_x, shrunk.origin_y), (-1920.0, 0.0));
        assert!(shrunk.needs_resize);
        let kept = slopdesk_window_placement(800.0, 600.0, 0.0, 0.0, 1920.0, 1080.0);
        assert_eq!((kept.width, kept.height), (800.0, 600.0));
        assert!(!kept.needs_resize);
    }

    #[test]
    fn the_half_point_tolerance_crosses_with_both_rules() {
        assert!(!slopdesk_window_placement(1920.25, 1080.0, 0.0, 0.0, 1920.0, 1080.0).needs_resize);
        assert!(slopdesk_window_fits(1920.25, 1080.0, 1920.0, 1080.0));
        assert!(!slopdesk_window_fits(1921.0, 1080.0, 1920.0, 1080.0));
    }
}
