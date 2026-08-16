//! The client's and the host's small pure policies: four questions with no state behind them.
//!
//! A colour matrix for the shader, a normalised click turned into a screen point, one step of the
//! playout buffer, and whether a connected stream has frozen. None of them holds anything between
//! calls, none of them touches a byte of the wire, and each is a handful of arithmetic — which is
//! exactly the shape that gets rewritten in place rather than called, and then drifts.
//!
//! ## Why these cross at all, being so small
//! Two of the four are pinned in `golden/golden_vectors.json` as IEEE bit patterns, which is the
//! whole argument: `coordWindowPoint` and `ycbcr` are the exact numbers a click lands on and the
//! exact numbers the GPU multiplies by. A second implementation of either agrees with the first
//! until a compiler contracts a multiply and an add into one instruction, and then a click lands a
//! pixel off on one machine. The generator now reads them through this door, so the golden corpus
//! is a check on the Rust rather than on a Swift copy of it.
//!
//! ## What is NOT here
//! Every arithmetic decision. `slopdesk-video` owns the clamps, the FMA-free multiply-then-add, the
//! NaN-ignoring maxima and the inclusive stall threshold; this module converts scalars to
//! `#[repr(C)]` records and back, and returns them by value.

use slopdesk_video::capture_recovery::{
    RECREATE_COOLDOWN_SECONDS, arrange_streamable_windows, channels_to_disconnect, should_attempt_recreate,
};
use slopdesk_video::coordinate_mapping::window_point;
use slopdesk_video::geometry::{
    VideoContentMode, VideoPoint, VideoRect, VideoSize, displayed_video_rect, view_point,
};
use slopdesk_video::keepalive::{
    HOST_HEARTBEAT_INTERVAL_SECONDS, IDLE_TIMEOUT_SECONDS, KEEPALIVE_INTERVAL_SECONDS, REAPER_TICK_SECONDS,
    StreamStallPolicy,
};
use slopdesk_video::playout::{PlayoutConfig, step_ms};
use slopdesk_video::stream_stall::{Liveness, StreamVerdict, verdict};
use slopdesk_video::ycbcr::{ColorRange, coefficients};

use crate::records_of;

/// The seven BT.709 YCbCr→RGB coefficients the fragment shader applies.
///
/// `f32` throughout and deliberately: the GPU's arithmetic is single-precision, and an `f64`
/// intermediate narrowed on the way out moves the low bits of numbers this repo pins bit-exactly.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskYCbCrCoefficients {
    /// Luma scale: maps the bias-subtracted luma onto `[0, 1]`.
    pub luma_scale: f32,
    /// Luma bias subtracted before scaling.
    pub luma_bias: f32,
    /// Chroma centre subtracted from Cb and Cr.
    pub chroma_bias: f32,
    /// Cr→R coefficient.
    pub cr_to_r: f32,
    /// Cb→G coefficient.
    pub cb_to_g: f32,
    /// Cr→G coefficient.
    pub cr_to_g: f32,
    /// Cb→B coefficient.
    pub cb_to_b: f32,
}

/// A point in the caller's coordinate space.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskVideoPoint {
    /// Horizontal position.
    pub x: f64,
    /// Vertical position.
    pub y: f64,
}

/// A size in the caller's coordinate space.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskVideoSize {
    /// Horizontal extent.
    pub width: f64,
    /// Vertical extent.
    pub height: f64,
}

impl SlopDeskVideoSize {
    /// The crate's size.
    pub(crate) const fn of(self) -> VideoSize {
        VideoSize::new(self.width, self.height)
    }
}

/// A rectangle in the caller's coordinate space, origin and extent.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskVideoRect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Horizontal extent.
    pub width: f64,
    /// Vertical extent.
    pub height: f64,
}

impl SlopDeskVideoRect {
    /// The crate's rect.
    pub(crate) const fn of(self) -> VideoRect {
        VideoRect::xywh(self.x, self.y, self.width, self.height)
    }

    /// The record a rect reports as.
    pub(crate) const fn from(rect: VideoRect) -> Self {
        Self {
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
        }
    }
}

/// Contain: the whole video sits inside the view, with bars on the longer axis.
pub const SLOPDESK_CONTENT_MODE_FIT: u32 = 0;
/// Cover: the video fills the view and the longer axis is cropped.
pub const SLOPDESK_CONTENT_MODE_FILL: u32 = 1;

/// The content mode a code names. Anything unknown is fit, the default the crate takes.
pub(crate) const fn content_mode(code: u32) -> VideoContentMode {
    if code == SLOPDESK_CONTENT_MODE_FILL {
        VideoContentMode::Fill
    } else {
        VideoContentMode::Fit
    }
}

/// The liveness stamps a stall verdict is read from.
///
/// The two arrival times carry their own presence flag rather than a sentinel time, because "no
/// frame has EVER arrived" and "the last frame arrived at time zero" are different states and only
/// one of them can be a stall.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskLiveness {
    /// The current time, on the caller's monotonic clock.
    pub now: f64,
    /// When the most recent decoded frame arrived; read only when `has_frame`.
    pub last_frame_at: f64,
    /// When the most recent host keepalive arrived; read only when `has_heartbeat`.
    pub last_heartbeat_at: f64,
    /// How long with no signal before a connected stream reads as frozen.
    pub threshold: f64,
    /// Whether `last_frame_at` means anything.
    pub has_frame: bool,
    /// Whether `last_heartbeat_at` means anything.
    pub has_heartbeat: bool,
    /// Whether the session still believes it is connected.
    pub connected: bool,
    /// Whether the host is suppressing frames because the window is static.
    pub idle_skip_active: bool,
}

/// A liveness signal arrived within the threshold.
pub const SLOPDESK_STREAM_LIVE: u32 = 0;
/// Connected, and nothing has arrived for at least the threshold.
pub const SLOPDESK_STREAM_STALLED: u32 = 1;
/// Not connected — the disconnect path owns recovery.
pub const SLOPDESK_STREAM_NOT_CONNECTED: u32 = 2;
/// Nothing has arrived yet; there is nothing to judge.
pub const SLOPDESK_STREAM_UNKNOWN: u32 = 3;

/// The keepalive timing contract, and the stall threshold it is sized against.
///
/// One record, because the five numbers are one argument: the host heartbeat is what the stall
/// threshold tolerates two losses of, and the reaper tick is what makes the idle timeout's
/// worst-case reclaim `IDLE_TIMEOUT + REAPER_TICK`. Splitting them into five entries would let a
/// caller read one and reason about it alone, which is exactly the drift they exist to prevent.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskKeepaliveTiming {
    /// The client keepalive cadence, in seconds.
    pub keepalive_interval: f64,
    /// How long a keepalive-proven flow may be idle before the host declares it dead.
    pub idle_timeout: f64,
    /// The host reaper's scan cadence, in seconds.
    pub reaper_tick: f64,
    /// The host→client heartbeat cadence, in seconds.
    pub host_heartbeat_interval: f64,
    /// How long without a liveness signal the client calls the stream frozen.
    pub stall_threshold: f64,
}

/// The keepalive timing contract.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_keepalive_timing() -> SlopDeskKeepaliveTiming {
    SlopDeskKeepaliveTiming {
        keepalive_interval: KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: IDLE_TIMEOUT_SECONDS,
        reaper_tick: REAPER_TICK_SECONDS,
        host_heartbeat_interval: HOST_HEARTBEAT_INTERVAL_SECONDS,
        stall_threshold: StreamStallPolicy::DEFAULT_THRESHOLD_SECONDS,
    }
}

/// The BT.709 coefficients for a full-range (`true`) or studio-swing (`false`) stream.
///
/// Only the luma pair differs between the two; the chroma centre and the four matrix coefficients
/// are bit-identical, which is why one flag is the whole input.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_ycbcr_coefficients(full_range: bool) -> SlopDeskYCbCrCoefficients {
    let values = coefficients(ColorRange::from_full_range(full_range));
    SlopDeskYCbCrCoefficients {
        luma_scale: values.luma_scale,
        luma_bias: values.luma_bias,
        chroma_bias: values.chroma_bias,
        cr_to_r: values.cr_to_r,
        cb_to_g: values.cb_to_g,
        cr_to_g: values.cr_to_g,
        cb_to_b: values.cb_to_b,
    }
}

/// Maps a normalised (`0..1`) position inside a window to an absolute point in CG top-left space.
///
/// `origin + n * size`, per axis, as a SEPARATE multiply and add — never fused. The client streams
/// normalised coordinates precisely so this is the only conversion, and there is no Y flip here:
/// `kCGWindowBounds` and `CGEvent` mouse positions are already the same space.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_coord_window_point(
    normalized_x: f64,
    normalized_y: f64,
    bounds_x: f64,
    bounds_y: f64,
    bounds_width: f64,
    bounds_height: f64,
) -> SlopDeskVideoPoint {
    let point = window_point(
        VideoPoint::new(normalized_x, normalized_y),
        VideoRect::xywh(bounds_x, bounds_y, bounds_width, bounds_height),
    );
    SlopDeskVideoPoint {
        x: point.x,
        y: point.y,
    }
}

/// One hysteretic step of the playout delay, in milliseconds.
///
/// Grows straight to a larger target and shrinks by at most `shrink_step_ms` per call, so a
/// transient jitter spike decays over several ticks instead of ratcheting the latency up. The knobs
/// arrive already resolved from the environment; each is clamped into its band on the Rust side, so
/// a hostile or absent knob cannot widen the buffer past its ceiling.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_playout_step_ms(
    jitter_seconds: f64,
    prev_playout_ms: f64,
    shrink_step_ms: f64,
    k: f64,
    base_ms: f64,
    floor_ms: f64,
    ceil_ms: f64,
) -> f64 {
    step_ms(
        jitter_seconds,
        prev_playout_ms,
        shrink_step_ms,
        PlayoutConfig::from_millis(k, base_ms, floor_ms, ceil_ms),
    )
}

/// Whether a connected stream has frozen: one of the four `SLOPDESK_STREAM_*` verdicts.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_stream_stall_verdict(inputs: SlopDeskLiveness) -> u32 {
    let answer = verdict(
        Liveness {
            now: inputs.now,
            last_frame_at: inputs.has_frame.then_some(inputs.last_frame_at),
            last_heartbeat_at: inputs.has_heartbeat.then_some(inputs.last_heartbeat_at),
            connected: inputs.connected,
            idle_skip_active: inputs.idle_skip_active,
        },
        inputs.threshold,
    );
    match answer {
        StreamVerdict::Live => SLOPDESK_STREAM_LIVE,
        StreamVerdict::Stalled => SLOPDESK_STREAM_STALLED,
        StreamVerdict::NotConnected => SLOPDESK_STREAM_NOT_CONNECTED,
        StreamVerdict::Unknown => SLOPDESK_STREAM_UNKNOWN,
    }
}

/// The area of intersection between two rects, zero when they are disjoint.
///
/// The multi-monitor screen pick reads this, and it is one of the numbers the golden corpus pins:
/// the crate's NaN-ignoring maxima are what make a degenerate rect land on a finite answer instead
/// of poisoning the pick.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_geometry_intersection_area(
    first: SlopDeskVideoRect,
    second: SlopDeskVideoRect,
) -> f64 {
    first.of().intersection_area(&second.of())
}

/// The rect the displayed video occupies inside a `view` layer, preserving the native aspect.
///
/// Contain in fit, cover in fill; any non-positive dimension falls back to the full view rect.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_geometry_displayed_video_rect(
    view: SlopDeskVideoSize,
    video_native: SlopDeskVideoSize,
    mode: u32,
) -> SlopDeskVideoRect {
    SlopDeskVideoRect::from(displayed_video_rect(
        view.of(),
        video_native.of(),
        content_mode(mode),
    ))
}

/// Where a host-window-space point is drawn in the layer's view space.
///
/// The exact inverse of the input encoder's `normalize`, so the cursor overlay lands where the
/// click does. Pinned bit-exactly: the multiplies stay separate and the pan clamp is NaN-ignoring.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_geometry_view_point(
    host_point: SlopDeskVideoPoint,
    view: SlopDeskVideoSize,
    video_native: SlopDeskVideoSize,
    zoom: f64,
    pan: SlopDeskVideoPoint,
    mode: u32,
) -> SlopDeskVideoPoint {
    let answer = view_point(
        VideoPoint::new(host_point.x, host_point.y),
        view.of(),
        video_native.of(),
        zoom,
        VideoPoint::new(pan.x, pan.y),
        content_mode(mode),
    );
    SlopDeskVideoPoint {
        x: answer.x,
        y: answer.y,
    }
}

/// Arranges a `windowList` reply, answering the caller's own indices in reply order.
///
/// The windows themselves never cross: the arrangement reads two facts about each — is it on
/// screen, and does it carry a title — so the caller lends those two arrays and maps the answer
/// back onto records it already holds. On-screen first, each side keeping its original relative
/// order, and UNTITLED OFF-screen entries dropped: phantom enumeration junk carries no title, while
/// a real minimized window keeps its.
///
/// # Safety
/// Both flag arrays must hold `count` live entries for the call, and `order` must be null or
/// writable for `cap` indices.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_arrange_streamable_windows(
    on_screen: *const bool,
    titled: *const bool,
    count: usize,
    order: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation on the two flag arrays.
    let (visible, named) = unsafe { (records_of(on_screen, count), records_of(titled, count)) };
    if visible.len() != count || named.len() != count {
        return 0;
    }
    let windows: Vec<(u32, bool, &'static str)> = (0..count)
        .map(|index| {
            let seen = visible.get(index).copied().unwrap_or(false);
            let has_title = named.get(index).copied().unwrap_or(false);
            (
                u32::try_from(index).unwrap_or(u32::MAX),
                seen,
                if has_title { "t" } else { "" },
            )
        })
        .collect();
    let arranged = arrange_streamable_windows(windows, |window| window.1, |window| window.2);
    let indices: Vec<u32> = arranged.iter().map(|window| window.0).collect();
    if indices.is_empty() || indices.len() > cap || order.is_null() {
        return indices.len();
    }
    // SAFETY: the buffer is non-null and holds at least `indices.len()` entries, by the check above
    // and the caller's obligation that it is writable for `cap`.
    unsafe { std::ptr::copy_nonoverlapping(indices.as_ptr(), order, indices.len()) };
    indices.len()
}

/// Whether a virtual-display re-create attempt may start now.
///
/// An in-flight attempt always blocks; otherwise the first attempt is free and later ones must be a
/// cooldown past the previous attempt's START, because a hung create must not re-arm early. The
/// LOCK that serialises concurrent mint lanes stays with the caller — a lock is not a rule.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_vd_recreate_should_attempt(
    now: f64,
    last_attempt: f64,
    has_last_attempt: bool,
    cooldown: f64,
    attempt_in_flight: bool,
) -> bool {
    should_attempt_recreate(
        now,
        if has_last_attempt {
            Some(last_attempt)
        } else {
            None
        },
        cooldown,
        attempt_in_flight,
    )
}

/// The default seconds between virtual-display re-create attempts.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_vd_recreate_cooldown() -> f64 {
    RECREATE_COOLDOWN_SECONDS
}

/// The channel ids to disconnect when the virtual display is terminated under them, sorted.
///
/// Answers the count either way, so a caller that lent too little learns what to lend.
///
/// # Safety
/// `parked` and `live` must each be null, or describe their stated number of live entries for the
/// call; `out` must be null, or writable for `cap` `uint32_t`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_vd_channels_to_disconnect(
    parked: *const u32,
    parked_count: usize,
    live: *const u32,
    live_count: usize,
    out: *mut u32,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations above are this function's, restated on `records_of`.
    let (parked, live) = unsafe { (records_of(parked, parked_count), records_of(live, live_count)) };
    let doomed = channels_to_disconnect(&parked.iter().copied().collect(), &live.iter().copied().collect());
    let count = doomed.len();
    if count > cap || out.is_null() {
        return count;
    }
    for (index, channel) in doomed.iter().enumerate() {
        // SAFETY: `count <= cap` was just checked and `out` is writable for `cap` entries by the
        // caller's obligation.
        unsafe { out.add(index).write(*channel) };
    }
    count
}

#[cfg(test)]
#[expect(
    clippy::float_cmp,
    reason = "these are pinned bit patterns and exact arithmetic, so exact equality is the assertion"
)]
mod tests {
    use super::{
        SLOPDESK_STREAM_LIVE, SLOPDESK_STREAM_NOT_CONNECTED, SLOPDESK_STREAM_STALLED,
        SLOPDESK_STREAM_UNKNOWN, SlopDeskLiveness, slopdesk_coord_window_point, slopdesk_playout_step_ms,
        slopdesk_stream_stall_verdict, slopdesk_ycbcr_coefficients,
    };

    #[test]
    fn only_the_luma_pair_changes_with_the_range() {
        let video = slopdesk_ycbcr_coefficients(false);
        let full = slopdesk_ycbcr_coefficients(true);
        assert_eq!(full.luma_scale, 1.0);
        assert_eq!(full.luma_bias, 0.0);
        assert_eq!(video.luma_scale, 255.0 / 219.0);
        assert_eq!(video.chroma_bias, full.chroma_bias);
        assert_eq!(video.cr_to_r, full.cr_to_r);
        assert_eq!(video.cb_to_b, full.cb_to_b);
    }

    #[test]
    fn the_click_lands_where_the_window_is_and_is_not_flipped() {
        let centre = slopdesk_coord_window_point(0.5, 0.25, 100.0, 200.0, 800.0, 600.0);
        assert_eq!(centre.x, 500.0);
        assert_eq!(centre.y, 350.0);
        // The top-left corner is the ORIGIN, in both axes: no Y flip lives on this path.
        let corner = slopdesk_coord_window_point(0.0, 0.0, -50.0, 0.0, 1024.0, 768.0);
        assert_eq!(corner.x, -50.0);
        assert_eq!(corner.y, 0.0);
    }

    #[test]
    fn the_playout_grows_at_once_and_shrinks_by_a_step() {
        // A jitter spike from a cold start: the target is taken immediately.
        let grown = slopdesk_playout_step_ms(0.020, 4.0, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!(grown > 4.0, "a real jitter measurement must widen the buffer");
        // The same buffer with the jitter gone comes down by at most the shrink step.
        let shrunk = slopdesk_playout_step_ms(0.0, grown, 2.0, 0.8, 4.0, 4.0, 35.0);
        assert!(shrunk >= grown - 2.0 - f64::EPSILON, "shrink is capped per call");
        assert!(shrunk < grown, "and it does shrink");
    }

    #[test]
    fn the_stall_verdict_reads_the_presence_flags_and_not_a_sentinel() {
        let base = SlopDeskLiveness {
            now: 100.0,
            last_frame_at: 99.5,
            last_heartbeat_at: 0.0,
            threshold: 3.0,
            has_frame: true,
            has_heartbeat: false,
            connected: true,
            idle_skip_active: false,
        };
        assert_eq!(slopdesk_stream_stall_verdict(base), SLOPDESK_STREAM_LIVE);
        assert_eq!(
            slopdesk_stream_stall_verdict(SlopDeskLiveness {
                last_frame_at: 90.0,
                ..base
            }),
            SLOPDESK_STREAM_STALLED
        );
        assert_eq!(
            slopdesk_stream_stall_verdict(SlopDeskLiveness {
                connected: false,
                ..base
            }),
            SLOPDESK_STREAM_NOT_CONNECTED
        );
        // A zero heartbeat stamp that is not FLAGGED present must not read as a 100-second gap.
        assert_eq!(
            slopdesk_stream_stall_verdict(SlopDeskLiveness {
                has_frame: false,
                idle_skip_active: true,
                ..base
            }),
            SLOPDESK_STREAM_UNKNOWN
        );
    }
}
