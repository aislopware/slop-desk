//! `mux_header`: the per-datagram UDP channel-mux PREFIX over the C ABI — the live wire that
//! fronts EVERY video datagram with a `u32` BE channelID lane id (the Swift
//! `VideoMuxHeaderCodec`). This completes the "every wire codec is Rust `SoT`" set: the same 4 bytes
//! the host/client mux flows prepend/strip are now produced + parsed by the single
//! [`video_mux_header`](aislopdesk_core::mux_header::video_mux_header) source of truth.
//!
//! ## Zero-copy, no per-packet heap
//!
//! The prefix is only 4 bytes and rides EVERY datagram, so neither boundary function allocates:
//!
//! * [`aisd_video_mux_header_encode`] is **caller-out** — it writes exactly the 4 BE channelID
//!   bytes into the front of a caller buffer the Swift side already sized to `4 + payload.len`
//!   (then the caller copies its payload after). No [`crate::AisdBytes`], no per-packet `Vec`.
//! * [`aisd_video_mux_header_decode`] **borrows** the datagram and returns the channelID by value
//!   plus the payload byte OFFSET (always `4` on success). The caller forms its own zero-copy
//!   payload sub-slice from that offset — the codec copies nothing.
//!
//! A C call is on the order of nanoseconds, so routing the trivial framing through the shared
//! codec costs nothing measurable while giving the Android shell the identical bytes. The wire is
//! byte-for-byte what the prior native `appendBE` / `VideoByteReader` framing produced (the
//! `muxBare` golden vector pins it).

use crate::{AISD_ERR_NULL, AISD_ERR_TRUNCATED, AISD_OK, AisdStatus, slice_in, slice_out};
use aislopdesk_core::mux_header::{CHANNEL_ID_LENGTH, video_mux_header};

/// Byte length of the big-endian `u32` channelID prefix every muxed datagram carries (4).
///
/// Exposed so the caller can size its framing buffer (`CHANNEL_ID_LENGTH + payload.len`) and know
/// the payload offset a decode reports.
pub const AISD_VIDEO_MUX_CHANNEL_ID_LENGTH: usize = CHANNEL_ID_LENGTH;

/// Writes the 4-byte big-endian `channel_id` prefix into the front of a caller buffer (caller-out;
/// no allocation).
///
/// The Swift/Android shell sizes `out` to `CHANNEL_ID_LENGTH + payload.len`, calls this to stamp
/// the leading 4 bytes, then copies its own payload after them — reproducing
/// `[u32 BE channelID][payload…]` with zero per-packet heap on the Rust side. On [`AISD_OK`]
/// `*written` receives the bytes written (always [`AISD_VIDEO_MUX_CHANNEL_ID_LENGTH`]).
///
/// Returns [`AISD_ERR_NULL`] for a null `out` / `written`, or [`AISD_ERR_TRUNCATED`] when
/// `out_cap < CHANNEL_ID_LENGTH` (the caller under-sized the buffer — nothing is written).
///
/// # Safety
/// `out` must point to `out_cap` writable bytes and `written` must be a writable pointer.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_header_encode(
    channel_id: u32,
    out: *mut u8,
    out_cap: usize,
    written: *mut usize,
) -> AisdStatus {
    if out.is_null() || written.is_null() {
        return AISD_ERR_NULL;
    }
    if out_cap < CHANNEL_ID_LENGTH {
        return AISD_ERR_TRUNCATED;
    }
    // SAFETY: `out` covers `out_cap >= CHANNEL_ID_LENGTH` writable bytes per the contract + check.
    let slot = unsafe { slice_out(out, out_cap) };
    slot[..CHANNEL_ID_LENGTH].copy_from_slice(&channel_id.to_be_bytes());
    // SAFETY: `written` is non-null per the check above and writable per the contract.
    unsafe { written.write(CHANNEL_ID_LENGTH) };
    AISD_OK
}

/// Parses the leading channelID prefix of a muxed datagram, borrowing it (no allocation).
///
/// On [`AISD_OK`], `*out_channel_id` receives the `u32` lane id and `*out_payload_offset` the byte
/// offset where the opaque payload begins (always [`AISD_VIDEO_MUX_CHANNEL_ID_LENGTH`]). The caller
/// forms its own zero-copy payload slice as `datagram[*out_payload_offset..]` — the codec copies
/// nothing.
///
/// Returns [`AISD_ERR_NULL`] for a null out-param (or a null `datagram` with a nonzero `len`), or
/// [`AISD_ERR_TRUNCATED`] when fewer than 4 bytes are present (a corrupt single datagram never
/// crashes the receiver — the same contract the native decoder had). On any non-[`AISD_OK`] return
/// the out-params are left untouched.
///
/// # Safety
/// `out_channel_id` / `out_payload_offset` must be writable pointers; if `len != 0`, `datagram`
/// must point to at least `len` readable bytes.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_video_mux_header_decode(
    datagram: *const u8,
    len: usize,
    out_channel_id: *mut u32,
    out_payload_offset: *mut usize,
) -> AisdStatus {
    if out_channel_id.is_null() || out_payload_offset.is_null() || (datagram.is_null() && len != 0)
    {
        return AISD_ERR_NULL;
    }
    // SAFETY: `datagram` covers `len` readable bytes per the contract (and the null+len check).
    let slice = unsafe { slice_in(datagram, len) };
    match video_mux_header::decode(slice) {
        Ok((channel_id, payload)) => {
            // The borrowed payload starts exactly CHANNEL_ID_LENGTH into the datagram; report the
            // offset so the caller forms its own zero-copy sub-slice (Data subdata view in Swift).
            let offset = len - payload.len();
            // SAFETY: both out-params are non-null per the check above and writable per the contract.
            unsafe {
                out_channel_id.write(channel_id);
                out_payload_offset.write(offset);
            }
            AISD_OK
        }
        // The only failure the bare-prefix decode can raise is a < 4-byte datagram (truncated).
        Err(_) => AISD_ERR_TRUNCATED,
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` coercions.
    #![allow(clippy::borrow_as_ptr)]
    use super::*;

    /// Encodes `[channelID][payload]` exactly as the caller does: stamp the 4-byte prefix into a
    /// sized buffer, then append the payload.
    fn frame(channel_id: u32, payload: &[u8]) -> Vec<u8> {
        let mut buf = vec![0u8; CHANNEL_ID_LENGTH + payload.len()];
        let mut written = 0usize;
        let status = unsafe {
            aisd_video_mux_header_encode(channel_id, buf.as_mut_ptr(), buf.len(), &mut written)
        };
        assert_eq!(status, AISD_OK);
        assert_eq!(written, CHANNEL_ID_LENGTH);
        buf[CHANNEL_ID_LENGTH..].copy_from_slice(payload);
        buf
    }

    #[test]
    fn encode_matches_core_and_is_big_endian() {
        let bytes = frame(0x0102_0304, &[9, 8, 7]);
        assert_eq!(bytes, vec![1, 2, 3, 4, 9, 8, 7]);
        // Byte-identical to the core codec (the single source of truth the golden vector pins).
        assert_eq!(bytes, video_mux_header::encode(0x0102_0304, &[9, 8, 7]));
    }

    #[test]
    fn decode_returns_channel_id_and_payload_offset() {
        let bytes = frame(0xAABB_CCDD, &[1, 2, 3, 4, 5]);
        let mut id = 0u32;
        let mut offset = 0usize;
        let status = unsafe {
            aisd_video_mux_header_decode(bytes.as_ptr(), bytes.len(), &mut id, &mut offset)
        };
        assert_eq!(status, AISD_OK);
        assert_eq!(id, 0xAABB_CCDD);
        assert_eq!(offset, CHANNEL_ID_LENGTH);
        assert_eq!(&bytes[offset..], &[1, 2, 3, 4, 5]);
    }

    #[test]
    fn empty_payload_round_trips() {
        let bytes = frame(7, &[]);
        assert_eq!(bytes, vec![0, 0, 0, 7]);
        let mut id = 0u32;
        let mut offset = 0usize;
        let status = unsafe {
            aisd_video_mux_header_decode(bytes.as_ptr(), bytes.len(), &mut id, &mut offset)
        };
        assert_eq!(status, AISD_OK);
        assert_eq!(id, 7);
        assert_eq!(offset, 4);
        assert!(bytes[offset..].is_empty());
    }

    #[test]
    fn short_datagram_is_truncated() {
        let three = [1u8, 2, 3];
        let mut id = 99u32;
        let mut offset = 99usize;
        let status = unsafe {
            aisd_video_mux_header_decode(three.as_ptr(), three.len(), &mut id, &mut offset)
        };
        assert_eq!(status, AISD_ERR_TRUNCATED);
        // Out-params untouched on a non-OK return.
        assert_eq!(id, 99);
        assert_eq!(offset, 99);
        // Empty datagram is also truncated (null with len 0 is allowed).
        let status =
            unsafe { aisd_video_mux_header_decode(core::ptr::null(), 0, &mut id, &mut offset) };
        assert_eq!(status, AISD_ERR_TRUNCATED);
    }

    #[test]
    fn encode_undersized_buffer_is_truncated() {
        let mut small = [0u8; 3];
        let mut written = 7usize;
        let status = unsafe {
            aisd_video_mux_header_encode(1, small.as_mut_ptr(), small.len(), &mut written)
        };
        assert_eq!(status, AISD_ERR_TRUNCATED);
        assert_eq!(written, 7); // untouched
    }

    #[test]
    fn null_guards() {
        let mut buf = [0u8; 4];
        let mut written = 0usize;
        let mut id = 0u32;
        let mut offset = 0usize;
        unsafe {
            assert_eq!(
                aisd_video_mux_header_encode(1, core::ptr::null_mut(), 4, &mut written),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_video_mux_header_encode(1, buf.as_mut_ptr(), 4, core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_video_mux_header_decode(buf.as_ptr(), 4, core::ptr::null_mut(), &mut offset),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_video_mux_header_decode(buf.as_ptr(), 4, &mut id, core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            // null datagram with a nonzero len is a null error (cannot read).
            assert_eq!(
                aisd_video_mux_header_decode(core::ptr::null(), 4, &mut id, &mut offset),
                AISD_ERR_NULL
            );
        }
    }
}
