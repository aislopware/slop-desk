//! The client's pointer and gesture policies —
//! `Sources/SlopDeskVideoClient/{BackgroundPointerPolicy,PinchZeroPolicy,PinchZoomKeyPlanner,
//! ScrollRoutePinner,TouchPointerPlan}.swift`.
//!
//! Every rule here belongs to a view that is never instantiated in a test — no Metal, no VT — which
//! is why they were lifted out of it in the first place. They cross in four shapes, each picked by
//! `docs/55` §4b:
//!
//! * The two pointer gates are pure predicates and cross as arguments.
//! * The pinch planner and the scroll-route pinner are STATEFUL, and their owner is a gesture
//!   recognizer the shell may attach more than once. A handle two of them shared would be one
//!   accumulator serving two gestures, so the state crosses BY VALUE — a residual, a pin — and
//!   every door answers the new state beside its verdict.
//! * The zoom-reset denylist carries a runtime EXTENSION set, so it is a handle owned by a
//!   process-lifetime namespace, exactly like the swipe-nav operating point.
//! * The phone's touch → pointer translation has no state at all: it is `docs/55` §4's "entry that
//!   takes no memory", every argument a scalar and every answer by value. Its one non-scalar answer
//!   is the pair ROUTE, which is an `Option` — so it crosses as a value beside a flag, never as a
//!   sentinel, because there is no route byte that could have meant "still undecided" without a
//!   caller having to remember it. The seven numbers of its vocabulary cross through ONE
//!   index-shaped door for the reason `docs/55` gives: a family read once into `static let`s does
//!   not become seven entry points.

use core::ffi::c_uchar;
use std::collections::BTreeSet;

use slopdesk_video::client_gestures::{
    self, PinchZoomKeyPlanner, ScrollRoutePinner, TouchPairRoute, allows_zoom_reset, extra_unsafe_reset_apps,
    forwards_pointer, is_background_click,
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

/// `TouchPairRoute::Zoom` as a byte.
pub const SLOPDESK_TOUCH_ROUTE_ZOOM: u8 = 0;
/// `TouchPairRoute::Pan` as a byte.
pub const SLOPDESK_TOUCH_ROUTE_PAN: u8 = 1;
/// `TouchPairRoute::Scroll` as a byte.
pub const SLOPDESK_TOUCH_ROUTE_SCROLL: u8 = 2;

/// The phone's touch vocabulary, by index, so seven numbers do not become seven doors.
///
/// `0` tap slop, `1` long-press delay, `2` pinch span slop, `3` pair travel slop, `4` minimum zoom,
/// `5` maximum zoom, `6` zoom step. An index nobody defined answers `0`, which the family cannot
/// hold: every one of these is a positive distance, delay or scale.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_touch_constant(index: u8) -> f64 {
    match index {
        0 => client_gestures::TAP_SLOP,
        1 => client_gestures::LONG_PRESS_DELAY,
        2 => client_gestures::PINCH_SPAN_SLOP,
        3 => client_gestures::PAIR_TRAVEL_SLOP,
        4 => client_gestures::MIN_ZOOM,
        5 => client_gestures::MAX_ZOOM,
        6 => client_gestures::ZOOM_STEP,
        _ => 0.0,
    }
}

/// Whether a one-finger contact has left the tap slop, i.e. it is a DRAG now and the pending long
/// press is off.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_escapes_tap_slop(dx: f64, dy: f64) -> bool {
    client_gestures::escapes_tap_slop(dx, dy)
}

/// What a two-contact gesture drives, and whether it has been decided at all.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskTouchPairRoute {
    /// One of the `SLOPDESK_TOUCH_ROUTE_*` bytes, meaningful only while `decided`.
    pub route: u8,
    /// Whether the pair has moved past its slop. While this is false the gesture sends NOTHING — a
    /// two-finger REST must not scroll — which is a state no route byte could have named.
    pub decided: bool,
}

/// Classifies a two-contact gesture over a remote desktop.
///
/// `span_delta` is the signed change in the distance between the contacts since the pair landed;
/// `centroid_travel` is how far their midpoint has moved since then; `zoom` is the viewport's
/// current client zoom. Span wins over travel: a pinch always drags its centroid a little, and
/// misreading that as a scroll sends the remote document flying.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_classify_pair(
    span_delta: f64,
    centroid_travel: f64,
    zoom: f64,
) -> SlopDeskTouchPairRoute {
    client_gestures::classify_pair(span_delta, centroid_travel, zoom).map_or_else(
        SlopDeskTouchPairRoute::default,
        |route| {
            SlopDeskTouchPairRoute {
                route: match route {
                    TouchPairRoute::Zoom => SLOPDESK_TOUCH_ROUTE_ZOOM,
                    TouchPairRoute::Pan => SLOPDESK_TOUCH_ROUTE_PAN,
                    TouchPairRoute::Scroll => SLOPDESK_TOUCH_ROUTE_SCROLL,
                },
                decided: true,
            }
        },
    )
}

/// The zoom a pinch lands on: the gesture's base scaled by the live span ratio, clamped to the
/// ladder. A non-finite or non-positive ratio — a degenerate pair — holds the base.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_pinched_zoom(base: f64, span_ratio: f64) -> f64 {
    client_gestures::pinched_zoom(base, span_ratio)
}

/// One footer zoom STEP from `zoom` (`step_in` is the + button), clamped to the ladder.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_stepped_zoom(zoom: f64, step_in: bool) -> f64 {
    client_gestures::stepped_zoom(zoom, step_in)
}

/// Clamps to the ladder, and SNAPS to exactly 1× near unity so repeated − steps settle on
/// actual-size instead of stopping at 1.024× forever.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_clamp_zoom(zoom: f64) -> f64 {
    client_gestures::clamp_zoom(zoom)
}

/// Clamps a normalized pan offset to what the renderer can actually show at `zoom`. At 1× the limit
/// is 0, so the crop is pinned centred and there is nothing to pan.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_clamp_pan(pan: f64, zoom: f64) -> f64 {
    client_gestures::clamp_pan(pan, zoom)
}

/// The scroll phase byte for a host scroll built out of touches — `1` began, `2` changed, `4`
/// ended.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_touch_scroll_phase(is_first: bool, is_last: bool) -> u8 {
    client_gestures::scroll_phase(is_first, is_last)
}

/// The `CGScrollPhase` byte for an `NSEvent.Phase` mask — the trackpad's half of what the door
/// above answers for a finger.
///
/// The mask crosses as its raw bits, because that is the shape the platform already has: turning it
/// into a case index on the Swift side would put a table there, which is the table this door exists
/// to remove. A phase this side does not recognise answers `0`, the phase-less wheel tick.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_cg_scroll_phase_code(ns_phase: u32) -> u8 {
    client_gestures::cg_scroll_phase_code(ns_phase)
}

/// The `CGMomentumScrollPhase` byte for an `NSEvent.momentumPhase` mask.
///
/// Separate from the door above because the two platform fields encode the SAME three edges
/// differently — an end is 4 in one and 3 in the other — so one door taking a "which field" flag
/// would be a door whose answer depends on getting the flag right, which is the mistake back again
/// under a different name.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_cg_momentum_phase_code(ns_phase: u32) -> u8 {
    client_gestures::cg_momentum_phase_code(ns_phase)
}

/// Clamps a platform tap count into the wire's byte, floored at 1 and saturating at 255.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_touch_click_count(tap_count: i64) -> u8 {
    client_gestures::click_count(tap_count)
}

/// What changed between the buttons a client has forwarded as DOWN and the ones an indirect pointer
/// is holding now. The bit INDEX of each set is the wire's own `MouseButton` ordinal.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SlopDeskPointerButtons {
    /// Buttons to send a press for.
    pub pressed: u8,
    /// Buttons to send a release for.
    pub released: u8,
    /// The new held set — the caller's next `held`.
    pub held: u8,
}

/// Diffs a `UIKit` `UIEvent.buttonMask` against the buttons already forwarded.
///
/// Stateless by design: the one byte of state stays with the caller, so this door has no handle and
/// no lifetime. Feeding it the SAME mask twice answers "nothing changed", which is what makes it
/// safe to call from a move as well as a press.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pointer_button_transitions(
    held: u8,
    ui_button_mask: u32,
) -> SlopDeskPointerButtons {
    let change = client_gestures::pointer_button_transitions(held, ui_button_mask);
    SlopDeskPointerButtons {
        pressed: change.pressed,
        released: change.released,
        held: change.held,
    }
}

/// The `CGScrollPhase` byte for a `UIKit` `UIGestureRecognizer.State`.
///
/// The iPad trackpad's half of what [`slopdesk_touch_scroll_phase`] answers for a finger and
/// [`slopdesk_cg_scroll_phase_code`] for a Mac one.
///
/// The state crosses as its raw ordinal for the same reason the `NSEvent.Phase` mask does: it is
/// already a stable platform encoding, and re-indexing it on the Swift side would put back the
/// table this door exists to remove.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_scroll_phase_for_gesture_state(state: u8) -> u8 {
    client_gestures::scroll_phase_for_gesture_state(state)
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "calling the doors as the near side does IS what these tests pin"
    )]

    use std::ptr;

    use super::{
        SLOPDESK_TOUCH_ROUTE_PAN, SLOPDESK_TOUCH_ROUTE_SCROLL, SLOPDESK_TOUCH_ROUTE_ZOOM,
        SlopDeskPinchPlanner, slopdesk_cg_momentum_phase_code, slopdesk_cg_scroll_phase_code,
        slopdesk_gesture_background_click, slopdesk_gesture_forwards_pointer, slopdesk_pinch_planner_new,
        slopdesk_pinch_planner_plan, slopdesk_scroll_pin_new, slopdesk_scroll_pin_route,
        slopdesk_touch_clamp_pan, slopdesk_touch_classify_pair, slopdesk_touch_click_count,
        slopdesk_touch_constant, slopdesk_touch_escapes_tap_slop, slopdesk_touch_pinched_zoom,
        slopdesk_touch_scroll_phase, slopdesk_touch_stepped_zoom, slopdesk_zoom_reset_allowed,
        slopdesk_zoom_reset_policy_free, slopdesk_zoom_reset_policy_parse,
    };

    #[test]
    fn the_two_platform_phase_fields_cross_as_the_bits_appkit_hands_over() {
        // The mask arrives verbatim: began is `1 << 0`, ended is `1 << 3`. Neither number is the
        // CoreGraphics code for the same edge, which is the whole point of asking.
        assert_eq!(slopdesk_cg_scroll_phase_code(1 << 0), 1, "began");
        assert_eq!(slopdesk_cg_scroll_phase_code(1 << 3), 4, "ended is a BIT here");
        assert_eq!(slopdesk_cg_scroll_phase_code(1 << 5), 128, "may-begin");
        assert_eq!(
            slopdesk_cg_momentum_phase_code(1 << 3),
            3,
            "ended is an ORDINAL here"
        );
        assert_eq!(
            slopdesk_cg_scroll_phase_code(1 << 1),
            0,
            "stationary is not a gesture edge"
        );
        assert_eq!(
            slopdesk_cg_momentum_phase_code(1 << 4),
            0,
            "a coast cannot be cancelled"
        );
    }

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

    /// The `Option` rule of `docs/55` §4: an undecided pair is a FLAG, because every route byte is
    /// a route and none of them could have meant "nothing has been decided yet".
    #[test]
    fn an_undecided_pair_crosses_as_a_flag_and_not_as_a_route() {
        let resting = slopdesk_touch_classify_pair(3.0, 2.0, 1.0);
        assert!(!resting.decided, "a two-finger rest must send nothing");
        let scroll = slopdesk_touch_classify_pair(0.0, 9.0, 1.0);
        assert!(scroll.decided);
        assert_eq!(scroll.route, SLOPDESK_TOUCH_ROUTE_SCROLL);
        assert_eq!(
            slopdesk_touch_classify_pair(0.0, 40.0, 2.0).route,
            SLOPDESK_TOUCH_ROUTE_PAN
        );
        assert_eq!(
            slopdesk_touch_classify_pair(-30.0, 200.0, 1.0).route,
            SLOPDESK_TOUCH_ROUTE_ZOOM,
            "the span beats the travel"
        );
    }

    /// The seven numbers come back through one door, and an index nobody defined answers a value
    /// the family cannot hold.
    #[test]
    fn the_touch_vocabulary_crosses_by_index() {
        assert!(
            (slopdesk_touch_constant(0) - 10.0).abs() < f64::EPSILON,
            "tap slop"
        );
        assert!(
            (slopdesk_touch_constant(1) - 0.5).abs() < f64::EPSILON,
            "long-press delay"
        );
        assert!(
            (slopdesk_touch_constant(4) - 1.0).abs() < f64::EPSILON,
            "the floor"
        );
        assert!(
            (slopdesk_touch_constant(6) - 1.25).abs() < f64::EPSILON,
            "the step"
        );
        assert!(slopdesk_touch_constant(200).abs() < f64::EPSILON);
    }

    #[test]
    fn the_scalar_touch_doors_answer_by_value() {
        assert!(slopdesk_touch_escapes_tap_slop(12.0, 0.0));
        assert!(!slopdesk_touch_escapes_tap_slop(6.0, 6.0));
        assert!((slopdesk_touch_pinched_zoom(2.0, 1.5) - 3.0).abs() < f64::EPSILON);
        assert!((slopdesk_touch_stepped_zoom(1.0, true) - 1.25).abs() < f64::EPSILON);
        assert!(
            slopdesk_touch_clamp_pan(0.4, 1.0).abs() < f64::EPSILON,
            "1× cannot pan"
        );
        assert_eq!(slopdesk_touch_scroll_phase(true, true), 4, "a lift still ENDS");
        assert_eq!(slopdesk_touch_click_count(9999), 255);
        assert_eq!(slopdesk_touch_click_count(0), 1);
    }
}
