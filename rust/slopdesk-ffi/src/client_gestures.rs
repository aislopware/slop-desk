//! The client's pointer and gesture policies —
//! `Sources/SlopDeskVideoClient/{BackgroundPointerPolicy,PinchZeroPolicy,PinchZoomKeyPlanner,
//! ScrollRoutePinner}.swift`.
//!
//! Every rule here belongs to a view that is never instantiated in a test — no Metal, no VT — which
//! is why they were lifted out of it in the first place. They cross in three shapes, each picked by
//! `docs/55` §4b:
//!
//! * The two pointer gates are pure predicates and cross as arguments.
//! * The pinch planner and the scroll-route pinner are STATEFUL, and their owner is a `SwiftUI`
//!   view that the framework copies whenever it pleases. A handle they copied would be one
//!   accumulator shared by two gestures, so the state crosses BY VALUE — a residual, a pin — and
//!   every door answers the new state beside its verdict.
//! * The zoom-reset denylist carries a runtime EXTENSION set, so it is a handle owned by a
//!   process-lifetime namespace, exactly like the swipe-nav operating point.

use core::ffi::c_uchar;
use std::collections::BTreeSet;

use slopdesk_video::client_gestures::{
    PinchZoomKeyPlanner, ScrollRoutePinner, allows_zoom_reset, extra_unsafe_reset_apps, forwards_pointer,
    is_background_click,
};

use crate::borrow;

/// Whether pointer MOTION may forward to the host: the active pane as ever, or any
/// background-pointer surface. The read-only gate is a separate check, downstream, on every relay.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_gesture_forwards_pointer(is_active: bool, background_pointer: bool) -> bool {
    forwards_pointer(is_active, background_pointer)
}

/// Whether a mouse-down is a BACKGROUND click, leaving local focus where it is. A key window always
/// takes the normal activate path.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_gesture_background_click(
    background_pointer: bool,
    window_is_key: bool,
) -> bool {
    is_background_click(background_pointer, window_is_key)
}

/// The pinch planner's whole state: what a gesture has accumulated and not yet spent.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskPinchPlanner {
    /// Magnification accumulated toward the next step.
    pub residual: f64,
}

/// One pinch event's answer: the steps to emit now, and the state to keep.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskPinchPlan {
    /// The planner after this event.
    pub state: SlopDeskPinchPlanner,
    /// Signed steps to emit now — positive zooms in, negative zooms out, zero keeps accumulating.
    pub steps: i32,
}

/// A planner with nothing accumulated.
///
/// Also what a gesture BEGINS with, which is why there is no separate reset door: a residual that
/// never leaks between pinches is the same thing as starting from this value.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pinch_planner_new() -> SlopDeskPinchPlanner {
    SlopDeskPinchPlanner {
        residual: PinchZoomKeyPlanner::new().residual(),
    }
}

/// Folds one magnification delta into the planner and answers the steps to emit.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pinch_planner_plan(
    state: SlopDeskPinchPlanner,
    magnification: f64,
) -> SlopDeskPinchPlan {
    let mut planner = PinchZoomKeyPlanner::restored(state.residual);
    let steps = planner.ingest(magnification);
    SlopDeskPinchPlan {
        state: SlopDeskPinchPlanner {
            residual: planner.residual(),
        },
        steps,
    }
}

/// The scroll-route pinner's whole state: where this gesture was pinned, if it was.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskScrollPin {
    /// Where the gesture routes, meaningful only while `has_pin`.
    pub remote: bool,
    /// Whether a gesture is pinned at all. A phase-less wheel tick never sets this, so it can never
    /// be read as a pin to the wrong destination.
    pub has_pin: bool,
}

/// One scroll event's answer: where it routes, and the pin to keep.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskScrollRoute {
    /// The pin after this event.
    pub state: SlopDeskScrollPin,
    /// True to forward this event to the remote window, false to scroll the pane locally.
    pub remote: bool,
}

/// A pinner with no gesture in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_pin_new() -> SlopDeskScrollPin {
    crossing(ScrollRoutePinner::new())
}

/// Decides where THIS event routes and maintains the pin.
///
/// `live_remote` is the caller's current would-be decision WITHOUT the read-only gate, which stays
/// live at the call site because locking a pane must stop relay immediately, mid-gesture included.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_scroll_pin_route(
    state: SlopDeskScrollPin,
    live_remote: bool,
    scroll_phase: u8,
    momentum_phase: u8,
) -> SlopDeskScrollRoute {
    let mut pinner = ScrollRoutePinner::restored(state.has_pin.then_some(state.remote));
    let remote = pinner.route(live_remote, scroll_phase, momentum_phase);
    SlopDeskScrollRoute {
        state: crossing(pinner),
        remote,
    }
}

/// A pinner as the two flags that carry it.
fn crossing(pinner: ScrollRoutePinner) -> SlopDeskScrollPin {
    SlopDeskScrollPin {
        remote: pinner.pinned().unwrap_or(false),
        has_pin: pinner.pinned().is_some(),
    }
}

/// The parsed zoom-reset denylist: the built-in names plus the runtime extension.
#[derive(Debug)]
pub struct SlopDeskZoomResetPolicy {
    /// The extension list, parsed once.
    extra: BTreeSet<String>,
}

/// The handle as a reference, or `None` for null.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_zoom_reset_policy_parse`].
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskZoomResetPolicy) -> Option<&'a SlopDeskZoomResetPolicy> {
    // SAFETY: by the caller's obligation this is a live allocation from `parse`.
    unsafe { handle.as_ref() }
}

/// A borrowed span as a string, where a NULL pointer means the value is unset.
///
/// # Safety
/// `raw` must be null or point to `len` readable bytes for the whole call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's bytes IS the boundary this module documents"
)]
unsafe fn text<'a>(raw: *const c_uchar, len: usize) -> Option<&'a str> {
    if raw.is_null() {
        return None;
    }
    // SAFETY: the caller's obligation, discharged by Swift's scoped buffer access.
    let bytes = unsafe { borrow(raw, len) };
    core::str::from_utf8(bytes).ok()
}

/// Parses the `SLOPDESK_PINCH_ZERO_UNSAFE_APPS` extension list. A NULL pointer is an unset
/// variable.
///
/// # Safety
/// `raw` must be null or point to `len` readable bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_zoom_reset_policy_parse(
    raw: *const c_uchar,
    len: usize,
) -> *mut SlopDeskZoomResetPolicy {
    // SAFETY: the caller's obligation, discharged by Swift's scoped buffer access.
    let extra = extra_unsafe_reset_apps(unsafe { text(raw, len) });
    Box::into_raw(Box::new(SlopDeskZoomResetPolicy { extra }))
}

/// Frees a parsed denylist. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_zoom_reset_policy_parse`], freed exactly
/// once.
///
/// **No shipped caller, deliberately** — same as [`slopdesk_swipe_nav_config_free`].
/// `PinchZeroPolicy` parses once into a `static let` and says so: "nothing frees it, and the parse
/// outlives every caller". The door stays so the next owner that is not process-lifetime has one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_zoom_reset_policy_free(handle: *mut SlopDeskZoomResetPolicy) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `parse` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Whether a smart-zoom reset may be sent at a pane bound to this app.
///
/// An EMPTY name — a desktop pane, or a legacy binding with no recorded app — fails OPEN: it
/// streams a whole display whose frontmost app the client cannot know. A NULL name is that same
/// case.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `app_name` must be null or point to `name_len`
/// readable bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_zoom_reset_allowed(
    handle: *const SlopDeskZoomResetPolicy,
    app_name: *const c_uchar,
    name_len: usize,
) -> bool {
    // SAFETY: the caller's obligation on both.
    let (policy, name) = unsafe { (held(handle), text(app_name, name_len)) };
    policy.is_none_or(|policy| allows_zoom_reset(name.unwrap_or_default(), &policy.extra))
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the doors as the near side does IS what these tests pin"
    )]

    use std::ptr;

    use super::{
        SlopDeskPinchPlanner, slopdesk_gesture_background_click, slopdesk_gesture_forwards_pointer,
        slopdesk_pinch_planner_new, slopdesk_pinch_planner_plan, slopdesk_scroll_pin_new,
        slopdesk_scroll_pin_route, slopdesk_zoom_reset_allowed, slopdesk_zoom_reset_policy_free,
        slopdesk_zoom_reset_policy_parse,
    };

    #[test]
    fn the_two_pointer_gates_cross_as_arguments() {
        assert!(slopdesk_gesture_forwards_pointer(false, true));
        assert!(!slopdesk_gesture_forwards_pointer(false, false));
        assert!(slopdesk_gesture_background_click(true, false));
        assert!(!slopdesk_gesture_background_click(true, true));
    }

    #[test]
    fn a_pinch_carries_its_residual_across_the_boundary_and_back() {
        let mut state = slopdesk_pinch_planner_new();
        let first = slopdesk_pinch_planner_plan(state, 0.1);
        assert_eq!(first.steps, 0, "still accumulating");
        state = first.state;
        assert_eq!(slopdesk_pinch_planner_plan(state, 0.1).steps, 1);
        // A fresh planner is what a gesture begins with, so the near-step residual cannot leak.
        assert_eq!(
            slopdesk_pinch_planner_plan(slopdesk_pinch_planner_new(), 0.1).steps,
            0
        );
    }

    #[test]
    fn a_wild_delta_is_capped_and_the_overflow_stays_in_the_state() {
        let capped = slopdesk_pinch_planner_plan(SlopDeskPinchPlanner::default(), 10.0);
        assert_eq!(capped.steps, 3);
        assert_eq!(
            slopdesk_pinch_planner_plan(capped.state, 0.0).steps,
            3,
            "the rest is still there to spend"
        );
    }

    #[test]
    fn a_focus_flip_mid_gesture_cannot_reroute_the_coast() {
        let began = slopdesk_scroll_pin_route(slopdesk_scroll_pin_new(), true, 1, 0);
        assert!(began.remote && began.state.has_pin);
        let changed = slopdesk_scroll_pin_route(began.state, false, 2, 0);
        assert!(changed.remote, "the pin owns the route under a focus flip");
        let coast = slopdesk_scroll_pin_route(changed.state, false, 0, 3);
        assert!(coast.remote, "and the tail too");
        assert!(!coast.state.has_pin, "the coast ending releases the pin");
        assert!(
            !slopdesk_scroll_pin_route(coast.state, false, 1, 0).remote,
            "so the next gesture pins fresh"
        );
    }

    #[test]
    fn the_denylist_grows_from_the_environment_and_an_unknown_pane_fails_open() {
        let raw = " Sublime Text , ,Logic Pro ";
        let policy = unsafe { slopdesk_zoom_reset_policy_parse(raw.as_ptr(), raw.len()) };
        let name = "Sublime Text";
        assert!(!unsafe { slopdesk_zoom_reset_allowed(policy, name.as_ptr(), name.len()) });
        let xcode = "Xcode";
        assert!(
            !unsafe { slopdesk_zoom_reset_allowed(policy, xcode.as_ptr(), xcode.len()) },
            "the built-in name holds under an extension list"
        );
        let chrome = "Google Chrome";
        assert!(unsafe { slopdesk_zoom_reset_allowed(policy, chrome.as_ptr(), chrome.len()) });
        assert!(
            unsafe { slopdesk_zoom_reset_allowed(policy, ptr::null(), 0) },
            "a desktop pane cannot know its frontmost app, so it fails open"
        );
        unsafe { slopdesk_zoom_reset_policy_free(policy) };
    }
}
