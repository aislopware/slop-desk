//! PATH 4's CLIENT end — requests out, replies in.
//!
//! `rust/slopdesk-dropd`'s `client` module owns every layout. This is the door.
//!
//! ## Why the client end lives in the daemon's crate
//! Because there the round trip is a TEST: `encode_request_*` and `decode_request` sit beside each
//! other and one test walks every frame type through both. While the client end was Swift the two
//! agreed by review, and this door is what makes the Rust one the only one.
//!
//! ## Two shapes
//! A request crosses as its type byte plus the three scalars any frame could carry and ONE borrowed
//! blob — a name for an offer, a body for a chunk, nothing for the rest. A reply crosses as a
//! record plus a small arena for the one string it can hold.
//!
//! The frame splitter is a HANDLE, for [`crate::mux_decoder`]'s reason: half a length prefix in one
//! `recv` and the rest in the next is the normal case, so the buffer has to outlive the call.
//!
//! ## The verdicts
//! Its own, because this protocol's faults are its own: a reply type the client does not know is
//! not the same answer as a body that ran short, and the Swift error enum names both.

use core::ffi::c_uchar;

use slopdesk_dropd::client::{
    CHUNK_BYTE_COUNT, FrameError, ReplyFrameDecoder, chunk_frame_len, decode_reply_payload,
    encode_request_frame, write_chunk_frame,
};
use slopdesk_dropd::protocol::{DecodeError, MAX_FRAME_PAYLOAD, MAX_TRANSFER_BYTES, Reply, Request, VERSION};

use crate::{TextArena, borrow, deliver};

/// The answer decoded cleanly.
pub const DROP_OK: u32 = 0;
/// No whole frame is buffered yet. Not an error — the splitter's `Ok(None)`.
pub const DROP_PENDING: u32 = 1;
/// The payload held no type byte at all.
pub const DROP_EMPTY: u32 = 2;
/// A type byte this end does not answer to; the byte itself is in `detail`.
pub const DROP_UNKNOWN_TYPE: u32 = 3;
/// The body ran short of what its type needs.
pub const DROP_TRUNCATED: u32 = 4;
/// A string field was not valid UTF-8.
pub const DROP_BAD_UTF8: u32 = 5;
/// A length prefix over the frame cap; the length is in `detail`.
pub const DROP_FRAME_TOO_LARGE: u32 = 6;

/// A text field, as an `(offset, length)` pair into the call's arena.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskDropText {
    /// Where the field starts in the arena.
    pub offset: u32,
    /// How long it is, in bytes.
    pub length: u32,
}

/// One host→client reply, flattened.
///
/// `kind` is the wire type byte — 6 `helloAck`, 7 `accept`, 8 `complete`, 9 `failed` — so a caller
/// switches on the same number the protocol does rather than on an ordinal invented here.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskDropReply {
    /// Whichever transfer the reply names; 0 for `helloAck`.
    pub transfer_id: u32,
    /// The failure reason, into the arena. Empty for every other kind.
    pub reason: SlopDeskDropText,
    /// The wire type byte.
    pub kind: u8,
    /// `helloAck`'s answer; false for every other kind.
    pub accepted: bool,
    /// The verdict's detail: the offending type byte, or a frame length over the cap.
    pub detail: u64,
}

/// The verdict a decode error names, and the detail that goes with it.
const fn fault(error: DecodeError) -> (u32, u64) {
    match error {
        DecodeError::Empty => (DROP_EMPTY, 0),
        DecodeError::UnknownType(byte) => (DROP_UNKNOWN_TYPE, byte as u64),
        DecodeError::Truncated => (DROP_TRUNCATED, 0),
        DecodeError::BadUtf8 => (DROP_BAD_UTF8, 0),
    }
}

/// Flattens a reply into the caller's record, interning its one string.
fn flatten(reply: &Reply, pool: &mut TextArena) -> SlopDeskDropReply {
    let mut record = SlopDeskDropReply::default();
    match *reply {
        Reply::HelloAck { accepted } => {
            record.kind = 6;
            record.accepted = accepted;
        },
        Reply::Accept { transfer_id } => {
            record.kind = 7;
            record.transfer_id = transfer_id;
        },
        Reply::Complete { transfer_id } => {
            record.kind = 8;
            record.transfer_id = transfer_id;
        },
        Reply::Failed {
            transfer_id,
            ref reason,
        } => {
            let (offset, length) = pool.intern(reason.as_bytes());
            record.kind = 9;
            record.transfer_id = transfer_id;
            record.reason = SlopDeskDropText { offset, length };
        },
    }
    record
}

/// Writes a flattened reply and its arena into the caller's buffers.
///
/// # Safety
/// `out` must be null or writable for one record; `arena` must be null or writable for `arena_cap`.
#[expect(
    unsafe_code,
    reason = "writing the caller's record and arena IS the boundary this module documents"
)]
unsafe fn hand_over(
    record: SlopDeskDropReply,
    pool: &TextArena,
    out: *mut SlopDeskDropReply,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    if out.is_null() || pool.0.len() > arena_cap {
        return DROP_TRUNCATED;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one record for this call.
    unsafe {
        out.write(record);
        deliver(&pool.0, arena, arena_cap);
    }
    DROP_OK
}

/// The full framed bytes for one client→host request.
///
/// `kind` is the wire type byte: 1 `hello` (`file_size` carries the version), 2 `offer` (`blob` is
/// the name), 3 `chunk` (`blob` is the body), 4 `finish`, 5 `cancel`. An unknown kind answers 0.
///
/// # Safety
/// `blob` must describe live memory for the call; `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_encode_request(
    kind: u8,
    transfer_id: u32,
    file_size: u64,
    blob: *const c_uchar,
    blob_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let blob = borrow(blob, blob_len);
        // A chunk's body is 256 KiB and is BORROWED all the way to the frame, and the sizing call
        // that precedes every write answers from arithmetic rather than by building the frame and
        // throwing it away. That is the difference between one copy of the body per chunk and three,
        // paid four thousand times per gigabyte. The four small frames build a `Request`, whose
        // largest body is a filename.
        if kind == 3 {
            let needed = chunk_frame_len(blob.len());
            if out.is_null() || cap < needed {
                return needed;
            }
            // SAFETY: `out` is non-null and writable for `cap >= needed` bytes by the caller's
            // obligation, and nothing else aliases it for the duration of this call.
            let room = std::slice::from_raw_parts_mut(out, needed);
            return if write_chunk_frame(room, transfer_id, blob) {
                needed
            } else {
                0
            };
        }
        let request = match kind {
            1 => {
                Request::Hello {
                    version: u8::try_from(file_size).unwrap_or(VERSION),
                }
            },
            2 => {
                Request::Offer {
                    transfer_id,
                    file_size,
                    name: String::from_utf8_lossy(blob).into_owned(),
                }
            },
            4 => Request::Finish { transfer_id },
            5 => Request::Cancel { transfer_id },
            _ => return 0,
        };
        deliver(&encode_request_frame(&request), out, cap)
    }
}

/// Decodes one reply payload (`[u8 type][body]`).
///
/// # Safety
/// `payload` must describe live memory for the call; `out` must point to one writable record;
/// `arena` must be null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_decode_reply(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskDropReply,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let reply = match decode_reply_payload(borrow(payload, payload_len)) {
            Ok(reply) => reply,
            Err(error) => {
                let (verdict, detail) = fault(error);
                if !out.is_null() {
                    out.write(SlopDeskDropReply {
                        detail,
                        ..SlopDeskDropReply::default()
                    });
                }
                return verdict;
            },
        };
        let mut pool = TextArena::default();
        let record = flatten(&reply, &mut pool);
        hand_over(record, &pool, out, arena, arena_cap)
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_drop_decoder_new`] that has not been freed, and
/// no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut ReplyFrameDecoder) -> Option<&'a mut ReplyFrameDecoder> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one decoder per connection, driven by one receive loop.
    Some(unsafe { &mut *handle })
}

/// Builds a reply splitter with an empty buffer.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_decoder_new() -> *mut ReplyFrameDecoder {
    Box::into_raw(Box::new(ReplyFrameDecoder::new()))
}

/// Frees a splitter. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_drop_decoder_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_drop_decoder_new`] not yet freed, with
/// no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_decoder_free(handle: *mut ReplyFrameDecoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from one `new` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Appends a freshly received chunk. A no-op once poisoned.
///
/// # Safety
/// `handle` must be live per [`held`]; `chunk` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_decoder_append(
    handle: *mut ReplyFrameDecoder,
    chunk: *const c_uchar,
    chunk_len: usize,
) {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        if let Some(decoder) = held(handle) {
            decoder.append(borrow(chunk, chunk_len));
        }
    }
}

/// The next complete reply, or [`DROP_PENDING`] when a whole frame is not yet buffered.
///
/// A fault poisons the splitter, and every later call re-reports it: the byte boundary for the
/// stream is lost, so resynchronising onto a peer's bytes is never the answer.
///
/// # Safety
/// `handle` must be live per [`held`]; `out` must point to one writable record; `arena` must be
/// null or writable for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_decoder_next(
    handle: *mut ReplyFrameDecoder,
    out: *mut SlopDeskDropReply,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(decoder) = held(handle) else {
            return DROP_EMPTY;
        };
        match decoder.next_reply() {
            Ok(None) => DROP_PENDING,
            Ok(Some(reply)) => {
                let mut pool = TextArena::default();
                let record = flatten(&reply, &mut pool);
                hand_over(record, &pool, out, arena, arena_cap)
            },
            Err(error) => {
                let (verdict, detail) = match error {
                    FrameError::FrameTooLarge(bytes) => (DROP_FRAME_TOO_LARGE, bytes as u64),
                    FrameError::Decode(inner) => fault(inner),
                };
                if !out.is_null() {
                    out.write(SlopDeskDropReply {
                        detail,
                        ..SlopDeskDropReply::default()
                    });
                }
                verdict
            },
        }
    }
}

/// How many bytes the splitter is holding — the assertion that a poisoned one cannot be grown.
///
/// # Safety
/// `handle` must be live per [`held`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_drop_decoder_buffered(handle: *mut ReplyFrameDecoder) -> usize {
    // SAFETY: the caller's obligations are this function's.
    unsafe { held(handle).map_or(0, |decoder| decoder.buffered_len()) }
}

/// One PATH-4 constant by index, so no caller respells a wire number.
///
/// | index | constant |
/// | --- | --- |
/// | 0 | the only supported version |
/// | 1 | the per-frame payload cap |
/// | 2 | the body chunk size a client sends |
/// | 3 | the hard ceiling on one offered file |
///
/// An unknown index answers `-1`, which is not a value any of these could be.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_drop_constant(index: u32) -> i64 {
    match index {
        0 => i64::from(VERSION),
        1 => i64::try_from(MAX_FRAME_PAYLOAD).unwrap_or(i64::MAX),
        2 => i64::try_from(CHUNK_BYTE_COUNT).unwrap_or(i64::MAX),
        3 => i64::try_from(MAX_TRANSFER_BYTES).unwrap_or(i64::MAX),
        _ => -1,
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
    #![expect(
        clippy::borrow_as_ptr,
        reason = "a `&mut record` at a C entry point is exactly what Swift's `&record` compiles to"
    )]

    use slopdesk_dropd::protocol::encode_reply_frame;

    use super::*;

    /// Encodes through the door, sizing the way §4 says to.
    fn framed(kind: u8, transfer_id: u32, file_size: u64, blob: &[u8]) -> Vec<u8> {
        let call = |out: *mut c_uchar, cap: usize| {
            // SAFETY: the fixture's blob outlives the call and `out` is this vector's storage.
            unsafe {
                slopdesk_drop_encode_request(
                    kind,
                    transfer_id,
                    file_size,
                    blob.as_ptr(),
                    blob.len(),
                    out,
                    cap,
                )
            }
        };
        let needed = call(core::ptr::null_mut(), 0);
        let mut frame = vec![0u8; needed];
        assert_eq!(call(frame.as_mut_ptr(), needed), needed);
        frame
    }

    #[test]
    fn every_request_the_door_encodes_is_the_frame_the_crate_encodes() {
        assert_eq!(
            framed(1, 0, u64::from(VERSION), &[]),
            encode_request_frame(&Request::Hello { version: VERSION })
        );
        assert_eq!(
            framed(2, 7, 4096, b"notes.txt"),
            encode_request_frame(&Request::Offer {
                transfer_id: 7,
                file_size: 4096,
                name: "notes.txt".to_owned(),
            })
        );
        let mut chunk = vec![0u8; chunk_frame_len(4)];
        assert!(write_chunk_frame(&mut chunk, 7, b"body"));
        assert_eq!(framed(3, 7, 0, b"body"), chunk);
        assert_eq!(
            framed(4, 7, 0, &[]),
            encode_request_frame(&Request::Finish { transfer_id: 7 })
        );
        assert_eq!(
            framed(5, 7, 0, &[]),
            encode_request_frame(&Request::Cancel { transfer_id: 7 })
        );
        assert_eq!(
            framed(99, 0, 0, &[]),
            Vec::<u8>::new(),
            "an unknown kind is no frame"
        );
    }

    #[test]
    fn a_failed_reply_brings_its_reason_through_the_arena() {
        let frame = encode_reply_frame(&Reply::Failed {
            transfer_id: 3,
            reason: "no room on disk".to_owned(),
        });
        let payload = &frame[4..];
        let mut record = SlopDeskDropReply::default();
        let mut arena = [0u8; 64];
        // SAFETY: every pointer here is to a live local for the duration of the call.
        let verdict = unsafe {
            slopdesk_drop_decode_reply(
                payload.as_ptr(),
                payload.len(),
                &mut record,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(verdict, DROP_OK);
        assert_eq!(record.kind, 9);
        assert_eq!(record.transfer_id, 3);
        let start = record.reason.offset as usize;
        let end = start + record.reason.length as usize;
        assert_eq!(&arena[start..end], b"no room on disk");
    }

    #[test]
    fn a_request_type_arriving_as_a_reply_is_refused_by_its_own_byte() {
        let mut record = SlopDeskDropReply::default();
        // SAFETY: the payload and the record are live locals.
        let verdict = unsafe {
            slopdesk_drop_decode_reply([2u8, 0, 0].as_ptr(), 3, &mut record, core::ptr::null_mut(), 0)
        };
        assert_eq!(verdict, DROP_UNKNOWN_TYPE);
        assert_eq!(record.detail, 2);
    }

    #[test]
    fn the_splitter_waits_for_a_whole_frame_and_then_answers() {
        let frame = encode_reply_frame(&Reply::Accept { transfer_id: 12 });
        let mut record = SlopDeskDropReply::default();
        // SAFETY: the handle comes from `new`, is used by this thread only, and is freed once.
        unsafe {
            let handle = slopdesk_drop_decoder_new();
            slopdesk_drop_decoder_append(handle, frame.as_ptr(), 2);
            assert_eq!(
                slopdesk_drop_decoder_next(handle, &mut record, core::ptr::null_mut(), 0),
                DROP_PENDING
            );
            slopdesk_drop_decoder_append(handle, frame[2..].as_ptr(), frame.len() - 2);
            assert_eq!(
                slopdesk_drop_decoder_next(handle, &mut record, core::ptr::null_mut(), 0),
                DROP_OK
            );
            assert_eq!(record.kind, 7);
            assert_eq!(record.transfer_id, 12);
            slopdesk_drop_decoder_free(handle);
        }
    }

    #[test]
    fn an_over_cap_prefix_poisons_the_splitter_and_keeps_reporting_it() {
        let mut record = SlopDeskDropReply::default();
        let prefix = u32::MAX.to_be_bytes();
        // SAFETY: as above.
        unsafe {
            let handle = slopdesk_drop_decoder_new();
            slopdesk_drop_decoder_append(handle, prefix.as_ptr(), prefix.len());
            assert_eq!(
                slopdesk_drop_decoder_next(handle, &mut record, core::ptr::null_mut(), 0),
                DROP_FRAME_TOO_LARGE
            );
            assert_eq!(record.detail, u64::from(u32::MAX));
            slopdesk_drop_decoder_append(handle, prefix.as_ptr(), prefix.len());
            assert_eq!(
                slopdesk_drop_decoder_buffered(handle),
                0,
                "a poisoned splitter cannot grow"
            );
            assert_eq!(
                slopdesk_drop_decoder_next(handle, &mut record, core::ptr::null_mut(), 0),
                DROP_FRAME_TOO_LARGE
            );
            slopdesk_drop_decoder_free(handle);
        }
    }

    #[test]
    fn the_constants_are_the_crate_s_own() {
        assert_eq!(slopdesk_drop_constant(0), i64::from(VERSION));
        assert_eq!(
            slopdesk_drop_constant(1),
            i64::try_from(MAX_FRAME_PAYLOAD).unwrap_or(i64::MAX)
        );
        assert_eq!(
            slopdesk_drop_constant(2),
            i64::try_from(CHUNK_BYTE_COUNT).unwrap_or(i64::MAX)
        );
        assert_eq!(
            slopdesk_drop_constant(3),
            i64::try_from(MAX_TRANSFER_BYTES).unwrap_or(i64::MAX)
        );
        assert_eq!(slopdesk_drop_constant(99), -1);
    }
}
