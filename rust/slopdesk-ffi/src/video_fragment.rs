//! The datagram codec: the 19-byte header and its payload, in both directions.
//!
//! It lives in its own module rather than beside the reassembler because it is not the
//! reassembler's. The host's send path writes datagrams, the client's router reads one before it
//! knows whether it will reassemble anything at all, and the golden-vector generator does both. One
//! codec, and every caller on either side of the boundary reaches the same one.
//!
//! ## Why the payload does not cross
//! Decoding answers a header and an OFFSET, not a payload. The caller already holds the datagram —
//! it just handed the bytes over — so copying the payload back would copy every byte of every frame
//! a second time for nothing. Swift slices its own buffer at the offset this side reports.

use core::ffi::c_uchar;

use slopdesk_video::fragment::{Flags, FrameFragmentHeader, encode_datagram};

use crate::{borrow, deliver};

/// A decoded header, laid out for Swift to read straight through.
///
/// `payload_offset` is here so no caller has to spell the header's own size: the wire layout is
/// this crate's, and a second `19` on the other side would be a second place to get it wrong.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskVideoFragmentHeader {
    /// Monotonic per-datagram sequence number.
    pub stream_seq: u32,
    /// Groups the fragments of one encoded frame.
    pub frame_id: u32,
    /// Host-monotonic ms since the host session start; 0 = unstamped.
    pub host_send_ts_millis: u32,
    /// This fragment's 0-based index within the frame.
    pub frag_index: u16,
    /// Total fragments in the frame, data and parity together.
    pub frag_count: u16,
    /// The declared payload length.
    pub payload_length: u16,
    /// The wire flag bits.
    pub flags: u8,
    /// Where the payload starts in the datagram the header was read from.
    pub payload_offset: u8,
}

/// Parses one datagram's header.
///
/// Answers `false` — writing nothing — for a datagram too short to hold a header, or one whose
/// declared payload runs past its end. That is what a corrupt packet on an unauthenticated socket
/// looks like, and it is the reason this guard exists once instead of on both sides.
///
/// # Safety
/// `bytes` must be null or point to `len` readable bytes, and `out` must be null or point to one
/// writable, aligned [`SlopDeskVideoFragmentHeader`], both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_fragment_decode(
    bytes: *const c_uchar,
    len: usize,
    out: *mut SlopDeskVideoFragmentHeader,
) -> bool {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let datagram = unsafe { borrow(bytes, len) };
    // The header only: the payload stays in the caller's datagram, which the caller still holds.
    let Ok((parsed, _payload)) = FrameFragmentHeader::decode(datagram) else {
        return false;
    };
    if out.is_null() {
        return true;
    }
    let header = SlopDeskVideoFragmentHeader {
        stream_seq: parsed.stream_seq,
        frame_id: parsed.frame_id,
        host_send_ts_millis: parsed.host_send_ts_millis,
        frag_index: parsed.frag_index,
        frag_count: parsed.frag_count,
        payload_length: parsed.payload_length,
        flags: parsed.flags.bits(),
        payload_offset: u8::try_from(slopdesk_video::fragment::HEADER_SIZE).unwrap_or(u8::MAX),
    };
    // SAFETY: non-null and, by the caller's obligation, one writable, aligned header — Swift passes
    // the address of a local `SlopDeskVideoFragmentHeader`.
    unsafe { out.write(header) };
    true
}

/// Serialises one datagram: the header's fields, then the payload.
///
/// The declared length comes from the PAYLOAD, not from a `payload_length` argument, which is why
/// there is no such argument: the two cannot disagree on the wire if only one of them exists.
///
/// # Safety
/// `payload` must be null or point to `payload_len` readable bytes, and `out` must be null or point
/// to `cap` writable bytes, both for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_fragment_encode(
    stream_seq: u32,
    frame_id: u32,
    frag_index: u16,
    frag_count: u16,
    flags: u8,
    host_send_ts_millis: u32,
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`.
    let bytes = unsafe { borrow(payload, payload_len) };
    let header = FrameFragmentHeader::new(
        stream_seq,
        frame_id,
        frag_index,
        frag_count,
        Flags::from_bits(flags),
        u16::try_from(bytes.len()).unwrap_or(u16::MAX),
        host_send_ts_millis,
    );
    let datagram = encode_datagram(&header, bytes);
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&datagram, out, cap) }
}

/// One of the fragment size budgets, by index: `0` the header, `1` the whole datagram, `2` the
/// payload the two leave between them. An unknown index answers 0, which packetizes nothing.
///
/// The datagram budget is an MTU claim — 1200 bytes stays under a typical path MTU once
/// `WireGuard`'s overhead is on it — and every other codec that shares this socket sizes its own
/// chunk by subtracting from it. Transcribed, a raised budget would reach the packetizer and none
/// of them, and the first symptom is a fragmented datagram on the slowest link, not an error here.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_fragment_size(index: c_uchar) -> usize {
    match index {
        0 => slopdesk_video::fragment::HEADER_SIZE,
        1 => slopdesk_video::fragment::MAX_DATAGRAM_SIZE,
        2 => slopdesk_video::fragment::MAX_PAYLOAD_SIZE,
        _ => 0,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::cast_possible_truncation,
    reason = "calling the boundary IS what these tests are for"
)]
mod tests {
    use super::*;

    fn encode(payload: &[u8], out: &mut [u8]) -> usize {
        unsafe {
            slopdesk_video_fragment_encode(
                7,
                9,
                2,
                5,
                Flags::KEYFRAME.bits(),
                1234,
                payload.as_ptr(),
                payload.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        }
    }

    fn decode(bytes: &[u8]) -> Option<SlopDeskVideoFragmentHeader> {
        let mut header = SlopDeskVideoFragmentHeader::default();
        let ok = unsafe { slopdesk_video_fragment_decode(bytes.as_ptr(), bytes.len(), &raw mut header) };
        ok.then_some(header)
    }

    #[test]
    fn a_datagram_round_trips_through_the_boundary() {
        let payload: Vec<u8> = (0..64u8).collect();
        let mut out = [0u8; 128];
        let len = encode(&payload, &mut out);
        assert_eq!(len, slopdesk_video::fragment::HEADER_SIZE + payload.len());

        let header = decode(&out[..len]).expect("what this side wrote, this side reads");
        assert_eq!(header.stream_seq, 7);
        assert_eq!(header.frame_id, 9);
        assert_eq!(header.frag_index, 2);
        assert_eq!(header.frag_count, 5);
        assert_eq!(header.host_send_ts_millis, 1234);
        assert_eq!(header.flags, Flags::KEYFRAME.bits());
        assert_eq!(header.payload_length, payload.len() as u16);
        assert_eq!(&out[usize::from(header.payload_offset)..len], payload.as_slice());
    }

    #[test]
    fn the_boundary_agrees_with_the_codec_it_wraps() {
        let payload: Vec<u8> = (0..200u8).collect();
        let mut out = [0u8; 256];
        let len = encode(&payload, &mut out);

        let direct = encode_datagram(
            &FrameFragmentHeader::new(7, 9, 2, 5, Flags::KEYFRAME, payload.len() as u16, 1234),
            &payload,
        );
        assert_eq!(&out[..len], direct.as_slice());
    }

    #[test]
    fn a_short_buffer_is_refused_and_nothing_is_written() {
        let payload = [1u8; 32];
        let mut out = [0u8; 8];
        let needed = encode(&payload, &mut out);
        assert_eq!(needed, slopdesk_video::fragment::HEADER_SIZE + payload.len());
        assert_eq!(out, [0u8; 8], "a refusal writes nothing at all");
    }

    #[test]
    fn a_truncated_or_lying_datagram_is_refused() {
        let payload = [3u8; 40];
        let mut out = [0u8; 128];
        let len = encode(&payload, &mut out);

        assert!(decode(&out[..len - 1]).is_none(), "the payload runs short");
        assert!(decode(&out[..10]).is_none(), "there is no header there");
        assert!(decode(&[]).is_none(), "an empty datagram is not a fragment");
    }

    #[test]
    fn a_null_out_still_answers_whether_it_parsed() {
        let payload = [5u8; 16];
        let mut out = [0u8; 64];
        let len = encode(&payload, &mut out);
        let parsed = unsafe { slopdesk_video_fragment_decode(out.as_ptr(), len, core::ptr::null_mut()) };
        assert!(parsed, "NULL is inert, not a failure to parse");
    }
}
