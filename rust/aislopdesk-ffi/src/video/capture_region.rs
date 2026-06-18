//! `capture_region`: pure, flat-struct (dialog-expand capture math; AX-event-driven).

use super::AisdRect;
use aislopdesk_core::capture_region;
use aislopdesk_core::geometry::VideoRect;

/// One window snapshot (`CGWindowListCopyWindowInfo` row) for capture-region math, flattened
/// for the C ABI. `frame` is the window's global bounds.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct AisdCaptureWindowSnapshot {
    /// `kCGWindowNumber`.
    pub window_id: u32,
    /// `kCGWindowOwnerPID`.
    pub owner_pid: i32,
    /// `kCGWindowLayer`.
    pub layer: i64,
    /// Global window bounds.
    pub frame: AisdRect,
}

impl AisdCaptureWindowSnapshot {
    const fn to_core(self) -> capture_region::WindowSnapshot {
        capture_region::WindowSnapshot::new(
            self.window_id,
            self.owner_pid,
            self.layer,
            self.frame.to_core(),
        )
    }
}

/// The capture union region: the target window unioned with qualifying same-pid panels in
/// front of it, clamped to the display. Wraps [`capture_region::union_region`].
///
/// `windows_in_front` is borrowed for the call only. Pass
/// [`capture_region::DEFAULT_MIN_OVERLAP_FRACTION`] (`0.30`) for `min_overlap_fraction`.
///
/// # Safety
/// If `windows_count != 0`, `windows_in_front` must point to at least `windows_count`
/// readable [`AisdCaptureWindowSnapshot`] values.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_capture_union_region(
    target_frame: AisdRect,
    target_window_id: u32,
    target_pid: i32,
    windows_in_front: *const AisdCaptureWindowSnapshot,
    windows_count: usize,
    display_bounds: AisdRect,
    min_overlap_fraction: f64,
) -> AisdRect {
    let core_windows: Vec<capture_region::WindowSnapshot> =
        if windows_count == 0 || windows_in_front.is_null() {
            Vec::new()
        } else {
            // SAFETY: `windows_in_front` is non-null per the guard and covers `windows_count`
            // readable `AisdCaptureWindowSnapshot` values per the contract.
            unsafe { core::slice::from_raw_parts(windows_in_front, windows_count) }
                .iter()
                .map(|w| w.to_core())
                .collect()
        };
    AisdRect::from_core(capture_region::union_region(
        target_frame.to_core(),
        target_window_id,
        target_pid,
        &core_windows,
        display_bounds.to_core(),
        min_overlap_fraction,
    ))
}

/// The OPAQUE content rectangles of the capture region (window frame + qualifying popups).
///
/// The target window frame + each qualifying same-pid popup in front of it, every rect clamped to
/// the display. Wraps [`capture_region::content_rects`] — the per-rect form the client masks the
/// black flank with.
///
/// CALLER-ARENA: fills up to `out_cap` rects into the caller-owned `out_rects` buffer and returns
/// the TOTAL count (so the caller can tell it was truncated). The caller reads
/// `min(returned, out_cap)` rects; nothing is heap-allocated or needs freeing. `windows_in_front`
/// is borrowed for the call only. Pass [`capture_region::DEFAULT_MIN_OVERLAP_FRACTION`] (`0.30`).
///
/// # Safety
/// If `windows_count != 0`, `windows_in_front` must point to `windows_count` readable
/// [`AisdCaptureWindowSnapshot`] values; if `out_cap != 0`, `out_rects` must point to `out_cap`
/// writable [`AisdRect`] values.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_capture_content_rects(
    target_frame: AisdRect,
    target_window_id: u32,
    target_pid: i32,
    windows_in_front: *const AisdCaptureWindowSnapshot,
    windows_count: usize,
    display_bounds: AisdRect,
    min_overlap_fraction: f64,
    out_rects: *mut AisdRect,
    out_cap: usize,
) -> usize {
    let core_windows: Vec<capture_region::WindowSnapshot> =
        if windows_count == 0 || windows_in_front.is_null() {
            Vec::new()
        } else {
            // SAFETY: `windows_in_front` is non-null per the guard and covers `windows_count`
            // readable `AisdCaptureWindowSnapshot` values per the contract.
            unsafe { core::slice::from_raw_parts(windows_in_front, windows_count) }
                .iter()
                .map(|w| w.to_core())
                .collect()
        };
    let rects = capture_region::content_rects(
        target_frame.to_core(),
        target_window_id,
        target_pid,
        &core_windows,
        display_bounds.to_core(),
        min_overlap_fraction,
    );
    if !out_rects.is_null() && out_cap > 0 {
        let n = rects.len().min(out_cap);
        // SAFETY: `out_rects` covers `out_cap` writable `AisdRect` per the contract; `n <= out_cap`.
        let out = unsafe { core::slice::from_raw_parts_mut(out_rects, n) };
        for (slot, r) in out.iter_mut().zip(rects.iter()) {
            *slot = AisdRect::from_core(*r);
        }
    }
    rects.len()
}

/// Hysteresis gate for capture retargeting.
///
/// Returns `1` if `desired` differs from `current` by more than `min_delta` on any edge, else
/// `0`. Wraps [`capture_region::should_retarget`]. Pass [`capture_region::DEFAULT_MIN_DELTA`]
/// (`8.0`) for `min_delta`. Pure; never fails.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_capture_should_retarget(
    current: AisdRect,
    desired: AisdRect,
    min_delta: f64,
) -> u8 {
    u8::from(capture_region::should_retarget(
        current.to_core(),
        desired.to_core(),
        min_delta,
    ))
}

/// Whether a geometry change should re-origin capture to the plain window frame.
///
/// Returns `1` when no union region is active (`active_region_is_null != 0`), else `0`. Wraps
/// [`capture_region::should_reorigin_to_window_on_geometry`]. Pure; never fails.
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_capture_reorigin_on_geometry(active_region_is_null: u8) -> u8 {
    let active = if active_region_is_null != 0 {
        None
    } else {
        Some(VideoRect::xywh(0.0, 0.0, 0.0, 0.0))
    };
    u8::from(capture_region::should_reorigin_to_window_on_geometry(
        active,
    ))
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions and exact float round-trip checks.
    #![allow(clippy::borrow_as_ptr, clippy::float_cmp)]
    use super::*;

    #[test]
    fn capture_union_region_matches_core() {
        let target = AisdRect {
            x: 100.0,
            y: 100.0,
            width: 800.0,
            height: 600.0,
        };
        let display = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        // A same-pid panel overlapping the target in front of it extends the union.
        let front = [AisdCaptureWindowSnapshot {
            window_id: 2,
            owner_pid: 42,
            layer: 0,
            frame: AisdRect {
                x: 700.0,
                y: 100.0,
                width: 400.0,
                height: 300.0,
            },
        }];
        let got =
            unsafe { aisd_capture_union_region(target, 1, 42, front.as_ptr(), 1, display, 0.30) };
        let core = capture_region::union_region(
            target.to_core(),
            1,
            42,
            &[front[0].to_core()],
            display.to_core(),
            0.30,
        );
        assert_eq!(got.x.to_bits(), core.origin.x.to_bits());
        assert_eq!(got.width.to_bits(), core.size.width.to_bits());
        // Empty windows list → just the target (clamped to display).
        let none = unsafe {
            aisd_capture_union_region(target, 1, 42, core::ptr::null(), 0, display, 0.30)
        };
        assert_eq!(none.width.to_bits(), target.width.to_bits());
    }

    #[test]
    fn capture_content_rects_fills_caller_arena() {
        let target = AisdRect {
            x: 0.0,
            y: 30.0,
            width: 1440.0,
            height: 900.0,
        };
        let display = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
        };
        // A same-pid pop-up menu (layer 101) overhanging the window bottom.
        let front = [AisdCaptureWindowSnapshot {
            window_id: 4215,
            owner_pid: 42,
            layer: 101,
            frame: AisdRect {
                x: 48.0,
                y: 733.0,
                width: 269.0,
                height: 283.0,
            },
        }];
        let mut buf = [AisdRect {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        }; 8];
        let n = unsafe {
            aisd_capture_content_rects(
                target,
                983,
                42,
                front.as_ptr(),
                1,
                display,
                0.30,
                buf.as_mut_ptr(),
                buf.len(),
            )
        };
        assert_eq!(n, 2, "window + popup");
        assert_eq!(buf[0].width.to_bits(), 1440.0_f64.to_bits());
        assert_eq!(buf[1].x.to_bits(), 48.0_f64.to_bits());
        assert_eq!(buf[1].height.to_bits(), 283.0_f64.to_bits());
        // Truncation: cap 1 returns total 2 but writes only the window.
        let n2 = unsafe {
            aisd_capture_content_rects(
                target,
                983,
                42,
                front.as_ptr(),
                1,
                display,
                0.30,
                buf.as_mut_ptr(),
                1,
            )
        };
        assert_eq!(n2, 2, "returns the TOTAL even when truncated");
    }

    #[test]
    fn capture_retarget_and_reorigin_match_core() {
        let a = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        };
        let b = AisdRect {
            x: 0.0,
            y: 0.0,
            width: 120.0,
            height: 100.0,
        }; // +20 width > 8
        assert_eq!(aisd_capture_should_retarget(a, b, 8.0), 1);
        assert_eq!(aisd_capture_should_retarget(a, a, 8.0), 0);
        assert_eq!(aisd_capture_reorigin_on_geometry(1), 1); // no active region → reorigin
        assert_eq!(aisd_capture_reorigin_on_geometry(0), 0); // active union → hold
    }
}
