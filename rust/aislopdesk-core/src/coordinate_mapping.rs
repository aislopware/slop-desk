//! Coordinate-mapping math — a port of Swift `CoordinateMapping`.
//!
//! The client streams normalised (0..1) window coordinates; the host maps them to a
//! host-window point in CG top-left space (no Y flip, no scale — `kCGWindowBounds` and
//! `CGEvent` mouse positions share that space). The multi-monitor screen pick flips the
//! window rect into Cocoa bottom-left space first, then takes the largest overlap.

use crate::geometry::{VideoPoint, VideoRect};

/// A display the host knows about, described purely (no `NSScreen` dependency).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScreenInfo {
    /// The screen's frame in Cocoa bottom-left space (`NSScreen.frame`).
    pub cocoa_frame: VideoRect,
    /// `NSScreen.backingScaleFactor` (1.0 standard, 2.0 Retina).
    pub backing_scale_factor: f64,
}

impl ScreenInfo {
    /// Builds a screen descriptor.
    #[must_use]
    pub const fn new(cocoa_frame: VideoRect, backing_scale_factor: f64) -> Self {
        Self {
            cocoa_frame,
            backing_scale_factor,
        }
    }
}

/// Maps a normalised (0..1) window point to a host-window point in CG top-left space.
/// No Y flip, no scale.
#[must_use]
pub fn window_point(normalized: VideoPoint, window_bounds: VideoRect) -> VideoPoint {
    VideoPoint::new(
        window_bounds.origin.x + normalized.x * window_bounds.size.width,
        window_bounds.origin.y + normalized.y * window_bounds.size.height,
    )
}

/// Flips a CG-top-left rect into Cocoa bottom-left space given the primary display
/// height: `cocoa_y = primary_height - cg_y - height`.
#[must_use]
pub fn cg_rect_to_cocoa(cg_rect: VideoRect, primary_height: f64) -> VideoRect {
    VideoRect::xywh(
        cg_rect.origin.x,
        primary_height - cg_rect.origin.y - cg_rect.size.height,
        cg_rect.size.width,
        cg_rect.size.height,
    )
}

/// Picks the screen a window lives on (largest overlap) and returns its
/// `backing_scale_factor`, or `None` if it overlaps no known screen.
///
/// The window rect
/// (CG top-left) is flipped into Cocoa space first, then intersected with each screen.
/// On an exact-area tie the earlier screen in `screens` wins (strictly-greater compare).
#[must_use]
pub fn backing_scale_factor(
    window_bounds_cg: VideoRect,
    screens: &[ScreenInfo],
    primary_height: f64,
) -> Option<f64> {
    let cocoa_window = cg_rect_to_cocoa(window_bounds_cg, primary_height);
    let mut best: Option<(f64, f64)> = None; // (area, scale)
    for screen in screens {
        let area = cocoa_window.intersection_area(&screen.cocoa_frame);
        if area > 0.0 && best.is_none_or(|(best_area, _)| area > best_area) {
            best = Some((area, screen.backing_scale_factor));
        }
    }
    best.map(|(_, scale)| scale)
}

/// Convenience for the rare case the client sent pixels: divide by the resolved
/// `backing_scale_factor` to get points, then add the window origin.
#[must_use]
pub fn window_point_from_pixel(
    pixel: VideoPoint,
    window_bounds_cg: VideoRect,
    backing_scale_factor: f64,
) -> VideoPoint {
    VideoPoint::new(
        window_bounds_cg.origin.x + pixel.x / backing_scale_factor,
        window_bounds_cg.origin.y + pixel.y / backing_scale_factor,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::VideoSize;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn normalized_maps_without_flip_or_scale() {
        let p = window_point(
            VideoPoint::new(0.5, 0.25),
            VideoRect::xywh(100.0, 200.0, 800.0, 600.0),
        );
        approx(p.x, 100.0 + 400.0);
        approx(p.y, 200.0 + 150.0);
    }

    #[test]
    fn cg_to_cocoa_flip() {
        // primary height 1000; a window at cg y=100 height 200 → cocoa y = 1000-100-200=700.
        let r = cg_rect_to_cocoa(VideoRect::xywh(0.0, 100.0, 50.0, 200.0), 1000.0);
        approx(r.origin.y, 700.0);
        approx(r.size.height, 200.0);
    }

    #[test]
    fn picks_secondary_monitor_scale() {
        let primary_height = 1000.0;
        let primary = ScreenInfo::new(VideoRect::xywh(0.0, 0.0, 1000.0, 1000.0), 1.0);
        // secondary sits to the right in Cocoa space, Retina.
        let secondary = ScreenInfo::new(VideoRect::xywh(1000.0, 0.0, 1000.0, 1000.0), 2.0);
        // a window entirely on the secondary (CG top-left x=1200)
        let win = VideoRect::xywh(1200.0, 100.0, 100.0, 100.0);
        let scale = backing_scale_factor(win, &[primary, secondary], primary_height);
        assert_eq!(scale, Some(2.0));
    }

    #[test]
    fn no_overlap_returns_none() {
        let primary = ScreenInfo::new(VideoRect::xywh(0.0, 0.0, 100.0, 100.0), 1.0);
        let win = VideoRect::xywh(5000.0, 5000.0, 10.0, 10.0);
        assert_eq!(backing_scale_factor(win, &[primary], 100.0), None);
        let _ = VideoSize::new(0.0, 0.0);
    }

    #[test]
    fn pixel_path_divides_by_scale() {
        let p = window_point_from_pixel(
            VideoPoint::new(200.0, 100.0),
            VideoRect::xywh(10.0, 20.0, 0.0, 0.0),
            2.0,
        );
        approx(p.x, 10.0 + 100.0);
        approx(p.y, 20.0 + 50.0);
    }
}
