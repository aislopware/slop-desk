//! `scroll_shift`: NEON per-row luma hashing + the pure vertical-shift estimator, over BORROWED
//! plane pointers (zero-copy).
//!
//! The host measures the TRUE per-frame content scroll between two captured frames (the previous,
//! kept as `cachedPixelBuffer`, and the current) and sends it to the client, which warps the last
//! decoded frame by it on spare 120 Hz display ticks (scroll reprojection). The estimate is the
//! dominant vertical row-shift found by per-row hashing both planes (the NEON
//! [`crate::frame_hash::NeonFrameHash`] kernel) and cross-correlating the row-hash arrays via the
//! pure [`aislopdesk_core::scroll_shift`] estimator (which excludes the uniform-background rows so
//! an editor's empty rows can't inflate confidence). Plane pointers come straight from the locked
//! `CVPixelBuffer`s — borrowed for the call only, never copied or freed.

use super::slice_in;
use crate::frame_hash::NeonFrameHash;
use crate::{AISD_ERR_NULL, AISD_OK, AisdStatus};
use aislopdesk_core::adaptive_qp::{adaptive_max_qp, changed_fraction};
use aislopdesk_core::scroll_shift::estimate_vertical_shift;

/// Per-row NEON luma hashes: hashes the first `width` bytes of each of the `height` `stride`-spaced
/// rows, bounds-guarded per row (an over-stated `height` stops early rather than reading OOB).
fn row_hashes(y: &[u8], stride: usize, width: usize, height: usize) -> Vec<u64> {
    let mut out = Vec::with_capacity(height);
    for r in 0..height {
        let start = r * stride;
        let end = start + width;
        if end > y.len() {
            break;
        }
        // One row hashed as a 1-row luma-only NV12 frame — reuses the proven NEON kernel.
        out.push(NeonFrameHash::hash_nv12(
            &y[start..end],
            width,
            width,
            1,
            &[],
            0,
        ));
    }
    out
}

/// Estimates the dominant VERTICAL content shift (in pixel rows) between two NV12 luma planes — the
/// host-side scroll measurement that drives client reprojection.
///
/// `prev_y` / `cur_y` are two same-dimensioned luma planes (the previous and current captured
/// frames); `prev_stride` / `cur_stride` their byte strides; `width` / `height` the visible luma
/// size in pixels; `max_shift` bounds the search (rows). On [`AISD_OK`], `*out_shift` is the dominant
/// shift (positive = content moved DOWN: row `i` now equals the previous frame's row `i - shift`)
/// and `*out_confidence_milli` is the match fraction ×1000 (`0..=1000`). The CALLER gates (e.g. fire
/// only when `confidence_milli >= 500 && shift != 0`).
///
/// Returns [`AISD_ERR_NULL`] for a null pointer. A degenerate dimension (`width`/`height` 0, a
/// `stride < width`, or a `stride * height` overflow) yields [`AISD_OK`] with shift 0 / confidence 0
/// — a non-fault "no measurement". Never panics across the boundary.
///
/// # Safety
/// `prev_y` / `cur_y` must each point to at least `stride * height` readable, initialized bytes that
/// stay valid for the call (borrowed — never retained or freed). `out_shift` /
/// `out_confidence_milli` must be writable. No input pointer is ever written through.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_estimate_scroll_shift_nv12(
    prev_y: *const u8,
    prev_stride: usize,
    cur_y: *const u8,
    cur_stride: usize,
    width: usize,
    height: usize,
    max_shift: usize,
    out_shift: *mut i32,
    out_confidence_milli: *mut u32,
) -> AisdStatus {
    if prev_y.is_null() || cur_y.is_null() || out_shift.is_null() || out_confidence_milli.is_null()
    {
        return AISD_ERR_NULL;
    }
    // Degenerate / absurd dims OR a hostile stride*height overflow ⇒ a defined "no measurement" (not a
    // fault). The 16384 ceiling (above any real display) HARD-GUARDS the `Vec::with_capacity(height)` in
    // `row_hashes` against a capacity-overflow panic if a caller ever passes a garbage dimension.
    let lens = if width == 0
        || height == 0
        || width > 16384
        || height > 16384
        || prev_stride < width
        || cur_stride < width
    {
        None
    } else {
        match (
            prev_stride.checked_mul(height),
            cur_stride.checked_mul(height),
        ) {
            (Some(p), Some(c)) => Some((p, c)),
            _ => None,
        }
    };
    let Some((prev_len, cur_len)) = lens else {
        // SAFETY: both out pointers are non-null (checked) and writable per the contract.
        unsafe {
            out_shift.write(0);
            out_confidence_milli.write(0);
        }
        return AISD_OK;
    };
    // SAFETY: per the contract each plane covers >= `stride * height` readable bytes (guarded above);
    // `slice_in` borrows exactly that many bytes read-only for the call.
    let prev = unsafe { slice_in(prev_y, prev_len) };
    let cur = unsafe { slice_in(cur_y, cur_len) };
    let prev_rows = row_hashes(prev, prev_stride, width, height);
    let cur_rows = row_hashes(cur, cur_stride, width, height);
    let est = estimate_vertical_shift(&prev_rows, &cur_rows, max_shift);
    // confidence ∈ [0, 1] (a fraction of informative rows) ⇒ milli ∈ [0, 1000]; the cast is bounded.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let milli = (est.confidence.clamp(0.0, 1.0) * 1000.0).round() as u32;
    // SAFETY: both out pointers are non-null (checked) and writable per the contract.
    unsafe {
        out_shift.write(est.shift);
        out_confidence_milli.write(milli);
    }
    AISD_OK
}

/// Adaptive per-frame QP ceiling from the inter-frame change magnitude.
///
/// NEON per-row hash + the pure [`changed_fraction`] / [`adaptive_max_qp`] core laws — drives "sharp
/// on a small change, blur graded by burst" (`AISLOPDESK_ADAPTIVE_QP`). The host calls this every
/// `.complete` frame with the previous (`cachedPixelBuffer`) and current luma planes and sets the
/// returned QP as the live frame's `MaxAllowedFrameQP` ceiling.
///
/// `qp_sharp` (low/sharp end, ≤ `qp_max`), `qp_max` (the configured live ceiling), and the band
/// `[b_lo_milli, b_hi_milli]` (change-fraction thresholds ×1000) parameterise the curve. On
/// [`AISD_OK`], `*out_qp` is the ceiling to apply and `*out_change_milli` the measured change
/// fraction ×1000 (for logging/telemetry). A null pointer ⇒ [`AISD_ERR_NULL`]; a degenerate/absurd
/// dimension or stride overflow ⇒ [`AISD_OK`] with `qp = qp_max` (no adaptive narrowing — the safe
/// "use the static ceiling" fallback) and `change = 0`. Never panics across the boundary.
///
/// # Safety
/// `prev_y` / `cur_y` must each cover ≥ `stride * height` readable bytes valid for the call
/// (borrowed, never retained/freed); `out_qp` / `out_change_milli` must be writable.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_adaptive_frame_qp_nv12(
    prev_y: *const u8,
    prev_stride: usize,
    cur_y: *const u8,
    cur_stride: usize,
    width: usize,
    height: usize,
    qp_sharp: u8,
    qp_max: u8,
    b_lo_milli: u32,
    b_hi_milli: u32,
    out_qp: *mut u8,
    out_change_milli: *mut u32,
) -> AisdStatus {
    if prev_y.is_null() || cur_y.is_null() || out_qp.is_null() || out_change_milli.is_null() {
        return AISD_ERR_NULL;
    }
    let lens = if width == 0
        || height == 0
        || width > 16384
        || height > 16384
        || prev_stride < width
        || cur_stride < width
    {
        None
    } else {
        match (
            prev_stride.checked_mul(height),
            cur_stride.checked_mul(height),
        ) {
            (Some(p), Some(c)) => Some((p, c)),
            _ => None,
        }
    };
    let Some((prev_len, cur_len)) = lens else {
        // Unmeasurable frame ⇒ no adaptive narrowing: apply the configured static ceiling.
        // SAFETY: both out pointers are non-null (checked) and writable per the contract.
        unsafe {
            out_qp.write(qp_max);
            out_change_milli.write(0);
        }
        return AISD_OK;
    };
    // SAFETY: each plane covers ≥ `stride * height` readable bytes (guarded); `slice_in` borrows
    // exactly that many bytes read-only for the call.
    let prev = unsafe { slice_in(prev_y, prev_len) };
    let cur = unsafe { slice_in(cur_y, cur_len) };
    let prev_rows = row_hashes(prev, prev_stride, width, height);
    let cur_rows = row_hashes(cur, cur_stride, width, height);
    let b = changed_fraction(&prev_rows, &cur_rows);
    let b_lo = f64::from(b_lo_milli) / 1000.0;
    let b_hi = f64::from(b_hi_milli) / 1000.0;
    let qp = adaptive_max_qp(b, qp_sharp, qp_max, b_lo, b_hi);
    // b ∈ [0, 1] ⇒ milli ∈ [0, 1000]; the cast is bounded.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let change_milli = (b.clamp(0.0, 1.0) * 1000.0).round() as u32;
    // SAFETY: both out pointers are non-null (checked) and writable per the contract.
    unsafe {
        out_qp.write(qp);
        out_change_milli.write(change_milli);
    }
    AISD_OK
}

#[cfg(test)]
mod tests {
    // The shift-construction loop cross-references cur[r] from prev[r - k], so a range index is
    // clearer than enumerate() here; `&mut x` out-params coerce to the C `*mut` (the ABI test idiom).
    #![allow(clippy::needless_range_loop, clippy::borrow_as_ptr)]
    use super::*;

    /// Build a synthetic luma plane: a uniform `bg` background with distinct "text" rows (each filled
    /// with a unique byte) at the given row indices, at the given stride.
    fn plane(stride: usize, width: usize, height: usize, bg: u8, text_rows: &[usize]) -> Vec<u8> {
        let mut v = vec![bg; stride * height];
        for (k, &r) in text_rows.iter().enumerate() {
            if r < height {
                let fill = 0x40u8.wrapping_add(k as u8 * 7).wrapping_add(1);
                for c in 0..width {
                    v[r * stride + c] = fill;
                }
            }
        }
        v
    }

    #[test]
    fn null_pointers_return_null_status() {
        let mut s = 0i32;
        let mut c = 0u32;
        let st = unsafe {
            aisd_estimate_scroll_shift_nv12(
                core::ptr::null(),
                16,
                core::ptr::null(),
                16,
                16,
                16,
                4,
                &mut s,
                &mut c,
            )
        };
        assert_eq!(st, AISD_ERR_NULL);
    }

    #[test]
    fn degenerate_dims_are_no_measurement_not_fault() {
        let y = [0u8; 64];
        let mut s = 9i32;
        let mut c = 9u32;
        // stride < width.
        let st = unsafe {
            aisd_estimate_scroll_shift_nv12(y.as_ptr(), 4, y.as_ptr(), 4, 8, 2, 4, &mut s, &mut c)
        };
        assert_eq!(st, AISD_OK);
        assert_eq!((s, c), (0, 0));
    }

    #[test]
    fn detects_a_real_vertical_scroll() {
        let (w, h, stride) = (32usize, 80usize, 40usize);
        let prev = plane(stride, w, h, 0x10, &[10, 20, 30, 40, 50]);
        // cur = prev shifted DOWN by 6 rows.
        let mut cur = vec![0x10u8; stride * h];
        for r in 0..h {
            let src = r as isize - 6;
            if src >= 0 {
                let s = src as usize;
                cur[r * stride..r * stride + w].copy_from_slice(&prev[s * stride..s * stride + w]);
            }
        }
        let mut shift = 0i32;
        let mut conf = 0u32;
        let st = unsafe {
            aisd_estimate_scroll_shift_nv12(
                prev.as_ptr(),
                stride,
                cur.as_ptr(),
                stride,
                w,
                h,
                40,
                &mut shift,
                &mut conf,
            )
        };
        assert_eq!(st, AISD_OK);
        assert_eq!(shift, 6, "dominant downward scroll of 6 rows");
        assert!(conf > 700, "confident (conf milli {conf})");
    }

    #[test]
    fn static_frame_is_shift_zero() {
        let (w, h, stride) = (32usize, 64usize, 32usize);
        let prev = plane(stride, w, h, 0x20, &[5, 15, 25, 35]);
        let cur = prev.clone();
        let mut shift = 9i32;
        let mut conf = 0u32;
        let st = unsafe {
            aisd_estimate_scroll_shift_nv12(
                prev.as_ptr(),
                stride,
                cur.as_ptr(),
                stride,
                w,
                h,
                20,
                &mut shift,
                &mut conf,
            )
        };
        assert_eq!(st, AISD_OK);
        assert_eq!(shift, 0, "no scroll ⇒ shift 0");
    }

    #[test]
    fn large_realistic_dims_do_not_crash() {
        // Reproduce the host's real capture dims (2× VD luma planes) + padded strides — the path that
        // panicked "capacity overflow" live.
        for &(w, h) in &[(1920usize, 1080usize), (2880, 1800), (3840, 2160)] {
            for pad in [0usize, 64, 256] {
                let stride = w + pad;
                let prev = vec![0x30u8; stride * h];
                let cur = vec![0x31u8; stride * h];
                let mut shift = 0i32;
                let mut conf = 0u32;
                let st = unsafe {
                    aisd_estimate_scroll_shift_nv12(
                        prev.as_ptr(),
                        stride,
                        cur.as_ptr(),
                        stride,
                        w,
                        h,
                        (h / 4).max(8),
                        &mut shift,
                        &mut conf,
                    )
                };
                assert_eq!(st, AISD_OK, "w={w} h={h} pad={pad}");
            }
        }
    }

    #[test]
    fn adaptive_qp_static_sharp_burst_max() {
        let (w, h, stride) = (32usize, 64usize, 32usize);
        let prev = plane(stride, w, h, 0x20, &[5, 15, 25, 35]);
        let mut qp = 0u8;
        let mut chg = 9u32;
        // Static (identical) → change 0 → qp_sharp.
        let st = unsafe {
            aisd_adaptive_frame_qp_nv12(
                prev.as_ptr(),
                stride,
                prev.as_ptr(),
                stride,
                w,
                h,
                22,
                34,
                20,
                300,
                &mut qp,
                &mut chg,
            )
        };
        assert_eq!(st, AISD_OK);
        assert_eq!((qp, chg), (22, 0), "static frame → sharp ceiling");
        // Whole frame different → change 1.0 → qp_max.
        let burst = plane(stride, w, h, 0x70, &[]);
        let st2 = unsafe {
            aisd_adaptive_frame_qp_nv12(
                prev.as_ptr(),
                stride,
                burst.as_ptr(),
                stride,
                w,
                h,
                22,
                34,
                20,
                300,
                &mut qp,
                &mut chg,
            )
        };
        assert_eq!(st2, AISD_OK);
        assert_eq!(qp, 34, "big burst → max ceiling");
        assert!(chg > 500, "change milli {chg}");
    }

    #[test]
    fn adaptive_qp_null_and_degenerate() {
        let mut qp = 7u8;
        let mut chg = 7u32;
        assert_eq!(
            unsafe {
                aisd_adaptive_frame_qp_nv12(
                    core::ptr::null(),
                    16,
                    core::ptr::null(),
                    16,
                    16,
                    16,
                    22,
                    34,
                    20,
                    300,
                    &mut qp,
                    &mut chg,
                )
            },
            AISD_ERR_NULL
        );
        let y = [0u8; 64];
        // Degenerate (stride < width) → qp_max (no narrowing) + change 0, not a fault.
        let st = unsafe {
            aisd_adaptive_frame_qp_nv12(
                y.as_ptr(),
                4,
                y.as_ptr(),
                4,
                8,
                2,
                22,
                34,
                20,
                300,
                &mut qp,
                &mut chg,
            )
        };
        assert_eq!(st, AISD_OK);
        assert_eq!((qp, chg), (34, 0));
    }
}
