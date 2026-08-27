//! The arithmetic that decides what a `HiDPI` virtual display IS, before any of it reaches
//! `WindowServer`.
//!
//! `Sources/SlopDeskVideoHost/VirtualDisplay.swift` splits into two halves for a reason its own
//! header states: the `CGVirtualDisplay` half is synchronous Mach IPC to the window server and can
//! only be exercised on real hardware, while the half BELOW is pure point↔pixel↔millimetre
//! arithmetic that decides every field the descriptor is filled with. This module is that half, and
//! it is the only copy of it — the Swift `VirtualDisplayGeometry` / `VirtualDisplayPlanner` that
//! carried it were deleted when this landed, and their headers had said "Matches the core" against
//! a core that did not exist.
//!
//! Four answers, and every one of them fails SILENTLY when it drifts:
//!
//! - a framebuffer over the chip's horizontal budget makes `applySettings:` return YES and leave
//!   `displayID` at 0, so the guard has to be arithmetic taken BEFORE the call;
//! - a `sizeInMillimeters` off by a rounding step moves the reported DPI across the `HiDPI`
//!   eligibility line, and the display comes up soft rather than failing;
//! - a virtual display placed on top of a real one makes `WindowServer` reflow the user's actual
//!   monitor arrangement to resolve the overlap;
//! - a refresh mode that is not advertised is simply never granted, and a 60 fps capture beats
//!   against a 60 Hz commit with nothing in any log.
//!
//! **Float order is load-bearing and pinned.** `golden/golden_vectors.json` carries
//! `virtualDisplayGeometry`, `vdOriginToRight`, `vdChipPixelLimit` and `vdRefreshRates` as BIT
//! PATTERNS, so `/ ppi * 25.4` may not be reassociated and may not become an FMA (`CLAUDE.md`), and
//! the two ordered comparisons below must keep the NaN behaviour they are spelled for: the PPI
//! floor sends a NaN to 1.0 rather than propagating it, and the rightmost-edge fold updates only on
//! a strict `<`, so a tie keeps the FIRST display and a later NaN extent never displaces a real
//! edge. A NaN that arrives FIRST does stick — that is the near side's own `max()` behaviour, so it
//! is the parity the corpus pins, not an oversight.
//!
//! Sizes are `i32` rather than the caller's `Int` because every one of them is a framebuffer
//! dimension — an `i32` converts to `f64` without loss, which is what lets the millimetre math be
//! pinned by bit pattern at all. The products saturate rather than wrap; the near side traps there
//! today, so saturation is only reachable where the caller has already lost.

use crate::geometry::{VideoPoint, VideoRect};

/// The 120 Hz ceiling on advertised modes.
///
/// The highest refresh `WindowServer` was measured to both GRANT and genuinely CLOCK for a headless
/// virtual display (`docs/DECISIONS.md`). Above it a mode is accepted and never driven, which is a
/// silent no-op rather than a failure, so nothing above it is offered.
pub const MAX_ADVERTISED_HZ: i32 = 120;

/// Millimetres per inch, exactly representable.
const MM_PER_INCH: f64 = 25.4;

/// The pixel density a virtual display reports at unless a caller asks for another.
///
/// ~163 PPI is the 27" 4K-class density macOS accepts for `HiDPI` eligibility everywhere.
pub const DEFAULT_TARGET_PPI: f64 = 163.0;

/// The horizontal framebuffer budget of a Pro/Max/Ultra die, and of anything unrecognised.
const WIDE_PIXEL_LIMIT: i32 = 7680;

/// The horizontal framebuffer budget of a base Apple M-series die.
const BASE_PIXEL_LIMIT: i32 = 6144;

/// One virtual display's point grid, its backing scale, and the chip budget it must fit inside.
///
/// Constructed through [`Geometry::new`], which floors every field at 1 — a zero or negative
/// dimension is a caller that has already lost the answer, and a 1×1 display is the shape that
/// makes the pixel-limit guard below still mean something.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    point_width: i32,
    point_height: i32,
    scale: i32,
    max_horizontal_pixels: i32,
}

impl Geometry {
    /// Builds a geometry, flooring every field at 1.
    #[must_use]
    pub const fn new(point_width: i32, point_height: i32, scale: i32, max_horizontal_pixels: i32) -> Self {
        Self {
            point_width: floor_at_one(point_width),
            point_height: floor_at_one(point_height),
            scale: floor_at_one(scale),
            max_horizontal_pixels: floor_at_one(max_horizontal_pixels),
        }
    }

    /// The logical width the parked window sees, in points.
    #[must_use]
    pub const fn point_width(&self) -> i32 {
        self.point_width
    }

    /// The logical height the parked window sees, in points.
    #[must_use]
    pub const fn point_height(&self) -> i32 {
        self.point_height
    }

    /// The backing pixel scale — 2 for a true Retina display.
    #[must_use]
    pub const fn scale(&self) -> i32 {
        self.scale
    }

    /// The chip's horizontal framebuffer budget this geometry is judged against.
    #[must_use]
    pub const fn max_horizontal_pixels(&self) -> i32 {
        self.max_horizontal_pixels
    }

    /// The backing framebuffer width, `points × scale`.
    #[must_use]
    pub const fn pixel_width(&self) -> i32 {
        self.point_width.saturating_mul(self.scale)
    }

    /// The backing framebuffer height, `points × scale`.
    #[must_use]
    pub const fn pixel_height(&self) -> i32 {
        self.point_height.saturating_mul(self.scale)
    }

    /// Whether the framebuffer would exceed the chip budget, and the display must NOT be created.
    ///
    /// `applySettings:` answers YES for an over-budget display and leaves `displayID` at 0, so this
    /// is the only place the refusal can be made while it is still legible.
    #[must_use]
    pub const fn exceeds_pixel_limit(&self) -> bool {
        self.pixel_width() > self.max_horizontal_pixels
    }

    /// The physical size to advertise, in millimetres, for a target pixel density.
    ///
    /// Computed from the PIXEL dimensions so the reported density matches the real framebuffer.
    /// `target_ppi` is floored at 1.0 by a comparison that sends a NaN to the floor rather than
    /// propagating it — `NAN >= 1.0` is false — and the division and the multiplication stay
    /// separate and left-to-right, because `golden/golden_vectors.json` pins both results as bit
    /// patterns.
    #[must_use]
    pub fn size_in_millimeters(&self, target_ppi: f64) -> (f64, f64) {
        let ppi = if target_ppi >= 1.0 { target_ppi } else { 1.0 };
        (
            f64::from(self.pixel_width()) / ppi * MM_PER_INCH,
            f64::from(self.pixel_height()) / ppi * MM_PER_INCH,
        )
    }
}

/// Floors a dimension at 1. `const` so [`Geometry::new`] can be.
const fn floor_at_one(value: i32) -> i32 {
    if value < 1 { 1 } else { value }
}

/// The virtual display's global origin: flush to the RIGHT of the rightmost existing display.
///
/// Placing it past every real display is what guarantees it never overlaps one, and an overlap is
/// resolved by `WindowServer` REFLOWING the user's real monitor arrangement — a visible, persistent
/// corruption of something the daemon does not own. On a single-display host this reduces to
/// `(mainWidth, 0)`.
///
/// `existing` are the online displays' global bounds. Each is STANDARDISED before its right edge is
/// read, so a negative extent moves the origin rather than producing an edge left of it. The fold
/// updates only on a strict `<`, which keeps the FIRST display on a tie and never lets a later NaN
/// displace a real edge; an empty list answers `(0, 0)`.
#[must_use]
pub fn origin_to_right(existing: &[VideoRect]) -> VideoPoint {
    let mut max_x = 0.0_f64;
    let mut seen = false;
    for rect in existing {
        let edge = rect.standardized().max_x();
        if !seen || max_x < edge {
            max_x = edge;
            seen = true;
        }
    }
    VideoPoint::new(max_x, 0.0)
}

/// The chip's maximum horizontal framebuffer pixels, read out of `machdep.cpu.brand_string`.
///
/// BRANCH ORDER is load-bearing: the Pro/Max/Ultra test runs BEFORE the bare `apple m` prefix, so
/// "Apple M1 Max" answers 7680 rather than 6144. Intel and unknown brands answer the permissive
/// 7680 — an over-budget create still fails safe through the `displayID == 0` guard, where an
/// over-strict limit would refuse a display that would have worked.
#[must_use]
pub fn chip_pixel_limit(cpu_brand: &str) -> i32 {
    let brand = cpu_brand.to_lowercase();
    if brand.contains("pro") || brand.contains("max") || brand.contains("ultra") {
        return WIDE_PIXEL_LIMIT;
    }
    if brand.contains("apple m") {
        return BASE_PIXEL_LIMIT;
    }
    WIDE_PIXEL_LIMIT
}

/// The refresh modes to advertise for a virtual display used as the capture SOURCE of an `fps`
/// encode. Descending, deduplicated.
///
/// Two requirements, unioned:
///
/// 1. **2:1 oversample.** `WindowServer` commits a parked surface at the display's refresh, and a
///    capture running 1:1 with the encode rate beats against it. A mode at `2 × fps` — capped at
///    [`MAX_ADVERTISED_HZ`] — lets the capture take two commits per encoded frame, which is why a
///    60 fps encode needs a 120 Hz mode rather than a 60 Hz one.
/// 2. **At least `fps` for a fast window.** A parked window is composited at most at the display's
///    refresh, so a 90 fps window needs a 90 Hz mode of its own.
///
/// The 60 and 30 baseline is always present, so an `fps` at or under 30 adds nothing.
#[must_use]
pub fn refresh_rates(fps: i32) -> Vec<f64> {
    let f = if fps < 1 { 1 } else { fps };
    let mut rates = vec![60.0_f64, 30.0_f64];
    let oversample = MAX_ADVERTISED_HZ.min(f.saturating_mul(2));
    if oversample > 60 {
        rates.push(f64::from(oversample));
    }
    if f > 60 {
        rates.push(f64::from(f));
    }
    rates.sort_by(|a, b| b.total_cmp(a));
    rates.dedup();
    rates
}

/// The key that asks the daemon for a virtual display, when the command line has not.
pub const VIRTUAL_DISPLAY_KEY: &str = "SLOPDESK_VD";

/// Whether the daemon opens a virtual display, given the environment text and whether the flag was
/// passed explicitly.
///
/// Default-ON in its own right (`0` is the only off value), but the flag wins outright: `explicit`
/// means the command line already answered, and an environment variable must not quietly reverse a
/// decision the operator typed. Answers [`None`] in exactly that case — and equally when the
/// variable is unset — so the caller keeps what it had rather than being handed a value to ignore.
#[must_use]
pub fn virtual_display_from_env(raw: Option<&str>, explicit: bool) -> Option<bool> {
    if explicit {
        return None;
    }
    raw.map(|text| text != "0")
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_TARGET_PPI, Geometry, MAX_ADVERTISED_HZ, chip_pixel_limit, origin_to_right, refresh_rates,
        virtual_display_from_env,
    };
    use crate::geometry::VideoRect;

    #[test]
    fn an_explicit_flag_beats_the_virtual_display_variable() {
        assert_eq!(
            virtual_display_from_env(Some("0"), true),
            None,
            "the command line already answered"
        );
        assert_eq!(virtual_display_from_env(Some("0"), false), Some(false));
        assert_eq!(virtual_display_from_env(Some("1"), false), Some(true));
        assert_eq!(
            virtual_display_from_env(None, false),
            None,
            "unset is not OFF — the caller keeps its own default"
        );
    }

    #[test]
    fn a_retina_geometry_backs_its_point_grid_at_scale() {
        let geometry = Geometry::new(1920, 1080, 2, 7680);
        assert_eq!(geometry.pixel_width(), 3840);
        assert_eq!(geometry.pixel_height(), 2160);
        assert!(!geometry.exceeds_pixel_limit());
    }

    #[test]
    fn every_dimension_is_floored_at_one() {
        let geometry = Geometry::new(0, -5, 0, 0);
        assert_eq!(geometry.point_width(), 1);
        assert_eq!(geometry.point_height(), 1);
        assert_eq!(geometry.scale(), 1);
        assert_eq!(geometry.max_horizontal_pixels(), 1);
        assert_eq!(geometry.pixel_width(), 1);
        // 1 > 1 is false — the floored geometry is exactly at its floored budget, not over it.
        assert!(!geometry.exceeds_pixel_limit());
    }

    #[test]
    fn an_over_budget_framebuffer_is_refused_before_windowserver_sees_it() {
        assert!(Geometry::new(3840, 2160, 2, 6144).exceeds_pixel_limit());
        assert!(!Geometry::new(3840, 2160, 2, 7680).exceeds_pixel_limit());
    }

    #[test]
    fn the_millimetre_size_keeps_its_operand_order() {
        let geometry = Geometry::new(1920, 1080, 2, 7680);
        let (width, height) = geometry.size_in_millimeters(DEFAULT_TARGET_PPI);
        // The bit patterns `golden/golden_vectors.json` pins for the shipped 1080p@2× display.
        assert_eq!(width.to_bits(), 4_648_474_625_199_435_851);
        assert_eq!(height.to_bits(), 4_644_628_951_744_622_164);
    }

    #[test]
    fn a_nan_ppi_takes_the_floor_rather_than_propagating() {
        let geometry = Geometry::new(1920, 1080, 2, 7680);
        let (width, height) = geometry.size_in_millimeters(f64::NAN);
        let (floored_width, floored_height) = geometry.size_in_millimeters(1.0);
        assert_eq!(width.to_bits(), floored_width.to_bits());
        assert_eq!(height.to_bits(), floored_height.to_bits());
    }

    /// The corpus compares this origin by BIT PATTERN, so the tests do too — `-0.0` is the answer a
    /// fold gets wrong while still comparing equal to `0.0`.
    fn rightmost(displays: &[VideoRect]) -> (u64, u64) {
        let origin = origin_to_right(displays);
        (origin.x.to_bits(), origin.y.to_bits())
    }

    #[test]
    fn the_origin_clears_every_real_display() {
        assert_eq!(rightmost(&[]), (0.0_f64.to_bits(), 0.0_f64.to_bits()));
        assert_eq!(
            rightmost(&[VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0)]),
            (1920.0_f64.to_bits(), 0.0_f64.to_bits())
        );
        assert_eq!(
            rightmost(&[
                VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
                VideoRect::xywh(1920.0, 0.0, 2560.0, 1440.0),
            ]),
            (4480.0_f64.to_bits(), 0.0_f64.to_bits())
        );
    }

    #[test]
    fn a_negative_extent_is_standardised_before_its_edge_is_read() {
        // A rect written right-to-left covers [100, 500]; its right edge is 500, not 100.
        assert_eq!(
            rightmost(&[VideoRect::xywh(500.0, 0.0, -400.0, 100.0)]).0,
            500.0_f64.to_bits()
        );
    }

    #[test]
    fn a_later_nan_extent_never_displaces_a_real_edge() {
        let displays = [
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
            VideoRect::xywh(0.0, 0.0, f64::NAN, 1080.0),
        ];
        assert_eq!(rightmost(&displays).0, 1920.0_f64.to_bits());
    }

    #[test]
    fn the_pro_max_ultra_test_runs_before_the_bare_apple_m_prefix() {
        assert_eq!(chip_pixel_limit("Apple M1"), 6144);
        assert_eq!(chip_pixel_limit("Apple M1 Max"), 7680);
        assert_eq!(chip_pixel_limit("Apple M2 Pro"), 7680);
        assert_eq!(chip_pixel_limit("Apple M1 Ultra"), 7680);
        assert_eq!(chip_pixel_limit("Intel(R) Core(TM) i9-9880H"), 7680);
        assert_eq!(chip_pixel_limit(""), 7680);
    }

    /// The ORDER is part of the answer, and the corpus pins each rate by bit pattern.
    fn ladder(fps: i32) -> Vec<u64> {
        refresh_rates(fps).iter().map(|rate| rate.to_bits()).collect()
    }

    fn bits(rates: &[f64]) -> Vec<u64> {
        rates.iter().map(|rate| rate.to_bits()).collect()
    }

    #[test]
    fn the_advertised_modes_cover_the_oversample_and_the_window() {
        assert_eq!(ladder(30), bits(&[60.0, 30.0]));
        assert_eq!(ladder(60), bits(&[120.0, 60.0, 30.0]));
        assert_eq!(ladder(90), bits(&[120.0, 90.0, 60.0, 30.0]));
        // The oversample is capped, and the cap collides with the window's own rate rather than
        // listing it twice.
        assert_eq!(ladder(120), bits(&[120.0, 60.0, 30.0]));
        assert_eq!(ladder(0), bits(&[60.0, 30.0]));
        assert_eq!(
            ladder(i32::MAX),
            bits(&[f64::from(i32::MAX), f64::from(MAX_ADVERTISED_HZ), 60.0, 30.0,])
        );
    }
}
