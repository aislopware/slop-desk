//! Delivery-keyed recovery-IDR admission policy — a port of Swift `RecoveryIDRPolicy`.
//!
//! The single authority on whether a client recovery request may force a real IDR. The legacy
//! gate keyed its cooldown on keyframe SEND time: when both kfDup copies of a recovery IDR were
//! lost, the client's 2·RTT escalation re-requested every ~2·RTT and every request inside the
//! 500 ms window was suppressed → ~600 ms of freeze, RTT-independent. Delivery-keying removes that:
//! a request carrying `last_decoded < newest sent keyframe` past the in-flight grace PROVES that
//! keyframe is a casualty ⇒ grant immediately (the casualty bypass).
//!
//! Decision table (`r` = request's last-decoded, `K` = newest sent keyframe):
//!  - r ≥ K ⇒ the request proves K delivered + a new post-K loss ⇒ grant (token-gated).
//!  - r < K, age(K) < grace ⇒ K plausibly crossed in flight ⇒ suppress.
//!  - r < K, age(K) ≥ grace ⇒ K presumed a casualty ⇒ THE BYPASS: grant.
//!  - r < a keyframe the client decode-ACKED ⇒ stale ⇒ suppress at zero cost regardless of age.
//!  - a token bucket (cap 2, refill 1/500 ms) caps everything that reaches "grant".
//!
//! Pure + wall-clock-only: all time injected as `f64` seconds (the session's `systemUptime`
//! domain), zero frame counting — immune to FPS-governor cadence changes.

use crate::seq::distance_wrapped;

/// Tunables for [`RecoveryIdrPolicy`]. f64 fields, so [`PartialEq`] only.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Config {
    /// In-flight grace = `grace_fraction × smoothed_rtt`, clamped to `[floor, ceil]`.
    pub grace_fraction: f64,
    /// Covers the rtt-unknown bootstrap (smoothed RTT = 0 before the first netstats fold).
    pub grace_floor_seconds: f64,
    /// Beyond it the kfDup second copy has also long been sent, so further suppression only adds
    /// freeze (= `kfDupMinInterval`).
    pub grace_ceil_seconds: f64,
    /// Burst allowance: one ordinary grant + one casualty-bypass grant back-to-back.
    pub bucket_capacity: f64,
    /// Sustained refill rate (1 token / 500 ms preserves the old spacing ceiling).
    pub refill_tokens_per_second: f64,
    /// A granted-but-unserviced latch suppresses duplicates until this expires.
    pub grant_pending_timeout: f64,
    /// Newest-last ring size for recently-sent keyframes.
    pub keyframe_ring_capacity: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            grace_fraction: 0.75,
            grace_floor_seconds: 0.040,
            grace_ceil_seconds: 0.250,
            bucket_capacity: 2.0,
            refill_tokens_per_second: 2.0,
            grant_pending_timeout: 1.5,
            keyframe_ring_capacity: 4,
        }
    }
}

/// One sent keyframe (id + send time in the `systemUptime` domain).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SentKeyframe {
    /// The keyframe's frame id.
    pub id: u32,
    /// The send time (seconds).
    pub at: f64,
}

/// The admission verdict for one IDR-issuing recovery request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// Issue the real IDR.
    Grant,
    /// An IDR grant is already latched and unexpired — the duplicate-request absorber.
    SuppressGrantPending,
    /// The request provably predates a keyframe the client DECODED (acked) — zero-cost suppression.
    SuppressStale,
    /// The newest sent keyframe plausibly is still in flight to the client.
    SuppressInFlight,
    /// Token bucket empty — the storm cap.
    SuppressRateLimited,
}

/// Delivery-keyed admission policy for recovery IDRs.
#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryIdrPolicy {
    config: Config,
    recent_keyframes: Vec<SentKeyframe>,
    delivered_keyframe_id: Option<u32>,
    tokens: f64,
    last_refill_at: Option<f64>,
    granted_at: Option<f64>,
}

impl Default for RecoveryIdrPolicy {
    fn default() -> Self {
        Self::new(Config::default())
    }
}

impl RecoveryIdrPolicy {
    /// Builds a policy with the given config; the token bucket starts full.
    #[must_use]
    pub const fn new(config: Config) -> Self {
        let tokens = config.bucket_capacity;
        Self {
            config,
            recent_keyframes: Vec::new(),
            delivered_keyframe_id: None,
            tokens,
            last_refill_at: None,
            granted_at: None,
        }
    }

    /// The active config.
    #[must_use]
    pub const fn config(&self) -> &Config {
        &self.config
    }

    /// Read-only token level (proves `suppress*` verdicts spend nothing).
    #[must_use]
    pub const fn available_tokens(&self) -> f64 {
        self.tokens
    }

    /// Called for EVERY keyframe handed to the wire (recovery, first-frame, static-crisp,
    /// heartbeat) with the next frame id read BEFORE packetize.
    pub fn note_keyframe_sent(&mut self, frame_id: u32, now: f64) {
        self.recent_keyframes.push(SentKeyframe {
            id: frame_id,
            at: now,
        });
        if self.recent_keyframes.len() > self.config.keyframe_ring_capacity {
            self.recent_keyframes.remove(0);
        }
        self.granted_at = None; // a keyframe went out: any pending grant is serviced
    }

    /// Called from the `.ack` fold. Idempotent; only ids matching a ring entry count (an LTR-P ack
    /// must not masquerade as keyframe delivery). Wrap-aware keep-newest.
    pub fn note_keyframe_delivered(&mut self, frame_id: u32) {
        if !self.recent_keyframes.iter().any(|k| k.id == frame_id) {
            return;
        }
        if let Some(delivered) = self.delivered_keyframe_id {
            if distance_wrapped(frame_id, delivered) <= 0 {
                return;
            }
        }
        self.delivered_keyframe_id = Some(frame_id);
    }

    /// THE admission decision for one IDR-issuing recovery request. `client_last_decoded == None`
    /// ⇔ the wire sentinel "nothing decoded yet" (treated as maximally behind).
    pub fn decide(
        &mut self,
        now: f64,
        client_last_decoded: Option<u32>,
        smoothed_rtt_seconds: f64,
    ) -> Verdict {
        self.refill(now);
        if let Some(granted) = self.granted_at {
            if now - granted < self.config.grant_pending_timeout {
                return Verdict::SuppressGrantPending;
            }
        }
        if let (Some(delivered), Some(request)) = (self.delivered_keyframe_id, client_last_decoded)
        {
            if distance_wrapped(request, delivered) < 0 {
                // The client's last-decoded is monotonic, so a request older than a keyframe it
                // ACKED was composed before that keyframe decoded — stale.
                return Verdict::SuppressStale;
            }
        }
        if let Some(newest) = self.recent_keyframes.last() {
            // None last-decoded (nothing decoded yet) is maximally behind by definition.
            let client_behind =
                client_last_decoded.is_none_or(|r| distance_wrapped(r, newest.id) < 0);
            if client_behind && now - newest.at < self.grace(smoothed_rtt_seconds) {
                return Verdict::SuppressInFlight;
            }
        }
        if self.tokens < 1.0 {
            return Verdict::SuppressRateLimited;
        }
        self.tokens -= 1.0;
        self.granted_at = Some(now);
        Verdict::Grant
    }

    /// In-flight grace window for the given smoothed RTT: `clamp(grace_fraction × rtt, floor, ceil)`.
    #[must_use]
    pub fn grace(&self, rtt: f64) -> f64 {
        (self.config.grace_fraction * rtt)
            .max(self.config.grace_floor_seconds)
            .min(self.config.grace_ceil_seconds)
    }

    fn refill(&mut self, now: f64) {
        // Mirrors the Swift `defer { lastRefillAt = now }`: the stamp advances on EVERY call, the
        // refill only when a strictly-later `now` has a prior stamp to measure against.
        if let Some(last) = self.last_refill_at {
            if now > last {
                self.tokens = self
                    .config
                    .bucket_capacity
                    .min(self.tokens + (now - last) * self.config.refill_tokens_per_second);
            }
        }
        self.last_refill_at = Some(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} !~= {b}");
    }

    #[test]
    fn grant_when_no_recent_keyframe() {
        let mut policy = RecoveryIdrPolicy::default();
        approx(policy.available_tokens(), 2.0);
        assert_eq!(policy.decide(10.0, None, 0.05), Verdict::Grant);
        approx(policy.available_tokens(), 1.0);
    }

    #[test]
    fn casualty_bypass_after_grace() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(100, 5.0);
        assert_eq!(policy.decide(5.2, Some(99), 0.05), Verdict::Grant);
    }

    #[test]
    fn suppress_in_flight_within_grace() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(100, 5.0);
        let before = policy.available_tokens();
        assert_eq!(
            policy.decide(5.02, Some(99), 0.05),
            Verdict::SuppressInFlight
        );
        approx(policy.available_tokens(), before);
    }

    #[test]
    fn request_proves_delivery_grants() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(100, 5.0);
        assert_eq!(policy.decide(5.01, Some(100), 0.05), Verdict::Grant);
        policy.note_keyframe_sent(101, 5.02);
        assert_eq!(policy.decide(5.03, Some(105), 0.05), Verdict::Grant);
    }

    #[test]
    fn suppress_stale_after_delivered_ack() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(100, 5.0);
        policy.note_keyframe_delivered(100);
        let before = policy.available_tokens();
        assert_eq!(policy.decide(9.0, Some(99), 0.05), Verdict::SuppressStale);
        approx(policy.available_tokens(), before);
    }

    #[test]
    fn delivered_ack_ignored_unless_ring_match() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(100, 5.0);
        policy.note_keyframe_delivered(555);
        assert_eq!(policy.decide(5.3, Some(99), 0.05), Verdict::Grant);
    }

    #[test]
    fn token_bucket_caps_burst_at_two() {
        let mut policy = RecoveryIdrPolicy::default();
        assert_eq!(policy.decide(10.0, None, 0.05), Verdict::Grant);
        policy.note_keyframe_sent(1, 10.01);
        assert_eq!(policy.decide(10.1, Some(0), 0.05), Verdict::Grant);
        policy.note_keyframe_sent(2, 10.11);
        assert_eq!(
            policy.decide(10.2, Some(0), 0.05),
            Verdict::SuppressRateLimited
        );
        assert_eq!(policy.decide(10.75, Some(0), 0.05), Verdict::Grant);
    }

    #[test]
    fn suppress_grant_pending_until_keyframe_sent_or_timeout() {
        let mut policy = RecoveryIdrPolicy::default();
        assert_eq!(policy.decide(10.0, None, 0.05), Verdict::Grant);
        assert_eq!(
            policy.decide(10.1, None, 0.05),
            Verdict::SuppressGrantPending
        );
        assert_eq!(
            policy.decide(11.0, None, 0.05),
            Verdict::SuppressGrantPending
        );
        policy.note_keyframe_sent(50, 11.1);
        assert_eq!(policy.decide(11.11, None, 0.05), Verdict::SuppressInFlight);

        let mut wedged = RecoveryIdrPolicy::default();
        assert_eq!(wedged.decide(20.0, None, 0.05), Verdict::Grant);
        assert_eq!(
            wedged.decide(21.4, None, 0.05),
            Verdict::SuppressGrantPending
        );
        assert_eq!(wedged.decide(21.6, None, 0.05), Verdict::Grant);
    }

    #[test]
    fn nil_last_decoded_treated_as_behind() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(0, 5.0);
        assert_eq!(policy.decide(5.01, None, 0.05), Verdict::SuppressInFlight);
        assert_eq!(policy.decide(5.2, None, 0.05), Verdict::Grant);
    }

    #[test]
    fn wrap_aware_ids() {
        let mut policy = RecoveryIdrPolicy::default();
        let near_max: u32 = u32::MAX - 1;
        policy.note_keyframe_sent(near_max, 5.0);
        assert_eq!(policy.decide(5.01, Some(3), 0.05), Verdict::Grant);
        policy.note_keyframe_sent(2, 5.02);
        policy.note_keyframe_delivered(near_max);
        policy.note_keyframe_delivered(2);
        assert_eq!(
            policy.decide(9.0, Some(u32::MAX), 0.05),
            Verdict::SuppressStale
        );
        policy.note_keyframe_delivered(near_max);
        assert_eq!(
            policy.decide(9.5, Some(u32::MAX), 0.05),
            Verdict::SuppressStale
        );
    }

    #[test]
    fn grace_clamp() {
        let policy = RecoveryIdrPolicy::default();
        approx(policy.grace(0.0), 0.040);
        approx(policy.grace(0.059), 0.044_25);
        approx(policy.grace(1.0), 0.250);
    }

    #[test]
    fn wall_clock_only() {
        fn run(extra_probes: usize) -> Vec<Verdict> {
            let mut policy = RecoveryIdrPolicy::default();
            let mut verdicts = Vec::new();
            policy.note_keyframe_sent(10, 1.0);
            verdicts.push(policy.decide(1.02, Some(9), 0.05));
            for _ in 0..extra_probes {
                let _ = policy.decide(1.02, Some(9), 0.05);
            }
            verdicts.push(policy.decide(1.2, Some(9), 0.05));
            policy.note_keyframe_sent(11, 1.21);
            verdicts.push(policy.decide(1.3, Some(9), 0.05));
            policy.note_keyframe_sent(12, 1.31);
            verdicts.push(policy.decide(1.4, Some(9), 0.05));
            verdicts
        }
        assert_eq!(run(0), run(7));
        assert_eq!(
            run(0),
            vec![
                Verdict::SuppressInFlight,
                Verdict::Grant,
                Verdict::Grant,
                Verdict::SuppressRateLimited,
            ]
        );
    }

    #[test]
    fn keyframe_ring_evicts_oldest() {
        let mut policy = RecoveryIdrPolicy::default();
        for id in [1u32, 2, 3, 4, 5] {
            policy.note_keyframe_sent(id, 5.0 + f64::from(id) * 0.001);
        }
        policy.note_keyframe_delivered(1);
        assert_eq!(policy.decide(6.0, Some(0), 0.05), Verdict::Grant);
    }
}
