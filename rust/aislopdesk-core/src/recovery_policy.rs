//! Client-side recovery DECISION logic — a port of the policy half of Swift
//! `RecoverySignaling` (`RecoveryPolicy`, `RecoveryRequestRedundancy`,
//! `LossObservationWindow`).
//!
//! Pure deciders; the timer/transport lives above this crate.

use crate::recovery::RecoveryMessage;

/// Default lossy-escalation floor when the env override is absent/garbage (60 ms).
const DEFAULT_ESCALATION_FLOOR_SECS: f64 = 0.06;

/// Pure env resolution for the lossy floor: parses `AISLOPDESK_ESCALATION_FLOOR_MS`,
/// default 60 ms, clamped to 20..=500 ms; absent/garbage/out-of-band keep the default.
///
/// INTENTIONAL deviation from Swift parity (documented, tested): Swift's
/// `Double(String)` additionally accepts C hex-float notation (e.g. `"0x64"` → 100.0),
/// which Rust's `str::parse::<f64>` rejects → falls back to the default here. This knob
/// is a milliseconds value and is only ever set to a plain decimal like `"60"`; matching
/// Swift's incidental hex-float acceptance would mean hand-rolling a hex-float parser
/// (its own risk surface) for input no operator writes. NaN/±∞ are rejected identically
/// on both sides via the finite + range guard, so only the absurd hex-float case differs.
#[must_use]
pub fn escalation_floor_seconds(env_value: Option<&str>) -> f64 {
    match env_value.and_then(|s| s.parse::<f64>().ok()) {
        Some(v) if v.is_finite() && (20.0..=500.0).contains(&v) => v / 1000.0,
        _ => DEFAULT_ESCALATION_FLOOR_SECS,
    }
}

/// Resolves the lossy-escalation floor from the live process environment.
#[must_use]
pub fn default_lossy_escalation_floor() -> f64 {
    escalation_floor_seconds(
        std::env::var("AISLOPDESK_ESCALATION_FLOOR_MS")
            .ok()
            .as_deref(),
    )
}

/// Models the client-side recovery policy: which message to send for a detected loss, and
/// when to escalate to a forced IDR.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryPolicy {
    /// Escalate to IDR if no decodable frame arrives within this multiple of RTT.
    pub idr_timeout_rtt_multiple: f64,
    /// The HALVED escalation multiple used while observing loss.
    pub lossy_idr_timeout_rtt_multiple: f64,
    /// Floor (seconds) on the lossy deadline (constant part).
    pub lossy_escalation_floor: f64,
    /// The RTT-proportional part of the lossy floor.
    pub lossy_escalation_floor_rtt_multiple: f64,
}

impl RecoveryPolicy {
    /// Builds a policy with explicit parameters.
    #[must_use]
    pub const fn new(
        idr_timeout_rtt_multiple: f64,
        lossy_idr_timeout_rtt_multiple: f64,
        lossy_escalation_floor: f64,
        lossy_escalation_floor_rtt_multiple: f64,
    ) -> Self {
        Self {
            idr_timeout_rtt_multiple,
            lossy_idr_timeout_rtt_multiple,
            lossy_escalation_floor,
            lossy_escalation_floor_rtt_multiple,
        }
    }

    /// The first message to send when frames `[lost_from, lost_to]` are detected lost:
    /// prefer an LTR refresh, threading the decode frontier through for the host's
    /// delivery-keyed cooldown.
    #[must_use]
    pub const fn initial_request(
        lost_from: u32,
        lost_to: u32,
        last_decoded: u32,
    ) -> RecoveryMessage {
        RecoveryMessage::RequestLtrRefresh {
            from_frame_id: lost_from,
            to_frame_id: lost_to,
            last_decoded_frame_id: last_decoded,
        }
    }

    /// The loss-adaptive escalation clock. `observing_loss == false` ⇒ `2·RTT`, no floor.
    /// `observing_loss == true` ⇒ the halved clock floored at the physically-arrivable
    /// response time `max(lossy_idr_multiple·RTT, floor, floor_rtt_multiple·RTT)`.
    #[must_use]
    pub fn should_escalate_to_idr(
        &self,
        elapsed_since_request: f64,
        rtt: f64,
        observing_loss: bool,
    ) -> bool {
        let deadline = if observing_loss {
            let floor = self
                .lossy_escalation_floor
                .max(self.lossy_escalation_floor_rtt_multiple * rtt);
            (self.lossy_idr_timeout_rtt_multiple * rtt).max(floor)
        } else {
            self.idr_timeout_rtt_multiple * rtt
        };
        elapsed_since_request >= deadline
    }
}

impl Default for RecoveryPolicy {
    /// Today's defaults: `2·RTT` normal, `1·RTT` lossy, env-resolved floor, 1.5·RTT floor
    /// multiple.
    fn default() -> Self {
        Self::new(2.0, 1.0, default_lossy_escalation_floor(), 1.5)
    }
}

/// How many byte-identical copies of one logical recovery request the client sends, and
/// their spacing — a redundancy against a lost request riding the same lossy path.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecoveryRequestRedundancy {
    /// Total sends per logical request, clamped to 1..=5.
    pub copies: u32,
    /// Gap between consecutive copies (seconds).
    pub spacing: f64,
}

impl RecoveryRequestRedundancy {
    /// Builds a redundancy config, clamping `copies` to 1..=5.
    #[must_use]
    pub fn new(copies: u32, spacing: f64) -> Self {
        Self {
            copies: copies.clamp(1, 5),
            spacing,
        }
    }

    /// Send-time offsets for one logical request: `[0, spacing, 2·spacing, …]`.
    #[must_use]
    pub fn send_offsets(&self) -> Vec<f64> {
        (0..self.copies)
            .map(|i| f64::from(i) * self.spacing)
            .collect()
    }

    /// `P(all copies lost)` under i.i.d. per-datagram loss `p`: `clamp01(p)^copies`.
    #[must_use]
    pub fn all_copies_lost_probability(per_datagram_loss: f64, copies: u32) -> f64 {
        let p = per_datagram_loss.clamp(0.0, 1.0);
        let n = copies.clamp(1, 5);
        let mut out = 1.0;
        for _ in 0..n {
            out *= p;
        }
        out
    }

    /// Expected freeze added by request loss per loss event: `P(all copies lost) ×
    /// escalation_delay`.
    #[must_use]
    pub fn expected_request_loss_freeze(
        per_datagram_loss: f64,
        copies: u32,
        escalation_delay: f64,
    ) -> f64 {
        Self::all_copies_lost_probability(per_datagram_loss, copies) * escalation_delay
    }
}

impl Default for RecoveryRequestRedundancy {
    /// 3 copies, 3 ms spacing.
    fn default() -> Self {
        Self::new(3, 0.003)
    }
}

/// The client-side loss-observing predicate gating the halved escalation clock.
///
/// Events
/// (unrecoverable losses and FEC-recovered completions) are fed in; the window reports
/// "observing loss" once enough events are recent.
#[derive(Debug, Clone, PartialEq)]
pub struct LossObservationWindow {
    window_seconds: f64,
    min_events: usize,
    capacity: usize,
    /// Event timestamps (seconds, caller's monotonic clock), newest last.
    events: Vec<f64>,
}

impl LossObservationWindow {
    /// Builds a window. `min_events` and `capacity` are floored at 1.
    #[must_use]
    pub fn new(window_seconds: f64, min_events: usize, capacity: usize) -> Self {
        Self {
            window_seconds,
            min_events: min_events.max(1),
            capacity: capacity.max(1),
            events: Vec::new(),
        }
    }

    /// Records one loss-ish event at `now`. Prunes events older than the window;
    /// drop-oldest at capacity (bounded regardless of feed rate).
    pub fn note_event(&mut self, now: f64) {
        self.events.retain(|&t| now - t <= self.window_seconds);
        if self.events.len() >= self.capacity {
            let remove = self.events.len() - self.capacity + 1;
            self.events.drain(0..remove);
        }
        self.events.push(now);
    }

    /// Whether ≥ `min_events` events lie within `window_seconds` of `now` (pure read).
    #[must_use]
    pub fn is_observing_loss(&self, now: f64) -> bool {
        self.events
            .iter()
            .filter(|&&t| now - t <= self.window_seconds && now - t >= 0.0)
            .count()
            >= self.min_events
    }
}

impl Default for LossObservationWindow {
    /// `{1.0 s, ≥2 events, capacity 8}`.
    fn default() -> Self {
        Self::new(1.0, 2, 8)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-12, "{a} != {b}");
    }

    #[test]
    fn escalation_floor_env_parsing() {
        approx(escalation_floor_seconds(None), 0.06);
        approx(escalation_floor_seconds(Some("garbage")), 0.06);
        approx(escalation_floor_seconds(Some("10")), 0.06); // below clamp → default
        approx(escalation_floor_seconds(Some("600")), 0.06); // above clamp → default
        approx(escalation_floor_seconds(Some("100")), 0.1);
        approx(escalation_floor_seconds(Some("inf")), 0.06);
        // INTENTIONAL deviation from Swift (documented on the fn): hex-float notation that
        // Swift's `Double(String)` would honour is rejected here → default. No operator sets
        // a milliseconds knob in hex-float form.
        approx(escalation_floor_seconds(Some("0x64")), 0.06);
        approx(escalation_floor_seconds(Some("0x1.4p5")), 0.06);
    }

    #[test]
    fn normal_escalation_is_two_rtt() {
        let p = RecoveryPolicy::new(2.0, 1.0, 0.06, 1.5);
        assert!(!p.should_escalate_to_idr(0.19, 0.1, false)); // < 2·0.1
        assert!(p.should_escalate_to_idr(0.20, 0.1, false)); // == 2·RTT
    }

    #[test]
    fn lossy_escalation_floored() {
        let p = RecoveryPolicy::new(2.0, 1.0, 0.06, 1.5);
        // rtt 10ms: max(1·0.01, max(0.06, 1.5·0.01=0.015)) = max(0.01, 0.06) = 0.06s
        assert!(!p.should_escalate_to_idr(0.05, 0.01, true));
        assert!(p.should_escalate_to_idr(0.06, 0.01, true));
        // rtt 100ms: max(1·0.1, max(0.06, 1.5·0.1)) = ~0.15s (avoid the exact-boundary
        // fp tie: 1.5*0.1 == 0.15000000000000002, matching Swift's IEEE result).
        assert!(!p.should_escalate_to_idr(0.14, 0.1, true));
        assert!(p.should_escalate_to_idr(0.16, 0.1, true));
    }

    #[test]
    fn redundancy_clamps_and_offsets() {
        let r = RecoveryRequestRedundancy::new(9, 0.003);
        assert_eq!(r.copies, 5);
        let offsets = r.send_offsets();
        assert_eq!(offsets.len(), 5);
        for i in 0u32..5 {
            // i·spacing, fp-exact to Swift's `Double(i) * spacing`.
            approx(offsets[i as usize], f64::from(i) * 0.003);
        }
        let r1 = RecoveryRequestRedundancy::new(0, 0.005);
        assert_eq!(r1.copies, 1);
    }

    #[test]
    fn all_copies_lost_probability_math() {
        approx(
            RecoveryRequestRedundancy::all_copies_lost_probability(0.1, 3),
            0.001,
        );
        // clamps p and copies
        approx(
            RecoveryRequestRedundancy::all_copies_lost_probability(2.0, 1),
            1.0,
        );
        approx(
            RecoveryRequestRedundancy::all_copies_lost_probability(-1.0, 3),
            0.0,
        );
    }

    #[test]
    fn loss_window_observes_after_min_events() {
        let mut w = LossObservationWindow::new(1.0, 2, 8);
        w.note_event(10.0);
        assert!(!w.is_observing_loss(10.0)); // only 1 event
        w.note_event(10.5);
        assert!(w.is_observing_loss(10.5)); // 2 within 1s
                                            // both age out by t=12
        assert!(!w.is_observing_loss(12.0));
    }

    #[test]
    fn loss_window_capacity_bounded() {
        let mut w = LossObservationWindow::new(100.0, 2, 3);
        for t in 0..10 {
            w.note_event(f64::from(t));
        }
        // capacity 3 → at most 3 retained; observing loss with min 2.
        assert!(w.is_observing_loss(9.0));
    }
}
