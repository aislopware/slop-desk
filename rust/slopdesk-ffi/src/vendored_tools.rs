//! Where the panel's pinned third-party programs live, in C —
//! `Sources/SlopDeskHost/HostServiceProcess.swift` and `AndroidServiceManager.swift`.
//!
//! The walk is [`slopdesk_androidd::toolchain::repo_root`]; what is here is the marshalling.
//!
//! ## Why the walk moved next to the search order
//! [`crate::tool_path`] already carries the project's ONE binary search order, and the vendored
//! prefix is the second rung of it. The walk that produces that prefix stayed Swift, which meant
//! the rung and the thing that fills it were in different languages: `locate_tool` took
//! `vendored_bin` as an argument and had no way to say what a checkout root even is. Now the
//! marker, the walk and the two paths that hang off it are one crate with the order that consumes
//! them.
//!
//! ## Why the START is a parameter
//! `Bundle.main.executableURL` is Foundation's, and resolving it is a Swift line either way. What
//! crosses is the WALK — the marker, the upward loop, the "outside a checkout finds nothing"
//! answer — because that is the part two languages could disagree about.
//!
//! hostd only: an iOS client has no checkout, no prefix and no `adb`.

use core::ffi::c_uchar;
use std::path::Path;

use slopdesk_androidd::toolchain;

use crate::{borrow, deliver};

/// Delivers `answer` — or nothing at all when the walk found no checkout.
///
/// A missing prefix is `0`, the same length an empty answer has, and both mean the caller falls
/// through to `PATH` and the host's own installs. There is no third state to distinguish.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[expect(
    unsafe_code,
    reason = "delivering the caller's answer is what this helper exists to do once"
)]
unsafe fn deliver_path(answer: Option<std::path::PathBuf>, out: *mut c_uchar, cap: usize) -> usize {
    let Some(path) = answer else {
        return 0;
    };
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(path.as_os_str().as_encoded_bytes(), out, cap) }
}

/// The checkout root `start` sits inside, or nothing when it sits in none.
///
/// # Safety
/// `start` must be null or point to `start_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vendored_repo_root(
    start: *const c_uchar,
    start_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let start = String::from_utf8_lossy(unsafe { borrow(start, start_len) }).into_owned();
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver_path(toolchain::repo_root(Path::new(&start)), out, cap) }
}

/// `ThirdParty/tools/.prefix/bin` for the checkout `start` sits inside — the `vendored_bin` rung of
/// the search order — or nothing outside one.
///
/// # Safety
/// `start` must be null or point to `start_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vendored_bin_dir(
    start: *const c_uchar,
    start_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let start = String::from_utf8_lossy(unsafe { borrow(start, start_len) }).into_owned();
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver_path(toolchain::vendored_bin_dir(Path::new(&start)), out, cap) }
}

/// The committed `scrcpy-server` jar for the checkout `start` sits inside, or nothing outside one.
///
/// # Safety
/// `start` must be null or point to `start_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_vendored_scrcpy_server_jar(
    start: *const c_uchar,
    start_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let start = String::from_utf8_lossy(unsafe { borrow(start, start_len) }).into_owned();
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver_path(toolchain::scrcpy_server_jar(Path::new(&start)), out, cap) }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the door is the point"
)]
mod tests {
    use super::{
        slopdesk_vendored_bin_dir, slopdesk_vendored_repo_root, slopdesk_vendored_scrcpy_server_jar,
    };
    use crate::testing::delivered;

    fn answer(door: unsafe extern "C" fn(*const u8, usize, *mut u8, usize) -> usize, start: &str) -> String {
        // SAFETY: `start` is a live slice for the call and `delivered` asks by length first.
        String::from_utf8(delivered(|out, cap| unsafe {
            door(start.as_ptr(), start.len(), out, cap)
        }))
        .expect("a path crosses as its own bytes")
    }

    #[test]
    fn this_checkout_answers_its_own_root_and_both_paths() {
        // The test binary is built inside this repository, so the walk from this source file's
        // crate directory must find the checkout the manifest lives in.
        let here = concat!(env!("CARGO_MANIFEST_DIR"), "/src/vendored_tools.rs");
        let root = answer(slopdesk_vendored_repo_root, here);
        assert!(!root.is_empty(), "this file is inside a checkout");
        assert!(here.starts_with(&root) && root.len() < here.len());
        assert_eq!(
            answer(slopdesk_vendored_bin_dir, here),
            format!("{root}/ThirdParty/tools/.prefix/bin")
        );
        assert_eq!(
            answer(slopdesk_vendored_scrcpy_server_jar, here),
            format!("{root}/ThirdParty/tools/vendor/scrcpy-server")
        );
    }

    #[test]
    fn a_binary_outside_a_checkout_answers_nothing() {
        for door in [
            slopdesk_vendored_repo_root,
            slopdesk_vendored_bin_dir,
            slopdesk_vendored_scrcpy_server_jar,
        ] {
            assert!(answer(door, "/usr/local/bin/slopdesk-hostd").is_empty());
            // SAFETY: both pointers are null, which each door's contract admits.
            assert_eq!(
                unsafe { door(std::ptr::null(), 0, std::ptr::null_mut(), 0) },
                0,
                "no start, no answer — and no read of a pointer nobody passed"
            );
        }
    }
}
