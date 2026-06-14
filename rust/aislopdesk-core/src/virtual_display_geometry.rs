//! Pure point<->pixel<->millimeter arithmetic + display-placement / chip-capability
//! math for a `HiDPI` virtual display.
//!
//! The canonical virtual-display geometry + planner logic. The macOS host shell calls it
//! over the C ABI (`RustVideoHostFFI.vd*`) from its VD-creation path.
//!
//! No CoreGraphics, no IPC, no private API: just the math that decides the VD's POINT
//! mode size, the PIXEL framebuffer, `sizeInMillimeters` (target PPI), global origin,
//! per-chip pixel ceiling, and advertised refresh-rate modes. The `golden_parity`
//! integration test pins these outputs against the frozen corpus (float outputs compared
//! as IEEE bit patterns; integer/bool outputs compared exactly).
//!
//! The `HiDPI` rule (from the `CGVirtualDisplay` research / `FreeDisplay` / force-hidpi /
//! Chromium): mode width/height are POINTS; `maxPixelsWide/High = points × scale`;
//! `settings.hiDPI = 1` makes the OS back the point grid with `scale`× pixels. So a
//! 1920×1080-POINT mode with `maxPixels = 3840×2160` and `hiDPI = 1` is a true Retina 2×
//! display.

use crate::geometry::{VideoPoint, VideoRect, VideoSize};

/// A virtual-display geometry value (reached from the host shell over the C ABI).
///
/// Swift `Int` is 64-bit on the targets, so all integer fields are `i64` to preserve
/// the same overflow domain for `point_width * scale`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VirtualDisplayGeometry {
    /// Logical (point) resolution width — what the window "sees".
    pub point_width: i64,
    /// Logical (point) resolution height.
    pub point_height: i64,
    /// Backing pixel scale (2 = Retina 2x).
    pub scale: i64,
    /// Per-chip maximum horizontal framebuffer pixels.
    pub max_horizontal_pixels: i64,
}

impl VirtualDisplayGeometry {
    /// Swift init default for `scale`.
    pub const DEFAULT_SCALE: i64 = 2;
    /// Swift init default for `maxHorizontalPixels`.
    pub const DEFAULT_MAX_HORIZONTAL_PIXELS: i64 = 7680;
    /// Swift `sizeInMillimeters` default `targetPPI = 163`.
    pub const DEFAULT_TARGET_PPI: f64 = 163.0;

    /// Builds a geometry, clamping every field to a minimum of 1 via `max(1, …)`.
    ///
    /// The host shell's FFI wrapper exposes `scale` and `maxHorizontalPixels` as default
    /// arguments ([`Self::DEFAULT_SCALE`] / [`Self::DEFAULT_MAX_HORIZONTAL_PIXELS`]).
    #[must_use]
    pub fn new(
        point_width: i64,
        point_height: i64,
        scale: i64,
        max_horizontal_pixels: i64,
    ) -> Self {
        Self {
            point_width: point_width.max(1),
            point_height: point_height.max(1),
            scale: scale.max(1),
            max_horizontal_pixels: max_horizontal_pixels.max(1),
        }
    }

    /// Backing framebuffer width in pixels (`points * scale`).
    #[must_use]
    pub const fn pixel_width(&self) -> i64 {
        self.point_width * self.scale
    }

    /// Backing framebuffer height in pixels (`points * scale`).
    #[must_use]
    pub const fn pixel_height(&self) -> i64 {
        self.point_height * self.scale
    }

    /// True when the backing framebuffer would exceed the chip's horizontal pixel
    /// limit (STRICT `>`, so an exact-fit `pixel_width == max_horizontal_pixels` is OK).
    ///
    /// The caller must NOT create the VD in that case (it would silently fail —
    /// `applySettings:` returns YES but the displayID stays 0) and should fall back to
    /// 1× capture.
    #[must_use]
    pub const fn exceeds_pixel_limit(&self) -> bool {
        self.pixel_width() > self.max_horizontal_pixels
    }

    /// Physical size in millimeters for `target_ppi`, computed from the PIXEL dims.
    /// `1 inch = 25.4 mm`. `target_ppi` is clamped to `>= 1` exactly as Swift's
    /// `max(1, targetPPI)`. Call with [`Self::DEFAULT_TARGET_PPI`] to reproduce the
    /// Swift default argument.
    #[must_use]
    pub fn size_in_millimeters(&self, target_ppi: f64) -> VideoSize {
        // Swift `max(1.0, targetPPI)` == the free `max`'s `y >= x ? y : x` with x = 1.0,
        // i.e. `target_ppi >= 1.0 ? target_ppi : 1.0`. The explicit ternary (rather than
        // `1.0_f64.max(target_ppi)`) propagates NaN → 1.0 (unlike `f64::max`); the Swift
        // shell uses the same semantics.
        let ppi = if target_ppi >= 1.0 { target_ppi } else { 1.0 };
        // PRESERVE op order: `Double(pixel) / ppi * 25.4` (left-to-right) for bit parity.
        VideoSize::new(
            self.pixel_width() as f64 / ppi * 25.4,
            self.pixel_height() as f64 / ppi * 25.4,
        )
    }
}

// ----- VD planner logic (a stateless namespace; the host shell calls it over the C ABI). -----
// Follows the crate convention of free functions for stateless namespaces
// (cf. `nal_unit::join`, `coordinate_mapping::window_point`, `mux_header::encode`).

/// The canonical `VirtualDisplayPlanner.originToRight(of:)`: the VD's global origin, flush to
/// the RIGHT of the rightmost existing display, at `y = 0`. Empty input -> `(0, 0)`.
///
/// Placing the VD past every real display guarantees it never overlaps one — macOS
/// resolves an overlap by reflowing displays, which would corrupt the user's real
/// multi-monitor arrangement. On a single-display host the rightmost edge IS the main
/// display's width, so this reduces to the historical `(main_width, 0)`. `existing_displays`
/// are the online displays' global bounds. Uses [`VideoRect::std_max_x`] (`CGRect.maxX`
/// = standardized right edge).
#[must_use]
pub fn origin_to_right(existing_displays: &[VideoRect]) -> VideoPoint {
    // Swift `existingDisplays.map(\.maxX).max() ?? 0`. Reproduce `Sequence.max()`:
    // seed with the first element, update only on STRICT `<` (ties keep the earlier),
    // empty -> None -> `?? 0` -> 0.0.
    let max_x = existing_displays
        .iter()
        .map(VideoRect::std_max_x)
        .fold(None, |acc: Option<f64>, v| {
            acc.map_or(Some(v), |a| Some(if a < v { v } else { a }))
        })
        .unwrap_or(0.0);
    VideoPoint::new(max_x, 0.0)
}

/// The canonical `VirtualDisplayPlanner.chipPixelLimit(cpuBrand:)`: the `CGVirtualDisplay` max
/// horizontal framebuffer pixels for the running chip, from its `machdep.cpu.brand_string`.
///
/// A Pro/Max/Ultra die has the larger display-pipe budget (7680); a base "Apple M…" die
/// is 6144. Intel / unknown -> 7680 (permissive — an over-budget create still fails safe
/// via the `displayID == 0` guard). Branch ORDER matters: pro/max/ultra are tested BEFORE
/// "apple m", so e.g. "Apple M1 Max" -> 7680, not 6144.
#[must_use]
pub fn chip_pixel_limit(cpu_brand: &str) -> i64 {
    // Unicode lowercasing; for ASCII cpu-brand strings (all real inputs) this is
    // byte-identical to Swift `String.lowercased()`. `.contains` is substring matching.
    let s = cpu_brand.to_lowercase();
    if s.contains("pro") || s.contains("max") || s.contains("ultra") {
        7680
    } else if s.contains("apple m") {
        // plain base M-series (M1/M2/M3/M4…)
        6144
    } else {
        7680
    }
}

/// The canonical `VirtualDisplayPlanner.refreshRates(fps:)`: always `[60, 30]`, plus `fps`
/// when `fps > 60`; deduped + sorted DESCENDING. Returned as `f64` (Swift `[Double]`).
///
/// `WindowServer` composites a VD-parked window at most at the VD's refresh, so a window
/// at `--fps 90` needs a `>= 90 Hz` mode or capture is silently capped at 60.
///
/// # Panics
///
/// Panics only if a refresh rate is NaN, which is unreachable here: every rate (`60.0`,
/// `30.0`, and `fps as f64` from a finite `i64`) is finite, so `partial_cmp` never returns
/// `None`.
#[must_use]
pub fn refresh_rates(fps: i64) -> Vec<f64> {
    let mut rates = vec![60.0_f64, 30.0];
    if fps > 60 {
        rates.push(fps as f64);
    }
    // Swift `Array(Set(rates)).sorted(by: >)`. The construction can never produce a
    // duplicate, so `dedup` is a no-op, but it mirrors the `Set`. All values finite.
    rates.sort_by(|a, b| b.partial_cmp(a).expect("refresh rates are finite"));
    rates.dedup();
    rates
}

#[cfg(test)]
mod tests {
    use super::*;

    // ----- VirtualDisplayGeometry cases -----

    // 2× HiDPI: a 1920×1080-POINT display is backed by 3840×2160 PIXELS.
    #[test]
    fn two_x_backing_pixels() {
        let g = VirtualDisplayGeometry::new(
            1920,
            1080,
            2,
            VirtualDisplayGeometry::DEFAULT_MAX_HORIZONTAL_PIXELS,
        );
        assert_eq!(g.pixel_width(), 3840);
        assert_eq!(g.pixel_height(), 2160);
        assert!(!g.exceeds_pixel_limit(), "3840 < 7680 chip limit");
    }

    // 1× (scale 1): pixels == points (the fallback / non-HiDPI case).
    #[test]
    fn one_x_backing() {
        let g = VirtualDisplayGeometry::new(
            1440,
            900,
            1,
            VirtualDisplayGeometry::DEFAULT_MAX_HORIZONTAL_PIXELS,
        );
        assert_eq!(g.pixel_width(), 1440);
        assert_eq!(g.pixel_height(), 900);
    }

    // The chip horizontal pixel limit gates oversized framebuffers (default 7680 + base-M 6144).
    #[test]
    fn exceeds_pixel_limit_strict() {
        // 3840 points × 2 = 7680 px → exactly the limit, NOT exceeding (strict `>`).
        assert!(!VirtualDisplayGeometry::new(3840, 2160, 2, 7680).exceeds_pixel_limit());
        // 3841 points × 2 = 7682 px → over the limit.
        assert!(VirtualDisplayGeometry::new(3841, 2160, 2, 7680).exceeds_pixel_limit());
        // Base-M chip limit 6144: 3072×2 = 6144 ok; 3200×2 = 6400 over.
        assert!(!VirtualDisplayGeometry::new(3072, 1920, 2, 6144).exceeds_pixel_limit());
        assert!(VirtualDisplayGeometry::new(3200, 1800, 2, 6144).exceeds_pixel_limit());
        // 6144 boundary, exact fit and +1 px over.
        assert!(!VirtualDisplayGeometry::new(3072, 1080, 2, 6144).exceeds_pixel_limit());
        assert!(VirtualDisplayGeometry::new(3073, 1080, 2, 6144).exceeds_pixel_limit());
    }

    // sizeInMillimeters derives from the PIXEL dims at the target PPI.
    #[test]
    fn size_in_millimeters() {
        let g = VirtualDisplayGeometry::new(1920, 1080, 2, 7680);
        let mm = g.size_in_millimeters(VirtualDisplayGeometry::DEFAULT_TARGET_PPI);
        // Identical op order → bit-exact with the reference expression.
        assert_eq!(mm.width, 3840.0 / 163.0 * 25.4);
        assert_eq!(mm.height, 2160.0 / 163.0 * 25.4);
        // sanity: ~598.5 mm wide.
        assert!((mm.width - 598.5).abs() < 1.0);
    }

    // Degenerate inputs are clamped to ≥1 (never zero/negative → never div-by-zero/bad descriptor).
    #[test]
    fn degenerate_inputs_clamped() {
        let g = VirtualDisplayGeometry::new(0, -5, 0, 0);
        assert_eq!(g.point_width, 1);
        assert_eq!(g.point_height, 1);
        assert_eq!(g.scale, 1);
        assert_eq!(g.max_horizontal_pixels, 1);
        assert_eq!(g.pixel_width(), 1);
        assert_eq!(g.pixel_height(), 1);
        // 1 > 1 is false → exact fit, not exceeding.
        assert!(!g.exceeds_pixel_limit());
    }

    // ----- size_in_millimeters PPI clamp edge cases -----

    #[test]
    fn ppi_clamp_zero_negative_and_one_all_yield_one() {
        let g = VirtualDisplayGeometry::new(1920, 1080, 2, 7680);
        let expected = g.pixel_width() as f64 / 1.0 * 25.4;
        assert_eq!(g.size_in_millimeters(0.0).width, expected);
        assert_eq!(g.size_in_millimeters(-10.0).width, expected);
        assert_eq!(g.size_in_millimeters(1.0).width, expected);
    }

    #[test]
    fn ppi_clamp_nan_yields_one_in_this_call_order() {
        let g = VirtualDisplayGeometry::new(1920, 1080, 2, 7680);
        // NaN >= 1.0 is false → ppi = 1.0, so the result is finite; the Swift shell matches this.
        let mm = g.size_in_millimeters(f64::NAN);
        let expected = g.pixel_width() as f64 / 1.0 * 25.4;
        assert!(mm.width.is_finite());
        assert_eq!(mm.width, expected);
    }

    #[test]
    fn ppi_normal_values_pass_through() {
        let g = VirtualDisplayGeometry::new(2560, 1440, 2, 7680);
        // hi-PPI 220, lo-PPI 96 — both > 1, untouched.
        assert_eq!(
            g.size_in_millimeters(220.0).width,
            g.pixel_width() as f64 / 220.0 * 25.4
        );
        assert_eq!(
            g.size_in_millimeters(96.0).height,
            g.pixel_height() as f64 / 96.0 * 25.4
        );
    }

    // ----- VirtualDisplayPlanner.originToRight cases -----

    // Single display: the VD lands flush to the right of it (the historical (mainWidth, 0)).
    #[test]
    fn origin_to_right_single_display() {
        let o = origin_to_right(&[VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0)]);
        assert_eq!(o, VideoPoint::new(1920.0, 0.0));
    }

    // Multi-display: the VD lands past the RIGHTMOST edge.
    #[test]
    fn origin_to_right_multi_display() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),    // main
            VideoRect::xywh(1920.0, 0.0, 2560.0, 1440.0), // secondary to the right
        ];
        // rightmost maxX = 1920 + 2560 = 4480.
        assert_eq!(origin_to_right(&displays), VideoPoint::new(4480.0, 0.0));
    }

    // No displays (degenerate): origin (0,0).
    #[test]
    fn origin_to_right_empty() {
        assert_eq!(origin_to_right(&[]), VideoPoint::new(0.0, 0.0));
    }

    // A display LEFT of the origin (negative X) still resolves the rightmost edge correctly.
    #[test]
    fn origin_to_right_with_negative_display() {
        let displays = [
            VideoRect::xywh(-1440.0, 0.0, 1440.0, 900.0), // to the LEFT of main
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),    // main
        ];
        assert_eq!(origin_to_right(&displays), VideoPoint::new(1920.0, 0.0));
    }

    // The rightmost display is NOT the last array element → proves we take max(maxX), not last.maxX.
    #[test]
    fn origin_to_right_rightmost_not_last() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),    // main
            VideoRect::xywh(5000.0, 0.0, 1000.0, 1080.0), // rightmost (maxX 6000), but not last
            VideoRect::xywh(1920.0, 0.0, 800.0, 1080.0),  // last element (maxX 2720)
        ];
        assert_eq!(origin_to_right(&displays), VideoPoint::new(6000.0, 0.0));
    }

    // y of the result is ALWAYS 0 regardless of input y; only maxX participates.
    #[test]
    fn origin_to_right_ignores_y_offsets() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
            VideoRect::xywh(1920.0, -300.0, 1920.0, 1080.0),
        ];
        assert_eq!(origin_to_right(&displays), VideoPoint::new(3840.0, 0.0));
    }

    // A negative-WIDTH rect must use standardized maxX: rect(x:1000,w:-200) has maxX = 1000.
    #[test]
    fn origin_to_right_negative_width_standardized() {
        let displays = [
            VideoRect::xywh(1000.0, 0.0, -200.0, 1080.0), // std maxX = 1000 (not 800)
            VideoRect::xywh(0.0, 0.0, 500.0, 500.0),
        ];
        assert_eq!(origin_to_right(&displays), VideoPoint::new(1000.0, 0.0));
    }

    // Fractional widths exercise f64 exactly.
    #[test]
    fn origin_to_right_fractional_width() {
        let displays = [VideoRect::xywh(0.0, 0.0, 1512.5, 982.25)];
        assert_eq!(origin_to_right(&displays), VideoPoint::new(1512.5, 0.0));
    }

    // ----- VirtualDisplayPlanner.chipPixelLimit cases -----

    #[test]
    fn chip_pixel_limit_base_pro_max_ultra() {
        assert_eq!(chip_pixel_limit("Apple M1"), 6144);
        assert_eq!(chip_pixel_limit("Apple M2"), 6144);
        assert_eq!(chip_pixel_limit("Apple M3"), 6144); // base M3 is 6144, NOT 7680
        assert_eq!(chip_pixel_limit("Apple M4"), 6144); // base M4 is 6144
        assert_eq!(chip_pixel_limit("Apple M2 Pro"), 7680);
        assert_eq!(chip_pixel_limit("Apple M3 Max"), 7680);
        assert_eq!(chip_pixel_limit("Apple M2 Ultra"), 7680);
        assert_eq!(chip_pixel_limit("Intel(R) Core(TM) i9"), 7680);
        assert_eq!(chip_pixel_limit(""), 7680);
    }

    // ----- chipPixelLimit edge cases -----

    #[test]
    fn chip_pixel_limit_branch_order_max_wins_over_apple_m() {
        // "Apple M1 Max" contains both "apple m" and "max"; pro/max/ultra is tested first → 7680.
        assert_eq!(chip_pixel_limit("Apple M1 Max"), 7680);
        assert_eq!(chip_pixel_limit("Apple M4 Max"), 7680);
    }

    #[test]
    fn chip_pixel_limit_case_insensitive() {
        assert_eq!(chip_pixel_limit("APPLE M1 PRO"), 7680);
        assert_eq!(chip_pixel_limit("apple m1 pro"), 7680);
    }

    #[test]
    fn chip_pixel_limit_substring_matching() {
        // "apple mx" contains the substring "apple m" → base limit.
        assert_eq!(chip_pixel_limit("apple mx"), 6144);
    }

    #[test]
    fn chip_pixel_limit_intel_full_brand_string() {
        assert_eq!(
            chip_pixel_limit("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"),
            7680
        );
    }

    // ----- VirtualDisplayPlanner.refreshRates cases -----

    // At 60fps (or below): just the 60/30 baseline (descending, deduped).
    #[test]
    fn refresh_rates_default() {
        assert_eq!(refresh_rates(60), vec![60.0, 30.0]);
        assert_eq!(refresh_rates(30), vec![60.0, 30.0]);
    }

    // Above 60fps: add the fps mode.
    #[test]
    fn refresh_rates_high_fps() {
        assert_eq!(refresh_rates(90), vec![90.0, 60.0, 30.0]);
        assert_eq!(refresh_rates(120), vec![120.0, 60.0, 30.0]);
    }

    // ----- refreshRates edge cases -----

    #[test]
    fn refresh_rates_boundary_and_low() {
        // fps == 60 is the boundary: NOT appended (strict `>`).
        assert_eq!(refresh_rates(60), vec![60.0, 30.0]);
        // fps == 59 / 0 / negative → baseline only.
        assert_eq!(refresh_rates(59), vec![60.0, 30.0]);
        assert_eq!(refresh_rates(0), vec![60.0, 30.0]);
        assert_eq!(refresh_rates(-5), vec![60.0, 30.0]);
    }

    #[test]
    fn refresh_rates_smallest_above_sixty() {
        // fps == 61 is the smallest value > 60.
        assert_eq!(refresh_rates(61), vec![61.0, 60.0, 30.0]);
    }

    #[test]
    fn refresh_rates_common_high_modes_descending() {
        assert_eq!(refresh_rates(144), vec![144.0, 60.0, 30.0]);
        // every output is sorted strictly descending.
        for fps in [0, 30, 60, 61, 90, 120, 144] {
            let r = refresh_rates(fps);
            for w in r.windows(2) {
                assert!(w[0] > w[1], "not descending for fps={fps}: {r:?}");
            }
        }
    }
}
