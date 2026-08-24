//! The running-application door — a pid in, a bundle identifier out.
//!
//! `rust/slopdesk-apple-app` makes the `NSRunningApplication` call; this is the door and holds no
//! decision. WHICH pid to ask about is [`crate::cgwindow::slopdesk_cgwindow_frontmost_pid`]'s
//! answer, and what a bundle id MEANS — is this app swipe-nav eligible — is `slopdesk-video`'s.
//!
//! ## What this replaced
//! The one remaining `import AppKit` on the host's frontmost path. `HostFrontmostApp.bundleID()`
//! held a `NSRunningApplication(processIdentifier:)` beside an FFI call that already answered the
//! other half, which made one question two languages.
//!
//! ## macOS only, for the reason [`crate::cgwindow`] is
//! There is no `NSRunningApplication` on iOS, so an ungated edge would not merely cost bytes, it
//! would fail to link. The `cfg` in `lib.rs`, the `TARGET_OS_OSX` guard in `slopdesk_ffi.h` and the
//! `MACOS-ONLY` region `slopdesk-gate ffi` reads out of that header — `docs/57` §3.

use core::ffi::c_uchar;

use crate::deliver;

/// The bundle identifier of the process with this pid, or `0` — §4's `Option::None` — when the pid
/// names no application.
///
/// A pid that exited, was never an app bundle, or is a plain executable with no `Info.plist` all
/// answer nothing, because they are the same answer to every caller: nothing can be said about this
/// process. Each one reads that as "not eligible", so the swipe-nav chip goes dark and the chord
/// does not fire — the failure is CLOSED rather than frozen on a stale snapshot.
///
/// # Safety
/// `out` must be null, or writable for `cap` bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_app_bundle_id(pid: i32, out: *mut c_uchar, cap: usize) -> usize {
    let Some(bundle) = slopdesk_apple_app::bundle_id(pid) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(bundle.as_bytes(), out, cap) }
}

/// Whether the app with this pid is HIDDEN — ⌘H, or hidden by another app becoming active.
///
/// A pid naming no application answers `false`. That conflation is deliberate and matches what the
/// only caller wants: the window feed reads hidden as a reason to SUPPRESS a row, and a window
/// belonging to nothing is not a window a person hid.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_app_is_hidden(pid: i32) -> bool {
    slopdesk_apple_app::is_hidden(pid)
}

/// Brings the app with this pid to the front.
///
/// `false` when the pid names no application or the framework declined — a request, never a
/// guarantee, which every caller already treats as best-effort because the click that follows lands
/// on whatever is frontmost either way.
///
/// No activation OPTIONS cross, and there is no door that takes them: the injector raises and
/// focuses one window through the accessibility API first, and `ActivateAllWindows` would undo
/// that.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_app_activate(pid: i32) -> bool {
    slopdesk_apple_app::activate(pid)
}

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the C ABI the way Swift does is the thing under test"
)]
mod tests {
    use super::{slopdesk_app_activate, slopdesk_app_bundle_id, slopdesk_app_is_hidden};

    /// A pid that cannot name an application answers nothing rather than an empty string a caller
    /// would go on to compare against an allowlist.
    #[test]
    fn an_impossible_pid_answers_nothing() {
        let mut out = [0u8; 128];
        // SAFETY: `out` is a live local, writable for its own length for the call.
        assert_eq!(
            unsafe { slopdesk_app_bundle_id(i32::MAX, out.as_mut_ptr(), out.len()) },
            0
        );
    }

    /// The two doors agree about a pid that names nothing: no bundle, and not hidden. Either one
    /// answering otherwise would make the window feed suppress or label a row it cannot resolve.
    #[test]
    fn a_pid_that_names_nothing_is_neither_bundled_nor_hidden() {
        assert!(!slopdesk_app_is_hidden(i32::MAX));
        assert!(!slopdesk_app_is_hidden(-1));
    }

    /// Activation of a pid that names nothing is refused. A `true` would claim a raise that never
    /// happened, and the injector's next click would be reported as having landed on that app.
    #[test]
    fn activating_a_pid_that_names_nothing_is_refused() {
        assert!(!slopdesk_app_activate(i32::MAX));
        assert!(!slopdesk_app_activate(-1));
    }

    /// A null buffer is answered with the size to lend, not written through — the two-call shape
    /// of §4, which a caller that has no idea how long a bundle id is depends on.
    #[test]
    fn a_null_buffer_is_sized_rather_than_written_through() {
        // SAFETY: null is one of the two shapes the door documents.
        assert_eq!(unsafe { slopdesk_app_bundle_id(1, core::ptr::null_mut(), 0) }, 0);
    }
}
