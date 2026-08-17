//! Annex-B NAL-unit iteration, and the rewrite into AVCC — [`crate::nal_unit`]'s other half.
//!
//! Two framings carry the same NAL units. `VideoToolbox` produces and consumes AVCC — every unit
//! preceded by a big-endian length — and that is what [`crate::nal_unit`] walks. Android's
//! `MediaCodec` produces Annex-B, where units are separated by a start code instead, and that is
//! what arrives over scrcpy's stream. The panel has to turn one into the other before a decode
//! session will look at it.
//!
//! ## Both start-code lengths, not just the long one
//! One stream carries both: `MediaCodec` writes `00 00 00 01` ahead of parameter sets and the first
//! slice, and the three-byte `00 00 01` between the slices of one frame. Handling only the long
//! form does not fail — it yields NAL units with a start code embedded in them, which the decoder
//! renders as corruption, which is a far worse way to find out.
//!
//! ## Ranges, not buffers
//! Every function here answers WHERE the units sit. An access unit is most of a frame and the
//! caller already holds it, so handing back owned copies would be a copy per NAL per frame on the
//! display path. Same convention, same reason, as [`crate::nal_unit::split_ranges`].

use core::ops::Range;

use crate::bytes::truncating_u32;
use crate::hevc_parameter_sets::{PPS_TYPE, SPS_TYPE, VPS_TYPE, nal_type};
use crate::nal_unit::LENGTH_PREFIX_SIZE;

/// H.264's sequence parameter set — the type in the low five bits of the header byte.
pub const H264_SPS_TYPE: u8 = 7;
/// H.264's picture parameter set.
pub const H264_PPS_TYPE: u8 = 8;

/// Where each NAL unit sits in an Annex-B buffer — start codes excluded.
///
/// A unit runs from the end of its start code to the start of the next one, or to the end of the
/// buffer. An empty run between two adjacent start codes is dropped rather than reported: a
/// zero-length NAL unit is not a unit, which is the same call [`crate::nal_unit::split_ranges`]
/// makes about a zero length prefix.
#[must_use]
pub fn split_ranges(annexb: &[u8]) -> Vec<Range<usize>> {
    let mut starts: Vec<(usize, usize)> = Vec::new();
    let mut index = 0;
    while index + 3 <= annexb.len() {
        if annexb.get(index) == Some(&0) && annexb.get(index + 1) == Some(&0) {
            if annexb.get(index + 2) == Some(&1) {
                starts.push((index, 3));
                index += 3;
                continue;
            }
            if annexb.get(index + 2) == Some(&0) && annexb.get(index + 3) == Some(&1) {
                starts.push((index, 4));
                index += 4;
                continue;
            }
        }
        index += 1;
    }

    let mut units = Vec::with_capacity(starts.len());
    for (position, (offset, code_len)) in starts.iter().enumerate() {
        let begin = offset + code_len;
        let end = starts.get(position + 1).map_or(annexb.len(), |(next, _)| *next);
        if begin < end {
            units.push(begin..end);
        }
    }
    units
}

/// The units themselves, for a caller that is not going to hold the buffer.
#[must_use]
pub fn split(annexb: &[u8]) -> Vec<&[u8]> {
    split_ranges(annexb)
        .into_iter()
        .filter_map(|unit| annexb.get(unit))
        .collect()
}

/// An Annex-B access unit rewritten as AVCC: every unit prefixed with its big-endian length.
///
/// `None` for a buffer holding no start code at all, rather than a passthrough. A payload that is
/// already length-prefixed would otherwise be silently mis-framed, and the panel would show a
/// decoder producing nothing with no clue why — the loud answer is the recoverable one.
#[must_use]
pub fn to_avcc(annexb: &[u8]) -> Option<Vec<u8>> {
    let units = split_ranges(annexb);
    if units.is_empty() {
        return None;
    }
    let mut out = Vec::with_capacity(annexb.len() + LENGTH_PREFIX_SIZE * units.len());
    for unit in units {
        let bytes = annexb.get(unit)?;
        out.extend_from_slice(&truncating_u32(bytes.len()).to_be_bytes());
        out.extend_from_slice(bytes);
    }
    Some(out)
}

/// Where an H.264 configuration buffer's SPS and PPS sit, in the order a format description wants.
///
/// Filtered by NAL type rather than taking every unit: `MediaCodec` is free to put an access-unit
/// delimiter or an SEI in the same buffer, and the format-description constructor rejects the whole
/// set if one member is not a parameter set.
#[must_use]
pub fn h264_parameter_sets(annexb: &[u8]) -> Vec<Range<usize>> {
    parameter_sets(annexb, |first| {
        matches!(first & 0x1F, H264_SPS_TYPE | H264_PPS_TYPE)
    })
}

/// Where an H.265 configuration buffer's VPS, SPS and PPS sit.
///
/// HEVC moved the NAL type to bits 1..6, which is [`nal_type`]'s reading and not a second one.
#[must_use]
pub fn h265_parameter_sets(annexb: &[u8]) -> Vec<Range<usize>> {
    parameter_sets(annexb, |first| {
        matches!(nal_type(&[first]), Some(VPS_TYPE | SPS_TYPE | PPS_TYPE))
    })
}

fn parameter_sets(annexb: &[u8], keep: impl Fn(u8) -> bool) -> Vec<Range<usize>> {
    split_ranges(annexb)
        .into_iter()
        .filter(|unit| annexb.get(unit.start).is_some_and(|first| keep(*first)))
        .collect()
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a panic in a test IS the failure report, and the `None` arm is what the assertion denies"
)]
mod tests {
    use super::{h264_parameter_sets, h265_parameter_sets, split, split_ranges, to_avcc};

    const FOUR_BYTE: [u8; 4] = [0, 0, 0, 1];
    const THREE_BYTE: [u8; 3] = [0, 0, 1];

    #[test]
    fn both_start_code_lengths_are_split() {
        let mut unit = FOUR_BYTE.to_vec();
        unit.extend_from_slice(&[0x67, 0x01]);
        unit.extend_from_slice(&THREE_BYTE);
        unit.extend_from_slice(&[0x68, 0x02]);
        unit.extend_from_slice(&FOUR_BYTE);
        unit.extend_from_slice(&[0x65, 0x03]);
        assert_eq!(split(&unit), vec![
            &[0x67, 0x01][..],
            &[0x68, 0x02][..],
            &[0x65, 0x03][..]
        ]);
    }

    #[test]
    fn every_unit_is_rewritten_with_its_four_byte_big_endian_length() {
        let mut unit = FOUR_BYTE.to_vec();
        unit.extend_from_slice(&[0x65, 0xAA, 0xBB]);
        unit.extend_from_slice(&THREE_BYTE);
        unit.push(0x01);
        assert_eq!(
            to_avcc(&unit),
            Some(vec![0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 1, 0x01])
        );
    }

    /// The round trip both framings are supposed to preserve.
    #[test]
    fn what_this_rewrites_the_avcc_walker_reads_back() {
        let mut unit = FOUR_BYTE.to_vec();
        unit.extend_from_slice(&[0x67, 0x64, 0x00]);
        unit.extend_from_slice(&THREE_BYTE);
        unit.extend_from_slice(&[0x68, 0xEE]);
        let avcc = to_avcc(&unit).expect("a buffer with start codes rewrites");
        assert_eq!(crate::nal_unit::split(&avcc), split(&unit));
    }

    #[test]
    fn a_buffer_with_no_start_code_is_refused_rather_than_passed_through() {
        assert_eq!(to_avcc(&[0x00, 0x00, 0x00, 0x04, 0x65]), None);
        assert_eq!(to_avcc(&[]), None);
    }

    #[test]
    fn an_empty_unit_between_two_start_codes_is_skipped() {
        let mut data = FOUR_BYTE.to_vec();
        data.extend_from_slice(&FOUR_BYTE);
        data.push(0x65);
        assert_eq!(split(&data), vec![&[0x65][..]]);
        assert_eq!(split_ranges(&data), vec![8..9]);
    }

    #[test]
    fn h264_keeps_only_sps_and_pps() {
        let mut config = Vec::new();
        for nal in [
            &[0x09, 0xF0][..],       // access-unit delimiter
            &[0x67, 0x64, 0x00][..], // SPS
            &[0x06, 0x05][..],       // SEI
            &[0x68, 0xEE][..],       // PPS
        ] {
            config.extend_from_slice(&FOUR_BYTE);
            config.extend_from_slice(nal);
        }
        let kept: Vec<&[u8]> = h264_parameter_sets(&config)
            .into_iter()
            .filter_map(|unit| config.get(unit))
            .collect();
        assert_eq!(kept, vec![&[0x67, 0x64, 0x00][..], &[0x68, 0xEE][..]]);
    }

    #[test]
    fn h265_reads_its_type_from_the_other_bits() {
        let mut config = Vec::new();
        for nal in [
            &[32 << 1, 0x01][..], // VPS
            &[33 << 1, 0x02][..], // SPS
            &[34 << 1, 0x03][..], // PPS
            &[1 << 1, 0x04][..],  // a slice
        ] {
            config.extend_from_slice(&FOUR_BYTE);
            config.extend_from_slice(nal);
        }
        let kept: Vec<&[u8]> = h265_parameter_sets(&config)
            .into_iter()
            .filter_map(|unit| config.get(unit))
            .collect();
        assert_eq!(kept, vec![&[64, 0x01][..], &[66, 0x02][..], &[68, 0x03][..]]);
    }

    /// The two readings genuinely disagree, which is why there are two functions.
    #[test]
    fn an_h264_sps_is_not_an_h265_one() {
        let mut config = FOUR_BYTE.to_vec();
        config.extend_from_slice(&[0x67, 0x64]);
        assert_eq!(h264_parameter_sets(&config).len(), 1);
        assert_eq!(h265_parameter_sets(&config).len(), 0);
    }
}
