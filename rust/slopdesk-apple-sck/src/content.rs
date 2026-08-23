//! What the window server says is shareable, and the two lookups the capture path makes into it.
//!
//! The query is asked FRESH at every start, and that is not caution. A window is enumerated by the
//! caller, then moved onto the virtual display by the Accessibility API, and only then captured —
//! so the frame the caller holds is the pre-move one, and a display-anchored crop built from it
//! would sample the wrong rectangle. Re-resolving by window id here is what makes the crop follow
//! the window the daemon actually parked.

use std::sync::Arc;

use block2::RcBlock;
use objc2::rc::Retained;
use objc2_foundation::NSError;
use objc2_screen_capture_kit::{SCDisplay, SCShareableContent, SCWindow};
use slopdesk_video::geometry::{VideoPoint, VideoRect};

use crate::handoff::Handoff;

/// One shareable window, still holding the framework object a content filter needs.
#[derive(Debug)]
pub struct Window {
    inner: Retained<SCWindow>,
}

impl Window {
    /// The `CGWindowID`. Per-boot and reusable, so it names a window only together with its owner.
    #[must_use]
    pub fn id(&self) -> u32 {
        // SAFETY: framework rule — a property read on a live `SCWindow` this crate holds a strong
        // reference to. `objc2` generates it `unsafe` because `ScreenCaptureKit`'s header does not
        // say which of its accessors are main-thread-only; this one answers a scalar and the
        // framework documents the whole class as usable from any queue.
        #[expect(unsafe_code, reason = "a property read on an SCWindow this crate owns")]
        unsafe {
            self.inner.windowID()
        }
    }

    /// The window's frame in CG global points, top-left origin — the space `kCGWindowBounds`, the
    /// display bounds and the Accessibility API all share.
    #[must_use]
    pub fn frame(&self) -> VideoRect {
        // SAFETY: framework rule — the same property read as [`Self::id`], answering a `CGRect` by
        // value.
        #[expect(unsafe_code, reason = "a property read on an SCWindow this crate owns")]
        let rect = unsafe { self.inner.frame() };
        VideoRect::xywh(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    /// The framework object, for the filter that needs it.
    pub(crate) fn raw(&self) -> &SCWindow {
        &self.inner
    }
}

/// One shareable display, still holding the framework object a content filter needs.
#[derive(Debug)]
pub struct Display {
    inner: Retained<SCDisplay>,
}

impl Display {
    /// The `CGDirectDisplayID`.
    #[must_use]
    pub fn id(&self) -> u32 {
        // SAFETY: framework rule — a property read on a live `SCDisplay` this crate holds a strong
        // reference to, answering a scalar.
        #[expect(unsafe_code, reason = "a property read on an SCDisplay this crate owns")]
        unsafe {
            self.inner.displayID()
        }
    }

    /// The display's bounds in CG global points, read through Quartz rather than through
    /// `ScreenCaptureKit`.
    ///
    /// `SCDisplay.frame` answers the same rectangle, and reading it here would still be one
    /// framework area too many: the crop arithmetic downstream compares this against
    /// `kCGWindowBounds`, and `slopdesk-apple-cgdisplay` is the crate that already promises those
    /// two are in the same space.
    #[must_use]
    pub fn bounds(&self) -> VideoRect {
        slopdesk_apple_cgdisplay::bounds_of(self.id())
    }

    /// The framework object, for the filter that needs it.
    pub(crate) fn raw(&self) -> &SCDisplay {
        &self.inner
    }
}

/// A snapshot of what the window server will share.
#[derive(Debug)]
pub struct ShareableContent {
    inner: Retained<SCShareableContent>,
}

impl ShareableContent {
    /// Asks the window server, and waits for the answer.
    ///
    /// `None` when the query failed — no Screen-Recording grant, no window server — or when it
    /// never answered inside the crate's wait limit. Which of the two it was is not distinguished
    /// on purpose: the caller's recovery is the same, and an error object that only ever reaches a
    /// log line is not worth threading through an FFI door.
    ///
    /// ⚠️ Requires a window server and a Screen-Recording grant, so no test can call this.
    #[must_use]
    pub fn current(exclude_desktop_windows: bool, on_screen_windows_only: bool) -> Option<Self> {
        let handoff = Handoff::<Option<Retained<SCShareableContent>>>::new();
        let filler = Arc::clone(&handoff);
        let completion = RcBlock::new(move |content: *mut SCShareableContent, _error: *mut NSError| {
            // SAFETY: framework rule — `ScreenCaptureKit` hands the completion handler a +0
            // reference valid for the call, and taking one of our own is how it outlives the
            // block. Null is the framework's own way of reporting that the query failed, and
            // `Retained::retain` answers `None` for it rather than retaining nothing.
            #[expect(
                unsafe_code,
                reason = "the handler's argument is a borrowed +0 reference; retaining it is the \
                          framework's stated way to keep it"
            )]
            let taken = unsafe { Retained::retain(content) };
            filler.deliver(taken);
        });
        // SAFETY: framework rule — the block is copied by `ScreenCaptureKit` before this returns
        // (`RcBlock` is the copyable heap block the API is documented to take), and the two flags
        // are plain booleans. Nothing here outlives the call on this side.
        #[expect(
            unsafe_code,
            reason = "the class method is generated unsafe because ScreenCaptureKit's header states no \
                      nullability"
        )]
        unsafe {
            SCShareableContent::getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler(
                exclude_desktop_windows,
                on_screen_windows_only,
                &completion,
            );
        }
        handoff.take().flatten().map(|inner| Self { inner })
    }

    /// The window with this `CGWindowID`, or `None` when it has closed since it was enumerated.
    #[must_use]
    pub fn window(&self, window_id: u32) -> Option<Window> {
        // SAFETY: framework rule — a property read answering an `NSArray` this crate then holds.
        #[expect(
            unsafe_code,
            reason = "a property read on an SCShareableContent this crate owns"
        )]
        let windows = unsafe { self.inner.windows() };
        windows
            .to_vec()
            .into_iter()
            .map(|inner| Window { inner })
            .find(|window| window.id() == window_id)
    }

    /// The display with this `CGDirectDisplayID`, or `None` when no such display is attached.
    #[must_use]
    pub fn display(&self, display_id: u32) -> Option<Display> {
        self.displays()
            .into_iter()
            .find(|display| display.id() == display_id)
    }

    /// The display whose bounds contain `point`, or `None` when the point is off every display.
    #[must_use]
    pub fn display_under(&self, point: VideoPoint) -> Option<Display> {
        self.displays()
            .into_iter()
            .find(|display| display.bounds().contains_point(point))
    }

    /// Every shareable display.
    fn displays(&self) -> Vec<Display> {
        // SAFETY: framework rule — the same property read as [`Self::window`]'s.
        #[expect(
            unsafe_code,
            reason = "a property read on an SCShareableContent this crate owns"
        )]
        let displays = unsafe { self.inner.displays() };
        displays
            .to_vec()
            .into_iter()
            .map(|inner| Display { inner })
            .collect()
    }
}
