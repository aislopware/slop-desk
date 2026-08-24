//! The PURE CONTROLLER drive: every decision-making component on synthetic telemetry, no hardware.
//!
//! Nothing here encodes a frame. Each component is fed a scripted series it cannot tell from a real
//! link's and made to print what it decided, so a change in a ladder, a threshold or a smoothing
//! constant shows up as a changed line rather than as a changed feel.

use slopdesk_video::adaptive_fec::{self, DEFAULT_TIER};
use slopdesk_video::client_jitter::{
    AdaptiveJitterController, DEFAULT_JITTER_SAFETY, DEFAULT_SHRINK_COOLDOWN_FRAMES, OwdJitterEstimator,
};
use slopdesk_video::congestion::{CongestionConfig, LiveCongestionController};
use slopdesk_video::loopback::tier_description;
use slopdesk_video::ltr::{LtrController, RecoveryAction, RecoveryRequestKind};
use slopdesk_video::network_estimate::NetworkEstimate;
use slopdesk_video::pacer_depth::{PacerDepthConfig, PacerDepthPolicy};
use slopdesk_video::recovery::{NetworkStatsReport, RecoveryMessage};

/// The clean-report shape every warm-up loop folds.
fn fold_clean(estimate: &mut NetworkEstimate, rtt: i64, unrecovered: u32, jitter_micros: u32) {
    estimate.fold(Some(rtt), 100, unrecovered, jitter_micros, 0, 0);
}

/// Drives every pure controller.
#[expect(
    clippy::too_many_lines,
    reason = "one printed trace per component, and the trace IS the deliverable — splitting it hides the \
              order"
)]
pub fn run() {
    println!("\n=== 5. PURE CONTROLLERS on synthetic telemetry (no HW) ===");

    // ── NetworkEstimate ──
    println!("  [NetworkEstimate]");
    let mut estimate = NetworkEstimate::new();
    for _ in 0..5 {
        fold_clean(&mut estimate, 20, 0, 500);
    }
    print_estimate("clean x5  ", &estimate);
    fold_clean(&mut estimate, 60, 12, 3000);
    print_estimate("loss spike", &estimate);
    let rtt = NetworkEstimate::compute_rtt_millis(1000, 950, 10);
    println!(
        "    compute_rtt_millis(host_now=1000, send_ts=950, hold=10) = {} ms (expect 40)",
        rtt.map_or_else(|| "nil".to_owned(), |value| value.to_string()),
    );

    // ── LiveCongestionController ──
    println!("  [LiveCongestionController] AIMD bitrate (ceiling=45 Mbps)");
    let config = CongestionConfig::default();
    let mut controller = LiveCongestionController::with_ceiling(45_000_000, config, false);
    println!(
        "    ceiling={} floor={} start={}",
        controller.ceiling(),
        controller.floor(),
        controller.current(),
    );
    let mut drive = NetworkEstimate::new();
    for _ in 0..10 {
        fold_clean(&mut drive, 20, 0, 400);
        let _ = controller.decide(&drive, None);
    }
    println!(
        "    after 10 warmup clean reports: current={} (held at ceiling)",
        controller.current(),
    );
    for index in 0..5 {
        // Raw loss 0.04, over the 0.02 decrease threshold.
        fold_clean(&mut drive, 25, 4, 600);
        println!(
            "    congestion report {} (loss 4%): current={}",
            index + 1,
            controller.decide(&drive, None).target,
        );
    }
    fold_clean(&mut drive, 30, 20, 900);
    println!(
        "    SEVERE report (loss 20%): current={}",
        controller.decide(&drive, None).target,
    );
    for _ in 0..30 {
        fold_clean(&mut drive, 20, 0, 300);
        let _ = controller.decide(&drive, None);
    }
    println!(
        "    after 30 clean recovery reports: current={} (additive climb back toward ceiling)",
        controller.current(),
    );

    // ── The adaptive-FEC ladder ──
    println!("  [adaptive_fec::tier_for_loss] loss -> tier ladder (hysteresis + one-step clamp)");
    let mut tier = DEFAULT_TIER;
    // The ladder's relax floor is what `SLOPDESK_FEC_ALLOW_OFF=1` lifts, and the sweep must walk
    // the ladder the SHIPPING default walks — off-tier barred unless the operator opted in.
    let allow_off = std::env::var("SLOPDESK_FEC_ALLOW_OFF").as_deref() == Ok("1");
    for loss in [0.0, 0.006, 0.025, 0.06, 0.12, 0.12, 0.04, 0.012, 0.001, 0.0, 0.0] {
        tier = adaptive_fec::tier_for_loss(loss, tier, allow_off);
        println!("    loss={loss:.3} -> tier={tier} ({})", tier_description(tier));
    }

    // ── The jitter estimator and the depth it drives ──
    println!("  [OwdJitterEstimator + AdaptiveJitterController]");
    let mut jitter = OwdJitterEstimator::new();
    let mut arrival = 0.0_f64;
    for delta in [
        0.016, 0.016, 0.050, 0.016, 0.045, 0.016, 0.055, 0.016, 0.040, 0.016,
    ] {
        arrival += delta;
        jitter.note(arrival);
    }
    println!(
        "    jittery arrival series -> jitter_micros={}us (smoothed seconds={:.5})",
        jitter.jitter_micros(),
        jitter.jitter_seconds(),
    );
    let mut depth = AdaptiveJitterController::new(
        1,
        8,
        60.0,
        1,
        DEFAULT_JITTER_SAFETY,
        DEFAULT_SHRINK_COOLDOWN_FRAMES,
    );
    println!("    target_depth start={}", depth.target_depth());
    for seconds in [0.0, 0.005, 0.010, 0.020, 0.030] {
        println!(
            "    note_frame(jitter={seconds:.3}s) -> depth={} (grow-fast)",
            depth.note_frame(seconds),
        );
    }
    println!("    note_underrun() -> depth={} (bump)", depth.note_underrun());
    // Shrink-slow: one step per cooldown, so it takes hundreds of clean frames to walk back.
    for _ in 0..200 {
        let _ = depth.note_frame(0.0);
    }
    println!(
        "    after 200 low-jitter frames -> depth={} (shrink-slow)",
        depth.target_depth(),
    );

    // ── LTRController ──
    println!("  [LtrController] record -> ack -> recovery_decision -> reset");
    let mut ltr = LtrController::new();
    println!(
        "    before ack: recovery_decision(LtrRefresh) = {:?} (expect Idr)",
        ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
    );
    ltr.record_ltr_frame(10, 7777);
    println!(
        "    ack_frame(10) -> {} (expect 7777)",
        ltr.ack_frame(10)
            .map_or_else(|| "nil".to_owned(), |token| token.to_string()),
    );
    println!("    has_acked_token = {}", ltr.has_acked_token());
    println!(
        "    after ack: recovery_decision(LtrRefresh) = {:?} (expect LtrRefresh)",
        ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
    );
    println!(
        "    Idr always -> {:?} (expect Idr)",
        ltr.recovery_decision(RecoveryRequestKind::Idr, true),
    );
    println!(
        "    LTR off -> {:?} (expect Idr)",
        ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, false),
    );
    println!(
        "    ack_frame(unknown 999) -> {} (expect nil)",
        ltr.ack_frame(999)
            .map_or_else(|| "nil".to_owned(), |token| token.to_string()),
    );
    ltr.reset();
    debug_assert_eq!(
        ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
        RecoveryAction::Idr,
        "a reset controller has no token, so a refresh must fold back to a keyframe",
    );
    println!(
        "    after reset: has_acked_token={} recovery_decision(LtrRefresh)={:?} (expect false, Idr)",
        ltr.has_acked_token(),
        ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
    );

    // ── PacerDepthPolicy, scripted rather than swept ──
    println!("  [PacerDepthPolicy] late-event promote / clean-dwell demote (component 4)");
    let mut policy = PacerDepthPolicy::new(PacerDepthConfig::default(), true);
    let mut now = 0.0_f64;
    for _ in 0..60 {
        now += 1.0 / 60.0;
        policy.note_arrival(now);
        let _ = policy.note_present(now);
    }
    println!(
        "    1s clean 60fps -> depth={} late_lo={:.1}ms (expect 1, ~28ms)",
        policy.depth(),
        policy.late_threshold_seconds() * 1000.0,
    );
    // One dropped slot is a 33 ms gap — dense enough to count, alone not enough to promote.
    now += 2.0 / 60.0;
    policy.note_arrival(now);
    let first = policy.note_present(now);
    println!(
        "    33ms dense gap #1 -> {first:?} depth={} (expect Late, still 1)",
        policy.depth(),
    );
    for _ in 0..24 {
        now += 1.0 / 60.0;
        policy.note_arrival(now);
        let _ = policy.note_present(now);
    }
    now += 2.0 / 60.0;
    policy.note_arrival(now);
    let second = policy.note_present(now);
    println!(
        "    33ms dense gap #2 (+433ms) -> {second:?} depth={} (expect Late, PROMOTED to 2)",
        policy.depth(),
    );
    for _ in 0..180 {
        now += 1.0 / 60.0;
        policy.note_arrival(now);
        let _ = policy.note_present(now);
    }
    println!(
        "    after 3s clean dwell -> depth={} (expect demoted to 1)",
        policy.depth(),
    );
    let window = policy.drain_counters();
    println!(
        "    drained window -> late={} gaps={}",
        window.late_frames, window.present_gaps,
    );

    // ── The telemetry wire those numbers travel on ──
    let report = NetworkStatsReport {
        frames_received: 120,
        fec_recovered: 5,
        unrecovered: 2,
        latest_host_send_ts: 950,
        client_hold_ms: 10,
        owd_jitter_micros: 1500,
        pacer_late_frames: window.late_frames,
        pacer_present_gaps: window.present_gaps,
        pacer_depth: policy.depth(),
        ..NetworkStatsReport::default()
    };
    let wire = RecoveryMessage::NetworkStats(report).encode();
    if let Ok(RecoveryMessage::NetworkStats(round_tripped)) = RecoveryMessage::decode(&wire) {
        println!(
            "  [NetworkStatsReport] wire round-trip OK: frames_received={} unrecovered={} jitter={}us \
             late={} gaps={} depth={} ({}-byte msg)",
            round_tripped.frames_received,
            round_tripped.unrecovered,
            round_tripped.owd_jitter_micros,
            round_tripped.pacer_late_frames,
            round_tripped.pacer_present_gaps,
            round_tripped.pacer_depth,
            wire.len(),
        );
    } else {
        println!("  [NetworkStatsReport] wire round-trip FAILED");
    }
}

/// One estimate line, in the order the controller reads the fields.
fn print_estimate(label: &str, estimate: &NetworkEstimate) {
    println!(
        "    {label} -> smoothed_rtt={:.1}ms min_rtt={:.1}ms loss_rate={:.4} last_loss={:.4} owd_rising={}",
        estimate.smoothed_rtt_millis,
        estimate.min_rtt_millis,
        estimate.loss_rate,
        estimate.last_loss_sample,
        estimate.owd_gradient_rising,
    );
}
