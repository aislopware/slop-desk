//! The two halves of the feedback loop every closed-loop scenario shares.
//!
//! The Swift original copy-pasted this block once per arm: the client folds each arriving fragment
//! into its jitter and trendline estimators, accumulates a window of counters, emits a
//! `NetworkStatsReport` on the ~50 ms cadence, that report round-trips the REAL recovery wire, and
//! the host folds it into a `NetworkEstimate` and ticks the congestion controller. What VARIES
//! between arms is the capacity model, the content and the verdict — never this. So it lives once
//! here and each scenario keeps only its own loop.
//!
//! Nothing here holds a clock. Every time is the caller's virtual millisecond, which is what makes
//! two runs of an arm produce the same numbers.

use slopdesk_video::client_jitter::OwdJitterEstimator;
use slopdesk_video::congestion::{CongestionConfig, LiveCongestionController, is_material_change};
use slopdesk_video::fragment::FrameFragment;
use slopdesk_video::live_bitrate::{DEFAULT_BITS_PER_PIXEL_PER_FRAME, target_bitrate};
use slopdesk_video::network_estimate::NetworkEstimate;
use slopdesk_video::reassembler::{FrameReassembler, ReassembledFrame, ReassemblyResult, distance_wrapped};
use slopdesk_video::recovery::{NetworkStatsReport, RecoveryMessage};
use slopdesk_video::trendline::{TrendSampler, TrendlineEstimator, pack_trend_flags, pack_trend_milli};

use crate::rig::{FPS, HEIGHT, WIDTH};

/// The live budget for the harness geometry — the ceiling every controller starts at.
#[must_use]
pub fn ceiling_bps() -> i64 {
    target_bitrate(
        i64::try_from(WIDTH).unwrap_or(1280),
        i64::try_from(HEIGHT).unwrap_or(720),
        FPS,
        2_000_000,
        DEFAULT_BITS_PER_PIXEL_PER_FRAME,
    )
}

/// One virtual frame interval at the harness frame rate, in milliseconds.
#[must_use]
#[expect(
    clippy::cast_precision_loss,
    reason = "the harness frame rate is a small integer, exact in f64"
)]
pub fn frame_interval_ms() -> f64 {
    1000.0 / FPS as f64
}

/// `clientHoldMs` as the real client computes it: `now − observedAt`, clamped non-negative.
#[must_use]
pub fn hold_ms(now: f64, observed_at: f64) -> f64 {
    (now - observed_at).max(0.0)
}

/// The pacer telemetry a report may carry, when the scenario is driving the depth policy.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PacerTelemetry {
    /// Frames the depth policy classified late in this window.
    pub late_frames: u32,
    /// Present gaps in this window.
    pub present_gaps: u32,
    /// The depth in force at the end of it.
    pub depth: u32,
}

/// The client half: the estimators the arriving fragments feed, and the window they accumulate.
#[derive(Debug, Default)]
pub struct Client {
    /// The inter-arrival jitter estimator, fed once per fragment.
    pub owd: OwdJitterEstimator,
    /// The delay-gradient estimator, fed once per strictly-newer frame.
    pub trend: TrendlineEstimator,
    /// The gate that decides which fragment is that one.
    pub sampler: TrendSampler,
    /// Complete frames this window.
    frames: u32,
    /// Of those, how many parity filled.
    fec: u32,
    /// Frames declared unrecoverable this window.
    unrecovered: u32,
    /// The newest host stamp seen, wrap-aware.
    latest_host_send_ts: u32,
    /// When that stamp arrived, in the caller's virtual milliseconds.
    latest_observed_at_ms: f64,
}

impl Client {
    /// A client that has seen nothing.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Folds one arriving fragment's TIMING — the jitter estimator, the newest-stamp tracker and,
    /// when `sample_trend`, the production trendline gate.
    ///
    /// This is the exact `SlopDeskVideoClientSession.ingestVideo` cadence: `owd.note` per fragment,
    /// the stamp advanced only on a strictly-newer one, and the trendline admitted at most once per
    /// frame through [`TrendSampler`].
    pub fn note_arrival(&mut self, parsed: &FrameFragment, arrival_ms: f64, sample_trend: bool) {
        self.owd.note(arrival_ms / 1000.0);
        let stamp = parsed.header.host_send_ts_millis;
        if stamp != 0
            && (self.latest_host_send_ts == 0 || distance_wrapped(stamp, self.latest_host_send_ts) > 0)
        {
            self.latest_host_send_ts = stamp;
            self.latest_observed_at_ms = arrival_ms;
        }
        if sample_trend && self.sampler.should_sample(parsed.header.frame_id, stamp) {
            self.trend.note(arrival_ms, stamp);
        }
    }

    /// Counts one frame the reassembler completed.
    pub const fn completed(&mut self, frame: &ReassembledFrame) {
        self.frames = self.frames.saturating_add(1);
        if frame.recovered_via_fec {
            self.fec = self.fec.saturating_add(1);
        }
    }

    /// Counts one frame the reassembler gave up on.
    pub const fn unrecovered(&mut self) {
        self.unrecovered = self.unrecovered.saturating_add(1);
    }

    /// Builds this window's report and clears the window.
    ///
    /// `now_client_ms` is the client's own virtual clock at the moment it composes — the arrival of
    /// the fragment that triggered the cadence — which is what makes `client_hold_ms` the real
    /// number rather than a host-side guess.
    pub fn report(
        &mut self,
        now_client_ms: f64,
        with_trend: bool,
        pacer: PacerTelemetry,
    ) -> NetworkStatsReport {
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "a virtual hold bounded by the scenario's own clock is far inside u32"
        )]
        let hold = if self.latest_host_send_ts == 0 {
            0
        } else {
            hold_ms(now_client_ms, self.latest_observed_at_ms).max(0.0) as u32
        };
        let report = NetworkStatsReport {
            frames_received: self.frames,
            fec_recovered: self.fec,
            unrecovered: self.unrecovered,
            latest_host_send_ts: self.latest_host_send_ts,
            client_hold_ms: hold,
            owd_jitter_micros: self.owd.jitter_micros(),
            owd_trend_milli: if with_trend {
                pack_trend_milli(self.trend.modified_trend())
            } else {
                0
            },
            owd_trend_flags: if with_trend {
                pack_trend_flags(self.trend.state(), self.trend.num_deltas())
            } else {
                0
            },
            pacer_late_frames: pacer.late_frames,
            pacer_present_gaps: pacer.present_gaps,
            pacer_depth: pacer.depth,
        };
        self.frames = 0;
        self.fec = 0;
        self.unrecovered = 0;
        report
    }
}

/// What one delivered fragment did to the reassembler.
#[derive(Debug)]
pub enum Delivered {
    /// It completed a frame.
    Frame(Box<ReassembledFrame>),
    /// It aged one out past recovery.
    Lost,
    /// It was absorbed, or it was too old to matter.
    Pending,
}

/// The intra-frame send gap: a large frame's fragments arrive spread across the wire, not at one
/// instant, so the jitter estimator sees a realistic inter-arrival delta.
///
/// The host paces a frame over about 8 ms, and a single-fragment frame has no spread at all.
#[must_use]
#[expect(
    clippy::cast_precision_loss,
    reason = "a frame's fragment count is a small integer, exact in f64"
)]
pub fn intra_gap_ms(fragments: usize) -> f64 {
    if fragments > 1 {
        8.0 / fragments as f64
    } else {
        0.0
    }
}

/// Delivers one fragment: the REAL codec round trip, the client's timing fold, then the
/// reassembler.
///
/// The bytes go through `FrameFragment::encode`/`decode` rather than being handed over as a struct,
/// so a field that stopped surviving the wire would surface here rather than on a client.
pub fn ingest(
    reassembler: &mut FrameReassembler,
    client: &mut Client,
    fragment: &FrameFragment,
    arrival_ms: f64,
    sample_trend: bool,
) -> Delivered {
    let Ok(parsed) = FrameFragment::decode(&fragment.encode()) else {
        return Delivered::Pending;
    };
    client.note_arrival(&parsed, arrival_ms, sample_trend);
    match reassembler.ingest(&parsed) {
        ReassemblyResult::Completed(frame) => {
            client.completed(&frame);
            Delivered::Frame(Box::new(frame))
        },
        ReassemblyResult::Dropped { .. } => {
            client.unrecovered();
            Delivered::Lost
        },
        ReassemblyResult::Incomplete | ReassemblyResult::Stale => Delivered::Pending,
    }
}

/// Drains the reassembler's deferred drop queue into the client's window, answering how many it
/// held.
///
/// A frame declared lost mid-burst is reported past the reorder grace rather than at the fragment
/// that finally aged it out, so a caller that must re-anchor learns about it here.
pub fn drain_lost(reassembler: &mut FrameReassembler, client: &mut Client) -> usize {
    let mut count = 0;
    while reassembler.next_dropped_frame().is_some() {
        client.unrecovered();
        count += 1;
    }
    count
}

/// Round-trips one report through the REAL recovery wire, both directions.
///
/// A scenario that handed the struct straight to the host would not be testing the thing every
/// number in it crosses; anything that stopped surviving the codec would show up here.
#[must_use]
pub fn round_trip(report: NetworkStatsReport) -> Option<NetworkStatsReport> {
    let wire = RecoveryMessage::NetworkStats(report).encode();
    match RecoveryMessage::decode(&wire) {
        Ok(RecoveryMessage::NetworkStats(received)) => Some(received),
        _ => None,
    }
}

/// The host half: the estimate the report folds into, and the controller it ticks.
#[derive(Debug)]
pub struct Host {
    /// The link estimate.
    pub estimate: NetworkEstimate,
    /// The rate controller.
    pub controller: LiveCongestionController,
    /// The rate last handed to the encoder — what the hardware is actually running at.
    pub actuated: i64,
    /// The controller's own latest answer, which the material-change gate may have hidden.
    pub target: i64,
}

impl Host {
    /// A host starting at the ceiling, with the delay-gradient cut armed or not.
    #[must_use]
    pub fn new(ceiling: i64, gradient_cut_enabled: bool) -> Self {
        Self {
            estimate: NetworkEstimate::new(),
            controller: LiveCongestionController::with_ceiling(
                ceiling,
                CongestionConfig::default(),
                gradient_cut_enabled,
            ),
            actuated: ceiling,
            target: ceiling,
        }
    }

    /// Folds one received report — exactly
    /// `SlopDeskVideoHostSession.handleRecovery(.networkStats)`.
    ///
    /// `host_now_ms` is the host's virtual clock when the report lands, so the round trip is
    /// computed the same clock-skew-free way production does it. `with_trend` off feeds a neutral
    /// trend rather than the report's, which is how an arm holds the gradient out of the loop.
    pub fn fold(&mut self, received: &NetworkStatsReport, host_now_ms: f64, with_trend: bool) {
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "a virtual clock bounded by the scenario's own length is far inside u32"
        )]
        let now = host_now_ms.max(0.0) as u32;
        let rtt =
            NetworkEstimate::compute_rtt_millis(now, received.latest_host_send_ts, received.client_hold_ms);
        let (state, modified) = if with_trend {
            (
                received.owd_trend_state_raw(),
                received.owd_trend_modified_milli_signed(),
            )
        } else {
            (0, 0)
        };
        self.estimate.fold(
            rtt,
            received.frames_received,
            received.unrecovered,
            received.owd_jitter_micros,
            state,
            modified,
        );
    }

    /// Ticks the controller and records its answer. Answers the new target.
    pub fn tick(&mut self) -> i64 {
        self.target = self.controller.decide(&self.estimate, None).target;
        self.target
    }

    /// Actuates `target` when the material-change gate admits it. Answers whether it moved.
    pub fn actuate(&mut self, target: i64) -> bool {
        if is_material_change(
            self.actuated,
            target,
            self.controller.ceiling(),
            CongestionConfig::default(),
        ) {
            self.actuated = target;
            return true;
        }
        false
    }
}

/// The rate as megabits per second, for the report lines.
#[must_use]
#[expect(
    clippy::cast_precision_loss,
    reason = "a bitrate in the tens of megabits is exact in f64"
)]
pub fn mbps(bps: i64) -> f64 {
    bps as f64 / 1_000_000.0
}
