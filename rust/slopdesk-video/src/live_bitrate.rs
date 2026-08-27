//! Sizing the live encoder budget to the pixels actually being encoded.
//!
//! A flat megabit target was measured at one resolution and one scale. A 2× `HiDPI` virtual display
//! QUADRUPLES the encoded pixels while a flat budget stays put, and with both the hard data-rate
//! cap and the quantiser ceiling binding at once, a heavy scroll frame cannot fit — so the encoder
//! DROPS it. A dropped frame IS the stutter; the cure is enough bits for motion frames to fit.
//!
//! So the budget is derived from the encoded pixel throughput — area times frame rate — at a fixed
//! per-pixel density, and any window at any capture scale is provisioned proportionally. The
//! configured bitrate acts as a FLOOR, so an explicitly higher value is still honoured.

/// The default bits per pixel per frame.
///
/// This is the CEILING, not the wire rate: the congestion controller still cuts the live target on
/// loss and round trip, so a constrained link never sees these bits. It is hardware-calibrated as
/// the density that lets the budget-adaptive quantiser ceiling hold through a hard 1080p60 scroll
/// with zero encoder drops; at the previous, lower density the same scroll either blurred to the
/// maximum quantiser or dropped frames by the hundred.
///
/// Frame SIZE is the dominant smoothness lever, so a LOWER density shrinks motion frames — smoother
/// scroll, coarser only DURING motion, which reads as natural motion blur — while the crisp static
/// refresh restores sharp text the instant the screen goes still.
pub const DEFAULT_BITS_PER_PIXEL_PER_FRAME: f64 = 0.25;

/// The absolute lower bound, so a tiny window never starves the encoder.
pub const MINIMUM_BITRATE: i64 = 1_000_000;

/// The density knob's environment key.
///
/// A lone key rather than a table, and named here anyway: the RULE was already Rust's, but the
/// SPELLING was still only in Swift, which is one spelling too many — a caller that resolved
/// `SLOPDESK_BPP_PER_FRAME` and handed the text to [`bits_per_pixel_from_env`] would get the tuned
/// default forever and no error anywhere.
pub const BITS_PER_PIXEL_KEY: &str = "SLOPDESK_BPP";

/// Parses the density knob, which must be positive and no greater than one.
///
/// Anything else falls back to the default rather than being clamped, because a density outside
/// that range is a typo rather than an intent.
#[must_use]
pub fn bits_per_pixel_from_env(raw: Option<&str>) -> f64 {
    let Some(parsed) = raw.and_then(|raw| raw.parse::<f64>().ok()) else {
        return DEFAULT_BITS_PER_PIXEL_PER_FRAME;
    };
    if parsed > 0.0 && parsed <= 1.0 {
        parsed
    } else {
        DEFAULT_BITS_PER_PIXEL_PER_FRAME
    }
}

/// The resolution-aware target bitrate, in bits per second, for an encoder of this pixel size at
/// this frame rate.
///
/// Never below `floor` — the configured bitrate, so an explicit higher cap is honoured — and never
/// below [`MINIMUM_BITRATE`]. Degenerate dimensions and frame rates are clamped to one rather than
/// producing a zero budget.
#[must_use]
pub fn target_bitrate(
    pixel_width: i64,
    pixel_height: i64,
    fps: i64,
    floor: i64,
    bits_per_pixel_per_frame: f64,
) -> i64 {
    let px = pixel_width.max(1);
    let py = pixel_height.max(1);
    let rate = fps.max(1);
    // Separate multiplies, never fused: the product is a pinned quantity, and rounding is
    // half-away-from-zero on both sides of the port.
    #[expect(
        clippy::cast_precision_loss,
        reason = "a pixel count and a frame rate are far inside f64's exact integer range"
    )]
    let area = (px as f64) * (py as f64);
    #[expect(
        clippy::cast_precision_loss,
        reason = "a pixel count and a frame rate are far inside f64's exact integer range"
    )]
    let throughput = area * (rate as f64);
    let bits = throughput * bits_per_pixel_per_frame;
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the rounded budget of a real encoder is orders of magnitude inside i64"
    )]
    let resolution = bits.round() as i64;
    MINIMUM_BITRATE.max(floor).max(resolution)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the density assertions are on values the parser either passes through verbatim or \
                  replaces with the default — which is the property under test"
    )]

    use super::{DEFAULT_BITS_PER_PIXEL_PER_FRAME, MINIMUM_BITRATE, bits_per_pixel_from_env, target_bitrate};

    #[test]
    fn the_budget_scales_with_the_pixels_actually_encoded() {
        let full_hd = target_bitrate(1920, 1080, 60, 12_000_000, DEFAULT_BITS_PER_PIXEL_PER_FRAME);
        assert_eq!(full_hd, 31_104_000);
        // The HiDPI case the flat budget got wrong: four times the pixels, four times the bits.
        let hidpi = target_bitrate(3840, 2160, 60, 12_000_000, DEFAULT_BITS_PER_PIXEL_PER_FRAME);
        assert_eq!(hidpi, full_hd * 4);
    }

    #[test]
    fn an_explicitly_higher_configured_bitrate_is_honoured() {
        let floor = 200_000_000;
        assert_eq!(
            target_bitrate(1920, 1080, 60, floor, DEFAULT_BITS_PER_PIXEL_PER_FRAME),
            floor,
        );
    }

    #[test]
    fn a_tiny_window_never_starves_the_encoder() {
        assert_eq!(
            target_bitrate(16, 16, 1, 0, DEFAULT_BITS_PER_PIXEL_PER_FRAME),
            MINIMUM_BITRATE
        );
    }

    #[test]
    fn degenerate_dimensions_clamp_rather_than_zeroing_the_budget() {
        assert_eq!(
            target_bitrate(0, -100, 0, 0, DEFAULT_BITS_PER_PIXEL_PER_FRAME),
            MINIMUM_BITRATE
        );
    }

    #[test]
    fn the_density_knob_falls_back_outside_its_range() {
        assert_eq!(bits_per_pixel_from_env(Some("0.15")), 0.15);
        assert_eq!(
            bits_per_pixel_from_env(Some("1")),
            1.0,
            "the top of the range is allowed"
        );
        assert_eq!(
            bits_per_pixel_from_env(Some("0")),
            DEFAULT_BITS_PER_PIXEL_PER_FRAME
        );
        assert_eq!(
            bits_per_pixel_from_env(Some("-1")),
            DEFAULT_BITS_PER_PIXEL_PER_FRAME
        );
        assert_eq!(
            bits_per_pixel_from_env(Some("4")),
            DEFAULT_BITS_PER_PIXEL_PER_FRAME
        );
        assert_eq!(
            bits_per_pixel_from_env(Some("dense")),
            DEFAULT_BITS_PER_PIXEL_PER_FRAME
        );
        assert_eq!(bits_per_pixel_from_env(None), DEFAULT_BITS_PER_PIXEL_PER_FRAME);
    }
}
