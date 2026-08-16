//! The presentation depth's two laws: the one-way-delay spike detector, and the policy that pays
//! one frame of standing latency for a spell of spikes and refunds it after a clean dwell.
//!
//! Both are Swift `struct`s their owner copies out, folds into and writes back, so both cross BY
//! VALUE — `(state, sample) -> state`, with the whole state travelling every time. There is no
//! handle and nothing is allocated on either side of a fold.
//!
//! ## Why the RINGS travel
//!
//! A promote window, a demote dwell and the dense-flow gate all read TIMES rather than counts: the
//! question is not "how many lates" but "how many inside the last second", and the ring is the only
//! place that answer lives. A crossing that carried the counters would be a different policy that
//! happened to agree while nothing aged out. So the three rings cross as fixed-capacity arrays —
//! sixteen arrivals, fifteen intervals, four lates — which are the capacities the folds themselves
//! cap at, and `interval_ring_size` is capped to the carried capacity when the state is rebuilt.
//!
//! ## Why the ENVIRONMENT is applied one pair at a time
//!
//! The caller holds a whole environment map and the bands live here, so the door takes a KEY and a
//! VALUE and answers the config that results. The alternative — nine optional strings in one call —
//! puts the names on the near side, which is the same law written twice.

use core::ffi::c_uchar;

use slopdesk_video::pacer_depth::{
    ARRIVAL_RING_CAPACITY, GapClass, INTERVAL_RING_CAPACITY, LATE_RING_CAPACITY, OwdLateConfig,
    OwdLateDetector, OwdLateSnapshot, PacerDepthConfig, PacerDepthPolicy, PacerDepthSnapshot,
};

use crate::{borrow, optional, optional_of};

/// The first present of a stream, which has no gap to classify.
pub const SLOPDESK_GAP_CLASS_FIRST: u32 = 0;
/// Inside the expected cadence.
pub const SLOPDESK_GAP_CLASS_NORMAL: u32 = 1;
/// Past the late boundary, dense enough to matter, and a sharp step up from the last gap.
pub const SLOPDESK_GAP_CLASS_LATE: u32 = 2;
/// Long enough to be a host idle-skip or a motion stop, which is never late.
pub const SLOPDESK_GAP_CLASS_IDLE: u32 = 3;

/// The gap classification as a plain code.
const fn gap_code(class: GapClass) -> u32 {
    match class {
        GapClass::First => SLOPDESK_GAP_CLASS_FIRST,
        GapClass::Normal => SLOPDESK_GAP_CLASS_NORMAL,
        GapClass::Late => SLOPDESK_GAP_CLASS_LATE,
        GapClass::Idle => SLOPDESK_GAP_CLASS_IDLE,
    }
}

// ---------------------------------------------------------------------------------------------
// The spike detector
// ---------------------------------------------------------------------------------------------

/// The detector's operating point, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskOwdLateConfig {
    /// The baseline bucket span in milliseconds; the effective history is one to two buckets.
    pub bucket_ms: f64,
    /// The absolute spike floor in milliseconds, which sits above the send lane's own wobble.
    pub threshold_floor_ms: f64,
    /// The interval-proportional component of the threshold.
    pub threshold_interval_fraction: f64,
    /// How many samples the baseline needs before any late verdict.
    pub warmup_samples: usize,
}

impl SlopDeskOwdLateConfig {
    /// The wrapped config this describes.
    const fn inner(self) -> OwdLateConfig {
        OwdLateConfig {
            bucket_ms: self.bucket_ms,
            threshold_floor_ms: self.threshold_floor_ms,
            threshold_interval_fraction: self.threshold_interval_fraction,
            warmup_samples: self.warmup_samples,
        }
    }

    /// The crossing form of a wrapped config.
    const fn of(config: OwdLateConfig) -> Self {
        Self {
            bucket_ms: config.bucket_ms,
            threshold_floor_ms: config.threshold_floor_ms,
            threshold_interval_fraction: config.threshold_interval_fraction,
            warmup_samples: config.warmup_samples,
        }
    }
}

/// The operating point the detector ships with.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_owd_late_config_default() -> SlopDeskOwdLateConfig {
    SlopDeskOwdLateConfig::of(OwdLateConfig::default())
}

/// Applies ONE environment pair to a config and answers the config that results.
///
/// An unknown key, an unparseable value and a non-finite one all answer the config unchanged, so a
/// caller can walk its whole environment without filtering first.
///
/// # Safety
/// `(key, key_len)` and `(value, value_len)` must each describe live memory for the whole call, or
/// be null.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_owd_late_config_apply(
    config: SlopDeskOwdLateConfig,
    key: *const c_uchar,
    key_len: usize,
    value: *const c_uchar,
    value_len: usize,
) -> SlopDeskOwdLateConfig {
    // SAFETY: each pair is live for the call or null, which borrows as empty.
    let (key_bytes, value_bytes) = unsafe { (borrow(key, key_len), borrow(value, value_len)) };
    let mut inner = config.inner();
    inner.apply_env_pair(
        &String::from_utf8_lossy(key_bytes),
        &String::from_utf8_lossy(value_bytes),
    );
    SlopDeskOwdLateConfig::of(inner)
}

/// The detector's whole state, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskOwdLate {
    /// The operating point, which travels with the state.
    pub config: SlopDeskOwdLateConfig,
    /// The monotone unwrapped send stamp, in milliseconds.
    pub unwrapped_send_ms: f64,
    /// Whether a previous wire stamp exists to step from.
    pub has_prev_send_ts: bool,
    /// The previous wire stamp.
    pub prev_send_ts: u32,
    /// The minimum inside the live bucket.
    pub current_bucket_min: f64,
    /// The minimum inside the bucket before it.
    pub previous_bucket_min: f64,
    /// Whether a bucket is open.
    pub has_bucket_start: bool,
    /// When the live bucket opened, on the arrival clock.
    pub bucket_start_arrival_ms: f64,
    /// How many samples have landed.
    pub samples: usize,
}

impl SlopDeskOwdLate {
    /// The wrapped detector this describes.
    fn inner(self) -> OwdLateDetector {
        OwdLateDetector::restored(OwdLateSnapshot {
            config: self.config.inner(),
            unwrapped_send_ms: self.unwrapped_send_ms,
            prev_send_ts: self.has_prev_send_ts.then_some(self.prev_send_ts),
            current_bucket_min: self.current_bucket_min,
            previous_bucket_min: self.previous_bucket_min,
            bucket_start_arrival_ms: optional_of(self.has_bucket_start, self.bucket_start_arrival_ms),
            samples: self.samples,
        })
    }

    /// The crossing form of a wrapped detector.
    fn of(detector: &OwdLateDetector) -> Self {
        let snapshot = detector.snapshot();
        let (has_bucket_start, bucket_start_arrival_ms) = optional(snapshot.bucket_start_arrival_ms, 0.0);
        Self {
            config: SlopDeskOwdLateConfig::of(snapshot.config),
            unwrapped_send_ms: snapshot.unwrapped_send_ms,
            has_prev_send_ts: snapshot.prev_send_ts.is_some(),
            prev_send_ts: snapshot.prev_send_ts.unwrap_or(0),
            current_bucket_min: snapshot.current_bucket_min,
            previous_bucket_min: snapshot.previous_bucket_min,
            has_bucket_start,
            bucket_start_arrival_ms,
            samples: snapshot.samples,
        }
    }
}

/// A detector at the given operating point, with an empty baseline.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_owd_late_new(config: SlopDeskOwdLateConfig) -> SlopDeskOwdLate {
    SlopDeskOwdLate::of(&OwdLateDetector::new(config.inner()))
}

/// One folded sample: the detector that results, and how far past the threshold it sat.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskOwdLateNote {
    /// The detector after the fold.
    pub detector: SlopDeskOwdLate,
    /// Whether the sample was a spike at all.
    pub has_deviation: bool,
    /// How far past the threshold it sat, in milliseconds.
    pub deviation_ms: f64,
}

/// Folds one per-frame sample and answers whether it was a network-late spike.
///
/// The caller admits one sample per strictly-newer frame id, so reordered frames, keyframe
/// duplicates and a zero stamp never reach here.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_owd_late_note(
    detector: SlopDeskOwdLate,
    arrival_ms: f64,
    send_ts: u32,
    interval_ms: f64,
) -> SlopDeskOwdLateNote {
    let mut inner = detector.inner();
    let (has_deviation, deviation_ms) = optional(inner.note(arrival_ms, send_ts, interval_ms), 0.0);
    SlopDeskOwdLateNote {
        detector: SlopDeskOwdLate::of(&inner),
        has_deviation,
        deviation_ms,
    }
}

// ---------------------------------------------------------------------------------------------
// The depth policy
// ---------------------------------------------------------------------------------------------

/// The policy's operating point, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPacerDepthConfig {
    /// A gap is late past the greater of the absolute floor and this factor times the interval.
    pub late_gap_factor: f64,
    /// The hardware-validated stall threshold, in seconds.
    pub absolute_late_floor_seconds: f64,
    /// A gap above this is idle and never late.
    pub idle_gap_seconds: f64,
    /// Late additionally requires this multiple of the previous in-flow gap.
    pub gap_gradient_factor: f64,
    /// Dense flow is at least this many arrivals inside the dense window.
    pub dense_min_arrivals: usize,
    /// The window the dense-flow count runs over, in seconds.
    pub dense_window_seconds: f64,
    /// Extra margin on the late boundary, as a fraction of the expected interval.
    pub late_slack_fraction: f64,
    /// Promote on this many late events inside the promote window.
    pub promote_late_count: usize,
    /// The window the promote count runs over, in seconds.
    pub promote_window_seconds: f64,
    /// Demote after this long with at most the tolerated number of lates.
    pub demote_clean_seconds: f64,
    /// The anti-flap: never demote sooner than this after a promotion.
    pub min_hold_seconds: f64,
    /// How many late events the trailing dwell tolerates and still demotes.
    pub demote_tolerance_lates: usize,
    /// How long after the first arrival promote DECISIONS are ignored.
    pub promote_warmup_seconds: f64,
    /// The boosted depth.
    pub boost_depth: u32,
    /// How many in-flow gaps the interval estimator KEEPS, capped at the carried capacity.
    pub interval_ring_size: usize,
    /// How many it needs before it is trusted over the default.
    pub min_samples_for_estimate: usize,
    /// The interval assumed before the estimator warms, in seconds.
    pub default_interval_seconds: f64,
    /// The floor the expected interval is clamped to.
    pub min_interval_seconds: f64,
    /// The ceiling the expected interval is clamped to.
    pub max_interval_seconds: f64,
}

impl SlopDeskPacerDepthConfig {
    /// The wrapped config this describes.
    fn inner(self) -> PacerDepthConfig {
        PacerDepthConfig {
            late_gap_factor: self.late_gap_factor,
            absolute_late_floor_seconds: self.absolute_late_floor_seconds,
            idle_gap_seconds: self.idle_gap_seconds,
            gap_gradient_factor: self.gap_gradient_factor,
            dense_min_arrivals: self.dense_min_arrivals,
            dense_window_seconds: self.dense_window_seconds,
            late_slack_fraction: self.late_slack_fraction,
            promote_late_count: self.promote_late_count,
            promote_window_seconds: self.promote_window_seconds,
            demote_clean_seconds: self.demote_clean_seconds,
            min_hold_seconds: self.min_hold_seconds,
            demote_tolerance_lates: self.demote_tolerance_lates,
            promote_warmup_seconds: self.promote_warmup_seconds,
            boost_depth: self.boost_depth,
            // A ring that kept more than the crossing carries would lose its oldest entry on every
            // trip, so the kept size is capped here rather than truncated silently later.
            interval_ring_size: self.interval_ring_size.min(INTERVAL_RING_CAPACITY),
            min_samples_for_estimate: self.min_samples_for_estimate,
            default_interval_seconds: self.default_interval_seconds,
            min_interval_seconds: self.min_interval_seconds,
            max_interval_seconds: self.max_interval_seconds,
        }
    }

    /// The crossing form of a wrapped config.
    const fn of(config: PacerDepthConfig) -> Self {
        Self {
            late_gap_factor: config.late_gap_factor,
            absolute_late_floor_seconds: config.absolute_late_floor_seconds,
            idle_gap_seconds: config.idle_gap_seconds,
            gap_gradient_factor: config.gap_gradient_factor,
            dense_min_arrivals: config.dense_min_arrivals,
            dense_window_seconds: config.dense_window_seconds,
            late_slack_fraction: config.late_slack_fraction,
            promote_late_count: config.promote_late_count,
            promote_window_seconds: config.promote_window_seconds,
            demote_clean_seconds: config.demote_clean_seconds,
            min_hold_seconds: config.min_hold_seconds,
            demote_tolerance_lates: config.demote_tolerance_lates,
            promote_warmup_seconds: config.promote_warmup_seconds,
            boost_depth: config.boost_depth,
            interval_ring_size: config.interval_ring_size,
            min_samples_for_estimate: config.min_samples_for_estimate,
            default_interval_seconds: config.default_interval_seconds,
            min_interval_seconds: config.min_interval_seconds,
            max_interval_seconds: config.max_interval_seconds,
        }
    }
}

/// The operating point the policy ships with.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_config_default() -> SlopDeskPacerDepthConfig {
    SlopDeskPacerDepthConfig::of(PacerDepthConfig::default())
}

/// Applies ONE environment pair to a config and answers the config that results.
///
/// An unknown key, an unparseable value and a non-finite one all answer the config unchanged, so a
/// caller can walk its whole environment without filtering first.
///
/// # Safety
/// `(key, key_len)` and `(value, value_len)` must each describe live memory for the whole call, or
/// be null.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pacer_depth_config_apply(
    config: SlopDeskPacerDepthConfig,
    key: *const c_uchar,
    key_len: usize,
    value: *const c_uchar,
    value_len: usize,
) -> SlopDeskPacerDepthConfig {
    // SAFETY: each pair is live for the call or null, which borrows as empty.
    let (key_bytes, value_bytes) = unsafe { (borrow(key, key_len), borrow(value, value_len)) };
    let mut inner = config.inner();
    inner.apply_env_pair(
        &String::from_utf8_lossy(key_bytes),
        &String::from_utf8_lossy(value_bytes),
    );
    SlopDeskPacerDepthConfig::of(inner)
}

/// The policy's whole state, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPacerDepth {
    /// The operating point, which travels with the state.
    pub config: SlopDeskPacerDepthConfig,
    /// Whether the depth ACTION runs at all. The counters run either way.
    pub adapt_enabled: bool,
    /// The live depth.
    pub depth: u32,
    /// Whether an arrival has landed.
    pub has_last_arrival: bool,
    /// The last arrival, which the next in-flow gap steps from.
    pub last_arrival: f64,
    /// The dense-flow ring, oldest first.
    pub arrivals: [f64; ARRIVAL_RING_CAPACITY],
    /// How many of the arrival ring's slots are live.
    pub arrival_len: usize,
    /// The in-flow inter-arrival gaps the estimator holds, oldest first.
    pub intervals: [f64; INTERVAL_RING_CAPACITY],
    /// How many of the interval ring's slots are live.
    pub interval_len: usize,
    /// Whether the governor has pinned the cadence.
    pub has_interval_hint: bool,
    /// The pinned cadence, in seconds.
    pub interval_hint: f64,
    /// Whether a content present has landed.
    pub has_last_present_at: bool,
    /// The last content present.
    pub last_present_at: f64,
    /// Whether a previous in-flow gap exists to compare against.
    pub has_prev_present_gap: bool,
    /// The previous in-flow present gap.
    pub prev_present_gap: f64,
    /// The late-event ring, oldest first.
    pub lates: [f64; LATE_RING_CAPACITY],
    /// How many of the late ring's slots are live.
    pub late_len: usize,
    /// Whether a promotion has ever happened.
    pub has_promoted_at: bool,
    /// When the last promotion happened.
    pub promoted_at: f64,
    /// Whether the stream has started.
    pub has_stream_start_at: bool,
    /// The stream's first arrival, which the promote warm-up measures from.
    pub stream_start_at: f64,
    /// Whether a re-show episode is open and therefore already counted.
    pub gap_episode_open: bool,
    /// The windowed late counter.
    pub late_count: u32,
    /// The windowed gap-episode counter.
    pub gap_count: u32,
}

impl SlopDeskPacerDepth {
    /// The wrapped policy this describes.
    fn inner(&self) -> PacerDepthPolicy {
        PacerDepthPolicy::restored(PacerDepthSnapshot {
            config: self.config.inner(),
            adapt_enabled: self.adapt_enabled,
            depth: self.depth,
            last_arrival: optional_of(self.has_last_arrival, self.last_arrival),
            arrivals: self.arrivals,
            arrival_len: self.arrival_len,
            intervals: self.intervals,
            interval_len: self.interval_len,
            interval_hint: optional_of(self.has_interval_hint, self.interval_hint),
            last_present_at: optional_of(self.has_last_present_at, self.last_present_at),
            prev_present_gap: optional_of(self.has_prev_present_gap, self.prev_present_gap),
            lates: self.lates,
            late_len: self.late_len,
            promoted_at: optional_of(self.has_promoted_at, self.promoted_at),
            stream_start_at: optional_of(self.has_stream_start_at, self.stream_start_at),
            gap_episode_open: self.gap_episode_open,
            late_count: self.late_count,
            gap_count: self.gap_count,
        })
    }

    /// The crossing form of a wrapped policy.
    fn of(policy: &PacerDepthPolicy) -> Self {
        let snapshot = policy.snapshot();
        let (has_last_arrival, last_arrival) = optional(snapshot.last_arrival, 0.0);
        let (has_interval_hint, interval_hint) = optional(snapshot.interval_hint, 0.0);
        let (has_last_present_at, last_present_at) = optional(snapshot.last_present_at, 0.0);
        let (has_prev_present_gap, prev_present_gap) = optional(snapshot.prev_present_gap, 0.0);
        let (has_promoted_at, promoted_at) = optional(snapshot.promoted_at, 0.0);
        let (has_stream_start_at, stream_start_at) = optional(snapshot.stream_start_at, 0.0);
        Self {
            config: SlopDeskPacerDepthConfig::of(snapshot.config),
            adapt_enabled: snapshot.adapt_enabled,
            depth: snapshot.depth,
            has_last_arrival,
            last_arrival,
            arrivals: snapshot.arrivals,
            arrival_len: snapshot.arrival_len,
            intervals: snapshot.intervals,
            interval_len: snapshot.interval_len,
            has_interval_hint,
            interval_hint,
            has_last_present_at,
            last_present_at,
            has_prev_present_gap,
            prev_present_gap,
            lates: snapshot.lates,
            late_len: snapshot.late_len,
            has_promoted_at,
            promoted_at,
            has_stream_start_at,
            stream_start_at,
            gap_episode_open: snapshot.gap_episode_open,
            late_count: snapshot.late_count,
            gap_count: snapshot.gap_count,
        }
    }
}

/// A policy at the given operating point, at depth one with every ring empty.
///
/// Adaptation off leaves the depth at one forever while every counter keeps running.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_new(
    config: SlopDeskPacerDepthConfig,
    adapt_enabled: bool,
) -> SlopDeskPacerDepth {
    SlopDeskPacerDepth::of(&PacerDepthPolicy::new(config.inner(), adapt_enabled))
}

/// The expected content interval: the hint when set, else the median of the in-flow ring once it
/// has warmed, else the default — clamped to its band either way.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_expected_interval(policy: SlopDeskPacerDepth) -> f64 {
    policy.inner().expected_interval_seconds()
}

/// The late boundary, with the slack term sitting on top of the base boundary.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_late_threshold(policy: SlopDeskPacerDepth) -> f64 {
    policy.inner().late_threshold_seconds()
}

/// Folds one decoded-frame submit, in client-monotonic seconds.
///
/// It also evaluates the demote, so a post-idle resume demotes BEFORE the pacer re-primes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_note_arrival(
    policy: SlopDeskPacerDepth,
    now: f64,
) -> SlopDeskPacerDepth {
    let mut inner = policy.inner();
    inner.note_arrival(now);
    SlopDeskPacerDepth::of(&inner)
}

/// One classified present: the policy that results, and how the gap read.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPacerDepthPresent {
    /// The policy after the fold.
    pub policy: SlopDeskPacerDepth,
    /// One of the `SLOPDESK_GAP_CLASS_*` codes.
    pub gap_class: u32,
}

/// Folds one content present and classifies its gap.
///
/// The verdict is diagnostic only — a present-gap late neither counts nor promotes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_note_present(
    policy: SlopDeskPacerDepth,
    now: f64,
) -> SlopDeskPacerDepthPresent {
    let mut inner = policy.inner();
    let gap_class = gap_code(inner.note_present(now));
    SlopDeskPacerDepthPresent {
        policy: SlopDeskPacerDepth::of(&inner),
        gap_class,
    }
}

/// Folds one NETWORK-late event, which is THE promotion input and the demote dwell's content.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_note_network_late(
    policy: SlopDeskPacerDepth,
    now: f64,
) -> SlopDeskPacerDepth {
    let mut inner = policy.inner();
    inner.note_network_late(now);
    SlopDeskPacerDepth::of(&inner)
}

/// Folds one empty-queue re-show tick, which counts a late-gap EPISODE exactly once.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_note_reshow(
    policy: SlopDeskPacerDepth,
    now: f64,
) -> SlopDeskPacerDepth {
    let mut inner = policy.inner();
    inner.note_reshow(now);
    SlopDeskPacerDepth::of(&inner)
}

/// The frame-rate governor's seam.
///
/// A cadence pin rebases the late boundary instantly instead of waiting out the estimator's
/// transient. An absent, non-finite or non-positive value returns to the estimator.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_set_interval_hint(
    policy: SlopDeskPacerDepth,
    has_seconds: bool,
    seconds: f64,
) -> SlopDeskPacerDepth {
    let mut inner = policy.inner();
    inner.set_interval_hint(optional_of(has_seconds, seconds));
    SlopDeskPacerDepth::of(&inner)
}

/// One drain of the windowed counters: the policy that results, and the window that was read.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPacerDepthDrain {
    /// The policy after the drain, with both counters back at zero.
    pub policy: SlopDeskPacerDepth,
    /// Windowed: NETWORK-late events.
    pub late_frames: u32,
    /// Windowed: late-gap episodes opened.
    pub present_gaps: u32,
    /// A gauge rather than a window: the live depth.
    pub depth: u32,
}

/// Reads and resets the windowed counters — one drain per network stats report.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_drain(policy: SlopDeskPacerDepth) -> SlopDeskPacerDepthDrain {
    let mut inner = policy.inner();
    let drained = inner.drain_counters();
    SlopDeskPacerDepthDrain {
        policy: SlopDeskPacerDepth::of(&inner),
        late_frames: drained.late_frames,
        present_gaps: drained.present_gaps,
        depth: drained.depth,
    }
}

/// Whether two policies are the same state.
///
/// The rings make this the one comparison the near side cannot spell for itself: a C array is a
/// tuple over there, and a tuple that long has no equality.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pacer_depth_eq(left: SlopDeskPacerDepth, right: SlopDeskPacerDepth) -> bool {
    left == right
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::float_cmp,
    clippy::suboptimal_flops,
    reason = "calling the door is the only way to test the door; a threshold is compared against the \
              constant the law is pinned to, and that constant is spelled as two products and an add \
              because the fused form the lint wants rounds once where the law rounds twice"
)]
mod tests {
    use super::{
        SLOPDESK_GAP_CLASS_FIRST, SLOPDESK_GAP_CLASS_IDLE, SLOPDESK_GAP_CLASS_LATE,
        SLOPDESK_GAP_CLASS_NORMAL, SlopDeskPacerDepth, slopdesk_owd_late_config_apply,
        slopdesk_owd_late_config_default, slopdesk_owd_late_new, slopdesk_owd_late_note,
        slopdesk_pacer_depth_config_apply, slopdesk_pacer_depth_config_default, slopdesk_pacer_depth_drain,
        slopdesk_pacer_depth_eq, slopdesk_pacer_depth_expected_interval, slopdesk_pacer_depth_late_threshold,
        slopdesk_pacer_depth_new, slopdesk_pacer_depth_note_arrival, slopdesk_pacer_depth_note_network_late,
        slopdesk_pacer_depth_note_present, slopdesk_pacer_depth_note_reshow,
        slopdesk_pacer_depth_set_interval_hint,
    };

    /// Applies one environment pair through the door.
    fn apply_depth(
        config: super::SlopDeskPacerDepthConfig,
        key: &str,
        value: &str,
    ) -> super::SlopDeskPacerDepthConfig {
        // SAFETY: both slices outlive the call.
        unsafe {
            slopdesk_pacer_depth_config_apply(config, key.as_ptr(), key.len(), value.as_ptr(), value.len())
        }
    }

    /// A policy past the promote warm-up with a dense arrival flow behind it.
    fn primed(adapt: bool) -> (SlopDeskPacerDepth, f64) {
        let mut policy = slopdesk_pacer_depth_new(slopdesk_pacer_depth_config_default(), adapt);
        let mut now = 0.0;
        for _ in 0..200 {
            now += 1.0 / 60.0;
            policy = slopdesk_pacer_depth_note_arrival(policy, now);
            policy = slopdesk_pacer_depth_note_present(policy, now).policy;
        }
        (policy, now)
    }

    #[test]
    fn the_whole_ring_crosses_so_a_window_can_still_age_out() {
        let (policy, now) = primed(true);
        // Two lates a tenth apart promote; the same two, spread wider than the window, do not.
        let paired = slopdesk_pacer_depth_note_network_late(
            slopdesk_pacer_depth_note_network_late(policy, now),
            now + 0.1,
        );
        assert_eq!(paired.depth, 2);
        let spread = slopdesk_pacer_depth_note_network_late(
            slopdesk_pacer_depth_note_network_late(policy, now),
            now + 1.2,
        );
        assert_eq!(spread.depth, 1, "the first late aged out of the window");
    }

    #[test]
    fn the_boost_is_refunded_after_a_clean_dwell_but_never_before_the_hold() {
        let (policy, now) = primed(true);
        let mut policy = slopdesk_pacer_depth_note_network_late(policy, now);
        policy = slopdesk_pacer_depth_note_network_late(policy, now + 0.1);
        assert_eq!(policy.depth, 2);
        policy = slopdesk_pacer_depth_note_arrival(policy, now + 0.5);
        assert_eq!(policy.depth, 2, "inside the anti-flap hold");
        policy = slopdesk_pacer_depth_note_arrival(policy, now + 2.7);
        assert_eq!(policy.depth, 1);
    }

    #[test]
    fn every_gap_class_crosses_as_its_own_code() {
        let fresh = slopdesk_pacer_depth_new(slopdesk_pacer_depth_config_default(), true);
        assert_eq!(
            slopdesk_pacer_depth_note_present(fresh, 0.0).gap_class,
            SLOPDESK_GAP_CLASS_FIRST
        );
        let (policy, now) = primed(true);
        assert_eq!(
            slopdesk_pacer_depth_note_present(policy, now + 0.1).gap_class,
            SLOPDESK_GAP_CLASS_LATE
        );
        assert_eq!(
            slopdesk_pacer_depth_note_present(policy, now + 1.0).gap_class,
            SLOPDESK_GAP_CLASS_IDLE
        );
        assert_eq!(
            slopdesk_pacer_depth_note_present(policy, now + 1.0 / 60.0).gap_class,
            SLOPDESK_GAP_CLASS_NORMAL
        );
    }

    #[test]
    fn a_re_show_episode_counts_once_and_the_drain_resets_the_window() {
        let (policy, now) = primed(true);
        let mut policy = slopdesk_pacer_depth_note_reshow(policy, now + 0.05);
        policy = slopdesk_pacer_depth_note_reshow(policy, now + 0.06);
        let drained = slopdesk_pacer_depth_drain(policy);
        assert_eq!(drained.present_gaps, 1);
        assert_eq!(drained.depth, 1);
        assert_eq!(slopdesk_pacer_depth_drain(drained.policy).present_gaps, 0);
    }

    #[test]
    fn the_cadence_pin_rebases_the_boundary_and_an_absent_one_returns_to_the_estimator() {
        let (policy, _) = primed(true);
        let hinted = slopdesk_pacer_depth_set_interval_hint(policy, true, 1.0 / 30.0);
        assert_eq!(slopdesk_pacer_depth_expected_interval(hinted), 1.0 / 30.0);
        // BIT-EXACT: two distinct products and one add, which is how the law spells it.
        let expected = 1.6 * (1.0 / 30.0) + 0.25 * (1.0 / 30.0);
        assert_eq!(slopdesk_pacer_depth_late_threshold(hinted), expected);
        let unpinned = slopdesk_pacer_depth_set_interval_hint(hinted, false, 0.0);
        assert!(slopdesk_pacer_depth_expected_interval(unpinned) < 1.0 / 40.0);
    }

    #[test]
    fn the_state_compares_whole_rings_and_not_just_its_counters() {
        let (policy, now) = primed(true);
        assert!(slopdesk_pacer_depth_eq(policy, policy));
        let moved = slopdesk_pacer_depth_note_arrival(policy, now + 1.0 / 60.0);
        assert!(!slopdesk_pacer_depth_eq(policy, moved));
    }

    #[test]
    fn the_depth_environment_clamps_every_band_by_name() {
        let base = slopdesk_pacer_depth_config_default();
        assert_eq!(
            apply_depth(base, "SLOPDESK_DEPTH_PROMOTE_LATES", "99").promote_late_count,
            4,
            "the ring's capacity is the ceiling",
        );
        assert_eq!(
            apply_depth(base, "SLOPDESK_DEPTH_LATE_SLACK_PCT", "-10").late_slack_fraction,
            0.0,
        );
        assert_eq!(
            apply_depth(base, "SLOPDESK_DEPTH_IDLE_MS", "garbage").idle_gap_seconds,
            base.idle_gap_seconds,
            "garbage keeps the default",
        );
        assert_eq!(
            apply_depth(base, "SLOPDESK_NOT_A_KNOB", "5"),
            base,
            "an unknown key is not this door's business",
        );
    }

    #[test]
    fn the_detector_folds_a_spike_into_how_far_past_the_threshold_it_sat() {
        let mut detector = slopdesk_owd_late_new(slopdesk_owd_late_config_default());
        for step in 0..20_u32 {
            let note = slopdesk_owd_late_note(detector, f64::from(step) * 16.0, step * 16, 16.0);
            assert!(!note.has_deviation, "a flat path is never late");
            detector = note.detector;
        }
        let spike = slopdesk_owd_late_note(detector, 360.0, 20 * 16, 16.0);
        assert!(spike.has_deviation);
        assert_eq!(spike.deviation_ms, 15.0, "forty past a twenty-five floor");
    }

    #[test]
    fn the_detector_environment_clamps_its_own_bands_by_name() {
        let base = slopdesk_owd_late_config_default();
        let key = "SLOPDESK_OWD_LATE_WARMUP";
        let value = "0";
        // SAFETY: both slices outlive the call.
        let tuned = unsafe {
            slopdesk_owd_late_config_apply(base, key.as_ptr(), key.len(), value.as_ptr(), value.len())
        };
        assert_eq!(tuned.warmup_samples, 1, "the floor holds");
        assert_eq!(tuned.threshold_floor_ms, base.threshold_floor_ms);
    }
}
