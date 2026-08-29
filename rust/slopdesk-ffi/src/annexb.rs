//! Annex-B NAL units — where they sit, and the rewrite into AVCC.
//!
//! [`crate::cursor_wire::slopdesk_nal_split`]'s other half. That door walks the LENGTH-PREFIXED
//! framing `VideoToolbox` speaks; this one walks the START-CODE framing Android's `MediaCodec`
//! produces, which is what arrives over scrcpy's stream.
//!
//! The bytes do not cross for the split: an access unit is most of a frame and the caller is
//! already holding it, so a walk answers WHERE the units sit and the payloads stay put. Only
//! [`slopdesk_annexb_to_avcc`] copies, because a rewrite is by definition a different buffer.

use core::ffi::c_uchar;

use slopdesk_video::annexb;
use slopdesk_video::bytes::truncating_u32;

use crate::cursor_wire::SlopDeskNalSpan;
use crate::{borrow, deliver};

/// Splits an Annex-B buffer into its NAL units, answering where each one sits.
///
/// Returns how many units the buffer holds, under §4's convention: more than `cap` means nothing
/// was written and the caller should ask again.
///
/// # Safety
/// `annexb` must be null or point to `len` readable bytes, and `out` must be null or point to `cap`
/// writable, aligned [`SlopDeskNalSpan`]s, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_annexb_split(
    annexb: *const c_uchar,
    len: usize,
    out: *mut SlopDeskNalSpan,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let buffer = unsafe { borrow(annexb, len) };
    // SAFETY: the caller's obligation for `out`/`cap`, restated above.
    unsafe { write_spans(&annexb::split_ranges(buffer), out, cap) }
}

// NOTE: `slopdesk_annexb_parameter_sets` LEFT (2026-08-29). Its one caller walked a config packet
// for the sets `CMVideoFormatDescriptionCreateFromH264ParameterSets` wanted, and both halves of
// that — the walk AND the framework call — are `slopdesk_panel_video_configure_annexb` now, on one
// side of the boundary. `slopdesk_video::annexb::h{264,265}_parameter_sets` is still the walk; it
// simply has no reason to cross.

/// An Annex-B access unit rewritten as AVCC, under §4's convention.
///
/// `0` means REFUSED, not "did not fit": a buffer holding no start code at all is not Annex-B, and
/// passing it through would silently mis-frame a payload that is already length-prefixed. A real
/// rewrite is never empty — one unit alone costs its four-byte prefix.
///
/// # Safety
/// `annexb` must be null or point to `len` readable bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_annexb_to_avcc(
    annexb: *const c_uchar,
    len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let buffer = unsafe { borrow(annexb, len) };
    let Some(avcc) = annexb::to_avcc(buffer) else {
        return 0;
    };
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&avcc, out, cap) }
}

/// The shared tail of both walks: count, or count and fill.
///
/// # Safety
/// `out` must be null or point to `cap` writable, aligned [`SlopDeskNalSpan`]s for the call.
#[expect(
    unsafe_code,
    reason = "writing through the caller's array IS the boundary this module documents"
)]
unsafe fn write_spans(units: &[core::ops::Range<usize>], out: *mut SlopDeskNalSpan, cap: usize) -> usize {
    if units.len() > cap || out.is_null() {
        return units.len();
    }
    for (slot, unit) in units.iter().enumerate() {
        let span = SlopDeskNalSpan {
            offset: truncating_u32(unit.start),
            length: truncating_u32(unit.end - unit.start),
        };
        // SAFETY: `slot` is below `units.len()`, which the check above put at or under `cap`.
        unsafe { out.add(slot).write(span) };
    }
    units.len()
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a fixed offset into a buffer the test \
              just built is the assertion"
)]
mod tests {
    use super::{slopdesk_annexb_split, slopdesk_annexb_to_avcc};
    use crate::cursor_wire::SlopDeskNalSpan;

    /// A three-unit buffer mixing both start-code lengths.
    fn fixture() -> Vec<u8> {
        let mut data = vec![0, 0, 0, 1, 0x67, 0x01];
        data.extend_from_slice(&[0, 0, 1, 0x68, 0x02]);
        data.extend_from_slice(&[0, 0, 0, 1, 0x65, 0x03]);
        data
    }

    /// The measure-then-fill convention, and both start-code lengths in one walk.
    #[test]
    fn a_split_measures_then_fills() {
        let data = fixture();
        // SAFETY: the buffer is a live local; a null `out` with `cap` 0 is the measuring call.
        let count = unsafe { slopdesk_annexb_split(data.as_ptr(), data.len(), core::ptr::null_mut(), 0) };
        assert_eq!(count, 3);

        let mut spans = [SlopDeskNalSpan::default(); 3];
        // SAFETY: both buffers are live locals.
        let filled =
            unsafe { slopdesk_annexb_split(data.as_ptr(), data.len(), spans.as_mut_ptr(), spans.len()) };
        assert_eq!(filled, 3);
        assert_eq!(&data[spans[0].offset as usize..][..spans[0].length as usize], &[
            0x67, 0x01
        ]);
        assert_eq!(&data[spans[1].offset as usize..][..spans[1].length as usize], &[
            0x68, 0x02
        ]);
        assert_eq!(&data[spans[2].offset as usize..][..spans[2].length as usize], &[
            0x65, 0x03
        ]);
    }

    /// Too small an array writes nothing and says how many there are.
    #[test]
    fn a_split_that_does_not_fit_writes_nothing() {
        let data = fixture();
        let mut spans = [SlopDeskNalSpan::default(); 1];
        // SAFETY: both buffers are live locals.
        let count =
            unsafe { slopdesk_annexb_split(data.as_ptr(), data.len(), spans.as_mut_ptr(), spans.len()) };
        assert_eq!(count, 3);
        assert_eq!(spans[0], SlopDeskNalSpan::default(), "untouched");
    }

    /// The rewrite the decode session takes, and the refusal that is not a size.
    #[test]
    fn a_rewrite_prefixes_each_unit_and_refuses_a_buffer_with_no_start_code() {
        let data = fixture();
        // SAFETY: the buffer is a live local; a null `out` with `cap` 0 is the measuring call.
        let needed = unsafe { slopdesk_annexb_to_avcc(data.as_ptr(), data.len(), core::ptr::null_mut(), 0) };
        assert_eq!(needed, 3 * (4 + 2));

        let mut avcc = vec![0_u8; needed];
        // SAFETY: both buffers are live locals.
        let written =
            unsafe { slopdesk_annexb_to_avcc(data.as_ptr(), data.len(), avcc.as_mut_ptr(), avcc.len()) };
        assert_eq!(written, needed);
        assert_eq!(&avcc[..6], &[0, 0, 0, 2, 0x67, 0x01]);

        let bare = [0x00, 0x00, 0x00, 0x04, 0x65];
        // SAFETY: the buffer is a live local.
        let refused = unsafe { slopdesk_annexb_to_avcc(bare.as_ptr(), bare.len(), core::ptr::null_mut(), 0) };
        assert_eq!(refused, 0, "already length-prefixed is not Annex-B");
    }
}
