//! The window RECORD every window-reading door speaks, and the display pick over a list of them.
//!
//! The record lives here rather than beside the macOS-only reader that fills it, because two doors
//! on opposite sides of the `TARGET_OS_OSX` guard pass the same four fields:
//! `slopdesk_cgwindow_in_front_of` answers them, and `slopdesk_capture_*` consumes them. Declaring
//! the layout twice is how a field reorder ships as green tests and a scrambled capture region.

use slopdesk_video::window_list::display_for_window_frame;

use crate::borrow;
use crate::video_policy::SlopDeskVideoRect;

/// One on-screen window, as the window server described it.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskWindowRecord {
    /// The frame in CG global points, top-left origin.
    pub bounds: SlopDeskVideoRect,
    /// The `CGWindowID`. Per-boot and reusable, so it names a window only with `owner_pid`.
    pub window_id: u32,
    /// The owning process.
    pub owner_pid: i32,
    /// The CG window level: `0` an ordinary window, `101` a pop-up menu, `24` the menu bar.
    pub layer: i32,
}

/// The display a window sits on: the one containing its centre, else the largest. `false` — there
/// are no displays at all — leaves `*out` untouched.
///
/// # Safety
/// `displays` must be null, or point to `count` initialised [`SlopDeskVideoRect`] for the call.
/// `out` must be null, or writable for one [`SlopDeskVideoRect`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_display_for_frame(
    frame: SlopDeskVideoRect,
    displays: *const SlopDeskVideoRect,
    count: usize,
    out: *mut SlopDeskVideoRect,
) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation above is restated on `borrow`.
    let lent = unsafe { borrow(displays, count) };
    let rects: Vec<_> = lent.iter().map(|rect| rect.of()).collect();
    let Some(display) = display_for_window_frame(frame.of(), &rects) else {
        return false;
    };
    // SAFETY: non-null was checked, and by the caller's obligation it is writable for one record
    // for this call. The value written is a plain `Copy` scalar record built here.
    unsafe { out.write(SlopDeskVideoRect::from(display)) };
    true
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the C ABI the way Swift does is the thing under test"
    )]
    #![expect(
        clippy::float_cmp,
        reason = "these are exact scalars the door copied, so exact equality is the assertion"
    )]

    use super::{SlopDeskVideoRect, slopdesk_window_display_for_frame};

    const fn rect(x: f64, y: f64, width: f64, height: f64) -> SlopDeskVideoRect {
        SlopDeskVideoRect { x, y, width, height }
    }

    #[test]
    fn the_display_under_the_window_centre_comes_back_through_the_door() {
        let displays = [rect(0.0, 0.0, 1920.0, 1080.0), rect(1920.0, 0.0, 3840.0, 2160.0)];
        let mut out = SlopDeskVideoRect::default();
        // SAFETY: both buffers are live locals of exactly the lengths declared.
        let found = unsafe {
            slopdesk_window_display_for_frame(
                rect(2400.0, 300.0, 1040.0, 700.0),
                displays.as_ptr(),
                displays.len(),
                &raw mut out,
            )
        };
        assert!(found);
        assert_eq!(out.x, 1920.0);
        assert_eq!(out.width, 3840.0);
    }

    /// No displays is `false` and an untouched buffer — the caller then reports the window's own
    /// size as the resize ceiling rather than a zero one nobody could resize to.
    #[test]
    fn an_empty_display_list_leaves_the_buffer_alone() {
        let mut out = rect(7.0, 7.0, 7.0, 7.0);
        // SAFETY: a null list with a zero count is one of the shapes the door documents.
        let found = unsafe {
            slopdesk_window_display_for_frame(
                rect(0.0, 0.0, 100.0, 100.0),
                core::ptr::null(),
                0,
                &raw mut out,
            )
        };
        assert!(!found);
        assert_eq!(out.x, 7.0);
    }

    #[test]
    fn a_null_out_is_refused_before_anything_is_read() {
        // SAFETY: null is one of the two shapes the door documents for `out`.
        assert!(!unsafe {
            slopdesk_window_display_for_frame(
                rect(0.0, 0.0, 100.0, 100.0),
                core::ptr::null(),
                0,
                core::ptr::null_mut(),
            )
        });
    }
}
