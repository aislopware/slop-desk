//! The mux receive path: a TCP byte stream becoming whole envelopes.
//!
//! [`slopdesk_wire::mux::MuxFrameDecoder`] is [`crate::frame_decoder`] one layer up — the same
//! buffering, the same cursor, the same fail-stop — splitting mux envelopes instead of terminal
//! frames. One decoder per physical mux connection.
//!
//! ## Why the payload is fetched, not handed over
//! For the same reason and by the same route as [`crate::frame_decoder`]: a `channelData` body is
//! an inner terminal frame the mux layer never parses, it lives in the decoder's own buffer, and
//! that buffer moves when the head is compacted. [`slopdesk_mux_decoder_next`] answers with the
//! payload's LENGTH and parks it; [`slopdesk_mux_decoder_payload`] copies it out once. The park
//! holds until the next `next` on the same handle.
//!
//! ## The verdicts
//! [`crate::wire_message`]'s `SLOPDESK_WIRE_DECODE_*` plus [`crate::frame_decoder`]'s
//! [`FRAME_PENDING`] and [`FRAME_TOO_LARGE`] — the framing faults are the framing faults, and a
//! caller that already maps one door's answers maps this one's.

use core::ffi::c_uchar;
use core::ops::Range;

use slopdesk_wire::WireError;
use slopdesk_wire::mux::MuxFrameDecoder;

use crate::frame_decoder::{FRAME_PENDING, FRAME_TOO_LARGE};
use crate::mux_envelope::{SlopDeskMuxFrame, pack};
use crate::wire_message::{WIRE_DECODE_AGAIN, WIRE_DECODE_OK, verdict};
use crate::{borrow, deliver};

/// The opaque handle: the decoder, the payload its last answer named, and a frame it decoded but
/// could not deliver into too small an arena.
#[derive(Debug, Default)]
pub struct SlopDeskMuxDecoder {
    decoder: MuxFrameDecoder,
    /// Where the last delivered frame's opaque payload sits in `decoder`'s buffer.
    payload: Range<usize>,
    /// A frame already taken off the stream whose arena did not fit — it cannot be put back.
    parked: Option<(SlopDeskMuxFrame, Vec<u8>)>,
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_mux_decoder_new`] that has not been freed, and
/// no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskMuxDecoder) -> Option<&'a mut SlopDeskMuxDecoder> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one object per connection, driven by one receive loop.
    Some(unsafe { &mut *handle })
}

/// Builds a decoder with an empty buffer.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decoder_new() -> *mut SlopDeskMuxDecoder {
    Box::into_raw(Box::new(SlopDeskMuxDecoder::default()))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_mux_decoder_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_mux_decoder_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decoder_free(handle: *mut SlopDeskMuxDecoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Appends a freshly received chunk. Dropped entirely once the decoder is poisoned.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `bytes` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decoder_append(
    handle: *mut SlopDeskMuxDecoder,
    bytes: *const c_uchar,
    len: usize,
) {
    // SAFETY: the caller's obligations are this function's; `held` and `borrow` restate them.
    unsafe {
        if let Some(held) = held(handle) {
            held.decoder.append(borrow(bytes, len));
        }
    }
}

/// Bytes currently buffered. Lets a caller assert a poisoned decoder cannot be grown.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decoder_buffered(handle: *mut SlopDeskMuxDecoder) -> usize {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe { held(handle).map_or(0, |held| held.decoder.buffered_byte_count()) }
}

/// Takes the next whole envelope off the stream.
///
/// `detail` carries what the verdict alone cannot say: the arena size on [`WIRE_DECODE_AGAIN`], the
/// unknown mux-type byte on `SLOPDESK_WIRE_DECODE_UNKNOWN_TYPE`, the claimed length on
/// [`FRAME_TOO_LARGE`]. It is left alone otherwise.
///
/// On [`WIRE_DECODE_OK`] the frame's opaque payload is PARKED rather than written: `payload_length`
/// says how long it is and [`slopdesk_mux_decoder_payload`] copies it out.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `out` must be writable for one
/// [`SlopDeskMuxFrame`], `arena` for `arena_cap` bytes, and `detail` for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decoder_next(
    handle: *mut SlopDeskMuxDecoder,
    out: *mut SlopDeskMuxFrame,
    arena: *mut c_uchar,
    arena_cap: usize,
    detail: *mut usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's; `held`, `deliver` and the two writes
    // below are each covered by one of them.
    unsafe {
        let Some(held) = held(handle) else {
            return FRAME_PENDING;
        };

        let packed = match held.parked.take() {
            Some(parked) => parked,
            None => {
                match held.decoder.next_frame_leaving_payload() {
                    Ok(None) => return FRAME_PENDING,
                    Err(error) => {
                        if !detail.is_null() {
                            detail.write(match error {
                                WireError::FrameTooLarge(length) => length,
                                WireError::UnknownMessageType(byte) => byte as usize,
                                _ => 0,
                            });
                        }
                        return match error {
                            WireError::FrameTooLarge(_) => FRAME_TOO_LARGE,
                            ref other => verdict(other),
                        };
                    },
                    Ok(Some((frame, payload))) => {
                        held.payload = payload.clone();
                        // Packed as `0..len`, not where it actually sits: the caller cannot index this
                        // buffer, so the only true thing to tell it is how long the payload is.
                        pack(&frame, &(0..payload.len()))
                    },
                }
            },
        };

        if packed.1.len() > arena_cap || out.is_null() {
            if !detail.is_null() {
                detail.write(packed.1.len());
            }
            held.parked = Some(packed);
            return WIRE_DECODE_AGAIN;
        }
        deliver(&packed.1, arena, arena_cap);
        out.write(packed.0);
        WIRE_DECODE_OK
    }
}

/// Copies the payload the last [`slopdesk_mux_decoder_next`] parked into the caller's buffer, and
/// reports its length either way (the §4 convention: `n > cap` wrote nothing).
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_decoder_payload(
    handle: *mut SlopDeskMuxDecoder,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's; `held` and `deliver` restate them.
    unsafe {
        let Some(held) = held(handle) else {
            return 0;
        };
        let payload = held.payload.clone();
        deliver(held.decoder.payload_bytes(&payload), out, cap)
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "the tests drive the same C entry points every caller does"
    )]
    #![expect(
        clippy::indexing_slicing,
        reason = "a test that slices its own fixture out of range has already failed"
    )]

    use slopdesk_wire::mux::MuxFrame;

    use super::{
        SlopDeskMuxDecoder, slopdesk_mux_decoder_append, slopdesk_mux_decoder_buffered,
        slopdesk_mux_decoder_free, slopdesk_mux_decoder_new, slopdesk_mux_decoder_next,
        slopdesk_mux_decoder_payload,
    };
    use crate::frame_decoder::{FRAME_PENDING, FRAME_TOO_LARGE};
    use crate::mux_envelope::SlopDeskMuxFrame;
    use crate::wire_message::{WIRE_DECODE_AGAIN, WIRE_DECODE_OK};

    struct Held(*mut SlopDeskMuxDecoder);

    impl Drop for Held {
        fn drop(&mut self) {
            unsafe { slopdesk_mux_decoder_free(self.0) };
        }
    }

    fn decoder() -> Held {
        Held(unsafe { slopdesk_mux_decoder_new() })
    }

    fn feed(held: &Held, bytes: &[u8]) {
        unsafe { slopdesk_mux_decoder_append(held.0, bytes.as_ptr(), bytes.len()) };
    }

    fn next(held: &Held) -> (u32, SlopDeskMuxFrame, usize) {
        let mut flat = SlopDeskMuxFrame::default();
        let mut arena = [0u8; 512];
        let mut detail = 0usize;
        let verdict = unsafe {
            slopdesk_mux_decoder_next(
                held.0,
                &raw mut flat,
                arena.as_mut_ptr(),
                arena.len(),
                &raw mut detail,
            )
        };
        (verdict, flat, detail)
    }

    #[test]
    fn an_envelope_split_across_reads_is_still_one_frame() {
        let held = decoder();
        let payload = b"an inner terminal frame".to_vec();
        let bytes = MuxFrame::ChannelData {
            channel_id: 11,
            payload: payload.clone(),
        }
        .encode();
        for byte in &bytes[..bytes.len() - 1] {
            feed(&held, &[*byte]);
            assert_eq!(
                next(&held).0,
                FRAME_PENDING,
                "answered before the envelope was whole"
            );
        }
        feed(&held, &bytes[bytes.len() - 1..]);
        let (verdict, flat, _) = next(&held);
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(flat.channel_id, 11);
        assert_eq!(flat.payload_length as usize, payload.len());

        let mut out = vec![0u8; flat.payload_length as usize];
        let copied = unsafe { slopdesk_mux_decoder_payload(held.0, out.as_mut_ptr(), out.len()) };
        assert_eq!(copied, out.len());
        assert_eq!(out, payload);
    }

    #[test]
    fn an_oversized_prefix_poisons_the_connection_and_says_how_big_it_claimed_to_be() {
        let held = decoder();
        feed(&held, &[0xFF, 0xFF, 0xFF, 0xFF]);
        let (verdict, _, detail) = next(&held);
        assert_eq!(verdict, FRAME_TOO_LARGE);
        assert_eq!(detail, 0xFFFF_FFFF);

        feed(
            &held,
            &MuxFrame::WindowAdjust {
                channel_id: 1,
                bytes_to_add: 8,
            }
            .encode(),
        );
        assert_eq!(next(&held).0, FRAME_TOO_LARGE);
        assert_eq!(unsafe { slopdesk_mux_decoder_buffered(held.0) }, 0);
    }

    #[test]
    fn an_open_whose_cwd_does_not_fit_waits_rather_than_being_lost() {
        let held = decoder();
        let cwd = "/deep".repeat(80);
        feed(
            &held,
            &MuxFrame::ChannelOpen {
                channel_id: 4,
                session_id: [1; 16],
                last_received_seq: 3,
                channel_class: 1,
                initial_cwd: Some(cwd.clone()),
            }
            .encode(),
        );

        let mut flat = SlopDeskMuxFrame::default();
        let mut small = [0u8; 8];
        let mut detail = 0usize;
        let verdict = unsafe {
            slopdesk_mux_decoder_next(
                held.0,
                &raw mut flat,
                small.as_mut_ptr(),
                small.len(),
                &raw mut detail,
            )
        };
        assert_eq!(verdict, WIRE_DECODE_AGAIN);
        assert_eq!(detail, cwd.len(), "the retry must be told how much room it needs");

        // The envelope is off the stream by now — the retry has to find it parked, not gone.
        let (verdict, flat, _) = next(&held);
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(flat.cwd_length as usize, cwd.len());
        assert!(flat.has_cwd);
    }
}
