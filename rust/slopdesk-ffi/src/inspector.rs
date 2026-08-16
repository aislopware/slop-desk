//! The inspector channel's CLIENT end — subscribe out, frames in.
//!
//! `rust/slopdesk-inspectord`'s `wire` module owns the frame: the four-byte big-endian prefix, the
//! 16 MiB cap, the three tags, the cursor-and-compact splitter. This is the door.
//!
//! ## What does NOT cross
//! An event's body. It is JSON, and the client parses it into its own model with `JSONDecoder` —
//! `decode_client` answers WHERE the body sits rather than what it says, so the bytes stay in the
//! caller's buffer. That keeps this door to the framing, which is the part that existed twice.
//!
//! The event SCHEMA still exists in two languages, and deliberately: `InspectorEvent` is a document
//! the daemon writes and the client reads, which is the two-ENDS shape, not one capability twice.
//!
//! ## The verdicts
//! Its own, because the recoverability split is this protocol's: a bad BODY is recoverable — the
//! frame's bytes were consumed before it was read, so the boundary holds — while a bad length
//! PREFIX is not, since nothing was consumed and every later read is garbage.

use core::ffi::c_uchar;

use slopdesk_inspectord::wire::{
    ClientFrame, CodecError, FrameDecoder, MAX_FRAME_PAYLOAD, PREFIX_LENGTH, WireMessage, decode_client,
    encode,
};

use crate::{borrow, deliver};

/// The frame decoded cleanly.
pub const INSPECTOR_OK: u32 = 0;
/// No whole frame is buffered yet. Not an error — the splitter's `Ok(None)`.
pub const INSPECTOR_PENDING: u32 = 1;
/// The payload held no type byte at all.
pub const INSPECTOR_TRUNCATED: u32 = 2;
/// A tag this end does not read; the byte itself is in `detail`.
pub const INSPECTOR_UNKNOWN_TYPE: u32 = 3;
/// A length prefix over the frame cap; the length is in `detail`.
pub const INSPECTOR_FRAME_TOO_LARGE: u32 = 4;
/// The body buffer was too small; the length needed is in `detail` and NOTHING was consumed.
pub const INSPECTOR_AGAIN: u32 = 5;

/// One host→client frame, as the client reads it.
///
/// `tag` is the wire type byte — 1 event, 2 keep-alive — so a caller switches on the same number
/// the protocol does. `body_offset`/`body_length` locate the event's JSON inside whichever buffer
/// the call was given; a keep-alive's body is empty.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskInspectorFrame {
    /// Where the body starts.
    pub body_offset: u32,
    /// How long the body is, in bytes.
    pub body_length: u32,
    /// The wire type byte.
    pub tag: u8,
    /// The verdict's detail: the offending tag, or a frame length over the cap.
    pub detail: u64,
}

/// The verdict a codec error names, and the detail that goes with it.
fn fault(error: &CodecError) -> (u32, u64) {
    match *error {
        CodecError::FrameTooLarge(length) => (INSPECTOR_FRAME_TOO_LARGE, length as u64),
        CodecError::UnknownType(tag) => (INSPECTOR_UNKNOWN_TYPE, u64::from(tag)),
        CodecError::Truncated | CodecError::MalformedBody(_) => (INSPECTOR_TRUNCATED, 0),
    }
}

/// Fills a record from what the client end read out of `payload`.
fn framed(frame: &ClientFrame) -> SlopDeskInspectorFrame {
    match *frame {
        ClientFrame::Event(ref body) => {
            SlopDeskInspectorFrame {
                body_offset: u32::try_from(body.start).unwrap_or(u32::MAX),
                body_length: u32::try_from(body.len()).unwrap_or(u32::MAX),
                tag: 1,
                detail: 0,
            }
        },
        ClientFrame::KeepAlive => {
            SlopDeskInspectorFrame {
                tag: 2,
                ..SlopDeskInspectorFrame::default()
            }
        },
    }
}

/// Writes a record, or a verdict's detail into an otherwise empty one.
///
/// # Safety
/// `out` must be null or writable for one record.
#[expect(
    unsafe_code,
    reason = "writing the caller's record IS the boundary this module documents"
)]
const unsafe fn place(out: *mut SlopDeskInspectorFrame, record: SlopDeskInspectorFrame) {
    if out.is_null() {
        return;
    }
    // SAFETY: non-null and, by the caller's obligation, writable for one record for this call.
    unsafe { out.write(record) };
}

/// The full framed bytes of the client's one outbound frame, `subscribe`.
///
/// Nine bytes, always, so the cap cannot be reached and there is no failure to report: an
/// unencodable subscribe does not exist.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_encode_subscribe(
    from_seq: i64,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    let Ok(frame) = encode(&WireMessage::Subscribe { from_seq }) else {
        return 0;
    };
    // SAFETY: the caller's obligation is this function's.
    unsafe { deliver(&frame, out, cap) }
}

/// Reads one whole payload — the tag included, the length prefix already stripped — the way the
/// CLIENT end reads it: the tag, and where the body sits INSIDE `payload`.
///
/// Nothing is copied. The caller already holds the bytes; this answers what they are.
///
/// # Safety
/// `payload` must describe live memory for the call; `out` must be null or writable for one record.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_decode_payload(
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut SlopDeskInspectorFrame,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        match decode_client(borrow(payload, payload_len)) {
            Ok(frame) => {
                place(out, framed(&frame));
                INSPECTOR_OK
            },
            Err(error) => {
                let (verdict, detail) = fault(&error);
                place(out, SlopDeskInspectorFrame {
                    detail,
                    ..SlopDeskInspectorFrame::default()
                });
                verdict
            },
        }
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_inspector_decoder_new`] that has not been freed,
/// and no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut FrameDecoder) -> Option<&'a mut FrameDecoder> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one decoder per connection, driven by one receive loop.
    Some(unsafe { &mut *handle })
}

/// Builds a frame splitter with an empty buffer.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_decoder_new() -> *mut FrameDecoder {
    Box::into_raw(Box::new(FrameDecoder::new()))
}

/// Frees a splitter. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_inspector_decoder_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_inspector_decoder_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_decoder_free(handle: *mut FrameDecoder) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from one `new` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Appends a freshly received chunk.
///
/// # Safety
/// `handle` must be live per [`held`]; `chunk` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_decoder_append(
    handle: *mut FrameDecoder,
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

/// The next complete frame, or [`INSPECTOR_PENDING`] when a whole one is not yet buffered.
///
/// The payload is copied into `body` and the record's `body_offset`/`body_length` point into THAT
/// buffer, so the caller reads an event's JSON straight out of it. Sizing is the caller's: a
/// payload cannot outrun what the splitter is holding, so one call always suffices.
///
/// A payload that arrives with too small a buffer answers [`INSPECTOR_TRUNCATED`] having consumed
/// the frame — which is the same in-band recovery a body that does not parse gets, and the reason
/// the caller sizes from `buffered` rather than guessing.
///
/// # Safety
/// `handle` must be live per [`held`]; `out` must be null or writable for one record; `body` must
/// be null or writable for `body_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_inspector_decoder_next(
    handle: *mut FrameDecoder,
    out: *mut SlopDeskInspectorFrame,
    body: *mut c_uchar,
    body_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(decoder) = held(handle) else {
            return INSPECTOR_TRUNCATED;
        };
        // Ask how long the payload is BEFORE consuming it: a frame read into a buffer too small for
        // it is a frame lost, and this splitter's whole contract is that a fault costs one frame
        // rather than the stream. The caller grows and calls again; the frame is still there. Only
        // that one case is answered from the peek — everything else goes through the read, which is
        // what compacts a drained buffer and reports a desync.
        if let Ok(Some(length)) = decoder.peek_payload_len()
            && (length > body_cap || body.is_null())
        {
            place(out, SlopDeskInspectorFrame {
                detail: length as u64,
                ..SlopDeskInspectorFrame::default()
            });
            return INSPECTOR_AGAIN;
        }
        match decoder.next_payload() {
            Ok(None) => INSPECTOR_PENDING,
            Ok(Some(payload)) => {
                let verdict = match decode_client(&payload) {
                    Ok(frame) => {
                        place(out, framed(&frame));
                        INSPECTOR_OK
                    },
                    Err(error) => {
                        let (verdict, detail) = fault(&error);
                        place(out, SlopDeskInspectorFrame {
                            detail,
                            ..SlopDeskInspectorFrame::default()
                        });
                        verdict
                    },
                };
                deliver(&payload, body, body_cap);
                verdict
            },
            Err(error) => {
                let (verdict, detail) = fault(&error);
                place(out, SlopDeskInspectorFrame {
                    detail,
                    ..SlopDeskInspectorFrame::default()
                });
                verdict
            },
        }
    }
}

// There is no `slopdesk_inspector_decoder_buffered`. It existed to let a Swift test assert that a
// drained decoder is empty, and no such test was ever written — `FrameDecoder::buffered_len` is
// asserted natively in `slopdesk-inspectord`, on the side that owns the buffer. A door held open
// for a test in the other language is the cross-language mirror fixture the rule bans.

/// The numbers this protocol is pinned to, by index.
///
/// | index | value |
/// | --- | --- |
/// | 0 | the frame payload cap |
/// | 1 | the length prefix's width |
/// | 2 | the client's outbound tag |
///
/// An unknown index answers `-1`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub extern "C" fn slopdesk_inspector_constant(index: u32) -> i64 {
    match index {
        0 => i64::try_from(MAX_FRAME_PAYLOAD).unwrap_or(i64::MAX),
        1 => i64::try_from(PREFIX_LENGTH).unwrap_or(i64::MAX),
        2 => 3,
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
        clippy::unwrap_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]
    use super::{
        INSPECTOR_AGAIN, INSPECTOR_FRAME_TOO_LARGE, INSPECTOR_OK, INSPECTOR_PENDING, INSPECTOR_TRUNCATED,
        INSPECTOR_UNKNOWN_TYPE, SlopDeskInspectorFrame, slopdesk_inspector_constant,
        slopdesk_inspector_decode_payload, slopdesk_inspector_decoder_append,
        slopdesk_inspector_decoder_free, slopdesk_inspector_decoder_new, slopdesk_inspector_decoder_next,
        slopdesk_inspector_encode_subscribe,
    };

    fn frame(tag: u8, body: &[u8]) -> Vec<u8> {
        let payload_len = u32::try_from(1 + body.len()).unwrap();
        let mut out = payload_len.to_be_bytes().to_vec();
        out.push(tag);
        out.extend_from_slice(body);
        out
    }

    #[test]
    fn a_subscribe_is_nine_bytes_of_tag_and_sequence() {
        let needed = unsafe { slopdesk_inspector_encode_subscribe(7, std::ptr::null_mut(), 0) };
        assert_eq!(needed, 13, "four prefix bytes, a tag and eight of sequence");
        let mut out = vec![0u8; needed];
        assert_eq!(
            unsafe { slopdesk_inspector_encode_subscribe(7, out.as_mut_ptr(), out.len()) },
            needed
        );
        assert_eq!(out, vec![0, 0, 0, 9, 3, 0, 0, 0, 0, 0, 0, 0, 7]);
    }

    #[test]
    fn a_payload_answers_where_its_body_is_without_copying_it() {
        let payload = [1u8, b'{', b'}'];
        let mut record = SlopDeskInspectorFrame::default();
        let verdict =
            unsafe { slopdesk_inspector_decode_payload(payload.as_ptr(), payload.len(), &raw mut record) };
        assert_eq!(verdict, INSPECTOR_OK);
        assert_eq!(record.tag, 1);
        assert_eq!(record.body_offset, 1);
        assert_eq!(record.body_length, 2);
    }

    #[test]
    fn the_clients_own_tag_is_not_readable_on_this_end() {
        let payload = [3u8, 0, 0, 0, 0, 0, 0, 0, 7];
        let mut record = SlopDeskInspectorFrame::default();
        let verdict =
            unsafe { slopdesk_inspector_decode_payload(payload.as_ptr(), payload.len(), &raw mut record) };
        assert_eq!(verdict, INSPECTOR_UNKNOWN_TYPE);
        assert_eq!(record.detail, 3);
    }

    #[test]
    fn an_empty_payload_is_truncated() {
        let mut record = SlopDeskInspectorFrame::default();
        let verdict = unsafe { slopdesk_inspector_decode_payload(std::ptr::null(), 0, &raw mut record) };
        assert_eq!(verdict, INSPECTOR_TRUNCATED);
    }

    #[test]
    fn the_splitter_reassembles_across_byte_boundaries() {
        let handle = unsafe { slopdesk_inspector_decoder_new() };
        let stream = [frame(1, b"{\"a\":1}"), frame(2, b"")].concat();
        let mut seen = Vec::new();
        for byte in &stream {
            unsafe { slopdesk_inspector_decoder_append(handle, byte, 1) };
            loop {
                // A fixed guess, not a size door: this is the §4 shape Swift uses, and the frames
                // this test feeds are far under it. An undersized call is covered by its own test.
                let mut body = vec![0u8; 64];
                let mut record = SlopDeskInspectorFrame::default();
                let verdict = unsafe {
                    slopdesk_inspector_decoder_next(handle, &raw mut record, body.as_mut_ptr(), body.len())
                };
                if verdict == INSPECTOR_PENDING {
                    break;
                }
                assert_eq!(verdict, INSPECTOR_OK);
                let start = record.body_offset as usize;
                let end = start + record.body_length as usize;
                seen.push((record.tag, body.get(start..end).unwrap().to_vec()));
            }
        }
        assert_eq!(seen, vec![(1, b"{\"a\":1}".to_vec()), (2, Vec::new())]);
        unsafe { slopdesk_inspector_decoder_free(handle) };
    }

    #[test]
    fn a_body_buffer_too_small_costs_nothing_and_says_how_much_it_needed() {
        let handle = unsafe { slopdesk_inspector_decoder_new() };
        let stream = frame(1, b"{\"a\":1}");
        unsafe { slopdesk_inspector_decoder_append(handle, stream.as_ptr(), stream.len()) };

        let mut record = SlopDeskInspectorFrame::default();
        let mut tiny = [0u8; 2];
        let verdict = unsafe {
            slopdesk_inspector_decoder_next(handle, &raw mut record, tiny.as_mut_ptr(), tiny.len())
        };
        assert_eq!(verdict, INSPECTOR_AGAIN);
        assert_eq!(record.detail, 8, "the tag plus seven bytes of body");

        // The frame is still there: growing and asking again reads it.
        let mut body = vec![0u8; usize::try_from(record.detail).unwrap()];
        let verdict = unsafe {
            slopdesk_inspector_decoder_next(handle, &raw mut record, body.as_mut_ptr(), body.len())
        };
        assert_eq!(verdict, INSPECTOR_OK);
        assert_eq!(record.tag, 1);
        let start = record.body_offset as usize;
        assert_eq!(
            body.get(start..start + record.body_length as usize).unwrap(),
            b"{\"a\":1}"
        );
        let verdict = unsafe {
            slopdesk_inspector_decoder_next(handle, &raw mut record, body.as_mut_ptr(), body.len())
        };
        assert_eq!(verdict, INSPECTOR_PENDING);
        // "a drained splitter has compacted its consumed head away" is asserted natively, on
        // `FrameDecoder::buffered_len` in `slopdesk-inspectord` — the side that owns the buffer.
        // Reaching for it through a C door existed only to let this line be written here.
        unsafe { slopdesk_inspector_decoder_free(handle) };
    }

    #[test]
    fn an_over_cap_prefix_is_a_framing_desync() {
        let handle = unsafe { slopdesk_inspector_decoder_new() };
        let too_big = u32::try_from(slopdesk_inspector_constant(0) + 1).unwrap();
        let prefix = too_big.to_be_bytes();
        unsafe { slopdesk_inspector_decoder_append(handle, prefix.as_ptr(), prefix.len()) };
        let mut record = SlopDeskInspectorFrame::default();
        let verdict =
            unsafe { slopdesk_inspector_decoder_next(handle, &raw mut record, std::ptr::null_mut(), 0) };
        assert_eq!(verdict, INSPECTOR_FRAME_TOO_LARGE);
        assert_eq!(record.detail, u64::from(too_big));
        unsafe { slopdesk_inspector_decoder_free(handle) };
    }

    #[test]
    fn the_constants_are_the_crates_own() {
        assert_eq!(slopdesk_inspector_constant(0), 16 * 1024 * 1024);
        assert_eq!(slopdesk_inspector_constant(1), 4);
        assert_eq!(slopdesk_inspector_constant(2), 3);
        assert_eq!(slopdesk_inspector_constant(9), -1);
    }
}
