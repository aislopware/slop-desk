//! The RECOVERY-IDR delivery-keyed cooldown scenario.
//!
//! Four phases. (A) the double-loss freeze: both duplicate copies of the first recovery keyframe
//! die, and the delivery-keyed policy must let the client's second request through where a
//! sent-keyed 500 ms window cannot. (B) the storm cap: six requests inside 350 ms must yield at
//! most a couple of grants, and the bucket must refill. (C) stale suppression: a delayed request
//! composed BEFORE a keyframe the client acked must be dropped, and must cost no token. (D) the
//! real-hardware invariant: a grant converts to an actual intra frame on the next encode, and the
//! frames before it stay deltas.
//!
//! A, B and C are pure policy traces on a virtual clock. Only D touches the encoder.

// `redundant_pub_crate` wants `pub` on every item in this private module, and rustc's
// `unreachable_pub` — denied by the manifest — refuses exactly that. The conflict is clippy's own,
// recorded in its documentation; the stricter of the two wins, one module at a time.
#![expect(
    clippy::redundant_pub_crate,
    reason = "conflicts with the denied `unreachable_pub`"
)]

use slopdesk_video::decode_admission::DecodeFrontier;
use slopdesk_video::encoder_config::DEFAULT_BITRATE;
use slopdesk_video::ltr::{LtrController, RecoveryAction, RecoveryRequestKind};
use slopdesk_video::recovery::{LtrEscalationTracker, RecoveryMessage, RecoveryPolicy};
use slopdesk_video::recovery_idr::{IdrVerdict, RecoveryIdrConfig, RecoveryIdrPolicy};
use slopdesk_video::recovery_routing::{RecoveryDecision, route_recovery};

use crate::rig::{Encoder, Source};

/// Which admission rule the trace runs under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GateMode {
    /// The delivery-keyed policy.
    V2,
    /// The legacy sent-keyed 500 ms window.
    Legacy,
}

/// What one double-loss trace measured.
#[derive(Clone, Copy, Debug)]
pub(crate) struct TraceResult {
    /// Virtual milliseconds from the loss to a recovery keyframe decoding.
    pub unfreeze_ms: f64,
    /// How many logical requests the client sent.
    pub requests: usize,
    /// Whether the SECOND request was granted — the casualty bypass, in one bit.
    pub second_granted: bool,
}

/// What the whole scenario measured.
#[derive(Clone, Copy, Debug)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each is one independently-measured verdict bit; collapsing them would lose which one failed"
)]
pub(crate) struct RecoveryIdrResult {
    /// Phase A: the delivery-keyed unfreeze.
    pub v2_unfreeze_ms: f64,
    /// Phase A: the legacy one, on the identical trace.
    pub legacy_unfreeze_ms: f64,
    /// Phase A: whether the second request was granted under the delivery-keyed rule.
    pub v2_second_request_granted: bool,
    /// Phase A: requests under it.
    pub v2_requests: usize,
    /// Phase A: requests under the legacy rule.
    pub legacy_requests: usize,
    /// Phase B: grants under the storm.
    pub storm_grants: usize,
    /// Phase B: suppressions under it.
    pub storm_suppressed: usize,
    /// Phase B: whether every suppression was one this phase can actually produce.
    pub storm_verdicts_ok: bool,
    /// Phase B: whether the bucket admitted again a refill interval later.
    pub refill_grant_after: bool,
    /// Phase C: whether the stale request was suppressed.
    pub stale_suppressed: bool,
    /// Phase C: whether that suppression spent no token.
    pub stale_spent_no_token: bool,
    /// Phase D: whether the grant produced a real intra frame.
    pub grant_yielded_keyframe: bool,
    /// Phase D: whether the frames before it stayed deltas.
    pub pre_grant_frames_were_deltas: bool,
}

impl Default for RecoveryIdrResult {
    fn default() -> Self {
        Self {
            v2_unfreeze_ms: f64::INFINITY,
            legacy_unfreeze_ms: f64::INFINITY,
            v2_second_request_granted: false,
            v2_requests: 0,
            legacy_requests: 0,
            storm_grants: 0,
            storm_suppressed: 0,
            storm_verdicts_ok: true,
            refill_grant_after: false,
            stale_suppressed: false,
            stale_spent_no_token: false,
            grant_yielded_keyframe: false,
            pre_grant_frames_were_deltas: true,
        }
    }
}

/// The host side of one trace: everything `host_receive` mutates.
struct HostSide {
    /// The delivery-keyed policy, consulted in `V2` mode.
    policy: RecoveryIdrPolicy,
    /// The long-term-reference controller. Fresh, so a refresh request folds to a keyframe.
    ltr: LtrController,
    /// The next keyframe id to hand out.
    next_keyframe: u32,
    /// How many keyframes have been sent.
    sent: usize,
    /// When the last one was emitted — the legacy rule's whole state.
    last_emit: Option<f64>,
}

impl HostSide {
    /// Whether this request earns a keyframe under `mode`.
    fn admit(&mut self, mode: GateMode, last: Option<u32>, now: f64, rtt: f64) -> bool {
        match mode {
            GateMode::V2 => self.policy.decide(now, last, rtt) == IdrVerdict::Grant,
            GateMode::Legacy => self.last_emit.is_none_or(|emit| now - emit >= 0.5),
        }
    }

    /// Routes one recovery datagram in at `arrive_at`.
    ///
    /// Answers the client's decode time when a granted keyframe actually DELIVERS. The FIRST
    /// recovery keyframe loses both of its duplicate copies — the scripted burst that is the whole
    /// point of the trace — so it grants but never lands.
    fn receive(&mut self, mode: GateMode, wire: &[u8], arrive_at: f64, rtt: f64) -> Option<f64> {
        let granted = match route_recovery(wire, true) {
            RecoveryDecision::ForceKeyframe {
                last_decoded_frame_id,
            } => self.admit(mode, last_decoded_frame_id, arrive_at, rtt),
            RecoveryDecision::RefreshLtr {
                last_decoded_frame_id,
            } => {
                self.ltr.recovery_decision(RecoveryRequestKind::LtrRefresh, true) == RecoveryAction::Idr
                    && self.admit(mode, last_decoded_frame_id, arrive_at, rtt)
            },
            _ => false,
        };
        if !granted {
            return None;
        }
        let sent_at = arrive_at + 0.010;
        self.policy.note_keyframe_sent(self.next_keyframe, sent_at);
        self.next_keyframe = self.next_keyframe.wrapping_add(1);
        self.last_emit = Some(sent_at);
        self.sent = self.sent.saturating_add(1);
        if self.sent == 1 {
            return None;
        }
        Some(sent_at + rtt / 2.0)
    }
}

/// One double-loss recovery trace through the REAL components.
#[must_use]
pub(crate) fn simulate_double_loss(mode: GateMode, rtt: f64, verbose: bool) -> TraceResult {
    let one_way = rtt / 2.0;
    let policy = RecoveryPolicy::default();
    let mut escalation = LtrEscalationTracker::new();
    let mut frontier = DecodeFrontier::new();
    frontier.note_decoded(49);
    let mut host = HostSide {
        policy: RecoveryIdrPolicy::new(RecoveryIdrConfig::default()),
        ltr: LtrController::new(),
        next_keyframe: 100,
        sent: 0,
        last_emit: None,
    };
    let mut requests = 1_usize;
    let mut second_granted = false;
    let mut unfreeze: Option<f64> = None;

    // t = 0: frame 50 is declared unrecoverable, so the client sends the real signal-recovery
    // shape — an LTR-refresh request carrying its decode frontier.
    escalation.note_loss(50);
    escalation.note_request_sent(0.0);
    let initial = RecoveryPolicy::initial_request(50, 50, frontier.wire_value());
    if let Some(decode_at) = host.receive(mode, &initial.encode(), one_way, rtt) {
        unfreeze = Some(decode_at);
    }

    // The client re-escalates on its own clock until a keyframe decodes. Capped at two seconds,
    // which is longer than any verdict here cares about.
    let mut now = 0.0_f64;
    while unfreeze.is_none() && now < 2.0 {
        now += 0.005;
        if !escalation.should_escalate(now, rtt, &policy, false) {
            continue;
        }
        requests = requests.saturating_add(1);
        escalation.note_request_sent(now);
        escalation.note_escalated(now);
        let before = host.sent;
        let wire = RecoveryMessage::RequestIdr {
            last_decoded_frame_id: frontier.wire_value(),
        }
        .encode();
        if let Some(decode_at) = host.receive(mode, &wire, now + one_way, rtt) {
            unfreeze = Some(decode_at);
        }
        if requests == 2 && host.sent > before {
            second_granted = true;
        }
        if verbose {
            println!(
                "      [{}] request #{requests} at t={:.0}ms → {}",
                if mode == GateMode::V2 { "v2    " } else { "legacy" },
                now * 1000.0,
                if host.sent > before {
                    format!("GRANT (kf #{})", host.sent)
                } else {
                    "suppressed".to_owned()
                },
            );
        }
    }
    TraceResult {
        unfreeze_ms: unfreeze.unwrap_or(2.0) * 1000.0,
        requests,
        second_granted,
    }
}

/// The four-phase scenario.
#[must_use]
pub(crate) fn run(verbose: bool) -> RecoveryIdrResult {
    let mut result = RecoveryIdrResult::default();

    // ── Phase A: the double-loss freeze, both rules on the identical trace ──
    let v2 = simulate_double_loss(GateMode::V2, 0.05, verbose);
    let legacy = simulate_double_loss(GateMode::Legacy, 0.05, verbose);
    result.v2_unfreeze_ms = v2.unfreeze_ms;
    result.legacy_unfreeze_ms = legacy.unfreeze_ms;
    result.v2_second_request_granted = v2.second_granted;
    result.v2_requests = v2.requests;
    result.legacy_requests = legacy.requests;

    // ── Phase B: the storm cap — six rapid requests through the REAL wire and router ──
    {
        let mut policy = RecoveryIdrPolicy::new(RecoveryIdrConfig::default());
        let mut next_keyframe = 500_u32;
        // A grant puts its keyframe on the wire 30 ms later.
        let mut pending_service: Option<f64> = None;
        for now in [0.0, 0.02, 0.05, 0.1, 0.2, 0.35] {
            if let Some(due) = pending_service
                && now >= due
            {
                policy.note_keyframe_sent(next_keyframe, due);
                next_keyframe = next_keyframe.wrapping_add(1);
                pending_service = None;
            }
            // Always behind, so the request is never itself stale.
            let wire = RecoveryMessage::RequestIdr {
                last_decoded_frame_id: 400,
            }
            .encode();
            let RecoveryDecision::ForceKeyframe {
                last_decoded_frame_id,
            } = route_recovery(&wire, true)
            else {
                continue;
            };
            match policy.decide(now, last_decoded_frame_id, 0.05) {
                IdrVerdict::Grant => {
                    result.storm_grants = result.storm_grants.saturating_add(1);
                    pending_service = Some(now + 0.03);
                },
                IdrVerdict::SuppressGrantPending
                | IdrVerdict::SuppressRateLimited
                | IdrVerdict::SuppressInFlight => {
                    result.storm_suppressed = result.storm_suppressed.saturating_add(1);
                },
                // Nothing was acked in this phase, so a stale verdict is impossible here.
                IdrVerdict::SuppressStale => result.storm_verdicts_ok = false,
            }
        }
        if let Some(due) = pending_service {
            policy.note_keyframe_sent(next_keyframe, due);
        }
        // A refill interval later the bucket must admit again — the sustained rate is unchanged.
        result.refill_grant_after = policy.decide(1.0, Some(400), 0.05) == IdrVerdict::Grant;
    }

    // ── Phase C: stale suppression — the decode acknowledgement over the REAL wire ──
    {
        let mut policy = RecoveryIdrPolicy::new(RecoveryIdrConfig::default());
        policy.note_keyframe_sent(200, 0.0);
        if let RecoveryDecision::Ack { stream_seq } =
            route_recovery(&RecoveryMessage::Ack { stream_seq: 200 }.encode(), true)
        {
            policy.note_keyframe_delivered(stream_seq);
        }
        let tokens_before = policy.available_tokens();
        // A delayed or reordered pre-keyframe request, far past any grace window.
        result.stale_suppressed = policy.decide(1.0, Some(199), 0.05) == IdrVerdict::SuppressStale;
        // NOT an epsilon compare: a suppression that spends nothing leaves the count bit-identical,
        // and anything else is the bug this phase exists to catch.
        #[expect(
            clippy::float_cmp,
            reason = "bit-exact ON PURPOSE: a suppression that spends nothing leaves the count identical"
        )]
        {
            result.stale_spent_no_token = policy.available_tokens() == tokens_before;
        }
    }

    // ── Phase D: a grant converts to a REAL keyframe on the next hardware encode ──
    {
        let mut policy = RecoveryIdrPolicy::new(RecoveryIdrConfig::default());
        let Ok(encoder) = Encoder::create(false, false, DEFAULT_BITRATE) else {
            println!("  recovery-idr encoder create FAILED");
            return result;
        };
        let Ok(source) = Source::create(false) else {
            return result;
        };
        let mut force = false;
        let mut forced_next = false;
        for index in 0..20_usize {
            source.paint(index, false);
            encoder.encode_live(&source, index, force);
            encoder.complete_frames();
            for emitted in encoder.drain() {
                if forced_next {
                    result.grant_yielded_keyframe = emitted.keyframe;
                    forced_next = false;
                } else if index > 0 && index < 10 && emitted.keyframe {
                    result.pre_grant_frames_were_deltas = false;
                }
            }
            force = false;
            if index == 9 {
                // The request arrives mid-stream. A fresh bucket grants, and the grant latches a
                // forced keyframe for the NEXT encode — the capturer's own latch, in one bool.
                if policy.decide(100.0, Some(3), 0.05) == IdrVerdict::Grant {
                    force = true;
                    forced_next = true;
                }
            }
        }
    }
    result
}
