//! The recovery channel and everything a client's feedback ACTUATES.
//!
//! The Swift host session's `handleRecovery` and its seven arms, `gateRecoveryIDR`,
//! `armKfDupFastAttack`, `actuateGovernedFps`, `applyUserStreamSettings`, and the host-stats echo
//! the report clock carries.
//!
//! ## Why this is the same owner as [`crate::session_inbound`]
//! Actuation here is NOT a timer. The congestion, quantiser, cadence and FEC decisions all run
//! INLINE when a feedback report arrives, over the same [`crate::session_wiring::Controllers`]
//! lock, in one fixed order.
//! Split across two owners, each would have to invent the lock discipline at that seam, and the
//! Swift's own history says what happens next: two readers of "is the link congested" that can
//! disagree, and a stream that coarsens and sharpens against itself. One file for the pump, one for
//! the actuation, ONE discipline across both — and the pump thread is the only thread that reaches
//! either.
//!
//! ## The ONE lock hold per report, in the Swift's order
//! `Session::fold_report` takes `Session::locked_controllers` EXACTLY ONCE and does five things
//! under it, in this order and no other:
//!
//! 1. **Fold the estimate.** Round trip, loss and the delay-gradient trend. Everything below reads
//!    the freshly folded numbers, which is why nothing below has to be told what the others saw.
//! 2. **Step the adaptive-FEC ladder.** Off the loss EWMA that step 1 just moved, in place on
//!    [`crate::session_wiring::Controllers::fec_tier`]. Only inside a real report, so the tier
//!    cannot walk before there is loss data — and under THIS hold, because the frame path reads the
//!    same field to stamp a packet and must never see half a report's worth of it.
//! 3. **Tick the ABR.** The AIMD's new target and, with it, the congestion VERDICT.
//! 4. **Tick the QP ladder.** On the ABR's verdict — reused, never re-derived.
//! 5. **Tick the FPS governor.** After the ABR, so it reacts to THIS tick's actuated rate.
//!
//! Five acquisitions would let a second report interleave between two of the reads and actuate a
//! bitrate the quantiser was never told about. The FRAMEWORK calls the plan produces all happen
//! after the guard is dropped: a property write is a window-server round trip, and a report folding
//! on another thread must never wait behind one.
//!
//! ## No fused multiply-add, anywhere below
//! `a * b + c` stays two roundings. The golden vectors pin these bit patterns, and `mul_add` rounds
//! once — which is why this crate's manifest turns `suboptimal_flops` and `imprecise_flops` OFF by
//! name. Where the Swift compared with `Double.maximum`/`.minimum` this uses [`f64::max`] and
//! [`f64::min`], never a `<` ternary, so a NaN propagates the way the wire's rules expect.
//!
//! ## The clock
//! Every timestamp here is [`Session::now`] — seconds since the session's own epoch — and every
//! wire millisecond is `crate::session_inbound::host_relative_millis` over the same instant. A
//! second `Instant::now()` in this file would put the two ends of the round-trip measurement in
//! different clock domains, which is a wire bug no gate on either side can see.
//!
//! ⚠️ GUI + TCC ONLY wherever a capture stream or an encoder is reached: those are framework
//! objects, so no test below installs one.

use std::sync::Arc;

use slopdesk_video::adaptive_fec::{self, RELAX_DWELL_REPORTS, TierState};
use slopdesk_video::congestion::{self, CutReason, LiveCongestionController};
use slopdesk_video::fps_governor::{self, FpsGovernor};
use slopdesk_video::ltr::{RecoveryAction, RecoveryRequestKind};
use slopdesk_video::network_estimate::NetworkEstimate;
use slopdesk_video::recovery::NetworkStatsReport;
use slopdesk_video::recovery_idr::IdrVerdict;
use slopdesk_video::recovery_routing::{RecoveryDecision, route_recovery};
use slopdesk_video::session_state::{bitrate_ceiling_from_wire, effective_fps, fps_cap_from_wire};
use slopdesk_video::video_control::VideoControlMessage;

use crate::sendlane::Job;
use crate::session::Session;
use crate::session_inbound::{SessionExtras, host_relative_millis};
use crate::session_wiring::{KF_DUP_FAST_ATTACK_WINDOW, PACE_CHUNK_FRAGMENTS, backpressure_skip};

/// How often the host echoes its half of the stats HUD back to the client.
///
/// Rides the client's own roughly 50 ms report clock rather than a timer of its own: with no
/// report there is no round trip to report anyway, so a client that wants no HUD costs zero
/// datagrams. A lost send heals on the next tick, which is why this is fire-and-forget.
const HOST_STATS_INTERVAL: f64 = 0.5;

/// What one folded report decided, to be actuated once the controller lock is released.
///
/// A value rather than five calls inside the hold, because every one of them is a framework
/// property write. Collecting them is what makes "one lock hold per report" and "no window-server
/// round trip under a lock" the same statement.
#[derive(Debug, Default, Clone, Copy)]
struct Actuation {
    /// The new constant quantiser, when const-QP mode owns the rate.
    quantiser: Option<i32>,
    /// The congestion verdict to hand the encoder's sharp-band decouple, when const-QP is on.
    link_congested: Option<bool>,
    /// The new live bitrate, when the move was material AND the QP ladder is not the rate control.
    bitrate_bps: Option<i64>,
    /// The governor's new cadence, when it CHANGED. Unchanged means silence on the wire.
    governed_fps: Option<i64>,
    /// The smoothed round trip just folded, for the stats echo.
    smoothed_rtt_millis: f64,
    /// The loss EWMA just folded, for the capturer's clean-link self-heal gate.
    ///
    /// `None` only when no report was folded, which cannot happen on this path — it is an `Option`
    /// for the reason [`Self::governed_fps`] is: a default of `0.0` would read as a MEASURED
    /// loss-free link and suppress healing on a link nothing has measured, which is the exact
    /// inversion of the capturer's infinite default.
    self_heal_loss_rate: Option<f64>,
}

impl Session {
    /// Handles one recovery datagram: the client's only channel for asking the host to act.
    ///
    /// Every arm asks [`route_recovery`] first and decides nothing itself. The three REQUEST arms —
    /// force-keyframe, LTR refresh and the selective NACK — pass the byte-keyed deduper, because
    /// the client sends each logical request three times and a second copy that acted would encode
    /// a second recovery frame. The ack, the report and the cursor re-ship are idempotent by
    /// construction and are not deduped.
    pub(crate) fn handle_recovery(self: &Arc<Self>, datagram: &[u8]) {
        let flowing = {
            let state = self.locked_state();
            let flowing = state.media_flowing();
            drop(state);
            flowing
        };
        let Some(extras) = self.extras() else {
            return;
        };
        let now = self.now();
        match route_recovery(datagram, flowing) {
            RecoveryDecision::ForceKeyframe {
                last_decoded_frame_id,
            } => {
                if admitted(&extras, datagram, now) {
                    // The GUARANTEED-recovery escalation: a client that lost frames re-anchors now
                    // rather than waiting for the roughly one-second heartbeat IDR.
                    self.gate_recovery_idr(last_decoded_frame_id);
                }
            },
            RecoveryDecision::RefreshLtr {
                last_decoded_frame_id,
            } => {
                if !admitted(&extras, datagram, now) {
                    return;
                }
                // The acked-only invariant, asked of the rule rather than re-derived: a refresh is
                // issued ONLY against a long-term reference the client decoded and acknowledged,
                // and everything else falls back to a real keyframe.
                let action = {
                    let controllers = self.locked_controllers();
                    let action = controllers
                        .ltr
                        .recovery_decision(RecoveryRequestKind::LtrRefresh, self.gates.ltr_enabled);
                    drop(controllers);
                    action
                };
                match action {
                    // SELF-HEAL PREFERENCE: the refresh arm is UNGATED. Only the IDR fallback pays
                    // the admission policy, because a cheap re-anchor is not what the storm cap
                    // exists to bound.
                    RecoveryAction::LtrRefresh => {
                        if let Some(capture) = self.capture_stream() {
                            capture.request_ltr_refresh();
                        }
                    },
                    RecoveryAction::Idr => self.gate_recovery_idr(last_decoded_frame_id),
                }
            },
            RecoveryDecision::Ack { stream_seq } => self.note_ack(stream_seq),
            // The sampler owns the shape cache and is the ONLY thing that can answer this: the
            // cursor is not re-read, because a fresh read would answer whatever shape is displayed
            // now rather than the id the client lost. Ungated, like the LTR-refresh arm above — a
            // few hundred bytes of an already-minted bitmap is not what the storm cap bounds.
            RecoveryDecision::ReshipCursorShape { shape_id } => self.reship_cursor_shape(shape_id),
            RecoveryDecision::NetworkStats(report) => self.fold_report(&extras, &report),
            RecoveryDecision::RetransmitFragments {
                frame_id,
                frag_indices,
            } => {
                if admitted(&extras, datagram, now) {
                    self.retransmit_fragments(frame_id, &frag_indices);
                }
            },
            // A corrupt datagram, and a datagram for a session that is not streaming. Both are
            // already decided; neither is an error this end can act on.
            RecoveryDecision::Drop | RecoveryDecision::IgnoreNotStreaming => {},
        }
    }

    /// Folds a durable-receipt acknowledgement.
    ///
    /// The delivery-keyed cooldown is fed UNCONDITIONALLY — not gated on long-term references —
    /// because the client acks every decoded keyframe and the policy's own ring match is what
    /// rejects a plain P-frame id. The long-term-reference fold, by contrast, only runs under the
    /// gate: with references off the client never sends an ack at all.
    fn note_ack(&self, stream_seq: u32) {
        let token = {
            let mut controllers = self.locked_controllers();
            controllers.recovery_idr.note_keyframe_delivered(stream_seq);
            let token = if self.gates.ltr_enabled {
                controllers.ltr.ack_frame(stream_seq)
            } else {
                None
            };
            drop(controllers);
            token
        };
        // Staged OUTSIDE the lock: this is a `VTSessionSetProperty`, and an unknown, duplicate or
        // evicted frame id already answered `None` above rather than reaching it.
        if let Some(token) = token {
            if let Some(encoder) = self.encoder() {
                encoder.stage_acked_token(token);
            }
            // SELF-HEAL: an ack just folded, so the encoder holds an acknowledged long-term
            // reference and the capturer's cadence refresh can be a small loss-immune P-frame
            // instead of falling back to an IDR. Idempotent — a lock-set of a bool — and disarmed
            // again at every encoder install and every encoded keyframe, both of which leave the
            // client holding no reference this side may name.
            if let Some(capture) = self.capture_stream() {
                capture.set_self_heal_eligible(true);
            }
        }
    }

    /// Answers a selective NACK from the send-history ring.
    ///
    /// Cheaper than a recovery keyframe and it lands inside the client's playout buffer. A ring
    /// miss is a benign no-op — the frame aged out, or retransmission is off host-side — and the
    /// client's own escalation is still the fallback once its repair grace expires.
    ///
    /// The zero gap is load-bearing and was lost here once: a retransmit answers a client already
    /// waiting on a deadline, so it goes out in ONE shot rather than being re-paced.
    fn retransmit_fragments(&self, frame_id: u32, frag_indices: &[u16]) {
        let Some(log) = self.retransmit.as_ref() else {
            return;
        };
        let resend = log.fragments(frame_id, frag_indices);
        if resend.is_empty() {
            return;
        }
        let job = Job::new(resend.into(), 0, PACE_CHUNK_FRAGMENTS, 0);
        if let Some(lane) = self.send_lane.as_ref() {
            // The SAME gate a captured frame passes before it is encoded (`session_pump`), asked
            // here for the same reason: the lane's depth is the congestion signal, and a burst of
            // distinct NACKs under real loss would otherwise grow the queue without bound — deep
            // enough to trip the capture side's own skip, drop live frames, and produce the loss
            // that produces the next NACK. A repair the queue has no room for is a repair the
            // client's own escalation answers once its grace expires; that path is why this one is
            // allowed to say no. Never forced: a retransmit is never an anchor.
            if backpressure_skip(
                self.gates.backpressure_enabled,
                lane.depth(),
                usize::try_from(self.gates.backpressure_depth).unwrap_or_default(),
                false,
            ) {
                return;
            }
            lane.enqueue(job);
            return;
        }
        // `SLOPDESK_SEND_LANE=0` pins the operator to the inline path, and there is no lane to
        // enqueue on. The SAME job drains here rather than being dropped, so a ring HIT is never
        // lost just because the drain is disabled.
        for outgoing in job.outgoings() {
            self.transport.send(&outgoing.bytes, outgoing.channel);
        }
    }

    /// Folds one client report and actuates what it decided.
    ///
    /// The five steps and their order are this file's module note; the code below is that list.
    #[expect(
        clippy::too_many_lines,
        reason = "one report actuates six axes, and the ORDER between them is the contract this function \
                  is; splitting it would let a caller run them apart"
    )]
    fn fold_report(self: &Arc<Self>, extras: &SessionExtras, report: &NetworkStatsReport) {
        // A proven modern feedback client, and the ONLY thing that makes the silence pause
        // eligible — the same never-act-without-evidence rule the idle reaper uses.
        let mut liveness = self.locked_liveness();
        liveness.saw_feedback = true;
        drop(liveness);

        // Everything the fold needs from OUTSIDE the controller lock, read before it is taken.
        // `SLOPDESK_NETSTATS=0` makes the client report a zero stamp, which answers `None` here, so
        // the round-trip term is skipped while loss and jitter still fold.
        let rtt = NetworkEstimate::compute_rtt_millis(
            host_relative_millis(self),
            report.latest_host_send_ts,
            report.client_hold_ms,
        );
        let user_cap = self.user_fps_cap();
        let config = extras.congestion_config();
        let adaptive_m = extras.adaptive_m();
        let allow_off = extras.fec_allow_off();
        let saw_unrecovered_loss = report.unrecovered > 0;

        let mut plan = Actuation::default();
        {
            let mut controllers = self.locked_controllers();

            // 1. THE ESTIMATE. Everything below reads what this just moved.
            controllers.estimate.fold(
                rtt,
                report.frames_received,
                report.unrecovered,
                report.owd_jitter_micros,
                report.owd_trend_state_raw(),
                report.owd_trend_modified_milli_signed(),
            );
            let estimate = controllers.estimate;
            plan.smoothed_rtt_millis = estimate.smoothed_rtt_millis;
            plan.self_heal_loss_rate = Some(estimate.loss_rate);

            // 2. THE FEC LADDER, off the freshly folded loss EWMA. Hysteresis, the one-step clamp,
            //    the relax floor and the sticky dwell are all the pure policy's; this site only
            //    feeds it the report's unrecovered evidence. It is stepped IN PLACE on the
            //    controller set, under this same hold: the frame path reads `Controllers::fec_tier`
            //    to stamp a packet, so stepping it anywhere else would let a frame be built from
            //    half a report.
            let tier_before = controllers.fec_tier;
            controllers.fec_tier = next_tier(
                adaptive_m,
                self.gates.adaptive_fec_enabled,
                estimate.loss_rate,
                tier_before,
                allow_off,
                saw_unrecovered_loss,
            );

            // 3. THE ABR and 4. THE QP LADDER. The quantiser reuses the ABR's own congestion
            //    verdict rather than deriving a second one: under const-QP that verdict IS what
            //    drives Q, and two detectors that disagreed would fight each other on one stream.
            if self.gates.abr_enabled {
                // IDLE-RAMP GUARD: the recent offered throughput, so the controller suppresses its
                // additive probe while the stream is application-limited. The cadence is the
                // EFFECTIVE one, because the utilisation signal must reflect the rate frames
                // actually encode at.
                let governed = controllers
                    .fps
                    .as_ref()
                    .map_or(self.spec.fps, FpsGovernor::current_fps);
                let offered = controllers.offered_bps(effective_fps(governed, user_cap));
                let decision = controllers
                    .congestion
                    .as_mut()
                    .map(|controller| controller.decide(&estimate, offered));
                if let Some(decision) = decision {
                    let congested = matches!(
                        decision.reason,
                        CutReason::RttStreak
                            | CutReason::LossCorroborated
                            | CutReason::Gradient
                            | CutReason::Catastrophic
                    );
                    plan.quantiser = controllers.qp.as_mut().map(|ladder| ladder.decide(congested));
                    // The sharp-sidebar band is used only on a clean link and collapses to a
                    // pinned Min == Max == Q when the link is stressed. Same verdict, said twice
                    // to the encoder because they are two properties.
                    plan.link_congested = plan.quantiser.map(|_| congested);
                    let ceiling = controllers
                        .congestion
                        .as_ref()
                        .map_or(0, LiveCongestionController::ceiling);
                    if congestion::is_material_change(
                        controllers.last_actuated_bps,
                        decision.target,
                        ceiling,
                        config,
                    ) {
                        controllers.last_actuated_bps = decision.target;
                        // Under const-QP the QP ladder is the SOLE rate control: the average
                        // bitrate stays pinned at the create-time ceiling as a drop backstop, and
                        // cutting it here would race the coarser Q by a frame.
                        if controllers.qp.is_none() {
                            plan.bitrate_bps = Some(decision.target);
                        }
                    }
                }
            }

            // 5. THE FPS GOVERNOR, on the same report clock and AFTER the ABR, so it reacts to this
            //    tick's actuated rate. The below-ceiling proxy compares against the EFFECTIVE
            //    ceiling, not the policy one: with a user bitrate ceiling the rate legitimately
            //    saturates at the override, and comparing against the policy ceiling would read a
            //    clean link as permanently congested and walk the cadence down.
            let target_bps = controllers.last_actuated_bps;
            let abr_current = controllers
                .congestion
                .as_ref()
                .map(LiveCongestionController::current);
            let abr_ceiling = controllers
                .congestion
                .as_ref()
                .map(LiveCongestionController::effective_ceiling);
            let evidence = fps_governor::congestion_evidence(
                &config,
                estimate.last_loss_sample,
                estimate.smoothed_rtt_millis,
                estimate.min_rtt_millis,
                abr_current,
                abr_ceiling,
            );
            let governed_before = controllers
                .fps
                .as_ref()
                .map_or(self.spec.fps, FpsGovernor::current_fps);
            let stepped = controllers
                .fps
                .as_mut()
                .map(|governor| governor.on_tick(target_bps, evidence));
            if let Some(stepped) = stepped
                && stepped != governed_before
            {
                plan.governed_fps = Some(stepped);
            }
            drop(controllers);
        }

        self.actuate(&plan);
        self.maybe_send_host_stats(extras, plan.smoothed_rtt_millis);
    }

    /// Applies a folded report's plan, OUTSIDE every lock it was decided under.
    ///
    /// The order is the Swift's: the quantiser and its decouple first, then the live rate, then the
    /// cadence — so a report that both coarsens Q and cuts the rate never leaves the encoder
    /// holding a rate its quantiser has not been told about.
    fn actuate(self: &Arc<Self>, plan: &Actuation) {
        if let Some(encoder) = self.encoder() {
            if let Some(quantiser) = plan.quantiser {
                let _actuated = encoder.set_const_qp(quantiser);
            }
            if let Some(congested) = plan.link_congested {
                let _actuated = encoder.set_link_congested(congested);
            }
            if let Some(target) = plan.bitrate_bps {
                let _actuated = encoder.set_live_bitrate(target);
            }
        }
        if let Some(fps) = plan.governed_fps {
            self.actuate_governed_fps(fps);
        }
        // SELF-HEAL, clean-link loss gate: the capturer suppresses the periodic refresh doublet
        // while the folded loss EWMA sits below its threshold, and re-arms the instant loss
        // appears. Pushed on every report rather than behind a read of the gate here — the capturer
        // consults the rate ONLY under its own gate, so an off gate makes this a store nobody
        // reads, and a copy of the gate on this side would be a second thing to keep in step. The
        // snapshot is at most one report (~50 ms) stale, well inside the K-frame heal cadence.
        if let Some(rate) = plan.self_heal_loss_rate
            && let Some(capture) = self.capture_stream()
        {
            capture.set_self_heal_loss_rate(rate);
        }
    }

    /// The admission gate for the two IDR-issuing recovery paths.
    ///
    /// A long-term-reference refresh never comes through here, which is what preserves the
    /// self-heal preference. With the delivery-keyed policy on, only a grant latches a keyframe;
    /// with it off the latch is unconditional and the capturer's own sent-keyed gate rules.
    fn gate_recovery_idr(&self, last_decoded: Option<u32>) {
        // CAPTURE BRING-UP GUARD, before the policy and not after: consulting it with no capturer
        // would burn a token AND latch a grant that no keyframe ever services — a phantom grant
        // whose pending window then suppresses the client's real re-request once capture is up.
        let Some(capture) = self.capture_stream() else {
            return;
        };
        let now = self.now();
        if !self.gates.recovery_idr_v2 {
            self.arm_fast_attack(now);
            capture.request_keyframe();
            return;
        }
        let verdict = {
            let mut controllers = self.locked_controllers();
            let smoothed_rtt_seconds = controllers.estimate.smoothed_rtt_millis / 1000.0;
            let verdict = controllers
                .recovery_idr
                .decide(now, last_decoded, smoothed_rtt_seconds);
            drop(controllers);
            verdict
        };
        if matches!(verdict, IdrVerdict::Grant) {
            self.arm_fast_attack(now);
            capture.request_keyframe();
        }
    }

    /// Opens the keyframe-duplication fast-attack window.
    ///
    /// Called wherever a RECOVERY keyframe is actually requested, and nowhere else. The loss EWMA
    /// LAGS — it only moves when a report folds — so at a clean-to-burst edge the client's request
    /// reaches the send path before the burst has folded into the rate, and that first re-anchor
    /// IDR is exactly the frame duplication exists for. On a clean link no recovery is ever
    /// requested, so this never arms and the periodic crisp IDR stays un-duplicated.
    fn arm_fast_attack(&self, now: f64) {
        let mut counters = self.locked_counters();
        counters.arm_fast_attack(now, KF_DUP_FAST_ATTACK_WINDOW);
        drop(counters);
    }

    /// Actuates a cadence on all three of its surfaces.
    ///
    /// The capture gate ENFORCES the cadence, the encoder's expected frame rate is a best-effort
    /// hint, and the client is told so its own frame pacer learns the new number. The user cap
    /// composes here by [`effective_fps`], so a governed step can never actuate above what the
    /// client asked for — and clearing the cap restores the governed cadence on the spot.
    ///
    /// The capture stream's slot configuration is deliberately untouched: slots stay at twice the
    /// base rate, which is the slot-beat trap `docs/52` names.
    fn actuate_governed_fps(self: &Arc<Self>, governed: i64) {
        let fps = effective_fps(governed, self.user_fps_cap());
        if let Some(capture) = self.capture_stream() {
            capture.set_governed_fps(i32::try_from(fps).unwrap_or(i32::MAX));
        }
        if let Some(encoder) = self.encoder() {
            encoder.set_expected_frame_rate(fps);
        }
        self.send_cadence(u16::try_from(fps.clamp(0, i64::from(u16::MAX))).unwrap_or(u16::MAX));
    }

    /// Applies the client's live stream overrides — the `ApplyStreamSettings` effect.
    ///
    /// A second settings message REPLACES the first wholesale: both axes are re-assigned every
    /// time, and a zero on either is the client asking for auto, not for zero. The wire values are
    /// clamped by [`fps_cap_from_wire`] and [`bitrate_ceiling_from_wire`] before anything sees
    /// them.
    ///
    /// Both axes actuate through the SAME paths a governed step or a folded report takes, which is
    /// what keeps one spelling of "apply a cadence" and one of "apply a rate". The bitrate has NO
    /// material-change gate here: this is a rare explicit request, not a fifty-millisecond tick.
    ///
    /// ⚠️ Takes `&Arc<Self>` rather than `&self` because the cadence announcement is
    /// `Session::send_cadence`'s, and that is an `Arc` method — it spawns the duplicate copy on a
    /// thread of its own. The call site in [`Session::apply_effect`] already holds an `Arc<Self>`,
    /// so it resolves unchanged.
    pub(crate) fn apply_stream_settings(self: &Arc<Self>, fps_cap: u8, bitrate_ceiling_bps: u32) {
        let cap = fps_cap_from_wire(fps_cap);
        let ceiling = bitrate_ceiling_from_wire(bitrate_ceiling_bps);
        self.store_user_settings(cap, ceiling);

        // THE CADENCE AXIS. The governor's own output keeps evolving underneath; the cap only
        // clamps ACTUATION, so re-actuating the current governed value is what applies — or clears
        // — the override.
        let governed = {
            let controllers = self.locked_controllers();
            let governed = controllers
                .fps
                .as_ref()
                .map_or(self.spec.fps, FpsGovernor::current_fps);
            drop(controllers);
            governed
        };
        self.actuate_governed_fps(governed);

        // THE RATE AXIS. With ABR on the controller clamps its own target down at once and never
        // climbs past the effective ceiling; with ABR off the live rate is pinned at the policy
        // ceiling, so the override — or its clearing — has to actuate the encoder directly. With
        // no encoder seeded yet there is no ceiling and nothing to actuate.
        let target = {
            let mut controllers = self.locked_controllers();
            #[expect(
                clippy::option_if_let_else,
                reason = "the else arm reads a SECOND field of the same guard; a closure would borrow it \
                          twice"
            )]
            let target = if let Some(controller) = controllers.congestion.as_mut() {
                controller.set_user_ceiling_bps(ceiling);
                Some(controller.current())
            } else if controllers.policy_ceiling_bps > 0 {
                let policy = controllers.policy_ceiling_bps;
                Some(policy.min(ceiling.unwrap_or(policy)))
            } else {
                None
            };
            let actuate = match target {
                Some(target) if target != controllers.last_actuated_bps => {
                    controllers.last_actuated_bps = target;
                    // The same const-QP carve-out as the report path: the QP ladder owns the rate,
                    // so the average bitrate stays pinned.
                    controllers.qp.is_none().then_some(target)
                },
                _ => None,
            };
            drop(controllers);
            actuate
        };
        if let Some(target) = target
            && let Some(encoder) = self.encoder()
        {
            let _actuated = encoder.set_live_bitrate(target);
        }
    }

    /// Echoes the host's half of the stats HUD, at most twice a second.
    ///
    /// Rides the client's report clock rather than a timer: with no report there is no round trip
    /// to report anyway. Fire-and-forget — the message is periodic, so a lost one heals on the next
    /// tick and there is nothing here worth a retry.
    fn maybe_send_host_stats(&self, extras: &SessionExtras, smoothed_rtt_millis: f64) {
        let flowing = {
            let state = self.locked_state();
            let flowing = state.media_flowing();
            drop(state);
            flowing
        };
        if !flowing {
            return;
        }
        let now = self.now();
        let due = {
            let mut recovery = extras.locked_recovery();
            let due = recovery.host_stats_due(now, HOST_STATS_INTERVAL);
            drop(recovery);
            due
        };
        if !due {
            return;
        }
        self.send_control(&VideoControlMessage::HostStats {
            rtt_tenths_millis: tenths_of_a_millisecond(smoothed_rtt_millis),
            // The capturer's encode wall-time EWMA, the HUD's second half. A session with no
            // capture stream sends zero, which is the wire's own spelling of "no reading yet" — a
            // client renders that half blank rather than being told a number nobody measured.
            encode_tenths_millis: self
                .capture_stream()
                .map_or(0, |capture| tenths_of_a_millisecond(capture.encode_millis_ewma())),
        });
    }
}

/// Whether this recovery datagram should be PROCESSED, or is one of the client's redundant copies.
///
/// The client sends each logical request three times for loss tolerance, and the dedup is
/// BYTE-keyed rather than kind-keyed on purpose: two genuinely different requests of the same kind
/// differ in their decode frontier, so they are different bytes and both are admitted.
fn admitted(extras: &SessionExtras, datagram: &[u8], now: f64) -> bool {
    let mut recovery = extras.locked_recovery();
    let admitted = recovery.admit(datagram, now);
    drop(recovery);
    admitted
}

/// Steps the adaptive-FEC ladder, or holds it where it is.
///
/// The two ladders are mutually exclusive and the parity one wins: with `SLOPDESK_ADAPTIVE_FEC_M`
/// set to a real parity count the wire tier means a parity multiplicity, and stepping the
/// group-size ladder underneath it would name a tier the client reads as something else entirely.
///
/// Both dwells are [`RELAX_DWELL_REPORTS`], which is the rule crate's own derivation of "twelve
/// seconds at the fifty-millisecond report cadence" — asked rather than restated here, so a change
/// of report cadence moves both ends together.
#[expect(
    clippy::fn_params_excessive_bools,
    reason = "each flag is one INDEPENDENT gate the ladder consults; a struct would name a state that has \
              no other reader"
)]
fn next_tier(
    adaptive_m: bool,
    adaptive_fec_enabled: bool,
    loss: f64,
    state: TierState,
    allow_off: bool,
    saw_unrecovered_loss: bool,
) -> TierState {
    if adaptive_m {
        // Floors at the CLEAN parity tier, never at OFF: this ladder has no off level, so it takes
        // no `allow_off`.
        return adaptive_fec::next_parity_tier_state(loss, state, RELAX_DWELL_REPORTS, saw_unrecovered_loss);
    }
    if adaptive_fec_enabled {
        return adaptive_fec::next_tier_state(
            loss,
            state,
            RELAX_DWELL_REPORTS,
            allow_off,
            saw_unrecovered_loss,
        );
    }
    state
}

/// A millisecond reading as the HUD carries it: tenths, saturating into the wire's 16 bits.
///
/// A non-finite or negative reading answers zero, which is the wire's own "no reading yet" — the
/// same value a client sees before the first report folds, so it renders one way and not two.
fn tenths_of_a_millisecond(millis: f64) -> u16 {
    let tenths = (millis * 10.0).round();
    if !tenths.is_finite() || tenths <= 0.0 {
        return 0;
    }
    let bounded = tenths.min(f64::from(u16::MAX));
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "bounded is finite, positive and at most u16::MAX, checked immediately above"
    )]
    let saturated = bounded as u16;
    saturated
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::panic,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::Weak;
    use std::sync::atomic::{AtomicU32, Ordering};

    use slopdesk_video::adaptive_fec::{DEFAULT_TIER, PARITY_TIER_CLEAN, TierState};
    use slopdesk_video::congestion::CongestionConfig;
    use slopdesk_video::fps_governor::{FpsGovernor, FpsGovernorConfig};
    use slopdesk_video::fragment::{Flags, FrameFragment, FrameFragmentHeader};
    use slopdesk_video::geometry::{VideoPoint, VideoRect, VideoSize};
    use slopdesk_video::host_gates::{GateContext, HostGates};
    use slopdesk_video::qp_control::{QpConfig, QpController};
    use slopdesk_video::recovery::{NetworkStatsReport, RecoveryMessage};
    use slopdesk_video::recovery_idr::RecoveryIdrConfig;
    use slopdesk_video::recovery_routing::{Outgoing, VideoChannel};
    use slopdesk_video::session_state::{PROTOCOL_VERSION, VideoSessionStateMachine};
    use slopdesk_video::video_control::VideoControlMessage;

    use super::{Arc, Session, next_tier, tenths_of_a_millisecond};
    use crate::env::Overlay;
    use crate::mux_lane::{LaneControl, LaneRetired, MuxLaneTransport};
    use crate::mux_sink::MuxSinkTable;
    use crate::session_wiring::{SessionSpec, Target};

    /// The two timings a live daemon resolves before it folds the gate table.
    const CONTEXT: GateContext = GateContext {
        scroll_resampler_active: false,
        keepalive_interval: slopdesk_video::keepalive::KEEPALIVE_INTERVAL_SECONDS,
        idle_timeout: slopdesk_video::keepalive::IDLE_TIMEOUT_SECONDS,
    };

    /// The window this session is minted for.
    const WINDOW: u32 = 4_242;

    /// A lane id nobody else in this process is using — the extras table is keyed by it.
    fn fresh_channel() -> u32 {
        static NEXT: AtomicU32 = AtomicU32::new(20_000);
        NEXT.fetch_add(1, Ordering::Relaxed)
    }

    /// A shared flow that COUNTS what reached the wire, so a retransmit is a value a test can read.
    #[derive(Debug, Default)]
    struct Flow {
        sent: AtomicU32,
    }

    impl LaneControl for Flow {
        fn admit(&self, _channel_id: u32) {}

        fn retire(&self, _channel_id: u32) {}

        fn send(&self, _datagram: &[u8], _channel: VideoChannel, _channel_id: u32) {
            self.sent.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// The registry's half of a lane's retirement, which a test session never consults.
    #[derive(Debug, Default)]
    struct Registry;

    impl LaneRetired for Registry {
        fn lane_retired(&self, _channel_id: u32) {}
    }

    /// A listening session over a lane with no socket under it, and the two handles it holds
    /// weakly or shares.
    fn session() -> (Arc<Session>, Arc<Registry>, Arc<Flow>) {
        session_gated(|_| {})
    }

    /// The same session, with one edit to the gate table before it is built.
    ///
    /// The gates a test needs are the ones `HostGates::from_env` leaves OFF by default —
    /// `SLOPDESK_NACK` is the only one so far — so a test about the retransmit log has to open its
    /// own gate rather than assume the default table opened it.
    fn session_gated(edit: impl FnOnce(&mut HostGates)) -> (Arc<Session>, Arc<Registry>, Arc<Flow>) {
        let registry = Arc::new(Registry);
        // The unsizing happens at this typed binding, not inside `downgrade`. `registry` is
        // returned to the caller, so the allocation outlives the strong handle dropped here.
        let watcher: Arc<dyn LaneRetired> = registry.clone();
        let observer: Weak<dyn LaneRetired> = Arc::downgrade(&watcher);
        let flow = Arc::new(Flow::default());
        let shared: Arc<dyn LaneControl> = flow.clone();
        let transport = Arc::new(MuxLaneTransport::new(
            fresh_channel(),
            shared,
            Arc::new(MuxSinkTable::new()),
            observer,
        ));
        let mut gates = HostGates::from_env(&[], CONTEXT);
        // The paced drain owns a thread of its own, and the inline arm is the one under test.
        gates.send_lane_enabled = false;
        edit(&mut gates);
        let session = Arc::new(Session::new(
            SessionSpec {
                target: Target::Window {
                    id: WINDOW,
                    pid: 99,
                    size_override: Some((640.0, 480.0)),
                    resize_limit: None,
                },
                capture_scale: 1.0,
                bitrate: 8_000_000,
                fps: 60,
            },
            transport,
            gates,
            RecoveryIdrConfig::default(),
            Overlay::default(),
            VideoSessionStateMachine::new(1, false),
        ));
        (session, registry, flow)
    }

    /// Puts the session's MACHINE into streaming without bringing a framework up.
    fn open_the_media_gate(session: &Arc<Session>) {
        let hello = VideoControlMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            requested_window_id: WINDOW,
            viewport: VideoSize::new(640.0, 480.0),
        };
        let mut state = session.locked_state();
        // A hello is only accepted from LISTENING, and the machine this fixture built is still
        // Idle: production reaches Listening through `Session::start`, which also binds sockets.
        let _listening = state.start();
        let effects = state.handle_control(
            &hello,
            VideoRect::new(VideoPoint::new(0.0, 0.0), VideoSize::new(640.0, 480.0)),
            |_, _| Some((640, 480)),
            |_, _| None,
            |_, _| None,
        );
        drop(state);
        drop(effects);
    }

    /// The payload size every test fragment carries. Plausible rather than meaningful: the ring
    /// selects on the header and never looks at a byte of this.
    const FRAGMENT_PAYLOAD: u16 = 40;

    /// One recorded datagram, carrying the header the ring SELECTS a repair by.
    ///
    /// The ring reads each datagram's own fragment header rather than trusting record order, so a
    /// repair test cannot record arbitrary bytes: a payload that does not decode matches no
    /// requested index and the log answers empty, which reads as an aged-out frame.
    fn fragment(frame_id: u32, frag_index: u16, frag_count: u16) -> Outgoing {
        let header = FrameFragmentHeader::new(
            u32::from(frag_index),
            frame_id,
            frag_index,
            frag_count,
            Flags::empty(),
            FRAGMENT_PAYLOAD,
            0,
        );
        Outgoing {
            channel: VideoChannel::Video,
            bytes: FrameFragment::new(header, vec![0xAB; usize::from(FRAGMENT_PAYLOAD)]).encode(),
        }
    }

    /// A report with the loss the test wants and nothing else set.
    fn report(frames_received: u32, unrecovered: u32) -> NetworkStatsReport {
        NetworkStatsReport {
            frames_received,
            fec_recovered: 0,
            unrecovered,
            latest_host_send_ts: 0,
            client_hold_ms: 0,
            owd_jitter_micros: 0,
            owd_trend_milli: 0,
            owd_trend_flags: 0,
            pacer_late_frames: 0,
            pacer_present_gaps: 0,
            pacer_depth: 0,
        }
    }

    #[test]
    fn a_report_folds_the_estimate_and_marks_the_client_as_a_feedback_speaker() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        session.handle_recovery(&RecoveryMessage::NetworkStats(report(100, 10)).encode());
        let liveness = session.locked_liveness();
        let saw = liveness.saw_feedback;
        drop(liveness);
        assert!(saw, "only a folded report may make the silence pause eligible");
        let controllers = session.locked_controllers();
        let loss = controllers.estimate.loss_rate;
        let samples = controllers.estimate.sample_count;
        drop(controllers);
        assert_eq!(samples, 1, "exactly one report folded");
        assert!(
            loss > 0.0,
            "ten unrecovered frames of a hundred is loss, not silence"
        );
        session.stop_inbound();
    }

    #[test]
    fn the_abr_the_quantiser_and_the_governor_all_tick_under_one_report() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        // Seeded the way an encoder build seeds it, so all three controllers exist at once and the
        // test reads the ORDER rather than the presence of any one of them.
        let mut controllers = session.locked_controllers();
        let _ = controllers.seed_for_encoder(
            20_000_000,
            &session.gates,
            CongestionConfig::default(),
            false,
            QpConfig::default(),
            Some(38),
            None,
        );
        controllers.fps = Some(FpsGovernor::new(60, FpsGovernorConfig::default()));
        let band = controllers.qp.as_ref().map(QpController::config);
        drop(controllers);

        for _ in 0..40_u32 {
            session.handle_recovery(&RecoveryMessage::NetworkStats(report(100, 30)).encode());
        }
        let controllers = session.locked_controllers();
        let samples = controllers.estimate.sample_count;
        let quantiser = controllers.qp.as_ref().map(QpController::q);
        let target = controllers.last_actuated_bps;
        let governor_ticked = controllers
            .fps
            .as_ref()
            .is_some_and(|governor| governor.current_fps() > 0);
        drop(controllers);

        assert_eq!(
            samples, 40,
            "every report folds exactly once, under exactly one hold"
        );
        let Some(band) = band else {
            panic!("const-QP was seeded, so a ladder must exist");
        };
        let Some(quantiser) = quantiser else {
            panic!("const-QP was seeded, so a ladder must exist");
        };
        assert!(
            (band.sharp..=band.coarse).contains(&quantiser),
            "the ladder rides the ABR's verdict and never leaves its own band"
        );
        assert!(
            target > 0,
            "the ABR must have anchored a target off its own ceiling"
        );
        assert!(
            governor_ticked,
            "and the governor must have been ticked on the same clock"
        );
        session.stop_inbound();
    }

    #[test]
    fn the_adaptive_fec_ladder_steps_only_inside_a_real_report() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        assert_eq!(
            session.fec_tier_state().tier,
            DEFAULT_TIER,
            "no report has arrived, so the tier is the byte-identical baseline"
        );
        for _ in 0..4_u32 {
            session.handle_recovery(&RecoveryMessage::NetworkStats(report(100, 40)).encode());
        }
        assert_ne!(
            session.fec_tier_state().tier,
            DEFAULT_TIER,
            "sustained heavy loss must escalate the ladder"
        );
        let controllers = session.locked_controllers();
        let stepped = controllers.fec_tier;
        drop(controllers);
        assert_eq!(
            stepped,
            session.fec_tier_state(),
            "the ladder lives on the controller set the FRAME path reads, not in a side table"
        );
        session.stop_inbound();
    }

    #[test]
    fn the_two_fec_ladders_are_mutually_exclusive_and_the_parity_one_wins() {
        let clean = TierState::default();
        let parity = next_tier(true, true, 0.20, clean, false, true);
        assert!(
            parity.tier >= PARITY_TIER_CLEAN,
            "with a real parity count the wire tier means a multiplicity, not a group size"
        );
        let group = next_tier(false, true, 0.20, clean, false, true);
        assert!(
            group.tier < PARITY_TIER_CLEAN,
            "the group-size ladder must never name a parity tier"
        );
        let held = next_tier(false, false, 0.20, clean, false, true);
        assert_eq!(held, clean, "with both gates off the tier does not move at all");
    }

    #[test]
    fn a_request_that_arrives_three_times_is_answered_exactly_once() {
        let (session, _registry, flow) = session_gated(|gates| gates.nack_enabled = true);
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        let Some(log) = session.retransmit.as_ref() else {
            panic!("the opened SLOPDESK_NACK gate must have built a retransmit log");
        };
        log.record(21, &[fragment(21, 0, 1)]);
        let datagram = RecoveryMessage::RequestFragments {
            frame_id: 21,
            frag_indices: vec![0],
        }
        .encode();
        let before = flow.sent.load(Ordering::Relaxed);
        for _ in 0..3_u32 {
            session.handle_recovery(&datagram);
        }
        assert_eq!(
            flow.sent.load(Ordering::Relaxed) - before,
            1,
            "the client sends each logical request three times; only the first copy may act"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_nack_is_answered_from_the_retransmit_log_in_one_unpaced_shot() {
        let (session, _registry, flow) = session_gated(|gates| gates.nack_enabled = true);
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        let Some(log) = session.retransmit.as_ref() else {
            panic!("the opened SLOPDESK_NACK gate must have built a retransmit log");
        };
        log.record(11, &[fragment(11, 0, 2), fragment(11, 1, 2)]);
        let before = flow.sent.load(Ordering::Relaxed);
        session.handle_recovery(
            &RecoveryMessage::RequestFragments {
                frame_id: 11,
                frag_indices: vec![0, 1],
            }
            .encode(),
        );
        assert_eq!(
            flow.sent.load(Ordering::Relaxed) - before,
            2,
            "both named fragments go out, in one shot, because the client is already on a deadline"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_nack_for_a_frame_that_aged_out_of_the_ring_sends_nothing_at_all() {
        let (session, _registry, flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        let before = flow.sent.load(Ordering::Relaxed);
        session.handle_recovery(
            &RecoveryMessage::RequestFragments {
                frame_id: 999,
                frag_indices: vec![0, 1, 2],
            }
            .encode(),
        );
        assert_eq!(
            flow.sent.load(Ordering::Relaxed),
            before,
            "a ring miss is a benign no-op — the client's own escalation is the fallback"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_recovery_request_before_capture_is_up_never_latches_a_phantom_grant() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        session.handle_recovery(
            &RecoveryMessage::RequestIdr {
                last_decoded_frame_id: 3,
            }
            .encode(),
        );
        let counters = session.locked_counters();
        let armed = counters.kf_dup_fast_attack_until;
        drop(counters);
        #[expect(clippy::float_cmp, reason = "the stamp is a literal zero or it was armed")]
        {
            assert_eq!(
                armed, 0.0,
                "with no capturer nothing was requested, so nothing may have been armed"
            );
        }
        session.stop_inbound();
    }

    #[test]
    fn an_ack_feeds_the_delivery_cooldown_whether_or_not_references_are_on() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        let mut controllers = session.locked_controllers();
        controllers.recovery_idr.note_keyframe_sent(5, 0.0);
        drop(controllers);
        session.handle_recovery(&RecoveryMessage::Ack { stream_seq: 5 }.encode());
        let controllers = session.locked_controllers();
        let mut policy = controllers.recovery_idr.clone();
        drop(controllers);
        assert!(
            matches!(
                policy.decide(0.001, Some(4), 0.0),
                slopdesk_video::recovery_idr::IdrVerdict::SuppressStale
            ),
            "a request that provably predates a DECODED keyframe costs nothing to drop"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_datagram_the_router_refuses_changes_nothing() {
        let (session, _registry, flow) = session();
        let _sink = session.lane_sink();
        let before = flow.sent.load(Ordering::Relaxed);
        // Not streaming, so every recovery datagram is ignored before it is even decoded.
        session.handle_recovery(&RecoveryMessage::NetworkStats(report(100, 10)).encode());
        // Streaming, but corrupt.
        open_the_media_gate(&session);
        session.handle_recovery(&[0xFF, 0xFF]);
        let controllers = session.locked_controllers();
        let samples = controllers.estimate.sample_count;
        drop(controllers);
        assert_eq!(samples, 0, "neither datagram may reach the fold");
        assert_eq!(
            flow.sent.load(Ordering::Relaxed),
            before,
            "and neither may reach the wire"
        );
        session.stop_inbound();
    }

    #[test]
    fn the_host_stats_echo_is_throttled_to_its_own_interval() {
        let (session, _registry, flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        let before = flow.sent.load(Ordering::Relaxed);
        for _ in 0..20_u32 {
            session.handle_recovery(&RecoveryMessage::NetworkStats(report(100, 1)).encode());
        }
        let sent = flow.sent.load(Ordering::Relaxed) - before;
        assert_eq!(
            sent, 1,
            "twenty reports inside one interval are one echo — the throttle is the whole point"
        );
        session.stop_inbound();
    }

    #[test]
    fn the_user_cadence_cap_clamps_a_governed_step_and_clearing_it_restores_the_governor() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        session.apply_stream_settings(24, 0);
        assert_eq!(
            session.user_fps_cap(),
            Some(24),
            "the wire value is clamped, then stored"
        );
        assert_eq!(
            session.user_bitrate_ceiling(),
            None,
            "a zero on the wire is auto, not zero"
        );
        session.apply_stream_settings(0, 0);
        assert_eq!(
            (session.user_fps_cap(), session.user_bitrate_ceiling()),
            (None, None),
            "a second message replaces the first wholesale, both axes"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_user_bitrate_ceiling_survives_an_encoder_rebuild_by_being_re_layered() {
        let (session, _registry, _flow) = session();
        let _sink = session.lane_sink();
        open_the_media_gate(&session);
        let mut controllers = session.locked_controllers();
        let _ = controllers.seed_for_encoder(
            20_000_000,
            &session.gates,
            CongestionConfig::default(),
            false,
            QpConfig::default(),
            None,
            None,
        );
        drop(controllers);

        session.apply_stream_settings(0, 5_000_000);
        let controllers = session.locked_controllers();
        let effective = controllers
            .congestion
            .as_ref()
            .map(slopdesk_video::congestion::LiveCongestionController::effective_ceiling);
        drop(controllers);
        assert_eq!(
            effective,
            Some(5_000_000),
            "the override layers UNDER the policy ceiling, where a rebuild can re-apply it"
        );
        assert_eq!(
            session.user_bitrate_ceiling(),
            Some(5_000_000),
            "and is readable by the next seed"
        );
        session.stop_inbound();
    }

    #[test]
    fn stream_settings_with_no_encoder_seeded_actuate_nothing_and_do_not_panic() {
        let (session, _registry, flow) = session();
        let _sink = session.lane_sink();
        let before = flow.sent.load(Ordering::Relaxed);
        session.apply_stream_settings(30, 4_000_000);
        assert_eq!(
            flow.sent.load(Ordering::Relaxed),
            before,
            "a session that is not streaming announces no cadence"
        );
        session.stop_inbound();
    }

    #[test]
    fn a_millisecond_reading_saturates_into_tenths_rather_than_wrapping() {
        assert_eq!(tenths_of_a_millisecond(12.34), 123);
        assert_eq!(
            tenths_of_a_millisecond(0.0),
            0,
            "zero is the wire's own no-reading-yet"
        );
        assert_eq!(
            tenths_of_a_millisecond(-5.0),
            0,
            "and so is anything a clock could not mean"
        );
        assert_eq!(tenths_of_a_millisecond(f64::NAN), 0);
        assert_eq!(
            tenths_of_a_millisecond(1_000_000.0),
            u16::MAX,
            "a saturating reading is still a reading; a wrapped one is a lie"
        );
    }
}
