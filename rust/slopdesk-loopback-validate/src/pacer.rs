//! The ADAPTIVE PACER DEPTH reflex check — pure virtual clock, no hardware, nothing random.
//!
//! It models the depth-one present-on-arrival pacer: a delivered frame arrives and shows at the
//! same instant, with 120 Hz re-show ticks between presents. The depth ACTION runs on network
//! lates, and those come from the REAL late detector consuming synthetic send and arrival stamps —
//! exactly the production session-to-pacer wiring.
//!
//! Five phases:
//! - A, three seconds clean at 60 — never engages.
//! - B, ten seconds with a +35 ms delay spike every twentieth frame, the Wi-Fi burst shape —
//!   promotes within a second and a half of onset and holds to the end of the phase.
//! - C, eight seconds clean — demotes two to four seconds after the last late.
//! - D, a 60→30 downshift with no loss — at most one crossover transient, never a promotion; and
//!   with the cadence hint, not even that.
//! - E, a motion stop then typing — zero lates, from the idle and density gates.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_video::pacer_depth::{OwdLateConfig, OwdLateDetector, PacerDepthConfig, PacerDepthPolicy};

/// What the five phases measured.
#[derive(Clone, Copy, Debug, Default)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each is one independently-measured verdict bit; collapsing them would lose which one failed"
)]
pub(crate) struct PacerDepthResult {
    /// Phase A lates.
    pub clean_lates: u32,
    /// Phase A present gaps.
    pub clean_gaps: u32,
    /// Whether phase A held depth one throughout.
    pub clean_depth_stayed_1: bool,
    /// Virtual milliseconds from burst onset to the promotion, or none if it never promoted.
    pub promote_after_onset_ms: Option<f64>,
    /// Whether the promotion held to the end of the burst.
    pub held_through_burst: bool,
    /// Phase B lates.
    pub burst_lates: u32,
    /// Virtual milliseconds from the LAST late to the demotion, or none if it never demoted.
    pub demote_after_last_late_ms: Option<f64>,
    /// Whether the recovery phase ended at depth one.
    pub depth1_at_recovery_end: bool,
    /// Phase D lates without the cadence hint.
    pub downshift_lates: u32,
    /// Whether phase D ever promoted.
    pub downshift_promoted: bool,
    /// Phase D lates with the hint.
    pub downshift_hint_lates: u32,
    /// Phase E lates.
    pub typing_lates: u32,
    /// Phase E present gaps.
    pub typing_gaps: u32,
}

/// The whole state one run threads through its phases.
struct Rig {
    /// The policy under test.
    policy: PacerDepthPolicy,
    /// The real late detector feeding its network-late input.
    detector: OwdLateDetector,
    /// The content clock.
    now: f64,
    /// When the last content present happened.
    last_present: f64,
    /// The content clock at the last late verdict.
    last_late_at: Option<f64>,
    /// The host's own send clock, which is strictly monotone: a delay never rewinds a stamp.
    send_clock_ms: f64,
}

impl Rig {
    /// A rig at rest.
    fn new() -> Self {
        Self {
            policy: PacerDepthPolicy::new(PacerDepthConfig::default(), true),
            detector: OwdLateDetector::new(OwdLateConfig::default()),
            now: 0.0,
            last_present: 0.0,
            last_late_at: None,
            send_clock_ms: 0.0,
        }
    }

    /// One content slot: advance the clock, run the re-show ticks that elapsed, then fold the
    /// arrival and the present at the same instant.
    fn step(&mut self, delta: f64) {
        self.now += delta;
        let mut tick = self.last_present + 1.0 / 120.0;
        #[expect(
            clippy::while_float,
            reason = "the rig's clock IS virtual seconds, and the loop is bounded by one content slot"
        )]
        while tick < self.now {
            self.policy.note_reshow(tick);
            tick += 1.0 / 120.0;
        }
        self.policy.note_arrival(self.now);
        self.policy.note_present(self.now);
        self.last_present = self.now;
    }

    /// One per-frame delay sample through the REAL detector.
    ///
    /// The host packetizes on the content cadence, so a spike delays the ARRIVAL and nothing else —
    /// the deviation the detector sees is exactly the spike over a constant base delay.
    fn sample(&mut self, spike: f64, interval_ms: f64) {
        self.send_clock_ms += interval_ms;
        let arrival_ms = self.send_clock_ms + 0.020 * 1000.0 + spike * 1000.0;
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "a virtual send clock bounded by the scenario's own length is far inside u32"
        )]
        let send_ts = self.send_clock_ms.round() as u32;
        if self.detector.note(arrival_ms, send_ts, interval_ms).is_some() {
            self.policy.note_network_late(self.now);
            self.last_late_at = Some(self.now);
        }
    }
}

/// Drives the five phases.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "five phases of one policy, each a handful of lines that only read as a sequence"
)]
pub(crate) fn run(verbose: bool) -> PacerDepthResult {
    let mut result = PacerDepthResult {
        clean_depth_stayed_1: true,
        held_through_burst: true,
        ..PacerDepthResult::default()
    };
    let mut rig = Rig::new();
    let delta60 = 1.0 / 60.0;

    // ── Phase A: three seconds clean at 60, which also warms the detector's baseline ──
    for _ in 0..180 {
        rig.step(delta60);
        rig.sample(0.0, delta60 * 1000.0);
        if rig.policy.depth() != 1 {
            result.clean_depth_stayed_1 = false;
        }
    }
    let clean = rig.policy.drain_counters();
    result.clean_lates = clean.late_frames;
    result.clean_gaps = clean.present_gaps;
    if verbose {
        println!(
            "    [A] 3s clean 60fps        : late={} gaps={} depth={}",
            result.clean_lates,
            result.clean_gaps,
            rig.policy.depth(),
        );
    }

    // ── Phase B: ten seconds with a +35 ms spike every twentieth frame ──
    let onset = rig.now;
    for index in 0..600_usize {
        rig.step(delta60);
        rig.sample(if index % 20 == 0 { 0.035 } else { 0.0 }, delta60 * 1000.0);
        if rig.policy.depth() == 2 && result.promote_after_onset_ms.is_none() {
            result.promote_after_onset_ms = Some((rig.now - onset) * 1000.0);
        }
        if result.promote_after_onset_ms.is_some() && rig.policy.depth() != 2 {
            result.held_through_burst = false;
        }
    }
    result.burst_lates = rig.policy.drain_counters().late_frames;
    if verbose {
        println!(
            "    [B] 10s owd-spike burst   : late={} promote@{} held={} depth={}",
            result.burst_lates,
            millis(result.promote_after_onset_ms),
            if result.held_through_burst { "YES" } else { "no" },
            rig.policy.depth(),
        );
    }

    // ── Phase C: eight seconds clean ──
    let last_late = rig.last_late_at;
    for _ in 0..480 {
        rig.step(delta60);
        rig.sample(0.0, delta60 * 1000.0);
        if rig.policy.depth() == 1
            && result.demote_after_last_late_ms.is_none()
            && let Some(late) = last_late
        {
            result.demote_after_last_late_ms = Some((rig.now - late) * 1000.0);
        }
    }
    result.depth1_at_recovery_end = rig.policy.depth() == 1;
    let _ = rig.policy.drain_counters();
    if verbose {
        println!(
            "    [C] 8s clean recovery     : demote {} after last late, depth={}",
            millis(result.demote_after_last_late_ms),
            rig.policy.depth(),
        );
    }

    // ── Phase D: a 60→30 downshift with no loss and NO hint ──
    for _ in 0..150 {
        rig.step(1.0 / 30.0);
        if rig.policy.depth() != 1 {
            result.downshift_promoted = true;
        }
    }
    result.downshift_lates = rig.policy.drain_counters().late_frames;

    // The hint arm is a separate instance: two seconds of warm-up at 60, the cadence hint lands,
    // then the downshift. The rebased threshold means zero lates, not even the crossover transient.
    let mut hinted = PacerDepthPolicy::new(PacerDepthConfig::default(), true);
    let mut hinted_now = 0.0_f64;
    for _ in 0..120 {
        hinted_now += delta60;
        hinted.note_arrival(hinted_now);
        hinted.note_present(hinted_now);
    }
    hinted.set_interval_hint(Some(1.0 / 30.0));
    for _ in 0..150 {
        hinted_now += 1.0 / 30.0;
        hinted.note_arrival(hinted_now);
        hinted.note_present(hinted_now);
    }
    result.downshift_hint_lates = hinted.drain_counters().late_frames;
    if verbose {
        println!(
            "    [D] 60→30 downshift       : no-hint late={} promoted={}   with-hint late={}",
            result.downshift_lates,
            if result.downshift_promoted { "YES" } else { "no" },
            result.downshift_hint_lates,
        );
    }

    // ── Phase E: a 400 ms motion stop, then typing at one frame per 180 ms ──
    rig.step(0.400);
    for _ in 0..15 {
        rig.step(0.180);
    }
    let typing = rig.policy.drain_counters();
    result.typing_lates = typing.late_frames;
    result.typing_gaps = typing.present_gaps;
    if verbose {
        println!(
            "    [E] stop + typing @180ms  : late={} gaps={} (gaps ≤1 = the stop-boundary episode, by \
             design) depth={}",
            result.typing_lates,
            result.typing_gaps,
            rig.policy.depth(),
        );
    }
    result
}

/// How an optional elapsed time prints.
fn millis(value: Option<f64>) -> String {
    value.map_or_else(|| "NEVER".to_owned(), |ms| format!("{ms:.0}ms"))
}
