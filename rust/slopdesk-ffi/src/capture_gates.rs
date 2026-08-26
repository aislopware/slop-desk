//! The capture path's `SLOPDESK_*` operating point and its five decisions, in C —
//! `Sources/SlopDeskVideoHost/WindowCapturer.swift`.
//!
//! The same two-step shape [`crate::host_gates`] has, for the same reason:
//! [`slopdesk_video_capture_gate_keys`] hands over the NAMES, the caller resolves each through
//! `EnvConfig.string` — the env → settings-overlay precedence, a lookup rule rather than a gate
//! rule — and [`slopdesk_video_capture_gates`] takes the texts back and answers the whole table at
//! once. The texts cross as a [`blob_list`], absent entries and all, because an unset key is not an
//! empty one and `SLOPDESK_VIDEO_DEBUG` is a PRESENCE gate that reads the two oppositely.
//!
//! ## The five decisions cross too, and three of them read the table
//!
//! A gate table whose consumers each re-implement the rule it feeds is half a port. Four of these
//! doors therefore take the resolved [`SlopDeskVideoCaptureGates`] by pointer and answer the
//! question directly, so the capture callback asks rather than branches. They are on the per-frame
//! path — [`slopdesk_video_capture_needs_frame_hash`] runs once per captured frame at 60 Hz — which
//! is why they take the table by pointer instead of by value: a thirty-field aggregate copied per
//! frame would be the one thing this port could plausibly make slower than the Swift it replaces.
//!
//! [`slopdesk_video_capture_fold_encode_ewma`] is the fifth, and the only one that reads no gate at
//! all: it is three scalars in and one out.

use core::ffi::c_uchar;

use slopdesk_video::blob_list;
use slopdesk_video::capture_gates::{
    BacklogDecision, CaptureGateContext, CaptureGates, KEYS, fold_encode_ewma,
};

use crate::{borrow, deliver};

/// The backlog verdict: append the incoming frame and schedule a drain.
pub const CAPTURE_BACKLOG_ENQUEUE: u8 = 0;
/// The backlog is full — drop the incoming (newest) delta.
pub const CAPTURE_BACKLOG_DROP_INCOMING: u8 = 1;
/// Freshest-wins — evict the pending frame at the returned index, then append the incoming one.
pub const CAPTURE_BACKLOG_EVICT_OLDEST: u8 = 2;

/// The resolved capture operating point, field for field with `slopdesk_video`'s own.
///
/// Flat and `repr(C)` rather than a packed blob, for the reason its sibling gives: the caller reads
/// these one at a time from two thousand lines of capture code, and a hand-decoded offset per read
/// is exactly the transcription this door exists to delete.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskVideoCaptureGates {
    /// Emit the periodic motion IDR during sustained motion. Default OFF.
    pub motion_heartbeat: bool,
    /// Configure the capture audio tap at all. Default ON.
    pub audio_capture: bool,
    /// Upgrade the static-IDR timer's re-encode to a crisp near-lossless frame. Default ON.
    pub crisp_when_static: bool,
    /// Drop a pixel-identical re-delivery before the encoder. Default OFF.
    pub static_suppress: bool,
    /// Trigger the crisp re-anchor off consecutive identical frames. Default OFF.
    pub still_crisp: bool,
    /// Measure content scroll and send the offset for the client to warp by. Default OFF.
    pub scroll_reproject: bool,
    /// Drive the live frame's QP ceiling from the measured change. Default OFF.
    pub adaptive_qp: bool,
    /// Drop a truly-idle frame before the encode hand-off. Default OFF; requires `adaptive_qp`.
    pub idle_skip: bool,
    /// Hand the encode to a dedicated serial queue. Default ON.
    pub encode_off_queue: bool,
    /// Step the effective fps down when the encoder cannot sustain the budget. Default ON.
    pub encode_pacer: bool,
    /// Evict the oldest pending delta rather than drop the incoming one. Default OFF.
    pub freshest_wins: bool,
    /// Suppress the self-heal refresh on a clean link. Default OFF.
    pub self_heal_loss_gate: bool,
    /// Mirror capture-gap diagnostics to stderr. PRESENCE, not value.
    pub debug_gaps: bool,
    /// Consecutive identical frames the event-driven crisp re-anchor needs. Default 2.
    pub still_crisp_threshold: u32,
    /// Bits each luma byte is right-shifted by before the per-row scroll hash. Default 3.
    pub scroll_quantize_shift: u8,
    /// The sharp (low) QP ceiling a small change is pinned to. Default 22.
    pub adaptive_qp_sharp: i32,
    /// The coarse QP ceiling a burst ramps up to. Defaults to the encoder's own static ceiling.
    pub adaptive_qp_max: i32,
    /// Frames the smoothed QP takes to ease UP to a coarser target. Default 1 (instant).
    pub adaptive_qp_up_ramp: i32,
    /// Most QP per frame the smoothed value may ease DOWN on a stop. Default 4.
    pub adaptive_qp_down_step: i32,
    /// Low end of the changed-row band, in milli. Default 20.
    pub adaptive_qp_band_lo_milli: u32,
    /// High end of the changed-row band, in milli. Default 300.
    pub adaptive_qp_band_hi_milli: u32,
    /// Encode only ~N of the captured fps during sustained fast scroll. `0` disables.
    pub scroll_fps: i32,
    /// Changed-row fraction, in milli, at or above which a frame is FAST scroll. Default 120.
    pub scroll_motion_threshold_milli: u32,
    /// Consecutive fast-scroll frames the cap debounces over.
    pub scroll_motion_sustain_frames: u32,
    /// Pending encodes the decoupled queue admits. Default 3.
    pub max_encode_pending: i32,
    /// Force a compact recovery IDR every Nth live frame. `0` disables.
    pub force_compact_every: i32,
    /// Live deltas between self-heal LTR refreshes. `0` disables.
    pub self_heal_every: i32,
    /// Minimum spacing between SENT recovery IDRs, in SECONDS. `0` disables the gate.
    pub min_recovery_idr_interval: f64,
    /// The loss EWMA at or above which self-heal stays armed under the clean-link gate. The crate's
    /// own constant, delivered with the table so the caller has no number of its own to drift.
    pub self_heal_loss_gate_threshold: f64,
}

/// The operating point as it crosses.
const fn crossing(gates: CaptureGates) -> SlopDeskVideoCaptureGates {
    SlopDeskVideoCaptureGates {
        motion_heartbeat: gates.motion_heartbeat,
        audio_capture: gates.audio_capture,
        crisp_when_static: gates.crisp_when_static,
        static_suppress: gates.static_suppress,
        still_crisp: gates.still_crisp,
        scroll_reproject: gates.scroll_reproject,
        adaptive_qp: gates.adaptive_qp,
        idle_skip: gates.idle_skip,
        encode_off_queue: gates.encode_off_queue,
        encode_pacer: gates.encode_pacer,
        freshest_wins: gates.freshest_wins,
        self_heal_loss_gate: gates.self_heal_loss_gate,
        debug_gaps: gates.debug_gaps,
        still_crisp_threshold: gates.still_crisp_threshold,
        scroll_quantize_shift: gates.scroll_quantize_shift,
        adaptive_qp_sharp: gates.adaptive_qp_sharp,
        adaptive_qp_max: gates.adaptive_qp_max,
        adaptive_qp_up_ramp: gates.adaptive_qp_up_ramp,
        adaptive_qp_down_step: gates.adaptive_qp_down_step,
        adaptive_qp_band_lo_milli: gates.adaptive_qp_band_lo_milli,
        adaptive_qp_band_hi_milli: gates.adaptive_qp_band_hi_milli,
        scroll_fps: gates.scroll_fps,
        scroll_motion_threshold_milli: gates.scroll_motion_threshold_milli,
        scroll_motion_sustain_frames: slopdesk_video::capture_gates::SCROLL_MOTION_SUSTAIN_FRAMES,
        max_encode_pending: gates.max_encode_pending,
        force_compact_every: gates.force_compact_every,
        self_heal_every: gates.self_heal_every,
        min_recovery_idr_interval: gates.min_recovery_idr_interval,
        self_heal_loss_gate_threshold: slopdesk_video::capture_gates::SELF_HEAL_LOSS_GATE_THRESHOLD,
    }
}

/// The far side of the crossing, for the decision doors: the table as the crate's own type.
///
/// The two structs carry the same fields and neither is the other's `repr`, so the trip back is
/// spelled once here rather than at each of the four doors that needs it. Only the fields a
/// decision reads have to be right, but all of them are carried: a partial rebuild is the kind of
/// thing that stays correct exactly until someone adds a fifth decision.
const fn returning(raw: &SlopDeskVideoCaptureGates) -> CaptureGates {
    CaptureGates {
        motion_heartbeat: raw.motion_heartbeat,
        audio_capture: raw.audio_capture,
        crisp_when_static: raw.crisp_when_static,
        static_suppress: raw.static_suppress,
        still_crisp: raw.still_crisp,
        still_crisp_threshold: raw.still_crisp_threshold,
        scroll_reproject: raw.scroll_reproject,
        scroll_quantize_shift: raw.scroll_quantize_shift,
        adaptive_qp: raw.adaptive_qp,
        adaptive_qp_sharp: raw.adaptive_qp_sharp,
        adaptive_qp_max: raw.adaptive_qp_max,
        adaptive_qp_up_ramp: raw.adaptive_qp_up_ramp,
        adaptive_qp_down_step: raw.adaptive_qp_down_step,
        adaptive_qp_band_lo_milli: raw.adaptive_qp_band_lo_milli,
        adaptive_qp_band_hi_milli: raw.adaptive_qp_band_hi_milli,
        idle_skip: raw.idle_skip,
        scroll_fps: raw.scroll_fps,
        scroll_motion_threshold_milli: raw.scroll_motion_threshold_milli,
        encode_off_queue: raw.encode_off_queue,
        encode_pacer: raw.encode_pacer,
        freshest_wins: raw.freshest_wins,
        max_encode_pending: raw.max_encode_pending,
        force_compact_every: raw.force_compact_every,
        self_heal_every: raw.self_heal_every,
        self_heal_loss_gate: raw.self_heal_loss_gate,
        min_recovery_idr_interval: raw.min_recovery_idr_interval,
        debug_gaps: raw.debug_gaps,
    }
}

/// The environment keys, NUL-joined, in the order the resolver reads their values.
///
/// The caller splits on `\0` and looks each name up through its own overlay-aware lookup. The list
/// is Rust's because the table that reads it is, and a name spelled here but resolved there under a
/// typo would silently answer its default.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_capture_gate_keys(out: *mut c_uchar, cap: usize) -> usize {
    let answer = KEYS.join("\0");
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Resolves the whole capture operating point from the texts of the keys above.
///
/// `values` is a [`blob_list`] whose entries are those texts in key order, with an ABSENT entry for
/// a key the environment does not set — which is not the same as an empty one, and the presence
/// gate is why.
///
/// The two scalars are the inputs no key carries: the encoder's own static QP ceiling, which is the
/// adaptive cap's default, and the pacer's EWMA weight. Both are the caller's resolved constants,
/// so they cross rather than being read from a crate this one does not depend on.
///
/// Answers `false` and writes nothing when the blob is not a blob list or an entry is not UTF-8 —
/// both of which mean the caller built the list wrong, since it built it from its own environment.
///
/// # Safety
/// `values` must be null or point to `len` live bytes; `out` null or writable for one
/// [`SlopDeskVideoCaptureGates`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `out` is the caller's to keep live"
)]
pub unsafe extern "C" fn slopdesk_video_capture_gates(
    values: *const c_uchar,
    len: usize,
    max_allowed_frame_qp: i32,
    encode_ewma_alpha: f64,
    out: *mut SlopDeskVideoCaptureGates,
) -> bool {
    // SAFETY: the caller's obligation, restated above; `borrow` states its own.
    let blob = unsafe { borrow(values, len) };
    let Some(entries) = blob_list::decode(blob) else {
        return false;
    };
    let mut texts: Vec<Option<&str>> = Vec::with_capacity(entries.len());
    for entry in entries {
        match entry {
            None => texts.push(None),
            Some(bytes) => {
                match core::str::from_utf8(bytes) {
                    Ok(text) => texts.push(Some(text)),
                    Err(_) => return false,
                }
            },
        }
    }
    let gates = crossing(CaptureGates::from_env(&texts, CaptureGateContext {
        max_allowed_frame_qp,
        encode_ewma_alpha,
    }));
    if out.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation, restated above — `out` is non-null here and the caller
    // guarantees it is writable for one of these, which is a plain `Copy` aggregate.
    unsafe { out.write(gates) };
    true
}

/// Whether a captured frame needs the shared full-NV12 hash — the union of the three gates that
/// consume one.
///
/// `false` for a null table, which is a capturer that has not resolved its gates: taking no hash is
/// the answer that costs nothing on the per-frame path.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_video_capture_needs_frame_hash(
    gates: *const SlopDeskVideoCaptureGates,
    measured: bool,
    change_milli: u32,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return false;
    };
    returning(raw).needs_frame_hash(measured, change_milli)
}

/// Whether a live delta may be dropped as idle — a real measurement with zero changed rows, on a
/// capturer whose idle-skip gate is on.
///
/// `false` for a null table, for the reason above.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_video_capture_skips_idle_frame(
    gates: *const SlopDeskVideoCaptureGates,
    measured: bool,
    change_milli: u32,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return false;
    };
    raw.idle_skip && slopdesk_video::capture_gates::idle_skip_eligible(measured, change_milli)
}

/// Whether this live delta should become a self-heal LTR refresh.
///
/// `false` for a null table: no heal is the answer that changes no bytes on the wire.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_capture_should_self_heal(
    gates: *const SlopDeskVideoCaptureGates,
    frames_since_anchor: i32,
    eligible: bool,
    loss_rate: f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return false;
    };
    returning(raw).should_self_heal(frames_since_anchor, eligible, loss_rate)
}

/// What the decoupled encode backlog does with an arriving frame.
///
/// `pending_forced` is one byte per already-queued frame, oldest first, non-zero for a forced one.
/// The verdict is the return; `evict_index` receives the position to remove and is written ONLY
/// for [`CAPTURE_BACKLOG_EVICT_OLDEST`].
///
/// [`CAPTURE_BACKLOG_ENQUEUE`] for a null table, which is the answer that loses no frame.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`]; `(pending_forced,
/// pending_len)` must be null or describe that many live bytes; `evict_index` must be null or
/// writable for one `usize`.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and both out-parameters are the caller's to keep \
              live"
)]
pub unsafe extern "C" fn slopdesk_video_capture_backlog_decision(
    gates: *const SlopDeskVideoCaptureGates,
    pending_forced: *const c_uchar,
    pending_len: usize,
    incoming_forced: bool,
    evict_index: *mut usize,
) -> u8 {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return CAPTURE_BACKLOG_ENQUEUE;
    };
    // SAFETY: as above; `borrow` states its own.
    let flags = unsafe { borrow(pending_forced, pending_len) };
    let pending: Vec<bool> = flags.iter().map(|byte| *byte != 0).collect();
    match returning(raw).backlog_decision(&pending, incoming_forced) {
        BacklogDecision::Enqueue => CAPTURE_BACKLOG_ENQUEUE,
        BacklogDecision::DropIncoming => CAPTURE_BACKLOG_DROP_INCOMING,
        BacklogDecision::EvictOldestUnforced(index) => {
            if !evict_index.is_null() {
                // SAFETY: non-null here, and the caller guarantees one writable `usize`.
                unsafe { evict_index.write(index) };
            }
            CAPTURE_BACKLOG_EVICT_OLDEST
        },
    }
}

/// The EWMA fold for one encode-wall sample: the first seeds the average whole, later ones fold.
///
/// The only decision here that reads no gate — three scalars in, one out — so it takes no table and
/// has no null case.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_video_capture_fold_encode_ewma(
    current: f64,
    sample_millis: f64,
    alpha: f64,
) -> f64 {
    fold_encode_ewma(current, sample_millis, alpha)
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]
    #![expect(
        clippy::float_cmp,
        reason = "a resolved gate is the exact number the rule computed, which is the property under test"
    )]
    use slopdesk_video::blob_list;
    use slopdesk_video::capture_gates::{KEYS, SCROLL_MOTION_SUSTAIN_FRAMES};

    use super::{
        CAPTURE_BACKLOG_DROP_INCOMING, CAPTURE_BACKLOG_ENQUEUE, CAPTURE_BACKLOG_EVICT_OLDEST,
        SlopDeskVideoCaptureGates, slopdesk_video_capture_backlog_decision,
        slopdesk_video_capture_fold_encode_ewma, slopdesk_video_capture_gate_keys,
        slopdesk_video_capture_gates, slopdesk_video_capture_needs_frame_hash,
        slopdesk_video_capture_should_self_heal, slopdesk_video_capture_skips_idle_frame,
    };

    /// The encoder's shipped static ceiling, as the caller passes it.
    const MAX_QP: i32 = 51;

    /// Resolves the table across the boundary from a sparse `(key, value)` list.
    fn gates(pairs: &[(&str, &str)]) -> SlopDeskVideoCaptureGates {
        let entries: Vec<Option<&[u8]>> = KEYS
            .iter()
            .map(|key| {
                pairs
                    .iter()
                    .find(|(name, _)| name == key)
                    .map(|(_, value)| value.as_bytes())
            })
            .collect();
        let blob = blob_list::encode(&entries);
        let mut out = SlopDeskVideoCaptureGates::default();
        // SAFETY: `blob` is live for the call and `out` is one live record.
        let ok =
            unsafe { slopdesk_video_capture_gates(blob.as_ptr(), blob.len(), MAX_QP, 0.25, &raw mut out) };
        assert!(ok, "a blob list built from the key list is always decodable");
        out
    }

    /// The names cross whole and in order, so a caller that splits on `\0` gets the key list back.
    #[test]
    fn the_key_list_crosses_in_order() {
        // SAFETY: a null `out` with a zero cap asks for the size, which is the door's own contract.
        let needed = unsafe { slopdesk_video_capture_gate_keys(core::ptr::null_mut(), 0) };
        let mut buffer = vec![0u8; needed];
        // SAFETY: `buffer` is live and exactly `needed` bytes long.
        let written = unsafe { slopdesk_video_capture_gate_keys(buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, needed);
        let text = String::from_utf8_lossy(&buffer);
        let names: Vec<&str> = text.split('\0').collect();
        assert_eq!(names, KEYS.to_vec());
    }

    #[test]
    fn the_shipped_operating_point_crosses_whole() {
        let shipped = gates(&[]);
        assert!(shipped.audio_capture);
        assert!(shipped.crisp_when_static);
        assert!(shipped.encode_off_queue);
        assert!(shipped.encode_pacer);
        assert!(!shipped.adaptive_qp);
        assert_eq!(
            shipped.adaptive_qp_max, MAX_QP,
            "the caller's ceiling is the default"
        );
        assert_eq!(shipped.self_heal_every, 30);
        assert_eq!(shipped.max_encode_pending, 3);
        assert_eq!(shipped.min_recovery_idr_interval, 0.0);
        assert_eq!(
            shipped.scroll_motion_sustain_frames, SCROLL_MOTION_SUSTAIN_FRAMES,
            "the debounce is the crate's constant, not a number the caller re-types",
        );
    }

    /// A malformed list is the caller's own bug — it built the list from its own environment — so
    /// the door refuses rather than guessing, and writes nothing.
    #[test]
    fn a_blob_that_is_not_a_list_is_refused() {
        let mut out = SlopDeskVideoCaptureGates::default();
        let junk = [0xFF_u8, 0xFF, 0xFF];
        // SAFETY: `junk` is live for the call and `out` is one live record.
        let ok =
            unsafe { slopdesk_video_capture_gates(junk.as_ptr(), junk.len(), MAX_QP, 0.25, &raw mut out) };
        assert!(!ok);
        assert!(!out.audio_capture, "a refused call leaves the record untouched");
    }

    #[test]
    fn the_four_table_doors_answer_inertly_for_a_null_table() {
        // SAFETY: null is the one pointer these doors are asked to answer for.
        unsafe {
            assert!(!slopdesk_video_capture_needs_frame_hash(
                core::ptr::null(),
                true,
                0
            ));
            assert!(!slopdesk_video_capture_skips_idle_frame(
                core::ptr::null(),
                true,
                0
            ));
            assert!(!slopdesk_video_capture_should_self_heal(
                core::ptr::null(),
                999,
                true,
                1.0
            ));
            assert_eq!(
                slopdesk_video_capture_backlog_decision(
                    core::ptr::null(),
                    core::ptr::null(),
                    0,
                    false,
                    core::ptr::null_mut(),
                ),
                CAPTURE_BACKLOG_ENQUEUE,
                "losing no frame is the inert answer",
            );
        }
    }

    #[test]
    fn the_frame_hash_and_the_idle_skip_cross_their_gates() {
        let plain = gates(&[]);
        let skipping = gates(&[("SLOPDESK_IDLE_SKIP", "1"), ("SLOPDESK_ADAPTIVE_QP", "1")]);
        // SAFETY: both records are live locals for the call.
        unsafe {
            assert!(!slopdesk_video_capture_needs_frame_hash(
                &raw const plain,
                true,
                0
            ));
            assert!(slopdesk_video_capture_needs_frame_hash(
                &raw const skipping,
                true,
                0
            ));
            assert!(!slopdesk_video_capture_needs_frame_hash(
                &raw const skipping,
                true,
                9
            ));
            assert!(slopdesk_video_capture_skips_idle_frame(
                &raw const skipping,
                true,
                0
            ));
            assert!(
                !slopdesk_video_capture_skips_idle_frame(&raw const skipping, false, 0),
                "an unmeasurable frame is not an idle one",
            );
            assert!(!slopdesk_video_capture_skips_idle_frame(
                &raw const plain,
                true,
                0
            ));
        }
    }

    #[test]
    fn the_self_heal_cadence_crosses() {
        let plain = gates(&[]);
        // SAFETY: the record is a live local for the call.
        unsafe {
            assert!(!slopdesk_video_capture_should_self_heal(
                &raw const plain,
                29,
                true,
                0.0
            ));
            assert!(slopdesk_video_capture_should_self_heal(
                &raw const plain,
                30,
                true,
                0.0
            ));
            assert!(!slopdesk_video_capture_should_self_heal(
                &raw const plain,
                30,
                false,
                0.0
            ));
        }
    }

    #[test]
    fn the_backlog_verdict_and_its_index_cross() {
        let historical = gates(&[("SLOPDESK_ENCODE_QUEUE_MAX", "2")]);
        let freshest = gates(&[
            ("SLOPDESK_ENCODE_QUEUE_MAX", "2"),
            ("SLOPDESK_ENCODE_FRESHEST", "1"),
        ]);
        let full = [0_u8, 0];
        let anchored = [1_u8, 0];
        let mut index = usize::MAX;
        // SAFETY: every record and slice is a live local, and `index` is one writable `usize`.
        unsafe {
            assert_eq!(
                slopdesk_video_capture_backlog_decision(
                    &raw const historical,
                    full.as_ptr(),
                    full.len(),
                    false,
                    &raw mut index,
                ),
                CAPTURE_BACKLOG_DROP_INCOMING,
            );
            assert_eq!(index, usize::MAX, "no index is written for a drop");
            assert_eq!(
                slopdesk_video_capture_backlog_decision(
                    &raw const historical,
                    full.as_ptr(),
                    full.len(),
                    true,
                    &raw mut index,
                ),
                CAPTURE_BACKLOG_ENQUEUE,
                "a recovery anchor is never dropped",
            );
            assert_eq!(
                slopdesk_video_capture_backlog_decision(
                    &raw const freshest,
                    anchored.as_ptr(),
                    anchored.len(),
                    false,
                    &raw mut index,
                ),
                CAPTURE_BACKLOG_EVICT_OLDEST,
            );
            assert_eq!(
                index, 1,
                "the stalest UNFORCED pending frame is the one that goes"
            );
        }
    }

    #[test]
    fn the_encode_ewma_fold_crosses() {
        assert_eq!(slopdesk_video_capture_fold_encode_ewma(0.0, 8.0, 0.25), 8.0);
        let folded = slopdesk_video_capture_fold_encode_ewma(8.0, 16.0, 0.25);
        assert!(folded > 8.0 && folded < 16.0, "a later sample folds: {folded}");
    }
}
