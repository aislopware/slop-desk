//! The CLOSED-LOOP SUITE: every adaptation reflex, run in one order, with one verdict block.
//!
//! Each section drives a scenario module and prints what it measured; the verdict block at the end
//! turns those numbers into the pass/warn line a reader acts on. The per-section printers are
//! public because the standalone flags print the SAME block — a verdict that reads differently
//! depending on how it was invoked would be two verdicts.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_video::congestion::CongestionConfig;
use slopdesk_video::loopback::tier_description;

use crate::redundancy::{RedundancyResult, yes};
use crate::{bottleneck, closedloop, fpsgov, gradient, idr, pacer, redundancy};

/// Drives every section, then the verdict block.
#[expect(
    clippy::too_many_lines,
    reason = "the suite IS its printed order: nine sections and the verdict that reads them"
)]
#[expect(
    clippy::indexing_slicing,
    reason = "the closed-loop arm reports one entry per phase, and there are three phases"
)]
pub(crate) fn run(frames_per_phase: usize) {
    println!(
        "\n=== CLOSED-LOOP ADAPTATION :: full reflex through REAL components (in-process lossy transport) \
         ==="
    );
    println!("    real HW encode→packetize(tier)→LOSS→reassemble+FEC→NetworkStatsReport(REAL wire)→");
    println!(
        "    host fold→adaptive FEC tier + LiveCongestionController→encoder.set_live_bitrate; client \
         jitter→depth."
    );
    println!("    {frames_per_phase} frames/phase, phases: CLEAN → ADVERSE(3% loss+jitter) → CLEAN.\n");

    println!("  [A] ALL adaptation ON (ABR + adaptive FEC + adaptive jitter)");
    let on = closedloop::run(closedloop::Arm {
        frames_per_phase,
        verbose: true,
        ..closedloop::Arm::default()
    });
    if !on.has_every_phase() {
        println!(
            "  FAIL: the closed-loop arm reported fewer than three phases — encoder or source create failed"
        );
        return;
    }
    println!(
        "    BITRATE  Mbps/phase  : clean={:.1}  adverse={:.1}  recovery={:.1}",
        on.phase_avg_bitrate_mbps[0], on.phase_avg_bitrate_mbps[1], on.phase_avg_bitrate_mbps[2],
    );
    println!(
        "    ENC bytes/frame      : clean={}  adverse={}  recovery={}  (HW honoured set_live_bitrate ⇒ \
         bytes track bitrate)",
        on.phase_avg_enc_bytes[0], on.phase_avg_enc_bytes[1], on.phase_avg_enc_bytes[2],
    );
    println!(
        "    FEC tier  peak/phase : clean={}  adverse={}  recovery={}",
        tier_description(on.phase_peak_tier[0]),
        tier_description(on.phase_peak_tier[1]),
        tier_description(on.phase_peak_tier[2]),
    );
    println!(
        "    JITTER depth peak    : clean={}  adverse={}  recovery={}",
        on.phase_peak_depth[0], on.phase_peak_depth[1], on.phase_peak_depth[2],
    );
    println!(
        "    DEPTH-V2 peak (comp4): clean={}  adverse={}  recovery={}  (late-event 1↔2 policy on the same \
         stream)",
        on.phase_peak_depth_v2[0], on.phase_peak_depth_v2[1], on.phase_peak_depth_v2[2],
    );
    println!(
        "    UNRECOVERED/phase    : clean={}  adverse={}  recovery={}",
        on.phase_unrecovered[0], on.phase_unrecovered[1], on.phase_unrecovered[2],
    );

    println!(
        "\n  [B] adaptive-FEC A/B control (ABR+jitter ON, FEC pinned at today-default g5 = non-adaptive \
         baseline)"
    );
    let fec_pinned = closedloop::run(closedloop::Arm {
        frames_per_phase,
        fec: false,
        fixed_tier: Some(0),
        ..closedloop::Arm::default()
    });
    if !fec_pinned.has_every_phase() {
        println!(
            "  FAIL: the closed-loop arm reported fewer than three phases — encoder or source create failed"
        );
        return;
    }
    // The fair window is STEADY STATE — the second half of the adverse phase. It excludes the
    // adaptive run's climb-from-OFF transient, which the pinned baseline never pays, and by then
    // the adaptive tier has settled at its heaviest.
    println!(
        "    adverse STEADY-STATE (2nd half) UNRECOVERED : adaptive={}  vs  pinned-g5={}",
        on.adverse_unrec_second_half, fec_pinned.adverse_unrec_second_half,
    );
    println!(
        "    adverse FULL-phase UNRECOVERED              : adaptive={}  vs  pinned-g5={}  (adaptive pays a \
         climb-from-OFF transient)",
        on.phase_unrecovered[1], fec_pinned.phase_unrecovered[1],
    );
    let fec_helped = on.adverse_unrec_second_half <= fec_pinned.adverse_unrec_second_half;

    println!(
        "\n  [C] LOSS-TOLERANCE #4 weather control (ABR ON, 3% loss at FLAT RTT — the measured 2026-06-10 \
         path shape)"
    );
    let weather = closedloop::run(closedloop::Arm {
        frames_per_phase,
        jitter: false,
        congest_rtt_in_adverse: false,
        ..closedloop::Arm::default()
    });
    if !weather.has_every_phase() {
        println!(
            "  FAIL: the closed-loop arm reported fewer than three phases — encoder or source create failed"
        );
        return;
    }
    let weather_held = !weather.bitrate_fell_in_adverse;
    println!(
        "    BITRATE  Mbps/phase  : clean={:.1}  weather={:.1}  after={:.1}",
        weather.phase_avg_bitrate_mbps[0],
        weather.phase_avg_bitrate_mbps[1],
        weather.phase_avg_bitrate_mbps[2],
    );

    println!(
        "\n  [D] DELAY-TARGETING bottleneck queue (capacity = 55% of ceiling, ZERO loss — the measured \
         2026-06-11 scroll shape)"
    );
    let queue = bottleneck::run(frames_per_phase.saturating_mul(5), true);
    let queue_converged = queue.converged_at_ms.is_some_and(|ms| ms <= 2500.0);
    // The controller TARGETS the round-trip slack trim boundary, so a governed queue hovers around
    // it. Twenty-five milliseconds is the "governed, not standing" gate — an ungoverned one sits at
    // several hundred.
    let queue_drained = queue.tail_avg_queue_ms < 25.0;
    let queue_no_pump = queue.rebash_count <= 1;
    println!(
        "    capacity={:.1}Mbps  converged at t={}  end rate={:.1}Mbps",
        queue.capacity_mbps,
        queue
            .converged_at_ms
            .map_or_else(|| "NEVER".to_owned(), |ms| format!("{ms:.0}ms")),
        queue.end_actuated_mbps,
    );
    println!(
        "    tail (last 25%) queue: avg={:.1}ms max={:.1}ms   re-bash climbs after convergence={}",
        queue.tail_avg_queue_ms, queue.tail_max_queue_ms, queue.rebash_count,
    );

    println!(
        "\n  [E] FPS-GOVERNOR cliff (2.5Mbps + uncompressible noise = past the QP51 floor → fps ladder; \
         restore → climb)"
    );
    let cliff = fpsgov::run_cliff(true);
    println!(
        "    cliff steps (in order)    : {}   min rung spacing={}",
        cliff
            .cliff_steps_in_order
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(" → "),
        if cliff.min_cliff_spacing_ms.is_finite() {
            format!("{:.0}ms", cliff.min_cliff_spacing_ms)
        } else {
            "n/a".to_owned()
        },
    );
    println!(
        "    held 60 in ample phase={}  ABR collapsed in cliff={}  end fps={}  step-up spacings={}",
        yes(cliff.held_base_in_phase1),
        yes(cliff.abr_collapsed_in_cliff),
        cliff.end_fps,
        cliff
            .step_up_spacings_ms
            .iter()
            .map(|ms| format!("{ms:.0}ms"))
            .collect::<Vec<_>>()
            .join(", "),
    );
    println!(
        "    cadence within plateaus   : admit worst |Δt − 1/fps| = {:.2}ms, final-plateau encode worst = \
         {:.2}ms (tolerance {:.2}ms); cliff VT-starvation gaps up to {:.0}ms (expected, not asserted)",
        cliff.worst_cadence_err_ms,
        cliff.worst_fit_encode_err_ms,
        0.5 / 120.0 * 1000.0,
        cliff.worst_encode_gap_ms,
    );

    println!("\n  [E2] FPS-GOVERNOR weather arm (3% loss at FLAT RTT, ABR holds — fps must hold 60)");
    let fps_weather = fpsgov::run_weather(frames_per_phase.saturating_mul(4), false);
    println!(
        "    min fps={}  loss-evidence ticks seen={}  bitrate held={}",
        fps_weather.min_fps,
        yes(fps_weather.saw_loss_evidence),
        yes(fps_weather.bitrate_held),
    );

    println!(
        "\n  [F] RECOVERY-IDR delivery-keyed cooldown (component 2: kfDup double-loss bypass vs legacy \
         500ms gate)"
    );
    let recovery_idr = idr::run(true);
    print_idr_phases(&recovery_idr);

    println!(
        "\n  [G] DELAY-GRADIENT early cut (component 3: capacity step to 40% — client trendline + raw-RTT \
         one-report cut, A/B in-process)"
    );
    let gradient = gradient::run(true);
    print_gradient_phases(&gradient);

    println!(
        "\n  [H] ADAPTIVE PACER DEPTH v3 (component 4: owd-late 1↔2 boost — real OwdLateDetector + policy, \
         virtual clock, phases A-E)"
    );
    let depth = pacer::run(true);

    println!(
        "\n  [I] RECOVERY-REQUEST REDUNDANCY (component 5: 3× spaced copies + host dedup + loss-adaptive \
         halved escalation)"
    );
    let redundancy = redundancy::run(true);
    print_redundancy_phases(&redundancy);

    println!("\n  ===== CLOSED-LOOP VERDICT =====");
    println!(
        "    #2 ABR        : bitrate fell under CORROBORATED loss (RTT inflated)={}  recovered after={}  {}",
        yes(on.bitrate_fell_in_adverse),
        yes(on.bitrate_recovered_after),
        mark(on.bitrate_fell_in_adverse && on.bitrate_recovered_after),
    );
    println!(
        "    #2b weather   : bitrate HELD under uncorroborated weather loss (flat RTT)={}  {}",
        yes(weather_held),
        mark(weather_held),
    );
    // The ladder FLOOR is why this verdict does NOT check "tier escalated under loss". Without a
    // floor the clean phase walks the tier to OFF and the adverse onset lands UNPROTECTED. With it
    // the stream enters the adverse phase already holding g10, which absorbs the scripted
    // one-hole-per-group loss completely — the loss average never rises, so there is nothing to
    // escalate from. What is pinned instead is the floor's own contract.
    let fec_never_off = !on.saw_off_tier;
    let fec_absorbed = on.phase_unrecovered[1] == 0;
    println!(
        "    #3 adaptiveFEC: never relaxed to OFF (ladder floor)={}  adverse absorbed at the standing floor \
         (unrec=0)={}  reduced unrecovered vs pinned-g5={}  {}",
        yes(fec_never_off),
        yes(fec_absorbed),
        yes(fec_helped),
        mark(fec_never_off && fec_absorbed && fec_helped),
    );
    let depth_grew = on.phase_peak_depth[1] > on.phase_peak_depth[0];
    println!(
        "    #4 adaptiveJit: playout depth grew under jitter={}  {}",
        yes(depth_grew),
        mark(depth_grew),
    );
    print_pacer_verdict(&depth);
    let hw_tracked = on.phase_avg_enc_bytes[1] < on.phase_avg_enc_bytes[0];
    println!(
        "    HW actuation  : encoded bytes shrank with bitrate={} (real VTSessionSetProperty took effect)  \
         {}",
        yes(hw_tracked),
        mark(hw_tracked),
    );
    println!(
        "    #5 delay-targeting: converged ≤2.5s={}  tail queue <25ms={}  no pumping={}  {}",
        yes(queue_converged),
        yes(queue_drained),
        yes(queue_no_pump),
        mark(queue_converged && queue_drained && queue_no_pump),
    );
    let stepped = cliff.cliff_steps_in_order.starts_with(&[30, 20])
        && cliff.cliff_spacing_ok
        && cliff.held_base_in_phase1
        && cliff.abr_collapsed_in_cliff;
    let recovered = cliff.end_fps == 60;
    println!(
        "    #6 fps-governor: stepped 60→30→20 under cliff={}  cadence regular={}  recovered to 60={}  {}",
        yes(stepped),
        yes(cliff.cadence_regular),
        yes(recovered),
        mark(stepped && cliff.cadence_regular && recovered),
    );
    let weather_fps_held = fps_weather.min_fps == 60 && fps_weather.saw_loss_evidence;
    println!(
        "    #6b fps-governor weather: held 60 under flat-RTT loss={}  {}",
        yes(weather_fps_held),
        mark(weather_fps_held),
    );
    print_idr_verdict(&recovery_idr);
    print_gradient_verdict(&gradient);
    redundancy::print_verdict(&redundancy);
}

/// The four recovery-IDR phase lines, shared by section [F] and `--recovery-idr`.
pub(crate) fn print_idr_phases(result: &idr::RecoveryIdrResult) {
    let speedup = if result.v2_unfreeze_ms > 0.0 {
        result.legacy_unfreeze_ms / result.v2_unfreeze_ms
    } else {
        0.0
    };
    println!(
        "    Phase A unfreeze (rtt=50ms, both IDR copies lost): V2={:.0}ms ({} requests)  vs  \
         LEGACY={:.0}ms ({} requests)  — {speedup:.1}× faster",
        result.v2_unfreeze_ms, result.v2_requests, result.legacy_unfreeze_ms, result.legacy_requests,
    );
    println!(
        "    Phase B storm (6 requests in 350ms): grants={}  suppressed={}  refill-grant after 500ms={}",
        result.storm_grants,
        result.storm_suppressed,
        yes(result.refill_grant_after),
    );
    println!(
        "    Phase C stale pre-ack request      : suppressed={}  zero-cost={}",
        yes(result.stale_suppressed),
        yes(result.stale_spent_no_token),
    );
    println!(
        "    Phase D real-HW grant→keyframe     : next encoded frame was IDR={}  pre-grant deltas stayed \
         deltas={}",
        yes(result.grant_yielded_keyframe),
        yes(result.pre_grant_frames_were_deltas),
    );
}

/// The recovery-IDR verdict line.
pub(crate) fn print_idr_verdict(result: &idr::RecoveryIdrResult) {
    let bypass = result.v2_second_request_granted
        && result.v2_unfreeze_ms < 250.0
        && result.legacy_unfreeze_ms > 500.0;
    let storm =
        (1..=2).contains(&result.storm_grants) && result.storm_verdicts_ok && result.refill_grant_after;
    let stale = result.stale_suppressed && result.stale_spent_no_token;
    let forced = result.grant_yielded_keyframe && result.pre_grant_frames_were_deltas;
    println!(
        "    #7 recovery-idr: casualty bypass <250ms (legacy >500ms)={}  storm ≤2 grants+refill={}  \
         stale-ack zero-cost={}  grant→HW keyframe={}  {}",
        yes(bypass),
        yes(storm),
        yes(stale),
        yes(forced),
        mark(bypass && storm && stale && forced),
    );
}

/// The three delay-gradient measurement lines.
pub(crate) fn print_gradient_phases(result: &gradient::GradientResult) {
    println!(
        "    capacity step={:.1}Mbps  onset→first-cut: OFF={}  ON={}  (trend OVERUSING at ON cut={})",
        result.capacity_mbps,
        millis(result.off_onset_to_first_cut_ms),
        millis(result.on_onset_to_first_cut_ms),
        yes(result.on_trend_overusing_at_first_cut),
    );
    println!(
        "    ON cuts ≤1s after onset   : {} (ticks-from-first {:?})  min cut spacing={} ticks",
        result.on_cut_ticks_from_onset.len(),
        result.on_cut_ticks_from_onset,
        result
            .on_min_cut_spacing_ticks
            .map_or_else(|| "n/a".to_owned(), |ticks| ticks.to_string()),
    );
    println!(
        "    clean ±4ms-wobble sub-run : cuts={} (false-positive guard, must be 0)",
        result.clean_wobble_cuts,
    );
}

/// The delay-gradient verdict line.
pub(crate) fn print_gradient_verdict(result: &gradient::GradientResult) {
    let hold_ticks = CongestionConfig::default().cut_hold_ticks as usize;
    let faster = result
        .on_onset_to_first_cut_ms
        .unwrap_or(f64::INFINITY)
        .lt(&result.off_onset_to_first_cut_ms.unwrap_or(f64::INFINITY));
    // One immediate cut plus at most one per hold window inside the first second of a persisting
    // squeeze — the no-cascade invariant is the SPACING, not the count.
    let spaced = result.on_min_cut_spacing_ticks.unwrap_or(hold_ticks) >= hold_ticks
        && result.on_cut_ticks_from_onset.len() <= 3;
    let calm = result.clean_wobble_cuts == 0;
    println!(
        "    #8 delay-gradient: onset→cut ON beats OFF={}  cuts spaced ≥{hold_ticks} ticks (≤3 in 1s)={}  \
         clean-phase cuts 0={}  {}",
        yes(faster),
        yes(spaced),
        yes(calm),
        mark(faster && spaced && calm),
    );
}

/// The adaptive-pacer-depth verdict line, shared by the suite and `--pacer-depth`.
pub(crate) fn print_pacer_verdict(result: &pacer::PacerDepthResult) {
    let clean = result.clean_lates == 0 && result.clean_gaps == 0 && result.clean_depth_stayed_1;
    let promote =
        result.promote_after_onset_ms.unwrap_or(f64::INFINITY) <= 1500.0 && result.held_through_burst;
    // The band opens at two seconds rather than a strict 2.5: the default demote tolerance anchors
    // the dwell at the SECOND-most-recent late, and at the burst's ~333 ms late spacing that puts
    // the earliest demote at about dwell − 333 ms after the LAST one.
    let demote = result
        .demote_after_last_late_ms
        .is_some_and(|ms| (2000.0..=4000.0).contains(&ms));
    let immune = result.downshift_lates <= 1
        && !result.downshift_promoted
        && result.downshift_hint_lates == 0
        && result.typing_lates == 0;
    println!(
        "    #4b depth-v2  : clean never engages={}  promote ≤1.5s into owd burst + holds={}  demote 2-4s \
         after last late={}  downshift/typing immune={}  {}",
        yes(clean),
        yes(promote),
        yes(demote),
        yes(immune),
        mark(clean && promote && demote && immune && result.depth1_at_recovery_end),
    );
}

/// The three recovery-redundancy measurement lines.
pub(crate) fn print_redundancy_phases(result: &RedundancyResult) {
    let better = if result.baseline.freeze_ms > 0.0 {
        (1.0 - result.redundant.freeze_ms / result.baseline.freeze_ms) * 100.0
    } else {
        0.0
    };
    println!(
        "    lost-request freeze: copies=1 (today)={:.0}ms  vs  copies=3={:.0}ms  ({better:.0}% better)",
        result.baseline.freeze_ms, result.redundant.freeze_ms,
    );
    println!(
        "    straddle dedup (REAL HW)  : ON encodes={} (expect 1)  OFF control={} (expect ≥2 — the \
         pre-existing LTR straddle bug)",
        result.dedup_on.recovery_encodes, result.dedup_off.recovery_encodes,
    );
    println!(
        "    all-copies-lost residual  : fast-escalation ON={:.0}ms  vs  OFF={:.0}ms (halved clock at \
         max(1·RTT, 60ms, 1.5·RTT) — the fix-3 floor)",
        result.fast_on.freeze_ms, result.fast_off.freeze_ms,
    );
}

/// How a whole verdict's outcome prints.
const fn mark(passed: bool) -> &'static str {
    if passed { "✅" } else { "⚠️" }
}

/// How an optional elapsed time prints.
fn millis(value: Option<f64>) -> String {
    value.map_or_else(|| "NEVER".to_owned(), |ms| format!("{ms:.0}ms"))
}
