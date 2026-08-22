//! The FEC ladder: how measured loss becomes the per-frame redundancy both ends must agree on.
//!
//! [`slopdesk_video::adaptive_fec`] holds the whole decision — the wire tier's group size, the
//! hysteretic level ladder, the relax dwell, the sticky window a dropped frame opens, and the
//! parity-`m` ladder beside it. This module is the boundary to it.
//!
//! ## Why nothing here is a handle
//! Every one of these is a function of its arguments. The tier decision looks stateful and is not:
//! the state IS the answer, so it crosses as a [`SlopDeskFecTierState`] in and one out, by value.
//! Three scalars are cheaper to copy than a handle is to own, and a value the host stores in its
//! own session struct cannot drift from a counter living somewhere else.
//!
//! ## Why the env still resolves in Swift
//! `SLOPDESK_FEC_M` and `SLOPDESK_FEC_K` come from `EnvConfig`, which reads the process environment
//! AND the settings overlay a GUI toggle writes — that lookup is the app's, not the codec's. So
//! Swift finds the string and this side decides what it means: parse, default, clamp, and the joint
//! `k + m <= 255` bound the field imposes. A missing variable and an unparseable one answer the
//! same, which is why absence needs no flag of its own — pass `(NULL, 0)`.

use core::ffi::c_uchar;

use slopdesk_video::adaptive_fec::{self, TierState};

use crate::borrow;

/// The tier decision's state, in and out by value: the wire tier, how many consecutive reports have
/// demanded relaxation, and how much of the sticky window a recent unrecovered loss opened is left.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskFecTierState {
    /// Consecutive relax-demanding reports so far; reset by any report that holds or escalates.
    pub relax_streak: u32,
    /// Reports left in the doubled-dwell window; 0 = inactive.
    pub sticky_relax_remaining: u32,
    /// The wire tier this state carries.
    pub tier: u8,
}

impl From<TierState> for SlopDeskFecTierState {
    fn from(state: TierState) -> Self {
        Self {
            relax_streak: state.relax_streak,
            sticky_relax_remaining: state.sticky_relax_remaining,
            tier: state.tier,
        }
    }
}

impl From<SlopDeskFecTierState> for TierState {
    fn from(state: SlopDeskFecTierState) -> Self {
        Self::new(state.tier, state.relax_streak, state.sticky_relax_remaining)
    }
}

/// One of the ladder's constants, by index — so neither end writes a number the other also writes.
///
/// 0 default tier · 1 parity tier CLEAN · 2 parity tier NORMAL · 3 parity tier BURST · 4 relax
/// dwell reports · 5 sticky-relax window reports · 6 the multi-loss default `k` · 7/8 the `m`
/// bounds · 9/10 the `k` bounds · 11 the multi-loss default `m`. An unknown index answers 0, which
/// is the default tier and so cannot be mistaken for a count.
///
/// 11 is deliberately not folded into 7: the floor and the default coincide today and answer
/// different questions, and a settings face that read the floor as "the default" would agree until
/// the floor moved.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_adaptive_fec_constant(index: u8) -> u32 {
    let size = |value: usize| u32::try_from(value).unwrap_or(0);
    match index {
        1 => u32::from(adaptive_fec::PARITY_TIER_CLEAN),
        2 => u32::from(adaptive_fec::PARITY_TIER_NORMAL),
        3 => u32::from(adaptive_fec::PARITY_TIER_BURST),
        4 => adaptive_fec::RELAX_DWELL_REPORTS,
        5 => adaptive_fec::STICKY_RELAX_WINDOW_REPORTS,
        6 => size(adaptive_fec::multi_loss::DEFAULT_K),
        7 => size(adaptive_fec::multi_loss::M_MIN),
        8 => size(adaptive_fec::multi_loss::M_MAX),
        9 => size(adaptive_fec::multi_loss::K_MIN),
        10 => size(adaptive_fec::multi_loss::K_MAX),
        11 => size(adaptive_fec::multi_loss::DEFAULT_M),
        // 0 and anything unknown: the default tier, which IS zero.
        _ => u32::from(adaptive_fec::DEFAULT_TIER),
    }
}

/// The FEC group size a wire tier means. Answers `false` — writing nothing — for the OFF tier that
/// carries no parity at all.
///
/// The absence is the RETURN value and not a reserved size because every size is legal here: the
/// caller passes its own configured default through, and a caller whose default is 0 would
/// otherwise be told its own answer means OFF. Same reason
/// [`crate::video_reassemble::slopdesk_video_reassembler_next_dropped_frame`] writes through an out
/// param.
///
/// Total over every `u8` — a tier read off a corrupt fragment must never trap, and a reserved value
/// falls back to the caller's default.
///
/// # Safety
/// `out` must be null or point to one writable, aligned `usize` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_adaptive_fec_group_size(
    tier: u8,
    default_group_size: usize,
    out: *mut usize,
) -> bool {
    let Some(size) = adaptive_fec::group_size(tier, default_group_size) else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, one writable, aligned `usize`.
        unsafe { out.write(size) };
    }
    true
}

/// The tier the host must stamp on every frame, given which ladders are active.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_adaptive_fec_wire_tier(
    adaptive_tier: u8,
    adaptive_m_enabled: bool,
    multi_loss_active: bool,
) -> u8 {
    adaptive_fec::wire_tier(adaptive_tier, adaptive_m_enabled, multi_loss_active)
}

/// The undwelled group-size ladder step: hysteresis and a one-level clamp.
///
/// The tools' and tests' entry point; production steps through
/// [`slopdesk_adaptive_fec_next_tier_state`], which is this plus the dwell.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_adaptive_fec_tier(loss: f64, previous_tier: u8, allow_off: bool) -> u8 {
    adaptive_fec::tier_for_loss(loss, previous_tier, allow_off)
}

/// The dwell-gated group-size ladder step — the production decision, once per client stats report.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_adaptive_fec_next_tier_state(
    loss: f64,
    state: SlopDeskFecTierState,
    dwell: u32,
    allow_off: bool,
    saw_unrecovered_loss: bool,
) -> SlopDeskFecTierState {
    adaptive_fec::next_tier_state(loss, state.into(), dwell, allow_off, saw_unrecovered_loss).into()
}

/// The dwell-gated parity-`m` ladder step: fast attack, slow decay, and no OFF level to fall to.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_adaptive_fec_next_parity_tier_state(
    loss: f64,
    state: SlopDeskFecTierState,
    dwell: u32,
    saw_unrecovered_loss: bool,
) -> SlopDeskFecTierState {
    adaptive_fec::next_parity_tier_state(loss, state.into(), dwell, saw_unrecovered_loss).into()
}

/// What `SLOPDESK_FEC_M` means: parse, default 1, clamp to the allowed range.
///
/// # Safety
/// `raw` must be null or point to `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_adaptive_fec_resolve_parity_count(
    raw: *const c_uchar,
    len: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(raw, len) };
    adaptive_fec::multi_loss::resolve_parity_count(str_or_absent(bytes))
}

/// Whether a resolved `m` means the multi-loss codec is ACTIVE.
///
/// A separate entry from [`slopdesk_adaptive_fec_constant`]'s `M_MIN`/`M_MAX` because it is not a
/// bound, it is a MEANING: `m >= 2` is what makes the wire's parity-per-group count change, what
/// selects the true `[k + m, k]` code over the XOR-equivalent default, and what
/// [`slopdesk_adaptive_fec_wire_tier`]'s `multi_loss_active` argument is asking about. A caller
/// given only the two bounds would have to recompose the threshold from them, which is the
/// transcription this door exists to remove — and it had already happened twice on the Swift side,
/// once in `MultiLossFEC.isActive` and once in `adaptiveMFromEnv`.
///
/// The argument is the RESOLVED count rather than the raw string, because the resolution already
/// has a door of its own and asking through both keeps one parse rather than two.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_adaptive_fec_multi_loss_active(parity_count: usize) -> bool {
    adaptive_fec::multi_loss::is_active(parity_count)
}

/// What `SLOPDESK_FEC_K` means: parse, default, clamp, then cap against the field bound.
///
/// The cap keeps `k + m <= 255` for the `m` the same environment resolves. Both strings cross
/// because that bound is joint — asking for `k` alone would answer a size the field cannot hold.
///
/// # Safety
/// `raw_k` and `raw_m` must each be null or point to their `len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_adaptive_fec_resolve_group_size(
    raw_k: *const c_uchar,
    len_k: usize,
    raw_m: *const c_uchar,
    len_m: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let (k, m) = unsafe { (borrow(raw_k, len_k), borrow(raw_m, len_m)) };
    adaptive_fec::multi_loss::resolve_group_size(str_or_absent(k), str_or_absent(m))
}

/// An empty or non-UTF-8 span reads as an absent variable, which is what an unparseable one already
/// resolves to — so absence needs no flag of its own on the wire between the two languages.
fn str_or_absent(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() {
        return None;
    }
    core::str::from_utf8(bytes).ok()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::*;

    fn group_size(tier: u8, default_group_size: usize) -> Option<usize> {
        let mut size = 0usize;
        let on = unsafe { slopdesk_adaptive_fec_group_size(tier, default_group_size, &raw mut size) };
        on.then_some(size)
    }

    #[test]
    fn only_the_off_tier_answers_absent_and_reserved_tiers_take_the_default() {
        assert_eq!(group_size(1, 5), None, "tier 1 is OFF");
        assert_eq!(group_size(0, 5), Some(5));
        assert_eq!(group_size(2, 5), Some(10));
        assert_eq!(group_size(3, 5), Some(3));
        assert_eq!(group_size(4, 5), Some(2));
        for tier in [5u8, 6, 7, 128, 255] {
            assert_eq!(group_size(tier, 7), Some(7), "tier {tier}");
        }
        // A caller whose own default is 0 must still get its answer back, not the absence.
        assert_eq!(group_size(0, 0), Some(0), "0 is a size like any other");
        assert_eq!(group_size(1, 0), None, "and OFF is still OFF");
    }

    #[test]
    fn the_boundary_agrees_with_the_ladder_it_wraps() {
        for tier in 0u8..8 {
            for loss in [0.0, 0.001, 0.006, 0.03, 0.07, 0.2] {
                assert_eq!(
                    slopdesk_adaptive_fec_tier(loss, tier, false),
                    adaptive_fec::tier_for_loss(loss, tier, false),
                );
                assert_eq!(
                    slopdesk_adaptive_fec_tier(loss, tier, true),
                    adaptive_fec::tier_for_loss(loss, tier, true),
                );
            }
        }
    }

    #[test]
    fn the_state_survives_the_trip_out_and_back() {
        let mut state = SlopDeskFecTierState {
            tier: adaptive_fec::DEFAULT_TIER,
            ..SlopDeskFecTierState::default()
        };
        // A loss burst escalates on the report it arrives on, dwell or no dwell.
        state = slopdesk_adaptive_fec_next_tier_state(0.2, state, 240, false, false);
        assert_eq!(state.tier, 3, "one level up from g5 is g3");
        assert_eq!(state.relax_streak, 0);

        // Relaxation waits: the streak counts, and the tier does not move until the dwell is met.
        let mut clean = state;
        for _ in 0..2 {
            clean = slopdesk_adaptive_fec_next_tier_state(0.0, clean, 3, false, false);
            assert_eq!(clean.tier, 3, "still holding while the streak builds");
        }
        clean = slopdesk_adaptive_fec_next_tier_state(0.0, clean, 3, false, false);
        assert_eq!(clean.tier, adaptive_fec::DEFAULT_TIER, "the dwell was met");
    }

    #[test]
    fn an_unrecovered_loss_doubles_the_dwell_and_the_window_decays() {
        let state = SlopDeskFecTierState::default();
        let armed = slopdesk_adaptive_fec_next_tier_state(0.0, state, 240, false, true);
        assert_eq!(
            armed.sticky_relax_remaining,
            adaptive_fec::STICKY_RELAX_WINDOW_REPORTS,
        );
        let next = slopdesk_adaptive_fec_next_tier_state(0.0, armed, 240, false, false);
        assert_eq!(
            next.sticky_relax_remaining,
            adaptive_fec::STICKY_RELAX_WINDOW_REPORTS - 1,
            "the window decays by one per report",
        );
    }

    #[test]
    fn the_parity_ladder_attacks_fast_and_never_falls_below_clean() {
        let state = SlopDeskFecTierState {
            tier: adaptive_fec::PARITY_TIER_CLEAN,
            ..SlopDeskFecTierState::default()
        };
        let burst = slopdesk_adaptive_fec_next_parity_tier_state(0.2, state, 240, false);
        assert_eq!(burst.tier, adaptive_fec::PARITY_TIER_BURST, "straight there");

        let mut clean = state;
        for _ in 0..10 {
            clean = slopdesk_adaptive_fec_next_parity_tier_state(0.0, clean, 1, false);
        }
        assert_eq!(clean.tier, adaptive_fec::PARITY_TIER_CLEAN, "the floor holds");
    }

    #[test]
    fn an_absent_variable_and_an_unparseable_one_resolve_alike() {
        let absent = unsafe { slopdesk_adaptive_fec_resolve_parity_count(core::ptr::null(), 0) };
        let nonsense = "not a number";
        let unparseable =
            unsafe { slopdesk_adaptive_fec_resolve_parity_count(nonsense.as_ptr(), nonsense.len()) };
        assert_eq!(absent, 1);
        assert_eq!(unparseable, 1);

        let three = "3";
        let m = unsafe { slopdesk_adaptive_fec_resolve_parity_count(three.as_ptr(), three.len()) };
        assert_eq!(m, 3);
    }

    #[test]
    fn the_threshold_the_two_languages_shared_is_now_one_answer() {
        // The bounds cannot stand in for it: `M_MIN` is 1, so a caller composing the threshold out
        // of `slopdesk_adaptive_fec_constant` would get "always active".
        assert!(!slopdesk_adaptive_fec_multi_loss_active(0));
        assert!(!slopdesk_adaptive_fec_multi_loss_active(
            adaptive_fec::multi_loss::M_MIN
        ));
        for m in 2..=adaptive_fec::multi_loss::M_MAX {
            assert!(slopdesk_adaptive_fec_multi_loss_active(m), "m = {m}");
        }
        // And it is the same predicate the tier→`m` table gates itself on, which is the drift this
        // removes: an `m` the door calls inactive must be an `m` that resolves every tier to itself.
        for m in 0..=adaptive_fec::multi_loss::M_MAX {
            if !slopdesk_adaptive_fec_multi_loss_active(m) {
                for tier in [
                    adaptive_fec::PARITY_TIER_CLEAN,
                    adaptive_fec::PARITY_TIER_NORMAL,
                    adaptive_fec::PARITY_TIER_BURST,
                ] {
                    assert_eq!(adaptive_fec::parity_count(tier, m), m, "m = {m}, tier = {tier}");
                }
            }
        }
    }

    #[test]
    fn the_group_size_is_capped_against_the_parity_count_it_travels_with() {
        let big_k = "64";
        let m = "8";
        let k = unsafe {
            slopdesk_adaptive_fec_resolve_group_size(big_k.as_ptr(), big_k.len(), m.as_ptr(), m.len())
        };
        assert_eq!(k, 64, "64 + 8 is well inside the field bound");
        let defaulted =
            unsafe { slopdesk_adaptive_fec_resolve_group_size(core::ptr::null(), 0, core::ptr::null(), 0) };
        assert_eq!(defaulted, adaptive_fec::multi_loss::DEFAULT_K);
    }
}
