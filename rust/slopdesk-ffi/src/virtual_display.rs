//! What a `HiDPI` virtual display IS, before `WindowServer` is asked for one.
//!
//! The four answers in `slopdesk_video::virtual_display`, and every one of them is arithmetic with
//! nothing to own: no handle, no allocation, no lifetime a caller could get wrong. The scalar
//! answers cross BY VALUE (`docs/55` §4b); the ones that carry a list borrow it for the call — a
//! display list as a flat run of `f64`s, four per display, exactly as `window_placement`'s door
//! already does, because that is what a Swift `[CGRect]` maps to without a second layout for either
//! side to agree on.
//!
//! The advertised modes are the one answer whose SIZE is not fixed, and it is bounded by
//! construction: the baseline pair plus at most the oversample and the window's own rate, so four
//! is the ceiling and the caller lends a fixed buffer rather than being handed one to free.
//!
//! Bit-exactness is the point of the boundary being here rather than in Swift.
//! `golden/golden_vectors.json` pins the millimetre conversion and the rightmost-edge fold as bit
//! patterns, which means the operand order, the NaN handling and the tie-breaking must survive the
//! crossing unchanged — they do, because nothing is recomputed on this side. The door hands over
//! the caller's scalars and hands back the crate's.

use std::os::raw::c_uchar;

use slopdesk_video::geometry::VideoRect;
use slopdesk_video::virtual_display;

/// The most refresh modes [`slopdesk_vd_refresh_rates`] can ever answer.
///
/// The baseline 60 and 30, the capped `min(120, 2 × fps)` oversample, and the window's own rate.
/// Stated here so the caller can size one stack buffer and never ask how big the answer is first.
pub const SLOPDESK_VD_MAX_REFRESH_RATES: usize = 4;

/// A virtual display's point grid, its backing framebuffer, and whether the chip can drive it.
///
/// The FLOORED dimensions come back with the derived ones on purpose. The near side fills a
/// `CGVirtualDisplayMode` from the POINT grid and `settings.hiDPI` from the SCALE, so if it kept
/// its own `max(1, …)` the floor would be spelled in two languages — which is the drift this
/// crossing exists to end, and the one a rule about literals could never see.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskVirtualDisplayGeometry {
    /// The logical width in points, floored at 1 — what a `CGVirtualDisplayMode` is built from.
    pub point_width: i32,
    /// The logical height in points, by the same rule.
    pub point_height: i32,
    /// The backing pixel scale, floored at 1. `>= 2` is what makes `settings.hiDPI` 1.
    pub scale: i32,
    /// The chip's horizontal framebuffer budget this geometry was judged against, floored at 1.
    pub max_horizontal_pixels: i32,
    /// The backing framebuffer width, `points × scale`, after the caller's dimensions are floored.
    pub pixel_width: i32,
    /// The backing framebuffer height, by the same rule.
    pub pixel_height: i32,
    /// Whether the framebuffer is over the chip's horizontal budget, and the display must NOT be
    /// created — `applySettings:` would answer YES and leave `displayID` at 0.
    pub exceeds_pixel_limit: bool,
}

/// A physical size in millimetres.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskVirtualDisplaySize {
    /// The width, in millimetres.
    pub width: f64,
    /// The height, in millimetres.
    pub height: f64,
}

/// A point in the global display space.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskVirtualDisplayOrigin {
    /// The horizontal coordinate.
    pub x: f64,
    /// The vertical coordinate.
    pub y: f64,
}

/// The backing framebuffer for a point grid at a scale, judged against a chip budget.
///
/// Every dimension is floored at 1 on the far side, so a zero or negative one crosses verbatim and
/// is answered rather than rejected.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_vd_geometry(
    point_width: i32,
    point_height: i32,
    scale: i32,
    max_horizontal_pixels: i32,
) -> SlopDeskVirtualDisplayGeometry {
    let geometry = virtual_display::Geometry::new(point_width, point_height, scale, max_horizontal_pixels);
    SlopDeskVirtualDisplayGeometry {
        point_width: geometry.point_width(),
        point_height: geometry.point_height(),
        scale: geometry.scale(),
        max_horizontal_pixels: geometry.max_horizontal_pixels(),
        pixel_width: geometry.pixel_width(),
        pixel_height: geometry.pixel_height(),
        exceeds_pixel_limit: geometry.exceeds_pixel_limit(),
    }
}

/// The physical size to advertise for a point grid at a target pixel density.
///
/// `target_ppi` is floored at 1.0 by a comparison that sends a NaN to the floor; the division and
/// the multiplication stay separate, so the two `f64`s that come back are the ones
/// `golden/golden_vectors.json` pins by bit pattern.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_vd_size_in_millimeters(
    point_width: i32,
    point_height: i32,
    scale: i32,
    max_horizontal_pixels: i32,
    target_ppi: f64,
) -> SlopDeskVirtualDisplaySize {
    let (width, height) =
        virtual_display::Geometry::new(point_width, point_height, scale, max_horizontal_pixels)
            .size_in_millimeters(target_ppi);
    SlopDeskVirtualDisplaySize { width, height }
}

/// The density a virtual display reports at unless a caller asks for another.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_vd_default_target_ppi() -> f64 {
    virtual_display::DEFAULT_TARGET_PPI
}

/// The origin to place the virtual display at: flush right of every display in `displays`.
///
/// `displays` is `4 * display_count` scalars — `x, y, width, height` per display, in the global
/// space the caller enumerates in. Each is standardised before its right edge is read, and an empty
/// or absent list answers the origin.
///
/// # Safety
/// `displays` must be null or point to `4 * display_count` readable, aligned `f64`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vd_origin_to_right(
    displays: *const f64,
    display_count: usize,
) -> SlopDeskVirtualDisplayOrigin {
    // SAFETY: the caller's obligation above, discharged by Swift's `withUnsafeBufferPointer`,
    // whose scope is exactly this call.
    let scalars = unsafe { crate::borrow(displays, display_count.saturating_mul(4)) };
    let bounds: Vec<VideoRect> = scalars
        .as_chunks::<4>()
        .0
        .iter()
        .map(|&[x, y, width, height]| VideoRect::xywh(x, y, width, height))
        .collect();
    let origin = virtual_display::origin_to_right(&bounds);
    SlopDeskVirtualDisplayOrigin {
        x: origin.x,
        y: origin.y,
    }
}

/// The chip's maximum horizontal framebuffer pixels, from its `machdep.cpu.brand_string`.
///
/// # Safety
/// `brand` must be null or name `brand_len` initialised bytes that stay live for the call. A null
/// or non-UTF-8 span reads as the empty brand, which answers the permissive limit.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vd_chip_pixel_limit(brand: *const c_uchar, brand_len: usize) -> i32 {
    // SAFETY: the caller's obligation above, discharged by the shared text helper.
    let text = unsafe { crate::lent(brand, brand_len) };
    virtual_display::chip_pixel_limit(text)
}

/// The refresh modes to advertise for a capture source feeding an `fps` encode, descending.
///
/// Writes at most `capacity` rates into `out` and answers how many the rule produced — which is
/// never more than [`SLOPDESK_VD_MAX_REFRESH_RATES`], so a caller that lends that many is never
/// short. A returned count above `capacity` means the buffer was too small and nothing beyond it
/// was written; the order is part of the answer, so a truncated read is a wrong one.
///
/// # Safety
/// `out` must be null or point to `capacity` writable, aligned `f64`s for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vd_refresh_rates(fps: i32, out: *mut f64, capacity: usize) -> usize {
    let rates = virtual_display::refresh_rates(fps);
    if !out.is_null() && capacity >= rates.len() {
        // SAFETY: the caller's obligation above. `rates` is a fresh local, so the two regions
        // cannot overlap, and the length is checked against the lent capacity first.
        unsafe { std::ptr::copy_nonoverlapping(rates.as_ptr(), out, rates.len()) }
    }
    rates.len()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{
        SLOPDESK_VD_MAX_REFRESH_RATES, slopdesk_vd_chip_pixel_limit, slopdesk_vd_default_target_ppi,
        slopdesk_vd_geometry, slopdesk_vd_origin_to_right, slopdesk_vd_refresh_rates,
        slopdesk_vd_size_in_millimeters,
    };

    #[test]
    fn the_framebuffer_and_its_budget_cross_by_value() {
        let retina = slopdesk_vd_geometry(1920, 1080, 2, 7680);
        assert_eq!((retina.pixel_width, retina.pixel_height), (3840, 2160));
        assert!(!retina.exceeds_pixel_limit);
        assert!(slopdesk_vd_geometry(3840, 2160, 2, 6144).exceeds_pixel_limit);
        // The FLOORED point grid and scale come back with the derived pixels, so the near side has
        // no reason to keep a `max(1, …)` of its own — the mode and `hiDPI` are built from these.
        let floored = slopdesk_vd_geometry(0, -5, 0, 0);
        assert_eq!((floored.point_width, floored.point_height), (1, 1));
        assert_eq!((floored.scale, floored.max_horizontal_pixels), (1, 1));
        assert_eq!((floored.pixel_width, floored.pixel_height), (1, 1));
        assert_eq!((retina.point_width, retina.point_height), (1920, 1080));
        assert_eq!((retina.scale, retina.max_horizontal_pixels), (2, 7680));
    }

    #[test]
    fn the_millimetre_bit_patterns_survive_the_crossing() {
        let size = slopdesk_vd_size_in_millimeters(1920, 1080, 2, 7680, slopdesk_vd_default_target_ppi());
        assert_eq!(size.width.to_bits(), 4_648_474_625_199_435_851);
        assert_eq!(size.height.to_bits(), 4_644_628_951_744_622_164);
        let nan = slopdesk_vd_size_in_millimeters(1920, 1080, 2, 7680, f64::NAN);
        let floored = slopdesk_vd_size_in_millimeters(1920, 1080, 2, 7680, 1.0);
        assert_eq!(nan.width.to_bits(), floored.width.to_bits());
    }

    #[test]
    fn a_display_list_crosses_as_four_scalars_each() {
        // Bit patterns rather than values: `-0.0` is what a fold gets wrong while comparing equal.
        let bits = |origin: super::SlopDeskVirtualDisplayOrigin| (origin.x.to_bits(), origin.y.to_bits());
        let zero = (0.0_f64.to_bits(), 0.0_f64.to_bits());
        let displays = [0.0, 0.0, 1920.0, 1080.0, 1920.0, 0.0, 2560.0, 1440.0];
        // SAFETY: one live buffer of eight scalars, borrowed for the call.
        let origin = unsafe { slopdesk_vd_origin_to_right(displays.as_ptr(), 2) };
        assert_eq!(bits(origin), (4480.0_f64.to_bits(), 0.0_f64.to_bits()));
        // SAFETY: the documented empty cases, neither of which dereferences the pointer.
        let empty = unsafe { slopdesk_vd_origin_to_right(displays.as_ptr(), 0) };
        assert_eq!(bits(empty), zero);
        // SAFETY: a null list is the documented absent case.
        let absent = unsafe { slopdesk_vd_origin_to_right(std::ptr::null(), 2) };
        assert_eq!(bits(absent), zero);
    }

    #[test]
    fn the_brand_crosses_as_a_borrowed_span() {
        let limit = |brand: &str| {
            // SAFETY: the string outlives the call.
            unsafe { slopdesk_vd_chip_pixel_limit(brand.as_ptr(), brand.len()) }
        };
        assert_eq!(limit("Apple M1"), 6144);
        assert_eq!(limit("Apple M1 Max"), 7680);
        // SAFETY: a null brand is the documented absent case, answering the permissive limit.
        assert_eq!(unsafe { slopdesk_vd_chip_pixel_limit(std::ptr::null(), 8) }, 7680);
    }

    #[test]
    fn the_modes_fit_the_stated_ceiling_and_a_short_buffer_writes_nothing() {
        let mut out = [0.0_f64; SLOPDESK_VD_MAX_REFRESH_RATES];
        // SAFETY: one live buffer of the stated ceiling, written for the call.
        let count = unsafe { slopdesk_vd_refresh_rates(90, out.as_mut_ptr(), out.len()) };
        assert_eq!(count, 4);
        let bits = |rates: &[f64]| rates.iter().map(|rate| rate.to_bits()).collect::<Vec<_>>();
        assert_eq!(bits(&out), bits(&[120.0, 90.0, 60.0, 30.0]));

        let mut short = [-1.0_f64; 2];
        // SAFETY: a buffer smaller than the answer — the count comes back, the buffer does not.
        let needed = unsafe { slopdesk_vd_refresh_rates(90, short.as_mut_ptr(), short.len()) };
        assert_eq!(needed, 4);
        assert_eq!(
            bits(&short),
            bits(&[-1.0, -1.0]),
            "a truncated order is a wrong order"
        );
        assert!(needed <= SLOPDESK_VD_MAX_REFRESH_RATES);
    }
}
