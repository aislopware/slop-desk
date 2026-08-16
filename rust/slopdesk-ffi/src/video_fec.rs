//! The video path's forward error correction, in C.
//!
//! Two entry points over [`slopdesk_video::fec::ReedSolomonFec`] — parity out, and losses repaired
//! back in — under the crate's pure convention. The codec keeps nothing between calls: an `[n, k]`
//! Reed-Solomon encoder is entirely determined by `(k, m)`, so it is built per call rather than
//! held behind a handle, and there is no free function to forget.
//!
//! ## Why this one is worth the crossing
//! The Swift it replaces is the least safe code in the tree. `NeonGf` reached through a C target
//! (`Sources/CSlopDeskSIMD`) with `UnsafeBufferPointer`, `withUnsafeTemporaryAllocation` and a
//! `swiftlint:disable force_unwrapping`, and both the encoder and the decoder passed raw
//! `UnsafeMutableBufferPointer` accumulators around — all of it on the path that parses hostile UDP
//! from the network. `slopdesk-video` is `forbid(unsafe_code)`, so the whole category goes away
//! rather than being reviewed again.
//!
//! ## The lists
//! A fragment list is not a span, so it becomes one: [`slopdesk_video::blob_list`] flattens
//! `[Option<&[u8]>]` into `u32 count | (u32 len | bytes)…`, with `u32::MAX` for a fragment lost in
//! flight. The format is decided there, where it can be tested under `forbid(unsafe_code)`; this
//! file only hands the span across. A list that does not describe itself exactly returns 0 — no
//! answer — rather than a guess at a shorter one.
//!
//! ## Why the arguments are copied, which is not free
//! Flattening a group's eight 1200-byte fragments measured 0.51 µs against 0.24 µs for the parity
//! it feeds, so passing them as `(address, length)` descriptors instead — 132 bytes rather than
//! 9.6 KB — was tried, and reverted. It cannot be done in O(1) stack: Swift's `withUnsafeBytes`
//! guarantees its pointer only for its closure body, so N fragments means N nested closures, and a
//! 3000-fragment keyframe then overflows the 512 KB stack the production send path runs on
//! (`RustFECLargeFrameStackTests` is the pin). Escaping the pointer is not the way out either: a
//! `Data` of 14 bytes or fewer stores its bytes inside the struct. What DID pay off is on the
//! answer side, below — `recover` sends back the repairs rather than the list.

use core::ffi::c_uchar;

use slopdesk_video::blob_list;
use slopdesk_video::fec::ReedSolomonFec;

use crate::{borrow, deliver};

/// Parity fragments for a frame's data fragments, as a blob list.
///
/// `data` is a blob list in which nothing is absent (the send side has lost nothing yet). `k` and
/// `m` shape the codec; `group_size` is the per-frame grouping width the adaptive tier chose, which
/// at `m == 1` is honoured exactly rather than clamped to `k` — that is what keeps the parity bytes
/// byte-identical to the legacy XOR wire.
///
/// Returns 0 when the list is malformed. A frame with no fragments answers with an EMPTY list,
/// which is four bytes, so an empty answer and a refusal are never the same return value.
///
/// # Safety
/// `data` must be null or point to `data_len` live bytes; `out` null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_fec_parity(
    k: usize,
    m: usize,
    group_size: usize,
    data: *const c_uchar,
    data_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let Some(blobs) = blob_list::decode(unsafe { borrow(data, data_len) }) else {
        return 0;
    };
    // A send-side list has no holes by construction; if one arrives anyway the codec would treat it
    // as a fragment to repair rather than one to read, so refuse instead of inventing bytes.
    let mut fragments = Vec::with_capacity(blobs.len());
    for blob in blobs {
        let Some(bytes) = blob else { return 0 };
        fragments.push(bytes);
    }
    let parity = ReedSolomonFec::new(k, m).parity(&fragments, group_size);
    let answer = blob_list::encode_all(&parity);
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

/// Repairs what the parity can, and answers with the REPAIRS ONLY.
///
/// Both inputs are blob lists whose absences are the fragments that never arrived. The answer is a
/// blob list of the same length and the same order as `data`, in which a fragment is present only
/// if this call is the reason it exists: everything that arrived intact comes back ABSENT, meaning
/// "nothing to give you, you already have it", and so does every hole the code could not close.
///
/// Answering with repairs rather than with the whole list is worth a paragraph because the two are
/// easy to confuse. The full list would send back the 9.6 KB the caller just handed over, so the
/// caller could overwrite its own fragments with copies of themselves; a typical single-loss frame
/// instead answers with one 1.2 KB shard and a run of four-byte absences. The caller patches the
/// holes it asked about and escalates the ones still open to a recovery request.
///
/// Returns 0 when either list is malformed.
///
/// # Safety
/// `data` and `parity` must each be null or point to their stated number of live bytes; `out` null
/// or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_fec_recover(
    k: usize,
    m: usize,
    group_size: usize,
    data: *const c_uchar,
    data_len: usize,
    parity: *const c_uchar,
    parity_len: usize,
    out: *mut c_uchar,
    cap: usize,
) -> usize {
    // SAFETY: the caller's obligations, restated above; `borrow` states its own.
    let (data_input, parity_input) = unsafe { (borrow(data, data_len), borrow(parity, parity_len)) };
    let (Some(data_blobs), Some(parity_blobs)) =
        (blob_list::decode(data_input), blob_list::decode(parity_input))
    else {
        return 0;
    };
    // Which fragments were holes BEFORE the codec ran is the whole basis of the answer, so it is
    // recorded here rather than inferred afterwards — after the call a repaired fragment and one
    // that arrived intact look exactly alike.
    let holes: Vec<bool> = data_blobs.iter().map(Option::is_none).collect();
    let mut fragments: Vec<Option<Vec<u8>>> = data_blobs.into_iter().map(|b| b.map(<[u8]>::to_vec)).collect();
    let parity_owned: Vec<Option<Vec<u8>>> =
        parity_blobs.into_iter().map(|b| b.map(<[u8]>::to_vec)).collect();
    ReedSolomonFec::new(k, m).recover(&mut fragments, &parity_owned, group_size);
    let repairs: Vec<Option<&[u8]>> = fragments
        .iter()
        .zip(holes)
        .map(|(fragment, was_hole)| if was_hole { fragment.as_deref() } else { None })
        .collect();
    let answer = blob_list::encode(&repairs);
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(&answer, out, cap) }
}

#[cfg(test)]
// The fixtures are literals built two lines above each call, so `expect` IS the assertion.
#[expect(
    clippy::expect_used,
    unsafe_code,
    reason = "calling the boundary IS what these tests are for"
)]
mod tests {
    use slopdesk_video::blob_list;

    use super::{slopdesk_video_fec_parity, slopdesk_video_fec_recover};

    fn parity_of(k: usize, m: usize, fragments: &[&[u8]]) -> Vec<u8> {
        let list = blob_list::encode(&fragments.iter().map(|f| Some(*f)).collect::<Vec<_>>());
        let mut out = [0_u8; 4096];
        // SAFETY: both buffers are live locals.
        let written = unsafe {
            slopdesk_video_fec_parity(k, m, k, list.as_ptr(), list.len(), out.as_mut_ptr(), out.len())
        };
        out.get(..written).unwrap_or_default().to_vec()
    }

    fn recover_of(k: usize, m: usize, data: &[Option<&[u8]>], parity: &[u8]) -> Vec<u8> {
        let data_list = blob_list::encode(data);
        let mut out = [0_u8; 4096];
        // SAFETY: every buffer is a live local.
        let written = unsafe {
            slopdesk_video_fec_recover(
                k,
                m,
                k,
                data_list.as_ptr(),
                data_list.len(),
                parity.as_ptr(),
                parity.len(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        out.get(..written).unwrap_or_default().to_vec()
    }

    /// One parity shard over one group IS the plain XOR — the property the whole wire rests on,
    /// checked through the boundary rather than only inside the crate.
    ///
    /// The shard is `u32 max-data-length | xor bytes`: the codec's OWN framing, not this
    /// boundary's. It is on the wire because a group's fragments may differ in length, and
    /// recovering a short one from the XOR needs to know how much of the shard is really its
    /// bytes. Asserting the prefix here keeps the marshalling honest — a shim that quietly
    /// re-framed the shard would still round-trip and would still break every deployed client.
    #[test]
    fn a_single_parity_shard_is_the_xor_of_the_group() {
        let answer = parity_of(3, 1, &[&[0x01, 0x02], &[0x10, 0x20], &[0x00, 0x04]]);
        let blobs = blob_list::decode(&answer).expect("a well-formed parity list");
        assert_eq!(blobs, vec![Some(&[0x00_u8, 0x00, 0x00, 0x02, 0x11, 0x26][..])]);
    }

    /// A lost fragment comes back, and the two fragments that arrived intact come back ABSENT —
    /// the answer is the repairs, not the list. An EMPTY fragment is not mistaken for a hole in
    /// either direction: it is not repaired, and it is not reported as one.
    #[test]
    fn the_answer_is_the_repairs_and_an_empty_fragment_is_not_a_hole() {
        let fragments: [&[u8]; 3] = [&[0xAA, 0xBB], &[0x01, 0x02], &[]];
        let parity = parity_of(3, 1, &fragments);
        let answer = recover_of(3, 1, &[Some(&[0xAA_u8, 0xBB][..]), None, Some(&[][..])], &parity);
        let blobs = blob_list::decode(&answer).expect("a repair list");
        assert_eq!(blobs, vec![None, Some(&[0x01_u8, 0x02][..]), None]);
    }

    /// Two holes against one parity shard cannot be closed — the answer reports NO repair for
    /// either, which is what lets the caller ask for a resend rather than believe wrong bytes.
    #[test]
    fn losses_beyond_the_codes_reach_are_reported_as_unrepaired() {
        let parity = parity_of(3, 1, &[&[0xAA, 0xBB], &[0x01, 0x02], &[0x00, 0x04]]);
        let answer = recover_of(3, 1, &[Some(&[0xAA_u8, 0xBB][..]), None, None], &parity);
        let blobs = blob_list::decode(&answer).expect("a repair list");
        assert_eq!(blobs, vec![None, None, None]);
    }

    /// A malformed list is 0 — no answer — and an empty frame is a four-byte EMPTY list, so the
    /// caller can tell "I could not read that" from "there was nothing to do".
    #[test]
    fn a_refusal_and_an_empty_answer_are_different_return_values() {
        let mut out = [0_u8; 64];
        let junk = [0xFF_u8, 0xFF, 0xFF, 0xFF];
        // SAFETY: both buffers are live locals.
        let refused = unsafe {
            slopdesk_video_fec_parity(3, 1, 3, junk.as_ptr(), junk.len(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(refused, 0);

        let empty = blob_list::encode(&[]);
        // SAFETY: both buffers are live locals.
        let written = unsafe {
            slopdesk_video_fec_parity(3, 1, 3, empty.as_ptr(), empty.len(), out.as_mut_ptr(), out.len())
        };
        assert_eq!(written, 4, "an empty list is still a list");
    }

    /// The undersized-buffer half of the convention: nothing is written and the call asks again.
    #[test]
    fn an_undersized_buffer_writes_nothing_and_asks_again() {
        let list = blob_list::encode(&[Some(&[1_u8, 2, 3, 4][..]), Some(&[5_u8, 6, 7, 8][..])]);
        let mut tiny = [0_u8; 2];
        // SAFETY: both buffers are live locals.
        let needed = unsafe {
            slopdesk_video_fec_parity(2, 1, 2, list.as_ptr(), list.len(), tiny.as_mut_ptr(), tiny.len())
        };
        assert!(needed > tiny.len(), "asked for {needed}");
        assert_eq!(tiny, [0, 0], "an undersized call must not write a partial answer");
    }
}
