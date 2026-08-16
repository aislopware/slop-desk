//! Where the client draws the host's cursor, and which way up.
//!
//! `rust/slopdesk-video`'s `cursor_overlay` owns the placement math. The layer itself — the bitmap
//! cache, the transaction that suppresses the implicit animation, the `NSCursor` built from a
//! cached shape — stays in the GUI, because it is `CALayer` and `NSCursor` all the way down.
//!
//! ## Bit-exact, for the same reason the geometry next door is
//! The fit placement maps the host position through the EXACT forward transform the input encoder
//! inverts, so the cursor tracks the same displayed pixel a click lands on. A contracted
//! multiply-add on one side of that pair moves the cursor away from where the click goes, at every
//! zoom and in every letterbox. Both sides call this one function; there is no second rounding.
//!
//! ## An update crosses as its two points
//! The crate's `CursorUpdate` carries a shape id and a visibility flag the placement never reads,
//! so the door takes the position and the hotspot and builds the rest — rather than minting a
//! record type for two fields the caller already holds apart.

use slopdesk_video::cursor::CursorUpdate;
use slopdesk_video::cursor_overlay::{
    bottom_left_origin_y, is_placeable, layer_frame_fit, layer_frame_scalar, rendered_shape_size,
};
use slopdesk_video::geometry::VideoPoint;

use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize, content_mode};

/// The parts of an update the placement reads. The shape id and the visibility flag are the
/// caller's business: one selects a cached bitmap, the other hides a layer.
const fn update(position: SlopDeskVideoPoint, hotspot: SlopDeskVideoPoint) -> CursorUpdate {
    CursorUpdate::new(
        VideoPoint::new(position.x, position.y),
        0,
        VideoPoint::new(hotspot.x, hotspot.y),
        true,
    )
}

/// The one-to-one placement: the host position scaled into view points, hotspot subtracted, so the
/// cursor's TIP lands on the reported position rather than its top-left corner.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_cursor_layer_frame_scalar(
    position: SlopDeskVideoPoint,
    hotspot: SlopDeskVideoPoint,
    video_scale: f64,
    cursor_size: SlopDeskVideoSize,
) -> SlopDeskVideoRect {
    SlopDeskVideoRect::from(layer_frame_scalar(
        &update(position, hotspot),
        video_scale,
        cursor_size.of(),
    ))
}

/// The aspect-fit and zoom-and-pan-correct placement, through the exact transform the input path
/// inverts.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_cursor_layer_frame_fit(
    position: SlopDeskVideoPoint,
    hotspot: SlopDeskVideoPoint,
    view: SlopDeskVideoSize,
    video_native: SlopDeskVideoSize,
    zoom: f64,
    pan: SlopDeskVideoPoint,
    cursor_size: SlopDeskVideoSize,
    mode: u32,
) -> SlopDeskVideoRect {
    SlopDeskVideoRect::from(layer_frame_fit(
        &update(position, hotspot),
        view.of(),
        video_native.of(),
        zoom,
        VideoPoint::new(pan.x, pan.y),
        cursor_size.of(),
        content_mode(mode),
    ))
}

/// A TOP-LEFT layer origin as the BOTTOM-LEFT one a macOS layer-backed view uses for its sublayers.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_cursor_bottom_left_origin_y(
    top_left_y: f64,
    height: f64,
    parent_height: f64,
) -> f64 {
    bottom_left_origin_y(top_left_y, height, parent_height)
}

/// Whether a computed frame is safe to assign to a layer. A non-finite component raises an uncaught
/// geometry exception that kills the process, so a frame that fails is SKIPPED.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_cursor_is_placeable(frame: SlopDeskVideoRect) -> bool {
    is_placeable(frame.of())
}

/// The size the overlay should render at, given the shape's logical point size and the raw bitmap.
/// A degenerate logical size falls back to the bitmap's own pixels rather than collapsing to
/// nothing.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_cursor_rendered_shape_size(
    logical: SlopDeskVideoSize,
    bitmap_pixels: SlopDeskVideoSize,
) -> SlopDeskVideoSize {
    let answer = rendered_shape_size(logical.of(), bitmap_pixels.of());
    SlopDeskVideoSize {
        width: answer.width,
        height: answer.height,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        slopdesk_cursor_bottom_left_origin_y, slopdesk_cursor_is_placeable, slopdesk_cursor_layer_frame_fit,
        slopdesk_cursor_layer_frame_scalar, slopdesk_cursor_rendered_shape_size,
    };
    use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

    const FIT: u32 = 0;

    fn at(x: f64, y: f64) -> SlopDeskVideoPoint {
        SlopDeskVideoPoint { x, y }
    }

    fn of(width: f64, height: f64) -> SlopDeskVideoSize {
        SlopDeskVideoSize { width, height }
    }

    #[test]
    fn the_scalar_placement_puts_the_tip_on_the_reported_position() {
        let frame = slopdesk_cursor_layer_frame_scalar(at(100.0, 50.0), at(4.0, 6.0), 2.0, of(24.0, 24.0));
        assert!((frame.x - 196.0).abs() < 1e-12);
        assert!((frame.y - 94.0).abs() < 1e-12);
        assert!((frame.width - 24.0).abs() < 1e-12);
    }

    #[test]
    fn the_fit_placement_agrees_with_the_scalar_one_when_nothing_is_letterboxed() {
        // A view exactly the native size, unzoomed: the two placements must land on the same pixel.
        let scalar = slopdesk_cursor_layer_frame_scalar(at(100.0, 50.0), at(4.0, 6.0), 1.0, of(24.0, 24.0));
        let fit = slopdesk_cursor_layer_frame_fit(
            at(100.0, 50.0),
            at(4.0, 6.0),
            of(800.0, 600.0),
            of(800.0, 600.0),
            1.0,
            at(0.0, 0.0),
            of(24.0, 24.0),
            FIT,
        );
        assert!((fit.x - scalar.x).abs() < 1e-12);
        assert!((fit.y - scalar.y).abs() < 1e-12);
    }

    #[test]
    fn a_top_left_origin_flips_into_the_parents_bottom_left_space() {
        assert!((slopdesk_cursor_bottom_left_origin_y(10.0, 24.0, 600.0) - 566.0).abs() < 1e-12);
    }

    #[test]
    fn a_non_finite_frame_is_never_placeable() {
        assert!(slopdesk_cursor_is_placeable(SlopDeskVideoRect {
            x: 1.0,
            y: 2.0,
            width: 3.0,
            height: 4.0,
        }));
        assert!(!slopdesk_cursor_is_placeable(SlopDeskVideoRect {
            x: f64::NAN,
            y: 2.0,
            width: 3.0,
            height: 4.0,
        }));
    }

    #[test]
    fn a_degenerate_logical_size_falls_back_to_the_bitmap_pixels() {
        let answer = slopdesk_cursor_rendered_shape_size(of(0.0, 16.0), of(32.0, 32.0));
        assert!((answer.width - 32.0).abs() < 1e-12);
        assert!((answer.height - 16.0).abs() < 1e-12);
    }
}
