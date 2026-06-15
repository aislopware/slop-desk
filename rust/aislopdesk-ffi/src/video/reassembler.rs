//! `reassembler`: the per-datagram video RECEIVE hot path over the C ABI.
//!
//! An OPAQUE handle ([`AisdReassembler`]) wraps the core
//! [`FrameReassembler`](aislopdesk_core::reassembler::FrameReassembler) — the single source of truth
//! for fragment buffering, the data/parity boundary inversion, FEC recovery, and the loss-detection
//! sweep. The Swift/Android shell drives it one datagram at a time:
//!
//! * [`aisd_reassembler_new`] builds the reassembler with the SAME knobs the Swift one took (the FEC
//!   group size `k` and parity-per-group `m`, plus the reorder grace). It constructs the core's
//!   NEON-backed [`ReedSolomonFec`](aislopdesk_core::fec::ReedSolomonFec) internally — the
//!   reassembler OWNS its FEC, so there is no second codec and no double-FEC. `m == 1` is the
//!   production / byte-identical XOR-equivalent wire.
//! * [`aisd_reassembler_ingest`] PARSES one raw fragment datagram (the 19-byte header + payload) and
//!   feeds it, returning a flat [`AisdReassemblyResult`] discriminated as pending / completed /
//!   dropped / stale. A completed frame carries an OWNED [`AisdBytes`] AVCC buffer + its flags.
//! * [`aisd_reassembler_next_dropped`] drains the OLDER frames the sweep declared hopeless (the
//!   `next_dropped_frame` queue), so a single ingest can both complete its own frame AND surface
//!   prior losses.
//! * [`aisd_reassembler_free`] destroys the handle.
//!
//! ## Memory & safety contract
//!
//! Same as the crate root: the input datagram is BORROWED (read, never freed); a completed frame's
//! `avcc` is a fresh Rust allocation the caller releases with [`crate::aisd_bytes_free`] (or the
//! convenience [`aisd_reassembly_result_free`]). The parse + ingest NEVER panic on hostile bytes — a
//! truncated header, an absurd `frag_count`, or a `frag_index >= frag_count` all surface as a benign
//! `pending` (the datagram is ignored), exactly as the core guards specify. There is no per-fragment
//! recursion or unbounded stack: the core buffers fragments in a `HashMap` and assembles the AVCC by
//! a single linear `extend_from_slice` walk, so a multi-megabyte keyframe is O(frame size) heap, O(1)
//! stack.

use crate::gf_neon::NeonGf;
use crate::{
    AISD_ERR_NULL, AISD_OK, AisdBytes, AisdStatus, bytes_from_vec, drop_bytes, free_handle,
    into_handle, slice_in,
};
use aislopdesk_core::fec::{FecScheme, ReedSolomonFec};
use aislopdesk_core::fragment::FrameFragment;
use aislopdesk_core::reassembler::{FrameReassembler, ReassembledFrame, ReassemblyResult};

/// The ingested fragment's frame still needs more fragments — nothing to emit yet. Also the value
/// reported for any IGNORED hostile/short datagram (a parse failure or a degenerate header).
pub const AISD_REASSEMBLY_PENDING: u8 = 0;
/// The ingested fragment completed its frame: `*out` carries the owned AVCC buffer + flags.
pub const AISD_REASSEMBLY_COMPLETED: u8 = 1;
/// The ingested fragment's OWN frame became hopeless this call: `frame_id` is the lost frame.
pub const AISD_REASSEMBLY_DROPPED: u8 = 2;
/// The datagram belonged to a frame already completed or dropped — ignored.
pub const AISD_REASSEMBLY_STALE: u8 = 3;

/// The flat result of feeding one datagram to [`aisd_reassembler_ingest`].
///
/// `kind` is one of the `AISD_REASSEMBLY_*` discriminants and selects which fields are meaningful:
/// * `COMPLETED`: `avcc` (owned — release it), `frame_id`, `keyframe`, `crisp`, `recovered_via_fec`,
///   `is_ltr`, `acked_anchored`.
/// * `DROPPED`: `frame_id` (the lost frame).
/// * `PENDING` / `STALE`: no fields; `avcc` is [`AisdBytes::EMPTY`].
///
/// Field order MUST match the C header's `AisdReassemblyResult`. The boolean-ish flag fields are
/// plain `u8` (read as `!= 0`), never a Rust `bool`, so a JNI `jboolean` of any nonzero value is
/// valid (no `bool`-validity UB across the boundary).
#[repr(C)]
pub struct AisdReassemblyResult {
    /// One of the `AISD_REASSEMBLY_*` discriminants.
    pub kind: u8,
    /// `COMPLETED.keyframe` — this frame is an IDR (a fresh decode anchor). Read as `!= 0`.
    pub keyframe: u8,
    /// `COMPLETED.crisp` — this frame is a crisp near-lossless static refresh. Read as `!= 0`.
    pub crisp: u8,
    /// `COMPLETED.recovered_via_fec` — a data hole existed and FEC parity filled it. Read as `!= 0`.
    pub recovered_via_fec: u8,
    /// `COMPLETED.is_ltr` — a Long-Term-Reference frame the client must ack on decode. Read as `!= 0`.
    pub is_ltr: u8,
    /// `COMPLETED.acked_anchored` — encoded via `ForceLTRRefresh` (wire bit 7). Read as `!= 0`.
    pub acked_anchored: u8,
    /// `COMPLETED.frame_id` / `DROPPED.frame_id`; `0` for `PENDING` / `STALE`.
    pub frame_id: u32,
    /// `COMPLETED` only: the owned AVCC byte buffer (release with [`crate::aisd_bytes_free`] or
    /// [`aisd_reassembly_result_free`]). [`AisdBytes::EMPTY`] for every other `kind`.
    pub avcc: AisdBytes,
}

impl AisdReassemblyResult {
    /// The base result with no payload — the value returned for `PENDING` / `STALE` and the
    /// template the completed/dropped variants overwrite.
    const fn empty(kind: u8) -> Self {
        Self {
            kind,
            keyframe: 0,
            crisp: 0,
            recovered_via_fec: 0,
            is_ltr: 0,
            acked_anchored: 0,
            frame_id: 0,
            avcc: AisdBytes::EMPTY,
        }
    }

    /// Flattens a completed core frame, moving its AVCC bytes across as an owned [`AisdBytes`].
    fn completed(frame: ReassembledFrame) -> Self {
        Self {
            kind: AISD_REASSEMBLY_COMPLETED,
            keyframe: u8::from(frame.keyframe),
            crisp: u8::from(frame.crisp),
            recovered_via_fec: u8::from(frame.recovered_via_fec),
            is_ltr: u8::from(frame.is_ltr),
            acked_anchored: u8::from(frame.acked_anchored),
            frame_id: frame.frame_id,
            avcc: bytes_from_vec(frame.avcc),
        }
    }
}

/// Opaque per-stream frame reassembler (the receive hot path).
///
/// Create with [`aisd_reassembler_new`], feed datagrams with [`aisd_reassembler_ingest`], drain
/// losses with [`aisd_reassembler_next_dropped`], destroy with [`aisd_reassembler_free`]. One per
/// video stream; not thread-safe — drive it from the single client receive loop.
pub struct AisdReassembler {
    inner: FrameReassembler,
}

/// Builds a reassembler that recovers up to `m` losses per group of `k` data fragments, granting a
/// reorder grace of `fec_reorder_grace` frame-ids past the loss frontier for awaited parity.
///
/// The reassembler OWNS a freshly-built NEON-backed Reed-Solomon codec (`[k + m, k]`) — there is no
/// externally-supplied FEC handle and therefore no double-codec. `m == 1` is the production wire
/// (XOR-equivalent, byte-identical). Pass `k == 0` (or `m == 0`) to build a NO-FEC reassembler (a
/// missing data fragment is then terminal once the frame is old) — mirroring `FrameReassembler(fec:
/// nil)`.
///
/// Returns null (NOT a panic/abort across the boundary) for an invalid FEC config: `k >= 1` but
/// `m < 1`, or `k + m > 255` (the Cauchy index sets must fit GF(2^8)). `fec_reorder_grace` is
/// floored at 0 by the core. Destroy a non-null result with [`aisd_reassembler_free`].
#[must_use]
#[unsafe(no_mangle)]
pub extern "C" fn aisd_reassembler_new(
    k: usize,
    m: usize,
    fec_reorder_grace: i32,
) -> *mut AisdReassembler {
    // k == 0 (or m == 0) => no-FEC reassembler, matching `FrameReassembler(fec: nil)`. A non-zero k
    // with an invalid (k, m) is rejected as null so the core's RS construction asserts never trip
    // across FFI (mirrors `aisd_fec_codec_new`).
    let fec = if k == 0 || m == 0 {
        None
    } else if k.saturating_add(m) > 255 {
        return core::ptr::null_mut();
    } else {
        // The reassembler's own FEC is the SAME NEON-backed RS codec the FEC ABI builds, so a
        // recovered frame is bit-identical to one the standalone `aisd_fec_recover` would produce.
        Some(Box::new(ReedSolomonFec::with_backend(k, m, NeonGf)) as Box<dyn FecScheme>)
    };
    into_handle(AisdReassembler {
        inner: FrameReassembler::new(fec, fec_reorder_grace),
    })
}

/// Destroys a reassembler created by [`aisd_reassembler_new`]. No-op on null.
///
/// # Safety
/// `reassembler` must be a pointer from [`aisd_reassembler_new`] that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_reassembler_free(reassembler: *mut AisdReassembler) {
    // SAFETY: per the contract, `reassembler` is an unfreed handle from `aisd_reassembler_new`.
    unsafe { free_handle(reassembler) }
}

/// Parses and ingests one fragment datagram, writing the outcome to `*out`.
///
/// `datagram` is the raw 19-byte header + payload (BORROWED — read, never freed); `datagram` may be
/// null only when `len == 0`. On a COMPLETED frame, `out.avcc` owns a Rust buffer — release it with
/// [`crate::aisd_bytes_free`] (or the whole result with [`aisd_reassembly_result_free`]).
///
/// Returns [`AISD_ERR_NULL`] for a null `reassembler` / `out` (or a null `datagram` with a nonzero
/// `len`), else [`AISD_OK`] with `*out` populated. NEVER panics on hostile input: a datagram that
/// fails to parse (truncated header, payload shorter than its declared length) OR whose header is
/// degenerate (`frag_count == 0`, `frag_count` above the core guard, or `frag_index >= frag_count`)
/// surfaces as [`AISD_REASSEMBLY_PENDING`] with an empty `avcc` — the datagram is ignored, never a
/// crash and never a wedged buffer.
///
/// # Safety
/// `out` must be a writable [`AisdReassemblyResult`]; if `len != 0`, `datagram` must point to at
/// least `len` readable bytes. On [`AISD_OK`] `*out` is overwritten as raw output WITHOUT freeing
/// any prior contents, so a previously-completed result held in the same storage must be released
/// with [`aisd_reassembly_result_free`] first (or use fresh storage) to avoid leaking its `avcc`.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_reassembler_ingest(
    reassembler: *mut AisdReassembler,
    datagram: *const u8,
    len: usize,
    out: *mut AisdReassemblyResult,
) -> AisdStatus {
    if reassembler.is_null() || out.is_null() || (datagram.is_null() && len != 0) {
        return AISD_ERR_NULL;
    }
    // SAFETY: `datagram` covers `len` readable bytes per the contract (and the null+len check).
    let bytes = unsafe { slice_in(datagram, len) };
    // SAFETY: `reassembler` is a live handle per the contract and the null check above.
    let r = unsafe { &mut *reassembler };
    // A corrupt single packet must NOT crash the receiver: an un-parseable datagram is ignored
    // (treated as a benign no-op, surfaced as PENDING) exactly like the core's per-fragment guard.
    let result = FrameFragment::decode(bytes).map_or_else(
        |_| AisdReassemblyResult::empty(AISD_REASSEMBLY_PENDING),
        |fragment| match r.inner.ingest(fragment) {
            ReassemblyResult::Completed(frame) => AisdReassemblyResult::completed(frame),
            ReassemblyResult::Dropped { frame_id } => AisdReassemblyResult {
                frame_id,
                ..AisdReassemblyResult::empty(AISD_REASSEMBLY_DROPPED)
            },
            ReassemblyResult::Incomplete => AisdReassemblyResult::empty(AISD_REASSEMBLY_PENDING),
            ReassemblyResult::Stale => AisdReassemblyResult::empty(AISD_REASSEMBLY_STALE),
        },
    );
    // SAFETY: `out` is non-null per the check above and writable per the contract.
    unsafe { out.write(result) };
    AISD_OK
}

/// Pops the next unrecoverably-lost frame id detected by a PRIOR ingest's hopeless sweep.
///
/// Returns `1` and writes `*out_frame_id` when a drop was surfaced, else `0` (`*out_frame_id`
/// untouched). The caller drains this in a loop after each ingest and issues one recovery signal
/// per id. Returns `0` for a null `reassembler` / `out_frame_id`.
///
/// # Safety
/// `out_frame_id`, if the call returns `1`, is written; it must be a writable `u32` pointer when
/// non-null.
#[must_use]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_reassembler_next_dropped(
    reassembler: *mut AisdReassembler,
    out_frame_id: *mut u32,
) -> u8 {
    // SAFETY: a non-null `reassembler` is a live handle per the contract.
    match unsafe { reassembler.as_mut() }.and_then(|r| r.inner.next_dropped_frame()) {
        Some(frame_id) if !out_frame_id.is_null() => {
            // SAFETY: `out_frame_id` is non-null per the guard and writable per the contract.
            unsafe { out_frame_id.write(frame_id) };
            1
        }
        _ => 0,
    }
}

/// Releases the owned `avcc` buffer inside an [`AisdReassemblyResult`] and resets it to empty.
///
/// A convenience over [`crate::aisd_bytes_free`] that also clears the discriminant. Idempotent (a
/// second call is a no-op) and safe on a `PENDING` / `STALE` / zeroed result (its `avcc` is already
/// [`AisdBytes::EMPTY`]); a null `result` pointer is also a no-op.
///
/// # Safety
/// `result`, if non-null, must point to a writable [`AisdReassemblyResult`] previously written by
/// [`aisd_reassembler_ingest`] (or zeroed) and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aisd_reassembly_result_free(result: *mut AisdReassemblyResult) {
    if result.is_null() {
        return;
    }
    // SAFETY: `result` is non-null per the check above and a writable, library-written result per
    // the contract; its `avcc` is an unfreed buffer this library produced (or EMPTY).
    unsafe {
        let r = &mut *result;
        drop_bytes(r.avcc);
        r.avcc = AisdBytes::EMPTY;
        r.kind = AISD_REASSEMBLY_PENDING;
    }
}

#[cfg(test)]
mod tests {
    // Driving the C ABI from tests means `&mut x` -> `*mut` coercions.
    #![allow(clippy::borrow_as_ptr)]
    use super::*;
    use aislopdesk_core::fragment::{PacketizeOptions, VideoPacketizer};

    /// Reads an owned/returned `AisdBytes` as a `Vec` (the caller still frees it).
    unsafe fn view(b: AisdBytes) -> Vec<u8> {
        unsafe {
            if b.ptr.is_null() || b.len == 0 {
                Vec::new()
            } else {
                core::slice::from_raw_parts(b.ptr, b.len).to_vec()
            }
        }
    }

    fn keyframe_opts() -> PacketizeOptions {
        PacketizeOptions {
            keyframe: true,
            ..PacketizeOptions::default()
        }
    }

    /// Ingests one fragment's encoded datagram through the C ABI, returning the populated result.
    unsafe fn ingest(r: *mut AisdReassembler, frag: &FrameFragment) -> AisdReassemblyResult {
        let bytes = frag.encode();
        let mut out = AisdReassemblyResult::empty(AISD_REASSEMBLY_STALE);
        let status = unsafe { aisd_reassembler_ingest(r, bytes.as_ptr(), bytes.len(), &mut out) };
        assert_eq!(status, AISD_OK);
        out
    }

    #[test]
    fn new_rejects_invalid_fec_but_allows_no_fec() {
        // k == 0 => no-FEC (valid). Invalid RS (k+m>255) => null.
        let no_fec = aisd_reassembler_new(0, 1, 2);
        assert!(!no_fec.is_null());
        unsafe { aisd_reassembler_free(no_fec) };
        assert!(
            aisd_reassembler_new(200, 56, 2).is_null(),
            "k+m>255 rejected"
        );
        // k >= 1 with m == 0 is a no-FEC reassembler (not an error): m == 0 means "no parity".
        let m0 = aisd_reassembler_new(5, 0, 2);
        assert!(!m0.is_null());
        unsafe { aisd_reassembler_free(m0) };
        unsafe { aisd_reassembler_free(core::ptr::null_mut()) }; // no-op
    }

    #[test]
    fn whole_frame_completes_with_correct_bytes_and_flags() {
        unsafe {
            // No-FEC reassembler (k == 0) for a no-FEC packetizer: the data/parity boundary is the
            // whole frag_count, so a wholly-arrived frame completes with every byte intact.
            let r = aisd_reassembler_new(0, 1, 2);
            let mut p = VideoPacketizer::new(None);
            let frame = vec![0x5Au8; VideoPacketizer::MAX_PAYLOAD_SIZE + 100];
            let frags = p.packetize(&frame, keyframe_opts());
            let mut completed: Option<AisdReassemblyResult> = None;
            for f in &frags {
                let out = ingest(r, f);
                if out.kind == AISD_REASSEMBLY_COMPLETED {
                    completed = Some(out);
                } else {
                    assert!(out.avcc.ptr.is_null(), "non-completed carries no bytes");
                }
            }
            let mut done = completed.expect("frame should complete");
            assert_eq!(view(done.avcc), frame, "avcc byte-exact");
            assert_eq!(done.keyframe, 1);
            assert_eq!(done.recovered_via_fec, 0);
            assert_eq!(done.crisp, 0);
            // Free via the result-free convenience (idempotent).
            aisd_reassembly_result_free(&mut done);
            aisd_reassembly_result_free(&mut done);
            assert!(done.avcc.ptr.is_null());
            aisd_reassembler_free(r);
        }
    }

    #[test]
    fn single_loss_recovers_via_fec() {
        unsafe {
            // k=5 m=1 (XOR-equivalent): drop one data fragment, parity in the same group recovers.
            let r = aisd_reassembler_new(5, 1, 2);
            let mut p =
                VideoPacketizer::new(Some(Box::new(ReedSolomonFec::with_backend(5, 1, NeonGf))));
            let frame = vec![0x3Cu8; VideoPacketizer::MAX_PAYLOAD_SIZE * 4];
            let frags = p.packetize(&frame, keyframe_opts());
            let mut completed: Option<AisdReassemblyResult> = None;
            for (i, f) in frags.iter().enumerate() {
                if i == 1 {
                    continue; // drop one data fragment
                }
                let out = ingest(r, f);
                if out.kind == AISD_REASSEMBLY_COMPLETED {
                    completed = Some(out);
                }
            }
            let done = completed.expect("FEC should recover the frame");
            assert_eq!(view(done.avcc), frame);
            assert_eq!(done.recovered_via_fec, 1, "recovered_via_fec flag set");
            crate::aisd_bytes_free(done.avcc); // free via the bytes path
            aisd_reassembler_free(r);
        }
    }

    #[test]
    fn unrecoverable_loss_surfaces_as_dropped() {
        unsafe {
            // No FEC: losing a data fragment of frame 0 is terminal once frame 1 advances the
            // frontier. The older frame is surfaced via next_dropped.
            let r = aisd_reassembler_new(0, 1, 2);
            let mut p = VideoPacketizer::new(None);
            let frame0 = vec![1u8; VideoPacketizer::MAX_PAYLOAD_SIZE * 3];
            let frame1 = vec![2u8; VideoPacketizer::MAX_PAYLOAD_SIZE];
            let f0 = p.packetize(&frame0, keyframe_opts());
            let f1 = p.packetize(&frame1, keyframe_opts());

            let _ = ingest(r, &f0[0]); // fragment 1 of frame 0 is lost
            let _ = ingest(r, &f0[2]);
            let _ = ingest(r, &f1[0]); // advances frontier → frame 0 hopeless

            let mut lost = 0u32;
            assert_eq!(aisd_reassembler_next_dropped(r, &mut lost), 1);
            assert_eq!(lost, 0, "frame 0 dropped");
            assert_eq!(
                aisd_reassembler_next_dropped(r, &mut lost),
                0,
                "queue drained"
            );
            aisd_reassembler_free(r);
        }
    }

    #[test]
    fn hostile_and_truncated_datagrams_are_ignored() {
        unsafe {
            let r = aisd_reassembler_new(5, 1, 2);
            // Truncated header (< 19 bytes) — parse fails → PENDING, no crash.
            let mut out = AisdReassemblyResult::empty(AISD_REASSEMBLY_STALE);
            let short = [0u8, 1, 2, 3];
            assert_eq!(
                aisd_reassembler_ingest(r, short.as_ptr(), short.len(), &mut out),
                AISD_OK
            );
            assert_eq!(out.kind, AISD_REASSEMBLY_PENDING);
            assert!(out.avcc.ptr.is_null());

            // Absurd frag_count (above the core guard) — header parses but is degenerate → ignored
            // as STALE by the core's hostile-input guard (no per-frame buffer ever allocated).
            let mut p = VideoPacketizer::new(None);
            let mut frag = p.packetize(&[1, 2, 3], keyframe_opts())[0].clone();
            frag.header.frag_count = (FrameReassembler::MAX_FRAGMENTS_PER_FRAME + 1) as u16;
            let out2 = ingest(r, &frag);
            assert_eq!(out2.kind, AISD_REASSEMBLY_STALE);
            assert!(out2.avcc.ptr.is_null());

            // Null guards.
            assert_eq!(
                aisd_reassembler_ingest(core::ptr::null_mut(), short.as_ptr(), 4, &mut out),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_reassembler_ingest(r, short.as_ptr(), 4, core::ptr::null_mut()),
                AISD_ERR_NULL
            );
            assert_eq!(
                aisd_reassembler_next_dropped(core::ptr::null_mut(), core::ptr::null_mut()),
                0
            );
            aisd_reassembler_free(r);
        }
    }

    // ----- Multi-loss (m > 1) ACTIVATION: full FFI send→receive round-trip -------------------
    //
    // The load-bearing proof through the REAL C ABI on BOTH ends: the send path
    // (`aisd_packetize`, built `(k, m)`, fec_group_size = k) and the receive path
    // (`aisd_reassembler_new(k, m, ...)` + `aisd_reassembler_ingest`). This is the property the
    // production `m == 1` / XOR wire CANNOT deliver (one loss per group max).

    /// Packetizes `frame` through `aisd_packetize` and returns the encoded wire datagrams as `Vec`s.
    /// `interleave` runs the burst-resilient transmit reorder (the production default), keyed by k.
    unsafe fn ffi_packetize(
        p: *mut super::super::packetizer::AisdVideoPacketizer,
        frame: &[u8],
        k: usize,
        interleave: bool,
    ) -> Vec<Vec<u8>> {
        use super::super::packetizer::{AisdPacketizeOptions, aisd_packetize};
        let opts = AisdPacketizeOptions {
            keyframe: 1,
            crisp: 0,
            is_ltr: 0,
            acked_anchored: 0,
            fec_tier: 0, // tier 0 ⇒ group size resolves to the codec's k (the m>1 requirement)
            interleave: u8::from(interleave),
            host_send_ts_millis: 0,
            fec_group_size: k, // fixed group_size = k for m>1
        };
        let mut out = crate::AisdBytesArray::EMPTY;
        let status = unsafe { aisd_packetize(p, frame.as_ptr(), frame.len(), opts, &mut out) };
        assert_eq!(status, AISD_OK);
        let datagrams: Vec<Vec<u8>> =
            unsafe { (0..out.count).map(|i| view(*out.items.add(i))).collect() };
        unsafe { crate::aisd_bytes_array_free(&mut out) };
        datagrams
    }

    /// Ingests a raw wire datagram through `aisd_reassembler_ingest`, returning the result.
    unsafe fn ffi_ingest(r: *mut AisdReassembler, datagram: &[u8]) -> AisdReassemblyResult {
        let mut out = AisdReassemblyResult::empty(AISD_REASSEMBLY_STALE);
        let status =
            unsafe { aisd_reassembler_ingest(r, datagram.as_ptr(), datagram.len(), &mut out) };
        assert_eq!(status, AISD_OK);
        out
    }

    /// The flat parity/data classification + `frag_index` of a wire datagram (header byte 12 bit1 =
    /// parity, bytes 8..10 BE = `frag_index`).
    fn classify(datagram: &[u8]) -> (bool, u16) {
        let frag_index = u16::from_be_bytes([datagram[8], datagram[9]]);
        let is_parity = datagram[12] & (1 << 1) != 0;
        (is_parity, frag_index)
    }

    #[test]
    fn ffi_m2_recovers_two_losses_per_group_round_trip() {
        unsafe {
            use super::super::packetizer::{aisd_video_packetizer_free, aisd_video_packetizer_new};
            let k = 5usize;
            let m = 2usize;
            // 10 data fragments ⇒ exactly two full groups of k=5; each group emits m=2 parity.
            let frame = vec![0xABu8; VideoPacketizer::MAX_PAYLOAD_SIZE * (2 * k)];
            let p = aisd_video_packetizer_new(k, m);
            let datagrams = ffi_packetize(p, &frame, k, false);
            let data_count = datagrams.iter().filter(|d| !classify(d).0).count();
            let parity_count = datagrams.iter().filter(|d| classify(d).0).count();
            assert_eq!(data_count, 2 * k, "two groups of k data fragments");
            assert_eq!(parity_count, 2 * m, "two groups × m=2 parity shards");

            // Drop 2 DISTINCT data fragments in EACH group (a 2-loss burst per group).
            let drop: std::collections::HashSet<u16> = [0, 1, 5, 7].into_iter().collect();
            let survivors: Vec<&Vec<u8>> = datagrams
                .iter()
                .filter(|d| {
                    let (is_parity, idx) = classify(d);
                    is_parity || !drop.contains(&idx)
                })
                .collect();

            let r = aisd_reassembler_new(k, m, 2);
            let mut completed: Option<AisdReassemblyResult> = None;
            for d in survivors {
                let out = ffi_ingest(r, d);
                if out.kind == AISD_REASSEMBLY_COMPLETED {
                    completed = Some(out);
                }
            }
            let done = completed.expect("m=2 recovers 2 losses per group");
            assert_eq!(view(done.avcc), frame, "reassembled frame byte-identical");
            assert_eq!(done.recovered_via_fec, 1, "completed via FEC recovery");
            crate::aisd_bytes_free(done.avcc);
            aisd_reassembler_free(r);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn ffi_m1_control_cannot_recover_two_losses_per_group() {
        unsafe {
            use super::super::packetizer::{aisd_video_packetizer_free, aisd_video_packetizer_new};
            // Same 2-loss-per-group pattern on an m == 1 (XOR) wire: provably unrecoverable.
            let k = 5usize;
            let frame = vec![0xCDu8; VideoPacketizer::MAX_PAYLOAD_SIZE * (2 * k)];
            let p = aisd_video_packetizer_new(k, 1);
            let datagrams = ffi_packetize(p, &frame, k, false);
            let drop: std::collections::HashSet<u16> = [0, 1, 5, 7].into_iter().collect();
            let survivors: Vec<&Vec<u8>> = datagrams
                .iter()
                .filter(|d| {
                    let (is_parity, idx) = classify(d);
                    is_parity || !drop.contains(&idx)
                })
                .collect();
            let r = aisd_reassembler_new(k, 1, 2);
            for d in survivors {
                let out = ffi_ingest(r, d);
                assert_ne!(
                    out.kind, AISD_REASSEMBLY_COMPLETED,
                    "XOR cannot recover 2/group"
                );
            }
            // Advance the frontier with a newer frame ⇒ the unrecoverable frame is dropped.
            let next = vec![0xEFu8; VideoPacketizer::MAX_PAYLOAD_SIZE];
            for d in &ffi_packetize(p, &next, k, false) {
                let _ = ffi_ingest(r, d);
            }
            let mut lost = 0u32;
            assert_eq!(aisd_reassembler_next_dropped(r, &mut lost), 1);
            assert_eq!(lost, 0, "frame 0 dropped, not wedged");
            aisd_reassembler_free(r);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn ffi_m2_three_losses_in_one_group_fail_gracefully() {
        unsafe {
            use super::super::packetizer::{aisd_video_packetizer_free, aisd_video_packetizer_new};
            let k = 5usize;
            let m = 2usize;
            let frame = vec![0x42u8; VideoPacketizer::MAX_PAYLOAD_SIZE * (2 * k)];
            let p = aisd_video_packetizer_new(k, m);
            let datagrams = ffi_packetize(p, &frame, k, false);
            // 3 holes (> m) in group 0; group 1 clean.
            let drop: std::collections::HashSet<u16> = [0, 1, 2].into_iter().collect();
            let survivors: Vec<&Vec<u8>> = datagrams
                .iter()
                .filter(|d| {
                    let (is_parity, idx) = classify(d);
                    is_parity || !drop.contains(&idx)
                })
                .collect();
            let r = aisd_reassembler_new(k, m, 2);
            for d in survivors {
                let out = ffi_ingest(r, d);
                assert_ne!(out.kind, AISD_REASSEMBLY_COMPLETED, "3 > m=2 unrecoverable");
            }
            // Graceful drop once the frontier advances — reaching here proves no panic.
            let next = vec![0x99u8; VideoPacketizer::MAX_PAYLOAD_SIZE];
            for d in &ffi_packetize(p, &next, k, false) {
                let _ = ffi_ingest(r, d);
            }
            let mut lost = 0u32;
            assert_eq!(aisd_reassembler_next_dropped(r, &mut lost), 1);
            assert_eq!(lost, 0);
            aisd_reassembler_free(r);
            aisd_video_packetizer_free(p);
        }
    }

    #[test]
    fn ffi_m2_recovers_two_losses_per_group_with_interleave() {
        unsafe {
            use super::super::packetizer::{aisd_video_packetizer_free, aisd_video_packetizer_new};
            // The PRODUCTION send path runs the burst-resilient interleave (default ON). The
            // reassembler keys by frag_index, so the reorder is transparent — m=2 still recovers a
            // 2-loss-per-group burst when the survivors arrive in interleaved transmit order.
            let k = 5usize;
            let m = 2usize;
            let frame = vec![0x7Eu8; VideoPacketizer::MAX_PAYLOAD_SIZE * (2 * k)];
            let p = aisd_video_packetizer_new(k, m);
            let datagrams = ffi_packetize(p, &frame, k, true); // interleaved transmit order
            let drop: std::collections::HashSet<u16> = [0, 1, 5, 7].into_iter().collect();
            // Feed survivors IN THE INTERLEAVED ORDER the packetizer produced (no re-sort).
            let r = aisd_reassembler_new(k, m, 2);
            let mut completed: Option<AisdReassemblyResult> = None;
            for d in &datagrams {
                let (is_parity, idx) = classify(d);
                if !is_parity && drop.contains(&idx) {
                    continue; // dropped data fragment
                }
                let out = ffi_ingest(r, d);
                if out.kind == AISD_REASSEMBLY_COMPLETED {
                    completed = Some(out);
                }
            }
            let done = completed.expect("m=2 recovers 2/group even in interleaved order");
            assert_eq!(view(done.avcc), frame, "reassembled frame byte-identical");
            assert_eq!(done.recovered_via_fec, 1);
            crate::aisd_bytes_free(done.avcc);
            aisd_reassembler_free(r);
            aisd_video_packetizer_free(p);
        }
    }
}
