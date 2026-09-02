//! The CLOSED-LOOP adaptation scenario: the complete reflex, through the real components.
//!
//! This is the gap a zero-loss loopback cannot reach. Real hardware encode at the live bitrate →
//! the real packetizer at the current FEC tier → in-code per-fragment loss → the real fragment
//! codec's round trip → the real reassembler with its parity recovery → the client's windowed
//! counters and jitter estimator → a `NetworkStatsReport` over the REAL recovery wire → the host's
//! round-trip computation and fold → the adaptive FEC ladder and the congestion controller → a REAL
//! `VTSessionSetProperty` on the encoder. The client's jitter controller and the pacer's depth
//! policy ride the same completed-frame stream.
//!
//! Three phases — CLEAN, ADVERSE, CLEAN — so every controller must move away from its baseline
//! under stress and back afterwards. The clock is a virtual 16 ms per frame and the loss is chosen
//! by fragment index, so a run is a repeat of the last one.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_video::adaptive_fec;
use slopdesk_video::client_jitter::{
    AdaptiveJitterController, DEFAULT_JITTER_SAFETY, DEFAULT_SHRINK_COOLDOWN_FRAMES,
};
use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::loopback::heavier_tier;
use slopdesk_video::pacer_depth::{PacerDepthConfig, PacerDepthPolicy};
use slopdesk_video::packetizer::PacketizeOptions;

use crate::link::{
    Client, Delivered, Host, PacerTelemetry, ceiling_bps, drain_lost, frame_interval_ms, ingest,
    intra_gap_ms, mbps, round_trip,
};
use crate::rig::{Decoder, Encoder, Source};
use crate::wire::Wire;

/// How the arm is configured.
#[derive(Clone, Copy, Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each flag switches one adaptation off independently — that IS the A/B matrix this scenario \
              sweeps"
)]
pub(crate) struct Arm {
    /// Frames per phase.
    pub frames_per_phase: usize,
    /// Whether the congestion controller actuates the encoder.
    pub abr: bool,
    /// Whether the FEC ladder is allowed to walk.
    pub fec: bool,
    /// Whether the adverse phase adds an arrival saw and drives the jitter controller.
    pub jitter: bool,
    /// A pinned FEC tier — the non-adaptive baseline the ladder is measured against.
    pub fixed_tier: Option<u8>,
    /// Whether the adverse phase ALSO inflates the one-way delay.
    ///
    /// On, the loss is CORROBORATED — real congestion, and the controller must cut. Off, it is
    /// WEATHER: loss at a flat round trip, the measured inter-ISP shape, and the controller must
    /// HOLD.
    pub congest_rtt_in_adverse: bool,
    /// Whether to print the per-phase trace.
    pub verbose: bool,
}

impl Default for Arm {
    fn default() -> Self {
        Self {
            frames_per_phase: 90,
            abr: true,
            fec: true,
            jitter: true,
            fixed_tier: None,
            congest_rtt_in_adverse: true,
            verbose: false,
        }
    }
}

/// What the three phases measured.
#[derive(Clone, Debug)]
pub(crate) struct ClosedLoopResult {
    /// Mean actuated rate per phase, in megabits per second.
    pub phase_avg_bitrate_mbps: Vec<f64>,
    /// The heaviest FEC tier each phase reached.
    pub phase_peak_tier: Vec<u8>,
    /// The deepest playout the jitter controller asked for, per phase.
    pub phase_peak_depth: Vec<u32>,
    /// The deepest the late-event depth policy asked for, per phase.
    pub phase_peak_depth_v2: Vec<u32>,
    /// Frames lost past recovery, per phase.
    pub phase_unrecovered: Vec<usize>,
    /// Mean encoded bytes per frame, per phase.
    pub phase_avg_enc_bytes: Vec<usize>,
    /// Whether the adaptive tier EVER selected OFF, which the ladder floor forbids.
    pub saw_off_tier: bool,
    /// Frames lost past recovery in the SECOND half of the adverse phase — the steady-state window,
    /// which is the only fair place to compare an adaptive ladder against a pinned one.
    pub adverse_unrec_second_half: usize,
    /// Whether the mean rate fell in the adverse phase.
    pub bitrate_fell_in_adverse: bool,
    /// Whether it climbed back afterwards.
    pub bitrate_recovered_after: bool,
    /// The controller's target at the END of the recovery phase.
    ///
    /// The recovery verdict keys on this against the adverse TROUGH, not the phase average: the
    /// climb only starts once the round-trip average decays and the hold-down expires, and the
    /// above-knee climb is deliberately cautious. "Recovered" means the climb is under way — a fast
    /// reclimb to the ceiling inside a 1.5 s window IS the pumping this design refuses.
    pub end_bitrate_mbps: f64,
    /// The lowest target the controller reached during the adverse phase.
    pub adverse_trough_mbps: f64,
}

impl ClosedLoopResult {
    /// Whether every per-phase series holds one entry per phase.
    ///
    /// [`run`] hands back a `Default` — every series EMPTY — when the encoder or the source cannot
    /// be created, and the suite indexes three phases; reading an empty arm as a FAIL is the
    /// difference between a printed verdict and an index panic.
    #[must_use]
    pub(crate) const fn has_every_phase(&self) -> bool {
        const PHASES: usize = 3;
        self.phase_avg_bitrate_mbps.len() == PHASES
            && self.phase_peak_tier.len() == PHASES
            && self.phase_peak_depth.len() == PHASES
            && self.phase_peak_depth_v2.len() == PHASES
            && self.phase_unrecovered.len() == PHASES
            && self.phase_avg_enc_bytes.len() == PHASES
    }
}

impl Default for ClosedLoopResult {
    fn default() -> Self {
        Self {
            phase_avg_bitrate_mbps: Vec::new(),
            phase_peak_tier: Vec::new(),
            phase_peak_depth: Vec::new(),
            phase_peak_depth_v2: Vec::new(),
            phase_unrecovered: Vec::new(),
            phase_avg_enc_bytes: Vec::new(),
            saw_off_tier: false,
            adverse_unrec_second_half: 0,
            bitrate_fell_in_adverse: false,
            bitrate_recovered_after: false,
            end_bitrate_mbps: 0.0,
            adverse_trough_mbps: f64::INFINITY,
        }
    }
}

/// What one phase accumulated, before it is folded into the result.
#[derive(Clone, Copy, Debug, Default)]
struct Phase {
    /// The sum of the actuated rate over every report.
    bitrate_sum: f64,
    /// How many reports that was.
    bitrate_count: usize,
    /// The heaviest tier reached.
    peak_tier: u8,
    /// The deepest playout asked for.
    peak_depth: u32,
    /// The deepest the late-event policy asked for.
    peak_depth_v2: u32,
    /// Frames lost past recovery.
    unrecovered: usize,
    /// Encoded bytes.
    enc_bytes: usize,
    /// Frames encoded.
    enc_count: usize,
}

/// The one-way delay a phase runs at: a congested adverse phase stands a queue, a weather one does
/// not.
const fn one_way_ms(arm: &Arm, phase: usize) -> f64 {
    if arm.congest_rtt_in_adverse && phase == 1 {
        45.0
    } else {
        5.0
    }
}

/// The per-fragment loss percentage a phase runs at.
const fn loss_percent(phase: usize) -> usize {
    if phase == 1 { 3 } else { 0 }
}

/// The arrival saw the adverse phase adds — a ±0/40 ms alternation, the shape a jitter buffer
/// exists for.
const fn jitter_ms(arm: &Arm, phase: usize, frame: usize) -> f64 {
    if arm.jitter && phase == 1 && frame & 1 == 1 {
        40.0
    } else {
        0.0
    }
}

/// Drives the complete adaptation reflex.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "one closed loop, told in the order the bytes travel; splitting it would hide the reflex that \
              IS the test"
)]
pub(crate) fn run(arm: Arm) -> ClosedLoopResult {
    let mut result = ClosedLoopResult::default();
    let ceiling = ceiling_bps();

    let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
        println!("  closed-loop encoder create FAILED");
        return result;
    };
    let Ok(source) = Source::create(false) else {
        return result;
    };
    encoder.set_live_bitrate(ceiling);
    let decoder = Decoder::create(false);
    let mut wire = Wire::new(1);
    let mut client = Client::new();
    let mut host = Host::new(ceiling, false);
    let mut jitter = AdaptiveJitterController::new(
        1,
        8,
        #[expect(
            clippy::cast_precision_loss,
            reason = "the harness frame rate is a small integer, exact in f64"
        )]
        {
            crate::rig::FPS as f64
        },
        1,
        DEFAULT_JITTER_SAFETY,
        DEFAULT_SHRINK_COOLDOWN_FRAMES,
    );
    let mut depth_policy = PacerDepthPolicy::new(PacerDepthConfig::default(), true);

    let mut tier = arm.fixed_tier.unwrap_or(adaptive_fec::DEFAULT_TIER);
    #[expect(clippy::integer_division, reason = "the floor is the bound being computed")]
    let second_half = arm.frames_per_phase / 2;
    let mut clock_ms = 0.0_f64;
    let mut global_fragment = 0_usize;
    let mut recovery_pending = false;
    let mut depth = jitter.target_depth();
    let mut adverse_second_half = 0_usize;

    for phase in 0..3_usize {
        let loss = loss_percent(phase);
        let one_way = one_way_ms(&arm, phase);
        let mut window = Phase {
            peak_depth_v2: depth_policy.depth(),
            ..Phase::default()
        };
        if arm.verbose {
            println!("  ── PHASE {} {} ──", phase + 1, phase_name(&arm, phase));
        }

        for frame in 0..arm.frames_per_phase {
            let index = phase * arm.frames_per_phase + frame;
            source.paint(index, false);
            let force = phase == 0 && frame == 0 || recovery_pending;
            recovery_pending = false;
            clock_ms += frame_interval_ms();
            encoder.encode_live(&source, index, force);
            encoder.complete_frames();

            for emitted in encoder.drain() {
                window.enc_bytes = window.enc_bytes.saturating_add(emitted.avcc.len());
                window.enc_count = window.enc_count.saturating_add(1);
                #[expect(
                    clippy::cast_possible_truncation,
                    clippy::cast_sign_loss,
                    reason = "a virtual clock bounded by the scenario's own length is far inside u32"
                )]
                let send_ts = clock_ms as u32;
                let fragments = wire.packetize_stamped(&emitted.avcc, PacketizeOptions {
                    keyframe: emitted.keyframe,
                    host_send_ts_millis: send_ts,
                    fec_tier: tier,
                    ..PacketizeOptions::default()
                });
                let arrival_base = clock_ms + one_way + jitter_ms(&arm, phase, frame);
                let gap = intra_gap_ms(fragments.len());

                for (local, fragment) in fragments.iter().enumerate() {
                    global_fragment = global_fragment.saturating_add(1);
                    #[expect(
                        clippy::cast_precision_loss,
                        reason = "a fragment index inside one frame is a small integer, exact in f64"
                    )]
                    let arrival_ms = arrival_base + local as f64 * gap;
                    // Deterministic ~loss%, chosen by wire POSITION rather than by a generator, so
                    // two runs of this arm eat the same fragments.
                    if loss > 0 && (global_fragment * 7 + 3) % 100 < loss {
                        continue;
                    }
                    let mut casualties = 0_usize;
                    match ingest(&mut wire.reassembler, &mut client, fragment, arrival_ms, false) {
                        Delivered::Frame(frame_in) => {
                            decoder.decode(&frame_in.avcc, frame_in.keyframe);
                            if arm.jitter {
                                depth = jitter.note_frame(client.owd.jitter_seconds());
                            }
                            window.peak_depth = window.peak_depth.max(depth);
                            // Present-on-arrival: at depth one a delivered frame arrives and shows
                            // at the same instant, so one completion is both events.
                            depth_policy.note_arrival(arrival_ms / 1000.0);
                            depth_policy.note_present(arrival_ms / 1000.0);
                            window.peak_depth_v2 = window.peak_depth_v2.max(depth_policy.depth());
                        },
                        Delivered::Lost => casualties = 1,
                        Delivered::Pending => {},
                    }
                    casualties = casualties.saturating_add(drain_lost(&mut wire.reassembler, &mut client));
                    if casualties > 0 {
                        window.unrecovered = window.unrecovered.saturating_add(casualties);
                        recovery_pending = true;
                        if phase == 1 && frame >= second_half {
                            adverse_second_half = adverse_second_half.saturating_add(casualties);
                        }
                    }
                }

                // The client's report timer is fps-independent; three encoded frames is the ~50 ms
                // production cadence at the harness rate.
                if !window.enc_count.is_multiple_of(3) {
                    continue;
                }
                let pacer = depth_policy.drain_counters();
                let report = client.report(clock_ms + one_way, false, PacerTelemetry {
                    late_frames: pacer.late_frames,
                    present_gaps: pacer.present_gaps,
                    depth: depth_policy.depth(),
                });
                let Some(received) = round_trip(report) else {
                    continue;
                };
                host.fold(&received, clock_ms + one_way * 2.0, false);
                if arm.fec && arm.fixed_tier.is_none() {
                    tier = adaptive_fec::tier_for_loss(host.estimate.loss_rate, tier, false);
                }
                if tier == 1 {
                    result.saw_off_tier = true;
                }
                window.peak_tier = heavier_tier(window.peak_tier, tier);
                if arm.abr {
                    let target = host.tick();
                    if host.actuate(target) {
                        encoder.set_live_bitrate(host.actuated);
                    }
                }
                window.bitrate_sum += mbps(host.actuated);
                window.bitrate_count = window.bitrate_count.saturating_add(1);
                // The recovery verdict keys on the controller TARGET, not the actuated rate: the
                // material-change gate deliberately hides sub-500k moves, and the cautious
                // above-knee climb is sub-500k per tick by design.
                if phase == 1 {
                    result.adverse_trough_mbps = result.adverse_trough_mbps.min(mbps(host.target));
                }
                if arm.verbose && window.enc_count.is_multiple_of(15) {
                    #[expect(
                        clippy::integer_division,
                        reason = "a mean byte count for the readout; the remainder is under one byte"
                    )]
                    let bytes_per_frame = window.enc_bytes / window.enc_count.max(1);
                    println!(
                        "    f{frame:<3} loss={:.3} unrec/win={}  tier={tier}({})  bitrate={:.1}Mbps  \
                         depth={depth}  enc~{}B",
                        host.estimate.loss_rate,
                        received.unrecovered,
                        slopdesk_video::loopback::tier_description(tier),
                        mbps(host.actuated),
                        bytes_per_frame,
                    );
                }
            }
        }

        result.phase_avg_bitrate_mbps.push(if window.bitrate_count > 0 {
            #[expect(
                clippy::cast_precision_loss,
                reason = "a report count inside one phase is a small integer, exact in f64"
            )]
            {
                window.bitrate_sum / window.bitrate_count as f64
            }
        } else {
            mbps(host.actuated)
        });
        result.phase_peak_tier.push(window.peak_tier);
        result.phase_peak_depth.push(window.peak_depth);
        result.phase_peak_depth_v2.push(window.peak_depth_v2);
        result.phase_unrecovered.push(window.unrecovered);
        result
            .phase_avg_enc_bytes
            .push(window.enc_bytes.checked_div(window.enc_count).unwrap_or(0));
    }

    result.adverse_unrec_second_half = adverse_second_half;
    result.end_bitrate_mbps = mbps(host.target);
    if let &[clean, adverse, _] = result.phase_avg_bitrate_mbps.as_slice() {
        result.bitrate_fell_in_adverse = adverse < clean - 0.05;
        result.bitrate_recovered_after = result.adverse_trough_mbps.is_finite()
            && result.end_bitrate_mbps > result.adverse_trough_mbps + 0.05;
    }
    result
}

/// How a phase announces itself in the trace.
fn phase_name(arm: &Arm, phase: usize) -> String {
    match phase {
        1 => {
            format!(
                "ADVERSE (3% loss{}{})",
                if arm.congest_rtt_in_adverse {
                    " + RTT inflation"
                } else {
                    " at FLAT RTT = weather"
                },
                if arm.jitter { " + jitter" } else { "" },
            )
        },
        0 => "CLEAN".to_owned(),
        _ => "CLEAN recovery".to_owned(),
    }
}
