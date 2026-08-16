//! Where the client draws the host's cursor, and which way up.
//!
//! The host strips the cursor from the video and ships its position over a separate low-latency
//! channel, so the client composites it on top of the decoded frame every refresh. That is what
//! makes pointer latency equal the round trip instead of the encode-decode pipeline: the cursor
//! keeps moving smoothly even while the video frames underneath it are stale.
//!
//! Everything here is placement math. The layer itself — the bitmap cache, the transaction that
//! suppresses the implicit animation, the platform cursor built from a cached shape — stays in the
//! GUI, because it is `CALayer` and `NSCursor` all the way down.

use crate::cursor::CursorUpdate;
use crate::geometry::{VideoContentMode, VideoPoint, VideoRect, VideoSize, displayed_video_rect, view_point};

/// The one-to-one placement: the host position scaled into view points, with the hotspot subtracted
/// so the cursor's TIP lands on the reported position rather than its top-left corner.
///
/// This assumes the video fills the layer from the origin, which is the fast case; the letterboxed
/// or zoomed pane needs [`layer_frame_fit`], whose scalar core this is.
#[must_use]
pub fn layer_frame_scalar(update: &CursorUpdate, video_scale: f64, cursor_size: VideoSize) -> VideoRect {
    // keep mul+add separate — FMA breaks bit-exact parity
    let x = update.position.x * video_scale - update.hotspot.x;
    let y = update.position.y * video_scale - update.hotspot.y;
    VideoRect::xywh(x, y, cursor_size.width, cursor_size.height)
}

/// The aspect-fit and zoom-and-pan-correct placement, mapping the host position through the EXACT
/// forward render transform the input path inverts.
///
/// That shared transform is the whole point: the overlay tracks the same displayed pixel a click
/// lands on, so the cursor the user sees and the coordinate the host receives cannot drift apart at
/// any zoom or in any letterbox. The hotspot arrives in host-window points, so it is scaled by the
/// displayed rect's per-source-point scale — times the zoom, which crops — before being subtracted.
#[must_use]
pub fn layer_frame_fit(
    update: &CursorUpdate,
    view_size: VideoSize,
    video_native_size: VideoSize,
    zoom: f64,
    pan: VideoPoint,
    cursor_size: VideoSize,
    mode: VideoContentMode,
) -> VideoRect {
    let tip = view_point(update.position, view_size, video_native_size, zoom, pan, mode);
    let rect = displayed_video_rect(view_size, video_native_size, mode);
    let z = 1.0_f64.max(zoom);
    let scale_x = if video_native_size.width > 0.0 {
        // keep the divide and the multiply separate — FMA breaks bit-exact parity
        (rect.size.width / video_native_size.width) * z
    } else {
        1.0
    };
    let scale_y = if video_native_size.height > 0.0 {
        (rect.size.height / video_native_size.height) * z
    } else {
        1.0
    };
    // keep mul+add separate — FMA breaks bit-exact parity
    let x = tip.x - update.hotspot.x * scale_x;
    let y = tip.y - update.hotspot.y * scale_y;
    VideoRect::xywh(x, y, cursor_size.width, cursor_size.height)
}

/// Converts a TOP-LEFT layer origin into the BOTTOM-LEFT one a macOS layer-backed view uses for its
/// sublayers.
///
/// The overlay is a sublayer of the Metal layer, whose host view flips neither its geometry nor
/// itself, so its sublayer space has y going UP — while the placement math above returns a top-left
/// frame, the same space the input path flips into. Writing the frame verbatim mirrors the cursor
/// vertically: it tracks the wrong pixel and sits visibly far from where clicks land. iOS layers
/// are already top-left and never call this.
#[must_use]
pub fn bottom_left_origin_y(top_left_y: f64, height: f64, parent_height: f64) -> f64 {
    parent_height - top_left_y - height
}

/// Whether a computed frame is safe to assign to a layer.
///
/// Assigning a non-finite component raises an uncaught geometry exception that kills the process.
/// The codec already rejects non-finite wire floats, so a malformed datagram is dropped upstream;
/// this covers the NaN that degenerate aspect-fit math could still produce from a zero dimension.
/// A frame that fails is SKIPPED — one stale cursor position is nothing beside a dead client.
#[must_use]
pub const fn is_placeable(frame: VideoRect) -> bool {
    frame.origin.x.is_finite()
        && frame.origin.y.is_finite()
        && frame.size.width.is_finite()
        && frame.size.height.is_finite()
}

/// The size the overlay should render at, given the shape's logical point size and the raw bitmap.
///
/// The bitmap may be a Retina or MTU-downscaled image, so the LOGICAL size is what the cursor
/// should occupy on screen; the layer scales its contents to these bounds. A degenerate logical
/// size falls back to the bitmap's own pixel dimensions rather than collapsing the cursor to
/// nothing.
#[must_use]
pub fn rendered_shape_size(logical_size: VideoSize, bitmap_pixels: VideoSize) -> VideoSize {
    let width = if logical_size.width > 0.0 {
        logical_size.width
    } else {
        bitmap_pixels.width
    };
    let height = if logical_size.height > 0.0 {
        logical_size.height
    } else {
        bitmap_pixels.height
    };
    VideoSize::new(width, height)
}

/// Clamps a hotspot into the shape's own bounds.
///
/// A malformed or oversized hotspot makes the platform reject the cursor outright, which would
/// leave the user with no cursor at all rather than a slightly wrong one.
#[must_use]
pub const fn clamped_hotspot(hotspot: VideoPoint, shape_size: VideoSize) -> VideoPoint {
    VideoPoint {
        x: hotspot.x.max(0.0).min(shape_size.width),
        y: hotspot.y.max(0.0).min(shape_size.height),
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures are exact halves and integers of the layer sizes"
    )]

    use super::{
        bottom_left_origin_y, clamped_hotspot, is_placeable, layer_frame_fit, layer_frame_scalar,
        rendered_shape_size,
    };
    use crate::cursor::CursorUpdate;
    use crate::geometry::{VideoContentMode, VideoPoint, VideoRect, VideoSize};

    fn point(x: f64, y: f64) -> VideoPoint {
        VideoPoint { x, y }
    }

    fn update_at(x: f64, y: f64, hotspot: VideoPoint) -> CursorUpdate {
        CursorUpdate::new(point(x, y), 1, hotspot, true)
    }

    #[test]
    fn the_tip_lands_on_the_reported_position_rather_than_the_corner() {
        let update = update_at(100.0, 50.0, point(4.0, 6.0));
        let frame = layer_frame_scalar(&update, 1.0, VideoSize::new(16.0, 24.0));
        assert_eq!(frame.origin, point(96.0, 44.0));
        assert_eq!(frame.size, VideoSize::new(16.0, 24.0));
    }

    #[test]
    fn the_scalar_placement_scales_the_position_but_not_the_hotspot() {
        let update = update_at(100.0, 50.0, point(4.0, 6.0));
        let frame = layer_frame_scalar(&update, 2.0, VideoSize::new(16.0, 24.0));
        assert_eq!(
            frame.origin,
            point(196.0, 94.0),
            "the hotspot is already in the overlay's own bitmap points here",
        );
    }

    #[test]
    fn the_fit_placement_tracks_the_pixel_a_click_would_land_on() {
        // A square video pillarboxed inside a wide layer: the video occupies the middle 500 points.
        let update = update_at(250.0, 250.0, point(0.0, 0.0));
        let frame = layer_frame_fit(
            &update,
            VideoSize::new(1000.0, 500.0),
            VideoSize::new(500.0, 500.0),
            1.0,
            point(0.0, 0.0),
            VideoSize::new(16.0, 16.0),
            VideoContentMode::Fit,
        );
        assert_eq!(
            frame.origin,
            point(500.0, 250.0),
            "the centre of the video is the centre of the pane"
        );
    }

    #[test]
    fn the_hotspot_is_scaled_into_view_points_so_the_tip_holds_at_any_zoom() {
        let update = update_at(250.0, 250.0, point(8.0, 8.0));
        let unzoomed = layer_frame_fit(
            &update,
            VideoSize::new(1000.0, 1000.0),
            VideoSize::new(500.0, 500.0),
            1.0,
            point(0.0, 0.0),
            VideoSize::new(16.0, 16.0),
            VideoContentMode::Fit,
        );
        // The video is displayed at twice its native size, so an 8-point hotspot is 16 view points.
        assert_eq!(unzoomed.origin, point(484.0, 484.0));
        let zoomed = layer_frame_fit(
            &update,
            VideoSize::new(1000.0, 1000.0),
            VideoSize::new(500.0, 500.0),
            2.0,
            point(0.0, 0.0),
            VideoSize::new(16.0, 16.0),
            VideoContentMode::Fit,
        );
        assert_eq!(
            zoomed.origin,
            point(468.0, 468.0),
            "the crop doubles the on-screen hotspot again"
        );
    }

    #[test]
    fn a_degenerate_video_size_leaves_the_hotspot_unscaled_rather_than_producing_a_nan() {
        let update = update_at(0.0, 0.0, point(8.0, 8.0));
        let frame = layer_frame_fit(
            &update,
            VideoSize::new(1000.0, 500.0),
            VideoSize::new(0.0, 0.0),
            1.0,
            point(0.0, 0.0),
            VideoSize::new(16.0, 16.0),
            VideoContentMode::Fit,
        );
        assert!(is_placeable(frame));
    }

    #[test]
    fn the_flip_puts_the_overlay_on_the_same_pixel_the_input_path_targets() {
        // A 16-point cursor whose top-left sits 100 down from the top of a 500-point parent has its
        // bottom edge 384 up from the bottom.
        assert_eq!(bottom_left_origin_y(100.0, 16.0, 500.0), 384.0);
        assert_eq!(
            bottom_left_origin_y(0.0, 16.0, 500.0),
            484.0,
            "the top of the pane is the top of the pane in either convention",
        );
    }

    #[test]
    fn a_non_finite_frame_is_refused_rather_than_assigned() {
        assert!(is_placeable(VideoRect::xywh(1.0, 2.0, 3.0, 4.0)));
        assert!(!is_placeable(VideoRect::xywh(f64::NAN, 2.0, 3.0, 4.0)));
        assert!(!is_placeable(VideoRect::xywh(1.0, f64::INFINITY, 3.0, 4.0)));
        assert!(!is_placeable(VideoRect::xywh(1.0, 2.0, f64::NAN, 4.0)));
        assert!(!is_placeable(VideoRect::xywh(1.0, 2.0, 3.0, f64::NAN)));
    }

    #[test]
    fn a_retina_bitmap_renders_at_its_logical_size() {
        assert_eq!(
            rendered_shape_size(VideoSize::new(16.0, 24.0), VideoSize::new(32.0, 48.0)),
            VideoSize::new(16.0, 24.0),
        );
    }

    #[test]
    fn a_missing_logical_size_falls_back_to_the_pixels_rather_than_vanishing() {
        assert_eq!(
            rendered_shape_size(VideoSize::new(0.0, 0.0), VideoSize::new(32.0, 48.0)),
            VideoSize::new(32.0, 48.0),
        );
        assert_eq!(
            rendered_shape_size(VideoSize::new(16.0, -1.0), VideoSize::new(32.0, 48.0)),
            VideoSize::new(16.0, 48.0),
            "each axis falls back on its own",
        );
    }

    #[test]
    fn an_oversized_hotspot_is_clamped_instead_of_losing_the_cursor_entirely() {
        let size = VideoSize::new(16.0, 24.0);
        assert_eq!(clamped_hotspot(point(4.0, 6.0), size), point(4.0, 6.0));
        assert_eq!(clamped_hotspot(point(-1.0, 999.0), size), point(0.0, 24.0));
    }
}
