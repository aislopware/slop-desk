//! Pure SSH-window-style flow-control credit math for one direction of one channel — a
//! port of Swift `AislopdeskProtocol.FlowCreditPolicy`.
//!
//! Mirrors the SSH per-channel window: the sender may transmit at most
//! [`remaining`](FlowCreditPolicy::remaining) bytes before it must wait for the peer to
//! grant more credit via a `CHANNEL_WINDOW_ADJUST`. [`consume`](FlowCreditPolicy::consume)
//! debits the window; [`adjust`](FlowCreditPolicy::adjust) re-credits it. No IO, no clock.

/// The outcome of attempting to send some bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConsumeResult {
    /// The full request fit; carries the credit left afterwards.
    Allowed {
        /// Credit remaining after the debit.
        remaining: i64,
    },
    /// The window had insufficient credit; NOTHING was consumed. `available` is how much
    /// could be sent right now (0 when blocked).
    Insufficient {
        /// Credit currently sendable.
        available: i64,
    },
}

/// SSH-window credit accounting for the SENDER side of one channel direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlowCreditPolicy {
    /// The window size the channel started with (the natural reference for "how much has
    /// been consumed").
    initial_window: i64,
    /// Bytes of credit still available to send. Never negative.
    remaining: i64,
}

impl FlowCreditPolicy {
    /// Creates a window with `initial_window` bytes of credit (clamped non-negative).
    #[must_use]
    pub fn new(initial_window: i64) -> Self {
        let start = initial_window.max(0);
        Self {
            initial_window: start,
            remaining: start,
        }
    }

    /// The window size the channel started with.
    #[must_use]
    pub const fn initial_window(&self) -> i64 {
        self.initial_window
    }

    /// Bytes of credit still available to send.
    #[must_use]
    pub const fn remaining(&self) -> i64 {
        self.remaining
    }

    /// Attempts to debit `bytes` from the window. All-or-nothing: if fewer than `bytes`
    /// credit remains, the window is left untouched and
    /// [`ConsumeResult::Insufficient`] reports how much is currently sendable. A zero- or
    /// negative-byte request is always allowed and consumes nothing.
    pub fn consume(&mut self, bytes: i64) -> ConsumeResult {
        let want = bytes.max(0);
        if want > self.remaining {
            return ConsumeResult::Insufficient {
                available: self.remaining,
            };
        }
        self.remaining -= want;
        ConsumeResult::Allowed {
            remaining: self.remaining,
        }
    }

    /// Re-credits the window by `bytes_to_add` (an SSH `CHANNEL_WINDOW_ADJUST`). Negative
    /// grants are ignored. Replenishing a blocked window unblocks it.
    ///
    /// Overflow-safe: a huge peer-chosen grant (or a long run of grants) saturates at
    /// [`i64::MAX`] instead of trapping. SSH-style windows may legitimately grow PAST
    /// `initial_window` (it is the starting reference, not a hard cap), so this does NOT
    /// clamp to the window; it only defuses the overflow trap.
    pub const fn adjust(&mut self, bytes_to_add: i64) {
        if bytes_to_add <= 0 {
            return;
        }
        let (sum, overflowed) = self.remaining.overflowing_add(bytes_to_add);
        self.remaining = if overflowed { i64::MAX } else { sum };
    }

    /// Whether the window is exhausted (no credit to send even a single byte).
    #[must_use]
    pub const fn is_blocked(&self) -> bool {
        self.remaining <= 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_window_is_full_credit_and_unblocked() {
        let policy = FlowCreditPolicy::new(1024);
        assert_eq!(policy.initial_window(), 1024);
        assert_eq!(policy.remaining(), 1024);
        assert!(!policy.is_blocked());
    }

    #[test]
    fn consume_within_window_debits_remaining() {
        let mut policy = FlowCreditPolicy::new(100);
        assert_eq!(policy.consume(30), ConsumeResult::Allowed { remaining: 70 });
        assert_eq!(policy.remaining(), 70);
        assert_eq!(policy.consume(70), ConsumeResult::Allowed { remaining: 0 });
        assert_eq!(policy.remaining(), 0);
        assert!(policy.is_blocked());
    }

    #[test]
    fn consume_beyond_window_is_all_or_nothing() {
        let mut policy = FlowCreditPolicy::new(50);
        assert_eq!(
            policy.consume(51),
            ConsumeResult::Insufficient { available: 50 }
        );
        assert_eq!(
            policy.remaining(),
            50,
            "an over-budget request must not partially debit"
        );
        assert!(!policy.is_blocked());
    }

    #[test]
    fn exhaustion_blocks() {
        let mut policy = FlowCreditPolicy::new(10);
        assert_eq!(policy.consume(10), ConsumeResult::Allowed { remaining: 0 });
        assert!(policy.is_blocked());
        assert_eq!(
            policy.consume(1),
            ConsumeResult::Insufficient { available: 0 }
        );
    }

    #[test]
    fn adjust_replenishes_and_unblocks() {
        let mut policy = FlowCreditPolicy::new(8);
        assert_eq!(policy.consume(8), ConsumeResult::Allowed { remaining: 0 });
        assert!(policy.is_blocked());
        policy.adjust(16);
        assert!(!policy.is_blocked());
        assert_eq!(policy.remaining(), 16);
        assert_eq!(policy.consume(12), ConsumeResult::Allowed { remaining: 4 });
    }

    #[test]
    fn adjust_can_grow_beyond_initial_window() {
        let mut policy = FlowCreditPolicy::new(4);
        policy.adjust(100);
        assert_eq!(policy.remaining(), 104);
        assert_eq!(policy.initial_window(), 4);
    }

    #[test]
    fn negative_and_zero_grants_ignored() {
        let mut policy = FlowCreditPolicy::new(5);
        policy.adjust(0);
        assert_eq!(policy.remaining(), 5);
        policy.adjust(-10);
        assert_eq!(
            policy.remaining(),
            5,
            "a negative grant must not shrink the window"
        );
    }

    #[test]
    fn zero_and_negative_consume_is_allowed_and_consumes_nothing() {
        let mut policy = FlowCreditPolicy::new(5);
        assert_eq!(policy.consume(0), ConsumeResult::Allowed { remaining: 5 });
        assert_eq!(policy.consume(-3), ConsumeResult::Allowed { remaining: 5 });
        assert_eq!(policy.remaining(), 5);
    }

    #[test]
    fn negative_initial_window_clamps_to_zero_and_blocks() {
        let policy = FlowCreditPolicy::new(-100);
        assert_eq!(policy.initial_window(), 0);
        assert_eq!(policy.remaining(), 0);
        assert!(policy.is_blocked());
    }

    #[test]
    fn adjust_is_overflow_safe_and_still_growable() {
        let mut policy = FlowCreditPolicy::new(1000);
        policy.adjust(5000);
        assert_eq!(
            policy.remaining(),
            6000,
            "a grant grows past initial (SSH auto-tuning)"
        );
        for _ in 0..3 {
            policy.adjust(i64::MAX);
        }
        assert_eq!(
            policy.remaining(),
            i64::MAX,
            "repeated huge grants saturate, no trap"
        );
        assert!(!policy.is_blocked());
        let mut p2 = FlowCreditPolicy::new(256 * 1024);
        p2.adjust(i64::from(u32::MAX));
        assert_eq!(p2.remaining(), 256 * 1024 + i64::from(u32::MAX));
    }
}
