//! The client's pointer and gesture policies: where input goes, and what a trackpad gesture — or a
//! FINGER — becomes.
//!
//! Every rule here belongs to a view that is never instantiated in a test, so each one is lifted
//! out of it and pinned on its own. The window mechanics stay in the view; the decisions live here.
//!
//! The second half of the module is the phone's, and it is the same split drawn against a different
//! input device. The Mac's half translates a TRACKPAD, which the platform has already recognised
//! into phases and magnifications; the phone's translates raw CONTACTS, because a finger on a
//! remote DESKTOP is not a finger — there is no touch to inject, only a pointer — so the whole
//! vocabulary (tap, long press, drag, two-finger scroll, pan, pinch) is synthesized. Its caller is
//! a `CAMetalLayer` over a `VideoToolbox` decoder, which hang-safety keeps out of the test bundle
//! entirely, so the arithmetic must live where a test can reach it or it is not tested at all.

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
        let routed = if scroll_phase == SCROLL_BEGAN || scroll_phase == SCROLL_MAY_BEGIN {
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
        if scroll_phase == SCROLL_CANCELLED || momentum_phase == MOMENTUM_END {
            self.pinned_remote = None;
        }
        routed
    }
}

/// How far (points) a one-finger contact may wander and still be a TAP rather than a drag.
///
/// Wide enough that a thumb press does not smear into a text selection, tight enough that a
/// deliberate 12 pt drag on a scrollbar thumb is one.
pub const TAP_SLOP: f64 = 10.0;

/// [`TAP_SLOP`] squared, so the escape test compares squared distances and no square root sits in a
/// 120 Hz touch path. A `const` rather than an expression at the comparison, because the product of
/// two literals folds identically and the comparison then reads as the one it is.
const TAP_SLOP_SQUARED: f64 = TAP_SLOP * TAP_SLOP;

/// How long (seconds) a contact must rest inside [`TAP_SLOP`] before it becomes a right click. The
/// system long-press interval — a phone user already has this timing in their hands.
pub const LONG_PRESS_DELAY: f64 = 0.5;

/// How much the span between two contacts must change (points) before the pair reads as a PINCH.
///
/// Generous on purpose: two fingers laid down for a scroll are never perfectly parallel, and a pair
/// that classified as a zoom on 4 pt of finger splay would jump the viewport on every scroll.
pub const PINCH_SPAN_SLOP: f64 = 24.0;

/// How far a pair's centroid must travel (points) before the pair is classified at all. Below this
/// the gesture is still undecided and NOTHING is sent — a two-finger rest must not scroll.
pub const PAIR_TRAVEL_SLOP: f64 = 8.0;

/// The floor of the phone's client zoom ladder. It is 1×, unlike the Mac's 0.25×: the stream
/// already letterboxes into the pane, so minifying below fit shows nothing but more background.
pub const MIN_ZOOM: f64 = 1.0;

/// The ceiling of that ladder.
pub const MAX_ZOOM: f64 = 8.0;

/// One zoom STEP of the footer's − / + controls (the Mac's ladder, same ratio).
pub const ZOOM_STEP: f64 = 1.25;

/// How near 1× a clamped zoom SNAPS to exactly 1×, so repeated − steps settle on actual-size
/// instead of stopping at 1.024× forever (the Mac's `applyZoom` rule).
const UNITY_SNAP: f64 = 0.06;

/// Whether a one-finger contact has left the tap slop.
///
/// I.e. it is a DRAG now, and the pending long press is off. Compared against
/// [`TAP_SLOP_SQUARED`] so no square root sits in a 120 Hz touch path.
#[must_use]
pub fn escapes_tap_slop(dx: f64, dy: f64) -> bool {
    let horizontal = dx * dx;
    let vertical = dy * dy;
    horizontal + vertical > TAP_SLOP_SQUARED
}

/// What a live TWO-CONTACT gesture over a remote desktop drives.
///
/// Decided ONCE, the first time the pair moves past its slop, and held to the gesture's end — the
/// [`ScrollRoutePinner`] rule, for the same reason: a gesture is one intent, and re-deciding it per
/// event lets a pinch's tail scroll the remote document (or a scroll's tail zoom the pane).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TouchPairRoute {
    /// The span between the contacts changed: LOCAL viewport zoom, plus the centroid pan that rides
    /// with it (the map idiom — you zoom and reposition in one gesture).
    Zoom,
    /// The pair translated while the viewport is already zoomed in: LOCAL pan. Nothing reaches the
    /// host. Panning has to be reachable somewhere, and at >1× it is what the user means far more
    /// often than a remote scroll.
    Pan,
    /// The pair translated at 1×: a HOST scroll wheel at the centroid — the same continuous,
    /// phase-carrying scroll the Mac's trackpad sends, so the host replays a native inertial scroll
    /// rather than a phase-less wheel tick.
    Scroll,
}

/// Classifies a two-contact gesture, or `None` while it is still undecided.
///
/// `span_delta` is the signed change in the distance between the two contacts since the pair
/// landed; `centroid_travel` is how far their midpoint has moved since then; `zoom` is the
/// viewport's CURRENT client zoom. Span wins over travel: a pinch always drags its centroid a
/// little, and misreading that as a scroll sends the remote document flying.
#[must_use]
pub fn classify_pair(span_delta: f64, centroid_travel: f64, zoom: f64) -> Option<TouchPairRoute> {
    if span_delta.abs() >= PINCH_SPAN_SLOP {
        return Some(TouchPairRoute::Zoom);
    }
    // `zoom` is the compositor scale the user is looking through; at 1× there is nothing to pan (the
    // whole stream is in the pane), so the pair can only mean a remote scroll. Written as a
    // predicate rather than as `travel < slop` so a NaN travel stays UNDECIDED, which is the answer
    // that sends nothing.
    (centroid_travel >= PAIR_TRAVEL_SLOP).then_some(if zoom > MIN_ZOOM {
        TouchPairRoute::Pan
    } else {
        TouchPairRoute::Scroll
    })
}

/// The zoom a pinch lands on: the zoom the gesture started from, scaled by the live span ratio,
/// clamped to the ladder.
///
/// `span_ratio` is `current_span / base_span`; a non-finite or non-positive ratio — a degenerate
/// pair, both contacts on the same pixel — holds the base.
#[must_use]
pub fn pinched_zoom(base: f64, span_ratio: f64) -> f64 {
    if span_ratio.is_finite() && span_ratio > 0.0 {
        clamp_zoom(base * span_ratio)
    } else {
        clamp_zoom(base)
    }
}

/// One footer zoom STEP from `zoom` (`step_in` is the + button), clamped to the ladder.
#[must_use]
pub fn stepped_zoom(zoom: f64, step_in: bool) -> f64 {
    clamp_zoom(if step_in {
        zoom * ZOOM_STEP
    } else {
        zoom / ZOOM_STEP
    })
}

/// Clamps to `[MIN_ZOOM, MAX_ZOOM]`, and SNAPS to exactly 1× near unity.
#[must_use]
#[expect(
    clippy::manual_clamp,
    reason = "`CLAUDE.md`'s bit-exact float rule: a comparison that SELECTS a float is `maximum`/`minimum`, \
              and `f64::clamp` is a different operation with different NaN behaviour and a panic the \
              release profile would abort on"
)]
pub fn clamp_zoom(zoom: f64) -> f64 {
    if !zoom.is_finite() {
        return MIN_ZOOM;
    }
    // `max`/`min` rather than `clamp` for the repo's bit-exactness rule: a comparison that SELECTS a
    // float is the pair of IEEE operations, never a `<` ternary.
    let mut clamped = f64::min(f64::max(zoom, MIN_ZOOM), MAX_ZOOM);
    if (clamped - 1.0).abs() < UNITY_SNAP {
        clamped = 1.0;
    }
    clamped
}

/// Clamps a normalized pan offset to what the renderer can actually show at `zoom`.
///
/// The iOS surface pans by moving the renderer's UV crop, and the crop's own limit is
/// `0.5·(1 − 1/zoom)` on each axis — the same number the input encoder's normalisation inverts,
/// which is why it is clamped HERE rather than left to the shader: a pan the encoder clamps and the
/// renderer does not is a click that lands somewhere the user is not looking. At 1× the limit is 0,
/// so the crop is pinned centred and there is nothing to pan.
#[must_use]
pub fn clamp_pan(pan: f64, zoom: f64) -> f64 {
    let z = clamp_zoom(zoom);
    if z > MIN_ZOOM {
        let limit = 0.5 * (1.0 - 1.0 / z);
        f64::min(f64::max(pan, -limit), limit)
    } else {
        0.0
    }
}

// -------------------------------------------------------------------------------------------
// The two phase encodings a scroll carries, and the one place they are spelled
// -------------------------------------------------------------------------------------------
//
// `CoreGraphics` puts TWO phase fields on a scroll event and gives them DIFFERENT encodings, which
// is the whole reason this table exists rather than a pair of `as u8` casts.
// `kCGScrollWheelEventScrollPhase` is a bit-per-state field, so its "ended" is 4 and there is room
// for a cancel at 8 and a finger-resting-but-not-yet-scrolling at 128;
// `kCGScrollWheelEventMomentumPhase` is a plain ordinal, so ITS "end" is 3. A three is a changed in
// one field and an end in the other, and nothing about either number says which field it came
// from.
//
// Those ten numbers were spelled in three places — here, in `scroll_reproject`, and again in the
// Mac client's view — and two of the three read different sets of them. That is a defect at zero
// calls per second: the cost of asking is the cost of not asking, and only one of the two answers
// is right. So the vocabulary is here, `scroll_reproject` reads it, and the client asks rather
// than transcribing.

/// `CGScrollPhase`: no phase — a classic wheel tick, or a finger-phase the platform did not name.
pub const SCROLL_NONE: u8 = 0;
/// `CGScrollPhase`: the finger landed and the gesture began.
pub const SCROLL_BEGAN: u8 = 1;
/// `CGScrollPhase`: the finger moved.
pub const SCROLL_CHANGED: u8 = 2;
/// `CGScrollPhase`: the finger lifted.
pub const SCROLL_ENDED: u8 = 4;
/// `CGScrollPhase`: the gesture was taken away rather than finished.
pub const SCROLL_CANCELLED: u8 = 8;
/// `CGScrollPhase`: a finger is resting on the trackpad without scrolling yet.
pub const SCROLL_MAY_BEGIN: u8 = 128;

/// `CGMomentumScrollPhase`: not coasting.
pub const MOMENTUM_NONE: u8 = 0;
/// `CGMomentumScrollPhase`: the coast started.
pub const MOMENTUM_BEGIN: u8 = 1;
/// `CGMomentumScrollPhase`: the coast is running.
pub const MOMENTUM_CONTINUE: u8 = 2;
/// `CGMomentumScrollPhase`: the coast finished. NOT 4 — this field is an ordinal, not a bit set.
pub const MOMENTUM_END: u8 = 3;

/// The `NSEvent.Phase` bits, as `AppKit` spells them. A THIRD encoding of the same idea, which is
/// why the mapping below cannot be a cast: `AppKit`'s ended is `1 << 3` and `CoreGraphics`' is
/// `1 << 2`.
mod ns_phase {
    pub(super) const BEGAN: u32 = 1 << 0;
    pub(super) const CHANGED: u32 = 1 << 2;
    pub(super) const ENDED: u32 = 1 << 3;
    pub(super) const CANCELLED: u32 = 1 << 4;
    pub(super) const MAY_BEGIN: u32 = 1 << 5;
}

/// The `CGScrollPhase` byte for an `AppKit` `NSEvent.Phase` mask, passed through verbatim.
///
/// A MASK, not a value: `AppKit` may set more than one bit, and the order below is the order the
/// gesture runs in, so a began-and-changed frame reads as a began. `.stationary`, an empty mask and
/// any bit `AppKit` adds later all fall to [`SCROLL_NONE`] — a phase this side does not recognise
/// is a phase the host should replay as a plain wheel tick, never as a guess at a gesture edge.
#[must_use]
pub const fn cg_scroll_phase_code(ns_phase: u32) -> u8 {
    if ns_phase & ns_phase::BEGAN != 0 {
        SCROLL_BEGAN
    } else if ns_phase & ns_phase::CHANGED != 0 {
        SCROLL_CHANGED
    } else if ns_phase & ns_phase::ENDED != 0 {
        SCROLL_ENDED
    } else if ns_phase & ns_phase::CANCELLED != 0 {
        SCROLL_CANCELLED
    } else if ns_phase & ns_phase::MAY_BEGIN != 0 {
        SCROLL_MAY_BEGIN
    } else {
        SCROLL_NONE
    }
}

/// The `CGMomentumScrollPhase` byte for an `AppKit` `NSEvent.momentumPhase` mask.
///
/// The same three edges under a different encoding, and the reason this is a second function rather
/// than an argument: an inertial tail has no cancel and no may-begin, so those two bits are not
/// "unmapped here", they do not exist in this field. They fall to [`MOMENTUM_NONE`] with everything
/// else `AppKit` might add.
#[must_use]
pub const fn cg_momentum_phase_code(ns_phase: u32) -> u8 {
    if ns_phase & ns_phase::BEGAN != 0 {
        MOMENTUM_BEGIN
    } else if ns_phase & ns_phase::CHANGED != 0 {
        MOMENTUM_CONTINUE
    } else if ns_phase & ns_phase::ENDED != 0 {
        MOMENTUM_END
    } else {
        MOMENTUM_NONE
    }
}

/// The scroll phase byte for a host scroll built out of touches.
///
/// The phone has no `mayBegin` (no trackpad rest) and no momentum tail (the platform hands the view
/// no coast events), so the momentum phase is always [`MOMENTUM_NONE`] — the host's replay then
/// ends the gesture at the lift instead of inventing an inertia the finger never had.
#[must_use]
pub const fn scroll_phase(is_first: bool, is_last: bool) -> u8 {
    if is_last {
        SCROLL_ENDED
    } else if is_first {
        SCROLL_BEGAN
    } else {
        SCROLL_CHANGED
    }
}

/// Clamps a platform tap count into the wire's byte, floored at 1.
///
/// Both platforms count consecutive taps without bound, and the host reads this only as a
/// click-state hint — so saturating is right, and trapping would be a crash on a very fast tapper.
#[must_use]
pub fn click_count(tap_count: i64) -> u8 {
    u8::try_from(tap_count.max(1)).unwrap_or(u8::MAX)
}

#[cfg(test)]
mod tests {
    use super::{
        MAX_ZOOM, MIN_ZOOM, PINCH_STEP_THRESHOLD, PinchZoomKeyPlanner, ScrollRoutePinner, TouchPairRoute,
        allows_zoom_reset, cg_momentum_phase_code, cg_scroll_phase_code, clamp_pan, clamp_zoom,
        classify_pair, click_count, escapes_tap_slop, extra_unsafe_reset_apps, forwards_pointer,
        is_background_click, pinched_zoom, scroll_phase, stepped_zoom,
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

    /// Bit-for-bit, the way the golden corpus reads a float: an `f64` that is one operation away
    /// from the expected value is a DIFFERENT answer, not a near one.
    fn same(actual: f64, expected: f64) {
        assert!(
            actual.to_bits() == expected.to_bits(),
            "expected {expected:?}, got {actual:?}"
        );
    }

    #[test]
    fn a_resting_finger_stays_a_tap() {
        assert!(!escapes_tap_slop(0.0, 0.0));
        assert!(!escapes_tap_slop(6.0, 6.0), "8.5 pt of roll is still a tap");
        assert!(!escapes_tap_slop(-10.0, 0.0), "exactly the slop is NOT past it");
    }

    #[test]
    fn deliberate_travel_becomes_a_drag() {
        assert!(escapes_tap_slop(12.0, 0.0));
        assert!(escapes_tap_slop(0.0, -12.0));
        assert!(escapes_tap_slop(8.0, 8.0), "11.3 pt diagonally is a drag");
    }

    /// Two fingers laid down and held must not scroll the remote document.
    #[test]
    fn a_pair_at_rest_is_undecided() {
        assert_eq!(classify_pair(3.0, 2.0, 1.0), None);
    }

    #[test]
    fn a_pair_translating_at_actual_size_scrolls_the_host() {
        assert_eq!(classify_pair(0.0, 9.0, 1.0), Some(TouchPairRoute::Scroll));
    }

    /// At >1× there is off-screen stream to reach, and reaching it is what two fingers mean.
    #[test]
    fn a_pair_translating_while_zoomed_pans_the_viewport() {
        assert_eq!(classify_pair(0.0, 40.0, 2.0), Some(TouchPairRoute::Pan));
    }

    /// A pinch always drags its centroid a little; misreading that as a scroll sends the remote
    /// document flying, so the span test runs first and wins outright.
    #[test]
    fn the_span_beats_the_travel() {
        assert_eq!(classify_pair(-30.0, 200.0, 1.0), Some(TouchPairRoute::Zoom));
    }

    #[test]
    fn a_small_splay_is_not_a_pinch() {
        assert_eq!(
            classify_pair(12.0, 20.0, 1.0),
            Some(TouchPairRoute::Scroll),
            "two fingers laid down for a scroll are never perfectly parallel"
        );
    }

    #[test]
    fn a_pinch_scales_from_the_gesture_base() {
        same(pinched_zoom(2.0, 1.5), 3.0);
        same(pinched_zoom(4.0, 0.5), 2.0);
    }

    #[test]
    fn a_pinch_clamps_to_the_ladder() {
        same(pinched_zoom(6.0, 4.0), MAX_ZOOM);
        same(
            pinched_zoom(2.0, 0.1),
            MIN_ZOOM, // the floor is 1×: below fit the stream shows only background
        );
    }

    /// Both contacts on the same pixel means a zero base span, so a non-finite ratio. Holding beats
    /// a NaN reaching the renderer's UV crop.
    #[test]
    fn a_degenerate_pinch_holds_the_base() {
        same(pinched_zoom(2.0, f64::NAN), 2.0);
        same(pinched_zoom(2.0, f64::INFINITY), 2.0);
        same(pinched_zoom(2.0, 0.0), 2.0);
    }

    #[test]
    fn the_stepped_ladder_walks_and_settles_at_actual_size() {
        let mut zoom = stepped_zoom(1.0, true);
        same(zoom, 1.25);
        zoom = stepped_zoom(zoom, true);
        same(zoom, 1.5625);
        // Stepping back out lands on 1.25 and then SNAPS to exactly 1 rather than stopping at
        // 1.0000…4 forever.
        zoom = stepped_zoom(zoom, false);
        same(zoom, 1.25);
        zoom = stepped_zoom(zoom, false);
        same(zoom, 1.0);
        same(stepped_zoom(zoom, false), 1.0);
    }

    #[test]
    fn near_unity_snaps_exactly() {
        same(clamp_zoom(1.04), 1.0);
        same(clamp_zoom(1.08), 1.08);
        same(clamp_zoom(f64::NAN), MIN_ZOOM);
    }

    /// At 1× the whole stream is in the pane, so the crop is pinned centred.
    #[test]
    fn actual_size_cannot_pan() {
        same(clamp_pan(0.4, 1.0), 0.0);
    }

    /// The renderer's UV crop travels `0.5·(1 − 1/zoom)` each way; a pan the encoder clamps and the
    /// renderer does not is a click that lands somewhere the user is not looking.
    #[test]
    fn the_pan_clamp_is_the_crop_limit() {
        same(clamp_pan(10.0, 2.0), 0.25);
        same(clamp_pan(-10.0, 2.0), -0.25);
        same(clamp_pan(0.1, 2.0), 0.1);
        same(clamp_pan(10.0, 4.0), 0.375);
    }

    #[test]
    fn the_scroll_phase_spells_one_gesture() {
        assert_eq!(scroll_phase(true, false), 1, "began");
        assert_eq!(scroll_phase(false, false), 2, "changed");
        assert_eq!(scroll_phase(false, true), 4, "ended");
        assert_eq!(
            scroll_phase(true, true),
            4,
            "a pair that lifts on its first move still ENDS — a began with no end strands it"
        );
    }

    /// The `AppKit` bits, spelled here as the platform spells them so the mapping is checked
    /// against the header rather than against itself.
    const NS_BEGAN: u32 = 1 << 0;
    const NS_STATIONARY: u32 = 1 << 1;
    const NS_CHANGED: u32 = 1 << 2;
    const NS_ENDED: u32 = 1 << 3;
    const NS_CANCELLED: u32 = 1 << 4;
    const NS_MAY_BEGIN: u32 = 1 << 5;

    #[test]
    fn the_two_platform_phase_fields_encode_the_same_edges_differently() {
        assert_eq!(cg_scroll_phase_code(NS_BEGAN), 1);
        assert_eq!(cg_scroll_phase_code(NS_CHANGED), 2);
        assert_eq!(cg_scroll_phase_code(NS_ENDED), 4);
        assert_eq!(cg_scroll_phase_code(NS_CANCELLED), 8);
        assert_eq!(cg_scroll_phase_code(NS_MAY_BEGIN), 128);
        // The whole reason the two are separate functions: an END is 4 in one field and 3 in the
        // other, and a CONTINUE is 2 in both. Reading either through the other's table silently
        // turns a finished coast into a mid-gesture move.
        assert_eq!(cg_momentum_phase_code(NS_BEGAN), 1);
        assert_eq!(cg_momentum_phase_code(NS_CHANGED), 2);
        assert_eq!(cg_momentum_phase_code(NS_ENDED), 3);
    }

    #[test]
    fn an_unnamed_phase_is_a_plain_wheel_tick_rather_than_a_guess() {
        for phase in [0, NS_STATIONARY, 1 << 6, 1 << 31] {
            assert_eq!(cg_scroll_phase_code(phase), 0, "{phase} is not a gesture edge");
            assert_eq!(cg_momentum_phase_code(phase), 0, "{phase} is not a coast edge");
        }
        // A momentum field has no cancel and no may-begin — those bits do not exist there, so they
        // are 0 rather than mapped through the scroll table.
        assert_eq!(cg_momentum_phase_code(NS_CANCELLED), 0);
        assert_eq!(cg_momentum_phase_code(NS_MAY_BEGIN), 0);
    }

    #[test]
    fn a_mask_carrying_two_edges_reads_as_the_earlier_one() {
        // `AppKit` sets more than one bit on the frame a gesture starts moving. The gesture's own
        // order decides, so began wins over changed and changed over ended — a begin the host never
        // saw would leave it replaying a move against no gesture.
        assert_eq!(cg_scroll_phase_code(NS_BEGAN | NS_CHANGED), 1);
        assert_eq!(cg_scroll_phase_code(NS_CHANGED | NS_ENDED), 2);
        assert_eq!(cg_scroll_phase_code(NS_ENDED | NS_CANCELLED), 4);
        assert_eq!(cg_momentum_phase_code(NS_BEGAN | NS_ENDED), 1);
    }

    #[test]
    fn the_touch_scroll_phase_is_the_same_table_the_trackpad_reads() {
        // One table, two callers. If these ever disagree the phone and the Mac are describing the
        // same gesture to the host in two vocabularies.
        assert_eq!(scroll_phase(true, false), cg_scroll_phase_code(NS_BEGAN));
        assert_eq!(scroll_phase(false, false), cg_scroll_phase_code(NS_CHANGED));
        assert_eq!(scroll_phase(false, true), cg_scroll_phase_code(NS_ENDED));
    }

    #[test]
    fn the_click_count_saturates_instead_of_trapping() {
        assert_eq!(click_count(0), 1, "a platform's 0 is still one click");
        assert_eq!(click_count(2), 2, "a double-tap is a real double-click");
        assert_eq!(click_count(9999), 255, "a very fast tapper is not a crash");
        assert_eq!(click_count(i64::MIN), 1);
    }
}
