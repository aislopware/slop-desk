//! Where an anti-flood bucket comes FROM.
//!
//! [`crate::notify`] already has the door that spends a token, and the bucket crosses by value in
//! both directions there — so the near side owns the four fields between calls. That left one thing
//! on the wrong side of the boundary: what a NEW bucket holds. It is not an assignment. A bucket
//! that rests full delivers the first explicit notification after an attach; one that rests empty
//! swallows it while it fills, which is a rate limiter behaving like a bug. And the burst and the
//! refill rate are the anti-flood policy itself — the numbers that decide how much a hostile shell
//! may post — which had been living in a Swift default argument.
//!
//! Both doors answer BY VALUE, so this is [`crate::chrome`]'s resting-gate shape rather than a
//! third convention: nothing is allocated, nothing is retained, and the whole answer is four
//! doubles.

use slopdesk_workspace::notify::RateLimiter;

use crate::notify::CNotifyRateLimiter;

/// The bucket a `RateLimiter` rests at, flattened.
const fn resting(bucket: RateLimiter) -> CNotifyRateLimiter {
    CNotifyRateLimiter {
        capacity: bucket.capacity,
        refill_per_second: bucket.refill_per_second,
        tokens: bucket.tokens,
        last_refill: bucket.last_refill,
    }
}

/// A full bucket at the burst and refill rate the caller names, its clock starting at `now`.
///
/// "Full" is the crate's answer and not the caller's: the tokens rest at the capacity, so the first
/// notification through a fresh bucket is delivered.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_rate_limiter(
    capacity: f64,
    refill_per_second: f64,
    now: f64,
) -> CNotifyRateLimiter {
    resting(RateLimiter::new(capacity, refill_per_second, now))
}

/// The bucket the explicit (OSC 9/777) path ships with, its clock starting at `now`.
///
/// Its burst and its refill rate come from the crate rather than from a caller's default argument,
/// for the reason every constant behind a door here does: two spellings of "how much may a remote
/// shell post" are two anti-flood policies, and the looser one is the one that would run.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_ws_notify_explicit_rate_limiter(now: f64) -> CNotifyRateLimiter {
    resting(RateLimiter::explicit(now))
}

#[cfg(test)]
mod tests {
    #![expect(unsafe_code, reason = "calling the door is the only way to test the door")]

    use super::{slopdesk_ws_notify_explicit_rate_limiter, slopdesk_ws_notify_rate_limiter};
    use crate::notify::{CNotifyRateLimiter, slopdesk_ws_notify_rate_limit_allow};

    /// Spends a token through the door the way Swift does.
    fn spend(bucket: &mut CNotifyRateLimiter, now: f64) -> bool {
        // SAFETY: one live local, borrowed for the call.
        unsafe { slopdesk_ws_notify_rate_limit_allow(&raw mut *bucket, now) }
    }

    #[test]
    fn a_bucket_from_the_door_rests_full_and_the_spend_door_agrees_with_it() {
        let mut bucket = slopdesk_ws_notify_rate_limiter(2.0, 1.0, 10.0);
        assert_eq!(
            bucket.tokens.to_bits(),
            2.0_f64.to_bits(),
            "a resting bucket is full, never empty"
        );
        assert_eq!(bucket.last_refill.to_bits(), 10.0_f64.to_bits());
        assert!(spend(&mut bucket, 10.0));
        assert!(spend(&mut bucket, 10.0));
        assert!(!spend(&mut bucket, 10.0), "the burst is the capacity");
        assert!(spend(&mut bucket, 11.0), "a second buys one back at this rate");
    }

    /// The shipped numbers are asserted as BEHAVIOUR rather than restated: five back to back, then
    /// one every two seconds. A retune has to move that to pass, and a near side that spelled its
    /// own defaults would not have been able to.
    #[test]
    fn the_explicit_bucket_carries_the_crate_s_own_burst_and_trickle() {
        let mut bucket = slopdesk_ws_notify_explicit_rate_limiter(0.0);
        let burst = (0..6).filter(|_| spend(&mut bucket, 0.0)).count();
        assert_eq!(burst, 5);
        assert!(!spend(&mut bucket, 1.9), "under two seconds buys nothing back");
        assert!(spend(&mut bucket, 2.0), "two seconds buys exactly one");
    }
}
