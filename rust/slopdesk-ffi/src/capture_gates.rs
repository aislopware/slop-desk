//! The capture path's `SLOPDESK_*` operating point and its four decisions, in C —
//! `Sources/SlopDeskVideoHost/WindowCapturer.swift`.
//!
//! The same two-step shape [`crate::host_gates`] has, for the same reason:
//! [`slopdesk_video_capture_gate_keys`] hands over the NAMES, the caller resolves each through
//! `EnvConfig.string` — the env → settings-overlay precedence, a lookup rule rather than a gate
//! rule — and [`slopdesk_video_capture_gates`] takes the texts back and answers the whole table at
//! once. The texts cross as a [`blob_list`], absent entries and all, because an unset key is not an
//! empty one and `SLOPDESK_VIDEO_DEBUG` is a PRESENCE gate that reads the two oppositely.
//!
//! ## The four decisions cross too, and three of them read the table
//!
//! A gate table whose consumers each re-implement the rule it feeds is half a port. Three of these
//! doors therefore take the resolved [`SlopDeskVideoCaptureGates`] by pointer and answer the
//! question directly, so the capture callback asks rather than branches. They are on the per-frame
//! path — [`slopdesk_video_capture_needs_frame_hash`] runs once per captured frame at 60 Hz — which
//! is why they take the table by pointer instead of by value: a thirty-field aggregate copied per
//! frame would be the one thing this port could plausibly make slower than the Swift it replaces.
//!
//! [`slopdesk_video_capture_fold_encode_ewma`] is the fourth, and the only one that reads no gate
//! at all: it is three scalars in and one out.
//!
//! There were FIVE. The self-heal cadence lost its last Swift caller in `08d33f2e` and its door
//! went with it — see the note where it stood.

use core::ffi::c_uchar;

use slopdesk_video::blob_list;
use slopdesk_video::capture_gates::{
    BacklogDecision, CaptureGateContext, CaptureGates, EncodeAnchors, EncodeFrame, KEYS, fold_encode_ewma,
    monotonic_pts, synthetic_pts,
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

/// The scroll-fps cap's verdict, and the decimator state it leaves behind.
///
/// Crosses by VALUE in both directions — it is three scalars, and an in-out pointer pair for three
/// scalars would cost the caller more than the copy does.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[repr(C)]
pub struct SlopDeskVideoScrollDecimation {
    /// Consecutive fast-scroll frames, after this one.
    pub motion_run: u32,
    /// The Bresenham accumulator, after this one.
    pub phase: i32,
    /// Whether this frame goes on to the encode hand-off. `false` drops it entirely.
    pub encode: bool,
}

/// The frameQueue-owned anchors the below-gate resolution carries between frames.
///
/// The two doubles lead so the record lays out the same way under every C ABI the header is read
/// by — the same discipline every other flat table here keeps.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
#[repr(C)]
pub struct SlopDeskVideoEncodeAnchors {
    /// Uptime seconds of the last heartbeat-cadence anchor — any emitted keyframe.
    pub last_heartbeat: f64,
    /// Uptime seconds of the last EMITTED keyframe, which drives the recovery-IDR cooldown.
    pub last_keyframe_emit: f64,
    /// Live frames since the last re-anchor (keyframe or LTR refresh).
    pub frames_since_anchor: i32,
    /// The diagnostic force-compact counter.
    pub force_compact_counter: i32,
    /// Whether a frame has ever been handed to the encoder on this capturer.
    pub has_emitted_first_frame: bool,
}

/// One below-gate frame's inputs that are neither the table nor the anchors.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
#[repr(C)]
pub struct SlopDeskVideoEncodeFrame {
    /// Uptime seconds, the same clock the anchors are stamped in.
    pub now: f64,
    /// The periodic motion-IDR cadence, in seconds.
    pub heartbeat_interval: f64,
    /// The freshly-folded loss EWMA, consulted only under the clean-link gate. Infinite before any
    /// report, so an unmeasured link never suppresses healing.
    pub self_heal_loss_rate: f64,
    /// The self-heal cadence for THIS frame — the table's K rebased time-equivalently at the
    /// governed fps. Equal to the table's own K while the fps governor is inert.
    pub heal_every: i32,
    /// The DRAINED forced-keyframe latch (a client loss-recovery request).
    pub keyframe_latched: bool,
    /// The DRAINED LTR-refresh latch — the cheap recovery alternative to a forced IDR.
    pub ltr_latched: bool,
    /// Whether client LTR acks are flowing, which is what arms the self-heal cadence.
    pub self_heal_eligible: bool,
}

/// What the below-gate path does with one frame, and the anchors it leaves behind.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
#[repr(C)]
pub struct SlopDeskVideoEncodeResolution {
    /// The advanced anchors — the caller assigns every field back.
    pub anchors: SlopDeskVideoEncodeAnchors,
    /// Encode this frame as an IDR.
    pub force_keyframe: bool,
    /// Encode it SMALL+coarse. `compact ⟹ force_keyframe` for every real obligation; the
    /// DIAGNOSTIC force-compact storm is the one path that sets it alone, on purpose.
    pub compact: bool,
    /// Encode it as a cheap `ForceLTRRefresh` P-frame.
    pub ltr_refresh: bool,
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

// The self-heal cadence has NO door. `slopdesk_video_capture_should_self_heal` was one until the
// capture path's last Swift caller went in `08d33f2e`, and a door nobody opens is the second way to
// ask something `slopdesk_video::capture_gates::CaptureGates::should_self_heal` already answers —
// which is what `ffi-doors-are-opened` bans. The Rust daemon calls the values form directly, so
// re-adding the door would cost one declaration and buy nothing.

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

/// Whether a periodic motion-heartbeat IDR is DUE, gate and clock together.
///
/// `false` for a null table — the heartbeat is default-OFF, so "not due" is both the inert answer
/// and the shipped one.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const unsafe extern "C" fn slopdesk_video_capture_heartbeat_due(
    gates: *const SlopDeskVideoCaptureGates,
    now: f64,
    last_heartbeat: f64,
    interval: f64,
) -> bool {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return false;
    };
    returning(raw).heartbeat_due(now, last_heartbeat, interval)
}

/// The asymmetric smoothing law for the per-frame adaptive-QP ceiling.
///
/// `previous` is read only when `has_previous` is set — the first measured frame of a stream has no
/// smoothed value and seeds the smoother whole.
///
/// `raw_qp` for a null table, which is the un-smoothed measurement: a capturer with no gates has
/// neither ramp to smooth by.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_capture_smooth_adaptive_qp(
    gates: *const SlopDeskVideoCaptureGates,
    has_previous: bool,
    previous: i32,
    raw_qp: i32,
) -> i32 {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return raw_qp;
    };
    returning(raw).smooth_adaptive_qp(has_previous.then_some(previous), raw_qp)
}

/// The scroll-fps cap for one frame: the sustain-run debounce, then the even Bresenham decimation.
///
/// `motion_run` and `phase` are the caller's carried state and come back advanced in the answer.
/// `obligated` is the frame that owes something — a pending forced keyframe, a pending LTR refresh,
/// or a due heartbeat — and always passes.
///
/// A null table answers `{0, 0, encode}`: the cap is default-OFF and a rate cap that cannot read
/// its rate must never drop a frame.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_capture_scroll_decimation(
    gates: *const SlopDeskVideoCaptureGates,
    motion_run: u32,
    phase: i32,
    base_fps: i32,
    measured: bool,
    change_milli: u32,
    obligated: bool,
) -> SlopDeskVideoScrollDecimation {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return SlopDeskVideoScrollDecimation {
            motion_run: 0,
            phase: 0,
            encode: true,
        };
    };
    let answer =
        returning(raw).scroll_decimation(motion_run, phase, base_fps, measured, change_milli, obligated);
    SlopDeskVideoScrollDecimation {
        motion_run: answer.motion_run,
        phase: answer.phase,
        encode: answer.encode,
    }
}

/// The below-gate keyframe / compact / LTR-refresh resolution for one frame.
///
/// A pure state transition: `anchors` cross by value and come back advanced inside the answer, so
/// the caller assigns each field rather than the door writing through a pointer. `frame.heal_every`
/// is the self-heal cadence ALREADY rebased at the governed fps (`slopdesk_fps_self_heal_every`),
/// because that is the K the encoded-frame counter must be compared against.
///
/// A null table answers "encode this frame as it is" — the anchors unchanged and every verdict
/// false. That is unreachable for a running capturer (the table is resolved before the first
/// frame), and it is the answer that neither forces an IDR nor advances a clock.
///
/// # Safety
/// `gates` must be null or point to one live [`SlopDeskVideoCaptureGates`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_capture_resolve_encode(
    gates: *const SlopDeskVideoCaptureGates,
    anchors: SlopDeskVideoEncodeAnchors,
    frame: SlopDeskVideoEncodeFrame,
) -> SlopDeskVideoEncodeResolution {
    // SAFETY: the caller's obligation, restated above.
    let Some(raw) = (unsafe { gates.as_ref() }) else {
        return SlopDeskVideoEncodeResolution {
            anchors,
            force_keyframe: false,
            compact: false,
            ltr_refresh: false,
        };
    };
    let answer = returning(raw).resolve_encode(
        EncodeAnchors {
            last_heartbeat: anchors.last_heartbeat,
            last_keyframe_emit: anchors.last_keyframe_emit,
            frames_since_anchor: anchors.frames_since_anchor,
            force_compact_counter: anchors.force_compact_counter,
            has_emitted_first_frame: anchors.has_emitted_first_frame,
        },
        EncodeFrame {
            now: frame.now,
            heartbeat_interval: frame.heartbeat_interval,
            self_heal_loss_rate: frame.self_heal_loss_rate,
            heal_every: frame.heal_every,
            keyframe_latched: frame.keyframe_latched,
            ltr_latched: frame.ltr_latched,
            self_heal_eligible: frame.self_heal_eligible,
        },
    );
    SlopDeskVideoEncodeResolution {
        anchors: SlopDeskVideoEncodeAnchors {
            last_heartbeat: answer.anchors.last_heartbeat,
            last_keyframe_emit: answer.anchors.last_keyframe_emit,
            frames_since_anchor: answer.anchors.frames_since_anchor,
            force_compact_counter: answer.anchors.force_compact_counter,
            has_emitted_first_frame: answer.anchors.has_emitted_first_frame,
        },
        force_keyframe: answer.force_keyframe,
        compact: answer.compact,
        ltr_refresh: answer.ltr_refresh,
    }
}

/// One 90 kHz tick past the last emitted PTS — the synthetic-frame counter.
///
/// Reads no gate: the caller hands over the high-water tick and puts the answer back into its own
/// `CMTime`, whose timescale is the one constant that stays on that side.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_video_capture_synthetic_pts(last_ticks: i64) -> i64 {
    synthetic_pts(last_ticks)
}

/// The high-water clamp a REAL frame's PTS passes through before the encode hand-off.
///
/// Both arguments are 90 kHz ticks, so the comparison is exact and the answer is one of them.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_video_capture_monotonic_pts(last_ticks: i64, incoming_ticks: i64) -> i64 {
    monotonic_pts(last_ticks, incoming_ticks)
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
        SlopDeskVideoCaptureGates, SlopDeskVideoEncodeAnchors, SlopDeskVideoEncodeFrame,
        SlopDeskVideoScrollDecimation, slopdesk_video_capture_backlog_decision,
        slopdesk_video_capture_fold_encode_ewma, slopdesk_video_capture_gate_keys,
        slopdesk_video_capture_gates, slopdesk_video_capture_heartbeat_due,
        slopdesk_video_capture_monotonic_pts, slopdesk_video_capture_needs_frame_hash,
        slopdesk_video_capture_resolve_encode, slopdesk_video_capture_scroll_decimation,
        slopdesk_video_capture_skips_idle_frame, slopdesk_video_capture_smooth_adaptive_qp,
        slopdesk_video_capture_synthetic_pts,
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
    fn the_three_table_doors_answer_inertly_for_a_null_table() {
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

    /// An ordinary below-gate frame, as the capturer hands one over.
    const LIVE: SlopDeskVideoEncodeFrame = SlopDeskVideoEncodeFrame {
        now: 100.0,
        heartbeat_interval: 2.5,
        self_heal_loss_rate: f64::INFINITY,
        heal_every: 30,
        keyframe_latched: false,
        ltr_latched: false,
        self_heal_eligible: true,
    };

    /// A capturer that has already delivered, both clocks anchored at the frame's own `now`.
    const ANCHORED: SlopDeskVideoEncodeAnchors = SlopDeskVideoEncodeAnchors {
        last_heartbeat: 100.0,
        last_keyframe_emit: 100.0,
        frames_since_anchor: 0,
        force_compact_counter: 0,
        has_emitted_first_frame: true,
    };

    #[test]
    fn the_adaptive_qp_smoother_crosses_with_its_option() {
        let plain = gates(&[]);
        // SAFETY: the record is a live local for the call.
        unsafe {
            assert_eq!(
                slopdesk_video_capture_smooth_adaptive_qp(&raw const plain, false, 99, 37),
                37,
                "no previous value: the first measured frame seeds the smoother whole",
            );
            assert_eq!(
                slopdesk_video_capture_smooth_adaptive_qp(&raw const plain, true, 40, 22),
                36,
                "the default down-step is 4",
            );
        }
        let ramped = gates(&[("SLOPDESK_AQP_UP_RAMP", "4")]);
        // SAFETY: as above.
        unsafe {
            assert_eq!(
                slopdesk_video_capture_smooth_adaptive_qp(&raw const ramped, true, 22, 23),
                23,
                "a step that rounds to zero still moves one QP",
            );
        }
    }

    #[test]
    fn the_scroll_decimation_and_its_carried_state_cross() {
        let capped = gates(&[("SLOPDESK_SCROLL_FPS", "30")]);
        let fast = capped.scroll_motion_threshold_milli;
        // SAFETY: the record is a live local for every call.
        unsafe {
            let first =
                slopdesk_video_capture_scroll_decimation(&raw const capped, 0, 0, 60, true, fast, false);
            assert_eq!(first, SlopDeskVideoScrollDecimation {
                motion_run: 1,
                phase: 0,
                encode: true,
            });
            let second = slopdesk_video_capture_scroll_decimation(
                &raw const capped,
                first.motion_run,
                first.phase,
                60,
                true,
                fast,
                false,
            );
            assert!(!second.encode, "30 of 60 keeps every other sustained frame");
            // An obligated frame always passes, however long the run.
            let owed = slopdesk_video_capture_scroll_decimation(
                &raw const capped,
                second.motion_run,
                second.phase,
                60,
                true,
                fast,
                true,
            );
            assert!(owed.encode);
            assert_eq!(owed.phase, 0);
        }
    }

    #[test]
    fn the_below_gate_resolution_crosses_whole() {
        let plain = gates(&[]);
        // SAFETY: the record is a live local for every call.
        unsafe {
            let first = slopdesk_video_capture_resolve_encode(
                &raw const plain,
                SlopDeskVideoEncodeAnchors {
                    has_emitted_first_frame: false,
                    ..ANCHORED
                },
                LIVE,
            );
            assert!(first.force_keyframe);
            assert!(!first.compact, "the FIRST frame stays full quality");
            assert!(first.anchors.has_emitted_first_frame);

            let latched = slopdesk_video_capture_resolve_encode(
                &raw const plain,
                first.anchors,
                SlopDeskVideoEncodeFrame {
                    keyframe_latched: true,
                    ..LIVE
                },
            );
            assert!(latched.force_keyframe);
            assert!(latched.compact, "a live forced IDR is compact");

            let healed = slopdesk_video_capture_resolve_encode(
                &raw const plain,
                SlopDeskVideoEncodeAnchors {
                    frames_since_anchor: 29,
                    ..ANCHORED
                },
                LIVE,
            );
            assert!(healed.ltr_refresh, "the 30th delta is the self-heal refresh");
            assert_eq!(healed.anchors.frames_since_anchor, 0);
        }
    }

    #[test]
    fn the_three_new_table_doors_answer_inertly_for_a_null_table() {
        // SAFETY: null is the one pointer these doors are asked to answer for.
        unsafe {
            assert!(!slopdesk_video_capture_heartbeat_due(
                core::ptr::null(),
                100.0,
                0.0,
                2.5
            ));
            assert_eq!(
                slopdesk_video_capture_smooth_adaptive_qp(core::ptr::null(), true, 22, 40),
                40,
                "the un-smoothed measurement is the inert answer",
            );
            assert_eq!(
                slopdesk_video_capture_scroll_decimation(core::ptr::null(), 9, 30, 60, true, 999, false),
                SlopDeskVideoScrollDecimation {
                    motion_run: 0,
                    phase: 0,
                    encode: true,
                },
                "a rate cap that cannot read its rate drops nothing",
            );
            let refused = slopdesk_video_capture_resolve_encode(core::ptr::null(), ANCHORED, LIVE);
            assert_eq!(refused.anchors, ANCHORED, "no clock advances");
            assert!(!refused.force_keyframe);
            assert!(!refused.compact);
            assert!(!refused.ltr_refresh);
        }
    }

    #[test]
    fn the_heartbeat_clock_crosses_with_its_gate() {
        let plain = gates(&[]);
        let beating = gates(&[("SLOPDESK_MOTION_HEARTBEAT", "1")]);
        // SAFETY: both records are live locals for the call.
        unsafe {
            assert!(!slopdesk_video_capture_heartbeat_due(
                &raw const plain,
                100.0,
                0.0,
                2.5
            ));
            assert!(slopdesk_video_capture_heartbeat_due(
                &raw const beating,
                100.0,
                97.5,
                2.5
            ));
            assert!(!slopdesk_video_capture_heartbeat_due(
                &raw const beating,
                100.0,
                97.6,
                2.5
            ));
        }
    }

    #[test]
    fn the_pts_counter_and_its_clamp_cross() {
        assert_eq!(slopdesk_video_capture_synthetic_pts(90_000), 90_001);
        assert_eq!(slopdesk_video_capture_synthetic_pts(i64::MAX), i64::MAX);
        assert_eq!(slopdesk_video_capture_monotonic_pts(90_001, 90_000), 90_001);
        assert_eq!(slopdesk_video_capture_monotonic_pts(90_001, 180_000), 180_000);
    }

    #[test]
    fn the_encode_ewma_fold_crosses() {
        assert_eq!(slopdesk_video_capture_fold_encode_ewma(0.0, 8.0, 0.25), 8.0);
        let folded = slopdesk_video_capture_fold_encode_ewma(8.0, 16.0, 0.25);
        assert!(folded > 8.0 && folded < 16.0, "a later sample folds: {folded}");
    }
}
