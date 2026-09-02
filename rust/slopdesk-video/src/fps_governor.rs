//! Frame rate as a control axis, on two independent bottlenecks.
//!
//! Under a genuinely bandwidth-starved link the encoder can only coarsen the quantiser so far: past
//! its entropy floor a dense scroll's offered load exceeds whatever rate the bitrate controller
//! actuated, and the queue-and-loss spiral starts. The answer is to drop the FRAME RATE, so each
//! remaining frame gets a bigger byte budget — sharper — while the aggregate fits the actuated
//! target.
//!
//! An alternating skip keyed on the previous frame's size is deliberately NOT how it is actuated:
//! it delivers frames at irregular alternating intervals, which is a primary cadence-stutter
//! source. Instead a rate is picked from a CLEAN-DIVISOR ladder of the base and actuated through
//! the schedule-anchored [`EncodeCadenceGate`], so a governed half-rate is a metronome-regular
//! every-second-delivery cadence.
//!
//! Two controllers share that ladder and that gate, because there are two distinct bottlenecks:
//!
//! * [`FpsGovernor`] — the LINK axis, ticking once per folded network report on the same clock as
//!   the bitrate controller, and stepping down only on network congestion.
//! * [`EncodeLoadPacer`] — the COMPUTE axis, ticking once per encoded frame. On a clean, fast link
//!   the bottleneck is the hardware encoder rather than the path: a fat scroll delta that over-runs
//!   the inter-arrival budget backs up the encode queue, and the capture hand-off then drops deltas
//!   RAGGEDLY, whenever the backlog is momentarily full. Ragged drops are an irregular present
//!   cadence — the same stutter — even though the AVERAGE encode is well under budget. The governor
//!   never sees this, because the link is clean.
//!
//! They compose at the hand-off as the MINIMUM of the two, so the axes never fight.
//!
//! Pure and deterministic throughout: no wall clock and no I/O. "Time" is a count of folded reports
//! or folded frames.

use crate::congestion::{CongestionConfig, effective_slack_millis};

/// The tunables shared by both frame-rate controllers.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FpsGovernorConfig {
    /// The offered-load overage tolerated before the link counts as over budget.
    ///
    /// The bitrate controller's own cuts absorb a modest overage by trimming rate; the frame rate
    /// only engages when the encoder CANNOT coarsen under budget — its entropy floor — which is
    /// exactly when offered exceeds the actuated rate by more than this.
    pub headroom_factor: f64,
    /// Consecutive over-budget AND congested reports before a step down — the same sustained-
    /// evidence bar as the bitrate controller's round-trip path, because one report holds only a
    /// few frames and is quantisation noise.
    pub step_down_ticks: u32,
    /// Reports between step downs — one rung per spacing window, mirroring the bitrate controller's
    /// cut-cascade fix, and long enough for the bytes average to re-converge on the new rung's
    /// frame sizes before the next decision.
    pub step_down_hold_ticks: u32,
    /// Clean reports per step-up rung. A step is a VISIBLE cadence change, so it is rare.
    pub step_up_ticks: u32,
    /// Reports to fold before any action — the cold-start guard.
    pub warmup_ticks: u32,
    /// The ladder's floor. Below it the stream is a slideshow; quantiser coarsening and the bitrate
    /// floor cover the remainder.
    pub min_fps: i64,
    /// The weight on a fresh per-frame bytes sample.
    pub bytes_alpha: f64,
}

impl Default for FpsGovernorConfig {
    fn default() -> Self {
        Self {
            headroom_factor: 1.2,
            step_down_ticks: 3,
            step_down_hold_ticks: 8,
            step_up_ticks: 60,
            warmup_ticks: 10,
            min_fps: 15,
            bytes_alpha: 0.125,
        }
    }
}

/// The environment keys, in the order [`FpsGovernorConfig::from_env`] reads their values.
///
/// The caller resolves these names — environment, then the settings overlay (`docs/58`) — and hands
/// the texts back positionally, the same split [`crate::host_gates::KEYS`] documents at length: a
/// lookup is a precedence rule and belongs to whoever owns the overlay, a default is a tuning rule
/// and belongs here.
///
/// `bytes_alpha` has no key and never had one. It is the EWMA weight the loss estimator uses, held
/// to the same value on purpose, so it stays a constant in [`FpsGovernorConfig::default`].
pub const KEYS: [&str; 6] = [
    "SLOPDESK_FPS_GOV_HEADROOM",
    "SLOPDESK_FPS_GOV_DOWN_N",
    "SLOPDESK_FPS_GOV_DOWN_HOLD",
    "SLOPDESK_FPS_GOV_UP_N",
    "SLOPDESK_FPS_GOV_WARMUP",
    "SLOPDESK_FPS_GOV_MIN",
];

impl FpsGovernorConfig {
    /// The operating point resolved from the texts of [`KEYS`], in that order.
    ///
    /// Every knob REJECTS an out-of-band value back to its tuned default rather than clamping it —
    /// the bitrate controller's rule ([`crate::congestion::validated_int_from_env`]), and the right
    /// one here for the same reason: `SLOPDESK_FPS_GOV_DOWN_N=0` is not a request for "step down on
    /// the very first congested report", it is a typo, and answering the nearest legal value would
    /// invent a cadence law nobody chose. That is the opposite of the quantiser family
    /// ([`crate::qp_control::QpConfig::from_env`]), which CLAMPS — a QP is an ordinal on a fixed
    /// 1…51 scale, so its nearest legal value means something.
    #[must_use]
    pub fn from_env(values: &[Option<&str>; KEYS.len()]) -> Self {
        let defaults = Self::default();
        // BY NAME, for the reason `host_gates` and the bitrate table give: a positional read
        // agrees with a table that has drifted, and a knob read into the wrong slot is an inversion
        // nothing catches.
        let at = |key: &str| -> Option<&str> {
            KEYS.iter()
                .position(|name| *name == key)
                .and_then(|index| values.get(index).copied().flatten())
        };
        let int = |key: &str, default: u32, lo: u32, hi: u32| {
            u32::try_from(crate::congestion::validated_int_from_env(
                at(key),
                i64::from(default),
                i64::from(lo),
                i64::from(hi),
            ))
            .unwrap_or(default)
        };
        Self {
            headroom_factor: crate::congestion::validated_double_from_env(
                at("SLOPDESK_FPS_GOV_HEADROOM"),
                defaults.headroom_factor,
                1.0,
                3.0,
            ),
            step_down_ticks: int("SLOPDESK_FPS_GOV_DOWN_N", defaults.step_down_ticks, 1, 1_000),
            step_down_hold_ticks: int(
                "SLOPDESK_FPS_GOV_DOWN_HOLD",
                defaults.step_down_hold_ticks,
                0,
                100_000,
            ),
            step_up_ticks: int("SLOPDESK_FPS_GOV_UP_N", defaults.step_up_ticks, 1, 100_000),
            warmup_ticks: int("SLOPDESK_FPS_GOV_WARMUP", defaults.warmup_ticks, 0, 100_000),
            min_fps: crate::congestion::validated_int_from_env(
                at("SLOPDESK_FPS_GOV_MIN"),
                defaults.min_fps,
                5,
                240,
            ),
            bytes_alpha: defaults.bytes_alpha,
        }
    }
}

/// The clean-divisor ladder: the base and its halves, thirds and quarters, floored, deduplicated,
/// DESCENDING.
///
/// Clean divisors are the whole point. On the delivery grid the governed intervals are then exact
/// multiples of a slot, which is what makes the [`EncodeCadenceGate`]'s cadence metronome-regular
/// rather than a beat pattern. Integer division, and rungs under the floor are dropped — but the
/// base itself is always present, so the ladder is never empty.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "a clean whole-number divisor of the base rate IS the ladder's definition"
)]
pub fn ladder(base_fps: i64, min_fps: i64) -> Vec<i64> {
    let base = base_fps.max(1);
    let mut rungs = vec![base];
    for divisor in 2..=4 {
        let rung = base / divisor;
        if rung >= min_fps && !rungs.contains(&rung) {
            rungs.push(rung);
        }
    }
    rungs.sort_unstable_by(|left, right| right.cmp(left));
    rungs
}

/// Every number a [`FpsGovernor`] holds — what an owner across a boundary carries between reports.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FpsGovernorSnapshot {
    /// The tunables.
    pub config: FpsGovernorConfig,
    /// The base rate the ladder is built from.
    pub base_fps: i64,
    /// The currently selected rate.
    pub current_fps: i64,
    /// The folded-report count.
    pub ticks: u32,
    /// Consecutive over-budget AND congested reports.
    pub over_budget_run: u32,
    /// Consecutive reports that were not over budget.
    pub clean_run: u32,
    /// No step down until the clock reaches this.
    pub down_hold_until_tick: u32,
    /// The per-frame bytes average, zero while unseeded.
    pub bytes_per_frame_avg: f64,
}

/// The LINK-axis governor.
#[derive(Debug, Clone, PartialEq)]
pub struct FpsGovernor {
    /// The tunables.
    config: FpsGovernorConfig,
    /// The session's configured capture and encode rate — the ladder's top rung, never exceeded.
    base_fps: i64,
    /// The rungs, descending.
    ladder: Vec<i64>,
    /// The currently selected rate.
    current_fps: i64,
    /// The folded-report count — the governor's clock.
    ticks: u32,
    /// Consecutive over-budget AND congested reports.
    over_budget_run: u32,
    /// Consecutive reports that were not over budget.
    clean_run: u32,
    /// No step down is permitted until the clock reaches this.
    down_hold_until_tick: u32,
    /// The average of NON-ANCHOR encoded frame bytes. Zero means unseeded, and the governor never
    /// acts unseeded.
    bytes_per_frame_avg: f64,
}

impl FpsGovernor {
    /// A governor anchored at a base rate, starting ungoverned at the top rung.
    #[must_use]
    pub fn new(base_fps: i64, config: FpsGovernorConfig) -> Self {
        let base = base_fps.max(1);
        let ladder = ladder(base, config.min_fps);
        let current_fps = ladder.first().copied().unwrap_or(base);
        Self {
            config,
            base_fps: base,
            ladder,
            current_fps,
            ticks: 0,
            over_budget_run: 0,
            clean_run: 0,
            down_hold_until_tick: 0,
            bytes_per_frame_avg: 0.0,
        }
    }

    /// The base rate.
    #[must_use]
    pub const fn base_fps(&self) -> i64 {
        self.base_fps
    }

    /// The rungs, descending.
    #[must_use]
    pub fn ladder(&self) -> &[i64] {
        &self.ladder
    }

    /// The currently selected rate.
    #[must_use]
    pub const fn current_fps(&self) -> i64 {
        self.current_fps
    }

    /// The per-frame bytes average, or zero while unseeded.
    #[must_use]
    pub const fn bytes_per_frame_avg(&self) -> f64 {
        self.bytes_per_frame_avg
    }

    /// Every number this governor holds, flat. The ladder is NOT among them — it is a function of
    /// the base rate and the floor, so carrying it would be carrying a derivation.
    #[must_use]
    pub const fn snapshot(&self) -> FpsGovernorSnapshot {
        FpsGovernorSnapshot {
            config: self.config,
            base_fps: self.base_fps,
            current_fps: self.current_fps,
            ticks: self.ticks,
            over_budget_run: self.over_budget_run,
            clean_run: self.clean_run,
            down_hold_until_tick: self.down_hold_until_tick,
            bytes_per_frame_avg: self.bytes_per_frame_avg,
        }
    }

    /// A governor rebuilt from a snapshot, with `new`'s invariants re-established.
    ///
    /// The rate lands ON a rung, because every path here reads it against the ladder and a value
    /// between two rungs would step to a rate no ladder names. An average that is not a finite
    /// positive number reads as UNSEEDED, which is the state the governor refuses to act in — the
    /// safe answer, and the one `new` starts from.
    #[must_use]
    pub fn restored(snapshot: FpsGovernorSnapshot) -> Self {
        let mut restored = Self::new(snapshot.base_fps, snapshot.config);
        restored.current_fps = restored
            .ladder
            .iter()
            .copied()
            .find(|rung| *rung <= snapshot.current_fps)
            .or_else(|| restored.ladder.last().copied())
            .unwrap_or(restored.base_fps);
        restored.ticks = snapshot.ticks;
        restored.over_budget_run = snapshot.over_budget_run;
        restored.clean_run = snapshot.clean_run;
        restored.down_hold_until_tick = snapshot.down_hold_until_tick;
        restored.bytes_per_frame_avg = if snapshot.bytes_per_frame_avg.is_finite() {
            snapshot.bytes_per_frame_avg.max(0.0)
        } else {
            0.0
        };
        restored
    }

    /// Folds one encoded frame's byte size — the motion and entropy proxy.
    ///
    /// ANCHOR frames, meaning keyframes and the crisp static refresh, are EXCLUDED: an anchor is an
    /// episodic several-fold outlier, so folding it would fake over-budget right after every
    /// recovery keyframe and step the rate down exactly while recovering. A long-term-reference
    /// refresh, about half again a delta, IS folded — that is steady-state stream cost, so the
    /// budget test self-accounts for the self-heal cadence.
    pub fn note_encoded_frame(&mut self, bytes: i64, is_anchor: bool) {
        if is_anchor || bytes <= 0 {
            return;
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "an encoded frame size is far inside f64's exact integer range"
        )]
        let sample = bytes as f64;
        // Separate multiplies and one add, never fused.
        self.bytes_per_frame_avg = if self.bytes_per_frame_avg == 0.0 {
            sample // the first non-anchor seeds exactly
        } else {
            let history = self.bytes_per_frame_avg * (1.0 - self.config.bytes_alpha);
            let fresh = sample * self.config.bytes_alpha;
            history + fresh
        };
    }

    /// One tick per folded network report, returning the selected rate.
    ///
    /// `target_bps` is the host's last actuated bitrate, which is the resolution-aware ceiling
    /// while the bitrate controller is idle. `congested` is POSITIVE congestion evidence for
    /// THIS report — see [`congestion_evidence`]. Content-heavy on a CLEAN link NEVER steps
    /// down: a frame-rate reduction costs input-to-photon latency, and a link that is carrying
    /// the bytes does not need the sacrifice.
    pub fn on_tick(&mut self, target_bps: i64, congested: bool) -> i64 {
        self.ticks = self.ticks.saturating_add(1);
        if self.ticks < self.config.warmup_ticks || self.bytes_per_frame_avg <= 0.0 || target_bps <= 0 {
            return self.current_fps;
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame rate and a bitrate are far inside f64's exact integer range"
        )]
        // Separate multiplies, never fused into a product-and-add by a later refactor.
        let offered_bps = self.bytes_per_frame_avg * 8.0 * (self.current_fps as f64);
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame rate and a bitrate are far inside f64's exact integer range"
        )]
        let budget = (target_bps as f64) * self.config.headroom_factor;
        let over_budget = offered_bps > budget;
        if over_budget && congested {
            self.clean_run = 0;
            self.over_budget_run = self.over_budget_run.saturating_add(1);
            if self.over_budget_run >= self.config.step_down_ticks
                && self.ticks >= self.down_hold_until_tick
                && let Some(next) = self.next_rung_down()
            {
                self.current_fps = next; // ONE rung down
                self.over_budget_run = 0;
                self.down_hold_until_tick = self.ticks + self.config.step_down_hold_ticks;
            }
        } else if over_budget {
            // Content-heavy but the link is holding: never step down on content alone.
            self.over_budget_run = 0;
            self.clean_run = 0;
        } else {
            self.over_budget_run = 0;
            self.clean_run = self.clean_run.saturating_add(1);
            self.try_step_up(target_bps);
        }
        self.current_fps
    }

    /// The next rung strictly below the current rate, if the ladder has one.
    fn next_rung_down(&self) -> Option<i64> {
        self.ladder.iter().copied().find(|rung| *rung < self.current_fps)
    }

    /// The next rung strictly above the current rate — the ladder is descending, so this reads it
    /// backwards to find the SMALLEST such rung.
    fn next_rung_up(&self) -> Option<i64> {
        self.ladder
            .iter()
            .rev()
            .copied()
            .find(|rung| *rung > self.current_fps)
    }

    /// One rung up on a sustained clean run, gated by a STRICT projected fit with NO headroom.
    ///
    /// The projection is conservative by construction: a per-frame bytes average measured at a
    /// LOWER rate over-estimates per-frame bytes at a higher one, because the temporal deltas
    /// there are smaller. So the fit test is biased safe.
    fn try_step_up(&mut self, target_bps: i64) {
        if self.current_fps >= self.base_fps || self.clean_run < self.config.step_up_ticks {
            return;
        }
        let Some(next) = self.next_rung_up() else {
            return;
        };
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame rate and a bitrate are far inside f64's exact integer range"
        )]
        let projected = self.bytes_per_frame_avg * 8.0 * (next as f64);
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame rate and a bitrate are far inside f64's exact integer range"
        )]
        let budget = target_bps as f64;
        if projected <= budget {
            self.current_fps = next;
            self.clean_run = 0;
        }
    }
}

/// The congestion-evidence predicate — the step-down gate's second arm.
///
/// It deliberately reuses the bitrate controller's OWN constants, through the same
/// [`effective_slack_millis`] rule, so the two controllers cannot disagree about what congested
/// means. The below-ceiling arm is included because that controller only ever cuts on positive
/// evidence, which makes "it has cut" a clean, already-debounced proxy that automatically composes
/// with any future cut mechanism: anything that lowers its target feeds this arm.
///
/// The comparisons are ordered rather than negated, so a non-finite baseline reads false through
/// the finiteness gate instead of poisoning the predicate.
#[must_use]
pub fn congestion_evidence(
    config: &CongestionConfig,
    last_loss_sample: f64,
    smoothed_rtt_millis: f64,
    min_rtt_millis: f64,
    abr_current: Option<i64>,
    abr_ceiling: Option<i64>,
) -> bool {
    if let (Some(current), Some(ceiling)) = (abr_current, abr_ceiling)
        && current < ceiling
    {
        return true;
    }
    if last_loss_sample > config.loss_threshold {
        return true;
    }
    let slack = effective_slack_millis(config, min_rtt_millis);
    min_rtt_millis.is_finite()
        && smoothed_rtt_millis > min_rtt_millis * config.rtt_inflate_factor
        && smoothed_rtt_millis > min_rtt_millis + slack
}

/// The schedule-anchored encode-cadence gate — the governors' actuator at the capture-to-encode
/// hand-off, and NOT an alternating skip.
///
/// The capture delivery rate stays untouched; this gate admits deliveries on a drift-free schedule
/// at the governed interval. An admitted frame advances the due time by EXACTLY one interval, a
/// metronome. A content stall re-anchors from now, so there is no burst catch-up. A forced frame —
/// a pending recovery latch, or the first frame — admits AND re-anchors, so the cadence stays
/// regular around forced frames; recovery latency is unchanged, because deliveries continue at full
/// rate and the next callback sees the latch.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct EncodeCadenceGate {
    /// The anchored next-due boundary, or zero while unanchored.
    next_due_seconds: f64,
}

impl EncodeCadenceGate {
    /// An unanchored gate.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            next_due_seconds: 0.0,
        }
    }

    /// A gate holding a due time it was given.
    ///
    /// A boundary that is not a finite number reads as UNANCHORED, which is the state the gate
    /// starts in and the one it recovers through: the next delivery admits and re-anchors, rather
    /// than being compared against a boundary no arithmetic can move.
    #[must_use]
    pub const fn restored(next_due_seconds: f64) -> Self {
        Self {
            next_due_seconds: if next_due_seconds.is_finite() {
                next_due_seconds
            } else {
                0.0
            },
        }
    }

    /// The anchored next-due boundary, zero meaning nothing has been admitted yet or the gate is
    /// inert.
    ///
    /// This is the gated-tail flush seam. On a REJECTED admission it is the slot boundary at which
    /// the rejected content becomes admissible, which a one-shot tail flush schedules against so
    /// the gated LAST frame of a motion burst ships at the next governed slot instead of
    /// waiting for the far-off static crisp refresh. Rejections never move it, so repeated
    /// gated deliveries re-arm against the SAME boundary.
    #[must_use]
    pub const fn next_due(&self) -> f64 {
        self.next_due_seconds
    }

    /// One delivered-frame admission decision.
    ///
    /// A non-positive interval is INERT and always admits — the ungoverned base-rate case never
    /// consults the schedule. The first call admits and anchors. The tolerance soaks capture-slot
    /// scheduling jitter without slipping a slot; call sites pass half a delivery slot.
    pub const fn admit(
        &mut self,
        now: f64,
        target_interval_seconds: f64,
        tolerance_seconds: f64,
        forced: bool,
    ) -> bool {
        if target_interval_seconds <= 0.0 {
            return true; // inert, the ungoverned base-rate case
        }
        if forced || self.next_due_seconds == 0.0 {
            self.next_due_seconds = now + target_interval_seconds;
            return true;
        }
        if now + tolerance_seconds < self.next_due_seconds {
            return false;
        }
        if now - self.next_due_seconds > target_interval_seconds {
            self.next_due_seconds = now + target_interval_seconds; // a stall re-anchors
        } else {
            self.next_due_seconds += target_interval_seconds; // drift-free advance
        }
        true
    }
}

/// The TIME-equivalent self-heal cadence at a governed rate.
///
/// The self-heal interval was tuned at the full rate for a target wall-clock heal latency. Counting
/// the same number of ENCODED frames at a governed quarter rate would stretch that fourfold, which
/// is not acceptable: the rate is only governed down DURING congestion, precisely when whole-frame
/// loss is most likely and recovery round trips are most expensive. So the wall-clock latency is
/// held roughly constant instead — the interval scales by the rate ratio, floored at two, because a
/// refresh-every-frame stream would be all refresh.
///
/// The cost is more refresh frames, each about half again a delta. But a governed-down stream
/// already fits the actuated budget with headroom, and refreshes ARE folded into the governor's
/// bytes average, so the budget test self-accounts for them.
#[must_use]
pub fn self_heal_effective_every(base_every: i64, base_fps: i64, governed_fps: i64) -> i64 {
    if base_every <= 0 {
        return 0; // disabled, passed straight through
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "a frame interval and a frame rate are far inside f64's exact integer range"
    )]
    // Separate multiply and divide; the rounding is half-away-from-zero on both sides of the port.
    let scaled = ((base_every as f64) * (governed_fps as f64) / (base_fps.max(1) as f64)).round();
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the scaled interval is bounded by the base interval it scaled"
    )]
    let scaled = scaled as i64;
    scaled.max(2)
}

/// The tunables for the COMPUTE-axis pacer.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncodeLoadPacerConfig {
    /// The weight on a fresh encode-time sample — a short memory, because encode spikes are bursty.
    pub alpha: f64,
    /// Step DOWN a rung once the encode-time average reaches this fraction of the CURRENT rung's
    /// budget. ONE: the backlog builds only when an encode takes longer than the interval it has,
    /// and a threshold under the interval steps a stream that was keeping up. The 2026-09-02
    /// cadence runs (`docs/71`) measured an 11–13 ms submit wall at 1280×800 — 72% of the 60 fps
    /// budget, zero backlog drops — and the earlier 0.85 tripped on its spikes, halving the rate.
    pub down_fraction: f64,
    /// Step UP a rung once the encode-time average — measured at the current, COARSER rung, so on
    /// LARGER frames — still fits this fraction of the next rung's tighter budget. Since the higher
    /// rung's frames are smaller, fitting the bigger ones under its budget is a conservative,
    /// biased-safe projection, mirroring the link governor's step-up fit.
    pub up_fraction: f64,
    /// Consecutive over-budget encoded frames before a step down — half a second at 60 fps. A
    /// step halves the rate for seconds, so it answers a SUSTAINED overrun; a burst that clears in
    /// a few frames costs a few ragged drops, which is the cheaper of the two.
    pub down_ticks: u32,
    /// Consecutive headroom frames before a step up — slow, because a step is a visible cadence
    /// change, and long enough that a rate that steps up is not about to step down again.
    pub up_ticks: u32,
    /// Frames to fold before any action — the cold-start guard.
    pub warmup_ticks: u32,
}

impl Default for EncodeLoadPacerConfig {
    fn default() -> Self {
        Self {
            alpha: 0.25,
            down_fraction: 1.0,
            up_fraction: 0.90,
            down_ticks: 30,
            up_ticks: 120,
            warmup_ticks: 8,
        }
    }
}

/// The per-frame wall-clock budget in milliseconds at a given rate.
#[must_use]
pub fn budget_millis(fps: i64) -> f64 {
    #[expect(
        clippy::cast_precision_loss,
        reason = "a frame rate is far inside f64's exact integer range"
    )]
    let rate = fps.max(1) as f64;
    1000.0 / rate
}

/// Every number an [`EncodeLoadPacer`] holds. The floor rides along because the pacer takes it as
/// an argument rather than from its own config, and the ladder cannot be rebuilt without it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EncodeLoadPacerSnapshot {
    /// The tunables.
    pub config: EncodeLoadPacerConfig,
    /// The base rate the ladder is built from.
    pub base_fps: i64,
    /// The ladder's floor.
    pub min_fps: i64,
    /// The currently paced rate.
    pub current_fps: i64,
    /// The average encode wall-time in milliseconds.
    pub encode_millis_avg: f64,
    /// The folded-frame count.
    pub ticks: u32,
    /// Consecutive over-budget frames.
    pub over_run: u32,
    /// Consecutive frames with headroom for the next rung up.
    pub clean_run: u32,
}

/// The COMPUTE-axis pacer.
///
/// INERT — it returns the base rate — until it has sustained evidence of over-run, so a stream the
/// encoder keeps up with is never touched.
#[derive(Debug, Clone, PartialEq)]
pub struct EncodeLoadPacer {
    /// The ladder's floor, kept so a snapshot can rebuild the same rungs.
    min_fps: i64,
    /// The tunables.
    config: EncodeLoadPacerConfig,
    /// The base rate.
    base_fps: i64,
    /// The rungs, descending — the same ladder the link governor uses, so both share one
    /// metronome-regular divisor set.
    ladder: Vec<i64>,
    /// The currently paced rate.
    current_fps: i64,
    /// The average encode wall-time in milliseconds.
    encode_millis_avg: f64,
    /// The folded-frame count.
    ticks: u32,
    /// Consecutive over-budget frames.
    over_run: u32,
    /// Consecutive frames with headroom for the next rung up.
    clean_run: u32,
}

impl EncodeLoadPacer {
    /// A pacer anchored at a base rate, starting inert at the top rung.
    #[must_use]
    pub fn new(base_fps: i64, config: EncodeLoadPacerConfig, min_fps: i64) -> Self {
        let base = base_fps.max(1);
        let ladder = ladder(base, min_fps);
        let current_fps = ladder.first().copied().unwrap_or(base);
        Self {
            min_fps,
            config,
            base_fps: base,
            ladder,
            current_fps,
            encode_millis_avg: 0.0,
            ticks: 0,
            over_run: 0,
            clean_run: 0,
        }
    }

    /// The currently paced rate.
    #[must_use]
    pub const fn current_fps(&self) -> i64 {
        self.current_fps
    }

    /// The average encode wall-time in milliseconds.
    #[must_use]
    pub const fn encode_millis_avg(&self) -> f64 {
        self.encode_millis_avg
    }

    /// Every number this pacer holds, flat.
    #[must_use]
    pub const fn snapshot(&self) -> EncodeLoadPacerSnapshot {
        EncodeLoadPacerSnapshot {
            config: self.config,
            base_fps: self.base_fps,
            min_fps: self.min_fps,
            current_fps: self.current_fps,
            encode_millis_avg: self.encode_millis_avg,
            ticks: self.ticks,
            over_run: self.over_run,
            clean_run: self.clean_run,
        }
    }

    /// A pacer rebuilt from a snapshot, with `new`'s invariants re-established — the rate lands ON
    /// a rung, and an average that is not a finite positive number reads as unseeded.
    #[must_use]
    pub fn restored(snapshot: EncodeLoadPacerSnapshot) -> Self {
        let mut restored = Self::new(snapshot.base_fps, snapshot.config, snapshot.min_fps);
        restored.current_fps = restored
            .ladder
            .iter()
            .copied()
            .find(|rung| *rung <= snapshot.current_fps)
            .or_else(|| restored.ladder.last().copied())
            .unwrap_or(restored.base_fps);
        restored.encode_millis_avg = if snapshot.encode_millis_avg.is_finite() {
            snapshot.encode_millis_avg.max(0.0)
        } else {
            0.0
        };
        restored.ticks = snapshot.ticks;
        restored.over_run = snapshot.over_run;
        restored.clean_run = snapshot.clean_run;
        restored
    }

    /// Folds one encoded frame's measured wall-time and returns the paced rate.
    ///
    /// ANCHOR frames are episodic several-fold encode-time outliers and are excluded, exactly as
    /// the link governor excludes them from its bytes average, so a recovery keyframe never
    /// fakes a step down.
    pub fn note(&mut self, encode_millis: f64, is_anchor: bool) -> i64 {
        if is_anchor || encode_millis < 0.0 {
            return self.current_fps;
        }
        self.ticks = self.ticks.saturating_add(1);
        // Separate multiplies and one add, never fused.
        self.encode_millis_avg = if self.encode_millis_avg == 0.0 {
            encode_millis // the first sample seeds exactly
        } else {
            let history = self.encode_millis_avg * (1.0 - self.config.alpha);
            let fresh = encode_millis * self.config.alpha;
            history + fresh
        };
        if self.ticks < self.config.warmup_ticks {
            return self.current_fps;
        }
        if self.encode_millis_avg > budget_millis(self.current_fps) * self.config.down_fraction {
            self.clean_run = 0;
            self.over_run = self.over_run.saturating_add(1);
            if self.over_run >= self.config.down_ticks
                && let Some(next) = self.ladder.iter().copied().find(|rung| *rung < self.current_fps)
            {
                self.current_fps = next; // ONE rung down
                self.over_run = 0;
            }
        } else {
            self.over_run = 0;
            self.step_up_on_headroom();
        }
        self.current_fps
    }

    /// One rung up once the headroom for the tighter higher-rung budget has been SUSTAINED. Any
    /// frame without that headroom resets the run.
    fn step_up_on_headroom(&mut self) {
        let up = self
            .ladder
            .iter()
            .rev()
            .copied()
            .find(|rung| *rung > self.current_fps);
        let Some(up) = up.filter(|_| self.current_fps < self.base_fps) else {
            self.clean_run = 0;
            return;
        };
        if self.encode_millis_avg >= budget_millis(up) * self.config.up_fraction {
            self.clean_run = 0;
            return;
        }
        self.clean_run = self.clean_run.saturating_add(1);
        if self.clean_run >= self.config.up_ticks {
            self.current_fps = up;
            self.clean_run = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the seeding assertions are on samples the law adopts verbatim, which is the property \
                  under test"
    )]

    use super::{
        EncodeCadenceGate, EncodeLoadPacer, EncodeLoadPacerConfig, FpsGovernor, FpsGovernorConfig, KEYS,
        budget_millis, congestion_evidence, ladder, self_heal_effective_every,
    };
    use crate::congestion::CongestionConfig;

    /// The values array, keyed by NAME rather than by index. A positional fixture would agree with
    /// a [`KEYS`] table that had drifted, which is the one failure the table exists to prevent.
    fn env(pairs: &[(&str, &'static str)]) -> [Option<&'static str>; KEYS.len()] {
        for (key, _) in pairs {
            assert!(KEYS.contains(key), "{key} is not a cadence gate");
        }
        KEYS.map(|name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| *value)
        })
    }

    #[test]
    fn the_unset_cadence_operating_point_is_the_tuned_one() {
        assert_eq!(
            FpsGovernorConfig::from_env(&env(&[])),
            FpsGovernorConfig::default()
        );
    }

    #[test]
    fn every_cadence_knob_is_reachable_under_its_own_name() {
        let config = FpsGovernorConfig::from_env(&env(&[
            ("SLOPDESK_FPS_GOV_HEADROOM", "1.5"),
            ("SLOPDESK_FPS_GOV_DOWN_N", "7"),
            ("SLOPDESK_FPS_GOV_DOWN_HOLD", "0"),
            ("SLOPDESK_FPS_GOV_UP_N", "90"),
            ("SLOPDESK_FPS_GOV_WARMUP", "0"),
            ("SLOPDESK_FPS_GOV_MIN", "24"),
        ]));
        assert_eq!(config.headroom_factor, 1.5);
        assert_eq!(config.step_down_ticks, 7);
        assert_eq!(config.step_down_hold_ticks, 0);
        assert_eq!(config.step_up_ticks, 90);
        assert_eq!(config.warmup_ticks, 0);
        assert_eq!(config.min_fps, 24);
    }

    #[test]
    fn an_out_of_band_cadence_knob_falls_to_its_default_rather_than_clamping() {
        let defaults = FpsGovernorConfig::default();
        let config = FpsGovernorConfig::from_env(&env(&[
            ("SLOPDESK_FPS_GOV_MIN", "1"),
            ("SLOPDESK_FPS_GOV_DOWN_N", "0"),
            ("SLOPDESK_FPS_GOV_HEADROOM", "9"),
        ]));
        assert_eq!(
            config.min_fps, defaults.min_fps,
            "a floor below the band is a typo, not a request for 5 fps"
        );
        assert_eq!(config.step_down_ticks, defaults.step_down_ticks);
        assert_eq!(config.headroom_factor, defaults.headroom_factor);
    }

    #[test]
    fn the_bytes_weight_has_no_key_and_never_moves() {
        let config = FpsGovernorConfig::from_env(&env(&[("SLOPDESK_FPS_GOV_MIN", "30")]));
        assert_eq!(config.bytes_alpha, FpsGovernorConfig::default().bytes_alpha);
        assert!(
            !KEYS.iter().any(|key| key.contains("ALPHA")),
            "the EWMA weight is held to the loss estimator's, so it is not a knob"
        );
    }

    /// A governor warmed past the cold-start guard with a known per-frame size.
    fn warmed(base_fps: i64, bytes: i64) -> FpsGovernor {
        let mut governor = FpsGovernor::new(base_fps, FpsGovernorConfig::default());
        governor.note_encoded_frame(bytes, false);
        for _ in 0..FpsGovernorConfig::default().warmup_ticks {
            governor.on_tick(i64::MAX, false);
        }
        governor
    }

    #[test]
    fn the_ladder_is_clean_divisors_descending_and_never_empty() {
        assert_eq!(ladder(60, 15), [60, 30, 20, 15]);
        assert_eq!(ladder(30, 15), [30, 15], "a rung under the floor is dropped");
        assert_eq!(ladder(10, 15), [10], "the base itself always survives the floor");
        assert_eq!(ladder(0, 15), [1], "a degenerate base still yields a rung");
    }

    /// A recovery keyframe must not fake over-budget right when the stream is recovering.
    #[test]
    fn an_anchor_frame_is_never_folded_into_the_bytes_average() {
        let mut governor = FpsGovernor::new(60, FpsGovernorConfig::default());
        governor.note_encoded_frame(500_000, true);
        assert_eq!(governor.bytes_per_frame_avg(), 0.0, "still unseeded");
        governor.note_encoded_frame(50_000, false);
        assert_eq!(
            governor.bytes_per_frame_avg(),
            50_000.0,
            "the first seeds exactly"
        );
        governor.note_encoded_frame(50_000, false);
        assert_eq!(
            governor.bytes_per_frame_avg(),
            50_000.0,
            "and a steady stream holds"
        );
    }

    #[test]
    fn nothing_moves_before_the_warmup_or_while_unseeded() {
        let mut governor = FpsGovernor::new(60, FpsGovernorConfig::default());
        governor.note_encoded_frame(1_000_000, false);
        for _ in 1..FpsGovernorConfig::default().warmup_ticks {
            assert_eq!(governor.on_tick(1_000_000, true), 60);
        }
        let mut unseeded = FpsGovernor::new(60, FpsGovernorConfig::default());
        for _ in 0..500 {
            assert_eq!(unseeded.on_tick(1_000_000, true), 60, "never acts unseeded");
        }
    }

    /// The rule that keeps the latency cost off a link that is coping.
    #[test]
    fn a_heavy_stream_on_a_clean_link_never_steps_down() {
        let mut governor = warmed(60, 200_000);
        for _ in 0..500 {
            governor.on_tick(1_000_000, false);
        }
        assert_eq!(governor.current_fps(), 60);
    }

    #[test]
    fn a_congested_over_budget_stream_steps_down_one_rung_per_window() {
        let mut governor = warmed(60, 200_000);
        // 200 kB at 60 fps is about 96 Mbps offered against a 10 Mbps target.
        for _ in 0..3 {
            governor.on_tick(10_000_000, true);
        }
        assert_eq!(governor.current_fps(), 30, "one rung, on a sustained streak");
        // The next rung has to wait out the spacing window, however over budget the stream is.
        for _ in 0..3 {
            governor.on_tick(10_000_000, true);
        }
        assert_eq!(governor.current_fps(), 30, "one cut per window, not a cascade");
        for _ in 0..8 {
            governor.on_tick(10_000_000, true);
        }
        assert_eq!(governor.current_fps(), 20);
    }

    #[test]
    fn the_ladder_floor_is_the_bottom_of_the_descent() {
        let mut governor = warmed(60, 5_000_000);
        for _ in 0..2_000 {
            governor.on_tick(1_000_000, true);
        }
        assert_eq!(governor.current_fps(), 15);
    }

    #[test]
    fn the_step_up_is_slow_and_needs_a_strict_fit_at_the_next_rung() {
        let mut governor = warmed(60, 200_000);
        for _ in 0..3 {
            governor.on_tick(10_000_000, true);
        }
        assert_eq!(governor.current_fps(), 30);
        // Clean, but 200 kB at 60 fps still would not fit: the strict projection refuses.
        for _ in 0..500 {
            governor.on_tick(60_000_000, false);
        }
        assert_eq!(governor.current_fps(), 30, "a fit that fails holds the rung");
        // A target that fits the projection exactly, and only after the full clean run.
        let mut governor = warmed(60, 200_000);
        for _ in 0..3 {
            governor.on_tick(10_000_000, true);
        }
        for _ in 0..59 {
            governor.on_tick(200_000_000, false);
        }
        assert_eq!(governor.current_fps(), 30, "not one report early");
        governor.on_tick(200_000_000, false);
        assert_eq!(governor.current_fps(), 60);
    }

    #[test]
    fn congestion_evidence_reads_the_same_constants_as_the_bitrate_controller() {
        let config = CongestionConfig::default();
        assert!(
            congestion_evidence(&config, 0.0, 10.0, 10.0, Some(20_000_000), Some(32_000_000)),
            "a controller below its ceiling has already cut on positive evidence",
        );
        assert!(!congestion_evidence(
            &config,
            0.0,
            10.0,
            10.0,
            Some(32_000_000),
            Some(32_000_000)
        ));
        assert!(
            congestion_evidence(&config, 0.05, 10.0, 10.0, None, None),
            "raw loss"
        );
        assert!(
            congestion_evidence(&config, 0.0, 120.0, 10.0, None, None),
            "an inflated round trip on a short baseline",
        );
        assert!(
            !congestion_evidence(&config, 0.0, 20.0, 10.0, None, None),
            "inside the absolute slack, so scheduling noise rather than a queue",
        );
        assert!(
            !congestion_evidence(&config, 0.0, 500.0, f64::INFINITY, None, None),
            "no baseline is not evidence",
        );
    }

    #[test]
    fn the_cadence_gate_is_a_drift_free_metronome() {
        let mut gate = EncodeCadenceGate::new();
        assert!(gate.admit(0.0, 1.0 / 30.0, 0.0, false), "the first anchors");
        assert!(!gate.admit(0.010, 1.0 / 30.0, 0.0, false), "too early");
        assert!(!gate.admit(0.020, 1.0 / 30.0, 0.0, false));
        assert!(gate.admit(0.034, 1.0 / 30.0, 0.0, false));
        // A rejection never moves the boundary, so a tail flush can re-arm against the same one.
        let mut gate = EncodeCadenceGate::new();
        gate.admit(0.0, 1.0 / 30.0, 0.0, false);
        let due = gate.next_due();
        gate.admit(0.001, 1.0 / 30.0, 0.0, false);
        gate.admit(0.002, 1.0 / 30.0, 0.0, false);
        assert_eq!(gate.next_due(), due);
    }

    #[test]
    fn the_tolerance_soaks_slot_jitter_without_slipping_a_slot() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        gate.admit(0.0, interval, 0.0, false);
        assert!(
            gate.admit(interval - 0.004, interval, 0.008, false),
            "a hair early is still this slot",
        );
        assert!(
            (gate.next_due() - interval * 2.0).abs() < 1e-12,
            "and the schedule advanced by exactly one interval",
        );
    }

    #[test]
    fn a_stall_re_anchors_rather_than_bursting_to_catch_up() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        gate.admit(0.0, interval, 0.0, false);
        assert!(gate.admit(10.0, interval, 0.0, false));
        assert!(
            (gate.next_due() - (10.0 + interval)).abs() < 1e-12,
            "anchored from now, not ten seconds of backlog",
        );
    }

    #[test]
    fn a_forced_frame_admits_and_re_anchors_and_an_inert_gate_admits_everything() {
        let mut gate = EncodeCadenceGate::new();
        let interval = 1.0 / 30.0;
        gate.admit(0.0, interval, 0.0, false);
        assert!(
            gate.admit(0.001, interval, 0.0, true),
            "a recovery latch is not gated"
        );
        assert!((gate.next_due() - (0.001 + interval)).abs() < 1e-12);
        let mut inert = EncodeCadenceGate::new();
        for step in 0..10 {
            assert!(inert.admit(f64::from(step), 0.0, 0.0, false));
        }
        assert_eq!(inert.next_due(), 0.0, "an inert gate never anchors");
    }

    #[test]
    fn the_self_heal_cadence_holds_the_wall_clock_latency_rather_than_the_frame_count() {
        assert_eq!(self_heal_effective_every(6, 60, 60), 6);
        assert_eq!(self_heal_effective_every(6, 60, 30), 3);
        assert_eq!(self_heal_effective_every(6, 60, 20), 2);
        assert_eq!(
            self_heal_effective_every(6, 60, 15),
            2,
            "floored, never every frame"
        );
        assert_eq!(self_heal_effective_every(0, 60, 15), 0, "disabled passes through");
    }

    #[test]
    fn the_pacer_is_inert_until_the_encoder_actually_over_runs() {
        let mut pacer = EncodeLoadPacer::new(60, EncodeLoadPacerConfig::default(), 15);
        for _ in 0..500 {
            pacer.note(4.0, false); // well inside the 16.7 ms budget
        }
        assert_eq!(pacer.current_fps(), 60);
    }

    /// The measured trap: a submit wall at three quarters of the budget, with the spikes a busy
    /// display puts on it, is a stream that is keeping up — the backlog never builds — and the
    /// pacer must leave it alone. The earlier 0.85 threshold and three-frame window stepped this
    /// stream 60 → 30 and back, every few seconds.
    #[test]
    fn a_wall_inside_the_budget_never_steps_however_spiky() {
        let mut pacer = EncodeLoadPacer::new(60, EncodeLoadPacerConfig::default(), 15);
        for frame in 0..2000 {
            let millis = if frame % 40 < 10 { 19.0 } else { 12.0 };
            pacer.note(millis, false);
        }
        assert_eq!(pacer.current_fps(), 60);
    }

    /// An overrun that clears inside the window costs its ragged frames and nothing more.
    #[test]
    fn a_short_over_run_is_ridden_out_rather_than_stepped() {
        let mut pacer = EncodeLoadPacer::new(60, EncodeLoadPacerConfig::default(), 15);
        for _ in 0..100 {
            pacer.note(8.0, false);
        }
        for _ in 0..20 {
            pacer.note(25.0, false); // over budget, but for a third of a second
        }
        assert_eq!(pacer.current_fps(), 60);
    }

    #[test]
    fn a_sustained_encode_over_run_steps_the_rate_down_a_clean_divisor() {
        let mut pacer = EncodeLoadPacer::new(60, EncodeLoadPacerConfig::default(), 15);
        for _ in 0..60 {
            pacer.note(25.0, false); // over the 60 fps budget, inside the 30 fps one
        }
        assert_eq!(pacer.current_fps(), 30);
        for _ in 0..500 {
            pacer.note(25.0, false);
        }
        assert_eq!(pacer.current_fps(), 30, "and settles where it fits");
    }

    #[test]
    fn an_anchor_frames_encode_time_never_paces_the_stream() {
        let mut pacer = EncodeLoadPacer::new(60, EncodeLoadPacerConfig::default(), 15);
        for _ in 0..100 {
            pacer.note(200.0, true);
        }
        assert_eq!(pacer.current_fps(), 60);
        assert_eq!(pacer.encode_millis_avg(), 0.0, "not even folded");
    }

    #[test]
    fn the_pacer_steps_back_up_only_on_sustained_headroom_for_the_tighter_budget() {
        let mut pacer = EncodeLoadPacer::new(60, EncodeLoadPacerConfig::default(), 15);
        for _ in 0..60 {
            pacer.note(25.0, false);
        }
        assert_eq!(pacer.current_fps(), 30);
        // 15 ms fits the 30 fps budget but not 90% of the 60 fps one: it holds.
        for _ in 0..500 {
            pacer.note(15.4, false);
        }
        assert_eq!(pacer.current_fps(), 30);
        for _ in 0..100 {
            pacer.note(4.0, false);
        }
        assert_eq!(
            pacer.current_fps(),
            30,
            "a hundred clean frames are not yet sustained"
        );
        for _ in 0..100 {
            pacer.note(4.0, false);
        }
        assert_eq!(pacer.current_fps(), 60);
    }

    #[test]
    fn the_budget_is_the_inter_arrival_interval_and_a_degenerate_rate_is_clamped() {
        assert!((budget_millis(60) - 16.666_666_666_666_668).abs() < 1e-9);
        assert!((budget_millis(0) - 1000.0).abs() < 1e-9);
    }
}
