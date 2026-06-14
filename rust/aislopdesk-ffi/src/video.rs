//! Video-path C ABI: the scalar realtime policies and small-buffer codecs from
//! `aislopdesk_core`'s video modules.
//!
//! Same memory / error contract as the crate root (see `lib.rs`): scalars cross by value;
//! any [`crate::AisdBytes`] returned owns a Rust allocation freed with [`crate::aisd_bytes_free`];
//! borrowed input buffers (`cap == 0`) are copied, never freed. The pure scalar functions here
//! take no pointers and cannot fail.

use crate::{
    bytes_from_vec, AisdBytes, AisdStatus, AISD_EMPTY, AISD_ERR_MALFORMED, AISD_ERR_NULL,
    AISD_ERR_TRUNCATED, AISD_OK,
};
use aislopdesk_core::adaptive_fec;
use aislopdesk_core::coordinate_mapping::{self, ScreenInfo};
use aislopdesk_core::cursor::CursorUpdate;
use aislopdesk_core::error::VideoProtocolError;
use aislopdesk_core::geometry::{VideoPoint, VideoRect};
use aislopdesk_core::live_bitrate_policy;
use aislopdesk_core::recovery_policy::RecoveryPolicy;

/// Maps a core video decode error to its boundary status code (shared by the video codecs).
pub(crate) const fn status_for_video_error(error: &VideoProtocolError) -> AisdStatus {
    match error {
        VideoProtocolError::Truncated => AISD_ERR_TRUNCATED,
        VideoProtocolError::Malformed(_) => AISD_ERR_MALFORMED,
    }
}

/// Borrows a `(ptr, len)` pair as a slice (empty for `len == 0`, even if `ptr` is null).
///
/// # Safety
/// If `len != 0`, `data` must point to at least `len` readable bytes.
pub(crate) const unsafe fn slice_in<'a>(data: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        core::slice::from_raw_parts(data, len)
    }
}

// ---------------------------------------------------------------------------------------
// live_bitrate_policy — pure, scalar (called ~per resolution change, never per frame)
// ---------------------------------------------------------------------------------------

/// Resolution-aware target bitrate (bits/sec) for an encoder of `pixel_width × pixel_height`
/// at `fps`, never below `floor` or the minimum. Wraps
/// [`live_bitrate_policy::target_bitrate`].
///
/// The caller resolves the `bits_per_pixel` density (e.g. from `AISLOPDESK_BPP`) and passes it
/// in, so the core stays environment-free and the result is deterministic.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_live_bitrate_target(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel: f64,
) -> i64 {
    live_bitrate_policy::target_bitrate(pixel_width, pixel_height, fps, floor, bits_per_pixel)
}

/// The absolute minimum live bitrate (bits/sec) — a tiny window never starves the encoder.
/// Wraps [`live_bitrate_policy::MINIMUM_BITRATE`].
#[must_use]
#[no_mangle]
pub const extern "C" fn aisd_live_bitrate_minimum() -> i64 {
    live_bitrate_policy::MINIMUM_BITRATE
}

// ---------------------------------------------------------------------------------------
// cursor — the fixed 36-byte hot cursor update (≈120 Hz, small => Rust faster than Data)
// ---------------------------------------------------------------------------------------

/// A decoded cursor update, flattened for the C ABI (the hot 36-byte message; no owned
/// buffer). Field order must match the C header's `AisdCursorUpdate`.
#[repr(C)]
pub struct AisdCursorUpdate {
    /// Cursor shape id (client caches the bitmap by this id).
    pub shape_id: u16,
    /// Visibility (`0` = hidden, nonzero = visible; read as `!= 0`).
    pub visible: u8,
    /// Host-window-space x (points).
    pub x: f64,
    /// Host-window-space y (points).
    pub y: f64,
    /// Hotspot x offset (points).
    pub hotspot_x: f64,
    /// Hotspot y offset (points).
    pub hotspot_y: f64,
}

/// Encodes a cursor update into its fixed 36-byte wire form.
///
/// On [`AISD_OK`], `*out` owns the
/// buffer — release with [`crate::aisd_bytes_free`]. Wraps [`CursorUpdate::encode`]; cannot
/// fail except for a null `out`.
///
/// # Safety
/// `out` must be a writable [`AisdBytes`] pointer.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_cursor_update_encode(
    shape_id: u16,
    visible: u8,
    x: f64,
    y: f64,
    hotspot_x: f64,
    hotspot_y: f64,
    out: *mut AisdBytes,
) -> AisdStatus {
    if out.is_null() {
        return AISD_ERR_NULL;
    }
    let update = CursorUpdate {
        position: VideoPoint::new(x, y),
        shape_id,
        hotspot: VideoPoint::new(hotspot_x, hotspot_y),
        visible: visible != 0,
    };
    out.write(bytes_from_vec(update.encode()));
    AISD_OK
}

/// Decodes a cursor update into `*out`.
///
/// Wraps [`CursorUpdate::decode`]: rejects a wrong type
/// byte or non-finite coordinate ([`AISD_ERR_MALFORMED`]) and a short body
/// ([`AISD_ERR_TRUNCATED`]). `data` may be null only when `len == 0`.
///
/// # Safety
/// `out` must be writable; if `len != 0`, `data` must point to `len` readable bytes.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_cursor_update_decode(
    data: *const u8,
    len: usize,
    out: *mut AisdCursorUpdate,
) -> AisdStatus {
    if out.is_null() || (data.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    match CursorUpdate::decode(slice_in(data, len)) {
        Ok(c) => {
            out.write(AisdCursorUpdate {
                shape_id: c.shape_id,
                visible: u8::from(c.visible),
                x: c.position.x,
                y: c.position.y,
                hotspot_x: c.hotspot.x,
                hotspot_y: c.hotspot.y,
            });
            AISD_OK
        }
        Err(e) => status_for_video_error(&e),
    }
}

// ---------------------------------------------------------------------------------------
// adaptive_fec — pure, scalar (tier/next_tier_state ~per netstats report; group_size on the
// reassemble/packetize path; FFI overhead negligible vs decode/encode)
// ---------------------------------------------------------------------------------------

/// Tier-decision state for the dwell-gated adaptive-FEC variant, flattened for the C ABI.
///
/// Mirrors [`adaptive_fec::TierState`] field-for-field (`#[repr(C)]`, same field order). Crosses
/// by value in both directions.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AisdTierState {
    /// Current wire tier (0..=7 on the wire; any `u8` is total).
    pub tier: u8,
    /// Consecutive reports that demanded relaxation.
    pub relax_streak: i32,
    /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive.
    pub sticky_relax_remaining: i32,
}

impl From<adaptive_fec::TierState> for AisdTierState {
    fn from(s: adaptive_fec::TierState) -> Self {
        Self {
            tier: s.tier,
            relax_streak: s.relax_streak,
            sticky_relax_remaining: s.sticky_relax_remaining,
        }
    }
}

impl From<AisdTierState> for adaptive_fec::TierState {
    fn from(s: AisdTierState) -> Self {
        Self::new(s.tier, s.relax_streak, s.sticky_relax_remaining)
    }
}

/// Maps a wire tier to the FEC group size both ends must use.
///
/// Wraps
/// [`adaptive_fec::group_size`]. Returns `1` and writes the group size to `*out` for a parity
/// tier; returns `0` for the OFF (no-parity) tier (leaving `*out` untouched — treat as nil).
/// TOTAL over every `tier` (unknown → `default_group_size`, never traps). A null `out` returns
/// `0` without writing.
///
/// # Safety
/// `out`, if non-null, must be a writable `usize` pointer.
#[must_use]
#[no_mangle]
pub const unsafe extern "C" fn aisd_adaptive_fec_group_size(
    tier: u8,
    default_group_size: usize,
    out: *mut usize,
) -> u8 {
    match adaptive_fec::group_size(tier, default_group_size) {
        // Return `1` only when a size was actually written, so the return is a clean
        // postcondition (`1` ⟺ `*out` holds a valid group size). A null `out` (caller error)
        // yields `0` like the OFF tier — nothing written, no UB.
        Some(g) if !out.is_null() => {
            out.write(g);
            1
        }
        _ => 0,
    }
}

/// Picks the next wire tier from the EWMA `loss` and the `previous_tier` (the plain decider;
/// the production host uses [`aisd_adaptive_fec_next_tier_state`]).
///
/// Wraps [`adaptive_fec::tier`].
/// `allow_off` is the OFF-tier escape hatch resolved by the caller from `AISLOPDESK_FEC_ALLOW_OFF`
/// (read `!= 0`), keeping the core environment-free.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_fec_tier(loss: f64, previous_tier: u8, allow_off: u8) -> u8 {
    adaptive_fec::tier(loss, previous_tier, allow_off != 0)
}

/// Dwell-gated tier step — the production entry point.
///
/// Wraps [`adaptive_fec::next_tier_state`]:
/// escalation is immediate (one step, resets the relax streak); relaxation is counted across
/// consecutive relax-demanding reports and applied at the effective dwell (doubled while a
/// sticky window from a recent unrecovered loss is open). Returns the next state by value.
/// `allow_off` / `saw_unrecovered_loss` are bytes read `!= 0`; the caller resolves `allow_off`
/// from the environment and passes `dwell`, keeping the core environment-free.
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_adaptive_fec_next_tier_state(
    loss: f64,
    state: AisdTierState,
    dwell: i32,
    allow_off: u8,
    saw_unrecovered_loss: u8,
) -> AisdTierState {
    adaptive_fec::next_tier_state(
        loss,
        state.into(),
        dwell,
        allow_off != 0,
        saw_unrecovered_loss != 0,
    )
    .into()
}

// ---------------------------------------------------------------------------------------
// coordinate_mapping — pure, scalar (per pointer event; FFI cost dwarfed by the CGEvent
// post it precedes, so it swaps unconditionally — no per-frame buffers)
// ---------------------------------------------------------------------------------------

/// A 2-D point in host points, flattened for the C ABI (field-for-field [`VideoPoint`]).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdPoint {
    /// Horizontal coordinate.
    pub x: f64,
    /// Vertical coordinate.
    pub y: f64,
}

impl AisdPoint {
    const fn to_core(self) -> VideoPoint {
        VideoPoint::new(self.x, self.y)
    }
    const fn from_core(p: VideoPoint) -> Self {
        Self { x: p.x, y: p.y }
    }
}

/// A rectangle (origin + size), flattened for the C ABI (`x, y, width, height`).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdRect {
    /// Origin x.
    pub x: f64,
    /// Origin y.
    pub y: f64,
    /// Extent width.
    pub width: f64,
    /// Extent height.
    pub height: f64,
}

impl AisdRect {
    const fn to_core(self) -> VideoRect {
        VideoRect::xywh(self.x, self.y, self.width, self.height)
    }
    const fn from_core(r: VideoRect) -> Self {
        Self {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        }
    }
}

/// A display (Cocoa-bottom-left frame + Retina backing scale), flattened for the C ABI.
/// Passed in as a borrowed array, never freed by Rust.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdScreenInfo {
    /// The screen's frame in Cocoa bottom-left space (`NSScreen.frame`).
    pub cocoa_frame: AisdRect,
    /// `NSScreen.backingScaleFactor` (1.0 standard, 2.0 Retina).
    pub backing_scale_factor: f64,
}

impl AisdScreenInfo {
    const fn to_core(self) -> ScreenInfo {
        ScreenInfo::new(self.cocoa_frame.to_core(), self.backing_scale_factor)
    }
}

/// Maps a normalised (0..1) window point to a host-window point in CG top-left space (no Y
/// flip, no scale). Wraps [`coordinate_mapping::window_point`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_coord_window_point(
    normalized: AisdPoint,
    window_bounds: AisdRect,
) -> AisdPoint {
    AisdPoint::from_core(coordinate_mapping::window_point(
        normalized.to_core(),
        window_bounds.to_core(),
    ))
}

/// Flips a CG-top-left rect into Cocoa bottom-left space given the primary display height.
/// Wraps [`coordinate_mapping::cg_rect_to_cocoa`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_coord_cg_rect_to_cocoa(cg_rect: AisdRect, primary_height: f64) -> AisdRect {
    AisdRect::from_core(coordinate_mapping::cg_rect_to_cocoa(
        cg_rect.to_core(),
        primary_height,
    ))
}

/// Picks the screen a window lives on (largest overlap) and writes its `backing_scale_factor`
/// to `*out_scale`.
///
/// Wraps [`coordinate_mapping::backing_scale_factor`]. Returns [`AISD_OK`]
/// (overlap; `*out_scale` written), [`AISD_EMPTY`] (no overlap; `*out_scale` untouched), or
/// [`AISD_ERR_NULL`] if `out_scale` is null, or `screens` is null while `screen_count != 0`.
/// `screens` is borrowed for the call only.
///
/// # Safety
/// `out_scale` must be a writable `f64`; if `screen_count != 0`, `screens` must point to at
/// least `screen_count` readable [`AisdScreenInfo`] values.
#[must_use]
#[no_mangle]
pub unsafe extern "C" fn aisd_coord_backing_scale_factor(
    window_bounds_cg: AisdRect,
    screens: *const AisdScreenInfo,
    screen_count: usize,
    primary_height: f64,
    out_scale: *mut f64,
) -> AisdStatus {
    if out_scale.is_null() || (screens.is_null() && screen_count != 0) {
        return AISD_ERR_NULL;
    }
    let core_screens: Vec<ScreenInfo> = if screen_count == 0 {
        Vec::new()
    } else {
        core::slice::from_raw_parts(screens, screen_count)
            .iter()
            .map(|s| s.to_core())
            .collect()
    };
    coordinate_mapping::backing_scale_factor(
        window_bounds_cg.to_core(),
        &core_screens,
        primary_height,
    )
    .map_or(AISD_EMPTY, |scale| {
        out_scale.write(scale);
        AISD_OK
    })
}

/// Pixel path: divide by `backing_scale_factor` to get points, then add the window origin.
/// Wraps [`coordinate_mapping::window_point_from_pixel`].
#[must_use]
#[no_mangle]
pub extern "C" fn aisd_coord_window_point_from_pixel(
    pixel: AisdPoint,
    window_bounds_cg: AisdRect,
    backing_scale_factor: f64,
) -> AisdPoint {
    AisdPoint::from_core(coordinate_mapping::window_point_from_pixel(
        pixel.to_core(),
        window_bounds_cg.to_core(),
        backing_scale_factor,
    ))
}

// ---------------------------------------------------------------------------------------
// recovery_policy — pure, scalar (per gated frame on the client recovery clock)
// ---------------------------------------------------------------------------------------

/// Whether the client should escalate a stalled LTR-refresh recovery to a forced IDR,
///
/// given
/// the configured policy multiples, time since the first request, the RTT estimate, and
/// whether it is observing loss.
///
/// Wraps [`RecoveryPolicy::should_escalate_to_idr`].
///
/// `observing_loss` crosses as a byte read `!= 0`. The lossy escalation floor (`lossy_floor_s`,
/// from `AISLOPDESK_ESCALATION_FLOOR_MS`) is resolved by the caller and passed in, keeping the
/// core environment-free. Returns `1` to escalate, `0` otherwise. The four multiples map
/// field-for-field onto [`RecoveryPolicy`].
#[must_use]
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn aisd_recovery_policy_should_escalate_to_idr(
    idr_rtt_mult: f64,
    lossy_idr_rtt_mult: f64,
    lossy_floor_s: f64,
    lossy_floor_rtt_mult: f64,
    elapsed_since_request: f64,
    rtt: f64,
    observing_loss: u8,
) -> u8 {
    let policy = RecoveryPolicy::new(
        idr_rtt_mult,
        lossy_idr_rtt_mult,
        lossy_floor_s,
        lossy_floor_rtt_mult,
    );
    u8::from(policy.should_escalate_to_idr(elapsed_since_request, rtt, observing_loss != 0))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    const BPP: f64 = live_bitrate_policy::DEFAULT_BITS_PER_PIXEL_PER_FRAME;

    #[test]
    fn live_bitrate_target_matches_core() {
        assert_eq!(
            aisd_live_bitrate_target(1920, 1080, 60, 12_000_000, BPP),
            18_662_400
        );
        assert_eq!(
            aisd_live_bitrate_target(2816, 1778, 60, 12_000_000, BPP),
            45_061_632
        );
        assert_eq!(
            aisd_live_bitrate_target(320, 240, 60, 12_000_000, BPP),
            12_000_000
        );
        assert_eq!(
            aisd_live_bitrate_target(64, 64, 60, 0, BPP),
            aisd_live_bitrate_minimum()
        );
        assert_eq!(
            aisd_live_bitrate_target(0, -10, 0, 0, BPP),
            aisd_live_bitrate_minimum()
        );
    }

    #[test]
    fn live_bitrate_minimum_is_one_megabit() {
        assert_eq!(aisd_live_bitrate_minimum(), 1_000_000);
    }

    fn zeroed_cursor() -> AisdCursorUpdate {
        AisdCursorUpdate {
            shape_id: 0,
            visible: 0,
            x: 0.0,
            y: 0.0,
            hotspot_x: 0.0,
            hotspot_y: 0.0,
        }
    }

    #[test]
    fn cursor_update_round_trips() {
        unsafe {
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(
                aisd_cursor_update_encode(42, 1, 1920.0, 1080.0, 8.0, 8.0, &mut frame),
                AISD_OK
            );
            assert_eq!(frame.len, 36);
            let mut out = zeroed_cursor();
            assert_eq!(
                aisd_cursor_update_decode(frame.ptr, frame.len, &mut out),
                AISD_OK
            );
            assert_eq!(out.shape_id, 42);
            assert_eq!(out.visible, 1);
            assert_eq!(
                (out.x, out.y, out.hotspot_x, out.hotspot_y),
                (1920.0, 1080.0, 8.0, 8.0)
            );
            crate::aisd_bytes_free(frame);
        }
    }

    #[test]
    fn cursor_update_rejects_nan_wrong_type_and_short() {
        unsafe {
            let mut frame = AisdBytes::EMPTY;
            assert_eq!(
                aisd_cursor_update_encode(1, 1, f64::NAN, 0.0, 0.0, 0.0, &mut frame),
                AISD_OK
            );
            let mut out = zeroed_cursor();
            assert_eq!(
                aisd_cursor_update_decode(frame.ptr, frame.len, &mut out),
                AISD_ERR_MALFORMED
            );
            crate::aisd_bytes_free(frame);

            let bad = [99u8; 36]; // wrong type byte
            assert_eq!(
                aisd_cursor_update_decode(bad.as_ptr(), bad.len(), &mut out),
                AISD_ERR_MALFORMED
            );
            assert_eq!(
                aisd_cursor_update_decode([1u8].as_ptr(), 1, &mut out),
                AISD_ERR_TRUNCATED
            );
        }
    }

    #[test]
    fn adaptive_fec_group_size_matches_core() {
        let mut out: usize = 0;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(0, 5, &mut out) }, 1);
        assert_eq!(out, 5);
        out = 999;
        assert_eq!(unsafe { aisd_adaptive_fec_group_size(1, 5, &mut out) }, 0);
        assert_eq!(out, 999, "OFF must not write *out");
        for (tier, def, want) in [
            (2u8, 5usize, 10usize),
            (3, 5, 3),
            (4, 5, 2),
            (5, 5, 5),
            (200, 7, 7),
        ] {
            out = 0;
            assert_eq!(
                unsafe { aisd_adaptive_fec_group_size(tier, def, &mut out) },
                1
            );
            assert_eq!(out, want, "tier {tier} default {def}");
        }
        assert_eq!(
            unsafe { aisd_adaptive_fec_group_size(0, 5, core::ptr::null_mut()) },
            0
        );
    }

    #[test]
    fn adaptive_fec_tier_matches_core() {
        assert_eq!(
            aisd_adaptive_fec_tier(0.10, 0, 0),
            adaptive_fec::tier(0.10, 0, false)
        );
        assert_eq!(aisd_adaptive_fec_tier(0.10, 0, 0), 3);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 0), 2);
        assert_eq!(aisd_adaptive_fec_tier(0.0, 2, 1), 1);
        assert_eq!(
            aisd_adaptive_fec_tier(0.0, 2, 2),
            1,
            "any nonzero allow_off is true"
        );
        assert_eq!(aisd_adaptive_fec_tier(0.015, 0, 0), 0);
    }

    #[test]
    fn adaptive_fec_next_tier_state_matches_core() {
        let dwell = adaptive_fec::RELAX_DWELL_REPORTS;
        let armed = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 0,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            1,
        );
        assert_eq!(
            armed.sticky_relax_remaining,
            adaptive_fec::STICKY_RELAX_WINDOW_REPORTS
        );
        let esc = aisd_adaptive_fec_next_tier_state(
            0.10,
            AisdTierState {
                tier: 0,
                relax_streak: 10,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!((esc.tier, esc.relax_streak), (3, 0));
        let core_next = adaptive_fec::next_tier_state(
            0.0,
            adaptive_fec::TierState::new(0, 5, 0),
            dwell,
            false,
            false,
        );
        let ffi_next = aisd_adaptive_fec_next_tier_state(
            0.0,
            AisdTierState {
                tier: 0,
                relax_streak: 5,
                sticky_relax_remaining: 0,
            },
            dwell,
            0,
            0,
        );
        assert_eq!(adaptive_fec::TierState::from(ffi_next), core_next);
    }

    #[test]
    fn adaptive_fec_tier_state_repr_round_trips() {
        let s = adaptive_fec::TierState::new(3, 7, 11);
        assert_eq!(adaptive_fec::TierState::from(AisdTierState::from(s)), s);
    }

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn coord_window_point_matches_core() {
        let p = aisd_coord_window_point(
            AisdPoint { x: 0.5, y: 0.5 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
        );
        approx(p.x, 500.0);
        approx(p.y, 500.0);
        let c = aisd_coord_window_point(
            AisdPoint { x: 1.0, y: 1.0 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
        );
        approx(c.x, 900.0);
        approx(c.y, 800.0);
    }

    #[test]
    fn coord_cg_to_cocoa_flip_matches_core() {
        let r = aisd_coord_cg_rect_to_cocoa(
            AisdRect {
                x: 0.0,
                y: 0.0,
                width: 400.0,
                height: 200.0,
            },
            1080.0,
        );
        approx(r.x, 0.0);
        approx(r.y, 880.0);
        approx(r.width, 400.0);
        approx(r.height, 200.0);
    }

    #[test]
    fn coord_backing_scale_picks_retina_after_flip() {
        let screens = [
            AisdScreenInfo {
                cocoa_frame: AisdRect {
                    x: 0.0,
                    y: 0.0,
                    width: 1920.0,
                    height: 1080.0,
                },
                backing_scale_factor: 1.0,
            },
            AisdScreenInfo {
                cocoa_frame: AisdRect {
                    x: 0.0,
                    y: 1080.0,
                    width: 2560.0,
                    height: 1440.0,
                },
                backing_scale_factor: 2.0,
            },
        ];
        let win = AisdRect {
            x: 100.0,
            y: -1000.0,
            width: 1280.0,
            height: 800.0,
        };
        let mut scale = 0.0_f64;
        let status = unsafe {
            aisd_coord_backing_scale_factor(
                win,
                screens.as_ptr(),
                screens.len(),
                1080.0,
                &mut scale,
            )
        };
        assert_eq!(status, AISD_OK);
        approx(scale, 2.0);
    }

    #[test]
    fn coord_backing_scale_no_overlap_and_null() {
        let screens = [AisdScreenInfo {
            cocoa_frame: AisdRect {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            backing_scale_factor: 1.0,
        }];
        let win = AisdRect {
            x: 10_000.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        };
        let mut scale = -1.0_f64;
        let status = unsafe {
            aisd_coord_backing_scale_factor(
                win,
                screens.as_ptr(),
                screens.len(),
                1080.0,
                &mut scale,
            )
        };
        assert_eq!(status, AISD_EMPTY);
        approx(scale, -1.0); // untouched on AISD_EMPTY
                             // null out_scale => AISD_ERR_NULL; null screens + count 0 => empty => AISD_EMPTY.
        assert_eq!(
            unsafe {
                aisd_coord_backing_scale_factor(
                    win,
                    core::ptr::null(),
                    0,
                    100.0,
                    core::ptr::null_mut(),
                )
            },
            AISD_ERR_NULL
        );
        assert_eq!(
            unsafe {
                aisd_coord_backing_scale_factor(win, core::ptr::null(), 0, 100.0, &mut scale)
            },
            AISD_EMPTY
        );
    }

    #[test]
    fn coord_pixel_path_divides_by_scale_once() {
        let p = aisd_coord_window_point_from_pixel(
            AisdPoint { x: 400.0, y: 300.0 },
            AisdRect {
                x: 100.0,
                y: 200.0,
                width: 800.0,
                height: 600.0,
            },
            2.0,
        );
        approx(p.x, 300.0);
        approx(p.y, 350.0);
    }

    // recovery_policy: defaults 2.0 normal, 1.0 lossy, 60 ms floor, 1.5 floor-rtt-multiple.
    fn escalate(elapsed: f64, rtt: f64, observing: u8) -> u8 {
        aisd_recovery_policy_should_escalate_to_idr(2.0, 1.0, 0.06, 1.5, elapsed, rtt, observing)
    }

    #[test]
    fn recovery_normal_path_is_two_rtt_no_floor() {
        assert_eq!(escalate(0.19, 0.1, 0), 0);
        assert_eq!(escalate(0.20, 0.1, 0), 1);
        assert_eq!(escalate(0.011, 0.006, 0), 0);
        assert_eq!(escalate(0.012, 0.006, 0), 1);
    }

    #[test]
    fn recovery_lossy_path_floored_and_byte_read() {
        assert_eq!(escalate(0.059, 0.01, 1), 0);
        assert_eq!(escalate(0.060, 0.01, 1), 1);
        assert_eq!(escalate(0.0749, 0.05, 1), 0);
        assert_eq!(escalate(0.0751, 0.05, 1), 1);
        assert_eq!(escalate(0.0751, 0.05, 0), 0); // normal clock still waits 2·RTT
        assert_eq!(escalate(0.030, 0.01, 2), 0); // any nonzero byte = observing loss
        assert_eq!(escalate(0.060, 0.01, 2), 1);
        assert_eq!(escalate(0.060, 0.01, 1), escalate(0.060, 0.01, 2));
    }

    #[test]
    fn recovery_matches_core_over_a_grid() {
        for &observing in &[0u8, 1u8] {
            let mut elapsed = 0.0;
            while elapsed <= 0.3 {
                for &rtt in &[0.005, 0.01, 0.05, 0.1, 0.25] {
                    let policy = RecoveryPolicy::new(2.0, 1.0, 0.06, 1.5);
                    let want =
                        u8::from(policy.should_escalate_to_idr(elapsed, rtt, observing != 0));
                    assert_eq!(escalate(elapsed, rtt, observing), want);
                }
                elapsed += 0.007;
            }
        }
    }
}
