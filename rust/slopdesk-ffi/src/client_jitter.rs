//! How jittery the link is, and how deep the buffer should be because of it.
//!
//! `rust/slopdesk-video`'s `client_jitter` owns both: the RFC3550 inter-arrival estimate, computed
//! entirely in the client's own monotonic clock so no cross-machine skew can enter it, and the
//! asymmetric depth controller it feeds — grow fast, shrink slow.
//!
//! ## Both cross as records, because both are read whole
//! An estimator is three numbers and a controller is seven, and the near side reads every one of
//! them, so §4b makes each a value that rides in and out of the fold rather than a handle. Both
//! come back in through the crate's `restored`, not its `new`: `new` orders the bounds and places
//! the initial depth inside them, which is right once and wrong every time after — re-clamping a
//! live recommendation would quietly undo a grow.
//!
//! ## An absent stamp crosses as a flag
//! The first arrival has no interval and the second has no second difference, which is what keeps
//! an initial burst from emitting a spurious spike. A sentinel time cannot say "none yet", so the
//! presence rides beside the value.

use slopdesk_video::client_jitter::{
    AdaptiveJitterController, DEFAULT_JITTER_SAFETY, DEFAULT_SHRINK_COOLDOWN_FRAMES, OwdJitterEstimator,
};

/// The one-way-delay jitter estimate, whole, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskOwdJitter {
    /// When the previous frame arrived, in client-monotonic seconds.
    pub last_arrival: f64,
    /// Whether any frame has arrived — a stamp of zero is a time, not an absence.
    pub has_last_arrival: bool,
    /// The previous inter-arrival interval, for the second difference.
    pub last_inter_arrival: f64,
    /// Whether there have been two arrivals yet.
    pub has_last_inter_arrival: bool,
    /// The smoothed jitter, in seconds.
    pub jitter_seconds: f64,
}

/// The adaptive jitter-buffer depth controller, whole, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskAdaptiveJitter {
    /// The floor — never fewer frames than this.
    pub min_depth: u32,
    /// The ceiling — the pacer's hard cap.
    pub max_depth: u32,
    /// The presentation cadence, which converts jitter seconds into a frame count.
    pub fps: f64,
    /// The buffer-sizing multiple.
    pub jitter_safety: f64,
    /// How many consecutive low-jitter frames a single one-step shrink costs.
    pub shrink_cooldown_frames: u32,
    /// The live recommendation, in frames.
    pub target_depth: u32,
    /// How far into the cooldown the run is.
    pub shrink_run: u32,
}

/// An estimator with no samples.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_owd_jitter_new() -> SlopDeskOwdJitter {
    jitter_record(&OwdJitterEstimator::new())
}

/// Folds one frame arrival, in client-monotonic seconds, and answers the smoothed jitter.
///
/// # Safety
/// `estimator` must point to one live, writable record for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_owd_jitter_note(estimator: *mut SlopDeskOwdJitter, arrival: f64) -> f64 {
    if estimator.is_null() {
        return 0.0;
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let mut working = jitter_of(unsafe { std::ptr::read(estimator) });
    working.note(arrival);
    // SAFETY: as above; writable for one record.
    unsafe { std::ptr::write(estimator, jitter_record(&working)) };
    working.jitter_seconds()
}

/// The smoothed jitter as microseconds, clamped to the wire field.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_owd_jitter_micros(estimator: SlopDeskOwdJitter) -> u32 {
    jitter_of(estimator).jitter_micros()
}

/// The buffer-sizing multiple the client uses when nothing was configured.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_adaptive_jitter_default_safety() -> f64 {
    DEFAULT_JITTER_SAFETY
}

/// The cooldown the client uses when nothing was configured, in frames.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_adaptive_jitter_default_cooldown() -> u32 {
    DEFAULT_SHRINK_COOLDOWN_FRAMES
}

/// A controller whose bounds are ordered and whose initial depth is placed inside them, so no
/// caller's configuration can produce an empty range.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub const extern "C" fn slopdesk_adaptive_jitter_new(
    min_depth: u32,
    max_depth: u32,
    fps: f64,
    initial_depth: u32,
    jitter_safety: f64,
    shrink_cooldown_frames: u32,
) -> SlopDeskAdaptiveJitter {
    controller_record(&AdaptiveJitterController::new(
        min_depth,
        max_depth,
        fps,
        initial_depth,
        jitter_safety,
        shrink_cooldown_frames,
    ))
}

/// The depth that would absorb the given jitter. A pure query — the controller does not move.
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
#[unsafe(no_mangle)]
pub extern "C" fn slopdesk_adaptive_jitter_depth_for(
    controller: SlopDeskAdaptiveJitter,
    jitter_seconds: f64,
) -> u32 {
    controller_of(controller).depth_for_jitter(jitter_seconds)
}

/// Folds one decoded frame's smoothed jitter and answers the recommendation.
///
/// # Safety
/// `controller` must point to one live, writable record for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_adaptive_jitter_note_frame(
    controller: *mut SlopDeskAdaptiveJitter,
    jitter_seconds: f64,
) -> u32 {
    // SAFETY: the caller's obligation above.
    unsafe { folded(controller, |working| working.note_frame(jitter_seconds)) }
}

/// A real starvation happened: grow one step at once, and restart the cooldown.
///
/// # Safety
/// As [`slopdesk_adaptive_jitter_note_frame`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_adaptive_jitter_note_underrun(
    controller: *mut SlopDeskAdaptiveJitter,
) -> u32 {
    // SAFETY: as above.
    unsafe { folded(controller, AdaptiveJitterController::note_underrun) }
}

/// Runs one fold over the caller's controller and writes it back.
///
/// # Safety
/// `controller` must be null, or point to one live, writable record for the call.
#[expect(
    unsafe_code,
    reason = "reconstituting the caller's controller IS the boundary this module documents"
)]
unsafe fn folded(
    controller: *mut SlopDeskAdaptiveJitter,
    fold: impl FnOnce(&mut AdaptiveJitterController) -> u32,
) -> u32 {
    if controller.is_null() {
        return 0;
    }
    // SAFETY: non-null and, by the caller's obligation, live for this call.
    let mut working = controller_of(unsafe { std::ptr::read(controller) });
    let depth = fold(&mut working);
    // SAFETY: as above; writable for one record.
    unsafe { std::ptr::write(controller, controller_record(&working)) };
    depth
}

/// The crate's estimator, rebuilt from the record that crossed.
const fn jitter_of(record: SlopDeskOwdJitter) -> OwdJitterEstimator {
    OwdJitterEstimator::restored(
        if record.has_last_arrival {
            Some(record.last_arrival)
        } else {
            None
        },
        if record.has_last_inter_arrival {
            Some(record.last_inter_arrival)
        } else {
            None
        },
        record.jitter_seconds,
    )
}

/// The record for an estimator that has just folded.
fn jitter_record(working: &OwdJitterEstimator) -> SlopDeskOwdJitter {
    let arrival = working.last_arrival();
    let inter = working.last_inter_arrival();
    SlopDeskOwdJitter {
        last_arrival: arrival.unwrap_or(0.0),
        has_last_arrival: arrival.is_some(),
        last_inter_arrival: inter.unwrap_or(0.0),
        has_last_inter_arrival: inter.is_some(),
        jitter_seconds: working.jitter_seconds(),
    }
}

/// The crate's controller, rebuilt from the record that crossed.
const fn controller_of(record: SlopDeskAdaptiveJitter) -> AdaptiveJitterController {
    AdaptiveJitterController::restored(
        record.min_depth,
        record.max_depth,
        record.fps,
        record.jitter_safety,
        record.shrink_cooldown_frames,
        record.target_depth,
        record.shrink_run,
    )
}

/// The record for a controller that has just folded.
const fn controller_record(working: &AdaptiveJitterController) -> SlopDeskAdaptiveJitter {
    SlopDeskAdaptiveJitter {
        min_depth: working.min_depth(),
        max_depth: working.max_depth(),
        fps: working.fps(),
        jitter_safety: working.jitter_safety(),
        shrink_cooldown_frames: working.shrink_cooldown_frames(),
        target_depth: working.target_depth(),
        shrink_run: working.shrink_run(),
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::float_cmp,
    reason = "the tests call the C entry points, and the fixtures fold exact binary fractions"
)]
mod tests {
    use super::{
        slopdesk_adaptive_jitter_default_cooldown, slopdesk_adaptive_jitter_default_safety,
        slopdesk_adaptive_jitter_depth_for, slopdesk_adaptive_jitter_new,
        slopdesk_adaptive_jitter_note_frame, slopdesk_adaptive_jitter_note_underrun,
        slopdesk_owd_jitter_micros, slopdesk_owd_jitter_new, slopdesk_owd_jitter_note,
    };

    #[test]
    fn an_initial_burst_never_emits_a_spike() {
        let mut estimator = slopdesk_owd_jitter_new();
        assert_eq!(unsafe { slopdesk_owd_jitter_note(&raw mut estimator, 1.0) }, 0.0);
        assert!(estimator.has_last_arrival);
        assert!(
            !estimator.has_last_inter_arrival,
            "one arrival is not an interval"
        );
        assert_eq!(unsafe { slopdesk_owd_jitter_note(&raw mut estimator, 2.0) }, 0.0);
        assert!(estimator.has_last_inter_arrival);
        // The third sample is the first with a second difference, and this one is steady.
        assert_eq!(unsafe { slopdesk_owd_jitter_note(&raw mut estimator, 3.0) }, 0.0);
    }

    #[test]
    fn an_uneven_arrival_raises_the_estimate_and_the_wire_field_follows() {
        let mut estimator = slopdesk_owd_jitter_new();
        for arrival in [1.0, 2.0, 3.5] {
            unsafe { slopdesk_owd_jitter_note(&raw mut estimator, arrival) };
        }
        assert!(estimator.jitter_seconds > 0.0);
        assert!(slopdesk_owd_jitter_micros(estimator) > 0);
    }

    #[test]
    fn the_depth_grows_at_once_and_shrinks_one_step_per_cooldown() {
        let mut controller = slopdesk_adaptive_jitter_new(1, 8, 60.0, 1, 2.5, 3);
        let grown = unsafe { slopdesk_adaptive_jitter_note_frame(&raw mut controller, 0.05) };
        assert!(grown > 1, "a rise applies in the same step");
        for _ in 0..2 {
            let held = unsafe { slopdesk_adaptive_jitter_note_frame(&raw mut controller, 0.0) };
            assert_eq!(held, grown, "a fall waits out the whole cooldown");
        }
        let settled = unsafe { slopdesk_adaptive_jitter_note_frame(&raw mut controller, 0.0) };
        assert_eq!(settled, grown - 1, "and then steps down by exactly one");
    }

    #[test]
    fn an_underrun_grows_immediately_and_restarts_the_cooldown() {
        let mut controller = slopdesk_adaptive_jitter_new(1, 8, 60.0, 2, 2.5, 3);
        let grown = unsafe { slopdesk_adaptive_jitter_note_underrun(&raw mut controller) };
        assert_eq!(grown, 3);
        assert_eq!(controller.shrink_run, 0);
        assert_eq!(
            slopdesk_adaptive_jitter_depth_for(controller, 0.0),
            1,
            "a clean link is the floor"
        );
    }

    #[test]
    fn the_defaults_are_the_crates_own() {
        assert_eq!(slopdesk_adaptive_jitter_default_safety(), 2.5);
        assert_eq!(slopdesk_adaptive_jitter_default_cooldown(), 180);
    }
}
