//! Resolution-aware live-bitrate policy for the HEVC encoder — a port of Swift
//! `LiveBitratePolicy`.
//!
//! Sizes the live budget to the ACTUAL encoded pixel throughput (area × fps) at a fixed
//! bits-per-pixel-per-frame density, so a window at any capture scale is provisioned
//! proportionally — a 2× `HiDPI` window quadruples the encoded pixels and therefore the budget,
//! instead of starving motion frames at a flat 1080p-tuned cap (which made `VideoToolbox` drop
//! frames → scroll stutter). The configured `--bitrate` acts as a floor.
//!
//! Pure integer/float arithmetic. The env knob is resolved through the pure
//! [`bits_per_pixel_per_frame`] so the math itself stays deterministic and testable, mirroring
//! the [`crate::recovery_policy`] env pattern.

/// The default bits-per-pixel-per-frame density (≈18.7 Mbps at 1080p60, ≈45 Mbps at a
/// 2816×1778@60 `HiDPI` window). Used when `AISLOPDESK_BPP` is absent or out of range.
pub const DEFAULT_BITS_PER_PIXEL_PER_FRAME: f64 = 0.15;

/// Absolute lower bound so a tiny window never starves the encoder (matches `VideoEncoder`'s
/// own clamp). Swift `Int`, i.e. `i64` on the platforms this runs on.
pub const MINIMUM_BITRATE: i64 = 1_000_000;

/// Resolves the bits-per-pixel-per-frame density from an `AISLOPDESK_BPP` value.
///
/// Accepts a
/// finite value in `(0, 1]`; anything else (absent, unparsable, ≤0, >1, NaN, ∞) yields
/// [`DEFAULT_BITS_PER_PIXEL_PER_FRAME`].
///
/// Deviation from Swift, identical in spirit to [`crate::recovery_policy::escalation_floor_seconds`]:
/// Swift's `Double(String)` accepts C hex-float notation (e.g. `"0x1.0p-3"`), which Rust's
/// `str::parse::<f64>` rejects → falls back to the default. No operator writes a fractional
/// density knob in hex-float, so the only realistic inputs (decimals) parse identically.
#[must_use]
pub fn bits_per_pixel_per_frame(env_value: Option<&str>) -> f64 {
    match env_value.and_then(|s| s.parse::<f64>().ok()) {
        Some(v) if v.is_finite() && v > 0.0 && v <= 1.0 => v,
        _ => DEFAULT_BITS_PER_PIXEL_PER_FRAME,
    }
}

/// Resolves the density from the live process environment (`AISLOPDESK_BPP`).
#[must_use]
pub fn default_bits_per_pixel_per_frame() -> f64 {
    bits_per_pixel_per_frame(std::env::var("AISLOPDESK_BPP").ok().as_deref())
}

/// Resolution-aware target bitrate (bits/sec) for an encoder of `pixel_width × pixel_height`
/// at `fps`, at the given `bits_per_pixel` density.
///
/// Never below `floor` (the configured
/// `--bitrate`, so an explicit higher cap is honoured) and never below [`MINIMUM_BITRATE`].
/// Degenerate (zero/negative) dimensions and fps are clamped to 1.
#[must_use]
pub fn target_bitrate(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel: f64,
) -> i64 {
    let px = pixel_width.max(1);
    let py = pixel_height.max(1);
    let rate = fps.max(1);
    let bits = (px as f64) * (py as f64) * (rate as f64) * bits_per_pixel;
    // Bounded by construction (pixel throughput × a sub-unit density), so the rounded value
    // is a finite count of bits/sec well inside i64; asserted in debug, saturating in release.
    debug_assert!(bits.is_finite() && bits.round() <= i64::MAX as f64);
    let resolution = bits.round() as i64;
    MINIMUM_BITRATE.max(floor).max(resolution)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BPP: f64 = DEFAULT_BITS_PER_PIXEL_PER_FRAME;

    #[test]
    fn standard_1080p_scales_above_floor() {
        assert_eq!(target_bitrate(1920, 1080, 60, 12_000_000, BPP), 18_662_400);
    }

    #[test]
    fn two_x_hidpi_window_gets_full_budget() {
        assert_eq!(target_bitrate(2816, 1778, 60, 12_000_000, BPP), 45_061_632);
    }

    #[test]
    fn quadruples_with_two_x_scale() {
        let one_x = target_bitrate(1408, 889, 60, 0, BPP);
        let two_x = target_bitrate(2816, 1778, 60, 0, BPP);
        assert_eq!(two_x, one_x * 4);
    }

    #[test]
    fn floor_honoured_for_small_window() {
        assert_eq!(target_bitrate(320, 240, 60, 12_000_000, BPP), 12_000_000);
    }

    #[test]
    fn explicit_higher_floor_wins() {
        assert_eq!(target_bitrate(1920, 1080, 60, 60_000_000, BPP), 60_000_000);
    }

    #[test]
    fn minimum_bitrate_floor() {
        assert_eq!(target_bitrate(64, 64, 60, 0, BPP), MINIMUM_BITRATE);
    }

    #[test]
    fn degenerate_inputs_clamp_safely() {
        assert_eq!(target_bitrate(0, -10, 0, 0, BPP), MINIMUM_BITRATE);
    }

    #[test]
    fn fps_scales_linearly() {
        let at_60 = target_bitrate(3840, 2160, 60, 0, BPP);
        let at_30 = target_bitrate(3840, 2160, 30, 0, BPP);
        assert_eq!(at_60, at_30 * 2);
    }

    #[test]
    fn bpp_env_resolution() {
        assert_eq!(bits_per_pixel_per_frame(None), 0.15);
        assert_eq!(bits_per_pixel_per_frame(Some("garbage")), 0.15);
        assert_eq!(bits_per_pixel_per_frame(Some("0")), 0.15); // not > 0
        assert_eq!(bits_per_pixel_per_frame(Some("1.5")), 0.15); // > 1.0
        assert_eq!(bits_per_pixel_per_frame(Some("inf")), 0.15);
        assert_eq!(bits_per_pixel_per_frame(Some("0.25")), 0.25);
        assert_eq!(bits_per_pixel_per_frame(Some("1.0")), 1.0);
        // INTENTIONAL deviation (documented): hex-float falls back to the default.
        assert_eq!(bits_per_pixel_per_frame(Some("0x1.0p-3")), 0.15);
    }
}
