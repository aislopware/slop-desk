//! The agent status readout, in C.
//!
//! The rules are `slopdesk_agent::readout`; what is here is the marshalling.
//!
//! Three scalars and one sentence. The READING and the INK are separate doors on purpose: they
//! answer different questions about the same status — what shape is drawn, and what tone it wears —
//! and a caller can need one without the other. Neither is a `Color`; the near side owns the
//! palette, and what crosses is which entry of it applies.

use core::ffi::c_uchar;

use slopdesk_agent::readout;

use crate::agent::status_from;
use crate::{borrow, deliver, push_text};

/// What the readout draws for `status`: `1` resting, `2` working, `3` awaiting, `4` done.
///
/// `0` is DRAW NOTHING — a pane with no agent in it — which is why the real readings start at one.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_agent_reading(status: u8) -> u8 {
    readout::reading(status_from(status)).map_or(0, readout::Reading::code)
}

/// The tone `status` wears: `0` muted, `1` thinking, `2` done, `3` awaiting.
///
/// Every status has one, including the one that draws nothing — a caller tinting a row's chrome
/// asks this without asking whether a glyph is up.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_ink(status: u8) -> u8 {
    readout::ink(status_from(status)).code()
}

/// The readout's glyph box, in points.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_agent_glyph_box() -> f64 {
    readout::GLYPH_BOX
}

/// The readout's caption, in one delivery.
///
/// ```text
/// 1 × [u32 length][UTF-8 bytes]
/// ```
///
/// `scent` is the short activity phrase the detector last saw, read only when `has_scent` is set;
/// it is APPENDED to the status label rather than replacing it, so a caption never says only what
/// the agent is doing without saying what state it is in.
///
/// # Safety
/// `scent` must be null or `scent_len` live bytes; `(out, cap)` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both pointers are the caller's"
)]
pub unsafe extern "C" fn slopdesk_agent_caption(
    status: u8,
    scent: *const c_uchar,
    scent_len: usize,
    has_scent: bool,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; the borrow dies with this call.
    let scent = String::from_utf8_lossy(unsafe { borrow(scent, scent_len) });
    let caption = readout::caption(status_from(status), has_scent.then_some(scent.as_ref()));
    let mut blob = Vec::new();
    push_text(&mut blob, &caption);
    // SAFETY: the caller's obligation, restated above; `deliver` writes at most `cap`.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]

    use slopdesk_agent::{ClaudeStatus, readout};

    use super::{
        slopdesk_agent_caption, slopdesk_agent_glyph_box, slopdesk_agent_ink, slopdesk_agent_reading,
    };
    use crate::agent::status_byte;
    use crate::testing::{delivered, runs};

    /// EVERY status, at all three doors — a parity sweep over the whole enum.
    #[test]
    fn every_status_crosses_unchanged() {
        for status in ClaudeStatus::ALL {
            let byte = status_byte(status);
            assert_eq!(
                slopdesk_agent_reading(byte),
                readout::reading(status).map_or(0, readout::Reading::code),
                "{status:?}",
            );
            assert_eq!(
                slopdesk_agent_ink(byte),
                readout::ink(status).code(),
                "{status:?}"
            );
            for scent in [None, Some(""), Some("reading files")] {
                let bytes = scent.unwrap_or_default().as_bytes().to_vec();
                let blob = delivered(|out, cap| {
                    // SAFETY: `bytes` and `out` are live locals for the call.
                    unsafe {
                        slopdesk_agent_caption(byte, bytes.as_ptr(), bytes.len(), scent.is_some(), out, cap)
                    }
                });
                assert_eq!(
                    runs(&blob, 1).first().map(String::as_str),
                    Some(readout::caption(status, scent).as_str()),
                    "{status:?} with {scent:?}",
                );
            }
        }
    }

    /// The one reserved code: an agent-less pane draws nothing, and nothing else answers zero.
    #[test]
    fn only_the_absent_agent_draws_nothing() {
        let drawing = ClaudeStatus::ALL
            .into_iter()
            .map(|status| slopdesk_agent_reading(status_byte(status)))
            .filter(|code| *code == 0)
            .count();
        assert_eq!(drawing, 1, "exactly one status draws no glyph");
        assert_eq!(slopdesk_agent_reading(status_byte(ClaudeStatus::None)), 0);
        // A byte no status has resolves to `None`, which draws nothing either.
        assert_eq!(slopdesk_agent_reading(99), 0);
    }

    #[test]
    fn the_glyph_box_crosses_unchanged() {
        assert!((slopdesk_agent_glyph_box() - readout::GLYPH_BOX).abs() < f64::EPSILON);
    }
}
