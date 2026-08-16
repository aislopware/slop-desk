//! What a clipboard payload would DO at a shell prompt, in C.
//!
//! Two entry points over [`slopdesk_terminal::paste`], and neither takes §4's `(out, cap)` shape:
//! one answers a BITMASK and the other a BOOLEAN, so there is nothing to size and nothing to
//! retry. A mask of `0` is a real answer here — "nothing about this payload is dangerous" — which
//! is exactly why the mask is not the crate's `usize` return: `0` there means the caller should
//! stop, and here it means the caller should paste.
//!
//! ## What is NOT here
//! The rules. Which four things are dangerous, what counts as a `sudo` TOKEN rather than a
//! substring, and the three states in which a paste provably cannot run are `slopdesk-terminal`'s,
//! in a crate that forbids `unsafe`.

use core::ffi::c_uchar;

use crate::borrow;

/// The four dangers `text` trips, as `slopdesk_terminal::paste`'s bit constants.
///
/// A payload that is not valid UTF-8 is read lossily rather than refused: a clipboard is whatever
/// the platform handed over, and refusing to classify it would silently mean "safe".
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_dangers(text: *const c_uchar, len: usize) -> u32 {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    slopdesk_terminal::paste::dangers(&String::from_utf8_lossy(bytes))
}

/// Whether the paste-protection confirmation should be shown.
///
/// # Safety
/// `(text, len)` must be null, or describe `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_paste_should_warn(
    text: *const c_uchar,
    len: usize,
    protection_on: bool,
    bracketed_safe: bool,
    program_advertised_bracketed: bool,
    is_alternate_screen: bool,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(text, len) };
    slopdesk_terminal::paste::should_warn(
        &String::from_utf8_lossy(bytes),
        protection_on,
        bracketed_safe,
        program_advertised_bracketed,
        is_alternate_screen,
    )
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use super::{slopdesk_paste_dangers, slopdesk_paste_should_warn};

    fn dangers(text: &str) -> u32 {
        // SAFETY: the pointer names a live local for the duration of the call.
        unsafe { slopdesk_paste_dangers(text.as_ptr(), text.len()) }
    }

    #[test]
    fn the_mask_crosses_and_zero_means_safe_rather_than_no_answer() {
        assert_eq!(dangers("ls -la"), 0);
        assert_eq!(dangers("sudo id\n"), 0b0110, "sudo plus a trailing newline");
    }

    #[test]
    fn the_decision_crosses_with_its_four_states() {
        let risky = "sudo id\n";
        // SAFETY: the pointer names a live local for the duration of each call.
        let warn = |on, safe, advertised, alt| unsafe {
            slopdesk_paste_should_warn(risky.as_ptr(), risky.len(), on, safe, advertised, alt)
        };
        assert!(warn(true, false, false, false));
        assert!(!warn(false, false, false, false));
        assert!(!warn(true, false, false, true));
        assert!(!warn(true, true, true, false));
    }

    #[test]
    fn a_null_payload_is_the_empty_one() {
        // SAFETY: a null pointer with a zero length is what `borrow` documents.
        let mask = unsafe { slopdesk_paste_dangers(std::ptr::null(), 0) };
        assert_eq!(mask, 0);
    }
}
