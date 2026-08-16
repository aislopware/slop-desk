//! The frame-rate axis: two governors, the gate they actuate through, and the self-heal cadence
//! that follows them down.
//!
//! Both governors are Swift `struct`s their owners copy, so both cross BY VALUE — state in, state
//! out, nothing allocated on either side. What does NOT cross is the LADDER. It is a function of
//! the base rate and the floor, both of which travel, so carrying it would be carrying a
//! derivation, and a record that carried one could be handed back inconsistent with the numbers it
//! derived from. The caller that wants to SEE the rungs asks for them: `slopdesk_fps_ladder` fills
//! a buffer under the ordinary out-and-capacity convention, and four rungs is the whole answer.
//!
//! The cadence gate is one `f64`, and it crosses as one: a due time in, a verdict and the due time
//! that results out. A rejected admission never moves the boundary, which is what lets a gated
//! frame re-arm against the same slot.
//!
//! The congestion predicate here takes the BITRATE law's tunables, not its own. The two controllers
//! have to agree on what "congested" means or the frame rate steps down on evidence the rate
//! controller ignored, so the slack rule is read from one place through `abr`'s config.

use slopdesk_video::fps_governor::{
    EncodeCadenceGate, EncodeLoadPacer, EncodeLoadPacerConfig, EncodeLoadPacerSnapshot, FpsGovernor,
    FpsGovernorConfig, FpsGovernorSnapshot, budget_millis, congestion_evidence, ladder,
    self_heal_effective_every,
};

use crate::abr::SlopDeskAbrConfig;

// ---------------------------------------------------------------------------------------------
// The link-axis governor
// ---------------------------------------------------------------------------------------------

/// The link governor's tunables, as they cross. Every one is `SLOPDESK_FPS_GOV_*`-overridable on
/// the host side.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsConfig {
    /// The offered-load overage tolerated before the link counts as over budget.
    pub headroom_factor: f64,
    /// The weight on a fresh per-frame bytes sample.
    pub bytes_alpha: f64,
    /// The ladder's floor — below it the stream is a slideshow.
    pub min_fps: i64,
    /// Consecutive over-budget AND congested reports before a step down.
    pub step_down_ticks: u32,
    /// Reports between step downs — one rung per spacing window.
    pub step_down_hold_ticks: u32,
    /// Clean reports per step-up rung.
    pub step_up_ticks: u32,
    /// Reports to fold before any action.
    pub warmup_ticks: u32,
}

impl SlopDeskFpsConfig {
    /// The crate's config for these numbers.
    const fn inner(self) -> FpsGovernorConfig {
        FpsGovernorConfig {
            headroom_factor: self.headroom_factor,
            step_down_ticks: self.step_down_ticks,
            step_down_hold_ticks: self.step_down_hold_ticks,
            step_up_ticks: self.step_up_ticks,
            warmup_ticks: self.warmup_ticks,
            min_fps: self.min_fps,
            bytes_alpha: self.bytes_alpha,
        }
    }

    /// These numbers for the crate's config.
    const fn of(config: FpsGovernorConfig) -> Self {
        Self {
            headroom_factor: config.headroom_factor,
            bytes_alpha: config.bytes_alpha,
            min_fps: config.min_fps,
            step_down_ticks: config.step_down_ticks,
            step_down_hold_ticks: config.step_down_hold_ticks,
            step_up_ticks: config.step_up_ticks,
            warmup_ticks: config.warmup_ticks,
        }
    }
}

/// The link governor as it crosses: the tunables and every number the next report reads.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsGovernor {
    /// The tunables.
    pub config: SlopDeskFpsConfig,
    /// The per-frame bytes average — zero means UNSEEDED, and the governor never acts unseeded.
    pub bytes_per_frame_avg: f64,
    /// The base rate, which is the ladder's top rung and is never exceeded.
    pub base_fps: i64,
    /// The currently selected rate.
    pub current_fps: i64,
    /// The folded-report count — the governor's clock.
    pub ticks: u32,
    /// Consecutive over-budget AND congested reports.
    pub over_budget_run: u32,
    /// Consecutive reports that were not over budget.
    pub clean_run: u32,
    /// No step down until the clock reaches this.
    pub down_hold_until_tick: u32,
}

impl SlopDeskFpsGovernor {
    /// The crate's governor for this record, with `new`'s invariants re-established.
    fn inner(self) -> FpsGovernor {
        FpsGovernor::restored(FpsGovernorSnapshot {
            config: self.config.inner(),
            base_fps: self.base_fps,
            current_fps: self.current_fps,
            ticks: self.ticks,
            over_budget_run: self.over_budget_run,
            clean_run: self.clean_run,
            down_hold_until_tick: self.down_hold_until_tick,
            bytes_per_frame_avg: self.bytes_per_frame_avg,
        })
    }

    /// This record for the crate's governor. By reference: the governor owns a ladder, so a copy is
    /// not free — and nothing crosses here, this is one Rust frame to the next.
    const fn of(governor: &FpsGovernor) -> Self {
        let snapshot = governor.snapshot();
        Self {
            config: SlopDeskFpsConfig::of(snapshot.config),
            bytes_per_frame_avg: snapshot.bytes_per_frame_avg,
            base_fps: snapshot.base_fps,
            current_fps: snapshot.current_fps,
            ticks: snapshot.ticks,
            over_budget_run: snapshot.over_budget_run,
            clean_run: snapshot.clean_run,
            down_hold_until_tick: snapshot.down_hold_until_tick,
        }
    }
}

/// One report's outcome: the governor that results and the rate it selected.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsTick {
    /// The governor after the report — what the caller writes back.
    pub governor: SlopDeskFpsGovernor,
    /// The selected rate.
    pub fps: i64,
}

/// The production defaults for the link governor.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_config_default() -> SlopDeskFpsConfig {
    SlopDeskFpsConfig::of(FpsGovernorConfig::default())
}

/// The clean-divisor ladder for a base rate: the base and its halves, thirds and quarters, floored,
/// deduplicated, DESCENDING. Answers how many rungs there are, and fills as many as fit.
///
/// The base itself is always present, so the answer is never zero — an empty ladder would be a rate
/// the governor could not name.
///
/// # Safety
/// `out` must be null, or writable for `cap` `int64_t`s for the whole call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_fps_ladder(
    base_fps: i64,
    min_fps: i64,
    out: *mut i64,
    cap: usize,
) -> usize {
    let rungs = ladder(base_fps, min_fps);
    if !out.is_null() {
        for (index, rung) in rungs.iter().take(cap).enumerate() {
            // SAFETY: `index` is below both `cap` and the rung count, and by the caller's obligation
            // `out` is writable for `cap` elements for this call.
            unsafe { out.add(index).write(*rung) };
        }
    }
    rungs.len()
}

/// A governor anchored at a base rate, starting ungoverned at the top rung.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_governor_new(base_fps: i64, config: SlopDeskFpsConfig) -> SlopDeskFpsGovernor {
    SlopDeskFpsGovernor::of(&FpsGovernor::new(base_fps, config.inner()))
}

/// Folds one encoded frame's byte size and answers the governor that results.
///
/// An ANCHOR — a keyframe or the crisp static refresh — is EXCLUDED, because it is an episodic
/// several-fold outlier that would fake over-budget right after every recovery keyframe.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_governor_note_frame(
    governor: SlopDeskFpsGovernor,
    bytes: i64,
    is_anchor: bool,
) -> SlopDeskFpsGovernor {
    let mut inner = governor.inner();
    inner.note_encoded_frame(bytes, is_anchor);
    SlopDeskFpsGovernor::of(&inner)
}

/// One report: answers the governor that results and the rate it selected.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_governor_tick(
    governor: SlopDeskFpsGovernor,
    target_bps: i64,
    congested: bool,
) -> SlopDeskFpsTick {
    let mut inner = governor.inner();
    let fps = inner.on_tick(target_bps, congested);
    SlopDeskFpsTick {
        governor: SlopDeskFpsGovernor::of(&inner),
        fps,
    }
}

/// The congestion-evidence predicate — the step-down gate's second arm.
///
/// It takes the BITRATE law's tunables so the two controllers cannot disagree about what congested
/// means. Each of the rate controller's two readings crosses as a value plus a flag, because a
/// session with no rate controller yet has neither, and no bitrate could stand for "absent".
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_congestion_evidence(
    config: SlopDeskAbrConfig,
    last_loss_sample: f64,
    smoothed_rtt_millis: f64,
    min_rtt_millis: f64,
    has_abr_current: bool,
    abr_current: i64,
    has_abr_ceiling: bool,
    abr_ceiling: i64,
) -> bool {
    congestion_evidence(
        &config.inner(),
        last_loss_sample,
        smoothed_rtt_millis,
        min_rtt_millis,
        has_abr_current.then_some(abr_current),
        has_abr_ceiling.then_some(abr_ceiling),
    )
}

// ---------------------------------------------------------------------------------------------
// The cadence gate
// ---------------------------------------------------------------------------------------------

/// One admission decision: whether the frame is admitted, and the due time that results.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsGateVerdict {
    /// The anchored next-due boundary after the decision. A REJECTION leaves it where it was, which
    /// is what lets a gated frame re-arm against the same slot.
    pub next_due_seconds: f64,
    /// Whether the delivery is admitted.
    pub admitted: bool,
}

/// One delivered-frame admission decision against a schedule-anchored gate.
///
/// A non-positive interval is INERT and always admits — the ungoverned base-rate case never
/// consults the schedule. A zero due time is unanchored, so the first call admits and anchors.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_fps_gate_admit(
    next_due_seconds: f64,
    now_seconds: f64,
    target_interval_seconds: f64,
    tolerance_seconds: f64,
    forced: bool,
) -> SlopDeskFpsGateVerdict {
    let mut gate = EncodeCadenceGate::restored(next_due_seconds);
    let admitted = gate.admit(now_seconds, target_interval_seconds, tolerance_seconds, forced);
    SlopDeskFpsGateVerdict {
        next_due_seconds: gate.next_due(),
        admitted,
    }
}

/// The TIME-equivalent self-heal interval at a governed rate: the interval scales by the rate ratio
/// so the wall-clock heal latency stays roughly constant, floored at two.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_self_heal_every(base_every: i64, base_fps: i64, governed_fps: i64) -> i64 {
    self_heal_effective_every(base_every, base_fps, governed_fps)
}

// ---------------------------------------------------------------------------------------------
// The compute-axis pacer
// ---------------------------------------------------------------------------------------------

/// The compute pacer's tunables, as they cross.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsPacerConfig {
    /// The weight on a fresh encode-time sample.
    pub alpha: f64,
    /// Step DOWN once the encode-time average reaches this share of the current rung's budget.
    pub down_fraction: f64,
    /// Step UP once it still fits this share of the next rung's tighter budget.
    pub up_fraction: f64,
    /// Consecutive over-budget frames before a step down.
    pub down_ticks: u32,
    /// Consecutive headroom frames before a step up.
    pub up_ticks: u32,
    /// Frames to fold before any action.
    pub warmup_ticks: u32,
}

impl SlopDeskFpsPacerConfig {
    /// The crate's config for these numbers.
    const fn inner(self) -> EncodeLoadPacerConfig {
        EncodeLoadPacerConfig {
            alpha: self.alpha,
            down_fraction: self.down_fraction,
            up_fraction: self.up_fraction,
            down_ticks: self.down_ticks,
            up_ticks: self.up_ticks,
            warmup_ticks: self.warmup_ticks,
        }
    }

    /// These numbers for the crate's config.
    const fn of(config: EncodeLoadPacerConfig) -> Self {
        Self {
            alpha: config.alpha,
            down_fraction: config.down_fraction,
            up_fraction: config.up_fraction,
            down_ticks: config.down_ticks,
            up_ticks: config.up_ticks,
            warmup_ticks: config.warmup_ticks,
        }
    }
}

/// The compute pacer as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsPacer {
    /// The tunables.
    pub config: SlopDeskFpsPacerConfig,
    /// The average encode wall-time in milliseconds.
    pub encode_millis_avg: f64,
    /// The base rate.
    pub base_fps: i64,
    /// The ladder's floor. It rides along because the pacer takes it as an argument rather than
    /// from its own tunables, and the rungs cannot be rebuilt without it.
    pub min_fps: i64,
    /// The currently paced rate.
    pub current_fps: i64,
    /// The folded-frame count.
    pub ticks: u32,
    /// Consecutive over-budget frames.
    pub over_run: u32,
    /// Consecutive frames with headroom for the next rung up.
    pub clean_run: u32,
}

impl SlopDeskFpsPacer {
    /// The crate's pacer for this record, with `new`'s invariants re-established.
    fn inner(self) -> EncodeLoadPacer {
        EncodeLoadPacer::restored(EncodeLoadPacerSnapshot {
            config: self.config.inner(),
            base_fps: self.base_fps,
            min_fps: self.min_fps,
            current_fps: self.current_fps,
            encode_millis_avg: self.encode_millis_avg,
            ticks: self.ticks,
            over_run: self.over_run,
            clean_run: self.clean_run,
        })
    }

    /// This record for the crate's pacer.
    const fn of(pacer: &EncodeLoadPacer) -> Self {
        let snapshot = pacer.snapshot();
        Self {
            config: SlopDeskFpsPacerConfig::of(snapshot.config),
            encode_millis_avg: snapshot.encode_millis_avg,
            base_fps: snapshot.base_fps,
            min_fps: snapshot.min_fps,
            current_fps: snapshot.current_fps,
            ticks: snapshot.ticks,
            over_run: snapshot.over_run,
            clean_run: snapshot.clean_run,
        }
    }
}

/// One frame's outcome: the pacer that results and the rate it paced to.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskFpsPacerNote {
    /// The pacer after the frame — what the caller writes back.
    pub pacer: SlopDeskFpsPacer,
    /// The paced rate.
    pub fps: i64,
}

/// The production defaults for the compute pacer.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_pacer_config_default() -> SlopDeskFpsPacerConfig {
    SlopDeskFpsPacerConfig::of(EncodeLoadPacerConfig::default())
}

/// The per-frame wall-clock budget in milliseconds at a given rate.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_budget_millis(fps: i64) -> f64 {
    budget_millis(fps)
}

/// A pacer anchored at a base rate, starting inert at the top rung. The floor is the link
/// governor's, so both axes step down the same rungs.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_pacer_new(
    base_fps: i64,
    config: SlopDeskFpsPacerConfig,
    min_fps: i64,
) -> SlopDeskFpsPacer {
    SlopDeskFpsPacer::of(&EncodeLoadPacer::new(base_fps, config.inner(), min_fps))
}

/// Folds one encoded frame's measured wall-time and answers the pacer that results plus the paced
/// rate. An ANCHOR is excluded, exactly as the link governor excludes it from its bytes average.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_fps_pacer_note(
    pacer: SlopDeskFpsPacer,
    encode_millis: f64,
    is_anchor: bool,
) -> SlopDeskFpsPacerNote {
    let mut inner = pacer.inner();
    let fps = inner.note(encode_millis, is_anchor);
    SlopDeskFpsPacerNote {
        pacer: SlopDeskFpsPacer::of(&inner),
        fps,
    }
}

#[cfg(test)]
#[expect(
    unsafe_code,
    clippy::float_cmp,
    reason = "calling the door is the only way to test the door, and an unseeded average is exactly zero — \
              the law adopts the first sample verbatim, which is the property under test"
)]
mod tests {
    use super::{
        SlopDeskFpsGovernor, slopdesk_fps_budget_millis, slopdesk_fps_config_default,
        slopdesk_fps_congestion_evidence, slopdesk_fps_gate_admit, slopdesk_fps_governor_new,
        slopdesk_fps_governor_note_frame, slopdesk_fps_governor_tick, slopdesk_fps_ladder,
        slopdesk_fps_pacer_config_default, slopdesk_fps_pacer_new, slopdesk_fps_pacer_note,
        slopdesk_fps_self_heal_every,
    };
    use crate::abr::slopdesk_abr_config_default;

    /// A governor warmed past the cold-start guard, with a known per-frame size folded in.
    fn warmed(base_fps: i64, bytes: i64) -> SlopDeskFpsGovernor {
        let config = slopdesk_fps_config_default();
        let mut governor = slopdesk_fps_governor_new(base_fps, config);
        governor = slopdesk_fps_governor_note_frame(governor, bytes, false);
        for _ in 0..config.warmup_ticks {
            governor = slopdesk_fps_governor_tick(governor, i64::MAX, false).governor;
        }
        governor
    }

    #[test]
    fn the_ladder_is_clean_divisors_descending_and_the_count_is_the_answer() {
        let mut rungs = [0_i64; 8];
        // SAFETY: the buffer is live and holds 8 elements for the call.
        let count = unsafe { slopdesk_fps_ladder(60, 15, rungs.as_mut_ptr(), rungs.len()) };
        assert_eq!(count, 4);
        assert_eq!(rungs.get(..count), Some(&[60, 30, 20, 15][..]));

        // Asking with no buffer at all is how a caller sizes one.
        // SAFETY: a null buffer is explicitly allowed, and nothing is written.
        assert_eq!(
            unsafe { slopdesk_fps_ladder(60, 15, core::ptr::null_mut(), 0) },
            4
        );

        // A floor above every divisor leaves the base alone — the answer is never empty.
        let mut one = [0_i64; 4];
        // SAFETY: the buffer is live and holds 4 elements for the call.
        let count = unsafe { slopdesk_fps_ladder(30, 30, one.as_mut_ptr(), one.len()) };
        assert_eq!((count, one[0]), (1, 30));
    }

    #[test]
    fn nothing_moves_before_the_warmup_or_while_unseeded() {
        let config = slopdesk_fps_config_default();
        let mut governor = slopdesk_fps_governor_new(60, config);
        assert_eq!(governor.current_fps, 60, "a governor starts ungoverned");

        // Unseeded: no frame has been folded, so no budget test is possible.
        for _ in 0..(config.warmup_ticks + config.step_down_ticks + 2) {
            let tick = slopdesk_fps_governor_tick(governor, 1, true);
            governor = tick.governor;
            assert_eq!(tick.fps, 60, "an unseeded governor never acts");
        }

        // An ANCHOR is not evidence, so folding one leaves the governor unseeded.
        governor = slopdesk_fps_governor_note_frame(governor, 900_000, true);
        assert_eq!(
            governor.bytes_per_frame_avg, 0.0,
            "an anchor is an outlier, not a sample"
        );
    }

    #[test]
    fn a_congested_over_budget_stream_steps_down_one_rung_per_window() {
        let config = slopdesk_fps_config_default();
        // 20 kB a frame at 60 fps is ~9.6 Mbps offered against a 1 Mbps target.
        let mut governor = warmed(60, 20_000);
        let mut rungs = 0;
        let step = |governor: &mut SlopDeskFpsGovernor, rungs: &mut i32| {
            let tick = slopdesk_fps_governor_tick(*governor, 1_000_000, true);
            if tick.fps < governor.current_fps {
                *rungs += 1;
            }
            *governor = tick.governor;
        };
        // The streak arms the first cut, and the spacing window is what the REST of these reports
        // spend: the last report inside it is still held.
        for _ in 0..(config.step_down_ticks + config.step_down_hold_ticks - 1) {
            step(&mut governor, &mut rungs);
        }
        assert_eq!(rungs, 1, "one rung per spacing window, never a cascade");
        assert_eq!(governor.current_fps, 30);
        // The very next report is past the window, and the queue is still there, so it cuts again.
        step(&mut governor, &mut rungs);
        assert_eq!(
            (rungs, governor.current_fps),
            (2, 20),
            "and a persisting queue keeps stepping"
        );
    }

    #[test]
    fn a_heavy_stream_on_a_clean_link_never_steps_down() {
        let config = slopdesk_fps_config_default();
        let mut governor = warmed(60, 20_000);
        for _ in 0..(config.step_down_ticks * 4) {
            governor = slopdesk_fps_governor_tick(governor, 1_000_000, false).governor;
        }
        assert_eq!(governor.current_fps, 60, "content alone is not congestion");
    }

    #[test]
    fn the_congestion_predicate_reads_the_bitrate_law_s_own_constants() {
        let abr = slopdesk_abr_config_default();
        // The rate controller sitting below its ceiling IS the evidence — already debounced.
        assert!(slopdesk_fps_congestion_evidence(
            abr, 0.0, 0.0, 10.0, true, 8_000_000, true, 32_000_000
        ));
        assert!(!slopdesk_fps_congestion_evidence(
            abr, 0.0, 0.0, 10.0, true, 32_000_000, true, 32_000_000
        ));
        // Loss over the threshold is its own arm.
        assert!(slopdesk_fps_congestion_evidence(
            abr, 0.5, 0.0, 10.0, false, 0, false, 0
        ));
        // A queue: past both the factor and the slack gate on a 10 ms baseline.
        assert!(slopdesk_fps_congestion_evidence(
            abr, 0.0, 90.0, 10.0, false, 0, false, 0
        ));
        assert!(!slopdesk_fps_congestion_evidence(
            abr, 0.0, 20.0, 10.0, false, 0, false, 0
        ));
        // A baseline that is not a number reads false rather than poisoning the predicate.
        assert!(!slopdesk_fps_congestion_evidence(
            abr,
            0.0,
            90.0,
            f64::INFINITY,
            false,
            0,
            false,
            0
        ));
    }

    #[test]
    fn the_cadence_gate_is_a_metronome_and_a_rejection_never_moves_the_boundary() {
        // Inert while ungoverned.
        assert!(slopdesk_fps_gate_admit(0.0, 5.0, 0.0, 0.0, false).admitted);

        // The first call anchors, and each admitted frame advances by EXACTLY one interval.
        let first = slopdesk_fps_gate_admit(0.0, 1.0, 0.5, 0.0, false);
        assert!(first.admitted && (first.next_due_seconds - 1.5).abs() < 1e-12);
        let second = slopdesk_fps_gate_admit(first.next_due_seconds, 1.5, 0.5, 0.0, false);
        assert!(second.admitted && (second.next_due_seconds - 2.0).abs() < 1e-12);

        // Early: rejected, and the boundary is exactly where it was, so the next try re-arms
        // against the same slot.
        let early = slopdesk_fps_gate_admit(second.next_due_seconds, 1.6, 0.5, 0.0, false);
        assert!(!early.admitted);
        assert!((early.next_due_seconds - second.next_due_seconds).abs() < 1e-12);

        // A stall re-anchors from now rather than bursting to catch up.
        let stalled = slopdesk_fps_gate_admit(second.next_due_seconds, 9.0, 0.5, 0.0, false);
        assert!(stalled.admitted && (stalled.next_due_seconds - 9.5).abs() < 1e-12);
    }

    #[test]
    fn the_self_heal_cadence_holds_the_wall_clock_rather_than_the_frame_count() {
        assert_eq!(slopdesk_fps_self_heal_every(6, 60, 60), 6);
        assert_eq!(slopdesk_fps_self_heal_every(6, 60, 30), 3);
        assert_eq!(slopdesk_fps_self_heal_every(6, 60, 20), 2);
        assert_eq!(
            slopdesk_fps_self_heal_every(6, 60, 15),
            2,
            "floored, never every frame"
        );
        assert_eq!(
            slopdesk_fps_self_heal_every(0, 60, 15),
            0,
            "disabled passes straight through"
        );
    }

    #[test]
    fn the_pacer_is_inert_until_the_encoder_actually_over_runs() {
        let config = slopdesk_fps_pacer_config_default();
        let mut pacer = slopdesk_fps_pacer_new(60, config, 15);
        assert!((slopdesk_fps_budget_millis(60) - 1000.0 / 60.0).abs() < 1e-12);

        // Comfortably inside the 16.7 ms budget: nothing moves, however long it runs.
        for _ in 0..(config.warmup_ticks + config.down_ticks * 4) {
            let note = slopdesk_fps_pacer_note(pacer, 4.0, false);
            pacer = note.pacer;
            assert_eq!(note.fps, 60);
        }

        // Then a sustained over-run steps one clean divisor down.
        let mut fps = 60;
        for _ in 0..(config.down_ticks + 4) {
            let note = slopdesk_fps_pacer_note(pacer, 30.0, false);
            pacer = note.pacer;
            fps = note.fps;
        }
        assert_eq!(
            fps, 30,
            "the compute axis steps the same rungs the link axis does"
        );
    }

    #[test]
    fn a_state_that_crossed_a_boundary_lands_on_a_rung() {
        let config = slopdesk_fps_config_default();
        let mut hostile = slopdesk_fps_governor_new(60, config);
        hostile.current_fps = 47; // between two rungs — no ladder names it
        hostile.bytes_per_frame_avg = f64::NAN;
        let landed = slopdesk_fps_governor_tick(hostile, 1_000_000, true).governor;
        assert_eq!(
            landed.current_fps, 30,
            "the rate lands on the rung at or below what it claimed"
        );
        assert_eq!(
            landed.bytes_per_frame_avg, 0.0,
            "and an average that is not a number is unseeded"
        );
    }
}
