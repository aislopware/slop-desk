//! The DELAY-TARGETING bottleneck-queue scenario: a real feedback loop, not a scripted phase.
//!
//! The link is a fluid bottleneck of capacity C with a FIFO queue. The queue grows when the
//! encoder's actual bytes exceed C and drains otherwise, and the round trip the controller sees IS
//! `base + queue/C`. That is the measured inter-ISP path shape — 11 ms idle, 80-110 ms during a
//! scroll, at zero loss: pure bufferbloat, nothing for a loss-keyed controller to see.
//!
//! An open-loop rate policy lets that queue stand for seconds. A delay-targeting one must converge
//! the rate under C quickly, end with a near-drained queue, and not pump back above C over and over
//! — which is what the knee memory is for.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::packetizer::PacketizeOptions;

use crate::link::{
    Client, Delivered, Host, PacerTelemetry, ceiling_bps, frame_interval_ms, ingest, intra_gap_ms, mbps,
    round_trip,
};
use crate::rig::{Decoder, Encoder, Source};
use crate::wire::Wire;

/// What the run measured.
#[derive(Clone, Copy, Debug)]
pub(crate) struct BottleneckResult {
    /// The first virtual time the actuated rate reached capacity or below.
    pub converged_at_ms: Option<f64>,
    /// The mean standing queue over the last quarter of the run.
    pub tail_avg_queue_ms: f64,
    /// Its worst over the same window.
    pub tail_max_queue_ms: f64,
    /// Post-convergence climbs back above capacity × 1.35 — the pumping count.
    pub rebash_count: usize,
    /// The rate the run ended at.
    pub end_actuated_mbps: f64,
    /// The capacity the arm ran against.
    pub capacity_mbps: f64,
}

impl Default for BottleneckResult {
    fn default() -> Self {
        Self {
            converged_at_ms: None,
            tail_avg_queue_ms: 0.0,
            tail_max_queue_ms: 0.0,
            rebash_count: 0,
            end_actuated_mbps: 0.0,
            capacity_mbps: 0.0,
        }
    }
}

/// One sample of the loop's state, taken at each report.
#[derive(Clone, Copy, Debug)]
struct Sample {
    /// The virtual clock.
    ms: f64,
    /// The standing queue, in milliseconds of drain time.
    queue: f64,
    /// The rate the encoder is running at.
    actuated: i64,
}

/// Drives the bottleneck.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "the queue, the delay it produces and the controller's answer to it are one feedback loop"
)]
pub(crate) fn run(frames: usize, verbose: bool) -> BottleneckResult {
    let mut result = BottleneckResult::default();
    let ceiling = ceiling_bps();
    // Between the controller's own floor fraction and the ceiling, so convergence is reachable.
    #[expect(
        clippy::integer_division,
        reason = "a share of a bitrate in bits per second; the remainder is under one bit"
    )]
    let capacity = ceiling * 55 / 100;
    result.capacity_mbps = mbps(capacity);

    let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
        println!("  bottleneck encoder create FAILED");
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

    let base_one_way_ms = 5.0;
    let mut clock_ms = 0.0_f64;
    let mut queue_ms = 0.0_f64;
    let mut frames_out = 0_usize;
    let mut samples: Vec<Sample> = Vec::new();

    for index in 0..frames {
        source.paint(index, false);
        clock_ms += frame_interval_ms();
        // The bottleneck drains continuously, one frame interval per frame tick.
        queue_ms = (queue_ms - frame_interval_ms()).max(0.0);
        encoder.encode_live(&source, index, index == 0);
        encoder.complete_frames();

        for emitted in encoder.drain() {
            frames_out = frames_out.saturating_add(1);
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
            // FEEDBACK: this frame's wire bytes join the queue, so its own delivery waits behind
            // them. That is the whole scenario — the delay the controller measures is caused by the
            // rate the controller chose.
            let wire_bytes: usize = fragments.iter().map(|fragment| fragment.encode().len()).sum();
            #[expect(
                clippy::cast_precision_loss,
                reason = "a frame's wire size and a link capacity are far inside f64's exact integer range"
            )]
            let drain_ms = (wire_bytes * 8) as f64 / capacity as f64 * 1000.0;
            queue_ms += drain_ms;
            let one_way = base_one_way_ms + queue_ms;
            let arrival_base = clock_ms + one_way;
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

            if !frames_out.is_multiple_of(3) {
                continue;
            }
            let report = client.report(clock_ms + one_way, false, PacerTelemetry::default());
            let Some(received) = round_trip(report) else {
                continue;
            };
            // The return path rides the un-queued direction: the queue this scenario builds is the
            // host→client one, and a report is a few dozen bytes.
            host.fold(&received, clock_ms + one_way + base_one_way_ms, false);
            let target = host.tick();
            if host.actuate(target) {
                encoder.set_live_bitrate(host.actuated);
            }
            samples.push(Sample {
                ms: clock_ms,
                queue: queue_ms,
                actuated: host.actuated,
            });
            if result.converged_at_ms.is_none() && host.actuated <= capacity {
                result.converged_at_ms = Some(clock_ms);
            }
            if verbose && frames_out.is_multiple_of(30) {
                println!(
                    "    t={clock_ms:5.0}ms  queue={queue_ms:5.1}ms  smoothedRTT={:5.1}ms  rate={:4.1}Mbps  \
                     knee={}",
                    host.estimate.smoothed_rtt_millis,
                    mbps(host.actuated),
                    host.controller
                        .knee_bps()
                        .map_or_else(|| "-".to_owned(), |knee| format!("{:.1}M", mbps(knee))),
                );
            }
        }
    }

    #[expect(clippy::integer_division, reason = "the floor is the bound being computed")]
    let tail_start = samples.len().saturating_sub((samples.len() / 4).max(1));
    let tail = samples.get(tail_start..).unwrap_or_default();
    if !tail.is_empty() {
        #[expect(
            clippy::cast_precision_loss,
            reason = "a sample count inside one run is a small integer, exact in f64"
        )]
        let count = tail.len() as f64;
        result.tail_avg_queue_ms = tail.iter().map(|sample| sample.queue).sum::<f64>() / count;
        result.tail_max_queue_ms = tail.iter().fold(0.0_f64, |worst, sample| worst.max(sample.queue));
    }
    if let Some(converged) = result.converged_at_ms {
        // A re-bash is a post-convergence crossing from at-or-under the pumping boundary to above
        // it — the transition, not the level, because a rate that simply stayed high is one event.
        #[expect(
            clippy::integer_division,
            reason = "a share of a bitrate in bits per second; the remainder is under one bit"
        )]
        let boundary = capacity * 135 / 100;
        result.rebash_count = samples
            .iter()
            .zip(samples.iter().skip(1))
            .filter(|(before, after)| {
                before.ms >= converged && before.actuated <= boundary && after.actuated > boundary
            })
            .count();
    }
    result.end_actuated_mbps = mbps(host.actuated);
    result
}
