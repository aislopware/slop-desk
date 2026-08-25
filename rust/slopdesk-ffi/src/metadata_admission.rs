//! One pane's metadata admission counter and the verb→performer table — docs/59 step 8.
//!
//! `rust/slopdesk-muxsession`'s `metadata_admission` owns the decisions. This is the door.
//!
//! ## Why the counter is a HANDLE and the table is not
//! The counter is state with a session's lifetime, mutated from the control loop (admission) and
//! from every metadata work item's completion (release), serialized by exactly ONE `NSLock` —
//! hostd's `metadataInFlightLock`, which guards this and nothing else. That is the same test
//! [`crate::pane_outbox`] and [`crate::pane_fanout`] answer, so the same shape applies.
//!
//! The table has no state at all: which performer owns a verb is a function of one wire byte, so
//! [`slopdesk_metadata_performer`] allocates nothing and there is no lifetime to get wrong.
//!
//! ## What did NOT cross
//! The performing. A Finder open, a `settings.json` merge, a pasteboard write and a lazily-spawned
//! child are `AppKit` and process work; the door names WHO, and hostd does it.

use core::ffi::c_uchar;

use slopdesk_muxsession::metadata_admission::{Admission, MAX_IN_FLIGHT, performer};

/// One pane session's bounded-admission counter, as an opaque handle.
///
/// `Copy` because every field is — the handle is only ever reached through the caller's raw
/// pointer, so the derive names what the type already is rather than offering a second way to hold
/// one.
#[derive(Debug, Clone, Copy)]
pub struct SlopDeskMetadataAdmission {
    /// The state the caller's `metadataInFlightLock` guards.
    inner: Admission,
}

/// Turns the caller's handle back into a reference.
///
/// # Safety
/// `handle` must be null or a live pointer from [`slopdesk_metadata_admission_new`] that has not
/// been freed, and no other reference to it may be live for the duration of the call.
#[expect(
    unsafe_code,
    reason = "turning the caller's handle back into a reference is this module's whole obligation"
)]
const unsafe fn held<'a>(
    handle: *mut SlopDeskMetadataAdmission,
) -> Option<&'a mut SlopDeskMetadataAdmission> {
    // SAFETY: by the caller's obligation this is a live, exclusively-held allocation from `new`.
    unsafe { handle.as_mut() }
}

/// A fresh counter at this build's cap.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_metadata_admission_new() -> *mut SlopDeskMetadataAdmission {
    Box::into_raw(Box::new(SlopDeskMetadataAdmission {
        inner: Admission::default(),
    }))
}

/// Frees a counter. Null is a no-op, and the same pointer must not be freed twice.
///
/// # Safety
/// `handle` must be null or a pointer from [`slopdesk_metadata_admission_new`], freed exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_metadata_admission_free(handle: *mut SlopDeskMetadataAdmission) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Takes a slot if one is free. `true` obliges the caller to release exactly once.
///
/// A dead handle answers `false`: a session with no counter has no bound, and refusing a request
/// the client will see answered is safer than admitting work nothing is counting.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_metadata_admission_admit(
    handle: *mut SlopDeskMetadataAdmission,
) -> bool {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return false;
    };
    state.inner.admit()
}

/// Returns a slot taken by an admit that answered `true`. A dead handle is a no-op.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_metadata_admission_release(handle: *mut SlopDeskMetadataAdmission) {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    if let Some(state) = unsafe { held(handle) } {
        state.inner.release();
    }
}

/// How many work items are admitted and unfinished. A dead handle answers `0`.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_metadata_admission_in_flight(
    handle: *mut SlopDeskMetadataAdmission,
) -> u32 {
    // SAFETY: the caller's obligation above is this function's, restated on `held`.
    let Some(state) = (unsafe { held(handle) }) else {
        return 0;
    };
    state.inner.in_flight()
}

/// The per-session cap, for a caller that has to NAME it — a log line or a test.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_metadata_admission_cap() -> u32 {
    MAX_IN_FLIGHT
}

/// Which performer owns `verb`: 1 path · 2 agent · 3 clipboard · 4 code-server · 5 simulator ·
/// 6 android · 7 the read-only builder (also every byte this build does not serve).
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_metadata_performer(verb: c_uchar) -> c_uchar {
    performer(verb).as_byte()
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use super::{
        slopdesk_metadata_admission_admit, slopdesk_metadata_admission_cap, slopdesk_metadata_admission_free,
        slopdesk_metadata_admission_in_flight, slopdesk_metadata_admission_new,
        slopdesk_metadata_admission_release, slopdesk_metadata_performer,
    };

    #[test]
    fn the_counter_bounds_a_flood_and_recovers_when_the_work_finishes() {
        let handle = slopdesk_metadata_admission_new();
        let cap = slopdesk_metadata_admission_cap();
        for _ in 0..cap {
            assert!(unsafe { slopdesk_metadata_admission_admit(handle) });
        }
        assert!(!unsafe { slopdesk_metadata_admission_admit(handle) });
        assert_eq!(unsafe { slopdesk_metadata_admission_in_flight(handle) }, cap);
        unsafe { slopdesk_metadata_admission_release(handle) };
        assert!(unsafe { slopdesk_metadata_admission_admit(handle) });
        unsafe { slopdesk_metadata_admission_free(handle) };
    }

    #[test]
    fn a_dead_handle_refuses_rather_than_admitting_uncounted_work() {
        assert!(!unsafe { slopdesk_metadata_admission_admit(std::ptr::null_mut()) });
        assert_eq!(
            unsafe { slopdesk_metadata_admission_in_flight(std::ptr::null_mut()) },
            0
        );
        unsafe { slopdesk_metadata_admission_release(std::ptr::null_mut()) };
        unsafe { slopdesk_metadata_admission_free(std::ptr::null_mut()) };
    }

    #[test]
    fn the_door_names_the_same_performers_the_rules_do() {
        assert_eq!(slopdesk_metadata_performer(9), 1);
        assert_eq!(slopdesk_metadata_performer(10), 1);
        assert_eq!(slopdesk_metadata_performer(11), 2);
        assert_eq!(slopdesk_metadata_performer(13), 2);
        assert_eq!(slopdesk_metadata_performer(15), 3);
        assert_eq!(slopdesk_metadata_performer(16), 3);
        assert_eq!(slopdesk_metadata_performer(18), 4);
        assert_eq!(slopdesk_metadata_performer(20), 4);
        assert_eq!(slopdesk_metadata_performer(21), 5);
        assert_eq!(slopdesk_metadata_performer(22), 6);
        assert_eq!(slopdesk_metadata_performer(1), 7);
        assert_eq!(slopdesk_metadata_performer(17), 7);
        assert_eq!(slopdesk_metadata_performer(0), 7);
        assert_eq!(slopdesk_metadata_performer(200), 7);
    }
}
