//! Pulling the HEVC parameter sets back out of a keyframe.
//!
//! The bytes do not cross. A keyframe access unit is most of a frame and the caller is already
//! holding it, so a decode answers WHERE the three sets sit and the payloads stay in the caller's
//! buffer — the same convention `slopdesk_nal_split` answers under, and for the same reason.
//!
//! An incomplete set is one answer, not three: a format description built from two of the three
//! would configure the decoder wrong, so the door says nothing was found rather than handing back
//! a partial one.

use slopdesk_video::hevc_parameter_sets::{PPS_TYPE, SPS_TYPE, VPS_TYPE, extract_spans, nal_type};

use crate::borrow;
use crate::cursor_wire::SlopDeskNalSpan;

/// The three NAL unit types this door looks for.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskHevcTypes {
    /// The video parameter set's type.
    pub vps: u8,
    /// The sequence parameter set's type.
    pub sps: u8,
    /// The picture parameter set's type.
    pub pps: u8,
}

/// One NAL unit type, as a value and a presence flag rather than a sentinel.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskHevcNalType {
    /// The type, live only when `present`.
    pub nal_type: u8,
    /// Whether the unit had a first byte at all.
    pub present: bool,
}

/// Where a keyframe's three parameter sets sit, in the order a format description wants them.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SlopDeskHevcParameterSets {
    /// Where the video parameter set sits.
    pub vps: SlopDeskNalSpan,
    /// Where the sequence parameter set sits.
    pub sps: SlopDeskNalSpan,
    /// Where the picture parameter set sits.
    pub pps: SlopDeskNalSpan,
}

/// The three types, so the near side spells none of them.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_hevc_types() -> SlopDeskHevcTypes {
    SlopDeskHevcTypes {
        vps: VPS_TYPE,
        sps: SPS_TYPE,
        pps: PPS_TYPE,
    }
}

/// The NAL unit type of one payload, taken WITHOUT its length prefix.
///
/// # Safety
/// `unit` must be null, or point to `unit_len` readable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_hevc_nal_type(unit: *const u8, unit_len: usize) -> SlopDeskHevcNalType {
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    let borrowed = unsafe { borrow(unit, unit_len) };
    nal_type(borrowed).map_or(
        SlopDeskHevcNalType {
            nal_type: 0,
            present: false,
        },
        |found| {
            SlopDeskHevcNalType {
                nal_type: found,
                present: true,
            }
        },
    )
}

/// Finds where a keyframe's parameter sets sit, answering false and leaving `out` untouched unless
/// all three are present.
///
/// # Safety
/// `avcc` must be null, or point to `avcc_len` readable bytes; `out` must be null or point to one
/// writable, aligned [`SlopDeskHevcParameterSets`]. Both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_hevc_parameter_sets(
    avcc: *const u8,
    avcc_len: usize,
    out: *mut SlopDeskHevcParameterSets,
) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation, discharged at the call site by a scoped buffer access.
    let borrowed = unsafe { borrow(avcc, avcc_len) };
    let Some(spans) = extract_spans(borrowed) else {
        return false;
    };
    let found = SlopDeskHevcParameterSets {
        vps: span(spans.vps),
        sps: span(spans.sps),
        pps: span(spans.pps),
    };
    // SAFETY: checked non-null above; the caller owns one aligned record for the call.
    unsafe { out.write(found) };
    true
}

/// One range as the span shape this boundary already answers in. A frame past four gigabytes is not
/// a frame, so the narrowing saturates rather than wrapping.
fn span(range: core::ops::Range<usize>) -> SlopDeskNalSpan {
    SlopDeskNalSpan {
        offset: u32::try_from(range.start).unwrap_or(u32::MAX),
        length: u32::try_from(range.len()).unwrap_or(u32::MAX),
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        clippy::indexing_slicing,
        unsafe_code,
        reason = "a panic in a test is the failure report, the fixture buffer is built right here, and the \
                  pointer entries have to be called to be tested"
    )]

    use super::{
        SlopDeskHevcParameterSets, slopdesk_hevc_nal_type, slopdesk_hevc_parameter_sets, slopdesk_hevc_types,
    };
    use crate::cursor_wire::SlopDeskNalSpan;

    /// One length-prefixed unit of the given type, with a payload byte to tell duplicates apart.
    fn unit(nal_unit_type: u8, tag: u8) -> Vec<u8> {
        let mut framed = vec![0, 0, 0, 3];
        framed.extend_from_slice(&[nal_unit_type << 1, 0x01, tag]);
        framed
    }

    fn avcc(units: &[Vec<u8>]) -> Vec<u8> {
        units.concat()
    }

    fn sets(buffer: &[u8]) -> Option<SlopDeskHevcParameterSets> {
        let mut found = SlopDeskHevcParameterSets {
            vps: SlopDeskNalSpan { offset: 0, length: 0 },
            sps: SlopDeskNalSpan { offset: 0, length: 0 },
            pps: SlopDeskNalSpan { offset: 0, length: 0 },
        };
        // SAFETY: both spans are live for the call.
        let complete = unsafe { slopdesk_hevc_parameter_sets(buffer.as_ptr(), buffer.len(), &raw mut found) };
        complete.then_some(found)
    }

    #[test]
    fn the_type_is_the_six_bits_under_the_forbidden_zero_bit() {
        let types = slopdesk_hevc_types();
        let payload = [types.sps << 1, 0x01];
        // SAFETY: the array outlives the call.
        let answered = unsafe { slopdesk_hevc_nal_type(payload.as_ptr(), payload.len()) };
        assert!(answered.present);
        assert_eq!(answered.nal_type, types.sps);
        // SAFETY: a null pointer is the documented empty case.
        let empty = unsafe { slopdesk_hevc_nal_type(core::ptr::null(), 0) };
        assert!(
            !empty.present,
            "an empty unit has no type, and no sentinel says so"
        );
    }

    #[test]
    fn a_keyframe_answers_where_its_three_sets_sit_and_never_copies_them() {
        let types = slopdesk_hevc_types();
        let buffer = avcc(&[
            unit(types.vps, 1),
            unit(types.sps, 2),
            unit(types.pps, 3),
            unit(19, 0xEE), // the coded slice the sets sit in front of
        ]);
        let found = sets(&buffer).expect("all three are present");
        assert_eq!(found.vps.offset, 4);
        assert_eq!(found.vps.length, 3);
        assert_eq!(found.sps.offset, 11);
        assert_eq!(found.pps.offset, 18);
        let start = found.sps.offset as usize;
        assert_eq!(
            buffer[start..start + found.sps.length as usize],
            [types.sps << 1, 0x01, 2],
            "and the span really points at the set",
        );
    }

    #[test]
    fn an_incomplete_set_answers_nothing_rather_than_a_partial_configuration() {
        let types = slopdesk_hevc_types();
        assert!(sets(&avcc(&[unit(types.vps, 1), unit(types.sps, 2)])).is_none());
        assert!(sets(&[]).is_none());
    }

    #[test]
    fn a_duplicated_set_answers_the_last_one_because_that_is_what_the_slices_use() {
        let types = slopdesk_hevc_types();
        let buffer = avcc(&[
            unit(types.vps, 1),
            unit(types.sps, 2),
            unit(types.sps, 9),
            unit(types.pps, 3),
        ]);
        let found = sets(&buffer).expect("all three are present");
        assert_eq!(found.sps.offset, 18);
    }
}
