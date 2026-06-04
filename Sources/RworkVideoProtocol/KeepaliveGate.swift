import Foundation

/// The `RWORK_VIDEO_KEEPALIVE` env-gate for the PATH 2 idle-timeout reaper
/// (CONCURRENCY-HOST-1 crash-without-bye + its UDP-mux analogue). Default OFF.
///
/// ## Why this gate exists
/// UDP has no FIN: a client that VANISHES without a `bye` (crash, network drop, or a
/// last-lane close racing its fire-and-forget bye egress) leaves the host's pinned flow
/// slot pinned and its capture/encode running with no peer (single-pin: one stuck slot;
/// mux: a leaked minted ``RworkVideoHostSession`` per lane). The clean-`bye` path already
/// frees the slot (``VideoDatagramTransport/resetClientFlow``); only the crash-without-bye
/// case needs a liveness reaper. This gate (ON) turns on a keepalive heartbeat (client) +
/// an idle-timeout reaper (host) that reclaims a dead flow.
///
/// ## Same flag, role-asymmetric (one variable, both ends read it)
/// - On the **host** (`rwork-videohostd`): ON ⇒ construct the ``IdleReapDecider`` + start
///   the idle-timeout reaper at the transport construction sites.
/// - On the **client** (`Rwork.app`): ON ⇒ start the keepalive send timer in
///   ``RworkVideoClientSession``.
/// The *role* differs by which binary reads the flag; the flag itself is one shared parse
/// (same rationale as ``VideoMuxGate`` being shared) so the constants can never drift.
///
/// ## OFF is byte-identical
/// An UNSET (or non-truthy) `RWORK_VIDEO_KEEPALIVE` returns `false`. The host constructs no
/// decider (the stamp blocks are skipped on a `nil` check, no timer is armed, the reap hooks
/// stay nil), the client constructs no keepalive task, and the new `keepalive` codec case is
/// unreachable because nobody emits it. The gate is read ONCE at the construction sites,
/// never on the hot per-datagram path — the same construction-site-gate discipline as
/// ``VideoMuxGate`` / ``StaticIDRGate``.
///
/// ## Why a one-sided gate is SAFE (degrades, never misbehaves)
/// - **Host ON, client OFF:** the client never sends keepalives ⇒ every flow has
///   `sawKeepalive == false` ⇒ the reaper returns `[]` forever ⇒ exactly today's no-reap
///   behaviour (the ``IdleReapDecider`` safety rule). No false kill of a silent legacy client.
/// - **Client ON, host OFF:** the client emits type-6 keepalive datagrams; the old host's
///   `handleControl` decode throws `.malformed` and drops them — harmless extra traffic
///   (one 2-byte datagram / 5 s), no crash, plus a free NAT/WireGuard path-refresh.
public enum KeepaliveGate {
    /// The `RWORK_VIDEO_KEEPALIVE` gate value from `env` (ON iff `"1"`/`"true"`/`"yes"`/`"on"`,
    /// case-insensitive). Default OFF. Same truthiness vocabulary as ``VideoMuxGate`` /
    /// ``StaticIDRGate``.
    public static func enabledFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = env["RWORK_VIDEO_KEEPALIVE"]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    // MARK: Constants (the timing contract — RFC 7675 §5.1 / RFC 9000 §10.1.2)

    /// Client keepalive cadence (seconds). RFC 7675 §5.1 consent-check default is 5 s; well
    /// under the 30 s NAT-UDP mapping expiry (RFC 9000 §10.1.2) so a single empty 2-byte
    /// datagram per 5 s also refreshes the NetBird/WireGuard path mapping.
    public static let keepaliveInterval: TimeInterval = 5

    /// Host idle threshold (seconds) before a keepalive-proven flow is declared dead. RFC 7675
    /// 30 s consent expiry = 6× the 5 s interval, tolerating ~5 consecutive keepalive losses
    /// before reaping (mobile burst-loss safe). The minimum-safe ratio is 3× (RFC 9000
    /// §10.1.2 / WireGuard 10 s passive); 6× is comfortable for a video session where a 30 s
    /// slot-reclaim latency is fine.
    public static let idleTimeout: TimeInterval = 30

    /// Host reaper scan cadence (seconds) — coarse, = the keepalive interval, so the
    /// worst-case reclaim latency is `idleTimeout + reaperTick` ≤ 35 s.
    public static let reaperTick: TimeInterval = 5
}
