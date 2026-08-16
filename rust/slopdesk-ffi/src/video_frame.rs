//! The three measurements the capture path takes on a frame it has just locked.
//!
//! One value per frame says whether it is a re-delivery of the last one ([`crate::video_frame`]'s
//! hash); two more compare it with its predecessor and say how far the picture scrolled and how
//! much of it changed. All three read the same locked planes, all three answer a scalar, and none
//! of them copies a pixel: an `IOSurface` mapping is up to eight megabytes per frame at 60 Hz, and
//! copying it to measure it would cost more than the measurement.
//!
//! ## Why the planes cross as pointers and not as bytes
//! Every other door here takes bytes Swift already owns. These take an address inside a mapping
//! Core Video locked for the duration of the call, because that is the only form the pixels have —
//! there is no `Data` to lend. The obligation is the same one, and it is discharged the same way:
//! `CVPixelBufferLockBaseAddress` brackets the call, exactly as `withUnsafeBytes` does elsewhere.
//! What this module adds is the arithmetic that turns a base address and a stride into a length,
//! done with `checked_mul` on this side, so a hostile or absurd stride is a defined "no
//! measurement" rather than a read past the mapping.
//!
//! ## What is NOT decided here
//! Whether a confidence is good enough to reproject on, whether a change fraction is a scroll, what
//! a sentinel hash should make the caller do. Those live in `slopdesk-video`, which forbids unsafe.
//! This module converts an address to a slice, and an estimate to a `#[repr(C)]` record.

use core::ffi::c_uchar;

use slopdesk_video::adaptive_qp::{QpCurve, compute_nv12};
use slopdesk_video::frame_hash::{LumaPlane, SENTINEL, hash_nv12};
use slopdesk_video::scroll_shift::estimate_nv12;

use crate::borrow;

/// One captured luma or chroma plane as it crosses: where its first row starts, and how far apart
/// the rows are.
///
/// The two travel together because neither means anything alone — a plane read at another plane's
/// stride is the whole class of bug the port removes, and a pair that cannot be split cannot be
/// mismatched at a call site.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SlopDeskLumaPlane {
    /// The plane's first byte, or null for "there is no plane".
    pub base: *const c_uchar,
    /// Bytes from the start of one row to the start of the next.
    pub stride: usize,
}

/// The two planes a frame-difference measurement compares, and the picture both are read at.
///
/// `width` and `height` are the VISIBLE dimensions, which is why they sit here rather than in the
/// plane: the two planes may be padded differently and are still the same picture.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SlopDeskLumaPair {
    /// The previous frame's luma plane.
    pub prev: SlopDeskLumaPlane,
    /// The frame just captured.
    pub cur: SlopDeskLumaPlane,
    /// Visible pixels per row.
    pub width: usize,
    /// Visible rows.
    pub height: usize,
}

/// What one scroll measurement produced, laid out for Swift to read straight through.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskScrollEstimate {
    /// The dominant vertical shift in rows; positive means the content moved DOWN.
    pub shift: i32,
    /// The confidence in thousandths, `0..=1000`. The caller's gate reads this.
    pub confidence_milli: u32,
    /// The first current-frame row of the moving band, or `-1` for "no band".
    pub band_top: i32,
    /// The last current-frame row of the moving band (inclusive), or `-1`.
    pub band_bottom: i32,
}

impl SlopDeskScrollEstimate {
    /// The answer to an unmeasurable pair: no shift, no confidence, and no band to reproject.
    ///
    /// `-1` rather than `0` for the band, because row zero is a real row: a caller cannot tell an
    /// absent band from one that begins at the top of the frame if both are spelled `0`.
    const NONE: Self = Self {
        shift: 0,
        confidence_milli: 0,
        band_top: -1,
        band_bottom: -1,
    };
}

/// What one adaptive-QP measurement produced.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskQpDecision {
    /// The per-frame `MaxAllowedFrameQP` ceiling to set.
    pub qp: u8,
    /// The measured change fraction ×1000, for the log rather than for the encoder.
    pub change_milli: u32,
}

/// The value a guarded-out hash answers instead of a hash.
///
/// Vended rather than spelled on the Swift side: a second `UInt64.max` there would be a second
/// place to decide what "no measurement" is, and the comparison against it is the frame-suppression
/// decision itself.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_video_frame_hash_sentinel() -> u64 {
    SENTINEL
}

/// Hashes one locked NV12 frame's luma and interleaved-chroma planes into a single 64-bit value.
///
/// Reads only the first `width` bytes of each `*_stride`-spaced row, so the value depends on the
/// picture and not on how the capture stack padded it. Answers
/// [`slopdesk_video_frame_hash_sentinel`] for a null luma plane, a degenerate dimension, a stride
/// narrower than the width, or a `stride * height` that overflows. A null `cbcr` — or one whose
/// implied length overflows — hashes luma only, which is a weaker but still valid answer.
///
/// # Safety
/// `y` must be null or point to `y_stride * height` readable bytes, and `cbcr` must be null or
/// point to `cbcr_stride * (height / 2)` readable bytes, both live for the whole call. Core Video's
/// lock around the call is what makes that true at the only call site.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_frame_hash_nv12(
    y: *const c_uchar,
    y_stride: usize,
    width: usize,
    height: usize,
    cbcr: *const c_uchar,
    cbcr_stride: usize,
) -> u64 {
    // SAFETY: the caller's obligation above, discharged by the pixel-buffer lock at the call site.
    let Some(luma) = (unsafe { plane_bytes(y, y_stride, height) }) else {
        return SENTINEL;
    };
    // NV12 chroma is half the luma height; an absent or absurd chroma plane is luma-only rather
    // than a refusal, because a luma-only hash still distinguishes the frames it is compared with.
    let chroma_rows = height.checked_div(2).unwrap_or(0);
    // SAFETY: as above, for the second plane.
    let chroma = unsafe { plane_bytes(cbcr, cbcr_stride, chroma_rows) };
    hash_nv12(luma, y_stride, width, height, chroma, cbcr_stride)
}

/// Estimates the dominant vertical content shift between two locked luma planes.
///
/// `quantize_shift` (`0..=7`) right-shifts every luma byte before the row hash, so capture noise
/// stops breaking the exact row match; `0` is the byte-for-byte path. An unmeasurable pair answers
/// [`SlopDeskScrollEstimate::NONE`], which is a defined result and not a fault.
///
/// # Safety
/// Each plane in `pair` must be null or point to `stride * height` readable bytes, live for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_scroll_nv12(
    pair: SlopDeskLumaPair,
    max_shift: usize,
    quantize_shift: u8,
) -> SlopDeskScrollEstimate {
    // SAFETY: the caller's obligation above, discharged by the pixel-buffer locks at the call site.
    let Some((prev, cur)) = (unsafe { planes(pair) }) else {
        return SlopDeskScrollEstimate::NONE;
    };
    let estimate = estimate_nv12(prev, cur, pair.width, pair.height, max_shift, quantize_shift);
    let (band_top, band_bottom) = estimate
        .band
        .map_or((-1, -1), |(top, bottom)| (row_index(top), row_index(bottom)));
    SlopDeskScrollEstimate {
        shift: estimate.shift,
        confidence_milli: estimate.confidence_milli(),
        band_top,
        band_bottom,
    }
}

/// The per-frame QP ceiling implied by how much of the picture changed between two locked planes.
///
/// `b_lo_milli` and `b_hi_milli` are the change-fraction thresholds ×1000: below the first the
/// ceiling is `qp_sharp`, above the second it is `qp_max`, and between them it ramps. An
/// unmeasurable pair answers `(qp_max, 0)` — the configured static ceiling, applied unnarrowed,
/// which is the safe fallback rather than a guess.
///
/// # Safety
/// Each plane in `pair` must be null or point to `stride * height` readable bytes, live for the
/// whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_adaptive_qp_nv12(
    pair: SlopDeskLumaPair,
    qp_sharp: u8,
    qp_max: u8,
    b_lo_milli: u32,
    b_hi_milli: u32,
) -> SlopDeskQpDecision {
    let curve = QpCurve {
        qp_sharp,
        qp_max,
        b_lo_milli,
        b_hi_milli,
    };
    // SAFETY: the caller's obligation above, discharged by the pixel-buffer locks at the call site.
    let Some((prev, cur)) = (unsafe { planes(pair) }) else {
        return SlopDeskQpDecision {
            qp: qp_max,
            change_milli: 0,
        };
    };
    let decision = compute_nv12(prev, cur, pair.width, pair.height, curve);
    SlopDeskQpDecision {
        qp: decision.qp,
        change_milli: decision.change_milli,
    }
}

/// A row index as the ABI carries it, or `-1` for one no `i32` can hold.
///
/// A band that cannot be spelled is reported as no band, which the caller already handles: it falls
/// back to warping the whole frame, and a whole-frame warp is never wrong, only less precise.
fn row_index(row: usize) -> i32 {
    i32::try_from(row).unwrap_or(-1)
}

/// Borrows one plane as `stride * rows` bytes, or `None` when there is nothing there to read.
///
/// The `checked_mul` is the whole point: `stride` and `rows` arrive from a capture stack, and their
/// product is the only number that says how far the mapping may be walked.
///
/// # Safety
/// `base` must be null or point to `stride * rows` readable bytes, live for the whole call.
#[expect(
    unsafe_code,
    reason = "turning the caller's base address into a slice IS this module's boundary"
)]
const unsafe fn plane_bytes<'a>(base: *const c_uchar, stride: usize, rows: usize) -> Option<&'a [u8]> {
    if base.is_null() || stride == 0 || rows == 0 {
        return None;
    }
    let Some(len) = stride.checked_mul(rows) else {
        return None;
    };
    // SAFETY: the caller's obligation above; `len` is exactly the product just checked.
    Some(unsafe { borrow(base, len) })
}

/// Borrows both planes of a pair, or `None` when either is unreadable.
///
/// Both or neither: a measurement that compares one real plane against an absent one would be
/// comparing the frame with nothing and calling the result a change.
///
/// # Safety
/// Each plane must satisfy [`plane_bytes`]'s obligation.
#[expect(
    unsafe_code,
    reason = "the pair is two of the same borrow, and the obligation is the same one twice"
)]
const unsafe fn planes<'a>(pair: SlopDeskLumaPair) -> Option<(LumaPlane<'a>, LumaPlane<'a>)> {
    // SAFETY: the caller's obligation above, for each plane in turn.
    let (Some(prev), Some(cur)) = (unsafe {
        (
            plane_bytes(pair.prev.base, pair.prev.stride, pair.height),
            plane_bytes(pair.cur.base, pair.cur.stride, pair.height),
        )
    }) else {
        return None;
    };
    Some((
        LumaPlane::new(prev, pair.prev.stride),
        LumaPlane::new(cur, pair.cur.stride),
    ))
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for"
)]
mod tests {
    use slopdesk_video::frame_hash::{FRAME_HASH_SEED, hash_run};

    use super::{
        SlopDeskLumaPair, SlopDeskLumaPlane, SlopDeskScrollEstimate, slopdesk_video_adaptive_qp_nv12,
        slopdesk_video_frame_hash_nv12, slopdesk_video_frame_hash_sentinel, slopdesk_video_scroll_nv12,
    };

    /// A plane whose row `r` is filled with the byte `r + tint`, so rows are distinguishable and a
    /// vertical shift is a shift of the fill values.
    fn ramp(width: usize, height: usize, tint: u8) -> Vec<u8> {
        (0..height)
            .flat_map(|row| {
                let value = u8::try_from(row % 251).unwrap_or(0).wrapping_add(tint);
                std::iter::repeat_n(value, width)
            })
            .collect()
    }

    fn plane(bytes: &[u8], stride: usize) -> SlopDeskLumaPlane {
        SlopDeskLumaPlane {
            base: bytes.as_ptr(),
            stride,
        }
    }

    fn pair(prev: &[u8], cur: &[u8], width: usize, height: usize) -> SlopDeskLumaPair {
        SlopDeskLumaPair {
            prev: plane(prev, width),
            cur: plane(cur, width),
            width,
            height,
        }
    }

    #[test]
    fn a_null_plane_hashes_to_the_sentinel_rather_than_faulting() {
        let sentinel = slopdesk_video_frame_hash_sentinel();
        assert_eq!(sentinel, u64::MAX);
        // SAFETY: a null plane is the documented "nothing to read" input.
        let hashed =
            unsafe { slopdesk_video_frame_hash_nv12(std::ptr::null(), 16, 16, 16, std::ptr::null(), 0) };
        assert_eq!(hashed, sentinel);
    }

    #[test]
    fn an_overflowing_stride_is_a_sentinel_and_not_a_read() {
        let bytes = ramp(8, 8, 0);
        // SAFETY: the pointer is live; the product `stride * height` is what overflows, and the
        // entry must answer before it is used to bound a read.
        let hashed =
            unsafe { slopdesk_video_frame_hash_nv12(bytes.as_ptr(), usize::MAX, 8, 8, std::ptr::null(), 0) };
        assert_eq!(hashed, slopdesk_video_frame_hash_sentinel());
    }

    #[test]
    fn the_luma_only_hash_is_the_rows_folded_in_order() {
        let width = 8;
        let height = 4;
        let bytes = ramp(width, height, 0);
        // SAFETY: `bytes` holds exactly `width * height` readable bytes for the call.
        let hashed = unsafe {
            slopdesk_video_frame_hash_nv12(bytes.as_ptr(), width, width, height, std::ptr::null(), 0)
        };
        assert_ne!(hashed, slopdesk_video_frame_hash_sentinel());
        // The same picture behind a wider stride hashes equal: padding is not part of the picture.
        let padded_stride = width + 5;
        let mut padded = vec![0xAA; padded_stride * height];
        for row in 0..height {
            let start = row * padded_stride;
            padded[start..start + width].copy_from_slice(&bytes[row * width..row * width + width]);
        }
        // SAFETY: `padded` holds exactly `padded_stride * height` readable bytes for the call.
        let from_padded = unsafe {
            slopdesk_video_frame_hash_nv12(padded.as_ptr(), padded_stride, width, height, std::ptr::null(), 0)
        };
        assert_eq!(hashed, from_padded);
        // And a one-byte change anywhere in the visible area moves it.
        let mut altered = bytes;
        altered[width * 2 + 3] ^= 0x01;
        // SAFETY: as above.
        let changed = unsafe {
            slopdesk_video_frame_hash_nv12(altered.as_ptr(), width, width, height, std::ptr::null(), 0)
        };
        assert_ne!(hashed, changed);
        // A single-row plane is one row hashed at the frame seed, which pins the fold's entry.
        let one_row = ramp(width, 1, 0);
        // SAFETY: `one_row` holds `width` readable bytes for the call.
        let single =
            unsafe { slopdesk_video_frame_hash_nv12(one_row.as_ptr(), width, width, 1, std::ptr::null(), 0) };
        assert_eq!(single, hash_run(&one_row, FRAME_HASH_SEED));
    }

    #[test]
    fn a_clean_scroll_crosses_as_a_shift_a_confidence_and_a_band() {
        let width = 8;
        let height = 32;
        let prev = ramp(width, height, 0);
        // The current frame is the previous one moved DOWN by two rows.
        let mut cur = vec![0_u8; width * height];
        for row in 2..height {
            let source = (row - 2) * width;
            cur[row * width..row * width + width].copy_from_slice(&prev[source..source + width]);
        }
        // SAFETY: both planes hold exactly `width * height` readable bytes for the call.
        let estimate = unsafe { slopdesk_video_scroll_nv12(pair(&prev, &cur, width, height), 8, 0) };
        assert_eq!(estimate.shift, 2);
        assert_eq!(estimate.confidence_milli, 1000);
        assert!(estimate.band_top >= 0 && estimate.band_bottom >= estimate.band_top);
    }

    #[test]
    fn an_unmeasurable_pair_is_the_none_estimate_and_the_static_ceiling() {
        let bytes = ramp(8, 8, 0);
        let mut broken = pair(&bytes, &bytes, 8, 8);
        broken.prev.base = std::ptr::null();
        // SAFETY: a null plane is the documented "nothing to read" input.
        let estimate = unsafe { slopdesk_video_scroll_nv12(broken, 4, 0) };
        assert_eq!(estimate, SlopDeskScrollEstimate::NONE);
        // SAFETY: as above.
        let decision = unsafe { slopdesk_video_adaptive_qp_nv12(broken, 20, 44, 10, 200) };
        assert_eq!(decision.qp, 44);
        assert_eq!(decision.change_milli, 0);
    }

    #[test]
    fn an_unchanged_frame_stays_sharp_and_a_replaced_one_does_not() {
        let width = 8;
        let height = 16;
        let same = ramp(width, height, 0);
        // SAFETY: both planes hold exactly `width * height` readable bytes for the call.
        let quiet =
            unsafe { slopdesk_video_adaptive_qp_nv12(pair(&same, &same, width, height), 20, 44, 10, 200) };
        assert_eq!(quiet.qp, 20);
        assert_eq!(quiet.change_milli, 0);

        let replaced = ramp(width, height, 37);
        // SAFETY: as above.
        let burst = unsafe {
            slopdesk_video_adaptive_qp_nv12(pair(&same, &replaced, width, height), 20, 44, 10, 200)
        };
        assert_eq!(burst.qp, 44);
        assert_eq!(burst.change_milli, 1000);
    }
}
