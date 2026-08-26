//! The app-layer round trip, smoothed.
//!
//! One `ping` carries this client's own monotonic timestamp; the host echoes it verbatim in the
//! `pong`, so the arithmetic never involves the host's clock and no clock skew reaches the reading.
//! What is left is one subtraction and one exponential average, and neither needs a clock of its
//! own — the near side reads the monotonic counter and hands both instants in.

/// The smoothing weight on a fresh sample. `0.25` is the TCP SRTT family's 1/8–1/4: responsive to a
/// change in the weather without flapping on a single outlier.
pub const ALPHA: f64 = 0.25;

/// Folds one pong into the smoothed round trip, or answers `None` for a sample there is nothing to
/// say about.
///
/// `None` comes back only when the echoed timestamp is in the future of the instant it came back
/// at, which a monotonic clock cannot produce honestly — so it is a hostile or corrupted echo, and
/// the previous reading stands rather than being poisoned by it. The near side surfaces a reading
/// only when one comes back.
///
/// A stale pong from before a suspend yields a very large sample, which is not an error: the
/// average absorbs it and the next few samples correct it.
///
/// The two products are kept separate — never a fused multiply-add — because the reading is a value
/// the wire and the golden vectors round twice, and a single rounding is a different number.
#[must_use]
#[expect(
    clippy::cast_precision_loss,
    reason = "a millisecond count only loses precision past 2^53 ms, which is 285,000 years of uptime"
)]
pub fn fold(now_ms: u64, sent_at_ms: u64, previous: Option<f64>) -> Option<f64> {
    let sample = now_ms.checked_sub(sent_at_ms)? as f64;
    Some(previous.map_or(sample, |smoothed| smoothed * (1.0 - ALPHA) + sample * ALPHA))
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the reading is a bit-exact value the wire pins; an epsilon would stop noticing a \
                  re-rounding"
    )]

    use super::{ALPHA, fold};

    /// The first sample IS the reading — there is nothing yet to average it against.
    #[test]
    fn the_first_pong_is_the_reading() {
        assert_eq!(fold(1_100, 1_000, None), Some(100.0));
    }

    /// A later sample moves the reading by exactly alpha, in the two separate products the wire
    /// rounds by.
    #[test]
    fn a_later_pong_moves_the_reading_by_alpha() {
        let smoothed = fold(1_300, 1_000, Some(100.0));
        assert_eq!(smoothed, Some(100.0 * 0.75 + 300.0 * 0.25));
        assert_eq!(ALPHA, 0.25);
    }

    /// An echo from the future of its own arrival is not a sample. The previous reading stands, and
    /// the near side is told there is nothing to surface.
    #[test]
    fn an_impossible_echo_is_not_a_sample() {
        assert_eq!(fold(1_000, 1_001, Some(42.0)), None);
        assert_eq!(fold(0, u64::MAX, None), None);
    }

    /// A pong that came back in the same millisecond reads zero rather than nothing — a link fast
    /// enough to answer inside the clock's resolution has still answered.
    #[test]
    fn an_instant_pong_reads_zero() {
        assert_eq!(fold(1_000, 1_000, None), Some(0.0));
    }

    /// A huge sample from a resumed suspend is absorbed rather than latched: it moves the reading a
    /// quarter of the way and the samples after it walk it back.
    #[test]
    fn a_suspend_outlier_is_absorbed_not_latched() {
        let spiked = fold(1_000_000, 0, Some(100.0)).unwrap_or_default();
        assert!(spiked < 1_000_000.0, "the outlier does not become the reading");
        let mut reading = spiked;
        for _ in 0..40 {
            reading = fold(1_020, 1_000, Some(reading)).unwrap_or_default();
        }
        assert!(
            reading < 60.0,
            "and the link's real weather wins it back: {reading}"
        );
    }
}
