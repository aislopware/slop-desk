//! DELIVERY-KEYED admission for recovery IDRs: the single authority on whether a client's recovery
//! request may force a real keyframe.
//!
//! ## The bug this shape exists to fix
//!
//! Keying a cooldown on keyframe SEND time cannot tell send from delivery. If both duplicate copies
//! of a recovery keyframe are lost in one burst, the client re-escalates every couple of round
//! trips — and every request landing inside a fixed send-keyed window is suppressed while the host
//! keeps shipping P-frames the broken client cannot use. That is a freeze whose length is set by
//! the cooldown rather than by the link. Delivery-keying removes the term: a request carrying a
//! last-decoded id BELOW the newest sent keyframe, arriving past the in-flight grace, PROVES that
//! keyframe was a casualty, so it is granted immediately.
//!
//! ## The decision table, with `r` the request's last-decoded id and `K` the newest sent keyframe
//!
//! | condition | verdict |
//! | --- | --- |
//! | `r >= K` | the request itself proves `K` arrived and reports a genuinely new loss ⇒ grant |
//! | `r < K`, `age(K) < grace` | the request plausibly crossed `K` in flight ⇒ suppress |
//! | `r < K`, `age(K) >= grace` | `K` is presumed a casualty ⇒ THE BYPASS: grant |
//! | `r` below a keyframe the client ACKED | stale, composed before its own re-anchor ⇒ suppress |
//!
//! and a token bucket caps everything that reaches a grant: the sustained rate matches the old
//! send-keyed cooldown exactly, with a burst of two so the casualty bypass is never blocked by the
//! ordinary grant that preceded it.
//!
//! Pure and wall-clock-only — every time is injected in seconds and nothing counts frames — so the
//! policy is immune to frame-rate governor changes.

use crate::reassembler::distance_wrapped;

/// The tuning knobs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryIdrConfig {
    /// The in-flight grace is this fraction of the smoothed round trip, clamped to the floor and
    /// ceiling below. A crossing request arrives within about half a round trip plus jitter after
    /// the keyframe went out; three quarters adds roughly fifty percent of margin.
    pub grace_fraction: f64,
    /// Covers the bootstrap, where the smoothed round trip is still zero.
    pub grace_floor_seconds: f64,
    /// The duplicate-keyframe spacing: beyond it the second copy has also long been sent, so
    /// further suppression only adds freeze.
    pub grace_ceil_seconds: f64,
    /// The burst allowance: exactly one ordinary grant plus one casualty bypass back to back.
    /// Recovery keyframes are compact and duplicated, so two grants is about four wire copies
    /// inside the sustained window — bounded. Three would re-open the storm.
    pub bucket_capacity: f64,
    /// The sustained refill, preserving the old spacing ceiling exactly.
    pub refill_tokens_per_second: f64,
    /// A granted-but-unserviced latch suppresses duplicates until this expires. Sized above the
    /// worst legitimate service path — a freshly quiet window waits out the quiet timer plus a tick
    /// plus margin — so it prevents both premature double grants and a permanent wedge if capture
    /// dies.
    pub grant_pending_timeout: f64,
    /// Keyframes are rare, so this covers every one plausibly in flight within an ack round trip.
    pub keyframe_ring_capacity: usize,
}

impl Default for RecoveryIdrConfig {
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

/// One sent keyframe.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SentKeyframe {
    /// The frame id the packetizer returned for it.
    pub id: u32,
    /// When it went out, in the host's uptime clock.
    pub at: f64,
}

/// The admission verdict for one recovery request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdrVerdict {
    /// Issue the keyframe.
    Grant,
    /// A grant is already latched and unexpired — the duplicate-request absorber.
    SuppressGrantPending,
    /// The request provably predates a keyframe the client DECODED, so it costs nothing to drop
    /// however old it is.
    SuppressStale,
    /// The newest sent keyframe is plausibly still in flight.
    SuppressInFlight,
    /// The token bucket is empty — the storm cap.
    SuppressRateLimited,
}

/// The delivery-keyed recovery-IDR policy.
#[derive(Debug, Clone, PartialEq)]
pub struct RecoveryIdrPolicy {
    /// The tuning.
    config: RecoveryIdrConfig,
    /// Recently sent keyframes, newest last, capped by the config.
    recent_keyframes: Vec<SentKeyframe>,
    /// The newest SENT keyframe id the client acknowledged, ring-matched so a plain P-frame ack can
    /// never masquerade as keyframe delivery.
    delivered_keyframe_id: Option<u32>,
    /// The bucket level.
    tokens: f64,
    /// When the bucket was last refilled.
    last_refill_at: Option<f64>,
    /// When the last grant was issued, until a keyframe services it.
    granted_at: Option<f64>,
}

impl Default for RecoveryIdrPolicy {
    fn default() -> Self {
        Self::new(RecoveryIdrConfig::default())
    }
}

impl RecoveryIdrPolicy {
    /// A policy with a full bucket and no history.
    #[must_use]
    pub const fn new(config: RecoveryIdrConfig) -> Self {
        Self {
            tokens: config.bucket_capacity,
            config,
            recent_keyframes: Vec::new(),
            delivered_keyframe_id: None,
            last_refill_at: None,
            granted_at: None,
        }
    }

    /// The tuning this policy runs on.
    #[must_use]
    pub const fn config(&self) -> RecoveryIdrConfig {
        self.config
    }

    /// The current token level, which proves the suppressing verdicts spend nothing.
    #[must_use]
    pub const fn available_tokens(&self) -> f64 {
        self.tokens
    }

    /// Notes every keyframe handed to the wire — recovery, first frame, crisp re-anchor, heartbeat
    /// — with the frame id the packetizer gave it. A keyframe going out services any pending grant.
    pub fn note_keyframe_sent(&mut self, frame_id: u32, now: f64) {
        self.recent_keyframes.push(SentKeyframe {
            id: frame_id,
            at: now,
        });
        while self.recent_keyframes.len() > self.config.keyframe_ring_capacity {
            self.recent_keyframes.remove(0);
        }
        self.granted_at = None;
    }

    /// Folds a client ack. Idempotent, and only ids matching a ring entry count. Wrap-aware
    /// keep-newest.
    pub fn note_keyframe_delivered(&mut self, frame_id: u32) {
        if !self.recent_keyframes.iter().any(|sent| sent.id == frame_id) {
            return;
        }
        if let Some(delivered) = self.delivered_keyframe_id
            && distance_wrapped(frame_id, delivered) <= 0
        {
            return;
        }
        self.delivered_keyframe_id = Some(frame_id);
    }

    /// THE admission decision for one recovery request.
    ///
    /// `client_last_decoded` of `None` is the wire sentinel "nothing decoded yet", treated as
    /// maximally behind, so the connect-time first-keyframe loss rides the same bypass.
    ///
    /// BRANCH ORDER IS LOAD-BEARING and must read exactly: refill, then grant-pending, then stale,
    /// then in-flight, then rate-limited, then grant. Reordering any pair changes behaviour.
    pub fn decide(
        &mut self,
        now: f64,
        client_last_decoded: Option<u32>,
        smoothed_rtt_seconds: f64,
    ) -> IdrVerdict {
        self.refill(now);
        if let Some(granted) = self.granted_at
            && now - granted < self.config.grant_pending_timeout
        {
            return IdrVerdict::SuppressGrantPending;
        }
        if let Some(delivered) = self.delivered_keyframe_id
            && let Some(request) = client_last_decoded
            && distance_wrapped(request, delivered) < 0
        {
            // Exact, not heuristic: the client's last-decoded id is monotonic, so a request older
            // than a keyframe it ACKED was composed before that keyframe decoded.
            return IdrVerdict::SuppressStale;
        }
        if let Some(newest) = self.recent_keyframes.last() {
            let client_behind =
                client_last_decoded.is_none_or(|decoded| distance_wrapped(decoded, newest.id) < 0);
            if client_behind && now - newest.at < self.grace(smoothed_rtt_seconds) {
                return IdrVerdict::SuppressInFlight;
            }
        }
        if self.tokens < 1.0 {
            return IdrVerdict::SuppressRateLimited;
        }
        self.tokens -= 1.0;
        self.granted_at = Some(now);
        IdrVerdict::Grant
    }

    /// The in-flight grace for a given smoothed round trip, clamped between the floor and ceiling.
    #[must_use]
    pub fn grace(&self, rtt: f64) -> f64 {
        let scaled = self.config.grace_fraction * rtt;
        self.config
            .grace_ceil_seconds
            .min(f64::max(self.config.grace_floor_seconds, scaled))
    }

    /// Refills the bucket for the elapsed time, clamped to capacity.
    fn refill(&mut self, now: f64) {
        if let Some(last) = self.last_refill_at
            && now > last
        {
            // Multiply, then add, then clamp — kept as separate operations, never fused.
            let earned = (now - last) * self.config.refill_tokens_per_second;
            let raised = self.tokens + earned;
            self.tokens = self.config.bucket_capacity.min(raised);
        }
        self.last_refill_at = Some(now);
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the token assertions are on levels the law pins exactly — a full bucket, or one token \
                  spent — which is the property under test"
    )]

    use super::{IdrVerdict, RecoveryIdrConfig, RecoveryIdrPolicy};

    #[test]
    fn a_request_that_proves_delivery_is_granted() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        // The client decoded 10 and lost something after it.
        assert_eq!(policy.decide(1.5, Some(10), 0.020), IdrVerdict::Grant);
        assert_eq!(policy.available_tokens(), 1.0, "exactly one token spent");
    }

    #[test]
    fn a_request_that_plausibly_crossed_the_keyframe_is_suppressed() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        assert_eq!(policy.decide(1.01, Some(9), 0.020), IdrVerdict::SuppressInFlight);
        assert_eq!(policy.available_tokens(), 2.0, "a suppression spends nothing");
    }

    /// The whole reason for delivery-keying: a lost keyframe must not cost a cooldown of freeze.
    #[test]
    fn a_casualty_keyframe_is_bypassed_immediately_past_the_grace() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        // 20 ms round trip ⇒ 15 ms grace, floored at 40 ms.
        assert_eq!(policy.decide(1.041, Some(9), 0.020), IdrVerdict::Grant);
    }

    #[test]
    fn nothing_decoded_yet_is_maximally_behind() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        assert_eq!(policy.decide(1.01, None, 0.020), IdrVerdict::SuppressInFlight);
        assert_eq!(
            policy.decide(1.5, None, 0.020),
            IdrVerdict::Grant,
            "the same bypass"
        );
    }

    #[test]
    fn a_request_older_than_an_acked_keyframe_is_stale_at_any_age() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        policy.note_keyframe_delivered(10);
        assert_eq!(policy.decide(100.0, Some(9), 0.020), IdrVerdict::SuppressStale);
    }

    #[test]
    fn only_a_ring_matched_ack_counts_as_keyframe_delivery() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        policy.note_keyframe_delivered(11); // a plain P-frame ack
        // Had it counted, this request would read as stale rather than as a casualty bypass.
        assert_eq!(policy.decide(1.5, Some(9), 0.020), IdrVerdict::Grant);
    }

    #[test]
    fn a_delivery_ack_never_goes_backwards() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        policy.note_keyframe_sent(20, 1.1);
        policy.note_keyframe_delivered(20);
        policy.note_keyframe_delivered(10); // reordered, older
        assert_eq!(
            policy.decide(2.0, Some(15), 0.020),
            IdrVerdict::SuppressStale,
            "still keyed on 20",
        );
    }

    #[test]
    fn a_granted_but_unserviced_latch_absorbs_the_duplicate_requests() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        assert_eq!(policy.decide(1.5, Some(10), 0.020), IdrVerdict::Grant);
        assert_eq!(
            policy.decide(1.6, Some(10), 0.020),
            IdrVerdict::SuppressGrantPending
        );
        // A keyframe going out services the latch.
        policy.note_keyframe_sent(11, 1.7);
        assert_eq!(policy.decide(1.8, Some(11), 0.020), IdrVerdict::Grant);
    }

    /// And the latch must not wedge the stream if capture dies without ever servicing it.
    #[test]
    fn an_unserviced_latch_expires() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(10, 1.0);
        assert_eq!(policy.decide(1.5, Some(10), 0.020), IdrVerdict::Grant);
        assert_eq!(
            policy.decide(3.1, Some(10), 0.020),
            IdrVerdict::Grant,
            "past the timeout"
        );
    }

    #[test]
    fn the_bucket_caps_a_storm_and_refills_at_the_sustained_rate() {
        let config = RecoveryIdrConfig {
            grant_pending_timeout: 0.0,
            ..RecoveryIdrConfig::default()
        };
        let mut policy = RecoveryIdrPolicy::new(config);
        policy.note_keyframe_sent(10, 1.0);
        assert_eq!(policy.decide(1.5, Some(10), 0.020), IdrVerdict::Grant);
        assert_eq!(
            policy.decide(1.5, Some(10), 0.020),
            IdrVerdict::Grant,
            "the burst of two"
        );
        assert_eq!(
            policy.decide(1.5, Some(10), 0.020),
            IdrVerdict::SuppressRateLimited
        );
        // One token per half second, and never past the capacity.
        assert_eq!(policy.decide(2.0, Some(10), 0.020), IdrVerdict::Grant);
        assert_eq!(policy.decide(60.0, Some(10), 0.020), IdrVerdict::Grant);
        assert_eq!(policy.available_tokens(), 1.0, "the bucket clamps at capacity");
    }

    #[test]
    fn the_grace_is_clamped_at_both_ends() {
        let policy = RecoveryIdrPolicy::default();
        assert_eq!(policy.grace(0.0), 0.040, "the bootstrap floor");
        assert!(
            (policy.grace(0.100) - 0.075).abs() < 1e-12,
            "three quarters of the round trip"
        );
        assert_eq!(policy.grace(10.0), 0.250, "the duplicate-copy ceiling");
    }

    #[test]
    fn the_keyframe_ring_is_bounded() {
        let mut policy = RecoveryIdrPolicy::default();
        for frame_id in 0..10 {
            policy.note_keyframe_sent(frame_id, f64::from(frame_id));
        }
        policy.note_keyframe_delivered(0);
        // Frame 0 fell out of the ring, so it cannot key a stale suppression.
        assert_ne!(policy.decide(100.0, Some(0), 0.020), IdrVerdict::SuppressStale);
    }

    /// Frame ids wrap, and the comparisons are distances rather than magnitudes.
    #[test]
    fn the_comparisons_survive_the_frame_id_wrap() {
        let mut policy = RecoveryIdrPolicy::default();
        policy.note_keyframe_sent(2, 1.0);
        assert_eq!(
            policy.decide(1.01, Some(u32::MAX), 0.020),
            IdrVerdict::SuppressInFlight,
            "u32::MAX is BEHIND frame 2, not ahead of it",
        );
    }
}
