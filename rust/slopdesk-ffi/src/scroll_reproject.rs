//! The client-side scroll-hint reprojection law.
//!
//! Seven scalars and nothing else, so it crosses BY VALUE: the caller copies the state out, folds
//! into it and writes it back. The near side holds one per pane inside a class it already owns, the
//! way the decode gate is held — the reference is the pane's, the state is this law's.
//!
//! An advance answers both the state and the offset, because the offset is what the renderer sets
//! and the state is what the next tick folds. Splitting them would make the near side call twice
//! and invent a rule about the order.

use slopdesk_video::scroll_reproject::{ScrollHint, ScrollPhase, ScrollReprojector};

/// Finger on glass: track the velocity, no decay.
pub const SLOPDESK_SCROLL_PHASE_ACTIVE: u32 = 0;
/// Inertial coast: track the velocity, no decay.
pub const SLOPDESK_SCROLL_PHASE_MOMENTUM: u32 = 1;
/// The gesture finished: arm the decay.
pub const SLOPDESK_SCROLL_PHASE_ENDED: u32 = 2;

/// The phase a code names. An unknown code cannot arise from this door and reads as the phase that
/// tracks without decaying, which is the one a stray sample may not silently arm a decay with.
const fn phase_of(code: u32) -> ScrollPhase {
    match code {
        SLOPDESK_SCROLL_PHASE_MOMENTUM => ScrollPhase::Momentum,
        SLOPDESK_SCROLL_PHASE_ENDED => ScrollPhase::Ended,
        _ => ScrollPhase::Active,
    }
}

/// The code one phase carries.
const fn code_of(phase: ScrollPhase) -> u32 {
    match phase {
        ScrollPhase::Active => SLOPDESK_SCROLL_PHASE_ACTIVE,
        ScrollPhase::Momentum => SLOPDESK_SCROLL_PHASE_MOMENTUM,
        ScrollPhase::Ended => SLOPDESK_SCROLL_PHASE_ENDED,
    }
}

/// The phase the platform's scroll and momentum codes name together.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_phase_of_platform(scroll_phase: u8, momentum_phase: u8) -> u32 {
    code_of(ScrollPhase::of_platform(scroll_phase, momentum_phase))
}

/// One host-measured per-frame scroll shift, in the fixed-point units it crosses the wire in.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskScrollHint {
    /// The signed horizontal shift over one frame, in ten-thousandths of the frame width.
    pub dx: i16,
    /// The signed vertical shift over one frame, in ten-thousandths of the frame height.
    pub dy: i16,
    /// The top of the moving-content band, in ten-thousandths of the frame height.
    pub band_top: u16,
    /// The band's bottom edge, exclusive, in the same units.
    pub band_bottom: u16,
}

impl SlopDeskScrollHint {
    /// The wrapped hint this describes.
    const fn inner(self) -> ScrollHint {
        ScrollHint::restored(self.dx, self.dy, self.band_top, self.band_bottom)
    }

    /// The crossing form of a wrapped hint.
    const fn of(hint: ScrollHint) -> Self {
        Self {
            dx: hint.dx(),
            dy: hint.dy(),
            band_top: hint.band_top(),
            band_bottom: hint.band_bottom(),
        }
    }
}

/// One scroll-velocity sample, in normalised units per second, with the phase it folds under.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollVelocity {
    /// The horizontal velocity.
    pub vx: f64,
    /// The vertical velocity.
    pub vy: f64,
    /// The phase code.
    pub phase: u32,
}

/// The moving-content band, and whether there is one.
///
/// An absent band crosses as a flag rather than a sentinel: an empty span at the top of the frame
/// is a degenerate band, not "the host measured no band", and a caller holding an earlier band must
/// keep it rather than replace it with a zero.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollBand {
    /// The band's top edge, normalised.
    pub top: f32,
    /// The band's bottom edge, normalised.
    pub bottom: f32,
    /// Whether this hint carries a band at all.
    pub present: bool,
}

/// The hint a measured estimate encodes, over the frame height it was measured on.
///
/// An unconfident or zero shift, or a degenerate height, answers the hint that says nothing moved.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_hint_measured(
    shift: i32,
    confidence_milli: u32,
    band_top_row: i32,
    band_bottom_row: i32,
    height: usize,
) -> SlopDeskScrollHint {
    SlopDeskScrollHint::of(ScrollHint::measured(
        shift,
        confidence_milli,
        band_top_row,
        band_bottom_row,
        height,
    ))
}

/// The velocity sample a hint is, at the rate the content frames arrive.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_hint_velocity(
    hint: SlopDeskScrollHint,
    content_fps: f64,
) -> SlopDeskScrollVelocity {
    let sample = hint.inner().velocity(content_fps);
    SlopDeskScrollVelocity {
        vx: sample.vx,
        vy: sample.vy,
        phase: code_of(sample.phase),
    }
}

/// The moving-content band a hint carries, if it carries one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_hint_band(hint: SlopDeskScrollHint) -> SlopDeskScrollBand {
    hint.inner().band().map_or(
        SlopDeskScrollBand {
            top: 0.0,
            bottom: 0.0,
            present: false,
        },
        |(top, bottom)| {
            SlopDeskScrollBand {
                top,
                bottom,
                present: true,
            }
        },
    )
}

/// The integrator, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollReprojector {
    /// The per-axis clamp on the integrated offset, in normalised units.
    pub max_band: f64,
    /// The decay time constant after a scroll ends, in seconds.
    pub decay_seconds: f64,
    /// The integrated horizontal offset.
    pub offset_x: f64,
    /// The integrated vertical offset.
    pub offset_y: f64,
    /// The horizontal velocity, in normalised units per second.
    pub velocity_x: f64,
    /// The vertical velocity.
    pub velocity_y: f64,
    /// Whether a scroll has ended, so an advance decays rather than integrates.
    pub decaying: bool,
}

impl SlopDeskScrollReprojector {
    /// The wrapped reprojector this describes.
    const fn inner(self) -> ScrollReprojector {
        ScrollReprojector::restored(
            self.max_band,
            self.decay_seconds,
            self.offset_x,
            self.offset_y,
            self.velocity_x,
            self.velocity_y,
            self.decaying,
        )
    }

    /// The crossing form of a wrapped reprojector.
    const fn of(reprojector: &ScrollReprojector) -> Self {
        let (offset_x, offset_y) = reprojector.offset();
        let (velocity_x, velocity_y) = reprojector.velocity();
        Self {
            max_band: reprojector.max_band(),
            decay_seconds: reprojector.decay_seconds(),
            offset_x,
            offset_y,
            velocity_x,
            velocity_y,
            decaying: reprojector.decaying(),
        }
    }
}

/// One normalised offset, where a frame spans `0..1` on each axis.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollOffset {
    /// The horizontal offset.
    pub x: f64,
    /// The vertical offset.
    pub y: f64,
}

/// One advance: the state that results, and the offset to set on the renderer.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollAdvance {
    /// The reprojector after the tick.
    pub reprojector: SlopDeskScrollReprojector,
    /// The offset the frame should be shifted by.
    pub offset: SlopDeskScrollOffset,
}

/// The law's default knobs, so the near side spells neither.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskScrollDefaults {
    /// The default per-axis band.
    pub max_band: f64,
    /// The default decay time constant, in seconds.
    pub decay_seconds: f64,
}

/// The law's default knobs.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_reprojector_defaults() -> SlopDeskScrollDefaults {
    SlopDeskScrollDefaults {
        max_band: ScrollReprojector::DEFAULT_MAX_BAND,
        decay_seconds: ScrollReprojector::DEFAULT_DECAY_SECONDS,
    }
}

/// A reprojector at rest, with both knobs sanitised into the range the law will accept.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_reprojector_new(
    max_band: f64,
    decay_seconds: f64,
) -> SlopDeskScrollReprojector {
    SlopDeskScrollReprojector::of(&ScrollReprojector::new(max_band, decay_seconds))
}

/// Folds one scroll-velocity sample, in normalised units per second, with its phase.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_reprojector_note_velocity(
    reprojector: SlopDeskScrollReprojector,
    vx: f64,
    vy: f64,
    phase: u32,
) -> SlopDeskScrollReprojector {
    let mut inner = reprojector.inner();
    inner.note_velocity(vx, vy, phase_of(phase));
    SlopDeskScrollReprojector::of(&inner)
}

/// Integrates the velocity over the elapsed time — or decays a stopped scroll — and answers the
/// state alongside the offset the renderer should take.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_reprojector_advance(
    reprojector: SlopDeskScrollReprojector,
    elapsed_seconds: f64,
) -> SlopDeskScrollAdvance {
    let mut inner = reprojector.inner();
    let (x, y) = inner.advance(elapsed_seconds);
    SlopDeskScrollAdvance {
        reprojector: SlopDeskScrollReprojector::of(&inner),
        offset: SlopDeskScrollOffset { x, y },
    }
}

/// Resets the offset to exactly zero — the no-double-count reset a real decoded frame performs.
/// The velocity is preserved; the decay flag is not.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_reprojector_note_real_frame(
    reprojector: SlopDeskScrollReprojector,
) -> SlopDeskScrollReprojector {
    let mut inner = reprojector.inner();
    inner.note_real_frame();
    SlopDeskScrollReprojector::of(&inner)
}

/// Drops the offset AND the velocity, for a pane going idle or losing focus.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_reprojector_reset(
    reprojector: SlopDeskScrollReprojector,
) -> SlopDeskScrollReprojector {
    let mut inner = reprojector.inner();
    inner.reset();
    SlopDeskScrollReprojector::of(&inner)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the fixtures are exact binary fractions and the reset is exactly zero by rule"
    )]

    use super::{
        SLOPDESK_SCROLL_PHASE_ACTIVE, SLOPDESK_SCROLL_PHASE_ENDED, SLOPDESK_SCROLL_PHASE_MOMENTUM,
        SlopDeskScrollHint, slopdesk_scroll_hint_band, slopdesk_scroll_hint_measured,
        slopdesk_scroll_hint_velocity, slopdesk_scroll_phase_of_platform,
        slopdesk_scroll_reprojector_advance, slopdesk_scroll_reprojector_defaults,
        slopdesk_scroll_reprojector_new, slopdesk_scroll_reprojector_note_real_frame,
        slopdesk_scroll_reprojector_note_velocity, slopdesk_scroll_reprojector_reset,
    };

    #[test]
    fn the_platform_codes_collapse_to_the_three_the_law_folds() {
        assert_eq!(
            slopdesk_scroll_phase_of_platform(2, 0),
            SLOPDESK_SCROLL_PHASE_ACTIVE
        );
        assert_eq!(
            slopdesk_scroll_phase_of_platform(0, 2),
            SLOPDESK_SCROLL_PHASE_MOMENTUM
        );
        assert_eq!(
            slopdesk_scroll_phase_of_platform(4, 0),
            SLOPDESK_SCROLL_PHASE_ENDED
        );
        assert_eq!(
            slopdesk_scroll_phase_of_platform(0, 3),
            SLOPDESK_SCROLL_PHASE_ENDED
        );
    }

    #[test]
    fn a_measured_shift_crosses_out_and_comes_back_as_a_velocity() {
        let hint = slopdesk_scroll_hint_measured(48, 900, 100, 899, 960);
        assert_eq!(hint, SlopDeskScrollHint {
            dx: 0,
            dy: 500,
            band_top: 1042,
            band_bottom: 9375,
        });
        let sample = slopdesk_scroll_hint_velocity(hint, 60.0);
        assert_eq!(sample.vy, 3.0);
        assert_eq!(sample.phase, SLOPDESK_SCROLL_PHASE_ACTIVE);
        let band = slopdesk_scroll_hint_band(hint);
        assert!(band.present);
        assert_eq!(band.bottom, 0.9375);
    }

    #[test]
    fn an_absent_band_crosses_as_a_flag_rather_than_a_zero_span() {
        let still = slopdesk_scroll_hint_measured(48, 100, 0, 100, 960);
        assert_eq!(still.dy, 0, "an unconfident measurement is not a scroll");
        let band = slopdesk_scroll_hint_band(still);
        assert!(!band.present, "and it carries no band to mask with");
        assert_eq!(
            slopdesk_scroll_hint_velocity(still, 60.0).phase,
            SLOPDESK_SCROLL_PHASE_ENDED,
            "a still frame arms the decay"
        );
    }

    #[test]
    fn a_tracked_velocity_integrates_and_the_band_holds_it() {
        let defaults = slopdesk_scroll_reprojector_defaults();
        let mut state = slopdesk_scroll_reprojector_new(defaults.max_band, defaults.decay_seconds);
        state = slopdesk_scroll_reprojector_note_velocity(state, 0.0, 2.0, SLOPDESK_SCROLL_PHASE_ACTIVE);
        let step = slopdesk_scroll_reprojector_advance(state, 0.015_625);
        assert_eq!(step.offset.y, 0.031_25);
        assert_eq!(step.offset.x, 0.0);
        let far = slopdesk_scroll_reprojector_advance(step.reprojector, 1.0);
        assert_eq!(far.offset.y, defaults.max_band, "a flick never leaves the band");
    }

    #[test]
    fn a_real_frame_zeroes_the_offset_and_keeps_the_gesture_alive() {
        let defaults = slopdesk_scroll_reprojector_defaults();
        let mut state = slopdesk_scroll_reprojector_new(defaults.max_band, defaults.decay_seconds);
        state = slopdesk_scroll_reprojector_note_velocity(state, 1.0, 2.0, SLOPDESK_SCROLL_PHASE_ACTIVE);
        state = slopdesk_scroll_reprojector_advance(state, 0.01).reprojector;
        let reset = slopdesk_scroll_reprojector_note_real_frame(state);
        assert_eq!(reset.offset_x, 0.0);
        assert_eq!(reset.offset_y, 0.0);
        assert_eq!(reset.velocity_y, 2.0, "the gesture may still be in flight");
        let full = slopdesk_scroll_reprojector_reset(state);
        assert_eq!(full.velocity_y, 0.0, "but an idle pane drops the velocity too");
    }

    #[test]
    fn an_ended_scroll_decays_to_exact_rest_rather_than_asymptoting() {
        let defaults = slopdesk_scroll_reprojector_defaults();
        let mut state = slopdesk_scroll_reprojector_new(defaults.max_band, defaults.decay_seconds);
        state = slopdesk_scroll_reprojector_note_velocity(state, 0.0, 1.0, SLOPDESK_SCROLL_PHASE_ACTIVE);
        state = slopdesk_scroll_reprojector_advance(state, 0.05).reprojector;
        state = slopdesk_scroll_reprojector_note_velocity(state, 0.0, 0.0, SLOPDESK_SCROLL_PHASE_ENDED);
        assert!(state.decaying);
        for _ in 0..60 {
            state = slopdesk_scroll_reprojector_advance(state, 0.016).reprojector;
        }
        assert_eq!(state.offset_y, 0.0, "it settles, and settles exactly");
    }

    #[test]
    fn a_hostile_knob_cannot_widen_the_band_and_survives_the_round_trip() {
        let defaults = slopdesk_scroll_reprojector_defaults();
        let state = slopdesk_scroll_reprojector_new(f64::NAN, 99.0);
        assert_eq!(state.max_band, defaults.max_band, "a non-finite knob falls back");
        assert_eq!(state.decay_seconds, 2.0, "and an absurd one clamps");
        let idle = slopdesk_scroll_reprojector_advance(state, f64::NAN);
        assert_eq!(
            idle.reprojector, state,
            "a clock glitch is a zero-length tick, not a jump"
        );
    }
}
