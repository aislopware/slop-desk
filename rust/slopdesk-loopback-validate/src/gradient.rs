//! The DELAY-GRADIENT onset scenario: a delay SLOPE that precedes the level, by design.
//!
//! The same fluid bottleneck the queue scenario runs, with a hard capacity STEP — ample for two
//! seconds of warm-up (controller warmup, minimum-round-trip baseline, and a full trendline
//! window), then 40% of the ceiling for a second and a half, then ample again. That is the measured
//! "scroll demand exceeds path capacity" onset.
//!
//! The client side runs the PRODUCTION sampling: one sample per strictly-newer frame admitted by
//! [`TrendSampler`] into a trendline estimator whose verdict rides the REAL stats wire into the
//! host's estimate and its controller. The A/B is the controller's own instance-level knob, so both
//! arms run in one process with no environment games.
//!
//! The false-positive guard is the other half. Flat capacity plus an alternating ±4 ms arrival
//! wobble is an ~8 ms saw with zero net ramp — the rate-independent path texture that any
//! fixed-threshold delay design misreads as congestion. The armed controller must record ZERO cuts.

use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::packetizer::PacketizeOptions;

use crate::link::{
    Client, Delivered, Host, PacerTelemetry, ceiling_bps, frame_interval_ms, ingest, intra_gap_ms, mbps,
    round_trip,
};
use crate::rig::{Decoder, Encoder, Source};
use crate::wire::Wire;

/// Frames of ample capacity before the step.
const WARM_FRAMES: usize = 120;
/// Frames of squeezed capacity.
const SQUEEZE_FRAMES: usize = 90;
/// Frames of ample capacity after it.
const RESTORE_FRAMES: usize = 60;

/// One cut the controller made.
#[derive(Clone, Copy, Debug)]
pub struct Cut {
    /// Which report it was.
    pub report: usize,
    /// The virtual clock at that report.
    pub ms: f64,
}

/// One arm's trace.
#[derive(Clone, Debug, Default)]
pub struct ArmTrace {
    /// Virtual milliseconds from the capacity step to the first cut, or none if it never cut.
    pub onset_to_first_cut_ms: Option<f64>,
    /// Every cut over the whole run.
    pub cuts: Vec<Cut>,
    /// The virtual clock at the capacity step.
    pub onset_clock_ms: f64,
    /// Whether the estimate read OVERUSING on the report that produced the first post-onset cut.
    pub trend_overusing_at_first_cut: bool,
    /// The squeezed capacity, in megabits per second.
    pub capacity_mbps: f64,
}

/// What the A/B measured.
#[derive(Clone, Debug, Default)]
pub struct GradientResult {
    /// The squeezed capacity, in megabits per second.
    pub capacity_mbps: f64,
    /// Onset to first cut with the gradient disarmed.
    pub off_onset_to_first_cut_ms: Option<f64>,
    /// Onset to first cut with it armed.
    pub on_onset_to_first_cut_ms: Option<f64>,
    /// The armed arm's cuts within a second of onset, as report ticks from the first of them.
    pub on_cut_ticks_from_onset: Vec<usize>,
    /// The closest two consecutive armed cuts came, in report ticks.
    pub on_min_cut_spacing_ticks: Option<usize>,
    /// Whether the estimate read OVERUSING at the armed arm's first cut.
    pub on_trend_overusing_at_first_cut: bool,
    /// Cuts during the clean wobble sub-run with the gradient armed. Must be zero.
    pub clean_wobble_cuts: usize,
}

/// One arm of the A/B.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "the capacity step, the queue it builds and the controller's answer are one feedback loop"
)]
pub fn run_arm(gradient_enabled: bool, verbose: bool) -> ArmTrace {
    let mut trace = ArmTrace::default();
    let ceiling = ceiling_bps();
    let ample = ceiling * 10;
    let squeeze = ceiling * 40 / 100;
    trace.capacity_mbps = mbps(squeeze);

    let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
        println!("  gradient-onset encoder create FAILED");
        return trace;
    };
    let Ok(source) = Source::create(false) else {
        return trace;
    };
    encoder.set_live_bitrate(ceiling);
    let decoder = Decoder::create(false);
    let mut wire = Wire::new(1);
    let mut client = Client::new();
    let mut host = Host::new(ceiling, gradient_enabled);

    let base_one_way_ms = 5.0;
    let mut clock_ms = 0.0_f64;
    let mut queue_ms = 0.0_f64;
    let mut frames_out = 0_usize;
    let mut report_index = 0_usize;

    for index in 0..WARM_FRAMES + SQUEEZE_FRAMES + RESTORE_FRAMES {
        let squeezing = (WARM_FRAMES..WARM_FRAMES + SQUEEZE_FRAMES).contains(&index);
        let capacity = if squeezing { squeeze } else { ample };
        source.paint(index, false);
        clock_ms += frame_interval_ms();
        if index == WARM_FRAMES {
            trace.onset_clock_ms = clock_ms;
        }
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
                    ingest(&mut wire.reassembler, &mut client, fragment, arrival_ms, true)
                {
                    decoder.decode(&frame.avcc, frame.keyframe);
                }
            }

            if !frames_out.is_multiple_of(3) {
                continue;
            }
            let report = client.report(clock_ms + one_way, true, PacerTelemetry::default());
            let Some(received) = round_trip(report) else {
                continue;
            };
            host.fold(&received, clock_ms + one_way + base_one_way_ms, true);
            let before = host.controller.current();
            let target = host.tick();
            report_index = report_index.saturating_add(1);
            if target < before {
                trace.cuts.push(Cut {
                    report: report_index,
                    ms: clock_ms,
                });
                if trace.onset_to_first_cut_ms.is_none()
                    && clock_ms >= trace.onset_clock_ms
                    && trace.onset_clock_ms > 0.0
                {
                    trace.onset_to_first_cut_ms = Some(clock_ms - trace.onset_clock_ms);
                    trace.trend_overusing_at_first_cut = host.estimate.owd_trend_overusing;
                }
            }
            if host.actuate(target) {
                encoder.set_live_bitrate(host.actuated);
            }
            if verbose && frames_out.is_multiple_of(30) {
                println!(
                    "    [{}] t={clock_ms:5.0}ms  queue={queue_ms:5.1}ms  smoothedRTT={:5.1}ms  \
                     rate={:4.1}Mbps  trend={}",
                    if gradient_enabled { "ON " } else { "OFF" },
                    host.estimate.smoothed_rtt_millis,
                    mbps(host.controller.current()),
                    if host.estimate.owd_trend_overusing {
                        "OVERUSE"
                    } else {
                        "-"
                    },
                );
            }
        }
    }
    trace
}

/// The false-positive guard: flat ample capacity and an alternating ±4 ms arrival wobble.
///
/// The wobble lives in the ARRIVAL model, not the content — mostly-static content re-painted every
/// fourth frame keeps a ten-second-equivalent arm cheap, and the texture under test is the path's,
/// not the picture's.
#[must_use]
pub fn run_wobble(frames: usize, verbose: bool) -> usize {
    let ceiling = ceiling_bps();
    let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
        println!("  gradient-wobble encoder create FAILED");
        return 0;
    };
    let Ok(source) = Source::create(false) else {
        return 0;
    };
    encoder.set_live_bitrate(ceiling);
    let decoder = Decoder::create(false);
    let mut wire = Wire::new(1);
    let mut client = Client::new();
    let mut host = Host::new(ceiling, true);

    let base_one_way_ms = 5.0;
    let mut clock_ms = 0.0_f64;
    let mut frames_out = 0_usize;
    let mut cuts = 0_usize;

    for index in 0..frames {
        if index % 4 == 0 {
            source.paint(index, false);
        }
        clock_ms += frame_interval_ms();
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
            // The saw runs on the ENCODE counter, not the frame counter: it is the arrival of a
            // datagram that wobbles, and a frame the encoder skipped never produced one.
            let wobble = if frames_out.is_multiple_of(2) { 4.0 } else { -4.0 };
            let arrival_base = clock_ms + base_one_way_ms + wobble;
            let gap = intra_gap_ms(fragments.len());

            for (local, fragment) in fragments.iter().enumerate() {
                #[expect(
                    clippy::cast_precision_loss,
                    reason = "a fragment index inside one frame is a small integer, exact in f64"
                )]
                let arrival_ms = arrival_base + local as f64 * gap;
                if let Delivered::Frame(frame) =
                    ingest(&mut wire.reassembler, &mut client, fragment, arrival_ms, true)
                {
                    decoder.decode(&frame.avcc, frame.keyframe);
                }
            }

            if !frames_out.is_multiple_of(3) {
                continue;
            }
            let report = client.report(
                clock_ms + base_one_way_ms + wobble,
                true,
                PacerTelemetry::default(),
            );
            let Some(received) = round_trip(report) else {
                continue;
            };
            host.fold(
                &received,
                clock_ms + base_one_way_ms + wobble + base_one_way_ms,
                true,
            );
            let before = host.controller.current();
            if host.tick() < before {
                cuts = cuts.saturating_add(1);
            }
        }
    }
    if verbose {
        println!(
            "    wobble arm: {frames_out} frames, cuts={cuts}, end rate={:.1}Mbps",
            mbps(host.controller.current()),
        );
    }
    cuts
}

/// The A/B plus the guard.
#[must_use]
pub fn run(verbose: bool) -> GradientResult {
    let mut result = GradientResult::default();
    let off = run_arm(false, verbose);
    let on = run_arm(true, verbose);
    result.capacity_mbps = on.capacity_mbps;
    result.off_onset_to_first_cut_ms = off.onset_to_first_cut_ms;
    result.on_onset_to_first_cut_ms = on.onset_to_first_cut_ms;
    result.on_trend_overusing_at_first_cut = on.trend_overusing_at_first_cut;
    let onset_cuts: Vec<&Cut> = on
        .cuts
        .iter()
        .filter(|cut| cut.ms >= on.onset_clock_ms && cut.ms <= on.onset_clock_ms + 1000.0)
        .collect();
    if let Some(first) = onset_cuts.first() {
        result.on_cut_ticks_from_onset = onset_cuts
            .iter()
            .map(|cut| cut.report.saturating_sub(first.report))
            .collect();
    }
    result.on_min_cut_spacing_ticks = on
        .cuts
        .windows(2)
        .map(|pair| pair[1].report.saturating_sub(pair[0].report))
        .min();
    result.clean_wobble_cuts = run_wobble(600, verbose);
    result
}
