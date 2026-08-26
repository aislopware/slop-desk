//! The two clocks a pane's truths are stamped with, and why they are two.
//!
//! `slopdesk_muxsession::truths::Stamps` takes both and says why: the title stamp is compared
//! against a scale that survives sleep, and every agent-detection fold runs on a monotonic one.
//! The Swift read them as `Date().timeIntervalSinceReferenceDate` and
//! `ProcessInfo.processInfo.systemUptime`; these are the same two clocks, read the same way.
//!
//! [`reference_now`] is Foundation's reference date reproduced arithmetically rather than
//! approximated: the constant is exact and documented, so a stamp taken here and a stamp taken by
//! the Swift host during a cutover name the same instant.
//!
//! [`uptime_now`] is `CLOCK_MONOTONIC`, which on Darwin is seconds since boot and is precisely what
//! `systemUptime` returns. Reading it through `nix` keeps this crate `forbid(unsafe_code)` — the
//! wrapper is safe, so no syscall obligation is created here for `slopdesk-posix` to carry.
//!
//! ## One thing found while porting, recorded rather than changed
//!
//! `slopdesk_wire::document::fields::title_is_fresh` compares the title stamp against the
//! command-started stamp, and its door calls both "host-timeline seconds" — but the host feeds it
//! one of each of these two clocks, which differ by the machine's boot instant. That is the
//! behaviour shipping today, so the port reproduces it exactly; changing it is a decision about the
//! freshness rule and belongs where that rule is read, not inside a port that is supposed to be
//! observably identical.

use std::time::{SystemTime, UNIX_EPOCH};

use nix::sys::time::TimeSpec;
use nix::time::{ClockId, clock_gettime};

/// Seconds between the Unix epoch and Foundation's reference date (2001-01-01 00:00:00 UTC).
///
/// Exact by definition: 31 years, of which 1972, 1976, 1980, 1984, 1988, 1992, 1996 and 2000 were
/// leap years, and no leap SECOND is counted because Unix time does not count them either.
const REFERENCE_DATE_UNIX_SECONDS: f64 = 978_307_200.0;

/// Nanoseconds per second, as an `f64` — the divisor both readings share.
const NANOS_PER_SECOND: f64 = 1_000_000_000.0;

/// Seconds since Foundation's reference date.
///
/// A clock that steps — the one the title stamp needs, because a laptop that slept for an hour must
/// still be able to say the title is an hour old. Before the reference date the answer is negative,
/// which is a real value on this timeline rather than a sentinel; nothing here branches on it.
#[must_use]
pub(crate) fn reference_now() -> f64 {
    let since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64());
    since_epoch - REFERENCE_DATE_UNIX_SECONDS
}

/// Monotonic seconds since boot — Darwin's `systemUptime`.
///
/// A clock that cannot go backwards, which is what every duration measured across a fold needs. A
/// `clock_gettime` that fails has no meaningful fallback, so it reads zero: every consumer compares
/// two readings of this clock, and two zeroes are an elapsed time of nothing rather than a
/// direction-reversed one.
#[must_use]
pub(crate) fn uptime_now() -> f64 {
    clock_gettime(ClockId::CLOCK_MONOTONIC).map_or(0.0, seconds)
}

/// One `timespec` as fractional seconds.
fn seconds(spec: TimeSpec) -> f64 {
    #[expect(
        clippy::cast_precision_loss,
        reason = "seconds since boot is under 2^53 for any machine that has ever run, and the nanosecond \
                  field is under 2^30 by its own definition"
    )]
    let whole = spec.tv_sec() as f64;
    #[expect(
        clippy::cast_precision_loss,
        reason = "0..1_000_000_000 is exactly representable"
    )]
    let fraction = spec.tv_nsec() as f64 / NANOS_PER_SECOND;
    whole + fraction
}

/// Both stamps, read together.
///
/// Together on purpose: a fold that read one clock at the top and the other at the bottom would
/// stamp two truths from the same batch as if they had arrived at different times.
#[must_use]
pub(crate) fn stamps() -> slopdesk_muxsession::truths::Stamps {
    slopdesk_muxsession::truths::Stamps {
        reference: reference_now(),
        uptime: uptime_now(),
    }
}

#[cfg(test)]
mod tests {
    use super::{reference_now, stamps, uptime_now};

    /// The reference date is behind us, so a stamp taken now is a large positive number — and it is
    /// the SAME number Foundation would answer, which is the only property that matters if a Rust
    /// host and a Swift host ever stamp the same pane.
    #[test]
    fn the_reference_clock_is_seconds_since_2001() {
        let now = reference_now();
        // 2024-01-01 and 2100-01-01 in the same scale. A test that pinned a tighter window would
        // fail on a machine whose clock is merely wrong rather than on a bug here.
        assert!(now > 725_846_400.0, "reference clock behind 2024: {now}");
        assert!(now < 3_155_760_000.0, "reference clock past 2100: {now}");
    }

    /// The monotonic clock advances and never retreats.
    #[test]
    fn the_uptime_clock_only_moves_forward() {
        let first = uptime_now();
        let second = uptime_now();
        assert!(second >= first, "uptime went backwards: {first} then {second}");
        assert!(first > 0.0, "uptime should be seconds since boot, got {first}");
    }

    /// The two are different scales, and a `Stamps` carries one of each rather than one twice.
    #[test]
    fn the_two_stamps_are_not_the_same_clock() {
        let taken = stamps();
        let difference = taken.reference - taken.uptime;
        assert!(
            difference > 1.0,
            "reference and uptime read the same clock: {taken:?}",
        );
    }
}
