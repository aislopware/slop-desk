//! The window-list doors — macOS only, for the reason `inject` is.
//!
//! `rust/slopdesk-apple-cgwindow` asks the `WindowServer` and decodes;
//! `slopdesk_video::window_list` decides what a record means. This is the door, and it holds
//! neither half.
//!
//! ## What these replaced
//!
//! Four Swift call sites, each with its own hand-written `CFDictionary` decode and its own spelling
//! of what a missing field means: the frontmost read, the geometry watcher's per-frame bounds poll,
//! the occluder scan behind DIALOG-EXPAND, and the parked-window restore's owner check. One of the
//! four defaulted a missing `kCGWindowLayer` to `Int.min` and another to `-1`; the crate behind
//! these doors drops the record instead, once.
//!
//! ## macOS only, and the three spellings that keep it true
//!
//! The `cfg` in `lib.rs`, the `TARGET_OS_OSX` guard in `slopdesk_ffi.h`, and the `MACOS-ONLY`
//! region `slopdesk-gate ffi` reads out of that header. See
//! `docs/57-apple-frameworks-in-rust.md` §3.

use slopdesk_apple_cgwindow::{bounds_of, frontmost_pid, windows_in_front_of};

use crate::spill;
use crate::video_policy::SlopDeskVideoRect;
use crate::window_list::SlopDeskWindowRecord;

/// `0` means "any owner", which is what a caller with no stale id to guard against passes.
const fn owner(expected_pid: i32) -> Option<i32> {
    if expected_pid == 0 {
        None
    } else {
        Some(expected_pid)
    }
}

/// The frontmost app's pid, or `0` when nothing normal-level is on screen.
///
/// `0` rather than a flag because `0` is not a pid a window can have, and every caller already
/// fails CLOSED on it — the swipe-nav chip goes dark and the chord does not fire, instead of
/// guessing from a frozen `NSWorkspace` snapshot.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_cgwindow_frontmost_pid() -> i32 {
    frontmost_pid().unwrap_or(0)
}

/// One window's current bounds. `false` means the window is gone, or `expected_pid` was given and
/// did not match its owner, or `out` was null — in every case `out` is left untouched.
///
/// # Safety
/// `out` must be null, or writable for one [`SlopDeskVideoRect`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cgwindow_bounds(
    window_id: u32,
    expected_pid: i32,
    out: *mut SlopDeskVideoRect,
) -> bool {
    if out.is_null() {
        return false;
    }
    let Some(bounds) = bounds_of(window_id, owner(expected_pid)) else {
        return false;
    };
    // SAFETY: non-null was just checked, and by the caller's obligation it is writable for one
    // record for this call. The value written is a plain `Copy` scalar record built here.
    unsafe { out.write(SlopDeskVideoRect::from(bounds)) };
    true
}

/// Every on-screen window strictly IN FRONT of `window_id`, front-to-back, and how many there are.
///
/// The answer is the count NEEDED — §4 — so a caller that lent too little is told what to lend. A
/// `window_id` of `0` names nothing and answers `0`.
///
/// # Safety
/// `out` must be null, or writable for `cap` [`SlopDeskWindowRecord`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cgwindow_in_front_of(
    window_id: u32,
    out: *mut SlopDeskWindowRecord,
    cap: usize,
) -> usize {
    let windows: Vec<SlopDeskWindowRecord> = windows_in_front_of(window_id)
        .into_iter()
        .map(|window| {
            SlopDeskWindowRecord {
                bounds: SlopDeskVideoRect::from(window.bounds),
                window_id: window.window_id,
                owner_pid: window.owner_pid,
                layer: window.layer,
            }
        })
        .collect();
    // SAFETY: the caller's obligation above is restated on `spill`.
    unsafe { spill(&windows, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{owner, slopdesk_cgwindow_bounds, slopdesk_cgwindow_frontmost_pid};

    /// `0` is "any owner"; anything else is a pid to check against. The parked-window restore
    /// depends on the second half — a reused `CGWindowID` must never move an unrelated app's
    /// window.
    #[test]
    fn a_zero_expected_pid_means_any_owner_and_anything_else_means_that_one() {
        assert_eq!(owner(0), None);
        assert_eq!(owner(4242), Some(4242));
        assert_eq!(owner(-1), Some(-1));
    }

    /// A null buffer is answered `false` without the query being run at all, so a caller that
    /// forgot to lend one cannot mistake "no room" for "no window".
    #[test]
    fn a_null_buffer_is_refused_rather_than_written_through() {
        // SAFETY: null is one of the two shapes the door documents.
        assert!(!unsafe { slopdesk_cgwindow_bounds(1, 0, core::ptr::null_mut()) });
    }

    /// A window id that cannot exist answers nothing rather than the first window on screen — the
    /// query is scoped to the id, not merely started from it.
    #[test]
    fn an_impossible_window_id_has_no_bounds() {
        let mut rect = crate::video_policy::SlopDeskVideoRect::default();
        // SAFETY: `rect` is a live local, writable for exactly one record for this call.
        assert!(!unsafe { slopdesk_cgwindow_bounds(u32::MAX, 0, &raw mut rect) });
    }

    /// Whatever the session is, the answer is a pid or the fail-closed `0` — never a negative
    /// number a caller would go on to inject into.
    #[test]
    fn the_frontmost_answer_is_a_pid_or_the_closed_zero() {
        assert!(slopdesk_cgwindow_frontmost_pid() >= 0);
    }
}
