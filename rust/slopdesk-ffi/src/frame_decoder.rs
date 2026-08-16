//! The terminal receive path: a TCP byte stream becoming whole messages.
//!
//! [`slopdesk_wire::FrameDecoder`] buffers arbitrary chunks, hands back one message per call, and
//! fail-stops the whole channel the moment a frame's boundary is lost. One decoder per channel per
//! connection.
//!
//! ## Why a handle
//! Because a frame arrives in pieces. Half a length prefix in one `recv` and the rest in the next
//! is the NORMAL case, so the decoder has to remember what it has been shown; copying that across
//! per chunk would copy the frame under construction — up to a 16 MiB `.output` — on every read.
//! [`crate::replay`] documents the convention; the obligation is the same, one free per new and no
//! overlapping calls.
//!
//! ## Why the opaque run is fetched, not handed over
//! A decoded message's payload lives in the decoder's own buffer, which the caller cannot index
//! and which moves when the head is compacted. So [`slopdesk_frame_decoder_next`] answers with the
//! run's LENGTH in `blob_length` and parks the run; [`slopdesk_frame_decoder_run`] copies it into
//! the caller's buffer, once, straight out of the decode buffer. The park holds until the next
//! `next` on the same handle — read it before you ask for another frame.
//!
//! ## The verdicts
//! [`crate::wire_message`]'s `SLOPDESK_WIRE_DECODE_*` values, plus two this door adds:
//! [`FRAME_PENDING`] for "not a whole frame yet", which is not an error, and [`FRAME_TOO_LARGE`]
//! for a length prefix past the ceiling, which is the one fault the frame layer owns rather than
//! the message table.

use core::ffi::c_uchar;
use core::ops::Range;

use slopdesk_wire::{FrameDecoder, WireError};

use crate::wire_message::{Packed, SlopDeskWireMessage, WIRE_DECODE_AGAIN, WIRE_DECODE_OK, pack, verdict};
use crate::{borrow, deliver};

/// No complete frame is buffered yet — append more bytes and ask again. Not an error.
pub const FRAME_PENDING: u32 = 5;
/// A length prefix exceeded the frame ceiling; `detail` carries the claimed length. The decoder is
/// poisoned and every later call returns this same verdict.
pub const FRAME_TOO_LARGE: u32 = 6;

/// The opaque handle: the decoder, the run its last answer named, and a message it decoded but
/// could not deliver into too small an arena.
#[derive(Debug, Default)]
pub struct SlopDeskFrameDecoder {
    decoder: FrameDecoder,
    /// Where the last delivered message's opaque run sits in `decoder`'s buffer.
    run: Range<usize>,
    /// A message already taken off the stream whose arena did not fit. It CANNOT be left in the
    /// stream — the frame is consumed by then — so it waits here for the caller's retry.
    parked: Option<Packed>,
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_frame_decoder_new`] that has not been freed, and
/// no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskFrameDecoder) -> Option<&'a mut SlopDeskFrameDecoder> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one object per channel, driven by one receive loop.
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
pub unsafe extern "C" fn slopdesk_frame_decoder_new() -> *mut SlopDeskFrameDecoder {
    Box::into_raw(Box::new(SlopDeskFrameDecoder::default()))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_frame_decoder_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_frame_decoder_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_frame_decoder_free(handle: *mut SlopDeskFrameDecoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from one `new` and is freed once.
    drop(unsafe { Box::from_raw(handle) });
}

/// Appends a freshly received chunk. Empty input, one byte and many frames' worth are all fine.
///
/// Dropped entirely once the decoder is poisoned, so a peer that keeps feeding a dead channel
/// cannot grow it without bound.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `bytes` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_frame_decoder_append(
    handle: *mut SlopDeskFrameDecoder,
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
pub unsafe extern "C" fn slopdesk_frame_decoder_buffered(handle: *mut SlopDeskFrameDecoder) -> usize {
    // SAFETY: the caller's obligation is `held`'s.
    unsafe { held(handle).map_or(0, |held| held.decoder.buffered_byte_count()) }
}

/// Takes the next whole message off the stream.
///
/// `detail` carries what the verdict alone cannot say: the arena size on [`WIRE_DECODE_AGAIN`], the
/// unknown type byte on `SLOPDESK_WIRE_DECODE_UNKNOWN_TYPE`, the claimed length on
/// [`FRAME_TOO_LARGE`]. It is left alone otherwise.
///
/// On [`WIRE_DECODE_OK`] the message's opaque run is PARKED rather than written: `blob_length` says
/// how long it is and [`slopdesk_frame_decoder_run`] copies it out.
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation, `out` must be writable for one
/// [`SlopDeskWireMessage`], `arena` for `arena_cap` bytes, and `detail` for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_frame_decoder_next(
    handle: *mut SlopDeskFrameDecoder,
    out: *mut SlopDeskWireMessage,
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
                match held.decoder.next_message_leaving_opaque_run() {
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
                    Ok(Some((message, run))) => {
                        held.run = run.clone();
                        // The run is packed as `0..len`, not where it actually sits: the caller cannot
                        // index this buffer, so the only true thing to tell it is how long the run is.
                        pack(&message, &(0..run.len()))
                    },
                }
            },
        };

        if packed.arena.len() > arena_cap || out.is_null() {
            if !detail.is_null() {
                detail.write(packed.arena.len());
            }
            held.parked = Some(packed);
            return WIRE_DECODE_AGAIN;
        }
        deliver(&packed.arena, arena, arena_cap);
        out.write(packed.flat);
        WIRE_DECODE_OK
    }
}

/// Copies the run the last [`slopdesk_frame_decoder_next`] parked into the caller's buffer, and
/// reports its length either way (the §4 convention: `n > cap` wrote nothing).
///
/// # Safety
/// `handle` must satisfy [`held`]'s obligation and `out` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_frame_decoder_run(
    handle: *mut SlopDeskFrameDecoder,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's; `held` and `deliver` restate them.
    unsafe {
        let Some(held) = held(handle) else {
            return 0;
        };
        let run = held.run.clone();
        deliver(held.decoder.run_bytes(&run), out, cap)
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

    use slopdesk_wire::WireMessage;

    use super::{
        FRAME_PENDING, FRAME_TOO_LARGE, SlopDeskFrameDecoder, slopdesk_frame_decoder_append,
        slopdesk_frame_decoder_buffered, slopdesk_frame_decoder_free, slopdesk_frame_decoder_new,
        slopdesk_frame_decoder_next, slopdesk_frame_decoder_run,
    };
    use crate::wire_message::{SlopDeskWireMessage, WIRE_DECODE_OK};

    struct Held(*mut SlopDeskFrameDecoder);

    impl Drop for Held {
        fn drop(&mut self) {
            unsafe { slopdesk_frame_decoder_free(self.0) };
        }
    }

    fn decoder() -> Held {
        Held(unsafe { slopdesk_frame_decoder_new() })
    }

    fn feed(held: &Held, bytes: &[u8]) {
        unsafe { slopdesk_frame_decoder_append(held.0, bytes.as_ptr(), bytes.len()) };
    }

    fn next(held: &Held) -> (u32, SlopDeskWireMessage, usize) {
        let mut flat = SlopDeskWireMessage::default();
        let mut arena = [0u8; 512];
        let mut detail = 0usize;
        let verdict = unsafe {
            slopdesk_frame_decoder_next(
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
    fn a_frame_split_across_reads_is_still_one_message() {
        let held = decoder();
        let frame = WireMessage::Output {
            seq: 5,
            bytes: b"half now, half later".to_vec(),
        }
        .encode();
        for byte in &frame[..frame.len() - 1] {
            feed(&held, &[*byte]);
            assert_eq!(
                next(&held).0,
                FRAME_PENDING,
                "answered before the frame was whole"
            );
        }
        feed(&held, &frame[frame.len() - 1..]);
        let (verdict, flat, _) = next(&held);
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(flat.seq, 5);
        assert_eq!(flat.blob_length as usize, "half now, half later".len());

        let mut run = vec![0u8; flat.blob_length as usize];
        let copied = unsafe { slopdesk_frame_decoder_run(held.0, run.as_mut_ptr(), run.len()) };
        assert_eq!(copied, run.len());
        assert_eq!(run, b"half now, half later");
    }

    #[test]
    fn an_oversized_prefix_poisons_the_channel_and_says_how_big_it_claimed_to_be() {
        let held = decoder();
        feed(&held, &[0xFF, 0xFF, 0xFF, 0xFF]);
        let (verdict, _, detail) = next(&held);
        assert_eq!(verdict, FRAME_TOO_LARGE);
        assert_eq!(detail, 0xFFFF_FFFF);

        // Fail-stop: a poisoned decoder drops what follows rather than resynchronising onto it.
        feed(&held, &WireMessage::Bye.encode());
        assert_eq!(next(&held).0, FRAME_TOO_LARGE);
        assert_eq!(unsafe { slopdesk_frame_decoder_buffered(held.0) }, 0);
    }

    #[test]
    fn a_message_whose_arena_does_not_fit_waits_rather_than_being_lost() {
        let held = decoder();
        let title = "t".repeat(400);
        feed(&held, &WireMessage::Title(title.clone()).encode());

        let mut flat = SlopDeskWireMessage::default();
        let mut small = [0u8; 8];
        let mut detail = 0usize;
        let verdict = unsafe {
            slopdesk_frame_decoder_next(
                held.0,
                &raw mut flat,
                small.as_mut_ptr(),
                small.len(),
                &raw mut detail,
            )
        };
        assert_eq!(verdict, super::WIRE_DECODE_AGAIN);
        assert_eq!(
            detail,
            title.len(),
            "the retry must be told how much room it needs"
        );

        // The frame is off the stream by now — the retry has to find it parked, not gone.
        let (verdict, flat, _) = next(&held);
        assert_eq!(verdict, WIRE_DECODE_OK);
        assert_eq!(flat.text_a_length as usize, title.len());
    }
}
