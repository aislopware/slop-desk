//! The host's four smallest send-path decisions: suppress, re-sharpen, budget, degrade.
//!
//! Whether a captured frame that changed nothing may be dropped; whether the picture has
//! demonstrably settled and the crisp re-anchor should fire early; how many bits a window of this
//! size at this frame rate is worth; and which rung a failed capture rebuild falls to. Four rules
//! with almost no arithmetic between them — which is exactly the shape that gets re-typed at the
//! call site rather than called, and then drifts one flag at a time.
//!
//! ## Why they cross by value
//! Nothing here is big. The suppression rule and the recovery ladder hold nothing at all; the
//! bitrate is three integers and a density; the stillness decider is a count and a latch. The far
//! side reads every field of every one of them, so a handle would buy an allocation and a free per
//! frame in return for nothing — §4b's test, applied to the smallest things in the repo.
//!
//! The stillness decider therefore crosses as a FOLD: the caller hands back the two numbers it was
//! last given, and gets the two numbers the rule says come next. The rule stays here; the storage
//! stays with the actor that owns the capture path.

use std::ffi::c_uchar;

use slopdesk_video::capture_recovery::{CaptureFailureAction, capture_failure_action};
use slopdesk_video::frame_gate::{FrameObligations, StillnessCrispDecider, should_suppress_static_frame};
use slopdesk_video::live_bitrate::{
    DEFAULT_BITS_PER_PIXEL_PER_FRAME, MINIMUM_BITRATE, bits_per_pixel_from_env, target_bitrate,
};

use crate::borrow;

/// A teardown or a newer owner raced the rebuild — do nothing.
pub const SLOPDESK_CAPTURE_ABANDON: u32 = 0;
/// Rebuild a plain window capture, dropping the region.
pub const SLOPDESK_CAPTURE_REBUILD_PLAIN_WINDOW: u32 = 1;
/// The fallback failed too — say goodbye and stop.
pub const SLOPDESK_CAPTURE_DISCONNECT: u32 = 2;

/// The forced-frame obligations, one flag each.
///
/// They stay separate rather than collapsing into a bitset for the reason the crate keeps them
/// separate: each is independent, any one of them wins, and a future obligation is one more field
/// whose default is "encode".
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskFrameObligations {
    /// The stream's first frame, which is always the keyframe the client needs to start.
    pub is_first_frame: bool,
    /// A client loss-recovery or heartbeat IDR latch is pending.
    pub forced_keyframe_pending: bool,
    /// An LTR-refresh recovery latch is pending.
    pub recovery_pending: bool,
    /// The periodic insurance IDR cadence is due.
    pub heartbeat_due: bool,
    /// A long-term-reference refresh is scheduled.
    pub ltr_refresh_due: bool,
    /// The self-heal cadence frame is due.
    pub self_heal_due: bool,
}

impl SlopDeskFrameObligations {
    /// The crate's obligations, field for field.
    const fn of(self) -> FrameObligations {
        FrameObligations {
            is_first_frame: self.is_first_frame,
            forced_keyframe_pending: self.forced_keyframe_pending,
            recovery_pending: self.recovery_pending,
            heartbeat_due: self.heartbeat_due,
            ltr_refresh_due: self.ltr_refresh_due,
            self_heal_due: self.self_heal_due,
        }
    }
}

/// The stillness decider's whole state: a count and a latch.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskStillnessCrisp {
    /// Consecutive byte-identical complete frames observed, reset to zero on any change.
    pub consecutive_equal: usize,
    /// Whether the crisp re-anchor already fired for the CURRENT rest period.
    pub fired_this_rest: bool,
}

impl SlopDeskStillnessCrisp {
    /// The crate's decider, restored from what the caller was last given.
    const fn of(self) -> StillnessCrispDecider {
        StillnessCrispDecider::restored(self.consecutive_equal, self.fired_this_rest)
    }

    /// The record a decider reports as.
    const fn from(decider: StillnessCrispDecider) -> Self {
        Self {
            consecutive_equal: decider.consecutive_equal(),
            fired_this_rest: decider.fired_this_rest(),
        }
    }
}

/// The live-bitrate floors the encoder is sized against.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskLiveBitrateDefaults {
    /// Bits per pixel per frame when the density knob says nothing usable.
    pub default_bits_per_pixel: f64,
    /// The absolute lower bound, so a tiny window never starves the encoder.
    pub minimum_bitrate: i64,
}

/// The live-bitrate floors.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_live_bitrate_defaults() -> SlopDeskLiveBitrateDefaults {
    SlopDeskLiveBitrateDefaults {
        default_bits_per_pixel: DEFAULT_BITS_PER_PIXEL_PER_FRAME,
        minimum_bitrate: MINIMUM_BITRATE,
    }
}

/// Whether a captured frame should be SUPPRESSED — skipped rather than handed to the encoder.
///
/// True only when the pixels are unchanged and NOTHING is outstanding: a duplicate frame with
/// nothing else to deliver.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_should_suppress_static_frame(
    hash_equal_to_last: bool,
    obligations: SlopDeskFrameObligations,
) -> bool {
    should_suppress_static_frame(hash_equal_to_last, obligations.of())
}

/// A stillness decider armed and at zero.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_stillness_crisp_new() -> SlopDeskStillnessCrisp {
    SlopDeskStillnessCrisp::from(StillnessCrispDecider::new())
}

/// Feeds one complete frame's hash-equality and answers the state that follows.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_stillness_crisp_on_frame(
    state: SlopDeskStillnessCrisp,
    hash_equal_to_previous: bool,
) -> SlopDeskStillnessCrisp {
    let mut decider = state.of();
    decider.on_frame(hash_equal_to_previous);
    SlopDeskStillnessCrisp::from(decider)
}

/// Whether to fire the crisp re-anchor now. Pure — the state is unchanged.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_stillness_crisp_should_fire(
    state: SlopDeskStillnessCrisp,
    rest_threshold: usize,
) -> bool {
    state.of().should_fire_crisp(rest_threshold)
}

/// Records that the re-anchor fired, and answers the state that follows.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_stillness_crisp_note_fired(
    state: SlopDeskStillnessCrisp,
) -> SlopDeskStillnessCrisp {
    let mut decider = state.of();
    decider.note_crisp_fired();
    SlopDeskStillnessCrisp::from(decider)
}

/// The density knob parsed, or the default when it says nothing usable.
///
/// An empty span is an unset knob, not an empty value — the same reading every door in this crate
/// gives a borrowed string.
///
/// # Safety
/// `raw` must be null, or point to `raw_len` initialised bytes live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_live_bitrate_bits_per_pixel(raw: *const c_uchar, raw_len: usize) -> f64 {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    let bytes = unsafe { borrow(raw, raw_len) };
    if bytes.is_empty() {
        return bits_per_pixel_from_env(None);
    }
    bits_per_pixel_from_env(std::str::from_utf8(bytes).ok())
}

/// The resolution-aware target bitrate, in bits per second.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_live_bitrate_target(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel_per_frame: f64,
) -> i64 {
    target_bitrate(pixel_width, pixel_height, fps, floor, bits_per_pixel_per_frame)
}

/// The recovery rung for one failed capture rebuild.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_capture_failure_action(
    media_flowing: bool,
    superseded: bool,
    is_fallback_rebuild: bool,
) -> u32 {
    match capture_failure_action(media_flowing, superseded, is_fallback_rebuild) {
        CaptureFailureAction::Abandon => SLOPDESK_CAPTURE_ABANDON,
        CaptureFailureAction::RebuildPlainWindow => SLOPDESK_CAPTURE_REBUILD_PLAIN_WINDOW,
        CaptureFailureAction::Disconnect => SLOPDESK_CAPTURE_DISCONNECT,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        SLOPDESK_CAPTURE_ABANDON, SLOPDESK_CAPTURE_DISCONNECT, SLOPDESK_CAPTURE_REBUILD_PLAIN_WINDOW,
        SlopDeskFrameObligations, slopdesk_capture_failure_action, slopdesk_live_bitrate_defaults,
        slopdesk_live_bitrate_target, slopdesk_should_suppress_static_frame, slopdesk_stillness_crisp_new,
        slopdesk_stillness_crisp_note_fired, slopdesk_stillness_crisp_on_frame,
        slopdesk_stillness_crisp_should_fire,
    };

    #[test]
    fn only_a_duplicate_frame_with_nothing_outstanding_is_suppressed() {
        let nothing = SlopDeskFrameObligations::default();
        assert!(slopdesk_should_suppress_static_frame(true, nothing));
        assert!(!slopdesk_should_suppress_static_frame(false, nothing));
        let pending = SlopDeskFrameObligations {
            recovery_pending: true,
            ..SlopDeskFrameObligations::default()
        };
        assert!(!slopdesk_should_suppress_static_frame(true, pending));
    }

    #[test]
    fn the_crisp_re_anchor_fires_once_per_rest_period() {
        let mut state = slopdesk_stillness_crisp_new();
        for _ in 0..3 {
            state = slopdesk_stillness_crisp_on_frame(state, true);
        }
        assert!(slopdesk_stillness_crisp_should_fire(state, 3));
        state = slopdesk_stillness_crisp_note_fired(state);
        assert!(!slopdesk_stillness_crisp_should_fire(state, 3), "once per rest");
        state = slopdesk_stillness_crisp_on_frame(state, false);
        assert_eq!(state.consecutive_equal, 0, "motion re-arms it");
        assert!(!state.fired_this_rest);
    }

    #[test]
    fn the_budget_never_falls_below_the_floor_it_was_given() {
        let defaults = slopdesk_live_bitrate_defaults();
        let tiny = slopdesk_live_bitrate_target(2, 2, 1, 0, defaults.default_bits_per_pixel);
        assert_eq!(
            tiny, defaults.minimum_bitrate,
            "a tiny window still gets the floor"
        );
        let honoured = slopdesk_live_bitrate_target(2, 2, 1, 50_000_000, defaults.default_bits_per_pixel);
        assert_eq!(honoured, 50_000_000, "an explicit higher cap wins");
    }

    #[test]
    fn the_ladder_abandons_before_it_degrades_and_degrades_before_it_disconnects() {
        assert_eq!(
            slopdesk_capture_failure_action(false, false, false),
            SLOPDESK_CAPTURE_ABANDON
        );
        assert_eq!(
            slopdesk_capture_failure_action(true, true, false),
            SLOPDESK_CAPTURE_ABANDON
        );
        assert_eq!(
            slopdesk_capture_failure_action(true, false, false),
            SLOPDESK_CAPTURE_REBUILD_PLAIN_WINDOW
        );
        assert_eq!(
            slopdesk_capture_failure_action(true, false, true),
            SLOPDESK_CAPTURE_DISCONNECT
        );
    }
}
