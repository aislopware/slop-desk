//! The simulator server's downstream dialect, in C.
//!
//! The rules are `slopdesk_devicepanel::sim_stream`'s. ONE door:
//! [`slopdesk_sim_stream_kind`] answers a KIND and nothing else. The payload is the message minus
//! its first byte, which the caller already holds — copying it here so it could be handed straight
//! back would be a memcpy per access unit, sixty times a second, for bytes that never left the
//! caller's own buffer.
//!
//! There WAS a second, `slopdesk_sim_avcc_parse`, answering a record's scalars and its parameter
//! sets as a length-prefixed blob. It went with the Swift that read it (2026-08-29): the only thing
//! that ever wanted those sets was a `CMVideoFormatDescription`, and
//! [`crate::panel_video::slopdesk_panel_video_configure_avcc`] now takes the record whole and calls
//! `parse_avc_configuration` on this side of the boundary. Nothing was lost — the layout's one
//! reader is still `slopdesk_devicepanel::sim_stream`, which pins it under its own tests.

use core::ffi::c_uchar;

use slopdesk_devicepanel::sim_stream::{StreamKind, stream_kind};

use crate::borrow;

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

#[cfg(test)]
#[expect(
    unsafe_code,
    reason = "calling the boundary IS what these tests are for, and a panic in a test is the report"
)]
mod tests {
    use super::{
        SLOPDESK_SIM_STREAM_CONFIGURATION, SLOPDESK_SIM_STREAM_DELTA, SLOPDESK_SIM_STREAM_JPEG,
        SLOPDESK_SIM_STREAM_KEYFRAME, SLOPDESK_SIM_STREAM_UNKNOWN, slopdesk_sim_stream_kind,
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
}
