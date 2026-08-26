//! The socket options every PATH-1 TCP connection is built with.
//!
//! This is `Sources/SlopDeskTransport/TransportParameters.swift`, read for what it ASKS FOR rather
//! than what it was written in:
//!
//! ```swift
//! tcp.noDelay = true
//! tcp.enableKeepalive = true
//! tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
//! NWParameters(tls: nil, tcp: tcp)
//! ```
//!
//! Five knobs, and four of them are sockopts. The fifth — `tls: nil` — is the one that does not
//! port to a call at all: there is no TLS library to leave unconfigured here, because there is none
//! linked. `CLAUDE.md`: "No app-layer crypto or auth — security is the `WireGuard` mesh."
//!
//! ## Where the numbers live, and why not here
//!
//! `noDelay` is not an optimisation, it is the protocol working: a keystroke is a few bytes, and
//! Nagle would hold it for an ACK it has no reason to wait for. `DECISIONS.md` records it as
//! mandatory. It is a boolean set at the one place a socket is made, so it lives at that place.
//!
//! The keepalive triple does NOT: it is a bound the DIALLER and the LISTENER must agree on, and
//! those are two programs. So it belongs to [`slopdesk_wire::transport`], which both ends already
//! link, and this module only spends it. Spelling it again here is exactly the second copy
//! `slopdesk-invariants` exists to refuse.

use slopdesk_wire::transport::{
    TCP_KEEPALIVE_IDLE_SECONDS, TCP_KEEPALIVE_INTERVAL_SECONDS, TCP_KEEPALIVE_RETRY_COUNT,
};
use socket2::TcpKeepalive;

/// The keepalive policy every PATH-1 socket carries, on both ends.
///
/// `socket2` rather than three hand-written `setsockopt` calls: Darwin spells the idle time
/// `TCP_KEEPALIVE` where Linux spells it `TCP_KEEPIDLE`, the count and interval are two more
/// platform-conditional constants, and none of that is a fact about slopdesk. `CLAUDE.md`'s test
/// for the `unsafe` crate — "could its safety comment be written without naming slopdesk" — is
/// passed by this code, which is exactly why it belongs to a library instead.
#[must_use]
pub const fn keepalive() -> TcpKeepalive {
    TcpKeepalive::new()
        .with_time(core::time::Duration::from_secs(TCP_KEEPALIVE_IDLE_SECONDS))
        .with_interval(core::time::Duration::from_secs(TCP_KEEPALIVE_INTERVAL_SECONDS))
        .with_retries(TCP_KEEPALIVE_RETRY_COUNT)
}

#[cfg(test)]
mod tests {
    use slopdesk_wire::transport::dead_peer_detection_ceiling;

    /// The ladder this crate configures is the wire's, asked for rather than transcribed. The
    /// values themselves are pinned where they are declared; what is checked here is that the
    /// bound a caller of THIS crate reasons about is that same ladder.
    #[test]
    fn the_detection_ceiling_is_the_one_the_wire_declares() {
        assert_eq!(dead_peer_detection_ceiling().as_secs(), 25);
    }
}
