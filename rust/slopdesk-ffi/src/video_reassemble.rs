//! The client receive path: datagrams becoming frames, and where hostile UDP is parsed.
//!
//! [`slopdesk_video::reassembler::FrameReassembler`] buffers a frame's fragments by id, inverts the
//! data/parity boundary the tier implies, recovers holes through the erasure code, holds the
//! selective-ARQ requests, and sweeps frames that can no longer complete. One datagram in, one
//! verdict out.
//!
//! ## Why a handle
//! Because it is per-frame state that outlives every call by design: a frame is declared lost only
//! once a NEWER frame's fragments arrive while it still has a hole the code cannot fill, so the
//! reassembler has to remember what it has been shown. Copying that across per datagram would copy
//! the frame under construction — up to a whole IDR — thirty times per frame. [`crate::replay`]
//! documents the convention; the obligation is the same, one free per new and no overlapping calls.
//!
//! ## Why the header arrives as scalars
//! The caller has already decoded it. The client's router reads `frameID` and `hostSendTsMillis`
//! off every datagram for the one-way-delay telemetry before it decides where the datagram goes, so
//! handing the raw bytes over would mean decoding the same 19 bytes twice. Seven scalars and a
//! payload span cost less than that and say exactly what crosses.
//!
//! ## The slots
//! A verdict is a tag, and the detail behind it is parked:
//!
//! | slot | filled by | read with |
//! | --- | --- | --- |
//! | frame | `ingest` answering [`VERDICT_COMPLETED`] | `frame_id` / `frame_flags` / `frame_avcc` |
//! | dropped | `ingest` answering [`VERDICT_DROPPED`], and `next_dropped_frame` | `frame_id` / the out param |
//! | retransmit | `next_needs_retransmit` | `retransmit_frame_id` / `retransmit_frags` |
//!
//! The frame slot holds until the next `ingest` completes another frame, so a caller may read the
//! flags, size the AVCC and copy it out without anything in between.

use core::ffi::c_uchar;

use slopdesk_video::fec::ReedSolomonFec;
use slopdesk_video::fragment::{Flags, FrameFragment, FrameFragmentHeader};
use slopdesk_video::reassembler::{FrameReassembler, ReassembledFrame, ReassemblyResult};

use crate::{borrow, deliver};

/// More fragments are still needed; nothing to emit.
pub const VERDICT_INCOMPLETE: u32 = 0;
/// The frame is complete — the frame slot holds it.
pub const VERDICT_COMPLETED: u32 = 1;
/// The frame is unrecoverable — the dropped slot holds its id.
pub const VERDICT_DROPPED: u32 = 2;
/// The datagram belonged to a frame already finished, or was implausible.
pub const VERDICT_STALE: u32 = 3;

/// The completed frame is a keyframe (IDR).
pub const FRAME_KEYFRAME: u32 = 1 << 0;
/// The completed frame is a crisp near-lossless static refresh.
pub const FRAME_CRISP: u32 = 1 << 1;
/// A data hole existed and parity filled it — the `fecRecovered` telemetry numerator.
pub const FRAME_RECOVERED_VIA_FEC: u32 = 1 << 2;
/// The frame is a Long-Term Reference the client acks after a successful decode.
pub const FRAME_IS_LTR: u32 = 1 << 3;
/// The frame was encoded via `ForceLTRRefresh`, so it references only acked LTRs.
pub const FRAME_ACKED_ANCHORED: u32 = 1 << 4;

/// The bits [`slopdesk_video_reassembler_frame_flags`] packs, by index, so no caller respells one.
///
/// | index | bit |
/// | --- | --- |
/// | 0 | keyframe |
/// | 1 | crisp |
/// | 2 | recovered via FEC |
/// | 3 | is LTR |
/// | 4 | acked-anchored |
///
/// The word crosses as one `u32` and is taken apart on the far side, so a position the two sides
/// disagree about is a decoded frame described wrongly — an LTR the client never acks, or a
/// keyframe the pipeline treats as a delta. An unknown index answers `0`, which is no bit at all.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
#[must_use]
pub const extern "C" fn slopdesk_video_reassembler_frame_flag(index: u32) -> u32 {
    match index {
        0 => FRAME_KEYFRAME,
        1 => FRAME_CRISP,
        2 => FRAME_RECOVERED_VIA_FEC,
        3 => FRAME_IS_LTR,
        4 => FRAME_ACKED_ANCHORED,
        _ => 0,
    }
}

/// The opaque handle: the reassembler, plus the slots its verdicts are read out of.
#[derive(Debug)]
pub struct SlopDeskVideoReassembler {
    reassembler: FrameReassembler,
    /// The frame produced by the last completing `ingest`.
    frame: ReassembledFrame,
    /// The frame the last `next_needs_retransmit` asked for, and which of its fragments.
    retransmit: (u32, Vec<u16>),
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_video_reassembler_new`] that has not been freed,
/// and no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskVideoReassembler) -> Option<&'a mut SlopDeskVideoReassembler> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live, correctly aligned and unaliased for
    // this call — the Swift owner is one object per video stream, driven by one receive loop.
    Some(unsafe { &mut *handle })
}

/// Packs a completed frame's latched wire bits into the `frame_flags` word.
const fn frame_flags(frame: &ReassembledFrame) -> u32 {
    let mut bits = 0;
    if frame.keyframe {
        bits |= FRAME_KEYFRAME;
    }
    if frame.crisp {
        bits |= FRAME_CRISP;
    }
    if frame.recovered_via_fec {
        bits |= FRAME_RECOVERED_VIA_FEC;
    }
    if frame.is_ltr {
        bits |= FRAME_IS_LTR;
    }
    if frame.acked_anchored {
        bits |= FRAME_ACKED_ANCHORED;
    }
    bits
}

/// Builds a reassembler. `parity_count == 0` means no FEC: a hole is a lost frame.
///
/// Returns null for a shape the erasure code cannot exist in (`k + m > 255`, or a zero group size
/// with parity) — a caller bug, refused rather than panicked across the boundary.
///
/// # Safety
/// Nothing is borrowed: the parameters are values. The function is `unsafe` only because an
/// exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_new(
    group_size: usize,
    parity_count: usize,
    fec_reorder_grace: i32,
) -> *mut SlopDeskVideoReassembler {
    let fec = if parity_count == 0 {
        None
    } else if group_size >= 1 && group_size + parity_count <= 255 {
        Some(ReedSolomonFec::new(group_size, parity_count))
    } else {
        return core::ptr::null_mut();
    };
    Box::into_raw(Box::new(SlopDeskVideoReassembler {
        reassembler: FrameReassembler::new(fec, fec_reorder_grace),
        frame: ReassembledFrame::default(),
        retransmit: (0, Vec::new()),
    }))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_video_reassembler_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_video_reassembler_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_free(handle: *mut SlopDeskVideoReassembler) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_video_reassembler_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

/// Arms selective ARQ: a frame missing at most `max_frags` fragments is held for `grace` newer
/// frames and asked for by index instead of being declared lost.
///
/// # Safety
/// As [`held`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_enable_retransmit(
    handle: *mut SlopDeskVideoReassembler,
    grace: i32,
    max_frags: usize,
) {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    if let Some(held) = unsafe { held(handle) } {
        held.reassembler.enable_retransmit(grace, max_frags);
    }
}

/// Feeds one datagram and answers a `VERDICT_*` tag. The detail behind it is parked.
///
/// The header arrives as its seven fields because the caller has already decoded them; `payload` is
/// the datagram's bytes after the 19-byte header.
///
/// # Safety
/// As [`held`], plus: `payload` must be null or point to `payload_len` readable bytes for the whole
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_ingest(
    handle: *mut SlopDeskVideoReassembler,
    stream_seq: u32,
    frame_id: u32,
    frag_index: u16,
    frag_count: u16,
    flags: u8,
    host_send_ts_millis: u32,
    payload: *const c_uchar,
    payload_len: usize,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return VERDICT_STALE;
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`, whose scope is
    // exactly this call.
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
    match held
        .reassembler
        .ingest(FrameFragment::new(header, bytes.to_vec()))
    {
        ReassemblyResult::Incomplete => VERDICT_INCOMPLETE,
        ReassemblyResult::Completed(frame) => {
            held.frame = frame;
            VERDICT_COMPLETED
        },
        ReassemblyResult::Dropped { frame_id } => {
            held.frame = ReassembledFrame {
                frame_id,
                ..ReassembledFrame::default()
            };
            VERDICT_DROPPED
        },
        ReassemblyResult::Stale => VERDICT_STALE,
    }
}

/// The parked frame's id — the completed frame, or the dropped one.
///
/// # Safety
/// As [`held`]. A null handle answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_frame_id(handle: *mut SlopDeskVideoReassembler) -> u32 {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    unsafe { held(handle) }.map_or(0, |h| h.frame.frame_id)
}

/// The parked frame's latched wire bits — the `FRAME_*` word.
///
/// # Safety
/// As [`held`]. A null handle answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_frame_flags(
    handle: *mut SlopDeskVideoReassembler,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    unsafe { held(handle) }.map_or(0, |h| frame_flags(&h.frame))
}

/// Copies the parked frame's AVCC buffer out. Reading it never mutates the slot.
///
/// # Safety
/// As [`held`], plus: `out` must be null or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_frame_avcc(
    handle: *mut SlopDeskVideoReassembler,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&held.frame.avcc, out, cap) }
}

/// Takes the next selective-ARQ request, parking it. Answers how many fragments it names — 0 means
/// there is no request, which cannot be confused with one, since a request for nothing is not one.
///
/// # Safety
/// As [`held`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_next_needs_retransmit(
    handle: *mut SlopDeskVideoReassembler,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    // Cleared even when there is nothing, so a stale request can never be read back behind a 0.
    held.retransmit = held
        .reassembler
        .next_needs_retransmit()
        .unwrap_or((0, Vec::new()));
    held.retransmit.1.len()
}

/// The parked retransmit request's frame id.
///
/// # Safety
/// As [`held`]. A null handle answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_retransmit_frame_id(
    handle: *mut SlopDeskVideoReassembler,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    unsafe { held(handle) }.map_or(0, |h| h.retransmit.0)
}

/// Copies the parked request's fragment indices out, reporting the count either way.
///
/// # Safety
/// As [`held`], plus: `out` must be null or point to `cap` writable `u16`s for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_retransmit_frags(
    handle: *mut SlopDeskVideoReassembler,
    out: *mut u16,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    let frags = &held.retransmit.1;
    if out.is_null() || cap < frags.len() {
        return frags.len();
    }
    for (at, &frag) in frags.iter().enumerate() {
        // SAFETY: `at` is below `frags.len()`, which the guard above put at or below `cap`, and the
        // caller's obligation is `cap` writable `u16`s — so every write lands inside the buffer.
        unsafe { out.add(at).write(frag) };
    }
    frags.len()
}

/// Takes the next frame the loss sweep abandoned, writing its id through `out`.
///
/// Answers `false` when there is none, which is why the id is an out param rather than the return:
/// every `u32` is a legal frame id, so no value could have meant "none".
///
/// # Safety
/// As [`held`], plus: `out` must be null or point to one writable `u32` for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_reassembler_next_dropped_frame(
    handle: *mut SlopDeskVideoReassembler,
    out: *mut u32,
) -> bool {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return false;
    };
    let Some(frame_id) = held.reassembler.next_dropped_frame() else {
        return false;
    };
    if !out.is_null() {
        // SAFETY: non-null and, by the caller's obligation, one writable, aligned `u32` — Swift
        // passes the address of a local `UInt32`.
        unsafe { out.write(frame_id) };
    }
    true
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the boundary IS what these tests are for")]
mod tests {
    use slopdesk_video::packetizer::{PacketizeOptions, VideoPacketizer};

    use super::*;

    /// Feeds one already-decoded fragment across the boundary.
    fn ingest(handle: *mut SlopDeskVideoReassembler, fragment: &FrameFragment) -> u32 {
        unsafe {
            slopdesk_video_reassembler_ingest(
                handle,
                fragment.header.stream_seq,
                fragment.header.frame_id,
                fragment.header.frag_index,
                fragment.header.frag_count,
                fragment.header.flags.bits(),
                fragment.header.host_send_ts_millis,
                fragment.payload.as_ptr(),
                fragment.payload.len(),
            )
        }
    }

    /// Reads the parked frame's AVCC out.
    fn avcc(handle: *mut SlopDeskVideoReassembler) -> Vec<u8> {
        let needed = unsafe { slopdesk_video_reassembler_frame_avcc(handle, core::ptr::null_mut(), 0) };
        let mut buffer = vec![0_u8; needed];
        let written =
            unsafe { slopdesk_video_reassembler_frame_avcc(handle, buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, needed, "the length must not move between the two calls");
        buffer
    }

    fn fragments(frame: &[u8], m: usize, tier: u8) -> Vec<FrameFragment> {
        VideoPacketizer::new(Some(ReedSolomonFec::new(8, m))).packetize(frame, PacketizeOptions {
            keyframe: true,
            fec_tier: tier,
            is_ltr: true,
            ..PacketizeOptions::default()
        })
    }

    #[test]
    fn a_clean_frame_comes_back_byte_for_byte() {
        let frame: Vec<u8> = (0..30_000_u32).map(|i| (i % 251) as u8).collect();
        let handle = unsafe { slopdesk_video_reassembler_new(8, 1, 2) };
        let mut completed = 0;
        for fragment in fragments(&frame, 1, 0) {
            if ingest(handle, &fragment) == VERDICT_COMPLETED {
                completed += 1;
                assert_eq!(avcc(handle), frame);
                let flags = unsafe { slopdesk_video_reassembler_frame_flags(handle) };
                assert_eq!(flags & FRAME_KEYFRAME, FRAME_KEYFRAME);
                assert_eq!(flags & FRAME_IS_LTR, FRAME_IS_LTR);
                assert_eq!(flags & FRAME_RECOVERED_VIA_FEC, 0, "nothing was lost");
                assert_eq!(unsafe { slopdesk_video_reassembler_frame_id(handle) }, 0);
            }
        }
        assert_eq!(completed, 1);
        unsafe { slopdesk_video_reassembler_free(handle) };
    }

    #[test]
    fn a_hole_the_parity_closes_is_reported_as_recovered() {
        let frame: Vec<u8> = (0..20_000_u32).map(|i| (i % 199) as u8).collect();
        let handle = unsafe { slopdesk_video_reassembler_new(8, 1, 2) };
        let mut completed = false;
        for (at, fragment) in fragments(&frame, 1, 0).iter().enumerate() {
            if at == 3 {
                continue; // one data fragment lost in flight
            }
            if ingest(handle, fragment) == VERDICT_COMPLETED {
                completed = true;
                assert_eq!(avcc(handle), frame);
                let flags = unsafe { slopdesk_video_reassembler_frame_flags(handle) };
                assert_eq!(flags & FRAME_RECOVERED_VIA_FEC, FRAME_RECOVERED_VIA_FEC);
            }
        }
        assert!(completed, "the parity closed the hole");
        unsafe { slopdesk_video_reassembler_free(handle) };
    }

    #[test]
    fn a_frame_beyond_the_codes_reach_is_dropped_and_named() {
        let frame: Vec<u8> = (0..20_000_u32).map(|i| (i % 197) as u8).collect();
        let handle = unsafe { slopdesk_video_reassembler_new(8, 1, 0) };
        // Two holes in one group is one more than a single parity can close.
        for (at, fragment) in fragments(&frame, 1, 0).iter().enumerate() {
            if at == 1 || at == 2 {
                continue;
            }
            ingest(handle, fragment);
        }
        // The sweep declares it only once a NEWER frame is seen, which is what the second frame is.
        let mut dropped = None;
        let mut next = VideoPacketizer::new(Some(ReedSolomonFec::new(8, 1)));
        next.packetize(&frame, PacketizeOptions::default()); // burn frame id 0
        for fragment in next.packetize(&frame, PacketizeOptions::default()) {
            if ingest(handle, &fragment) == VERDICT_DROPPED {
                dropped = Some(unsafe { slopdesk_video_reassembler_frame_id(handle) });
            }
        }
        let mut swept = 0_u32;
        let had = unsafe { slopdesk_video_reassembler_next_dropped_frame(handle, &raw mut swept) };
        assert!(
            dropped.is_some() || had,
            "the lost frame is named one way or the other"
        );
        unsafe { slopdesk_video_reassembler_free(handle) };
    }

    #[test]
    fn a_short_buffer_is_told_what_it_needs_and_nothing_is_written() {
        let frame = vec![7_u8; 9_000];
        let handle = unsafe { slopdesk_video_reassembler_new(8, 1, 2) };
        for fragment in fragments(&frame, 1, 0) {
            ingest(handle, &fragment);
        }
        let needed = unsafe { slopdesk_video_reassembler_frame_avcc(handle, core::ptr::null_mut(), 0) };
        assert_eq!(needed, frame.len());
        let mut small = vec![0_u8; needed - 1];
        let asked = unsafe { slopdesk_video_reassembler_frame_avcc(handle, small.as_mut_ptr(), small.len()) };
        assert_eq!(asked, needed);
        assert!(small.iter().all(|&b| b == 0));
        unsafe { slopdesk_video_reassembler_free(handle) };
    }

    #[test]
    fn a_null_handle_answers_rather_than_crashing() {
        let null = core::ptr::null_mut();
        assert_eq!(
            unsafe { slopdesk_video_reassembler_ingest(null, 0, 0, 0, 1, 0, 0, core::ptr::null(), 0) },
            VERDICT_STALE,
        );
        assert_eq!(unsafe { slopdesk_video_reassembler_frame_id(null) }, 0);
        assert_eq!(unsafe { slopdesk_video_reassembler_frame_flags(null) }, 0);
        assert_eq!(
            unsafe { slopdesk_video_reassembler_next_needs_retransmit(null) },
            0
        );
        assert!(!unsafe { slopdesk_video_reassembler_next_dropped_frame(null, core::ptr::null_mut()) });
        unsafe { slopdesk_video_reassembler_free(null) };
    }

    #[test]
    fn an_impossible_shape_is_refused_rather_than_panicked() {
        assert!(unsafe { slopdesk_video_reassembler_new(250, 250, 2) }.is_null());
        assert!(unsafe { slopdesk_video_reassembler_new(0, 1, 2) }.is_null());
    }

    /// The flag door answers the same bits `frame_flags` packs, so the caller that takes the word
    /// apart never respells a position.
    #[test]
    fn the_exported_flag_bits_are_the_ones_frame_flags_packs() {
        assert_eq!(slopdesk_video_reassembler_frame_flag(0), FRAME_KEYFRAME);
        assert_eq!(slopdesk_video_reassembler_frame_flag(1), FRAME_CRISP);
        assert_eq!(slopdesk_video_reassembler_frame_flag(2), FRAME_RECOVERED_VIA_FEC);
        assert_eq!(slopdesk_video_reassembler_frame_flag(3), FRAME_IS_LTR);
        assert_eq!(slopdesk_video_reassembler_frame_flag(4), FRAME_ACKED_ANCHORED);
        assert_eq!(
            slopdesk_video_reassembler_frame_flag(5),
            0,
            "an unknown index is no bit"
        );
    }
}
