//! The accessibility tree's host end: park a window on a display, put it back, un-minimize it,
//! resize it, raise it, and sweep an app for what its windows are doing.
//!
//! Four Swift files were the accessibility tree before this — `WindowPlacement.swift`,
//! `WindowGeometryWatcher`'s resize half, `InputInjector`'s raise chain and
//! `WindowFeedAXSupport`'s probe half — and every one of them opened by writing the same six lines:
//! make an application element, cap its messaging timeout, copy `kAXWindows`, walk it calling a
//! private symbol, compare against a `CGWindowID`. That preamble is now written once, in
//! [`resolve`], and the doors below are what each file actually wanted.
//!
//! Three crates meet here, which is why this is in the shim rather than in any of them:
//!
//! | crate | what it answers |
//! | --- | --- |
//! | `slopdesk-apple-ax` | the elements, their frames, and the four effects |
//! | [`slopdesk_video::ax_probe`] | which candidate is the window, which pids to sweep, what a sweep proves |
//! | `slopdesk-apple-cgdisplay` | which display a window is being parked on |
//!
//! ## Why the whole orchestration is here and not in Swift
//! Parking a window is: read its frame, ask where it should go, shrink it, move it, read what it
//! achieved, and roll the whole thing back if the app refused the shrink. Six accessibility
//! round-trips whose ORDER is load-bearing — size before position, or an app clamps the size to the
//! display it is leaving — and one of whose steps is a decision (`window_placement`) that has been
//! Rust with golden vectors for a long time. Leaving the sequence in Swift kept a rule and its only
//! caller on opposite sides of the boundary; every crossing was a chance to reorder them.

use std::sync::Mutex;

use slopdesk_apple_ax::{App, Window};
use slopdesk_video::ax_probe::{Candidate, Frame, Ledger, ProbeBudget, classify, match_window};
use slopdesk_video::geometry::VideoRect;
use slopdesk_video::window_placement;

use crate::video_policy::SlopDeskVideoRect;
use crate::{records_of, spill};

/// The per-message cap every door here opens its application element with, in seconds.
///
/// A quarter of a second. Three of the four Swift originals used exactly this; the fourth — the
/// raise chain — used a third of it, and that difference is kept below rather than averaged away.
const TIMEOUT: f32 = 0.25;

/// The raise chain's cap, in seconds.
///
/// Tighter than [`TIMEOUT`] because the raise sits directly under a click: a missed raise lands the
/// event on the already-frontmost window, which is a small wrong thing, while an eighth of a second
/// of frozen input is a large one. The other doors are not under a click and can afford to wait.
const RAISE_TIMEOUT: f32 = 0.08;

/// A window's frame INSIDE this module — the crate's own rect, in CG global top-left points. What
/// crosses the boundary is [`SlopDeskVideoRect`], which is the same four doubles with a layout C
/// can name.
type Rect = VideoRect;

/// The frame to pass when there is no fallback to offer, and it is NaN rather than zero on purpose.
///
/// Every comparison against a NaN is false, so a fallback match against this can never succeed —
/// while a zero rect would match a genuinely empty window sitting at the global origin, which is
/// what a window being torn down looks like for a frame or two.
const NO_FALLBACK: Rect = Rect::xywh(f64::NAN, f64::NAN, f64::NAN, f64::NAN);

/// The window `window_id` of `pid`, resolved through the whole preamble, or `None`.
///
/// `bounds` is the frame to fall back to when the private id symbol answers for NO candidate at
/// all, which is what a locked screen does. Pass a degenerate rect to refuse the fallback outright.
fn resolve(pid: i32, window_id: u32, bounds: Rect, timeout: f32) -> Option<(App, Window)> {
    let app = App::new(pid, timeout);
    let windows = app.windows();
    let candidates: Vec<Candidate> = windows
        .iter()
        .map(|window| {
            Candidate {
                id: window.id(),
                frame: window.frame().map(|frame| {
                    Frame {
                        x: frame.x,
                        y: frame.y,
                        width: frame.width,
                        height: frame.height,
                    }
                }),
            }
        })
        .collect();
    let wanted = Frame {
        x: bounds.origin.x,
        y: bounds.origin.y,
        width: bounds.size.width,
        height: bounds.size.height,
    };
    let index = match_window(&candidates, window_id, wanted)?;
    let mut windows = windows;
    if index >= windows.len() {
        return None;
    }
    Some((app, windows.swap_remove(index)))
}

/// A window's frame as `slopdesk-apple-ax` answers it, as the rect the rest of the tree speaks.
fn rect_of(window: &Window) -> Option<Rect> {
    window
        .frame()
        .map(|frame| Rect::xywh(frame.x, frame.y, frame.width, frame.height))
}

/// Put `window` back at `frame`: ORIGIN first, then size.
///
/// The inverse order of the park, and for the inverse reason — crossing back to the roomier display
/// before growing is what lets the size take at all.
fn restore(window: &Window, frame: Rect) {
    let _ = window.set_origin(frame.origin.x, frame.origin.y);
    let _ = window.set_size(frame.size.width, frame.size.height);
}

// ---------------------------------------------------------------------------------- //
// Trust
// ---------------------------------------------------------------------------------- //

/// Whether this process holds the Accessibility grant.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_is_trusted() -> bool {
    slopdesk_apple_ax::is_trusted()
}

/// Asks for the Accessibility grant with the system prompt, and answers whether it is already held.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_prompt_for_trust() -> bool {
    slopdesk_apple_ax::prompt_for_trust()
}

// ---------------------------------------------------------------------------------- //
// Placing one window
// ---------------------------------------------------------------------------------- //

/// What a successful park answers: the size the window actually took, and where it was before.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct SlopDeskAxPark {
    /// The window's pre-move global frame, for putting it back later.
    pub original: SlopDeskVideoRect,
    /// The size the window ACHIEVED, which is not necessarily the size it was asked for.
    pub achieved_width: f64,
    /// The achieved height, on the same terms.
    pub achieved_height: f64,
}

/// Moves the window fully onto `display_id`, shrinking it first if it does not fit.
///
/// The order is size-then-position, and it is load-bearing: an app asked to move across displays
/// before it is asked to shrink clamps the shrink against the display it is LEAVING.
///
/// Answers `false` and touches nothing further on every failure — the window is not found, its
/// pre-move frame is unreadable, the position write is refused, or the app clamped the shrink so
/// the window still overhangs. On the last two the window is rolled BACK to where it started, so
/// the caller's fallback captures it cleanly in place rather than over-cropping a half-moved one.
///
/// # Safety
/// `out` must be null or a writable [`SlopDeskAxPark`]. It is written only on `true`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ax_park_window(
    window_id: u32,
    pid: i32,
    display_id: u32,
    out: *mut SlopDeskAxPark,
) -> bool {
    if pid <= 0 || display_id == 0 {
        return false;
    }
    let Some((_app, window)) = resolve(pid, window_id, NO_FALLBACK, TIMEOUT) else {
        return false;
    };
    let Some(original) = rect_of(&window) else {
        return false;
    };
    let display = slopdesk_apple_cgdisplay::bounds_of(display_id);
    let plan = window_placement::place(
        original.size.width,
        original.size.height,
        display.origin.x,
        display.origin.y,
        display.size.width,
        display.size.height,
    );
    if plan.needs_resize {
        let _ = window.set_size(plan.width, plan.height);
    }
    if !window.set_origin(plan.origin_x, plan.origin_y) {
        restore(&window, original);
        return false;
    }
    let achieved = rect_of(&window).map_or((plan.width, plan.height), |frame| {
        (frame.size.width, frame.size.height)
    });
    if !window_placement::fits(achieved.0, achieved.1, display.size.width, display.size.height) {
        restore(&window, original);
        return false;
    }
    if out.is_null() {
        return true;
    }
    // SAFETY: the caller's obligation, above — non-null and writable for one record.
    unsafe {
        out.write(SlopDeskAxPark {
            original: SlopDeskVideoRect::from(original),
            achieved_width: achieved.0,
            achieved_height: achieved.1,
        });
    }
    true
}

/// Puts the window back at `frame` — the inverse of a park, origin before size.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_restore_window(window_id: u32, pid: i32, frame: SlopDeskVideoRect) -> bool {
    if pid <= 0 {
        return false;
    }
    let Some((_app, window)) = resolve(pid, window_id, NO_FALLBACK, TIMEOUT) else {
        return false;
    };
    restore(&window, frame.of());
    true
}

/// The window was not found, or the un-minimize was refused.
pub const SLOPDESK_AX_DEMINIATURIZE_FAILED: i32 = 0;
/// The window was not minimized, so nothing was written.
pub const SLOPDESK_AX_DEMINIATURIZE_NOT_MINIMIZED: i32 = 1;
/// The window was minimized and has been asked to come back.
pub const SLOPDESK_AX_DEMINIATURIZE_RESTORING: i32 = 2;

/// Un-minimizes the window so the window server paints it again.
///
/// A minimized window is never rendered, so capturing one streams nothing. Read-then-write: a
/// window that is not minimized is left completely untouched, because writing `false` to an
/// already-false attribute is an app-visible event on some apps and a no-op on none.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_deminiaturize(window_id: u32, pid: i32) -> i32 {
    if pid <= 0 {
        return SLOPDESK_AX_DEMINIATURIZE_FAILED;
    }
    let Some((_app, window)) = resolve(pid, window_id, NO_FALLBACK, TIMEOUT) else {
        return SLOPDESK_AX_DEMINIATURIZE_FAILED;
    };
    if window.minimized() != Some(true) {
        return SLOPDESK_AX_DEMINIATURIZE_NOT_MINIMIZED;
    }
    if window.set_minimized(false) {
        SLOPDESK_AX_DEMINIATURIZE_RESTORING
    } else {
        SLOPDESK_AX_DEMINIATURIZE_FAILED
    }
}

/// Resizes the window and answers the size it ACTUALLY took.
///
/// `displays` is every display's bounds, used for one thing: re-anchoring the window at its
/// display's top-left corner BEFORE the size write. macOS clamps an accessibility size-set to keep
/// the window on screen from its CURRENT position, so a window parked mid-screen cannot grow to
/// fill the display until it has been moved to the origin first. Lending nothing skips the
/// re-anchor, which is the right call for a caller that already knows the window is at an origin.
///
/// Answers `false` when the window is not found or refuses the size write — a fixed-size window and
/// a hung app both land here, and both mean the caller keeps its old encoder and sends no
/// acknowledgement.
///
/// # Safety
/// `displays` must be null or point to `display_count` readable rects. `out_width` and `out_height`
/// must be null or writable; both are written only on `true`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ax_resize_window(
    window_id: u32,
    pid: i32,
    width: f64,
    height: f64,
    displays: *const SlopDeskVideoRect,
    display_count: usize,
    out_width: *mut f64,
    out_height: *mut f64,
) -> bool {
    if pid <= 0 {
        return false;
    }
    let Some((_app, window)) = resolve(pid, window_id, NO_FALLBACK, TIMEOUT) else {
        return false;
    };
    // SAFETY: the caller's obligation, above — null or `display_count` readable rects.
    let displays: &[SlopDeskVideoRect] = unsafe { records_of(displays, display_count) };
    let displays: Vec<Rect> = displays.iter().map(|rect| rect.of()).collect();
    if let Some(live) = rect_of(&window)
        && let Some(display) = slopdesk_video::window_list::display_for_window_frame(live, &displays)
    {
        // Best-effort: a window that refuses the position write still gets the size write below.
        let _ = window.set_origin(display.origin.x, display.origin.y);
    }
    if !window.set_size(width.max(1.0), height.max(1.0)) {
        return false;
    }
    let achieved = rect_of(&window).map_or((width, height), |frame| (frame.size.width, frame.size.height));
    if !out_width.is_null() {
        // SAFETY: the caller's obligation, above.
        unsafe { out_width.write(achieved.0) };
    }
    if !out_height.is_null() {
        // SAFETY: the caller's obligation, above.
        unsafe { out_height.write(achieved.1) };
    }
    true
}

// ---------------------------------------------------------------------------------- //
// Raising one window, repeatedly
// ---------------------------------------------------------------------------------- //

/// One window's raise target, resolved at most once.
///
/// A handle rather than a function because the resolution is what costs: listing an app's windows
/// and asking each one for its id is O(windows) synchronous round-trips, and the raise runs on
/// every first event of every interaction. The Swift this replaces cached the element for exactly
/// this reason; a stateless door would have thrown that away and called it a simplification.
#[derive(Debug)]
pub struct SlopDeskAxRaiser {
    /// The process whose window is raised.
    pid: i32,
    /// The window, by the id the rest of the host knows it by.
    window_id: u32,
    /// The resolved pair, once. A stale element is harmless — every accessibility call on one
    /// answers an error rather than faulting — so it is never invalidated, only replaced when the
    /// resolution failed and is retried.
    resolved: Mutex<Option<(App, Window)>>,
}

/// Views a raiser handle as a shared reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_ax_raiser_new`].
#[expect(
    unsafe_code,
    reason = "the shim's whole job is turning a caller's pointer into a reference"
)]
const unsafe fn raiser<'a>(handle: *const SlopDeskAxRaiser) -> Option<&'a SlopDeskAxRaiser> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: the caller's obligation, above.
    Some(unsafe { &*handle })
}

/// Builds a raiser for one window of one process. Never null.
///
/// # Safety
/// The answer must be passed to [`slopdesk_ax_raiser_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_raiser_new(pid: i32, window_id: u32) -> *mut SlopDeskAxRaiser {
    Box::into_raw(Box::new(SlopDeskAxRaiser {
        pid,
        window_id,
        resolved: Mutex::new(None),
    }))
}

/// Releases a raiser. Null is inert.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_ax_raiser_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ax_raiser_free(handle: *mut SlopDeskAxRaiser) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free.
    drop(unsafe { Box::from_raw(handle) });
}

/// Raises and focuses the window; answers whether it had a target to raise.
///
/// `bounds` is the window's current frame, used only as the fallback when the private id symbol
/// answers for no candidate at all — a locked screen. It is passed per call rather than held
/// because the geometry watcher already tracks it and a second copy would go stale.
///
/// This does NOT bring the application forward. Ordering the raise against an activation is the
/// caller's, and it stays there.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ax_raiser_raise(
    handle: *mut SlopDeskAxRaiser,
    bounds: SlopDeskVideoRect,
) -> bool {
    // SAFETY: the caller's obligation, above.
    let Some(state) = (unsafe { raiser(handle) }) else {
        return false;
    };
    if state.pid <= 0 {
        return false;
    }
    let Ok(mut resolved) = state.resolved.lock() else {
        return false;
    };
    if resolved.is_none() {
        *resolved = resolve(state.pid, state.window_id, bounds.of(), RAISE_TIMEOUT);
    }
    let Some((app, window)) = resolved.as_ref() else {
        return false;
    };
    let _ = window.raise();
    app.focus(window);
    true
}

// ---------------------------------------------------------------------------------- //
// Sweeping an app
// ---------------------------------------------------------------------------------- //

/// The budgeted minimized probe: which off-screen windows are minimized, and which are real windows
/// at all.
#[derive(Debug)]
pub struct SlopDeskAxProbe {
    /// Which pids may be swept this tick, and what has been swept recently.
    state: Mutex<(ProbeBudget, Ledger)>,
}

/// Views a probe handle as a shared reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_ax_probe_new`].
#[expect(
    unsafe_code,
    reason = "the shim's whole job is turning a caller's pointer into a reference"
)]
const unsafe fn probe<'a>(handle: *const SlopDeskAxProbe) -> Option<&'a SlopDeskAxProbe> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: the caller's obligation, above.
    Some(unsafe { &*handle })
}

/// Builds a probe. Never null.
///
/// # Safety
/// The answer must be passed to [`slopdesk_ax_probe_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_ax_probe_new() -> *mut SlopDeskAxProbe {
    Box::into_raw(Box::new(SlopDeskAxProbe {
        state: Mutex::new((ProbeBudget::new(), Ledger::new())),
    }))
}

/// Releases a probe. Null is inert.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_ax_probe_new`] that has not already been
/// freed, and no call on it may be in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ax_probe_free(handle: *mut SlopDeskAxProbe) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free.
    drop(unsafe { Box::from_raw(handle) });
}

/// One off-screen window, and the process that owns it.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct SlopDeskAxOffScreen {
    /// The window's `CGWindowID`.
    pub window_id: u32,
    /// The owning process.
    pub pid: i32,
}

/// What the classification answers for one window.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct SlopDeskAxVerdict {
    /// The window's `CGWindowID`.
    pub window_id: u32,
    /// Whether the accessibility tree lists it at all. A window it does NOT list is a phantom the
    /// window server reports and no person can look at, which is the feed's inclusion gate.
    pub ax_listed: bool,
    /// Whether it is minimized into the Dock, as opposed to sitting on another Space.
    pub minimized: bool,
}

/// Classifies every off-screen window, sweeping at most a few applications on the way.
///
/// `now` is the CALLER's clock, so a whole tick shares one instant; reading a clock per pid would
/// age two sweeps started in the same tick differently.
///
/// The sweep is budgeted because it is the only thing in the window feed that can BLOCK: a hung app
/// costs its whole messaging timeout, so an unbounded tick is one beachballing app away from
/// stalling the feed. Windows whose pid was not swept this tick answer from the last sweep, and
/// windows never swept at all appear in the answer with no verdict rather than a guessed one.
///
/// Answers the number of records it NEEDS; call again with a buffer that size when it exceeds
/// `cap`. A second call re-classifies from the ledger and sweeps nothing new — the budget already
/// stamped this tick's pids — so a retry is cheap and stable.
///
/// # Safety
/// `windows` must be null or point to `count` readable records, and `out` null or writable for
/// `cap` records.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ax_probe_classify(
    handle: *mut SlopDeskAxProbe,
    windows: *const SlopDeskAxOffScreen,
    count: usize,
    now: f64,
    out: *mut SlopDeskAxVerdict,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, above.
    let Some(state) = (unsafe { probe(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation, above — null or `count` readable records.
    let windows: &[SlopDeskAxOffScreen] = unsafe { records_of(windows, count) };
    let Ok(mut state) = state.state.lock() else {
        return 0;
    };
    let (budget, ledger) = &mut *state;

    let mut pids: Vec<i32> = windows.iter().map(|window| window.pid).collect();
    pids.sort_unstable();
    pids.dedup();
    for pid in budget.pids_to_probe(&pids, now) {
        let Some(sweep) = sweep(pid) else {
            // A FAILED sweep is not folded. Stale beats absent: folding an empty answer would mark
            // every one of that app's windows a phantom and the feed would drop them all.
            continue;
        };
        let off_screen: Vec<u32> = windows
            .iter()
            .filter(|window| window.pid == pid)
            .map(|window| window.window_id)
            .collect();
        ledger.fold(&sweep, &off_screen);
    }

    let ids: Vec<u32> = windows.iter().map(|window| window.window_id).collect();
    ledger.retain(&ids);
    let classified = classify(ledger, &ids);
    let records: Vec<SlopDeskAxVerdict> = ids
        .iter()
        .map(|id| {
            SlopDeskAxVerdict {
                window_id: *id,
                ax_listed: classified.ax_listed.binary_search(id).is_ok(),
                minimized: classified.minimized.binary_search(id).is_ok(),
            }
        })
        .collect();
    // SAFETY: the caller's obligation, above — null or writable for `cap` records.
    unsafe { spill(&records, out, cap) }
}

/// One application's accessibility window sweep: every listed window's id and minimized flag, or
/// `None` when the sweep itself failed.
///
/// `None` and an EMPTY answer are different and the caller depends on it: empty means the app
/// genuinely lists no windows, which is evidence, while `None` means the question could not be put,
/// which is not.
fn sweep(pid: i32) -> Option<Vec<(u32, bool)>> {
    let app = App::new(pid, TIMEOUT);
    let windows = app.windows();
    if windows.is_empty() {
        // Indistinguishable here from a refusal, and treated as one. An app with genuinely zero
        // windows owns none of the off-screen ids this is being asked about, so folding its empty
        // sweep could only mark other apps' windows absent.
        return None;
    }
    Some(
        windows
            .iter()
            .filter_map(|window| Some((window.id()?, window.minimized().unwrap_or(false))))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use slopdesk_video::geometry::VideoRect;

    use super::{
        SLOPDESK_AX_DEMINIATURIZE_FAILED, SlopDeskAxOffScreen, SlopDeskAxPark, SlopDeskAxVerdict,
        slopdesk_ax_deminiaturize, slopdesk_ax_is_trusted, slopdesk_ax_park_window,
        slopdesk_ax_probe_classify, slopdesk_ax_probe_free, slopdesk_ax_probe_new, slopdesk_ax_raiser_free,
        slopdesk_ax_raiser_new, slopdesk_ax_raiser_raise, slopdesk_ax_resize_window,
        slopdesk_ax_restore_window,
    };
    use crate::video_policy::SlopDeskVideoRect;

    /// Null is inert on every door that takes a handle, and a pid that is not a process is a
    /// refusal rather than a fault on every door that takes one. Between them these are the two
    /// arms a headless suite can reach, and they are the ones a caller hits in production when an
    /// app quits mid-session.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn every_door_refuses_rather_than_faults() {
        let rect = SlopDeskVideoRect::from(VideoRect::xywh(0.0, 0.0, 100.0, 100.0));
        unsafe {
            assert!(!slopdesk_ax_raiser_raise(std::ptr::null_mut(), rect));
            assert_eq!(
                slopdesk_ax_probe_classify(
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    0,
                    0.0,
                    std::ptr::null_mut(),
                    0
                ),
                0
            );
            assert!(!slopdesk_ax_park_window(1, 0, 1, std::ptr::null_mut()));
            assert!(!slopdesk_ax_park_window(1, i32::MAX, 0, std::ptr::null_mut()));
            assert!(!slopdesk_ax_resize_window(
                1,
                0,
                10.0,
                10.0,
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut()
            ));
            assert_eq!(slopdesk_ax_deminiaturize(1, 0), SLOPDESK_AX_DEMINIATURIZE_FAILED);
        }
        assert!(!slopdesk_ax_restore_window(1, 0, rect));
        // The trust read is a fact about the process, so all this can assert is that asking twice
        // agrees — which is the property that lets it be called on every status refresh.
        assert_eq!(slopdesk_ax_is_trusted(), slopdesk_ax_is_trusted());
    }

    /// A window of a process that does not exist is not found, so the park writes NOTHING — the
    /// record the caller lent is left exactly as it was. A door that wrote a zeroed record on
    /// failure would look identical to one that parked a window at the origin.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn a_failed_park_leaves_the_caller_s_record_untouched() {
        let mut record = SlopDeskAxPark {
            original: SlopDeskVideoRect::from(VideoRect::xywh(7.0, 8.0, 9.0, 10.0)),
            achieved_width: 11.0,
            achieved_height: 12.0,
        };
        // SAFETY: `record` is a live local for the whole call.
        let parked = unsafe { slopdesk_ax_park_window(1, i32::MAX, 1, &raw mut record) };
        assert!(!parked);
        // Bit-exact: the door either wrote the whole record or did not touch it, so anything but
        // the sentinel the caller put there is a write that should not have happened.
        assert_eq!(record.achieved_width.to_bits(), 11.0_f64.to_bits());
        assert_eq!(record.original.x.to_bits(), 7.0_f64.to_bits());
    }

    /// A raiser for a process that is not there is built, used and freed without faulting — the
    /// resolution simply never succeeds, and the door reports it every time rather than caching a
    /// failure as if it were an answer.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn a_raiser_for_a_process_that_is_gone_keeps_answering_no() {
        let handle = slopdesk_ax_raiser_new(i32::MAX, 42);
        assert!(!handle.is_null());
        // SAFETY: `handle` is live for the whole block and freed exactly once at the end.
        unsafe {
            for _ in 0..256 {
                assert!(!slopdesk_ax_raiser_raise(
                    handle,
                    SlopDeskVideoRect::from(VideoRect::xywh(0.0, 0.0, 1.0, 1.0))
                ));
            }
            slopdesk_ax_raiser_free(handle);
        }
    }

    /// The classify door reports the count it NEEDS, writes nothing into a short buffer, and
    /// answers a verdict record per window asked about — including for windows nothing is known
    /// about, which carry `false` for both flags rather than being silently dropped.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn classify_reports_what_it_needs_before_it_writes() {
        let handle = slopdesk_ax_probe_new();
        let windows = [
            SlopDeskAxOffScreen {
                window_id: 5,
                pid: i32::MAX,
            },
            SlopDeskAxOffScreen {
                window_id: 6,
                pid: i32::MAX,
            },
        ];
        // SAFETY: `handle` is live, `windows` is a live array of two, and the out buffer below is
        // sized from the count the first call reported.
        unsafe {
            let needed = slopdesk_ax_probe_classify(
                handle,
                windows.as_ptr(),
                windows.len(),
                0.0,
                std::ptr::null_mut(),
                0,
            );
            assert_eq!(needed, 2);
            let mut out = [SlopDeskAxVerdict::default(); 2];
            assert_eq!(
                slopdesk_ax_probe_classify(handle, windows.as_ptr(), windows.len(), 0.0, out.as_mut_ptr(), 1),
                2,
                "a short buffer reports the need rather than truncating"
            );
            assert_eq!(out[0].window_id, 0, "and writes nothing");
            assert_eq!(
                slopdesk_ax_probe_classify(
                    handle,
                    windows.as_ptr(),
                    windows.len(),
                    0.0,
                    out.as_mut_ptr(),
                    out.len()
                ),
                2
            );
            assert_eq!(out[0].window_id, 5);
            assert_eq!(out[1].window_id, 6);
            assert!(!out[0].ax_listed, "a pid that cannot be swept proves nothing");
            slopdesk_ax_probe_free(handle);
        }
    }

    /// The probe handle survives ten thousand classifications without the ledger or the stamp map
    /// growing — the retain pass drops every window that stopped being asked about, and the budget
    /// drops every pid that stopped being offered.
    #[test]
    #[expect(unsafe_code, reason = "calling C entry points is what this module is")]
    fn a_probe_holds_nothing_for_windows_it_stopped_being_asked_about() {
        let handle = slopdesk_ax_probe_new();
        // SAFETY: `handle` is live for the whole block and freed exactly once at the end.
        unsafe {
            for tick in 0..10_000_u32 {
                let windows = [SlopDeskAxOffScreen {
                    window_id: tick,
                    pid: i32::MAX - tick.cast_signed(),
                }];
                let mut out = [SlopDeskAxVerdict::default(); 1];
                assert_eq!(
                    slopdesk_ax_probe_classify(
                        handle,
                        windows.as_ptr(),
                        1,
                        f64::from(tick),
                        out.as_mut_ptr(),
                        1
                    ),
                    1
                );
            }
            slopdesk_ax_probe_free(handle);
        }
    }
}
