//! The client's pointer and gesture policies: where input goes, and what a trackpad gesture
//! becomes.
//!
//! Every rule here belongs to a view that is never instantiated in a test, so each one is lifted
//! out of it and pinned on its own. The window mechanics stay in the view; the decisions live here.

use std::collections::BTreeSet;

/// Whether pointer MOTION may forward to the host.
///
/// A satellite window — a dedicated remote desktop, or a popped-out pane — keeps taking POINTER
/// input while it is not the key window, so the user can hover, scroll and click the remote desktop
/// while typing stays in whatever they are working in. The active pane forwards as ever; a
/// background-pointer surface forwards too.
///
/// The read-only gate is a separate check, downstream, on every relay.
#[must_use]
pub const fn forwards_pointer(is_active: bool, background_pointer: bool) -> bool {
    is_active || background_pointer
}

/// Whether a mouse-down is a BACKGROUND click: forwarded to the host with the local window left
/// un-activated and the local pane activation skipped, so local focus does not move at all.
///
/// A KEY window always takes the normal activate path — background mode changes only the not-key
/// case.
#[must_use]
pub const fn is_background_click(background_pointer: bool, window_is_key: bool) -> bool {
    background_pointer && !window_is_key
}

/// App display names where the reset-zoom chord is not a reset.
///
/// The chord means "actual size" in browsers and most documents, but in some apps it means
/// something else entirely — in one IDE it toggles the navigator — so a two-finger double-tap there
/// would rearrange the workspace instead of resetting zoom. This is the swipe allowlist idea
/// inverted: smart zoom stays on everywhere except known-unsafe apps, because a deliberate
/// double-tap is far less accident-prone than a scroll-adjacent swipe. The zoom-in and zoom-out
/// chords stay ungated; they ARE the zoom chords in editors too.
pub const UNSAFE_RESET_APP_NAMES: [&str; 1] = ["Xcode"];

/// Parses the runtime extension list — comma-separated, whitespace-tolerant — so the denylist can
/// grow without a rebuild.
#[must_use]
pub fn extra_unsafe_reset_apps(raw: Option<&str>) -> BTreeSet<String> {
    raw.unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

/// Whether a smart-zoom reset may be sent at a pane bound to this app.
///
/// Matching is by DISPLAY name, the picker's own style, because bundle ids never reach this seam. A
/// desktop pane, or a legacy binding with no recorded app, has an empty name and FAILS OPEN: it
/// streams a whole display whose frontmost app the client cannot know.
#[must_use]
pub fn allows_zoom_reset(app_name: &str, extra_unsafe: &BTreeSet<String>) -> bool {
    app_name.is_empty() || !(UNSAFE_RESET_APP_NAMES.contains(&app_name) || extra_unsafe.contains(app_name))
}

/// Accumulated magnification per zoom step. A full two-finger sweep sums to about one, so this
/// yields around five steps — the ladder browsers and editors zoom by.
pub const PINCH_STEP_THRESHOLD: f64 = 0.2;
/// The per-event cap on emitted steps, so one wild delta, or a burst the platform coalesced, cannot
/// machine-gun the host with keystrokes.
pub const PINCH_MAX_STEPS_PER_EVENT: i32 = 3;

/// Turns a trackpad pinch into discrete zoom-key steps.
///
/// There is no public way to synthesise a real magnify gesture on the host — only scroll wheels and
/// mouse and key events have public constructors — and the private route is broken in the very apps
/// most likely to be zoomed. So the pinch is TRANSLATED into the near-universal zoom key
/// equivalents and rides the existing key path, with no wire change.
///
/// Accumulation carries across the events of one pinch and RESETS at its start, so a residual never
/// leaks from one pinch into the next.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PinchZoomKeyPlanner {
    residual: f64,
}

impl PinchZoomKeyPlanner {
    /// A planner with nothing accumulated.
    #[must_use]
    pub const fn new() -> Self {
        Self { residual: 0.0 }
    }

    /// Resets accumulation, at the start of a new pinch.
    pub const fn begin(&mut self) {
        self.residual = 0.0;
    }

    /// The accumulation carried so far, so a caller that cannot hold this type can hold the one
    /// number that IS its state.
    #[must_use]
    pub const fn residual(&self) -> f64 {
        self.residual
    }

    /// A planner mid-gesture, rebuilt from that number.
    #[must_use]
    pub const fn restored(residual: f64) -> Self {
        Self { residual }
    }

    /// Feeds one magnification delta and returns the SIGNED steps to emit now: positive to zoom in,
    /// negative to zoom out, zero to keep accumulating.
    ///
    /// A non-finite delta is dropped rather than folded, so one bad event cannot poison the
    /// residual for the rest of the gesture.
    pub fn ingest(&mut self, magnification: f64) -> i32 {
        if !magnification.is_finite() {
            return 0;
        }
        self.residual += magnification;
        let mut steps = 0;
        while self.residual >= PINCH_STEP_THRESHOLD && steps < PINCH_MAX_STEPS_PER_EVENT {
            self.residual -= PINCH_STEP_THRESHOLD;
            steps += 1;
        }
        while self.residual <= -PINCH_STEP_THRESHOLD && steps > -PINCH_MAX_STEPS_PER_EVENT {
            self.residual += PINCH_STEP_THRESHOLD;
            steps -= 1;
        }
        steps
    }
}

/// The scroll phase code for a gesture beginning.
const PHASE_BEGAN: u8 = 1;
/// The scroll phase code for a gesture that may begin.
const PHASE_MAY_BEGIN: u8 = 128;
/// The scroll phase code for a cancelled gesture.
const PHASE_CANCELLED: u8 = 8;
/// The momentum phase code for the end of a coast.
const MOMENTUM_ENDED: u8 = 3;

/// Pins the forward-to-host versus pan-the-canvas choice for the LIFETIME of one gesture.
///
/// The choice used to be re-derived per event from live focus, so a focus flip mid-gesture rerouted
/// the gesture's momentum TAIL: a background pane's inertia suddenly swallowed by a newly focused
/// remote window, or a focused pane's coast bleeding into a canvas pan. A gesture is one intent,
/// and its destination is decided where it STARTS and held through the coast.
///
/// Deliberately NOT pinned: the read-only gate stays a live per-event check at the call site, since
/// locking a pane must stop relay immediately, mid-gesture included. And a phase-less wheel tick —
/// a classic mouse — has no beginning to pin at, so it keeps the live decision every tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ScrollRoutePinner {
    pinned_remote: Option<bool>,
}

impl ScrollRoutePinner {
    /// A pinner with no gesture in flight.
    #[must_use]
    pub const fn new() -> Self {
        Self { pinned_remote: None }
    }

    /// Where this gesture is pinned, if it is — the whole state, for a caller that holds it as two
    /// flags rather than as this type.
    #[must_use]
    pub const fn pinned(&self) -> Option<bool> {
        self.pinned_remote
    }

    /// A pinner rebuilt from that answer.
    #[must_use]
    pub const fn restored(pinned_remote: Option<bool>) -> Self {
        Self { pinned_remote }
    }

    /// Decides where THIS event routes, true to forward to the remote window, and maintains the
    /// pin.
    ///
    /// `live_remote` is the caller's current would-be decision, WITHOUT the read-only gate.
    pub const fn route(&mut self, live_remote: bool, scroll_phase: u8, momentum_phase: u8) -> bool {
        let routed = if scroll_phase == PHASE_BEGAN || scroll_phase == PHASE_MAY_BEGIN {
            self.pinned_remote = Some(live_remote);
            live_remote
        } else if let Some(pinned) = self.pinned_remote
            && (scroll_phase != 0 || momentum_phase != 0)
        {
            pinned // mid-gesture, on the glass or coasting: the pin owns the route
        } else {
            // A phase-less wheel tick, or a mid-gesture event with no pin because its beginning
            // predates this view — fall back to the live decision.
            live_remote
        };
        if scroll_phase == PHASE_CANCELLED || momentum_phase == MOMENTUM_ENDED {
            self.pinned_remote = None;
        }
        routed
    }
}

#[cfg(test)]
mod tests {
    use super::{
        PINCH_STEP_THRESHOLD, PinchZoomKeyPlanner, ScrollRoutePinner, allows_zoom_reset,
        extra_unsafe_reset_apps, forwards_pointer, is_background_click,
    };

    #[test]
    fn a_background_surface_keeps_taking_pointer_while_typing_goes_elsewhere() {
        assert!(forwards_pointer(true, false), "the active pane, as ever");
        assert!(forwards_pointer(false, true));
        assert!(!forwards_pointer(false, false));
    }

    #[test]
    fn only_a_background_click_in_a_not_key_window_leaves_local_focus_alone() {
        assert!(is_background_click(true, false));
        assert!(
            !is_background_click(true, true),
            "a key window always takes the normal activate path",
        );
        assert!(!is_background_click(false, false));
    }

    #[test]
    fn the_zoom_reset_is_withheld_only_where_the_chord_means_something_else() {
        let none = extra_unsafe_reset_apps(None);
        assert!(allows_zoom_reset("Google Chrome", &none));
        assert!(!allows_zoom_reset("Xcode", &none));
    }

    /// A pane streaming a whole display cannot know its frontmost app.
    #[test]
    fn a_pane_with_no_recorded_app_fails_open() {
        assert!(allows_zoom_reset("", &extra_unsafe_reset_apps(Some("Xcode"))));
    }

    #[test]
    fn the_denylist_grows_from_the_environment_without_a_rebuild() {
        let extra = extra_unsafe_reset_apps(Some(" Sublime Text , ,Logic Pro "));
        assert!(!allows_zoom_reset("Sublime Text", &extra));
        assert!(!allows_zoom_reset("Logic Pro", &extra));
        assert!(allows_zoom_reset("Google Chrome", &extra));
        assert!(extra_unsafe_reset_apps(Some("")).is_empty());
    }

    #[test]
    fn a_pinch_emits_one_step_per_threshold_of_travel() {
        let mut planner = PinchZoomKeyPlanner::new();
        assert_eq!(planner.ingest(0.1), 0, "still accumulating");
        assert_eq!(planner.ingest(0.1), 1);
        assert_eq!(planner.ingest(-0.4), -2, "and it reverses");
    }

    /// One wild delta must not machine-gun the host with keystrokes.
    #[test]
    fn the_per_event_step_cap_holds_and_the_overflow_stays_accumulated() {
        let mut planner = PinchZoomKeyPlanner::new();
        assert_eq!(planner.ingest(10.0), 3);
        assert_eq!(planner.ingest(0.0), 3, "the rest is still there to spend");
    }

    #[test]
    fn a_residual_never_leaks_from_one_pinch_into_the_next() {
        let mut planner = PinchZoomKeyPlanner::new();
        assert_eq!(planner.ingest(0.19), 0);
        planner.begin();
        assert_eq!(planner.ingest(0.19), 0, "the near-step residual is gone");
        assert_eq!(planner.ingest(PINCH_STEP_THRESHOLD - 0.19), 1);
    }

    #[test]
    fn a_non_finite_delta_is_dropped_rather_than_folded() {
        let mut planner = PinchZoomKeyPlanner::new();
        assert_eq!(planner.ingest(0.1), 0);
        assert_eq!(planner.ingest(f64::NAN), 0);
        assert_eq!(planner.ingest(f64::INFINITY), 0);
        assert_eq!(planner.ingest(0.1), 1, "the residual survived intact");
    }

    /// The failure the pin exists to stop: a focus flip rerouting the gesture's tail.
    #[test]
    fn a_focus_flip_mid_gesture_cannot_reroute_the_coast() {
        let mut pinner = ScrollRoutePinner::new();
        assert!(pinner.route(true, 1, 0), "began, pinned to the remote");
        assert!(pinner.route(false, 2, 0), "changed under it, still remote");
        assert!(pinner.route(false, 0, 1), "and the momentum tail too");
    }

    #[test]
    fn a_gesture_ending_releases_the_pin_for_the_next_one() {
        let mut pinner = ScrollRoutePinner::new();
        pinner.route(true, 1, 0);
        assert!(pinner.route(false, 0, 3), "the coast ends on the old route");
        assert!(!pinner.route(false, 1, 0), "and the next gesture pins fresh");
    }

    #[test]
    fn a_cancelled_gesture_releases_the_pin_too() {
        let mut pinner = ScrollRoutePinner::new();
        pinner.route(true, 1, 0);
        pinner.route(true, 8, 0);
        assert!(!pinner.route(false, 2, 0), "nothing pinned, so live wins");
    }

    /// A classic mouse has no gesture to pin at, so every tick decides for itself.
    #[test]
    fn a_phase_less_wheel_tick_keeps_the_live_decision() {
        let mut pinner = ScrollRoutePinner::new();
        assert!(pinner.route(true, 0, 0));
        assert!(!pinner.route(false, 0, 0));
    }
}
