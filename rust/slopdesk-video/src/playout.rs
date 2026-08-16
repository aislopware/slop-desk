//! The adaptive playout-delay law: how much jitter buffer the client's pacer holds.
//!
//! A FIXED playout buffer is wrong across links — a clean LAN wastes latency it never needed, while
//! a jittery WAN underruns and stutters. This maps the live measured jitter to a target buffer of
//! `ordered_clamp(k·jitter + base, [floor, ceil])`, then steps toward it GROW-FAST / SHRINK-SLOW,
//! so a transient spike decays over several ticks instead of ratcheting the latency up for good.
//!
//! ## The FMA trap
//!
//! `k * jitter + base` is a SEPARATE multiply and add, never fused, so the low bits stay put. All
//! the arithmetic is in the SECONDS domain; the public [`step_ms`] entry keeps the caller's
//! milliseconds at the edges, where the knobs are configured.

use crate::geometry::ordered_clamp;

/// The coefficient on the measured jitter, slightly under 1: the RFC 3550 mean deviation
/// underestimates the peak, but `+ base` and the smoothing make `0.8` enough at the validated link.
pub const DEFAULT_K: f64 = 0.8;
/// The constant term (seconds) added before the clamp, so a near-zero-jitter cold start still seeds
/// a real buffer rather than presenting on arrival.
pub const DEFAULT_BASE_SECONDS: f64 = 0.004;
/// The minimum playout (seconds). It must stay above zero — a zero buffer exposes raw jitter.
pub const DEFAULT_FLOOR_SECONDS: f64 = 0.004;
/// The maximum playout (seconds), capping the latency a pathological link can add.
pub const DEFAULT_CEIL_SECONDS: f64 = 0.035;

/// The tunable shape of the playout law, in the seconds domain.
///
/// Built from the millisecond knobs with each clamped to a sane band, `ceil >= floor` guaranteed,
/// and a non-finite knob replaced by its default: the caller resolves environment knobs, so every
/// field here has already survived a string.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlayoutConfig {
    /// The coefficient on measured jitter, clamped to `0..=4`.
    pub k: f64,
    /// The constant term (seconds), clamped to `0..=0.05`.
    pub base_seconds: f64,
    /// The minimum playout (seconds), clamped to `0.001..=0.05`.
    pub floor_seconds: f64,
    /// The maximum playout (seconds), clamped to `0.001..=0.2` and never below the floor.
    pub ceil_seconds: f64,
}

impl Default for PlayoutConfig {
    fn default() -> Self {
        Self {
            k: DEFAULT_K,
            base_seconds: DEFAULT_BASE_SECONDS,
            floor_seconds: DEFAULT_FLOOR_SECONDS,
            ceil_seconds: DEFAULT_CEIL_SECONDS,
        }
    }
}

impl PlayoutConfig {
    /// Builds a config from the millisecond knobs, clamping each into its band.
    #[must_use]
    pub fn from_millis(k: f64, base_ms: f64, floor_ms: f64, ceil_ms: f64) -> Self {
        let floor = if floor_ms.is_finite() {
            ordered_clamp(floor_ms / 1000.0, 0.001, 0.05)
        } else {
            DEFAULT_FLOOR_SECONDS
        };
        let ceil_raw = if ceil_ms.is_finite() {
            ordered_clamp(ceil_ms / 1000.0, 0.001, 0.2)
        } else {
            DEFAULT_CEIL_SECONDS
        };
        Self {
            k: if k.is_finite() {
                ordered_clamp(k, 0.0, 4.0)
            } else {
                DEFAULT_K
            },
            base_seconds: if base_ms.is_finite() {
                ordered_clamp(base_ms / 1000.0, 0.0, 0.05)
            } else {
                DEFAULT_BASE_SECONDS
            },
            floor_seconds: floor,
            // The NaN-ignoring IEEE max; both operands are finite by here.
            ceil_seconds: ceil_raw.max(floor),
        }
    }

    /// The TARGET playout (seconds) for a measured jitter: `ordered_clamp(k·jitter + base, [floor,
    /// ceil])`.
    ///
    /// A non-finite or negative jitter falls back to the floor — a bad sample must never be able to
    /// inflate the buffer, which is the direction that cannot be undone quickly.
    #[must_use]
    pub fn target_seconds(&self, jitter_seconds: f64) -> f64 {
        if !jitter_seconds.is_finite() || jitter_seconds < 0.0 {
            return self.floor_seconds;
        }
        let scaled = self.k * jitter_seconds; // a SEPARATE multiply...
        let raw = scaled + self.base_seconds; // ...and a SEPARATE add
        ordered_clamp(raw, self.floor_seconds, self.ceil_seconds)
    }

    /// One hysteretic step toward the target (seconds): GROW immediately to a larger target, but
    /// SHRINK by at most `shrink_step_seconds` per call. A non-finite `prev` re-seeds at the floor.
    #[must_use]
    pub fn step_seconds(&self, jitter_seconds: f64, prev_seconds: f64, shrink_step_seconds: f64) -> f64 {
        let target = self.target_seconds(jitter_seconds);
        let prev = if prev_seconds.is_finite() {
            ordered_clamp(prev_seconds, self.floor_seconds, self.ceil_seconds)
        } else {
            self.floor_seconds
        };
        if target >= prev {
            return target; // grow fast, which also covers the cold start seeded at the floor
        }
        let step = if shrink_step_seconds.is_finite() {
            shrink_step_seconds.max(0.0)
        } else {
            0.0
        };
        (prev - step).max(target) // shrink slow
    }
}

/// One hysteretic step of the playout delay, in milliseconds.
///
/// Maps the live `jitter_seconds` to `ordered_clamp(k·jitter + base, [floor, ceil])` and steps
/// `prev_playout_ms` toward it — grow fast, shrink by at most `shrink_step_ms` per call. The units
/// are the caller's: jitter in seconds, everything else in milliseconds.
#[must_use]
pub fn step_ms(jitter_seconds: f64, prev_playout_ms: f64, shrink_step_ms: f64, config: PlayoutConfig) -> f64 {
    config.step_seconds(jitter_seconds, prev_playout_ms / 1000.0, shrink_step_ms / 1000.0) * 1000.0
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "these assertions are on values that were CLAMPED to a constant or passed through \
                  unchanged, so exact equality is the property under test; the arithmetic results are \
                  compared with a tolerance instead"
    )]

    use super::{DEFAULT_CEIL_SECONDS, DEFAULT_FLOOR_SECONDS, DEFAULT_K, PlayoutConfig, step_ms};

    /// The default config in the units the caller configures it in.
    fn defaults() -> PlayoutConfig {
        PlayoutConfig::from_millis(DEFAULT_K, 4.0, 4.0, 35.0)
    }

    #[test]
    fn the_target_is_the_measured_jitter_plus_the_base_between_the_bounds() {
        let config = defaults();
        // 0.8 * 0.010 + 0.004 = 0.012
        assert!((config.target_seconds(0.010) - 0.012).abs() < 1e-12);
        // Below the floor at zero jitter: the base alone is the floor.
        assert!((config.target_seconds(0.0) - DEFAULT_FLOOR_SECONDS).abs() < 1e-12);
        // Well past the ceiling.
        assert!((config.target_seconds(1.0) - DEFAULT_CEIL_SECONDS).abs() < 1e-12);
    }

    #[test]
    fn a_bad_jitter_sample_never_inflates_the_buffer() {
        let config = defaults();
        assert_eq!(config.target_seconds(f64::NAN), config.floor_seconds);
        assert_eq!(config.target_seconds(f64::INFINITY), config.floor_seconds);
        assert_eq!(config.target_seconds(-1.0), config.floor_seconds);
    }

    /// The asymmetry IS the policy: a spike is absorbed at once, and given back slowly.
    #[test]
    fn the_buffer_grows_at_once_and_shrinks_by_a_step() {
        let config = defaults();
        let spike = config.step_seconds(0.030, 0.005, 0.002);
        assert!((spike - 0.028).abs() < 1e-12, "grew straight to the target");
        // Back to a quiet link: the target is the floor, but only one step is given back per call.
        let first = config.step_seconds(0.0, spike, 0.002);
        assert!((first - 0.026).abs() < 1e-12);
        let second = config.step_seconds(0.0, first, 0.002);
        assert!((second - 0.024).abs() < 1e-12);
    }

    #[test]
    fn the_shrink_never_undershoots_the_target() {
        let config = defaults();
        // A step larger than the whole distance still lands exactly on the target.
        let stepped = config.step_seconds(0.0, 0.030, 1.0);
        assert!((stepped - config.floor_seconds).abs() < 1e-12);
        // A non-finite or negative step is no step at all: the buffer holds rather than jumping.
        assert!((config.step_seconds(0.0, 0.030, f64::NAN) - 0.030).abs() < 1e-12);
        assert!((config.step_seconds(0.0, 0.030, -5.0) - 0.030).abs() < 1e-12);
    }

    #[test]
    fn a_cold_start_seeds_at_the_floor() {
        let config = defaults();
        assert_eq!(config.step_seconds(0.0, f64::NAN, 0.002), config.floor_seconds);
        // A previous value from outside the band is pulled back into it before the comparison — so
        // an absurd 5 s buffer becomes the ceiling and then shrinks by one step, rather than
        // snapping straight down to the target.
        assert!((config.step_seconds(0.030, 5.0, 0.002) - 0.033).abs() < 1e-12);
    }

    #[test]
    fn every_knob_is_clamped_into_its_band_and_a_bad_one_takes_its_default() {
        let wild = PlayoutConfig::from_millis(99.0, 900.0, 900.0, 9000.0);
        assert_eq!(wild.k, 4.0);
        assert_eq!(wild.base_seconds, 0.05);
        assert_eq!(wild.floor_seconds, 0.05);
        assert_eq!(wild.ceil_seconds, 0.2);

        let broken = PlayoutConfig::from_millis(f64::NAN, f64::NAN, f64::NAN, f64::NAN);
        assert_eq!(broken, PlayoutConfig::default());

        // A ceiling under the floor is raised to it, so the clamp band never inverts.
        let inverted = PlayoutConfig::from_millis(0.8, 4.0, 40.0, 2.0);
        assert_eq!(inverted.floor_seconds, 0.04);
        assert_eq!(inverted.ceil_seconds, 0.04);
        assert_eq!(inverted.target_seconds(0.0), 0.04);
    }

    #[test]
    fn the_millisecond_entry_keeps_the_callers_units() {
        let config = defaults();
        // 0.8 * 0.010 + 0.004 = 0.012 s = 12 ms, grown to at once from a 5 ms buffer.
        assert!((step_ms(0.010, 5.0, 2.0, config) - 12.0).abs() < 1e-9);
        // …and given back 2 ms at a time.
        assert!((step_ms(0.0, 12.0, 2.0, config) - 10.0).abs() < 1e-9);
    }
}
