//! The UDP mux prefix — `Sources/SlopDeskVideoProtocol/Mux/VideoMuxHeaderCodec.swift`.
//!
//! Four big-endian bytes in front of a datagram, saying which logical lane it belongs to. Every
//! outgoing datagram on the video flow goes through it and every incoming one is split by it, on
//! both the host and the client, which makes it the cheapest possible thing to get wrong twice.
//!
//! ## Framing writes into the caller's buffer
//! The prefix is four bytes and the payload is the rest, so an `encode` that allocated here and
//! copied back would copy the whole datagram a second time to prepend four bytes. `encode_into`
//! writes the answer where the caller wants it, and the caller knows the length up front — there is
//! never a sizing call.
//!
//! ## Splitting answers an OFFSET
//! Decoding hands back a channel id and where the payload starts, never the payload: the caller is
//! holding the datagram it just passed in. Zero means the datagram was too short to be split, which
//! is unambiguous because a payload can never start at offset zero.

use core::ffi::c_uchar;

use slopdesk_video::fragment::Flags;
use slopdesk_video::mux_header::{self, CHANNEL_ID_LENGTH, MuxFrameFragmentHeader};

use crate::borrow;

/// A decoded muxed fragment header, laid out for Swift to read straight through.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskMuxFragmentHeader {
    /// The logical lane this fragment belongs to.
    pub channel_id: u32,
    /// Monotonic per-datagram sequence number.
    pub stream_seq: u32,
    /// Groups the fragments of one encoded frame.
    pub frame_id: u32,
    /// This fragment's 0-based index within the frame.
    pub frag_index: u16,
    /// Total fragments in the frame.
    pub frag_count: u16,
    /// The declared payload length.
    pub payload_length: u16,
    /// The wire flag bits, shared verbatim with the plain fragment header.
    pub flags: u8,
    /// Where the payload starts in the datagram the header was read from.
    pub payload_offset: u8,
}

/// The prefix, and optionally a one-byte tag, written in front of `payload`.
///
/// `has_tag` selects between the bare lane prefix and the media-socket shape. It is a flag rather
/// than two entry points because the two differ by one byte in one place, and a caller choosing
/// between two symbols would be choosing between two chances to pick the wrong one.
///
/// Returns the bytes the framing needs; `cap` short of that leaves `out` untouched.
///
/// # Safety
/// `payload` must be null or point to `payload_len` readable bytes, and `out` must be null or point
/// to `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_encode(
    channel_id: u32,
    has_tag: bool,
    tag: u8,
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(payload, payload_len) };
    let tag = has_tag.then_some(tag);
    if out.is_null() {
        return mux_header::encode_into(channel_id, tag, bytes, &mut []);
    }
    // SAFETY: the caller's obligation on `out` — `cap` writable bytes, which Swift discharges with
    // `withUnsafeMutableBytes` over a `Data` it just sized.
    let buffer = unsafe { core::slice::from_raw_parts_mut(out, cap) };
    mux_header::encode_into(channel_id, tag, bytes, buffer)
}

/// Splits a muxed datagram, answering where its payload starts and writing the lane id out.
///
/// Answers 0 — writing nothing — for a datagram too short to carry the prefix.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `channel_id` must be null or point to
/// one writable, aligned `u32`, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decode(
    bytes: *const c_uchar,
    len: usize,
    channel_id: *mut u32,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    let Ok((lane, _payload)) = mux_header::decode(datagram) else {
        return 0;
    };
    if !channel_id.is_null() {
        // SAFETY: non-null and, by the caller's obligation, one writable, aligned `u32`.
        unsafe { channel_id.write(lane) };
    }
    CHANNEL_ID_LENGTH
}

/// The muxed fragment header and its payload, written into the caller's buffer.
///
/// The declared payload length comes from the payload, never from an argument: two fields that
/// could disagree on the wire are one field here.
///
/// # Safety
/// `payload` must be null or point to `payload_len` readable bytes, and `out` must be null or point
/// to `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_fragment_encode(
    channel_id: u32,
    stream_seq: u32,
    frame_id: u32,
    frag_index: u16,
    frag_count: u16,
    flags: u8,
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(payload, payload_len) };
    let header = MuxFrameFragmentHeader::new(
        channel_id,
        stream_seq,
        frame_id,
        frag_index,
        frag_count,
        Flags::from_bits(flags),
        u16::try_from(bytes.len()).unwrap_or(u16::MAX),
    );
    if out.is_null() {
        return header.encode_into(bytes, &mut []);
    }
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    let buffer = unsafe { core::slice::from_raw_parts_mut(out, cap) };
    header.encode_into(bytes, buffer)
}

/// Parses one muxed datagram's header.
///
/// Answers `false` — writing nothing — for a datagram too short to hold the header, or one whose
/// declared payload runs past its end.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskMuxFragmentHeader`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_fragment_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskMuxFragmentHeader,
) -> bool {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    // The header only: the payload stays in the datagram the caller is still holding.
    let Ok((parsed, _payload)) = MuxFrameFragmentHeader::decode(datagram) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    let header = SlopDeskMuxFragmentHeader {
        channel_id: parsed.channel_id,
        stream_seq: parsed.stream_seq,
        frame_id: parsed.frame_id,
        frag_index: parsed.frag_index,
        frag_count: parsed.frag_count,
        payload_length: parsed.payload_length,
        flags: parsed.flags.bits(),
        payload_offset: u8::try_from(MuxFrameFragmentHeader::SIZE).unwrap_or(u8::MAX),
    };
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned header.
    unsafe { out.write(header) };
    true
}

/// The sizes a caller cannot derive from a header it has not decoded yet.
///
/// `index` selects: 0 the channel-id prefix, 1 the muxed header, 2 the largest payload one muxed
/// fragment may carry. An index with no constant behind it answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_mux_constant(index: u8) -> usize {
    match index {
        0 => CHANNEL_ID_LENGTH,
        1 => MuxFrameFragmentHeader::SIZE,
        2 => MuxFrameFragmentHeader::MAX_PAYLOAD_SIZE,
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
        SlopDeskMuxFragmentHeader, slopdesk_mux_constant, slopdesk_mux_decode, slopdesk_mux_encode,
        slopdesk_mux_fragment_decode, slopdesk_mux_fragment_encode,
    };

    #[test]
    fn the_bare_prefix_fronts_the_payload_and_splits_back_off_it() {
        let payload = [9_u8, 8, 7];
        let mut out = [0_u8; 7];
        let written = unsafe {
            slopdesk_mux_encode(
                0x0102_0304,
                false,
                0,
                payload.as_ptr(),
                payload.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 7);
        assert_eq!(out, [1, 2, 3, 4, 9, 8, 7]);
        let mut lane = 0_u32;
        let offset = unsafe { slopdesk_mux_decode(out.as_ptr(), out.len(), &raw mut lane) };
        assert_eq!(offset, 4);
        assert_eq!(lane, 0x0102_0304);
        assert_eq!(&out[offset..], &payload);
    }

    #[test]
    fn the_media_shape_carries_its_tag_between_the_lane_and_the_payload() {
        let payload = [0xAA_u8];
        let mut out = [0_u8; 6];
        let written = unsafe {
            slopdesk_mux_encode(
                7,
                true,
                0x2A,
                payload.as_ptr(),
                payload.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, 6);
        assert_eq!(out, [0, 0, 0, 7, 0x2A, 0xAA]);
    }

    #[test]
    fn a_short_buffer_is_left_untouched_and_asks_again() {
        let payload = [1_u8, 2, 3];
        let mut out = [0_u8; 4];
        let needed = unsafe {
            slopdesk_mux_encode(
                1,
                false,
                0,
                payload.as_ptr(),
                payload.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(needed, 7);
        assert_eq!(out, [0; 4]);
        let sized = unsafe {
            slopdesk_mux_encode(
                1,
                false,
                0,
                payload.as_ptr(),
                payload.len(),
                core::ptr::null_mut(),
                0,
            )
        };
        assert_eq!(sized, 7);
    }

    #[test]
    fn a_datagram_too_short_to_carry_a_lane_is_refused() {
        let stub = [1_u8, 2, 3];
        let mut lane = 0_u32;
        let offset = unsafe { slopdesk_mux_decode(stub.as_ptr(), stub.len(), &raw mut lane) };
        assert_eq!(offset, 0);
        assert_eq!(lane, 0);
    }

    #[test]
    fn the_muxed_fragment_header_round_trips_through_the_boundary() {
        let payload = [4_u8; 12];
        let mut out = [0_u8; 64];
        let written = unsafe {
            slopdesk_mux_fragment_encode(
                0xDEAD_BEEF,
                5,
                6,
                1,
                4,
                0x03,
                payload.as_ptr(),
                payload.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!(written, slopdesk_mux_constant(1) + payload.len());
        let mut header = SlopDeskMuxFragmentHeader::default();
        let ok = unsafe { slopdesk_mux_fragment_decode(out.as_ptr(), written, &raw mut header) };
        assert!(ok);
        assert_eq!(header.channel_id, 0xDEAD_BEEF);
        assert_eq!(header.stream_seq, 5);
        assert_eq!(header.frame_id, 6);
        assert_eq!(header.frag_index, 1);
        assert_eq!(header.frag_count, 4);
        assert_eq!(header.flags, 0x03);
        assert_eq!(header.payload_length, 12);
        assert_eq!(usize::from(header.payload_offset), slopdesk_mux_constant(1));
        assert_eq!(&out[usize::from(header.payload_offset)..written], &payload);
    }

    #[test]
    fn a_muxed_fragment_promising_more_payload_than_it_carries_is_refused() {
        let mut datagram = [0_u8; 19 + 4];
        datagram[17] = 0xFF;
        datagram[18] = 0xFF;
        let mut header = SlopDeskMuxFragmentHeader::default();
        let refused =
            unsafe { slopdesk_mux_fragment_decode(datagram.as_ptr(), datagram.len(), &raw mut header) };
        assert!(!refused);
        assert_eq!(header, SlopDeskMuxFragmentHeader::default());
    }

    #[test]
    fn the_constants_are_the_ones_the_layout_declares() {
        assert_eq!(slopdesk_mux_constant(0), 4);
        assert_eq!(slopdesk_mux_constant(1), 19);
        assert!(slopdesk_mux_constant(2) > 1000);
        assert_eq!(slopdesk_mux_constant(9), 0);
    }
}
