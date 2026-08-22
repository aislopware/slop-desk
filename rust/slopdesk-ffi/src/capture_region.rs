//! The DIALOG-EXPAND doors: what the capture region should be, and whether to act on it.
//!
//! Portable on purpose, unlike the `cgwindow` doors next to them. Reading the window list needs a
//! `WindowServer`; deciding what the list MEANS needs nothing, and the `slopdesk-video` module
//! behind these is checked by `golden/golden_vectors.json` on every platform the crate builds for.
//!
//! The tuning constants do not cross. `union_region`'s overlap fraction and `should_retarget`'s
//! per-edge delta are the crate's, and the only Swift caller took both defaults — carrying them
//! over the ABI would have created a second place to change one.

use slopdesk_video::capture_region::{
    DEFAULT_MIN_DELTA, DEFAULT_MIN_OVERLAP_FRACTION, RegionDecision, WindowSnapshot, content_rects,
    region_decision, should_reorigin_to_window_on_geometry, should_retarget, union_region,
};

use crate::video_policy::SlopDeskVideoRect;
use crate::window_list::SlopDeskWindowRecord;
use crate::{borrow, spill};

/// Nothing to do — the region has not moved past hysteresis.
pub const SLOPDESK_REGION_HOLD: u32 = 0;
/// Retarget the capture to the rect written into `out`.
pub const SLOPDESK_REGION_EXPAND: u32 = 1;
/// Go back to the plain window frame. `out` is untouched.
pub const SLOPDESK_REGION_CONTRACT: u32 = 2;

/// The lent records as the crate's snapshots.
///
/// # Safety
/// `windows` must be null, or point to `count` initialised [`SlopDeskWindowRecord`] for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's record array IS the boundary this module documents"
)]
unsafe fn snapshots(windows: *const SlopDeskWindowRecord, count: usize) -> Vec<WindowSnapshot> {
    // SAFETY: the caller's obligation above is restated on `borrow`.
    let lent = unsafe { borrow(windows, count) };
    lent.iter()
        .map(|window| WindowSnapshot {
            window_id: window.window_id,
            owner_pid: window.owner_pid,
            layer: window.layer,
            frame: window.bounds.of(),
        })
        .collect()
}

/// The capture region: the target frame ∪ every panel the OS attached to it, clamped to `display`.
///
/// `windows` is the front-to-back slice strictly IN FRONT of the target — what
/// `slopdesk_cgwindow_in_front_of` answers, passed straight back in.
///
/// # Safety
/// `windows` must be null, or point to `count` initialised [`SlopDeskWindowRecord`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_capture_union_region(
    target: SlopDeskVideoRect,
    target_window_id: u32,
    target_pid: i32,
    windows: *const SlopDeskWindowRecord,
    count: usize,
    display: SlopDeskVideoRect,
) -> SlopDeskVideoRect {
    // SAFETY: the caller's obligation above is restated on `snapshots`.
    let snaps = unsafe { snapshots(windows, count) };
    SlopDeskVideoRect::from(union_region(
        target.of(),
        target_window_id,
        target_pid,
        &snaps,
        display.of(),
        DEFAULT_MIN_OVERLAP_FRACTION,
    ))
}

/// The OPAQUE pieces inside that region — the target, then each panel — so the client can mask the
/// black flank BETWEEN them, which the bounding box cannot express.
///
/// The answer is the count NEEDED — §4.
///
/// # Safety
/// `windows` must be null, or point to `count` initialised [`SlopDeskWindowRecord`] for the call.
/// `out` must be null, or writable for `cap` [`SlopDeskVideoRect`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_capture_content_rects(
    target: SlopDeskVideoRect,
    target_window_id: u32,
    target_pid: i32,
    windows: *const SlopDeskWindowRecord,
    count: usize,
    display: SlopDeskVideoRect,
    out: *mut SlopDeskVideoRect,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is restated on `snapshots`.
    let snaps = unsafe { snapshots(windows, count) };
    let rects: Vec<SlopDeskVideoRect> = content_rects(
        target.of(),
        target_window_id,
        target_pid,
        &snaps,
        display.of(),
        DEFAULT_MIN_OVERLAP_FRACTION,
    )
    .into_iter()
    .map(SlopDeskVideoRect::from)
    .collect();
    // SAFETY: the caller's obligation above is restated on `spill`.
    unsafe { spill(&rects, out, cap) }
}

/// Whether a region change is worth an encoder rebuild: any edge past the crate's hysteresis.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_capture_should_retarget(
    current: SlopDeskVideoRect,
    desired: SlopDeskVideoRect,
) -> bool {
    should_retarget(current.of(), desired.of(), DEFAULT_MIN_DELTA)
}

/// Whether a window MOVE should re-origin the input and cursor mapping to the plain window frame.
///
/// The pair is the ABI's spelling of `CGRect?`: `active_region` is read only when `region_active`.
/// While a region IS in force, the mapping origin belongs to the union and the stream is still
/// union-sized, so re-origining would land clicks in the dialog overhang at the wrong absolute point.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_capture_should_reorigin(
    active_region: SlopDeskVideoRect,
    region_active: bool,
) -> bool {
    should_reorigin_to_window_on_geometry(region_active.then(|| active_region.of()))
}

/// What a freshly measured union means for a capture currently at `current` — `has_current` false
/// being the plain window frame.
///
/// Answers one of the three `SLOPDESK_REGION_*` verdicts. `out` is written only for `EXPAND`.
///
/// # Safety
/// `out` must be null, or writable for one [`SlopDeskVideoRect`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_capture_region_decision(
    union_global: SlopDeskVideoRect,
    window_frame: SlopDeskVideoRect,
    current: SlopDeskVideoRect,
    has_current: bool,
    out: *mut SlopDeskVideoRect,
) -> u32 {
    let decision = region_decision(
        union_global.of(),
        window_frame.of(),
        has_current.then(|| current.of()),
        DEFAULT_MIN_DELTA,
    );
    match decision {
        RegionDecision::Hold => SLOPDESK_REGION_HOLD,
        RegionDecision::Contract => SLOPDESK_REGION_CONTRACT,
        RegionDecision::Expand(target) => {
            if out.is_null() {
                return SLOPDESK_REGION_HOLD;
            }
            // SAFETY: non-null was just checked, and by the caller's obligation it is writable for
            // one record for this call. The value written is a plain `Copy` scalar record.
            unsafe { out.write(SlopDeskVideoRect::from(target)) };
            SLOPDESK_REGION_EXPAND
        }
    }
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

    use super::{
        SLOPDESK_REGION_CONTRACT, SLOPDESK_REGION_EXPAND, SLOPDESK_REGION_HOLD, SlopDeskVideoRect,
        SlopDeskWindowRecord, slopdesk_capture_content_rects, slopdesk_capture_region_decision,
        slopdesk_capture_should_reorigin, slopdesk_capture_should_retarget,
        slopdesk_capture_union_region,
    };

    const fn rect(x: f64, y: f64, width: f64, height: f64) -> SlopDeskVideoRect {
        SlopDeskVideoRect {
            x,
            y,
            width,
            height,
        }
    }

    const DISPLAY: SlopDeskVideoRect = rect(0.0, 0.0, 1920.0, 1080.0);
    const TARGET: SlopDeskVideoRect = rect(120.0, 120.0, 700.0, 500.0);

    const fn record(window_id: u32, owner_pid: i32, layer: i32, bounds: SlopDeskVideoRect) -> SlopDeskWindowRecord {
        SlopDeskWindowRecord {
            bounds,
            window_id,
            owner_pid,
            layer,
        }
    }

    /// The occluder scan's own record array goes straight back in, which is the point of sharing
    /// one layout across the guard.
    #[test]
    fn a_same_pid_dialog_grows_the_region_through_the_door() {
        let windows = [record(1794, 407, 0, rect(30.0, 203.0, 880.0, 448.0))];
        // SAFETY: `windows` is a live local of exactly the length declared.
        let union = unsafe {
            slopdesk_capture_union_region(TARGET, 1783, 407, windows.as_ptr(), windows.len(), DISPLAY)
        };
        assert_eq!(union.x, 30.0);
        assert_eq!(union.width, 880.0);
    }

    /// An empty list is the ordinary case — no dialog is open — and must answer the clamped frame
    /// rather than a null rect a caller would take for "capture nothing".
    #[test]
    fn a_null_window_list_answers_the_plain_frame() {
        // SAFETY: a null array with a zero count is one of the shapes the door documents.
        let union =
            unsafe { slopdesk_capture_union_region(TARGET, 1783, 407, core::ptr::null(), 0, DISPLAY) };
        assert_eq!(union.x, TARGET.x);
        assert_eq!(union.width, TARGET.width);
    }

    /// §4: the answer is the count NEEDED, so a counting call lends nothing and is told what to lend.
    #[test]
    fn the_content_rects_report_the_count_they_need_before_writing_any() {
        let windows = [record(1794, 407, 101, rect(700.0, 300.0, 200.0, 600.0))];
        // SAFETY: a null out with a zero cap is the counting shape the door documents.
        let needed = unsafe {
            slopdesk_capture_content_rects(
                TARGET,
                1783,
                407,
                windows.as_ptr(),
                windows.len(),
                DISPLAY,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 2, "the target, then the popup");
        let mut room = [SlopDeskVideoRect::default(); 2];
        // SAFETY: `room` is a live local writable for exactly the two records declared.
        let written = unsafe {
            slopdesk_capture_content_rects(
                TARGET,
                1783,
                407,
                windows.as_ptr(),
                windows.len(),
                DISPLAY,
                room.as_mut_ptr(),
                room.len(),
            )
        };
        assert_eq!(written, 2);
        assert_eq!(room[0].x, TARGET.x);
        assert_eq!(room[1].x, 700.0);
    }

    #[test]
    fn the_hysteresis_gate_and_the_re_origin_gate_answer_through_the_door() {
        assert!(!slopdesk_capture_should_retarget(TARGET, rect(123.0, 123.0, 703.0, 503.0)));
        assert!(slopdesk_capture_should_retarget(TARGET, rect(30.0, 120.0, 880.0, 531.0)));
        assert!(slopdesk_capture_should_reorigin(SlopDeskVideoRect::default(), false));
        assert!(!slopdesk_capture_should_reorigin(rect(20.0, 70.0, 880.0, 560.0), true));
    }

    #[test]
    fn the_three_verdicts_come_back_with_the_rect_only_when_expanding() {
        let expanded = rect(30.0, 120.0, 880.0, 531.0);
        let mut out = SlopDeskVideoRect::default();
        // SAFETY: `out` is a live local, writable for one record for each call below.
        let verdict = unsafe {
            slopdesk_capture_region_decision(expanded, TARGET, SlopDeskVideoRect::default(), false, &raw mut out)
        };
        assert_eq!(verdict, SLOPDESK_REGION_EXPAND);
        assert_eq!(out.x, 30.0);

        // SAFETY: as above.
        let verdict = unsafe { slopdesk_capture_region_decision(TARGET, TARGET, expanded, true, &raw mut out) };
        assert_eq!(verdict, SLOPDESK_REGION_CONTRACT);

        // SAFETY: as above.
        let verdict = unsafe {
            slopdesk_capture_region_decision(TARGET, TARGET, SlopDeskVideoRect::default(), false, &raw mut out)
        };
        assert_eq!(verdict, SLOPDESK_REGION_HOLD);
    }

    /// A null `out` cannot carry an expansion, so the door reports HOLD rather than announcing a
    /// retarget whose rect the caller never received.
    #[test]
    fn an_expansion_with_nowhere_to_write_it_is_reported_as_hold() {
        let expanded = rect(30.0, 120.0, 880.0, 531.0);
        // SAFETY: null is one of the two shapes the door documents for `out`.
        let verdict = unsafe {
            slopdesk_capture_region_decision(
                expanded,
                TARGET,
                SlopDeskVideoRect::default(),
                false,
                core::ptr::null_mut(),
            )
        };
        assert_eq!(verdict, SLOPDESK_REGION_HOLD);
    }
}
