//! The three content filters, and nothing about which one to build.
//!
//! [`slopdesk_video::capture_config::CaptureMode`] is where that is decided, with the measurement
//! behind each choice written next to it.

use objc2::rc::Retained;
use objc2::{AllocAnyThread, Message};
use objc2_foundation::NSArray;
use objc2_screen_capture_kit::{SCContentFilter, SCWindow};

use crate::content::{Display, Window};

/// The per-window compositor: this window's own backing store, wherever it is.
#[must_use]
pub(crate) fn desktop_independent_window(window: &Window) -> Retained<SCContentFilter> {
    // SAFETY: framework rule — an initialiser taking a live `SCWindow` the caller holds a strong
    // reference to for the duration of the call. The filter retains what it needs; `ScreenCaptureKit`
    // documents a filter as outliving the window object that described it.
    #[expect(
        unsafe_code,
        reason = "an SCContentFilter initialiser; generated unsafe because the header states no nullability"
    )]
    unsafe {
        SCContentFilter::initWithDesktopIndependentWindow(SCContentFilter::alloc(), window.raw())
    }
}

/// The whole display, dock and desktop included, excluding nothing.
///
/// The empty exclusion array is not a placeholder — it is the documented way to say "everything on
/// this display", and the crop that narrows it to one window is the configuration's source rect
/// rather than the filter's business.
#[must_use]
pub(crate) fn display_excluding_nothing(display: &Display) -> Retained<SCContentFilter> {
    let excluded = NSArray::<SCWindow>::new();
    // SAFETY: framework rule — the same initialiser contract as above, with an array this crate
    // just built and holds for the call.
    #[expect(
        unsafe_code,
        reason = "an SCContentFilter initialiser; generated unsafe for the same header reason"
    )]
    unsafe {
        SCContentFilter::initWithDisplay_excludingWindows(SCContentFilter::alloc(), display.raw(), &excluded)
    }
}

/// The display, compositing only this window and its children.
///
/// Display-anchored like [`display_excluding_nothing`] — so no child window can nudge the crop
/// origin — and occlusion-proof, which is what lets several served windows share one virtual
/// display without bleeding into each other's frames.
#[must_use]
pub(crate) fn display_including_window(display: &Display, window: &Window) -> Retained<SCContentFilter> {
    let included = NSArray::from_retained_slice(&[window.raw().retain()]);
    // SAFETY: framework rule — the same initialiser contract, with an array holding one live window
    // this crate retained for the call.
    #[expect(
        unsafe_code,
        reason = "an SCContentFilter initialiser; generated unsafe for the same header reason"
    )]
    unsafe {
        SCContentFilter::initWithDisplay_includingWindows(SCContentFilter::alloc(), display.raw(), &included)
    }
}
