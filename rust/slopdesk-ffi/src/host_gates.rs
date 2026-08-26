//! The video host's `SLOPDESK_*` operating point, in C —
//! `Sources/SlopDeskVideoHost/SlopDeskVideoHostSession.swift`.
//!
//! Two entry points, because the family is resolved in two steps and only the middle one is Swift's
//! business. [`slopdesk_video_host_gate_keys`] hands over the NAMES; the caller looks each up
//! through `EnvConfig.string` — the env → settings-overlay precedence, which is a lookup rule and
//! not a gate rule — and [`slopdesk_video_host_gates`] takes the resolved texts back and answers
//! the whole operating point at once.
//!
//! The texts cross in the blob-list shape [`slopdesk_video::blob_list`] already defines, absent
//! entries and all, rather than in a format invented for this door. An unset key IS an absent blob
//! there, and the distinction is load-bearing twice over: `SLOPDESK_VIDEO_DEBUG` is a PRESENCE
//! gate, so absent and empty are opposite answers, and `SLOPDESK_PACE_ADAPTIVE` is overridden by
//! the mere presence of a sibling key whose value never parses.
//!
//! Resolved ONCE per process, at the first `static let` that forces it — so this is not a hot door
//! and the whole table crossing by value is the cheap half of what the thirty-three separate
//! `ProcessInfo` reads it replaces cost.

use core::ffi::c_uchar;

use slopdesk_video::blob_list;
use slopdesk_video::host_gates::{GateContext, HostGates, KEYS};

use crate::{borrow, deliver};

/// The resolved operating point, field for field with `slopdesk_video`'s own.
///
/// Flat and `repr(C)` rather than a packed blob: the caller reads these one at a time from thirty
/// different places in a three-thousand-line actor, and a hand-decoded offset per read is exactly
/// the transcription this door exists to delete.
#[derive(Debug, Clone, Copy, Default)]
#[repr(C)]
pub struct SlopDeskVideoHostGates {
    /// Mirror lifecycle beats to stderr. PRESENCE, not value.
    pub debug_stderr: bool,
    /// Burst-resilient transmit interleaving. Default ON.
    pub interleave_transmit: bool,
    /// Chunked send pacing at all. Default ON.
    pub pace_send: bool,
    /// Compute the pacing gap from the live ABR target. Default ON, lost to an explicit pin.
    pub pacing_adaptive: bool,
    /// Route paced sends through the dedicated lane. Default ON.
    pub send_lane_enabled: bool,
    /// Drop a capture frame before encode when the lane is deep. Default ON.
    pub backpressure_enabled: bool,
    /// Sum consecutive same-phase scroll deltas into one post.
    pub scroll_coalesce_enabled: bool,
    /// The schedule-anchored encode cadence governor. Default OFF.
    pub fps_governor_enabled: bool,
    /// Reconfigure a live capture stream on resize. Default ON.
    pub in_place_resize_enabled: bool,
    /// Duplicate-send keyframes. Default ON.
    pub kf_dup: bool,
    /// Duplicate-send small changed deltas. Default OFF.
    pub small_dup: bool,
    /// Answer client NACKs from a send history. Default OFF.
    pub nack_enabled: bool,
    /// Delivery-keyed recovery-IDR cooldown. Default ON.
    pub recovery_idr_v2: bool,
    /// Stamp send times and fold the client's reports. Default ON.
    pub telemetry_enabled: bool,
    /// Actuate the congestion controller's target. Default ON.
    pub abr_enabled: bool,
    /// Pick the per-frame FEC tier from measured loss. Default ON.
    pub adaptive_fec_enabled: bool,
    /// Full-range colour on all four coupled points. Default OFF.
    pub full_range: bool,
    /// Long-term-reference recovery. Default ON.
    pub ltr_enabled: bool,
    /// Log every injected input event. PRESENCE, not value.
    pub input_trace: bool,
    /// Expand the capture region over a system dialog. Default ON.
    pub dialog_expand_enabled: bool,
    /// Build the packetizer with no FEC scheme at all. Only `SLOPDESK_FEC=0`.
    pub fec_disabled: bool,
    /// The static inter-chunk gap, in NANOSECONDS.
    pub pace_gap_nanos: u64,
    /// Pace at this multiple of the live target. `1…10`, default 2.5.
    pub pace_rate_multiplier: f64,
    /// Keyframe pace-rate floor, bits per second.
    pub kf_pace_floor_bps: i64,
    /// Delta pace-rate floor, bits per second; 0 means raw-ABR pacing.
    pub delta_pace_floor_bps: i64,
    /// The lane depth that starts dropping.
    pub backpressure_depth: i64,
    /// Minimum interval between injected summed scrolls, in SECONDS.
    pub scroll_inject_interval: f64,
    /// The smoothed loss rate at which keyframe duplication arms.
    pub kf_dup_loss_threshold: f64,
    /// The encoded byte length below which a delta counts as small.
    pub small_dup_max_bytes: i64,
    /// Retransmit ring depth, in frames.
    pub retransmit_ring_frames: i64,
    /// Retransmit ring ceiling, in bytes.
    pub retransmit_ring_max_bytes: i64,
    /// The recovery-request dedup window, in SECONDS; 0 admits every datagram.
    pub recovery_dedup_window: f64,
    /// Pause capture after this many SECONDS of client silence; 0 disables.
    pub client_silence_pause_seconds: f64,
}

/// The operating point as it crosses.
const fn crossing(gates: HostGates) -> SlopDeskVideoHostGates {
    SlopDeskVideoHostGates {
        debug_stderr: gates.debug_stderr,
        interleave_transmit: gates.interleave_transmit,
        pace_send: gates.pace_send,
        pacing_adaptive: gates.pacing_adaptive,
        send_lane_enabled: gates.send_lane_enabled,
        backpressure_enabled: gates.backpressure_enabled,
        scroll_coalesce_enabled: gates.scroll_coalesce_enabled,
        fps_governor_enabled: gates.fps_governor_enabled,
        in_place_resize_enabled: gates.in_place_resize_enabled,
        kf_dup: gates.kf_dup,
        small_dup: gates.small_dup,
        nack_enabled: gates.nack_enabled,
        recovery_idr_v2: gates.recovery_idr_v2,
        telemetry_enabled: gates.telemetry_enabled,
        abr_enabled: gates.abr_enabled,
        adaptive_fec_enabled: gates.adaptive_fec_enabled,
        full_range: gates.full_range,
        ltr_enabled: gates.ltr_enabled,
        input_trace: gates.input_trace,
        dialog_expand_enabled: gates.dialog_expand_enabled,
        fec_disabled: gates.fec_disabled,
        pace_gap_nanos: gates.pace_gap_nanos,
        pace_rate_multiplier: gates.pace_rate_multiplier,
        kf_pace_floor_bps: gates.kf_pace_floor_bps,
        delta_pace_floor_bps: gates.delta_pace_floor_bps,
        backpressure_depth: gates.backpressure_depth,
        scroll_inject_interval: gates.scroll_inject_interval,
        kf_dup_loss_threshold: gates.kf_dup_loss_threshold,
        small_dup_max_bytes: gates.small_dup_max_bytes,
        retransmit_ring_frames: gates.retransmit_ring_frames,
        retransmit_ring_max_bytes: gates.retransmit_ring_max_bytes,
        recovery_dedup_window: gates.recovery_dedup_window,
        client_silence_pause_seconds: gates.client_silence_pause_seconds,
    }
}

/// The environment key names, `\0`-separated, in the order the values must come back.
///
/// No trailing separator, so a split on `\0` yields exactly the key count. The caller resolves each
/// name through its own overlay-aware lookup — the list is Rust's because the table that reads it
/// is, and a name spelled here but resolved there under a typo would silently answer its default.
///
/// # Safety
/// `out` must be null or writable for `cap` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub unsafe extern "C" fn slopdesk_video_host_gate_keys(out: *mut c_uchar, cap: usize) -> usize {
    let answer = KEYS.join("\0");
    // SAFETY: the caller's obligation, restated above; `deliver` states its own.
    unsafe { deliver(answer.as_bytes(), out, cap) }
}

/// Resolves the whole operating point from the texts of the keys above.
///
/// `values` is a [`blob_list`] whose entries are those texts in key order, with an ABSENT entry for
/// a key the environment does not set — which is not the same as an empty one, and the two presence
/// gates are why.
///
/// The three scalars are the inputs no key carries: whether the injector's scroll resampler is
/// active (the coalescer's default follows it) and the keepalive window the client-silence pause is
/// clamped into. They are the caller's resolved constants, so they cross rather than being read
/// from a crate this one does not depend on.
///
/// Answers `false` and writes nothing when the blob is not a blob list or an entry is not UTF-8 —
/// both of which mean the caller built the list wrong, since it built it from its own environment.
///
/// # Safety
/// `values` must be null or point to `len` live bytes; `out` null or writable for one
/// [`SlopDeskVideoHostGates`].
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point, and `out` is the caller's to keep live"
)]
pub unsafe extern "C" fn slopdesk_video_host_gates(
    values: *const c_uchar,
    len: usize,
    scroll_resampler_active: bool,
    keepalive_interval: f64,
    idle_timeout: f64,
    out: *mut SlopDeskVideoHostGates,
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
    let gates = crossing(HostGates::from_env(&texts, GateContext {
        scroll_resampler_active,
        keepalive_interval,
        idle_timeout,
    }));
    if out.is_null() {
        return false;
    }
    // SAFETY: the caller's obligation, restated above — `out` is non-null here and the caller
    // guarantees it is writable for one of these, which is a plain `Copy` aggregate.
    unsafe { out.write(gates) };
    true
}

#[cfg(test)]
#[expect(unsafe_code, reason = "calling the door is the only way to test the door")]
mod tests {
    use slopdesk_video::blob_list;
    use slopdesk_video::host_gates::KEYS;

    use super::{SlopDeskVideoHostGates, slopdesk_video_host_gate_keys, slopdesk_video_host_gates};

    /// The names cross whole and in order, so a caller that splits on `\0` gets the key list back.
    #[test]
    fn the_key_list_crosses_in_order() {
        // SAFETY: a null `out` with a zero cap asks for the size, which is the door's own contract.
        let needed = unsafe { slopdesk_video_host_gate_keys(core::ptr::null_mut(), 0) };
        let mut buffer = vec![0u8; needed];
        // SAFETY: `buffer` is live and exactly `needed` bytes long.
        let written = unsafe { slopdesk_video_host_gate_keys(buffer.as_mut_ptr(), buffer.len()) };
        assert_eq!(written, needed);
        let text = String::from_utf8_lossy(&buffer);
        let names: Vec<&str> = text.split('\0').collect();
        assert_eq!(names, KEYS.to_vec());
    }

    /// Resolves one gate through the door, to pin the blob shape the caller has to build: an
    /// ABSENT entry for an unset key, a present one for a set key, in key order.
    #[test]
    fn a_present_entry_reaches_its_gate_and_an_absent_one_does_not() {
        let set: Vec<Option<&[u8]>> = KEYS
            .iter()
            .map(|key| (*key == "SLOPDESK_ABR").then_some(b"0".as_slice()))
            .collect();
        let blob = blob_list::encode(&set);
        let mut gates = SlopDeskVideoHostGates::default();
        // SAFETY: both pointers are into live local storage for the length given.
        let ok =
            unsafe { slopdesk_video_host_gates(blob.as_ptr(), blob.len(), true, 5.0, 30.0, &raw mut gates) };
        assert!(ok);
        assert!(!gates.abr_enabled, "the one set key was read");
        assert!(gates.ltr_enabled, "and every absent one kept its default");
    }

    /// A blob that is not a blob list is a caller bug, and is refused rather than half-read.
    #[test]
    fn a_malformed_blob_is_refused() {
        let junk = [0xFF_u8, 0xFF, 0xFF];
        let mut gates = SlopDeskVideoHostGates::default();
        // SAFETY: both pointers are into live local storage for the length given.
        let ok =
            unsafe { slopdesk_video_host_gates(junk.as_ptr(), junk.len(), true, 5.0, 30.0, &raw mut gates) };
        assert!(!ok);
    }
}
