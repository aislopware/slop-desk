//! Where a device panel's frame sits, and what a point in it means, in C.
//!
//! The rules are `slopdesk_devicepanel::geometry`'s. Every one of them is a handful of `f64`s in
//! and a point, a size or a kind out, so nothing crosses through a buffer: the vocabulary is
//! [`crate::video_policy`]'s point/size/rect, which is already the shape the aspect-fit door next
//! to it speaks — a panel and the desktop renderer inverting the same law had better be saying it
//! in the same words.
//!
//! The two answers that can DECLINE — a click on the bars beside the frame, a contact that belongs
//! to no system edge — say so with a code rather than a sentinel coordinate, because every
//! coordinate is a real one.
//!
//! What is NOT here is the scroll machine — the wheel's scale, the quarter turn, the plant and the
//! re-grip, and the four metrics they are written against. Those were doors while Swift still ran
//! the gesture; the gesture is now [`crate::panel_scroll`]'s handle, which reaches
//! `geometry::{scroll_vector, unrotated, planted, regrip}` inside Rust. Re-exporting them would be
//! an entry point with no caller, which is how a hand-maintained header drifts.

use slopdesk_devicepanel::geometry::{
    SystemEdge, clamp_to_i32, clamp_to_u16, clamped_device_point, device_point, fitted_rect, pinch_fingers,
    surface_is_usable, system_edge, video_pixels,
};

use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

/// The contact belongs to no system edge.
pub const SLOPDESK_PANEL_EDGE_NONE: u32 = 0;
/// The bottom band — the home indicator and the app switcher.
pub const SLOPDESK_PANEL_EDGE_BOTTOM: u32 = 1;
/// The top band — the pull-down shades.
pub const SLOPDESK_PANEL_EDGE_TOP: u32 = 2;

/// A pinch's two contacts, which are only ever produced together.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskPinchPair {
    /// The contact on the far side of the centre along the diagonal.
    pub first: SlopDeskVideoPoint,
    /// The contact on the near side.
    pub second: SlopDeskVideoPoint,
}

/// Where the frame sits inside a panel of `bounds`: aspect-fit, centred, on whole points. A
/// degenerate input answers the zero rect — "nothing to draw yet".
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_fitted_rect(
    content: SlopDeskVideoSize,
    bounds: SlopDeskVideoSize,
) -> SlopDeskVideoRect {
    SlopDeskVideoRect::from(fitted_rect(content.of(), bounds.of()))
}

/// A panel-space point in the frame's own space. `false` — and `out` untouched — for a click on the
/// bars beside the frame, which is not a tap on its edge.
///
/// # Safety
/// `out` must be null or writable for one point.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_panel_device_point(
    point: SlopDeskVideoPoint,
    fitted: SlopDeskVideoRect,
    out: *mut SlopDeskVideoPoint,
) -> bool {
    let Some(answer) = device_point(point.of(), fitted.of()) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable for one point.
        unsafe { std::ptr::write(out, SlopDeskVideoPoint::from(answer)) };
    }
    true
}

/// The same mapping for a point that left the frame mid-drag: clamped to the last addressable point
/// rather than dropped, so a shade-pull or a swipe-back finishes.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_clamped_device_point(
    point: SlopDeskVideoPoint,
    fitted: SlopDeskVideoRect,
) -> SlopDeskVideoPoint {
    SlopDeskVideoPoint::from(clamped_device_point(point.of(), fitted.of()))
}

/// A point in the fitted rect's own space, in the pixel grid the stream says it is encoding — the
/// only grid `scrcpy` will accept a positional message in.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_video_pixels(
    point: SlopDeskVideoPoint,
    fitted: SlopDeskVideoRect,
    video: SlopDeskVideoSize,
) -> SlopDeskVideoPoint {
    SlopDeskVideoPoint::from(video_pixels(point.of(), fitted.of(), video.of()))
}

/// Whether a positional message may be built at all: a frame drawn somewhere, and a stream that has
/// named its size.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_surface_is_usable(
    fitted: SlopDeskVideoRect,
    video: SlopDeskVideoSize,
) -> bool {
    surface_is_usable(fitted.of(), video.of())
}

/// A pinch's two contacts: a pair straddling `centre` along the diagonal, clamped inside the frame.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_pinch_fingers(
    centre: SlopDeskVideoPoint,
    spread: f64,
    fitted: SlopDeskVideoRect,
) -> SlopDeskPinchPair {
    let (first, second) = pinch_fingers(centre.of(), spread, fitted.of());
    SlopDeskPinchPair {
        first: SlopDeskVideoPoint::from(first),
        second: SlopDeskVideoPoint::from(second),
    }
}

/// Which system edge a contact starting at `point` belongs to, or `SLOPDESK_PANEL_EDGE_NONE`.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_system_edge(
    point: SlopDeskVideoPoint,
    fitted: SlopDeskVideoRect,
    is_upside_down: bool,
) -> u32 {
    match system_edge(point.of(), fitted.of(), is_upside_down) {
        None => SLOPDESK_PANEL_EDGE_NONE,
        Some(SystemEdge::Bottom) => SLOPDESK_PANEL_EDGE_BOTTOM,
        Some(SystemEdge::Top) => SLOPDESK_PANEL_EDGE_TOP,
    }
}

/// A geometry as the wire's unsigned 16-bit field, saturating rather than wrapping.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_clamp_u16(value: f64) -> u16 {
    clamp_to_u16(value)
}

/// A coordinate as the wire's signed 32-bit field, saturating at both ends.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_panel_clamp_i32(value: f64) -> i32 {
    clamp_to_i32(value)
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::float_cmp,
    reason = "the tests call the C entry points, and a panel's geometry is exact whole points"
)]
mod tests {
    use super::{
        SLOPDESK_PANEL_EDGE_BOTTOM, SLOPDESK_PANEL_EDGE_NONE, SLOPDESK_PANEL_EDGE_TOP,
        slopdesk_panel_clamp_i32, slopdesk_panel_clamp_u16, slopdesk_panel_clamped_device_point,
        slopdesk_panel_device_point, slopdesk_panel_fitted_rect, slopdesk_panel_pinch_fingers,
        slopdesk_panel_surface_is_usable, slopdesk_panel_system_edge, slopdesk_panel_video_pixels,
    };
    use crate::video_policy::{SlopDeskVideoPoint, SlopDeskVideoRect, SlopDeskVideoSize};

    const FRAME: SlopDeskVideoRect = SlopDeskVideoRect {
        x: 0.0,
        y: 0.0,
        width: 200.0,
        height: 400.0,
    };

    const fn point(x: f64, y: f64) -> SlopDeskVideoPoint {
        SlopDeskVideoPoint { x, y }
    }

    const fn size(width: f64, height: f64) -> SlopDeskVideoSize {
        SlopDeskVideoSize { width, height }
    }

    #[test]
    fn the_fit_crosses_rounded_and_a_degenerate_one_crosses_as_nothing() {
        let fitted = slopdesk_panel_fitted_rect(size(1206.0, 2622.0), size(320.0, 800.0));
        assert_eq!(fitted.width, 320.0);
        assert_eq!(fitted.height, (320.0 * 2622.0 / 1206.0_f64).round());
        assert_eq!(
            slopdesk_panel_fitted_rect(size(0.0, 0.0), size(320.0, 800.0)),
            SlopDeskVideoRect::default()
        );
    }

    #[test]
    fn a_click_beside_the_frame_declines_with_the_flag_rather_than_a_coordinate() {
        let mut out = SlopDeskVideoPoint::default();
        assert!(unsafe { slopdesk_panel_device_point(point(150.0, 60.0), FRAME, &raw mut out) });
        assert_eq!(out, point(150.0, 60.0));
        // Off the frame: `false`, and the caller's point is left exactly as it was.
        assert!(!unsafe { slopdesk_panel_device_point(point(150.0, 500.0), FRAME, &raw mut out) });
        assert_eq!(out, point(150.0, 60.0));
        // A null out is the "did it land?" question on its own.
        assert!(unsafe { slopdesk_panel_device_point(point(1.0, 1.0), FRAME, std::ptr::null_mut()) });
    }

    #[test]
    fn a_drag_off_the_edge_and_a_touch_in_the_video_grid_both_cross() {
        assert_eq!(
            slopdesk_panel_clamped_device_point(point(9999.0, 9999.0), FRAME),
            point(199.0, 399.0)
        );
        let video = size(1080.0, 2160.0);
        assert!(slopdesk_panel_surface_is_usable(FRAME, video));
        assert_eq!(
            slopdesk_panel_video_pixels(point(100.0, 200.0), FRAME, video),
            point(540.0, 1080.0)
        );
        assert!(!slopdesk_panel_surface_is_usable(FRAME, size(0.0, 0.0)));
    }

    #[test]
    fn a_pinch_crosses_as_the_pair_it_is() {
        let pair = slopdesk_panel_pinch_fingers(point(100.0, 200.0), 80.0, FRAME);
        assert!(pair.first.x > pair.second.x && pair.first.y > pair.second.y);
        assert_eq!(f64::midpoint(pair.first.x, pair.second.x), 100.0);
    }

    #[test]
    fn an_edge_crosses_as_a_code_and_no_edge_has_one_of_its_own() {
        assert_eq!(
            slopdesk_panel_system_edge(point(100.0, 395.0), FRAME, false),
            SLOPDESK_PANEL_EDGE_BOTTOM
        );
        assert_eq!(
            slopdesk_panel_system_edge(point(100.0, 4.0), FRAME, false),
            SLOPDESK_PANEL_EDGE_TOP
        );
        assert_eq!(
            slopdesk_panel_system_edge(point(100.0, 200.0), FRAME, false),
            SLOPDESK_PANEL_EDGE_NONE
        );
        // Upside down the bands are on the other axis.
        assert_eq!(
            slopdesk_panel_system_edge(point(4.0, 200.0), FRAME, true),
            SLOPDESK_PANEL_EDGE_BOTTOM
        );
        assert_eq!(
            slopdesk_panel_system_edge(point(100.0, 395.0), FRAME, true),
            SLOPDESK_PANEL_EDGE_NONE
        );
    }

    #[test]
    fn a_wire_field_saturates_rather_than_wrapping() {
        assert_eq!(slopdesk_panel_clamp_u16(1080.0), 1080);
        assert_eq!(slopdesk_panel_clamp_u16(70_000.0), u16::MAX);
        assert_eq!(slopdesk_panel_clamp_u16(f64::NAN), 0);
        assert_eq!(slopdesk_panel_clamp_i32(-5.0), -5);
        assert_eq!(slopdesk_panel_clamp_i32(1e18), i32::MAX);
    }
}
