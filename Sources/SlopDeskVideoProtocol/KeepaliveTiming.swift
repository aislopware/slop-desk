import Foundation

/// The PATH 2 keepalive / idle-timeout-reaper timing contract (CONCURRENCY-HOST-1
/// crash-without-bye + its UDP-mux analogue). Always on.
///
/// ## Why keepalive exists
/// UDP has no FIN: a client that VANISHES without a `bye` (crash, network drop, or a
/// last-lane close racing its fire-and-forget bye egress) would leave the host's pinned flow
/// slot pinned and its capture/encode running with no peer (single-pin: one stuck slot;
/// mux: a leaked minted ``SlopDeskVideoHostSession`` per lane). The clean-`bye` path already
/// frees the slot (``VideoDatagramTransport/resetClientFlow``); the crash-without-bye case is
/// handled by a keepalive heartbeat (client) + an idle-timeout reaper (host) that reclaims a
/// dead flow, driven by the pure ``IdleReapDecider`` (never-reap-without-keepalive safety rule).
public enum KeepaliveTiming {
    // MARK: Constants (the timing contract — RFC 7675 §5.1 / RFC 9000 §10.1.2)

    //
    // Native Swift twin of `slopdesk_core::keepalive` — fixed compile-time constants (seconds),
    // the SINGLE source of truth shared by the client keepalive timer and the host idle-reaper so
    // host and client cannot silently drift apart.

    /// Client keepalive cadence (seconds). RFC 7675 §5.1 consent-check default is 5 s; well
    /// under the 30 s NAT-UDP mapping expiry (RFC 9000 §10.1.2) so a single empty 2-byte
    /// datagram per 5 s also refreshes the NetBird/WireGuard path mapping.
    public static let keepaliveInterval: TimeInterval = 5.0

    /// Host idle threshold (seconds) before a keepalive-proven flow is declared dead. RFC 7675
    /// 30 s consent expiry = 6× the 5 s interval, tolerating ~5 consecutive keepalive losses
    /// before reaping (mobile burst-loss safe). The minimum-safe ratio is 3× (RFC 9000
    /// §10.1.2 / WireGuard 10 s passive); 6× is comfortable for a video session where a 30 s
    /// slot-reclaim latency is fine.
    public static let idleTimeout: TimeInterval = 30.0

    /// Host reaper scan cadence (seconds) — coarse, = the keepalive interval, so the
    /// worst-case reclaim latency is `idleTimeout + reaperTick` ≤ 35 s.
    public static let reaperTick: TimeInterval = 5.0

    /// HOST→client heartbeat cadence (seconds) — the stall-scrim liveness signal, the counterpart of
    /// the client keepalive above. While a session streams, the host sends a zero-body `keepalive` on
    /// the control channel every second so the client can tell a healthily-IDLE window (idle-skip
    /// suppresses frames by design) from a DEAD / unreachable host (nothing arrives at all) and overlay
    /// its "Reconnecting…" scrim. Reuses wire type 6 — keepalive is documented wire-safe in BOTH
    /// directions (an old peer drops it inertly), so this is behaviour-only, no wire-format change.
    /// 1 s ⇒ the client's 3 s ``StreamStallPolicy/threshold`` tolerates two consecutive losses before
    /// declaring a stall, at a cost of one ~21-byte datagram per second per session.
    public static let hostHeartbeatInterval: TimeInterval = 1.0
}
