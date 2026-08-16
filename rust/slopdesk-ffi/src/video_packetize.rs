//! The host send path's one CPU-heavy stretch: an encoded frame becoming wire datagrams.
//!
//! [`slopdesk_video::packetizer::VideoPacketizer`] does the MTU split, picks the per-frame FEC
//! shape off the tier ladder, computes the parity, optionally interleaves, and stamps the 19-byte
//! header on every datagram. What crosses here is one frame in and one flattened list of finished
//! datagrams out.
//!
//! ## Why a handle and not a function
//! Two counters. `streamSeq` advances once per datagram and `frameID` once per frame, and the host
//! reads `frameID` BEFORE packetizing so it can record the frame's LTR token against the id the
//! frame is about to carry. Passing both in and out per call would work, but it would also mean two
//! sides can disagree about who advanced them; the handle makes that unrepresentable. This is the
//! same convention [`crate::replay`] documents, and the obligation is the same one: exactly one
//! free per new, and no two calls on one handle may overlap.
//!
//! ## Why the answer is held, not returned
//! The `(out, cap) -> needed` convention wants the caller to size its buffer, but the answer's size
//! is exactly what the tier ladder decides — how many parity fragments a tier adds is the logic
//! being called. So [`slopdesk_video_packetizer_raw`] packetizes, parks the flattened list on the
//! handle, and returns its length; [`slopdesk_video_packetizer_answer`] copies it out. The frame is
//! packetized once and the counters advance once, whatever the caller's buffer turns out to be.
//!
//! ## The answer's shape
//! [`slopdesk_video::blob_list`] — `u32 count | (u32 len | bytes)…`, big-endian, every blob
//! present. Send order: data fragments then parity, or the interleaved order when the caller asked
//! for it.

use core::ffi::c_uchar;

use slopdesk_video::blob_list;
use slopdesk_video::fec::ReedSolomonFec;
use slopdesk_video::packetizer::{PacketizeOptions, VideoPacketizer};

use crate::{borrow, deliver};

/// `keyframe` — the IDR flag.
pub const FLAG_KEYFRAME: u32 = 1 << 0;
/// `crisp` — the near-lossless static refresh flag.
pub const FLAG_CRISP: u32 = 1 << 1;
/// `isLTR` — this frame is a Long-Term Reference and the client acks it after decode.
pub const FLAG_IS_LTR: u32 = 1 << 2;
/// `ackedAnchored` — this frame is a `ForceLTRRefresh` product.
pub const FLAG_ACKED_ANCHORED: u32 = 1 << 3;
/// `interleave` — run the burst-resilient transmit reorder.
pub const FLAG_INTERLEAVE: u32 = 1 << 4;

/// The opaque handle: the packetizer, plus the one slot its answer is read out of.
#[derive(Debug)]
pub struct SlopDeskVideoPacketizer {
    packetizer: VideoPacketizer,
    /// The flattened datagram list produced by the last `raw` call.
    answer: Vec<u8>,
}

/// Turns a caller's handle pointer into a reference for the duration of one call.
///
/// # Safety
/// `handle` must be a live pointer from [`slopdesk_video_packetizer_new`] that has not been freed,
/// and no other call on it may overlap this one.
#[expect(
    unsafe_code,
    reason = "reconstituting the handle IS the boundary this module documents"
)]
unsafe fn held<'a>(handle: *mut SlopDeskVideoPacketizer) -> Option<&'a mut SlopDeskVideoPacketizer> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: non-null and, by the caller's obligation, live, correctly aligned and unaliased for
    // this call — the Swift owner is one object per send loop, serialised by the session actor.
    Some(unsafe { &mut *handle })
}

/// Builds a packetizer. `parity_count == 0` sends data fragments only, with no FEC at all.
///
/// Returns null only if `group_size`/`parity_count` are a shape the code cannot exist in
/// (`k + m > 255`, or a zero group with a non-zero parity) — a caller bug, refused rather than
/// panicked across the boundary.
///
/// # Safety
/// Nothing is borrowed: the parameters are values. The function is `unsafe` only because an
/// exported C entry point is, in edition 2024.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_packetizer_new(
    group_size: usize,
    parity_count: usize,
) -> *mut SlopDeskVideoPacketizer {
    let fec = if parity_count == 0 {
        None
    } else if group_size >= 1 && group_size + parity_count <= 255 {
        Some(ReedSolomonFec::new(group_size, parity_count))
    } else {
        return core::ptr::null_mut();
    };
    Box::into_raw(Box::new(SlopDeskVideoPacketizer {
        packetizer: VideoPacketizer::new(fec),
        answer: Vec::new(),
    }))
}

/// Frees a handle. Null is a no-op; anything else must come from exactly one
/// [`slopdesk_video_packetizer_new`] and be freed exactly once.
///
/// # Safety
/// `handle` must be null, or a live pointer from [`slopdesk_video_packetizer_new`] not yet freed,
/// with no other call on it in flight.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_packetizer_free(handle: *mut SlopDeskVideoPacketizer) {
    if handle.is_null() {
        return;
    }
    // SAFETY: by the caller's obligation this pointer came from `Box::into_raw` in
    // `slopdesk_video_packetizer_new` and has not been freed, so reclaiming the box is sound.
    drop(unsafe { Box::from_raw(handle) });
}

/// The `frameID` the next [`slopdesk_video_packetizer_raw`] will assign. Pure read.
///
/// # Safety
/// As [`held`]. A null handle answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_packetizer_peek_frame_id(
    handle: *mut SlopDeskVideoPacketizer,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    unsafe { held(handle) }.map_or(0, |h| h.packetizer.peek_next_frame_id())
}

/// The `streamSeq` the next emitted datagram will carry. Pure read.
///
/// # Safety
/// As [`held`]. A null handle answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_packetizer_peek_stream_seq(
    handle: *mut SlopDeskVideoPacketizer,
) -> u32 {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    unsafe { held(handle) }.map_or(0, |h| h.packetizer.peek_next_stream_seq())
}

/// Packetizes one frame and parks the flattened datagram list on the handle.
///
/// Returns the parked answer's length in bytes — what [`slopdesk_video_packetizer_answer`] needs.
/// The counters advance exactly once here, whatever the caller then does with the answer.
///
/// # Safety
/// As [`held`], plus: `frame` must be null or point to `frame_len` readable bytes for the whole
/// call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_packetizer_raw(
    handle: *mut SlopDeskVideoPacketizer,
    frame: *const c_uchar,
    frame_len: usize,
    host_send_ts_millis: u32,
    fec_tier: u8,
    flags: u32,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation, discharged by Swift's `withUnsafeBytes`, whose scope is
    // exactly this call.
    let bytes = unsafe { borrow(frame, frame_len) };
    let options = PacketizeOptions {
        keyframe: flags & FLAG_KEYFRAME != 0,
        crisp: flags & FLAG_CRISP != 0,
        host_send_ts_millis,
        fec_tier,
        is_ltr: flags & FLAG_IS_LTR != 0,
        acked_anchored: flags & FLAG_ACKED_ANCHORED != 0,
        interleave: flags & FLAG_INTERLEAVE != 0,
    };
    let datagrams = held.packetizer.packetize_raw(bytes, options);
    held.answer = blob_list::encode_all(&datagrams);
    held.answer.len()
}

/// Copies the parked answer out. Reading it never mutates the slot, so a caller may take the
/// length, allocate, and copy without holding anything in between.
///
/// # Safety
/// As [`held`], plus: `out` must be null or point to `cap` writable bytes for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_video_packetizer_answer(
    handle: *mut SlopDeskVideoPacketizer,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, discharged by the Swift owner.
    let Some(held) = (unsafe { held(handle) }) else {
        return 0;
    };
    // SAFETY: the caller's obligation on `out`, discharged by Swift's `withUnsafeMutableBytes`.
    unsafe { deliver(&held.answer, out, cap) }
}

#[cfg(test)]
// The fixtures are vectors built a line above each call, so `expect` IS the assertion.
#[expect(
    clippy::expect_used,
    clippy::unwrap_used,
    unsafe_code,
    reason = "calling the boundary IS what these tests are for"
)]
mod tests {
    use super::*;

    /// Packetizes through the boundary and hands back the decoded datagrams.
    fn packetize(handle: *mut SlopDeskVideoPacketizer, frame: &[u8], tier: u8, flags: u32) -> Vec<Vec<u8>> {
        let needed =
            unsafe { slopdesk_video_packetizer_raw(handle, frame.as_ptr(), frame.len(), 7, tier, flags) };
        let mut buffer = vec![0_u8; needed];
        let written = unsafe { slopdesk_video_packetizer_answer(handle, buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, needed, "the answer's length must not move between calls");
        blob_list::decode(&buffer)
            .expect("the answer is a well-formed blob list")
            .into_iter()
            .map(|blob| blob.expect("no datagram is absent").to_vec())
            .collect()
    }

    #[test]
    fn the_boundary_agrees_with_the_packetizer_it_wraps() {
        let frame: Vec<u8> = (0..30_000_u32).map(|i| (i % 251) as u8).collect();
        let handle = unsafe { slopdesk_video_packetizer_new(8, 2) };
        let across = packetize(handle, &frame, 4, FLAG_KEYFRAME | FLAG_INTERLEAVE);
        unsafe { slopdesk_video_packetizer_free(handle) };

        let mut direct = VideoPacketizer::new(Some(ReedSolomonFec::new(8, 2)));
        let expected = direct.packetize_raw(&frame, PacketizeOptions {
            keyframe: true,
            crisp: false,
            host_send_ts_millis: 7,
            fec_tier: 4,
            is_ltr: false,
            acked_anchored: false,
            interleave: true,
        });
        assert_eq!(across, expected);
    }

    #[test]
    fn the_counters_advance_once_per_call_and_the_peeks_see_it() {
        let frame = vec![1_u8; 5_000];
        let handle = unsafe { slopdesk_video_packetizer_new(8, 1) };
        assert_eq!(unsafe { slopdesk_video_packetizer_peek_frame_id(handle) }, 0);
        let first = packetize(handle, &frame, 0, 0);
        assert_eq!(unsafe { slopdesk_video_packetizer_peek_frame_id(handle) }, 1);
        assert_eq!(
            unsafe { slopdesk_video_packetizer_peek_stream_seq(handle) },
            u32::try_from(first.len()).unwrap(),
        );
        unsafe { slopdesk_video_packetizer_free(handle) };
    }

    #[test]
    fn a_short_buffer_is_refused_and_the_frame_is_not_packetized_twice() {
        let frame = vec![9_u8; 4_000];
        let handle = unsafe { slopdesk_video_packetizer_new(8, 1) };
        let needed = unsafe { slopdesk_video_packetizer_raw(handle, frame.as_ptr(), frame.len(), 0, 0, 0) };
        let mut small = vec![0_u8; needed - 1];
        let asked = unsafe { slopdesk_video_packetizer_answer(handle, small.as_mut_ptr(), small.len()) };
        assert_eq!(asked, needed, "a short buffer is told what it needs");
        assert!(small.iter().all(|&b| b == 0), "and nothing is written into it");
        assert_eq!(
            unsafe { slopdesk_video_packetizer_peek_frame_id(handle) },
            1,
            "the frame was packetized once, not once per read",
        );
        unsafe { slopdesk_video_packetizer_free(handle) };
    }

    #[test]
    fn no_parity_means_data_fragments_only() {
        let frame = vec![3_u8; 4_000];
        let bare = unsafe { slopdesk_video_packetizer_new(8, 0) };
        let without = packetize(bare, &frame, 0, 0);
        unsafe { slopdesk_video_packetizer_free(bare) };

        let coded = unsafe { slopdesk_video_packetizer_new(8, 1) };
        let with = packetize(coded, &frame, 0, 0);
        unsafe { slopdesk_video_packetizer_free(coded) };

        assert!(with.len() > without.len(), "parity adds datagrams");
        // The headers differ by design — `fragCount` counts the parity too — so what has to match is
        // the frame's own bytes, which the split must carve identically either way.
        let payloads = |grams: &[Vec<u8>]| -> Vec<Vec<u8>> {
            grams
                .iter()
                .take(without.len())
                .map(|g| g.get(19..).unwrap_or_default().to_vec())
                .collect()
        };
        assert_eq!(payloads(&with), payloads(&without), "the MTU split does not move");
    }

    #[test]
    fn a_null_handle_answers_rather_than_crashing() {
        let frame = [1_u8, 2, 3];
        assert_eq!(
            unsafe {
                slopdesk_video_packetizer_raw(core::ptr::null_mut(), frame.as_ptr(), frame.len(), 0, 0, 0)
            },
            0,
        );
        assert_eq!(
            unsafe { slopdesk_video_packetizer_answer(core::ptr::null_mut(), core::ptr::null_mut(), 0) },
            0,
        );
        assert_eq!(
            unsafe { slopdesk_video_packetizer_peek_frame_id(core::ptr::null_mut()) },
            0,
        );
    }

    #[test]
    fn an_impossible_shape_is_refused_rather_than_panicked() {
        assert!(unsafe { slopdesk_video_packetizer_new(250, 250) }.is_null());
        assert!(unsafe { slopdesk_video_packetizer_new(0, 1) }.is_null());
    }
}
