//! The socket policy both ends of a PATH-1 frame stream are written against.
//!
//! Not framing, and not a socket: three integers and the bound they imply. They live in the codec
//! crate for the reason every other number here does — the LISTENER and the DIALLER are two
//! separate programs, and a keepalive ladder configured on one side only is a half-open connection
//! that neither end reports. Nothing in this module opens, reads or configures anything, so the
//! crate's "transport-agnostic, no dependencies" promise still holds letter for letter.
//!
//! ## Why the numbers are not "tuning"
//!
//! Nothing in the mux layer polls. A client whose device slept, whose `WireGuard` tunnel flapped,
//! or whose Mac was closed leaves a socket that is open by every local test and connected to
//! nobody, and the only thing that ever notices is the kernel's keepalive probe. So the ladder is
//! what makes a dead peer DETECTABLE at all, and the detach ladder above it is written against
//! [`dead_peer_detection_ceiling`]: a timeout shorter than that bound would fire while the peer is
//! still merely quiet.
//!
//! `TCP_NODELAY` belongs to the same policy and is deliberately absent: it is a boolean, not a
//! number, and a boolean spelled twice cannot drift into a *different* boolean.

use core::time::Duration;

/// Seconds a PATH-1 connection may sit idle before the kernel sends its first keepalive probe.
///
/// Distinct from the video path's application-level UDP keepalive, which holds a NAT mapping open
/// and is a datagram this host sends rather than a probe the kernel sends.
pub const TCP_KEEPALIVE_IDLE_SECONDS: u64 = 10;

/// Seconds between keepalive probes once probing has started.
pub const TCP_KEEPALIVE_INTERVAL_SECONDS: u64 = 5;

/// Unanswered probes before the kernel declares the connection dead.
pub const TCP_KEEPALIVE_RETRY_COUNT: u32 = 3;

/// How long the whole ladder takes to declare a silent peer dead.
///
/// Derived rather than typed, and exported rather than kept private: every timeout stacked above
/// this one — detach, relinquish, the roster's eviction — is chosen relative to this bound, and a
/// second spelling of 25 would be right only until one of the three above it moved.
///
/// Not `const fn`: `u64::from` is not a const trait method yet, and the alternative — an `as` cast
/// — would be a lossless widening spelled the one way that also hides a lossy one.
#[must_use]
pub fn dead_peer_detection_ceiling() -> Duration {
    Duration::from_secs(
        TCP_KEEPALIVE_IDLE_SECONDS + TCP_KEEPALIVE_INTERVAL_SECONDS * u64::from(TCP_KEEPALIVE_RETRY_COUNT),
    )
}

#[cfg(test)]
mod tests {
    use super::{
        TCP_KEEPALIVE_IDLE_SECONDS, TCP_KEEPALIVE_INTERVAL_SECONDS, TCP_KEEPALIVE_RETRY_COUNT,
        dead_peer_detection_ceiling,
    };

    /// The ladder both ends were written against, pinned so a tune is a visible edit here rather
    /// than a silent change of meaning at one end of a connection.
    #[test]
    fn the_keepalive_ladder_is_the_one_both_ends_agreed_on() {
        assert_eq!(TCP_KEEPALIVE_IDLE_SECONDS, 10);
        assert_eq!(TCP_KEEPALIVE_INTERVAL_SECONDS, 5);
        assert_eq!(TCP_KEEPALIVE_RETRY_COUNT, 3);
        assert_eq!(dead_peer_detection_ceiling().as_secs(), 25);
    }
}
