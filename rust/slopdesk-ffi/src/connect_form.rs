//! The connect sheet's words, in C.
//!
//! The rules are `slopdesk_workspace::connect_form`; what is here is the marshalling.
//!
//! The three PORT prompts deliberately do not cross. They are `ConnectionTarget.default`'s own
//! numbers rendered as text, and a door for them would be a second spelling of a default that the
//! near side already holds — see the rule module's header.

use core::ffi::c_uchar;

use slopdesk_workspace::connect_form::{self, Word};

use crate::{deliver, push_text};

/// Every word the sheet says, in one delivery.
///
/// ```text
/// 8 × [u32 length][UTF-8 bytes]   // `Word::ALL`'s own order
/// ```
///
/// One crossing for the set, because a sheet lays all eight out at once and a door per label was
/// measured too expensive inside a `SwiftUI` body.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_connect_form_words(out: *mut c_uchar, cap: usize) -> usize {
    let mut blob = Vec::new();
    for word in Word::ALL {
        push_text(&mut blob, word.text());
    }
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// Whether a connect attempt should dismiss the sheet.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_connect_form_closes_after(failed: bool) -> bool {
    connect_form::should_close_after_connect(failed)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::connect_form::{self, Word};

    use super::{slopdesk_ws_connect_form_closes_after, slopdesk_ws_connect_form_words};
    use crate::testing::{delivered, runs};

    #[test]
    fn every_word_crosses_in_its_own_order() {
        let blob = delivered(|out, cap| {
            // SAFETY: `out` is a live local for the call.
            unsafe { slopdesk_ws_connect_form_words(out, cap) }
        });
        let words = runs(&blob, Word::ALL.len());
        for (index, word) in Word::ALL.into_iter().enumerate() {
            assert_eq!(
                words.get(index).map(String::as_str),
                Some(word.text()),
                "{word:?}"
            );
        }
    }

    #[test]
    fn only_a_clean_connect_dismisses_the_sheet() {
        for failed in [false, true] {
            assert_eq!(
                slopdesk_ws_connect_form_closes_after(failed),
                connect_form::should_close_after_connect(failed),
            );
        }
    }
}
