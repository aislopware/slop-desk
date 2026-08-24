//! The By-Project sidebar key, in C.
//!
//! One entry point over [`slopdesk_git::project_key`]: a pane's cwd in, the key the wire's type 34
//! carries out. The resolve and the walk are ONE crossing on purpose — hostd used to canonicalise
//! on its side and walk on the other, which is two chances for the two halves to disagree about
//! what path they were talking about.
//!
//! Blocking, like everything it wraps: the caller keeps this on its metadata queue, never on a PTY
//! read loop (`docs/45`).

use core::ffi::c_uchar;

use crate::{borrow, deliver};

/// The By-Project key for `cwd`, under §4's delivery convention.
///
/// # Safety
/// `cwd` must be null or point to `cwd_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_project_key(
    cwd: *const c_uchar,
    cwd_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above is `borrow`'s.
    let path = String::from_utf8_lossy(unsafe { borrow(cwd, cwd_len) }).into_owned();
    let key = slopdesk_git::project_key::key_of(&path);
    // SAFETY: the caller's obligation above is `deliver`'s.
    unsafe { deliver(key.as_bytes(), out, cap) }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "a panic in a test is the failure report, and calling the door is the point"
)]
mod tests {
    use super::slopdesk_project_key;
    use crate::testing::delivered;

    fn key(cwd: &str) -> String {
        // SAFETY: `cwd` is a live slice for the call, and `delivered` asks by length first.
        String::from_utf8(delivered(|out, cap| unsafe {
            slopdesk_project_key(cwd.as_ptr(), cwd.len(), out, cap)
        }))
        .expect("the key is the path's own bytes")
    }

    #[test]
    fn a_directory_in_no_repository_crosses_as_itself() {
        assert_eq!(key("/no/such/directory/anywhere"), "/no/such/directory/anywhere");
    }

    #[test]
    fn this_checkout_crosses_as_its_toplevel() {
        let here = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
        let crossed = key(here);
        assert!(
            here.starts_with(&crossed) && crossed.len() < here.len(),
            "expected an ancestor toplevel of {here}, got {crossed}"
        );
    }

    #[test]
    fn a_null_cwd_is_inert() {
        // SAFETY: both pointers are null, which the door's own contract admits.
        assert_eq!(
            unsafe { slopdesk_project_key(std::ptr::null(), 0, std::ptr::null_mut(), 0) },
            0,
            "no path, no key — and no read of a pointer nobody passed"
        );
    }
}
