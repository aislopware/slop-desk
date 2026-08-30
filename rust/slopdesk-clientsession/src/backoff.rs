//! How long a reconnect campaign waits, and when it stops waiting.
//!
//! A coding session wants a FAST re-grab, not a minutes-long backoff: the ceiling is two seconds,
//! not the thirty a general-purpose client would pick. Twenty attempts under the default schedule
//! is about thirty-five seconds of wall clock, after which the pane is told the host is unreachable
//! rather than left at a frozen "reconnecting" dot.
//!
//! Times cross as NANOSECONDS. The near side's own duration type carries attoseconds, and a
//! millisecond count would silently round a schedule somebody configured in fractions of one.

/// The wait before the first retry.
pub const DEFAULT_INITIAL_NS: u64 = 250_000_000;

/// The ceiling every later wait saturates at.
pub const DEFAULT_MAXIMUM_NS: u64 = 2_000_000_000;

/// What each wait multiplies by.
pub const DEFAULT_MULTIPLIER: f64 = 2.0;

/// How many attempts one SUPERVISED campaign makes before giving up.
///
/// The single source of truth for the ceiling. The app-global supervisor and the "attempt N of M"
/// copy both mirror this, so a mismatch cannot render an impossible "attempt 25 of 20".
pub const MAX_RECONNECT_ATTEMPTS: u32 = 20;

/// An exponential retry schedule, capped.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Backoff {
    /// The wait before the first retry, in nanoseconds.
    pub initial_ns: u64,
    /// The ceiling, in nanoseconds.
    pub maximum_ns: u64,
    /// What each step multiplies by.
    pub multiplier: f64,
}

impl Default for Backoff {
    fn default() -> Self {
        Self {
            initial_ns: DEFAULT_INITIAL_NS,
            maximum_ns: DEFAULT_MAXIMUM_NS,
            multiplier: DEFAULT_MULTIPLIER,
        }
    }
}

impl Backoff {
    /// The wait after `current_ns`, capped at [`maximum_ns`](Self::maximum_ns).
    ///
    /// A multiplier below one is not rejected — a schedule that converges is a legal thing to ask
    /// for — and a negative one lands at zero, because a saturating cast is the only reading of a
    /// negative wait that is not a wait of two hundred years.
    #[must_use]
    #[expect(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the product is compared against the ceiling before it is taken, and a nanosecond count \
                  only loses precision past 2^53 ns — 104 days, far above any retry wait"
    )]
    pub fn next_after(self, current_ns: u64) -> u64 {
        let scaled = (current_ns as f64) * self.multiplier;
        if scaled > self.maximum_ns as f64 {
            self.maximum_ns
        } else {
            scaled as u64
        }
    }

    /// The wait BEFORE the `attempt`-th retry, one-indexed.
    ///
    /// A closed form keyed on the attempt count rather than a running total, so it is testable
    /// without a clock and so "reset the schedule once a connection has been healthy" is simply
    /// "start again at attempt 1" — which a new campaign already does.
    ///
    /// Computed by STEPPING rather than by raising the multiplier to a power: the sequence has to
    /// be exactly the one a running total would produce, and it saturates rather than overflowing
    /// on an attempt count nobody bounded.
    ///
    /// Attempt 1 is the initial wait verbatim, even where that exceeds the ceiling: the first wait
    /// is the one that was asked for, and the ceiling governs the GROWTH.
    #[must_use]
    pub fn delay_for_attempt(self, attempt: u32) -> u64 {
        if attempt <= 1 {
            return self.initial_ns;
        }
        let mut delay = self.initial_ns;
        for _ in 1..attempt {
            delay = self.next_after(delay);
            if delay >= self.maximum_ns {
                break;
            }
        }
        delay
    }
}

/// Whether a supervised campaign has run out of attempts. One-indexed, asked after the counter
/// advances, so the campaign makes exactly [`MAX_RECONNECT_ATTEMPTS`] of them.
#[must_use]
pub const fn exhausted(attempt: u32) -> bool {
    attempt > MAX_RECONNECT_ATTEMPTS
}

#[cfg(test)]
mod tests {
    use super::{Backoff, DEFAULT_INITIAL_NS, DEFAULT_MAXIMUM_NS, MAX_RECONNECT_ATTEMPTS, exhausted};

    /// The shipped ladder, verbatim: a quarter second, then doubling to the two-second ceiling,
    /// where it stays for every attempt after.
    #[test]
    fn the_shipped_ladder_is_250_500_1000_2000() {
        let backoff = Backoff::default();
        let ladder: Vec<u64> = (1..=6).map(|n| backoff.delay_for_attempt(n)).collect();
        assert_eq!(ladder, vec![
            250_000_000,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            2_000_000_000,
            2_000_000_000
        ]);
    }

    /// Stepping and the closed form are the SAME schedule — the closed form exists to be testable,
    /// not to be a second one.
    #[test]
    fn the_closed_form_matches_a_running_total() {
        let backoff = Backoff::default();
        let mut running = backoff.initial_ns;
        for attempt in 1..=30 {
            assert_eq!(backoff.delay_for_attempt(attempt), running, "attempt {attempt}");
            running = backoff.next_after(running);
        }
    }

    /// The ceiling holds against an attempt count nobody bounded — no overflow, no wrap.
    #[test]
    fn a_huge_attempt_count_saturates_at_the_ceiling() {
        let backoff = Backoff::default();
        assert_eq!(backoff.delay_for_attempt(u32::MAX), DEFAULT_MAXIMUM_NS);
        assert_eq!(backoff.next_after(u64::MAX), DEFAULT_MAXIMUM_NS);
    }

    /// The first wait is the one that was asked for, even where it already exceeds the ceiling.
    #[test]
    fn the_first_wait_is_the_one_that_was_asked_for() {
        let backoff = Backoff {
            initial_ns: 9_000_000_000,
            maximum_ns: 2_000_000_000,
            multiplier: 2.0,
        };
        assert_eq!(backoff.delay_for_attempt(1), 9_000_000_000);
        assert_eq!(
            backoff.delay_for_attempt(2),
            2_000_000_000,
            "the growth is what is capped"
        );
    }

    /// A schedule that converges is legal, and a nonsensical one lands at zero rather than at two
    /// centuries.
    #[test]
    fn an_unusual_multiplier_is_honoured_not_rejected() {
        let converging = Backoff {
            initial_ns: 1_000_000,
            maximum_ns: 2_000_000_000,
            multiplier: 0.5,
        };
        assert_eq!(converging.delay_for_attempt(2), 500_000);
        assert_eq!(converging.delay_for_attempt(3), 250_000);

        let nonsense = Backoff {
            initial_ns: 1_000_000,
            maximum_ns: 2_000_000_000,
            multiplier: -2.0,
        };
        assert_eq!(nonsense.next_after(1_000_000), 0);
    }

    /// Sub-millisecond schedules survive the crossing — the reason the unit is nanoseconds.
    #[test]
    fn a_sub_millisecond_schedule_is_not_rounded_away() {
        let fine = Backoff {
            initial_ns: 1_500,
            maximum_ns: 1_000_000,
            multiplier: 2.0,
        };
        assert_eq!(fine.delay_for_attempt(1), 1_500);
        assert_eq!(fine.delay_for_attempt(2), 3_000);
    }

    /// The give-up gate fires one attempt PAST the ceiling, so the campaign makes exactly that
    /// many.
    #[test]
    fn the_campaign_makes_exactly_the_ceiling_of_attempts() {
        assert!(!exhausted(1));
        assert!(!exhausted(MAX_RECONNECT_ATTEMPTS));
        assert!(exhausted(MAX_RECONNECT_ATTEMPTS + 1));
    }

    /// The shipped ceiling is roughly thirty-five seconds of wall clock — the figure the pane's
    /// "could not reach the host" copy is written against.
    #[test]
    fn the_shipped_campaign_is_about_thirty_five_seconds() {
        let backoff = Backoff::default();
        let total: u64 = (1..=MAX_RECONNECT_ATTEMPTS)
            .map(|n| backoff.delay_for_attempt(n))
            .sum();
        assert!((33_000_000_000..=37_000_000_000).contains(&total), "{total} ns");
        assert_eq!(DEFAULT_INITIAL_NS, 250_000_000);
    }
}
