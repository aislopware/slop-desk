//! Where a remoted window goes when it is parked on the virtual display — and which one a crash
//! left behind.
//!
//! The two park rules are six numbers in and five out, so they cross BY VALUE: there is no state to
//! hold and nothing to own. The near side keeps its window-system semantics: a display's extents
//! are standardised before they cross (`CGRect.width` returns `|size|`) and a window's size is not
//! (`CGSize.width` is a stored field), which is why the two arrive as plain scalars rather than as
//! a rect the far side would have to re-interpret.
//!
//! The launch-hygiene rule is the one crossing with a LIST, and it crosses as a flat run of `f64`s
//! — four per display, `x, y, width, height` — because that is what a Swift `[CGRect]` maps to
//! without a second layout for either side to agree on.

use slopdesk_video::geometry::VideoRect;
use slopdesk_video::{window_placement, window_restore};

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

/// Whether launch hygiene should move a window a crashed daemon recorded back to where it was.
///
/// `displays` is `4 * display_count` scalars — `x, y, width, height` per display, in the same
/// global top-left space as the window frame. An empty list means the enumeration failed, and the
/// answer is then always `false`.
///
/// # Safety
/// `displays` must be null or point to `4 * display_count` readable, aligned `f64`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_window_should_restore(
    current_x: f64,
    current_y: f64,
    current_width: f64,
    current_height: f64,
    original_x: f64,
    original_y: f64,
    displays: *const f64,
    display_count: usize,
) -> bool {
    let scalars = if displays.is_null() || display_count == 0 {
        &[][..]
    } else {
        // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBufferPointer`.
        unsafe { core::slice::from_raw_parts(displays, display_count.saturating_mul(4)) }
    };
    let bounds: Vec<VideoRect> = scalars
        .as_chunks::<4>()
        .0
        .iter()
        .map(|&[x, y, width, height]| VideoRect::xywh(x, y, width, height))
        .collect();
    window_restore::should_restore(
        VideoRect::xywh(current_x, current_y, current_width, current_height),
        original_x,
        original_y,
        &bounds,
    )
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{slopdesk_window_fits, slopdesk_window_placement, slopdesk_window_should_restore};

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

    #[test]
    fn only_a_window_no_display_can_reach_is_moved_home() {
        let displays = [0.0, 0.0, 2560.0, 1440.0, 2560.0, 0.0, 1920.0, 1080.0];
        let restore = |x: f64, y: f64, count: usize| {
            // SAFETY: one live buffer of eight scalars, borrowed for the call.
            unsafe {
                slopdesk_window_should_restore(x, y, 1440.0, 900.0, 120.0, 80.0, displays.as_ptr(), count)
            }
        };
        assert!(restore(4480.0, 0.0, 2), "past every display");
        assert!(!restore(300.0, 200.0, 2), "visible on the main one");
        assert!(!restore(120.0, 80.0, 2), "already home");
        assert!(!restore(4480.0, 0.0, 0), "no displays is no answer");
        // SAFETY: a null list is the documented empty case, never dereferenced.
        assert!(!unsafe {
            slopdesk_window_should_restore(4480.0, 0.0, 1440.0, 900.0, 120.0, 80.0, core::ptr::null(), 4)
        });
    }
}
