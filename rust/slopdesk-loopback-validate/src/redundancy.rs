//! The RECOVERY-REQUEST REDUNDANCY scenario.
//!
//! A recovery request is one small datagram on a lossy path, and losing it costs a whole escalation
//! interval of frozen picture. Three arms answer whether sending it three times, spaced, is worth
//! it: the freeze before and after redundancy, whether the host absorbs the copies into ONE action,
//! and whether the loss-adaptive escalation clock helps when every copy dies.
//!
//! The timing arms are a pure virtual clock over the real components. The straddle arm is not: it
//! drives a REAL encoder, because "one recovery encode" has to mean one encoded frame rather than
//! one increment of a counter.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use std::collections::BTreeSet;

use slopdesk_video::decode_admission::DecodeFrontier;
use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::ltr::{LtrController, RecoveryAction, RecoveryRequestKind};
use slopdesk_video::recovery::{
    LossObservationWindow, LtrEscalationTracker, RecoveryMessage, RecoveryPolicy, RecoveryRequestRedundancy,
};
use slopdesk_video::recovery_dedupe::RecoveryRequestDeduper;
use slopdesk_video::recovery_idr::{IdrVerdict, RecoveryIdrConfig, RecoveryIdrPolicy};
use slopdesk_video::recovery_routing::{RecoveryDecision, route_recovery};

use crate::link::frame_interval_ms;
use crate::rig::{Encoder, Source};

/// What one request-loss timing arm measured.
#[derive(Clone, Copy, Debug)]
pub(crate) struct LossArmResult {
    /// Virtual milliseconds from the loss to the recovery keyframe decoding at the client.
    pub freeze_ms: f64,
    /// Logical requests the client composed.
    pub logical_requests: usize,
    /// Datagrams those turned into.
    pub wire_copies: usize,
    /// Requests the host acted on.
    pub host_admitted: usize,
    /// Copies the host's deduper absorbed.
    pub host_duplicates_dropped: usize,
    /// Escalations the client's clock produced.
    pub escalations: usize,
}

impl Default for LossArmResult {
    fn default() -> Self {
        Self {
            freeze_ms: f64::INFINITY,
            logical_requests: 0,
            wire_copies: 0,
            host_admitted: 0,
            host_duplicates_dropped: 0,
            escalations: 0,
        }
    }
}

/// How one timing arm is configured.
#[derive(Clone, Debug)]
pub(crate) struct LossArm {
    /// Client redundancy. One is a single unprotected send.
    pub copies: usize,
    /// Which copy indices of the INITIAL request the wire eats.
    pub drop_initial_copies: BTreeSet<usize>,
    /// Whether the loss-adaptive halved escalation clock is armed.
    pub fast_escalation: bool,
    /// Parity-recovered early-warning events seeded into the loss window at t = 0.
    pub seed_loss_events: usize,
    /// The round trip the arm runs at.
    pub rtt: f64,
    /// Whether to print the arm's line.
    pub verbose: bool,
    /// The label it prints under.
    pub label: &'static str,
}

/// One datagram the wire is still carrying.
#[derive(Clone, Debug)]
struct InFlight {
    /// When it lands at the host.
    at: f64,
    /// The bytes.
    wire: Vec<u8>,
}

/// One request-loss recovery episode.
#[must_use]
#[expect(
    clippy::too_many_lines,
    reason = "one episode: the send plan, the host's absorption and the client's clock are one trace"
)]
pub(crate) fn run_loss_arm(arm: &LossArm) -> LossArmResult {
    let mut result = LossArmResult::default();
    let one_way = arm.rtt / 2.0;
    let frame_interval = frame_interval_ms() / 1000.0;

    // ── Client side ──
    let redundancy =
        RecoveryRequestRedundancy::new(arm.copies, RecoveryRequestRedundancy::default().spacing());
    let mut escalation = LtrEscalationTracker::new();
    let policy = RecoveryPolicy::default();
    let mut loss_window = LossObservationWindow::default();
    let mut frontier = DecodeFrontier::new();
    frontier.note_decoded(49);
    // ── Host side ──
    let mut deduper = RecoveryRequestDeduper::default();
    // Fresh, so a refresh request folds to a keyframe rather than a cheap re-anchor.
    let ltr = LtrController::new();
    let mut idr_policy = RecoveryIdrPolicy::new(RecoveryIdrConfig::default());
    let mut next_keyframe = 100_u32;

    let mut in_flight: Vec<InFlight> = Vec::new();
    let mut response_decode_at: Option<f64> = None;
    let offsets = redundancy.send_offsets();

    // Seed the early-warning events: the burst is already visible before the freeze.
    for _ in 0..arm.seed_loss_events {
        loss_window.note_event(0.0);
    }

    // t = 0: frame 50 is declared unrecoverable, so the client runs the real signal-recovery shape
    // — a loss event, a loss boundary, and the initial refresh request carrying its frontier.
    loss_window.note_event(0.0);
    escalation.note_loss(50);
    let initial = RecoveryPolicy::initial_request(50, 50, frontier.wire_value()).encode();
    send_logical(
        &mut result,
        &mut in_flight,
        &offsets,
        &initial,
        0.0,
        one_way,
        &arm.drop_initial_copies,
    );
    escalation.note_request_sent(0.0);

    // One-millisecond virtual ticks; the escalation is re-checked on the 5 ms drain-loop cadence.
    let mut now = 0.0_f64;
    #[expect(
        clippy::while_float,
        reason = "the arm's clock IS virtual seconds, and the loop is bounded by its own two-second cap"
    )]
    while now < 2.0 {
        now += 0.001;
        while in_flight.first().is_some_and(|next| next.at <= now) {
            let next = in_flight.remove(0);
            if let Some(decode_at) = host_receive(
                &mut result,
                &mut deduper,
                &ltr,
                &mut idr_policy,
                &mut next_keyframe,
                &next.wire,
                next.at,
                arm.rtt,
                frame_interval,
            ) {
                response_decode_at =
                    Some(response_decode_at.map_or(decode_at, |current: f64| current.min(decode_at)));
            }
        }
        if let Some(done) = response_decode_at
            && now >= done
        {
            result.freeze_ms = done * 1000.0;
            break;
        }
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "a virtual clock bounded by the arm's two-second cap is far inside u64"
        )]
        let tick = (now * 1000.0).round() as u64;
        if !tick.is_multiple_of(5) {
            continue;
        }
        let observing = arm.fast_escalation && loss_window.is_observing_loss(now);
        if !escalation.should_escalate(now, arm.rtt, &policy, observing) {
            continue;
        }
        result.escalations = result.escalations.saturating_add(1);
        let wire = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: frontier.wire_value(),
        }
        .encode();
        send_logical(
            &mut result,
            &mut in_flight,
            &offsets,
            &wire,
            now,
            one_way,
            &BTreeSet::new(),
        );
        escalation.note_request_sent(now);
        escalation.note_escalated(now);
    }
    if arm.verbose {
        println!(
            "    {} freeze={:.0}ms requests={} copies={} admitted={} dups-dropped={} escalations={}",
            arm.label,
            result.freeze_ms,
            result.logical_requests,
            result.wire_copies,
            result.host_admitted,
            result.host_duplicates_dropped,
            result.escalations,
        );
    }
    result
}

/// One logical client send: ONE encode, `copies` byte-identical datagrams at the redundancy
/// offsets.
fn send_logical(
    result: &mut LossArmResult,
    in_flight: &mut Vec<InFlight>,
    offsets: &[f64],
    wire: &[u8],
    at: f64,
    one_way: f64,
    drop: &BTreeSet<usize>,
) {
    result.logical_requests = result.logical_requests.saturating_add(1);
    for (index, offset) in offsets.iter().enumerate() {
        result.wire_copies = result.wire_copies.saturating_add(1);
        if drop.contains(&index) {
            continue;
        }
        in_flight.push(InFlight {
            at: at + offset + one_way,
            wire: wire.to_vec(),
        });
    }
    in_flight.sort_by(|a, b| a.at.total_cmp(&b.at));
}

/// The host's receive path: route, dedup, resolve the refresh, admit, then quantize to the next
/// capture boundary.
///
/// The capturer latch is MODELED as that boundary rounding — the real capturer needs a GUI session,
/// and what matters here is that a grant cannot be encoded before the next frame.
#[expect(
    clippy::too_many_arguments,
    reason = "every one is a distinct component the receive path threads through; a struct here would be \
              one field per argument"
)]
fn host_receive(
    result: &mut LossArmResult,
    deduper: &mut RecoveryRequestDeduper,
    ltr: &LtrController,
    idr_policy: &mut RecoveryIdrPolicy,
    next_keyframe: &mut u32,
    wire: &[u8],
    at: f64,
    rtt: f64,
    frame_interval: f64,
) -> Option<f64> {
    let last_decoded = match route_recovery(wire, true) {
        RecoveryDecision::ForceKeyframe {
            last_decoded_frame_id,
        } => {
            if !deduper.admit(wire, at) {
                result.host_duplicates_dropped = result.host_duplicates_dropped.saturating_add(1);
                return None;
            }
            result.host_admitted = result.host_admitted.saturating_add(1);
            last_decoded_frame_id
        },
        RecoveryDecision::RefreshLtr {
            last_decoded_frame_id,
        } => {
            if !deduper.admit(wire, at) {
                result.host_duplicates_dropped = result.host_duplicates_dropped.saturating_add(1);
                return None;
            }
            result.host_admitted = result.host_admitted.saturating_add(1);
            if ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true) != RecoveryAction::Idr {
                return None;
            }
            last_decoded_frame_id
        },
        _ => return None,
    };
    if idr_policy.decide(at, last_decoded, rtt) != IdrVerdict::Grant {
        return None;
    }
    let boundary = (at / frame_interval).ceil() * frame_interval;
    let sent_at = boundary + 0.010;
    idr_policy.note_keyframe_sent(*next_keyframe, sent_at);
    *next_keyframe = next_keyframe.wrapping_add(1);
    Some(sent_at + rtt / 2.0)
}

/// What one straddle arm measured.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct DedupArmResult {
    /// Refresh encodes issued on the REAL encoder — the latch-drain count.
    pub recovery_encodes: usize,
    /// Frames the encoder emitted.
    pub frames_emitted: usize,
    /// Requests the host acted on.
    pub admitted: usize,
    /// Copies the deduper absorbed.
    pub duplicates_dropped: usize,
}

/// The frame-boundary STRADDLE arm, on the real encoder.
///
/// One logical refresh request arrives as three byte-identical copies at 10, 15 and 20 ms, and the
/// 16.7 ms capture boundary falls BETWEEN the second and the third. The capturer latch dedups the
/// two copies inside one frame, but the post-boundary copy RE-LATCHES — and without the host's
/// deduper that encodes a SECOND refresh for one loss, because nothing else gates the refresh path.
#[must_use]
pub(crate) fn run_dedup_arm(dedup_on: bool, verbose: bool) -> DedupArmResult {
    let mut result = DedupArmResult::default();
    // A zero window is the kill switch: no request is ever a duplicate.
    let mut deduper = RecoveryRequestDeduper::new(
        if dedup_on { 0.020 } else { 0.0 },
        RecoveryRequestDeduper::DEFAULT_CAPACITY,
    );
    let mut ltr = LtrController::new();
    ltr.record_ltr_frame(0, 1);
    // An acked token, so a refresh resolves to the cheap re-anchor — the path with no cooldown.
    let _ = ltr.ack_frame(0);

    let Ok(encoder) = Encoder::create(false, true, DEFAULT_BITRATE) else {
        println!("  recovery-loss straddle encoder create FAILED");
        return result;
    };
    let Ok(source) = Source::create(false) else {
        return result;
    };

    let wire = RecoveryMessage::RequestLtrRefresh {
        from_frame_id: 50,
        to_frame_id: 50,
        last_decoded_frame_id: 49,
    }
    .encode();
    let arrivals = [0.010, 0.015, 0.020];
    let mut arrival_index = 0_usize;
    let mut pending_refresh = false;
    let frame_interval = frame_interval_ms() / 1000.0;

    for index in 0..6_usize {
        #[expect(
            clippy::cast_precision_loss,
            reason = "a frame index inside one arm is a small integer, exact in f64"
        )]
        let boundary = index as f64 * frame_interval;
        while let Some(&at) = arrivals.get(arrival_index)
            && at <= boundary
        {
            arrival_index = arrival_index.saturating_add(1);
            if !matches!(route_recovery(&wire, true), RecoveryDecision::RefreshLtr { .. }) {
                continue;
            }
            if !deduper.admit(&wire, at) {
                result.duplicates_dropped = result.duplicates_dropped.saturating_add(1);
                continue;
            }
            result.admitted = result.admitted.saturating_add(1);
            if ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true) == RecoveryAction::LtrRefresh {
                pending_refresh = true;
            }
        }
        // The boundary drains the latch exactly like the capturer: consume, reset, encode for real.
        let refresh = core::mem::take(&mut pending_refresh);
        source.paint(index, false);
        if index == 0 {
            encoder.encode_live(&source, index, true);
        } else if refresh {
            result.recovery_encodes = result.recovery_encodes.saturating_add(1);
            encoder.encode_ltr_refresh(&source, index);
        } else {
            encoder.encode_live(&source, index, false);
        }
        encoder.complete_frames();
        result.frames_emitted = result.frames_emitted.saturating_add(encoder.drain().len());
    }
    if verbose {
        println!(
            "    straddle dedup={}: recovery encodes={} admitted={} dups-dropped={} HW frames={}",
            if dedup_on { "ON " } else { "OFF" },
            result.recovery_encodes,
            result.admitted,
            result.duplicates_dropped,
            result.frames_emitted,
        );
    }
    result
}

/// What the whole component measured.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct RedundancyResult {
    /// One copy, and it is lost — what ships today.
    pub baseline: LossArmResult,
    /// Three copies, and the first is lost.
    pub redundant: LossArmResult,
    /// The straddle with the deduper on.
    pub dedup_on: DedupArmResult,
    /// Its control, with the deduper off.
    pub dedup_off: DedupArmResult,
    /// Every copy lost, on the halved clock.
    pub fast_on: LossArmResult,
    /// Its control, on the plain clock.
    pub fast_off: LossArmResult,
}

impl Default for LossArm {
    fn default() -> Self {
        Self {
            copies: 1,
            drop_initial_copies: BTreeSet::new(),
            fast_escalation: false,
            seed_loss_events: 0,
            // The estimate's own bootstrap, which is the freeze math's anchor.
            rtt: 0.05,
            verbose: false,
            label: "",
        }
    }
}

/// Drives every arm.
#[must_use]
pub(crate) fn run(verbose: bool) -> RedundancyResult {
    RedundancyResult {
        baseline: run_loss_arm(&LossArm {
            copies: 1,
            drop_initial_copies: BTreeSet::from([0]),
            verbose,
            label: "arm1 copies=1 req LOST (today) :",
            ..LossArm::default()
        }),
        redundant: run_loss_arm(&LossArm {
            copies: 3,
            drop_initial_copies: BTreeSet::from([0]),
            verbose,
            label: "arm2 copies=3 first copy lost :",
            ..LossArm::default()
        }),
        dedup_on: run_dedup_arm(true, verbose),
        dedup_off: run_dedup_arm(false, verbose),
        fast_on: run_loss_arm(&LossArm {
            copies: 3,
            drop_initial_copies: BTreeSet::from([0, 1, 2]),
            fast_escalation: true,
            seed_loss_events: 2,
            verbose,
            label: "arm4 ALL copies lost, fast ON  :",
            ..LossArm::default()
        }),
        fast_off: run_loss_arm(&LossArm {
            copies: 3,
            drop_initial_copies: BTreeSet::from([0, 1, 2]),
            seed_loss_events: 2,
            verbose,
            label: "arm4 ALL copies lost, fast OFF :",
            ..LossArm::default()
        }),
    }
}

/// The shared verdict line, printed by the suite and by the standalone flag alike.
pub(crate) fn print_verdict(result: &RedundancyResult) {
    let redundant = result.redundant.freeze_ms <= result.baseline.freeze_ms * 0.6
        && result.redundant.host_duplicates_dropped >= 1
        && result.redundant.host_admitted == 1;
    let dedup = result.dedup_on.recovery_encodes == 1 && result.dedup_off.recovery_encodes >= 2;
    // The lossy clock is max(1·RTT, 60 ms, 1.5·RTT), which at this arm's 50 ms round trip is 75 ms
    // against the normal 100 — a deadline gap of only ~25 ms, of which the host's frame-boundary
    // quantization can eat up to one interval. That thin margin is the deliberate price of the
    // 60 ms floor: never escalate before a refresh can physically land. A lower floor would widen
    // the gap and re-open the storm.
    let fast = result.fast_on.freeze_ms + 8.0 <= result.fast_off.freeze_ms;
    println!(
        "    #9 recovery-redundancy: lost-request freeze 3×-copies beats single ≥40%={}  straddle dedup \
         ON=1/OFF≥2 HW encodes={}  lossy clock ≥8ms faster when all copies lost={}  {}",
        yes(redundant),
        yes(dedup),
        yes(fast),
        if redundant && dedup && fast {
            "✅"
        } else {
            "⚠️"
        },
    );
}

/// How a verdict's bit prints.
pub(crate) const fn yes(value: bool) -> &'static str {
    if value { "YES" } else { "no" }
}
