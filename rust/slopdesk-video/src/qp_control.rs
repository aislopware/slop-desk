//! The link-adaptive constant-QP law: an integer additive-increase, multiplicative-decrease driven
//! by the link's own congestion verdict.
//!
//! An encoder's average-bitrate mode banks unused budget while the screen is idle and then slams
//! the quantiser on the frames right after a burst — the idle-then-hard-scroll blur. Pinning a
//! CONSTANT quantiser per frame removes that clawback, and this controller keeps the constant
//! adaptive: congested coarsens fast, so frames shrink and fit the degraded link; clean sharpens
//! one step per interval.
//!
//! The quantiser is INVERSE quality, so the senses flip against a bitrate controller: congestion
//! RAISES it.

/// The sanitised bounds and step sizes.
///
/// Sanitising is not decoration: these arrive from the environment, and a hostile or fat-fingered
/// value must never invert the range or escape the encoder's legal quantiser span.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QpConfig {
    /// The sharpest — lowest — quantiser on a clean link.
    pub sharp: i32,
    /// The coarsest — highest — quantiser under sustained congestion.
    pub coarse: i32,
    /// The rise per congested report: coarsen fast.
    pub up_step: i32,
    /// Clean reports per one-step sharpen: ease back slowly.
    pub down_interval: i32,
}

impl Default for QpConfig {
    fn default() -> Self {
        Self {
            sharp: 26,
            coarse: 40,
            up_step: 3,
            down_interval: 4,
        }
    }
}

impl QpConfig {
    /// The legal quantiser span.
    pub const MIN_QP: i32 = 1;
    /// The coarsest quantiser the encoder accepts.
    pub const MAX_QP: i32 = 51;

    /// The config with every field forced into a shape the controller can honour: both quantisers
    /// inside the legal span, the coarse one never below the sharp one, and both steps at least
    /// one — a zero down-interval would sharpen on every clean report, and a zero up-step would
    /// leave congestion unanswered forever.
    #[must_use]
    pub fn sanitized(&self) -> Self {
        let sharp = self.sharp.clamp(Self::MIN_QP, Self::MAX_QP);
        let coarse = self.coarse.min(Self::MAX_QP).max(sharp);
        Self {
            sharp,
            coarse,
            up_step: if self.up_step > 1 { self.up_step } else { 1 },
            down_interval: if self.down_interval > 1 {
                self.down_interval
            } else {
                1
            },
        }
    }

    /// The operating point resolved from the texts of [`KEYS`], in that order.
    ///
    /// Every knob CLAMPS an out-of-band value to the nearest legal one, through
    /// [`clamped_int_from_env`], rather than rejecting it back to the default. That is deliberate
    /// and it is the opposite of the bitrate and cadence families
    /// ([`crate::fps_governor::FpsGovernorConfig::from_env`]): a quantiser is an ordinal on the
    /// encoder's fixed 1…51 scale, so `SLOPDESK_QP_SHARP=0` HAS a nearest legal value and it means
    /// what the operator was reaching for. A rate or a report count does not.
    ///
    /// The result is still fed through [`Self::sanitized`] by [`QpController::new`], because a
    /// per-knob clamp cannot see the pair rule — `sharp=40, coarse=10` is two legal values and one
    /// inverted range.
    #[must_use]
    pub fn from_env(values: &[Option<&str>; KEYS.len()]) -> Self {
        let defaults = Self::default();
        // BY NAME, not by position — the shape `crate::host_gates` settled: a positional read
        // agrees with a table that has drifted, and `sharp` and `coarse` are the two ends of one
        // range, so reading either into the other's slot inverts it silently.
        let at = |key: &str| -> Option<&str> {
            KEYS.iter()
                .position(|name| *name == key)
                .and_then(|index| values.get(index).copied().flatten())
        };
        Self {
            sharp: clamped_int_from_env(
                at("SLOPDESK_QP_SHARP"),
                defaults.sharp,
                Self::MIN_QP,
                Self::MAX_QP,
            ),
            coarse: clamped_int_from_env(
                at("SLOPDESK_QP_COARSE"),
                defaults.coarse,
                Self::MIN_QP,
                Self::MAX_QP,
            ),
            up_step: clamped_int_from_env(at("SLOPDESK_QP_UP_STEP"), defaults.up_step, 1, 50),
            down_interval: clamped_int_from_env(
                at("SLOPDESK_QP_DOWN_INTERVAL"),
                defaults.down_interval,
                1,
                10_000,
            ),
        }
    }
}

/// The environment keys, in the order [`QpConfig::from_env`] reads their values.
///
/// The caller resolves these names through the environment and then the settings overlay, and hands
/// the texts back positionally — the split [`crate::host_gates::KEYS`] argues in full.
pub const KEYS: [&str; 4] = [
    "SLOPDESK_QP_SHARP",
    "SLOPDESK_QP_COARSE",
    "SLOPDESK_QP_UP_STEP",
    "SLOPDESK_QP_DOWN_INTERVAL",
];

/// The controller: a sanitised config plus the current quantiser and the clean streak behind it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QpController {
    /// The sanitised knobs.
    config: QpConfig,
    /// The current constant quantiser.
    q: i32,
    /// The clean-report streak carried between steps.
    clean_streak: i32,
}

impl QpController {
    /// A controller seeded at `seed_q`, clamped into the sanitised range.
    #[must_use]
    pub fn new(config: QpConfig, seed_q: i32) -> Self {
        let config = config.sanitized();
        Self {
            q: seed_q.clamp(config.sharp, config.coarse),
            config,
            clean_streak: 0,
        }
    }

    /// A controller rebuilt from a state that already existed, streak and all.
    ///
    /// This is what a caller that keeps the controller BY VALUE needs — the host copies it out of
    /// its session, folds a report into the copy and writes it back, so the streak has to survive a
    /// round trip that `new` deliberately zeroes. The config is sanitised and the quantiser clamped
    /// on the way in, because a state that crossed a boundary is untrusted like any other input.
    #[must_use]
    pub fn restored(config: QpConfig, q: i32, clean_streak: i32) -> Self {
        let config = config.sanitized();
        Self {
            q: q.clamp(config.sharp, config.coarse),
            config,
            // `decide` resets the streak the moment it reaches the interval, so the interval itself
            // is not a state the fold can be in — restoring lands on a reachable one or below.
            clean_streak: clean_streak.clamp(0, config.down_interval - 1),
        }
    }

    /// The sanitised config this controller runs on.
    #[must_use]
    pub const fn config(&self) -> QpConfig {
        self.config
    }

    /// The clean-report streak behind the next sharpen — the other half of the state.
    #[must_use]
    pub const fn clean_streak(&self) -> i32 {
        self.clean_streak
    }

    /// The current constant quantiser.
    #[must_use]
    pub const fn q(&self) -> i32 {
        self.q
    }

    /// Folds one report's congestion verdict, returning the possibly-unchanged quantiser.
    ///
    /// Congested coarsens by a whole step toward the coarse bound; clean sharpens by one, but only
    /// once the streak reaches the interval, and the streak restarts either way.
    pub fn decide(&mut self, congested: bool) -> i32 {
        if congested {
            self.q = (self.q + self.config.up_step).min(self.config.coarse);
            self.clean_streak = 0;
        } else {
            self.clean_streak += 1;
            if self.clean_streak >= self.config.down_interval {
                self.q = (self.q - 1).max(self.config.sharp);
                self.clean_streak = 0;
            }
        }
        self.q
    }
}

/// Parses one of the integer quantiser knobs, CLAMPING an out-of-range value rather than rejecting
/// it, and falling back to `default` when the text is absent or not an integer.
///
/// Clamping here is deliberate and differs from the congestion controller's validate-then-default:
/// a quantiser knob has a meaningful nearest legal value, whereas a malformed rate does not.
#[must_use]
pub fn clamped_int_from_env(raw: Option<&str>, default: i32, lo: i32, hi: i32) -> i32 {
    raw.and_then(|raw| raw.parse::<i32>().ok())
        .map_or(default, |parsed| parsed.clamp(lo, hi))
}

#[cfg(test)]
mod tests {
    use super::{KEYS, QpConfig, QpController, clamped_int_from_env};

    /// The values array, keyed by NAME rather than by index — a positional fixture would agree with
    /// a [`KEYS`] table that had drifted.
    fn env(pairs: &[(&str, &'static str)]) -> [Option<&'static str>; KEYS.len()] {
        for (key, _) in pairs {
            assert!(KEYS.contains(key), "{key} is not a quantiser gate");
        }
        KEYS.map(|name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| *value)
        })
    }

    #[test]
    fn the_unset_quantiser_operating_point_is_the_tuned_one() {
        assert_eq!(QpConfig::from_env(&env(&[])), QpConfig::default());
    }

    #[test]
    fn every_quantiser_knob_is_reachable_under_its_own_name() {
        let config = QpConfig::from_env(&env(&[
            ("SLOPDESK_QP_SHARP", "20"),
            ("SLOPDESK_QP_COARSE", "44"),
            ("SLOPDESK_QP_UP_STEP", "5"),
            ("SLOPDESK_QP_DOWN_INTERVAL", "9"),
        ]));
        assert_eq!(config, QpConfig {
            sharp: 20,
            coarse: 44,
            up_step: 5,
            down_interval: 9,
        });
    }

    #[test]
    fn an_out_of_band_quantiser_knob_clamps_rather_than_falling_to_its_default() {
        let config = QpConfig::from_env(&env(&[
            ("SLOPDESK_QP_SHARP", "0"),
            ("SLOPDESK_QP_COARSE", "900"),
            ("SLOPDESK_QP_UP_STEP", "0"),
        ]));
        assert_eq!(config.sharp, QpConfig::MIN_QP, "a QP has a nearest legal value");
        assert_eq!(config.coarse, QpConfig::MAX_QP);
        assert_eq!(config.up_step, 1);
        assert_eq!(
            QpConfig::from_env(&env(&[("SLOPDESK_QP_SHARP", "sharp")])).sharp,
            QpConfig::default().sharp,
            "an unparseable value is still the default, not the floor"
        );
    }

    #[test]
    fn a_pair_the_per_knob_clamp_cannot_see_is_still_caught_by_sanitizing() {
        let inverted = QpConfig::from_env(&env(&[("SLOPDESK_QP_SHARP", "40"), ("SLOPDESK_QP_COARSE", "10")]));
        assert_eq!(inverted.sharp, 40, "each value is legal on its own");
        assert_eq!(inverted.coarse, 10);
        let sane = inverted.sanitized();
        assert!(
            sane.coarse >= sane.sharp,
            "the pair rule lives in `sanitized`, which is why `from_env` does not have to know it"
        );
    }

    #[test]
    fn congestion_coarsens_fast_and_clean_sharpens_slowly() {
        let mut controller = QpController::new(QpConfig::default(), 26);
        assert_eq!(controller.decide(true), 29, "a whole step per congested report");
        assert_eq!(controller.decide(false), 29);
        assert_eq!(controller.decide(false), 29);
        assert_eq!(controller.decide(false), 29);
        assert_eq!(controller.decide(false), 28, "one step per four clean reports");
    }

    #[test]
    fn the_streak_restarts_on_congestion() {
        let mut controller = QpController::new(QpConfig::default(), 30);
        controller.decide(false);
        controller.decide(false);
        controller.decide(false);
        assert_eq!(controller.decide(true), 33);
        // The three clean reports are gone: it takes a fresh four to sharpen.
        controller.decide(false);
        controller.decide(false);
        controller.decide(false);
        assert_eq!(controller.q(), 33);
        assert_eq!(controller.decide(false), 32);
    }

    #[test]
    fn both_bounds_hold_under_sustained_pressure() {
        let mut controller = QpController::new(QpConfig::default(), 26);
        for _ in 0..100 {
            controller.decide(true);
        }
        assert_eq!(controller.q(), 40, "never past the coarse bound");
        for _ in 0..1_000 {
            controller.decide(false);
        }
        assert_eq!(controller.q(), 26, "never past the sharp bound");
    }

    /// A hostile environment value must not be able to invert the range or escape the span.
    #[test]
    fn the_config_is_sanitised_before_it_can_do_damage() {
        let inverted = QpConfig {
            sharp: 40,
            coarse: 10,
            up_step: 0,
            down_interval: -5,
        };
        let sane = inverted.sanitized();
        assert_eq!(sane.sharp, 40);
        assert_eq!(
            sane.coarse, 40,
            "the coarse bound is lifted, never left below the sharp one"
        );
        assert_eq!(sane.up_step, 1);
        assert_eq!(sane.down_interval, 1);

        let out_of_span = QpConfig {
            sharp: -3,
            coarse: 900,
            up_step: 3,
            down_interval: 4,
        }
        .sanitized();
        assert_eq!(out_of_span.sharp, 1);
        assert_eq!(out_of_span.coarse, 51);
    }

    #[test]
    fn the_seed_is_clamped_into_the_sanitised_range() {
        assert_eq!(QpController::new(QpConfig::default(), 5).q(), 26);
        assert_eq!(QpController::new(QpConfig::default(), 99).q(), 40);
        assert_eq!(QpController::new(QpConfig::default(), 33).q(), 33);
    }

    #[test]
    fn a_degenerate_down_interval_sharpens_every_clean_report() {
        let config = QpConfig {
            down_interval: 1,
            ..QpConfig::default()
        };
        let mut controller = QpController::new(config, 30);
        assert_eq!(controller.decide(false), 29);
        assert_eq!(controller.decide(false), 28);
    }

    /// A by-value owner folds through a round trip, so the streak has to survive one.
    #[test]
    fn a_restored_controller_resumes_the_streak_it_was_given() {
        let config = QpConfig::default();
        let mut carried = QpController::new(config, 30);
        carried.decide(false);
        carried.decide(false);
        carried.decide(false);
        assert_eq!(carried.clean_streak(), 3);

        // Exactly what a boundary does: take the three numbers out, put them back, keep folding.
        let mut round_tripped = QpController::restored(carried.config(), carried.q(), carried.clean_streak());
        assert_eq!(round_tripped, carried, "the round trip is lossless");
        assert_eq!(
            round_tripped.decide(false),
            29,
            "the fourth clean report sharpens, because the streak came back"
        );
    }

    /// A state that crossed a boundary is untrusted: it cannot smuggle in an illegal quantiser or a
    /// streak that has already passed the interval.
    #[test]
    fn a_restored_state_is_clamped_like_any_other_input() {
        let hostile = QpController::restored(
            QpConfig {
                sharp: 40,
                coarse: 10,
                up_step: 0,
                down_interval: 0,
            },
            900,
            -7,
        );
        assert_eq!(hostile.config().coarse, 40, "the range cannot invert");
        assert_eq!(hostile.q(), 40);
        assert_eq!(hostile.clean_streak(), 0);
        assert_eq!(
            QpController::restored(QpConfig::default(), 30, 99).clean_streak(),
            3,
            "a streak is held at the last state the fold can actually be in"
        );
    }

    #[test]
    fn the_env_knob_clamps_rather_than_rejecting() {
        assert_eq!(clamped_int_from_env(Some("31"), 26, 1, 51), 31);
        assert_eq!(
            clamped_int_from_env(Some("900"), 26, 1, 51),
            51,
            "clamped, not defaulted"
        );
        assert_eq!(clamped_int_from_env(Some("0"), 26, 1, 51), 1);
        assert_eq!(
            clamped_int_from_env(Some("sharp"), 26, 1, 51),
            26,
            "unparsable defaults"
        );
        assert_eq!(clamped_int_from_env(None, 26, 1, 51), 26);
    }
}
