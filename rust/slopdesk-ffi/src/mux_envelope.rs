//! The TCP mux envelope: `[u32 muxFrameLength][u32 channelID][u8 muxType][body…]`.
//!
//! Five frame types, one of which — [`MuxFrame::ChannelData`] — carries an inner terminal frame
//! verbatim and is what a flooding pane is made of. `rust/slopdesk-wire`'s `mux::envelope` owns the
//! layout; this is the door.
//!
//! ## Two address spaces, the same two as [`crate::wire_message`]
//! `cwd_*` is an offset into the ARENA, because an encode has to put the string somewhere. The
//! payload is an offset into the DATAGRAM, because it is the one field a copy is felt on: decoding
//! answers WHERE it sits and encoding takes it as its own argument.
//!
//! ## The verdicts
//! [`crate::wire_message`]'s `SLOPDESK_WIRE_DECODE_*`, unchanged — this envelope's faults are the
//! same three the terminal table has, and a caller that already maps them should not learn a second
//! set.

use core::ffi::c_uchar;
use core::ops::Range;

use slopdesk_wire::SESSION_ID_BYTE_COUNT;
use slopdesk_wire::mux::{MuxCloseReason, MuxFrame};

use crate::wire_message::{WIRE_DECODE_AGAIN, WIRE_DECODE_OK, verdict};
use crate::{arena_text, borrow, deliver, saturating_u32};

/// One mux envelope, flattened.
///
/// Every field is meaningful only for the arms that carry it; the rest are zero. `mux_type` says
/// which arm, and it is the wire's own type byte.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskMuxFrame {
    /// `channelOpen`: highest sequence number the initiator already holds.
    pub last_received_seq: i64,
    /// `channelOpenAck`: the host-authoritative resume verdict.
    pub resume_from_seq: i64,
    /// The logical channel this frame addresses.
    pub channel_id: u32,
    /// `windowAdjust`: flow-control credit being granted.
    pub bytes_to_add: u32,
    /// `channelOpen`: where the initial cwd sits in the ARENA.
    pub cwd_offset: u32,
    /// `channelOpen`: how long the initial cwd is.
    pub cwd_length: u32,
    /// `channelData`: where the payload sits in the DATAGRAM. Zero on the encode side, where the
    /// payload is its own argument.
    pub payload_offset: u32,
    /// `channelData`: how long the payload is.
    pub payload_length: u32,
    /// The wire's own mux-type byte.
    pub mux_type: u8,
    /// `channelOpen`: what the channel is FOR, carried raw so an unserved class is refused rather
    /// than failing the frame.
    pub channel_class: u8,
    /// `channelClose`: why the peer closed.
    pub reason: u8,
    /// `channelOpenAck`: whether the responder will service the channel.
    pub accepted: bool,
    /// `channelOpen`: whether the initiator had an opinion about the cwd at all. An ABSENT cwd is
    /// not a zero-length one — it is the field not being there, and it keeps the common open at 30
    /// bytes.
    pub has_cwd: bool,
    /// `channelOpen`: the session this channel belongs to; all-zero opens a new one.
    pub session_id: [u8; SESSION_ID_BYTE_COUNT],
}

/// Spreads a decoded frame onto the flat struct plus the text it interned.
pub(crate) fn pack(frame: &MuxFrame, run: &Range<usize>) -> (SlopDeskMuxFrame, Vec<u8>) {
    let mut flat = SlopDeskMuxFrame {
        channel_id: frame.channel_id(),
        mux_type: frame.mux_type().as_byte(),
        ..SlopDeskMuxFrame::default()
    };
    let mut arena = Vec::new();
    match *frame {
        MuxFrame::ChannelOpen {
            session_id,
            last_received_seq,
            channel_class,
            ref initial_cwd,
            ..
        } => {
            flat.session_id = session_id;
            flat.last_received_seq = last_received_seq;
            flat.channel_class = channel_class;
            if let Some(cwd) = initial_cwd.as_deref() {
                flat.has_cwd = true;
                flat.cwd_offset = 0;
                flat.cwd_length = saturating_u32(cwd.len());
                arena.extend_from_slice(cwd.as_bytes());
            }
        },
        MuxFrame::ChannelOpenAck {
            accepted,
            resume_from_seq,
            ..
        } => {
            flat.accepted = accepted;
            flat.resume_from_seq = resume_from_seq;
        },
        MuxFrame::ChannelData { .. } => {
            flat.payload_offset = saturating_u32(run.start);
            flat.payload_length = saturating_u32(run.len());
        },
        MuxFrame::ChannelClose { reason, .. } => flat.reason = reason.as_byte(),
        MuxFrame::WindowAdjust { bytes_to_add, .. } => flat.bytes_to_add = bytes_to_add,
    }
    (flat, arena)
}

/// Rebuilds a frame from the flat struct. `None` for a mux-type byte no arm answers to.
fn unpack(flat: &SlopDeskMuxFrame, arena: &[u8]) -> Option<MuxFrame> {
    let channel_id = flat.channel_id;
    match flat.mux_type {
        1 => {
            Some(MuxFrame::ChannelOpen {
                channel_id,
                session_id: flat.session_id,
                last_received_seq: flat.last_received_seq,
                channel_class: flat.channel_class,
                initial_cwd: flat
                    .has_cwd
                    .then(|| arena_text(arena, flat.cwd_offset, flat.cwd_length)),
            })
        },
        2 => {
            Some(MuxFrame::ChannelOpenAck {
                channel_id,
                accepted: flat.accepted,
                resume_from_seq: flat.resume_from_seq,
            })
        },
        3 => {
            Some(MuxFrame::ChannelData {
                channel_id,
                payload: Vec::new(),
            })
        },
        4 => {
            Some(MuxFrame::ChannelClose {
                channel_id,
                reason: MuxCloseReason::from_byte_or_retired(flat.reason),
            })
        },
        5 => {
            Some(MuxFrame::WindowAdjust {
                channel_id,
                bytes_to_add: flat.bytes_to_add,
            })
        },
        _ => None,
    }
}

/// Decodes one envelope from a COMPLETE inner run (`[channelID][muxType][body…]`, without the
/// length prefix — framing belongs to the mux frame decoder).
///
/// The payload is answered as an OFFSET into `inner`, never copied.
///
/// # Safety
/// `inner` must describe live memory for the call, `out` must be writable for one
/// [`SlopDeskMuxFrame`], and `arena` for `arena_cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_frame_decode(
    inner: *const c_uchar,
    inner_len: usize,
    out: *mut SlopDeskMuxFrame,
    arena: *mut c_uchar,
    arena_cap: usize,
) -> u32 {
    // SAFETY: the caller's obligations are this function's; `borrow` and `deliver` restate them.
    unsafe {
        let bytes = borrow(inner, inner_len);
        let (frame, run) = match MuxFrame::decode_leaving_payload(bytes) {
            Ok(decoded) => decoded,
            Err(error) => return verdict(&error),
        };
        let (flat, pool) = pack(&frame, &run);
        if pool.len() > arena_cap || out.is_null() {
            return WIRE_DECODE_AGAIN;
        }
        deliver(&pool, arena, arena_cap);
        out.write(flat);
        WIRE_DECODE_OK
    }
}

/// Encodes one envelope into a COMPLETE frame — the four-byte length prefix included.
///
/// `arena` holds the cwd the `cwd_*` span names; `payload` is the opaque run, passed whole because
/// it is the one field a copy would be felt on. Returns the byte count under the §4 convention.
///
/// # Safety
/// `frame` must point at one live struct, every input pair must describe live memory for the call,
/// and `out` must be writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_frame_encode(
    frame: *const SlopDeskMuxFrame,
    arena: *const c_uchar,
    arena_len: usize,
    payload: *const c_uchar,
    payload_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: one struct read, two borrows and one lent buffer, none outliving the call.
    unsafe {
        let arena = borrow(arena, arena_len);
        let payload = borrow(payload, payload_len);
        let Some(frame) = unpack(&*frame, arena) else {
            return 0;
        };
        let out = if out.is_null() || cap == 0 {
            &mut [][..]
        } else {
            core::slice::from_raw_parts_mut(out, cap)
        };
        frame.encode_with_payload_into(payload, out)
    }
}

/// The byte count [`slopdesk_mux_frame_encode`] would produce, WITHOUT building the frame.
///
/// # Safety
/// `frame` must point at one live struct and `arena` must describe live memory for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_mux_frame_byte_count(
    frame: *const SlopDeskMuxFrame,
    arena: *const c_uchar,
    arena_len: usize,
    payload_len: usize,
) -> usize {
    // SAFETY: one borrow and one struct read, neither outliving the call.
    unsafe {
        let arena = borrow(arena, arena_len);
        unpack(&*frame, arena).map_or(0, |frame| frame.encoded_byte_count_with_payload(payload_len))
    }
}

/// The sizes both ends would otherwise type: `0` the smallest legal `muxFrameLength`, `1` the
/// length prefix in front of it, `2` a session id's width. An index with no constant answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_mux_envelope_constant(index: u32) -> usize {
    match index {
        0 => slopdesk_wire::mux::MIN_MUX_FRAME_LENGTH,
        1 => slopdesk_wire::mux::PREFIX_LENGTH,
        2 => SESSION_ID_BYTE_COUNT,
        _ => 0,
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

    use slopdesk_wire::mux::{MuxCloseReason, MuxFrame};

    use super::{
        SlopDeskMuxFrame, pack, slopdesk_mux_frame_byte_count, slopdesk_mux_frame_decode,
        slopdesk_mux_frame_encode,
    };
    use crate::wire_message::WIRE_DECODE_OK;

    fn every_frame() -> Vec<MuxFrame> {
        vec![
            MuxFrame::ChannelOpen {
                channel_id: 9,
                session_id: [7; 16],
                last_received_seq: -1,
                channel_class: 1,
                initial_cwd: None,
            },
            MuxFrame::ChannelOpen {
                channel_id: 9,
                session_id: [7; 16],
                last_received_seq: 42,
                channel_class: 2,
                initial_cwd: Some("/Volumes/Lacie/Workspace".to_owned()),
            },
            MuxFrame::ChannelOpenAck {
                channel_id: 3,
                accepted: true,
                resume_from_seq: 4096,
            },
            MuxFrame::ChannelData {
                channel_id: 7,
                payload: (0..=255u8).cycle().take(4096).collect(),
            },
            MuxFrame::ChannelClose {
                channel_id: 2,
                reason: MuxCloseReason::SubscriberEvicted,
            },
            MuxFrame::WindowAdjust {
                channel_id: 5,
                bytes_to_add: 65_536,
            },
        ]
    }

    /// The boundary must not be able to change the bytes. For every arm, the frame this door
    /// produces is the frame the crate that owns the layout produces.
    #[test]
    fn the_envelope_is_byte_identical_to_the_crate_that_owns_the_layout() {
        for frame in every_frame() {
            let expected = frame.encode();
            let payload = frame.opaque_payload();
            let (flat, arena) = pack(&frame, &(0..payload.len()));
            let mut out = vec![0xAA; expected.len()];
            let written = unsafe {
                slopdesk_mux_frame_encode(
                    &raw const flat,
                    arena.as_ptr(),
                    arena.len(),
                    payload.as_ptr(),
                    payload.len(),
                    out.as_mut_ptr(),
                    out.len(),
                )
            };
            assert_eq!(written, expected.len(), "sized wrong for {frame:?}");
            assert_eq!(out, expected, "wrote differently for {frame:?}");

            let counted = unsafe {
                slopdesk_mux_frame_byte_count(&raw const flat, arena.as_ptr(), arena.len(), payload.len())
            };
            assert_eq!(counted, expected.len(), "counted wrong for {frame:?}");
        }
    }

    /// The payload crosses as a span into the caller's own datagram, so this is what proves the
    /// span names the right bytes rather than merely the right LENGTH.
    #[test]
    fn the_payload_is_a_span_into_the_datagram() {
        let payload: Vec<u8> = (0..=255u8).cycle().take(4096).collect();
        let bytes = MuxFrame::ChannelData {
            channel_id: 7,
            payload: payload.clone(),
        }
        .encode();
        let inner = &bytes[4..];

        let mut flat = SlopDeskMuxFrame::default();
        let mut arena = [0u8; 64];
        let answer = unsafe {
            slopdesk_mux_frame_decode(
                inner.as_ptr(),
                inner.len(),
                &raw mut flat,
                arena.as_mut_ptr(),
                arena.len(),
            )
        };
        assert_eq!(answer, WIRE_DECODE_OK);
        let start = flat.payload_offset as usize;
        let end = start + flat.payload_length as usize;
        assert_eq!(&inner[start..end], &payload[..]);
    }
}
