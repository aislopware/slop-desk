//! The cursor side-channel and the AVCC NAL-unit split — the last two small codecs the video path
//! spelled twice.
//!
//! They share a file for the same reason `metadata_wire` bundles three: neither is big enough to
//! earn one, and both answer SPANS into the caller's buffer rather than copies. Beyond that they
//! have nothing in common, so read them as two.
//!
//! ## The cursor socket
//!
//! The host strips the real cursor out of the captured video and streams its position over a small
//! separate socket, so pointer latency is RTT and nothing else. That message fires at up to 120 Hz
//! and its coordinates are multiplied through the client's aspect-fit transform into a `CALayer`
//! frame — a NaN off the wire is an uncatchable `CALayerInvalidGeometry` and a dead client, which
//! is why every coordinate is finite-checked at decode and why that check exists once.
//!
//! The shape bitmap crosses as an OFFSET: it is a PNG the caller is already holding. The third
//! message on this socket, the swipe-nav status, has its own entry point in
//! [`crate::metadata_wire`] because it is a different wire with different stakes.
//!
//! ## The AVCC split
//!
//! A length-prefixed NAL-unit buffer is parsed defensively: a prefix claiming more bytes than
//! remain ends the iteration rather than failing it, because a truncated tail means "no more whole
//! units" and never a crash. Splitting answers `(offset, length)` pairs for the same reason the
//! bitmap does — an IDR's units are most of a frame, and the caller passed that frame in.

use core::ffi::c_uchar;

use slopdesk_video::cursor::{CursorShapeMessage, CursorUpdate};
use slopdesk_video::error::VideoProtocolError;
use slopdesk_video::geometry::{VideoPoint, VideoSize};
use slopdesk_video::{blob_list, nal_unit};

use crate::{borrow, deliver, truncating_u32};

/// The datagram parsed.
pub const CURSOR_DECODE_OK: u32 = 0;
/// The datagram ended mid-field.
pub const CURSOR_DECODE_TRUNCATED: u32 = 1;
/// The datagram was well-sized and unacceptable: another type, or a non-finite coordinate.
pub const CURSOR_DECODE_MALFORMED: u32 = 2;

/// Which verdict a decode failure earns.
const fn verdict(error: &VideoProtocolError) -> u32 {
    match *error {
        VideoProtocolError::Truncated => CURSOR_DECODE_TRUNCATED,
        VideoProtocolError::Malformed(_) => CURSOR_DECODE_MALFORMED,
    }
}

/// One cursor-channel message, flat. `message_type` says which fields carry meaning: 1 a position
/// update, 2 a shape bitmap.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SlopDeskCursorMessage {
    /// Cursor position in host-window space, points. Update only.
    pub x: f64,
    /// Cursor position y.
    pub y: f64,
    /// The shape's hotspot offset, points. Both grammars carry it.
    pub hotspot_x: f64,
    /// The hotspot's y.
    pub hotspot_y: f64,
    /// The shape's declared width in points — informational, since the bitmap is self-describing.
    /// Shape only, and an `f64` because rounding it down to the wire's `u16` is the codec's rule,
    /// not this boundary's.
    pub width: f64,
    /// The shape's declared height in points. Shape only.
    pub height: f64,
    /// Where the PNG bitmap starts in the datagram. Shape decode only.
    pub bitmap_offset: u32,
    /// How many bytes of it there are.
    pub bitmap_length: u32,
    /// The shape this message wears, or describes.
    pub shape_id: u16,
    /// Which wire type this is.
    pub message_type: u8,
    /// Whether the cursor is currently visible over the window. Update only.
    pub visible: bool,
}

/// Parses one cursor-channel datagram — a position update or a shape bitmap.
///
/// The type byte is checked, not assumed: three message kinds share this socket, and reading one as
/// another would drive the overlay from the wrong bytes.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskCursorMessage`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cursor_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskCursorMessage,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let flat = match datagram.first().copied() {
        Some(CursorUpdate::MESSAGE_TYPE) => {
            match CursorUpdate::decode(datagram) {
                Ok(update) => {
                    SlopDeskCursorMessage {
                        x: update.position.x,
                        y: update.position.y,
                        hotspot_x: update.hotspot.x,
                        hotspot_y: update.hotspot.y,
                        shape_id: update.shape_id,
                        message_type: CursorUpdate::MESSAGE_TYPE,
                        visible: update.visible,
                        ..SlopDeskCursorMessage::default()
                    }
                },
                Err(error) => return verdict(&error),
            }
        },
        Some(CursorShapeMessage::MESSAGE_TYPE) => {
            match CursorShapeMessage::decode_parts(datagram) {
                Ok((shape_id, size, hotspot, bitmap)) => {
                    SlopDeskCursorMessage {
                        hotspot_x: hotspot.x,
                        hotspot_y: hotspot.y,
                        width: size.width,
                        height: size.height,
                        // The bitmap stays in the caller's datagram, immediately past the fixed header.
                        bitmap_offset: truncating_u32(CursorShapeMessage::HEADER_SIZE),
                        bitmap_length: truncating_u32(bitmap.len()),
                        shape_id,
                        message_type: CursorShapeMessage::MESSAGE_TYPE,
                        ..SlopDeskCursorMessage::default()
                    }
                },
                Err(error) => return verdict(&error),
            }
        },
        Some(_) => return CURSOR_DECODE_MALFORMED,
        None => return CURSOR_DECODE_TRUNCATED,
    };
    if out.is_null() {
        return CURSOR_DECODE_OK;
    }
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned value.
    unsafe { out.write(flat) };
    CURSOR_DECODE_OK
}

/// Serialises one cursor-channel message; the shape arm takes its PNG through `bitmap`. Returns
/// bytes NEEDED under §4, and 0 for a type no arm answers to.
///
/// # Safety
/// `bitmap` must be null or point to `bitmap_len` readable bytes, and `out` must be null or point
/// to `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_cursor_encode(
    message: SlopDeskCursorMessage,
    bitmap: *const c_uchar,
    bitmap_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let hotspot = VideoPoint::new(message.hotspot_x, message.hotspot_y);
    let datagram = match message.message_type {
        CursorUpdate::MESSAGE_TYPE => {
            CursorUpdate::new(
                VideoPoint::new(message.x, message.y),
                message.shape_id,
                hotspot,
                message.visible,
            )
            .encode()
        },
        CursorShapeMessage::MESSAGE_TYPE => {
            // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
            let bytes = unsafe { borrow(bitmap, bitmap_len) };
            CursorShapeMessage::new(
                message.shape_id,
                VideoSize::new(message.width, message.height),
                hotspot,
                bytes.to_vec(),
            )
            .encode()
        },
        _ => return 0,
    };
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&datagram, out, cap) }
}

/// The cursor wire's declared numbers. `index` selects — 0 the update's type byte, 1 its encoded
/// size, 2 the shape's type byte, 3 the shape's fixed header.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_cursor_constant(index: u8) -> usize {
    match index {
        0 => CursorUpdate::MESSAGE_TYPE as usize,
        1 => CursorUpdate::ENCODED_SIZE,
        2 => CursorShapeMessage::MESSAGE_TYPE as usize,
        3 => CursorShapeMessage::HEADER_SIZE,
        _ => 0,
    }
}

/// Where one NAL unit sits inside the AVCC buffer it was split out of.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskNalSpan {
    /// Byte offset of the unit's first payload byte — past its length prefix.
    pub offset: u32,
    /// The unit's length in bytes.
    pub length: u32,
}

/// Splits an AVCC buffer into its NAL units, answering where each one sits.
///
/// Returns how many units the buffer holds, under §4's convention: more than `cap` means nothing
/// was written and the caller should ask again.
///
/// # Safety
/// `avcc` must be null or point to `len` readable bytes, and `out` must be null or point to `cap`
/// writable, aligned [`SlopDeskNalSpan`]s, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_nal_split(
    avcc: *const c_uchar,
    len: usize,
    out: *mut SlopDeskNalSpan,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let buffer = unsafe { borrow(avcc, len) };
    let units = nal_unit::split_ranges(buffer);
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

/// Re-prefixes a run of NAL units back into one AVCC buffer.
///
/// The units arrive as a §4d blob list, the shape the FEC boundary already carries, because a run
/// of separately-allocated payloads cannot cross as one span any other way. A list that does not
/// parse, or one carrying an absence, answers 0: absence has no meaning here — a missing NAL unit
/// is a frame that cannot be built, not a frame with a hole.
///
/// # Safety
/// `list` must be null or point to `list_len` readable bytes, and `out` must be null or point to
/// `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_nal_join(
    list: *const c_uchar,
    list_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBufferPointer`.
    let packed = unsafe { borrow(list, list_len) };
    let Some(blobs) = blob_list::decode(packed) else {
        return 0;
    };
    let mut units = Vec::with_capacity(blobs.len());
    for blob in blobs {
        let Some(unit) = blob else { return 0 };
        units.push(unit);
    }
    let avcc = nal_unit::join(&units);
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&avcc, out, cap) }
}

/// The AVCC wire's declared numbers. `index` selects — 0 the length-prefix width.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_nal_constant(index: u8) -> usize {
    match index {
        0 => nal_unit::LENGTH_PREFIX_SIZE,
        _ => 0,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    clippy::float_cmp,
    reason = "the tests call the C entry points, and a panic in a test is the failure report"
)]
mod tests {
    use slopdesk_video::blob_list;

    use super::{
        CURSOR_DECODE_MALFORMED, CURSOR_DECODE_OK, CURSOR_DECODE_TRUNCATED, SlopDeskCursorMessage,
        SlopDeskNalSpan, slopdesk_cursor_constant, slopdesk_cursor_decode, slopdesk_cursor_encode,
        slopdesk_nal_constant, slopdesk_nal_join, slopdesk_nal_split,
    };

    fn cursor_wire(message: SlopDeskCursorMessage, bitmap: &[u8]) -> Vec<u8> {
        let needed = unsafe {
            slopdesk_cursor_encode(message, bitmap.as_ptr(), bitmap.len(), core::ptr::null_mut(), 0)
        };
        let mut wire = vec![0_u8; needed];
        let written = unsafe {
            slopdesk_cursor_encode(
                message,
                bitmap.as_ptr(),
                bitmap.len(),
                wire.as_mut_ptr(),
                wire.len(),
            )
        };
        assert_eq!(written, needed);
        wire
    }

    fn nal_join(units: &[Option<&[u8]>]) -> Vec<u8> {
        let packed = blob_list::encode(units);
        let needed = unsafe { slopdesk_nal_join(packed.as_ptr(), packed.len(), core::ptr::null_mut(), 0) };
        let mut avcc = vec![0_u8; needed];
        let written =
            unsafe { slopdesk_nal_join(packed.as_ptr(), packed.len(), avcc.as_mut_ptr(), avcc.len()) };
        assert_eq!(written, needed);
        avcc
    }

    #[test]
    fn a_position_update_round_trips_its_thirty_six_bytes() {
        let update = SlopDeskCursorMessage {
            x: 100.5,
            y: 200.25,
            hotspot_x: 4.0,
            hotspot_y: 8.0,
            shape_id: 77,
            message_type: 1,
            visible: true,
            ..SlopDeskCursorMessage::default()
        };
        let wire = cursor_wire(update, &[]);
        assert_eq!(wire.len(), slopdesk_cursor_constant(1));
        let mut back = SlopDeskCursorMessage::default();
        let ok = unsafe { slopdesk_cursor_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(ok, CURSOR_DECODE_OK);
        assert_eq!(back, update);
    }

    #[test]
    fn a_shape_reports_where_its_bitmap_sits_rather_than_copying_it() {
        let bitmap = [0x89_u8, b'P', b'N', b'G', 1, 2, 3];
        let shape = SlopDeskCursorMessage {
            hotspot_x: 1.0,
            hotspot_y: 2.0,
            width: 32.0,
            height: 32.0,
            shape_id: 5,
            message_type: 2,
            ..SlopDeskCursorMessage::default()
        };
        let wire = cursor_wire(shape, &bitmap);
        assert_eq!(wire.len(), slopdesk_cursor_constant(3) + bitmap.len());
        let mut back = SlopDeskCursorMessage::default();
        let ok = unsafe { slopdesk_cursor_decode(wire.as_ptr(), wire.len(), &raw mut back) };
        assert_eq!(ok, CURSOR_DECODE_OK);
        assert_eq!(back.bitmap_offset as usize, slopdesk_cursor_constant(3));
        assert_eq!(back.bitmap_length as usize, bitmap.len());
        assert_eq!(&wire[back.bitmap_offset as usize..], &bitmap);
        assert_eq!(back.width, 32.0);
        assert_eq!(back.shape_id, 5);
    }

    #[test]
    fn a_non_finite_coordinate_and_a_foreign_type_are_both_refused() {
        let hostile = SlopDeskCursorMessage {
            x: f64::NAN,
            message_type: 1,
            ..SlopDeskCursorMessage::default()
        };
        let wire = cursor_wire(hostile, &[]);
        let mut back = SlopDeskCursorMessage::default();
        assert_eq!(
            unsafe { slopdesk_cursor_decode(wire.as_ptr(), wire.len(), &raw mut back) },
            CURSOR_DECODE_MALFORMED
        );
        let foreign = [9_u8, 0, 0];
        assert_eq!(
            unsafe { slopdesk_cursor_decode(foreign.as_ptr(), foreign.len(), &raw mut back) },
            CURSOR_DECODE_MALFORMED
        );
        assert_eq!(
            unsafe { slopdesk_cursor_decode(core::ptr::null(), 0, &raw mut back) },
            CURSOR_DECODE_TRUNCATED
        );
    }

    #[test]
    fn an_unencodable_message_type_answers_nothing_rather_than_guessing() {
        let stranger = SlopDeskCursorMessage {
            message_type: 3,
            ..SlopDeskCursorMessage::default()
        };
        let refused =
            unsafe { slopdesk_cursor_encode(stranger, core::ptr::null(), 0, core::ptr::null_mut(), 0) };
        assert_eq!(refused, 0);
    }

    #[test]
    fn the_avcc_split_answers_offsets_into_the_caller_s_buffer() {
        let avcc = nal_join(&[Some(&[1, 2, 3]), Some(&[4, 5])]);
        assert_eq!(avcc.len(), 2 * slopdesk_nal_constant(0) + 5);

        let count = unsafe { slopdesk_nal_split(avcc.as_ptr(), avcc.len(), core::ptr::null_mut(), 0) };
        assert_eq!(count, 2);
        let mut spans = vec![SlopDeskNalSpan::default(); count];
        let filled =
            unsafe { slopdesk_nal_split(avcc.as_ptr(), avcc.len(), spans.as_mut_ptr(), spans.len()) };
        assert_eq!(filled, 2);
        assert_eq!(spans[0].offset as usize, slopdesk_nal_constant(0));
        assert_eq!(spans[0].length, 3);
        assert_eq!(&avcc[spans[1].offset as usize..][..spans[1].length as usize], &[
            4, 5
        ]);
    }

    #[test]
    fn a_join_over_an_absence_refuses_rather_than_building_a_short_frame() {
        let packed = blob_list::encode(&[Some(&[1, 2][..]), None]);
        let refused = unsafe { slopdesk_nal_join(packed.as_ptr(), packed.len(), core::ptr::null_mut(), 0) };
        assert_eq!(refused, 0);
    }

    #[test]
    fn a_truncated_tail_ends_the_split_instead_of_failing_it() {
        let mut avcc = vec![0_u8, 0, 0, 2, 7, 7];
        avcc.extend_from_slice(&[0, 0, 0, 9, 1]);
        let count = unsafe { slopdesk_nal_split(avcc.as_ptr(), avcc.len(), core::ptr::null_mut(), 0) };
        assert_eq!(count, 1);
    }
}
