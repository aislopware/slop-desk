//! The simulator server's DOWNSTREAM dialect: what a binary websocket message is, and what an avcC
//! record says.
//!
//! This is a FOREIGN wire, not one of slopdesk's own. `baguette serve` defines it and this side
//! speaks it, so the rules that govern the mux protocol do not apply: there are no golden vectors
//! to pin and no version byte anyone here controls. What it owes instead is what every untrusted
//! decoder owes — an optional answer, validate-then-drop, and not one byte read without a bounds
//! check. The frames arrive over the mesh from a process the user installed, and a malformed one
//! must yield `None`, never a panic.
//!
//! The dialect, measured against `baguette serve` v2 (`docs/47-simulator-panel.md`):
//!
//! ```text
//! BINARY message = [1 byte type][payload]
//!   0x01  avcC decoder configuration record (SPS/PPS)
//!   0x02  H.264 IDR    — AVCC, length-prefixed NALs (NOT Annex-B start codes)
//!   0x03  H.264 delta  — same framing
//!   0x04  JPEG seed frame — painted before the first IDR lands, so the surface is never blank
//! TEXT message = JSON; carries errors and control, never pixels.
//! ```
//!
//! ## The payload never crosses
//!
//! [`stream_kind`] answers the KIND and nothing else. The payload is the message minus its first
//! byte, which the caller already holds and can slice for free — copying it here so it could be
//! handed straight back would be a memcpy per access unit, sixty times a second, for a value that
//! never left the caller's own buffer.

/// What one binary downstream message carries.
///
/// [`Unknown`](Self::Unknown) is a first-class answer on purpose: a newer server that adds a type
/// must degrade to "ignore that message" rather than to a dropped connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum StreamKind {
    /// The avcC configuration record — the parameter sets a decoder is built from.
    Configuration = 0,
    /// An access unit that stands alone: a keyframe.
    KeyFrame = 1,
    /// An access unit that depends on the one before it.
    DeltaFrame = 2,
    /// A JPEG still, painted until the first access unit decodes.
    Jpeg = 3,
    /// A type byte this build does not know.
    Unknown = 4,
}

/// The type byte of an avcC configuration record.
pub const TYPE_CONFIGURATION: u8 = 0x01;
/// The type byte of a keyframe access unit.
pub const TYPE_KEYFRAME: u8 = 0x02;
/// The type byte of a delta access unit.
pub const TYPE_DELTA: u8 = 0x03;
/// The type byte of a JPEG still.
pub const TYPE_JPEG: u8 = 0x04;

/// What `message` carries, or `None` when it is not a message this wire produces.
///
/// A message shorter than two bytes answers `None` rather than an empty-payload one: the server
/// never sends a bodiless frame, so one on the wire means the stream is not what this thinks it is,
/// and the honest response is to drop it. The server's own page decoder applies the same
/// `byteLength < 2` floor.
#[must_use]
pub fn stream_kind(message: &[u8]) -> Option<StreamKind> {
    let (&type_byte, payload) = message.split_first()?;
    if payload.is_empty() {
        return None;
    }
    Some(match type_byte {
        TYPE_CONFIGURATION => StreamKind::Configuration,
        TYPE_KEYFRAME => StreamKind::KeyFrame,
        TYPE_DELTA => StreamKind::DeltaFrame,
        TYPE_JPEG => StreamKind::Jpeg,
        _ => StreamKind::Unknown,
    })
}

/// The parameter sets and NAL length size an avcC record carries — everything a format description
/// is built from, and nothing else.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AvcConfiguration {
    /// The SPS blobs, then the PPS blobs, in the order the record listed them. Empty sets are
    /// dropped: one is meaningless to a decoder and would only make the format description fail
    /// later, further from the cause.
    pub parameter_sets: Vec<Vec<u8>>,
    /// 1, 2 or 4. Every observed stream uses 4; the field is PARSED rather than assumed because a
    /// wrong guess here decodes as garbage instead of failing loudly.
    pub nal_unit_header_length: u8,
    /// The profile indication, kept only so a mismatch is diagnosable from a log.
    pub profile: u8,
    /// The level indication, kept for the same reason.
    pub level_indication: u8,
}

/// Parse an avcC record.
///
/// `None` on any truncation, an unknown configuration version, or a record carrying no SPS — each
/// of which would otherwise become a format description that decodes nothing, which is far harder
/// to diagnose than a refusal at the door.
///
/// Layout (ISO/IEC 14496-15 §5.2.4.1): version, profile, compatibility, level, then a byte whose
/// low two bits are `lengthSizeMinusOne`, then a byte whose low five bits are the SPS count, then
/// length-prefixed SPS blobs, then a PPS count byte and its length-prefixed blobs.
#[must_use]
pub fn parse_avc_configuration(record: &[u8]) -> Option<AvcConfiguration> {
    let mut reader = ByteReader::new(record);
    let version = reader.byte()?;
    if version != 1 {
        return None;
    }
    let profile = reader.byte()?;
    reader.byte()?; // profile compatibility — read to advance, never used.
    let level_indication = reader.byte()?;
    let length_byte = reader.byte()?;
    let sps_count = reader.byte()?;

    let mut parameter_sets = Vec::new();
    reader.read_parameter_sets(usize::from(sps_count & 0x1F), &mut parameter_sets)?;
    if parameter_sets.is_empty() {
        return None;
    }
    // The PPS count and its sets are absent from a truncated record. That is tolerated: an SPS
    // alone still yields a usable format description, and refusing here would turn a
    // recoverable stream into a dead panel.
    if let Some(pps_count) = reader.byte() {
        reader.read_parameter_sets(usize::from(pps_count), &mut parameter_sets)?;
    }

    Some(AvcConfiguration {
        parameter_sets,
        nal_unit_header_length: (length_byte & 0x03) + 1,
        profile,
        level_indication,
    })
}

/// A cursor that can only move forward and never past the end. Every read is bounds-checked and
/// answers an option — the shape an untrusted-input decoder owes.
struct ByteReader<'a> {
    bytes: &'a [u8],
}

impl<'a> ByteReader<'a> {
    const fn new(bytes: &'a [u8]) -> Self {
        Self { bytes }
    }

    fn byte(&mut self) -> Option<u8> {
        let (&first, rest) = self.bytes.split_first()?;
        self.bytes = rest;
        Some(first)
    }

    fn blob(&mut self, length: usize) -> Option<&'a [u8]> {
        let (blob, rest) = self.bytes.split_at_checked(length)?;
        self.bytes = rest;
        Some(blob)
    }

    /// `count` consecutive `[u16 BE length][bytes]` blobs, appended to `sets`. A zero-length set is
    /// skipped rather than appended, for the reason [`AvcConfiguration::parameter_sets`] gives.
    fn read_parameter_sets(&mut self, count: usize, sets: &mut Vec<Vec<u8>>) -> Option<()> {
        for _ in 0..count {
            let high = self.byte()?;
            let low = self.byte()?;
            let length = usize::from(u16::from_be_bytes([high, low]));
            let blob = self.blob(length)?;
            if !blob.is_empty() {
                sets.push(blob.to_vec());
            }
        }
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use super::{AvcConfiguration, StreamKind, parse_avc_configuration, stream_kind};

    #[test]
    fn each_type_byte_names_its_own_kind() {
        assert_eq!(stream_kind(&[0x01, 0xAA]), Some(StreamKind::Configuration));
        assert_eq!(stream_kind(&[0x02, 0xAA]), Some(StreamKind::KeyFrame));
        assert_eq!(stream_kind(&[0x03, 0xAA]), Some(StreamKind::DeltaFrame));
        assert_eq!(stream_kind(&[0x04, 0xAA]), Some(StreamKind::Jpeg));
    }

    /// A type this build has never heard of is IGNORED, not fatal — the server may add one, and a
    /// dropped connection over an unread message is a panel that dies on an upgrade.
    #[test]
    fn an_unknown_type_is_a_message_to_ignore_not_a_broken_stream() {
        assert_eq!(stream_kind(&[0x7F, 0xAA]), Some(StreamKind::Unknown));
    }

    /// The two-byte floor: the server never sends a bodiless frame, so one means the stream is not
    /// what this thinks it is.
    #[test]
    fn a_message_with_no_body_is_refused() {
        assert_eq!(stream_kind(&[]), None);
        assert_eq!(stream_kind(&[0x02]), None);
    }

    /// One SPS and one PPS, the shape every observed stream sends.
    #[test]
    fn a_whole_record_yields_both_parameter_sets_and_the_nal_length() {
        let record = [
            1, 0x64, 0x00, 0x1F, // version, profile, compatibility, level
            0xFF, // lengthSizeMinusOne = 3 in the low two bits
            0xE1, // one SPS in the low five bits
            0x00, 0x03, 1, 2, 3, // SPS
            1, // one PPS
            0x00, 0x02, 4, 5, // PPS
        ];

        assert_eq!(
            parse_avc_configuration(&record),
            Some(AvcConfiguration {
                parameter_sets: vec![vec![1, 2, 3], vec![4, 5]],
                nal_unit_header_length: 4,
                profile: 0x64,
                level_indication: 0x1F,
            })
        );
    }

    /// An SPS alone is USABLE, so a record that stops after it is kept. The alternative turns a
    /// recoverable stream into a dead panel over bytes the decoder did not need.
    #[test]
    fn a_record_that_stops_after_its_sps_is_still_a_configuration() {
        let record = [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x01, 9];
        let parsed = parse_avc_configuration(&record).map(|config| config.parameter_sets);
        assert_eq!(parsed, Some(vec![vec![9]]));
    }

    /// Each refusal is one a format description would otherwise be built from and then decode
    /// nothing, which is the failure that is hard to trace back here.
    #[test]
    fn a_record_that_could_only_decode_garbage_is_refused() {
        // A version byte this layout is not.
        assert_eq!(parse_avc_configuration(&[2, 0x64, 0x00, 0x1F, 0xFF, 0xE1]), None);
        // No SPS at all.
        assert_eq!(parse_avc_configuration(&[1, 0x64, 0x00, 0x1F, 0xFF, 0xE0]), None);
        // An SPS whose length runs past the record.
        assert_eq!(
            parse_avc_configuration(&[1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x08, 1, 2]),
            None
        );
        // Truncated before the counts.
        assert_eq!(parse_avc_configuration(&[1, 0x64, 0x00]), None);
    }

    /// A declared PPS that is not there is a TRUNCATION, unlike an absent count — the record said
    /// how many were coming, so fewer means the message was cut.
    #[test]
    fn a_pps_count_that_lies_is_a_truncation() {
        let record = [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x01, 9, 2, 0x00, 0x01, 8];
        assert_eq!(parse_avc_configuration(&record), None);
    }

    /// An empty set is dropped rather than carried: the decoder cannot use one, and it would only
    /// make the format description fail later.
    #[test]
    fn an_empty_parameter_set_is_dropped() {
        let record = [1, 0x64, 0x00, 0x1F, 0xFF, 0xE2, 0x00, 0x00, 0x00, 0x01, 7];
        let parsed = parse_avc_configuration(&record).map(|config| config.parameter_sets);
        assert_eq!(parsed, Some(vec![vec![7]]));
    }

    /// The length size is read, not assumed: a wrong guess decodes as garbage instead of failing.
    #[test]
    fn the_nal_length_size_comes_off_the_record() {
        let with_size = |byte: u8| {
            let record = [1, 0x64, 0x00, 0x1F, byte, 0xE1, 0x00, 0x01, 9];
            parse_avc_configuration(&record).map(|config| config.nal_unit_header_length)
        };
        assert_eq!(with_size(0xFC), Some(1));
        assert_eq!(with_size(0xFD), Some(2));
        assert_eq!(with_size(0xFF), Some(4));
    }
}
