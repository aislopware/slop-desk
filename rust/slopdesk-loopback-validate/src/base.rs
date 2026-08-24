//! The base scenarios: one closed pass of the loop per loss model, and the LTR hardware probe.
//!
//! Each of these proves the SOFTWARE loop end to end — synthetic frame, real hardware encode, real
//! packetizer, deterministic loss, real fragment codec, real reassembler with FEC, real hardware
//! decode. Nothing here is simulated except the loss, and the loss is index-based rather than
//! random so a run is a repeat of the last one.

use slopdesk_ffi::decoder::DecodeOutcome;
use slopdesk_video::adaptive_fec;
use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::loopback::{LossModel, ScenarioStats, tier_description};
use slopdesk_video::ltr::{LtrController, RecoveryRequestKind};
use slopdesk_video::packetizer::PacketizeOptions;

use crate::rig::{Decoder, Encoder, Source};
use crate::wire::{GROUP, Wire};

/// Everything one base scenario varies.
#[derive(Clone, Copy, Debug)]
pub struct Arm {
    /// How many frames to push through.
    pub frames: usize,
    /// The FEC tier every frame is packetized at.
    pub tier: u8,
    /// Which fragments the wire eats.
    pub loss: LossModel,
    /// Whether the source and the decoder negotiate full-range luma.
    pub full_range: bool,
    /// Whether transmission is reordered column-major across FEC groups.
    pub interleave: bool,
    /// Parity shards per group: one is the XOR-equivalent codec, more is Reed-Solomon depth.
    pub parity: usize,
}

impl Default for Arm {
    fn default() -> Self {
        Self {
            frames: 120,
            tier: 0,
            loss: LossModel::None,
            full_range: false,
            interleave: false,
            parity: 1,
        }
    }
}

/// One closed pass of the loop.
///
/// A frame the encoder could not fit under the hard rate cap produces no output and is counted as
/// nothing — never a crash, which is the same reading the host takes.
#[must_use]
pub fn run(name: &str, arm: Arm) -> ScenarioStats {
    let mut stats = ScenarioStats::named(name);
    let Ok(encoder) = Encoder::create(arm.full_range, false, DEFAULT_BITRATE) else {
        println!("  [{name}] ENCODER CREATE FAILED");
        return stats;
    };
    let Ok(source) = Source::create(arm.full_range) else {
        println!("  [{name}] pixel-buffer create failed");
        return stats;
    };
    let decoder = Decoder::create(arm.full_range);
    let mut wire = Wire::new(arm.parity);
    let tier_group = adaptive_fec::group_size(arm.tier, GROUP).unwrap_or(0);
    let mut recovery_pending = false;

    for index in 0..arm.frames {
        source.paint(index, false);
        let force = index == 0 || recovery_pending;
        recovery_pending = false;
        encoder.encode_live(&source, index, force);
        // Force the asynchronous output callbacks to fire, then read what they left.
        encoder.complete_frames();

        for emitted in encoder.drain() {
            stats.encoded = stats.encoded.saturating_add(1);
            let fragments = wire.packetize(&emitted.avcc, PacketizeOptions {
                keyframe: emitted.keyframe,
                crisp: false,
                host_send_ts_millis: 0,
                fec_tier: arm.tier,
                is_ltr: false,
                acked_anchored: false,
                interleave: arm.interleave,
            });
            let sent = wire.transmit(&fragments, arm.loss, tier_group, &mut stats);
            if sent.dropped > 0 {
                recovery_pending = true;
            }
            for frame in sent.completed {
                match decoder.decode(&frame.avcc, frame.keyframe) {
                    DecodeOutcome::Delivered | DecodeOutcome::Dropped => {},
                    // A delta referencing a lost frame, or an FEC mis-recovery — count, re-anchor.
                    DecodeOutcome::NeedsKeyframe | DecodeOutcome::Failed(_) => {
                        stats.decode_failures = stats.decode_failures.saturating_add(1);
                        recovery_pending = true;
                    },
                }
            }
            if wire.drain_dropped(&mut stats) > 0 {
                recovery_pending = true;
            }
        }
    }

    encoder.complete_frames();
    stats.decoded = decoder.decoded();
    report(&stats);
    stats
}

/// One scenario's line, in the shape the Swift printed it.
fn report(stats: &ScenarioStats) {
    println!("  [done] {}", stats.name);
    println!(
        "         enc={} fragSent={} fragDrop={} reasm={} fecRecov={} framesDrop={} decodeOK={} \
         decodeFail={}",
        stats.encoded,
        stats.fragments_sent,
        stats.fragments_dropped,
        stats.reassembled,
        stats.fec_recovered,
        stats.frames_dropped,
        stats.decoded,
        stats.decode_failures,
    );
}

/// The LTR hardware probe: seed, record, ack, refresh, decode.
///
/// The ACKED-ONLY gate is the thing under test. Before any ack a refresh request must answer
/// `Idr`; after one it may answer `LtrRefresh`; and either way the refresh must produce a frame the
/// decoder accepts, because `VideoToolbox`'s own contract falls back to an IDR when no long-term
/// reference has been acknowledged.
#[must_use]
pub fn run_ltr_hardware(frames: usize) -> ScenarioStats {
    let mut stats = ScenarioStats::named("6. LTR HW (record/ack/refresh)");
    let Ok(encoder) = Encoder::create(false, true, DEFAULT_BITRATE) else {
        println!("  LTR encoder create FAILED");
        return stats;
    };
    let Ok(source) = Source::create(false) else {
        return stats;
    };
    let decoder = Decoder::create(false);
    let mut wire = Wire::new(1);
    let mut controller = LtrController::new();
    let mut ltr_frames_seen = 0_u64;
    let mut last_acked: Option<i64> = None;

    println!(
        "  recoveryDecision(.ltrRefresh) BEFORE any ack: {:?}",
        controller.recovery_decision(RecoveryRequestKind::LtrRefresh, true)
    );

    source.paint(0, false);
    encoder.encode_live(&source, 0, true);
    encoder.complete_frames();
    process(
        &encoder,
        &decoder,
        &mut wire,
        &mut controller,
        &mut stats,
        &mut ltr_frames_seen,
        &mut last_acked,
    );

    if ltr_frames_seen > 0 {
        println!(
            "  LTR token observed on keyframe: YES (token={})",
            last_acked.map_or_else(|| "nil".to_owned(), |token| token.to_string())
        );
    } else {
        println!(
            "  LTR token observed on keyframe: no — this HW encoder did not attach \
             RequireLTRAcknowledgementToken (VT will fall back to IDR on a refresh; still decodable)"
        );
    }
    println!(
        "  hasAckedToken after keyframe decode+ack: {}",
        controller.has_acked_token()
    );
    println!(
        "  recoveryDecision(.ltrRefresh) AFTER ack: {:?}",
        controller.recovery_decision(RecoveryRequestKind::LtrRefresh, true)
    );

    // A few normal live deltas to build stream depth.
    let deltas = frames.saturating_sub(2).max(2);
    for index in 1..deltas {
        source.paint(index, false);
        encoder.encode_live(&source, index, false);
        encoder.complete_frames();
        process(
            &encoder,
            &decoder,
            &mut wire,
            &mut controller,
            &mut stats,
            &mut ltr_frames_seen,
            &mut last_acked,
        );
    }

    // The refresh: a P-frame against the acked long-term reference if one exists, else an IDR.
    // Either way it must produce a decodable frame.
    let before = decoder.decoded();
    let last = frames.saturating_sub(1);
    source.paint(last, false);
    encoder.encode_ltr_refresh(&source, last);
    encoder.complete_frames();
    process(
        &encoder,
        &decoder,
        &mut wire,
        &mut controller,
        &mut stats,
        &mut ltr_frames_seen,
        &mut last_acked,
    );
    println!(
        "  encodeLiveLTRRefresh produced a decodable frame: {}",
        if decoder.decoded() > before { "YES" } else { "NO" }
    );

    encoder.complete_frames();
    stats.decoded = decoder.decoded();
    println!("  [done] {}", stats.name);
    println!(
        "         enc={} fragSent={} reasm={} decodeOK={} decodeFail={} ltrFrames={ltr_frames_seen}",
        stats.encoded, stats.fragments_sent, stats.reassembled, stats.decoded, stats.decode_failures,
    );
    stats
}

/// Drains one encode's output through the wire, recording and acking long-term references.
///
/// The ack is fed back only on a SUCCESSFUL decode, which is what the client's own rule is: a token
/// enters the acknowledged set exclusively because the frame carrying it decoded.
fn process(
    encoder: &Encoder,
    decoder: &Decoder,
    wire: &mut Wire,
    controller: &mut LtrController,
    stats: &mut ScenarioStats,
    ltr_frames_seen: &mut u64,
    last_acked: &mut Option<i64>,
) {
    for emitted in encoder.drain() {
        stats.encoded = stats.encoded.saturating_add(1);
        let frame_id = wire.peek_frame_id();
        let is_ltr = emitted.ltr.is_some();
        if let Some(token) = emitted.ltr {
            *ltr_frames_seen = ltr_frames_seen.saturating_add(1);
            controller.record_ltr_frame(frame_id, token);
        }
        let fragments = wire.packetize(&emitted.avcc, PacketizeOptions {
            keyframe: emitted.keyframe,
            crisp: false,
            host_send_ts_millis: 0,
            fec_tier: 0,
            is_ltr,
            acked_anchored: false,
            interleave: false,
        });
        for frame in wire.transmit(&fragments, LossModel::None, GROUP, stats).completed {
            match decoder.decode(&frame.avcc, frame.keyframe) {
                DecodeOutcome::Delivered | DecodeOutcome::Dropped => {
                    if frame.is_ltr
                        && let Some(token) = controller.ack_frame(frame.frame_id)
                    {
                        *last_acked = Some(token);
                        // The next encode drains it as `AcknowledgedLTRTokens`.
                        encoder.stage_acked_token(token);
                    }
                },
                DecodeOutcome::NeedsKeyframe | DecodeOutcome::Failed(_) => {
                    stats.decode_failures = stats.decode_failures.saturating_add(1);
                },
            }
        }
        wire.discard_dropped();
    }
}

/// The FEC tier sweep: one arm per tier, each dropping one data fragment per group.
///
/// OFF must NOT recover — there is no parity to recover from — and every other tier must, which is
/// the whole ladder's contract in one pass.
#[must_use]
pub fn tier_sweep(frames: usize) -> Vec<ScenarioStats> {
    [1_u8, 2, 3, 4, 0]
        .into_iter()
        .map(|tier| {
            // No per-arm banner: the sweep printed one, and each arm's own `[done]` line names the
            // tier it ran — a second header per tier would be the same string twice.
            let name = format!("FEC tier {tier} ({}) 1-hole/grp", tier_description(tier));
            run(&name, Arm {
                frames,
                tier,
                loss: LossModel::FirstPerGroup(1),
                ..Arm::default()
            })
        })
        .collect()
}

/// The summary table, in the columns the Swift printed.
pub fn print_summary(all: &[ScenarioStats]) {
    println!("\n========================== SUMMARY ==========================");
    println!(
        "{:<34}{:>5}{:>8}{:>7}{:>7}{:>6}{:>6}{:>7}{:>7}",
        "scenario", "enc", "fragS", "fragD", "reasm", "fecR", "drop", "decOK", "decErr",
    );
    for stats in all {
        println!(
            "{:<34}{:>5}{:>8}{:>7}{:>7}{:>6}{:>6}{:>7}{:>7}",
            stats.name,
            stats.encoded,
            stats.fragments_sent,
            stats.fragments_dropped,
            stats.reassembled,
            stats.fec_recovered,
            stats.frames_dropped,
            stats.decoded,
            stats.decode_failures,
        );
    }
    println!("============================================================");
}
