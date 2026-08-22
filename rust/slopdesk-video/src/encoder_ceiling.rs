//! The hardware encoder's own quantiser ceiling: what the budget affords, and what its drops say.
//!
//! ## Two answers to one question, and why they are here together
//!
//! The encoder writes ONE `MaxAllowedFrameQP` per frame, and two independent laws decide it.
//!
//! The first is the BUDGET. A quantiser pinned sharp drops frames whenever the rate controller
//! cannot carry sharp motion at the offered budget — measured on hardware, 97 dropped frames in one
//! 18-second scroll at 6–16 Mbps on a 1080p60 session — while a quantiser pinned coarse blurs a
//! hard scroll on a link with bits to spare. So the ceiling FOLLOWS the budget's density in bits
//! per pixel per frame: sharp while the target carries sharp motion, relaxing to the
//! coarsen-rather- than-drop bound as it thins.
//!
//! The second is the CONTENT, and the budget cannot see it. A rich target on pathological content —
//! noise, video, a mandelbrot — offers 95–119 Mbps against a 30 Mbps budget, and no quantiser at
//! the sharp end can fit that, so the encoder drops instead: 209 dropped frames in 25 seconds,
//! which is the exact failure the budget law was written to remove. So the encoder watches its OWN
//! drops and carries a RELIEF above whatever the budget said, attacking within a few frames and
//! decaying back slowly, because coarse-but-moving beats sharp-but-missing and a sudden re-sharpen
//! is a pop.
//!
//! They compose as `min(hard_bound, budget_ceiling + relief)` at the call site, which is the only
//! place either number means anything.
//!
//! ## One ramp, not two
//!
//! [`qp_ceiling`] does not have a ramp of its own — it maps the density onto the band and hands the
//! interpolation to [`crate::adaptive_qp::adaptive_max_qp`], which already owns the linear
//! sharp-to-coarse ceiling ramp for the per-frame change fraction. The two laws read different
//! inputs in opposite directions and the ramp between them is the same arithmetic, which is exactly
//! the shape that drifts when it is written twice: a fused multiply-add on one side, an `f32`
//! intermediate on the other, and nothing in either test suite goes red.
//!
//! The mapping is `x = sharp_bpp - bpp` over `[0, sharp_bpp - coarse_bpp]`, which reverses the
//! direction and leaves the interpolation fraction bit-identical to the density form: subtracting
//! the zero low end is exact, so `t` is `(sharp_bpp - bpp) / (sharp_bpp - coarse_bpp)` either way.

use core::cmp::Ordering;

use crate::adaptive_qp::adaptive_max_qp;

/// The sharp end of the budget-adaptive ceiling.
///
/// One step coarser than the reference implementations pin (35), which keeps a little more
/// coarsening headroom before the relief has to do anything.
pub const SHARP_QP_CEILING: i32 = 38;

/// The density at or above which the sharp ceiling fits without drops, in bits per pixel per frame.
///
/// Hardware-measured: zero drops at or above this density under a 31 Mbps ceiling at 1080p60.
pub const SHARP_BPP: f64 = 0.14;

/// The density at or below which the ceiling is fully relaxed to the hard bound.
///
/// Hardware-measured: the drop-storm regime sat between this and [`SHARP_BPP`].
pub const COARSE_BPP: f64 = 0.07;

/// How far one dropped frame lifts the relief.
///
/// A storm reaches the full sharp-to-coarse span in about four frames, roughly 70 ms at 60 fps.
pub const ATTACK_STEP: i32 = 4;

/// How many consecutive clean encodes the relief holds at full height before it may decay.
///
/// About three seconds at 60 fps: long enough that a bursty regime does not re-sharpen into its own
/// next burst.
pub const HOLD_FRAMES: i32 = 180;

/// After the hold, one quantiser step comes off per this many clean encodes.
pub const DECAY_EVERY: i32 = 4;

/// The relief's own ceiling, which is the quantiser's maximum.
///
/// The relief is added to a ceiling that is already at least 1, so this bound is never reachable in
/// composition — it exists so a drop flood cannot walk the accumulator toward overflow.
pub const RELIEF_CAP: i32 = 51;

/// The band the budget's density is mapped onto: the two quantiser ends and the two knees.
///
/// One value rather than four arguments, for the reason a plane travels with its stride: a sharp
/// end read against the wrong knee is the whole failure this law exists to avoid, and a pair that
/// cannot be split cannot be mismatched at a call site.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CeilingBand {
    /// The sharp end, taken at or above `sharp_bpp`.
    pub sharp: i32,
    /// The coarse end, taken at or below `coarse_bpp`, and the answer to every refusal below.
    pub coarse: i32,
    /// The density at or above which the sharp end fits.
    pub sharp_bpp: f64,
    /// The density at or below which the ceiling is fully relaxed.
    pub coarse_bpp: f64,
}

impl Default for CeilingBand {
    /// The shipped operating point, with the hard bound as the coarse end.
    fn default() -> Self {
        Self {
            sharp: SHARP_QP_CEILING,
            coarse: RELIEF_CAP,
            sharp_bpp: SHARP_BPP,
            coarse_bpp: COARSE_BPP,
        }
    }
}

/// The quantiser ceiling a budget of `target_bps` affords on a `pixel_width` by `pixel_height`
/// picture at `fps`.
///
/// `band.sharp` at or above `band.sharp_bpp` density, `band.coarse` at or below `band.coarse_bpp`,
/// and the ramp between them. A degenerate picture, cadence or budget answers `band.coarse`, and so
/// does an inverted band or an inverted pair of knees: every uncertainty resolves toward coarsening
/// rather than toward a ceiling the encoder might have to drop a frame to honour.
///
/// Both ends are quantisers, so a value outside the byte range is a caller that has lost track of
/// what it is asking for — it answers the coarse end rather than saturating into a band nobody
/// chose.
#[must_use]
pub fn qp_ceiling(target_bps: i64, pixel_width: i64, pixel_height: i64, fps: i64, band: CeilingBand) -> i32 {
    if pixel_width <= 0 || pixel_height <= 0 || fps <= 0 || target_bps <= 0 {
        return band.coarse;
    }
    // An ORDERED comparison, so a non-finite knee is an inverted pair rather than a silent pass.
    if band.coarse < band.sharp || band.sharp_bpp.partial_cmp(&band.coarse_bpp) != Some(Ordering::Greater) {
        return band.coarse;
    }
    let (Ok(sharp_byte), Ok(coarse_byte)) = (u8::try_from(band.sharp), u8::try_from(band.coarse)) else {
        return band.coarse;
    };
    #[expect(
        clippy::cast_precision_loss,
        reason = "a picture's pixel rate is bounded by the capture geometry and the cadence, so it is exact \
                  in an f64 by many orders of magnitude"
    )]
    let pixel_rate = (pixel_width as f64) * (pixel_height as f64) * (fps as f64);
    #[expect(
        clippy::cast_precision_loss,
        reason = "a link budget in bits per second is exact in an f64 well past any rate a video encoder is \
                  configured at"
    )]
    let bpp = (target_bps as f64) / pixel_rate;
    // The reversal: a DENSE budget is the sharp end, where a small change fraction is on the other
    // law, so the distance BELOW the sharp knee is what rides the ramp.
    let distance = band.sharp_bpp - bpp;
    let span = band.sharp_bpp - band.coarse_bpp;
    i32::from(adaptive_max_qp(distance, sharp_byte, coarse_byte, 0.0, span))
}

/// The drop-feedback relief: how far above the budget's ceiling the encoder is currently running.
///
/// Attacks on any dropped frame and decays only after a hold, so a bursty regime keeps its relief
/// and a settled one re-sharpens a step at a time. A value, because its owner takes a copy out
/// under a lock, folds it and writes it back — the shape `docs/55` §4b calls a by-value crossing.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DropRelief {
    relief: i32,
    clean_frames: i32,
}

impl DropRelief {
    /// A relief that has seen nothing yet.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            relief: 0,
            clean_frames: 0,
        }
    }

    /// Rebuilds a relief from a carried pair.
    ///
    /// Both fields are sanitised into the range the fold can produce: a hostile or stale record has
    /// to land on a legal state, because a panic crossing the C boundary aborts the process.
    #[must_use]
    pub const fn restored(relief: i32, clean_frames: i32) -> Self {
        Self {
            relief: if relief < 0 {
                0
            } else if relief > RELIEF_CAP {
                RELIEF_CAP
            } else {
                relief
            },
            clean_frames: if clean_frames < 0 { 0 } else { clean_frames },
        }
    }

    /// The extra quantiser steps the caller composes above the budget-derived ceiling.
    #[must_use]
    pub const fn relief(&self) -> i32 {
        self.relief
    }

    /// How many consecutive clean encodes have been folded.
    #[must_use]
    pub const fn clean_frames(&self) -> i32 {
        self.clean_frames
    }

    /// Folds one encode tick and answers the current relief.
    ///
    /// `drops` is how many frames the encoder dropped since the last tick. A negative count is a
    /// caller that has lost its counter, and reads as none — never as a decay in reverse.
    pub const fn fold(&mut self, drops: i64) -> i32 {
        if drops > 0 {
            // Saturating in i64 before the clamp: a drop count large enough to overflow the step
            // multiplication is a broken counter, and the answer to it is the cap, not a wrap.
            let attacked = (self.relief as i64).saturating_add((ATTACK_STEP as i64).saturating_mul(drops));
            #[expect(
                clippy::cast_possible_truncation,
                reason = "the arm above it takes every value past the cap, and the cap is well inside an i32"
            )]
            {
                self.relief = if attacked > RELIEF_CAP as i64 {
                    RELIEF_CAP
                } else {
                    attacked as i32
                };
            }
            self.clean_frames = 0;
        } else {
            self.clean_frames = self.clean_frames.saturating_add(1);
            if self.clean_frames > HOLD_FRAMES && self.relief > 0 && self.clean_frames % DECAY_EVERY == 0 {
                self.relief -= 1;
            }
        }
        self.relief
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ATTACK_STEP, COARSE_BPP, CeilingBand, DECAY_EVERY, DropRelief, HOLD_FRAMES, RELIEF_CAP, SHARP_BPP,
        SHARP_QP_CEILING, qp_ceiling,
    };

    /// The shipped operating point: 1080p60 against the default band.
    fn ceiling(target_bps: i64) -> i32 {
        qp_ceiling(target_bps, 1920, 1080, 60, CeilingBand::default())
    }

    fn band(sharp: i32, coarse: i32, sharp_bpp: f64, coarse_bpp: f64) -> CeilingBand {
        CeilingBand {
            sharp,
            coarse,
            sharp_bpp,
            coarse_bpp,
        }
    }

    #[test]
    fn a_healthy_budget_is_sharp() {
        assert_eq!(ceiling(31_104_000), 38, "bpp 0.25, the shipped rate ceiling");
        assert_eq!(ceiling(17_418_240), 38, "bpp 0.14 exactly — the knee is sharp");
    }

    #[test]
    fn a_thin_budget_relaxes_all_the_way() {
        assert_eq!(
            ceiling(6_500_000),
            51,
            "bpp 0.052 — the measured drop-storm regime"
        );
        assert_eq!(ceiling(8_709_120), 51, "bpp 0.07 exactly — the knee is coarse");
        assert_eq!(ceiling(1_000_000), 51);
    }

    #[test]
    fn between_the_knees_it_ramps() {
        assert_eq!(ceiling(14_929_920), 42, "bpp 0.12");
        assert_eq!(ceiling(12_441_600), 45, "bpp 0.10");
    }

    #[test]
    fn a_thinner_budget_never_answers_sharper() {
        let mut previous = 0;
        for step in 0..=2000 {
            let answer = ceiling(31_104_000 - step * 15_000);
            assert!(answer >= previous, "the ceiling ran backwards at step {step}");
            previous = answer;
        }
    }

    /// The rounding ORDER is the one thing reusing the change-fraction ramp changes: the deleted
    /// Swift rounded the ramp and then added the sharp end, and this rounds their sum. Both round
    /// half away from zero and the sharp end is an exact integer, so they agree — swept across the
    /// whole band rather than argued about, because a disagreement would be one quantiser step at a
    /// knife edge and nothing downstream would report it.
    #[test]
    fn rounding_the_sum_agrees_with_rounding_the_ramp() {
        let pixel_rate = 1920.0 * 1080.0 * 60.0;
        for step in 0..=20_000_i64 {
            let target = 8_709_120 + step * 436;
            #[expect(
                clippy::cast_precision_loss,
                reason = "a swept budget in bits per second is exact in an f64"
            )]
            let bpp = (target as f64) / pixel_rate;
            if bpp <= COARSE_BPP || bpp >= SHARP_BPP {
                continue;
            }
            let t = (SHARP_BPP - bpp) / (SHARP_BPP - COARSE_BPP);
            let ramp = t * f64::from(RELIEF_CAP - SHARP_QP_CEILING);
            #[expect(
                clippy::cast_possible_truncation,
                reason = "the ramp is bounded by the span between two quantisers"
            )]
            let ramp_first = SHARP_QP_CEILING + (ramp.round() as i32);
            assert_eq!(
                ceiling(target),
                ramp_first,
                "the two rounding orders parted at {target}"
            );
        }
    }

    #[test]
    fn a_degenerate_configuration_relaxes() {
        let shipped = CeilingBand::default();
        assert_eq!(qp_ceiling(12_000_000, 0, 1080, 60, shipped), 51);
        assert_eq!(qp_ceiling(12_000_000, 1920, -1, 60, shipped), 51);
        assert_eq!(qp_ceiling(12_000_000, 1920, 1080, 0, shipped), 51);
        assert_eq!(qp_ceiling(0, 1920, 1080, 60, shipped), 51);
        assert_eq!(
            qp_ceiling(12_000_000, 1920, 1080, 60, band(38, 51, COARSE_BPP, SHARP_BPP)),
            51,
            "inverted knees"
        );
        assert_eq!(
            qp_ceiling(12_000_000, 1920, 1080, 60, band(51, 38, SHARP_BPP, COARSE_BPP)),
            38,
            "an inverted band answers the coarse end it was given"
        );
        assert_eq!(
            qp_ceiling(12_000_000, 1920, 1080, 60, band(-1, 51, SHARP_BPP, COARSE_BPP)),
            51,
            "a quantiser outside the byte range"
        );
        assert_eq!(
            qp_ceiling(12_000_000, 1920, 1080, 60, band(38, 51, f64::NAN, COARSE_BPP)),
            51,
            "a non-finite knee"
        );
    }

    #[test]
    fn a_pinned_ceiling_is_honoured_at_every_density() {
        for target in [1_000_000, 13_063_680, 31_104_000] {
            assert_eq!(
                qp_ceiling(target, 1920, 1080, 60, band(40, 40, SHARP_BPP, COARSE_BPP)),
                40
            );
        }
    }

    #[test]
    fn a_drop_attacks_at_once() {
        let mut relief = DropRelief::new();
        assert_eq!(relief.fold(1), ATTACK_STEP);
        assert_eq!(relief.fold(1), ATTACK_STEP * 2);
        let mut storm = DropRelief::new();
        for _ in 0..4 {
            storm.fold(1);
        }
        assert!(storm.relief() >= 13, "a storm must cross the whole span fast");
    }

    #[test]
    fn the_relief_saturates() {
        let mut relief = DropRelief::new();
        for _ in 0..100 {
            relief.fold(10);
        }
        assert_eq!(relief.relief(), RELIEF_CAP);
        assert_eq!(
            relief.fold(i64::MAX),
            RELIEF_CAP,
            "a broken counter is still the cap"
        );
    }

    #[test]
    fn nothing_decays_inside_the_hold() {
        let mut relief = DropRelief::new();
        relief.fold(1);
        for _ in 0..HOLD_FRAMES {
            relief.fold(0);
        }
        assert_eq!(relief.relief(), ATTACK_STEP);
    }

    #[test]
    fn it_decays_a_step_at_a_time_after_the_hold() {
        let mut relief = DropRelief::new();
        relief.fold(1);
        for _ in 0..(HOLD_FRAMES + ATTACK_STEP * DECAY_EVERY) {
            relief.fold(0);
        }
        assert_eq!(relief.relief(), 0);
    }

    #[test]
    fn a_drop_mid_decay_re_arms() {
        let mut relief = DropRelief::new();
        relief.fold(1);
        for _ in 0..(HOLD_FRAMES + DECAY_EVERY) {
            relief.fold(0);
        }
        assert_eq!(relief.relief(), ATTACK_STEP - 1, "one decay step landed");
        assert_eq!(relief.fold(1), ATTACK_STEP * 2 - 1);
        assert_eq!(relief.clean_frames(), 0, "the hold restarts on a new drop");
    }

    #[test]
    fn a_negative_drop_count_is_not_a_reverse_decay() {
        let mut relief = DropRelief::new();
        relief.fold(1);
        assert_eq!(relief.fold(-5), ATTACK_STEP, "reads as a clean tick");
        assert_eq!(relief.clean_frames(), 1);
    }

    #[test]
    fn a_carried_record_lands_on_a_legal_state() {
        assert_eq!(DropRelief::restored(-4, -9), DropRelief::new());
        assert_eq!(DropRelief::restored(900, 3).relief(), RELIEF_CAP);
        assert_eq!(DropRelief::restored(7, 11).clean_frames(), 11);
    }
}
