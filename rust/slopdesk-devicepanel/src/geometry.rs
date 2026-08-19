//! Where a device's frame sits in a sidebar, and what a point in that sidebar means.
//!
//! This is the part of a device panel that can be wrong in a way nobody notices until a tap lands
//! two rows off — both Swift files said exactly that, in the two places where it could be wrong two
//! different ways. The arithmetic is now one implementation, and the two panels differ only where
//! their PROTOCOLS differ.
//!
//! ## What the two panels genuinely do not share
//!
//! - **Rotation.** The simulator's framebuffer never turns; the bezel is drawn under a rotation, so
//!   a scroll delta that never passed through the view's geometry disagrees with it by a quarter
//!   turn on a device held sideways — hence [`unrotated`]. `scrcpy` rotates on the DEVICE and
//!   announces the new size in a session packet, so the Android frame is always already the right
//!   way up and there is no angle to be out of step with.
//! - **Whose pixel grid a touch is in.** The simulator host rescales from the fitted rect's own
//!   space. `scrcpy`'s `PositionMapper` does NOT rescale a mismatched pair — it DROPS it — so an
//!   Android touch must be in the video's own grid, paired with the size being encoded
//!   ([`video_pixels`]).
//!
//! ## Vocabulary
//!
//! [`slopdesk_video::geometry`]'s point/size/rect, because the aspect fit here IS
//! [`displayed_video_rect`] — the same law the desktop video client's renderer, input encoder and
//! cursor overlay invert. A panel with its own fit is how a click ends up beside the pixel it was
//! drawn for.

use slopdesk_video::geometry::{VideoContentMode, VideoPoint, VideoRect, VideoSize, displayed_video_rect};

/// How far in from the frame's edge a synthetic contact must stay.
///
/// Planting ON the boundary puts the contact inside the platform's own system-gesture band — the
/// home indicator and the pull-down shades on iOS, the gesture-navigation strip on Android — so a
/// scroll would read as a Back or a Home. The number is the same on both because it is a property
/// of a finger, not of an OS.
pub const EDGE_MARGIN: f64 = 24.0;

/// What a classic wheel NOTCH is worth in points.
///
/// The window server reports a trackpad's delta already in points and a wheel's in LINES, and a
/// line taken as a point is a finger movement of one or two pixels — under both platforms' own
/// touch slop, so the device discards it and the panel looks like it eats scrolls.
pub const POINTS_PER_LINE: f64 = 32.0;

/// How far up the framebuffer iOS's bottom edge gesture reaches, as a fraction.
///
/// `baguette`'s own web UI uses these two numbers and this classification; they are copied rather
/// than re-derived because the server interprets the edge hint against them.
pub const BOTTOM_BAND: f64 = 0.93;
/// How far down the framebuffer iOS's top edge gesture reaches, as a fraction.
pub const TOP_BAND: f64 = 0.07;

/// The largest rect with `content`'s aspect ratio that fits inside `bounds`, centred and rounded to
/// whole points.
///
/// Two things the shared law does not say, and this does. A degenerate input answers the ZERO rect,
/// which the view reads as "nothing to draw yet" — the truth before the first frame — where
/// [`displayed_video_rect`] answers the full view rect. And the result is rounded, because a device
/// frame is drawn on a pixel grid.
#[must_use]
pub fn fitted_rect(content: VideoSize, bounds: VideoSize) -> VideoRect {
    if !(content.width > 0.0 && content.height > 0.0 && bounds.width > 0.0 && bounds.height > 0.0) {
        return VideoRect::xywh(0.0, 0.0, 0.0, 0.0);
    }
    let rect = displayed_video_rect(bounds, content, VideoContentMode::Fit);
    VideoRect::xywh(
        rect.origin.x.round(),
        rect.origin.y.round(),
        rect.size.width.round(),
        rect.size.height.round(),
    )
}

/// A point in panel space in the fitted rect's own space, or `None` when it landed on the bars
/// either side of the frame.
///
/// `None` rather than a clamped edge point on purpose: a click beside the device is not a tap on
/// its edge, and clamping would make the surround a permanently-armed strip that taps the outermost
/// row of pixels.
#[must_use]
pub fn device_point(point: VideoPoint, fitted: VideoRect) -> Option<VideoPoint> {
    if !(fitted.size.width > 0.0 && fitted.size.height > 0.0) {
        return None;
    }
    // Half-open on the far edges, the way a rect's own containment test is: the point at `max_x` is
    // the first column of the bar beside the frame, not the last column of the frame.
    let inside = point.x >= fitted.min_x()
        && point.x < fitted.max_x()
        && point.y >= fitted.min_y()
        && point.y < fitted.max_y();
    if !inside {
        return None;
    }
    Some(VideoPoint::new(
        point.x - fitted.min_x(),
        point.y - fitted.min_y(),
    ))
}

/// The same mapping for a point that may have left the frame mid-drag, CLAMPED instead of dropped.
///
/// A drag legitimately runs off the edge — that is how a shade is pulled down and how a swipe-back
/// finishes — and dropping those would freeze the gesture at the boundary while the button is still
/// held. Only the DOWN that starts a gesture uses the strict form above.
#[must_use]
pub fn clamped_device_point(point: VideoPoint, fitted: VideoRect) -> VideoPoint {
    if !(fitted.size.width > 0.0 && fitted.size.height > 0.0) {
        return VideoPoint::new(0.0, 0.0);
    }
    VideoPoint::new(
        (point.x - fitted.min_x()).max(0.0).min(fitted.size.width - 1.0),
        (point.y - fitted.min_y()).max(0.0).min(fitted.size.height - 1.0),
    )
}

/// A point in the fitted rect's own space, in the video's pixel grid.
///
/// Clamped to the last addressable pixel rather than the size itself: a touch at exactly
/// `video.height` is off the bottom edge of a frame whose rows are `0..height`. An unusable pair —
/// a stream that has not named a size, a panel too small to draw in — answers the origin, and the
/// caller should not be sending at all (see [`surface_is_usable`]).
#[must_use]
pub fn video_pixels(point: VideoPoint, fitted: VideoRect, video: VideoSize) -> VideoPoint {
    if !surface_is_usable(fitted, video) {
        return VideoPoint::new(0.0, 0.0);
    }
    VideoPoint::new(
        (point.x * video.width / fitted.size.width)
            .max(0.0)
            .min(video.width - 1.0),
        (point.y * video.height / fitted.size.height)
            .max(0.0)
            .min(video.height - 1.0),
    )
}

/// Whether a positional message may be built at all: the frame is drawn somewhere, and the stream
/// has said what it is encoding. A message from an unusable pair would be discarded by the device.
#[must_use]
pub fn surface_is_usable(fitted: VideoRect, video: VideoSize) -> bool {
    fitted.size.width > 0.0 && fitted.size.height > 0.0 && video.width > 0.0 && video.height > 0.0
}

/// One scroll event's delta as FINGER TRAVEL, in points.
///
/// SCALE only: a precise (trackpad) delta is already in points, a classic wheel's is in lines.
///
/// SIGN is pass-through, and deliberately so. The window server has ALREADY applied the user's
/// scroll-direction preference; folding in the raw device direction double-applies it, and
/// synthesized events report that flag unset whatever the setting. That trap cost the simulator
/// panel a round and is recorded in `docs/47`.
#[must_use]
pub fn scroll_vector(delta: VideoSize, is_precise: bool) -> VideoSize {
    let scale = if is_precise { 1.0 } else { POINTS_PER_LINE };
    VideoSize::new(delta.width * scale, delta.height * scale)
}

/// A screen-space vector in the space of a view drawn at `angle` degrees clockwise.
///
/// Quarter turns only, which is all a simulator orientation produces — spelled out rather than run
/// through trigonometry so the four cases are readable and a test can pin them exactly.
#[must_use]
pub fn unrotated(vector: VideoSize, angle: f64) -> VideoSize {
    // A non-finite angle rounds to nothing an `i64` can hold, so it reads as no rotation.
    let quarter = if angle.is_finite() {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "an orientation is one of four quarter turns; anything else falls through"
        )]
        let rounded = angle.round() as i64;
        rounded
    } else {
        0
    };
    match quarter {
        90 => VideoSize::new(vector.height, -vector.width),
        -90 | 270 => VideoSize::new(-vector.height, vector.width),
        180 | -180 => VideoSize::new(-vector.width, -vector.height),
        _ => vector,
    }
}

/// The two contacts a pinch is made of: a pair straddling `centre`, `spread` points apart along the
/// diagonal.
///
/// The diagonal rather than the horizontal so a spread has room in both axes on a screen far taller
/// than it is wide, and clamped inside the frame because a finger past the edge is a system gesture
/// rather than a zoom.
#[must_use]
pub fn pinch_fingers(centre: VideoPoint, spread: f64, fitted: VideoRect) -> (VideoPoint, VideoPoint) {
    // Half the spread, projected onto the diagonal. Kept as written — separate multiplies, no FMA.
    let arm = spread / 2.0 * (2.0_f64.sqrt() / 2.0);
    let inset = 1.0;
    let clamped = |point: VideoPoint| {
        VideoPoint::new(
            point.x.max(inset).min(inset.max(fitted.size.width - inset)),
            point.y.max(inset).min(inset.max(fitted.size.height - inset)),
        )
    };
    (
        clamped(VideoPoint::new(centre.x + arm, centre.y + arm)),
        clamped(VideoPoint::new(centre.x - arm, centre.y - arm)),
    )
}

/// `point`, moved inside the frame by [`EDGE_MARGIN`].
///
/// The fallback is the CENTRE of the axis, for a frame too small to hold two margins: a sliver has
/// no valid band, and the middle is the only place that is not an edge.
#[must_use]
pub fn planted(point: VideoPoint, fitted: VideoRect) -> VideoPoint {
    VideoPoint::new(
        banded(
            point.x,
            EDGE_MARGIN,
            fitted.size.width - EDGE_MARGIN,
            fitted.size.width / 2.0,
        ),
        banded(
            point.y,
            EDGE_MARGIN,
            fitted.size.height - EDGE_MARGIN,
            fitted.size.height / 2.0,
        ),
    )
}

/// Where the finger lands after running out of screen: at the far end of the axis it was travelling
/// along, so the next stretch of the same gesture has the full height to move through.
///
/// This is a hand lifting and planting again, which is what makes a long scroll one gesture rather
/// than a series of unrelated flicks — and both panels reconstruct a real finger for the same
/// reason, however differently they then spell the contact on the wire.
#[must_use]
pub fn regrip(travel: VideoSize, fitted: VideoRect) -> VideoPoint {
    let far = |extent: f64, direction: f64| {
        if direction >= 0.0 {
            EDGE_MARGIN
        } else {
            extent - EDGE_MARGIN
        }
    };
    let is_vertical = travel.height.abs() >= travel.width.abs();
    let point = if is_vertical {
        VideoPoint::new(fitted.size.width / 2.0, far(fitted.size.height, travel.height))
    } else {
        VideoPoint::new(far(fitted.size.width, travel.width), fitted.size.height / 2.0)
    };
    planted(point, fitted)
}

/// A system edge a contact can start on — the hint that lets the host drive the home indicator, the
/// app switcher and the pull-down shades from a drag instead of only from a button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum SystemEdge {
    /// The bottom band — the home indicator and the app switcher.
    Bottom = 0,
    /// The top band — the pull-down shades.
    Top = 1,
}

impl SystemEdge {
    /// The byte this crosses as.
    #[must_use]
    pub const fn as_byte(self) -> u8 {
        self as u8
    }
}

/// Which system edge, if any, a contact starting at `point` belongs to.
///
/// `portrait-upside-down` is the case that is not a rotation of the others: the physical bottom
/// edge lands on visual LEFT, so the bands swap axes. The landscape cases deliberately do not — the
/// framebuffer stays portrait whichever way the device is held, and the home indicator stays on the
/// same framebuffer edge.
#[must_use]
pub fn system_edge(point: VideoPoint, fitted: VideoRect, is_upside_down: bool) -> Option<SystemEdge> {
    if !(fitted.size.width > 0.0 && fitted.size.height > 0.0) {
        return None;
    }
    let x_norm = point.x / fitted.size.width;
    let y_norm = point.y / fitted.size.height;
    let in_bottom = if is_upside_down {
        x_norm <= 1.0 - BOTTOM_BAND
    } else {
        y_norm >= BOTTOM_BAND
    };
    if in_bottom {
        return Some(SystemEdge::Bottom);
    }
    let in_top = if is_upside_down {
        x_norm >= BOTTOM_BAND
    } else {
        y_norm <= TOP_BAND
    };
    in_top.then_some(SystemEdge::Top)
}

/// The size the wire carries a positional message's geometry as, clamped rather than truncated: the
/// field is 16 bits, and a size past 65535 would wrap and place every touch at the origin.
#[must_use]
pub fn clamp_to_u16(value: f64) -> u16 {
    if !value.is_finite() || value <= 0.0 {
        return 0;
    }
    if value >= f64::from(u16::MAX) {
        return u16::MAX;
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "guarded: finite and inside 0..u16::MAX"
    )]
    let bounded = value as u16;
    bounded
}

/// A coordinate as the wire's signed 32-bit field, saturating at both ends and answering `0` for a
/// value that is not a number at all.
#[must_use]
pub fn clamp_to_i32(value: f64) -> i32 {
    if !value.is_finite() {
        return 0;
    }
    if value >= f64::from(i32::MAX) {
        return i32::MAX;
    }
    if value <= f64::from(i32::MIN) {
        return i32::MIN;
    }
    #[expect(
        clippy::cast_possible_truncation,
        reason = "guarded: finite and inside i32's range"
    )]
    let bounded = value as i32;
    bounded
}

/// A value held inside `low..=high`, or `fallback` when the band has no room.
fn banded(value: f64, low: f64, high: f64, fallback: f64) -> f64 {
    if low > high {
        fallback
    } else {
        value.max(low).min(high)
    }
}

#[cfg(test)]
#[expect(
    clippy::float_cmp,
    reason = "a panel's geometry is whole points, and the exact value IS what a misplaced tap is"
)]
mod tests {
    use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};

    use super::{
        BOTTOM_BAND, EDGE_MARGIN, POINTS_PER_LINE, SystemEdge, clamp_to_i32, clamp_to_u16,
        clamped_device_point, device_point, fitted_rect, pinch_fingers, planted, regrip, scroll_vector,
        surface_is_usable, system_edge, unrotated, video_pixels,
    };

    /// The real ratio: iPhone 17 Pro at 1206×2622, as the format description reports it.
    const DEVICE: VideoSize = VideoSize::new(1206.0, 2622.0);

    #[test]
    fn a_tall_device_in_a_sidebar_is_width_limited_and_centred() {
        // The counter-intuitive case: the device is tall, but a 320×800 panel is PROPORTIONALLY
        // taller still, so the fit is bounded by width and the bars land above and below.
        let fitted = fitted_rect(DEVICE, VideoSize::new(320.0, 800.0));
        assert_eq!(fitted.size.width, 320.0);
        assert_eq!(fitted.size.height, (320.0 * 2622.0 / 1206.0_f64).round());
        assert_eq!(fitted.min_x(), 0.0);
        assert_eq!(fitted.min_y(), ((800.0 - fitted.size.height) / 2.0).round());
    }

    #[test]
    fn a_short_panel_flips_the_limit_to_height_and_it_is_still_a_fit() {
        let fitted = fitted_rect(DEVICE, VideoSize::new(320.0, 400.0));
        assert_eq!(fitted.size.height, 400.0);
        assert_eq!(fitted.size.width, (400.0 * 1206.0 / 2622.0_f64).round());
        assert_eq!(fitted.min_y(), 0.0);
        assert_eq!(fitted.min_x(), ((320.0 - fitted.size.width) / 2.0).round());
        // Aspect-FIT, never fill: cropping a phone hides the status bar or the home indicator,
        // which are exactly what someone mirroring a device is watching.
        let wide = fitted_rect(DEVICE, VideoSize::new(2000.0, 400.0));
        assert_eq!(wide.size.height, 400.0);
        assert!(wide.size.width < 2000.0);
    }

    #[test]
    fn a_degenerate_fit_is_the_zero_rect_rather_than_the_whole_panel() {
        let nothing = VideoRect::xywh(0.0, 0.0, 0.0, 0.0);
        assert_eq!(
            fitted_rect(VideoSize::new(0.0, 0.0), VideoSize::new(10.0, 10.0)),
            nothing
        );
        assert_eq!(
            fitted_rect(VideoSize::new(10.0, 10.0), VideoSize::new(0.0, 0.0)),
            nothing
        );
        assert_eq!(
            fitted_rect(VideoSize::new(f64::NAN, 10.0), VideoSize::new(10.0, 10.0)),
            nothing
        );
    }

    #[test]
    fn a_click_beside_the_frame_is_not_a_tap_on_its_edge() {
        let fitted = VideoRect::xywh(50.0, 0.0, 200.0, 400.0);
        assert_eq!(
            device_point(VideoPoint::new(150.0, 60.0), fitted),
            Some(VideoPoint::new(100.0, 60.0))
        );
        assert_eq!(device_point(VideoPoint::new(10.0, 60.0), fitted), None);
        assert_eq!(device_point(VideoPoint::new(150.0, 500.0), fitted), None);
        assert_eq!(
            device_point(VideoPoint::new(150.0, 60.0), VideoRect::xywh(0.0, 0.0, 0.0, 0.0)),
            None
        );
    }

    #[test]
    fn a_drag_that_runs_off_the_edge_clamps_instead_of_stopping() {
        let fitted = VideoRect::xywh(50.0, 0.0, 200.0, 400.0);
        assert_eq!(
            clamped_device_point(VideoPoint::new(-100.0, 60.0), fitted),
            VideoPoint::new(0.0, 60.0)
        );
        // The LAST addressable point, not the size itself.
        assert_eq!(
            clamped_device_point(VideoPoint::new(9999.0, 9999.0), fitted),
            VideoPoint::new(199.0, 399.0)
        );
        assert_eq!(
            clamped_device_point(VideoPoint::new(9.0, 9.0), VideoRect::xywh(0.0, 0.0, 0.0, 0.0)),
            VideoPoint::new(0.0, 0.0)
        );
    }

    #[test]
    fn a_touch_crosses_in_the_grid_the_server_is_encoding() {
        let fitted = VideoRect::xywh(0.0, 0.0, 200.0, 400.0);
        let video = VideoSize::new(1080.0, 2160.0);
        assert!(surface_is_usable(fitted, video));
        assert_eq!(
            video_pixels(VideoPoint::new(100.0, 200.0), fitted, video),
            VideoPoint::new(540.0, 1080.0)
        );
        // The bottom-right corner of the fitted rect is the last PIXEL, not one past it.
        assert_eq!(
            video_pixels(VideoPoint::new(200.0, 400.0), fitted, video),
            VideoPoint::new(1079.0, 2159.0)
        );
        // No size on the wire yet: nothing to send, and nothing that could be misread as a corner.
        let blind = VideoSize::new(0.0, 0.0);
        assert!(!surface_is_usable(fitted, blind));
        assert_eq!(
            video_pixels(VideoPoint::new(100.0, 200.0), fitted, blind),
            VideoPoint::new(0.0, 0.0)
        );
    }

    #[test]
    fn a_wheel_notch_is_worth_a_finger_movement_and_a_trackpad_delta_is_already_one() {
        assert_eq!(
            scroll_vector(VideoSize::new(0.0, 3.0), false),
            VideoSize::new(0.0, 3.0 * POINTS_PER_LINE)
        );
        assert_eq!(
            scroll_vector(VideoSize::new(0.0, 3.0), true),
            VideoSize::new(0.0, 3.0)
        );
        // Sign is pass-through: the preference has already been applied upstream.
        assert_eq!(
            scroll_vector(VideoSize::new(0.0, -2.0), true),
            VideoSize::new(0.0, -2.0)
        );
    }

    #[test]
    fn a_quarter_turn_is_undone_exactly_and_anything_else_passes_through() {
        let vector = VideoSize::new(3.0, 7.0);
        assert_eq!(unrotated(vector, 0.0), vector);
        assert_eq!(unrotated(vector, 90.0), VideoSize::new(7.0, -3.0));
        assert_eq!(unrotated(vector, -90.0), VideoSize::new(-7.0, 3.0));
        assert_eq!(unrotated(vector, 270.0), VideoSize::new(-7.0, 3.0));
        assert_eq!(unrotated(vector, 180.0), VideoSize::new(-3.0, -7.0));
        // Round-trip, and a nonsense angle that must not trap.
        assert_eq!(unrotated(unrotated(vector, 90.0), -90.0), vector);
        assert_eq!(unrotated(vector, f64::NAN), vector);
        assert_eq!(unrotated(vector, 45.0), vector);
    }

    #[test]
    fn a_pinch_straddles_its_centre_and_stays_inside_the_frame() {
        let fitted = VideoRect::xywh(0.0, 0.0, 200.0, 400.0);
        let (first, second) = pinch_fingers(VideoPoint::new(100.0, 200.0), 80.0, fitted);
        assert!(
            first.x > second.x && first.y > second.y,
            "a pair straddling the centre"
        );
        assert!((f64::midpoint(first.x, second.x) - 100.0).abs() < 0.001);
        // A spread wider than the frame still lands two contacts on it.
        let (wide, narrow) = pinch_fingers(VideoPoint::new(100.0, 200.0), 100_000.0, fitted);
        let inside =
            |finger: VideoPoint| finger.x >= 1.0 && finger.x <= 199.0 && finger.y >= 1.0 && finger.y <= 399.0;
        assert!(
            inside(wide) && inside(narrow),
            "a contact past the edge is a system gesture"
        );
    }

    #[test]
    fn a_synthetic_finger_never_lands_in_the_system_gesture_band() {
        let fitted = VideoRect::xywh(0.0, 0.0, 200.0, 400.0);
        assert_eq!(
            planted(VideoPoint::new(0.0, 0.0), fitted),
            VideoPoint::new(EDGE_MARGIN, EDGE_MARGIN)
        );
        assert_eq!(
            planted(VideoPoint::new(9999.0, 9999.0), fitted),
            VideoPoint::new(200.0 - EDGE_MARGIN, 400.0 - EDGE_MARGIN)
        );
        // A sliver has no valid band at all, so the middle — the only place that is not an edge.
        let sliver = VideoRect::xywh(0.0, 0.0, 10.0, 10.0);
        assert_eq!(
            planted(VideoPoint::new(0.0, 0.0), sliver),
            VideoPoint::new(5.0, 5.0)
        );
    }

    #[test]
    fn a_regrip_lands_at_the_far_end_of_the_axis_the_finger_was_travelling() {
        let fitted = VideoRect::xywh(0.0, 0.0, 200.0, 400.0);
        // Travelling DOWN the screen: replant at the top, with the full height still to go.
        assert_eq!(
            regrip(VideoSize::new(0.0, 30.0), fitted),
            VideoPoint::new(100.0, EDGE_MARGIN)
        );
        assert_eq!(
            regrip(VideoSize::new(0.0, -30.0), fitted),
            VideoPoint::new(100.0, 400.0 - EDGE_MARGIN)
        );
        // A mostly-horizontal travel regrips along the other axis, centred on this one.
        assert_eq!(
            regrip(VideoSize::new(-30.0, 1.0), fitted),
            VideoPoint::new(200.0 - EDGE_MARGIN, 200.0)
        );
    }

    #[test]
    fn the_edge_bands_are_where_the_host_reads_them() {
        let fitted = VideoRect::xywh(0.0, 0.0, 200.0, 400.0);
        let at = |y: f64| system_edge(VideoPoint::new(100.0, y), fitted, false);
        assert_eq!(at(399.0), Some(SystemEdge::Bottom));
        assert_eq!(at(400.0 * BOTTOM_BAND), Some(SystemEdge::Bottom));
        assert_eq!(at(1.0), Some(SystemEdge::Top));
        assert_eq!(at(200.0), None);
        assert_eq!(
            system_edge(
                VideoPoint::new(100.0, 399.0),
                VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
                false
            ),
            None
        );
    }

    #[test]
    fn upside_down_swaps_the_bands_onto_the_other_axis() {
        let fitted = VideoRect::xywh(0.0, 0.0, 200.0, 400.0);
        let at = |x: f64| system_edge(VideoPoint::new(x, 200.0), fitted, true);
        // The physical bottom edge is now visual LEFT.
        assert_eq!(at(1.0), Some(SystemEdge::Bottom));
        assert_eq!(at(199.0), Some(SystemEdge::Top));
        assert_eq!(at(100.0), None);
        // And the y band no longer decides anything.
        assert_eq!(system_edge(VideoPoint::new(100.0, 399.0), fitted, true), None);
    }

    #[test]
    fn a_size_past_the_wire_field_saturates_rather_than_wrapping() {
        assert_eq!(clamp_to_u16(1080.0), 1080);
        assert_eq!(clamp_to_u16(70_000.0), u16::MAX);
        assert_eq!(clamp_to_u16(-1.0), 0);
        assert_eq!(clamp_to_u16(f64::NAN), 0);
        assert_eq!(clamp_to_i32(-5.0), -5);
        assert_eq!(clamp_to_i32(1e18), i32::MAX);
        assert_eq!(clamp_to_i32(-1e18), i32::MIN);
        assert_eq!(clamp_to_i32(f64::NAN), 0);
    }

    #[test]
    fn every_edge_survives_the_byte_it_crosses_as() {
        assert_eq!(SystemEdge::Bottom.as_byte(), 0);
        assert_eq!(SystemEdge::Top.as_byte(), 1);
    }
}
