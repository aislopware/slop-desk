//! The Outline row's age line and its status gutter, in C.
//!
//! The rules are `slopdesk_workspace::outline`; what is here is the marshalling.
//!
//! The CLOCK stays on the near side. A door that read one would answer a different string every
//! time it was asked with the same inputs, which is not a rule; the caller subtracts its own two
//! dates and hands over the seconds.

use core::ffi::c_uchar;

use slopdesk_workspace::outline::{self, Gutter};

use crate::{deliver, push_text};

/// How long ago something happened, in words, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// A NEGATIVE `seconds_ago` is a clock that went backwards between the two readings the caller
/// subtracted — the rule floors it at "just now" rather than printing a future.
///
/// # Safety
/// `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `(out, cap)` is the caller's buffer"
)]
pub unsafe extern "C" fn slopdesk_ws_outline_relative_time(
    seconds_ago: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let mut blob = Vec::new();
    push_text(&mut blob, &outline::relative_time(seconds_ago));
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

/// The gutter bucket a block's status code names.
///
/// The repair is the point of the door: a status that did not survive the crossing reads as the
/// neutral running dot rather than claiming an outcome the block never reported.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_outline_gutter(status: u8) -> u8 {
    Gutter::from_code(status).code()
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_workspace::outline::{self, Gutter};

    use super::{slopdesk_ws_outline_gutter, slopdesk_ws_outline_relative_time};
    use crate::testing::{delivered, runs};

    #[test]
    fn every_bucket_of_the_age_line_crosses_unchanged() {
        for seconds in [-5_i64, 0, 30, 90, 3_600, 90_000, 8_640_000] {
            let blob = delivered(|out, cap| {
                // SAFETY: `out` is a live local for the call.
                unsafe { slopdesk_ws_outline_relative_time(seconds, out, cap) }
            });
            assert_eq!(
                runs(&blob, 1).first().cloned(),
                Some(outline::relative_time(seconds)),
                "{seconds}s",
            );
        }
    }

    #[test]
    fn a_status_that_did_not_survive_the_crossing_claims_no_outcome() {
        for gutter in [Gutter::Running, Gutter::Succeeded, Gutter::Failed] {
            assert_eq!(slopdesk_ws_outline_gutter(gutter.code()), gutter.code());
        }
        assert_eq!(slopdesk_ws_outline_gutter(200), Gutter::Running.code());
    }
}
