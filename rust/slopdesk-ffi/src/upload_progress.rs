//! How full a drag-drop upload's bar is, and whether the row has settled — in C.
//!
//! The rules are [`slopdesk_workspace::gui_readout`]'s `upload_fraction` and `upload_is_settled`,
//! beside the glyph and the tint that already crossed for the same three-case phase.
//!
//! Two scalar doors with scalar answers: there is nothing to size, nothing to retry, and no buffer
//! at either end. The phase crosses as its byte, the same byte
//! `slopdesk_ws_gui_upload_glyph` reads, so a row's bar and its mark can never be reading two
//! different phases.
//!
//! ## Why the FRACTION is worth a door at all
//!
//! It is four lines of arithmetic, and `CLAUDE.md`'s bit-exactness rule is exactly why they belong
//! on one side of the boundary rather than being retyped on the other. Two `u64`→`f64` conversions,
//! one division and one `min`, in that order and with nothing fused — a second copy in Swift that
//! reached for `addingProduct` or reassociated the division would drift by a bit and nothing would
//! fail. The crate's module header spells the argument out step by step.

use slopdesk_workspace::gui_readout::{UploadPhase, upload_fraction, upload_is_settled};

/// How full the upload row's progress bar is, in `0..=1`.
///
/// `phase_code` is the phase byte: 0 sending · 1 completed · 2 failed, and anything else reads as
/// SENDING — never a completion that did not happen.
///
/// Completed reads 1 whatever the counters say, because a transfer whose size was never reported
/// would otherwise finish at an empty bar. A total of 0 while sending reads 0 rather than dividing
/// by zero — there is no fraction of an unknown size, and an indeterminate bar is the renderer's
/// business. Everything else is `sent / total` ceilinged at 1, so a host that over-reports cannot
/// push the bar past its track.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_ws_gui_upload_fraction(phase_code: u8, sent_bytes: u64, total_bytes: u64) -> f64 {
    upload_fraction(UploadPhase::from_code(phase_code), sent_bytes, total_bytes)
}

/// Whether the upload has SETTLED — completed or failed — which is the cue its row's dismissal is
/// scheduled on.
///
/// Failure settles as surely as success does; a row that lingered because the transfer ended badly
/// would be the one row on the overlay that never goes away. An unnamed phase byte has NOT settled,
/// for the same reason it draws the sending glyph.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_gui_upload_is_settled(phase_code: u8) -> bool {
    upload_is_settled(UploadPhase::from_code(phase_code))
}

#[cfg(test)]
mod tests {
    use super::{slopdesk_ws_gui_upload_fraction, slopdesk_ws_gui_upload_is_settled};

    const SENDING: u8 = 0;
    const COMPLETED: u8 = 1;
    const FAILED: u8 = 2;

    /// Every branch of the bar, across the boundary — including the two the near side's suite could
    /// not reach because its `Phase` had no fourth case.
    #[test]
    fn the_bar_crosses_full_when_done_empty_when_unmeasured_and_never_past_its_track() {
        assert!((slopdesk_ws_gui_upload_fraction(SENDING, 25, 100) - 0.25).abs() < f64::EPSILON);
        assert!((slopdesk_ws_gui_upload_fraction(COMPLETED, 0, 0) - 1.0).abs() < f64::EPSILON);
        assert!((slopdesk_ws_gui_upload_fraction(SENDING, 10, 0) - 0.0).abs() < f64::EPSILON);
        assert!((slopdesk_ws_gui_upload_fraction(FAILED, 40, 100) - 0.4).abs() < f64::EPSILON);
        assert!((slopdesk_ws_gui_upload_fraction(SENDING, 300, 100) - 1.0).abs() < f64::EPSILON);
        assert!(
            (slopdesk_ws_gui_upload_fraction(9, 25, 100) - 0.25).abs() < f64::EPSILON,
            "an unnamed phase byte is still IN FLIGHT",
        );
    }

    /// Settlement, and the unnamed byte that must not claim it.
    #[test]
    fn both_endings_settle_and_an_unnamed_byte_does_not() {
        assert!(!slopdesk_ws_gui_upload_is_settled(SENDING));
        assert!(slopdesk_ws_gui_upload_is_settled(COMPLETED));
        assert!(slopdesk_ws_gui_upload_is_settled(FAILED));
        assert!(!slopdesk_ws_gui_upload_is_settled(9));
    }
}
