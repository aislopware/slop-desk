//! Length-prefixed (AVCC / HVCC) NAL-unit iteration —
//! `Sources/SlopDeskVideoProtocol/NALUnit.swift`.
//!
//! `VideoToolbox` emits a `CMSampleBuffer` whose `CMBlockBuffer` holds one or more NAL units, each
//! preceded by a big-endian length prefix (4 bytes in the configs we ship). The macOS-26 "multiple
//! NALUs corrupt video" watch-item was DOWNGRADED after measurement — one NALU per buffer, even for
//! an IDR — but we iterate length-prefixed NALUs defensively anyway, because correct AVCC parsing
//! costs nothing.
//!
//! This is the pure, host/client-agnostic parse: the host hands it the raw `CMBlockBuffer` bytes,
//! and the client rebuilds the same AVCC layout from reassembled fragments before feeding the
//! decoder.

use crate::bytes::truncating_u32;

/// The length-prefix width, in bytes. AVCC and HVCC both use 4 in our encoder configs.
pub const LENGTH_PREFIX_SIZE: usize = 4;

/// Splits an AVCC byte buffer into its individual NAL units — payloads only, prefixes stripped.
///
/// Parsing is deliberately forgiving at the TAIL and strict nowhere: a prefix claiming more bytes
/// than remain, or a non-positive length, simply ends the iteration. A truncated tail means "no
/// more whole NAL units", never an error and never a panic — the frame that did arrive is still
/// worth decoding.
#[must_use]
pub fn split(avcc: &[u8]) -> Vec<&[u8]> {
    split_ranges(avcc)
        .into_iter()
        .filter_map(|unit| avcc.get(unit))
        .collect()
}

/// Says WHERE each NAL unit sits instead of handing back the bytes — the same single walk
/// [`split`] is built on.
///
/// An IDR's units are most of a frame, so a caller that is already holding the buffer wants their
/// bounds and not a second copy of them; that is also the only shape this can cross a C boundary
/// in.
#[must_use]
pub fn split_ranges(avcc: &[u8]) -> Vec<core::ops::Range<usize>> {
    let mut units = Vec::new();
    let mut offset = 0;
    while let Some(header) = avcc.get(offset..offset + LENGTH_PREFIX_SIZE) {
        let Ok(header) = <[u8; LENGTH_PREFIX_SIZE]>::try_from(header) else {
            break;
        };
        let length = u32::from_be_bytes(header) as usize;
        let start = offset + LENGTH_PREFIX_SIZE;
        // A zero length is refused as well as an overlong one: an empty NAL unit is not a unit, and
        // accepting it would advance the offset by the prefix alone and re-parse the same bytes.
        let Some(end) = length
            .checked_add(start)
            .filter(|end| length > 0 && *end <= avcc.len())
        else {
            break;
        };
        units.push(start..end);
        offset = end;
    }
    units
}

/// Re-assembles NAL-unit payloads into one AVCC byte buffer, each unit re-prefixed with its 4-byte
/// big-endian length. The inverse of [`split`].
#[must_use]
pub fn join(units: &[&[u8]]) -> Vec<u8> {
    let total: usize = units.iter().map(|unit| LENGTH_PREFIX_SIZE + unit.len()).sum();
    let mut out = Vec::with_capacity(total);
    for unit in units {
        out.extend_from_slice(&truncating_u32(unit.len()).to_be_bytes());
        out.extend_from_slice(unit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{join, split};

    #[test]
    fn a_split_recovers_each_unit_and_stops_at_a_ragged_tail() {
        // 0x42, then a prefix claiming 9 bytes with only 2 left → the tail is dropped, not an error.
        let avcc = [0, 0, 0, 1, 0x42, 0, 0, 0, 9, 0x01, 0x02];
        assert_eq!(split(&avcc), vec![&[0x42_u8][..]]);
    }

    #[test]
    fn a_zero_length_prefix_ends_the_walk_rather_than_spinning() {
        // Without the `length > 0` guard this would advance by four bytes forever on some inputs.
        let avcc = [0, 0, 0, 0, 1, 2, 3];
        assert!(split(&avcc).is_empty());
    }

    #[test]
    fn two_units_split_in_order() {
        let avcc = [0, 0, 0, 1, 0x09, 0, 0, 0, 2, 0x08, 0x07, 0x01, 0x02, 0x03];
        assert_eq!(split(&avcc), vec![&[0x09_u8][..], &[0x08, 0x07][..]]);
    }

    #[test]
    fn join_is_the_inverse_of_split() {
        let units: Vec<&[u8]> = vec![&[1, 2, 3], &[4, 5], &[6]];
        let avcc = join(&units);
        assert_eq!(avcc, vec![0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 2, 4, 5, 0, 0, 0, 1, 6]);
        assert_eq!(split(&avcc), units);
    }

    #[test]
    fn an_empty_buffer_yields_nothing_either_way() {
        assert!(split(&[]).is_empty());
        assert!(join(&[]).is_empty());
        assert!(split(&[0, 0, 0]).is_empty(), "shorter than one prefix");
    }
}
