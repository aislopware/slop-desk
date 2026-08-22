//! An application's accessibility element, and the windows it publishes.

use objc2_application_services::AXUIElement;
use objc2_core_foundation::{CFArray, CFRetained, CGPoint, CGSize};

use crate::attribute;

/// `AXWindows` — the array of window elements an application publishes.
const WINDOWS: &str = "AXWindows";
/// `AXPosition` — a window's top-left corner in global points, as a `CGPoint` `AXValue`.
const POSITION: &str = "AXPosition";
/// `AXSize` — a window's size in points, as a `CGSize` `AXValue`.
const SIZE: &str = "AXSize";
/// `AXMinimized` — whether the window is in the Dock, as a `CFBoolean`.
const MINIMIZED: &str = "AXMinimized";
/// `AXMainWindow` — the application's main window, written with a window element.
const MAIN_WINDOW: &str = "AXMainWindow";
/// `AXFocusedWindow` — the application's focused window, written with a window element.
const FOCUSED_WINDOW: &str = "AXFocusedWindow";
/// `AXRaise` — the action that brings a window to the front of its application's own stack.
const RAISE: &str = "AXRaise";

/// A window's global frame in top-left points — the space `CGWindowBounds` uses, so a caller that
/// already knows a window by its `CGWindowID` can compare the two without converting.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Frame {
    /// The left edge, global points.
    pub x: f64,
    /// The top edge, global points.
    pub y: f64,
    /// The width in points. Raw, never standardised: a caller deciding a resize needs the sign it
    /// was given.
    pub width: f64,
    /// The height in points, on the same terms.
    pub height: f64,
}

/// One application's accessibility element, with its messaging timeout already set.
///
/// The timeout is per-application and is the only reason this is a type rather than a function:
/// every call in a sequence should inherit the deadline the sequence was opened with, and an app
/// element re-created per call would silently fall back to the framework's ~6 second default.
#[derive(Debug)]
pub struct App {
    /// The `AXUIElement` for the process.
    element: CFRetained<AXUIElement>,
}

impl App {
    /// The accessibility element for `pid`, capped at `timeout_seconds` per message.
    ///
    /// A hung, modal or beachballing target is the normal case this exists for: without a cap, one
    /// unresponsive app stalls the caller for the framework default, which on the raise path is
    /// several seconds of frozen input. The element is created even for a pid that does not exist —
    /// the framework has nothing to check against — and every read through it then fails, which is
    /// the answer callers already handle.
    ///
    /// # Safety
    /// `AXUIElementCreateApplication` is documented to answer a valid element for any pid under the
    /// Create rule, which the binding discharges by handing back a `CFRetained`.
    /// `AXUIElementSetMessagingTimeout` accepts any non-negative float and treats zero as "restore
    /// the default"; the value is the caller's and is passed through unexamined, because a caller
    /// asking for no cap is asking for the framework's behaviour.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "objc2 marks both AX entry points unsafe; the obligations are the framework's"
    )]
    pub fn new(pid: i32, timeout_seconds: f32) -> Self {
        // SAFETY: framework rule, above — any pid is a legal argument, Create rule on the result.
        let element = unsafe { AXUIElement::new_application(pid) };
        // SAFETY: framework rule, above — the cap applies to every later message to this app.
        let _ = unsafe { element.set_messaging_timeout(timeout_seconds) };
        Self { element }
    }

    /// Every window the application publishes, in the order it publishes them.
    ///
    /// Empty covers a real absence and a refusal alike — an app with no windows, an app that does
    /// not implement the attribute, a pid that is gone, and accessibility not being granted at all.
    /// The caller's next step is the same in each case, so the distinction has no reader.
    ///
    /// # Safety
    /// The Accessibility header documents `AXWindows` as an array of `AXUIElementRef`. C's
    /// `CFArrayRef` has nowhere to say so, which is why the read hands back an untyped array; this
    /// states it once. Nothing is dereferenced — the typed view only decides which `get` applies.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "C's CFArrayRef carries no element type; the Accessibility header is where it lives"
    )]
    pub fn windows(&self) -> Vec<Window> {
        let Some(array) = attribute::copy(&self.element, WINDOWS).and_then(|v| v.downcast::<CFArray>().ok())
        else {
            return Vec::new();
        };
        // SAFETY: framework rule, above — `AXWindows` is documented as an array of window elements.
        let typed = unsafe { CFRetained::cast_unchecked::<CFArray<AXUIElement>>(array) };
        typed
            .to_vec()
            .into_iter()
            .map(|element| Window { element })
            .collect()
    }

    /// Point the application's `AXMainWindow` and `AXFocusedWindow` at `window`.
    ///
    /// Best-effort and unreported: an app that refuses either write is an app whose window is
    /// already going to be raised by the action, and the pair exists to make the raise stick rather
    /// than to be verified.
    pub fn focus(&self, window: &Window) {
        let _ = attribute::set(&self.element, MAIN_WINDOW, &window.element);
        let _ = attribute::set(&self.element, FOCUSED_WINDOW, &window.element);
    }
}

/// One window of one application.
#[derive(Debug)]
pub struct Window {
    /// The `AXUIElement` for the window.
    element: CFRetained<AXUIElement>,
}

impl Window {
    /// The window's `CGWindowID`, or `None` when the private symbol cannot answer.
    ///
    /// There is no public `AXUIElement`↔`CGWindowID` map, and this is the whole reason the host can
    /// bind the two at all. The symbol is resolved and called in `slopdesk_posix::dynsym`, because
    /// doing it here would mean a function-pointer transmute and `docs/57` §2 bars one from this
    /// family; what crosses is a borrowed pointer, and the obligation that comes back with it is
    /// the framework's: the callee reads the element's `CFTypeID`, so it must be a live AX element.
    #[must_use]
    #[expect(
        unsafe_code,
        reason = "the private AX↔CGWindowID symbol takes an element pointer and reads through it"
    )]
    pub fn id(&self) -> Option<u32> {
        // SAFETY: `self.element` is an `AXUIElement` this struct holds a retain on, so it is a live
        // AX element for the whole call — which is the door's entire contract. `CFRetained` cannot
        // hand out a dangling reference, so the cast below borrows something that exists.
        unsafe { slopdesk_posix::dynsym::ax_window_id(core::ptr::from_ref(&*self.element).cast()) }
    }

    /// The window's global frame, or `None` when either half is unreadable.
    ///
    /// Both halves or neither: a caller planning a move needs the size, and a caller planning a
    /// restore needs the origin, so half an answer is one that would be completed by a guess.
    #[must_use]
    pub fn frame(&self) -> Option<Frame> {
        let origin = attribute::point(&self.element, POSITION)?;
        let size = attribute::size(&self.element, SIZE)?;
        Some(Frame {
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height,
        })
    }

    /// Move the window's top-left corner to `(x, y)` in global points.
    #[must_use]
    pub fn set_origin(&self, x: f64, y: f64) -> bool {
        attribute::set_point(&self.element, POSITION, CGPoint::new(x, y))
    }

    /// Resize the window to `width` × `height` points.
    ///
    /// The window may clamp to its own minimum or maximum, and a fixed-size one refuses outright —
    /// so `true` means the framework accepted the message, not that the size took. Read [`frame`]
    /// back to learn what actually happened.
    ///
    /// [`frame`]: Self::frame
    #[must_use]
    pub fn set_size(&self, width: f64, height: f64) -> bool {
        attribute::set_size(&self.element, SIZE, CGSize::new(width, height))
    }

    /// Whether the window is minimized into the Dock, or `None` when it does not say.
    #[must_use]
    pub fn minimized(&self) -> Option<bool> {
        attribute::flag(&self.element, MINIMIZED)
    }

    /// Minimize or un-minimize the window.
    #[must_use]
    pub fn set_minimized(&self, minimized: bool) -> bool {
        attribute::set_flag(&self.element, MINIMIZED, minimized)
    }

    /// Bring the window to the front of its own application's window stack.
    ///
    /// This does NOT bring the application forward — that is a separate activation, and it is
    /// `slopdesk-apple-app`'s. Ordering the two is the caller's decision and stays there.
    #[must_use]
    pub fn raise(&self) -> bool {
        attribute::perform(&self.element, RAISE)
    }
}
