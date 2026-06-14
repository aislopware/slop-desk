//! Pure window-placement arithmetic.
//!
//! The canonical window-placement logic; the macOS host shell calls it over the C ABI
//! (`RustVideoHostFFI.windowPlacement`/`windowFits`) from its VD-park path. Only the PURE
//! math lives here; the host's `WindowPlacement` enum (Accessibility side effects) stays in
//! Swift and is intentionally NOT portable to this core.
//!
//! Feature #1 (`HiDPI` virtual-display parking): decide where/how to move a window
//! fully onto a display. [`placement`] clamps the window DOWN to the display bounds
//! (never enlarges) and places it at the display's top-left origin; [`fits`] checks,
//! after the AX move, that the window actually shrank to fit (½-pt tolerance).
//!
//! ## CoreGraphics-semantics preserved exactly
//!
//! * `CGRect.width`/`.height` STANDARDIZE — they return `|size|`, always
//!   non-negative — so the display extents read `display_bounds.width()` /
//!   `.height()` (the abs-returning helpers on [`VideoRect`]).
//! * `CGSize.width`/`.height` are RAW stored fields (NOT standardized), so the
//!   window operand (and the `size` arg to [`fits`]) is used verbatim, never abs'd.
//!   The clamp is therefore asymmetric: `min(window_raw, display_abs)`.
//! * `CGRect.origin` is the RAW stored origin (NOT standardized), so [`placement`]
//!   returns `display_bounds.origin` verbatim — including negative coordinates from
//!   a display placed to the left of / above the main display.
//! * The `min(x, y)` clamp uses the same ternary form as Swift's global `min`
//!   (`{ y < x ? y : x }`) rather than [`f64::min`]: the two agree for every finite input,
//!   but the ternary propagates a NaN operand (unlike `f64::min`); the Swift shell does the same.
//! * The ½-pt tolerance math is byte-for-byte: `0.5` is exactly representable and is
//!   added to exactly-representable inputs, so there is no rounding error. NO
//!   rounding (`.rounded()`) appears anywhere in this module.

use crate::geometry::{VideoRect, VideoSize};
// NOTE: VideoPoint is reused only via VideoRect::origin (no direct construction here).

/// Result of [`placement`]. The Swift shell returns the equivalent labeled tuple
/// `(origin: CGPoint, size: CGSize, needsResize: Bool)`. `Copy` (all-`Copy` fields),
/// matching the Swift value type.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Placement {
    /// The move target = the display's top-left origin. Equals `display_bounds.origin`
    /// VERBATIM (CG `.origin` is the RAW stored origin, never standardized).
    pub origin: crate::geometry::VideoPoint,
    /// The clamped window size: each axis = `min(window, display)`, i.e. shrunk to
    /// fit the display, never enlarged.
    pub size: VideoSize,
    /// True iff the window overhangs the display by MORE than ½ pt on either axis
    /// (so it must be resized DOWN before the cross-display move).
    pub needs_resize: bool,
}

/// Clamp `window_size` to `display_bounds` (resize DOWN only — never enlarge) and
/// place at the display's top-left origin.
///
/// macOS crops a window that overhangs a
/// display, so an oversized window must be shrunk before the move.
///
/// CG-semantic asymmetry preserved EXACTLY:
///   * `window_size.width`/`.height` are RAW `CGSize` fields (NOT standardized).
///   * `display_bounds.width()`/`.height()` are CG-standardized (abs) — see geometry.
///   * `min(a, b)` uses the same form as Swift's global `min(x, y) == { y < x ? y : x }`
///     (matters only for NaN, which is not vectorable; finite inputs agree with `f64::min`).
#[must_use]
pub fn placement(window_size: VideoSize, display_bounds: VideoRect) -> Placement {
    let dw = display_bounds.width(); // CG-standardized (abs)
    let dh = display_bounds.height();
    // Swift `min(windowSize.width, displayBounds.width)` == `dw < window ? dw : window`.
    let w = if dw < window_size.width {
        dw
    } else {
        window_size.width
    };
    let h = if dh < window_size.height {
        dh
    } else {
        window_size.height
    };
    // ½-pt tolerance so float equality never triggers a no-op resize. Uses the
    // CLAMPED w/h vs the RAW window size, OR across both axes (short-circuits; no
    // observable difference since both sides are side-effect-free comparisons).
    let needs_resize = (w + 0.5 < window_size.width) || (h + 0.5 < window_size.height);
    Placement {
        origin: display_bounds.origin,
        size: VideoSize::new(w, h),
        needs_resize,
    }
}

/// True when `size` fits inside `bounds` (within a ½-pt tolerance).
///
/// Used after the
/// AX move to confirm the window shrank to fit the VD; an app that refuses/clamps
/// the resize leaves an oversized window that must NOT be reported as a successful
/// 2× move. `bounds.width()`/`.height()` are CG-standardized (abs); `size` is raw.
#[must_use]
pub fn fits(size: VideoSize, bounds: VideoRect) -> bool {
    size.width <= bounds.width() + 0.5 && size.height <= bounds.height() + 0.5
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::{VideoPoint, VideoRect, VideoSize};

    // ---- placement and fits cases (the host `VirtualDisplayGeometryTests` suite drives these via the FFI) ----

    /// `testPlacementFitsNoResize`: a window smaller than the display is not resized
    /// and is placed at the display origin.
    #[test]
    fn placement_fits_no_resize() {
        let p = placement(
            VideoSize::new(1200.0, 800.0),
            VideoRect::xywh(3840.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.origin, VideoPoint::new(3840.0, 0.0));
        assert_eq!(p.size, VideoSize::new(1200.0, 800.0));
        assert!(!p.needs_resize);
    }

    /// `testPlacementClampsOversizedWidth`: larger on one axis → clamp that axis, flag resize.
    #[test]
    fn placement_clamps_oversized_width() {
        let p = placement(
            VideoSize::new(2400.0, 900.0),
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.size, VideoSize::new(1920.0, 900.0));
        assert!(p.needs_resize);
    }

    /// `testPlacementClampsBothAxes`: larger on both axes → clamp both.
    #[test]
    fn placement_clamps_both_axes() {
        let p = placement(
            VideoSize::new(4000.0, 3000.0),
            VideoRect::xywh(100.0, 50.0, 1920.0, 1080.0),
        );
        assert_eq!(p.origin, VideoPoint::new(100.0, 50.0));
        assert_eq!(p.size, VideoSize::new(1920.0, 1080.0));
        assert!(p.needs_resize);
    }

    /// `testPlacementExactSizeNoResize`: exactly display-sized → no resize (½-pt tolerance).
    #[test]
    fn placement_exact_size_no_resize() {
        let p = placement(
            VideoSize::new(1920.0, 1080.0),
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
        );
        assert!(!p.needs_resize);
        assert_eq!(p.size, VideoSize::new(1920.0, 1080.0));
    }

    /// `testFitsWithinBounds`: ≤ bounds (with ½-pt tolerance) passes; overhang on either axis fails.
    #[test]
    fn fits_within_bounds() {
        let vd = VideoRect::xywh(3840.0, 0.0, 1920.0, 1080.0);
        assert!(fits(VideoSize::new(1920.0, 1080.0), vd)); // exact
        assert!(fits(VideoSize::new(1200.0, 800.0), vd)); // smaller
        assert!(fits(VideoSize::new(1920.4, 1080.0), vd)); // within tol
        assert!(!fits(VideoSize::new(1921.0, 1080.0), vd)); // width over
        assert!(!fits(VideoSize::new(1920.0, 1200.0), vd)); // height over
    }

    // ---- added boundary/edge tests ----

    /// Overhang by EXACTLY 0.5 pt stays within tolerance: `1440.0 + 0.5 < 1440.5` is false.
    #[test]
    fn placement_half_pt_overhang_is_within_tolerance() {
        let p = placement(
            VideoSize::new(1440.5, 900.0),
            VideoRect::xywh(0.0, 0.0, 1440.0, 900.0),
        );
        assert_eq!(p.size, VideoSize::new(1440.0, 900.0));
        assert!(!p.needs_resize); // 1440.0 + 0.5 < 1440.5 is false
    }

    /// `fits` is `<=` at exactly the ½-pt tolerance; one ulp past it fails.
    #[test]
    fn fits_exactly_at_half_pt_tolerance() {
        let vd = VideoRect::xywh(0.0, 0.0, 1440.0, 900.0);
        assert!(fits(VideoSize::new(1440.5, 900.5), vd)); // 1440.5 <= 1440.0 + 0.5
        assert!(!fits(VideoSize::new(1440.6, 900.0), vd));
    }

    /// Window smaller than display on both axes: clamp picks the window value, no resize.
    #[test]
    fn placement_smaller_both_axes() {
        let p = placement(
            VideoSize::new(640.0, 480.0),
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.size, VideoSize::new(640.0, 480.0));
        assert!(!p.needs_resize);
    }

    /// Overhang by 0.5 + epsilon flags a resize on that axis (mirrors parity case P6).
    #[test]
    fn placement_overhang_half_pt_plus_eps_needs_resize() {
        let p = placement(
            VideoSize::new(1440.6, 900.0),
            VideoRect::xywh(0.0, 0.0, 1440.0, 900.0),
        );
        assert_eq!(p.size, VideoSize::new(1440.0, 900.0));
        assert!(p.needs_resize);
    }

    /// Overhang by a full point clearly needs a resize (parity case P7).
    #[test]
    fn placement_over_by_one_needs_resize() {
        let p = placement(
            VideoSize::new(1441.0, 900.0),
            VideoRect::xywh(0.0, 0.0, 1440.0, 900.0),
        );
        assert_eq!(p.size, VideoSize::new(1440.0, 900.0));
        assert!(p.needs_resize);
    }

    /// Per-axis OR: oversized on ONLY the height still flags resize; width keeps the window value.
    #[test]
    fn placement_per_axis_or_height_only() {
        let p = placement(
            VideoSize::new(1000.0, 2000.0),
            VideoRect::xywh(0.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.size, VideoSize::new(1000.0, 1080.0));
        assert!(p.needs_resize);
    }

    /// Zero-area display bounds: clamp to 0x0; resize flagged because the window exceeds 0.5.
    #[test]
    fn placement_zero_area_display() {
        let p = placement(
            VideoSize::new(800.0, 600.0),
            VideoRect::xywh(0.0, 0.0, 0.0, 0.0),
        );
        assert_eq!(p.origin, VideoPoint::new(0.0, 0.0));
        assert_eq!(p.size, VideoSize::new(0.0, 0.0));
        assert!(p.needs_resize);
    }

    /// Zero-size window: clamp stays 0x0, no resize, origin = display origin.
    #[test]
    fn placement_zero_size_window() {
        let p = placement(
            VideoSize::new(0.0, 0.0),
            VideoRect::xywh(0.0, 0.0, 1440.0, 900.0),
        );
        assert_eq!(p.size, VideoSize::new(0.0, 0.0));
        assert!(!p.needs_resize);
    }

    /// Negative display origin (display left/above main): origin is returned RAW, not standardized.
    #[test]
    fn placement_negative_origin_returned_verbatim() {
        let p = placement(
            VideoSize::new(800.0, 600.0),
            VideoRect::xywh(-1440.0, 300.0, 1440.0, 900.0),
        );
        assert_eq!(p.origin, VideoPoint::new(-1440.0, 300.0));
        assert_eq!(p.size, VideoSize::new(800.0, 600.0));
        assert!(!p.needs_resize);
    }

    /// Negative-SIZE display bounds: `width()`/`height()` standardize (abs) to (1440,900) for the
    /// clamp, but `origin` is returned RAW (100,200). Proves width()=abs AND origin=raw (P11).
    #[test]
    fn placement_negative_size_display_standardizes_extent_but_not_origin() {
        let p = placement(
            VideoSize::new(2000.0, 1500.0),
            VideoRect::xywh(100.0, 200.0, -1440.0, -900.0),
        );
        assert_eq!(p.origin, VideoPoint::new(100.0, 200.0)); // raw, not standardized
        assert_eq!(p.size, VideoSize::new(1440.0, 900.0)); // clamped to |extent|
        assert!(p.needs_resize);
    }

    /// Negative window width is used RAW (`CGSize` is NOT standardized): `min(-100, 1440) = -100`,
    /// no resize. Proves the window operand is NOT abs'd (asymmetry vs display) (P12).
    #[test]
    fn placement_negative_window_width_used_raw() {
        let p = placement(
            VideoSize::new(-100.0, 600.0),
            VideoRect::xywh(0.0, 0.0, 1440.0, 900.0),
        );
        assert_eq!(p.origin, VideoPoint::new(0.0, 0.0));
        assert_eq!(p.size, VideoSize::new(-100.0, 600.0));
        assert!(!p.needs_resize); // -100 + 0.5 < -100 is false
    }

    /// Fractional inputs split per-axis: width within tolerance (no shrink yet width-clamped),
    /// height over → resize. Exactly-representable so the math is exact (P13).
    #[test]
    fn placement_fractional_per_axis_split() {
        let p = placement(
            VideoSize::new(1000.25, 750.75),
            VideoRect::xywh(0.0, 25.0, 1000.0, 700.0),
        );
        assert_eq!(p.origin, VideoPoint::new(0.0, 25.0));
        assert_eq!(p.size, VideoSize::new(1000.0, 700.0));
        // width: 1000.0 + 0.5 < 1000.25 is false; height: 700.0 + 0.5 < 750.75 is true → OR = true.
        assert!(p.needs_resize);
    }

    /// `fits` with both axes exactly at the tolerance passes; per-axis AND means one axis over fails.
    #[test]
    fn fits_exactly_at_tolerance_both_axes_then_one_over() {
        let vd = VideoRect::xywh(0.0, 0.0, 1440.0, 900.0);
        assert!(fits(VideoSize::new(1440.5, 900.5), vd)); // F6: both at tol
        assert!(!fits(VideoSize::new(1440.6, 900.0), vd)); // F7: width over, AND fails
    }

    /// `fits` against zero bounds: only sizes ≤ 0.5 per axis pass (F8/F9).
    #[test]
    fn fits_zero_bounds() {
        let zero = VideoRect::xywh(0.0, 0.0, 0.0, 0.0);
        assert!(fits(VideoSize::new(0.5, 0.5), zero)); // F8: at tol
        assert!(!fits(VideoSize::new(0.6, 0.0), zero)); // F9: width over
    }

    /// `fits` against negative-SIZE bounds: `width()`/`height()` standardize (abs) so a window
    /// equal to the absolute extent fits (F10).
    #[test]
    fn fits_negative_size_bounds_standardizes() {
        let bounds = VideoRect::xywh(0.0, 0.0, -1920.0, -1080.0);
        assert!(fits(VideoSize::new(1920.0, 1080.0), bounds));
    }

    // ---- bit-exact spot checks (mirror the golden-parity expectations) ----

    /// The clamped axes are taken VERBATIM from the operands (no arithmetic), so they must be
    /// bit-identical: clamp picks the display extent on an oversized axis and the window value
    /// otherwise — never a derived/rounded value.
    #[test]
    fn placement_values_are_bit_exact_operands() {
        let p = placement(
            VideoSize::new(2400.0, 800.0),
            VideoRect::xywh(3840.0, 0.0, 1920.0, 1080.0),
        );
        assert_eq!(p.origin.x.to_bits(), 3840.0_f64.to_bits());
        assert_eq!(p.origin.y.to_bits(), 0.0_f64.to_bits());
        assert_eq!(p.size.width.to_bits(), 1920.0_f64.to_bits()); // clamped to display
        assert_eq!(p.size.height.to_bits(), 800.0_f64.to_bits()); // kept window value
    }
}
