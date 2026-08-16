//! Pulling the HEVC parameter sets back out of a keyframe.
//!
//! The host streams length-prefixed NAL units with no out-of-band parameter sets, because the
//! encoder keeps them in the sample buffer's format description rather than inline. So the host
//! explicitly PREPENDS them ahead of the coded slice on a keyframe, and a keyframe access unit
//! carries its video, sequence and picture parameter sets inline — which is what this reads back.
//!
//! The client's decoder needs a format description built from those three before it can decode the
//! first slice. Walking the units and pulling the payloads is the pure part, and it lives here so
//! it is testable with no decoder anywhere near it.
//!
//! The two-byte NAL header is a forbidden zero bit, a six-bit type, a six-bit layer id and a
//! three-bit temporal id, so the type is the low six bits of the first byte after the top one.

use crate::nal_unit;

/// The video parameter set's NAL unit type.
pub const VPS_TYPE: u8 = 32;
/// The sequence parameter set's NAL unit type.
pub const SPS_TYPE: u8 = 33;
/// The picture parameter set's NAL unit type.
pub const PPS_TYPE: u8 = 34;

/// The three parameter sets, in the order the format-description call wants them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParameterSets {
    /// The video parameter set.
    pub vps: Vec<u8>,
    /// The sequence parameter set.
    pub sps: Vec<u8>,
    /// The picture parameter set.
    pub pps: Vec<u8>,
}

impl ParameterSets {
    /// The three payloads in their fixed order.
    #[must_use]
    pub fn ordered(&self) -> [&[u8]; 3] {
        [&self.vps, &self.sps, &self.pps]
    }
}

/// The NAL unit type of one payload, taken WITHOUT its length prefix. `None` for an empty unit.
#[must_use]
pub fn nal_type(unit: &[u8]) -> Option<u8> {
    unit.first().map(|&first| (first >> 1) & 0x3F)
}

/// Where the three parameter sets sit inside the buffer they were read from.
///
/// A caller already holding the access unit wants their BOUNDS rather than a second copy of bytes
/// it has — and bounds are the only shape they can cross a C boundary in, which is the same
/// reasoning [`nal_unit::split_ranges`] is built on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParameterSetSpans {
    /// Where the video parameter set sits.
    pub vps: core::ops::Range<usize>,
    /// Where the sequence parameter set sits.
    pub sps: core::ops::Range<usize>,
    /// Where the picture parameter set sits.
    pub pps: core::ops::Range<usize>,
}

/// Finds where a keyframe's three parameter sets sit.
///
/// `None` unless all three are present: an incomplete set cannot build a format description, and
/// the decoder has to wait for a full keyframe rather than configure itself halfway.
///
/// Takes the LAST of each. An access unit normally carries one of each, and where one is
/// duplicated, the trailing set is the one active for the slices that follow.
#[must_use]
pub fn extract_spans(avcc: &[u8]) -> Option<ParameterSetSpans> {
    let mut vps = None;
    let mut sps = None;
    let mut pps = None;
    for unit in nal_unit::split_ranges(avcc) {
        match avcc.get(unit.clone()).and_then(nal_type) {
            Some(VPS_TYPE) => vps = Some(unit),
            Some(SPS_TYPE) => sps = Some(unit),
            Some(PPS_TYPE) => pps = Some(unit),
            _ => {},
        }
    }
    Some(ParameterSetSpans {
        vps: vps?,
        sps: sps?,
        pps: pps?,
    })
}

/// Pulls the parameter sets out of a keyframe buffer, for a caller that wants the bytes.
#[must_use]
pub fn extract(avcc: &[u8]) -> Option<ParameterSets> {
    let spans = extract_spans(avcc)?;
    Some(ParameterSets {
        vps: avcc.get(spans.vps)?.to_vec(),
        sps: avcc.get(spans.sps)?.to_vec(),
        pps: avcc.get(spans.pps)?.to_vec(),
    })
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{PPS_TYPE, SPS_TYPE, VPS_TYPE, extract, nal_type};
    use crate::nal_unit;

    /// One NAL unit of the given type, with a payload byte to tell duplicates apart.
    fn unit(nal_unit_type: u8, tag: u8) -> Vec<u8> {
        vec![nal_unit_type << 1, 0x01, tag]
    }

    /// A coded slice, which is what a keyframe's parameter sets sit in front of.
    fn slice() -> Vec<u8> {
        unit(19, 0xEE)
    }

    fn avcc(units: &[Vec<u8>]) -> Vec<u8> {
        nal_unit::join(&units.iter().map(Vec::as_slice).collect::<Vec<_>>())
    }

    #[test]
    fn the_type_is_the_six_bits_under_the_forbidden_zero_bit() {
        assert_eq!(nal_type(&unit(VPS_TYPE, 0)), Some(VPS_TYPE));
        assert_eq!(nal_type(&unit(PPS_TYPE, 0)), Some(PPS_TYPE));
        assert_eq!(nal_type(&[]), None);
    }

    #[test]
    fn a_keyframe_yields_its_three_parameter_sets() {
        let buffer = avcc(&[unit(VPS_TYPE, 1), unit(SPS_TYPE, 2), unit(PPS_TYPE, 3), slice()]);
        let sets = extract(&buffer).expect("all three are present");
        assert_eq!(sets.vps, unit(VPS_TYPE, 1));
        assert_eq!(sets.sps, unit(SPS_TYPE, 2));
        assert_eq!(sets.pps, unit(PPS_TYPE, 3));
        assert_eq!(sets.ordered().len(), 3);
    }

    /// A format description built from half a set would configure the decoder wrong.
    #[test]
    fn an_incomplete_set_yields_nothing_rather_than_a_partial_configuration() {
        assert_eq!(
            extract(&avcc(&[unit(VPS_TYPE, 1), unit(SPS_TYPE, 2), slice()])),
            None,
        );
        assert_eq!(extract(&avcc(&[slice()])), None, "a delta carries none");
        assert_eq!(extract(&[]), None);
    }

    /// The trailing set is the one active for the slices that follow it.
    #[test]
    fn a_duplicated_parameter_set_takes_the_last_one() {
        let buffer = avcc(&[
            unit(VPS_TYPE, 1),
            unit(SPS_TYPE, 2),
            unit(PPS_TYPE, 3),
            unit(PPS_TYPE, 9),
            slice(),
        ]);
        let sets = extract(&buffer).expect("all three are present");
        assert_eq!(sets.pps, unit(PPS_TYPE, 9));
    }

    /// The buffer arrives from the wire, so a truncated one must not be an error.
    #[test]
    fn a_truncated_buffer_reads_the_units_that_did_arrive() {
        let mut buffer = avcc(&[unit(VPS_TYPE, 1), unit(SPS_TYPE, 2), unit(PPS_TYPE, 3)]);
        buffer.truncate(buffer.len() - 1);
        assert_eq!(extract(&buffer), None, "the last unit is not whole");
    }
}
