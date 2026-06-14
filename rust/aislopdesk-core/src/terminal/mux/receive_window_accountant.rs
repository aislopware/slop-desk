//! Pure receiver-side accounting for ONE direction of ONE channel — a port of Swift
//! `AislopdeskProtocol.ReceiveWindowAccountant`.
//!
//! The symmetric peer of [`FlowCreditPolicy`](super::FlowCreditPolicy) (which lives on the
//! SENDER): the receiver re-credits the sender by emitting a window-adjust once it has
//! consumed "enough" of the window. Emitting on a HALF-WINDOW threshold (rather than per
//! byte) keeps a window-adjust frame off the wire for every chunk while still keeping the
//! sender's window from draining to zero under a steady stream — the standard
//! amortised-credit trade-off (yamux / RFC 9113 §5.2 / RFC 4254). No IO, no clock.

/// Half-window replenish-decision accounting for the RECEIVER side of one channel direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReceiveWindowAccountant {
    /// The receive window size (the same value the sender uses as its initial send
    /// window). Half of this is the replenish threshold.
    initial_window: i64,
    /// Bytes consumed but NOT yet granted back via a window-adjust. Reset to 0 on a grant.
    pending_credit: i64,
}

impl ReceiveWindowAccountant {
    /// Creates an accountant for a window of `initial_window` bytes (clamped non-negative).
    #[must_use]
    pub fn new(initial_window: i64) -> Self {
        Self {
            initial_window: initial_window.max(0),
            pending_credit: 0,
        }
    }

    /// The receive window size.
    #[must_use]
    pub const fn initial_window(&self) -> i64 {
        self.initial_window
    }

    /// Bytes consumed but not yet granted back to the sender.
    #[must_use]
    pub const fn pending_credit(&self) -> i64 {
        self.pending_credit
    }

    /// The half-window replenish threshold: once `pending_credit` reaches this, emit a
    /// grant. At least 1 for any positive window so a tiny window still makes progress; a
    /// zero/negative window disables grants ([`i64::MAX`]).
    #[must_use]
    pub fn threshold(&self) -> i64 {
        if self.initial_window <= 0 {
            i64::MAX
        } else {
            (self.initial_window / 2).max(1)
        }
    }

    /// Records that `bytes` were consumed and returns the amount of credit to GRANT back
    /// to the sender right now, or `None` if the half-window threshold has not yet been
    /// crossed (accumulate and wait).
    ///
    /// All-or-nothing per crossing: when the threshold is crossed the WHOLE accumulated
    /// `pending_credit` is granted (and reset to 0). A zero/negative consume grants
    /// nothing. A zero/negative window never grants.
    pub fn consume(&mut self, bytes: i64) -> Option<i64> {
        if self.initial_window <= 0 {
            return None;
        }
        let took = bytes.max(0);
        self.pending_credit += took;
        if self.pending_credit < self.threshold() {
            return None;
        }
        let grant = self.pending_credit;
        self.pending_credit = 0;
        Some(grant)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_grant_below_half_window_threshold() {
        let mut acc = ReceiveWindowAccountant::new(1000);
        assert_eq!(acc.threshold(), 500);
        assert_eq!(acc.consume(100), None, "100 < 500 → accumulate");
        assert_eq!(acc.consume(399), None, "499 < 500 → still below");
        assert_eq!(acc.pending_credit(), 499);
    }

    #[test]
    fn grants_whole_pending_once_threshold_crossed() {
        let mut acc = ReceiveWindowAccountant::new(1000);
        assert_eq!(acc.consume(300), None);
        assert_eq!(
            acc.consume(250),
            Some(550),
            "300+250=550 ≥ 500 → grant the full 550"
        );
        assert_eq!(acc.pending_credit(), 0);
        assert_eq!(
            acc.consume(100),
            None,
            "fresh accumulation starts below threshold"
        );
    }

    #[test]
    fn single_large_consume_crosses_threshold_immediately() {
        let mut acc = ReceiveWindowAccountant::new(1000);
        assert_eq!(acc.consume(800), Some(800));
        assert_eq!(acc.pending_credit(), 0);
    }

    #[test]
    fn exact_threshold_grants() {
        let mut acc = ReceiveWindowAccountant::new(1000);
        assert_eq!(acc.consume(500), Some(500));
    }

    #[test]
    fn zero_and_negative_consume_grants_nothing() {
        let mut acc = ReceiveWindowAccountant::new(1000);
        assert_eq!(acc.consume(0), None);
        assert_eq!(acc.consume(-50), None);
        assert_eq!(acc.pending_credit(), 0);
    }

    #[test]
    fn zero_window_never_grants() {
        let mut acc = ReceiveWindowAccountant::new(0);
        assert_eq!(acc.consume(1_000_000), None);
        assert_eq!(acc.threshold(), i64::MAX);
        let neg = ReceiveWindowAccountant::new(-100);
        assert_eq!(neg.initial_window(), 0, "negative window clamps to zero");
    }

    #[test]
    fn tiny_window_threshold_is_at_least_one() {
        let mut acc = ReceiveWindowAccountant::new(1);
        assert_eq!(acc.threshold(), 1, "a 1-byte window still makes progress");
        assert_eq!(acc.consume(1), Some(1));
    }
}
