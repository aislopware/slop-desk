//! One pane session's detach/rebind ladder and its two exit latches — docs/59 step 5b.
//!
//! `rust/slopdesk-muxsession`'s `lifecycle` owns the decisions. This is the door.
//!
//! ## Why this handle is shared, not exclusive
//! Every other pane handle in this crate is reached under exactly one of hostd's `NSLock`s, so
//! [`crate::pane_outbox`] and friends hand out `&mut` and let the caller's lock do the serializing.
//! This one cannot: the EOF latch is set from the supervised ingest path, the exit-sent latch from
//! the output drain, and both are polled by the exit task — three threads that must never queue
//! behind the teardown ladder. So the handle is `Sync` and serializes itself, and `held` hands back
//! a SHARED reference.
//!
//! That is also why hostd loses two locks here and not three: `eofLock` and `exitSentLock` are gone
//! outright, while `taskLock` stays to guard the `Task`s, the sub-channels and the stream — Swift
//! objects that cannot cross at all.
//!
//! ## What did NOT cross
//! The `onExit` swap, the task cancellation, the `PaneOutputStream` open, and the two bounded
//! polls. A closure is not a fact and a `Task` is not a number; the door answers WHETHER a detach
//! tears down, whether a rebind may proceed, and from which offset — hostd does all four.

use slopdesk_muxsession::lifecycle::{FROM_NOW_ON, Lifecycle, RebindVerdict};

/// One pane session's lifecycle state, as an opaque handle.
#[derive(Debug)]
pub struct SlopDeskPaneLifecycle {
    /// The state that serializes itself — see the module note.
    inner: Lifecycle,
}

/// The `detach` verdict, packed one bit per obligation: `1` this call is the first (tear down),
/// `2` a supervised stream was open and must be stopped.
pub const DETACH_FIRST: u8 = 1;
/// See [`DETACH_FIRST`].
pub const DETACH_STOP_STREAM: u8 = 2;

/// The `rebind` verdict: refuse and change nothing.
pub const REBIND_REFUSE: u8 = 0;
/// Proceed; the session never started a relay, so there is no subscription to re-open.
pub const REBIND_PROCEED: u8 = 1;
/// Proceed and re-open the subscription at the offset written to the out-parameter.
pub const REBIND_PROCEED_RESUME: u8 = 2;

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_pane_lifecycle_new`] that has not been
/// freed. Unlike this crate's other handles a SHARED reference is enough, because the state
/// serializes itself.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(handle: *const SlopDeskPaneLifecycle) -> Option<&'a SlopDeskPaneLifecycle> {
    // SAFETY: by the caller's obligation this is a live allocation from `new`.
    unsafe { handle.as_ref() }
}

/// A fresh lifecycle: not started, attached, resuming from nowhere.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_lifecycle_new() -> *mut SlopDeskPaneLifecycle {
    Box::into_raw(Box::new(SlopDeskPaneLifecycle {
        inner: Lifecycle::new(),
    }))
}

/// Frees a lifecycle. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_pane_lifecycle_new`], freed exactly once,
/// with no other thread still calling into it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_free(handle: *mut SlopDeskPaneLifecycle) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Claims the one-time relay start. `true` for the caller that wins.
///
/// A dead handle answers `false` — a session with no lifecycle must not start a second set of
/// relay tasks nobody is tracking.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_start(handle: *const SlopDeskPaneLifecycle) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.start()
}

/// Whether the relay has been started. A dead handle answers `false`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_is_started(handle: *const SlopDeskPaneLifecycle) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_started())
}

/// Records that a supervised subscription is open, so a later rebind knows to re-open one.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_stream_opened(handle: *const SlopDeskPaneLifecycle) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.stream_opened();
    }
}

/// Flips the detached flag and answers what this call must tear down, as [`DETACH_FIRST`] |
/// [`DETACH_STOP_STREAM`]. A dead handle answers `0` — nothing to tear down.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_detach(handle: *const SlopDeskPaneLifecycle) -> u8 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    let verdict = state.inner.detach();
    u8::from(verdict.first) * DETACH_FIRST + u8::from(verdict.stop_stream) * DETACH_STOP_STREAM
}

/// Whether the session is parked in the detached store. A dead handle answers `false`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_is_detached(handle: *const SlopDeskPaneLifecycle) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_some_and(|state| state.inner.is_detached())
}

/// Decides a rebind against the returning client's sub-channels.
///
/// Answers [`REBIND_REFUSE`], [`REBIND_PROCEED`] or [`REBIND_PROCEED_RESUME`], the last writing the
/// resume cursor to `resume_from` when it is non-null.
///
/// A dead handle refuses: acking a pane whose relay nothing is tracking would orphan it.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, and `resume_from` must be null or point at one
/// writable `uint64_t` for the duration of the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_rebind(
    handle: *const SlopDeskPaneLifecycle,
    data_finished: bool,
    control_finished: bool,
    resume_from: *mut u64,
) -> u8 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return REBIND_REFUSE;
    };
    match state.inner.rebind(data_finished, control_finished) {
        RebindVerdict::Refuse => REBIND_REFUSE,
        RebindVerdict::Proceed { resume_from: None } => REBIND_PROCEED,
        RebindVerdict::Proceed {
            resume_from: Some(offset),
        } => {
            if !resume_from.is_null() {
                // SAFETY: by the caller's obligation this points at one writable `u64` for the call.
                unsafe { resume_from.write(offset) };
            }
            REBIND_PROCEED_RESUME
        },
    }
}

/// Advances the resume cursor to where the just-ingested chunk ends.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_record_offset(
    handle: *const SlopDeskPaneLifecycle,
    end: u64,
) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.record_offset(end);
    }
}

/// Where a rebind re-opens the subscription. A dead handle answers the `fromNowOn` sentinel.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_offset(handle: *const SlopDeskPaneLifecycle) -> u64 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.map_or(FROM_NOW_ON, |state| state.inner.offset())
}

/// The `fromNowOn` seed, for a caller that has to NAME it.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_lifecycle_from_now_on() -> u64 {
    FROM_NOW_ON
}

/// Latches "superd drained this master to EOF".
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_signal_eof(handle: *const SlopDeskPaneLifecycle) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.signal_eof();
    }
}

/// Whether the EOF latch is set. A dead handle answers `true` so a bounded poll on a torn-down
/// pane returns at once rather than spinning to its timeout.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_is_eof(handle: *const SlopDeskPaneLifecycle) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_none_or(|state| state.inner.is_eof())
}

/// Latches "the drain put `.exit` on the wire".
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_signal_exit_sent(handle: *const SlopDeskPaneLifecycle) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.signal_exit_sent();
    }
}

/// Whether the exit-sent latch is set. A dead handle answers `true`, for
/// [`slopdesk_pane_lifecycle_is_eof`]'s reason.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pane_lifecycle_is_exit_sent(handle: *const SlopDeskPaneLifecycle) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    unsafe { held(handle) }.is_none_or(|state| state.inner.is_exit_sent())
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        DETACH_FIRST, DETACH_STOP_STREAM, REBIND_PROCEED, REBIND_PROCEED_RESUME, REBIND_REFUSE,
        slopdesk_pane_lifecycle_detach, slopdesk_pane_lifecycle_free, slopdesk_pane_lifecycle_from_now_on,
        slopdesk_pane_lifecycle_is_detached, slopdesk_pane_lifecycle_is_eof,
        slopdesk_pane_lifecycle_is_exit_sent, slopdesk_pane_lifecycle_is_started,
        slopdesk_pane_lifecycle_new, slopdesk_pane_lifecycle_offset, slopdesk_pane_lifecycle_rebind,
        slopdesk_pane_lifecycle_record_offset, slopdesk_pane_lifecycle_signal_eof,
        slopdesk_pane_lifecycle_signal_exit_sent, slopdesk_pane_lifecycle_start,
        slopdesk_pane_lifecycle_stream_opened,
    };

    #[test]
    fn a_pane_detaches_once_and_rebinds_at_the_cursor_it_left() {
        let handle = slopdesk_pane_lifecycle_new();
        unsafe {
            assert!(slopdesk_pane_lifecycle_start(handle));
            assert!(!slopdesk_pane_lifecycle_start(handle));
            assert!(slopdesk_pane_lifecycle_is_started(handle));
            slopdesk_pane_lifecycle_stream_opened(handle);
            slopdesk_pane_lifecycle_record_offset(handle, 8192);
            assert_eq!(
                slopdesk_pane_lifecycle_detach(handle),
                DETACH_FIRST | DETACH_STOP_STREAM
            );
            assert_eq!(slopdesk_pane_lifecycle_detach(handle), 0);
            assert!(slopdesk_pane_lifecycle_is_detached(handle));

            let mut resume = 0_u64;
            assert_eq!(
                slopdesk_pane_lifecycle_rebind(handle, false, false, &raw mut resume),
                REBIND_PROCEED_RESUME
            );
            assert_eq!(resume, 8192);
            assert!(!slopdesk_pane_lifecycle_is_detached(handle));
            slopdesk_pane_lifecycle_free(handle);
        }
    }

    #[test]
    fn a_dead_sub_channel_refuses_and_leaves_the_pane_claimable() {
        let handle = slopdesk_pane_lifecycle_new();
        unsafe {
            slopdesk_pane_lifecycle_start(handle);
            slopdesk_pane_lifecycle_detach(handle);
            assert_eq!(
                slopdesk_pane_lifecycle_rebind(handle, true, false, std::ptr::null_mut()),
                REBIND_REFUSE
            );
            assert!(slopdesk_pane_lifecycle_is_detached(handle));
            // A started session re-opens even with a null out-parameter — the caller that does not
            // want the cursor still learns it must subscribe again.
            assert_eq!(
                slopdesk_pane_lifecycle_rebind(handle, false, false, std::ptr::null_mut()),
                REBIND_PROCEED_RESUME
            );
            slopdesk_pane_lifecycle_free(handle);
        }
    }

    #[test]
    fn a_session_that_never_started_a_relay_reopens_nothing() {
        let handle = slopdesk_pane_lifecycle_new();
        unsafe {
            slopdesk_pane_lifecycle_detach(handle);
            assert_eq!(
                slopdesk_pane_lifecycle_rebind(handle, false, false, std::ptr::null_mut()),
                REBIND_PROCEED
            );
            slopdesk_pane_lifecycle_free(handle);
        }
    }

    #[test]
    fn the_latches_are_independent_and_survive_a_detach() {
        let handle = slopdesk_pane_lifecycle_new();
        unsafe {
            assert!(!slopdesk_pane_lifecycle_is_eof(handle));
            assert!(!slopdesk_pane_lifecycle_is_exit_sent(handle));
            slopdesk_pane_lifecycle_signal_eof(handle);
            assert!(slopdesk_pane_lifecycle_is_eof(handle));
            assert!(!slopdesk_pane_lifecycle_is_exit_sent(handle));
            slopdesk_pane_lifecycle_signal_exit_sent(handle);
            slopdesk_pane_lifecycle_detach(handle);
            assert!(slopdesk_pane_lifecycle_is_eof(handle));
            assert!(slopdesk_pane_lifecycle_is_exit_sent(handle));
            slopdesk_pane_lifecycle_free(handle);
        }
    }

    #[test]
    fn a_dead_handle_refuses_every_decision_and_ends_every_poll() {
        let dead = std::ptr::null();
        unsafe {
            assert!(!slopdesk_pane_lifecycle_start(dead));
            assert!(!slopdesk_pane_lifecycle_is_started(dead));
            assert_eq!(slopdesk_pane_lifecycle_detach(dead), 0);
            assert!(!slopdesk_pane_lifecycle_is_detached(dead));
            assert_eq!(
                slopdesk_pane_lifecycle_rebind(dead, false, false, std::ptr::null_mut()),
                REBIND_REFUSE
            );
            assert_eq!(
                slopdesk_pane_lifecycle_offset(dead),
                slopdesk_pane_lifecycle_from_now_on()
            );
            assert!(
                slopdesk_pane_lifecycle_is_eof(dead),
                "a torn-down pane must not spin a bounded poll to its timeout"
            );
            assert!(slopdesk_pane_lifecycle_is_exit_sent(dead));
            slopdesk_pane_lifecycle_stream_opened(dead);
            slopdesk_pane_lifecycle_record_offset(dead, 1);
            slopdesk_pane_lifecycle_signal_eof(dead);
            slopdesk_pane_lifecycle_signal_exit_sent(dead);
            slopdesk_pane_lifecycle_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn the_first_real_offset_replaces_the_sentinel_through_the_door() {
        let handle = slopdesk_pane_lifecycle_new();
        unsafe {
            assert_eq!(
                slopdesk_pane_lifecycle_offset(handle),
                slopdesk_pane_lifecycle_from_now_on()
            );
            slopdesk_pane_lifecycle_record_offset(handle, 16);
            slopdesk_pane_lifecycle_record_offset(handle, 4);
            assert_eq!(slopdesk_pane_lifecycle_offset(handle), 16);
            slopdesk_pane_lifecycle_free(handle);
        }
    }
}
