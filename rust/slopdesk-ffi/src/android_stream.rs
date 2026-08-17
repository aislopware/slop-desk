//! The scrcpy stream's client end — a stateful reassembler, held across calls.
//!
//! `slopdesk_androidd::stream` owns the framing. This is the door, and it is the same handle shape
//! `slopdesk_inspector_decoder_*` uses for the same reason: a byte stream cannot be reassembled by
//! a pure function, because the half-message left over from one `recv` is what the next one
//! completes. The alternative — Swift holding the buffer and Rust parsing one message at a time —
//! puts the state back on the side that was supposed to stop holding it.
//!
//! ## Why the client end is not Swift
//! `crate::screen`'s reason. The bridge relays the stream verbatim, so nothing in Rust had ever
//! read it and the whole decoder lived in `AndroidStreamProtocol.swift` — over bytes a DEVICE
//! wrote, on the per-frame path, with a buffer that copied its own remainder on every message.
//!
//! ## Sizing, and why `AGAIN` exists
//! An access unit is most of a frame, so the §4 measure-then-fill retry would cost a parse per
//! frame if the answer were thrown away. Instead the door PEEKS: a payload that does not fit is
//! answered [`ANDROID_STREAM_AGAIN`] with the needed length, having consumed nothing, so the caller
//! grows once and the message is still there. Steady state is one call per message, because the
//! caller keeps the buffer it grew.
//!
//! There is deliberately no "how much is buffered" door. `slopdesk_inspector_decoder_buffered` and
//! `slopdesk_frame_decoder_buffered` exist because a caller there sizes from the backlog; here the
//! `AGAIN` record already carries the EXACT length, and an upper bound would only tempt a caller
//! into allocating the whole backlog once per frame.

use core::ffi::c_uchar;

use slopdesk_androidd::stream::{Message, StreamParser};
use slopdesk_video::bytes::truncating_u32;

use crate::{borrow, deliver};

/// A whole message was read.
pub const ANDROID_STREAM_OK: u32 = 0;
/// No whole message is buffered yet — the ordinary answer between packets.
pub const ANDROID_STREAM_PENDING: u32 = 1;
/// The stream said something impossible and no further byte will be read from it. Terminal: a
/// desynchronised stream has no start marker to resynchronise on, so the connection is redialled.
pub const ANDROID_STREAM_CORRUPT: u32 = 2;
/// The payload does not fit `body`. `payload_len` carries what it needs, and NOTHING was consumed.
pub const ANDROID_STREAM_AGAIN: u32 = 5;

/// [`SlopDeskAndroidStreamMessage::kind`] — no message; the field block is not live.
pub const ANDROID_STREAM_KIND_NONE: u8 = 0;
/// The stream's codec name, in `body`. Sent once, at the head.
pub const ANDROID_STREAM_KIND_CODEC: u8 = 1;
/// A video size, in `width`/`height`. No payload.
pub const ANDROID_STREAM_KIND_SESSION: u8 = 2;
/// Parameter sets in Annex-B, in `body`.
pub const ANDROID_STREAM_KIND_CONFIGURATION: u8 = 3;
/// One access unit in Annex-B, in `body`.
pub const ANDROID_STREAM_KIND_ACCESS_UNIT: u8 = 4;

/// What one message said, minus its bytes.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SlopDeskAndroidStreamMessage {
    /// One of the `ANDROID_STREAM_KIND_*` constants.
    pub kind: u8,
    /// Whether the device marked this access unit a key frame. `false` for every other kind.
    pub is_keyframe: bool,
    /// Pixels across, live only for a session message.
    pub width: u32,
    /// Pixels down, live only for a session message.
    pub height: u32,
    /// Bytes written into `body` — or, under [`ANDROID_STREAM_AGAIN`], bytes it would need.
    pub payload_len: u32,
}

/// Builds a parser at the head of a fresh stream.
///
/// # Safety
/// Nothing is borrowed. The function is `unsafe` only because an exported C entry point is, in
/// edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_stream_new() -> *mut StreamParser {
    Box::into_raw(Box::new(StreamParser::new()))
}

/// Frees a parser. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_android_stream_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_android_stream_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_stream_free(handle: *mut StreamParser) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this came from one `new` and has not been freed.
    drop(unsafe { Box::from_raw(handle) });
}

/// Writes a record through the caller's out-pointer, if it gave one.
///
/// # Safety
/// `out` must be null or writable and aligned for one record for the call.
#[expect(
    unsafe_code,
    reason = "writing through the caller's pointer IS the boundary this module documents"
)]
const unsafe fn place(out: *mut SlopDeskAndroidStreamMessage, record: SlopDeskAndroidStreamMessage) {
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, writable and aligned for one record.
        unsafe { out.write(record) };
    }
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_android_stream_new`] that has not been freed,
/// and no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut StreamParser) -> Option<&'a mut StreamParser> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live and unaliased for this call — the
    // Swift owner is one parser per mirror session, driven by one receive loop.
    Some(unsafe { &mut *handle })
}

/// Appends a freshly received chunk. A corrupt parser ignores it.
///
/// # Safety
/// `handle` must be live per [`held`]; `chunk` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_stream_append(
    handle: *mut StreamParser,
    chunk: *const c_uchar,
    chunk_len: usize,
) {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        if let Some(parser) = held(handle) {
            parser.append(borrow(chunk, chunk_len));
        }
    }
}

/// The next complete message, or a verdict saying why there is none.
///
/// `out` is written for every verdict except [`ANDROID_STREAM_PENDING`], so a caller reads
/// `payload_len` after an [`ANDROID_STREAM_AGAIN`] to learn what to allocate.
///
/// # Safety
/// `handle` must be live per [`held`]; `out` must be null or writable for one message record;
/// `body` must be null or writable for `body_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_stream_next(
    handle: *mut StreamParser,
    out: *mut SlopDeskAndroidStreamMessage,
    body: *mut c_uchar,
    body_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's.
    unsafe {
        let Some(parser) = held(handle) else {
            return ANDROID_STREAM_CORRUPT;
        };
        // Ask how long the payload is BEFORE consuming it. A message read into a buffer too small
        // for it is a message LOST, and this parser's whole contract is that the stream survives a
        // caller's bad guess: the caller grows and calls again with the message still there.
        match parser.peek_payload_len() {
            None if parser.is_corrupt() => {
                place(out, SlopDeskAndroidStreamMessage::default());
                return ANDROID_STREAM_CORRUPT;
            },
            None => return ANDROID_STREAM_PENDING,
            Some(length) if length > body_cap || (length > 0 && body.is_null()) => {
                place(out, SlopDeskAndroidStreamMessage {
                    payload_len: truncating_u32(length),
                    ..SlopDeskAndroidStreamMessage::default()
                });
                return ANDROID_STREAM_AGAIN;
            },
            Some(_) => {},
        }
        let Some(message) = parser.next_message() else {
            // Unreachable through the peek above, which already said a whole message is there.
            place(out, SlopDeskAndroidStreamMessage::default());
            return ANDROID_STREAM_PENDING;
        };
        let (record, payload) = describe(message);
        place(out, record);
        deliver(&payload, body, body_cap);
        ANDROID_STREAM_OK
    }
}

/// Splits one message into the record that crosses and the bytes that follow it.
fn describe(message: Message) -> (SlopDeskAndroidStreamMessage, Vec<u8>) {
    match message {
        Message::Codec(name) => {
            (
                SlopDeskAndroidStreamMessage {
                    kind: ANDROID_STREAM_KIND_CODEC,
                    payload_len: truncating_u32(name.len()),
                    ..SlopDeskAndroidStreamMessage::default()
                },
                name.into_bytes(),
            )
        },
        Message::Session { width, height } => {
            (
                SlopDeskAndroidStreamMessage {
                    kind: ANDROID_STREAM_KIND_SESSION,
                    width,
                    height,
                    ..SlopDeskAndroidStreamMessage::default()
                },
                Vec::new(),
            )
        },
        Message::Configuration(payload) => {
            (
                SlopDeskAndroidStreamMessage {
                    kind: ANDROID_STREAM_KIND_CONFIGURATION,
                    payload_len: truncating_u32(payload.len()),
                    ..SlopDeskAndroidStreamMessage::default()
                },
                payload,
            )
        },
        Message::AccessUnit { payload, is_keyframe } => {
            (
                SlopDeskAndroidStreamMessage {
                    kind: ANDROID_STREAM_KIND_ACCESS_UNIT,
                    is_keyframe,
                    payload_len: truncating_u32(payload.len()),
                    ..SlopDeskAndroidStreamMessage::default()
                },
                payload,
            )
        },
    }
}

/// Whether a stream identifier names a codec the PANEL can decode.
///
/// Narrower than the daemon's own `Codec::parse`, which knows AV1 too: a decode session gains AV1
/// only on M3-class hardware and later, so offering it would make the panel's ability to show
/// anything depend on which Mac the client is running.
///
/// # Safety
/// `identifier` must be null or point to `len` live bytes for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_android_stream_decodable_codec(
    identifier: *const c_uchar,
    len: usize,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let bytes = unsafe { borrow(identifier, len) };
    core::str::from_utf8(bytes).is_ok_and(|name| slopdesk_androidd::stream::decodable_codec(name).is_some())
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::indexing_slicing,
    reason = "calling the boundary IS what these tests are for, and a fixed offset into a frame the test \
              just built is the assertion"
)]
mod tests {
    use super::{
        ANDROID_STREAM_AGAIN, ANDROID_STREAM_CORRUPT, ANDROID_STREAM_KIND_ACCESS_UNIT,
        ANDROID_STREAM_KIND_CODEC, ANDROID_STREAM_KIND_SESSION, ANDROID_STREAM_OK, ANDROID_STREAM_PENDING,
        SlopDeskAndroidStreamMessage, slopdesk_android_stream_append,
        slopdesk_android_stream_decodable_codec, slopdesk_android_stream_free, slopdesk_android_stream_new,
        slopdesk_android_stream_next,
    };

    /// Feeds a chunk and reads one message with a generous buffer.
    fn step(
        handle: *mut slopdesk_androidd::stream::StreamParser,
        chunk: &[u8],
        body: &mut [u8],
    ) -> (u32, SlopDeskAndroidStreamMessage) {
        // SAFETY: the handle is live for the test and every buffer is a live local.
        unsafe {
            slopdesk_android_stream_append(handle, chunk.as_ptr(), chunk.len());
            let mut record = SlopDeskAndroidStreamMessage::default();
            let verdict =
                slopdesk_android_stream_next(handle, &raw mut record, body.as_mut_ptr(), body.len());
            (verdict, record)
        }
    }

    /// The whole trip: codec, geometry, a key frame — and the handle freed exactly once.
    #[test]
    fn a_stream_crosses_message_by_message() {
        // SAFETY: nothing is borrowed by `new`.
        let handle = unsafe { slopdesk_android_stream_new() };
        let mut body = [0_u8; 64];

        let (verdict, record) = step(handle, b"h264", &mut body);
        assert_eq!(verdict, ANDROID_STREAM_OK);
        assert_eq!(record.kind, ANDROID_STREAM_KIND_CODEC);
        assert_eq!(&body[..record.payload_len as usize], b"h264");

        let mut session = vec![0x80, 0, 0, 0];
        session.extend_from_slice(&1080_u32.to_be_bytes());
        session.extend_from_slice(&2400_u32.to_be_bytes());
        let (verdict, record) = step(handle, &session, &mut body);
        assert_eq!(verdict, ANDROID_STREAM_OK);
        assert_eq!(record.kind, ANDROID_STREAM_KIND_SESSION);
        assert_eq!((record.width, record.height), (1080, 2400));

        let mut frame = vec![0x20, 0, 0, 0, 0, 0, 0, 0];
        frame.extend_from_slice(&3_u32.to_be_bytes());
        frame.extend_from_slice(&[1, 2, 3]);
        let (verdict, record) = step(handle, &frame, &mut body);
        assert_eq!(verdict, ANDROID_STREAM_OK);
        assert_eq!(record.kind, ANDROID_STREAM_KIND_ACCESS_UNIT);
        assert!(record.is_keyframe);
        assert_eq!(&body[..record.payload_len as usize], &[1, 2, 3]);

        // SAFETY: one `new`, freed once.
        unsafe { slopdesk_android_stream_free(handle) };
    }

    /// A half-arrived packet is `PENDING`, not a short read.
    #[test]
    fn an_incomplete_packet_is_pending() {
        // SAFETY: nothing is borrowed by `new`.
        let handle = unsafe { slopdesk_android_stream_new() };
        let mut body = [0_u8; 16];
        assert_eq!(step(handle, b"h264", &mut body).0, ANDROID_STREAM_OK);
        assert_eq!(step(handle, &[0x20, 0, 0], &mut body).0, ANDROID_STREAM_PENDING);
        // SAFETY: one `new`, freed once.
        unsafe { slopdesk_android_stream_free(handle) };
    }

    /// The retry contract: too small a buffer costs a call, never the message.
    #[test]
    fn a_payload_that_does_not_fit_is_still_there_afterwards() {
        // SAFETY: nothing is borrowed by `new`.
        let handle = unsafe { slopdesk_android_stream_new() };
        let mut small = [0_u8; 2];
        assert_eq!(step(handle, b"h264", &mut small).0, ANDROID_STREAM_AGAIN);

        let mut room = [0_u8; 8];
        // SAFETY: the handle is live and the buffer is a live local.
        let (verdict, record) = unsafe {
            let mut record = SlopDeskAndroidStreamMessage::default();
            let verdict =
                slopdesk_android_stream_next(handle, &raw mut record, room.as_mut_ptr(), room.len());
            (verdict, record)
        };
        assert_eq!(verdict, ANDROID_STREAM_OK, "the message survived the bad guess");
        assert_eq!(&room[..record.payload_len as usize], b"h264");
        // SAFETY: one `new`, freed once.
        unsafe { slopdesk_android_stream_free(handle) };
    }

    /// A desync is terminal and says so, rather than going quiet.
    #[test]
    fn a_corrupt_stream_is_named_and_stays_named() {
        // SAFETY: nothing is borrowed by `new`.
        let handle = unsafe { slopdesk_android_stream_new() };
        let mut body = [0_u8; 16];
        assert_eq!(step(handle, &[0, 0, 0, 0], &mut body).0, ANDROID_STREAM_CORRUPT);
        assert_eq!(
            step(handle, &[0x20, 0, 0, 0], &mut body).0,
            ANDROID_STREAM_CORRUPT
        );
        // SAFETY: one `new`, freed once.
        unsafe { slopdesk_android_stream_free(handle) };
    }

    /// Null is a no-op rather than a crash, which is what a Swift `deinit` on a failed init needs.
    #[test]
    fn freeing_null_is_a_no_op() {
        // SAFETY: null is the documented no-op.
        unsafe { slopdesk_android_stream_free(core::ptr::null_mut()) };
    }

    #[test]
    fn only_the_two_decodable_codecs_are_accepted() {
        for (name, expected) in [("h264", true), ("h265", true), ("av1", false), ("vp9", false)] {
            let bytes = name.as_bytes();
            // SAFETY: the identifier is a live local.
            let answer = unsafe { slopdesk_android_stream_decodable_codec(bytes.as_ptr(), bytes.len()) };
            assert_eq!(answer, expected, "{name}");
        }
    }
}
