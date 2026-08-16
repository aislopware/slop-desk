//! The three low-rate host↔client metadata wires: window geometry, swipe-nav status, app audio.
//!
//! They share a module because they share a shape — a small message off the same untrusted UDP
//! mesh, decoded into something the UI or the audio ring acts on — and because none of them is big
//! enough to earn a file. What each one guards is different, and that is the part worth reading:
//!
//! * geometry coordinates land in a `CALayer` frame, where a NaN is an uncaught
//!   `CALayerInvalidGeometry` and a dead client. Finite-checked at decode.
//! * the swipe status drives an affordance that must never promise a navigation the host would
//!   refuse, so its type byte is checked rather than assumed.
//! * an audio datagram declares its own payload length, which is the classic over-allocate lever:
//!   the cap and the exact-consumption check are decode guards, not the caller's manners.
//!
//! Every one of them answers OFFSETS into the caller's datagram rather than copies — a title, a
//! codec frame, an AAC cookie — for the reason `docs/55-ffi-boundary.md` §4 gives: the caller is
//! still holding the bytes it just handed over.

use core::ffi::c_uchar;

use slopdesk_video::audio_wire::{
    AudioChannelMessage, AudioStreamConfig, AudioWireFormat, decode_config_parts, decode_parts,
};
use slopdesk_video::error::VideoProtocolError;
use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};
use slopdesk_video::swipe_nav::{SwipeDirection, SwipeNavStatusMessage};
use slopdesk_video::window_geometry::WindowGeometryMessage;

use crate::{borrow, deliver};

/// The datagram parsed.
pub const METADATA_DECODE_OK: u32 = 0;
/// The datagram ended mid-field.
pub const METADATA_DECODE_TRUNCATED: u32 = 1;
/// The datagram was well-sized and unacceptable.
pub const METADATA_DECODE_MALFORMED: u32 = 2;

/// Which verdict a decode failure earns. Truncated and malformed stay apart because the caller's
/// own error type keeps them apart, and one of the two is a normal consequence of a lost packet.
const fn verdict(error: &VideoProtocolError) -> u32 {
    match *error {
        VideoProtocolError::Truncated => METADATA_DECODE_TRUNCATED,
        VideoProtocolError::Malformed(_) => METADATA_DECODE_MALFORMED,
    }
}

// -- Window geometry ---------------------------------------------------------------------- //

/// One window-geometry message, flat. `message_type` says which fields mean anything: 1 move
/// (x, y), 2 resize (width, height), 3 bounds (all four), 4 title (`title_offset`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskWindowGeometry {
    /// Origin x in host CG space, points.
    pub x: f64,
    /// Origin y in host CG space, points.
    pub y: f64,
    /// Width in points.
    pub width: f64,
    /// Height in points.
    pub height: f64,
    /// Which wire type this is.
    pub message_type: u8,
    /// Where the UTF-8 title starts in the datagram, for the title arm. 0 everywhere else.
    pub title_offset: u8,
}

/// Parses one window-geometry datagram.
///
/// Non-finite coordinates are malformed, and so is a title that is not valid UTF-8 — strictly,
/// never lossily, because a mojibake title is a corrupt datagram and not a rendering problem.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskWindowGeometry`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_geometry_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskWindowGeometry,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let parsed = match WindowGeometryMessage::decode(datagram) {
        Ok(message) => message,
        Err(error) => return verdict(&error),
    };
    if out.is_null() {
        return METADATA_DECODE_OK;
    }
    let mut flat = SlopDeskWindowGeometry {
        message_type: parsed.message_type(),
        ..SlopDeskWindowGeometry::default()
    };
    match parsed {
        WindowGeometryMessage::Move(point) => {
            flat.x = point.x;
            flat.y = point.y;
        },
        WindowGeometryMessage::Resize(size) => {
            flat.width = size.width;
            flat.height = size.height;
        },
        WindowGeometryMessage::Bounds(rect) => {
            flat.x = rect.origin.x;
            flat.y = rect.origin.y;
            flat.width = rect.size.width;
            flat.height = rect.size.height;
        },
        // The title stays in the caller's datagram, one byte past the type.
        WindowGeometryMessage::Title(_) => flat.title_offset = GEOMETRY_TITLE_OFFSET,
    }
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned value.
    unsafe { out.write(flat) };
    METADATA_DECODE_OK
}

/// Serialises one window-geometry message; the title arm takes its bytes through `title`. Returns
/// bytes NEEDED under §4, and 0 for a type no arm answers to.
///
/// # Safety
/// `title` must be null or point to `title_len` readable bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_window_geometry_encode(
    message: SlopDeskWindowGeometry,
    title: *const c_uchar,
    title_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let title_bytes = unsafe { borrow(title, title_len) };
    let rebuilt = match message.message_type {
        1 => WindowGeometryMessage::Move(VideoPoint::new(message.x, message.y)),
        2 => WindowGeometryMessage::Resize(VideoSize::new(message.width, message.height)),
        3 => {
            WindowGeometryMessage::Bounds(VideoRect::xywh(
                message.x,
                message.y,
                message.width,
                message.height,
            ))
        },
        4 => {
            match String::from_utf8(title_bytes.to_vec()) {
                Ok(title) => WindowGeometryMessage::Title(title),
                Err(_) => return 0,
            }
        },
        _ => return 0,
    };
    let datagram = rebuilt.encode();
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&datagram, out, cap) }
}

/// Where a title starts: one type byte in.
const GEOMETRY_TITLE_OFFSET: u8 = 1;

/// The offsets a caller would otherwise spell itself. `index` selects — 0 the title offset.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_window_geometry_constant(index: u8) -> u8 {
    match index {
        0 => GEOMETRY_TITLE_OFFSET,
        _ => 0,
    }
}

// -- Swipe-nav status --------------------------------------------------------------------- //

/// The host's swipe-nav status, flat. Six bytes on the wire, and every one of them is about
/// whether an affordance may promise something.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskSwipeNavStatus {
    /// The host's lift-fire travel threshold in points, already clamped.
    pub fire_travel: u16,
    /// Whether a qualifying swipe would currently be translated into a navigation.
    pub eligible: bool,
    /// Whether the host's slow tier is on.
    pub slow_tier: bool,
    /// The target app's back command would navigate right now. Meaningless unless known.
    pub can_go_back: bool,
    /// The target app's forward command would navigate right now. Meaningless unless known.
    pub can_go_forward: bool,
    /// Whether the host actually read the history state. False means FAIL OPEN, never dark.
    pub history_known: bool,
}

impl SlopDeskSwipeNavStatus {
    /// The flat value as the message it describes.
    pub(crate) const fn message(self) -> SwipeNavStatusMessage {
        SwipeNavStatusMessage::new(
            self.eligible,
            self.slow_tier,
            self.fire_travel,
            self.can_go_back,
            self.can_go_forward,
            self.history_known,
        )
    }
}

/// Serialises the status: a fixed six bytes. Returns bytes NEEDED under §4.
///
/// # Safety
/// `out` must be null or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_status_encode(
    status: SlopDeskSwipeNavStatus,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let datagram = status.message().encode();
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&datagram, out, cap) }
}

/// Parses a status datagram.
///
/// A datagram that is not this message type is malformed rather than ignored: the cursor socket
/// carries three types, and picking the wrong one would drive the affordance from another
/// message's bytes.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskSwipeNavStatus`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_swipe_nav_status_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskSwipeNavStatus,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let parsed = match SwipeNavStatusMessage::decode(datagram) {
        Ok(status) => status,
        Err(error) => return verdict(&error),
    };
    if out.is_null() {
        return METADATA_DECODE_OK;
    }
    let flat = SlopDeskSwipeNavStatus {
        fire_travel: parsed.fire_travel,
        eligible: parsed.eligible,
        slow_tier: parsed.slow_tier,
        can_go_back: parsed.can_go_back,
        can_go_forward: parsed.can_go_forward,
        history_known: parsed.history_known,
    };
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned value.
    unsafe { out.write(flat) };
    METADATA_DECODE_OK
}

/// Whether the chip may show for a swipe in `direction` — 0 back, anything else forward.
///
/// Known-dead history suppresses the affordance; UNKNOWN fails open. The host's fire path
/// deliberately does not apply this, so a stale read can cost feedback and never a navigation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_swipe_nav_allows_chip(
    status: SlopDeskSwipeNavStatus,
    direction: u8,
) -> bool {
    let direction = if direction == 0 {
        SwipeDirection::Back
    } else {
        SwipeDirection::Forward
    };
    status.message().allows_chip(direction)
}

/// The numbers the status wire declares. `index` selects — 0 the message type, 1 the encoded size.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_swipe_nav_constant(index: u8) -> usize {
    match index {
        0 => SwipeNavStatusMessage::MESSAGE_TYPE as usize,
        1 => SwipeNavStatusMessage::ENCODED_SIZE,
        _ => 0,
    }
}

// -- App audio ---------------------------------------------------------------------------- //

/// One app-audio datagram, flat.
///
/// `is_config` picks the grammar: a config carries the decode parameters and a cookie span, a frame
/// carries a payload span. Both spans index the datagram the caller passed in.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskAudioMessage {
    /// One monotonic counter for every packet of a session, config and frame alike.
    pub seq: u32,
    /// Host-monotonic ms, relative to the host session and never cross-clock.
    pub host_send_ts_millis: u32,
    /// Sample rate in Hz. Config only.
    pub sample_rate: u32,
    /// Where the frame payload or the cookie starts in the datagram.
    pub span_offset: u16,
    /// How many bytes of it there are.
    pub span_length: u16,
    /// Whether this is a config packet.
    pub is_config: bool,
    /// The wire format id. Config only.
    pub format: u8,
    /// Interleaved channel count. Config only.
    pub channels: u8,
}

/// Parses one audio datagram.
///
/// The declared payload length is the lever a corrupt datagram would pull to make a receiver
/// allocate: over the cap is malformed, past the end is truncated, and a byte left over is
/// malformed too. All three are decode guards here.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskAudioMessage`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskAudioMessage,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    // The BORROWING decode: every guard, no owned payload. The span the caller wants is inside the
    // datagram it still holds, so copying it here and again on the way back would copy every audio
    // frame twice to answer where it starts.
    let (seq, host_send_ts_millis, is_config, payload) = match decode_parts(datagram) {
        Ok(parts) => parts,
        Err(error) => return verdict(&error),
    };
    let header = u16::try_from(AudioChannelMessage::HEADER_SIZE).unwrap_or(u16::MAX);
    let flat = if is_config {
        let (format, sample_rate, channels, cookie) = match decode_config_parts(payload) {
            Ok(parts) => parts,
            Err(error) => return verdict(&error),
        };
        SlopDeskAudioMessage {
            seq,
            host_send_ts_millis,
            sample_rate,
            // The cookie trails the config payload's own eight-byte head, which itself trails the
            // message header — so its offset is the sum, and the caller slices once.
            span_offset: header.saturating_add(CONFIG_HEAD_SIZE),
            span_length: u16::try_from(cookie.len()).unwrap_or(u16::MAX),
            is_config: true,
            format: format.raw_value(),
            channels,
        }
    } else {
        SlopDeskAudioMessage {
            seq,
            host_send_ts_millis,
            span_offset: header,
            span_length: u16::try_from(payload.len()).unwrap_or(u16::MAX),
            ..SlopDeskAudioMessage::default()
        }
    };
    if out.is_null() {
        return METADATA_DECODE_OK;
    }
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned value.
    unsafe { out.write(flat) };
    METADATA_DECODE_OK
}

/// Serialises one audio datagram.
///
/// `span` is the frame payload for a frame message and the AAC cookie for a config one. Returns
/// bytes NEEDED under §4, and 0 for a config naming a format the wire does not admit.
///
/// # Safety
/// `span` must be null or point to `span_len` readable bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_audio_encode(
    message: SlopDeskAudioMessage,
    span: *const c_uchar,
    span_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(span, span_len) };
    let rebuilt = if message.is_config {
        let Some(format) = AudioWireFormat::from_raw(message.format) else {
            return 0;
        };
        AudioChannelMessage::Config {
            seq: message.seq,
            host_send_ts_millis: message.host_send_ts_millis,
            config: AudioStreamConfig::new(format, message.sample_rate, message.channels, bytes.to_vec()),
        }
    } else {
        AudioChannelMessage::Frame {
            seq: message.seq,
            host_send_ts_millis: message.host_send_ts_millis,
            payload: bytes.to_vec(),
        }
    };
    let datagram = rebuilt.encode();
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&datagram, out, cap) }
}

/// The config payload's fixed head: format, sample rate, channels, cookie length.
const CONFIG_HEAD_SIZE: u16 = 8;

/// The audio wire's declared numbers. `index` selects — 0 the header size, 1 the payload cap, 2 the
/// config payload's head.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_audio_constant(index: u8) -> usize {
    match index {
        0 => AudioChannelMessage::HEADER_SIZE,
        1 => AudioChannelMessage::MAX_PAYLOAD_BYTES,
        2 => CONFIG_HEAD_SIZE as usize,
        _ => 0,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "the tests call the C entry points, and a panic in a test is the failure report"
)]
mod tests {
    use super::{
        METADATA_DECODE_MALFORMED, METADATA_DECODE_OK, METADATA_DECODE_TRUNCATED, SlopDeskAudioMessage,
        SlopDeskSwipeNavStatus, SlopDeskWindowGeometry, slopdesk_audio_constant, slopdesk_audio_decode,
        slopdesk_audio_encode, slopdesk_swipe_nav_allows_chip, slopdesk_swipe_nav_constant,
        slopdesk_swipe_nav_status_decode, slopdesk_swipe_nav_status_encode,
        slopdesk_window_geometry_constant, slopdesk_window_geometry_decode, slopdesk_window_geometry_encode,
    };

    fn geometry_wire(message: SlopDeskWindowGeometry, title: &[u8]) -> Vec<u8> {
        let needed = unsafe {
            slopdesk_window_geometry_encode(message, title.as_ptr(), title.len(), core::ptr::null_mut(), 0)
        };
        let mut wire = vec![0_u8; needed];
        let written = unsafe {
            slopdesk_window_geometry_encode(
                message,
                title.as_ptr(),
                title.len(),
                wire.as_mut_ptr(),
                wire.len(),
            )
        };
        assert_eq!(written, needed);
        wire
    }

    #[test]
    fn bounds_carry_all_four_numbers_back() {
        let message = SlopDeskWindowGeometry {
            x: 10.5,
            y: -20.25,
            width: 800.0,
            height: 600.0,
            message_type: 3,
            title_offset: 0,
        };
        let wire = geometry_wire(message, &[]);
        let mut back = SlopDeskWindowGeometry::default();
        let ok = unsafe { slopdesk_window_geometry_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(ok, METADATA_DECODE_OK);
        assert_eq!(back, message);
    }

    #[test]
    fn a_title_is_left_at_the_offset_the_codec_reports() {
        let message = SlopDeskWindowGeometry {
            message_type: 4,
            ..SlopDeskWindowGeometry::default()
        };
        let wire = geometry_wire(message, b"wnd");
        let mut back = SlopDeskWindowGeometry::default();
        let ok = unsafe { slopdesk_window_geometry_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(ok, METADATA_DECODE_OK);
        assert_eq!(back.title_offset, slopdesk_window_geometry_constant(0));
        assert_eq!(&wire[usize::from(back.title_offset)..], b"wnd");
    }

    #[test]
    fn a_non_finite_coordinate_never_reaches_a_layer() {
        let message = SlopDeskWindowGeometry {
            x: f64::INFINITY,
            message_type: 1,
            ..SlopDeskWindowGeometry::default()
        };
        let wire = geometry_wire(message, &[]);
        let mut back = SlopDeskWindowGeometry::default();
        let hostile = unsafe { slopdesk_window_geometry_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(hostile, METADATA_DECODE_MALFORMED);
        let short = unsafe { slopdesk_window_geometry_decode(wire.as_ptr(), 4, &raw mut back) };
        assert_eq!(short, METADATA_DECODE_TRUNCATED);
    }

    #[test]
    fn the_swipe_status_round_trips_its_six_bytes() {
        let status = SlopDeskSwipeNavStatus {
            fire_travel: 120,
            eligible: true,
            slow_tier: false,
            can_go_back: true,
            can_go_forward: false,
            history_known: true,
        };
        let mut wire = [0_u8; 6];
        let written = unsafe { slopdesk_swipe_nav_status_encode(status, wire.as_mut_ptr(), wire.len()) };
        assert_eq!(written, slopdesk_swipe_nav_constant(1));
        assert_eq!(usize::from(wire[0]), slopdesk_swipe_nav_constant(0));
        let mut back = SlopDeskSwipeNavStatus::default();
        let ok = unsafe { slopdesk_swipe_nav_status_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(ok, METADATA_DECODE_OK);
        assert_eq!(back, status);
        assert!(slopdesk_swipe_nav_allows_chip(status, 0));
        assert!(!slopdesk_swipe_nav_allows_chip(status, 1));
    }

    #[test]
    fn an_unknown_history_state_fails_open_in_both_directions() {
        let status = SlopDeskSwipeNavStatus {
            history_known: false,
            ..SlopDeskSwipeNavStatus::default()
        };
        assert!(slopdesk_swipe_nav_allows_chip(status, 0));
        assert!(slopdesk_swipe_nav_allows_chip(status, 1));
    }

    #[test]
    fn an_audio_frame_reports_where_its_payload_sits() {
        let payload = [3_u8; 40];
        let message = SlopDeskAudioMessage {
            seq: 9,
            host_send_ts_millis: 1234,
            ..SlopDeskAudioMessage::default()
        };
        let needed = unsafe {
            slopdesk_audio_encode(message, payload.as_ptr(), payload.len(), core::ptr::null_mut(), 0)
        };
        let mut wire = vec![0_u8; needed];
        let written = unsafe {
            slopdesk_audio_encode(
                message,
                payload.as_ptr(),
                payload.len(),
                wire.as_mut_ptr(),
                wire.len(),
            )
        };
        assert_eq!(written, slopdesk_audio_constant(0) + payload.len());
        let mut back = SlopDeskAudioMessage::default();
        let ok = unsafe { slopdesk_audio_decode(wire.as_ptr(), written, &raw mut back) };
        assert_eq!(ok, METADATA_DECODE_OK);
        assert_eq!(back.seq, 9);
        assert_eq!(back.host_send_ts_millis, 1234);
        assert!(!back.is_config);
        assert_eq!(usize::from(back.span_offset), slopdesk_audio_constant(0));
        assert_eq!(usize::from(back.span_length), payload.len());
        assert_eq!(&wire[usize::from(back.span_offset)..], &payload);
    }

    #[test]
    fn an_audio_config_reports_where_its_cookie_sits() {
        let cookie = [0xAB_u8; 5];
        let message = SlopDeskAudioMessage {
            seq: 1,
            sample_rate: 48_000,
            is_config: true,
            format: 1,
            channels: 2,
            ..SlopDeskAudioMessage::default()
        };
        let needed = unsafe {
            slopdesk_audio_encode(message, cookie.as_ptr(), cookie.len(), core::ptr::null_mut(), 0)
        };
        let mut wire = vec![0_u8; needed];
        let written = unsafe {
            slopdesk_audio_encode(
                message,
                cookie.as_ptr(),
                cookie.len(),
                wire.as_mut_ptr(),
                wire.len(),
            )
        };
        assert_eq!(written, needed);
        let mut back = SlopDeskAudioMessage::default();
        let ok = unsafe { slopdesk_audio_decode(wire.as_ptr(), written, &raw mut back) };
        assert_eq!(ok, METADATA_DECODE_OK);
        assert!(back.is_config);
        assert_eq!(back.sample_rate, 48_000);
        assert_eq!(back.channels, 2);
        assert_eq!(back.format, 1);
        assert_eq!(
            usize::from(back.span_offset),
            slopdesk_audio_constant(0) + slopdesk_audio_constant(2)
        );
        assert_eq!(&wire[usize::from(back.span_offset)..], &cookie);
    }

    #[test]
    fn a_payload_length_past_the_end_is_refused_rather_than_allocated() {
        let mut wire = vec![0_u8; slopdesk_audio_constant(0)];
        wire[9] = 0xFF;
        wire[10] = 0xFF;
        let mut back = SlopDeskAudioMessage::default();
        let refused = unsafe { slopdesk_audio_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_ne!(refused, METADATA_DECODE_OK);
        assert_eq!(back, SlopDeskAudioMessage::default());
    }
}
