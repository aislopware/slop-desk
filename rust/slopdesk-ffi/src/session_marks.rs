//! The retry SCHEDULE, in C — the two shipped numbers a near side still names.
//!
//! ## What this file used to be, and why almost all of it went
//!
//! Eighteen doors: the session marks crossing by value, `deliver`/`ack`/`adopt`/`stream_ended`
//! stepping them in place, the four gates, the round-trip fold, and the whole ladder. Their caller
//! was the SWIFT pane session — `SlopDeskClient.swift` and `ReconnectManager.swift` — and `docs/63`
//! §G.5 replaced it with `rust/slopdesk-clientdriver`, which calls `slopdesk_clientsession` as a
//! crate. Sixteen of the eighteen lost their only caller in that one change, and a door whose far
//! side went away is `docs/55` §4b's own retirement criterion.
//!
//! ## The two that stayed, and why they are not the driver's
//!
//! What crosses here is not a session at all now — it is a CONFIGURATION and a piece of UI copy,
//! and both are asked BEFORE any driver exists:
//!
//! - [`slopdesk_pane_backoff_default`] answers the shipped schedule, which `SlopDeskClient.Backoff`
//!   presents as its three defaults and hands STRAIGHT BACK across `slopdesk_pane_driver_new`'s
//!   config. A literal `250ms`/`2s`/`2.0` in Swift would be a second copy of a rule that already
//!   has one, and it would be the copy a caller edits.
//! - [`slopdesk_pane_backoff_max_attempts`] is the give-up ceiling, and the near side needs it for
//!   a reason the driver cannot serve: the chrome renders "attempt N of M" while the campaign is
//!   still running, so M has to be readable before the `GaveUp` event that would report it.
//!
//! ## The ladder is nanoseconds
//!
//! The near side's duration type carries attoseconds. Milliseconds would silently round a schedule
//! configured in fractions of one, so the schedule crosses in nanoseconds, which is exact for every
//! wait it can express and saturates only past a hundred days.

use slopdesk_clientsession::backoff::{Backoff, MAX_RECONNECT_ATTEMPTS};

// NOTE: nothing converts a `SlopDeskPaneBackoff` back INTO a `Backoff` here any more. The schedule
// only ever crosses OUTWARD now — Swift reads it, presents it as three defaults, and hands the
// numbers to `slopdesk_pane_driver_new`, which builds the real `Backoff` on the Rust side.

/// One retry schedule, whole, as it crosses.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SlopDeskPaneBackoff {
    /// The wait before the first retry, in nanoseconds.
    pub initial_ns: u64,
    /// The ceiling, in nanoseconds.
    pub maximum_ns: u64,
    /// What each step multiplies by.
    pub multiplier: f64,
}

/// The shipped retry schedule: a quarter second, doubling to a two-second ceiling.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub extern "C" fn slopdesk_pane_backoff_default() -> SlopDeskPaneBackoff {
    let shipped = Backoff::default();
    SlopDeskPaneBackoff {
        initial_ns: shipped.initial_ns,
        maximum_ns: shipped.maximum_ns,
        multiplier: shipped.multiplier,
    }
}

/// How many attempts one SUPERVISED campaign makes before giving up.
///
/// The single source of truth for the ceiling: the app-global supervisor and the "attempt N of M"
/// copy both read it from here, so a mismatch cannot render an impossible "attempt 25 of 20".
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "`no_mangle` on an exported C entry point trips the lint even where the body is safe"
)]
pub const extern "C" fn slopdesk_pane_backoff_max_attempts() -> u32 {
    MAX_RECONNECT_ATTEMPTS
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the round trip is a bit-exact value; an epsilon would stop noticing a re-rounding"
    )]

    use super::{slopdesk_pane_backoff_default, slopdesk_pane_backoff_max_attempts};

    /// The shipped ladder crosses in nanoseconds, and the ceiling crosses as itself.
    ///
    /// The NUMBERS are asserted rather than merely round-tripped, because the whole point of the
    /// two survivors is that Swift does not spell them: a door that answered a schedule of its own
    /// invention would round-trip perfectly and still hand the driver a ladder nobody chose.
    ///
    /// The ladder's own arithmetic — what the third wait is, when it saturates, when a campaign is
    /// exhausted — is `slopdesk_clientsession::backoff`'s and is pinned there. It used to be pinned
    /// here too, through `slopdesk_pane_backoff_delay`/`_next_after`/`_exhausted`, and those doors
    /// retired with the Swift campaign that walked them (`docs/63` §G.5). What is left is the
    /// crossing.
    #[test]
    fn the_shipped_schedule_and_its_ceiling_cross() {
        let shipped = slopdesk_pane_backoff_default();
        assert_eq!(shipped.initial_ns, 250_000_000);
        assert_eq!(shipped.maximum_ns, 2_000_000_000);
        assert_eq!(shipped.multiplier, 2.0);
        assert_eq!(slopdesk_pane_backoff_max_attempts(), 20);
    }
}
