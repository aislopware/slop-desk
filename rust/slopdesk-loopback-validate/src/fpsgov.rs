//! The FPS-GOVERNOR scenarios: the cliff, where frame rate itself must give, and the weather
//! control, where it must not.
//!
//! The cliff is the loop a scripted phase cannot express: the offered load exceeds anything the
//! rate controller can actuate — 2.5 Mbps of link under uncompressible noise, past the coarsening
//! floor where the encoder simply cannot squeeze further — so the only remaining variable is how
//! many frames are offered. It runs the REAL hardware encoder with a live expected-frame-rate
//! property set on every step, through the packetizer, a fluid bottleneck queue tail-clamped at
//! ~400 ms of bufferbloat, the real reassembler and decoder, the real stats wire, the estimate, the
//! controller, and finally the governor — with the REAL cadence gate admitting deliveries at the
//! governed rate. That is exactly the host's own wiring.
//!
//! The weather arm is the control: 3% per-fragment loss at a FLAT round trip, the measured
//! inter-ISP shape. Loss alone trips the governor's congestion arm, but the stream FITS the
//! actuated rate, so the over-budget half of the step-down gate never fires. Frame rate is never
//! sacrificed to weather.

use slopdesk_video::congestion::CongestionConfig;
use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::fps_governor::{EncodeCadenceGate, FpsGovernor, FpsGovernorConfig, congestion_evidence};
use slopdesk_video::packetizer::PacketizeOptions;

use crate::link::{
    Client, Delivered, Host, PacerTelemetry, ceiling_bps, drain_lost, frame_interval_ms, ingest,
    intra_gap_ms, mbps, round_trip,
};
use crate::rig::{Decoder, Encoder, FPS, Source};
use crate::wire::Wire;

/// The cadence tolerance the host passes: half a 120 Hz capture slot.
const HALF_SLOT_MS: f64 = 0.5 / 120.0 * 1000.0;

/// What the cliff measured.
#[derive(Clone, Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each is one independently-measured verdict bit; collapsing them would lose which one failed"
)]
pub struct CliffResult {
    /// Governed rates stepped TO during the cliff, in order.
    pub cliff_steps_in_order: Vec<i64>,
    /// Whether every consecutive rung pair was about a step-down hold window apart.
    pub cliff_spacing_ok: bool,
    /// The closest two rungs came, in virtual milliseconds.
    pub min_cliff_spacing_ms: f64,
    /// Whether the rate never moved during the ample warm-up phase.
    pub held_base_in_phase1: bool,
    /// Whether the controller actually collapsed below its ceiling during the cliff — the
    /// governor's evidence.
    pub abr_collapsed_in_cliff: bool,
    /// Whether every plateau's admission schedule stayed metronome-regular.
    ///
    /// Inside every plateau of a second or more, the worst inter-ADMIT deviation from the governed
    /// interval must stay under half a capture slot — the property an alternating skip pattern
    /// violates by construction. The same bound is applied to ENCODER-OUTPUT times in the final,
    /// non-starved plateau. Output gaps inside the cliff are deliberately NOT asserted: noise at
    /// the rate floor is many times past the encoder's entropy floor, where it silently drops
    /// frames — which is the very thing the governor exists to relieve.
    pub cadence_regular: bool,
    /// The worst admission-schedule deviation, across all plateaus.
    pub worst_cadence_err_ms: f64,
    /// The worst encoder-output deviation in the final plateau.
    pub worst_fit_encode_err_ms: f64,
    /// The worst encoder-output deviation anywhere — informational, not asserted.
    pub worst_encode_gap_ms: f64,
    /// The rate at the end of the restore phase.
    pub end_fps: i64,
    /// How far apart the restore climbs were.
    pub step_up_spacings_ms: Vec<f64>,
}

impl Default for CliffResult {
    fn default() -> Self {
        Self {
            cliff_steps_in_order: Vec::new(),
            cliff_spacing_ok: true,
            min_cliff_spacing_ms: f64::INFINITY,
            held_base_in_phase1: true,
            abr_collapsed_in_cliff: false,
            cadence_regular: true,
            worst_cadence_err_ms: 0.0,
            worst_fit_encode_err_ms: 0.0,
            worst_encode_gap_ms: 0.0,
            end_fps: FPS,
            step_up_spacings_ms: Vec::new(),
        }
    }
}

/// One governed-rate plateau boundary.
#[derive(Clone, Copy, Debug)]
struct Change {
    /// When the rate changed.
    ms: f64,
    /// What it changed to.
    fps: i64,
}

/// Drives the cliff.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "three phases of one feedback loop; the phase boundaries ARE the scenario"
)]
pub fn run_cliff(verbose: bool) -> CliffResult {
    let mut result = CliffResult::default();
    let ceiling = ceiling_bps();

    let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
        println!("  fps-gov encoder create FAILED");
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
    let mut governor = FpsGovernor::new(FPS, FpsGovernorConfig::default());
    let mut gate = EncodeCadenceGate::new();
    let mut governed_fps = FPS;

    let slot_ms = frame_interval_ms();
    let base_one_way_ms = 5.0;
    let mut clock_ms = 0.0_f64;
    let mut queue_bytes = 0.0_f64;
    let mut global_index = 0_usize;
    let mut delivered_since_report = 0_usize;
    let mut admit_times: Vec<f64> = Vec::new();
    let mut encode_times: Vec<f64> = Vec::new();
    let mut changes: Vec<Change> = vec![Change { ms: 0.0, fps: FPS }];
    let mut cliff_step_times: Vec<f64> = Vec::new();

    // Two seconds ample, six seconds of cliff, fourteen seconds of restore — at 60 deliveries per
    // second. The content is chosen per phase so each assertion is reachable on real rate control:
    // structured content fits any budget, noise fits none, and low-motion restores.
    let phase_frames = [120_usize, 360, 840];
    let capacities = [ceiling * 2, 2_500_000, ceiling * 2];

    for phase in 0..3_usize {
        let capacity = capacities[phase];
        if verbose {
            println!(
                "    ── phase {}  capacity={:.1}Mbps  {} ──",
                phase + 1,
                mbps(capacity),
                match phase {
                    0 => "structured (hold 60)",
                    1 => "NOISE cliff (ladder down)",
                    _ => "low-motion restore (climb)",
                },
            );
        }
        for _ in 0..phase_frames[phase] {
            clock_ms += slot_ms;
            #[expect(
                clippy::cast_precision_loss,
                reason = "a link capacity in bits per second is far inside f64's exact integer range"
            )]
            let drained = capacity as f64 / 8.0 * slot_ms / 1000.0;
            queue_bytes = (queue_bytes - drained).max(0.0);
            match phase {
                0 => source.paint(global_index, false),
                1 => source.paint_noise(global_index),
                _ => source.paint(global_index, true),
            }

            // The REAL cadence gate, at the exact host wiring: consulted only when governed below
            // base, and the first frame is forced.
            let forced = global_index == 0;
            let admitted = if governed_fps < FPS {
                #[expect(
                    clippy::cast_precision_loss,
                    reason = "a governed frame rate is a small integer, exact in f64"
                )]
                let interval = 1.0 / governed_fps as f64;
                gate.admit(clock_ms / 1000.0, interval, 0.5 / 120.0, forced)
            } else {
                true
            };
            global_index = global_index.saturating_add(1);

            if admitted {
                admit_times.push(clock_ms);
                encoder.encode_live(&source, global_index, forced);
                encoder.complete_frames();
                for emitted in encoder.drain() {
                    encode_times.push(clock_ms);
                    governor.note_encoded_frame(
                        i64::try_from(emitted.avcc.len()).unwrap_or(i64::MAX),
                        emitted.keyframe,
                    );
                    #[expect(
                        clippy::cast_possible_truncation,
                        clippy::cast_sign_loss,
                        reason = "a virtual clock bounded by the scenario's own length is far inside u32"
                    )]
                    let send_ts = clock_ms as u32;
                    let fragments = wire.packetize_stamped(&emitted.avcc, PacketizeOptions {
                        keyframe: emitted.keyframe,
                        host_send_ts_millis: send_ts,
                        ..PacketizeOptions::default()
                    });
                    let wire_bytes: usize = fragments.iter().map(|fragment| fragment.encode().len()).sum();
                    #[expect(
                        clippy::cast_precision_loss,
                        reason = "a frame's wire size is far inside f64's exact integer range"
                    )]
                    let added = wire_bytes as f64;
                    queue_bytes += added;
                    // Bufferbloat tail-clamp at ~400 ms of the live capacity. Real paths bound
                    // their standing queue; without it the cliff banks a multi-second backlog that
                    // dominates the restore phase. Clamped bytes are NOT fed back as loss — the
                    // cliff's congestion signal is delay, which is the measured scroll shape.
                    #[expect(
                        clippy::cast_precision_loss,
                        reason = "a link capacity in bits per second is far inside f64's exact integer range"
                    )]
                    let cap_bytes = capacity as f64 / 8.0 * 0.4;
                    queue_bytes = queue_bytes.min(cap_bytes);
                    #[expect(
                        clippy::cast_precision_loss,
                        reason = "a link capacity in bits per second is far inside f64's exact integer range"
                    )]
                    let queue_ms = queue_bytes * 8.0 / capacity as f64 * 1000.0;
                    let arrival_base = clock_ms + base_one_way_ms + queue_ms;
                    let gap = intra_gap_ms(fragments.len());
                    for (local, fragment) in fragments.iter().enumerate() {
                        #[expect(
                            clippy::cast_precision_loss,
                            reason = "a fragment index inside one frame is a small integer, exact in f64"
                        )]
                        let arrival_ms = arrival_base + local as f64 * gap;
                        if let Delivered::Frame(frame) =
                            ingest(&mut wire.reassembler, &mut client, fragment, arrival_ms, false)
                        {
                            decoder.decode(&frame.avcc, frame.keyframe);
                        }
                    }
                }
            }

            // The client reports on the 50 ms DELIVERY clock. The real client's report timer is
            // frame-rate-INDEPENDENT, so the governor keeps its tick rate even at a governed 15.
            delivered_since_report = delivered_since_report.saturating_add(1);
            if delivered_since_report != 3 {
                continue;
            }
            delivered_since_report = 0;
            #[expect(
                clippy::cast_precision_loss,
                reason = "a link capacity in bits per second is far inside f64's exact integer range"
            )]
            let queue_ms = queue_bytes * 8.0 / capacity as f64 * 1000.0;
            let now_client_ms = clock_ms + base_one_way_ms + queue_ms;
            let report = client.report(now_client_ms, false, PacerTelemetry::default());
            let Some(received) = round_trip(report) else {
                continue;
            };
            host.fold(&received, now_client_ms + base_one_way_ms, false);
            let target = host.tick();
            if host.actuate(target) {
                encoder.set_live_bitrate(host.actuated);
            }
            if phase == 1 && host.controller.current() < host.controller.ceiling() {
                result.abr_collapsed_in_cliff = true;
            }
            let congested = congestion_evidence(
                &CongestionConfig::default(),
                host.estimate.last_loss_sample,
                host.estimate.smoothed_rtt_millis,
                host.estimate.min_rtt_millis,
                Some(host.controller.current()),
                Some(host.controller.ceiling()),
            );
            let new_fps = governor.on_tick(host.actuated, congested);
            if new_fps == governed_fps {
                continue;
            }
            if verbose {
                #[expect(
                    clippy::cast_precision_loss,
                    reason = "a governed frame rate is a small integer, exact in f64"
                )]
                let offered = governor.bytes_per_frame_avg() * 8.0 * governed_fps as f64 / 1_000_000.0;
                println!(
                    "    t={clock_ms:5.0}ms  fps {governed_fps} → {new_fps}  (offered≈{offered:.1}Mbps \
                     target={:.1}Mbps congested={} rtt={:.0}ms)",
                    mbps(host.actuated),
                    if congested { "Y" } else { "n" },
                    host.estimate.smoothed_rtt_millis,
                );
            }
            if phase == 0 {
                result.held_base_in_phase1 = false;
            }
            if phase == 1 && new_fps < governed_fps {
                result.cliff_steps_in_order.push(new_fps);
                cliff_step_times.push(clock_ms);
            }
            if phase == 2
                && new_fps > governed_fps
                && let Some(last) = changes.last()
            {
                result.step_up_spacings_ms.push(clock_ms - last.ms);
            }
            changes.push(Change {
                ms: clock_ms,
                fps: new_fps,
            });
            governed_fps = new_fps;
            encoder.set_expected_frame_rate(new_fps);
        }
    }
    result.end_fps = governed_fps;

    // One rung per step-down hold window — eight ticks of 50 ms — with 350 ms allowing a single
    // report of phase alignment.
    for pair in cliff_step_times.windows(2) {
        let spacing = pair[1] - pair[0];
        result.min_cliff_spacing_ms = result.min_cliff_spacing_ms.min(spacing);
        if spacing < 350.0 {
            result.cliff_spacing_ok = false;
        }
    }

    changes.push(Change {
        ms: clock_ms + slot_ms,
        fps: governed_fps,
    });
    let final_index = changes.len().saturating_sub(2);
    for (index, pair) in changes.windows(2).enumerate() {
        let (segment, next) = (pair[0], pair[1]);
        if next.ms - segment.ms < 1000.0 {
            continue;
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "a governed frame rate is a small integer, exact in f64"
        )]
        let expected = 1000.0 / segment.fps.max(1) as f64;
        // Skip the first 200 ms of each plateau: the gate re-anchors there, and the transition
        // frame itself belongs to neither side.
        let admits = within(&admit_times, segment.ms + 200.0, next.ms);
        for gap in admits.windows(2) {
            let error = ((gap[1] - gap[0]) - expected).abs();
            result.worst_cadence_err_ms = result.worst_cadence_err_ms.max(error);
            if error > HALF_SLOT_MS {
                result.cadence_regular = false;
            }
        }
        let outputs = within(&encode_times, segment.ms + 200.0, next.ms);
        for gap in outputs.windows(2) {
            let error = ((gap[1] - gap[0]) - expected).abs();
            result.worst_encode_gap_ms = result.worst_encode_gap_ms.max(error);
            if index == final_index {
                result.worst_fit_encode_err_ms = result.worst_fit_encode_err_ms.max(error);
                if error > HALF_SLOT_MS {
                    result.cadence_regular = false;
                }
            }
        }
    }
    result
}

/// The stamps strictly after `from` and at or before `to`.
fn within(times: &[f64], from: f64, to: f64) -> Vec<f64> {
    times
        .iter()
        .copied()
        .filter(|stamp| *stamp > from && *stamp <= to)
        .collect()
}

/// What the weather arm measured.
#[derive(Clone, Copy, Debug)]
pub struct WeatherResult {
    /// The lowest governed rate reached.
    pub min_fps: i64,
    /// Whether the governor's congestion arm ever saw the loss.
    pub saw_loss_evidence: bool,
    /// Whether the actuated rate stayed at the ceiling throughout.
    pub bitrate_held: bool,
}

impl Default for WeatherResult {
    fn default() -> Self {
        Self {
            min_fps: FPS,
            saw_loss_evidence: false,
            bitrate_held: true,
        }
    }
}

/// Drives the weather control arm.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "the same one loop as the cliff, with the queue removed — splitting it would hide that"
)]
pub fn run_weather(frames: usize, verbose: bool) -> WeatherResult {
    let mut result = WeatherResult::default();
    let ceiling = ceiling_bps();

    let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
        println!("  fps-gov weather encoder create FAILED");
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
    let mut governor = FpsGovernor::new(FPS, FpsGovernorConfig::default());

    let base_one_way_ms = 5.0;
    let mut clock_ms = 0.0_f64;
    let mut global_fragment = 0_usize;
    let mut recovery_pending = false;
    let mut frames_out = 0_usize;

    for index in 0..frames {
        source.paint(index, false);
        clock_ms += frame_interval_ms();
        let force = index == 0 || recovery_pending;
        recovery_pending = false;
        encoder.encode_live(&source, index, force);
        encoder.complete_frames();

        for emitted in encoder.drain() {
            frames_out = frames_out.saturating_add(1);
            governor.note_encoded_frame(
                i64::try_from(emitted.avcc.len()).unwrap_or(i64::MAX),
                emitted.keyframe,
            );
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "a virtual clock bounded by the scenario's own length is far inside u32"
            )]
            let send_ts = clock_ms as u32;
            let fragments = wire.packetize_stamped(&emitted.avcc, PacketizeOptions {
                keyframe: emitted.keyframe,
                host_send_ts_millis: send_ts,
                ..PacketizeOptions::default()
            });
            // FLAT round trip — this is weather, and weather has no queue.
            let arrival_base = clock_ms + base_one_way_ms;
            let gap = intra_gap_ms(fragments.len());
            for (local, fragment) in fragments.iter().enumerate() {
                global_fragment = global_fragment.saturating_add(1);
                #[expect(
                    clippy::cast_precision_loss,
                    reason = "a fragment index inside one frame is a small integer, exact in f64"
                )]
                let arrival_ms = arrival_base + local as f64 * gap;
                if (global_fragment * 7 + 3) % 100 < 3 {
                    continue;
                }
                match ingest(&mut wire.reassembler, &mut client, fragment, arrival_ms, false) {
                    Delivered::Frame(frame) => {
                        decoder.decode(&frame.avcc, frame.keyframe);
                    },
                    Delivered::Lost => recovery_pending = true,
                    Delivered::Pending => {},
                }
                if drain_lost(&mut wire.reassembler, &mut client) > 0 {
                    recovery_pending = true;
                }
            }

            if !frames_out.is_multiple_of(3) {
                continue;
            }
            let report = client.report(clock_ms + base_one_way_ms, false, PacerTelemetry::default());
            let Some(received) = round_trip(report) else {
                continue;
            };
            host.fold(&received, clock_ms + base_one_way_ms * 2.0, false);
            let target = host.tick();
            if host.actuate(target) {
                encoder.set_live_bitrate(host.actuated);
            }
            if host.actuated < host.controller.ceiling() {
                result.bitrate_held = false;
            }
            let congested = congestion_evidence(
                &CongestionConfig::default(),
                host.estimate.last_loss_sample,
                host.estimate.smoothed_rtt_millis,
                host.estimate.min_rtt_millis,
                Some(host.controller.current()),
                Some(host.controller.ceiling()),
            );
            if congested {
                result.saw_loss_evidence = true;
            }
            let governed = governor.on_tick(host.actuated, congested);
            result.min_fps = result.min_fps.min(governed);
            if verbose && frames_out.is_multiple_of(30) {
                println!(
                    "    f{index:<3} loss={:.3} congested={} fps={governed} rate={:.1}Mbps",
                    host.estimate.last_loss_sample,
                    if congested { "Y" } else { "n" },
                    mbps(host.actuated),
                );
            }
        }
    }
    result
}
