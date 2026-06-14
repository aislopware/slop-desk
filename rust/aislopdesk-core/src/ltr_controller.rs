//! Long-Term-Reference (LTR) recovery bookkeeping — a port of Swift `LTRController` (WF-8).
//!
//! A low-latency HEVC `VTCompressionSession` can emit LTR frames carrying an acknowledgement
//! token; the host can then recover a client that lost frames with a CHEAP P-frame referencing an
//! *acknowledged* long-term reference (`ForceLTRRefresh`) instead of a full IDR — no decoder
//! flush, a fraction of the bytes.
//!
//! ## The ACKED-ONLY invariant (paramount)
//!
//! A `ForceLTRRefresh` may ONLY reference a long-term reference the client *definitely holds*.
//! Referencing a lost / un-acked LTR makes the recovery frame depend on a frame the client lacks
//! → persistent corruption until an IDR. So a token enters the acknowledged set EXCLUSIVELY via
//! [`ack_frame`](LtrController::ack_frame), which the host calls only when the client sends
//! `RecoveryMessage::Ack` — and the client sends that ONLY after successfully decoding the
//! LTR-flagged frame. [`recovery_decision`](LtrController::recovery_decision) returns
//! [`RecoveryAction::Idr`] whenever no token is acked.
//!
//! Pure + deterministic (no wall-clock, no I/O) and bounded on every dimension: the `frame_id →
//! token` map and the acknowledged-token set are both capped with evict-oldest.

use std::collections::HashMap;

/// Max recorded `frame_id → token` mappings retained for ack look-up (evict-oldest past it).
pub const FRAME_TOKEN_CAP: usize = 64;
/// Max acknowledged tokens retained (keep-most-recent, drop oldest).
pub const ACKNOWLEDGED_TOKEN_CAP: usize = 8;

/// The recovery a client request should trigger.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecoveryAction {
    /// Issue a `ForceLTRRefresh` — a cheap P-frame against an ACKNOWLEDGED long-term reference.
    /// Only ever returned when the ACKED-ONLY invariant holds.
    LtrRefresh,
    /// Force a full IDR keyframe — the guaranteed re-anchor; the safe fallback whenever LTR is off
    /// or no token has been acknowledged, and ALWAYS for an explicit `request_idr`.
    Idr,
}

/// The kind of client recovery request driving the decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Request {
    /// `RecoveryMessage::RequestLtrRefresh` — eligible for an LTR refresh under the ACKED-ONLY gate.
    LtrRefresh,
    /// `RecoveryMessage::RequestIdr` — the guaranteed-recovery escalation; ALWAYS a real IDR.
    Idr,
}

/// Tracks emitted LTR frames and client acks to gate the recovery decision.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LtrController {
    frame_tokens: HashMap<u32, i64>,
    frame_order: Vec<u32>,
    acknowledged_tokens: Vec<i64>,
}

impl LtrController {
    /// A fresh controller with nothing recorded.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Recorded `frame_id → token` mappings awaiting a client ack.
    #[must_use]
    pub const fn frame_tokens(&self) -> &HashMap<u32, i64> {
        &self.frame_tokens
    }

    /// Insertion order of [`frame_tokens`](Self::frame_tokens) keys (oldest first).
    #[must_use]
    pub fn frame_order(&self) -> &[u32] {
        &self.frame_order
    }

    /// The acknowledged tokens (oldest → newest) to feed the encoder as `AcknowledgedLTRTokens`.
    #[must_use]
    pub fn current_acknowledged_tokens(&self) -> &[i64] {
        &self.acknowledged_tokens
    }

    /// Whether ANY token has been acknowledged — the ACKED-ONLY gate's positive signal.
    #[must_use]
    pub fn has_acked_token(&self) -> bool {
        !self.acknowledged_tokens.is_empty()
    }

    /// Records that the encoder emitted an LTR frame `frame_id` carrying acknowledgement `token`.
    /// Insertion-ordered; evicts the oldest mapping past the cap. Idempotent on a repeated
    /// `frame_id` (updates the token, keeps its place).
    pub fn record_ltr_frame(&mut self, frame_id: u32, token: i64) {
        if !self.frame_tokens.contains_key(&frame_id) {
            self.frame_order.push(frame_id);
        }
        self.frame_tokens.insert(frame_id, token);
        while self.frame_order.len() > FRAME_TOKEN_CAP {
            let evicted = self.frame_order.remove(0);
            self.frame_tokens.remove(&evicted);
        }
    }

    /// Folds a client acknowledgement of `frame_id`: if it maps to a recorded token, add that
    /// token to the acknowledged set (keep-most-recent, dedup) and return it. An unknown /
    /// already-evicted / duplicate `frame_id` returns `None` — a safe no-op.
    pub fn ack_frame(&mut self, frame_id: u32) -> Option<i64> {
        let token = *self.frame_tokens.get(&frame_id)?;
        // Keep-most-recent: if already acked, move it to the newest slot.
        if let Some(idx) = self.acknowledged_tokens.iter().position(|&t| t == token) {
            self.acknowledged_tokens.remove(idx);
        }
        self.acknowledged_tokens.push(token);
        while self.acknowledged_tokens.len() > ACKNOWLEDGED_TOKEN_CAP {
            self.acknowledged_tokens.remove(0);
        }
        Some(token)
    }

    /// Invalidate ALL acked-token + frame-map state. The host MUST call this whenever it rebuilds
    /// the encoder / `VTCompressionSession`: a fresh session holds zero acknowledged LTRs, so the
    /// acknowledged set must be cleared in lockstep or the gate would issue a `ForceLTRRefresh`
    /// against an LTR the new session never had.
    pub fn reset(&mut self) {
        self.frame_tokens.clear();
        self.frame_order.clear();
        self.acknowledged_tokens.clear();
    }

    /// THE recovery decision. A `request_idr` ALWAYS forces a real IDR. A `request_ltr_refresh`
    /// becomes [`RecoveryAction::LtrRefresh`] ONLY when `has_enable_ltr` is on AND at least one
    /// token has been acknowledged; otherwise it falls back to [`RecoveryAction::Idr`].
    #[must_use]
    pub fn recovery_decision(&self, request: Request, has_enable_ltr: bool) -> RecoveryAction {
        if request != Request::LtrRefresh {
            return RecoveryAction::Idr;
        }
        if has_enable_ltr && self.has_acked_token() {
            RecoveryAction::LtrRefresh
        } else {
            RecoveryAction::Idr
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ack_unknown_frame_returns_none_and_no_token() {
        let mut c = LtrController::new();
        assert_eq!(c.ack_frame(42), None);
        assert!(!c.has_acked_token());
        assert!(c.current_acknowledged_tokens().is_empty());
    }

    #[test]
    fn record_then_ack_folds_token_and_arms_has_acked() {
        let mut c = LtrController::new();
        c.record_ltr_frame(7, 0xABCD);
        assert!(!c.has_acked_token());
        let folded = c.ack_frame(7);
        assert_eq!(folded, Some(0xABCD));
        assert!(c.has_acked_token());
        assert_eq!(c.current_acknowledged_tokens(), &[0xABCD]);
    }

    #[test]
    fn duplicate_ack_is_idempotent_no_growth() {
        let mut c = LtrController::new();
        c.record_ltr_frame(1, 100);
        assert_eq!(c.ack_frame(1), Some(100));
        assert_eq!(c.ack_frame(1), Some(100));
        assert_eq!(c.current_acknowledged_tokens(), &[100]);
    }

    #[test]
    fn ack_after_eviction_is_safe_no_op() {
        let mut c = LtrController::new();
        c.record_ltr_frame(0, 999);
        for f in 1..=(FRAME_TOKEN_CAP + 4) as u32 {
            c.record_ltr_frame(f, i64::from(f));
        }
        assert_eq!(c.ack_frame(0), None);
        assert!(!c.has_acked_token());
    }

    #[test]
    fn frame_token_map_evicts_oldest() {
        let mut c = LtrController::new();
        let n = (FRAME_TOKEN_CAP + 30) as u32;
        for f in 0..n {
            c.record_ltr_frame(f, i64::from(f));
        }
        assert_eq!(c.frame_tokens().len(), FRAME_TOKEN_CAP);
        assert_eq!(c.frame_order().len(), FRAME_TOKEN_CAP);
        assert_eq!(c.frame_tokens().get(&0), None);
        assert_eq!(c.frame_tokens().get(&(n - 1)), Some(&i64::from(n - 1)));
    }

    #[test]
    fn acknowledged_set_keeps_most_recent_bounded() {
        let mut c = LtrController::new();
        let n = (ACKNOWLEDGED_TOKEN_CAP + 20) as i64;
        for f in 0..n {
            c.record_ltr_frame(f as u32, f * 7);
            let _ = c.ack_frame(f as u32);
        }
        let acked = c.current_acknowledged_tokens();
        assert_eq!(acked.len(), ACKNOWLEDGED_TOKEN_CAP);
        let expected: Vec<i64> = ((n - ACKNOWLEDGED_TOKEN_CAP as i64)..n)
            .map(|x| x * 7)
            .collect();
        assert_eq!(acked, expected.as_slice());
        assert_eq!(acked.last(), Some(&((n - 1) * 7)));
    }

    #[test]
    fn staging_never_grows_under_long_stream() {
        let mut c = LtrController::new();
        for f in 0..10_000u32 {
            c.record_ltr_frame(f, i64::from(f));
            let _ = c.ack_frame(f);
        }
        assert!(c.frame_tokens().len() <= FRAME_TOKEN_CAP);
        assert!(c.frame_order().len() <= FRAME_TOKEN_CAP);
        assert!(c.current_acknowledged_tokens().len() <= ACKNOWLEDGED_TOKEN_CAP);
        assert!(c.has_acked_token());
    }

    #[test]
    fn recovery_decision_requires_acked_token_for_ltr_refresh() {
        let mut c = LtrController::new();
        assert_eq!(
            c.recovery_decision(Request::LtrRefresh, true),
            RecoveryAction::Idr
        );
        c.record_ltr_frame(3, 55);
        assert_eq!(
            c.recovery_decision(Request::LtrRefresh, true),
            RecoveryAction::Idr
        );
        let _ = c.ack_frame(3);
        assert_eq!(
            c.recovery_decision(Request::LtrRefresh, true),
            RecoveryAction::LtrRefresh
        );
    }

    #[test]
    fn recovery_decision_idr_when_ltr_off() {
        let mut c = LtrController::new();
        c.record_ltr_frame(1, 9);
        let _ = c.ack_frame(1);
        assert_eq!(
            c.recovery_decision(Request::LtrRefresh, false),
            RecoveryAction::Idr
        );
    }

    #[test]
    fn request_idr_always_forces_idr() {
        let mut c = LtrController::new();
        c.record_ltr_frame(1, 9);
        let _ = c.ack_frame(1);
        assert_eq!(c.recovery_decision(Request::Idr, true), RecoveryAction::Idr);
    }

    #[test]
    fn reset_clears_acked_set_and_frame_map() {
        let mut c = LtrController::new();
        c.record_ltr_frame(1, 11);
        c.record_ltr_frame(2, 22);
        let _ = c.ack_frame(1);
        let _ = c.ack_frame(2);
        assert!(c.has_acked_token());
        assert!(!c.frame_tokens().is_empty());
        assert!(!c.frame_order().is_empty());

        c.reset();

        assert!(!c.has_acked_token());
        assert!(c.current_acknowledged_tokens().is_empty());
        assert!(c.frame_tokens().is_empty());
        assert!(c.frame_order().is_empty());
    }

    #[test]
    fn reset_rearms_acked_only_gate_after_session_rebuild() {
        let mut c = LtrController::new();
        c.record_ltr_frame(5, 0xDEAD);
        let _ = c.ack_frame(5);
        assert_eq!(
            c.recovery_decision(Request::LtrRefresh, true),
            RecoveryAction::LtrRefresh
        );

        c.reset();

        assert_eq!(
            c.recovery_decision(Request::LtrRefresh, true),
            RecoveryAction::Idr
        );
        assert!(!c.has_acked_token());
    }

    #[test]
    fn late_ack_for_pre_rebuild_frame_is_no_op_after_reset() {
        let mut c = LtrController::new();
        c.record_ltr_frame(9, 0xBEEF);
        c.reset();
        assert_eq!(c.ack_frame(9), None);
        assert!(!c.has_acked_token());
        c.record_ltr_frame(10, 0xCAFE);
        assert_eq!(c.ack_frame(10), Some(0xCAFE));
        assert!(c.has_acked_token());
    }
}
