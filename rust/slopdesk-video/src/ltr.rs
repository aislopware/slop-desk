//! Long-term-reference bookkeeping: which cheap re-anchor the host is ALLOWED to send.
//!
//! A low-latency HEVC encoder session can emit frames carrying a long-term-reference
//! acknowledgement token, which lets a client that lost frames be recovered with a cheap P-frame
//! referencing an acknowledged long-term reference instead of a full IDR — no decoder flush, a
//! fraction of the bytes.
//!
//! ## The acked-only invariant
//!
//! A forced refresh may ONLY reference a long-term reference the client DEFINITELY holds.
//! Referencing a lost or un-acked one makes the recovery frame depend on a frame the client lacks,
//! which is persistent corruption until an IDR — strictly worse than the IDR it saved. So a token
//! enters the acknowledged set exclusively through [`LtrController::ack_frame`], which the host
//! calls only on a client ack, and the client sends that only after it has SUCCESSFULLY DECODED the
//! flagged frame. Two nets then stack: this controller's gate returns [`RecoveryAction::Idr`] when
//! nothing is acked, and the encoder's own contract emits an IDR if no long-term reference has been
//! acknowledged.
//!
//! Pure and deterministic — no clock, no I/O — and bounded on every dimension: both the frame map
//! and the acknowledged set evict oldest, so a long stream, an ack flood, or unknown and duplicate
//! ack ids can never grow memory.

use std::collections::BTreeMap;

/// The recovery a client request should trigger.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryAction {
    /// A forced refresh: a cheap P-frame against an ACKNOWLEDGED long-term reference the client
    /// definitely holds, with no decoder flush. Only ever returned when the acked-only invariant
    /// holds.
    LtrRefresh,
    /// A full IDR keyframe — the guaranteed, heavier re-anchor. The safe fallback whenever LTR is
    /// off or nothing has been acknowledged yet, and always for an explicit IDR request.
    Idr,
}

/// The kind of client recovery request driving the decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryRequestKind {
    /// Eligible for a refresh under the acked-only gate.
    LtrRefresh,
    /// The guaranteed-recovery escalation: always a real IDR.
    Idr,
}

/// The long-term-reference controller.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LtrController {
    /// Frame id to acknowledgement token, for emitted frames awaiting a client ack.
    frame_tokens: BTreeMap<u32, i64>,
    /// Insertion order of [`Self::frame_tokens`], oldest first, driving the bounded eviction.
    frame_order: Vec<u32>,
    /// The tokens the client has acknowledged, oldest to newest. Non-empty means a refresh may
    /// reference one.
    acknowledged_tokens: Vec<i64>,
}

impl LtrController {
    /// How many frame-to-token mappings are retained for ack look-up.
    ///
    /// Past this a recorded frame is evicted and a later ack for it is a safe no-op. Roughly one
    /// flagged frame per heartbeat, crisp re-anchor or recovery, so this covers a generous window.
    pub const FRAME_TOKEN_CAP: usize = 64;

    /// How many acknowledged tokens are retained, keeping the most recent. A refresh references the
    /// newest acked reference, so a small set suffices.
    pub const ACKNOWLEDGED_TOKEN_CAP: usize = 8;

    /// A controller with nothing recorded and nothing acknowledged.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records that the encoder emitted a long-term-reference frame carrying `token`.
    ///
    /// Insertion-ordered, evicting the oldest past the cap. Idempotent on a repeated id: the token
    /// is updated and the place kept — frame ids are monotonic, so this is essentially never hit.
    pub fn record_ltr_frame(&mut self, frame_id: u32, token: i64) {
        if self.frame_tokens.insert(frame_id, token).is_none() {
            self.frame_order.push(frame_id);
        }
        while self.frame_order.len() > Self::FRAME_TOKEN_CAP {
            let evicted = self.frame_order.remove(0);
            self.frame_tokens.remove(&evicted);
        }
    }

    /// Folds a client acknowledgement of `frame_id` — the ack field carries a FRAME id, not a
    /// stream sequence — returning the token to stage onto the encoder.
    ///
    /// An unknown, already-evicted or duplicate id returns `None`: a safe no-op, never a crash and
    /// never unbounded growth. An already-acked token moves to the newest slot, so eviction drops
    /// the genuinely stalest one.
    pub fn ack_frame(&mut self, frame_id: u32) -> Option<i64> {
        let token = *self.frame_tokens.get(&frame_id)?;
        self.acknowledged_tokens.retain(|held| *held != token);
        self.acknowledged_tokens.push(token);
        while self.acknowledged_tokens.len() > Self::ACKNOWLEDGED_TOKEN_CAP {
            self.acknowledged_tokens.remove(0);
        }
        Some(token)
    }

    /// The acknowledged tokens, oldest to newest, to feed the encoder.
    #[must_use]
    pub fn acknowledged_tokens(&self) -> &[i64] {
        &self.acknowledged_tokens
    }

    /// The recorded frame ids in insertion order, oldest first.
    ///
    /// Introspection, for a caller that has to show the eviction happened without keeping a second
    /// copy of the map to show it from.
    #[must_use]
    pub fn frame_order(&self) -> &[u32] {
        &self.frame_order
    }

    /// The token recorded for `frame_id`, if it has not been evicted.
    #[must_use]
    pub fn token_for(&self, frame_id: u32) -> Option<i64> {
        self.frame_tokens.get(&frame_id).copied()
    }

    /// Whether ANY token has been acknowledged — the gate's positive signal.
    #[must_use]
    pub const fn has_acked_token(&self) -> bool {
        !self.acknowledged_tokens.is_empty()
    }

    /// Invalidates all acked-token and frame-map state.
    ///
    /// The host MUST call this whenever it rebuilds the encoder session — bring-up, an in-session
    /// resize, or a resize-failure rebuild. A fresh session holds ZERO acknowledged long-term
    /// references, so the acknowledged set has to be cleared in lockstep: a token acked against the
    /// destroyed session would otherwise keep the gate open and issue a refresh against a reference
    /// the new session never had, collapsing the two-net stack to one. The frame map goes too,
    /// because those tokens belong to the dead session and a late ack for one must not re-open the
    /// gate.
    pub fn reset(&mut self) {
        self.frame_tokens.clear();
        self.frame_order.clear();
        self.acknowledged_tokens.clear();
    }

    /// THE recovery decision.
    ///
    /// An IDR request always forces a real IDR — the guaranteed escalation must never degrade to a
    /// refresh. A refresh request becomes one ONLY when LTR is enabled AND at least one token has
    /// been acknowledged; otherwise it falls back to an IDR, exactly as when LTR is off.
    #[must_use]
    pub fn recovery_decision(&self, request: RecoveryRequestKind, has_enable_ltr: bool) -> RecoveryAction {
        if request == RecoveryRequestKind::LtrRefresh && has_enable_ltr && self.has_acked_token() {
            RecoveryAction::LtrRefresh
        } else {
            RecoveryAction::Idr
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{LtrController, RecoveryAction, RecoveryRequestKind};

    /// The whole point of the type: nothing acked means nothing cheap.
    #[test]
    fn a_refresh_needs_an_acknowledged_reference() {
        let mut controller = LtrController::new();
        assert_eq!(
            controller.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
            RecoveryAction::Idr,
            "nothing acked yet",
        );
        controller.record_ltr_frame(10, 0xAA);
        assert_eq!(
            controller.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
            RecoveryAction::Idr,
            "emitting is not acknowledging",
        );
        assert_eq!(controller.ack_frame(10), Some(0xAA));
        assert_eq!(
            controller.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
            RecoveryAction::LtrRefresh,
        );
        assert_eq!(
            controller.recovery_decision(RecoveryRequestKind::LtrRefresh, false),
            RecoveryAction::Idr,
            "LTR off is the same fallback",
        );
    }

    #[test]
    fn an_idr_request_never_degrades_to_a_refresh() {
        let mut controller = LtrController::new();
        controller.record_ltr_frame(10, 0xAA);
        controller.ack_frame(10);
        assert_eq!(
            controller.recovery_decision(RecoveryRequestKind::Idr, true),
            RecoveryAction::Idr,
        );
    }

    #[test]
    fn an_unknown_ack_is_a_no_op() {
        let mut controller = LtrController::new();
        assert_eq!(controller.ack_frame(99), None);
        assert!(
            !controller.has_acked_token(),
            "an unknown id must not open the gate"
        );
    }

    #[test]
    fn a_repeated_ack_moves_the_token_to_newest_rather_than_duplicating() {
        let mut controller = LtrController::new();
        controller.record_ltr_frame(1, 100);
        controller.record_ltr_frame(2, 200);
        controller.ack_frame(1);
        controller.ack_frame(2);
        controller.ack_frame(1);
        assert_eq!(controller.acknowledged_tokens(), [200, 100]);
    }

    #[test]
    fn both_stores_are_bounded() {
        let mut controller = LtrController::new();
        let overflow = u32::try_from(LtrController::FRAME_TOKEN_CAP).unwrap_or(64) + 10;
        for frame_id in 0..overflow {
            controller.record_ltr_frame(frame_id, i64::from(frame_id));
        }
        assert_eq!(controller.ack_frame(0), None, "the oldest mapping was evicted");
        assert_eq!(controller.ack_frame(overflow - 1), Some(i64::from(overflow - 1)));

        for frame_id in 1..overflow {
            controller.ack_frame(frame_id);
        }
        assert_eq!(
            controller.acknowledged_tokens().len(),
            LtrController::ACKNOWLEDGED_TOKEN_CAP,
        );
    }

    /// A rebuilt encoder session holds no references, so the gate has to re-arm.
    #[test]
    fn a_reset_re_arms_the_gate_and_forgets_the_dead_sessions_frames() {
        let mut controller = LtrController::new();
        controller.record_ltr_frame(10, 0xAA);
        controller.ack_frame(10);
        controller.reset();
        assert!(!controller.has_acked_token());
        assert_eq!(
            controller.recovery_decision(RecoveryRequestKind::LtrRefresh, true),
            RecoveryAction::Idr,
        );
        assert_eq!(
            controller.ack_frame(10),
            None,
            "a late ack must not re-open the gate"
        );
    }

    #[test]
    fn re_recording_a_frame_id_updates_the_token_and_keeps_its_place() {
        let mut controller = LtrController::new();
        controller.record_ltr_frame(10, 0xAA);
        controller.record_ltr_frame(10, 0xBB);
        assert_eq!(controller.ack_frame(10), Some(0xBB));
        assert_eq!(controller.acknowledged_tokens(), [0xBB]);
    }
}
