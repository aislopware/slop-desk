//! Coordinate-mapping math — `Sources/SlopDeskVideoProtocol/CoordinateMapping.swift`
//! (doc 18 §B, doc 05 §2).
//!
//! The pipeline the host runs for every injected pointer event:
//!
//! 1. The client streams NORMALISED (0..1) window coordinates, never raw pixels, which removes the
//!    pixel-versus-point ambiguity entirely.
//! 2. `normalized → host-window-point`: `target = window_bounds.origin + n * window_bounds.size`,
//!    computed in CG TOP-LEFT space. `kCGWindowBounds` and `CGEvent` mouse positions share that
//!    exact space, so the click coordinate needs NO Y flip — flipping here is the common mistake.
//! 3. The Retina backing scale factor does NOT enter the click math; both sides are points. It is
//!    only needed if the client ever sent pixels.
//! 4. The multi-monitor fix: `kCGWindowBounds` is CG top-left while `NSScreen.frame` is Cocoa
//!    bottom-left. To pick the screen a window sits on, the window rect must be flipped into Cocoa
//!    space FIRST (`cocoa_y = primary_height - y - height`) before intersecting each screen frame.
//!    Without the flip, a window on a secondary monitor intersects the wrong screen and gets the
//!    wrong scale.
//!
//! Every function here is pure. `coordWindowPoint` in the golden corpus pins step 2 as raw `f64`
//! bit patterns, which is why the multiply and the add stay separate operations.

use crate::geometry::{VideoPoint, VideoRect};

/// A display the host knows about, described purely — no `NSScreen` dependency.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScreenInfo {
    /// The screen's frame in COCOA bottom-left space (`NSScreen.frame`): origin at the bottom-left
    /// of the primary display, +Y up.
    pub cocoa_frame: VideoRect,
    /// `NSScreen.backingScaleFactor` — 1.0 standard, 2.0 Retina.
    pub backing_scale_factor: f64,
}

impl ScreenInfo {
    /// Builds a screen description.
    #[must_use]
    pub const fn new(cocoa_frame: VideoRect, backing_scale_factor: f64) -> Self {
        Self {
            cocoa_frame,
            backing_scale_factor,
        }
    }
}

/// Step 2 — maps a normalised (0..1) window point to a host-window point in CG TOP-LEFT space,
/// ready for `CGEvent(mouseCursorPosition:)` or `CGWarpMouseCursorPosition`. No Y flip, no scale.
///
/// `normalized` is the click position within the window, x and y each in 0..1, where (0,0) is the
/// window's top-left and (1,1) its bottom-right. `window_bounds` is `kCGWindowBounds`.
#[must_use]
pub fn window_point(normalized: VideoPoint, window_bounds: VideoRect) -> VideoPoint {
    // keep mul+add separate — FMA breaks bit-exact golden parity
    VideoPoint::new(
        window_bounds.origin.x + normalized.x * window_bounds.size.width,
        window_bounds.origin.y + normalized.y * window_bounds.size.height,
    )
}

/// Step 4 (helper) — flips a CG top-left rect into Cocoa bottom-left space given the primary
/// display's height: `cocoa_y = primary_height - cg_y - height`.
///
/// The primary display's top is `cg_y = 0`, so its bottom is `cg_y = primary_height`; in Cocoa the
/// primary's bottom is `y = 0`. A window whose CG top is `y` with height `h` therefore has Cocoa
/// bottom-left `primary_height - y - h`.
#[must_use]
pub fn cg_rect_to_cocoa(cg_rect: VideoRect, primary_height: f64) -> VideoRect {
    VideoRect::xywh(
        cg_rect.origin.x,
        primary_height - cg_rect.origin.y - cg_rect.size.height,
        cg_rect.size.width,
        cg_rect.size.height,
    )
}

/// Step 4 — picks the screen a window lives on by largest overlap and returns its backing scale
/// factor, or `None` if the window overlaps no known screen.
///
/// The window rect (CG top-left) is flipped into Cocoa space first, then intersected with each
/// screen frame. The tie-break is STRICT `area > best`, so on an exact-area tie the EARLIER screen
/// in `screens` wins — which is the order the caller passed, not an arbitrary one.
#[must_use]
pub fn backing_scale_factor(
    window_bounds_cg: VideoRect,
    screens: &[ScreenInfo],
    primary_height: f64,
) -> Option<f64> {
    let cocoa_window = cg_rect_to_cocoa(window_bounds_cg, primary_height);
    let mut best: Option<(f64, f64)> = None;
    for screen in screens {
        let area = cocoa_window.intersection_area(&screen.cocoa_frame);
        // The `> 0` guard runs first, so the `unwrap_or(0.0)` arm is only reached with a positive
        // area — which is why a `None` best always takes it.
        if area > 0.0 && area > best.map_or(0.0, |(best_area, _)| best_area) {
            best = Some((area, screen.backing_scale_factor));
        }
    }
    best.map(|(_, scale)| scale)
}

/// Converts a PIXEL coordinate to a host-window point.
///
/// The rare case where the client sent pixels instead of normalised coordinates (raw
/// `ScreenCaptureKit`-frame pixels, say): divide by the resolved backing scale factor to get
/// points, then add the window origin.
///
/// Use [`backing_scale_factor`] to resolve `scale`. Spelled out as its own function so a future
/// caller does not double-apply the scale.
#[must_use]
pub fn window_point_from_pixel(pixel: VideoPoint, window_bounds_cg: VideoRect, scale: f64) -> VideoPoint {
    // keep div+add separate — FMA breaks bit-exact golden parity
    VideoPoint::new(
        window_bounds_cg.origin.x + pixel.x / scale,
        window_bounds_cg.origin.y + pixel.y / scale,
    )
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "these are pinned bit patterns, so exact equality is the assertion"
    )]

    use super::{ScreenInfo, backing_scale_factor, cg_rect_to_cocoa, window_point, window_point_from_pixel};
    use crate::geometry::{VideoPoint, VideoRect};

    #[test]
    fn the_normalized_point_lands_inside_the_bounds_with_no_y_flip() {
        let bounds = VideoRect::xywh(100.0, 200.0, 800.0, 600.0);
        assert_eq!(
            window_point(VideoPoint::new(0.5, 0.25), bounds),
            VideoPoint::new(500.0, 350.0)
        );
        assert_eq!(
            window_point(VideoPoint::new(0.0, 0.0), bounds),
            VideoPoint::new(100.0, 200.0)
        );
        assert_eq!(
            window_point(VideoPoint::new(1.0, 1.0), bounds),
            VideoPoint::new(900.0, 800.0)
        );
    }

    #[test]
    fn the_cocoa_flip_is_its_own_inverse() {
        let cg = VideoRect::xywh(-50.0, 120.0, 1024.0, 768.0);
        let cocoa = cg_rect_to_cocoa(cg, 1080.0);
        assert_eq!(cocoa.origin.y, 1080.0 - 120.0 - 768.0);
        assert_eq!(
            cg_rect_to_cocoa(cocoa, 1080.0),
            cg,
            "flipping twice returns the original"
        );
    }

    #[test]
    fn the_largest_overlapping_screen_wins_and_a_tie_goes_to_the_earlier_one() {
        let primary = ScreenInfo::new(VideoRect::xywh(0.0, 0.0, 1000.0, 1000.0), 1.0);
        let secondary = ScreenInfo::new(VideoRect::xywh(1000.0, 0.0, 1000.0, 1000.0), 2.0);
        let screens = [primary, secondary];

        // Mostly on the secondary screen (CG y = 0 with height 1000 flips to Cocoa y = 0).
        let on_secondary = VideoRect::xywh(1200.0, 0.0, 400.0, 1000.0);
        assert_eq!(backing_scale_factor(on_secondary, &screens, 1000.0), Some(2.0));

        // Exactly half on each: the STRICT `>` tie-break keeps the earlier screen.
        let straddling = VideoRect::xywh(900.0, 0.0, 200.0, 1000.0);
        assert_eq!(backing_scale_factor(straddling, &screens, 1000.0), Some(1.0));
    }

    #[test]
    fn a_window_on_no_known_screen_answers_none_rather_than_a_default_scale() {
        let screens = [ScreenInfo::new(VideoRect::xywh(0.0, 0.0, 100.0, 100.0), 2.0)];
        let offscreen = VideoRect::xywh(5000.0, 5000.0, 10.0, 10.0);
        assert_eq!(backing_scale_factor(offscreen, &screens, 100.0), None);
        assert_eq!(
            backing_scale_factor(offscreen, &[], 100.0),
            None,
            "and with no screens at all"
        );
    }

    #[test]
    fn the_flip_is_what_makes_the_multi_monitor_pick_correct() {
        // The regression this exists for: a window BELOW the primary's top edge in CG space is
        // ABOVE the origin in Cocoa space. Skipping the flip picks the wrong screen.
        let low = ScreenInfo::new(VideoRect::xywh(0.0, 0.0, 800.0, 400.0), 1.0);
        let high = ScreenInfo::new(VideoRect::xywh(0.0, 400.0, 800.0, 400.0), 3.0);
        let screens = [low, high];
        // CG y = 0..100 is the TOP of the desktop, which in Cocoa (height 800) is y = 700..800.
        let at_cg_top = VideoRect::xywh(0.0, 0.0, 800.0, 100.0);
        assert_eq!(backing_scale_factor(at_cg_top, &screens, 800.0), Some(3.0));
    }

    #[test]
    fn the_pixel_form_divides_by_the_scale_exactly_once() {
        let bounds = VideoRect::xywh(10.0, 20.0, 100.0, 100.0);
        assert_eq!(
            window_point_from_pixel(VideoPoint::new(200.0, 100.0), bounds, 2.0),
            VideoPoint::new(110.0, 70.0)
        );
    }
}
