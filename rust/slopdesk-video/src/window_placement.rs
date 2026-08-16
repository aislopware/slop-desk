//! Where a remoted window goes when it is parked on the virtual display.
//!
//! The host puts the captured window on a `HiDPI` virtual display so it renders at a real 2×
//! backing.
//! macOS CROPS a window that overhangs its display, so an oversized one has to be shrunk before it
//! is moved, and after the move the achieved size has to be checked: an app that refuses or clamps
//! the resize leaves a window still overhanging, which must not be reported as a successful park —
//! the capture crop would exceed the framebuffer and the client's input mapping would desync.
//!
//! Both rules are arithmetic on six numbers, and the caller's window-system semantics stay with the
//! caller: a display's extents arrive ALREADY standardised (`CGRect.width` returns `|size|`) while
//! a window's size arrives RAW (`CGSize.width` is a stored field), so the clamp here is
//! deliberately asymmetric and this module never takes an absolute value of its own.
//!
//! The ordered comparisons are spelled as they are for one reason: a NaN. `display < window` is
//! false for a NaN operand, so the window value passes through — where a min that "ignores NaN"
//! would hand back the display's. The golden corpus pins the answers as bit patterns precisely so a
//! port cannot quietly choose the other one.

/// The half-point tolerance both rules carry.
///
/// Exactly representable, and added to values that are, so it introduces no rounding of its own. It
/// exists so floating-point equality does not order a no-op resize, or fail a window that fits.
pub const TOLERANCE: f64 = 0.5;

/// Where a window goes, at what size, and whether it has to be resized to get there.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    /// The display origin the window is moved to, verbatim — including the negative coordinates of
    /// a display placed left of or above the main one.
    pub origin_x: f64,
    /// The vertical half of that origin.
    pub origin_y: f64,
    /// The width to resize to: the window's own, or the display's where the window is wider.
    pub width: f64,
    /// The height to resize to, by the same rule.
    pub height: f64,
    /// Whether the clamp actually shrank the window by more than the tolerance. A window that
    /// already fits is moved without a resize, so an app that dislikes being resized is not asked.
    pub needs_resize: bool,
}

/// Clamps a window to a display — DOWN only, never enlarging — and places it at the display origin.
///
/// `display_width` / `display_height` are the display's STANDARDISED extents and
/// `window_width` / `window_height` the window's RAW size, as the caller's window system defines
/// each; this function compares them as given.
#[must_use]
pub fn place(
    window_width: f64,
    window_height: f64,
    display_x: f64,
    display_y: f64,
    display_width: f64,
    display_height: f64,
) -> Placement {
    // The ordered ternary, NOT a NaN-ignoring minimum: a NaN window size stays a NaN here, and the
    // vectors pin that.
    let width = if display_width < window_width {
        display_width
    } else {
        window_width
    };
    let height = if display_height < window_height {
        display_height
    } else {
        window_height
    };
    // The tolerance is added to the CLAMPED extent and compared against the RAW window, each step
    // its own operation. There is no multiply to fuse with, but the comparison is a half-point
    // predicate the corpus pins, so it stays spelled exactly this way.
    let needs_width = width + TOLERANCE < window_width;
    let needs_height = height + TOLERANCE < window_height;
    Placement {
        origin_x: display_x,
        origin_y: display_y,
        width,
        height,
        needs_resize: needs_width || needs_height,
    }
}

/// Whether a size fits inside bounds, within the tolerance.
///
/// Read AFTER the move, against the size the window actually achieved: the plan said what to ask
/// for, and this says whether the app complied. A NaN fails, which is the answer that rolls the
/// window back rather than parking it on a size nothing can crop correctly.
#[must_use]
pub fn fits(width: f64, height: f64, bounds_width: f64, bounds_height: f64) -> bool {
    width <= bounds_width + TOLERANCE && height <= bounds_height + TOLERANCE
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures are exact binary fractions, and passing a value through UNCHANGED is the \
                  property under test"
    )]

    use super::{fits, place};

    #[test]
    fn a_window_that_already_fits_is_moved_without_being_resized() {
        let plan = place(800.0, 600.0, 0.0, 0.0, 1920.0, 1080.0);
        assert_eq!((plan.width, plan.height), (800.0, 600.0));
        assert!(!plan.needs_resize);
    }

    #[test]
    fn an_oversized_window_is_shrunk_to_the_display_before_it_crosses() {
        let plan = place(2560.0, 1600.0, 0.0, 0.0, 1920.0, 1080.0);
        assert_eq!((plan.width, plan.height), (1920.0, 1080.0));
        assert!(plan.needs_resize, "macOS would crop it otherwise");
    }

    #[test]
    fn the_display_origin_crosses_verbatim_including_a_negative_one() {
        let plan = place(400.0, 300.0, -1920.0, -240.0, 1920.0, 1080.0);
        assert_eq!((plan.origin_x, plan.origin_y), (-1920.0, -240.0));
    }

    #[test]
    fn a_shrink_inside_the_tolerance_is_not_worth_asking_an_app_for() {
        let plan = place(1920.25, 1080.0, 0.0, 0.0, 1920.0, 1080.0);
        assert_eq!(plan.width, 1920.0, "the clamp still applies");
        assert!(!plan.needs_resize, "but a quarter point is not a resize");
        assert!(place(1921.0, 1080.0, 0.0, 0.0, 1920.0, 1080.0).needs_resize);
    }

    #[test]
    fn a_nan_window_size_passes_through_rather_than_becoming_the_display() {
        let plan = place(f64::NAN, 600.0, 0.0, 0.0, 1920.0, 1080.0);
        assert!(plan.width.is_nan(), "an ordered compare keeps the NaN");
        assert!(
            !plan.needs_resize,
            "and every comparison against it is false, so nothing is asked for"
        );
    }

    #[test]
    fn a_window_fits_when_it_overhangs_by_less_than_the_tolerance() {
        assert!(fits(1920.0, 1080.0, 1920.0, 1080.0), "exact fits");
        assert!(
            fits(1920.25, 1080.0, 1920.0, 1080.0),
            "a quarter point over still fits"
        );
        assert!(!fits(1921.0, 1080.0, 1920.0, 1080.0));
        assert!(
            !fits(f64::NAN, 1080.0, 1920.0, 1080.0),
            "an unreadable size is rolled back, not parked"
        );
    }
}
