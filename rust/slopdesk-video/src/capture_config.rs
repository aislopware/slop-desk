//! What shape a capture stream takes, decided without `ScreenCaptureKit` in the room.
//!
//! Every knob `WindowCapturer` used to resolve inline — the delivery ceiling, the surface queue
//! depth, the crisp quiet window, the poll tick, which content filter to build, whether a live
//! resize may happen in place — is a clamp over an environment string and a couple of numbers. None
//! of it needs a framework, and all of it was untestable where it sat: the file it lived in cannot
//! be instantiated without a window server and a Screen-Recording grant, so its rules were
//! exercised only by whichever fragments had been split out by hand for that purpose.
//!
//! They are all here now, and `slopdesk-apple-sck` — which does need the window server — reads them
//! rather than deciding anything.
//!
//! ## Why the ceilings are what they are
//! The two that are not obvious carry their measurement with them. The delivery ceiling defaults to
//! TWICE the encode rate because a capture interval equal to the encode interval quantises when
//! `ScreenCaptureKit` may hand over a fresh composite: a change landing just after a slot waits out
//! the rest of it. At a 1× ceiling that beat against the source compositor's commit time cost ~3
//! fps and clustered ~30 ms double-slot gaps through every scroll; at 2× there were none over a
//! 14 600-frame session, and the ENCODE rate — and so the bitrate — is untouched either way.
//! Raising both instead (`--fps 120`) measured WORSE glass-to-glass, by ~18 ms at p50.
//!
//! The surface queue defaults to five because the encode runs synchronously on the sample-handler
//! queue, so one fat scroll-burst frame blocks the next delivery as soon as it over-runs
//! `interval × (depth − 1)` — a measured 61 ms capture gap at depth three.

use crate::geometry::{VideoPoint, VideoRect};

/// The lowest delivery ceiling an operator may ask for, in Hz. Below this a capture stream is
/// slower than the cadence gate it feeds and the gate's arithmetic stops meaning anything.
pub const CAPTURE_HZ_FLOOR: i32 = 15;

/// The highest delivery ceiling, in Hz.
///
/// `ScreenCaptureKit` accepts more; nothing downstream does anything useful with it, and the
/// interval becomes a rounding artefact.
pub const CAPTURE_HZ_CEILING: i32 = 240;

/// The delivery ceiling, in Hz.
///
/// An explicit request clamped to `[15, 240]`, else twice the encode rate under the same ceiling.
/// See the module note for why the default is a multiple rather than the encode rate itself.
#[must_use]
pub fn resolve_capture_hz(requested: Option<&str>, fps: i32) -> i32 {
    if let Some(value) = requested.and_then(|text| text.parse::<i32>().ok()) {
        return value.clamp(CAPTURE_HZ_FLOOR, CAPTURE_HZ_CEILING);
    }
    fps.max(1).saturating_mul(2).min(CAPTURE_HZ_CEILING)
}

/// The shallowest surface queue. Two is the framework's own working minimum — one surface in
/// flight and one being filled.
pub const QUEUE_DEPTH_FLOOR: i32 = 2;

/// The deepest surface queue. Past this the queue stops absorbing an encode spike and starts
/// storing latency.
pub const QUEUE_DEPTH_CEILING: i32 = 12;

/// The default surface queue depth — see the module note on the measured 61 ms gap at three.
pub const QUEUE_DEPTH_DEFAULT: i32 = 5;

/// The surface queue depth, clamped to `[2, 12]`.
#[must_use]
pub fn resolve_queue_depth(requested: Option<&str>) -> i32 {
    requested
        .and_then(|text| text.parse::<i32>().ok())
        .map_or(QUEUE_DEPTH_DEFAULT, |value| {
            value.clamp(QUEUE_DEPTH_FLOOR, QUEUE_DEPTH_CEILING)
        })
}

/// The heartbeat IDR cadence in seconds when nothing asks otherwise.
///
/// 2.5 rather than 1: on a window that is never idle every heartbeat is a 50–135 KB burst that the
/// crisp path never fires on, so a tight cadence risks burst loss for no benefit to a client that
/// is already in sync — detected loss recovers through the recovery channel, not through this.
pub const HEARTBEAT_DEFAULT: f64 = 2.5;

/// The shortest heartbeat an operator may ask for, in seconds.
pub const HEARTBEAT_FLOOR: f64 = 0.25;

/// The longest heartbeat, in seconds.
pub const HEARTBEAT_CEILING: f64 = 60.0;

/// The heartbeat IDR cadence in seconds.
///
/// A request OUTSIDE `[0.25, 60]` is refused rather than clamped — this one predates the clamping
/// knobs and its two ends mean different things (a sub-quarter-second heartbeat is a burst
/// generator, a minute-long one is not a heartbeat), so a value at either extreme is more likely a
/// typo than an intention.
#[must_use]
pub fn resolve_heartbeat(requested: Option<&str>) -> f64 {
    match requested.and_then(|text| text.parse::<f64>().ok()) {
        Some(value) if (HEARTBEAT_FLOOR..=HEARTBEAT_CEILING).contains(&value) => value,
        _ => HEARTBEAT_DEFAULT,
    }
}

/// The shortest crisp quiet window, in seconds. Below this the re-anchor fires during a one-frame
/// pause mid-motion.
pub const QUIET_WINDOW_FLOOR: f64 = 0.05;

/// The crisp quiet window when nothing asks otherwise: the re-sharpen target.
pub const QUIET_WINDOW_DEFAULT: f64 = 0.3;

/// How long the static-IDR timer waits after the last real frame, in seconds.
///
/// It is the pause before the crisp near-lossless re-anchor. A request arrives in MILLISECONDS and
/// is clamped to `[0.05, heartbeat]` — never longer than the heartbeat, since a longer window
/// stretches the timer path's recovery suppression.
#[must_use]
pub fn resolve_quiet_window(requested_millis: Option<&str>, heartbeat: f64) -> f64 {
    let ceiling = QUIET_WINDOW_FLOOR.max(heartbeat);
    let wanted = requested_millis
        .and_then(|text| text.parse::<f64>().ok())
        .map_or(QUIET_WINDOW_DEFAULT, |millis| millis / 1000.0);
    wanted.clamp(QUIET_WINDOW_FLOOR, ceiling)
}

/// The fastest static-IDR poll, in seconds.
pub const IDR_TICK_FLOOR: f64 = 0.02;

/// The slowest static-IDR poll, in seconds.
pub const IDR_TICK_CEILING: f64 = 1.0;

/// The static-IDR poll when nothing asks otherwise, in seconds. At 80 ms the worst case
/// time-to-crisp is the quiet window plus a tick — about 0.38 s.
pub const IDR_TICK_DEFAULT: f64 = 0.08;

/// The static-IDR poll interval in seconds.
///
/// The timer polls the decider — recovery latch, idle service, crisp re-anchor — and the decider
/// only emits when due, so a sub-cadence tick is a cheap no-op. A request arrives in MILLISECONDS
/// and is clamped to `[0.02, 1]`.
#[must_use]
pub fn resolve_idr_poll_tick(requested_millis: Option<&str>) -> f64 {
    requested_millis
        .and_then(|text| text.parse::<f64>().ok())
        .map_or(IDR_TICK_DEFAULT, |millis| {
            (millis / 1000.0).clamp(IDR_TICK_FLOOR, IDR_TICK_CEILING)
        })
}

/// How a capture stream sources a window's pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CaptureMode {
    /// The per-window compositor. Follows the window anywhere, but the capture is anchored to the
    /// bounding rect of the window UNION its child windows, so a child that overhangs the frame —
    /// a browser's link-URL bubble — nudges the crop origin and the whole image shifts about a
    /// pixel while the child is up.
    #[default]
    Window,
    /// The display, cropped to the window's frame in display-local points. Immune to the
    /// child-window nudge and ~5 ms faster at p50, but EVERYTHING overlapping the rect is
    /// captured — correct only when the window is alone on the display.
    DisplayExcluding,
    /// The display, cropped the same way, compositing only the target window and its children.
    /// Display-anchored (no nudge) AND occlusion-proof, so windows stacked on one shared virtual
    /// display cannot bleed into each other. Measured a whole 60 Hz slot faster than
    /// [`Self::Window`] glass-to-glass — 35.8/36.0 ms at p50 against 50.7/51.2 — with p90 equal.
    DisplayIncluding,
}

/// Which filter to build.
///
/// An explicit request wins; otherwise the display-anchored pair is taken when the daemon parked
/// the window on the virtual display, and the per-window compositor when it did not (off the
/// virtual display a window may move and overlap freely).
#[must_use]
pub fn resolve_capture_mode(requested: Option<&str>, prefer_display_anchored: bool) -> CaptureMode {
    match requested {
        Some("window" | "0") => CaptureMode::Window,
        Some("1" | "display") => CaptureMode::DisplayExcluding,
        Some("include" | "display-include") => CaptureMode::DisplayIncluding,
        _ if prefer_display_anchored => CaptureMode::DisplayIncluding,
        _ => CaptureMode::Window,
    }
}

/// The mode a stream with an explicit capture region must run in, whatever was asked for.
///
/// A union region spans the window AND the dialog it put up, which are two windows — and only the
/// including filter composites both. Under the per-window compositor the dialog is not in the
/// capture at all, and under the excluding filter whatever else overlaps the union comes with it.
/// So a region overrides the request rather than being refused by it: the region is the more
/// specific instruction, and it arrived because a dialog is on screen right now.
#[must_use]
pub const fn mode_for_region(requested: CaptureMode, has_region: bool) -> CaptureMode {
    if has_region {
        CaptureMode::DisplayIncluding
    } else {
        requested
    }
}

/// Whether a live resize may reconfigure the running stream instead of restarting it.
///
/// Only when the caller enabled it, the capture is display-anchored — so there is a config with a
/// serialised driver to rewrite — and the crop is not a poller-owned union region. Everything else
/// falls back to a restart.
#[must_use]
pub const fn can_resize_in_place(enabled: bool, display_anchored: bool, union_owned: bool) -> bool {
    enabled && display_anchored && !union_owned
}

/// The sampled region pinned to the window's own frame, in POINTS.
///
/// The pin is the fix for a whole pane going soft whenever a child window pops up. With child
/// windows composited, the captured bounding rect grows to contain them; because the output buffer
/// stays pinned to the window's own size, the framework scales that larger rect DOWN to fit and
/// every static glyph in the frame is resampled into fewer pixels. Naming the source rect maps
/// exactly `(0, 0, w, h)` points into the buffer however far a child pushes the union out, so the
/// content scale stays at 1 and the child is simply cropped at the frame edge rather than
/// shrinking everything else.
///
/// The dimensions arrive in PIXELS (window points × the capture scale) because that is what the
/// output buffer is measured in; the rect is point-space, so it divides back out.
#[must_use]
pub fn pinned_source_rect(pixel_width: i32, pixel_height: i32, capture_scale: f64) -> VideoRect {
    let scale = capture_scale.max(1.0);
    VideoRect::xywh(
        0.0,
        0.0,
        f64::from(pixel_width) / scale,
        f64::from(pixel_height) / scale,
    )
}

/// The window's frame origin expressed in its display's local point space — the origin a
/// display-anchored crop needs.
#[must_use]
pub fn display_local_origin(window_origin: VideoPoint, display_origin: VideoPoint) -> VideoPoint {
    VideoPoint::new(
        window_origin.x - display_origin.x,
        window_origin.y - display_origin.y,
    )
}

/// Whether a moved window has moved far enough to be worth reconfiguring the live stream for.
///
/// Half a point in either axis. Below that the crop would land on the same pixels and the
/// reconfigure would cost a mid-GOP whole-frame delta for nothing.
#[must_use]
pub fn origin_moved(current: VideoPoint, next: VideoPoint) -> bool {
    (next.x - current.x).abs() >= 0.5 || (next.y - current.y).abs() >= 0.5
}

/// Everything a capture stream's configuration is built from, with no framework types in it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaptureSpec {
    /// Output buffer width in pixels.
    pub pixel_width: i32,
    /// Output buffer height in pixels.
    pub pixel_height: i32,
    /// The delivery ceiling in Hz — the reciprocal becomes the minimum frame interval.
    pub capture_hz: i32,
    /// How many surfaces the framework may hold in flight.
    pub queue_depth: i32,
    /// The sampled region, in points.
    pub source_rect: VideoRect,
    /// Capture the full-range NV12 variant rather than the video-range one.
    pub full_range: bool,
    /// Composite the target window's child windows. Only meaningful under
    /// [`CaptureMode::DisplayIncluding`].
    pub include_child_windows: bool,
    /// The audio tap's sample rate in Hz, or `0` for no tap at all.
    pub audio_sample_rate: i32,
    /// The audio tap's channel count. Read only when [`Self::audio_sample_rate`] is non-zero.
    pub audio_channel_count: i32,
}

impl CaptureSpec {
    /// Whether the stream should tap the captured content's audio.
    #[must_use]
    pub const fn captures_audio(&self) -> bool {
        self.audio_sample_rate > 0
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CAPTURE_HZ_CEILING, CAPTURE_HZ_FLOOR, CaptureMode, CaptureSpec, HEARTBEAT_DEFAULT, IDR_TICK_DEFAULT,
        QUEUE_DEPTH_DEFAULT, QUIET_WINDOW_DEFAULT, QUIET_WINDOW_FLOOR, can_resize_in_place,
        display_local_origin, mode_for_region, origin_moved, pinned_source_rect, resolve_capture_hz,
        resolve_capture_mode, resolve_heartbeat, resolve_idr_poll_tick, resolve_queue_depth,
        resolve_quiet_window,
    };
    use crate::geometry::VideoPoint;

    /// The default is a MULTIPLE of the encode rate, and the multiple is what the measurement
    /// bought — see the module note. A test that pinned only the clamp would let the 1× regression
    /// back in silently.
    #[test]
    fn the_delivery_ceiling_defaults_to_twice_the_encode_rate() {
        assert_eq!(resolve_capture_hz(None, 30), 60);
        assert_eq!(resolve_capture_hz(None, 60), 120);
        assert_eq!(
            resolve_capture_hz(None, 0),
            2,
            "a zero encode rate still yields a live stream"
        );
        assert_eq!(
            resolve_capture_hz(None, 1_000_000),
            CAPTURE_HZ_CEILING,
            "the doubling saturates rather than wrapping",
        );
    }

    /// An explicit ceiling is clamped at both ends, and text that is not a number is not a
    /// request — it answers the default, exactly as an absent value does.
    #[test]
    fn an_explicit_delivery_ceiling_is_clamped_and_a_non_number_is_not_one() {
        assert_eq!(resolve_capture_hz(Some("90"), 30), 90);
        assert_eq!(resolve_capture_hz(Some("1"), 30), CAPTURE_HZ_FLOOR);
        assert_eq!(resolve_capture_hz(Some("10000"), 30), CAPTURE_HZ_CEILING);
        assert_eq!(resolve_capture_hz(Some(""), 30), 60);
        assert_eq!(resolve_capture_hz(Some("fast"), 30), 60);
    }

    /// The surface queue clamps into `[2, 12]` and defaults to the measured five.
    #[test]
    fn the_surface_queue_clamps_around_the_measured_default() {
        assert_eq!(resolve_queue_depth(None), QUEUE_DEPTH_DEFAULT);
        assert_eq!(resolve_queue_depth(Some("0")), 2);
        assert_eq!(resolve_queue_depth(Some("99")), 12);
        assert_eq!(resolve_queue_depth(Some("7")), 7);
        assert_eq!(resolve_queue_depth(Some("deep")), QUEUE_DEPTH_DEFAULT);
    }

    /// The heartbeat REFUSES an out-of-range request rather than clamping it — the one knob here
    /// that does, and the doc comment says why.
    #[test]
    fn an_out_of_range_heartbeat_is_refused_rather_than_clamped() {
        assert!((resolve_heartbeat(None) - HEARTBEAT_DEFAULT).abs() < f64::EPSILON);
        assert!((resolve_heartbeat(Some("0.1")) - HEARTBEAT_DEFAULT).abs() < f64::EPSILON);
        assert!((resolve_heartbeat(Some("600")) - HEARTBEAT_DEFAULT).abs() < f64::EPSILON);
        assert!((resolve_heartbeat(Some("1.0")) - 1.0).abs() < f64::EPSILON);
        assert!((resolve_heartbeat(Some("0.25")) - 0.25).abs() < f64::EPSILON);
        assert!((resolve_heartbeat(Some("60")) - 60.0).abs() < f64::EPSILON);
    }

    /// The quiet window arrives in milliseconds, floors at 50 ms, and is CEILINGED by the
    /// heartbeat — a longer window would stretch the timer path's recovery suppression past the
    /// anchor it is suppressing against.
    #[test]
    fn the_quiet_window_is_ceilinged_by_the_heartbeat_it_shares_a_timer_with() {
        assert!((resolve_quiet_window(None, 2.5) - QUIET_WINDOW_DEFAULT).abs() < f64::EPSILON);
        assert!((resolve_quiet_window(Some("1"), 2.5) - QUIET_WINDOW_FLOOR).abs() < f64::EPSILON);
        assert!((resolve_quiet_window(Some("120"), 2.5) - 0.12).abs() < f64::EPSILON);
        assert!((resolve_quiet_window(Some("9000"), 2.5) - 2.5).abs() < f64::EPSILON);
        assert!(
            (resolve_quiet_window(None, 0.01) - QUIET_WINDOW_FLOOR).abs() < f64::EPSILON,
            "a heartbeat under the floor cannot push the window below it",
        );
    }

    /// The poll tick clamps into `[20 ms, 1 s]` around its 80 ms default.
    #[test]
    fn the_poll_tick_clamps_around_eighty_milliseconds() {
        assert!((resolve_idr_poll_tick(None) - IDR_TICK_DEFAULT).abs() < f64::EPSILON);
        assert!((resolve_idr_poll_tick(Some("5")) - 0.02).abs() < f64::EPSILON);
        assert!((resolve_idr_poll_tick(Some("5000")) - 1.0).abs() < f64::EPSILON);
        assert!((resolve_idr_poll_tick(Some("40")) - 0.04).abs() < f64::EPSILON);
    }

    /// Every spelling the A/B lever accepts, and the two defaults it falls through to.
    #[test]
    fn every_capture_mode_spelling_resolves_and_the_default_follows_the_park() {
        for text in ["window", "0"] {
            assert_eq!(resolve_capture_mode(Some(text), true), CaptureMode::Window);
        }
        for text in ["1", "display"] {
            assert_eq!(
                resolve_capture_mode(Some(text), false),
                CaptureMode::DisplayExcluding
            );
        }
        for text in ["include", "display-include"] {
            assert_eq!(
                resolve_capture_mode(Some(text), false),
                CaptureMode::DisplayIncluding
            );
        }
        assert_eq!(resolve_capture_mode(None, true), CaptureMode::DisplayIncluding);
        assert_eq!(resolve_capture_mode(None, false), CaptureMode::Window);
        assert_eq!(
            resolve_capture_mode(Some("yes"), false),
            CaptureMode::Window,
            "an unrecognised request is not a request",
        );
    }

    /// A region overrides every mode, including the two an operator can force by hand — and
    /// changes nothing when there is no region.
    #[test]
    fn a_capture_region_forces_the_only_mode_that_composites_a_dialog() {
        for requested in [
            CaptureMode::Window,
            CaptureMode::DisplayExcluding,
            CaptureMode::DisplayIncluding,
        ] {
            assert_eq!(mode_for_region(requested, true), CaptureMode::DisplayIncluding);
            assert_eq!(mode_for_region(requested, false), requested);
        }
    }

    /// The in-place resize gate is a conjunction, and every one of its three terms can veto.
    #[test]
    fn an_in_place_resize_needs_all_three_terms() {
        assert!(can_resize_in_place(true, true, false));
        assert!(!can_resize_in_place(false, true, false));
        assert!(!can_resize_in_place(true, false, false));
        assert!(!can_resize_in_place(true, true, true));
    }

    /// The pin divides pixels back into points, and a scale below one cannot make the rect bigger
    /// than the buffer — a caller that passes `0` gets the buffer's own size, not infinity.
    #[test]
    fn the_pinned_rect_is_the_buffer_measured_in_points() {
        let plain = pinned_source_rect(1920, 1080, 1.0);
        assert!((plain.size.width - 1920.0).abs() < f64::EPSILON);
        assert!((plain.size.height - 1080.0).abs() < f64::EPSILON);
        let retina = pinned_source_rect(1920, 1080, 2.0);
        assert!((retina.size.width - 960.0).abs() < f64::EPSILON);
        assert!((retina.size.height - 540.0).abs() < f64::EPSILON);
        let degenerate = pinned_source_rect(1920, 1080, 0.0);
        assert!((degenerate.size.width - 1920.0).abs() < f64::EPSILON);
        assert!((plain.origin.x).abs() < f64::EPSILON && (plain.origin.y).abs() < f64::EPSILON);
    }

    /// A display-local origin is the window's global origin less the display's, and a move under
    /// half a point is not a move.
    #[test]
    fn a_move_under_half_a_point_is_not_worth_reconfiguring_for() {
        let local = display_local_origin(VideoPoint::new(1450.0, 320.0), VideoPoint::new(1440.0, 0.0));
        assert!((local.x - 10.0).abs() < f64::EPSILON);
        assert!((local.y - 320.0).abs() < f64::EPSILON);
        assert!(!origin_moved(local, VideoPoint::new(10.4, 320.4)));
        assert!(origin_moved(local, VideoPoint::new(10.5, 320.0)));
        assert!(origin_moved(local, VideoPoint::new(10.0, 319.5)));
        assert!(origin_moved(local, VideoPoint::new(-100.0, 320.0)));
    }

    /// The audio tap is keyed off the sample rate alone, so "no tap" and "a tap at zero Hz" cannot
    /// be spelled differently.
    #[test]
    fn a_spec_taps_audio_exactly_when_it_names_a_sample_rate() {
        let base = CaptureSpec {
            pixel_width: 1920,
            pixel_height: 1080,
            capture_hz: 60,
            queue_depth: QUEUE_DEPTH_DEFAULT,
            source_rect: pinned_source_rect(1920, 1080, 1.0),
            full_range: false,
            include_child_windows: false,
            audio_sample_rate: 0,
            audio_channel_count: 2,
        };
        assert!(!base.captures_audio());
        assert!(
            CaptureSpec {
                audio_sample_rate: 48_000,
                ..base
            }
            .captures_audio()
        );
    }
}
