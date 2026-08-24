//! The ACK-REFERENCED encoding probe: the Parsec model on this machine's real hardware.
//!
//! Every delta encoded with `ForceLTRRefresh` references only long-term frames the CLIENT has
//! acknowledged, so a lost frame cannot break the chain — no recovery round trip, no freeze. Three
//! things have to be true before that is shippable, and none of them can be read out of
//! documentation:
//!
//! 1. does this encoder accept a per-frame refresh and attach a token EVERY frame?
//! 2. what does referencing an RTT-old reference cost in bytes, at 2 and at 6 frames of lag?
//! 3. does the picture actually survive whole-frame loss with the recovery path switched OFF, where
//!    the plain previous-frame chain provably breaks?
//!
//! The fifteen arms answer those, plus the one that decides it: low-motion content, where a genuine
//! P-frame collapses to a few kilobytes and a secretly-intra stream does not.

use std::collections::BTreeSet;

use slopdesk_ffi::decoder::DecodeOutcome;
use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::loopback::{LossModel, ScenarioStats};
use slopdesk_video::ltr::LtrController;
use slopdesk_video::packetizer::PacketizeOptions;

use crate::rig::{Decoder, Encoder, Source};
use crate::wire::{GROUP, Wire};

/// Everything one arm varies.
#[derive(Clone, Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each flag is one independent knob of the arm matrix, and folding them into enums would name \
              combinations that do not exist"
)]
pub struct ArmSpec {
    /// The label the arm prints under.
    pub name: &'static str,
    /// How many frames to push through.
    pub frames: usize,
    /// Whether the arm encodes ack-referenced at all.
    pub ack_ref: bool,
    /// How many frames a decoded long-term reference takes to be acknowledged back at the host.
    pub ack_lag_frames: usize,
    /// Whole-frame wire loss: positive drops one frame per N, negative drops `|n|` consecutive
    /// frames once per 24, zero drops none.
    pub drop_every_n: i32,
    /// Whether a decode failure forces an IDR re-anchor, as production does.
    pub recover_on_fail: bool,
    /// Whether to withhold every acknowledgement, which is the encoder's documented IDR fallback.
    pub never_ack: bool,
    /// Whether to print each of the first frames and every refresh.
    pub verbose: bool,
    /// Whether the content is the frozen-background desktop shape.
    pub low_motion: bool,
    /// Zero refreshes every frame; N refreshes every Nth.
    pub refresh_every: usize,
    /// Exact frame indices the wire eats, which overrides `drop_every_n` when non-empty.
    pub drop_frames: BTreeSet<usize>,
}

impl ArmSpec {
    /// The plain previous-frame chain on a clean link — the shape everything else is measured
    /// against.
    #[must_use]
    pub const fn baseline(name: &'static str, frames: usize) -> Self {
        Self {
            name,
            frames,
            ack_ref: false,
            ack_lag_frames: 0,
            drop_every_n: 0,
            recover_on_fail: true,
            never_ack: false,
            verbose: false,
            low_motion: false,
            refresh_every: 0,
            drop_frames: BTreeSet::new(),
        }
    }

    /// The ack-referenced chain at a given acknowledgement lag.
    #[must_use]
    pub fn ack_ref(name: &'static str, frames: usize, ack_lag_frames: usize) -> Self {
        Self {
            ack_ref: true,
            ack_lag_frames,
            ..Self::baseline(name, frames)
        }
    }
}

/// What one arm measured.
#[derive(Clone, Copy, Debug, Default)]
pub struct ArmResult {
    /// Frames the encoder emitted.
    pub encoded: usize,
    /// Of those, how many it marked intra.
    pub keyframes: usize,
    /// How many carried a long-term-reference token.
    pub ltr_token_frames: usize,
    /// Bytes across every non-intra frame.
    pub delta_bytes_total: usize,
    /// How many of those there were.
    pub delta_count: usize,
    /// Bytes across every intra frame.
    pub kf_bytes_total: usize,
    /// Decodes the client accepted.
    pub decode_ok: usize,
    /// Decodes it refused.
    pub decode_fail: usize,
    /// Forced re-anchors this arm paid for.
    pub recovery_idrs: usize,
    /// Whole frames the wire ate.
    pub frames_dropped_on_wire: usize,
    /// The picture check's average mean-absolute-difference against the analytic source.
    pub avg_mad: f64,
    /// Its worst.
    pub max_mad: f64,
    /// Its worst within three frames of a loss.
    pub post_drop_max_mad: f64,
    /// Bytes across every sparse refresh frame.
    pub refresh_bytes_total: usize,
    /// How many of those there were.
    pub refresh_count: usize,
}

impl ArmResult {
    /// Mean bytes per sparse refresh frame.
    #[must_use]
    pub const fn avg_refresh_bytes(&self) -> usize {
        match self.refresh_bytes_total.checked_div(self.refresh_count) {
            Some(mean) => mean,
            None => 0,
        }
    }

    /// Mean bytes across ALL frames.
    ///
    /// The honest cross-arm comparator: the intra/delta split rests on the encoder's own `NotSync`
    /// attachment, which mislabels an LTR-refresh P-frame as a keyframe, so a per-class average
    /// would compare two different populations.
    #[must_use]
    pub const fn avg_frame_bytes(&self) -> usize {
        match (self.delta_bytes_total + self.kf_bytes_total).checked_div(self.encoded) {
            Some(mean) => mean,
            None => 0,
        }
    }
}

/// Whether the wire eats frame `index` under this arm's loss shape.
fn drops_frame(spec: &ArmSpec, index: usize) -> bool {
    if !spec.drop_frames.is_empty() {
        return spec.drop_frames.contains(&index);
    }
    if spec.drop_every_n < 0 {
        // BURST: `|n|` consecutive frames die together once per 24, so two adjacent long-term
        // references are lost in one go — the worst case for any newest-reference policy.
        let burst = usize::try_from(-spec.drop_every_n).unwrap_or(0);
        return index > 0 && (index % 24) >= 12 && (index % 24) < 12 + burst;
    }
    let Ok(every) = usize::try_from(spec.drop_every_n) else {
        return false;
    };
    // A mid-cycle frame, so the seed keyframe is never the one that dies.
    every > 0 && index > 0 && index % every == every / 2
}

/// One acknowledgement the simulated round trip has not yet delivered.
#[derive(Clone, Copy, Debug)]
struct PendingAck {
    /// The frame index at which the ack becomes visible to the host.
    due_at: usize,
    /// The frame it acknowledges.
    frame_id: u32,
}

/// One arm of the ack-ref experiment.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "one arm is one loop: the ack feedback, the loss shape and the picture check are the same pass"
)]
pub fn run_arm(spec: &ArmSpec) -> ArmResult {
    let mut result = ArmResult::default();
    let Ok(encoder) = Encoder::create(false, spec.ack_ref, DEFAULT_BITRATE) else {
        println!("  [{}] ENCODER CREATE FAILED", spec.name);
        return result;
    };
    let Ok(source) = Source::create(false) else {
        return result;
    };
    let decoder = Decoder::create(false);
    decoder.measure_against(spec.low_motion);
    let mut wire = Wire::new(1);
    let mut controller = LtrController::new();
    let mut stats = ScenarioStats::named(spec.name);

    let mut pending: Vec<PendingAck> = Vec::new();
    let mut recovery_pending = false;
    // NOT the minimum: `index - last_drop` would underflow at the start of the run.
    let mut last_drop: i64 = -1_000_000;

    for index in 0..spec.frames {
        // Acks whose simulated round trip elapsed land BEFORE this encode, the way an arriving
        // datagram does.
        if spec.ack_ref && !spec.never_ack {
            pending.retain(|ack| {
                if ack.due_at > index {
                    return true;
                }
                if let Some(token) = controller.ack_frame(ack.frame_id) {
                    encoder.stage_acked_token(token);
                }
                false
            });
        }

        source.paint(index, spec.low_motion);
        let force = index == 0 || recovery_pending;
        recovery_pending = false;
        if force && index > 0 {
            result.recovery_idrs = result.recovery_idrs.saturating_add(1);
        }
        let is_refresh = spec.ack_ref
            && !force
            && (spec.refresh_every == 0 || index > 0 && index % spec.refresh_every == 0);
        if is_refresh {
            encoder.encode_ltr_refresh(&source, index);
        } else {
            encoder.encode_live(&source, index, force);
        }
        encoder.complete_frames();

        let dropped = drops_frame(spec, index);
        if dropped {
            result.frames_dropped_on_wire = result.frames_dropped_on_wire.saturating_add(1);
            last_drop = i64::try_from(index).unwrap_or(i64::MAX);
        }

        for emitted in encoder.drain() {
            result.encoded = result.encoded.saturating_add(1);
            if emitted.keyframe {
                result.keyframes = result.keyframes.saturating_add(1);
                result.kf_bytes_total = result.kf_bytes_total.saturating_add(emitted.avcc.len());
            } else {
                result.delta_bytes_total = result.delta_bytes_total.saturating_add(emitted.avcc.len());
                result.delta_count = result.delta_count.saturating_add(1);
            }
            if is_refresh && spec.refresh_every > 0 {
                result.refresh_bytes_total = result.refresh_bytes_total.saturating_add(emitted.avcc.len());
                result.refresh_count = result.refresh_count.saturating_add(1);
                if spec.verbose {
                    println!(
                        "    refresh@{index} kf={} ltrTok={} bytes={}",
                        emitted.keyframe,
                        token_text(emitted.ltr),
                        emitted.avcc.len(),
                    );
                }
            }
            if spec.verbose && result.encoded <= 12 {
                println!(
                    "    f#{} kf={} ltrTok={} bytes={}",
                    result.encoded - 1,
                    emitted.keyframe,
                    token_text(emitted.ltr),
                    emitted.avcc.len(),
                );
            }
            let frame_id = wire.peek_frame_id();
            let is_ltr = emitted.ltr.is_some();
            if let Some(token) = emitted.ltr {
                result.ltr_token_frames = result.ltr_token_frames.saturating_add(1);
                controller.record_ltr_frame(frame_id, token);
            }
            // The frame is packetized even when it dies on the wire, so the frame-id sequence and
            // the host stamp advance exactly as they would have.
            let fragments = wire.packetize(&emitted.avcc, PacketizeOptions {
                keyframe: emitted.keyframe,
                is_ltr,
                ..PacketizeOptions::default()
            });
            if dropped {
                continue;
            }
            let recent = i64::try_from(index).unwrap_or(i64::MAX) - last_drop <= 3;
            decoder.expect(index, recent);
            for frame in wire
                .transmit(&fragments, LossModel::None, GROUP, &mut stats)
                .completed
            {
                match decoder.decode(&frame.avcc, frame.keyframe) {
                    DecodeOutcome::Delivered | DecodeOutcome::Dropped => {
                        result.decode_ok = result.decode_ok.saturating_add(1);
                        if spec.ack_ref && !spec.never_ack && frame.is_ltr {
                            pending.push(PendingAck {
                                due_at: index.saturating_add(spec.ack_lag_frames.max(1)),
                                frame_id: frame.frame_id,
                            });
                        }
                    },
                    DecodeOutcome::NeedsKeyframe | DecodeOutcome::Failed(_) => {
                        result.decode_fail = result.decode_fail.saturating_add(1);
                        if spec.recover_on_fail {
                            recovery_pending = true;
                        }
                    },
                }
            }
        }
        // Whole-frame loss is deliberate here, so the reassembler's own bookkeeping is drained
        // rather than counted.
        wire.discard_dropped();
    }

    encoder.complete_frames();
    let (average, worst, post_drop) = decoder.picture();
    result.avg_mad = average;
    result.max_mad = worst;
    result.post_drop_max_mad = post_drop;
    println!(
        "  [{}] enc={} kf={} ltrTok={} avgALL={}B framesLost={} decodeOK={} decodeFail={} recoveryIDRs={} \
         MAD avg={average:.1} max={worst:.1} postDrop={post_drop:.1}",
        spec.name,
        result.encoded,
        result.keyframes,
        result.ltr_token_frames,
        result.avg_frame_bytes(),
        result.frames_dropped_on_wire,
        result.decode_ok,
        result.decode_fail,
        result.recovery_idrs,
    );
    result
}

/// How a token prints when the encoder attached one, and when it did not.
fn token_text(token: Option<i64>) -> String {
    token.map_or_else(|| "-".to_owned(), |value| value.to_string())
}

/// The relative byte overhead of `a` against `b`, as the probe prints it.
fn pct(a: usize, b: usize) -> String {
    if b == 0 {
        return "n/a".to_owned();
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "a frame's byte count is far inside f64's exact integer range"
    )]
    let ratio = a as f64 / b as f64;
    format!("{:+.1}%", (ratio - 1.0) * 100.0)
}

/// A ratio that answers zero rather than a non-finite when the denominator is empty.
#[expect(
    clippy::cast_precision_loss,
    reason = "a frame's byte count is far inside f64's exact integer range"
)]
fn ratio(a: usize, b: usize) -> f64 {
    if b == 0 { 0.0 } else { a as f64 / b as f64 }
}

/// A verdict's mark.
const fn mark(ok: bool) -> &'static str {
    if ok { "✅" } else { "❌" }
}

/// The fifteen-arm experiment and its verdicts.
#[expect(
    clippy::too_many_lines,
    reason = "fifteen arms and their verdicts; every line is one measured claim about this hardware"
)]
pub fn run_probe(frames: usize) {
    println!(
        "=== ACK-REF probe :: per-frame ForceLTRRefresh (Parsec ack-referenced encoding) on REAL HW ==="
    );
    println!(
        "    {frames} frames/arm, whole-frame wire loss 1/13 (~7.7%), ack lag in FRAMES (60fps ⇒ 2≈33ms \
         RTT, 6≈100ms)\n"
    );

    let base = run_arm(&ArmSpec::baseline("A base P-chain    clean          ", frames));
    let base_loss = run_arm(&ArmSpec {
        drop_every_n: 13,
        ..ArmSpec::baseline("B base P-chain    drop1/13 +rec  ", frames)
    });
    let ack_clean = run_arm(&ArmSpec {
        verbose: true,
        ..ArmSpec::ack_ref("C ack-ref lag2    clean          ", frames, 2)
    });
    let ack_loss = run_arm(&ArmSpec {
        drop_every_n: 13,
        recover_on_fail: false,
        ..ArmSpec::ack_ref("D ack-ref lag2    drop1/13 NOrec ", frames, 2)
    });
    let ack_lag6 = run_arm(&ArmSpec::ack_ref("E ack-ref lag6    clean          ", frames, 6));
    // ADVERSARIAL: drop only TOKEN frames — `i % 16 == 8` is always even, the observed token
    // cadence. An encoder that references the previous long-term frame unconditionally must
    // corrupt its dependents; one that honours acks reaches back to an older acked reference.
    let ack_token_loss = run_arm(&ArmSpec {
        drop_every_n: 16,
        recover_on_fail: false,
        ..ArmSpec::ack_ref("F ack-ref lag2    dropTOKEN NOrec", frames, 2)
    });
    // NO acks ever: the documented contract says a refresh without an acknowledged reference falls
    // back to an IDR. Byte sizes against C and E distinguish ack-driven from ack-ignored.
    let ack_never = run_arm(&ArmSpec {
        drop_every_n: 13,
        recover_on_fail: false,
        never_ack: true,
        ..ArmSpec::ack_ref("G ack-ref NO-acks drop1/13 NOrec ", frames, 2)
    });
    // BURST: four consecutive whole frames die every 24, so at least two token frames are lost
    // together. Staying pixel-clean here covers the real path's measured burst shape.
    let ack_burst = run_arm(&ArmSpec {
        drop_every_n: -4,
        recover_on_fail: false,
        ..ArmSpec::ack_ref("H ack-ref lag2    BURST4/24 NOrec", frames, 2)
    });
    // The healing HORIZON: eight consecutive lost frames, a 133 ms outage.
    let ack_burst8 = run_arm(&ArmSpec {
        drop_every_n: -8,
        recover_on_fail: false,
        ..ArmSpec::ack_ref("I ack-ref lag2    BURST8/24 NOrec", frames, 2)
    });
    // THE INTRA-DETECTOR: low-motion content is the real desktop shape. A P delta collapses to a
    // few kilobytes; a secretly-intra stream stays large, and per-frame refresh is not shippable.
    let base_low = run_arm(&ArmSpec {
        low_motion: true,
        ..ArmSpec::baseline("J base P-chain    LOW-MOTION clean", frames)
    });
    let ack_low = run_arm(&ArmSpec {
        low_motion: true,
        ..ArmSpec::ack_ref("K ack-ref lag2    LOW-MOTION clean", frames, 2)
    });
    // SPARSE refresh: a normal chain with one refresh every 30 frames.
    let sparse = run_arm(&ArmSpec {
        verbose: true,
        low_motion: true,
        refresh_every: 30,
        ..ArmSpec::ack_ref("L sparse-refresh  LOW-MOTION clean", frames, 2)
    });
    // WHICH reference does the sparse refresh reach for? Frames 25-29 die and are never acked, and
    // the refresh fires at 30. Acked-reference semantics reach back to 24 and stay clean.
    let anchored = run_arm(&ArmSpec {
        recover_on_fail: false,
        low_motion: true,
        refresh_every: 30,
        drop_frames: (25..=29).collect(),
        ..ArmSpec::ack_ref("M sparse+burst25-29 acked  NOrec  ", frames, 2)
    });
    let anchored_no_ack = run_arm(&ArmSpec {
        recover_on_fail: false,
        never_ack: true,
        low_motion: true,
        refresh_every: 30,
        drop_frames: (25..=29).collect(),
        ..ArmSpec::ack_ref("N sparse+burst25-29 NOack  NOrec  ", frames, 2)
    });
    // Refresh COST on real motion, at the 100 ms self-heal cadence.
    let sparse_cost = run_arm(&ArmSpec {
        refresh_every: 6,
        ..ArmSpec::ack_ref("O sparse6 MOTION  clean (cost)    ", frames, 2)
    });

    let coverage = ratio(ack_clean.ltr_token_frames, ack_clean.encoded);
    // The clean arm's own worst is the codec's noise floor; a post-loss picture within ~1.5× of it
    // is as healthy as a picture that never saw a loss.
    let ceiling = 3.0_f64.max(ack_clean.max_mad * 1.5);
    let d_survives =
        ack_loss.decode_fail == 0 && ack_loss.recovery_idrs == 0 && ack_loss.post_drop_max_mad <= ceiling;
    let f_survives = ack_token_loss.decode_fail == 0
        && ack_token_loss.recovery_idrs == 0
        && ack_token_loss.post_drop_max_mad <= ceiling;
    let baseline_breaks = base_loss.decode_fail > 0 || base_loss.recovery_idrs > 0;

    println!();
    println!(
        "  token cadence (LTR frames/encoded)      : {}/{} = {:.0}%",
        ack_clean.ltr_token_frames,
        ack_clean.encoded,
        coverage * 100.0,
    );
    println!(
        "  byte overhead vs baseline  lag2 / lag6  : {} / {} (base {}B)",
        pct(ack_clean.avg_frame_bytes(), base.avg_frame_bytes()),
        pct(ack_lag6.avg_frame_bytes(), base.avg_frame_bytes()),
        base.avg_frame_bytes(),
    );
    println!(
        "  acks ignored by encoder?                : lag2={}B lag6={}B noAck={}B (identical ⇒ \
         AcknowledgedLTRTokens has no effect)",
        ack_clean.avg_frame_bytes(),
        ack_lag6.avg_frame_bytes(),
        ack_never.avg_frame_bytes(),
    );
    println!(
        "  VERDICT survive 7.7% mixed frame loss, ZERO recovery : {} (decodeFail={} recIDR={} \
         postDropMAD={:.1} vs clean {:.1})",
        mark(d_survives),
        ack_loss.decode_fail,
        ack_loss.recovery_idrs,
        ack_loss.post_drop_max_mad,
        ack_clean.max_mad,
    );
    println!(
        "  VERDICT survive TOKEN-frame loss, ZERO recovery      : {} (decodeFail={} recIDR={} \
         postDropMAD={:.1})",
        mark(f_survives),
        ack_token_loss.decode_fail,
        ack_token_loss.recovery_idrs,
        ack_token_loss.post_drop_max_mad,
    );
    let h_survives =
        ack_burst.decode_fail == 0 && ack_burst.recovery_idrs == 0 && ack_burst.post_drop_max_mad <= ceiling;
    println!(
        "  VERDICT survive BURST-4 frame loss, ZERO recovery    : {} (decodeFail={} recIDR={} \
         postDropMAD={:.1})",
        mark(h_survives),
        ack_burst.decode_fail,
        ack_burst.recovery_idrs,
        ack_burst.post_drop_max_mad,
    );
    let i_survives = ack_burst8.decode_fail == 0
        && ack_burst8.recovery_idrs == 0
        && ack_burst8.post_drop_max_mad <= ceiling;
    println!(
        "  horizon  survive BURST-8 frame loss, ZERO recovery   : {} (decodeFail={} postDropMAD={:.1})",
        if i_survives {
            "✅"
        } else {
            "❌ (past horizon — client recovery backstop applies)"
        },
        ack_burst8.decode_fail,
        ack_burst8.post_drop_max_mad,
    );
    println!(
        "  VERDICT no-acks arm under loss (VT contract check)   : decodeFail={} postDropMAD={:.1} kf={}",
        ack_never.decode_fail, ack_never.post_drop_max_mad, ack_never.keyframes,
    );
    println!(
        "  baseline P-chain breaks under same loss (contrast)   : {} (decodeFail={} recIDR={} \
         postDropMAD={:.1})",
        if baseline_breaks {
            "✅ breaks as expected"
        } else {
            "⚠️ did not break"
        },
        base_loss.decode_fail,
        base_loss.recovery_idrs,
        base_loss.post_drop_max_mad,
    );
    let intra_ratio = ratio(ack_low.avg_frame_bytes(), base_low.avg_frame_bytes());
    println!(
        "  INTRA-DETECTOR low-motion bytes base→ackRef          : {}B → {}B ({intra_ratio:.1}×) {}",
        base_low.avg_frame_bytes(),
        ack_low.avg_frame_bytes(),
        if intra_ratio > 3.0 {
            "❌ ack-ref frames are SECRETLY INTRA — per-frame refresh NOT shippable"
        } else {
            "✅ genuine P-frames — shippable"
        },
    );
    let sparse_is_p =
        sparse.avg_refresh_bytes() > 0 && sparse.avg_refresh_bytes() < base_low.avg_frame_bytes() * 8;
    println!(
        "  SPARSE refresh frame size (every 30, low-motion)     : {}B vs P-delta {}B vs intra ~{}B → {}",
        sparse.avg_refresh_bytes(),
        base_low.avg_frame_bytes(),
        ack_low.avg_frame_bytes(),
        if sparse_is_p {
            "✅ GENUINE LTR-P (WF-8 recovery is a real P-frame)"
        } else {
            "❌ intra-sized (VT LTR refresh = coarse intra, no real long-term P reference)"
        },
    );
    // Only the refresh at 30 and what follows it matter: frames 25-29 were never delivered, so a
    // clean post-burst picture with no failures after 30 means the refresh anchored on an acked
    // reference rather than a dead one.
    let healed = anchored.post_drop_max_mad <= ceiling && anchored.post_drop_max_mad > 0.0;
    println!(
        "  VERDICT refresh anchors to ACKED LTR (burst-kill 25-29): {} (decodeFail={} postDropMAD={:.1} \
         kf={})",
        if healed {
            "✅ healed at refresh@30 with zero recovery"
        } else {
            "❌ refresh referenced a dead frame"
        },
        anchored.decode_fail,
        anchored.post_drop_max_mad,
        anchored.keyframes,
    );
    println!(
        "  VERDICT no-ack refresh falls back to IDR (VT contract) : kf={} decodeFail={} postDropMAD={:.1} \
         refreshAvg={}B",
        anchored_no_ack.keyframes,
        anchored_no_ack.decode_fail,
        anchored_no_ack.post_drop_max_mad,
        anchored_no_ack.avg_refresh_bytes(),
    );
    let cost_ratio = ratio(sparse_cost.avg_refresh_bytes(), base.avg_frame_bytes());
    println!(
        "  refresh COST on motion (every 6, vs 1-back delta)      : {}B vs {}B ({cost_ratio:.2}× per \
         refresh ⇒ +{:.1}% stream at K=6)",
        sparse_cost.avg_refresh_bytes(),
        base.avg_frame_bytes(),
        (cost_ratio - 1.0).max(0.0) / 6.0 * 100.0,
    );
}
