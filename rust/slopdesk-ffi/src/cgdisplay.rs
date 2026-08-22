//! The display-list doors — macOS only, for the reason `inject` is.
//!
//! `rust/slopdesk-apple-cgdisplay` asks Quartz; nothing here decides anything. Every rect is CG
//! global points, top-left origin — the space `kCGWindowBounds` and the Accessibility API share,
//! and NOT `NSScreen.frame`'s.
//!
//! ## What these replaced
//!
//! Three Swift call sites that each ran the same two-call enumeration by hand — the resize
//! display-pick, the feed's display ordinals, and the parked-window restore's "does this intersect
//! any display at all". Two of the three sized their buffer from a first counting call and one
//! hard-coded sixteen.

use slopdesk_apple_cgdisplay::{active, bounds_of, online, under};
use slopdesk_video::geometry::VideoPoint;

use crate::spill;
use crate::video_policy::SlopDeskVideoRect;

/// One display, as the capture path needs it.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct SlopDeskCGDisplay {
    /// The bounds in CG global points, top-left origin.
    pub bounds: SlopDeskVideoRect,
    /// The `CGDirectDisplayID`, which is how `SCShareableContent` and the virtual display name it.
    pub display_id: u32,
}

/// The crate's display, as the record it reports as.
const fn record(display: slopdesk_apple_cgdisplay::Display) -> SlopDeskCGDisplay {
    SlopDeskCGDisplay {
        bounds: SlopDeskVideoRect::from(display.bounds),
        display_id: display.id,
    }
}

/// Every display, and how many there are.
///
/// `online` asks for displays that EXIST — including mirrored and sleeping ones — rather than only
/// the drawable ones. The parked-window restore wants that wider set: a window on a sleeping
/// display is not stranded, and moving it would take a window the user never lost.
///
/// The answer is the count NEEDED — §4 — so a caller that lent too little is told what to lend.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`SlopDeskCGDisplay`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cgdisplay_list(
    online_only: bool,
    out: *mut SlopDeskCGDisplay,
    cap: usize,
) -> usize {
    let displays: Vec<SlopDeskCGDisplay> = if online_only { online() } else { active() }
        .into_iter()
        .map(record)
        .collect();
    // SAFETY: the caller's obligation above is restated on `spill`.
    unsafe { spill(&displays, out, cap) }
}

/// The display under a point. `false` means the point is off every display, or `out` was null — in
/// either case `out` is left untouched.
///
/// # Safety
/// `out` must be null, or writable for one [`SlopDeskCGDisplay`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cgdisplay_under(x: f64, y: f64, out: *mut SlopDeskCGDisplay) -> bool {
    if out.is_null() {
        return false;
    }
    let Some(display) = under(VideoPoint::new(x, y)) else {
        return false;
    };
    // SAFETY: non-null was just checked, and by the caller's obligation it is writable for one
    // record for this call. The value written is a plain `Copy` scalar record built here.
    unsafe { out.write(record(display)) };
    true
}

/// One display's bounds, by id.
///
/// For the callers that already hold one, from `SCShareableContent` or from the virtual display
/// they created. An id naming no display answers a zero rect, which is CoreGraphics's own answer
/// and what those callers already read as "no clamp".
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_cgdisplay_bounds_of(display_id: u32) -> SlopDeskVideoRect {
    SlopDeskVideoRect::from(bounds_of(display_id))
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{SlopDeskCGDisplay, slopdesk_cgdisplay_list, slopdesk_cgdisplay_under};

    /// A null buffer still reports the count, which is how the two-call shape starts: lend nothing,
    /// learn the size, lend that.
    #[test]
    fn a_null_buffer_still_reports_the_count_it_would_have_written() {
        // SAFETY: null is one of the two shapes the door documents.
        let needed = unsafe { slopdesk_cgdisplay_list(false, core::ptr::null_mut(), 0) };
        let mut room = vec![SlopDeskCGDisplay::default(); needed];
        // SAFETY: `room` is a live local holding exactly `needed` records.
        let written = unsafe { slopdesk_cgdisplay_list(false, room.as_mut_ptr(), room.len()) };
        assert_eq!(written, needed);
    }

    /// Active displays are a subset of online ones, so the door can never report more of them.
    #[test]
    fn there_are_never_more_active_displays_than_online_ones() {
        // SAFETY: null is one of the two shapes the door documents.
        let active = unsafe { slopdesk_cgdisplay_list(false, core::ptr::null_mut(), 0) };
        // SAFETY: as above.
        let online = unsafe { slopdesk_cgdisplay_list(true, core::ptr::null_mut(), 0) };
        assert!(active <= online);
    }

    /// A point no display can contain answers `false` rather than the main display, so a caller
    /// clamping to "the display under the window" cannot silently anchor to the wrong one.
    #[test]
    fn a_point_off_every_display_is_refused() {
        let mut display = SlopDeskCGDisplay::default();
        // SAFETY: `display` is a live local, writable for exactly one record for this call.
        assert!(!unsafe { slopdesk_cgdisplay_under(-1.0e9, -1.0e9, &raw mut display) });
    }

    /// A null out-pointer is refused rather than written through.
    #[test]
    fn a_null_out_pointer_is_refused() {
        // SAFETY: null is one of the two shapes the door documents.
        assert!(!unsafe { slopdesk_cgdisplay_under(0.0, 0.0, core::ptr::null_mut()) });
    }
}
