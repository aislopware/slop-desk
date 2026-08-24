//! Keeping the Mac — or its screen — awake, in C:
//! `Sources/SlopDeskHost/PreventSleepDriver.swift` and
//! `Sources/SlopDeskVideoHost/HostDisplayWake.swift`.
//!
//! Two handles, one shape. Each pairs a pure fold with the single [`SleepAssertion`] it drives, and
//! answers the state that fold reached — so the caller never counts anything, never remembers an
//! edge, and cannot apply a verdict computed against a set it no longer has.
//!
//! ## Why the pairing is INSIDE the handle
//! This is the whole reason the doors exist. The Swift versions kept the set (or the refcount) and
//! the assertion as two objects and made the caller hold a lock across both, because the failure
//! otherwise is subtle: pane "a" finishing on one thread computes `anyWorking = true` (b is still
//! in the set), pane "b" finishing on another removes the last entry and applies `false`, and then
//! the first thread applies its stale `true` — leaving an assertion held over an empty set, which
//! does not self-heal and keeps the Mac awake until the daemon dies. Behind one door the update and
//! the apply are one statement, so the interleaving has nowhere to happen. What is left on the
//! Swift side is the handle obligation every door in this crate carries: no two calls on one handle
//! at once, which its `NSLock` already provided.
//!
//! ## The two are not one door with a flag
//! An agent working through the night must not let the MACHINE sleep; a client watching the desktop
//! must not let the SCREEN go dark; and an agent working with nobody watching should still let the
//! screen go dark. Two assertions, two folds, two lifetimes — the system one is per-hostd and keyed
//! by pane, the display one is per-video-host and refcounted by session.
//!
//! macOS only, gated in `lib.rs`: `IOPMAssertion` is an `IOKit` API about the machine this process
//! runs on, and no client asks it of itself.

use core::ffi::c_uchar;

use slopdesk_agent::sleep::PreventSleep;
use slopdesk_apple_power::{SleepAssertion, SleepKind};
use slopdesk_video::display_wake::DisplayWake;

use crate::borrow;

/// The name `pmset -g assertions` shows for the agent-working assertion.
const SYSTEM_REASON: &str = "slopdesk: agent working";
/// The name `pmset -g assertions` shows for the desktop-stream assertion.
const DISPLAY_REASON: &str = "slopdesk: remote desktop session attached";

/// The opaque prevent-sleep handle: which panes are working, and the system assertion driven by it.
///
/// Neither field is `Copy`, so no exemption is needed to keep the handle from becoming one — which
/// is the property that matters here: a duplicated handle is a second owner that would free once
/// more.
#[derive(Debug)]
pub struct SlopDeskPreventSleep {
    fold: PreventSleep,
    assertion: SleepAssertion,
}

/// The opaque display-wake handle: how many desktop streams are live, and the display assertion
/// driven by it.
///
/// `SleepAssertion` is not `Copy`, which keeps this one out of the same trap for the same reason.
#[derive(Debug)]
pub struct SlopDeskDisplayWake {
    fold: DisplayWake,
    assertion: SleepAssertion,
}

/// Builds a prevent-sleep driver with nothing working.
///
/// `enabled` is the `SLOPDESK_AGENT_PREVENT_SLEEP` opt-in, read once at launch — the preference is
/// not live-reloadable, and a hostd restart is the reload.
///
/// # Safety
/// Nothing is borrowed — the function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prevent_sleep_new(enabled: bool) -> *mut SlopDeskPreventSleep {
    Box::into_raw(Box::new(SlopDeskPreventSleep {
        fold: PreventSleep::new(enabled),
        assertion: SleepAssertion::new(SleepKind::System, SYSTEM_REASON),
    }))
}

/// Releases a prevent-sleep driver, RELEASING any assertion it still holds.
///
/// The release is the point: a daemon teardown that dropped this handle while an agent was still
/// working would otherwise leave the Mac awake for good. It happens in `SleepAssertion`'s `Drop`,
/// which reclaiming the box runs.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_prevent_sleep_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prevent_sleep_free(handle: *mut SlopDeskPreventSleep) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_prevent_sleep_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

/// Records one pane's `.working` transition, drives the assertion to the resulting state, and
/// answers whether it is now held.
///
/// A pane id that is not valid UTF-8 is folded lossily rather than refused: the id is a key in a
/// set, so a replacement character costs a pane its dedupe at worst, while refusing would drop a
/// transition and strand the assertion.
///
/// `false` from a handle that WANTED to assert means the system refused the create; the next
/// transition retries, which is why nothing here remembers the failure.
///
/// # Safety
/// `handle` must be null or a live, unfreed pointer from [`slopdesk_prevent_sleep_new`] with no
/// other call on it in flight; `pane` must be null or point to `pane_len` live bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_prevent_sleep_note(
    handle: *mut SlopDeskPreventSleep,
    pane: *const c_uchar,
    pane_len: usize,
    working: bool,
) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation above is `borrow`'s.
    let pane = String::from_utf8_lossy(unsafe { borrow(pane, pane_len) }).into_owned();
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    let driver = unsafe { &mut *handle };
    // ONE statement: the fold's answer is computed from the set this call just updated, and applied
    // before anything else can update it again. See the module note.
    driver.assertion.set_asserted(driver.fold.note(&pane, working))
}

/// Whether the system assertion is held right now. Diagnostic — the driver never asks itself.
///
/// # Safety
/// `handle` must be null or a live, unfreed pointer from [`slopdesk_prevent_sleep_new`] with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const unsafe extern "C" fn slopdesk_prevent_sleep_is_held(handle: *const SlopDeskPreventSleep) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    unsafe { (*handle).assertion.is_held() }
}

/// Builds a display-wake driver with no holders.
///
/// # Safety
/// Nothing is borrowed — the function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_display_wake_new() -> *mut SlopDeskDisplayWake {
    Box::into_raw(Box::new(SlopDeskDisplayWake {
        fold: DisplayWake::new(),
        assertion: SleepAssertion::new(SleepKind::Display, DISPLAY_REASON),
    }))
}

/// Releases a display-wake driver, RELEASING any assertion it still holds — the same teardown
/// guarantee its sibling gives, for the same reason.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_display_wake_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_display_wake_free(handle: *mut SlopDeskDisplayWake) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_display_wake_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

/// One more streaming desktop session. Answers whether the display assertion is now held.
///
/// # Safety
/// `handle` must be null or a live, unfreed pointer from [`slopdesk_display_wake_new`] with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_display_wake_acquire(handle: *mut SlopDeskDisplayWake) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    let driver = unsafe { &mut *handle };
    driver.assertion.set_asserted(driver.fold.acquire())
}

/// One streaming desktop session ended. Answers whether the display assertion is still held.
///
/// An unbalanced release clamps at zero rather than underflowing — `DisplayWake`'s rule, and the
/// one that keeps a double teardown from holding the screen awake forever.
///
/// # Safety
/// `handle` must be null or a live, unfreed pointer from [`slopdesk_display_wake_new`] with no
/// other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_display_wake_release(handle: *mut SlopDeskDisplayWake) -> bool {
    if handle.is_null() {
        return false;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call.
    let driver = unsafe { &mut *handle };
    driver.assertion.set_asserted(driver.fold.release())
}

// There is no `slopdesk_display_wake_is_held`. Both doors above already answer the state they
// reached and `HostDisplayWake` reads neither, so a third would be an export with no caller — which
// `ffi-doors-are-opened` fails, and rightly: an unread door is a claim about the far side that
// nothing checks. The prevent-sleep twin has one only because hostd's supervision suite asserts on
// it. What the doors here MEAN is `slopdesk_video::display_wake`'s, and its own tests cover it.

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "the tests drive the same C entry points every caller does"
)]
mod tests {
    use super::{
        slopdesk_display_wake_acquire, slopdesk_display_wake_free, slopdesk_display_wake_new,
        slopdesk_display_wake_release, slopdesk_prevent_sleep_free, slopdesk_prevent_sleep_is_held,
        slopdesk_prevent_sleep_new, slopdesk_prevent_sleep_note,
    };

    /// The door's own contract: every entry point tolerates null, and none of them assert.
    #[test]
    fn every_door_tolerates_a_null_handle() {
        // SAFETY: null is what each door's contract admits.
        unsafe {
            assert!(!slopdesk_prevent_sleep_note(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                true
            ));
            assert!(!slopdesk_prevent_sleep_is_held(std::ptr::null()));
            assert!(!slopdesk_display_wake_acquire(std::ptr::null_mut()));
            assert!(!slopdesk_display_wake_release(std::ptr::null_mut()));
            slopdesk_prevent_sleep_free(std::ptr::null_mut());
            slopdesk_display_wake_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn the_first_working_pane_asserts_and_the_last_one_out_releases() {
        // SAFETY: one handle, used and freed exactly once, with no overlapping call.
        unsafe {
            let handle = slopdesk_prevent_sleep_new(true);
            assert!(!handle.is_null());
            let (a, b) = ("pane-a", "pane-b");
            assert!(slopdesk_prevent_sleep_note(handle, a.as_ptr(), a.len(), true));
            assert!(slopdesk_prevent_sleep_note(handle, b.as_ptr(), b.len(), true));
            assert!(slopdesk_prevent_sleep_is_held(handle));
            assert!(slopdesk_prevent_sleep_note(handle, a.as_ptr(), a.len(), false));
            assert!(!slopdesk_prevent_sleep_note(handle, b.as_ptr(), b.len(), false));
            assert!(!slopdesk_prevent_sleep_is_held(handle));
            slopdesk_prevent_sleep_free(handle);
        }
    }

    /// The opt-in gates the effect: a driver built disabled never asserts, however much work
    /// arrives.
    #[test]
    fn a_disabled_driver_never_asserts() {
        // SAFETY: one handle, used and freed exactly once, with no overlapping call.
        unsafe {
            let handle = slopdesk_prevent_sleep_new(false);
            let pane = "pane-a";
            assert!(!slopdesk_prevent_sleep_note(
                handle,
                pane.as_ptr(),
                pane.len(),
                true
            ));
            assert!(!slopdesk_prevent_sleep_is_held(handle));
            slopdesk_prevent_sleep_free(handle);
        }
    }

    /// Freeing a handle that is still asserting must let go — the teardown guarantee. Checked by
    /// building a SECOND driver afterwards and asserting with it, which a leaked assertion table
    /// would eventually refuse.
    #[test]
    fn freeing_a_holding_handle_releases_its_assertion() {
        // SAFETY: each handle is used and freed exactly once, with no overlapping call.
        unsafe {
            for _ in 0..1_000 {
                let handle = slopdesk_prevent_sleep_new(true);
                let pane = "pane-a";
                assert!(slopdesk_prevent_sleep_note(
                    handle,
                    pane.as_ptr(),
                    pane.len(),
                    true
                ));
                slopdesk_prevent_sleep_free(handle);
            }
            let after = slopdesk_prevent_sleep_new(true);
            let pane = "pane-a";
            assert!(slopdesk_prevent_sleep_note(
                after,
                pane.as_ptr(),
                pane.len(),
                true
            ));
            slopdesk_prevent_sleep_free(after);
        }
    }

    #[test]
    fn the_display_refcount_holds_until_the_last_session_ends() {
        // SAFETY: one handle, used and freed exactly once, with no overlapping call.
        unsafe {
            let handle = slopdesk_display_wake_new();
            assert!(slopdesk_display_wake_acquire(handle));
            assert!(slopdesk_display_wake_acquire(handle));
            assert!(slopdesk_display_wake_release(handle));
            assert!(!slopdesk_display_wake_release(handle));
            // The clamp: a stray release must not strand the count below zero.
            assert!(!slopdesk_display_wake_release(handle));
            assert!(slopdesk_display_wake_acquire(handle));
            slopdesk_display_wake_free(handle);
        }
    }

    /// A pane id that is not valid UTF-8 folds lossily rather than dropping the transition.
    #[test]
    fn an_invalid_utf8_pane_id_still_moves_the_set() {
        let pane = [0xFF_u8, 0xFE, 0x41];
        // SAFETY: one handle, used and freed exactly once; the bytes are a live local array.
        unsafe {
            let handle = slopdesk_prevent_sleep_new(true);
            assert!(slopdesk_prevent_sleep_note(
                handle,
                pane.as_ptr(),
                pane.len(),
                true
            ));
            assert!(!slopdesk_prevent_sleep_note(
                handle,
                pane.as_ptr(),
                pane.len(),
                false
            ));
            slopdesk_prevent_sleep_free(handle);
        }
    }
}
