//! Keeping the Mac's SCREEN awake, in C: `HostDisplayWake.swift`.
//!
//! One handle, pairing a pure fold with the single [`SleepAssertion`] it drives, and answering the
//! state that fold reached — so the caller never counts anything, never remembers an edge, and
//! cannot apply a verdict computed against a set it no longer has.
//!
//! ## Why the pairing is INSIDE the handle
//! This is the whole reason the door exists. The Swift version kept the refcount and the assertion
//! as two objects and made the caller hold a lock across both, because the failure otherwise is
//! subtle: one session ending on one thread computes "still held" (another is live), the last one
//! ending on another thread applies `false`, and then the first thread applies its stale `true` —
//! leaving an assertion held over an empty set, which does not self-heal and keeps the screen lit
//! until the daemon dies. Behind one door the update and the apply are one statement, so the
//! interleaving has nowhere to happen. What is left on the Swift side is the handle obligation
//! every door in this crate carries: no two calls on one handle at once, which its `NSLock` already
//! provided.
//!
//! ## The SYSTEM assertion is not here, and that is `docs/60` F.9
//! An agent working through the night must not let the MACHINE sleep; a client watching the desktop
//! must not let the SCREEN go dark; and an agent working with nobody watching should still let the
//! screen go dark. Two assertions, two folds, two lifetimes — and the system one was only ever
//! hostd's. It had a `SlopDeskPreventSleep` handle here because hostd was SWIFT: the working-pane
//! set lived in `slopdesk_agent::sleep` and the pane edges arrived in Swift, so the two had to meet
//! at a C boundary. `rust/slopdesk-hostd::sleep` owns the pair outright now, and buys the same
//! property with OWNERSHIP rather than a lock — one thread holds the set and the assertion and
//! nothing else can reach either. So the door went with the host that opened it.
//!
//! What is left is the DISPLAY assertion, which is per-video-host and refcounted by session rather
//! than keyed by pane, and whose caller is still Swift.
//!
//! macOS only, gated in `lib.rs`: `IOPMAssertion` is an `IOKit` API about the machine this process
//! runs on, and no client asks it of itself.

use slopdesk_apple_power::{SleepAssertion, SleepKind};
use slopdesk_video::display_wake::DisplayWake;

/// The name `pmset -g assertions` shows for the desktop-stream assertion.
const DISPLAY_REASON: &str = "slopdesk: remote desktop session attached";

/// The opaque display-wake handle: how many desktop streams are live, and the display assertion
/// driven by it.
///
/// `SleepAssertion` is not `Copy`, which keeps this one out of the same trap for the same reason.
#[derive(Debug)]
pub struct SlopDeskDisplayWake {
    fold: DisplayWake,
    assertion: SleepAssertion,
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
// nothing checks. What the doors here MEAN is `slopdesk_video::display_wake`'s, and its own tests
// cover it.

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "the tests drive the same C entry points every caller does"
)]
mod tests {
    use super::{
        slopdesk_display_wake_acquire, slopdesk_display_wake_free, slopdesk_display_wake_new,
        slopdesk_display_wake_release,
    };

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
}
