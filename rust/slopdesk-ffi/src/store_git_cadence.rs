//! When the sidebar's git line is re-probed and where the reply is filed, in C.
//!
//! `slopdesk_workspace::store_git_cadence` owns the decisions. What is here is the marshalling.
//!
//! ## The clock crosses as an INTERVAL, and absence crosses as infinity
//!
//! A `Date` has no C shape worth agreeing on, and the rule never wanted one: what it reads is how
//! long ago something happened. So the caller subtracts and sends `f64` seconds. A project that has
//! never been fetched, or never been pushed to, sends `INFINITY` — which is not a sentinel bolted
//! on but the literal reading, and it lands on the same branch the absent case does: infinitely
//! stale is due, and a push infinitely long ago grants no grace.
//!
//! ## A blank string is an absent string
//!
//! Every text argument here arrives as `(ptr, len)`, and a null pointer, a zero length and an empty
//! Rust string are one thing at that boundary. That costs nothing, because every one of these
//! arguments is a project key or a directory whose blank form was already no answer: the rules drop
//! a blank key, and a blank directory normalizes to nothing.
//!
//! ## Only ONE key comes back from a booking
//!
//! A reply can be filed under two keys, and the second one is always the caller's own fallback —
//! so it crosses back as a flag rather than as a string the caller would be reading back to itself.

use core::ffi::c_uchar;

use slopdesk_workspace::store_git_cadence::{
    self, Freshness, PUSH_GRACE_WINDOW, STALE_WINDOW, STALE_WINDOW_ACTIVE_PROJECT,
};

use crate::borrow;

/// The three staleness windows, in seconds — the constants the caller mirrors so its own tests can
/// name them without a second copy of the numbers.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskWsGitWindows {
    /// A background project's window.
    pub stale: f64,
    /// The focused project's, tighter.
    pub active: f64,
    /// The back-off while host pushes are fresh.
    pub push_grace: f64,
}

/// Where a freshly-fetched reading is filed.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SlopDeskWsGitBooking {
    /// `false` drops the WHOLE reading — the caller writes nothing and stamps nothing.
    pub booked: bool,
    /// Whether to file the reading under the caller's own fallback key as well.
    pub alias: bool,
    /// Bytes the primary key NEEDS. `primary <= cap` means it was written; `primary > cap` means
    /// nothing was, and the caller should call again with a buffer that big — the same retry
    /// protocol every counted door here uses, carried in a field because the verdict travels beside
    /// it.
    pub primary: usize,
}

/// A caller-lent `(ptr, len)` as text, where anything blank or not UTF-8 is ABSENT.
///
/// Non-UTF-8 reads as absent rather than as an error: every argument here is a path or a project
/// key, and a path this side cannot read is a path it cannot make a claim about.
///
/// # Safety
/// `(ptr, len)` must satisfy [`borrow`]'s obligation.
#[expect(
    unsafe_code,
    reason = "lending the caller's bytes for the call is half this module's pointer work"
)]
unsafe fn text<'a>(ptr: *const c_uchar, len: usize) -> Option<&'a str> {
    // SAFETY: the caller's obligation above is this function's, restated on `borrow`.
    let lent = unsafe { borrow(ptr, len) };
    core::str::from_utf8(lent).ok().filter(|text| !text.is_empty())
}

/// Writes `answer` into `(out, cap)`, answering the bytes it NEEDED.
///
/// `0` is no answer, `n <= cap` is written, `n > cap` wrote nothing — `docs/55` §4, exactly.
///
/// # Safety
/// `(out, cap)` must be null or writable for `cap` bytes for the call.
#[expect(
    unsafe_code,
    reason = "writing into the caller's buffer is the other half of the counted convention"
)]
unsafe fn spill(answer: Option<&str>, out: *mut c_uchar, cap: usize) -> usize {
    let Some(bytes) = answer.map(str::as_bytes) else {
        return 0;
    };
    let needed = bytes.len();
    if needed == 0 || needed > cap || out.is_null() {
        return needed;
    }
    // SAFETY: `needed <= cap` was just checked, `out` is non-null and writable for `cap` bytes by
    // the caller's obligation, and the source is the caller's own input or a String allocated
    // inside this call, so the two cannot overlap.
    unsafe { core::ptr::copy_nonoverlapping(bytes.as_ptr(), out, needed) };
    needed
}

/// The three staleness windows, in seconds.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_git_windows() -> SlopDeskWsGitWindows {
    SlopDeskWsGitWindows {
        stale: STALE_WINDOW,
        active: STALE_WINDOW_ACTIVE_PROJECT,
        push_grace: PUSH_GRACE_WINDOW,
    }
}

/// Whether the snapshot edge should re-fetch this project's git line.
///
/// `since_fetch` and `since_push` are seconds ago; a non-finite value is "never", which is the
/// reading a project with no line and a project nothing has pushed to both send.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_git_refresh_due(
    in_flight: bool,
    since_fetch: f64,
    since_push: f64,
    active_project: bool,
) -> bool {
    store_git_cadence::refresh_due(Freshness {
        in_flight,
        since_fetch: since_fetch.is_finite().then_some(since_fetch),
        since_push: since_push.is_finite().then_some(since_push),
        active_project,
    })
}

/// A pane's SECTION key for git bookkeeping, from its host-pushed key and its directory.
///
/// # Safety
/// `(key, key_len)` and `(cwd, cwd_len)` must be readable, and `(out, cap)` writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_git_section_key(
    key: *const c_uchar,
    key_len: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `text` and `spill`.
    unsafe {
        let resolved = store_git_cadence::section_key(text(key, key_len), text(cwd, cwd_len));
        spill(resolved.as_deref(), out, cap)
    }
}

/// A pane's HOST-PUSHED key alone, raw — `0` while the pane is still on its directory fallback.
///
/// # Safety
/// `(key, key_len)` must be readable, and `(out, cap)` writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_git_host_key(
    key: *const c_uchar,
    key_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `text` and `spill`.
    unsafe {
        let resolved = store_git_cadence::host_pushed_key(text(key, key_len));
        spill(resolved.as_deref(), out, cap)
    }
}

/// The key a probe's reply may be ALIASED under, or `0` when it may not be aliased at all.
///
/// # Safety
/// `(key, key_len)` and `(cwd, cwd_len)` must be readable, and `(out, cap)` writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_git_alias_candidate(
    key: *const c_uchar,
    key_len: usize,
    cwd: *const c_uchar,
    cwd_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `text` and `spill`.
    unsafe {
        let resolved = store_git_cadence::alias_candidate(text(key, key_len), text(cwd, cwd_len));
        spill(resolved.as_deref(), out, cap)
    }
}

/// Where a freshly-fetched reading is filed, or a `booked` of `false` to drop it whole.
///
/// # Safety
/// `(toplevel, toplevel_len)` and `(fallback, fallback_len)` must be readable, and `(out, cap)`
/// writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_git_booking(
    toplevel: *const c_uchar,
    toplevel_len: usize,
    fallback: *const c_uchar,
    fallback_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> SlopDeskWsGitBooking {
    // SAFETY: the caller's obligation above is this function's, restated on `text` and `spill`.
    unsafe {
        let root = text(toplevel, toplevel_len).unwrap_or_default();
        let Some(plan) = store_git_cadence::booking(root, text(fallback, fallback_len)) else {
            return SlopDeskWsGitBooking::default();
        };
        SlopDeskWsGitBooking {
            booked: true,
            alias: plan.alias,
            primary: spill(Some(plan.primary.as_str()), out, cap),
        }
    }
}

/// Where a HOST-PUSHED reading is filed, or `0` to drop it.
///
/// # Safety
/// `(repo_root, len)` must be readable, and `(out, cap)` writable, for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_ws_git_pushed_key(
    repo_root: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is this function's, restated on `text` and `spill`.
    unsafe {
        let root = text(repo_root, len).unwrap_or_default();
        let resolved = store_git_cadence::pushed_booking(root);
        spill(resolved.as_deref(), out, cap)
    }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use slopdesk_workspace::store_git_cadence::{
        PUSH_GRACE_WINDOW, STALE_WINDOW, STALE_WINDOW_ACTIVE_PROJECT,
    };

    use super::{
        slopdesk_ws_git_alias_candidate, slopdesk_ws_git_booking, slopdesk_ws_git_host_key,
        slopdesk_ws_git_pushed_key, slopdesk_ws_git_refresh_due, slopdesk_ws_git_section_key,
        slopdesk_ws_git_windows,
    };

    /// Reads a two-input text door back as a String, sized the way the caller sizes it.
    fn two_in(
        door: unsafe extern "C" fn(*const u8, usize, *const u8, usize, *mut u8, usize) -> usize,
        first: &str,
        second: &str,
    ) -> Option<String> {
        // SAFETY: both inputs are live locals and `out` is null, the documented size call.
        let needed = unsafe {
            door(
                first.as_ptr(),
                first.len(),
                second.as_ptr(),
                second.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        if needed == 0 {
            return None;
        }
        let mut out = vec![0_u8; needed];
        // SAFETY: both inputs are live locals and `out` holds exactly `needed` bytes.
        let written = unsafe {
            door(
                first.as_ptr(),
                first.len(),
                second.as_ptr(),
                second.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        if written != needed {
            return None;
        }
        String::from_utf8(out).ok()
    }

    /// The three windows cross as the constants the rules hold, bit for bit.
    #[test]
    fn the_windows_cross_verbatim() {
        let windows = slopdesk_ws_git_windows();
        assert_eq!(windows.stale.to_bits(), STALE_WINDOW.to_bits());
        assert_eq!(windows.active.to_bits(), STALE_WINDOW_ACTIVE_PROJECT.to_bits());
        assert_eq!(windows.push_grace.to_bits(), PUSH_GRACE_WINDOW.to_bits());
    }

    /// An infinite interval is "never", on both clocks.
    #[test]
    fn infinity_crosses_as_never() {
        assert!(slopdesk_ws_git_refresh_due(
            false,
            f64::INFINITY,
            f64::INFINITY,
            false
        ));
        assert!(!slopdesk_ws_git_refresh_due(
            true,
            f64::INFINITY,
            f64::INFINITY,
            false
        ));
        assert!(!slopdesk_ws_git_refresh_due(false, 20.0, f64::INFINITY, false));
        assert!(slopdesk_ws_git_refresh_due(false, 20.0, f64::INFINITY, true));
        assert!(
            !slopdesk_ws_git_refresh_due(false, 20.0, 1.0, true),
            "a fresh push holds the poll off even for the focused project",
        );
    }

    /// The section key crosses through the size-then-read protocol.
    #[test]
    fn the_section_key_crosses_through_a_sized_buffer() {
        assert_eq!(
            two_in(slopdesk_ws_git_section_key, "/work/alpha/", "/work/alpha/src"),
            Some("/work/alpha".to_owned()),
        );
        assert_eq!(
            two_in(slopdesk_ws_git_section_key, "", "/work/alpha/src"),
            Some("/work/alpha/src".to_owned()),
        );
        assert_eq!(two_in(slopdesk_ws_git_section_key, "", ""), None);
    }

    /// A short buffer writes nothing and asks again — the retry half of the convention.
    #[test]
    fn a_short_buffer_writes_nothing() {
        let key = "/work/alpha";
        let mut out = [0_u8; 4];
        // SAFETY: `key` is a live local and `out` is a live buffer of exactly four bytes.
        let needed =
            unsafe { slopdesk_ws_git_host_key(key.as_ptr(), key.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(needed, key.len());
        assert_eq!(out, [0_u8; 4], "nothing was written into the short buffer");
    }

    /// Only a pane still on its directory fallback offers an alias key.
    #[test]
    fn the_alias_candidate_crosses_only_for_a_keyless_pane() {
        assert_eq!(
            two_in(slopdesk_ws_git_alias_candidate, "", "/work/alpha/src"),
            Some("/work/alpha/src".to_owned()),
        );
        assert_eq!(
            two_in(slopdesk_ws_git_alias_candidate, "/work/alpha", "/work/alpha/src"),
            None,
        );
    }

    /// The booking's verdict, its alias flag and its key all cross in one call.
    #[test]
    fn a_booking_crosses_as_a_verdict_beside_one_key() {
        let toplevel = "/work/alpha";
        let fallback = "/work/alpha/src";
        let mut out = [0_u8; 64];
        // SAFETY: both inputs are live locals and `out` is a live 64-byte buffer.
        let plan = unsafe {
            slopdesk_ws_git_booking(
                toplevel.as_ptr(),
                toplevel.len(),
                fallback.as_ptr(),
                fallback.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert!(plan.booked);
        assert!(plan.alias);
        assert_eq!(out.get(..plan.primary), Some(toplevel.as_bytes()));
    }

    /// A plugin-cache reading is refused at the door, and writes nothing.
    #[test]
    fn a_plugin_cache_reading_is_refused_at_the_door() {
        let toplevel = "/cache/zsh-users---zsh-autosuggestions";
        let mut out = [0_u8; 64];
        // SAFETY: `toplevel` is a live local, the fallback is the documented empty pair, and `out`
        // is a live 64-byte buffer.
        let plan = unsafe {
            slopdesk_ws_git_booking(
                toplevel.as_ptr(),
                toplevel.len(),
                core::ptr::null(),
                0,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert!(!plan.booked);
        assert_eq!(plan.primary, 0);

        // SAFETY: `toplevel` is a live local and `out` is a live 64-byte buffer.
        let pushed = unsafe {
            slopdesk_ws_git_pushed_key(toplevel.as_ptr(), toplevel.len(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(pushed, 0);
    }

    /// A push books under the repo root the host named, normalized.
    #[test]
    fn a_push_crosses_normalized() {
        let root = "/work/alpha/";
        let mut out = [0_u8; 64];
        // SAFETY: `root` is a live local and `out` is a live 64-byte buffer.
        let needed =
            unsafe { slopdesk_ws_git_pushed_key(root.as_ptr(), root.len(), out.as_mut_ptr(), out.len()) };
        assert_eq!(out.get(..needed), Some("/work/alpha".as_bytes()));
    }

    /// A null pair at every text input is the documented empty case.
    #[test]
    fn null_inputs_are_the_empty_case() {
        // SAFETY: null pointers with zero lengths are the documented empty pairs.
        unsafe {
            assert_eq!(
                slopdesk_ws_git_section_key(
                    core::ptr::null(),
                    0,
                    core::ptr::null(),
                    0,
                    core::ptr::null_mut(),
                    0,
                ),
                0,
            );
            assert_eq!(
                slopdesk_ws_git_host_key(core::ptr::null(), 0, core::ptr::null_mut(), 0),
                0,
            );
            assert_eq!(
                slopdesk_ws_git_pushed_key(core::ptr::null(), 0, core::ptr::null_mut(), 0),
                0,
            );
        }
    }
}
