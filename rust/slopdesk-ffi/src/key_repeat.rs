//! The key-repeat state machine, in C.
//!
//! The rules are [`slopdesk_workspace::key_repeat`]; what is here is the marshalling, plus the one
//! lock the handle convention makes this module declare.
//!
//! ## A HANDLE, and one of the few that TWO THREADS may call
//!
//! The header's convention says no two calls on one handle may overlap, because every other handle
//! there is serialised by the Swift object that owns it. This one cannot be, and the reason is the
//! shape of the thing rather than a caller's convenience: key events arrive on the MAIN thread from
//! `pressesBegan`/`pressesEnded`, while the `DispatchSourceTimer` that drives the repeat fires on
//! its own serial queue and asks this handle whether it is still live. Two threads is the design.
//!
//! So the state sits behind a `Mutex` and every door takes a SHARED handle pointer. The lock is
//! held for a byte comparison and a counter read, never across a callback — there is nothing to
//! call back into from here.
//!
//! ## What did NOT cross, and why it could not
//!
//! The payload. `onFire` re-emits a typed value — a `PhoneKey.Press` — and a generic Swift value
//! has no C spelling. What crosses instead is the caller's own IDENTITY encoding of it: opaque
//! bytes, compared and never read. The caller keeps the typed value it is about to emit, keeps the
//! timer, and keeps nothing else.

use core::ffi::c_uchar;
use std::sync::Mutex;

use slopdesk_workspace::key_repeat::{self, Down, KeyRepeat, Stage, Tick, Timing};

use crate::borrow;

/// The latch, its generation counter, and the cadence it hands out.
#[derive(Debug)]
pub struct SlopDeskKeyRepeat {
    /// Guarded because two threads call this handle by design; see the module header.
    state: Mutex<KeyRepeat>,
    /// Fixed at construction: the two waits are a property of the repeater, not of one press.
    timing: Timing,
}

/// Turns a caller's handle pointer into a reference for one call.
///
/// Shared rather than exclusive, which is the whole difference from the ordinary handle here: the
/// state behind it is locked, so two threads holding this reference at once is what the module
/// documents rather than aliasing UB.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_key_repeat_new`] that has not been
/// freed.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
const unsafe fn held<'a>(handle: *const SlopDeskKeyRepeat) -> Option<&'a SlopDeskKeyRepeat> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live — and the state behind it is guarded,
    // so a concurrent call through another copy of this reference is sound.
    Some(unsafe { &*handle })
}

/// The standard wait between the first fire and the first repeat, in milliseconds.
///
/// Asked rather than transcribed: it is what a caller's `Timing.standard` is built from, and a copy
/// would be the cadence this side stopped applying.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_key_repeat_default_initial_delay_ms() -> u32 {
    key_repeat::DEFAULT_INITIAL_DELAY_MS
}

/// The standard wait between repeats, in milliseconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_key_repeat_default_repeat_interval_ms() -> u32 {
    key_repeat::DEFAULT_REPEAT_INTERVAL_MS
}

/// A repeater with nothing held, at this cadence.
///
/// Never null. There is no cadence this can refuse — a zero wait is a caller asking for a timer
/// that fires immediately, which its own scheduler decides what to do about.
///
/// # Safety
/// The answer must be passed to [`slopdesk_key_repeat_free`] exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_key_repeat_new(
    initial_delay_ms: u32,
    repeat_interval_ms: u32,
) -> *mut SlopDeskKeyRepeat {
    Box::into_raw(Box::new(SlopDeskKeyRepeat {
        state: Mutex::new(KeyRepeat::new()),
        timing: Timing {
            initial_delay_ms,
            repeat_interval_ms,
        },
    }))
}

/// Releases a repeater. Null is inert; exactly one free per [`slopdesk_key_repeat_new`].
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_key_repeat_new`] not yet freed, with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "reclaiming the box IS the other half of the handle convention"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_free(handle: *mut SlopDeskKeyRepeat) {
    if handle.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, a live box from `new` with nothing in
    // flight — so reclaiming it here is the single matching free.
    drop(unsafe { Box::from_raw(handle) });
}

/// A key went down.
///
/// `true` means the caller must CANCEL any armed timer, emit the key once now, and arm a one-shot
/// `after_ms` from now, quoting `generation` when it elapses. `false` means this key is already
/// latched and its ramp is running: do nothing at all, and neither out-param is touched.
///
/// The identity is compared byte for byte and never interpreted; the empty one is an ordinary key.
///
/// # Safety
/// `handle` must be null or live; `(identity, len)` must be null, or name `len` initialised bytes
/// live for the call; `generation` and `after_ms` must be null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and every pointer is the caller's"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_down(
    handle: *const SlopDeskKeyRepeat,
    identity: *const c_uchar,
    len: usize,
    generation: *mut u64,
    after_ms: *mut u32,
) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(repeater) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: ditto; the borrow dies with this call.
    let bytes = unsafe { borrow(identity, len) };
    let Ok(mut state) = repeater.state.lock() else {
        // A poisoned lock means a panic crossed this state. Answering "continue" arms nothing and
        // fires nothing, which is the inert answer of the two.
        return false;
    };
    match state.down(bytes, repeater.timing) {
        Down::Continue => false,
        Down::Start {
            generation: token,
            after_ms: delay,
        } => {
            if !generation.is_null() {
                // SAFETY: non-null and writable by the caller's obligation.
                unsafe { generation.write(token) };
            }
            if !after_ms.is_null() {
                // SAFETY: ditto.
                unsafe { after_ms.write(delay) };
            }
            true
        },
    }
}

/// A key went up. `true` means the caller must cancel its armed timer.
///
/// A release for a key that is NOT the latched one answers `false` and changes nothing, so a stale
/// event cannot kill a live repeat.
///
/// # Safety
/// `handle` must be null or live; `(identity, len)` must be null, or name `len` initialised bytes
/// live for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_up(
    handle: *const SlopDeskKeyRepeat,
    identity: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(repeater) = (unsafe { held(handle) }) else {
        return false;
    };
    // SAFETY: ditto; the borrow dies with this call.
    let bytes = unsafe { borrow(identity, len) };
    repeater.state.lock().is_ok_and(|mut state| state.up(bytes))
}

/// Drops any latch — focus loss, disconnect, teardown. `true` when there was one, so the caller
/// cancels its timer exactly when there is one to cancel. Idempotent.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the handle is the caller's"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_stop(handle: *const SlopDeskKeyRepeat) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(repeater) = (unsafe { held(handle) }) else {
        return false;
    };
    repeater.state.lock().is_ok_and(|mut state| state.stop())
}

/// A timer armed under `generation` just elapsed. Answers what to do:
///
/// | code | meaning |
/// | --- | --- |
/// | 0 | STALE — the latch moved. Emit nothing and let the timer go. |
/// | 1 | FIRE — emit the key. Whatever timer is running stays. |
/// | 2 | FIRE, then replace the one-shot with a repeating timer every `every_ms`. |
///
/// `every_ms` is written only for code 2. `stage` is 0 for the one-shot and 1 for the repeating
/// timer; any other byte reads as the repeating one, which fires without arming anything.
///
/// # Safety
/// `handle` must be null or live; `every_ms` must be null or writable.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_elapsed(
    handle: *const SlopDeskKeyRepeat,
    stage: u8,
    generation: u64,
    every_ms: *mut u32,
) -> u8 {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(repeater) = (unsafe { held(handle) }) else {
        return 0;
    };
    let Ok(latched) = repeater.state.lock() else {
        return 0;
    };
    match latched.elapsed(Stage::from_code(stage), generation, repeater.timing) {
        Tick::Stale => 0,
        Tick::Fire => 1,
        Tick::FireThenRepeat { every_ms: interval } => {
            if !every_ms.is_null() {
                // SAFETY: non-null and writable by the caller's obligation.
                unsafe { every_ms.write(interval) };
            }
            2
        },
    }
}

/// Whether `generation` is still the live latch.
///
/// The caller asks once more after arming a timer: a release that landed while the arm was in
/// flight makes the fresh handle stale, and adopting it would leave a timer nobody will cancel.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the handle is the caller's"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_is_current(
    handle: *const SlopDeskKeyRepeat,
    generation: u64,
) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(repeater) = (unsafe { held(handle) }) else {
        return false;
    };
    repeater
        .state
        .lock()
        .is_ok_and(|state| state.is_current(generation))
}

/// Whether any key is held and repeating.
///
/// # Safety
/// `handle` must be null or live.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and the handle is the caller's"
)]
pub unsafe extern "C" fn slopdesk_key_repeat_is_held(handle: *const SlopDeskKeyRepeat) -> bool {
    // SAFETY: the caller's obligation, forwarded unchanged.
    let Some(repeater) = (unsafe { held(handle) }) else {
        return false;
    };
    repeater.state.lock().is_ok_and(|state| state.is_held())
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::key_repeat;

    use super::{
        SlopDeskKeyRepeat, slopdesk_key_repeat_default_initial_delay_ms,
        slopdesk_key_repeat_default_repeat_interval_ms, slopdesk_key_repeat_down,
        slopdesk_key_repeat_elapsed, slopdesk_key_repeat_free, slopdesk_key_repeat_is_current,
        slopdesk_key_repeat_is_held, slopdesk_key_repeat_new, slopdesk_key_repeat_stop,
        slopdesk_key_repeat_up,
    };

    /// A press, answering `(started, generation, after_ms)`.
    fn down(handle: *const SlopDeskKeyRepeat, identity: &[u8]) -> (bool, u64, u32) {
        let mut generation = u64::MAX;
        let mut after_ms = u32::MAX;
        let started = unsafe {
            slopdesk_key_repeat_down(
                handle,
                identity.as_ptr(),
                identity.len(),
                &raw mut generation,
                &raw mut after_ms,
            )
        };
        (started, generation, after_ms)
    }

    fn elapsed(handle: *const SlopDeskKeyRepeat, stage: u8, generation: u64) -> (u8, u32) {
        let mut every_ms = u32::MAX;
        let code = unsafe { slopdesk_key_repeat_elapsed(handle, stage, generation, &raw mut every_ms) };
        (code, every_ms)
    }

    /// The whole ramp across the boundary: latch, initial one-shot, hand-off to the repeating
    /// timer, then release — and every stale timer answering nothing afterwards.
    #[test]
    fn the_ramp_crosses_as_start_then_hand_off_then_fire_and_a_release_ends_it() {
        let handle = slopdesk_key_repeat_new(
            slopdesk_key_repeat_default_initial_delay_ms(),
            slopdesk_key_repeat_default_repeat_interval_ms(),
        );
        let (started, generation, after_ms) = down(handle, b"a");
        assert!(started);
        assert_eq!(after_ms, key_repeat::DEFAULT_INITIAL_DELAY_MS);
        assert!(unsafe { slopdesk_key_repeat_is_held(handle) });
        assert!(unsafe { slopdesk_key_repeat_is_current(handle, generation) });

        assert_eq!(
            elapsed(handle, 0, generation),
            (2, key_repeat::DEFAULT_REPEAT_INTERVAL_MS),
            "the one-shot fires and hands over",
        );
        assert_eq!(elapsed(handle, 1, generation).0, 1, "and then it just fires");

        assert!(unsafe { slopdesk_key_repeat_up(handle, b"a".as_ptr(), 1) });
        assert!(!unsafe { slopdesk_key_repeat_is_held(handle) });
        assert_eq!(
            elapsed(handle, 1, generation).0,
            0,
            "a timer that outran its cancel"
        );
        unsafe { slopdesk_key_repeat_free(handle) };
    }

    /// A duplicate press touches neither out-param, so a caller that ignores the `false` cannot
    /// arm a second timer from a stale generation sitting in its locals.
    #[test]
    fn a_duplicate_press_leaves_both_out_params_untouched() {
        let handle = slopdesk_key_repeat_new(350, 50);
        let (started, ..) = down(handle, b"a");
        assert!(started);
        let (again, generation, after_ms) = down(handle, b"a");
        assert!(!again);
        assert_eq!(generation, u64::MAX, "untouched");
        assert_eq!(after_ms, u32::MAX, "untouched");
        unsafe { slopdesk_key_repeat_free(handle) };
    }

    /// A release for another key is ignored; `stop` is idempotent and says whether it did anything.
    #[test]
    fn an_unmatched_release_is_ignored_and_stop_reports_what_it_dropped() {
        let handle = slopdesk_key_repeat_new(350, 50);
        let (_, generation, _) = down(handle, b"a");
        assert!(!unsafe { slopdesk_key_repeat_up(handle, b"b".as_ptr(), 1) });
        assert!(unsafe { slopdesk_key_repeat_is_current(handle, generation) });
        assert!(unsafe { slopdesk_key_repeat_stop(handle) });
        assert!(!unsafe { slopdesk_key_repeat_stop(handle) });
        unsafe { slopdesk_key_repeat_free(handle) };
    }

    /// An overridden cadence rides both answers — the near side's integration test against a real
    /// `DispatchSourceTimer` needs one it can cross twice inside a second.
    #[test]
    fn the_handles_own_cadence_is_what_comes_back() {
        let handle = slopdesk_key_repeat_new(30, 20);
        let (started, generation, after_ms) = down(handle, b"\x7f");
        assert!(started);
        assert_eq!(after_ms, 30);
        assert_eq!(elapsed(handle, 0, generation), (2, 20));
        unsafe { slopdesk_key_repeat_free(handle) };
    }

    /// The empty identity is an ordinary key, and a null one is the SAME key — both are the empty
    /// byte string, which is what `borrow` folds them to.
    #[test]
    fn a_null_identity_is_the_empty_one_and_it_latches() {
        let handle = slopdesk_key_repeat_new(350, 50);
        let mut generation = 0_u64;
        let mut after_ms = 0_u32;
        assert!(unsafe {
            slopdesk_key_repeat_down(
                handle,
                core::ptr::null(),
                0,
                &raw mut generation,
                &raw mut after_ms,
            )
        });
        assert!(unsafe { slopdesk_key_repeat_is_held(handle) });
        assert!(!unsafe {
            slopdesk_key_repeat_down(
                handle,
                b"".as_ptr(),
                0,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
            )
        });
        assert!(unsafe { slopdesk_key_repeat_up(handle, core::ptr::null(), 0) });
        unsafe { slopdesk_key_repeat_free(handle) };
    }

    /// A null handle is inert at every door, and freeing null is a no-op — the handle convention's
    /// own contract.
    #[test]
    fn a_null_handle_is_inert_everywhere() {
        let null: *const SlopDeskKeyRepeat = core::ptr::null();
        assert!(!down(null, b"a").0);
        assert!(!unsafe { slopdesk_key_repeat_up(null, b"a".as_ptr(), 1) });
        assert!(!unsafe { slopdesk_key_repeat_stop(null) });
        assert!(!unsafe { slopdesk_key_repeat_is_held(null) });
        assert!(!unsafe { slopdesk_key_repeat_is_current(null, 0) });
        assert_eq!(elapsed(null, 0, 0).0, 0);
        unsafe { slopdesk_key_repeat_free(core::ptr::null_mut()) };
    }
}
