//! The host's two admission laws: what quantiser the encoder runs at, and whether a client's
//! recovery request may force a keyframe.
//!
//! Both are folds over injected time and injected verdicts — no socket, no clock, no encoder — so
//! both cross whole. What does NOT cross is where their knobs come from: the host resolves
//! `SLOPDESK_QP_*` and `SLOPDESK_IDR_*` through its own overlay-aware `EnvConfig`, so a GUI setting
//! can override an environment variable. The door takes the resolved TEXT, or the resolved numbers,
//! and never reads an environment of its own.
//!
//! ## Why one crosses by value and the other by handle
//!
//! The quantiser controller is a VALUE on the far side: its owner copies it out, folds a report
//! into the copy and writes it back, and equality is part of its contract. A handle would quietly
//! alias two owners that the Swift type system says are separate, so the fold crosses as
//! `(config, state, congested) -> state` with no allocation at all.
//!
//! The recovery policy is a reference on the far side — one instance per session, mutated from the
//! session actor, holding a token bucket and a keyframe ring that must not be copied by accident.
//! So it crosses as a handle, and the Swift class holds exactly one.

use core::ffi::c_uchar;

use slopdesk_video::encoder_ceiling;
use slopdesk_video::qp_control::{QpConfig, QpController, clamped_int_from_env};
use slopdesk_video::recovery_idr::{IdrVerdict, RecoveryIdrConfig, RecoveryIdrPolicy};

use crate::borrow;

/// Issue the keyframe.
pub const SLOPDESK_IDR_VERDICT_GRANT: u32 = 0;
/// A grant is already latched and unexpired — the duplicate-request absorber.
pub const SLOPDESK_IDR_VERDICT_SUPPRESS_GRANT_PENDING: u32 = 1;
/// The request provably predates a keyframe the client decoded.
pub const SLOPDESK_IDR_VERDICT_SUPPRESS_STALE: u32 = 2;
/// The newest sent keyframe is plausibly still in flight.
pub const SLOPDESK_IDR_VERDICT_SUPPRESS_IN_FLIGHT: u32 = 3;
/// The token bucket is empty — the storm cap.
pub const SLOPDESK_IDR_VERDICT_SUPPRESS_RATE_LIMITED: u32 = 4;

// ---------------------------------------------------------------------------------------------
// The quantiser law
// ---------------------------------------------------------------------------------------------

/// The quantiser bounds and step sizes, as they cross.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SlopDeskQpConfig {
    /// The sharpest — lowest — quantiser on a clean link.
    pub sharp: i32,
    /// The coarsest — highest — quantiser under sustained congestion.
    pub coarse: i32,
    /// The rise per congested report.
    pub up_step: i32,
    /// Clean reports per one-step sharpen.
    pub down_interval: i32,
}

impl SlopDeskQpConfig {
    /// The crate's config for these numbers.
    const fn inner(self) -> QpConfig {
        QpConfig {
            sharp: self.sharp,
            coarse: self.coarse,
            up_step: self.up_step,
            down_interval: self.down_interval,
        }
    }

    /// These numbers for the crate's config.
    const fn of(config: QpConfig) -> Self {
        Self {
            sharp: config.sharp,
            coarse: config.coarse,
            up_step: config.up_step,
            down_interval: config.down_interval,
        }
    }
}

/// The controller as it crosses: the sanitised knobs and the two numbers behind the next decision.
///
/// The clean streak travels because it IS the state — a fold that forgot it would sharpen on every
/// clean report instead of one per interval.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SlopDeskQpController {
    /// The sanitised knobs the fold runs on.
    pub config: SlopDeskQpConfig,
    /// The current constant quantiser.
    pub q: i32,
    /// The clean-report streak carried between folds.
    pub clean_streak: i32,
}

impl SlopDeskQpController {
    /// The crate's controller for this record, and the record for one.
    fn inner(self) -> QpController {
        QpController::restored(self.config.inner(), self.q, self.clean_streak)
    }

    /// The record for a controller — every number the next fold needs, and nothing else.
    const fn of(controller: QpController) -> Self {
        Self {
            config: SlopDeskQpConfig::of(controller.config()),
            q: controller.q(),
            clean_streak: controller.clean_streak(),
        }
    }
}

// The knobs are sanitised by `slopdesk_qp_new`, and there is no door that only sanitises.
//
// `QpController::new` calls `sanitized()` on the way in and so does the by-value rebuild, so every
// controller that exists has legal knobs whatever a caller passed. A standalone door would answer a
// config the caller then has to remember to use — and the one that forgot would be
// indistinguishable from the one that did.
//
// The DEFAULTS door below is not that door. Sanitising is a rule, and a rule the caller can skip is
// a rule that is sometimes not applied; the defaults are a TABLE, and a table the caller can skip
// is a table nobody spelled twice. The failure mode each avoids is the opposite one.

/// The tuned defaults for the quantiser knobs, so the fallback each `SLOPDESK_QP_*` parse falls
/// back TO is spelled once.
///
/// These four numbers were hardware-validated together, and the host used to re-declare them beside
/// its environment lookups. Two spellings of one table is the shape `docs/55` §8 catalogues: retune
/// `sharp` here and a host that kept its own `26` would keep encoding at the old operating point
/// with nothing to show that it had diverged — no build error, no failing test, just a different
/// picture. The numbers are unsanitised on purpose, because they are already legal and
/// `slopdesk_qp_new` sanitises whatever it is handed regardless.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_qp_config_default() -> SlopDeskQpConfig {
    SlopDeskQpConfig::of(QpConfig::default())
}

/// A controller seeded at `seed_q`, with the config sanitised and the seed clamped into it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_qp_new(config: SlopDeskQpConfig, seed_q: i32) -> SlopDeskQpController {
    SlopDeskQpController::of(QpController::new(config.inner(), seed_q))
}

/// Folds one report's congestion verdict and answers the controller that results.
///
/// Congested coarsens by a whole step toward the coarse bound; clean sharpens by one, but only once
/// the streak reaches the interval, and the streak restarts either way.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_qp_decide(
    controller: SlopDeskQpController,
    congested: bool,
) -> SlopDeskQpController {
    let mut inner = controller.inner();
    inner.decide(congested);
    SlopDeskQpController::of(inner)
}

/// Parses one of the integer quantiser knobs, CLAMPING an out-of-range value rather than rejecting
/// it, and falling back to `default` when the text is absent or not an integer.
///
/// `has_raw` distinguishes an ABSENT knob from an empty one: an empty string is text that does not
/// parse, which is the same answer here, but the caller should not have to know that.
///
/// # Safety
/// `(raw, raw_len)` must describe live memory for the whole call, or be null.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_qp_clamped_int(
    raw: *const c_uchar,
    raw_len: usize,
    has_raw: bool,
    default: i32,
    lo: i32,
    hi: i32,
) -> i32 {
    // SAFETY: the pair is live for the call or null, which borrows as empty.
    let bytes = unsafe { borrow(raw, raw_len) };
    let text = has_raw.then(|| String::from_utf8_lossy(bytes).into_owned());
    clamped_int_from_env(text.as_deref(), default, lo, hi)
}

// ---------------------------------------------------------------------------------------------
// The encoder's own quantiser ceiling: what the budget affords, and what its drops say
// ---------------------------------------------------------------------------------------------

/// The band the budget's density is mapped onto, and the relief's three tunables, as they cross.
///
/// One record rather than seven arguments and seven fallbacks, for the reason
/// `slopdesk_qp_config_default` gives one section up: they were calibrated together on hardware, so
/// a caller that kept its own spelling of one of them would encode at an operating point nobody
/// chose, with no build error and no failing test to say so. Widest-first, so the hand-written
/// header has no padding to transcribe.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskQpCeilingConfig {
    /// The density at or above which the sharp end fits, in bits per pixel per frame.
    pub sharp_bpp: f64,
    /// The density at or below which the ceiling is fully relaxed.
    pub coarse_bpp: f64,
    /// The sharp end of the budget-adaptive ceiling.
    pub sharp_qp: i32,
    /// How far one dropped frame lifts the relief.
    pub attack_step: i32,
    /// Consecutive clean encodes the relief holds at full height before it may decay.
    pub hold_frames: i32,
    /// After the hold, one quantiser step per this many clean encodes.
    pub decay_every: i32,
}

/// The drop-feedback relief as it crosses: both numbers the next fold reads, and nothing else.
///
/// The clean-frame streak travels for the reason `SlopDeskQpController`'s does — it IS the state,
/// and a relief rebuilt without it would decay from inside its own hold window.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct SlopDeskQpDropRelief {
    /// The extra quantiser steps the caller composes above the budget-derived ceiling.
    pub relief: i32,
    /// The consecutive clean encodes folded since the last drop.
    pub clean_frames: i32,
}

/// The hardware-calibrated defaults for the budget ceiling and the drop relief.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_qp_ceiling_config_default() -> SlopDeskQpCeilingConfig {
    SlopDeskQpCeilingConfig {
        sharp_bpp: encoder_ceiling::SHARP_BPP,
        coarse_bpp: encoder_ceiling::COARSE_BPP,
        sharp_qp: encoder_ceiling::SHARP_QP_CEILING,
        attack_step: encoder_ceiling::ATTACK_STEP,
        hold_frames: encoder_ceiling::HOLD_FRAMES,
        decay_every: encoder_ceiling::DECAY_EVERY,
    }
}

/// The quantiser ceiling a budget of `target_bps` affords on a `pixel_width` by `pixel_height`
/// picture at `fps`, given the band's two ends and two knees.
///
/// Every refusal — a degenerate picture, cadence or budget, an inverted band, an inverted pair of
/// knees, a quantiser outside the byte range — answers `coarse`. There is no sentinel, because the
/// coarse end IS the safe answer: the encoder coarsens rather than dropping a frame it cannot fit.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_video_qp_ceiling(
    target_bps: i64,
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    sharp: i32,
    coarse: i32,
    sharp_bpp: f64,
    coarse_bpp: f64,
) -> i32 {
    encoder_ceiling::qp_ceiling(
        target_bps,
        pixel_width,
        pixel_height,
        fps,
        encoder_ceiling::CeilingBand {
            sharp,
            coarse,
            sharp_bpp,
            coarse_bpp,
        },
    )
}

/// Folds one encode tick's dropped-frame count into the relief and answers the relief that results.
///
/// A drop attacks at once; a clean tick lengthens the streak and, past the hold, decays one step
/// per interval. A carried record is sanitised into a legal state on the way in, because a panic
/// crossing this boundary aborts the process.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_qp_drop_relief_fold(
    state: SlopDeskQpDropRelief,
    drops: i64,
) -> SlopDeskQpDropRelief {
    let mut inner = encoder_ceiling::DropRelief::restored(state.relief, state.clean_frames);
    inner.fold(drops);
    SlopDeskQpDropRelief {
        relief: inner.relief(),
        clean_frames: inner.clean_frames(),
    }
}

// ---------------------------------------------------------------------------------------------
// The recovery-keyframe admission law
// ---------------------------------------------------------------------------------------------

/// The recovery policy's tuning, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskIdrConfig {
    /// The in-flight grace is this fraction of the smoothed round trip, clamped below.
    pub grace_fraction: f64,
    /// Covers the bootstrap, where the smoothed round trip is still zero.
    pub grace_floor_seconds: f64,
    /// The duplicate-keyframe spacing; beyond it, suppression only adds freeze.
    pub grace_ceil_seconds: f64,
    /// The burst allowance: one ordinary grant plus one casualty bypass.
    pub bucket_capacity: f64,
    /// The sustained refill.
    pub refill_tokens_per_second: f64,
    /// How long a granted-but-unserviced latch suppresses duplicates.
    pub grant_pending_timeout: f64,
    /// How many recently sent keyframes to remember.
    pub keyframe_ring_capacity: usize,
}

impl SlopDeskIdrConfig {
    /// The crate's config for these numbers.
    const fn inner(self) -> RecoveryIdrConfig {
        RecoveryIdrConfig {
            grace_fraction: self.grace_fraction,
            grace_floor_seconds: self.grace_floor_seconds,
            grace_ceil_seconds: self.grace_ceil_seconds,
            bucket_capacity: self.bucket_capacity,
            refill_tokens_per_second: self.refill_tokens_per_second,
            grant_pending_timeout: self.grant_pending_timeout,
            keyframe_ring_capacity: self.keyframe_ring_capacity,
        }
    }

    /// These numbers for the crate's config.
    const fn of(config: RecoveryIdrConfig) -> Self {
        Self {
            grace_fraction: config.grace_fraction,
            grace_floor_seconds: config.grace_floor_seconds,
            grace_ceil_seconds: config.grace_ceil_seconds,
            bucket_capacity: config.bucket_capacity,
            refill_tokens_per_second: config.refill_tokens_per_second,
            grant_pending_timeout: config.grant_pending_timeout,
            keyframe_ring_capacity: config.keyframe_ring_capacity,
        }
    }
}

/// The tuned defaults for the recovery-keyframe knobs, spelled once for the same reason
/// [`slopdesk_qp_config_default`] is.
///
/// Seven numbers, and every one of them is load-bearing against a specific failure the host has
/// already had: the burst allowance is two because three re-opens the keyframe storm, and the
/// pending timeout is sized above the worst legitimate service path because anything shorter
/// double-grants and anything unbounded wedges. A second spelling of that reasoning is a second
/// place to get it wrong, and unlike the quantiser table these are floats — a host that re-typed
/// `0.040` as `0.04` would agree today and stop agreeing the moment either side is retuned.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_idr_config_default() -> SlopDeskIdrConfig {
    SlopDeskIdrConfig::of(RecoveryIdrConfig::default())
}

/// The policy behind an opaque pointer: one per session, mutated from the session actor.
#[derive(Debug)]
pub struct SlopDeskIdrPolicy {
    /// The law itself.
    policy: RecoveryIdrPolicy,
}

/// Borrows a handle as the policy it points at.
///
/// # Safety
/// `handle` must be null, or a pointer returned by [`slopdesk_idr_policy_new`] that has not been
/// freed, with no other live reference for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *mut SlopDeskIdrPolicy) -> Option<&'a mut SlopDeskIdrPolicy> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// A policy with a full bucket and no history. Never null unless allocation itself failed.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_idr_policy_new(config: SlopDeskIdrConfig) -> *mut SlopDeskIdrPolicy {
    Box::into_raw(Box::new(SlopDeskIdrPolicy {
        policy: RecoveryIdrPolicy::new(config.inner()),
    }))
}

/// Frees a policy. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_idr_policy_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idr_policy_free(handle: *mut SlopDeskIdrPolicy) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Notes every keyframe handed to the wire, with the frame id the packetizer gave it. A keyframe
/// going out services any pending grant.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idr_policy_note_keyframe_sent(
    handle: *mut SlopDeskIdrPolicy,
    frame_id: u32,
    now: f64,
) {
    // SAFETY: the caller's obligation, discharged by the Swift owner holding one handle.
    if let Some(held) = unsafe { held(handle) } {
        held.policy.note_keyframe_sent(frame_id, now);
    }
}

/// Folds a client ack. Idempotent, and only ids matching a ring entry count, so a plain P-frame ack
/// can never masquerade as keyframe delivery.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idr_policy_note_keyframe_delivered(
    handle: *mut SlopDeskIdrPolicy,
    frame_id: u32,
) {
    // SAFETY: the caller's obligation, as above.
    if let Some(held) = unsafe { held(handle) } {
        held.policy.note_keyframe_delivered(frame_id);
    }
}

/// THE admission decision for one recovery request, as a `SLOPDESK_IDR_VERDICT_*` value.
///
/// `has_last_decoded` false is the wire sentinel "nothing decoded yet", treated as maximally behind
/// so the connect-time first-keyframe loss rides the casualty bypass.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idr_policy_decide(
    handle: *mut SlopDeskIdrPolicy,
    now: f64,
    has_last_decoded: bool,
    last_decoded: u32,
    smoothed_rtt_seconds: f64,
) -> u32 {
    // SAFETY: the caller's obligation, as above.
    let Some(held) = (unsafe { held(handle) }) else {
        return SLOPDESK_IDR_VERDICT_SUPPRESS_RATE_LIMITED;
    };
    let verdict = held.policy.decide(
        now,
        has_last_decoded.then_some(last_decoded),
        smoothed_rtt_seconds,
    );
    match verdict {
        IdrVerdict::Grant => SLOPDESK_IDR_VERDICT_GRANT,
        IdrVerdict::SuppressGrantPending => SLOPDESK_IDR_VERDICT_SUPPRESS_GRANT_PENDING,
        IdrVerdict::SuppressStale => SLOPDESK_IDR_VERDICT_SUPPRESS_STALE,
        IdrVerdict::SuppressInFlight => SLOPDESK_IDR_VERDICT_SUPPRESS_IN_FLIGHT,
        IdrVerdict::SuppressRateLimited => SLOPDESK_IDR_VERDICT_SUPPRESS_RATE_LIMITED,
    }
}

/// The in-flight grace for a given smoothed round trip, clamped between the floor and ceiling.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idr_policy_grace(handle: *mut SlopDeskIdrPolicy, rtt: f64) -> f64 {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.map_or(0.0, |held| held.policy.grace(rtt))
}

/// The current token level, which proves the suppressing verdicts spend nothing.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_idr_policy_available_tokens(handle: *mut SlopDeskIdrPolicy) -> f64 {
    // SAFETY: the caller's obligation, as above.
    unsafe { held(handle) }.map_or(0.0, |held| held.policy.available_tokens())
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        SLOPDESK_IDR_VERDICT_GRANT, SLOPDESK_IDR_VERDICT_SUPPRESS_GRANT_PENDING,
        SLOPDESK_IDR_VERDICT_SUPPRESS_IN_FLIGHT, SLOPDESK_IDR_VERDICT_SUPPRESS_RATE_LIMITED,
        SlopDeskIdrConfig, SlopDeskQpConfig, SlopDeskQpController, SlopDeskQpDropRelief,
        slopdesk_idr_config_default, slopdesk_idr_policy_available_tokens, slopdesk_idr_policy_decide,
        slopdesk_idr_policy_free, slopdesk_idr_policy_grace, slopdesk_idr_policy_new,
        slopdesk_idr_policy_note_keyframe_sent, slopdesk_qp_clamped_int, slopdesk_qp_config_default,
        slopdesk_qp_decide, slopdesk_qp_new, slopdesk_video_qp_ceiling,
        slopdesk_video_qp_ceiling_config_default, slopdesk_video_qp_drop_relief_fold,
    };

    /// The encoder ceiling's own tuned table, and the refusal that is not a sentinel.
    #[test]
    fn the_encoder_ceiling_table_and_its_refusals_cross_intact() {
        let config = slopdesk_video_qp_ceiling_config_default();
        assert!((config.sharp_bpp - 0.14).abs() < f64::EPSILON);
        assert!((config.coarse_bpp - 0.07).abs() < f64::EPSILON);
        assert_eq!(
            (
                config.sharp_qp,
                config.attack_step,
                config.hold_frames,
                config.decay_every
            ),
            (38, 4, 180, 4),
        );

        let ceiling = |bps| {
            slopdesk_video_qp_ceiling(
                bps,
                1920,
                1080,
                60,
                config.sharp_qp,
                51,
                config.sharp_bpp,
                config.coarse_bpp,
            )
        };
        assert_eq!(ceiling(31_104_000), 38, "a dense budget stays sharp");
        assert_eq!(ceiling(14_929_920), 42, "the ramp between the knees");
        assert_eq!(ceiling(6_500_000), 51, "a thin budget relaxes all the way");
        assert_eq!(
            slopdesk_video_qp_ceiling(12_000_000, 0, 1080, 60, 38, 51, 0.14, 0.07),
            51,
            "a degenerate picture answers the coarse end, which is the SAFE answer and not a sentinel",
        );
    }

    /// The relief's streak travels, so a fold cannot decay from inside its own hold window.
    #[test]
    fn the_drop_relief_carries_the_state_the_next_fold_reads() {
        let attacked = slopdesk_video_qp_drop_relief_fold(SlopDeskQpDropRelief::default(), 1);
        assert_eq!(attacked, SlopDeskQpDropRelief {
            relief: 4,
            clean_frames: 0
        });

        // Walk the hold out one clean tick at a time, carrying the record each time.
        let mut carried = attacked;
        for _ in 0..180 {
            carried = slopdesk_video_qp_drop_relief_fold(carried, 0);
        }
        assert_eq!(carried.relief, 4, "nothing decays inside the hold");
        for _ in 0..4 {
            carried = slopdesk_video_qp_drop_relief_fold(carried, 0);
        }
        assert_eq!(carried.relief, 3, "one step comes off per interval past the hold");

        let hostile = slopdesk_video_qp_drop_relief_fold(
            SlopDeskQpDropRelief {
                relief: -900,
                clean_frames: -7,
            },
            0,
        );
        assert_eq!(hostile, SlopDeskQpDropRelief {
            relief: 0,
            clean_frames: 1
        },);
        assert_eq!(
            slopdesk_video_qp_drop_relief_fold(SlopDeskQpDropRelief::default(), i64::MAX).relief,
            51,
            "a broken drop counter lands on the cap rather than aborting the process",
        );
    }

    /// The defaults cross intact, and they are the operating point `docs/29` records rather than
    /// whatever the struct's own `Default` would have produced field by field.
    #[test]
    fn the_tuned_defaults_reach_the_caller_unchanged() {
        let qp = slopdesk_qp_config_default();
        assert_eq!(qp, SlopDeskQpConfig {
            sharp: 26,
            coarse: 40,
            up_step: 3,
            down_interval: 4
        },);
        assert_ne!(
            qp,
            SlopDeskQpConfig::default(),
            "the derived all-zero default is not the tuned one, and this door must answer the tuned one",
        );

        let idr = slopdesk_idr_config_default();
        assert!((idr.grace_fraction - 0.75).abs() < f64::EPSILON);
        assert!((idr.grace_floor_seconds - 0.040).abs() < f64::EPSILON);
        assert!((idr.grace_ceil_seconds - 0.250).abs() < f64::EPSILON);
        assert!((idr.bucket_capacity - 2.0).abs() < f64::EPSILON);
        assert!((idr.refill_tokens_per_second - 2.0).abs() < f64::EPSILON);
        assert!((idr.grant_pending_timeout - 1.5).abs() < f64::EPSILON);
        assert_eq!(idr.keyframe_ring_capacity, 4);
    }

    /// The defaults are already legal, so sanitising them is the identity. A retune that broke this
    /// would be shipping an operating point the controller silently declines to run at.
    #[test]
    fn the_default_quantiser_knobs_survive_their_own_sanitation() {
        let seeded = slopdesk_qp_new(slopdesk_qp_config_default(), 30);
        assert_eq!(seeded.config, slopdesk_qp_config_default());
        assert_eq!(seeded.q, 30, "and the seed is inside the default range");
    }

    /// The sanitation `QpController::new` applies on the way in, asked directly: there is no door
    /// that only sanitises, because a caller who forgot to use its answer would look identical to
    /// one who did.
    fn sanitized(config: SlopDeskQpConfig) -> SlopDeskQpConfig {
        SlopDeskQpConfig::of(config.inner().sanitized())
    }

    /// The production knobs.
    const fn knobs() -> SlopDeskQpConfig {
        SlopDeskQpConfig {
            sharp: 26,
            coarse: 40,
            up_step: 3,
            down_interval: 4,
        }
    }

    /// The production tuning.
    const fn tuning() -> SlopDeskIdrConfig {
        SlopDeskIdrConfig {
            grace_fraction: 0.75,
            grace_floor_seconds: 0.040,
            grace_ceil_seconds: 0.250,
            bucket_capacity: 2.0,
            refill_tokens_per_second: 2.0,
            grant_pending_timeout: 1.5,
            keyframe_ring_capacity: 4,
        }
    }

    #[test]
    fn a_hostile_config_cannot_invert_or_escape_the_legal_span() {
        assert_eq!(
            sanitized(SlopDeskQpConfig {
                sharp: -5,
                coarse: 3,
                up_step: 0,
                down_interval: 0,
            }),
            SlopDeskQpConfig {
                sharp: 1,
                coarse: 3,
                up_step: 1,
                down_interval: 1,
            },
            "a sub-legal sharp rises to the floor and the steps land at one",
        );
        assert_eq!(
            sanitized(SlopDeskQpConfig {
                sharp: 44,
                coarse: 12,
                up_step: 3,
                down_interval: 4,
            })
            .coarse,
            44,
            "a coarse below the sharp is lifted to it rather than inverting the range",
        );
        assert_eq!(
            slopdesk_qp_new(knobs(), 99).q,
            40,
            "the seed is clamped into the sanitised range",
        );
    }

    #[test]
    fn congestion_coarsens_fast_and_clean_sharpens_one_step_per_interval() {
        let mut controller = slopdesk_qp_new(knobs(), 30);
        controller = slopdesk_qp_decide(controller, true);
        assert_eq!(controller.q, 33, "a congested report rises by the whole step");
        assert_eq!(controller.clean_streak, 0);

        // Three clean reports build the streak without moving the quantiser; the fourth spends it.
        let quiet: Vec<SlopDeskQpController> = (0..4)
            .scan(controller, |held, _| {
                *held = slopdesk_qp_decide(*held, false);
                Some(*held)
            })
            .collect();
        assert_eq!(
            quiet.iter().map(|held| held.q).collect::<Vec<_>>(),
            vec![33, 33, 33, 32],
            "one sharpen per four clean reports, not one per report",
        );
        assert_eq!(
            quiet.iter().map(|held| held.clean_streak).collect::<Vec<_>>(),
            vec![1, 2, 3, 0],
            "the streak is the state, and spending it resets it",
        );
    }

    #[test]
    fn the_quantiser_stops_at_both_bounds() {
        let mut controller = slopdesk_qp_new(knobs(), 39);
        for _ in 0..5 {
            controller = slopdesk_qp_decide(controller, true);
        }
        assert_eq!(controller.q, 40, "congestion cannot push past the coarse bound");
        let mut controller = slopdesk_qp_new(knobs(), 27);
        for _ in 0..40 {
            controller = slopdesk_qp_decide(controller, false);
        }
        assert_eq!(controller.q, 26, "quiet cannot sharpen past the sharp bound");
    }

    #[test]
    fn a_knob_is_clamped_rather_than_rejected_and_absent_text_falls_back() {
        let parse = |text: Option<&str>| {
            let bytes = text.unwrap_or("").as_bytes();
            unsafe { slopdesk_qp_clamped_int(bytes.as_ptr(), bytes.len(), text.is_some(), 26, 1, 51) }
        };
        assert_eq!(
            (parse(None), parse(Some("")), parse(Some("nonsense"))),
            (26, 26, 26),
            "absent, empty and unparseable all fall back to the default",
        );
        assert_eq!(
            (parse(Some("99")), parse(Some("-4")), parse(Some("31"))),
            (51, 1, 31),
            "an out-of-range knob is clamped to the nearest legal value",
        );
    }

    #[test]
    fn a_request_that_crosses_a_fresh_keyframe_is_suppressed_and_an_aged_one_is_granted() {
        let handle = slopdesk_idr_policy_new(tuning());
        unsafe { slopdesk_idr_policy_note_keyframe_sent(handle, 100, 1.0) };
        // The client is behind the keyframe that just went out, and the grace has not elapsed.
        assert_eq!(
            unsafe { slopdesk_idr_policy_decide(handle, 1.01, true, 90, 0.020) },
            SLOPDESK_IDR_VERDICT_SUPPRESS_IN_FLIGHT,
        );
        assert!(
            (unsafe { slopdesk_idr_policy_available_tokens(handle) } - 2.0).abs() < 1e-9,
            "a suppressed request spends nothing",
        );
        // Past the grace the keyframe is presumed a casualty — the bypass.
        assert_eq!(
            unsafe { slopdesk_idr_policy_decide(handle, 1.30, true, 90, 0.020) },
            SLOPDESK_IDR_VERDICT_GRANT,
        );
        // And a second request while that grant is unserviced is absorbed.
        assert_eq!(
            unsafe { slopdesk_idr_policy_decide(handle, 1.31, true, 90, 0.020) },
            SLOPDESK_IDR_VERDICT_SUPPRESS_GRANT_PENDING,
        );
        unsafe { slopdesk_idr_policy_free(handle) };
    }

    #[test]
    fn the_bucket_caps_a_storm_and_the_grace_is_clamped_at_both_ends() {
        let handle = slopdesk_idr_policy_new(tuning());
        // Three requests a tenth of a second apart — past the grace every time, so nothing is
        // suppressed as in flight, and each grant is serviced by the keyframe that follows it.
        // Refill is 2/s, so 0.1 s buys 0.2 of a token and the bucket cannot keep up with the burst.
        let verdicts: Vec<u32> = (0..3)
            .map(|round| {
                let now = f64::from(round) * 0.1;
                let verdict = unsafe { slopdesk_idr_policy_decide(handle, now, false, 0, 0.0) };
                unsafe { slopdesk_idr_policy_note_keyframe_sent(handle, 10 + round, now) };
                verdict
            })
            .collect();
        assert_eq!(
            verdicts,
            vec![
                SLOPDESK_IDR_VERDICT_GRANT,
                SLOPDESK_IDR_VERDICT_GRANT,
                SLOPDESK_IDR_VERDICT_SUPPRESS_RATE_LIMITED
            ],
            "a burst of two, then the storm cap",
        );
        let grace = |rtt| unsafe { slopdesk_idr_policy_grace(handle, rtt) };
        assert!(
            (grace(0.0) - 0.040).abs() < 1e-9 && (grace(10.0) - 0.250).abs() < 1e-9,
            "the bootstrap floor and the duplicate-keyframe ceiling both bind",
        );
        unsafe { slopdesk_idr_policy_free(handle) };
    }

    #[test]
    fn a_null_handle_answers_rather_than_faults() {
        assert_eq!(
            unsafe { slopdesk_idr_policy_decide(std::ptr::null_mut(), 0.0, false, 0, 0.0) },
            SLOPDESK_IDR_VERDICT_SUPPRESS_RATE_LIMITED,
            "no policy means no keyframe, which is the safe answer",
        );
        assert!((unsafe { slopdesk_idr_policy_grace(std::ptr::null_mut(), 0.1) }).abs() < 1e-9);
        assert!((unsafe { slopdesk_idr_policy_available_tokens(std::ptr::null_mut()) }).abs() < 1e-9);
        unsafe { slopdesk_idr_policy_note_keyframe_sent(std::ptr::null_mut(), 0, 0.0) };
        unsafe { slopdesk_idr_policy_free(std::ptr::null_mut()) };
    }
}
