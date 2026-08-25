//! The simulator server's downstream dialect, in C.
//!
//! The rules are `slopdesk_devicepanel::sim_stream`'s. Two doors, and the split between them is the
//! whole of the design:
//!
//! - [`slopdesk_sim_stream_kind`] answers a KIND and nothing else. The payload is the message minus
//!   its first byte, which the caller already holds — copying it here so it could be handed
//!   straight back would be a memcpy per access unit, sixty times a second, for bytes that never
//!   left the caller's own buffer.
//! - [`slopdesk_sim_avcc_parse`] answers a record's four scalars in a header struct and its
//!   parameter SETS as one length-prefixed blob (`docs/55` §4's array shape). A record arrives once
//!   per stream, so the copy there is paid once and buys the caller a single delivery to cut.

use core::ffi::c_uchar;

use slopdesk_devicepanel::sim_stream::{StreamKind, parse_avc_configuration, stream_kind};

use crate::{borrow, deliver};

/// The message is an avcC configuration record.
pub const SLOPDESK_SIM_STREAM_CONFIGURATION: u8 = 0;
/// The message is an access unit that stands alone.
pub const SLOPDESK_SIM_STREAM_KEYFRAME: u8 = 1;
/// The message is an access unit that depends on the one before it.
pub const SLOPDESK_SIM_STREAM_DELTA: u8 = 2;
/// The message is a JPEG still.
pub const SLOPDESK_SIM_STREAM_JPEG: u8 = 3;
/// The message carries a type byte this build does not know — ignore it, do not drop the stream.
pub const SLOPDESK_SIM_STREAM_UNKNOWN: u8 = 4;

/// What one binary downstream message carries.
///
/// `false` — and `kind` untouched — for a message this wire never produces, which the caller drops.
/// The payload the caller then uses is the message minus its FIRST byte.
///
/// # Safety
/// `message` must be readable for `len` bytes for the duration of the call, and `kind` writable.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_stream_kind(
    message: *const c_uchar,
    len: usize,
    kind: *mut u8,
) -> bool {
    // SAFETY: the caller's obligation above.
    let message = unsafe { borrow(message, len) };
    let Some(answer) = stream_kind(message) else {
        return false;
    };
    if kind.is_null() {
        return false;
    }
    // SAFETY: `kind` was just checked non-null and is writable by the caller's obligation.
    unsafe {
        kind.write(match answer {
            StreamKind::Configuration => SLOPDESK_SIM_STREAM_CONFIGURATION,
            StreamKind::KeyFrame => SLOPDESK_SIM_STREAM_KEYFRAME,
            StreamKind::DeltaFrame => SLOPDESK_SIM_STREAM_DELTA,
            StreamKind::Jpeg => SLOPDESK_SIM_STREAM_JPEG,
            StreamKind::Unknown => SLOPDESK_SIM_STREAM_UNKNOWN,
        });
    }
    true
}

/// What an avcC record says about itself, beside the parameter sets it carries.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskAvcHeader {
    /// How many parameter sets the delivery holds.
    pub set_count: u32,
    /// 1, 2 or 4 — the NAL length prefix size the stream is framed with.
    pub nal_unit_header_length: u8,
    /// The profile indication, kept so a mismatch is diagnosable from a log.
    pub profile: u8,
    /// The level indication, kept for the same reason.
    pub level_indication: u8,
}

/// Parse an avcC record.
///
/// Answers the bytes NEEDED for the parameter-set delivery, which is `set_count` blobs each framed
/// as four big-endian length bytes then that many bytes. `0` — and `header` untouched — is a record
/// that could only build a format description which decodes nothing, which is far harder to
/// diagnose than a refusal here.
///
/// # Safety
/// `record` must be readable for `len` bytes, `header` writable, and `out` writable for `cap`
/// bytes.
#[expect(
    unsafe_code,
    reason = "an exported C entry point reading a caller-owned buffer is unsafe by definition"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn slopdesk_sim_avcc_parse(
    record: *const c_uchar,
    len: usize,
    header: *mut SlopDeskAvcHeader,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation above.
    let record = unsafe { borrow(record, len) };
    let Some(config) = parse_avc_configuration(record) else {
        return 0;
    };
    if header.is_null() {
        return 0;
    }

    let mut blob = Vec::new();
    for set in &config.parameter_sets {
        let Ok(length) = u32::try_from(set.len()) else {
            return 0;
        };
        blob.extend_from_slice(&length.to_be_bytes());
        blob.extend_from_slice(set);
    }
    let Ok(set_count) = u32::try_from(config.parameter_sets.len()) else {
        return 0;
    };

    // SAFETY: `header` was just checked non-null and is writable by the caller's obligation. Written
    // before the delivery so a caller that sized its buffer from the count can retry without
    // re-parsing — the parse is pure, but a second one is a second allocation.
    unsafe {
        header.write(SlopDeskAvcHeader {
            set_count,
            nal_unit_header_length: config.nal_unit_header_length,
            profile: config.profile,
            level_indication: config.level_indication,
        });
    }
    // SAFETY: `blob` is a live local that cannot overlap `out`, which is writable for `cap` bytes.
    unsafe { deliver(&blob, out, cap) }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        SLOPDESK_SIM_STREAM_CONFIGURATION, SLOPDESK_SIM_STREAM_DELTA, SLOPDESK_SIM_STREAM_JPEG,
        SLOPDESK_SIM_STREAM_KEYFRAME, SLOPDESK_SIM_STREAM_UNKNOWN, SlopDeskAvcHeader,
        slopdesk_sim_avcc_parse, slopdesk_sim_stream_kind,
    };

    fn kind(message: &[u8]) -> Option<u8> {
        let mut answer = 0xFF;
        // SAFETY: both are live locals for the call.
        let known = unsafe { slopdesk_sim_stream_kind(message.as_ptr(), message.len(), &raw mut answer) };
        known.then_some(answer)
    }

    /// Every type byte crosses as its own code, and a body-less message crosses as a refusal.
    #[test]
    fn the_type_byte_crosses_as_a_code() {
        assert_eq!(kind(&[0x01, 1]), Some(SLOPDESK_SIM_STREAM_CONFIGURATION));
        assert_eq!(kind(&[0x02, 1]), Some(SLOPDESK_SIM_STREAM_KEYFRAME));
        assert_eq!(kind(&[0x03, 1]), Some(SLOPDESK_SIM_STREAM_DELTA));
        assert_eq!(kind(&[0x04, 1]), Some(SLOPDESK_SIM_STREAM_JPEG));
        assert_eq!(kind(&[0x7F, 1]), Some(SLOPDESK_SIM_STREAM_UNKNOWN));
        assert_eq!(kind(&[0x02]), None);
        assert_eq!(kind(&[]), None);
    }

    /// The header and the delivery describe the SAME record: the count in one must cut the other
    /// exactly, or the caller builds a format description out of a blob it mis-split.
    #[test]
    fn the_header_cuts_the_delivery_exactly() {
        let record = [
            1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x03, 1, 2, 3, 1, 0x00, 0x02, 4, 5,
        ];
        let mut header = SlopDeskAvcHeader::default();
        let mut out = [0_u8; 64];
        // SAFETY: every pointer is a live local for the call.
        let written = unsafe {
            slopdesk_sim_avcc_parse(
                record.as_ptr(),
                record.len(),
                &raw mut header,
                out.as_mut_ptr(),
                out.len(),
            )
        };

        assert_eq!(header.set_count, 2);
        assert_eq!(header.nal_unit_header_length, 4);
        assert_eq!(header.profile, 0x64);
        assert_eq!(header.level_indication, 0x1F);
        assert_eq!(&out[..written], &[0, 0, 0, 3, 1, 2, 3, 0, 0, 0, 2, 4, 5]);
    }

    /// The §4 retry: asking with no room answers the size and writes nothing, and asking again with
    /// it answers the same bytes. A parse is pure, so a retry cannot see a different record.
    #[test]
    fn a_short_buffer_answers_the_size_and_writes_nothing() {
        let record = [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x01, 9];
        let mut header = SlopDeskAvcHeader::default();
        // SAFETY: `record` and `header` are live locals; the delivery pointer is null with cap 0.
        let needed = unsafe {
            slopdesk_sim_avcc_parse(
                record.as_ptr(),
                record.len(),
                &raw mut header,
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(needed, 5);
        assert_eq!(header.set_count, 1);
    }

    /// A record that could only decode garbage answers ZERO, which is not a size — the caller reads
    /// it as "no configuration" and keeps the decoder it had.
    #[test]
    fn a_refused_record_answers_no_size_at_all() {
        let record = [2, 0x64, 0x00, 0x1F, 0xFF, 0xE1];
        let mut header = SlopDeskAvcHeader::default();
        let mut out = [0_u8; 8];
        // SAFETY: every pointer is a live local for the call.
        let written = unsafe {
            slopdesk_sim_avcc_parse(
                record.as_ptr(),
                record.len(),
                &raw mut header,
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 0);
        assert_eq!(header, SlopDeskAvcHeader::default());
    }
}
